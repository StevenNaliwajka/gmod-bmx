--[[--------------------------------------------------------------------------
    bmx/sv_motor.lua

    THE MOTOR DRIVES (G14, G15): what runs inside the physics step for an e-bike, an
    e-moto, a dirt bike and a moped, the battery they share, and the door that
    keeps a server's players off them when the owner says so. The model they are
    built from, and every number's meaning, is sh_motor.lua.

    A DRIVE IS A FUNCTION (sv_physics.lua, BMX.Drives): torque out for the whole
    vehicle, plus an optional second value that says whether the rear brake stays on
    (true) or is dropped (false). Each motor kind below is one of those and nothing
    else is special-cased in the physics step, which is the platform's whole point.

        assist     the pedal drive's own torque, and on top of it LEVEL times what the
                   rider is putting into the pedals, faded out at bmx_ebike_limit
        throttle   (the test cart's, wrapped) the same motor, but when the vehicle
                   carries a battery: no motor on an empty pack, regen on the brake
        engine     an engine with a torque curve and a clutch (M.EngineStep), through
                   the road bike's gear model; a moped's engine starts on the pedals

    THE BATTERY lives on the vehicle's state (st.battery, Wh), is drained by the
    motor's work at the wheel (M.ElectricWatts), refilled by regen, and recharged
    while the vehicle is parked and nobody is on it (BMX.MotorThink, from the
    entity's Think). bmx_ebike_battery 0 is an infinite pack: st.battery is nil and
    nothing is ever spent.
----------------------------------------------------------------------------]]

BMX = BMX or {}
local M = BMX.Motor

local min, max, abs = math.min, math.max, math.abs
local function clamp(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end
local RPM = M.RPM

-- REPLICATED, so the HUD and the options panel can show every player what the
-- server is using; they change only on the server (sh_settings.lua rows).
local FLAGS = bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED)
CreateConVar("bmx_ebike_limit", tostring(M.DEFAULT_LIMIT_KMH), FLAGS,
    "BMX: the speed (km/h) an e-bike's motor stops helping at; the rider pedals on alone above it.")
CreateConVar("bmx_ebike_battery", tostring(M.DEFAULT_BATTERY_WH), FLAGS,
    "BMX: an e-bike's battery in watt-hours (an e-moto carries three times this). 0 = infinite.")

local function approach(cur, target, rate, dt)
    local d = target - cur
    local step = rate * dt
    if abs(d) <= step then return target end
    return cur + step * (d > 0 and 1 or -1)
end

--------------------------------------------------------------------------
-- THE PACK. Returns the charge in Wh and the capacity, or nil, nil for an
-- infinite one. A pack is full when it is first looked at, which is the first
-- time the vehicle is ridden or thought about.
--------------------------------------------------------------------------
local function pack(ent, st)
    local cap = M.CapacityWh(ent:Bike())
    if not cap then
        st.battery = nil
        return nil, nil
    end
    if st.battery == nil then st.battery = cap end
    if st.battery > cap then st.battery = cap end
    return st.battery, cap
end
M.Pack = pack

-- Spend (or, with a negative torque, put back) what a wheel torque costs, and keep
-- the books the tests check: the motor's mechanical work in joules.
local function bill(ent, st, torque, omega, dt)
    local joules = M.Watts(torque, omega) * dt
    if joules > 0 then st.motorJ = (st.motorJ or 0) + joules end
    local wh, cap = pack(ent, st)
    if wh then st.battery = M.Spend(wh, cap, M.ElectricWatts(torque, omega), dt) end
end

local function powered(ent, st)
    local wh = pack(ent, st)
    return wh == nil or wh > 0
end

--------------------------------------------------------------------------
-- ASSIST (G14): the legs, plus a motor of LEVEL x what the legs ask for.
--------------------------------------------------------------------------
BMX.Drives.assist = function(ent, cfg, dt, inp, st, wheel, vdef)
    local d = vdef.drive
    local legs = BMX.Drives.pedal(ent, cfg, dt, inp, st, wheel)

    local D = cfg.Drive
    local ratio = BMX.GearRatio(ent, cfg)
    local effort = D.crankTorque * (st.sprinting and D.sprintTorque or 1) * inp.throttle / ratio
    local limit = M.LimitUps()
    local speed = st.fwdSpeed or 0
    local level = M.Level(ent)
    local on = powered(ent, st)
    local tq = M.AssistTorque(level, effort, speed, limit, on) * M.WheelieCut(st.pitch, inp.wheelieMod)
    st.assistTorque = tq
    local omega = wheel and wheel.omega or 0
    if tq > 0 then bill(ent, st, tq, omega, dt) end

    -- The whine follows the motor's own speed, and the motor lets go at the limit:
    -- it is the audible cue that the help has stopped.
    st.rpm = (on and level > 0) and omega * (d.motorRatio or 12) * RPM * M.AssistFade(speed, limit) or 0
    return legs + tq
end

--------------------------------------------------------------------------
-- THROTTLE, WITH A BATTERY AND REGEN (the e-moto). A throttle drive with neither
-- field is the test cart's and goes through the original untouched.
--------------------------------------------------------------------------
local baseThrottle = BMX.Drives.throttle
BMX.Drives.throttle = function(ent, cfg, dt, inp, st, wheel, vdef)
    local d = vdef.drive
    if d.battery == nil and d.regen == nil then
        return baseThrottle(ent, cfg, dt, inp, st, wheel, vdef)
    end
    local tq = baseThrottle(ent, cfg, dt, inp, st, wheel, vdef)
    local omega = wheel and wheel.omega or 0
    local on = powered(ent, st)
    if not on then tq = 0 end
    tq = tq * M.WheelieCut(st.pitch, inp.wheelieMod)
    st.cadence = 0                     -- no legs: nothing turns the cranks

    -- REGEN: S slows the motor as well as the pad. It fades in over the first 60 u/s
    -- so it never pushes a standing vehicle backwards, and it goes to the pack.
    local regen = 0
    local speed = st.fwdSpeed or 0
    if d.regen and inp.brakeRear > 0 and speed > 5 and omega > 0 then
        regen = -d.regen * inp.brakeRear * clamp(speed / 60, 0, 1)
    end
    local drive = tq + regen
    if drive ~= 0 then bill(ent, st, drive, omega, dt) end
    st.assistTorque = drive
    st.rpm = on and omega * (d.motorRatio or 10) * RPM or 0
    return drive, regen < 0 and true or nil
end

--------------------------------------------------------------------------
-- THE ENGINE (G15).
--------------------------------------------------------------------------
BMX.Drives.engine = function(ent, cfg, dt, inp, st, wheel, vdef)
    local d = vdef.drive
    local E = st.engine
    if not E then
        E = M.NewEngine(d)
        -- A moped's engine is OFF until the pedals have started it.
        if d.pedalStart then E.started, E.omega = false, 0 end
        st.engine = E
    end
    local wOmega = wheel and max(wheel.omega, 0) or 0
    local speed = st.fwdSpeed or 0
    local gears = BMX.Gears.Def(ent)
    local ratio = gears and BMX.GearRatio(ent, cfg) or d.ratio

    -- PEDAL START: the legs are the drive (the pedal drive, whole) until the vehicle has
    -- been pedalled d.pedalStart metres, and then the engine catches at the speed it is
    -- doing. A starter does not push; it only takes over.
    if not E.started then
        if wheel then wheel.extraInertia = nil end
        local legs = BMX.Drives.pedal(ent, cfg, dt, inp, st, wheel)
        if inp.throttle > 0 and speed > 0 then E.pedalled = E.pedalled + speed * 0.0254 * dt end
        if E.pedalled >= d.pedalStart and speed > 40 then
            E.started = true
            E.omega = max(d.idle / RPM, wOmega / ratio)
            E.caught = true
        end
        st.rpm = 0
        return legs
    end

    -- THE LEVER. Pulled in quickly, let out quicker: a rider dumps the clutch.
    local want = inp.clutch and 1 or 0
    local prev = E.lever
    E.lever = approach(E.lever, want, want > E.lever and 10 or 16, dt)
    local engage = 1 - E.lever

    local omegaIn = wOmega / ratio
    -- What the wheel weighs from the engine's side of the box: the wheel's own inertia and
    -- the vehicle's mass on its tyre, through the ratio squared.
    local r = cfg.Wheel.radius
    local iWheel = (cfg.Wheel.inertia + cfg.Chassis.mass * r * r) * ratio * ratio
    -- ...and the most the tyre can use: its grip on its load, at the wheel, through the ratio.
    local tyreCap = wheel and (wheel.load or 0) * cfg.Wheel.grip * r * ratio or nil
    local tt, flywheel = M.EngineStep(d, E, inp.throttle, engage, omegaIn, dt, iWheel, tyreCap)
    -- Locked, the engine is part of the wheel: it carries the engine's inertia as its own
    -- (sv_wheel.lua). Anything else, the wheel is light again.
    if wheel then wheel.extraInertia = flywheel and d.inertia / (ratio * ratio) or nil end

    -- THE CLUTCH POP. Let the lever out with the throttle open and the engine well above
    -- the wheel's speed, and the torque that dumps does two things: the wheel gets all
    -- the clutch can carry (above, it is simply the capacity: the revs built up are
    -- what the engine spends), and the rider's body is jerked back, which is a
    -- nose-up kick for popTime seconds, fading. That kick is the wheelie's start; RMB
    -- (weight back) is what holds it, exactly as on a BMX.
    local redOmega = d.redline / RPM
    if prev >= 0.5 and E.lever < 0.5 and inp.throttle > 0.3 then
        local over = E.omega - omegaIn
        if over > 0.25 * redOmega then
            E.pop = d.popTime or 0.4
            E.popStrength = clamp(over / (0.7 * redOmega), 0.3, 1)
        end
    end
    if E.pop > 0 then
        local phys = ent:GetPhysicsObject()
        if wheel and wheel.onGround and IsValid(phys) then
            local t = E.pop / (d.popTime or 0.4)
            BMX.ApplyTorque(phys, ent, ent:GetRight(),
                cfg.Pitch.torque * (d.popGain or 0.9) * E.popStrength * t, dt)
        end
        E.pop = max(E.pop - dt, 0)
    end

    st.cadence = 0
    st.rpm = E.omega * RPM
    st.clutchLever = E.lever
    -- Keep the rear brake whatever the sign: engine braking is a drag, not pedalling backwards.
    return tt / ratio, true
end

--------------------------------------------------------------------------
-- BMX.MotorThink: what the entity's Think (20 Hz) does for a motor vehicle. The
-- networked rpm, battery and clutch; the parked recharge; the engine going cold when
-- the rider gets off.
--------------------------------------------------------------------------
function BMX.MotorThink(ent, st)
    local def = ent:Bike()
    if not M.IsMotor(def) then return end
    local now = CurTime()
    local dt = min(max(now - (ent.bmxMotorT or now), 0), 0.5)
    ent.bmxMotorT = now
    local driven = IsValid(ent:GetDriver())

    ent:SetRpm(driven and (st.rpm or 0) or 0)
    ent:SetClutch(driven and (st.clutchLever or 0) or 0)

    if M.HasBattery(def) then
        local wh, cap = pack(ent, st)
        if wh then
            -- PARKED: nobody aboard and not rolling. Charging at a fixed fraction of the pack.
            if not driven and (st.speed or 0) < 30 then
                st.battery = M.Charge(wh, cap, dt)
                wh = st.battery
            end
            ent:SetBattery(wh / cap)
        else
            ent:SetBattery(-1)
        end
    end

    if not driven and M.IsEngine(def) and st.engine then
        for _, w in ipairs(ent.wheels or {}) do w.extraInertia = nil end
        -- Nobody on it: the engine is off. A moped is started on the pedals again.
        local E = st.engine
        E.omega, E.lever, E.pop, E.pedalled = 0, 0, 0, 0
        if def.drive.pedalStart then E.started = false else E.started = true; E.omega = def.drive.idle / RPM end
        st.rpm, st.clutchLever = 0, 0
    end
end

--------------------------------------------------------------------------
-- THE ASSIST LEVEL (G14). The mouse wheel and [ ] are the shift keys (cl_gears.lua
-- sends them, sv_gears.lua's BMX.Shift hands an e-bike's to here), so an e-bike's
-- "gear" is its level, 0 to 3, with the same cooldown a gear has.
--------------------------------------------------------------------------
function BMX.ShiftAssist(bike, dir)
    local now = CurTime()
    if now < (bike.bmxShiftReady or 0) then return nil end
    local from = M.Level(bike)
    local to = clamp(from + (dir > 0 and 1 or -1), 0, M.MAX_LEVEL)
    if to == from then return nil end
    bike.bmxShiftReady = now + BMX.Gears.SHIFT_COOLDOWN
    bike:SetAssist(to + 1)
    return to
end

-- Straight to a level (a test, a bot): no cooldown.
function BMX.SetAssist(bike, level)
    if not IsValid(bike) or not M.IsAssist(bike) then return nil end
    level = clamp(math.floor(level), 0, M.MAX_LEVEL)
    bike:SetAssist(level + 1)
    return level
end

--------------------------------------------------------------------------
-- THE SPAWN GATE. A motor vehicle needs the CAMI privilege "BMX - Spawn Motor
-- Vehicles" (an admin by default: a server owner who wants everyone to have them
-- grants it to their users in their admin mod's own screen), on top of
-- bmx_allow_motor, which sv_rules.lua's door already honours. It is a
-- PlayerSpawnSENT hook for the reason the others are: that is the one door the spawn
-- menu, bmx_spawn and the /bike window all go through.
--------------------------------------------------------------------------
hook.Add("PlayerSpawnSENT", "BMX.MotorPrivilege", function(ply, class)
    local id = BMX.IdForClass(class)
    local def = id and BMX.Vehicles[id]
    if not def or def.family ~= "moto" then return end
    if BMX.Can(ply, "BMX - Spawn Motor Vehicles") then return end
    if IsValid(ply) then
        ply:ChatPrint("[BMX] motor vehicles need the \"BMX - Spawn Motor Vehicles\" privilege on this server.")
    end
    return false
end)
