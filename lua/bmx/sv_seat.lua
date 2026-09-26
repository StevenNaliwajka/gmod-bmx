--[[--------------------------------------------------------------------------
    bmx/sv_seat.lua

    Binding a player to a bike, and unbinding them again in every way it can
    happen: getting off, dying, disconnecting, or the bike being removed
    underneath them.

    These are global hooks rather than entity methods because PlayerEnteredVehicle
    and friends fire on the gamemode, not on the vehicle, and because the unbind
    path has to survive the bike already being NULL.
----------------------------------------------------------------------------]]

BMX = BMX or {}

local function bind(ply, bike)
    if not IsValid(ply) or not IsValid(bike) then return end

    bike:SetDriver(ply)
    ply.BMXBike = bike

    -- A fresh input table per rider. Reusing the old one hands the new rider
    -- the previous one's half-held brake, which is a bug that only shows up on
    -- a busy server and is miserable to track down.
    bike.input = BMX.BlankInput()
    bike.hopHeld, bike.hopRelease, bike.hopCharge = false, false, 0

    -- Re-arm the crash grace period. Mounting a bike that is mid-tumble should
    -- not immediately throw the person who just got on it.
    bike.spawnTime = CurTime()

    bike:RebuildTraceFilter()

    local phys = bike:GetPhysicsObject()
    if IsValid(phys) then phys:Wake() end

    BMX.PickUp(bike)

    hook.Run("BMX_RiderMounted", bike, ply)
end

--------------------------------------------------------------------------
-- Getting on a bike that is lying on its side picks it up, as a rider would.
--
-- Nothing else can: the kickstand and the foot (C.Stand) only hold a bike
-- that is still up, and the lean assist needs speed. Before this, a bike that
-- had been knocked over or crashed was scenery for the rest of the map.
--
-- Stood up where it lies, facing the way it was pointing, lifted clear of
-- the ground and stopped, with the controller's history reset so the first
-- substep does not read the righting as a roll rate of hundreds of degrees a
-- second.
--------------------------------------------------------------------------
function BMX.PickUp(bike)
    if not IsValid(bike) or not bike.st then return false end
    local roll, pitch = BMX.Attitude(bike, vector_up)
    local S = bike:Cfg().Stand
    if math.abs(roll) < S.maxRoll and math.abs(pitch) < S.maxRoll then return false end

    local phys = bike:GetPhysicsObject()
    local fwd = bike:GetForward()
    local yaw = (math.abs(fwd.x) + math.abs(fwd.y) > 1e-3)
        and math.deg(math.atan2(fwd.y, fwd.x)) or bike:GetAngles().y

    bike:SetAngles(Angle(0, yaw, 0))
    bike:SetPos(bike:GetPos() + Vector(0, 0, bike:Cfg().Wheel.radius + 4))
    if IsValid(phys) then
        phys:SetVelocity(vector_origin)
        phys:SetAngleVelocity(vector_origin)
        phys:Wake()
    end

    local st = bike.st
    st.lastRoll, st.lastPitch, st.roll, st.pitch = 0, 0, 0, 0
    st.rollRate, st.pitchRate = 0, 0
    st.prevF, st.prevR, st.prevU = nil, nil, nil
    return true
end

local function unbind(ply, bike)
    bike = IsValid(bike) and bike or (IsValid(ply) and ply.BMXBike)

    if IsValid(ply) then ply.BMXBike = nil end

    if IsValid(bike) then
        bike:SetDriver(NULL)
        bike.input = BMX.BlankInput()
        bike.hopHeld, bike.hopRelease, bike.hopCharge = false, false, 0
        bike:RebuildTraceFilter()
        hook.Run("BMX_RiderDismounted", bike, ply)
    end
end

BMX.BindRider   = bind
BMX.UnbindRider = unbind

hook.Add("PlayerEnteredVehicle", "BMX.Mount", function(ply, veh)
    if IsValid(veh) and IsValid(veh.BMXBike) then
        bind(ply, veh.BMXBike)
    end
end)

hook.Add("PlayerLeaveVehicle", "BMX.Dismount", function(ply, veh)
    if IsValid(veh) and veh.BMXBike then
        unbind(ply, veh.BMXBike)
    end
end)

-- Dying in the seat does not always fire PlayerLeaveVehicle depending on the
-- gamemode, and a bike left holding a dead player's entity keeps steering.
hook.Add("PlayerDeath", "BMX.DismountOnDeath", function(ply)
    if IsValid(ply.BMXBike) then unbind(ply, ply.BMXBike) end
end)

hook.Add("PlayerDisconnected", "BMX.DismountOnDisconnect", function(ply)
    if IsValid(ply.BMXBike) then unbind(ply, ply.BMXBike) end
end)

