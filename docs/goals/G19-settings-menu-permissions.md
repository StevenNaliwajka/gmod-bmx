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
