--[[--------------------------------------------------------------------------
    bmx/sv_balance.lua

    Lean, derived steering, and pitch. This is the file that decides whether the
    thing feels like a bike or like a prop with wheels.

    THE CENTRAL IDEA: STEERING IS AN OUTPUT.

    A real bike does not turn because the bars moved; it turns because it is
    leaning, and the bars moved to sustain the lean. GTA models this the same
    way, and it is why binding A/D straight to a steer angle never feels right
    no matter how much you tune it.

    So:
        1. rider input  ->  TARGET roll angle
        2. a PD controller drives actual roll toward the target
        3. the front wheel's steer angle is DERIVED from the roll that resulted
        4. the steered front tyre generates lateral force, the bike yaws, and
           the resulting centripetal acceleration is what actually holds the
           lean up

    Step 4 means the loop closes through the real tyre model in sv_wheel.lua,
    not through a fudge. Lean too far for your speed and the front washes out,
    because the friction circle says so.

    SIGN CONVENTIONS, verified against Source's right-handed X-forward,
    Y-left, Z-up frame:
        roll  > 0   leaning RIGHT   torque about +ent:GetForward()
        pitch > 0   nose UP         torque about +ent:GetRight()
----------------------------------------------------------------------------]]

BMX = BMX or {}

local abs, min, max = math.abs, math.min, math.max

local function gravity()
    local g = physenv.GetGravity()
    return g and g:Length() or 600
end

-- BMX.Attitude lives in sh_util.lua: the chase camera leans with the bike and
-- needs the same roll the controller is working from.

--------------------------------------------------------------------------
-- Ground balance: hold the target lean, derive the steer angle.
--
-- `st` is the bike's persistent controller state (roll/pitch history), so the
-- rates can be differentiated numerically. PhysObj:GetAngleVelocity's component
-- ordering is ambiguous enough across builds that differentiating an angle we
-- computed ourselves is both simpler and more portable.
--------------------------------------------------------------------------
function BMX.Balance(ent, phys, dt, inp, st, wheels, groundNormal, speed)
    local C  = BMX.Config
    local B  = C.Balance

    local roll, pitch = BMX.Attitude(ent, groundNormal)

    -- Numerical rates, lightly smoothed. Raw per-substep derivatives are noisy
    -- enough that a Kd of any useful size turns into a buzz.
    local rollRate  = (roll  - st.lastRoll)  / dt
    local pitchRate = (pitch - st.lastPitch) / dt
    st.rollRate  = st.rollRate  + (rollRate  - st.rollRate)  * min(1, 18 * dt)
    st.pitchRate = st.pitchRate + (pitchRate - st.pitchRate) * min(1, 18 * dt)
    st.lastRoll  = roll
    st.lastPitch = pitch
    st.roll      = roll
    st.pitch     = pitch

    ----------------------------------------------------------------------
    -- 1 + 2. Target lean, and the PD that holds it.
    ----------------------------------------------------------------------
    local targetRoll = inp.lean * B.maxLean

    -- Assist authority ramps in with speed. Below fadeInLow the bike gets no
    -- help at all and WILL fall over, which is correct: a stationary bicycle
    -- does exactly that, and a bike that balances itself at walking pace reads
    -- as a hovering prop.
    local authority = BMX.Ramp(speed, B.fadeInLow, B.fadeInHigh)

    local err   = targetRoll - roll
    local alpha = B.leanKp * err - B.leanKd * st.rollRate
    alpha = BMX.Clamp(alpha, -B.maxAssistAccel, B.maxAssistAccel) * authority

    BMX.ApplyTorque(phys, ent, ent:GetForward(),
        BMX.TorqueFor(BMX.IRoll(ent), alpha), dt)

    st.leanAuthority = authority
    st.leanError     = err

    ----------------------------------------------------------------------
    -- 3. Derive the steer angle from the lean that actually happened.
    --
    -- Steady-state cornering:   tan(roll) = v^2 / (g * R)
    -- Bicycle model:            R = wheelbase / tan(steer)
    --   =>                      tan(steer) = wheelbase * g * tan(roll) / v^2
    --
    -- As v falls this saturates to maxSteer, which is not a failure mode: it is
    -- the correct answer. Slow riding genuinely does need big steering inputs.
    ----------------------------------------------------------------------
    local v2 = max(speed * speed, 1)
    local derived = math.atan(C.Wheel.wheelbase * gravity() * math.tan(roll) / v2)

    -- Below walking pace the rider is paddling the bike around and steers it
    -- directly, because there is no lean-driven cornering to derive from.
    local walkBlend = 1 - BMX.Ramp(speed, 0, B.walkSpeed)
    local direct    = inp.lean * B.maxSteer
    local target    = derived * (1 - walkBlend) + direct * walkBlend
    target = BMX.Clamp(target, -B.maxSteer, B.maxSteer)

    -- Mild first-order lag on the bars, standing in for trail and rider grip.
    -- Without it the front end chatters over every bump the suspension passes.
    local f = min(1, B.steerRate * dt)
    for _, w in ipairs(wheels) do
        if w.isFront then
            w.steer = w.steer + (target - w.steer) * f
            st.steer = w.steer
        end
    end
end

--------------------------------------------------------------------------
-- Ground pitch: wheelies, stoppies, manuals.
--
-- Some of this emerges on its own: drive force is applied at the rear contact
-- patch, which is below the centre of mass, so hard pedalling already lifts the
-- front. What does NOT emerge is a wheelie you can HOLD, because the balance
-- point is unstable. The hold assist below is that skill, modelled.
--------------------------------------------------------------------------
function BMX.PitchControl(ent, phys, dt, inp, st, wheels)
    local C = BMX.Config
    local P = C.Pitch

    local front, rear
    for _, w in ipairs(wheels) do
        if w.isFront then front = w else rear = w end
    end

    local axisR = ent:GetRight()      -- positive torque about this = nose up
    local torque = 0

    -- Direct rider weight shift.
    torque = torque + inp.pitch * P.torque

    local frontUp = front and not front.onGround
    local rearUp  = rear  and not rear.onGround

    if frontUp and not rearUp and inp.pitch > 0 then
        ------------------------------------------------------------------
        -- Wheelie hold. A PD onto the rider's chosen balance point, but
        -- only INSIDE the hold window: past holdMax you are looping out and
        -- the assist stops, so a wheelie can still be blown. An assist with
        -- no ceiling is what turns "wheelie" into "the bike cannot fall".
        ------------------------------------------------------------------
        local target = inp.pitch * P.holdMax
        if st.pitch < P.holdMax then
            local alpha = P.holdKp * (target - st.pitch) - P.holdKd * st.pitchRate
            torque = torque + BMX.TorqueFor(BMX.IPitch(ent), alpha)
        end
    elseif rearUp and not frontUp and inp.pitch < 0 then
        ------------------------------------------------------------------
        -- Stoppie. Same idea mirrored. The front brake does the lifting;
        -- this only keeps you from going over the bars instantly.
        ------------------------------------------------------------------
        local target = inp.pitch * -P.stoppieMax
        if st.pitch > P.stoppieMax then
            local alpha = P.holdKp * (target - st.pitch) - P.holdKd * st.pitchRate
            torque = torque + BMX.TorqueFor(BMX.IPitch(ent), alpha)
        end
    elseif not frontUp and not rearUp then
        -- Both wheels down: damp pitch so the bike settles rather than
        -- porpoising on its own suspension.
        torque = torque - BMX.TorqueFor(BMX.IPitch(ent),
            P.groundDamping * st.pitchRate)
    end

    BMX.ApplyTorque(phys, ent, axisR, torque, dt)
end
