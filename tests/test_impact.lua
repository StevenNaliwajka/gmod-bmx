--[[--------------------------------------------------------------------------
    Riding into something that stays put: a post, a goal, a kerb's face.

    A rider: "when I drive into a post/goal or bump with the bike the bike
    freaks out and does some weird physics thing and flings sometimes or clips
    through the floor". Measured on a real server (a 12-unit pole at 300 u/s):
    VPhysics stops the hull at its front wheel box, low and ahead of the mass
    centre, and the bike came out of that substep spinning over its bars at
    770 deg/s and lifting at 110 u/s; the front strut caught the nose at seven
    times its static load and the bike went up, round 40 degrees and back down
    5 units into the floor.

    The offline plant has no hull to collide, so the hit is written in the way
    VPhysics hands it over: the substep's motion replaced by the post-hit one,
    and the collision noted through ENT:NoteImpact, exactly as PhysicsCollide
    calls it. Crash.impactSoak (sv_physics.lua, 2c) is what is held here.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

-- A ridden bike at speed, and the hit: what VPhysics left it with on the
-- substep it met a post head-on, as measured.
local function hitPost(soak)
    local sv = F.server()
    local E = sv.env
    local bike = F.bike(sv)
    F.scripted(sv, bike)
    bike:Cfg().Crash.impactSoak = soak
    sv:run(0.5)
    F.accelerateTo(sv, bike, 280, 6)
    F.input(bike, { throttle = 0.5 })
    sv:run(0.2)
    local phys = bike:GetPhysicsObject()
    local z0 = phys:LocalToWorld(phys:GetMassCenter()).z
    phys:SetVelocity(E.Vector(65, 0, 110))
    phys:SetAngleVelocity(E.Vector(0, 770, -90))
    bike:NoteImpact({ Speed = 295, HitNormal = E.Vector(1, 0, 0), HitEntity = E.game.GetWorld() },
        bike:Cfg().Crash)
    return sv, E, bike, phys, z0
end

local function outcome(sv, bike, phys, z0)
    local rise, spin = 0, 0
    sv:run(1.5, function()
        rise = math.max(rise, phys:LocalToWorld(phys:GetMassCenter()).z - z0)
        spin = math.max(spin, phys:GetAngleVelocity():Length())
    end)
    return rise, spin
end

T.test("impact: a post hit head-on stops the bike without flinging it", function()
    local sv, E, bike, phys, z0 = hitPost(true)
    T.ok(bike.bmxImpact ~= nil, "the hit was noted for the next substep")
    -- The very next tick: the soak has run.
    sv:run(sv.world.dt)
    T.ok(bike.bmxImpact == nil, "and soaked")
    T.between(phys:GetVelocity().z, -1e9, 60, "upward speed after the hit, u/s (was 110)")
    T.between(phys:GetAngleVelocity():Length(), 0, 250, "spin after the hit, deg/s (was 770)")
    local rise = outcome(sv, bike, phys, z0)
    T.between(rise, -1e9, 6, "mass centre rise after the hit, units")
    T.between(math.deg(math.abs(bike.st.roll)), 0, 15, "roll after, deg")
    T.between(math.deg(math.abs(bike.st.pitch)), 0, 15, "pitch after, deg")
    T.ok(F.wheels(bike) ~= nil and bike:GetDriver() ~= nil, "rider still aboard")
end)

T.test("impact: without the soak the same hit throws the bike up (the test can see the bug)", function()
    local sv, E, bike, phys, z0 = hitPost(false)
    local rise = outcome(sv, bike, phys, z0)
    T.between(rise, 6, 1e9, "mass centre rise with impactSoak off, units")
end)

T.test("impact: the soak leaves the hit's stop alone and takes off the bounce back", function()
    local sv = F.server()
    local E = sv.env
    local bike = F.bike(sv)
    F.scripted(sv, bike)
    sv:run(0.5)
    F.accelerateTo(sv, bike, 250, 6)
    local phys = bike:GetPhysicsObject()
    -- Bounced straight back off a wall at 120 u/s.
    phys:SetVelocity(E.Vector(-120, 0, 0))
    bike:NoteImpact({ Speed = 250, HitNormal = E.Vector(1, 0, 0), HitEntity = E.game.GetWorld() },
        bike:Cfg().Crash)
    sv:run(sv.world.dt)
    T.between(phys:GetVelocity().x, -bike:Cfg().Crash.impactBounce - 5, 5,
        "speed coming back off the wall, u/s (was -120)")
end)

T.test("impact: only side hits on things that stay put, with a rider, are soaked", function()
    local sv = F.server()
    local E = sv.env
    local bike = F.bike(sv)
    local CR = bike:Cfg().Crash
    local world = E.game.GetWorld()
    -- No rider: nothing.
    bike:NoteImpact({ Speed = 300, HitNormal = E.Vector(1, 0, 0), HitEntity = world }, CR)
    T.ok(bike.bmxImpact == nil, "a riderless bike is left to VPhysics")
    F.scripted(sv, bike)
    sv:run(0.3)
    -- The floor (a landing) is not an impact.
    bike:NoteImpact({ Speed = 300, HitNormal = E.Vector(0, 0, -1), HitEntity = world }, CR)
    T.ok(bike.bmxImpact == nil, "a hit from below is a landing, not an impact")
    -- Too slow to matter.
    bike:NoteImpact({ Speed = 10, HitNormal = E.Vector(1, 0, 0), HitEntity = world }, CR)
    T.ok(bike.bmxImpact == nil, "a nudge is left alone")
    -- Something moving into the bike (a car, a thrown prop) still pushes it.
    local prop = E.ents.Create("prop_physics")
    prop:Spawn()
    bike:NoteImpact({ Speed = 300, HitNormal = E.Vector(1, 0, 0), HitEntity = prop,
        TheirOldVelocity = E.Vector(-400, 0, 0) }, CR)
    T.ok(bike.bmxImpact == nil, "a moving thing hitting the bike is not soaked")
    -- A post: soaked.
    bike:NoteImpact({ Speed = 300, HitNormal = E.Vector(0.8, 0.6, 0.1), HitEntity = world }, CR)
    T.ok(bike.bmxImpact ~= nil, "a post from the side is soaked")
    T.near(bike.bmxImpact.normal.z, 0, 1e-9, "along the ground")
end)

--------------------------------------------------------------------------
-- THE LANDING AFTER THE BUMP. Off an 8-unit bump at 300 u/s (real server)
-- the bike came down 32 degrees nose-first on the front wheel with too little
-- air for the air assist to level it, and the landing's pitch assist
-- (Crash.recoverPitchKp/Kd) -- sized as if the front axle were a hinge, on a
-- strut that had not taken the load yet -- turned the free body 7 times too
-- hard: past level onto the rear wheel at 900 deg/s, back at 1000, 1240,
-- over. Here the touchdown is set up as it was, recovery window open.
--------------------------------------------------------------------------
T.test("impact: a nose-first touchdown off a bump levels without see-sawing", function()
    for _, deg in ipairs({ 20, 32, 40 }) do
        local sv = F.server()
        local E = sv.env
        local bike = F.bike(sv)
        F.scripted(sv, bike)
        sv:run(0.5)
        F.input(bike, { throttle = 0.5 })
        local C = bike:Cfg()
        local phys = bike:GetPhysicsObject()
        -- Pitched nose-down about the front axle, the front tyre just on the ground.
        local half, r = C.Wheel.wheelbase * 0.5, C.Wheel.radius
        local a = math.rad(deg)
        local axleZ = sv.world.groundZ + r
        local origin = E.Vector(-half * math.cos(a) + half, 0, axleZ + half * math.sin(a))
        phys:SetAngles(E.Angle(deg, 0, 0))
        phys:SetPos(origin)
        phys:SetVelocity(E.Vector(200, 0, -50))
        phys:SetAngleVelocity(E.Vector(0, 0, 0))
        bike.st.recoverUntil = E.CurTime() + C.Crash.recoverTime
        bike.st.landedAt = E.CurTime()
        local peakRate, past = 0, 0
        sv:run(1.2, function()
            peakRate = math.max(peakRate, math.abs(phys:GetAngleVelocity().y))
            past = math.max(past, math.deg(bike.st.pitch or 0))     -- nose UP past level
        end)
        local label = string.format("%d deg nose-down on the front wheel", deg)
        T.between(past, -1e9, 12, label .. ": furthest nose-up past level after, deg")
        T.between(peakRate, 0, 400, label .. ": fastest pitch, deg/s (was 900+)")
        T.between(math.deg(math.abs(bike.st.pitch)), 0, 8, label .. ": pitch at the end, deg")
        T.ok(bike:GetDriver() ~= nil, label .. ": rider still aboard")
    end
end)

--------------------------------------------------------------------------
-- A WHEEL THAT COMES BACK DOWN PAST ITS TRAVEL. Cresting an 18-unit hump
-- nose-down (real server) the rear wheel was off the ground for a few ticks
-- and came back with the slope already 4 units past its full travel: the
-- bump stop answered at the 309,600 ceiling and threw the bike over its bars.
-- A fresh contact while riding (not landing) is held to full travel; the
-- rest is the wheel box's to meet.
--------------------------------------------------------------------------
T.test("impact: a wheel finding the ground past its travel does not fire the bump stop", function()
    local sv = F.server()
    local E = sv.env
    local bike = F.bike(sv)
    F.scripted(sv, bike)
    sv:run(0.5)
    local C = bike:Cfg()
    local phys = bike:GetPhysicsObject()
    -- Sunk 4 units past full travel, both wheels coming to it fresh.
    local z = sv.world.groundZ + F.restHeight(sv) - (C.Wheel.restLength - bike.wheels[1].compression) - 4
    F.place(bike, E.Vector(0, 0, z), E.Angle(0, 0, 0))
    phys:SetVelocity(E.Vector(150, 0, 0))
    phys:SetAngleVelocity(E.Vector(0, 0, 0))
    for _, w in ipairs(bike.wheels) do w.lastComp = nil end
    bike.st.recoverUntil, bike.st.airMode = 0, false
    sv:run(sv.world.dt)
    local ceiling = C.Wheel.spring * C.Wheel.restLength * 2
    for i, w in ipairs(bike.wheels) do
        T.between(w.load, 0, ceiling, (i == 1 and "front" or "rear") .. " strut on its first contact (bump stop: 240,000+)")
    end
    local up = 0
    sv:run(0.3, function() up = math.max(up, phys:GetVelocity().z) end)
    T.between(up, -1e9, 150, "thrown up by it, u/s")
end)
