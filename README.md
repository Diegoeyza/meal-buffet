# Meal Buffet

> **Status: v0.1 in development.** The release script (`reframework/meal_buffet.lua`)
> is not built yet: the apply path is being verified on the current game build
> with the discovery probe in `reframework/meal_apply_probe.lua`.

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

Not installable yet: the release script does not exist. The only file that
loads today is the development probe (see **Development** below).

Once the release ships, install will be:

1. Install REFramework if you have not already.
2. Copy `reframework/meal_buffet.lua` to
   `<game>\reframework\autorun\meal_buffet.lua`
   (Steam: `...\steamapps\common\MonsterHunterWilds\reframework\autorun\`)
3. Launch the game → REFramework menu (Insert) → **Script Generated UI** →
   **Meal Buffet** confirms it loaded.

`./package.sh` will then build two shapes into `dist/`: a flat bundle
(`meal-buffet-<version>.zip`) and a `MealBuffet-<version>.zip` laid out for the
game folder (Nexus/Vortex).

## Usage (planned)

1. REFramework menu (Insert) → **Script Generated UI** → **Meal Buffet**.
2. Pick a base meal.
3. Pick the extra meal skills, or reroll them.
4. Press **Apply**. The meal buff lands on your hunter immediately.

Reload the script any time: REFramework menu → Script → **Reset scripts**.

## Status

In development. The meal state, the master data and the apply path are being
verified on the current build with the probe below; the panel and Apply are not
written yet. Treat it as a single-player / co-op convenience tool rather than a
balance mod.

## Development

- `reframework/meal_apply_probe.lua` is the discovery probe. Copy it to
  `<game>\reframework\autorun\`, then open REFramework → Script Generated UI →
  **Meal Buffet Probe**. It is kept in the repo and is **not** included in
  release bundles.
- Probe outputs land in `reframework/data/`:
  `meal_apply_probe_types.json` (type surface),
  `meal_apply_probe_master.json` (meal master data, base meals and the random
  skill pool),
  `meal_apply_probe_states.json` (appended meal snapshots, tagged by hand),
  `meal_apply_probe_capture.json` (hooked meal/dining calls with args, return
  values and an epoch marker),
  `meal_apply_probe_apply.json` (clone/strip/apply-clone experiment with
  read-back values and +15/+120-frame verification).
- Probe flow, one session: Dump types + Dump master data; Arm hooks; snapshot
  a normal eat (tag `before` / `after_normal`) and a voucher eat (tag `before` /
  `after_voucher`), dumping the capture after each; then Clone → Strip → Apply
  clone, and repeat during a quest for the mid-quest case.
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
