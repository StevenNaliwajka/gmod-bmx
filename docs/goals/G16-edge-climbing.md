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
