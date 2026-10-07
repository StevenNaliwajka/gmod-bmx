include("shared.lua")

--[[--------------------------------------------------------------------------
    entities/bmx_base/cl_init.lua

    Drawing. Two things are worth knowing before editing this file.

    1. WHEEL POSITION IS NOT NETWORKED. The client re-runs the same downward
       trace the server's suspension uses and places the wheel from the result.
       Two traces per bike per frame is far cheaper than networking two floats
       at physics rate, and it is exactly right on every client because the
       world geometry is identical on both ends.

    2. THE WHEELS ARE DRAWN PROCEDURALLY until a bike supplies a wheelModel.
       That is not laziness dressed up: seeing the ring the simulation thinks it
       is rolling on is the single most useful debugging aid this addon has. If
       the bike is behaving oddly, look at where the wheels are. They turn red
       when the trace finds no ground.
----------------------------------------------------------------------------]]

local TYRE_SEGMENTS = 48
local SPOKES        = 12

local COL_TYRE   = Color(24, 24, 27)
local COL_TREAD  = Color(58, 58, 62)
local COL_RIM    = Color(190, 194, 202)
local COL_SPOKE  = Color(160, 165, 175)
local COL_PART   = Color(34, 34, 38)       -- bars, cranks, seat, fork crown
local COL_CHROME = Color(200, 204, 212)
local COL_AIR    = Color(235, 90, 60)

-- Big enough for the frame, the bars and a rider, in chassis units at the
-- stock wheelbase; scaled per bike. Without it the engine culls the drawing
-- by the hidden model's bounds, and the bike vanishes at the edge of the view.
local BOUNDS_MIN, BOUNDS_MAX = Vector(-36, -18, -14), Vector(36, 18, 72)

function ENT:Initialize()
    self.spinAngle  = 0
    self.crankAngle = 0
    local k = self:Cfg().Wheel.wheelbase / 39
    self:SetRenderBounds(BOUNDS_MIN * k, BOUNDS_MAX * k)
end

--------------------------------------------------------------------------
-- ROTATIONS FOR THE TRICKS: a tailwhip swings the frame about the steer axis,
-- a barspin turns the bars about it, a tabletop lays the whole bike over.
-- Rodrigues, right-handed, so the three agree with each other.
--------------------------------------------------------------------------
local function rotVec(v, axis, ang)
    if ang == 0 then return v end
    local c, s = math.cos(ang), math.sin(ang)
    return v * c + axis:Cross(v) * s + axis * (axis:Dot(v) * (1 - c))
end

local function rotAbout(p, origin, axis, ang)
    if ang == 0 then return p end
    return origin + rotVec(p - origin, axis, ang)
end

-- The signed short way from `cur` to `target` (both radians mod a turn),
-- closed at `rate` a second: the drawn part follows the networked angle, which
-- arrives a byte at a time, without jumping.
local function approachAngle(cur, target, rate, dt)
    local d = (target - cur + math.pi) % (math.pi * 2) - math.pi
    if math.abs(d) < 1e-4 then return target end
    return cur + d * math.min(1, rate * dt)
end
local TRICK_FOLLOW = 40     -- 1/s

--------------------------------------------------------------------------
-- Where a wheel's axle is in world space right now, and whether it found
-- ground. Same geometry as Wheel:Simulate, forces omitted.
--------------------------------------------------------------------------
--
-- `ent`, not `self`: this is a plain local function, not a method, so there is
-- no `self` in scope. It used to read `self:Cfg()`, which is a nil index on
-- every frame of every bike on every client -- so the wheels, the fork and the
-- one debugging aid this file exists for never drew once. The headless suite
-- cannot see it (a dedicated server never calls Draw); tests/test_client.lua
-- can, because it runs this file.
local function axlePos(ent, mountLocal)
    local WC     = ent:Cfg().Wheel
    local maxLen = BMX.WheelReach(WC)
    local down   = -ent:GetUp()
    local mount  = ent:LocalToWorld(mountLocal)

    local tr = util.TraceLine({
        start  = mount,
        endpos = mount + down * maxLen,
        filter = { ent, ent:GetPod(), ent:GetDriver() },
        mask   = MASK_SOLID,
    })

    -- The same disc geometry the server's suspension uses (BMX.DiscContact),
    -- so a wheel is drawn where the simulation thinks it is: the whole value of
    -- drawing them procedurally.
    local s
    if tr.Hit then
        s = BMX.DiscContact(mount, down, ent:GetRight(), maxLen * tr.Fraction,
            tr.HitNormal, WC.radius)
    end
    if not s or s > WC.restLength then
        return mount + down * WC.restLength, false
    end
    return mount + down * math.max(s, 0), true
end

