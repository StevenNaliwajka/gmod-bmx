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
