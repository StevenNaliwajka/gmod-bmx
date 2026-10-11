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
    -- on the ground and pedalling, so the cranks turn with the wheel (a freewheel
    -- holds them still otherwise: cl_init.lua ENT:Coasting)
    bike:SetGrounded(true)
    bike:SetPedalling(true)
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

-- How far what TOUCHES the bike is from its target: the ball of the foot (the
-- toe bone, for a foot bone) and the inside of the fist (for a hand bone), not
-- the ankle and the wrist the limbs end in (cl_rider.lua, "what touches the bike").
local CONTACT = { ["ValveBiped.Bip01_R_Foot"] = "ValveBiped.Bip01_R_Toe0",
                  ["ValveBiped.Bip01_L_Foot"] = "ValveBiped.Bip01_L_Toe0" }
-- How far a pedal is from being UNDER the foot: from the ankle to the ball. The
-- ball goes on the pedal whenever the leg can fold that far; over the top of
-- the stroke on a low saddle the foot slides forward and the pedal is under the
-- arch (cl_rider.lua ankleSetback), which is still a foot on its pedal.
local function underFoot(cl, ply, side, target)
    ply:InvalidateBoneCache(); ply:SetupBones()
    local a = ply:GetBoneMatrix(ply:LookupBone("ValveBiped.Bip01_" .. side .. "_Foot")):GetTranslation()
    local b = ply:GetBoneMatrix(ply:LookupBone("ValveBiped.Bip01_" .. side .. "_Toe0")):GetTranslation()
    local g = b - a
    local t = math.max(0, math.min(1, (target - a):Dot(g) / g:Dot(g)))
    return (a + g * t - target):Length()
end

local function reach(cl, ply, bone, target)
    local hand = bone:match("_([RL])_Hand$")
    if hand then
        ply:InvalidateBoneCache(); ply:SetupBones()
        return (cl.env.BMX.RiderFistCentre(ply, hand) - target):Length()
    end
    local b = ply:LookupBone(CONTACT[bone] or bone)
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
    T.between(rf, 0, 1.5, "the ball of the right foot to its pedal (forward), units")
    -- the left pedal is at the back, under the saddle: the foot may have slid forward on it
    T.between(underFoot(cl, ply, "L", t.lFoot), 0, 1.5, "left pedal under the left foot")
    T.between(reach(cl, ply, "ValveBiped.Bip01_R_Hand", t.rHandHeld or t.rHand), 0, 1.5, "right hand to its grip")
    T.between(reach(cl, ply, "ValveBiped.Bip01_L_Hand", t.lHandHeld or t.lHand), 0, 1.5, "left hand to its grip")
end)

