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
    -- The front foot stands just behind the front truck's bolts and the back foot
    -- over the back truck's (the trucks are at +-7.9 on the 16-unit wheelbase, their
    -- bolts 1.06 either side): a shoulder-wide stance, which is what a skater rides
    -- on. The ollie moves the back foot onto the tail from here (cl_board.lua).
    footFront = 6.2,
    footBack  = -7.4,
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

-- THE PUSH PHASE ON THE WIRE: where the rider is in the WHOLE push cycle, 0..1 of
-- the kick interval, or -1 when not pushing. Not just the stroke: the foot that
-- pushed still has to lift and come back to the deck after the force stops, and a
-- phase that went to -1 at the end of the stroke snapped it home in one frame.
function B.PushPhaseOf(ps, interval)
    interval = interval or T.kickInterval
    if ps and ps.dv and ps.phase and ps.phase >= 0 and ps.phase < interval then
        return ps.phase / interval
    end
    return -1
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

-- The four direction keys as booleans { w, s, a, d }: the board record's raw keys
-- where a decoder wrote them (so W and S together are both seen, which the single
-- forward axis cannot say), else the standard fields a scripted rider writes.
function B.Keys(inp)
    local b = inp.board
    local w, s, a, d
    if b and (b.w ~= nil or b.s ~= nil) then
        w, s = b.w or false, b.s or false
    else
        local f = b and b.fwd ~= 0 and b.fwd or ((inp.throttle or 0) - (inp.brakeRear or 0))
        w, s = f > 0.5, f < -0.5
    end
    local sd = b and b.side ~= 0 and b.side or (inp.leanTarget or 0)
    a, d = sd < -0.5, sd > 0.5
    -- The flick scheme: the mouse's stroke stands in for the keys.
    if b and (b.flickF ~= 0 or b.flickS ~= 0) then
        w, s, a, d = b.flickF > 0, b.flickF < 0, b.flickS < 0, b.flickS > 0
    end
    return { w = w, s = s, a = a, d = d }
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

