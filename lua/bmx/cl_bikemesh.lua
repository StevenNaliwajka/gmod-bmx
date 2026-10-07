--[[--------------------------------------------------------------------------
    bmx/cl_bikemesh.lua

    Turns the procedural model (cl_bikegeo.lua) into IMeshes, makes its
    materials, lights it, and draws a group of it under a matrix. The bike
    entity (entities/bmx_base/cl_init.lua) decides WHERE each group goes;
    this file only knows how to put triangles on screen.

    BUILT ONCE PER SIZE, over several frames. A model is ~70k triangles and
    costs a few hundred milliseconds to build in Lua, so it is built in a
    coroutine a slice a frame, keyed by the bike's scale and wheel radius;
    every bike of that size shares it. Until it is ready the old primitive
    bike is drawn, so a first spawn never hitches and never shows nothing.

    MATERIALS are VertexLitGeneric made here: a white base, a flat normal map
    (render targets, cleared once -- nothing shipped) so Phong works, and
    env_cubemap reflections. The paint is one material per colour, its
    $color2 the palette colour; the rest are fixed (black anodised, chrome,
    polished alloy, chain steel, rubber, the tan skinwall, the saddle, pedal
    nylon).

    LIGHTING. An IMesh is not a model, so the engine does not light it. Each
    bike's lighting is sampled where it stands (render.ComputeLighting along
    the six axes), split into an ambient cube and one directional light from
    the bright side (which also gives the Phong highlight), and set with
    engine lighting suppressed while its groups are drawn.

    bmx_bike_model 0 goes back to the primitive bike (and is what a client
    without Mesh support gets).
----------------------------------------------------------------------------]]

BMX = BMX or {}
-- Hot reload: free the meshes the previous version of this file built.
if BMX.BikeMesh and BMX.BikeMesh.Clear then BMX.BikeMesh.Clear() end
local BM = {}
BMX.BikeMesh = BM

local cvModel = CreateClientConVar("bmx_bike_model", "1", true, false,
    "BMX: 1 = the detailed bike model, 0 = the simple one made of shapes.")
local cvBudget = CreateClientConVar("bmx_bike_build_ms", "4", true, false,
    "BMX: milliseconds a frame spent building the bike model (it is built once).")

function BM.Enabled()
    return cvModel:GetBool() and Mesh ~= nil and BMX.BikeGeo ~= nil
end

--------------------------------------------------------------------------
-- TEXTURES AND MATERIALS
--------------------------------------------------------------------------
local ROLE = {
    -- color2, phong exponent, phong boost, envmap tint
    black   = { Vector(0.035, 0.035, 0.04), 18, 0.9,  0.03 },
    chrome  = { Vector(0.55, 0.57, 0.62),   70, 3.0,  0.85 },
    alloy   = { Vector(0.55, 0.56, 0.58),   35, 2.0,  0.35 },
    steel   = { Vector(0.30, 0.30, 0.32),   25, 1.2,  0.18 },
    rubber  = { Vector(0.028, 0.028, 0.03), 6,  0.25, 0 },
    gum     = { Vector(0.50, 0.33, 0.18),   6,  0.2,  0 },
    seat    = { Vector(0.035, 0.035, 0.04), 12, 0.6,  0.01 },
    plastic = { Vector(0.05, 0.05, 0.055),  10, 0.5,  0.02 },
}
local PAINT = { 30, 1.6, 0.12 }       -- exponent, boost, envmap: a metallic clear coat

local tex                              -- { white, normal }
-- CreateMaterial hands back the existing material for a name it has seen,
-- keyvalues ignored, so a reload of this file names its materials afresh.
local MATSUFFIX = tostring(math.floor((SysTime and SysTime() or 0) * 1000) % 1000000)
local mats = {}                        -- role or "paint r g b" -> IMaterial
local texCleared = 0

local function textures()
    if tex then return tex end
    local flags = 0
    tex = {
        white  = GetRenderTargetEx("_rt_bmx_white", 16, 16, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE,
            flags, 0, IMAGE_FORMAT_RGBA8888),
        normal = GetRenderTargetEx("_rt_bmx_flatnormal", 16, 16, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE,
            flags, 0, IMAGE_FORMAT_RGBA8888),
    }
    return tex
end