T.test("IK: pedalling, the feet stay on the pedals all the way round", function()
    local cl, bike, ply = seated()
    bike:SetCadence(0)
    for _ = 1, 40 do frame(cl, bike, ply) end
    -- Pedals turn with the rear wheel now: roll at 180 u/s, about a crank
    -- turn a second.
    bike._vel = bike:GetForward() * 180
    local worst = 0
    for i = 1, 66 do
        frame(cl, bike, ply)
        if i > 5 then
            ply:InvalidateBoneCache(); ply:SetupBones()
            worst = math.max(worst, underFoot(cl, ply, "R", bike.ikTargets.rFoot))
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
    bike._vel = bike:GetForward() * 200
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
    for _ = 1, 40 do frame(cl, bike, ply) end
    bike._vel = bike:GetForward() * 180
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

T.test("IK: toes forward, the sole pitched as the stroke has it, the ball of the foot on the pedal", function()
    local cl, bike, ply = seated()
    for _ = 1, 40 do frame(cl, bike, ply) end
    ply:InvalidateBoneCache(); ply:SetupBones()
    local B = cl.env.BMX
    local fwd, up = bike:GetForward(), bike:GetUp()
    for _, s in ipairs({ "R", "L" }) do
        local d = (P(ply, "ValveBiped.Bip01_" .. s .. "_Toe0") - P(ply, "ValveBiped.Bip01_" .. s .. "_Foot")):GetNormalized()
        local plan = (d - up * d:Dot(up)):GetNormalized()
        T.ok(plan:Dot(fwd) > 0.97, s .. " toes point forward: " .. plan:Dot(fwd))
        local want = B.RiderFootDir(fwd, up, bike.ikTargets[s:lower() .. "Sole"])
        local off = math.deg(math.acos(math.max(-1, math.min(1, d:Dot(want)))))
        T.between(off, 0, 4, s .. " foot pitched as its crank angle wants, deg off")
    end
    -- the ankle's stroke: heel down over the top and front, toes down through the bottom and back
    local top, bottom = B.PedalSole(-math.pi / 4), B.PedalSole(math.pi * 3 / 4)
    T.ok(bottom > top + 15, string.format("toes further down at the back of the stroke (%.0f) than the front (%.0f)", bottom, top))
    T.ok(top < 0, "a heel dropped over the top: " .. top)
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
    bike._vel = bike:GetForward() * 180
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
    T.between(underFoot(cl, ply, "R", bike.ikTargets.rFoot), 0, 3, "foot on its pedal")
    T.between(reach(cl, ply, "ValveBiped.Bip01_R_Hand", bike.ikTargets.rHand), 0, 3, "hand on its grip")
end)

T.test("landing: the rider crouches to soak it up, in proportion, the knees giving over a few frames, then stands", function()
    local cl, bike, ply = seated()
    local function land(vz)
        bike.bmxLandHit, bike.bmxSm = 0, nil
        bike:SetGrounded(false)
        bike._vel = cl.env.Vector(0, 0, vz)
        frame(cl, bike, ply)                  -- in the air, falling
        bike:SetGrounded(true)
        bike._vel = cl.env.Vector()
        frame(cl, bike, ply)                  -- touchdown
        local first, peak = bike.bmxLand, bike.bmxLand
        for _ = 1, 15 do frame(cl, bike, ply) peak = math.max(peak, bike.bmxLand) end
        return peak, first
    end
    T.eq(land(-60), 0, "a gentle touchdown: no crouch")
    local soft = land(-200)
    local hard, first = land(-500)
    T.ok(soft > 0.25 and hard > soft, string.format("a harder landing crouches deeper (%.2f < %.2f)", soft, hard))
    T.ok(first < hard * 0.5, string.format("not all in the touchdown frame (%.2f of %.2f)", first, hard))
    for _ = 1, 60 do frame(cl, bike, ply) end
    T.eq(bike.bmxLand, 0, "and stands back up")
end)

-- What the pose is built from used to be fed straight in: a sprint was ten
-- degrees of tuck in one frame, a change of stance 28. It is followed now
-- (cl_rider.lua SMOOTH), the same at any frame rate.
T.test("smoothing: a sprint and a change of stance ease the torso over, at 30 and at 144 frames a second", function()
    local results = {}
    for _, fps in ipairs({ 30, 144 }) do
        local cl, bike, ply = seated()
        local E = cl.env
        E.GetConVar("bmx_rider_ik"):SetString("0")       -- the body alone
        E.FrameTime = function() return 1 / fps end
        local function lean() return E.BMX.RiderSpineLean(ply) end
        local function run(secs, track)
            local last, worst, t63 = lean(), 0, nil
            local from = last
            for i = 1, math.floor(secs * fps) do
                frame(cl, bike, ply)
                local now = lean()
                worst = math.max(worst, math.abs(now - last))
                last = now
                if track and not t63 and math.abs(now - from) >= 0.63 * math.abs(track - from) then t63 = i / fps end
            end
            return worst, t63, from
        end
        run(1)
        local before = lean()
        bike:SetSprinting(true)
        local worst, t63 = run(0.8, before + E.BMX.RiderAmplitudes.sprintTuck)
        local step = lean() - before
        T.near(step, E.BMX.RiderAmplitudes.sprintTuck, 0.5, fps .. " fps: the whole sprint tuck in the end")
        T.ok(worst < step * (fps == 30 and 0.4 or 0.12), string.format("%d fps: at most %.1f of %.1f degrees a frame", fps, worst, step))
        results[fps] = t63
        ply:SetNWInt("BMXStance", 3)                    -- attack
        local s0 = lean()
        local w2 = run(0.8)
        T.near(lean() - s0, 22, 0.5, fps .. " fps: into the attack stance")
        T.ok(w2 < 22 * (fps == 30 and 0.4 or 0.12), string.format("%d fps: the stance eased, %.1f a frame", fps, w2))
    end
    T.ok(results[30] and results[144] and math.abs(results[30] - results[144]) < 0.05,
        string.format("as quick at 30 as at 144 (%.3f s, %.3f s)", results[30] or -1, results[144] or -1))
end)

-- Out of the saddle a rider's shoulders rock with the pedals and the body dips
-- into each downstroke; seated, barely; coasting, not at all.
T.test("the stroke in the body: out of the saddle the shoulders rock with the cranks, the head holds still", function()
    local cl = client()
    local R = cl.env.BMX.RiderAmplitudes
    local up = pose(cl, { stand = 1, pedal = 1, crank = math.pi / 2 })
    local down = pose(cl, { stand = 1, pedal = 1, crank = 3 * math.pi / 2 })
    T.near(up.spine.r, R.strokeTwist, 1e-6, "a rock one way")
    T.near(down.spine.r, -R.strokeTwist, 1e-6, "and back, half a turn on")
    T.near(up.head.r, -up.spine.r * 0.8, 1e-6, "the head turned back against it")
    T.ok(pose(cl, { stand = 1, pedal = 1, crank = math.pi / 2 }).spine.y >
         pose(cl, { stand = 1, pedal = 1, crank = 0 }).spine.y, "a dip into the downstroke")
    T.ok(math.abs(pose(cl, { stand = 0, pedal = 1, crank = math.pi / 2 }).spine.r) < R.strokeTwist * 0.3, "seated, barely")
    T.eq(pose(cl, { stand = 1, pedal = 0, crank = math.pi / 2 }).spine.r, 0, "coasting, not at all")
    T.near(pose(cl, { sprint = 1, pedal = 1, crank = math.pi / 2 }).spine.r, R.strokeTwist, 1e-6, "a sprint is out of the saddle")
    T.ok(pose(cl, { air = 1 }).head.y > pose(cl, {}).head.y + 5, "in the air the head drops to spot the landing")
end)

T.test("IK: a rider some way off still pedals, solved every few frames", function()
    local cl, bike, ply = seated()
    local n = 0
    cl.env.FrameNumber = function() n = n + 1 return n end
    cl.eyePos = bike:GetPos() + cl.env.Vector(2000, 0, 0)
    local solved = 0
    for _ = 1, 16 do
        cl.setupBones = 0
        frame(cl, bike, ply)
        if cl.setupBones > 0 then solved = solved + 1 end
    end
    T.between(solved, 3, 5, "a quarter of the frames")
end)

T.test("a rider drawn twice in one frame (a reflection) is posed once", function()
    local cl, bike, ply = seated()
    cl.env.FrameNumber = function() return 7 end
    frame(cl, bike, ply)
    cl.setupBones = 0
    cl.env.hook.Run("PrePlayerDraw", ply)
    T.eq(cl.setupBones, 0, "the second draw reuses the first's pose")
end)

T.test("IK: at full lock, both hands stay on the grips, left and right", function()
    local cl, bike, ply = seated()
    local lock = bike:Cfg().Balance.maxSteer
    for _, dir in ipairs({ 1, -1 }) do
        bike:SetSteer(lock * dir)
        for _ = 1, 60 do frame(cl, bike, ply) end
        ply:InvalidateBoneCache(); ply:SetupBones()
        -- To the grip, anywhere along it (the hand takes the nearest point).
        local r = reach(cl, ply, "ValveBiped.Bip01_R_Hand", bike.ikTargets.rHandHeld or bike.ikTargets.rHand)
        local l = reach(cl, ply, "ValveBiped.Bip01_L_Hand", bike.ikTargets.lHandHeld or bike.ikTargets.lHand)
        T.between(r, 0, 2, (dir > 0 and "right" or "left") .. " lock: right hand to its grip")
        T.between(l, 0, 2, (dir > 0 and "right" or "left") .. " lock: left hand to its grip")
    end
end)

T.test("IK: the knees never come into the stomach, all the way round the pedals", function()
    local cl, bike, ply = seated()
    for _ = 1, 30 do frame(cl, bike, ply) end
    bike._vel = bike:GetForward() * 180
    local worst = math.huge
    for _ = 1, 90 do
        frame(cl, bike, ply)
        ply:InvalidateBoneCache(); ply:SetupBones()
        local pel, sp = P(ply, "ValveBiped.Bip01_Pelvis"), P(ply, "ValveBiped.Bip01_Spine2")
        local axis = (sp - pel):GetNormalized()
        for _, s in ipairs({ "R", "L" }) do
            local k = P(ply, "ValveBiped.Bip01_" .. s .. "_Calf")
            if (k - pel):Dot(axis) > 0 then
                worst = math.min(worst, ((k - pel) - axis * (k - pel):Dot(axis)):Length())
            end
        end
    end
    T.ok(worst > 9, string.format("closest a knee gets to the torso's centre line: %.1f", worst))
end)


-- ValveBiped's head is turned half round from its spine (+Y back, +Z right,
-- measured on real models; tests/lib/skeleton.lua), so the pose's "hold the
-- horizon against the spine" nodded the head onto the chest on every real model:
-- a road rider looking at the ground (rider-preview/real-client-v2, 2026-10-10).
T.test("the head looks up the road, not at the ground, however far the rider tucks", function()
    local cl, bike, ply = seated()
    local E = cl.env
    E.GetConVar("bmx_rider_ik"):SetString("0")
    bike:SetSpeedUPS(400)
    bike:SetSprinting(true)
    ply:SetNWInt("BMXStance", 3)                          -- attack: the deepest fold
    for _ = 1, 60 do frame(cl, bike, ply) end
    ply:InvalidateBoneCache(); ply:SetupBones()
    local head = ply:GetBoneMatrix(ply:LookupBone("ValveBiped.Bip01_Head1"))
    local spine = ply:GetBoneMatrix(ply:LookupBone("ValveBiped.Bip01_Spine2"))
    local face = head:GetRight()                          -- the head's -Y: where the face points
    local chest = -spine:GetRight()                       -- the spine's +Y: where the chest points
    local fwd = bike:GetForward()
    T.ok(E.BMX.RiderSpineLean(ply) > 30, "folded well forward: " .. E.BMX.RiderSpineLean(ply))
    T.ok(chest:Dot(E.Vector(0, 0, 1)) < -0.4, "the chest faces down")
    T.ok(face:Dot(E.Vector(0, 0, 1)) > -0.5, string.format("but the face looks ahead, %.0f deg down",
        math.deg(math.asin(-face:Dot(E.Vector(0, 0, 1))))))
    T.ok(face:Dot(fwd) > 0.85, "up the road")
end)

