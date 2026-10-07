--[[--------------------------------------------------------------------------
    G21, camera and HUD options: the trick camera's maths, the rider's
    stance, the filmer camera's aim, the speedometer's extra line, and the
    settings rows for all of them.

    The air camera is the one that can feel wrong without anyone being able to
    say why, so it is tested the way it is meant to behave: stepped frame by
    frame through a takeoff and a landing, at a high and a low frame rate, and
    required never to JUMP.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local function client()
    local sv, world = F.server()
    local cl = F.client(world)
    return sv, cl, world
end

--------------------------------------------------------------------------
-- The trick camera
--------------------------------------------------------------------------
-- Step a camera through ground / air / ground at `fps`, returning the series
-- of distance multipliers and FOV additions, one per frame.
local function flight(cl, fps, amount, groundS, airS)
    local B = cl.env.BMX
    local st, dt = { t = 0, phase = 0 }, 1 / fps
    local mult, fov = {}, {}
    local function frame(grounded)
        local blend = B.AirCamStep(st, grounded, dt)
        local m, f = B.AirCamExtras(blend, amount)
        mult[#mult + 1], fov[#fov + 1] = m, f
    end
    for _ = 1, math.floor(groundS * fps) do frame(true) end
    for _ = 1, math.floor(airS * fps) do frame(false) end
    for _ = 1, math.floor(2 * fps) do frame(true) end
    return mult, fov
end

T.test("air camera: no jump at takeoff or landing, at any frame rate", function()
    local _, cl = client()
    local A = cl.env.BMX.AirCam
    for _, fps in ipairs({ 20, 60, 144 }) do
        local mult, fov = flight(cl, fps, 1, 1, 1.5)
        -- The fastest the smoothstep moves is 1.5 x the phase rate; allow a
        -- little over for the frame the ramp starts.
        local maxDm = A.dist * 1.5 / math.min(A.secondsIn, A.secondsOut) / fps * 1.05
        local maxDf = A.fov  * 1.5 / math.min(A.secondsIn, A.secondsOut) / fps * 1.05
        for i = 2, #mult do
            T.ok(math.abs(mult[i] - mult[i - 1]) <= maxDm,
                string.format("%d fps: distance jumped %.4f at frame %d", fps,
                    mult[i] - mult[i - 1], i))
            T.ok(math.abs(fov[i] - fov[i - 1]) <= maxDf,
                string.format("%d fps: FOV jumped %.4f at frame %d", fps,
                    fov[i] - fov[i - 1], i))
        end
        T.near(mult[1], 1, 1e-9, "starts at the normal distance")
        T.near(mult[#mult], 1, 1e-9, "ends at the normal distance")
        local top = 0
        for _, m in ipairs(mult) do top = math.max(top, m) end
        T.near(top, 1 + A.dist, 1e-6, "a long air reaches the full pull-back")
    end
end)

T.test("air camera: a bump is not an air, and 0 turns the camera off", function()
    local _, cl = client()
    local B = cl.env.BMX
    local st = { t = 0, phase = 0 }
    for _ = 1, 4 do B.AirCamStep(st, false, 1 / 60) end     -- 0.067 s off the ground
    T.eq(B.AirCamStep(st, true, 1 / 60), 0, "landing after a bump leaves the camera alone")
    local mult, fov = flight(cl, 60, 0, 0.5, 1.5)
    for i = 1, #mult do
        T.eq(mult[i], 1, "bmx_cam_air 0 never pulls back")
        T.eq(fov[i], 0, "bmx_cam_air 0 never widens")
    end
end)

--------------------------------------------------------------------------
-- The stance
--------------------------------------------------------------------------
T.test("stance: IK targets move by the stance's offsets, as a copy", function()
    local sv, cl, world = client()
    local B = cl.env.BMX
    local V = cl.env.Vector
    local ply = cl:player("Rider")
    local bike = { Cfg = function() return { Wheel = { wheelbase = 39 } } end,
                   LocalToWorld = function(_, v) return v + V(100, 0, 0) end }
    local ik = { rHand = V(10, 0, 30), rHandA = V(10, 1, 30), lFoot = V(0, 5, 5) }

    T.eq(B.StanceOf(ply), "seated", "the default is seated")
    T.ok(B.StanceTargets(ply, bike, ik) == ik, "seated changes nothing")

    ply:SetNWInt("BMXStance", B.RiderStanceId.attack)
    T.eq(B.StanceOf(ply), "attack", "other players' stance comes from the networked int")
    local out = B.StanceTargets(ply, bike, ik)
    T.ok(out ~= ik, "a copy, so applying twice does not stack")
    local off = B.RiderPoseOffset("attack")
    T.near(out.rHand.x, 10 + off.rHand.x, 1e-9, "hand moved forward")
    T.near(out.rHand.z, 30 + off.rHand.z, 1e-9, "hand moved down")
    T.near(out.rHandA.z, 30 + off.rHand.z, 1e-9, "the grip range moves with the hand")
    T.near(out.lFoot.z, 5 + off.lFoot.z, 1e-9, "foot moved")
    T.near(ik.rHand.z, 30, 1e-9, "the original is untouched")
    T.near(B.StanceLean(ply), off.spineLean, 1e-9, "the torso folds with it")

    ply:SetNWInt("BMXStance", 99)
    T.eq(B.StanceOf(ply), "seated", "an unknown id is seated")
    T.eq(B.RiderPoseOffset("nonsense"), B.StanceOffsets.seated, "an unknown name is seated")
end)

T.test("stance: the server copies the userinfo convar onto the player, validated", function()
    local sv = F.server()
    local ply = sv:player("Rider")
    ply._info = { bmx_rider_pose = "standing" }
    sv:run(1)
    T.eq(ply:GetNWInt("BMXStance", 1), sv.env.BMX.RiderStanceId.standing, "standing arrives")
    ply._info.bmx_rider_pose = "rm -rf"
    sv:run(1)
    T.eq(ply:GetNWInt("BMXStance", 1), 1, "junk falls back to seated")
end)

--------------------------------------------------------------------------
-- The filmer camera
--------------------------------------------------------------------------
T.test("filmer: aim, zoom and operator lag", function()
    local _, cl = client()
    local B, V = cl.env.BMX, cl.env.Vector
    local a = B.FilmerAim(V(0, 0, 0), V(100, 100, 0))
    T.near(a.y, 45, 1e-6, "yaw to the subject")
    T.near(a.p, 0, 1e-6, "level")
    local up = B.FilmerAim(V(0, 0, 0), V(100, 0, 100))
    T.near(up.p, -45, 1e-6, "looks up with a negative pitch")

    T.ok(B.FilmerFov(300) > B.FilmerFov(900), "closer means a wider view")
    T.between(B.FilmerFov(1), 18, 80, "clamped near")
    T.between(B.FilmerFov(1e6), 18, 80, "clamped far")

    local st = {}
    local first = B.FilmerTrack(st, cl.env.Angle(0, 90, 0), 1 / 60)
    T.near(first.y, 90, 1e-9, "the first aim is exact")
    local next1 = B.FilmerTrack(st, cl.env.Angle(0, -90, 0), 1 / 60)
    T.ok(next1.y < 90 and next1.y > 60, "then it eases toward the target, the short way")
    for _ = 1, 600 do B.FilmerTrack(st, cl.env.Angle(0, -90, 0), 1 / 60) end
    T.near(math.abs(st.ang.y), 90, 0.01, "and settles on it")

    local near = { GetPos = function() return V(10, 0, 0) end }
    local far  = { GetPos = function() return V(500, 0, 0) end }
    T.ok(B.FilmerNearest(V(0, 0, 0), { far, near }, 1000) == near, "nearest wins")
    T.eq(B.FilmerNearest(V(0, 0, 0), { far }, 100), nil, "out of range is nobody")
end)

T.test("filmer: the entity is registered and spawnable", function()
    local _, cl = client()
    local t = cl.env.scripted_ents.Get("bmx_filmer_cam")
    T.ok(t, "registered on the client")
    T.ok(t.Spawnable and t.AdminOnly, "an admin can spawn it")
    T.ok(t.IsBMXFilmer, "the view finds it by its flag")
end)

--------------------------------------------------------------------------
-- The speedometer's extra line
--------------------------------------------------------------------------
T.test("hud: combo multiplier and airtime line", function()
    local _, cl = client()
    local B = cl.env.BMX
    T.eq(B.HudStatsLine(0, 0), nil, "nothing to say, nothing shown")
    T.eq(B.HudStatsLine(3, 0), "combo x3", "just a combo")
    T.eq(B.HudStatsLine(0, 1.234), "air 1.23s", "just air")
    T.eq(B.HudStatsLine(2, 0.5), "combo x2   air 0.50s", "both")

    local st = {}
    local t, live = B.AirClock(st, true, 0)
    T.eq(t, 0, "on the ground")
    t, live = B.AirClock(st, false, 1.0)
    T.eq(t, 0, "the first moments are not shown")
    t, live = B.AirClock(st, false, 2.0)
    T.near(t, 1.0, 1e-9, "a second in the air")
    T.ok(live, "live")
    t, live = B.AirClock(st, true, 2.5)
    T.near(t, 1.5, 1e-9, "held on landing")
    T.ok(not live, "no longer live")
    t = B.AirClock(st, true, 5.1)
    T.eq(t, 0, "and gone after 2.5 s")
    B.AirClock(st, false, 6)
    B.AirClock(st, true, 6.1)
    T.eq((B.AirClock(st, true, 6.2)), 0, "a bump is never shown")
end)

--------------------------------------------------------------------------
-- The settings rows
--------------------------------------------------------------------------
T.test("settings: the G21 rows exist", function()
    local sv = F.server()
    local S = sv.env.BMX.Settings
    for _, name in ipairs({ "bmx_cam_air", "bmx_rider_pose" }) do
        T.ok(S.Get(name), name .. " is described in sh_settings.lua")
    end
    T.eq(S.Get("bmx_rider_pose").kind, "choice", "the stance is a choice")
end)
