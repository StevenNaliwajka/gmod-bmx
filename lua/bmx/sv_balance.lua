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

    ----------------------------------------------------------------------
    -- GRAVITY FEED-FORWARD.
    --
    -- A leaning bike is toppled by the ground reaction, which acts at the
    -- contact patch and is displaced h*sin(roll) from under the centre of mass.
    -- That torque is m*g*h*sin(roll) and it GROWS with lean, so it is largest
    -- exactly where the rider is asking for the most commitment.
    --
    -- Making the PD supply it through error is the mistake this replaces. At 42
    -- degrees the requirement is 74 rad/s^2, and a Kp of 26 only asks for that
    -- at 163 degrees of error -- so the bike sagged out of every lean and then
    -- fell over, at full assist authority, looking exactly like a tuning
    -- problem. Cancelling it explicitly leaves the PD doing what a PD is good
    -- at: killing the residual and the rate.
    --
    -- Scaled by authority along with everything else, so a stationary bike is
    -- still un-helped and still falls over. That is the design, not an oversight.
    --
    -- ...AND IT MUST NOT CANCEL WHAT THE CORNERING IS ALREADY DOING. This is the
    -- half that was missing, and it cost 14 degrees of lean.
    --
    -- Gravity is not the only thing acting on the roll axis. The lateral tyre
    -- force acts at the same contact patch, h below the centre of mass, and its
    -- torque RIGHTS the bike. In steady cornering the two cancel exactly, and
    -- not by coincidence: the derived steer angle in step 3 below is chosen so
    -- that tan(steer) = wheelbase*g*tan(roll)/v^2, which is the radius at which
    -- m*v^2/R = m*g*tan(roll), whose righting torque h*F*cos(roll) is precisely
    -- the m*g*h*sin(roll) that gravity is applying. That is what "the loop
    -- closes through the real tyre model" means at the top of this file.
    --
    -- So subtracting the whole toppling torque left the righting torque
    -- unopposed: a spurious roll-upright acceleration of m*g*h*sin(roll)/I that
    -- the PD then had to fight with error alone. The bike sagged out of every
    -- lean by a repeatable 13-15 degrees, which reads exactly like a Kp that
    -- wants raising and is nothing of the kind.
    --
    -- Cancel the NET instead, and take the lateral force from the wheels rather
    -- than from the ideal-cornering formula, because the formula is only true
    -- once the turn has developed. At a standstill, at walking pace, or with the
    -- steer angle saturated, the tyres genuinely are not producing enough and
    -- the assist genuinely is needed -- which is the case it was added for. This
    -- measures the shortfall instead of assuming it.
    ----------------------------------------------------------------------
    local h      = C.Chassis.massCenterExpected.z
    local topple = (C.Chassis.mass * gravity() * h * math.sin(roll)) / BMX.IRoll(ent)

    local lat = 0
    for _, w in ipairs(wheels) do
        if w.onGround then lat = lat + (w.latForce or 0) end
    end
    local righting = (lat * h * math.cos(roll)) / BMX.IRoll(ent)

    local err   = targetRoll - roll
    local alpha = -(topple - righting) + B.leanKp * err - B.leanKd * st.rollRate
    alpha = BMX.Clamp(alpha, -B.maxAssistAccel, B.maxAssistAccel) * authority

    st.toppleAccel   = topple
    st.rightingAccel = righting

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

    local frontUp = front and not front.onGround
    local rearUp  = rear  and not rear.onGround

    -- THE YANK AND THE BALANCE ARE DIFFERENT ACTS, and only one of them is in
    -- charge at a time. Getting the front wheel up is a shove: the rider throws
    -- their weight back against a gravity torque that is resisting the whole
    -- way. Keeping it up is not a shove at all, it is a rider making small
    -- corrections either side of an unstable point.
    --
    -- The direct weight shift used to be applied unconditionally, on top of the
    -- hold PD. So the moment the front came up, the PD was trying to settle onto
    -- a target while a constant 1,050,000 kept pushing past it -- and past the
    -- balance point, where gravity joins in, there is no coming back. Every
    -- wheelie in the headless suite looped out, and no target the PD aimed at
    -- could have changed that, because the PD was not the thing in control.
    if frontUp and not rearUp and inp.pitch > 0 then
        ------------------------------------------------------------------
        -- Wheelie hold. A PD onto the rider's chosen balance point, but
        -- only INSIDE the hold window: past holdMax you are looping out and
        -- the assist stops, so a wheelie can still be blown. An assist with
        -- no ceiling is what turns "wheelie" into "the bike cannot fall".
        ------------------------------------------------------------------
        -- Aim SHORT OF THE BALANCE POINT, not past it. See Pitch.holdAim.
        local target = inp.pitch * BMX.WheelieBalance() * P.holdAim
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
    else
        -- Nothing is being held, so the rider's weight shift acts directly.
        -- This is the yank that STARTS a wheelie or a stoppie, and it is the
        -- only branch that gets it: once a wheel is up, the PD above takes over.
        torque = torque + inp.pitch * P.torque

        if not frontUp and not rearUp then
            -- Both wheels down: damp pitch so the bike settles rather than
            -- porpoising on its own suspension.
            torque = torque - BMX.TorqueFor(BMX.IPitch(ent),
                P.groundDamping * st.pitchRate)
        end
    end

    BMX.ApplyTorque(phys, ent, axisR, torque, dt)
end
