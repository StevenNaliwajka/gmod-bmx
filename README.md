# gmod-bmx

BMX bikes for Garry's Mod, with lean-driven handling modelled on GTA 5's bikes.

Two wheels, a real tyre model, and steering that is an *output* of how far you
are leaning rather than a key you press. Wheelies, stoppies, bunny hops, air
control and flips.

**Status: live on the
[Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3814420080)**
since 2026-10-05. [CHANGELOG.md](CHANGELOG.md) says what each version added,
and which one the Workshop has. Two test suites gate every commit: an **offline suite** that
executes the addon (client half included) against a Garry's Mod shim in a
stock Lua 5.1, and a **headless suite** on a real dedicated server that seats a
bot on the bike and measures what it does. The bike rides, brakes, skids,
steers from lean, hops and lands, wheelies, stoppies, grinds, flips and scores
combos. Its feel numbers were derived and measured before anybody rode it, and
are now being tuned from what riders say. See [Tuning](docs/TUNING.md).

---

## Install

**Players:** subscribe to
[BMX Bike on the Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3814420080).
There is no content dependency beyond base Garry's Mod -- including the audio,
which is all base-game paths rather than shipped files.

**Servers:** add Workshop item `3814420080` to your server's collection
(`host_workshop_collection`), or put a checkout of this repository in
`garrysmod/addons/gmod-bmx`. There is nothing to build.

Then, in game:

```
bmx_spawn            spawn a bike where you are looking
bmx_spawn cruiser    the 24-inch cruiser (or: mini, stock)
```

or find **BMX** in the spawn menu's Entities tab. There are three bikes: the
20-inch **BMX**, the 24-inch **BMX Cruiser** (longer, heavier, faster at the
top end, slower off the line) and the 16-inch **Mini BMX** (short, light and
quick, with a low top speed). Press `E` on the bike to get on
(and `E` again to get off, beside it). Get off at a slow stop and the kickstand
goes down; get off at speed and it stays up, so the bike rolls on for a moment
and falls over. A bike that has fallen is picked up when you get on it.

Crash (or tip the bike over with you on it) and you are thrown off as a
ragdoll for a moment, then back on your feet with what you had.
`bmx_crash_ragdoll 0` (server) keeps the plain shove instead.

The rider's hands are on the grips and feet on the pedals (inverse kinematics,
so the legs follow the pedals round), and they tuck with speed, crouch for a hop
and lean with the bike. `bmx_rider_ik 0` falls back to a simple leg swing, and
`bmx_rider_anim 0` leaves the plain seated pose, if your player model's skeleton
disagrees with either.

## Controls

| Key | On the ground | In the air |
|---|---|---|
| `W` / `S` | pedal / rear brake | nose down / nose up (front flip / back flip) |
| `A` / `D` | lean, which steers you | roll |
| `RMB` hold | weight back: wheelie or manual, works under power | yaw assist (with `A`/`D`) |
| `LMB` | front brake, plus the weight shift forward that comes with it | front brake |
| `SPACE` | hold to preload, release to bunny hop | - |
| `SHIFT` | sprint (drains stamina) | - |
| `CTRL` | tuck: less drag | tuck: faster rotation |
| `K` | next paint colour, in a puff of smoke | same |
| `L` | cinematic camera on/off | same |

**Chase camera.** It eases after the bike's turns and ramps rather than being
bolted to it; `bmx_cam_smooth 0` bolts it back on. In the air, a lean key
you were already holding when the wheels left the ground does nothing until
you let go of it -- press it again to roll -- so steering up a ramp does not
throw you into a barrel roll off the lip.

**Gamepad.** A controller's left stick is read as an analog axis, so a half
stick is half throttle, half lean or half a flip, and buttons bound to the keys
above do what the keys do. `bmx_stick_deadzone` (client, default `0.1`) is how
much stick travel counts as centred: raise it if your bike creeps into a turn
with the stick let go.

