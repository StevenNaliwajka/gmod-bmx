--[[--------------------------------------------------------------------------
    bmx/sh_motor.lua

    THE MOTOR MODEL (G14, G15): everything about a powered vehicle that is a
    function and not a side effect. The server's half is sv_motor.lua (it runs
    these inside the physics step and owns the state), the client's is cl_motor.lua
    (the HUD and the sounds); this file is what all of them agree on, and what the
    offline suite can call without a world.

    THREE KINDS OF POWER, all of them a `drive = { kind = ... }` of the platform
    (sh_vehicles.lua, sv_physics.lua BMX.Drives):

        assist    an e-bike's motor. Its torque is a LEVEL (0-3) times what the
                  rider's legs are putting in, and it fades to nothing at a legal-
                  ish speed (bmx_ebike_limit, 25 km/h): the rider pedals on alone
                  above it, as on a real one. It draws on a battery.
        throttle  a motor on the key, no legs (the e-moto): torque falling to nothing
                  at maxSpeed, regen on the brake. Same battery. (The kind was the
                  test cart's; the new fields are optional, so the cart is untouched.)
        engine    a petrol engine: a torque CURVE over rpm, an inertia, and a clutch
                  between it and the gearbox. The dirt bike has five gears (the road
                  bike's gear model, sh_gears.lua, with a ratio that is wheel
                  revolutions per ENGINE revolution) and a clutch lever on SHIFT; the
                  moped has one ratio and starts on the pedals.

    WHY THE UNITS ARE WHAT THEY ARE. A torque in this addon is kg * units^2 / s^2
    and a unit is an inch, so one of them is 0.0254^2 = 6.45e-4 newton-metres. The
    battery is in watt-hours so that a setting a server owner can read (500 Wh, a
    typical e-bike pack) means something; the conversion lives in ONE place (M.NM
    and M.Watts below) so the drain, the regen and the tests share it, and "the
    battery drains roughly as much as the motor does work" is a statement about the
    same numbers the physics step is using, not a tuned curve.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Motor = BMX.Motor or {}
local M = BMX.Motor

local min, max, abs = math.min, math.max, math.abs
local function clamp(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end

--------------------------------------------------------------------------
-- CONSTANTS
--------------------------------------------------------------------------
M.MAX_LEVEL = 3              -- assist levels 0..3
M.EFFICIENCY = 0.85          -- battery to wheel (controller, motor, gears)
M.REGEN_EFF  = 0.60          -- wheel to battery, braking
M.CHARGE_SECONDS = 120       -- a parked, empty pack is full again in two minutes (a game's pace, not a charger's)
M.NM = 1 / (39.37 * 39.37)   -- one torque unit (kg u^2/s^2) in newton-metres
M.RAMP_KMH = 2               -- the assist fades over the last 2 km/h under the limit
M.DEFAULT_LIMIT_KMH = 25
M.DEFAULT_BATTERY_WH = 500

local RPM = 60 / (2 * math.pi)       -- rad/s -> rev/min
M.RPM = RPM

function M.KmhToUps(kmh) return kmh / (0.0254 * 3.6) end

-- Mechanical watts for a torque (kg u^2/s^2) turning at omega (rad/s).
function M.Watts(torque, omega) return torque * omega * M.NM end

--------------------------------------------------------------------------
-- THE SETTINGS, read where both realms can (the convars are server-created and
-- replicated). A missing convar is the default, so the model is usable in a bare
-- test and by a client that has not received them yet.
--------------------------------------------------------------------------
local function cvar(name, default)
    local cv = GetConVar and GetConVar(name)
    return cv and cv:GetFloat() or default
end

-- The assist cut-off, in units a second.
function M.LimitUps() return M.KmhToUps(max(cvar("bmx_ebike_limit", M.DEFAULT_LIMIT_KMH), 1)) end

-- The pack's capacity in Wh for a vehicle definition, or nil for "infinite"
-- (bmx_ebike_battery 0). A vehicle's own `battery` is a multiple of the setting
-- (the e-moto carries three e-bikes' worth).
function M.CapacityWh(def)
    local base = cvar("bmx_ebike_battery", M.DEFAULT_BATTERY_WH)
    if base <= 0 then return nil end
    local d = def and def.drive
    return base * ((d and d.battery) or 1)
end

--------------------------------------------------------------------------
-- WHAT KIND OF MOTOR A VEHICLE HAS. `drive.kind` is the whole truth, but the
-- HUD, the sound and the battery all ask the same three questions.
--------------------------------------------------------------------------
local function driveOf(thing)
    local def = thing
    if thing and thing.Bike then def = thing:Bike() end
    return def and def.drive, def
end

function M.IsAssist(thing) local d = driveOf(thing) return d ~= nil and d.kind == "assist" end
function M.IsEngine(thing) local d = driveOf(thing) return d ~= nil and d.kind == "engine" end

-- Does it carry a battery? An assist drive always does; a throttle drive when it
-- says `battery` (the test cart's plain one does not).
function M.HasBattery(thing)
    local d = driveOf(thing)
    return d ~= nil and (d.kind == "assist" or (d.kind == "throttle" and d.battery ~= nil))
end

-- Any of the three: a vehicle whose sound is a motor's and not a freewheel's.
function M.IsMotor(thing)
    local d = driveOf(thing)
    return d ~= nil and (d.kind == "assist" or d.kind == "engine"
        or (d.kind == "throttle" and d.battery ~= nil))
end

--------------------------------------------------------------------------
-- ASSIST (G14).
--
-- THE LEVEL is stored on the entity as level + 1, so that 0 (a networked int's
-- default) can mean "never set" and read as the registration's own level. Level 0
-- is a real setting, "motor off": a heavy bike with no help.
--------------------------------------------------------------------------
function M.Level(ent)
    local d = driveOf(ent)
    local raw = ent.GetAssist and ent:GetAssist() or 0
    if raw < 1 then return (d and d.assist) or 1 end
    return clamp(raw - 1, 0, M.MAX_LEVEL)
end

-- The fade the speed limit puts on the motor: whole under (limit - ramp), nothing
-- at the limit, linear between. A smooth edge, not a wall: a motor that cut out
-- dead at 25.0 would be a bump in the road every time the rider crossed it.
function M.AssistFade(speed, limitUps)
    local ramp = M.KmhToUps(M.RAMP_KMH)
    return clamp((limitUps - speed) / ramp, 0, 1)
end

-- The motor's torque at the wheel: LEVEL times the rider's effort, faded by the
-- limit, and nothing at all on an empty pack. `effort` is what the legs are asking
-- for at the wheel (crankTorque * throttle / gear ratio): the torque SENSOR of a
-- real mid-drive reads the push on the pedal, not the cadence, and a motor does not
-- spin out at 120 rpm the way a rider does, which is what lets the limit be the
-- thing that caps the speed.
function M.AssistTorque(level, effort, speed, limitUps, powered)
    if not powered or level <= 0 or effort <= 0 then return 0 end
    return level * effort * M.AssistFade(speed, limitUps)
end

-- TRACTION CONTROL: a motor's torque is cut as the front wheel comes up. Four times a
-- rider's push (level 3) through one rear tyre looped the plant's e-bike over backwards
-- in 0.6 s, and a real controller limits current to keep the front wheel down for the
-- same reason. The cut comes in between 6 and 16 degrees of nose-up; a rider who is
-- HOLDING a wheelie (weight back, RMB) has chosen it, and gets up to 22 to 38 degrees.
function M.WheelieCut(pitch, holding)
    local lo, hi = math.rad(6), math.rad(16)
    if holding then lo, hi = math.rad(22), math.rad(38) end
    return 1 - clamp(((pitch or 0) - lo) / (hi - lo), 0, 1)
end

--------------------------------------------------------------------------
-- THE BATTERY. State is one number, Wh, kept by the server on the vehicle's state
-- (st.battery); nil means "infinite" (bmx_ebike_battery 0).
--------------------------------------------------------------------------

-- The electrical watts a wheel torque costs (positive) or returns (negative:
-- regen). Efficiency works against you both ways.
function M.ElectricWatts(torque, omega)
    local p = M.Watts(torque, omega)
    if p >= 0 then return p / M.EFFICIENCY end
    return p * M.REGEN_EFF
end

-- Spend `watts` for `dt` seconds. Returns the new charge, clamped to [0, cap].
function M.Spend(wh, cap, watts, dt)
    return clamp(wh - watts * dt / 3600, 0, cap)
end

-- Parked: charging. A fixed fraction of the pack a second.
function M.Charge(wh, cap, dt)
    return min(cap, wh + cap / M.CHARGE_SECONDS * dt)
end

--------------------------------------------------------------------------
-- ENGINES (G15).
--
-- A drive of kind `engine`:
--
--   torque      peak engine torque, kg u^2/s^2 (what the curve's 1.0 is)
--   curve       { {rpm, fraction}, ... } rising in rpm: the torque curve
--   idle        rpm the idle governor holds
--   redline     rpm the rev limiter cuts at
--   inertia     the engine's, kg u^2: how fast it revs when nothing holds it
--   friction    engine braking, as a fraction of peak torque at redline
--   clutch      what the clutch can carry, as a multiple of peak torque
--   engageRpm   the centrifugal bite: below it the clutch passes nothing, so a
--               stopped bike in gear does not stall and does not creep
--   ratio       wheel revolutions per engine revolution when the vehicle has no
--               gears (the moped's one speed)
--   popGain, popTime   the clutch pop's pitch kick (below)
--   pedalStart  metres of pedalling before a moped's engine catches
--
-- The gears are the road bike's: `gears = { ratios = {...} }` on the vehicle,
-- shifted with [ and ] and the wheel, but a ratio here is WHEEL revolutions per
-- ENGINE revolution (the road bike's was wheel per crank), so the lowest gear is
-- the smallest number. sh_gears.lua does not care what the cog is.
--------------------------------------------------------------------------
BMX.DriveChecks = BMX.DriveChecks or {}

-- Piecewise-linear, clamped at both ends.
function M.CurveAt(curve, rpm)
    local n = #curve
    if rpm <= curve[1][1] then return curve[1][2] end
    if rpm >= curve[n][1] then return curve[n][2] end
    for i = 2, n do
        local a, b = curve[i - 1], curve[i]
        if rpm <= b[1] then
            local t = (rpm - a[1]) / (b[1] - a[1])
            return a[2] + (b[2] - a[2]) * t
        end
    end
    return curve[n][2]
end

-- The engine's torque at an rpm and throttle (0..1), kg u^2/s^2. Open throttle
-- follows the curve; a closed one is engine braking, a drag that grows with rpm;
-- the rev limiter takes the push away at the redline, and the idle governor holds
-- the engine up when the rider is not on the throttle.
function M.EngineTorque(d, rpm, throttle)
    local push = d.torque * M.CurveAt(d.curve, rpm) * throttle
    if rpm >= d.redline then push = 0 end
    local drag = d.torque * d.friction * clamp(rpm / d.redline, 0, 1.2) * (1 - throttle)
    local t = push - drag
    if rpm < d.idle then
        -- The governor: enough to climb back to idle, never more than the curve gives.
        t = max(t, d.torque * M.CurveAt(d.curve, d.idle) * clamp((d.idle - rpm) / 300 + 0.15, 0, 1))
    end
    return t
end

-- The clutch's grip: its capacity times how far the lever is out (1 = engaged),
-- times the centrifugal bite, which comes in between idle and engageRpm.
function M.ClutchCapacity(d, engage, rpm)
    local bite = clamp((rpm - d.idle * 1.15) / max(d.engageRpm - d.idle * 1.15, 1), 0, 1)
    return d.torque * d.clutch * engage * bite
end

-- A fresh engine state.
function M.NewEngine(d)
    return { omega = d.idle / RPM, lever = 0, slip = 0, locked = false, started = true,
             pop = 0, popStrength = 0, pedalled = 0 }
end

-- ONE SUBSTEP of the engine and its clutch.
--
--   s        the state { omega, locked, ... }
--   throttle 0..1
--   engage   the clutch: 1 engaged (the lever out), 0 pulled in
--   omegaIn  the input shaft's speed IF it were locked to the wheel: wheel omega
--            divided by the ratio, rad/s
--   iWheel   what the wheel weighs from the engine's side (optional), kg u^2
--   tyreCap  the most torque, engine side, the rear tyre can use (optional)
--
-- Returns `torque, flywheel`: the torque the engine side puts into the wheel (engine
-- side, so the wheel gets it divided by the ratio) and whether the engine is RIGIDLY
-- TIED to the wheel this step, in which case the wheel must carry the engine's
-- inertia (sv_wheel.lua `extraInertia`).
--
-- THREE STATES, because an engine and a wheel are not one kind of thing:
--
--   open      the clutch passes nothing (lever pulled, or below the centrifugal
--             bite): the engine revs on its own torque and the wheel is free.
--   locked    the clutch holds. Engine and wheel are one body: the engine speed IS
--             the wheel's (times the ratio) and the engine's torque is the torque on
--             that body, whose inertia is the wheel's plus the engine's reflected
--             through the gear (Ie / ratio^2, some 400 times the wheel's own). The
--             clutch is carrying the engine torque less what spinning the engine up
--             takes; past its capacity it breaks free.
--   slipping  the clutch passes exactly its capacity, in the direction of the slip,
--             and the engine keeps what is left. It locks again the moment the two
--             speeds meet.
--
-- WHY NOT ONE FORMULA. The first version solved the clutch like a tyre's grip, by
-- asking what torque would lock it this step and clamping that to the capacity. It
-- chattered: the wheel is so light next to the engine (reflected through a first
-- gear its inertia is 0.03 against the engine's 14) that a full capacity of torque
-- spins it past the engine's speed in one tick, the sign flips, and the clutch
-- swings between plus and minus its capacity for as long as the throttle is held.
-- Tying them into one body when they are locked is not an approximation of that
-- case, it is the case.
function M.EngineStep(d, s, throttle, engage, omegaIn, dt, iWheel, tyreCap)
    local rpm = s.omega * RPM
    local te = M.EngineTorque(d, rpm, throttle)
    local cap = M.ClutchCapacity(d, engage, rpm)
    local redOmega = d.redline / RPM
    local prevIn = s.prevIn or omegaIn
    s.prevIn = omegaIn

    if cap <= 0 then
        s.locked = false
        s.omega = max(s.omega + te / d.inertia * dt, 0)
        s.slip = s.omega - omegaIn
        return 0, false
    end

    local slip = s.omega - omegaIn
    if s.locked then
        -- What the clutch is carrying: the engine's torque less its own spin-up.
        local carried = te - d.inertia * (omegaIn - prevIn) / dt
        if abs(carried) > cap then
            s.locked = false
            s.breakSign = carried >= 0 and 1 or -1
        end
    elseif abs(slip) <= 0.03 * redOmega then
        s.locked = true
    end

    if s.locked then
        s.omega = omegaIn
        s.slip = 0
        return te, true
    end

    -- A SLIPPING CLUTCH NEVER PASSES MORE THAN IT TAKES TO MEET THE SPEEDS THIS STEP: the
    -- two sides close on each other at tq * (1/Ie + 1/Iw) a second, Iw being what the wheel
    -- weighs from the engine's side of the gearbox (the vehicle's mass on the tyre, through
    -- the ratio squared: `iWheel`, from the drive). Past it the wheel overshoots the engine
    -- in one tick and the torque chatters between plus and minus the capacity.
    local sgn = abs(slip) > 1e-6 and (slip > 0 and 1 or -1) or (s.breakSign or 1)
    local tq = cap
    if iWheel then tq = min(tq, abs(slip) / (dt * (1 / d.inertia + 1 / iWheel))) end
    -- ...nor more than the tyre can hold (`tyreCap`, engine side): a clutch that can pass
    -- twice what the rear tyre can use only spins the wheel past the engine, and the
    -- torque then reverses to drag it back, a tick at a time.
    if tyreCap then tq = min(tq, tyreCap) end
    s.omega = max(s.omega + (te - sgn * tq) / d.inertia * dt, 0)
    -- Crossed over in this step: the speeds have met, so they are one body again.
    if sgn * (s.omega - omegaIn) <= 0 then s.locked, s.omega = true, omegaIn end
    s.slip = s.omega - omegaIn
    return sgn * tq, false
end

-- The speed, u/s, a gear reaches at an engine rpm.
function M.SpeedAt(cfg, ratio, rpm)
    return rpm / RPM * ratio * cfg.Wheel.radius
end

-- Engine rpm at a speed in a gear.
function M.RpmAt(cfg, ratio, speed)
    return speed / cfg.Wheel.radius / ratio * RPM
end

-- The wheel torque a gear gives at full throttle at a speed.
local function wheelTorqueAt(d, cfg, ratio, speed)
    local rpm = M.RpmAt(cfg, ratio, speed)
    if rpm > d.redline then return 0 end
    return M.EngineTorque(d, rpm, 1) / ratio
end
M.WheelTorqueAt = wheelTorqueAt

-- WHERE TO SHIFT: the speed at which the next gear pulls harder than this one. From
-- the torque curve's peak rpm in this gear up to its redline, the first speed where
-- gear i+1's wheel torque is at least gear i's; the redline's speed if it never is.
-- What a rider should do, what an automatic would, and what the tests pin.
function M.ShiftPoint(d, cfg, ratios, i)
    local hi = ratios[i + 1]
    if not hi then return nil end
    local lo = ratios[i]
    local peakRpm, peak = d.idle, -1
    for _, p in ipairs(d.curve) do if p[2] > peak then peak, peakRpm = p[2], p[1] end end
    local v0 = M.SpeedAt(cfg, lo, peakRpm)
    local vEnd = M.SpeedAt(cfg, lo, d.redline)
    local v = v0
    while v < vEnd do
        if wheelTorqueAt(d, cfg, hi, v) >= wheelTorqueAt(d, cfg, lo, v) then return v end
        v = v + 1
    end
    return vEnd
end

-- The top speed of a powered vehicle's top gear at its redline (engine), or its
-- maxSpeed (throttle); nil for everything else. What the wind, the grind's pitch
-- and the tuck call "fast" (sh_gears.lua TopCeiling asks).
function M.TopSpeed(thing, cfg)
    local d = driveOf(thing)
    if not d then return nil end
    if d.kind == "throttle" and d.battery ~= nil then return d.maxSpeed end
    if d.kind == "engine" then
        local def = thing.Bike and thing:Bike() or thing
        local g = def.gears
        local ratio = g and g.ratios[#g.ratios] or d.ratio
        return M.SpeedAt(cfg, ratio, d.redline)
    end
    return nil
end

--------------------------------------------------------------------------
-- THE CHECKS the registry runs on a motor drive (sh_vehicles.lua asks
-- BMX.DriveChecks[kind]). The same bargain as every other field: a misspelt key
-- is an error at registration, not a vehicle that rides on a default.
--------------------------------------------------------------------------
local function isnum(v) return type(v) == "number" and v == v and v > 0 and v < math.huge end

local function checkCurve(c, bad)
    if type(c) ~= "table" or #c < 2 then
        bad[#bad + 1] = "drive.curve must be a list of at least two { rpm, fraction } points"
        return
    end
    local prev = -1
    for i, p in ipairs(c) do
        if type(p) ~= "table" or not isnum(p[1]) or type(p[2]) ~= "number" or p[2] < 0 or p[2] > 1.5 then
            bad[#bad + 1] = "drive.curve[" .. i .. "] must be { rpm, fraction 0..1.5 }"
        elseif p[1] <= prev then
            bad[#bad + 1] = "drive.curve must rise in rpm (point " .. i .. ")"
        else
            prev = p[1]
        end
    end
end

BMX.DriveChecks.engine = function(d, bad, def)
    if def and not def.gears and not isnum(d.ratio) then
        bad[#bad + 1] = "an engine with no gears needs drive.ratio (wheel revolutions per engine revolution)"
    end
    for _, k in ipairs({ "torque", "idle", "redline", "inertia", "friction", "clutch", "engageRpm" }) do
        if not isnum(d[k]) then bad[#bad + 1] = "an engine drive needs a positive " .. k end
    end
    checkCurve(d.curve, bad)
    if isnum(d.idle) and isnum(d.redline) and d.idle >= d.redline then
        bad[#bad + 1] = "drive.idle must be under drive.redline"
    end
    if isnum(d.engageRpm) and isnum(d.redline) and d.engageRpm >= d.redline then
        bad[#bad + 1] = "drive.engageRpm must be under drive.redline"
    end
    if type(d.curve) == "table" and #d.curve >= 2 and isnum(d.redline) and type(d.curve[#d.curve]) == "table"
        and isnum(d.curve[#d.curve][1]) and d.curve[#d.curve][1] < d.redline then
        bad[#bad + 1] = "drive.curve must reach the redline"
    end
end

BMX.DriveChecks.assist = function(d, bad)
    if d.assist ~= nil and not (type(d.assist) == "number" and d.assist >= 0 and d.assist <= M.MAX_LEVEL
        and d.assist == math.floor(d.assist)) then
        bad[#bad + 1] = "drive.assist must be a whole level, 0 to " .. M.MAX_LEVEL
    end
end

-- The kinds and their fields, added to the platform's table (sh_vehicles.lua).
-- `assist` is the pedal drive plus a motor, `engine` is the petrol one; `throttle`
-- takes the battery and the regen as optional extras.
local DK = BMX.DriveKinds
DK.assist = { assist = "number", battery = "number" }
DK.engine = {
    torque = "number", curve = "table", idle = "number", redline = "number",
    inertia = "number", friction = "number", clutch = "number", engageRpm = "number",
    ratio = "number", popGain = "number", popTime = "number", pedalStart = "number",
}
DK.throttle.regen = "number"
DK.throttle.battery = "number"
DK.throttle.motorRatio = "number"

-- The pose set a motorcycle's rider uses (cl_motor.lua fills in the pose).
BMX.RegisterPoseSet("moto", { label = "Moto: seated forward, feet on the pegs, hands on the bars" })

--------------------------------------------------------------------------
-- FMX TRICKS (G15). Held body poses, the registry's `pose` kind (sh_tricks.lua),
-- decoded for a motorcycle only (BMX.DecodePose's `moto` flag): the bike's own
-- Alt + W / S / A / D poses are a BMX rider's, and a motocross rider's are these.
-- A superman is the registry's existing one (Alt + W + S), which moto riders do
-- far better than BMX ones, so it is not registered twice. The backflip is the
-- flip every vehicle has.
--------------------------------------------------------------------------
local function inAir(st) return st.airMode and true or false end
BMX.RegisterTrick{ id = "heel_clicker", name = "Heel Clicker", kind = "pose", pose = "heelclicker",
    points = 14, input = "Alt + A / D in the air on a motorcycle (heels kicked together over the seat)",
    canStart = inAir }
BMX.RegisterTrick{ id = "cliffhanger", name = "Cliffhanger", kind = "pose", pose = "cliffhanger",
    points = 18, input = "Alt + S in the air on a motorcycle (feet up on the bars, sat right back)",
    canStart = inAir }

--------------------------------------------------------------------------
-- INPUT MAPS. Both are the bike's keys plus the shift keys the road bike has
-- (cl_gears.lua sees [ ] and the wheel, sv_gears.lua decides). On an e-bike the
-- shift is the ASSIST LEVEL; on a motorcycle it is the gear, and SHIFT is the clutch
-- lever where the bike's is the sprint (a motorcycle has no stamina to spend).
--------------------------------------------------------------------------
do
    local G, A = "ground", "air"
    local up   = { KEY_RBRACKET or 54, MOUSE_WHEEL_UP or 112 }
    local down = { KEY_LBRACKET or 53, MOUSE_WHEEL_DOWN or 113 }

    local ea = {}
    for name, a in pairs(BMX.InputMaps.bike.actions) do ea[name] = a end
    ea.shiftUp   = { buttons = up,   ctx = { G, A }, label = "Assist up (] or wheel up)" }
    ea.shiftDown = { buttons = down, ctx = { G, A }, label = "Assist down ([ or wheel down)" }
    BMX.RegisterInputMap{ id = "ebike", label = "E-bike", actions = ea }

    local ma = {}
    for name, a in pairs(BMX.InputMaps.bike.actions) do ma[name] = a end
    ma.sprint = nil
    ma.forward   = { key = IN_FORWARD, ctx = { G, A, "grind" }, label = "Throttle / nose down" }
    ma.clutch    = { key = IN_SPEED, ctx = { G }, label = "Clutch (hold; let go with the throttle open to pop a wheelie)" }
    ma.shiftUp   = { buttons = up,   ctx = { G, A }, label = "Shift up (] or wheel up)" }
    ma.shiftDown = { buttons = down, ctx = { G, A }, label = "Shift down ([ or wheel down)" }
    BMX.RegisterInputMap{ id = "moto", label = "Motorcycle", actions = ma }
end
