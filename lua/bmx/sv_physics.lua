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

    -- THE PUSH OF EVERYONE PEDALLING (G13, sv_tandem.lua): the driver's throttle plus a
    -- stoker's, each 0..1, so a tandem's torque is the sum of its two riders'. For every
    -- other vehicle it is the driver's alone, the number it always was.
    local thr = inp.throttle + (BMX.Tandem and BMX.Tandem.Push(ent, inp) or 0)

    local tq  = D.crankTorque * (sprinting and D.sprintTorque  or 1)
    local cad = D.maxCadence  * (sprinting and D.sprintCadence or 1)

    -- Crank speed implied by the rear wheel through the gear.
    local gearRatio = BMX.GearRatio(ent, cfg)       -- the bike's, or the current gear's (sh_gears.lua)
    local crankOmega = rear.omega / gearRatio
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
    if D.climbAssist and D.climbAssist > 0 and rear.onGround and thr > 0 then
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
                    * f.z * (1 - spin) * thr * wall
            end
        end
    end

    local crank = tq * (1 - spin) * thr

    -- Paddling backwards. A rider at a standstill holding the "brake" key
    -- expects to be able to walk the bike back, not to stand there. Only
    -- available below walking pace, where the brake would do nothing anyway.
    if inp.brakeRear > 0 and st.speed < 40 and rear.omega < 1 then
        crank = crank - tq * 0.16 * inp.brakeRear
    end

    st.sprinting = sprinting
    return crank / gearRatio
end

--------------------------------------------------------------------------
-- THE DRIVES (G22). What turns the rider's keys into wheel torque is the
-- vehicle's `drive = { kind = ... }`, and each kind is a function
--
--     drive(ent, cfg, dt, inp, st, wheel, vdef) -> torque
--
-- where `wheel` is the first wheel marked drive = true (the rear, on a bike) and
-- the result is the torque for the WHOLE vehicle, which the step splits evenly
-- between the drive wheels. `pedal` is the function above, untouched.
--------------------------------------------------------------------------
BMX.Drives = BMX.Drives or {}
BMX.Drives.pedal = function(ent, cfg, dt, inp, st, wheel) return drivetrain(ent, cfg, dt, inp, st, wheel) end

-- A motor: the throttle's torque, falling away linearly to nothing at maxSpeed,
-- which is what makes the speed a limit rather than a number somebody tuned a
-- drag term to hit. Reversing is the brake key's, as everywhere (inp.brakeRear
-- is a brake, not a gear): a throttle vehicle does not back up.
BMX.Drives.throttle = function(ent, cfg, dt, inp, st, wheel, vdef)
    local d = vdef.drive
    local top = d.maxSpeed or 400
    local fall = BMX.Clamp(1 - (st.fwdSpeed or 0) / top, 0, 1)
    st.cadence = wheel and wheel.omega or 0
    return d.torque * inp.throttle * fall
end

-- A COASTER BRAKE (G12): the bike's legs, freewheeling. What makes it a coaster is
-- not in the drive but around it: its input map (bike_rearonly) gives it no front
-- brake, and S is the rear brake, which is how a coaster is braked.
BMX.Drives.coaster = BMX.Drives.pedal

BMX.Drives.none = function() return 0 end

-- The drive a vehicle entity runs, or the one that does nothing, with a single
-- loud message for a kind that has no function yet (`push`, until G23).
local driveWarned = {}
function BMX.DriveFor(ent)
    local def = ent.Bike and ent:Bike()
    local kind = def and def.drive and def.drive.kind or "pedal"
    local fn = BMX.Drives[kind]
    if fn then return fn, def end
    if not driveWarned[kind] then
        driveWarned[kind] = true
        ErrorNoHalt(string.format("[BMX] drive kind %q has no implementation; vehicles " ..
            "that name it do not drive.\n", tostring(kind)))
    end
    return BMX.Drives.none, def
end

--------------------------------------------------------------------------
-- THE AXLES. The single-track code, the landing judge and the manual tracker
-- speak of "the front wheel" and "the rear wheel". With N wheels an axle is the
-- group of wheels with that role: ONE wheel stands for itself (so the bike sees
-- exactly the wheel objects it always did), and several are summarised -- on the
-- ground if any is, the worst sideways slip, the fastest spin. No wheel at all
-- gives an axle that is never on the ground.
--------------------------------------------------------------------------
local function axleOf(group)
    if #group == 1 then return group[1] end
    local a = { onGround = false, slipLat = 0, slipLong = 0, omega = 0, load = 0,
                contactNorm = Vector(0, 0, 1), wheels = group }
    for _, w in ipairs(group) do
        if w.onGround then a.onGround, a.contactNorm = true, w.contactNorm end
        a.slipLat  = max(a.slipLat,  abs(w.slipLat  or 0))
        a.slipLong = max(a.slipLong, abs(w.slipLong or 0))
        a.omega    = max(a.omega, w.omega or 0)
        a.load     = a.load + (w.load or 0)
    end
    return a
