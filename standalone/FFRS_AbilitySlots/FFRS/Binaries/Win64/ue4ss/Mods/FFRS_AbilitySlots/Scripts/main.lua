-- FFRS_AbilitySlots: more ability slots (and optional extra ability AP) for FINAL FANTASY RESONANCE.
-- The ability-slot part of FFRS_QoL as a mod of its own. Settings live in ../config.ini and are
-- read again every 3 seconds. If FFRS_QoL is installed and enabled, this mod does nothing: FFRS_QoL
-- has the same settings (AbilitySlots, APCapacityBonus) and the two would fight over them.

local TAG = "[FFRS_AbilitySlots] "
local function log(fmt, ...) print(TAG .. string.format(fmt, ...) .. "\n") end

local MIN_SLOTS, MAX_SLOTS = 8, 16

-- Timers on the game thread (LoopAsync runs Lua on another thread and is unsafe with UObjects).
local function gameLoop(ms, fn)
    local function safe()
        local ok, err = pcall(fn)
        if not ok then log("timer error: %s", tostring(err)) end
    end
    if LoopInGameThreadWithDelay then return LoopInGameThreadWithDelay(ms, safe) end
    LoopAsync(ms, function() ExecuteInGameThread(safe); return false end)
end

-- Mod folder (parent of Scripts/), from this script's own path.
local function modDir()
    local ok, info = pcall(function() return debug.getinfo(1, "S") end)
    local src = (ok and info and info.source) or ""
    src = src:gsub("^@", ""):gsub("\\", "/")
    local dir = src:match("^(.*)/[Ss]cripts/[^/]*$")
    return dir or "Mods/FFRS_AbilitySlots"
end
local MOD_DIR = modDir()
local MODS_DIR = MOD_DIR:match("^(.*)/[^/]+$") or "Mods"

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

-- FFRS_QoL counts as installed when its script is there and UE4SS will load it: an enabled.txt in
-- its folder, or "FFRS_QoL : 1" in mods.txt.
local function qolEnabled()
    if not readFile(MODS_DIR .. "/FFRS_QoL/Scripts/main.lua") then return false end
    if readFile(MODS_DIR .. "/FFRS_QoL/enabled.txt") then return true end
    local list = readFile(MODS_DIR .. "/mods.txt") or ""
    for line in list:gmatch("[^\r\n]+") do
        local v = line:match("^%s*FFRS_QoL%s*:%s*(%d+)")
        if v then return v == "1" end
    end
    return false
end

if qolEnabled() then
    log("FFRS_QoL is installed and enabled; it has the same ability slot settings, so this mod does nothing. "
        .. "Set AbilitySlots in FFRS_QoL instead, or disable one of the two.")
    return
end

------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------
local cfg = { Slots = 12, APBonus = 0, FitPanel = true }
local lastText = nil

local function clampInt(v, lo, hi, def)
    v = tonumber(v)
    if not v then return def end
    v = math.floor(v + 0.5)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function loadConfig()
    local text = readFile(MOD_DIR .. "/config.ini")
    if not text or text == lastText then return false end
    lastText = text
    local raw = {}
    for line in text:gmatch("[^\r\n]+") do
        local k, v = line:match("^%s*([%w_]+)%s*=([^;#]*)")
        if k then raw[k] = v:match("^%s*(.-)%s*$") end
    end
    cfg.Slots = clampInt(raw.Slots, MIN_SLOTS, MAX_SLOTS, 12)
    cfg.APBonus = clampInt(raw.APBonus, 0, 9999, 0)
    local fp = raw.FitPanel and raw.FitPanel:lower()
    cfg.FitPanel = not (fp == "false" or fp == "0" or fp == "off" or fp == "no")
    log("settings: Slots=%d APBonus=%d FitPanel=%s", cfg.Slots, cfg.APBonus, tostring(cfg.FitPanel))
    return true
end

------------------------------------------------------------------------
-- Slots and AP. Every character's base values come from the UNIT_PARAMETER_CALC_DATA table:
-- maxAciontListNum (8) is the number of ability slots and baseSkillEquipCost the ability AP limit.
-- The game copies them into each character when a save is loaded, so a change shows after loading a
-- save. The equipment screen lets you equip into any slot below maxAciontListNum. Lowering it keeps
-- abilities already equipped in the extra slots (the game never drops them); they can be unequipped.
------------------------------------------------------------------------
local origSlots, origAP = {}, {}
local applied = ""

