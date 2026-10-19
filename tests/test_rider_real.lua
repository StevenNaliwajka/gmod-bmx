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

T.test("real skeleton: while a model builds, the riders fit the simple bike drawn meanwhile (the tandem's two included), riding straight and turning", function()
    for _, id in ipairs(SIMPLE_BIKES) do
        local motor = id == "dirtbike" or id == "moped"
        fits(id .. " (simple)", (ride(id, { simple = true, speed = motor and 40 or (id == "penny" or id == "unicycle") and 100 or 150 })), OPEN_HANDS[id])
    end
    -- turning slowly, the far grip swung forward: the stretched simple bike's wide bars
    -- were out of reach (the dirt bike's by 3.7 units, the city bike's by 1.1)
    for _, id in ipairs({ "dirtbike", "city", "moped" }) do
        fits(id .. " (simple), turning", (ride(id, { simple = true, speed = 20, steer = 25 })))
    end
end)

-- A KICK SCOOTER'S RIDER, standing, through whole kicks at 20 and at 60 frames a second:
-- the hands stay on the grips while the body drops into the kick and rises out of it.
T.test("real skeleton: a scooter rider's hands stay on the bars through the kick, at 20 and 60 fps, and kicking hard", function()
    for _, run in ipairs({ { 20, 1 }, { 60, 1 }, { 20, 2.2 } }) do
        local fps, kicks = run[1], run[2]
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
            -- a kick a second; kicking hard, more than two (the body drops into each
            -- kick in a frame or two at 20 fps, as a client measured)
            local ph = (i * kicks % fps) / fps
            ent:SetPushPhase(ph < 0.95 and ph or -1)
            frame()
            if i > fps then
                local w = misses(B, ply, ent.ikTargets)
                worst = math.max(worst, w.rHand or 0, w.lHand or 0)
                reach = math.max(reach, ply.bmxSpineLeanShown or 0)
            end
        end
        local label = fps .. " fps" .. (kicks > 1 and ", kicking hard" or "")
        T.between(worst, 0, fps < 30 and 1.0 or 0.4, label .. ": the fists off the grips through the kick, units at worst")
        T.between(reach, 0, 16, label .. ": the torso stood over the bars, not wound to its reach limit chasing them, degrees")
        T.eq(#cl.errors, 0, "no errors: " .. table.concat(cl.errors, " | "))
    end
end)

-- A GRIP THAT GOES OUT OF REACH IS REACHED FOR AT ONCE. A hard landing or a hop's pop
-- moves the body away from the bars in a frame; the torso's reach lean took four
-- frames at 20 fps to follow and the hands were off the bars meanwhile (2026-10-11).
-- Here the grips go 4 units further in one frame: back on them within two frames.
T.test("real skeleton: grips that jump out of reach are reached for within two frames at 20 fps", function()
    local sv, world, cl, n = client()
    local E, B = cl.env, cl.env.BMX
    local bike = cl:clientEntity("bmx_base")
    bike:SetPos(E.Vector(0, 0, F.restHeight(sv)))
    local ply = cl:player("Reacher" .. n)
    ply._skel = SR.load("kleiner_seated")
    ply._vehicle = seatPod(cl, bike, B.SeatFor(bike:Bike(), bike:Cfg(), "rider"))
    bike:SetPod(ply._vehicle)
    bike:SetDriver(ply)
    cl.eyePos = bike:GetPos() + E.Vector(0, 150, 50)
    world.dt = 1 / 20
    local fwd = bike:GetForward()
    local function frame(shift)
        bike:Draw()
        local t = bike.ikTargets
        for _, k in ipairs({ "rHand", "lHand", "rHandA", "rHandB", "lHandA", "lHandB" }) do
            if t[k] then t[k] = t[k] + fwd * shift end
        end
        E.hook.Run("PrePlayerDraw", ply)
        local w = misses(B, ply, t)
        return math.max(w.rHand or 0, w.lHand or 0)
    end
    for _ = 1, 20 do frame(4) end
    T.between(frame(4), 0, 0.3, "settled on grips a stretch away")
    frame(8)
    local second = frame(8)
    T.between(second, 0, 1.2, "two frames after the grips went 4 units further, the hands within, units")
    T.between(frame(8), 0, 0.8, "and nearly there the frame after")
end)

-- THE FEET ON PEDALS THAT JUMP, THE SAME FRAME. A hard landing swings the frame under
-- the rider: on a 20 fps client a foot stood two to five units off its pedal for two
-- frames, the foot turned only so far a frame (2026-10-11). Here the pedals drop 10 units
-- and bounce 5 back, a frame each: each foot is on its pedal in that frame (with the
-- foot aimed twice a frame, as it was, 2 units off on the bounce).
T.test("real skeleton: pedals that jump in one frame (a hard landing) have the feet on them that frame", function()
    local sv, world, cl, n = client()
    local E, B = cl.env, cl.env.BMX
    local bike = cl:clientEntity("bmx_base")
    bike:SetPos(E.Vector(0, 0, F.restHeight(sv)))
    bike:SetGrounded(true)
    bike:SetPedalling(true)
    local ply = cl:player("Lander" .. n)
    ply._skel = SR.load("kleiner_seated")
    ply._vehicle = seatPod(cl, bike, B.SeatFor(bike:Bike(), bike:Cfg(), "rider"))
    bike:SetPod(ply._vehicle)
    bike:SetDriver(ply)
    cl.eyePos = bike:GetPos() + E.Vector(0, 150, 50)
    world.dt = 1 / 20
    local up, fwd = bike:GetUp(), bike:GetForward()
    local function frame(drop)
        bike:Draw()
        local t = bike.ikTargets
        for _, k in ipairs({ "rFoot", "lFoot" }) do t[k] = t[k] - up * drop + fwd * (drop * 0.5) end
        E.hook.Run("PrePlayerDraw", ply)
        local w = misses(B, ply, t)
        return math.max(w.rFoot or 0, w.lFoot or 0)
    end
    bike._vel = fwd * 150
    for _ = 1, 20 do frame(0) end
    T.between(frame(10), 0, 0.3, "the frame the pedals dropped, the feet on them, units")
    T.between(frame(-5), 0, 0.3, "and the frame they bounced back up past where they were")
    T.between(frame(0), 0, 0.3, "and home")
end)

-- THE RIDER RIDES THE FRAME THE BIKE DRAWS. The frame is drawn on its axles, so a
-- suspension squashed by a hard landing lifts saddle, pedals and bars off the chassis
-- the rider's seat is on (cl_init.lua); the rider is moved with it (BMX.RiderFollowFrame)
-- and stays on the bars and pedals. Without it, squashed 6 units, the hands were 0.9
-- off the bars.
T.test("real skeleton: a landing squashes the suspension and the rider rides the frame down and up, on the bars and pedals", function()
    local sv, world, cl, n = client()
    local E, B = cl.env, cl.env.BMX
    local cb = cl:clientEntity("bmx_base")
    local z0 = F.restHeight(sv)
    cb:SetPos(E.Vector(0, 0, z0))
    cb:SetGrounded(true)
    cb:SetPedalling(true)
    local seat = B.SeatFor(cb:Bike(), cb:Cfg(), "rider")
    local ply = cl:player("Squash" .. n)
    ply._skel = SR.load("kleiner_seated")
    ply._vehicle = seatPod(cl, cb, seat)
    cb:SetPod(ply._vehicle)
    cb:SetDriver(ply)
    cl.eyePos = cb:GetPos() + E.Vector(0, 150, 50)
    T.ok(MF.ready(cl, cb), "the model builds")
    world.dt = 1 / 20
    cb._vel = cb:GetForward() * 120
    local worst, rose = 0, 0
    local pb = ply:LookupBone("ValveBiped.Bip01_Pelvis")
    for i = 1, 36 do
        local dz = (i > 14 and i <= 22) and 6 or 0
        cb:SetPos(E.Vector(cb:GetPos().x, 0, z0 - dz))
        ply._vehicle:SetPos(cb:LocalToWorld(seat.offset))
        MF.draw(cl, cb)
        E.hook.Run("PrePlayerDraw", ply)
        if i > 8 then
            local w = misses(B, ply, cb.ikTargets)
            for _, v in pairs(w) do worst = math.max(worst, v) end
            if dz > 0 then rose = math.max(rose, (ply:GetManipulateBonePosition(pb)):Length()) end
        end
    end
    T.between(worst, 0, 0.3, "hands and feet on the bike through the squash, units at worst")
    T.ok(rose > 3, string.format("the rider rose with the frame: %.1f units", rose))
    T.between(ply:GetManipulateBonePosition(pb):Length(), 0, 0.5, "and is back on the chassis once it is up")
    if cb.Remove then cb:Remove() end
end)

-- A SKATER, on kleiner's real standing skeleton. The arms were sent to points on the
-- board and the open hands aimed out to the side, so every skater rode with the arms
-- reaching out and the wrists cocked, palms down, like paws; a grab left both hands
-- fists for the rest of the ride; and the head looked out to the side the body faces
-- (kleiner's mesh in the offline studio, 2026-10-19). Here: the hands hang from the
-- shoulders, the wrists straight, the fingers open again after a grab, and the eyes
-- look up the board, level.
T.test("real skeleton: a skater's arms hang loose, wrists straight, a grab's hand opens after it, and the eyes look up the board", function()
    local sv, world = F.server()
    local cl = F.client(world)
    local E, B = cl.env, cl.env.BMX
    local ent = cl:clientEntity("bmx_skateboard")
    ent:SetPos(E.Vector(0, 0, 1.3))
    ent:SetGrounded(true)
    ent:SetPushPhase(-1)
    local ply = cl:player("Skater")
    ply._skel = SR.load("kleiner_standing")
    ply._vehicle = seatPod(cl, ent, B.SeatFor(ent:Bike(), ent:Cfg(), "rider"))
    ent:SetPod(ply._vehicle)
    ent:SetDriver(ply)
    cl.localPlayer = sv:player("Looker")
    cl.eyePos = ent:GetPos() + E.Vector(0, 150, 50)
    world.dt = 1 / 30
    local function frame() world.time = world.time + world.dt ent:Draw() E.hook.Run("PrePlayerDraw", ply) end
    local function P(name) ply:InvalidateBoneCache() return ply:GetBoneMatrix(ply:LookupBone("ValveBiped.Bip01_" .. name)) end
    local function fingersCurled(s)
        for _, f in ipairs({ "1", "2", "3", "4" }) do
            local a = ply:GetManipulateBoneAngles(ply:LookupBone("ValveBiped.Bip01_" .. s .. "_Finger" .. f .. "1"))
            if math.abs(a.p) + math.abs(a.y) + math.abs(a.r) > 1 then return true end
        end
        return false
    end
    ent._vel = ent:GetForward() * 200
    for _ = 1, 30 do frame() end
    for _, s in ipairs({ "R", "L" }) do
        local sh, el, wr = P(s .. "_UpperArm"):GetTranslation(), P(s .. "_Forearm"):GetTranslation(), P(s .. "_Hand"):GetTranslation()
        local kn = P(s .. "_Finger2"):GetTranslation()
        T.ok(wr.z < sh.z - 15, s .. ": the hand hangs below its shoulder: " .. (sh.z - wr.z))
        local bend = math.deg(math.acos((wr - el):GetNormalized():Dot((kn - wr):GetNormalized())))
        T.between(bend, 0, 25, s .. ": the wrist straight, the hand going on from the forearm, degrees")
        T.ok(not fingersCurled(s), s .. ": an open hand, not a fist")
    end
    -- the eyes up the board, the way it rolls, and level
    local fb = ply:LookupBone("ValveBiped.forward")
    ply:InvalidateBoneCache()
    local gaze = ply:GetBoneMatrix(fb):GetForward()
    local fwd = ent:GetForward()
    local yaw = math.deg(math.acos(math.Clamp(E.Vector(gaze.x, gaze.y, 0):GetNormalized():Dot(E.Vector(fwd.x, fwd.y, 0):GetNormalized()), -1, 1)))
    T.between(yaw, 0, 20, "looking up the board, not out to the side, degrees off its heading")
    local skull = P("Head1")
    T.between(math.abs(skull:GetUp().z), 0, 0.2, "the eyes level: the head's side axis about horizontal")
    -- a grab closes the back hand on the deck; after it, the hand opens again
    ent:SetGrounded(false)
    ent:SetTrickBits(B.PoseIDs.indy * 65536)
    for _ = 1, 15 do frame() end
    T.ok(fingersCurled("R"), "the indy's hand (the back one, riding regular) closes on the deck")
    T.ok(not fingersCurled("L"), "the other keeps its balance, open")
    ent:SetTrickBits(0)
    for _ = 1, 15 do frame() end
    T.ok(not fingersCurled("R") and not fingersCurled("L"), "let go, both hands open again")
    T.eq(#cl.errors, 0, "no errors: " .. table.concat(cl.errors, " | "))
end)

-- OUT OF THE SADDLE. The standing and attack stances only leaned the torso, so a
-- "standing" rider sat on the saddle (kleiner's mesh in the offline studio, 2026-10-19).
-- Standing, the hips come up off it -- as far as the legs still reach the bottom of the
-- stroke -- with the hands on the grips, the feet on the pedals, the elbows bent (lifted
-- 9 units, a BMX's low bars were past arm's length and the arms locked straight). A
-- penny-farthing's pedals are already a stretch away: its rider rises only as far as
-- the hips brought over the hub still reach them.
T.test("real skeleton: standing and attack lift the rider off the saddle, on the grips and pedals, elbows bent", function()
    local sv, world, cl, n = client()
    local E, B = cl.env, cl.env.BMX
    local function elbow(ply, s)
        ply:InvalidateBoneCache()
        local function P(b) return ply:GetBoneMatrix(ply:LookupBone("ValveBiped.Bip01_" .. s .. "_" .. b)):GetTranslation() end
        local S, El, W = P("UpperArm"), P("Forearm"), P("Hand")
        return math.deg(math.acos(math.Clamp((El - S):GetNormalized():Dot((W - El):GetNormalized()), -1, 1)))
    end
    for _, id in ipairs({ "stock", "dirtbike", "penny" }) do
        local cb = cl:clientEntity(B.ClassFor(id))
        cb:SetPos(E.Vector(0, 0, F.restHeight(sv)))
        cb:SetGrounded(true)
        cb:SetPedalling(true)
        local ply = cl:player("Stander" .. n .. id)
        ply._skel = SR.load("kleiner_seated")
        ply._vehicle = seatPod(cl, cb, B.SeatFor(cb:Bike(), cb:Cfg(), "rider"))
        cb:SetPod(ply._vehicle)
        cb:SetDriver(ply)
        cl.eyePos = cb:GetPos() + E.Vector(0, 150, 50)
        T.ok(MF.ready(cl, cb), id .. ": the model builds")
        world.dt = 1 / 20
        cb._vel = cb:GetForward() * 120
        local pb = ply:LookupBone("ValveBiped.Bip01_Pelvis")
        local function settle(stance)
            ply:SetNWInt("BMXStance", B.RiderStanceId[stance])
            local worst = 0
            for i = 1, 30 do
                MF.draw(cl, cb)
                E.hook.Run("PrePlayerDraw", ply)
                if i > 20 then
                    -- (a hand anywhere on its grip: the stance's targets are a copy, so
                    -- where along it the solver chose is not on the bike's own table)
                    local t = cb.ikTargets
                    for k, v in pairs(misses(B, ply, t)) do
                        if k:find("Hand") and t[k .. "A"] then
                            local fc = B.RiderFistCentre(ply, k:sub(1, 1):upper())
                            v = segDist(fc, t[k .. "A"], t[k .. "B"])
                        end
                        worst = math.max(worst, v)
                    end
                end
            end
            return ply:GetManipulateBonePosition(pb):Length(), worst
        end
        local seated = settle("seated")
        for _, stance in ipairs({ "standing", "attack" }) do
            local up, worst = settle(stance)
            if id == "penny" then
                -- (the hub's pedals are a stretch already: up only as far as the hips over
                -- the hub still reach the bottom of the stroke)
                T.between(up - seated, -0.5, B.RiderStandRise + 0.5, string.format("%s %s: no higher than a stand allows", id, stance))
            else
                T.ok(up > seated + 2.5, string.format("%s %s: up off the saddle, %.1f units", id, stance, up))
            end
            T.between(worst, 0, 0.6, id .. " " .. stance .. ": hands and feet on the bike, units at worst")
            T.ok(elbow(ply, "R") > 12 and elbow(ply, "L") > 12,
                string.format("%s %s: elbows bent, not locked (%.0f, %.0f degrees)", id, stance, elbow(ply, "R"), elbow(ply, "L")))
        end
        if cb.Remove then cb:Remove() end
    end
end)
