--[[--------------------------------------------------------------------------
    bmx/sh_config.lua

    Every tunable number in the simulation, in one table.

    UNITS. Source works in inches and kilograms:
        distance   1 unit  = 1 inch, 1 metre = 39.37 units
        mass       kilograms
        force      kg * units/s^2   (so F = m*a with a in units/s^2)
        torque     kg * units^2/s^2
        angles     RADIANS inside the simulation, degrees only at the edges

    Source gravity is 600 u/s^2. Real gravity is 386 u/s^2. The engine is
    therefore ~1.55x "heavy", which is why the derived-from-reality numbers
    below still need a tuning pass: a real BMX in Source gravity feels sluggish
    until the drive torque and grip are scaled up to match. Where a default came
    from a real-world figure the figure is named, so a future tuner knows which
    numbers are physics and which are taste.

    Anything here can be overridden per bike in sh_bikes.lua, and the ones a
    tuner touches every five minutes are also exposed as convars (see the
    CONVARS block at the bottom) so you can tune without a map reload.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Config = BMX.Config or {}

local C = BMX.Config

--------------------------------------------------------------------------
-- CHASSIS
--------------------------------------------------------------------------
C.Chassis = {
    -- Bike + rider. A BMX is ~11 kg, a rider ~75 kg. The rider is part of the
    -- sprung mass because we never simulate them separately.
    mass = 86,

    -- Collision hull, local space. Entity origin sits on the AXLE LINE (the
    -- height of both wheel centres), so the ground is at z = -10.
    --
    -- The hull is TALL because it stands in for the rider as well as the frame:
    -- a rider clips walls, and a hull that stops at the top tube lets them ride
    -- through one. Its floor is at z = +2, i.e. 12 units clear of the ground,
    -- because the raycast wheels hold the bike up and a hull that touches the
    -- ground fights them and makes the bike buzz.
    -- THE HULL IS ALSO THE MASS CENTRE, and that is not a coincidence to be
    -- tidied away later. **GMod has no PhysObj:SetMassCenter** -- GetMassCenter
    -- exists, the setter does not (verified on a live server, 2026-08-20). So
    -- the only way to place the centre of mass is to place the BOX: VPhysics
    -- puts the COM at the geometric centre of the hull it was given.
    --
    -- These bounds are therefore chosen to put the COM at (-2, 0, 20):
    --     x: (-18 + 14) / 2 = -2      slightly rearward, for the load split
    --     y: (-4  +  4) / 2 =  0
    --     z: (  2 + 38) / 2 = 20      a standing rider's mass above the axles
    --
    -- MOVING EITHER BOUND MOVES THE CENTRE OF MASS. The height is load-bearing:
    -- it sets the gravity torque the balance controller has to fight when
    -- leaning, and how readily rear drive force lifts the front, which is where
    -- wheelies come from without being scripted. Dropping it toward the axle is
    -- the classic arcade cheat; it makes the bike almost untippable and kills
    -- wheelies stone dead.
    --
    -- The entity verifies the actual COM against massCenterExpected at spawn
    -- and complains if they diverge, so this can never silently drift again.
    hullMin = Vector(-18, -4,  2),
    hullMax = Vector( 14,  4, 38),

    massCenterExpected = Vector(-2, 0, 20),

    -- Low-friction so the frame slides off geometry it clips instead of
    -- catching an edge and cartwheeling. Crash feel comes from the crash
    -- handler, not from hull friction.
    surfaceProp = "gmod_ice",

    -- Moments of inertia used by the balance/pitch controllers, kg*units^2.
    -- Deliberately NOT read from PhysObj:GetInertia(): VPhysics derives that
    -- from the collision hull, and our hull is a stand-in for a frame, not a
    -- mass distribution. Computed as m * k^2 with a radius of gyration k:
    --   roll  k ~ 16u  (rider is tall and narrow: hardest axis to flick)
    --   pitch k ~ 17u  (wheelbase dominates)
    --   yaw   k ~ 16u
    inertiaRoll  = 86 * 16 * 16,
    inertiaPitch = 86 * 17 * 17,
    inertiaYaw   = 86 * 16 * 16,

    -- Where the driver's seat sits, local space.
    seatOffset = Vector(-4, 0, 18),
    seatAngles = Angle(0, 0, 0),
}

--------------------------------------------------------------------------
-- WHEELS
--------------------------------------------------------------------------
-- A 20" BMX wheel is 20 inches across, so radius 10 units exactly. Wheelbase on
-- a park/street BMX is ~990 mm = 39 units. Source units being inches is the one
-- genuine convenience the engine offers this project.
C.Wheel = {
    radius    = 10,
    wheelbase = 39,

    -- Suspension travel. A BMX has no FORK, but it is not rigid: the tyre
    -- carcass deflects and, far more importantly, THE RIDER IS THE SUSPENSION.
    -- Legs and arms absorb impacts on a BMX, which is why riders stand up for
    -- anything rough. 6 units is ~15 cm of rider compliance, which is realistic
    -- and is what this spring actually represents.
    --
    -- The original 2.0 was "a BMX has no suspension, keep it tiny", and it was
    -- wrong twice over: physically, because it ignored the rider, and
    -- numerically, because 2 units of travel forces a 43,000 spring to carry
    -- the bike, and a 43,000 spring is not integrable at 66 Hz. See below.
    restLength = 6.0,

    -- Sized so each wheel carries m*g/2 at ~3u of sag, i.e. half its travel:
    --   k = (86*600/2) / 3 ~= 8600
    --
    -- THIS NUMBER IS BOUNDED BY THE TIMESTEP, not just by taste. The natural
    -- frequency the integrator sees is sqrt(k/m_eff), and m_eff at the contact
    -- patch is ~20 kg rather than the 43 kg per-wheel share, because the patch
    -- sits ~21 units from the centre of mass and pushing on it mostly pitches
    -- the bike (see the effective-mass note in sv_wheel.lua). At k = 43000 that
    -- is w = 47 rad/s and w*dt = 0.71, which rings hard and pumps energy in
    -- through the pitch coupling: measured 88,787 of load at 0.62 units of
    -- compression, against a 25,800 static, and a bike thrown 63 units up by
    -- being dropped 1.6. At k = 8600 it is w = 21 rad/s and w*dt = 0.32, which
    -- is comfortable.
    --
    -- If you raise this, check w*dt against the EFFECTIVE mass, not the mass.
    spring = 8600,
    -- ~0.6 of critical against the EFFECTIVE mass at the contact patch:
    -- critical is 2*sqrt(k*m_eff) = 2*sqrt(8600*19.8) = 825. The clamp in
    -- Wheel:Simulate makes any value here stable, so this is a feel number
    -- rather than a stability one, but sizing it against m_eff rather than the
    -- per-wheel share is what makes it feel the way the number says it should.
    damper = 500,
    -- Extra stiffness applied only past restLength, so hard landings bottom out
    -- against something instead of teleporting the hull through the floor.
    -- Kept to ~7x the main spring: stiff enough to be a real stop, soft enough
    -- that arriving at it is not its own explosion.
    bumpStop = 60000,

    -- Tyre model. Both stiffnesses are FORCE PER UNIT OF SLIP VELOCITY
    -- (kg/s), not the classic slip-RATIO stiffness. Slip ratio divides by
    -- ground speed and therefore blows up at a standstill, which is precisely
    -- the state a BMX spends a lot of its life in. Slip velocity has no such
    -- singularity and is stable from 0 to top speed with no special-casing.
    longStiffness = 2600,
    latStiffness  = 5200,

    -- Friction coefficient. Both tyre forces are clamped into a circle of
    -- radius grip*N, so this is the single number that decides when you slide.
    grip = 1.35,

    -- Ceiling on suspension force, as a multiple of the WHOLE bike's weight.
    -- A numerical backstop, not a physical effect: see the clamp in
    -- Wheel:Simulate. Normal riding peaks around 5-8x static on a hard landing,
    -- so 12 never engages in play and only catches the pathological substep.
    maxLoadFactor = 6,

    -- Rotating inertia of one wheel, kg*units^2. Solid-disc approximation for
    -- a 2.2 kg wheel+tyre at r=10: 0.5*m*r^2 = 110.
    inertia = 110,

    -- Coasting losses. Rolling resistance is proportional to load; drag is
    -- proportional to v^2 and is what actually sets the coasting top speed.
    rollingResistance = 0.012,
}

--------------------------------------------------------------------------
-- DRIVETRAIN
--------------------------------------------------------------------------
C.Drive = {
    -- 25t chainring / 9t driver = 2.78 wheel revolutions per crank revolution.
    gearRatio = 25 / 9,

    -- Peak crank torque, kg*units^2/s^2. A standing rider puts ~150 Nm through
    -- the cranks; 1 Nm = 39.37^2 = 1550 of our torque units, so 150 Nm is
    -- ~232000. Scaled up here because Source gravity is 1.55x real and an
    -- honest 150 Nm accelerates like a shopping trolley on the moon's evil twin.
    crankTorque = 300000,

    -- Cadence ceiling, rad/s at the crank. 120 rpm = 12.6 rad/s. Past this the
    -- rider is spinning out and contributes nothing, which is what caps top
    -- speed on the flat: 12.6 * 2.78 * 10 = ~350 u/s = ~32 km/h. Correct for a
    -- BMX, and deliberately slow compared to every other GMod vehicle.
    maxCadence = 12.6,

    -- Sprint multiplier on crank torque and cadence while IN_SPEED is held,
    -- drained from stamina below.
    sprintTorque  = 1.55,
    sprintCadence = 1.25,

    staminaMax     = 100,
    staminaDrain   = 34,   -- per second while sprinting
    staminaRegen   = 16,   -- per second while not

    -- Coasting: a BMX freewheel (or a fixed-gear cassette) never drives the
    -- cranks backwards, so no engine braking. Set to true for a fixed gear.
    fixedGear = false,

    -- Brake torques, kg*units^2/s^2, at the wheel. Most street BMXs run a rear
    -- brake only; the front is here because stoppies are half the point.
    rearBrake  = 95000,
    frontBrake = 150000,

    -- Aerodynamic drag: F = dragArea * v * |v|, so this is 0.5 * rho * Cd * A
    -- expressed in kg per UNIT, not per metre. For a rider on a bike
    -- 0.5 * 1.225 * 0.9 * 0.4 = 0.22 kg/m, and 0.22 / 39.37 = 0.0056.
    --
    -- IT DOES NOT GET THE GRAVITY SCALING. Drive torque is scaled up because
    -- Source pulls 1.55x harder than the real world; drag has nothing to do
    -- with gravity and scaling it too just makes a slow bike.
    --
    -- This was 0.10, eighteen times too much, and it was invisible for as long
    -- as the tyre bug stopped the bike from ever reaching a speed where drag
    -- mattered. Once the bike could actually accelerate, it measured a terminal
    -- 198 u/s against a closed-form prediction of 200 -- the drivetrain model
    -- agreeing with itself perfectly, at the wrong answer. The give-away is in
    -- the cadence: the design says top speed is capped by the RIDER SPINNING
    -- OUT (see maxCadence), and at 0.10 the bike settles at 0.57 of maximum
    -- cadence, which means it was drag-limited and the whole cadence ceiling
    -- was decorative. At 0.0056 terminal is 312 u/s at 0.89 of cadence, which
    -- is the model the rest of this block describes.
    dragArea = 0.0056,
}

--------------------------------------------------------------------------
-- BALANCE AND STEERING
--
-- This block is where the GTA feel lives, so read the comments before touching
-- the numbers.
--
-- The model is DRIVEN LEAN, not simulated balance. Player input sets a TARGET
-- roll angle; a PD controller drives actual roll to it; the front wheel's steer
-- angle is then DERIVED from the roll that resulted. Steering is an output, not
-- an input. That single inversion is most of what makes a GTA bike feel like a
-- GTA bike, and it is why binding A/D straight to steer never does.
--------------------------------------------------------------------------
C.Balance = {
    maxLean = math.rad(42),     -- how far the rider can commit

    -- The PD holding roll on target. Kp is in 1/s^2, Kd in 1/s. Critical-ish
    -- damping is Kd = 2*sqrt(Kp); a little under feels alive, a lot under
    -- oscillates and reads as "twitchy".
    leanKp = 26,
    leanKd = 9.0,

    -- Ceiling on the assist's angular acceleration, rad/s^2. This is the
    -- difference between an arcade bike and one on rails: with no cap, no
    -- landing can ever go wrong because the controller simply undoes it.
    --
    -- Sized against the gravity torque the assist has to beat at full lean:
    --   T_gravity = m * g * h * sin(maxLean)
    --             = 86 * 600 * 20 * sin(42) = 690,000
    --   alpha_min = T_gravity / I_roll = 690000 / 9299 = 74 rad/s^2
    --
    -- NOTE THE DENOMINATOR. This was originally derived against the invented
    -- inertia of 22,016, which gave 31 and made 45 look like a 1.4x margin. The
    -- REAL roll inertia is 9,299 (VPhysics, measured), so 45 was in fact well
    -- BELOW the requirement: the balance controller could not hold the bike up
    -- at any lean worth having, at full authority, and the bike fell over while
    -- every diagnostic said the assist was working perfectly.
    --
    -- 110 leaves ~1.5x margin over the 74 needed. Most of that requirement is
    -- now met by the gravity feed-forward in sv_balance.lua rather than by the
    -- PD, so this is a ceiling on total authority rather than the working value.
    -- It still needs to be finite: it is the only thing that lets a bad landing
    -- beat the assist.
    maxAssistAccel = 110,

    -- Assist authority against speed, u/s. Below fadeInLow the bike is on its
    -- own and will fall over (correct: a stationary bike does). Full authority
    -- by fadeInHigh.
    fadeInLow  = 25,
    fadeInHigh = 110,

    -- Below this the rider is "walking" the bike and gets direct steering
    -- instead of lean-derived steering, so you can turn round on the spot.
    walkSpeed = 45,

    maxSteer = math.rad(38),

    -- Trail/self-centring: mild damping on the derived steer angle so the front
    -- end does not chatter over bumps.
    steerRate = 9.0,
}

--------------------------------------------------------------------------
-- PITCH: WHEELIES, STOPPIES, MANUALS
--------------------------------------------------------------------------
C.Pitch = {
    -- Direct rider torque about the local right axis, kg*units^2/s^2. Applied
    -- on the ground; the air block below has its own.
    torque = 1050000,

    -- Wheelie hold assist. Once the front wheel is up, a PD holds pitch near
    -- the rider's target so the bike does not instantly loop out. Without this
    -- a wheelie is a 0.4 second event and nobody can use it.
    holdKp = 9,
    holdKd = 4.2,
    holdMax = math.rad(48),      -- beyond this you are looping out, no help
    stoppieMax = math.rad(-40),

    -- Pitch damping on the ground, so the bike settles instead of porpoising.
    groundDamping = 2.6,
}

--------------------------------------------------------------------------
-- AIR
--------------------------------------------------------------------------
C.Air = {
    -- Angular accelerations in the air, rad/s^2. These are large: air control
    -- in GTA (and in a real bike whip) is much more authoritative than anything
    -- available on the ground.
    pitchAccel = 15.0,
    rollAccel  = 13.0,
    yawAccel   = 4.0,          -- deliberately weak; bikes barely yaw in the air

    -- Damping so releasing the stick stops the rotation rather than leaving you
    -- spinning like a thrown prop.
    damping = 1.5,

    -- Very light pull back toward upright, applied only when descending. GTA
    -- does this subtly and it is why casual play does not end in a crash every
    -- jump. Set to 0 for a pure simulation.
    autoLevel = 1.6,

    -- Both wheels must be off the ground for this long before air mode engages,
    -- so a bump in the road is not a "trick".
    engageDelay = 0.08,
}

--------------------------------------------------------------------------
-- BUNNY HOP
--------------------------------------------------------------------------
C.Hop = {
    -- Preload: hold IN_DUCK to compress, release to pop. Charge ramps 0 -> 1
    -- over chargeTime; releasing early gives a proportionally smaller hop.
    chargeTime = 0.42,
    minCharge  = 0.25,

    -- Vertical velocity added at full charge, u/s. 260 u/s against 600 u/s^2
    -- gravity is ~56 units of air = ~1.4 m. A very good rider hops ~1 m, and
    -- this is a videogame.
    popSpeed = 265,

    -- Fraction of pop applied forward, so a hop clears an obstacle rather than
    -- landing on it.
    forwardBias = 0.22,

    -- Nose-up impulse at the pop, rad/s, so hops naturally start a manual.
    pitchImpulse = 1.9,

    cooldown = 0.25,
}

--------------------------------------------------------------------------
-- CRASHING
--------------------------------------------------------------------------
C.Crash = {
    enabled = true,

    -- On regaining ground contact, the landing is bad if the bike is further
    -- than this off the surface normal.
    maxLandAngle = math.rad(52),

    -- ...or if it is moving sideways faster than this at the contact patch.
    maxLandLateral = 210,

    -- Impact into geometry: chassis hull collision above this speed throws the
    -- rider regardless of angle.
    maxImpactSpeed = 430,

    -- Damage dealt to the ejected rider, scaled by how bad it was.
    damageScale = 0.09,

    -- Ejection: rider keeps the bike's velocity plus a bit of lift, which reads
    -- as being thrown rather than teleported.
    ejectLift = 120,

    -- Grace period after spawning or entering, so a bike dropped by the spawn
    -- menu does not immediately eject its first rider.
    grace = 1.0,
}

--------------------------------------------------------------------------
-- CONVARS
--
-- Only the numbers a tuner reaches for repeatedly. Everything else is a code
-- edit on purpose: a hundred convars is not a tuning interface, it is a haystack.
--------------------------------------------------------------------------
C.ConVars = {
    -- name              default                          field path
    { "bmx_lean_kp",     C.Balance.leanKp,                "Balance.leanKp"      },
    { "bmx_lean_kd",     C.Balance.leanKd,                "Balance.leanKd"      },
    { "bmx_max_lean",    math.deg(C.Balance.maxLean),     "Balance.maxLean",     true },
    { "bmx_grip",        C.Wheel.grip,                    "Wheel.grip"          },
    { "bmx_spring",      C.Wheel.spring,                  "Wheel.spring"        },
    { "bmx_damper",      C.Wheel.damper,                  "Wheel.damper"        },
    { "bmx_crank",       C.Drive.crankTorque,             "Drive.crankTorque"   },
    { "bmx_pitch",       C.Pitch.torque,                  "Pitch.torque"        },
    { "bmx_hop",         C.Hop.popSpeed,                  "Hop.popSpeed"        },
    { "bmx_air_pitch",   C.Air.pitchAccel,                "Air.pitchAccel"      },
    { "bmx_air_roll",    C.Air.rollAccel,                 "Air.rollAccel"       },
    { "bmx_autolevel",   C.Air.autoLevel,                 "Air.autoLevel"       },
}

-- Live-tuning plumbing. A convar whose fourth element is true is authored in
-- DEGREES and stored in radians, because typing 42 in a console is humane and
-- typing 0.733 is not.
--
-- These are REPLICATED, which means only the server may create them: calling
-- CreateConVar with FCVAR_REPLICATED on a client is an error. The client
-- receives them automatically and reads them through GetConVar like any other.
function BMX.SetupConVars()
    if not SERVER then return end

    for _, row in ipairs(C.ConVars) do
        local name, default, path = row[1], row[2], row[3]
        CreateConVar(name, tostring(default),
            bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY),
            "BMX tuning: " .. path)
    end
end

-- Pull convar values into the config table. Called at 20 Hz from the bike's
-- Think, and once from the client HUD, so a tuner sees a change on the next
-- tick instead of having to respawn the bike.
--
-- Runs on both realms: the client draws wheels and a HUD from the same table,
-- and a lean limit that differs between the two would show up as a camera that
-- disagrees with the bike.
function BMX.ApplyConVars()
    for _, row in ipairs(C.ConVars) do
        local name, _, path, isDegrees = row[1], row[2], row[3], row[4]
        local cv = GetConVar(name)
        if cv then
            local v = cv:GetFloat()
            if isDegrees then v = math.rad(v) end
            local group, key = string.match(path, "^(%w+)%.(%w+)$")
            if group and C[group] then C[group][key] = v end
        end
    end
end
