--[[--------------------------------------------------------------------------
    bmx/sh_util.lua

    Small shared helpers. The important one is BMX.ApplyTorque.
----------------------------------------------------------------------------]]

BMX = BMX or {}

local sqrt, abs, min, max = math.sqrt, math.abs, math.min, math.max

--------------------------------------------------------------------------
-- Maths
--------------------------------------------------------------------------

function BMX.Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Linear ramp from 0 at `lo` to 1 at `hi`, clamped both ends.
function BMX.Ramp(v, lo, hi)
    if hi <= lo then return v >= hi and 1 or 0 end
    return BMX.Clamp((v - lo) / (hi - lo), 0, 1)
end

-- Component of `v` perpendicular to unit vector `n`, normalised. Returns nil if
-- `v` is (near) parallel to `n`, which callers must handle: this happens for
-- real (a bike pointing straight down a wall) and silently normalising a zero
-- vector is how you get NaNs in a physics object that can never be recovered.
function BMX.ProjectPerp(v, n)
    local p = v - n * v:Dot(n)
    local l = p:Length()
    if l < 1e-4 then return nil end
    return p / l
end

-- Signed angle in radians of `from` -> `to` about unit axis `axis`.
function BMX.SignedAngle(from, to, axis)
    local c = BMX.Clamp(from:Dot(to), -1, 1)
    local a = math.acos(c)
    if from:Cross(to):Dot(axis) < 0 then a = -a end
    return a
end

--------------------------------------------------------------------------
-- Attitude
--
-- Roll and pitch of an entity relative to a reference "up" (the ground normal
-- while riding, world up in the air).
--
-- Measuring roll against the GROUND NORMAL rather than against world up is what
-- lets a rider ride a banked wall or a quarter-pipe transition without the
-- balance controller fighting to stand them vertical and throwing them off.
--
-- Shared, not server-only: the chase camera leans with the bike and needs the
-- same number the balance controller is working from.
--
-- Sign conventions, verified against Source's right-handed X-forward, Y-left,
-- Z-up frame:
--     roll  > 0   leaning RIGHT
--     pitch > 0   nose UP
--------------------------------------------------------------------------
function BMX.Attitude(ent, groundNormal)
    local ref = groundNormal or vector_up
    local fwd = ent:GetForward()
    local up  = ent:GetUp()

    local refP = BMX.ProjectPerp(ref, fwd)
    local upP  = BMX.ProjectPerp(up,  fwd)

    local roll = 0
    if refP and upP then
        roll = BMX.SignedAngle(refP, upP, fwd)
    end

    return roll, math.asin(BMX.Clamp(fwd:Dot(ref), -1, 1))
end

--------------------------------------------------------------------------
-- Physics
--------------------------------------------------------------------------

-- Apply a pure torque about a WORLD-SPACE axis.
--
-- PhysObj:ApplyTorqueCenter takes an Angle whose component-to-axis mapping is a
-- long-standing source of confusion (and differs from the Angle you would write
-- by hand), so this deliberately does not use it. Instead it applies a
-- force-couple: two equal and opposite forces at +/- a lever arm perpendicular
-- to the axis. The linear components cancel exactly, leaving torque = 2*r*F
-- about `axis` and nothing else. Slightly more expensive, completely
-- unambiguous, and it can be reasoned about on paper when the bike misbehaves.
--
--   axis    unit vector, world space
--   torque  kg*units^2/s^2
--   dt      seconds (forces are applied as impulses, so everything scales by dt)
local LEVER = 20   -- units; arbitrary, cancels out of the result

function BMX.ApplyTorque(phys, ent, axis, torque, dt)
    if torque == 0 then return end

    -- Any vector perpendicular to the axis will do as the lever direction.
    local perp = BMX.ProjectPerp(ent:GetForward(), axis)
              or BMX.ProjectPerp(ent:GetUp(), axis)
              or BMX.ProjectPerp(ent:GetRight(), axis)
    if not perp then return end

    local force = axis:Cross(perp) * (torque / (2 * LEVER) * dt)
    local com   = phys:LocalToWorld(phys:GetMassCenter())

    phys:ApplyForceOffset( force, com + perp * LEVER)
    phys:ApplyForceOffset(-force, com - perp * LEVER)
end

-- Angular acceleration -> torque, for a given axis's moment of inertia.
function BMX.TorqueFor(inertia, alpha)
    return inertia * alpha
end

-- True if a number is finite. Every value that reaches a PhysObj goes through
-- this: one NaN entering VPhysics corrupts the object permanently, and the
-- symptom (a bike that vanishes, or an entire map's physics going still) looks
-- nothing like its cause.
function BMX.Finite(n)
    return n == n and n ~= math.huge and n ~= -math.huge
end

function BMX.FiniteVec(v)
    return BMX.Finite(v.x) and BMX.Finite(v.y) and BMX.Finite(v.z)
end

--------------------------------------------------------------------------
-- Speed formatting, shared by the HUD and the debug overlay
--------------------------------------------------------------------------

-- Source units/s -> km/h. 1 unit = 1 inch = 0.0254 m.
function BMX.ToKMH(ups)
    return ups * 0.0254 * 3.6
end

function BMX.ToMPH(ups)
    return ups * 0.0254 * 2.23694
end
