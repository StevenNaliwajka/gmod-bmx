# G05 -- Riding up and down steep ramps without sinking

**Competitor:** [#5](https://github.com/luttje/gmod-bicycle/issues/5) (closed):
on `hb_skatepark_v7` and the PHX `tri2x2x2solid` wedge, "the bike abruptly
stops and the wheels just start sinking into the ramps" at steep angles or
against vertical faces.

**Us today:** our wheels are rays along the chassis down axis, with the
contact corrected to below the axle under pitch (`docs/DESIGN.md` §7, "The
tyre touches down below its axle"). That handles the slope itself. What a
single ray **cannot** see is a face *in front of* the tyre: at the foot of a
45° wedge the ray still hits flat ground while the front of the tyre is
already inside the ramp. The headless `lands_on_a_transition` covers landing
on a curve, not riding *into* a steep face.

## Goal

The bike rides up any transition or wedge up to 60°, down any up to 80° (a
vert quarter pipe roll-in), and into a vertical wall without the wheel going
into the geometry. It bounces off, crashes, or (with a hop) climbs it (G16).

## Done when

- Ride at 20 mph into a 45° PHX wedge: the bike goes up it, and wheel
  penetration stays < 1 u every tick.
- Roll in to a 75° quarter pipe from the top: no tyre clip, and you ride out.
- Ride at 10 mph into a vertical wall: the front wheel stops at the wall (or
  the rider goes over the bars above a threshold), and the wheel never passes
  through it.
- All of it holds on `hb_skatepark_v7`, `gm_skatepark` and `pf_skatepark`,
  the maps the competitor's players ride.

## Approach

Replace the single suspension ray with a **swept wheel**: a short
`util.TraceHull` (a thin disc approximated by a box the tyre's width and
radius) from the axle forward along velocity, plus a fan of 3-5 rays over
the front quadrant of the tyre (−60°…+30° from straight down). Take the
contact as the *shallowest* penetration among them, with the contact normal
from that hit. The suspension force acts along the normal, not along the
chassis down axis, so a steep face pushes the wheel back and up. The
contact-below-axle correction generalises to "contact on the tyre circle in
the direction of the hit".

Performance: 5 rays × 2 wheels at 66 tick is 660 traces/s per bike. The
`crowd` case (25 bikes at 66 tps) is the budget. Only fan out when the centre
ray reports a slope over 25° or the previous tick touched a steep face.

## Tests

- Headless `rides_up_wedge_45`, `rolls_in_to_quarter`, `into_a_wall_stops`,
  each checking max penetration from a trace inside the tyre.
- The `crowd` case must still hold 66 tps.
- Offline: contact solver unit tests on a synthetic wedge.

## Risks

This changes the wheel model under everything, so it's the riskiest item in
this list. Land it behind `bmx_wheel_sweep 1` (default off), ride it, then
flip the default.

## Status (2026-10-07)

**Implemented behind `bmx_wheel_sweep` (default 0), partly measured.** The
swept wheel is shared with G16 and is described in `docs/DESIGN.md` ("Two
things a ray and a slip velocity cannot do"): a one-ray bumper, a nine-ray fan
only when needed (a face ahead, a floor over 25 degrees, or a face touched in
the last 0.15 s), resolved as a plane or an edge, applied as a second
normal-only contact beside the floor's. `BMX.SweepProbe / SweepContact /
SweepResolve` are pure functions in `sh_util.lua`, run offline against
hand-built geometry. The headless cases are written but **unverified until CI
runs them.**

Done-when, item by item:

- **20 mph into a 45 degree wedge, penetration < 1 u every tick: not met as
  worded, partly met.** The solver finds a 45, 60 and 75 degree face exactly
  (depth within 0.1 u, offline), and `rides_up_wedge_45` is written. 20 mph is
  352 u/s, above the bike's ~310 u/s top speed, and a 30 u wedge is what 240
  u/s can climb (`v^2 = 2*g*h`), so the case rides a 30 u wedge at 240. The
  "< 1 u" does not hold by construction: a face contact is a spring like the
  ground's, so the chassis is compliant against it by up to the strut's travel
  (the same as the 3 u of sag into the ground). The case asserts the face never
  bottoms the strut instead.
- **Roll in to a 75 degree quarter pipe: written (`rolls_in_to_quarter`,
  a 6-chord approximation of an R=100 arc), unverified.** Contact is found on
  faces to 80 degrees; steeper is a wall.
- **10 mph into a vertical wall, never through it: written
  (`into_a_wall_stops`), unverified.** On the plant, at 3 mph, the tyre stops
  within the strut's travel and does not climb (a wall is suspension-only: no
  tyre force, so pushing on it does not climb it). At 10 mph the hull, not the
  wheel, is what stops a bike in the engine (the spring has 8,600 a unit against
  1.3 million of kinetic energy), which the plant has no hull for.
- **All of it on `hb_skatepark_v7`, `gm_skatepark`, `pf_skatepark`: not done.**
  The cases build their own terrain with `bmx_city_solid`, so they do not depend
  on a map; nothing has been ridden on those three.

Not done: the thin hull trace (an AABB cannot be rotated into the wheel plane;
the fan plus the second contact gives the same push), tyre friction on faces,
and the client's wheel drawing (it still draws from the strut ray, so against a
steep face the drawn tyre can pass through it by the strut's compression). The
`crowd` case has not been run with the sweep on; flat ground costs one extra
trace a wheel. The default stays off until it has been ridden.

Tests: `tests/test_wheel_contact.lua` ("sweep: ..." solver tests on a wedge,
steps and a wall; "sweep (plant): ..." closed-loop on the plant), headless
`rides_up_wedge_45`, `rolls_in_to_quarter`, `into_a_wall_stops` (+ variants).

## Status update (2026-10-08)

`rolls_in_to_quarter` is no longer `wip`: 10/10 on the stock bike, the cruiser, the mini,
the fixie and the city bike on a private server; it was passing on main since the
riding-into-things work (04141d0, d2d700d). `@road` stays `wip`: 25/30, the five lost all
turned over on the way down (roll 164). `rides_up_wedge_45` on `@mini`, `@road` and `@fixie` stays `wip`:
5-7/10 each, every failure the same stall on the top edge (the wheel box meets the 45
degree face, VPhysics keeps the 0.71 of the speed along it, the bike reaches the top at
60-90 u/s). Turning the motion up the face instead (keeping most of the speed) got those
three to 9-10/10 and broke the cruiser (5/10, 2/8): faster, a bike flies off the top edge,
and a wheel coming down on that convex corner is pushed out of it as an obstacle and
stopped dead. Rolling over a crest is what is left; it was not shipped.
