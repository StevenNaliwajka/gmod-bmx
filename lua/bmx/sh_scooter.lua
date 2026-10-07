--[[--------------------------------------------------------------------------
    bmx/sh_scooter.lua

    THE KICK SCOOTER (G24), the third park vehicle, and the cheapest one: it is
    almost nothing but things the platform and the other two already had.

        family   scooter               the spawn menu's Scooters heading, bmx_allow_scooters
        wheels   two, in line          BMX.BikeWheels: the front steered by the fork
        balance  singletrack           the bike's own: lean-derived steering, held up by
                                       the controller. A scooter is single-track, so it
                                       needs the same thing a bike does and nothing else.
        drive    push                  the BOARD's kick (sv_board.lua), with the foot drag
                                       switched off: a scooter brakes with its fender
        input    scooter               this file's map: the bike's keys, without a sprint
        pose     scooter               cl_scooter.lua: both feet on the deck, hands on the bars

    WHAT IS DIFFERENT FROM A BIKE is the geometry and three small numbers, all of it
    data in the `physics` table below:

      * A SMALL TRAIL. A real scooter has a steep head tube and almost no trail, which
        is why it is twitchy: the steering answers a lean at once and has little of the
        self-righting a bike's trail gives. Here the trail's stand-in is the lag on the
        bars (Balance.steerRate, sv_balance.lua step 3: "a mild first-order lag on the
        bars, standing in for trail"), so a small trail is a high rate.
      * SMALL WHEELS: radius 5 on a 28-unit wheelbase. They roll over less, and with
        110 mm wheels that is true to life.
      * THE REAR FENDER BRAKE. S is the rear brake of the platform, as it is on the
        city bike; a scooter has no front brake at all (the input map has none on the
        ground), which is also why LMB is free for the tailwhip.

    THE TRICKS are the bike's air set plus the two part tricks of G03, and a few of
    its own:

      * TAILWHIP and BARSPIN are G03's, unchanged: the part turns kinematically
        (sv_tricks.lua), auto-completes past 270 degrees and snaps back under 90. On a
        scooter the part that turns is the DECK, which is exactly the part G03 turns
        (the rear group, round the steer tube): that is why a scooter tailwhip is so
        much more natural than a bike's, and why no new physics was written for it.
      * BRI FLIP: a tailwhip and a front or back flip in the same air (sv_scooter.lua).
      * FLIPS, 360s and style poses are the bike's (sv_air.lua).
      * MANUALS are the bike's wheelie on the rear wheel, called a manual here.
      * GRINDS: 50-50 (the deck on the rail), smith (the front peg) and feeble (the
        back peg), through `grindPoints.moves` exactly as the board's are. The pegs
        are on the axles, so the two peg grinds need an EDGE (a ledge or coping) to
        hang the wheels over; on a round rail only the deck can ride it.

    EVERYTHING NUMERIC IS IN BMX.Scooter.Tune and the registration's `physics`, for
    the reason the board's is: one place, and the tests read the same table.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Scooter = BMX.Scooter or {}
local SC = BMX.Scooter

local abs = math.abs

--------------------------------------------------------------------------
-- THE TUNING. Source units: inches, kilograms, seconds.
--------------------------------------------------------------------------
SC.Tune = {
    -- The push: a kick every kickInterval while W is held, adding `torque` u/s at a
    -- standstill and less as it speeds up (B.KickDv), to nothing at maxSpeed. A
    -- scooter is kicked more often and a little harder than a board: it has a
    -- deck to stand on while it rolls, and a rider on one kicks all the time.
    kick = 46, maxSpeed = 330, kickInterval = 0.55,

    -- The geometry the drawing and the grind contacts share (chassis space, x
    -- forward, the origin on the axle line). The deck's top is `deckTop` over the
    -- axles; the head tube leans back `headLean` units from its foot to its top.
    deckTop   = 1.7,
    deckFront = 12.2, deckBack = -9,      -- the deck runs from the neck back to over the rear wheel
    deckWidth = 5.0,
    barHeight = 35,
    barWidth  = 22,
    headFoot  = 1.6,           -- how far behind the front axle the steer axis starts
    headLean  = 4.0,           -- ...and how much further back it is at the top

    -- Where the rider's feet go on the deck (x), and which side of the deck's middle
    -- (so the stance is a little sideways, front foot ahead).
    footFront = 6.5, footBack = -3.5,

    -- THE GRINDS. See SC.Grinds. The deck rides a rail with the point `deckZ` (its
    -- underside, below the wheel boxes' floor so they clear the rail, like the
    -- bike's chainring); a peg rides it at the axle line's `pegZ`, `pegY` out from
    -- the middle (the pegs stick out each side of the axle).
    deckZ = -1.2, pegZ = -0.2, pegY = 3.6, edgeY = 2.4,
    alongAngle = math.rad(45),     -- within this of the rail's line it is a grind; past it, none

    -- BRI FLIP: the whip and the flip each pay as they would alone, and this much more
    -- on top, because doing both in one air is the trick.
    briBonus = 0.5,
}
local T = SC.Tune

--------------------------------------------------------------------------
-- THE INPUT MAP: the bike's, without the sprint and without a front brake on the
-- ground. W kicks (and in the air is nose down), S is the fender brake, A and D
-- lean, SPACE hops, RMB is the manual, LMB with A / D is the tailwhip, R the
-- barspin on the air (and the bell on the ground), CTRL the tuck, ALT the style
-- modifier. A key that is not here is never down (sv_input.lua), so the bike's
-- decoder is reused whole and the keys it would read for a sprint are just off.
--------------------------------------------------------------------------
local G, A, GR, M = "ground", "air", "grind", "manual"

BMX.RegisterInputMap{
    id = "scooter", label = "Scooter",
    actions = {
        forward     = { key = IN_FORWARD,   ctx = { G, A, GR }, label = "Kick / nose down" },
        back        = { key = IN_BACK,      ctx = { G, A, GR }, label = "Rear fender brake / nose up" },
        left        = { key = IN_MOVELEFT,  ctx = { G, A },     label = "Lean left" },
        right       = { key = IN_MOVERIGHT, ctx = { G, A },     label = "Lean right" },
        tuck        = { key = IN_DUCK,      ctx = { G, A },     label = "Tuck" },
        brakeFront  = { key = IN_ATTACK,    ctx = { A, GR },    label = "Tailwhip (there is no front brake)" },
        weightBack  = { key = IN_ATTACK2,   ctx = { G, A, M },  label = "Manual / 360" },
        hop         = { key = IN_JUMP,      ctx = { G, A },     label = "Bunny hop" },
        bar         = { key = IN_RELOAD,    ctx = { G, A, M },  label = "Bell / barspin" },
        alt         = { key = IN_WALK,      ctx = { A, M },     label = "Style modifier" },
    },
}

BMX.RegisterPoseSet("scooter", { label = "Scooter: both feet on the deck, hands on the bars" })

--------------------------------------------------------------------------
-- THE KEYS, as booleans, from whichever fields the rider's input has: in the air
-- the bike's decoder turns W and S into the pitch target (W nose down: negative),
-- on the ground into the throttle and the rear brake, and a scripted rider writes
-- those fields directly. A and D are the lean target. Quantised at a half so a
-- gamepad stick has to mean it.
--------------------------------------------------------------------------
function SC.Keys(inp)
    inp = inp or {}
    local thr, brk, pit, lean = inp.throttle or 0, inp.brakeRear or 0, inp.pitchTarget or 0, inp.leanTarget or 0
    return {
        w = thr > 0.5 or pit < -0.5,
        s = brk > 0.5 or pit > 0.5,
        a = lean < -0.5,
        d = lean > 0.5,
    }
end

--------------------------------------------------------------------------
-- THE GRINDS. A move is a CONTACT RULE (the board's idea, sh_board.lua): which
-- point of the scooter rides the rail, and how it sits on it.
--
--      none      50-50     the deck's underside on the rail (a pipe or a ledge)
--      W         smith     the front peg on a ledge's edge, the nose a little over
--      S         feeble    the back peg on a ledge's edge, the tail a little over
--
-- The keys are the ones held as the scooter locks on. `edge` marks the moves that
-- need a ledge or coping, an edge to hang the wheels over: on a round rail they
-- fall back to the 50-50. `x` is where on the deck the rail is (the pegs are on the
-- axles, so theirs depend on the wheelbase and are filled in by SC.GrindContact),
-- `pitch` the nose-up angle held, `yaw` how far the scooter is turned off the line
-- of the rail, `mult` the points multiplier on the grind's rate. `toward` (the peg grinds)
-- is which side of the ledge the NOSE is turned to: the peg is on the top side and the
-- wheels have to hang over the drop, so the smith (front peg) turns its nose onto the
-- top, which swings the tail out over the drop, and the feeble (back peg) the nose out
-- over the drop, the front wheel with it. Turned the other way the far wheel would be
-- inside the ledge, and the pose would be refused for want of room (sv_grind.lua). The
-- yaw is small for the same reason: the wheel at the peg is a box 10 long and 2.4 wide, and
-- turned further than about 18 degrees its far corner is over the ledge's top
-- (tests/test_scooter.lua checks the corner against the angle).
--------------------------------------------------------------------------
SC.Grinds = {
    scooter_5050   = { name = "50-50",        x = -2,  z = T.deckZ, pitch = 0,    yaw = 0,    mult = 1.0,
                       input = "hop onto a rail along it (a pipe or a ledge), no other key" },
    scooter_smith  = { name = "Smith Grind",  peg = "front", z = T.pegZ, pitch = -0.1, yaw = 0.2, mult = 1.5, edge = true,
                       toward = "top",  input = "W as you land on a ledge's edge, along it" },
    scooter_feeble = { name = "Feeble Grind", peg = "back",  z = T.pegZ, pitch = 0.1,  yaw = 0.2, mult = 1.5, edge = true,
                       toward = "drop", input = "S as you land on a ledge's edge, along it" },
}
SC.GrindOrder = { "scooter_5050", "scooter_smith", "scooter_feeble" }

-- The grind the keys pick, on a ledge (`edge`) or a round rail. `k` is SC.Keys.
function SC.ClassifyGrind(k, edge)
    local id = "scooter_5050"
    if edge and k.w and not k.s then id = "scooter_smith"
    elseif edge and k.s and not k.w then id = "scooter_feeble" end
    return id
end

-- Is the scooter pointed along the rail's line (within alongAngle of it, in either
-- direction), where a scooter can grind it? `angle` is between its forward and the
-- rail's line.
function SC.IsAlong(angle)
    local a = abs(angle) % math.pi
    if a > math.pi / 2 then a = math.pi - a end
    return a <= T.alongAngle
end

-- The point of the scooter (chassis space) that rides the rail for a grind. `half` is
-- half the wheelbase (a peg is on an axle); `edge` is whether it is a ledge, `sgn` the
-- side of the scooter the ledge's top is on (+1 left): on a ledge the whole scooter
-- hangs off the drop, so even the deck's contact is toward the top side.
function SC.GrindContact(id, half, edge, sgn)
    local g = SC.Grinds[id]
    if g.peg then
        return Vector(g.peg == "front" and half or -half, (sgn or 1) * T.pegY, g.z)
    end
    local y = edge and (sgn or 1) * T.edgeY or 0
    return Vector(g.x, y, g.z)
end

-- WHERE THE SPARKS COME FROM (cl_grind.lua asks by the grind code the server
-- networks, ENT:GetGrind): the bike's are 1 to 3 and the board's 4 to 9, so these
-- start at 10: the deck, the front peg, the back peg. Chassis space.
SC.SparkCode = { scooter_5050 = 10, scooter_smith = 11, scooter_feeble = 12 }
function SC.SparkPoints(code, half, sgn)
    half = half or 14
    if code == 10 then return { Vector(-2, 0, T.deckZ) } end
    if code == 11 then return { Vector(half, (sgn or 1) * T.pegY, T.pegZ) } end
    if code == 12 then return { Vector(-half, (sgn or 1) * T.pegY, T.pegZ) } end
    return {}
end

for _, id in ipairs(SC.GrindOrder) do
    local g = SC.Grinds[id]
    BMX.RegisterTrick{ id = id, name = g.name, kind = "grind",
        points = BMX.Config.Grind.pointsPerSec * g.mult, input = g.input }
end

--------------------------------------------------------------------------
-- BRI FLIP: a tailwhip and a flip in the same air. The scoring list for an air
-- already holds both, as "Tailwhip" and "Backflip" or "Frontflip" (with a count of
-- the turns); the pair becomes one entry that counts as two tricks for the combo
-- (`tricks`, sv_combo.lua) and pays both and a bonus. Pure over the list, so the
-- suite can run it. Returns the list, changed in place.
--------------------------------------------------------------------------
BMX.RegisterTrick{ id = "briflip", name = "Bri Flip", kind = "custom", points = 1100,
    input = "a tailwhip (LMB + A / D) and a front or back flip (W / S) in the same air" }

function SC.MergeBri(out, bonus)
    bonus = bonus or T.briBonus
    local whip, flip
    for i, e in ipairs(out) do
        if e.name == BMX.Tricks.tailwhip.name then whip = whip or i end
        if e.name == BMX.Tricks.backflip.name or e.name == BMX.Tricks.frontflip.name then flip = flip or i end
    end
    if not (whip and flip) then return out end
    local w, f = out[whip], out[flip]
    local sum = w.points + f.points
    local merged = { name = BMX.Tricks.briflip.name, count = 1,
                     points = sum + math.floor(sum * bonus), tricks = (w.tricks or 1) + (f.tricks or 1) }
    local first, second = math.min(whip, flip), math.max(whip, flip)
    table.remove(out, second)
    out[first] = merged
    return out
end

--------------------------------------------------------------------------
-- THE VEHICLE.
--
-- Physics, scaled down from the stock bike's by what a scooter is: 62 kg (the rider
-- standing on 4 kg of scooter), 5-unit wheels on a 28-unit wheelbase, a hull that is
-- a tall narrow rider on a short deck. The suspension is the rider's legs again,
-- sprung to carry m g / 2 at about two units of sag; the damper is 0.6 of critical
-- against the effective mass at the patch, as the bike's is (sh_config.lua).
--
--   Wheel.restLength 4      with radius 5 the wheel boxes' floor is -(5 - 4) = -1, the
--                           deck's underside at -1.2 below it (the grind contact)
--   Drive.rearBrake 60000   a fender is a flexing plate and not a disc: a firm stop that
--                           stays under what the rear tyre's grip can hold (1.35 x its
--                           share of the weight, ~25,000 of force at a 5-unit radius)
--   Hop.popSpeed 205        a rider hops a scooter about as well as a BMX
--   Balance.steerRate 15    the small trail (see the top of this file)
--   Balance.maxSteer 44 deg a steeper head angle turns further for the same lean
--
-- The bar box is written in the bike's own 39-unit space because the platform scales
-- it by wheelbase / 39 (BMX.CollisionBoxes); 28 / 39 is the K below.
--------------------------------------------------------------------------
local WHEELBASE = 28
local K = WHEELBASE / 39

SC.GrindPoints = {
    moves = function(...) return SC.GrindMoves(...) end,
    crank = Vector(-2, 0, T.deckZ),
    pegs  = function(cfg)
        local half = cfg.Wheel.wheelbase * 0.5
        return { y = T.pegY, z = T.pegZ, x = { half, -half } }
    end,
}

BMX.RegisterBike("scooter", {
    look        = "scooter",       -- its model (docs/MODELS.md)
    printName   = "Scooter",
    description = "A pro stunt scooter: kick (W), steer by leaning, rear fender brake (S), hop, tailwhip, barspin, bri flip and grind.",
    author      = "Burrito",
    family      = "scooter",
    colorIndex  = 2,
    drive       = { kind = "push", torque = T.kick, maxSpeed = T.maxSpeed, kickInterval = T.kickInterval, footBrake = false },
    input       = "scooter",
    pose        = "scooter",
    seats       = { { offset = Vector(-3, 0, 1.9) } },
    tricks      = { "backflip", "frontflip", "barrel_roll", "spin360", "tailwhip", "barspin", "briflip",
                    "wheelie", "nohander", "nofooter", "cancan_l", "cancan_r", "superman", "nothing",
                    "xup", "turndown", "tabletop",
                    "scooter_5050", "scooter_smith", "scooter_feeble" },
    grindPoints = SC.GrindPoints,
    physics = {
        Chassis = {
            mass = 62,
            hullMin = Vector(-12, -3, 2), hullMax = Vector(8, 3, 50),
            massCenterExpected = Vector(-2, 0, 26),
            wheelHullHalfWidth = 1.2,
            pegHullHalfWidth   = 4.2,
            -- The bars: 35 up, 22 across, 4.8 behind the head tube's top.
            barHullCentre = Vector((WHEELBASE / 2 - 4.8) / K, 0, T.barHeight / K),
            barHullHalf   = Vector(1.5 / K, 11 / K, 1.2 / K),
            seatOffset = Vector(-3, 0, 1.9),
            inertiaRoll = 62 * 14 * 14, inertiaPitch = 62 * 12 * 12, inertiaYaw = 62 * 11 * 11,
        },
        Wheel = {
            radius = 5, wheelbase = WHEELBASE, restLength = 4,
            spring = 9000, damper = 450, bumpStop = 42000,
            inertia = 14, grip = 1.3, rollingResistance = 0.014,
            stepMax = 3.5,
        },
        Drive = { rearBrake = 60000, frontBrake = 0, dragArea = 0.0055, maxCadence = 30 },
        Hop   = { popSpeed = 205, chargeTime = 0.36 },
        Balance = { steerRate = 15, maxSteer = math.rad(44), maxLean = math.rad(38) },
        Grind = { pegY = T.pegY, pegZ = T.pegZ, hopSpeed = 170 },
    },
})
