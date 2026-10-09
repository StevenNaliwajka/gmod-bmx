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

Every vehicle takes ~10 s (its detailed model is built, as a client does), so `all`
is a few minutes; name the ones you are working on.

## What it is and is not

It boots the offline suite's client realm (`tests/lib/gmod.lua`) and seats its
stand-in skeleton (`tests/lib/skeleton.lua`: ValveBiped's bones at a standard
player's lengths) on each bike, as `tests/test_rider.lua` does, then draws the bike
and runs `PrePlayerDraw` frame by frame. So the pose sets, the IK, the stances, and
the grips and pedals the bike reports are all the shipped code's. A real player
model's mesh is not: for that, `tools/ride/shoot.sh` photographs a ridden bike
through a connected client.

**The spine.** `cl_rider.lua` bends the spine and head forward with
`Angle(0, lean, 0)`, about the bone's own Z, which is ValveBiped's bend axis (it is
a Character Studio Biped). The suite's stand-in reaches `Spine2` with a plain pitch,
which leaves its side axis on Y, so there a forward lean comes out as a bend to the
rider's left (+20 degrees: the head 4 units left instead of 4 forward). The IK is
solved in each bone's own frame and cannot tell, so the suite passes either way. By
default this tool turns `Spine2` about its length to Biped's axes (the same rest
pose to the unit); `BMX_RIDER_SKELETON=standin` draws the suite's skeleton exactly
as it is.
