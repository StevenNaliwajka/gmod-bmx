# Performance and the camera: how the addon is measured, and the loop that keeps it fast

Players reported, on the Workshop bug thread (2026-10-08 to 11-04):

- "out of my 500+ mods this is still the mod which is causing the most lag"
- "my frames whenever I spawn something really go down the drain"
- "the riding pose only shows up in certain camera positions; other ways your character
  uses the jeep/airboat driving animation"

This file is the plan that answers them and keeps them answered. It is a loop, run
again after every change that touches drawing, physics or the rider:

1. **Measure in a real game, on a GPU** (not only the offline shim). Frame times,
   which of the addon's hooks and methods cost what, and a line profile.
2. **Take the single largest cost**, find out why it is paid, and remove it.
3. **Pin it with an offline test** that fails on the old code (every test below was
   checked that way), so it cannot come back.
4. **Measure again**, the same scenes, the same way. Record the numbers (the table
   below). Back to 2 while anything the players would feel is left.
5. **Sweep the camera**: every vehicle, every stage of the ride, the chase camera
   swung all the way round at three heights and in first person, every frame judged.

## The tools

All of them drive a real Garry's Mod client: `tools/bench/sp.sh` runs it in
singleplayer on the test client VM (gmod-marionette, an RTX 2070), which is what
the players who reported it play.

| Command | What it does |
|---|---|
| `tools/bench/sp.sh install [REF]` | this tree's addon (or a commit's) into the client, the Workshop copies moved aside |
| `tools/bench/sp.sh launch` | singleplayer on gm_flatgrass, the game window focused (unfocused, it is held to 20 fps) |
| `tools/bench/sp.sh probe` | scenes: nothing spawned; 8 first spawns; 8 parked; riding. Frame times and every BMX hook timed |
| `tools/bench/sp.sh parked TAG` | 8 parked vehicles: frame times, each vehicle's Draw, and a line profile of the addon's Lua |
| `tools/bench/sp.sh camsweep [PASSES] [IDS]` | the camera sweep (below), with the frames it judged bad captured |
| `tools/bench/sp.sh blocker on\|off` | another addon's `PrePlayerDraw` that returns `false`, placed ahead of ours |
| `tools/bench/sp.sh restore` | put the client back as it was |
| `tools/bench/probe_addon/lua/svprobe.lua` | the server half's cost per tick (in singleplayer it is the same process) |
| `luajit tools/bench/client_frame.lua --sites` | offline: which line of the addon makes each Vector, per frame |

### The camera sweep

`tools/ride/camsweep_*.lua`: the player rides each vehicle themselves (the server
drives the bike) through one timeline -- parked, pedal, sprint, standing, attack,
hop, air with a style pose, landing, a braking turn -- four times: the chase camera
at 12, 40 and -12 degrees, and first person. The view is turned as a mouse turns it,
300 degrees a second, so every stage is seen from every side. Every frame it records
where the camera is round the vehicle, whether the rider was drawn, whether the
riding pose was on them that frame, and how far each fist and foot is from the grips
and pedals the vehicle drew; a frame with the pose missing or a limb more than 7
units off is "bad", and is photographed.

## What was found, and what changed (1.4.1)

### 1. The motorbikes' shock springs were rebuilt every frame
The coil spring of the dirt bike, e-moto and downhill bike was worked out in Lua and
streamed to the engine vertex by vertex, every frame, for every one in view: 1,400
vertices and about 10,000 engine calls each. On 1.4.0 it was about three quarters
of all the addon's Lua time with 8 parked vehicles in view. The body, shaft and coil
are now meshes built once and drawn under one matrix (stretched along the shock as
the suspension moves). `tests/test_perf_client.lua`: "a motorbike's shock is built
once".

### 2. The brake cable and kickstand, the same
A parked BMX streamed its cable loop and stand every frame (about 1,500 engine
calls). Once they hold still for a frame they are a mesh drawn under the bike's
matrix; while the bars are being turned they are streamed as before.
`tests/test_perf_client.lua`: "a parked bike's cable and stand are built once".

### 3. Parked vehicles never slept
Every vehicle woke its physics 20 times a second, so a parked bike nobody was near
ran the whole tyre, balance and suspension step 66 times a second, forever. A vehicle
with nobody on it, on its stand (or fallen over) and still for a second now sleeps;
anything touching it wakes it, and getting on wakes it the same tick.
`tests/test_perf.lua`: "a parked vehicle with nobody on it falls asleep".

