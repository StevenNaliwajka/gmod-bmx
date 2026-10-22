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
    -- THE STROKE IN THE BODY. Out of the saddle (standing, attack, a sprint) a
    -- rider's shoulders rock with the pedals, pulling on the bar on the side that
    -- pushes, and the body dips a little into each downstroke; seated, barely.
    -- The head holds still against the shoulders, eyes on the road.
    strokeTwist  = 7,      -- degrees each way about the spine's length, out of the saddle
    strokeBob    = 2.5,    -- degrees forward at the bottom of each downstroke
    strokeSeated = 0.2,    -- ...seated, this fraction of it
    airLook      = 12,     -- degrees the head drops in the air, to spot the landing
    -- TOWARD THE BARS, ALWAYS. A seated rider leans to the bars from the hips; 1.3.9's sat
    -- bolt upright at a standstill (the trunk 0-3 degrees on kleiner; 28 is the middle of a
    -- rider on footage, tools/rider/refpose), the arms bent up to reach down for the grips.
    seatLean     = 12,
}
BMX.RiderAmplitudes = RIDER

local BONES = {
    rThigh = "ValveBiped.Bip01_R_Thigh", rCalf = "ValveBiped.Bip01_R_Calf",
    lThigh = "ValveBiped.Bip01_L_Thigh", lCalf = "ValveBiped.Bip01_L_Calf",
    spine  = "ValveBiped.Bip01_Spine2",  head  = "ValveBiped.Bip01_Head1",
    rArm   = "ValveBiped.Bip01_R_UpperArm", lArm = "ValveBiped.Bip01_L_UpperArm",
    -- the spine's lower links, which take a share of its forward lean (below)
    spineLow = "ValveBiped.Bip01_Spine", spineMid = "ValveBiped.Bip01_Spine1",
}
BMX.RiderBones = BONES

-- A BACK CURVES. The forward lean used to be all at Spine2, a hinge at the
-- shoulder blades over a back held straight; it is shared down the spine's
-- links now, the lower ones a little less, as a back bends. ValveBiped's Spine,
-- Spine1 and Spine2 share their frame (measured, tests/lib/skeleton.lua), so
-- each takes the same Angle(0, lean, 0). A model without a link gives its
-- share to Spine2. The IK's own lean toward the grips (spineReach) and every
-- twist stay on Spine2.
local SPINE_SHARE = { { "spineLow", 0.25 }, { "spineMid", 0.3 } }
local HEAD_HOLD = 0.75     -- of a lean added to a pose set's own, the neck takes back

-- THE HEAD IS TURNED HALF ROUND from the spine on ValveBiped (+Y back, +Z right:
-- measured), so a flex that bends the spine forward tips the head back. Every pose
-- set speaks of the head in the spine's terms (positive y nods it forward); this
-- is what goes on the bone. The twist, about the bone's length, is the same.
function BMX.HeadAngle(a)
    return Angle(-a.p, -a.y, a.r)
end

--------------------------------------------------------------------------
-- The pose, as { boneKey = Angle } offsets from the base pose.
--
--   s.crank     crank angle, rad (the drawn cranks')
--   s.speed     u/s
--   s.topSpeed  u/s, the cadence-limited top speed
--   s.sprint    0..1 (or a bool)
--   s.hop       0..1 preload
--   s.pitch     bike pitch, rad, nose up positive
--   s.steer     rad
--   s.leanFwd   0..1 weight forward over the bars (G02)
--   s.stand     0..1 out of the saddle (the stance: standing, attack)
--   s.pedal     0..1 how hard the legs are turning the cranks
--   s.air       0..1 how far into an air
-- `sprint` may be a fraction as well as a bool: the driver below eases it.
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
    local sprint = (s.sprint == true and 1) or (tonumber(s.sprint) or 0)
    local tuck  = frac * R.tuckMax + sprint * R.sprintTuck + crouch * 0.6
    local spine = R.seatLean + tuck + lean * R.leanFwd + math.deg(s.pitch or 0) * R.pitchFollow

    -- The stroke: a twist with the cranks (one rock a turn, toward the side that
    -- pushes) and a dip with each downstroke (two a turn), as hard as the legs
    -- work and mostly out of the saddle.
    local effort = BMX.Clamp(s.pedal or 0, 0, 1) *
        math.max(sprint, BMX.Clamp(s.stand or 0, 0, 1), R.strokeSeated)
    local twist = math.sin(c) * R.strokeTwist * effort
    spine = spine + (0.5 - 0.5 * math.cos(2 * c)) * R.strokeBob * effort

    local arm = math.deg(s.steer or 0) * R.armSteer

    return {
        rThigh = Angle(0, rT, 0), lThigh = Angle(0, lT, 0),
        rCalf  = Angle(0, rC, 0), lCalf  = Angle(0, lC, 0),
        spine  = Angle(0, spine, twist),
        -- The head holds the horizon against the spine, so the rider looks
        -- down the road rather than at the front tyre; it holds still against
        -- the shoulders' rock, and in the air it drops to spot the landing.
        head   = Angle(0, -spine * 0.7 + BMX.Clamp(s.air or 0, 0, 1) * R.airLook, -twist * 0.8),
        rArm   = Angle(arm, 0, 0), lArm = Angle(arm, 0, 0),
    }
end

--------------------------------------------------------------------------
-- SMOOTHED INPUTS. What the pose is built from arrives in steps: sprint is a
-- bool, the stance an int, the hop charge and the weight forward are networked
-- floats that move at the network's rate, and a landing is seen in one frame.
-- Fed straight in, every step was a snap: ten degrees of tuck the frame a sprint
-- started, 28 when the stance changed, a full crouch the frame the wheels
-- touched and none the frame a hop let go. Each now FOLLOWS its input on a
-- critically damped spring: it eases out and in, never overshoots, and moves
-- the same at 30 frames a second as at 300. Seconds, roughly the time to cover
-- two thirds of a step.
--------------------------------------------------------------------------
local SMOOTH = {
    sprint  = 0.16,   -- out of the saddle into a sprint and back
    lean    = 0.09,   -- weight forward (G02): already ramped by the server, this hides the steps
    stance  = 0.22,   -- the stance's torso lean, and out of the saddle
    hopIn   = 0.07,   -- the hop preload going down
    hopOut  = 0.045,  -- ...and the pop up, quicker
    land    = 0.05,   -- a landing's crouch going in
    air     = 0.25,   -- the head dropping in the air and coming up after
    pedal   = 0.2,    -- how hard the legs work, from the cranks' speed
    reach   = 0.08,   -- the IK's own lean and twist toward grips out of reach
    look    = 0.15,   -- the head turning into a corner
}
BMX.RiderSmooth = SMOOTH
local PEDAL_FULL = 7        -- rad/s of crank: a rider working (about 67 rpm)
-- WHERE THE RIDER LOOKS: into the turn the bike is making, a little way, as a rider
-- looks through a corner; over the shoulder into a spin. Degrees of head twist per
-- degree a second of the bike's yaw, and the most. A positive twist turns the face
-- left on ValveBiped's head (its length points up; the roll is right-handed), and a
-- positive yaw rate is a left turn, so the two need no sign between them.
local LOOK_GAIN, LOOK_MAX = 0.12, 28

-- A critically damped spring (the Game Programming Gems 4 form): x and its rate v
-- toward `target` with time `tau`, exact enough at any dt and never unstable.
local function damp(x, v, target, tau, dt)
    if dt <= 0 then return x, v end
    local omega = 2 / math.max(tau, 1e-3)
    local k = omega * dt
    local e = 1 / (1 + k + 0.48 * k * k + 0.235 * k * k * k)
    local change = x - target
    local temp = (v + omega * change) * dt
    v = (v - omega * temp) * e
    x = target + (change + temp) * e
    -- (it can cross the target by a hair on a big step: not past it)
    if (change > 0) == (x < target) and x ~= target then x, v = target, 0 end
    return x, v
end
BMX.RiderDamp = damp

-- st[key] follows target. The first sight of a key starts it at its target, so
-- a rider who gets on is not seen easing into the pose they already hold.
local function follow(st, key, target, tau, dt)
    local x = st[key]
    if x == nil then st[key], st[key .. "V"] = target, 0 return target end
    local v
    x, v = damp(x, st[key .. "V"] or 0, target, tau, dt)
    st[key], st[key .. "V"] = x, v
    return x
end
BMX.RiderFollow = follow

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

-- THE SKELETON IS RE-POSED ONLY WHEN SOMETHING ON IT MOVED. Every bone read here
-- wants the skeleton as the manipulations so far have it, and the solve used to have
-- the engine pose the whole of it again (InvalidateBoneCache + SetupBones) before
-- every read: about sixty times a frame for each rider near the view, half of them on
-- a skeleton nothing had touched since the last time (measured offline,
-- tools/bench/client_frame.lua). `posed` is the player whose bone cache shows every
-- manipulation made through manip() and manipPos() since it was posed; a refresh of
-- that player is then the same pose again and is skipped. What this file cannot see
-- (another file's manipulations, the next frame's animation) it does not trust: every
-- way in forgets (forgetPose), so the first read after it poses for real.
local posed
local poseNo = 0            -- counts the real poses, for bonePos's cache
local function refresh(ply)
    if posed == ply then return end
    ply:InvalidateBoneCache()
    ply:SetupBones()
    posed = ply
    poseNo = poseNo + 1
end
-- BONES BY NAME, looked up once per model. A solve asks for the same thirty-odd bones
-- by name eighty times a frame per rider, each an engine lookup; a model's bones do
-- not move about, so each player keeps its model's answers (and asks again when the
-- model changes: checked once at each way in). A bone not found is asked for again.
local boneMaps = setmetatable({}, { __mode = "k" })     -- player -> { [0] = model, name -> index }
local mapPly, boneMap
local function lookupBone(ply, name)
    if ply ~= mapPly then
        local model = ply:GetModel()
        local m = boneMaps[ply]
        if not m or m[0] ~= model then m = { [0] = model }; boneMaps[ply] = m end
        mapPly, boneMap = ply, m
    end
    local b = boneMap[name]
    if b == nil then
        b = ply:LookupBone(name)
        boneMap[name] = b
    end
    return b
end
local function forgetPose() posed, mapPly = nil, nil end
local function manip(ply, b, a)
    if posed == ply then posed = nil end
    ply:ManipulateBoneAngles(b, a)
