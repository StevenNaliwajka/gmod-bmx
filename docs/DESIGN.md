# Design

Why this addon is built the way it is, and what is deliberately not built yet.

---

## 1. The decision that shapes everything: not a Source vehicle

Garry's Mod gives you three ways to make something driveable, and two of them
are dead ends for a bicycle.

**`prop_vehicle_jeep` plus a vehicle script.** This is Source's own vehicle
system: a four-wheel VPhysics controller configured by a `.txt` in
`scripts/vehicles/`. The wheel count is structural, not a parameter. It has no
representation of lean, and its controller actively resists torque applied from
Lua because it is continuously correcting the chassis toward its own solution.
Every motorbike in GMod built this way is a four-wheeler with two wheels made
invisible, which is exactly why none of them feel like bikes.

**Real two-wheel physics.** Two thin cylinders resting on a plane at Source's
physics rate jitter, tunnel through displacement seams, and catch on brush
edges. The contact patch is small, the mass above it is high, and VPhysics is
not a solver you can tune your way out of that with.

**A scripted entity with a Lua-driven simulation.** What this addon does. One
box hull for world collision, two raycast wheels, and the whole vehicle model
written out where it can be read and changed. It is more work up front and it is
the only one of the three that can produce the target behaviour.

## 2. Raycast wheels

A wheel here is a downward trace from an axle mount, plus a force applied at the
contact point. It has no collision hull at all, so it cannot tunnel or jitter,
and its behaviour is a function you can read rather than a solver you can only
observe. Same model as Bullet's `btRaycastVehicle` and Unity's `WheelCollider`.

Per wheel, per substep:

1. Trace down `restLength + radius` from the mount.
2. Suspension: `N = k*compression + c*d(compression)/dt`, clamped to `N >= 0`
   because a wheel can push and never pull. A separate, much stiffer bump-stop
   term past `restLength` keeps a hard landing from putting the hull through the
   floor, which VPhysics resolves by launching the bike.
3. Tyre forces from **slip velocity**, not slip ratio.
4. Clamp both into a friction circle of radius `grip * N`.
5. Integrate the wheel's own `omega` against the drive torque, the brake, and
   the reaction from the tyre force.

### Why slip velocity and not slip ratio

The classic tyre model uses slip *ratio*, which divides by ground speed. A BMX
spends a great deal of its life at or near zero ground speed: track stands,
rolling out of a stall, landing a stoppie. Slip ratio is singular there and
every implementation papers over it with a low-speed special case that has its
own tuning and its own failure modes.

Slip velocity (`omega*radius - v_forward`) has no singularity, is stable from
zero to top speed with no special-casing, and produces the same behaviour
everywhere it matters. The stiffness constant changes units; nothing else does.

### What comes free from the friction circle

Because both tyre forces are clamped into one circle, several behaviours that
would otherwise need explicit code fall out:

- Grabbing the brake mid-corner washes out the front, because braking and
  cornering spend the same budget.
- Locking the rear (`omega` driven to zero by the brake) makes `slipLong`
  become `-v_forward`, which saturates immediately: a skid.
- Landing sideways saturates laterally and the bike slides out.

Saturation per wheel is on the tuning overlay for exactly this reason. When the
bike does something surprising, that number usually explains it.

## 3. Steering is an output

This is the part that makes it feel like GTA rather than like a prop with
wheels.

A real bicycle does not turn because the bars moved. It turns because it is
leaning, and the bars moved to sustain the lean. Binding `A`/`D` to a steer
angle inverts cause and effect, and no amount of tuning fixes a model that is
backwards.

So the chain is:

```
rider input  ->  target roll angle
                 PD controller drives actual roll toward it
                 steer angle DERIVED from the roll that resulted
                 steered front tyre generates lateral force
                 bike yaws, centripetal acceleration appears
                 that acceleration is what holds the lean up
```

The derivation is the steady-state cornering relation plus the bicycle model:

```
tan(roll)  = v^2 / (g * R)          leaning balances centripetal acceleration
R          = wheelbase / tan(steer) turn radius from steer angle
=> tan(steer) = wheelbase * g * tan(roll) / v^2
```

