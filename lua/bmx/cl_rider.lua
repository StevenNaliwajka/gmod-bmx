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
    -- WEIGHT FORWARD (G02): at full lean the torso folds this much further over
    -- the bars and the hips drop back, the hands staying on the grips (the IK
    -- reaches them from the new shoulder position), the head up to watch the
    -- road, and the legs fold a little under the weight.
    leanFwd      = 24,     -- degrees of extra spine lean
    leanFwdHips  = 9,      -- degrees of extra thigh fold
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
--   s.leanFwd   0..1 weight forward over the bars (G02)
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
    local lean  = BMX.Clamp(s.leanFwd or 0, 0, 1)
    rT, lT = rT - lean * R.leanFwdHips, lT - lean * R.leanFwdHips
    local tuck  = frac * R.tuckMax + (s.sprint and R.sprintTuck or 0) + crouch * 0.6
    local spine = tuck + lean * R.leanFwd + math.deg(s.pitch or 0) * R.pitchFollow

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

-- Turn bone `b` so the direction from bone `fromB` to bone `toB` points along
-- `want`. Used to put a sole flat on a pedal and knuckles over a bar.
local function aim(ply, b, fromB, toB, want, twist)
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
    tryTurn(ply, b, axis, deg, function() return off() < o0 end, twist or TWIST.tip)
end

--------------------------------------------------------------------------
-- One limb: ANALYTIC two-bone IK.
--
-- The first versions nudged each joint toward the target in turn (cyclic
-- coordinate descent). That was fine riding straight and it got STUCK at full
-- lock: the grip is well within reach (16 units from the shoulder, 23 of arm)
-- but with the elbow's plane fixed from the old pose and a pole pulling the
-- other way, it settled 11 units short and the hand came off the bar.
--
-- A two-bone limb has an exact answer, so this computes it: from the root,
-- the target and the two bone lengths, the elbow or knee sits where the law
-- of cosines puts it, in the plane that faces the pole (knee forward, elbow
-- out and down). Each bone is then pointed at the next point. It cannot get
-- stuck, it reaches whatever is in reach, and it bends the limb the way the
-- pole says every time -- which also keeps a knee out in front of the stomach
-- at the top of the pedal stroke, where a pole with too much "up" in it had
-- lifted it into the rider.
--------------------------------------------------------------------------
local function solveLimb(ply, limb, T, pole)
    local rb, hb, eb = ply:LookupBone(limb.root), ply:LookupBone(limb.hinge),
        ply:LookupBone(limb.eff)
    if not (rb and hb and eb) then return end
    for _ = 1, 2 do
        refresh(ply)
        local R, K, F = bonePos(ply, rb), bonePos(ply, hb), bonePos(ply, eb)
        local la, lb = (K - R):Length(), (F - K):Length()
        local toT = T - R
        local d = toT:Length()
        if d < 1e-3 or la < 1e-3 or lb < 1e-3 then return end
        local dir = toT / d
        -- In reach, and never so close that the joint would have to fold
        -- past MAX_BEND (the law of cosines at that fold is the least
        -- distance the two bones can span).
        local inner = math.rad(180 - MAX_BEND)
        local dMin = math.sqrt(la * la + lb * lb - 2 * la * lb * math.cos(inner))
        d = math.Clamp(d, dMin, (la + lb) * 0.999)
        local along = (la * la - lb * lb + d * d) / (2 * d)
        local h = math.sqrt(math.max(la * la - along * along, 0))
        local side = pole - dir * pole:Dot(dir)
        if side:Length() < 1e-3 then side = (K - R) - dir * (K - R):Dot(dir) end
        side:Normalize()
        local joint = R + dir * along + side * h
        aim(ply, rb, rb, hb, (joint - R):GetNormalized(), TWIST.root)
        refresh(ply)
        local K2 = bonePos(ply, hb)
        aim(ply, hb, hb, eb, (R + dir * d - K2):GetNormalized(), TWIST.hinge)
    end
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

