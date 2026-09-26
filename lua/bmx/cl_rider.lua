--[[--------------------------------------------------------------------------
    bmx/cl_rider.lua

    The rider's body.

    Without this a rider is whatever the prisoner pod gives them: the chair
    pose, hands on knees, frozen for the whole ride, which reads as a mannequin
    bolted to a bike. Two layers fix it, both client-side and both built from
    what already ships with every player model:

      1. THE BASE POSE. `drive_airboat`, the stock seated pose with both hands
         forward on handlebars, in place of the chair sit. CalcMainActivity.

      2. MOTION ON TOP, by bone manipulation, driven entirely by what the bike
         already networks: the legs pedal in step with the DRAWN cranks
         (cl_init keeps bike.crankAngle), and stop when coasting; the body
         tucks forward with speed and further when sprinting; it crouches while
         a hop is preloaded; it sits back through a wheelie and forward in a
         stoppie; the arms turn with the bars.

    Nothing here is simulated or networked: every client works out every
    rider's pose from the bike it is on, at no cost to the server.

    THE POSE IS A PURE FUNCTION (BMX.RiderPose), so the suite can check it
    without a renderer: which bones, which way, in step with what. Whether it
    LOOKS right is a human question, and bone axes do differ between player
    models, so `bmx_rider_anim 0` turns layer 2 off and every amplitude is in
    the RIDER table below.
----------------------------------------------------------------------------]]

BMX = BMX or {}

local cv_anim = CreateClientConVar("bmx_rider_anim", "1", true, false,
    "Animate BMX riders (pedalling, lean, crouch). 0 leaves the plain seated pose.")
local cv_ik = CreateClientConVar("bmx_rider_ik", "1", true, false,
    "Put riders' hands on the grips and feet on the pedals (IK). 0 uses the simple swing.")

--------------------------------------------------------------------------
-- Amplitudes, degrees. Source bones rotate about their own local axes; on the
-- ValveBiped skeleton every stock player model uses, flexing a thigh, knee or
-- the spine forward is the Y (second) component.
--------------------------------------------------------------------------
local RIDER = {
    thighSwing   = 22,     -- pedalling: thigh up and down through a stroke
    calfSwing    = 26,     -- and the knee opening and closing, a quarter behind
    tuckMax      = 18,     -- spine forward at full speed
    sprintTuck   = 10,     -- extra when sprinting: up out of the saddle
    crouch       = 24,     -- hop preload: knees and hips fold
    pitchFollow  = 0.5,    -- how much of the bike's pitch the torso counters
    armSteer     = 0.6,    -- fraction of the steer angle the arms follow
}
BMX.RiderAmplitudes = RIDER

local BONES = {
    rThigh = "ValveBiped.Bip01_R_Thigh", rCalf = "ValveBiped.Bip01_R_Calf",
    lThigh = "ValveBiped.Bip01_L_Thigh", lCalf = "ValveBiped.Bip01_L_Calf",
    spine  = "ValveBiped.Bip01_Spine2",  head  = "ValveBiped.Bip01_Head1",
    rArm   = "ValveBiped.Bip01_R_UpperArm", lArm = "ValveBiped.Bip01_L_UpperArm",
}
BMX.RiderBones = BONES

