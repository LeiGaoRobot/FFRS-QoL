-- FFRS_QoL: encounter toggle + EXP/Gil/MR/drop-rate multipliers for FINAL FANTASY RESONANCE
-- Settings live in ../config.ini and are reloaded live (edit with Settings.bat or by hand).
-- The mod writes ../status.txt so the settings window can show live state.

local TAG = "[FFRS_QoL] "
local function log(fmt, ...) print(TAG .. string.format(fmt, ...) .. "\n") end

-- Timers that run on the game thread. LoopAsync/ExecuteWithDelay run Lua on UE4SS's async
-- thread while hooks run on the game thread; frequent use of both corrupted callback refs
-- ("Ref was not function") and crashed the game. Fall back only if the new API is missing.
local HAS_GAME_TIMERS = (LoopInGameThreadWithDelay ~= nil) and (ExecuteInGameThreadWithDelay ~= nil)
local function gameLoop(ms, fn, fallbackMs)
    local function safe()
        local ok, err = pcall(fn)
        if not ok then log("timer error: %s", tostring(err)) end
    end
    if HAS_GAME_TIMERS then
        return LoopInGameThreadWithDelay(ms, safe)
    end
    LoopAsync(fallbackMs or ms, function()
        ExecuteInGameThread(safe)
        return false
    end)
end
local function gameDelay(ms, fn)
    local function safe()
        local ok, err = pcall(fn)
        if not ok then log("timer error: %s", tostring(err)) end
    end
    if HAS_GAME_TIMERS then
        return ExecuteInGameThreadWithDelay(ms, safe)
    end
    ExecuteWithDelay(ms, function() ExecuteInGameThread(safe) end)
end

-- Mod folder (parent of Scripts/), from this script's own path.
local function modDir()
    local ok, info = pcall(function() return debug.getinfo(1, "S") end)
    local src = (ok and info and info.source) or ""
    src = src:gsub("^@", ""):gsub("\\", "/")
    local dir = src:match("^(.*)/Scripts/[^/]+$")
    return dir or "ue4ss/Mods/FFRS_QoL"
end
local DIR = modDir()
local CONFIG_PATH = DIR .. "/config.ini"
local STATUS_PATH = DIR .. "/status.txt"

local Defaults = {
    EncountersEnabled  = true,
    EncounterRate      = 1.0,
    ExpMultiplier      = 2.0,
    MoneyMultiplier    = 2.0,
    MRPointMultiplier  = 1.0,
    DropMultiplier     = 1.0,
    RareAlwaysDrop     = false,
    APMultiplier       = 1.0,
    BattleSpeedMultiplier = 1.0,
    AlwaysEscape       = false,
    ItemLimit          = 99,
    APCapacityBonus    = 0,
    MapMarkers         = true,
    LBGainMultiplier   = 1.0,
    PersistentLB       = false,
    AutoRepeat         = false,
    SmartSupport       = true,
    AutoOpenSettings   = true,
    UILanguage         = "auto",
    ToggleEncounterKey = "F6",
    CycleMultiplierKey = "F7",
    AutoRepeatKey      = "F8",
    RepeatCommandKey   = "F9",
    ToggleEncounterPad = "",
    CycleMultiplierPad = "",
    RepeatCommandPad   = "R3",
    AutoRepeatPad      = "L3",
    CyclePresets       = "1,2,3,5",
}
local Order = { "EncountersEnabled", "EncounterRate", "ExpMultiplier", "MoneyMultiplier", "MRPointMultiplier", "DropMultiplier",
                "RareAlwaysDrop", "APMultiplier", "BattleSpeedMultiplier", "AlwaysEscape", "ItemLimit", "APCapacityBonus", "MapMarkers", "LBGainMultiplier", "PersistentLB", "AutoRepeat", "SmartSupport",
                "AutoOpenSettings", "UILanguage", "ToggleEncounterKey", "CycleMultiplierKey", "AutoRepeatKey", "RepeatCommandKey",
                "ToggleEncounterPad", "CycleMultiplierPad", "RepeatCommandPad", "AutoRepeatPad",
                "CyclePresets" }

local cfg = {}
for k, v in pairs(Defaults) do cfg[k] = v end
local lastConfigText = nil

local function clampMult(x, fallback)
    x = tonumber(x)
    if not x then return fallback end
    if x < 0 then x = 0 end
    if x > 10 then x = 10 end
    return x
end

-- Whole-number settings with their own range (not multipliers).
local IntRange = { ItemLimit = { 99, 9999 }, APCapacityBonus = { 0, 9999 } }
local function clampInt(k, x)
    x = tonumber(x)
    if not x then return Defaults[k] end
    x = math.floor(x)
    local r = IntRange[k]
    if x < r[1] then x = r[1] end
    if x > r[2] then x = r[2] end
    return x
end

local function parseConfig(text)
    local new = {}
    for k, v in pairs(Defaults) do new[k] = v end
    for line in text:gmatch("[^\r\n]+") do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k and Defaults[k] ~= nil then
            if IntRange[k] then
                new[k] = clampInt(k, v)
            elseif type(Defaults[k]) == "boolean" then
                new[k] = (v == "1" or v:lower() == "true")
            elseif type(Defaults[k]) == "number" then
                new[k] = clampMult(v, Defaults[k])
            else
                new[k] = v
            end
        end
    end
    return new
end

