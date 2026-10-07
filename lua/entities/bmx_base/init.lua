AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

--[[--------------------------------------------------------------------------
    entities/bmx_base/init.lua  (server)

    Lifecycle, the seat, and the two events the simulation hands back up:
    OnLanded and Crash.
----------------------------------------------------------------------------]]

util.AddNetworkString("bmx_tricks")

function ENT:Initialize()
    local bike = self:Bike()

    -- THIS BIKE'S config, not the base. There used to be a `local C =
    -- BMX.Config` at file scope, which bound the base table once at LOAD time --
    -- so a per-bike override could never have reached the hull, the mass, or
    -- the wheel mounts no matter what else was threaded through.
    local C = self:Cfg()

    self:SetModel(bike.model)
    -- A procedurally drawn bike's model is a stand-in the client never draws;
    -- its shadow would still be cast, as a floating square under the frame.
    if not bike.hasModel then self:DrawShadow(false) end
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)

    -- The hull is ours, not the model's. A placeholder prop's physics mesh has
    -- nothing to do with a bike, and even a finished BMX model would give a
    -- concave mesh that VPhysics would decompose into something unpredictable.
    -- One box, defined in config, is a hull we can reason about.
    -- The body plus a slim box per wheel, so the ground has something to push
    -- on when the bike is down: see Chassis.wheelHullBottom and
    -- BMX.CollisionBoxes, which also keeps the mass centre where it was.
    self:PhysicsInitMultiConvex(BMX.CollisionMeshes(C))
    self:EnableCustomCollisions(true)
    self:SetCollisionBounds(BMX.CollisionBounds(C))

    -- Opt into GM:ShouldCollide so the rider and the seat can be excluded from
    -- this hull. See the hook in sv_seat.lua: without it, seating a player
    -- inside the chassis is an interpenetration the engine resolves by firing
    -- the bike across the map.
    self:SetCustomCollisionCheck(true)

    -- USE (E) ON THE BIKE GETS YOU ON IT. The seat is an invisible,
    -- non-solid pod, so the use key's trace can never land on it: the only
    -- thing a player looking at a bike can press E on is the bike. With no
    -- Use here, nobody could get on at all except by a script. See ENT:Use.
    self:SetUseType(SIMPLE_USE)

    local phys = self:GetPhysicsObject()
    if not IsValid(phys) then
        ErrorNoHalt("[BMX] physics init failed for " .. tostring(bike.model) ..
            " -- removing\n")
        SafeRemoveEntity(self)
        return
    end

    phys:SetMass(C.Chassis.mass)
    phys:SetMaterial(C.Chassis.surfaceProp)

    -- NOT phys:SetMassCenter(). That function does not exist in GMod: there is
    -- a GetMassCenter and no setter. Calling it threw inside Initialize, which
    -- aborted the rest of this function silently -- the entity came out with
    -- working physics and NO SEAT, and the only visible symptom was a bike
    -- nobody could sit on. The centre of mass is placed by the HULL GEOMETRY
    -- instead (see sh_config.lua), so all this can do is check the result.
    local com = phys:GetMassCenter()
    local want = C.Chassis.massCenterExpected
    if want and com:Distance(want) > 1.5 then
        ErrorNoHalt(string.format(
            "[BMX] mass centre is %s but the hull was meant to put it at %s. " ..
            "Someone changed the hull (hullMin/hullMax or the wheel boxes) without " ..
            "updating massCenterExpected; balance and wheelies are now tuned against " ..
            "the wrong number.\n", tostring(com), tostring(want)))
    end

    -- All damping is ours. VPhysics' built-in drag is tuned for tumbling debris
    -- and fights the tyre model; its angular damping fights the balance
    -- controller. The small angular term left in is a numerical safety net, not
    -- a design choice.
    phys:EnableDrag(false)
    phys:SetDamping(0, 0.1)
    phys:EnableMotion(true)
    phys:Wake()

    -- THIS IS WHAT MAKES PhysicsSimulate RUN. It is not enough to define the
    -- method: ENT:PhysicsSimulate is the MOTION CONTROLLER callback, and
    -- VPhysics only invokes it for physics objects that have been added to one.
    --
    -- Without these two lines the entity is completely well-formed, spawns
    -- normally, has correct mass and a valid hull -- and simply never
    -- simulates. No wheels, no balance, no error. It falls under stock gravity
    -- and tips over, which looks exactly like "the balance controller is
    -- broken" rather than "the balance controller has never once executed".
    -- That cost a full headless test run to find; the harness reported nine
    -- failures whose single common cause was this.
    self:StartMotionController()
    self:AddToMotionController(phys)

    -- Use the REAL moments of inertia, not the estimates in config. The
    -- controllers command an angular acceleration and convert with T = I*alpha,
    -- so a wrong I scales every torque in the addon by the same factor.
    local I, measured = BMX.CacheInertia(self, phys, C)
    if not measured then
        ErrorNoHalt("[BMX] GetInertia returned nothing usable; " ..
            "falling back to the config estimates. Rotation will be off.\n")
    end

    ----------------------------------------------------------------------
    -- Simulation state
    ----------------------------------------------------------------------
    -- MOUNTS SIT restLength ABOVE THE AXLE LINE, and that offset is the whole
    -- suspension. The ray is restLength + radius long and compression is
    -- measured back from its far end, so a mount placed ON the axle line makes
    -- the spring read FULL COMPRESSION at the nominal ride height, with no
    -- travel left in it. Measured consequence of getting this wrong: the bike
    -- sank to 9.12 units of compression against a 2-unit spring, the bump-stop
    -- saw 7 units of overshoot, and the suspension applied 2,623,462 against a
    -- design load of 25,800 -- roughly a hundredfold, which threw the bike
    -- hundreds of units into the air.
    --
    -- With the offset, at rest: mount is 12 - sag above ground, the axle sits
    -- exactly one radius up, and the origin settles at radius - sag.
    --
    -- N WHEELS (G22): the vehicle's own `wheels` list, resolved against this
    -- vehicle's config (a bike's layout is a function of its wheelbase). `pos` is
    -- the axle; the mount is restLength above it, as it always was. A bike's list
    -- is front then rear, so every loop over the wheels sees what it always saw.
    local lift = C.Wheel.restLength
    self.wheels = {}
    for _, wd in ipairs(BMX.WheelDefs(bike, C)) do
        local front = wd.front
        if front == nil then front = wd.pos.x > 0 end
        self.wheels[#self.wheels + 1] = BMX.NewWheel(
            Vector(wd.pos.x, wd.pos.y, wd.pos.z + lift), front, wd)
    end

    -- MORE THAN TWO WHEELS ARE EVALUATED TOGETHER, not one after another.
    -- The wheels apply their forces to the chassis as they go, and a lateral
    -- slip is measured at the patch, so the second wheel of a pair sees the roll
    -- the first one's suspension force just gave the body (a vertical push at
    -- 11 units to the side, 27 below the mass centre, is several u/s of
    -- sideways velocity at the patch). Left and right tyres then answered each
    -- other's disturbance instead of the chassis's real slip, their forces
    -- cancelled, and the test cart crept sideways at 5 u/s for ever. So with
    -- more than two wheels every one reads its patch's velocity from a snapshot
    -- taken before any of them acts (BMX.PhysicsStep passes it), and each
    -- carries only its share of the mass in the tyre's stability caps
    -- (`coupling`, effectiveMass in sv_wheel.lua). A bike -- two wheels in line,
    -- on the centreline, where this never showed -- is exactly as it was.
    local coupling = #self.wheels > 2 and #self.wheels or 1
    for _, w in ipairs(self.wheels) do w.coupling = coupling end

    self.st    = BMX.NewState(C)
    -- Which vehicle this state belongs to, for the trick list (BMX.VehicleAllows).
    self.st.def = bike
    self.input = BMX.BlankInput()

    self.hopCharge  = 0
    self.hopHeld    = false
    self.hopRelease = false
    self.hopReady   = 0
    self.spawnTime  = CurTime()

    self:SetScore(0)

    self:CreateSeat()
    self:RebuildTraceFilter()
    self:AssertBuilt()
end

--------------------------------------------------------------------------
-- The seat.
--
-- A parented prop_vehicle_prisoner_pod. This is the same trick simfphys uses,
-- and it is worth being explicit about WHY rather than treating it as folklore:
-- the pod is the only stock entity that gives Lua a driver reference, an
-- enter/exit flow with working animations, and a usercmd stream, without also
-- dragging in a physics controller that wants to drive.
--------------------------------------------------------------------------
function ENT:CreateSeat()
    -- THE RIDER'S SEAT (`seats` in the registration, BMX.SeatFor): the vehicle's own
    -- model, offset and angles where it gives them, the config's where it does not.
    local pod = self:BuildPod(BMX.SeatFor(self:Bike(), self:Cfg(), "rider"))
    if not IsValid(pod) then return end
    pod.BMXBike = self
    self:SetPod(pod)
end

-- A pod for a seat, parented to the bike. The rider's and a passenger's are made the
-- same way (sv_passenger.lua builds the others, on first boarding).
function ENT:BuildPod(seat)
    local pod = ents.Create("prop_vehicle_prisoner_pod")
    if not IsValid(pod) then return end

    pod:SetModel(seat.model or "models/nova/airboat_seat.mdl")
    -- A prisoner pod without a vehiclescript is not reliably a working vehicle.
    -- It is the keyvalue that gives it its seat definition and exit points.
    pod:SetKeyValue("vehiclescript", "scripts/vehicles/prisoner_pod.txt")
    pod:SetKeyValue("limitview", "0")     -- free look; the chase cam needs it
    pod:SetPos(self:LocalToWorld(seat.offset))
    pod:SetAngles(self:LocalToWorldAngles(seat.angles))
    pod:Spawn()
    pod:Activate()

    pod:SetParent(self)
    pod:SetNoDraw(true)
    pod:SetNotSolid(true)
    pod:DrawShadow(false)

    -- The pod must contribute nothing to the simulation. Left motion-enabled it
    -- is a second physics object bolted to the first, and the pair fight.
    local pp = pod:GetPhysicsObject()
    if IsValid(pp) then
        pp:EnableMotion(false)
        pp:EnableCollisions(false)
    end

    -- The duplicator must not copy the seat in its own right: it is parented to
    -- this entity and Initialize builds a fresh one, so a pasted bike would come
    -- up with two.
    pod.DoNotDuplicate = true

    pod.BMXBike = self
    self:DeleteOnRemove(pod)
    return pod
end

--------------------------------------------------------------------------
-- E on any part of the bike (frame, seat, bars): get on. The hull covers all
-- of them, since it stands in for the rider as well as the frame.
--------------------------------------------------------------------------
function ENT:Use(activator)
    if not IsValid(activator) or not activator:IsPlayer() then return end
    if activator:InVehicle() then return end
    local pod = self:GetPod()
    if not IsValid(pod) then return end
    -- ON A RACK (G13): E lets it down; the next E gets on (sv_rack.lua).
    if self.BMXRack and BMX.Rack then BMX.Rack.Release(self, activator) return end
    -- E ON AN OCCUPIED BIKE is a second rider boarding, at the rear: the pegs, or
    -- the child seat if it is on (sv_passenger.lua). Nothing else about getting on
    -- a ridden bike was ever possible, so nothing changes for anyone else.
    if IsValid(self:GetDriver()) then
        if BMX.Passenger and BMX.Passenger.TryBoard then BMX.Passenger.TryBoard(self, activator) end
        return
    end
    -- (ply, bike) like every public hook that has a rider in it. Through 1.1.0
    -- this was (bike, ply), and the name is the same, so it cannot be kept as
    -- an alias: MODDING.md says so.
    if hook.Run("BMX_CanMount", activator, self) == false then return end
    if activator.BMXTumbling or self.pickingUp then return end
    -- A bike lying down is picked up first, where the player can see it
    -- (BMX.BeginPickUp), and they get on at the end of it.
    if BMX.IsFallen(self) then
        BMX.BeginPickUp(self, activator)
        return
    end
    activator:EnterVehicle(pod)
end

-- Fail LOUDLY rather than half-built. A bike whose Initialize died partway
-- through still spawns, still has physics, and still looks completely normal
-- until someone presses E on it and nothing happens. That cost an afternoon
-- once; it should never cost one again.
function ENT:AssertBuilt()
    local why
    if not IsValid(self:GetPod())              then why = "no seat (CreateSeat failed)"
    elseif not self.wheels or #self.wheels ~= #BMX.WheelDefs(self:Bike(), self:Cfg()) then
        why = "wheels missing"
    elseif not self.st                          then why = "no controller state"
    elseif not self.input                       then why = "no input table"
    elseif not IsValid(self:GetPhysicsObject()) then why = "no physics object"
    end
    if why then
        ErrorNoHalt("[BMX] bike " .. self:EntIndex() ..
            " is half-built: " .. why .. ". Something threw inside Initialize.\n")
        return false
    end
    return true
end

-- Everything the wheel traces must ignore. Rebuilt whenever the driver changes,
-- because a trace that hits the rider standing in their own seat reads as
-- ground and the bike levitates on its own passenger.
function ENT:RebuildTraceFilter()
    local f = { self, self:GetPod() }
    local d = self:GetDriver()
    if IsValid(d) then f[#f + 1] = d end
    -- ...and whoever is riding with them, and the pods they sit in.
    for _, pod in pairs(self.paxPods or {}) do
        if IsValid(pod) then f[#f + 1] = pod end
    end
    for _, ply in pairs(self.passengers or {}) do
        if IsValid(ply) then f[#f + 1] = ply end
    end
    self.traceFilter = f
end

--------------------------------------------------------------------------
-- Physics
--
-- PhysicsSimulate is the only hook in GMod called once per VPhysics SUBSTEP
-- with that substep's dt. Think runs at frame rate with a dt that varies with
-- server load, which is not something a PD controller can be tuned against.
--
-- Forces are applied inside via ApplyForceOffset / ApplyForceCenter rather than
-- returned as an acceleration triple, so SIM_NOTHING is the correct return: it
-- tells VPhysics we are not overriding its integration, only adding to it.
--------------------------------------------------------------------------
function ENT:PhysicsSimulate(phys, dt)
    BMX.PhysicsStep(self, phys, dt)
    return SIM_NOTHING
end

--------------------------------------------------------------------------
-- Housekeeping. Deliberately NOT the physics: this runs at frame rate.
--------------------------------------------------------------------------
function ENT:Think()
    local st = self.st
    if st then
        -- Networked state, for the HUD and for drawing the fork. These are
        -- floats that change every tick, so they are pushed at 20 Hz rather
        -- than at physics rate: nothing on the client is sensitive to the
        -- difference and the bandwidth is 3x lower.
        self:SetSpeedUPS(st.speed)
        self:SetGrounded(st.grounded)
        self:SetSteer(st.steer)
        self:SetStamina(st.stamina)
        self:SetCadence(st.cadence)
        self:SetSprinting(st.sprinting or false)
        self:SetLeanFwd(st.leanFwd or 0)
        self:SetHopCharge(self.hopHeld
            and math.min(1, (self.hopCharge or 0) / self:Cfg().Hop.chargeTime) or 0)
    end

    -- FALLEN OVER: the hull grips instead of skating (Chassis.fallenSurfaceProp).
    -- Switched only when the state changes; a physics material is not
    -- something to set twenty times a second.
    if st then
        local C = self:Cfg()
        local fallen = math.abs(st.roll or 0) > C.Stand.maxRoll
            or math.abs(st.pitch or 0) > C.Stand.maxRoll
        if fallen ~= (self.bmxFallen or false) then
            self.bmxFallen = fallen
            local phys = self:GetPhysicsObject()
            if IsValid(phys) then
                phys:SetMaterial(fallen and C.Chassis.fallenSurfaceProp or C.Chassis.surfaceProp)
            end
        end
    end

    -- Is anybody leaning on it? A parked bike's hold lets go while a player
    -- is touching it (see 7c in sv_physics.lua). Checked here at 20 Hz, not
    -- per substep: a box query per substep for every bike on a server is
    -- real cost, and a push lasts far longer than a twentieth of a second.
    if st and not IsValid(self:GetDriver()) then
        local C = self:Cfg().Chassis
        local lmin, lmax = BMX.CollisionBounds(self:Cfg())
        local mn, mx = self:BoundsWorld(lmin, lmax, 8)
        for _, e in ipairs(ents.FindInBox(mn, mx)) do
            -- Standing ON the bike is not pushing it. Letting the hold go
            -- then let the bike shift under their feet, and a player a prop
            -- moves into gets stuck in it; held still, it is just something
            -- to stand on and walk off.
            if e:IsPlayer() and not e:InVehicle() and e:GetGroundEntity() ~= self then
                st.pushedUntil = CurTime() + 0.6
                break
            end
        end
    end

    -- Water: which wheels and whether the rider's chest is under (20 Hz).
    if st and BMX.Water then BMX.Water.Think(self) end

    -- Live tuning. Reading a dozen convars 20 times a second is free and it
    -- means a tuner sees a change immediately instead of respawning the bike.
    BMX.ApplyConVars()

    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:Wake() end

    self:NextThink(CurTime() + 0.05)
    return true
end

--------------------------------------------------------------------------
-- Landing
--------------------------------------------------------------------------
function ENT:OnLanded(tricks, front, rear)
    -- TYRES FIRST, because the landing is heard before it is judged.
    --
    -- An event, not a state, so it is a server-side one-shot rather than
    -- anything in cl_sound.lua: it happens once, at a moment only the server
    -- knows. Soft or hard is chosen by how fast the bike was coming down, which
    -- is the same number JudgeLanding is about to use to decide whether this
    -- was a landing at all.
    local phys = self:GetPhysicsObject()
    local fall = IsValid(phys) and math.abs(math.min(phys:GetVelocity().z, 0)) or 0

    if fall > 40 and BMX.SoundsOn() then
        local key = fall > 320 and "land_hard" or "land_soft"
        local L   = BMX.Sounds[key]
        self:EmitSound(BMX.SoundFile(key), L.level, math.random(94, 106),
            L.vol * math.Clamp(fall / 600, 0.25, 1))
    end

    -- Trick scoring: a trick that ends in a crash should still be
    -- reported, it just should not pay.
    local crashed, severity, reason = self:JudgeLanding(front, rear)

    if not crashed and #tricks > 0 then
        self:AwardTricks(tricks)
    elseif #tricks > 0 then
        hook.Run("BMX_TricksBailed", self, self:GetDriver(), tricks)
    end

    if crashed then
        self:Crash(reason, severity)
    else
        -- Landed on the wheels: help it back up (Crash.recoverTime).
        self.st.recoverUntil = CurTime() + self:Cfg().Crash.recoverTime
    end
end

-- Pay out a completed trick list, from the air (OnLanded) or the ground (a
-- held wheelie or stoppie, see BMX.TrackManual). One path, so a gamemode
-- listening on BMX_TricksLanded hears about both kinds the same way.
function ENT:AwardTricks(tricks)
    -- bmx_scoring 0 (sv_rules.lua): a server that does not want scoring gets
    -- none of it -- no points, no callout, no combo -- rather than a score
    -- nobody can see going up.
    if BMX.ScoringEnabled and not BMX.ScoringEnabled() then return 0 end

    -- THE MULTIPLIER: the vehicle's own (`scoreMult`: the road bike's x1.5) times
    -- a passenger's (x2, sv_passenger.lua), applied to every trick HERE so that
    -- the score, the callout, the public hook and the combo's chain all see the
    -- same number. On copies: the caller's list is not ours to rewrite.
    local mult = (self:Bike().scoreMult or 1) * (BMX.PassengerScoreMult and BMX.PassengerScoreMult(self) or 1)
    if mult ~= 1 then
        local scaled = {}
        for i, t in ipairs(tricks) do
            local c = {}
            for k, v in pairs(t) do c[k] = v end
            c.points = math.floor((t.points or 0) * mult + 0.5)
            scaled[i] = c
        end
        tricks = scaled
    end
    local total = 0
    for _, t in ipairs(tricks) do total = total + t.points end
    if total <= 0 then return 0 end

    self:SetScore(self:GetScore() + total)
    -- One public BMX_TrickLanded per trick (docs/MODDING.md), so a scoreboard
    -- hook never has to unpack a list; the whole-landing BMX_TricksLanded
    -- stays for one version as the alias.
    local rider = self:GetDriver()
    if IsValid(rider) then
        for _, t in ipairs(tricks) do
            hook.Run("BMX_TrickLanded", rider, t, t.points or 0, self)
        end
    end
    hook.Run("BMX_TricksLanded", self, rider, tricks, total)
    self:SendTrickCallout(tricks, total)
    if BMX.ComboAdd then BMX.ComboAdd(self, tricks) end
    return total
end

-- Tell the rider what they just did. Only the rider: a callout is feedback on
-- your own input, and broadcasting every hop on a busy server would be both
-- noisy and a steady trickle of bandwidth for something nobody else is reading.
function ENT:SendTrickCallout(tricks, total)
    local ply = self:GetDriver()
    if not IsValid(ply) then return end

    net.Start("bmx_tricks", true)
        net.WriteUInt(math.min(#tricks, 7), 3)
        for i = 1, math.min(#tricks, 7) do
            net.WriteString(tricks[i].name)
            net.WriteUInt(math.min(tricks[i].count, 15), 4)
            net.WriteUInt(math.min(tricks[i].points, 65535), 16)
        end
        net.WriteUInt(math.min(total, 1048575), 20)
    net.Send(ply)
end

-- Was that a landing or an accident?
function ENT:JudgeLanding(front, rear)
    local CR = self:Cfg().Crash
    if not CR.enabled then return false end
    if CurTime() - (self.spawnTime or 0) < CR.grace then return false end

    local st = self.st
    local n  = st.groundNormal

    -- How far off the surface are we? acos of the dot product is the angle
    -- between "which way is up for the bike" and "which way is up for the
    -- ground", which is exactly the quantity a rider judges by eye.
    local off = math.acos(BMX.Clamp(self:GetUp():Dot(n), -1, 1))
    if off > CR.maxLandAngle then
        local sev = (off - CR.maxLandAngle) / (math.pi - CR.maxLandAngle)
        return true, sev, "angle"
    end

    -- Landing sideways. Cheap to check and it catches the case the angle test
    -- misses entirely: a perfectly upright bike arriving with all its velocity
    -- across the tyres.
    -- A PART OUT OF LINE, OR A POSE STILL HELD (sv_tricks.lua): the frame or
    -- the bars more than Tricks.partMaxOut from a whole turn means the bike
    -- is not rideable, and a rider still in a pose has no hands or feet where
    -- they need them. Both go the way every bad landing goes, so the combo is
    -- lost and the tricks do not pay.
    local why, sev = BMX.LandingFault and BMX.LandingFault(st)
    if why then return true, sev, why end

    local lat = math.max(math.abs(front.slipLat or 0), math.abs(rear.slipLat or 0))
    if CR.maxLandLateral and lat > CR.maxLandLateral then
        return true, BMX.Clamp((lat - CR.maxLandLateral) / CR.maxLandLateral, 0, 1), "sideways"
    end

    return false
end

--------------------------------------------------------------------------
-- Crash: throw the rider off.
--------------------------------------------------------------------------
function ENT:Crash(reason, severity)
    -- A crash loses the combo's bonus (sv_combo.lua), while the rider is
    -- still aboard to be told so.
    if BMX.ComboEnd then BMX.ComboEnd(self, false) end
    local ply = self:GetDriver()
    if not IsValid(ply) then return end

    severity = BMX.Clamp(severity or 0.5, 0, 1)
    -- For anything that wants to know why a rider came off (the bot's log,
    -- a server's stats): before the rider is thrown, while they are aboard.
    hook.Run("BMX_Crashed", self, ply, reason, severity)

    local CR   = self:Cfg().Crash
    local phys = self:GetPhysicsObject()
    local vel  = IsValid(phys) and phys:GetVelocity() or Vector()

    -- Let a gamemode veto or replace this entirely: "throw the rider" is one
    -- opinion about what a crash is, and a deathrun server will have another.
    if hook.Run("BMX_Crash", self, ply, reason, severity) == false then return end

    self.bmxCrashing = true             -- a thrown rider puts no stand down
    ply:ExitVehicle()

    -- A passenger goes too (sv_passenger.lua): thrown with the bike's momentum and
    -- ragdolled the same way, BMX_RiderCrashed fired for each. After the veto above,
    -- so a gamemode that keeps the rider on keeps the passenger on.
    if BMX.Passenger and BMX.Passenger.Eject then BMX.Passenger.Eject(self, vel, severity) end

    local throw = vel + Vector(0, 0, CR.ejectLift * severity)
    -- OVER THE BARS (G13, the penny-farthing's header): a crash that says where the rider
    -- goes adds it to the throw, once.
    if self.crashBoost then throw = throw + self.crashBoost self.crashBoost = nil end
    local dmg = math.floor(severity * vel:Length() * CR.damageScale)
    local bike = self
    local function hurt()
        if not IsValid(ply) or dmg <= 1 then return end
        local d = DamageInfo()
        d:SetDamage(dmg)
        d:SetDamageType(DMG_FALL)
        d:SetAttacker(IsValid(bike) and bike or ply)
        d:SetInflictor(IsValid(bike) and bike or ply)
        ply:TakeDamageInfo(d)
    end

    timer.Simple(0, function()
        if not IsValid(ply) then return end
        -- Thrown as a RAGDOLL for a moment (BMX.Tumble, sv_seat.lua), so a
        -- rider comes off the bike as a body rather than sliding out of it
        -- standing up. Hurt when they get up, so the damage lands on the
        -- player and not on a ragdoll. bmx_crash_ragdoll 0 is the old shove.
        -- Somebody else's ragdoll first. BMX_RiderCrashed(ply, vel, bike) lets
        -- ANY ragdoll addon take the rider without us knowing about each one:
        -- return true from it and the rider is yours. Then RagMod, if
        -- installed (sv_compat_ragmod.lua; false on any problem). Damage still
        -- lands either way, straight away: there is no get-up of ours to wait for.
        if hook.Run("BMX_RiderCrashed", ply, throw, bike) == true
            or (BMX.Compat and BMX.Compat.Ragdoll and BMX.Compat.Ragdoll(ply, throw)) then
            hurt()
            return
        end
        if GetConVar("bmx_crash_ragdoll"):GetBool() and BMX.Tumble(ply, throw, hurt) then
            return
        end
        ply:SetVelocity(throw)
        hurt()
    end)

    local CS = BMX.Sounds.crash
    if BMX.SoundsOn() then self:EmitSound(BMX.SoundFile("crash"), CS.level, 100, CS.vol) end
end

--------------------------------------------------------------------------
-- Hitting something hard enough that the landing check is beside the point.
--------------------------------------------------------------------------
function ENT:PhysicsCollide(data, phys)
    local CR = self:Cfg().Crash
    if not CR.enabled then return end
    if data.Speed < CR.maxImpactSpeed then return end
    if CurTime() - (self.spawnTime or 0) < CR.grace then return end

    -- NOT A CRASH ON A RAIL. A grind puts the frame on the rail on purpose,
    -- and hopping off still scrapes it for a moment.
    local st0 = self.st
    if st0 and (st0.grind or CurTime() - (st0.grindEnded or -1e9) < 0.3) then return end

    -- NOT A CRASH IF IT LANDED ON ITS WHEELS. The wheels have collision
    -- boxes now (Chassis.wheelHullBottom), and a hard landing that bottoms
    -- the suspension out meets the ground with them, at speed. That is the
    -- tyres doing their job. A hit below the body box with the bike upright
    -- is a landing; anything else is the frame or the rider hitting
    -- something.
    local C = self:Cfg()
    if data.HitPos then
        local loc = self:WorldToLocal(data.HitPos)
        local body = BMX.CollisionBoxes(C)[1]
        local roll, pitch = BMX.Attitude(self, vector_up)
        if loc.z < body[1].z and math.abs(roll) < C.Crash.maxLandAngle
            and math.abs(pitch) < C.Crash.maxLandAngle then
            -- A landing, found by the collision before the suspension saw
            -- it: let the next substep stick it (sv_physics.lua, 4b).
            if self.st and self.st.airMode then self.bmxTouchdown = true end
            return
        end
    end
    --
    -- NEXT TICK, NOT NOW. This is a VPhysics collision callback, and Crash
    -- takes the rider out of the vehicle: changing what collides with what
    -- from inside the callback is the thing GMod prints "Changing collision
    -- rules within a callback is likely to cause crashes!" about, and a crash
    -- of the server kind is not the crash this is modelling. One impact also
    -- reports several contacts in the same step, so the pending flag keeps it
    -- to one ejection.
    self:QueueCrash("impact", BMX.Clamp(data.Speed / (CR.maxImpactSpeed * 3), 0, 1))
end

-- A crash decided inside a physics callback (a collision, or the substep
-- that notices the bike has tipped over) happens on the NEXT tick, once:
-- taking a rider out of a vehicle from inside VPhysics is how servers crash.
function ENT:QueueCrash(reason, severity)
    if self.crashPending then return end
    self.crashPending = true
    timer.Simple(0, function()
        if not IsValid(self) then return end
        self.crashPending = false
        self:Crash(reason, severity)
    end)
end

--------------------------------------------------------------------------
-- Spawn menu placement: drop the bike a little above the aim point, upright and
-- facing away from the spawner, so it lands on its wheels instead of arriving
-- inside the floor.
--------------------------------------------------------------------------
function ENT:SpawnFunction(ply, tr, class)
    if not tr.Hit then return end

    local ang = Angle(0, ply:EyeAngles().y, 0)
    local ent = ents.Create(class)
    ent:SetPos(tr.HitPos + tr.HitNormal * (BMX.RestHeight(ent:Cfg()) + 0.5))
    ent:SetAngles(ang)
    ent:Spawn()
    ent:Activate()
    BMX.PaintAsPreferred(ent, ply)
    return ent
end

-- The world-space box around a local box, grown by `pad` on every side.
function ENT:BoundsWorld(lmin, lmax, pad)
    local mn = Vector(math.huge, math.huge, math.huge)
    local mx = -mn
    for _, x in ipairs({ lmin.x, lmax.x }) do
        for _, y in ipairs({ lmin.y, lmax.y }) do
            for _, z in ipairs({ lmin.z, lmax.z }) do
                local p = self:LocalToWorld(Vector(x, y, z))
                mn = Vector(math.min(mn.x, p.x), math.min(mn.y, p.y), math.min(mn.z, p.z))
                mx = Vector(math.max(mx.x, p.x), math.max(mx.y, p.y), math.max(mx.z, p.z))
            end
        end
    end
    local g = Vector(pad, pad, pad)
    return mn - g, mx + g
end

function ENT:OnRemove()
    local pod = self:GetPod()
    if IsValid(pod) then SafeRemoveEntity(pod) end
    -- Whatever it was carrying is the world's again (sv_basket.lua).
    if self.basketHeld and BMX.Basket then BMX.Basket.Release(self, "removed") end
end