--------------------------------------------------------------------------
-- The pose, as { boneKey = Angle } offsets from the base pose.
--
--   s.crank     crank angle, rad (the drawn cranks')
--   s.speed     u/s
--   s.topSpeed  u/s, the cadence-limited top speed
--   s.sprint    bool
--   s.hop       0..1 preload
--   s.pitch     bike pitch, rad, nose up positive
--   s.steer     rad
--------------------------------------------------------------------------
function BMX.RiderPose(s)
    local R = RIDER
    local c = s.crank or 0

    -- Pedalling: right leg on the crank's angle, left leg half a turn behind,
    -- because that is where its pedal is.
    local rT = math.sin(c) * R.thighSwing
    local lT = math.sin(c + math.pi) * R.thighSwing
    local rC = math.sin(c + math.pi * 0.5) * R.calfSwing
    local lC = math.sin(c + math.pi * 1.5) * R.calfSwing

    -- Crouch for a hop: both legs fold further, the body goes down and forward.
    local crouch = (s.hop or 0) * R.crouch
    rT, lT = rT - crouch, lT - crouch
    rC, lC = rC + crouch * 1.4, lC + crouch * 1.4

    -- Tuck with speed, more on a sprint; counter the bike's pitch so the rider
    -- stays over the bike: back through a wheelie, forward in a stoppie.
    local frac  = math.Clamp((s.speed or 0) / math.max(s.topSpeed or 1, 1), 0, 1)
    local tuck  = frac * R.tuckMax + (s.sprint and R.sprintTuck or 0) + crouch * 0.6
    local spine = tuck + math.deg(s.pitch or 0) * R.pitchFollow

    local arm = math.deg(s.steer or 0) * R.armSteer

    return {
        rThigh = Angle(0, rT, 0), lThigh = Angle(0, lT, 0),
        rCalf  = Angle(0, rC, 0), lCalf  = Angle(0, lC, 0),
        spine  = Angle(0, spine, 0),
        -- The head holds the horizon against the spine, so the rider looks
        -- down the road rather than at the front tyre.
        head   = Angle(0, -spine * 0.7, 0),
        rArm   = Angle(arm, 0, 0), lArm = Angle(arm, 0, 0),
    }
end

--------------------------------------------------------------------------
-- HANDS ON THE GRIPS, FEET ON THE PEDALS: inverse kinematics.
--
-- Bone offsets from a pose only nudge limbs, so the swing above never put a
-- foot on a pedal or a hand on a bar, and a rider on the server said so.
-- This does: cyclic coordinate descent, one pass a frame. For each joint in a
-- limb (the knee, then the hip; the elbow, then the shoulder), turn it so the
-- hand or foot points at its target, measured on the real skeleton the engine
-- just posed. The bike records where its pedals and grips are when it is drawn
-- (cl_init.lua, bike.ikTargets), so the legs follow the pedal circle on their
-- own: no pedalling animation to keep in step with anything.
--
-- Solved in the bone's own frame, so it works on any skeleton, and GUARDED,
-- because nobody has watched it on a real model: each step is capped, every
-- joint's total is capped, and a step that leaves the hand or foot further
-- from its target is reversed. That last part also settles which way the
-- engine's RotateAroundAxis turns: the first steps that go well fix the sign.
--------------------------------------------------------------------------
local LIMBS = {
    { eff = "ValveBiped.Bip01_R_Foot", target = "rFoot", side = 1, leg = true,
      hinge = "ValveBiped.Bip01_R_Calf", root = "ValveBiped.Bip01_R_Thigh" },
    { eff = "ValveBiped.Bip01_L_Foot", target = "lFoot", side = -1, leg = true,
      hinge = "ValveBiped.Bip01_L_Calf", root = "ValveBiped.Bip01_L_Thigh" },
    { eff = "ValveBiped.Bip01_R_Hand", target = "rHand", side = 1,
      hinge = "ValveBiped.Bip01_R_Forearm", root = "ValveBiped.Bip01_R_UpperArm" },
    { eff = "ValveBiped.Bip01_L_Hand", target = "lHand", side = -1,
      hinge = "ValveBiped.Bip01_L_Forearm", root = "ValveBiped.Bip01_L_UpperArm" },
}
BMX.RiderLimbs = LIMBS

local IK_RANGE  = 1200     -- units from the view; further riders keep their pose
local MAX_STEP  = 25       -- degrees per joint per frame
local MAX_TOTAL = 150      -- degrees, any component of a joint's correction
-- TWIST, the roll of a bone about its own length, is what wrings a limb's
-- mesh like a sweet wrapper. A manipulation angle is yaw, then pitch, then
-- roll about the bone's own length, so its ROLL is exactly that twist, and
-- clamping it limits the twist without changing where the bone points.
-- Hinges barely twist at all (a knee cannot), hips and shoulders a little.
local TWIST = { root = 30, hinge = 8, tip = 35 }
local MIN_BEND  = 15       -- a knee or elbow never straightens past this...
local MAX_BEND  = 155      -- ...or folds past this, degrees

local function refresh(ply)
    ply:InvalidateBoneCache()
    ply:SetupBones()
end

local function bonePos(ply, b)
    local m = ply:GetBoneMatrix(b)
    return m and m:GetTranslation()
end

-- A world axis, in a bone's own frame (GMod matrices: -Y is GetRight).
local function toLocal(M, axis)
    return Vector(axis:Dot(M:GetForward()), -axis:Dot(M:GetRight()), axis:Dot(M:GetUp()))
end

-- manip * R(axisLocal, deg): a turn in the bone's own frame, after the pose.
local function turned(manip, axisLocal, deg, twist)
    local d = Angle(0, 0, 0)
    d:RotateAroundAxis(axisLocal, deg)
    local m = Matrix()
    m:SetAngles(manip)
    m:Rotate(d)
    local a = m:GetAngles()
    if a.p ~= a.p or a.y ~= a.y or a.r ~= a.r then return nil end
    if math.abs(a.p) > MAX_TOTAL then return nil end
    if twist then a.r = math.Clamp(a.r, -twist, twist) end
    return a
end

local function setManip(ply, b, a)
    ply.bmxIK[b] = a
    ply:ManipulateBoneAngles(b, a)
end

-- Signed angle from u to v about unit axis h, both first flattened onto the
-- plane square to h. Degrees.
local function planeAngle(u, v, h)
    u = u - h * u:Dot(h)
    v = v - h * v:Dot(h)
    if u:Length() < 1e-4 or v:Length() < 1e-4 then return 0 end
    u:Normalize(); v:Normalize()
    return math.deg(math.atan2(u:Cross(v):Dot(h), u:Dot(v)))
end

-- Turn bone `b` about WORLD axis `h` by `deg`, keeping the change only if
-- `better()` says it helped. The engine's rotation sign is not assumed: if the
-- turn made things worse the opposite one is tried, and the first answers fix
-- the sign for good (ikSign). Tested converging under both conventions.
local ikSign, ikVotes = nil, 0
local function tryTurn(ply, b, h, deg, better, twist)
    local M = ply:GetBoneMatrix(b)
    if not M or math.abs(deg) < 0.05 then return false end
    local axisLocal = toLocal(M, h)
    local old = ply.bmxIK[b] or Angle(0, 0, 0)
    for _, sign in ipairs(ikSign and { ikSign } or { 1, -1 }) do
        local cand = turned(old, axisLocal, deg * sign, twist)
        if cand then
            setManip(ply, b, cand)
            refresh(ply)
            if better() then
                if not ikSign then
                    ikVotes = ikVotes + sign
                    if math.abs(ikVotes) >= 6 then ikSign = ikVotes > 0 and 1 or -1 end
                end
                return true
            end
        end
    end
    setManip(ply, b, old)
    refresh(ply)
    return false
end

local function bend(ply, root, hinge, eff)
    local H, K, F = bonePos(ply, root), bonePos(ply, hinge), bonePos(ply, eff)
    local u, v = (K - H):GetNormalized(), (F - K):GetNormalized()
    return math.deg(math.acos(math.Clamp(u:Dot(v), -1, 1))), H, K, F
end

--------------------------------------------------------------------------
-- One limb: hinge, then root, then the pole.
--
-- THE KNEE AND ELBOW ARE HINGES. The first version turned every joint freely
-- in 3D, and a solver free to twist a shin sideways or fold a knee backwards
-- will do it to reach a pedal: riders' legs "deformed and contorted below the
-- bike". So the hinge only turns about the axis the limb already bends
-- around, and stays between MIN_BEND and MAX_BEND. Then THE POLE: spinning
-- the thigh (or upper arm) about the hip-to-foot line moves the knee without
-- moving the foot, and it is turned until the knee points forward and up
-- (the elbow out and down), where a rider's are.
--------------------------------------------------------------------------
local function solveLimb(ply, limb, T, pole)
    local rb, hb, eb = ply:LookupBone(limb.root), ply:LookupBone(limb.hinge),
        ply:LookupBone(limb.eff)
    if not (rb and hb and eb) then return end
    local function err() return (bonePos(ply, eb) - T):Length() end

    -- Hinge. Its axis is the normal of the plane the limb bends in now,
    -- remembered so a nearly straight limb does not lose it.
    refresh(ply)
    local _, H, K, F = bend(ply, rb, hb, eb)
    ply.bmxHinge = ply.bmxHinge or {}
    local h = (K - H):Cross(F - K)
    if h:Length() > 1e-3 then
        h:Normalize()
        ply.bmxHinge[hb] = h
    else
        h = ply.bmxHinge[hb]
    end
    if h then
        local deg = math.Clamp(planeAngle(F - K, T - K, h), -MAX_STEP, MAX_STEP)
        local e0 = err()
        tryTurn(ply, hb, h, deg, function()
            local b1 = bend(ply, rb, hb, eb)
            return err() < e0 and b1 >= MIN_BEND and b1 <= MAX_BEND
        end, TWIST.hinge)
    end

    -- Root: a ball joint, pointing the whole limb at the target.
    refresh(ply)
    local R = bonePos(ply, rb)
    local a, c = (bonePos(ply, eb) - R), (T - R)
    if a:Length() > 1e-3 and c:Length() > 1e-3 then
        a:Normalize(); c:Normalize()
        local axis = a:Cross(c)
        local sn = axis:Length()
        if sn > 1e-4 then
            axis = axis / sn
            local deg = math.min(math.deg(math.atan2(sn, a:Dot(c))), MAX_STEP)
            local e0 = err()
            tryTurn(ply, rb, axis, deg, function() return err() < e0 end, TWIST.root)
        end
    end

    -- Pole: spin about root-to-effector, which leaves the effector where it is.
    refresh(ply)
    local _, H2, K2, F2 = bend(ply, rb, hb, eb)
    local line = F2 - H2
    if line:Length() > 1e-3 then
        line:Normalize()
        local deg = math.Clamp(planeAngle(K2 - H2, pole, line), -MAX_STEP, MAX_STEP)
        local function poleErr()
            local _, h3, k3, f3 = bend(ply, rb, hb, eb)
            return math.abs(planeAngle(k3 - h3, pole, (f3 - h3):GetNormalized()))
        end
        local p0 = poleErr()
        tryTurn(ply, rb, line, deg, function() return poleErr() < p0 end, TWIST.root)
    end
end

-- Turn bone `b` so the direction from bone `fromB` to bone `toB` points along
-- `want`. Used to put a sole flat on a pedal and knuckles over a bar.
local function aim(ply, b, fromB, toB, want)
    refresh(ply)
    local a = bonePos(ply, toB) - bonePos(ply, fromB)
    if a:Length() < 1e-3 then return end
    a:Normalize()
    local axis = a:Cross(want)
    local sn = axis:Length()
    if sn < 1e-4 then return end
    axis = axis / sn
    local deg = math.min(math.deg(math.atan2(sn, a:Dot(want))), MAX_STEP)
    local function off()
        local d = (bonePos(ply, toB) - bonePos(ply, fromB)):GetNormalized()
        return math.acos(math.Clamp(d:Dot(want), -1, 1))
    end
    local o0 = off()
    tryTurn(ply, b, axis, deg, function() return off() < o0 end, TWIST.tip)
end

--------------------------------------------------------------------------
-- CLOSED HANDS. Which way a finger curls into the palm is a property of the
-- skeleton, and guessing wrong bends fingers backwards. So it is MEASURED,
-- once per model on this client: the index finger's base is turned a little
-- about each of its axes, both ways, and the turn that brings its tip closest
-- to the thumb's base is the curl (curling closes that gap; bending back or
-- spreading does not). Every finger is then curled about that axis. The
-- server cannot do this for us: SetupBones is client-only, and the server's
-- bones do not see manipulations (measured, 2026-09-26).
--------------------------------------------------------------------------
local FINGERS = { "1", "2", "3", "4" }
local CURL = 55                    -- degrees at each finger joint: round a grip
local curlAxis = {}                -- model -> side -> local axis, or false
BMX.RiderCurlAxis = curlAxis

