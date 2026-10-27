--[[----------------------------------------------------------------------------
    Map markers for chests and shining spots (minimap + world map menu).

    Based on "Item and Chest Markers (Including World Map)" v1.2 (FFR_MapMarkers
    v0.8.1) by ZArkadia: https://www.nexusmods.com/finalfantasyresonance/mods/25
    Used and modified with credit, as its permissions allow. field_items.lua is
    the author's generated list of shining-spot ids.

    Needs the author's pak, zzz_TreasureMinimap_P (in Content/Paks/~mods): it makes
    chests and shining spots show on the minimap and world map. The game keeps those
    markers after looting; this module hides looted ones, gives enemy symbols the
    monster-head icon and "Examine" points a plain dot.

    Changes for FFRS_QoL: an on/off switch (MapMarkers in config.ini). When off, the
    extra markers the pak adds (chests, spots, examine points) are hidden, which
    looks like the unmodded game, and icons are left alone.

    Looted state comes from the save: CPP_BFL_SaveDataMap.IsOpenTreasureBox(mapId, uniqueId).
    Game state is only read; the only writes are marker opacity and icon. All
    timers run on the game thread.
    ----------------------------------------------------------------------------]]

local M = {}

local CONFIG = {
    TICK_MS      = 500,
    MINI_MS      = 50,       -- minimap rescan
    HOLD_MS      = 3000,     -- after a map change, only hide (never un-hide) markers
    ENEMY_ICON   = "UI.Map.Icon.MythicalBeast",   -- monster-head icon
    EXAMINE_ICON = "UI.Map.Icon.Point",           -- small dot, like NPCs
    HIDE_EXAMINE_ON_WORLD_MAP = true,             -- vanilla never lists them there
}

local TAG_TREASURE = "Field.Object.Interact.Type.Treasure"
local TAG_CHECK    = "Field.Object.Interact.Type.Check"
local TYPE_GIMMICK = 2      -- eMapObjectType::Gimmick

local okItems, ITEMS = pcall(require, "field_items")
if not okItems then ITEMS = nil end

local isEnabled = function() return true end
local say = function(fmt, ...) print("[FFRS_QoL] markers: " .. string.format(fmt, ...) .. "\n") end

local faded = {}            -- widget full name -> { widget, opacity before we faded it }
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

