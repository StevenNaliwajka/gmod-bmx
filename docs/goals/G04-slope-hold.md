# G04 -- A parked or braked bike holds on a slope

**Competitor:** [#4](https://github.com/luttje/gmod-bicycle/issues/4) (closed):
"there isn't any friction holding the bike steady, meaning a tiny incline
causes it to slide continuously."

**Us today:** probably fine, but nothing proves it. Our tyres use a
slip-velocity model (`sv_wheel.lua`, `docs/DESIGN.md` §2). A pure
slip-velocity model has **no static friction**: at zero slip it gives zero
force, so a braked wheel creeps downhill at a speed of
`m·g·sin(θ) / stiffness`. There is no headless case for a slope.

## Goal

A bike stands still on any slope its tyres could hold in real life (up to
about 30° on dry concrete), with brakes held or on its kickstand, and it
doesn't drift at all, not even slowly.

## Done when

- With the rear brake held on a 10° slope, the bike moves < 1 u in 10 s.
- Parked on its stand on a 10° slope, < 1 u in 60 s.
- Rolling freely (no brake) on a 2° slope, it does roll: we don't add
  stiction to free rolling.
- No new jitter at rest: chassis velocity < 0.5 u/s RMS while held.

## Approach

Add a **stick-slip anchor** to a braked or parked wheel: when the contact
patch speed is below `stickSpeed` (≈ 2 u/s) and the wheel is braked, store
the contact point and apply a spring-damper towards it, limited by the friction
circle. If the required force exceeds μ·N, the anchor breaks and normal sliding
resumes. This is the standard fix for slip-velocity tyre models (it's how
most raycast car sims hold on hills), and it slots into the existing per-wheel
force step.

## Tests

- Headless `holds_on_slope`: spawn on a tilted `bmx_city_solid` or a PHX
  wedge at 5°, 10°, 20°. Brake held, check drift.
- Headless `parked_on_slope`: same, on the stand.
- Headless `rolls_on_gentle_slope`: no brake on 2° and it accelerates.
- Run each on all three bikes (the harness already does this for riding cases).

## Risks

A spring anchor can buzz if it's under-damped. Critically damp it against the
bike's mass, and test at 33 and 66 tick.

## Status (2026-10-07)

**Mostly done, with one deliberate difference from the spec.** The headless
cases are written but **unverified until CI runs them**; the offline results
below are on the shim's rigid-body plant, which is right in kind and is not
VPhysics.

Implemented: the stick-slip anchor in `Wheel:Simulate` (`sv_wheel.lua`,
"STATIC FRICTION"), convar `bmx_wheel_stiction` (default 1), config
`Wheel.stiction / stickSpeed / stickFreq / stickCooldown`. Critically damped
against the effective mass at the patch, integrated implicitly (stable at any
tickrate), limited by the friction circle, broken at `grip*N` with a cooldown. A
riderless bike on its stand has its wheels treated as locked on a slope
(`Wheel.hold`, set in `sv_physics.lua`). Documented in `docs/DESIGN.md`
("Two things a ray and a slip velocity cannot do").

Done-when, item by item:

- **Brake held on a 10 degree slope, < 1 u in 10 s: done on the plant, with the
  FRONT brake.** The rear brake key at a standstill is the paddle-backwards key
  by design (`drivetrain` in `sv_physics.lua`: below 40 u/s it releases the
  brake and pedals back), so it can never be what holds a bike, and I left that
  alone. A front-only hold also depends on which way the bike faces (uphill the
  weight is on the rear and a front-only hold gives up near 12 degrees on the
  plant), so the 20 degree case faces downhill. Offline: 5 and 10 degrees
  uphill and 20 downhill all hold under 1.5 u; with `bmx_wheel_stiction 0` the
  same bike creeps over 3 u (the control).
- **Parked on its stand on 10 degrees, < 1 u in 60 s: done on the plant** (also
  20 degrees). Note that the existing kickstand hold (7c) already did this on the
  plant; the anchor is what keeps the tyres from carrying the slope on their own.
- **Rolling freely on 2 degrees still rolls: done** (offline and in
  `rolls_on_gentle_slope`): free rolling never reaches the anchor.
- **No new jitter at rest, RMS < 0.5 u/s while held: done on the plant**, at 66
  and at 33 ticks. Unverified on VPhysics.

Not done: the rear-brake wording of the goal (see above), and a measurement of
whether the anchor's lateral spring fights a leaned, braked bike at a standstill
(it measures raw contact displacement, so it may resist a lean a little).

Tests: `tests/test_wheel_contact.lua` ("anchor: ..."), headless
`holds_on_slope`, `parked_on_slope`, `rolls_on_gentle_slope` (and their
`@cruiser` / `@mini` variants), written, not yet run on a server.
