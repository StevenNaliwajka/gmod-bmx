--[[--------------------------------------------------------------------------
    Air control off a vert ramp (G06): what the takeoff was, the turn about
    the ramp face's normal that settles on a half turn, the landing aim, the spine transfer.

    The classifier and the spine finder are pure (sv_launch.lua), so they get
    synthetic normals and a made-up profile. The turn and the transfer are
    flown on the shim's plant, high enough that nothing is touched for seconds,
    with the takeoff kind set the way sv_physics.lua would set it. What the
    plant cannot say is how a park quarter pipe's coping launches a real bike:
    the headless cases vert_turnaround and spine_transfer ask that.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local function V(E, x, y, z) return E.Vector(x, y, z) end

-- The surface normal of a face rising `deg` along +x (leaning back toward -x).
local function face(E, deg)
    local a = math.rad(deg)
    return E.Vector(-math.sin(a), 0, math.cos(a))
end

--------------------------------------------------------------------------
-- The classifier
--------------------------------------------------------------------------
T.test("launch kind: a steep wall left upward is vert, a slope is a ramp, level ground is flat", function()
    local sv = F.server()
    local E, L = sv.env, sv.env.BMX.Launch
    T.eq(L.Classify(face(E, 70), V(E, 120, 0, 300)), "vert", "a 70 degree wall, going up")
    T.eq(L.Classify(face(E, 62), V(E, 200, 0, 330)), "vert", "62 degrees, going up")
    T.eq(L.Classify(face(E, 30), V(E, 300, 0, 160)), "ramp", "a 30 degree kicker")
    T.eq(L.Classify(face(E, 59), V(E, 200, 0, 330)), "ramp", "59 degrees is under the vert line")
    T.eq(L.Classify(face(E, 12), V(E, 300, 0, 60)), "ramp", "a 12 degree slope")
    T.eq(L.Classify(face(E, 4), V(E, 300, 0, 40)), "flat", "4 degrees is a bump")
    T.eq(L.Classify(E.Vector(0, 0, 1), V(E, 300, 0, 120)), "flat", "a hop off level ground")
    T.eq(L.Classify(nil, V(E, 300, 0, 120)), "flat", "no surface remembered")
end)

T.test("launch kind: leaving a wall sideways or downward is not vert", function()
    local sv = F.server()
    local E, L = sv.env, sv.env.BMX.Launch
    T.eq(L.Classify(face(E, 75), V(E, 300, 0, 80)), "ramp", "off a wall moving mostly along it")
    T.eq(L.Classify(face(E, 75), V(E, 300, 0, -50)), "ramp", "or falling off it")
    T.eq(L.Classify(face(E, 75), V(E, 0, 0, 0)), "ramp", "or not moving")
end)

T.test("launch kind: air mode engaging stores it, from the surface left and the velocity then", function()
    local sv = F.server()
    local E = sv.env
    local bike = F.bike(sv)
    F.scripted(sv, bike)
    sv:run(0.3)
    local function takeoff(vel)
        F.place(bike, V(E, 0, 0, sv.world.groundZ + 4000), E.Angle(0, 0, 0))
        local p = bike:GetPhysicsObject()
        p:SetVelocity(vel)
        p:SetAngleVelocity(V(E, 0, 0, 0))
        bike.st.angVel, bike.st.prevF = V(E, 0, 0, 0), nil
        bike.st.grounded, bike.st.airMode = false, false
        bike.st.launchNormal = face(E, 70)
        F.input(bike, {})
        sv:run(0.3)
        T.ok(bike.st.airMode, "air mode engaged")
        return bike.st.launchKind
    end
    T.eq(takeoff(V(E, 120, 0, 320)), "vert", "up the wall it just left")
    T.eq(takeoff(V(E, 320, 0, 20)), "ramp", "off the same surface sideways")
end)

--------------------------------------------------------------------------
-- Flying it
--------------------------------------------------------------------------
-- A bike in the air high above the plant's ground, marked as the given kind.
local function flying(kind, opts)
    opts = opts or {}
    local sv = F.server()
    local E = sv.env
    local bike = F.bike(sv)
    F.scripted(sv, bike)
    sv:run(0.3)
    F.place(bike, V(E, 0, 0, sv.world.groundZ + (opts.height or 6000)), E.Angle(0, opts.yaw or 0, 0))
    local p = bike:GetPhysicsObject()
    p:SetVelocity(opts.vel or V(E, 120, 0, 60))
    p:SetAngleVelocity(V(E, 0, 0, 0))
    bike.st.angVel, bike.st.prevF = V(E, 0, 0, 0), nil
    bike.st.grounded, bike.st.airMode = false, false
    F.input(bike, {})
    sv:run(0.2)
    T.ok(bike.st.airMode, "air mode engaged")
    bike.st.launchKind = kind
    bike.st.launchNormal = face(E, 70)
    bike.st.launchZ = bike:GetPos().z
    return sv, bike
end

local function heading(bike)
    local f = bike:GetForward()
    return math.deg(math.atan2(f.y, f.x))
end

T.test("vert turn: a tap of D comes round to a half turn and stops there", function()
    local sv, bike = flying("vert")
    F.input(bike, { lean = 1 })
    sv:run(0.3)
    F.input(bike, {})
    sv:run(2.2)
    T.near(bike.st.vertSpin, -math.pi, 0.3, "the turn settled on a half turn, clockwise for D (rad)")
    T.ok(math.abs(math.abs(heading(bike)) - 180) < 20, "facing back the way it came: " .. heading(bike))
    T.ok(math.abs(bike.st.angVel:Dot(sv.env.Vector(0, 0, 1))) < 0.3, "and it has stopped turning")
    T.eq(#sv.errors, 0, "no errors: " .. table.concat(sv.errors, " | "))
end)

-- Off a tall park quarter pipe a vert flight is half a second: the turn has to answer
-- the key at once (not the ground lean's third-of-a-second ramp), turn about its axis
-- and nothing else (not the roll damping's share of it), and then bring the bike over
-- onto the face it is coming back down (the drop, Air.vertDropStart). Real server:
-- vert_turnaround.
T.test("vert turn: nose up off a wall, a quick D: a half turn and back over onto the face in half a second", function()
    local sv, bike = flying("vert")
    local E = sv.env
    local p = bike:GetPhysicsObject()
    p:SetAngles(E.Angle(-80, 0, 0))
    p:SetVelocity(V(E, 30, 0, 140))
    bike.st.angVel, bike.st.prevF = V(E, 0, 0, 0), nil
    F.input(bike, { lean = 1 })
    local turned
    sv:run(0.4, function()
        if not turned and math.abs(bike.st.vertSpin or 0) > 1.0 then
            turned = true
            F.input(bike, {})
        end
        return false
    end)
    T.ok(turned, "the key turned it past a radian within 0.4 s")
    sv:run(0.3)
    local n = face(E, 70)
    local fall = (-(E.Vector(0, 0, 1) - n * n.z)):GetNormalized()
    T.between(math.abs(math.deg(bike.st.vertSpin)), 130, 230, "turned about the face's normal, deg")
    T.ok(bike.st.vertDrop, "the drop took over on the way down")
    T.ok(bike:GetUp():Dot(n) > 0.7, string.format("wheels to the face: up . normal = %.2f", bike:GetUp():Dot(n)))
    T.ok(bike:GetForward():Dot(fall) > 0.7, string.format("pointing down it: forward . fall line = %.2f", bike:GetForward():Dot(fall)))
    T.eq(#sv.errors, 0, "no errors: " .. table.concat(sv.errors, " | "))
end)

T.test("vert turn: A turns the other way, to the same half turn", function()
    local sv, bike = flying("vert")
    F.input(bike, { lean = -1 })
    sv:run(0.3)
    F.input(bike, {})
    sv:run(2.2)
    T.near(bike.st.vertSpin, math.pi, 0.3, "counter-clockwise (rad)")
end)

T.test("vert turn: held, it goes on past a half turn", function()
    -- going up for the whole of it, so it is the settle that is measured and not
    -- the landing aim, which takes over coming down
    local sv, bike = flying("vert")
    bike:GetPhysicsObject():SetVelocity(sv.env.Vector(0, 0, 1800))
    F.input(bike, { lean = 1 })
    sv:run(1.4)
    T.ok(math.abs(bike.st.vertSpin) > math.pi * 1.5, "well past 180 with the key held: " .. math.deg(bike.st.vertSpin))
    F.input(bike, {})
    sv:run(1.5)
    local n = math.abs(bike.st.vertSpin) / math.pi
    T.near(n, math.floor(n + 0.5), 0.12, "and it settles on a whole number of half turns")
end)

T.test("vert turn: a brush of the key under 35 degrees settles back where it started", function()
    local sv, bike = flying("vert")
    F.input(bike, { lean = 1 })
    sv:run(0.06)
    F.input(bike, {})
    sv:run(1.5)
    T.near(bike.st.vertSpin, 0, 0.15, "back to nothing (rad)")
end)

T.test("vert turn: the barrel roll stays on A/D anywhere that is not vert", function()
    local sv, bike = flying("ramp")
    F.input(bike, { lean = 1 })
    sv:run(0.8)
    T.ok(math.abs(bike.st.spinRoll) > 1, "rolled: " .. bike.st.spinRoll)
    T.near(bike.st.vertSpin or 0, 0, 1e-6, "and nothing counted as a vert turn")
end)

T.test("vert turn: with RMB held A/D are still the 360, not the vert turn", function()
    local sv, bike = flying("vert")
    F.input(bike, { lean = 1, wheelieMod = true })
    sv:run(0.8)
    T.ok(math.abs(bike.st.spinYaw) > 1, "yawed about the bike's own axis: " .. bike.st.spinYaw)
    T.ok(not bike.st.vertTarget, "no vert target")
end)

T.test("air assist 0: A/D roll off vert too, and nothing is turned or paid", function()
    local sv, bike = flying("vert")
    sv.env.GetConVar("bmx_air_assist"):SetString("0")
    F.input(bike, { lean = 1 })
    sv:run(0.8)
    T.ok(math.abs(bike.st.spinRoll) > 1, "A/D rolled: " .. bike.st.spinRoll)
    T.near(bike.st.vertSpin or 0, 0, 1e-6, "no vert turn")
end)

T.test("vert landing aim: coming down turned part way round, it is aimed down the ramp it left", function()
    -- Wheels to the face it left (up along its normal), turned 60 degrees short of
    -- the fall line about that normal, coming down: the aim turns it the rest of the
    -- way about the same axis the turn is made about (sv_air.lua).
    local sv, bike = flying("vert", { height = 9000 })
    local E = sv.env
    local n = face(E, 70)
    local fall = (-(E.Vector(0, 0, 1) - n * n.z)):GetNormalized()
    local side = n:Cross(fall)
    local a = math.rad(60)
    local f0 = fall * math.cos(a) + side * math.sin(a)
    local p = bike:GetPhysicsObject()
    p:SetAngles(f0:AngleEx(n))
    p:SetVelocity(E.Vector(0, 0, -250))
    p:SetAngleVelocity(E.Vector(0, 0, 0))
    bike.st.angVel, bike.st.prevF = E.Vector(0, 0, 0), nil
    bike.st.vertSpin = 0
    F.input(bike, {})
    sv:run(1.8)
    local f = bike:GetForward()
    f = (f - n * f:Dot(n)):GetNormalized()
    local err = math.deg(math.acos(math.max(-1, math.min(1, f:Dot(fall)))))
    T.ok(err < 12, "within 12 degrees of the fall line, about the face's normal: " .. err)
end)

T.test("vert landing aim: a bike left facing the wall is the rider's to turn, not the assist's", function()
    local sv, bike = flying("vert", { yaw = 0, height = 9000 })
    bike:GetPhysicsObject():SetVelocity(sv.env.Vector(0, 0, -250))
    F.input(bike, {})
    sv:run(1.5)
    T.ok(math.abs(heading(bike)) < 15, "still facing the wall: " .. heading(bike))
end)

--------------------------------------------------------------------------
-- The spine
--------------------------------------------------------------------------
-- A spine along +x: the launch face rising to a coping at x = 100 (leaning back
-- toward -x, as a face the bike came up does), the far face dropping away
-- beyond it, level ground past that.
local function spineTrace(E, deg)
    local rise = math.tan(math.rad(deg))
    local up = face(E, deg)
    local down = E.Vector(math.sin(math.rad(deg)), 0, math.cos(math.rad(deg)))
    return function(p)
        if p.x < 100 then return math.max(0, p.x), up end
        local z = 100 - (p.x - 100) * rise
        if z > 0 then return z, down end
        return 0, E.Vector(0, 0, 1)
    end
end

T.test("spine: over the coping the far face is found, with the way down it", function()
    local sv = F.server()
    local E, L, C = sv.env, sv.env.BMX.Launch, sv.env.BMX.Config
    local sp = L.FindSpine(V(E, 108, 0, 190), face(E, 70), C, { trace = spineTrace(E, 70) })
    T.ok(sp, "found it")
    T.near(sp.normal.x, math.sin(math.rad(70)), 1e-6, "its normal leans the other way")
    T.ok(sp.dir.x > 0.2 and sp.dir.z < -0.5, "the way down a steep face is mostly down, a little forward: " .. sp.dir.x .. ", " .. sp.dir.z)
    T.near(sp.dir:Length(), 1, 1e-6, "a unit direction")
end)

T.test("spine: nothing over the coping, nothing found; and not from too far back or too far up", function()
    local sv = F.server()
    local E, L, C = sv.env, sv.env.BMX.Launch, sv.env.BMX.Config
    local launchFace = face(E, 70)
    -- A quarter pipe with a flat deck behind it: no mirrored surface at all.
    local deck = function(p)
        if p.x < 100 then return math.max(0, p.x), launchFace end
        return 100, E.Vector(0, 0, 1)
    end
    T.eq(L.FindSpine(V(E, 108, 0, 190), launchFace, C, { trace = deck }), nil, "a deck is not a spine")
    local trace = spineTrace(E, 70)
    T.eq(L.FindSpine(V(E, 10, 0, 190), launchFace, C, { trace = trace }), nil, "too far back: the far face is over 64 u away")
    T.eq(L.FindSpine(V(E, 108, 0, 600), launchFace, C, { trace = trace }), nil, "too far above it to drop in")
    T.eq(L.FindSpine(V(E, 108, 0, 190), nil, C, { trace = trace }), nil, "no launch normal, no spine")
    -- Its own launch face is never "the other side" of itself.
    T.eq(L.FindSpine(V(E, 30, 0, 190), launchFace, C, { trace = function(p) return math.max(0, p.x), launchFace end }),
        nil, "over its own face and nothing else")
end)

T.test("spine transfer: a fresh W near the apex carries the velocity over onto the far face", function()
    local sv, bike = flying("vert", { height = 6000 })
    local E = sv.env
    local dir = E.Vector(0.8, 0, -0.6)
    bike:GetPhysicsObject():SetVelocity(E.Vector(40, 0, 20))
    bike.st.spineTarget = { pos = E.Vector(120, 0, 0), normal = face(E, 70), dir = dir, dist = 16 }
    bike.st.spineSeen = sv.world.time
    F.input(bike, {})
    sv:run(0.1)
    T.ok(not bike.st.spineDone, "nothing happens without a press")
    F.input(bike, { pitch = -1 })
    sv:run(0.05)
    F.input(bike, {})
    sv:run(0.4)
    T.ok(bike.st.spineDone, "the press took")
    local v = bike:GetPhysicsObject():GetVelocity()
    T.ok(v:GetNormalized():Dot(dir) > 0.8, "moving down the far face: " .. v:GetNormalized():Dot(dir))
    T.ok(v:Length() >= 120, "at least the transfer speed: " .. v:Length())
    local paid = sv.env.BMX.ScoreAir(bike.st)
    local got
    for _, t in ipairs(paid) do if t.name == "Spine Transfer" then got = t end end
    T.ok(got, "scored as a Spine Transfer")
    T.eq(got and got.points, sv.env.BMX.Config.Air.spinePoints, "at the config's points")
    T.eq(#sv.errors, 0, "no errors: " .. table.concat(sv.errors, " | "))
end)

T.test("spine transfer: no press, no transfer", function()
    local sv, bike = flying("vert", { height = 6000 })
    local E = sv.env
    bike.st.spineTarget = { pos = E.Vector(120, 0, 0), normal = face(E, 70), dir = E.Vector(0.8, 0, -0.6), dist = 16 }
    bike.st.spineSeen = sv.world.time
    -- sv_input.lua zeroes a key held at takeoff until it is let go, so the
    -- air controller sees no W at all: the same here, no pitch input.
    F.input(bike, {})
    sv:run(0.5)
    T.ok(not bike.st.spineDone, "no transfer without a fresh press")
end)

T.test("spine transfer: it is an ordinary trick, so the combo stays alive across it", function()
    local sv, bike = flying("vert", { height = 8000 })
    bike:AwardTricks({ { name = "Air 180", count = 1, points = 220 } })
    bike:AwardTricks({ { name = "Spine Transfer", count = 1, points = 350 } })
    T.eq(bike.st.combo.n, 2, "two tricks in the chain")
    sv:run(1.6)         -- past Combo.grace, still in the air
    T.ok(bike.st.combo, "still open while the bike is in the air")
end)

T.test("vert tricks: Air 180 pays per half turn, more for height", function()
    local sv = F.server()
    local B = sv.env.BMX
    local A = B.Config.Air
    local function score(spin, height)
        local st = { launchKind = "vert", vertSpin = spin, airPeakZ = 1000 + height, launchZ = 1000 }
        local out = B.ScoreAir(st)
        for _, t in ipairs(out) do if t.name == "Air 180" then return t end end
    end
    local low, high = score(-math.pi * 1.02, 40), score(-math.pi * 1.02, 160)
    T.ok(low and high, "paid")
    T.eq(low.count, 1, "one half turn")
    T.eq(low.points, math.floor(A.vertBase + A.vertPerUnit * 40), "the base plus a share per unit of height")
    T.ok(high.points > low.points, "higher is worth more")
    T.eq(score(-math.pi * 2.05, 40).count, 2, "two half turns")
    T.eq(score(-0.3, 40), nil, "a brush is not a trick")
    local st = { launchKind = "ramp", vertSpin = -math.pi, airPeakZ = 1100, launchZ = 1000 }
    for _, t in ipairs(B.ScoreAir(st)) do T.ok(t.name ~= "Air 180", "not off a ramp") end
end)

T.test("air assist: the setting is a server row, on by default", function()
    local sv = F.server()
    local row = sv.env.BMX.Settings.Get("bmx_air_assist")
    T.ok(row, "described in sh_settings.lua")
    T.eq(row.scope, "server", "an admin's")
    T.eq(row.default, true, "on by default")
    T.ok(sv.env.GetConVar("bmx_air_assist"):GetBool(), "and the convar says so")
    T.ok(sv.env.BMX.Tricks.air180 and sv.env.BMX.Tricks.spine_transfer, "both tricks are registered")
end)