local function live(class)
    local out = {}
    for _, o in ipairs(FindAllOf(class) or {}) do
        if valid(o) and not fullName(o):find("Default__", 1, true) then out[#out + 1] = o end
    end
    return out
end

local libs = {}
local function lib(name)
    local o = libs[name]
    if not valid(o) then
        o = StaticFindObject("/Script/mucha.Default__" .. name)
        libs[name] = o
    end
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

-- "treasure" | "spot" (shining spot) | "examine" (other Check gimmick) | "enemy" | nil
local function classify(info, mapId)
    if info.tag == TAG_TREASURE then return "treasure" end
    if info.tag ~= TAG_CHECK then return nil end
    if info.type ~= TYPE_GIMMICK then return "enemy" end
    if not ITEMS then return "spot" end
    local m = mapId and ITEMS[mapId]
    return (m and m[info.id]) and "spot" or "examine"
end

local function looted(info, mapId)
    -- RelatedMapId can point at another map (e.g. a transition target): fallback only
    if mapId == nil and info.mapId and info.mapId >= 0 then mapId = info.mapId end
    return mapId ~= nil and isOpen(mapId, info.id)
end

-- > 0 while the old map's markers may still be on screen
local holdScans = 0

-- keyed by full name: UE4SS hands out a new userdata for the same widget each tick
local function fade(w, hide)
    local key = fullName(w)
    local f = faded[key]
    if hide then
        local ok, op = pcall(function() return w:GetRenderOpacity() end)
        if not f then
            faded[key] = { widget = w, opacity = (ok and op and op > 0) and op or 1.0 }
        end
        if not (ok and op == 0) then w:SetRenderOpacity(0) end
    elseif f and holdScans == 0 then
        w:SetRenderOpacity(f.opacity)
        faded[key] = nil
    end
end

-- Swaps a minimap marker's icon (the game may set it back; the next scan re-applies).
local function setIcon(w, tag)
    local ok, cur = pcall(function() return w.WBP_MapIcon:GetBrushTag().TagName:ToString() end)
    if ok and cur == tag then return end
    local okSet, err = pcall(function() w:SetIconTag({ TagName = FName(tag) }) end)
    if not okSet then logOnce("icon", "SetIconTag failed: %s", tostring(err)) end
end

-- ------------------------------------------------------------------ minimap

local function sameMapId()
    for _, m in ipairs(live("CPP_MapManager")) do
        local ok, id = pcall(function() return m:GetSameMapId() end)
        if ok and type(id) == "number" then return id end
    end
    return nil
end

-- Gimmicks that hid themselves or were used up (e.g. the magic pot after its Ether).
local GONE_CLASSES = { "CPP_MapGimmick_BlockingBase", "BP_MapGimmick_BlockingBase_Child_MagicPot_C" }
local gone, goneMapId = {}, nil

local function scanGone(mapId)
    local ids = {}
    for _, class in ipairs(GONE_CLASSES) do
        for _, a in ipairs(FindAllOf(class) or {}) do
            pcall(function()
                if not valid(a) then return end
                local mesh = a:GetStaticMeshComponent()
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

local lastMapId = nil

local function scanMinimap()
    local on = isEnabled()
    local mapId = sameMapId()
    -- During a map change the id switches while the old markers are still shown.
    if mapId ~= lastMapId then
        lastMapId = mapId
        holdScans = math.ceil(CONFIG.HOLD_MS / CONFIG.MINI_MS)
    elseif holdScans > 0 then
        holdScans = holdScans - 1
    end
    for _, w in ipairs(FindAllOf("WBP_MiniMapEntry_C") or {}) do
        if valid(w) and fullName(w):find("/Engine/Transient", 1, true) then
            local okVm, vm = pcall(function() return w.VM_MiniMapEntry end)
            local info = okVm and valid(vm) and objectInfo(function() return vm.EntryData.ObjectData end) or nil
            local kind = info and classify(info, mapId)
            -- Quest targets (e.g. a quest's enemy) show in the unmodded game too: the
            -- off switch must not hide them.
            local okQ, quest = pcall(function() return vm.EntryData.bIsMarkedQuestTarget end)
            local offHide = (not on) and not (okQ and quest == true)
            if kind == "treasure" or kind == "spot" then
                fade(w, offHide or (on and looted(info, mapId)))
            elseif kind == "examine" then
                fade(w, offHide or (on and goneMapId == mapId and gone[info.id] == true))
                if on then setIcon(w, CONFIG.EXAMINE_ICON) end
            elseif kind == "enemy" then
                -- enemy symbols use the Check type too, so they only show because of the pak
                fade(w, offHide)
                if on then setIcon(w, CONFIG.ENEMY_ICON) end
            else
                fade(w, false)          -- widget may be reused from a hidden marker
            end
        end
    end
end

-- -------------------------------------------------------- world map menu

local function wldMapId()
    for _, s in ipairs(live("CPP_UI_WldMapSubsystem")) do
        local ok, id = pcall(function() return s.WldMapId end)
        if ok and type(id) == "number" and id > 0 then return id end
    end
    return nil
end

local cachedLayouts, cachedWldId = {}, nil

local function scanWorldMap(layouts, mapId)
    local on = isEnabled()
    for _, layout in ipairs(layouts) do
        local widgets = {}
        local ok, err = pcall(function()
            layout.EntryMap:ForEach(function(k, v) widgets[k:get()] = v:get() end)
            layout.ObjectDataCacheMap:ForEach(function(k, v)
                local w = widgets[k:get()]
                local info = objectInfo(function() return v:get() end)
                local kind = info and classify(info, mapId)
                if valid(w) and (kind == "treasure" or kind == "spot") then
                    fade(w, (not on) or looted(info, mapId))
                elseif valid(w) and kind == "examine" then
                    fade(w, (not on) or CONFIG.HIDE_EXAMINE_ON_WORLD_MAP)
                end
            end)
        end)
        if not ok then logOnce("wld", "world map scan failed: %s", tostring(err)) end
    end
end

-- --------------------------------------------------------------------- loops

local function tick()
    openCache = {}
    scanGone(lastMapId)
    cachedLayouts = live("CPP_WBP_WldMap_LandmarkLayout")
    if #cachedLayouts > 0 then
        cachedWldId = wldMapId()
        scanWorldMap(cachedLayouts, cachedWldId)
    end
    for key, f in pairs(faded) do
        if not valid(f.widget) then faded[key] = nil end
    end
end

-- World map menu: rescanned every 16 ms while its layout is visible, so looted
-- markers don't flash when it opens or the region changes.
local FAST_MS, DISCOVER_MS = 16, 50
local sinceSearch = 0
local function visibleLayouts()
    local visible = {}
    for _, layout in ipairs(cachedLayouts) do
        if valid(layout) then
            local okV, vis = pcall(function() return layout:IsVisible() end)
            if okV and vis then visible[#visible + 1] = layout end
        end
    end
    return visible
end
local function fastWorldMap()
    local visible = visibleLayouts()
    if #visible == 0 then
        sinceSearch = sinceSearch + FAST_MS
        if sinceSearch < DISCOVER_MS then return end
        sinceSearch = 0
        cachedLayouts = live("CPP_WBP_WldMap_LandmarkLayout")
        if #cachedLayouts == 0 then return end
        openCache = {}
        cachedWldId = wldMapId()
        visible = visibleLayouts()
        if #visible == 0 then return end
    end
    scanWorldMap(visible, cachedWldId)
end

-- opts.enabled: function returning true while markers should show
-- opts.log: logging function (fmt, ...)
function M.start(opts)
    if opts and opts.enabled then isEnabled = opts.enabled end
    if opts and opts.log then say = function(fmt, ...) opts.log("markers: " .. fmt, ...) end end
    if type(LoopInGameThreadWithDelay) ~= "function" then
        say("needs LoopInGameThreadWithDelay (UE4SS experimental build); markers not managed")
        return false
    end
    LoopInGameThreadWithDelay(CONFIG.TICK_MS, function()
        local ok, err = pcall(tick)
        if not ok then logOnce("tick:" .. tostring(err), "tick error: %s", tostring(err)) end
    end)
    LoopInGameThreadWithDelay(CONFIG.MINI_MS, function()
        local ok, err = pcall(function() openCache = {}; scanMinimap() end)
        if not ok then logOnce("mini:" .. tostring(err), "minimap scan error: %s", tostring(err)) end
    end)
    LoopInGameThreadWithDelay(FAST_MS, function()
        local ok, err = pcall(fastWorldMap)
        if not ok then logOnce("fast:" .. tostring(err), "fast scan error: %s", tostring(err)) end
    end)
    say("started (spot list %s)", ITEMS and "loaded" or "MISSING")
    return true
end

return M
