--[[--------------------------------------------------------------------------
    bmx/sv_physics.lua

    The physics step. Called once per VPhysics substep from
    ENT:PhysicsSimulate, which is the only place in GMod that hands Lua a
    correct, substep-accurate dt. Doing this in Think instead means running at
    the frame rate with a dt that varies with how many props someone just
    spawned, and a PD controller tuned at 60 fps then oscillating at 200.

    Order matters and is not arbitrary:

        1. inputs are smoothed          (needs dt)
        2. angular velocity is estimated from the orientation delta
        3. the drivetrain decides torques
        4. wheels trace, compute tyre forces, and APPLY them
        5. ground state is re-read from the fresh traces
        6. balance/pitch (grounded) or air control (airborne)
        7. drag, hop, landing and crash checks

    Step 4 before step 6 is the important one: the balance controller wants to
    know whether the wheels found ground THIS substep, not last one.
----------------------------------------------------------------------------]]

BMX = BMX or {}

local abs, min, max, sqrt = math.abs, math.min, math.max, math.sqrt

--------------------------------------------------------------------------
-- Fresh controller state for a bike.
--------------------------------------------------------------------------
function BMX.NewState(cfg)
    return {
        lastRoll = 0, lastPitch = 0,
        roll = 0, pitch = 0,
        rollRate = 0, pitchRate = 0,
        steer = 0,
        leanAuthority = 0, leanError = 0,

        angVel = Vector(),
        prevF = nil, prevR = nil, prevU = nil,

        grounded = false,
        groundNormal = Vector(0, 0, 1),
        airSince = 0,
        airMode = false,

        spinPitch = 0, spinRoll = 0, spinYaw = 0, airTime = 0,

        stamina = (cfg or BMX.Config).Drive.staminaMax,
        speed = 0,
        cadence = 0,
    }
end

--------------------------------------------------------------------------
-- World-space angular velocity from successive orientations.
--
-- PhysObj:GetAngleVelocity returns a Vector whose component-to-axis mapping is
-- documented inconsistently and has bitten enough addons to be worth avoiding
-- outright. Three basis vectors give an unambiguous answer:
--
--     w ~= 1/2 * ( f_prev x f_now + r_prev x r_now + u_prev x u_now ) / dt
--
-- exact in the limit, and accurate to well under a degree at physics-substep
-- sizes. It costs three cross products.
--------------------------------------------------------------------------
local function estimateAngVel(ent, st, dt)
    local f, r, u = ent:GetForward(), ent:GetRight(), ent:GetUp()

    if st.prevF and dt > 0 then
        local w = (st.prevF:Cross(f) + st.prevR:Cross(r) + st.prevU:Cross(u)) * (0.5 / dt)
        if BMX.FiniteVec(w) then st.angVel = w end
    end

    st.prevF, st.prevR, st.prevU = f, r, u
end

--------------------------------------------------------------------------
-- Drivetrain: rider legs -> rear wheel torque.
--------------------------------------------------------------------------
local function drivetrain(ent, cfg, dt, inp, st, rear)
    local D = cfg.Drive

    -- Stamina gates the sprint, so the sprint is a resource rather than a
    -- permanent 55% power bonus that everyone simply holds down forever.
    --
    -- WINDED, with hysteresis. Gating on "stamina > 1" alone let a rider
    -- holding SHIFT on an empty tank regenerate past 1 on one substep and
    -- drain below it on the next, so the sprint flickered on alternate ticks
    -- instead of stopping: a bonus that never ran out, at half strength. Once
    -- empty, it stays off until staminaRecover has come back.
    if st.stamina <= 1 then st.winded = true end
    if st.winded and st.stamina >= D.staminaRecover then st.winded = false end

    local sprinting = inp.sprint and inp.throttle > 0.1 and not st.winded
    if sprinting then
        st.stamina = max(0, st.stamina - D.staminaDrain * dt)
    else
        st.stamina = min(D.staminaMax, st.stamina + D.staminaRegen * dt)
    end

    local tq  = D.crankTorque * (sprinting and D.sprintTorque  or 1)
    local cad = D.maxCadence  * (sprinting and D.sprintCadence or 1)

    -- Crank speed implied by the rear wheel through the gear.
    local crankOmega = rear.omega / D.gearRatio
    st.cadence = crankOmega

    -- Falling torque curve. At maxCadence the rider is spinning out and
    -- contributes nothing, which is what caps top speed on the flat: no drag
    -- term is doing that job, the legs are.
    local spin  = BMX.Clamp(crankOmega / cad, 0, 1)
    local crank = tq * (1 - spin) * inp.throttle

    -- Paddling backwards. A rider at a standstill holding the "brake" key
    -- expects to be able to walk the bike back, not to stand there. Only
    -- available below walking pace, where the brake would do nothing anyway.
    if inp.brakeRear > 0 and st.speed < 40 and rear.omega < 1 then
        crank = crank - tq * 0.16 * inp.brakeRear
    end

    st.sprinting = sprinting
    return crank / D.gearRatio
