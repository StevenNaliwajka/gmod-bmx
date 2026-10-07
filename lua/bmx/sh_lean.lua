--[[--------------------------------------------------------------------------
    bmx/sh_lean.lua

    THE LEAN / STEER CONTROLLER'S ARITHMETIC, with nothing else attached (G30).

    WHY THIS FILE EXISTS. Client-side prediction of the rider's own bike (G30,
    cl_predict.lua) has to run the SAME controller the server runs, or the
    prediction is a second, drifting opinion about how the bike leans and the
    rider sees it as rubber-banding. The controller lived inside sv_balance.lua
    and sv_input.lua, welded to entities, physics objects and torque. What a
    client can share is the arithmetic: numbers in, numbers out, no entity. That
    is all that moved, in the same order, with the same operators.

    SERVER BEHAVIOUR IS UNCHANGED, BIT FOR BIT. Floating point is not
    associative, so each expression below is the one that was in sv_balance.lua,
    with the same grouping; sv_balance.lua and sv_input.lua now call it.
    tests/test_predict_server_unchanged.lua holds a trajectory recorded before
    the move to %.17g and requires equality, and keeps the old expressions
    verbatim to compare against. Do NOT "tidy" a formula here without re-running
    it: a reordered multiply is a different bike.

    What did NOT move: gravity's torque lever arm and inertia (they need the
    entity), the stand, and anything that applies a torque. Those stay in
    sv_balance.lua and arrive here as plain numbers.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Lean = BMX.Lean or {}
local L = BMX.Lean

local min, max = math.min, math.max

-- INPUT SMOOTHING (was sv_input.lua). CALM, not crisp: returning to centre used
-- to be faster (6.5) and on a keyboard, where A and D are all or nothing, every
-- release was a snap the bike overshot. Both are a glide now.
L.LEAN_RATE   = 3.0    -- units of target per second
L.LEAN_RETURN = 3.0    -- the same on the way back
L.PITCH_RATE  = 6.0

function L.Approach(cur, target, rate, dt)
    local d = target - cur
    local step = rate * dt
    if math.abs(d) <= step then return target end
    return cur + step * (d > 0 and 1 or -1)
end

-- The smoothed lean one step on from `lean`, toward the raw A/D target.
function L.StepLean(lean, leanTarget, dt)
    local rate = (math.abs(leanTarget) < math.abs(lean)) and L.LEAN_RETURN or L.LEAN_RATE
    return L.Approach(lean, leanTarget, rate, dt)
end

-- A numerically differentiated, lightly smoothed rate (roll or pitch). Raw
-- per-substep derivatives are noisy enough that a Kd of any useful size turns
-- into a buzz. Returns the new filtered rate.
function L.FilterRate(rate, last, now, dt)
    local raw = (now - last) / dt
    return rate + (raw - rate) * min(1, 18 * dt)
end

-- The roll torque gravity applies about the centre of mass, as an angular
-- acceleration (see the long note in sv_balance.lua: formulation 1 ships).
function L.Topple(mass, g, h, roll, inertia)
    return (mass * g * h * math.sin(roll)) / inertia
end

-- The commanded roll acceleration: cancel topple, PD on the error, clamped to
-- the assist ceiling and scaled by the speed-dependent authority.
function L.RollAlpha(topple, kp, kd, err, rollRate, ceiling, authority)
    local alpha = -topple + kp * err - kd * rollRate
    return BMX.Clamp(alpha, -ceiling, ceiling) * authority
end

-- The steer angle the bicycle model asks for at this roll and speed:
-- tan(steer) = wheelbase * g * tan(roll) / v^2.
function L.DerivedSteer(wheelbase, g, roll, speed)
    local v2 = max(speed * speed, 1)
    return math.atan(wheelbase * g * math.tan(roll) / v2)
end

-- The steer target: derived at speed, the rider's direct lean below walking
-- pace (no lean-driven cornering to derive from), clamped to maxSteer.
function L.SteerTarget(derived, lean, speed, walkSpeed, maxSteer)
    local walkBlend = 1 - BMX.Ramp(speed, 0, walkSpeed)
    local direct    = lean * maxSteer
    local target    = derived * (1 - walkBlend) + direct * walkBlend
    return BMX.Clamp(target, -maxSteer, maxSteer)
end

-- THE STICK'S DEAD ZONE (was sv_input.lua's, which still publishes it as
-- BMX.StickDeadzone): inside it is zero, outside it the rest of the travel is
-- stretched back to 0..1. The client's prediction reads its stick the same way.
function L.Deadzone(v, d)
    local a = math.abs(v)
    if a <= d then return 0 end
    return (v > 0 and 1 or -1) * math.min((a - d) / (1 - d), 1)
end

-- First-order lag on the bars, standing in for trail and rider grip.
function L.SteerLag(steer, target, steerRate, dt)
    local f = min(1, steerRate * dt)
    return steer + (target - steer) * f
end
