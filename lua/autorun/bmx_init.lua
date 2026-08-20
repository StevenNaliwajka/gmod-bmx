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

BMX = BMX or {}
BMX.Version = "0.1.0"

local SHARED = {
    "bmx/sh_config.lua",
    "bmx/sh_util.lua",
    "bmx/sh_bikes.lua",
}

local SERVER_FILES = {
    "bmx/sv_wheel.lua",
    "bmx/sv_balance.lua",
    "bmx/sv_air.lua",
    "bmx/sv_input.lua",
    "bmx/sv_physics.lua",
    "bmx/sv_seat.lua",
    "bmx/sv_debug.lua",
}

local CLIENT_FILES = {
    "bmx/cl_view.lua",
    "bmx/cl_hud.lua",
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
