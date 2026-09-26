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

local function clear(ply)
    for _, name in pairs(BONES) do
        local b = ply:LookupBone(name)
        if b then ply:ManipulateBoneAngles(b, Angle(0, 0, 0)) end
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

    local C = bike:Cfg()
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
        local b = ply:LookupBone(BONES[key])
        if b then ply:ManipulateBoneAngles(b, ang) end
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
