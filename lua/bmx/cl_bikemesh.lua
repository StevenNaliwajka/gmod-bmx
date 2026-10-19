--[[--------------------------------------------------------------------------
    bmx/cl_bikemesh.lua

    Turns the procedural model (cl_bikegeo.lua) into IMeshes, makes its
    materials, lights it, and draws a group of it under a matrix. The bike
    entity (entities/bmx_base/cl_init.lua) decides WHERE each group goes;
    this file only knows how to put triangles on screen.

    BUILT ONCE PER SIZE, over several frames. A model is ~70k triangles and
    costs up to a second to build in Lua, so it is built in a coroutine a
    slice a frame (bmx_bike_build_ms), keyed by the bike's scale and wheel
    radius; every bike of that size shares it. The build keeps to the slice
    by the clock: the geometry looks at it every few dozen triangles
    (cl_bikegeo.lua G.YieldIn), the meshes every few dozen vertices, and each
    mesh (at most MAX_TRIS triangles) is handed to the engine at the start of
    a slice. The vehicles being drawn are built first, the rest of the world's
    at half the rate. Until it is ready the old primitive bike is drawn, so a
    first spawn does not hitch and never shows nothing.
    bmx_bike_build_report prints what each build cost on this client.

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
    -- for the vehicles that are not a BMX (cl_geo_*.lua)
    white   = { Vector(0.78, 0.78, 0.76),   14, 0.7,  0.04 },  -- white plastic: number plates, panels
    wood    = { Vector(0.62, 0.42, 0.22),   8,  0.3,  0 },     -- maple: a deck's veneer
    leather = { Vector(0.24, 0.12, 0.05),   10, 0.45, 0.01 },  -- a brown saddle, grips
    lens    = { Vector(0.75, 0.75, 0.72),   80, 3.0,  0.6 },   -- a lamp's glass
    redlens = { Vector(0.6, 0.02, 0.02),    60, 2.0,  0.3 },   -- a tail light, a reflector
    amber   = { Vector(0.8, 0.35, 0.02),    60, 2.0,  0.3 },   -- an indicator, a side reflector
}
local PAINT = { 30, 1.6, 0.12 }       -- exponent, boost, envmap: a metallic clear coat

local tex                              -- { white, normal }
-- CreateMaterial hands back the existing material for a name it has seen,
-- keyvalues ignored, so a reload of this file names its materials afresh.
local MATSUFFIX = tostring(math.floor((SysTime and SysTime() or 0) * 1000) % 1000000)
local mats = {}                        -- role or "paint r g b" -> IMaterial
local paintByCol = setmetatable({}, { __mode = "k" })   -- a Color table -> { r, g, b, m = its paint }
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
        -- By the colour itself first: a frame's every paint bucket asked by formatting
        -- a key, and the palette's colours are the same tables every time.
        local hit = paintByCol[col]
        if hit and hit.r == col.r and hit.g == col.g and hit.b == col.b then return hit.m end
        local key = string.format("paint %d %d %d", col.r, col.g, col.b)
        local m = mats[key]
        if m then paintByCol[col] = { r = col.r, g = col.g, b = col.b, m = m } end
        if not m then
            -- linear-ish: the palette is sRGB, $color2 multiplies a linear base
            local c = Vector((col.r / 255) ^ 2.2, (col.g / 255) ^ 2.2, (col.b / 255) ^ 2.2) * 1.15
            m = makeMat("bmx_paint_" .. col.r .. "_" .. col.g .. "_" .. col.b, c, PAINT[1], PAINT[2], PAINT[3])
            mats[key] = m
            paintByCol[col] = { r = col.r, g = col.g, b = col.b, m = m }
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
-- BUILDING. One model per size, shared; built in a coroutine, a few ms a frame.
--------------------------------------------------------------------------
local models = {}                     -- key -> { ready, groups, layout } or a building job

-- A MESH IS AT MOST MAX_TRIS TRIANGLES, so the engine takes each in one frame. The
-- whole bucket used to go to BuildFromTriangles in one call (under the 65535-vertex
-- limit: 21000 triangles): the BMX's rubber was 31,000 vertices in one call, the
-- tandem's 58,000, and that call reads every vertex's table through the Lua API.
-- A bucket bigger than this is cut into equal meshes, drawn one after the other with
-- the same material under the same matrix: the same triangles reach the screen in
-- the same order, so the same pixels. Each one is a draw call: 4096 adds a few to a
-- vehicle (the BMX 48 -> 54) and keeps each call to 12,288 vertices.
local MAX_TRIS = 4096
BM.MAX_TRIS = MAX_TRIS
local CHECK_VERTS = 48                -- the clock looked at every this many vertices

local Z_AXIS, X_AXIS = Vector(0, 0, 1), Vector(1, 0, 0)
local function tangentOf(n)
    -- any unit vector perpendicular to the normal: the normal map is flat,
    -- so only the frame's orthogonality matters, not its direction
    local t = n:Cross(Z_AXIS)
    if t:LengthSqr() < 1e-4 then t = n:Cross(X_AXIS) end
    t:Normalize()
    return t
end

-- A layout's points as Vectors, nested tables (gripR = { A, B }) and all.
local function toVectors(t)
    local out = {}
    for key, v in pairs(t) do
        if type(v) == "table" and type(v[1]) == "number" and #v == 3 then
            out[key] = Vector(v[1], v[2], v[3])
        elseif type(v) == "table" then
            out[key] = toVectors(v)
        else
            out[key] = v
        end
    end
    return out
end
BM.LayoutVectors = toVectors

-- THE BUILD'S GARBAGE, AND THE COLLECTOR LEFT TO ITS OWN PACE. A model's source
-- geometry was 100-250 MB of short-lived Lua tables, and the working set it held while
-- meshing (a table a vertex) 60-100 MB. LuaJIT starts a round when the heap has doubled
-- since the last one, so a round that ended mid-build counted that working set as live
-- and let the heap grow by twice as much again: a 32-bit client (GMod's default branch,
-- about 4 GB of address space, half of it the game) aborted after seeing ten or so
-- vehicle kinds (2026-10-08, a test client, 2.6 GB -> 4.0 GB over ten vehicles). 1.2.0
-- answered with the collector stepped at every mesh slice and two full rounds forced in
-- steps before a model counted as ready.
--
-- The causes are gone instead: a vertex is eight numbers in a flat array while the
-- model is built (cl_bikegeo.lua) and a pooled table while it is meshed, so a build
-- makes a sixth of the garbage (the BMX about 57 MB offline, was about 340 MB) and
-- holds a third of the working set. And the forced rounds were a hitch of their own:
-- a round walks the WHOLE client heap, every addon's, and while one runs every
-- allocation anywhere in the client pays for it -- two rounds forced back to back,
-- after every build, were a second or more of slow frames with 15-25 ms ones among
-- them (tools/bench --build --heap 200: a client-sized heap). The heap's high water
-- during a build is the same with them or without (+118 MB, +126 MB there): it comes
-- before the build ends.
-- So nothing is forced: no step, no round, never collectgarbage("collect") (a whole
-- heap in one frame). tests/test_contacts.lua holds the build's garbage to a budget.

-- THE FRAME'S BUDGET, KEPT BY THE BUILD ITSELF. Whoever runs a slice of a build sets
-- the deadline (bmx_bike_build_ms from now); the build looks at the clock every few
-- dozen triangles (cl_bikegeo.lua G.YieldIn) or vertices and gives the frame back as
-- soon as it has passed. It used to give way every 128 triangles or 1500 vertices
-- and be resumed until the time was up, so a frame was the budget plus whatever one
-- of those steps cost -- and with the collector's work landing in them, 20-60 ms.
local deadline, sliceStart = 0, 0
local function pause()
    if SysTime() >= deadline then coroutine.yield() end
end

-- What BuildFromTriangles costs here, a vertex (seconds), learned from each call: a
-- mesh is handed over at the start of a frame's slice unless what is left of the
-- slice is enough for it. It starts at 1 us a vertex, about the dearest a client was
-- thought to be, until the first one is measured.
local commitPerVert = 1e-6

-- FLAT, POOLED VERTICES. A mesh is handed to the engine as a table of vertex tables
-- (pos, normal, u, v, userdata, tangent, binormal), and the engine copies them: the
-- same tables, and the same Vectors in them, are filled again for the next mesh. A
-- vertex used to be two new tables and four new Vectors, a million objects a model
-- for the collector -- and the half-built mesh's table, written while the collector
-- was in the middle of a round, was walked again in one step at its end (LuaJIT's
-- "grey again" list): the 15-30 ms frames of the old build. Pooled objects stay put,
-- and only numbers are written into them. Each value is what it was: the position
-- and normal set from the same numbers, the tangent and binormal worked out by the
-- same Vector calls from the same normal (once for each distinct normal, and copied:
-- the same inputs give the same result), userdata the tangent's components and 1.
local setv
local function vectorSetter()
    if Vector(0, 0, 0).SetUnpacked then
        return function(v, x, y, z) v:SetUnpacked(x, y, z) end
    end
    return function(v, x, y, z) v.x, v.y, v.z = x, y, z end
end

-- The same number to the bit: -0 is not 0 here (a normal's zero's sign can reach the
-- tangent's), and NaN is never the same.
local function same(a, b)
    return a == b and (a ~= 0 or 1 / a == 1 / b)
end

local function newVertex()
    return { pos = Vector(0, 0, 0), normal = Vector(0, 0, 0), u = 0, v = 0,
             userdata = { 0, 0, 0, 1 }, tangent = Vector(0, 0, 0), binormal = Vector(0, 0, 0) }
end

local function buildJob(key, opt)
    local stats = { key = key, slices = 0, ms = 0, worst = 0, commits = 0, verts = 0, commitMs = 0,
                    commitWorst = 0, commitWorstVerts = 0 }
    local job = { stats = stats }
    job.co = coroutine.create(function()
        local G = BMX.BikeGeo
        setv = setv or vectorSetter()
        -- The geometry looks at the clock every few dozen triangles.
        G.YieldIn(coroutine.running(), pause)
        local M = G.Build(opt)
        pause()
        local layout = toVectors(M.layout or {})
        local out = { groups = {}, layout = layout, stats = G.Stats(M) }
        job.partial = out
        local fmt = BM.Material("black")
        local VS = G.VS
        local pool, verts = {}, {}
        -- Each distinct normal's tangent frame, as numbers: FN[s..s+8] = the normal,
        -- the tangent, the binormal, found by frameAt[a number made of the normal]. A
        -- model has a tenth as many distinct normals as vertices (spokes, teeth and
        -- mirrored halves repeat them), and the Vector calls are made once for each.
        local frameAt, FN, nFrames = {}, {}, 0
        for _, gname in ipairs(M.order) do
            local list = {}
            out.groups[gname] = list
            for _, b in ipairs(M.groups[gname]) do
                local entry = { mat = b.mat, detail = b.detail, meshes = {} }
                list[#list + 1] = entry
                local f, tris = b.f, b.tris
                local chunks = math.ceil(tris / MAX_TRIS)
                for c = 1, chunks do
                    local t0, t1 = math.floor((c - 1) * tris / chunks), math.floor(c * tris / chunks)
                    local n = (t1 - t0) * 3
                    -- The builder winds triangles counter-clockwise seen from outside
                    -- (right-handed); Source's front faces are the other way round and the
                    -- back ones are culled, so each triangle's last two vertices are
                    -- swapped here: 1, 3, 2.
                    local k = 0
                    for t = t0, t1 - 1 do
                        for corner = 0, 2 do
                            local o = (t * 3 + (corner == 0 and 0 or 3 - corner)) * VS
                            k = k + 1
                            local vt = pool[k]
                            if not vt then
                                vt = newVertex()
                                pool[k] = vt
                            end
                            -- (written only when it changes: a table written with an object
                            -- while the collector is mid-round is walked again at its end)
                            if verts[k] ~= vt then verts[k] = vt end
                            setv(vt.pos, f[o + 1], f[o + 2], f[o + 3])
                            local nx, ny, nz = f[o + 4], f[o + 5], f[o + 6]
                            local N = vt.normal
                            setv(N, nx, ny, nz)
                            -- the tangent frame of this normal: worked out once a build
                            local key = nx + ny * 1.6180339887498949 + nz * 2.7182818284590451
                            -- (a -0 keyed apart from its 0: mirrored parts have both)
                            if nx == 0 and 1 / nx < 0 then key = key + 0.0625 end
                            if ny == 0 and 1 / ny < 0 then key = key + 0.125 end
                            if nz == 0 and 1 / nz < 0 then key = key + 0.25 end
                            local s = key == key and frameAt[key]
                            if not (s and same(FN[s], nx) and same(FN[s + 1], ny) and same(FN[s + 2], nz)) then
                                local T = tangentOf(N)
                                local Bn = N:Cross(T)
                                if s or key ~= key then
                                    s = 0             -- another normal has its key: worked out, not kept
                                else
                                    s = nFrames * 9 + 1
                                    nFrames = nFrames + 1
                                    frameAt[key] = s
                                end
                                FN[s], FN[s + 1], FN[s + 2] = nx, ny, nz
                                FN[s + 3], FN[s + 4], FN[s + 5] = T.x, T.y, T.z
                                FN[s + 6], FN[s + 7], FN[s + 8] = Bn.x, Bn.y, Bn.z
                            end
                            local tx, ty, tz = FN[s + 3], FN[s + 4], FN[s + 5]
                            setv(vt.tangent, tx, ty, tz)
                            setv(vt.binormal, FN[s + 6], FN[s + 7], FN[s + 8])
                            local ud = vt.userdata
                            ud[1], ud[2], ud[3] = tx, ty, tz
                            vt.u, vt.v = f[o + 7], f[o + 8]
                            if k % CHECK_VERTS == 0 and SysTime() >= deadline then coroutine.yield() end
                        end
                    end
                    for i = #verts, n + 1, -1 do verts[i] = nil end
                    -- Handed to the engine at the start of a slice, unless it fits in
                    -- what is left of this one; the frame after it starts afresh.
                    local now = SysTime()
                    if now - sliceStart > 0.0002 and now + n * commitPerVert > deadline then
                        coroutine.yield()
                        now = SysTime()
                    end
                    local m = Mesh(fmt)
                    m:BuildFromTriangles(verts)
                    local dt = SysTime() - now
                    entry.meshes[#entry.meshes + 1] = m
                    -- (the dearest lately, fading: one slow call keeps it cautious a while)
                    commitPerVert = math.max(dt / n, commitPerVert * 0.75, 1e-9)
                    stats.commits, stats.verts, stats.commitMs = stats.commits + 1, stats.verts + n, stats.commitMs + dt * 1000
                    if dt * 1000 > stats.commitWorst then stats.commitWorst, stats.commitWorstVerts = dt * 1000, n end
                    if SysTime() >= deadline then coroutine.yield() end
                end
                b.f = nil            -- this part's source vertices are meshes now
            end
            M.groups[gname] = nil
        end
        job.partial = nil
        return out
    end)
    return job
end

-- Which build runs this frame, and for how long. ONE BUILD'S SLICE A FRAME, and the
-- vehicles being DRAWN first: a build a drawing asked for this frame or the last runs
-- for bmx_bike_build_ms; one only the prebuild asked for (cl_init.lua: every vehicle in
-- the world, drawn or not) runs for half of it, and only when no drawn vehicle waits.
-- A build already started is finished before another starts (two half-built models
-- would be two working sets), unless a drawn one is waiting.
local frameRan = -1
local background = false
local seq = 0

-- The prebuild marks its asks as the low-rate kind (BM.Background(true) ... (false)).
function BM.Background(on) background = on and true or false end

local function pick(frame)
    local best, bestScore
    for _, m in pairs(models) do
        local job = m.job
        if job and not m.failed then
            local drawn = (m.drawnAt or -10) >= frame - 1
            local asked = drawn or (m.askedAt or -10) >= frame - 1
            if asked then
                local score = (drawn and 4 or 0) + (job.started and 2 or 0)
                if not best or score > bestScore or (score == bestScore and m.seq < best.seq) then
                    best, bestScore = m, score
                end
            end
        end
    end
    return best, best and bestScore >= 4
end

-- One slice of build `m`, `ms` long. Returns the model when it is done.
local function runSlice(key, m, ms)
    local job = m.job
    local t0 = SysTime()
    sliceStart, deadline = t0, t0 + ms / 1000
    job.started = true
    local ok, res = coroutine.resume(job.co)
    local st = job.stats
    local dt = (SysTime() - t0) * 1000
    st.slices, st.ms, st.worst = st.slices + 1, st.ms + dt, math.max(st.worst, dt)
    if not ok then
        m.failed, m.err = true, tostring(res)
        MsgN("[BMX] bike model failed to build, using the simple bike: " .. tostring(res))
        return nil
    end
    if coroutine.status(job.co) == "dead" then
        res.ready = true
        res.buildStats = st
        models[key] = res
        BM.LastBuilds[#BM.LastBuilds + 1] = st
        if #BM.LastBuilds > 32 then table.remove(BM.LastBuilds, 1) end
        return res
    end
end
BM.LastBuilds = {}

-- The model for this size, or nil while it is being built (the caller
-- draws the simple bike meanwhile). Building advances here, a few ms a
-- frame, whichever vehicle asks first (pick() decides which build).
-- `kind` (optional): a model kind other than the BMX's (cl_bikegeo.lua G.Kinds),
-- with `opt` its builder's size: { wheelbase, radius, rearRadius, seat, ... }.
function BM.Get(k, radius, kind, opt)
    if not BM.Enabled() then return nil end
    local key = string.format("%.3f/%.3f", k, radius)
    if kind and kind ~= "bmx" then
        if not BMX.BikeGeo.Kinds[kind] then return nil end
        local seat = opt and opt.seat
        key = string.format("%s/%s/%.2f/%.2f/%s", kind, key, opt and opt.wheelbase or 0,
            opt and opt.rearRadius or 0, seat and string.format("%.2f,%.2f,%.2f", seat[1], seat[2], seat[3]) or "")
    end
    local m = models[key]
    if m and m.ready then return m end
    if m and m.failed then return nil end
    if not m then
        local build = { k = k, radius = radius }
        if kind and kind ~= "bmx" then
            build = {}
            for kk, v in pairs(opt or {}) do build[kk] = v end
            build.kind, build.k, build.radius = kind, k, radius
        end
        seq = seq + 1
        m = { job = buildJob(key, build), seq = seq, key = key }
        models[key] = m
    end
    local frame = FrameNumber()
    m.askedAt = frame
    if not background then m.drawnAt = frame end
    if frameRan == frame then return nil end      -- one build's slice a frame
    frameRan = frame
    local run, drawn = pick(frame)
    if not run then return nil end
    local budget = math.max(cvBudget:GetFloat(), 0.5)
    local done = runSlice(run.key, run, drawn and budget or math.max(budget * 0.5, 0.5))
    if run == m then return done end
    return nil
end

-- A VEHICLE'S MODEL, REMEMBERED. Every vehicle in the world asks for its model once or
-- twice a frame (the prebuild Think, its own Draw), and each ask built an options table
-- or three and two or three string.format keys to find a model built long ago. The
-- ready model is kept on `owner` (the entity) while what chose it -- the registration,
-- the config table and the config's revision -- is the same, and not once BM.Clear has
-- marked it cleared or with the models switched off. `get(...)` is the full ask.
function BM.Remembered(owner, bike, C, get, ...)
    if not BM.Enabled() then return nil end
    local r = owner.bmxModelMemo
    if r and r.bike == bike and r.cfg == C and r.rev == BMX.ConfigRevision and not r.model.cleared then
        return r.model
    end
    local m = get(...)
    if m then owner.bmxModelMemo = { bike = bike, cfg = C, rev = BMX.ConfigRevision, model = m } end
    return m
end

-- What the cache holds, for a bug report or a probe: key -> "ready" | "building" |
-- "failed: <error>".
function BM.Status()
    local out = {}
    for key, m in pairs(models) do
        out[key] = m.ready and "ready" or m.failed and ("failed: " .. tostring(m.err)) or "building"
    end
    return out
end

local function destroyGroups(groups)
    for _, list in pairs(groups) do
        for _, e in ipairs(list) do
            for _, mesh in ipairs(e.meshes) do if IsValid(mesh) then mesh:Destroy() end end
        end
    end
end

-- Throw every built model away (bmx_bike_model_rebuild, or a hot reload), and the
-- meshes of any build half done.
function BM.Clear()
    for _, m in pairs(models) do
        m.cleared = true                -- a bike still holding it must not draw it
        if m.groups then destroyGroups(m.groups) end
        if m.job and m.job.partial then destroyGroups(m.job.partial.groups) end
    end
    models = {}
end
concommand.Add("bmx_bike_model_rebuild", function() BM.Clear() end)

-- WHAT THE BUILDS COST ON THIS CLIENT: each model built this session, its frames,
-- the worst frame's build time, and what the engine took to take its meshes
-- (BuildFromTriangles, which nothing offline can time). docs/TESTING.md.
concommand.Add("bmx_bike_build_report", function()
    MsgN(string.format("[BMX] model builds (bmx_bike_build_ms %.1f, at most %d triangles a mesh):",
        cvBudget:GetFloat(), MAX_TRIS))
    for _, st in ipairs(BM.LastBuilds) do
        MsgN(string.format("  %s: %d frames, %.0f ms, worst frame %.2f ms | %d meshes, %d vertices, " ..
            "BuildFromTriangles %.1f ms in all, worst %.2f ms (%d vertices), %.2f us a vertex",
            st.key, st.slices, st.ms, st.worst, st.commits, st.verts, st.commitMs, st.commitWorst,
            st.commitWorstVerts, st.verts > 0 and st.commitMs * 1000 / st.verts or 0))
    end
    for key, s in pairs(BM.Status()) do
        if s ~= "ready" then MsgN("  " .. key .. ": " .. s) end
    end
end)

--------------------------------------------------------------------------
-- LIGHTING
--------------------------------------------------------------------------
local AXES = { Vector(1, 0, 0), Vector(-1, 0, 0), Vector(0, 1, 0), Vector(0, -1, 0), Vector(0, 0, 1), Vector(0, 0, -1) }

local function sample(pos, dir)
    local c = render.ComputeLighting(pos, dir)
    local d = render.ComputeDynamicLighting(pos, dir)
    return c + d
end

local LIGHT = { type = MATERIAL_LIGHT_DIRECTIONAL, range = 0,
                constantFalloff = 1, linearFalloff = 0, quadraticFalloff = 0 }
local LIGHTS, NO_LIGHTS = { LIGHT }, {}

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
        -- (One table, filled afresh each time: the engine copies the light.)
        LIGHT.color = L.col
        LIGHT.dir = -L.dir              -- the way the light travels
        LIGHT.pos = pos + L.dir * 4096
        render.SetLocalModelLights(LIGHTS)
    else
        render.SetLocalModelLights(NO_LIGHTS)
    end
end

function BM.EndLighting()
    render.SetLocalModelLights(NO_LIGHTS)
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
local RING_COS, RING_SIN = {}, {}     -- sides -> cos, sin of j / sides of a turn, j = 0..sides
function BM.DrawTube(pts, radius, role, sides, paint)
    sides = sides or 6
    local n = #pts
    if n < 2 then return end
    render.SetMaterial(BM.Material(role, paint))
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
    -- EACH RING'S VERTICES ONCE. Every point of a ring is a corner of four quads
    -- (two along the tube, two round it), and each quad used to work out its own
    -- four corners -- the direction, its tangent frame, the position -- with a table
    -- per quad: a motorbike's coiled shock spring (70 rings of 5) cost more than the
    -- rest of the bike and its rider together, every frame (tools/bench). The same
    -- vectors from the same arithmetic, worked out once a ring (j = sides is the
    -- closing angle, 2 pi, as the last quad round has always had it), then emitted in
    -- the same order.
    local cs, sn = RING_COS[sides], RING_SIN[sides]
    if not cs then
        cs, sn = {}, {}
        for j = 0, sides do
            local a = j / sides * math.pi * 2
            cs[j], sn[j] = math.cos(a), math.sin(a)
        end
        RING_COS[sides], RING_SIN[sides] = cs, sn
    end
    local P, D, TS, TT, TX, TY, TZ = {}, {}, {}, {}, {}, {}, {}
    for i = 1, n do
        local Ni, bi, p = N[i], T[i]:Cross(N[i]), pts[i]
        local base = (i - 1) * (sides + 1)
        for j = 0, sides do
            local d = Ni * cs[j] + bi * sn[j]
            local t = tangentOf(d)
            local k = base + j
            P[k], D[k], TS[k], TT[k] = p + d * radius, d, t, d:Cross(t)
            TX[k], TY[k], TZ[k] = t.x, t.y, t.z
        end
    end
    local Position, Normal, TangentS, TangentT = mesh.Position, mesh.Normal, mesh.TangentS, mesh.TangentT
    local UserData, TexCoord, AdvanceVertex = mesh.UserData, mesh.TexCoord, mesh.AdvanceVertex
    mesh.Begin(MATERIAL_QUADS, (n - 1) * sides)
    for i = 1, n - 1 do
        local r1, r2 = (i - 1) * (sides + 1), i * (sides + 1)
        for j = 0, sides - 1 do
            -- ring i at j, ring i+1 at j, ring i+1 at j+1, ring i at j+1
            for q = 1, 4 do
                local k = (q == 1 and r1 + j) or (q == 2 and r2 + j) or (q == 3 and r2 + j + 1) or (r1 + j + 1)
                Position(P[k])
                Normal(D[k])
                TangentS(TS[k])
                TangentT(TT[k])
                UserData(TX[k], TY[k], TZ[k], 1)
                TexCoord(0, 0, 0)
                AdvanceVertex()
            end
        end
    end
    mesh.End()
end
