--[[--------------------------------------------------------------------------
    entities/bmx_city_solid/shared.lua

    The solid parts of the city: a viaduct, or a pier. sh_city.lua lays them
    out as boxes under a name; this entity is spawned once per name by
    sv_city.lua and gives those boxes collision, on the server for physics and
    on the client for player movement prediction.

    It draws nothing. cl_city.lua draws the whole city in one pass, solid parts
    included, so what you see and what you hit come from the same layout.
----------------------------------------------------------------------------]]

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "BMX city solid"
ENT.Author = "naliwajka"
ENT.Spawnable = false
ENT.AdminOnly = true
ENT.RenderGroup = RENDERGROUP_OPAQUE
ENT.PhysgunDisabled = true
ENT.m_tblToolsAllowed = {}

function ENT:SetupDataTables()
    self:NetworkVar("String", 0, "SolidName")
end

-- The boxes for this entity's name, as convex hulls in ENTITY space.
function ENT:Convexes()
    local L = BMX.City and BMX.City.Layout()
    local s = L and L.solids[self:GetSolidName()]
    if not s then return nil end
    local o = self:GetPos()
    local out = {}
    for _, b in ipairs(s.boxes) do
        local x0, y0, z0, x1, y1, z1 = b[1] - o.x, b[2] - o.y, b[3] - o.z, b[4] - o.x, b[5] - o.y, b[6] - o.z
        out[#out + 1] = {
            Vector(x0, y0, z0), Vector(x1, y0, z0), Vector(x1, y1, z0), Vector(x0, y1, z0),
            Vector(x0, y0, z1), Vector(x1, y0, z1), Vector(x1, y1, z1), Vector(x0, y1, z1),
        }
    end
    return out
end

function ENT:BuildPhysics()
    local hulls = self:Convexes()
    if not hulls then return false end
    self:PhysicsInitMultiConvex(hulls)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_NONE)
    self:EnableCustomCollisions(true)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then
        phys:EnableMotion(false)
        phys:SetMaterial("metal")
    end
    self._built = true
    return true
end
