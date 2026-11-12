Meal Buffet — REFramework mod for Monster Hunter Wilds
====================================================

Applies any canteen meal, and any consumable buff, to YOUR hunter on demand,
without walking to the canteen and without spending a Meal Voucher, ingredients
or items. Works in the hub, at camp, and during a quest.

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
  3. Pick Meals or Consumables at the top of the panel.

  Meals:
  - < Prev / Next > pick a meal set. Its base stats and fixed skills are
    listed.
  - For each extra buff slot, < / > cycles: game roll -> none -> a specific
    buff. Each picked buff shows a short description.
  - Press "Apply meal". The active skills list at the top shows what landed.
  - Press "Clear meal" to remove the active meal (this is the Meal Stripper
    strip).

  Consumables:
  - Drugs, seeds, pills, powders and drinks. Tick what you want and press
    "Apply selected", or press "Apply" on a single row.
  - "Standard" applies a built-in set. "Save selection" stores your ticks in
    one of the four unnamed slots; "Apply" on a slot applies it later.
  - "Item Prolonger" toggles the duration bonus; < > overrides the level.
  - "Auto preset on quest start" applies the selected preset once per quest.
  - "Auto Hot/Cool Drink on quest start" applies one drink based on the
    quest locale: ST103 Oilwell Basin -> Cool Drink, ST104 Iceshard Cliffs ->
    Hot Drink, ST402 Omega Planetes -> Hot Drink.
  - Nothing is consumed and nothing has to be in your pouch.

NOTES
-----
- Meals, fixed skills, buff durations and item buffs come from the game at
  runtime, so a title update shows up without a mod update.
- Applying a meal replaces whatever meal is already active. Drugs share a slot
  with their mega version, and a seed shares a slot with its pill.
- Selections, the four preset slots and both auto toggles are saved to
  reframework/data/meal_buffet.json.
- If a game patch renames an internal field or method, the panel reports the
  failing call instead of throwing.
- Reload the script any time: REFramework menu -> "Script" -> "Reset scripts".
- No hooks: the auto toggles poll the quest state a few times a second, and
  writes happen only on Apply/Clear or when a toggle fires.

CREDITS
-------
- REFramework by praydog
- Mod structure follows Hunt Dumper (MIT) by thieleju
- This project: Apache-2.0
