# G30 -- Feel under real ping

**Competitor:** an animation-driven SENT, so its feel online is whatever
GMod's entity interpolation gives it. No public work on prediction.

**Us today:** the physics runs on the server and clients see the
networked result (`docs/DESIGN.md` §5). `docs/GOALS.md` P2 still lists "ride
on a real server with real ping" as **needs a person**. At 100 ms, the input
→ lean → steer chain is 100 ms behind the rider's fingers, which is the
difference between a trick game that feels tight and one that feels floaty.

## Goal

Riding at 150 ms feels close to riding on a listen server.

## Done when

- A measured baseline: with `net_fakelag 50/100/150` on the test server, an
  input-to-visible-lean latency number for each, recorded in `docs/TUNING.md`.
- **Client-side visual prediction** of the rider's own vehicle: the client
  runs the same lean/steer controller for display, from its own input, and
  blends to the server state (error < 4 u snaps, larger errors ease over
  100 ms). Other riders stay interpolated.
- Trick inputs are timestamped with the usercmd tick so a trick pressed at
  the lip on the client counts at the lip on the server (lag compensation for
  takeoff decisions like G06's spine and G23's ollie pop).
- At 150 ms fake lag, a tester can hold a manual and land a grind at their
  listen-server success rate ±10%.

## Approach

`sv_input.lua` already decodes usercmds, so the shared controller code moves to
a `sh_` file to run on both sides (as `sh_config.lua` does). Only the rider's
own vehicle predicts.

## Tests

- Offline: the shared controller returns identical outputs on client and
  server shims for the same input sequence (determinism).
- Headless with `net_fakelag`: server state is unaffected (prediction is
  display-only).

## Risks

Prediction mismatch shows as rubber-banding, so ship it behind
`bmx_predict 1` (default off) until riders say it's better.
