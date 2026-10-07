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

## Status (2026-10-07)

Built on branch `worktree-agent-a4c9798db73feff8f`; offline suite green
(`tests/test_tricks.lua`). The headless cases are written but have **not**
been run on a real server, and nothing has been looked at in the game: the
drawing and the IK are checked only for "runs, finite, parts where the maths
says".

| Done when | |
|---|---|
| Tailwhip: frame turns 360 about the steer axis, bars and rider stay, feet leave the pedals and return | **Done**, drawing unseen in-game. `cl_init.lua` rotates the rear group about the head tube; the foot IK targets stay at the unwhipped pedals. |
| Barspin: bars (and fork) turn 360, hands let go and catch | **Done**, drawing unseen in-game. Hand targets come from the bars *without* the spin. The front wheel turns with the fork, as the goal says. |
| Scored and chained, 600 / 400, x N, "Tailwhip to Barspin" | **Done.** Both in one air merge into one entry, e.g. "2x Tailwhip to Barspin" (1600), which the combo counts as two tricks (`tricks = 2`). |
| Auto-complete over 270, snap back under 90, between = out of line | **Done** (`sv_tricks.lua`, config `Tricks.autoComplete` / `snapBack`). |
| Landing more than 30 deg out of line bails through the existing path, combo lost | **Done** (`BMX.LandingFault`, read by `ENT:JudgeLanding`, reason `whip` / `bars`). Tested on the entity and on the plant. |
| Barspin also works in a manual | **Done**; a finished barspin pays on the spot. |
| Bindings: LMB + A/D whip, R bars, LMB + R both; RMB + A/D stays 360 | **Done.** |
| Rebindable (G19) | **Not done**: waits on G19's settings panel. The keys are read in one place (`sv_input.lua`). |
| `st.whipAngle` / `st.barAngle` networked as one byte each | **Done, slightly different**: `st.parts.whip.angle` / `.bar.angle`, packed with the pose id into one int `TrickBits` (a byte each, three bytes). |
| Counter-torque on the chassis | **Done**, small (`Tricks.whipKick`); the plant shows a few degrees of yaw. |
| Bot: `tailwhip`, `barspin` in `bmx_bot_trick` | **Done** (`Tailwhip`, `Barspin` in `Bot.TrickList`). |
| Tests: 280 / 80 deg whip, 40 deg bail, points and names for whip x2 + bars, headless `tailwhip_lands` | **Done offline**; `tailwhip_lands` written, **not run**. |
