# G09 -- Road bike

**Competitor:** [#9](https://github.com/luttje/gmod-bicycle/issues/9) (open,
requested): a road bike. They listed CC-BY Sketchfab candidates and noted that
the chain needs simplifying.

**Us today:** three BMX-family bikes in `sh_bikes.lua`, each with `physics`
overrides. Nothing has drop bars, gears or road tyres.

## Goal

A road bike that rides like one: fast, twitchy, poor on jumps and good on
the road. It gives the people who come for "bikes in GMod" a reason to pick ours.

## Done when

- `bmx_spawn road` and a spawn menu entry.
- Physics: 700c wheels (≈ 13.8 u radius at our scale), long wheelbase,
  low-mass frame, narrow high-grip / low-slip-limit tyres, top speed ≈ 1.6× the
  BMX, steering quicker at speed.
- **Gears:** a simple 2-11 gear model so cadence stays sane from walking pace
  to top speed. Shift with mouse wheel or `[`/`]`, and the gear shows on the HUD.
  The other bikes stay single-speed.
- Rider pose: drop-bar grip, a more tucked back (`cl_rider.lua` pose table).
- Tricks: allowed, but scored at ×1.5 ("road bike tax"). This makes for a
  good meme on servers.
- Every headless riding case runs on it, as it does for the cruiser and the
  mini.

## Approach

Physics overrides only, plus a new `gears` field in the registry (validated
like `physics`). Procedural drawing gets a drop-bar shape. A model comes
later, under G20's licence rule.

## Tests

- Offline: registry and gear ratios. Cadence at top speed in top gear is in
  60-110 rpm.
- Headless: all riding cases on `road`.

## Risks

Low, after G22. Before G22, the gears field is the first non-BMX concept in
the registry, so design it to fit the platform.

## Status (2026-10-07)

Done on the offline plant, in one commit on top of G22; headless cases written,
**not run** (no server here). Not merged, not on the Workshop.

- **`bmx_spawn road`**, "Road Bike" in the spawn menu under Bikes
  (`sh_bikes.lua`). 700c wheel (radius 13.8), wheelbase 48 (the BMX's 39), mass 78,
  grip 1.5 and rolling resistance 0.007, `dragArea` 0.0037, `Hop.popSpeed` 190.
  Measured on the plant: top speed in the top gear is about **1.6x the BMX's**
  (502 against 315 u/s), the cadence there 103 rpm.
- **Quicker steering at speed:** `Balance.leanKp` 300 / `leanKd` 70 and the
  assist whole by 95 u/s (110 on the BMX). The lean, and so the steer that comes
  from it, builds sooner; `tests/test_road.lua` checks the rise time against the BMX's.
- **Gears:** a `gears = { ratios = {...}, start = n }` registry field, validated
  at registration (2-11 ratios, rising, a whole-number `start`, no other keys) and
  documented in `docs/MODDING.md`. The model is `lua/bmx/sh_gears.lua`: the drive
  asks `BMX.GearRatio(ent, cfg)`, which is `Drive.gearRatio` for every other bike and
  the current gear's ratio on one with gears; the gear is a networked integer on the
  entity. The road bike has eight, 1.2 to 3.5, and `BMX.Gears.Covers` shows that some
  gear keeps the legs at 60-110 rpm at every speed from a jog (110 u/s) to the top
  gear's top speed (neighbouring bands overlap). Below that is a standing start.
- **Shifting:** `]` / mouse wheel up, `[` / wheel down, from the vehicle's input map
  (`road`, in `sh_vehicles.lua`; actions with `buttons` instead of a usercmd `key`).
  The client sees the press (`cl_gears.lua`) and sends one message; the server
  (`sv_gears.lua`) decides: the sender must be the rider, and a bike takes one shift
  per 0.15 s. `bmx_shift_wheel 0` gives the wheel back to the weapon switch. The
  gear and the cadence in rpm are on the HUD.
- **Look:** drop bars drawn from the bar points (`barStyle = "drop"`), a `road`
  rider pose set (`cl_rider.lua`: flat-back crouch at a standstill, lower at speed,
  head up) with the style-trick poses of the BMX. Not seen on a client.
- **Score x1.5:** a `scoreMult` field, applied once in `ENT:AwardTricks`, so the
  score, callout, `BMX_TrickLanded` and the combo all see the multiplied number.
- **Tests:** `tests/test_road.lua` (39): registry and spawn, the gears field's
  rejections, the gear model and its cadence band, shifting through the real wire,
  the drive running on the gear, top speed and cadence on the plant, steering,
  hop, braking, the x1.5, the drawn drops and the pose. Headless: every riding case
  also runs as `<case>@road` (`sv_test_cases.lua`).
- **Left:** a real model (G20), tuning by feel on a server (the plant is right in
  kind, not in number), an automatic box for gamepad players, and the headless
  `@road` cases have not met VPhysics: the bands were written for the BMX and a
  road bike may sit at the edge of one.
