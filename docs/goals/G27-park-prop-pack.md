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