--------------------------------------------------------------------------
-- THE FLIPS. During the pop window (Tune.flipWindow after an ollie) a direction
-- picks the flip, THPS style:
--
--           W            front shove-it
--      W+A  hardflip     W+D  varial kickflip
--       A   kickflip      D   heelflip
--      S+A  360 flip     S+D  varial heelflip
--           S            pop shove-it           W+S  impossible
--
-- (Skate's mouse flick picks the same directions, bmx_board_flick.) A flip is the
-- DECK rotating on its own axes while the rider stays put: roll about its long
-- axis (the kick and heel), yaw about the vertical (the shove-its), pitch about
-- the cross axis (the impossible, which wraps the board round the back foot).
-- Angles are the total each turns through, radians; `dur` how long it takes.
--
-- THE CATCH. Land with the deck within Tune.catchAngle (20 degrees) of flat and
-- wheels down, or bail. "Flat" for a roll or pitch is a whole turn and for yaw a
-- half turn (a deck is the same either way round), so the catch window is the
-- last part of the flip, and a pop too low for the board to finish is a bail.
--------------------------------------------------------------------------
local PI = math.pi
B.Flips = {
    kickflip   = { name = "Kickflip",        w = false, s = false, a = true,  d = false,
                   roll =  TAU, yaw = 0,   pitch = 0,   dur = 0.42, points = 300, input = "A after the pop" },
    heelflip   = { name = "Heelflip",        w = false, s = false, a = false, d = true,
                   roll = -TAU, yaw = 0,   pitch = 0,   dur = 0.42, points = 300, input = "D after the pop" },
    popshove   = { name = "Pop Shove-it",    w = false, s = true,  a = false, d = false,
                   roll = 0,    yaw = PI,  pitch = 0,   dur = 0.36, points = 200, input = "S after the pop" },
    frontshove = { name = "Front Shove-it",  w = true,  s = false, a = false, d = false,
                   roll = 0,    yaw = -PI, pitch = 0,   dur = 0.36, points = 200, input = "W after the pop" },
    flip360    = { name = "360 Flip",        w = false, s = true,  a = true,  d = false,
                   roll =  TAU, yaw = TAU, pitch = 0,   dur = 0.55, points = 600, input = "S + A after the pop" },
    varialheel = { name = "Varial Heelflip", w = false, s = true,  a = false, d = true,
                   roll = -TAU, yaw = -PI, pitch = 0,   dur = 0.46, points = 400, input = "S + D after the pop" },
    varialkick = { name = "Varial Kickflip", w = true,  s = false, a = false, d = true,
                   roll =  TAU, yaw = PI,  pitch = 0,   dur = 0.46, points = 400, input = "W + D after the pop" },
    hardflip   = { name = "Hardflip",        w = true,  s = false, a = true,  d = false,
                   roll =  TAU, yaw = -PI, pitch = 0,   dur = 0.50, points = 450, input = "W + A after the pop" },
    impossible = { name = "Impossible",      w = true,  s = true,  a = false, d = false,
                   roll = 0,    yaw = 0,   pitch = TAU, dur = 0.50, points = 500, input = "W + S after the pop" },
}
B.FlipOrder = { "kickflip", "heelflip", "popshove", "frontshove", "flip360",
                "varialheel", "varialkick", "hardflip", "impossible" }

T.flipWindow = 0.45          -- s after the pop in which a direction picks a flip
T.flipSettle = 0.06          -- s a direction is held before it counts (so a diagonal is two keys)
T.catchAngle = math.rad(20)  -- land within this of flat, or bail
T.cleanAngle = math.rad(5)   -- within this it is a clean catch
T.okAngle    = math.rad(12)
T.catchMult  = { clean = 1.25, ok = 1.0, late = 0.6 }
T.switchMult = 1.2
T.fakieMult  = 1.1
T.nollieMult = 1.1

-- Which flip a set of keys picks, or nil. W + S is the impossible whatever A and
-- D say; otherwise the keys must be exactly a row's.
function B.FlipFor(k)
    if not (k.w or k.s or k.a or k.d) then return nil end
    local a, d = k.a, k.d
    if a and d then a, d = false, false end
    local w, s = k.w, k.s
    if w and s then a, d = false, false end
    for _, id in ipairs(B.FlipOrder) do
        local f = B.Flips[id]
        if f.w == w and f.s == s and f.a == a and f.d == d then return id end
    end
    return nil
end

-- How far through its turn each axis of the deck is, `t` seconds after the flip
-- began: roll, yaw, pitch (radians). Ease-out: it spins fastest at first and
-- settles into the catch, which is what a flip looks like and what leaves the
-- last part of it flat enough to land.
function B.FlipAngles(flip, t)
    local x = BMX.Clamp((t or 0) / flip.dur, 0, 1)
    local e = 1 - (1 - x) * (1 - x)
    return flip.roll * e, flip.yaw * e, flip.pitch * e
end

-- How far from a flat landing the deck is at time `t`: the largest, over its three
-- axes, of the distance to the nearest whole turn (a half turn for yaw).
function B.CatchError(flip, t)
    local r, y, p = B.FlipAngles(flip, t)
    local function off(a, q)
        local m = abs(a) % q
        return min(m, q - m)
    end
    return max(off(r, TAU), off(y, PI), off(p, TAU))
end

-- "clean", "ok", "late", or nil for a bail.
function B.CatchGrade(err)
    if err <= T.cleanAngle then return "clean" end
    if err <= T.okAngle then return "ok" end
    if err <= T.catchAngle then return "late" end
    return nil
end

-- The seconds, after a flip begins, from which a landing is caught: the start of
-- its catch window. (It stays caught from there on: the flip is over.)
function B.CatchFrom(flip)
    local lo, hi = 0, flip.dur
    for _ = 1, 30 do
        local mid = (lo + hi) / 2
        if B.CatchError(flip, mid) <= T.catchAngle then hi = mid else lo = mid end
    end
    return hi
end

-- The points for a flip landed: its own, times the catch (clean more, late
-- less), the stance (switch and fakie pay more) and the nollie.
function B.FlipPoints(flip, grade, switch, fakie, nollie)
    local mult = T.catchMult[grade] or 0
    if switch then mult = mult * T.switchMult elseif fakie then mult = mult * T.fakieMult end
    if nollie then mult = mult * T.nollieMult end
    return floor(flip.points * mult + 0.5)
end

-- THE TRICKS, registered like every other (sh_tricks.lua): scored on landing by
-- sv_board_tricks.lua, listed by the trick overlay, and what a vehicle's `tricks`
-- list names.
for _, id in ipairs(B.FlipOrder) do
    local f = B.Flips[id]
    BMX.RegisterTrick{ id = id, name = f.name, kind = "custom", points = f.points, input = f.input }
end
BMX.RegisterTrick{ id = "board180", name = "180", kind = "custom", points = 120,
    input = "CTRL + A / D in the air (a half turn)" }

--------------------------------------------------------------------------
-- THE GRINDS AND SLIDES. Hold SPACE in the air near a rail or a ledge (or turn
-- on bmx_board_autogrind and just touch it) and the board locks on. WHICH grind
-- is two things the rider already did: how the board is turned to the rail (along
-- it is a grind, across it a slide) and the keys held as it locked on.
--
--           along the rail                          across it
--    none     50-50                          none    boardslide
--      W      nosegrind                        W     noseslide        (ledges)
--      S      5-0                              S     tailslide        (ledges)
--    W+A/D    crooked                         A/D    lipslide         (ledges)
--    S+A      smith (ledges)
--    S+D      feeble (ledges)
--
-- Each is a CONTACT RULE: which point of the board rides the rail and how the
-- board sits on it. `x` is where on the deck (board space, x forward) the rail
-- is; `z` its height (a truck's hanger for the grinds, the deck's underside for
-- the slides); `pitch` the nose-up angle the board holds (a 5-0 is on the back
-- truck with the nose up, a nosegrind on the front with the tail up); `yaw` how
-- far the board is turned off the rail's own line (a crooked grind is angled), and
-- `toward` (smith, feeble) which side of a ledge the nose points to: the drop, for
-- the smith (the front truck hangs below the edge), the top for the feeble.
-- `edge` marks the ones that need a ledge or coping, an edge to hang a truck off:
-- on a round rail they fall back to the plain version (smith to 5-0, the slides
-- to a boardslide). `mult` is the points multiplier on the grind's rate.
--
-- The contact heights are chosen so the rail is BELOW everything the hull
-- has (BMX.CollisionBoxes: the trucks' boxes start at the axle line, the deck's
-- slab at 0.95), or the pose would be refused as no room (sv_grind.lua,
-- GrindPoseClear). The pose puts the contact point Grind.clearance (0.3) above the
-- rail, so a truck grinds 0.2 under the axle line (the rail 0.5 under it) and a
-- slide rides 0.1 over it (the rail 0.2 under): the deck floats a unit above a
-- rail it slides, which nobody can see from the camera and which keeps a ledge's
-- top, under the half of the board on its side, out of the trucks' boxes.
--------------------------------------------------------------------------
T.truckX, T.tipX = 8, 13.5
T.truckZ, T.deckZ = -0.2, 0.1
T.grindEdgeY = 3                   -- how far the board's middle hangs over the drop of a ledge
T.alongAngle = math.rad(45)        -- within this of the rail's line it is a grind, past it a slide
T.meterGrind  = { unstable = 0.7, wobble = 0.08, control = 1.5 }
T.meterManual = { unstable = 0.8, wobble = 0.09, control = 1.6 }
T.manualMinSpeed = 40
T.manualPitch = math.rad(13)
T.manualMin = 0.8
T.manualRate = { manual = 150, nose = 170 }

B.Grinds = {
    grind5050  = { name = "50-50",         along = true,  x = 0,           z = T.truckZ, pitch = 0,     yaw = 0,    mult = 1.0,
                   input = "SPACE onto a rail, no other key" },
    grind50    = { name = "5-0",           along = true,  x = -T.truckX,   z = T.truckZ, pitch = 0.12,  yaw = 0,    mult = 1.2,
                   input = "SPACE + S onto a rail" },
    nosegrind  = { name = "Nosegrind",     along = true,  x = T.truckX,    z = T.truckZ, pitch = -0.12, yaw = 0,    mult = 1.2,
                   input = "SPACE + W onto a rail" },
    crooked    = { name = "Crooked Grind", along = true,  x = T.truckX,    z = T.truckZ, pitch = -0.12, yaw = 0.5,  mult = 1.5,
                   input = "SPACE + W + A / D onto a rail" },
    smith      = { name = "Smith Grind",   along = true,  x = -T.truckX,   z = T.truckZ, pitch = -0.12, yaw = 0.6,  mult = 1.5, edge = true,
                   toward = "drop", input = "SPACE + S + A onto a ledge" },
    feeble     = { name = "Feeble Grind",  along = true,  x = -T.truckX,   z = T.truckZ, pitch = 0.1,   yaw = 0.6,  mult = 1.5, edge = true,
                   toward = "top", input = "SPACE + S + D onto a ledge" },
    boardslide = { name = "Boardslide",    along = false, x = 3,           z = T.deckZ,  pitch = 0,     yaw = math.pi / 2, mult = 1.3,
                   input = "SPACE across a rail, no other key" },
    lipslide   = { name = "Lipslide",      along = false, x = -3,          z = T.deckZ,  pitch = 0,     yaw = math.pi / 2, mult = 1.5, edge = true,
                   input = "SPACE + A / D across a ledge" },
    noseslide  = { name = "Noseslide",     along = false, x = T.tipX,      z = T.deckZ,  pitch = -0.1,  yaw = math.pi / 2, mult = 1.6, edge = true,
                   input = "SPACE + W across a ledge" },
    tailslide  = { name = "Tailslide",     along = false, x = -T.tipX,     z = T.deckZ,  pitch = 0.1,   yaw = math.pi / 2, mult = 1.6, edge = true,
                   input = "SPACE + S across a ledge" },
}
B.GrindOrder = { "grind5050", "grind50", "nosegrind", "crooked", "smith", "feeble",
                 "boardslide", "lipslide", "noseslide", "tailslide" }

-- The grind the keys pick, for a board turned `along` or across the rail, on a
-- ledge (`edge`) or a round rail. `k` is B.Keys.
function B.ClassifyGrind(k, along, edge)
    local side = (k.a or k.d) and not (k.a and k.d)
    local id
    if along then
        if k.w and not k.s then id = side and "crooked" or "nosegrind"
        elseif k.s and not k.w then
            if k.a and not k.d then id = "smith"
            elseif k.d and not k.a then id = "feeble"
            else id = "grind50" end
        else id = "grind5050" end
    else
        if k.w and not k.s then id = "noseslide"
        elseif k.s and not k.w then id = "tailslide"
        elseif side then id = "lipslide"
        else id = "boardslide" end
    end
    if B.Grinds[id].edge and not edge then
        id = along and "grind50" or "boardslide"
    end
    return id
end

-- Is the board turned along the rail's line or across it? `angle` is the angle
-- between the board's forward and the rail's line, 0..pi/2 once folded (a board
-- pointing against the rail is as along it as one pointing with it).
function B.IsAlong(angle)
    local a = abs(angle) % math.pi
    if a > math.pi / 2 then a = math.pi - a end
    return a <= T.alongAngle
end

-- The point of the board (board space) that rides the rail for a grind: on a round
-- rail the middle of the deck's line, on a ledge the board hangs over the drop, so
-- the contact is `sgn` * grindEdgeY to the side the ledge's top is on (an across
-- slide has the ledge's edge straight under it).
function B.GrindContact(id, edge, sgn)
    local g = B.Grinds[id]
    local y = (edge and g.along) and (sgn or 1) * T.grindEdgeY or 0
    return Vector(g.x, y, g.z)
end

-- WHERE THE SPARKS COME FROM (cl_grind.lua asks by the grind code the server
-- networks, ENT:GetGrind): codes 1 to 3 are the bike's; the board's start at 4.
-- 4 both trucks, 5 the back truck, 6 the front truck, 7 the deck's middle, 8 the
-- nose, 9 the tail. Board space.
B.SparkCode = { grind5050 = 4, grind50 = 5, smith = 5, feeble = 5, nosegrind = 6, crooked = 6,
                boardslide = 7, lipslide = 7, noseslide = 8, tailslide = 9 }
function B.SparkPoints(code)
    local z, tx, tip = T.truckZ, T.truckX, T.tipX
    if code == 4 then return { Vector(tx, 0, z), Vector(-tx, 0, z) }
    elseif code == 5 then return { Vector(-tx, 0, z) }
    elseif code == 6 then return { Vector(tx, 0, z) }
    elseif code == 7 then return { Vector(0, 0, T.deckZ) }
    elseif code == 8 then return { Vector(tip, 0, T.deckZ) }
    elseif code == 9 then return { Vector(-tip, 0, T.deckZ) } end
    return {}
end

for _, id in ipairs(B.GrindOrder) do
    local g = B.Grinds[id]
    BMX.RegisterTrick{ id = id, name = g.name, kind = "grind",
        points = BMX.Config.Grind.pointsPerSec * g.mult, input = g.input }
end

-- THE MANUALS, held on the ground (RMB; with ALT the nose manual) and balanced
-- with W and S against a meter (the HUD's), scored per second held.
BMX.RegisterTrick{ id = "board_manual", name = "Manual", kind = "ground",
    points = T.manualRate.manual, input = "RMB on the ground (W / S balance it)" }
BMX.RegisterTrick{ id = "board_nosemanual", name = "Nose Manual", kind = "ground",
    points = T.manualRate.nose, input = "ALT + RMB on the ground (W / S balance it)" }

-- THE BALANCE METER. A value in -1..1 that drifts away from zero faster the further
-- it is (an inverted pendulum, so it can be held and cannot be ignored) with a
-- slow wobble on top, and that the rider's keys push back. Past 1 either way
-- the trick is over: `unstable` is how hard it runs away, `wobble` the amplitude
-- of the disturbance, `control` what a key can do about it. Pure, so the suite
-- can run it. `m` is { v = value, t = time, phase = radians }; `push` is the key,
-- -1..1, already signed so that a positive push raises the meter.
function B.MeterStep(m, dt, push, P)
    m.t = (m.t or 0) + dt
    local w = P.wobble * (math.sin(1.9 * m.t + (m.phase or 0)) * 0.65
        + math.sin(4.3 * m.t + 2 * (m.phase or 0)) * 0.35)
    -- It starts off true by a little, one way or the other by the phase, so an
    -- unattended meter is lost in a few seconds whatever the wobble does.
    if m.v == nil then m.v = 0.12 * (math.sin((m.phase or 0) * 3.7 + 1) >= 0 and 1 or -1) end
    m.v = m.v + (P.unstable * m.v + w + P.control * push) * dt
    return m.v
end

--------------------------------------------------------------------------
-- THE GRABS (G17's pose system). RMB in the air, and a direction, puts a hand on
-- the deck: the pose is held and scored per tenth of a second (Tricks.poseTick),
-- merged with a spin into one trick when both are in the same air ("360 Indy"),
-- and must be let go of before the wheels touch or the landing bails
-- (sv_tricks.lua). The IK targets are cl_board.lua's (B.GrabRows).
--
--   RMB          method      RMB+A    indy         RMB+D   melon
--   RMB+W        nosegrab    RMB+S    tailgrab     RMB+S+D stalefish
--------------------------------------------------------------------------
B.GrabOrder = { "method", "indy", "melon", "nosegrab", "tailgrab", "stalefish" }
local GRAB_DEF = {
    method    = { name = "Method",    per = 14, input = "RMB in the air" },
    indy      = { name = "Indy",      per = 10, input = "RMB + A in the air" },
    melon     = { name = "Melon",     per = 10, input = "RMB + D in the air" },
    nosegrab  = { name = "Nosegrab",  per = 10, input = "RMB + W in the air" },
    tailgrab  = { name = "Tailgrab",  per = 10, input = "RMB + S in the air" },
    stalefish = { name = "Stalefish", per = 12, input = "RMB + S + D in the air" },
}
B.Grabs = GRAB_DEF

-- The grab the keys pick (RMB being down). `k` is B.Keys.
function B.GrabFor(k)
    if k.s and k.d and not k.w then return "stalefish" end
    if k.w and not k.s then return "nosegrab" end
    if k.s and not k.w then return "tailgrab" end
    if k.a and not k.d then return "indy" end
    if k.d and not k.a then return "melon" end
    return "method"
end

for _, id in ipairs(B.GrabOrder) do
    local g = GRAB_DEF[id]
    BMX.RegisterTrick{ id = id, name = g.name, kind = "pose", pose = id, points = g.per, input = g.input,
        canStart = function(st) return st.airMode and true or false end }
end

--------------------------------------------------------------------------
-- THE STYLE: reverts, powerslides, switch. A revert is a half turn on landing on
-- a steep surface (A or D within revertWindow of touching down, on a surface
-- steeper than revertSlope) that keeps the combo, which is the THPS combo glue. A
-- powerslide is CTRL with A / D at speed: the board is turned slideAngle off its
-- travel and scrubs. Switch is LMB on the ground at a roll.
--------------------------------------------------------------------------
T.revertWindow = 0.3
T.revertSlope  = math.rad(25)
T.revertTime   = 0.28
T.revertPoints = 100
T.slideAngle   = math.rad(35)
T.slideRate    = math.rad(420)      -- the fastest the board is turned into or out of a slide
T.slideMinSpeed = 80
T.slideMinTime = 0.5
T.slideRatePay = 80
T.swapMaxSpeed = 220

BMX.RegisterTrick{ id = "board_revert", name = "Revert", kind = "custom", points = T.revertPoints,
    input = "A / D on touching down on a transition" }
BMX.RegisterTrick{ id = "board_powerslide", name = "Powerslide", kind = "ground", points = T.slideRatePay,
    input = "CTRL + A / D at speed" }

-- Does a landing on a surface with this normal qualify for a revert?
function B.RevertSurface(normal)
    return normal.z < math.cos(T.revertSlope)
end
