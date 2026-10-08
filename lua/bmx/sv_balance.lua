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

    BALANCE MODES ARE MODULES (G22). Everything above this line of the file is
    the `singletrack` mode: two wheels in line, steering derived from lean. It is
    registered at the bottom as BMX.BalanceModes.singletrack, and the physics step
    asks the vehicle which mode it runs (`balance = ...` in its registration)
    instead of calling it by name. A mode is a table of two functions with the
    signatures BMX.Balance and BMX.PitchControl already had:

        Ground(ent, phys, cfg, dt, inp, st, wheels, groundNormal, speed)
        Pitch (ent, phys, cfg, dt, inp, st, wheels)

    BMX.Balance and BMX.PitchControl are still the singletrack functions under
    their old names. The code did not move, only the way it is reached: moving
    four hundred lines of tuned controller to make a registry is a way to break
    it, and the history of this file is the record of why each line is there.
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
--------------------------------------------------------------------------
-- WHICH WAY IS UP, FOR BALANCE: GRAVITY'S. A rider stays upright to gravity
-- whatever the ground under them does. This used to hold the bike square to
-- the SURFACE, so riding across or diagonally up a slope tilted the bike with
-- it -- 32 degrees off vertical across a 25-degree bank, 45 across a 35 --
-- and a bike leaning that far off gravity with nothing holding it there went
-- over downhill: "it always tries to make me stand up even when going up
-- slopes diagonally, so I flip over". Measured in tests/test_ride_feel.lua.
--
-- The one place gravity's up stops meaning anything is pointed steeply up or
-- down a surface -- a quarter pipe's face -- where "upright" can only mean
-- square to the wall. So between Balance.surfaceFrom and surfaceTo of climb
-- (or dive) the reference blends over to the surface's normal.
--------------------------------------------------------------------------
function BMX.BalanceUp(ent, cfg, groundNormal)
    local B = cfg.Balance
    local steep = math.abs(ent:GetForward():Dot(vector_up))
    local b = BMX.Ramp(steep, math.sin(B.surfaceFrom), math.sin(B.surfaceTo))
    if b <= 0 or not groundNormal then return vector_up end
    return (vector_up * (1 - b) + groundNormal * b):GetNormalized()
end

