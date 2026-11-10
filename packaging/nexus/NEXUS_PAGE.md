# Nexus page — Meal Buffet v0.1.1

Upload `dist/MealBuffet-0.1.1.zip` as the main file (Vortex-ready layout).

The Nexus description field uses **BBCode** (not Markdown). Paste the blocks
below straight into the matching fields (BBCode/source view).

**Supersedes Meal Stripper.** This mod includes the same one-click meal strip
(`Clear meal`) and adds the whole meal picker on top, so Meal Stripper should be
retired. The retirement note for the old page is in
`packaging/nexus/MEAL_STRIPPER_RETIREMENT.md`.

---

**Title:**

```
Meal Buffet — Any Meal, Anywhere, No Voucher (REFramework)
```

**Short description:**

```
Apply any canteen meal to your hunter from the REFramework menu: pick the meal, pick or reroll the two extra buffs, press Apply. No canteen trip, no voucher, no ingredients. Includes a one-click meal reset, replacing Meal Stripper.
```

**Full description (BBCode — paste as-is):**

```
[size=6][b]Meal Buffet[/b][/size]

Applies any canteen meal to your hunter [b]on demand[/b], straight from the REFramework menu — no walk to the canteen, no Meal Voucher, no ingredients used.

Pick one of the game's meal sets, choose or reroll the two extra buffs, press [b]Apply[/b]. The panel lists every food skill you will get, with a short description of what it does.

[line]

[size=5][b]Replaces Meal Stripper[/b][/size]

Meal Buffet includes the same one-click meal strip that Meal Stripper provided — it is the [b]Clear meal[/b] button. If you have Meal Stripper installed, remove it: this mod does the same and more. [i]Unlike[/i] Meal Stripper, you do not need to strip and re-eat: applying a new meal replaces the active one directly.

[line]

[size=5][b]What it does[/b][/size]

[list]
[*][b]Every meal set[/b] — the full list is read from the game's own master data at runtime (Kunafa, Azuz, Slid, Suja and the special/event sets). Nothing is hardcoded, so meals added by a title update appear without a mod update.
[*][b]Fixed skills, shown by name[/b] — each set's three regular food skills are listed.
[*][b]Two extra buffs under your control[/b] — each slot can be left to the game's own weighted roll, set to nothing, or set to a specific buff from that meal's pool. Every active or picked skill is shown with a short description.
[*][b]Apply[/b] — builds the meal with the game's own meal object and hands it to your hunter; the result lists the same food skills as a real canteen meal.
[*][b]Clear meal[/b] — one click removes the active meal buff (max HP, max stamina, attack/defence bonuses and the food skills drop off). This is the Meal Stripper behaviour.
[*][b]Nothing is spent[/b] — no Meal Voucher, no ingredients, no canteen visit.
[*][b]Remembers your selection[/b] — the chosen meal and buffs are saved and come back next session.
[/list]

[line]

[size=5][b]How to use[/b][/size]

[list=1]
[*]Install REFramework, then extract this archive into your game folder (Vortex: install normally). You should end up with:
[code]<game>\reframework\autorun\meal_buffet.lua[/code]
[*]In game, press [b]Insert[/b] to open REFramework → [b]Script Generated UI[/b] → [b]Meal Buffet[/b].
[*]Use [b]< Prev[/b] / [b]Next >[/b] to pick a meal set. Its fixed skills are listed below the base stats.
[*]For each extra buff slot, use [b]<[/b] / [b]>[/b] to cycle: [i]game roll[/i] → [i]none[/i] → each specific buff. Picked buffs show their description.
[*]Press [b]Apply meal[/b]. The meal lands immediately; the [b]active skills[/b] list at the top shows exactly what is on your hunter.
[*]Press [b]Clear meal[/b] to remove it (replaces Meal Stripper's strip button).
[/list]

Default Steam path:
[code]...\steamapps\common\MonsterHunterWilds\[/code]

[line]

[size=5][b]Where it works[/b][/size]

[list]
[*]In the hub and at camp, without a canteen visit.
[*]During a quest, including at the camp canteen.
[*]No voucher and no ingredients are consumed in any case.
[*]Applying a meal replaces whatever meal is already active, so you can swap sets freely.
[/list]

[line]

[size=5][b]Status and limits[/b][/size]

[list]
[*][b]Your hunter only.[/b] It only ever writes to your own local hunter. Other players in your lobby or link party are never selected or modified.
[*][b]No save editing.[/b] It does not write save data and does not modify game files. The applied meal is not saved into your character; it is a runtime state, like a canteen meal.
[*][b]Single-player and co-op convenience.[/b] It does not change what other players see or do, and nothing is sent over the network.
[*][b]Master-data dependent.[/b] Meal sets and buffs are read from the game's tables at runtime. If a patch renames an internal field or method, the panel reports the failing call instead of throwing; a patch may still need a mod update.
[*]Reload any time: REFramework menu → Script → [b]Reset scripts[/b], or restart the game.
[/list]

[line]

[size=5][b]Safety[/b][/size]

[list]
[*][b]No hooks. No per-frame work.[/b] The panel reads data only when it is open; writes happen only when you press Apply or Clear.
[*]Every SDK call is guarded. As with any mod that writes live game state, a game-side access violation is still possible; use at your own risk.
[*]Back up your save before using mods that change gameplay state, as always.
[/list]

[line]

[size=5][b]Requirements[/b][/size]

[list]
[*]Monster Hunter Wilds
[*][url=https://www.nexusmods.com/monsterhunterwilds]REFramework for MH Wilds[/url] (install [b]dinput8.dll[/b] first)
[/list]

[line]

[size=5][b]Changelog[/b][/size]

[b]0.1.1[/b]
[list]
[*]Meal skill descriptions: each active or picked buff now shows a short line describing what it does.
[*]Descriptions can be toggled off to keep the panel compact.
[/list]

[b]0.1.0[/b]
[list]
[*]First release: meal set picker, fixed-skill preview, two extra-buff slots (game roll / none / specific), Apply, Clear meal, saved selection.
[*]Clear meal supersedes Meal Stripper's strip button.
[/list]

[line]

[size=5][b]Credits[/b][/size]

[list]
[*][url=https://github.com/praydog/REFramework]REFramework[/url] by praydog
[*]Mod structure follows [url=https://github.com/thieleju/HUNT_DUMPER]Hunt Dumper[/url] (MIT) by thieleju
[/list]

Source and issues: [url=https://github.com/Diegoeyza/meal-buffet]github.com/Diegoeyza/meal-buffet[/url]
```

**Changelog field:**

```
0.1.1
- Show a short description for every active or picked meal skill.
- Descriptions toggle to keep the panel compact.

0.1.0
- First release: meal set picker, fixed-skill preview, two extra-buff slots (game roll / none / specific pick), Apply, Clear meal.
- Clear meal replaces Meal Stripper; applying a new meal replaces the active one directly.
```

**File to upload:** `dist/MealBuffet-0.1.1.zip`

**Suggested Nexus metadata:**
- Category: Gameplay
- Version: 0.1.1
- Requirements: REFramework for MH Wilds
