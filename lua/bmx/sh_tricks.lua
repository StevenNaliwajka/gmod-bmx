--[[--------------------------------------------------------------------------
    bmx/sh_tricks.lua

    THE TRICK REGISTRY. Every trick the addon knows is registered here, by
    one call:

        BMX.RegisterTrick{
            id       = "tailwhip",          unique, [%w_]+
            name     = "Tailwhip",          what the callout and the combo say
            input    = "LMB + A/D in the air",   for the trick list overlay
            points   = 600,                 per rotation / per second / per
                                            0.1 s held, by `kind` (below)
            pose     = "superman",          optional: the rider pose this trick
                                            puts the body in (cl_rider.lua)
            canStart = function(st, inp)    optional: may it run right now?
            onTick   = function(ent, st, inp, dt)   optional: runs every
                                            substep while canStart says yes
            kind     = "spin" | "part" | "pose" | "ground" | "grind" | "custom"
        }

    WHY A REGISTRY. Until now a trick was a row in a table in sv_air.lua, a
    name in sv_grind.lua and a string in TrackManual, and a new one meant
    finding all three. The flips, the barrel roll, the 360, the wheelie, the
    stoppie and the grinds are all registered here and the scoring reads them
    back, so the built-ins and anything a modder (G20) or another vehicle
    (G23, a skateboard's grabs) adds are the same kind of thing.

    WHAT EACH KIND MEANS
        spin     a rotation of the whole bike about an axis, counted in full
                 turns (sv_air.lua). `axis` is spinPitch / spinRoll / spinYaw,
                 `sign` is +1, -1, or 0 for either way. points = per turn.
        part     a rotation of a PART about the steer axis (sv_tricks.lua):
                 `part` is "whip" (the frame) or "bar" (the bars).
                 points = per turn.
        pose     a held body position. points = per `Tricks.poseTick` seconds
                 held. Its `pose` is both the IK target on the client and the
                 byte on the wire.
        ground   held on the ground (TrackManual). points = per second. The
                 numbers the bike actually pays are the config's
                 (Tricks.wheeliePerSec ...) so a bike can override them; the
                 registry holds the defaults.
        grind    a rail trick (sv_grind.lua). points = per second.
        custom   whatever onTick says. It may return points, which are banked
                 and paid under this trick's name on landing.

    This file is shared: the client lists the same registry in the trick
    overlay (cl_tricks.lua) and the pose ids on the wire come from it.
----------------------------------------------------------------------------]]

BMX = BMX or {}

BMX.Tricks     = {}     -- id -> trick
BMX.TrickOrder = {}     -- ids, in registration order
BMX.PoseNames  = {}     -- pose id (1..255) -> pose name; 0 is "no pose"
BMX.PoseIDs    = {}     -- pose name -> pose id
BMX.PoseTricks = {}     -- pose name -> the pose trick that owns it
BMX.TickList   = {}     -- the tricks that have an onTick, in order

local KINDS = { spin = true, part = true, pose = true, ground = true,
                grind = true, custom = true }
local AXES  = { spinPitch = true, spinRoll = true, spinYaw = true }
local PARTS = { whip = true, bar = true }

local function bad(id, why)
    error("BMX.RegisterTrick(" .. tostring(id) .. "): " .. why, 3)
end

function BMX.RegisterTrick(t)
    if type(t) ~= "table" then bad(nil, "expected a table") end
    local id = t.id
    if type(id) ~= "string" or not id:match("^[%w_]+$") then
        bad(id, "id must be a non-empty string of letters, digits and _")
    end
    if BMX.Tricks[id] then bad(id, "duplicate id") end
    if type(t.name) ~= "string" or t.name == "" then bad(id, "name must be a non-empty string") end
    if type(t.input) ~= "string" or t.input == "" then bad(id, "input must be a non-empty string") end
    if type(t.points) ~= "number" or t.points ~= t.points or t.points < 0 or t.points == math.huge then
        bad(id, "points must be a finite number >= 0")
    end
    if t.pose ~= nil and (type(t.pose) ~= "string" or t.pose == "") then
        bad(id, "pose must be a non-empty string when given")
    end
    if t.canStart ~= nil and type(t.canStart) ~= "function" then bad(id, "canStart must be a function") end
    if t.onTick   ~= nil and type(t.onTick)   ~= "function" then bad(id, "onTick must be a function") end

    local kind = t.kind or "custom"
    if not KINDS[kind] then bad(id, "unknown kind " .. tostring(kind)) end
    if kind == "spin" then
        if not AXES[t.axis] then bad(id, "a spin needs axis = spinPitch / spinRoll / spinYaw") end
        if t.sign ~= 1 and t.sign ~= -1 and t.sign ~= 0 then bad(id, "a spin needs sign = 1, -1 or 0") end
    elseif kind == "part" then
        if not PARTS[t.part] then bad(id, "a part trick needs part = whip / bar") end
    elseif kind == "pose" and not t.pose then
        bad(id, "a pose trick needs a pose")
    end

    local trick = {
        id = id, name = t.name, input = t.input, points = t.points, kind = kind,
        pose = t.pose, canStart = t.canStart, onTick = t.onTick,
        axis = t.axis, sign = t.sign, part = t.part,
    }
    BMX.Tricks[id] = trick
    BMX.TrickOrder[#BMX.TrickOrder + 1] = id
    if t.onTick then BMX.TickList[#BMX.TickList + 1] = trick end
    if kind == "pose" and not BMX.PoseTricks[t.pose] then BMX.PoseTricks[t.pose] = trick end

    -- A pose gets its wire id the first time anything names it. One byte, so
    -- 255 poses is the ceiling, and 255 is far more than a rider has limbs for.
    if t.pose and not BMX.PoseIDs[t.pose] then
        local n = #BMX.PoseNames + 1
        if n > 255 then bad(id, "more than 255 poses") end
        BMX.PoseNames[n] = t.pose
        BMX.PoseIDs[t.pose] = n
    end
    return trick
end

-- The registered tricks of one kind, in registration order.
function BMX.TricksOfKind(kind)
    local out = {}
    for _, id in ipairs(BMX.TrickOrder) do
        local t = BMX.Tricks[id]
        if t.kind == kind then out[#out + 1] = t end
    end
    return out
end

-- The pose trick for a pose name, or nil.
function BMX.TrickForPose(pose) return BMX.PoseTricks[pose] end

--------------------------------------------------------------------------
-- WHICH POSE IS THE RIDER ASKING FOR? A pure function of the keys, so the
-- server's usercmd decode and the tests share it.
--
--   k.alt    the trick modifier (IN_WALK, Alt by default)
--   k.rmb    right mouse
--   k.fwd    W is down       k.back   S is down      (both = superman)
--   k.side   -1 A, +1 D, 0 neither
--   k.jump   SPACE
--   k.air    both wheels off the ground
--   k.manual in a wheelie or a stoppie
--
-- Alt turns W/S/A/D into poses instead of rotations. RMB + W is X-up, and
-- RMB + A/D stays the 360 it always was (a rider's hands know it), so the
-- turndown, which wants RMB + A/D, takes Alt as well: Alt + RMB + A/D.
-- On the ground only X-up in a manual is a pose, and it takes Alt there:
-- RMB + W in a manual is just a wheelie under power, and a pose that paid
-- every powered wheelie would change what a wheelie is worth.
--------------------------------------------------------------------------
function BMX.DecodePose(k)
    if k.air then
        if k.alt then
            if k.rmb then
                if (k.side or 0) ~= 0 then return "turndown" end
                return "tabletop"
            end
            if k.jump then return "nothing" end
            if k.fwd and k.back then return "superman" end
            if (k.side or 0) < 0 then return "cancan_l" end
            if (k.side or 0) > 0 then return "cancan_r" end
            if k.fwd then return "nohander" end
            if k.back then return "nofooter" end
            return nil
        end
        if k.rmb and k.fwd and not k.back then return "xup" end
        return nil
    end
    if k.manual and k.alt and k.rmb and k.fwd and not k.back then return "xup" end
    return nil
end

--------------------------------------------------------------------------
-- THE WIRE. The frame spin, the bar spin and the pose travel as ONE int on the
-- bike, a byte each: where each part is in its turn as 0..255 of a revolution,
-- and the pose id (BMX.PoseIDs, 0 = none). Packed by sv_tricks.lua, read here
-- by cl_init.lua, so it lives where both can see it.
--------------------------------------------------------------------------
function BMX.UnpackTrickBits(bits)
    bits = bits or 0
    local w = bits % 256
    local b = math.floor(bits / 256) % 256
    local id = math.floor(bits / 65536) % 256
    return w / 256 * math.pi * 2, b / 256 * math.pi * 2, id
end

-- How long the rider takes to move into, or out of, a pose (cl_rider.lua).
BMX.PoseBlendTime = 0.15

--------------------------------------------------------------------------
-- THE BUILT-INS. Same names, same numbers, as when they were rows in
-- sv_air.lua: registering them changed where they live and nothing else.
--------------------------------------------------------------------------
local K = BMX.Config.Tricks
local G = BMX.Config.Grind

-- Whole-bike rotations: points per full turn.
BMX.RegisterTrick{ id = "backflip",    name = "Backflip",    kind = "spin", axis = "spinPitch", sign =  1,
    points = 500, input = "S in the air (hold)" }
BMX.RegisterTrick{ id = "frontflip",   name = "Frontflip",   kind = "spin", axis = "spinPitch", sign = -1,
    points = 500, input = "W in the air (hold)" }
BMX.RegisterTrick{ id = "barrel_roll", name = "Barrel Roll", kind = "spin", axis = "spinRoll",  sign =  0,
    points = 400, input = "A / D in the air (hold)" }
BMX.RegisterTrick{ id = "spin360",     name = "360",         kind = "spin", axis = "spinYaw",   sign =  0,
    points = 250, input = "RMB + A / D in the air (hold)" }

-- Frame and bar spins (G03). Rate, snap-back and landing rules are the
-- config's (Tricks.whipRate ... partMaxOut) and are applied in sv_tricks.lua.
BMX.RegisterTrick{ id = "tailwhip", name = "Tailwhip", kind = "part", part = "whip",
    points = 600, input = "LMB + A / D in the air (hold; let go past 270 deg to finish)" }
BMX.RegisterTrick{ id = "barspin",  name = "Barspin",  kind = "part", part = "bar",
    points = 400, input = "R in the air or a manual (A / D picks the way); LMB + R = both" }

-- Style poses (G17): held, paid per Tricks.poseTick, and you must be out of
-- them before the wheels touch.
local function inAir(st) return st.airMode and true or false end
local function inAirOrManual(st) return (st.airMode or st.manual) and true or false end

local function pose(id, name, per, input, pname, canStart)
    BMX.RegisterTrick{ id = id, name = name, kind = "pose", pose = pname or id,
        points = per, input = input, canStart = canStart or inAir }
end
pose("nohander",  "No-Hander",  8,  "Alt + W in the air")
pose("nofooter",  "No-Footer",  8,  "Alt + S in the air")
pose("cancan_l",  "Can-Can",    10, "Alt + A in the air (left leg)")
pose("cancan_r",  "Can-Can",    10, "Alt + D in the air (right leg)")
pose("superman",  "Superman",   15, "Alt + W + S in the air")
pose("nothing",   "Nothing",    30, "Alt + SPACE in the air (no hands, no feet)")
pose("xup",       "X-Up",       10, "RMB + W in the air; Alt + RMB + W in a manual", nil, inAirOrManual)
pose("turndown",  "Turndown",   12, "Alt + RMB + A / D in the air")
pose("tabletop",  "Tabletop",   14, "Alt + RMB in the air")

-- Ground tricks and grinds: names for the scoring; the config pays.
BMX.RegisterTrick{ id = "wheelie", name = "Wheelie", kind = "ground",
    points = K.wheeliePerSec, input = "RMB (weight back), with W for power" }
BMX.RegisterTrick{ id = "stoppie", name = "Stoppie", kind = "ground",
    points = K.stoppiePerSec, input = "LMB (front brake) at speed" }
BMX.RegisterTrick{ id = "crank_grind", name = "Crank Grind", kind = "grind",
    points = G.pointsPerSec, input = "bunny hop onto a pipe, along it" }
BMX.RegisterTrick{ id = "peg_grind", name = "Double Peg Grind", kind = "grind",
    points = G.pointsPerSec, input = "bunny hop onto a ledge edge, along it" }
