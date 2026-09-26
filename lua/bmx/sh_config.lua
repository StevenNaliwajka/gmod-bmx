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

    -- THE WHEELS HAVE VOLUME TOO, for the ground to push on when the bike is
    -- down. The suspension is raycasts with no collision, so a bike on its
    -- nose or side used to put its wheels into the floor: the front wheel
    -- reaches 15 units past the body box and 12 below it. Each wheel gets a
    -- slim box -- the tyre's width, its full diameter fore and aft, and down
    -- to wheelHullBottom below the axle line.
    --
    -- The box's floor is DERIVED, at -(radius - restLength): it meets flat
    -- ground exactly where the suspension runs out of travel. So it never
    -- touches while riding and it IS the hard stop on a big landing. It was a
    -- written-down -4, right only for one travel; one unit short of it and a
    -- 40-unit drop overcompressed to 3.26, drawing the tyres into the ground.
    -- See BMX.CollisionBoxes: the body box is SHIFTED so the whole shape's
    -- mass centre stays at massCenterExpected.
    wheelHullHalfWidth = 1.6,

    -- AND THE BARS. They reach 14.5 units out each side, against 4 for the
    -- body box, so a bike lying on its side put its lower bar end 10 units
    -- into the floor. A slim box across them, where cl_init draws them (at
    -- the stock wheelbase; scaled with it), is what it lies on instead. High
    -- enough never to touch while riding: at full lean the bar ends are ~17
    -- units off the ground.
    barHullCentre = Vector(10.5, 0, 29),
    barHullHalf   = Vector(2.5, 14.8, 1.5),

    -- ...AND THE PEGS, which stick out 6.6 units each side of each axle: past
    -- the wheel box, so a bike on its side had them 2.6 units into the floor.
    -- Their own small box per axle, from the axle line UP. The wheel box
    -- could not simply be widened: its bottom corners would then touch down
    -- in a hard corner. This one clears the ground by a unit at full lean.
    pegHullHalfWidth = 6.6,

    massCenterExpected = Vector(-2, 0, 20),

    -- Low-friction so the frame slides off geometry it clips instead of
    -- catching an edge and cartwheeling. Crash feel comes from the crash
    -- handler, not from hull friction.
    surfaceProp = "gmod_ice",

    -- ...and once it has FALLEN OVER, the opposite. Ice is right for a hull
    -- that brushes a wall at speed; it is wrong for a bike lying on its side,
    -- which then skated off across the map on it. A fallen bike's hull grips
    -- like the metal frame it is, and goes back to ice when it is upright.
    fallenSurfaceProp = "metal",

    -- FALLBACK moments of inertia, kg*units^2. THESE ARE NOT WHAT RUNS.
    --
    -- The live values come from PhysObj:GetInertia() via BMX.CacheInertia, and
    -- these are only reached if that returns nothing usable -- which would also
    -- print an error. Tuning them does nothing on a healthy bike.
    --
    -- The comment here used to say the opposite: "deliberately NOT read from
    -- GetInertia, because VPhysics derives it from the collision hull and our
    -- hull is a stand-in for a frame, not a mass distribution". That argument is
    -- still a real one, and it lost, for a reason worth keeping: the invented
    -- constants below are roughly 2.2x the measured figures (9,299 / 11,837 /
    -- 7,353), every controller converts a commanded angular acceleration with
    -- T = I*alpha, and being 2.2x out scaled EVERY torque in the addon. A
    -- defensible model that is wrong by a factor loses to a measurement.
    --
    -- Left as m * k^2 with a radius of gyration k, so the shape of the estimate
    -- survives even though the numbers are dormant:
    --   roll  k ~ 16u  (rider is tall and narrow: hardest axis to flick)
    --   pitch k ~ 17u  (wheelbase dominates)
    --   yaw   k ~ 16u
    inertiaRoll  = 86 * 16 * 16,
    inertiaPitch = 86 * 17 * 17,
    inertiaYaw   = 86 * 16 * 16,

    -- Where the driver's seat sits, local space.
    -- Over the drawn saddle (cl_init FRAME.seat, x -10.5). At -4 the rider's
    -- seat sat six units in front of it, in the middle of the top tube.
    seatOffset = Vector(-10.5, 0, 18),
    -- -90 YAW, because a Source seat model faces along its own +Y, not +X.
    -- At 0 the rider sat across the bike, facing its right-hand side, with
    -- their legs pedalling in thin air. simfphys mounts its seats the same way.
    seatAngles = Angle(0, -90, 0),
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
    -- anything rough. 8 units is ~20 cm of rider compliance, which is what
    -- this spring actually represents.
    --
    -- 8, NOT 6, BECAUSE A LANDING IS DECIDED BY DISTANCE. Stopping a fall of
    -- speed v inside travel d takes v^2 / 2d, whatever the spring and damper:
    -- from a 60-unit drop (268 u/s) that is ~10 g over 6 units, and at 66 Hz
    -- the bike crosses 6 units in about a tick and a half, so the damper
    -- barely acts and the hard stop takes the blow. Measured on the tests'
    -- plant: 6 -> 8 cut the peak on that drop from 32 g to 23 g, with the
    -- same ride height (which is radius - sag, not a function of travel).
    --
    -- The original 2.0 was "a BMX has no suspension, keep it tiny", and it was
    -- wrong twice over: physically, because it ignored the rider, and
    -- numerically, because 2 units of travel forces a 43,000 spring to carry
    -- the bike, and a 43,000 spring is not integrable at 66 Hz. See below.
    restLength = 8.0,

    -- Sized so each wheel carries m*g/2 at ~3u of sag (it was half the old
    -- 6-unit travel; with 8 it is 3/8, leaving more for the landing):
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
    staminaRecover = 30,   -- once empty, no sprint until back to this

    -- Coasting: a BMX freewheel (or a fixed-gear cassette) never drives the
    -- cranks backwards, so no engine braking. Set to true for a fixed gear.
    fixedGear = false,

    -- Uphill help, as a fraction of the slope's pull (m*g*sin(slope)) added to
    -- the crank while pedalling up. 1 means the rider carries the slope and
    -- still has the flat's full push to accelerate with. 0 is the honest
    -- 12-degree bike. See the climbing note in sv_physics.lua.
    climbAssist = 1.0,
    -- ...full up to climbMax, fading to none at climbWall. Past that is a
    -- quarter pipe's vert, which you get up on speed, not on the pedals.
    climbMax  = math.rad(40),
    climbWall = math.rad(55),

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
    -- THESE ARE NOT FREE, and the number they have to meet is derivable.
    --
    -- The feed-forward cancels the toppling torque, which leaves the lateral
    -- tyre force's RIGHTING torque unopposed, and the PD has to hold the lean
    -- against it with error alone. In the steady state that is exactly
    --
    --     Kp * (target - roll) = topple(roll)
    --
    -- because a developed corner puts the righting torque equal to the toppling
    -- one (see the long note in sv_balance.lua). Solve it for the 25.2-degree
    -- target the suite uses and the gap the design asks for -- 12 degrees:
    --
    --     Kp  26  ->  21.8 deg of lean shortfall     (measured: 22.4)
    --     Kp 120  ->  14.6
    --     Kp 182  ->  12.0   the threshold
    --     Kp 220  ->  10.8   measured: 10.8
    --
    -- So 26 was not an aggressive-versus-relaxed choice, it was a value that
    -- could not meet the spec written next to it. 220 is the first round number
    -- with margin. HOW FAR ABOVE 182 to sit is a feel question and this is
    -- probably the first thing a rider will want to move; the constraint is that
    -- below ~182 the bike cannot hold the lean it is asked for, at any speed,
    -- however long you wait.
    --
    -- Kd tracks Kp: critical is 2*sqrt(Kp), and a little under feels alive while
    -- a lot under oscillates and reads as twitchy. 27 is zeta ~0.9.
    leanKp = 220,
    leanKd = 27.0,

    -- Ceiling on the assist's angular acceleration, rad/s^2. This is the
    -- difference between an arcade bike and one on rails: with no cap, no
    -- landing can ever go wrong because the controller simply undoes it.
    --
    -- Sized against the gravity torque the assist has to beat at full lean:
    --   T_gravity = m * g * h * sin(maxLean)
    --             = 86 * 600 * 30 * sin(42) = 1,035,800
    --   alpha_min = T_gravity / I_roll = 1035800 / 9299 = 111 rad/s^2
    --
    -- BOTH OF THOSE HAVE BEEN WRONG ONCE, WHICH IS WHY THE WORKING IS SHOWN.
    --
    -- The DENOMINATOR was originally the invented inertia of 22,016, giving 31
    -- and making 45 look like a 1.4x margin. The real roll inertia is 9,299
    -- (VPhysics, measured), so 45 was well BELOW the requirement: the balance
    -- controller could not hold the bike up at any lean worth having, at full
    -- authority, while every diagnostic said the assist was working perfectly.
    --
    -- The LEVER ARM was then wrong the same way. It used massCenterExpected.z,
    -- 20, which is the mass centre above the AXLE LINE -- but the bike topples
    -- about its CONTACT PATCH, a further Wheel.radius down, so the arm is 30.
    -- That put the requirement at 74 where it is really 111, and made a ceiling
    -- of 110 look like a comfortable 1.5x margin when it was actually BELOW the
    -- requirement at full lean. Same failure, same controller, second factor.
    --
    -- 165 restores the ~1.5x this was always meant to have. Most of the
    -- requirement is met by the gravity feed-forward in sv_balance.lua rather
    -- than by the PD, so this is a ceiling on total authority and not the
    -- working value. It still needs to be finite: it is the only thing that lets
    -- a bad landing beat the assist.
    maxAssistAccel = 165,

    -- Assist authority against speed, u/s. Full authority by fadeInHigh. Below
    -- fadeInLow the LEAN assist does nothing and C.Stand holds the bike
    -- instead; in between they share it.
    fadeInLow  = 25,
    fadeInHigh = 110,

    -- Below this the rider is "walking" the bike and gets direct steering
    -- instead of lean-derived steering, so you can turn round on the spot.
    walkSpeed = 45,

    maxSteer = math.rad(38),

    -- HOW FAR THE BARS ARE DRAWN TURNED, against how far they really are. The
    -- simulated steer is the physical one, and at speed that is small: a full
    -- lean at 280 u/s needs about 8 degrees of bar, which a rider watching the
    -- bike reads as "leaning and not turning the handlebars". So the DRAWN bars,
    -- fork and front wheel (and the rider's hands, through the IK) are turned
    -- by up to this many times the real angle, ramping in from walking pace to
    -- visualSteerFull. Display only: nothing simulated reads it.
    visualSteerGain = 3.0,
    visualSteerFull = 250,
    visualSteerMax  = math.rad(34),

    -- Trail/self-centring: mild damping on the derived steer angle so the front
    -- end does not chatter over bumps.
    steerRate = 9.0,
}

