# G21 -- Camera and HUD options

**Competitor:** first or third person (`bicycle_cam_third_person`), camera
distance, height and roll, a speedometer in km/h, mph or off, and how the
character sits on the bike.

**Us today:** at parity or ahead. `bmx_cam_first`, `bmx_cam_dist`,
`bmx_cam_height`, `bmx_cam_roll`, `bmx_cam_smooth` (eased chase cam, 1.1.0),
`bmx_units`, `bmx_hud`, and a **cinematic camera** (`bmx_cinematic`, L) they
don't have. What's missing is that nobody can find any of it without the
console, and there are a few camera modes a trick game wants.

## Goal

Keep the lead, and make it visible.

## Done when

- Everything is in G19's **Rider** panel.
- **Trick camera:** in the air, the chase cam pulls back and widens FOV
  slightly (`bmx_cam_air`), then eases back on landing. It's what makes Skate
  and THPS airs read.
- **Fixed "filmer" camera:** a spawnable camera entity that tracks the
  nearest rider. It's for servers to put at a park's best ramp, and it feeds
  G28.
- **Rider pose options** (theirs has a sitting pose): seated, standing,
  "attack position", chosen per rider. It changes only the IK targets.
- **Speedometer** also shows the combo multiplier and airtime. The combo
  HUD already exists, so this is one more line.
- Every camera option works the same on the skateboard (G23).

## Tests

- Offline: camera math for air pull-back is continuous, with no jump at
  takeoff or landing.

## Risks

None.

## Status (2026-10-07)

- **Everything is in G19's Rider panel:** done. Every `bmx_cam_*`, `bmx_units`,
  `bmx_hud`, `bmx_stick_deadzone` and `bmx_cinematic`, with help text and reset
  (see `lua/bmx/sh_settings.lua`; the panel is unverified in a live client).
- Trick camera (`bmx_cam_air`): not done (later wave).
- Filmer camera entity: not done (later wave).
- Rider pose options: not done (later wave).
- Speedometer combo and airtime line: not done.
- Skateboard parity: not applicable yet (G23).
