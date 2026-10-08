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

--------------------------------------------------------------------------
-- THE DISC ON AN EDGE. BMX.DiscContact treats the ground the ray met as a
-- plane that goes on for ever, and pitched well over against it (riding off a
-- deck into a drop-in, a wheel at the top of a wedge) the disc's lowest point
-- on that plane lies past the plane's real edge: over the drop, where there is
-- nothing. The plane's "contact" there sat 33 u up the strut, the compression
-- went to full travel in one substep, and the bump stop kicked the wheel
-- (174,000 on a road bike's rear going over a quarter pipe's lip, real server).
--
-- What the disc meets there is the EDGE: the point `e` where the ground under
-- the ray ends. This is the strut position at which a disc of `radius`, in the
-- wheel's plane, just touches that point, the point, and the normal at it (from
-- the edge to the axle). nil if the edge is out of the disc's reach.
--------------------------------------------------------------------------
function BMX.EdgeDiscContact(mount, down, axle, e, radius)
    local d = e - mount
    d = d - axle * d:Dot(axle)                     -- into the wheel's plane
    local along = d:Dot(down)
    local q = d - down * along                     -- off the strut line, in plane
    local h2 = q:LengthSqr()
    if h2 >= radius * radius then return nil end
    local s = along - math.sqrt(radius * radius - h2)
    local centre = mount + down * s
    local n = centre - e
    n = n - axle * n:Dot(axle)
    local len = n:Length()
    if len < 1e-6 then return nil end
    return s, e, n / len
end

--------------------------------------------------------------------------
-- THE SWEPT WHEEL: what the tyre touches IN FRONT of the axle.
--
-- BMX.DiscContact answers one question: where does the disc touch the ground
-- under the strut. A ray down the strut cannot see anything else. At the foot
-- of a 45 degree wedge it still hits flat ground while the front of the tyre
-- is already inside the ramp; against a curb it sees nothing until the axle is
-- over the edge, and by then the tyre has been pushing on the face for a
-- second with nothing to push back. That is luttje/gmod-bicycle's #5 and #16
-- (wheels sinking into steep ramps, getting stuck on a curb), and it is the
-- same missing contact in both.
--
-- So the tyre is probed with a FAN of rays from the axle in the wheel's own
-- plane, over the quadrant it rolls into (and a little behind), each as long as
-- the radius: a hit closer than the radius is the tyre inside something.
--
--   centre   the axle at the strut's full extension: the position from which
--            "inside the ground" means "the spring is compressed"
--   down     unit vector the strut runs along (chassis -up)
--   axle     unit vector along the wheel's axle (chassis right)
--   dir      +1 rolling forwards, -1 backwards: the fan points where it goes
--   degs     angles from straight down toward travel, degrees
--   trace    function(from, to) -> { Hit, HitPos, HitNormal, Fraction, ... }
--   best     accumulator from an earlier call, so a lite fan and the rest of
--            the fan can be fired separately and merged
--   ignore   a surface normal: hits within ~25 degrees of it are the surface
--            the strut ray already has (the floor under the wheel), and are
--            skipped, so the fan reports only what is DIFFERENT. Without it a
--            wheel resting on the floor, 3 units deep into it, always out-ranks
--            the first unit of a curb beside it.
--
-- It takes a trace FUNCTION rather than calling util.TraceLine, so the offline
-- suite can run it against a hand-built wedge and a step with no engine at all.
--
-- WHICH HIT. The deepest, ranked by how far inside the tyre it is along the
-- ray (r - h). The doc this was written from said "shallowest penetration",
-- and that cannot be right: resolving the shallowest of two overlaps leaves
-- the deeper one inside the geometry, which is the bug. A wheel at the foot of
-- a wedge is ON the floor (3 units deep) and a unit into the ramp; the one
-- that most needs pushing out is the one that is most inside.
--
-- Returns the best raw hit (or nil) and the number of rays fired. Hand it to
-- BMX.SweepResolve to turn it into a contact.
--------------------------------------------------------------------------
BMX.SWEEP_LITE  = { 35, 60, 85 }
BMX.SWEEP_EXTRA = { -40, -20, 20, 48, 72, 92 }
-- (Together: nine rays, 20 degrees or less apart over -40..92. LITE is what
-- fires alone when there is no floor to rule hits out against.)

