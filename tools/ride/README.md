# Ride studio

Pictures of every vehicle **ridden**: a scripted bot gets on, rolls forward at a set
throttle, and a connected client photographs bike and rider together from a few
angles (three side shots a beat apart, so the pedal stroke shows; front; rear; the
legs close up; from above). It is how the rider's pose and the pedalling are looked
at without anyone having to ride. The icon studio (`tools/icons/`) shoots a vehicle
standing alone; this one shoots it in use.

    BMX_RCON_PASSWORD=... tools/ride/shoot.sh                    # every vehicle
    BMX_RCON_PASSWORD=... tools/ride/shoot.sh stock,road 0.45 out/

Arguments: vehicle ids (comma-separated, or `all`), the throttle (0..1), and where
to put the JPEGs. Same settings as the icon studio: `BMX_STUDIO_HOST`,
`BMX_STUDIO_PORT`, `BMX_STUDIO_SSH`, `BMX_STUDIO_GMOD`, and `BMX_STUDIO_OWNER`, which is
required: the name of YOUR client. Nobody else's client is ever sent code or made to
render, and with the owner not connected the run stops at once.

The stage is open floor (`RIDESTUDIO.FLOOR`, petopia_bmx_fall's park by default);
the vehicle faces the longest clear run from there. Worn vehicles (the skates) are
put on the bot instead of spawned. A changelevel drops the client half: run it
again, the script re-sends it every time.

**A clear view.** On a map with walls and a Lua-drawn city (petopia_bmx_fall) fixed
camera offsets landed behind brickwork and trees: half of the first real-client run's
front and close-up shots showed no rider. So for the shoot the client turns the map's
city, trees and falling leaves off (`bmx_city_draw`, `bmx_city_plants`,
`bmx_city_leaves`, put back afterwards with the other studio settings), and every
camera is checked for a clear line to its subject: blocked, it swings round the vehicle
in 30 degree steps to the nearest clear spot at the same distance, or else moves in to
just short of what is in the way. Each moved camera is reported in the server log
(`[ride] client diag: stock_front: swung 30`).

## The animation sweep

Numbers rather than pictures: `sweep.sh` rides a bot on each vehicle in turn (the BMX
with a no-hander, the BMX with a passenger on the pegs and a can-can, the road bike,
the tandem with a stoker, the unicycle, the penny-farthing, the dirt bike with a
superman, the scooter, the skateboard, then the cruiser, mini, fixie, city bike,
downhill bike, e-bike, e-moto, moped and the dirt bike slow at full lock) through the
same 14 seconds -- pedal in a
circle, sprint, attack and standing stances, a hop with the style pose -- while YOUR
client follows each one and measures every frame:

- how far each fist and foot is drawn from what the IK was handed, and from the grips
  and pedals the vehicle drew that same frame (a rider drawn before their vehicle
  would hold last frame's grips);
- how far the hands, feet, spine and head move in a frame and how sharply that motion
  changes (scaled to a 60 fps frame, so an uneven frame time is not a pop);
- the frame times while each vehicle's model is first built, against the second
  before;
- every server setting against the client's copy of it.

      BMX_RCON_PASSWORD=... BMX_STUDIO_OWNER=Burrito tools/ride/sweep.sh            # summary
      BMX_RCON_PASSWORD=... BMX_STUDIO_OWNER=Burrito tools/ride/sweep.sh 1 "4 6"    # per frame, tandem and penny

Run it on gm_flatgrass (`changelevel gm_flatgrass`): the stage is the open plane at
(4000, 4000) by default (`sweep_ground x y z` for another map), clear of the spawn
slab's 512-unit drop. A hand's miss is measured from the fist's centre, so OPEN hands
(the unicycle's, a skater's between grabs) read the wrist-to-knuckles length, not a
miss. First used 2026-10-11 on the marionette client: it found the tandem's and the
penny-farthing's riders short of their bars and pedals, the skater hunched over, and
the hands and feet jumping when a model finished building (1.3.2).