end

function BMX.Axles(wheels)
    local f, r = {}, {}
    for _, w in ipairs(wheels) do
        local g = w.isFront and f or r
        g[#g + 1] = w
    end
    return axleOf(f), axleOf(r)
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

    -- A BIKE ON A RACK OR LOCKED (G13) is a prop on the car or on the world: it welds
    -- to its carrier through the constraint system, and running the tyre model against
    -- a car body it is bolted to would only shake the pair of them.
    if ent.BMXRack then phys:Wake() return end

    ----------------------------------------------------------------------
    -- 0. MOVED BY SOMETHING ELSE THIS TICK (a SetPos on the physics object: a
    -- teleport, a respawn, a script putting the bike somewhere). The physics
    -- object is already there; the entity's transform, which the wheels cast
    -- from (ent:LocalToWorld), still says where it was, until the tick ends.
    -- Run a substep now and every wheel finds the OLD ground and pushes on the
    -- new body with a lever arm the length of the jump: a skateboard put 600
    -- units away spun at 1,600 deg/s and went end over end before it had
    -- rolled a unit (measured on a real server). Within a tick the entity
    -- lags the body by at most the tick's own motion, so a gap well past that
    -- is a teleport: no forces this substep, and the wheels forget the ground
    -- they had (their compression and any pinned contact patch).
    ----------------------------------------------------------------------
    local gap = (phys:GetPos() - ent:GetPos()):Length()
    if gap > 16 + phys:GetVelocity():Length() * engine.TickInterval() * 2 then
        for _, w in ipairs(wheels) do w.lastComp, w.anchor = nil, nil end
        st.preVel, st.preAngV = nil, nil
        return
    end

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

    ----------------------------------------------------------------------
    -- 2c. RODE INTO SOMETHING THAT STAYS PUT (Crash.impactSoak). The hull hit
    -- a post, a goal or a kerb's face from the side on the last substep
    -- (ENT:NoteImpact); VPhysics has already stopped it, and with the stop
    -- came a lever's worth of spin and a pop off the low wheel box. Against
    -- the motion as it was at the end of the last substep (st.preVel/preAngV,
    -- below): most of the new spin goes, the bike gains no more than
    -- impactPop upward and comes back off the obstacle at no more than
    -- impactBounce. It still stops: speed INTO the obstacle is VPhysics's.
    ----------------------------------------------------------------------
    local imp = ent.bmxImpact
    ent.bmxImpact = nil
    -- ONTO A SLOPE (imp.ramp): a tyre rolling onto it keeps the motion along
    -- its surface and loses only what went into it. The wheel's box corner
    -- meeting the foot of a 36-unit quarter pipe at 183 u/s left 60 (the
    -- bike stalled at the foot one ride in five); what survives here is the
    -- motion it had, slid onto the slope's plane, never more than VPhysics
    -- left plus that.
    if imp and imp.ramp and hasDriver and st.preVel then
        local CR = C.Crash
        local w0, w1 = st.preAngV, phys:GetAngleVelocity()
        phys:SetAngleVelocity(w0 + (w1 - w0) * (CR.impactKeepSpin or 0))
        local n = imp.normal:GetNormalized()
        if st.preVel:Dot(n) > 0 then n = -n end         -- out of the slope, toward the bike
        local along = st.preVel - n * st.preVel:Dot(n)
        local v = phys:GetVelocity()
        if along:Length() > v:Length() and BMX.FiniteVec(along) then phys:SetVelocity(along) end
        st.rampHits = (st.rampHits or 0) + 1
        imp = nil
    end
    if imp and hasDriver and st.preVel then
        local CR = C.Crash
        local w0, w1 = st.preAngV, phys:GetAngleVelocity()
        phys:SetAngleVelocity(w0 + (w1 - w0) * (CR.impactKeepSpin or 0))
        local v = phys:GetVelocity()
        local zCap = max(st.preVel.z, 0) + (CR.impactPop or 0)
        if v.z > zCap then v.z = zCap end
        local nIn = imp.normal
        if nIn:LengthSqr() > 1e-6 then
            nIn = nIn:GetNormalized()
            if st.preVel:Dot(nIn) < 0 then nIn = -nIn end
            local back = -v:Dot(nIn)
            local cap = CR.impactBounce or 0
            if back > cap then v = v + nIn * (back - cap) end
        end
        -- A HARD STOP: most of a fast approach taken out in one hit. The rider
        -- plants rather than letting the bike rotate on, so the pitch and roll
        -- it was ALREADY turning at go too (yaw stays: a glance still turns
        -- it). Riding up a 36-unit park quarter pipe, scrapes on the way up
        -- had the nose turning up at 250 deg/s when the front wheel met the
        -- vertical top; kept, that looped the bike over backwards onto its
        -- side and threw the rider half the time.
        local inBefore = st.preVel:Dot(nIn)
        if inBefore > (CR.impactStopSpeed or math.huge)
            and math.max(v:Dot(nIn), 0) < inBefore * (1 - (CR.impactStopFrac or 1)) then
            local w = phys:GetAngleVelocity()
            phys:SetAngleVelocity(Vector(0, 0, w.z))
            st.hardStops = (st.hardStops or 0) + 1
        end
        if BMX.FiniteVec(v) then phys:SetVelocity(v) end
        st.impactAt = CurTime()
        st.impacts = (st.impacts or 0) + 1
    end

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
        st.preVel = nil
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
        st.preVel = nil
        phys:Wake()
        return
    end

    ----------------------------------------------------------------------
    -- 3. Drivetrain and brakes
    ----------------------------------------------------------------------
    local front, rear = BMX.Axles(wheels)

    -- THE DRIVE: the vehicle's own (BMX.Drives), and the wheels it turns. A
    -- bike's is the pedal drive on its one drive wheel, the rear.
    local drive, vdef = BMX.DriveFor(ent)
    local driveWheel, nDrive = nil, 0
    for _, w in ipairs(wheels) do
        if w.drive then
            driveWheel = driveWheel or w
            nDrive = nDrive + 1
        end
    end
    -- A drive returns its torque and, optionally, a say in the rear brake: nil
    -- leaves the rule below, true KEEPS the brake whatever the sign of the torque,
    -- false DROPS it. The fixed gear (sv_fixie.lua) needs both: its legs' torque on
    -- the wheel is negative whenever it is slowing down, and a skid stop must not
    -- be mistaken for pedalling backwards -- but S at a standstill is exactly that.
    local driveTorque, brakeSay = 0, nil
    if hasDriver then driveTorque, brakeSay = drive(ent, C, dt, inp, st, driveWheel, vdef) end
    driveTorque = driveTorque or 0
    local brakeRear   = inp.brakeRear  * C.Drive.rearBrake
    local brakeFront  = inp.brakeFront * C.Drive.frontBrake

    -- Paddling backwards is a drive, not a brake, so do not do both at once.
    if brakeSay == false or (driveTorque < 0 and brakeSay == nil) then brakeRear = 0 end

    ----------------------------------------------------------------------
    -- 4. Wheels
    ----------------------------------------------------------------------
    -- LANDING SOAK: coming down out of the air (air mode is still set on the
    -- touchdown substep, which is the one that carries the blow) or just
    -- landed, with a rider aboard, the suspension's push is taken through the
    -- rider's legs rather than levered at the tyre. See Wheel:Simulate.
    local soak = hasDriver and (st.airMode or (st.recoverUntil or 0) > CurTime())
    for _, w in ipairs(wheels) do w.soak = soak end

    -- PARKED: nobody aboard, on the stand, and nobody leaning on it. A parked
    -- wheel on a slope is held by the stick-slip anchor (Wheel:Simulate), which
    -- needs to know it is parked because nothing in its inputs says so: a
    -- parked bike has no brake held.
    local parked = not hasDriver and st.onStand
        and not ((st.pushedUntil or 0) > CurTime())
    for _, w in ipairs(wheels) do w.hold = parked end

    -- EVERY WHEEL, in list order (a bike's is front, then rear). The drive
    -- torque is shared out between the wheels marked drive; a wheel's brake is
    -- its axle's: the front brake on the front axle, the rear on the others.
    local filter = ent.traceFilter
    local share = nDrive > 0 and driveTorque / nDrive or 0
    -- More than two wheels read the chassis's motion as it was at the top of the
    -- substep (see ENT:Initialize on `coupling`); a bike's two take it live.
    local snap
    if #wheels > 2 then
        snap = { v = phys:GetVelocity(), w = st.angVel or vector_origin,
                 com = phys:LocalToWorld(phys:GetMassCenter()) }
    end
    for _, w in ipairs(wheels) do
        w:Simulate(ent, phys, C, dt, w.drive and share or 0,
            w.isFront and brakeFront or brakeRear, filter, snap)
    end

    -- A PASSENGER'S WEIGHT, where they sit rather than at the mass centre
    -- (sv_passenger.lua): a couple, no net force.
    if ent.paxMass and ent.paxMass > 0 and BMX.Passenger and BMX.Passenger.ApplyWeight then
        BMX.Passenger.ApplyWeight(ent, phys, dt)
    end

    -- The climbing push (see drivetrain): at the mass centre, along the slope.
    if hasDriver and st.climbDir and st.climbAccel > 0 and driveWheel and driveWheel.onGround then
        phys:ApplyForceCenter(st.climbDir * (st.climbAccel * phys:GetMass() * dt))
    end

    ----------------------------------------------------------------------
    -- 4b. STICKING A LANDING (Crash.soakSpeed). The substep a wheel first
    -- touches down out of the air, with a rider aboard.
    ----------------------------------------------------------------------
    -- A hard landing can meet the ground with a wheel BOX before either
    -- suspension ray registers it (at landing speed the bike moves ~12 units
    -- a tick); PhysicsCollide marks that as a touchdown too (ent.bmxTouchdown).
    local anyDown = false
    for _, w in ipairs(wheels) do if w.onGround then anyDown = true end end
    local touchdown = st.airMode and (anyDown or ent.bmxTouchdown)
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
    -- 4c. NO BOUNCE OFF A LANDING (Crash.reboundSpeed). Just landed, with a
    -- rider aboard and a wheel down: what the springs give back pushing the
    -- bike up off the ground, past reboundSpeed along the ground's normal, is
    -- taken off at the mass centre -- the rider's legs soak the landing and do
    -- not spring it back. Without it a 113-unit drop on the live park came
    -- back up at 56 u/s, the rear wheel left the ground and then the front: a
    -- see-saw on the two tyres. Along the normal, so riding on up a slope is
    -- untouched; never just after a hop (the pop is the rider meaning it).
    ----------------------------------------------------------------------
    local CR = C.Crash
    if hasDriver and anyDown and CR.reboundSpeed and (st.landedAt or -1) + (CR.reboundWindow or 0) > CurTime()
        and CurTime() - (st.hopAt or -1) > 0.3 and not ent.hopHeld then
        local n = st.groundNormal or vector_up
        local v = phys:GetVelocity()
        local vn = v:Dot(n)
        if vn > CR.reboundSpeed then
            phys:ApplyForceCenter(n * ((CR.reboundSpeed - vn) * phys:GetMass()))
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
    local grounded = anyDown

    -- The mean of the contact normals of every wheel on the ground, summed in
    -- list order (a bike's: front, then rear).
    local n = Vector()
    local c = 0
    for _, w in ipairs(wheels) do
        if w.onGround then n = n + w.contactNorm; c = c + 1 end
    end
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
        -- THE SURFACE LEFT, remembered: air mode engages a little after the
        -- wheels have gone and a wheel in the air reports no normal, so the
        -- takeoff is classified against the last one that was on the ground
        -- (BMX.Launch.Classify, G06). The raw mean, not the smoothed one: the
        -- smoothing lags a quarter pipe's curve by its own time constant.
        st.launchNormal = st.groundNormalRaw

        -- THE VEHICLE'S BALANCE MODE (sv_balance.lua): singletrack for a bike,
        -- none for something that stands on its own wheels.
        local mode = BMX.BalanceFor(ent)
        mode.Ground(ent, phys, C, dt, inp, st, wheels, st.groundNormal, speed)
        mode.Pitch(ent, phys, C, dt, inp, st, wheels)

        -- STEER BY FUNCTION. A wheel whose `steer` is a function takes its angle
        -- from it every grounded substep, after the balance has run (so it may
        -- read the roll it just produced): a board's truck lean, a cart's
        -- wheels following the key. "fork" wheels were steered by the balance.
        local steered
        for _, w in ipairs(wheels) do
            if type(w.steerMode) == "function" then
                w.steer = w.steerMode(w, ent, st, inp, C, dt, speed) or 0
                steered = steered or w
            end
        end
        if steered then st.steer = steered.steer end
    else
        st.airSince = st.airSince + dt
        if not st.airMode and st.airSince >= C.Air.engageDelay then
            st.airMode = true
            BMX.AirReset(st)
            -- WHAT KIND OF TAKEOFF (G06): ramp, vert or flat, from the surface
            -- just left and the velocity now. After AirReset, which clears
            -- what the last air decided.
            if BMX.Launch and BMX.Launch.Classify then
                st.launchKind = BMX.Launch.Classify(st.launchNormal, vel, C)
            end
            st.launchZ = phys:LocalToWorld(phys:GetMassCenter()).z
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
        -- Wheelies and stoppies, for a vehicle whose trick list has them.
        if BMX.VehicleAllows(vdef, "wheelie") or BMX.VehicleAllows(vdef, "stoppie") then
            local done = BMX.TrackManual(st, C, front, rear, speed, dt)
            if done and ent.AwardTricks then ent:AwardTricks(done) end
        end
        -- Frame and bar spins, poses, anything registered (sv_tricks.lua):
        -- after the manual, so a bar spin knows whether one is under way.
        if BMX.TricksTick then
            local paid = BMX.TricksTick(ent, phys, C, dt, inp, st)
            if paid and ent.AwardTricks then ent:AwardTricks(paid) end
        end
        if BMX.ComboThink then BMX.ComboThink(ent, st) end
        -- THE BALANCE MODE'S OWN TICK, if it has one: the skateboard's ollie, lean
        -- and tricks (sv_board.lua), which run in the air as well as on the ground.
        local mode = BMX.BalanceFor(ent)
        if mode.Tick then mode.Tick(ent, phys, C, dt, inp, st, vdef) end
    else
        st.manual = nil
        if BMX.TricksIdle then BMX.TricksIdle(ent, st) end
        local idle = BMX.BalanceFor(ent).Idle
        if idle then idle(ent, st) end
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
    -- 7d. HELD ON THE BRAKE: a rider stopped with a brake locked and its
    -- contact patch pinned (the stick-slip anchor, Wheel:Simulate), both
    -- wheels down, no pedalling either way. Static friction again, and for the reason 7c
    -- gives: the anchor's spring is sized on the mass the PATCH feels, which
    -- with the chassis free to pitch about it is a fraction of the bike (9 kg
    -- of 86 on the front, facing down 20 degrees). Against the whole bike that
    -- spring is soft and a third damped: the bike sagged 3 u and swung on it
    -- for three seconds at 1-3 u/s, and on 10 degrees facing up it never
    -- caught at all (holds_on_slope, real server). So the horizontal motion is
    -- bled off at the mass centre while the anchor holds; the anchor's own
    -- friction limit still decides whether it holds, and a bike that slides
    -- (anchor let go) or is ridden off is untouched.
    ----------------------------------------------------------------------
    -- THE FRONT BRAKE, not merely a pinned patch: S at a standstill is the
    -- paddle-backwards key (drivetrain), and holding that bike still is
    -- holding the rider's feet (tests/test_sim.lua, "S at a standstill").
    if hasDriver and inp.throttle <= 0 and (inp.brakeRear or 0) <= 0 and brakeFront > 0
        and speed < (C.Wheel.brakeStickSpeed or 0) then
        local pinned, down = false, true
        for _, w in ipairs(wheels) do
            if w.anchor then pinned = true end
            if not w.onGround then down = false end
        end
        if pinned and down then
            local vNow = phys:GetVelocity()
            phys:ApplyForceCenter(Vector(vNow.x, vNow.y, 0) * -phys:GetMass())
            st.brakeHeld = true
        else
            st.brakeHeld = nil
        end
    else
        st.brakeHeld = nil
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

        -- G30 (bmx_lagcomp): a release pressed while the bike was still on the
        -- ground counts, though it has left it by the time the command arrived.
        local pressedGrounded = grounded
            or (BMX.LagCompGrace and BMX.LagCompGrace(ent, ent.hopReleaseAge))
        ent.hopReleaseAge = nil
        if pressedGrounded and hasDriver and CurTime() >= (ent.hopReady or 0) then
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
            st.hopAt = CurTime()
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

    -- The motion this substep leaves the bike with, every force above
    -- applied: what an impact on the next one is measured against (2c).
    st.preVel, st.preAngV = phys:GetVelocity(), phys:GetAngleVelocity()
end
