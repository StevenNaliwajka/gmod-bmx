--[[--------------------------------------------------------------------------
    bmx/cl_motor.lua

    THE MOTOR VEHICLES' PRESENTATION (G14, G15): the HUD's extra lines, the whine
    and the engine note, and the motorcyclist's pose. Everything it reads is what
    the server already networks for the purpose (Rpm, Battery, Clutch, Assist, Gear);
    nothing here is simulation.

    THE SOUNDS are the addon's own loops (sh_sound.lua, tools/sound/make_sounds.py):
    a channel per vehicle whose PITCH follows the networked rpm and whose volume
    follows how hard it is working. An engine's file was made at a known rpm, so
    its pitch is the rpm over that: the note IS the firing rate.
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

-- Do the cranks stand still? A motorbike has none (its feet are on pegs, and every
-- drawing leaves the cranks off: M.HasPedals). A moped's pedals are its starter: they
-- turn with the wheel while the rider pedals it off, and once the engine has caught
-- (the server networks rpm above nothing only then, sv_motor.lua) the freewheel lets
-- them stop and the rider's feet rest on them, level. cl_init.lua asks every frame.
function M.FixedCranks(bike)
    if not M.HasPedals(bike) then return true end
    local d = bike:Bike().drive
    return d.kind == "engine" and d.pedalStart ~= nil and bike.GetRpm ~= nil and bike:GetRpm() > 0
end

-- WHERE HELD CRANKS STAND: level, the nearer way round (a foot that was forward stays
-- the forward one), eased there rather than snapped so the legs do not jump when the
-- engine catches. `cur` is the crank angle drawn last frame. Nothing to ease without
-- pedals: 0.
M.CRANK_REST_RATE = 6        -- 1/s: about a third of a second to come level
function M.RestCrank(bike, cur, dt)
    if not M.HasPedals(bike) then return 0 end
    cur = cur or 0
    local level = math.floor(cur / math.pi + 0.5) * math.pi
    local d = level - cur
    if math.abs(d) < 1e-3 then return level end
    return cur + d * math.min(1, M.CRANK_REST_RATE * (dt or 0))
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

-- THE ATTACK POSITION, seated: torso forward over the tank, head up, elbows up and
-- out, knees in against the tank, both legs alike (there are no pedals: the BMX's
-- pedalling swing at a still crank is asymmetric, one knee open and one closed).
local MOTO = { lean = 14, leanFast = 8, thigh = -10, calf = 18 }
BMX.MotoPose = MOTO
if BMX.PoseSets and BMX.PoseSets.moto then
    BMX.PoseSets.moto.rider = function(s)
        local t = {}
        for k, v in pairs(s) do t[k] = v end
        t.crank = 0                      -- nothing pedals
        local pose = BMX.RiderPose(t)
        local frac = math.Clamp((s.speed or 0) / math.max(s.topSpeed or 1, 1), 0, 1)
        local spine = pose.spine.y + MOTO.lean + MOTO.leanFast * frac
        pose.spine = Angle(pose.spine.p, spine, pose.spine.r)
        pose.head = Angle(0, -spine * 0.85, 0)
        -- the legs alike, folded to the pegs; the hop/landing crouch still adds to both
        local crouch = (s.hop or 0) * 24
        local th, ca = MOTO.thigh - crouch, MOTO.calf + crouch * 1.4
        pose.rThigh, pose.lThigh = Angle(0, th, 0), Angle(0, th, 0)
        pose.rCalf, pose.lCalf = Angle(0, ca, 0), Angle(0, ca, 0)
        return pose
    end
    BMX.PoseSets.moto.poles = { arm = Vector(-0.15, 1, 0.45), leg = Vector(1, -0.3, 0.25) }
    BMX.PoseSets.moto.poses = BMX.RiderPoses
end

--------------------------------------------------------------------------
-- THE SOUND. One looping channel per motor vehicle.
--
--   assist / e-moto  the whine (BMX.Sounds.motor): pitch rises with the motor's rpm,
--                    volume with how fast it is turning, silent when it is not
--   engine           the note (BMX.Sounds.engine, or the registry's drive.sound: the
--                    moped's engine2t): pitch is rpm / the file's baseRpm, and a
--                    little louder under load; a pulled clutch lets it rev free.
--                    A moped's engine is silent until the pedals have started it.
--
-- BMX.MotorSoundParams is pure: rpm in, pitch and volume out. The loop below only
-- feeds it and plays the result.
--------------------------------------------------------------------------
function BMX.MotorSoundParams(key, rpm, redline)
    local S = BMX.Sounds[key]
    local f = math.Clamp((rpm or 0) / math.max(redline or 1, 1), 0, 1)
    local pitch = S.pitch[1] + (S.pitch[2] - S.pitch[1]) * f
    if S.baseRpm then pitch = math.Clamp(100 * (rpm or 0) / S.baseRpm, S.pitch[1], S.pitch[2]) end
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

-- The loop a motor vehicle plays: its registry's drive.sound, else by kind.
function BMX.MotorSoundKey(def)
    local d = def.drive
    if d.sound and BMX.Sounds[d.sound] then return d.sound end
    return d.kind == "engine" and "engine" or "motor"
end

for _, k in ipairs({ "motor", "engine", "engine2t" }) do
    if BMX.Sounds[k] then util.PrecacheSound(BMX.Sounds[k].path) end
end

local live = {}

local function stopState(state)
    if state.patch then state.patch:Stop() end
end

local function updateSound(ent, state)
    local def = ent:Bike()
    local key = BMX.MotorSoundKey(def)
    local S = BMX.Sounds[key]
    if not BMX.SoundsOn() then stopState(state) return end
    local vRide = BMX.VolRide()
    local rpm = ent:GetRpm()
    local pitch, vol = BMX.MotorSoundParams(key, rpm, topRpm(def))
    -- An idling engine is audible; the whine is not until it spins. But a moped's
    -- engine is OFF until the pedals start it (sv_motor.lua networks 0 rpm until
    -- then), and it used to idle the moment anyone sat on it.
    if M.IsEngine(ent) and IsValid(ent:GetDriver()) and (rpm > 0 or not def.drive.pedalStart) then
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
