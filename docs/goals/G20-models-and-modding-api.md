# G20 -- Real models, a modding API, and a model editor

**Competitor:** two CC-BY Sketchfab models (RayznGames' mountain bike,
Grimecent's BMX), re-textured grey so they recolour, meshes merged, with an
armature added and credits in the README. An `INTEGRATION_GUIDE.md` covers
registering bike models, writing tricks, and hooks, and a `MODELING_GUIDE.md`
covers building one. There's an in-game `bicycle_editor` for fitting a model to
its mount points.

**Us today:** no model at all; the bike is drawn from beams
(`docs/DESIGN.md` §8). The licence rule is **"original or CC0 only"**. Our
registry (`sh_bikes.lua`) already takes `frameOffset/frameAngles` for a
model and validated `physics` overrides, but there's no guide, no public hooks
list, and no editor.

## Goal

1. Our Workshop thumbnail and first impression show a real bike.
2. Other people can add vehicles and tricks to our addon, so the content
   grows without us.

## Done when

- **Licence decision (owner):** extend the rule to "original, CC0 **or
  CC-BY 4.0 with attribution in `CREDITS.md` and the Workshop description**".
  Never ripped or NC/ND assets. I recommend this: it's the licence the
  competitor uses, and it's what Sketchfab's free BMX/skateboard models mostly
  carry.
- **One model per shipped vehicle** (BMX first, then the skateboard, G23),
  rigged with the bones G01 requires, greyscale albedo for `bmx_color`
  tinting, and LODs. The procedural bike stays as `bmx_model 0` and as the
  debug view.
- **`docs/MODDING.md`**: register a vehicle (registry fields, `physics`
  overrides, seats, drive), register a trick (G17's `BMX.RegisterTrick`), and
  a **hooks list** with arguments: `BMX_Mounted`, `BMX_Dismounted`,
  `BMX_TrickLanded(ply, trick, points)`, `BMX_ComboBanked(ply, chain,
  total)`, `BMX_ComboBailed`, `BMX_RiderCrashed(ply, vel)`, `BMX_CanSpawn`,
  `BMX_CanMount`. Gamemodes (DarkRP, TTT, Petopia) can then hook scoring.
- **Example addon** `gmod-bmx-example-vehicle` that adds one bike with only the
  public API, and is built in CI so the API can't silently break.
- **`bmx_editor`** (CAMI-gated): spawn a model, drag the mount points
  (axles, steer axis, seat, bars, pedals, pegs) with gizmos, and print the
  registry entry to copy.

## Approach

- Models: Blender → `.smd`/`.qc` via Crowbar in a separate `modelsrc/` with
  its own licence file. The `.gma` grows from 468 KB to a few MB, which is fine.
- Hooks: most already exist internally (`hook.Run` is used in
  `sv_combo.lua`, `sv_grind.lua`, `sv_seat.lua`). Rename them to a stable public
  prefix and document them. Keep the old names as aliases for a version.

## Tests

- Offline: every documented hook is fired at least once by the suite, and
  the test fails if a hook is documented but never run (or run but not
  documented).
- CI: the example vehicle addon loads and passes `per_bike_physics`.

## Risks

Model work needs a person with Blender time, or a commission. The API needs a
freeze: from then on, a breaking change needs a major version.

## Where the assets go (owner, 2026-10-07)

All BMX vehicle assets go in the BMX addon (`gmod/gmod-bmx`): every vehicle's
models, materials and sounds, as well as its code. They never go in the gamemode
(`gmod/gmod-bmx-mode`) or the map (`gmod/petopia_bmx_fall`), so a server running
only the addon has every vehicle complete.

## Status (2026-10-07, later): the BMX has a real model

The stock bike (and the cruiser and mini, scaled) now draws as a detailed
model built in code (`lua/bmx/cl_bikegeo.lua`, `cl_bikemesh.lua`,
`DrawDetailed` in `entities/bmx_base/cl_init.lua`): original work under the
code's MIT licence, so the licence question does not arise for it. It is
rigged by construction -- each moving part is its own mesh group placed by
the same maths the simple bike uses -- so G01's rig check has nothing to
check on it. The procedural bike stays as `bmx_bike_model 0` and as the
`bmx_debug` view. Tests: `tests/test_bikemodel.lua`. Offline look:
`tools/bike/export.lua` + `tools/bike/preview.py`. Still open: the
skateboard's model (G23), the example addon and `bmx_editor`.

## Status (2026-10-07)

The public hooks and the guide are done; models, the licence change, the
example addon and the editor are not started (out of this change's scope).

- **Hooks routed** to stable public names, old ones kept as aliases for one
  version, fired right after the new ones: `BMX_Mounted(ply, bike)`,
  `BMX_Dismounted(ply, bike)`, `BMX_TrickLanded(ply, trick, points, bike)` (once
  per trick), `BMX_ComboBanked(ply, chain, total)`, `BMX_ComboBailed(ply,
  chain)`, `BMX_CanSpawn(ply, bikeId)`, `BMX_CanMount(ply, bike)`. Fired from
  `entities/bmx_base/init.lua`, `sv_seat.lua` and `sv_combo.lua`.
- **`BMX_CanMount` is a breaking change**: same name, arguments were `(bike,
  ply)`, now `(ply, bike)`. It cannot be an alias. Said so in the guide.
- **`BMX_RiderCrashed`** is documented as pending and deliberately not fired
  here (another change adds it). `tests/test_hooks_doc.lua` allows it until
  then, and fails the day it is fired without leaving its `PENDING` list.
- **`docs/MODDING.md`**: registering a bike (every registry field, `physics`
  overrides and what they imply), the hooks list with arguments and realms,
  deprecated aliases, the commands for server owners. It says
  `BMX.RegisterTrick` (`sh_tricks.lua`, being built elsewhere) will be the trick
  API, and gets a section when it lands.
- **Tests** (`tests/test_hooks_doc.lua`): every documented hook is fired somewhere
  in `lua/`, every `BMX_` hook fired is documented, and each public hook is
  exercised with its documented arguments (including both vetoes and that the
  old names still fire).
- Also fixed on the way: `sv_test.lua`'s `ShutDown` listener returned a boolean,
  which ends the hook chain and could have stopped other `ShutDown` listeners.

Left: the licence decision, real models, the example vehicle addon and its CI
job, `bmx_editor`, and the trick section of MODDING.md once `RegisterTrick`
exists. The API freeze (a breaking change needs a major version) starts at the
release that ships this.
