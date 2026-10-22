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
    idle; the body over the board (B.Posture, 1.4.0) is set from what real skaters
    do, measured off footage: the hips go back and down over the heels as the chest
    comes forward over the toes, the knees over the toes with the front foot turned
    toward the nose, both feet pinned to the deck by the same two-bone IK the bike's
    legs use. The pelvis is moved by a nudge measured once per model (as the
    fingers' curl is), and the back folds over it. The push turns the hips up the
    board (a pelvis turn, measured per model the same way) while the back foot steps
    off over the deck's edge, sweeps back flat along the ground, and is carried home
    outside the deck and set back on its bolts, driven by the server's push phase and
    not by an animation; the arms swing against it. The ollie's crouch sets the back
    foot on the tail, the pop straightens the legs off it and drags the front foot up
    to the nose, the knees come up under the rider in the air, and the landing folds
    them. The suite checks each target against the deck (tests/test_board_rider.lua),
    the joint angles against the footage's (tests/test_board_lifelike.lua), and every
    part of the body against the board and the rest of the body (tests/test_body_clip.lua).
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
local ANKLE     = 4.2                       -- the ankle bone over the sole (kleiner's 4.24, measured
                                            -- on the mesh; 1.3.9's 2.8 sank every sole into the grip)
local FOOT_Z    = DECK_TOP + ANKLE          -- an ankle standing on the deck
local GROUND_Z  = -1.3                      -- the ground, under the axle line
local DECK_HALF = 4.0                       -- half the deck's width
local HEEL_IN   = 2.8                       -- the ankle sits this far from the deck's middle toward
                                            -- the heel edge: a foot 11.8 long (3 behind the ankle,
                                            -- 8.8 ahead) hangs a little over both edges, as a
                                            -- skater's does
local TAIL_X    = 11.4                      -- the ball of the back foot on the tail, for an ollie
local NOSE_X    = 10.4                      -- ...and where the front foot slides to as it levels it
B.Ankle, B.FootZ, B.DeckTop = ANKLE, FOOT_Z, DECK_TOP

local function ease(t) t = max(0, min(1, t)) return t * t * (3 - 2 * t) end
local function lerp(a, b, t) return a + (b - a) * t end
local function lerpV(a, b, t) return a + (b - a) * t end
B.Ease = ease

-- 0 -> 1 by `a` seconds, held to `b`, back to 0 by `c`
local function window(t, a, b, c)
    if t <= 0 or t >= c then return 0 end
    if t < a then return ease(t / a) end
    if t < b then return 1 end
    return 1 - ease((t - b) / (c - b))
end
B.Window = window

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
-- The step off takes an eighth of a second (0.22 of a 0.6 s kick): at 0.10 the foot left
-- the deck in two frames, twelve units a frame at 30 (tools/rider/studio/motion.py).
local PUSH_STEP, PUSH_HOME = 0.22, 0.84
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

-- PLANTED. `strokeX`, when the drawing knows it, is where along the board the foot that
-- went down is now: a foot on the ground stays where it was put while the board runs on
-- from it, so it goes back along the board at the board's speed, not at the phase's
-- (which slid it 17-31 units over the ground at a cruise). The way home starts from
-- wherever the stroke ended (`strokeX` through the rest of the cycle). At speed the
-- board runs out the leg's reach before the phase's stroke is over; the foot leaves the
-- ground then (`liftP`, the phase it reached the back at), as a skater's does, rather
-- than being dragged along behind the tail.
function B.PushFoot(p, bolt, T0, g, strokeX, liftP)
    if not p or p < 0 or p >= 1 then return bolt, false end
    g = g or B.PushGeo(T0)
    local a, b, c = B.PushMarks(g)
    if liftP and liftP > a and liftP < b then b = liftP end
    local plant = Vector(g.plantX, g.side, g.ground)
    local back  = Vector(strokeX and p >= b and strokeX or g.backX, g.side, g.ground)
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
        if strokeX then return Vector(math.Clamp(strokeX, g.backX, g.plantX), g.side, g.ground), true end
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
-- ...and the body's spring off the tail (B.Posture, B.RiderHands): a tenth of a second and
-- more; at 0.06 the body sprang ten units a frame at 30 (tools/rider/studio/motion.py).
local POP_T = 0.12
local OLLIE_DRAG = 5.5        -- units the dragging foot comes up off the grip as it goes
local OLLIE_TAIL = 5.0        -- ...and the popping foot after it, bringing the tail up
-- How far each foot is off the deck `t` s after an ollie's pop: the dragging foot, then
-- the popping one (B.RiderFeet).
function B.OllieLift(t)
    return OLLIE_DRAG * window(t - 0.04, 0.08, 0.16, 0.28), OLLIE_TAIL * window(t - 0.14, 0.08, 0.14, 0.24)
end

-- THE TAIL SNAPS. On footage the pop stands the deck 20-30 degrees nose up for an
-- instant before the front foot levels it; the chassis's own nose kick (sv_board.lua,
-- popNoseKick against the level hold) is about 10. The drawing tilts the deck the rest,
-- about the back truck (it is lifted as it turns, so the tail stays where it struck),
-- and the feet go with it: the back leg straight off the tail, the front knee folding
-- as the nose comes up to it. Radians nose up (down for a nollie) and the lift.
local TILT_MAX, TILT_PIVOT = 0.34, 12.5
function B.OllieTilt(airT, nollie)
    local a = TILT_MAX * window(airT or 0, 0.05, 0.08, 0.28)
    return nollie and -a or a, TILT_PIVOT * math.sin(a)
end

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
        -- THE LEGS SEE-SAW. On footage the front knee folds to 110-120 degrees as the foot
        -- drags up the grip while the back leg is straight off the tail; then the back knee
        -- folds as far, bringing the tail up, while the front leg reaches down to level the
        -- nose; then both come down soft for the landing. They do not move together.
        local up, tail = B.OllieLift(t)
        slideFoot, popFoot = slideFoot + Vector(0, 0, up), popFoot + Vector(0, 0, tail)
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
        back, pushing = B.PushFoot(s.push, back, T, B.PushGeo(T, faceY), s.strokeX, s.liftP)
    end
    return front, back, pushing
end

--------------------------------------------------------------------------
-- THE ARMS. A skater's arms are for balance: hanging loose at a cruise, the lead one
-- a little toward the nose; swung fore and aft against the pushing leg, as in a walk;
-- forward over the knees in a crouch; up and out in the air; out wide and see-sawing
-- on a manual or a grind as the meter drifts.
--
-- FROM THE SHOULDERS. Each hand is an offset from its own shoulder, in the frame the
-- rider faces (x the way they face -- up the board through a push -- y to their left,
-- z up), units for kleiner's arm; cl_rider.lua puts it on the posed shoulder and
-- scales it to the model's arm. They used to be points on the board, worked out for
-- where a body would stand: the real body crouched, leaned and turned for a push, the
-- hands stayed, and the arms reached up and out with the wrists cocked like paws, or
-- folded into the thighs mid-push (kleiner's mesh in the offline studio, 2026-10-19).
-- Hanging, a hand is ARM_HANG below its shoulder: the elbow a little bent, as a loose
-- arm is, whatever the body above it does.
-- `s`: stance, pushW, push, crouch, land (a landing's absorb, 0..1), airT, ollie,
-- balance (the meter, -1..1, on a manual or a grind, else nil), sway (a Vector, the
-- arms' lag behind the body, B.ArmSway), t and seed (B.Posture's drift).
-- Returns the lead hand (the nose's side) and the trailing one.
--
-- MEASURED (1.4.0, the same footage as B.Posture): rolling, the upper arms 20-50
-- degrees out from the body and the elbows 10-60 bent, never held still; the pop
-- throws them up and out (70-120 degrees on the clips), the air holds them out
-- (60-90) with the elbows a little bent, and on a manual they are out but not a
-- scarecrow's T (1.3.9's were straight out at 64-66 degrees, the elbows locked).
--------------------------------------------------------------------------
local ARM_HANG = 22.4        -- shoulder to wrist, kleiner's 23.2 of arm a little bent
-- Where a standing body's shoulders are over the seat, for the estimate the drawing
-- hands out before the solver has the real ones (kleiner in idle_all_01).
local SHOULDER_Z, SHOULDER_W = 64.6, 7.7
local function hang(x, y, len)
    len = len or ARM_HANG
    return Vector(x, y, -math.sqrt(math.max(len * len - x * x - y * y, 1)))
end
B.ArmHang = ARM_HANG
local TAU = math.pi * 2


function B.RiderHands(s)
    local stance = s.stance or 1
    local n = stance >= 0 and 1 or -1       -- the nose's side: the rider's left riding regular
    -- LOOSE: hanging a little out from the body, the lead arm a little forward, as
    -- arms hang off shoulders that are balancing a board.
    local lead  = hang(3.5, n * 8.5)
    local trail = hang(1.5, -n * 7)

    -- The crouch: the hands come forward and down over the knees, a little wider (and
    -- through a pop's first instant, from there: the crouch's networked value is gone the
    -- frame the board leaves the ground, and the hands jumped 19 units in a frame).
    local c = math.Clamp(s.crouch or 0, 0, 1)
    if s.airT and s.ollie then c = math.max(c, 1 - ease(s.airT / POP_T)) end
    if c > 0 then
        lead, trail = lerpV(lead, hang(10, n * 8, 20.5), c), lerpV(trail, hang(8, -n * 7.5, 20.5), c)
    end

    -- In the air: out for balance. Off a pop they are THROWN up and out first, with the
    -- legs' spring, and settle to out-and-down as the knees come up.
    local out = s.airW or (s.airT and ease(s.airT / 0.15) or 0)
    if out > 0 then
        local up = (s.airT and s.ollie) and window(s.airT, 0.08, 0.2, 0.5) or 0
        lead  = lerpV(lead,  lerpV(Vector(4, n * 15.5, -15.5), Vector(6, n * 17.5, -11.5), up), out)
        trail = lerpV(trail, lerpV(Vector(1, -n * 15.5, -15.5), Vector(2, -n * 18, -12), up), out)
    end

    -- A landing: out and down, catching the weight, and back to hanging as it rises.
    local l = math.Clamp(s.land or 0, 0, 1)
    if l > 0 and not s.airT then
        lead, trail = lerpV(lead, Vector(6, n * 13, -16), l * 0.8), lerpV(trail, Vector(2, -n * 13, -16), l * 0.8)
    end

    -- On a manual or a grind: out, elbows bent, see-sawing against the meter -- eased in
    -- and out (`balW`): it was a step of 15 units the frame a manual began and ended.
    local bw = s.balW or (s.balance and 1 or 0)
    if bw > 0 then
        local m = math.Clamp(s.balance or 0, -1, 1)
        lead = lerpV(lead, Vector(3, n * 15, -15 + 5.5 * m), bw)
        trail = lerpV(trail, Vector(1, -n * 14.5, -15 - 5.5 * m), bw)
    end

    -- The push: the body has turned up the board and the arms swing by it, against the
    -- pushing leg -- as the (back) foot goes back, its own side's arm comes forward and
    -- the other goes back, as in a walk.
    local w = s.pushW or 0
    if w > 0 then
        local g = B.PushGeo(T, -n)
        local fx = B.PushFoot(s.push or -1, Vector(T.footBack, 0, FOOT_Z), T, g).x
        local sw = math.Clamp((g.plantX - fx) / (g.plantX - g.backX), 0, 1)
        lead, trail = lerpV(lead, hang(6 - 11 * sw, n * 6), w), lerpV(trail, hang(-5 + 12 * sw, -n * 7), w)
    end

    -- NEVER STILL: a slow drift, each hand on its own (B.HandDrift), unless the caller
    -- adds it after its own smoothing (`noDrift`), and the lag behind the body as the
    -- board speeds up, slows and turns (B.ArmSway): two hands frozen at fixed points
    -- read as a mannequin.
    if not s.noDrift then
        local dl, dtr = B.HandDrift(s.t, s.seed, c, s.balance)
        lead, trail = lead + dl, trail + dtr
    end
    if s.sway then lead, trail = lead + s.sway, trail + s.sway end
    return lead, trail
end

function B.HandDrift(t, seed, crouch, balance)
    t, seed = t or 0, seed or 0
    local quiet = 1 - math.max(crouch or 0, balance and 1 or 0) * 0.6
    return Vector(0.7 * math.sin(t * TAU * 0.19 + seed), 0.5 * math.sin(t * TAU * 0.13 + seed * 2.1),
            0.6 * math.sin(t * TAU * 0.23 + seed * 0.7)) * quiet,
        Vector(0.6 * math.sin(t * TAU * 0.17 + seed * 1.3), 0.5 * math.sin(t * TAU * 0.11 + seed * 0.4),
            0.6 * math.sin(t * TAU * 0.21 + seed * 2.6)) * quiet
end

--------------------------------------------------------------------------
-- THE ARMS' LAG. A body that speeds up leaves its loose arms behind for a moment,
-- and they swing through and settle; one turning swings them out. A spring under
-- its damping (they swing past and back once), pulled by the board's acceleration
-- in the rider's frame (x the way they face, y to their left), units of hand offset.
-- `st` keeps it per board; returns the offset.
--------------------------------------------------------------------------
local SWAY_W, SWAY_Z = 8, 0.45        -- rad/s and damping: about a third of a second, one overshoot
local SWAY_GAIN, SWAY_MAX = 0.005, 3.0
function B.ArmSway(st, acc, dt)
    st.x, st.v = st.x or Vector(0, 0, 0), st.v or Vector(0, 0, 0)
    if not dt or dt <= 0 then return st.x end
    local want = acc * -SWAY_GAIN
    if want:Length() > SWAY_MAX then want = want:GetNormalized() * SWAY_MAX end
    -- (in steps no longer than a 60 Hz frame, so a slow frame does not blow it up)
    local left = math.min(dt, 0.25)
    while left > 1e-6 do
        local h = math.min(left, 1 / 60)
        local a = (want - st.x) * (SWAY_W * SWAY_W) - st.v * (2 * SWAY_Z * SWAY_W)
        st.v = st.v + a * h
        st.x = st.x + st.v * h
        left = left - h
    end
    -- settled: exactly still, so a rider who is not moving is not re-posed for it
    if (st.x - want):Length() < 0.02 and st.v:Length() < 0.05 then st.x, st.v = want, Vector(0, 0, 0) end
    return st.x
end

--------------------------------------------------------------------------
-- THE GRABS (G17's pose system): which hand goes where on the deck, in board
-- space, for a stance. `faceY` is the side the rider faces, -1 (right) for the
-- left foot forward. A row is hand targets by role (front or back), and what the
-- body and the deck do: spineLean (degrees), boardLift (units the deck is pulled
-- up to the rider), boardPitch (radians of nose up).
--------------------------------------------------------------------------
-- THE BOARD COMES UP TO THE HAND. A grab on footage is the knees pulled up to the chest
-- with the board on the feet, not the rider bending down to it: the deck rises most of
-- a shin (1.3.9 lifted it 2 units, and the rider folded over straight legs to reach).
-- B.Posture tucks the knees under the body by the grab's weight; this is the rest.
local GRABS = {
    --   id           role   point on the deck: x, side (+1 = the toe edge), z
    indy      = { hand = "back",  x =  0.0, edge =  1, z = 2.4, lean = 10, lift = 5.5, splay = { 20, -45 } },
    melon     = { hand = "front", x =  0.5, edge = -1, z = 2.4, lean = 6,  lift = 5.5, splay = { 30, -30 } },
    stalefish = { hand = "back",  x = -6.5, edge = -1, z = 2.4, lean = 12, lift = 5.0, splay = { 0, 20 } },
    nosegrab  = { hand = "front", x = 14.0, edge =  0, z = 2.6, lean = 14, lift = 5.5, pitch = 0.18, splay = { -25, 0 } },
    tailgrab  = { hand = "back",  x = -14.0, edge = 0, z = 2.6, lean = 8,  lift = 5.5, pitch = -0.18, splay = { 0, 25 } },
    method    = { hand = "front", x =  1.0, edge = -1, z = 3.0, lean = -8, lift = 7.0, pitch = 0.14, splay = { 25, -25 } },
}
-- `splay`: degrees each knee turns toward the nose through the grab (the front's, the
-- back's), to open a way for the hand -- between them to the middle of the deck, past
-- the front one to the nose, the back one to the tail. Square, the knees were where the
-- arm went, through the thighs (4-6 units, tests/test_body_clip.lua).
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

-- Shared with the other standing riders (cl_scooter.lua, cl_skates.lua): lowering the
-- pelvis is the same calibrated nudge whoever is crouching.
B.LowerPelvis = lowerPelvis

--------------------------------------------------------------------------
-- THE BODY OVER THE BOARD (1.4.0). A skater does not stand on a board the way a
-- person stands at a bus stop on soft knees: the hips go BACK over the heels as
-- they go down, the chest comes forward over the toes to keep the weight over the
-- deck, and the deeper the crouch the further forward the back folds. Measured off
-- real footage (tools/rider/refpose: MediaPipe's pose model over CC-licensed clips
-- of skaters, 2026-10-22): rolling along, knees 25-60 and hips 15-60 degrees, the
-- trunk 10-30 forward; an ollie's crouch, knees 100-125, hips 100-130, the trunk
-- 45-55; the air, the knees pulled up to 100-120; the landing, knees 50-90, back up
-- over half a second. 1.3.9's skater bent at the knees over an upright back (hips 7
-- degrees rolling, 27 in the crouch, the trunk 4 and 7) and rode the air on legs
-- nearly straight (61): a person standing on a board, not riding it.
--
-- B.Posture is that, a pure function, in the rider's own frame. Returns `drop` (units
-- the pelvis goes down: the knees bend under it, the feet pinned by the IK), `back`
-- (units back over the heels; negative, out over the toes), `along` (units toward the
-- nose: the weight over one foot, for a manual or a push), `lean` (degrees the back
-- folds forward), `twist` (degrees the chest turns toward the nose) and `look`
-- (degrees the eyes drop to the ground ahead). `s`:
--   crouch    0..1, the ollie's preload (SPACE held)
--   land      0..1, a landing's absorb (cl_rider.lua's bmxLand)
--   speed     u/s
--   airT      seconds since the board left the ground (nil on it); ollie: off a pop;
--             sinceLand, seconds since it came down, and landFrom, the air's pose then
--   pushW     0..1 how far round for a push; pushBend 0..1 (B.PushBend)
--   carve     degrees the deck leans toward the rider's toes (negative: the heels)
--   manual    "manual" / "nose" / nil; balance the meter, -1..1, on a manual or a grind
--   grab      0..1, a grab's weight
--   t, seed   seconds (any clock) and a number per rider: the breathing and the drift;
--             tFine, the clock for the road's grain at speed (else t)
--
-- THE DRIFT TICKS AT FIVE A SECOND (B.DriftClock). The rider's IK re-poses the skeleton
-- only when something on it moved (cl_rider.lua), so a rider standing still is nearly
-- free; a body that breathes every frame is never still, and an idle skater cost what
-- a riding one does (8.6 SetupBones a frame, not 2: tests/test_perf_client.lua). At
-- these sizes a fifth of a second's step is a quarter of a degree of the back and a
-- tenth of a unit of the hips: nobody sees the steps, and the pose is solved five
-- times a second instead of every frame.
--------------------------------------------------------------------------
local RIDE   = { drop = 10,  back = 3.0, lean = 24 }    -- rolling along on soft knees
local CROUCH = { drop = 21,  back = 6.5, lean = 62 }    -- an ollie's preload, all the way down
local POP    = { drop = 6,   back = 1.0, lean = 24 }    -- the back leg straight off the tail
local TUCK   = { drop = 17,  back = 3.5, lean = 58 }    -- the knees up under the rider
local REACH  = { drop = 12,  back = 2.5, lean = 28 }    -- the legs down again for the ground
local DROPIN = { drop = 13,  back = 2.5, lean = 24 }    -- off a drop, no pop: a gentle tuck
local LAND   = { drop = 9.5, back = 2.5, lean = 36 }    -- ADDED at the hardest landing
local TUCK_T, REACH_T = 0.30, 0.58     -- s after the board leaves the ground (POP_T, above)
local SETTLE_T = 0.15         -- s after touching down: the air's pose gives way to the ground's
local PUSH_FOLD = 9           -- units further down on the standing leg as the other reaches the ground
local CROUCH_DEPTH = CROUCH.drop
B.CrouchDepth, B.RideBend = CROUCH_DEPTH, RIDE.drop
B.PostureKeys = { RIDE = RIDE, CROUCH = CROUCH, POP = POP, TUCK = TUCK, REACH = REACH, LAND = LAND }

function B.CrouchShown(c)
    c = math.Clamp(c or 0, 0, 1)
    return 1 - (1 - c) ^ 2.5
end

local function mix(a, b, u)
    return { drop = lerp(a.drop, b.drop, u), back = lerp(a.back, b.back, u), lean = lerp(a.lean, b.lean, u) }
end

function B.Posture(s)
    local speedK = math.Clamp((s.speed or 0) / 300, 0, 1)
    local ride = { drop = RIDE.drop + speedK * 1.5, back = RIDE.back, lean = RIDE.lean + speedK * 4 }
    -- (the networked crouch is how long SPACE has been held, which sets the pop's height;
    -- a skater is most of the way down for any ollie, so the body gets there first)
    local c = B.CrouchShown(s.crouch)
    local P = mix(ride, CROUCH, c)
    local look = 10 * c

    -- THE AIR. Off a pop: the legs straighten off the tail, the knees come up under the
    -- body as the board rises to the feet, and go down again to meet the ground. Off a
    -- drop with no pop the knees just soften.
    local t = s.airT
    if t then
        if s.ollie then
            if t < POP_T then P = mix(mix(ride, CROUCH, math.max(c, 0.85)), POP, ease(t / POP_T))
            elseif t < TUCK_T then P = mix(POP, TUCK, ease((t - POP_T) / (TUCK_T - POP_T)))
            else P = mix(TUCK, REACH, ease((t - TUCK_T) / (REACH_T - TUCK_T))) end
            look = 14 * window(t, 0.1, 0.4, 0.7)
        else
            P = mix(P, DROPIN, ease(t / 0.25))
            look = 8
        end
    end

    -- Just down: from the air's reach to the ground's pose, not in a frame (a soft landing
    -- has no absorb to hide the step).
    if not t and s.sinceLand and s.sinceLand < SETTLE_T and s.landFrom then
        P = mix(s.landFrom, P, ease(s.sinceLand / SETTLE_T))
    end

    -- THE LANDING folds the knees and the back, by how hard it was, and comes up again.
    local l = math.Clamp(s.land or 0, 0, 1)
    if l > 0 and not t then
        P.drop, P.back, P.lean = P.drop + LAND.drop * l, P.back + LAND.back * l, P.lean + LAND.lean * l
        look = math.max(look, 8 * l)
    end

    -- A GRAB IS A TUCK: the knees come up to the hand, not the back down to the knees.
    local g = math.Clamp(s.grab or 0, 0, 1)
    if g > 0 then
        P.drop = lerp(P.drop, math.max(P.drop, TUCK.drop + 1), g)
        P.lean = P.lean + 6 * g
    end

    -- THE PUSH: the hips have come round up the board (B.TurnPelvis) and the back leans
    -- into it; the standing knee folds as the other foot reaches the ground; the weight
    -- is over the front foot, on the middle of the deck where that foot has turned.
    local w = math.Clamp(s.pushW or 0, 0, 1)
    P.drop = P.drop + (s.pushBend or 0) * PUSH_FOLD
    P.lean = P.lean + w * 10
    P.back = lerp(P.back, 0.5, w)
    local along = w * 3.0

    -- INTO A CARVE: over the toes for a toe-side turn (the pelvis out over them, the
    -- back folding), sat back over the heels for a heel-side one with the chest
    -- forward against it; deeper either way.
    local cv = (s.carve or 0) * (1 - w)
    if cv >= 0 then
        P.back, P.drop, P.lean = P.back - 0.22 * cv, P.drop + 0.10 * cv, P.lean + 0.45 * cv
    else
        P.back, P.drop, P.lean = P.back - 0.18 * cv, P.drop - 0.12 * cv, P.lean - 0.2 * cv
    end

    -- A MANUAL: the weight over the wheels that are down, the back a little more upright;
    -- the meter sways it fore and aft (a manual) or across, over the heels and the toes
    -- (a grind).
    -- (`manualW`, how far into it: eased by the drawing, or the weight stepped 4 units)
    local mw = s.manualW or 1
    if s.manual == "manual" or s.manual == "nose" then
        along = along + (s.manual == "nose" and 4 or -4) * mw
        P.drop, P.lean = P.drop + 1 * mw, P.lean - 4 * mw
        if s.balance then along = along + 1.2 * math.Clamp(s.balance, -1, 1) * mw end
    elseif s.balance then
        P.back = P.back + 1.5 * math.Clamp(s.balance, -1, 1) * mw
    end

    P.along, P.twist, P.look, P.speedK = along, 0, look, speedK
    if not s.noLife then B.PostureLife(P, s) end
    P.drop = math.Clamp(P.drop, 0, CROUCH_DEPTH + 3)
    return P
end

-- NEVER STILL. Breathing in the back; the weight drifting a little from foot to foot
-- and the shoulders with it; at speed the road's grain in the knees. Added to a posture
-- AFTER any smoothing of it (SET.rider): smoothed, the drift's five-a-second steps became
-- a change every frame, and a skater standing still was re-posed every frame for it.
function B.PostureLife(P, s)
    local tt, seed, speedK = s.t or 0, s.seed or 0, P.speedK or 0
    local drift = 0.6 * sin(tt * TAU * 0.13 + seed * 1.7) + 0.4 * sin(tt * TAU * 0.31 + seed * 0.6)
    P.lean = P.lean + 0.8 * sin(tt * TAU * 0.27 + seed)
    P.along = P.along + 0.7 * drift
    P.drop = P.drop + speedK * 0.3 * sin((s.tFine or tt) * TAU * 2.3 + seed)
    P.twist = (P.twist or 0) + 2 * drift
    return P
end

-- The pelvis moved in the rider's frame (x the way they face, y to their left, z up),
-- by the per-model map MEASURED as the drop is: each axis of the bone's position
-- offset nudged, where the bone went seen in that frame, and the three inverted.
-- A model it cannot measure (no pelvis, a singular map) is only lowered.
local pelvisMap = {}         -- model -> { rows of the inverse }, or false
local function calibratePelvisMap(ply, b, F, L, U)
    ply:ManipulateBonePosition(b, Vector(0, 0, 0))
    refresh(ply)
    local m0 = ply:GetBoneMatrix(b)
    if not m0 then return nil end
    local p0 = m0:GetTranslation()
    local col = {}
    for k, ax in ipairs({ Vector(1, 0, 0), Vector(0, 1, 0), Vector(0, 0, 1) }) do
        ply:ManipulateBonePosition(b, ax * 4)
        refresh(ply)
        local m = ply:GetBoneMatrix(b)
        if not m then return nil end
        local d = (m:GetTranslation() - p0) / 4
        col[k] = { d:Dot(F), d:Dot(L), d:Dot(U) }
    end
    ply:ManipulateBonePosition(b, Vector(0, 0, 0))
    refresh(ply)
    -- the 3x3 with those columns, inverted (rider frame -> the offset)
    local a, bb, c = col[1], col[2], col[3]
    local m = { { a[1], bb[1], c[1] }, { a[2], bb[2], c[2] }, { a[3], bb[3], c[3] } }
    local det = m[1][1] * (m[2][2] * m[3][3] - m[2][3] * m[3][2])
              - m[1][2] * (m[2][1] * m[3][3] - m[2][3] * m[3][1])
              + m[1][3] * (m[2][1] * m[3][2] - m[2][2] * m[3][1])
    if abs(det) < 0.25 then return nil end
    local inv = {}
    for i = 1, 3 do
        inv[i] = {}
        for j = 1, 3 do
            local r1, r2 = (j % 3) + 1, ((j + 1) % 3) + 1
            local c1, c2 = (i % 3) + 1, ((i + 1) % 3) + 1
            inv[i][j] = (m[r1][c1] * m[r2][c2] - m[r1][c2] * m[r2][c1]) / det
        end
    end
    return inv
end

function B.PlacePelvis(ply, bike, stance, back, along, drop)
    local b = ply:LookupBone(PELVIS)
    if not b then return end
    local model = ply:GetModel()
    if pelvisMap[model] == nil then
        local F, U = B.FacingFor(bike, stance, 0)
        pelvisMap[model] = calibratePelvisMap(ply, b, F, U:Cross(F), U) or false
    end
    local inv = pelvisMap[model]
    if not inv then return lowerPelvis(ply, drop) end
    local w = { -back, along, -drop }
    ply:ManipulateBonePosition(b, Vector(
        inv[1][1] * w[1] + inv[1][2] * w[2] + inv[1][3] * w[3],
        inv[2][1] * w[1] + inv[2][2] * w[2] + inv[2][3] * w[3],
        inv[3][1] * w[1] + inv[3][2] * w[2] + inv[3][3] * w[3]))
    ply.bmxPelvis = b
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

local PUSH_TURN = 70            -- degrees the hips come round up the board for a push
local POSTURE_KEYS, POSTURE_TAU = { "drop", "back", "along", "lean" }, 0.05

-- st[key] following `target` on a critically damped spring (cl_rider.lua's), SETTLED
-- exactly onto it once within a hair: a value that only creeps toward its target moves
-- the skeleton every frame, and a rider standing still would be re-posed for nothing.
function B.Smooth(st, key, target, tau, dt)
    local x = st[key]
    if x == nil or not dt or dt <= 0 then st[key], st[key .. "V"] = target, 0 return target end
    local v
    x, v = BMX.RiderDamp(x, st[key .. "V"] or 0, target, tau, dt)
    if math.abs(x - target) < 0.005 and math.abs(v) < 0.05 then x, v = target, 0 end
    st[key], st[key .. "V"] = x, v
    return x
end
local OPEN_SHOULDERS = 12       -- degrees the chest turns toward the nose

-- B.Posture's inputs for a board as it is now: what the server networks (the crouch,
-- the lean, the flags), what the drawing worked out this frame (bike.bmxRide: the
-- push's weight, when it left the ground and whether off a pop) and what the rider
-- hook did (bmxLand, a landing's absorb; poseW, a grab's weight).
local DRIFT_HZ = 5
function B.DriftClock(t) return math.floor(t * DRIFT_HZ) / DRIFT_HZ end

local function postureOf(bike, R, speed, noLife)
    local grab = 0
    for _, w in pairs(bike.poseW or {}) do grab = grab + w end
    local stance = R.stance or 1
    local lean = bike.GetBoardLean and bike:GetBoardLean() or 0
    return B.Posture({
        crouch = bike.GetCrouch and bike:GetCrouch() or 0,
        land = bike.bmxLand or 0, speed = speed,
        airT = R.airT, ollie = R.ollie, sinceLand = R.sinceLand, landFrom = R.landFrom,
        pushW = R.pushW, pushBend = R.pushBend,
        -- The deck's top leans toward -Y for a positive lean, which is the toe side for
        -- a rider facing -Y (regular).
        carve = (stance >= 0 and 1 or -1) * math.deg(lean),
        manual = R.manual or R.lastManual, balance = R.balance or R.lastBalance, manualW = R.balW,
        grab = grab,
        t = B.DriftClock(CurTime()), tFine = CurTime(), seed = (bike.EntIndex and bike:EntIndex() or 0) * 1.37,
        noLife = noLife,
    })
end
B.PostureOf = postureOf

-- The bone offsets for the ride: the pelvis placed and the back folded as B.Posture
-- has them, the hips come round for a push. Called from the rider hook BEFORE the IK
-- solve (cl_rider.lua), which is why the pelvis is moved and turned from here: the
-- legs' IK then bends the knees between it and the feet on the deck.
SET.rider = function(s)
    local bike, ply = s.bike, s.ply
    local R = bike and bike.bmxRide or {}
    local stance = R.stance or 1
    local faceSign = stance >= 0 and 1 or -1
    local w = R.pushW or 0
    local P = bike and postureOf(bike, R, s.speed, true) or B.Posture({ speed = s.speed })
    -- FOLLOWED, NOT SET: B.Posture's phases are keyframes eased one to the next, and
    -- where one phase gives way to the next (the crouch to the pop, the pop to the
    -- tuck) the body stopped and started in a frame -- 6 to 10 units of jolt at 30 fps
    -- (tools/rider/studio/motion.py). A short spring takes the corners off.
    if bike then
        R.postureSm = R.postureSm or {}
        local dt = FrameTime()
        for _, k in ipairs(POSTURE_KEYS) do P[k] = B.Smooth(R.postureSm, k, P[k], POSTURE_TAU, dt) end
        B.PostureLife(P, { t = B.DriftClock(CurTime()), tFine = CurTime(), seed = bike:EntIndex() * 1.37 })
    end
    R.posture = P
    if ply and bike then
        B.PlacePelvis(ply, bike, stance, P.back, faceSign * P.along, P.drop)
        B.TurnPelvis(ply, faceSign * PUSH_TURN * w)
    end
    -- ...and on a manual or a grind, the meter: the body leans the way it is falling
    -- and the arms (B.RiderHands) bring it back.
    local meter = R.balance and R.balance * 4 or 0
    local spine = P.lean + math.deg(s.pitch or 0) * 0.5 + meter
    -- The shoulders open a little toward the nose (where the eyes are, BMX.RiderLookAt),
    -- not through a push, when the hips have come round already, and drift with the
    -- weight. A positive twist turns the chest to the rider's left, where the nose is
    -- riding regular.
    local lean = bike and bike.GetBoardLean and bike:GetBoardLean() or 0
    local twist = math.deg(lean) * 0.3 + faceSign * (OPEN_SHOULDERS * (1 - w) + P.twist)
    return {
        spine = Angle(0, spine, twist),
        head  = Angle(0, -spine * 0.7, -twist * 0.5),
    }
end
-- A skater folds at the hips more than up the back: the lean is shared further down
-- the spine than a bike rider's (cl_rider.lua's SPINE_SHARE), or a deep crouch was a
-- hunch with the shoulders rolled over an upright pelvis.
SET.spineShare = { { "spineLow", 0.45 }, { "spineMid", 0.3 } }
SET.ownLife = true          -- B.Posture breathes and drifts the weight itself

--------------------------------------------------------------------------
-- THE RIDER'S IK: both feet on the deck, hands out for balance. The solver is the
-- bike's (BMX.SolveRiderIK), handed a stand-in for the "bike" whose forward is the
-- way the RIDER faces, so the knees and toes point across the deck. Through a push
-- that turns up the board with the hips, so the knees and toes point the way the
-- board goes and the pushing leg swings back under the body.
--------------------------------------------------------------------------
local TOE_TURN = 70             -- degrees the toes come round up the board for a push
-- STANDING ON A BOARD, the front foot is turned toward the nose and the back one a
-- little, the knees over the toes (1.3.9's both pointed straight across the deck, as
-- nobody stands): degrees, toward the nose, for the IK's per-foot yaw (cl_rider.lua).
local FRONT_TOE, BACK_TOE = 28, 10
B.ToeYaw = { front = FRONT_TOE, back = BACK_TOE }

function B.FacingFor(bike, stance, pushW)
    local up = bike:GetUp()
    local face = bike:GetRight() * (stance >= 0 and 1 or -1)   -- GetRight() is the board's right
    local a = math.rad(TOE_TURN) * (pushW or 0)
    if a ~= 0 then face = (face * cos(a) + bike:GetForward() * sin(a)):GetNormalized() end
    return face, up
end

-- Elbows back and a little out, as loose arms hang (the bike's are out and down, over
-- bars); knees forward, over the toes.
SET.poles = { arm = Vector(-0.8, 0.45, -0.25), leg = Vector(1, 0, 0.2) }

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
        bmxPoseSet = SET,
    }
    BMX.SolveRiderIK(ply, ik, proxy)
    -- EYES UP THE BOARD: the way it is going, over the lead shoulder (the tail first,
    -- rolling fakie), not out to the side the body faces.
    -- ...and into a turn, as a bike rider's head goes (cl_rider.lua's look, degrees left).
    if BMX.RiderLookAt then
        local dir = bike:GetForward() * (B.HasFlag(flags, "fakie") and -1 or 1)
        local look = math.rad(ply.bmxLook or 0)
        if look ~= 0 then
            local c, s = math.cos(look), math.sin(look)
            dir = Vector(dir.x * c - dir.y * s, dir.x * s + dir.y * c, dir.z)
        end
        -- ...and down at the ground a little way ahead in a crouch, and at the board
        -- through an ollie, to spot the landing (B.Posture's look).
        local P = bike.bmxRide and bike.bmxRide.posture
        local down = P and math.rad(P.look or 0) or 0
        if down > 0 then dir = (dir * math.cos(down) - up * math.sin(down)):GetNormalized() end
        BMX.RiderLookAt(ply, dir)
    end
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
local function boardModel(bike, C)
    local WC = C.Wheel
    local wheels = BMX.WheelDefs(bike, C)
    return BMX.BikeMesh.Get(WC.wheelbase / 39, WC.radius, bike.look, {
        wheelbase = WC.wheelbase, restLength = WC.restLength,
        extra = { track = wheels[1] and math.abs(wheels[1].pos.y) or 4.6 },
    })
end
function BMX.BoardModel(ent)
    local bike, C = ent:Bike(), ent:Cfg()
    local BM = BMX.BikeMesh
    if not bike.look or not BM then return nil end
    return BM.Remembered(ent, bike, C, boardModel, bike, C)
end

--------------------------------------------------------------------------
-- THE BOARD IN HAND (weapon_bmx_board, sv_board_carry.lua). The carried board was the
-- SWEP's world model, a base-game plate held out in front in the "slam" hold, from
-- before the board had a model. It is the board itself now, the way a skater carries
-- one walking: hanging at the side from the right hand, which holds it by the front
-- truck's hanger, the deck against the leg and the wheels out, swinging with the arm.
-- The same built model the ridden boards draw (built once, shared). Returns whether
-- it drew (false while the model builds: the SWEP draws its plate meanwhile).
--------------------------------------------------------------------------
B.CarryOut = 1.2            -- units the grip is out from the palm, so the deck clears the leg
local CARRY_TAIL = 4        -- units the kicked-up tail runs on past the rear axle

-- THE CARRYING ARM DOWN AT THE SIDE. The "normal" hold's idle stands with the arms out
-- in an A, and the board hung from that hand dangled a foot out from the hip (kleiner's
-- mesh in the offline studio, 2026-10-19). The right arm is brought in: where the
-- animation has the hand, fore and aft and up and down -- so it still swings as the
-- player walks -- but no further out from the shoulder than CARRY_OUT, at the same
-- reach. Put back when the board is put down (or the player is far away).
local CARRY_OUT = 3.0
local CARRY_RANGE = 1200
local CARRY_BONES = { "ValveBiped.Bip01_R_UpperArm", "ValveBiped.Bip01_R_Forearm", "ValveBiped.Bip01_R_Hand" }
local carrying = setmetatable({}, { __mode = "k" })
local function carryRelease(ply)
    for _, name in ipairs(CARRY_BONES) do
        local b = ply:LookupBone(name)
        if b then
            ply:ManipulateBoneAngles(b, Angle(0, 0, 0))
            if ply.bmxIK then ply.bmxIK[b] = nil end
        end
    end
    carrying[ply] = nil
end
function B.CarryPose(ply)
    local limb = BMX.RiderLimbs and BMX.RiderLimbs[3]
    if not (limb and BMX.RiderSolveLimb and BMX.RiderAimBone) then return end
    -- The arm as the animation has it, then measured.
    for _, name in ipairs(CARRY_BONES) do
        local b = ply:LookupBone(name)
        if b then ply:ManipulateBoneAngles(b, Angle(0, 0, 0)) end
    end
    ply.bmxIK = ply.bmxIK or {}
    for _, name in ipairs(CARRY_BONES) do
        local b = ply:LookupBone(name)
        if b then ply.bmxIK[b] = nil end
    end
    ply:InvalidateBoneCache()
    ply:SetupBones()
    local sb, eb, hb = ply:LookupBone(limb.root), ply:LookupBone(limb.hinge), ply:LookupBone(limb.eff)
    local S, E, H = sb and ply:GetBoneMatrix(sb), eb and ply:GetBoneMatrix(eb), hb and ply:GetBoneMatrix(hb)
    if not (S and E and H) then return end
    S, E, H = S:GetTranslation(), E:GetTranslation(), H:GetTranslation()
    local ang = ply:GetRenderAngles()
    local f, r = ang:Forward(), ang:Right()
    local up = Vector(0, 0, 1)
    local d = H - S
    local len = d:Length()
    local x, y = d:Dot(f), math.min(d:Dot(r), CARRY_OUT)
    local z = -math.sqrt(math.max(len * len - x * x - y * y, 1))
    BMX.RiderSolveLimb(ply, limb, S + f * x + r * y + up * z, (r * 0.45 - f * 0.8):GetNormalized())
    -- the wrist straight, the hand going on from the forearm
    local fb = ply:LookupBone("ValveBiped.Bip01_R_Finger2")
    if fb then
        ply:InvalidateBoneCache()
        ply:SetupBones()
        local E2, H2 = ply:GetBoneMatrix(eb):GetTranslation(), ply:GetBoneMatrix(hb):GetTranslation()
        BMX.RiderAimBone(ply, hb, hb, fb, (H2 - E2):GetNormalized())
    end
    carrying[ply] = true
end

hook.Add("PrePlayerDraw", "BMX.Board.Carry", function(ply)
    local w = ply:GetActiveWeapon()
    local holding = IsValid(w) and w:GetClass() == "weapon_bmx_board" and not ply:InVehicle()
        and EyePos():Distance(ply:GetPos()) < CARRY_RANGE
    if holding then
        B.CarryPose(ply)
    elseif carrying[ply] then
        carryRelease(ply)
    end
end)
function B.DrawCarried(ply, paint)
    local def = BMX.Vehicles and BMX.Vehicles.skateboard
    if not (def and def.look and BMX.BikeMesh and BMX.ConfigFor) then return false end
    local C = BMX.ConfigFor(def)
    local model = boardModel(def, C)
    if not model then return false end
    local hb = ply:LookupBone("ValveBiped.Bip01_R_Hand")
    local m = hb and ply:GetBoneMatrix(hb)
    if not m then return false end
    -- HANGING, as a held board does: straight down from the front truck in the hand
    -- (it used to follow the hand's own axis, and a crouch, whose hand points up the
    -- arm, held it up past the shoulder: seen on a real client, 2026-10-20), the deck's
    -- top against the leg. Only when the hand is too low for the tail to clear the
    -- ground (a crouch) does the tail swing back, as far as it must.
    local ang = ply:GetRenderAngles()
    local fwd, out = ang:Forward(), ang:Right()
    fwd = Vector(fwd.x, fwd.y, 0):GetNormalized()
    out = Vector(out.x, out.y, 0):GetNormalized()
    local lay = model.layout
    local ta, ax = lay.truckAt, lay.axle
    local grip = Vector(ta.x + ax.x, 0, ta.z + ax.z * 0.7)     -- on the front hanger
    local palm = m:GetTranslation() + m:GetForward() * 3.0 + out * B.CarryOut
    local below = grip.x + (lay.front.x - lay.rear.x) * 0.5 + CARRY_TAIL     -- grip to the tail's end
    local clear = palm.z - ply:GetPos().z - 1
    local c = math.Clamp(clear / below, 0.2, 1)
    local x = Vector(0, 0, 1) * c + fwd * math.sqrt(1 - c * c)     -- the nose up, the tail down (and back)
    local z = -out                                       -- the deck's top against the leg
    local y = z:Cross(x)
    local O = palm - x * grip.x - z * grip.z
    local function P(v) return O + x * v.x + y * v.y + z * v.z end
    B.DrawModel(ply, model, {
        P = P, level = { f = x, l = y, u = z }, center = P(Vector(0, 0, 0)),
        wheels = BMX.WheelDefs(def, C), simRadius = C.Wheel.radius,
        paint = paint or BMX.PaletteColor(1), lod = 0, steer = 0,
    })
    return true
end

BMX.DrawVehicle = BMX.DrawVehicle or {}
BMX.DrawVehicle.board = function(ent, kit)
    local bike = ent:Bike()
    local C = ent:Cfg()
    local WC = C.Wheel
    local dt = BMX.DrawDT(ent)
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
    -- The ollie's snap of the tail (B.OllieTilt), on top of what the chassis does.
    local R0 = ent.bmxRide
    if R0 and R0.airAt and R0.ollie then
        local tilt, tiltLift = B.OllieTilt(CurTime() - R0.airAt, B.HasFlag(flags, "nollie"))
        liftPitch, lift = liftPitch + tilt, lift + tiltLift
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
        -- down: the pose it had in the air, to come out of it from (B.Posture's settle)
        if R.airAt then
            local P = R.posture
            R.landedAt = now
            R.landFrom = P and { drop = P.drop, back = P.back, lean = P.lean } or nil
        end
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
    R.pushW = R.pushW + math.Clamp(wantW - R.pushW, -3 * dt, 5 * dt)
    R.stance = stance
    R.airT = airT
    R.air = airT and ease(airT / 0.15) or 0
    R.pushBend = pushing and B.PushBend(push) or 0
    R.balance = B.HasFlag(flags, "meter") and ent:GetMeter() or nil
    R.manual = B.HasFlag(flags, "manual") and "manual" or (B.HasFlag(flags, "nose") and "nose" or nil)
    -- The arms' weights, eased: out for the air (in quickly, down over a quarter of a
    -- second after the landing), and out for a manual or a grind's balance.
    R.airW = (R.airW or 0) + math.Clamp((airT and ease(airT / 0.12) or 0) - (R.airW or 0), -4 * dt, 14 * dt)
    R.balW = (R.balW or 0) + math.Clamp((R.balance and 1 or 0) - (R.balW or 0), -4 * dt, 4 * dt)
    if R.balance then R.lastBalance = R.balance end
    if R.manual then R.lastManual = R.manual elseif R.balance then R.lastManual = nil end
    R.sinceLand = R.landedAt and (now - R.landedAt) or nil

    -- PLANTED: the pushing foot's place on the ground, kept from where it went down
    -- while the board runs on from it (B.PushFoot's strokeX).
    local pushGeo = B.PushGeo(T, stance >= 0 and -1 or 1)
    local pa, pb = B.PushMarks(pushGeo)
    local strokeX
    if pushing and push >= pa then
        local f0 = ent:GetForward()
        if push < pb and not R.liftP then
            R.plantAt = R.plantAt or (ent:GetPos() + f0 * pushGeo.plantX)
            local x = (R.plantAt - ent:GetPos()):Dot(f0)
            if x <= pushGeo.backX then R.liftP = push end       -- the leg is out: up it comes
            strokeX = math.Clamp(x, pushGeo.backX, pushGeo.plantX)
            R.strokeEnd = strokeX
        else
            strokeX = R.strokeEnd
        end
    else
        R.plantAt, R.strokeEnd, R.liftP = nil, nil, nil
    end
    R.flip = B.TrackFlip(R.flip or {}, df.roll, df.yaw, df.pitch)
    R.flip.roll, R.flip.yaw, R.flip.pitch = df.roll, df.yaw, df.pitch

    local front, back, offDeck = B.RiderFeet({
        stance = stance, push = airT and -1 or push, pushW = R.pushW,
        crouch = ent:GetCrouch(), airT = airT, ollie = R.ollie,
        nollie = B.HasFlag(flags, "nollie"),
        manual = R.manual,
        flip = R.flip,
        strokeX = strokeX, liftP = R.liftP,
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

    -- The arms' lag (B.ArmSway): the board's acceleration, seen in the rider's frame.
    local face, fup = B.FacingFor(ent, stance, R.pushW)
    local fleft = fup:Cross(face)
    local vel = ent:GetVelocity()
    local acc = (R.lastVel and dt > 0) and (vel - R.lastVel) / dt or Vector(0, 0, 0)
    R.lastVel = vel
    R.sway = R.sway or {}
    local sway = B.ArmSway(R.sway, Vector(acc:Dot(face), acc:Dot(fleft), 0), dt)

    local land = ent.bmxLand or 0
    local lead, trail = B.RiderHands({
        stance = stance, pushW = R.pushW, push = push, crouch = B.CrouchShown(ent:GetCrouch()), land = land,
        airT = airT, ollie = R.ollie, airW = R.airW,
        balance = R.balance or R.lastBalance, balW = R.balW,
        noDrift = true,
    })
    -- ...followed, as the body is (B.Smooth): each phase's arms are a keyframe.
    R.handSm = R.handSm or {}
    lead = Vector(B.Smooth(R.handSm, "lx", lead.x, 0.05, dt), B.Smooth(R.handSm, "ly", lead.y, 0.05, dt),
        B.Smooth(R.handSm, "lz", lead.z, 0.05, dt))
    trail = Vector(B.Smooth(R.handSm, "tx", trail.x, 0.05, dt), B.Smooth(R.handSm, "ty", trail.y, 0.05, dt),
        B.Smooth(R.handSm, "tz", trail.z, 0.05, dt))
    local dl, dtr = B.HandDrift(B.DriftClock(now), ent:EntIndex() * 1.37, B.CrouchShown(ent:GetCrouch()), R.balance)
    lead, trail = lead + dl + sway, trail + dtr + sway
    -- The lead hand is on the nose's side: the left for a left-foot-forward stance.
    local lRel, rRel = stance >= 0 and lead or trail, stance >= 0 and trail or lead
    -- Arms out for balance are OPEN hands, and the torso does not reach for them (without
    -- this the arms counted as holding bars, and the reach for them bent every skater 30
    -- degrees over). The solver puts each on its shoulder (`Rel`); until then, and for
    -- whoever reads the targets without solving, each is where a standing body's
    -- shoulder would put it.
    local body = postureOf(ent, R, ent.GetSpeedUPS and ent:GetSpeedUPS() or 0)
    local rest = B.FacingFor(ent, stance, 0)
    local neck = ent:LocalToWorld(Vector(0, 0, T.seatZ)) + fup * (SHOULDER_Z - body.drop) - rest * body.back
        + rest * (math.sin(math.rad(body.lean)) * (SHOULDER_Z - 40))
    local function est(rel, side)
        return neck + fleft * (SHOULDER_W * side) + face * rel.x + fleft * rel.y + fup * rel.z
    end
    -- The toes: the front foot turned toward the nose, the back a little (B.ToeYaw), as
    -- far as the push has not already turned them both up the board. Degrees to the
    -- rider's left, which is the nose riding regular.
    local n = stance >= 0 and 1 or -1
    local still = 1 - (R.pushW or 0)
    local frontYaw, backYaw = n * FRONT_TOE * still, n * BACK_TOE * still
    -- A GRAB OPENS THE KNEES for the hand (GRABS' `splay`).
    for name, w in pairs(W or {}) do
        local g = GRABS[name]
        if g and g.splay and w > 0 then
            frontYaw = frontYaw + n * g.splay[1] * w
            backYaw = backYaw + n * g.splay[2] * w
        end
    end
    -- ...and the soles laid on the deck as it leans into a carve: toes down on a
    -- toe-side turn, heels down on a heel-side one (degrees toe-down).
    local sole = math.deg(ent:GetBoardLean()) * n
    local ik = {
        lFoot = lFoot, rFoot = rFoot, ankles = true,
        lFootYaw = stance >= 0 and frontYaw or backYaw, rFootYaw = stance >= 0 and backYaw or frontYaw,
        lSole = sole, rSole = sole,
        lHand = est(lRel, 1), rHand = est(rRel, -1),
        lHandRel = lRel, rHandRel = rRel,
        openHands = true,
    }
    -- A GRAB takes its hand to its place on the deck, by the grab's weight, and closes it
    -- there (the other hand keeps its balance, open).
    local to, toW = {}, {}
    for name, w in pairs(W or {}) do
        local row = rows[name]
        if row and w > 0 then
            for _, key in ipairs({ "rHand", "lHand" }) do
                if row[key] then
                    to[key] = (to[key] or Vector(0, 0, 0)) + P(row[key]) * w
                    toW[key] = (toW[key] or 0) + w
                end
            end
        end
    end
    for _, key in ipairs({ "rHand", "lHand" }) do
        local w = toW[key]
        if w then
            local at = to[key] / w
            w = min(w, 1)
            ik[key .. "To"], ik[key .. "ToW"] = at, w
            ik[key] = ik[key] + (at - ik[key]) * w
        end
        ik[key .. "Open"] = not (w and w > 0.5)
    end
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
