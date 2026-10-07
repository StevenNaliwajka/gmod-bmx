# G01 -- The bike's details follow its moving parts

**Competitor:** [#1](https://github.com/luttje/gmod-bicycle/issues/1) (closed):
the right brake cable on the handlebar came loose when steering. It's a
skinned-model bug: one vertex group was weighted to the frame bone instead of
the bar bone.

**Us today:** the bike is drawn from beams in `entities/bmx_base/cl_init.lua`.
Bars, fork and cranks follow the steer angle and cadence because they're
computed from them, so we can't get this exact bug. There are no cables at all,
and once we ship a real model (G20) we inherit the whole class of bug.

## Goal

Every part that should move with the bars, fork, cranks or wheels does, at any
steer angle and through barspins (G03), on the procedural bike and on every
model.

## Done when

- The procedural bike draws brake cables (and a gyro/detangler on the BMX)
  from the bars to the frame, following the steer angle, and they don't
  self-intersect through a full barspin.
- Every registered model passes an automated **rig check**: each bone a part
  needs (bars, fork, front wheel, rear wheel, cranks, pedals) exists, and the
  offline suite checks the bone names against the registry entry.
- A visual check (`bmx_debug 2`) draws each part's bone axis, so a mis-weighted
  part is obvious in one screenshot.

## Approach

- Cables: a three-point Bézier from the lever to the frame stop, with the
  lever end taken from the bar transform. Drawn with `render.DrawBeam` segments
  like the rest of the bike.
- Rig check: add a `bones = { bars=..., fork=..., ... }` table to model entries
  in `sh_bikes.lua`, validated at registration the same way `physics` overrides
  already are (unknown key = loud error).

## Tests

- Offline: registry rejects a model entry that's missing a required bone.
- Offline: cable endpoints at steer ±90° and after 360° of barspin stay
  attached to the bar transform (distance < 0.5 u).

## Risks

Low. Pure client drawing, no physics change.