-- Render targets can lose their contents (a device reset, alt-tab on some
-- drivers), so they are cleared again now and then. Two 16x16 clears.
local function clearTextures()
    local t = textures()
    if RealTime() < texCleared then return end
    texCleared = RealTime() + 5
    render.PushRenderTarget(t.white)
        render.Clear(255, 255, 255, 255)
    render.PopRenderTarget()
    render.PushRenderTarget(t.normal)
        -- a flat tangent-space normal; alpha is the Phong mask: full
        render.Clear(128, 128, 255, 255)
    render.PopRenderTarget()
end

local function makeMat(name, color2, exp, boost, env)
    local t = textures()
    local kv = {
        ["$basetexture"] = "_rt_bmx_white",
        ["$bumpmap"] = "_rt_bmx_flatnormal",
        ["$color2"] = string.format("[%f %f %f]", color2.x, color2.y, color2.z),
        ["$phong"] = 1,
        ["$phongexponent"] = exp,
        ["$phongboost"] = boost,
        ["$phongfresnelranges"] = "[0.25 0.6 1]",
        ["$model"] = 1,
    }
    if env > 0 then
        -- A fixed HL2 reflection, not env_cubemap: an IMesh gets no cubemap
        -- of its own, and maps without built cubemaps hand out a flat grey.
        kv["$envmap"] = "environment maps/metal_generic_002"
        kv["$envmaptint"] = string.format("[%f %f %f]", env, env, env)
        kv["$envmapfresnel"] = 1
    end
    local m = CreateMaterial(name .. "_" .. MATSUFFIX, "VertexLitGeneric", kv)
    m:SetTexture("$basetexture", t.white)
    m:SetTexture("$bumpmap", t.normal)
    return m
end