**Cinematic camera.** `L` while riding (or `bmx_cinematic 1`): the camera cuts
between GTA-style external shots, trackside cameras you ride past, a low chase,
a side dolly, a front shot looking back, a wide air shot while you are airborne
and a slow orbit when you stop, with letterbox bars. A crash is filmed too: it
holds a shot on your tumbling body until you are back up. Getting off ends it.

**Colour.** Fourteen, red to pink plus white and black. `K` while riding cycles
them; hold `C` and right-click a bike for **Bike colour** to pick one; or
`bmx_color <name>` for the bike you ride or look at. Whatever colour you last
chose is the colour your next bike spawns in, and it is remembered across
sessions (it is saved to `bmx_color_default`, which you can also set directly).
A duplicator copy keeps its paint.

Tricks score on the HUD. Flips, barrel rolls and big air pay on landing (not
on a crash). A wheelie held for a second or more, or a stoppie held to a stop,
pays by the second when it ends.

Two of those are worth calling out because they are the difference between
tricks working and tricks being an accident:

- **`RMB` is weight back, not a mode.** `RMB` + `W` is a wheelie under power,
  which is how a wheelie actually works. You keep pedalling.
- **The front brake shifts your weight forward on its own.** A rider grabbing
  the front brake comes over the bars whether they meant to or not. Modelling
  that is what makes a stoppie something you can hold.
- **Lean over the bars with `Ctrl` + `LMB`.** Holding `Ctrl` as you press the
  front brake shifts your weight forward and keeps it there until `Ctrl` is let
  go. Brake hard and the rear comes up (a stoppie); let go of `LMB` with `Ctrl`
  still down and the brake is off with your weight still forward: a **nose
  manual**, rolling on the front wheel, `W` leaning further over and `S` sitting
  up. It pays by the second and chains in a combo. If you would rather have
  `LMB` lean forward (like other bike mods) set `bmx_lmb_mode lean`; then
  `Ctrl` + `LMB` brakes as well. The nose manual itself is `bmx_nose_manual 1`,
  off until it has been ridden on your server.
- **Off a vertical ramp the air helps you turn round.** Go up a quarter pipe
  (or a bowl wall) steeper than 60 degrees and tap `A` or `D` in the air: the
  bike comes round about the vertical to a half turn, scored as **Air 180**
  (worth more the higher you are), and a landing that is part way round is aimed
  back down the ramp. Hold the key and it keeps turning. Over a spine or two
  back-to-back quarter pipes, a fresh `W` press at the top carries you over onto
  the far face: a **Spine Transfer**, and your combo stays alive. Anywhere that
  is not vert, `A` and `D` are still the barrel roll. `bmx_air_assist 0` turns
  it all off.

## Server settings

Server console or `server.cfg`; all three are saved.

| Convar | Default | What it does |
|---|---|---|
| `bmx_max_per_player N` | `0` | Bikes one player may have out at once, every kind counted together. `0` is no limit of ours; `sbox_maxsents` still applies. Holds for the spawn menu and `bmx_spawn` alike. |
| `bmx_scoring 0` | `1` | No scoring at all: no points, callouts or combos, and the `BMX_TricksLanded` hook does not fire. |
| `bmx_combos 0` | `1` | Tricks still score, but chaining them pays no combo bonus. |
| `bmx_crash_ragdoll 0` | `1` | A crash shoves the rider off instead of ragdolling them. |
| `bmx_nose_manual 1` | `0` | Lets a rider holding weight forward (`Ctrl` + `LMB`) keep rolling on the front wheel after the brake comes off. Off until it has been ridden live: with it off, a stoppie ends when the brake does. |
| `bmx_air_assist 0` | `1` | No air turn, landing aim or spine transfer off vertical ramps: `A` / `D` stay the barrel roll everywhere. |

## First run

Run this once on any new server build before tuning anything:

```
bmx_selftest
```

It measures whether `PhysObj:ApplyForceCenter` takes an impulse or a force on
your build. The whole simulation scales forces by `dt` on the assumption that it
takes an impulse. If that is wrong the bike is uniformly weak or violent by a
factor of ~66 and nothing else looks broken, which is a miserable thing to
discover by feel. Expected output is `-> IMPULSE (expected)`.

