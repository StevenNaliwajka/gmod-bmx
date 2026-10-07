--[[--------------------------------------------------------------------------
    bmx/sv_fixie.lua

    THE FIXED GEAR (G10): the one bike where the cranks and the rear wheel are the
    same thing. A freewheel lets the legs stop while the wheel goes on; a fixed
    cog does not, so a fixie's pedals turn whenever it moves, in either direction,
    and the legs are a heavy flywheel the wheel has to turn too. That is what
    this file models, and everything a fixie does that a BMX does not follows from
    it: coasting turns the legs (and slows the bike a little, the legs being dragged
    round), S locks the legs and the tyre skids, S at a standstill pedals
    backwards and rolls the bike back (fakie), and a rider who rocks the cranks can
    hold the bike still (a trackstand).

    THE DRIVE (`drive = { kind = "fixed" }`, BMX.Drives.fixed). The rider's push is
    exactly what the pedal drive works out -- the stamina, the sprint, the climbing
    help, the paddle backwards -- so none of that is written twice. What is new is
    that the push goes onto the CRANKS, a body of its own with an inertia and a drag,
    and the cranks reach the wheel through a stiff spring and damper:

        crank --- spring/damper (k, c) --- rear wheel

    All of it is in WHEEL SPACE (the crank's angle times the gear ratio), which makes
    the spring a plain torsional one between two spinning things and the ratio only a
    scale on the angle and on the inertia. A real chain and cog are not infinitely
    stiff and do not need to be here: STIFF is the point, because a spring that gives
    a little is what lets a hard skid break the tyre's grip instead of the legs
    refusing to stop -- the wheel is braked, the legs are dragged by the spring, and
    the tyre skids when the brake asks for more than it has.

    BACKWARD EULER. The spring is so much stiffer than anything it is attached to
    that a forward step would ring itself apart at 66 ticks a second (its natural
    frequency is over 150 rad/s). The relative velocity is solved implicitly instead,
    which is stable for any k and costs one division.

    THE CRANK ANGLE AS DRAWN is the wheel's over the ratio (cl_init.lua), which is the
    spring's rest state: the twist is a few hundredths of a radian, never visible.
    What the server keeps (`st.crankA`, `st.crankW`) is the crank's own state, for the
    twist, for the legs' inertia, and for a test that checks the two stay together.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Fixie = BMX.Fixie or {}
local Fx = BMX.Fixie

local abs, max, min = math.abs, math.max, math.min

-- THE NUMBERS, in wheel space (kg*units^2 and per second).
--   legInertia   the legs and cranks' inertia, as a multiple of the wheel's own:
--                a rider's legs are three or four wheels' worth of flywheel
--   legDrag      the legs' passive drag, torque per rad/s: what makes a coasting
--                fixie slow down a little instead of rolling free. Sized for about
--                6,000 of wheel torque at 35 rad/s (a 350 u/s coast), a fifteenth of
--                the brake: a nuisance you feel, not a brake you use
--   stiffness    the spring: torque per rad of twist. 4e6 is a twist of 0.02 rad at
--                80,000, a skid's worth
--   damping      the damper beside it, a little under critical for the pair
Fx.legInertia = 3
Fx.legDrag    = 170
Fx.stiffness  = 4e6
Fx.damping    = 14000

-- The legs have been left alone (nobody was riding, or the vehicle was not on this
-- drive) for longer than this and are put back on the wheel rather than carried
-- over: a rider who mounts a fixie that rolled on without them must not find the
-- cranks a quarter turn out and the spring wound up.
local RESEED = 0.25

BMX.Drives = BMX.Drives or {}
BMX.Drives.fixed = function(ent, cfg, dt, inp, st, wheel, vdef)
    -- No drive wheel, nothing to be fixed to. (A registration with a fixed drive
    -- needs one; this is for a state built by hand.)
    if not wheel then return 0 end

    -- THE RIDER'S PUSH AT THE WHEEL, as the pedal drive makes it: torque, with the
    -- stamina, the sprint, the climb and the paddle backwards all in it.
    local tau = BMX.Drives.pedal(ent, cfg, dt, inp, st, wheel, vdef) or 0

    local WC = wheel:WheelConfig(cfg)
    local Iw = WC.inertia
    local Ie = Iw * Fx.legInertia
    local ratio = BMX.GearRatio(ent, cfg)
    local now = CurTime()

    -- The legs' state is the wheel's until they have been ridden for a moment.
    if not st.crankA or (now - (st.crankAt or -1e9)) > RESEED then
        st.crankA = wheel.spinAngle
        st.crankW = wheel.omega
    end
    st.crankAt = now

    local k, c = Fx.stiffness, Fx.damping
    local x = st.crankA - wheel.spinAngle           -- the twist
    local u = st.crankW - wheel.omega               -- and how fast it is changing
    local Tc = tau - Fx.legDrag * st.crankW         -- what is on the legs but the spring
    local inv = 1 / Ie + 1 / Iw

    -- The relative velocity at the END of the step, the spring and the damper
    -- evaluated there (backward Euler).
    local un = (u + dt * Tc / Ie - dt * inv * k * x) / (1 + dt * inv * (k * dt + c))
    local ts = k * (x + dt * un) + c * un           -- the torque the spring puts on the WHEEL

    -- And the legs take the reaction.
    st.crankW = st.crankW + dt * (Tc - ts) / Ie
    st.crankA = st.crankA + st.crankW * dt

    -- THE LEGS' SPEED, for the HUD: the crank's own, in rad/s at the crank.
    st.cadence = st.crankW / ratio

    -- THE REAR BRAKE: kept (a skid stop is the rear brake, and the spring's torque
    -- on the wheel is negative whenever the bike is slowing) except in the one
    -- place S means "pedal backwards", at a standstill (the pedal drive's own
    -- condition), where it is dropped so the bike can roll back.
    local paddling = inp.brakeRear > 0 and st.speed < 40 and wheel.omega < 1
    return ts, not paddling
end

-- The crank's angle in real radians (of the crank, not the wheel), and what it
-- should be if it were locked: tests and the HUD ask for both.
function Fx.CrankAngle(st, ratio) return (st.crankA or 0) / ratio end
function Fx.LockedAngle(wheel, ratio) return wheel.spinAngle / ratio end

--------------------------------------------------------------------------
-- THE FRONT BRAKE. A fixie's brake is its legs, and most have no other. LMB does
-- nothing on one (the `bike_rearonly` input map, sh_vehicles.lua) unless the
-- server has bmx_fixie_frontbrake 1, for the track bike that was given a brake to
-- be legal on the road.
--------------------------------------------------------------------------
local FLAGS = bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED)
local cvFront = CreateConVar("bmx_fixie_frontbrake", "0", FLAGS,
    "BMX: 1 = LMB brakes the front wheel of a fixed gear as well (0 = the legs are the only brake).")

-- May this bike's front brake be used on the ground when its map has none? Only a
-- fixed gear, and only on the server's say.
function BMX.FrontBrakeConVar(bike)
    local def = bike and bike.Bike and bike:Bike()
    return def ~= nil and def.drive.kind == "fixed" and cvFront:GetBool()
end

--------------------------------------------------------------------------
-- THE TWO TRICKS only a fixie has (registered in sh_tricks.lua, ticking here).
--
--   Fakie        riding BACKWARDS under your own power: S at a standstill pedals
--                the cranks back and the bike rolls back. Paid per second of it.
--   Trackstand   standing still with A or D held and nothing else: the rider
--                rocking the cranks to hold the bike up. Paid per second of it,
--                after a second, so a bike that has merely stopped is not one.
--
-- Both are PAID AS THEY RUN, a full second at a time, straight to the bike
-- (ent:AwardTricks), not banked for a landing: neither has one.
--------------------------------------------------------------------------
Fx.FAKIE_MIN_SPEED = 12      -- u/s backwards before it counts as riding
Fx.TRACK_MAX_SPEED = 10      -- u/s: standing still
Fx.TRACK_LEAN_MIN  = 0.3     -- how much A or D, of full, is "rocking the cranks"
Fx.TRACK_FIRST     = 1.0     -- seconds before the first pays

local function fixed(st)
    local d = st.def
    return d ~= nil and d.drive ~= nil and d.drive.kind == "fixed"
end
Fx.IsFixed = fixed

-- Is this the moment a trick's clock runs? `which` is "fakie" or "trackstand".
function Fx.Running(which, st, inp)
    if not fixed(st) or not st.grounded or st.airMode or st.grind then return false end
    if which == "fakie" then
        return (st.fwdSpeed or 0) < -Fx.FAKIE_MIN_SPEED and inp.brakeRear > 0.5
    end
    return (st.speed or 0) < Fx.TRACK_MAX_SPEED
        and abs(inp.leanTarget or 0) >= Fx.TRACK_LEAN_MIN
        and inp.throttle == 0 and inp.brakeRear == 0 and (inp.brakeFront or 0) == 0
end

-- One substep of a trick's clock. Pays a whole second at a time.
function Fx.Tick(which, ent, st, inp, dt)
    local clocks = st.fixieClock
    if not clocks then clocks = {} st.fixieClock = clocks end
    if not Fx.Running(which, st, inp) then
        clocks[which], clocks[which .. "Paid"] = nil, nil
        return
    end
    local t = (clocks[which] or 0) + dt
    local trick = BMX.Tricks[which]
    local first = (which == "trackstand") and Fx.TRACK_FIRST or 1
    -- Whole seconds banked so far (past the first), so a long one pays steadily.
    local paid = clocks[which .. "Paid"] or 0
    if t >= first + paid then
        clocks[which .. "Paid"] = paid + 1
        if ent.AwardTricks then
            ent:AwardTricks({ { name = trick.name, count = 1, points = trick.points } })
        end
    end
    clocks[which] = t
    -- A clock that stopped starts again from nothing, paid seconds and all.
end
