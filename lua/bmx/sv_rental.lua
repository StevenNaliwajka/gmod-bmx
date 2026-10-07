--[[--------------------------------------------------------------------------
    bmx/sv_rental.lua

    The server half of the bike rental (sh_rental.lua says what it is).
    BMX.Rental.Rent is the one door: the machine's window and the tests both
    use it, and it returns (vehicle) or (nil, why).
----------------------------------------------------------------------------]]

local R = BMX.Rental

util.AddNetworkString(R.NET_OPEN)
util.AddNetworkString(R.NET_RENT)

R.Out = R.Out or {}     -- vehicle -> true, every rental that is out

local function refuse(ply, why)
    if IsValid(ply) then ply:ChatPrint("[BMX] " .. why) end
    return nil, why
end

-- Give the player's rental back: their vehicle is removed (a rider who is not
-- the renter is put off it first).
function R.Return(ply)
    local old = IsValid(ply) and ply.BMXRental
    if IsValid(old) then
        local d = old.GetDriver and old:GetDriver()
        if IsValid(d) then d:ExitVehicle() end
        R.Out[old] = nil
        old:Remove()
    end
    if IsValid(ply) then ply.BMXRental = nil end
end

function R.Rent(ply, machine, id)
    if not IsValid(ply) then return nil, "no player" end
    if not (IsValid(machine) and machine.IsBMXRental) then return nil, "not a rental machine" end
    if ply:GetPos():Distance(machine:GetPos()) > R.REACH then
        return refuse(ply, "walk up to the rental machine first.")
    end
    if ply:InVehicle() then return refuse(ply, "get off first.") end
    id = string.lower(tostring(id or ""))
    local def = BMX.Vehicles[id]
    if not def or def.hidden then return refuse(ply, "the machine has no " .. id .. ".") end
    if CurTime() < (ply.BMXNextRent or 0) then return nil, "too fast" end
    ply.BMXNextRent = CurTime() + R.COOLDOWN

    -- Skates are worn, not parked: the machine hands them over (BMX.Worn.Give
    -- asks the same doors).
    if def.worn then
        if BMX.Worn.Give(ply, id) then return ply end
        return nil, "refused"
    end

    if not BMX.VehicleEnabled(id) then
        return refuse(ply, string.lower(BMX.Families[def.family].category) ..
            " are switched off on this server.")
    end
    if not BMX.DebugAllowed(def, ply) then return refuse(ply, id .. " is a debug vehicle.") end
    if hook.Run("BMX_CanSpawn", ply, id) == false then return nil, "vetoed" end

    R.Return(ply)

    local ent = ents.Create(BMX.ClassFor(id))
    if not IsValid(ent) then return nil, "could not create " .. id end
    local pos, ang = R.Bay(machine)
    ent:SetPos(pos + Vector(0, 0, BMX.RestHeight(ent:Cfg()) + 0.5))
    ent:SetAngles(ang)
    ent:Spawn()
    ent:Activate()
    ent.BMXOwner = ply
    ent.BMXRented = true
    BMX.PaintAsPreferred(ent, ply)
    ply.BMXRental = ent
    R.Out[ent] = true
    if cleanup then cleanup.Add(ply, "bmx", ent) end
    machine:EmitSound("buttons/button4.wav")

    -- Straight on: the whole point is not having to know anything.
    local pod = ent.GetPod and ent:GetPod()
    if IsValid(pod) and hook.Run("BMX_CanMount", ply, ent) ~= false then
        ply:EnterVehicle(pod)
    end
    return ent
end

net.Receive(R.NET_RENT, function(_, ply)
    local machine = net.ReadEntity()
    local id = net.ReadString()
    R.Rent(ply, machine, id)
end)

-- E on a machine: open its window on that player's screen.
function R.Open(ply, machine)
    net.Start(R.NET_OPEN)
    net.WriteEntity(machine)
    net.Send(ply)
end

-- THE SWEEP. A rental with nobody on it for R.IDLE seconds goes back, unless
-- its renter locked it up (a lock is a decision to keep it).
function R.Sweep()
    local now = CurTime()
    for ent in pairs(R.Out) do
        if not IsValid(ent) then
            R.Out[ent] = nil
        elseif IsValid(ent:GetDriver()) or ent.BMXLock then
            ent.BMXIdleSince = nil
        else
            ent.BMXIdleSince = ent.BMXIdleSince or now
            if now - ent.BMXIdleSince >= R.IDLE then
                local owner = ent.BMXOwner
                R.Out[ent] = nil
                ent:Remove()
                if IsValid(owner) and owner.BMXRental == ent then owner.BMXRental = nil end
            end
        end
    end
end
timer.Create("BMX.Rental.Sweep", 5, 0, R.Sweep)

hook.Add("PlayerDisconnected", "BMX.Rental", function(ply) R.Return(ply) end)

-- The machine stays where the map put it: only admins move or remove one.
local function machineGuard(ply, ent)
    if IsValid(ent) and ent.IsBMXRental and not (IsValid(ply) and ply:IsAdmin()) then return false end
end
hook.Add("PhysgunPickup", "BMX.Rental", machineGuard)
hook.Add("GravGunPickupAllowed", "BMX.Rental", machineGuard)
hook.Add("GravGunPunt", "BMX.Rental", machineGuard)
hook.Add("CanProperty", "BMX.Rental", function(ply, _, ent) return machineGuard(ply, ent) end)
hook.Add("CanTool", "BMX.Rental", function(ply, tr)
    if tr then return machineGuard(ply, tr.Entity) end
end)
