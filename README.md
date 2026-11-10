# Meal Buffet

> **Status: v0.1.1.** Apply verified in game in the hub, at camp and during a
> quest: the meal builder uses the game's own `app.cMealEffect`, and the
> applied meal lists the same food skills as a real canteen meal.

**A REFramework mod for Monster Hunter Wilds.** Applies any canteen meal to your
own hunter on demand, from the REFramework menu — no walk to the canteen, no
Meal Voucher, no ingredients spent.

Pick a meal set, choose or reroll the two extra buffs, press **Apply**. Works in
the hub, at camp, and during a quest.

## Replaces Meal Stripper

Meal Buffet includes the same one-click meal strip: the **Clear meal** button.
It also removes the need to strip before eating again — applying a new meal
replaces the active one directly. Remove Meal Stripper if it is installed.

## What it does

- **Every meal set**: the list is enumerated from the game's own meal master
  data (Kunafa, Azuz, Slid, Suja and the special/event sets), so nothing is
  hardcoded and meals added by a title update show up on their own.
- **Fixed skills, by name**: each set's three regular food skills are listed.
- **Two extra buffs, under your control**: each slot can use the game's own
  weighted roll, be set to nothing, or be a specific buff from that meal's pool.
- **Skill descriptions**: every active or picked skill is shown with a short
  line describing what it does (toggleable).
- **Clear meal**: removes the active meal (max HP/stamina, attack/defence, food
  skills, timer and flags) — the Meal Stripper behaviour.
- **No cost**: no Meal Voucher, no ingredients, no canteen visit.
- **Remembers the selection**: saved to `reframework/data/meal_buffet.json`.

## How it works

The active meal is `app.cHunterMealEffect` on the local hunter; the meal
definition itself is an `app.cMealEffect` attached to it.

Per apply, the mod:

1. reads the chosen canteen set from
   `app.user_data.MealDataLobby` (via `app.MealUtil.getMealDataLobby`),
2. creates a fresh `app.cMealEffect` and fills it with
   `copyFrom(app.user_data.MealDataLobby.cData, false)`,
3. adds the extra buffs with `addRandomTableParam(tableId)` (the game's own
   weighted roll) or `addRandomData(record)` (an exact pick),
4. hands it to the hunter with `cHunterMealEffect:setMealEffect(effect, false)`,
5. writes the end state a real canteen eat leaves behind:
   `_DurationTimer = _TimerMax = minutes * 60`, both active flags true.

Meal sets, fixed skills and the buff pool are read from game master data at
runtime. Only the user-controlled hunter is ever targeted. No save data is
written, no game files are modified, nothing talks to the network, and every SDK
call is `pcall`-guarded.

## Requirements

- Monster Hunter Wilds
- [REFramework for MH Wilds](https://www.nexusmods.com/monsterhunterwilds) (install `dinput8.dll` first)

## Install

1. Install REFramework if you have not already.
2. Copy `reframework/meal_buffet.lua` to
   `<game>\reframework\autorun\meal_buffet.lua`
   (Steam: `...\steamapps\common\MonsterHunterWilds\reframework\autorun\`)
3. Launch the game → REFramework menu (Insert) → **Script Generated UI** →
   **Meal Buffet** confirms it loaded.

`./package.sh` builds two shapes into `dist/`: a flat bundle
(`meal-buffet-<version>.zip`) and a `MealBuffet-<version>.zip` laid out for the
game folder (Nexus/Vortex).

## Usage

1. REFramework menu (Insert) → **Script Generated UI** → **Meal Buffet**.
2. `< Prev` / `Next >` pick a meal set. Base stats and fixed skills are listed.
3. For each extra buff slot, `<` / `>` cycles `game roll` → `none` → each
   specific buff; picked buffs show their description.
4. Press **Apply meal**. The `active skills` list shows what landed.
5. Press **Clear meal** to remove the active meal.

Reload the script any time: REFramework menu → Script → **Reset scripts**.

## Status and limits

v0.1.1. Apply and Clear are verified in the hub, at camp and during a quest;
the food-skill list matches a real meal.
Meal sets come from master data, so a game patch that renames an internal field
or method makes the panel report the failing call instead of throwing — a patch
may still need a mod update. Treat it as a single-player / co-op convenience
tool rather than a balance mod.

See [CHANGELOG.md](CHANGELOG.md).

## Development

- The apply path was established with two development probes (type surface and
  meal master data, then the game's apply API). They are not shipped and were
  removed from the working tree after verification; earlier commits in the git
  history contain them if a future game patch needs the investigation repeated.
- `./package.sh` builds both release zips into `dist/`. It reads the version
  from a `local VERSION = "..."` line in `reframework/meal_buffet.lua`.
- If a game patch renames an internal field or method, the mod reports the
  failing call in its status line instead of throwing.
- Syntax gate: the script runs under LuaJIT (Lua 5.1). Check a change with a
  real Lua 5.1 compiler, not only a modern Lua parser — 5.4-only syntax, and
  even a nested `...`, passes most parsers and fails to load in game
  (`cannot use '...' outside a vararg function`).
- Packaging notes for the Nexus release live in `packaging/nexus/`
  (`NEXUS_PAGE.md`, `README.txt`, `MEAL_STRIPPER_RETIREMENT.md`).

## Credits & license

- [REFramework](https://github.com/praydog/REFramework) by praydog
- Mod structure follows [Hunt Dumper](https://github.com/thieleju/HUNT_DUMPER) (MIT) by thieleju
- No GPL or unlicensed code was copied into this repository
- Licensed under Apache-2.0 (see `LICENSE`)
