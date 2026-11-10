# Nexus page — Meal Buffet v0.1.1

Upload `dist/MealBuffet-0.1.1.zip` as the main file.

The Nexus mod description field uses **BBCode** (not Markdown). Paste the block
below straight into the Description field (BBCode/source view).

---

**Title:**

```
Meal Buffet — Eat Any Meal, Anywhere (REFramework)
```

**Short description:**

```
Applies any canteen meal buff to your own hunter on demand, from the REFramework menu. Pick a meal, pick or reroll the extra skills, press Apply. No canteen trip, no Meal Voucher spent.
```

**Full description (BBCode — paste as-is):**

```
[size=6][b]Meal Buffet[/b][/size]

Applies any canteen meal buff to your hunter [b]on demand[/b], straight from the REFramework menu — no walk to the canteen, no Meal Voucher, no ingredients used.

Pick one of the game's base meals, pick or reroll the extra meal skills, then press Apply. Works in the hub, at camp, and mid-quest.

[line]

[size=5][b]What it does[/b][/size]

The meal you are currently under (its buff, its timer and its extra food skills) lives in a small state block on your hunter. Meal Buffet builds the same state the canteen would build for the meal you choose, and applies it to your own hunter.

[list]
[*][b]Meal list[/b] — every base meal the game defines, read from the game's own master data at runtime. Nothing is hardcoded, so meals added by a title update appear without a mod update.
[*][b]Extra skills[/b] — pick the random meal skills yourself, or reroll them until you like the set. Each active or picked skill is listed with a short description of what it does.
[*][b]Apply[/b] — puts the selected meal on your hunter immediately.
[*]No canteen trip and no Meal Voucher spent. Your ingredients are untouched.
[/list]

[line]

[size=5][b]How to use[/b][/size]

[list=1]
[*]Install REFramework, then extract this archive into your game folder (Vortex: install normally). You should end up with:
[code]<game>\reframework\autorun\meal_buffet.lua[/code]
[*]In game, press [b]Insert[/b] to open REFramework → [b]Script Generated UI[/b] → [b]Meal Buffet[/b].
[*]Pick a base meal from the list.
[*]Pick the extra meal skills, or reroll them, until you have the set you want.
[*]Press [b]Apply[/b]. The meal buff lands immediately.
[/list]

Default Steam path:
[code]...\steamapps\common\MonsterHunterWilds\[/code]

[line]

[size=5][b]Where it works[/b][/size]

[list]
[*]In the hub and at camp, without a canteen visit.
[*]During a quest.
[*]No voucher and no ingredients are consumed in any of these cases.
[/list]

[line]

[size=5][b]Status and limits[/b][/size]

[list]
[*][b]In development.[/b] The meal data and the apply path are being verified on the current game build before the panel ships; treat it as a convenience tool, not a balance mod.
[*][b]Your hunter only.[/b] It only ever writes to your own local hunter's meal state. Other players in your lobby or link party are never selected or modified.
[*][b]Single-player and co-op convenience.[/b] It does not change what other players see or do, and it does not edit your save file.
[*][b]Master data dependent.[/b] If a game patch renames an internal meal field, the mod logs a per-field miss instead of erroring. A patch may still need a mod update for full function.
[*]Reload any time: REFramework menu → Script → [b]Reset scripts[/b], or restart the game.
[/list]

[line]

[size=5][b]Safety[/b][/size]

[list]
[*]A small pointer-only hook runs on the quest state so the mod can label or gate in-quest use; there is no per-frame work beyond apply verification.
[*]Never writes save data, never modifies game files, nothing talks to the network.
[*]Every SDK call is guarded. As with any mod that writes live game state, a game-side access violation is still possible; use at your own risk.
[/list]

[line]

[size=5][b]Requirements[/b][/size]

[list]
[*]Monster Hunter Wilds
[*][url=https://www.nexusmods.com/monsterhunterwilds]REFramework for MH Wilds[/url] (install [b]dinput8.dll[/b] first)
[/list]

[line]

[size=5][b]Credits[/b][/size]

[list]
[*][url=https://github.com/praydog/REFramework]REFramework[/url] by praydog
[*]Mod structure follows [url=https://github.com/thieleju/HUNT_DUMPER]Hunt Dumper[/url] (MIT) by thieleju
[/list]

Source and issues: [url=https://github.com/Diegoeyza/meal-buffet]github.com/Diegoeyza/meal-buffet[/url]
```
