--[[--------------------------------------------------------------------------
    The rider's body (cl_rider.lua): which pose, which bones, in step with what.

    Whether it LOOKS right needs a person on a client. What this can pin is
    that the pose follows the bike: legs in step with the drawn cranks and
    still when coasting, a tuck that grows with speed, a crouch for a hop, and
    nothing left on a player once they get off.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local function client()
    local sv, world = F.server()
    local cl = F.client(world)
    local bike = cl:clientEntity("bmx_base")
    bike:SetPos(cl.env.Vector(0, 0, F.restHeight(sv)))
    local pod = cl.makeEntity("prop_vehicle_prisoner_pod")
    pod:SetParent(bike)
    bike:SetPod(pod)
    local ply = cl:player("Rider")
    ply._vehicle = pod
    bike:SetDriver(ply)
    return cl, bike, ply
end

local function pose(cl, t)
    local s = { crank = 0, speed = 0, topSpeed = 350, sprint = false, hop = 0, pitch = 0, steer = 0 }
    for k, v in pairs(t or {}) do s[k] = v end
    return cl.env.BMX.RiderPose(s)
end

T.test("a rider sits in the hands-forward riding pose, and only on a BMX", function()
    local cl, bike, ply = client()
    local act, seq = cl.env.hook.Run("CalcMainActivity", ply, cl.env.Vector())
    T.eq(act, cl.env.ACT_DRIVE_AIRBOAT, "riding activity")
    T.eq(seq, 42, "the drive_airboat sequence")
    ply._vehicle = nil
    T.eq(cl.env.hook.Run("CalcMainActivity", ply, cl.env.Vector()), nil, "on foot: untouched")
    ply._vehicle = bike:GetPod()
    ply._noSequences = true
    T.eq(cl.env.hook.Run("CalcMainActivity", ply, cl.env.Vector()), nil,
        "a model without the sequence keeps its own pose")
end)

T.test("the legs pedal half a turn apart, in step with the crank", function()
    local cl = client()
    local a = pose(cl, { crank = math.pi / 2 })
    T.ok(a.rThigh.y > 15, "right thigh up at a quarter turn: " .. a.rThigh.y)
    T.near(a.lThigh.y, -a.rThigh.y, 1e-9, "left thigh the opposite way")
    local b = pose(cl, { crank = math.pi / 2 + math.pi })
    T.near(b.rThigh.y, a.lThigh.y, 1e-9, "half a turn later the legs have swapped")
end)

T.test("the pose follows speed, sprint, hop preload, wheelie and steer", function()
    local cl = client()
    local slow, fast = pose(cl, { speed = 20 }), pose(cl, { speed = 350 })
    T.ok(fast.spine.y > slow.spine.y + 10, "tucks forward with speed")
    T.ok(pose(cl, { speed = 350, sprint = true }).spine.y > fast.spine.y, "further on a sprint")
    local rest, crouched = pose(cl), pose(cl, { hop = 1 })
    T.ok(crouched.rCalf.y > rest.rCalf.y + 20, "knees fold for a hop")
    T.ok(crouched.spine.y > rest.spine.y, "and the body goes down")
    T.ok(pose(cl, { pitch = math.rad(25) }).spine.y > rest.spine.y, "leans into a wheelie")
    T.ok(pose(cl, { pitch = math.rad(-20) }).spine.y < rest.spine.y, "back in a stoppie")
    T.ok(pose(cl, { steer = math.rad(20) }).rArm.p > 5, "arms follow the bars")
    T.ok(math.abs(fast.head.y) < math.abs(fast.spine.y), "the head holds the horizon")
end)

-- A rider seated in the pod, the pod where the bike puts it.
local function seated()
    local cl, bike, ply = client()
    local C = bike:Cfg().Chassis
    local pod = bike:GetPod()
    pod:SetPos(bike:LocalToWorld(C.seatOffset))
    pod:SetAngles(bike:LocalToWorldAngles(C.seatAngles))
    return cl, bike, ply
end

local function frame(cl, bike, ply)
    bike:Draw()
    cl.env.hook.Run("PrePlayerDraw", ply)
end

local function reach(cl, ply, bone, target)
    local b = ply:LookupBone(bone)
    return (ply:GetBoneMatrix(b):GetTranslation() - target):Length()
end

T.test("IK: the feet go onto the pedals and the hands onto the grips", function()
    local cl, bike, ply = seated()
    bike:SetCadence(0)
    frame(cl, bike, ply)
    local t = bike.ikTargets
    local startFoot = reach(cl, ply, "ValveBiped.Bip01_R_Foot", t.rFoot)
    for _ = 1, 40 do frame(cl, bike, ply) end
    t = bike.ikTargets
    ply:InvalidateBoneCache(); ply:SetupBones()
    local rf = reach(cl, ply, "ValveBiped.Bip01_R_Foot", t.rFoot)
    T.ok(rf < startFoot, string.format("closer than the plain pose (%.1f -> %.1f)", startFoot, rf))
    T.between(rf, 0, 1.5, "right foot to its pedal, units")
    T.between(reach(cl, ply, "ValveBiped.Bip01_L_Foot", t.lFoot), 0, 1.5, "left foot to its pedal")
    T.between(reach(cl, ply, "ValveBiped.Bip01_R_Hand", t.rHand), 0, 1.5, "right hand to its grip")
    T.between(reach(cl, ply, "ValveBiped.Bip01_L_Hand", t.lHand), 0, 1.5, "left hand to its grip")
end)

T.test("IK: pedalling, the feet stay on the pedals all the way round", function()
    local cl, bike, ply = seated()
    bike:SetCadence(0)
    for _ = 1, 40 do frame(cl, bike, ply) end
    bike:SetCadence(8)                             -- about a turn a second
    local worst = 0
    for i = 1, 66 do
        frame(cl, bike, ply)
        if i > 5 then
            ply:InvalidateBoneCache(); ply:SetupBones()
            worst = math.max(worst, reach(cl, ply, "ValveBiped.Bip01_R_Foot", bike.ikTargets.rFoot))
        end
    end
    T.between(worst, 0, 3, "furthest the right foot got from its pedal over a turn, units")
end)

T.test("IK: coasting, the legs are still", function()
    local cl, bike, ply = seated()
    bike:SetCadence(0)
    for _ = 1, 40 do frame(cl, bike, ply) end
    local b = ply:LookupBone("ValveBiped.Bip01_R_Foot")
    local p0 = ply:GetBoneMatrix(b):GetTranslation()
    for _ = 1, 10 do frame(cl, bike, ply) end
    ply:InvalidateBoneCache(); ply:SetupBones()
    T.between((ply:GetBoneMatrix(b):GetTranslation() - p0):Length(), 0, 0.3, "foot movement, units")
end)

T.test("IK off: the simple swing still pedals in time with the cranks", function()
    local cl, bike, ply = seated()
    cl.env.GetConVar("bmx_rider_ik"):SetString("0")
    bike:SetCadence(10)
    for _ = 1, 5 do frame(cl, bike, ply) end
    local want = math.sin(bike.crankAngle) * cl.env.BMX.RiderAmplitudes.thighSwing
    T.near(ply._bones["ValveBiped.Bip01_R_Thigh"].y, want, 1e-9, "thigh on the crank angle")
end)

T.test("getting off, or bmx_rider_anim 0, puts every bone back", function()
    local cl, bike, ply = client()
    bike:SetCadence(10)
    bike:Draw(); cl.env.hook.Run("PrePlayerDraw", ply)
    ply._vehicle = nil
    cl.env.hook.Run("PrePlayerDraw", ply)
    for name, a in pairs(ply._bones) do
        T.ok(a.p == 0 and a.y == 0 and a.r == 0, name .. " reset after dismount")
    end
    ply._vehicle = bike:GetPod()
    cl.env.hook.Run("PrePlayerDraw", ply)
    cl.env.GetConVar("bmx_rider_anim"):SetString("0")
    cl.env.hook.Run("PrePlayerDraw", ply)
    for name, a in pairs(ply._bones) do
        T.ok(a.p == 0 and a.y == 0 and a.r == 0, name .. " reset with animation off")
    end
end)

local function P(ply, name)
    return ply:GetBoneMatrix(ply:LookupBone(name)):GetTranslation()
end

T.test("IK: knees bend forward and stay above the feet, all the way round", function()
    local cl, bike, ply = seated()
    bike:SetCadence(0)
    for _ = 1, 40 do frame(cl, bike, ply) end
    bike:SetCadence(8)
    local fwd = bike:GetForward()
    local worstFwd, minBend, maxBend, below = math.huge, 180, 0, false
    for i = 1, 66 do
        frame(cl, bike, ply)
        ply:InvalidateBoneCache(); ply:SetupBones()
        for _, s in ipairs({ "R", "L" }) do
            local H = P(ply, "ValveBiped.Bip01_" .. s .. "_Thigh")
            local K = P(ply, "ValveBiped.Bip01_" .. s .. "_Calf")
            local F = P(ply, "ValveBiped.Bip01_" .. s .. "_Foot")
            -- The knee's offset from the hip-foot line, along the bike's forward.
            local line = (F - H):GetNormalized()
            local off = (K - H) - line * (K - H):Dot(line)
            worstFwd = math.min(worstFwd, off:Dot(fwd))
            local b = math.deg(math.acos(math.Clamp((K - H):GetNormalized():Dot((F - K):GetNormalized()), -1, 1)))
            minBend, maxBend = math.min(minBend, b), math.max(maxBend, b)
            if K.z < F.z then below = true end
        end
    end
    T.ok(worstFwd > 0, "the knee is always in front of the hip-foot line: " .. worstFwd)
    T.ok(not below, "never below its own foot")
    T.between(minBend, 14, 180, "the knee never locks straight, deg")
    T.between(maxBend, 0, 156, "or folds past the limit, deg")
end)

T.test("IK: soles flat on the pedals, toes forward", function()
    local cl, bike, ply = seated()
    for _ = 1, 40 do frame(cl, bike, ply) end
    ply:InvalidateBoneCache(); ply:SetupBones()
    for _, s in ipairs({ "R", "L" }) do
        local d = (P(ply, "ValveBiped.Bip01_" .. s .. "_Toe0") - P(ply, "ValveBiped.Bip01_" .. s .. "_Foot")):GetNormalized()
        T.ok(d:Dot(bike:GetForward()) > 0.9, s .. " toes point forward: " .. d:Dot(bike:GetForward()))
    end
end)

T.test("IK: the hands close round the grips, curling the right way", function()
    local cl, bike, ply = seated()
    local function gap(s)
        return (P(ply, "ValveBiped.Bip01_" .. s .. "_Finger12") - P(ply, "ValveBiped.Bip01_" .. s .. "_Finger0")):Length()
    end
    ply:InvalidateBoneCache(); ply:SetupBones()
    local openR = gap("R")
    for _ = 1, 10 do frame(cl, bike, ply) end
    ply:InvalidateBoneCache(); ply:SetupBones()
    T.ok(gap("R") < openR * 0.75, string.format("right fingertips close on the thumb (%.2f -> %.2f)", openR, gap("R")))
    T.ok(gap("L") < openR * 0.75, "and the left")
    local ax = cl.env.BMX.RiderCurlAxis[ply:GetModel()][1]
    -- The rig curls about its pitch axis. WHICH WAY depends on the engine's
    -- rotation convention, which is why it is measured, so only the axis is
    -- checked here (the gap above is the behaviour, either way).
    T.ok(ax and math.abs(ax.y) > 0.99, "calibrated onto the rig's pitch axis: " .. tostring(ax))
    for _, f in ipairs({ "2", "3", "4" }) do
        local b = ply:LookupBone("ValveBiped.Bip01_R_Finger" .. f .. "1")
        T.ok(ply._manip[b], "finger " .. f .. " curled too")
    end
end)

T.test("IK: getting off opens the hands and straightens everything", function()
    local cl, bike, ply = seated()
    for _ = 1, 10 do frame(cl, bike, ply) end
    ply._vehicle = nil
    cl.env.hook.Run("PrePlayerDraw", ply)
    for b, a in pairs(ply._manip) do
        T.ok(a.p == 0 and a.y == 0 and a.r == 0, "bone " .. b .. " reset")
    end
end)

T.test("IK: a leg that starts twisted is brought back, knee forward (the pole)", function()
    local cl, bike, ply = seated()
    -- Twist the right thigh a quarter turn about its own length, so the knee
    -- points out sideways: what an unconstrained solve, or a model with other
    -- rest axes, can start from.
    local b = ply:LookupBone("ValveBiped.Bip01_R_Thigh")
    ply.bmxIK = { [b] = cl.env.Angle(0, 0, 90) }
    ply:ManipulateBoneAngles(b, ply.bmxIK[b])
    for _ = 1, 60 do frame(cl, bike, ply) end
    ply:InvalidateBoneCache(); ply:SetupBones()
    local H = P(ply, "ValveBiped.Bip01_R_Thigh")
    local K = P(ply, "ValveBiped.Bip01_R_Calf")
    local F = P(ply, "ValveBiped.Bip01_R_Foot")
    local line = (F - H):GetNormalized()
    local off = ((K - H) - line * (K - H):Dot(line)):GetNormalized()
    T.ok(off:Dot(bike:GetForward()) > 0.5, "knee back to forward: " .. off:Dot(bike:GetForward()))
    T.ok(math.abs(off:Dot(bike:GetRight())) < 0.6, "not out to the side: " .. off:Dot(bike:GetRight()))
end)

T.test("IK: a rider far from the view keeps their pose instead of re-solving", function()
    local cl, bike, ply = seated()
    cl.eyePos = bike:GetPos() + cl.env.Vector(5000, 0, 0)
    cl.setupBones = 0
    for _ = 1, 5 do frame(cl, bike, ply) end
    T.eq(cl.setupBones, 0, "no solving across the map")
    cl.eyePos = bike:GetPos() + cl.env.Vector(200, 0, 0)
    frame(cl, bike, ply)
    T.ok(cl.setupBones > 0, "solving again up close")
end)

T.test("IK: no limb is wrung: twist stays within limits through pedalling and steering", function()
    local cl, bike, ply = seated()
    bike:SetCadence(8)
    local worst = {}
    for i = 1, 90 do
        bike:SetSteer(math.rad(20 * math.sin(i / 10)))
        frame(cl, bike, ply)
        for _, limb in ipairs(cl.env.BMX.RiderLimbs) do
            for kind, name in pairs({ root = limb.root, hinge = limb.hinge }) do
                local a = ply.bmxIK[ply:LookupBone(name)]
                if a then worst[kind] = math.max(worst[kind] or 0, math.abs(a.r)) end
            end
        end
    end
    T.between(worst.root or 0, 0, 30.001, "worst hip/shoulder twist, deg")
    T.between(worst.hinge or 0, 0, 8.001, "worst knee/elbow twist, deg")
    -- And still doing the job while limited, once the bars stop moving (a
    -- sweeping bar is a target the hand follows a frame behind).
    bike:SetSteer(math.rad(10))
    for _ = 1, 20 do frame(cl, bike, ply) end
    ply:InvalidateBoneCache(); ply:SetupBones()
    T.between(reach(cl, ply, "ValveBiped.Bip01_R_Foot", bike.ikTargets.rFoot), 0, 3, "foot on its pedal")
    T.between(reach(cl, ply, "ValveBiped.Bip01_R_Hand", bike.ikTargets.rHand), 0, 3, "hand on its grip")
end)