-- A back curves: the lean is shared down the spine's links instead of folding at
-- the shoulder blades.
T.test("the back curves: the lean is shared down the spine, the lower links a little less", function()
    local cl, bike, ply = seated()
    local E = cl.env
    E.GetConVar("bmx_rider_ik"):SetString("0")
    bike:SetSpeedUPS(400)
    for _ = 1, 30 do frame(cl, bike, ply) end
    local function y(name) return ply:GetManipulateBoneAngles(ply:LookupBone("ValveBiped.Bip01_" .. name)).y end
    local low, mid, top = y("Spine"), y("Spine1"), y("Spine2")
    T.ok(low > 0 and mid > 0 and top > 0, string.format("every link bends forward (%.1f %.1f %.1f)", low, mid, top))
    T.ok(low < mid and mid < top, "less low down")
    T.near(low + mid + top, E.BMX.RiderSpineLean(ply), 1e-9, "and they add up to the pose's lean")
end)


-- A rider looks through a corner: the head turns a little way into the turn the bike
-- is making, the same way whichever way it turns, eased, and comes back straight.
T.test("the head looks into the turn, left and right, and back to the road", function()
    local cl, bike, ply = seated()
    local E = cl.env
    E.GetConVar("bmx_rider_ik"):SetString("0")
    local head = ply:LookupBone("ValveBiped.Bip01_Head1")
    local spine = ply:LookupBone("ValveBiped.Bip01_Spine2")
    -- against the rider's own chest (the stand-in's seat is not parented to the bike)
    local function faceSide()
        ply:InvalidateBoneCache(); ply:SetupBones()
        local face = ply:GetBoneMatrix(head):GetRight()       -- the head's -Y: where the face points
        return face:Dot(ply:GetBoneMatrix(spine):GetUp())     -- Spine2's +Z is the rider's left
    end
    for _ = 1, 20 do frame(cl, bike, ply) end
    T.near(faceSide(), 0, 0.05, "riding straight: eyes ahead")
    local function turn(degPerSec)
        for _ = 1, 40 do
            local a = bike:GetAngles()
            bike:SetAngles(E.Angle(a.p, a.y + degPerSec * E.FrameTime(), a.r))
            frame(cl, bike, ply)
        end
        return faceSide()
    end
    local left = turn(90)
    T.ok(left > 0.12, "turning left, the face turns left: " .. left)
    local right = turn(-90)
    T.ok(right < -0.12, "turning right, it turns right: " .. right)
    T.ok(math.abs(turn(0)) < 0.05, "straight again, eyes ahead")
    T.ok(turn(2000) < math.sin(math.rad(30)) + 0.05, "a fast spin turns it no further than the most")
