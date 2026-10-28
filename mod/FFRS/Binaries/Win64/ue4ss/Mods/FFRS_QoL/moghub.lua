-- FFRS QoL settings page for MogHub (https://github.com/jesus-seijas-sp/ffr-moghub).
--
-- MogHub runs this file as a plugin because the folder has a moghub.lua; without MogHub nothing reads it.
-- FFRS QoL itself is Scripts/main.lua, which UE4SS runs as usual. This page edits the same config.ini as
-- the settings window (Settings.ps1), and main.lua reads that file again every second, so a change made
-- here or in the window applies in game at once and shows up on the other side.
--
-- Keys and pad bindings, the cycle steps and "Add item" stay in the settings window: they need key
-- capture or a long item list. Settings not declared here are left as they are in config.ini.
local mod, kit = ...

local HAS_ITEM_LIMIT = kit.exists(mod:path("ItemLimit.ps1"))
local HAS_WINDOW = kit.exists(mod:path("Settings.ps1"))

local x = "x%g"
-- Defaults and ranges follow main.lua (Defaults, clampMult, IntRange), so Reset gives the mod's own defaults.
local function mult(key, label, default, help, min, max, step)
    return { key = key, label = label, type = "number", min = min or 0, max = max or 10, step = step or 0.5,
             default = default, format = x, help = help }
end

local function openWindow()
    local ps1 = mod:path("Settings.ps1"):gsub("/", "\\")
    local cmd = string.format(
        'start "" conhost.exe --headless powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%s" -FromGame', ps1)
    local ok, res = pcall(os.execute, cmd)
    if not ok then return nil, tostring(res) end
    return mod:t("windowOpened", "Settings window opened (switch to it with Alt+Tab)")
end

local items = {
    { header = "Field" },
    { key = "EncountersEnabled", label = "Random encounters", type = "toggle", default = true,
      help = "Off: walking never starts a random battle. Story and fixed battles still happen. Hotkey: F6 (change it in the settings window)." },
    { key = "EncounterRate", label = "Encounter rate", type = "number", min = 0.1, max = 5, step = 0.1, default = 1,
      format = x, help = "How often random battles happen: 2 = twice as often, 0.5 = half as often." },
    { key = "MapMarkers", label = "Chest and item markers", type = "toggle", default = true,
      help = "Shows treasure chests and items you haven't picked up on the map and minimap." },

    { header = "Battle rewards" },
    mult("ExpMultiplier", "EXP", 2, "EXP from battles. Also applied to encounters settled by auto-resolve mods."),
    mult("MoneyMultiplier", "Gil", 2, "Gil from battles. Also applied to encounters settled by auto-resolve mods."),
    mult("MRPointMultiplier", "MR points", 1, "Mastery points earned by equipped Visions."),
    mult("APMultiplier", "AP", 1, "AP from battles."),
    mult("DropMultiplier", "Item drops", 1, "Drop chance x this multiplier, up to 100%."),
    { key = "RareAlwaysDrop", label = "Rare items always drop", type = "toggle", default = false,
      help = "Every enemy that has a rare item drops it." },

    { header = "Battle" },
    mult("BattleSpeedMultiplier", "Battle speed", 1, "Stacks with the game's own 1x / 1.5x / 2x speed button.", 0.5, 4, 0.5),
    { key = "AlwaysEscape", label = "Escape always succeeds", type = "toggle", default = false,
      help = "Only in battles that allow fleeing; boss and story battles are not affected." },
    mult("LBGainMultiplier", "Limit Burst gain", 1, "How fast the Limit Burst gauge fills."),
    { key = "PersistentLB", label = "Keep Limit Burst between battles", type = "toggle", default = false,
      help = "Each character's Limit Burst gauge carries over to the next battle." },
    { key = "LibraScanAll", label = "Libra scans all enemies", type = "toggle", default = true,
      help = "Libra and Mechamog Scan (and items that cast them) scan every enemy at once. The bestiary and weaknesses update as usual. Only the skill table in memory changes." },
    { key = "AutoLibra", label = "Auto Libra", type = "toggle", default = false,
      help = "Every enemy is scanned as the battle starts, weaknesses included, even the first time you meet it. Like a real Libra it goes into the bestiary and stays once you save, even if you turn this off." },

    { header = "Repeat last command" },
    { key = "AutoRepeat", label = "Auto repeat", type = "toggle", default = false,
      help = "A simple auto battle: each character reuses their last command. Characters without one are chosen by hand. Hotkey: F8." },
    { key = "SmartSupport", label = "Smart targets for support skills", type = "toggle", default = true,
      help = "When repeating, heals go to the ally with the lowest HP and buffs to allies that don't have them yet." },

    { header = "Items and abilities" },
}

if HAS_ITEM_LIMIT then
    items[#items + 1] = { key = "ItemLimit", label = "Carry limit", type = "number", min = 99, max = 9999, step = 100,
        default = 99, help = "Most of each item you can hold. The game uses 99; set 99 to restore it." }
end
items[#items + 1] = { key = "APCapacityBonus", label = "Ability AP limit +", type = "number", min = 0, max = 9999,
    step = 50, default = 0, format = "+%d", help = "Raises every character's AP limit for equipped abilities. Load a save to see it." }
items[#items + 1] = { key = "AbilitySlots", label = "Ability slots", type = "number", min = 8, max = 12, step = 1,
    default = 8, help = "Ability slots per character (the game has 8). Load a save to see it. More slots need more AP. Lowering it keeps abilities already in the extra slots." }

if HAS_WINDOW then
    items[#items + 1] = { header = "Settings window" }
    items[#items + 1] = { label = "Open the settings window", type = "action", button = "Open", run = mod:action(openWindow),
        help = "The full settings window (Windows only): hotkeys and pad buttons, multiplier cycle steps, Add item." }
    items[#items + 1] = { key = "AutoOpenSettings", label = "Open the window with the game", type = "toggle", default = true,
        help = "Opens the settings window every time the game starts." }
    items[#items + 1] = { key = "UILanguage", label = "Window language", type = "choice", default = "auto",
        choices = { { "auto", "Auto" }, { "zh", "中文" }, { "en", "English" } },
        help = "Language of the settings window and of FFRS QoL's in-game notices." }
end

-- The same file the mod and the settings window use (the default would be a config.ini of our own).
local cfg = mod:settings{ file = "config.ini", items = items }

cfg:onChange(function(key, value) mod:log("%s = %s", key, tostring(value)) end)
mod:log("settings page ready (item limit %s, window %s)", HAS_ITEM_LIMIT and "yes" or "no", HAS_WINDOW and "yes" or "no")
