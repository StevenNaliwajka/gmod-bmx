--[[--------------------------------------------------------------------------
    tests/lib/scooter.lua

    The kick scooter's fixtures (G24), the way tests/lib/board.lua is the board's: a
    scooter resting on the plant and a scripted rider on it. A scooter is a bike for
    everything the harness cares about (two wheels in line, the standard input table),
    so its input is F.input's.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local M = {}

-- A scooter resting on the plant, upright, facing +X. Two wheels carry the weight.
function M.scooter(sv, at, yaw)
    local B = sv.env.BMX
    local cfg = B.ConfigFor(B.Vehicles.scooter)
    local sag = cfg.Chassis.mass * sv.world.gravity * 0.5 / cfg.Wheel.spring
    local e = sv.env.ents.Create("bmx_scooter")
    e:SetPos(at or sv.env.Vector(0, 0, sv.world.groundZ + cfg.Wheel.radius - sag))
    e:SetAngles(sv.env.Angle(0, yaw or 0, 0))
    e:Spawn()
    e:Activate()
    return e
end

-- A server with a scooter and a scripted rider on it, settled past the spawn grace.
function M.ridden(opts)
    local sv = F.server(opts)
    local e = M.scooter(sv)
    F.scripted(sv, e)
    sv:run(1.3)
    return sv, e
end

return M