local function calcTables()
    local out = {}
    for _, dt in ipairs(FindAllOf("DataTable") or {}) do
        pcall(function()
            if not dt:IsValid() then return end
            local s = dt:GetRowStruct()
            if s and s:IsValid() and s:GetFName():ToString() == "UNIT_PARAMETER_CALC_DATA" then
                out[#out + 1] = { dt = dt, path = dt:GetFullName() }
            end
        end)
    end
    return out
end

local function applyTables()
    local rows, slotsNow, apNow = 0, nil, nil
    for _, t in ipairs(calcTables()) do
        t.dt:ForEachRow(function(rowName, row)
            local key = t.path .. "|" .. rowName
            local s = origSlots[key]
            if not s then s = row.maxAciontListNum; origSlots[key] = s end
            local slots = math.max(s, cfg.Slots)
            if row.maxAciontListNum ~= slots then row.maxAciontListNum = slots end
            local a = origAP[key]
            if not a then a = row.baseSkillEquipCost; origAP[key] = a end
            local ap = a + cfg.APBonus
            if row.baseSkillEquipCost ~= ap then row.baseSkillEquipCost = ap end
            rows, slotsNow, apNow = rows + 1, slots, ap
        end)
    end
    local now = string.format("%d row(s), slots %s, AP %s", rows, tostring(slotsNow), tostring(apNow))
    if rows > 0 and now ~= applied then
        applied = now
        log("character table: %s (load a save to see changes)", now)
    end
end

------------------------------------------------------------------------
-- Equipment screen fit. The right-hand panel lists the equipment rows, the Vision and the ability
-- rows, each 40 units high plus 8 units of spacing, with room for about 12 rows. With more rows,
-- every equipment and ability row gets the same smaller height; if even the smallest rows don't fit,
-- the Vision row (64 units) shrinks to 20 too. Only heights that differ are written.
------------------------------------------------------------------------
local FIT_ROOM, FIT_GAP, FIT_MIN, FIT_MAX = 612, 8, 22, 40
local VISION_H, VISION_MIN = 64, 20
local Fit = { lists = {}, nextScan = 0, last = "" }

local function widgetClass(w)
    local ok, n = pcall(function() return w:GetClass():GetFName():ToString() end)
    return ok and n or ""
end
local function collectWidgets(w, want, acc, seen, depth)
    if depth > 10 or not (w and w:IsValid()) then return end
    if widgetClass(w) == want then
        local a = w:GetAddress()
        if not seen[a] then seen[a] = true; acc[#acc + 1] = w end
        return
    end
    local okN, n = pcall(function() return w:GetChildrenCount() end)
    if okN and n then for i = 0, n - 1 do collectWidgets(w:GetChildAt(i), want, acc, seen, depth + 1) end end
    local okT, root = pcall(function() return w.WidgetTree.RootWidget end)
    if okT and root and root:IsValid() then collectWidgets(root, want, acc, seen, depth + 1) end
end
local function firstSizeBox(w, depth)
    depth = depth or 0
    if depth > 8 or not (w and w:IsValid()) then return nil end
    if widgetClass(w) == "SizeBox" then return w end
    local okN, n = pcall(function() return w:GetChildrenCount() end)
    if okN and n then
        for i = 0, n - 1 do local r = firstSizeBox(w:GetChildAt(i), depth + 1); if r then return r end end
    end
    local okT, root = pcall(function() return w.WidgetTree.RootWidget end)
    if okT and root and root:IsValid() then return firstSizeBox(root, depth + 1) end
    return nil
end
local function visibleOnly(t)
    local r = {}
    for _, w in ipairs(t) do if w:IsVisible() then r[#r + 1] = w end end
    return r
end

local function fitEquipmentPanel(list)
    local box = list:GetParent()                       -- VerticalBox_List: item list, Vision, abilities
    if not (box and box:IsValid()) then return end
    local items, skills = {}, {}
    collectWidgets(box:GetChildAt(0), "WBP_UnitEquippedItemEntry_C", items, {}, 0)
    collectWidgets(list, "WBP_UnitEquippedSkillEntry_C", skills, {}, 0)
    items, skills = visibleOnly(items), visibleOnly(skills)
    local rows = #items + #skills
    if rows == 0 then return end
    local room, vh = FIT_ROOM, VISION_H
    if rows * (FIT_MIN + FIT_GAP) > FIT_ROOM then room, vh = FIT_ROOM + VISION_H - VISION_MIN, VISION_MIN end
    local h = math.floor(room / rows) - FIT_GAP
    if h > FIT_MAX then h = FIT_MAX end
    if h < FIT_MIN then h = FIT_MIN end
    local vsb = firstSizeBox(box:GetChildAt(1))
    if vsb and vsb:GetFName():ToString() == "SizeBox_0" and math.abs((vsb.HeightOverride or 0) - vh) > 0.01 then
        vsb:SetHeightOverride(vh)
    end
    for _, group in ipairs({ items, skills }) do
        for _, w in ipairs(group) do
            local sb = firstSizeBox(w)
            if sb and math.abs((sb.HeightOverride or 0) - h) > 0.01 then sb:SetHeightOverride(h) end
        end
    end
    local now = string.format("%d+%d rows, height %d, vision %d", #items, #skills, h, vh)
    if now ~= Fit.last then Fit.last = now; log("equipment panel: %s", now) end
end

------------------------------------------------------------------------
-- Loops
------------------------------------------------------------------------
loadConfig()
gameLoop(3000, function()
    loadConfig()
    applyTables()
end)

gameLoop(400, function()
    if not cfg.FitPanel then return end
    local now = os.clock()
    local open = nil
    for _, w in ipairs(Fit.lists) do
        if w:IsValid() and w:IsVisible() then open = w; break end
    end
    if not open and now >= Fit.nextScan then
        Fit.nextScan = now + 3
        Fit.lists = {}
        for _, w in ipairs(FindAllOf("WBP_UnitEquippedSkillList_C") or {}) do
            if w:IsValid() then
                Fit.lists[#Fit.lists + 1] = w
                if not open and w:IsVisible() then open = w end
            end
        end
    end
    if open then fitEquipmentPanel(open) end
end)

log("loaded (slots %d-%d, settings in %s/config.ini)", MIN_SLOTS, MAX_SLOTS, MOD_DIR)
