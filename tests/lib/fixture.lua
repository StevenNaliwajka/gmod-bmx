--[[--------------------------------------------------------------------------
    tests/lib/fixture.lua

    Worlds, realms, bikes and riders, built the same way every time.
----------------------------------------------------------------------------]]

local gmod = require("lib.gmod")

local F = {}

-- A booted server realm on its own world.
function F.server(opts)
    local world = gmod.World(opts)
    local sv = gmod.Realm(world, "server"):boot()
    return sv, world
end

-- A booted client realm sharing `world` with a server.
function F.client(world)
    return gmod.Realm(world, "client"):boot()
end

-- Where the bike's origin sits at rest: one wheel radius up, less the static
-- sag. The same derivation the headless suite spawns at.
function F.restHeight(sv)
    local C = sv.env.BMX.Config
    local sag = C.Chassis.mass * sv.world.gravity * 0.5 / C.Wheel.spring
    return C.Wheel.radius - sag
end

-- A spawned bike, upright, facing +X, at its resting height.
function F.bike(sv, class, pos)
    local e = sv.env.ents.Create(class or "bmx_base")
    e:SetPos(pos or sv.env.Vector(0, 0, sv.world.groundZ + F.restHeight(sv)))
    e:SetAngles(sv.env.Angle(0, 0, 0))
    e:Spawn()
    e:Activate()
    return e
end

-- A player in the bike's seat.
function F.rider(sv, bike, opts)
    local ply = sv:player((opts and opts.name) or "Rider", opts)
    ply:EnterVehicle(bike:GetPod())
    return ply
end

-- A SCRIPTED rider, as the headless harness makes one: StartCommand leaves
-- bike.input alone, and the test writes it.
function F.scripted(sv, bike)
    local ply = F.rider(sv, bike, { bot = true, name = "BMXTestBot" })
    ply.BMXScripted = true
    return ply
end

-- Write the rider's input the way Ctx:input does in sv_test.lua: anything
-- omitted is neutral.
function F.input(bike, t)
    t = t or {}
    local i = bike.input
    i.throttle    = t.throttle   or 0
    i.brakeRear   = t.brakeRear  or 0
    i.brakeFront  = t.brakeFront or 0
    i.leanTarget  = t.lean       or 0
    i.pitchTarget = t.pitch      or 0
    i.tuck        = t.tuck       or false
    i.sprint      = t.sprint     or false
    i.wheelieMod  = t.wheelieMod or false
end

-- Move a SPAWNED bike, the way the engine requires: through its physics
-- object. Entity:SetPos/SetAngles are ignored once a body exists (see gmod.lua).
function F.place(bike, pos, ang)
    local p = bike:GetPhysicsObject()
    if ang then p:SetAngles(ang) end
    if pos then p:SetPos(pos) end
end

-- Knock a bike over: dropped onto its side from high enough that nothing
-- starts inside the ground. (Placing it on its side at ride height put the
-- lower bar end inside the floor, and resolving that flicked it upright.)
function F.layDown(sv, bike, yaw)
    local E = sv.env
    F.place(bike, bike:GetPos() + E.Vector(0, 0, 24), E.Angle(0, yaw or 0, 88))
end

function F.wheels(bike)
    local f, r
    for _, w in ipairs(bike.wheels) do
        if w.isFront then f = w else r = w end
    end
    return f, r
end

-- Ride at `speed` u/s: throttle until there, then hand back. Returns whether it
-- got there in `timeout` seconds.
function F.accelerateTo(sv, bike, speed, timeout)
    F.input(bike, { throttle = 1 })
    return sv:run(timeout or 15, function() return bike.st.speed >= speed end)
end

return F
