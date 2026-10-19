--[[--------------------------------------------------------------------------
    weapons/weapon_bmx_board.lua

    THE BOARD UNDER YOUR ARM (G23, sv_board_carry.lua). Left mouse puts it down in
    front of you; bmx_pickup_board (bind it) takes one back. It counts toward bmx_max_per_player
    while you carry it. Others see the board itself in your hand, hanging at your
    side by its front truck (cl_board.lua, BMX.Board.DrawCarried); the base-game
    plate is the world model only while that model builds, or without the client
    files.
----------------------------------------------------------------------------]]

SWEP.PrintName    = "Skateboard"
SWEP.Author       = "Burrito"
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
SWEP.HoldType     = "normal"     -- the arm down at the side, the board in the hand

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
    function SWEP:DrawWorldModel(flags)
        local ply = self:GetOwner()
        local B = BMX and BMX.Board
        if IsValid(ply) and B and B.DrawCarried and B.DrawCarried(ply) then return end
        self:DrawModel(flags)
    end

    function SWEP:DrawHUD()
        draw.SimpleText("LMB  put the board down", "DermaDefault", ScrW() * 0.5, ScrH() - 80,
            Color(255, 255, 255, 220), TEXT_ALIGN_CENTER)
    end
end
