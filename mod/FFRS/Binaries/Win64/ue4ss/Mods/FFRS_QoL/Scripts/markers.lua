--[[----------------------------------------------------------------------------
    Map markers for chests and shining spots (minimap + world map menu).

    Based on "Item and Chest Markers (Including World Map)" v1.5 (FFR_MapMarkers
    v0.16) by ZArkadia: https://www.nexusmods.com/finalfantasyresonance/mods/25
    Used and modified with credit, as its permissions allow. field_items.lua and
    chest_items.lua are the author's generated lists of shining-spot and chest ids.

    Needs the author's paks in Content/Paks/~mods:
      zzz_TreasureMinimap_P   chests, shining spots and exits show on the minimap
                              and the world map menu
      zzz_RevealHiddenAreas_P hidden paths show on the map (pak only, no Lua)
    The game keeps chest/spot markers after looting. This module:
      * hides looted chests and shining spots, and gimmicks that are used up
        (e.g. the magic pot after its Ether)
      * gives enemy symbols the monster-head icon, "Examine" points a plain dot
      * door hint: an exit whose target map still has unopened chests or spots
        gets the chest icon; other exits stay hidden as in the unmodded game
      * hides quest/story Check points the pak would otherwise show

    Changes for FFRS_QoL:
      * on/off switch (MapMarkers in config.ini). When off, every marker the pak
        adds is hidden, which looks like the unmodded game, and icons are left alone.
      * quest targets (EntryData.bIsMarkedQuestTarget) are never hidden.
      * no F10 key poll and no frame-time logging; M.dump() / M.stats() are there
        for dev evals.

    Looted state comes from the save: CPP_BFL_SaveDataMap.IsOpenTreasureBox(mapId, uniqueId).
    Game state is only read; the only writes are marker opacity and icon. All
    timers run on the game thread. No game object is kept between ticks: UE4SS
    IsValid can say true for freed memory, so only numbers and strings are cached.
    ----------------------------------------------------------------------------]]

local M = {}

local CONFIG = {
    TICK_MS         = 500,
    MINI_MS         = 250,      -- minimap pass (remembered markers cost one call each)
    MINI_REVALIDATE = 8,        -- markers fully re-read per pass, round-robin
    HOLD_MS         = 3000,     -- after a map change, only hide (never un-hide) markers
    ENEMY_ICON      = "UI.Map.Icon.MythicalBeast",   -- monster-head icon
    EXAMINE_ICON    = "UI.Map.Icon.Point",           -- small dot, like NPCs
    DOOR_HINT       = true,
    DOOR_ICON       = "UI.Map.Icon.TreasureBox",
    DOOR_SKIP       = { [1000] = true },   -- save map ids never hinted (world map)
}

local TAG_TREASURE   = "Field.Object.Interact.Type.Treasure"
local TAG_CHECK      = "Field.Object.Interact.Type.Check"
local TAG_TRANSITION = "Field.Object.Interact.Type.Transition"
local TYPE_GIMMICK   = 2        -- eMapObjectType::Gimmick
-- eMapObjectType None / NPC / EncountArea: enemy symbols and field bosses. Other
-- Check types (DestinationArea / TransitionPoint / Point) are quest and story points.
local ENEMY_TYPES = { [0] = true, [1] = true, [4] = true }

-- save map id -> { [uniqueId] = true } for every shining spot
local okItems, ITEMS = pcall(require, "field_items")
if not (okItems and type(ITEMS) == "table") then ITEMS = nil end

-- chest ids per map id, and map id -> save map id for maps sharing a save list
local okChests, CHESTS = pcall(require, "chest_items")
if not (okChests and type(CHESTS) == "table") then okChests, CHESTS = false, { chests = {}, alias = {} } end
CHESTS.chests, CHESTS.alias = CHESTS.chests or {}, CHESTS.alias or {}
local function saveOf(mapId) return CHESTS.alias[mapId] or mapId end
local LOOT = {}                 -- save map id -> { [uniqueId] = true }: chests + spots
for m, ids in pairs(CHESTS.chests) do
    local s = saveOf(m)
    LOOT[s] = LOOT[s] or {}
    for _, id in ipairs(ids) do LOOT[s][id] = true end