function BMX.SweepContact(centre, down, axle, dir, radius, degs, trace, best, ignore)
    local fwd = axle:Cross(down)           -- Source: forward = right x down
    local rays = 0
    for _, deg in ipairs(degs) do
        local a = math.rad(deg) * dir
        local d = down * math.cos(a) + fwd * math.sin(a)
        local tr = trace(centre, centre + d * radius)
        rays = rays + 1
        if tr.Hit and not tr.StartSolid and tr.Fraction > 0 then
            local h = radius * tr.Fraction
            local dr = radius - h
            local same = ignore and tr.HitNormal:Dot(ignore) > 0.9
            if not same and (not best or dr > best.dr) then
                best = { dr = dr, h = h, d = d, n = tr.HitNormal, P = tr.HitPos }
            end
        end
    end
    return best, rays
end

-- cos of the angle between a ray and the surface normal it hit, above which
-- the hit is trusted as a plane without checking that the plane really extends
-- under the tyre: the ray is within ~18 degrees of the normal, so what it hit
-- is what the tyre would touch.
BMX.SWEEP_PLANE_COS = 0.95

--------------------------------------------------------------------------
-- Turn the best raw hit into the contact the tyre really has.
--
-- TWO KINDS, because a ray hit on its own cannot say which it is:
--
--   a PLANE (a floor, a wedge, a wall). The tyre's contact is the foot of the
--     perpendicular from the axle to the plane, wherever the ray happened to
--     land, and the depth is exact however oblique the ray was: the centre's
--     distance to the plane is h*cos(angle to the normal). The force acts
--     along the plane's normal.
--
--   an EDGE (a curb's top corner). The tyre touches the corner, the force acts
--     along the line from the corner to the axle -- which tilts UP as the
--     wheel comes over it, and that tilt is what lifts a wheel onto a step
--     -- and the depth is r minus the distance to the corner.
--
-- To tell them apart when the ray was oblique, a second ray is fired from the
-- axle along the plane's normal: if it finds the same plane at the distance
-- the first implied, the plane is real under the tyre; if it misses, the
-- "plane" was the side of a step whose top is below the axle, and the contact
-- is the corner. Perpendicular hits skip the check (SWEEP_PLANE_COS).
--
-- Returns { depth, normal, point, plane } or nil. `depth` is along `normal`
-- and is what the spring is compressed by.
--------------------------------------------------------------------------
function BMX.SweepResolve(centre, axle, radius, trace, hit)
    if not hit then return nil end
    local n = hit.n
    local inPlane = BMX.ProjectPerp(n, axle)
    local cc = -hit.d:Dot(n)

    local plane = false
    if inPlane and cc > 0.05 then
        if cc >= BMX.SWEEP_PLANE_COS then
            plane = true
        else
            local k = inPlane:Dot(n)
            local want = hit.h * cc / k            -- distance along -inPlane
            local tr = trace(centre, centre - inPlane * (radius * 1.25))
            if tr.Hit and not tr.StartSolid and tr.HitNormal:Dot(n) > 0.95 then
                local got = radius * 1.25 * tr.Fraction
                plane = math.abs(got - want) < 0.75
            end
        end
    end

    if plane then
        local k = inPlane:Dot(n)
        local depth = radius * k - hit.h * cc
        if depth <= 0 then return nil end
        -- The disc, pushed out by `depth`, touches at the end of the in-plane
        -- normal from the displaced axle.
        local touchCentre = centre + n * depth
        return { depth = depth, normal = n, point = touchCentre - inPlane * radius,
                 plane = true }
    end

    if hit.h < 1e-3 then return nil end
    local u = (centre - hit.P) / hit.h
    local depth = radius - hit.h
    if depth <= 0 then return nil end
    return { depth = depth, normal = u, point = hit.P, plane = false }
end

--------------------------------------------------------------------------
-- The whole probe, tiered by cost. This is what the wheel runs each substep
-- with bmx_wheel_sweep on, here rather than in sv_wheel.lua so the offline
-- suite runs the production decision and not a copy of it.
--
-- FLAT GROUND COSTS ONE EXTRA RAY. The first idea was three lite probes at
-- 35, 60 and 85 degrees, with the rest of the fan fired on any hit. It missed
-- exactly what it was for: a 4-unit curb's corner sits at 59 degrees when the
-- tyre first touches it, the 60 degree probe grazed past it onto the top, and
-- the first thing that saw the curb was a tyre already 4 units into it. A fan
-- has gaps and a corner lives in them.
--
-- So the lookout is a BUMPER: one ray along the travel direction, a unit above
-- the floor, from under the axle, a little longer than the tyre reaches. A
-- face rising from the floor ahead cannot hide from it, whatever its corner
-- does, and it fires before the tyre is in anything. The fan is for
-- RESOLVING the contact, not for finding the obstacle.
--
--   floorPoint, floorNormal   the strut ray's own contact, or nil if the wheel
--                             has no floor under it (then the fan fires at
--                             once: there is nothing to rule a hit out against)
--   hot                       a face was touched lately, or the floor is steep:
--                             skip the lookout and fan out
--
-- Returns the resolved contact or nil.
--------------------------------------------------------------------------
BMX.SWEEP_BUMPER_HEIGHT = 1
BMX.SWEEP_BUMPER_EXTRA  = 4

function BMX.SweepProbe(centre, down, axle, dir, radius, trace, floorPoint, floorNormal, hot)
    if floorNormal and not hot then
        local fwd = BMX.ProjectPerp(axle:Cross(down), floorNormal)
        if not fwd then return nil end
        local from = floorPoint + floorNormal * BMX.SWEEP_BUMPER_HEIGHT
        local tr = trace(from, from + fwd * (dir * (radius + BMX.SWEEP_BUMPER_EXTRA)))
        if not (tr.Hit and not tr.StartSolid and tr.HitNormal:Dot(floorNormal) < 0.9) then
            return nil
        end
    end

    local best = BMX.SweepContact(centre, down, axle, dir, radius,
        BMX.SWEEP_LITE, trace, nil, floorNormal)
    if best or floorNormal then
        best = BMX.SweepContact(centre, down, axle, dir, radius,
            BMX.SWEEP_EXTRA, trace, best, floorNormal)
    end
    return BMX.SweepResolve(centre, axle, radius, trace, best)
end

-- Where the entity origin sits above flat ground at rest: on the axle line,
-- which is one wheel radius up less the static sag. Spawning anywhere higher
-- is dropping the bike, and it bounced on its suspension every time it was
-- spawned: both spawn paths used to put it 16 units plus a radius up.
function BMX.RestHeight(cfg)
    local C = cfg or BMX.Config
    local g = physenv and physenv.GetGravity and physenv.GetGravity():Length() or 600
    local sag = C.Chassis.mass * g * (C.Wheel.loadShare or 0.5) / C.Wheel.spring
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

    local wheels = {}
    -- ONE AXLE FOR A ONE-WHEELED VEHICLE (G13): a wheelbase of nothing is a unicycle,
    -- and two identical boxes on top of each other would count its wheel twice in the
    -- volume that places the mass centre. And a REAR WHEEL OF ITS OWN SIZE (a
    -- penny-farthing's), whose axle sits lower on the chassis by the difference. {x of
    -- the axle, its wheel's radius, its height on the chassis}; a bike's two are
    -- exactly what they always were.
    local axles = (half < 0.5) and { { 0, r, 0 } }
        or { { half, r, 0 }, { -half, W.rearRadius or r, W.rearRadius and (W.rearRadius - r) or 0 } }
    for _, a in ipairs(axles) do
        local x, rr, dz = a[1], a[2], a[3]
        -- The floor is where the suspension runs out of travel (see the config).
        local floor = CH.wheelHullBottom or -(rr - W.restLength)
        wheels[#wheels + 1] = { Vector(x - rr, -hw, dz + floor), Vector(x + rr, hw, dz + rr) }
    end
    -- The pegs (Chassis.pegHullHalfWidth): a box across each axle.
    if CH.pegHullHalfWidth then
        local pw = CH.pegHullHalfWidth
        for _, a in ipairs(axles) do
            local x, dz = a[1], a[3]
            wheels[#wheels + 1] = { Vector(x - 1.2, -pw, dz), Vector(x + 1.2, pw, dz + 6) }
        end
    end
    -- The bars (Chassis.barHullCentre): counted with the wheels, since the
    -- body is shifted to balance whatever is added to it.
    if CH.barHullCentre and half >= 0.5 then
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