--------------------------------------------------------------------------
-- STANDING STILL: THE KICKSTAND AND THE RIDER'S FOOT
--
-- The lean assist above fades in with speed (fadeInLow..fadeInHigh) and does
-- nothing at a standstill. This used to be the whole story, on purpose: "a
-- bike that stands up on its own reads as a hovering prop". In play it read
-- as a bike you could not get on. Spawned, it fell over; stopped, it fell
-- over with you on it; and on its side it could never be ridden again.
--
-- So the slow end now has a support of its own, weighted by exactly the
-- authority the lean assist is NOT using, so the two hand over across the
-- same speed band rather than stacking:
--
--   parked (no rider)  a kickstand. The bike leans a little onto it, to the
--                      left, the side stands are on, and brakes itself.
--   ridden             the rider's foot. Upright, with a small lean from
--                      A/D so turning on the spot still looks like something.
--
-- Knocked past maxRoll it has fallen, and nothing holds it: a kickstand
-- does not stand a bike back up. Getting on picks it up (sv_seat.lua).
--------------------------------------------------------------------------
C.Stand = {
    standLean = math.rad(-9),      -- parked: leaning LEFT onto the stand
    footLean  = math.rad(6),       -- ridden: how far A/D lean at a standstill
    maxRoll   = math.rad(50),      -- beyond this it has fallen over

    -- The stand goes down only when a rider gets off slower than this, u/s
    -- (walking pace). Get off at speed and it stays up: the bike rolls on by
    -- itself and falls over when it stops, as a real one does.
    deploySpeed = 45,

    -- A riderless bike on the ground loses this much speed a second, u/s^2,
    -- on top of drag. Nothing else slowed it but drag and rolling
    -- resistance, and the lean assist kept it balanced at speed with nobody
    -- on it, so a bike let go of at 220 u/s was still rolling at 120 a
    -- minute later. A real one wobbles, scrubs and goes down in seconds:
    -- from 220 this is ~4 s and ~400 units, then it falls over.
    riderlessDecel = 60,

    -- Parked: the nudge that sets the bike down onto its stand from upright,
    -- rad/s^2 per rad of gap. Loses to gravity about 2 degrees right of
    -- upright, which is what lets somebody walking into it knock it over.
    settle    = 30,
    tipOver   = math.rad(6),       -- past this lean the other way, no nudge at all

    -- Stiff enough to beat the toppling gradient with margin: that is
    -- m*g*h/I_roll = 86*600*30/9299 = 166 rad/s^2 per rad, so 400 holds and
    -- 40 is zeta ~1 against it. Clamped by Balance.maxAssistAccel like the
    -- lean assist, so a hard enough shove still knocks a parked bike over.
    kp = 400,
    kd = 40,
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
    -- holdKd IS DERIVABLE, and being under-damped here does not look like
    -- under-damping, it looks like a bike that loops out.
    --
    -- The yank ramps out as the wheelie develops (see the handover note in
    -- sv_balance.lua), and that plus the P term crosses the gravity torque at a
    -- stable equilibrium near 25 degrees. Stable statically -- applied torque
    -- falls off faster with angle than the gravity torque it is beating -- so
    -- the failure is purely dynamic overshoot:
    --
    --   restoring gradient / I_eff = 15.4 1/s^2  ->  omega = 3.93 rad/s
    --   critical = 2*omega = 7.9,  so 4.2 is zeta 0.53
    --
    -- At that damping the nose overshoots the 25-degree equilibrium, passes the
    -- 41.2-degree balance point where gravity changes sides, and from there it
    -- is going over however good the controller is. Measured: 77 degrees.
    -- 7.1 is zeta 0.9.
    --
    -- NOTE THE DENOMINATOR, again. omega uses the effective inertia about the
    -- rear contact patch (72,574), not the free-body pitch inertia (11,837).
    -- That factor of 6.1 is the third place in this addon where using the
    -- free-body figure for a constrained body has produced a number that looked
    -- carefully derived and was wrong.
    holdKp = 9,
    holdKd = 7.1,

    -- WHERE IT AIMS, as a fraction of the balance point. NOT an angle, because
    -- the balance point is a consequence of the chassis geometry and an angle
    -- written here would silently stop matching it the moment someone moved the
    -- hull. See BMX.WheelieBalance().
    --
    -- Past the balance point, gravity stops resisting the wheelie and starts
    -- driving it, so anything aiming beyond it loops out every single time.
    -- holdMax used to be BOTH the target and the give-up ceiling, at 48 degrees
    -- against a balance point of 41.2: the assist drove the bike through the
    -- point of no return and the headless suite could never hold a wheelie.
    -- 0.82 of 41.2 is ~34 degrees, which is a wheelie with somewhere to go.
    holdAim = 0.82,

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

    -- The pitch half of the same cheat, applied only with NO pitch input and
    -- not mid-flip (see AirControl), for the whole flight rather than only the
    -- descent: it exists to take a bunny hop's own nose-up kick back out
    -- before the landing. With the air damping above that is omega ~3.5 rad/s
    -- at zeta ~0.65, so a full hop peaks near 20 degrees and comes down
    -- close to level. Off whenever autoLevel is 0.
    pitchLevelKp = 12,
    pitchLevelKd = 3.0,

    -- Both wheels must be off the ground for this long before air mode engages,
    -- so a bump in the road is not a "trick".
    engageDelay = 0.08,
}

