AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

-- The spawn menu's classes carry ParkShape / ParkParams; BMX.Park.Place and a
-- duplicator paste have already set the datatable (a paste restores it before
-- Spawn), and then it is left alone.
function ENT:Initialize()
    if self:GetShape() == "" then
        local shape = self.ParkShape or "kicker"
        self:SetShape(shape)
        self:SetParams(BMX.Park.EncodeParams(shape, self.ParkParams))
    end
    self:SetModel("models/hunter/blocks/cube025x025x025.mdl")
    self:DrawShadow(false)
    self:BuildPhysics()
end

-- A map-placed or SetKeyValue'd piece.
function ENT:KeyValue(k, v)
    if k == "shape" then self.ParkShape = v
    elseif k == "params" then self.ParkParams = v end
end