As `v` falls this saturates to `maxSteer`, which is not a failure mode: slow
riding genuinely does need large steering inputs. Below `walkSpeed` it blends
into direct steering so a rider can paddle the bike around on the spot, where
there is no lean-driven cornering to derive from.

### The assist, and its ceiling

The PD holding roll on target is an assist. It is capped at
`Balance.maxAssistAccel` and its authority ramps in with speed, both
deliberately:

- **Below `fadeInLow` there is no assist at all**, so a stationary bike falls
  over. A bike that balances itself at walking pace reads as a hovering prop.
- **The cap is finite**, so a bad landing can beat it. With no cap, no landing
  can ever go wrong because the controller simply undoes it, and the game has no
  failure state.

The cap is sized against the gravity torque it has to beat at full lean
(`m * g * h * sin(maxLean)`), with about 1.4x margin. That derivation is written
out in `sh_config.lua` next to the number, so a future tuner knows which end of
the range they are working in.

The centre of mass **height** is load-bearing here and is not a cosmetic
detail: it sets that gravity torque, and it sets how readily rear drive force
lifts the front. Dropping it toward the axle is the classic arcade cheat. It
makes the bike almost untippable and it also kills wheelies stone dead.

## 4. Air

Air control is far more authoritative than anything on the ground. That is not a
cheat: a rider really can whip an 11 kg bike around underneath 75 kg of
themselves, and it is the entire reason the sport exists.

The one honest cheat is `Air.autoLevel`: a weak pull back toward upright,
applied to roll only and only while descending. Without it every jump ends in a
crash for a casual player. It never touches pitch, because levelling pitch would
fight every intentional flip. `bmx_autolevel 0` for the purist version.

Air mode does not engage the instant both wheels lose contact. A bump in the
road unloads both wheels for a substep or two, and switching control modes there
makes the bike twitch on rough ground and scores phantom tricks for riding over
a kerb. `Air.engageDelay` is that debounce.

### Tricks

Rotation is integrated about each **local** axis while airborne. The angle tells
you where the bike is; only the integral tells you how it got there, which is
the difference between a backflip and a bike that happens to be upside down.

Landing is judged after scoring, so a trick that ends in a crash is still
reported. It just does not pay.

## 5. Networking

Server-authoritative. GMod exposes no vehicle prediction API, so a custom
vehicle cannot be predicted the way a player's movement is. simfphys and LVS
have the same constraint. High-ping riders will feel it.

The mitigations here are honest ones: client-side camera smoothing, and input
read from the usercmd rather than from a second `net` channel. What is
deliberately *not* attempted is local prediction, which in the absence of engine
support means reconciling two divergent physics simulations and produces
rubber-banding worse than the latency it hides.

What actually crosses the wire:

- **Usercmds** (free, already sent every tick, already ordered, already
  rate-limited, and already carrying analog axes for gamepads). Read in
  `StartCommand` server-side. A `net` message for lean would only add a second,
  unordered, unvalidated channel saying the same thing.
- **A handful of networked vars at 20 Hz**: speed, grounded, steer, stamina,
  cadence, hop charge, score.
- **Nothing for wheel position.** The client re-runs the same suspension trace
  and places the wheel from the result. Two traces per bike per frame beats
  networking two floats at physics rate, and the world geometry is identical on
  both ends so the answer is exactly right.
- **Steer is networked** and cannot be derived, because it is an *output* of the
  balance controller rather than a function of the rider's key.
- **The debug stream** only exists while a rider sets `bmx_debug 1`, only goes
  to that rider, and is sent unreliable.

## 6. Two implementation details worth knowing

**`PhysicsSimulate`, not `Think`.** It is the only hook in GMod called once per
VPhysics substep with that substep's `dt`. `Think` runs at frame rate with a
`dt` that varies with how many props someone just spawned, and a PD controller
tuned at 60 fps oscillates at 200. Forces are applied inside it via
`ApplyForceOffset`, so `SIM_NOTHING` is the correct return: it means "not
overriding your integration, only adding to it".

