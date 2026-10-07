--[[--------------------------------------------------------------------------
    entities/bmx_park_piece/shared.lua

    One piece of a skatepark: a kicker, a quarter pipe, a rail. The piece is
    two strings on the wire, its shape id and its parameter list ("2,1"), and
    everything else is derived: BMX.Park.Build (sh_park.lua) makes the convex
    hulls from them, here on the server for physics and on the client for
    player-movement prediction, and cl_park.lua draws the same build's faces.
    No model file, no vertex ever sent.

    Generalises bmx_city_solid (the petopia_bmx_fall map's city), which does the same for a name instead of a
    parameter list. Unlike the city's, a piece is furniture: it can be
    physgunned and unfrozen, it dupes (the datatable is saved and restored),
    and it is FROZEN by default, which is what keeps a whole park cheap: a
    frozen multi-convex body costs the engine nothing per tick.

    The spawn menu's classes (bmx_park_quarterpipe_v2_m and the rest) derive
    from this one and only set ParkShape and ParkParams, see sh_park.lua.
----------------------------------------------------------------------------]]

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "BMX park piece"
ENT.Author = "naliwajka"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.RenderGroup = RENDERGROUP_OPAQUE

function ENT:SetupDataTables()
    self:NetworkVar("String", 0, "Shape")
    self:NetworkVar("String", 1, "Params")
end

-- The piece's hulls, in ENTITY space (the generator already centres them).
function ENT:Convexes()
    local b = BMX.Park.Build(self:GetShape(), self:GetParams())
    return b and b.hulls or nil
end

-- The grind lines of this piece in the world: { kind, a, b }.
function ENT:GrindLines()
    local b = BMX.Park.Build(self:GetShape(), self:GetParams())
    if not b then return {} end
    return BMX.Park.WorldGrind(b, self:GetPos(), self:GetAngles().y)
end

function ENT:BuildPhysics()
    local b = self:GetShape() ~= "" and BMX.Park.Build(self:GetShape(), self:GetParams())
    if not b then return false end
    self:PhysicsInitMultiConvex(b.hulls)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:EnableCustomCollisions(true)
    self:SetRenderBounds(b.mins, b.maxs)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then
        phys:SetMaterial("concrete")
        phys:SetMass(500)
        phys:EnableMotion(false)        -- frozen by default
    end
    self._built = true
    return true
end
