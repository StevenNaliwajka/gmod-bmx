--[[--------------------------------------------------------------------------
    bmx/cl_park.lua

    DRAWING THE PARK PIECES. One IMesh per distinct piece (shape + parameters),
    built from BMX.Park.Build's faces, the same build the entity's collision
    comes from; every piece of that kind draws the one mesh with its own
    matrix. A hundred quarter pipes are one mesh and a hundred draw calls,
    not a hundred meshes.

    NO LIGHTING, NO TEXTURE. The material is UnlitGeneric on a white
    texture with vertex colours, as the city's is, and the shade is baked
    into the vertices from the face's normal (a fixed sun), so a ramp still
    reads as a ramp. Coping and rails are lighter, dirt is brown.
----------------------------------------------------------------------------]]

BMX = BMX or {}
local P = BMX.Park

P._meshes = P._meshes or {}

local SUN = Vector(0.35, 0.2, 0.9)
SUN:Normalize()

local function material()
    if not P._mat then
        P._mat = CreateMaterial("bmxpark_unlit", "UnlitGeneric", {
            ["$basetexture"] = "color/white",
            ["$vertexcolor"] = "1",
            ["$nocull"] = "1",
        })
    end
    return P._mat
end

local function clamp255(x) return math.Clamp(math.floor(x + 0.5), 0, 255) end

-- The triangles of a build, shaded: { pos, r, g, b } per vertex.
function P.Triangles(b)
    local tris = {}
    for _, f in ipairs(b.faces) do
        local pts = f.pts
        local n = (pts[2] - pts[1]):Cross(pts[3] - pts[1])
        local len = n:Length()
        local shade = 1
        if len > 1e-6 then
            n = n / len
            shade = 0.55 + 0.45 * math.abs(n:Dot(SUN))
        end
        local c = P.Colors[f.key] or P.Colors.deck
        local r, g, bl = clamp255(c[1] * shade), clamp255(c[2] * shade), clamp255(c[3] * shade)
        for i = 2, #pts - 1 do
            for _, p in ipairs({ pts[1], pts[i], pts[i + 1] }) do
                tris[#tris + 1] = { p, r, g, bl }
            end
        end
    end
    return tris
end

function P.MeshFor(shapeId, params)
    local b = P.Build(shapeId, params)
    if not b then return nil end
    local key = shapeId .. "|" .. P.EncodeParams(shapeId, params)
    local m = P._meshes[key]
    if m then return m end
    local tris = P.Triangles(b)
    local im = Mesh(material())
    mesh.Begin(im, MATERIAL_TRIANGLES, #tris / 3)
    for _, v in ipairs(tris) do
        mesh.Position(v[1])
        mesh.Color(v[2], v[3], v[4], 255)
        mesh.AdvanceVertex()
    end
    mesh.End()
    P._meshes[key] = im
    return im
end

function P.FreeMeshes()
    for _, m in pairs(P._meshes) do if m.Destroy then m:Destroy() end end
    P._meshes = {}
end

function P.Draw(ent)
    if ent:GetShape() == "" then return end
    local m = P.MeshFor(ent:GetShape(), ent:GetParams())
    if not m then return end
    local mat = Matrix()
    mat:SetTranslation(ent:GetPos())
    mat:SetAngles(ent:GetAngles())
    render.SetMaterial(material())
    cam.PushModelMatrix(mat)
    m:Draw()
    cam.PopModelMatrix()
end

-- A map change or a lua refresh drops the meshes; the next Draw rebuilds.
hook.Add("PreCleanupMap", "BMXPark", function() P.FreeMeshes() end)

-- The tool's ghost: the footprint box where the next piece would go.
hook.Add("PostDrawTranslucentRenderables", "BMXPark", function()
    local g = P.Ghost
    if not g or CurTime() - g.t > 0.25 then return end
    render.DrawWireframeBox(g.pos, g.ang, g.mins, g.maxs, Color(120, 220, 255), true)
end)