local function fingerBones(ply, side, f)
    local p = "ValveBiped.Bip01_" .. (side == 1 and "R" or "L") .. "_Finger" .. f
    return ply:LookupBone(p), ply:LookupBone(p .. "1"), ply:LookupBone(p .. "2")
end

local function calibrateCurl(ply, side)
    local base, _, tip = fingerBones(ply, side, "1")
    local thumb = ply:LookupBone("ValveBiped.Bip01_" .. (side == 1 and "R" or "L") .. "_Finger0")
    if not (base and tip and thumb) then return nil end
    local best, bestD
    local old = ply:GetManipulateBoneAngles(base)
    for _, ax in ipairs({ Vector(1, 0, 0), Vector(0, 1, 0), Vector(0, 0, 1) }) do
        for _, sg in ipairs({ 1, -1 }) do
            local d = Angle(0, 0, 0)
            d:RotateAroundAxis(ax, 40 * sg)
            ply:ManipulateBoneAngles(base, d)
            refresh(ply)
            local dist = (bonePos(ply, tip) - bonePos(ply, thumb)):Length()
            if not bestD or dist < bestD then best, bestD = ax * sg, dist end
        end
    end
    ply:ManipulateBoneAngles(base, old)
    refresh(ply)
    return best
end

local function closeHand(ply, side)
    local model = ply:GetModel()
    curlAxis[model] = curlAxis[model] or {}
    local ax = curlAxis[model][side]
    if ax == nil then
        ax = calibrateCurl(ply, side) or false
        curlAxis[model][side] = ax
    end
    if not ax then return end
    local curl = Angle(0, 0, 0)
    curl:RotateAroundAxis(ax, CURL)
    for _, f in ipairs(FINGERS) do
        for _, b in ipairs({ fingerBones(ply, side, f) }) do
            ply.bmxIK[b] = curl
            ply:ManipulateBoneAngles(b, curl)
        end
    end
