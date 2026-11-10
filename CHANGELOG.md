# Changelog

## 0.1.1 — 2026-11-10
- Show a short description for every active or picked meal skill.
- Verified in the hub, at camp and during a quest.
- `Descriptions: on/off` toggle to keep the panel compact (saved in the config).

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
