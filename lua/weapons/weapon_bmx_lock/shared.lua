--[[--------------------------------------------------------------------------
    weapons/weapon_bmx_lock/shared.lua

    THE BIKE LOCK (G13): a chain and a padlock, for roleplay.

        left click    lock the bike you are aiming at to the world (parked, on the ground)
        right click   unlock it: yours, or anyone's if you have "BMX - Unlock Any Lock"
        reload        say who a bike is locked by

    A locked bike cannot be mounted or physgunned by anyone but its owner; the rules and
    their reasons are lua/bmx/sv_lock.lua.
----------------------------------------------------------------------------]]

SWEP.PrintName     = "Bike Lock"
SWEP.Author        = "naliwajka"
SWEP.Category      = "BMX"
SWEP.Instructions  = "Left click: lock the bike you are aiming at to the ground. Right click: unlock it (yours, or any if you are an admin). Reload: who locked it."
SWEP.Spawnable     = true
SWEP.AdminOnly     = false

-- Base-game models only: the tool gun's, held like one.
SWEP.ViewModel     = "models/weapons/c_toolgun.mdl"
SWEP.WorldModel    = "models/weapons/w_toolgun.mdl"
SWEP.UseHands      = true
SWEP.Slot          = 5
SWEP.SlotPos       = 9

SWEP.Primary.ClipSize      = -1
SWEP.Primary.DefaultClip   = -1
SWEP.Primary.Automatic     = false
SWEP.Primary.Ammo          = "none"
SWEP.Secondary.ClipSize    = -1
SWEP.Secondary.DefaultClip = -1
SWEP.Secondary.Automatic   = false
SWEP.Secondary.Ammo        = "none"

-- One action a second: a lock is not a machine gun.
SWEP.Cooldown = 0.6

function SWEP:Initialize()
    self:SetHoldType("pistol")
end

-- Say something to the holder, on the server (the client has nothing to say).
local function say(self, msg)
    if SERVER and IsValid(self:GetOwner()) then self:GetOwner():ChatPrint("[BMX] " .. msg) end
end

function SWEP:PrimaryAttack()
    self:SetNextPrimaryFire(CurTime() + self.Cooldown)
    if CLIENT then return end
    local ply = self:GetOwner()
    local bike = BMX.Lock.Aimed(ply)
    if not bike then say(self, "aim at a parked bike.") return end
    local ok, why = BMX.Lock.Lock(bike, ply)
    if ok then
        self:EmitSound("doors/door_latch3.wav", 60, 110)
        say(self, "locked. Only you (or an admin) can unlock it.")
    else
        say(self, "cannot lock it: " .. tostring(why) .. ".")
    end
end

function SWEP:SecondaryAttack()
    self:SetNextSecondaryFire(CurTime() + self.Cooldown)
    if CLIENT then return end
    local ply = self:GetOwner()
    local bike = BMX.Lock.Aimed(ply)
    if not bike then say(self, "aim at a locked bike.") return end
    local ok, why = BMX.Lock.Unlock(bike, ply)
    if ok then
        self:EmitSound("doors/door_latch1.wav", 60, 100)
        say(self, "unlocked.")
    else
        say(self, "cannot unlock it: " .. tostring(why) .. ".")
    end
end

function SWEP:Reload()
    if CLIENT or (self.nextInfo or 0) > CurTime() then return end
    self.nextInfo = CurTime() + 1
    local bike = BMX.Lock.Aimed(self:GetOwner())
    local lock = bike and BMX.Lock.Of(bike)
    say(self, lock and ("locked by " .. tostring(lock.ownerName) .. ".") or "that bike is not locked.")
end

-- Nothing on the weapon is held to the server's setting: the bikes' switch is checked
-- where the lock is made (BMX.Lock.CanLock), so a switched-off server's weapon just says so.