end

function BMX.SolveRiderIK(ply, targets, bike)
    ply.bmxIK = ply.bmxIK or {}
    local fwd, up, right = bike:GetForward(), bike:GetUp(), bike:GetRight()
    for _, limb in ipairs(LIMBS) do
        local T = targets[limb.target]
        if T then
            -- Knees forward and up; elbows out, down and back.
            local pole = limb.leg and (fwd + up * 0.6)
                or (right * limb.side - up * 0.6 - fwd * 0.3)
            solveLimb(ply, limb, T, pole:GetNormalized())

            local s = limb.side == 1 and "R" or "L"
            local eb = ply:LookupBone(limb.eff)
            if limb.leg then
                -- Toes forward, sole on the pedal.
                local toe = ply:LookupBone("ValveBiped.Bip01_" .. s .. "_Toe0")
                -- Twice: the leg solve just turned the foot with the shin.
                if eb and toe then aim(ply, eb, eb, toe, fwd); aim(ply, eb, eb, toe, fwd) end
            else
                -- Knuckles forward over the bar, then the fingers closed round it.
                local knuck = ply:LookupBone("ValveBiped.Bip01_" .. s .. "_Finger2")
                if eb and knuck then aim(ply, eb, eb, knuck, (fwd - up * 0.3):GetNormalized()) end
                closeHand(ply, limb.side)
            end
        end
    end
