# gmod-bmx

BMX bikes for Garry's Mod, with lean-driven handling modelled on GTA 5's bikes.

Two wheels, a real tyre model, and steering that is an *output* of how far you
are leaning rather than a key you press. Wheelies, stoppies, bunny hops, air
control and flips.

**Status: v0.1.0, pre-alpha.** The simulation is complete and parses clean, but
it has not yet been ridden on a live server. Numbers are derived-from-reality
starting points, not playtested ones. See [Tuning](docs/TUNING.md).

---

## Install

Clone straight into your addons folder. There is nothing to build and no
content dependency beyond base Garry's Mod.

```
cd garrysmod/addons
git clone https://github.com/<you>/gmod-bmx.git
```

Then, in game:

```
bmx_spawn            spawn a bike where you are looking
```

or find **BMX** in the spawn menu's Entities tab. Press `E` to get on.

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

Two of those are worth calling out because they are the difference between
tricks working and tricks being an accident:

- **`RMB` is weight back, not a mode.** `RMB` + `W` is a wheelie under power,
  which is how a wheelie actually works. You keep pedalling.
- **The front brake shifts your weight forward on its own.** A rider grabbing
  the front brake comes over the bars whether they meant to or not. Modelling
  that is what makes a stoppie something you can hold.

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

## Headless testing

```
bmx_test          run the regression suite
bmx_test_list     list the cases
```

A dedicated server runs the whole simulation whether or not anyone is watching,
so the suite makes a bot, seats it on a bike, drives it, and asserts on the
result. **No client, no GPU, no human**, which means correctness regressions can
be caught on a headless box continuously.

It covers the force-units assumption, ride height and suspension load, the fact
that a riderless bike is *supposed* to fall over, acceleration and the cadence
ceiling, rear-brake lockup and friction-circle saturation, lean-derives-steering
in **both** directions, whether the balance PD actually holds its target, bunny
hops, wheelies, air mode, and crash ejection. Every case ends with a NaN check,
because one NaN inside a `PhysObj` is unrecoverable and its symptoms look
nothing like its cause.

It cannot cover the client half: the camera, the HUD and the wheel drawing never
execute on a dedicated server. Nor can it tell you the bike is fun. Those need a
person on a real client, which is exactly the split that makes the rest of it
worth automating.

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
lua/bmx/sv_debug.lua          tuning stream and the units self-test
lua/bmx/cl_view.lua           chase camera
lua/bmx/cl_hud.lua            rider HUD and tuning overlay
lua/entities/bmx_base/        the entity
tools/syntax-check.sh         parse everything with a real Lua 5.1 front end
```

## Adding a bike

One table in `lua/bmx/sh_bikes.lua`:

```lua
BMX.RegisterBike("cruiser", {
    printName   = "Cruiser",
    model       = "models/yourpack/cruiser.mdl",
    frameOffset = Vector(0, 0, 4),
})
```

That registers entity class `bmx_cruiser`, derived from `bmx_base`, and adds it
to the spawn menu. Entries currently describe appearance and mount points only:
per-bike *physics* is Phase 5, and the reason it is not a half-working field
today is written down in `sh_bikes.lua`.

## Contributing

`tools/syntax-check.sh` parses every file with a real Lua 5.1 front end (via
Docker) and rewrites GLua's three extensions to 5.1 equivalents for the
duration. Run it before opening a PR. It does not execute anything, so it
catches syntax errors and not typo'd API names.

## Licence and content

Code is MIT, see [LICENSE](LICENSE).

The bike model shipped here is a **placeholder** (a Hunter's plate from base
GMod, with procedurally drawn wheels) so the addon has zero content
dependencies and can be cloned and ridden immediately.

**Do not add ripped assets.** A GTA 5 BMX model, or anything extracted from
another game, in a public repository is the fastest way to get it taken down.
Original or CC0 models only, licensed separately from the code and stated
explicitly.
