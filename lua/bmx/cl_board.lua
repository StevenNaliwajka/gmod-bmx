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
    they have gone, and lift a little through a flip. That is the part the other
    skateboard addon could not animate, and it is the same trick as the bike's
    tailwhip: the feet stay where the pedals were.

    THE RIDER stands sideways on the deck. The base pose is the stock standing
    idle, the knees bend by lowering the pelvis (calibrated once per model, as the
    fingers' curl is) with both feet pinned to the deck by the same two-bone IK the
    bike's legs use, the arms balance, and the push is the back foot leaving the
    deck, sweeping along the ground and coming back, driven by the server's push
    phase and not by an animation. Nobody has watched this on a real player model:
    every offset is a number in a table below.
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
-- THE FEET. Board-space targets for each foot, in the CHASSIS frame (so that a
-- flip leaves them behind) and in the push cycle's. `stance` is +1 for the left
-- foot forward. Returns { front = Vector, back = Vector } in chassis-local space
-- (x forward), and the pushing foot's air/ground blend.
--
-- The push cycle (p, 0..1 through a kick interval, -1 not kicking): the back foot
-- steps off the deck to the ground beside the front foot (0..0.12 of a kick),
-- sweeps back along the ground (to 0.42), lifts and returns to its bolt (to 0.62).
--------------------------------------------------------------------------
local FOOT_Z = 4.6                          -- the ankle over the deck's top
local GROUND_Z = -1.3                       -- the ground, under the axle line

local function ease(t) t = max(0, min(1, t)) return t * t * (3 - 2 * t) end

function B.PushFoot(p, bolt, T0)
    T0 = T0 or T
    if not p or p < 0 then return bolt, false end
    local down = Vector(T0.footFront - 1, bolt.y, GROUND_Z + 2.4)
    local back = Vector(T0.footBack - 8, bolt.y, GROUND_Z + 2.4)
    local kickT = T0.kickTime / T0.kickInterval        -- the stroke, as a share of the interval
    if p < 0.12 then
        return bolt + (down - bolt) * ease(p / 0.12), true
    elseif p < 0.12 + kickT * 0.7 then
        return down + (back - down) * ease((p - 0.12) / (kickT * 0.7)), true
    elseif p < 0.62 then
        local t0 = 0.12 + kickT * 0.7
        local t = (p - t0) / (0.62 - t0)
        local lift = Vector(back.x, back.y, GROUND_Z + 7)
        if t < 0.5 then return back + (lift - back) * ease(t * 2), true end
        return lift + (bolt - lift) * ease((t - 0.5) * 2), true
    end
    return bolt, false
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
local RIDE_BEND = 3.2           -- ...and at rest: riding knees are always soft
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

-- The bone offsets for the ride: the torso follows the lean and folds with the
-- crouch, the head holds the horizon. Called from the rider hook BEFORE the IK
-- solve (cl_rider.lua), which is why the pelvis is lowered from here.
SET.rider = function(s)
    local bike, ply = s.bike, s.ply
    local crouch = bike and bike.GetCrouch and bike:GetCrouch() or 0
    crouch = max(crouch, s.hop or 0)
    -- NEVER LOCKED STRAIGHT: a skater rides on soft knees, a little deeper with
    -- speed; the crouch and a hop's preload go down from there.
    local speedBend = math.Clamp((s.speed or 0) / 300, 0, 1) * 1.2
    local bend = RIDE_BEND + speedBend
    if ply then lowerPelvis(ply, bend + crouch * (CROUCH_DEPTH - bend)) end
    local lean = bike and bike.GetBoardLean and bike:GetBoardLean() or 0
    local spine = crouch * 18 + math.deg(s.pitch or 0) * 0.5
    local twist = math.deg(lean) * 0.5
    return {
        spine = Angle(0, spine, twist),
        head  = Angle(0, -spine * 0.7, -twist * 0.5),
    }
end

--------------------------------------------------------------------------
-- THE RIDER'S IK: both feet on the bolts, hands out for balance. The solver is
-- the bike's (BMX.SolveRiderIK), handed a stand-in for the "bike" whose forward is
-- the way the RIDER faces, so the knees and toes point across the deck.
--------------------------------------------------------------------------
SET.solveIK = function(ply, bike)
    local ik = bike.ikTargets
    if not ik or not BMX.SolveRiderIK then return end
    local flags = bike:GetBoardFlags()
    local stance = B.Stance(B.HasFlag(flags, "goofy"), B.HasFlag(flags, "switch"))
    local up = bike:GetUp()
    local face = bike:GetRight() * (stance >= 0 and 1 or -1)   -- GetRight() is the board's right
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
    -- ent.ikTargets). The feet are targeted in the CHASSIS frame, so a flip
    -- leaves them where the deck was, and lifts them through it; the pushing foot
    -- goes to the ground; the hands are out for balance, or on the deck for a grab.
    ------------------------------------------------------------------------
    local cf, cr = ent:GetForward(), ent:GetRight()
    local function C2W(v) return ent:LocalToWorld(v) end
    local flip = max(abs(sin(df.roll * 0.5)), abs(sin(df.yaw)), abs(sin(df.pitch * 0.5)))
    local up = Vector(0, 0, flip * 4)
    local frontBolt = Vector(T.footFront, 0, FOOT_Z + lift)
    local backBolt  = Vector(T.footBack,  0, FOOT_Z + lift)
    local pf, pushing = B.PushFoot(ent:GetPushPhase(), backBolt)
    local feet = { front = frontBolt + up, back = pf + up }
    local lFoot = stance >= 0 and feet.front or feet.back
    local rFoot = stance >= 0 and feet.back or feet.front
    local faceY = stance >= 0 and -1 or 1
    local balance = ent:GetBoardLean() * 6
    local ik = {
        lFoot = C2W(lFoot), rFoot = C2W(rFoot),
        -- Arms out along the board, a little toward the way the rider faces.
        lHand = C2W(Vector(stance >= 0 and 13 or -13, faceY * 5, 36 + balance)),
        rHand = C2W(Vector(stance >= 0 and -13 or 13, faceY * 5, 36 - balance)),
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