end
local function manipPos(ply, b, v)
    if posed == ply then posed = nil end
    ply:ManipulateBonePosition(b, v)
end

-- A bone's position, read off the engine's pose. The solve reads the same few bones
-- again and again between two poses (the trial a joint is judged by, then the next
-- step's start); while the skeleton is the one last posed (`posed`), a bone already
-- read in this pose is handed back as it was read (a new matrix and a new Vector
-- from the engine each time otherwise). The Vectors are only ever read, never moved.
local readPly, readNo, read = nil, -1, {}
local function bonePos(ply, b)
    local clean = posed == ply
    if clean and readPly == ply and readNo == poseNo then
        local p = read[b]
        if p ~= nil then return p or nil end
    end
    local m = ply:GetBoneMatrix(b)
    local p = m and m:GetTranslation()
    if clean then
        if readPly ~= ply or readNo ~= poseNo then readPly, readNo, read = ply, poseNo, {} end
        read[b] = p or false
    end
    return p
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
    manip(ply, b, a)
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
    local fixed = ikSign            -- (the signs to try, as the loop starts: the one, or both)
    for k = 1, fixed and 1 or 2 do
        local sign = fixed or (k == 1 and 1 or -1)
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
-- A FAST BODY NEEDS MORE THAN TWO PASSES. Each aim turns a joint at most MAX_STEP,
-- so two passes a frame let a limb swing 50 degrees: when the body moved further than
-- that in one frame -- the pelvis dropping 7 units into a scooter kick, the pop of a
-- hop, on a 20 fps client -- the hand was left up to 8 units off the bar for that
-- frame (2026-10-11). It goes on, up to SOLVE_PASSES, while the end of the limb is
-- still SOLVE_CLOSE off where it is going; an ordinary frame is done in one or two.
local SOLVE_PASSES, SOLVE_CLOSE = 5, 0.25
local function solveLimb(ply, limb, T, pole)
    local rb, hb, eb = lookupBone(ply, limb.root), lookupBone(ply, limb.hinge),
        lookupBone(ply, limb.eff)
    if not (rb and hb and eb) then return end
    for pass = 1, SOLVE_PASSES do
        if pass > 2 then
            refresh(ply)
            local R0, F0 = bonePos(ply, rb), bonePos(ply, eb)
            local want = T - R0
            local reach = want:Length()
            local la = (bonePos(ply, hb) - R0):Length() + (F0 - bonePos(ply, hb)):Length()
            if reach > 1e-3 then want = R0 + want / reach * math.min(reach, la * 0.999) end
            if (F0 - want):Length() < SOLVE_CLOSE then break end
        end
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
local THUMB_CURL = 40              -- ...and at the thumb's middle joint (its tip 0.6 of it)
local curlAxis = {}                -- model -> side -> local axis, or false
local thumbAxis = {}               -- the same, for the thumb
BMX.RiderCurlAxis = curlAxis

-- Each side's bone names, made once (they were put together afresh at every use).
local SIDE_BONES = {}
for _, s in ipairs({ "R", "L" }) do
    local p = "ValveBiped.Bip01_" .. s .. "_"
    local t = { toe = p .. "Toe0", upperArm = p .. "UpperArm", forearm = p .. "Forearm", hand = p .. "Hand",
                finger0 = p .. "Finger0", finger2 = p .. "Finger2", fingers = {}, fist = {},
                thumb = { p .. "Finger01", p .. "Finger02" }, mid = p .. "Finger21" }
    for _, f in ipairs(FINGERS) do t.fingers[f] = { p .. "Finger" .. f, p .. "Finger" .. f .. "1", p .. "Finger" .. f .. "2" } end
    for _, name in ipairs({ "Finger2", "Finger21", "Finger22", "Finger0" }) do t.fist[#t.fist + 1] = p .. name end
    SIDE_BONES[s] = t
end
local function sideOf(side) return side == 1 and "R" or "L" end

local function fingerBones(ply, side, f)
    local n = SIDE_BONES[sideOf(side)].fingers[f]
    return lookupBone(ply, n[1]), lookupBone(ply, n[2]), lookupBone(ply, n[3])
end

local function calibrateCurl(ply, side)
    local base, _, tip = fingerBones(ply, side, "1")
    local thumb = lookupBone(ply, SIDE_BONES[sideOf(side)].finger0)
    if not (base and tip and thumb) then return nil end
    local best, bestD
    local old = ply:GetManipulateBoneAngles(base)
    for _, ax in ipairs({ Vector(1, 0, 0), Vector(0, 1, 0), Vector(0, 0, 1) }) do
        for _, sg in ipairs({ 1, -1 }) do
            local d = Angle(0, 0, 0)
            d:RotateAroundAxis(ax, 40 * sg)
            manip(ply, base, d)
            refresh(ply)
            local dist = (bonePos(ply, tip) - bonePos(ply, thumb)):Length()
            if not bestD or dist < bestD then best, bestD = ax * sg, dist end
        end
    end
    manip(ply, base, old)
    refresh(ply)
    return best
end

-- `amount`, 0..1, of the full curl: a hand closes on what it takes hold of and opens
-- when it lets go over CURL_TIME (followed, below), not in a frame.
local function closeHand(ply, side, amount)
    local model = ply:GetModel()
    curlAxis[model] = curlAxis[model] or {}
    local ax = curlAxis[model][side]
    if ax == nil then
        ax = calibrateCurl(ply, side) or false
        curlAxis[model][side] = ax
    end
    if not ax then return end
    local curl = Angle(0, 0, 0)
    curl:RotateAroundAxis(ax, CURL * (amount or 1))
    -- The same curl every frame: a hand whose fingers were all given it, on this model
    -- (a new model starts its bone map afresh), and that the engine still has on the
    -- first of them, is left alone. Setting it again moves nothing, but the skeleton
    -- would be posed again to see that.
    local first = fingerBones(ply, side, FINGERS[1])
    local curled = boneMap.curled
    if first and curled and curled[side] then
        local had, has = ply.bmxIK[first], ply:GetManipulateBoneAngles(first)
        if had and had.p == curl.p and had.y == curl.y and had.r == curl.r
            and has.p == curl.p and has.y == curl.y and has.r == curl.r then
            return
        end
    end
    for _, f in ipairs(FINGERS) do
        for _, b in ipairs({ fingerBones(ply, side, f) }) do
            ply.bmxIK[b] = curl
            manip(ply, b, curl)
        end
    end
    -- THE THUMB WRAPS THE BAR. Only the fingers were curled, and every fist had its
    -- thumb standing up out of it (kleiner's mesh in the offline studio, 2026-10-19).
    -- Its way round is measured as the fingers' is: its middle joint turned about each
    -- of its axes, both ways, and the turn that brings its last joint closest to the
    -- curled middle finger is the way it closes.
    local th = SIDE_BONES[sideOf(side)].thumb
    local t1, t2, mid = lookupBone(ply, th[1]), lookupBone(ply, th[2]), lookupBone(ply, SIDE_BONES[sideOf(side)].mid)
    if t1 and t2 and mid then
        thumbAxis[model] = thumbAxis[model] or {}
        local tax = thumbAxis[model][side]
        if tax == nil then
            local best, bestD
            refresh(ply)
            for _, a in ipairs({ Vector(1, 0, 0), Vector(0, 1, 0), Vector(0, 0, 1) }) do
                for _, sg in ipairs({ 1, -1 }) do
                    local d = Angle(0, 0, 0)
                    d:RotateAroundAxis(a, 40 * sg)
                    manip(ply, t1, d)
                    refresh(ply)
                    local dist = (bonePos(ply, t2) - bonePos(ply, mid)):Length()
                    if not bestD or dist < bestD then best, bestD = a * sg, dist end
                end
            end
            manip(ply, t1, Angle(0, 0, 0))
            tax = best or false
            thumbAxis[model][side] = tax
        end
        if tax then
            for i, b in ipairs({ t1, t2 }) do
                local a = Angle(0, 0, 0)
                a:RotateAroundAxis(tax, THUMB_CURL * (i == 1 and 1 or 0.6) * (amount or 1))
                ply.bmxIK[b] = a
                manip(ply, b, a)
            end
        end
    end
    boneMap.curled = boneMap.curled or {}
    boneMap.curled[side] = true
end

-- AN OPEN HAND IS THE MODEL'S OWN. A hand that had been closed (a grab, the bars before
-- a no-hander) kept its fingers curled when it let go: every skater rode the rest of
-- the way with two fists after one grab (seen with the offline studio on kleiner's
-- mesh, 2026-10-19). Its fingers go back to the animation's relaxed hand.
local function openHand(ply, side)
    local curled = boneMap and boneMap.curled
    local th = SIDE_BONES[sideOf(side)].thumb
    local bones = { lookupBone(ply, th[1]), lookupBone(ply, th[2]) }
    for _, f in ipairs(FINGERS) do
        for _, b in ipairs({ fingerBones(ply, side, f) }) do bones[#bones + 1] = b end
    end
    for _, b in pairs(bones) do
        if ply.bmxIK[b] then
            ply.bmxIK[b] = nil
            manip(ply, b, Angle(0, 0, 0))
        end
    end
    if curled then curled[side] = nil end
end

-- How closed each hand is, 0..1, following whether it holds something.
local CURL_TIME = 0.06
local function curlFor(ply, side, hold, dt)
    ply.bmxCurl = ply.bmxCurl or {}
    return follow(ply.bmxCurl, side, hold and 1 or 0, CURL_TIME, dt)
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
local SPINE_LEAN  = 40     -- degrees of extra lean toward the bars (30 left a dirt bike's
                           -- rider at walking pace, bars turned, two units short of one)
local SPINE_STEP  = 4      -- degrees a frame, at 60 frames a second
-- Out of reach above REACH_OUT, home below REACH_IN, held between: one line
-- for both had the torso lean in one frame and ease back the next, at the
-- edge of reach, a shiver at full lock.
local REACH_OUT, REACH_IN = 0.15, 0.03

-- How far each grip is beyond its shoulder's reach, summed. Scored on REACH,
-- not on where the hands are now: a twist trial moves the hands with the
-- shoulders before the arms have re-solved, so judged by the hands every
-- trial looked worse and the torso never turned.
local function reachExcess(ply, targets)
    local total = 0
    for _, s in ipairs({ "R", "L" }) do
        local names = SIDE_BONES[s]
        local sh = lookupBone(ply, names.upperArm)
        local el = lookupBone(ply, names.forearm)
        local ha = lookupBone(ply, names.hand)
        local key = s == "R" and "rHand" or "lHand"
        local T = targets[key .. "Wrist"] or targets[key .. "Held"] or targets[key]
        -- (a hand that holds nothing is not reached for: the other may be)
        if sh and el and ha and T and not targets[key .. "Open"] then
            local S, E, H = bonePos(ply, sh), bonePos(ply, el), bonePos(ply, ha)
            local arm = (E - S):Length() + (H - E):Length()
            total = total + math.max(0, (T - S):Length() - arm * 0.97)
        end
    end
    return total
end

-- It DECIDES where the torso should be (ply.bmxSpineTwist, ply.bmxSpineLean),
-- trying a step either way on the real skeleton; the pose then FOLLOWS that
-- (SMOOTH.reach, in the driver below), so the body turns into the bars
-- smoothly, and as fast at any frame rate. The skeleton is put back as the
-- pose had it, which is what this frame draws.
-- A GRIP OUT OF REACH IS REACHED FOR AT ONCE. One round of tries a frame moved the
-- torso SPINE_STEP at a time while a hard landing or a hop's pop had the hands out of
-- reach for four frames on a 20 fps client (2026-10-11): while the hands are out of
-- reach it takes up to REACH_ROUNDS rounds in the frame.
local REACH_ROUNDS = 2
local spineReachOnce
local function spineReach(ply, targets)
    for _ = 1, REACH_ROUNDS do
        if not spineReachOnce(ply, targets) then break end
    end
end
-- One round. True while the hands are still out of reach and the round helped.
function spineReachOnce(ply, targets)
    local sb = lookupBone(ply, "ValveBiped.Bip01_Spine2")
    if not (sb and targets.rHand and targets.lHand) then return false end
    refresh(ply)
    local cur = ply:GetManipulateBoneAngles(sb)
    local e0 = reachExcess(ply, targets)
    local tw, ln = ply.bmxSpineTwist or 0, ply.bmxSpineLean or 0
    -- What the pose drew is the base plus the shown (followed) reach: trials
    -- are the base plus a candidate target.
    local shownTw, shownLn = ply.bmxSpineTwistShown or tw, ply.bmxSpineLeanShown or ln
    local baseP, baseY, baseR = cur.p, cur.y - shownLn, cur.r - shownTw
    local step = SPINE_STEP * math.Clamp(FrameTime() * 60, 0.25, 2)
    local tries = {}
    if e0 > REACH_OUT then
        -- Either way on the twist, and more or less lean: a lean left over
        -- from the last turn can be the thing in the way on this one.
        tries = { { step, 0 }, { -step, 0 }, { 0, step }, { 0, -step } }
    elseif e0 < REACH_IN and (math.abs(tw) > 0.1 or ln > 0.1) then
        -- In reach: ease back toward square and upright, while it stays so.
        tries = { { -math.min(math.abs(tw), step * 0.5) * (tw > 0 and 1 or -1),
                    -math.min(ln, step * 0.5) } }
    end
    -- THE BEST OF THE TRIES, not the first that helps. Taking the first, a twist
    -- step helped every frame by undoing the last one's overshoot, so the twist
    -- dithered (7, 18, 14, 10... degrees) and the lean behind it was never tried: a
    -- dirt bike's rider, whose grips are 20 units ahead, stayed two units short of
    -- the left one (2026-10-11, on kleiner's own skeleton).
    local bestT, bestL, bestE
    for _, d in ipairs(tries) do
        local nt = math.Clamp(tw + d[1], -SPINE_TWIST, SPINE_TWIST)
        local nl = math.Clamp(ln + d[2], 0, SPINE_LEAN)
        -- The lean goes on the flex (y) the pose already uses; its sign is
        -- the pose's own "forward", so it needs no calibration.
        manip(ply, sb, Angle(baseP, baseY + nl, baseR + nt))
        refresh(ply)
        local e1 = reachExcess(ply, targets)
        if e0 < REACH_IN then
            -- easing back: take it while it stays in reach
            if e1 < REACH_IN then bestT, bestL = nt, nl break end
        elseif e1 < e0 - 1e-3 and (not bestE or e1 < bestE) then
            bestT, bestL, bestE = nt, nl, e1
        end
    end
    if bestT then ply.bmxSpineTwist, ply.bmxSpineLean = bestT, bestL end
    -- Put back as the pose had it (nothing to put back when nothing was tried).
    if #tries > 0 then
        manip(ply, sb, cur)
        refresh(ply)
    end
    return bestE ~= nil and bestE > REACH_OUT
end

-- THE RIDER RIDES THE DRAWN FRAME. A bike's frame is drawn sitting on its axles
-- (cl_init.lua: Pf), so a suspension squashed by a hard landing lifts the frame --
-- saddle, pedals and bars -- off the chassis, while the seat a player is parented to
-- stays on the chassis: the pedals came up into the folded legs and a foot stood off
-- its pedal for two frames on a 20 fps client (2026-10-11). The pelvis is moved by
-- what the drawing did to the seat point (BMX.RiderFollowFrame), so the rider rises
-- and settles with the bike. Which way a bone position offset moves the pelvis is the
-- skeleton's own, so it is MEASURED once per model, in the vehicle's frame (a seated
-- rider faces the way the vehicle does), as the board's crouch measures its way down.
local FRAME_SHIFT_MAX = 12      -- units: more than this is a wheel lost, not a landing
local pelvisMaps = {}           -- model -> { x, y, z column Vectors } or false
local function pelvisMap(ply, bike, pb)
    local model = ply:GetModel()
    local m = pelvisMaps[model]
    if m ~= nil then return m end
    manipPos(ply, pb, Vector(0, 0, 0))
    refresh(ply)
    local p0 = bonePos(ply, pb)
    if not p0 then pelvisMaps[model] = false return false end
    local cols = {}
    for i, ax in ipairs({ Vector(1, 0, 0), Vector(0, 1, 0), Vector(0, 0, 1) }) do
        manipPos(ply, pb, ax * 4)
        refresh(ply)
        local d = (bonePos(ply, pb) - p0) / 4
        cols[i] = Vector(d:Dot(bike:GetForward()), -d:Dot(bike:GetRight()), d:Dot(bike:GetUp()))
    end
    manipPos(ply, pb, Vector(0, 0, 0))
    refresh(ply)
    local det = cols[1]:Dot(cols[2]:Cross(cols[3]))
    m = math.abs(det) > 0.25 and cols or false
    pelvisMaps[model] = m
    return m
end

-- OUT OF THE SADDLE. The standing and attack stances (sh_stance.lua) and a sprint
-- only leaned the torso, so a "standing" rider sat on the saddle with their back
-- straighter (kleiner's mesh in the offline studio, 2026-10-19). A rider out of the
-- saddle has their hips up and over the cranks, legs nearly straight at the bottom of
-- the stroke: the pelvis is lifted (and brought forward toward the cranks) as far as
-- the legs still reach the bottom of the pedal circle with a soft knee -- on a tall
-- bike (a penny-farthing's hub) that is a few units over the hub, or none. `stand`:
-- { rise = 0..1 of STAND_RISE (or of `max`, units), over = 0..1 of the way from the hips
-- to over the cranks, `feet` = { right, left } to stand on if not the vehicle's pedals }.
local STAND_RISE    = 6     -- units, the most the hips come up (at 9 a BMX's low bars were
                            -- past arm's length even with the back leaned its whole 40)
local STAND_FWD_MAX = 6     -- units, the most they come forward
local STAND_KNEE    = 0.93  -- of thigh and shin: the knee never quite straight...
local STAND_ANKLE   = 0.5   -- ...and of the ankle to the ball of the foot, the ankle's give
local function standShift(ply, bike, pb, stand)
    local ik = bike.ikTargets
    local rF, lF = ik and ik.rFoot, ik and ik.lFoot
    if stand.feet then rF, lF = stand.feet[1], stand.feet[2] end
    if not (rF and lF) then return nil end
    manipPos(ply, pb, Vector(0, 0, 0))     -- (the hips where the seat has them)
    refresh(ply)
    local O, fwd, right, up = bike:GetPos(), bike:GetForward(), bike:GetRight(), bike:GetUp()
    local function loc(v) v = v - O return Vector(v:Dot(fwd), -v:Dot(right), v:Dot(up)) end
    local R, L = loc(rF), loc(lF)
    local C = (R + L) * 0.5
    local r = math.sqrt((R.x - L.x) ^ 2 + (R.z - L.z) ^ 2) * 0.5
    local legs = {}
    for _, sd in ipairs({ { "R", R }, { "L", L } }) do
        local p = "ValveBiped.Bip01_" .. sd[1] .. "_"
        local th, ca, ft, to = lookupBone(ply, p .. "Thigh"), lookupBone(ply, p .. "Calf"),
            lookupBone(ply, p .. "Foot"), lookupBone(ply, p .. "Toe0")
        if not (th and ca and ft and to) then return nil end
        local Th, Ca, Ft, To = bonePos(ply, th), bonePos(ply, ca), bonePos(ply, ft), bonePos(ply, to)
        legs[#legs + 1] = { H = loc(Th), low = Vector(C.x, sd[2].y, C.z - r),
            reach = ((Ca - Th):Length() + (Ft - Ca):Length()) * STAND_KNEE + (To - Ft):Length() * STAND_ANKLE }
    end
    local dx = math.Clamp((C.x - (legs[1].H.x + legs[2].H.x) * 0.5) * stand.over, -STAND_FWD_MAX, STAND_FWD_MAX)
    local function fits(k)
        for _, g in ipairs(legs) do
            if (g.H + Vector(dx, 0, k) - g.low):Length() > g.reach then return false end
        end
        return true
    end
    if not fits(0) then return nil end
    local lo, hi = 0, (stand.max or STAND_RISE) * stand.rise
    if not fits(hi) then
        for _ = 1, 10 do
            local mid = (lo + hi) * 0.5
            if fits(mid) then lo = mid else hi = mid end
        end
        hi = lo
    end
    -- (the forward part comes with the rise: a rider stood up a hair is not pushed forward)
    return Vector(dx * math.min(1, hi / 2), 0, hi)
end
BMX.RiderStandRise = STAND_RISE

-- `seat`: the rider's seat in the vehicle's chassis space (its pod's offset); `stand`,
-- out of the saddle (above), or nil.
function BMX.RiderFollowFrame(ply, bike, seat, stand)
    forgetPose()
    local pb = lookupBone(ply, "ValveBiped.Bip01_Pelvis")
    if not pb then return end
    local fm = bike.bmxFrameMap
    local shift
    if fm and seat then
        local m = seat - fm.lift0
        local d = fm.Pf(m) - fm.P0(m)
        shift = Vector(d:Dot(bike:GetForward()), -d:Dot(bike:GetRight()), d:Dot(bike:GetUp()))
        if shift:Length() > FRAME_SHIFT_MAX or shift:Length() < 0.05 then shift = nil end
    end
    if stand and stand.rise > 0.01 then
        local up = standShift(ply, bike, pb, stand)
        if up then shift = shift and (shift + up) or up end
    end
    if not shift then
        if ply.bmxFramePelvis then
            manipPos(ply, pb, Vector(0, 0, 0))
            ply.bmxFramePelvis, ply.bmxPelvis = nil, nil
        end
        return
    end
    local M = pelvisMap(ply, bike, pb)
    if not M then return end
    local det = M[1]:Dot(M[2]:Cross(M[3]))
    local x = Vector(shift:Dot(M[2]:Cross(M[3])), M[1]:Dot(shift:Cross(M[3])), M[1]:Dot(M[2]:Cross(shift))) / det
    manipPos(ply, pb, x)
    ply.bmxFramePelvis, ply.bmxPelvis = pb, pb      -- (clear() puts it back)
end

-- What spineReach decided, FOLLOWED (SMOOTH.reach): the lean and twist a pose adds to
-- Spine2 this frame, degrees, and what spineReach's next trials take as already shown.
-- The rider's pose and a passenger's (cl_passenger.lua) both put it on, or the torso a
-- passenger's IK asked for was never drawn: a tandem's stoker, 4 units short of their
-- bars, had spineReach wound to its limits (30 degrees of lean, 40 of twist) judging
-- trials against a pose that never had either (seen on a real client, 2026-10-11).
function BMX.RiderReachFollow(ply, dt)
    if not (ply.bmxSpineTwist or ply.bmxSpineLean) then return 0, 0 end
    local rs = ply.bmxReachSm or {}
    ply.bmxReachSm = rs
    -- Reaching OUT for a grip is quick (a rider grabs for the bars), letting the
    -- torso back is the unhurried SMOOTH.reach.
    local function tau(key, want) return (math.abs(want) > math.abs(rs[key] or 0)) and SMOOTH.reach * 0.4 or SMOOTH.reach end
    local lean, twist = ply.bmxSpineLean or 0, ply.bmxSpineTwist or 0
    ply.bmxSpineLeanShown = follow(rs, "lean", lean, tau("lean", lean), dt)
    ply.bmxSpineTwistShown = follow(rs, "twist", twist, tau("twist", twist), dt)
    return ply.bmxSpineLeanShown, ply.bmxSpineTwistShown
end

-- WHICH WAY THE ELBOWS AND KNEES POINT, in the bike's own frame: x forward, y out to
-- the limb's own side, z up. A cyclist's elbows hang out, down and back and the knees
-- go forward; a motocross rider's elbows are UP and out and the knees grip the tank.
-- A pose set may bring its own (`poles = { arm = ..., leg = ... }`).
local ARM_POLE = Vector(-0.3, 1, -0.6)
local LEG_POLE = Vector(1, 0, 0.2)
BMX.RiderPoles = { arm = ARM_POLE, leg = LEG_POLE }

--------------------------------------------------------------------------
-- WHAT TOUCHES THE BIKE: the BALL of the foot and the inside of the fist.
--
-- The IK used to put the FOOT BONE on the pedal and the HAND BONE on the grip,
-- and on ValveBiped those are the ankle and the wrist. So the pedal sat under
-- the ankle with the toes hanging five units past it and the sole through it,
-- and the bar ran through the wrist with the fist closed on air in front of it:
-- the feet and hands that "did not match" the bike. A rider's contact is the
-- ball of the foot (the Toe0 bone, at the joint of the toes) over the spindle
-- or the peg, and the bar across the palm, inside the curled fingers.
--
-- THE FOOT is placed exactly: the sole's pitch is chosen (below), the
-- ankle-to-ball length is measured off the model, so the ankle's target is the
-- contact less that length along the chosen direction, and the foot is then
-- turned to point that way. THE HAND is measured: where the curled fingers and
-- the thumb close (their centroid) against the wrist, in the bike's own frame,
-- is kept per rider and the next frame's wrist target is the grip less it. The
-- hand is always aimed the same way in the bike's frame, so that offset holds
-- still and a frame's lag in it is nothing.
--------------------------------------------------------------------------
-- A FLAT FOOT'S ankle-to-ball line slopes down this far (ValveBiped's ankle sits
-- well above the ball of the foot), so "sole flat on the pedal" is this pitch and
-- not level: aiming the line level, as the IK did, stood the rider on their heels.
local FOOT_SLOPE = 25
-- ...and standing on a deck, measured on kleiner's own shoe (studio, 2026-10-22): with
-- the sole flat on the ground in the idle, the ankle is 4.24 over it, the ball 0.44, and
-- the line between them falls 33.5 degrees. A deck's foot is set by its ankle
-- (`targets.ankles`) with the sole laid flat at that.
local STAND_SLOPE = 33.5
BMX.RiderStandSlope = STAND_SLOPE
-- THE ANKLE'S STROKE: a rider's heel drops over the top and front of the stroke,
-- where they push, and the toes point down through the bottom and back, where
-- they pull through. Degrees toe-down from a flat sole: a mean and a swing, and
-- the crank angle it peaks at (positive t is the pedal going forward and down;
-- 0 is the right crank level forward). Pure, so the suite checks it.
local ANKLE = { mean = 8, swing = 12, peak = 0.75 * math.pi }
BMX.RiderAnkle = ANKLE
function BMX.PedalSole(t)
    return ANKLE.mean + ANKLE.swing * math.cos((t or 0) - ANKLE.peak)
end
-- On a footpeg the ball of the foot is on it and the heel a little up: a
-- motorcyclist rides on the balls of their feet, ready to stand.
BMX.PegSole = 6
local GRIP_OFF_MAX = 6      -- units: a measured wrist-to-fist offset longer than this is wrong
local GRIP_MID = 0.5        -- of the way along a grip from its inner end: where a fist holds it
local KNUCKLE_FOLLOW = 0.6  -- how much of the forearm's direction a gripping hand's knuckles take
local GRIP_MID_REACH = 0.94 -- ...while the wrist is no further than this of the arm's length
local GRIP_RESOLVE = 0.25   -- units: a fist this far from where it was used is solved for again

local function ballLength(ply, foot, toe)
    local a, b = bonePos(ply, foot), bonePos(ply, toe)
    return (a and b) and (b - a):Length() or 0
end

-- THE FOOT SLIDES FORWARD ON THE PEDAL WHEN THE LEG RUNS OUT OF FOLD. Over the
-- top of the stroke on a low saddle (a BMX's), an ankle behind the pedal would
-- sit almost under the hip, closer than a knee folded past FOOT_FOLD can bring
-- it, and the solve then had no plane to bend in and threw the knee out to the
-- side. A rider's foot slips forward on the pedal there, so the pedal goes under
-- the arch: the ankle's set-back `L` is cut, down to nothing (the ankle over the
-- pedal, as the IK always had it), until the ankle is far enough from the hip.
local FOOT_FOLD = 135       -- degrees: the most a pedalling knee is asked to fold
local function ankleSetback(ply, limb, T, dir, L)
    local rb, hb, eb = lookupBone(ply, limb.root), lookupBone(ply, limb.hinge), lookupBone(ply, limb.eff)
    local R, K, F = rb and bonePos(ply, rb), hb and bonePos(ply, hb), eb and bonePos(ply, eb)
    if not (R and K and F) then return L end
    local la, lb = (K - R):Length(), (F - K):Length()
    local r = math.sqrt(la * la + lb * lb - 2 * la * lb * math.cos(math.rad(180 - FOOT_FOLD)))
    -- |T - dir * x - R| = r, the smaller root: any set-back up to it keeps the
    -- ankle at least r from the hip.
    local V = T - R
    local b = V:Dot(dir)
    local disc = b * b - V:Dot(V) + r * r
    if disc <= 0 then return L end
    return math.Clamp(b - math.sqrt(disc), 0, L)
end

-- The point a closed hand holds a bar at: the curled fingers' and the thumb's
-- centroid. nil if the model has no fingers.
local function fistCentre(ply, s)
    local sum, n = Vector(0, 0, 0), 0
    for _, name in ipairs(SIDE_BONES[s].fist) do
        local b = lookupBone(ply, name)
        local p = b and bonePos(ply, b)
        if p then sum = sum + p; n = n + 1 end
    end
    return n >= 3 and sum / n or nil
end
-- (Asked from outside, after bones this file did not move: read afresh.)
function BMX.RiderFistCentre(ply, s) forgetPose() return fistCentre(ply, s) end

-- The direction from the ankle to the ball of the foot for a sole tipped `sole`
-- degrees toe-down, in the bike's frame.
local function footDir(fwd, up, sole)
    local a = math.rad(FOOT_SLOPE + (sole or 0))
    return (fwd * math.cos(a) - up * math.sin(a)):GetNormalized()
end
BMX.RiderFootDir = footDir

-- THE TOES POINT WHEN THE PEDAL IS A STRETCH AWAY. At the bottom of the stroke on a
-- tall bike (a penny-farthing's hub, a shorter model on any bike) the ankle that the
-- stroke's sole puts behind the pedal can be past the leg's length, and the solve
-- stood the leg straight with the foot off the pedal: two units at the bottom of
-- every stroke on a real penny (2026-10-11). A rider's ankle extends there before
-- the foot leaves the pedal. This is the least extra toe-down, up to TOE_REACH
-- degrees, that brings the ankle within the leg's length (or as close as pointing
-- them can): nothing on a bike that fits, and it comes and goes with the pedal.
local TOE_REACH = 35
BMX.RiderToeReach = TOE_REACH
local function toesFor(ply, limb, T, fwd, up, sole, L)
    local rb, hb, eb = lookupBone(ply, limb.root), lookupBone(ply, limb.hinge), lookupBone(ply, limb.eff)
    local R, K, F = rb and bonePos(ply, rb), hb and bonePos(ply, hb), eb and bonePos(ply, eb)
    if not (R and K and F) or L <= 0 then return 0 end
    local reach = ((K - R):Length() + (F - K):Length()) * 0.995
    local function far(e) return (T - footDir(fwd, up, sole + e) * L - R):Length() > reach end
    if not far(0) then return 0 end
    -- Pointing helps only until the foot lies along the line from the hip: past that
    -- the ankle swings away again. Between, the distance falls the whole way.
    local d = T - R
    local best = math.deg(math.atan2(-d:Dot(up), d:Dot(fwd))) - FOOT_SLOPE - sole
    local hi = math.Clamp(best, 0, TOE_REACH)
    if hi <= 0 or far(hi) then return hi end
    local lo = 0
    for _ = 1, 10 do
        local mid = (lo + hi) * 0.5
        if far(mid) then lo = mid else hi = mid end
    end
    return hi
end

-- WHEN THE TARGETS COME FROM SOMEWHERE ELSE, THE LIMBS EASE ACROSS. While a
-- vehicle's model is still being built it is drawn as the simple bike, scaled, whose
-- grips and pedals are not the model's; when the model is ready they all move at once,
-- and on a real client both riders of a tandem threw their hands and feet 7 to 10
-- units in one frame (2026-10-11). Each drawing names what it is (`src` on its target
-- table: "model", "simple", a passenger's "pegs"...); when that changes, each limb is
-- followed across from where it was over JUMP_TIME, eased. Only then: telling a jump
-- by its size alone also caught a kicking foot and the pedals at a hard landing on a
-- 20 fps client, and dragged them a fifth of a second behind. Kept in the vehicle's
-- own frame (about the player), so riding along is not a jump. A rider not solved for
-- a while (far off, or just got on) starts afresh.
local JUMP_TIME = 0.2
BMX.RiderJump = { time = JUMP_TIME }
local function smooth01(t) return t * t * (3 - 2 * t) end
local function followTarget(ply, key, T, src, o, fwd, right, up, now, dt)
    local d = T - o
    local loc = Vector(d:Dot(fwd), d:Dot(right), d:Dot(up))
    local J = ply.bmxIKJump or {}
    ply.bmxIKJump = J
    local s = J[key]
    if not s or now - s.time > 0.5 or now < s.time then
        J[key] = { loc = loc, shown = loc, time = now, src = src }
        return T
    end
    if src ~= nil and s.src ~= nil and src ~= s.src then s.from, s.t = s.shown, 0 end
    if src ~= nil then s.src = src end
    s.loc, s.time = loc, now
    local shown = loc
    if s.from then
        s.t = s.t + dt / JUMP_TIME
        if s.t >= 1 then
            s.from = nil
        else
            shown = s.from + (loc - s.from) * smooth01(s.t)
        end
    end
    s.shown = shown
    if not s.from then return T end
    return o + fwd * shown.x + right * shown.y + up * shown.z
end

-- HANDS THAT HANG FROM THE SHOULDERS. A hand with nothing to hold (a skater's
-- balancing arms) was given a point fixed to the vehicle, worked out for where a body
-- would stand: when the real one leaned, crouched or turned for a push, its shoulders
-- moved and the hands did not, so the arms reached out like paws or folded into the
-- thighs (the offline studio on kleiner's mesh, 2026-10-19). A drawing may give a hand
-- as an offset from its own shoulder instead (`rHandRel`: x forward, y left, z up in the
-- vehicle's frame, units for an arm as long as kleiner's, scaled to the model's),
-- resolved here once the body is posed, and pulled toward `rHandTo` by `rHandToW` (a
-- grab on the deck).
local REL_ARM = 23.2
local function resolveRelHands(ply, targets, fwd, right, up)
    for _, limb in ipairs(LIMBS) do
        local rel = not limb.leg and targets[limb.target .. "Rel"]
        local rb, hb, eb = lookupBone(ply, limb.root), lookupBone(ply, limb.hinge), lookupBone(ply, limb.eff)
        if rel and rb and hb and eb then
            refresh(ply)
            local S, K, H = bonePos(ply, rb), bonePos(ply, hb), bonePos(ply, eb)
            local k = ((K - S):Length() + (H - K):Length()) / REL_ARM
            local T = S + (fwd * rel.x - right * rel.y + up * rel.z) * k
            local to, w = targets[limb.target .. "To"], targets[limb.target .. "ToW"]
            if to and w and w > 0 then T = T + (to - T) * math.min(w, 1) end
            targets[limb.target] = T
        end
    end
end

function BMX.SolveRiderIK(ply, targets, bike)
    forgetPose()
    ply.bmxIK = ply.bmxIK or {}
    ply.bmxGripOff = ply.bmxGripOff or {}
    local fwd, up, right = bike:GetForward(), bike:GetUp(), bike:GetRight()
    -- (A stand-in for the bike, the board's, names its pose set itself.)
    local set = bike.bmxPoseSet or (BMX.PoseSetFor and BMX.PoseSetFor(bike))
    local poles = set and set.poles or {}
    -- Hands that hold nothing (a unicyclist's arms, a skater's between grabs): the
    -- drawing may say so frame by frame, else the set does.
    local openHands = targets.openHands
    if openHands == nil then openHands = (set and set.openHands) or false end
    -- (The frame's time for the easing, the clock only to tell a rider not solved for a
    -- while: a paused game's clock stands still, and so would a jump's easing.)
    local origin, now, frameDt = ply:GetPos(), CurTime(), FrameTime()
    resolveRelHands(ply, targets, fwd, right, up)
    local anyHeld = false
    for _, limb in ipairs(LIMBS) do
        local T = targets[limb.target]
        -- A hand holds the MIDDLE of its grip, or further out if its shoulder is (a
        -- city bike's swept ends); in toward the stem only as far as it must to reach.
        -- It used to take the point nearest the shoulder, which on every bike was the
        -- grip's inner end: the fist closed half on the bare bar beside it (kleiner's
        -- mesh in the offline studio, 2026-10-19).
        local A, B = targets[limb.target .. "A"], targets[limb.target .. "B"]
        local rb = lookupBone(ply, limb.root)
        if T and A and B and rb then
            refresh(ply)
            local S = bonePos(ply, rb)
            local g = B - A
            local near = math.Clamp((S - A):Dot(g) / math.max(g:Dot(g), 1e-6), 0, 1)
            local t = math.max(near, GRIP_MID)
            if t > near then
                local hb, eb = lookupBone(ply, limb.hinge), lookupBone(ply, limb.eff)
                local arm = (hb and eb) and ((bonePos(ply, hb) - S):Length() + (bonePos(ply, eb) - bonePos(ply, hb)):Length()) or 0
                -- (to the fist: its centre is past the wrist by the measured offset; and
                -- only while it is comfortably in reach -- a stretched rider slides in at
                -- once, rather than leaning after the middle of a grip a frame behind)
                local o = ply.bmxGripOff and ply.bmxGripOff[limb.side]
                arm = arm * GRIP_MID_REACH + (o and o:Length() or 0)
                local function far(u) return ((A + g * u) - S):Length() > arm end
                if far(t) then
                    -- (as far out as reaches, between the middle and the nearest point)
                    local lo, hi = near, t
                    for _ = 1, 8 do
                        local mid = (lo + hi) * 0.5
                        if far(mid) then hi = mid else lo = mid end
                    end
                    t = lo
                end
            end
            T = A + g * t
            targets[limb.target .. "Held"] = T
        end
        if T then T = followTarget(ply, limb.target, T, targets.src, origin, fwd, right, up, now, frameDt) end
        if T then
            local s = limb.side == 1 and "R" or "L"
            local eb = lookupBone(ply, limb.eff)
            -- A FOOT MAY POINT ITS OWN WAY: `<foot>Yaw`, degrees to the rider's left of
            -- the vehicle's forward (a skater's front foot turned toward the nose), and
            -- its knee goes with it, over the toes.
            local lfwd, lright = fwd, right
            local yaw = limb.leg and targets[limb.target .. "Yaw"]
            if yaw and yaw ~= 0 then
                local a = math.rad(yaw)
                lfwd = (fwd * math.cos(a) - right * math.sin(a)):GetNormalized()
                lright = lfwd:Cross(up):GetNormalized()
            end
            -- Each hand open or holding: the drawing may say so for one hand (a grab, a
            -- no-hander letting go of one side), else the whole set's way.
            local open = targets[limb.target .. "Open"]
            if open == nil then open = openHands end
            local holding = not limb.leg and not open
            if holding then anyHeld = true end
            -- How closed the hand is, followed: it closes on a grip and opens off one.
            local curl = not limb.leg and curlFor(ply, limb.side, holding, frameDt) or 0
            -- (a hand may hold softly: a passenger's on the rider's shoulders)
            if holding then curl = curl * (targets[limb.target .. "Curl"] or 1) end
            -- Where the wrist or the ankle has to go for the fist or the ball of
            -- the foot to be on T.
            local W, dir
            if limb.leg and targets.ankles then
                -- A FOOT STANDING ON A DECK (a board's, a scooter's): the target is where
                -- the ANKLE goes, an ankle's height over the grip, and the sole is laid flat
                -- from it by the aim below. Read as a pedal's ball of the foot, as it was
                -- until 1.4.0, every skater's ankle stood a foot's length back from where
                -- the board put it -- four units out past the heel edge -- and the sole
                -- floated over the grip (kleiner on the studio's board, 2026-10-22).
                dir = footDir(lfwd, up, (targets[limb.target:sub(1, 1) .. "Sole"] or 0) + STAND_SLOPE - FOOT_SLOPE)
                W = T
            elseif limb.leg then
                local toe = lookupBone(ply, SIDE_BONES[s].toe)
                local sole = targets[limb.target:sub(1, 1) .. "Sole"] or 0
                local L = (eb and toe) and ballLength(ply, eb, toe) or 0
                refresh(ply)
                sole = sole + toesFor(ply, limb, T, lfwd, up, sole, L)
                dir = footDir(lfwd, up, sole)
                W = T - dir * ankleSetback(ply, limb, T, dir, L)
            else
                -- The wrist where the fist is on T, as far as the hand is closed: a hand
                -- taking hold or letting go moves its wrist across with its fingers.
                local o = ply.bmxGripOff[limb.side]
                W = (o and curl > 0) and (T - (fwd * o.x + right * o.y + up * o.z) * curl) or T
                if holding then targets[limb.target .. "Wrist"] = W end
            end
            -- Knees forward and up; elbows out, down and back (or the set's own).
            local pp = limb.leg and (poles.leg or LEG_POLE) or (poles.arm or ARM_POLE)
            local pole = (lfwd * pp.x + lright * (pp.y * limb.side) + up * pp.z):GetNormalized()
            solveLimb(ply, limb, W, pole)

            if limb.leg then
                -- Toes forward, the sole pitched as the stroke has it, the ball on the pedal.
                -- Until it points there (the leg solve just turned the foot with the shin,
                -- and each aim turns it at most MAX_STEP: twice was not enough the frame a
                -- hard landing swung the leg, and the foot stood off its pedal for two).
                local toe = lookupBone(ply, SIDE_BONES[s].toe)
                if eb and toe then
                    for _ = 1, 4 do
                        aim(ply, eb, eb, toe, dir)
                        if (bonePos(ply, toe) - bonePos(ply, eb)):GetNormalized():Dot(dir) > 0.998 then break end
                    end
                end
            elseif not holding then
                -- Nothing to hold (a unicyclist's balancing arms, a skater's): the wrist
                -- STRAIGHT, the hand going on from the forearm and a little down, as a
                -- hand hangs. It used to be aimed out to the side and down whatever the
                -- arm did, which on a skater's hanging arms cocked both wrists and turned
                -- the palms down: paws (kleiner's mesh, 2026-10-19). The fingers are the
                -- model's own relaxed hand, opening from a fist as it lets go.
                local knuck = lookupBone(ply, SIDE_BONES[s].finger2)
                local hb = lookupBone(ply, limb.hinge)
                if eb and knuck and hb then
                    refresh(ply)
                    local fa = (bonePos(ply, eb) - bonePos(ply, hb)):GetNormalized()
                    aim(ply, eb, eb, knuck, (fa - up * 0.2):GetNormalized())
                end
                if curl > 0.02 then closeHand(ply, limb.side, curl) else openHand(ply, limb.side) end
            else
                -- Knuckles forward over the bar, then the fingers closed round it, and
                -- where that fist is against the wrist, for the next frame. THE FIST IS
                -- WHERE THE LAST FRAME'S WAS against the wrist, and the forearm's roll
                -- turns it: when the body moved a lot in a frame (the bottom of a scooter
                -- kick, a hard landing) it had moved, and the fist was off the bar by up
                -- to 8 units for that frame on a real client (2026-10-11). So when the
                -- measured offset is GRIP_RESOLVE off the one used, the arm is solved
                -- again with it, once. The knuckles are aimed until they point where they
                -- go (each aim turns the wrist at most MAX_STEP: after a big swing of the
                -- forearm one was not enough, and the fist was still turned off the bar).
                local knuck = lookupBone(ply, SIDE_BONES[s].finger2)
                local kdir = (fwd - up * 0.3):GetNormalized()
                -- The wrist goes some way with the forearm: stood up out of the saddle the
                -- forearm comes down steeply onto the bar, and knuckles held level forward
                -- asked more of the wrist than it turns -- the fist sat rolled off the grip
                -- (1.7 units, kleiner standing on a BMX, 2026-10-19).
                local hb = lookupBone(ply, limb.hinge)
                if hb and eb then
                    refresh(ply)
                    local fa = (bonePos(ply, eb) - bonePos(ply, hb)):GetNormalized()
                    kdir = (kdir + fa * KNUCKLE_FOLLOW):GetNormalized()
                end
                local function aimKnuckles()
                    if not (eb and knuck) then return end
                    for _ = 1, 4 do
                        aim(ply, eb, eb, knuck, kdir)
                        local d = (bonePos(ply, knuck) - bonePos(ply, eb)):GetNormalized()
                        if d:Dot(kdir) > 0.998 then break end
                    end
                end
                for pass = 1, 2 do
                    aimKnuckles()
                    closeHand(ply, limb.side, curl)
                    refresh(ply)
                    local fc, wr = fistCentre(ply, s), eb and bonePos(ply, eb)
                    if not (fc and wr) then break end
                    local d = fc - wr
                    if d:Length() > GRIP_OFF_MAX then break end
                    local n = Vector(d:Dot(fwd), d:Dot(right), d:Dot(up))
                    local o = ply.bmxGripOff[limb.side]
                    ply.bmxGripOff[limb.side] = n
                    if pass == 2 or not o or (n - o):Length() < GRIP_RESOLVE then break end
                    W = T - fwd * n.x - right * n.y - up * n.z
                    targets[limb.target .. "Wrist"] = W
                    solveLimb(ply, limb, W, pole)
                end
            end
        end
    end
    -- The torso reaches for what the HANDS HOLD. A set whose hands are open (a
    -- unicyclist's or a skater's balancing arms) has nothing to reach for: the board's
    -- arms out to the side wound it to its whole 30 degrees, and every skater rode
    -- hunched over (2026-10-11). An old reach eases off.
    if not anyHeld then
        ply.bmxSpineLean, ply.bmxSpineTwist = ply.bmxSpineLean and 0, ply.bmxSpineTwist and 0
    else
        spineReach(ply, targets)
    end
    -- The engine draws the player from the bones as last posed: they show it all.
    refresh(ply)
end

-- The two-bone solve and the bone aim, for the other riders' poses that put a
-- limb somewhere (the skater's feet on the ground, cl_skates.lua).
-- (Called from another file, whose own manipulations this one has not seen.)
function BMX.RiderSolveLimb(...) forgetPose() return solveLimb(...) end
function BMX.RiderAimBone(...) forgetPose() return aim(...) end

--------------------------------------------------------------------------
-- THE EYES ON THE WAY AHEAD. A rider who stands across their vehicle (a skater) looks
-- where it is going, over the lead shoulder, not out to the side they face.
--
-- A WHOLE ORIENTATION, NOT A TWIST. Twisting the head round on its own length kept
-- the pose's nod -- the head holding the horizon against a forward lean -- about the
-- head's untwisted axis, and once the face was turned toward the nose that nod tipped
-- it back to look at the sky (kleiner's mesh in the offline studio, 2026-10-19). So the
-- head is set to look along `dir` (pitched LOOK_DOWN under it, at the ground ahead)
-- with its eyes level, measured: where the face points now (the model's "forward"
-- bone, else the head's -Y, [[valvebiped-bone-frames]]) and which way the skull's top
-- is (its own X), and the turn that takes those to the wanted gaze and the vertical
-- is put on the bone. The neck takes LOOK_NECK of the turn about the vertical first,
-- so it does not all kink at the skull. A face is never turned more than LOOK_LIMIT
-- from the way the chest faces. What the head's base pose and the engine's aim layer
-- already did is all in what is measured, so it needs to know neither.
--------------------------------------------------------------------------
local LOOK_LIMIT, LOOK_NECK, LOOK_DOWN = 75, 0.4, 8
-- Rotations as their three columns (where x, y and z go): a manipulation is applied in
-- the bone's own frame after its pose, so a bone's world rotation is the posed one
-- times the manipulation's.
local function cols(a) return { a:Forward(), -a:Right(), a:Up() } end
local function boneCols(m) return { m:GetForward(), -m:GetRight(), m:GetUp() } end
local function apply(R, v) return R[1] * v.x + R[2] * v.y + R[3] * v.z end
local function applyT(R, v) return Vector(R[1]:Dot(v), R[2]:Dot(v), R[3]:Dot(v)) end
local function mul(A, B) return { apply(A, B[1]), apply(A, B[2]), apply(A, B[3]) } end
local function toAngle(R) return R[1]:AngleEx(R[3]) end
-- The manipulation that turns a bone whose world rotation is R (under manipulation m)
-- by `turn`, a function on world vectors: m * R^T * turn * R.
local function turnedManip(m, R, turn)
    local RtQR = {}
    for i = 1, 3 do RtQR[i] = applyT(R, turn(R[i])) end
    return toAngle(mul(cols(m), RtQR))
end
local function flat(v) return Vector(v.x, v.y, 0) end
local function yawOf(v) return math.deg(math.atan2(v.y, v.x)) end
local function rotZ(v, deg)
    local c, s = math.cos(math.rad(deg)), math.sin(math.rad(deg))
    return Vector(v.x * c - v.y * s, v.x * s + v.y * c, v.z)
end

local function gazeOf(ply, hb)
    local fb = lookupBone(ply, "ValveBiped.forward")
    local m = ply:GetBoneMatrix(fb or hb)
    if not m then return nil end
    return fb and m:GetForward() or m:GetRight()
end

-- `dir`: the world direction to look along. Returns the yaw the face turned, degrees.
function BMX.RiderLookAt(ply, dir)
    forgetPose()
    local hb = lookupBone(ply, "ValveBiped.Bip01_Head1")
    local nb = lookupBone(ply, "ValveBiped.Bip01_Neck1")
    local cb = lookupBone(ply, "ValveBiped.Bip01_Spine4") or lookupBone(ply, "ValveBiped.Bip01_Spine2")
    if not (hb and dir) or flat(dir):Length() < 1e-3 then return end
    ply.bmxIK = ply.bmxIK or {}
    -- The neck is this function's alone: square again before anything is measured.
    if nb then manip(ply, nb, Angle(0, 0, 0)) end
    refresh(ply)
    local g0 = gazeOf(ply, hb)
    if not g0 or flat(g0):Length() < 1e-3 then return end
    -- The way to look, no further round than LOOK_LIMIT from the chest's facing.
    local want = yawOf(dir)
    local C = cb and ply:GetBoneMatrix(cb)
    if C then
        local chest = yawOf(-C:GetRight())          -- (the spine's +Y faces forward)
        want = chest + math.Clamp(math.AngleDifference(want, chest), -LOOK_LIMIT, LOOK_LIMIT)
    end
    local turnYaw = math.AngleDifference(want, yawOf(g0))
    -- The neck's share, about the vertical.
    if nb and math.abs(turnYaw) > 0.1 then
        local N = ply:GetBoneMatrix(nb)
        if N then
            local a = turnedManip(Angle(0, 0, 0), boneCols(N), function(v) return rotZ(v, turnYaw * LOOK_NECK) end)
            manip(ply, nb, a)
            ply.bmxIK[nb] = a                       -- (put back on getting off)
            refresh(ply)
        end
    end
    -- The head: its gaze onto the wanted one, the top of the skull up.
    local H = ply:GetBoneMatrix(hb)
    local g = gazeOf(ply, hb)
    if not (H and g) then return end
    local Hc = boneCols(H)
    local function frame(x, top)
        x = x:GetNormalized()
        local z = top - x * top:Dot(x)
        if z:Length() < 1e-3 then return nil end
        z:Normalize()
        return { x, z:Cross(x), z }
    end
    local cur = frame(g, Hc[1])                    -- (the head's own X runs up the skull)
    local d = Angle(LOOK_DOWN, want, 0):Forward()
    local wanted = frame(d, Vector(0, 0, 1))
    if not (cur and wanted) then return end
    local function turn(v) return apply(wanted, applyT(cur, v)) end
    manip(ply, hb, turnedManip(ply:GetManipulateBoneAngles(hb), Hc, turn))
    refresh(ply)
    return turnYaw
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
-- over BMX.PoseBlendTime, in and out, eased (BMX.UpdatePoseWeights).
--------------------------------------------------------------------------
local HANDS_UP = { rHand = Vector(8, -15, 36), lHand = Vector(8, 15, 36) }
-- A no-footer kicks the legs out WIDE, nearly straight: at 14 out and low the knees
-- only splayed, a squat over the top tube (kleiner's mesh in the offline studio,
-- 2026-10-19).
local FEET_OUT = { rFoot = Vector(0, -29, 10), lFoot = Vector(0, 29, 10) }

-- `openHands`: the hands it takes off the bars hold nothing, so they OPEN (they stayed
-- the fists that had held the grips: kleiner's mesh in the offline studio, 2026-10-19).
BMX.RiderPoses = {
    nohander = { rHand = HANDS_UP.rHand, lHand = HANDS_UP.lHand, spineLean = -4, openHands = true },
    nofooter = { rFoot = FEET_OUT.rFoot, lFoot = FEET_OUT.lFoot },
    -- A can-can swings one leg over the top tube to the other side.
    cancan_r = { rFoot = Vector(-1, 9, 14) },
    cancan_l = { lFoot = Vector(-1, -9, 14) },
    -- Superman: legs out STRAIGHT behind, body laid forward, hands on the bars (the feet
    -- were 21 units behind the hips and the knees folded up behind like a frog's).
    superman = { rFoot = Vector(-36, -5, 25), lFoot = Vector(-36, 5, 25), spineLean = 40 },
    nothing  = { rHand = HANDS_UP.rHand, lHand = HANDS_UP.lHand,
                 rFoot = FEET_OUT.rFoot, lFoot = FEET_OUT.lFoot, spineLean = 6, openHands = true },
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
-- Open hands, elbows out and a little back: arms held out for balance.
BMX.PoseSets.unicycle.openHands = true
-- (and a unicyclist stays on the saddle whatever the stance: it is all they have)
BMX.PoseSets.unicycle.seatedOnly = true
BMX.PoseSets.unicycle.poles = { arm = Vector(-0.4, 1, -0.15), leg = Vector(1, 0, 0.2) }

local POSE_HANDS = { "rHand", "lHand" }
local POSE_LIMBS = { "rHand", "lHand", "rFoot", "lFoot" }

-- This bike's pose weights (name -> 0..1), moved toward the pose the server
-- says is held. Called once a frame from the bike's Draw.
--
-- EASED, NOT LINEAR. The weights move at a steady rate (bike.poseLin), and
-- what the body follows is that eased in and out (smoothstep), so a limb
-- leaves its grip gently, swings, and settles on its pose instead of starting
-- and stopping dead. Crossing from one pose to another still sums to one:
-- smoothstep(1 - t) is 1 - smoothstep(t).
local function ease(t) return t * t * (3 - 2 * t) end
BMX.PoseEase = ease

function BMX.UpdatePoseWeights(bike, current, dt)
    local L = bike.poseLin or {}
    bike.poseLin = L
    local W = {}
    bike.poseW = W
    local step = (dt or 0) / BMX.PoseBlendTime
    for _, name in ipairs(BMX.PoseNames) do
        local w = L[name] or 0
        local target = (name == current) and 1 or 0
        if w < target then w = math.min(target, w + step)
        elseif w > target then w = math.max(target, w - step) end
        L[name] = w > 0 and w or nil
        if w > 0 then W[name] = ease(w) end
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
                -- (open once it is mostly off the bar: cl_rider.lua eases the fingers)
                if d[key] and d.openHands and w > 0.5 then ik[key .. "Open"] = true end
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
--------------------------------------------------------------------------
-- TARGETS CARRIED WITH THE VEHICLE. The grips and pedals are where the vehicle's own
-- drawing put them, in the world, as it stood then. A rider posed before it is drawn
-- again -- earlier in the same frame, or in a view it was not drawn in at all (culled,
-- off the edge of the screen) -- reached for where the bars had been: on a real
-- client a scooter rider's hands trailed a foot behind and below the bars (2026-10-20).
-- So they are first moved on with the vehicle since that drawing (rigidly: a turn of
-- the bars or the cranks since is a frame's worth, and the next drawing has it). The
-- offsets from a shoulder (`Rel`) are not points, and stay.
--------------------------------------------------------------------------
function BMX.CarryTargets(bike)
    local at = bike.bmxTargetsAt
    if not at then return end
    local p, f, r, u = bike:GetPos(), bike:GetForward(), bike:GetRight(), bike:GetUp()
    if p == at.p and f == at.f and u == at.u then return end
    for _, t in ipairs({ bike.ikTargets or false, bike.ikTargetsStoker or false }) do
        if t then
            for k, v in pairs(t) do
                if isvector(v) and not (isstring(k) and k:sub(-3) == "Rel") then
                    local d = v - at.p
                    t[k] = p + f * d:Dot(at.f) + r * d:Dot(at.r) + u * d:Dot(at.u)
                end
            end
        end
    end
    at.p, at.f, at.r, at.u = p, f, r, u
end

local animated = {}     -- player -> true while we have bones moved on them
local LIFE = { breathe = 0.8, drift = 1.6 }    -- degrees of the back's lean and twist
local SPRINT_RISE, SPRINT_OVER = 0.8, 0.5     -- a sprint is out of the saddle, over the cranks
local STAND = { rise = 0, over = 0 }          -- (reused: what RiderFollowFrame is handed)
local LAND_MIN     = 120    -- u/s downward: gentler than this is not worth a crouch
local LAND_FULL    = 450    -- u/s downward for the deepest crouch
local LAND_RECOVER = 2.0    -- per second: back up in about half a second
-- A RIDER FAR AWAY STILL PEDALS. The IK re-poses the skeleton a few dozen times a
-- frame: every frame near the view, every IK_FAR_EVERY frames out to IK_FAR, and
-- not at all beyond (they keep the pose they had). It used to stop at IK_RANGE,
-- and a rider across the park froze mid-stroke on a moving bike.
local IK_FAR       = 3000
local IK_FAR_EVERY = 4
local LIMB_KEYS = { rThigh = true, lThigh = true, rCalf = true, lCalf = true,
                    rArm = true, lArm = true }

local function clear(ply)
    for _, name in pairs(BONES) do
        local b = ply:LookupBone(name)
        if b then manip(ply, b, Angle(0, 0, 0)) end
    end
    for b in pairs(ply.bmxIK or {}) do manip(ply, b, Angle(0, 0, 0)) end
    ply.bmxIK, ply.bmxHinge, ply.bmxSpineTwist, ply.bmxSpineLean = nil, nil, nil, nil
    ply.bmxSpineTwistShown, ply.bmxSpineLeanShown, ply.bmxReachSm = nil, nil, nil
    ply.bmxGripOff, ply.bmxPoseFrame, ply.bmxIKJump, ply.bmxFramePelvis = nil, nil, nil, nil
    ply.bmxCurl, ply.bmxLook = nil, nil
    -- The board's crouch lowers the pelvis (cl_board.lua); put it back.
    if ply.bmxPelvis then
        manipPos(ply, ply.bmxPelvis, Vector(0, 0, 0))
        ply.bmxPelvis = nil
    end
    animated[ply] = nil
end
BMX.ClearRiderPose = clear

-- How far forward the pose has a rider's back, degrees, summed down the spine and
-- less the IK's own reach lean: what the pose set, the style pose and the stance chose.
function BMX.RiderSpineLean(ply)
    local total = 0
    for _, key in ipairs({ "spineLow", "spineMid", "spine" }) do
        local b = ply:LookupBone(BONES[key])
        if b then total = total + ply:GetManipulateBoneAngles(b).y end
    end
    return total - (ply.bmxReachSm and ply.bmxSpineLeanShown or 0)
end

hook.Add("PrePlayerDraw", "BMX.RiderMotion", function(ply)
    forgetPose()
    local bike = cv_anim:GetBool() and BMX.LocalBike(ply) or nil
    if not bike then
        if animated[ply] then clear(ply) end
        return
    end

    -- Once a frame: a player drawn twice in one (a water reflection, a mirror,
    -- a camera's screen) keeps what the first draw posed, rather than easing
    -- twice as fast and solving the IK twice. A passenger too: theirs eases.
    local frameNo = FrameNumber and FrameNumber()
    if frameNo and ply.bmxPoseFrame == frameNo then return end
    ply.bmxPoseFrame = frameNo

    -- A PASSENGER is not at the bars: their pose is their own (cl_passenger.lua).
    if BMX.IsPassenger and BMX.IsPassenger(ply) then
        BMX.CarryTargets(bike)
        BMX.PassengerPose(ply, bike)
        animated[ply] = true
        return
    end

    local C = bike:Cfg()
    BMX.CarryTargets(bike)
    local useIK = cv_ik:GetBool() and bike.ikTargets ~= nil
    -- IK SWITCHED OFF MID-RIDE (bmx_rider_ik 0, the options panel): what the solver
    -- had posed -- forearms, hands, fingers, feet, a board rider's crouch -- stayed
    -- where it last put them, and came apart from the bike until the rider got off.
    -- Back to rest; the pose layer below has the limbs now.
    if not useIK and ply.bmxIK then
        for b in pairs(ply.bmxIK) do manip(ply, b, Angle(0, 0, 0)) end
        ply.bmxIK, ply.bmxHinge, ply.bmxSpineTwist, ply.bmxSpineLean = nil, nil, nil, nil
        ply.bmxSpineTwistShown, ply.bmxSpineLeanShown, ply.bmxReachSm = nil, nil, nil
        ply.bmxGripOff, ply.bmxIKJump, ply.bmxCurl = nil, nil, nil
        if ply.bmxPelvis then
            manipPos(ply, ply.bmxPelvis, Vector(0, 0, 0))
            ply.bmxPelvis = nil
        end
    end
    local dt = FrameTime()
    local st = bike.bmxSm or {}
    bike.bmxSm = st

    -- THE LEGS SOAK UP A LANDING. On touching down with real downward speed
    -- the rider crouches, in proportion to how hard it was, and eases back up
    -- over about half a second: the same fold as a hop preload. Worked out
    -- here from what the client already sees (grounded, and the bike's
    -- vertical velocity just before), so it costs no networking. The impact
    -- (bmxLandHit) is a step; the crouch (bmxLand) follows it on a spring, so
    -- the knees give over a few frames instead of folding in one.
    local grounded = bike:GetGrounded()
    local vz = bike:GetVelocity().z
    if grounded and bike.bmxWasAir and (bike.bmxAirVz or 0) < -LAND_MIN then
        bike.bmxLandHit = math.Clamp(-bike.bmxAirVz / LAND_FULL, 0.35, 1)
    end
    if not grounded then bike.bmxAirVz = vz end
    bike.bmxWasAir = not grounded
    bike.bmxLandHit = math.max(0, (bike.bmxLandHit or 0) - dt * LAND_RECOVER)
    local land = follow(st, "land", bike.bmxLandHit, SMOOTH.land, dt)
    if bike.bmxLandHit == 0 and land < 0.002 then land, st.land, st.landV = 0, 0, 0 end
    bike.bmxLand = land

    -- The rest of what the pose is built from, followed (SMOOTH).
    local hopNow = bike:GetHopCharge()
    local hop = follow(st, "hop", hopNow, hopNow > (st.hop or 0) and SMOOTH.hopIn or SMOOTH.hopOut, dt)
    local sprint = follow(st, "sprint", bike:GetSprinting() and 1 or 0, SMOOTH.sprint, dt)
    local leanFwd = follow(st, "lean", bike:GetLeanFwd(), SMOOTH.lean, dt)
    local air = follow(st, "air", grounded and 0 or 1, SMOOTH.air, dt)
    local crank = bike.crankAngle or 0
    local turned = st.crank and math.abs((crank - st.crank + math.pi) % (2 * math.pi) - math.pi) or 0
    st.crank = crank
    local pedal = follow(st, "pedal", dt > 0 and math.Clamp(turned / dt / PEDAL_FULL, 0, 1) or 0, SMOOTH.pedal, dt)
    local stanceName = BMX.StanceOf and BMX.StanceOf(ply) or "seated"
    local stance = follow(st, "stance", BMX.StanceLean and BMX.StanceLean(ply) or 0, SMOOTH.stance, dt)
    local stand = follow(st, "stand", (stanceName == "standing" or stanceName == "attack") and 1 or 0,
        SMOOTH.stance, dt)
    local yaw = bike:GetAngles().y
    local yawRate = (st.yaw and dt > 0) and math.AngleDifference(yaw, st.yaw) / dt or 0
    st.yaw = yaw
    local look = follow(st, "look", math.Clamp(yawRate * LOOK_GAIN, -LOOK_MAX, LOOK_MAX), SMOOTH.look, dt)

    local set = BMX.PoseSetFor(bike)
    local pose = set.rider({
        crank    = crank,
        speed    = bike:GetSpeedUPS(),
        topSpeed = BMX.Gears.TopCeiling(bike, C),
        sprint   = sprint,
        hop      = math.max(hop, land),
        pitch    = select(2, BMX.Attitude(bike, vector_up)),
        steer    = bike:GetSteer(),
        leanFwd  = leanFwd,
        stand    = stand,
        pedal    = pedal,
        air      = air,
        -- For a pose set that needs more than the bike's own numbers (the
        -- board's crouch and stance live on the entity and the player).
        bike     = bike,
        ply      = ply,
    })
    -- A style pose folds and twists the torso too (BMX.RiderPoses).
    local poseLean, poseTwist = BMX.PoseBody(bike.poseW, set.poses)
    -- ...and so does the rider's chosen stance (sh_stance.lua, G21), eased.
    poseLean = poseLean + stance
    -- A pose set may cap how far the CHOSEN lean folds the torso (`maxLean`,
    -- degrees). The tuck, the set's own lean, a style pose and the stance
    -- otherwise just add up: on a motorbike at full speed in the attack stance
    -- they came to 62 degrees, the head below the bars (seen with tools/rider).
    -- The IK's own lean toward grips out of reach (spineReach) goes on after
    -- the cap, so a capped rider still gets their hands to the bars.
    local setLean = pose.spine.y
    local lean = setLean + poseLean
    local twist = pose.spine.r + poseTwist
    -- NEVER STILL: every rider breathes, and their weight drifts a little side to side,
    -- on a clock that ticks five times a second (cl_board.lua's B.DriftClock: the IK
    -- re-poses only when something moved, so a rider sat still is still nearly free). A
    -- pose set that does its own (the board's B.Posture) says so.
    if not set.ownLife then
        local t, seed = math.floor(CurTime() * 5) / 5, ply:EntIndex() * 1.37
        lean = lean + LIFE.breathe * math.sin(t * math.pi * 2 * 0.25 + seed)
        twist = twist + LIFE.drift * (0.6 * math.sin(t * math.pi * 2 * 0.11 + seed * 1.7)
            + 0.4 * math.sin(t * math.pi * 2 * 0.29 + seed * 0.6))
    end
    if set.maxLean and lean > set.maxLean then lean = set.maxLean end
    local reachLean = 0
    if useIK then
        -- The IK's own lean and twist (spineReach), followed.
        local reachTwist
        reachLean, reachTwist = BMX.RiderReachFollow(ply, dt)
        lean = lean + reachLean
        twist = twist + reachTwist
    end
    pose.spine = Angle(pose.spine.p, lean, twist)
    -- The neck holds the horizon against what was added to the set's own lean
    -- (the stance, a style pose, the IK's reach), as each set's head does
    -- against its own: the eyes stay up the road.
    -- ...and turns into the corner (`look`, above).
    if pose.head then
        pose.head = Angle(pose.head.p, pose.head.y - (lean - setLean) * HEAD_HOLD, pose.head.r + look)
    end
    -- The chosen lean shared down the back; Spine2 keeps the rest of it, the
    -- IK's reach and the twist.
    local rest = lean - reachLean
    for _, sh in ipairs(set.spineShare or SPINE_SHARE) do
        local b = lookupBone(ply, BONES[sh[1]])
        if b then
            manip(ply, b, Angle(0, rest * sh[2], 0))
            lean = lean - rest * sh[2]
        end
    end
    pose.spine = Angle(pose.spine.p, lean, pose.spine.r)
    for key, ang in pairs(pose) do
        -- With IK on, the limbs are the solver's; the pose keeps the body.
        if not (useIK and LIMB_KEYS[key]) then
            local b = lookupBone(ply, BONES[key])
            if key == "head" then ang = BMX.HeadAngle(ang) end
            if b then manip(ply, b, ang) end
        end
    end
    -- The solve re-poses the skeleton a few dozen times, which is nothing for
    -- the riders near you and waste for one across the map, so a rider far
    -- from the view keeps the pose they last had (manipulations persist).
    -- On the saddle the bike drew (a board's and a scooter's riders stand on drawings
    -- of their own, with their own pelvis).
    if not set.solveIK then
        local seat = BMX.SeatFor and BMX.SeatFor(bike:Bike(), C, "rider")
        -- Out of the saddle: the stance's, or a sprint's (a rider sprints stood up).
        local sOff = BMX.RiderPoseOffset and BMX.RiderPoseOffset(stanceName) or {}
        local rise = set.seatedOnly and 0 or math.max(sOff.rise or 0, sprint * SPRINT_RISE)
        local over = math.max(sOff.over or 0, sprint * SPRINT_OVER)
        rise = follow(st, "rise", rise, SMOOTH.stance, dt)
        STAND.rise, STAND.over = rise, follow(st, "over", over, SMOOTH.stance, dt)
        BMX.RiderFollowFrame(ply, bike, seat and seat.offset or C.Chassis.seatOffset, useIK and STAND or nil)
    end
    local dist = useIK and EyePos():Distance(ply:GetPos()) or math.huge
    if dist < IK_RANGE or (dist < IK_FAR and ((frameNo or 0) + ply:EntIndex()) % IK_FAR_EVERY == 0) then
        ply.bmxLook = look              -- (a set that aims the head itself looks into the turn too)
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
--
-- EVERY ragdoll, so every ragdoll must answer: the PlayerColor proxy (matproxy/
-- player_color.lua) sets nothing at all when GetPlayerColor gives no vector, and the
-- shared material kept the last colour drawn with it -- a sandbox ragdoll or a TTT
-- corpse turned up in some other player's colour. Not a crash ragdoll of ours (or not
-- yet told whose), it answers what the proxy would without the method. The
-- networked colour is read against a value no colour can be, so the answer does not
-- hang on what GetNWVector gives for an unset key.
local NO_COLOUR = Vector(-1, -1, -1)
local DEFAULT_COLOUR = Vector(62 / 255, 88 / 255, 106 / 255)
local function ragdollColour(self)
    local col = self:GetNWVector("BMXPlayerColor", NO_COLOUR)
    if col and col ~= NO_COLOUR then return col end
    local rider = self:GetNWEntity("BMXRider", NULL)
    if IsValid(rider) and rider.GetPlayerColor then return rider:GetPlayerColor() end
    return DEFAULT_COLOUR
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
