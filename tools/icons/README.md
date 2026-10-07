# Spawn-menu icons

Every entry this addon puts in the Q menu (vehicles, park pieces, the rack, the
filmer camera, the weapons) has a picture: `materials/entities/<class>.png`,
128x128, which is where the spawn menu looks for an entry's icon. Nobody should
have to choose a ramp or a bike from its name alone.

`tests/test_spawn_icons.lua` enforces it. A new spawnable entry fails the suite
until it has a picture, and an icon whose entry is gone fails too.

## The pictures are renders of the real thing

They are not drawings. `studio_sv.lua` spawns each entry on a test server, at a
stage in the air away from the spawn points, and freezes it there.
`studio_cl.lua` runs on a connected client and draws that one entity through its
own `Draw` into a render target, once on black and once on white. `compose.py`
takes the difference between the two as the matte. It then crops the item and
puts it on one shared tile: a soft gradient, a drop shadow and rounded corners.

So an icon shows exactly what spawns, paint and all. When a vehicle's look
changes, shoot it again.

The camera has two fixed directions. Vehicles are seen from their right-hand
side, a little from the front. Park pieces are seen from in front of the riding
face, from above. The three sizes of a park piece are shot from the L's camera
and cut with the L's crop, so S and M show how big they really are next to L,
and each gets an S / M / L badge.

Items with no entity of their own (the skates and the lock) are drawn in
`studio_cl.lua` (`CUSTOM`), with the same primitives and colours the game uses.
The Skateboard weapon is shot as the skateboard it puts down.

## Shooting

You need a test server running this addon (`test-gmod`), with a human connected:
the client is what renders. You also need ssh to the server, and Python with
Pillow and numpy.

    BMX_RCON_PASSWORD=... tools/icons/shoot.sh                 # everything
    BMX_RCON_PASSWORD=... tools/icons/shoot.sh bmx_park_kicker # one shape
    BMX_RCON_PASSWORD=... tools/icons/shoot.sh bmx_ebike

It writes straight into `materials/entities/`. Look at them before you commit:
a picture of the wrong thing is worse than none.

Settings (environment variables): `BMX_STUDIO_HOST`, `BMX_STUDIO_PORT` (27016),
`BMX_STUDIO_SSH` (`root@host`), `BMX_STUDIO_GMOD` (`/opt/gmod/garrysmod`),
`BMX_STUDIO_OWNER` (the player who renders; default the first human) and
`BMX_STUDIO_RAW` (keep the raw pairs here).

The server must run the code the icons are meant to show. Deploy first if the
look changed on a branch.

## Adding something new to the menu

1. Register it as usual.
2. If it has no entity of its own, add a `CUSTOM` drawer to `studio_cl.lua`. If
   it needs its own camera direction, add it to `DIRS`.
3. Shoot it, look at it, and commit the PNG with the code.
