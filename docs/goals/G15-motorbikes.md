# G15 -- Motorbikes: dirt bike, then scooter-moped

**Competitor:** [#15](https://github.com/luttje/gmod-bicycle/issues/15) (open):
"Technically could be supported": a Honda dirt bike, a classic motorbike,
and a Piaggio moped "that has pedals to start it". One commenter: "people
should totally fund the motorbike". Another: "need bike style trials HD".

**Us today:** nothing motorised.

## Goal

A **dirt bike** that does Trials HD / freestyle motocross (FMX). It's the
largest single audience on the competitor's comments that isn't a skateboard,
and our physics is a far better base for it than an animation rig: throttle
wheelies, clutch, rear-wheel spin and suspension compression are all
physics.

## Done when

- `bmx_spawn dirtbike`. Engine torque curve and 4-5 gears (shared with G09's
  gear model), throttle W, brakes S/LMB, clutch Shift (a clutch pop = a
  wheelie).
- Long-travel suspension with a visible compression, big jumps land.
- **Rider lean** (Ctrl/Space or the mouse) moves the weight fore/aft. That's
  the core Trials mechanic.
- **FMX tricks:** superman, heel clicker, cliffhanger, backflip. They go
  through the same trick and combo system (G17's style-trick framework
  carries over).
- **Trials mode:** a checkpoint/timer entity (G26) and fault counting on
  dabs (foot down).
- Engine sound from a base-game placeholder (pitch by rpm), until a
  CC0/CC-BY sound is sourced under the licence rule.
- Moped (Piaggio-style): pedal-start for the first few metres, then the engine
  takes over, as they described. It comes after the dirt bike.

## Approach

All of it is on G22, using the throttle drive from G14. The rider lean is a COM
offset, as in G02. Gears and clutch are a small drivetrain model: the engine
inertia is coupled to the rear wheel through the clutch's slip.

## Tests

- Offline: torque curve, shift points, clutch slip.
- Headless `dirtbike_wheelie_on_clutch_pop`, `dirtbike_lands_big_jump`.

## Risks

Scope creep: a dirt bike is a whole game. Ship the riding first, then FMX
tricks, then the Trials mode.

## Status (2026-10-07)

Riding, FMX poses and the moped are built and tested on the offline plant; the headless cases
`dirtbike_wheelie_on_clutch_pop` and `dirtbike_lands_big_jump` are written, **not run**. Not on the Workshop.

- **`bmx_spawn dirtbike`**: drive kind `engine` (`sh_motor.lua`): torque curve (peak 7500 rpm), idle governor,
  rev limiter, engine braking, five gears through the road bike's gear model (a ratio is wheel revs per engine
  rev), shifted with `[` `]` / wheel. Top gear's redline ~688 u/s (2.2x BMX). `ShiftPoint` gives where the next
  gear pulls harder (tested rising, in the power band).
- **Clutch on SHIFT** (`moto` input map, `inp.clutch`): three states, open / locked / slipping (`M.EngineStep`);
  a centrifugal bite means no creep and no stall. Locked, the wheel carries the engine's inertia
  (`sv_wheel.lua` `extraInertia`). A pop (lever out, throttle open, revs high) lifts the front 19-30 degrees for
  0.4-0.7 s on the plant; the same throttle without it does not; RMB holds it.
- **Long travel** (restLength 12 vs 8, spring/damper scaled by mass); a 250 u drop lands, using its travel.
- **Rider lean**: `Pitch.leanShift` 14 (BMX 7) and `leanRate` 8 on the existing COM offset; tested as more
  front load.
- **FMX**: `heel_clicker` (Alt+A/D) and `cliffhanger` (Alt+S) via `BMX.RegisterTrick`, decoded for family
  `moto` only; superman (Alt+W+S) is the existing one; backflip lands and pays on the dirt bike. IK rows
  in `cl_rider`'s table via `cl_motor.lua`, unseen in game.
- **Moped**: pedal drive until 4 m, then the engine catches (~45.8 km/h top); cold again when the rider gets off.
- **Sound**: `engine` placeholder loop pitched by rpm.
- **Out of scope / left**: Trials mode, checkpoints and dab/fault counting belong to the game-mode repo
  (gmod-bmx-mode); a classic motorbike; real models (G20); tuning by feel; the headless cases have not met VPhysics
  (the clutch/wheel coupling in particular is a plant result).

## Status update (2026-10-08): the big jump on a real server

`dirtbike_lands_big_jump` is no longer `wip` and passes on VPhysics (gm_flatgrass, 10/10 on a
private server). The "2.9 of 12 units" CI 2649522 read was the measurement, not the spring: air
mode ends on the very tick a wheel touches, and the case stopped sampling there, at the static
sag. Read through the settle, a 250-unit drop takes 11.6 of the 12 units (the landing soak's
250 u/s into the travel, the bump stop not reached), lands on both wheels, roll 0, rider aboard.
No suspension numbers changed. `dirtbike_wheelie_on_clutch_pop` was already running.
