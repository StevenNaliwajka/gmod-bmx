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