### 4. The riding pose could be switched off by another addon
The rider's pose went on only from a `PrePlayerDraw` hook. In GMod a hook is skipped
when another addon's hook for the same event returns anything first -- even
`false` -- and which comes first depends on the hook table's order. Then the rider
was drawn in the bare driving sit: the jeep/airboat animation the bug report
describes. Reproduced in a real game with one such addon: the pose was on 0 frames
in 4,866, hands and feet 37 units off the bike, from every camera angle. The vehicle
now notices a rider drawn without our hook having run (`PostPlayerDraw`) and poses
them from its own Draw, which no other addon's hook can stand in front of. With
nothing in the way nothing changes. `tests/test_rider.lua`: "the rider is posed even
when another addon's PrePlayerDraw returns first".

### 5. The inline skates had no chase camera
Every vehicle had the chase camera except the skates: a skater rode in first person, the
one rider who could never see themselves (docs/goals/G25 had it "for the next pass"). The
skates now have the same chase camera (`bmx_cam_skates`, on by default; first person is
still `bmx_cam_first`), and the crosshair is hidden while it is on.
`tests/test_client.lua`: "on skates the chase camera follows the skater".

## The numbers (1.4.0 against 1.4.1, 2026-11-08)

The same procedure on both, back to back, each in a fresh session: RTX 2070, GMod's
32-bit LuaJIT client, singleplayer gm_flatgrass, 1280x960, window focused.

| Scene | 1.4.0 | 1.4.1 |
|---|---|---|
| 8 parked vehicles in view (stock, road, dirt bike, e-moto, scooter, tandem, penny, downhill) | 93.2 fps; frame median 9.35 ms, p99 23.1 | **220.5 fps**; median 3.94 ms, p99 12.8 |
| the same, every BMX hook timed (the probe) | 61.4 fps | **127.1 fps** |
| the server's cost of those 8 (singleplayer: the same process) | 77.8 ms of every second (1.17 ms a tick) | **19.0 ms** (0.29 ms a tick) |
| nothing of ours spawned | 243.9 fps | 242.6 fps (the addon idle costs 0.04 ms a frame) |
| riding a BMX alone, chase camera | 240.6 fps | 234.5 fps (the same, within noise) |
| 8 first spawns, one every 0.6 s (each new kind builds its model) | 62.6 fps; p95 27.2 ms, max 36.9 | 65.6 fps; p95 23.1 ms, max 41.4 (no real change) |

Earlier the same day, the parked scene with a line profile: 1.4.0 spent about three
quarters of the addon's Lua drawing the shock coils; after 1.4.1 nothing streamed per
frame is left in the top of the profile. Per parked vehicle the Draw now costs 0.3 ms
(scooter) to 0.7 ms (tandem), against well over 1 ms for the motorbikes before.

**The camera sweep**, every vehicle, 4 passes (chase at 12, 40 and -12 degrees and first
person), 9 stages, the camera all the way round -- about 11,000 frames a vehicle:

| | 1.4.0 | 1.4.1 |
|---|---|---|
| another addon's PrePlayerDraw returning first (stock, penny) | rider posed on **0** of 4,866 drawn frames; hands and feet 37 u off the bike | posed on **every** drawn frame, all 17 vehicles; hands and feet within 0.4 u |
| no other addon | posed on every drawn frame | posed on every drawn frame, all 17 vehicles |
| skates | first person only: the skater never seen | chase camera; the skater drawn in every chase frame |

Left as they are, and why: a few single frames 8-19 u off -- a landing, the frame the
test teleports the bike back to its start, the scooter's bars turning in the frame the
rider is drawn before them, a board's feet while its model is first built -- each one
frame, not a pose that stays wrong. The first-spawn hitch (one frame up to ~40 ms while
a new kind of vehicle is built) is unchanged; what players felt afterwards, the frame
rate staying down while the vehicles stood about, is what 1.4.1 fixes.

## Round 2 (1.4.2): the first-spawn hitch, the trick-spot search, every feature measured

`tools/bench/sp.sh spawns` logs every frame for 5 s after each kind's first spawn: frame
time, the Lua heap (a drop is a collection), the build's time in that frame and its
longest slice. `tools/bench/sp.sh features` measures every feature in its own scene,
client and server. What they found, and what changed:

### 6. One mesh was a 9 ms call
`BuildFromTriangles` runs at 0.73 us a vertex (bmx_bike_build_report, real client), and a
mesh was up to 4096 triangles: ~9 ms in one call, every build's worst frame. Meshes are
at most 1536 triangles now (~3.4 ms), inside the 4 ms slice. `tests/test_perf_client.lua`:
"no mesh handed to the engine is more than a build slice can take".

### 7. A finished model's first frame
The frame a built model was first drawn handed all its meshes to the GPU (a 31 ms frame).
Each mesh is now drawn once, invisibly (no colour, no depth written), a slice a frame,
before the model counts as ready. Test: "a built model is warmed a slice a frame".

### 8. Built while you choose
Pointing at a vehicle in the Q menu or the /bike (or rental) menu builds and warms its
model then, in the background, so the click finds it ready. Only that kind: building all
of them up front measured ~200 MB of a 32-bit game. Test: "pointing at a vehicle in the
menu builds its model before the click".

### 9. Unused models are let go
Every model built stayed for the session (up to ~200 MB). A model nothing has asked for in
5 minutes is freed, except the `bmx_model_keep` (4) most recent, kept to 15. Test: "a model
nothing uses is freed after a while".

### 10. Materials and the seat model loaded while joining
The vehicle materials (and the decal and tyre-lettering textures) are made one a tick after
joining, and the seat model is precached at load, instead of in the first spawn's frame.