end)

-- THE TOES POINT FOR A PEDAL A STRETCH AWAY (cl_rider.lua, toesFor). Placed beyond
-- where the stroke's sole leaves the ankle in the leg's reach, but within the leg and
-- foot laid in a line, the ball of the foot still reaches it: the ankle extends. A real
-- rider on a penny-farthing had the foot two units off the pedal at the bottom of
-- every stroke before (2026-10-11).
T.test("IK: a pedal a stretch away: the toes point and the ball of the foot reaches it", function()
    local cl, bike, ply = seated()
    local E, B = cl.env, cl.env.BMX
    for _ = 1, 40 do frame(cl, bike, ply) end
    ply:InvalidateBoneCache(); ply:SetupBones()
    local fwd, up = bike:GetForward(), bike:GetUp()
    local hip = P(ply, "ValveBiped.Bip01_R_Thigh")
    local leg = (P(ply, "ValveBiped.Bip01_R_Calf") - hip):Length() + (P(ply, "ValveBiped.Bip01_R_Foot") - P(ply, "ValveBiped.Bip01_R_Calf")):Length()
    local ball = (P(ply, "ValveBiped.Bip01_R_Toe0") - P(ply, "ValveBiped.Bip01_R_Foot")):Length()
    local down = (fwd * 0.25 - up):GetNormalized()
    local T0 = hip + down * (leg + ball * 0.85)
    -- with the stroke's sole the ankle would be out of the leg's reach
    local flat = T0 - B.RiderFootDir(fwd, up, 10) * ball
    T.ok((flat - hip):Length() > leg, string.format("(set up: the ankle a flat sole needs is %.1f from the hip, the leg %.1f)", (flat - hip):Length(), leg))
    local targets = {}
    for k, v in pairs(bike.ikTargets) do targets[k] = v end
    targets.rFoot, targets.rSole = T0, 10
    for _ = 1, 40 do B.SolveRiderIK(ply, targets, bike) end
    ply:InvalidateBoneCache(); ply:SetupBones()
    local toe, ankle = P(ply, "ValveBiped.Bip01_R_Toe0"), P(ply, "ValveBiped.Bip01_R_Foot")
    T.between((toe - T0):Length(), 0, 1.0, "the ball of the foot on the far pedal, units")
    local d = (toe - ankle):GetNormalized()
    local pitch = math.deg(math.asin(-d:Dot(up)))
    T.ok(pitch > 25 + 10 + 10, string.format("the toes pointed: %.0f deg below level, the stroke's sole %.0f", pitch, 25 + 10))
    T.ok(pitch < 25 + 10 + B.RiderToeReach + 2, "no further than the ankle goes")
end)

