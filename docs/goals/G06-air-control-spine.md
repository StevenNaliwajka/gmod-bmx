# G06 -- Air control: turn around on a quarter pipe, spine transfers

**Competitor:** [#6](https://github.com/luttje/gmod-bicycle/issues/6) (closed,
shipped as "Advanced air control"). Off a quarter pipe, holding A/D turns you
round to ride back down. Releasing W and pressing it again above the top of a
quarter pipe pitches you over into the one behind (spine transfer). Keys held
at takeoff are ignored until pressed again. Admins can switch it off.

**Us today:** in the air A/D roll (barrel roll), RMB + A/D yaw (360), and
W/S pitch (`sv_air.lua`). The 1.1.0 fix ignores a key held at takeoff until
it's let go. That's the same rule they arrived at. There is **no
quarter-pipe awareness**: going straight up a vert wall, the rider has to do a
full RMB 180 by hand, and nothing helps with a spine.

## Goal

Riding a bowl or a vert ramp should flow. Go up, come round, come back down,
without needing a perfect 180 every time. The spine transfer should be a
scored trick.

## Done when

- **Quarter-pipe detect:** at takeoff, if the launch surface normal is over
  60° from up and the velocity is mostly up, the bike is "on vert".
- **Vert turn:** on vert, A/D (no RMB) turns the bike round about world up
  (a "180 / revert"), and the landing assist aims it back into the ramp. It's
  scored as "Air 180" and its points scale with the height.
- **Spine transfer:** above the coping with a back-to-back quarter pipe
  behind it (detected by a trace from the apex), a fresh W press carries the
  bike over the spine. It's scored as "Spine Transfer", and the combo stays
  alive.
- Barrel roll is still on A/D when **not** on vert, so nothing existing breaks.
- `bmx_air_assist 0|1` (server) switches it off.

## Approach

- In `sv_launch.lua` (which already decides what a takeoff was), classify the
  launch as `ramp`, `vert` or `flat` and put it on `st.launchKind`.
- In `sv_air.lua`, branch the A/D mapping on `launchKind`: `vert` → yaw
  about world up, with a PD that settles at 180° unless the input is still
  held.
- Spine: at the apex, trace backwards and down from the coping. If a surface
  with a mirrored normal is within 64 u, set `st.spineTarget` and, on W, blend
  the velocity direction towards it over 0.3 s.
- The ramp finder in `sv_bot.lua` already finds ramps, so it can find
  spines too, and the bot can show this off.

## Tests

- Headless `vert_turnaround`: up a gm_skatepark quarter pipe with D held,
  the bike lands facing down the ramp, rideable.
- Headless `spine_transfer`: on a spawned back-to-back pair (G27), it lands
  in the far ramp.
- Offline: launch classifier on synthetic normals.

## Risks

Over-assisting removes the skill. Keep the assist on landings only, never on
the turn itself, and score assisted landings at full points so no one is
punished for turning it on.

## Status (2026-10-07)

**Built, offline-tested; the park-piece cases are written and not yet run on a
real server.**

