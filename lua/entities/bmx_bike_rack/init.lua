AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

--[[--------------------------------------------------------------------------
    entities/bmx_bike_rack/init.lua  (server)

    A plate, welded to a car if there is one near, that holds two bikes (BMX.Rack,
    sv_rack.lua). Everything it does is in that file; this only spawns, uses and lets go.
----------------------------------------------------------------------------]]

function ENT:Initialize()
    self:SetModel(self.RackModel)
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetUseType(SIMPLE_USE)
    self.held = {}
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then
        phys:SetMass(60)
        phys:Wake()
    end
end

-- Spawned from the menu: put it where the player points, and against the nearest car if
-- there is one, on the side of it the player pointed at, facing away from it.
function ENT:SpawnFunction(ply, tr, class)
    if not tr.Hit then return end
    local ent = ents.Create(class)
    if not IsValid(ent) then return end
    local pos = tr.HitPos + tr.HitNormal * 4
    ent:SetPos(pos)
    local car = BMX.Rack and BMX.Rack.FindCarrier(pos)
    if car then
        local near = car:NearestPoint(pos)
        local away = (near - car:GetPos())
        away.z = 0
        if away:LengthSqr() > 1 then
            ent:SetAngles(Angle(0, away:Angle().y, 0))
            ent:SetPos(near + away:GetNormalized() * 24 + Vector(0, 0, 6))
        end
    else
        ent:SetAngles(Angle(0, ply:EyeAngles().y, 0))
    end
    ent:Spawn()
    ent:Activate()
    if car then BMX.Rack.Attach(ent, car, ply) end
    return ent
end

function ENT:Use(ply)
    if not IsValid(ply) or not ply:IsPlayer() then return end
    local what = BMX.Rack.Use(self, ply)
    local say = {
        off      = "bikes are switched off on this server (bmx_allow_bikes 0).",
        attached = "the rack is welded to the vehicle.",
        loaded   = "bike loaded (" .. BMX.Rack.Count(self) .. " of " .. BMX.Rack.Capacity .. ").",
        released = "bike let down.",
        notyours = "the bikes on it are not yours to take off.",
        nothing  = "nothing to load: put a bike beside the rack and use it.",
    }
    ply:ChatPrint("[BMX] " .. (say[what] or ""))
end

-- A COPY (the duplicator, a save) starts empty. The default copy merges this
-- entity's table into the paste, so the paste held the original's bikes and its
-- weld: removing the paste let the original's bikes down and pulled the original
-- off its car.
function ENT:OnEntityCopyTableFinish(data)
    data.held, data.carrier, data.carrierWeld = nil, nil, nil
    if data.DT then data.DT.Loaded = 0 end
end

-- ...and finds its own car once the paste has made its welds, which is after this.
function ENT:PostEntityPaste()
    timer.Simple(0, function()
        if not IsValid(self) or not (BMX.Rack and constraint.FindConstraints) then return end
        for _, c in ipairs(constraint.FindConstraints(self, "Weld")) do
            local other = (c.Ent1 == self) and c.Ent2 or c.Ent1
            if BMX.Rack.IsCarrier(other) then
                self.carrier, self.carrierWeld = other, c.Constraint
                if self.SetCarried then self:SetCarried(true) end
                return
            end
        end
        if self.SetCarried then self:SetCarried(false) end
    end)
end

function ENT:OnRemove()
    if BMX.Rack then
        BMX.Rack.ReleaseAll(self)
        BMX.Rack.Detach(self)
    end
end