-- A TARGET THAT JUMPS IS EASED ACROSS (cl_rider.lua, followTarget): a vehicle's model
-- finishing its build moves every grip and pedal at once, and the hands followed in one
-- frame. Now the hand is part way the frame after, and there within JUMP_TIME.
T.test("IK: a grip that jumps is followed across, not snapped to, and a steady one exactly", function()
    local cl, bike, ply = seated()
    local E, B = cl.env, cl.env.BMX
    for _ = 1, 40 do frame(cl, bike, ply) end
    local fwd = bike:GetForward()
    local base = { rHand = bike.ikTargets.rHand, lHand = bike.ikTargets.lHand,
                   rFoot = bike.ikTargets.rFoot, lFoot = bike.ikTargets.lFoot,
                   rSole = bike.ikTargets.rSole, lSole = bike.ikTargets.lSole }
    local function solve(shift, n)
        local t = {}
        for k, v in pairs(base) do t[k] = v end
        t.rHand, t.lHand = base.rHand + fwd * shift, base.lHand + fwd * shift
        for _ = 1, n do B.SolveRiderIK(ply, t, bike) end
        ply:InvalidateBoneCache(); ply:SetupBones()
        return (B.RiderFistCentre(ply, "R") - t.rHand):Length(), (B.RiderFistCentre(ply, "R") - base.rHand):Length()
    end
    local atNew = solve(0, 30)
    T.between(atNew, 0, 1.5, "settled on the grip")
    -- 8 units toward the rider in one frame: a jump
    local frames = math.ceil(B.RiderJump.time / E.FrameTime())
    local toNew = solve(-8, 1)
    T.ok(toNew > 6, string.format("the frame after, not there yet (it eases in): %.1f from the new grip", toNew))
    local midNew, midOld = solve(-8, math.floor(frames / 2) - 1)
    T.ok(midNew > 2 and midOld > 2, string.format("half way through, between the two: %.1f from the new, %.1f from the old", midNew, midOld))
    T.between(solve(-8, frames), 0, 1.5, "and on the new grip within the easing time")
    -- small steady steps (a turning bar) are followed as they come
    local worst = 0
    for i = 1, 20 do worst = math.max(worst, (solve(-8 + i * 0.3, 1))) end
    T.between(worst, 0, 1.5, "a grip moving steadily is held all the way")
end)
