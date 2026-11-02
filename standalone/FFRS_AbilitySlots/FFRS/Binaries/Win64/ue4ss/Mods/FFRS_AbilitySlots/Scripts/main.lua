-- FFRS Ability Slots: more ability slots (8 - 16) per character for FINAL FANTASY RESONANCE.
-- Settings live in ../config.ini and are read again every second.
--
-- How it works: UNIT_PARAMETER_CALC_DATA.maxAciontListNum (8 in the base game) is the number of
-- ability slots. When a save is loaded the game builds each character's ability list from the save
-- and pads it up to this number, and the equipment screen only lets you equip into slots below it.
-- Raising the value before the save loads gives every character more slots; abilities in the extra
-- slots count on the map and in battle like the others. Lowering it again keeps abilities already
-- equipped beyond the limit (the game never drops them), and the save only stores filled slots.
--
-- The equipment screen has room for about 12 rows (4 equipment + 8 abilities), so the rows are made
-- shorter when there are more of them.
--
-- Part of FFRS QoL (https://github.com/LeiGaoRobot/FFRS-QoL), split out for people who only want
-- the slots. If FFRS QoL is installed too, this mod stays off and FFRS QoL's own setting is used.

local TAG = "[FFRS_AbilitySlots] "
local function log(fmt, ...) print(TAG .. string.format(fmt, ...) .. "\n") end

-- Game-thread timers (async timers next to game-thread hooks crashed this game).
local function gameLoop(ms, fn)
    local function safe()
        local ok, err = pcall(fn)
        if not ok then log("timer error: %s", tostring(err)) end
    end
    if LoopInGameThreadWithDelay then return LoopInGameThreadWithDelay(ms, safe) end
    LoopAsync(ms, function() ExecuteInGameThread(safe); return false end)
end

local function modDir()
    local ok, info = pcall(function() return debug.getinfo(1, "S") end)
    local src = (ok and info and info.source) or ""
    src = src:gsub("^@", ""):gsub("\\", "/")
    return src:match("^(.*)/Scripts/[^/]+$") or "ue4ss/Mods/FFRS_AbilitySlots"
end
local DIR = modDir()
local CONFIG_PATH = DIR .. "/config.ini"
local STATUS_PATH = DIR .. "/status.txt"

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local t = f:read("*a"); f:close()
    return t
end
local function writeFile(path, text)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(text); f:close()
    return true
end

------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------
local Defaults = { AbilitySlots = 12, APCapacityBonus = 0, FitEquipmentScreen = true }
local Range = { AbilitySlots = { 8, 16 }, APCapacityBonus = { 0, 9999 } }
local cfg = { AbilitySlots = 12, APCapacityBonus = 0, FitEquipmentScreen = true }
local lastConfigText = nil

local function defaultConfigText()
    return table.concat({
        "; FFRS Ability Slots - changes are read within a second; slot and AP changes show after loading a save.",
        "; AbilitySlots: ability slots per character, 8 (the game's own) to 16.",
        "AbilitySlots=12",
        "; APCapacityBonus: extra AP limit for every character (0 = unchanged). More slots need more AP.",
        "APCapacityBonus=0",
        "; FitEquipmentScreen: 1 = shrink the rows on the equipment screen so every slot fits.",
        "FitEquipmentScreen=1",
    }, "\n") .. "\n"
end

local function loadConfig()
    local text = readFile(CONFIG_PATH)
    if not text then
        text = defaultConfigText()
        writeFile(CONFIG_PATH, text)
    end
    if text == lastConfigText then return false end
    lastConfigText = text
    local new = {}
    for k, v in pairs(Defaults) do new[k] = v end
    for line in text:gmatch("[^\r\n]+") do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k and Defaults[k] ~= nil then
            if Range[k] then
                local n = tonumber(v)
                if n then
                    n = math.floor(n)
                    if n < Range[k][1] then n = Range[k][1] end
                    if n > Range[k][2] then n = Range[k][2] end
                    new[k] = n
                end
            else
                new[k] = (v == "1" or v:lower() == "true")
            end
        end
    end
    cfg = new
    log("settings: %d slots, AP limit +%d, fit screen %s", cfg.AbilitySlots, cfg.APCapacityBonus,
        cfg.FitEquipmentScreen and "on" or "off")
    return true
end

-- FFRS QoL writes the same table fields, so with both mods active they would keep overwriting
-- each other. FFRS QoL counts as active when its script is there and UE4SS starts it
-- (enabled.txt, or "FFRS_QoL : 1" in mods.txt).
local function qolActive()
    local mods = DIR:match("^(.*)/[^/]+$") or "ue4ss/Mods"
    if not readFile(mods .. "/FFRS_QoL/Scripts/main.lua") then return false end
    if readFile(mods .. "/FFRS_QoL/enabled.txt") then return true end
    local list = readFile(mods .. "/mods.txt") or ""
    for line in list:gmatch("[^\r\n]+") do
        local name, on = line:match("^%s*([%w_]+)%s*:%s*(%d)")
        if name == "FFRS_QoL" then return on == "1" end
    end
    return false
end
local QOL = qolActive()
if QOL then
    log("FFRS QoL is installed: this mod stays off; use FFRS QoL's \"Ability slots\" setting instead")
end

------------------------------------------------------------------------
-- Slots and AP limit (UNIT_PARAMETER_CALC_DATA)
------------------------------------------------------------------------
local stats = { slots = "", apBase = "", panel = "", err = "" }
local origSlots, origAP = {}, {}

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

local function applySlots()
    for _, t in ipairs(calcTables()) do
        t.dt:ForEachRow(function(rowName, row)
            local key = t.path .. "|" .. rowName
            local s = origSlots[key]
            if not s then s = row.maxAciontListNum; origSlots[key] = s end
            local slots = math.max(s, cfg.AbilitySlots)
            if row.maxAciontListNum ~= slots then row.maxAciontListNum = slots end
            stats.slots = slots

            local a = origAP[key]
            if not a then a = row.baseSkillEquipCost; origAP[key] = a end
            local want = a + cfg.APCapacityBonus
            if row.baseSkillEquipCost ~= want then row.baseSkillEquipCost = want end
            stats.apBase = want
        end)
    end
end

------------------------------------------------------------------------
-- Equipment screen fit. Every equipment row and ability row has a SizeBox 40 units high plus 8
-- units of spacing, and the panel has room for about 612 units. With more rows than that, all
-- rows get the same smaller height. If even the smallest rows don't fit (16 slots with 6 accessory
-- rows from 4-accessory mods), the Vision row (64 units, SizeBox_0 of WBP_UnitEquippedVision)
-- shrinks to 20 as well. The game reuses these widgets, so this re-checks while the screen is open
-- and only writes heights that differ.
------------------------------------------------------------------------
local FIT_ROOM, FIT_GAP, FIT_MIN, FIT_MAX = 612, 8, 22, 40
local VISION_H, VISION_MIN = 64, 20
local Fit = { lists = {}, nextScan = 0 }

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
    local box = list:GetParent()                       -- equipment list, Vision, abilities
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
    local panel = string.format("%d+%d rows, height %d, vision %d", #items, #skills, h, vh)
    if panel ~= stats.panel then log("equipment panel: %s", panel) end
    stats.panel = panel
end

local function fitTick()
    if not cfg.FitEquipmentScreen then return end
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
end

------------------------------------------------------------------------
-- Main loop
------------------------------------------------------------------------
local function writeStatus()
    writeFile(STATUS_PATH, table.concat({
        "Active=" .. (QOL and "0 (FFRS QoL installed)" or "1"),
        "AbilitySlots=" .. tostring(stats.slots),
        "APLimit=" .. tostring(stats.apBase),
        "Panel=" .. tostring(stats.panel),
        "LastError=" .. tostring(stats.err),
    }, "\n") .. "\n")
end

if not QOL then
    loadConfig()
    local tick = 0
    gameLoop(1000, function()
        tick = tick + 1
        local changed = loadConfig()
        if changed or tick % 3 == 0 then
            local ok, err = pcall(applySlots)
            stats.err = ok and "" or tostring(err)
            if not ok then log("apply error: %s", stats.err) end
        end
        writeStatus()
    end)
    gameLoop(400, fitTick)
    log("loaded (%d slots)", cfg.AbilitySlots)
else
    writeStatus()
end