end
for s, ids in pairs(ITEMS or {}) do
    LOOT[s] = LOOT[s] or {}
    for id in pairs(ids) do LOOT[s][id] = true end
end

local isEnabled = function() return true end
local say = function(fmt, ...) print("[FFRS_QoL] markers: " .. string.format(fmt, ...) .. "\n") end

local faded = {}                -- widget address -> { opacity before we faded it, cls = class name }
local logged = {}

local function logOnce(key, fmt, ...)
    if logged[key] then return end
    logged[key] = true
    say(fmt, ...)
end

local function valid(o)
    if type(o) ~= "userdata" then return false end
    local ok, r = pcall(function() return o:IsValid() end)
    return ok and r == true
end

local function fullName(o)
    local ok, s = pcall(function() return o:GetFullName() end)
    return ok and s or ""
end

-- short object name check (GetFullName walks every outer and is much slower)
local function isCDO(o)
    local ok, n = pcall(function() return o:GetFName():ToString() end)
    return not ok or type(n) ~= "string" or n:find("Default__", 1, true) == 1
end

local function live(class)
    local out = {}
    for _, o in ipairs(FindAllOf(class) or {}) do
        if not isCDO(o) then out[#out + 1] = o end
    end
    return out
end

-- looked up on every call (a hash lookup), never kept
local function lib(name)
    local o = StaticFindObject("/Script/mucha.Default__" .. name)
    return valid(o) and o or nil
end

-- { tag, type, id, mapId } from the FFieldObjectCoreData that getOd() returns
local function objectInfo(getOd)
    local ok, info = pcall(function()
        local od = getOd()
        return {
            tag   = od.InteractTag.TagName:ToString(),
            type  = od.TypeData.Type,
            id    = od.TypeData.ID,
            mapId = od.RelatedMapId,
        }
    end)
    if not ok then logOnce("info", "object data not readable: %s", tostring(info)) end
    return ok and info or nil
end

local openCache = {}
local function isOpen(mapId, uid)
    local key = mapId .. ":" .. uid
    if openCache[key] == nil then
        local save = lib("CPP_BFL_SaveDataMap")
        local ok, r = pcall(function() return save:IsOpenTreasureBox(mapId, uid) end)
        if not ok then logOnce("open", "IsOpenTreasureBox failed: %s", tostring(r)) end
        openCache[key] = ok and r == true
    end
    return openCache[key]
end

-- "treasure" | "spot" | "examine" | "enemy" | "door" | "other" (quest/story point)
-- | nil (not ours: left alone)
local function classify(info, mapId)
    if info.tag == TAG_TREASURE then return "treasure" end
    if info.tag == TAG_TRANSITION then return "door" end
    if info.tag ~= TAG_CHECK then return nil end
    if info.type ~= TYPE_GIMMICK then return ENEMY_TYPES[info.type] and "enemy" or "other" end
    if not ITEMS then return "spot" end
    local m = mapId and ITEMS[mapId]
    return (m and m[info.id]) and "spot" or "examine"
end

local function looted(info, mapId)
    -- RelatedMapId can point at another map (e.g. a transition target): fallback only
    if mapId == nil and info.mapId and info.mapId >= 0 then mapId = info.mapId end
    return mapId ~= nil and isOpen(mapId, info.id)
end

-- Door hint. doorTargets (transition unique id -> target map id) is rebuilt by the
-- 500 ms tick and holds numbers only; doorLoot caches per target until then.
local doorTargets, doorLoot = {}, {}
local curMapId, prevMapId = nil, nil    -- the map you are in, the one before

local function hasLoot(target)
    local s = saveOf(target)
    if doorLoot[s] == nil then
        local found = false
        for id in pairs(LOOT[s] or {}) do
            if not isOpen(s, id) and not (target ~= s and isOpen(target, id)) then
                found = true
                break
            end
        end
        doorLoot[s] = found
    end
    return doorLoot[s]
end

-- target map id of a door that should get the chest icon, else nil. Skipped: the
-- world map (as target or as the current map), the current map, the previous map.
local function doorHint(info)
    if not CONFIG.DOOR_HINT then return nil end
    local target = doorTargets[info.id]
    if not target and type(info.mapId) == "number" and info.mapId >= 0 then target = info.mapId end
    if type(target) ~= "number" or target < 0 then return nil end
    local s = saveOf(target)
    if CONFIG.DOOR_SKIP[s] or CONFIG.DOOR_SKIP[curMapId] or s == curMapId or s == prevMapId then return nil end
    return hasLoot(target) and target or nil
end

local function scanDoors()
    local t = {}
    for _, cls in ipairs({ "CPP_MapTransitionTrigger", "BP_MapTransitionTrigger_C" }) do
        for _, a in ipairs(FindAllOf(cls) or {}) do
            pcall(function()
                if isCDO(a) or not valid(a) then return end
                if a.m_IsSameMapTrasition then return end       -- stairs etc. inside one map
                local uid, map = a.m_UniqueId, a.m_MapId
                if type(uid) == "number" and type(map) == "number" then t[uid] = map end
            end)
        end
    end
    doorTargets, doorLoot = t, {}
end

-- while the old map's markers may still be on screen: only hide
local holdUntil = 0
local function holding() return os.clock() < holdUntil end

-- keyed by address: UE4SS hands out a new userdata for the same widget each tick
local function fade(w, hide, key, cls)
    key = key or w:GetAddress()
    local f = faded[key]
    if hide then
        local ok, op = pcall(function() return w:GetRenderOpacity() end)
        if not f then
            if not cls then
                local okC, c = pcall(function() return w:GetClass():GetFName():ToString() end)
                cls = okC and c or nil
            end
            faded[key] = { opacity = (ok and op and op > 0) and op or 1.0, cls = cls }
        end
        if not (ok and op == 0) then w:SetRenderOpacity(0) end
    elseif f and not holding() then
        w:SetRenderOpacity(f.opacity)
        faded[key] = nil
    end
end

-- swaps a minimap marker's icon (the game may set it back; a later pass re-applies)
local function setIcon(w, tag)
    local ok, cur = pcall(function() return w.WBP_MapIcon:GetBrushTag().TagName:ToString() end)
    if ok and cur == tag then return end
    local okSet, err = pcall(function() w:SetIconTag({ TagName = FName(tag) }) end)
    if not okSet then logOnce("icon", "SetIconTag failed: %s", tostring(err)) end
end

local function newStats()
    return { mini = 0, loot = 0, hidden = 0, enemy = 0, examine = 0, gone = 0, other = 0, door = 0, quest = 0 }
end

-- ------------------------------------------------------------------ minimap

local function sameMapId()
    for _, m in ipairs(live("CPP_MapManager")) do
        local ok, id = pcall(function() return m:GetSameMapId() end)
        if ok and type(id) == "number" then return id end
    end
    return nil
end

-- Unique ids of gimmicks in the loaded map that hid themselves or were used up.
-- Rebuilt by the 500 ms tick, and only while an examine marker is on the minimap.
local GONE_CLASSES = { "CPP_MapGimmick_BlockingBase", "BP_MapGimmick_BlockingBase_Child_MagicPot_C" }
local gone, goneMapId = {}, nil
local gimUid = {}               -- gimmick address -> m_UniqueId; cleared on map change and every 10 s
local examineIds = {}           -- unique ids of the examine markers in the last minimap pass

local function scanGone(mapId)
    local ids = {}
    if next(examineIds) == nil then gone, goneMapId = ids, mapId; return end
    -- a used-up interactable (lowered ladder, fought spot...) is hidden or has interact type None
    for _, a in ipairs(FindAllOf("CPP_MapGimmick") or {}) do
        pcall(function()
            if not valid(a) then return end
            local at = a:GetAddress()
            local uid = gimUid[at]
            if uid == nil then uid = a.m_UniqueId; gimUid[at] = uid end
            if examineIds[uid] and (a.bHidden or a.interactType == 0) then ids[uid] = true end
        end)
    end
    for _, class in ipairs(GONE_CLASSES) do
        for _, a in ipairs(FindAllOf(class) or {}) do
            pcall(function()
                if not valid(a) then return end
                local mesh = a:GetStaticMeshComponent()
                -- the pot keeps its mesh; once fed, its BP turns off the sparkle + light
                local okFx, fx = pcall(function() return a.NS_EF_BG_00Common_Magipot_001 end)
                local fxOff = okFx and valid(fx) and not fx:IsVisible()
                if a.bHidden or fxOff or (valid(mesh) and not mesh:IsVisible()) then
                    ids[a.m_UniqueId] = true
                end
            end)
        end
    end
    gone, goneMapId = ids, mapId
end

local lastMapId, lastMini = nil, newStats()
local lastOn = nil              -- switch state the memo / world map entries were built for

-- A marker's data is read once and remembered: memo[widget address] =
-- { info, kind, quest, hide } (plain values only), or false for a class template.
-- New markers, and MINI_REVALIDATE markers per pass round-robin, are fully re-read.
-- The memo is cleared on every map change and when the switch changes.
local memo, rr = {}, 0

-- what a marker should look like now: hide, icon tag (nil = leave the icon alone)
local function decide(m, mapId, on)
    local k, info = m.kind, m.info
    if k == nil then return false, nil end      -- not ours: un-hide (widget may be reused)
    if m.quest then                             -- quest targets show in the unmodded game too
        return false, (on and k == "enemy") and CONFIG.ENEMY_ICON or nil
    end
    if not on then return true, nil end
    if k == "treasure" or k == "spot" then return looted(info, mapId), nil end
    if k == "examine" then return goneMapId == mapId and gone[info.id] == true, CONFIG.EXAMINE_ICON end
    if k == "other" then return true, nil end
    if k == "door" then
        local hint = doorHint(info)
        return not hint, hint and CONFIG.DOOR_ICON or nil
    end
    if k == "enemy" then return false, CONFIG.ENEMY_ICON end
    return false, nil
end

-- an un-hide is held back while holding(); m.hide then stays true so a later pass retries
local function applied(hide, key) return hide or (holding() and faded[key] ~= nil) end

local MINI_CLS = "WBP_MiniMapEntry_C"

local function process(w, key, m, mapId, full, on)
    if full or not m then
        local okVm, vm = pcall(function() return w.VM_MiniMapEntry end)
        local info, quest = nil, false
        if okVm and valid(vm) then
            info = objectInfo(function() return vm.EntryData.ObjectData end)
            local okQ, q = pcall(function() return vm.EntryData.bIsMarkedQuestTarget end)
            quest = okQ and q == true
        end
        m = { info = info, kind = info and classify(info, mapId), quest = quest }
        local hide, icon = decide(m, mapId, on)
        fade(w, hide, key, MINI_CLS)
        if icon then setIcon(w, icon) end
        m.hide = applied(hide, key)
        return m
    end
    local hide, icon = decide(m, mapId, on)     -- Lua tables + cached save lookups only
    if hide ~= m.hide then
        fade(w, hide, key, MINI_CLS)
        m.hide = applied(hide, key)
        if icon then setIcon(w, icon) end       -- door hint switched on
    end
    return m
end

local function tally(stats, exIds, m)
    stats.mini = stats.mini + 1
    local k = m.kind
    if m.quest then stats.quest = stats.quest + 1 end
    if k == "treasure" or k == "spot" then
        stats.loot = stats.loot + 1
        if m.hide then stats.hidden = stats.hidden + 1 end
    elseif k == "examine" then
        stats.examine = stats.examine + 1
        exIds[m.info.id] = true
        if m.hide then stats.gone = stats.gone + 1 end
    elseif k == "other" then
        stats.other = stats.other + 1
    elseif k == "door" then
        if not m.hide then stats.door = stats.door + 1 end
    elseif k == "enemy" then
        stats.enemy = stats.enemy + 1
    end
end

local wldDone                   -- world map entries (declared here, reset on a switch change)

local function scanMinimap()
    local on = isEnabled() and true or false
    if on ~= lastOn then
        lastOn = on
        memo, wldDone = {}, {}
    end
    local mapId = sameMapId()
    -- during a map change the id switches while the old markers are still shown
    if mapId ~= lastMapId then
        lastMapId = mapId
        holdUntil = os.clock() + CONFIG.HOLD_MS / 1000
        doorTargets, doorLoot = {}, {}
        memo, gimUid = {}, {}
        if mapId and mapId ~= curMapId then curMapId, prevMapId = mapId, curMapId end
    end
    local stats, exIds, seen = newStats(), {}, {}
    stats.mapId = mapId
    local list = FindAllOf(MINI_CLS) or {}
    local n = math.max(#list, 1)
    for i, w in ipairs(list) do
        local key = w:GetAddress()
        -- a widget being destroyed (HUD teardown at a battle) is skipped and not
        -- marked seen, so its memo entry goes too (upstream v0.16 crash fix)
        if valid(w) then
            local m = memo[key]
            if m == nil and not fullName(w):find("/Engine/Transient", 1, true) then
                m = false
                memo[key] = false
            end
            seen[key] = true
            if m ~= false then
                local full = (i - 1 - rr) % n < CONFIG.MINI_REVALIDATE
                local ok, r = pcall(process, w, key, m, mapId, full, on)
                if ok then
                    memo[key] = r
                    tally(stats, exIds, r)
                else
                    memo[key] = nil
                    logOnce("mark:" .. tostring(r), "minimap marker error: %s", tostring(r))
                end
            end
        end
    end
    rr = (rr + CONFIG.MINI_REVALIDATE) % n
    for key in pairs(memo) do if not seen[key] then memo[key] = nil end end
    lastMini, examineIds = stats, exIds
end

-- -------------------------------------------------------- world map menu

local function wldMapId()
    for _, s in ipairs(live("CPP_UI_WldMapSubsystem")) do
        local ok, id = pcall(function() return s.WldMapId end)
        if ok and type(id) == "number" and id > 0 then return id end
    end
    return nil
end

-- The menu's markers are handled once per opening. wldDone: marker id ->
-- { a = widget address, loot, hide }. A rescan reads only markers that are new or
-- got a new widget, and puts opacity 0 back on hidden ones if something reset it.
local cachedWldId, lastWld = nil, { wld = 0, wldHidden = 0 }
wldDone = {}

local function scanWorldMap(layouts, mapId, verify, on)
    for _, layout in ipairs(layouts) do
        local widgets = {}
        local ok, err = pcall(function()
            layout.EntryMap:ForEach(function(k, v) widgets[k:get()] = v:get() end)
            layout.ObjectDataCacheMap:ForEach(function(k, v)
                local id = k:get()
                local w = widgets[id]
                if not valid(w) then return end
                local a = w:GetAddress()
                local d = wldDone[id]
                if d and d.a == a then
                    if d.hide and verify then
                        local okO, op = pcall(function() return w:GetRenderOpacity() end)
                        if okO and op ~= 0 then w:SetRenderOpacity(0) end
                    end
                    return
                end
                local info = objectInfo(function() return v:get() end)
                local kind = info and classify(info, mapId)
                d = { a = a }
                if kind == "treasure" or kind == "spot" then
                    d.loot = true
                    d.hide = (not on) or looted(info, mapId)
                    fade(w, d.hide)
                elseif kind then
                    -- only items here: the list is static, so an NPC, field boss or
                    -- quest point would keep its "!" before and after its quest
                    d.hide = true
                    fade(w, true)
                end
                wldDone[id] = d
            end)
        end)
        if not ok then logOnce("wld", "world map scan failed: %s", tostring(err)) end
    end
    local s = { wld = 0, wldHidden = 0, wldId = mapId }
    for _, d in pairs(wldDone) do
        if d.loot then
            s.wld = s.wld + 1
            if d.hide then s.wldHidden = s.wldHidden + 1 end
        end
    end
    lastWld = s
end

-- Checked every 100 ms. Layouts are found fresh on every pass and never kept
-- (a kept layout that was garbage collected crashed upstream v0.8.1). An open
-- menu is rescanned when its marker count changes (a chunk was added), when the
-- switch changes, or every FULL_MS.
local FAST_MS, FULL_MS = 100, 1000
local wasVisible, lastCount, sinceFull, wldOn = false, -1, 0, nil
local function fastWorldMap()
    local visible = {}
    for _, layout in ipairs(FindAllOf("CPP_WBP_WldMap_LandmarkLayout") or {}) do
        local okN, n = pcall(function() return layout:GetFName():ToString() end)
        if okN and type(n) == "string" and not n:find("Default__", 1, true) and valid(layout) then
            local okV, vis = pcall(function() return layout:IsVisible() end)
            if okV and vis then visible[#visible + 1] = layout end
        end
    end
    if #visible == 0 then
        wasVisible = false
        return
    end
    local on = isEnabled() and true or false
    local count = 0
    for _, layout in ipairs(visible) do
        pcall(function() layout.EntryMap:ForEach(function() count = count + 1 end) end)
    end
    sinceFull = sinceFull + FAST_MS
    if not wasVisible or on ~= wldOn then      -- menu just opened or switch changed
        wasVisible, wldOn = true, on
        openCache, wldDone = {}, {}
        cachedWldId = wldMapId()
    elseif count == lastCount and sinceFull < FULL_MS then
        return
    else
        local id = wldMapId()
        if id ~= cachedWldId then cachedWldId, wldDone = id, {} end
    end
    local verify = sinceFull >= FULL_MS
    lastCount, sinceFull = count, 0
    scanWorldMap(visible, cachedWldId, verify, on)
end

-- --------------------------------------------------------------------- loop

-- gimmicks every 8th tick (4 s) or right after a map change; doors once per map
-- (retried every 2 s while none found) and every 10 s; faded-widget cleanup every 10 s
local tickN, doorsFor = 0, nil
local function tick()
    openCache = {}
    tickN = tickN + 1
    if tickN % 8 == 0 or goneMapId ~= lastMapId then scanGone(lastMapId) end
    if tickN % 20 == 0 or doorsFor ~= lastMapId or (next(doorTargets) == nil and tickN % 4 == 0) then
        doorsFor = lastMapId
        scanDoors()
    end
    -- forget faded widgets that FindAllOf no longer lists (kept addresses are never called)
    if tickN % 20 == 0 then
        gimUid = {}
        local alive = {}
        for key, f in pairs(faded) do
            local cls = f.cls
            if cls and not alive[cls] then
                alive[cls] = {}
                for _, o in ipairs(FindAllOf(cls) or {}) do alive[cls][o:GetAddress()] = true end
            end
            if not (cls and alive[cls][key]) then faded[key] = nil end
        end
    end
end

-- ----------------------------------------------------------------- dev tools

-- one line with the current marker counts
function M.stats()
    local s, w = lastMini, lastWld
    return string.format("on %s | minimap: %d markers, %d chest/spot, %d looted hidden, %d enemy, %d examine (%d gone), %d quest/story hidden, %d quest targets, %d door hints | world map: %d chest/spot, %d looted hidden | mapId %s wldMapId %s | lists: spots %s, chests %s",
        tostring(lastOn), s.mini, s.loot, s.hidden, s.enemy, s.examine, s.gone, s.other, s.quest, s.door,
        w.wld, w.wldHidden, tostring(s.mapId), tostring(w.wldId),
        ITEMS and "loaded" or "MISSING", okChests and "loaded" or "MISSING")
end

-- every marker and map gimmick right now, as lines (read only)
function M.dump()
    local out = {}
    local function add(fmt, ...) out[#out + 1] = string.format(fmt, ...) end
    local function num(v) return type(v) == "number" and string.format("%g", v) or tostring(v) end
    local mapId = sameMapId()
    add("mapId %s, current %s, previous %s", tostring(mapId), tostring(curMapId), tostring(prevMapId))
    for _, w in ipairs(FindAllOf(MINI_CLS) or {}) do
        if valid(w) and fullName(w):find("/Engine/Transient", 1, true) then
            local okVm, vm = pcall(function() return w.VM_MiniMapEntry end)
            local info = okVm and valid(vm) and objectInfo(function() return vm.EntryData.ObjectData end) or nil
            if info then
                local okQ, q = pcall(function() return vm.EntryData.bIsMarkedQuestTarget end)
                local okO, op = pcall(function() return w:GetRenderOpacity() end)
                add("mini %s type %s id %s related %s quest %s opacity %s kind %s door-target %s hint %s",
                    (info.tag:gsub("^Field%.Object%.Interact%.Type%.", "")), num(info.type), num(info.id),
                    num(info.mapId), okQ and tostring(q) or "?", okO and num(op) or "?",
                    tostring(classify(info, mapId)), tostring(doorTargets[info.id]),
                    tostring(info.tag == TAG_TRANSITION and doorHint(info) or nil))
            end
        end
    end
    for _, a in ipairs(FindAllOf("CPP_MapGimmick_TreasureBox") or {}) do
        pcall(function()
            if not valid(a) or isCDO(a) then return end
            add("chest id %s type id %s open %s save-open %s", num(a.m_Id), num(a.TypeData.ID),
                tostring(a.m_IsOpen), mapId and tostring(isOpen(mapId, a.m_Id)) or "?")
        end)
    end
    for uid, map in pairs(doorTargets) do
        local s = saveOf(map)
        add("door uid %s -> map %s (save %s) loot ids %s unopened %s", num(uid), num(map), num(s),
            tostring(LOOT[s] ~= nil), tostring(hasLoot(map)))
    end
    return table.concat(out, "\n")
end

-- ---------------------------------------------------------------------- start

-- opts.enabled: function returning true while markers should show
-- opts.log: logging function (fmt, ...)
function M.start(opts)
    if opts and opts.enabled then isEnabled = opts.enabled end
    if opts and opts.log then say = function(fmt, ...) opts.log("markers: " .. fmt, ...) end end
    if type(LoopInGameThreadWithDelay) ~= "function" then
        say("needs LoopInGameThreadWithDelay (UE4SS experimental build); markers not managed")
        return false
    end
    local function guarded(name, fn)
        return function()
            local ok, err = pcall(fn)
            if not ok then logOnce(name .. ":" .. tostring(err), "%s error: %s", name, tostring(err)) end
        end
    end
    LoopInGameThreadWithDelay(CONFIG.TICK_MS, guarded("tick", tick))
    LoopInGameThreadWithDelay(CONFIG.MINI_MS, guarded("minimap", scanMinimap))
    LoopInGameThreadWithDelay(FAST_MS, guarded("worldmap", fastWorldMap))
    say("started (based on Item and Chest Markers v1.5; spot list %s, chest list %s)",
        ITEMS and "loaded" or "MISSING", okChests and "loaded" or "MISSING")
    return true
end

return M
