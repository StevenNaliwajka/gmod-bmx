# G14 -- Electric bikes and e-moto

**Competitor:** [#14](https://github.com/luttje/gmod-bicycle/issues/14) (open):
e-bikes, an e-moto (Talaria Sting), and "battery and motor bodygroups" on
existing bikes. They note that with no pedals the feet just sit on the frame.

**Us today:** single human drive torque in `sv_physics.lua`. No motor,
no battery.

## Goal

A pedal-assist e-bike and a no-pedal e-moto, both on the vehicle platform.
They're the first motorised vehicles, so they set the pattern for G15.

## Done when

- **Pedal assist (e-bike):** motor torque = assist level × rider torque,
  capped at a legal-ish top speed (25 km/h assist cut-off by default,
  `bmx_ebike_limit`). Assist level 0-3 on mouse wheel, shown on the HUD.
- **E-moto:** throttle on W, no pedalling (feet on pegs), regen on S,
  top speed ≈ 2.5× BMX. It's heavier, with long-travel suspension.
- **Battery:** drains with motor work and recharges when parked. The HUD shows
  the charge, and an empty battery means you pedal a heavy bike.
  `bmx_ebike_battery 0` = infinite.
- A whine sound that scales with motor rpm (base-game placeholder, as in
  `sh_sound.lua`).
- An "e-bike" bodygroup or flag on the cruiser/road bike, if the owner wants it.

## Approach

The platform's `drive` becomes a list of torque sources: `human`,
`assist(k, vmax)`, `throttle(maxTorque, curve)`. Battery state lives in
the bike's networked struct.

## Tests

- Offline: assist cuts off at the limit, and battery drain is roughly
  energy-conserving.
- Headless `ebike_top_speed`: flat ground, holds ≤ limit with assist.

## Risks

Low after G22. Server owners may hate fast e-motos on RP maps, so add
`bmx_allow_motor 0`.
