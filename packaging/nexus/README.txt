Meal Buffet — REFramework mod for Monster Hunter Wilds
====================================================

Applies any canteen meal buff to YOUR hunter on demand, without walking to the
canteen and without spending a Meal Voucher. Pick one of the game's base meals
(the list is read from the game's meal master data at runtime, never
hardcoded), pick or reroll the extra meal skills, then press Apply. Works in
the hub, at camp, and mid-quest.

This mod is in development. It only writes meal state on your own local
hunter: it never selects other players, does not modify game files, does not
write save data, and does not talk to the network.

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
  3. Pick a base meal from the list.
  4. Pick the extra meal skills, or reroll them, until you have the set you
     want.
  5. Press "Apply". The meal buff lands on your hunter immediately.
  - Works outside a quest (hub, camp) and during a quest.
  - No Meal Voucher and no ingredients are consumed.

NOTES
-----
- Meals and skills are enumerated from game master data, so a title update
  that adds meals shows up without a mod update.
- If a game patch renames an internal meal field, the mod logs a per-field
  miss instead of erroring.
- Reload the script any time: REFramework menu -> "Script" -> "Reset scripts".

CREDITS
-------
- REFramework by praydog
- Mod structure follows Hunt Dumper (MIT) by thieleju
- This project: Apache-2.0
