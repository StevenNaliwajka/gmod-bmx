# G27 -- A park in a spawn menu: ramps, rails, quarter pipes

**Competitor:** none. Their players hunt for skatepark maps and PHX wedges,
and issue #5 was filed against a PHX prop.

**Us today:** the city (`sh_city.lua`) proves we can build collidable
geometry from Lua (`bmx_city_solid`), and `sv_bot.lua` has a ramp finder. No
spawnable park pieces.

## Goal

Any map (gm_flatgrass, gm_construct, an RP map) becomes a park in two minutes,
and server owners can build a permanent one. It also gives our tests fixed,
known geometry instead of depending on Workshop maps.

## Done when

- A spawn menu category **BMX Park** with procedural, collidable, freezable
  pieces, each with sizes (S/M/L) and the right grind flags:
  - kicker, launch ramp, quarter pipe (3 heights), **spine** (back-to-back
    QP, G06), bank, funbox, pyramid, **flat rail**, down rail, kinked rail,
    ledge / manual pad, hubba, bowl corner, dirt jump pair (take-off +
    landing), drop-in deck with coping.
- Rails, ledges and coping are tagged so `sv_grind.lua` grinds them
  without guessing (the city's solids already carry data).
- Pieces snap to each other (edge-to-edge) when placed with a toolgun mode
  `bmx_park`, and the whole layout saves and loads (`bmx_park_save <name>`)
  for permanent parks, beyond what dupes do.
- Lightweight: pieces are mesh-built like the city (`bmx_city_solid`
  pattern), have no model files, and network as parameters.
- Some preset parks ("Street plaza", "Vert ramp", "Dirt line") load with one
  command.

## Approach

Generalise `bmx_city_solid` into `bmx_park_piece` with a shape id and a
parameter list. Collision via `PhysicsInitConvex` / multi-convex from the
same generator the client draws from (the city's deterministic-generator
rule applies). The quarter pipe's curve is a convex strip set.

## Tests

- Offline: every piece's convexes are valid and match its drawn mesh (the
  city tests do this for buildings).
- Headless: G05, G06 and G16 cases spawn these pieces, so terrain tests stop
  depending on maps.

## Risks

Physics cost of many convexes. Freeze by default and cap the piece count
(`bmx_park_max`).

## Status (2026-10-07)

**Built, offline-tested; the two headless cases are written and unverified
until a real server runs them.** Nothing here has been seen in a game: no
client has drawn a piece and VPhysics has not collided with one.

What exists:

- `bmx_park_piece` (`lua/entities/bmx_park_piece/`): a shape id and a
  parameter list (`"2,1"`: size S/M/L, then the shape's variant) as two
  networked strings; the server builds `PhysicsInitMultiConvex` from
  `BMX.Park.Build` (`sh_park.lua`) and the client builds the same hulls for
  prediction and draws the same build's faces (`cl_park.lua`, one IMesh per
  distinct piece). Frozen on spawn, physgun-able, dupes. No model, no sound.
- 15 shapes, 78 spawn-menu classes in the category **BMX Park**: kicker,
  launch ramp, quarter pipe (low/mid/tall), spine (3 heights), bank, funbox,
  pyramid, flat rail, down rail (with stairs), kinked rail, ledge and manual
  pad, hubba (with stairs), bowl corner (3 heights), dirt jump pair (3 gaps),
  drop-in deck (3 heights), each S/M/L. A quarter pipe's curve is 8 convex
  strips; the drawn surface is the same chords.
- **Grind tags.** Rails, ledges, manual pads and coping come out of the
  generator as `grind` lines (`ENT:GrindLines()`, `BMX.Park.WorldGrind`).
  `sv_grind.lua` is NOT changed: it still finds a rail by tracing, so the tags
  do not steer it. They are what is measured (the offline tests check every
  tag against `C.Grind`: pipe width, `drop` either side, edge drop) and what the
  headless rail case aims at. Coping is a 4 wide pipe 3 above the deck, so it
  grinds as an edge toward the transition; whether the live classifier takes it
  is for the headless run to say.
- Tool `bmx_park` (Construction): left places or snaps edge to edge
  (`BMX.Park.Snap`, nearest side in the target's own proportions; optional
  slide in steps of 8), right turns a quarter, reload removes, a ghost box shows
  the spot.
- `bmx_park_save <name>` / `bmx_park_load <name>` (`data/bmx/parks/<map>/<name>.json`,
  world positions), `bmx_park_preset <street_plaza|vert_ramp|dirt_line>` (built
  where you aim; the layout is computed from footprints so it cannot overlap),
  `bmx_park_clear`, `bmx_park_list`. All but the list need the new CAMI
  privilege **BMX - Build Parks** (admin).
- `bmx_park_max` (default 120, 1-500): a server setting row; caps the toolgun,
  the spawn menu and every load, which stops at the cap and reports the rest.
- Offline: `tests/test_park.lua` (hull validity by brute-force face search,
  mesh vs collision, grind tags vs `C.Grind`, snap touching at every turn,
  save/load round trip, privilege, presets vs cap, the tool). Headless:
  `park_quarterpipe_ride_up`, `park_flat_rail_grind`.

Not done: G05, G06 and G16 cases still build their own terrain (the pieces are
there to switch to); no icons in the spawn menu (no model to render); no
per-piece colour; a preset is built at one height, so on uneven ground it
floats or sinks in places.
