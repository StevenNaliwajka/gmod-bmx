# G22 -- The vehicle platform: one core, many vehicles

**Competitor:** a bicycle SENT whose ride is the player model's animation
rotated about the pedals. Their author's own words on why the skateboard
stopped: "significantly harder to animate [...] anything I try with
skateboarding looks very janky." Their architecture is a bicycle, and a
different vehicle means a different addon.

**Us today:** the core is already mostly vehicle-agnostic, but it's named and
shaped as a bike:

| Part | File | Bike-specific today |
|---|---|---|
| Raycast wheels, tyre model | `sv_wheel.lua` | assumes 2 wheels in line, front steers |
| Balance / lean-derived steer | `sv_balance.lua` | single-track (bicycle) dynamics |
| Air, flips, tuck | `sv_air.lua` | nothing much |
| Launch classify | `sv_launch.lua` | nothing |
| Grinds | `sv_grind.lua` | crank and pegs as contact points |
| Combos, scoring | `sv_combo.lua`, `sv_rules.lua` | nothing |
| Input decode | `sv_input.lua` | the bike's key map |
| Rider IK | `cl_rider.lua` | hands on bars, feet on pedals |
| Drawing | `bmx_base/cl_init.lua` | procedural bike |
| Registry | `sh_bikes.lua` | `BMX.Bikes` |

## Goal

Split it so a new vehicle is a **registry entry + a balance mode + an input
map + a rider pose set + a trick list**, and the bike becomes one client
of the platform. Then the skateboard (G23), scooter (G24), skates (G25),
e-bikes (G14) and dirt bike (G15) don't fork the codebase.

## Done when

- `BMX.RegisterVehicle{ id, family = "bike"|"board"|"scooter"|"skates"|"moto",
  wheels = { {pos, radius, steer = fn|false, drive = bool}, ... },
  balance = "singletrack"|"board"|"none", drive = {...}, seats = {...},
  input = "<input map id>", pose = "<pose set id>", tricks = {...},
  grindPoints = {...}, physics = {...} }`.
- `BMX.Bikes` and `bmx_spawn <bike>` keep working (aliases), and the Workshop
  spawn menu gets categories: **Bikes**, **Boards**, **Scooters**, **Motor**.
- Wheels: any count, any layout (1 for the unicycle, 2 in line for bikes,
  4 in a rectangle for boards and skates, 2-3 for scooters), and steer by
  function (fork angle for bikes, **truck lean** for boards).
- Balance modes are modules: `singletrack` (today's code, moved),
  `board` (G23), `none` (motor with a COM low enough not to need it).
- Input maps are tables: the action → key binding plus a context (ground /
  air / grind / manual), so G19's keybind UI is generated from them.
- **Every existing test passes unchanged** on the bike after the move:
  352 offline, 53 headless, 38 kit. This is the acceptance test for the
  refactor.

## Approach

Do it as a **pure refactor first**, with no behaviour change and the test
counts held, then add the skateboard in a second branch. Move code with
`git mv`-style commits so the history stays readable. The entity class
`bmx_base` stays (the duplicator and saves depend on it). Vehicle id is a
networked string, set at spawn.

## Tests

- The full suites, unchanged.
- New offline: registry validation for each field, including a 4-wheel
  board and a 1-wheel unicycle.
- New headless: a placeholder "test cart" vehicle (4 wheels, `balance =
  "none"`) that drives forward, proving the platform works for a non-bike
  before the skateboard depends on it.

## Risks

This is a big refactor on a live addon. Mitigate it with the suites (which is
what they're for), a branch, and the test server before `main`. Estimated
size: about a third of `sv_physics.lua` and `sv_input.lua` move, and
`sv_wheel.lua` generalises its wheel loop.

## Status (2026-10-07)

Done on branch `worktree-agent-a4c1507d0ad52139b`, in two commits, not merged,
not on the Workshop. Nothing about the bike changed: the 646 offline tests that
existed before pass unchanged after both phases, and the Workshop kit test passes.

**Phase 1, the refactor (no behaviour change).**

- `BMX.RegisterVehicle{ id, family, wheels, balance, drive, seats, input, pose,
  tricks, grindPoints, physics, ... }`, validated at registration like the physics
  overrides (`lua/bmx/sh_vehicles.lua`, `sh_bikes.lua`). `BMX.RegisterBike` is the
  bike-shaped way in and fills the bike's fields; stock, cruiser and mini register
  through it. `BMX.Bikes` is the same table as `BMX.Vehicles`; `bmx_spawn <id>`,
  the spawn rows, the duplicator, `bmx_base` and every convar are untouched.
- `sv_physics.lua` loops over N wheels (drive torque shared between `drive`
  wheels, each wheel takes its axle's brake); `BMX.Drives` (`pedal` is the old
  function); per-wheel `steer` is `false`, `"fork"` or a function; per-wheel `radius`.
- `BMX.BalanceModes` in `sv_balance.lua`: `singletrack` is the old code, reached
  through the registry (it did not move; see DESIGN 6c).
- Input maps are tables (`BMX.InputMaps`, action to key and context); `sv_input.lua`
  reads its keys from the vehicle's map. The `bike` map is the old keys.
- Rider pose sets (`BMX.PoseSets`) in `cl_rider.lua`; grind points per vehicle
  (`grindPoints`) in `sv_grind.lua` and `cl_grind.lua`; the trick list gates what
  is scored from motion.

**Phase 2, the proof.**

- `balance = "none"`, `drive = { kind = "throttle" }`, and the hidden `testcart`
  (4 wheels, rear pair driven, front pair steered by a function). Not in the
  spawn menu or `BikeIDs`; `bmx_spawn testcart` needs `bmx_debug 1`.
- Spawn menu rows carry `Subcategory` Bikes / Boards / Scooters / Motor and
  `Family`; `Category` is still `"BMX"` because `tests/test_bikes.lua` pins it.
  Only Bikes is populated.
- Vehicles settings group: `bmx_allow_bikes`, `_boards`, `_scooters`, `_motor`
  (server, admin), honoured by `bmx_spawn` and the spawn menu's `PlayerSpawnSENT`.
- Offline: `tests/test_platform.lua` (47 tests): validation of every field, the
  4-wheel board and 1-wheel unicycle layouts accepted, input maps, settings and
  spawn doors, and the cart driving forward, steering and braking on the plant.
  Headless: `test_cart_drives` in `sv_test_cases.lua` (written, **not run**: no
  server here). Offline total 693 passed.
- `docs/MODDING.md` has the `RegisterVehicle` reference; `docs/DESIGN.md` 6c is
  the platform section.

**What the cart found.** Four wheels evaluated one after another in a substep
read each other's roll as sideways slip and cancelled (the cart crept sideways at
5 u/s). With more than two wheels each reads a snapshot taken at the top of the
substep and carries a share of the mass in the tyre caps. Two-wheel vehicles are
unchanged bit for bit. That is a plant result; the headless case is what checks
it on VPhysics.

**For the skateboard (G23):** the `board` balance name is reserved and runs as
`none` with one console message until its module exists; `push` is a reserved
drive kind with no function; the spawn menu still has one `BMX` heading (flip
`Category` in `RegisterVehicle` and `tests/test_bikes.lua:72` when you want four).
