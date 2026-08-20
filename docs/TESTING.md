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

## Getting tuning numbers back into the repo

```
bmx_dump_config
```

prints every live value to console in a form you can paste into
`lua/bmx/sh_config.lua`. Convars are replicated and apply on the next tick, so a
tuning session is: change, ride, change, ride, dump.

Keep the tickrate you tuned at written down next to whatever you commit. It is
part of the answer.
