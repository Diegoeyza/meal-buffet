Meal Buffet — REFramework mod for Monster Hunter Wilds
====================================================

Applies any canteen meal to YOUR hunter on demand, without walking to the
canteen and without spending a Meal Voucher. Pick one of the game's meal sets,
choose or reroll the two extra buffs, then press Apply. Works in the hub, at
camp, and during a quest.

This mod replaces Meal Stripper: the Clear meal button is the same one-click
meal strip, and applying a new meal replaces the active one directly, so you
do not need to strip and re-eat. If Meal Stripper is installed, remove it.

Only your own local hunter is ever touched: other players are never selected,
game files are not modified, save data is not written, and nothing talks to
the network.

REQUIREMENTS
------------
- Monster Hunter Wilds
- REFramework for MH Wilds (install dinput8.dll first)

INSTALL (Vortex or manual)
--------------------------
The archive is already laid out for the game folder.

Manual:
  1. Install REFramework if you have not already.
  2. Extract this archive into your game folder so you get
        <game>\reframework\autorun\meal_buffet.lua
     Default Steam path:
        ...\steamapps\common\MonsterHunterWilds\
  3. Launch the game; open the REFramework menu -> "Script Generated UI" ->
     "Meal Buffet" to confirm it loaded.

Vortex:
  Install the archive normally; it maps into the game's reframework folder.

USAGE
-----
  1. Press Insert to open the REFramework menu.
  2. Script Generated UI -> Meal Buffet.
  3. < Prev / Next > pick a meal set. Its base stats and fixed skills are
     listed.
  4. For each extra buff slot, < / > cycles: game roll -> none -> a specific
     buff. Each picked buff shows a short description.
  5. Press "Apply meal". The active skills list at the top shows what landed.
  6. Press "Clear meal" to remove the active meal (this is the Meal Stripper
     strip).
  - Works outside a quest (hub, camp) and during a quest.
  - No Meal Voucher and no ingredients are consumed.

NOTES
-----
- Meals, fixed skills and the extra-buff pool come from game master data at
  runtime, so a title update that adds meals shows up without a mod update.
- Applying a meal replaces whatever meal is already active.
- The selection (meal + buffs) is saved to reframework/data/meal_buffet.json.
- If a game patch renames an internal field or method, the panel reports the
  failing call instead of throwing.
- Reload the script any time: REFramework menu -> "Script" -> "Reset scripts".
- No hooks, no per-frame work: writes happen only when you press Apply/Clear.

CREDITS
-------
- REFramework by praydog
- Mod structure follows Hunt Dumper (MIT) by thieleju
- This project: Apache-2.0
