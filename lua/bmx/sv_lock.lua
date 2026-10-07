--[[--------------------------------------------------------------------------
    bmx/sv_lock.lua

    THE BIKE LOCK (G13): a parked bike locked to the world, for roleplay. The tool is
    weapon_bmx_lock (lua/weapons/weapon_bmx_lock): left click locks the bike it is aimed
    at, right click unlocks it. The rules are here.

    WHAT LOCKING IS. A bike with nobody on it, standing on the world, is welded to the
    world (constraint.Weld with the world entity) and marked: `Locked` networked to the
    clients (a chain and a padlock are drawn on it, cl_oddbikes.lua), and the lock's state
    kept on the bike: who locked it (their SteamID64, so it survives their reconnecting,
    and the player while they are here), and when. The weld is the lock: nothing the
    bike's own simulation or a stray prop does will move it.

    WHO MAY DO WHAT.
      lock        anybody with the weapon, to a bike that is parked, standing on the world,
                  not on a rack and not already locked
      unlock      the player who locked it, or anyone with the CAMI privilege
                  "BMX - Unlock Any Lock" (admins, by default; sh_permissions.lua). The
                  server console may do anything.
      mount       only the owner: E on your own locked bike unlocks it and gets you on, the
                  way a key does. Anybody else is refused, with the owner's name. Nobody
                  can board a locked bike as a passenger either (BMX_CanMount is asked for
                  both).
      physgun, gravity gun, tool gun   only a player who could unlock it: for anybody else
                  the bike is part of the world. (The owner's physgun lets the lock go
                  first: a welded bike would not move anyway, and a locked bike that is
                  carried off would be a lock that does nothing.)

    bmx_allow_bikes 0 switches the weapon off with the rest of the bikes.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Lock = BMX.Lock or {}
local L = BMX.Lock

L.PRIV  = "BMX - Unlock Any Lock"
L.Range = 110       -- u: how far the weapon reaches

-- The lock on a bike, or nil.
function L.Of(bike)
    return IsValid(bike) and bike.BMXLock or nil
end

local function sid(ply)
    if not IsValid(ply) then return nil end
    return ply.SteamID64 and ply:SteamID64() or ("ent" .. ply:EntIndex())
end
L.SteamID = sid

function L.IsOwner(bike, ply)
    local lock = L.Of(bike)
    return lock ~= nil and IsValid(ply) and lock.ownerSID == sid(ply)
end

-- The one question about unlocking: the owner, a player with "BMX - Unlock Any Lock", or
-- the server console (a nil or invalid player).
function L.CanUnlock(bike, ply)
    if not L.Of(bike) then return false end
    if ply == nil or not IsValid(ply) then return true end
    if L.IsOwner(bike, ply) then return true end
    return BMX.Can(ply, L.PRIV) and true or false
end

-- Is there something of the world under the bike to lock it to? A downward trace from
-- the bike that meets the world (brush or displacement), not a prop or a player.
local function onTheWorld(bike)
    local tr = util.TraceLine({ start = bike:GetPos() + Vector(0, 0, 4), endpos = bike:GetPos() - Vector(0, 0, 70),
        filter = { bike, bike:GetPod() }, mask = MASK_SOLID })
    return tr.Hit and (tr.HitWorld or (IsValid(tr.Entity) and tr.Entity:IsWorld())) and true or false
end

-- May this player lock this bike? (ok, why).
function L.CanLock(bike, ply)
    if not IsValid(bike) or not bike.IsBMX then return false, "that is not a bike" end
    if BMX.VehicleEnabled and not BMX.VehicleEnabled("stock") then return false, "bikes are switched off on this server" end
    if L.Of(bike) then return false, "it is already locked" end
    if IsValid(bike:GetDriver()) then return false, "somebody is riding it" end
    if bike.BMXRack then return false, "it is on a rack" end
    if BMX.IsFallen and BMX.IsFallen(bike) then return false, "it has fallen over: stand it up first" end
    if not onTheWorld(bike) then return false, "there is nothing to lock it to" end
    return true
end

function L.Lock(bike, ply)
    local ok, why = L.CanLock(bike, ply)
    if not ok then return false, why end
    local world = game.GetWorld()
    bike.BMXLock = {
        owner = ply, ownerSID = sid(ply), ownerName = IsValid(ply) and ply:Nick() or "the server",
        at = CurTime(),
    }
    -- Held upright on its stand, then welded to the world where it stands.
    bike:SetStandDown(true)
    bike.BMXLock.weld = constraint.Weld(bike, world, 0, 0, 0, true, false)
    if bike.SetLocked then bike:SetLocked(true) end
    hook.Run("BMX_BikeLocked", bike, ply)
    return true
end

-- Let a lock go. Without `force`, only somebody who may (CanUnlock); the owner stepping
-- on and the owner's physgun are the owner's, so they pass the same test.
function L.Unlock(bike, ply, force)
    local lock = L.Of(bike)
    if not lock then return false, "it is not locked" end
    if not force and not L.CanUnlock(bike, ply) then
        return false, "it is locked by " .. tostring(lock.ownerName)
    end
    if lock.weld and IsValid(lock.weld) then lock.weld:Remove() end
    bike.BMXLock = nil
    if bike.SetLocked then bike:SetLocked(false) end
    local phys = bike:GetPhysicsObject()
    if IsValid(phys) then phys:Wake() end
    hook.Run("BMX_BikeUnlocked", bike, ply)
    return true
end

--------------------------------------------------------------------------
-- THE DOORS.
--------------------------------------------------------------------------
-- Mounting (and boarding as a passenger): the owner unlocks it by getting on; nobody else.
hook.Add("BMX_CanMount", "BMX.Lock", function(ply, bike)
    if not L.Of(bike) then return end
    if L.IsOwner(bike, ply) then
        L.Unlock(bike, ply)
        return
    end
    if IsValid(ply) then ply:ChatPrint("[BMX] it is locked by " .. tostring(bike.BMXLock.ownerName) .. ".") end
    return false
end)

-- The physgun: for anybody who could not unlock it, the bike is part of the world. For
-- those who could, it lets go first.
hook.Add("PhysgunPickup", "BMX.Lock", function(ply, ent)
    if not L.Of(ent) then return end
    if L.CanUnlock(ent, ply) then
        L.Unlock(ent, ply)
        return
    end
    return false
end)

hook.Add("GravGunPickupAllowed", "BMX.Lock", function(ply, ent)
    if L.Of(ent) and not L.CanUnlock(ent, ply) then return false end
end)
hook.Add("GravGunPunt", "BMX.Lock", function(ply, ent)
    if L.Of(ent) then return false end
end)

-- The tool gun (remove, weld, rope, ...): only for somebody who could unlock it.
hook.Add("CanTool", "BMX.Lock", function(ply, tr)
    local ent = tr and tr.Entity
    if L.Of(ent) and not L.CanUnlock(ent, ply) then
        if IsValid(ply) then ply:ChatPrint("[BMX] it is locked by " .. tostring(ent.BMXLock.ownerName) .. ".") end
        return false
    end
end)

-- The property menu (remove, ignite, paint, ...): the same.
hook.Add("CanProperty", "BMX.Lock", function(ply, property, ent)
    if L.Of(ent) and not L.CanUnlock(ent, ply) then return false end
end)

-- The weapon itself comes and goes with the bikes: bmx_allow_bikes 0 gives nobody one.
hook.Add("PlayerGiveSWEP", "BMX.LockEnabled", function(ply, class)
    if class == "weapon_bmx_lock" and BMX.VehicleEnabled and not BMX.VehicleEnabled("stock") then return false end
end)
hook.Add("PlayerSpawnSWEP", "BMX.LockEnabled", function(ply, class)
    if class == "weapon_bmx_lock" and BMX.VehicleEnabled and not BMX.VehicleEnabled("stock") then return false end
end)

-- What the weapon is aimed at: the bike under its aim, or nil.
function L.Aimed(ply)
    local tr = ply:GetEyeTrace()
    if tr and IsValid(tr.Entity) and tr.Entity.IsBMX and tr.HitPos:Distance(ply:GetShootPos()) <= L.Range then
        return tr.Entity
    end
    return nil
end
