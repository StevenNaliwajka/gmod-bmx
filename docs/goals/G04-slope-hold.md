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
