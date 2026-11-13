# Nexus page — Meal Buffet v0.3.0

**Live:** https://www.nexusmods.com/monsterhunterwilds/mods/5321

Upload `dist/MealBuffet-0.3.0.zip` as the main file (Vortex-ready layout).

The Nexus description field uses **BBCode** (not Markdown). Paste the blocks
below straight into the matching fields (BBCode/source view).

**Supersedes Meal Stripper.** This mod includes the same one-click meal strip
(`Clear meal`) and adds the whole meal picker and the consumables panel, so Meal
Stripper should be retired. The retirement note for the old page is in
`packaging/nexus/MEAL_STRIPPER_RETIREMENT.md`.

---

**Title:**

```
Meal Buffet — Any Meal or Consumable Buff, Anywhere (REFramework)
```

**Short description:**

```
Apply any canteen meal, and any consumable buff (drugs, seeds, pills, powders, drinks), to your hunter from the REFramework menu. Pick meals, tick buffs, save presets, auto-apply at quest start. No voucher, no items, no canteen trip.
```

**Full description (BBCode — paste as-is):**

```
[size=6][b]Meal Buffet[/b][/size]

Applies any canteen meal, and any consumable buff, to your hunter [b]on demand[/b], straight from the REFramework menu — no walk to the canteen, no Meal Voucher, no ingredients, no items used.

Two panels:

[list]
[*][b]Meals[/b] — pick a meal set, choose or reroll the two extra buffs, press Apply.
[*][b]Consumables[/b] — tick drugs, seeds, pills, powders and drinks, then apply them all at once or one at a time.
[/list]

[line]

[size=5][b]Replaces Meal Stripper[/b][/size]

Meal Buffet includes the same one-click meal strip that Meal Stripper provided — it is the [b]Clear meal[/b] button. If you have Meal Stripper installed, remove it: this mod does the same and more. [i]Unlike[/i] Meal Stripper, you do not need to strip and re-eat: applying a new meal replaces the active one directly.

[line]

[size=5][b]Meals[/b][/size]

[list]
[*][b]Every meal set[/b] — the full list is read from the game's own master data at runtime (Kunafa, Azuz, Slid, Suja and the special/event sets). Nothing is hardcoded, so meals added by a title update appear without a mod update.
[*][b]Fixed skills, shown by name[/b] — each set's three regular food skills are listed.
[*][b]Two extra buffs under your control[/b] — each slot can be left to the game's own weighted roll, set to nothing, or set to a specific buff from that meal's pool. Every active or picked skill is shown with a short description.
[*][b]Apply[/b] — builds the meal with the game's own meal object and hands it to your hunter; the result lists the same food skills as a real canteen meal.
[*][b]Clear meal[/b] — one click removes the active meal buff (max HP, max stamina, attack/defence bonuses and the food skills drop off). This is the Meal Stripper behaviour.
[*][b]Auto refresh outside quest[/b] — while you are in the hub or at a camp, the meal you last applied is reapplied when it expires or has under a minute left. It pauses after [b]Clear meal[/b] until you apply again.
[*][b]Nothing is spent[/b] — no Meal Voucher, no ingredients, no canteen visit.
[/list]

[line]

[size=5][b]Consumables[/b][/size]

[list]
[*][b]14 buff items[/b] — Demondrug, Mega Demondrug, Armorskin, Mega Armorskin, Might Seed, Adamant Seed, Might Pill, Adamant Pill, Demon Powder, Hardshell Powder, Dash Juice, Immunizer, Hot Drink, Cool Drink.
[*][b]Nothing is consumed[/b] — the buff is applied through the game's own item-buff system. No item is used and nothing has to be in your pouch.
[*][b]Per row or batch[/b] — press [b]Apply[/b] on one buff, tick several and press [b]Apply selected[/b], or clear everything with one button.
[*][b]Presets[/b] — a built-in [b]Standard[/b] set plus four unnamed slots: tick the buffs you want and press [b]Save selection[/b]. Your sets are stored and applied later as-is.
[*][b]Item Prolonger[/b] (Enduring Jewel) — the multiplier is read from your hunter, shown in the panel, and can be toggled off or overridden to Lv1–3.
[*][b]Slot rules[/b] — a drug and its mega version share a slot, and a seed and its pill share a slot: applying one replaces the other.
[*][b]Auto preset on quest start[/b] — applies the selected preset once when a quest begins, never during the hunt.
[*][b]Auto Hot/Cool Drink on quest start[/b] — one drink per quest based on the locale: Oilwell Basin gets a Cool Drink, Iceshard Cliffs (and the Omega Planetes arena) get a Hot Drink.
[/list]

[line]

[size=5][b]How to use[/b][/size]

[list=1]
[*]Install REFramework, then extract this archive into your game folder (Vortex: install normally). You should end up with:
[code]<game>\reframework\autorun\meal_buffet.lua[/code]
[*]In game, press [b]Insert[/b] to open REFramework → [b]Script Generated UI[/b] → [b]Meal Buffet[/b].
[*]Choose [b]Meals[/b] or [b]Consumables[/b] at the top of the panel.
[*]Meals: [b]< Prev[/b] / [b]Next >[/b] pick a set, [b]<[/b] / [b]>[/b] set each extra buff, then [b]Apply meal[/b].
[*]Consumables: tick buffs and press [b]Apply selected[/b], or press [b]Apply[/b] on a row. [b]Standard[/b] applies the built-in set; [b]Save selection[/b] stores your ticks in one of the four slots.
[*]Both auto toggles are one-shot per quest and the panel shows the detected locale next to them.
[/list]

Default Steam path:
[code]...\steamapps\common\MonsterHunterWilds\[/code]

[line]

[size=5][b]Where it works[/b][/size]

[list]
[*]In the hub and at camp, without a canteen visit.
[*]During a quest, including at the camp canteen.
[*]Nothing is spent: no voucher, no ingredients, no items.
[*]Applying a meal or buff replaces the active one, so you can swap sets freely.
[/list]

[line]

[size=5][b]Status and limits[/b][/size]

[list]
[*][b]Your hunter only.[/b] It only ever writes to your own local hunter. Other players in your lobby or link party are never selected or modified.
[*][b]No save editing.[/b] It does not write save data and does not modify game files. Meals and buffs are runtime state, like eating in game.
[*][b]Single-player and co-op convenience.[/b] It does not change what other players see or do, and nothing is sent over the network.
[*][b]Game-data dependent.[/b] Meals, buffs and durations are read from the game at runtime. If a patch renames an internal field or method, the panel reports the failing call instead of throwing; a patch may still need a mod update.
[*]Reload any time: REFramework menu → Script → [b]Reset scripts[/b], or restart the game.
[/list]

[line]

[size=5][b]Safety[/b][/size]

[list]
[*][b]No hooks.[/b] The auto toggles poll the quest state a few times a second while enabled; nothing runs every frame otherwise.
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

[b]0.3.0[/b]
[list]
[*]Meals: auto refresh outside quest — reapplies the last meal when it expires or has under a minute left (hub and camp).
[/list]

[b]0.2.0[/b]
[list]
[*]Consumables panel: drugs, seeds, pills, powders and drinks, with per-row and batch apply/clear. No item is consumed.
[*]Presets: Standard set plus four user slots.
[*]Item Prolonger toggle and level override.
[*]Auto preset on quest start, and auto Hot/Cool Drink on quest start based on the quest locale.
[*]Meals and Consumables panels; settings persist.
[/list]

[b]0.1.1[/b]
[list]
[*]Meal skill descriptions.
[/list]

[b]0.1.0[/b]
[list]
[*]First release: meal picker, random extra buffs, Apply meal, Clear meal.
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
0.3.0
- Meals: auto refresh outside quest (hub and camp), reapplying the last meal when it expires or has under a minute left.

0.2.0
- Consumables panel: drugs, seeds, pills, powders and drinks; per-row and batch apply/clear; no item consumed.
- Presets: Standard set plus four user slots.
- Item Prolonger toggle and level override.
- Auto preset on quest start, and auto Hot/Cool Drink on quest start based on the quest locale.
- Meals and Consumables panels; settings persist.

0.1.1
- Meal skill descriptions.

0.1.0
- First release: meal picker, random extra buffs, Apply meal, Clear meal.
```

**File to upload:** `dist/MealBuffet-0.3.0.zip`

**Suggested Nexus metadata:**
- Category: Gameplay
- Version: 0.3.0
- Requirements: REFramework for MH Wilds
