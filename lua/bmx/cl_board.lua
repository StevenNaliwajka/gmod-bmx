--[[--------------------------------------------------------------------------
    bmx/cl_board.lua

    THE SKATEBOARD, CLIENT SIDE (G23): the player's three board settings, the
    board drawn from tubes and boxes like the bike is, and the rider on it.

    THE BOARD IS A MODEL BUILT IN CODE, as the bike is (zero content, no ripped
    assets; cl_geo_board.lua's "skateboard", docs/MODELS.md): a 7-ply popsicle deck
    with grip, a graphic and its bolts, two trucks whose hangers stay level as the
    deck leans and turn as it carves, four 54 mm wheels. Until it is built (or with
    bmx_bike_model 0, or bmx_debug) a deck of boxes and wheels of tubes stand in.
    Everything the server networks about it (shared.lua: the lean, the crouch,
    the push phase, the deck's three flip angles, the flags) is turned into where
    the parts go here, and nothing is simulated.

    THE DECK IS A SEPARATE BODY FROM THE RIDER. A flip rotates the deck about its
    own axes (the networked bytes) while the chassis, and the rider on it, stay
    put; the rider's feet are targeted at where the deck's bolts were, not where
    they have gone: they lift to let it turn, the flicking foot goes off the edge
    the deck rolls toward, the scooping foot goes with the tail, and they come down
    on it for the catch (B.FlipFeet). That is the part the other skateboard addon
    could not animate, and it is the same trick as the bike's tailwhip: the feet
    stay where the pedals were.

    THE RIDER stands sideways on the deck. The base pose is the stock standing
    idle, the knees bend by lowering the pelvis (calibrated once per model, as the
    fingers' curl is) with both feet pinned to the deck by the same two-bone IK the
    bike's legs use, and the body leans over the toes or the heels into a carve. The
    push turns the hips up the board (a pelvis turn, measured per model the same way)
    while the back foot steps off over the deck's edge, sweeps back flat along the
    ground, and is carried home outside the deck and set back on its bolts, driven by
    the server's push phase and not by an animation; the arms swing against it. The
    ollie's crouch sets the back foot on the tail, the pop drags the front foot up to
    the nose, and the landing folds the knees. Nobody has watched this on a real player
    model: every offset is a number in a table below, and the suite checks each target
    against the deck (tests/test_board_rider.lua).
----------------------------------------------------------------------------]]

BMX = BMX or {}
local B = BMX.Board
local T = B.Tune

--------------------------------------------------------------------------
-- THE PLAYER'S SETTINGS. All userinfo convars: the server reads them off the
-- rider (sv_board.lua), the way it reads bmx_stick_deadzone.
--------------------------------------------------------------------------
CreateClientConVar("bmx_stance", "regular", true, true,
    "BMX skateboard: regular (left foot forward) or goofy (right foot forward).")
CreateClientConVar("bmx_board_flick", "0", true, true,
    "BMX skateboard: 1 = flick the mouse to pick a flip trick (Skate style) instead of W/A/S/D.")
CreateClientConVar("bmx_board_autogrind", "0", true, true,
    "BMX skateboard: 1 = lock onto rails and ledges on contact, without holding SPACE.")

local abs, min, max, sin, cos = math.abs, math.min, math.max, math.sin, math.cos

local function rotVec(v, axis, ang)
    if ang == 0 then return v end
    local c, s = cos(ang), sin(ang)
    return v * c + axis:Cross(v) * s + axis * (axis:Dot(v) * (1 - c))
end

--------------------------------------------------------------------------
-- WHERE THE PARTS ARE, a pure function of what the server networks, so the suite
-- can read it without a renderer. Returns a table of functions and bases:
--
--   P(v)        a point in board space (x forward, y left, z up, units, origin on
--               the chassis's axle line) to the world, with the deck's own flip
--               rotation, the grab lift and the lean applied
--   f, l, u     the deck's own basis vectors, world
--
-- `s`: ent (the chassis: GetPos, GetForward, GetRight, GetUp), lean (rad), roll,
-- yaw, pitch (the flip, rad), lift (units the grabs pull the deck up),
-- liftPitch (rad, the nose raised for a method), ground (the z of the ground
-- under the origin, local: -(radius - sag)).
--------------------------------------------------------------------------
local DECK_Z = 1.4        -- the deck's middle, over the axle line

function B.Frame(s)
    local ent = s.ent
    local O = ent:GetPos()
    local cf, cr, cu = ent:GetForward(), ent:GetRight(), ent:GetUp()
    local f, r, u = cf, cr, cu

    -- The deck's own rotations, about its own axes: the shove-it's yaw, then the
    -- kickflip's roll, then the impossible's pitch.
    if (s.yaw or 0) ~= 0 then f, r = rotVec(f, u, s.yaw), rotVec(r, u, s.yaw) end
    if (s.roll or 0) ~= 0 then r, u = rotVec(r, f, s.roll), rotVec(u, f, s.roll) end
    local pitch = (s.pitch or 0) + (s.liftPitch or 0)
    if pitch ~= 0 then f, u = rotVec(f, r, pitch), rotVec(u, r, pitch) end

    local lean = s.lean or 0
    local G = O + cu * (s.ground or -1.3)
    local center = O + cu * ((s.lift or 0) + DECK_Z)
    local function P(v)
        local p = center + f * v.x - r * v.y + u * (v.z - DECK_Z)
        if lean ~= 0 then p = G + rotVec(p - G, cf, lean) end
        return p
    end
    local lf, lr, lu = f, r, u
    if lean ~= 0 then lf, lr, lu = rotVec(f, cf, lean), rotVec(r, cf, lean), rotVec(u, cf, lean) end
    return { P = P, f = lf, l = -lr, u = lu, r = lr, center = P(Vector(0, 0, DECK_Z)) }
end

--------------------------------------------------------------------------
-- THE FEET. Board-space targets for each foot, in a frame that has the deck's
-- lean and its grab lift but NOT its flip: a carve tilts the deck under the feet
-- and they go with it (or they would slide across the grip), while a flip turns
-- the deck out from under them, which is the trick. x is along the board, y to
-- its left, z over the axle line; the IK pins the ANKLE, which stands ANKLE over
-- the sole, so a foot on the deck is at DECK_TOP + ANKLE.
--
-- Every number is a guess at a real skater and nobody has watched it on a real
-- player model: they are here, in one place, for that reason.
--------------------------------------------------------------------------
local DECK_TOP  = 1.8                       -- the grip's top over the axle line (cl_geo_board.lua)
local ANKLE     = 2.8                       -- the ankle bone over the sole
local FOOT_Z    = DECK_TOP + ANKLE          -- an ankle standing on the deck
local GROUND_Z  = -1.3                      -- the ground, under the axle line
local DECK_HALF = 4.0                       -- half the deck's width
local HEEL_IN   = 2.4                       -- the ankle sits this far from the deck's middle toward
                                            -- the heel edge, so the toes reach the toe edge
local TAIL_X    = 11.4                      -- the ball of the back foot on the tail, for an ollie
local NOSE_X    = 9.8                       -- ...and where the front foot slides to as it levels it
B.Ankle, B.FootZ, B.DeckTop = ANKLE, FOOT_Z, DECK_TOP

local function ease(t) t = max(0, min(1, t)) return t * t * (3 - 2 * t) end
local function lerp(a, b, t) return a + (b - a) * t end
local function lerpV(a, b, t) return a + (b - a) * t end
B.Ease = ease

-- How far the deck's top stands over its flat middle at a distance x along it: flat
-- out to the kicks, then the bend, then the straight kick (cl_geo_board.lua's deck
-- line, 20 and 21 degrees). So a foot on the tail stands on the tail, not in it.
local KICK_AT, KICK_BEND = 9.3, 2.6
function B.DeckRise(x)
    local u = abs(x)
    if u <= KICK_AT then return 0 end
    local A = x >= 0 and math.rad(20) or math.rad(21)
    local Rb = KICK_BEND / A
    local xb = Rb * sin(A)                 -- how far along x the bend reaches
    if u <= KICK_AT + xb then
        return Rb * (1 - cos(math.asin((u - KICK_AT) / Rb)))
    end
    return Rb * (1 - cos(A)) + (u - KICK_AT - xb) * math.tan(A)
end

--------------------------------------------------------------------------
-- THE PUSH, a pure function of the phase (0..1 through a kick interval, -1 not
-- pushing), for the board and the scooter alike. A push is four moves, and each
-- has to be on the right surface:
--
--   STEP OFF  (0 .. STEP)   the foot leaves its bolt, out over the deck's edge
--                           BEFORE it goes down, to the ground beside the front foot
--   STROKE    (.. share)    flat on the ground, sweeping back along it to behind the
--                           tail: this is when the server adds the speed
--                           (kickTime of the interval), so the foot is down for all of it
--   RECOVER   (.. HOME)     the knee lifts the foot off the ground and carries it
--                           forward OUTSIDE the deck, then in over it and down onto
--                           its bolt
--   RIDE      (.. 1)        on the bolt until the next kick
--
-- `g` is the geometry it pushes on (board space): stand (z of an ankle standing on
-- the deck), ground (an ankle on the ground), side (y of the planted foot), plantX,
-- backX (where the stroke starts and ends), share (the stroke's share of the
-- interval). Without it, the board's, for a rider facing its right. Returns the
-- ankle's point and whether the foot is off its bolt.
--------------------------------------------------------------------------
local PUSH_STEP, PUSH_HOME = 0.10, 0.84
local PUSH_LIFT = 3.0          -- how far over the deck the foot is carried back in

function B.PushGeo(T0, faceY)
    T0 = T0 or T
    return {
        stand = FOOT_Z, ground = GROUND_Z + ANKLE,
        side = (faceY or -1) * (DECK_HALF + 3.2),
        plantX = (T0.footFront or T.footFront) - 1.2, backX = -15.0,
        deckHalf = DECK_HALF,
        share = (T0.kickTime or T.kickTime) / (T0.kickInterval or T.kickInterval),
    }
end

-- The phase's marks for a geometry: the stroke is on the ground from STEP to a
-- little past the force (so the foot never lifts while it is still pushing).
function B.PushMarks(g)
    local stroke = math.Clamp(g.share + 0.04, PUSH_STEP + 0.15, PUSH_HOME - 0.2)
    return PUSH_STEP, stroke, PUSH_HOME
end

function B.PushFoot(p, bolt, T0, g)
    if not p or p < 0 or p >= 1 then return bolt, false end
    g = g or B.PushGeo(T0)
    local a, b, c = B.PushMarks(g)
    local plant = Vector(g.plantX, g.side, g.ground)
    local back  = Vector(g.backX, g.side, g.ground)
    if p < a then
        -- Out first, then down: y gets most of the way before z starts to fall, and z
        -- arcs up over the deck's edge on the way.
        local t = p / a
        local y = lerp(bolt.y, g.side, ease(t * 1.6))
        local z = bolt.z + PUSH_LIFT * 0.6 * sin(math.pi * min(1, t * 1.25))
        if t > 0.45 then z = z + (g.ground - bolt.z) * ease((t - 0.45) / 0.55) end
        return Vector(lerp(bolt.x, plant.x, ease(t)), y, z), true
    elseif p < b then
        -- Flat on the ground. The sweep starts slow (the foot bites) and speeds up
        -- as the leg straightens behind.
        local t = (p - a) / (b - a)
        return Vector(lerp(plant.x, back.x, t * t * (2 - t) * 0.35 + ease(t) * 0.65), g.side, g.ground), true
    elseif p < c then
        local t = (p - b) / (c - b)
        local over = Vector(bolt.x - 1.0, g.side, g.stand + PUSH_LIFT)
        if t < 0.55 then
            -- Up and forward, still beside the deck: the knee comes up first.
            local u = t / 0.55
            return Vector(lerp(back.x, over.x, ease(u)), g.side, lerp(g.ground, over.z, ease(min(1, u * 1.4)))), true
        end
        -- In over the deck, then down onto the bolt: it is over the deck before it
        -- is as low as the deck.
        local u = (t - 0.55) / 0.45
        return Vector(lerp(over.x, bolt.x, ease(u)), lerp(g.side, bolt.y, ease(min(1, u * 1.5))),
            bolt.z + PUSH_LIFT * (1 - ease(u) ^ 2)), true
    end
    return bolt, false
end

-- How far the STANDING leg folds through a push, 0..1: the other foot has to reach
-- the ground beside a deck a few inches up, and further behind, so the knee on the
-- deck bends as it reaches and straightens again as the foot comes home.
function B.PushBend(p, g)
    if not p or p < 0 or p >= 1 then return 0 end
    g = g or B.PushGeo()
    local a, b, c = B.PushMarks(g)
    if p < a then return ease(p / a) * 0.8 end
    if p < b then return 0.8 + 0.2 * ease((p - a) / (b - a)) end
    if p < c then return 1 - ease((p - b) / (c - b)) end
    return 0
end

--------------------------------------------------------------------------
-- THE FLIP'S FEET. The deck turns on its own axes while the rider stays, and the
-- feet do what a skater's do: the flicking foot drags up the deck and off its
-- edge the way the deck's top rolls (a kickflip's and a heelflip's go opposite
-- ways), the scooping foot goes with the tail (a shove-it), both lift to let it
-- turn under them, and they come down onto it for the catch.
--
-- `fs` is the drawn flip: roll, yaw, pitch (radians, as networked and followed) and
-- the way each started turning (dRoll, dYaw, dPitch, +1 / -1, B.TrackFlip). Returns
-- offsets (board space) for the popping foot and the flicking foot.
--------------------------------------------------------------------------
local FLIP_LIFT  = 6.0         -- how high both feet go while the deck is on its side
local FLICK_SIDE = 4.5         -- how far off the deck's edge the flick goes
local FLICK_FWD  = 2.5         -- ...and up it, toward the end it flicks off
local SCOOP_SIDE = 3.8         -- the shove-it's scoop, with the tail

-- out to 1 by `o` radians of the deck's turn, held to `h`, back to 0 by `e`
local function bump(th, o, h, e)
    if th <= 0 or th >= e then return 0 end
    if th < o then return ease(th / o) end
    if th < h then return 1 end
    return 1 - ease((th - h) / (e - h))
end

-- How far the deck has turned about one axis, from where it started, the way it is
-- going: the networked angle is a byte, 0..2pi, so a heelflip starts near 2pi.
local function turned(a, dir)
    if not dir or a == 0 then return 0 end
    local TAU = math.pi * 2
    return (dir > 0 and a or -a) % TAU
end

-- Which way each axis started turning: set when the deck leaves flat, kept until it
-- is flat again (the server zeroes all three on the landing).
function B.TrackFlip(st, roll, yaw, pitch)
    local function w(a) return (a + math.pi) % (math.pi * 2) - math.pi end
    if abs(w(roll)) < 1e-3 and abs(w(yaw)) < 1e-3 and abs(w(pitch)) < 1e-3 then
        st.dRoll, st.dYaw, st.dPitch = nil, nil, nil
        return st
    end
    if not st.dRoll and abs(w(roll)) >= 1e-3 then st.dRoll = w(roll) > 0 and 1 or -1 end
    if not st.dYaw and abs(w(yaw)) >= 1e-3 then st.dYaw = w(yaw) > 0 and 1 or -1 end
    if not st.dPitch and abs(w(pitch)) >= 1e-3 then st.dPitch = w(pitch) > 0 and 1 or -1 end
    return st
end

function B.FlipFeet(fs)
    local roll, yaw, pitch = fs.roll or 0, fs.yaw or 0, fs.pitch or 0
    local lift = max(abs(sin(roll * 0.5)), abs(sin(pitch * 0.5)), 0.6 * abs(sin(yaw))) * FLIP_LIFT
    local pop, flick = Vector(0, 0, lift), Vector(0, 0, lift)
    -- The flick: the deck's top rolls toward -Y for a positive roll (B.Frame), and
    -- the foot that flicked it leaves the same way, up toward its end of the deck.
    local tr = turned(roll, fs.dRoll)
    if tr > 0 then
        local k = bump(tr, 1.2, 3.6, 5.6)
        flick = flick + Vector(FLICK_FWD * k, -fs.dRoll * FLICK_SIDE * k, 1.5 * k)
    end
    -- The scoop: a positive yaw swings the tail toward -Y, and the back foot with it.
    local ty = turned(yaw, fs.dYaw)
    if ty > 0 then
        local k = bump(ty, 0.8, 1.8, 2.9)
        pop = pop + Vector(-1.5 * k, -fs.dYaw * SCOOP_SIDE * k, 0.5 * k)
    end
    -- The impossible wraps the deck round the back foot, which stays low with it; the
    -- front foot gets right out of the way.
    local tp = turned(pitch, fs.dPitch)
    if tp > 0 then
        local k = bump(tp, 1.0, 4.0, 5.8)
        pop = pop - Vector(0, 0, lift * 0.6 * k)
        flick = flick + Vector(0, 0, 4 * k)
    end
    return pop, flick
end

--------------------------------------------------------------------------
-- WHERE BOTH FEET GO, a pure function of the rider's state, so the suite can check
-- every target against the deck. `s`:
--   stance   +1 left foot forward, -1 right
--   push     the networked push phase (-1, or 0..1); pushW the drawn weight of the
--            push, 0..1 (the front foot turns to point up the board while it is on)
--   crouch   0..1, the ollie's preload (SPACE held)
--   airT     seconds since the board left the ground, nil on it
--   ollie    true when it left the ground from a crouch (a pop, not a roll off a drop)
--   nollie   the pop was off the nose
--   manual   "manual" / "nose" / nil
--   flip     B.TrackFlip's table with roll, yaw, pitch
-- Returns front, back (board space, the ankle), and whether the back foot is pushing.
--------------------------------------------------------------------------
local OLLIE_SLIDE, OLLIE_LEVEL = 0.16, 0.36       -- s after the pop: the slide, then level

function B.RiderFeet(s)
    local stance = s.stance or 1
    local faceY = stance >= 0 and -1 or 1
    local yIn = -faceY * HEEL_IN
    local ff, fb = T.footFront, T.footBack
    local front = Vector(ff, yIn, FOOT_Z)
    local back  = Vector(fb, yIn, FOOT_Z)

    -- THE OLLIE. The crouch sets it up: the back foot's ball on the tail, the front
    -- foot back toward the middle. The pop snaps the tail, the front foot drags up
    -- toward the nose and levels the board, and both come back over the bolts for the
    -- landing. A nollie is the same, end for end.
    local crouch = s.crouch or 0
    local popFoot, slideFoot = back, front
    local function onDeck(x, y) return Vector(x, y, FOOT_Z + B.DeckRise(x)) end
    -- along the deck's top from one standing place to another, over the kick's bend
    local function slide(a, b, u) return onDeck(lerp(a.x, b.x, u), lerp(a.y, b.y, u)) end
    local sg = s.nollie and -1 or 1                  -- +1: the tail pops
    local setPop   = onDeck(-sg * TAIL_X, yIn * 0.5)
    local setSlide = onDeck(sg * (ff - 2.4), yIn)
    local homePop, homeSlide = s.nollie and front or back, s.nollie and back or front
    if s.airT and s.ollie then
        local t = s.airT
        if t < OLLIE_SLIDE then
            local u = ease(t / OLLIE_SLIDE)
            popFoot = setPop
            slideFoot = slide(setSlide, onDeck(sg * NOSE_X, yIn), u)
        else
            local u = ease((t - OLLIE_SLIDE) / (OLLIE_LEVEL - OLLIE_SLIDE))
            popFoot = slide(setPop, homePop, u)
            slideFoot = slide(onDeck(sg * NOSE_X, yIn), homeSlide, u)
        end
    elseif crouch > 0 and not s.airT then
        local u = ease(crouch * 1.6)
        popFoot, slideFoot = slide(homePop, setPop, u), slide(homeSlide, setSlide, u)
    else
        popFoot, slideFoot = homePop, homeSlide
    end
    if s.nollie then front, back = popFoot, slideFoot else back, front = popFoot, slideFoot end

    -- A MANUAL: the weight on the wheels that are down, the other foot light and
    -- back toward the middle.
    if not s.airT and s.manual == "manual" then
        front = Vector(ff - 1.6, yIn, FOOT_Z)
    elseif not s.airT and s.manual == "nose" then
        back = Vector(fb + 1.6, yIn, FOOT_Z)
    end

    -- THE FLIP. The popping foot is the back one (the front on a nollie), the
    -- flicking foot the other.
    local fl = s.flip
    if fl and (fl.dRoll or fl.dYaw or fl.dPitch) then
        local pop, flick = B.FlipFeet(fl)
        if s.nollie then
            -- end for end: each foot's reach along the board is toward its own end
            front, back = front + Vector(-pop.x, pop.y, pop.z), back + Vector(-flick.x, flick.y, flick.z)
        else
            back, front = back + pop, front + flick
        end
    end

    -- THE PUSH. The front foot turns to point up the board (its ankle onto the middle
    -- line) and stays on its bolt; the back foot does the push.
    local pushing = false
    local w = s.pushW or ((s.push or -1) >= 0 and 1 or 0)
    if w > 0 then front = Vector(front.x, lerp(front.y, 0, w), front.z) end
    if (s.push or -1) >= 0 and not s.airT then
        back, pushing = B.PushFoot(s.push, back, T, B.PushGeo(T, faceY))
    end
    return front, back, pushing
end

--------------------------------------------------------------------------
-- THE ARMS. A skater's arms are for balance: loose and a little out in front at
-- a cruise, swung against the pushing leg, carried over the toes in a crouch, up
-- and out in the air, out wide and see-sawing on a manual or a grind as the meter
-- drifts. Chassis space, like the feet; `faceY` is the side the rider faces.
-- `s`: stance, lean (the deck's, rad), pushW, push, drop (units the pelvis is down),
-- crouch, airT, balance (the meter, -1..1, on a manual or a grind, else nil).
-- Returns the lead hand (the nose's side) and the trailing one.
--------------------------------------------------------------------------
function B.RiderHands(s)
    local stance = s.stance or 1
    local faceY = stance >= 0 and -1 or 1
    local lead  = Vector(12, faceY * 4, 35)
    local trail = Vector(-12, faceY * 3, 34)

    -- Into the carve: the deck's top leans toward -Y for a positive lean, and the
    -- body and its arms go with it.
    local lean = s.lean or 0
    local side = Vector(0, -sin(lean) * 10, -abs(sin(lean)) * 2)
    lead, trail = lead + side, trail + side

    -- In the air: up and out, wider, the way a rider holds their balance off a pop.
    if s.airT then
        local k = ease(s.airT / 0.15)
        lead = lead + Vector(4, faceY * 2, 6) * k
        trail = trail + Vector(-4, faceY * 1, 5) * k
    end

    -- On a manual or a grind: out wide, see-sawing against the meter.
    if s.balance then
        local m = math.Clamp(s.balance, -1, 1)
        lead = Vector(17, faceY * 2, 38 + 7 * m)
        trail = Vector(-17, faceY * 2, 38 - 7 * m)
    end

    -- The push: the body has turned up the board, the arms hang by it and swing
    -- against the pushing leg (as the foot goes back, its own side's arm comes
    -- forward and the other goes back, as in a walk).
    local w = s.pushW or 0
    if w > 0 then
        local g = B.PushGeo(T, faceY)
        local fx = B.PushFoot(s.push or -1, Vector(T.footBack, 0, FOOT_Z), T, g).x
        local sw = math.Clamp((g.plantX - fx) / (g.plantX - g.backX), 0, 1)
        local pl = Vector(7 - 5 * sw, faceY * 6, 32)
        local pt = Vector(-1 + 7 * sw, faceY * 7, 31)
        lead, trail = lerpV(lead, pl, w), lerpV(trail, pt, w)
    end

    -- The crouch takes the shoulders down with the pelvis, and the hands forward
    -- over the toes.
    local drop = s.drop or 0
    local c = s.crouch or 0
    lead = lead + Vector(-2 * c, faceY * 3 * c, -drop)
    trail = trail + Vector(2 * c, faceY * 3 * c, -drop)
    return lead, trail
end

--------------------------------------------------------------------------
-- THE GRABS (G17's pose system): which hand goes where on the deck, in board
-- space, for a stance. `faceY` is the side the rider faces, -1 (right) for the
-- left foot forward. A row is hand targets by role (front or back), and what the
-- body and the deck do: spineLean (degrees), boardLift (units the deck is pulled
-- up to the rider), boardPitch (radians of nose up).
--------------------------------------------------------------------------
local GRABS = {
    --   id           role   point on the deck: x, side (+1 = the toe edge), z
    indy      = { hand = "back",  x =  0.0, edge =  1, z = 2.4, lean = 10, lift = 2.0 },
    melon     = { hand = "front", x =  0.5, edge = -1, z = 2.4, lean = 6,  lift = 2.0 },
    stalefish = { hand = "back",  x = -6.5, edge = -1, z = 2.4, lean = 12, lift = 2.0 },
    nosegrab  = { hand = "front", x = 14.0, edge =  0, z = 2.6, lean = 14, lift = 2.5, pitch = 0.18 },
    tailgrab  = { hand = "back",  x = -14.0, edge = 0, z = 2.6, lean = 8,  lift = 2.5, pitch = -0.18 },
    method    = { hand = "front", x =  1.0, edge = -1, z = 3.0, lean = -8, lift = 4.0, pitch = 0.14 },
}
B.GrabRows = GRABS

-- The pose rows for a stance, keyed like BMX.RiderPoses (rHand / lHand targets in
-- board space, spineLean, plus the board's own lift and pitch).
function B.PoseRows(stance)
    local faceY = stance >= 0 and -1 or 1
    -- Facing the right (-Y), the left hand is the front one; facing the left, the right.
    local frontKey = stance >= 0 and "lHand" or "rHand"
    local backKey  = stance >= 0 and "rHand" or "lHand"
    local rows = {}
    for id, g in pairs(GRABS) do
        local row = { spineLean = g.lean, boardLift = g.lift, boardPitch = g.pitch or 0 }
        local key = g.hand == "front" and frontKey or backKey
        row[key] = Vector(g.x, faceY * g.edge * 3.6, g.z)
        rows[id] = row
    end
    return rows
end

--------------------------------------------------------------------------
-- THE POSE SET. `poses` is what BMX.PoseBody reads for the torso; the hand
-- targets are resolved per stance (PoseRows) when the board is drawn.
--------------------------------------------------------------------------
local SET = BMX.PoseSets.board
SET.poses = {}
for id, g in pairs(GRABS) do SET.poses[id] = { spineLean = g.lean } end

-- The stock standing idle, in place of the seated drive pose.
SET.activity = function(ply)
    local seq = ply:LookupSequence("idle_all_01")
    if not seq or seq < 0 then return end
    return ACT_HL2MP_IDLE, seq
end

--------------------------------------------------------------------------
-- LOWERING THE PELVIS, for the crouch. Which way a bone's position offset moves
-- it is a property of the skeleton, so it is MEASURED once per model: each axis
-- of the pelvis is nudged both ways and the one that brings it lowest in the
-- world is the way down. Then the legs' IK, with the feet pinned, does the rest:
-- the knees bend.
--------------------------------------------------------------------------
local PELVIS = "ValveBiped.Bip01_Pelvis"
local pelvisDown = {}        -- model -> unit Vector in the bone's frame, or false

local function refresh(ply)
    ply:InvalidateBoneCache()
    ply:SetupBones()
end

local function boneZ(ply, b)
    local m = ply:GetBoneMatrix(b)
    return m and m:GetTranslation().z
end

local function calibratePelvis(ply, b)
    local best, bestDrop
    ply:ManipulateBonePosition(b, Vector(0, 0, 0))
    refresh(ply)
    local z0 = boneZ(ply, b)
    if not z0 then return nil end
    for _, ax in ipairs({ Vector(1, 0, 0), Vector(0, 1, 0), Vector(0, 0, 1) }) do
        for _, sg in ipairs({ 1, -1 }) do
            ply:ManipulateBonePosition(b, ax * (4 * sg))
            refresh(ply)
            local z = boneZ(ply, b)
            local drop = z and (z0 - z) or 0
            if not bestDrop or drop > bestDrop then best, bestDrop = ax * sg, drop end
        end
    end
    ply:ManipulateBonePosition(b, Vector(0, 0, 0))
    refresh(ply)
    if bestDrop and bestDrop > 1 then return best end
    return nil
end

local CROUCH_DEPTH = 9          -- units the pelvis drops at a full crouch
local RIDE_BEND = 5             -- ...and at rest: riding knees are always soft
local PUSH_DROP = 5             -- ...further on the standing leg as the other reaches the ground
local AIR_TUCK  = 4             -- ...and in the air, the knees up under the rider
B.RideBend = RIDE_BEND

local function lowerPelvis(ply, depth)
    local b = ply:LookupBone(PELVIS)
    if not b then return end
    local model = ply:GetModel()
    if pelvisDown[model] == nil then pelvisDown[model] = calibratePelvis(ply, b) or false end
    local ax = pelvisDown[model]
    if not ax then return end
    ply:ManipulateBonePosition(b, ax * depth)
    ply.bmxPelvis = b
end

-- Shared with the other standing rider (cl_scooter.lua): lowering the pelvis is the
-- same calibrated nudge whoever is crouching.
B.LowerPelvis, B.CrouchDepth = lowerPelvis, CROUCH_DEPTH

-- How far down the pelvis is, units, a pure function so the arms can come down with
-- it. `s`: crouch (the ollie's preload, or a landing's absorb, 0..1), speed, pushBend
-- (B.PushBend), air (0..1, how far into the air tuck).
function B.BodyDrop(s)
    local c = math.Clamp(s.crouch or 0, 0, 1)
    -- NEVER LOCKED STRAIGHT: a skater rides on soft knees, a little deeper with
    -- speed; the crouch and a hop's preload go down from there.
    local bend = RIDE_BEND + math.Clamp((s.speed or 0) / 300, 0, 1) * 1.2
    local d = bend + c * (CROUCH_DEPTH - bend)
    d = d + (1 - c) * ((s.pushBend or 0) * PUSH_DROP + (s.air or 0) * AIR_TUCK)
    return min(d, CROUCH_DEPTH + 2)
end

--------------------------------------------------------------------------
-- TURNING THE HIPS, for the push. A skater pushing faces up the board, not across
-- it: the hips come round, the pushing leg swings straight back under them and the
-- arms swing by the body. Which way a turn of the pelvis bone goes in the world is,
-- again, the skeleton's, so it is MEASURED once per model: each of its three angles
-- is tried and the one that swings the line between the hips round the vertical
-- (without tipping it) is the turn, signed so +degrees is anticlockwise seen from
-- above. A model it cannot measure keeps square hips.
--------------------------------------------------------------------------
local R_THIGH, L_THIGH = "ValveBiped.Bip01_R_Thigh", "ValveBiped.Bip01_L_Thigh"
local pelvisYaw = {}         -- model -> { k = 1|2|3 (p, y, r), gain }, or false
local TRY_DEG = 20

local function hipLine(ply)
    local r, l = ply:LookupBone(R_THIGH), ply:LookupBone(L_THIGH)
    local mr, ml = r and ply:GetBoneMatrix(r), l and ply:GetBoneMatrix(l)
    if not (mr and ml) then return nil end
    return ml:GetTranslation() - mr:GetTranslation()
end

local function angleOf(k, deg)
    return Angle(k == 1 and deg or 0, k == 2 and deg or 0, k == 3 and deg or 0)
end

local function calibratePelvisYaw(ply, b)
    ply:ManipulateBoneAngles(b, Angle(0, 0, 0))
    refresh(ply)
    local d0 = hipLine(ply)
    if not d0 or d0:Length() < 1 then return nil end
    local best
    for k = 1, 3 do
        ply:ManipulateBoneAngles(b, angleOf(k, TRY_DEG))
        refresh(ply)
        local d = hipLine(ply)
        if d then
            local yaw = math.deg(math.atan2(d0.x * d.y - d0.y * d.x, d0.x * d.x + d0.y * d.y))
            local tilt = abs(d.z - d0.z) / d0:Length()
            if abs(yaw) > TRY_DEG * 0.6 and tilt < 0.2 and (not best or abs(yaw) > abs(best.yaw)) then
                best = { k = k, yaw = yaw }
            end
        end
    end
    ply:ManipulateBoneAngles(b, Angle(0, 0, 0))
    refresh(ply)
    if not best then return nil end
    return { k = best.k, gain = TRY_DEG / best.yaw }
end

-- Turn the hips `deg` anticlockwise (from above) from where the pose has them. The
-- angle is kept with the IK's (ply.bmxIK), so getting off (cl_rider.lua) puts it back.
function B.TurnPelvis(ply, deg)
    local b = ply:LookupBone(PELVIS)
    if not b then return end
    local model = ply:GetModel()
    if pelvisYaw[model] == nil then pelvisYaw[model] = calibratePelvisYaw(ply, b) or false end
    local c = pelvisYaw[model]
    if not c then return end
    ply.bmxIK = ply.bmxIK or {}
    if abs(deg) < 0.25 then
        if ply.bmxIK[b] then
            ply:ManipulateBoneAngles(b, Angle(0, 0, 0))
            ply.bmxIK[b] = nil
        end
        return
    end
    local a = angleOf(c.k, math.Clamp(deg * c.gain, -80, 80))
    ply:ManipulateBoneAngles(b, a)
    ply.bmxIK[b] = a
end

local PUSH_TURN = 55            -- degrees the hips come round up the board for a push

-- The bone offsets for the ride: the torso follows the carve and folds with the
-- crouch, the hips come round for a push, the head holds the horizon. Called from
-- the rider hook BEFORE the IK solve (cl_rider.lua), which is why the pelvis is
-- lowered and turned from here. What the drawing worked out this frame (the push's
-- weight, the air) is on the board (bike.bmxRide, set in BMX.DrawVehicle.board).
SET.rider = function(s)
    local bike, ply = s.bike, s.ply
    local R = bike and bike.bmxRide or {}
    local crouch = bike and bike.GetCrouch and bike:GetCrouch() or 0
    crouch = max(crouch, s.hop or 0)
    local stance = R.stance or 1
    local faceSign = stance >= 0 and 1 or -1
    local w = R.pushW or 0
    local drop = B.BodyDrop({ crouch = crouch, speed = s.speed, pushBend = R.pushBend, air = R.air })
    if ply then
        lowerPelvis(ply, drop)
        B.TurnPelvis(ply, faceSign * PUSH_TURN * w)
    end
    -- INTO THE CARVE. A board turns by the rider's weight over the toes or the heels:
    -- a toe-side carve folds them over their toes, a heel-side one sits them back. The
    -- deck's top leans toward -Y for a positive lean, which is the toe side for a
    -- rider facing -Y (regular).
    local lean = bike and bike.GetBoardLean and bike:GetBoardLean() or 0
    local carve = faceSign * math.deg(lean) * 0.7 * (1 - w)
    -- ...and on a manual or a grind, the meter: the body leans the way it is falling
    -- and the arms (B.RiderHands) bring it back.
    local meter = R.balance and R.balance * 6 or 0
    local spine = crouch * 18 + math.deg(s.pitch or 0) * 0.5 + carve + w * 8 + meter
    local twist = math.deg(lean) * 0.3
    return {
        spine = Angle(0, spine, twist),
        head  = Angle(0, -spine * 0.7, -twist * 0.5),
    }
end

--------------------------------------------------------------------------
-- THE RIDER'S IK: both feet on the deck, hands out for balance. The solver is the
-- bike's (BMX.SolveRiderIK), handed a stand-in for the "bike" whose forward is the
-- way the RIDER faces, so the knees and toes point across the deck. Through a push
-- that turns up the board with the hips, so the knees and toes point the way the
-- board goes and the pushing leg swings back under the body.
--------------------------------------------------------------------------
local TOE_TURN = 60             -- degrees the toes come round up the board for a push

function B.FacingFor(bike, stance, pushW)
    local up = bike:GetUp()
    local face = bike:GetRight() * (stance >= 0 and 1 or -1)   -- GetRight() is the board's right
    local a = math.rad(TOE_TURN) * (pushW or 0)
    if a ~= 0 then face = (face * cos(a) + bike:GetForward() * sin(a)):GetNormalized() end
    return face, up
end

SET.solveIK = function(ply, bike)
    local ik = bike.ikTargets
    if not ik or not BMX.SolveRiderIK then return end
    local flags = bike:GetBoardFlags()
    local stance = B.Stance(B.HasFlag(flags, "goofy"), B.HasFlag(flags, "switch"))
    local face, up = B.FacingFor(bike, stance, bike.bmxRide and bike.bmxRide.pushW or 0)
    local proxy = {
        GetForward = function() return face end,
        GetUp = function() return up end,
        GetRight = function() return face:Cross(up):GetNormalized() end,
    }
    BMX.SolveRiderIK(ply, ik, proxy)
end

--------------------------------------------------------------------------
-- THE DRAWING.
--------------------------------------------------------------------------
local COL_GRIP  = Color(26, 26, 29)
local COL_WHEEL = Color(232, 226, 206)
local COL_HUB   = Color(60, 60, 66)
local COL_TRUCK = Color(176, 180, 190)
local MAT_MATTE = "models/debug/debugwhite"
local MAT_CHROME = "phoenix_storms/fender_chrome"

local DECK_LEN, DECK_W, DECK_T = 30.5, 8.0, 0.9
local TIP_LEN, TIP_RISE = 3.6, math.rad(24)

local FLIP_FOLLOW = 40       -- 1/s: the drawn flip follows the networked byte

local function approachAngle(cur, target, rate, dt)
    local d = (target - cur + math.pi) % (math.pi * 2) - math.pi
    if abs(d) < 1e-4 then return target end
    return cur + d * min(1, rate * dt)
end

-- THE MODEL'S DRAWING (cl_geo_board.lua's "skateboard"): the deck where the primitive
-- deck is (the frame's P), each truck's baseplate on the deck (the rear one turned half
-- round, kingpins facing each other), each hanger about its pivot, level with the
-- ground while the deck leans over it and turned by the truck's steer as the board
-- carves, and the wheels on the hangers' axles, turning. `d`: P, level (B.Frame without
-- the lean), center, wheels (BMX.WheelDefs), spins, simRadius (the simulation's wheel,
-- which the spins are for), paint, lod, steer (B.TruckSteer).
local function matFromMap(f)
    local o = f(Vector(0, 0, 0))
    return BMX.BikeMesh.Matrix(o, f(Vector(1, 0, 0)) - o, f(Vector(0, 1, 0)) - o, f(Vector(0, 0, 1)) - o)
end

function B.ModelMaps(model, d)
    local lay = model.layout
    local P = d.P
    local lf, ll, lu = d.level.f, d.level.l, d.level.u
    local maps = { deck = P, trucks = {}, hangers = {}, wheels = {} }
    local function world(b) return lf * b.x + ll * b.y + lu * b.z end
    for ti, sg in ipairs({ 1, -1 }) do
        local ta = lay.truckAt
        -- truck space -> board space: the rear truck is the front one turned half round
        local function Tk(m) return Vector(ta.x * sg + m.x * sg, m.y * sg, ta.z + m.z) end
        maps.trucks[ti] = function(m) return P(Tk(m)) end
        local pv = lay.pivot
        local O = P(Tk(pv))
        local yaw = -sg * (d.steer or 0)          -- a right turn yaws the front truck clockwise
        local c, sn = cos(yaw), sin(yaw)
        local function dirB(b) return world(Vector(b.x * c - b.y * sn, b.x * sn + b.y * c, b.z)) end
        local function H(m)
            local q = m - pv
            return O + dirB(Vector(q.x * sg, q.y * sg, q.z))
        end
        maps.hangers[ti] = H
        -- the wheels on this truck, by their board-space side
        for i, wd in ipairs(d.wheels) do
            if (wd.pos.x >= 0) == (sg > 0) then
                local ty = (wd.pos.y >= 0 and 1 or -1) * lay.track * sg
                local cen = H(Vector(lay.axle.x, ty, lay.axle.z))
                local ex, ey, ez = dirB(Vector(1, 0, 0)), dirB(Vector(0, 1, 0)), dirB(Vector(0, 0, 1))
                -- WheelSpin turns the simulation's wheel (radius 2.2): the drawn one is a
                -- real wheel's size and turns faster for the same speed
                local spin = (d.spins and d.spins[i] or 0) * ((d.simRadius or lay.wheelR) / lay.wheelR)
                maps.wheels[i] = { o = cen, ex = rotVec(ex, ey, spin), ey = ey, ez = rotVec(ez, ey, spin) }
            end
        end
    end
    return maps
end

function B.DrawModel(ent, model, d)
    local BM = BMX.BikeMesh
    local maps = B.ModelMaps(model, d)
    local paint, lod = d.paint, d.lod
    BM.BeginLighting(d.center, ent)
        BM.DrawGroup(model, "deck", matFromMap(maps.deck), paint, lod)
        for ti = 1, 2 do
            BM.DrawGroup(model, "truck", matFromMap(maps.trucks[ti]), paint, lod)
            BM.DrawGroup(model, "hanger", matFromMap(maps.hangers[ti]), paint, lod)
        end
        for _, w in pairs(maps.wheels) do
            BM.DrawGroup(model, "wheel", BM.Matrix(w.o, w.ex, w.ey, w.ez), paint, lod)
        end
    BM.EndLighting()
end

-- The board's built model, or nil while it builds (asking advances the build; the
-- studios pump it, BMX.BikeModelFor).
function BMX.BoardModel(ent)
    local bike, C = ent:Bike(), ent:Cfg()
    local BM, WC = BMX.BikeMesh, C.Wheel
    if not bike.look or not BM then return nil end
    local wheels = BMX.WheelDefs(bike, C)
    return BM.Get(WC.wheelbase / 39, WC.radius, bike.look, {
        wheelbase = WC.wheelbase, restLength = WC.restLength,
        extra = { track = wheels[1] and math.abs(wheels[1].pos.y) or 4.6 },
    })
end

BMX.DrawVehicle = BMX.DrawVehicle or {}
BMX.DrawVehicle.board = function(ent, kit)
    local bike = ent:Bike()
    local C = ent:Cfg()
    local WC = C.Wheel
    local dt = FrameTime()
    local debug = GetConVar("bmx_debug") and GetConVar("bmx_debug"):GetInt() > 0
    local lod = kit.lod(ent, debug)
    local cu = ent:GetUp()
    local flags = ent:GetBoardFlags()
    local stance = B.Stance(B.HasFlag(flags, "goofy"), B.HasFlag(flags, "switch"))

    -- The deck's flip, followed (it arrives a byte at a time), and the pose.
    local roll, yaw, pitch = B.UnpackBits(ent:GetBoardBits())
    ent.drawFlip = ent.drawFlip or { roll = roll, yaw = yaw, pitch = pitch }
    local df = ent.drawFlip
    df.roll  = approachAngle(df.roll,  roll,  FLIP_FOLLOW, dt)
    df.yaw   = approachAngle(df.yaw,   yaw,   FLIP_FOLLOW, dt)
    df.pitch = approachAngle(df.pitch, pitch, FLIP_FOLLOW, dt)
    local _, _, poseId = BMX.UnpackTrickBits(ent:GetTrickBits())
    local W = BMX.UpdatePoseWeights(ent, BMX.PoseNames[poseId], dt)
    local rows = B.PoseRows(stance)
    local lift, liftPitch = 0, 0
    for name, w in pairs(W) do
        local row = rows[name]
        if row then lift = lift + row.boardLift * w; liftPitch = liftPitch + row.boardPitch * w end
    end

    local g = physenv.GetGravity():Length()
    local sag = math.Clamp(C.Chassis.mass * g / 4 / WC.spring, 0, WC.restLength)
    local frame = B.Frame({
        ent = ent, lean = ent:GetBoardLean(), roll = df.roll, yaw = df.yaw, pitch = df.pitch,
        lift = lift, liftPitch = liftPitch, ground = -(WC.radius - sag),
    })
    local P = frame.P
    local bf, bl, bu = frame.f, frame.l, frame.u
    local ang = bf:AngleEx(bu)
    local col = BMX.PaletteColor(ent:GetColorIndex())
    local half = WC.wheelbase * 0.5

    -- THE BUILT MODEL (cl_geo_board.lua), once it is built and unless bmx_bike_model is
    -- 0 or bmx_debug wants the simple board; the primitives below stand in meanwhile.
    local BM = BMX.BikeMesh
    local wheels = BMX.WheelDefs(bike, C)
    local model = not debug and BMX.BoardModel(ent) or nil

    ------------------------------------------------------------------------
    -- Deck: the paint underneath, grip tape on top, the nose and tail kicked up.
    ------------------------------------------------------------------------
    if not model then
        kit.solid("box", P(Vector(0, 0, DECK_Z)), ang, Vector(DECK_LEN, DECK_W, DECK_T), col)
        kit.solid("box", P(Vector(0, 0, DECK_Z + DECK_T * 0.5 + 0.06)), ang,
            Vector(DECK_LEN - 0.4, DECK_W - 0.4, 0.12), COL_GRIP, MAT_MATTE)
        for _, sgn in ipairs({ 1, -1 }) do
            local tf = rotVec(bf, bl, -sgn * TIP_RISE)           -- the end tilts up, away from the middle
            local tu = rotVec(bu, bl, -sgn * TIP_RISE)
            local at = DECK_LEN * 0.5 + TIP_LEN * 0.5 * cos(TIP_RISE) - 0.4
            local p = P(Vector(sgn * at, 0, DECK_Z + sin(TIP_RISE) * TIP_LEN * 0.5))
            kit.solid("box", p, tf:AngleEx(tu), Vector(TIP_LEN, DECK_W, DECK_T), col)
            kit.solid("box", p + tu * (DECK_T * 0.5 + 0.06), tf:AngleEx(tu),
                Vector(TIP_LEN - 0.3, DECK_W - 0.4, 0.12), COL_GRIP, MAT_MATTE)
        end
    end

    ------------------------------------------------------------------------
    -- Trucks and wheels. A wheel is a short cylinder turning with the board's
    -- speed (the bike's WheelSpin), with a hub bolt so the spin shows. Where the
    -- axle is comes from the same trace the suspension makes.
    ------------------------------------------------------------------------
    local spins = {}
    for i, wd in ipairs(wheels) do
        local local_ = Vector(wd.pos.x, wd.pos.y, wd.pos.z)
        local grounded = ent:GetGrounded()
        if lod < 2 then
            local world, hit = kit.axlePos(ent, wd.pos + Vector(0, 0, WC.restLength))
            local_ = ent:WorldToLocal(world)
            grounded = hit
        else
            local_ = Vector(wd.pos.x, wd.pos.y, wd.pos.z + sag)
        end
        local c = P(local_)
        local spin = ent:WheelSpin("w" .. i, grounded, false, dt)
        spins[i] = spin
        if not model then
            local ww = 1.6
            kit.tube(c - bl * (ww * 0.5), c + bl * (ww * 0.5), WC.radius * 2, COL_WHEEL)
            if lod == 0 then
                local pin = (bf * cos(spin) + bu * sin(spin)) * (WC.radius * 0.55)
                kit.tube(c + pin - bl * (ww * 0.55), c + pin + bl * (ww * 0.55), 0.5, COL_HUB)
            end
        end
    end
    if not model and lod < 2 then
        for _, sgn in ipairs({ 1, -1 }) do
            local x = sgn * half
            local hanger = P(Vector(x, 0, 0.2))
            kit.tube(hanger - bl * 5.0, hanger + bl * 5.0, 1.0, COL_TRUCK)
            kit.solid("box", P(Vector(x, 0, DECK_Z - DECK_T * 0.5 - 0.35)), ang,
                Vector(4.2, 3.4, 0.7), COL_TRUCK, MAT_CHROME)
        end
    end
    if model then
        -- The deck's flip without the lean: the hangers stay level on the ground while
        -- the deck leans over them, as a truck's do.
        local level = B.Frame({
            ent = ent, lean = 0, roll = df.roll, yaw = df.yaw, pitch = df.pitch,
            lift = lift, liftPitch = liftPitch, ground = -(WC.radius - sag),
        })
        B.DrawModel(ent, model, {
            P = P, level = level, center = frame.center, wheels = wheels, spins = spins, simRadius = WC.radius,
            paint = col, lod = lod,
            steer = B.TruckSteer(ent:GetBoardLean(), ent.GetSpeedUPS and ent:GetSpeedUPS() or 0, WC.wheelbase),
        })
    end

    ------------------------------------------------------------------------
    -- Where the rider's hands and feet belong (cl_rider.lua's IK reads
    -- ent.ikTargets). The feet are on the deck as it leans and lifts but NOT as it
    -- flips, so a flip leaves them and they catch it (B.RiderFeet); the pushing foot
    -- goes to the ground; the hands balance, or go to the deck for a grab.
    --
    -- What the rider's pose needs and the server does not send is worked out here
    -- from what it does (bike.bmxRide, read by SET.rider): when the board left the
    -- ground and whether that was a pop out of a crouch, which way the flip started,
    -- and how far round the body has turned for the push.
    ------------------------------------------------------------------------
    local now = CurTime()
    local R = ent.bmxRide or {}
    ent.bmxRide = R
    local grounded = ent:GetGrounded()
    if ent:GetCrouch() > 0.05 then R.crouchAt = now end
    if grounded then
        R.airAt = nil
    elseif not R.airAt then
        R.airAt = now
        R.ollie = R.crouchAt ~= nil and now - R.crouchAt < 0.25
    end
    local airT = R.airAt and (now - R.airAt) or nil
    local push = ent:GetPushPhase()
    local pushing = push >= 0 and not airT
    -- The body comes round quickly for a push and goes back slowly after the last, so
    -- a run of kicks is one turned-up stance, not a twist and back every kick.
    local wantW = pushing and 1 or 0
    R.pushW = R.pushW or 0
    R.pushW = R.pushW + math.Clamp(wantW - R.pushW, -4 * dt, 10 * dt)
    R.stance = stance
    R.air = airT and ease(airT / 0.15) or 0
    R.pushBend = pushing and B.PushBend(push) or 0
    R.balance = B.HasFlag(flags, "meter") and ent:GetMeter() or nil
    R.flip = B.TrackFlip(R.flip or {}, df.roll, df.yaw, df.pitch)
    R.flip.roll, R.flip.yaw, R.flip.pitch = df.roll, df.yaw, df.pitch

    local front, back, offDeck = B.RiderFeet({
        stance = stance, push = airT and -1 or push, pushW = R.pushW,
        crouch = ent:GetCrouch(), airT = airT, ollie = R.ollie,
        nollie = B.HasFlag(flags, "nollie"),
        manual = B.HasFlag(flags, "manual") and "manual" or (B.HasFlag(flags, "nose") and "nose" or nil),
        flip = R.flip,
    })
    -- On the deck the feet lean with it; a foot out on the ground for a push is on the
    -- level ground instead, blending over as it steps off the deck's edge.
    local feetFrame = B.Frame({
        ent = ent, lean = ent:GetBoardLean(), lift = lift, liftPitch = liftPitch, ground = -(WC.radius - sag),
    })
    local function onDeck(v) return feetFrame.P(v) end
    local backW = onDeck(back)
    if offDeck then
        local levelFrame = B.Frame({ ent = ent, lean = 0, lift = lift, liftPitch = liftPitch, ground = -(WC.radius - sag) })
        local k = ease((abs(back.y) - HEEL_IN) / (DECK_HALF + 3.2 - HEEL_IN))
        backW = lerpV(backW, levelFrame.P(back), k)
    end
    local frontW = onDeck(front)
    local lFoot = stance >= 0 and frontW or backW
    local rFoot = stance >= 0 and backW or frontW

    local function C2W(v) return ent:LocalToWorld(v) end
    local hc = max(ent:GetCrouch(), ent.bmxLand or 0)
    local lead, trail = B.RiderHands({
        stance = stance, lean = ent:GetBoardLean(), pushW = R.pushW, push = push,
        crouch = hc, airT = airT, balance = R.balance,
        drop = B.BodyDrop({ crouch = hc, speed = ent.GetSpeedUPS and ent:GetSpeedUPS() or 0,
                            pushBend = R.pushBend, air = R.air }) - RIDE_BEND,
    })
    -- The lead hand is on the nose's side: the left for a left-foot-forward stance.
    local ik = {
        lFoot = lFoot, rFoot = rFoot,
        lHand = C2W(stance >= 0 and lead or trail),
        rHand = C2W(stance >= 0 and trail or lead),
    }
    BMX.ApplyPoseTargets(ik, W, function(v) return P(v) end, rows)
    ent.ikTargets = ik

    if debug then
        render.DrawLine(frame.center, frame.center + bf * 12, Color(255, 60, 60), true)
        render.DrawLine(frame.center, frame.center + bu * 12, Color(80, 120, 255), true)
    end
end

--------------------------------------------------------------------------
-- THE HUD: the ollie's preload at the centre, the stance words under the speed,
-- and the BALANCE METER of a manual or a grind (THPS style): a bar with a safe
-- middle and a marker that drifts toward an end, which A / D (a grind) or W / S (a
-- manual) bring back. Pure in B.MeterLayout so the suite can read it.
--------------------------------------------------------------------------
-- The marker's place along a bar `w` wide, and the colour of the zone it is in:
-- green near the middle, amber past two thirds, red past nine tenths.
function B.MeterLayout(meter, w)
    local m = math.Clamp(meter or 0, -1, 1)
    local a = math.abs(m)
    local col = a < 0.66 and Color(120, 220, 120) or (a < 0.9 and Color(240, 190, 80) or Color(235, 90, 60))
    return (m * 0.5 + 0.5) * w, col
end
hook.Add("HUDPaint", "BMX.Board.HUD", function()
    local ply = LocalPlayer()
    if not IsValid(ply) then return end
    local bike = BMX.LocalBike(ply)
    if not bike or bike:Bike().family ~= "board" then return end
    if BMX.CinematicActive and BMX.CinematicActive(ply) then return end
    local sw, sh = ScrW(), ScrH()
    local crouch = bike:GetCrouch()
    if crouch > 0 then
        draw.RoundedBox(3, sw * 0.5 - 60, sh * 0.62, 120, 5, Color(0, 0, 0, 140))
        draw.RoundedBox(3, sw * 0.5 - 60, sh * 0.62, math.floor(120 * crouch), 5,
            crouch >= 0.999 and Color(120, 220, 120) or Color(240, 190, 80))
    end
    local flags = bike:GetBoardFlags()
    if B.HasFlag(flags, "meter") then
        local w, h = 240, 10
        local x, y = sw * 0.5 - w / 2, sh * 0.7
        draw.RoundedBox(4, x, y, w, h, Color(0, 0, 0, 150))
        draw.RoundedBox(4, x + w * 0.17, y, w * 0.66, h, Color(60, 120, 60, 120))
        local px, col = B.MeterLayout(bike:GetMeter(), w)
        draw.RoundedBox(3, x + px - 3, y - 3, 6, h + 6, col)
        local what = B.HasFlag(flags, "grind") and "BALANCE  A / D"
            or (B.HasFlag(flags, "nose") and "NOSE MANUAL  W / S" or "MANUAL  W / S")
        draw.SimpleText(what, "BMX.Small", sw * 0.5, y + h + 6, Color(255, 255, 255, 220),
            TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
    end
    local words = {}
    if B.HasFlag(flags, "switch") then words[#words + 1] = "SWITCH" end
    if B.HasFlag(flags, "fakie") then words[#words + 1] = "FAKIE" end
    if B.HasFlag(flags, "nollie") then words[#words + 1] = "NOLLIE" end
    if #words > 0 then
        draw.SimpleText(table.concat(words, "  "), "BMX.Small", sw - 28 - 125, sh - 34 - 96 - 22,
            Color(255, 255, 255, 230), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
    end
end)
