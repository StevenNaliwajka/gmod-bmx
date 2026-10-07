# G13 -- Other bikes: unicycle, penny-farthing, tandem, downhill; rack and lock

**Competitor:** [#13](https://github.com/luttje/gmod-bicycle/issues/13) (open):
a sports bike, an enduro/DH bike, a carbon frame, an alternative BMX, a
**unicycle** ("requires addon rework to support single wheel balance"), a
**penny-farthing**, a **tandem** ("requires addon rework to support passenger
IK"), a **car bike rack** and a **bike lock**.

**Us today:** our balance controller already leans the bike by steering
(`docs/DESIGN.md` §3), and the wheel model is per-wheel. A unicycle is "one
wheel, no steering, balance by pedalling", which is the controller they'd
have to rewrite and a parameter change for us after G22.

## Goal

Ship the oddballs they flagged as hard, because those are the ones that show
off a physics core: **unicycle first**, then penny-farthing, then tandem.
Downhill (DH) bike for the mountain crowd. The rack and lock are utility
props for RP.

## Done when

- **Unicycle:** one wheel, fixed drive (G10), fore/aft balance by pedalling
  (W/S), side balance by leaning (A/D) and twisting (mouse yaw). It's hard
  and it's meant to be. Tricks: idle (rocking in place) and hop. It falls
  over and ragdolls on loss of balance.
- **Penny-farthing:** front-wheel drive direct, a huge front wheel (≈ 26 u
  radius), the rider high up. A hard front brake pitches you over the bars
  ("header"), which is real and very funny.
- **Tandem:** two seats (G11 seat list), both pedal and torque adds up.
  The front rider steers.
- **DH bike:** long-travel suspension (the `physics` overrides already cover
  spring/damper), big tyres, very stable at speed, heavy. Rides
  `gm_downhill`-type maps.
- **Bike rack:** a prop that welds to a car (`prop_vehicle_jeep` or simfphys
  / LVS vehicles) and holds up to 2 bikes.
- **Lock:** a SWEP or tool that locks a parked bike to a world surface. Only
  the owner (or CAMI admins, G19) can unlock it. It's for RP.

## Approach

All after G22. Unicycle needs the platform's `wheels = 1` case and a
balance mode that ignores steering. Penny-farthing needs `drive = "front"`.
Tandem needs G11's seat list with `pedals = true` on both seats.

## Tests

- Headless `unicycle_balances_with_bot`: the bot holds it upright for 10 s
  with W/S input only.
- Headless `penny_header`: full front brake at 15 mph ejects the rider forward.
- Offline: tandem torque sum.

## Risks

The unicycle may be no fun if it's too realistic. Ship it with an assist
level (`bmx_unicycle_assist`, default 0.6).
