# G03 -- Tailwhip and barspin

**Competitor:** [#3](https://github.com/luttje/gmod-bicycle/issues/3) (closed,
shipped). Tailwhip = LMB + A/D in the air, which spins the frame around the
head tube. Barspin = RMB + A/D in the air *or in a wheelie*. Both together =
both mouse buttons + A/D. Hold for more turns, and "let go early and the spin
finishes the turn by itself".

**Us today:** none. The air tricks are flips, barrel roll and 360
(`sv_air.lua`, the `spinPitch / spinRoll / spinYaw` table near line 200). RMB +
A/D in the air is already yaw (the 360), so the competitor's barspin binding
collides with ours.

## Goal

These are the two signature BMX tricks, and a BMX addon without them gets
reviewed as unfinished. Ours should look better than theirs: the frame and bars
are physically separate parts here, so the frame mass can actually swing
round, not just be animated.

## Done when

- **Tailwhip**: the frame (rear wheel, cranks, seat) rotates 360° about
  the steer axis while the bars and rider stay put. The rider's feet leave the
  pedals during the whip and come back at 360°.
- **Barspin**: bars and fork rotate 360° about the steer axis, and the
  rider's hands let go and catch.
- Both are scored and chained in `sv_combo.lua` (suggested 600 / 400 points,
  ×N for N rotations, "Tailwhip to Barspin" when both are in one air).
- **Auto-complete**: releasing the input with more than 270° done finishes
  the rotation, and releasing with less than 90° snaps back. In between, the
  part is out of line when you land, and you crash.
- **Landing rule**: landing with the frame or bars more than 30° out of line
  bails (the bike isn't rideable), and this goes through the existing bail
  path so the combo is lost.
- Barspin also works in a manual (ground trick), the way theirs does.

## Approach

- **Bindings:** keep our RMB + A/D = 360, because it's a real trick and
  combos need it. Bind tailwhip to **LMB + A/D** in the air (the front brake
  does nothing in the air, so it's free). Bind barspin to **R** in the air or
  in a manual, and bars-and-whip to LMB + R. Make all of it rebindable (G19).
- **State:** add `st.whipAngle` and `st.barAngle` next to `spinYaw`, network
  them as one byte each (the bikes already send a small state struct in
  `sv_physics.lua`), and render them in `cl_init.lua` by rotating the frame
  group and bar group about the head-tube axis.
- **Physics:** the angular momentum is small, so model the whip as a
  kinematic part rotation with a counter-torque on the chassis (the rider
  "throws" the frame). That gives a small, believable yaw wobble.
- **Bot:** add `tailwhip` and `barspin` to `bmx_bot_trick` so the trick bot
  shows them off on servers.

## Tests

- Offline: a whip released at 280° completes, and one released at 80° snaps
  back. Landing at 40° out of line bails, and the combo is lost.
- Offline: points and chain names for tailwhip ×2 + barspin.
- Headless `tailwhip_lands`: off the ramp case, a whip is commanded and the
  bike lands rideable.

## Risks

The binding collision is the real risk: changing what RMB + A/D does in the air
would break riders' muscle memory. So we add bindings and keep the existing
ones.
