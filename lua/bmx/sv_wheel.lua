--[[--------------------------------------------------------------------------
    bmx/sv_wheel.lua

    A raycast wheel: suspension spring/damper plus a slip-velocity tyre model.

    WHY RAYCAST AND NOT REAL WHEELS. Two thin cylinders resting on a plane at
    Source's physics rate jitter, tunnel through displacement seams, and catch on
    brush edges. Every "motorbike" in Garry's Mod that tries it ends up as a
    four-wheel jeep with two wheels hidden, which is exactly why none of them
    feel like bikes. A raycast wheel has no collision hull at all: it is a
    downward trace plus a force, so it cannot tunnel, cannot jitter, and its
    behaviour is a function you can read rather than a solver you can only
    observe. This is the same model as Bullet's btRaycastVehicle and Unity's
    WheelCollider.

    Each wheel owns its own rotational state (omega), which is what makes
    lockups, skids and pedalling-in-the-air fall out of the model instead of
    having to be special-cased.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Wheel = BMX.Wheel or {}

local Wheel = BMX.Wheel
Wheel.__index = Wheel

local abs, min, max, sqrt = math.abs, math.min, math.max, math.sqrt

--------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------

-- mountLocal: the SUSPENSION MOUNT in chassis space -- the top of the strut,
-- NOT the axle. The chassis origin sits on the design axle line, so the mount
-- is (+/- wheelbase/2, 0, restLength): lifted by exactly the spring's travel.
--
-- Putting it on the axle line instead makes the spring read full compression at
-- the nominal ride height with no travel left, which is a hundredfold force
-- error and a bike that launches. See the comment in ENT:Initialize.
--
-- `def` is the wheel's entry in the vehicle's `wheels` list (sh_vehicles.lua),
-- and is optional: the suite builds bare wheels without one. It is what makes
-- the wheel loop N wheels rather than a front and a rear: which share of the
-- drive torque it takes (`drive`), how it steers (`steerMode`: "fork" is the
-- single-track balance's to set, a function is called every grounded substep)
-- and its own radius, if it has one.
function BMX.NewWheel(mountLocal, isFront, def)
    def = def or {}
    return setmetatable({
        mount     = mountLocal,
        isFront   = isFront,
        def       = def,
        drive     = def.drive or false,
        steerMode = def.steer or false,
        radiusOverride = def.radius,

        -- state
        omega       = 0,      -- rad/s, positive = rolling forwards
        steer       = 0,      -- rad, steered wheels only
        compression = 0,      -- units
        lastComp    = 0,
        onGround    = false,
        groundTime  = 0,

        -- last-frame outputs, read by the debug overlay and the crash check
        load        = 0,      -- N, normal force
        slipLong    = 0,      -- u/s
        slipLat     = 0,      -- u/s
        latForce    = 0,      -- kg*u/s^2, read by the balance feed-forward
        saturation  = 0,      -- 0..1, how much of the friction circle is used
        contactPos  = Vector(),
        contactNorm = Vector(0, 0, 1),
        spinAngle   = 0,      -- rad, accumulated, for the visual wheel

        -- stick-slip anchor (see "STATIC FRICTION" in Wheel:Simulate)
        anchor      = nil,    -- world point the contact patch is pinned to
        anchorFree  = 0,      -- CurTime() after which it may stick again
        hold        = false,  -- set by PhysicsStep: parked, so hold on a slope

        -- swept contact (see "THE SWEPT WHEEL")
        steepUntil  = 0,      -- CurTime() until which the full fan stays on
        wall        = false,  -- the contact is a face too steep to roll up
        rays        = 1,      -- traces fired last substep, for the cost tests
        obstacle    = nil,    -- the second contact last substep, if any
    }, Wheel)
end

--------------------------------------------------------------------------
-- THIS WHEEL'S Wheel config group: the vehicle's, or -- when the wheel has a
-- radius of its own (a unicycle's, a scooter's small front) -- that group seen
-- through an overlay with just the radius replaced. Reading through __index
-- rather than copying keeps live tuning working on every other field, and the
-- overlay is cached against the group it overlays, which is rebuilt when a
-- convar moves a per-vehicle config. A wheel with no radius of its own (every
-- bike's) gets the group itself, so nothing changes for them.
--------------------------------------------------------------------------
function Wheel:WheelConfig(cfg)
    local WC = cfg.Wheel
    local r = self.radiusOverride
    if not r or r == WC.radius then return WC end
    if self._ovBase ~= WC or self._ovR ~= r then
        self._ovBase, self._ovR = WC, r
        -- ...and the wheel's own inertia: a solid disc's is mr^2/2, so it goes with the
        -- square of the radius (a penny-farthing's small wheel is not a 26-unit one's
        -- flywheel). Nothing that has a radius of its own of the config's is changed.
        self._ov = setmetatable({ radius = r, inertia = WC.inertia * (r / WC.radius) ^ 2 }, { __index = WC })
    end
    return self._ov
end

--------------------------------------------------------------------------
-- The forward direction this wheel actually rolls in.
--
-- Front wheel: chassis forward rotated by the steer angle about the CONTACT
-- NORMAL, not about the chassis up. On a slope those differ, and steering about
-- the chassis up on a hill quietly steers you into the hill.
--------------------------------------------------------------------------
local function rollDirection(self, ent, normal)
    local fwd = BMX.ProjectPerp(ent:GetForward(), normal)
    if not fwd then return nil, nil end

    if self.steer ~= 0 then
        local ang = self.steer
        local c, s = math.cos(ang), math.sin(ang)
        local right = fwd:Cross(normal)
        fwd = (fwd * c + right * s):GetNormalized()
    end

    -- Source is X-forward, Y-left, Z-up, so right = forward x up.
    return fwd, fwd:Cross(normal)
end

--------------------------------------------------------------------------
-- The effective mass the chassis presents at a contact point along a
-- direction: the standard constraint-space quantity,
--
--     1/m_eff = 1/M + (r x d) . I^-1 . (r x d)
--
-- It is the mass an impulse along `dir` applied at `contact` actually has to
-- shift, which is NOT the bike's mass whenever the contact is offset from the
-- centre of mass: pushing forward on a patch 20 units below the COM mostly
-- pitches the bike, and pushing sideways mostly rolls it.
--
-- Every explicit force in this file that is trying to REMOVE a relative
-- velocity -- the suspension damper, and both tyre forces -- has to be capped
-- against this figure or it overshoots and adds energy. Sharing one function
-- is deliberate: the damper was fixed for this in isolation once, and the tyre,
-- which has exactly the same problem, was left behind for a month.
--------------------------------------------------------------------------
local function effectiveMass(ent, phys, cfg, contact, dir, share)
    local com = phys:LocalToWorld(phys:GetMassCenter())
    local rxd = (contact - com):Cross(dir)

    -- Express r x d on the body's principal axes. Source's local frame is
    -- x = forward, y = LEFT, z = up, so the y component is -Right.
    local lx =  rxd:Dot(ent:GetForward())
    local ly = -rxd:Dot(ent:GetRight())
    local lz =  rxd:Dot(ent:GetUp())

    local invI = lx * lx / BMX.IRoll(ent)
               + ly * ly / BMX.IPitch(ent)
               + lz * lz / BMX.IYaw(ent)

    -- WHEN SEVERAL WHEELS ANSWER THE SAME MOTION (`share`, the wheel's
    -- `coupling`: the number of wheels, for a vehicle with more than two; 1 for
    -- a bike). Each cap above is the force that would null the slip IF THIS
    -- WHEEL WERE THE ONLY ONE ACTING, and a bike's two wheels are the case they
    -- were tuned against. Four wheels all measuring the same slip and each
    -- nulling the whole of it overshoot it four times over and ring; each
    -- carrying a quarter of the mass is the same constraint split between them,
    -- and the stick-slip springs below add back up to the whole. A bike's
    -- coupling is exactly 1, so nothing it computes changes.
    return 1 / (1 / cfg.Chassis.mass + invI) / (share or 1)
end

--------------------------------------------------------------------------
-- THE SWEPT WHEEL (bmx_wheel_sweep): the contacts a single ray cannot see.
--
-- The strut ray finds the floor under the axle. What it cannot find is a face
-- IN FRONT of the tyre -- the foot of a wedge, a curb, a wall -- so the tyre
-- sank into it (luttje/gmod-bicycle #5) or stuck against it (#16). Here the
-- disc is probed by a fan of rays in its own plane (BMX.SweepContact), and the
-- contact it finds is handled as a second, normal-only constraint next to the
-- floor's, or as the wheel's only contact when there is no floor in reach.
--
-- Cost is the reason it is tiered (BMX.SweepProbe). On flat ground a wheel
-- fires its strut ray and one bumper ray (two traces, against one without the
-- sweep); the nine-ray fan only goes out when the bumper hit a face rising from
-- the floor, the floor under the strut is steeper than 25 degrees, or a face
-- was touched in the last Wheel.sweepHold seconds. 25 bikes at 66 ticks is the
-- budget (the headless `crowd` case), and it is spent on the bikes that need it.
--
-- Returns the resolved contact (BMX.SweepResolve) or nil, and the ray count.
--------------------------------------------------------------------------
local function sweepProbe(self, ent, phys, WC, mountWorld, down, floorPoint, floorNormal, hot)
    local centre = mountWorld + down * WC.restLength
    local dir = (phys:GetVelocity():Dot(ent:GetForward()) >= -2) and 1 or -1
    return BMX.SweepProbe(centre, down, ent:GetRight(), dir, WC.radius,
        self._traceFn, floorPoint, floorNormal, hot)
end

--------------------------------------------------------------------------
-- The force one contact applies along its normal: spring, damper and bump
-- stop with the same stability cap as the main contact's. Used for the second
-- (obstacle) contact, which has no tyre.
--------------------------------------------------------------------------
local function normalForce(ent, phys, cfg, dt, contact, normal, depth)
    local WC = cfg.Wheel
    local velAt = phys:GetVelocityAtPoint(contact)
    local compVel = -velAt:Dot(normal)
    local springF = WC.spring * min(depth, WC.restLength)
    if depth > WC.restLength then springF = springF + WC.bumpStop * (depth - WC.restLength) end
    local damperF = WC.damper * compVel
    if compVel > 0 then
        local cap = effectiveMass(ent, phys, cfg, contact, normal) * compVel / dt
        if damperF > cap then damperF = cap end
    end
    local N = springF + damperF
    if N < 0 then N = 0 end
    local maxN = WC.maxLoadFactor * cfg.Chassis.mass * physenv.GetGravity():Length()
    if N > maxN then N = maxN end
    return N
end

-- Push the wheel out of a face the fan found. The force is along the contact's
-- normal and applied at the contact: no tyre on it, because a face is not
-- something a wheel is driven along. Pushing against a wall does not climb it.
local function applyFace(self, ent, phys, cfg, dt, face)
    local N = normalForce(ent, phys, cfg, dt, face.point, face.normal, face.depth)
    local f = face.normal * N
    if BMX.FiniteVec(f) then phys:ApplyForceOffset(f * dt, face.point) end
    self.obstacle = face
    self.faceLoad = N
end

--------------------------------------------------------------------------
-- One physics substep for one wheel.
--
--   driveTorque  kg*units^2/s^2 delivered to THIS wheel by the drivetrain
--   brakeTorque  kg*units^2/s^2, always opposes rotation
--   filter       entities the ground trace must ignore
--   snap         optional { v, w, com }: the chassis's velocity, angular
--                velocity and mass centre at the START of the substep. With it
--                the wheel reads the patch's velocity from that instead of from
--                the live body, which the wheels before it in the loop have
--                already pushed. A bike (two wheels, applied in turn, which is
--                what its tyre caps were tuned on) passes none; see
--                ENT:Initialize, where `coupling` is set, for why four wheels
--                cannot be evaluated one after another.
--
-- Returns nothing; forces are applied directly and diagnostic state is left on
-- the wheel for the caller.
--------------------------------------------------------------------------
function Wheel:Simulate(ent, phys, cfg, dt, driveTorque, brakeTorque, filter, snap)
    local C     = cfg
    local WC    = self:WheelConfig(C)
    local radius = WC.radius
    local maxLen = BMX.WheelReach(WC)
    -- THE WHEEL'S INERTIA, plus the engine's when a locked clutch ties one to it (G15,
    -- sv_motor.lua sets `extraInertia` = engine inertia / ratio^2 each substep it is
    -- locked, and nothing otherwise): a flywheel 50 times the wheel's own is what an
    -- engine on a locked clutch IS, and without it the wheel answers a drive torque
    -- at its own tiny inertia and the clutch chatters. Every other vehicle: unchanged.
    local WI    = WC.inertia + (self.extraInertia or 0)

    local mountWorld = ent:LocalToWorld(self.mount)
    local down       = -ent:GetUp()
    local now        = CurTime()

    local tr = util.TraceLine({
        start  = mountWorld,
        endpos = mountWorld + down * maxLen,
        filter = filter,
        mask   = MASK_SOLID,
    })

    -- Where the DISC touches, not where the ray landed. See BMX.DiscContact:
    -- the two agree on the level and under lean, and differ under pitch by
    -- exactly the error that was lifting wheelies past their balance point.
    local s, contact, edgeNormal
    if tr.Hit then
        s, contact = BMX.DiscContact(mountWorld, down, ent:GetRight(),
            maxLen * tr.Fraction, tr.HitNormal, radius)
        -- IS THE GROUND REALLY THERE? Far from the ray's own hit (a wheel
        -- pitched well over against the surface) the disc's lowest point on the
        -- plane may be past the plane's edge. Then the edge is what it touches
        -- (BMX.EdgeDiscContact). Near the ray hit it is the plane's, as always,
        -- and no trace is spent.
        if s and (contact - tr.HitPos):LengthSqr() > (WC.edgeCheck or 3) ^ 2 then
            local n = tr.HitNormal
            local function ground(p)
                local t = util.TraceLine({ start = p + n * 1.5, endpos = p - n * 1.5,
                    filter = filter, mask = MASK_SOLID })
                return t.Hit and not t.StartSolid and t.HitNormal:Dot(n) > 0.95
            end
            if not ground(contact) then
                local a, b = tr.HitPos, contact          -- a on the ground, b past it
                for _ = 1, 6 do
                    local m = (a + b) * 0.5
                    if ground(m) then a = m else b = m end
                end
                local es, ec, en = BMX.EdgeDiscContact(mountWorld, down, ent:GetRight(), a, radius)
                if es then
                    s, contact, edgeNormal = es, ec, en
                else
                    s, contact = nil, nil
                end
                self.edgeHits = (self.edgeHits or 0) + 1
            end
        end
    end

    ----------------------------------------------------------------------
    -- THE SWEPT WHEEL (see sweepProbe). Fires only with bmx_wheel_sweep on.
    -- `floor` is the strut's own contact, if it has one; `face` is what the
    -- fan found that the floor does not explain.
    ----------------------------------------------------------------------
    local floor = s and s <= WC.restLength
    local face, sweepComp, sweepNormal, sweepPoint
    self.rays, self.obstacle, self.wall = 1, nil, false
    if WC.sweep and WC.sweep > 0 then
        if not self._traceFn then
            self._traceFn = function(a, b)
                self._rayCount = self._rayCount + 1
                return util.TraceLine({ start = a, endpos = b,
                    filter = self._filter, mask = MASK_SOLID })
            end
        end
        self._filter, self._rayCount = filter, 1
        local floorNormal = floor and tr.HitNormal or nil
        local steepFloor = floor and tr.HitNormal.z < 0.906       -- over 25 degrees
        local hot = steepFloor or now < self.steepUntil
        face = sweepProbe(self, ent, phys, WC, mountWorld, down,
            floor and contact or nil, floorNormal, hot)
        self.rays = self._rayCount
        if face or steepFloor then self.steepUntil = now + (WC.sweepHold or 0.15) end
        if face and not floor and face.normal.z >= (WC.wallCos or 0.17) then
            -- Nothing under the strut, but ground the tyre IS touching: the
            -- fan's contact stands in for the floor, tyre forces and all.
            -- (A wedge face seen from above is how a wheel rides over a lip.)
            s, contact = WC.restLength - face.depth, face.point
            sweepComp, sweepNormal = face.depth, face.normal
            floor, face = true, nil
        end
    end

    ----------------------------------------------------------------------
    -- Airborne: no ground in reach, or ground the disc cannot touch at full
    -- extension. The ray is longer than the strut so that a pitched wheel can
    -- still find the ground it is sitting on; the price is that a hit is no
    -- longer proof of contact on its own.
    ----------------------------------------------------------------------
    if not floor then
        self.lastComp   = nil
        self.anchor     = nil
        self.onGround   = false
        self.load       = 0
        self.slipLong   = 0
        self.slipLat    = 0
        self.latForce   = 0
        self.saturation = 0
        self.compression = 0
        self.contactNorm = Vector(0, 0, 1)

        -- The rider can still spin the cranks in the air (and a locked brake
        -- still stops the wheel), which is how a real rider sets up a landing.
        local netTorque = driveTorque
        if brakeTorque > 0 then
            local dOmega = brakeTorque / WI * dt
            if abs(self.omega) <= dOmega then
                self.omega = 0
            else
                self.omega = self.omega - dOmega * (self.omega > 0 and 1 or -1)
            end
        end
        self.omega = self.omega + (netTorque / WI) * dt
        -- bearing drag, so a free wheel eventually stops
        self.omega = self.omega * (1 - min(0.4 * dt, 0.5))

        self.spinAngle = self.spinAngle + self.omega * dt

        -- Touching something steep with no floor under the strut: a wall.
        if face then
            self.wall = true
            applyFace(self, ent, phys, C, dt, face)
        end
        return
    end

    ----------------------------------------------------------------------
    -- Suspension
    ----------------------------------------------------------------------
    local comp   = WC.restLength - s                -- >= 0
    local normal = sweepNormal or edgeNormal or tr.HitNormal

    ----------------------------------------------------------------------
    -- A STEP IS NOT A SPRING. The strut is a ray from the mount, and the
    -- substep the mount crosses a ledge's edge the ray lands on its TOP: the
    -- compression jumps by the ledge's height in one tick, far past the
    -- travel, and the bump stop answers with the force of a crash landing.
    -- Riding into a 16-unit ledge threw the bike up at 226 u/s, a 40-unit one
    -- at 483 (tests/test_ride_feel.lua). A tyre cannot do that: it rolls up
    -- a small step over the distance it takes to climb it, and a step taller
    -- than about half its radius it cannot roll onto at all -- that is a face
    -- the wheel runs into, which the wheel's collision box already meets.
    --
    -- So, riding (not landing: a landing's soak wants the full compression
    -- at once), the ground under a wheel may rise at most Wheel.climbRate,
    -- and a rise of more than Wheel.stepMax in one substep is not ground.
    ----------------------------------------------------------------------
    -- (A contact the FAN found is already geometry: it rises as smoothly as
    -- the tyre rolls onto the face, so the limiter has nothing to limit.)
    local prev = self.lastComp
    self.stepBlocked = false
    -- AND NO WHEEL COMES BACK DOWN PAST ITS TRAVEL. A wheel that was off the
    -- ground (no `prev`), with the bike riding rather than landing, finds the
    -- ground again within a unit or two of the end of its ray -- unless the
    -- ground swung into the ray from the side: cresting a hump nose-down the
    -- rear strut came back on the slope behind it 4 units past full travel,
    -- the bump stop answered at the 309,600 ceiling and threw the bike over
    -- its bars (measured on a real server). That much is the wheel box's to
    -- meet, not the spring's.
    if not prev and not self.soak and not sweepComp and comp > WC.restLength then
        comp = WC.restLength
    end
    if prev and not self.soak and not sweepComp then
        local rise = comp - prev
        if rise > WC.stepMax then
            comp = prev
            self.stepBlocked = true
        elseif rise > WC.climbRate * dt then
            comp = prev + WC.climbRate * dt
        end
    end
    self.lastComp = comp

    local velAt   = snap and (snap.v + snap.w:Cross(contact - snap.com))
                         or phys:GetVelocityAtPoint(contact)

    -- d(compression)/dt: the contact patch approaching the ground. Measured
    -- along the ground normal rather than the strut, since that is the axis the
    -- force acts along and the one the damper's cap below is sized on; the two
    -- are the same thing on the level.
    local compVel = -velAt:Dot(normal)

    local springF = WC.spring * min(comp, WC.restLength)
    if comp > WC.restLength then
        -- Bottomed out. Without this term a hard landing puts the hull through
        -- the floor and VPhysics resolves it by launching the bike.
        springF = springF + WC.bumpStop * (comp - WC.restLength)
    end

    ----------------------------------------------------------------------
    -- THE DAMPER MUST NEVER REVERSE THE APPROACH IT IS DAMPING.
    --
    -- This is the single nastiest bug in the file's history, so it is worth
    -- the space. An explicit damper computes F = c*v and applies it for a
    -- whole timestep. If c*dt exceeds the effective mass at the contact
    -- point, that impulse does not just remove the approach velocity, it
    -- reverses it -- and adds energy every step. The result is a suspension
    -- that pumps itself up until the bike is thrown into the sky.
    --
    -- The trap is that the naive stability check PASSES. Against the
    -- per-wheel mass share (43 kg) c*dt/m is 0.67, comfortably stable. But
    -- the contact patch sits ~21 units from the centre of mass, so pushing
    -- on it mostly PITCHES the bike rather than lifting it, and the mass it
    -- actually feels is I_pitch/r^2 ~ 26 kg. At that figure c*dt/m is 1.13
    -- and the loop diverges: one contact spiked 3 rad/s of pitch in a single
    -- substep, the rotation moved the contact point, that inflated compVel,
    -- and the damper answered with 429,853 against a 25,800 static load.
    --
    -- So compute the real effective mass along the suspension axis -- the
    -- standard constraint-space quantity, 1/m_eff = 1/M + (r x n).I^-1.(r x n)
    -- -- and clamp the damper to the impulse that exactly nulls the approach.
    -- That is unconditionally stable for any c, any dt and any geometry,
    -- which is a much better property than a damper that happens to be tuned
    -- low enough today.
    ----------------------------------------------------------------------
    local damperF = WC.damper * compVel

    if compVel > 0 then
        local cap = effectiveMass(ent, phys, cfg, contact, normal, self.coupling) * compVel / dt
        if damperF > cap then damperF = cap end
    end

    local N = springF + damperF
    if N < 0 then N = 0 end        -- a wheel can push, never pull

    -- ANTI-EXPLOSION CLAMP. Not a physical effect: a numerical backstop.
    -- One bad substep -- a spawn inside geometry, a teleport, a mount offset
    -- that leaves the spring bottomed out -- can hand the bump-stop tens of
    -- units of overshoot and produce a force two orders of magnitude past
    -- anything real. VPhysics faithfully applies it and the bike leaves the
    -- map. A ceiling costs nothing in normal riding (a hard landing peaks
    -- around 5-8x static) and turns "launched into orbit" into "landed hard".
    local maxN = WC.maxLoadFactor * C.Chassis.mass
        * physenv.GetGravity():Length()
    if N > maxN then N = maxN end

    self.compression = comp
    self.load        = N

    -- The face beside the floor: the wheel is on the ground AND against
    -- something (the foot of a ramp, a curb). Pushed out along its normal.
    if face then applyFace(self, ent, phys, C, dt, face) end

    ----------------------------------------------------------------------
    -- Tyre
    ----------------------------------------------------------------------
    local fwdDir, rightDir = rollDirection(self, ent, normal)
    if not fwdDir then
        -- Bike is pointing along the surface normal (nose into a wall). No
        -- meaningful contact patch; apply the suspension force only.
        phys:ApplyForceOffset(normal * (N * dt), contact)
        self.onGround = true
        self.latForce = 0
        return
    end

    local vFwd = velAt:Dot(fwdDir)
    local vLat = velAt:Dot(rightDir)

    ----------------------------------------------------------------------
    -- SPIN THE WHEEL FIRST, THEN SOLVE THE TYRE AGAINST WHAT THAT LEAVES.
    --
    -- The drive and brake torques are applied here, before the slip is
    -- measured, and the tyre force is solved for afterwards as the reaction to
    -- the slip they produced. That ordering is the whole difference between a
    -- tyre that hooks up and one that spins.
    --
    -- Do it the other way round -- measure slip, apply a capped force, then
    -- integrate the wheel against drive MINUS that force -- and the drive
    -- torque is regenerating slip that the force is only ever answering one
    -- step late. The wheel wins, because the cap below is sized against the
    -- wheel's own tiny rotational inertia (I/r^2 is about 1.1 kg). It spins up
    -- to the cadence ceiling, the falling torque curve in sv_physics then reads
    -- a rider spinning out and cuts crank torque to nearly nothing, and the
    -- bike tops out at a third of walking pace with its rear wheel screaming.
    -- Measured: 75 u/s against a 210 u/s floor, cadence pinned at 0.99.
    ----------------------------------------------------------------------
    local omegaFree = self.omega + (driveTorque / WI) * dt

    -- A brake-LOCKED wheel is a different constraint, not a stiffer one: the
    -- tyre force reacts into the brake and through it into the chassis, rather
    -- than spinning the wheel. Detected the same way the brake itself decides,
    -- so the two can never disagree.
    local locked, braked = false, false
    if brakeTorque > 0 then
        local dOmega = brakeTorque / WI * dt
        if abs(omegaFree) <= dOmega then
            omegaFree = 0                 -- locked: the slip becomes -vFwd,
            locked    = true              -- the tyre saturates, and you skid
            braked    = true
        else
            omegaFree = omegaFree - dOmega * (omegaFree > 0 and 1 or -1)
        end
    end

    ----------------------------------------------------------------------
    -- A PARKED WHEEL ON A SLOPE IS A LOCKED ONE. The kickstand holds a bike
    -- level (7c in sv_physics.lua) but it is the TYRES that have to carry the
    -- bike's weight down the slope, and a wheel left free to roll would just
    -- roll. Only on a slope: on the level there is nothing to hold, and
    -- locking the patch there is how a parked bike's lean onto its stand got
    -- fought by its own tyres.
    ----------------------------------------------------------------------
    local stick = WC.stiction and WC.stiction > 0
    if stick and not locked and self.hold and abs(vFwd) < WC.stickSpeed
       and normal.z < 0.9995 then
        omegaFree = 0
        locked    = true
    end

    -- Slip VELOCITY, not slip ratio. See the note in sh_config.lua: slip ratio
    -- divides by ground speed and a BMX spends a lot of its life at zero.
    local slipLong = omegaFree * radius - vFwd
    local slipLat  = -vLat

    local Fmax  = WC.grip * N
    local Flong = slipLong * WC.longStiffness
    local Flat  = slipLat  * WC.latStiffness

    ----------------------------------------------------------------------
    -- A TYRE FORCE MAY NEVER MORE THAN CANCEL THE SLIP IT IS ANSWERING.
    --
    -- Both stiffnesses above are relaxation rates integrated EXPLICITLY, so
    -- each is only stable while its force takes more than a timestep to close
    -- its own slip. Neither was. Measured on the live server at 66 Hz:
    --
    --     longitudinal   tau = 0.40 ms,  dt/tau = 37.6
    --     lateral        tau = 3.52 ms,  dt/tau =  4.3
    --
    -- and stability needs dt/tau < 2. So the longitudinal slip was multiplied
    -- by about -35 every substep and the lateral by -2.3: both flipped sign
    -- every tick and grew.
    --
    -- THE FRICTION CIRCLE HID IT AND THEN MADE IT WORSE. A divergence normally
    -- ends in a NaN, which is at least loud. Here the circle clamped the
    -- runaway to grip*N every tick, so it presented as a bounded oscillation
    -- with no error at all -- and because the clamp RADIUS is grip*N, and N is
    -- itself oscillating in phase, the positive half-cycle was bounded by a
    -- larger N than the negative one. That rectifies. The bike accelerated
    -- from 0 to 296 u/s in two seconds with no rider aboard and no throttle:
    -- free energy, straight out of a stability bug.
    --
    -- What it looked like from outside is worth recording, because none of it
    -- pointed here: the front wheel bounced clear of the ground so the static
    -- load split read 21/79 against a designed 45/55, the "top speed" case
    -- measured a number that had nothing to do with the drivetrain, braking
    -- could never stop a bike being pushed, and lean, wheelie and steering all
    -- failed on top of a chassis that was being shaken. Six of the twelve
    -- cases, and the tuning notes had them down as five separate tuning
    -- problems downstream of a sixth.
    --
    -- The cure is the damper's, one block up: cap the force at the one that
    -- exactly nulls the slip over this dt. Below the stability limit the linear
    -- stiffness is untouched, so this is a ceiling rather than a retune, and it
    -- holds for any stiffness, any tickrate and any contact geometry.
    --
    -- WHICH COMPLIANCE, though, is the part that is easy to get wrong. Slip is
    -- the difference between two speeds, so the force closes it through
    -- whichever of them can actually move. A rolling wheel spins up, so its
    -- r^2/I term joins the chassis term -- and dominates it, because a 20-inch
    -- wheel is only about 1.1 kg of equivalent mass at the contact patch. A
    -- LOCKED wheel cannot, so that path is gone and only the chassis remains.
    --
    -- Getting that second case wrong is not subtle: with the wheel term wrongly
    -- included, a wheel skidding at 200 u/s was capped at about 14,000 against
    -- a grip limit of 37,800, so the friction circle could never bind and the
    -- suite measured a peak saturation of 0.00 during a full-lock skid. The
    -- tyre had been given a numerical ceiling below its physical one, which
    -- quietly deletes the friction model.
    ----------------------------------------------------------------------
    local invCompLong = 1 / effectiveMass(ent, phys, cfg, contact, fwdDir, self.coupling)
    if not locked then
        invCompLong = invCompLong + radius * radius / WI
    end

    local capLong = abs(slipLong) / (dt * invCompLong)
    if abs(Flong) > capLong then
        Flong = capLong * (Flong >= 0 and 1 or -1)
    end

    local capLat = abs(slipLat) * effectiveMass(ent, phys, cfg, contact, rightDir, self.coupling) / dt
    if abs(Flat) > capLat then
        Flat = capLat * (Flat >= 0 and 1 or -1)
    end

    ----------------------------------------------------------------------
    -- STATIC FRICTION: THE STICK-SLIP ANCHOR.
    --
    -- A slip-velocity tyre answers a slip that already exists, so at zero slip
    -- it gives zero force: a locked wheel on a slope creeps at
    -- m*g*sin(slope)/stiffness, steadily, for as long as the brake is held.
    -- That is luttje/gmod-bicycle's #4 ("a tiny incline causes it to slide
    -- continuously"), and real tyres do not do it: below some speed the patch
    -- STICKS, and what holds it is a displacement, not a velocity.
    --
    -- So a LOCKED wheel (brake held, or parked on a slope) that is slower than
    -- stickSpeed pins its contact patch to where it is. From then on the force
    -- is a spring-damper on how far the patch has been dragged from that
    -- point, along and across the wheel, with the stiffness a critically
    -- damped oscillator of natural frequency stickFreq has against the mass the
    -- patch really feels (effectiveMass, as for the damper above).
    --
    -- INTEGRATED IMPLICITLY. The explicit damper elsewhere in this file needs
    -- its cap because c*dt past the effective mass reverses the velocity it is
    -- damping. This one is solved for the NEXT step's position and velocity,
    -- F = -(k*x + (k*dt + c)*v) / (1 + c*dt/m + k*dt^2/m), which is stable for
    -- any stiffness and any tickrate, so it needs no cap and cannot buzz at 33
    -- or 66. At 25 rad/s the held patch sags F/k: a bike on 20 degrees takes
    -- ~0.7 units, which is the sag of a spring, and it stays there.
    --
    -- LIMITED BY THE FRICTION CIRCLE. When the force it takes to hold the
    -- patch exceeds grip*N the tyre lets go: the anchor is dropped, ordinary
    -- sliding resumes, and it cannot stick again for stickCooldown. A wheel
    -- that is rolling is never here at all, so free rolling is untouched.
    ----------------------------------------------------------------------
    local anchored = false
    if stick and locked then
        local vPatch = sqrt(vFwd * vFwd + vLat * vLat)
        -- (The FRONT brake's: at a standstill the rear key is the paddle-backwards
        -- key, and a rear patch pinned from walking pace fought the paddling.)
        local catch = (braked and self.isFront) and (WC.brakeStickSpeed or WC.stickSpeed) or WC.stickSpeed
        if not self.anchor and now >= self.anchorFree and vPatch < catch then
            self.anchor = Vector(contact)
        end
        if self.anchor then
            local d = contact - self.anchor
            local w = WC.stickFreq
            local function spring(x, v, m)
                local k, c = m * w * w, 2 * m * w
                return -(k * x + (k * dt + c) * v) / (1 + c * dt / m + k * dt * dt / m)
            end
            local mL = effectiveMass(ent, phys, cfg, contact, fwdDir, self.coupling)
            local mT = effectiveMass(ent, phys, cfg, contact, rightDir, self.coupling)
            local aLong = spring(d:Dot(fwdDir),   vFwd, mL)
            local aLat  = spring(d:Dot(rightDir), vLat, mT)
            if sqrt(aLong * aLong + aLat * aLat) <= Fmax then
                Flong, Flat, anchored = aLong, aLat, true
            else
                self.anchor     = nil
                self.anchorFree = now + WC.stickCooldown
            end
        end
    else
        self.anchor = nil
    end

    -- Friction circle: the tyre has one budget and braking spends the same
    -- money as cornering. This is the whole reason a bike washes out mid-corner
    -- when you grab the brake, and it costs four lines.
    local mag = sqrt(Flong * Flong + Flat * Flat)
    if mag > Fmax and mag > 0 then
        local scale = Fmax / mag
        Flong = Flong * scale
        Flat  = Flat  * scale
        self.saturation = 1
    else
        self.saturation = Fmax > 0 and (mag / Fmax) or 0
    end

    -- Rolling resistance, proportional to load, always opposing motion.
    if abs(vFwd) > 1 and not anchored then
        Flong = Flong - WC.rollingResistance * N * (vFwd > 0 and 1 or -1)
    end

    ----------------------------------------------------------------------
    -- Wheel rotation
    --
    -- The drive and brake torques were already integrated above, into
    -- omegaFree, so all that is left here is the tyre's reaction -- which is
    -- what makes a spun-up wheel hook up. A brake-locked wheel takes that
    -- reaction through the brake instead and stays put, which is what makes a
    -- skid a skid rather than a wheel that quietly starts rolling again.
    ----------------------------------------------------------------------
    if locked then
        self.omega = 0
    else
        self.omega = omegaFree - (Flong * radius / WI) * dt
    end

    -- Freewheel: a BMX cassette cannot be driven backwards by the ground, so a
    -- coasting rider feels no engine braking. Fixed-gear bikes skip this.
    if not C.Drive.fixedGear and driveTorque <= 0 and brakeTorque <= 0 and not locked then
        local kinematic = vFwd / radius
        if self.omega < kinematic then self.omega = kinematic end
    end

    self.spinAngle = self.spinAngle + self.omega * dt

    ----------------------------------------------------------------------
    -- Apply
    ----------------------------------------------------------------------
    local force = normal * N + fwdDir * Flong + rightDir * Flat

    if self.soak then
        ------------------------------------------------------------------
        -- LANDING SOAK (see sv_physics.lua): the suspension's push goes in
        -- directly beneath the mass centre SIDEWAYS, so it cannot lever a
        -- leaned bike further over. A landing leaned 45 degrees took ~10x
        -- the bike's weight at the contact patch, 20-odd units to the side,
        -- and rolled the bike from 44 to 112 degrees in a tenth of a second.
        -- Fore and aft it is unchanged, so pitch still behaves. The tyre
        -- forces stay at the patch.
        ------------------------------------------------------------------
        local com = phys:LocalToWorld(phys:GetMassCenter())
        local soakAt = contact + rightDir * (com - contact):Dot(rightDir)
        -- ...and most of the way under it fore and aft (Crash.soakPitch), so
        -- a big nose-first landing does not throw the bike end over end
        -- off its front wheel. Not all the way: a nose-down landing should
        -- still come down like one.
            + fwdDir * ((com - contact):Dot(fwdDir) * C.Crash.soakPitch)
        local up = normal * N
        local rest = fwdDir * Flong + rightDir * Flat
        if BMX.FiniteVec(up) and BMX.FiniteVec(rest) then
            phys:ApplyForceOffset(up * dt, soakAt)
            phys:ApplyForceOffset(rest * dt, contact)
        end
    elseif BMX.FiniteVec(force) then
        phys:ApplyForceOffset(force * dt, contact)
    end

    self.onGround    = true
    self.groundTime  = CurTime()
    self.slipLong    = slipLong
    self.slipLat     = slipLat
    self.latForce    = Flat
    self.contactPos  = contact
    self.contactNorm = normal
    self.lastComp    = comp
end

--------------------------------------------------------------------------
-- Where to draw the wheel, chassis space. The suspension travel means this is
-- NOT simply the mount point.
--------------------------------------------------------------------------
function Wheel:VisualOffset(cfg)
    local WC = self:WheelConfig(cfg or BMX.Config)
    local drop = self.onGround
        and (WC.restLength - math.min(self.compression, WC.restLength))
        or WC.restLength
    return self.mount - Vector(0, 0, drop)
end
