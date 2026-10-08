--[[--------------------------------------------------------------------------
    bmx/cl_scooter.lua

    THE KICK SCOOTER, CLIENT SIDE (G24): the scooter drawn from tubes and boxes, as
    the bike and the board are, and the rider on it.

    A MODEL BUILT IN CODE (zero content, no ripped assets; cl_geo_board.lua's
    "scooter", docs/MODELS.md): a box-section deck with grip, a neck to an integrated
    head tube, fork-less rear dropouts, a flex fender brake, a threadless fork under a
    4-bolt clamp, an oversized T-bar with grips and a bell, metal-cored wheels, pegs.
    Until it is built (or with bmx_bike_model 0, or bmx_debug) tubes and boxes stand
    in. Where each part goes is a function of what the server
    networks (shared.lua: the steer, the trick bits for the whip and the bar spin, the
    push phase) and nothing is simulated here.

    THE TRICKS ARE G03'S, DRAWN THE SAME WAY (cl_init.lua). A tailwhip turns the rear
    group -- the deck, the fender and the rear wheel -- about the steer tube, which is
    the head tube's line, while the bars and the rider stay; a barspin turns the bars,
    the fork and the front wheel about it. On a bike that rear group is the frame; on
    a scooter it is the deck, which is why a scooter tailwhip reads so much better.
    The rider's feet are targeted at where the deck WAS (unwhipped), so they leave it
    as it goes round and meet it again, and the hands are targeted at the bars without
    the spin, so they let go while the bars turn.

    THE RIDER stands on the deck, one foot ahead of the other, hands on the grips as
    the bars steer. The base pose is the stock standing idle (the board's), the knees
    bend by lowering the pelvis (the board's calibrated nudge, cl_board.lua) and both
    feet and both hands are pinned by the bike's IK solver. A kick is the board's push
    cycle on the scooter's geometry: the standing knee folds while the back foot steps
    off the deck's edge to the ground, sweeps back past the rear wheel and is carried
    home outside the deck (SC.RiderTargets). Nobody has watched this on a real player
    model: every offset is a number in BMX.Scooter.Tune or beside SC.RiderTargets, and
    the suite checks the targets against the scooter (tests/test_scooter_rider.lua).
----------------------------------------------------------------------------]]

BMX = BMX or {}
local SC = BMX.Scooter
local T = SC.Tune
local B = BMX.Board

local abs, min, max, sin, cos = math.abs, math.min, math.max, math.sin, math.cos

local function rotVec(v, axis, ang)
    if ang == 0 then return v end
    local c, s = cos(ang), sin(ang)
    return v * c + axis:Cross(v) * s + axis * (axis:Dot(v) * (1 - c))
end

local function rotAbout(p, origin, axis, ang)
    if ang == 0 then return p end
    return origin + rotVec(p - origin, axis, ang)
end

local function approachAngle(cur, target, rate, dt)
    local d = (target - cur + math.pi) % (math.pi * 2) - math.pi
    if abs(d) < 1e-4 then return target end
    return cur + d * min(1, rate * dt)
end

local TRICK_FOLLOW = 40     -- 1/s: the drawn part follows the networked byte

--------------------------------------------------------------------------
-- THE FRAME'S POINTS, chassis space (x forward, y left, z up, the origin on the axle
-- line), a pure function of the wheelbase so the suite can read it without a renderer.
-- The steer axis runs from the head tube's foot to its top, leaning back.
--------------------------------------------------------------------------
function SC.Frame(half)
    local headB = Vector(half - T.headFoot, 0, 2.2)
    local headT = Vector(half - T.headFoot - T.headLean, 0, T.barHeight - 2.0)
    return {
        headB = headB, headT = headT,
        axis = (headT - headB):GetNormalized(),
        bars = headT + Vector(0, 0, 2.0),
        deckMid = Vector((T.deckFront + T.deckBack) * 0.5, 0, T.deckTop - 0.45),
        deckLen = T.deckFront - T.deckBack,
    }
end

--------------------------------------------------------------------------
-- THE POSE SET. The style poses (the bike's, BMX.RiderPoses) are written for a rider
-- sat over a bike: a hand "up" is at 36 units. A scooter rider stands, so their hands
-- go up 20 further; the feet and the body keep their numbers.
--------------------------------------------------------------------------
local SET = BMX.PoseSets.scooter
SET.poses = {}
for id, row in pairs(BMX.RiderPoses) do
    local r = {}
    for k, v in pairs(row) do r[k] = v end
    for _, hand in ipairs({ "rHand", "lHand" }) do
        if r[hand] then r[hand] = r[hand] + Vector(0, 0, 20) end
    end
    SET.poses[id] = r
end

-- The stock standing idle, in place of the seated drive pose (the board's, which is
-- the same thing: a rider standing on a platform).
SET.activity = function(ply, bike)
    local board = BMX.PoseSets.board
    return board.activity and board.activity(ply, bike)
end

-- The bone offsets for the ride: the knees bend with the hop's preload and a landing's
-- crouch (the pelvis lowered), the STANDING knee folds deep through a kick (the deck
-- is high off the ground and the kicking foot has to reach it, and then reach back),
-- the knees come up in the air, the torso leans into the steer, over the bars at
-- speed and further over them through a kick, the head holds the horizon. What the
-- drawing worked out this frame is on the scooter (bike.bmxRide).
local KICK_DROP = 9             -- units the pelvis goes down at the bottom of a kick
local AIR_TUCK  = 3             -- ...and in the air
SC.KickDrop = KICK_DROP

function SC.BodyDrop(s)
    local crouch = math.Clamp(s.crouch or 0, 0, 1)
    -- Soft knees at rest (the board's riding bend), deeper with the crouch.
    local depth, bend = B and B.CrouchDepth or 9, (B and B.RideBend or 5) * 1.2
    local d = bend + crouch * (depth - bend)
    return d + (1 - crouch) * ((s.pushBend or 0) * KICK_DROP + (s.air or 0) * AIR_TUCK)
end

SET.rider = function(s)
    local ply = s.ply
    local R = s.bike and s.bike.bmxRide or {}
    local crouch = math.Clamp(s.hop or 0, 0, 1)
    if ply and B and B.LowerPelvis then
        B.LowerPelvis(ply, SC.BodyDrop({ crouch = crouch, pushBend = R.pushBend, air = R.air }))
    end
    local speedLean = math.Clamp((s.speed or 0) / 330, 0, 1) * 6
    local spine = crouch * 16 + speedLean + (R.pushBend or 0) * 10 + math.deg(s.pitch or 0) * 0.5
    local twist = math.deg(s.steer or 0) * 0.3
    return {
        spine = Angle(0, spine, twist),
        head  = Angle(0, -spine * 0.7, -twist * 0.5),
    }
end

-- Both feet and both hands are the solver's. The bike's solver is handed the real
-- vehicle: a scooter rider faces the way it goes. (Not the stance offsets of the seated
-- rider, which are for sitting on a saddle.)
SET.solveIK = function(ply, bike)
    if bike.ikTargets and BMX.SolveRiderIK then BMX.SolveRiderIK(ply, bike.ikTargets, bike) end
end

--------------------------------------------------------------------------
-- THE RIDER'S TARGETS, a pure function so the suite can check every one against
-- the scooter's geometry. Space: the frame's (chassis space with the static sag
-- added, x forward, y left, z up; SC.Frame's points are in it).
--
-- THE FEET stand on the deck with the ankle B.Ankle over its grip. The back (right)
-- foot kicks: the board's push cycle (B.PushFoot), on the scooter's geometry --
-- stepped off the deck's right edge to the ground beside the standing foot, swept
-- back along the ground past the rear wheel, lifted and carried forward outside the
-- deck and set back on it. Through a tailwhip both feet jump off the deck, highest
-- as it comes round under them, and land back on it.
--
-- THE HANDS hold the grips: the point nearest each shoulder on the grip's length
-- (A to B, cl_rider.lua). Through a barspin they let go, up and back off the bar so
-- it can turn under them, and take it again as it comes home.
--
-- `s`: push (phase, -1 off), whip, bar (radians), geo (SC.KickGeo). `F` is SC.Frame.
--------------------------------------------------------------------------
local WHIP_JUMP = 5.0           -- how high the feet jump while the deck whips round
local BAR_LET_GO = 2.5          -- how far the hands come off the bar through a spin

-- The ground and the deck for the kick, in the frame's space: the wheels stand on the
-- ground one radius under their axles, which are the frame's z = 0.
function SC.KickGeo(radius, half)
    local A = B.Ankle or 2.8
    return {
        stand = T.deckTop + A, ground = -radius + A,
        side = -(T.deckWidth * 0.5 + 3.0),
        plantX = T.footBack + 3.0, backX = -(half + 2.0),
        deckHalf = T.deckWidth * 0.5,
        share = B.Tune.kickTime / T.kickInterval,
    }
end

function SC.RiderTargets(s, F)
    local A = B.Ankle or 2.8
    local footZ = T.deckTop + A
    local frontBolt = Vector(T.footFront, 0.9, footZ)
    local backBolt  = Vector(T.footBack, -0.9, footZ)
    local jump = WHIP_JUMP * min(1, abs(sin((s.whip or 0) * 0.5)) * 2.5)
    local lFoot = frontBolt + Vector(0, 0, jump)
    local rFoot, kicking = backBolt + Vector(0, 0, jump), false
    if (s.push or -1) >= 0 and jump == 0 then
        rFoot, kicking = B.PushFoot(s.push, backBolt, nil, s.geo)
    end
    local bars, w = F.bars, T.barWidth * 0.5
    -- Up and back toward the rider, off the bar, while it spins.
    local free = min(1, abs(sin((s.bar or 0) * 0.5)) * 3)
    local off = Vector(-BAR_LET_GO * 0.8, 0, BAR_LET_GO) * free
    local t = {
        lFoot = lFoot, rFoot = rFoot, kicking = kicking,
        rHand = bars + Vector(0, -(w - 1.8), 0) + off, lHand = bars + Vector(0, w - 1.8, 0) + off,
        rHandA = bars + Vector(0, -(w - 3.6), 0) + off, rHandB = bars + Vector(0, -w, 0) + off,
        lHandA = bars + Vector(0, w - 3.6, 0) + off, lHandB = bars + Vector(0, w, 0) + off,
    }
    return t
end

--------------------------------------------------------------------------
-- THE DRAWING.
--------------------------------------------------------------------------
local COL_GRIP   = Color(26, 26, 29)
local COL_WHEEL  = Color(236, 232, 214)
local COL_CORE   = Color(200, 204, 212)
local COL_BAR    = Color(190, 194, 202)
local COL_DARK   = Color(34, 34, 38)
local MAT_MATTE  = "models/debug/debugwhite"
local MAT_CHROME = "phoenix_storms/fender_chrome"

local function wheel(kit, c, axis, fwd, up, spin, radius, lod)
    local ww = 1.2
    kit.tube(c - axis * (ww * 0.5), c + axis * (ww * 0.5), radius * 2, COL_WHEEL)
    if lod < 2 then
        kit.tube(c - axis * (ww * 0.6), c + axis * (ww * 0.6), radius * 0.9, COL_CORE)
    end
    if lod == 0 then
        local pin = (fwd * cos(spin) + up * sin(spin)) * (radius * 0.6)
        kit.tube(c + pin - axis * (ww * 0.65), c + pin + axis * (ww * 0.65), 0.5, COL_DARK)
    end
end

--------------------------------------------------------------------------
-- THE MODEL (cl_geo_board.lua's "scooter"): the frame's numbers it is built to, and
-- where its groups go. The rear group (deck, neck, head tube, fender, rear wheel)
-- turns by the whip about the steer axis; the front (fork, bars, front wheel) by the
-- steer and the barspin about it, as the primitive scooter's parts do. The wheels
-- are on the model's own axles, turning: a stiff scooter's wheels stay in its
-- dropouts (the suspension's travel is the rider's legs).
--------------------------------------------------------------------------
function SC.ModelExtra()
    return { deckTop = T.deckTop, deckFront = T.deckFront, deckBack = T.deckBack, deckWidth = T.deckWidth,
             barHeight = T.barHeight, barWidth = T.barWidth, headFoot = T.headFoot, headLean = T.headLean,
             pegY = T.pegY }
end

local function matFromMap(f)
    local o = f(Vector(0, 0, 0))
    return BMX.BikeMesh.Matrix(o, f(Vector(1, 0, 0)) - o, f(Vector(0, 1, 0)) - o, f(Vector(0, 0, 1)) - o)
end

local function wheelMat(map, centre, spin)
    local o = map(centre)
    local ex = map(centre + Vector(1, 0, 0)) - o
    local ey = map(centre + Vector(0, 1, 0)) - o
    local ez = map(centre + Vector(0, 0, 1)) - o
    return BMX.BikeMesh.Matrix(o, rotVec(ex, ey, spin), ey, rotVec(ez, ey, spin))
end

-- `d`: P (chassis space to world, as the drawer has it), headB and steerAxis (world),
-- whip, bar, steer (radians), fSpin, rSpin, paint, lod. Returns the maps it drew with.
function SC.ModelMaps(model, d)
    local P, hb, ax = d.P, d.headB, d.steerAxis
    local maps = {}
    maps.deck = function(m) return rotAbout(P(m), hb, ax, d.whip or 0) end
    maps.front = function(m) return rotAbout(P(m), hb, ax, (d.bar or 0) - (d.steer or 0)) end
    return maps
end

function SC.DrawModel(ent, model, d)
    local BM = BMX.BikeMesh
    local lay = model.layout
    local maps = SC.ModelMaps(model, d)
    local paint, lod = d.paint, d.lod
    BM.BeginLighting(ent:LocalToWorld(Vector(0, 0, 14)), ent)
        BM.DrawGroup(model, "deck", matFromMap(maps.deck), paint, lod)
        BM.DrawGroup(model, "fork", matFromMap(maps.front), paint, lod)
        BM.DrawGroup(model, "bars", matFromMap(maps.front), paint, lod)
        BM.DrawGroup(model, "wheel", wheelMat(maps.deck, lay.rear, d.rSpin or 0), paint, lod)
        BM.DrawGroup(model, "wheel", wheelMat(maps.front, lay.front, d.fSpin or 0), paint, lod)
        if lay.bellPivot and model.groups.bellLever then
            local ang = math.rad(38) * (BMX.BellFlick and BMX.BellFlick(CurTime() - (ent.bellRungAt or -10)) or 0)
            local pv, bx = lay.bellPivot, lay.bellAxis or Vector(0, 0, 1)
            BM.DrawGroup(model, "bellLever", matFromMap(function(m)
                return maps.front(pv + rotVec(m - pv, bx, ang))
            end), paint, lod)
        end
    BM.EndLighting()
    return maps
end

BMX.DrawVehicle = BMX.DrawVehicle or {}
-- The scooter's built model, or nil while it builds (asking advances the build).
function BMX.ScooterModel(ent)
    local bike, C = ent:Bike(), ent:Cfg()
    local BM, WC = BMX.BikeMesh, C.Wheel
    if not bike.look or not BM then return nil end
    return BM.Get(WC.wheelbase / 39, WC.radius, bike.look, {
        wheelbase = WC.wheelbase, restLength = WC.restLength,
        seat = { C.Chassis.seatOffset.x, C.Chassis.seatOffset.y, C.Chassis.seatOffset.z },
        extra = SC.ModelExtra(),
    })
end

BMX.DrawVehicle.scooter = function(ent, kit)
    local bike = ent:Bike()
    local C = ent:Cfg()
    local WC = C.Wheel
    local dt = FrameTime()
    local debug = GetConVar("bmx_debug") and GetConVar("bmx_debug"):GetInt() > 0
    local lod = kit.lod(ent, debug)
    local half = WC.wheelbase * 0.5

    local fwd, up, right = ent:GetForward(), ent:GetUp(), ent:GetRight()

    -- The tricks, as networked: the whip and the bar spin arrive a byte at a time and are
    -- followed, the pose blends over BMX.PoseBlendTime.
    local whipA, barA, poseId = BMX.UnpackTrickBits(ent:GetTrickBits())
    ent.drawWhip = approachAngle(ent.drawWhip or whipA, whipA, TRICK_FOLLOW, dt)
    ent.drawBar  = approachAngle(ent.drawBar  or barA,  barA,  TRICK_FOLLOW, dt)
    local whipAng, barAng = ent.drawWhip, ent.drawBar
    local W = BMX.UpdatePoseWeights(ent, BMX.PoseNames[poseId], dt)
    local bodyRoll = BMX.PoseDrawAngles(W, SET.poses)

    -- A tabletop lays the whole scooter over about its long axis.
    local bodyAng = ent:GetAngles()
    if bodyRoll ~= 0 then
        right, up = rotVec(right, fwd, bodyRoll), rotVec(up, fwd, bodyRoll)
        bodyAng = fwd:AngleEx(up)
    end

    -- The steer is an output of the balance controller, networked (shared.lua).
    local steer = BMX.VisualSteer(ent:GetSteer(), ent:GetSpeedUPS(), C)
    local steeredFwd = fwd
    if steer ~= 0 then
        local c, s = cos(steer), sin(steer)
        steeredFwd = fwd * c + right * s
    end
    local steeredRight = steeredFwd:Cross(up)
    steeredRight:Normalize()

    -- The wheels: where the suspension has them (the same trace the server's makes), or
    -- at rest when far away.
    local lift = WC.restLength
    local g = physenv.GetGravity():Length()
    local sag = math.Clamp(C.Chassis.mass * g * 0.5 / WC.spring, 0, WC.restLength)
    local lift0 = Vector(0, 0, sag)
    local fPos, fHit, rPos, rHit
    if lod >= 2 then
        fPos, rPos = ent:LocalToWorld(Vector(half, 0, sag)), ent:LocalToWorld(Vector(-half, 0, sag))
        fHit = ent:GetGrounded(); rHit = fHit
    else
        fPos, fHit = kit.axlePos(ent, Vector(half, 0, lift))
        rPos, rHit = kit.axlePos(ent, Vector(-half, 0, lift))
    end
    local fallen = abs((BMX.Attitude(ent, vector_up))) > C.Stand.maxRoll
    local fSpin = ent:WheelSpin("front", fHit, fallen, dt)
    local rSpin = ent:WheelSpin("rear", rHit, fallen, dt)

    local bodyC = ent:LocalToWorld(Vector(0, 0, 10))
    local function P(v)
        local p = ent:LocalToWorld(v + lift0)
        return bodyRoll ~= 0 and rotAbout(p, bodyC, fwd, bodyRoll) or p
    end
    if bodyRoll ~= 0 then
        fPos, rPos = rotAbout(fPos, bodyC, fwd, bodyRoll), rotAbout(rPos, bodyC, fwd, bodyRoll)
    end

    local F = SC.Frame(half)
    local headB, headT = P(F.headB), P(F.headT)
    local steerAxis = (headT - headB):GetNormalized()
    -- The rear group (deck, fender, rear wheel) turns by the whip; the front end (fork,
    -- bars, front wheel) by the barspin.
    local function Wh(p) return rotAbout(p, headB, steerAxis, whipAng) end
    local function Wv(v) return rotVec(v, steerAxis, whipAng) end
    local function Bs(p) return rotAbout(p, headB, steerAxis, barAng) end
    local function Bv(v) return rotVec(v, steerAxis, barAng) end

    local rPosD, fPosD = Wh(rPos), Bs(fPos)
    local fwdW, upW, rightW = Wv(fwd), Wv(up), Wv(right)
    local deckAng = whipAng ~= 0 and fwdW:AngleEx(upW) or bodyAng
    local fAxis, fFwd, fUp = Bv(steeredRight), Bv(steeredFwd), Bv(up)

    local col = BMX.PaletteColor(ent:GetColorIndex())

    -- THE BUILT MODEL (cl_geo_board.lua's "scooter"), once it is built and unless
    -- bmx_bike_model is 0 or bmx_debug wants the simple one; the primitives below stand
    -- in meanwhile. The rider's targets further down are the same either way.
    local BM = BMX.BikeMesh
    local model = not debug and BMX.ScooterModel(ent) or nil
    if model then
        SC.DrawModel(ent, model, {
            P = P, headB = headB, steerAxis = steerAxis, whip = whipAng, bar = barAng, steer = steer,
            fSpin = fSpin, rSpin = rSpin, paint = col, lod = lod,
        })
    else
        wheel(kit, fPosD, fAxis, fFwd, fUp, fSpin, WC.radius, lod)
        wheel(kit, rPosD, rightW, fwdW, upW, rSpin, WC.radius, lod)
    end

    ------------------------------------------------------------------------
    -- The deck (paint underneath, grip tape on top), the neck that ties it to the head
    -- tube, and the rear: a ramp kicked up over the wheel and the flex fender on it.
    ------------------------------------------------------------------------
    local deckC = Wh(P(F.deckMid))
    if not model then
        kit.solid("box", deckC, deckAng, Vector(F.deckLen, T.deckWidth, 0.9), col)
        kit.solid("box", deckC + upW * 0.5, deckAng, Vector(F.deckLen - 0.4, T.deckWidth - 0.4, 0.12), COL_GRIP, MAT_MATTE)
        kit.tube(Wh(P(Vector(T.deckFront, 0, T.deckTop - 0.6))), Wh(headB), 2.2, col)       -- the neck
        local kickA = Wh(P(Vector(T.deckBack, 0, T.deckTop - 0.6)))
        local kickB = Wh(P(Vector(-half - 5.5, 0, WC.radius + 1.3)))
        kit.tube(kickA, kickB, 2.0, col)                                                    -- the kick-up
        if lod < 2 then
            kit.solid("box", Wh(P(Vector(-half - 3, 0, WC.radius + 1.6))), deckAng,
                Vector(11, 4.2, 0.5), COL_DARK, MAT_MATTE)                                  -- the fender brake
            for _, side in ipairs({ 1, -1 }) do
                kit.tube(rPosD + rightW * (side * 1.8), Wh(P(Vector(-half - 3, side * 1.8, WC.radius + 1.0))),
                    0.8, COL_BAR)                                                           -- the dropouts
            end
        end

        ------------------------------------------------------------------------
        -- The steer tube and the fork, which turn with the bars, and the T-bar.
        ------------------------------------------------------------------------
        local headTop = Bs(headT)
        local headBot = Bs(headB)
        kit.tube(headBot, headTop, 2.0, COL_BAR)
        for _, side in ipairs({ 1, -1 }) do
            kit.tube(headBot + fAxis * (side * 1.4), fPosD + fAxis * (side * 1.4), 1.0, COL_BAR)    -- the fork legs
        end
        -- The bars sit on the head tube's top, turned with the steer.
        local barsC = Bs(P(F.bars))
        local barL, barR = barsC - fAxis * (T.barWidth * 0.5), barsC + fAxis * (T.barWidth * 0.5)
        kit.tube(barL, barR, 1.4, COL_BAR)
        kit.tube(headTop, barsC, 1.6, COL_BAR)
        if lod < 2 then
            for _, side in ipairs({ 1, -1 }) do
                local e = barsC + fAxis * (side * T.barWidth * 0.5)
                kit.tube(e - fAxis * (side * 3.6), e, 1.7, COL_GRIP)                        -- the grips
            end
        end
    end

    ------------------------------------------------------------------------
    -- Where the rider's hands and feet belong (cl_rider.lua's IK reads
    -- ent.ikTargets; SC.RiderTargets works them out). The feet are on the deck as it
    -- was UNWHIPPED, so a tailwhip leaves them behind and they meet it again; the
    -- hands are on the grips as the steer has them but without the spin, so a
    -- barspin leaves them. The left foot leads.
    ------------------------------------------------------------------------
    local R = ent.bmxRide or {}
    ent.bmxRide = R
    local now = CurTime()
    if ent:GetGrounded() then R.airAt = nil elseif not R.airAt then R.airAt = now end
    local airT = R.airAt and (now - R.airAt) or nil
    local push = airT and -1 or ent:GetPushPhase()
    local geo = SC.KickGeo(WC.radius, half)
    R.pushBend = B.PushBend(push, geo)
    R.air = airT and B.Ease(airT / 0.15) or 0
    local t = SC.RiderTargets({ push = push, whip = whipAng, bar = barAng, steer = steer, geo = geo }, F)
    local function C2W(v) return ent:LocalToWorld(v + lift0) end
    -- The grips are turned with the bars about the steer axis (the model turns its
    -- front by -steer about it, SC.ModelMaps), and leaned over with a tabletop.
    local function G(v)
        local p = P(v)
        return steer ~= 0 and rotAbout(p, headB, steerAxis, -steer) or p
    end
    local ik = {
        lFoot = C2W(t.lFoot), rFoot = C2W(t.rFoot),
        rHand = G(t.rHand), lHand = G(t.lHand),
        rHandA = G(t.rHandA), rHandB = G(t.rHandB),
        lHandA = G(t.lHandA), lHandB = G(t.lHandB),
    }
    BMX.ApplyPoseTargets(ik, W, function(v)
        local p = ent:LocalToWorld(v + lift0)
        return bodyRoll ~= 0 and rotAbout(p, bodyC, fwd, bodyRoll) or p
    end, SET.poses)
    ent.ikTargets = ik

    if debug then
        render.DrawLine(headB, headT, Color(255, 200, 60), true)
        render.DrawLine(deckC, deckC + upW * 10, Color(80, 120, 255), true)
    end
end
