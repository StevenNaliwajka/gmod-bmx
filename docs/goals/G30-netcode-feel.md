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

## Status (2026-10-07)

Built on branch `g30-predict`, all of it behind switches that default OFF.

- **Shared controller.** `lua/bmx/sh_lean.lua` holds the lean/steer arithmetic
  (input smoothing, rate filter, topple, roll PD, derived steer, steer lag,
  dead zone); `sv_balance.lua` and `sv_input.lua` call it. The server is
  bit-identical: `tests/test_predict_server_unchanged.lua` compares a recorded
  ride, written with `%.17g` BEFORE the move (`tests/data/golden_lean.lua`), and
  keeps the old expressions to compare against.
- **Prediction.** `bmx_predict` (client, default 0), `cl_predict.lua` +
  `sh_predict.lua`: the rider's own single-track bike on the ground is drawn
  with a roll offset and steer that lead the networked ones by ping + cl_interp
  (capped 0.3 s); error under 4 u snaps, larger eases over 100 ms. Display only;
  other riders stay interpolated.
- **Latency probe.** `bmx_latency_probe [n]` and the method in docs/TUNING.md.
  The table there is empty: it needs a live server.
- **Lag comp.** `bmx_lagcomp` (default 0) + `bmx_lagcomp_max` (0.15 s),
  `sv_lagcomp.lua`: usercmd age from `cmd:TickCount()`, clamped by ping; hop
  release (`sv_physics.lua`), ollie coyote window (`sv_board.lua`) and spine W
  (`sv_air.lua`) judge the press at its own time.
- **Tests.** Offline: determinism across realms, server-unchanged, blend/snap,
  the lead, probe math, lag comp, settings rows. Headless: a case asserting
  bmx_predict leaves server state untouched.

**Not done / needs a person on a live server:** the baseline and predicted
numbers in the TUNING table; whether `cmd:TickCount()` gives the age assumed in
`P.CmdAge` on a real srcds (the formula is the engine's own lag-comp, but it is
unverified here); the "manual and grind at 150 ms within 10% of listen-server"
done-when; the rider's body and IK are NOT predicted (the bike is), so at high
ping the body trails the frame a little; prediction is lean and steer only (no
pitch, no air).
