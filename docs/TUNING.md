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
| `authority` | The lean assist's speed ramp. Below it the kickstand or the rider's foot (`C.Stand`) holds the bike instead; the two share the band in between. |
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

Two switches sit beside grip, both on the wheel (docs/DESIGN.md, "Two things a
ray and a slip velocity cannot do"). `bmx_wheel_stiction` (default 1) pins a
locked or parked wheel's patch below `Wheel.stickSpeed`, so a held bike does
not creep on a slope; it only acts on a wheel that is not rolling. The anchor
lets go at `grip*N`, so raising `bmx_grip` raises the slope a bike holds on.
`bmx_wheel_sweep` (default **0**) probes the front of the tyre for ramps, curbs
and walls; turn it on to ride it, and watch the cost with 20 bikes out.

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

Weight forward and the nose manual (`bmx_nose_manual`, off by default):
`Pitch.leanShift` (units the mass centre moves forward, a gravity torque of
m*g*shift), `noseAim` / `noseTrim` (where it aims, and W / S's share), `noseYank`
(the yank that carries it, as a share of `torque`), `noseMinPitch` and
`noseMinSpeed` (when it starts and lets go). Like the wheelie's, the hold settles
short of its aim, so tune by the pitch it reaches, not the number written.

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

Off a vert wall (`Air.vertAngle`, 60 degrees, left going mostly up) A/D turn
the bike about the ramp face's normal instead (an Air 180): `Air.vertYawRate` is
how fast, `vertKp` and `vertKd` the PD that settles it on a half turn, `vertReturn`
how hard it is pulled back in over the face, `vertDrop*` the drop back in,
`vertAimKp`/`vertAimMax` the landing aim and `vertLandKp/Kd` squaring it up on the
face after, `spine*` the spine transfer. `bmx_air_assist 0` removes all of it.

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
2. A wide flat area, for the balance stage. You need room to lean and turn.
3. A single kicker, for the air stage. One repeatable jump beats a skate park.
4. A gentle bank or quarter-pipe, to check that roll measured against the ground
   normal actually works and the controller does not fight the transition.

`gm_flatgrass` covers 1 and 2 and ships with the game.

## Known state, 2026-08-26

**The headless suite passes 12 of 12 on a real server**, repeatably. The bike
rides, brakes, skids, steers from lean, hops, holds a wheelie at 34-45 degrees
with the rear wheel down 86-91% of the hold, and tracks a commanded lean to
within 11 degrees of 25.

It has still **never been ridden by a human**, so nothing here is known about
how it feels. Every number below is derived or measured, not played.

### The two things that were wrong, and how they hid

Both of the last cases to fall were controller gains that could not meet the
spec written next to them, and in both cases the surrounding physics had an
error that made the gain look reasonable.

**`leanKp` was 26 where the spec needs 182.** With the feed-forward cancelling
the toppling torque, the lateral tyre force's righting torque is left unopposed
and the PD holds the lean against it with error alone. The steady state is
exactly `Kp*(target - roll) = topple(roll)`. Solve it:

| Kp | predicted shortfall | measured |
|---|---|---|
| 26 | 21.8 deg | 22.4 |
| 182 | 12.0 (the threshold) | |
| 220 | 10.8 | 11.0 |

So 26 was never an aggressive-versus-relaxed choice; it was a value that could
not hold the lean it was asked for at any speed, however long you waited. Four
separate restructurings of the feed-forward were tried first, and all of them
were working on the wrong term.

**The toppling lever arm went to the axle line, not the contact patch.**
`massCenterExpected.z` is 20, measured from the chassis origin which sits on the
axle line; the patch is a further `Wheel.radius` down, so the arm is 30. That
understated gravity's torque by a third *and* under-sized `maxAssistAccel`,
whose own derivation used the same 20 and produced 74 rad/s² for a requirement
that is really 111 -- so a ceiling of 110 looked like a comfortable 1.5x margin
while sitting *below* the requirement at full lean.

**The wheelie was three faults stacked.** `holdMax` was both the PD's target and
its give-up ceiling, at 48 degrees against a balance point of `atan(17.5/20)` =
41.2, so the assist aimed past the point where gravity stops resisting a wheelie
and starts driving it. The direct weight shift was applied unconditionally on
top of the hold, so a constant 1,050,000 shoved while the PD tried to settle.
And `holdKd` was zeta 0.53 against the effective inertia about the rear contact,
so the nose overshot its equilibrium and went through the balance point.

### The lesson that cost the most

`I_pitch + m*d²` = 72,574, not `I_pitch` = 11,837. **Three separate numbers in
this addon were derived against the free-body pitch inertia for a bike that
pivots on its rear contact patch**, each time producing a figure that looked
carefully worked out and was 6.1x wrong: an old note recommending `Pitch.torque`
be halved (withdrawn), the wheelie hold's P term, and its damping. If you are
sizing anything about pitch, check which body you are talking about first.

The roll axis has the twin of it: `maxAssistAccel` was first derived against an
invented inertia, then against the wrong lever arm. Both times the number was
below requirement and both times it read as a tuning problem.

### What a rider will probably want to move first

- `leanKp` 220 / `leanKd` 27. The floor is ~182; above that it is taste, and
  this is a much stiffer assist than the 26 it replaces. Expect opinions.
- `Pitch.holdAim` 0.82 of the balance point. Where a wheelie sits.
- `Wheel.grip` 1.35 and the two slip stiffnesses, which have no real-world
  reference to derive from.

### Added with the offline suite, all feel numbers

- `Air.pitchLevelKp` 12 / `pitchLevelKd` 3. Takes a bunny hop's own nose-up
  kick back out in the air, only with no pitch input and not mid-flip. Without
  it a plain hop landed at 50+ degrees on the hull. `bmx_autolevel 0` turns it
  off along with the roll levelling.
- `Drive.staminaRecover` 30. Once sprint empties the tank, it stays off until
  this much has come back.
- `Stand.*`. The kickstand lean for a parked bike (`standLean`), how far A/D lean
  a ridden bike at a standstill (`footLean`), and past what roll it counts as
  fallen (`maxRoll`).
- `Tricks.*`. How long a wheelie (`manualMin`) or stoppie (`stoppieMin`) must
  be held to score, and what it pays per second.

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

## The cruiser and the mini (1.1.0)

Both are the stock bike with geometry overrides in `sh_bikes.lua`, and pass
every headless riding case against the stock bike's bands. Like the stock
bike in 1.0.0, nobody has ridden them yet, so these are the numbers to move
first:

- **Cruiser** (`radius 12`, `wheelbase 43`, `mass 94`, `restLength 10`,
  `crankTorque 340000`). The torque was raised from the stock 300000 only far
  enough that it still climbs; if it feels sluggish, that is the number.
  `restLength` is 10 for the crank grind's sake (see the comment there), so a
  softer or harder landing is `spring` / `damper`, not travel.
- **Mini** (`radius 8`, `wheelbase 34`, `mass 82`). Everything else is stock,
  including `leanKp`, which on a shorter bike may feel twitchy: try a per-bike
  `Balance = { leanKd = ... }` before touching the base.

A per-bike override of a field that has a convar is opted out of live tuning
for that field (see sh_config.lua), so tune these by editing `sh_bikes.lua`.

## Measuring input-to-visible-lean latency (G30)

The number that decides whether the bike feels tight on a server is the time
from a key going down to the bike on screen visibly leaning. It is ping plus
the interpolation delay plus the server's own response, and it is measured with
a client command, `bmx_latency_probe [trials]`, which needs a live server.

**Method.** Both ends are timestamps on the one client clock (`SysTime`), so
there is no clock sync to get wrong, and it holds under `net_fakelag` (which
delays packets, not the client's clock). It is `BMX.Predict.ProbeFeed`
(`sh_predict.lua`), tested offline on synthetic timelines.

1. On the server, flat ground, a stock bike at the tuning tickrate (record it,
   see docs/TESTING.md). In the client console set the lag: `net_fakelag 0`,
   then `50`, `100`, `150` in turn (it is the one-way delay the client adds, so
   the displayed ping is about twice it plus the real one). Note `ping` in the
   scoreboard each time.
2. Get on the bike, reach a steady 250-300 u/s straight and level, hands off.
3. `bmx_latency_probe 8`. It prints "ready". Tap D and let go, about two seconds
   apart, eight times. Each tap prints its latency in chat.
4. A trial starts at the first usercmd with a non-zero side axis and ends at the
   first frame the DRAWN roll has moved 1.5 degrees from its baseline in the
   pressed direction. The next trial waits for the key to be up and the roll to
   be still, so one tail never starts the next.
5. The report is min / median / max in ms plus `ping`, `net_fakelag` and
   `bmx_predict`. With `bmx_predict 1` it prints the networked lean and the
   drawn (predicted) lean side by side. Repeat for each row below, once with
   `bmx_predict 0` and once with `1`.

Read the median; a max far above it is a dropped packet or a hitch, not the
bike. Do not tune `leanKp` to hide a number from this table: it measures the
network, and a stiffer controller only moves the part after it.

| net_fakelag | ping shown | networked median (ms) | predicted median (ms) | min | max | date / tickrate |
|---|---|---|---|---|---|---|
| 0 (baseline) | | | | | | |
| 50 | | | | | | |
| 100 | | | | | | |
| 150 | | | | | | |

**Expected, not measured:** the networked column should sit near
`ping + cl_interp (0.1 s) + about one server tick + the controller's own rise`,
and the predicted column should drop by roughly `ping + cl_interp` from it. If
it does not, the prediction's horizon is wrong: `P.Horizon` in `sh_predict.lua`.

The prediction (`bmx_predict`, default 0) and the lag compensation
(`bmx_lagcomp`, default 0) both ship OFF until riders say they are better. See
docs/DESIGN.md section 5.
