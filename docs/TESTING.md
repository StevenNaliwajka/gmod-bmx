# Testing

How to get this in front of a running server, and what to check in what order.

Nothing here is specific to any particular host. If you already have a Garry's
Mod server you administer, only the first section matters.

---

## Singleplayer is enough for most of it

The simulation is server-authoritative, and in singleplayer you *are* the
server. Everything works: `bmx_debug`, `bmx_selftest`, `bmx_dump_config`, live
convar tuning.

```
cd garrysmod/addons
git clone https://github.com/<you>/gmod-bmx.git
```

Launch, start a sandbox game on `gm_flatgrass`, and:

```
bmx_spawn
```

What singleplayer will **not** show you is latency. A bike that feels sharp
locally and mushy on a server is not a tuning problem, it is the absence of
prediction (see `docs/DESIGN.md`, section 5), and no amount of Kp fixes it. Do
the feel tuning locally and the latency check on a real server.

## A dedicated server

Any anonymous SteamCMD install works:

```
steamcmd +force_install_dir /opt/gmod +login anonymous \
         +app_update 4020 -beta x86-64 validate +quit
```

Then clone this repo into `/opt/gmod/garrysmod/addons/` and start with
`-game garrysmod -console -norestart +map gm_flatgrass`.

Two settings worth being deliberate about:

- **`-tickrate` is a physics setting here, not a performance one.** It sets how
  often VPhysics substeps, which is the `dt` every controller in this addon
  integrates against. Tuning at 66 and running at 100 changes how the bike
  feels. Pick one and record it alongside any tuning numbers you keep.
- **`-norestart`.** `srcds_run` is a shell wrapper with its own restart loop.
  Under a service manager both try to own the lifecycle, and the symptom is a
  stop that appears to work over a server that is still answering.

**Restart, do not Lua-reload.** GMod will happily re-run a file, but this addon
registers entities and hooks at load, and the old registrations stay behind. The
resulting half-old, half-new state is a spectacular way to spend an hour chasing
a bug that no longer exists in the source.

## The order to check things

### 1. It loaded

Console should show `[BMX] 0.1.0 loaded (server)` and the same for the client.
If not, run `tools/syntax-check.sh` and look for a file that did not parse.

### 2. Force units

```
bmx_selftest
```

Expected: `-> IMPULSE (expected)`.

This is the first thing to run on any new build and it is not optional. Every
force in the addon is scaled by `dt` on the assumption that
`PhysObj:ApplyForceCenter` takes an impulse. If that is wrong, nothing crashes
and nothing looks obviously broken: the bike is simply uniformly weak or
uniformly violent by a factor of about 66, and you will spend an evening
retuning grip and crank torque to compensate for a units error.

### 3. It stands up

`bmx_spawn`, then look at it without getting on. You should see two procedural
wheel rings sitting on the ground and a placeholder frame between them. The
rings turn red when their trace finds no ground.

A riderless bike is *supposed* to fall over. There is no balance assist without
a rider and no assist at all below walking pace, because a bike that stands up
on its own reads as a hovering prop.

If the wheels are floating above or sunk into the ground, that is
`Wheel.restLength` or `Wheel.radius` disagreeing with where the entity origin
is. The origin sits on the axle line.

### 4. It rolls

Get on, pedal. Watch the cadence bar. Top speed on the flat is capped by cadence,
not by drag: if the bar pins at 1.00 you are at terminal speed by design.

### 5. It leans

```
bmx_debug 1
```

`A`/`D` and watch `roll / target`. The two numbers should track within a few
degrees at speed. A persistent gap means the assist is out of authority, not
mistuned, and `authority` on the line below tells you whether that is the speed
ramp doing its job.

This is the stage where most of the tuning time goes. `docs/TUNING.md` is the
order to work through it.

### 6. It flies

Find a kicker. Both wheel rings should go red, `mode` should read `AIRBORNE`,
and `flip / roll / spin` should accumulate. Land badly on purpose and check that
you actually get thrown off: a bike you cannot crash has no failure state, and
the balance assist cap is the only thing standing between this and a rail
shooter.

## Offline, on any machine

```
tools/run-tests.sh
```

The real addon files, executed in a stock Lua 5.1 against a Garry's Mod shim
(`tests/lib/gmod.lua`). No game, no server, no client: Lua 5.1 or Docker is
enough, and it takes about ten seconds.

It exists because the headless suite below has two blind spots by
construction, and both had shipped bugs:

- **It has no client.** The wheel drawing, the HUD, the tuning overlay, the
  chase camera and the sound loops never run on a dedicated server. The first
  time the shim ran them, the wheel drawing and the `bmx_debug` overlay both
  threw on every frame they had ever drawn.