end

--------------------------------------------------------------------------
-- The main entry point.
--------------------------------------------------------------------------
function BMX.PhysicsStep(ent, phys, dt)
    if dt <= 0 or dt > 0.25 then return end     -- a stalled server hands out
                                                -- absurd dt; integrating it
                                                -- launches the bike into orbit
    -- THIS BIKE'S config, resolved once per substep and threaded from here
    -- down. Everything below reads `C`, so a bike with per-bike physics
    -- overrides gets its own numbers without a single global changing meaning.
    local C   = ent:Cfg()
    local st  = ent.st
    local inp = ent.input
    local wheels = ent.wheels
    if not st or not inp or not wheels then return end

    local hasDriver = IsValid(ent:GetDriver())

    ----------------------------------------------------------------------
    -- 1 + 2
    ----------------------------------------------------------------------
    if hasDriver then
        BMX.SmoothInput(inp, dt)
    else
        -- A riderless bike coasts to a stop and falls over. No neutral-input
        -- balancing: an unattended bike that stands up on its own reads as a
        -- bug even when it is convenient.
        inp.lean, inp.pitch, inp.throttle = 0, 0, 0
        inp.brakeRear, inp.brakeFront = 0, 0
    end

    estimateAngVel(ent, st, dt)

    local vel   = phys:GetVelocity()
    local fwd   = ent:GetForward()
    local speed = vel:Length()
    local fwdSpeed = vel:Dot(fwd)
    st.speed    = speed
    st.fwdSpeed = fwdSpeed

    ----------------------------------------------------------------------
    -- 3. Drivetrain and brakes
    ----------------------------------------------------------------------
    local front, rear
    for _, w in ipairs(wheels) do
        if w.isFront then front = w else rear = w end
    end

    local driveTorque = hasDriver and drivetrain(ent, C, dt, inp, st, rear) or 0
    local brakeRear   = inp.brakeRear  * C.Drive.rearBrake
    local brakeFront  = inp.brakeFront * C.Drive.frontBrake

    -- Paddling backwards is a drive, not a brake, so do not do both at once.
    if driveTorque < 0 then brakeRear = 0 end

    ----------------------------------------------------------------------
    -- 4. Wheels
    ----------------------------------------------------------------------
    local filter = ent.traceFilter
    front:Simulate(ent, phys, C, dt, 0,           brakeFront, filter)
    rear:Simulate (ent, phys, C, dt, driveTorque, brakeRear,  filter)

    ----------------------------------------------------------------------
    -- Skid state, for the client's tyre sound. A tyre is skidding when it is
    -- ON the ground, at the limit of its friction circle, AND actually sliding
    -- -- saturation alone is not enough, because a wheel sitting still under a
    -- locked brake is saturated and silent.
    ----------------------------------------------------------------------
    local skid = false
    for _, w in ipairs(wheels) do
        if w.onGround and w.saturation > 0.98
            and (abs(w.slipLong) + abs(w.slipLat)) > 45 then
            skid = true
        end
    end
    if skid ~= ent:GetSkidding() then ent:SetSkidding(skid) end

    ----------------------------------------------------------------------
    -- 5. Ground state
    ----------------------------------------------------------------------
    local wasGrounded = st.grounded
    local grounded = front.onGround or rear.onGround

    local n = Vector()
    local c = 0
    if front.onGround then n = n + front.contactNorm; c = c + 1 end
    if rear.onGround  then n = n + rear.contactNorm;  c = c + 1 end
    if c > 0 then
        n:Normalize()
        st.groundNormal = n
    else
        st.groundNormal = Vector(0, 0, 1)
    end
    st.grounded = grounded

    ----------------------------------------------------------------------
    -- 6. Attitude control
    --
    -- Air mode does not engage the instant both wheels lose contact: a bump in
    -- the road unloads both wheels for a substep or two, and switching control
    -- modes there makes the bike twitch on rough ground and scores phantom
    -- "tricks" for riding over a kerb.
    ----------------------------------------------------------------------
    if grounded then
        if st.airMode then
            -- Landed. Score first, then judge the landing: a trick that ends
            -- badly should still be reported, it just does not count.
            local tricks = BMX.ScoreAir(st)
            st.airMode = false
            ent:OnLanded(tricks, front, rear)
        end
        st.airSince = 0

        BMX.Balance(ent, phys, C, dt, inp, st, wheels, st.groundNormal, speed)
        BMX.PitchControl(ent, phys, C, dt, inp, st, wheels)
    else
        st.airSince = st.airSince + dt
        if not st.airMode and st.airSince >= C.Air.engageDelay then
            st.airMode = true
            BMX.AirReset(st)
        end
        if st.airMode then
            BMX.AirControl(ent, phys, C, dt, inp, st)
        end
        -- Attitude still needs measuring in the air, for the HUD and for the
        -- landing check that is about to use it.
        --
        -- BOTH history values must be advanced here, not just roll. Leaving
        -- lastPitch frozen at its pre-jump value means the first Balance call
        -- after landing differentiates a whole backflip across one substep: a
        -- pitch rate two orders of magnitude too large, straight into Kd, and a
        -- torque spike that flings the bike on touchdown. It reads exactly like
        -- a landing physics bug and is nothing of the kind.
        st.lastRoll, st.lastPitch = st.roll, st.pitch
        st.roll, st.pitch = BMX.Attitude(ent, vector_up)
    end

    ----------------------------------------------------------------------
    -- 6b. Ground tricks. Only with a rider: a riderless bike that bounces on
    -- its front wheel is not doing a stoppie.
    ----------------------------------------------------------------------
    if hasDriver then
        local done = BMX.TrackManual(st, C, front, rear, speed, dt)
        if done and ent.AwardTricks then ent:AwardTricks(done) end
    else
        st.manual = nil
    end

    ----------------------------------------------------------------------
    -- 7a. Drag
    --
    -- Quadratic, applied at the centre of mass. VPhysics' own drag is disabled
    -- on this object because it is tuned for tumbling debris and would fight
    -- the tyre model.
    ----------------------------------------------------------------------
    if speed > 1 then
        local area = C.Drive.dragArea * (inp.tuck and 0.7 or 1)
        local f = vel:GetNormalized() * (-area * speed * speed * dt)
        if BMX.FiniteVec(f) then phys:ApplyForceCenter(f) end
    end

    ----------------------------------------------------------------------
    -- 7b. Bunny hop
    ----------------------------------------------------------------------
    local H = C.Hop
    if ent.hopHeld then
        ent.hopCharge = min(H.chargeTime, (ent.hopCharge or 0) + dt)
    end

    if ent.hopRelease then
        ent.hopRelease = false
        ent.hopHeld    = false

        if grounded and hasDriver and CurTime() >= (ent.hopReady or 0) then
            local charge = max(H.minCharge, (ent.hopCharge or 0) / H.chargeTime)

            -- Pop along the surface normal, not along world up, so hopping off
            -- a transition sends you along the ramp rather than straight up.
            local dir = (st.groundNormal + fwd * H.forwardBias):GetNormalized()
            local dv  = H.popSpeed * charge

            phys:ApplyForceCenter(dir * (dv * phys:GetMass()))

            -- Nose-up kick, so a hop naturally rolls into a manual. Written as
            -- a torque whose dt cancels, which makes it an impulse.
            BMX.ApplyTorque(phys, ent, ent:GetRight(),
                BMX.TorqueFor(BMX.IPitch(ent), H.pitchImpulse / dt), dt)

            ent.hopReady = CurTime() + H.cooldown
            local H = BMX.Sounds.hop
            ent:EmitSound(BMX.SoundFile("hop"), H.level, 110, H.vol)
        end
        ent.hopCharge = 0
    end

    ----------------------------------------------------------------------
    -- Keep VPhysics awake. An object that falls asleep stops receiving
    -- PhysicsSimulate, and the symptom is a bike that works until you stand
    -- still for two seconds and then never responds again.
    ----------------------------------------------------------------------
    phys:Wake()
end
