--[[--------------------------------------------------------------------------
    bmx/sh_motorbikes.lua

    THE MOTOR VEHICLES (G14, G15): an e-bike, an e-moto, a dirt bike and a moped.
    The model they run on is sh_motor.lua, the drives are sv_motor.lua, and the
    platform they are registered against is sh_vehicles.lua / sh_bikes.lua. Like
    the road bike, none of them has a model: they are drawn in code from their
    geometry, so a motor vehicle is a registry entry and some numbers.

    ALL FOUR ARE FAMILY `moto`, so they sit under the Motor heading of the spawn
    menu, the whole heading switches off with bmx_allow_motor 0, and spawning one
    needs the CAMI privilege "BMX - Spawn Motor Vehicles" (sv_motor.lua). They are
    single-track vehicles (the singletrack balance mode): a motorbike is held up by
    the same lean-derived steering and the same wheelie hold as a BMX, which is what
    makes a throttle wheelie, a clutch pop and a Trials lean the BMX's own physics
    with more torque behind it, not a second simulation.

    HOW THE NUMBERS WERE CHOSEN is in each entry. The shared rule: a heavier vehicle
    gets the sprung weight's spring and damper scaled with it (a BMX's spring is
    8600 for 86 kg, so a 150 kg moto's 13600 sags the same few units), more travel
    (restLength, which is what the suspension is: the mount sits that far above the
    axle), and a bigger weight-shift torque (Pitch.torque, which is an acceleration
    times the pitch inertia that the measured body supplies, so the wheelie's yank
    scales with the mass instead of being a feather on a heavier frame).
----------------------------------------------------------------------------]]

BMX = BMX or {}

--------------------------------------------------------------------------
-- THE E-BIKE (G14). A pedal-assist city-and-trail bike: the BMX's legs with a motor
-- behind them. The assist level (0-3, the mouse wheel or [ and ]) is how many times
-- what the rider is putting in the motor adds, until 25 km/h (bmx_ebike_limit),
-- where the motor fades out and the rider pedals on alone. It draws on a battery
-- (bmx_ebike_battery Wh) that a parked bike recharges; with it empty, or at level 0,
-- it is a 108 kg bicycle.
--
--   mass 108            the frame, a motor and a pack: heavier than a BMX by the
--                       weight of the battery
--   wheel 11.5 / base 44  a 24-inch-ish wheel and a frame between the cruiser's and
--                       the BMX's; the seat scales with the frame, x 44/39
--   gearRatio 2.4       the legs' ceiling is 12.6 * 2.4 * 11.5 = 348 u/s, above the
--                       25 km/h (273 u/s) limit, so what holds the speed at the limit
--                       is the MOTOR'S fade and not the rider spinning out
--   assist = 1          it spawns in level 1: a gentle help, not a surprise
BMX.RegisterBike("ebike", {
    printName   = "E-Bike",
    description = "Pedal-assist e-bike: the motor adds 0-3 times your pedalling (mouse wheel or [ ]) up to 25 km/h, then you pedal on alone. The battery drains with the motor's work and recharges while parked.",
    family      = "moto",
    colorIndex  = 6,            -- teal
    drive       = { kind = "assist", assist = 1 },
    input       = "ebike",
    seats       = { pegs = {} },
    physics = {
        Chassis = { mass = 108, seatOffset = Vector(-11.85, 0, 20.3) },    -- x 44/39
        Wheel   = { radius = 11.5, wheelbase = 44, restLength = 9.5, grip = 1.4,
                    spring = 10800, damper = 620 },
        Drive   = { gearRatio = 1.95, dragArea = 0.0052 },
        Hop     = { popSpeed = 150 },
        Pitch   = { torque = 1320000 },
    },
})