- **It skips the usercmd decode** on purpose (its bot writes `bike.input`
  directly), so nothing checked which key does what.

What the shim gives the tests:

- **Two realms**, server and client, each its own global environment, loaded
  in the engine's order. A test fails if the client runs a file the server
  never `AddCSLuaFile`'d, which is the bug that works in singleplayer and
  breaks in multiplayer.
- **A net wire** between them that checks every read against the write it
  consumes: type, bit width, and that the receiver read exactly as many fields
  as were sent. The debug overlay and the trick callouts are tested end to end.
- **A rigid-body plant**: impulses at points, the inertia tensor VPhysics
  reports for the stock hull, gravity, and hull-against-ground contact. Before
  any test was written against it, it reproduced the live server's recorded
  figures: ride height 7.2-7.5 u (live 7.3-7.5), the full weight carried, and a
  right lean turning right.

The plant is not VPhysics, so the closed-loop tests use the headless suite's
bands and assert signs and orderings. When the two disagree, take it to a real
server: the headless suite is the authority on how the bike behaves.

The suite also runs the config's derivations as arithmetic (the Kp floor, the
assist ceiling against the contact-patch lever arm, the pivot inertias, drag
versus the cadence ceiling), and a minute of random riding checking for NaNs.
Every bug fixed alongside it was mutation-checked: revert the fix and a test
fails.

## Headless, and automatic

Everything above the offline section is a human looking at a bike. This
section is the part that runs on a real server without one.

`bmx_test` drives the whole simulation from a bot on a real dedicated server:
eighteen cases covering the tyre model, the balance PD, derived steering,
wheelies, stoppies, hops and their landings, air mode, the duplicator and the
sound table. It writes `data/bmx_test_results.txt`
and prints the same report to console. On a provisioned server:

```
bmx-test                     # restart, run every case, report, exit 0/1/2
bmx-test --ref my-branch     # check that out first
bmx-test --case lean_steers  # same run, just show one case
```

Exit 0 is a clean run, 1 is a failing case, and **2 is the harness itself being
broken** -- the server never came up, the addon never loaded, the suite wedged.
Keeping those apart matters: a pipeline that reports "the bike is wrong" when it
means "I could not measure the bike" is a pipeline people learn to ignore.

`tools/server/install-server-tools.sh` puts `bmx-test` and its RCON client on
the box, and `install.sh` runs it on every deploy so the harness and the code
under test are always the same commit.

### In CI

`.gitlab-ci.yml` runs two gates. `ci-test.sh` parses every Lua file and runs
the offline suite on the runner, on every branch, in about fifteen seconds.
GitHub Actions runs the same offline suite, which is the only execution
coverage on that side, since it has no game server. The `headless` stage then checks
the pipeline's commit out on the game server and runs the suite there, also on
every branch, serialised by `resource_group` because there is only one server.

### Four things that have to be true, and were each not true once

**The server must not hibernate.** A Source dedicated server with no players
idles its tick loop, and the harness is driven from the `Think` hook. Without
`sv_hibernate_think 1` the suite accepts `bmx_test`, answers "a run is already
in progress" to everything after it, and never advances: no results, no error,
no progress. A headless box is empty by definition, so this is not optional.

**The addon must be readable by the user the server runs as.** If it is not, the
addon does not load and *nothing says so* -- srcds starts, answers RCON and
reports itself healthy. On this estate `addons/` itself was left `drwx------
root:root` by a rebuild, and three weeks of "the server is up" meant nothing.
`bmx-test` waits for the addon's own load line before it believes anything.

**RCON has to be reachable, which means srcds needs `-ip`.** It picks its TCP
bind address by resolving the hostname, and a cloud-init `/etc/hosts` maps that
to `127.0.1.1`. The UDP game port still binds `0.0.0.0`, so players connect
fine and only the test loop is dead -- and it fails as "connection refused",
which reads like a firewall.

**`bmx_test_onboot` cannot be armed from outside.** It looks like the obvious
way to start a run, and there is no moment to set it: the addon creates the
convar when its Lua loads, so a `+bmx_test_onboot 1` on the command line is
"Unknown command", and `server.cfg` is exec'd *after* the `InitPostEntity` hook
that reads it. It is useful when set from inside Lua and useless to a script.
RCON after the load line is the trigger that works.

## Getting tuning numbers back into the repo

```
bmx_dump_config
```

prints every live value to console in a form you can paste into
`lua/bmx/sh_config.lua`. Convars are replicated and apply on the next tick, so a
tuning session is: change, ride, change, ride, dump.

Keep the tickrate you tuned at written down next to whatever you commit. It is
part of the answer.
