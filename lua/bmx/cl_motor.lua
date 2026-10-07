--[[--------------------------------------------------------------------------
    bmx/cl_motor.lua

    THE MOTOR VEHICLES' PRESENTATION (G14, G15): the HUD's extra lines, the whine
    and the engine note, and the motorcyclist's pose. Everything it reads is what
    the server already networks for the purpose (Rpm, Battery, Clutch, Assist, Gear);
    nothing here is simulation.

    THE SOUNDS ARE PLACEHOLDERS, base-game paths in sh_sound.lua like every other
    sound in the addon (docs/DESIGN.md section 8): a looping channel per vehicle
    whose PITCH follows the networked rpm and whose volume follows how hard it is
    working. Nobody has heard them; replacing one is the one-line edit the table
    describes.
----------------------------------------------------------------------------]]

BMX = BMX or {}
local M = BMX.Motor

--------------------------------------------------------------------------
-- THE HUD LINES, as data: what cl_hud.lua draws under the speed. Pure, so the
-- suite reads it without a screen. nil for a vehicle with nothing to add.
--
--   assist   "assist 2/3" on an e-bike
--   battery  0..1, or nil for an infinite pack; with batteryLabel "62%" / "inf"
--   rpm      0..1 of the redline (engines) or of the motor's range, for the bar
--   gear     "gear 3/5" (the road bike's label), on an engine
--   clutch   true while the lever is pulled in
--------------------------------------------------------------------------
function BMX.MotorHudInfo(bike)
    if not M or not M.IsMotor(bike) then return nil end
    local def = bike:Bike()
    local d = def.drive
    local out = {}
    if M.IsAssist(bike) then
        out.assist = string.format("assist %d/%d", M.Level(bike), M.MAX_LEVEL)
    end
    if M.HasBattery(bike) then
        local b = bike:GetBattery()
        if b < 0 then
            out.battery, out.batteryLabel = nil, "battery inf"
        else
            out.battery = math.Clamp(b, 0, 1)
            out.batteryLabel = string.format("battery %d%%", math.floor(out.battery * 100 + 0.5))
        end
    end
    if M.IsEngine(bike) then
        out.rpm = math.Clamp(bike:GetRpm() / d.redline, 0, 1)
        out.rpmLabel = string.format("%.0f rpm", bike:GetRpm())
        out.gear = BMX.Gears.Label(bike)
        out.clutch = bike:GetClutch() > 0.5
    end
    return out
end

-- Do the cranks stand still? A motorbike's feet are on pegs: the cranks the
-- procedural bike draws are held at a fixed angle (cl_init.lua asks).
function M.FixedCranks(bike)
    local d = bike:Bike().drive
    if d.kind == "engine" then return d.pedalStart == nil end
    return d.kind == "throttle" and d.battery ~= nil
end

--------------------------------------------------------------------------
-- THE RIDER'S POSE. A motorcyclist sits forward on the seat with the legs bent to
-- the pegs: the bike's pose with the pedalling taken out and the body a little
-- forward (the same IK still puts the hands on the grips and the feet on the
-- pegs the cranks stand in for). The FMX poses are rows in the style-pose table,
-- in the bike's own space like the BMX's (cl_rider.lua BMX.RiderPoses); nobody has
-- watched them on a real model.
--------------------------------------------------------------------------
-- They go in the SAME table as the BMX's (every registered pose has a row there: the
-- suite checks it), reachable only on a motorcycle because only its keys decode them.
BMX.RiderPoses.heelclicker = { rFoot = Vector(-17, -3, 24), lFoot = Vector(-17, 3, 24), spineLean = 10 }
BMX.RiderPoses.cliffhanger = { rFoot = Vector(12, -6, 33), lFoot = Vector(12, 6, 33), spineLean = -12 }

