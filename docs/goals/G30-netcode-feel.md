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

### Update (2026-10-15): the skates under a ping, offline

The skates (G25) are the one vehicle whose MOVEMENT the client predicts: the player is the
chassis, so the engine runs `SetupMove` for them on the client too, and `cl_skates.lua` runs the
shared step there. An audit found nobody had tried that with a ping. With no game client to
hand, `tests/test_skates_ping.lua` (on `tests/lib/netsim.lua`) runs a server and a client realm
against each other over a link (50, 100 and 200 ms RTT, +-20 ms jitter each way, 1% loss): the
engine's client loop (a usercmd a tick predicted at once; on a snapshot the networked fields put
back to the server's for the acknowledged command and, if they differ from the prediction, every
later command predicted again; `cl_pred_optimize 2`), the server running commands as they come (a
lost one replaced by the last), and one stand-in for `CGameMovement` on both ends.

Riding, carving, jumping and stopping were already exact. Four things were not, and are fixed
(1.3.4 against the fix, a one-second grind balanced with A / D from the HUD meter):

| | 1.3.4, 100 ms | 1.3.4, 200 ms | fixed, 100 ms | fixed, 200 ms |
|---|---|---|---|---|
| On a rail: the client's picture against the server's, 95th pct / worst | 15 / 25 u | 37 / 50 u | 0 / 6 u (the lock) | 0 / 6 u |
| On a rail: corrections over 4 units | 17 | 20 | 0 | 0 |
| The pop off a rail: the jump when the server's answer comes | 22 u | ~40 u | none | none |
| A carve with every snapshot replayed: worst | 22 u | | 0 | 0 |
| Holstering while rolling: the snap | 14 u | 41 u | 0 | 0 |

The causes: on a rail the client handed the move to the engine with the keys still in it (A and D
walked the skater off the rail's side, W walked); the pop was the server's alone; the client's
own state (heading, stride clock, last SPACE, last speed) was not wound back when the engine
predicted commands again, so a replay disagreed and the next one did too; and the client started
and stopped predicting on `BMXWorn`, a ping late. The fixes are in `cl_skates.lua`'s PREDICTION
note. A bike under the same link is never corrected and drawn 13-56 units behind where it is (a
hop seen 166 / 227 / 318 ms after the key at 50 / 100 / 200 ms): the trade the owner accepts.

**Still the server's:** the LOCK onto a rail. The client has no rail finder, so for a ping it
lands on the rail's top and rolls. Along a rail that is close to a grind (a correction of 0.4 u
at 100 ms, 1 u at 200); turned across it (a backslide) the wheels grip, and the client is
corrected once by 8 u at 100 ms, 30 u at 200. A ledge's lock: 4.6 u, 10 u. Predicting it means
sharing `sv_grind.lua`'s finder (it is entity-free) and the skates' lock with the client.

**What a real client must confirm** (the simulation is not the engine): a client on a LAN server
(`sv_cheats 1`) with `net_fakelag 100` (then 200) and `cl_showerror 1` (prediction errors in the console), skates
equipped from the WEAPON SELECTOR (that switch is predicted; `bmx_give_skates` is not):

1. Stride straight, carve, jump, T-stop: no `cl_showerror` lines, no visible hitch.
2. A soul grind on a long rail, tapping A / D for balance: the view stays on the rail, does not
   turn with A / D, and does not slide sideways. Let go of SPACE: the pop is instant and smooth.
3. Ride a grind off the rail's end: a short drop, no hitch.
4. A backslide and a ledge grind: expect ONE correction as it locks on (the known limit above),
   then nothing; a ledge's pop goes away from the ledge.
5. Holster while rolling fast: you stop gliding at once, with no snap a ping later.
6. Stride with `net_fakeloss 5`: corrections, if any, settle at once rather than repeating.

If any of 1, 2 or 6 shows repeated errors, the engine is restoring or predicting something
`lib/netsim.lua` assumes it does not: `cmd:CommandNumber()` in the client's `SetupMove`, the
replay restoring the networked velocity and friction (`m_flFriction` in the player's local
send table), the order StartCommand, weapon switch, view angles, SetupMove, and `BMXSkateFlags`
arriving with the snapshot it belongs to (the NW vars are not predicted) are the assumptions.
