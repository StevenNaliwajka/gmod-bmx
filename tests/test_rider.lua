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
