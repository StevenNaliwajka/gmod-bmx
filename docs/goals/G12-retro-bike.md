# G12 -- Retro / city bike

**Competitor:** [#12](https://github.com/luttje/gmod-bicycle/issues/12) (open,
requested): a retro bike, with candidates including a basket bike and an "old
German bike".

**Us today:** none.

## Goal

An upright, slow, heavy city bike with a basket and a bell (G18). It's the
roleplay-server bike (DarkRP, Helix), which is a big audience the competitor
is courting with CAMI support.

## Done when

- `bmx_spawn city`. Upright pose, swept-back bars, 28-inch wheels, heavy
  frame, coaster brake (S), and LMB does nothing, as on a real Dutch bike.
- **Basket:** a physics-attached container. Small props dropped in stay in
  while riding gently and fly out on a crash or a hop. Good for RP deliveries.
- **Kickstand**, a **bell** (G18) and an optional **lock** (G13).
- Child seat option (G11).

## Approach

Registry entry + overrides. The basket is a trigger volume welded to the
frame. Props inside get their velocity matched each tick until the bike's
acceleration exceeds a threshold, and then they're released.

## Tests

- Headless `basket_keeps_prop`: a small prop in the basket, ride 20 m at
  10 mph, and it's still in. A hop at full speed and it's out.

## Risks

Low. It mostly matters to RP servers, so build it after G19 (permissions) and
G18 (bell).

## Status (2026-10-07)

Done on the offline plant, in one commit on top of G11; the headless case is
written, **not run** (no server here). Not merged, not on the Workshop.

- **`bmx_spawn city`**, "City Bike" in the spawn menu under Bikes. 28-inch wheels
  (radius 14), a 52-long frame, 112 kg (the cruiser's is 94), `pose = "upright"`,
  `barStyle = "swept"`. The upright rider (`cl_rider.lua`): spine back, no tuck with
  speed, an unhurried stroke. Slow on purpose: `Drive.maxCadence 9.5` (91 rpm) and
  gearRatio 2.0 give ~235 u/s (21 km/h), three quarters of the BMX's, and a standing
  start a second longer. Hop pop 150, lean 34 degrees.
- **Coaster brake, LMB nothing:** a new `coaster` drive kind (the pedal drive,
  freewheeling) and the `bike_rearonly` input map: S is the rear brake and there is no
  front brake on the ground, and not even `bmx_fixie_frontbrake 1` gives it one (that is
  the fixie's). The kickstand and the bell are the ones every bike has (`sv_bell.lua`, R).
- **The basket** (`lua/bmx/sv_basket.lua`, a `basket = { mins, maxs, maxMass, hold }`
  registry field, validated): a box in the bike's own space, so "welded to the frame" is
  literal and there is no entity to constrain or duplicate. A loose `prop_physics` of at most
  12 kg that comes to rest in it is captured and from then on placed where it sits every
  tick, with the bike's velocity and no gravity, not colliding with the bike. The bike's
  acceleration is read over a 50 ms window; past 1,500 u/s^2 (two and a half g) the
  whole load is released at once with the bike's velocity and a flick up and sideways, so it
  flies. Also released by a crash, a bike on its side, removal, or a player picking the prop
  up; not caught again for 1.5 s. On the plant: riding at 10 mph reads ~20 u/s^2, a full
  hop ~2,500. Drawn as a wire box with a slatted floor and struts to the head tube.
- **Child seat:** from G11. The city bike has `seats = { child = {} }` (no pegs), so the
  context-menu toggle is offered on it, and E on the back of a ridden one with the seat on
  seats a second player in it at 0.6 scale, a quarter of the bike's mass.
- **Tests:** `tests/test_citybike.lua` (31): the registry and spawn (and bmx_allow_bikes),
  nine basket-validation rejections, the bike against the BMX (slower, freewheeling, S
  stops it), LMB through the real usercmd decode, the kickstand, the upright pose, and
  the basket on the plant with real props: caught, not caught (heavy, fast, held, outside),
  20 m at 10 mph and still in and where it was put, a hop throws it out and it flies, a crash,
  a fallen bike, a removed bike, a physgun, collision, the cooldown, a bumpy road that is
  not a hop, and the drawn box. Headless: `basket_keeps_prop` (a pop can in the box; as
  far as the ground allows up to 20 m at 10 mph and still in; a hop throws it out) and every
  riding case as `<case>@city`.
- **Left:** the optional lock (G13), a rear rack and a second basket, and the 1,500
  threshold against VPhysics's contact noise, which the plant does not have: if the prop
  comes out on a gentle ride on a real server, that is the number to raise (`hold` in the
  registration).
