# Goals

What is left to do on the BMX addon, most urgent first. First written
2026-10-07 against 79a2939; updated the same day after the work below.

**Release rule.** The addon is live on the Steam Workshop (item 3814420080).
A Workshop update goes out only when the owner says so. GitLab (`main`) and
the test server (VM 110149, which the pipeline's `deploy-dev` + `headless`
jobs feed) get changes as fast as possible.

## Where it stands

- The Workshop item was posted 2026-10-05, from a build that was not recorded
  (its size lies between v1.0.0's and the combos commit's). 71 subscribers,
  9 favourites, no comments and too few votes for a rating as of 2026-10-07.
- `main` is **1.1.0** (see `CHANGELOG.md`), green on the test server.
  **It is not on Steam.** The kit is built: `dist/BMX-Workshop-1.1.0.zip`.
- Offline suite 352 tests, kit/release tests 38, headless suite 53 cases.

## P0: housekeeping now that it is live -- done

- [x] Workshop ID recorded (`docs/PUBLISHING.md`, `workshop/workshop-id.txt`),
      read by `update.bat` / `publish.sh`; `publish.bat` and `publish.sh create`
      refuse to make a second item. `tools/test-workshop.sh` checks it all
      against a fake `gmpublish`, and runs in CI.
- [x] README status, test counts and install steps brought up to date; it
      points players and servers at the Workshop.
- [x] The GitHub workflow is gone (the repo has no GitHub remote, so it never
      ran); GitLab CI does the checking.
- [x] Merged branches deleted locally and on GitLab; local `main` synced.
- [x] Headless suite confirmed green on the test server for 79a2939, and for
      every commit since.

## P1: ship 1.1.0 -- ready, waiting on the owner

- [x] `BMX.Version` 1.1.0, `CHANGELOG.md`, Workshop description in
      `addon.json` (combos, three bikes, server settings, gamepad).
- [x] Kit built: `tools/package-workshop.sh` -> `dist/BMX-Workshop-1.1.0.zip`.
- [ ] **Owner: say go.** Then `update.bat` (or `./publish.sh update "..."`)
      on the publisher's PC, check the Workshop description, mark the
      CHANGELOG entry with the date, and tag `v1.1.0`
      (`docs/PUBLISHING.md`, "Releasing an update").

## P2: tune from real riders

- [x] Workshop feedback looked for: none yet (no comments, no rating).
- [x] Load test: offline, 16 riders at once (traces linear in bikes, nothing
      sent while plainly riding, messages addressed to their own rider);
      headless `crowd` case, 25 bikes out on the real server: 66.0 of 66
      ticks/s.
- [ ] **Needs a person.** Ride with `bmx_debug 1` and go through the
      known-untuned values in `docs/TUNING.md` (crank torque, lean gains,
      tyre stiffnesses, wheelie aim, landing angle), now including the
      cruiser's and the mini's.
- [ ] **Needs a person.** Ride on a real server with real ping.
- [ ] When feedback arrives: fold each change that holds up into
      `sh_config.lua` / `sh_bikes.lua` with its reasoning, and add a test for
      any bug a player found.

## P3: features

- [x] More bikes: the 24-inch **cruiser** and 16-inch **mini**, physics
      overrides only, every headless riding case run on each (found and fixed
      the cruiser crank-grinding 2.6 u above the pipe).
- [x] Server settings: `bmx_max_per_player`, `bmx_scoring`, `bmx_combos`.
- [x] Gamepad: the stick was already analog; added a per-rider
      `bmx_stick_deadzone` so a worn stick does not steer.
- [x] Combo multiplier on the HUD -- already there in 1.1.0's combos.
- [ ] An optional real model. Needs an original or CC0 model to exist first;
      never ripped assets.
- [ ] More grind types (feeble, smith). Not started on purpose: a new grind
      changes how the live bike behaves on every rail, and nobody can feel it
      before it ships. Worth doing after the first round of rider feedback.

## Found along the way

- [x] A bike with `physics` overrides had no `Grind` / `Combo` config (the
      merge list was hand-written and predated both): the first grind or trick
      on such a bike threw. Fixed before any shipped bike had overrides.

## Done before 2026-10-07 (for reference)

Lean-derived steering, raycast wheels and tyre model, wheelies, stoppies, hops,
flips, grinds (crank and double peg), slope landings, ragdoll crashes, IK
rider, procedural bike, 14 colours, cinematic camera, combos, an offline and a
headless test suite in CI, and the Workshop kit.
