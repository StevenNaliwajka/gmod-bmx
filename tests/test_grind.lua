--[[--------------------------------------------------------------------------
    Grinding (sv_grind.lua), on the shim's plant with box "rails" in the world.

    The boxes are traced against but not collided with: on a rail the bike is
    placed, not pushed, so what is tested is where it is put and when it lets
    go. Sloped and curved rails are a real-map question for the headless suite.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

-- A world with `solids`, a ridden bike, and the crank contact point.
local function world(solids)
    local sv = F.server({ solids = solids })
    local bike = F.bike(sv)
    local ply = F.scripted(sv, bike)
    sv:run(0.3)
    return sv, bike, ply
end

-- Put the bike in the air with its crank contact `above` units over (x, y, z)
-- (z = the rail top), facing `yaw`, moving at `vel`.
local function launch(sv, bike, x, y, z, above, yaw, vel)
    local E = sv.env
    local crank = E.BMX.GrindCrankPoint(bike:Cfg())
    local ang = E.Angle(0, yaw or 0, 0)
    local off = ang:Forward() * crank.x - ang:Right() * crank.y + ang:Up() * crank.z
    F.place(bike, E.Vector(x, y, z + above) - off, ang)
    bike:GetPhysicsObject():SetVelocity(vel)
    bike.st.grounded, bike.st.groundedFor = false, 0
end

-- Collect what the bike pays out.
local function tricksOf(bike)
    local got = {}
    local orig = bike.AwardTricks
    bike.AwardTricks = function(self, list)
        for _, t in ipairs(list) do got[#got + 1] = t end
        return orig(self, list)
    end
    return got
end

-- A 2x2 pipe along x, top at z = 30.
local PIPE = function(E, len) return { E.Vector(-(len or 300), -1, 28), E.Vector(len or 300, 1, 30) } end

local function axles(bike)
    local half = bike:Cfg().Wheel.wheelbase * 0.5
    return bike:LocalToWorld(bike.Vector and bike.Vector(half, 0, 0) or nil)
end

T.test("grind: hop onto a pipe along it -> a crank grind, wheels either side", function()
    local sv0 = F.server()
    local E = sv0.env
    local sv, bike, ply = world({ PIPE(E) })
    E = sv.env
    local got = tricksOf(bike)
    launch(sv, bike, -200, 0.5, 30, 5, 8, E.Vector(300, 0, -40))
    local locked
    sv:run(0.3, function() locked = locked or bike.st.grind end)
    T.ok(locked, "locked on")
    T.eq(bike.st.grind and bike.st.grind.kind, "crank", "a crank grind")
    sv:run(0.3)
    T.ok(bike.st.grind, "still grinding")
    T.eq(bike:GetGrind(), 1, "networked as a crank grind")
    local crank = bike:LocalToWorld(E.BMX.GrindCrankPoint(bike:Cfg()))
    T.between(crank.z - 30, 0, 1, "chainring on the pipe's top, units above it")
    T.between(math.abs(crank.y), 0, 0.6, "and on its centre line")
    local half = bike:Cfg().Wheel.wheelbase * 0.5
    local fy = bike:LocalToWorld(E.Vector(half, 0, 0)).y
    local ry = bike:LocalToWorld(E.Vector(-half, 0, 0)).y
    T.ok(fy * ry < 0, "front and rear wheels on opposite sides: " .. fy .. " / " .. ry)
    T.between(math.min(math.abs(fy), math.abs(ry)), 5, 12, "each well clear of the pipe")
    T.between(bike:GetPhysicsObject():GetVelocity().x, 200, 320, "sliding along it, u/s")
    T.ok(E.IsValid(bike:GetDriver()), "rider aboard")
    T.eq(#sv.errors, 0, "no errors: " .. table.concat(sv.errors, " | "))

    -- Off the end: it lets go and carries on, and the grind is paid.
    sv:run(2.5, function() end)
    T.ok(not bike.st.grind, "let go at the end of the pipe")
    T.eq(bike:GetGrind(), 0, "networked off")
    T.ok(bike:GetPhysicsObject():GetVelocity().x > 100, "still moving on")
    local paid
    for _, t in ipairs(got) do if t.name == "Crank Grind" then paid = t end end
    T.ok(paid and paid.points > 100, "a Crank Grind was paid: " .. tostring(paid and paid.points))
    T.ok(E.IsValid(bike:GetDriver()), "rider still aboard")
end)

T.test("grind: the jump key hops off the rail", function()
    local sv0 = F.server()
    local sv, bike = world({ PIPE(sv0.env, 2000) })
    local E = sv.env
    launch(sv, bike, -200, 0, 30, 4, 0, E.Vector(300, 0, -20))
    sv:run(0.4)
    T.ok(bike.st.grind, "grinding")
    bike.hopRelease = true
    sv:tick()
    T.ok(not bike.st.grind, "off")
    T.ok(bike:GetPhysicsObject():GetVelocity().z > 100, "popped up: " .. bike:GetPhysicsObject():GetVelocity().z)
    T.ok(E.IsValid(bike:GetDriver()), "rider aboard")
    sv:run(0.2)
    T.ok(not bike.st.grind, "and does not lock straight back on")
end)

T.test("grind: a ledge edge -> double peg grind, hanging off the drop side", function()
    local sv0 = F.server()
    local E0 = sv0.env
    -- Top at z = 20, the edge along x at y = 0, the ledge over +y.
    local sv, bike = world({ { E0.Vector(-600, 0, 0), E0.Vector(600, 200, 20) } })
    local E = sv.env
    launch(sv, bike, -300, 2, 20, 6, 0, E.Vector(280, 0, -30))
    sv:run(0.4)
    local g = bike.st.grind
    T.ok(g, "locked on")
    T.eq(g and g.kind, "peg", "a peg grind")
    T.eq(bike:GetGrind(), 2, "pegs on the LEFT (the ledge is on +y, left when facing +x)")
    local half = bike:Cfg().Wheel.wheelbase * 0.5
    local f = bike:LocalToWorld(E.Vector(half, 0, 0))
    local r = bike:LocalToWorld(E.Vector(-half, 0, 0))
    T.between(f.y, -6, -3, "front wheel off the drop side, y")
    T.between(r.y, -6, -3, "rear wheel off the drop side, y")
    local peg = bike:LocalToWorld(E.Vector(half, bike:Cfg().Grind.pegY, bike:Cfg().Grind.pegZ))
    T.between(peg.y, 0, 2, "peg over the top, just in from the edge")
    T.between(peg.z - 20, 0, 1, "peg on the top")
end)

T.test("grind: no lock-on on flat ground, across a pipe, or too slow", function()
    local sv, bike = world({})
    local E = sv.env
    launch(sv, bike, 0, 0, 0, 6, 0, E.Vector(300, 0, -30))
    sv:run(1, function() T.ok(not bike.st.grind, "flat ground is not a rail") end)

    local sv0 = F.server()
    local sv2, bike2 = world({ PIPE(sv0.env) })
    E = sv2.env
    launch(sv2, bike2, 0, -60, 30, 5, 90, E.Vector(0, 300, -30))
    local any = false
    sv2:run(0.5, function() any = any or bike2.st.grind ~= nil end)
    T.ok(not any, "crossing a pipe at right angles does not grind")

    local sv3, bike3 = world({ PIPE(sv0.env) })
    E = sv3.env
    launch(sv3, bike3, -200, 0, 30, 4, 0, E.Vector(45, 0, -20))
    any = false
    sv3:run(0.5, function() any = any or bike3.st.grind ~= nil end)
    T.ok(not any, "too slow to lock on")
end)

T.test("grind: friction slows it, and it ends when too slow", function()
    local sv0 = F.server()
    local sv, bike = world({ PIPE(sv0.env, 3000) })
    local E = sv.env
    launch(sv, bike, -2500, 0, 30, 4, 0, E.Vector(120, 0, -20))
    sv:run(0.3)
    T.ok(bike.st.grind, "grinding")
    local v0 = bike.st.grind.speed
    sv:run(0.5)
    T.ok(bike.st.grind and bike.st.grind.speed < v0 - 10, "slowing")
    sv:run(3)
    T.ok(not bike.st.grind, "over once too slow")
end)

T.test("grind: touching the rail is not a crash, and nobody aboard ends it", function()
    local sv0 = F.server()
    local sv, bike, ply = world({ PIPE(sv0.env, 2000) })
    local E = sv.env
    launch(sv, bike, -200, 0, 30, 4, 0, E.Vector(300, 0, -20))
    sv:run(0.3)
    T.ok(bike.st.grind, "grinding")
    sv.world.time = sv.world.time + 5          -- well past the spawn grace
    bike:PhysicsCollide({ Speed = 3000, HitPos = bike:GetPos(), HitEntity = E.NULL,
                          OurOldVelocity = E.Vector() }, bike:GetPhysicsObject())
    T.ok(not bike.crashPending, "no crash queued")
    ply:ExitVehicle()
    sv:tick()
    T.ok(not bike.st.grind, "the grind ends with the rider gone")
end)

T.test("grind: a bare ramp is not an edge, at any slope or heading", function()
    -- A ramp's surface falls away to one side of every point on it, which the
    -- first edge finder took for a ledge: flying across a 15-40 degree slope
    -- locked the bike into a peg grind on nothing, pinned into the ramp.
    local bad = {}
    for _, d in ipairs({ 10, 15, 25, 30, 40, 50 }) do
        for _, yaw in ipairs({ 0, 45, 60, 90, 180, 270 }) do
            local sv = F.server({ groundSlope = d })
            local E = sv.env
            local bike = F.bike(sv)
            F.scripted(sv, bike)
            sv:run(0.2)
            F.place(bike, E.Vector(0, 0, 14), E.Angle(0, yaw, 0))
            bike:GetPhysicsObject():SetVelocity(E.Angle(0, yaw, 0):Forward() * 250 + E.Vector(0, 0, -20))
            bike.st.grounded = false
            local g
            sv:run(0.4, function() g = g or (bike.st.grind and bike.st.grind.kind) end)
            if g then bad[#bad + 1] = d .. " deg / yaw " .. yaw end
        end
    end
    T.eq(#bad, 0, "false grinds: " .. table.concat(bad, ", "))
end)