local function serializeConfig()
    local lines = { "; FFRS_QoL settings - changes apply in game within ~1 second.",
                    "; Key changes need a game restart." }
    for _, k in ipairs(Order) do
        local v = cfg[k]
        if type(v) == "boolean" then v = v and "1" or "0"
        elseif IntRange[k] then v = string.format("%d", v)
        elseif type(v) == "number" then v = string.format("%.2f", v) end
        lines[#lines + 1] = k .. "=" .. tostring(v)
    end
    return table.concat(lines, "\n") .. "\n"
end

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

local function saveConfig()
    local text = serializeConfig()
    if writeFile(CONFIG_PATH, text) then lastConfigText = text end
end

-- Returns true when the config changed since the last read.
local function loadConfig()
    local text = readFile(CONFIG_PATH)
    if not text then saveConfig(); return true end
    if text == lastConfigText then return false end
    lastConfigText = text
    cfg = parseConfig(text)
    return true
end

------------------------------------------------------------------------
-- Game data
------------------------------------------------------------------------
local HUGE = 1.0e9
local origDifficulty, origMap, origThreshold, origDrop = {}, {}, {}, {}
local origSpeed, origGroup = {}, {}
local stats = { difficultyRows = 0, mapRows = 0, unitRows = 0, groupRows = 0, speedList = "", players = 0, lastError = "",
                repeatRecords = 0, repeatLast = "" }

local function rowStructName(dt)
    local ok, name = pcall(function()
        local s = dt:GetRowStruct()
        if not s or not s:IsValid() then return nil end
        return s:GetFName():ToString()
    end)
    return ok and name or nil
end

-- One scan of all DataTables per apply, grouped by row struct name.
local Wanted = { GAME_DIFFICULTY_PARAM = true, UNIT_PARAMETER = true, MAP_DATA = true,
                 BTL_GENERAL_DATA = true, BATTLE_GROUP_DATA = true, UNIT_PARAMETER_CALC_DATA = true,
                 SKILL_EFFECT_DATA = true }
local function collectTables()
    local out = { GAME_DIFFICULTY_PARAM = {}, UNIT_PARAMETER = {}, MAP_DATA = {},
                  BTL_GENERAL_DATA = {}, BATTLE_GROUP_DATA = {}, UNIT_PARAMETER_CALC_DATA = {},
                  SKILL_EFFECT_DATA = {} }
    local tables = FindAllOf("DataTable")
    if not tables then return out end
    for _, dt in ipairs(tables) do
        -- Objects can be half-loaded/unloaded during map transitions; skip anything odd.
        pcall(function()
            if type(dt) ~= "userdata" or not dt:IsValid() then return end
            local name = rowStructName(dt)
            if name and Wanted[name] then
                local list = out[name]
                list[#list + 1] = { dt = dt, path = dt:GetFullName() }
            end
        end)
    end
    return out
end

-- Identity of a table set: object addresses + row counts. Changes when a table is (re)loaded.
local function signature(list)
    local parts = {}
    for _, t in ipairs(list) do
        local okA, addr = pcall(function() return t.dt:GetAddress() end)
        parts[#parts + 1] = t.path .. "@" .. tostring(okA and addr or "?") .. "#" .. tostring(#t.dt)
    end
    return table.concat(parts, ";")
end

local function applyMultipliers(list)
    local rows = 0
    for _, t in ipairs(list) do
        t.dt:ForEachRow(function(rowName, row)
            local key = t.path .. "|" .. rowName
            local o = origDifficulty[key]
            if not o then
                o = { exp = row.ExpRate, money = row.MoneyRate, mr = row.MRPointRate }
                origDifficulty[key] = o
            end
            row.ExpRate = o.exp * cfg.ExpMultiplier
            row.MoneyRate = o.money * cfg.MoneyMultiplier
            row.MRPointRate = o.mr * cfg.MRPointMultiplier
            rows = rows + 1
        end)
    end
    stats.difficultyRows = rows
end

-- Ability AP capacity: every character's base capacity is UNIT_PARAMETER_CALC_DATA.baseSkillEquipCost
-- (100). The game copies it into each character when a save is loaded, so changes show after
-- loading a save (or at game start).
local origAPBase = {}
local function applyAPCapacity(list)
    for _, t in ipairs(list) do
        t.dt:ForEachRow(function(rowName, row)
            local key = t.path .. "|" .. rowName
            local o = origAPBase[key]
            if not o then o = row.baseSkillEquipCost; origAPBase[key] = o end
            local want = o + cfg.APCapacityBonus
            if row.baseSkillEquipCost ~= want then row.baseSkillEquipCost = want end
            stats.apBase = want
        end)
    end
end

-- Limit Burst gain. LB passives and skills are SKILL_EFFECT_DATA rows of effect type 2 (parameter
-- variation) whose ParamList is { amount %, 4 = LimitBurstPoint, ... }: taking damage, attack, crit,
-- kill, auto charge, heal... Positive amounts are multiplied (LB costs stay as they are), and so are
-- the base gains in UNIT_PARAMETER_CALC_DATA (break, all-break, taking damage).
local EFFECT_PARAM_VARIATION, PARAM_LB = 2, 4
local origLBEffect, origLBBase = {}, {}
local lastLBKey = nil
local function applyLBGain(effectTables, calcTables)
    local m = cfg.LBGainMultiplier
    if m < 0 then m = 0 end
    local key = signature(effectTables) .. "|" .. signature(calcTables) .. "|" .. string.format("%.3f", m)
    if key == lastLBKey then return end
    local n = 0
    for _, t in ipairs(effectTables) do
        t.dt:ForEachRow(function(rowName, row)
            if row.EffectType ~= EFFECT_PARAM_VARIATION then return end
            local k = t.path .. "|" .. rowName
            local o = origLBEffect[k]
            if o == nil then
                o = false
                local amount, ptype
                row.ParamList:ForEach(function(i, e)
                    if i == 1 then amount = e:get() elseif i == 2 then ptype = e:get() end
                end)
                if ptype == PARAM_LB and amount and amount > 0 then o = amount end
                origLBEffect[k] = o
            end
            if o then
                row.ParamList:ForEach(function(i, e) if i == 1 then e:set(math.floor(o * m + 0.5)) end end)
                n = n + 1
            end
        end)
    end
    for _, t in ipairs(calcTables) do
        t.dt:ForEachRow(function(rowName, row)
            local k = t.path .. "|" .. rowName
            local o = origLBBase[k]
            if not o then
                o = { row.breakLBIncrease, row.allBreakLBIncrease, row.damagedLBIncrease }
                origLBBase[k] = o
            end
            row.breakLBIncrease = math.floor(o[1] * m + 0.5)
            row.allBreakLBIncrease = math.floor(o[2] * m + 0.5)
            row.damagedLBIncrease = o[3] * m
        end)
    end
    stats.lbEffects = n
    lastLBKey = key
end

-- Dev helpers: active only when the mod folder has a "dev" subfolder.
local DEV_DIR = DIR .. "/dev"
local function devEnabled()
    local f = io.open(DEV_DIR .. "/.keep", "r")
    if f then f:close(); return true end
    return false
end

local function csvField(v)
    v = tostring(v):gsub('"', '""')
    return '"' .. v .. '"'
end

-- Writes dev/units.csv with the original drop data of every enemy row.
local function dumpUnits(list)
    if not devEnabled() then return end
    local lines = { "table,row,ID,Name,Level,Category,IsBoss,Experience,Money,DropNormalItem,DropNormalItemRate,DropRareItem,DropRareItemRate,StealNormalItem,StealRareItem,StealItemRate" }
    for _, t in ipairs(list) do
        t.dt:ForEachRow(function(rowName, row)
            local o = origDrop[t.path .. "|" .. rowName] or {}
            local ok, name = pcall(function() return row.Name:ToString() end)
            local okC, cat = pcall(function() return row.Category end)
            lines[#lines + 1] = table.concat({
                csvField(t.path:match("([^%.]+)$") or t.path), csvField(rowName), row.ID, csvField(ok and name or "?"),
                row.Level, tostring(okC and cat or "?"), tostring(row.IsBoss), row.Experience, row.Money,
                row.DropNormalItem, o.normal or row.DropNormalItemRate, row.DropRareItem, o.rare or row.DropRareItemRate,
                row.StealNormalItem, row.StealRareItem, row.StealItemRate }, ",")
        end)
    end
    local f = io.open(DEV_DIR .. "/units.csv", "w")
    if f then f:write(table.concat(lines, "\n") .. "\n"); f:close() end
    log("dev: wrote %d rows to dev/units.csv", #lines - 1)
end

-- Runs dev/eval.lua once (in the game thread), output to dev/eval_out.txt.
local function devEval()
    local path = DEV_DIR .. "/eval.lua"
    local f = io.open(path, "r")
    if not f then return end
    local code = f:read("*a"); f:close()
    os.remove(DEV_DIR .. "/eval_done.lua")
    os.rename(path, DEV_DIR .. "/eval_done.lua")
    local outLines = {}
    local env = setmetatable({
        out = function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
            outLines[#outLines + 1] = table.concat(parts, "\t")
        end,
        DEV_DIR = DEV_DIR, origDrop = origDrop, cfg = cfg, stats = stats,
    }, { __index = _G })
    local chunk, err = load(code, "eval", "t", env)
    local ok, res
    if chunk then ok, res = pcall(chunk) else ok, res = false, err end
    if not ok then outLines[#outLines + 1] = "ERROR: " .. tostring(res) end
    local o = io.open(DEV_DIR .. "/eval_out.txt", "w")
    if o then o:write(table.concat(outLines, "\n") .. "\n"); o:close() end
end

-- Enemy drop rates (FUNIT_PARAMETER.DropNormalItemRate / DropRareItemRate, int32).
-- Each value is a divisor: drop chance = 100 / value percent. Normal and rare are rolled independently.
local dropScaleLogged = false
local lastDropKey = nil
local function applyDropRates(list)
    local key = signature(list) .. "|" .. string.format("%.3f", cfg.DropMultiplier) .. "|" .. tostring(cfg.RareAlwaysDrop)
    if key == lastDropKey then return end

    -- Pass 1: capture originals and build a histogram of rates.
    local rows, nonZero, hist = 0, 0, {}
    for _, t in ipairs(list) do
        t.dt:ForEachRow(function(rowName, row)
            local k = t.path .. "|" .. rowName
            local o = origDrop[k]
            if not o then
                o = { normal = row.DropNormalItemRate, rare = row.DropRareItemRate,
                      normalItem = row.DropNormalItem, rareItem = row.DropRareItem }
                origDrop[k] = o
            end
            for _, v in ipairs({ o.normal, o.rare }) do
                if v > 0 then nonZero = nonZero + 1; hist[v] = (hist[v] or 0) + 1 end
            end
            rows = rows + 1
        end)
    end
    stats.unitRows = rows

    if rows > 0 and not dropScaleLogged then
        dropScaleLogged = true
        local vals = {}
        for v in pairs(hist) do vals[#vals + 1] = v end
        table.sort(vals)
        local parts = {}
        for _, v in ipairs(vals) do parts[#parts + 1] = string.format("%d(%.1f%%)x%d", v, 100 / v, hist[v]) end
        log("drop rates: %d unit rows, %d non-zero rates | rate(chance)xcount: %s",
            rows, nonZero, table.concat(parts, " "))
        dumpUnits(list)
    end

    -- Pass 2: write scaled values.
    -- The game rolls a drop as: rand(0..100) <= 100 / rate + bonus (see FFRS drop roll at 0x144fa2c20),
    -- so the stored rate is a divisor: chance% = 100 / rate. Raising the chance means dividing the rate.
    -- A rate of 1 is a guaranteed drop; 0 disables the slot.
    local m = cfg.DropMultiplier
    local function scale(v)
        if v <= 0 then return v end
        if m <= 0 then return 0 end
        local n = math.floor(v / m + 0.5)
        if n < 1 then n = 1 end
        return n
    end
    for _, t in ipairs(list) do
        t.dt:ForEachRow(function(rowName, row)
            local o = origDrop[t.path .. "|" .. rowName]
            if o then
                row.DropNormalItemRate = scale(o.normal)
                if cfg.RareAlwaysDrop and (o.rareItem or 0) > 0 and o.rare > 0 then
                    row.DropRareItemRate = 1  -- 100 / 1 = guaranteed rare drop
                else
                    row.DropRareItemRate = scale(o.rare)
                end
            end
        end)
    end
    lastDropKey = key
end

-- Encounters: on/off (doMovementEncount) and frequency. A random encounter happens after walking a
-- random distance between encountMin/MaxMovementLength (separate values on a chocobo), so the
-- frequency multiplier divides those distances (x2 = half the distance = twice as many battles).
local origMapLen = {}
local lastMapKey = nil
local function applyEncounterTables(list)
    local rate = cfg.EncounterRate
    if rate < 0.1 then rate = 0.1 end
    local key = signature(list) .. "|" .. tostring(cfg.EncountersEnabled) .. "|" .. string.format("%.3f", rate)
    if key == lastMapKey then return end
    local rows = 0
    for _, t in ipairs(list) do
        t.dt:ForEachRow(function(rowName, row)
            local k = t.path .. "|" .. rowName
            if origMap[k] == nil then origMap[k] = row.doMovementEncount end
            row.doMovementEncount = cfg.EncountersEnabled and origMap[k] or false
            local o = origMapLen[k]
            if not o then
                o = { row.encountMinMovementLength, row.encountMaxMovementLength,
                      row.chocoboEncountMinMovementLength, row.chocoboEncountMaxMovementLength }
                origMapLen[k] = o
            end
            row.encountMinMovementLength = o[1] / rate
            row.encountMaxMovementLength = o[2] / rate
            row.chocoboEncountMinMovementLength = o[3] / rate
            row.chocoboEncountMaxMovementLength = o[4] / rate
            rows = rows + 1
        end)
    end
    stats.mapRows = rows
    lastMapKey = key
end

-- Battle speed: the game's own speed steps (BTL_GENERAL_DATA.GameSpeedList, originally 1/1.5/2)
-- are scaled, so the in-game speed toggle keeps working with faster steps.
local lastSpeedKey = nil
local function applyBattleSpeed(list)
    local m = cfg.BattleSpeedMultiplier
    if m < 0.5 then m = 0.5 end
    if m > 5 then m = 5 end
    local key = signature(list) .. "|" .. string.format("%.3f", m)
    if key == lastSpeedKey then return end
    local shown = {}
    for _, t in ipairs(list) do
        t.dt:ForEachRow(function(rowName, row)
            local k = t.path .. "|" .. rowName
            local o = origSpeed[k]
            if not o then
                o = {}
                row.GameSpeedList:ForEach(function(i, e) o[i] = e:get() end)
                origSpeed[k] = o
            end
            row.GameSpeedList:ForEach(function(i, e)
                if o[i] then
                    e:set(o[i] * m)
                    shown[#shown + 1] = string.format("%.2f", o[i] * m)
                end
            end)
        end)
    end
    stats.speedList = table.concat(shown, "/")
    lastSpeedKey = key
end

-- Battle groups: AP reward (int) and escape chance (percent; 50 for most groups).
-- Escape is only forced for groups that already allow escaping (bosses/story battles stay as they are).
local lastGroupKey = nil
local function applyBattleGroups(list)
    local key = signature(list) .. "|" .. string.format("%.3f", cfg.APMultiplier) .. "|" .. tostring(cfg.AlwaysEscape)
    if key == lastGroupKey then return end
    local rows = 0
    for _, t in ipairs(list) do
        t.dt:ForEachRow(function(rowName, row)
            local k = t.path .. "|" .. rowName
            local o = origGroup[k]
            if not o then
                o = { ap = row.ap, escape = row.probabilityOfSuccessfulEscape }
                origGroup[k] = o
            end
            row.ap = math.floor(o.ap * cfg.APMultiplier + 0.5)
            if cfg.AlwaysEscape and row.CanEscape then
                row.probabilityOfSuccessfulEscape = 10000
            else
                row.probabilityOfSuccessfulEscape = o.escape
            end
            rows = rows + 1
        end)
    end
    stats.groupRows = rows
    lastGroupKey = key
end

-- Current map: push the player's encounter distance out of reach while disabled.
local function applyPlayerThreshold()
    local players = FindAllOf("CPP_MapUnit_Playable")
    local count = 0
    if players then
        for _, p in ipairs(players) do
            if p:IsValid() then
                count = count + 1
                local key = p:GetFullName()
                local cur = p.m_EncountThresholdDistance
                if not cfg.EncountersEnabled then
                    if cur < HUGE then
                        origThreshold[key] = cur
                        p.m_EncountThresholdDistance = HUGE
                    end
                elseif origThreshold[key] then
                    if cur >= HUGE then p.m_EncountThresholdDistance = origThreshold[key] end
                    origThreshold[key] = nil
                end
            end
        end
    end
    stats.players = count
end

local function applyAll()
    local ok, err = pcall(function()
        local t = collectTables()
        applyMultipliers(t.GAME_DIFFICULTY_PARAM)
        applyDropRates(t.UNIT_PARAMETER)
        applyEncounterTables(t.MAP_DATA)
        applyBattleSpeed(t.BTL_GENERAL_DATA)
        applyBattleGroups(t.BATTLE_GROUP_DATA)
        applyAPCapacity(t.UNIT_PARAMETER_CALC_DATA)
        applyLBGain(t.SKILL_EFFECT_DATA, t.UNIT_PARAMETER_CALC_DATA)
        applyPlayerThreshold()
    end)
    stats.lastError = ok and "" or tostring(err)
    if not ok then log("apply error: %s", stats.lastError) end
end

------------------------------------------------------------------------
-- Item carry limit. The game hardcodes 99 in native code, so ItemLimit.ps1 rewrites those
-- spots in this process's memory (99 restores the original code). It runs in the background
-- and reports to itemlimit_status.txt.
------------------------------------------------------------------------
local ITEMLIMIT_STATUS = DIR .. "/itemlimit_status.txt"
local itemLimitApplied = 99  -- the game starts with its original code
-- Helper scripts are started through "conhost --headless": with Windows Terminal as the default
-- terminal, "powershell -WindowStyle Hidden" alone leaves an empty terminal window open.
-- ItemLimit.ps1 is an optional download (antivirus heuristics flag its memory patching),
-- so the feature stays off when the file isn't there.
local ITEMLIMIT_PS1 = DIR .. "/ItemLimit.ps1"
local itemLimitMissingLogged = false
local function itemLimitInstalled()
    local f = io.open(ITEMLIMIT_PS1, "r")
    if f then f:close(); return true end
    return false
end

local function applyItemLimit()
    if cfg.ItemLimit == itemLimitApplied then return end
    if not itemLimitInstalled() then
        if not itemLimitMissingLogged then
            log("item limit %d: ItemLimit.ps1 not installed (optional file), keeping 99", cfg.ItemLimit)
            itemLimitMissingLogged = true
        end
        return
    end
    itemLimitApplied = cfg.ItemLimit
    os.remove(ITEMLIMIT_STATUS)
    local ps1 = ITEMLIMIT_PS1:gsub("/", "\\")
    local cmd = string.format(
        'start "" conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%s" -Limit %d',
        ps1, cfg.ItemLimit)
    local ok, res = pcall(os.execute, cmd)
    log("item limit %d: patcher %s", cfg.ItemLimit, ok and "started" or ("failed: " .. tostring(res)))
end

local function itemLimitResult()
    if itemLimitApplied == 99 and not itemLimitInstalled() then return "not installed" end
    local t = readFile(ITEMLIMIT_STATUS)
    local r = t and t:match("ItemLimitResult=([^\r\n]*)")
    if r then return r end
    return itemLimitApplied == 99 and "original (99)" or "applying..."
end

local function writeStatus()
    writeFile(STATUS_PATH, table.concat({
        "ItemLimit=" .. cfg.ItemLimit,
        "MapMarkers=" .. (cfg.MapMarkers and "1" or "0"),
        string.format("LBGain=%.2f", cfg.LBGainMultiplier),
        "LBEffects=" .. tostring(stats.lbEffects or ""),
        "PersistentLB=" .. (cfg.PersistentLB and "1" or "0"),
        "APBase=" .. tostring(stats.apBase or ""),
        "ItemLimitResult=" .. itemLimitResult(),
        "Encounters=" .. (cfg.EncountersEnabled and "1" or "0"),
        string.format("EncounterRate=%.2f", cfg.EncounterRate),
        string.format("Exp=%.2f", cfg.ExpMultiplier),
        string.format("Money=%.2f", cfg.MoneyMultiplier),
        string.format("MRPoint=%.2f", cfg.MRPointMultiplier),
        string.format("Drop=%.2f", cfg.DropMultiplier),
        "RareAlways=" .. (cfg.RareAlwaysDrop and "1" or "0"),
        string.format("AP=%.2f", cfg.APMultiplier),
        "SpeedList=" .. stats.speedList,
        "AlwaysEscape=" .. (cfg.AlwaysEscape and "1" or "0"),
        "AutoRepeat=" .. (cfg.AutoRepeat and "1" or "0"),
        "RepeatRecords=" .. stats.repeatRecords,
        "RepeatLast=" .. stats.repeatLast,
        "GroupRows=" .. stats.groupRows,
        "UnitRows=" .. stats.unitRows,
        "DifficultyRows=" .. stats.difficultyRows,
        "MapRows=" .. stats.mapRows,
        "Players=" .. stats.players,
        "Error=" .. stats.lastError:gsub("[\r\n]", " "),
    }, "\n") .. "\n")
end

local function report(what)
    log("%s | encounters=%s exp=%.2fx gil=%.2fx mr=%.2fx drop=%.2fx | difficulty rows=%d map rows=%d unit rows=%d",
        what, cfg.EncountersEnabled and "ON" or "OFF", cfg.ExpMultiplier, cfg.MoneyMultiplier,
        cfg.MRPointMultiplier, cfg.DropMultiplier, stats.difficultyRows, stats.mapRows, stats.unitRows)
end

------------------------------------------------------------------------
-- Main loop: config check every second, full re-apply every 3 seconds
------------------------------------------------------------------------
loadConfig()
applyItemLimit()
local tick = 0
gameLoop(1000, function()
    tick = tick + 1
    local changed = loadConfig()
    if changed or tick % 3 == 0 then applyAll() end
    if changed then applyItemLimit() end
    if changed then report("config reloaded") end
    if tick % 2 == 0 or changed then writeStatus() end
    local okE, errE = pcall(devEval)
    if not okE then log("dev eval error: %s", tostring(errE)) end
end)

------------------------------------------------------------------------
-- Dev: log every battle result to dev/battle_log.txt
------------------------------------------------------------------------
local function devAppend(line)
    local f = io.open(DEV_DIR .. "/battle_log.txt", "a")
    if f then f:write(os.date("%H:%M:%S") .. " " .. line .. "\n"); f:close() end
end

-- Current (in-table) drop data for one enemy ID, for comparing against what dropped.
local function describeEnemy(id)
    local desc = "?"
    for _, dt in ipairs(FindAllOf("DataTable") or {}) do
        if dt:IsValid() and rowStructName(dt) == "UNIT_PARAMETER" then
            dt:ForEachRow(function(_, row)
                if row.ID == id then
                    desc = string.format("%d(N %d@%d%% R %d@%d%%)", id, row.DropNormalItem, row.DropNormalItemRate,
                        row.DropRareItem, row.DropRareItemRate)
                    return true
                end
            end)
        end
    end
    return desc
end

local function describeResult(r)
    local items, enemies = {}, {}
    r.itemDataList:ForEach(function(_, e)
        local it = e:get()
        items[#items + 1] = it.ItemId .. "x" .. it.Num
    end)
    r.enemyDataList:ForEach(function(_, e) enemies[#enemies + 1] = describeEnemy(e:get()) end)
    return string.format("exp=%d gil=%d ap=%d(base %d) items=[%s] enemies=[%s]", r.totalExperience, r.totalMoney,
        r.totalAp, r.baseAp, table.concat(items, ","), table.concat(enemies, " "))
end

if devEnabled() then
    devAppend(string.format("session start (drop multiplier %.2f)", cfg.DropMultiplier))
    local battleNo = 0
    local okN, errN = pcall(function()
        NotifyOnNewObject("/Script/mucha.CPP_BtlBeginResultDelVal", function(obj)
            gameDelay(500, function()
                local ok, err = pcall(function()
                    if not obj:IsValid() then devAppend("result object gone before read"); return end
                    battleNo = battleNo + 1
                    devAppend(string.format("battle #%d drop=%.2fx %s", battleNo, cfg.DropMultiplier,
                        describeResult(obj.resultData)))
                end)
                if not ok then devAppend("result read error: " .. tostring(err)) end
            end)
        end)
    end)
    if not okN then devAppend("NotifyOnNewObject failed: " .. tostring(errN)) end

    -- Log every change of the effective global time dilation (battle speed check).
    local lastTD = nil
    gameLoop(1000, function()
        local ok, td = pcall(function()
            local ws = FindFirstOf("WorldSettings")
            return ws and ws:IsValid() and ws.TimeDilation or nil
        end)
        if ok and td and (lastTD == nil or math.abs(td - lastTD) > 0.001) then
            devAppend(string.format("time dilation %.3f (speed steps %s)", td, stats.speedList))
            lastTD = td
        end
    end)
end

------------------------------------------------------------------------
-- On-screen notices: small UMG widgets built from Lua (no game assets needed).
-- toast(): a short message near the top of the screen.
-- Badge: "auto repeat on" reminder shown in battle while auto repeat is on.
------------------------------------------------------------------------
local Hud = { serial = 0, toastSerial = 0, inBattle = false, badgeShown = false, lastAuto = nil }
local GREEN = { R = 0.45, G = 1.0, B = 0.55, A = 1.0 }
local GREY  = { R = 0.85, G = 0.85, B = 0.85, A = 1.0 }
local AMBER = { R = 1.0, G = 0.78, B = 0.35, A = 1.0 }
local HudLayout = {
    toast = { ax = 0.5, ay = 0.2, alx = 0.5, aly = 0.5, size = 22, z = 1001 },
    badge = { ax = 0.012, ay = 0.905, alx = 0.0, aly = 1.0, size = 16, z = 1000 },
}

-- Notice language: Chinese when the game itself runs in Chinese, English otherwise.
-- Read once from the engine (game thread); retried a few times, then English.
local NoticeLang = { zh = nil, tries = 0 }
local function detectNoticeLang()
    if NoticeLang.zh ~= nil or NoticeLang.tries >= 10 then return end
    NoticeLang.tries = NoticeLang.tries + 1
    local ok, culture = pcall(function()
        local lib = StaticFindObject("/Script/Engine.Default__KismetInternationalizationLibrary")
        if not (lib and lib:IsValid()) then return nil end
        local c = lib:GetCurrentCulture()
        if type(c) ~= "string" then c = c:ToString() end
        return c
    end)
    if ok and type(culture) == "string" and culture ~= "" then
        NoticeLang.zh = culture:lower():sub(1, 2) == "zh"
        log("game culture %s, notices in %s", culture, NoticeLang.zh and "Chinese" or "English")
    elseif NoticeLang.tries >= 10 then
        log("could not read the game culture (%s), notices in English", tostring(culture))
    end
end
local function tr(zh, en)
    -- The settings window's language choice wins; "auto" follows the game's language.
    local pick = tostring(cfg.UILanguage or ""):lower()
    if pick == "zh" then return zh end
    if pick == "en" then return en end
    if NoticeLang.zh == nil then detectNoticeLang() end
    if NoticeLang.zh then return zh end
    return en
end

-- Returns { W, text } for a widget kind, (re)creating it when needed. Widgets get dropped
-- from the viewport on map changes and may be garbage collected afterwards.
local function hudWidget(kind)
    local h = Hud[kind]
    local L = HudLayout[kind]
    if not (h and h.W:IsValid() and h.text:IsValid()) then
        local gi = FindFirstOf("GameInstance")
        if not (gi and gi:IsValid()) then return nil end
        Hud.serial = Hud.serial + 1
        local base = string.format("FFRSQoL_%s_%d", kind, Hud.serial)
        local W = StaticConstructObject(StaticFindObject("/Script/UMG.UserWidget"), gi, FName(base))
        local tree = StaticConstructObject(StaticFindObject("/Script/UMG.WidgetTree"), W, FName(base .. "_Tree"))
        W.WidgetTree = tree
        local canvas = StaticConstructObject(StaticFindObject("/Script/UMG.CanvasPanel"), tree, FName(base .. "_Canvas"))
        tree.RootWidget = canvas
        local border = StaticConstructObject(StaticFindObject("/Script/UMG.Border"), tree, FName(base .. "_Border"))
        local text = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), tree, FName(base .. "_Text"))
        border:SetContent(text)
        border:SetBrushColor({ R = 0.0, G = 0.0, B = 0.0, A = 0.65 })
        border:SetPadding({ Left = 16, Top = 7, Right = 16, Bottom = 7 })
        local slot = canvas:AddChildToCanvas(border)
        slot:SetAutoSize(true)
        slot:SetAnchors({ Minimum = { X = L.ax, Y = L.ay }, Maximum = { X = L.ax, Y = L.ay } })
        slot:SetAlignment({ X = L.alx, Y = L.aly })
        slot:SetPosition({ X = 0, Y = 0 })
        local f = text.Font
        f.Size = L.size
        text:SetFont(f)
        W:SetVisibility(1)  -- collapsed until used
        h = { W = W, text = text }
        Hud[kind] = h
    end
    if not h.W:IsInViewport() then h.W:AddToViewport(L.z) end
    return h
end

local function hudShow(kind, msg, color)
    local h = hudWidget(kind)
    if not h then return nil end
    h.text:SetText(FText(msg))
    h.text:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 })
    h.W:SetVisibility(3)  -- visible, ignores the mouse
    return h
end

local function toast(msg, color, ms)
    local ok, err = pcall(function()
        local h = hudShow("toast", msg, color or GREY)
        if not h then return end
        Hud.toastSerial = Hud.toastSerial + 1
        local s = Hud.toastSerial
        gameDelay(ms or 1800, function()
            if Hud.toastSerial == s and h.W:IsValid() then h.W:SetVisibility(1) end
        end)
    end)
    if not ok then log("notice error: %s", tostring(err)) end
end

local function keyLabel(keyName, padName)
    local k = tostring(cfg[keyName] or "")
    local p = tostring(cfg[padName] or "")
    if p ~= "" then return k .. " / " .. p end
    return k
end

-- Show/hide the in-battle reminder. Battles are detected from the command menu opening;
-- the battle is over once no battle unit actors exist.
local function updateBadge()
    local ok, err = pcall(function()
        if Hud.inBattle then
            local u = FindFirstOf("CPP_BtlUnit")
            if not (u and u:IsValid()) then Hud.inBattle = false end
        end
        local want = cfg.AutoRepeat and Hud.inBattle
        if want then
            local keys = keyLabel("AutoRepeatKey", "AutoRepeatPad")
            hudShow("badge", tr("● 自动重复：开（" .. keys .. " 关闭）", "● Auto repeat ON (" .. keys .. " to stop)"), GREEN)
        elseif Hud.badgeShown then
            local h = Hud.badge
            if h and h.W:IsValid() then h.W:SetVisibility(1) end
        end
        Hud.badgeShown = want
    end)
    if not ok then log("badge error: %s", tostring(err)) end
end

-- Toast when auto repeat changed (hotkey, gamepad or the settings window).
local function noteAutoRepeat()
    if Hud.lastAuto == nil then Hud.lastAuto = cfg.AutoRepeat; return end
    if cfg.AutoRepeat == Hud.lastAuto then return end
    Hud.lastAuto = cfg.AutoRepeat
    if cfg.AutoRepeat then toast(tr("自动重复：开", "Auto repeat: ON"), GREEN) else toast(tr("自动重复：关", "Auto repeat: OFF"), GREY) end
    updateBadge()
end

gameLoop(1000, function()
    detectNoticeLang()
    noteAutoRepeat()
    if Hud.inBattle or Hud.badgeShown then updateBadge() end
end)

------------------------------------------------------------------------
-- Hotkeys (bound at startup; changing keys needs a game restart)
------------------------------------------------------------------------
local Actions = {}   -- keyboard binding name -> action function (shared with gamepad bindings)
local function bind(name, fn)
    Actions[name] = fn
    local k = Key[cfg[name]]
    if not k then
        log("unknown key '%s' for %s, using %s", tostring(cfg[name]), name, Defaults[name])
        k = Key[Defaults[name]]
    end
    RegisterKeyBind(k, function() ExecuteInGameThread(fn) end)
end

bind("ToggleEncounterKey", function()
    cfg.EncountersEnabled = not cfg.EncountersEnabled
    saveConfig(); applyAll(); writeStatus(); report("hotkey")
    if cfg.EncountersEnabled then toast(tr("遇敌：开", "Encounters: ON"), GREEN) else toast(tr("遇敌：关", "Encounters: OFF"), GREY) end
end)

bind("CycleMultiplierKey", function()
    local presets = {}
    for v in tostring(cfg.CyclePresets):gmatch("[^,%s]+") do
        local n = clampMult(v, nil)
        if n then presets[#presets + 1] = n end
    end
    if #presets == 0 then presets = { 1, 2, 3, 5 } end
    local nextV = presets[1]
    for _, v in ipairs(presets) do
        if v > cfg.ExpMultiplier + 0.001 then nextV = v; break end
    end
    cfg.ExpMultiplier, cfg.MoneyMultiplier = nextV, nextV
    saveConfig(); applyAll(); writeStatus(); report("hotkey")
    toast(string.format(tr("经验 / 金钱倍率：×%g", "EXP / Gil: x%g"), nextV), GREEN)
end)

------------------------------------------------------------------------
-- Repeat last command (battle)
-- Each decided command is recorded per acting unit. When that unit's command menu
-- opens again, the record is re-sent through the game's own "Delegate.Battle.Cmd.Decide"
-- event, which closes the menu and executes the command exactly like a manual choice.
------------------------------------------------------------------------
local Rep = {
    records = {},          -- ["<unit>:<cmdType>"] = plain copy of the decision
    menuOpen = false,
    lastDecidedActor = -1, -- actor of the previous decision (diagnostics only)
    menuSerial = 0,
}
local DEV_REPEAT = devEnabled()
local function repLog(fmt, ...)
    local line = string.format(fmt, ...)
    stats.repeatLast = line
    if DEV_REPEAT then devAppend("REPEAT " .. line) end
end

local bflBattle = nil
local function battleLib()
    if not (bflBattle and bflBattle:IsValid()) then
        bflBattle = StaticFindObject("/Script/mucha.Default__CPP_BFL_Battle")
    end
    return bflBattle
end

local function currentActor()
    local ss = FindFirstOf("CPP_UI_BattleSubsystem")
    if not (ss and ss:IsValid()) then return -1 end
    return ss.CurrentActionUnitUniqueId
end

-- Current battle phase from the UI: 0 = normal turn, 1 = additional action, 2 = finish.
-- Matches eBtlCmdType, so it selects which recorded command to replay.
local function currentPhase()
    local ok, phase = pcall(function()
        local ss = FindFirstOf("CPP_UI_BattleSubsystem")
        if not (ss and ss:IsValid()) then return 0 end
        return ss.BtlPhaseType
    end)
    return (ok and type(phase) == "number") and phase or 0
end

local function copyInts(arr)
    local t = {}
    arr:ForEach(function(_, e) t[#t + 1] = e:get() end)
    return t
end

local function countRecords()
    local n = 0
    for _ in pairs(Rep.records) do n = n + 1 end
    stats.repeatRecords = n
end

-- Record every decided command.
local okRec, errRec = pcall(function()
    RegisterHook("/Script/mucha.CPP_BtlDelEventCmd:OnExecuteDecideCommand", function(ctx, value)
        local ok, err = pcall(function()
            local v = value:get()
            local c = { CmdType = v.CmdType, isNotConsume = v.isNotConsume, doCalcOrder = v.doCalcOrder,
                        CommandId = v.CommandId, items = {}, keys = {} }
            v.cmdDecideDataList:ForEach(function(_, e)
                local d = e:get()
                c.items[#c.items + 1] = {
                    actionId = d.actionId, unit = d.actionUnitUniqueId,
                    targets = copyInts(d.targetUnitUniqueIdList), params = copyInts(d.ParameterList),
                    isUseItem = d.isUseItem, IsAll = d.IsAll,
                    pCat = d.ParentActionKey.Category, pId = d.ParentActionKey.ID,
                }
            end)
            v.actionKeys:ForEach(function(_, e)
                local k = e:get()
                c.keys[#c.keys + 1] = { k.Category, k.ID }
            end)
            if #c.items == 0 then return end
            if DEV_REPEAT then
                for _, it in ipairs(c.items) do
                    repLog("decided: unit %d action %d cmd %d type %d IsAll=%s targets=[%s] params=[%s] parent=%d/%d keys=%d",
                        it.unit, it.actionId, c.CommandId, c.CmdType, tostring(it.IsAll), table.concat(it.targets, ","),
                        table.concat(it.params, ","), it.pCat or -1, it.pId or -1, #c.keys)
                end
            end
            local actor = c.items[1].unit
            Rep.lastDecidedActor = actor
            if c.CmdType == 0 or c.CmdType == 1 or c.CmdType == 2 then
                Rep.records[actor .. ":" .. c.CmdType] = c
                countRecords()
            end
        end)
        if not ok then log("repeat record error: %s", tostring(err)) end
    end)
end)
if not okRec then log("repeat: could not hook command decisions: %s", tostring(errRec)) end

local function unitAlive(id)
    local bfl = battleLib()
    local ok, alive = pcall(function()
        local u = bfl:GetBattleUnitByUniqueId(id, true)
        return u ~= nil and u:IsValid()
    end)
    return ok and alive
end

------------------------------------------------------------------------
-- Smart support targeting: for single-target skills on allies,
--   heal (HP increase)  -> ally with the lowest HP ratio
--   buff (adds status)  -> ally that does not have that status yet
-- Everything else keeps the recorded target.
------------------------------------------------------------------------
local SkillIdx = nil   -- [skillId] = { kind = "heal"|"buff"|nil, statuses = {[status]=true} }
local REL_FRIENDLIES, REL_ENEMIES, PARAM_HP, TARGET_SINGLE = 1, 2, 1, 1
local EFFECT_DAMAGE_RECOVERY = 1
local VAR_INCREASE, VAR_RATIO_INCREASE = 0, 2

local function unwrap(x)
    if type(x) == "userdata" then
        local ok, v = pcall(function() return x:get() end)
        if ok then return v end
    end
    return x
end

local function outList(fn)
    local t = {}
    fn(t)
    local res = {}
    for _, v in pairs(t) do res[#res + 1] = unwrap(v) end
    return res
end

local function buildSkillIndex()
    local effects, skills = {}, {}
    for _, dt in ipairs(FindAllOf("DataTable") or {}) do
        pcall(function()
            local name = rowStructName(dt)
            if name == "SKILL_EFFECT_DATA" then
                dt:ForEachRow(function(_, row) effects[row.ID] = row.statusCondition end)
            elseif name == "SKILL_DATA" then
                dt:ForEachRow(function(_, row)
                    local ids = {}
                    row.effectBundleList:ForEach(function(_, e)
                        local b = e:get()
                        if b.effectId > 0 and b.targetRelation == REL_FRIENDLIES then ids[#ids + 1] = b.effectId end
                    end)
                    skills[row.ID] = {
                        effType = row.skillEffectType, varType = row.parameterVariationType,
                        paramType = row.parameterType, targetType = row.TargetType,
                        rel = row.defaultTargetRelation, status = row.statusCondition, effectIds = ids,
                        cost = row.Cost,
                    }
                end)
            end
        end)
    end
    local idx, n = {}, 0
    for id, s in pairs(skills) do
        local entry = { kind = nil, statuses = {}, cost = s.cost or 0, rel = s.rel }
        if s.rel == REL_FRIENDLIES and s.targetType == TARGET_SINGLE then
            if s.status and s.status > 0 then entry.statuses[s.status] = true end
            for _, eid in ipairs(s.effectIds) do
                local st = effects[eid]
                if st and st > 0 then entry.statuses[st] = true end
            end
            if next(entry.statuses) then
                entry.kind = "buff"
            elseif s.effType == EFFECT_DAMAGE_RECOVERY and s.paramType == PARAM_HP
                and (s.varType == VAR_INCREASE or s.varType == VAR_RATIO_INCREASE) then
                entry.kind = "heal"
            end
        end
        idx[id] = entry
        n = n + 1
    end
    if n > 0 then SkillIdx = idx end
    return n
end

local function hpRatio(bfl, uid)
    local ok, r = pcall(function()
        local p = bfl:GetBattleUnitParameter(uid, true)
        if not (p and p:IsValid()) then return nil end
        local cur, max = p:GetParameterByType(PARAM_HP, false), p:GetMaxParameterByType(PARAM_HP)
        if not max or max <= 0 then return nil end
        return cur / max
    end)
    return ok and r or nil
end

local function hasAnyStatus(bfl, uid, wanted)
    local ok, list = pcall(function()
        return outList(function(t) bfl:GetStatusConditionList(t, uid) end)
    end)
    if not ok then return false end
    for _, st in ipairs(list) do
        if wanted[st] then return true end
    end
    return false
end

-- Skill info from the index (built on first use; unknown ids are cached as empty).
local function skillInfo(skillId)
    if not SkillIdx or not SkillIdx[skillId] then
        buildSkillIndex()
        if SkillIdx and not SkillIdx[skillId] then SkillIdx[skillId] = { kind = nil, statuses = {}, cost = 0 } end
    end
    return SkillIdx and SkillIdx[skillId]
end

local PARAM_MP = 2
local function currentMP(bfl, uid)
    local ok, mp = pcall(function()
        local p = bfl:GetBattleUnitParameter(uid, true)
        if not (p and p:IsValid()) then return nil end
        return p:GetParameterByType(PARAM_MP, false)
    end)
    return ok and mp or nil
end

-- Returns a better target for heal/buff skills, or nil to keep the recorded one.
local function smartTarget(source, actor, skillId, recorded)
    if not cfg.SmartSupport then return nil end
    local info = skillInfo(skillId)
    if not info or not info.kind then return nil end
    local bfl = battleLib()
    local okC, cands = pcall(function()
        return outList(function(t) bfl:GetSkillTargetUnitUniqueIdList(t, actor, skillId, REL_FRIENDLIES, true) end)
    end)
    if not okC or #cands == 0 then return nil end

    if info.kind == "heal" then
        local best, bestR = nil, 2
        for _, uid in ipairs(cands) do
            local r = hpRatio(bfl, uid)
            if r and r < bestR then best, bestR = uid, r end
        end
        if best and bestR < 1 then
            repLog("%s: heal %d -> unit %d (HP %.0f%%)", source, skillId, best, bestR * 100)
            return best
        end
        return nil -- everyone is at full HP: keep the recorded target
    end

    -- buff: keep the recorded target if it still lacks the status, else first ally without it
    local function lacks(uid) return not hasAnyStatus(bfl, uid, info.statuses) end
    for _, uid in ipairs(cands) do
        if uid == recorded and lacks(uid) then return nil end
    end
    local best, bestR = nil, 2
    for _, uid in ipairs(cands) do
        if lacks(uid) then
            local r = hpRatio(bfl, uid) or 1
            if r < bestR then best, bestR = uid, r end
        end
    end
    if best then repLog("%s: buff %d -> unit %d (no buff yet)", source, skillId, best) end
    return best
end

-- Re-send the current actor's last command. Returns true when sent.
local function replay(source)
    local notNow = tr("现在不能重复（请在选指令时使用）", "Can't repeat now (use it while choosing a command)")
    if not Rep.menuOpen then repLog("%s: command menu not open", source); return false, notNow end
    local actor = currentActor()
    if actor == nil or actor < 0 then repLog("%s: no acting unit", source); return false, notNow end
    local cmdType = currentPhase()
    local c = Rep.records[actor .. ":" .. cmdType]
    if not c then repLog("%s: unit %d has no recorded command (type %d)", source, actor, cmdType); return false, tr("这个角色还没有可重复的指令，请手动选择", "No command to repeat for this character yet; choose one") end
    local first = c.items[1]
    if first.isUseItem then repLog("%s: unit %d last used an item, not repeated", source, actor); return false, tr("上次用的是道具，不会重复", "Last command was an item; not repeated") end

    local bfl = battleLib()
    -- IsEnableCommand checks a command-menu entry (e.g. 1 = abilities; a basic attack is its own
    -- entry), not an individual skill, so check the menu the command came from.
    local menuEntry = (c.CommandId ~= -1) and c.CommandId or first.actionId
    local okE, usable = pcall(function() return bfl:IsEnableCommand(actor, menuEntry) end)
    if DEV_REPEAT then repLog("%s: unit %d action %d menu %d IsEnableCommand=%s", source, actor, first.actionId, menuEntry, tostring(usable)) end
    if okE and usable == false then
        repLog("%s: unit %d command menu %d not available now", source, actor, menuEntry)
        return false, tr("上次的指令现在不能用，请手动选择", "Last command isn't available now; choose one")
    end
    -- MP check for skills from a skill menu.
    if c.CommandId ~= -1 then
        local info = skillInfo(first.actionId)
        local cost = info and info.cost or 0
        local mp = currentMP(bfl, actor)
        if cost > 0 and mp and mp < cost then
            repLog("%s: unit %d skill %d needs %d MP, has %d", source, actor, first.actionId, cost, mp)
            return false, tr("MP 不足，请手动选择", "Not enough MP; choose a command")
        end
    end

    local cls = StaticFindObject("/Script/mucha.CPP_BtlCmdDecideDelegateVal")
    local disp = FindFirstOf("CPP_MuchaEventDispatcher")
    if not (cls and cls:IsValid() and disp and disp:IsValid()) then repLog("%s: game objects missing", source); return false, tr("重复失败", "Repeat failed") end
    local v = StaticConstructObject(cls, disp)
    v.CmdType = c.CmdType
    v.isNotConsume = c.isNotConsume
    v.doCalcOrder = c.doCalcOrder
    v.CommandId = c.CommandId
    for i, it in ipairs(c.items) do
        local targets = {}
        if it.IsAll then
            -- "All" (toggled with the all-target button): target everyone the skill can reach in
            -- this battle. The recorded unit ids belong to the earlier battle, so reusing them
            -- could leave a single target.
            local info = skillInfo(it.actionId)
            local rel = (info and (info.rel == REL_FRIENDLIES or info.rel == REL_ENEMIES)) and info.rel or REL_ENEMIES
            local okA, all = pcall(function()
                return outList(function(t) bfl:GetSkillTargetUnitUniqueIdList(t, actor, it.actionId, rel, true) end)
            end)
            if okA and #all > 0 then targets = all
            elseif not okA then repLog("%s: all-target list error %s", source, tostring(all)) end
        end
        if #targets == 0 and not it.IsAll and #it.targets == 1 then
            local okS, smart = pcall(smartTarget, source, actor, it.actionId, it.targets[1])
            if okS and smart then targets = { smart }
            elseif not okS then repLog("%s: smart target error %s", source, tostring(smart)) end
        end
        if #targets == 0 then
            for _, tid in ipairs(it.targets) do
                if unitAlive(tid) then targets[#targets + 1] = tid end
            end
        end
        if #targets == 0 and not it.IsAll then
            local okT, nt = pcall(function() return bfl:GetDefaultSkillTargetUnitUniqueId(actor, it.actionId) end)
            if okT and nt ~= nil and nt >= 0 then targets = { nt } end
        end
        if #targets == 0 then repLog("%s: unit %d has no valid target", source, actor); return false, tr("没有可用的目标，请手动选择", "No valid target; choose one") end

        v.cmdDecideDataList[i] = { actionId = it.actionId, actionUnitUniqueId = it.unit }
        local d = v.cmdDecideDataList[i]
        d.actionId = it.actionId
        d.actionUnitUniqueId = it.unit
        d.isUseItem = it.isUseItem
        d.IsAll = it.IsAll
        d.ParentActionKey.Category = it.pCat
        d.ParentActionKey.ID = it.pId
        for j, tid in ipairs(targets) do d.targetUnitUniqueIdList[j] = tid end
        for j, p in ipairs(it.params) do d.ParameterList[j] = p end
    end
    for i, k in ipairs(c.keys) do
        v.actionKeys[i] = { Category = k[1], ID = k[2] }
        v.actionKeys[i].Category = k[1]
        v.actionKeys[i].ID = k[2]
    end
    disp:ExecuteEvent({ TagName = FName("Delegate.Battle.Cmd.Decide") }, v)
    repLog("%s: unit %d repeated action %d (type %d)", source, actor, first.actionId, c.CmdType)
    return true
end

-- Track the command menu; in auto mode, replay shortly after it opens.
local okMenu, errMenu = pcall(function()
    RegisterHook("/Script/mucha.CPP_MuchaEventDispatcher:ExecuteEvent", function(ctx, tag)
        local okT, t = pcall(function() return tag:get().TagName:ToString() end)
        if not okT then return end
        if t == "Delegate.Battle.Cmd.List.Begin" then
            Rep.menuOpen = true
            Rep.menuSerial = Rep.menuSerial + 1
            if not Hud.inBattle then Hud.inBattle = true; updateBadge() end
            if DEV_REPEAT then repLog("menu open: actor %d phase %d", currentActor(), currentPhase()) end
            if cfg.AutoRepeat then
                local serial = Rep.menuSerial
                gameDelay(350, function()
                    if cfg.AutoRepeat and Rep.menuOpen and Rep.menuSerial == serial then
                        local ok, sent, why = pcall(replay, "auto")
                        if not ok then log("auto repeat error: %s", tostring(sent))
                        elseif not sent and why then toast(tr("自动重复：", "Auto repeat: ") .. why, AMBER, 2200) end
                    end
                end)
            end
        elseif t == "Delegate.Battle.Cmd.List.End" then
            Rep.menuOpen = false
        end
    end)
end)
if not okMenu then log("repeat: could not hook battle events: %s", tostring(errMenu)) end

bind("RepeatCommandKey", function()
    local ok, sent, why = pcall(replay, "key")
    if not ok then log("repeat error: %s", tostring(sent)); toast(tr("重复失败", "Repeat failed"), AMBER); return end
    if sent then toast(tr("重复上次指令", "Repeated last command"), GREEN, 1200) else toast(why or tr("重复失败", "Repeat failed"), AMBER, 2200) end
end)

bind("AutoRepeatKey", function()
    cfg.AutoRepeat = not cfg.AutoRepeat
    saveConfig(); writeStatus(); report("hotkey auto-repeat " .. (cfg.AutoRepeat and "ON" or "OFF"))
    noteAutoRepeat()
    -- If a menu is already open, act on it right away.
    if cfg.AutoRepeat and Rep.menuOpen then pcall(replay, "auto") end
end)

------------------------------------------------------------------------
-- Gamepad bindings, polled from the game's own input state (PlayerController:IsInputKeyDown).
-- Format: "R3", "LT+Y", "LB+RB+A" (Xbox names; PlayStation pads map Cross=A, Circle=B,
-- Square=X, Triangle=Y). Back paddles are not separate buttons to games: map them to a
-- button/chord here or to a keyboard key in Steam Input. Pad bindings apply live.
------------------------------------------------------------------------
local PadNames = {
    A = "Gamepad_FaceButton_Bottom", B = "Gamepad_FaceButton_Right",
    X = "Gamepad_FaceButton_Left", Y = "Gamepad_FaceButton_Top",
    LB = "Gamepad_LeftShoulder", RB = "Gamepad_RightShoulder",
    LT = "Gamepad_LeftTrigger", RT = "Gamepad_RightTrigger",
    L3 = "Gamepad_LeftThumbstick", R3 = "Gamepad_RightThumbstick",
    UP = "Gamepad_DPad_Up", DOWN = "Gamepad_DPad_Down", LEFT = "Gamepad_DPad_Left", RIGHT = "Gamepad_DPad_Right",
    BACK = "Gamepad_Special_Left", VIEW = "Gamepad_Special_Left", SELECT = "Gamepad_Special_Left",
    START = "Gamepad_Special_Right", MENU = "Gamepad_Special_Right",
}
local PadBindings = {
    { cfgKey = "ToggleEncounterPad", action = "ToggleEncounterKey" },
    { cfgKey = "CycleMultiplierPad", action = "CycleMultiplierKey" },
    { cfgKey = "RepeatCommandPad",   action = "RepeatCommandKey" },
    { cfgKey = "AutoRepeatPad",      action = "AutoRepeatKey" },
}
local padHeld = {}
local padWarned = {}
local fkeyCache = {}
local cachedPC = nil

local function parsePad(spec)
    local keys = {}
    for part in tostring(spec or ""):gmatch("[^+%s]+") do
        local k = PadNames[part:upper()]
        if not k then
            if not padWarned[spec] then padWarned[spec] = true; log("unknown gamepad binding '%s'", tostring(spec)) end
            return nil
        end
        keys[#keys + 1] = k
    end
    if #keys == 0 then return nil end
    return keys
end

local function fkey(name)
    local k = fkeyCache[name]
    if not k then
        k = { KeyName = FName(name) }
        fkeyCache[name] = k
    end
    return k
end

local function playerController()
    if cachedPC and cachedPC:IsValid() then return cachedPC end
    cachedPC = nil
    local pcs = FindAllOf("PlayerController") or {}
    for _, pc in ipairs(pcs) do
        if pc:IsValid() and not pc:GetFullName():find("Default__", 1, true) then
            cachedPC = pc
            break
        end
    end
    return cachedPC
end

-- Pad recording for the settings window: it can't read the controller itself when tools like
-- HidHide hide it from other programs, so it writes capture_request.txt ("id=<n>") and the mod
-- records the next button / chord here, then answers in capture_result.txt.
local CAPTURE_REQ = DIR .. "/capture_request.txt"
local CAPTURE_RES = DIR .. "/capture_result.txt"
local CaptureOrder = { "LT", "RT", "LB", "RB", "A", "B", "X", "Y", "L3", "R3", "UP", "DOWN", "LEFT", "RIGHT", "BACK", "START" }
local Cap = nil         -- { id, t0, union = {token = true}, seen }
local lastCapId = nil
os.remove(CAPTURE_REQ)  -- drop a request left over from an earlier session

local function captureFinish(chord)
    if not Cap then return end
    writeFile(CAPTURE_RES, "id=" .. Cap.id .. "\nchord=" .. (chord or "") .. "\n")
    os.remove(CAPTURE_REQ)
    Cap = nil
    if chord and chord ~= "" then toast(tr("已录制手柄按键：", "Pad binding recorded: ") .. chord, GREEN, 2500) else toast(tr("手柄录制已取消", "Pad recording cancelled"), GREY) end
end

-- Called from the 1 s loop: pick up a new request.
local function checkCaptureRequest()
    local t = readFile(CAPTURE_REQ)
    local id = t and t:match("id=(%d+)")
    if not id then
        if Cap then Cap = nil end
        return
    end
    if id == lastCapId then return end
    lastCapId = id
    Cap = { id = id, t0 = os.time(), union = {}, seen = false }
    toast(tr("请按下要绑定的手柄键或组合键（全部松开后生效）", "Press a pad button or combo (set when all are released)"), AMBER, 4000)
end

local function captureTick(pc)
    if os.time() - Cap.t0 > 10 then captureFinish(nil); return end
    local any = false
    for _, tok in ipairs(CaptureOrder) do
        local ok, down = pcall(function() return pc:IsInputKeyDown(fkey(PadNames[tok])) end)
        if ok and down then any = true; Cap.union[tok] = true end
    end
    if any then Cap.seen = true; return end
    if Cap.seen then
        local tokens = {}
        for _, tok in ipairs(CaptureOrder) do if Cap.union[tok] then tokens[#tokens + 1] = tok end end
        if #tokens > 3 then
            toast(tr("最多只能组合 3 个键，请重新按", "At most 3 buttons; press again"), AMBER, 2500)
            Cap.union, Cap.seen, Cap.t0 = {}, false, os.time()
            return
        end
        captureFinish(table.concat(tokens, "+"))
    end
end

gameLoop(1000, function() checkCaptureRequest() end)

gameLoop(50, function()
    if Cap then
        local pc = playerController()
        if pc then captureTick(pc) end
        return  -- no pad actions while recording
    end
    do
        local active = {}
        for _, b in ipairs(PadBindings) do
            local keys = parsePad(cfg[b.cfgKey])
            if keys then active[#active + 1] = { b = b, keys = keys } end
        end
        if #active == 0 then return end
        local pc = playerController()
        if not pc then return end
        for _, a in ipairs(active) do
            local all = true
            for _, k in ipairs(a.keys) do
                local ok, down = pcall(function() return pc:IsInputKeyDown(fkey(k)) end)
                if not ok then
                    if not padWarned.query then padWarned.query = true; log("gamepad query failed: %s", tostring(down)) end
                    all = false
                    break
                end
                if not down then all = false; break end
            end
            local id = a.b.cfgKey
            if all and not padHeld[id] then
                padHeld[id] = true
                local fn = Actions[a.b.action]
                if fn then
                    if DEV_REPEAT then devAppend("PAD " .. id .. " = " .. tostring(cfg[id]) .. " fired") end
                    local okA, errA = pcall(fn)
                    if not okA then log("gamepad action error: %s", tostring(errA)) end
                end
            elseif not all then
                padHeld[id] = false
            end
        end
    end
end, 250)

------------------------------------------------------------------------
-- Persistent Limit Burst gauge: while a battle runs, each party member's LB is recorded once a
-- second (by character id); when the next battle starts it is written back. Kept in lb_state.txt
-- so it also survives a game restart (it is not tied to a save slot).
------------------------------------------------------------------------
local LB_STATE = DIR .. "/lb_state.txt"
local LB = { saved = {}, inBattle = false, restored = false, dirty = false }
do
    local t = readFile(LB_STATE)
    if t then
        for id, v in t:gmatch("(%d+)=(%d+)") do LB.saved[tonumber(id)] = tonumber(v) end
    end
end
local function saveLBState()
    local lines = {}
    for id, v in pairs(LB.saved) do lines[#lines + 1] = id .. "=" .. v end
    table.sort(lines)
    writeFile(LB_STATE, table.concat(lines, "\n") .. "\n")
    LB.dirty = false
end
local function partyLB(fn)
    local bfl = battleLib()
    for uid = 0, 3 do
        pcall(function()
            local p = bfl:GetBattleUnitParameter(uid, true)
            if not (p and p:IsValid()) then return end
            fn(bfl, uid, p:GetUnitId())
        end)
    end
end
gameLoop(1000, function()
    local u = FindFirstOf("CPP_BtlUnit")
    local battle = u ~= nil and u:IsValid()
    if not battle then
        if LB.inBattle then
            LB.inBattle, LB.restored = false, false
            if LB.dirty then saveLBState() end
        end
        return
    end
    LB.inBattle = true
    if not cfg.PersistentLB then return end
    if not LB.restored then
        local n, done = 0, false
        partyLB(function(bfl, uid, unitId)
            done = true
            local want = LB.saved[unitId]
            if want and want > 0 then
                local cur = bfl:GetUnitLimitBurstPoint(uid) or 0
                if want > cur then bfl:SetBattleUnitLimitBurstPoint(unitId, want); n = n + 1 end
            end
        end)
        if done then
            LB.restored = true
            if n > 0 then log("persistent LB: restored %d character(s)", n) end
        end
        return
    end
    partyLB(function(bfl, uid, unitId)
        local v = bfl:GetUnitLimitBurstPoint(uid)
        if type(v) == "number" and v >= 0 and LB.saved[unitId] ~= v then LB.saved[unitId] = v; LB.dirty = true end
    end)
end)

------------------------------------------------------------------------
-- Add items (from the settings window). The window writes item_request.txt
-- ("id=<serial>", "item=<item id>", "num=<count>"; item=0 only refreshes the list). The mod
-- answers with items.txt (every item in the game's language with the current count) and
-- item_result.txt. Items go straight into the save's inventory (CPP_BFL_SaveDataInventory
-- AddInventory), capped at the item's carry limit; they are kept once the game is saved.
------------------------------------------------------------------------
local ITEM_REQ = DIR .. "/item_request.txt"
local ITEM_RES = DIR .. "/item_result.txt"
local ITEM_LIST = DIR .. "/items.txt"
local lastItemReq = nil
os.remove(ITEM_REQ)

local function itemLibs()
    local inv = StaticFindObject("/Script/mucha.Default__CPP_BFL_SaveDataInventory")
    local item = StaticFindObject("/Script/mucha.Default__CPP_BFL_Item")
    if inv and inv:IsValid() and item and item:IsValid() then return inv, item end
    return nil
end

-- Items that can be added: consumables/materials (1) and equipment (3). Key items (2) and
-- artifacts (4, e.g. the chocobo saddle) unlock story features, so they are left out.
-- { id, type, sort, name } in the game's language, sorted by type then the game's sort order.
local ADDABLE_TYPES = { 1, 3 }
local itemCache = nil
local function allItems(item)
    if itemCache then return itemCache end
    local list = {}
    for _, t in ipairs(ADDABLE_TYPES) do
        local arr = item:GetAllItemIdListByType(t) or {}
        for i = 1, #arr do
            local id = arr[i]
            if type(id) ~= "number" then id = id:get() end
            local okN, name = pcall(function() return item:GetItemName(id):ToString() end)
            name = okN and tostring(name):gsub("[\t\r\n]", " ") or ""
            if id > 0 and name ~= "" then
                local okS, sort = pcall(function() return item:GetItemDataById(id).SortId end)
                list[#list + 1] = { id = id, type = t, sort = (okS and type(sort) == "number") and sort or id, name = name }
            end
        end
    end
    table.sort(list, function(a, b)
        if a.type ~= b.type then return a.type < b.type end
        if a.sort ~= b.sort then return a.sort < b.sort end
        return a.id < b.id
    end)
    -- The item tables load with the game's data; keep the list once it has something.
    if #list > 0 then itemCache = list end
    return list
end

-- A save is loaded when the player has a character on a map. (The title screen already has
-- a new game's inventory, so the inventory alone can't tell.)
local function saveLoaded()
    local pc = playerController()
    if not pc then return false end
    local ok, valid = pcall(function() return pc.Pawn ~= nil and pc.Pawn:IsValid() end)
    return ok and valid == true
end

local function writeItemList(items, inv, item, loaded)
    local lines = { "save=" .. (loaded and "1" or "0") }
    for _, it in ipairs(items) do
        local n = 0
        if loaded then
            local ok, v = pcall(function() return item:GetInventoryItemNum(it.id) end)
            if ok and type(v) == "number" then n = v end
        end
        lines[#lines + 1] = string.format("%d\t%d\t%d\t%s", it.id, it.type, n, it.name)
    end
    writeFile(ITEM_LIST, table.concat(lines, "\n") .. "\n")
end

local function checkItemRequest()
    local t = readFile(ITEM_REQ)
    local serial = t and t:match("id=(%d+)")
    if not serial or serial == lastItemReq then return end
    lastItemReq = serial
    os.remove(ITEM_REQ)
    local want = tonumber(t:match("item=(%d+)")) or 0
    local num = tonumber(t:match("num=(%d+)")) or 0
    local inv, item = itemLibs()
    local function reply(result, extra)
        writeFile(ITEM_RES, "id=" .. serial .. "\nresult=" .. result .. "\n" .. (extra or ""))
    end
    if not inv then reply("nogame"); return end
    local items = allItems(item)
    local loaded = saveLoaded()
    if want > 0 then
        local entry
        for _, it in ipairs(items) do if it.id == want then entry = it; break end end
        if not entry then
            reply("unknown")
        elseif not loaded then
            reply("nosave")
        else
            local have = item:GetInventoryItemNum(want) or 0
            local okM, max = pcall(function() return item:GetMaxItemNumById(want) end)
            max = (okM and type(max) == "number" and max > 0) and max or 99
            if cfg.ItemLimit and cfg.ItemLimit > max and itemLimitApplied == cfg.ItemLimit then max = cfg.ItemLimit end
            local add = math.min(num, max - have)
            if add <= 0 then
                reply("full", string.format("item=%d\ncount=%d\nmax=%d\n", want, have, max))
                toast(string.format(tr("%s 已达持有上限（%d）", "%s is already at the carry limit (%d)"), entry.name, max), AMBER, 2500)
            else
                inv:AddInventory(want, add)
                local now = item:GetInventoryItemNum(want) or (have + add)
                reply("ok", string.format("item=%d\nadded=%d\ncount=%d\nmax=%d\n", want, now - have, now, max))
                toast(string.format(tr("已添加 %s ×%d（现有 %d）", "Added %s x%d (now %d)"), entry.name, now - have, now), GREEN, 2500)
                log("add item %d (%s): +%d -> %d (max %d)", want, entry.name, now - have, now, max)
            end
        end
    else
        reply(loaded and "list" or "nosave")
    end
    writeItemList(items, inv, item, loaded)
end

gameLoop(500, function()
    local ok, err = pcall(checkItemRequest)
    if not ok then
        log("add item error: %s", tostring(err))
        local serial = lastItemReq or "0"
        writeFile(ITEM_RES, "id=" .. serial .. "\nresult=error\n")
    end
end)

------------------------------------------------------------------------
-- Map markers for chests and shining spots (scripts/markers.lua, based on
-- "Item and Chest Markers" by ZArkadia). Needs the zzz_TreasureMinimap_P pak.
------------------------------------------------------------------------
do
    local okM, markers = pcall(require, "markers")
    if okM and type(markers) == "table" then
        local okS, err = pcall(markers.start, { enabled = function() return cfg.MapMarkers end, log = log })
        if not okS then log("markers: start failed: %s", tostring(err)) end
    else
        log("markers: module not loaded: %s", tostring(markers))
    end
end

log("loaded from %s (%s = encounters, %s = cycle multiplier, %s = repeat command, %s = auto repeat; pad: repeat %s, auto %s)", DIR,
    cfg.ToggleEncounterKey, cfg.CycleMultiplierKey, cfg.RepeatCommandKey, cfg.AutoRepeatKey,
    tostring(cfg.RepeatCommandPad), tostring(cfg.AutoRepeatPad))

------------------------------------------------------------------------
-- Open the settings window when the game starts (the window keeps itself single-instance
-- and closes when the game exits). Uses `start`, so it returns immediately.
------------------------------------------------------------------------
if cfg.AutoOpenSettings then
    local ps1 = (DIR .. "/Settings.ps1"):gsub("/", "\\")
    local cmd = string.format(
        'start "" conhost.exe --headless powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%s" -FromGame', ps1)
    local ok, res = pcall(os.execute, cmd)
    if ok then
        log("settings window launch requested (result %s)", tostring(res))
    else
        log("could not open settings window: %s", tostring(res))
    end
end