--------------------------------------------------------------------------
-- BUNNY HOP
--------------------------------------------------------------------------
C.Hop = {
    -- Preload: hold IN_JUMP to compress, release to pop. (IN_DUCK is tuck.) Charge ramps 0 -> 1
    -- over chargeTime; releasing early gives a proportionally smaller hop.
    chargeTime = 0.42,
    minCharge  = 0.25,

    -- Vertical velocity added at full charge, u/s. 225 u/s against 600 u/s^2
    -- gravity is ~42 units of air, ~1.1 m: a very good rider hops about 1 m.
    -- It was 265 (~1.5 m), and a rider on the server found it "bouncing
    -- really high".
    popSpeed = 225,

    -- Fraction of pop applied forward, so a hop clears an obstacle rather than
    -- landing on it.
    forwardBias = 0.22,

    -- Nose-up impulse at the pop, rad/s, so hops naturally start a manual.
    pitchImpulse = 1.9,
    -- Pitch at which that kick has faded to nothing, rad. See the hop in
    -- sv_physics.lua: from a wheelie it used to stack into a backflip.
    kickFade = math.rad(15),

    cooldown = 0.25,
}

--------------------------------------------------------------------------
-- CRASHING
--------------------------------------------------------------------------
C.Crash = {
    enabled = true,

    -- LAND ON YOUR WHEELS AND YOU STAY ON. A landing is judged the moment a
    -- wheel touches the ground again, and it throws the rider only past this
    -- far off the surface: at 75 degrees the frame or bars reach the ground
    -- before the tyres, so it was not a landing on the wheels at all. It was
    -- 52, which threw riders off flips that came down nose-first on the front
    -- wheel, from any height, whatever their momentum.
    maxLandAngle = math.rad(75),

    -- A sideways landing only slides the tyres; nil turns the check off. It
    -- was 210 u/s of sideways slip, which ejected riders off landings that
    -- were on both wheels.
    maxLandLateral = nil,

    -- AFTER A LANDING, THE BIKE IS HELPED BACK UP. For recoverTime the lean
    -- assist works at full authority whatever the speed, with recoverBoost
    -- times its usual ceiling, a pitch assist levels a nose-down or nose-up
    -- touchdown, and the tip-over rule below waits. So a landing that is on
    -- the wheels but crooked rights itself under the rider instead of falling
    -- over a moment later and throwing them anyway.
    recoverTime  = 0.6,
    -- How far toward the mass centre, fore and aft, a landing's push is moved
    -- (0 = at the tyre, 1 = straight under the mass centre). Sideways it is
    -- always moved all the way. See Wheel:Simulate.
    soakPitch    = 0.7,

    -- STICKING IT. On the touchdown substep of a landing with a rider aboard,
    -- downward speed beyond soakSpeed is taken off at the mass centre (no
    -- lever arm, so it tips nothing), and soakSpin of the bike's pitch and
    -- roll spin with it: the rider's legs and arms absorbing the blow.
    -- Without it a big drop crossed the 8 units of travel in under a tick
    -- and met the ground on the wheel boxes, whose corner levered a
    -- nose-down landing end over end. An arcade assist, and it says so.
    soakSpeed = 250,
    -- ALL of the pitch spin too. At 0.75 a flip landed on a tyre (pitch 21,
    -- live server) kept a quarter of its rotation and went on over the front
    -- onto the bars: sticking a landing on the wheels ends the trick.
    soakSpin  = 1.0,       -- of the pitch spin
    -- ALL of the roll spin. A barrel roll landed with the tyres flat (roll
    -- -18, measured on the live server) still carried a quarter of its spin
    -- after soakSpin and rolled on over onto the bars. Sideways spin has no
    -- business surviving a landing on the wheels.
    soakRollSpin = 1.0,
    recoverBoost = 2.0,
    recoverPitchKp = 40,
    recoverPitchKd = 9,

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

    -- Tipped over on the ground with a rider aboard: past this lean (or this
    -- pitch, a looped wheelie) near the ground for tipTime, the rider is thrown.
    -- Full lean in a corner is Balance.maxLean, 42 degrees, well short.
    tipRoll  = math.rad(65),
    tipPitch = math.rad(75),
    tipTime  = 0.15,
    tipMaxVz = 80,          -- u/s: moving vertically faster than this is flight
}