end

--------------------------------------------------------------------------
-- Layer 1: the base pose.
--------------------------------------------------------------------------
hook.Add("CalcMainActivity", "BMX.RiderPose", function(ply)
    local bike = BMX.LocalBike(ply)
    if not bike then return end
    local seq = ply:LookupSequence("drive_airboat")
    if not seq or seq < 0 then return end       -- a model without it keeps its own
    return ACT_DRIVE_AIRBOAT, seq
end)

--------------------------------------------------------------------------
-- Layer 2: motion. Applied just before each player is drawn, and cleared from
-- anyone who has got off, so a rider never walks away with pedalling legs.
--------------------------------------------------------------------------
local animated = {}     -- player -> true while we have bones moved on them
local LIMB_KEYS = { rThigh = true, lThigh = true, rCalf = true, lCalf = true,
                    rArm = true, lArm = true }

local function clear(ply)
    for _, name in pairs(BONES) do
        local b = ply:LookupBone(name)
        if b then ply:ManipulateBoneAngles(b, Angle(0, 0, 0)) end
    end
    for b in pairs(ply.bmxIK or {}) do ply:ManipulateBoneAngles(b, Angle(0, 0, 0)) end
    ply.bmxIK, ply.bmxHinge = nil, nil
    animated[ply] = nil
