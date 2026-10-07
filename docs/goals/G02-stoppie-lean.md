# G02 -- Stoppie and lean forward on left mouse

**Competitor:** [#2](https://github.com/luttje/gmod-bicycle/issues/2) (closed).
Holding LMB leans the rider forward. Braking while leaning pulls a stoppie, and
releasing the brake keeps rolling on the front wheel (a nose manual).

**Us today:** LMB is the front brake (`sv_input.lua`, `inp.brakeFront`), and
a hard front brake already lifts the rear into a stoppie
(`sv_physics.lua`, pitch hold, "stoppie controllable rather than an accident").
There is no rider weight shift, though, and no **nose manual**: once the
brake comes off, the stoppie ends.

## Goal

The front end gets the same depth as the back end. Weight forward, stoppie,
nose manual, and each one counts in combos.

## Done when

- Holding LMB with the brake shifts the rider's weight forward (visible in the
  IK pose, `cl_rider.lua`) and moves the centre of mass forward a set distance.
- Brake on, then brake off while still leaning, holds a **nose manual**:
  rolling on the front wheel with W/S trimming the balance, the same way the
  wheelie/manual already works on RMB.
- "Stoppie" and "Nose Manual" are tricks in `sv_combo.lua` with points per
  second, and they chain like the manual does.
- The competitor's binding (LMB = lean forward) works without breaking
  ours: LMB still brakes the front wheel. Lean forward is LMB + Ctrl, or a
  setting `bmx_lmb_mode brake|lean`.

## Approach

Copy the wheelie/manual balance controller in `sv_physics.lua` and mirror it
about the front contact patch. The pitch hold is already generic in the sign
of the target pitch. The COM shift is a per-tick offset to the force
application point, the same trick tucking uses in `sv_air.lua`.

## Tests

- Headless `nose_manual_holds`: at 15 mph, brake then release with lean
  held. The rear wheel is off the ground for > 2 s, and the bike doesn't flip.
- Offline: combo awards "Nose Manual" and chains it into a hop.

## Risks

Medium. It touches the pitch controller every rider uses. Gate it behind a
convar until it's been ridden.