--------------------------------------------------------------------------
-- DRAWING PRIMITIVES: real 3D shapes.
--
-- Every tube on the bike is a cylinder -- base Garry's Mod's XQM unit cylinder
-- (12.5 across and 12.5 long, along its own X) scaled to the tube's length
-- and thickness -- in glossy paint, tinted per part. Joints are spheres, the
-- saddle a squashed one, the pedals blocks. One clientside model per shape
-- per bike, drawn many times a frame with a different transform each time.
--
-- This replaces flat camera-facing strips, which is what the whole frame
-- used to be: they read as paper cut-outs next to the real tyre model. They
-- remain as the fallback if the shapes will not load.
--------------------------------------------------------------------------
local PRIM = {
    cyl = { model = "models/xqm/cylinderx1.mdl",               size = 12.5 },
    sph = { model = "models/hunter/misc/sphere025x025.mdl",    size = 12.3625 },
    box = { model = "models/hunter/blocks/cube025x025x025.mdl", size = 12.3125 },
}
BMX.BikePrimitives = PRIM

--------------------------------------------------------------------------
-- MATERIALS BY WHAT THE PART IS, all base Garry's Mod. It was one glossy
-- paint for everything, and a mirror-finish saddle read as plastic, not
-- leather. Each is a light, neutral base, so the colour modulation still
-- tints it.
--------------------------------------------------------------------------
local MAT = {
    paint  = "phoenix_storms/mat/mat_phx_metallic",  -- the frame: metallic paint
    chrome = "phoenix_storms/fender_chrome",         -- post, pegs, spindle: the rims' chrome
    satin  = "phoenix_storms/mat/mat_phx_plastic",   -- bars, fork, cranks: anodised black
    matte  = "models/debug/debugwhite",              -- saddle, grips: leather and rubber
}
BMX.BikeMaterials = MAT

local drawing       -- the bike being drawn, for the shape cache

local function primModel(kind)
    local ent = drawing
    if not ent then return nil end
    ent.prims = ent.prims or {}
    local m = ent.prims[kind]
    if m and IsValid(m) then return m end
    if m == false and CurTime() < (ent.primRetry or 0) then return nil end
    m = ClientsideModel(PRIM[kind].model, RENDERGROUP_OPAQUE)
    if not IsValid(m) then
        ent.prims[kind] = false
        ent.primRetry = CurTime() + 3
        return nil
    end
    m:SetNoDraw(true)
    ent.prims[kind] = m
    return m
end

-- Which material a part gets, from the colour it is drawn in: the chrome and
-- black-part colours are fixed, so anything else is the frame's paint.
local function roleMaterial(col, override)
    if override then return override end
    if col == COL_CHROME or col == COL_RIM then return MAT.chrome end
    if col == COL_PART then return MAT.satin end
    if col == COL_TYRE or col == COL_TREAD then return MAT.matte end
    return MAT.paint
end

local function drawPrim(m, pos, ang, scale, col, material)
    m:SetMaterial(roleMaterial(col, material))
    local mat = Matrix()
    mat:Scale(scale)
    m:EnableMatrix("RenderMultiply", mat)
    m:SetPos(pos)
    m:SetAngles(ang)
    m:SetupBones()
    render.SetColorModulation(col.r / 255, col.g / 255, col.b / 255)
    m:DrawModel()
    render.SetColorModulation(1, 1, 1)
end

-- A tube from a to b, `width` across.
local function tube(a, b, width, col)
    local d = b - a
    local len = d:Length()
    local m = len > 0.01 and primModel("cyl")
    if not m then
        render.DrawBeam(a, b, width, 0, 1, col)
        return
    end
    local s = PRIM.cyl.size
    drawPrim(m, (a + b) * 0.5, d:Angle(), Vector(len / s, width / s, width / s), col)
end

-- A ball, `dia` across: where tubes meet, so a joint is round and not a gap.
local function joint(p, dia, col)
    local m = primModel("sph")
    if not m then return end
    local s = dia / PRIM.sph.size
    drawPrim(m, p, Angle(0, 0, 0), Vector(s, s, s), col)
end

-- A box or an ellipsoid, centred on `p`, `dims` long/wide/tall in `ang`.
local function solid(kind, p, ang, dims, col, material)
    local m = primModel(kind)
    if not m then
        render.DrawBox(p, ang, dims * -0.5, dims * 0.5, col)
        return
    end
    drawPrim(m, p, ang, dims / PRIM[kind].size, col, material)
end

-- A circle in the plane spanned by e1/e2, as a closed chain of beams. Each
-- segment is stretched past its ends by half the beam's width: camera-facing
-- beams meet at a corner with a notch between them, and on a thick ring those
-- notches were the holes that made a tyre look like a row of squares.
local function ring(center, e1, e2, radius, width, col, segments)
    local prev
    for i = 0, segments do
        local t = (i / segments) * math.pi * 2
        local p = center + (e1 * math.cos(t) + e2 * math.sin(t)) * radius
        if prev then
            local d = (p - prev):GetNormalized() * (width * 0.5)
            tube(prev - d, p + d, width, col)
        end
        prev = p
    end
end

--------------------------------------------------------------------------
-- THE TYRE MODEL. A real, round tyre from base Garry's Mod (Phoenix Storms'
-- moped tyre: black tread and sidewall on a chrome rim), so there is still no
-- content dependency and nothing from another game.
--
-- It replaces a tyre drawn as a ring of camera-facing beams, which is what a
-- rider on the server saw as "a few squares": each segment is a flat quad
-- turned to face the viewer, so from anywhere but side-on the ring came apart
-- into tiles. Measured on the live server: 38.4 across and 7.3 thick, axle on
-- the model's Z, origin on one face with the centre 4.37 up it.
--------------------------------------------------------------------------
local TYRE_MODEL   = BMX.TyreModel
local TYRE_RADIUS  = 19.19          -- model units
local TYRE_CENTREZ = 4.37           -- model units, along the axle
local TYRE_THIN    = 0.62           -- BMX tyres are narrower than a moped's

