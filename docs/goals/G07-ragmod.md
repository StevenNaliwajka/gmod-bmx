# G07 -- RagMod support on crashes

**Competitor:** [#7](https://github.com/luttje/gmod-bicycle/issues/7) (closed,
shipped): if RagMod / RagMod Reworked
([2817879135](https://steamcommunity.com/sharedfiles/filedetails/?id=2817879135),
[972513789](https://steamcommunity.com/sharedfiles/filedetails/?id=972513789))
is installed, going over the bars turns the player into a RagMod ragdoll.
There's a setting to turn it off.

**Us today:** `bmx_crash_ragdoll` makes our own ragdoll on a crash. It doesn't
know RagMod exists, so a RagMod player gets our ragdoll and not the one
they installed RagMod for.

## Goal

If RagMod is present, a crash hands the player to RagMod, with our launch
velocity, so they keep RagMod's controls (grab, get up) and its look.
Otherwise it works as it does today.

## Done when

- Detect RagMod at `InitPostEntity` (global table or its hook names, checked
  for both the original and Reworked).
- On a crash with RagMod present and `bmx_ragmod 1` (server, default 1), call
  RagMod's ragdollise entry point and set the ragdoll's velocity to the rider's
  at ejection.
- If RagMod errors or is missing, fall back to `bmx_crash_ragdoll`, with no
  Lua errors either way.
- The bike stays put and can be picked up with E (as it is today).

## Approach

A small adapter `sv_compat_ragmod.lua` with `BMX.Compat.Ragdoll(ply, vel)`.
The crash path in `entities/bmx_base/init.lua` calls the adapter first. Fire a
`BMX_RiderCrashed` hook as well, so *other* ragdoll addons can take over
without us knowing about each one (part of G20's API).

## Tests

- Offline: a fake RagMod table. The adapter calls it with the right
  velocity, and when absent it falls back.
- Manual: install RagMod Reworked on the test server and crash once.

## Risks

RagMod's API isn't stable. Pin the functions we call in a comment, and fail
over to ours on any error (`pcall`).

## Status (2026-10-07)

Implemented on the worktree branch, not yet on a live server.

- `lua/bmx/sv_compat_ragmod.lua`: `BMX.Compat.Ragdoll(ply, vel)`,
  `BMX.Compat.DetectRagMod()` (run at `InitPostEntity`), convar `bmx_ragmod`
  (default 1). Every call into RagMod is a `pcall`; any failure returns false and
  the existing `bmx_crash_ragdoll` path runs.
- `ENT:Crash` fires `BMX_RiderCrashed(ply, vel, bike)` (return true to take the
  rider), then asks the adapter, then falls back. Damage is applied either way.
- Offline tests in `tests/test_ragmod.lua` (fake RagMod table, velocity, error
  fallback, convar off, hook takeover).
- **Not verified:** RagMod's real entry-point names are a guess (see the file
  header); the manual crash test with RagMod Reworked installed is still to do.
  Until then players get our own ragdoll, as before.
