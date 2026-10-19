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
git clone <this repository> gmod-bmx
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

`bmx_spawn`, then look at it without getting on. You should see a BMX drawn in
code: frame, fork, bars, seat, cranks, chain, pegs, and two tyres sitting on the
ground. With `bmx_debug 1` the tyres turn red when their trace finds no ground.

A riderless bike stands on its kickstand, leaning a few degrees left, and stays
where it was left. Knock it flat and it stays down; get on and it is picked up.
With a rider at a standstill, the rider's foot holds it up. This used to be the
opposite (a stationary bike fell over, by design) until the first person to ride
it found a bike they could not get on. See `C.Stand` in `sh_config.lua`.

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

- **A world with shape**: the ground can be a ramp (`World{ groundSlope = }`),
  and boxes can stand in for rails and ledges (`World{ solids = }`). Traces hit
  both, and hull traces sweep their box the way the engine's do. The plant does
  not collide with the boxes: a grind places the bike itself, and that
  placement is what is tested.
- **A cost meter**: `tests/test_perf.lua` counts the traces one physics
  substep makes in every state (parked, riding, in the air, grinding) and the
  model draws one bike costs a frame near, mid and far, and fails when a
  change blows a budget. `tests/test_perf_client.lua` does the same for the
  client's frame: how often the rider IK has the engine pose a skeleton, the
  bones it looks up by name and the Vectors it makes (see "What a client frame
  costs", below).

Which file covers what, for the newer parts:

| File | What it rides |
|---|---|
| `test_grind.lua` | a bike placed over a pipe, a ledge, a bare ramp: what locks on and what does not |
| `test_grind_jump.lua` | a HUMAN rider through the real keys (W, SPACE) hopping onto rails, with every run checked for being launched |
| `test_landing.lua` | hands-off landings onto transitions and banks, and a barrel roll left alone |
| `test_air_assist.lua` | air control off vert ramps (G06): the launch classifier on synthetic normals, the turn about the ramp face's normal settling on a half turn, the landing aim, the spine finder on a made-up profile and the transfer on the plant, scoring, `bmx_air_assist`. Headless twins: `vert_turnaround`, `spine_transfer` (park pieces) |
| `test_nose_manual.lua` | weight forward and the nose manual (G02): the LMB / Ctrl / `bmx_lmb_mode` decode through the real `StartCommand`, the IK lean, a nose manual held over 2 s on the plant without flipping, W / S trim, the convar gate, pay by the second and chaining in a combo. Headless twin: `nose_manual_holds` |
| `test_combo.lua` | combos (`sv_combo.lua`): the bonus, the grace, a bail, a manual or grind holding one open, the HUD, and the variety rule (`bmx_combo_variety`, `Combo.repeats`): a repeat adding all, 3/4, 1/2, 1/4 and then nothing to the chain or the multiplier while still paying its own points, ten backflips against ten different tricks, grind-manual-grind, what `BMX_ComboBanked` carries, and the old rule at 0. The farms it closes are ridden end to end in `test_skates.lua` (jumping on the spot), `test_unicycle.lua` (hopping on the spot) and `test_board_flips.lua` (flat-ground kickflips) |
| `test_perf.lua` | the trace and draw budgets |
| `test_perf_client.lua` | the client frame's budgets: SetupBones a frame for a BMX rider pedalling, a scooter and a board rider standing, a skater; bone lookups and Vectors; the shock spring's Vectors per ring; a ready model remembered and forgotten when it must be |
| `test_platform.lua` | the vehicle platform (G22): `RegisterVehicle` validation (a 4-wheel board and a 1-wheel unicycle accepted, every bad field refused), input maps, the Vehicles settings and their spawn doors, and the hidden 4-wheel test cart driving forward with no balance mode. The headless twin is `test_cart_drives` |
| `test_road.lua` | the road bike and the gear model (G09): the `gears` field's rejections, the cadence band, shifting through the real wire, top speed (~1.6x the BMX) and cadence on the plant, the x1.5 score. Every riding headless case also runs as `<case>@road` |
| `test_fixie.lua` | the fixed gear (G10): the cranks locked to the wheel while coasting, the legs' drag, a skid stop under 8 m, LMB through the usercmd decode, fakie and trackstand scored. Headless: `fixie_skid_stop`, and `<case>@fixie` |
| `test_passenger.lua` | the seat registry, boarding, mass and the weight couple, the crash that takes both (a hook for each), the child seat, the client's view of a passenger. Headless: `passenger_mount_and_crash` (a second bot) |
| `test_unicycle.lua` | the unicycle (G13): the registry's new vocabulary (one wheel, `reverse`, `drawer`, seat `pedals`) accepted and refused, a rider on a scripted assist controller holding it for 10 s standing and riding, the assist deciding whether it stands without one (and monotonically, at any inertia), S as the backwards pedal, the mouse's twist through the usercmd, idle and hop scored, the stand holding it parked, the fall and the ragdoll, the drawing. Headless: `unicycle_balances` |
| `test_oddbikes.lua` | the penny-farthing, the tandem and the DH bike (G13): the two wheel sizes and the hull built from them, the header at 15 mph on a full front brake (forward, with the rear wheel off the ground first) and not on half a pull, the tandem's torque as the sum of two riders' (and the stoker's keys read for nothing else), the DH's drop against a BMX's and its sag under the step limit. Headless: `penny_header`, `tandem_rides`, `dh_lands_drop` |
| `test_rack_lock.lua` | the bike rack and the bike lock (G13): what a carrier is, capacity two and a third refused with a reason, the welds and their release (E on the bike, E on the rack, the rack removed), and the lock's permission logic (owner, "BMX - Unlock Any Lock", CAMI, the console), mount, physgun, tool gun and boarding refused to a stranger, the weapon's clicks. The shim records constraints (`constraint.Weld`, `NoCollide`, `game.GetWorld`) rather than simulating them |
| `test_citybike.lua` | the city bike (G12) and the basket on the plant with real props: kept at 10 mph for 20 m, thrown out by a hop, a crash or a fall. Headless: `basket_keeps_prop`, and `<case>@city` |
| `test_skates_ping.lua` | the skates' client prediction under a real ping (G25, G30), on `lib/netsim.lua`: a server and a client realm against each other over a link with delay, jitter and loss, the engine's restore-and-predict-again loop on the client, the same stand-in for its movement on both ends. Straight, carve, jump, T-stop, a grind (balanced with A / D from the HUD meter, popped and ridden off the end), a backslide, a ledge, a bail with and without a ragdoll, and the weapon switch on and off, measured as the client's picture against the server's for each command, every correction's jump, and whether both agreed the skater was on a rail. A bike under the same link is the baseline. `BMX_PING_REPORT=1` prints the whole table at 50, 100 and 200 ms |

The plant is not VPhysics, so the closed-loop tests use the headless suite's
bands and assert signs and orderings. When the two disagree, take it to a real
server: the headless suite is the authority on how the bike behaves.

The suite also runs the config's derivations as arithmetic (the Kp floor, the
assist ceiling against the contact-patch lever arm, the pivot inertias, drag
versus the cadence ceiling), and a minute of random riding checking for NaNs.
Every bug fixed alongside it was mutation-checked: revert the fix and a test
fails.

### What a client frame costs

Players feel the client's frame rate, and nothing on a dedicated server runs the
client's Lua. `tools/bench/client_frame.lua` drives the real client files -- each
bike's `Draw`, the rider's pose and IK (`PrePlayerDraw`), the chase camera, the
HUD, the sound, the prediction, the skates and the board -- through the same shim,
with 1, 8 or 16 riders in view, frame after frame, under LuaJIT (GMod's Lua):

```
sudo apt install luajit
luajit tools/bench/client_frame.lua                    # six vehicles, 1 8 16 riders
luajit tools/bench/client_frame.lua stock,scooter 8 --varied --count --hooks
luajit tools/bench/client_frame.lua --root ../older-checkout stock 8   # the same scene on older code
```

What it reports, a frame: milliseconds (and the worst frames, `--spikes`), the Lua
garbage made (the collector stopped for the measure: LuaJIT's pauses are a
stutter), and with `--count` the engine calls made -- SetupBones above all, each
one the engine posing a player's whole skeleton again. `--hooks` puts the time,
garbage, Vectors and SetupBones down to the hook that spent them; `--varied` rides
as riders do (steering, bumps, hops, airs with tricks and style poses, landings,
stances, kicks) instead of straight on; `--buildlog` lists a model build's slices
over 8/16/33 ms; `--dump FILE` writes every rider's bone manipulations and a
checksum of everything drawn, frame by frame, so a change can be shown to pose and
draw exactly as before (diff two dumps). The checksum takes in the built meshes
too: every vertex handed to BuildFromTriangles, each number by its bits, and the
draws of meshes one after another as one stream (a bucket cut into several meshes
drawn in a row checksums as the one mesh it was, if the same triangles reach the
screen in the same order). With `--dump` the models are built after the first frame
without the world moving on, so two versions start the dumped frames alike however
many frames their builds take. `--joff` runs with the JIT off.

Read the counts and the `lua` column, not the total: the shim's skeleton and its
table Vectors are slower than the engine's C++ (a shim Vector is a table, about
three times the bytes of GMod's), and a GPU is not here at all. The SetupBones
count is the number to watch: tests/test_perf_client.lua holds it to a budget.

Measured when the IK learned to pose only what moved (LuaJIT, riders 120 units
apart, all near the view):

| a frame, riding steady | 1.3.2 | 1.3.4 | after |
|---|---|---|---|
| SetupBones, one BMX rider | 56.4 | 58.4 | 11.3 |
| SetupBones, one scooter / board rider | 47 / 40 | 49 / 42 | 3 / 1 |
| SetupBones, one skater | 19.1 | 20.1 | 4.1 |
| SetupBones, 8 BMX riders | 452 | 468 | 90 |
| frame, 8 BMX riders, shim ms (JIT off) | -- | 61.5 | 22.2 |
| frame, 8 dirt bikes, shim ms (JIT off) | -- | 88.8 | 23.0 |
| bone matrices read, 4 BMX riders, varied riding | -- | 760 | 292 |

1.3.3 made the IK dearer by 2-10% (the extra passes for a fast-moving body, the
foot and knuckle aimed until they point, the frame follow); the IK was already
57 skeleton poses a frame per rider before it.

### What a model build costs

A vehicle kind's detailed model is built the first time a client sees it, once per
kind and size a session (BikeMesh.Get, a slice of `bmx_bike_build_ms` a frame), and
the prebuild Think asks for every vehicle in the world, drawn or not. `--build`
measures it on its own: one rider of each vehicle drawn with the models off (the
simple bike, as drawn while a model builds: the baseline frame), then from nothing
built until the model is ready.

```
luajit tools/bench/client_frame.lua --build stock,road,dirtbike,skateboard,scooter,unicycle,penny,tandem,skates
luajit tools/bench/client_frame.lua --build stock --heap 200     # a client-sized Lua heap
luajit tools/bench/client_frame.lua --build stock --root ../older-checkout
```

`build` is the time spent in BikeMesh.Get a frame (the collector's work inside it
included); `extra` is the whole frame less the baseline -- the build and what it
left for the rest of the frame (LuaJIT pays a collector's debt at the next
allocation, wherever it is). `extra` is what a player feels. `--heap MB` gives the
process a client's heap first: the bench's own heap is a few MB, and LuaJIT paces
its rounds by the heap (a round when it has doubled, and a round walks all of it), so
a small heap runs a round every few MB of garbage where a client runs one every
hundred-odd.

THE STUTTER IT WAS (1.3.6, before perf/model-build), found with `--build`,
`--framelog`, the sampling profiler and a count hook:

- **The collector, behind half the build's time and all its spikes.** A model's
  source vertices were a table each, `{ p = {...}, n = {...}, u, v }`, and the
  meshes' vertices two tables and four Vectors each: the BMX made about 340 MB of
  garbage and held 60 MB of tables while it meshed (JIT on: 52% of the build's time
  in the collector, VM-state profile). And a table written while a round is under way is
  walked again, in ONE step, when the round ends (LuaJIT's "grey again" list): the
  half-built mesh's 63,000-entry vertex table was, every round -- the build's 15-30
  ms frames came in pairs, one per round.
- **Steps too long to keep to the budget.** The build gave way every 128 triangles or
  1500 vertices and was resumed until its 4 ms were up: a frame was the budget plus
  one step, and a step was up to 367,000 Lua instructions (lua5.1, count hook) before
  any collector work; some builders ran long stretches of their own between two
  triangles (a road bike's bar tape, the city bike's chain case, a deep-V rim).
- **Two rounds of the whole heap forced after every build** (1.2.0's answer to the
  32-bit out-of-memory crash), before the model counted as ready: on a client-sized
  heap (`--heap 200`) a second or more during which every allocation of every addon
  paid for the collector, with 15-25 ms frames among them.
- **One BuildFromTriangles call a bucket**, up to 21,000 triangles: the BMX's rubber
  31,000 vertices, the tandem's 58,000, every vertex's table read through the Lua C
  API in one call. The shim cannot time it (below).
- **The prebuild's asks and a drawn bike's were the same**: whichever asked first in a
  frame ran its build, so a bike on screen could wait behind one across the map.

WHAT CHANGED: a model's vertices are eight numbers in a flat array while it is built
(cl_bikegeo.lua; `b.v` is still there, made on demand, for a tool or a test reading
a finished model); the hot primitives (tri, grid, sweep, lathe, plate, cap) work in
numbers, not a table per sum; meshing fills POOLED vertex tables and Vectors (the
engine copies them) and works each distinct normal's tangent frame out once (a model
has a tenth as many distinct normals as vertices); the build looks at SysTime every
16 triangles or 48 vertices and yields as soon as the budget is spent (the long
builder stretches given pause points); a bucket over 4096 triangles is cut into
equal meshes, each handed over at the start of a slice (unless what is left of the
slice is enough for it, learned from the calls before); drawn vehicles are built
first and at the full budget, the prebuild's at half, nearest first; nothing forces
the collector. Every vehicle draws to the bit what it drew before (`--dump`,
below).

RESULTS (`--build --heap 200`, LuaJIT 2.1 on this desk, `bmx_bike_build_ms` 4; the
mean of two runs, the max the worse; "frames" are the frames the build ran in):

| vehicle | | frames | build ms p50 / p95 / max | build > 16 / > 5 ms | extra ms p95 / max | extra > 16 / > 5 ms | build ms in all | garbage MB |
|---|---|---|---|---|---|---|---|---|
| BMX | 1.3.6 | 278 | 4.7 / 11.2 / 44.5 | 8 / 104 | 20.5 / 58.0 | 18 / 110 | 1603 | 346 |
| | now | 84 | 4.0 / 4.5 / 5.2 | 0 / 1 | 5.3 / 6.6 | 0 / 9 | 338 | 58 |
| road bike | 1.3.6 | 244 | 4.8 / 15.9 / 53.5 | 12 / 103 | 24.4 / 70.8 | 20 / 152 | 1596 | 373 |
| | now | 123 | 4.0 / 4.7 / 5.3 | 0 / 2 | 4.8 / 5.6 | 0 / 3 | 500 | 66 |
| dirt bike | 1.3.6 | 262 | 4.5 / 12.3 / 43.7 | 8 / 117 | 16.6 / 52.5 | 16 / 128 | 1558 | 346 |
| | now | 132 | 4.1 / 4.8 / 5.4 | 0 / 4 | 5.7 / 6.8 | 0 / 24 | 541 | 69 |
| skateboard | 1.3.6 | 90 | 5.0 / 7.7 / 10.2 | 0 / 44 | 8.4 / 15.1 | 0 / 52 | 490 | 109 |
| | now | 48 | 4.1 / 4.4 / 5.0 | 0 / 0 | 5.3 / 5.7 | 0 / 6 | 184 | 40 |
| scooter | 1.3.6 | 116 | 4.7 / 12.2 / 24.5 | 1 / 55 | 16.3 / 27.7 | 7 / 56 | 693 | 146 |
| | now | 36 | 4.0 / 4.3 / 4.8 | 0 / 0 | 4.9 / 5.2 | 0 / 2 | 142 | 30 |
| unicycle | 1.3.6 | 78 | 5.2 / 8.1 / 15.7 | 0 / 44 | 13.1 / 21.8 | 2 / 46 | 438 | 96 |
| | now | 42 | 4.1 / 4.6 / 5.5 | 0 / 1 | 4.1 / 5.9 | 0 / 1 | 163 | 23 |
| penny-farthing | 1.3.6 | 121 | 4.5 / 8.7 / 24.2 | 2 / 55 | 16.8 / 27.7 | 8 / 56 | 683 | 133 |
| | now | 43 | 4.0 / 4.9 / 5.2 | 0 / 2 | 5.2 / 6.3 | 0 / 3 | 172 | 30 |
| tandem | 1.3.6 | 239 | 4.8 / 17.5 / 59.4 | 12 / 104 | 27.4 / 85.1 | 22 / 152 | 1569 | 377 |
| | now | 126 | 4.0 / 4.5 / 6.2 | 0 / 2 | 5.6 / 8.0 | 0 / 16 | 506 | 68 |
| skates | 1.3.6 | 79 | 5.1 / 7.7 / 15.0 | 0 / 40 | 8.3 / 15.0 | 0 / 45 | 430 | 68 |
| | now | 31 | 4.0 / 4.4 / 4.8 | 0 / 0 | 4.9 / 5.3 | 0 / 1 | 118 | 21 |

Without `--heap` (the bench's own few-MB heap, a collector round every few MB) the
build's own slices are the same (max 5.0-6.8 ms, none over 16), and the whole frame
spikes where a round ends: p95 5-10 ms, max 6.5-20 ms (1.3.6: p95 16-35, max 21-72,
2-34 frames over 16 ms) -- with frames that build nothing reaching 11 ms there too.
The heap's high water while building, client-sized heap: the BMX +114 MB (1.3.6
+270), the tandem +152 (+291).

The same-pixels proof: `--dump` over 120 frames of varied riding, 1 and 3 riders,
on all 17 vehicles (stock, cruiser, mini, road, fixie, city, unicycle, penny,
tandem, dh, ebike, emoto, dirtbike, moped, skateboard, scooter, skates): byte for
byte the same file from release/1.3.6 and from this branch. The source geometry of
all 17 kinds is bit-identical too (every bucket, every number, the layouts).
tests/test_perf_client.lua holds the build to its step budget by count (the longest
stretch without looking at the clock, and the largest mesh), tests/test_contacts.lua
its garbage (the dirt bike under lua5.1: 573 MB in 1.3.6, 123 MB now, budget 150).

ON A REAL CLIENT, the checks this cannot make: with `net_graph 1` (or
`cl_showfps 2`), eight bots riding BMXs within 1,000 units of the camera, compare
1.3.4 and this build's frame times. Then the model build: `bmx_bike_build_report`
prints, for each model built this session, its frames, its worst frame's build time
and what BuildFromTriangles took -- in all, its worst call (and that call's
vertices) and microseconds a vertex. Spawn a vehicle kind not yet seen this session
(or `bmx_bike_model_rebuild`, which builds the ones in view again) with `net_graph
1` up, then run `bmx_bike_build_report`. The worst frame should be about
`bmx_bike_build_ms` (4); if the worst BuildFromTriangles call is over ~4 ms, its
cost a vertex says how far to lower MAX_TRIS in cl_bikemesh.lua (each mesh is a draw
call: at 4096 one BMX in view is 56 Mesh:Draw a frame, 50 with one mesh a bucket).

## Headless, and automatic

Everything above the offline section is a human looking at a bike. This
section is the part that runs on a real server without one.

`bmx_test` drives the whole simulation from a bot on a real dedicated server:
nineteen cases covering the tyre model, the balance PD, derived steering,
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