--------------------------------------------------------------------------
-- THE TORSO TURNS WITH THE BARS. At full lock the outer grip swings ~7 units
-- forward, beyond an arm hanging from shoulders square to the bike, and the
-- hand came off it. A rider turns their upper body into the bars; so when a
-- hand is off its grip, the spine is twisted about its own length (the roll
-- of its manipulation: the twist, as for every bone here) a few degrees at a
-- time, the way that brings both hands closer, up to SPINE_TWIST. When the
-- hands are home it eases back to square. Kept in ply.bmxSpineTwist, because
-- the pose (tuck, lean) rewrites the spine's angle every frame.
--------------------------------------------------------------------------
local SPINE_TWIST = 40     -- degrees either way, about the spine's length
local SPINE_LEAN  = 30     -- degrees of extra lean toward the bars
local SPINE_STEP  = 4      -- degrees a frame

-- How far each grip is beyond its shoulder's reach, summed. Scored on REACH,
-- not on where the hands are now: a twist trial moves the hands with the
-- shoulders before the arms have re-solved, so judged by the hands every
-- trial looked worse and the torso never turned.
local function reachExcess(ply, targets)
    local total = 0
    for _, s in ipairs({ "R", "L" }) do
        local sh = ply:LookupBone("ValveBiped.Bip01_" .. s .. "_UpperArm")
        local el = ply:LookupBone("ValveBiped.Bip01_" .. s .. "_Forearm")
        local ha = ply:LookupBone("ValveBiped.Bip01_" .. s .. "_Hand")
        local key = s == "R" and "rHand" or "lHand"
        local T = targets[key .. "Held"] or targets[key]
        if sh and el and ha and T then
            local S, E, H = bonePos(ply, sh), bonePos(ply, el), bonePos(ply, ha)
            local arm = (E - S):Length() + (H - E):Length()
            total = total + math.max(0, (T - S):Length() - arm * 0.97)
        end
    end
    return total
end

local function spineReach(ply, targets)
    local sb = ply:LookupBone("ValveBiped.Bip01_Spine2")
    if not (sb and targets.rHand and targets.lHand) then return end
    refresh(ply)
    local cur = ply:GetManipulateBoneAngles(sb)
    local e0 = reachExcess(ply, targets)
    local tw, ln = ply.bmxSpineTwist or 0, ply.bmxSpineLean or 0
    local tries = {}
    if e0 > 0.05 then
        -- Either way on the twist, and more or less lean: a lean left over
        -- from the last turn can be the thing in the way on this one.
        tries = { { SPINE_STEP, 0 }, { -SPINE_STEP, 0 }, { 0, SPINE_STEP }, { 0, -SPINE_STEP } }
    elseif math.abs(tw) > 0.1 or ln > 0.1 then
        -- In reach: ease back toward square and upright, while it stays so.
        tries = { { -math.min(math.abs(tw), SPINE_STEP * 0.5) * (tw > 0 and 1 or -1),
                    -math.min(ln, SPINE_STEP * 0.5) } }
    end
    for _, d in ipairs(tries) do
        local nt = math.Clamp(tw + d[1], -SPINE_TWIST, SPINE_TWIST)
        local nl = math.Clamp(ln + d[2], 0, SPINE_LEAN)
        -- The lean goes on the flex (y) the pose already uses; its sign is
        -- the pose's own "forward", so it needs no calibration.
        ply:ManipulateBoneAngles(sb, Angle(cur.p, cur.y + (nl - ln), nt))
        refresh(ply)
        local e1 = reachExcess(ply, targets)
        if (e0 > 0.05 and e1 < e0 - 1e-3) or (e0 <= 0.05 and e1 <= 0.05) then
            ply.bmxSpineTwist, ply.bmxSpineLean = nt, nl
            return
        end
    end
    ply:ManipulateBoneAngles(sb, cur)
    refresh(ply)
end

