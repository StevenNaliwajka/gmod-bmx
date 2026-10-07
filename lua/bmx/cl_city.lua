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

function City.BuildMeshes(layout)
    City.FreeMeshes()
    local out = {}
    -- stable order, so the draw order (and anything that depends on it) is
    -- the same every build
    local keys = {}
    for k in pairs(layout.faces) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local list = layout.faces[key]
        local M = City.Materials[key]
        local col = M.color or { 1, 1, 1 }
        local mat = City.Material(key)
        local i = 1
        while i <= #list do
            local n = math.min(#list - i + 1, QUADS_PER_MESH)
            local m = Mesh(mat)
            mesh.Begin(m, MATERIAL_QUADS, n)
            for j = i, i + n - 1 do
                local q = list[j]
                local s = q[17]
                local r, g, b = clamp255(s * col[1]), clamp255(s * col[2]), clamp255(s * col[3])
                mesh.Position(Vector(q[1], q[2], q[3])) mesh.TexCoord(0, q[13], q[14]) mesh.Color(r, g, b, 255) mesh.AdvanceVertex()
                mesh.Position(Vector(q[4], q[5], q[6])) mesh.TexCoord(0, q[15], q[14]) mesh.Color(r, g, b, 255) mesh.AdvanceVertex()
                mesh.Position(Vector(q[7], q[8], q[9])) mesh.TexCoord(0, q[15], q[16]) mesh.Color(r, g, b, 255) mesh.AdvanceVertex()
                mesh.Position(Vector(q[10], q[11], q[12])) mesh.TexCoord(0, q[13], q[16]) mesh.Color(r, g, b, 255) mesh.AdvanceVertex()
            end
            mesh.End()
            out[#out + 1] = { mesh = m, mat = mat, key = key, quads = n }
            i = i + n
        end
    end
    City.meshes = out
    return out
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
local fontsMade = false
local function makeFonts()
    if fontsMade then return end
    fontsMade = true
    surface.CreateFont("BMXCitySign", { font = "Coolvetica", size = 120, weight = 800, antialias = true })
    surface.CreateFont("BMXCitySignSub", { font = "Roboto", size = 40, weight = 700, antialias = true })
end

local function drawSigns(layout)
    makeFonts()
    for _, s in ipairs(layout.signs) do
        local n = Vector(s.normal[1], s.normal[2], s.normal[3])
        local ang = n:Angle()
        ang:RotateAroundAxis(ang:Up(), 90)
        ang:RotateAroundAxis(ang:Forward(), 90)
        -- 120 px of title font is 55% of the panel's height
        local scale = (s.h * 0.55) / 120
        local pw, ph = s.w / scale, s.h / scale
        local c = s.color
        cam.Start3D2D(Vector(s.pos[1], s.pos[2], s.pos[3]), ang, scale)
            surface.SetDrawColor(c[1], c[2], c[3], 255)
            surface.DrawRect(-pw / 2 - 10, -ph / 2 - 10, pw + 20, ph + 20)
            surface.SetDrawColor(14, 16, 22, 255)
            surface.DrawRect(-pw / 2, -ph / 2, pw, ph)
            draw.SimpleText(s.text, "BMXCitySign", 0, -ph * 0.1, Color(c[1], c[2], c[3], 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            if s.sub then
                draw.SimpleText(s.sub, "BMXCitySignSub", 0, ph * 0.32, Color(235, 235, 235, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            end
        cam.End3D2D()
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

function City.Draw(bDepth, bSkybox, b3DSky)
    if bDepth or bSkybox or b3DSky then return end
    if not City.meshes then return end
    if not cvDraw:GetBool() or not City.Enabled() then
        for name in pairs(City._sounds) do lineSound(name, nil, false) end
        return
    end
    for _, m in ipairs(City.meshes) do
        render.SetMaterial(m.mat)
        m.mesh:Draw()
    end
    local L = City._layout
    if not L then return end
    if cvTrains:GetBool() then
        drawTrains(L, CurTime())
    else
        for name in pairs(City._sounds) do lineSound(name, nil, false) end
    end
    if cvSigns:GetBool() then drawSigns(L) end
end
hook.Add("PostDrawOpaqueRenderables", "BMXCity", City.Draw)

concommand.Add("bmx_city_rebuild_client", function()
    City.ClientClear()
    City.ClientBuild()
end, nil, "BMX: rebuild the city's meshes on this client")
