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
