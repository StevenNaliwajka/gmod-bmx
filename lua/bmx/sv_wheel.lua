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
        latForce    = 0,      -- kg*u/s^2, read by the balance feed-forward
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
local function effectiveMass(ent, phys, cfg, contact, dir)
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

    return 1 / (1 / cfg.Chassis.mass + invI)
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
function Wheel:Simulate(ent, phys, cfg, dt, driveTorque, brakeTorque, filter)
    local C     = cfg
    local WC    = C.Wheel
    local radius = WC.radius
    local maxLen = BMX.WheelReach(WC)

    local mountWorld = ent:LocalToWorld(self.mount)
    local down       = -ent:GetUp()

    local tr = util.TraceLine({
        start  = mountWorld,
        endpos = mountWorld + down * maxLen,
        filter = filter,
        mask   = MASK_SOLID,
    })

    -- Where the DISC touches, not where the ray landed. See BMX.DiscContact:
    -- the two agree on the level and under lean, and differ under pitch by
    -- exactly the error that was lifting wheelies past their balance point.
    local s, contact
    if tr.Hit then
        s, contact = BMX.DiscContact(mountWorld, down, ent:GetRight(),
            maxLen * tr.Fraction, tr.HitNormal, radius)
    end

    ----------------------------------------------------------------------
    -- Airborne: no ground in reach, or ground the disc cannot touch at full
    -- extension. The ray is longer than the strut so that a pitched wheel can
    -- still find the ground it is sitting on; the price is that a hit is no
    -- longer proof of contact on its own.
    ----------------------------------------------------------------------
    if not s or s > WC.restLength then
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
    local comp   = WC.restLength - s                -- >= 0
    local normal = tr.HitNormal

    local velAt   = phys:GetVelocityAtPoint(contact)

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
        local cap = effectiveMass(ent, phys, cfg, contact, normal) * compVel / dt
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
    local omegaFree = self.omega + (driveTorque / WC.inertia) * dt

    -- A brake-LOCKED wheel is a different constraint, not a stiffer one: the
    -- tyre force reacts into the brake and through it into the chassis, rather
    -- than spinning the wheel. Detected the same way the brake itself decides,
    -- so the two can never disagree.
    local locked = false
    if brakeTorque > 0 then
        local dOmega = brakeTorque / WC.inertia * dt
        if abs(omegaFree) <= dOmega then
            omegaFree = 0                 -- locked: the slip becomes -vFwd,
            locked    = true              -- the tyre saturates, and you skid
        else
            omegaFree = omegaFree - dOmega * (omegaFree > 0 and 1 or -1)
        end
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
    local invCompLong = 1 / effectiveMass(ent, phys, cfg, contact, fwdDir)
    if not locked then
        invCompLong = invCompLong + radius * radius / WC.inertia
    end

    local capLong = abs(slipLong) / (dt * invCompLong)
    if abs(Flong) > capLong then
        Flong = capLong * (Flong >= 0 and 1 or -1)
    end

    local capLat = abs(slipLat) * effectiveMass(ent, phys, cfg, contact, rightDir) / dt
    if abs(Flat) > capLat then
        Flat = capLat * (Flat >= 0 and 1 or -1)
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
    if abs(vFwd) > 1 then
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
        self.omega = omegaFree - (Flong * radius / WC.inertia) * dt
    end

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
    local WC = (cfg or BMX.Config).Wheel
    local drop = self.onGround
        and (WC.restLength - math.min(self.compression, WC.restLength))
        or WC.restLength
    return self.mount - Vector(0, 0, drop)
end
