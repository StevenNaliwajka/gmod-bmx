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
