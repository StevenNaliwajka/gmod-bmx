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
`BMX_STUDIO_PORT`, `BMX_STUDIO_SSH`, `BMX_STUDIO_GMOD`, `BMX_STUDIO_OWNER` (the
human whose client renders).

The stage is open floor (`RIDESTUDIO.FLOOR`, petopia_bmx_fall's park by default);
the vehicle faces the longest clear run from there. Worn vehicles (the skates) are
put on the bot instead of spawned. A changelevel drops the client half: run it
again, the script re-sends it every time.