-- One clientside model per wheel, made on first draw and removed with the
-- bike. nil if the model will not load, and the beam drawing takes over.
--
-- NOT GATED ON util.IsValidModel, and a failure is RETRIED. The first version
-- asked IsValidModel first and cached a failure forever, and on a real client
-- the riders saw the beam fallback -- "a bunch of black squares" with spokes
-- turning inside a tyre that did not -- which is what a model that never
-- loaded looks like. The server now precaches the model (sh_bikes.lua) so
-- every client has it, the create is simply attempted, and a failure is tried
-- again a few seconds later rather than never, and reported once.
local RETRY = 3
local warned = false

local function tyreModel(ent, key, radius)
    ent.tyres = ent.tyres or {}
    local t = ent.tyres[key]
    if t and IsValid(t) then return t end
    if t == false and CurTime() < (ent.tyreRetry or 0) then return nil end

    local m = ClientsideModel(TYRE_MODEL, RENDERGROUP_OPAQUE)
    if not IsValid(m) then
        ent.tyres[key] = false
        ent.tyreRetry = CurTime() + RETRY
        if not warned then
            warned = true
            MsgN("[BMX] tyre model " .. TYRE_MODEL .. " did not load; drawing tyres instead")
        end
        return nil
    end
    m:SetNoDraw(true)
    local s = radius / TYRE_RADIUS
    local mat = Matrix()
    mat:Scale(Vector(s, s, s * TYRE_THIN))
    m:EnableMatrix("RenderMultiply", mat)
    m.bmxScale = s
    ent.tyres[key] = m
    return m
end

--------------------------------------------------------------------------
-- A wheel: tyre, rim, spokes, hub, and BMX pegs. The spokes carry the spin,
-- which is what makes speed legible at a glance.
--
-- The tyre turns red when its trace finds no ground, but only with bmx_debug
-- on. It used to be always, which was a debugging aid when the bike was a
-- plate with rings around it and reads as a glitch on something that looks
-- like a bike.
--------------------------------------------------------------------------
local function drawWheel(ent, key, center, axleDir, spin, radius, grounded, debug, lod)
    -- Any orthonormal basis spanning the wheel's plane. Angle():Up()/:Right()
    -- of the axle direction gives one for free.
    local a  = axleDir:Angle()
    local e1 = a:Up()
    local e2 = a:Right()

    local tyreW = radius * 0.24
    local model = tyreModel(ent, key, radius)
    if model and not (debug and not grounded) then
        -- Forward turns with the spin, up is the axle: the tyre rolls.
        local fwd = e1 * math.cos(spin) + e2 * math.sin(spin)
        local s = model.bmxScale
        model:SetPos(center - axleDir * (TYRE_CENTREZ * s * TYRE_THIN))
        model:SetAngles(fwd:AngleEx(axleDir))
        model:SetupBones()
        model:DrawModel()
    else
        -- The beam tyre: the fallback, and bmx_debug's red "no ground" tyre.
        local col = (debug and not grounded) and COL_AIR or COL_TYRE
        ring(center, e1, e2, radius - tyreW * 0.5, tyreW, col, TYRE_SEGMENTS)
        ring(center, e1, e2, radius - tyreW - 0.3, 0.7, COL_RIM, TYRE_SEGMENTS)
        -- Tread blocks, which turn with the wheel: a plain black ring looks
        -- the same at any spin, so without these the tyre read as stationary
        -- while the spokes inside it went round.
        for i = 0, 15 do
            local t = spin + (i / 16) * math.pi * 2
            local dir = e1 * math.cos(t) + e2 * math.sin(t)
            local tang = e1 * -math.sin(t) + e2 * math.cos(t)
            local at = center + dir * (radius - tyreW * 0.15)
            tube(at - tang * 0.5, at + tang * 0.5, tyreW * 0.55, COL_TREAD)
        end
    end

    -- Spokes only on the beam tyre: the model has its own chrome face, and
    -- lines drawn through it would read as scratches rather than spokes.
    if not model or (debug and not grounded) then
        local rim = radius - tyreW - 0.4
        for i = 0, SPOKES - 1 do
            local t = spin + (i / SPOKES) * math.pi * 2
            local p = center + (e1 * math.cos(t) + e2 * math.sin(t)) * rim
            render.DrawLine(center, p, COL_SPOKE, true)
        end
    end

    -- Hub and pegs: the pegs are the one part a BMX has that nothing else does.
    if (lod or 0) >= 2 then return end
    tube(center - axleDir * 2.2, center + axleDir * 2.2, 1.6, COL_CHROME)
    tube(center + axleDir * 2.4, center + axleDir * 6.0, 1.3, COL_CHROME)
    tube(center - axleDir * 2.4, center - axleDir * 6.0, 1.3, COL_CHROME)
