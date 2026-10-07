AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

function ENT:Initialize()
    if self.CitySolidName then self:SetSolidName(self.CitySolidName) end
    self:SetModel("models/hunter/blocks/cube025x025x025.mdl")
    self:DrawShadow(false)
    self:BuildPhysics()
end

-- A handful of these exist per map; always send them, so a rider's client has
-- the collision before they ride under a viaduct, not when it enters the PVS.
function ENT:UpdateTransmitState() return TRANSMIT_ALWAYS end
