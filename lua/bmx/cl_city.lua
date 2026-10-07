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
City._plantRetry = City._plantRetry or {}
-- Is the model there? util.IsValidModel alone is no answer on the client: it
-- says false for any model nobody has precached yet, which at InitPostEntity
-- is every tree -- and once cached as missing, not one tree or lamp was drawn.
local function haveModel(path)
    if util.IsValidModel and util.IsValidModel(path) then return true end
    return file and file.Exists and file.Exists(path, "GAME") or false
end
local function plantModel(kind, existing)
    local m = City._plantEnts[kind]
    if IsValid(m) then return m end
    if m == false and CurTime() < (City._plantRetry[kind] or 0) then return nil end
    if existing and m == nil then return nil end
    local P = City.Plants[kind]
    if not P or not haveModel(P.model) then
        -- try again in a few seconds, not never
        City._plantEnts[kind] = false
        City._plantRetry[kind] = CurTime() + 3
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

-- Autumn crowns. HL2's tree leaves are a sparse, dark sheet made to be lit;
-- they cannot be turned into a full red-and-gold crown. So each tree wears a
-- crown of leaf cards -- the hedges' own leaves and colours, so trees and
-- bushes match -- built once per kind in the tree's own space and drawn
-- through the same transform as the tree, so they sway together.
City.CROWN_MATS = { "leaves_red", "leaves_orange", "leaves_gold", "leaves_rust" }
City._crowns = City._crowns or {}
function City.CrownQuads(kind)
    local P = City.Plants[kind]
    local rng = City.Rng(#kind * 7919 + P.h)
    local out = {}
    local h, r = P.h, P.r
    -- an egg of clusters round the upper part of the tree
    local cz, rz, rr = h * 0.66, h * 0.24, r * 0.62
    if kind == "poplar" then cz, rz, rr = h * 0.58, h * 0.36, r * 0.32 end
    local n = math.floor(22 + h / 12)
    for _ = 1, n do
        local a = rng.float() * math.pi * 2
        local d = math.sqrt(rng.float())
        local x, y = math.cos(a) * rr * d, math.sin(a) * rr * d
        local z = cz + (rng.float() * 2 - 1) * rz * math.sqrt(1 - d * d * 0.7)
        local w = (0.62 + rng.float() * 0.3) * math.max(rr, 80)
        -- darker underneath and inside, bright on top
        local shade = math.min(1, 0.62 + 0.38 * ((z - (cz - rz)) / (2 * rz)) + 0.1 * d)
        local rot = rng.float() * math.pi
        for k = 0, 2 do
            local t = rot + k * math.pi / 3
            local ux, uy = math.cos(t), math.sin(t)
            local u0 = (k * 0.37) % 1
            -- the leaf art is ragged at the top and cut off square at the
            -- bottom: each card is two halves, the top one the art's ragged
            -- crown, the bottom one the same mirrored, so no edge is straight
            out[#out + 1] = { x - ux * w / 2, y - uy * w / 2, z + w / 2,
                              x + ux * w / 2, y + uy * w / 2, z + w / 2,
                              x + ux * w / 2, y + uy * w / 2, z,
                              x - ux * w / 2, y - uy * w / 2, z, shade, u0, 0, 0.62 }
            out[#out + 1] = { x - ux * w / 2, y - uy * w / 2, z,
                              x + ux * w / 2, y + uy * w / 2, z,
                              x + ux * w / 2, y + uy * w / 2, z - w / 2,
                              x - ux * w / 2, y - uy * w / 2, z - w / 2, shade * 0.9, u0, 0.62, 0 }
        end
    end
    return out
end

local function crownMesh(kind, mood)
    local c = City._crowns[kind]
    if c ~= nil then return c or nil end
    if not Mesh then City._crowns[kind] = false return nil end
    local quads = City.CrownQuads(kind)
    local m = Mesh()
    mesh.Begin(m, MATERIAL_QUADS, #quads)
    for _, q in ipairs(quads) do
        local s = q[13]
        local r, g, b = clamp255(s * mood[1]), clamp255(s * mood[2]), clamp255(s * mood[3])
        local u0, v0, v1 = q[14], q[15], q[16]
        local uv = { u0, v0, u0 + 1, v0, u0 + 1, v1, u0, v1 }
        for v = 0, 3 do
            mesh.Position(Vector(q[v * 3 + 1], q[v * 3 + 2], q[v * 3 + 3]))
            mesh.TexCoord(0, uv[v * 2 + 1], uv[v * 2 + 2])
            mesh.Color(r, g, b, 255)
            mesh.AdvanceVertex()
        end
    end
    mesh.End()
    City._crowns[kind] = m
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
            scale = p.scale,
            still = P.still, phase = (p.x * 0.0123 + p.y * 0.0171) % (math.pi * 2),
            fall = 1 + math.floor(math.abs(p.x * 0.37 + p.y * 0.61)) % #City.CROWN_MATS,
            -- tall thin trees sway further at the top than squat ones
            sway = math.min(1.6, 0.6 + P.h * p.scale / 600),
        }
    end
    -- grouped by kind: one model swap per kind per frame
    table.sort(out, function(a, b) return a.kind < b.kind end)
    City.plants = out
    -- the models and crowns are made here, once, not in the middle of a frame
    local mood = layout.mood and layout.mood.light or { 1, 1, 1 }
    for _, p in ipairs(out) do
        plantModel(p.kind)
        if not p.still then crownMesh(p.kind, mood) end
    end
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
                local crown = not p.still and City._crowns[p.kind]
                if crown then
                    local mx = Matrix()
                    mx:SetTranslation(p.pos)
                    mx:SetAngles(ang)
                    if p.scale ~= 1 then mx:Scale(Vector(p.scale, p.scale, p.scale)) end
                    cam.PushModelMatrix(mx)
                        render.SetMaterial(City.Material(City.CROWN_MATS[p.fall]))
                        crown:Draw()
                    cam.PopModelMatrix()
                end
            end
        end
    end
    render.SuppressEngineLighting(false)
    return drawn
end

--------------------------------------------------------------------------
-- Signs
--------------------------------------------------------------------------
--------------------------------------------------------------------------
-- Ad pictures. The thing an ad sells is a real 3D model -- the chowder's
-- takeout carton, the toy, the TV -- PHOTOGRAPHED into a render target and
-- laid on the board like a product shot. Only models every Garry's Mod
-- player has (HL2 / GMod content), so nothing ships that is not ours, plus
-- the server's Peter Griffin player model where a client has it: a slot can
-- list several models and takes the first one this client can load.
--
--   pic = { { model = "models/...mdl" | { "first choice", "fallback" },
--             at = {x,y,z}, ang = {p,y,r}, scale = 1, seq = "idle_all_01" }, ... },
--   picYaw = 180 (the camera looks along this; 180 sees a model's front),
--   picPitch = 8, picBg = {r,g,b}
--
-- A render target can lose its contents (a resolution change, alt-tab on
-- some drivers), so each picture is shot again every PIC_EVERY seconds, one
-- picture a frame.
--------------------------------------------------------------------------
City.PIC_SIZE = 512
City.PIC_EVERY = 30
City._pics = City._pics or {}

-- On a client, util.IsValidModel says no to anything the server has not
-- precached, which is most props (measured: the bike and the carton were
-- "invalid", the precached player model was not). Ask the filesystem.
local function hasModel(m) return type(m) == "string" and file.Exists(m, "GAME") end
function City.PickModel(slot)
    local list = type(slot.model) == "table" and slot.model or { slot.model }
    for _, m in ipairs(list) do if hasModel(m) then return m end end
end

local function shoot(s, P)
    local scene, mins, maxs = {}, nil, nil
    for _, slot in ipairs(s.pic) do
        local mdl = City.PickModel(slot)
        local e = mdl and ClientsideModel(mdl, RENDERGROUP_OPAQUE)
        if IsValid(e) then
            e:SetNoDraw(true)
            local at, ang = slot.at or { 0, 0, 0 }, slot.ang or { 0, 0, 0 }
            e:SetPos(Vector(at[1], at[2], at[3]))
            e:SetAngles(Angle(ang[1], ang[2], ang[3]))
            local sc = slot.scale or 1
            if sc ~= 1 then e:SetModelScale(sc, 0) end
            if slot.seq then
                local q = e:LookupSequence(slot.seq)
                if q and q >= 0 then e:ResetSequence(q) e:SetCycle(slot.cycle or 0) end
            end
            e:SetupBones()
            -- render bounds, not the physics hull: the hull can be smaller
            -- than what is drawn, and the shot then crops the product
            local a, b = e:GetRenderBounds()
            for _, cx in ipairs({ a.x, b.x }) do for _, cy in ipairs({ a.y, b.y }) do for _, cz in ipairs({ a.z, b.z }) do
                local w = e:LocalToWorld(Vector(cx, cy, cz) * sc)
                mins = mins and Vector(math.min(mins.x, w.x), math.min(mins.y, w.y), math.min(mins.z, w.z)) or w
                maxs = maxs and Vector(math.max(maxs.x, w.x), math.max(maxs.y, w.y), math.max(maxs.z, w.z)) or w
            end end end
            scene[#scene + 1] = e
        end
    end
    if #scene == 0 then return false end
    local c, r = (mins + maxs) / 2, (maxs - mins):Length() / 2
    local camAng = Angle(s.picPitch or 8, s.picYaw or 180, 0)
    local fov = 36
    -- r is the bounding sphere's radius: just inside it fills the shot
    local dist = r / math.tan(math.rad(fov / 2)) * 0.95
    local camPos = c - camAng:Forward() * dist
    local bg = s.picBg or { 70, 70, 80 }
    render.PushRenderTarget(P.rt)
        render.Clear(bg[1], bg[2], bg[3], 255, true, true)
        cam.Start3D(camPos, camAng, fov, 0, 0, City.PIC_SIZE, City.PIC_SIZE, 1, dist * 4)
            render.SuppressEngineLighting(true)
            -- a soft studio light, kept DIM (a full-strength cube washed the
            -- products out): warm key from above and the camera's side,
            -- cool fill, deep shadow -- the board is lit by the sun as well
            local key = s.picLight or 1
            render.ResetModelLighting(0.16 * key, 0.16 * key, 0.18 * key)
            render.SetModelLighting(BOX_TOP, 0.62 * key, 0.6 * key, 0.56 * key)
            render.SetModelLighting(BOX_BACK, 0.5 * key, 0.48 * key, 0.45 * key)
            render.SetModelLighting(BOX_FRONT, 0.5 * key, 0.48 * key, 0.45 * key)
            render.SetModelLighting(BOX_LEFT, 0.3 * key, 0.3 * key, 0.33 * key)
            render.SetModelLighting(BOX_RIGHT, 0.22 * key, 0.22 * key, 0.25 * key)
            for _, e in ipairs(scene) do e:DrawModel() end
            render.SuppressEngineLighting(false)
        cam.End3D()
    render.PopRenderTarget()
    for _, e in ipairs(scene) do e:Remove() end
    return true
end

-- The picture for sign `s`: a material, or nil while it has none (no
-- models on this client, or not shot yet). At most one shot per frame.
local shotThisFrame = -1
function City.AdPicture(s)
    if not s.pic then return nil end
    local P = City._pics[s]
    if not P then
        -- named by the ad, so a rebuild reuses its render target
        local name = "bmxcity_pic_" .. (s.text or "ad"):lower():gsub("[^%w]", "")
        local rt = GetRenderTargetEx(name, City.PIC_SIZE, City.PIC_SIZE, RT_SIZE_NO_CHANGE, MATERIAL_RT_DEPTH_SEPARATE,
            0, 0, IMAGE_FORMAT_RGB888)
        P = { rt = rt, at = -math.huge,
              mat = CreateMaterial(name .. "_mat", "UnlitGeneric", { ["$basetexture"] = rt:GetName() }) }
        City._pics[s] = P
    end
    local now = RealTime()
    if now - P.at > City.PIC_EVERY and shotThisFrame ~= FrameNumber() then
        shotThisFrame = FrameNumber()
        P.ok = shoot(s, P)
        P.at = now
    end
    return P.ok and P.mat or nil
end

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
    for _, sz in ipairs({ 120, 100, 84, 70, 58, 48, 40, 34 }) do
        surface.CreateFont("BMXCityAd" .. sz, { font = "Impact", size = sz, weight = 500, antialias = true })
    end
    for _, sz in ipairs({ 44, 36, 30 }) do
        surface.CreateFont("BMXCityAdSub" .. sz, { font = "Roboto", size = sz, weight = 800, antialias = true })
    end
    surface.CreateFont("BMXCityAdBrand", { font = "Roboto", size = 26, weight = 700, antialias = true })
    surface.CreateFont("BMXCityTransit", { font = "Roboto", size = 70, weight = 800, antialias = true })
    for _, sz in ipairs({ 110, 90, 72, 60, 48 }) do
        surface.CreateFont("BMXCityNeon" .. sz, { font = "Coolvetica", size = sz, weight = 500, antialias = true })
    end
    for _, sz in ipairs({ 110, 90, 72, 60, 48, 40, 34 }) do
        surface.CreateFont("BMXCitySerif" .. sz, { font = "Georgia", size = sz, weight = 700, antialias = true })
    end
    for _, sz in ipairs({ 40, 32, 26, 22, 18 }) do
        surface.CreateFont("BMXCitySerifSub" .. sz, { font = "Georgia", size = sz, weight = 400, italic = true, antialias = true })
    end
    for _, sz in ipairs({ 96, 80, 66, 54, 44 }) do
        surface.CreateFont("BMXCityThin" .. sz, { font = "Roboto Light", size = sz, weight = 300, antialias = true })
    end
    for _, sz in ipairs({ 38, 32, 26, 24, 20, 18 }) do
        surface.CreateFont("BMXCityThinSub" .. sz, { font = "Roboto", size = sz, weight = 400, antialias = true })
    end
    for _, sz in ipairs({ 40, 34, 28, 24, 20, 18 }) do
        surface.CreateFont("BMXCityAdSub" .. sz, { font = "Roboto", size = sz, weight = 800, antialias = true })
    end
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

-- ADS COME IN STYLES, so a street of them does not look like one poster
-- printed eight times. `style` picks one (default "comic"):
--   comic    sunburst, starburst sticker, outlined Impact, the gag line
--   classic  a vintage poster: cream paper, ink borders, serif type, a ribbon
--   minimal  modern: flat colour, full-height product shot, light type
--   tv       a news broadcast: the shot as the picture, LIVE bug, lower third
--   sale     retail: candy stripes, a tilted price tag, SALE in red
--   split    two colours split on a diagonal, a tilted polaroid of the product
--   neon     night: a dark wall, glowing tubes that flicker now and then
-- Every style takes the same fields (text, sub, fine, burst, price, colours).

local INK = Color(20, 20, 30)

-- a frame and the lamps over it; kinds differ by style
local function frame(pw, ph, kind)
    if kind == "wood" then
        surface.SetDrawColor(92, 60, 32, 255) surface.DrawRect(-pw / 2 - 22, -ph / 2 - 22, pw + 44, ph + 44)
        surface.SetDrawColor(130, 90, 50, 255) surface.DrawRect(-pw / 2 - 12, -ph / 2 - 12, pw + 24, ph + 24)
    elseif kind == "alu" then
        surface.SetDrawColor(170, 174, 180, 255) surface.DrawRect(-pw / 2 - 8, -ph / 2 - 8, pw + 16, ph + 16)
    elseif kind == "bezel" then
        surface.SetDrawColor(18, 18, 20, 255) surface.DrawRect(-pw / 2 - 26, -ph / 2 - 26, pw + 52, ph + 52)
        surface.SetDrawColor(60, 60, 66, 255) surface.DrawOutlinedRect(-pw / 2 - 26, -ph / 2 - 26, pw + 52, ph + 52, 3)
        return
    elseif kind == "brackets" then
        surface.SetDrawColor(60, 60, 66, 255)
        for _, x in ipairs({ -pw * 0.35, pw * 0.35 }) do surface.DrawRect(x - 6, -ph / 2 - 30, 12, 30) end
        return
    else
        surface.SetDrawColor(245, 245, 245, 255) surface.DrawRect(-pw / 2 - 14, -ph / 2 - 14, pw + 28, ph + 28)
        surface.SetDrawColor(40, 40, 44, 255) surface.DrawRect(-pw / 2 - 4, -ph / 2 - 4, pw + 8, ph + 8)
    end
    for i = 1, 4 do
        local lx = -pw / 2 + pw * (i - 0.5) / 4
        surface.SetDrawColor(50, 50, 55, 255) surface.DrawRect(lx - 3, -ph / 2 - 46, 6, 30)
        surface.SetDrawColor(255, 245, 200, 255) surface.DrawRect(lx - 16, -ph / 2 - 52, 32, 10)
    end
end

local function gradient(x, y, w, h, a, b, steps)
    steps = steps or 12
    for i = 0, steps - 1 do
        local f = i / (steps - 1)
        surface.SetDrawColor(a.r + (b.r - a.r) * f, a.g + (b.g - a.g) * f, a.b + (b.b - a.b) * f, 255)
        surface.DrawRect(x, y + h * i / steps, w, h / steps + 1)
    end
end

local function photo(pic, x, y, sz, mount)
    if not pic then return end
    if mount then
        surface.SetDrawColor(0, 0, 0, 80) surface.DrawRect(x + 10, y + 10, sz, sz)
        surface.SetDrawColor(mount) surface.DrawRect(x - 8, y - 8, sz + 16, sz + 16)
    end
    surface.SetMaterial(pic)
    surface.SetDrawColor(255, 255, 255, 255)
    surface.DrawTexturedRect(x, y, sz, sz)
    draw.NoTexture()
end

-- draw fn() rotated by `deg` about (cx, cy) on the panel
local function tilted(cx, cy, deg, fn)
    local m = Matrix()
    m:Translate(Vector(cx, cy, 0))
    m:Rotate(Angle(0, deg, 0))
    cam.PushModelMatrix(m, true)
        -- always popped: a matrix left pushed skews every frame after it
        local ok, err = pcall(fn)
    cam.PopModelMatrix()
    if not ok then error(err, 0) end
end

local function star(cx, cy, r, points, inner)
    local p = {}
    for i = 0, points * 2 - 1 do
        local a = i / (points * 2) * math.pi * 2 - math.pi / 2
        local rr = (i % 2 == 0) and r or r * (inner or 0.77)
        p[#p + 1] = { x = cx + math.cos(a) * rr, y = cy + math.sin(a) * rr }
    end
    return p
end

local function sticker(s, cx, cy, r, fill)
    if not s.burst then return end
    local rim = star(cx, cy, r * 1.08, 16)
    surface.SetDrawColor(255, 255, 255, 255) surface.DrawPoly(rim)
    surface.SetDrawColor(fill) surface.DrawPoly(star(cx, cy, r, 16))
    local lines = string.Explode("\n", s.burst)
    for i, l in ipairs(lines) do
        draw.SimpleTextOutlined(l, fit("BMXCityAdSub", { 44, 36, 30, 24 }, l, r * 1.5), cx, cy + (i - (#lines + 1) / 2) * r * 0.42,
            Color(255, 255, 90), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 2, Color(60, 0, 0))
    end
end

local STYLES = {}

function STYLES.comic(s, pw, ph, pic)
    local bg, bg2 = col(s.bg, { 255, 220, 40 }), col(s.bg2 or s.bg, { 255, 140, 0 })
    local fg, band = col(s.fg, { 230, 30, 60 }), col(s.band, { 20, 30, 80 })
    frame(pw, ph)
    gradient(-pw / 2, -ph / 2, pw, ph, bg, bg2)
    local psz = ph * 0.76
    local px, py = pw / 2 - psz - ph * 0.05, -ph / 2 + ph * 0.035
    local rcx, rcy = pic and px + psz / 2 or pw / 2 - ph * 0.42, pic and py + psz / 2 or -ph * 0.08
    surface.SetDrawColor(255, 255, 255, 46)
    for i = 0, 15, 2 do
        local a0, a1 = i / 16 * math.pi * 2, (i + 1) / 16 * math.pi * 2
        local ray = clipRect({ { x = rcx, y = rcy }, { x = rcx + math.cos(a0) * pw * 1.4, y = rcy + math.sin(a0) * pw * 1.4 },
            { x = rcx + math.cos(a1) * pw * 1.4, y = rcy + math.sin(a1) * pw * 1.4 } }, -pw / 2, -ph / 2, pw / 2, ph / 2)
        if #ray >= 3 then surface.DrawPoly(ray) end
    end
    surface.SetDrawColor(band) surface.DrawRect(-pw / 2, ph / 2 - ph * 0.17, pw, ph * 0.17)
    photo(pic, px, py, psz, WHITE)
    local x0 = -pw / 2 + pw * 0.04
    local room = (pic and px - 24 or rcx - ph * 0.35) - x0
    local hf = fit("BMXCityAd", { 120, 100, 84, 70, 58 }, s.text, room)
    draw.SimpleText(s.text, hf, x0 + 6, -ph * 0.2 + 6, Color(0, 0, 0, 110), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    draw.SimpleTextOutlined(s.text, hf, x0, -ph * 0.2, fg, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, 5, INK)
    if s.sub then draw.SimpleTextOutlined(s.sub, fit("BMXCityAdSub", { 44, 36, 30 }, s.sub, room), x0, ph * 0.08, col(s.subColor, { 255, 255, 255 }), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, 3, INK) end
    if s.fine then draw.SimpleText(s.fine, "BMXCityAdBrand", x0, ph / 2 - ph * 0.085, Color(255, 255, 255, 230), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER) end
    if pic then sticker(s, px + psz - ph * 0.02, py + ph * 0.06, ph * 0.16, col(s.burstColor, { 255, 40, 40 }))
    else sticker(s, rcx, rcy, ph * 0.3, col(s.burstColor, { 255, 40, 40 })) end
end

function STYLES.classic(s, pw, ph, pic)
    local paper, ink, accent = col(s.bg, { 243, 232, 206 }), col(s.fg, { 120, 28, 28 }), col(s.band, { 28, 46, 86 })
    frame(pw, ph, "wood")
    surface.SetDrawColor(paper) surface.DrawRect(-pw / 2, -ph / 2, pw, ph)
    -- foxing at the edges: an aged print
    surface.SetDrawColor(120, 90, 40, 26)
    for i = 1, 3 do surface.DrawOutlinedRect(-pw / 2 + i * 4, -ph / 2 + i * 4, pw - i * 8, ph - i * 8, 4) end
    surface.SetDrawColor(ink) surface.DrawOutlinedRect(-pw / 2 + 18, -ph / 2 + 18, pw - 36, ph - 36, 4)
    surface.DrawOutlinedRect(-pw / 2 + 30, -ph / 2 + 30, pw - 60, ph - 60, 2)
    local psz = ph * 0.62
    local px, py = pw / 2 - psz - ph * 0.12, -psz / 2 - ph * 0.02
    if pic then
        photo(pic, px, py, psz, ink)
        surface.SetDrawColor(paper) surface.DrawOutlinedRect(px - 4, py - 4, psz + 8, psz + 8, 3)
    end
    local cx = pic and (-pw / 2 + (px - 30 + pw / 2) / 2) or 0
    local room = pic and (px - 60 - (-pw / 2 + 50)) or pw - 120
    if s.burst then
        local rib = s.burst:gsub("\n", " ")
        local rw = math.min(room, 360)
        surface.SetDrawColor(accent) surface.DrawRect(cx - rw / 2, -ph * 0.36, rw, 40)
        draw.SimpleText(rib, fit("BMXCitySerifSub", { 32, 26, 22 }, rib, rw - 20), cx, -ph * 0.36 + 20, paper, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
    -- a title too long for one line at a readable size goes on two
    local sizes = { 110, 90, 72, 60, 48, 40, 34 }
    local f1 = fit("BMXCitySerif", sizes, s.text, room)
    surface.SetFont(f1)
    if surface.GetTextSize(s.text) > room or f1 == "BMXCitySerif34" then
        local words = string.Explode(" ", s.text)
        local half = math.ceil(#words / 2)
        local l1, l2 = table.concat(words, " ", 1, half), table.concat(words, " ", half + 1)
        local f2 = fit("BMXCitySerif", { 60, 48, 40, 34 }, #l1 > #l2 and l1 or l2, room)
        draw.SimpleText(l1, f2, cx, -ph * 0.17, ink, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        draw.SimpleText(l2, f2, cx, -ph * 0.04, ink, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    else
        draw.SimpleText(s.text, f1, cx, -ph * 0.1, ink, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
    surface.SetDrawColor(ink) surface.DrawRect(cx - room * 0.3, ph * 0.04, room * 0.6, 3)
    if s.sub then draw.SimpleText(s.sub, fit("BMXCitySerifSub", { 40, 32, 26 }, s.sub, room), cx, ph * 0.15, accent, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER) end
    if s.fine then draw.SimpleText(s.fine, fit("BMXCitySerifSub", { 26, 22, 18 }, s.fine, room), cx, ph * 0.33, Color(ink.r, ink.g, ink.b, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER) end
end

function STYLES.minimal(s, pw, ph, pic)
    local bg, fg, accent = col(s.bg, { 24, 26, 32 }), col(s.fg, { 250, 250, 250 }), col(s.band, { 0, 200, 140 })
    frame(pw, ph, "alu")
    surface.SetDrawColor(bg) surface.DrawRect(-pw / 2, -ph / 2, pw, ph)
    local x0 = -pw / 2 + ph * 0.12
    if pic then photo(pic, -pw / 2, -ph / 2, ph) x0 = -pw / 2 + ph + ph * 0.1 end
    local room = pw / 2 - x0 - ph * 0.1
    surface.SetDrawColor(accent) surface.DrawRect(x0, -ph * 0.3, 70, 6)
    draw.SimpleText(s.text, fit("BMXCityThin", { 96, 80, 66, 54, 44 }, s.text, room), x0, -ph * 0.1, fg, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    if s.sub then draw.SimpleText(s.sub, fit("BMXCityThinSub", { 38, 32, 26 }, s.sub, room), x0, ph * 0.1, Color(fg.r, fg.g, fg.b, 190), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER) end
    if s.fine then draw.SimpleText(s.fine, fit("BMXCityThinSub", { 24, 20, 18 }, s.fine, room), x0, ph * 0.34, Color(fg.r, fg.g, fg.b, 120), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER) end
    if s.burst then
        local b = s.burst:gsub("\n", " ")
        draw.SimpleText(b, "BMXCityThinSub24", pw / 2 - ph * 0.08, -ph / 2 + ph * 0.1, accent, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
    end
end

function STYLES.tv(s, pw, ph, pic)
    local bar, tag = col(s.band, { 14, 40, 120 }), col(s.burstColor, { 210, 20, 30 })
    frame(pw, ph, "bezel")
    gradient(-pw / 2, -ph / 2, pw, ph, col(s.bg, { 30, 50, 110 }), col(s.bg2, { 8, 12, 40 }))
    -- the shot, framed on the right like the picture-in-picture box
    local psz = ph * 0.66
    local px, py = pw / 2 - psz - 30, -ph / 2 + 30
    if pic then
        photo(pic, px, py, psz)
        surface.SetDrawColor(255, 255, 255, 230) surface.DrawOutlinedRect(px - 4, py - 4, psz + 8, psz + 8, 4)
    end
    surface.SetDrawColor(0, 0, 0, 34)
    for y = -ph / 2, ph / 2, 6 do surface.DrawRect(-pw / 2, y, pw, 2) end
    -- LIVE bug
    local live = s.burst and s.burst:gsub("\n", " ") or "LIVE"
    surface.SetDrawColor(tag) surface.DrawRect(-pw / 2 + 24, -ph / 2 + 22, 120, 46)
    draw.SimpleText(live, fit("BMXCityAdSub", { 36, 30, 24 }, live, 110), -pw / 2 + 84, -ph / 2 + 45, WHITE, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    -- lower third, left of the picture: BREAKING tag, headline bar, tagline
    local lw = (pic and px - 20 or pw / 2 - 24) - (-pw / 2 + 24)
    local ly = -ph * 0.1
    surface.SetDrawColor(tag) surface.DrawRect(-pw / 2 + 24, ly - 40, 200, 40)
    draw.SimpleText("BREAKING", "BMXCityAdSub30", -pw / 2 + 124, ly - 20, WHITE, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    surface.SetDrawColor(255, 255, 255, 240) surface.DrawRect(-pw / 2 + 24, ly, lw, 96)
    draw.SimpleText(s.text, fit("BMXCityAd", { 84, 70, 58, 48, 40 }, s.text, lw - 32), -pw / 2 + 40, ly + 48, bar, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    surface.SetDrawColor(bar) surface.DrawRect(-pw / 2 + 24, ly + 96, lw, 56)
    if s.sub then draw.SimpleText(s.sub, fit("BMXCityAdSub", { 36, 30, 24, 20 }, s.sub, lw - 32), -pw / 2 + 40, ly + 124, WHITE, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER) end
    -- the ticker along the bottom
    surface.SetDrawColor(10, 10, 14, 255) surface.DrawRect(-pw / 2, ph / 2 - 40, pw, 40)
    if s.fine then draw.SimpleText("*  " .. s.fine .. "  *", "BMXCityAdBrand", -pw / 2 + 20, ph / 2 - 20, Color(255, 220, 60), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER) end
end

function STYLES.sale(s, pw, ph, pic)
    local bg, stripe, red = col(s.bg, { 255, 236, 60 }), col(s.bg2, { 255, 210, 0 }), col(s.fg, { 220, 20, 30 })
    frame(pw, ph)
    surface.SetDrawColor(bg) surface.DrawRect(-pw / 2, -ph / 2, pw, ph)
    surface.SetDrawColor(stripe)
    for x = -pw, pw, 90 do
        local band = clipRect({ { x = x, y = -ph / 2 }, { x = x + 45, y = -ph / 2 }, { x = x + 45 + ph, y = ph / 2 }, { x = x + ph, y = ph / 2 } },
            -pw / 2, -ph / 2, pw / 2, ph / 2)
        if #band >= 3 then surface.DrawPoly(band) end
    end
    local psz = ph * 0.74
    local px, py = -pw / 2 + ph * 0.07, -psz / 2
    photo(pic, px, py, psz, WHITE)
    local x0 = pic and (px + psz + 40) or (-pw / 2 + 40)
    local room = pw / 2 - x0 - ph * 0.5
    draw.SimpleTextOutlined("SALE", fit("BMXCityAd", { 120, 100 }, "SALE", room), x0, -ph * 0.28, red, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, 4, WHITE)
    draw.SimpleTextOutlined(s.text, fit("BMXCityAd", { 84, 70, 58, 48 }, s.text, room), x0, -ph * 0.02, INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, 3, WHITE)
    if s.sub then draw.SimpleText(s.sub, fit("BMXCityAdSub", { 36, 30, 24 }, s.sub, room + ph * 0.4), x0, ph * 0.2, INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER) end
    if s.fine then draw.SimpleText(s.fine, "BMXCityAdBrand", x0, ph * 0.38, Color(80, 60, 0), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER) end
    -- the price tag, tilted, with its hole
    local tx, ty = pw / 2 - ph * 0.3, -ph * 0.02
    tilted(tx, ty, 12, function()
        local w, h = ph * 0.46, ph * 0.3
        surface.SetDrawColor(red)
        surface.DrawPoly({ { x = -w / 2, y = 0 }, { x = -w / 2 + h / 2, y = -h / 2 }, { x = w / 2, y = -h / 2 }, { x = w / 2, y = h / 2 }, { x = -w / 2 + h / 2, y = h / 2 } })
        surface.SetDrawColor(bg) surface.DrawPoly(disc(-w / 2 + h * 0.42, 0, h * 0.1, 12))
        local price = s.price or "$9.99"
        draw.SimpleText(price, fit("BMXCityAd", { 84, 70, 58, 48, 40, 34 }, price, w * 0.58), w * 0.12, 0, WHITE, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end)
end

function STYLES.split(s, pw, ph, pic)
    local a, b = col(s.bg, { 255, 80, 60 }), col(s.bg2, { 40, 60, 200 })
    frame(pw, ph)
    surface.SetDrawColor(a) surface.DrawRect(-pw / 2, -ph / 2, pw, ph)
    surface.SetDrawColor(b)
    surface.DrawPoly(clipRect({ { x = pw * 0.05, y = -ph / 2 }, { x = pw / 2, y = -ph / 2 }, { x = pw / 2, y = ph / 2 }, { x = -pw * 0.12, y = ph / 2 } },
        -pw / 2, -ph / 2, pw / 2, ph / 2))
    surface.SetDrawColor(255, 255, 255, 255)
    surface.DrawPoly({ { x = pw * 0.05, y = -ph / 2 }, { x = pw * 0.05 + 10, y = -ph / 2 }, { x = -pw * 0.12 + 10, y = ph / 2 }, { x = -pw * 0.12, y = ph / 2 } })
    local x0 = -pw / 2 + pw * 0.04
    local room = pw * 0.5
    draw.SimpleTextOutlined(s.text, fit("BMXCityAd", { 120, 100, 84, 70, 58 }, s.text, room + pw * 0.08), x0, -ph * 0.2, WHITE, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, 5, INK)
    -- the diagonal runs from x = pw*0.05 at the top to -pw*0.12 at the
    -- bottom: a line at height y has until there, less a margin
    local function until_(y) return (pw * 0.05 + (-pw * 0.17) * ((y + ph / 2) / ph)) - x0 - 24 end
    if s.sub then draw.SimpleTextOutlined(s.sub, fit("BMXCityAdSub", { 40, 34, 28, 24, 20 }, s.sub, until_(ph * 0.14)), x0, ph * 0.08, col(s.subColor, { 255, 255, 200 }), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, 3, INK) end
    if s.fine then draw.SimpleText(s.fine, fit("BMXCityAdSub", { 24, 20, 18 }, s.fine, until_(ph * 0.4)), x0, ph * 0.34, WHITE, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER) end
    if pic then
        local psz = ph * 0.7
        tilted(pw / 2 - psz * 0.72, 0, -6, function()
            surface.SetDrawColor(0, 0, 0, 90) surface.DrawRect(-psz / 2 + 12, -psz / 2 + 12, psz + 20, psz + 60)
            surface.SetDrawColor(250, 250, 250, 255) surface.DrawRect(-psz / 2 - 10, -psz / 2 - 10, psz + 20, psz + 60)
            photo(pic, -psz / 2, -psz / 2, psz)
            if s.burst then
                draw.SimpleText(s.burst:gsub("\n", " "), fit("BMXCitySerifSub", { 32, 26, 22 }, s.burst:gsub("\n", " "), psz), 0, psz / 2 + 24, INK, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            end
        end)
    end
end

function STYLES.neon(s, pw, ph, pic)
    local c1, c2 = col(s.fg, { 255, 60, 200 }), col(s.band, { 60, 230, 255 })
    frame(pw, ph, "brackets")
    surface.SetDrawColor(16, 14, 22, 255) surface.DrawRect(-pw / 2, -ph / 2, pw, ph)
    surface.SetDrawColor(255, 255, 255, 8)
    for y = -ph / 2, ph / 2, 30 do surface.DrawRect(-pw / 2, y, pw, 2) end
    -- now and then a tube stutters
    local t = RealTime() + (#s.text * 1.7)
    local on = not (math.sin(t * 0.9) > 0.97 and math.sin(t * 37) > 0)
    local glow = on and 1 or 0.25
    local function tube(x, y, w, h, c)
        for i = 3, 1, -1 do
            surface.SetDrawColor(c.r, c.g, c.b, 30 * glow)
            surface.DrawOutlinedRect(x - i * 4, y - i * 4, w + i * 8, h + i * 8, 4)
        end
        surface.SetDrawColor(c.r, c.g, c.b, 255 * glow) surface.DrawOutlinedRect(x, y, w, h, 5)
    end
    tube(-pw / 2 + 18, -ph / 2 + 18, pw - 36, ph - 36, c2)
    local x0 = -pw / 2 + pw * 0.06
    local room = pw * 0.56
    if pic then
        local psz = ph * 0.62
        local px = pw / 2 - psz - ph * 0.12
        photo(pic, px, -psz / 2, psz)
        surface.SetDrawColor(0, 0, 0, 90) surface.DrawRect(px, -psz / 2, psz, psz)   -- the night dims it
        tube(px - 8, -psz / 2 - 8, psz + 16, psz + 16, c1)
        room = px - 40 - x0
    end
    local hf = fit("BMXCityNeon", { 110, 90, 72, 60, 48 }, s.text, room)
    for _, o in ipairs({ { -4, 0 }, { 4, 0 }, { 0, -4 }, { 0, 4 } }) do
        draw.SimpleText(s.text, hf, x0 + o[1], -ph * 0.12 + o[2], Color(c1.r, c1.g, c1.b, 50 * glow), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    end
    draw.SimpleText(s.text, hf, x0, -ph * 0.12, Color(255, 230, 250, 255 * glow), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    if s.sub then draw.SimpleText(s.sub, fit("BMXCityAdSub", { 40, 34, 28 }, s.sub, room), x0, ph * 0.12, c2, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER) end
    if s.fine then draw.SimpleText(s.fine, fit("BMXCityAdSub", { 24, 20, 18 }, s.fine, room), x0, ph * 0.3, Color(c2.r, c2.g, c2.b, 160), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER) end
end

City.AdStyles = STYLES

local function adSign(s, pw, ph)
    draw.NoTexture()
    local fn = STYLES[s.style or "comic"] or STYLES.comic
    fn(s, pw, ph, City.AdPicture(s))
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

-- Signs are painted boards, not screens: lit by the light that falls on
-- them, not glowing on their own. Over the board, a shade down to the
-- afternoon's light where it stands (brighter under a street lamp), and on a
-- billboard the warm pools its own lamps throw down its face. Only the board
-- is shaded; the lamp heads over it stay bright. Off with bmx_city_mood 0,
-- or on a map with no mood.
local GRAD_DOWN
function City.SignLight(s, layout)
    local m = layout and layout.mood
    if not m or not m.signLight then return 1 end
    local light = m.signLight
    local pool = m.signLampRadius or 520
    for _, l in ipairs(layout.lamps or {}) do
        local dx, dy, dz = s.pos[1] - l.head[1], s.pos[2] - l.head[2], s.pos[3] - l.head[3]
        local d2 = (dx * dx + dy * dy + dz * dz) / (pool * pool)
        if d2 < 1 then light = light + (m.signLampLight or 0.35) * (1 - d2) end
    end
    return math.min(light, 1)
end

function City.LightSign(s, pw, ph, layout)
    local m = layout and layout.mood
    local cv = GetConVar("bmx_city_mood")
    if not m or not m.signLight or (cv and not cv:GetBool()) then return end
    local shade = 1 - City.SignLight(s, layout)
    local dusk = m.signShadow or { 24, 14, 10 }
    draw.NoTexture()
    -- the board takes the light of where it is
    surface.SetDrawColor(dusk[1], dusk[2], dusk[3], 255 * shade)
    surface.DrawRect(-pw / 2, -ph / 2, pw, ph)
    -- and is darker at its foot, furthest from the light above it
    GRAD_DOWN = GRAD_DOWN or Material("vgui/gradient-u")
    surface.SetMaterial(GRAD_DOWN)
    surface.SetDrawColor(dusk[1], dusk[2], dusk[3], 110 * shade)
    surface.DrawTexturedRect(-pw / 2, -ph / 2, pw, ph)
    if (s.look or "ad") == "ad" then
        -- the billboard's four lamps shine down onto it: warm pools from
        -- the top edge, fading down the face
        local warm = m.lampColor or { 255, 186, 112 }
        City._gradDown = City._gradDown or Material("vgui/gradient-d")
        surface.SetMaterial(City._gradDown)
        for i = 1, 4 do
            local lx = -pw / 2 + pw * (i - 0.5) / 4
            surface.SetDrawColor(warm[1], warm[2], warm[3], 70)
            surface.DrawTexturedRect(lx - pw * 0.13, -ph / 2, pw * 0.26, ph * 0.7)
        end
    end
end

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
                -- one bad sign must not leave the 3D2D camera open (that
                -- breaks the rest of the frame): report it once, carry on
                local ok, err = pcall(look, s, pw, ph)
                if not ok and not s._err then s._err = true ErrorNoHalt("[BMX] city sign " .. tostring(s.text) .. ": " .. tostring(err) .. "\n") end
                if ok then City.LightSign(s, pw, ph, layout) end
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
    for k, c in pairs(City._crowns) do if c and c.Destroy then c:Destroy() end City._crowns[k] = nil end
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