end

--------------------------------------------------------------------------
-- How far each wheel has turned, per wheel, from what the client already has.
--
-- A tyre on the ground rolls at the bike's FORWARD speed (signed: backwards
-- is backwards). Off the ground nothing drives it, so it keeps its own spin
-- and winds down slowly on its bearings; on its side, the tyre scrubs the
-- ground and stops quickly. This used to be one angle for both wheels driven
-- by the bike's speed MAGNITUDE, so a crashed bike tumbling along, or falling,
-- spun its wheels as if it were being ridden, and they never stopped while
-- it was moving at all.
--------------------------------------------------------------------------
local BEARING_DRAG = 0.5     -- 1/s, a free wheel in the air
local SCRUB        = 6.0     -- 1/s, a wheel lying against the ground

function ENT:WheelSpin(key, grounded, fallen, dt)
    self.spin = self.spin or {}
    local w = self.spin[key] or { angle = 0, rate = 0 }
    self.spin[key] = w

    local r = self:Cfg().Wheel.radius
    if grounded and not fallen then
        w.rate = self:GetVelocity():Dot(self:GetForward()) / r
    else
        w.rate = w.rate * math.exp(-(fallen and SCRUB or BEARING_DRAG) * dt)
    end
    w.angle = w.angle + w.rate * dt
    return w.angle
end