--------------------------------------------------------------------------
-- THE E-MOTO (G14): a no-pedal electric motorbike (the Talaria Sting is the one
-- people ask for). Throttle on W, feet on pegs, regen on S, about two and a half
-- times the BMX's top speed, heavy, with long-travel suspension.
--
--   torque 700000, maxSpeed 850   the throttle's torque falls linearly to nothing at
--                       maxSpeed, so the speed is a limit and not a drag term; the
--                       bike gets to ~2.5x the BMX's (~315 u/s -> ~790) on the plant
--   regen 260000        S brakes with the motor as well as the pad, and what that
--                       braking would have heated is put back in the pack (at
--                       REGEN_EFF, 60%)
--   battery 3           three e-bikes' worth of pack, because it is working much harder
--   mass 150            a motorbike with a pack in it
--   wheel 12.5, restLength 10.5   long travel (a BMX's is 8) on a wheel that still
--                       leaves the hull's floor under the pegs; spring 13600 and damper
--                       850 are the BMX's scaled by mass (see the file header)
BMX.RegisterBike("emoto", {
    printName   = "E-Moto",
    description = "Electric motorbike: throttle on W, no pedalling, regen braking on S, about 2.5x a BMX's top speed. Heavy, with long-travel suspension.",
    family      = "moto",
    bell        = "horn",       -- R on the ground: a horn, not a bicycle bell
    colorIndex  = 8,            -- blue
    drive       = { kind = "throttle", torque = 700000, maxSpeed = 850, regen = 260000,
                    battery = 3, motorRatio = 10 },
    pose        = "moto",
    seats       = { pegs = {} },
    physics = {
        Chassis = { mass = 150, seatOffset = Vector(-12.9, 0, 22.2) },     -- x 48/39
        Wheel   = { radius = 12.5, wheelbase = 48, restLength = 10.5, grip = 1.5,
                    spring = 13600, damper = 850, bumpStop = 100000, rollingResistance = 0.01 },
        Drive   = { dragArea = 0.0048 },
        Hop     = { popSpeed = 140 },
        Pitch   = { torque = 1840000 },
    },
})

--------------------------------------------------------------------------
-- THE DIRT BIKE (G15). Trials and freestyle motocross. A petrol engine with a torque
-- curve, a five-speed gearbox (the road bike's gear model: [ ] and the wheel) and a
-- clutch on SHIFT. Hold the clutch with the throttle open and let go, and the
-- revs you built dump into the rear wheel: a clutch pop, which is a wheelie. The
-- rider leans fore and aft over a long-travel bike, which is the Trials mechanic.
--
--   engine: 16000 peak, idle 1800, redline 10500, a peaky curve that is best between
--     6000 and 9000 rpm (the shift points, sh_motor.lua ShiftPoint, fall there)
--   gears: the top gear's redline is 700 u/s (2.2x the BMX); each gear below is 1.28x
--     lower, so the five reach 270 / 345 / 440 / 565 / 700 at the redline. The ratio
--     is WHEEL revolutions per ENGINE revolution (the road bike's was per crank).
--   wheel 14, restLength 12   a 28-inch wheel and a long stroke: 12 u of travel against
--     a BMX's 8, with the hull's floor 2 u under the axle line as the road bike's is
--   mass 118; spring 11800, damper 700, bumpStop 90000 (the BMX's scaled by mass)
--   Pitch.leanShift 14, leanRate 8   the rider's weight over the bars is twice the
--     BMX's COM offset and comes on faster: a Trials rider throws their weight around
--   Hop.popSpeed 130   the legs do not hop a 118 kg bike; the suspension and the throttle do
BMX.RegisterBike("dirtbike", {
    printName   = "Dirt Bike",
    description = "Trials and freestyle motocross: an engine with a torque curve, five gears ([ ] or the wheel), a clutch on SHIFT (let go with the throttle open to pop a wheelie), long-travel suspension and FMX poses (Alt in the air: superman, heel clicker, cliffhanger).",
    family      = "moto",
    bell        = "horn",       -- R on the ground: a horn, not a bicycle bell
    colorIndex  = 2,            -- orange
    gears       = { ratios = { 0.01695, 0.0217, 0.02777, 0.03555, 0.0455 }, start = 1 },
    drive       = {
        kind = "engine", torque = 10500, idle = 1800, redline = 10500, inertia = 14,
        friction = 0.14, clutch = 2.2, engageRpm = 3500, popGain = 0.2, popTime = 0.4,
        curve = { { 1500, 0.35 }, { 3000, 0.55 }, { 5000, 0.8 }, { 7500, 1.0 },
                  { 9500, 0.85 }, { 10500, 0.4 } },
    },
    input       = "moto",
    pose        = "moto",
    seats       = { pegs = {} },
    physics = {
        Chassis = { mass = 118, seatOffset = Vector(-14.9, 0, 25.5) },     -- x 58/39
        Wheel   = { radius = 14, wheelbase = 58, restLength = 12, grip = 1.5,
                    spring = 11800, damper = 700, bumpStop = 90000, rollingResistance = 0.014 },
        Drive   = { dragArea = 0.0055 },
        Hop     = { popSpeed = 130 },
        Pitch   = { torque = 1440000, leanShift = 14, leanRate = 8 },
    },
})

--------------------------------------------------------------------------
-- THE MOPED (G15): a Piaggio-style scooter-moped that "has pedals to start it". You
-- pedal it off (an engine drive that has not started: the legs are the drive), and
-- after the first few metres the engine catches and takes over. No gears, no clutch
-- lever (a centrifugal clutch and one ratio), 45 km/h.
--
--   pedalStart 4   metres of pedalling before the engine starts
--   ratio 0.0567   wheel revolutions per engine revolution: 7500 rpm at 490 u/s on an
--                  11-radius wheel
--   torque 9000    a 50 cc: just enough, and the legs are what gets it off the line
BMX.RegisterBike("moped", {
    printName   = "Moped",
    description = "Piaggio-style moped: pedal it off for the first few metres and the engine takes over. One speed, about 45 km/h.",
    family      = "moto",
    bell        = "horn",       -- R on the ground: a horn, not a bicycle bell
    colorIndex  = 12,           -- white
    drive       = {
        kind = "engine", torque = 9000, idle = 1500, redline = 7800, inertia = 9,
        friction = 0.12, clutch = 2.5, engageRpm = 2800, ratio = 0.0567, pedalStart = 4,
        curve = { { 1500, 0.6 }, { 3500, 0.85 }, { 5500, 1.0 }, { 7800, 0.7 } },
    },
    input       = "bike_rearonly",
    pose        = "upright",
    barStyle    = "swept",
    seats       = { pegs = {} },
    physics = {
        Chassis = { mass = 104, seatOffset = Vector(-12.9, 0, 20.3) },
        Wheel   = { radius = 11, wheelbase = 48, restLength = 9, grip = 1.35,
                    spring = 10400, damper = 600 },
        Drive   = { gearRatio = 2.2, dragArea = 0.006 },
        Hop     = { popSpeed = 120 },
        Pitch   = { torque = 1270000 },
    },
})
