--[[--------------------------------------------------------------------------
    weapons/weapon_bmx_skates.lua

    THE SKATES (G25, sv_skates.lua): equipping this puts the player into skate mode in
    place of walking, and holstering (switching to anything else, dying, dropping it)
    takes them out. Nothing to spawn and nothing to lose: it is a weapon in the list
    (or `bmx_give_skates`, or `bmx_spawn skates`, or the /bike window), and the vehicle
    it carries is a WORN one (docs/MODDING.md): the player is the chassis.

    It counts toward bmx_max_per_player while you hold it, as a carried board does
    (BMX.BikesOwnedBy, sv_rules.lua). The model is a base-game plate, never drawn in
    hand; the skates themselves are drawn on the player's feet (cl_skates.lua).
----------------------------------------------------------------------------]]

SWEP.PrintName    = "Inline skates"
SWEP.Author       = "naliwajka"
SWEP.Category     = "BMX"
SWEP.Instructions = "Equip to skate: W stride, A / D crossover, S brake, SPACE jump, hold SPACE in the air near a rail to grind. Switch weapon to take them off."
SWEP.Spawnable    = true
SWEP.AdminOnly    = false

SWEP.Slot         = 0
SWEP.SlotPos      = 6
SWEP.DrawAmmo     = false
SWEP.DrawCrosshair = false

SWEP.ViewModel    = "models/weapons/c_arms.mdl"
SWEP.WorldModel   = "models/hunter/plates/plate025x025.mdl"
SWEP.UseHands     = true
SWEP.HoldType     = "normal"

SWEP.Primary.ClipSize     = -1
SWEP.Primary.DefaultClip  = -1
SWEP.Primary.Automatic    = false
SWEP.Primary.Ammo         = "none"
SWEP.Secondary.ClipSize    = -1
SWEP.Secondary.DefaultClip = -1
SWEP.Secondary.Automatic   = false
SWEP.Secondary.Ammo        = "none"

function SWEP:Initialize()
    self:SetHoldType(self.HoldType)
end

-- ON: the weapon becomes the active one. The owner is kept, because by the time the
-- weapon is removed it no longer has one to ask.
function SWEP:Deploy()
    local ply = self:GetOwner()
    self.BMXWearer = ply
    if SERVER and BMX and BMX.Skates and IsValid(ply) then BMX.Skates.Equip(ply) end
    return true
end

-- OFF: something else became the active weapon.
function SWEP:Holster()
    if SERVER and BMX and BMX.Skates and IsValid(self.BMXWearer or self:GetOwner()) then
        BMX.Skates.Unequip(self.BMXWearer or self:GetOwner())
    end
    return true
end

-- GONE: dropped, stripped (a crash's tumble strips and gives back), or the player left.
function SWEP:OnRemove()
    if SERVER and BMX and BMX.Skates and IsValid(self.BMXWearer) then BMX.Skates.Unequip(self.BMXWearer) end
end

function SWEP:OnDrop()
    if SERVER and BMX and BMX.Skates and IsValid(self.BMXWearer) then BMX.Skates.Unequip(self.BMXWearer) end
end

function SWEP:PrimaryAttack() end
function SWEP:SecondaryAttack() end
function SWEP:Reload() end

if CLIENT then
    function SWEP:DrawHUD()
        draw.SimpleText("W stride   A / D crossover   S brake   SPACE jump   hold SPACE near a rail: grind",
            "DermaDefault", ScrW() * 0.5, ScrH() - 80, Color(255, 255, 255, 200), TEXT_ALIGN_CENTER)
    end
end
