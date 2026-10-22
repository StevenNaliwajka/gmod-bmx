# Rider preview

Every vehicle's **rider**, posed by the shipped `lua/bmx/cl_rider.lua` through a
pedal stroke, drawn without a game client: a contact sheet, a looping GIF per
vehicle, and a reach report (how far each hand and foot is from its grip or pedal).
It is how a change to a pose set, the IK or a stance is looked at in seconds,
before anyone takes it to a server.

    lua5.1 tools/rider/export.lua [ids] [frames] [speed] [stance] > rider.json
    python3 tools/rider/render.py rider.json out/

| Argument | Default | |
|---|---|---|
| `ids` | `all` | comma-separated vehicle ids (`stock,road,dirtbike`), or every vehicle with a rider pose |
| `frames` | `12` | samples per crank turn |
| `speed` | `0` | 0..1 of the bike's top speed: the tuck grows with it |
| `stance` | `seated` | `seated`, `standing` or `attack` (`sh_stance.lua`) |

`out/sheet.png` has a row per vehicle: the side view at crank 0, 90, 180 and 270,
then the front. A red ring marks a hand or foot more than 3 units off its grip or
pedal (the offline suite's band for a foot over a whole stroke). `out/<id>.gif` is
the stroke on a loop, and `out/report.txt` the worst miss per limb.

Every vehicle takes ~15 s (its detailed model is built, as a client does), so `all`
is a few minutes; name the ones you are working on.

**The tandem** shows both riders: the stoker on their own pedals and bars, with a
row of their own in the report. **Open hands** (the unicycle's arms out for
balance) hold nothing, so for them the hand itself is measured to its target; for
everyone else it is the inside of the fist to the grip, as `tests/test_rider.lua`
measures it. A vehicle with no model of its own is drawn as the simple bike and
marked `*` in the report.

## What it is and is not

It boots the offline suite's client realm (`tests/lib/gmod.lua`) and seats its
stand-in skeleton (`tests/lib/skeleton.lua`: ValveBiped's bones at a standard
player's lengths) on each bike where `ENT:BuildPod` would (`BMX.SeatFor`), as
`tests/test_rider.lua` does, then draws the bike's detailed model through the
suite's fake mesh (`tests/lib/meshfake.lua`) and runs `PrePlayerDraw` frame by
frame. So the pose sets, the IK, the stances, and
the grips and pedals the bike reports are all the shipped code's. A real player
model's mesh is not: for that, `tools/ride/shoot.sh` photographs a ridden bike
through a connected client.

**The spine** bends forward about its own Z, as ValveBiped's does and as
`cl_rider.lua` assumes. The stand-in used to have its side axis there instead, so
every forward lean was drawn (and tested) as a bend to the rider's left; that was
found with this tool and fixed in `tests/lib/skeleton.lua`.

## The photo studio

The stick figures above say where the joints are; they cannot say whether a rider
LOOKS right -- a wrist cocked, a thumb sticking out of a fist, a hand half off its
grip, a head turned to the sky. The studio draws the real thing: kleiner's own mesh,
skinned on kleiner's real skeleton (`tests/data/skeleton_kleiner_*.lua`), posed by the
shipped code through a scenario, with the vehicle's built model as it was drawn.

    tools/rider/studio/studio.sh skateboard                 # -> skateboard.png
    tools/rider/studio/studio.sh stock styles out.png       # each style pose, in the air
    tools/rider/studio/studio.sh stock bike out.png "standing,attack" 0.6
    STUDIO_PAX=1 tools/rider/studio/studio.sh tandem        # with the stoker
    STUDIO_VIEWS="front,R hand" tools/rider/studio/studio.sh scooter
    STUDIO_GOOFY=1 tools/rider/studio/studio.sh skateboard  # (STUDIO_FAKIE=1: rolling tail first)

A row per shot (cruise, push 0.40, crouch, indy grab...), a column per camera: front,
the left side, back three-quarter, high, and each hand close up. The scenarios are in
`studio.lua` (`bike`, `styles`, `board`, `flips`, `scooter`, the skates' strides, and
`rest`: the capture with nothing moved). A shot takes a second or two to draw; a
vehicle's model takes a few seconds to build first.

The first run compiles `raster.c` (a z-buffer: flat shading, no textures) and copies
kleiner's .mdl/.vvd/.dx90.vtx out of a GMod install's VPKs (`fetch_model.py`, over ssh
from `BMX_STUDIO_MODEL_SRC`, default `test-gmod:/opt/gmod/garrysmod`) into `.model/`,
which git ignores: they are Valve's files.

What it is not: the engine's animation. The base sequence is the capture's one frame
(drive_airboat seated, idle_all_01 standing), with the head turned wherever the
capturing bot was looking, about 48 degrees off; on a client the head follows the
player's aim. So judge a head by what the code sets (BMX.RiderLookAt measures and
overrides it), and confirm on a client with `tools/ride/shoot.sh`. First used
2026-10-19: it found the skater's paws, the fists left after a grab, the head looking
at the sky, the seated "standing" stance, fists half off their grips and the thumbs.

## Video

A still says where a limb is; it takes motion to see a foot sliding on the ground, a
knee that snaps between two frames, or a crouch that comes too late for the pop. The
studio films a scenario: a shot every simulated frame, drawn from one camera, as an
H.264 mp4 with a label strip (the phase, the time, the speed, the height off the ground,
a timeline of the phases).

    tools/rider/studio/video.sh skateboard skate_session skate.mp4 side
    tools/rider/studio/video.sh stock bike_session bike.mp4 three-quarter
    tools/rider/studio/video.sh scooter scooter_session scooter.mp4 follow 60
    STUDIO_KEEP=shots.json STUDIO_RANGE=6.5:8.2 tools/rider/studio/video.sh skateboard skate_session ollie.mp4 tripod

`video.sh <id> <scenario> <out.mp4> [camera] [fps]`. The scenarios written for film are
the `*_session` ones in `studio.lua`: the vehicle really travels (its position advances
every frame at its speed, the seat with it), a push is the server's push cycle, a carve
turns the board by what its trucks steer, an air is a parabola from the speed the
server's own pop or hop gives, and every phase is in seconds, so `fps` (the simulation's
rate as well as the film's, default 30) does not change the timing. The older scenarios
film too, but they teleport, as they were written to for stills.

| Scenario | Vehicle | What happens (seconds) |
|---|---|---|
| `skate_session` | `skateboard` | roll in 0-1, three pushes 1-2.8 (0.6 s each), cruise, carve left 3.8-5 and right 5-6.2, ollie from a 0.3 s crouch (pop at 7.1, about 0.5 s and 20 units of air), roll, kickflip from a 0.35 s crouch (pop at 9.45), manual 10.6-12.2, roll out to 13.7 |
| `bike_session` | `stock` (any bike) | pedal seated 0-3, stand and sprint 3-5.5, coast with the cranks level 5.5-7, a full-charge bunny hop (0.42 s preload, 0.73 s of air), a few strokes, a hop with a tabletop, roll out: about 12.5 |
| `scooter_session` | `scooter` | roll in, four kicks 0.8-3 (0.55 s each), cruise, lean into a turn left 4-5.4 and right 5.4-6.8, a full-charge hop (pop at 7.8, 0.67 s of air), two kicks, roll out: about 11.4 |

Cameras: `side` (from the vehicle's right: a regular skater's front, a bike's drive
side), `side-l`, `front`, `back`, `three-quarter`, `high` and `follow` travel with the
rider -- a dolly on a smoothed track, at a fixed height so an air rises in the frame,
and except `follow` (a chase camera that turns with the vehicle) at fixed directions,
so a carve is seen turning the board. `tripod` stands still beside the track and pans,
as real footage is shot (STUDIO_TRIPOD=t: level with where the rider is t seconds in).
The ground is a world-anchored checkerboard, so it slides past at the vehicle's speed,
and everything casts a shadow on it, which is what shows how high an air went.
STUDIO_GOOFY=1 films the skater goofy, STUDIO_SIZE=WxH (768x432) the picture size,
STUDIO_RANGE=t0:t1 only part, STUDIO_FRAMES=dir writes the PNGs too.

It takes about 40 s for a 14 s film on 4 cores: ~17 s to simulate (every frame a client
would draw) and ~20 s to draw them (`raster.c`, a process per core). Next to the mp4
it writes `<out>.angles.json`, the rider's knee, hip and elbow flexion and trunk lean
every frame (`tools/rider/angles.py`), which `compare.py` plots.

`tools/rider/studio/motion.py shots.json` (keep them with STUDIO_KEEP) measures the
two things a film shows that a still cannot: frames where a joint jumps in the
vehicle's frame (a second difference over 2.5 units: 75 u/s of change in one frame), and
a foot down on the ground that slides over it instead of staying planted.

First used 2026-10-22, on the 1.3.9 rider. A board's push and a scooter's kick put the
foot down for 0.27 s and it slides 11 to 44 units forward over the ground meanwhile (it
moves at two thirds of the vehicle's speed or more; it should stand still), and it steps
off the deck in one or two frames (10-15 units a frame). An ollie's, a kickflip's or a
hop's body snaps 6-10 units in the frame of the pop and again at touchdown, where the
legs straighten instead of soaking the landing; the crouch before an ollie is shallow
(knees 70 degrees, hips 20, the trunk upright, where the real kid in `compare.py` is at
120, 130 and 50) and the bike's preload does not lower the rider at all. A manual's arms
jump 15 units in and out. Pedalling, once a turn near the top of the stroke, the foot's
pitch flips and drags the knee 5 units in a frame. The feet stand with the ball of the
foot (Toe0) on the targets the deck sets for the ankle: on the board the heels hang off
the heel edge and the soles float a unit over the grip, on the scooter three.

## Comparing with real footage

`tools/rider/compare.py` puts a real clip and a studio film side by side in one mp4, at
the same height, each cut to its own segment, with a title and its own clock, and plots
both riders' knee, hip and trunk angles under them on one time axis with a cursor:

    python3 tools/rider/compare.py ollie_vs.mp4 \
        --ref "Ollie 1.ogv" --ref-from 0.9 --ref-to 2.1 --ref-mirror --ref-pose ollie1.json \
        --ours skate.mp4 --ours-from 6.75 --ours-to 7.95 --ours-title "studio: ollie"

Line the two up on an event by choosing the cuts (above, the pop is 0.35 s into each).
`--*-crop x,y,w,h` crops a clip in its source's pixels and `--*-speed 0.5` plays it at
half speed. `--ref-mirror` flips the real clip and swaps its left and right angles: a
goofy skater riding right to left then matches the studio's regular rider on the `side`
camera. Our angles are read from the film's `.angles.json`; the real rider's from
`--ref-pose`, made with

    python -I tools/rider/refpose/blazepose.py "Ollie 1.ogv" ollie1.json --from 0.5 --to 2.5

which runs MediaPipe's BlazePose (pose_landmarker_heavy) on LiteRT, so it works on a CPU
without AVX, where the mediapipe wheels do not. It needs numpy, opencv-python and
ai-edge-litert (a venv), and the two models, which are not in git:

    mkdir -p tools/rider/refpose/.models && cd tools/rider/refpose/.models
    curl -LO https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_heavy/float16/latest/pose_landmarker_heavy.task
    unzip pose_landmarker_heavy.task      # pose_detector.tflite, pose_landmarks_detector.tflite

The angles are measured the same way on both (`angles.py`: flexion from the joint
centres, 0 for straight; the real ones from BlazePose's 3D world landmarks, which is
what lets a monocular estimate be compared at all). Compare shapes and timing, not
single degrees: the estimate is a few degrees off at best and more with a limb hidden,
frames it is unsure of are dropped (`--min-vis`), and a child is not kleiner.

Reference clips are not committed (a film made from one is a derivative: credit it and
keep its licence if it is shared). The ones this was built with are on Wikimedia
Commons: "Ollie 1.ogv" and "Ollie 2.ogv" by Medvedev, CC BY-SA 3.0 (a kid's ollies, a
static camera, the rider crossing it), and "Kenyan skateboarding.webm" by Drewperez1,
CC BY-SA 4.0 (a push at 0-1 s, a ride and an ollie down steps at 1.4-4.6 s).
