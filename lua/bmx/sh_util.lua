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
-- Where a wheel touches the ground: the geometry of a DISC, not of a ray.
--
-- The suspension ray runs from the mount along the chassis's own down axis,
-- and the axle slides along that axis. The tyre, though, is a disc of radius r
-- in the wheel's plane, and it touches the ground at the disc's lowest point
-- toward the ground, which is NOT where the ray hits it once the bike pitches.
--
-- Treating the ray hit as the contact (which is what this replaced) is exact
-- when the bike is level and wrong in proportion to pitch: the contact slides
-- r*sin(pitch) behind the axle, so the rear spring, carrying most of the bike,
-- pushes up at a point behind where the tyre really is. At 35 degrees that is
-- ~6 units and ~290,000 of nose-up torque that no real bike has, about twice
-- the gravity torque the wheelie hold is balancing against. Wheelies were
-- being lifted past their balance point by the geometry.
--
-- ROLL is different, and the ray was right about it: a thin tyre leaning over
-- touches down IN its own plane, so the lateral offset under lean is real and
-- the balance feed-forward depends on it. The disc model reproduces that case
-- exactly and fixes only the in-plane one.
--
--   mount   world-space top of the strut
--   down    unit vector the strut runs along (chassis -up)
--   axle    unit vector along the wheel's axle (chassis right)
--   dist    distance from the mount to where the ray met the ground
--   normal  the ground's normal there
--   radius  wheel radius
--
-- Returns the axle's distance along `down` from the mount at which the disc
-- just touches the ground, and the contact point. Returns nil when the disc
-- cannot touch at all (the ground is edge-on to the wheel).
--------------------------------------------------------------------------
function BMX.DiscContact(mount, down, axle, dist, normal, radius)
    -- The ground's normal, projected into the wheel's plane: the direction
    -- from the contact to the axle.
    local inPlane = BMX.ProjectPerp(normal, axle)
    if not inPlane then return nil end

    local c = -down:Dot(normal)             -- cos of the strut's tilt
    local k = inPlane:Dot(normal)           -- cos of the wheel's lean
    if c < 0.2 or k <= 0 then return nil end

    -- Height of a point on the strut above the ground falls linearly with how
    -- far down the strut it is, reaching zero at `dist`. The disc touches when
    -- its centre is r*k above the ground.
    local s = dist - radius * k / c
    local centre = mount + down * s
    return s, centre - inPlane * radius
end

-- Where the entity origin sits above flat ground at rest: on the axle line,
-- which is one wheel radius up less the static sag. Spawning anywhere higher
-- is dropping the bike, and it bounced on its suspension every time it was
-- spawned: both spawn paths used to put it 16 units plus a radius up.
function BMX.RestHeight(cfg)
    local C = cfg or BMX.Config
    local g = physenv and physenv.GetGravity and physenv.GetGravity():Length() or 600
    local sag = C.Chassis.mass * g * 0.5 / C.Wheel.spring
    return C.Wheel.radius - math.min(sag, C.Wheel.restLength)
end