if BMX.PoseSets and BMX.PoseSets.moto then
    BMX.PoseSets.moto.rider = function(s)
        local t = {}
        for k, v in pairs(s) do t[k] = v end
        t.crank = 0                      -- nothing pedals
        local pose = BMX.RiderPose(t)
        local spine = pose.spine.y + 8   -- sat forward, over the tank
        pose.spine = Angle(pose.spine.p, spine, pose.spine.r)
        pose.head = Angle(0, -spine * 0.7, 0)
        return pose
    end
    BMX.PoseSets.moto.poses = BMX.RiderPoses
end

--------------------------------------------------------------------------
-- THE SOUND. One looping channel per motor vehicle.
--
--   assist / e-moto  the whine (BMX.Sounds.motor): pitch rises with the motor's rpm,
--                    volume with how fast it is turning, silent when it is not
--   engine           the note (BMX.Sounds.engine): pitch from idle to redline, and a
--                    little louder under load; a pulled clutch lets it rev free
--
-- BMX.MotorSoundParams is pure: rpm in, pitch and volume out. The loop below only
-- feeds it and plays the result.
--------------------------------------------------------------------------
function BMX.MotorSoundParams(key, rpm, redline)
    local S = BMX.Sounds[key]
    local f = math.Clamp((rpm or 0) / math.max(redline or 1, 1), 0, 1)
    local pitch = S.pitch[1] + (S.pitch[2] - S.pitch[1]) * f
    local vol = rpm and rpm > 1 and S.vol * (0.45 + 0.55 * f) or 0
    return pitch, vol
end

-- A motor's top rpm for the pitch scale, kind by kind.
local function topRpm(def)
    local d = def.drive
    if d.kind == "engine" then return d.redline end
    -- The motor turns at the wheel's speed times its reduction; the top is where the
    -- vehicle tops out (an e-bike at its assist limit, an e-moto at maxSpeed).
    local radius = BMX.ConfigFor(def).Wheel.radius
    local top = d.kind == "assist" and M.LimitUps() or d.maxSpeed or 400
    return top / radius * (d.motorRatio or (d.kind == "assist" and 12 or 10)) * M.RPM
end
M.TopRpm = topRpm

if not CLIENT then return end

for _, k in ipairs({ "motor", "engine" }) do
    if BMX.Sounds[k] then util.PrecacheSound(BMX.Sounds[k].path) end
end

local live = {}

local function stopState(state)
    if state.patch then state.patch:Stop() end
end

local function updateSound(ent, state)
    local def = ent:Bike()
    local key = M.IsEngine(ent) and "engine" or "motor"
    local S = BMX.Sounds[key]
    if not BMX.SoundsOn() then stopState(state) return end
    local vRide = BMX.VolRide()
    local rpm = ent:GetRpm()
    local pitch, vol = BMX.MotorSoundParams(key, rpm, topRpm(def))
    -- An idling engine is audible; the whine is not until it spins.
    if key == "engine" and IsValid(ent:GetDriver()) then
        pitch, vol = BMX.MotorSoundParams(key, math.max(rpm, def.drive.idle), def.drive.redline)
    end
    vol = vol * vRide
    local patch = state.patch
    if not patch then
        patch = CreateSound(ent, S.path)
        state.patch = patch
    end
    if vol > 0.01 then
        if not patch:IsPlaying() then patch:PlayEx(0, pitch) end
        patch:ChangeVolume(vol, 0.08)
        patch:ChangePitch(pitch, 0.08)
    elseif patch:IsPlaying() then
        patch:Stop()
    end
end

hook.Add("Think", "BMX.MotorSound", function()
    for ent, state in pairs(live) do
        if not IsValid(ent) then stopState(state); live[ent] = nil end
    end
    for _, ent in ipairs(ents.FindByClass("bmx_*")) do
        if ent.IsBMX and ent.Bike and M.IsMotor(ent) then
            live[ent] = live[ent] or {}
            updateSound(ent, live[ent])
        end
    end
end)

hook.Add("ShutDown", "BMX.MotorSoundStop", function()
    for _, state in pairs(live) do stopState(state) end
    live = {}
end)
