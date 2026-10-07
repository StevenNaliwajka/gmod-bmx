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
