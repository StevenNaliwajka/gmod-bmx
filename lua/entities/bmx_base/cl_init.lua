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

local SEGMENTS  = 20
local COL_TYRE  = Color(28, 28, 32)
local COL_SPOKE = Color(150, 155, 165)
local COL_FORK  = Color(120, 125, 135)
local COL_AIR   = Color(235, 90, 60)

function ENT:Initialize()
    self.spinAngle = 0
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
-- A wheel as a ring plus four spokes. The spokes carry the spin, which is what
-- makes speed legible at a glance.
--------------------------------------------------------------------------
local function drawWheel(center, axleDir, spin, radius, grounded)
    -- Any orthonormal basis spanning the wheel's plane. Angle():Up()/:Right()
    -- of the axle direction gives one for free.
    local a  = axleDir:Angle()
    local e1 = a:Up()
    local e2 = a:Right()

    local col = grounded and COL_TYRE or COL_AIR

    local prev
    for i = 0, SEGMENTS do
        local t = (i / SEGMENTS) * math.pi * 2
        local p = center + (e1 * math.cos(t) + e2 * math.sin(t)) * radius
        if prev then render.DrawLine(prev, p, col, false) end
        prev = p
    end

    for i = 0, 3 do
        local t = spin + (i / 4) * math.pi * 2
        local p = center + (e1 * math.cos(t) + e2 * math.sin(t)) * (radius - 1)
        render.DrawLine(center, p, COL_SPOKE, false)
    end
end

function ENT:Draw()
    local bike = self:Bike()
    local WC   = self:Cfg().Wheel
    local half = WC.wheelbase * 0.5

    ----------------------------------------------------------------------
    -- Frame. Drawn through a pushed matrix rather than by moving the entity,
    -- so the physics origin stays on the axle line where the simulation needs
    -- it while the model sits wherever it looks right.
    ----------------------------------------------------------------------
    local m = Matrix()
    m:SetTranslation(self:LocalToWorld(bike.frameOffset))
    m:SetAngles(self:LocalToWorldAngles(bike.frameAngles))
    m:Scale(Vector(bike.scale, bike.scale, bike.scale))

    cam.PushModelMatrix(m)
        self:DrawModel()
    cam.PopModelMatrix()

    ----------------------------------------------------------------------
    -- Wheels
    ----------------------------------------------------------------------
    local spin = self:VisualWheelSpin(FrameTime())

    local up        = self:GetUp()
    local rearAxle  = self:GetRight()
    local frontAxle = rearAxle

    -- Steer is networked because it is an OUTPUT of the balance controller: it
    -- is derived from the lean that actually happened, so the client has no way
    -- to work it out from anything it already holds.
    local steer = self:GetSteer()
    if steer ~= 0 then
        local c, s = math.cos(steer), math.sin(steer)
        local steered = self:GetForward() * c + rearAxle * s
        frontAxle = steered:Cross(up)
        frontAxle:Normalize()
    end

    render.SetColorMaterial()

    -- The SUSPENSION MOUNTS, exactly as ENT:Initialize places them: restLength
    -- above the axle line. axlePos slides the axle down the strut from there.
    local lift = WC.restLength
    local fPos, fHit = axlePos(self, Vector( half, 0, lift))
    local rPos, rHit = axlePos(self, Vector(-half, 0, lift))

    drawWheel(fPos, frontAxle, spin, WC.radius, fHit)
    drawWheel(rPos, rearAxle,  spin, WC.radius, rHit)

    ----------------------------------------------------------------------
    -- Fork and bars, so the steer angle is visible on placeholder geometry.
    -- Drops out for free once a bike ships a real forkModel.
    ----------------------------------------------------------------------
    if not bike.forkModel then
        local head = fPos + up * 26
        render.DrawLine(fPos, head, COL_FORK, false)
        render.DrawLine(head - frontAxle * 9, head + frontAxle * 9, COL_FORK, false)
    end
end
