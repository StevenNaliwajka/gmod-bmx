--[[--------------------------------------------------------------------------
    bmx/sv_unicycle.lua

    THE UNICYCLE (G13): one wheel, no fork, a fixed gear, and nothing to hold it up
    but the person on it.

    WHY IT IS A BALANCE MODE AND NOT A BIKE WITH ONE WHEEL. The single-track mode
    (sv_balance.lua) is built on one fact: a bike turns because it leans, and the
    front wheel's angle is DERIVED from the lean that resulted. A unicycle has no
    front wheel to derive and no wheelbase to turn about, and on top of that it is
    unstable on a second axis the bike is not: a bike is held up fore and aft by its
    second wheel, a unicycle by nothing. It is an inverted pendulum on TWO axes,
    and a rider keeps it up by moving the wheel under the weight:

        fore and aft   W / S: pedalling. The fixed drive's torque at the tyre pitches
                       the body (drive at the patch, below the mass centre, is a
                       wheelie's physics), so a rider who is falling forward pedals
                       forward and the body comes back. This is REAL, it is the same
                       tyre model and the same drive the other bikes run; the balance
                       mode does not fake it.
        side to side   A / D: the lean, a target roll. A real rider twists to put the
                       wheel under the weight; the lean is what that comes to.
        round          the mouse (yaw): twist the whole thing round on the spot, and
                       the lean turns it as it rolls (a coordinated turn, g tan(roll) / v).

    THE ASSIST (bmx_unicycle_assist, default 0.6). A unicycle as hard as a real one is
    not a game anybody plays twice, and the goal says as much: "the unicycle may be no
    fun if it's too realistic". Each axis is a spring and a damper pulling the body to
    the rider's target (the lean they ask for; the pedalling's forward lean), plus the
    feed-forward that cancels gravity's toppling, and the assist is the share of THAT
    feed-forward that is switched on:

        alpha = -assist * topple  +  Kp (target - angle)  -  Kd (rate)

    (The single-track mode scales all of it by one number; here the spring is the
    rider's own legs and is always there, which is also what lets A / D do anything at
    assist 0. Four formulations of the feed-forward were tried on the bike and the
    note in sv_balance.lua says why this one: it does not depend on what it controls.)

    THE SPRING IS A FRACTION OF THE TOPPLING'S GRADIENT, not a number. Gravity's pull
    on a tilted body is G = m*g*h/I per radian (roll ~110-170 rad/s^2 per rad, pitch
    ~140-220, depending on the inertia the engine measures; a bike's is 166), and a
    spring of `hold * G` leaves a net stiffness of (hold - (1 - assist)) * G. So the
    break-even assist is 1 - hold, WHATEVER the inertia is: with hold 0.7 the vehicle
    holds itself above assist 0.3 and needs the rider below it. 0.6 is the default: it
    stands, with a soft wobble that A / D and W / S take out; 0.2 falls over the moment
    the rider lets go of the keys; 0 is the real thing; 1.0 is a vehicle that cannot
    fall (the same as the stand does for a parked bike). The softer it is held, the
    further a given A / D leans it: the steady lean is hold * target / (hold - (1 - assist)).
    The damper is critical for the net stiffness at full assist (zeta).

    FALLING. The assist is whole up to fallFrom of lean, fades out to nothing at
    fallTo, and past that it is physics: the vehicle goes over, and the ordinary tip
    rule (sv_physics.lua 6a, with this vehicle's own tipRoll / tipPitch) throws the
    rider as a ragdoll. A rider who lands a hop gets the whole assist for
    Crash.recoverTime, as a bike does.

    PARKED. With nobody aboard and the stand down (a spawned vehicle, one the rider
    stepped off at a standstill) the unicycle is held upright by the stand's own
    controller, as a parked bike is, and a shove past its ceiling knocks it over.
    One that was let go of at speed has no stand and falls, as it should.

    THE TWO TRICKS (sh_tricks.lua, ticking here): IDLE, rocking in place (the
    pedalling reversing a few times a couple of seconds at a standstill, upright),
    paid a second at a time, and a HOP, paid when it leaves the ground.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Unicycle = BMX.Unicycle or {}
local U = BMX.Unicycle

local abs, min, max = math.abs, math.min, math.max

local FLAGS = bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED)
local cvAssist = CreateConVar("bmx_unicycle_assist", "0.6", FLAGS,
    "BMX: how much of the unicycle's balance is done for the rider, 0 (none: as hard as the real thing) to 1 (it cannot fall).")

-- The assist, clamped: a console that sets it to 7 gets 1.
function BMX.UnicycleAssist()
    return BMX.Clamp(cvAssist:GetFloat(), 0, 1)
end

local function gravity()
    local g = physenv.GetGravity()
    return g and g:Length() or 600
end

-- Is this controller state a unicycle's? (The tricks' canStart.)
function U.IsUnicycle(st)
    local d = st and st.def
    return d ~= nil and d.balance == "unicycle"
end

--------------------------------------------------------------------------
-- THE BALANCE MODE.
--------------------------------------------------------------------------
-- The assist's say over one axis: how much of it there is at this angle (whole up
-- to fallFrom, none from fallTo on), a function of the worse of roll and pitch.
local function standing(U_, roll, pitch)
    local worst = max(abs(roll), abs(pitch))
    return 1 - BMX.Ramp(worst, U_.fallFrom, U_.fallTo)
end
U.Standing = standing

-- The rider's twist this tick, a yaw RATE they ask for, rad/s: the mouse's movement
-- (written to inp.mouseX by the usercmd hook below, or by a test) scaled and clamped,
-- and smoothed so a flick is not a snap. Right is positive on the mouse and a right
-- turn DEcreases yaw in Source, hence the sign.
local function twist(U_, inp, dt)
    local want = BMX.Clamp((inp.mouseX or 0) * U_.twistRate, -U_.twistMax, U_.twistMax)
    inp.twist = (inp.twist or 0) + (want - (inp.twist or 0)) * min(1, 12 * dt)
    return -inp.twist
end

local function ground(ent, phys, C, dt, inp, st, wheels, groundNormal, speed)
    local UC = C.Unicycle
    local roll  = select(1, BMX.Attitude(ent, BMX.BalanceUp(ent, C, groundNormal)))
    local pitch = select(2, BMX.Attitude(ent, groundNormal))
    st.rollRate  = st.rollRate  + ((roll  - st.lastRoll)  / dt - st.rollRate)  * min(1, 18 * dt)
    st.pitchRate = st.pitchRate + ((pitch - st.lastPitch) / dt - st.pitchRate) * min(1, 18 * dt)
    st.lastRoll, st.lastPitch = roll, pitch
    st.roll, st.pitch = roll, pitch
    st.onStand = false

    local ridden = IsValid(ent:GetDriver())
    local g = gravity()
    local h = C.Chassis.massCenterExpected.z + C.Wheel.radius
    local topR = (C.Chassis.mass * g * h * math.sin(roll))  / BMX.IRoll(ent)
    local topP = (C.Chassis.mass * g * h * math.sin(pitch)) / BMX.IPitch(ent)

    local alphaR, alphaP = 0, 0
    if ridden then
        local assist = BMX.UnicycleAssist()
        -- Just landed: the whole assist, so a hop that comes down crooked is caught.
        if (st.recoverUntil or 0) > CurTime() then assist = 1 end
        -- ...and none of it once it is going over (see `standing`).
        local hold = standing(UC, roll, pitch)

        local targetRoll  = inp.lean * UC.maxLean
        -- Pedalling forward asks to lean forward a little: the spring would otherwise
        -- fight the acceleration the rider is paying for.
        local targetPitch = -(inp.throttle - inp.brakeRear) * UC.accelLean

        -- The gradients, from the inertia the engine measured (see the header).
        local gR = C.Chassis.mass * g * h / BMX.IRoll(ent)
        gP = C.Chassis.mass * g * h / BMX.IPitch(ent)
        local kpR, kpP = UC.holdRoll * gR, UC.holdPitch * gP
        local kdR, kdP = 2 * UC.zeta * math.sqrt(kpR), 2 * UC.zeta * math.sqrt(kpP)
        local aR = -assist * topR + kpR * (targetRoll  - roll)  - kdR * st.rollRate
        local aP = -assist * topP + kpP * (targetPitch - pitch) - kdP * st.pitchRate
        alphaR = BMX.Clamp(aR, -UC.maxAccel, UC.maxAccel) * hold
        alphaP = BMX.Clamp(aP, -UC.maxAccel, UC.maxAccel) * hold
        st.leanAuthority, st.leanError = assist * hold, targetRoll - roll
    elseif ent:GetStandDown() and max(abs(roll), abs(pitch)) < C.Stand.maxRoll then
        -- PARKED: the stand's controller on both axes, with the stand's ceiling.
        local S, B = C.Stand, C.Balance
        alphaR = BMX.Clamp(-topR + S.kp * (0 - roll)  - S.kd * st.rollRate,  -B.maxAssistAccel, B.maxAssistAccel)
        alphaP = BMX.Clamp(-topP + S.kp * (0 - pitch) - S.kd * st.pitchRate, -B.maxAssistAccel, B.maxAssistAccel)
        st.onStand = true
        st.leanAuthority, st.leanError = 0, 0
    else
        st.leanAuthority, st.leanError = 0, 0
    end

    st.toppleAccel = topR
    if alphaR ~= 0 then
        BMX.ApplyTorque(phys, ent, ent:GetForward(), BMX.TorqueFor(BMX.IRoll(ent), alphaR), dt)
    end
    if alphaP ~= 0 then
        BMX.ApplyTorque(phys, ent, ent:GetRight(), BMX.TorqueFor(BMX.IPitch(ent), alphaP), dt)
    end

    ------------------------------------------------------------------
    -- ROUND. The yaw rate the rider is asking for: the lean's coordinated turn
    -- (fading in with speed: at a standstill a lean does not turn anything) plus the
    -- mouse's twist. Applied as a yaw torque; the tyre's side force then takes the
    -- velocity round after the heading, which is all a turn is.
    ------------------------------------------------------------------
    if ridden and st.grounded then
        local up = ent:GetUp()
        local fade = BMX.Ramp(speed, 20, 80)
        local lean = -UC.turnGain * g * math.tan(BMX.Clamp(roll, -0.6, 0.6)) / max(speed, 60) * fade
        local want = BMX.Clamp(lean + twist(UC, inp, dt), -UC.twistMax, UC.twistMax)
        local wYaw = st.angVel:Dot(up)
        BMX.ApplyTorque(phys, ent, up, BMX.TorqueFor(BMX.IYaw(ent), UC.yawKp * 3 * (want - wYaw)), dt)
    end
end

BMX.BalanceModes.unicycle = {
    Ground = ground,
    Pitch  = function() end,
}

--------------------------------------------------------------------------
-- THE PEDALS. A unicycle has no brake: S pedals BACKWARDS, at any speed, which is
-- how it is slowed and how it is reversed. The fixed drive (sv_fixie.lua) asks for
-- this when its registration says `reverse = true`, instead of the fixie's skid
-- stop, and drops the rear brake for it.
--
-- Forward is the pedal drive exactly as it is (stamina, sprint, the climbing push); the
-- backward torque is the mirror of its falling curve, so the legs run out of speed
-- backwards the way they do forwards and there is no instant stop.
--------------------------------------------------------------------------
function U.PedalTorque(ent, cfg, dt, inp, st, wheel, vdef)
    local fwdOnly = setmetatable({ throttle = inp.throttle, brakeRear = 0 }, { __index = inp })
    local tau = BMX.Drives.pedal(ent, cfg, dt, fwdOnly, st, wheel, vdef) or 0
    if inp.brakeRear > 0 then
        local D = cfg.Drive
        local ratio = BMX.GearRatio(ent, cfg)
        local back = BMX.Clamp(-(wheel.omega / ratio) / D.maxCadence, 0, 1)
        tau = tau - D.crankTorque * (1 - back) * inp.brakeRear / ratio
    end
    return tau
end

--------------------------------------------------------------------------
-- THE MOUSE. The usercmd carries the mouse's movement a tick at a time; the twist
-- is read from it for a rider of a unicycle and nobody else (a bike's rider
-- steers with A / D and has no use for it). A scripted rider writes inp.mouseX
-- itself, like the rest of the input, and is skipped, as sv_input.lua skips it.
--------------------------------------------------------------------------
hook.Add("StartCommand", "BMX.UnicycleTwist", function(ply, cmd)
    local bike = ply.BMXBike
    if not IsValid(bike) or bike:GetDriver() ~= ply or ply.BMXScripted then return end
    local def = bike.Bike and bike:Bike()
    if not def or def.balance ~= "unicycle" then return end
    local inp = bike.input
    if inp and cmd.GetMouseX then inp.mouseX = cmd:GetMouseX() or 0 end
end)

--------------------------------------------------------------------------
-- THE TWO TRICKS. Both are PAID AS THEY HAPPEN, straight to the vehicle
-- (ent:AwardTricks), not banked for a landing: idle has no landing, and a hop's
-- is the vehicle's own.
--
--   idle   rocking in place: the pedalling reversing idleReversals times inside
--          idleWindow seconds, at under idleSpeed, upright and on the ground. Paid a
--          second at a time while it goes on.
--   hop    the hop (SPACE), paid when it leaves the ground, once per hop: the hop's own
--          clock (ent.hopReady) is what moves.
--------------------------------------------------------------------------
local function clocks(st)
    st.uniClock = st.uniClock or { revs = {}, dir = 0, idle = 0, idlePaid = 0 }
    return st.uniClock
end

function U.Rocking(ent, st, inp)
    local UC = ent:Cfg().Unicycle
    local k = clocks(st)
    local now = CurTime()
    local d = inp.throttle - inp.brakeRear
    local dir = d > 0.15 and 1 or (d < -0.15 and -1 or 0)
    if dir ~= 0 and dir ~= k.dir then
        if k.dir ~= 0 then k.revs[#k.revs + 1] = now end
        k.dir = dir
    end
    local keep = {}
    for _, t in ipairs(k.revs) do if now - t <= UC.idleWindow then keep[#keep + 1] = t end end
    k.revs = keep
    return #keep >= UC.idleReversals and (st.speed or 0) < UC.idleSpeed and st.grounded
        and not st.airMode and abs(st.roll or 0) < math.rad(14) and abs(st.pitch or 0) < math.rad(14)
end

function U.Tick(which, ent, st, inp, dt)
    local UC = ent:Cfg().Unicycle
    local k = clocks(st)
    if which == "idle" then
        if not U.Rocking(ent, st, inp) then
            k.idle, k.idlePaid = 0, 0
            return
        end
        k.idle = k.idle + dt
        if k.idle >= k.idlePaid + 1 then
            k.idlePaid = k.idlePaid + 1
            local trick = BMX.Tricks.uni_idle
            if ent.AwardTricks then
                ent:AwardTricks({ { name = trick.name, count = 1, points = UC.idlePoints } })
            end
        end
    else
        -- The hop code stamps ent.hopReady the moment it pops. The first tick only
        -- learns the value, so a vehicle that hopped before this ran pays nothing.
        local seen = k.hopSeen
        k.hopSeen = ent.hopReady or 0
        if seen ~= nil and (ent.hopReady or 0) ~= seen and ent.hopReady > 0 then
            local trick = BMX.Tricks.uni_hop
            if ent.AwardTricks then
                ent:AwardTricks({ { name = trick.name, count = 1, points = UC.hopPoints } })
            end
        end
    end
end