**Torque via a force couple, not `ApplyTorqueCenter`.** That function takes an
`Angle` whose component-to-axis mapping is documented inconsistently and has
bitten enough addons to be worth avoiding. `BMX.ApplyTorque` instead applies two
equal and opposite forces at a lever arm perpendicular to the chosen axis. The
linear components cancel exactly, leaving `torque = 2*r*F` about that axis and
nothing else. Slightly more expensive, completely unambiguous, and it can be
checked on paper when the bike misbehaves.

Similarly, angular velocity is estimated from successive orientations rather
than read from `PhysObj:GetAngleVelocity`:

```
w ~= 1/2 * (f_prev x f_now + r_prev x r_now + u_prev x u_now) / dt
```

Exact in the limit, accurate to well under a degree at substep sizes, three
cross products, and no ambiguity about what the components mean.

## 6b. Nine traps, all found by running it

Every one of these produced correct-looking code, no error, and a symptom
several steps from its cause. They are written down because none of them is
guessable and all of them cost real time. The first six are engine traps; the
last two are traps in the physics and in the harness, and they are the ones that
made six of twelve cases fail while pointing at five different subsystems.

**1. `PhysObj:SetMassCenter` does not exist.** `GetMassCenter` does; there is no
setter. Calling it throws *inside* `Initialize`, which silently abandons the
rest of the function. The entity comes out with correct physics and no seat, and
looks completely normal until someone presses E. Place the centre of mass by
choosing the hull: VPhysics puts it at the box's geometric centre.

**2. `ENT:PhysicsSimulate` is the motion-controller callback.** Defining the
method does nothing at all. Without `StartMotionController()` and
`AddToMotionController(phys)` the entire simulation is dead code: the bike falls
under stock gravity and tips over, which reads as "the balance controller is
broken" rather than "the balance controller has never executed".

**3. An empty dedicated server hibernates.** It stops running the game
simulation, so `GM:Think` never fires and any headless harness gets zero ticks
and hangs while the server reports itself perfectly healthy. `sv_hibernate_think 1`.

**4. VPhysics reports inertia in kg·m², not kg·units².** Everything else in the
engine's Lua surface is in inches. The controllers convert angular acceleration
to torque with `T = I·alpha`, so a wrong `I` scales *every* torque by the same
factor. Multiply `GetInertia()` by 39.37².

**5. The rider collides with the bike they are sitting on.** The chassis hull
stands in for the rider's body and the seat is inside it, so mounting
interpenetrates two hulls and the engine pushes them apart as hard as it takes.
Measured: a settled bike reached 88 u/s and went airborne in one frame.
`SetCustomCollisionCheck(true)` plus a `ShouldCollide` hook.

**6. GMod's RCON refuses two packet shapes.** The end-of-response sentinel every
Source RCON tutorial recommends (an empty type-0 packet from the client) is
treated as an HTTP probe, and so is any packet of exactly 26 wire bytes, which
is a 12-character command. Both drop the connection and count toward a ban.
Only relevant if you drive the server remotely, which a headless loop must.

**7. A stiffness is a timestep decision, and a clamp can hide a divergence.**
Both tyre slip stiffnesses were relaxation rates integrated explicitly, and both
were far past the point where that is stable at 66 Hz. That should have been a
NaN, which is loud. Instead the friction circle clamped the runaway every tick,
so it presented as a bounded oscillation with no error -- and because the clamp
radius is `grip*N` and `N` was oscillating in phase with the force, the clamp
RECTIFIED it. The bike made free energy: 0 to 296 u/s in two seconds, no rider,
no throttle. Anything that limits a value is also capable of hiding the fact
that the value was diverging, and of turning a symmetric oscillation into a net
force.

