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
