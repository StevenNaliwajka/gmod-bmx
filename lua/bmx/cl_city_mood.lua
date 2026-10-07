--[[--------------------------------------------------------------------------
    bmx/cl_city_mood.lua

    The hour and the season of a map's city: a late autumn afternoon on
    gm_skatepark. Everything here is client-side looks, nothing else:

        sky        the map's bright noon sky drawn over with a low golden one
        haze       warm fog that softens the skyline into the distance
        grade      a slight warm, low-sun colour grade over the whole frame
        lamps      the street lamps' glow, and dynamic lights from the nearest
                   few, so riders and ramps under them are lit
        leaves     the odd leaf letting go of a tree and drifting down on the
                   wind, settling on the ground for a while

    The map's definition (sh_city_maps.lua) says what: its `mood` table. A
    map with no mood gets none of this.

    Convars (client):
        bmx_city_mood     1  sky, haze, grade and lamp lights
        bmx_city_leaves   1  falling leaves
----------------------------------------------------------------------------]]

local City = BMX.City

local cvMood = CreateClientConVar("bmx_city_mood", "1", true, false, "BMX: the city's late-afternoon sky, haze and lamp light (1/0)")
local cvLeaves = CreateClientConVar("bmx_city_leaves", "1", true, false, "BMX: leaves falling from the city's trees (1/0)")

local function mood()
    if not cvMood:GetBool() or not City.Enabled() then return nil end
    local L = City._layout
    return L and City.meshes and L.mood or nil
end

--------------------------------------------------------------------------
-- Sky. Each face of a cube round the camera, drawn after the map's own 2D
-- sky so it replaces it. Faces by the direction they look in; `skyYaw` turns
-- the whole box so the bright part of the clouds sits where the map's sun is.
--------------------------------------------------------------------------
City._skyMats = City._skyMats or {}
local function skyMat(name, face, tint)
    local key = name .. face
    local m = City._skyMats[key]
    if m then return m end
    m = CreateMaterial("bmxsky_" .. key:gsub("%W", "_"), "UnlitGeneric", {
        ["$basetexture"] = name .. face,
        ["$nofog"] = "1",
        ["$ignorez"] = "1",
        ["$color"] = string.format("[%g %g %g]", tint[1], tint[2], tint[3]),
    })
    City._skyMats[key] = m
    return m
end

