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
