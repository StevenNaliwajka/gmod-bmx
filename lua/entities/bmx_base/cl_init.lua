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
local COL_FRAME  = Color(205, 35, 45)      -- a bike def can set frameColor

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
-- Drawing primitives. Everything is a camera-facing beam or a box in the colour
-- material: no textures, no models, nothing that is not in base Garry's Mod.
--------------------------------------------------------------------------
local function tube(a, b, width, col)
    render.DrawBeam(a, b, width, 0, 1, col)
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
local function drawWheel(ent, key, center, axleDir, spin, radius, grounded, debug)
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
    bb     = Vector(-4.5, 0,  1.5),    -- bottom bracket
    seatJ  = Vector(-9.5, 0, 14.0),    -- where the top tube meets the seat tube
    seat   = Vector(-10.5, 0, 18.5),   -- top of the seat post
    headT  = Vector(12.5, 0, 17.5),    -- head tube, top
    headB  = Vector(14.5, 0, 10.5),    -- head tube, bottom
    bars   = Vector(10.5, 0, 26.0),    -- bar centre (BMX bars are tall and swept back)
}
local CRANK   = 6.8     -- 170 mm cranks
local Q       = 3.4     -- half the distance between the pedals
local RING    = 3.8     -- chainring radius
local COG     = 1.3     -- rear cog radius
local CHAINY  = -2.3    -- the drive side is the RIGHT, which is -Y in Source

