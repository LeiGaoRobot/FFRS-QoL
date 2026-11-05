-- Smart auto battle for FFRS QoL (loaded by main.lua; used by auto repeat in Smart mode).
-- Picks the acting character's command from the enemies' real elemental resistances, which the
-- game knows even for enemies that were never scanned:
--   1. an ally below the heal threshold -> the strongest affordable heal that reaches them
--   1b. own MP below AutoEtherBelow (default 30%) and it has skills that cost MP -> an ether
--   2. boss fights: 託付 (hand the gauge to an ally it completes a Limit Burst for) or 極限蓄力
--      (when it completes the character's own); then attack buffs that aren't active yet (敏銳,
--      信心, 急速 ...): 轉戰自如之策 before a formation, one formation at a time, and with W臂腕 two
--      buffs (or a buff and an attack) per turn
--   2b. any fight: a charge (凝氣, 累積魔力) before an attack
--   3. the strongest turn built from attack skills that no target resists (a weakness counts
--      1.5x, a group skill counts every target): one skill, 連續詠唱 (two spells), W行動 (two
--      non-spell attacks), 魔力增幅 + a magic attack, 平衡崩壞 + a physical attack, or W臂腕
--      with two of those. In boss fights a Limit Burst the LB pays for always goes first (alone
--      or inside W臂腕). 模仿 instead when the turn decided just before is worth more.
--   4. with nothing to attack with, the recorded command unless a target would halve, nullify,
--      absorb or reflect its element -> then a basic attack
-- plan() returns a command in the same shape as main.lua's records; items with fixed = true
-- already have their targets.
local M = {}

local REL_FRIENDLIES, REL_ENEMIES = 1, 2
local PARAM_HP, PARAM_MP = 1, 2
local TGT_SELF, TGT_SINGLE, TGT_GROUP = 0, 1, 2
local EFFECT_DAMAGE_RECOVERY, VAR_DECREASE = 1, 1
local RES_WEAK, RES_HALVED = 1, 2          -- eResistance: 2 halved, 3 invalid, 4 absorb, 5 reflect
local ATTR_LIMIT, ATTR_SUMMON = 5, 7       -- skillAttrType: never picked automatically
local MENU_SKILLS, MENU_SUMMON, MENU_ITEMS, MENU_LIMIT = 1, 6, 7, 10
local ATTR_MAGIC = 4                       -- spells: blocked by Silence, bounced by Reflect
local DMG_PHYSICAL, DMG_MAGIC = 1, 2       -- eSkillDamageType
local ST_SILENCE, ST_REFLECT = 4, 32       -- eUnitStatusCondition
local CAT_SKILL, CAT_ITEM = 1, 2           -- eActionCategory
local W_ARM = 400650                       -- W臂腕: any two commands (each may be a boosted attack)
local DUAL_CAST = 400730                   -- 連續詠唱: two spells
local W_ACTION = 400710                    -- W行動: two attacks that aren't spells
local MAGIC_BOOST = 400660                 -- 魔力增幅: next magic attack x2 damage, x1.5 MP
local BREAK_BOOST = 400700                 -- 平衡崩壞: next physical attack x2 break damage, x1.5 MP
local CHARGE_ANY, CHARGE_MAGIC = 400460, 400630   -- 凝氣 (next attack), 累積魔力 (next magic attack)
local STRATAGEM = 405120                   -- 轉戰自如之策: after a formation the character acts again
-- 陣型, best first (the set 轉戰自如之策 names; 405030 and 405080 are Limit Burst formations, never
-- cast here but seen as active). Only one is active at a time: a new one replaces it.
local FORMATIONS = { 405110, 405060, 405070, 405030, 405080 }
local MIMIC = 400330                       -- 模仿: repeats the turn decided just before
local LB_PASS, LB_CHARGE = 403210, 400770  -- 託付 (own gauge to an ally), 極限蓄力 (own gauge +25%)
local LB_CHARGE_RATE = 0.25                -- of one gauge bar (the smallest it could mean)
local WEAK_BONUS = 1.5
local BOOST_MP = 1.5
local BREAK_VALUE = 1.25                   -- break damage, not HP damage: worth a little more
local CHARGE_TIME = 120                    -- seconds a charge waits for the character's next turn
-- Attack buffs used when not active: attack/magic/break up, haste, boost and the characters'
-- own damage stances (eUnitStatusCondition). Defence buffs are left out.
local BUFF_STATUS = { [24] = true, [26] = true, [28] = true, [33] = true, [37] = true, [41] = true,
    [51] = true, [52] = true, [53] = true, [71] = true, [72] = true, [73] = true, [74] = true,
    [75] = true, [76] = true, [77] = true, [78] = true, [80] = true, [81] = true, [83] = true, [84] = true }

local D = nil     -- helpers from main.lua (init)
local Info = nil  -- [skillId] = { el, mag, attr, rel, tgt, damage, dmgType, buffs, cmd1, name }
local Charged = {}  -- [unit] = os.clock() of the charge planned for its next turn

function M.init(deps) D = deps end

local function buildInfo()
    local t, effects, bundles = {}, {}, {}
    for _, dt in ipairs(FindAllOf("DataTable") or {}) do
        pcall(function()
            local struct = D.rowStructName(dt)
            if struct == "SKILL_EFFECT_DATA" then
                dt:ForEachRow(function(_, row) effects[row.ID] = row.statusCondition end)
            elseif struct == "SKILL_DATA" then
                dt:ForEachRow(function(_, row)
                    local cmd1 = false
                    row.belongCommandList:ForEach(function(_, e) if e:get() == MENU_SKILLS then cmd1 = true end end)
                    local ids = {}
                    pcall(function()
                        row.effectBundleList:ForEach(function(_, e)
                            local b = e:get()
                            if b.effectId > 0 and b.targetRelation == REL_FRIENDLIES then ids[#ids + 1] = b.effectId end
                        end)
                    end)
                    bundles[row.ID] = ids
                    local okN, name = pcall(function() return row.Name:ToString() end)
                    t[row.ID] = {
                        el = row.element, mag = row.magnification or 0, attr = row.skillAttrType,
                        rel = row.defaultTargetRelation, tgt = row.TargetType, cmd1 = cmd1,
                        reflectPen = row.isReflectPenetration and true or false,
                        damage = row.skillEffectType == EFFECT_DAMAGE_RECOVERY and row.parameterType == PARAM_HP
                            and row.parameterVariationType == VAR_DECREASE,
                        dmgType = row.DamageType, status = row.statusCondition,
                        name = okN and tostring(name) or tostring(row.ID),
                    }
                end)
            end
        end)
    end
    -- Attack buff statuses a friendly skill gives (on the row or through its effects).
    for id, s in pairs(t) do
        local b = {}
        if BUFF_STATUS[s.status] then b[s.status] = true end
        for _, eid in ipairs(bundles[id] or {}) do
            local st = effects[eid]
            if st and BUFF_STATUS[st] then b[st] = true end
        end
        if next(b) and s.rel == REL_FRIENDLIES and not s.damage then s.buffs = b end
    end
    if next(t) then Info = t end
end

local function info(id)
    if not Info then buildInfo() end
    return Info and Info[id]
end
M.info = info

local function name(id)
    local s = info(id)
    return s and s.name or tostring(id)
end

local skillLib = nil
local function costFor(unitId, id, isAll)
    local ok, c = pcall(function()
        if not (skillLib and skillLib:IsValid()) then skillLib = StaticFindObject("/Script/mucha.Default__CPP_BFL_Skill") end
        return skillLib:GetSkillCost(id, unitId, isAll and true or false)
    end)
    if ok and type(c) == "number" and c >= 0 then return c end
    return math.huge
end
local function cost(ctx, id, isAll) return costFor(ctx.unitId, id, isAll) end

local unitLib = nil
local function oneGauge()
    local ok, g = pcall(function()
        if not (unitLib and unitLib:IsValid()) then unitLib = StaticFindObject("/Script/mucha.Default__CPP_BFL_Unit") end
        return unitLib:GetLimitBurstPointOneGauge()
    end)
    return (ok and type(g) == "number" and g > 0) and g or 0
end

-- MP for a whole recorded turn (a W command costs its own MP plus each ability).
local function turnCost(ctx, c)
    local sum = 0
    for _, it in ipairs(c.items) do
        if not it.isUseItem and it.pId ~= MENU_LIMIT then sum = sum + cost(ctx, it.actionId, it.IsAll) end
    end
    return sum
end

-- Status conditions of a unit as a set (cached for one decision).
local function statuses(bfl, cache, uid)
    local key = "st" .. uid
    local s = cache[key]
    if not s then
        s = {}
        local ok, list = pcall(function() return D.outList(function(t) bfl:GetStatusConditionList(t, uid) end) end)
        if ok then for _, x in ipairs(list) do s[x] = true end end
        cache[key] = s
    end
    return s
end

-- A spell aimed at a unit with Reflect would bounce off it.
local function bounces(bfl, cache, s, uid)
    return s.attr == ATTR_MAGIC and not s.reflectPen and statuses(bfl, cache, uid)[ST_REFLECT] == true
end

local function targetsOf(bfl, actor, id, rel)
    local ok, list = pcall(function()
        return D.outList(function(t) bfl:GetSkillTargetUnitUniqueIdList(t, actor, id, rel, true) end)
    end)
    return ok and list or {}
end

local function hpOf(bfl, uid)
    local ok, hp = pcall(function() return bfl:GetBattleUnitParameter(uid, true):GetParameterByType(PARAM_HP, false) end)
    return (ok and type(hp) == "number") and hp or math.huge
end

local function lowestHp(bfl, list)
    local best, bestHp = nil, nil
    for _, uid in ipairs(list) do
        local hp = hpOf(bfl, uid)
        if not best or hp < bestHp then best, bestHp = uid, hp end
    end
    return best
end

-- The unit's real resistance to an element (cached for one decision).
local function resist(bfl, cache, uid, el)
    local u = cache[uid]
    if not u then u = {}; cache[uid] = u end
    local r = u[el]
    if r == nil then
        local ok, v = pcall(function() return bfl:GetBattleUnitParameter(uid, true):GetResistanceToElement(el) end)
        r = (ok and type(v) == "number") and v or 0
        u[el] = r
    end
    return r
end

local function contains(list, x)
    for _, v in ipairs(list) do if v == x then return true end end
    return false
end

-- What the acting unit can use now: its menus (GetActionList: basic attack, 1 = abilities,
-- the Vision's menu, 6 summons, defend, 7 items, escape), its skills and the menu each one is in.
local function unitContext(bfl, actor, cache)
    local p = bfl:GetBattleUnitParameter(actor, true)
    local ctx = { actor = actor, unitId = p:GetUnitId(), mp = p:GetParameterByType(PARAM_MP, false) or 0, menuOf = {}, skills = {} }
    ctx.silenced = statuses(bfl, cache, actor)[ST_SILENCE] == true
    local menus = D.outList(function(t) p:GetActionList(t) end)
    local vision = nil
    for _, m in ipairs(menus) do
        if m < 1000 and m ~= MENU_SKILLS and m ~= MENU_SUMMON and m ~= MENU_ITEMS and m ~= MENU_LIMIT then vision = m; break end
    end
    local function enabled(m)
        local ok, r = pcall(function() return bfl:IsEnableCommand(actor, m) end)
        return not (ok and r == false)
    end
    local own = {}
    for _, id in ipairs(D.outList(function(t) p:GetActiveSkillList(t) end)) do own[id] = true end
    local okSkills, okVision = enabled(MENU_SKILLS), vision ~= nil and enabled(vision)
    local okLb, lb = pcall(function() return p:GetLimitBurstPoint() end)
    ctx.lb = (okLb and type(lb) == "number") and lb or 0
    ctx.itemsOk = contains(menus, MENU_ITEMS) and enabled(MENU_ITEMS)
    -- Limit Bursts sit behind their own button, not in GetActionList (IsEnableCommand(10) is
    -- always false); LB decides whether one can be used.
    ctx.limits = {}
    for _, id in ipairs(D.outList(function(t) p:GetActiveSkillListWithVision(t) end)) do
        local s = info(id)
        if s then
            if s.attr == 1 and s.damage and not ctx.basic then ctx.basic = id end   -- 戰鬥
            if s.attr == ATTR_LIMIT and s.damage then ctx.limits[#ctx.limits + 1] = id; ctx.menuOf[id] = MENU_LIMIT end
            if s.attr ~= ATTR_LIMIT and s.attr ~= ATTR_SUMMON and not (ctx.silenced and s.attr == ATTR_MAGIC) then
                local menu = nil
                if own[id] then
                    if s.cmd1 and okSkills then menu = MENU_SKILLS end
                elseif okVision then
                    menu = vision   -- skills that only the Vision gives sit in its own menu
                end
                if menu then ctx.menuOf[id] = menu; ctx.skills[#ctx.skills + 1] = id end
            end
        end
    end
    if not ctx.basic and menus[1] and menus[1] > 1000 then ctx.basic = menus[1] end
    return ctx
end

-- How much a hit on uid is worth: 1.5 on a weakness, 1 when neutral, nil when the target would
-- halve, nullify, absorb or reflect it.
local function factor(bfl, cache, s, uid)
    if bounces(bfl, cache, s, uid) then return nil end
    if not (s.el and s.el > 0) then return 1 end
    local r = resist(bfl, cache, uid, s.el)
    if r == RES_WEAK then return WEAK_BONUS end
    if r >= RES_HALVED then return nil end
    return 1
end

-- A single or group damage skill: { id, targets, score, weak }, or nil when it can't hit
-- anything at full strength. A group skill counts every target, so it wins against several
-- enemies; one target that resists rules it out.
local function evaluate(bfl, ctx, id, cache)
    local s = info(id)
    if not (s and s.damage and s.rel == REL_ENEMIES) then return nil end
    if s.tgt ~= TGT_SINGLE and s.tgt ~= TGT_GROUP then return nil end
    local cands = targetsOf(bfl, ctx.actor, id, REL_ENEMIES)
    if #cands == 0 then return nil end
    if s.tgt == TGT_SINGLE then
        local bestF, pool = nil, {}
        for _, uid in ipairs(cands) do
            local f = factor(bfl, cache, s, uid)
            if f and (not bestF or f > bestF) then bestF, pool = f, { uid }
            elseif f and f == bestF then pool[#pool + 1] = uid end
        end
        if not bestF then return nil end
        return { id = id, targets = { lowestHp(bfl, pool) }, score = s.mag * bestF, weak = bestF > 1 }
    end
    local sum, weak = 0, false
    for _, uid in ipairs(cands) do
        local f = factor(bfl, cache, s, uid)
        if not f then return nil end
        sum = sum + f
        if f > 1 then weak = true end
    end
    return { id = id, targets = cands, score = s.mag * sum, weak = weak }
end

-- Is a boss among the enemies?
local function bossFight(bfl, ctx, cache)
    if cache.boss == nil then
        cache.boss = false
        for _, uid in ipairs(targetsOf(bfl, ctx.actor, ctx.basic or 0, REL_ENEMIES)) do
            local ok, b = pcall(function() return bfl:GetBattleUnitParameter(uid, true):IsBoss() end)
            if ok and b == true then cache.boss = true end
        end
    end
    return cache.boss
end

-- Keys are the menu path of every action in order: [cat:menu, cat:skill] per action. A basic
-- attack (no parent menu) and an action chosen inside an earlier action's list (W's own basic
-- attacks, the spells of 連續詠唱, the attack after 魔力增幅 ...) add only the skill.
local function buildKeys(c)
    local keys, used = {}, {}
    for _, it in ipairs(c.items) do
        if it.pCat ~= 0 and not used[it.pId] then keys[#keys + 1] = { it.pCat, it.pId } end
        keys[#keys + 1] = { it.isUseItem and CAT_ITEM or CAT_SKILL, it.actionId }
        used[it.actionId] = true
    end
    return keys
end
M.buildKeys = buildKeys

local function copyItem(it)
    local n = {}
    for k, v in pairs(it) do n[k] = v end
    return n
end

local function shell(ctx, phase, rec)
    return { CmdType = phase, isNotConsume = rec and rec.isNotConsume or false,
             doCalcOrder = (rec == nil) or rec.doCalcOrder, items = {}, keys = {}, smart = true }
end

local function single(ctx, phase, rec, id, targets)
    local menu = ctx.menuOf[id]
    local c = shell(ctx, phase, rec)
    c.CommandId = menu
    c.items[1] = { actionId = id, unit = ctx.actor, targets = targets, params = {}, isUseItem = false, IsAll = false,
                   pCat = CAT_SKILL, pId = menu, fixed = true }
    c.keys = buildKeys(c)
    return c
end

local function basicAttack(bfl, ctx, phase, rec)
    if not ctx.basic then return nil end
    local cands = targetsOf(bfl, ctx.actor, ctx.basic, REL_ENEMIES)
    local okT, t = pcall(function() return bfl:GetDefaultSkillTargetUnitUniqueId(ctx.actor, ctx.basic) end)
    local target = (okT and type(t) == "number" and contains(cands, t)) and t or lowestHp(bfl, cands)
    if not target then return nil end
    local c = shell(ctx, phase, rec)
    c.CommandId = -1
    c.items[1] = { actionId = ctx.basic, unit = ctx.actor, targets = { target }, params = {}, isUseItem = false, IsAll = false,
                   pCat = 0, pId = -1, fixed = true }
    c.keys = buildKeys(c)
    return c
end

-- Lowest ally under the threshold, healed with the strongest heal the actor can pay for that
-- won't bounce off them (a healing spell bounces off Reflect; an ability like First Aid doesn't).
local function planHeal(bfl, ctx, phase, rec, threshold, cache)
    local heals = {}
    for _, id in ipairs(ctx.skills) do
        local k = D.skillInfo(id)
        if k and k.kind == "heal" then
            local c = cost(ctx, id)
            if c <= ctx.mp then heals[#heals + 1] = { id = id, cost = c, mag = info(id).mag } end
        end
    end
    if #heals == 0 then return nil end
    table.sort(heals, function(a, b) if a.mag ~= b.mag then return a.mag > b.mag end; return a.cost < b.cost end)
    local hurt, seen = {}, {}
    for _, hl in ipairs(heals) do
        hl.targets = targetsOf(bfl, ctx.actor, hl.id, REL_FRIENDLIES)
        for _, uid in ipairs(hl.targets) do
            if not seen[uid] then
                seen[uid] = true
                local r = D.hpRatio(bfl, uid)
                if r and r * 100 < threshold then hurt[#hurt + 1] = { uid = uid, r = r } end
            end
        end
    end
    table.sort(hurt, function(a, b) return a.r < b.r end)
    for _, h in ipairs(hurt) do
        for _, hl in ipairs(heals) do
            if contains(hl.targets, h.uid) and not bounces(bfl, cache, info(hl.id), h.uid) then
                return single(ctx, phase, rec, hl.id, { h.uid }), string.format("heal %s -> unit %d (HP %.0f%%)", name(hl.id), h.uid, h.r * 100)
            end
        end
    end
    return nil
end

-- MP items (item id, MP restored), weakest first: 乙太, 渦輪乙太, 超級乙太.
local ETHERS = { { id = 3, mp = 50 }, { id = 20, mp = 150 }, { id = 18, mp = 300 } }
local itemLib = nil
local function stock(id)
    local ok, n = pcall(function()
        if not (itemLib and itemLib:IsValid()) then itemLib = StaticFindObject("/Script/mucha.Default__CPP_BFL_Item") end
        return itemLib:GetInventoryItemNum(id)
    end)
    return (ok and type(n) == "number") and n or 0
end

-- Below the MP threshold (percent of max), with skills that cost MP: drink the biggest
-- ether that doesn't waste MP, else the smallest one in stock. Without one, the turn is planned
-- as usual (cheaper skills, then a basic attack).
local function planEther(bfl, ctx, phase, rec, below)
    if below <= 0 or not ctx.itemsOk then return nil end
    local ok, max = pcall(function() return bfl:GetBattleUnitParameter(ctx.actor, true):GetMaxParameterByType(PARAM_MP) end)
    if not (ok and type(max) == "number" and max > 0) or ctx.mp * 100 >= below * max then return nil end
    local usesMp = false   -- a character whose skills are all free has no use for MP
    for _, id in ipairs(ctx.skills) do
        local s = info(id)
        if (s.damage or s.buffs or (D.skillInfo(id) or {}).kind == "heal") and cost(ctx, id) > 0 then usesMp = true; break end
    end
    if not usesMp then return nil end
    local gap, pick = max - ctx.mp, nil
    for _, e in ipairs(ETHERS) do
        if stock(e.id) > 0 then
            if e.mp <= gap or not pick then pick = e end
        end
    end
    if not pick then return nil end
    local c = shell(ctx, phase, rec)
    c.CommandId = MENU_ITEMS
    c.items[1] = { actionId = pick.id, unit = ctx.actor, targets = { ctx.actor }, params = {}, isUseItem = true, IsAll = false,
                   pCat = CAT_SKILL, pId = MENU_ITEMS, fixed = true }
    c.keys = buildKeys(c)
    local okN, nm = pcall(function() return itemLib:GetItemName(pick.id):ToString() end)
    return c, string.format("item %s (MP %d/%d)", okN and tostring(nm) or tostring(pick.id), ctx.mp, max)
end

-- Turn building. A "strike" is one attack: { id, targets, score, cost }; a limit strike costs
-- LB (lb) instead of MP. A "unit" is what one command slot does: a strike, 魔力增幅 / 平衡崩壞
-- followed by a strike, or a Limit Burst. A turn is one unit, or a head (連續詠唱, W行動, W臂腕)
-- with two of them.
local function act(ctx, id, targets, pId)
    return { actionId = id, unit = ctx.actor, targets = targets, params = {}, isUseItem = false, IsAll = false,
             pCat = CAT_SKILL, pId = pId, fixed = true }
end

local function has(ctx, id) return ctx.menuOf[id] == MENU_SKILLS end

local function units(ctx, strikes, limits)
    local list = {}
    for _, s in ipairs(limits) do
        list[#list + 1] = { score = s.score, cost = 0, lb = s.lb, strikes = { s },
                            items = function() return { act(ctx, s.id, s.targets, MENU_LIMIT) } end }
    end
    for _, s in ipairs(strikes) do
        list[#list + 1] = { score = s.score, cost = s.cost, strikes = { s },
                            items = function() return { act(ctx, s.id, s.targets, ctx.menuOf[s.id]) } end }
        local si = info(s.id)
        local boost = (si.dmgType == DMG_MAGIC and has(ctx, MAGIC_BOOST) and MAGIC_BOOST)
            or (si.dmgType == DMG_PHYSICAL and has(ctx, BREAK_BOOST) and BREAK_BOOST) or nil
        if boost then
            local value = boost == MAGIC_BOOST and 2 or BREAK_VALUE
            list[#list + 1] = { score = s.score * value, cost = cost(ctx, boost) + math.ceil(s.cost * BOOST_MP), strikes = { s },
                                boost = boost,
                                items = function() return { act(ctx, boost, { ctx.actor }, MENU_SKILLS), act(ctx, s.id, s.targets, boost) } end }
        end
    end
    return list
end

-- The best pair from list (the same entry may be used twice) that fits in mp and lb, with at
-- most one Limit Burst (exactly one when needLimit).
local function bestPair(list, mp, lb, needLimit)
    local best = nil
    for i = 1, #list do
        for j = i, #list do
            local a, b = list[i], list[j]
            local c = a.cost + b.cost
            local n = (a.lb and 1 or 0) + (b.lb and 1 or 0)
            if c <= mp and (a.lb or 0) + (b.lb or 0) <= (lb or 0) and n <= 1 and (n == 1 or not needLimit) then
                local s = a.score + b.score
                if not best or s > best.score or (s == best.score and c < best.cost) then best = { a, b, score = s, cost = c } end
            end
        end
    end
    return best
end

local function strikeLabel(s)
    local t = (#s.targets == 1) and ("unit " .. s.targets[1]) or (#s.targets .. " enemies")
    return name(s.id) .. " -> " .. t
end

local function turn(ctx, phase, rec, items, label)
    local c = shell(ctx, phase, rec)
    c.CommandId = items[1].pId
    c.items = items
    c.keys = buildKeys(c)
    return c, label
end

-- The strongest affordable turn, or nil when no strike fits. When a Limit Burst can be paid for
-- (boss fights), the turn always has one: on its own or inside W臂腕. The data's magnification
-- undervalues limits, so they aren't left to the score.
local function planAttack(ctx, phase, rec, strikes, limits)
    local best = nil
    local needLimit = #limits > 0
    local function offer(score, mp, build)
        if mp <= ctx.mp and (not best or score > best.score or (score == best.score and mp < best.cost)) then
            best = { score = score, cost = mp, build = build }
        end
    end
    local all = units(ctx, strikes, limits)
    for _, u in ipairs(all) do
        if (u.lb or 0) <= ctx.lb and (u.lb or not needLimit) then
            offer(u.score, u.cost, function()
                local label = (u.boost and (name(u.boost) .. " + ") or "") .. strikeLabel(u.strikes[1])
                return turn(ctx, phase, rec, u.items(), "attack: " .. label)
            end)
        end
    end
    -- 連續詠唱 / W行動: the head, then two strikes chosen from its own list.
    local function twoOf(head, keep)
        if needLimit or not has(ctx, head) then return end
        local pool = {}
        for _, s in ipairs(strikes) do if keep(info(s.id)) then pool[#pool + 1] = s end end
        local headCost = cost(ctx, head)
        local p = bestPair(pool, ctx.mp - headCost)
        if not p then return end
        offer(p.score, p.cost + headCost, function()
            local items = { act(ctx, head, { ctx.actor }, MENU_SKILLS), act(ctx, p[1].id, p[1].targets, head), act(ctx, p[2].id, p[2].targets, head) }
            return turn(ctx, phase, rec, items, string.format("attack: %s + %s, %s", name(head), strikeLabel(p[1]), strikeLabel(p[2])))
        end)
    end
    twoOf(DUAL_CAST, function(s) return s.attr == ATTR_MAGIC end)
    twoOf(W_ACTION, function(s) return s.attr ~= ATTR_MAGIC end)
    -- W臂腕: two commands, each a strike or a boosted strike.
    if has(ctx, W_ARM) then
        local wCost = cost(ctx, W_ARM)
        local p = bestPair(all, ctx.mp - wCost, ctx.lb, needLimit)
        if p then
            offer(p.score, p.cost + wCost, function()
                local items = { act(ctx, W_ARM, { ctx.actor }, MENU_SKILLS) }
                local parts = {}
                for k = 1, 2 do
                    for _, it in ipairs(p[k].items()) do items[#items + 1] = it end
                    parts[k] = (p[k].boost and (name(p[k].boost) .. " + ") or "") .. strikeLabel(p[k].strikes[1])
                end
                return turn(ctx, phase, rec, items, string.format("attack: %s + %s, %s", name(W_ARM), parts[1], parts[2]))
            end)
        end
    end
    if best then
        local c, label = best.build()
        return c, label, best.score
    end
    return nil
end

local function unitLabel(u)
    return (u.boost and (name(u.boost) .. " + ") or "") .. strikeLabel(u.strikes[1])
end

-- W臂腕 with `first` ({ id, targets, cost }) and the strongest attack that still fits (a Limit
-- Burst when limits has one), or nil without W臂腕 or the MP for both.
local function wWithAttack(ctx, phase, rec, strikes, first, firstLabel, kind, limits)
    if not has(ctx, W_ARM) then return nil end
    local room = ctx.mp - cost(ctx, W_ARM) - first.cost
    local lim = limits or {}
    local bestU = nil
    for _, u in ipairs(units(ctx, strikes, lim)) do
        if u.cost <= room and (u.lb or 0) <= ctx.lb and (u.lb or #lim == 0)
            and (not bestU or u.score > bestU.score) then bestU = u end
    end
    if not bestU then return nil end
    local items = { act(ctx, W_ARM, { ctx.actor }, MENU_SKILLS), act(ctx, first.id, first.targets, ctx.menuOf[first.id]) }
    for _, it in ipairs(bestU.items()) do items[#items + 1] = it end
    return turn(ctx, phase, rec, items, string.format("%s: %s + %s, %s", kind, name(W_ARM), firstLabel, unitLabel(bestU)))
end

-- The Limit Burst gauge of an ally and the cheapest damage Limit Burst it has (nil: none).
local function allyLimit(bfl, uid)
    local ok, lb, need = pcall(function()
        local p = bfl:GetBattleUnitParameter(uid, true)
        local unitId, need = p:GetUnitId(), nil
        for _, id in ipairs(D.outList(function(t) p:GetActiveSkillListWithVision(t) end)) do
            local s = info(id)
            if s and s.attr == ATTR_LIMIT and s.damage then
                local c = costFor(unitId, id)
                if not need or c < need then need = c end
            end
        end
        return p:GetLimitBurstPoint(), need
    end)
    if ok and type(lb) == "number" then return lb, need end
    return 0, nil
end

-- Boss fights: 託付 when the character has no damage Limit Burst of its own and its gauge
-- completes an ally's; 極限蓄力 when it completes the character's own (inside W臂腕 with an attack
-- when it can).
local function planLimitHelp(bfl, ctx, phase, rec, strikes)
    if ctx.menuOf[LB_PASS] and #ctx.limits == 0 and ctx.lb > 0 and cost(ctx, LB_PASS) <= ctx.mp then
        for _, uid in ipairs(targetsOf(bfl, ctx.actor, LB_PASS, REL_FRIENDLIES)) do
            if uid ~= ctx.actor then
                local lb, need = allyLimit(bfl, uid)
                if need and lb < need and lb + ctx.lb >= need then
                    return single(ctx, phase, rec, LB_PASS, { uid }),
                        string.format("pass LB %s -> unit %d (%d + %d of %d)", name(LB_PASS), uid, lb, ctx.lb, need)
                end
            end
        end
    end
    if ctx.menuOf[LB_CHARGE] and #ctx.limits > 0 then
        local need = nil
        for _, id in ipairs(ctx.limits) do
            local c = cost(ctx, id)
            if not need or c < need then need = c end
        end
        local c = cost(ctx, LB_CHARGE)
        if ctx.lb < need and ctx.lb + oneGauge() * LB_CHARGE_RATE >= need and c <= ctx.mp then
            local first = { id = LB_CHARGE, targets = { ctx.actor }, cost = c }
            local w, wl = wWithAttack(ctx, phase, rec, strikes, first, name(LB_CHARGE), "LB")
            if w then return w, wl end
            return single(ctx, phase, rec, LB_CHARGE, { ctx.actor }), string.format("LB %s (%d of %d)", name(LB_CHARGE), ctx.lb, need)
        end
    end
    return nil
end

-- What 模仿 would be worth now: the turn decided just before (another character's, usually),
-- scored like our own attacks against the enemies still standing. 0 when it has no attack, or
-- a target would resist it.
local function mimicScore(bfl, ctx, cache)
    if not (ctx.menuOf[MIMIC] and D.lastDecision) or cost(ctx, MIMIC) > ctx.mp then return 0 end
    local c = D.lastDecision()
    if not (c and c.items and c.items[1]) or c.items[1].actionId == MIMIC then return 0 end
    local enemies = targetsOf(bfl, ctx.actor, ctx.basic or 0, REL_ENEMIES)
    local alive = {}
    for _, uid in ipairs(enemies) do alive[uid] = true end
    local sum, mult = 0, 1
    for _, it in ipairs(c.items) do
        if it.actionId == MAGIC_BOOST then mult = 2
        elseif it.actionId == BREAK_BOOST then mult = BREAK_VALUE
        else
            local s = info(it.actionId)
            if s and s.damage and s.rel == REL_ENEMIES then
                local part = 0
                for _, uid in ipairs((s.tgt == TGT_GROUP) and enemies or it.targets) do
                    if alive[uid] then
                        local f = factor(bfl, cache, s, uid)
                        if not f then return 0 end
                        part = part + f
                    end
                end
                sum = sum + s.mag * part * mult
            end
            mult = 1
        end
    end
    return sum
end

local IS_FORMATION = {}
for _, id in ipairs(FORMATIONS) do IS_FORMATION[id] = true end

-- Allies an attack buff would reach that lack it: the actor first for a single-target buff,
-- every target for a group buff. nil when nobody lacks it.
local function buffTargets(bfl, ctx, cache, id, s)
    local cands = (s.tgt == TGT_SELF) and { ctx.actor } or targetsOf(bfl, ctx.actor, id, REL_FRIENDLIES)
    local function lacks(uid)
        local st = statuses(bfl, cache, uid)
        for b in pairs(s.buffs) do if not st[b] then return true end end
        return false
    end
    if s.tgt == TGT_SINGLE then
        if contains(cands, ctx.actor) and lacks(ctx.actor) then return { ctx.actor } end
        for _, uid in ipairs(cands) do if lacks(uid) then return { uid } end end
        return nil
    end
    for _, uid in ipairs(cands) do if lacks(uid) then return cands end end
    return nil
end

local function formationActive(bfl, ctx, cache)
    local st = statuses(bfl, cache, ctx.actor)
    for _, id in ipairs(FORMATIONS) do
        local s = info(id)
        if s and s.buffs then for b in pairs(s.buffs) do if st[b] then return true end end end
    end
    return false
end

-- Attack buffs the character can cast now that aren't active yet, in casting order:
-- 轉戰自如之策, then one formation (the best it has, and only while none is active), then the rest.
local function missingBuffs(bfl, ctx, cache)
    local list = {}
    local function try(id)
        local s = info(id)
        if not (ctx.menuOf[id] and ctx.menuOf[id] ~= MENU_LIMIT and s and s.buffs) then return false end
        local c = cost(ctx, id)
        if c > ctx.mp then return false end
        local t = buffTargets(bfl, ctx, cache, id, s)
        if not t then return false end
        list[#list + 1] = { id = id, targets = t, cost = c, buffs = s.buffs }
        return true
    end
    -- 轉戰自如之策 only pays when a formation follows it.
    if not formationActive(bfl, ctx, cache) then
        local n = #list
        try(STRATAGEM)
        local had = #list > n
        local got = false
        for _, id in ipairs(FORMATIONS) do if try(id) then got = true; break end end
        if had and not got then table.remove(list, n + 1) end
    end
    for _, id in ipairs(ctx.skills) do
        if id ~= STRATAGEM and not IS_FORMATION[id] then try(id) end
    end
    -- Two buffs with the same effect (急速 and 大急速): keep the one that reaches more allies.
    local keep = {}
    for i, e in ipairs(list) do
        local drop = false
        for j, f in ipairs(list) do
            if i ~= j and (#f.targets > #e.targets or (#f.targets == #e.targets and j < i)) then
                for b in pairs(e.buffs) do if f.buffs[b] then drop = true end end
            end
        end
        if not drop then keep[#keep + 1] = e end
    end
    return keep
end

local function buffLabel(b)
    return name(b.id) .. " -> " .. ((#b.targets == 1) and ("unit " .. b.targets[1]) or (#b.targets .. " allies"))
end

-- Boss fights: the first missing attack buff. With W臂腕 it takes a second missing buff, else
-- an attack, in the same turn. A Limit Burst the gauge pays for comes first: then only W臂腕
-- with the buff and the limit.
local function planBuff(bfl, ctx, phase, rec, cache, strikes, limits)
    local list = missingBuffs(bfl, ctx, cache)
    local a = list[1]
    if not a then return nil end
    if #limits > 0 then
        return wWithAttack(ctx, phase, rec, strikes, a, buffLabel(a), "buff", limits)
    end
    if has(ctx, W_ARM) then
        local room = ctx.mp - cost(ctx, W_ARM) - a.cost
        for k = 2, #list do
            local b = list[k]
            if b.cost <= room then
                local items = { act(ctx, W_ARM, { ctx.actor }, MENU_SKILLS), act(ctx, a.id, a.targets, ctx.menuOf[a.id]),
                                act(ctx, b.id, b.targets, ctx.menuOf[b.id]) }
                return turn(ctx, phase, rec, items, string.format("buff: %s + %s, %s", name(W_ARM), buffLabel(a), buffLabel(b)))
            end
        end
        local w, wl = wWithAttack(ctx, phase, rec, strikes, a, buffLabel(a), "buff")
        if w then return w, wl end
    end
    return single(ctx, phase, rec, a.id, a.targets), "buff " .. buffLabel(a)
end

-- Any fight: a charge before the character's next attack (only when it has something to hit
-- then). A charge is planned once per two turns.
local function planCharge(ctx, phase, rec, strikes)
    local at = Charged[ctx.actor]
    if at and os.clock() - at < CHARGE_TIME then Charged[ctx.actor] = nil; return nil end
    if #strikes == 0 then return nil end
    local magic = false
    for _, s in ipairs(strikes) do if info(s.id).dmgType == DMG_MAGIC then magic = true end end
    for _, id in ipairs({ CHARGE_ANY, CHARGE_MAGIC }) do
        if has(ctx, id) and (id ~= CHARGE_MAGIC or magic) and cost(ctx, id) <= ctx.mp then
            Charged[ctx.actor] = os.clock()
            return single(ctx, phase, rec, id, { ctx.actor }), "charge " .. name(id)
        end
    end
    return nil
end

-- The recorded command with targets that don't resist its element (or reflect its spell), or
-- nil when it can't avoid one, a spell is blocked by Silence, or MP can't pay for it.
local function avoidResist(bfl, ctx, rec, cache)
    if turnCost(ctx, rec) > ctx.mp then return nil, "mp" end
    local c = { CmdType = rec.CmdType, isNotConsume = rec.isNotConsume, doCalcOrder = rec.doCalcOrder,
                CommandId = rec.CommandId, items = {}, keys = rec.keys, smart = true }
    for i, it in ipairs(rec.items) do
        local n = copyItem(it)
        local s = info(it.actionId)
        if ctx.silenced and s and s.attr == ATTR_MAGIC then return nil, "silence" end
        if s and s.damage and s.rel == REL_ENEMIES and ((s.el and s.el > 0) or s.attr == ATTR_MAGIC) then
            local cands = targetsOf(bfl, ctx.actor, it.actionId, REL_ENEMIES)
            local ok = {}
            for _, uid in ipairs(cands) do
                local good = not (s.el and s.el > 0 and resist(bfl, cache, uid, s.el) >= RES_HALVED)
                if good and not bounces(bfl, cache, s, uid) then ok[#ok + 1] = uid end
            end
            if s.tgt == TGT_SINGLE and not it.IsAll then
                if #ok == 0 then return nil, "resist" end
                local keep = (#it.targets == 1 and contains(ok, it.targets[1])) and it.targets[1] or lowestHp(bfl, ok)
                n.targets, n.fixed = { keep }, true
            elseif #ok < #cands then
                return nil, "resist"
            end
        end
        c.items[i] = n
    end
    return c
end

local function hasItem(c)
    for _, it in ipairs(c.items) do if it.isUseItem then return true end end
    return false
end

-- Returns command, note. command is nil when nothing could be planned (replay then works as in
-- Repeat mode). single is the character's last single ability, tried when the recorded turn
-- can't be used (a W turn without the MP for it).
function M.plan(bfl, actor, phase, rec, single1)
    local cfg = D.cfg()
    local cache = {}
    local ctx = unitContext(bfl, actor, cache)
    local threshold = tonumber(cfg.AutoHealBelow) or 0
    if threshold > 0 then
        local c, why = planHeal(bfl, ctx, phase, rec, threshold, cache)
        if c then return c, why end
    end
    local ce, ewhy = planEther(bfl, ctx, phase, rec, tonumber(cfg.AutoEtherBelow) or 30)
    if ce then return ce, ewhy end
    local strikes = {}
    for _, id in ipairs(ctx.skills) do
        local e = evaluate(bfl, ctx, id, cache)
        if e then
            e.cost = cost(ctx, id)
            if e.cost <= ctx.mp then strikes[#strikes + 1] = e end
        end
    end
    local limits = {}
    if #ctx.limits > 0 and bossFight(bfl, ctx, cache) then
        for _, id in ipairs(ctx.limits) do
            local e = evaluate(bfl, ctx, id, cache)
            if e then
                e.lb = cost(ctx, id)
                if e.lb <= ctx.lb then limits[#limits + 1] = e end
            end
        end
    end
    -- Gauge help and buffs only pay off in long fights (boss fights); charges clear normal fights
    -- faster too.
    if bossFight(bfl, ctx, cache) then
        local l, lwhy = planLimitHelp(bfl, ctx, phase, rec, strikes)
        if l then return l, lwhy end
        local b, bwhy = planBuff(bfl, ctx, phase, rec, cache, strikes, limits)
        if b then return b, bwhy end
    end
    local ch, chwhy = planCharge(ctx, phase, rec, strikes)
    if ch then return ch, chwhy end
    local a, awhy, ascore = planAttack(ctx, phase, rec, strikes, limits)
    -- 模仿 when the turn just decided is worth at least the character's own best: it costs no MP
    -- (never instead of a Limit Burst).
    if #limits == 0 then
        local m = mimicScore(bfl, ctx, cache)
        if m > 0 and m >= (ascore or 0) then
            return single(ctx, phase, rec, MIMIC, { ctx.actor }), string.format("mimic %s (%.0f vs %.0f)", name(MIMIC), m, ascore or 0)
        end
    end
    if a then return a, awhy end
    -- Nothing to attack with (no MP, everything resisted): the recorded turn, else the last single
    -- ability, else a basic attack.
    local reasons = { mp = "not enough MP", silence = "silenced", resist = "would be resisted" }
    local why = "no command to repeat"
    local tries = {}
    if rec then tries[#tries + 1] = rec end
    if single1 and single1 ~= rec then tries[#tries + 1] = single1 end
    for i, r in ipairs(tries) do
        if hasItem(r) then
            why = "last command was an item"
        else
            local c, fail = avoidResist(bfl, ctx, r, cache)
            if c then
                if r == rec then return c, "no attack skill: repeat" end
                return c, "no attack skill, " .. why .. ": last single ability"
            end
            why = "last command " .. (reasons[fail] or "unusable")
        end
    end
    return basicAttack(bfl, ctx, phase, rec), why .. ": basic attack"
end

return M
