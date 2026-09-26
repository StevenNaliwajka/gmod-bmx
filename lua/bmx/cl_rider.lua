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
    { eff = "ValveBiped.Bip01_R_Foot", target = "rFoot",
      chain = { "ValveBiped.Bip01_R_Calf", "ValveBiped.Bip01_R_Thigh" } },
    { eff = "ValveBiped.Bip01_L_Foot", target = "lFoot",
      chain = { "ValveBiped.Bip01_L_Calf", "ValveBiped.Bip01_L_Thigh" } },
    { eff = "ValveBiped.Bip01_R_Hand", target = "rHand",
      chain = { "ValveBiped.Bip01_R_Forearm", "ValveBiped.Bip01_R_UpperArm" } },
    { eff = "ValveBiped.Bip01_L_Hand", target = "lHand",
      chain = { "ValveBiped.Bip01_L_Forearm", "ValveBiped.Bip01_L_UpperArm" } },
}
BMX.RiderLimbs = LIMBS

local MAX_STEP  = 25       -- degrees per joint per frame
local MAX_TOTAL = 150      -- degrees, any component of a joint's correction
local ikSign, ikVotes = nil, 0

local function refresh(ply)
    ply:InvalidateBoneCache()
    ply:SetupBones()
end

local function bonePos(ply, b)
    local m = ply:GetBoneMatrix(b)
    return m and m:GetTranslation()
end

-- manip * R(axisLocal, deg): a turn in the bone's own frame, after the pose.
local function turned(manip, axisLocal, deg)
    local d = Angle(0, 0, 0)
    d:RotateAroundAxis(axisLocal, deg)
    local m = Matrix()
    m:SetAngles(manip)
    m:Rotate(d)
    local a = m:GetAngles()
    if a.p ~= a.p or a.y ~= a.y or a.r ~= a.r then return nil end
    if math.abs(a.p) > MAX_TOTAL or math.abs(a.r) > MAX_TOTAL then return nil end
    return a
end

local function setManip(ply, b, a)
    ply.bmxIK[b] = a
    ply:ManipulateBoneAngles(b, a)
end

function BMX.SolveRiderIK(ply, targets)
    ply.bmxIK = ply.bmxIK or {}
    for _, limb in ipairs(LIMBS) do
        local T = targets[limb.target]
        local eb = ply:LookupBone(limb.eff)
        if T and eb then
            for _, name in ipairs(limb.chain) do
                local jb = ply:LookupBone(name)
                if jb then
                    refresh(ply)
                    local E = bonePos(ply, eb)
                    local J = ply:GetBoneMatrix(jb)
                    if E and J then
                        local P = J:GetTranslation()
                        local a, c = E - P, T - P
                        if a:Length() > 1e-3 and c:Length() > 1e-3 then
                            a:Normalize(); c:Normalize()
                            local axis = a:Cross(c)
                            local s = axis:Length()
                            if s > 1e-4 then
                                axis = axis / s
                                local deg = math.min(math.deg(math.atan2(s, a:Dot(c))), MAX_STEP)
                                local axisLocal = Vector(axis:Dot(J:GetForward()),
                                    -axis:Dot(J:GetRight()), axis:Dot(J:GetUp()))
                                local old = ply.bmxIK[jb] or Angle(0, 0, 0)
                                local before = (E - T):Length()

                                -- Try the sign we believe in (or +, before we know).
                                local sign = ikSign or 1
                                local cand = turned(old, axisLocal, deg * sign)
                                local ok = false
                                if cand then
                                    setManip(ply, jb, cand)
                                    refresh(ply)
                                    ok = (bonePos(ply, eb) - T):Length() < before
                                end
                                if not ok and not ikSign then
                                    cand = turned(old, axisLocal, -deg)
                                    if cand then
                                        setManip(ply, jb, cand)
                                        refresh(ply)
                                        ok = (bonePos(ply, eb) - T):Length() < before
                                        if ok then sign = -1 end
                                    end
                                end
                                if ok and not ikSign then
                                    if sign == (ikVotes >= 0 and 1 or -1) or ikVotes == 0 then
                                        ikVotes = ikVotes + sign
                                    else
                                        ikVotes = 0
                                    end
                                    if math.abs(ikVotes) >= 6 then ikSign = ikVotes > 0 and 1 or -1 end
                                end
                                if not ok then setManip(ply, jb, old) end
                            end
                        end
                    end
                end
            end
        end
    end
end
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
    ply.bmxIK = nil
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
    if useIK then BMX.SolveRiderIK(ply, bike.ikTargets) end
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
hook.Add("OnEntityCreated", "BMX.RagdollColour", function(e)
    timer.Simple(0, function()
        if not IsValid(e) or e:GetClass() ~= "prop_ragdoll" then return end
        local col = e:GetNWVector("BMXPlayerColor", nil)
        if col then e.GetPlayerColor = function() return col end end
    end)
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
