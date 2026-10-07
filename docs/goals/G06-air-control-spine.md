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