| Done when | State |
|---|---|
| Quarter-pipe detect | **Done.** `BMX.Launch.Classify(normal, vel, cfg)` (`sv_launch.lua`): `vert` when the surface left is over `Air.vertAngle` (60 deg) from level and `vz / speed >= Air.vertUp` (0.5); `ramp` from `Air.rampAngle` (10 deg); else `flat`. `sv_physics.lua` remembers the last grounded normal (`st.launchNormal`) and sets `st.launchKind` when air mode engages. |
| Vert turn | **Done.** `BMX.VertAir` (`sv_air.lua`): A/D (no RMB, not under a whip, bar or pose) turn about WORLD up at up to `Air.vertYawRate`; on release a PD settles on the nearest half turn (a tap under `Air.vertMin` settles back to nothing); held, it keeps turning. D is clockwise. The heading is `st.vertSpin`. Scored on landing as **Air 180**, `Air.vertBase + Air.vertPerUnit * height` per half turn. |
| Landing aim | **Done**, on vert only: descending with no key held and within `Air.vertAimMax` (100 deg) of the fall line (the landing surface's, else the face left), a PD turns the bike to face down the ramp. Never during the turn; a bike left facing the wall is the rider's to turn. |
| Spine transfer | **Done.** `BMX.Launch.FindSpine` near the apex (`|vz| < Air.spineApexVz`): the first ground within `Air.spineReach` (64 u) over the coping, below the bike, whose normal mirrors the launch face's (`Air.spineMirror`) becomes `st.spineTarget`. A fresh W press within `Air.spineWindow` blends the velocity down that face over `Air.spineBlend` (0.3 s, at least `Air.spineSpeed`); W also pitches the bike over. Scored as **Spine Transfer** (`Air.spinePoints`); it is an ordinary trick, so the combo stays open across it. |
| Barrel roll off vert | **Unchanged**: A/D roll everywhere that is not vert, and with RMB held they are still the 360. |
| `bmx_air_assist 0\|1` | **Done**: server row in `sh_settings.lua` (category "How the bike rides"), convar in `sv_rules.lua`, README, Workshop description, `bmx_report`. |
| Bot | **Partly.** `Air 180` and `Spine Transfer` are in `Bot.Tricks` (`bmx_bot_trick Air 180`): the bot lays a tall park quarter pipe or a spine at the end of its clearest run and rides at it sprinting. The ramp FINDER is unchanged (it turns steep walls down on purpose; a vert wall is laid, not found). They are not in `Bot.TrickList`, so the show and SKATE do not pick them and no `bot_*` headless case was made. Not run live. |

Tests: `tests/test_air_assist.lua` (19: classifier on synthetic normals, the
turn settling at 180 either way, held, tap, barrel roll kept off vert, RMB 360
kept, assist off, landing aim, spine finder on a synthetic profile, the
transfer on the plant, combo, scoring, the setting). Headless, appended to
`sv_test_cases.lua`: `vert_turnaround` (tall park quarter pipe, D tapped, lands
facing down the ramp) and `spine_transfer` (park spine, W at the top, lands on
the far side, "Spine Transfer" scored).

Left: run the two headless cases and tune the entry speed (430 u/s from 380 u
back is a guess at what clears an 84 u deck); ride it to set `vertYawRate` and
the aim gains; the bot's two tricks live; a quarter pipe in a map that is not a
park piece is classified the same way but has not been looked at.

## Status update (2026-10-08): the two cases on a real server

`spine_transfer` is no longer `wip`: 20/20 on a private server on top of 39211f2 (7/10
before it). `vert_turnaround` stays `wip` at 12/20 (CI a326eb6 / 1004: 0 of 3 each). What
was wrong, measured per tick:

- **The turn did a third of its rate.** It read the smoothed lean (a third of a second to
  full), it applied one torque along world up to a body whose inertias differ (so it spun
  about the frame's long axis and the nose swung off sideways), and the roll damping and
  landing roll-levelling in `AirControl` read a turn about world up off a 70 degree wall as
  a roll to stop. Now the key is read as pressed, the torque is the one angular acceleration
  shared out axis by axis, and while VertAir is turning nothing else acts about world up.
  The half turn is made: 165-200 degrees where it was 70-120.
- **It came down on its side.** Turned, the bike is still nose-up. Past `Air.vertDropStart`
  (100 degrees) on the way down the whole attitude is steered onto the landing one (forward
  down the fall line, wheels to the face, `vertDropKp/Kd`), with the turn's own settle about
  world up until `vertDropAim` (160 degrees) and the heading after.
- **Half its speed went into the coping and the strip joints** (G27): 311 u/s up the face,
  131 left at the lip; now 150-165 leave it.
- **The spine transfer** blended the bike onto the way DOWN the far face from an apex short
  of the top, and it hung on the coping. It now carries the bike across the top at
  `spineSpeed` and lets gravity bring it down.

Left, from the 10-run logs: a vert flight off the 84 u quarter pipe at 430 u/s is half a
second, and a 180 about world up plus the nose-over is ~300 degrees of rotation; in 3-5 of
10 the bike is still swinging round when it lands and ends across the face. Off the 70
degree top it drifts toward the deck. (Tried and not kept: starting the heading aim at 130
degrees of turn and a slower spine carry, both worse.) Offline: `tests/test_air_assist.lua`
"nose up off a wall, a quick D: a half turn and back over onto the face in half a second".
