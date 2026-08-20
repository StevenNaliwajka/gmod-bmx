# Tuning

Tuning is most of the remaining work. This is the order to do it in and the
symptom-to-cause table for when something feels wrong.

---

## Before you change a single number

```
bmx_selftest
```

Confirms `PhysObj:ApplyForceCenter` takes an impulse on this build. Every force
in the addon is scaled by `dt` on that assumption. If it is wrong the bike is
uniformly weak or violent by a factor of about 66, nothing crashes, and you will
spend an evening retuning grip and crank torque to compensate for a units error.
Expected: `-> IMPULSE (expected)`.

```
bmx_debug 1
```

Turns on the tuning overlay. Tune with it open. The three lines that matter
most:

| Line | Read it as |
|---|---|
| `roll / target` | A persistent gap means the assist is **out of authority**, not mistuned. Raising `bmx_lean_kp` will not help; raising `maxAssistAccel` might, or the bike is simply leaning further than its speed can support and that is correct. |
| `authority` | The speed ramp. Below about 0.2 the bike is on its own. If it falls over at a speed where it should not, this is why. |
| `saturation` | 1.00 means that tyre's friction circle is full. Any more braking costs cornering and vice versa. This is what explains a washed-out front end. |

Everything is a replicated convar, so changes apply on the next tick with no
respawn. When a session lands on something good:

```
bmx_dump_config
```

prints the live values in a form you can paste back into `sh_config.lua`.

## The order

Tune in this order. Each stage depends on the one above it being settled, and
tuning them out of order means retuning everything twice.

### 1. Suspension: `bmx_spring`, `bmx_damper`

Symptom to fix: the bike buzzes, sinks, or bounces on flat ground.

The defaults are sized so each wheel carries `m*g/2` at about 3 units of sag out
of 6 units of travel. That travel is **rider compliance**, not a fork: legs and
arms are the suspension on a BMX. Check `compression` on the overlay while
parked. It should sit near 3 and be roughly equal front to rear; a large
front/rear imbalance means the bike is sitting nose-high and will wheelie under
power instead of accelerating.

**The spring rate is bounded by the timestep, not just by taste.** The frequency
the integrator sees is `sqrt(k/m_eff)`, and `m_eff` at the contact patch is
about 20 kg rather than the 43 kg per-wheel share, because the patch sits ~21
units from the centre of mass and pushing on it mostly pitches the bike. Keep
`w*dt` under about 0.4 at your tickrate. At the old k of 43000 it was 0.71 and
the suspension pumped energy in through the pitch coupling until the bike was
thrown into the sky. If you raise the spring, check against the EFFECTIVE mass.

Damper too low: bouncing. Too high: the bike feels welded to the ground and
loses its wheels over crests. It cannot destabilise the simulation at any value
(see the effective-mass clamp in `sv_wheel.lua`), so this is purely a feel knob.

### 2. Drive: `bmx_crank`

Symptom to fix: acceleration and top speed.

Top speed on the flat is set by **cadence**, not by drag. Watch the cadence bar:
if it pins at 1.00 and you want more speed, raise `Drive.maxCadence` or
`gearRatio`, not `bmx_crank`. `bmx_crank` sets how hard it pulls off the line.

Default is 300000, which is roughly 150 Nm at the crank scaled up for Source's
1.55x gravity. If a standing start feels like a shopping trolley, this is the
number.

### 3. Grip: `bmx_grip`

Symptom to fix: how easily the bike slides.

Watch `saturation`. If you can never break traction under braking, grip is too
high. If the rear steps out under gentle pedalling, too low. Default 1.35.

Grip interacts with everything downstream, which is why it comes before the
balance controller: retuning grip afterward invalidates the lean tuning.

### 4. Balance: `bmx_lean_kp`, `bmx_lean_kd`, `bmx_max_lean`

This is the stage that decides whether it feels like a bike. Budget real time
for it.

`leanKd` should be near `2*sqrt(leanKp)` for critical damping. A little under
feels alive; a lot under oscillates and reads as twitchy. Defaults are 26 and
9.0 against a critical value of 10.2, so slightly underdamped on purpose.

