# G13 -- Other bikes: unicycle, penny-farthing, tandem, downhill; rack and lock

**Competitor:** [#13](https://github.com/luttje/gmod-bicycle/issues/13) (open):
a sports bike, an enduro/DH bike, a carbon frame, an alternative BMX, a
**unicycle** ("requires addon rework to support single wheel balance"), a
**penny-farthing**, a **tandem** ("requires addon rework to support passenger
IK"), a **car bike rack** and a **bike lock**.

**Us today:** our balance controller already leans the bike by steering
(`docs/DESIGN.md` §3), and the wheel model is per-wheel. A unicycle is "one
wheel, no steering, balance by pedalling", which is the controller they'd
have to rewrite and a parameter change for us after G22.

## Goal

Ship the oddballs they flagged as hard, because those are the ones that show
off a physics core: **unicycle first**, then penny-farthing, then tandem.
Downhill (DH) bike for the mountain crowd. The rack and lock are utility
props for RP.

## Done when

- **Unicycle:** one wheel, fixed drive (G10), fore/aft balance by pedalling
  (W/S), side balance by leaning (A/D) and twisting (mouse yaw). It's hard
  and it's meant to be. Tricks: idle (rocking in place) and hop. It falls
  over and ragdolls on loss of balance.
- **Penny-farthing:** front-wheel drive direct, a huge front wheel (≈ 26 u
  radius), the rider high up. A hard front brake pitches you over the bars
  ("header"), which is real and very funny.
- **Tandem:** two seats (G11 seat list), both pedal and torque adds up.
  The front rider steers.
- **DH bike:** long-travel suspension (the `physics` overrides already cover
  spring/damper), big tyres, very stable at speed, heavy. Rides
  `gm_downhill`-type maps.
- **Bike rack:** a prop that welds to a car (`prop_vehicle_jeep` or simfphys
  / LVS vehicles) and holds up to 2 bikes.
- **Lock:** a SWEP or tool that locks a parked bike to a world surface. Only
  the owner (or CAMI admins, G19) can unlock it. It's for RP.

## Approach

All after G22. Unicycle needs the platform's `wheels = 1` case and a
balance mode that ignores steering. Penny-farthing needs `drive = "front"`.
Tandem needs G11's seat list with `pedals = true` on both seats.

## Tests

- Headless `unicycle_balances_with_bot`: the bot holds it upright for 10 s
  with W/S input only.
- Headless `penny_header`: full front brake at 15 mph ejects the rider forward.
- Offline: tandem torque sum.

## Risks

The unicycle may be no fun if it's too realistic. Ship it with an assist
level (`bmx_unicycle_assist`, default 0.6).

## Status (2026-10-07)

Done on a worktree branch, one commit per group (unicycle, penny-farthing, tandem, DH,
rack, lock), not merged, not on the Workshop. The offline suite and the Workshop kit test
pass; the four headless cases are **written and not run** (no server here).

- **Unicycle** (`unicycle`): one wheel, `drive = { kind = "fixed", reverse = true }`
  (S pedals backwards at any speed: there is no brake), the `unicycle` balance mode
  (`sv_unicycle.lua`): an inverted pendulum on two axes, fore and aft by pedalling (the
  drive's torque at the patch, not faked) and side to side by lean, the mouse's yaw twisting
  it round and the lean turning it (a coordinated turn). `bmx_unicycle_assist` (server,
  0..1, default 0.6) is the share of gravity's toppling cancelled for the rider; the spring
  is a fraction of the toppling's own gradient, so it stands alone above assist 0.3 whatever
  inertia the engine measures. Falls throw the rider through the ordinary tip rule (its own
  36 / 40 degrees) as a ragdoll. Tricks `uni_idle` (rock in place, per second) and `uni_hop`.
  Held upright by the stand when parked. Drawn in code (`cl_oddbikes.lua`).
- **Penny-farthing** (`penny`): `front-direct` drive on a 26-unit front wheel (a 6-unit rear,
  `Wheel.rearRadius`), rider 62 units up, `pennyfarthing` balance (single-track plus the header
  rule, `sv_penny.lua`). Full front brake at 15 mph pitches it over the bars on the plant, rear
  wheel off the ground first, and the rider is thrown forward as crash reason `"header"`; half
  a pull, or a pull at walking pace, is not one.
- **Tandem** (`tandem`): the G11 second seat with `pedals = true`; `BMX.Tandem.Push` adds the
  stoker's throttle to the driver's inside the pedal drive, so the torques sum. The captain
  steers; the stoker's keys are read for nothing but pedalling. A stoker's own bars, cranks and
  IK targets are drawn.
- **DH** (`dh`): the stock bike with other numbers and no new code: 16 units of travel, a heavy
  damper, 27.5-inch tyres, 118 kg. A 4 m drop uses 84% of
  the travel on the plant where a BMX uses all of it. **It found a trap:** the spring's static sag must be
  under `Wheel.stepMax` or the wheel's compression is refused every substep and the bike sits on
  its hull (DESIGN 6e).
- **Bike rack** (`bmx_bike_rack`, BMX > Bikes): welds to the nearest vehicle (engine, simfphys,
  LVS) and holds two bikes, welded and set not to collide, not simulating; E on the bike lets it
  down, E on the rack loads the bike beside it or releases the last. `BMX.Rack` (`sv_rack.lua`).
- **Lock** (`weapon_bmx_lock`): left click locks a parked bike to the world (a weld), right
  click unlocks, reload says who. Only the owner or a player with "BMX - Unlock Any Lock" can
  unlock; a locked bike cannot be mounted (the owner's E unlocks it), boarded, physgunned,
  tooled or gravity-gunned by anyone else. `BMX.Lock` (`sv_lock.lua`). Honours `bmx_allow_bikes`.
- **Tests:** `tests/test_unicycle.lua` (35), `tests/test_oddbikes.lua` (26),
  `tests/test_rack_lock.lua` (30); headless `unicycle_balances`, `penny_header`, `tandem_rides`,
  `dh_lands_drop`. The offline shim learned constraints, `game.GetWorld`, `PhysicsInit` and
  scripted weapons.
- **Left:** none of it has been ridden on VPhysics (the plant's inertia for the unicycle's narrow
  body is a scaling of the stock box's); the unicycle's feel at 0.6 is a number to tune from
  riders. The rider's animation on all of them is the IK's with new targets, nobody has watched
  it. The rack's physics body is a base-game plate (`plate1x1`), drawn in code, and a bike hung
  across it is placed by constants, not measured against a real car. A locked bike is welded to
  the world where it stands, so a map with moving geometry under it will move it. No unlock
  by key/code, no rack for non-bike props.

## Status update (2026-10-08): the tandem on a real server

`tandem_rides` is no longer `wip` and passes on VPhysics (gm_flatgrass, 10/10 on a private
server). CI a326eb6 had read "alone 179, both 157, D does not turn it"; the drive and the
steering were never the problem:

- **The case:** the stoker bot left over from the previous run was put down on top of the new
  tandem by `ExitVehicle` and shoved it to 150 u/s before the "alone" launch. It now gets off
  first, and both launches start from a standstill: alone ~90 u/s after 2 s, both ~155.
- **The vehicle:** a pedalling stoker (141,700 of wheel torque) out-pushed the captain's
  95,000 rear brake, so a stop rolled 870 units and the turn ran off the test ground. Now the
  captain's brake cuts the stoker's push (`BMX.Tandem.Push`, a timing chain's worth of
  "the captain calls the stop") and the tandem's only brake is 150,000, sized for two riders.
  Offline: `tests/test_oddbikes.lua` "the captain's brake stops the stoker's push".
- The captain's D turns it about 112 degrees in 1.5 s at 110 u/s with both aboard.
