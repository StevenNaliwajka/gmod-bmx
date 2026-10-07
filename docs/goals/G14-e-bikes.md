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

## Status (2026-10-07)

Built on the vehicle platform and tested on the offline plant; the headless case
`ebike_top_speed` is written, **not run** (no server here). Not on the Workshop.

- **`bmx_spawn ebike`** (`sh_motorbikes.lua`): family `moto`, Motor in the spawn menu. Drive kind `assist`
  (`sv_motor.lua`): the pedal drive plus LEVEL x the rider's effort, faded out over the last 2 km/h under
  `bmx_ebike_limit` (25), so the legs take over above it. Level 0-3 on the mouse wheel and `[` `]` (the
  `ebike` input map reuses the road bike's shift message); HUD shows `assist n/3` and the battery.
  Motor torque is cut as the front wheel rises (`M.WheelieCut`): level 3 looped the plant's bike over without it.
  On the plant level 3 holds 25.0 km/h; the legs alone reach 23.3.
- **Battery** (`sh_motor.lua`, `sv_motor.lua`): Wh on the state, drained by `torque * omega * (1/39.37^2) / 0.85`,
  recharged in two minutes when parked and unridden, empty = no motor, `bmx_ebike_battery 0` = infinite (networked -1).
  Test: the pack gave up the motor's work over the efficiency, measured from what the drives return, and the
  bike's kinetic energy never exceeds motor plus legs.
- **`emoto`**: `throttle` drive with `battery = 3` and `regen`; W throttle, no pedalling, S regen (60% back).
  ~2.55x the BMX's top speed (803 vs 315 u/s), 150 kg, long travel (restLength 10.5), upright and steering at speed.
- **Whine** (`sh_sound.lua` `motor`, `cl_motor.lua`): a looping base-game placeholder whose pitch follows the
  networked rpm; it dies at the assist limit. Nobody has heard it.
- **Settings**: `bmx_ebike_limit`, `bmx_ebike_battery` (rows in `sh_settings.lua`), `bmx_allow_motor`; spawning
  needs the CAMI privilege "BMX - Spawn Motor Vehicles" (admin by default), gated in `PlayerSpawnSENT`.
- **Tests**: `tests/test_motor.lua` (assist cut-off, limit, levels, shift wire, battery arithmetic and energy,
  empty/parked/infinite, regen, e-moto speed, HUD, registry, gate, settings); headless `ebike_top_speed`.
- **Left**: tuning by feel on a server; the "e-bike bodygroup" (no models yet, G20); drawn as a BMX with static
  cranks on the e-moto; the privilege defaulting to admin means players need it granted on a dedicated server.