--------------------------------------------------------------------------
-- THE DECAL: the down tube's graphic, drawn into a render target with alpha
-- (no texture shipped), alpha-tested onto the tube. Redrawn now and then in
-- case the render target lost it.
--------------------------------------------------------------------------
local decalRT, decalDrawn = nil, 0
local tyreRT
local function drawTyreText()
    if not tyreRT then
        tyreRT = GetRenderTargetEx("_rt_bmx_tyretext", 2048, 64, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE,
            0, 0, IMAGE_FORMAT_RGBA8888)
        surface.CreateFont("BMXTyre", { font = "Coolvetica", size = 52, weight = 800, antialias = true })
    end
    render.PushRenderTarget(tyreRT)
    render.OverrideAlphaWriteEnable(true, true)
    render.Clear(0, 0, 0, 0)
    cam.Start2D()
        -- The band is far longer than it is tall, so the lettering is drawn
        -- squeezed sideways and comes out in proportion on the tyre.
        local m = Matrix()
        m:Scale(Vector(0.4, 1, 1))
        cam.PushModelMatrix(m)
            local ink = Color(28, 20, 14, 255)
            for half = 0, 1 do
                local x0 = half * 1024 / 0.4
                draw.SimpleText("STREET  SKINWALL   20 x 2.30", "BMXTyre", x0 + 120, 32, ink, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                draw.SimpleText("MAX 65 PSI", "BMXTyre", x0 + 1700, 32, ink, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            end
        cam.PopModelMatrix()
    cam.End2D()
    render.OverrideAlphaWriteEnable(false)
    render.PopRenderTarget()
end

local function drawDecal()
    if not decalRT then
        decalRT = GetRenderTargetEx("_rt_bmx_decal", 1024, 128, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE,
            0, 0, IMAGE_FORMAT_RGBA8888)
        surface.CreateFont("BMXDecal", { font = "Coolvetica", size = 118, weight = 800, italic = true, antialias = true })
        surface.CreateFont("BMXDecalSmall", { font = "Coolvetica", size = 34, weight = 600, italic = true, antialias = true })
    end
    render.PushRenderTarget(decalRT)
    render.OverrideAlphaWriteEnable(true, true)
    render.Clear(0, 0, 0, 0)
    cam.Start2D()
        local white, dark = Color(245, 245, 245, 255), Color(20, 20, 22, 255)
        -- two slanted bars, the wordmark, and a long tapering speed stripe
        draw.NoTexture()
        for i, x in ipairs({ 40, 78 }) do
            surface.SetDrawColor(i == 1 and dark or white)
            surface.DrawPoly({ { x = x + 30, y = 14 }, { x = x + 52, y = 14 }, { x = x + 22, y = 114 }, { x = x, y = 114 } })
        end
        draw.SimpleTextOutlined("BMX", "BMXDecal", 140, 64, white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, 3, dark)
        surface.SetDrawColor(white)
        surface.DrawPoly({ { x = 420, y = 46 }, { x = 1000, y = 58 }, { x = 996, y = 66 }, { x = 412, y = 80 } })
        surface.SetDrawColor(dark)
        surface.DrawPoly({ { x = 430, y = 88 }, { x = 900, y = 84 }, { x = 898, y = 88 }, { x = 428, y = 96 } })
        draw.SimpleText("STREET  20\"", "BMXDecalSmall", 440, 22, white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    cam.End2D()
    render.OverrideAlphaWriteEnable(false)
    render.PopRenderTarget()
end

hook.Add("PreRender", "BMX.BikeDecal", function()
    if not decalRT or RealTime() < decalDrawn then return end
    decalDrawn = RealTime() + 10
    drawDecal()
    if tyreRT then drawTyreText() end
end)

-- An alpha-tested material over a render-target texture.
local function rtMaterial(name, rtName, rt, color2)
    local t = textures()
    local m = CreateMaterial(name .. "_" .. MATSUFFIX, "VertexLitGeneric", {
        ["$basetexture"] = rtName,
        ["$bumpmap"] = "_rt_bmx_flatnormal",
        ["$color2"] = color2 or "[1 1 1]",
        ["$alphatest"] = 1,
        ["$alphatestreference"] = 0.5,
        ["$phong"] = 1, ["$phongexponent"] = PAINT[1], ["$phongboost"] = PAINT[2],
        ["$phongfresnelranges"] = "[0.25 0.6 1]",
        ["$model"] = 1,
    })
    m:SetTexture("$basetexture", rt)
    m:SetTexture("$bumpmap", t.normal)
    return m
end

function BM.Material(role, col)
    if role == "decal" then
        if not mats.decal then
            drawDecal()
            decalDrawn = RealTime() + 10
            mats.decal = rtMaterial("bmx_decal", "_rt_bmx_decal", decalRT)
        end
        return mats.decal
    end
    if role == "tyretext" then
        if not mats.tyretext then
            drawTyreText()
            mats.tyretext = rtMaterial("bmx_tyretext", "_rt_bmx_tyretext", tyreRT)
        end
        return mats.tyretext
    end
    if role == "paint" then
        col = col or Color(200, 40, 40)
        local key = string.format("paint %d %d %d", col.r, col.g, col.b)
        local m = mats[key]
        if not m then
            -- linear-ish: the palette is sRGB, $color2 multiplies a linear base
            local c = Vector((col.r / 255) ^ 2.2, (col.g / 255) ^ 2.2, (col.b / 255) ^ 2.2) * 1.15
            m = makeMat("bmx_paint_" .. col.r .. "_" .. col.g .. "_" .. col.b, c, PAINT[1], PAINT[2], PAINT[3])
            mats[key] = m
        end
        return m
    end
    local m = mats[role]
    if not m then
        local r = ROLE[role] or ROLE.black
        m = makeMat("bmx_" .. role, r[1], r[2], r[3], r[4])
        mats[role] = m
    end
    return m
end

--------------------------------------------------------------------------
-- BUILDING. One model per size, shared; built in a coroutine.
--------------------------------------------------------------------------
local models = {}                     -- key -> { ready, groups, layout } or a building job
local MAX_TRIS = 21000                -- 3 vertices a triangle, under the 65535-vertex mesh limit

local function tangentOf(n)
    -- any unit vector perpendicular to the normal: the normal map is flat,
    -- so only the frame's orthogonality matters, not its direction
    local t = n:Cross(Vector(0, 0, 1))
    if t:LengthSqr() < 1e-4 then t = n:Cross(Vector(1, 0, 0)) end
    t:Normalize()
    return t
end

local function buildJob(key, k, radius)
    return coroutine.create(function()
        local G = BMX.BikeGeo
        local M = G.Build({ k = k, radius = radius })
        coroutine.yield()
        local layout = {}
        for key, v in pairs(M.layout) do
            layout[key] = type(v) == "table" and Vector(v[1], v[2], v[3]) or v
        end
        local out = { groups = {}, layout = layout, stats = G.Stats(M) }
        local fmt = BM.Material("black")
        local work = 0
        for _, gname in ipairs(M.order) do
            local list = {}
            for _, b in ipairs(M.groups[gname]) do
                local entry = { mat = b.mat, detail = b.detail, meshes = {} }
                local verts = {}
                local function flush()
                    if #verts == 0 then return end
                    local m = Mesh(fmt)
                    m:BuildFromTriangles(verts)
                    entry.meshes[#entry.meshes + 1] = m
                    verts = {}
                end
                -- The builder winds triangles counter-clockwise seen from
                -- outside (right-handed); Source's front faces are the other
                -- way round and the back ones are culled, so each triangle's
                -- last two vertices are swapped here: 1, 3, 2.
                local src = b.v
                for i = 1, #src do
                    local r = (i - 1) % 3
                    local v = (r == 1) and src[i + 1] or (r == 2) and src[i - 1] or src[i]
                    local n = Vector(v.n[1], v.n[2], v.n[3])
                    local t = tangentOf(n)
                    verts[#verts + 1] = {
                        pos = Vector(v.p[1], v.p[2], v.p[3]), normal = n,
                        u = v.u, v = v.v,
                        userdata = { t.x, t.y, t.z, 1 },
                        tangent = t, binormal = n:Cross(t),
                    }
                    if #verts >= MAX_TRIS * 3 then flush() end
                    work = work + 1
                    if work >= 1500 then work = 0 coroutine.yield() end
                end
                flush()
                list[#list + 1] = entry
            end
            out.groups[gname] = list
        end
        return out
    end)
end

-- The model for this size, or nil while it is being built (the caller
-- draws the simple bike meanwhile). Building advances here, a few ms a
-- frame, from whichever bike asks first.
local lastStep = 0
function BM.Get(k, radius)
    if not BM.Enabled() then return nil end
    local key = string.format("%.3f/%.3f", k, radius)
    local m = models[key]
    if m and m.ready then return m end
    if m and m.failed then return nil end
    if not m then
        m = { job = buildJob(key, k, radius) }
        models[key] = m
    end
    local frame = FrameNumber()
    if lastStep == frame then return nil end      -- one job's slice a frame
    lastStep = frame
    local deadline = SysTime() + math.max(cvBudget:GetFloat(), 0.5) / 1000
    while SysTime() < deadline do
        local ok, res = coroutine.resume(m.job)
        if not ok then
            m.failed = true
            MsgN("[BMX] bike model failed to build, using the simple bike: " .. tostring(res))
            return nil
        end
        if coroutine.status(m.job) == "dead" then
            res.ready = true
            models[key] = res
            return res
        end
    end
    return nil
end

-- Throw every built model away (bmx_bike_model_rebuild, or a hot reload).
function BM.Clear()
    for _, m in pairs(models) do
        if m.groups then
            for _, list in pairs(m.groups) do
                for _, e in ipairs(list) do
                    for _, mesh in ipairs(e.meshes) do if IsValid(mesh) then mesh:Destroy() end end
                end
            end
        end
    end
    models = {}
end
concommand.Add("bmx_bike_model_rebuild", function() BM.Clear() end)

--------------------------------------------------------------------------
-- LIGHTING
--------------------------------------------------------------------------
local AXES = { Vector(1, 0, 0), Vector(-1, 0, 0), Vector(0, 1, 0), Vector(0, -1, 0), Vector(0, 0, 1), Vector(0, 0, -1) }

local function sample(pos, dir)
    local c = render.ComputeLighting(pos, dir)
    local d = render.ComputeDynamicLighting(pos, dir)
    return c + d
end

-- Light the meshes drawn until BM.EndLighting as a model standing at `pos`.
-- Samples are cached on `ent` for a few frames: lighting changes slowly
-- and ComputeLighting is not free.
function BM.BeginLighting(pos, ent)
    clearTextures()
    local L = ent and ent.bmxLight
    if not L or RealTime() > L.t or L.pos:DistToSqr(pos) > 64 * 64 then
        local s = {}
        for i, a in ipairs(AXES) do s[i] = sample(pos, a) end
        -- one directional light from the bright side: u points at it
        local diff = { s[1] - s[2], s[3] - s[4], s[5] - s[6] }
        local lum = function(v) return v.x * 0.3 + v.y * 0.59 + v.z * 0.11 end
        local u = Vector(lum(diff[1]), lum(diff[2]), lum(diff[3]))
        local col = Vector(0, 0, 0)
        if u:LengthSqr() > 1e-8 then
            u:Normalize()
            col = diff[1] * u.x + diff[2] * u.y + diff[3] * u.z
            col.x, col.y, col.z = math.max(col.x, 0) * 0.85, math.max(col.y, 0) * 0.85, math.max(col.z, 0) * 0.85
        end
        local amb = {}
        for i, a in ipairs(AXES) do
            local c = s[i] - col * math.max(0, a:Dot(u))
            amb[i] = Vector(math.max(c.x, 0), math.max(c.y, 0), math.max(c.z, 0))
        end
        L = { t = RealTime() + 0.25, pos = pos, amb = amb, dir = u, col = col }
        if ent then ent.bmxLight = L end
    end
    render.SuppressEngineLighting(true)
    for i = 1, 6 do
        local c = L.amb[i]
        render.SetModelLighting(i - 1, c.x, c.y, c.z)
    end
    if L.col:LengthSqr() > 1e-6 then
        -- Falloff given explicitly: left out, the attenuation divides by
        -- zero and the light saturates everything to flat full-bright.
        render.SetLocalModelLights({ {
            type = MATERIAL_LIGHT_DIRECTIONAL,
            color = L.col,
            dir = -L.dir,               -- the way the light travels
            pos = pos + L.dir * 4096,
            range = 0,
            constantFalloff = 1, linearFalloff = 0, quadraticFalloff = 0,
        } })
    else
        render.SetLocalModelLights({})
    end
end

function BM.EndLighting()
    render.SetLocalModelLights({})
    render.SuppressEngineLighting(false)
end

--------------------------------------------------------------------------
-- DRAWING
--------------------------------------------------------------------------
-- A matrix taking model space to world: columns are where the model's
-- x, y and z axes point, then its origin.
function BM.Matrix(o, ex, ey, ez)
    return Matrix({
        { ex.x, ey.x, ez.x, o.x },
        { ex.y, ey.y, ez.y, o.y },
        { ex.z, ey.z, ez.z, o.z },
        { 0, 0, 0, 1 },
    })
end

-- Draw one group of `model` under `mtx`. `paint` is the frame colour;
-- `lod` >= 2 skips the buckets marked detail (spokes, chain, knobs, pins).
function BM.DrawGroup(model, name, mtx, paint, lod)
    local list = model.groups[name]
    if not list then return end
    cam.PushModelMatrix(mtx)
    for _, e in ipairs(list) do
        if not (e.detail and (lod or 0) >= 2) then
            render.SetMaterial(BM.Material(e.mat, paint))
            for _, m in ipairs(e.meshes) do m:Draw() end
        end
    end
    cam.PopModelMatrix()
end

-- A tube through `pts` (world space), drawn immediately: the parts that bend
-- every frame (the brake cable's loop, the kickstand).
function BM.DrawTube(pts, radius, role, sides)
    sides = sides or 6
    local n = #pts
    if n < 2 then return end
    render.SetMaterial(BM.Material(role))
    -- frames by parallel transport
    local T, N = {}, {}
    for i = 1, n do
        local a, b = pts[math.max(1, i - 1)], pts[math.min(n, i + 1)]
        local t = b - a
        t:Normalize()
        T[i] = t
    end
    local up = math.abs(T[1].z) < 0.9 and Vector(0, 0, 1) or Vector(1, 0, 0)
    N[1] = (up - T[1] * up:Dot(T[1])):GetNormalized()
    for i = 2, n do
        local q = N[i - 1] - T[i] * N[i - 1]:Dot(T[i])
        if q:LengthSqr() < 1e-8 then q = N[i - 1] end
        q:Normalize()
        N[i] = q
    end
    mesh.Begin(MATERIAL_QUADS, (n - 1) * sides)
    for i = 1, n - 1 do
        local b1, b2 = T[i]:Cross(N[i]), T[i + 1]:Cross(N[i + 1])
        for j = 0, sides - 1 do
            local a1, a2 = j / sides * math.pi * 2, (j + 1) / sides * math.pi * 2
            local d11 = N[i] * math.cos(a1) + b1 * math.sin(a1)
            local d12 = N[i] * math.cos(a2) + b1 * math.sin(a2)
            local d21 = N[i + 1] * math.cos(a1) + b2 * math.sin(a1)
            local d22 = N[i + 1] * math.cos(a2) + b2 * math.sin(a2)
            for _, v in ipairs({ { pts[i], d11 }, { pts[i + 1], d21 }, { pts[i + 1], d22 }, { pts[i], d12 } }) do
                local t = tangentOf(v[2])
                mesh.Position(v[1] + v[2] * radius)
                mesh.Normal(v[2])
                mesh.TangentS(t)
                mesh.TangentT(v[2]:Cross(t))
                mesh.UserData(t.x, t.y, t.z, 1)
                mesh.TexCoord(0, 0, 0)
                mesh.AdvanceVertex()
            end
        end
    end
    mesh.End()
end
