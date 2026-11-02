FFRS Ability Slots
==================

More ability slots for FINAL FANTASY RESONANCE (Steam PC): 8 to 16 per character, an optional
bonus to the ability AP limit, and an equipment screen that shrinks its rows so every slot fits.
This is the ability-slot part of FFRS QoL as a mod of its own.

Install
1. Install UE4SS first (UE4SS_v3.0.1 experimental build, extracted into FFRS\Binaries\Win64).
2. Drag the FFRS folder from this zip into the game folder (Steam > right-click the game >
   Manage > Browse local files) and merge.
3. Start the game and load a save.

Settings: FFRS\Binaries\Win64\ue4ss\Mods\FFRS_AbilitySlots\config.ini
  Slots     ability slots per character, 8 to 16 (default 12)
  APBonus   extra ability AP for every character (default 0)
  FitPanel  shrink the equipment screen rows so all slots fit (default true)
Changes are read within 3 seconds; load a save to see new slots and AP.
More slots need more AP, so raise APBonus as well if abilities don't fit.

Notes
- If FFRS QoL is installed and enabled, this mod does nothing: FFRS QoL has the same settings
  (Ability slots, Ability AP limit +). You only need one of the two.
- Lowering Slots keeps abilities already equipped in the extra slots until you unequip them.
- Steam Deck / Linux: set the launch option WINEDLLOVERRIDES="dwmapi=n,b" %command% so UE4SS loads.
- Uninstall: delete the FFRS_AbilitySlots folder. Saves are not touched otherwise; abilities in
  extra slots stay in a save made with them, so unequip them first to get back to exactly 8.

https://github.com/LeiGaoRobot/FFRS-QoL

----------------------------------------------------------------------
中文：能力栏扩展独立版。每人 8–16 格能力栏、可选能力 AP 上限加成，装备画面自动缩小行高放得下。
需要先装 UE4SS，把压缩包里的 FFRS 文件夹拖进游戏目录合并即可。
设置在 Mods\FFRS_AbilitySlots\config.ini（Slots 格数、APBonus AP 加成、FitPanel 自适应），改完读档生效。
已启用 FFRS QoL 时本 mod 不起作用（FFRS QoL 里有相同设置），两者装一个即可。