-- WHICH WAY THE ELBOWS AND KNEES POINT, in the bike's own frame: x forward, y out to
-- the limb's own side, z up. A cyclist's elbows hang out, down and back and the knees
-- go forward; a motocross rider's elbows are UP and out and the knees grip the tank.
-- A pose set may bring its own (`poles = { arm = ..., leg = ... }`).
local ARM_POLE = Vector(-0.3, 1, -0.6)
local LEG_POLE = Vector(1, 0, 0.2)
BMX.RiderPoles = { arm = ARM_POLE, leg = LEG_POLE }

function BMX.SolveRiderIK(ply, targets, bike)
    ply.bmxIK = ply.bmxIK or {}
    local fwd, up, right = bike:GetForward(), bike:GetUp(), bike:GetRight()
    local set = BMX.PoseSetFor and BMX.PoseSetFor(bike)
    local poles = set and set.poles or {}
    for _, limb in ipairs(LIMBS) do
        local T = targets[limb.target]
        -- A hand takes the point on its grip nearest its shoulder.
        local A, B = targets[limb.target .. "A"], targets[limb.target .. "B"]
        local rb = ply:LookupBone(limb.root)
        if T and A and B and rb then
            refresh(ply)
            local S = bonePos(ply, rb)
            local g = B - A
            local t = math.Clamp((S - A):Dot(g) / math.max(g:Dot(g), 1e-6), 0, 1)
            T = A + g * t
            targets[limb.target .. "Held"] = T
        end
        if T then
            -- Knees forward and up; elbows out, down and back (or the set's own).
            local pp = limb.leg and (poles.leg or LEG_POLE) or (poles.arm or ARM_POLE)
            local pole = fwd * pp.x + right * (pp.y * limb.side) + up * pp.z
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
    spineReach(ply, targets)
end

--------------------------------------------------------------------------
-- STYLE POSES (G17): IK targets, blended.
--
-- Each pose in sh_tricks.lua names a row here. A row says where a hand or a
-- foot goes INSTEAD of its grip or pedal, in the bike's own space (X forward,
-- Y left, Z up, inches at the stock wheelbase; the bike scales them), and
-- how the rest of the body and the bike go with it:
--
--   rHand lHand rFoot lFoot   a target; leave out to keep the grip or pedal
--   spineLean   degrees the torso folds forward
--   spineTwist  degrees it turns about its length
--   bikeRoll    degrees the bike lies over about its long axis (tabletop)
--   barsTurn    degrees the bars fold forward about the stem (turndown)
--   barsSpin    degrees the bars are turned about the steer axis (X-up)
--
-- Nobody has watched these on a real model, so they are numbers in a table
-- and the solver is the same guarded one that holds the grips.
--
-- The server sends one pose id; every client blends its own weights toward it
-- over BMX.PoseBlendTime (0.15 s), in and out.
--------------------------------------------------------------------------
local HANDS_UP = { rHand = Vector(8, -15, 36), lHand = Vector(8, 15, 36) }
local FEET_OUT = { rFoot = Vector(-1, -14, 5), lFoot = Vector(-1, 14, 5) }

BMX.RiderPoses = {
    nohander = { rHand = HANDS_UP.rHand, lHand = HANDS_UP.lHand, spineLean = -4 },
    nofooter = { rFoot = FEET_OUT.rFoot, lFoot = FEET_OUT.lFoot },
    -- A can-can swings one leg over the top tube to the other side.
    cancan_r = { rFoot = Vector(-1, 9, 14) },
    cancan_l = { lFoot = Vector(-1, -9, 14) },
    -- Superman: legs out behind, body laid forward, hands on the bars.
    superman = { rFoot = Vector(-26, -5, 17), lFoot = Vector(-26, 5, 17), spineLean = 28 },
    nothing  = { rHand = HANDS_UP.rHand, lHand = HANDS_UP.lHand,
                 rFoot = FEET_OUT.rFoot, lFoot = FEET_OUT.lFoot, spineLean = 6 },
    xup      = { barsSpin = 180, spineTwist = 10 },
    turndown = { barsTurn = 75, spineTwist = -20, spineLean = 10 },
    tabletop = { bikeRoll = 70 },
}

