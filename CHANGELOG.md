# Changelog

## 0.3.0 — 2026-11-13
- **Auto refresh outside quest** (Meals panel): while in the hub or at a camp,
  re-applies the meal you last applied when it expires or has under a minute
  left. Chosen by polling `app.MissionManager.get_IsPlayingQuest()`; paused
  after *Clear meal* until you apply again.
- Remembers the last applied meal by menu enum, so refreshing keeps the meal you
  actually ate rather than the one currently previewed in the picker.

## 0.2.0 — 2026-11-11
- **Consumables panel**: apply any buff item from the REFramework menu — drugs,
  seeds, pills, powders and drinks. Uses the game's own
  `activateItemBuff(type, effectRate, timeScale)`; no item is consumed and
  nothing has to be in the pouch.
- Per-buff Apply/Clear, `Apply selected`, and `Clear all`.
- **Presets**: built-in Standard set plus four unnamed slots (`Save selection`).
- **Item Prolonger (Enduring Jewel)**: multiplier read from the hunter
  (`getSkillItemUsePowerUpTimeRate`), on/off toggle and Lv0–3 override.
- **Auto preset on quest start**: one-shot application of a chosen preset,
  detected by polling `app.MissionManager.get_IsPlayingQuest()` (no hooks).
- **Auto Hot/Cool Drink on quest start**: one drink per quest based on the
  locale — ST103 Oilwell Basin → Cool Drink, ST104 Iceshard Cliffs → Hot Drink,
  ST402 Omega Planetes → Hot Drink.
- Panel split into **Meals** and **Consumables** sections; both states persist
  in `reframework/data/meal_buffet.json`.
- Slot rules: drug ↔ mega drug and seed ↔ pill replace each other.

## 0.1.1 — 2026-11-10
- Show a short description for every active or picked meal skill.
- `Descriptions: on/off` toggle to keep the panel compact (saved in the config).
- Verified in the hub, at camp and during a quest.

## 0.1.0 — 2026-11-10
- First release.
- Meal set picker read from the game's master data (Kunafa, Azuz, Slid, Suja and
  the special/event sets), with base stats and fixed-skill names.
- Two extra-buff slots per meal: the game's own weighted roll, none, or a
  specific buff from that meal's pool.
- Apply meal (builds the meal with the game's own object and hands it to the
  hunter; timer and flags mirror a real canteen eat).
- Clear meal: the Meal Stripper strip (max HP/stamina, attack/defence, food
  skills, timer and flags).
- Selection saved to `reframework/data/meal_buffet.json`.
- No hooks, no per-frame work; no voucher or ingredients consumed.
