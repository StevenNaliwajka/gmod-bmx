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

    -- CLIMBING: the rider stands, leans over the bars and mashes. The legs
    -- above are sized for the flat, where a full-power start is ~10,800 of
    -- wheel force against ~51,600 of weight: sin(12 deg) of it. Every half
    -- pipe and funbox in a skatepark is steeper than that, and pedalling up
    -- one stalled and rolled back down.
    --
    -- So on an uphill the rider also carries climbAssist of the slope's pull,
    -- m*g*sin(slope), through the same falling curve: the bike climbs at a
    -- lower cadence, the way a lower gear would, instead of not at all.
    --
    -- IT IS A PUSH AT THE MASS CENTRE, NOT MORE CRANK TORQUE. Drive at the
    -- rear tyre acts at the contact patch, ~20 units below the mass centre,
    -- and pitches the nose up in proportion. On a slope the bike is already
    -- leaning back toward its balance point, so as crank torque the help
    -- looped the bike over backwards from 25 degrees up and threw the rider
    -- (measured in tests/test_sim.lua). A rider climbing keeps their weight
    -- forward exactly so that does not happen; applying the help where the
    -- weight is says the same thing. Applied in PhysicsStep, only while the
    -- rear tyre is on the ground.
    st.climbAccel, st.climbDir = 0, nil
    if D.climbAssist and D.climbAssist > 0 and rear.onGround and inp.throttle > 0 then
        local n = st.groundNormal or vector_up
        local f = ent:GetForward()
        f = f - n * f:Dot(n)
        local len = f:Length()
        if len > 1e-3 then
            f = f / len
            if f.z > 0 then
                st.climbDir = f
                -- Up to climbMax the help is whole; by climbWall it is gone.
                -- A vert wall is ridden on momentum, not pedalled up.
                local wall = 1 - BMX.Ramp(math.asin(math.min(f.z, 1)),
                    D.climbMax or math.rad(40), D.climbWall or math.rad(55))
                st.climbAccel = D.climbAssist * physenv.GetGravity():Length()
                    * f.z * (1 - spin) * inp.throttle * wall
            end
        end
    end

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
        -- A riderless bike has no input. Parked, it sits on its kickstand
        -- (C.Stand, in BMX.Balance) and is held where it stands: see 7c.
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
    -- 2b. GRINDING (sv_grind.lua). On a rail the bike is placed along it and
    -- none of the riding model below applies: no tyres, no balance, no tip
    -- rule. Off it, each substep looks for a rail to lock on to.
    ----------------------------------------------------------------------
    if st.grind then
        if hasDriver then
            BMX.GrindStep(ent, phys, C, dt, inp, st)
        else
            BMX.EndGrind(ent, phys, C, st, "rider")
        end
        phys:Wake()
        return
    end
    -- JUST OFF A RAIL: no faster than it left. If the rail it was on still
    -- overlaps the hull anywhere, VPhysics resolves that as a shove on the
    -- first free substep, and a shove of any size reads as being launched.
    -- The pose check in sv_grind.lua is meant to make this never fire; this
    -- is what keeps a map it did not foresee from throwing the rider.
    local ex = st.grindExit
    if ex then
        if CurTime() > ex.untilT then
            st.grindExit = nil
        else
            local v = phys:GetVelocity()
            local capZ = max(ex.vel.z, 0) + 40
            local capH = Vector(ex.vel.x, ex.vel.y, 0):Length() + 40
            local vh = Vector(v.x, v.y, 0)
            local fix = false
            if v.z > capZ then v.z, fix = capZ, true end
            if vh:Length() > capH then
                vh = vh:GetNormalized() * capH
                v.x, v.y, fix = vh.x, vh.y, true
            end
            if fix then
                phys:SetVelocity(v)
                st.grindExitClamped = (st.grindExitClamped or 0) + 1
            end
            vel = phys:GetVelocity()
        end
    end
    if hasDriver and BMX.TryGrind and BMX.TryGrind(ent, phys, C, st, vel) then
        phys:Wake()
        return
    end

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
    -- LANDING SOAK: coming down out of the air (air mode is still set on the
    -- touchdown substep, which is the one that carries the blow) or just
    -- landed, with a rider aboard, the suspension's push is taken through the
    -- rider's legs rather than levered at the tyre. See Wheel:Simulate.
    local soak = hasDriver and (st.airMode or (st.recoverUntil or 0) > CurTime())
    front.soak, rear.soak = soak, soak

    -- PARKED: nobody aboard, on the stand, and nobody leaning on it. A parked
    -- wheel on a slope is held by the stick-slip anchor (Wheel:Simulate), which
    -- needs to know it is parked because nothing in its inputs says so: a
    -- parked bike has no brake held.
    local parked = not hasDriver and st.onStand
        and not ((st.pushedUntil or 0) > CurTime())
    front.hold, rear.hold = parked, parked

    local filter = ent.traceFilter
    front:Simulate(ent, phys, C, dt, 0,           brakeFront, filter)
    rear:Simulate (ent, phys, C, dt, driveTorque, brakeRear,  filter)

    -- The climbing push (see drivetrain): at the mass centre, along the slope.
    if hasDriver and st.climbDir and st.climbAccel > 0 and rear.onGround then
        phys:ApplyForceCenter(st.climbDir * (st.climbAccel * phys:GetMass() * dt))
    end

    ----------------------------------------------------------------------
    -- 4b. STICKING A LANDING (Crash.soakSpeed). The substep a wheel first
    -- touches down out of the air, with a rider aboard.
    ----------------------------------------------------------------------
    -- A hard landing can meet the ground with a wheel BOX before either
    -- suspension ray registers it (at landing speed the bike moves ~12 units
    -- a tick); PhysicsCollide marks that as a touchdown too (ent.bmxTouchdown).
    local touchdown = st.airMode and (front.onGround or rear.onGround or ent.bmxTouchdown)
    ent.bmxTouchdown = nil
    if hasDriver and touchdown then
        local CR = C.Crash
        local v = phys:GetVelocity()
        if v.z < -CR.soakSpeed then
            phys:ApplyForceCenter(Vector(0, 0, (-CR.soakSpeed - v.z) * phys:GetMass()))
        end
        -- The spin: all of it stops. Set on the engine's own angular velocity
        -- rather than torqued away against st.angVel, which is estimated from
        -- the last substep's rotation and trails a fast flip: cancelled that
        -- way, enough was left to carry a landed flip on over the bars.
        if CR.soakSpin >= 1 and (CR.soakRollSpin or 1) >= 1 then
            phys:SetAngleVelocity(vector_origin)
        else
            local w = st.angVel or vector_origin
            local r, f = ent:GetRight(), ent:GetForward()
            local k = CR.soakSpin
            BMX.ApplyTorque(phys, ent, r, BMX.TorqueFor(BMX.IPitch(ent), -w:Dot(r) * k / dt), dt)
            BMX.ApplyTorque(phys, ent, f, BMX.TorqueFor(BMX.IRoll(ent),
                -w:Dot(f) * (CR.soakRollSpin or k) / dt), dt)
        end
    end

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
        st.groundNormalRaw = n
        -- SMOOTHED. A floor's seams and undulations swing the raw normal tick
        -- to tick. Lean used to be held against it, and riding hands-off over
        -- bumps rolled the bike up to 16 degrees by itself (the live server
        -- showed 18); lean is now held against GRAVITY (BMX.BalanceUp), which
        -- bumps cannot touch, but pitch -- what a wheelie or a stoppie is
        -- judged on -- is still measured against this, and so is the steep-
        -- face blend. Followed at Balance.normalFollow it still tracks a real
        -- transition in a couple of tenths of a second. Taken RAW on
        -- touchdown, so a landing is judged on the surface it actually met.
        if not wasGrounded or not st.groundNormal then
            st.groundNormal = n
        else
            local k = min(1, C.Balance.normalFollow * dt)
            local sm = st.groundNormal + (n - st.groundNormal) * k
            st.groundNormal = sm:GetNormalized()
        end
    else
        st.groundNormal = Vector(0, 0, 1)
    end
    st.grounded = grounded
    st.groundedFor = grounded and (st.groundedFor or 0) + dt or 0

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
    -- 6a. FALLEN OVER WITH A RIDER ON IT. A crash used to be judged only on
    -- landing from the air, or on a hard hit; a bike that simply tipped onto
    -- its side on the ground kept its rider seated in it, lying sideways
    -- with their legs through the floor. Past tipRoll (or tipPitch: a looped
    -- wheelie) near the ground for tipTime, they come off. Near the ground,
    -- so a barrel roll in the air is not a crash until it lands wrong.
    ----------------------------------------------------------------------
    if hasDriver and C.Crash.enabled and CurTime() - (ent.spawnTime or 0) >= C.Crash.grace then
        local CR = C.Crash
        local over = abs(st.roll) > CR.tipRoll or abs(st.pitch) > CR.tipPitch
        if (st.recoverUntil or 0) > CurTime() then over = false end
        -- AT REST ON ITS SIDE, not falling past it. A barrel roll coming down
        -- passes within reach of the ground at 100 degrees of roll, and this
        -- rule threw its rider there, in mid-air, before the landing (which
        -- judges itself) had even happened. Measured on the live server.
        if abs(vel.z) > CR.tipMaxVz then over = false end
        local near = false
        if over then
            local com = phys:LocalToWorld(phys:GetMassCenter())
            near = util.TraceLine({ start = com, endpos = com - Vector(0, 0, 45),
                filter = ent.traceFilter, mask = MASK_SOLID }).Hit
        end
        if over and near then
            st.tippedFor = (st.tippedFor or 0) + dt
            if st.tippedFor >= CR.tipTime and ent.QueueCrash then
                ent:QueueCrash("tipped", 0.4)
            end
        else
            st.tippedFor = 0
        end
    end

    ----------------------------------------------------------------------
    -- 6b. Ground tricks. Only with a rider: a riderless bike that bounces on
    -- its front wheel is not doing a stoppie.
    ----------------------------------------------------------------------
    if hasDriver then
        local done = BMX.TrackManual(st, C, front, rear, speed, dt)
        if done and ent.AwardTricks then ent:AwardTricks(done) end
        -- Frame and bar spins, poses, anything registered (sv_tricks.lua):
        -- after the manual, so a bar spin knows whether one is under way.
        if BMX.TricksTick then
            local paid = BMX.TricksTick(ent, phys, C, dt, inp, st)
            if paid and ent.AwardTricks then ent:AwardTricks(paid) end
        end
        if BMX.ComboThink then BMX.ComboThink(ent, st) end
    else
        st.manual = nil
        if BMX.TricksIdle then BMX.TricksIdle(ent, st) end
        -- Got off with a combo open: it was landed, and it banks.
        if st.combo and BMX.ComboEnd then BMX.ComboEnd(ent, true) end
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

    -- 7a''. Water (sv_water.lua): drag per submerged wheel, from what the
    -- bike's Think last measured.
    if BMX.Water then BMX.Water.Drag(ent, phys, vel, dt) end

    ----------------------------------------------------------------------
    -- 7a'. Nobody aboard, rolling: scrub it down (Stand.riderlessDecel), so a
    -- bike let go of at speed rolls on for a few seconds and then falls,
    -- instead of coasting across the map balanced by an assist with no rider.
    ----------------------------------------------------------------------
    if not hasDriver and grounded and fwdSpeed ~= 0 then
        local dv = math.min(abs(fwdSpeed), C.Stand.riderlessDecel * dt)
        phys:ApplyForceCenter(fwd * (-(fwdSpeed > 0 and 1 or -1) * dv * phys:GetMass()))
    end

    ----------------------------------------------------------------------
    -- 7c. PARKED: held where it stands.
    --
    -- A bike on its stand is held by STATIC friction, which a slip-velocity
    -- tyre model does not have: it only ever answers a slip that already
    -- exists. Holding a parked bike with a locked brake was tried first and
    -- it CREPT, steadily, at 16 u/s: the locked tyre's force acts 27 units
    -- below the centre of mass, so each substep it "stopped" the contact
    -- patch mostly by pitching the chassis, the springs pitched it back, and
    -- the patch's motion that the tyre kept answering was the chassis's own
    -- settling. Measured on the tests' plant, never shipped.
    --
    -- So this models the stiction directly: bleed off the horizontal and yaw
    -- motion at the centre of mass, where it cannot pitch anything. Only
    -- while parked on the stand and slow, so a bike that is pushed hard, or
    -- knocked off its stand, moves like anything else.
    ----------------------------------------------------------------------
    -- AND NEVER AGAINST A PLAYER. With somebody touching the bike, the hold
    -- would be pinning it against them every substep: the bike pushed back
    -- into the player, and a player a prop is pushed into gets stuck in it.
    -- So the hold lets go and ordinary physics settles the push (ENT:Think
    -- sets pushedUntil).
    local touched = (st.pushedUntil or 0) > CurTime()
    if not hasDriver and st.onStand and not touched and speed < C.Balance.walkSpeed then
        -- Read NOW, after this substep's tyre forces, not the `vel` taken at
        -- the top of the step: removing that one leaves whatever the tyres
        -- just added, and the bike still slid at 0.2 u/s.
        local k = 1
        local vNow = phys:GetVelocity()
        local vh = Vector(vNow.x, vNow.y, 0)
        phys:ApplyForceCenter(vh * (-phys:GetMass() * k))
        -- HEADING, not just yaw rate. The tyres' sideways forces, reacting
        -- the stand's small steady lean error at the front and rear patches,
        -- sit at different distances from the mass centre and add up to a
        -- steady yaw torque. Damping the rate alone only slowed the result:
        -- a parked bike turned on the spot at 1.6 degrees a second. So the
        -- heading it was parked at is held, with the rate as the D term.
        local up = ent:GetUp()
        local f = ent:GetForward()
        local yaw = math.atan2(f.y, f.x)
        st.parkYaw = st.parkYaw or yaw
        local err = math.atan2(math.sin(st.parkYaw - yaw), math.cos(st.parkYaw - yaw))
        local wYaw = st.angVel:Dot(up)
        local alpha = 60 * err - 16 * wYaw
        BMX.ApplyTorque(phys, ent, up, BMX.TorqueFor(BMX.IYaw(ent), alpha), dt)
    else
        st.parkYaw = nil
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
            --
            -- ONLY FROM LEVEL. It fades out as the bike is already pitched up,
            -- and is gone by Hop.kickFade: from a wheelie it stacked on the
            -- wheelie's own rotation and sent the bike to 89 degrees, a
            -- backflip nobody asked for, measured on the tests' plant.
            local level = 1 - BMX.Ramp(st.pitch or 0, 0, H.kickFade)
            if level > 0 then
                BMX.ApplyTorque(phys, ent, ent:GetRight(),
                    BMX.TorqueFor(BMX.IPitch(ent), H.pitchImpulse * level / dt), dt)
            end

            ent.hopReady = CurTime() + H.cooldown
            local H = BMX.Sounds.hop
            if BMX.SoundsOn() then ent:EmitSound(BMX.SoundFile("hop"), H.level, 110, H.vol) end
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