Then:

```
bmx_debug 1
```

for the tuning overlay: roll versus target, assist authority, the derived steer
angle, and per-wheel load, slip and friction-circle saturation. Tuning a
controller whose state you cannot see is guesswork with extra steps.

Singleplayer is enough for nearly all of this: you are the server, so the debug
stream, the self-test and live convar tuning all work. What singleplayer cannot
show you is latency. See [docs/TESTING.md](docs/TESTING.md) for the order to
check things in, and [docs/TUNING.md](docs/TUNING.md) for what to change.

## Testing

Two suites, because each can see what the other cannot.

**Offline**, on any machine with Lua 5.1 or Docker, in about ten seconds:

```
tools/run-tests.sh            every test
tools/run-tests.sh balance    only tests whose file or name matches
```

It loads the real addon files into a server realm and a client realm against
a Garry's Mod shim (`tests/lib/gmod.lua`), so it runs the code a dedicated
server never does: the wheel drawing, the HUD, the tuning overlay, the chase
camera, the sounds, and the usercmd decode. The two realms share a net wire
that fails a read that does not match its write. A small rigid-body plant
lets it ride the bike closed-loop. It is not VPhysics, so its bands are the
headless suite's, and the headless suite is the authority on how the bike
actually behaves.

**Headless**, on a real dedicated server:

```
bmx_test          run the regression suite
bmx_test_list     list the cases
```

A dedicated server runs the whole simulation whether or not anyone is watching,
so the suite makes a bot, seats it on a bike, drives it, and asserts on the
result. **No client, no GPU, no human**, which means correctness regressions can
be caught on a headless box continuously.

It covers the force-units assumption, ride height and suspension load, the fact
that a parked bike stands on its kickstand and a fallen one is picked up by
getting on, acceleration and the cadence
ceiling, rear-brake lockup and friction-circle saturation, lean-derives-steering
in **both** directions, whether the balance PD actually holds its target, bunny
hops (and their landings), wheelies, stoppies, air mode, and crash ejection. It also covers the things a public
server finds first: that a bike survives a duplicator copy/paste with exactly
one seat, that nobody can physgun or gravgun a bike with a rider on it (and that
an empty one still picks up normally), that deleting a bike out from under its
rider does not strand them, and that a bike's per-bike physics overrides really
reach the simulation. Every case ends with a NaN check, because one NaN inside a
`PhysObj` is unrecoverable and its symptoms look nothing like its cause.

It cannot cover the client half: the camera, the HUD and the wheel drawing never
execute on a dedicated server. The offline suite covers those. Neither can tell
you the bike is fun. That needs a person on a real client, which is exactly the
split that makes the rest of it worth automating.

Results print to console and land in `data/bmx_test_results.txt`. With
`bmx_test_quit 1` the server exits when the run finishes, so CI can wait on the
process and read the file.

## How it works

The short version, with the long version in [docs/DESIGN.md](docs/DESIGN.md):

- **Not a `prop_vehicle_jeep`.** Source's vehicle system is a four-wheel
  VPhysics controller with no concept of lean, and it fights applied torque.
  Every GMod "motorbike" built on it is a four-wheeler with two wheels hidden.
- **Raycast wheels.** Two downward traces, a spring/damper, and a
  slip-velocity tyre model clamped to a friction circle. No wheel collision
  hulls, so nothing jitters, tunnels, or catches on a brush edge.
- **Steering is derived from lean.** Rider input sets a target roll angle, a PD
  controller holds it, and the front wheel's steer angle falls out of the
  steady-state cornering relation. The loop then closes through the real tyre
  model, so leaning further than your speed supports washes the front out.
- **Server-authoritative.** GMod has no vehicle prediction API. High-ping riders
  will feel it. That is a property of the engine, not a shortcut here.

## Repository layout

