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
