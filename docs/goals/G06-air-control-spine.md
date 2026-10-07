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