```
lua/autorun/bmx_init.lua      loader; the file order is a design decision
lua/bmx/sh_config.lua         every tunable number, with its derivation
lua/bmx/sh_util.lua           maths, and the force-couple torque helper
lua/bmx/sh_bikes.lua          the bike registry
lua/bmx/sv_wheel.lua          raycast wheel: suspension + tyre
lua/bmx/sv_balance.lua        lean PD, derived steering, wheelie/stoppie hold
lua/bmx/sv_air.lua            air control and trick accounting
lua/bmx/sv_physics.lua        the substep, and the order it runs in
lua/bmx/sv_input.lua          usercmd decoding
lua/bmx/sv_seat.lua           mount/dismount in every way it can happen
lua/bmx/sv_rules.lua          server settings: bike limit, scoring and combos on/off
lua/bmx/sv_debug.lua          tuning stream and the units self-test
lua/bmx/cl_view.lua           chase camera
lua/bmx/cl_hud.lua            rider HUD and tuning overlay
lua/entities/bmx_base/        the entity
tools/syntax-check.sh         parse everything with a real Lua 5.1 front end
tools/run-tests.sh            the offline suite (tests/)
tests/lib/gmod.lua            the Garry's Mod shim it runs against
```

## Adding a bike

One table in `lua/bmx/sh_bikes.lua`:

```lua
BMX.RegisterBike("tourer", {
    printName   = "Tourer",
    model       = "models/yourpack/tourer.mdl",
    frameOffset = Vector(0, 0, 4),
})
```

That registers entity class `bmx_tourer`, derived from `bmx_base`, and adds it
to the spawn menu.

The shipped **cruiser** and **mini** in `sh_bikes.lua` are worked examples of
the second form: no model and no new code, only geometry. The hull, the measured
inertia and the drawn frame follow wheelbase and radius on their own; the seat
is the one thing to scale yourself (by wheelbase / 39), and a bigger wheel
wants more suspension travel or it crank-grinds on its hull instead of its
chainring. Every headless riding case runs again on each of them.

A bike can also carry its own **physics**, as overrides on the shared config:

```lua
BMX.RegisterBike("tourer", {
    printName = "Tourer",
    physics = {
        Chassis = { mass = 94 },
        Wheel   = { radius = 12, wheelbase = 43 },
        Drive   = { crankTorque = 260000 },
    },
})
```

Anything omitted comes from the base, and a bike with no `physics` table shares
the base by reference rather than copying it. Overrides are checked against the
real config at registration, so a typo is a loud error rather than a value that
goes nowhere. Note that overriding a field which has a convar opts that bike out
of *live* tuning for that one field, because an explicit override is meant to
win.

## Contributing

Run `tools/run-tests.sh` before opening a PR. It executes the addon, so it
catches nil indexes and typo'd names as well as syntax errors, and it needs
only Lua 5.1 or Docker. Keep the addon plain Lua 5.1 (no `continue`, `!=`,
`&&`): that is what lets a stock interpreter load it. `tools/syntax-check.sh`
still parses every file, and tolerates GLua's extensions if one slips in.

`bmx_test` runs the headless regression suite on any dedicated server: no
client, no GPU, a bot for a rider. It catches regressions and it cannot tell you
the bike is fun. See [docs/TESTING.md](docs/TESTING.md).

## Docs

- [Design](docs/DESIGN.md) - why steering is an output, and nine traps found by
  running it rather than by reading it
- [Tuning](docs/TUNING.md) - the order to tune in, and the two things still open
- [Testing](docs/TESTING.md) - getting it in front of a server, and in what order
- [Publishing](docs/PUBLISHING.md) - the `.gma`, the icon, and the Workshop

## Licence and content

Code is MIT, see [LICENSE](LICENSE).

The bike ships **no model**: it is drawn in code from tubes and boxes (frame,
fork, bars, seat, cranks that turn as you pedal, chain, pegs), sized from its
own geometry. So the addon has zero content dependencies and can be cloned and
ridden immediately. A bike def can supply a real `model` instead.

**Do not add ripped assets.** A GTA 5 BMX model, or anything extracted from
another game, in a public repository is the fastest way to get it taken down.
Original or CC0 models only, licensed separately from the code and stated
explicitly.
