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
----------------------------------------------------------------------------]]

local City = BMX.City

local cvDraw = CreateClientConVar("bmx_city_draw", "1", true, false, "BMX: draw the city around the park (1/0)")
local cvTrains = CreateClientConVar("bmx_city_trains", "1", true, false, "BMX: run the subway trains (1/0)")
local cvSigns = CreateClientConVar("bmx_city_signs", "1", true, false, "BMX: draw the city's signs (1/0)")

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

    local out = {}
    for _, b in ipairs(order) do
        local M = City.Materials[b.key]
        local col = M.color or { 1, 1, 1 }
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
                local r, g, bl = clamp255(s * col[1]), clamp255(s * col[2]), clamp255(s * col[3])
                mesh.Position(Vector(q[1], q[2], q[3])) mesh.TexCoord(0, q[13], q[14]) mesh.Color(r, g, bl, 255) mesh.AdvanceVertex()
                mesh.Position(Vector(q[4], q[5], q[6])) mesh.TexCoord(0, q[15], q[14]) mesh.Color(r, g, bl, 255) mesh.AdvanceVertex()
                mesh.Position(Vector(q[7], q[8], q[9])) mesh.TexCoord(0, q[15], q[16]) mesh.Color(r, g, bl, 255) mesh.AdvanceVertex()
                mesh.Position(Vector(q[10], q[11], q[12])) mesh.TexCoord(0, q[13], q[16]) mesh.Color(r, g, bl, 255) mesh.AdvanceVertex()
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
    if l.axis == "y" then return l.at, a, z, 90 end
    return a, l.at, z, 0
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
-- Signs
--------------------------------------------------------------------------
-- Three looks, after Petopia's own pages (naliwajka.com/petopia: a 1998
-- desktop -- navy title bars, silver bevels, cyan and yellow on navy):
--   window     a Windows-98 window: title bar, three buttons, silver body
--   neon       a dark panel with a coloured frame and glowing text
--   billboard  a big rooftop board: navy, a yellow rule, huge type
-- `text` is the headline, `sub` the line under it, `title` the window's
-- title bar. Colours are {r,g,b}.
local fontsMade = false
local function makeFonts()
    if fontsMade then return end
    fontsMade = true
    surface.CreateFont("BMXCitySign", { font = "Coolvetica", size = 120, weight = 800, antialias = true })
    surface.CreateFont("BMXCitySignSub", { font = "Roboto", size = 40, weight = 700, antialias = true })
    surface.CreateFont("BMXCityWin", { font = "Tahoma", size = 110, weight = 900, antialias = true })
    surface.CreateFont("BMXCityWinTitle", { font = "Tahoma", size = 30, weight = 800, antialias = true })
    surface.CreateFont("BMXCityWinSub", { font = "Tahoma", size = 34, weight = 700, antialias = true })
end

local NAVY, NAVY2 = Color(0, 0, 128), Color(16, 132, 208)
local SILVER, WHITE, GREY, DARK = Color(192, 192, 192), Color(255, 255, 255), Color(128, 128, 128), Color(40, 40, 40)

local function bevel(x, y, w, h, raised)
    local tl, br = raised and WHITE or GREY, raised and GREY or WHITE
    surface.SetDrawColor(tl) surface.DrawRect(x, y, w, 3) surface.DrawRect(x, y, 3, h)
    surface.SetDrawColor(br) surface.DrawRect(x, y + h - 3, w, 3) surface.DrawRect(x + w - 3, y, 3, h)
end

