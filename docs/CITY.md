# The city around the park

On maps that have one (today: `gm_skatepark`), the addon builds a city around
the park: buildings stand on every wall instead of bare brick, a second row and
a skyline rise behind them, and three elevated subway lines cross overhead,
with trains running over them on a timetable.

Nothing in the map is edited. The city is drawn by the client
(`lua/bmx/cl_city.lua`) from a layout that `lua/bmx/sh_city.lua` builds out
of a per-map definition (`lua/bmx/sh_city_maps.lua`). The parts riders can
touch (the viaducts and their piers) get colliders, `bmx_city_solid`
entities spawned by `lua/bmx/sv_city.lua`. It uses only HL2/GMod content, so
there is nothing extra to download.

## How it fits around a sealed map

`gm_skatepark` is one box: brick walls to z 528, sky brushes above, ceiling
z 1720. The sky brushes are not drawn as geometry, so anything drawn beyond
them shows through. The frontage's facades stand 4 units inside the walls and
cover the brick from the floor up. The buildings' bodies and everything behind
them are out in the void, where nobody can reach, so they need no collision.
The engine never draws entities out there (no visleaf), which is why the city
is a render hook and not entities.

## Settings

| Convar | Realm | Default | |
|---|---|---|---|
| `bmx_city` | server, replicated | 1 | build the city on maps that have one |
| `bmx_city_draw` | client | 1 | draw it |
| `bmx_city_trains` | client | 1 | run the trains and their sound |
| `bmx_city_signs` | client | 1 | draw the signs |

Commands: `bmx_city_info` (what this map's city has), `bmx_city_rebuild`
(admin; respawn the colliders after changing `bmx_city`), and
`bmx_city_rebuild_client`.

## Changing the city

Everything is in the map's table in `sh_city_maps.lua`:

- `seed`: a different seed gives a different city with the same rules.
  The generator is private and seeded, so every realm builds the same one.
- `frontage`, `backRow`: lot widths, depths, floor counts, styles, setback
  towers. One floor is 128 units, one HL2 `building_template` panel.
- `skyline`: tower count, distance band, heights.
- `viaducts`: each line's axis, position, deck height, train period, offset,
  cars and speed. `piers` stand under the crossings.
- `signs`: text panels on the facades.

Styles (which panels go on the street floor, the floors above and the
cornice) and materials are at the top of `sh_city.lua`.

To look at a change without starting the game:

    lua5.1 tools/city/export.lua gm_skatepark > layout.json
    python3 tools/city/preview.py layout.json texdump view.png  100 -1500 130 35 -18

`texdump/` comes from `tools/city/texdump.py`, run on a GMod server.

`tests/test_city.lua` holds the rules a layout must keep, checked against
every ramp's measured footprint: solids clear of every ramp and spawn by 40
units, viaducts at least 400 over the tallest coping, lines that cross without
touching and stay under the sky ceiling, every portal covered by a tall enough
building, trains that come out of one portal and go into the other. Change the
map's table and run `tools/run-tests.sh city`.

## Another map

Measure the map's play box, floor height and sun (the brush and entity lumps
of the BSP), add a table under its name, and put any piers in clear lanes. If
the map is not a sealed box, the frontage covers whatever is behind its walls.
