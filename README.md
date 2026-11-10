# Meal Buffet

> **Status: v0.1.0.** The apply path is verified on the current build: the mod
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

v0.1.0. Apply works and the food-skill list matches a real meal. Verified in the
hub; mid-quest still needs a test. Treat it as a single-player / co-op
convenience tool rather than a balance mod.

## Development

- `reframework/meal_apply_probe.lua` is the phase-1 probe (type surface,
  master data, meal watcher, clone/strip/apply-clone). `reframework/meal_apply_probe2.lua`
  is the phase-2 probe (meal master-data tables, canteen menu enumeration, and
  the two candidate apply paths: `FacilityDining:setMealEffectLobby` and
  "build a `cMealEffect`, then `setMealEffect`"). Copy either to
  `<game>\reframework\autorun\`, then open REFramework → Script Generated UI →
  **Meal Buffet Probe** / **Meal Apply Probe 2**. Neither is included in
  release bundles.
- Probe outputs land in `reframework/data/`:
  `meal_apply_probe_types.json` (type surface),
  `meal_apply_probe_master.json` (meal master data, base meals and the random
  skill pool),
  `meal_apply_probe_states.json` (appended meal snapshots, tagged by hand),
  `meal_apply_probe_watch.json` (read-only change timeline: every field move
  with before/after values, food-skill count and derived stats, plus the run
  epoch),
  `meal_apply_probe_apply.json` (clone/strip/apply-clone experiment with
  read-back values and +15/+120-frame verification).
- Phase 2 outputs: `meal_apply_probe2_types.json` (apply-path signatures),
  `meal_apply_probe2_master.json` (base meals with `MealSkill[]` and
  `_RandomTable[]`, the random table with weights, canteen and field-camp
  menus), `meal_apply_probe2_apply.json` (each apply attempt with before/after
  state and +15/+120-frame verification).
- Probe flow, one session: Dump types + Dump master data; turn Watch on;
  snapshot before the eat (tag `before`), eat at the canteen (a voucher is
  fine), snapshot again (tag `after_eat`), then dump the watch; then
  Clone → Strip → Apply clone, and repeat during a quest for the mid-quest
  case.
- The probe deliberately registers **no hooks**. An earlier version hooked the
  dining classes and crashed the game when an eat fired a hook whose arguments
  could not be dereferenced safely; a native access violation cannot be caught
  from Lua. The watcher polls the one meal object it resolves instead.
- `./package.sh` builds both release zips into `dist/` once
  `reframework/meal_buffet.lua` exists. It reads the version from a
  `local VERSION = "..."` line in that file, so the release script must declare
  one.
- Write paths only ever act on the user-controlled hunter; the master-player
  fallback is refused for writes.
- If a game patch renames an internal field, the probe records a per-field miss
  instead of erroring — a patch may still need a mod update for full function.
- Syntax gate: the scripts run under LuaJIT (Lua 5.1). Check a change with a
  real Lua 5.1 compiler, not only a modern Lua parser — 5.4-only syntax, and
  even a nested `...`, passes most parsers and fails to load in game
  (`cannot use '...' outside a vararg function`).

## Credits & license

- [REFramework](https://github.com/praydog/REFramework) by praydog
- Mod structure follows [Hunt Dumper](https://github.com/thieleju/HUNT_DUMPER) (MIT) by thieleju
- No GPL or unlicensed code was copied into this repository
- Licensed under Apache-2.0 (see `LICENSE`)
