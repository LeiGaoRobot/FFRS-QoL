-- Smart auto battle for FFRS QoL (loaded by main.lua; used by auto repeat in Smart mode).
-- Picks the acting character's command from the enemies' real elemental resistances, which the
-- game knows even for enemies that were never scanned:
--   1. an ally below the heal threshold -> the strongest affordable single-target heal on them
--   2. a skill that hits a weakness and that no target resists -> the strongest one (a recorded
--      W臂腕 turn keeps its W and uses that skill for both of its attacks)
--   3. otherwise the recorded command, unless a target would halve, nullify, absorb or reflect its
--      element -> then a basic attack (also when there is no record yet)
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
local ST_SILENCE, ST_REFLECT = 4, 32       -- eUnitStatusCondition
local CAT_SKILL = 1                        -- eActionCategory.Skill
local W_ARM = 400650                       -- W臂腕: any two commands
local WEAK_BONUS = 1.5

local D = nil     -- helpers from main.lua (init)
local Info = nil  -- [skillId] = { el, mag, attr, rel, tgt, damage, cmd1, name }

function M.init(deps) D = deps end

local function buildInfo()
    local t = {}
    for _, dt in ipairs(FindAllOf("DataTable") or {}) do
        pcall(function()
            if D.rowStructName(dt) ~= "SKILL_DATA" then return end
            dt:ForEachRow(function(_, row)
                local cmd1 = false
                row.belongCommandList:ForEach(function(_, e) if e:get() == MENU_SKILLS then cmd1 = true end end)
                local okN, name = pcall(function() return row.Name:ToString() end)
                t[row.ID] = {
                    el = row.element, mag = row.magnification or 0, attr = row.skillAttrType,
                    rel = row.defaultTargetRelation, tgt = row.TargetType, cmd1 = cmd1,
                    reflectPen = row.isReflectPenetration and true or false,
                    damage = row.skillEffectType == EFFECT_DAMAGE_RECOVERY and row.parameterType == PARAM_HP
                        and row.parameterVariationType == VAR_DECREASE,
                    name = okN and tostring(name) or tostring(row.ID),
                }
            end)
        end)
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
local function cost(ctx, id, isAll)
    local ok, c = pcall(function()
        if not (skillLib and skillLib:IsValid()) then skillLib = StaticFindObject("/Script/mucha.Default__CPP_BFL_Skill") end
        return skillLib:GetSkillCost(id, ctx.unitId, isAll and true or false)
    end)
    if ok and type(c) == "number" and c >= 0 then return c end
    return math.huge
end

-- MP for a whole recorded turn (a W command costs its own MP plus each ability).
local function turnCost(ctx, c)
    local sum = 0
    for _, it in ipairs(c.items) do
        if not it.isUseItem then sum = sum + cost(ctx, it.actionId, it.IsAll) end
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
    for _, id in ipairs(D.outList(function(t) p:GetActiveSkillListWithVision(t) end)) do
        local s = info(id)
        if s then
            if s.attr == 1 and s.damage and not ctx.basic then ctx.basic = id end   -- 戰鬥
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

