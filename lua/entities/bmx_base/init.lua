AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

--[[--------------------------------------------------------------------------
    entities/bmx_base/init.lua  (server)

    Lifecycle, the seat, and the two events the simulation hands back up:
    OnLanded and Crash.
----------------------------------------------------------------------------]]

local C = BMX.Config

util.AddNetworkString("bmx_tricks")

function ENT:Initialize()
    local bike = self:Bike()

    self:SetModel(bike.model)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)

    -- The hull is ours, not the model's. A placeholder prop's physics mesh has
    -- nothing to do with a bike, and even a finished BMX model would give a
    -- concave mesh that VPhysics would decompose into something unpredictable.
    -- One box, defined in config, is a hull we can reason about.
    self:PhysicsInitBox(C.Chassis.hullMin, C.Chassis.hullMax)
    self:SetCollisionBounds(C.Chassis.hullMin, C.Chassis.hullMax)

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
            "Someone changed hullMin/hullMax without updating " ..
            "massCenterExpected; balance and wheelies are now tuned against " ..
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

    ----------------------------------------------------------------------
    -- Simulation state
    ----------------------------------------------------------------------
    local half = C.Wheel.wheelbase * 0.5
    self.wheels = {
        BMX.NewWheel(Vector( half, 0, 0), true),   -- front
        BMX.NewWheel(Vector(-half, 0, 0), false),  -- rear
    }

    self.st    = BMX.NewState()
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
    local bike = self:Bike()

    local pod = ents.Create("prop_vehicle_prisoner_pod")
    if not IsValid(pod) then return end

    pod:SetModel(bike.seatModel or "models/nova/airboat_seat.mdl")
    -- A prisoner pod without a vehiclescript is not reliably a working vehicle.
    -- It is the keyvalue that gives it its seat definition and exit points.
    pod:SetKeyValue("vehiclescript", "scripts/vehicles/prisoner_pod.txt")
    pod:SetKeyValue("limitview", "0")     -- free look; the chase cam needs it
    pod:SetPos(self:LocalToWorld(C.Chassis.seatOffset))
    pod:SetAngles(self:LocalToWorldAngles(C.Chassis.seatAngles))
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

    pod.BMXBike = self
    self:SetPod(pod)
    self:DeleteOnRemove(pod)
end

-- Fail LOUDLY rather than half-built. A bike whose Initialize died partway
-- through still spawns, still has physics, and still looks completely normal
-- until someone presses E on it and nothing happens. That cost an afternoon
-- once; it should never cost one again.
function ENT:AssertBuilt()
    local why
    if not IsValid(self:GetPod())              then why = "no seat (CreateSeat failed)"
    elseif not self.wheels or #self.wheels ~= 2 then why = "wheels missing"
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
        self:SetHopCharge(self.hopHeld
            and math.min(1, (self.hopCharge or 0) / C.Hop.chargeTime) or 0)
    end

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
    -- Trick scoring first: a trick that ends in a crash should still be
    -- reported, it just should not pay.
    local crashed, severity, reason = self:JudgeLanding(front, rear)

    if not crashed and #tricks > 0 then
        local total = 0
        for _, t in ipairs(tricks) do total = total + t.points end
        self:SetScore(self:GetScore() + total)

        hook.Run("BMX_TricksLanded", self, self:GetDriver(), tricks, total)
        self:SendTrickCallout(tricks, total)
    elseif #tricks > 0 then
        hook.Run("BMX_TricksBailed", self, self:GetDriver(), tricks)
    end

    if crashed then
        self:Crash(reason, severity)
    end
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
    local CR = BMX.Config.Crash
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
    local lat = math.max(math.abs(front.slipLat or 0), math.abs(rear.slipLat or 0))
    if lat > CR.maxLandLateral then
        return true, BMX.Clamp((lat - CR.maxLandLateral) / CR.maxLandLateral, 0, 1), "sideways"
    end

    return false
end

--------------------------------------------------------------------------
-- Crash: throw the rider off.
--------------------------------------------------------------------------
function ENT:Crash(reason, severity)
    local ply = self:GetDriver()
    if not IsValid(ply) then return end

    severity = BMX.Clamp(severity or 0.5, 0, 1)

    local CR   = BMX.Config.Crash
    local phys = self:GetPhysicsObject()
    local vel  = IsValid(phys) and phys:GetVelocity() or Vector()

    -- Let a gamemode veto or replace this entirely: "throw the rider" is one
    -- opinion about what a crash is, and a deathrun server will have another.
    if hook.Run("BMX_Crash", self, ply, reason, severity) == false then return end

    ply:ExitVehicle()

    timer.Simple(0, function()
        if not IsValid(ply) then return end
        ply:SetVelocity(vel + Vector(0, 0, CR.ejectLift * severity))

        local dmg = math.floor(severity * vel:Length() * CR.damageScale)
        if dmg > 1 then
            local d = DamageInfo()
            d:SetDamage(dmg)
            d:SetDamageType(DMG_FALL)
            d:SetAttacker(IsValid(self) and self or ply)
            d:SetInflictor(IsValid(self) and self or ply)
            ply:TakeDamageInfo(d)
        end
    end)

    self:EmitSound("physics/metal/metal_box_impact_hard" ..
        math.random(1, 3) .. ".wav", 80, 100, 1)
end

--------------------------------------------------------------------------
-- Hitting something hard enough that the landing check is beside the point.
--------------------------------------------------------------------------
function ENT:PhysicsCollide(data, phys)
    local CR = BMX.Config.Crash
    if not CR.enabled then return end
    if data.Speed < CR.maxImpactSpeed then return end
    if CurTime() - (self.spawnTime or 0) < CR.grace then return end

    -- Not a crash if we merely landed on our wheels hard: the wheels are
    -- raycasts and do not generate collisions, so any hull collision at speed
    -- is genuinely the frame or the rider hitting something.
    self:Crash("impact", BMX.Clamp(data.Speed / (CR.maxImpactSpeed * 3), 0, 1))
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
    ent:SetPos(tr.HitPos + tr.HitNormal * 16 + Vector(0, 0, BMX.Config.Wheel.radius))
    ent:SetAngles(ang)
    ent:Spawn()
    ent:Activate()
    return ent
end

function ENT:OnRemove()
    local pod = self:GetPod()
    if IsValid(pod) then SafeRemoveEntity(pod) end
end
