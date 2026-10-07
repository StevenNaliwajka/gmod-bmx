--[[--------------------------------------------------------------------------
    tests/lib/board.lua

    The skateboard's fixtures, shared by the board test files: a board resting on
    the plant, a scripted rider on it, and the input a scripted rider writes.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local M = {}

-- A board resting on the plant, upright, facing +X. Four wheels carry the
-- weight, so the static sag is m g / 4 / k.
function M.board(sv, at, yaw)
    local B = sv.env.BMX
    local cfg = B.ConfigFor(B.Vehicles.skateboard)
    local sag = cfg.Chassis.mass * sv.world.gravity / 4 / cfg.Wheel.spring
    local e = sv.env.ents.Create("bmx_skateboard")
    e:SetPos(at or sv.env.Vector(0, 0, sv.world.groundZ + cfg.Wheel.radius - sag))
    e:SetAngles(sv.env.Angle(0, yaw or 0, 0))
    e:Spawn()
    e:Activate()
    return e
end

-- A server with a board and a scripted rider on it, settled.
function M.ridden(opts)
    local sv = F.server(opts)
    local e = M.board(sv)
    F.scripted(sv, e)
    sv:run(0.6)
    return sv, e
end

-- Write the standard input and the board record, the way a scripted rider (the
-- bot, the headless harness) does. Anything omitted is neutral. `fwd` is the W / S
-- axis (W is +1) and `side` the raw A / D (D is +1); `w` and `s` say which of the
-- two forward keys are down where they differ from the axis (W with S).
function M.press(e, t)
    t = t or {}
    F.input(e, { throttle = t.throttle, brakeRear = t.brake, lean = t.lean })
    local b = e.input.board or {}
    e.input.board = b
    b.fwd, b.side = t.fwd or 0, t.side or 0
    b.w = t.w ~= nil and t.w or (b.fwd > 0)
    b.s = t.s ~= nil and t.s or (b.fwd < 0)
    b.jump, b.alt, b.grab, b.duck, b.swap = t.jump or false, t.alt or false,
        t.grab or false, t.duck or false, t.swap or false
    b.flickF, b.flickS = 0, 0
end

return M
