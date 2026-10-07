--[[--------------------------------------------------------------------------
    bmx/sh_board.lua

    THE SKATEBOARD'S VOCABULARY (G23): the numbers, the pure functions the
    simulation and the tests share, the input map and the rider pose set. The
    vehicle itself is registered in sh_boards.lua (after sh_bikes.lua, which
    owns RegisterVehicle); this file loads BEFORE that, because a registration is
    checked against the input maps, pose sets and trick ids that exist when it is
    made.

    WHY A BOARD IS NOT A BIKE WITH THE BARS TAKEN OFF.

      * Four wheels on two trucks make a statically stable deck. There is no
        single-track balance to hold up, so the `board` balance mode (sv_board.lua)
        holds the chassis flat to the ground and leaves the LEAN to the rider.
      * The lean is the steering, as the goal says, and it is a real skateboard's:
        the deck rolls on its trucks and each truck turns by atan(sin(lean) * k).
        That roll is a state of its own (st.board.lean), a spring that follows the
        key, and NOT the chassis's physical roll: a real deck pivots on its trucks
        with the wheels staying on the ground, which a rigid raycast body cannot do
        without lifting a wheel. So the chassis stays flat, the wheels stay down,
        and the lean is networked and drawn.
      * The board is a separate body from the rider. The physics object is the
        trucks and the weight on them; the DECK is drawn rotating on its own (the
        flip tricks), the way the tailwhip turns a frame.

    EVERYTHING NUMERIC LIVES IN BMX.Board.Tune, in one table, for the same reason
    BMX.Config does: a number somebody wants to change should be one line, and the
    tests read the same table the simulation does. It is deliberately not a
    BMX.Config group: those become per-vehicle overrides and convars, and the board
    already gets its physics from the registration's own `physics` table.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Board = BMX.Board or {}
local B = BMX.Board

local abs, min, max, sqrt, floor = math.abs, math.min, math.max, math.sqrt, math.floor
local TAU = math.pi * 2

--------------------------------------------------------------------------
-- THE TUNING. Source units: inches, kilograms, seconds.
--------------------------------------------------------------------------
B.Tune = {
    ----------------------------------------------------------------------
    -- Steering. The deck leans at most maxLean; a spring (leanOmega rad/s,
    -- damping ratio leanZeta) follows the commanded lean, which is what makes it
    -- CARVE rather than snap: the rider's key moves a target and the deck rolls
    -- toward it in about a fifth of a second. The trucks then turn by
    -- atan(sin(lean) * steerK) and no further than the tyres can hold:
    -- aLatMax is the sideways acceleration the steering stops asking for, because
    -- a rider and a deck this tall roll over past about half a g (the chassis is
    -- held flat, but a tyre that is asked for more than it has just skids).
    ----------------------------------------------------------------------
    maxLean   = math.rad(25),
    leanOmega = 15,
    leanZeta  = 0.75,
    steerK    = 0.9,
    aLatMax   = 160,

    ----------------------------------------------------------------------
    -- The push. A kick adds `kick` u/s at a standstill and less as the board
    -- speeds up, falling to nothing at maxSpeed (a rider cannot kick faster than
    -- the ground is going), spread over kickTime so it reads as a stroke and not
    -- a teleport. Holding W kicks again every kickInterval. Both come from the
    -- vehicle's own `drive = { kind = "push", ... }`; these are the defaults and
    -- the foot-brake and kick-turn numbers.
    ----------------------------------------------------------------------
    kickInterval = 0.6,
    kickTime     = 0.28,
    kick         = 52,
    maxSpeed     = 300,
    footBrake    = 240,      -- u/s^2 with S held and the board rolling
    kickTurnSpeed = 35,      -- slower than this S is a kick-turn, not a brake
    kickTurnTime  = 0.45,

    ----------------------------------------------------------------------
    -- The ollie. Hold SPACE to crouch, release to pop. The height of the pop is
    -- proportional to how long it was held, up to crouchMax: popMin units for a
    -- tap, popMax for a full crouch. The speed that reaches that height under the
    -- world's gravity is v = sqrt(2 g h), so the number a player feels is a height
    -- (which they can judge against a ledge) and not an impulse.
    ----------------------------------------------------------------------
    crouchMax    = 0.4,
    popMin       = 7,
    popMax       = 26,
    popCooldown  = 0.25,
    popForward   = 0.12,     -- of the pop leaned along the board, like the hop's
    popNoseKick  = 1.6,      -- rad/s of nose-up (nose-down for a nollie) spin
    coyote       = 0.08,     -- s after leaving the ground that a pop still works

    ----------------------------------------------------------------------
    -- Holding the chassis flat: PD gains (rad/s^2 per rad, per rad/s) and the most
    -- angular acceleration the assist may ask for. The roll hold cancels the
    -- tyres' own sideways force (the board would otherwise roll OUTWARD in a
    -- corner, like a car), the pitch hold carries manuals (sv_board_grind.lua).
    ----------------------------------------------------------------------
    rollKp = 90, rollKd = 16, rollMax = 220,
    pitchKp = 60, pitchKd = 13, pitchMax = 200,
    levelKp = 25, levelKd = 8,

    ----------------------------------------------------------------------
    -- Bailing on an edge: a wheel that meets a rise of Wheel.stepMax or more
    -- (4 units on the board) at catchSpeed or faster, for catchTime, throws the
    -- rider. Slower, it is just a bump the rider walks the board over.
    ----------------------------------------------------------------------
    catchSpeed = 140,
    catchTime  = 0.06,

    ----------------------------------------------------------------------
    -- Where the rider's feet go on the deck, board space (x forward), and which
    -- way the seat model faces for each stance (a seat faces its own +Y, so the
    -- yaw that turns that onto the board's right, the side a regular rider faces,
    -- is 180; goofy faces the left and is 0). Nobody has watched this on a real
    -- player model; they are numbers in a table and a swap is one line.
    ----------------------------------------------------------------------
    footFront = 4.6,
    footBack  = -5.4,
    seatYaw   = { regular = 180, goofy = 0 },
    seatZ     = 2.4,
}
local T = B.Tune

--------------------------------------------------------------------------
-- THE TRUCKS: steer = atan(sin(lean) * k), limited by what the tyres can hold.
--
-- `lean` is the deck's roll, radians, positive to the right. The result is the
-- angle EACH truck turns, positive to the right; the front truck turns with it
-- and the rear against it (sh_boards.lua), which is how a board with two trucks
-- steers about a point between them. The limit is the angle at which the turn's
-- sideways acceleration, v^2 / R with R = wheelbase / (2 tan(steer)), reaches
-- aLatMax: tan(steer) <= wheelbase * aLatMax / (2 v^2). At a walk it never
-- applies and the board turns as sharply as the trucks allow; at speed it is the
-- reason a board that is flat out carves wide instead of washing out.
--------------------------------------------------------------------------
function B.TruckSteer(lean, speed, wheelbase)
    local s = math.atan(math.sin(lean or 0) * T.steerK)
    local v = max(speed or 0, 1)
    local lim = math.atan((wheelbase or 16) * T.aLatMax / (2 * v * v))
    return BMX.Clamp(s, -lim, lim)
end

-- One substep of the lean spring: a damped second-order follow of `target`.
-- Returns the new lean and lean rate. Semi-implicit Euler, which is stable for
-- omega*dt well under 1 (here 0.23).
function B.LeanStep(lean, rate, target, dt)
    local w, z = T.leanOmega, T.leanZeta
    local acc = w * w * (target - lean) - 2 * z * w * rate
    rate = rate + acc * dt
    lean = lean + rate * dt
    return lean, rate
end

--------------------------------------------------------------------------
-- THE POP. Height from how long SPACE was held, and the speed that gets there.
--------------------------------------------------------------------------
function B.PopHeight(held)
    local f = BMX.Clamp((held or 0) / T.crouchMax, 0, 1)
    return T.popMin + (T.popMax - T.popMin) * f
end

function B.PopSpeed(height, gravity)
    return sqrt(2 * (gravity or 600) * max(height, 0))
end

--------------------------------------------------------------------------
-- THE KICK. How much speed one kick adds at a given speed: the full kick from a
-- standstill, none at maxSpeed.
--------------------------------------------------------------------------
function B.KickDv(speed, kick, maxSpeed)
    kick, maxSpeed = kick or T.kick, maxSpeed or T.maxSpeed
    return kick * BMX.Clamp(1 - max(speed or 0, 0) / maxSpeed, 0, 1)
end

-- The push cycle as a pure state machine, so the test can run it without a
-- board. `ps` is { phase = seconds since the last kick began, kicking = bool,
-- dv = the speed this kick will add }. Returns the speed to add THIS step
-- (nonzero only during a stroke) and whether a kick began this step. A kick
-- begins at once when W goes down on a board that has been ready for a full
-- interval, and again every `interval` while it stays down.
function B.PushStep(ps, dt, want, speed, drive)
    local interval = drive and drive.kickInterval or T.kickInterval
    local kick     = drive and drive.torque or T.kick
    local top      = drive and drive.maxSpeed or T.maxSpeed
    local began = false
    ps.phase = (ps.phase or interval) + dt
    if want and ps.phase >= interval and (speed or 0) < top then
        ps.phase, ps.kicking, began = 0, true, true
        ps.dv = B.KickDv(speed, kick, top)
    end
    local add = 0
    if ps.kicking then
        if ps.phase < T.kickTime then
            add = (ps.dv or 0) * dt / T.kickTime
        else
            ps.kicking = false
        end
    end
    return add, began
end

--------------------------------------------------------------------------
-- STANCE. Regular is the left foot forward, goofy the right; SWITCH is riding
-- with the other one forward, which is a stance change and not a direction.
-- FAKIE is rolling backwards, tail first, in whichever stance one is in.
--
-- `stance` is +1 for the left foot forward and -1 for the right: the product of
-- the rider's own (bmx_stance, regular = +1) and whether they have switched.
--------------------------------------------------------------------------
function B.Stance(goofy, switch)
    return (goofy and -1 or 1) * (switch and -1 or 1)
end

-- Fakie, with hysteresis so a board that stops and rocks does not flicker
-- between the two: it takes `enter` u/s backwards to become fakie and `leave`
-- u/s forwards to stop being. `was` is the previous answer.
function B.IsFakie(fwdSpeed, was, enter, leave)
    enter, leave = enter or 25, leave or 15
    if was then return fwdSpeed < leave end
    return fwdSpeed < -enter
end

-- Which side the front foot is on, "left" or "right", for a stance (+1/-1).
function B.FrontFoot(stance)
    return stance >= 0 and "left" or "right"
end

--------------------------------------------------------------------------
-- THE WIRE. The board's own networked state is a few floats and two ints
-- (entities/bmx_base/shared.lua): the lean, the push phase, the crouch, the
-- balance meter, the deck's three flip angles as one byte each (BoardBits), and
-- a set of flags. The flags and the bytes are packed and read here so the server
-- that writes them and the client that draws them cannot disagree.
--------------------------------------------------------------------------
B.Flag = {
    goofy = 1, switch = 2, fakie = 4, meter = 8, manual = 16, nose = 32,
    slide = 64, powerslide = 128, nollie = 256, grind = 512,
}

function B.PackFlags(t)
    local n = 0
    for name, bit in pairs(B.Flag) do
        if t[name] then n = n + bit end
    end
    return n
end

function B.HasFlag(flags, name)
    return floor((flags or 0) / B.Flag[name]) % 2 == 1
end

local function byteOf(angle)
    return floor((angle % TAU) / TAU * 256 + 0.5) % 256
end

-- The deck's flip angles (radians): roll about its long axis, yaw about the
-- vertical (shove-its), pitch about the cross axis (the impossible), one byte
-- each. 0 is flat.
function B.PackBits(roll, yaw, pitch)
    return byteOf(roll or 0) + byteOf(yaw or 0) * 256 + byteOf(pitch or 0) * 65536
end

function B.UnpackBits(bits)
    bits = bits or 0
    return (bits % 256) / 256 * TAU, (floor(bits / 256) % 256) / 256 * TAU,
        (floor(bits / 65536) % 256) / 256 * TAU
end

--------------------------------------------------------------------------
-- THE INPUT MAP. W pushes (and, in the air, is a flip direction), S drags a foot
-- (a kick-turn at a standstill), A and D lean, SPACE crouches and pops, ALT makes
-- the pop a nollie, RMB is the manual on the ground and the grab in the air, CTRL
-- is the powerslide on the ground and the body spin in the air, LMB swaps feet.
-- sv_board.lua decodes them (`decode`, below, is set there).
--------------------------------------------------------------------------
local G, A, GR, M = "ground", "air", "grind", "manual"

BMX.RegisterInputMap{
    id = "board", label = "Skateboard",
    actions = {
        forward = { key = IN_FORWARD,   ctx = { G, A, GR }, label = "Push / front shove-it flick" },
        back    = { key = IN_BACK,      ctx = { G, A, GR }, label = "Foot brake, kick-turn / pop shove-it flick" },
        left    = { key = IN_MOVELEFT,  ctx = { G, A, GR }, label = "Lean left / kickflip flick" },
        right   = { key = IN_MOVERIGHT, ctx = { G, A, GR }, label = "Lean right / heelflip flick" },
        jump    = { key = IN_JUMP,      ctx = { G, A, GR }, label = "Crouch, release to ollie; hold to grind" },
        alt     = { key = IN_WALK,      ctx = { G, A },     label = "Nollie" },
        grab    = { key = IN_ATTACK2,   ctx = { G, A, M },  label = "Manual; grab in the air" },
        crouch  = { key = IN_DUCK,      ctx = { G, A },     label = "Powerslide with A / D; body spin in the air" },
        swap    = { key = IN_ATTACK,    ctx = { G },        label = "Switch stance" },
    },
}

--------------------------------------------------------------------------
-- THE RIDER'S POSE SET. cl_board.lua fills in `rider` (bone offsets), `poses`
-- (the grab IK targets), `activity` and `solveIK`; the id has to exist before a
-- registration can name it.
--------------------------------------------------------------------------
BMX.RegisterPoseSet("board", { label = "Board: standing sideways on the deck, feet on the bolts" })

-- A fresh input record for a board's rider. The standard input table (throttle,
-- lean...) carries W, S and A / D; this carries what a bike's does not.
function B.NewInput()
    return { fwd = 0, side = 0, jump = false, alt = false, grab = false, duck = false,
             swap = false, flickF = 0, flickS = 0 }
end

-- The record on an input table, made if it is missing (a scripted rider or a bot
-- that only set throttle and lean has none).
function B.InputOf(inp)
    local b = inp.board
    if not b then b = B.NewInput(); inp.board = b end
    return b
end

-- The rider's direction for a flick or a flip, as -1/0/1 each: forward (W), side
-- (D is +1). The raw keys of the board record where a decoder wrote them, else the
-- standard fields a scripted rider writes (throttle - brakeRear, the lean key).
-- Quantised at one half, so a gamepad stick has to mean it.
function B.RawDir(inp)
    local b = inp.board
    local f, s
    if b and (b.fwd ~= 0 or b.side ~= 0) then
        f, s = b.fwd, b.side
    else
        f = (inp.throttle or 0) - (inp.brakeRear or 0)
        s = inp.leanTarget or 0
    end
    if b and (b.flickF ~= 0 or b.flickS ~= 0) then f, s = b.flickF, b.flickS end
    local function q(v) return v > 0.5 and 1 or (v < -0.5 and -1 or 0) end
    return q(f), q(s)
end