### 11. The trick-spot search ran for everyone
The navigation search for the trick bot's ramps and rails ran on every server as the map
loaded, and again whenever park pieces changed: ~45 s at 4 ms a tick, **311 ms of every
second** with nothing spawned (in singleplayer, the player's own frame). It is only done up
front under the BMX gamemode now (or `bmx_nav_eager 1`); elsewhere when the bot or
auto-ride first asks, at 1 ms a tick where the server is the player's game.
`tests/test_nav.lua`: "outside the BMX gamemode the spots are searched for only when asked".

### Every feature, 1.4.0 against 1.4.2 (`sp.sh features`, singleplayer gm_flatgrass, RTX 2070)

| Scene | fps 1.4.0 | fps 1.4.2 | p99 ms 1.4.0 | p99 ms 1.4.2 | addon Lua ms/frame 1.4.0 | 1.4.2 | server ms/s 1.4.0 | 1.4.2 |
|---|---|---|---|---|---|---|---|---|
| nothing spawned | 238.0 | 290.3 | 10.67 | 3.95 | 0.04 | 0.04 | 311.2 | 0.9 |
| riding stock BMX | 193.2 | 280.2 | 12.59 | 6.57 | 3.24 | 3.13 | 324.0 | 11.9 |
| riding cruiser | 224.2 | 279.8 | 14.35 | 5.80 | 3.26 | 3.23 | 216.4 | 13.3 |
| riding mini | 228.8 | 283.3 | 14.29 | 5.55 | 3.19 | 3.10 | 211.3 | 11.3 |
| riding road | 286.2 | 286.0 | 4.66 | 4.61 | 2.44 | 2.56 | 10.5 | 12.3 |
| riding fixie | 286.3 | 286.2 | 4.71 | 4.74 | 2.33 | 2.45 | 13.7 | 12.0 |
| riding city | 286.2 | 286.0 | 4.51 | 4.63 | 2.41 | 2.54 | 12.4 | 13.7 |
| riding unicycle | 288.7 | 289.0 | 4.32 | 4.23 | 1.21 | 1.23 | 10.0 | 8.7 |
| riding penny | 287.7 | 286.7 | 4.70 | 4.46 | 1.64 | 1.71 | 12.7 | 12.3 |
| riding tandem | 285.7 | 284.0 | 4.69 | 4.88 | 2.61 | 2.82 | 11.2 | 12.8 |
| riding downhill | 249.8 | 286.7 | 10.08 | 4.62 | 6.83 | 2.41 | 14.2 | 10.8 |
| riding scooter | 280.3 | 280.3 | 5.22 | 5.22 | 2.49 | 2.54 | 11.7 | 12.0 |
| riding e-bike | 285.3 | 285.3 | 4.64 | 4.54 | 2.46 | 2.63 | 11.9 | 12.1 |
| riding e-moto | 260.5 | 289.3 | 9.47 | 4.48 | 6.31 | 1.97 | 14.4 | 12.5 |
| riding dirt bike | 256.5 | 288.8 | 9.80 | 4.58 | 6.45 | 2.06 | 14.0 | 12.4 |
| riding moped | 286.8 | 287.8 | 4.90 | 4.58 | 2.19 | 2.26 | 13.7 | 12.2 |
| riding skateboard | 282.2 | 283.2 | 5.28 | 5.02 | 2.37 | 2.37 | 16.7 | 16.4 |
| riding skates | 290.3 | 289.0 | 4.04 | 4.20 | 0.07 | 1.23* | 8.4 | 8.6 |
| riding, replay buffer off | 279.8 | 282.2 | 5.78 | 5.55 | 3.31 | 3.11 | 13.6 | 12.4 |
| replay playback | 282.0 | 281.0 | 5.60 | 5.90 | 1.83 | 1.83 | 12.6 | 11.7 |
| cinematic camera | 282.7 | 282.0 | 5.61 | 5.36 | 3.11 | 3.04 | 12.2 | 11.4 |
| first-person camera | 290.2 | 287.0 | 4.23 | 4.94 | 2.51 | 2.53 | 9.8 | 12.6 |
| filmer camera watching | 283.0 | 283.2 | 5.15 | 5.48 | 3.20 | 3.18 | 12.8 | 12.6 |
| skate park preset ridden through | 189.7 | 277.5 | 13.79 | 5.99 | 3.48 | 3.52 | 332.4 | 13.8 |
| bike rack, 4 bikes, rental machine | 118.3 | 245.8 | 18.60 | 10.69 | 11.47 | 8.20 | 368.1 | 14.4 |
| 16 parked vehicles in view | 25.3 | 104.8 | 64.25 | 22.29 | 51.66 | 21.08 | 473.3 | 40.9 |
| the BMX menu open | 224.8 | 290.5 | 14.96 | 3.77 | 0.04 | 0.05 | 300.1 | 0.7 |

\* the skater is drawn now (1.4.1's chase camera on skates); before, they were never seen.
Each scene runs 6 s after 3-5 s to settle; the probe's own timing adds a little to "addon
Lua" in both columns. Several scenes of 1.4.0 ran during the trick-spot search (row 1's
311 ms/s), which is what most of their difference is.

### The first spawn of each kind (`sp.sh spawns`, a fresh session, each alone)

Worst frame in the 5 s after the spawn (frames over 16.7 ms):

| kind | 1.4.0 | 1.4.1 | 1.4.2 | 1.4.2, pointed at in the menu for 1.5 s first |
|---|---|---|---|---|
| stock BMX (the session's first spawn) | 35.2 (3) | 35.5 (4) | 27.3 (1) | 22.3 (1) |
| road | 16.9 (2) | 17.8 (2) | 15.0 (0) | 12.6 (0) |
| tandem | 19.2 (2) | 17.3 (2) | 15.5 (0) | 10.5 (0) |
| dirt bike | 18.0 (3) | 18.2 (2) | 13.1 (0) | 11.2 (0) |
| penny | 15.5 (0) | 16.8 (1) | 13.8 (0) | 11.2 (0) |
| scooter | 23.5 (3) | 29.6 (1) | 12.8 (0) | 8.1 (0) |

p95 frame in those 5 s: ~11.4 ms (1.4.0, 1.4.1) -> ~6 ms (1.4.2) -> ~5 ms when pointed at
first. Left: the session's very first spawn still has one ~22-27 ms frame (the engine
creating the first vehicle and its seat; 6 ms of it is the server's first spawn in
singleplayer).

## Next round

Run the loop again when: a vehicle gets a new moving part (anything drawn per frame
belongs in a mesh), a new hook goes on a player draw (it can be skipped: give it a
fallback as BMX.PoseRidersOf does), a background job is added (who needs it, and does it
run for everyone?), or a player reports lag. Run `sp.sh features` before a release and
compare with the table above. Candidates measured but not yet worth the change: the
per-part matrix maths in `ENT:DrawDetailed` (~10% of what is left), the stand-in drawn
while a model builds (a client-side prop per tube: dearer than the model it stands in
for, but shown for well under a second now), and the session's first-spawn frame.
