--[[--------------------------------------------------------------------------
    autorun/bmx_init.lua

    The loader. Load order is NOT alphabetical and NOT incidental:

        sh_config    defines BMX.Config, which every other file reads at load
                     time as well as at run time
        sh_util      defines the maths helpers sh_bikes and the sim both use
        sh_bikes     registers bikes, which needs ClassFor and the config
        sv_* / cl_*  the simulation and the presentation, in dependency order

    Getting this wrong produces "attempt to index a nil value (field 'Wheel')"
    at load, which is a far less obvious symptom than it sounds like once six
    files are involved. An explicit list beats a directory scan for exactly that
    reason: the order is a design decision, so it should be written down.
----------------------------------------------------------------------------]]

-- SEND THIS FILE ITSELF. Everything below is careful to AddCSLuaFile the shared
-- and client lists, and then the loader that does the sending was the one file
-- not on either of them.
--
-- Whether lua/autorun/*.lua reaches clients on its own is exactly the kind of
-- engine detail that is easy to be confident about and wrong about, and the
-- failure mode is brutally asymmetric: if it does, this line costs nothing, and
-- if it does not, the entire client half -- HUD, chase camera, the procedural
-- wheels -- is simply absent in multiplayer while working perfectly in
-- singleplayer, which is where all the testing happens.
--
-- A headless suite structurally cannot catch this. It has no client.
if SERVER then AddCSLuaFile() end

BMX = BMX or {}
BMX.Version = "1.1.0"

local SHARED = {
    "bmx/sh_config.lua",
    "bmx/sh_settings.lua",    -- every player and admin setting, in one list (after sh_config: reads its defaults)
    "bmx/sh_permissions.lua", -- CAMI privileges and BMX.Can
    "bmx/sh_util.lua",
    "bmx/sh_tricks.lua",    -- the trick registry; the scoring and the overlay read it
    "bmx/sh_bikes.lua",
    "bmx/sh_sound.lua",
    "bmx/sh_color.lua",     -- the palette and the ways to choose from it
    "bmx/sh_city.lua",      -- the city around the park: layout builder
    "bmx/sh_city_maps.lua", -- ...and which maps have one
}

local SERVER_FILES = {
    "bmx/sv_wheel.lua",
    "bmx/sv_balance.lua",
    "bmx/sv_air.lua",
    "bmx/sv_input.lua",
    "bmx/sv_grind.lua",     -- before sv_physics, which calls it
    "bmx/sv_combo.lua",     -- chained tricks: before sv_physics too
    "bmx/sv_tricks.lua",    -- frame/bar spins and style poses: before sv_physics too
    "bmx/sv_physics.lua",
    "bmx/sv_seat.lua",
    "bmx/sv_compat_ragmod.lua", -- RagMod, if installed: before the crash path asks
    "bmx/sv_bell.lua",      -- R on the ground rings the bell
    "bmx/sv_water.lua",     -- drag, splash and ejection in water (sv_physics checks for it)
    "bmx/sv_rules.lua",     -- server-owner settings: bike limit, scoring on/off
    "bmx/sv_settings.lua",  -- changing and saving them: net message, server.json
    "bmx/sv_scores.lua",    -- personal bests + leaderboard; listens to the public hooks
    "bmx/sv_launch.lua",    -- finding a ramp to get air off, or putting one down
    "bmx/sv_bot.lua",       -- a bot rider that does tricks (bmx_bot_spawn)
    "bmx/sv_games.lua",     -- SKATE, Trick Attack, Combo Mambo (loads bmx/games/*)
    "bmx/sv_debug.lua",
    "bmx/sv_city.lua",      -- the city's colliders and admin commands

    -- The headless harness loads last: its cases reference BMX.Config, the
    -- wheel/balance state and the entity, so everything it asserts on must
    -- already exist. It does nothing until bmx_test is run.
    "bmx/sv_test.lua",
    "bmx/sv_test_cases.lua",
}

local CLIENT_FILES = {
    "bmx/cl_view.lua",
    "bmx/cl_hud.lua",
    "bmx/cl_scores.lua",    -- after cl_hud: it borrows that file's fonts
    "bmx/cl_games.lua",
    "bmx/cl_sound.lua",
    "bmx/cl_rider.lua",     -- after cl_view: it finds the rider's bike the same way
    "bmx/cl_cinematic.lua", -- L: the cinematic camera; cl_view hands over to it
    "bmx/cl_grind.lua",     -- sparks and the scrape while a bike grinds
    "bmx/cl_tricks.lua",    -- the trick list overlay (bmx_tricks)
    "bmx/cl_report.lua",    -- bmx_report: a paste-able block for a bug report
    "bmx/cl_city.lua",      -- draws the city, runs the subway trains
    "bmx/cl_options.lua",   -- spawn menu > Options > BMX, built from BMX.Settings
}

if SERVER then
    for _, f in ipairs(SHARED) do AddCSLuaFile(f) end
    for _, f in ipairs(CLIENT_FILES) do AddCSLuaFile(f) end
end

for _, f in ipairs(SHARED) do include(f) end

-- Convars are created after sh_config so the defaults they publish are the ones
-- actually in the table, and before anything reads them.
BMX.SetupConVars()

if SERVER then
    for _, f in ipairs(SERVER_FILES) do include(f) end
else
    for _, f in ipairs(CLIENT_FILES) do include(f) end
end

if SERVER then
    MsgN("[BMX] ", BMX.Version, " loaded (server)")
else
    MsgN("[BMX] ", BMX.Version, " loaded (client)")
end
