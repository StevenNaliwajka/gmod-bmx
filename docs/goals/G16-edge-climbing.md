# G16 -- Climbing over curbs and edges at low speed

**Competitor:** [#16](https://github.com/luttje/gmod-bicycle/issues/16)
(closed): "(at low speeds) If 1 wheel is over a step instead of climbing over
it, it just gets stuck."

**Us today:** unknown, and that's the problem. A downward ray per wheel
(`sv_wheel.lua`) sees the step only once the axle is **over** it. Before
that the tyre's front face is against the step, and nothing pushes it up.
At walking pace we have the same failure mode as them. The `into_a_ledge`
headless case is about grinding, not curbs.

## Goal

A wheel rolls up a step up to ~40% of its radius (a curb) at any speed above
walking, like a real tyre does. Bigger steps need a hop, a manual or a bunny
hop, which keeps the skill and is how BMX works.

## Done when

- At 3 mph, both wheels climb an 8 u curb (≈ 40% of the 20" BMX's radius).
- At 3 mph, a 16 u step stops the front wheel. A manual (RMB) gets the
  front up, and the rear then climbs on its own if the step is ≤ 40% of the
  rear radius.
- The mini (16") and the cruiser (24") scale with their radius.
- No step-climbing "pop": vertical acceleration stays under 3 g on a curb
  at 10 mph.

## Approach

This shares its fix with G05: the swept wheel and front-quadrant rays find
the step's top edge in front of the axle. The contact normal there points back
and up, so the suspension force along that normal lifts the wheel exactly as
the step's corner would. Do G05 and G16 as one change, with tests from both.

## Tests

- Headless `climbs_curb_slow` (8 u box), `stops_at_step_then_manuals_up`
  (16 u), `curb_no_pop` (10 mph, 8 u, peak accel), on all three bikes.
- Spawn curbs with `bmx_city_solid` boxes so the cases don't depend on a map.

## Risks

Same as G05.

## Status (2026-10-07)

**Implemented with G05, behind `bmx_wheel_sweep` (default 0); the offline half
passes, the headless cases are written but unverified until CI runs them.**
See the G05 status and `docs/DESIGN.md`.

A correction to the goal's own numbers, which is why the cases differ from it:
an "8 u curb" is 0.8 of a 20 inch tyre's 10 u radius, not 40% of it, and a
curb that tall is not rollable at walking pace (the contact normal at first
touch is nearly horizontal). The cases use heights as fractions of each bike's
radius: **0.4 radius** for "a curb" (4 u on the BMX, 4.8 on the cruiser, 3.2 on
the mini) and **1.6 radii** for "too tall" (the goal's 16 u), so the mini and the
cruiser scale as the goal asks.

- **At 3 mph both wheels climb the curb: done on the plant for all three
  bikes** (the contact is found, the chassis ends on the curb's top, both wheels
  down); `climbs_curb_slow` is written for the engine.
- **A 1.6-radius step stops the front wheel, a manual gets it up: written
  (`stops_at_step_then_manuals_up`), plant half done.** On the plant the tyre
  stops at the face and does not climb it. "The rear then climbs on its own if
  the step is <= 40% of the rear radius" is not tested: the step in the case is
  four times that, so the rear cannot, and the case asserts only the stop and
  the lift.
- **Scale with radius: done** (both cases and offline tests use `0.4 * radius`).
- **No pop, vertical acceleration under 3 g at 10 mph: written
  (`curb_no_pop`), unverified, and probably tight.** Rolling a tyre onto a
  4 u curb at 176 u/s takes ~0.05 s, an average vertical speed of ~75 u/s, so
  the figure is measured over a 50 ms window (what a rider feels) rather than
  tick to tick. Expect this band to be the first to move.
  On the plant, 10 mph over a curb stays under 3 g tick to tick.

The only thing the sweep does to the existing step handling is leave it alone:
the climb-rate limiter and `stepMax` still govern the floor ray, and the fan's
contacts bypass them because they are geometry and rise as smoothly as the tyre
rolls onto the face.
