--[[--------------------------------------------------------------------------
    bmx/cl_city.lua

    Draws the city sh_city.lua lays out: the buildings, the viaducts, the
    signs, and the subway trains running over the park.

    WHY A RENDER HOOK AND NOT ENTITIES. Almost all of the city stands outside
    the map's box, in the void. The engine draws an entity only if it sits in a
    visleaf the camera can see, and the void has none, so an entity out there
    is never drawn. A hook is drawn every frame regardless, and the sky
    brushes in front of it are not geometry (the sky only fills pixels nothing
    else wrote), so the city shows through them.

    WHY UNLIT. The HL2 building panels are LightmappedGeneric, and a mesh has
    no lightmap. Each surface is copied into an UnlitGeneric material and lit
    by vertex colour: sh_city bakes a sun term per face from the map's own
    light_environment, so the shading agrees with the park's.

    THE TRAINS ARE ON A TIMETABLE, not networked: every line runs on a fixed
    period from CurTime(), which the server keeps in sync with every client, so
    every rider sees the same train at the same place without a single message.

    Convars (client):
        bmx_city_draw     1  draw the city at all
        bmx_city_trains   1  run the trains (and their sound)
        bmx_city_signs    1  draw the signs
        bmx_city_plants   1  draw the trees, shrubs and roof gardens
----------------------------------------------------------------------------]]

local City = BMX.City

local cvDraw = CreateClientConVar("bmx_city_draw", "1", true, false, "BMX: draw the city around the park (1/0)")
local cvTrains = CreateClientConVar("bmx_city_trains", "1", true, false, "BMX: run the subway trains (1/0)")
local cvSigns = CreateClientConVar("bmx_city_signs", "1", true, false, "BMX: draw the city's signs (1/0)")
local cvPlants = CreateClientConVar("bmx_city_plants", "1", true, false, "BMX: draw the city's trees, shrubs and roof gardens (1/0)")

City.TrainModel = "models/props_trainstation/train_outro_car01.mdl"
City.TrainCar = { length = 650, gap = 14, lift = 104 }   -- lift: the model's floor is 104 below its origin
City.TrainSound = "sound/ambient/machines/train_wheels_overhead_loop1.wav"
City.TrainHorn = "ambient/alarms/train_horn_distant1.wav"

-- At most this many quads in one IMesh. Well under the vertex ceiling a single
-- mesh can hold, so no map's city can ever overflow one.
local QUADS_PER_MESH = 4000

--------------------------------------------------------------------------
-- Materials
--------------------------------------------------------------------------
City._mats = City._mats or {}
function City.Material(key)
    local m = City._mats[key]
    if m then return m end
    local M = City.Materials[key]
    local params = {
        ["$basetexture"] = M.tex,
        ["$vertexcolor"] = "1",
        ["$nocull"] = "1",
    }
    if M.alpha then
        params["$alphatest"] = "1"
        params["$alphatestreference"] = "0.5"
    end
    -- a tint that may go past 1 (a vertex colour cannot): the autumn leaves
    if M.mul then params["$color"] = string.format("[%g %g %g]", M.mul[1], M.mul[2], M.mul[3]) end
    m = CreateMaterial("bmxcity_" .. key, "UnlitGeneric", params)
    City._mats[key] = m
    return m
end

--------------------------------------------------------------------------
-- Meshes
--------------------------------------------------------------------------
local function clamp255(x) x = math.floor(x * 255 + 0.5) if x < 0 then return 0 elseif x > 255 then return 255 end return x end

-- Draw order: what is nearest the park first, so the GPU's depth test throws
-- away the pixels of everything behind it before shading them. The viaducts
-- cross in front of everything, the frontage hides most of the back row, the
-- back row hides most of the skyline.
City.GroupRank = { via = 1, front = 2, back = 3, sky = 4, misc = 5 }

local function rankOf(group)
    return City.GroupRank[group:match("^(%w+)") or "misc"] or 5
end

