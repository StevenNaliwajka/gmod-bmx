--[[--------------------------------------------------------------------------
    What a bike COSTS, held to a budget.

    Every trace is engine work, and the physics step runs 66 times a second
    for every bike on the server. These count the traces one substep makes in
    each state a bike is in, and fail when a change makes any state dearer
    than its budget -- the way the grind search once cost 27 a substep for
    every airborne bike, jumping over nothing (now ~4), and a grind 43 (~25).
    The budgets carry headroom; they catch a doubling, not noise.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

-- A server whose traces are counted.
local function counted(opts)
    local sv = F.server(opts)
    local E = sv.env
    local n = { 0 }
    local tl, th = E.util.TraceLine, E.util.TraceHull
    E.util.TraceLine = function(t) n[1] = n[1] + 1 return tl(t) end
    E.util.TraceHull = function(t) n[1] = n[1] + 1 return th(t) end
    local bike = F.bike(sv)
    F.scripted(sv, bike)
    sv:run(0.5)
    return sv, bike, n
end

-- Traces per tick over `secs`.
local function rate(sv, n, secs)
    n[1] = 0
    local ticks = math.max(1, math.floor(secs / sv.world.dt + 0.5))
    sv:run(secs)
    return n[1] / ticks
end

-- In the air at `height` over the ground below the origin, moving along +x.
local function airborne(sv, bike, height)
    local E = sv.env
    F.place(bike, E.Vector(0, 0, height), E.Angle(0, 0, 0))
    bike:GetPhysicsObject():SetVelocity(E.Vector(250, 0, 0))
    bike.st.grounded = false
end

T.test("perf: parked and riding cost the two wheel traces", function()
    local sv, bike, n = counted()
    T.between(rate(sv, n, 1), 0, 2.5, "parked, rider aboard: traces a tick")
    F.input(bike, { throttle = 1 })
    T.between(rate(sv, n, 1), 0, 2.5, "riding on the flat: traces a tick")
end)

T.test("perf: in the air, the grind search is nearly free unless a rail might be there", function()
    local sv, bike, n = counted()
    airborne(sv, bike, 200)
    -- The wheels (2), the grind pre-check (1) and the landing look-ahead
    -- (3 traces every third substep, sv_air.lua) = ~4.
    T.between(rate(sv, n, 0.2), 0, 4.5, "high in the air: traces a tick")
    airborne(sv, bike, 30)
    T.between(rate(sv, n, 0.2), 0, 8, "just over flat ground: traces a tick")

    local sv2, bike2, n2 = counted({ groundSlope = 30 })
    local E = sv2.env
    F.place(bike2, E.Vector(0, 0, 25), E.Angle(0, 90, 0))
    bike2:GetPhysicsObject():SetVelocity(E.Vector(0, 250, 0))
    bike2.st.grounded = false
    T.between(rate(sv2, n2, 0.2), 0, 8, "just over a 30-degree ramp: traces a tick")
end)

T.test("perf: grinding follows the rail for ~25 traces a substep", function()
    local E0 = F.server().env
    local sv, bike, n = counted({ solids = { { E0.Vector(-3000, -1, 28), E0.Vector(3000, 1, 30) } } })
    local E = sv.env
    local crank = E.BMX.GrindCrankPoint(bike:Cfg())
    F.place(bike, E.Vector(-2000, 0, 34 - crank.z), E.Angle(0, 0, 0))
    bike:GetPhysicsObject():SetVelocity(E.Vector(300, 0, -20))
    bike.st.grounded = false
    sv:run(0.3)
    T.ok(bike.st.grind, "grinding")
    T.between(rate(sv, n, 1), 0, 30, "grinding: traces a tick")
    T.ok(bike.st.grind, "still grinding after the measured second")
end)

--------------------------------------------------------------------------
-- The CLIENT: what one bike costs to draw, by distance (cl_init.lua LOD).
--------------------------------------------------------------------------
local function drawAt(dist, lodScale)
    local sv, world = F.server()
    local bike = F.bike(sv)
    sv:run(0.3)
    local cl = F.client(world)
    local E = cl.env
    if lodScale then E.GetConVar("bmx_lod_scale"):SetFloat(lodScale) end
    local cb = cl:clientEntity("bmx_base")
    cb:SetPos(bike:GetPos())
    cb:SetAngles(bike:GetAngles())
    cb:SetGrounded(true)
    cl.eyePos = bike:GetPos() + E.Vector(0, -dist, 20)
    cl.lines, cl.beams, cl.drawnModels, cl.boxes3d = 0, {}, 0, 0
    cl.drawnCS = {}
    local traces = 0
    local tl = E.util.TraceLine
    E.util.TraceLine = function(t) traces = traces + 1 return tl(t) end
    cb:Draw()
    E.util.TraceLine = tl
    local tyres = 0
    for _, d in ipairs(cl.drawnCS) do if d.model:find("tire") then tyres = tyres + 1 end end
    return #cl.drawnCS, traces, tyres, cb, cl
end

T.test("perf: a bike's draw cost falls with distance, and it is still a bike far away", function()
    local near, tNear, tyNear = drawAt(200)
    local mid, tMid, tyMid = drawAt(1500)
    local far, tFar, tyFar, cb = drawAt(4000)
    T.between(near, 45, 70, "near: model draws a frame")
    T.between(mid, 0, near * 0.7, "mid: at most 70% of near (" .. near .. ")")
    T.between(far, 0, near * 0.45, "far: at most 45% of near")
    T.ok(far >= 12, "but far still draws frame, fork, bars and seat: " .. far)
    T.eq(tyNear, 2, "near: both tyres")
    T.eq(tyMid, 2, "mid: both tyres")
    T.eq(tyFar, 2, "far: both tyres")
    T.eq(tFar, 0, "far: no ground traces for the wheels")
    T.ok(tNear >= 2, "near: the wheels are traced to the ground")
    if os.getenv("BMX_TRACE") then
        print(string.format("    draws near %d / mid %d / far %d; traces %d / %d / %d", near, mid, far, tNear, tMid, tFar))
    end
end)

T.test("perf: the rider's hand and foot targets do not depend on the level of detail", function()
    local _, _, _, cbN = drawAt(200)
    local _, _, _, cbF = drawAt(4000)
    local function targets(cb)
        for k, v in pairs(cb) do
            if type(v) == "table" and v.rFoot and v.lFoot and v.rHand then return v end
        end
    end
    local a, b = targets(cbN), targets(cbF)
    T.ok(a and b, "targets recorded at both distances")
    if a and b then
        for _, key in ipairs({ "rFoot", "lFoot", "rHand", "lHand" }) do
            T.ok(a[key] and b[key], key .. " at both")
        end
    end
end)

T.test("perf: bmx_lod_scale 0 is full detail at any distance", function()
    local near = drawAt(200)
    local farFull = drawAt(4000, 0)
    T.eq(farFull, near, "4000 units away with LOD off draws what near does")
end)