**8. An assumption that holds only because something else is broken comes due
the moment you fix the other thing.** The harness picked test ground by
flatness, with a note that an acceleration run travels about 1,200 units. True
at the time -- while the tyre bug held the bike to a third of its speed. With
that fixed, runs went off the edge of the flat area at 1,310 units, and four
cases started taking their measurements on a bike in free fall: lean, steering,
pitch and top speed, all reported against the controller, none of them its
fault. `st.speed` is a velocity magnitude, so a falling bike reports a top speed
that climbs forever and passes any band you give it.

**9. Which body are you talking about?** `I_pitch` from VPhysics is the
free-body pitch inertia. A bike doing a wheelie is not a free body: it pivots on
its rear contact patch, where the inertia is `I_pitch + m*d^2` = 72,574 against
11,837, a factor of 6.1. THREE separate numbers in this addon were derived
against the wrong one -- a recommendation to halve `Pitch.torque` (withdrawn),
the wheelie hold's P term, and its damping -- and each time the result looked
carefully worked out and was six times wrong. The roll axis has the twin:
`maxAssistAccel` was sized first against an invented inertia and then against a
lever arm that reached to the axle line instead of the contact patch, and both
times came out below requirement while reading as a tuning problem.

**The generalisable lesson** is in trap 5. Five separate cases were failing --
acceleration, lean, test speed, wheelies, braking -- and each read like a tuning
problem in a different subsystem. They had one cause. The measurement that found
it ignored all five subsystems and printed the bike's speed on the first frame
after mounting: 88 where it should have been 0. When several unrelated things
fail at once, look for the shared precondition, not for a common factor in the
symptoms.

## 7. Roadmap

| Phase | Deliverable | Status |
|---|---|---|
| 0 | Entity, pod seat, chassis hull, debug overlay | done |
| 1 | Raycast wheels, suspension, drive, brakes, skids | done |
| 2 | Lean PD, derived steering, balance assist | done |
| 3 | Wheelies, stoppies, bunny hop, air mode, tricks | done |
| 4 | Crash and ejection, damage, sound | done, placeholder sounds |
| 6f | Rolling, skid, freewheel and landing sound | done, base-game placeholders |
| 5 | Headless regression harness (bot rider, no client) | done |
| 6 | First live bring-up: six engine traps found and fixed | done |
| 6b | Tyre integration, drag, and a harness that measured falling bikes | done |
| 6c | Balance and pitch gains that could not meet their own spec | done |
| 6d | Per-bike physics: a bike carries its own config overrides | done |
| 6e | Duplicator, grab guards, client-file delivery | done |
| 6g | Offline suite: client half, wire format, usercmd decode, plant | done |
| 6h | Disc tyre contact, stoppie inertia, hop landing, ground tricks | done |
| 6i | Procedural bike body, kickstand, foot down, pick up a fallen bike | done |
| 6j | Base-game tyre model, rider animation, E to mount, grippy when fallen | done |
| 7 | Tuning pass with a human rider | **in progress** |
| 8 | Workshop release | icon and packer done |

Phases 0 to 6i are done. **The offline suite (192 tests) and the headless
suite (19 cases, on a real dedicated server) both pass.** The bike rides,
brakes, skids, steers from lean, hops and lands, holds a wheelie and a stoppie,
and tracks a commanded lean to within 11 degrees.

### The tyre touches down below its axle, not where the ray lands

The suspension is a ray from each mount along the chassis's own down axis,
and the contact used to be wherever that ray met the ground. On the level that
is exact. Under lean it is also right, because a thin tyre touches down inside
its own plane, and the balance feed-forward depends on that offset. Under
PITCH it is wrong: a round wheel touches directly below its axle, and the ray
hit slides r*sin(pitch) behind it. At 35 degrees the rear spring, carrying most
of the bike, pushed up about 6 units behind the tyre: roughly 290,000 of
nose-up torque, twice the gravity torque the wheelie hold balances against.
Wheelies were levered past their balance point by geometry.

`BMX.DiscContact` models the tyre as a disc in the wheel's plane and finds its
lowest point toward the ground. It reproduces the ray exactly on the level and
under pure lean and differs only under pitch. The client draws the wheels from
the same function, so they are drawn where the simulation has them.

**It has still never been ridden by a human**, so nothing is known about how it
feels; that is phase 7 and it is the only thing a harness cannot answer.

