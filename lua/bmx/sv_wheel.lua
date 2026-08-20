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
function BMX.NewWheel(mountLocal, isFront)
    return setmetatable({
        mount     = mountLocal,
        isFront   = isFront,

        -- state
        omega       = 0,      -- rad/s, positive = rolling forwards
        steer       = 0,      -- rad, front wheel only
        compression = 0,      -- units
        lastComp    = 0,
        onGround    = false,
        groundTime  = 0,

        -- last-frame outputs, read by the debug overlay and the crash check
        load        = 0,      -- N, normal force
        slipLong    = 0,      -- u/s
        slipLat     = 0,      -- u/s
        saturation  = 0,      -- 0..1, how much of the friction circle is used
        contactPos  = Vector(),
        contactNorm = Vector(0, 0, 1),
        spinAngle   = 0,      -- rad, accumulated, for the visual wheel
    }, Wheel)
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
-- One physics substep for one wheel.
--
--   driveTorque  kg*units^2/s^2 delivered to THIS wheel by the drivetrain
--   brakeTorque  kg*units^2/s^2, always opposes rotation
--   filter       entities the ground trace must ignore
--
-- Returns nothing; forces are applied directly and diagnostic state is left on
-- the wheel for the caller.
--------------------------------------------------------------------------
function Wheel:Simulate(ent, phys, dt, driveTorque, brakeTorque, filter)
    local C     = BMX.Config
    local WC    = C.Wheel
    local radius = WC.radius
    local maxLen = WC.restLength + radius

    local mountWorld = ent:LocalToWorld(self.mount)
    local down       = -ent:GetUp()

    local tr = util.TraceLine({
        start  = mountWorld,
        endpos = mountWorld + down * maxLen,
        filter = filter,
        mask   = MASK_SOLID,
    })

    ----------------------------------------------------------------------
    -- Airborne
    ----------------------------------------------------------------------
    if not tr.Hit then
        self.onGround   = false
        self.load       = 0
        self.slipLong   = 0
        self.slipLat    = 0
        self.saturation = 0
        self.compression = 0
        self.contactNorm = Vector(0, 0, 1)

        -- The rider can still spin the cranks in the air (and a locked brake
        -- still stops the wheel), which is how a real rider sets up a landing.
        local netTorque = driveTorque
        if brakeTorque > 0 then
            local dOmega = brakeTorque / WC.inertia * dt
            if abs(self.omega) <= dOmega then
                self.omega = 0
            else
                self.omega = self.omega - dOmega * (self.omega > 0 and 1 or -1)
            end
        end
        self.omega = self.omega + (netTorque / WC.inertia) * dt
        -- bearing drag, so a free wheel eventually stops
        self.omega = self.omega * (1 - min(0.4 * dt, 0.5))

        self.spinAngle = self.spinAngle + self.omega * dt
        return
    end

    ----------------------------------------------------------------------
    -- Suspension
    ----------------------------------------------------------------------
    local dist   = maxLen * tr.Fraction
    local comp   = maxLen - dist                    -- >= 0
    local normal = tr.HitNormal

    local contact = mountWorld + down * dist
    local velAt   = phys:GetVelocityAtPoint(contact)

    -- d(compression)/dt: moving along `down` compresses the spring.
    local compVel = velAt:Dot(down)

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
        local com = phys:LocalToWorld(phys:GetMassCenter())
        local rxn = (contact - com):Cross(normal)

        -- Express r x n on the body's principal axes. Source's local frame is
        -- x = forward, y = LEFT, z = up, so the y component is -Right.
        local lx =  rxn:Dot(ent:GetForward())
        local ly = -rxn:Dot(ent:GetRight())
        local lz =  rxn:Dot(ent:GetUp())

        local invI = lx * lx / BMX.IRoll(ent)
                   + ly * ly / BMX.IPitch(ent)
                   + lz * lz / BMX.IYaw(ent)

        local mEff = 1 / (1 / C.Chassis.mass + invI)
        local cap  = mEff * compVel / dt
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
    local maxN = WC.maxLoadFactor * BMX.Config.Chassis.mass
        * physenv.GetGravity():Length()
    if N > maxN then N = maxN end

    self.compression = comp
    self.load        = N

    ----------------------------------------------------------------------
    -- Tyre
    ----------------------------------------------------------------------
    local fwdDir, rightDir = rollDirection(self, ent, normal)
    if not fwdDir then
        -- Bike is pointing along the surface normal (nose into a wall). No
        -- meaningful contact patch; apply the suspension force only.
        phys:ApplyForceOffset(normal * (N * dt), contact)
        self.onGround = true
        return
    end

    local vFwd = velAt:Dot(fwdDir)
    local vLat = velAt:Dot(rightDir)

    -- Slip VELOCITY, not slip ratio. See the note in sh_config.lua: slip ratio
    -- divides by ground speed and a BMX spends a lot of its life at zero.
    local slipLong = self.omega * radius - vFwd
    local slipLat  = -vLat

    local Fmax  = WC.grip * N
    local Flong = slipLong * WC.longStiffness
    local Flat  = slipLat  * WC.latStiffness

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
    if abs(vFwd) > 1 then
        Flong = Flong - WC.rollingResistance * N * (vFwd > 0 and 1 or -1)
    end

    ----------------------------------------------------------------------
    -- Wheel rotation
    --
    -- The tyre force reacts back on the wheel through the contact patch, which
    -- is what makes a locked wheel stay locked and a spun-up wheel hook up.
    ----------------------------------------------------------------------
    local wheelTorque = driveTorque - Flong * radius

    if brakeTorque > 0 then
        local dOmega = brakeTorque / WC.inertia * dt
        if abs(self.omega) <= dOmega then
            self.omega = 0        -- locked: slipLong becomes -vFwd, tyre saturates, you skid
        else
            self.omega = self.omega - dOmega * (self.omega > 0 and 1 or -1)
        end
    end

    self.omega = self.omega + (wheelTorque / WC.inertia) * dt

    -- Freewheel: a BMX cassette cannot be driven backwards by the ground, so a
    -- coasting rider feels no engine braking. Fixed-gear bikes skip this.
    if not C.Drive.fixedGear and driveTorque <= 0 and brakeTorque <= 0 then
        local kinematic = vFwd / radius
        if self.omega < kinematic then self.omega = kinematic end
    end

    self.spinAngle = self.spinAngle + self.omega * dt

    ----------------------------------------------------------------------
    -- Apply
    ----------------------------------------------------------------------
    local force = normal * N + fwdDir * Flong + rightDir * Flat

    if BMX.FiniteVec(force) then
        phys:ApplyForceOffset(force * dt, contact)
    end

    self.onGround    = true
    self.groundTime  = CurTime()
    self.slipLong    = slipLong
    self.slipLat     = slipLat
    self.contactPos  = contact
    self.contactNorm = normal
    self.lastComp    = comp
end

--------------------------------------------------------------------------
-- Where to draw the wheel, chassis space. The suspension travel means this is
-- NOT simply the mount point.
--------------------------------------------------------------------------
function Wheel:VisualOffset()
    local WC = BMX.Config.Wheel
    local drop = self.onGround
        and (WC.restLength - math.min(self.compression, WC.restLength))
        or WC.restLength
    return self.mount - Vector(0, 0, drop)
end
