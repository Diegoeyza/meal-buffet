# Meal Buffet

> **Status: v0.1.1.** The apply path is verified on the current build: the mod
> builds the meal with the game's own `app.cMealEffect` and hands it to the
> hunter. Verified in game that the applied meal lists the same food skills as
> a real canteen meal. Mid-quest use still needs an explicit test.

**A REFramework mod for Monster Hunter Wilds.** Applies any canteen meal buff
to your own hunter on demand, from the REFramework menu — no walk to the
canteen, no Meal Voucher, no ingredients spent.

Pick one of the game's base meals, pick or reroll the extra meal skills, press
**Apply**. Works in the hub, at camp, and mid-quest.

## What it does

- **Any base meal**: the list is enumerated from the game's own meal master
  data at runtime, so nothing is hardcoded and meals added by a title update
  show up on their own.
- **Extra skills on demand**: pick the random meal skills yourself, or reroll
  them until you get the set you want.
- **Apply anywhere**: hub, camp, or an active quest. No canteen visit.
- **No cost**: no Meal Voucher, no ingredients.

## How it works

Working hypothesis, being verified by the probe: the active meal — buff, timer,
and extra food skills — is a small state block on your local hunter,
`app.cHunterMealEffect`.

- Base meals and their skill pools are read from the game's meal master data at
  runtime, not from a table in the script.
- **Apply** will first try the game's own meal apply path, so the result is the
  same state the canteen would produce. If that path is unavailable in the
  current context, the mod falls back to writing the meal state fields on
  `app.cHunterMealEffect` directly.
- Development is probe-first: `reframework/meal_apply_probe.lua` (not packaged)
  dumps the meal types and the master-data entries, captures the game's own eat
  calls, and verifies that re-written meal fields survive the next frames.
- Only your own (user-controlled) hunter is ever selected for writes; other
  players are never touched. The master-player fallback is refused for writes.
  No save data is written, no game files are modified, nothing talks to the
  network.
- Every SDK call is `pcall`-guarded.

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

## Usage (planned)

1. REFramework menu (Insert) → **Script Generated UI** → **Meal Buffet**.
2. Pick a base meal.
3. Pick the extra meal skills, or reroll them.
4. Press **Apply**. The meal buff lands on your hunter immediately.

Reload the script any time: REFramework menu → Script → **Reset scripts**.

## Status

v0.1.1. Apply works, the food-skill list matches a real meal, and the panel shows a short description of every active or picked meal skill. Verified in the
hub; mid-quest still needs a test. Treat it as a single-player / co-op
convenience tool rather than a balance mod.

## Development

- The apply path was established with two development probes (type surface and
  meal master data, then the game's apply API). They are not shipped and were
  removed from the working tree after verification; earlier commits in the git
  history contain them if a future game patch needs the investigation repeated.
- The mod builds a fresh `app.cMealEffect` per apply:
  `copyFrom(app.user_data.MealDataLobby.cData, false)`, extras through
  `addRandomTableParam(tableId)` or `addRandomData(record)`, then
  `cHunterMealEffect:setMealEffect`, followed by the timer and flags a real
  canteen eat leaves behind (`_DurationTimer = _TimerMax = minutes * 60`).
- Meal sets, fixed skills and the random-buff pool are read from the game's
  master data at runtime, so canteen changes (new or event meals) appear
  without a mod update.
- `./package.sh` builds both release zips into `dist/`. It reads the version
  from a `local VERSION = "..."` line in `reframework/meal_buffet.lua`.
- Only the user-controlled hunter is ever targeted for writes; the
  master-player fallback is refused.
- If a game patch renames an internal field or method, the mod reports the
  failing call in its status line instead of throwing.
- Syntax gate: the script runs under LuaJIT (Lua 5.1). Check a change with a
  real Lua 5.1 compiler, not only a modern Lua parser — 5.4-only syntax, and
  even a nested `...`, passes most parsers and fails to load in game
  (`cannot use '...' outside a vararg function`).

## Credits & license

- [REFramework](https://github.com/praydog/REFramework) by praydog
- Mod structure follows [Hunt Dumper](https://github.com/thieleju/HUNT_DUMPER) (MIT) by thieleju
- No GPL or unlicensed code was copied into this repository
- Licensed under Apache-2.0 (see `LICENSE`)
