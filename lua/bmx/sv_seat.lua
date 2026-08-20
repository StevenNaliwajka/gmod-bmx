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

    hook.Run("BMX_RiderMounted", bike, ply)
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
-- Physgun / toolgun etiquette
--------------------------------------------------------------------------

-- Never let anyone grab the seat: it is parented and invisible, and picking it
-- up detaches the rider's frame of reference from the bike in a way that looks
-- like the addon exploding.
hook.Add("PhysgunPickup", "BMX.NoPodGrab", function(ply, ent)
    if ent:GetClass() == "prop_vehicle_prisoner_pod" and ent.BMXBike then
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
concommand.Add("bmx_spawn", function(ply, _, args)
    if not IsValid(ply) then return end

    local id    = args[1] or "stock"
    local class = BMX.ClassFor(id)
    if not class then
        ply:ChatPrint("[BMX] no such bike: " .. id ..
            " (try: " .. table.concat(BMX.BikeIDs(), ", ") .. ")")
        return
    end

    local tr = ply:GetEyeTrace()
    if not tr.Hit or tr.HitPos:Distance(ply:GetPos()) > 400 then
        ply:ChatPrint("[BMX] look at the ground within 400 units.")
        return
    end

    local ent = ents.Create(class)
    if not IsValid(ent) then return end

    ent:SetPos(tr.HitPos + tr.HitNormal * 16 + Vector(0, 0, BMX.Config.Wheel.radius))
    ent:SetAngles(Angle(0, ply:EyeAngles().y, 0))
    ent:Spawn()
    ent:Activate()

    -- Undo history, so a tester can clean up with Z like any other spawn.
    undo.Create("BMX")
        undo.AddEntity(ent)
        undo.SetPlayer(ply)
    undo.Finish()

    if cleanup then cleanup.Add(ply, "bmx", ent) end
end)
