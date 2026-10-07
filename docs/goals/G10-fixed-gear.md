# G10 -- Fixed gear (fixie)

**Competitor:** [#10](https://github.com/luttje/gmod-bicycle/issues/10) (open,
requested).

**Us today:** our drive is freewheeling (the cranks stop when you stop
pedalling, and the `freewheel` sound plays while coasting).

## Goal

A fixie, which is the one bike where our physics model makes a gameplay
difference an animation-driven bike can't: the cranks are locked to the rear
wheel.

## Done when

- `bmx_spawn fixie`.
- **No freewheel:** crank angle = rear wheel angle × ratio, always. Coasting
  turns the rider's legs.
- **Skid stop:** S locks the legs and the rear tyre skids (it's the only
  brake, so LMB does nothing on a fixie unless `bmx_fixie_frontbrake 1`).
- **Backwards riding:** S at standstill pedals backwards and the bike rolls
  back. Fakie riding on a fixie is a real trick, and it's scored.
- **Trackstand:** at standstill with no feet down, balance by rocking the
  cranks. It's held with A/D and scored per second.

## Approach

A `drive = "fixed"` registry field, used where `sv_physics.lua` applies the
crank torque. The crank-to-wheel coupling is a stiff spring between crank angle
and wheel angle (so a hard skid can still break traction). The fakie and
trackstand states reuse the wheelie balance controller's structure.

## Tests

- Offline: crank angle tracks wheel angle while coasting.
- Headless `fixie_skid_stop`: from 15 mph, S stops it in < 8 m with a skid
  event networked.

## Risks

Low. It's a niche bike, but it's cheap after the road bike's frame shape.

## Status (2026-10-07)

Done on the offline plant, in one commit on top of G09; the headless case is
written, **not run** (no server here). Not merged, not on the Workshop.

- **`bmx_spawn fixie`**, "Fixie" in the spawn menu under Bikes. 700c wheels, a
  44-long frame, 80 kg, one gear (2.6), `input = "bike_rearonly"`.
- **No freewheel:** a new drive kind, `{ kind = "fixed" }` (`lua/bmx/sv_fixie.lua`,
  registered in `BMX.Drives`, validated in `sh_vehicles.lua`). The rider's push is the
  pedal drive's, so the stamina, sprint, climbing help and the paddle backwards are not
  written twice; it goes onto the legs, a body of its own (three wheels' inertia and a
  little drag), and the legs reach the rear wheel through a stiff spring and damper in
  wheel space, solved by backward Euler so it is stable at any step (checked down to a
  stalled server's 0.2 s). The twist while coasting is a few thousandths of a radian. The
  config's own `Drive.fixedGear = true` removes the wheel's freewheel floor. The drive
  hands the physics step a say in the rear brake (a second return value), because the
  legs' torque on the wheel is negative whenever the bike slows and that must not be
  taken for "pedalling backwards, so release the brake".
- **Coasting turns the legs and drags the bike:** 6% of its speed lost in 3 s from
  220 u/s against the BMX's 4%; the freewheel tick is silent on a fixie (`cl_sound.lua`).
- **Skid stop:** S, the rear brake, doubled (`rearBrake = 200000`; the brake is the
  rider's legs). From 15 mph it stops in **3.7 m** on the plant (the BMX's rear brake
  alone is 7.2 m), with the skid networked (`ent:GetSkidding()`).
- **LMB does nothing on the ground** (the `bike_rearonly` input map has no ground
  `brakeFront`; the usercmd decode in `sv_input.lua` reads the map's context), unless
  `bmx_fixie_frontbrake 1` (server, Options > BMX > Server > Vehicles). In the air LMB is
  still the tailwhip's key.
- **Fakie:** S at a standstill pedals backwards and the bike rolls back (to ~40 u/s),
  and riding it is the `fakie` trick, 40 a second. **Trackstand:** A or D held at a
  standstill with nothing else is `trackstand`, 25 a second after the first. Both are
  registered for every vehicle (`sh_tricks.lua`) and earned only on a fixed gear.
- **Tests:** `tests/test_fixie.lua` (17): registry and spawn, the drive kind's
  validation, the crank locked to the wheel while coasting (and a BMX with no crank
  state), the legs' drag against the BMX's, top speed, integration stability at four step
  sizes, the skid stop and its networked skid, LMB and the convar through the real
  usercmd decode, S at a standstill, the two tricks scored and not on a BMX. Headless:
  `fixie_skid_stop` (< 8 m and a networked skid, from 15 mph) and every riding case
  as `<case>@fixie`.
- **Left:** the legs' visible motion while skidding (the client draws the cranks off
  the wheel, which is locked, so they stop, correctly; nobody has watched it), the rocking
  of the cranks in a trackstand (it is scored, not animated), and tuning by feel.