local function windowSign(s, pw, ph, c)
    local tb = math.min(ph * 0.2, 44)
    surface.SetDrawColor(SILVER) surface.DrawRect(-pw / 2, -ph / 2, pw, ph)
    bevel(-pw / 2, -ph / 2, pw, ph, true)
    -- title bar: navy fading to blue, as 98 drew it
    local x0, y0, w0 = -pw / 2 + 6, -ph / 2 + 6, pw - 12
    for i = 0, 15 do
        local f = i / 15
        surface.SetDrawColor(NAVY.r + (NAVY2.r - NAVY.r) * f, NAVY.g + (NAVY2.g - NAVY.g) * f, NAVY.b + (NAVY2.b - NAVY.b) * f, 255)
        surface.DrawRect(x0 + w0 * i / 16, y0, w0 / 16 + 1, tb)
    end
    draw.SimpleText(s.title or "Petopia", "BMXCityWinTitle", x0 + 10, y0 + tb / 2, WHITE, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    for i = 1, 3 do
        local bx = x0 + w0 - i * (tb + 2) - 2
        surface.SetDrawColor(SILVER) surface.DrawRect(bx, y0 + 4, tb - 6, tb - 8)
        bevel(bx, y0 + 4, tb - 6, tb - 8, true)
        draw.SimpleText(({ "x", "o", "_" })[i], "BMXCityWinTitle", bx + (tb - 6) / 2, y0 + tb / 2, DARK, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
    -- the body: a sunken field, the headline in the sign's colour
    local by = y0 + tb + 8
    local bh = ph / 2 - 6 - by - 6
    surface.SetDrawColor(s.field and Color(s.field[1], s.field[2], s.field[3]) or NAVY)
    surface.DrawRect(x0 + 4, by, w0 - 8, bh)
    bevel(x0 + 4, by, w0 - 8, bh, false)
    local hasSub = s.sub ~= nil
    draw.SimpleText(s.text, "BMXCityWin", 0, by + bh * (hasSub and 0.4 or 0.5), Color(c[1], c[2], c[3]), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    if hasSub then
        draw.SimpleText(s.sub, "BMXCityWinSub", 0, by + bh * 0.82, WHITE, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
end

local function neonSign(s, pw, ph, c)
    surface.SetDrawColor(c[1], c[2], c[3], 255)
    surface.DrawRect(-pw / 2 - 10, -ph / 2 - 10, pw + 20, ph + 20)
    surface.SetDrawColor(14, 16, 22, 255)
    surface.DrawRect(-pw / 2, -ph / 2, pw, ph)
    local glow = Color(c[1], c[2], c[3], 60)
    for _, o in ipairs({ { -3, 0 }, { 3, 0 }, { 0, -3 }, { 0, 3 } }) do
        draw.SimpleText(s.text, "BMXCitySign", o[1], -ph * 0.1 + o[2], glow, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
    draw.SimpleText(s.text, "BMXCitySign", 0, -ph * 0.1, Color(c[1], c[2], c[3], 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    if s.sub then
        draw.SimpleText(s.sub, "BMXCitySignSub", 0, ph * 0.32, Color(235, 235, 235, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
end

local function billboardSign(s, pw, ph, c)
    surface.SetDrawColor(NAVY) surface.DrawRect(-pw / 2, -ph / 2, pw, ph)
    surface.SetDrawColor(255, 255, 0, 255)
    surface.DrawRect(-pw / 2, -ph / 2, pw, 8) surface.DrawRect(-pw / 2, ph / 2 - 8, pw, 8)
    surface.DrawRect(-pw / 2, ph * 0.18, pw, 4)
    draw.SimpleText(s.text, "BMXCitySign", 0, -ph * 0.14, Color(c[1], c[2], c[3]), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    if s.sub then
        draw.SimpleText(s.sub, "BMXCitySignSub", 0, ph * 0.34, Color(0, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
end

local LOOKS = { window = windowSign, neon = neonSign, billboard = billboardSign }

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
            -- neon/billboard: the headline font is 55% of the panel's height;
            -- a window is laid out 360 px tall, title bar and all
            local scale = (s.look == "window") and (s.h / 360) or ((s.h * 0.55) / 120)
            local pw, ph = s.w / scale, s.h / scale
            local look = LOOKS[s.look or "neon"] or neonSign
            cam.Start3D2D(p + n * 0.5, ang, scale)
                look(s, pw, ph, s.color)
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
    local ms = ((SysTime and SysTime() or 0) - t0) * 1000
    MsgN(string.format("[BMX] city: %d buildings, %d quads in %d meshes, %d subway lines (%.0f ms)",
        #L.buildings, L.quads, #City.meshes, #L.lines, ms))
    return true
end

function City.ClientClear()
    City.FreeMeshes()
    for name in pairs(City._sounds) do lineSound(name, nil, false) end
    for i, m in pairs(City._cars) do if IsValid(m) then m:Remove() end City._cars[i] = nil end
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
