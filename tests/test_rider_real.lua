--[[--------------------------------------------------------------------------
    The rider IK on a REAL player model's skeleton (lib/skeleton_real.lua):
    kleiner's 69 bones as a client drew them, seated (drive_airboat) and
    standing (idle_all_01).

    The stand-in skeleton (lib/skeleton.lua) reached bars and pedals a real model
    cannot, so test_rider.lua passed what players saw fail: the tandem's riders
    two and four units short of their bars, the penny-farthing's feet off the
    pedals, the dirt bike's left hand short at full lock, riders off the pedals of
    the simple bike while a model builds, and a scooter rider's hands off the bars
    as each kick ended (measured on a client with tools/ride/sweep.sh, 2026-10-11).
    Here every vehicle is ridden on the real skeleton, on its model and on the
    simple bike drawn while the model builds, and each fist and the ball of each
    foot must be on what it holds.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local MF = require("lib.meshfake")
local SR = require("lib.skeleton_real")

local function segDist(P, A, B)
    local g = B - A
    local t = math.max(0, math.min(1, (P - A):Dot(g) / g:Dot(g)))
    return (A + g * t - P):Length()
end

-- How far each fist is from what it holds and each foot from its pedal or peg.
local function misses(B, ply, t)
    ply:InvalidateBoneCache(); ply:SetupBones()
    local r = {}
    for _, s in ipairs({ "R", "L" }) do
        local hk, fk = s == "R" and "rHand" or "lHand", s == "R" and "rFoot" or "lFoot"
        local T, fc = t[hk .. "Held"] or t[hk], B.RiderFistCentre(ply, s)
        if T and fc then r[hk] = (fc - T):Length() end
        if t[fk] then
            local a = ply:GetBoneMatrix(ply:LookupBone("ValveBiped.Bip01_" .. s .. "_Foot")):GetTranslation()
            local b = ply:GetBoneMatrix(ply:LookupBone("ValveBiped.Bip01_" .. s .. "_Toe0")):GetTranslation()
            r[fk] = segDist(t[fk], a, b)
        end
    end
    return r
end

local function seatPod(cl, ent, seat)
    local pod = cl.makeEntity("prop_vehicle_prisoner_pod")
    pod:SetParent(ent)
    pod:SetPos(ent:LocalToWorld(seat.offset))
    pod:SetAngles(ent:LocalToWorldAngles(seat.angles))
    return pod
end

-- `id` ridden by kleiner (and a stoker on a tandem), on its model or, `simple`, on
-- the simple bike; rolled `speed` u/s for `frames` frames, the bars at `steer`.
-- One client for every ride, so each model is built once (in plain Lua a build is
-- seconds; the game's is a few ms a frame).
local shared
local function client()
    if not shared then
        local sv, world = F.server()
        local cl = F.client(world)
        MF.enable(cl)
        shared = { sv = sv, world = world, cl = cl, n = 0 }
    end
    shared.n = shared.n + 1
    return shared.sv, shared.world, shared.cl, shared.n
end

local function ride(id, opt)
    opt = opt or {}
    local sv, world, cl, n = client()
    local E, B = cl.env, cl.env.BMX
    local errs = #cl.errors
    local cb = cl:clientEntity(B.ClassFor(id))
    cb:SetPos(E.Vector(0, 0, F.restHeight(sv)))
    cb:SetGrounded(true)
    cb:SetPedalling(true)
    local rider = cl:player("Rider" .. n)
    rider._skel = SR.load("kleiner_seated")
    rider._vehicle = seatPod(cl, cb, B.SeatFor(cb:Bike(), cb:Cfg(), "rider"))
    cb:SetPod(rider._vehicle)
    cb:SetDriver(rider)
    local stoker
    if B.HasSeat(cb:Bike(), "pegs") and cb:Bike().seats.pegs.pedals then
        stoker = cl:player("Stoker" .. n)
        stoker._skel = SR.load("kleiner_seated")
        stoker._vehicle = seatPod(cl, cb, B.SeatFor(cb:Bike(), cb:Cfg(), "pegs"))
        cb._nw.PaxPegs = stoker
    end
    cl.eyePos = cb:GetPos() + E.Vector(0, 150, 50)
    if not opt.simple then T.ok(MF.ready(cl, cb), id .. ": the model builds") end
    local function frame()
        if opt.simple then cb:Draw() else MF.draw(cl, cb) end
        if opt.steer then cb:SetSteer(math.rad(opt.steer)) end
        E.hook.Run("PrePlayerDraw", rider)
        if stoker then E.hook.Run("PrePlayerDraw", stoker) end
    end
    -- At 20 frames a second (each frame here is a full solve on 69 bones: kept few),
    -- 18 frames are about a turn of the cranks.
    world.dt = 1 / 20
    for _ = 1, 12 do frame() end
    cb._vel = cb:GetForward() * (opt.speed or 150)
    local worst = { rider = {}, stoker = {} }
    for _ = 1, opt.frames or 18 do
        frame()
        local t = B.StanceTargets and B.StanceTargets(rider, cb, cb.ikTargets) or cb.ikTargets
        for k, v in pairs(misses(B, rider, t)) do worst.rider[k] = math.max(worst.rider[k] or 0, v) end
        if stoker then
            for k, v in pairs(misses(B, stoker, B.PassengerTargets(stoker, cb, "pegs", rider))) do
                worst.stoker[k] = math.max(worst.stoker[k] or 0, v)
            end
        end
    end
    T.eq(#cl.errors, errs, id .. ": no errors: " .. table.concat(cl.errors, " | "))
    if cb.Remove then cb:Remove() end
    return worst, cb
end

local OPEN_HANDS = { unicycle = true }      -- arms out for balance: nothing to hold
local function fits(label, worst, skipHands, tol)
    for who, w in pairs(worst) do
        for k, v in pairs(w) do
            if not (skipHands and k:find("Hand")) then
                T.between(v, 0, tol or 0.5, string.format("%s: the %s's %s on it, units at worst", label, who, k))
            end
        end
    end
end

-- Each shape of rider-to-bike once (a model build in plain Lua takes seconds): the
-- BMX's, the road bike's drops, the city bike's swept bars, the tandem's two cockpits,
-- the penny-farthing's hub pedals, the unicycle's, and a motorbike's pegs. All
-- fourteen were measured the same way on 2026-10-11 and fit.
local PEDAL_BIKES = { "stock", "road", "city", "tandem", "penny" }
local SIMPLE_BIKES = { "stock", "road", "city", "tandem", "penny", "unicycle", "dirtbike", "moped" }

T.test("real skeleton: kleiner, posed with nothing moved, is where the client drew him", function()
    local sv, world = F.server()
    local cl = F.client(world)
    local E = cl.env
    local bike = cl:clientEntity("bmx_base")
    bike:SetPos(E.Vector(0, 0, 30))
    local pod = seatPod(cl, bike, cl.env.BMX.SeatFor(bike:Bike(), bike:Cfg(), "rider"))
    local ply = cl:player("Rider")
    ply._vehicle = pod
    ply._skel = SR.load("kleiner_seated")
    local data = dofile("tests/data/skeleton_kleiner_seated.lua")
    ply:InvalidateBoneCache(); ply:SetupBones()
    local worst = 0
    for i, b in ipairs(data.bones) do
        local want = pod:GetPos() + E.Vector(b[3][1], b[3][2], b[3][3])
        worst = math.max(worst, (ply:GetBoneMatrix(i):GetTranslation() - want):Length())
    end
    T.between(worst, 0, 0.15, "every bone within rounding of the capture, units")
    T.eq(ply:GetBoneCount(), 69, "all 69 bones")
end)

T.test("real skeleton: the riders on their models: fists on the grips, feet on the pedals (the tandem's two included)", function()
    for _, id in ipairs(PEDAL_BIKES) do
        fits(id, (ride(id, { speed = id == "penny" and 100 or 150 })), OPEN_HANDS[id])
    end
end)

T.test("real skeleton: the dirt bike's rider on its model, the hands on the grips at full lock both ways", function()
    fits("dirtbike", (ride("dirtbike", { speed = 40 })))
    fits("dirtbike, full lock left", (ride("dirtbike", { speed = 10, steer = 30 })))
    fits("dirtbike, full lock right", (ride("dirtbike", { speed = 10, steer = -30 })))
end)

T.test("real skeleton: while a model builds, the riders fit the simple bike drawn meanwhile (the tandem's two included)", function()
    for _, id in ipairs(SIMPLE_BIKES) do
        local motor = id == "dirtbike" or id == "moped"
        fits(id .. " (simple)", (ride(id, { simple = true, speed = motor and 40 or (id == "penny" or id == "unicycle") and 100 or 150 })), OPEN_HANDS[id])
    end
end)

-- A KICK SCOOTER'S RIDER, standing, through whole kicks at 20 and at 60 frames a second:
-- the hands stay on the grips while the body drops into the kick and rises out of it.
T.test("real skeleton: a scooter rider's hands stay on the bars through the kick, at 20 and 60 fps", function()
    for _, fps in ipairs({ 20, 60 }) do
        local sv, world = F.server()
        local cl = F.client(world)
        local E, B = cl.env, cl.env.BMX
        local ent = cl:clientEntity("bmx_scooter")
        ent:SetPos(E.Vector(0, 0, 3))
        ent:SetGrounded(true)
        ent:SetPushPhase(-1)
        local ply = cl:player("Rider")
        ply._skel = SR.load("kleiner_standing")
        ply._vehicle = seatPod(cl, ent, B.SeatFor(ent:Bike(), ent:Cfg(), "rider"))
        ent:SetPod(ply._vehicle)
        ent:SetDriver(ply)
        cl.localPlayer = sv:player("Looker")
        cl.eyePos = ent:GetPos() + E.Vector(0, 150, 50)
        local function frame() ent:Draw() E.hook.Run("PrePlayerDraw", ply) end
        for _ = 1, 20 do frame() end
        ent._vel = ent:GetForward() * 200
        world.dt = 1 / fps
        local worst, reach = 0, 0
        for i = 1, fps * 2 do
            local ph = (i % fps) / fps            -- a kick a second
            ent:SetPushPhase(ph < 0.95 and ph or -1)
            frame()
            if i > fps then
                local w = misses(B, ply, ent.ikTargets)
                worst = math.max(worst, w.rHand or 0, w.lHand or 0)
                reach = math.max(reach, ply.bmxSpineLeanShown or 0)
            end
        end
        T.between(worst, 0, fps < 30 and 1.0 or 0.4, fps .. " fps: the fists off the grips through the kick, units at worst")
        T.between(reach, 0, 16, fps .. " fps: the torso stood over the bars, not wound to its reach limit chasing them, degrees")
        T.eq(#cl.errors, 0, "no errors: " .. table.concat(cl.errors, " | "))
    end
end)