--------------------------------------------------------------------------
-- THE POSE SETS (G22). A vehicle names one (`pose = "bike"`), and the set is
-- two things: `rider(s)`, the bone offsets for the ride (BMX.RiderPose above is
-- the bike's), and `poses`, the style-trick IK targets (BMX.RiderPoses). The
-- ids are declared in sh_vehicles.lua so a registration can be checked; this is
-- where the client fills them in.
--
-- `seated` is the plain one for a vehicle with no pedals and no bars to
-- animate: the stock seated pose with the torso following the vehicle's pitch,
-- and no style poses. A board's set (G23) is the next to be added here.
--------------------------------------------------------------------------
BMX.PoseSets.bike.rider = function(s) return BMX.RiderPose(s) end
BMX.PoseSets.bike.poses = BMX.RiderPoses

BMX.PoseSets.seated.rider = function(s)
    local spine = math.deg(s.pitch or 0) * RIDER.pitchFollow
    return { spine = Angle(0, spine, 0), head = Angle(0, -spine * 0.7, 0) }
end
BMX.PoseSets.seated.poses = {}

-- ROAD (G09): the bike's pose with the body folded down over the bars. The base
-- pose already tucks with speed; this adds a flat-back crouch that is there even
-- at a standstill and deepens a little with speed (a rider on the drops is lower
-- than one on the hoods, and they are on the drops once they are going), and the
-- head comes up against it to look down the road. The hands and feet are the
-- IK's, on the drop bar's grips (cl_init.lua), so this is only the torso.
RIDER.roadTuck     = 20      -- degrees of spine forward over the bike's own
RIDER.roadTuckFast = 10      -- ...and this much more at the top speed
BMX.PoseSets.road.rider = function(s)
    local pose = BMX.RiderPose(s)
    local frac = math.Clamp((s.speed or 0) / math.max(s.topSpeed or 1, 1), 0, 1)
    local spine = pose.spine.y + RIDER.roadTuck + RIDER.roadTuckFast * frac
    pose.spine = Angle(pose.spine.p, spine, pose.spine.r)
    pose.head  = Angle(0, -spine * 0.8, 0)
    return pose
end
BMX.PoseSets.road.poses = BMX.RiderPoses

-- UPRIGHT (G12): a Dutch bike's rider sits up and a little back, and does not
-- tuck with speed (the bike has no speed to tuck for). The pedalling is unhurried:
-- shorter strokes, since the legs are doing a stroll, not a sprint.
RIDER.uprightBack  = 7       -- degrees of spine BACK from vertical
RIDER.uprightSwing = 0.7     -- the thigh and calf swing, as a fraction of the BMX's
BMX.PoseSets.upright.rider = function(s)
    local pose = BMX.RiderPose(s)
    local spine = -RIDER.uprightBack + pose.spine.y * 0.25
    pose.spine = Angle(pose.spine.p, spine, pose.spine.r)
    pose.head  = Angle(0, -spine * 0.7, 0)
    for _, k in ipairs({ "rThigh", "lThigh", "rCalf", "lCalf" }) do
        local a = pose[k]
        pose[k] = Angle(a.p, a.y * RIDER.uprightSwing, a.r)
    end
    return pose
end
BMX.PoseSets.upright.poses = BMX.RiderPoses

-- UNICYCLE (G13): sat straight on the saddle, the torso following the vehicle's pitch a
-- little (a rider rocks forward as they pedal), arms out (the IK's: hands out to the
-- sides, cl_oddbikes.lua), the legs pedalling in step with the wheel, as a fixed gear
-- does. No style poses: there are no hands free to strike one with.
BMX.PoseSets.unicycle.rider = function(s)
    local pose = BMX.RiderPose(s)
    local spine = pose.spine.y * 0.3
    pose.spine = Angle(pose.spine.p, spine, pose.spine.r)
    pose.head  = Angle(0, -spine * 0.7, 0)
    return pose
end
BMX.PoseSets.unicycle.poses = {}

local POSE_HANDS = { "rHand", "lHand" }
local POSE_LIMBS = { "rHand", "lHand", "rFoot", "lFoot" }

-- This bike's pose weights (name -> 0..1), moved toward the pose the server
-- says is held. Called once a frame from the bike's Draw.
function BMX.UpdatePoseWeights(bike, current, dt)
    local W = bike.poseW or {}
    bike.poseW = W
    local step = (dt or 0) / BMX.PoseBlendTime
    for _, name in ipairs(BMX.PoseNames) do
        local w = W[name] or 0
        local target = (name == current) and 1 or 0
        if w < target then w = math.min(target, w + step)
        elseif w > target then w = math.max(target, w - step) end
        W[name] = w > 0 and w or nil
    end
    return W
end

-- What the weights add up to for the bike's drawing, in radians: the roll of
-- the whole bike, the bars folded forward, the bars turned.
function BMX.PoseDrawAngles(W, poses)
    poses = poses or BMX.RiderPoses
    local roll, turn, spin = 0, 0, 0
    for name, w in pairs(W or {}) do
        local d = poses[name]
        if d then
            roll = roll + math.rad(d.bikeRoll or 0) * w
            turn = turn + math.rad(d.barsTurn or 0) * w
            spin = spin + math.rad(d.barsSpin or 0) * w
        end
    end
    return roll, turn, spin
end

-- The torso: degrees forward and degrees of twist.
function BMX.PoseBody(W, poses)
    poses = poses or BMX.RiderPoses
    local lean, twist = 0, 0
    for name, w in pairs(W or {}) do
        local d = poses[name]
        if d then
            lean  = lean  + (d.spineLean  or 0) * w
            twist = twist + (d.spineTwist or 0) * w
        end
    end
    return lean, twist
end

-- Move the IK targets (the table cl_init builds each frame) toward the poses'.
-- `toWorld` turns a bike-space point into a world one. A hand that is being
-- posed gives up its grip RANGE: the solver would otherwise take the nearest
-- point on the bar and ignore the pose.
function BMX.ApplyPoseTargets(ik, W, toWorld, poses)
    poses = poses or BMX.RiderPoses
    for name, w in pairs(W or {}) do
        local d = poses[name]
        if d and w > 0 then
            for _, key in ipairs(POSE_LIMBS) do
                if d[key] and ik[key] then
                    ik[key] = ik[key] + (toWorld(d[key]) - ik[key]) * w
                end
            end
            for _, key in ipairs(POSE_HANDS) do
                if d[key] then ik[key .. "A"], ik[key .. "B"] = nil, nil end
            end
        end
    end
    return ik
end

--------------------------------------------------------------------------
-- Layer 1: the base pose.
--------------------------------------------------------------------------
hook.Add("CalcMainActivity", "BMX.RiderPose", function(ply)
    local bike = BMX.LocalBike(ply)
    if not bike then return end
    -- A pose set may bring its own base pose (the board's: standing, not seated).
    local set = BMX.PoseSetFor(bike)
    if set.activity then return set.activity(ply, bike) end
    local seq = ply:LookupSequence("drive_airboat")
    if not seq or seq < 0 then return end       -- a model without it keeps its own
    return ACT_DRIVE_AIRBOAT, seq
end)

--------------------------------------------------------------------------
-- Layer 2: motion. Applied just before each player is drawn, and cleared from
-- anyone who has got off, so a rider never walks away with pedalling legs.
--------------------------------------------------------------------------
local animated = {}     -- player -> true while we have bones moved on them
local LAND_MIN     = 120    -- u/s downward: gentler than this is not worth a crouch
local LAND_FULL    = 450    -- u/s downward for the deepest crouch
local LAND_RECOVER = 2.0    -- per second: back up in about half a second
local LIMB_KEYS = { rThigh = true, lThigh = true, rCalf = true, lCalf = true,
                    rArm = true, lArm = true }

local function clear(ply)
    for _, name in pairs(BONES) do
        local b = ply:LookupBone(name)
        if b then ply:ManipulateBoneAngles(b, Angle(0, 0, 0)) end
    end
    for b in pairs(ply.bmxIK or {}) do ply:ManipulateBoneAngles(b, Angle(0, 0, 0)) end
    ply.bmxIK, ply.bmxHinge, ply.bmxSpineTwist, ply.bmxSpineLean = nil, nil, nil, nil
    -- The board's crouch lowers the pelvis (cl_board.lua); put it back.
    if ply.bmxPelvis then
        ply:ManipulateBonePosition(ply.bmxPelvis, Vector(0, 0, 0))
        ply.bmxPelvis = nil
    end
    animated[ply] = nil
end
BMX.ClearRiderPose = clear

hook.Add("PrePlayerDraw", "BMX.RiderMotion", function(ply)
    local bike = cv_anim:GetBool() and BMX.LocalBike(ply) or nil
    if not bike then
        if animated[ply] then clear(ply) end
        return
    end

    -- A PASSENGER is not at the bars: their pose is their own (cl_passenger.lua).
    if BMX.IsPassenger and BMX.IsPassenger(ply) then
        BMX.PassengerPose(ply, bike)
        animated[ply] = true
        return
    end

    local C = bike:Cfg()
    local useIK = cv_ik:GetBool() and bike.ikTargets ~= nil

    -- THE LEGS SOAK UP A LANDING. On touching down with real downward speed
    -- the rider crouches, in proportion to how hard it was, and eases back up
    -- over about half a second: the same fold as a hop preload. Worked out
    -- here from what the client already sees (grounded, and the bike's
    -- vertical velocity just before), so it costs no networking.
    local dt = FrameTime()
    local grounded = bike:GetGrounded()
    local vz = bike:GetVelocity().z
    if grounded and bike.bmxWasAir and (bike.bmxAirVz or 0) < -LAND_MIN then
        bike.bmxLand = math.Clamp(-bike.bmxAirVz / LAND_FULL, 0.35, 1)
    end
    if not grounded then bike.bmxAirVz = vz end
    bike.bmxWasAir = not grounded
    bike.bmxLand = math.max(0, (bike.bmxLand or 0) - dt * LAND_RECOVER)
    local set = BMX.PoseSetFor(bike)
    local pose = set.rider({
        crank    = bike.crankAngle or 0,
        speed    = bike:GetSpeedUPS(),
        topSpeed = BMX.Gears.TopCeiling(bike, C),
        sprint   = bike:GetSprinting(),
        hop      = math.max(bike:GetHopCharge(), bike.bmxLand or 0),
        pitch    = select(2, BMX.Attitude(bike, vector_up)),
        steer    = bike:GetSteer(),
        leanFwd  = bike:GetLeanFwd(),
        -- For a pose set that needs more than the bike's own numbers (the
        -- board's crouch and stance live on the entity and the player).
        bike     = bike,
        ply      = ply,
    })
    if useIK and (ply.bmxSpineTwist or ply.bmxSpineLean) then
        pose.spine = Angle(pose.spine.p, pose.spine.y + (ply.bmxSpineLean or 0),
            ply.bmxSpineTwist or 0)
    end
    -- A style pose folds and twists the torso too (BMX.RiderPoses).
    local poseLean, poseTwist = BMX.PoseBody(bike.poseW, set.poses)
    -- ...and so does the rider's chosen stance (sh_stance.lua, G21).
    poseLean = poseLean + (BMX.StanceLean and BMX.StanceLean(ply) or 0)
    if poseLean ~= 0 or poseTwist ~= 0 then
        pose.spine = Angle(pose.spine.p, pose.spine.y + poseLean, pose.spine.r + poseTwist)
    end
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
        if set.solveIK then
            set.solveIK(ply, bike)      -- the board's: feet on the bolts, facing sideways
        else
            BMX.SolveRiderIK(ply, BMX.StanceTargets and BMX.StanceTargets(ply, bike, bike.ikTargets)
                or bike.ikTargets, bike)
        end
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