-- A damage skill with an element: its weakness score and targets, or nil when it hits no
-- weakness or any target would resist it.
local function evaluate(bfl, ctx, id, cache)
    local s = info(id)
    if not (s and s.damage and s.rel == REL_ENEMIES and s.el and s.el > 0) then return nil end
    if s.tgt ~= TGT_SINGLE and s.tgt ~= TGT_GROUP then return nil end
    local cands = targetsOf(bfl, ctx.actor, id, REL_ENEMIES)
    if #cands == 0 then return nil end
    if s.tgt == TGT_SINGLE then
        local weak = {}
        for _, uid in ipairs(cands) do
            if resist(bfl, cache, uid, s.el) == RES_WEAK and not bounces(bfl, cache, s, uid) then weak[#weak + 1] = uid end
        end
        if #weak == 0 then return nil end
        return { id = id, targets = { lowestHp(bfl, weak) }, score = s.mag * WEAK_BONUS }
    end
    local weak = 0
    for _, uid in ipairs(cands) do
        local r = resist(bfl, cache, uid, s.el)
        if r >= RES_HALVED or bounces(bfl, cache, s, uid) then return nil end
        if r == RES_WEAK then weak = weak + 1 end
    end
    if weak == 0 then return nil end
    return { id = id, targets = cands, score = s.mag * (weak * WEAK_BONUS + (#cands - weak)) }
end

-- Keys are the menu path of every action in order: [cat:menu, cat:skill] per action; a basic
-- attack (no parent menu) and W's own basic attacks (parent = the W skill) add only the skill.
local function buildKeys(c)
    local keys = {}
    for i, it in ipairs(c.items) do
        if it.pCat ~= 0 and not (i > 1 and it.pId == c.items[1].actionId) then keys[#keys + 1] = { it.pCat, it.pId } end
        keys[#keys + 1] = { CAT_SKILL, it.actionId }
    end
    return keys
end
M.buildKeys = buildKeys

local function sameKeys(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i][1] ~= b[i][1] or a[i][2] ~= b[i][2] then return false end
    end
    return true
end

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

-- A recorded W turn with the best weakness skill in place of its attacks.
local function planW(bfl, ctx, rec, best)
    if #rec.items < 2 or not sameKeys(buildKeys(rec), rec.keys) then return nil end
    local head = rec.items[1]
    local hs = info(head.actionId)
    if not hs or hs.tgt ~= TGT_SELF then return nil end
    local bs = info(best.id)
    local c = { CmdType = rec.CmdType, isNotConsume = rec.isNotConsume, doCalcOrder = rec.doCalcOrder,
                CommandId = rec.CommandId, items = { copyItem(head) }, smart = true }
    local total, changed = cost(ctx, head.actionId), 0
    for i = 2, #rec.items do
        local it = rec.items[i]
        local s = info(it.actionId)
        local n = copyItem(it)
        -- Other multi-commands (連續詠唱 and the like) only take certain kinds of skills: there,
        -- swap only for a skill of the same kind.
        local fits = head.actionId == W_ARM or (s and s.attr == bs.attr)
        if s and s.damage and s.rel == REL_ENEMIES and not it.isUseItem and fits then
            n.actionId, n.targets, n.fixed, n.params, n.IsAll = best.id, best.targets, true, {}, false
            n.pCat, n.pId = CAT_SKILL, ctx.menuOf[best.id]
            total, changed = total + best.cost, changed + 1
        else
            if ctx.silenced and s and s.attr == ATTR_MAGIC then return nil end
            total = total + cost(ctx, it.actionId, it.IsAll)
        end
        c.items[i] = n
    end
    if changed == 0 or total > ctx.mp then return nil end
    c.keys = buildKeys(c)
    return c
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
    local best = nil
    for _, id in ipairs(ctx.skills) do
        local e = evaluate(bfl, ctx, id, cache)
        if e then
            e.cost = cost(ctx, id)
            if e.cost <= ctx.mp and (not best or e.score > best.score or (e.score == best.score and e.cost < best.cost)) then best = e end
        end
    end
    if best then
        local target = (#best.targets == 1) and ("unit " .. best.targets[1]) or (#best.targets .. " enemies")
        if rec and #rec.items > 1 and not hasItem(rec) then
            local w = planW(bfl, ctx, rec, best)
            if w then return w, string.format("weakness: %s with %s x2 -> %s", name(rec.items[1].actionId), name(best.id), target) end
        end
        return single(ctx, phase, rec, best.id, best.targets), string.format("weakness: %s -> %s", name(best.id), target)
    end
    -- No weakness: the recorded turn, else the last single ability, else a basic attack.
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
                if r == rec then return c, "no weakness: repeat" end
                return c, "no weakness, " .. why .. ": last single ability"
            end
            why = "last command " .. (reasons[fail] or "unusable")
        end
    end
    return basicAttack(bfl, ctx, phase, rec), why .. ": basic attack"
end

return M