-- The collision shape: a body box and one slim box per wheel, as {min, max}
-- pairs in chassis space. See Chassis.wheelHullBottom.
--
-- VPhysics puts the mass centre at the volume centre of the shape it is
-- given, and there is no setter (see the note on hullMin). Adding wheel boxes
-- would drag it down and change every balance number derived from it, so the
-- BODY is moved to compensate: solved so the union's volume centre lands
-- exactly on massCenterExpected. Its size is unchanged, only where it sits.
function BMX.CollisionBoxes(cfg)
    local C  = cfg or BMX.Config
    local CH, W = C.Chassis, C.Wheel
    local half, r = W.wheelbase * 0.5, W.radius
    local hw = CH.wheelHullHalfWidth or 1.6
    -- The floor is where the suspension runs out of travel (see the config).
    local bot = CH.wheelHullBottom or -(W.radius - W.restLength)

    local wheels = {}
    for _, x in ipairs({ half, -half }) do
        wheels[#wheels + 1] = { Vector(x - r, -hw, bot), Vector(x + r, hw, r) }
    end
    -- The pegs (Chassis.pegHullHalfWidth): a box across each axle.
    if CH.pegHullHalfWidth then
        local pw = CH.pegHullHalfWidth
        for _, x in ipairs({ half, -half }) do
            wheels[#wheels + 1] = { Vector(x - 1.2, -pw, 0), Vector(x + 1.2, pw, 6) }
        end
    end
    -- The bars (Chassis.barHullCentre): counted with the wheels, since the
    -- body is shifted to balance whatever is added to it.
    if CH.barHullCentre then
        local k = W.wheelbase / 39
        local c, h = CH.barHullCentre * k, CH.barHullHalf * k
        wheels[#wheels + 1] = { c - h, c + h }
    end

    local function vol(b) local d = b[2] - b[1] return d.x * d.y * d.z end
    local function mid(b) return (b[1] + b[2]) * 0.5 end

    local size  = CH.hullMax - CH.hullMin
    local vBody = size.x * size.y * size.z
    local sumV, sumM = 0, Vector(0, 0, 0)
    for _, b in ipairs(wheels) do
        sumV = sumV + vol(b)
        sumM = sumM + mid(b) * vol(b)
    end
    local want = CH.massCenterExpected
    local bodyCentre = (want * (vBody + sumV) - sumM) / vBody

    local out = { { bodyCentre - size * 0.5, bodyCentre + size * 0.5 } }
    for _, b in ipairs(wheels) do out[#out + 1] = b end
    return out
end

-- The whole shape's bounding box, chassis space.
function BMX.CollisionBounds(cfg)
    local mn = Vector(math.huge, math.huge, math.huge)
    local mx = -mn
    for _, b in ipairs(BMX.CollisionBoxes(cfg)) do
        mn = Vector(math.min(mn.x, b[1].x), math.min(mn.y, b[1].y), math.min(mn.z, b[1].z))
        mx = Vector(math.max(mx.x, b[2].x), math.max(mx.y, b[2].y), math.max(mx.z, b[2].z))
    end
    return mn, mx
end

local function boxMesh(mn, mx)
    local v = {}
    for _, x in ipairs({ mn.x, mx.x }) do
        for _, y in ipairs({ mn.y, mx.y }) do
            for _, z in ipairs({ mn.z, mx.z }) do v[#v + 1] = Vector(x, y, z) end
        end
    end
    return v
end

-- The shape as PhysicsInitMultiConvex wants it: one vertex list per box.
function BMX.CollisionMeshes(cfg)
    local out = {}
    for _, b in ipairs(BMX.CollisionBoxes(cfg)) do out[#out + 1] = boxMesh(b[1], b[2]) end
    return out
end

-- The steer angle to DRAW. See Balance.visualSteerGain: the real angle,
-- turned up with speed so a leaning rider is seen to be steering.
function BMX.VisualSteer(steer, speed, cfg)
    local B = (cfg or BMX.Config).Balance
    local gain = 1 + ((B.visualSteerGain or 1) - 1)
        * BMX.Ramp(speed, B.walkSpeed, B.visualSteerFull or 250)
    -- Drawn no further than visualSteerMax: at the full 38 degrees the far
    -- grip swings beyond an arm's reach even with the rider twisting and
    -- leaning into it, and the hand came off the bar.
    local lim = B.visualSteerMax or B.maxSteer
    return BMX.Clamp(steer * gain, -lim, lim)
end

-- How far the suspension ray reaches. Past the strut's full extension plus one
-- radius, because a pitched disc sits r/cos(pitch) down the strut from the
-- ground rather than r: 1.6 radii covers ~51 degrees, beyond the wheelie hold's
-- give-up angle. Shared so the client's drawing traces exactly what the server
-- simulates.
function BMX.WheelReach(WC)
    return WC.restLength + WC.radius * 1.6
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

-- The wheelie balance point, radians: the nose-up angle at which the centre of
-- mass passes over the rear contact patch. Below it gravity resists the
-- wheelie; above it gravity DRIVES the wheelie and you are looping out whatever
-- you do next.
--
-- Derived rather than written down, because it is a consequence of two numbers
-- in the config that people move for unrelated reasons -- the mass centre and
-- the wheelbase. A hardcoded angle here would go quietly wrong the first time
-- someone adjusted the hull, and "quietly wrong" for this one means every
-- wheelie loops out.
--
-- With the shipped geometry (COM 17.5u ahead of the rear contact, 20u above it)
-- it is atan(17.5/20) = 41.2 degrees.
function BMX.WheelieBalance(cfg)
    local C = cfg or BMX.Config
    local ahead = C.Chassis.massCenterExpected.x + C.Wheel.wheelbase * 0.5
    return math.atan(ahead / C.Chassis.massCenterExpected.z)
end

-- Pitch inertia about an AXLE, kg*units^2: what a commanded angular
-- acceleration really costs while the bike balances on one wheel. A wheelie
-- pivots about the rear axle and a stoppie about the front one, so it is the
-- free-body pitch inertia plus m*d^2 with d from the mass centre to that axle
-- (parallel axis theorem).
--
-- One function for both ends because the wheelie hold and the stoppie hold
-- each used to work this out for themselves, and only one of them did: the
-- stoppie used the free-body figure, 7.3x too small. With the shipped geometry
-- the rear is 72,574 and the front 85,990.
function BMX.PivotInertia(ent, cfg, front)
    local C  = cfg or BMX.Config
    local mc = C.Chassis.massCenterExpected
    local half = C.Wheel.wheelbase * 0.5
    local dx = front and (half - mc.x) or (mc.x + half)
    local dz = mc.z
    return BMX.IPitch(ent) + C.Chassis.mass * (dx * dx + dz * dz)
end

-- VPhysics reports inertia in kg*METRES^2, while every force and length in this
-- addon is in kg*UNITS^2. 1 m = 39.37 units, so the conversion is 39.37^2.
--
-- This matters more than a unit note usually does. The controllers command an
-- angular ACCELERATION and convert it to torque with T = I*alpha, so if I is
-- wrong by a factor then every torque in the addon is wrong by that factor and
-- the bike rotates that much too fast. Measured on a live server before this
-- existed: the invented constants were ~2x the real inertia, which is why the
-- balance controller flipped the bike and a bunny hop accumulated 45 radians of
-- rotation in the air.
BMX.M2U2 = (1 / 0.0254) ^ 2      -- 1550.0

-- Real principal moments for an entity, in kg*units^2, as (roll, pitch, yaw).
-- Source's local axes are x = forward, y = left, z = up, so the components map
-- straight onto roll / pitch / yaw in that order.
--
-- Cached on the entity at spawn: GetInertia does not change unless the physics
-- object is rebuilt, and this is read several times per substep.
function BMX.CacheInertia(ent, phys, cfg)
    local i = phys:GetInertia()
    if not i or not BMX.FiniteVec(i) or i:Length() <= 0 then
        -- Fall back to the documented estimates rather than dividing by zero.
        local C = (cfg or BMX.Config).Chassis
        ent.I = Vector(C.inertiaRoll, C.inertiaPitch, C.inertiaYaw)
        return ent.I, false
    end
    ent.I = i * BMX.M2U2
    return ent.I, true
end

-- Accessors, with a fallback so a controller can never index a nil.
-- The fallbacks read the BIKE's config, not the base, so a heavier bike whose
-- GetInertia failed still falls back to its own estimates rather than the
-- stock bike's.
local function fallback(ent) return (ent.Cfg and ent:Cfg() or BMX.Config).Chassis end
function BMX.IRoll(ent)  return (ent.I and ent.I.x) or fallback(ent).inertiaRoll  end
function BMX.IPitch(ent) return (ent.I and ent.I.y) or fallback(ent).inertiaPitch end
function BMX.IYaw(ent)   return (ent.I and ent.I.z) or fallback(ent).inertiaYaw   end

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

--------------------------------------------------------------------------
-- The crank grind's contact (sv_grind.lua), entity-local; shared because the
-- client throws its sparks from the same point: the bottom of the chainring as
-- cl_init.lua draws it. The frame is drawn on the line it RIDES at, lifted by
-- the static sag above the design line, and scaled with the wheelbase.
--------------------------------------------------------------------------
function BMX.GrindCrankPoint(cfg)
    local C = cfg or BMX.Config
    local G = C.Grind
    local k = C.Wheel.wheelbase / 39
    local sag = C.Wheel.radius - BMX.RestHeight(C)
    return Vector(G.bb.x * k, 0, G.bb.z * k + sag - G.ring * k)
end

