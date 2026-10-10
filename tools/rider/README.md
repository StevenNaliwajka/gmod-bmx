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
