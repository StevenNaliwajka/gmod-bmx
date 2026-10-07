--[[--------------------------------------------------------------------------
    bmx/sh_boards.lua

    THE BOARDS: registered through BMX.RegisterVehicle (sh_bikes.lua), against the
    vocabulary in sh_board.lua. Loaded after sh_bikes.lua for that reason, and in
    its own file so adding a board is not an edit to the bike list.

    WHAT A SKATEBOARD IS, IN THE PLATFORM'S TERMS (docs/MODDING.md):

        family   board                 the spawn menu's Boards heading, bmx_allow_boards
        wheels   four, on two trucks   every wheel steers, by a function of the deck's lean
        balance  board                 sv_board.lua: the chassis is held flat, the lean is a state
        drive    push                  a kick every kickInterval, foot-drag brake
        input    board                 sh_board.lua's map; sv_board.lua decodes it
        pose     board                 cl_board.lua: standing sideways, feet on the bolts

    THE NUMBERS ARE A SKATEBOARD'S, in inches and kilograms like everything else:
    a 31-inch deck, a 16-inch wheelbase (a real one is 14; the extra two keep a
    raycast chassis from pitching on its own ground forces), wheels of radius 2.2
    (a real wheel is 1.1: bigger rolls over a crack, which is what the goal asks of
    them), 72 kg of board and rider. The weight is the rider's because the rider is
    part of the sprung mass: the physics object is the board with someone on it.

    THE CHASSIS HULL. The body box is the rider's, tall and narrow and well above
    the deck so it never touches a rail; the thin boxes across the axles and the
    slab for the deck (the `bars` slot of the hull, which is the only other
    optional box the platform has) are what a board lying on its side rests on. The
    mass centre is 24 units above the axle line, a crouching skater's, and the
    entity checks the real one against it on spawn.
----------------------------------------------------------------------------]]

BMX = BMX or {}
local B = BMX.Board

-- The wheelbase, and the stock-bike scale the hull's bar slot is multiplied by
-- (BMX.CollisionBoxes scales it by wheelbase / 39, so the slab is written in
-- that scaled space).
local WHEELBASE = 16
local HULL_K = WHEELBASE / 39

-- The truck steer functions: (wheel, ent, st, inp, cfg, dt, speed) -> radians,
-- called every grounded substep after the balance has run. The front truck turns
-- with the deck's lean and the rear against it, so the board steers about a point
-- between them. `sign` is +1 for the front.
local function truck(sign)
    return function(w, ent, st, inp, cfg, dt, speed)
        local b = st.board
        if not b then return 0 end
        return sign * B.TruckSteer(b.lean or 0, speed, cfg.Wheel.wheelbase)
    end
end

-- Four wheels in a rectangle: a 16-inch wheelbase and a 9-inch track. Positions
-- are the AXLES in chassis space, as everywhere (sh_vehicles.lua).
function B.Wheels(cfg)
    local half = (cfg or BMX.Config).Wheel.wheelbase * 0.5
    local y = 4.6
    return {
        { pos = Vector( half,  y, 0), steer = truck( 1), drive = false, name = "front_l" },
        { pos = Vector( half, -y, 0), steer = truck( 1), drive = false, name = "front_r" },
        { pos = Vector(-half,  y, 0), steer = truck(-1), drive = false, name = "rear_l" },
        { pos = Vector(-half, -y, 0), steer = truck(-1), drive = false, name = "rear_r" },
    }
end

-- The points a rail is looked for at and ridden on (sv_board_grind.lua turns
-- them into a grind's pose): the middle of the deck's underside, and the axle
-- line's hanger height at each truck. `pegs` is what an edge is ridden on, the
-- trucks' track.
B.GrindPoints = {
    crank = Vector(0, 0, 0.8),
    pegs  = function(cfg)
        local half = cfg.Wheel.wheelbase * 0.5
        return { y = 4.6, z = -0.2, x = { half, -half } }
    end,
}

BMX.RegisterVehicle({
    id          = "skateboard",
    printName   = "Skateboard",
    description = "A skateboard: push, carve, ollie and flip it, grind rails and ledges.",
    author      = "naliwajka",
    family      = "board",
    colorIndex  = 6,
    wheels      = B.Wheels,
    balance     = "board",
    drive       = { kind = "push", torque = 52, maxSpeed = 300, kickInterval = 0.6 },
    seats       = { { offset = Vector(0, 0, B.Tune.seatZ), angles = Angle(0, B.Tune.seatYaw.regular, 0) } },
    input       = "board",
    pose        = "board",
    tricks      = { "spin360" },
    grindPoints = B.GrindPoints,
    physics = {
        Chassis = {
            mass = 72,
            hullMin = Vector(-8, -6, 10), hullMax = Vector(8, 6, 38),
            massCenterExpected = Vector(0, 0, 24),
            -- The trucks' boxes (x +-1.2 about each axle, z 0..6) and the deck's slab.
            wheelHullHalfWidth = 5.5,
            pegHullHalfWidth   = 5.5,
            barHullCentre = Vector(0, 0, 1.4 / HULL_K),
            barHullHalf   = Vector(15 / HULL_K, 4 / HULL_K, 0.45 / HULL_K),
            seatOffset = Vector(0, 0, B.Tune.seatZ),
            inertiaRoll = 72 * 9 * 9, inertiaPitch = 72 * 10 * 10, inertiaYaw = 72 * 8 * 8,
        },
        Wheel = {
            radius = 2.2, wheelbase = WHEELBASE, restLength = 4,
            -- Four wheels carry the weight, so 72 * 600 / 4 = 10,800 a wheel: a
            -- 12,000 spring sags under a unit, with a damper at about half of
            -- critical. A stiffer one rings at the tick (the bike's note on this).
            spring = 12000, damper = 450, bumpStop = 40000,
            inertia = 5, grip = 1.2, rollingResistance = 0.01,
            -- A rise of 4 units in one substep is a face, not ground: the bail rule.
            stepMax = 4,
        },
        -- No brakes on the wheels: the foot drags on the ground (sv_board.lua), and a
        -- locked 2-unit wheel is a skid, not a stop.
        Drive = { rearBrake = 0, frontBrake = 0, dragArea = 0.007, maxCadence = 50 },
        Crash = { maxLandAngle = math.rad(35), recoverTime = 0.5 },
        Air   = { yawAccel = 16 },
    },
})
