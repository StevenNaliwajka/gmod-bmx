# Goals

What is left to do on the BMX addon, most urgent first. Written 2026-10-07
against `main` at 79a2939.

**Release rule.** The addon is live on the Steam Workshop. A Workshop update
goes out only when the owner says so. GitLab (`main`) and the test server
(VM 110149, which the pipeline's `deploy-dev` + `headless` jobs feed) get
changes as fast as possible.

## Where it stands

- v1.0.0 is on the Workshop (0905fbe, 2026-09-27).
- `main` is one feature past that: Tony Hawk combos and a camera that does not
  sway with the bike (79a2939). This is **not on Steam yet**.
- Offline suite: 264/264 pass (2026-10-07). Headless suite: 24/24 as of v1.0.0.

## P0: housekeeping now that it is live

- [ ] **Record the Workshop ID** in `docs/PUBLISHING.md` and bake it into
      `workshop/update.bat` / `publish.sh`. Right now the file still says
      "not yet published". An update without `-id` creates a second item
      instead of updating the live one.
- [ ] **Fix the stale README status.** It still says "v0.1.0, pre-alpha", "218
      tests / 19 headless cases" and "has never been ridden by a human". It
      should say 1.0.0, live on the Workshop, 264 offline / 24 headless, with a
      Workshop link.
- [ ] Replace the `github.com/<you>/gmod-bmx` placeholder in the README install
      steps with the real clone URL, or point people at the Workshop.
      `.github/workflows/build.yml` exists but the only remote is GitLab, so
      either set up a GitHub mirror or drop the workflow.
- [ ] Sync local `main` (14 behind `origin/main`) and delete the branches that
      are fully merged: `feat/headless-ci`, `feat/offline-suite`,
      `fix/tyre-integration-stability`, and `feat/procedural-bike` once it is
      in.
- [ ] Confirm the headless suite is still green on the test server for
      79a2939, including the new combo code.

## P1: ship the next update (1.1.0), when the owner says go

- [ ] Bump `BMX.Version` to `1.1.0` in `lua/autorun/bmx_init.lua`.
- [ ] Add combos to the Workshop description in `addon.json`. It lists tricks
      but not the combo system.
- [ ] `tools/package-workshop.sh` to build the kit, then
      `gmpublish update -id <ID> -changes "..."` from the publisher's PC.
- [ ] Tag `v1.1.0` and push the tag.
- [ ] Write a changelog people can read: combos, the camera fix.

## P2: tune from real riders

The numbers were derived or measured, never played (`docs/TUNING.md`). Now
that people are playing, tune from what they say:

- [ ] Gather Workshop comments and bug reports into one list.
- [ ] Ride it yourself with `bmx_debug 1` and go through the known-untuned
      values in order:
  - `Drive.crankTorque` / `maxCadence` (the gravity scaling is a guess)
  - `Balance.leanKp` 220 / `leanKd` 27 (stiff, "expect opinions")
  - `Wheel.grip`, `longStiffness`, `latStiffness` (nothing real to derive them
    from)
  - `Pitch.holdAim` (where a wheelie sits)
  - `Crash.maxLandAngle` 52 (a guess)
  - `Air.pitchLevelKp/Kd`, `Tricks.*` scoring
- [ ] Ride on a real multiplayer server with real ping. GMod has no vehicle
      prediction, so high-ping feel is the one thing nobody has measured.
- [ ] Do a load test with many bikes and riders at once on the test server.
      `test_perf` covers the draw LOD offline, but not server tick cost under
      load.
- [ ] Fold each change that holds up back into `sh_config.lua` along with its
      reasoning, and add a headless case for any bug a player found.

## P3: features (ideas, not commitments)

- [ ] More bikes through `BMX.RegisterBike`, for example a heavier cruiser or
      a smaller kids' bike, using per-bike `physics` overrides.
- [ ] An optional real model (original or CC0 only, never ripped assets).
- [ ] More grind and trick variety on top of the combo system: more grind
      types, manual-to-grind links, a combo multiplier on the HUD.
- [ ] Gamepad support, if GMod's input makes it practical.
- [ ] Server-owner settings: a spawn limit per player, and which tricks score.

## Done (for reference)

Lean-derived steering, raycast wheels and tyre model, wheelies, stoppies, hops,
flips, grinds (crank and double peg), slope landings, ragdoll crashes, IK
rider, procedural bike, 14 colours, cinematic camera, combos, an offline and a
headless test suite in CI, and the Workshop kit and v1.0.0 release.
