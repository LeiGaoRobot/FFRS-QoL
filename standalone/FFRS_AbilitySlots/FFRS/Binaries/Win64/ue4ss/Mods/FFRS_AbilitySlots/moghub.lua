-- FFRS Ability Slots settings page for MogHub (https://github.com/jesus-seijas-sp/ffr-moghub).
-- MogHub runs this file because the folder has a moghub.lua; without MogHub nothing reads it.
-- It edits config.ini, which Scripts/main.lua reads again every second.
local mod, kit = ...

local items = {
    { key = "AbilitySlots", label = "Ability slots", type = "number", min = 8, max = 16, step = 1, default = 12,
      help = "Ability slots per character (the game has 8). Load a save to see it. More slots need more AP. Lowering it keeps abilities already in the extra slots." },
    { key = "APCapacityBonus", label = "Ability AP limit +", type = "number", min = 0, max = 9999, step = 50,
      default = 0, format = "+%d", help = "Raises every character's AP limit for equipped abilities. Load a save to see it." },
    { key = "FitEquipmentScreen", label = "Fit the equipment screen", type = "toggle", default = true,
      help = "Makes the rows on the equipment screen shorter so every slot fits on the panel." },
}

local cfg = mod:settings{ file = "config.ini", items = items }
cfg:onChange(function(key, value) mod:log("%s = %s", key, tostring(value)) end)
