# G19 -- Q-menu settings, CAMI permissions, reset and persistence

**Competitor:** spawn menu **Options → Bicycle** with **Client** (camera,
units, sit pose, volumes; saved) and **Server** (top speed, acceleration,
steering, grip, suspension, and more; host/admin only, live). Commands
`bicycle_reset_client` and `bicycle_reset_tuning`. **CAMI** privileges (works
with ULX, SAM, Helix) for physgunning ridden bikes, resetting tuning and the
model editor.

**Us today:** about 40 convars and commands (`bmx_*`), all console only. No
menu, no CAMI, no reset, and no permissions model beyond what convar flags give.

## Goal

A server owner can set the addon up without opening a console, and give their
moderators exactly the powers they want. This decides whether a
server runs our addon, and servers are what bring subscribers.

## Done when

- **Options → BMX** in the spawn menu:
  - **Rider** (client): camera (first/chase, distance, height, roll,
    smoothing), units, HUD on/off, stick deadzone, volumes (G18),
    keybinds for every trick input (G03, G17), and the trick list overlay.
  - **Server** (admin): scoring, combos, max per player, passengers (G11),
    air assist (G06), water (G18), ragmod (G07), motor vehicles (G14/G15),
    and the main physics feel sliders (top speed, accel, grip, lean gain),
    each with a "reset to default" button.
  - **Vehicles** (admin): enable/disable each vehicle type for spawning.
- `bmx_reset_client`, `bmx_reset_server`.
- **Persistence:** server settings are saved to `data/bmx/server.json` on change
  and loaded at boot. This beats theirs, which reset on restart unless the admin
  runs `host_writeconfig_lua`.
- **CAMI privileges:** `BMX - Change Server Settings`, `BMX - Physgun Ridden`,
  `BMX - Spawn Motor Vehicles`, `BMX - Remove Any Bike`, `BMX - Bot`
  (`bmx_bot_*`), `BMX - Unlock Any Lock` (G13). The defaults are superadmin /
  admin, and they're registered with CAMI if present or fall back to
  `IsAdmin()`.
- Every setting has a tooltip that says what it does in a player's words.

## Approach

`cl_options.lua` builds panels from a **settings table** in `sh_config.lua`
(name, type, range, default, scope, help) so the menu, the reset commands,
the JSON persistence and `bmx_dump_config` all come from one list. Server
changes go through a net message checked against CAMI. They don't go through
raw convar replication.

## Tests

- Offline: every setting in the table has help text, a range, and round-trips
  through JSON. A non-admin's change is rejected.
- Offline: a CAMI shim grants and denies.

## Risks

Low. It's mostly UI. The settings table is a refactor of `sh_config.lua`
access, so do it before the convar count grows further with these goals.

## Status (2026-10-07)

The settings table is `lua/bmx/sh_settings.lua`, the menu is
`lua/bmx/cl_options.lua`, saving and the net message are
`lua/bmx/sv_settings.lua`, CAMI is `lua/bmx/sh_permissions.lua`. Tests:
`tests/test_settings.lua`. The panels have not been looked at in a real client
(no vgui offline), so the layout is **unverified on a live game**.

- **Options > BMX > Rider (client):** done for what exists today: camera
  (first/chase, distance, height, roll, smoothing, cinematic), units, HUD,
  stick deadzone, rider animation and IK, bike colour, city drawing, bike
  detail, tuning overlay. Not done: volumes (G18), trick keybinds (G03, G17),
  trick list overlay (those features do not exist yet).
- **Options > BMX > Server (admin):** done for scoring, combos, bikes per
  player, crash ragdoll, the city, bot name/model, and all twelve physics feel
  sliders. Not done: passengers, air assist, water, ragmod, motor vehicles
  (their goals add rows with `BMX.Settings.Add`). Reset button per row and per
  page: done.
- **Vehicles panel (enable/disable each type):** not done; it needs the vehicle
  platform (G22). The category list in `sh_settings.lua` is the extension point.
- **`bmx_reset_client`, `bmx_reset_server`:** done.
- **Persistence:** done: `data/bmx/server.json`, written on any change (debounced),
  loaded at `InitPostEntity`.
- **CAMI:** done: all six privileges registered (retried at `InitPostEntity`),
  `BMX.Can(ply, name)` with an admin/superadmin fallback. Gating in place:
  `bmx_bot_*` and physgun on a ridden bike. Registered but nothing to gate yet:
  Spawn Motor Vehicles, Remove Any Bike, Unlock Any Lock.
- **Tooltips for every setting:** done, and a test fails without them.
- **Tests:** done: help and range on every row, JSON round trip, load at boot,
  non-admin rejected, CAMI grant and deny, and a guard that fails if a `bmx_`
  convar exists that the table does not describe.
- `bmx_dump_config` now also prints every setting, starring changed ones.
- Server convars for scoring, combos, bike limit, crash ragdoll and bot name/model
  became `FCVAR_REPLICATED` so the panel can show their value. Names unchanged.
