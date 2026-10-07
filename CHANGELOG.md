# Changelog

The top entry is always the version in `lua/autorun/bmx_init.lua`
(`BMX.Version`); the offline suite checks they agree. An entry says whether the
Workshop has it yet, because `main` and the test server move ahead of Steam:
a Workshop update goes out only when the owner says so.

## 1.1.0 -- on `main` and the test server, not yet on the Workshop

**New**

- **Combos**, the Tony Hawk way. Tricks chained together -- air into a grind,
  the grind into a manual, the manual into a hop -- build a combo, and landing
  it pays the chain's points again for every trick past the first. Bail before
  it banks and the bonus is lost (the tricks' own points stay). The HUD shows
  the chain, the multiplier, then LANDED or BAILED.
- **Two more bikes**: the **BMX Cruiser** (24-inch: longer, heavier, faster at
  the top end, slower off the line) and the **Mini BMX** (16-inch: short, light
  and quick, with a low top speed). Both are in the spawn menu, and
  `bmx_spawn cruiser` / `bmx_spawn mini`.
- **Server settings**: `bmx_max_per_player N` caps the bikes one player can
  have out (spawn menu and `bmx_spawn` alike), `bmx_scoring 0` turns scoring
  off entirely, `bmx_combos 0` keeps trick points but drops combo bonuses.

**Changed**

- The chase camera no longer sways with the bike's lean.

**Fixed**

- A bike registered with `physics` overrides had no grind or combo settings
  and threw on its first grind or trick. No bike on the Workshop had
  overrides, so nobody hit it; the new bikes would have.

**Under the hood**

- The Workshop item ID (3814420080) ships in the upload kit, so an update needs
  nothing typed and the first-upload script refuses to make a second item.
- Every riding case in the headless suite also runs on the cruiser and the
  mini, and a crowd case checks that a server with two dozen bikes out keeps
  its tickrate. The offline suite has tests for the bikes, the settings, the
  upload kit and sixteen riders at once.

## 1.0.0 -- 2026-09-27, the first Workshop release

Lean-to-steer riding on raycast wheels with a real tyre model; pedalling,
braking and skids; wheelies, manuals, stoppies, bunny hops, flips, barrel
rolls and 360s with on-screen scoring; crank and double-peg grinds found
automatically on any map; slope-matched landings; ragdoll crashes; an IK
rider on a procedural bike; 14 paint colours; and a GTA-style cinematic camera.
