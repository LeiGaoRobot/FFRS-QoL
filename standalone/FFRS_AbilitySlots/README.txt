FFRS Ability Slots 1.0.0 - FINAL FANTASY RESONANCE
====================================================

More ability slots for every character: 8 (the game's own) up to 16, 12 by default.
The equipment screen makes its rows shorter so every slot fits on the panel.
Abilities in the extra slots work on the map and in battle like the others.

This is the ability slot part of FFRS QoL on its own, for people who only want the slots.
If you use FFRS QoL, you don't need this: FFRS QoL has the same setting, and this mod turns
itself off when FFRS QoL is installed.

Requirements
------------
UE4SS, experimental build (the official 3.0.1 release is too old for this game):
https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest
Download UE4SS_v3.0.1-....zip (not the zDEV one) and extract it into FFRS\Binaries\Win64,
so that dwmapi.dll and the ue4ss folder sit next to FFRS-Win64-Shipping.exe.
Use engine version 5.6 in ue4ss\UE4SS-settings.ini ([EngineVersionOverride] MajorVersion = 5,
MinorVersion = 6) if UE4SS doesn't detect it. FFRS QoL and most FFRS UE4SS mods ship this file.

Install
-------
Drag the FFRS folder from this archive into the game folder (the one with FFRS.exe).
The mod starts by itself (enabled.txt), no need to edit mods.txt.

Settings
--------
FFRS\Binaries\Win64\ue4ss\Mods\FFRS_AbilitySlots\config.ini (open with Notepad):

  AbilitySlots=12        slots per character, 8 to 16
  APCapacityBonus=0      extra AP limit for every character; more slots need more AP
  FitEquipmentScreen=1   1 = shrink the equipment screen rows so every slot fits

Changes are read within a second. Slot count and AP limit apply when a save is loaded,
so load your save again after changing them. With MogHub (Nexus mod 110) installed, the
same settings are in the game's Mods menu.

Good to know
------------
- At 16 slots with 4-accessory mods (6 equipment rows) the rows get small and the Vision row
  gets shorter too, so everything stays on the panel.
- Steam Deck / Linux (Proton): set the game's launch option to
  WINEDLLOVERRIDES="dwmapi=n,b" %command%  so UE4SS loads.
- Lowering the slot count keeps abilities that are already in the extra slots; you can still
  unequip them.
- Uninstall: unequip the abilities in slots 9 and up (or keep them, the game keeps them in the
  save) and delete the FFRS_AbilitySlots folder.
- Single-player only. Back up your saves before trying mods.

Source: https://github.com/LeiGaoRobot/FFRS-QoL (MIT license). Part of FFRS QoL.
