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
- **Trick camera** (`bmx_cam_air`, 0..1, default 0.6): done, `cl_view.lua`.
  In the air the chase camera pulls back (up to +40% distance) and widens
  (+14 degrees FOV); a 0.12 s hang time means a bump is not an air; the
  blend is a rate-limited smoothstep, so nothing jumps at takeoff or landing
  (tested frame by frame at 20, 60 and 144 fps). Unverified in a live client.
- **Filmer camera:** done. `lua/entities/bmx_filmer_cam` (Q menu > BMX,
  admin-only) turns to follow the nearest rider; `bmx_filmer_view` looks
  through the nearest one (`cl_filmer.lua`). The aim, zoom and operator lag
  are tested; how the tripod model looks is not. G28's fixed replay camera
  uses the same maths.
- **Rider pose options** (`bmx_rider_pose`: seated, standing, attack): done.
  `sh_stance.lua` is a table of IK-target offsets plus a torso lean; the
  server copies the userinfo convar onto the player as an NWInt
  (`sv_stance.lua`) so others see it; `cl_rider.lua` has two small additive
  calls (`BMX.StanceTargets`, `BMX.StanceLean`). The offsets are numbers
  nobody has watched on a real model.
- **Speedometer line:** done. `combo xN   air 1.23s` under the speed box;
  airtime is held 2.5 s after landing and never shown for a bump.
- Skateboard parity: nothing to do yet (G23). Every option reads
  `BMX.LocalBike`, so it applies to whatever vehicle that returns.