-- face -> the direction the camera looks to see it, and its right and up
-- (Source's skybox convention: ft looks +x... turned by skyYaw)
local FACES = {
    { "ft", Vector(1, 0, 0), Vector(0, -1, 0), Vector(0, 0, 1) },
    { "bk", Vector(-1, 0, 0), Vector(0, 1, 0), Vector(0, 0, 1) },
    { "lf", Vector(0, 1, 0), Vector(1, 0, 0), Vector(0, 0, 1) },
    { "rt", Vector(0, -1, 0), Vector(-1, 0, 0), Vector(0, 0, 1) },
    { "up", Vector(0, 0, 1), Vector(0, -1, 0), Vector(-1, 0, 0) },
    { "dn", Vector(0, 0, -1), Vector(0, -1, 0), Vector(1, 0, 0) },
}
City.SkyFaces = FACES

function City.DrawSky(m)
    local S = 2000
    local yaw = m.skyYaw or 0
    local tint = m.skyTint or { 1, 1, 1 }
    render.OverrideDepthEnable(true, false)
    cam.Start3D(Vector(0, 0, 0), EyeAngles())
    for _, f in ipairs(FACES) do
        local d, r, u = Vector(f[2]), Vector(f[3]), Vector(f[4])
        if yaw ~= 0 then
            local a = Angle(0, yaw, 0)
            d:Rotate(a) r:Rotate(a) u:Rotate(a)
        end
        local c = d * S
        render.SetMaterial(skyMat(m.sky, f[1], tint))
        -- top-left, top-right, bottom-right, bottom-left
        render.DrawQuad(c - r * S + u * S, c + r * S + u * S, c + r * S - u * S, c - r * S - u * S)
    end
    cam.End3D()
    render.OverrideDepthEnable(false, false)
end

hook.Add("PostDraw2DSkyBox", "BMXCityMood", function()
    local m = mood()
    if m and m.sky then City.DrawSky(m) end
end)

--------------------------------------------------------------------------
-- Haze: warm, thin, far. The skyline fades into it; the park does not.
--------------------------------------------------------------------------
local function fog(m, scale)
    local f = m.fog
    if not f then return end
    render.FogMode(MATERIAL_FOG_LINEAR)
    render.FogStart(f.start * (scale or 1))
    render.FogEnd(f.finish * (scale or 1))
    render.FogMaxDensity(f.density)
    render.FogColor(f.color[1], f.color[2], f.color[3])
    return true
end
hook.Add("SetupWorldFog", "BMXCityMood", function()
    local m = mood()
    if m then return fog(m) end
end)
hook.Add("SetupSkyboxFog", "BMXCityMood", function(scale)
    local m = mood()
    if m then return fog(m, scale) end
end)

--------------------------------------------------------------------------
-- The grade: a little warmer, a little less bright, a little less saturated.
--------------------------------------------------------------------------
hook.Add("RenderScreenspaceEffects", "BMXCityMood", function()
    local m = mood()
    if not m or not m.grade or not DrawColorModify then return end
    local g = m.grade
    DrawColorModify({
        ["$pp_colour_addr"] = g.addr or 0, ["$pp_colour_addg"] = g.addg or 0, ["$pp_colour_addb"] = g.addb or 0,
        ["$pp_colour_brightness"] = g.brightness or 0, ["$pp_colour_contrast"] = g.contrast or 1,
        ["$pp_colour_colour"] = g.colour or 1,
        ["$pp_colour_mulr"] = g.mulr or 0, ["$pp_colour_mulg"] = g.mulg or 0, ["$pp_colour_mulb"] = g.mulb or 0,
    })
end)

--------------------------------------------------------------------------
-- Lamps: a glow at every lamp head, and real dynamic lights at the few
-- nearest the camera (the engine has a handful of them; the floor's pools
-- are baked, these light the ramps, the bikes and the riders).
--------------------------------------------------------------------------
local GLOW
local DLIGHTS = 6

hook.Add("PostDrawTranslucentRenderables", "BMXCityMoodLamps", function(depth, sky)
    if depth or sky then return end
    local m = mood()
    local L = City._layout
    if not m or not L or not L.lamps then return end
    local c = m.lampColor or { 255, 190, 120 }
    local col = Color(c[1], c[2], c[3], 230)
    GLOW = GLOW or Material("sprites/light_glow02_add")
    render.SetMaterial(GLOW)
    for _, l in ipairs(L.lamps) do
        local h = l._head or Vector(l.head[1], l.head[2], l.head[3])
        l._head = h
        render.DrawSprite(h, 110, 110, col)
        render.DrawSprite(h, 34, 34, color_white)
    end
end)

function City.NearestLamps(L, eye, n)
    local list = {}
    for _, l in ipairs(L.lamps or {}) do
        local dx, dy, dz = l.head[1] - eye.x, l.head[2] - eye.y, l.head[3] - eye.z
        list[#list + 1] = { l = l, d = dx * dx + dy * dy + dz * dz }
    end
    table.sort(list, function(a, b) return a.d < b.d end)
    local out = {}
    for i = 1, math.min(n, #list) do out[i] = list[i].l end
    return out
end

hook.Add("Think", "BMXCityMoodLamps", function()
    local m = mood()
    local L = City._layout
    if not m or not L or not L.lamps or not DynamicLight then return end
    local c = m.lampColor or { 255, 190, 120 }
    for i, l in ipairs(City.NearestLamps(L, EyePos(), DLIGHTS)) do
        local d = DynamicLight(0x4C00 + i)
        if d then
            d.pos = Vector(l.head[1], l.head[2], l.head[3] - 24)
            d.r, d.g, d.b = c[1], c[2], c[3]
            d.brightness = m.lampBrightness or 1.4
            d.decay = 1000
            d.size = m.lampSize or 560
            d.dietime = CurTime() + 0.5
        end
    end
end)

--------------------------------------------------------------------------
-- Falling leaves. Now and then a leaf lets go of a tree near the camera and
-- drifts down, fluttering, carried east by the west wind; it lies on the
-- ground a while, then is gone. Drawn as small two-sided quads in the
-- autumn colours; at most MAX at once.
--------------------------------------------------------------------------
local MAX = 90
local PALETTE = {
    { 196, 74, 28 }, { 214, 120, 30 }, { 222, 168, 52 }, { 150, 52, 30 }, { 170, 96, 40 }, { 120, 70, 36 },
}
City._leaves = City._leaves or {}
local nextLeaf = 0

local function trees()
    local out = {}
    for _, p in ipairs(City.plants or {}) do if not p.still then out[#out + 1] = p end end
    return out
end
local treeList, treeFor

function City.SpawnLeaf(tree, rnd, ground)
    rnd = rnd or math.random
    local P = City.Plants[tree.kind]
    local s = tree.radius / math.max(P.r, P.h / 2)
    local r = P.r * s * 0.6
    local a = rnd() * math.pi * 2
    local c = PALETTE[1 + math.floor(rnd() * #PALETTE)]
    return {
        pos = Vector(tree.pos.x + math.cos(a) * r * rnd(), tree.pos.y + math.sin(a) * r * rnd(),
                     tree.pos.z + P.h * s * (0.45 + rnd() * 0.45)),
        ground = ground or (tree.pos.z + 1),
        fall = 34 + rnd() * 26,
        drift = Vector(30 + rnd() * 40, (rnd() - 0.5) * 30, 0),
        phase = rnd() * 6.28, spin = (rnd() - 0.5) * 400, yaw = rnd() * 360,
        size = 4 + rnd() * 3.5,
        col = { c[1] * 0.85, c[2] * 0.85, c[3] * 0.85 },
        rest = nil,
    }
end

-- Move every leaf on by dt; drop the ones that have lain long enough.
function City.StepLeaves(leaves, dt, t)
    for i = #leaves, 1, -1 do
        local f = leaves[i]
        if f.rest then
            if t > f.rest then table.remove(leaves, i) end
        else
            local flutter = math.sin(t * 2.6 + f.phase)
            f.pos.x = f.pos.x + (f.drift.x + flutter * 26) * dt
            f.pos.y = f.pos.y + (f.drift.y + math.cos(t * 2.1 + f.phase) * 18) * dt
            f.pos.z = f.pos.z - f.fall * (0.75 + 0.35 * flutter * flutter) * dt
            f.yaw = f.yaw + f.spin * dt
            if f.pos.z <= f.ground then
                f.pos.z = f.ground
                f.rest = t + 9 + (f.phase % 1) * 6
            end
        end
    end
end

hook.Add("Think", "BMXCityLeaves", function()
    local m = mood()
    if not m or not cvLeaves:GetBool() or not City.plants then
        if #City._leaves > 0 then City._leaves = {} end
        return
    end
    if treeFor ~= City.plants then treeList, treeFor = trees(), City.plants end
    local t = CurTime()
    local dt = math.min(FrameTime(), 0.1)
    City.StepLeaves(City._leaves, dt, t)
    if t >= nextLeaf and #treeList > 0 and #City._leaves < MAX then
        nextLeaf = t + (m.leafEvery or 0.25) * (0.5 + math.random())
        -- a tree near the camera, so the leaves fall where somebody is
        local eye = EyePos()
        for _ = 1, 6 do
            local tr = treeList[math.random(#treeList)]
            if tr.pos:DistToSqr(eye) < 2200 * 2200 then
                -- a tree in the park drops its leaves on the park's floor
                local L, ground = City._layout, nil
                local pk = L and L.def and L.def.park
                if pk and tr.pos.x > pk[1] and tr.pos.x < pk[4] and tr.pos.y > pk[2] and tr.pos.y < pk[5] and tr.pos.z < pk[3] + 100 then
                    ground = pk[3] + 1.5
                end
                City._leaves[#City._leaves + 1] = City.SpawnLeaf(tr, nil, ground)
                break
            end
        end
    end
end)

hook.Add("PostDrawTranslucentRenderables", "BMXCityLeaves", function(depth, sky)
    if depth or sky then return end
    local leaves = City._leaves
    if #leaves == 0 then return end
    local t = CurTime()
    render.SetColorMaterial()
    mesh.Begin(MATERIAL_QUADS, #leaves * 2)
    local ang = Angle()
    for _, f in ipairs(leaves) do
        -- tumbling in the air, flat on the ground
        if f.rest then ang.p, ang.y, ang.r = 0, f.yaw, 0
        else ang.p, ang.y, ang.r = math.sin(t * 3.1 + f.phase) * 60, f.yaw, math.cos(t * 2.3 + f.phase) * 50 end
        local fw, rt = ang:Forward() * f.size, ang:Right() * (f.size * 0.55)
        local p = f.pos
        local a = 255
        if f.rest then a = math.Clamp((f.rest - t) * 128, 0, 255) end
        local r, g, b = f.col[1], f.col[2], f.col[3]
        -- both windings: a leaf has two sides
        for _, v in ipairs({ { p + fw, p + rt, p - fw, p - rt }, { p + fw, p - rt, p - fw, p + rt } }) do
            for k = 1, 4 do
                mesh.Position(v[k]) mesh.Color(r, g, b, a) mesh.AdvanceVertex()
            end
        end
    end
    mesh.End()
end)