function BMX.Balance(ent, phys, cfg, dt, inp, st, wheels, groundNormal, speed)
    local C  = cfg
    local B  = C.Balance

    -- Roll against gravity (BalanceUp); pitch against the ground, because a
    -- wheelie, a stoppie and the tip rule are all about the ground: measured
    -- against gravity, riding up any ramp would read as a wheelie.
    local roll = select(1, BMX.Attitude(ent, BMX.BalanceUp(ent, cfg, groundNormal)))
    local pitch = select(2, BMX.Attitude(ent, groundNormal))

    -- Numerical rates, lightly smoothed. Raw per-substep derivatives are noisy
    -- enough that a Kd of any useful size turns into a buzz.
    st.rollRate  = BMX.Lean.FilterRate(st.rollRate,  st.lastRoll,  roll,  dt)
    st.pitchRate = BMX.Lean.FilterRate(st.pitchRate, st.lastPitch, pitch, dt)
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

    -- Just landed on the wheels (Crash.recoverTime): full authority at any
    -- speed and a higher ceiling, so a crooked landing rights itself.
    local recovering = (st.recoverUntil or 0) > CurTime() and IsValid(ent:GetDriver())
    local ceiling = B.maxAssistAccel
    if recovering then
        authority = 1
        ceiling = ceiling * C.Crash.recoverBoost
    end

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
    -- ...AND IT COSTS 14 DEGREES OF LEAN, WHICH IS A KNOWN TRADE AND NOT AN
    -- OVERSIGHT. Four formulations have been run on a live server. The three
    -- that are not here are written out below anyway, because each one looks
    -- correct from the algebra and all three put the bike on the ground -- so
    -- without the record the next reader derives one of them again.
    --
    -- Write the plant out:   roll'' = topple(roll) - righting(roll) + alpha
    --
    -- `righting` is the lateral tyre force acting at the contact patch below the
    -- centre of mass, and in steady cornering it equals topple exactly -- not by
    -- coincidence, but because the derived steer angle in step 3 is chosen so
    -- that tan(steer) = wheelbase*g*tan(roll)/v^2, the radius at which
    -- m*v^2/R = m*g*tan(roll), whose righting torque h*F*cos(roll) is precisely
    -- the m*g*h*sin(roll) gravity is applying. That cancellation is what "the
    -- loop closes through the real tyre model" means at the top of this file.
    --
    --   1. alpha = -topple(roll) + PD.  What this was. Stable, because
    --      cancelling topple(roll) removes the destabilising roll-dependent
    --      term. But the steady state then demands Kp*err = righting =
    --      topple(roll), which at these gains is a permanent 13-15 degrees of
    --      lean shortfall. It reads exactly like a Kp that wants raising.
    --
    --   2. alpha = -(topple - righting) + PD.  Cancel the NET, measuring the
    --      real lateral force. This is the one that looks careful, and it is on
    --      the ground in half a second. `righting` is downstream of roll through
    --      the derived steering, so cancelling it closes a POSITIVE FEEDBACK
    --      loop: more roll, more steer, more lateral force, a bigger
    --      feed-forward pushing further into the lean. Measured through the
    --      transient, righting ran two to three times topple and the bike rolled
    --      past 90 degrees. A cancellation can be arithmetically right and
    --      dynamically fatal: the quantity you cancel must not depend on the
    --      thing you are controlling.
    --
    --   3. alpha = PD alone. The algebra says the steady state is exact, since
    --      topple and righting cancel there on their own. It also falls over,
    --      because that equilibrium is an INVERTED PENDULUM -- the derived
    --      steering follows the roll rather than stabilising it, so nothing
    --      supplies the phase lead a real bike gets from trail. The
    --      destabilising gain is d(topple)/d(roll) = 111 rad/s^2 per radian
    --      against a Kp of 26, and it runs away.
    --
    --   4. alpha = -topple(roll) + topple(target) + PD. Cancel at the current
    --      roll for stability, add back at the target because that is what the
    --      cornering will supply once the bike is there. Zero steady-state error
    --      on paper, and topple(target) is constant with respect to roll so it
    --      opens no feedback path. It falls over too, and the reason is
    --      TIMING rather than algebra: topple(target) arrives at full value on
    --      the first substep while the cornering that justifies it takes a few
    --      tenths of a second to develop, so the bike gets 93 rad/s^2 into the
    --      lean from upright and slams straight through the target.
    --
    -- SO 1 IS WHAT SHIPS, shortfall and all, and the shortfall is a TUNING
    -- ITEM rather than a bug -- see docs/TUNING.md. Removing it properly wants
    -- integral action or a Kp several times larger, and both of those change how
    -- the bike feels to ride, which is not a judgement a headless suite is
    -- entitled to make. Every alternative above trades the error for a bike on
    -- its side, which is a much worse answer than leaning 14 degrees shy.
    ----------------------------------------------------------------------
    -- THE LEVER ARM IS TO THE CONTACT PATCH, NOT TO THE AXLE LINE.
    --
    -- This block applies a pure couple about the centre of mass, so `topple` has
    -- to be the net roll torque about the COM from the external forces. Gravity
    -- acts AT the COM and contributes none. The normal force acts at the CONTACT
    -- PATCH, and its torque is N times the patch's lateral offset from the COM.
    --
    -- massCenterExpected.z is measured from the chassis origin, which sits on
    -- the AXLE LINE. The patch is a further Wheel.radius below that. So the
    -- COM-to-patch distance is 30 units and the lateral offset under roll is
    -- 30*sin(roll) -- half again what this used to use.
    --
    -- Understating it by a third left a residual destabilising term in the
    -- plant, and it under-sized the ceiling this alpha is clamped to: see the
    -- derivation next to Balance.maxAssistAccel, which was computed against the
    -- same wrong 20 and came out at 74 rad/s^2 for a requirement that is really
    -- 111. That is the second time a number in this controller has been sized
    -- against a quantity that was itself wrong -- the first was the inertia, and
    -- the note beside maxAssistAccel records it.
    local h      = C.Chassis.massCenterExpected.z + C.Wheel.radius
    local topple = BMX.Lean.Topple(C.Chassis.mass, gravity(), h, roll, BMX.IRoll(ent))

    -- Reported, not used. The debug overlay earns its keep by showing what the
    -- bike is doing about its own balance, and the gap between these two is how
    -- you watch the cornering develop -- which is what made formulation 2's
    -- feedback loop visible in the first place.
    local lat = 0
    for _, w in ipairs(wheels) do
        if w.onGround then lat = lat + (w.latForce or 0) end
    end

    local err   = targetRoll - roll
    local alpha = BMX.Lean.RollAlpha(topple, B.leanKp, B.leanKd, err, st.rollRate, ceiling, authority)

    ----------------------------------------------------------------------
    -- THE SLOW END: kickstand or foot. See C.Stand. Weighted by the authority
    -- the lean assist is not using, so the two hand over across the same
    -- speed band instead of stacking. Not past maxRoll: a fallen bike stays
    -- fallen until somebody gets on it.
    ----------------------------------------------------------------------
    local S = C.Stand
    local support = 1 - authority
    st.onStand = false
    local ridden = IsValid(ent:GetDriver())
    -- HELD BY A FOOT OR A STAND, or by nothing. No rider and the stand up is
    -- nothing: a bike let go of at speed rolls on, balanced only by its speed,
    -- and falls over when it slows, rather than growing a kickstand on the way.
    local held = ridden or ent:GetStandDown()
    if support > 0 and abs(roll) < S.maxRoll and held then
        local want = ridden and (inp.lean * S.footLean) or S.standLean
        local a = -topple + S.kp * (want - roll) - S.kd * st.rollRate
        a = BMX.Clamp(a, -B.maxAssistAccel, B.maxAssistAccel)

        -- A KICKSTAND ONLY PUSHES. It props the bike from the left and can
        -- hold it off the ground, but it cannot pull it back: push a parked
        -- bike from the left and it lifts off the stand, comes upright, and
        -- over it goes. That is how a real one behaves, and it is how someone
        -- walking into a parked bike knocks it over. (It used to hold the lean
        -- both ways, so the bike was an immovable post that shoved back.)
        -- The rider's foot is a different thing and works both ways.
        if not ridden and a < 0 then a = 0 end

        -- ...AND IT IS WHERE THE BIKE WAS LEFT. Right of the stand lean the
        -- leg is off the ground and only gravity acts, which at exactly
        -- upright is nothing: a noise-free bike would stand there forever, and
        -- on a real server it would fall whichever way the first bump sent
        -- it, half the time away from its stand. So a parked bike is SET DOWN
        -- onto its stand, by a gentle nudge left. Gentle on purpose: it loses
        -- to gravity a couple of degrees right of upright (settle * lean-gap
        -- against the ~166 rad/s^2 per rad toppling gradient), so a push from
        -- the left still tips the bike over, and past tipOver it is not tried.
        -- Not while somebody is touching it: the nudge exists to set a bike
        -- down, and against a push it is just resistance. With it on, a shove
        -- that should tip a parked bike over only rocked it.
        local touched = (st.pushedUntil or 0) > CurTime()
        if not ridden and not touched and roll > S.standLean and roll < S.tipOver then
            a = a - S.settle * (roll - S.standLean) - S.kd * 0.25 * st.rollRate
        end

        alpha = alpha + a * support
        st.onStand = not ridden
    end

    st.toppleAccel   = topple
    st.rightingAccel = (lat * h * math.cos(roll)) / BMX.IRoll(ent)

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
    local derived = BMX.Lean.DerivedSteer(C.Wheel.wheelbase, gravity(), roll, speed)

    -- Below walking pace the rider is paddling the bike around and steers it
    -- directly, because there is no lean-driven cornering to derive from.
    local target = BMX.Lean.SteerTarget(derived, inp.lean, speed, B.walkSpeed, B.maxSteer)

    -- Mild first-order lag on the bars, standing in for trail and rider grip.
    -- Without it the front end chatters over every bump the suspension passes.
    for _, w in ipairs(wheels) do
        if w.steerMode == "fork" then
            w.steer = BMX.Lean.SteerLag(w.steer, target, B.steerRate, dt)
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
function BMX.PitchControl(ent, phys, cfg, dt, inp, st, wheels)
    local C = cfg
    local P = C.Pitch

    local front, rear
    for _, w in ipairs(wheels) do
        if w.isFront then front = w else rear = w end
    end

    local axisR = ent:GetRight()      -- positive torque about this = nose up
    local torque = 0

    local frontUp = front and not front.onGround
    local rearUp  = rear  and not rear.onGround

    ----------------------------------------------------------------------
    -- WEIGHT FORWARD (G02). The rider leaning over the bars (inp.leanFwd: LMB +
    -- Ctrl, or LMB with bmx_lmb_mode lean) comes on and off over 1 / leanRate
    -- seconds, st.leanFwd 0..1, which is also what is networked for the rider's
    -- IK. RMB (weight back) wins.
    --
    -- Its effect is the mass centre moved Pitch.leanShift forward: a gravity
    -- torque of m*g*leanShift nose-down. Applied wherever nothing is HOLDING the
    -- pitch (the plain branch below, and the nose manual's hold), not under a
    -- wheelie's or a stoppie's own hold, whose PDs would only be pushed off their
    -- aim by it.
    ----------------------------------------------------------------------
    local wantLean = (inp.leanFwd and not inp.wheelieMod) and 1 or 0
    local stepLean = P.leanRate * dt
    local curLean = st.leanFwd or 0
    st.leanFwd = curLean + BMX.Clamp(wantLean - curLean, -stepLean, stepLean)
    local shiftTorque = st.leanFwd * P.leanShift * phys:GetMass() * gravity()

    ----------------------------------------------------------------------
    -- THE NOSE MANUAL (G02, bmx_nose_manual): rolling on the front wheel. A
    -- stoppie that outlives the brake: weight still forward, brake off, the rear
    -- at least noseMinPitch up (so merely leaning never starts one), rolling at
    -- noseMinSpeed or more (below it the front wheel has stopped and it is just a
    -- stoppie that ended). Once held it needs only the lean, not the pitch.
    -- st.noseHold is what BMX.TrackManual reads to call it a Nose Manual.
    ----------------------------------------------------------------------
    local nose = false
    if BMX.NoseManualOn and BMX.NoseManualOn() and rearUp and not frontUp
        and inp.leanFwd and (inp.brakeFront or 0) < 0.5 and not inp.wheelieMod
        and (st.speed or 0) >= P.noseMinSpeed
        and (st.noseHold or st.pitch < -P.noseMinPitch) then
        nose = true
    end
    st.noseHold = nose

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
        local target = inp.pitch * BMX.WheelieBalance(C) * P.holdAim
        if st.pitch < P.holdMax then
            ------------------------------------------------------------------
            -- HAND THE YANK OVER TO THE HOLD, rather than switching between
            -- them. Cutting the direct weight shift dead the instant the front
            -- wheel left the ground left a PD of about 53,000 holding a bike
            -- that still needs 800,000 to stay up, so the nose dropped, the
            -- front touched, the yank came back at full strength, and the whole
            -- thing oscillated around the lift threshold. That is why this case
            -- landed anywhere between 4 and 8 degrees of a 34-degree target on
            -- identical code: the variance WAS the handover.
            --
            -- Ramping it out as the wheelie develops is also what a rider does.
            -- You throw your weight to get the front up and then stop throwing
            -- it; you do not keep heaving at a bike that is already up, which is
            -- what the original unconditional version did and why every wheelie
            -- looped out. Full yank at zero pitch, nothing left at the target,
            -- and the two curves cross at a stable ~13 degrees.
            ------------------------------------------------------------------
            local reach = target > 0
                and BMX.Clamp((target - st.pitch) / target, 0, 1) or 0
            torque = torque + inp.pitch * P.torque * reach

            -- AND THE INERTIA IS NOT THE FREE-BODY ONE. A bike on its rear wheel
            -- is pivoting about the contact patch, so a commanded angular
            -- acceleration costs I_pitch + m*d^2 = 72,574, not I_pitch = 11,837.
            -- Using the free-body figure made every correction 6.1x too small --
            -- and it is the DAMPING that this ruins: the ramp above gets the
            -- nose up with real angular momentum behind it, holdKd was supplying
            -- about 99,000 against a 1,050,000 lift, and the bike sailed through
            -- the target and jumped. Same mistake docs/TUNING.md withdrew an old
            -- note for, and the reason that note existed at all.
            local iEff  = BMX.PivotInertia(ent, C, false)

            local alpha = P.holdKp * (target - st.pitch) - P.holdKd * st.pitchRate
            torque = torque + BMX.TorqueFor(iEff, alpha)
        end
    elseif rearUp and not frontUp and (inp.pitch < 0 or nose) then
        ------------------------------------------------------------------
        -- Stoppie. Same idea mirrored. The front brake does the lifting;
        -- this only keeps you from going over the bars instantly.
        --
        -- AND THE NOSE MANUAL, which is the wheelie's hold above, mirrored about
        -- the front contact patch: the same yank ramping out as the nose comes
        -- down to its aim, plus the same PD, with the weight shift standing in
        -- for the rider's push. It aims at noseAim, trimmed by W / S, and the
        -- same ceiling (stoppieMax) is where it stops helping and the bike can
        -- go over the bars. A PD alone is not enough here, for the reason it is
        -- not for a wheelie: gravity's torque about the front axle is several
        -- times what the error left under a PD can supply.
        ------------------------------------------------------------------
        local target = inp.pitch * -P.stoppieMax
        if nose then
            target = -(P.noseAim + BMX.Clamp(inp.noseTrim or 0, -1, 1) * P.noseTrim)
        end
        if nose and st.pitch > P.stoppieMax then
            local reach = BMX.Clamp((target - st.pitch) / target, 0, 1)
            torque = torque - P.noseYank * P.torque * reach - shiftTorque
        end
        if st.pitch > P.stoppieMax then
            -- The wheelie's lesson, applied to its mirror image, where it had
            -- not been. A bike on its FRONT wheel pivots about the front axle,
            -- so a commanded angular acceleration costs I_pitch + m*d^2 with d
            -- measured to that axle: 85,990 against the free-body 11,837. This
            -- used the free-body figure, which made the stoppie hold 7.3x too
            -- weak to do anything a rider would notice. BMX.PivotInertia is the
            -- one place that knows the geometry, for both ends.
            local alpha = P.holdKp * (target - st.pitch) - P.holdKd * st.pitchRate
            torque = torque + BMX.TorqueFor(BMX.PivotInertia(ent, C, true), alpha)
        end
    else
        -- Nothing is being held, so the rider's weight shift acts directly.
        -- This is the yank that STARTS a wheelie or a stoppie.
        torque = torque + inp.pitch * P.torque - shiftTorque

        if not frontUp and not rearUp then
            -- Both wheels down: damp pitch so the bike settles rather than
            -- porpoising on its own suspension.
            torque = torque - BMX.TorqueFor(BMX.IPitch(ent),
                P.groundDamping * st.pitchRate)
        end
    end

    -- Just landed on the wheels: level a nose-down or nose-up touchdown about
    -- the axle it is on, so a flip landed on one wheel comes down onto both
    -- instead of going over the bars or looping out.
    --
    -- NEVER PAST LEVEL IN ONE SUBSTEP. The law is the PD it always was,
    -- Kd * (want - rate) with want = -(Kp/Kd) * pitch: the rate that levels
    -- the bike. Sized on the inertia about the axle it lands on, as if that
    -- axle were a hinge -- but it is a strut with no travel used yet, so for
    -- the first substeps the torque turns the FREE body, 7.3 times as hard
    -- as asked: past level, onto the other wheel, which asked the same back
    -- the other way. Off an 8-unit bump at 300 u/s the bike see-sawed front,
    -- rear, front at 400, 1000, 1240 deg/s and cartwheeled (measured on a
    -- real server). So the rate is read off the engine now, not st.pitchRate
    -- (a substep late), and the step the free body would take is held to
    -- half the gap to `want`: it closes on level, and never crosses it.
    if (st.recoverUntil or 0) > CurTime() and IsValid(ent:GetDriver()) and inp.pitch == 0 then
        local CR = C.Crash
        local rate = -math.rad(phys:GetAngleVelocity().y)      -- nose up, about axisR
        local want = -CR.recoverPitchKp / CR.recoverPitchKd * st.pitch
        local iPivot = BMX.PivotInertia(ent, C, st.pitch < 0)
        local alpha = CR.recoverPitchKd * (want - rate)
        local step = math.abs(alpha * iPivot / BMX.IPitch(ent) * dt)
        local room = 0.5 * math.abs(want - rate)
        if step > room then alpha = alpha * room / step end
        torque = torque + BMX.TorqueFor(iPivot, alpha)
    end

    -- NOT OVER THE BARS BY ACCIDENT. On the front wheel alone, past
    -- noseGuardStart nose-down, with the rider asking for no stoppie (no
    -- pitch-forward, no nose manual, no front brake), the rider's weight goes
    -- back: levelled toward noseGuardStart by the same never-past-it law as
    -- the landing assist above. Cresting an 18-unit hump whose top is shorter
    -- than the bike at 150 u/s, the front dropped down the far face while
    -- the rear still climbed the near one, and the bike pitched on to 74
    -- degrees and over (one ride in ten, real server).
    local CRg = C.Crash
    if CRg.noseGuardStart and rearUp and not frontUp and not nose and inp.pitch >= 0
        and (inp.brakeFront or 0) < 0.1 and IsValid(ent:GetDriver())
        and st.pitch < -CRg.noseGuardStart then
        local rate = -math.rad(phys:GetAngleVelocity().y)
        local want = -CRg.recoverPitchKp / CRg.recoverPitchKd * (st.pitch + CRg.noseGuardStart)
        local iPivot = BMX.PivotInertia(ent, C, true)
        local alpha = CRg.recoverPitchKd * (want - rate)
        local step = math.abs(alpha * iPivot / BMX.IPitch(ent) * dt)
        local room = 0.5 * math.abs(want - rate)
        if step > room then alpha = alpha * room / step end
        if alpha > 0 then torque = torque + BMX.TorqueFor(iPivot, alpha) end
    end

    BMX.ApplyTorque(phys, ent, axisR, torque, dt)
end

--------------------------------------------------------------------------
-- THE MODES.
--------------------------------------------------------------------------
BMX.BalanceModes = BMX.BalanceModes or {}

-- Today's code, reached through the registry.
BMX.BalanceModes.singletrack = {
    Ground = function(...) return BMX.Balance(...) end,
    Pitch  = function(...) return BMX.PitchControl(...) end,
}

-- The mode a vehicle entity runs. A name with no module behind it (`board`
-- before G23 lands, or a typo that slipped past the registry) runs as `none`,
-- and says so once per name rather than once per substep.
local warned = {}
function BMX.BalanceFor(ent)
    local def = ent.Bike and ent:Bike()
    local name = def and def.balance or "singletrack"
    local mode = BMX.BalanceModes[name]
    if mode then return mode end
    if not warned[name] then
        warned[name] = true
        ErrorNoHalt(string.format("[BMX] balance mode %q has no module; vehicles that " ..
            "name it run as \"none\".\n", tostring(name)))
    end
    return BMX.BalanceModes.none
end

--------------------------------------------------------------------------
-- `none`: NOTHING HOLDS THE VEHICLE UP. A motor vehicle whose centre of mass
-- is low enough, or a cart on four wheels, stands on its suspension like any
-- rigid body; there is no lean target, no assist, no kickstand and no wheelie
-- hold to run.
--
-- What it does keep doing is the BOOKKEEPING, because the rest of the step reads
-- it: st.roll and st.pitch (the tip rule, the landing judge, the HUD, the
-- camera), their rates and the history the air control differentiates against.
-- Taken exactly as the single-track mode takes them -- roll against gravity,
-- pitch against the ground -- so a vehicle that switches mode does not change
-- what those numbers mean. Steering is the wheels' own (`steer` functions in the
-- registration), applied by the physics step after this returns.
--------------------------------------------------------------------------
BMX.BalanceModes.none = {
    Ground = function(ent, phys, cfg, dt, inp, st, wheels, groundNormal, speed)
        local roll  = select(1, BMX.Attitude(ent, BMX.BalanceUp(ent, cfg, groundNormal)))
        local pitch = select(2, BMX.Attitude(ent, groundNormal))
        st.rollRate  = st.rollRate  + ((roll  - st.lastRoll)  / dt - st.rollRate)  * min(1, 18 * dt)
        st.pitchRate = st.pitchRate + ((pitch - st.lastPitch) / dt - st.pitchRate) * min(1, 18 * dt)
        st.lastRoll, st.lastPitch = roll, pitch
        st.roll, st.pitch = roll, pitch
        st.onStand = false
        st.leanAuthority, st.leanError = 0, 0
    end,
    Pitch = function() end,
}
