AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

--[[--------------------------------------------------------------------------
    entities/bmx_rental/init.lua  (server)

    The machine: a frozen vending machine. Renting is BMX.Rental (sv_rental.lua).
----------------------------------------------------------------------------]]

function ENT:Initialize()
    self:SetModel(BMX.Rental.Model)
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetUseType(SIMPLE_USE)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:EnableMotion(false) end
end

function ENT:Use(ply)
    if IsValid(ply) and ply:IsPlayer() and not ply:InVehicle() then BMX.Rental.Open(ply, self) end
end