--------------------------------------------------------------------------
-- GROUND TRICKS
--
-- Air tricks are scored by rotation (sv_air.lua). A wheelie or a stoppie has
-- no rotation to count, only DURATION, so it pays by the second once it has
-- been held long enough to be deliberate.
--------------------------------------------------------------------------
C.Tricks = {
    -- Held at least this long, or it was a bump and not a trick. A preloaded
    -- hop lifts the front for about half a second on its own, so this sits
    -- well clear of it.
    manualMin = 1.0,

    -- A stoppie is a stop: it lasts as long as the bike takes to halt, about
    -- half a second from riding speed. Held that long, it was meant.
    stoppieMin = 0.4,

    -- A wheel leaving the ground for a substep over a bump does not end the
    -- trick, and a rear wheel working its suspension mid-wheelie is not
    -- "both wheels down". The trick ends only once its shape has been gone
    -- for this long. Same reasoning as Air.engageDelay.
    manualGrace = 0.15,

    -- Below this the bike is being walked, not ridden, and no trick STARTS.
    -- One already under way carries on down to a standstill.
    manualMinSpeed = 30,

    wheeliePerSec = 150,
    stoppiePerSec = 200,    -- harder, and much shorter
}

--------------------------------------------------------------------------
-- GRINDING (sv_grind.lua)
--
-- Hop onto a rail or a ledge edge moving roughly along it and the bike locks
-- on and slides. Two grinds, chosen by what is under the middle of the bike:
--
--   crank grind       a PIPE (narrower than pipeMaxWidth): the pipe runs under
--                     the middle, the chainring rides it, and the bike is
--                     turned crankYaw off the pipe so the wheels hang down
--                     either side of it
--   double peg grind  an EDGE (a ledge, a box, a wide beam): the bike hangs off
--                     the drop side, both pegs on the edge
--
-- No map needs marking up: rails are found with traces, so a brush rail, a
-- prop and a kerb all work the same way.
--------------------------------------------------------------------------
C.Grind = {
    enabled = true,

    -- Where the frame meets a pipe: the bottom of the chainring, drawn by
    -- cl_init.lua (FRAME.bb, RING) on the frame's riding line. Move one and
    -- move the other.
    bb   = Vector(-4.5, 0, 2.5),
    ring = 3.8,
    -- A peg's contact, per side: out along the axle, just under its centre.
    pegY = 4.4,
    pegZ = -1.0,
    -- A peg rests this far onto the edge's top, not on the corner itself.
    pegInset = 0.8,
    -- Gap kept between the contact and the rail top, units.
    clearance = 0.3,

    -- The crank grind's angle to the pipe. Large enough that the peg boxes
    -- (6.6 out from each axle, 19.5 fore and aft of the middle) are clear of
    -- a pipe: 19.5 * sin(25 deg) = 8.2.
    crankYaw = math.rad(25),

    -- FINDING A RAIL. The rail top must be within snapAbove below the
    -- contact point (falling onto it) or snapBelow above it (a little past).
    snapAbove = 10,
    snapBelow = 3,
    reach     = 6,      -- half-width of the grid searched round the contact
    ring      = 7,      -- radius of the ring that tells a pipe from an edge
    drop      = 6,      -- lower than the top by this much is off the rail
    topTol    = 1.5,    -- within this of the top is still on it
    pipeMaxWidth = 6,   -- wider than this is a beam: grind its edge on pegs
    edgeSearch   = 12,  -- how far across the top an edge is looked for

    -- GETTING ON. Hopping onto it or just landed, moving along it.
    minSpeed      = 70,             -- u/s along the rail
    maxEntryAngle = math.rad(40),   -- between the travel and the rail
    maxEntryVz    = 120,            -- rising faster than this is not landing on it
    landedWindow  = 0.2,            -- s on the ground that still counts as landing

    -- ON IT. Gravity along a sloped rail speeds it up or slows it down.
    friction   = 40,     -- u/s^2
    brakeDecel = 220,    -- u/s^2 more with a brake held
    stopSpeed  = 30,     -- slower than this and the grind is over

    -- GETTING OFF: hop (the jump key), the rail ending, or too slow.
    hopSpeed = 190,      -- u/s up
    minHop   = 0.6,      -- of hopSpeed, for a tap of the key
    hopAway  = 60,       -- u/s off the ledge side of a peg grind
    cooldown = 0.4,      -- s before the same bike can lock on again

    minTime      = 0.3,  -- s: shorter was a brush, not a grind
    pointsPerSec = 140,
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
    local changed = false

    for _, row in ipairs(C.ConVars) do
        local name, _, path, isDegrees = row[1], row[2], row[3], row[4]
        local cv = GetConVar(name)
        if cv then
            local v = cv:GetFloat()
            if isDegrees then v = math.rad(v) end
            local group, key = string.match(path, "^(%w+)%.(%w+)$")
            if group and C[group] and C[group][key] ~= v then
                C[group][key] = v
                changed = true
            end
        end
    end

    -- Bikes with physics overrides hold a MERGED copy of this table, and they
    -- need to know when the thing they were merged from has moved. Bumping a
    -- counter is enough: they compare it against the revision they built at and
    -- rebuild lazily, so live tuning still reaches every bike on the next tick
    -- without rebuilding a table 20 times a second for nothing.
    if changed then BMX.ConfigRevision = BMX.ConfigRevision + 1 end
end

--------------------------------------------------------------------------
-- PER-BIKE PHYSICS
--
-- A bike registered with a `physics` table gets the base config with those
-- values merged over the top. A bike without one SHARES this table by
-- reference -- no copy, no merge, and live convar tuning reaches it for free.
--
-- WHY MERGE INSTEAD OF SWAPPING BMX.Config FOR THE DURATION OF A SUBSTEP.
-- The swap is two lines and it works, because PhysicsSimulate is never
-- re-entrant. It is also a global that means something different depending on
-- who is on the stack, which is a thing to inflict on a reader only if the
-- alternative is worse. It is not: every function that needs the config
-- already receives the entity, so the config can travel WITH the entity.
-- See ENT:Cfg() in entities/bmx_base/shared.lua.
--
-- A NOTE FOR TUNERS. Overriding a field that has a convar (see the ConVars
-- block above) opts that bike out of live tuning for that one field, because
-- an explicit override is meant to win. That is the correct behaviour and it
-- is also surprising at 2am, so it is written here.
--------------------------------------------------------------------------
BMX.ConfigRevision = 0

local GROUPS = { "Chassis", "Wheel", "Drive", "Balance", "Stand", "Pitch", "Air", "Hop",
                 "Crash", "Tricks" }

-- Public, so bmx_dump_config walks the same list the merge does: two copies of
-- it is how a new group gets merged per bike and silently left out of the dump.
BMX.ConfigGroups = GROUPS

-- Check a physics override table against the base BEFORE anything runs, so a
-- typo is a loud error at registration rather than a bike that quietly handles
-- like every other one. This is the whole reason the field did not exist until
-- now: `physics = {}` that silently does nothing is worse than no field at all.
function BMX.ValidatePhysics(id, phys)
    if not phys then return true end
    local bad = {}

    for group, over in pairs(phys) do
        if not C[group] then
            bad[#bad + 1] = string.format("no config group %q", tostring(group))
        elseif not istable(over) then
            bad[#bad + 1] = string.format("%s is not a table", tostring(group))
        else
            for key in pairs(over) do
                if C[group][key] == nil then
                    bad[#bad + 1] = string.format("%s.%s does not exist", group, tostring(key))
                end
            end
        end
    end

    if #bad > 0 then
        ErrorNoHalt(string.format("[BMX] bike %q has physics overrides that go " ..
            "nowhere: %s. They would have been silently ignored.\n",
            tostring(id), table.concat(bad, ", ")))
        return false
    end
    return true
end

-- The effective config for a bike definition. Cached on the def and rebuilt
-- only when a convar has actually moved the base.
function BMX.ConfigFor(def)
    local phys = def and def.physics
    if not phys then return C end

    if def._cfg and def._cfgRev == BMX.ConfigRevision then return def._cfg end

    local out = { ConVars = C.ConVars }
    for _, g in ipairs(GROUPS) do
        local base = C[g]
        if base then
            local t = {}
            for k, v in pairs(base) do t[k] = v end
            local over = phys[g]
            if over then
                for k, v in pairs(over) do
                    if base[k] ~= nil then t[k] = v end
                end
            end
            out[g] = t
        end
    end

    def._cfg, def._cfgRev = out, BMX.ConfigRevision
    return out
end
