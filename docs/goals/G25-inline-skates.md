# G25 -- Inline skates / roller skates

**Competitor:** none.

**Us today:** nothing. They're the hardest of the park vehicles: there are
two "vehicles" (one per foot), and the rider's legs are the suspension.

## Goal

Aggressive inline skates, as in Jet Set Radio and Aggressive Inline. This
completes the action-sports suite. Done well, it's a reason for skatepark
servers to run us and nothing else.

## Done when

- Equipped as a **SWEP** (`weapon_bmx_skates`) rather than spawned. Equipping
  puts the player into skate mode in place of walking, and holstering exits.
  Nothing to spawn, nothing to lose.
- Each foot is a 4-wheel frame (G22 wheels), and the body's COM moves between
  them. Push by alternating strides (W), crossover turns (A/D), T-stop or
  heel brake (S).
- Jump (Space), **soul grinds**: soul, mizou, makio, topside, royale, unity,
  backslide, frontside. Spins, flips, grabs. All on G17's registry and combos.
- Wall-ride (JSR style) as a stretch goal.

## Approach

The platform needs a "worn" vehicle: no seat, the player entity *is* the
chassis, and the wheels are cast from the feet. This is a new balance mode
(`skates`), so it's the last park vehicle, after the board proves the
platform.

## Tests

- Headless: stride to speed, soul grind on a rail, bail on a bad landing.

## Risks

High effort. Do it only after the board's M3 and if players ask for it.

## Status (2026-10-07)

A first cut, on branch `feat/scooter-skates` (the commit after the scooter's), not merged, not on the Workshop. It
delivers the worn-vehicle platform support and a playable first cut; the rest is listed below as not done. **Nobody has
skated it on a server**: the engine's part (below) is an assumption that only the headless cases can check.

| Done when | |
|---|---|
| Equipped as a **SWEP** (`weapon_bmx_skates`); equipping puts the player into skate mode, holstering exits | **Done.** Deploy equips, Holster / OnRemove / OnDrop exit; death, leaving, entering a vehicle and `bmx_allow_boards 0` take them off. Also `bmx_give_skates`, `bmx_spawn skates` (the /bike window lists them under Boards), and a held pair counts toward `bmx_max_per_player`. |
| The platform: a **worn** vehicle, no seat, the player is the chassis | **Done.** `worn = true` in `RegisterVehicle`: no entity class (`BMX.ClassFor` nil, out of `VehicleIDs` and `BikeIDs`, in `WornIDs` and `GettableIDs`), no spawn row, no seat, a worn balance mode (`skates`) and a `stride` drive. `sv_worn.lua`: `BMX.Worn.Equip / Unequip / Of`, `BMX.WornModes[...]`, and a **stand-in for the entity** (`w.proxy`) so scoring, combos, `BMX_TrickLanded` and the callouts are the one existing path. Six new public hooks, documented (`BMX_WornEquipped`, `Holstered`, `Grind`, `GrindEnded`, `Bailed`, `TricksBailed`). |
| Each foot a 4-wheel frame (G22 wheels), the COM between them | **Partly.** Eight registry wheels, four in a line under each boot, **cast from the feet** every tick (the slope under the skater, which wheels are down). There is no sprung chassis: the player's own hull stands and the legs are the suspension, so the COM is not modelled; the legs' alternation is the stride cycle and the drawing. |
| Push by alternating strides (W), crossover turns (A / D), T-stop or heel brake (S) | **Done, on a plant of its own.** `BMX.Skates.Step` is a pure function (stride adds speed, less as it speeds up; a carve rotates the velocity with the heading and grips the sideways part away; crossovers pump a little speed back; the heading chases where you look at a rate that falls with speed). `bmx_skates_brake tstop|heel` (a new client setting). |
| Jump (SPACE) | **Done.** A fresh press on the ground. |
| **Soul grinds**: soul, mizou, makio, topside, royale, unity, backslide, frontside | **Soul, mizou and backslide**, through `grindPoints.moves`, `sv_grind.lua's rail finder reused as it is, the skater placed on the rail every tick and the engine's movement taken over (`Move` returns true), the board's balance meter (A / D), SPACE released to pop off, scored by the second at 1.0 / 1.4 / 1.6 of the grind rate. **Not done:** makio, topside, royale, unity, frontside. |
| Spins, flips, grabs, on G17's registry and combos | **Spins only:** a 180 or a 360 (and more) from the heading turned in the air, paid on the landing with air time, through the combo. **Not done:** flips and grabs (they need a pose set for a skater and a deck-less trick model). A bad landing (a fall over 720 u/s, or touching down across the way of travel at speed) is a bail through the usual ragdoll path. |
| Wall-ride | **Not done** (stretch). |

**The engine's part, and why it is the risk.** The player's own movement does the collisions, stairs and slopes; the skates only own the velocity: each tick, before the engine moves the player (`SetupMove`), their velocity goes through the step and back, their walk keys are zeroed and `Entity:SetFriction(0)` takes the engine's friction away. The velocity last written is kept unless the engine's came back more than 12 percent slower (a wall). The client predicts with the same shared code (`S.Decode / Observe / Apply`), because the engine predicts a player's own movement, and while the server says the skater is on a rail the client leaves the movement alone. That prediction is **best effort**: the client's stride timing and heading are its own copy and are not wound back on a replay. If `SetFriction` does not do what is assumed, nothing glides and the first headless run will say so (`skates_stride_to_speed` checks the friction first).

**Tests.** `tests/test_skates.lua` (33): the registration and the platform's checks, the input map, the settings, the step on a plant (stride to speed with alternating legs, coasting, both brakes, crossovers, the view chase, grip, the jump, slopes, spins and the landing rules), equip and holster through the SWEP and the commands, the setup through the real `SetupMove` and `Move` hooks with a stand-in for the engine's movement (stride, the wall rule, steering, a jump and a bail, scoring), the grinds on rails (soul, mizou, backslide, a ledge, the pop, the balance lost), the client (A / D turn the view, the prediction, the boots, the legs, the sparks). Headless cases `skates_stride_to_speed` and `skates_soul_grind`: written, **not run**.

**For the next pass.** The skates' feel, the player's pose on a real model (the stride swing and pelvis nudge are numbers in `cl_skates.lua`), a rolling sound (base-game placeholders: none yet), a third-person camera for a skater (the chase camera is the vehicles'), and the missing grinds, flips and grabs.