end
BMX.ClearRiderPose = clear

hook.Add("PrePlayerDraw", "BMX.RiderMotion", function(ply)
    local bike = cv_anim:GetBool() and BMX.LocalBike(ply) or nil
    if not bike then
        if animated[ply] then clear(ply) end
        return
    end

    local C = bike:Cfg()
    local useIK = cv_ik:GetBool() and bike.ikTargets ~= nil
    local pose = BMX.RiderPose({
        crank    = bike.crankAngle or 0,
        speed    = bike:GetSpeedUPS(),
        topSpeed = C.Drive.maxCadence * C.Drive.gearRatio * C.Wheel.radius,
        sprint   = bike:GetSprinting(),
        hop      = bike:GetHopCharge(),
        pitch    = select(2, BMX.Attitude(bike, vector_up)),
        steer    = bike:GetSteer(),
    })
    for key, ang in pairs(pose) do
        -- With IK on, the limbs are the solver's; the pose keeps the body.
        if not (useIK and LIMB_KEYS[key]) then
            local b = ply:LookupBone(BONES[key])
            if b then ply:ManipulateBoneAngles(b, ang) end
        end
    end
    -- The solve re-poses the skeleton a few dozen times, which is nothing for
    -- the riders near you and waste for one across the map, so a rider far
    -- from the view keeps the pose they last had (manipulations persist).
    if useIK and EyePos():Distance(ply:GetPos()) < IK_RANGE then
        BMX.SolveRiderIK(ply, bike.ikTargets, bike)
    end
    animated[ply] = true
end)

--------------------------------------------------------------------------
-- The reach-down while a fallen bike is picked up (BMX.BeginPickUp). A
-- gesture, layered over whatever the player is doing, from the stock set.
--------------------------------------------------------------------------
net.Receive("bmx_gesture", function()
    local ply = net.ReadEntity()
    local what = net.ReadString()
    if not IsValid(ply) or what ~= "pickup" then return end
    ply:AnimRestartGesture(GESTURE_SLOT_CUSTOM, ACT_GMOD_GESTURE_ITEM_PLACE, true)
end)

--------------------------------------------------------------------------
-- A crash ragdoll wears its rider's player colour: the PlayerColor material
-- proxy calls ent:GetPlayerColor(), which only players have, so the ragdoll
-- (BMX.Tumble) carries the colour in a networked var and is given the method.
--------------------------------------------------------------------------
--
-- LOOKED UP WHEN DRAWN, not when created. The first version read the
-- networked colour a tick after the ragdoll appeared, and it had often not
-- arrived yet, so the ragdoll kept the default colour: a rider in red tumbled
-- off in the stock grey-blue. Every ragdoll now answers GetPlayerColor
-- itself, from the networked value or, failing that, from its rider.
local function ragdollColour(self)
    local col = self:GetNWVector("BMXPlayerColor", nil)
    if col then return col end
    local rider = self:GetNWEntity("BMXRider", NULL)
    if IsValid(rider) and rider.GetPlayerColor then return rider:GetPlayerColor() end
end

hook.Add("OnEntityCreated", "BMX.RagdollColour", function(e)
    if IsValid(e) and e:GetClass() == "prop_ragdoll" and not e.GetPlayerColor then
        e.GetPlayerColor = ragdollColour
    end
end)

--------------------------------------------------------------------------
-- No pickup notices while a tumble gives the player their things back
-- (BMX.Tumble): the server asks for quiet just before it re-gives them.
--------------------------------------------------------------------------
local quietUntil = 0
net.Receive("bmx_quiet", function() quietUntil = CurTime() + net.ReadFloat() end)
local function quiet() if CurTime() < quietUntil then return true end end
hook.Add("HUDWeaponPickedUp", "BMX.QuietRestore", quiet)
hook.Add("HUDAmmoPickedUp",   "BMX.QuietRestore", quiet)
hook.Add("HUDItemPickedUp",   "BMX.QuietRestore", quiet)

-- Players that leave the server take their entry with them.
hook.Add("EntityRemoved", "BMX.RiderForget", function(e) animated[e] = nil end)
