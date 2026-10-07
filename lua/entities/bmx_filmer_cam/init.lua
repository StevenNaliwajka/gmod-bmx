AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

function ENT:Initialize()
    self:SetModel(self.Model)
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:EnableMotion(false) end   -- a tripod stays where it is put
end

-- Placed where the admin is looking, a little off the ground, facing them.
function ENT:SpawnFunction(ply, tr, class)
    if not tr.Hit then return end
    local ent = ents.Create(class)
    if not IsValid(ent) then return end
    local yaw = IsValid(ply) and (ply:EyeAngles().y + 180) or 0
    ent:SetPos(tr.HitPos + tr.HitNormal * 30)
    ent:SetAngles(Angle(0, yaw, 0))
    ent:Spawn()
    ent:Activate()
    return ent
end