function ENT:Draw()
    local bike = self:Bike()
    local C    = self:Cfg()
    local WC   = C.Wheel
    local half = WC.wheelbase * 0.5
    local dt   = FrameTime()
    local debug = GetConVar("bmx_debug") and GetConVar("bmx_debug"):GetInt() > 0

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
    local fPos, fHit = axlePos(self, Vector( half, 0, lift))
    local rPos, rHit = axlePos(self, Vector(-half, 0, lift))

    local fallen = math.abs((BMX.Attitude(self, vector_up))) > C.Stand.maxRoll
    local fSpin = self:WheelSpin("front", fHit, fallen, dt)
    local rSpin = self:WheelSpin("rear",  rHit, fallen, dt)

    if not bike.wheelModel then
        drawWheel(self, "front", fPos, frontAxle, fSpin, WC.radius, fHit, debug)
        drawWheel(self, "rear",  rPos, rearAxle,  rSpin, WC.radius, rHit, debug)
    end

    if bike.hasModel then return end

    ----------------------------------------------------------------------
    -- The frame. Chassis points sit on the axle line the bike RIDES at, which
    -- is the design line lifted by the static sag, so an unladen frame lines
    -- up with wheels at their resting compression.
    ----------------------------------------------------------------------
    local k   = WC.wheelbase / 39
    local g   = physenv.GetGravity():Length()
    local sag = math.Clamp(C.Chassis.mass * g * 0.5 / WC.spring, 0, WC.restLength)
    local lift0 = Vector(0, 0, sag)
    local function P(v) return self:LocalToWorld(v * k + lift0) end

    local col = bike.frameColor or COL_FRAME
    local bb, seatJ, seat = P(FRAME.bb), P(FRAME.seatJ), P(FRAME.seat)
    local headT, headB = P(FRAME.headT), P(FRAME.headB)

    tube(seatJ, headT, 1.5 * k, col)            -- top tube
    tube(headB, bb, 1.7 * k, col)               -- down tube
    tube(bb, seatJ, 1.5 * k, col)               -- seat tube
    tube(headT, headB, 1.9 * k, col)            -- head tube
    for _, side in ipairs({ 1, -1 }) do
        local off = right * (1.6 * k * side)
        tube(bb + off, rPos + off, 0.95 * k, col)       -- chain stays
        tube(seatJ + off, rPos + off, 0.95 * k, col)    -- seat stays
    end

    -- Seat post and seat.
    tube(seatJ, seat, 1.0 * k, COL_CHROME)
    render.DrawBox(seat + up * (0.8 * k), self:GetAngles(),
        Vector(-5, -1.9, -0.8) * k, Vector(4, 1.9, 0.8) * k, COL_PART)

    ----------------------------------------------------------------------
    -- Fork, stem and bars. The fork runs from the head tube to the front
    -- axle where it really is, so it steers and compresses with the wheel.
    ----------------------------------------------------------------------
    for _, side in ipairs({ 1, -1 }) do
        local off = frontAxle * (1.7 * k * side)
        tube(headB + off, fPos + off, 1.0 * k, COL_PART)
    end
    tube(headB - frontAxle * (1.9 * k), headB + frontAxle * (1.9 * k), 1.2 * k, COL_PART)

    -- The bars turn about the head tube with the steer angle: the bar centre's
    -- offset from the head tube is re-expressed along the STEERED forward.
    local d = P(FRAME.bars) - headT
    local barsC = headT + steeredFwd * d:Dot(fwd) + up * d:Dot(up)
    local stemTop = headT + up * (3 * k)
    tube(headT, stemTop, 1.4 * k, COL_PART)
    local barL = barsC - frontAxle * (11 * k)
    local barR = barsC + frontAxle * (11 * k)
    tube(stemTop, barsC, 1.0 * k, COL_PART)         -- the rise of the bar
    tube(barL, barR, 0.95 * k, COL_PART)
    tube(barL, barL - frontAxle * (3.5 * k), 1.5 * k, COL_TYRE)    -- grips
    tube(barR, barR + frontAxle * (3.5 * k), 1.5 * k, COL_TYRE)

    -- Where the rider's hands and feet belong, for the IK in cl_rider.lua.
    -- Recorded every frame the bike is drawn: the rider is drawn in the same
    -- frame, at worst one frame behind.
    local ik = { rHand = barR + frontAxle * (1.75 * k), lHand = barL - frontAxle * (1.75 * k) }
    self.ikTargets = ik

    ----------------------------------------------------------------------
    -- Drivetrain. The cranks turn at the networked cadence, so pedalling is
    -- visible, and coasting (the freewheel ticking) shows them still.
    ----------------------------------------------------------------------
    self.crankAngle = (self.crankAngle or 0) + self:GetCadence() * dt

    local cr = right * (-CHAINY * k)             -- -Y local is +right world
    local ringC = bb + cr
    ring(ringC, fwd, up, RING * k, 0.6 * k, COL_CHROME, 16)
    local cogC = rPos + cr
    tube(ringC + up * (RING * k), cogC + up * (COG * k), 0.45 * k, COL_PART)   -- chain, top
    tube(ringC - up * (RING * k), cogC - up * (COG * k), 0.45 * k, COL_PART)   -- chain, bottom

    for _, side in ipairs({ 1, -1 }) do
        local t = self.crankAngle + (side == 1 and 0 or math.pi)
        local arm = (fwd * math.cos(t) - up * math.sin(t)) * (CRANK * k)
        local root = bb + right * (Q * k * side)
        local pedal = root + arm
        ik[side == 1 and "rFoot" or "lFoot"] = pedal + right * (1.8 * k * side) + up * (0.9 * k)
        tube(root, pedal, 0.9 * k, COL_PART)
        render.DrawBox(pedal + right * (1.8 * k * side), self:GetAngles(),
            Vector(-1.8, -1.8, -0.5) * k, Vector(1.8, 1.8, 0.5) * k, COL_PART)
    end
    tube(bb - right * (Q * k), bb + right * (Q * k), 1.3 * k, COL_PART)     -- spindle

    ----------------------------------------------------------------------
    -- Kickstand, when parked. Drawn from the bottom bracket to the ground on
    -- the LEFT, which is the side the parked bike leans on (Stand.standLean).
    ----------------------------------------------------------------------
    if not IsValid(self:GetDriver()) and self:GetSpeedUPS() < 20 then
        local from = bb - right * (2 * k)
        local want = from - up * (16 * k) - right * (7 * k)
        local tr = util.TraceLine({ start = from, endpos = want,
            filter = { self, self:GetPod() }, mask = MASK_SOLID })
        tube(from, tr.Hit and tr.HitPos or want, 0.8 * k, COL_PART)
    end
end

-- The tyre models are clientside and belong to nobody else: remove them with
-- the bike, or every bike ever spawned leaves two behind until the map changes.
function ENT:OnRemove()
    for _, m in pairs(self.tyres or {}) do
        if m and IsValid(m) then m:Remove() end
    end
    self.tyres = nil
end