function City.BuildMeshes(layout)
    City.FreeMeshes()
    -- bucket every quad by (group, material): a group is one part of the
    -- city with its own bounds, so a part out of view costs nothing
    local buckets, order = {}, {}
    for key, list in pairs(layout.faces) do
        for _, q in ipairs(list) do
            local g = q[18] or "misc"
            local id = g .. "|" .. key
            local b = buckets[id]
            if not b then
                b = { group = g, key = key, quads = {},
                      mins = { math.huge, math.huge, math.huge }, maxs = { -math.huge, -math.huge, -math.huge } }
                buckets[id] = b
                order[#order + 1] = b
            end
            b.quads[#b.quads + 1] = q
            for c = 0, 3 do
                for a = 1, 3 do
                    local v = q[c * 3 + a]
                    if v < b.mins[a] then b.mins[a] = v end
                    if v > b.maxs[a] then b.maxs[a] = v end
                end
            end
        end
    end
    table.sort(order, function(a, b)
        local ra, rb = rankOf(a.group), rankOf(b.group)
        if ra ~= rb then return ra < rb end
        if a.group ~= b.group then return a.group < b.group end
        return a.key < b.key
    end)

    -- the hour of the day: every surface takes the light's colour (a late
    -- autumn afternoon is warm and low); the floor's own light is baked in
    local mood = layout.mood and layout.mood.light or { 1, 1, 1 }
    local out = {}
    for _, b in ipairs(order) do
        local M = City.Materials[b.key]
        local base = M.color or { 1, 1, 1 }
        local col = { base[1] * mood[1], base[2] * mood[2], base[3] * mood[3] }
        local mat = City.Material(b.key)
        local list = b.quads
        local i = 1
        while i <= #list do
            local n = math.min(#list - i + 1, QUADS_PER_MESH)
            local m = Mesh(mat)
            mesh.Begin(m, MATERIAL_QUADS, n)
            for j = i, i + n - 1 do
                local q = list[j]
                local s = q[17]
                local uv = { q[13], q[14], q[15], q[14], q[15], q[16], q[13], q[16] }
                for c = 0, 3 do
                    local r, g, bl
                    if q[19] then
                        -- lit per vertex (the floor): its own colours
                        local k = 19 + c * 3
                        r, g, bl = clamp255(q[k] * base[1]), clamp255(q[k + 1] * base[2]), clamp255(q[k + 2] * base[3])
                    else
                        r, g, bl = clamp255(s * col[1]), clamp255(s * col[2]), clamp255(s * col[3])
                    end
                    mesh.Position(Vector(q[c * 3 + 1], q[c * 3 + 2], q[c * 3 + 3]))
                    mesh.TexCoord(0, uv[c * 2 + 1], uv[c * 2 + 2])
                    mesh.Color(r, g, bl, 255)
                    mesh.AdvanceVertex()
                end
            end
            mesh.End()
            local cx, cy, cz = (b.mins[1] + b.maxs[1]) / 2, (b.mins[2] + b.maxs[2]) / 2, (b.mins[3] + b.maxs[3]) / 2
            local dx, dy, dz = b.maxs[1] - cx, b.maxs[2] - cy, b.maxs[3] - cz
            out[#out + 1] = { mesh = m, mat = mat, key = b.key, group = b.group, quads = n,
                              center = Vector(cx, cy, cz), radius = math.sqrt(dx * dx + dy * dy + dz * dz) }
            i = i + n
        end
    end
    City.meshes = out
    return out
end

-- Is a sphere anywhere in the view? A cone test against the camera, with the
-- wider of the two half-angles, so it never culls something on screen.
function City.InView(center, radius, eye, fwd, cosHalf, sinHalf)
    local d = center - eye
    local along = d:Dot(fwd)
    if along < -radius then return false end            -- wholly behind
    local dist2 = d:Dot(d)
    if dist2 <= radius * radius then return true end    -- around the camera
    local perp = math.sqrt(math.max(dist2 - along * along, 0))
    -- distance from the sphere's centre to the cone's surface
    return perp * cosHalf - along * sinHalf <= radius
end

function City.FreeMeshes()
    for _, m in ipairs(City.meshes or {}) do
        if m.mesh and m.mesh.Destroy then m.mesh:Destroy() end
    end
    City.meshes = nil
end

--------------------------------------------------------------------------
-- Trains
--------------------------------------------------------------------------

-- Where line `l`'s train is at time t: nil when none is running, else the
-- head's distance along the line from its `from` end, and the direction it is
-- going (+1 from -> to, -1 back). Pure, for the tests.
function City.TrainAt(l, t)
    local C = City.TrainCar
    local len = l.to - l.from
    local train = l.cars * C.length + (l.cars - 1) * C.gap
    local run = (len + 2 * l.runout + train) / l.speed
    local since = t - l.offset
    local cycle = math.floor(since / l.period)
    local phase = since - cycle * l.period
    if phase < 0 or phase > run then return nil end
    local dir = (cycle % 2 == 0) and 1 or -1
    local head = -l.runout + phase * l.speed            -- distance travelled
    return { head = head, dir = dir, cycle = cycle, train = train, run = run, phase = phase }
end

-- The world position and yaw of car `i` (1 = lead) of a train at `st`.
function City.CarPos(l, st, i)
    local C = City.TrainCar
    local back = (i - 0.5) * C.length + (i - 1) * C.gap
    local d = st.head - back                             -- distance from the start end
    local a = st.dir > 0 and (l.from + d) or (l.to - d)
    local z = l.deck + City.Viaduct.rail + C.lift
    -- train_outro_car01 is long along its own y axis (-322..327, measured on
    -- the server): yaw 0 lays it along world y, yaw 90 along world x. It
    -- faces the way it is going.
    if l.axis == "y" then return l.at, a, z, st.dir > 0 and 0 or 180 end
    return a, l.at, z, st.dir > 0 and -90 or 90
end

City._cars = City._cars or {}
local function carModel(i)
    local m = City._cars[i]
    if IsValid(m) then return m end
    if util.IsValidModel and not util.IsValidModel(City.TrainModel) then return nil end
    m = ClientsideModel(City.TrainModel, RENDERGROUP_OPAQUE)
    if not IsValid(m) then return nil end
    m:SetNoDraw(true)
    City._cars[i] = m
    return m
end

-- One looping wheel-rumble channel per line, moved with the train.
City._sounds = City._sounds or {}
local function lineSound(name, pos, on)
    local s = City._sounds[name]
    if not on then
        if s and s.ch and s.ch:IsValid() then s.ch:Stop() end
        City._sounds[name] = nil
        return
    end
    if not s then
        s = { pending = true }
        City._sounds[name] = s
        if sound and sound.PlayFile then
            sound.PlayFile(City.TrainSound, "3d noblock", function(ch)
                if not ch then return end
                if City._sounds[name] ~= s then ch:Stop() return end
                s.ch = ch
                ch:EnableLooping(true)
                ch:Set3DFadeDistance(900, 0)
                ch:SetVolume(1)
                ch:SetPos(s.pos or pos)
                ch:Play()
            end)
        end
    end
    s.pos = pos
    if s.ch and s.ch:IsValid() then s.ch:SetPos(pos) end
end

local function drawTrains(layout, t)
    local used = 0
    render.SuppressEngineLighting(true)
    -- a fixed light: the cars spend half their run outside the map, where the
    -- engine has no lighting to give them, and should not go black there
    render.ResetModelLighting(0.45, 0.45, 0.48)
    render.SetModelLighting(BOX_TOP, 1, 0.98, 0.9)
    render.SetModelLighting(BOX_BACK, 0.9, 0.88, 0.8)
    for _, l in ipairs(layout.lines) do
        local st = City.TrainAt(l, t)
        if st then
            for i = 1, l.cars do
                local x, y, z, yaw = City.CarPos(l, st, i)
                used = used + 1
                local m = carModel(used)
                if m then
                    m:SetPos(Vector(x, y, z))
                    m:SetAngles(Angle(0, yaw, 0))
                    m:SetupBones()
                    m:DrawModel()
                end
                if i == 1 then
                    -- the sound rides the middle of the train
                    local mx, my, mz = City.CarPos(l, st, math.ceil(l.cars / 2))
                    lineSound(l.name, Vector(mx, my, mz), true)
                end
            end
            -- the horn, once, as it comes out of the portal
            if l._horn ~= st.cycle and st.head > -300 then
                l._horn = st.cycle
                local hx, hy, hz = City.CarPos(l, st, 1)
                if sound and sound.Play then sound.Play(City.TrainHorn, Vector(hx, hy, hz), 95, 100, 0.6) end
            end
        else
            lineSound(l.name, nil, false)
        end
    end
    render.SuppressEngineLighting(false)
end

--------------------------------------------------------------------------
-- Plants
--
-- One ClientsideModel per kind of plant, moved to each plant and drawn there
-- from this hook, the way the trains are. Not one entity per plant: they are
-- never in the engine's hands, so nothing fades them out with distance or
-- drops them when they leave the PVS (most of the roof gardens are out in the
-- void, which has no visleaf at all), and there is nothing on the server for
-- a physgun, toolgun or cleanup to grab. A plant is skipped only when it is
-- wholly out of the camera's view, and always drawn at its full LOD. The
-- bushes and hedges are not here: they are leaf cards in the city's meshes.
--------------------------------------------------------------------------
City._plantEnts = City._plantEnts or {}
local function plantModel(kind, existing)
    local m = City._plantEnts[kind]
    if m == false then return nil end
    if IsValid(m) or existing then return IsValid(m) and m or nil end
    local P = City.Plants[kind]
    if not P or (util.IsValidModel and not util.IsValidModel(P.model)) then
        City._plantEnts[kind] = false
        return nil
    end
    m = ClientsideModel(P.model, RENDERGROUP_OPAQUE)
    if not IsValid(m) then return nil end
    m:SetNoDraw(true)
    -- full detail at every distance: HL2's trees drop to a bare-branch LOD
    -- past ~800 units, and from across the park every tree went leafless
    m:SetLOD(0)
    City._plantEnts[kind] = m
    return m
end

-- Each plant as the numbers the draw loop needs, built once.
function City.BuildPlants(layout)
    local out = {}
    for _, p in ipairs(layout.props or {}) do
        local P = City.Plants[p.kind]
        local mx
        if p.scale ~= 1 then
            mx = Matrix()
            mx:Scale(Vector(p.scale, p.scale, p.scale))
        end
        out[#out + 1] = {
            kind = p.kind, pos = Vector(p.x, p.y, p.z), ang = Angle(0, p.yaw, 0), matrix = mx,
            center = Vector(p.x, p.y, p.z + P.h * p.scale / 2), radius = math.max(P.r, P.h / 2) * p.scale,
            still = P.still, phase = (p.x * 0.0123 + p.y * 0.0171) % (math.pi * 2),
            -- tall thin trees sway further at the top than squat ones
            sway = math.min(1.6, 0.6 + P.h * p.scale / 600),
        }
    end
    -- grouped by kind: one model swap per kind per frame
    table.sort(out, function(a, b) return a.kind < b.kind end)
    City.plants = out
    -- the models are made here, once, not in the middle of a frame
    for _, p in ipairs(out) do plantModel(p.kind) end
    return out
end

local function drawPlants(eye, fwd, cosH, sinH)
    local list = City.plants
    if not list or #list == 0 then return 0 end
    render.SuppressEngineLighting(true)
    -- daylight from the west, as the map's sun: a bright top, a soft fill
    render.ResetModelLighting(0.36, 0.38, 0.34)
    render.SetModelLighting(BOX_TOP, 0.95, 0.95, 0.85)
    render.SetModelLighting(BOX_BACK, 0.75, 0.72, 0.62)
    render.SetModelLighting(BOX_BOTTOM, 0.18, 0.2, 0.16)
    local drawn, kind, m = 0, nil, nil
    -- the wind: a slow sway, every tree on its own phase, and a gust now
    -- and then that leans them all a little further (from the west, as
    -- the weather comes)
    local t = CurTime()
    local gust = 1 + 0.8 * math.max(0, math.sin(t * 0.21)) ^ 3
    local ang = Angle(0, 0, 0)
    for _, p in ipairs(list) do
        if City.InView(p.center, p.radius, eye, fwd, cosH, sinH) then
            if p.kind ~= kind then kind = p.kind m = plantModel(kind, true) end
            if m then
                m:SetPos(p.pos)
                if p.still then
                    m:SetAngles(p.ang)
                else
                    local ph = p.phase
                    ang.p = p.ang.p + (math.sin(t * 0.9 + ph) * 0.9 + 0.5) * gust * p.sway
                    ang.y = p.ang.y
                    ang.r = p.ang.r + math.sin(t * 0.67 + ph * 1.7) * 0.6 * gust * p.sway
                    m:SetAngles(ang)
                end
                if p.matrix then m:EnableMatrix("RenderMultiply", p.matrix) else m:DisableMatrix("RenderMultiply") end
                m:SetupBones()
                m:DrawModel()
                drawn = drawn + 1
            end
        end
    end
    render.SuppressEngineLighting(false)
    return drawn
end

--------------------------------------------------------------------------
-- Signs
--------------------------------------------------------------------------
-- The looks:
--   ad        a comic billboard ad: sunburst rays, a starburst badge that
--             shouts (`burst`, "\\n" for a second line), an outlined headline,
--             the gag line (`sub`) and the fine print that undoes it (`fine`)
--   transit   a station sign: a coloured roundel with the line number and
--             the station name, white on dark grey
--   street    a green US street sign with a block number
-- Ad colours as {r,g,b}: bg -> bg2 (the ground, top to bottom), fg (headline),
-- band (the fine-print strip), burstColor, subColor.
local fontsMade = false
local function makeFonts()
    if fontsMade then return end
    fontsMade = true
    surface.CreateFont("BMXCitySign", { font = "Coolvetica", size = 120, weight = 800, antialias = true })
    surface.CreateFont("BMXCitySignSub", { font = "Roboto", size = 40, weight = 700, antialias = true })
    for _, sz in ipairs({ 120, 100, 84, 70, 58 }) do
        surface.CreateFont("BMXCityAd" .. sz, { font = "Impact", size = sz, weight = 500, antialias = true })
    end
    for _, sz in ipairs({ 44, 36, 30 }) do
        surface.CreateFont("BMXCityAdSub" .. sz, { font = "Roboto", size = sz, weight = 800, antialias = true })
    end
    surface.CreateFont("BMXCityAdBrand", { font = "Roboto", size = 26, weight = 700, antialias = true })
    surface.CreateFont("BMXCityTransit", { font = "Roboto", size = 70, weight = 800, antialias = true })
end

local WHITE = Color(255, 255, 255)

-- The biggest of a font family's sizes that fits `text` in `room` pixels.
local function fit(prefix, sizes, text, room)
    for _, sz in ipairs(sizes) do
        surface.SetFont(prefix .. sz)
        if surface.GetTextSize(text) <= room then return prefix .. sz end
    end
    return prefix .. sizes[#sizes]
end
local function col(t, d) t = t or d return Color(t[1], t[2], t[3], t[4] or 255) end

local function disc(cx, cy, r, n)
    local poly = {}
    for i = 0, (n or 24) - 1 do local a = i / (n or 24) * math.pi * 2 poly[#poly + 1] = { x = cx + math.cos(a) * r, y = cy + math.sin(a) * r } end
    return poly
end

-- A convex polygon clipped to a rectangle (Sutherland-Hodgman): 3D2D has no
-- scissor of its own, and a ray must stop at the board's edge.
local function clipRect(poly, x0, y0, x1, y1)
    local function clip(pts, inside, cross)
        local out = {}
        for i = 1, #pts do
            local a, b = pts[i], pts[i % #pts + 1]
            local ia, ib = inside(a), inside(b)
            if ia then out[#out + 1] = a end
            if ia ~= ib then out[#out + 1] = cross(a, b) end
        end
        return out
    end
    local function lerpX(a, b, x) local t = (x - a.x) / (b.x - a.x) return { x = x, y = a.y + (b.y - a.y) * t } end
    local function lerpY(a, b, y) local t = (y - a.y) / (b.y - a.y) return { x = a.x + (b.x - a.x) * t, y = y } end
    poly = clip(poly, function(p) return p.x >= x0 end, function(a, b) return lerpX(a, b, x0) end)
    if #poly < 3 then return poly end
    poly = clip(poly, function(p) return p.x <= x1 end, function(a, b) return lerpX(a, b, x1) end)
    if #poly < 3 then return poly end
    poly = clip(poly, function(p) return p.y >= y0 end, function(a, b) return lerpY(a, b, y0) end)
    if #poly < 3 then return poly end
    return clip(poly, function(p) return p.y <= y1 end, function(a, b) return lerpY(a, b, y1) end)
end
City.ClipRect = clipRect

-- A comic ad: a two-tone ground with sunburst rays behind a starburst badge,
-- a fat outlined headline, the gag line, and the fine print that undoes it.
local function adSign(s, pw, ph)
    local bg, bg2 = col(s.bg, { 255, 220, 40 }), col(s.bg2 or s.bg, { 255, 140, 0 })
    local fg, band = col(s.fg, { 230, 30, 60 }), col(s.band, { 20, 30, 80 })
    local burst = col(s.burstColor, { 255, 40, 40 })
    draw.NoTexture()
    -- frame
    surface.SetDrawColor(245, 245, 245, 255) surface.DrawRect(-pw / 2 - 14, -ph / 2 - 14, pw + 28, ph + 28)
    surface.SetDrawColor(40, 40, 44, 255) surface.DrawRect(-pw / 2 - 4, -ph / 2 - 4, pw + 8, ph + 8)
    -- ground: top to bottom, bg into bg2
    for i = 0, 11 do
        local f = i / 11
        surface.SetDrawColor(bg.r + (bg2.r - bg.r) * f, bg.g + (bg2.g - bg.g) * f, bg.b + (bg2.b - bg.b) * f, 255)
        surface.DrawRect(-pw / 2, -ph / 2 + ph * i / 12, pw, ph / 12 + 1)
    end
    -- sunburst rays from the badge, alternate wedges a shade lighter
    local bx, by, br = pw / 2 - ph * 0.42, -ph * 0.08, ph * 0.3
    surface.SetDrawColor(255, 255, 255, 46)
    local reach = pw * 1.4
    for i = 0, 15, 2 do
        local a0, a1 = i / 16 * math.pi * 2, (i + 1) / 16 * math.pi * 2
        local ray = clipRect({ { x = bx, y = by },
            { x = bx + math.cos(a0) * reach, y = by + math.sin(a0) * reach },
            { x = bx + math.cos(a1) * reach, y = by + math.sin(a1) * reach } }, -pw / 2, -ph / 2, pw / 2, ph / 2)
        if #ray >= 3 then surface.DrawPoly(ray) end
    end
    -- the fine-print band along the bottom
    surface.SetDrawColor(band) surface.DrawRect(-pw / 2, ph / 2 - ph * 0.17, pw, ph * 0.17)
    -- headline: shadow, then outlined
    local x0 = -pw / 2 + pw * 0.04
    local room = (bx - br * 1.15) - x0
    local hf = fit("BMXCityAd", { 120, 100, 84, 70, 58 }, s.text, room)
    draw.SimpleText(s.text, hf, x0 + 6, -ph * 0.2 + 6, Color(0, 0, 0, 110), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    draw.SimpleTextOutlined(s.text, hf, x0, -ph * 0.2, fg, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, 5, Color(20, 20, 30))
    if s.sub then
        draw.SimpleTextOutlined(s.sub, fit("BMXCityAdSub", { 44, 36, 30 }, s.sub, room), x0, ph * 0.08,
            col(s.subColor, { 255, 255, 255 }), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, 3, Color(20, 20, 30))
    end
    if s.fine then
        draw.SimpleText(s.fine, "BMXCityAdBrand", x0, ph / 2 - ph * 0.085, Color(255, 255, 255, 230), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    end
    -- the starburst badge: a 16-point star, a white rim, the shout inside
    local star = {}
    for i = 0, 31 do
        local a = i / 32 * math.pi * 2 - math.pi / 2
        local rr = (i % 2 == 0) and br * 1.12 or br * 0.86
        star[#star + 1] = { x = bx + math.cos(a) * rr, y = by + math.sin(a) * rr }
    end
    surface.SetDrawColor(255, 255, 255, 255)
    local rim = {}
    for i, p in ipairs(star) do rim[i] = { x = bx + (p.x - bx) * 1.08, y = by + (p.y - by) * 1.08 } end
    surface.DrawPoly(rim)
    surface.SetDrawColor(burst) surface.DrawPoly(star)
    if s.burst then
        local lines = string.Explode("\n", s.burst)
        for i, l in ipairs(lines) do
            draw.SimpleTextOutlined(l, fit("BMXCityAdSub", { 44, 36, 30 }, l, br * 1.5), bx, by + (i - (#lines + 1) / 2) * br * 0.42,
                Color(255, 255, 90), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 2, Color(60, 0, 0))
        end
    end
    -- lamps on arms along the top edge
    for i = 1, 4 do
        local lx = -pw / 2 + pw * (i - 0.5) / 4
        surface.SetDrawColor(50, 50, 55, 255) surface.DrawRect(lx - 3, -ph / 2 - 40, 6, 30)
        surface.SetDrawColor(255, 245, 200, 255) surface.DrawRect(lx - 16, -ph / 2 - 46, 32, 10)
    end
end

local function transitSign(s, pw, ph)
    local c = col(s.color, { 220, 40, 40 })
    surface.SetDrawColor(36, 38, 42, 255) surface.DrawRect(-pw / 2, -ph / 2, pw, ph)
    surface.SetDrawColor(200, 200, 200, 255) surface.DrawOutlinedRect(-pw / 2, -ph / 2, pw, ph, 4)
    local r = ph * 0.36
    local cx = -pw / 2 + ph * 0.5
    draw.NoTexture()
    surface.SetDrawColor(c)
    local poly = {}
    for i = 0, 23 do local a = i / 24 * math.pi * 2 poly[#poly + 1] = { x = cx + math.cos(a) * r, y = math.sin(a) * r } end
    surface.DrawPoly(poly)
    draw.SimpleText(s.line or "1", "BMXCityTransit", cx, 0, WHITE, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    draw.SimpleText(s.text, "BMXCityTransit", cx + r + 24, -ph * 0.08, WHITE, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    if s.sub then draw.SimpleText(s.sub, "BMXCitySignSub", cx + r + 26, ph * 0.28, Color(190, 190, 190), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER) end
end

-- A US street sign: green, a white border, white capitals, a block number.
local function streetSign(s, pw, ph)
    surface.SetDrawColor(0, 110, 60, 255) surface.DrawRect(-pw / 2, -ph / 2, pw, ph)
    surface.SetDrawColor(255, 255, 255, 255)
    surface.DrawOutlinedRect(-pw / 2 + 8, -ph / 2 + 8, pw - 16, ph - 16, 6)
    local num = s.sub and s.sub ~= ""
    draw.SimpleText(s.text, "BMXCitySign", num and -pw * 0.06 or 0, 0, WHITE, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    if num then draw.SimpleText(s.sub, "BMXCitySignSub", pw / 2 - 40, ph * 0.18, WHITE, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER) end
end

local LOOKS = { ad = adSign, transit = transitSign, street = streetSign }
-- the panel's height in 3D2D pixels for each look (its width follows)
local PANEL_PX = { ad = 360, transit = 180, street = 170 }

local function drawSigns(layout)
    makeFonts()
    local eye = EyePos()
    for _, s in ipairs(layout.signs) do
        local n = Vector(s.normal[1], s.normal[2], s.normal[3])
        local p = Vector(s.pos[1], s.pos[2], s.pos[3])
        -- only from the front: a sign is one-sided
        if (eye - p):Dot(n) > 0 then
            local ang = n:Angle()
            ang:RotateAroundAxis(ang:Up(), 90)
            ang:RotateAroundAxis(ang:Forward(), 90)
            local scale = s.h / (PANEL_PX[s.look] or 360)
            local pw, ph = s.w / scale, s.h / scale
            local look = LOOKS[s.look or "ad"] or adSign
            -- 14 units proud: in front of any cornice (they stick out 8)
            cam.Start3D2D(p + n * (s.roof and 0.5 or 14), ang, scale)
                look(s, pw, ph)
            cam.End3D2D()
        end
    end
end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------
function City.ClientBuild()
    City.meshes = nil
    City._layoutMap = nil
    if not City.Enabled() then return false end
    local L = City.Layout()
    if not L then return false end
    local t0 = SysTime and SysTime() or 0
    City.BuildMeshes(L)
    City.BuildPlants(L)
    local ms = ((SysTime and SysTime() or 0) - t0) * 1000
    MsgN(string.format("[BMX] city: %d buildings, %d quads in %d meshes, %d plants, %d subway lines (%.0f ms)",
        #L.buildings, L.quads, #City.meshes, #City.plants, #L.lines, ms))
    return true
end

function City.ClientClear()
    City.FreeMeshes()
    for name in pairs(City._sounds) do lineSound(name, nil, false) end
    for i, m in pairs(City._cars) do if IsValid(m) then m:Remove() end City._cars[i] = nil end
    for k, m in pairs(City._plantEnts) do if m and IsValid(m) then m:Remove() end City._plantEnts[k] = nil end
    City.plants = nil
end

hook.Add("InitPostEntity", "BMXCity", function() City.ClientBuild() end)

-- PostDrawOpaqueRenderables(bDrawingDepth, bDrawingSkybox, isDraw3DSkybox).
-- ONLY the depth pass and the 3D skybox's own pass are skipped. bDrawingSkybox
-- is NOT "this is the skybox pass": on gm_skatepark it is true on every
-- ordinary frame (measured on a live client, 63 of 63 frames), and skipping on
-- it drew the city never -- built, all 70 meshes, and invisible.
City.Stats = { drawn = 0, culled = 0 }
function City.Draw(bDepth, bSkybox, b3DSky)
    if bDepth or b3DSky then return end
    if not City.meshes then return end
    if not cvDraw:GetBool() or not City.Enabled() then
        for name in pairs(City._sounds) do lineSound(name, nil, false) end
        return
    end
    local eye, fwd = EyePos(), EyeAngles():Forward()
    local vs = render.GetViewSetup and render.GetViewSetup()
    -- the cone must reach the screen's CORNERS: the half-angle of the
    -- diagonal, from the horizontal fov and the aspect, plus a margin
    local fov = (vs and vs.fov) or 120
    local aspect = (vs and vs.aspect) or (ScrW() / math.max(ScrH(), 1))
    local t = math.tan(math.rad(math.min(fov, 170)) / 2)
    local half = math.min(math.atan(t * math.sqrt(1 + 1 / (aspect * aspect))) + math.rad(6), math.rad(89))
    local cosH, sinH = math.cos(half), math.sin(half)
    local drawn, culled, last = 0, 0, nil
    for _, m in ipairs(City.meshes) do
        if City.InView(m.center, m.radius, eye, fwd, cosH, sinH) then
            if m.mat ~= last then render.SetMaterial(m.mat) last = m.mat end
            m.mesh:Draw()
            drawn = drawn + 1
        else
            culled = culled + 1
        end
    end
    City.Stats.drawn, City.Stats.culled = drawn, culled
    local L = City._layout
    if not L then return end
    if cvPlants:GetBool() then City.Stats.plants = drawPlants(eye, fwd, cosH, sinH) end
    if cvTrains:GetBool() then
        drawTrains(L, CurTime())
    else
        for name in pairs(City._sounds) do lineSound(name, nil, false) end
    end
    if cvSigns:GetBool() then drawSigns(L) end
end
hook.Add("PostDrawOpaqueRenderables", "BMXCity", function(a, b, c) City.Draw(a, b, c) end)

concommand.Add("bmx_city_rebuild_client", function()
    City.ClientClear()
    City.ClientBuild()
end, nil, "BMX: rebuild the city's meshes on this client")
