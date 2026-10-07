# G24 -- Kick scooter

**Competitor:** none. (Their #15 mentions a moped with pedals, which is a
motor vehicle, G15.)

**Us today:** nothing. After G22 and G23 it's cheap: 2 small wheels in
line (single track, like the bike) with the **board's** push and the bike's
bars.

## Goal

A pro stunt scooter, the third park vehicle. Scooter tricks are mostly bike
tricks (tailwhip, barspin) on a board-like deck, so most of the trick code
comes from G03 and G23.

## Done when

- `bmx_spawn scooter`, spawn menu **Scooters**.
- Riding: push like the board (W), steer at the bars like the bike
  (`singletrack` balance with a small trail), rear fender brake (S).
- Tricks: bunny hop, **tailwhip** (deck around the bars, from G03),
  **barspin** (G03), **bri flip** (whip + flip), front/back flips, manuals,
  grinds (deck and pegs: 50-50, feeble, smith).
- Rider: both feet on the deck, IK.
- All headless riding cases on `scooter`.

## Approach

Registry entry on G22: `family = "scooter"`, `balance = "singletrack"`,
`drive = { push = ... }` (from the board), `tricks` = the bike's air set +
whip and barspin. No new physics.

## Tests

- Headless: the riding cases plus `scooter_tailwhip_lands`.

## Risks

Low. It depends on G03 and G23 landing first.

## Status (2026-10-07)

Built on branch `feat/scooter-skates` (one commit, on top of the skateboard at `06e4f7c`), not merged, not on the
Workshop. Nothing about the bike or the board changed: their tests pass unchanged, with one pinned list (the
"unknown bike" message) gaining the scooter.

| Done when | |
|---|---|
| `bmx_spawn scooter`, spawn menu **Scooters** | **Done.** `BMX.RegisterBike("scooter", ...)` with `family = "scooter"` (`sh_scooter.lua`): the spawn row is under Scooters, `bmx_allow_scooters` switches it off (the setting row already existed), it is duplicable and counts toward `bmx_max_per_player`. No new convar. |
| Push like the board (W), bars like the bike, `singletrack` with a small trail, fender brake on S | **Done, on the plant.** The `push` drive gained `footBrake = false` (the board's foot drag and kick-turn off); S is the platform's rear brake. The small trail is `Balance.steerRate 15` (the bike's lag on the bars "standing in for trail") with a wider `maxSteer`. 5-unit wheels on a 28-unit wheelbase, 62 kg. |
| Tricks: bunny hop, **tailwhip**, **barspin**, **bri flip**, flips, manuals | **Done.** Hop, flips, 360, poses and manuals are the bike's code untouched; the tailwhip and barspin are G03's state machine as it is (auto-complete past 270 degrees, snap-back under 90, a landing more than 30 degrees out of line bails), and what turns is the deck, rear wheel and fender about the steer tube. The **bri flip** is a whip and a front or back flip in one air merged into one entry that counts as two tricks (`BMX.Scooter.MergeBri`). A manual is paid as "Manual", not "Wheelie". |
| Grinds: 50-50, feeble, smith | **Done through `grindPoints.moves`.** 50-50 is the deck on a pipe or a ledge; on a ledge's edge W as it locks on is a smith (the front peg), S a feeble (the back peg). Each is a contact rule in `BMX.Scooter.Grinds`. The pose is turned only 0.2 rad off the rail: the plant found that the 0.35 first written put the peg wheel's box 0.2 units over the ledge's top and the grind never locked, so the angle is now checked against the wheel box in the suite. Nose onto the top for the smith, out over the drop for the feeble. |
| Rider: both feet on the deck, IK | **Done, unseen.** Pose set `scooter` (`cl_scooter.lua`): both feet on the deck (the left ahead), hands on the grips, the back foot is the pushing one (the board's push cycle), knees by the board's calibrated pelvis nudge. A tailwhip leaves the feet where the deck was, a barspin leaves the hands. Nobody has watched it on a real player model. |
| All headless riding cases on `scooter` | **Written, not run** (no server here): `scooter_pushes_to_speed`, `scooter_carves_without_tipping`, `scooter_tailwhip_lands`, `scooter_50_50_on_rail`, and 11 of the shipped riding cases as `<case>@scooter` (the ones that assume no pedal or front brake; `wheelie`, `stoppie`, `accelerate` and `brake_locks` are not on it). |

**Tests.** `tests/test_scooter.lua` (30): the registration, the input map and decode, the keys that pick each grind and the rule for each contact (below the hull's boxes, the peg wheel clear of the ledge), the bri flip merge, rides on the plant (kick to speed, coast, the fender brake, both carves, a hop), the tailwhip completing by itself on the scooter and paying 600, a barspin, "Tailwhip to Barspin", a bail on a half whip, a bri flip, the 50-50 / smith / feeble locks, no lock across a rail, the drawing (feet and hands, a whip, a barspin, every pose) and the headless bookkeeping.

**What the plant could not say, the biggest feel risks:** whether `steerRate 15` is twitchy or just wrong, the fender brake's stop against a real tyre, the standing rider's pose and seat height, and the grinds' pose against real VPhysics hulls (the plant is a box world).