--------------------------------------------------------------------------
-- THE RIDER MUST NOT COLLIDE WITH THE BIKE THEY ARE SITTING ON.
--
-- The chassis hull is deliberately tall enough to stand in for the rider's
-- body, and the seat sits inside it. So the moment a player is placed in the
-- pod, their own ~32x32x72 hull is interpenetrating the bike's, and the engine
-- resolves that the way it resolves any deep overlap: by pushing the two apart
-- as hard as it takes.
--
-- Measured before this existed: mounting a stationary, settled bike put it at
-- 88 u/s and airborne within one frame, and 500 units below the map shortly
-- after. Every downstream case failed for reasons that looked like physics
-- tuning -- the bike could not accelerate, could not hold a lean, could not
-- wheelie -- when in fact it was simply never on the ground after a rider got
-- on it.
--
-- SetCustomCollisionCheck(true) on the bike is what makes this hook get asked.
--------------------------------------------------------------------------
hook.Add("ShouldCollide", "BMX.RiderPassthrough", function(a, b)
    if not IsValid(a) or not IsValid(b) then return end

    local bike, other
    if a.IsBMX then bike, other = a, b
    elseif b.IsBMX then bike, other = b, a
    else return end

    if other == bike:GetPod() or other == bike:GetDriver() then
        return false
    end
end)

--------------------------------------------------------------------------
-- Physgun / toolgun etiquette
--------------------------------------------------------------------------

-- Never let anyone grab the seat: it is parented and invisible, and picking it
-- up detaches the rider's frame of reference from the bike in a way that looks
-- like the addon exploding.
hook.Add("PhysgunPickup", "BMX.NoPodGrab", function(ply, ent)
    if ent:GetClass() == "prop_vehicle_prisoner_pod" and ent.BMXBike then
        return false
    end
    -- AND NOT A BIKE WITH SOMEBODY ON IT. Holding a bike in the physgun puts
    -- its physics object under the engine's shadow controller while
    -- PhysicsSimulate keeps applying suspension and tyre forces to it every
    -- substep, and the rider is in a pod parented to the whole argument. There
    -- is no useful behaviour to define here, only degrees of mess, so the
    -- answer is no while it is occupied. An empty bike picks up normally.
    if ent.IsBMX and IsValid(ent:GetDriver()) then
        return false
    end
end)

-- Same reasoning for the gravity gun, which is the one a stranger on a public
-- server will actually reach for.
hook.Add("GravGunPickupAllowed", "BMX.NoGrabRidden", function(ply, ent)
    if not IsValid(ent) then return end
    if ent:GetClass() == "prop_vehicle_prisoner_pod" and ent.BMXBike then
        return false
    end
    if ent.IsBMX and IsValid(ent:GetDriver()) then
        return false
    end
end)

hook.Add("GravGunPunt", "BMX.NoPuntRidden", function(ply, ent)
    if IsValid(ent) and ent.IsBMX and IsValid(ent:GetDriver()) then
        return false
    end
end)

-- Dropping a bike out of the physgun should leave it awake, or it lands and
-- goes to sleep before the first PhysicsSimulate and never wakes.
hook.Add("PhysgunDrop", "BMX.WakeOnDrop", function(_, ent)
    if IsValid(ent) and ent.IsBMX then
        local phys = ent:GetPhysicsObject()
        if IsValid(phys) then phys:Wake() end
    end
end)

--------------------------------------------------------------------------
-- Spawning from the console, which is how you will actually test this.
--------------------------------------------------------------------------
--
-- IT ASKS THE GAMEMODE FIRST, exactly as the spawn menu does. The spawn menu
-- routes every entity through PlayerSpawnSENT, which is where sandbox applies
-- sbox_maxsents and where a server's admin mod applies its restrictions. A
-- console command that skipped it was a way round both: anyone on a public
-- server could type bmx_spawn in a loop. PlayerSpawnedSENT afterwards is what
-- counts the bike against that limit.
local SPAWN_COOLDOWN = 1.0

if cleanup then cleanup.Register("bmx") end

concommand.Add("bmx_spawn", function(ply, _, args)
    if not IsValid(ply) then return end

    local id    = args[1] or "stock"
    local class = BMX.ClassFor(id)
    if not class then
        ply:ChatPrint("[BMX] no such bike: " .. id ..
            " (try: " .. table.concat(BMX.BikeIDs(), ", ") .. ")")
        return
    end

    if CurTime() < (ply.BMXNextSpawn or 0) then return end
    ply.BMXNextSpawn = CurTime() + SPAWN_COOLDOWN

    if hook.Run("PlayerSpawnSENT", ply, class) == false then return end

    local tr = ply:GetEyeTrace()
    if not tr.Hit or tr.HitPos:Distance(ply:GetPos()) > 400 then
        ply:ChatPrint("[BMX] look at the ground within 400 units.")
        return
    end

    local ent = ents.Create(class)
    if not IsValid(ent) then return end

    ent:SetPos(tr.HitPos + tr.HitNormal * 16 + Vector(0, 0, ent:Cfg().Wheel.radius))
    ent:SetAngles(Angle(0, ply:EyeAngles().y, 0))
    ent:Spawn()
    ent:Activate()

    hook.Run("PlayerSpawnedSENT", ply, ent)

    -- Undo history, so a tester can clean up with Z like any other spawn.
    undo.Create("BMX")
        undo.AddEntity(ent)
        undo.SetPlayer(ply)
    undo.Finish()

    if cleanup then cleanup.Add(ply, "bmx", ent) end
end)
