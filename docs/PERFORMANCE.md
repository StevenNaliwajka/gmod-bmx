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

## Next round

Run the loop again when: a vehicle gets a new moving part (anything drawn per frame
belongs in a mesh), a new hook goes on a player draw (it can be skipped: give it a
fallback as BMX.PoseRidersOf does), or a player reports lag. Candidates measured but
not yet worth the change: the per-part matrix maths in `ENT:DrawDetailed` (~10% of
what is left), and the first-spawn build spike.
