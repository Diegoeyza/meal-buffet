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

The active meal — buff, timer, and extra food skills — is a small state block
on your local hunter, `app.cHunterMealEffect`.

- Base meals and their skill pools are read from the game's meal master data at
  runtime, not from a table in the script.
- **Apply** first tries the game's own meal apply path, so the result is the
  same state the canteen would produce. If that path is unavailable in the
  current context, the mod falls back to writing the meal state fields on
  `app.cHunterMealEffect` directly.
- Development was probe-first: a dev probe (`reframework/meal_apply_probe.lua`,
  not packaged) dumps the meal types, lists the master-data entries, and
  verifies that an applied meal survives the next frames.
- Only your own (user-controlled) hunter is ever selected; other players are
  never touched. No save data is written, no game files are modified, nothing
  talks to the network.
- Everything is `pcall`-guarded: the script never throws into the game.

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

Release zips (`./package.sh` → `dist/`) come in two shapes: a flat bundle
(`meal-buffet-<version>.zip`) and a `MealBuffet-<version>.zip` laid out for the
game folder (Nexus/Vortex).

## Usage

1. REFramework menu (Insert) → **Script Generated UI** → **Meal Buffet**.
2. Pick a base meal.
3. Pick the extra meal skills, or reroll them.
4. Press **Apply**. The meal buff lands on your hunter immediately.

Reload the script any time: REFramework menu → Script → **Reset scripts**.

## Status

In development. The menu, the meal list and Apply work; treat it as a
single-player / co-op convenience tool rather than a balance mod.

## Development

- `reframework/meal_apply_probe.lua` is the development probe. It is kept in
  the repo and is **not** included in release bundles.
- `./package.sh` builds both release zips into `dist/`.
- The field set was established on the 2026-11 build via the probe. If a game
  patch renames an internal meal field, the mod logs a per-field miss instead
  of erroring — a patch may still need a mod update for full function.

## Credits & license

- [REFramework](https://github.com/praydog/REFramework) by praydog
- Mod structure follows [Hunt Dumper](https://github.com/thieleju/HUNT_DUMPER) (MIT) by thieleju
- No GPL or unlicensed code was copied into this repository
- Licensed under Apache-2.0 (see `LICENSE`)
