--[[--------------------------------------------------------------------------
    entities/bmx_test_solid/shared.lua

    TEST GEOMETRY for the headless suite (sv_test.lua, T.Solid). The cases need
    a wedge, a curb and a wall to ride into on whatever map the server is on,
    so a case hands this entity convex point lists in WORLD space (CustomHulls)
    before Spawn, and it becomes a frozen, invisible solid made of them.

    Nothing in the game spawns it. A client never has the hulls and so builds
    nothing, which is right for geometry that exists for one test.
----------------------------------------------------------------------------]]

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "BMX test solid"
ENT.Author = "naliwajka"
ENT.Spawnable = false
ENT.AdminOnly = true
ENT.RenderGroup = RENDERGROUP_OPAQUE
ENT.PhysgunDisabled = true
ENT.m_tblToolsAllowed = {}

-- The hulls in ENTITY space.
function ENT:Convexes()
    if not self.CustomHulls then return nil end
    local o = self:GetPos()
    local out = {}
    for _, h in ipairs(self.CustomHulls) do
        local pts = {}
        for i, p in ipairs(h) do pts[i] = p - o end
        out[#out + 1] = pts
    end
    return out
end

function ENT:BuildPhysics()
    local hulls = self:Convexes()
    if not hulls then return false end
    self:PhysicsInitMultiConvex(hulls)
    self:SetSolid(SOLID_VPHYSICS)
    -- MOVETYPE_VPHYSICS, FROZEN -- the same recipe as bmx_park_piece, whose
    -- shapes the bike demonstrably rides up. This was MOVETYPE_NONE, and on
    -- the real server (CI 2663) NOTHING built here collided: a 277 u run
    -- straight through a wall, a 20 degree slope a trace reported as flat
    -- ground (normal z 1.000), a wedge and a curb the bike never touched. A
    -- NONE-movetype entity is not simulated as a physics body, so the
    -- multi-convex shape is never in the world. The offline suite has no
    -- VPhysics and could not have shown it.
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:EnableCustomCollisions(true)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then
        phys:SetMass(500)
        phys:SetMaterial("metal")
        phys:EnableMotion(false)
    end
    self._built = true
    return true
end