--------------------------------------------------------------------------
-- The frame, in chassis space.
--
-- Points are in inches, which Source units are, on a stock 20-inch BMX with a
-- 39-unit wheelbase, measured from the design axle line. They scale with the
-- bike's own wheelbase, so a per-bike physics override that makes the bike
-- bigger draws a bigger bike. The two axles are NOT in this table: the stays
-- and the fork run to where the wheels actually are, so the frame stays
-- attached to them as the suspension (the rider's legs) works.
--------------------------------------------------------------------------
local FRAME = {
    bb     = Vector(-4.5, 0,  2.5),    -- bottom bracket: pedals clear the ground
                                        -- even at full travel
    seatJ  = Vector(-9.5, 0, 14.0),    -- where the top tube meets the seat tube
    seat   = Vector(-10.5, 0, 18.5),   -- top of the seat post
    headT  = Vector(12.5, 0, 17.5),    -- head tube, top
    headB  = Vector(14.5, 0, 10.5),    -- head tube, bottom
    bars   = Vector(10.5, 0, 26.0),    -- bar centre (BMX bars are tall and swept back)
}
--------------------------------------------------------------------------
-- THE BARS AND THE BRAKE CABLE (G01).
--
-- The competitor's addon shipped a bug where the right brake cable stayed
-- behind on the frame while the bars turned: a vertex weighted to the wrong
-- bone. Drawn from the steer angle there is no bone to get wrong, but the same
-- failure is still possible in a subtler form -- a cable computed from the
-- wrong transform -- so the geometry is pure functions of the steer angle and
-- tests/test_cable.lua checks, at +-90 degrees and through a full barspin, that
-- the cable's bar end is still on the bar and its frame ends have not moved.
--
-- The bars turn about the head tube: their offset from it is re-expressed
-- along the STEERED forward. `d` is the bar centre's offset from the head tube
-- top in the bike's frame (already scaled by k).
--------------------------------------------------------------------------
function BMX.SteeredBars(headT, fwd, right, up, steer, d, k)
    local c, s = math.cos(steer), math.sin(steer)
    local sf   = fwd * c + right * s
    local axle = sf:Cross(up)
    axle:Normalize()
    local barsC = headT + sf * d:Dot(fwd) + up * d:Dot(up)
    return {
        fwd = sf, axle = axle, barsC = barsC,
        barL = barsC - axle * (11 * k), barR = barsC + axle * (11 * k),
        stemTop = headT + up * (3 * k),
    }
end

-- A quadratic Bezier through three points, as `n + 1` points.
local function bezier(a, c, b, n)
    local pts = {}
    for i = 0, n do
        local t = i / n
        local u = 1 - t
        pts[#pts + 1] = a * (u * u) + c * (2 * u * t) + b * (t * t)
    end
    return pts
end

-- THE BRAKE CABLE, with a gyro detangler. A BMX with a rear brake and bars that
-- spin all the way round needs one: the cable runs from the lever to a plate
-- under the stem that is part of the FRAME and does not turn, and on from there
-- along the top tube to the brake. The lever end follows the bars; the gyro and
-- the brake end are fixed to the frame; the span between the lever and the gyro
-- is a loop with slack. Because the lever turns about the head tube axis and
-- the gyro sits ON it, their distance is the same at every steer angle, so the
-- slack is the same too: nothing stretches and nothing winds up, at +-90 or
-- through any number of barspins.
--
-- `bars` is BMX.SteeredBars; `brake` is the frame-side stop. Returns the lever,
-- gyro and brake points and the two polylines (`bar`: lever to gyro, `frame`:
-- gyro to brake).
function BMX.BrakeCable(bars, headT, up, brake, k, segments)
    segments = segments or 8
    local lever = bars.barR + bars.axle * (0.6 * k) + bars.fwd * (1.6 * k)
    local gyro  = headT + up * (2.2 * k)

    -- The loop hangs: its control point sags below the straight line in
    -- proportion to how far the ends are apart, which is constant (above).
    local slack = 0.25 * lever:Distance(gyro)
    local c1 = (lever + gyro) * 0.5 - up * slack
    -- Along the top tube, bowed a little up and out of the frame's way.
    local c2 = (gyro + brake) * 0.5 + up * (1.2 * k)

    return {
        lever = lever, gyro = gyro, brake = brake,
        bar   = bezier(lever, c1, gyro, segments),
        frame = bezier(gyro, c2, brake, segments),
    }
end

-- Three short lines: a part's own forward (red), right (green) and up (blue).
-- bmx_debug 2: a mis-weighted or mis-parented part has the wrong axes, and that
-- is visible in one screenshot.
local function axes(pos, f, r, u, len)
    render.DrawLine(pos, pos + f * len, Color(255, 60, 60), true)
    render.DrawLine(pos, pos + r * len, Color(60, 255, 60), true)
    render.DrawLine(pos, pos + u * len, Color(80, 120, 255), true)
end

--------------------------------------------------------------------------
-- LEVEL OF DETAIL. A bike is ~55 model draws and 2 ground traces a frame,
-- every frame, at any distance -- eight riders in view is ~440 draws for
-- bikes that past a street's width are a few pixels across. So by distance
-- from the eye:
--
--   0  near   everything
--   1  mid    the chainring in 6 pieces not 16; no joint balls, no chain,
--             no pedal blocks or spindle: all under a few pixels there
--   2  far    frame, fork, bars, saddle and tyres; the wheels drawn where
--             they sit at rest instead of traced to the ground (the two
--             traces are most of what a far bike costs)
--
-- bmx_lod_scale stretches both distances (2 = twice as far); 0 turns LOD
-- off. The rider's hand and foot targets are worked out at every level:
-- only what is DRAWN changes, never where the rider's limbs go.
--------------------------------------------------------------------------
local LOD_MID, LOD_FAR = 900, 2500
local lodScale = CreateClientConVar("bmx_lod_scale", "1", true, false,
    "BMX bike detail by distance: 1 normal, 2 = full detail twice as far, 0 = always full.")

function BMX.BikeLOD(ent)
    local k = lodScale:GetFloat()
    if k <= 0 then return 0 end
    local d = EyePos():Distance(ent:GetPos())
    if d > LOD_FAR * k then return 2 end
    if d > LOD_MID * k then return 1 end
    return 0
end

local CRANK   = 6.8     -- 170 mm cranks
local Q       = 3.4     -- half the distance between the pedals
local RING    = 3.8     -- chainring radius
local COG     = 1.3     -- rear cog radius
local CHAINY  = -2.3    -- the drive side is the RIGHT, which is -Y in Source

function ENT:Draw()
    drawing = self
    local bike = self:Bike()
    local C    = self:Cfg()
    local WC   = C.Wheel
    local half = WC.wheelbase * 0.5
    local dt   = FrameTime()
    local debug = GetConVar("bmx_debug") and GetConVar("bmx_debug"):GetInt() > 0
    local lod = debug and 0 or BMX.BikeLOD(self)
    local debug2 = GetConVar("bmx_debug") and GetConVar("bmx_debug"):GetInt() >= 2

    ----------------------------------------------------------------------
    -- A bike that ships a real model draws it, through a pushed matrix so
    -- the physics origin stays on the axle line while the model sits
    -- wherever it looks right. The stock bike ships none and is drawn below.
    ----------------------------------------------------------------------
    if bike.hasModel then
        local m = Matrix()
        m:SetTranslation(self:LocalToWorld(bike.frameOffset))
        m:SetAngles(self:LocalToWorldAngles(bike.frameAngles))
        m:Scale(Vector(bike.scale, bike.scale, bike.scale))

        cam.PushModelMatrix(m)
            self:DrawModel()
        cam.PopModelMatrix()
    end

    ----------------------------------------------------------------------
    -- Wheels
    ----------------------------------------------------------------------

    local fwd       = self:GetForward()
    local up        = self:GetUp()
    local right     = self:GetRight()

    ----------------------------------------------------------------------
    -- THE TRICKS, as networked (sv_tricks.lua): how far the frame and the
    -- bars are round their turn, and which pose the rider holds. The angles
    -- arrive a byte at a time, so they are FOLLOWED rather than shown; the
    -- pose weights blend over BMX.PoseBlendTime (cl_rider.lua).
    ----------------------------------------------------------------------
    local whipA, barA, poseId = BMX.UnpackTrickBits(self:GetTrickBits())
    self.drawWhip = approachAngle(self.drawWhip or whipA, whipA, TRICK_FOLLOW, dt)
    self.drawBar  = approachAngle(self.drawBar  or barA,  barA,  TRICK_FOLLOW, dt)
    local whipAng, barAng = self.drawWhip, self.drawBar
    local W = BMX.UpdatePoseWeights(self, BMX.PoseNames[poseId], dt)
    local bodyRoll, barsTurn, barsSpin = BMX.PoseDrawAngles(W)

    -- Tabletop: the whole bike laid over about its own long axis. Everything
    -- below is then built from the laid-over up and right.
    local bodyAng = self:GetAngles()
    if bodyRoll ~= 0 then
        right = rotVec(right, fwd, bodyRoll)
        up    = rotVec(up,    fwd, bodyRoll)
        bodyAng = fwd:AngleEx(up)
    end
    local rearAxle  = right
    local frontAxle = right

    -- Steer is networked because it is an OUTPUT of the balance controller: it
    -- is derived from the lean that actually happened, so the client has no way
    -- to work it out from anything it already holds.
    local steer = BMX.VisualSteer(self:GetSteer(), self:GetSpeedUPS(), C)
    local steeredFwd = fwd
    if steer ~= 0 then
        local c, s = math.cos(steer), math.sin(steer)
        steeredFwd = fwd * c + right * s
        frontAxle = steeredFwd:Cross(up)
        frontAxle:Normalize()
    end

    render.SetColorMaterial()

    -- The SUSPENSION MOUNTS, exactly as ENT:Initialize places them: restLength
    -- above the axle line. axlePos slides the axle down the strut from there.
    local lift = WC.restLength
    local fPos, fHit, rPos, rHit
    if lod >= 2 then
        -- Far: where the wheels sit at rest (the axle line lifted by the
        -- static sag), and grounded as the server says, with no traces.
        local g = physenv.GetGravity():Length()
        local sag = math.Clamp(C.Chassis.mass * g * 0.5 / WC.spring, 0, WC.restLength)
        fPos = self:LocalToWorld(Vector( half, 0, sag))
        rPos = self:LocalToWorld(Vector(-half, 0, sag))
        fHit = self:GetGrounded()
        rHit = fHit
    else
        fPos, fHit = axlePos(self, Vector( half, 0, lift))
        rPos, rHit = axlePos(self, Vector(-half, 0, lift))
    end

    local fallen = math.abs((BMX.Attitude(self, vector_up))) > C.Stand.maxRoll
    local fSpin = self:WheelSpin("front", fHit, fallen, dt)
    local rSpin = self:WheelSpin("rear",  rHit, fallen, dt)

    ----------------------------------------------------------------------
    -- The frame's own measures, up here because the tricks move parts about
    -- the steer axis (the head tube), and the wheels hang off those parts.
    -- Chassis points sit on the axle line the bike RIDES at, which is the
    -- design line lifted by the static sag, so an unladen frame lines up with
    -- wheels at their resting compression.
    ----------------------------------------------------------------------
    local k   = WC.wheelbase / 39
    local g   = physenv.GetGravity():Length()
    local sag = math.Clamp(C.Chassis.mass * g * 0.5 / WC.spring, 0, WC.restLength)
    local lift0 = Vector(0, 0, sag)
    local bodyC = self:LocalToWorld(Vector(0, 0, 10 * k))
    local function P(v)
        local p = self:LocalToWorld(v * k + lift0)
        return bodyRoll ~= 0 and rotAbout(p, bodyC, fwd, bodyRoll) or p
    end
    if bodyRoll ~= 0 then
        fPos = rotAbout(fPos, bodyC, fwd, bodyRoll)
        rPos = rotAbout(rPos, bodyC, fwd, bodyRoll)
    end

    local headT, headB = P(FRAME.headT), P(FRAME.headB)
    local steerAxis = (headT - headB):GetNormalized()
    -- The frame group (rear wheel, stays, cranks, seat) turns by the whip,
    -- the front end (fork, front wheel, bars) by the barspin.
    local function Wh(p) return rotAbout(p, headB, steerAxis, whipAng) end
    local function Wv(v) return rotVec(v, steerAxis, whipAng) end
    local function Bs(p) return rotAbout(p, headB, steerAxis, barAng) end
    local function Bv(v) return rotVec(v, steerAxis, barAng) end

    local rPosD, rearAxleD = Wh(rPos), Wv(rearAxle)
    local fPosD, frontAxleD = Bs(fPos), Bv(frontAxle)

    if not bike.wheelModel then
        drawWheel(self, "front", fPosD, frontAxleD, fSpin, WC.radius, fHit, debug, lod)
        drawWheel(self, "rear",  rPosD, rearAxleD,  rSpin, WC.radius, rHit, debug, lod)
    end

    -- A model's own bones (the `bones` table in its registry entry), axes drawn
    -- at each, when bmx_debug is 2.
    if debug2 and bike.bones then
        for _, name in pairs(bike.bones) do
            local i = self:LookupBone(name)
            local bp, ba = nil, nil
            if i then bp, ba = self:GetBonePosition(i) end
            if bp then axes(bp, ba:Forward(), ba:Right(), ba:Up(), 5) end
        end
    end

    if bike.hasModel then return end

    -- The paint: this bike's palette colour (sh_color.lua), networked.
    local col = BMX.PaletteColor(self:GetColorIndex())
    local bb0 = P(FRAME.bb)         -- where the bottom bracket is, whip or not
    local bb, seatJ, seat = Wh(bb0), Wh(P(FRAME.seatJ)), Wh(P(FRAME.seat))
    local fwdW, upW, rightW = Wv(fwd), Wv(up), Wv(right)
    local whipAngles = whipAng ~= 0 and fwdW:AngleEx(upW) or bodyAng

    tube(seatJ, headT, 1.5 * k, col)            -- top tube
    tube(headB, bb, 1.7 * k, col)               -- down tube
    tube(bb, seatJ, 1.5 * k, col)               -- seat tube
    tube(headT, headB, 1.9 * k, col)            -- head tube
    for _, side in ipairs({ 1, -1 }) do
        local off = rightW * (1.6 * k * side)
        tube(bb + off, rPosD + off, 0.95 * k, col)      -- chain stays
        tube(seatJ + off, rPosD + off, 0.95 * k, col)   -- seat stays
        if lod == 0 then joint(rPosD + off, 1.3 * k, col) end  -- dropouts
    end
    -- Where the tubes meet: round, not a notch.
    if lod == 0 then
        joint(bb, 2.4 * k, col)
        joint(seatJ, 1.9 * k, col)
        joint(headT, 2.1 * k, col)
        joint(headB, 2.1 * k, col)
    end

    -- Seat post and seat: a padded saddle, not a brick.
    tube(seatJ, seat, 1.0 * k, COL_CHROME)
    solid("sph", seat + upW * (0.8 * k) - fwdW * (0.5 * k), whipAngles,
        Vector(9.5, 4.0, 2.0) * k, COL_PART, MAT.matte)

    ----------------------------------------------------------------------
    -- Fork, stem and bars. The fork runs from the head tube to the front
    -- axle where it really is, so it steers and compresses with the wheel.
    ----------------------------------------------------------------------
    for _, side in ipairs({ 1, -1 }) do
        local off = frontAxleD * (1.7 * k * side)
        tube(headB + off, fPosD + off, 1.0 * k, COL_PART)
    end
    tube(headB - frontAxleD * (1.9 * k), headB + frontAxleD * (1.9 * k), 1.2 * k, COL_PART)

    -- The bars turn about the head tube with the steer angle: the bar centre's
    -- offset from the head tube is re-expressed along the STEERED forward.
    -- Then the tricks: a barspin turns them about the steer axis, an X-up
    -- half a turn more, and a turndown folds them forward about the stem.
    local d = P(FRAME.bars) - headT
    local barsC0 = headT + steeredFwd * d:Dot(fwd) + up * d:Dot(up)
    local stemTop0 = headT + up * (3 * k)
    local function barsAt(spin, turn)
        local stem = rotAbout(stemTop0, headB, steerAxis, spin)
        local function R(p)
            p = rotAbout(p, headB, steerAxis, spin)
            return rotAbout(p, stem, frontAxle, turn)
        end
        return R(stemTop0), R(barsC0), R(barsC0 - frontAxle * (11 * k)),
            R(barsC0 + frontAxle * (11 * k)), R(barsC0 - frontAxle * (14.5 * k)),
            R(barsC0 + frontAxle * (14.5 * k))
    end
    local stemTop, barsC, barL, barR, gripL, gripR = barsAt(barAng + barsSpin, barsTurn)
    -- The same bars as BMX.SteeredBars would give, spun and turned: the brake
    -- cable's lever end follows them, its frame end does not.
    local barAxle = (barR - barL):GetNormalized()
    local bars = {
        barsC = barsC, stemTop = stemTop, barL = barL, barR = barR,
        axle = barAxle,
        fwd = up:Cross(barAxle):GetNormalized(),
    }
    tube(headT, stemTop, 1.4 * k, COL_PART)
    tube(stemTop, barsC, 1.0 * k, COL_PART)         -- the rise of the bar
    tube(barL, barR, 0.95 * k, COL_PART)
    tube(barL, gripL, 1.5 * k, COL_TYRE)            -- grips
    tube(barR, gripR, 1.5 * k, COL_TYRE)

    -- The brake cable, from the right lever through the gyro to the rear brake
    -- (BMX.BrakeCable). Not at the far LOD, where it is under a pixel wide.
    if lod < 2 then
        local brake = seatJ + (rPos - seatJ) * 0.8
        local cab = BMX.BrakeCable(bars, headT, up, brake, k, lod == 0 and 5 or 2)
        for _, line in ipairs({ cab.bar, cab.frame }) do
            for i = 1, #line - 1 do tube(line[i], line[i + 1], 0.35 * k, COL_PART) end
        end
        tube(barR, cab.lever, 0.5 * k, COL_CHROME)         -- the brake lever
        if lod == 0 then joint(cab.gyro, 1.8 * k, COL_CHROME) end   -- the detangler
    end

    -- bmx_debug 2: each moving part's own axes.
    if debug2 then
        axes(headT, steeredFwd, frontAxle, up, 5 * k)          -- fork and bars
        axes(fPos, steeredFwd, frontAxle, up, 5 * k)           -- front wheel
        axes(rPos, fwd, right, up, 5 * k)                      -- rear wheel
        axes(bb, fwd, right, up, 5 * k)                        -- cranks
    end

    -- Where the rider's hands and feet belong, for the IK in cl_rider.lua.
    -- Recorded every frame the bike is drawn: the rider is drawn in the same
    -- frame, at worst one frame behind.
    -- A hand holds a grip ANYWHERE along it: rHandA..rHandB is the grip's
    -- length, and the IK takes the point nearest the shoulder (a stretched
    -- rider slides in toward the stem). rHand is the middle, for everything
    -- that just wants "the grip".
    -- THE HANDS HOLD THE BARS AS THE POSE TURNS THEM (an X-up crosses the
    -- arms, a turndown pushes them forward) but NOT as a barspin does: the
    -- targets come from the bars without the spin, so the hands let go while
    -- the bars go round, and catch them when they are back.
    local _, _, hbL, hbR, hgL, hgR = barsAt(barsSpin, barsTurn)
    local gripDirR, gripDirL = (hgR - hbR):GetNormalized(), (hgL - hbL):GetNormalized()
    local ik = { rHand = hbR + gripDirR * (1.75 * k), lHand = hbL + gripDirL * (1.75 * k),
                 rHandA = hbR, rHandB = hgR,
                 lHandA = hbL, lHandB = hgL }
    self.ikTargets = ik

    ----------------------------------------------------------------------
    -- Drivetrain. The cranks turn at the networked cadence, so pedalling is
    -- visible, and coasting (the freewheel ticking) shows them still.
    ----------------------------------------------------------------------
    -- THE CRANKS TURN WITH THE REAR WHEEL, through the gearing: wheel still,
    -- pedals still; rolling forward (or back), pedals forward (or back). They
    -- used to follow the rider's networked cadence, which was only loosely the
    -- same thing and read as pedals with a mind of their own.
    self.crankAngle = rSpin / C.Drive.gearRatio

    local cr = rightW * (-CHAINY * k)            -- -Y local is +right world
    local ringC = bb + cr
    if lod < 2 then ring(ringC, fwdW, upW, RING * k, 0.6 * k, COL_CHROME, lod == 0 and 16 or 6) end
    local cogC = rPosD + cr
    if lod == 0 then
        tube(ringC + upW * (RING * k), cogC + upW * (COG * k), 0.45 * k, COL_PART)   -- chain, top
        tube(ringC - upW * (RING * k), cogC - upW * (COG * k), 0.45 * k, COL_PART)   -- chain, bottom
    end

    for _, side in ipairs({ 1, -1 }) do
        local t = self.crankAngle + (side == 1 and 0 or math.pi)
        local arm = (fwdW * math.cos(t) - upW * math.sin(t)) * (CRANK * k)
        local root = bb + rightW * (Q * k * side)
        local pedal = root + arm
        -- THE FEET STAY WHERE THE PEDALS WERE. In a tailwhip the cranks go
        -- round with the frame and the rider's feet do not: they leave the
        -- pedals and meet them again at the top of the turn.
        local arm0 = (fwd * math.cos(t) - up * math.sin(t)) * (CRANK * k)
        local pedal0 = bb0 + right * (Q * k * side) + arm0
        ik[side == 1 and "rFoot" or "lFoot"] = pedal0 + right * (1.8 * k * side) + up * (0.9 * k)
        if lod < 2 then tube(root, pedal, 0.9 * k, COL_PART) end
        -- Matte: pedals are grippy plastic and pins, not polished metal.
        if lod == 0 then
            solid("box", pedal + rightW * (1.8 * k * side), whipAngles,
                Vector(3.6, 3.6, 1.0) * k, COL_PART, MAT.matte)
        end
    end
    if lod == 0 then
        tube(bb - rightW * (Q * k), bb + rightW * (Q * k), 1.3 * k, COL_PART)     -- spindle
    end

    -- Style poses move the hands and feet off the bike's own points (an
    -- IK target each, blended in and out: cl_rider.lua).
    BMX.ApplyPoseTargets(ik, W, function(v)
        local p = self:LocalToWorld(v * k + lift0)
        return bodyRoll ~= 0 and rotAbout(p, bodyC, fwd, bodyRoll) or p
    end)

    ----------------------------------------------------------------------
    -- Kickstand, when it is DOWN (networked: put down by a rider stopping, or
    -- a bike spawned parked). Drawn from the bottom bracket to the ground on
    -- the LEFT, the side a parked bike leans on (Stand.standLean).
    ----------------------------------------------------------------------
    if self:GetStandDown() then
        local from = bb - rightW * (2 * k)
        local want = from - upW * (16 * k) - rightW * (7 * k)
        local to = want
        if lod < 2 then
            local tr = util.TraceLine({ start = from, endpos = want,
                filter = { self, self:GetPod() }, mask = MASK_SOLID })
            if tr.Hit then to = tr.HitPos end
        end
        tube(from, to, 0.8 * k, COL_PART)
    end
end

-- The tyre models are clientside and belong to nobody else: remove them with
-- the bike, or every bike ever spawned leaves two behind until the map changes.
function ENT:OnRemove()
    for _, set in ipairs({ self.tyres or {}, self.prims or {} }) do
        for _, m in pairs(set) do
            if m and IsValid(m) then m:Remove() end
        end
    end
    self.tyres, self.prims = nil, nil
end
