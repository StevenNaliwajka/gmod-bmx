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

## Status (2026-10-07)

**Built and offline-tested; the nose manual ships OFF (`bmx_nose_manual 0`)
until it has been ridden on a real server.**

| Done when | State |
|---|---|
| Weight forward, visible in the IK | **Done.** `inp.leanFwd` (`sv_input.lua`) comes on over 1 / `Pitch.leanRate` s as `st.leanFwd`, networked as `LeanFwd` (float slot 6) and read by `cl_rider.lua`: the torso folds `RIDER.leanFwd` (24 deg) further over the bars and the thighs fold under it, the hands staying on the grips (the IK reaches them from the new shoulder). The physics side is the mass centre `Pitch.leanShift` (7 u) forward, a gravity torque of m*g*shift nose-down wherever nothing is holding the pitch (`PitchControl`). |
| Nose manual | **Done, gated.** `PitchControl` mirrors the wheelie's hold about the front contact: the same yank ramping out as the nose comes to its aim plus the same PD with the front pivot inertia, the weight shift standing in for the rider's push. It starts from a stoppie (rear at least `noseMinPitch` up) when the brake comes off with the lean held, lets go below `noseMinSpeed`, and W / S trim the aim by +-`noseTrim`. On the tests' plant it holds ~20 deg (13 / 30 under S / W) for as long as it is rolling, over 3 s, with no flip. `st.noseHold` is what `BMX.TrackManual` reads. |
| "Stoppie" and "Nose Manual" tricks | **Done.** `Stoppie` already existed; `Nose Manual` is registered in `sh_tricks.lua` (`ground`, `Tricks.noseManualPerSec` 220 a second, `noseManualMin` 1 s). A stoppie that becomes a nose manual pays the stoppie and starts the nose manual; the held manual keeps a combo open (`sv_combo.lua` reads `st.manual`) and the payout joins it. |
| LMB binding | **Done.** `LMB` + `Ctrl` brakes and leans, and the lean stays while `Ctrl` is held (so `LMB` up is "brake off, weight forward"). `bmx_lmb_mode lean` (client, userinfo, Options > Rider "Left mouse") makes `LMB` the lean and `Ctrl` + `LMB` the brake. `Ctrl` alone is the tuck, `RMB` wins over the lean, and in the air `LMB` is still the tailwhip. |
| The convar gate | **Done.** `bmx_nose_manual` (server, row in `sh_settings.lua`, default 0). With it off, leaning only shifts the weight and a stoppie ends with the brake exactly as before; nothing in `PitchControl` changes for a rider who never presses `Ctrl` + `LMB`. |

Tests: `tests/test_nose_manual.lua` (17: the key decode through the real
`StartCommand` in both modes, the IK, the hold over 2.4 s, W / S trim, the
convar gate, no nose manual from a lean alone, pay by the second, and the combo
chain through a hop). Headless: `nose_manual_holds` in `sv_test_cases.lua`
(15 mph, rear off the ground for over 2 s of the 2.6 after the brake, no flip,
pays as a Nose Manual).

Left: run `nose_manual_holds` and ride it with the convar on; if it holds, flip
the default to 1 (the setting row and `README.md` say 0). The plant's yank and
PD are the wheelie's tuned numbers, mirrored; VPhysics may want `noseYank` or
`noseAim` moved. No bot trick for it yet.