The harness in phase 5 is what makes that split workable: correctness runs
headless and continuously on a server with no graphics hardware, so the only
thing a human client is needed for is feel. See `lua/bmx/sv_test.lua` for what
it can and cannot see.

### Per-bike physics, and the option that was not on the list

A bike entry in `sh_bikes.lua` can carry a `physics` table of config overrides,
grouped exactly as `BMX.Config` is. Anything omitted comes from the base.

This section used to describe a choice between two options:

- **Thread a `cfg` table through every function** in `sv_wheel`, `sv_balance`,
  `sv_air` and `sv_physics`. Explicit, no global state, touches every signature.
- **Swap `BMX.Config` to point at the active bike's table for the duration of
  its substep.** Two lines, safe because `PhysicsStep` is never re-entrant, and
  a form of global mutation that will surprise the next reader.

There is a third that is better than both, and it was invisible until someone
listed the call sites: **every function in the simulation that needs the config
already receives the entity.** So the config does not have to be threaded from
anywhere or stashed in a global for a while -- it can travel with the bike it
belongs to. `ENT:Cfg()` resolves it, `PhysicsStep` resolves it once per substep
and passes it down the hot path, and the cold paths ask the entity directly.

That keeps the explicitness of the first option and most of the brevity of the
second, and it has a property neither has: at any point in a stack trace, the
config in scope provably belongs to the bike in scope.

**A bike with no overrides shares `BMX.Config` by reference.** No copy, no
merge, and live convar tuning reaches it for free. A bike WITH overrides gets a
merged copy, cached against `BMX.ConfigRevision`, which `ApplyConVars` bumps
only when a convar has actually moved -- so tuning still reaches every bike on
the next tick without rebuilding tables twenty times a second for nothing.

**Overrides are validated at registration**, against the real config, and a key
that does not exist is a loud error. That check is the entire reason this field
did not exist for six phases: a `physics = {}` that silently does nothing is
worse than no field at all, and the only difference between the two is whether
it validates.

Two things fell out of doing it. `init.lua` had a file-scope
`local C = BMX.Config`, which bound the base table once at LOAD time -- so an
override could never have reached the hull, the mass or the wheel mounts however
much was threaded through everything else. And a bike registered *after* load
never got an entity class at all, because the pass that derives `bmx_<id>` runs
once on a timer and anything later joined a queue that had already been drained.

## 8. Content and licensing

The stock bike ships no model at all. `cl_init.lua` draws a 20-inch BMX from
camera-facing beams and boxes: frame, fork, tall swept bars that turn with the
steer angle, seat, cranks that turn at the networked cadence, chain, pegs, and a
kickstand when parked. It is sized from the bike's own wheelbase, and the stays
and fork run to where the wheels actually are, so the drawing still shows exactly
where the simulation has its wheels: the debugging property the old placeholder
(a Hunter plate with wheel rings) was kept for. Zero content dependencies, clone
and ride.

A real model needs: a frame, a fork that steers with the front wheel, two
wheels, and cranks. `frameOffset` / `frameAngles` align it against the axle
line, which is where the entity origin sits.

**Ripped assets do not go in a public repository.** A GTA 5 BMX model, or
anything extracted from another game, is the fastest way to have the repository
taken down. Original or CC0 only, licensed separately from the code and stated
explicitly.

**That includes audio, and audio is where the temptation is worst**, because a
sound file is small, easy to extract and feels less like theft than a model.
It is not: a Workshop item with lifted game audio gets the item removed and the
account warned, and the repository behind it follows.

So the addon ships no audio either. Everything in `sh_sound.lua` is a base-game
path, which means zero content dependency, nothing to license, and not one byte
in the `.gma` -- and the suite walks every entry to prove the file is really
there, because a wrong path is silent for the player and noisy in their console.
They are placeholders, and each one records what it stands in for so replacing
it is a one-line edit rather than a guess. If real audio is ever recorded or
sourced CC0, it lands beside the model with the same rules: stated licence,
separate from the code.
