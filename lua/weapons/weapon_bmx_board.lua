--[[--------------------------------------------------------------------------
    weapons/weapon_bmx_board.lua

    THE BOARD UNDER YOUR ARM (G23, sv_board_carry.lua). Left mouse puts it down in
    front of you; bmx_pickup_board (bind it) takes one back. It counts toward bmx_max_per_player
    while you carry it. The model is a base-game plate, since there is no board
    model yet (that is G23's M5); the first-person view is drawn as the same
    procedural board when cl_board.lua is there to do it.
----------------------------------------------------------------------------]]

SWEP.PrintName    = "Skateboard"
SWEP.Author       = "naliwajka"
SWEP.Category     = "BMX"
SWEP.Instructions = "Left mouse: put the board down.  Console: bmx_pickup_board while looking at one picks it up."
SWEP.Spawnable    = true
SWEP.AdminOnly    = false

SWEP.Slot         = 0
SWEP.SlotPos      = 5
SWEP.DrawAmmo     = false
SWEP.DrawCrosshair = true

SWEP.ViewModel    = "models/weapons/c_arms.mdl"
SWEP.WorldModel   = "models/hunter/plates/plate05x1.mdl"
SWEP.UseHands     = true
SWEP.HoldType     = "slam"

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

function SWEP:PrimaryAttack()
    self:SetNextPrimaryFire(CurTime() + 0.6)
    if SERVER and BMX and BMX.BoardCarry then BMX.BoardCarry.Drop(self:GetOwner()) end
end

function SWEP:SecondaryAttack() end

function SWEP:Reload() end

if CLIENT then
    function SWEP:DrawHUD()
        draw.SimpleText("LMB  put the board down", "DermaDefault", ScrW() * 0.5, ScrH() - 80,
            Color(255, 255, 255, 220), TEXT_ALIGN_CENTER)
    end
end
