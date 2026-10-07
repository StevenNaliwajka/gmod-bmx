--[[--------------------------------------------------------------------------
    bmx/sh_predict.lua

    THE PURE PARTS OF G30 (feel under real ping): numbers in, numbers out, no
    entity, no convar, no clock, so the client, the server and the offline suite
    run the very same code on the very same inputs.

        1. THE LEAD    what the shared lean/steer controller (sh_lean.lua) says
                       the rider's own bike will have done by the time their
                       input has gone to the server and the answer has come back
                       and been interpolated: the client's DISPLAY prediction.
        2. THE BLEND   how the drawn value follows that target: an error under 4
                       units is snapped (the eye cannot see it, and easing it
                       only adds lag); a larger one eases over 100 ms.
        3. THE PROBE   the state machine behind bmx_latency_probe: from
                       timestamps of an input and of the first visible lean.
        4. LAG COMP    which tick (as a time ago) a usercmd's input is attributed
                       to, and whether the bike was on the ground then.

    PREDICTION IS DISPLAY-ONLY. Nothing here is ever written to the server's
    simulation by the client. The server runs the same bike it always ran; the
    client draws a body-roll offset and a steer angle that lead the networked
    ones and fade to them. A wrong prediction is therefore a wrong PICTURE for
    a moment, never a wrong bike: that is also why it can ship behind a switch
    and be judged by riders (bmx_predict, default 0).
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Predict = BMX.Predict or {}
local P = BMX.Predict

P.SNAP_UNITS  = 4        -- a display error under this is snapped, not eased
P.EASE_TIME   = 0.1      -- s: a larger one is eased out over this
P.MAX_HORIZON = 0.3      -- s: never lead by more than this, whatever the ping says
P.STEP        = 1 / 66   -- s: the lead's integration step (the server's tick)

--------------------------------------------------------------------------
-- 2. THE BLEND
--------------------------------------------------------------------------

-- Where a drawn value goes this frame. `arm` converts the angle error into
-- units (a roll of r radians moves the top of the bike about r * arm units; the
-- bike's centre of mass is about 30 up). Under SNAP_UNITS the target is taken
-- as it is. Over it the value closes on the target exponentially with the time
-- constant EASE_TIME / 3, which is 95% of the way after EASE_TIME and never
-- overshoots, whatever the frame time.
function P.Blend(shown, target, arm, dt)
    local err = target - shown
    if math.abs(err) * arm < P.SNAP_UNITS then return target end
    local k = 1 - math.exp(-dt * 3 / P.EASE_TIME)
    return shown + err * k
end

--------------------------------------------------------------------------
-- 1. THE LEAD
--------------------------------------------------------------------------

-- How far ahead of the networked state to look: the input's trip to the server
-- (ping / 2), the state's trip back (ping / 2) and the interpolation delay the
-- client draws behind. Capped, because a bad ping must not make a wild guess.
function P.Horizon(pingSeconds, interp)
    local h = (pingSeconds or 0) + (interp or 0)
    if h < 0 then h = 0 end
    return math.min(h, P.MAX_HORIZON)
end

-- A history is an ascending list of samples { t, target, lean }: the raw A/D
-- target, and the smoothed lean the client had after it. The sample in force at
-- `t` is the last one at or before it (the first, if t is earlier than all).
function P.SampleAt(history, t)
    local best = history[1]
    for i = 1, #history do
        local h = history[i]
        if h.t <= t then best = h else break end
    end
    return best
end

-- `s`:
--   roll, rollRate, steer   the NETWORKED (drawn) state now
--   speed                   u/s
--   now, horizon, history   the clock, how far to look ahead, the input record
--   B, maxLean...           the bike's Balance config, see sh_config.lua
--   mass, g, h, inertia     for gravity's roll torque (BMX.Lean.Topple)
--   wheelbase               the bicycle model's
--
-- It REPLAYS the rider's recorded input over the horizon, from the networked
-- state, through the shared controller: the lean smoothing, the PD with its
-- ceiling and authority, and the derived steer with its lag, step by step.
-- Replaying the record rather than holding the last input is what lets it cover
-- the part of the trip the server has not seen yet AND the part it has but the
-- picture has not caught up with.
--
-- THE PLANT IS THE CONTROLLER'S OWN STEADY STATE, not a copy of VPhysics:
-- roll'' = alpha, because in cornering the tyre's righting torque cancels
-- gravity's topple (sv_balance.lua, "formulation 1"). It misses the transient
-- of the real tyre; the blend and the networked state correct that, and the
-- error is bounded by the horizon, which is at most MAX_HORIZON.
function P.Lead(s)
    local L, horizon = BMX.Lean, s.horizon
    local roll, rate, steer = s.roll, s.rollRate or 0, s.steer or 0
    if horizon <= 0 then return roll, steer end

    local n  = math.max(1, math.ceil(horizon / P.STEP))
    local dt = horizon / n
    local t0 = s.now - horizon
    local first = P.SampleAt(s.history, t0)
    local lean = first and first.lean or 0
    local B = s.B

    for i = 1, n do
        local smp = P.SampleAt(s.history, t0 + (i - 1) * dt)
        local target = smp and smp.target or 0
        lean = L.StepLean(lean, target, dt)

        local topple = L.Topple(s.mass, s.g, s.h, roll, s.inertia)
        local authority = BMX.Ramp(s.speed, B.fadeInLow, B.fadeInHigh)
        local alpha = L.RollAlpha(topple, B.leanKp, B.leanKd, lean * B.maxLean - roll,
            rate, B.maxAssistAccel, authority)
        rate = rate + alpha * dt
        roll = roll + rate * dt

        local derived = L.DerivedSteer(s.wheelbase, s.g, roll, s.speed)
        local want = L.SteerTarget(derived, lean, s.speed, B.walkSpeed, B.maxSteer)
        steer = L.SteerLag(steer, want, B.steerRate, dt)
    end
    return roll, steer
end

--------------------------------------------------------------------------
-- 3. THE LATENCY PROBE (bmx_latency_probe, cl_predict.lua)
--
-- WHAT IT MEASURES: the time from the rider's key going down to the bike on
-- their screen visibly leaning. Both ends are timestamps taken on the one
-- client clock (SysTime), so there is no clock sync to get wrong and it holds
-- under net_fakelag, which delays the packets but not the client's clock.
--
-- THE TRIAL: it waits for the lean input to be ZERO and the drawn roll to be
-- still (a baseline), stamps the first command whose side axis is nonzero, then
-- watches the drawn roll for the first frame that has moved more than
-- `threshold` radians from the baseline in the direction pressed. That is the
-- "visible lean". It then waits for the input to be released and the roll to
-- settle before the next trial, so one trial's tail is never the next's start.
--------------------------------------------------------------------------
P.PROBE_THRESHOLD = math.rad(1.5)   -- a lean you can see on a bike
P.PROBE_QUIET     = 0.05            -- rad/s: "still"
P.PROBE_TIMEOUT   = 2.0             -- s: a trial with no lean by then is dropped

function P.ProbeNew(trials, threshold)
    return { want = trials or 5, threshold = threshold or P.PROBE_THRESHOLD,
        state = "idle", results = {}, dropped = 0 }
end

-- One observation: the clock, the side input (-1..1), the drawn roll (rad).
-- Returns the latency in seconds when a trial just completed, else nil.
function P.ProbeFeed(pr, t, side, roll)
    local done
    if pr.state == "idle" then
        -- Need a still bike and no key before a press means anything.
        local still = pr.lastRoll == nil or pr.lastT == nil
            or math.abs(roll - pr.lastRoll) / math.max(t - pr.lastT, 1e-4) < P.PROBE_QUIET
        if side == 0 and still then pr.state = "armed" end
    elseif pr.state == "armed" then
        if side ~= 0 then
            pr.state, pr.t0, pr.dir, pr.base = "waiting", t, side > 0 and 1 or -1, roll
        end
    elseif pr.state == "waiting" then
        if (roll - pr.base) * pr.dir >= pr.threshold then
            done = t - pr.t0
            pr.results[#pr.results + 1] = done
            pr.state = "release"
        elseif t - pr.t0 > P.PROBE_TIMEOUT then
            pr.dropped = pr.dropped + 1
            pr.state = "release"
        end
    elseif pr.state == "release" then
        if side == 0 then pr.state = "idle" end
    end
    pr.lastT, pr.lastRoll = t, roll
    if #pr.results >= pr.want then pr.state = "finished" end
    return done
end

function P.ProbeFinished(pr) return pr.state == "finished" end

-- min / median / max of a list of seconds, in milliseconds.
function P.Summary(results)
    local n = #results
    if n == 0 then return nil end
    local s = {}
    for i = 1, n do s[i] = results[i] end
    table.sort(s)
    local med = (n % 2 == 1) and s[(n + 1) / 2] or (s[n / 2] + s[n / 2 + 1]) / 2
    return { n = n, min = s[1] * 1000, median = med * 1000, max = s[n] * 1000 }
end

--------------------------------------------------------------------------
-- 4. LAG COMPENSATION: WHICH TICK AN INPUT COUNTS AT
--
-- THE PROBLEM. A rider presses SPACE at the lip of a ramp. They saw the bike on
-- the ground when they pressed; by the time the command reaches the server the
-- bike has rolled on and left the lip, so the server sees a hop released in the
-- air and drops it. The press was on time; the answer arrived late.
--
-- THE RULE (the engine's own for hitscan, applied to a trick): a usercmd is
-- stamped with the tick the client had when it made it (cmd:TickCount(), the
-- latest server tick the client had received), and the client draws
-- `lerp` seconds behind that. The world the rider acted on was
-- therefore at (cmdTick - lerpTicks), and the input's AGE is how long ago that
-- was on the server now.
--
-- WHAT IT MAY CHANGE: only the time an input is attributed to, nothing else. A
-- takeoff decision that asks "was the bike on the ground when this was pressed"
-- asks it of the bike's recorded state at (now - age), and is otherwise the
-- decision it always made. The age is clamped to `maxAge` and to what the
-- player's own ping can explain (+ lerp + two ticks), so a client cannot claim
-- an old tick to buy a hop a second after leaving the ground.
--------------------------------------------------------------------------
function P.CmdAge(serverTick, cmdTick, lerp, interval, maxAge, ping)
    if not cmdTick or cmdTick <= 0 then return 0 end      -- a bot, or no stamp
    local seen = cmdTick - lerp / interval
    local age = (serverTick - seen) * interval
    local cap = math.min(maxAge, (ping or 0) + lerp + 2 * interval)
    if age < 0 then return 0 end
    if age > cap then return cap end
    return age
end

-- A bike's grounded history is an ascending list of { t, grounded }. Was it on
-- the ground at `t`? The sample in force then: the last at or before it, or the
-- oldest we have if t is older than all of them.
function P.GroundedAt(history, t)
    local best = history[1]
    for i = 1, #history do
        local h = history[i]
        if h.t <= t then best = h else break end
    end
    return best ~= nil and best.grounded == true
end