| Symptom | Cause | Fix |
|---|---|---|
| Sluggish to change direction | Kp too low, or `LEAN_RATE` in `sv_input.lua` too slow | raise Kp first |
| Oscillates, wobbles at speed | Kd too low for the Kp | raise Kd |
| Feels like it is on rails, no sense of falling | `maxAssistAccel` too high, or the mass centre is too low | lower the cap before touching the gains |
| Falls over at moderate speed | `fadeInLow` too high | lower it, or check `authority` on the overlay |
| Corners are too tight or too wide | this is `maxLean` and `maxSteer`, not the gains | `bmx_max_lean` (degrees) |

The single most common mistake is fixing a *steering* complaint with a *balance*
gain. Steering is derived from lean, so a bike that will not turn tight enough
usually needs more lean, not more Kp.

### 5. Pitch: `bmx_pitch`

Wheelies and stoppies. `Pitch.torque` is the rider's weight shift;
`Pitch.holdKp`/`holdKd` are the hold assist that makes a wheelie last longer
than 0.4 seconds.

`holdMax` is the ceiling on the assist. Past it you are looping out and the
assist stops, which is what keeps a wheelie something you can blow. Raising it
toward 90 degrees makes wheelies unloseable.

### 6. Air: `bmx_air_pitch`, `bmx_air_roll`, `bmx_autolevel`

Terminal rotation rate is `accel / Air.damping`. Default is 15/1.5 = 10 rad/s,
about 1.6 revolutions per second, so a backflip takes roughly 0.6 seconds. Tune
against a jump you can actually reach on your test map.

`bmx_autolevel 0` removes the descending-only roll assist. Do this once to feel
how much of the forgiveness is coming from it, then set it where you want the
difficulty.

### 7. Hop: `bmx_hop`

`popSpeed` 265 u/s against 600 u/s^2 gravity is about 56 units of air, roughly
1.4 m. A very good rider hops about 1 m. Tune against the obstacle heights on
your map, not against realism.

## Test map

Anything works, but the tuning goes much faster with a map that has, in this
order of usefulness:

1. A long flat straight, for top speed and for the suspension check.
2. A wide flat area, for the balance stage. You need room to fall over.
3. A single kicker, for the air stage. One repeatable jump beats a skate park.
4. A gentle bank or quarter-pipe, to check that roll measured against the ground
   normal actually works and the controller does not fight the transition.

`gm_flatgrass` covers 1 and 2 and ships with the game.

## Known state, 2026-08-20

The headless suite passes 7-8 of 12 on a real server. `forces` and `torque` both
pass, which means the linear and rotational force paths are calibrated exactly:
a commanded impulse and a commanded angular acceleration each produce what they
say. Suspension, braking, hops, air rotation and crashes all behave.

**The open problem is the static pitch balance, and everything else follows from
it.** At rest the front wheel carries ~21% of the weight where the geometry says
45% (front compression 0.91 against a rear 3.36). A lightly loaded front wheel
resists far less pitch torque than it should, so full throttle produces a
violent wheelie (measured 74 degrees of pitch) instead of acceleration, the rear
tyre spends its time either unloaded or spinning up, and the bike never reaches
the speed the lean cases need. Four of the five remaining failures are
downstream of that one fact.

Start there. Useful next measurements: the settled front/rear load split with a
rider aboard, whether the bike sits nose-high at equilibrium, and whether
`Pitch.torque` (1,050,000 against a real I_pitch of 11,837, so ~89 rad/s^2)
should be roughly halved.

## Known-untuned

Everything below the level of "it behaves correctly". v0.1.0 has never been
ridden by a human. The numbers in `sh_config.lua` are
derived from real BMX figures and scaled for Source's gravity, with the
derivation written next to each one so you know which are physics and which are
taste. Expect to change most of the taste ones.

The values most likely to be wrong on first contact:

- `Drive.crankTorque` and `maxCadence`: the gravity scaling is a guess.
- `Balance.leanKp` / `leanKd`: PD gains chosen analytically, never felt.
- `Wheel.longStiffness` / `latStiffness`: the slip-velocity stiffnesses have no
  real-world reference to derive from at all, unlike grip and load.
- `Crash.maxLandAngle`: 52 degrees is a guess about where a landing stops being
  a landing.
