--[[--------------------------------------------------------------------------
    tools/ride/ride_cl.lua -- the ride studio, client half (NOT shipped). Pushed to
    the rendering client by ride_sv.lua; see tools/ride/README.md.

    Renders the world (bike, rider and all) from cameras placed relative to the
    vehicle into a render target, and sends each frame back as a JPEG.
----------------------------------------------------------------------------]]
local W, H = 960, 640
local rt = GetRenderTargetEx("ridestudio_rt1", W, H, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_SEPARATE,
    bit.bor(4, 8), 0, IMAGE_FORMAT_RGBA8888)

-- Chunks of 30 kB a quarter second apart: ~120 kB/s, inside a client's upload rate,
-- so a long run never backs up the owner's connection.
local CHUNK, GAP = 30000, 0.25
local function send(name, data, after)
    local n = math.ceil(#data / CHUNK)
    for i = 1, n do
        timer.Simple(i * GAP, function()
            local s = data:sub((i - 1) * CHUNK + 1, i * CHUNK)
            net.Start("ridestudio_img")
            net.WriteString(name) net.WriteUInt(i, 16) net.WriteUInt(n, 16)
            net.WriteUInt(#s, 32) net.WriteData(s, #s)
            net.SendToServer()
        end)
    end
    timer.Simple(n * GAP + 0.1, after)
end

-- The client's own settings that would hide the built model (bmx_debug draws the
-- simple bike, bmx_bike_model 0 turns the model off) are set for the shoot and put
-- back exactly as they were when it ends; what they were is reported, so a surprise
-- setting is visible in the server log.
local saved
local function studioSettings()
    if saved then return end
    saved = {}
    for name, want in pairs({ bmx_debug = "0", bmx_bike_model = "1", bmx_lod_scale = "0" }) do
        local cv = GetConVar(name)
        if cv then
            saved[name] = cv:GetString()
            if saved[name] ~= want then RunConsoleCommand(name, want) end
        end
    end
end
local function restoreSettings()
    if not saved then return "" end
    local notes = {}
    for name, v in pairs(saved) do
        notes[#notes + 1] = name .. "=" .. v
        RunConsoleCommand(name, v)
    end
    saved = nil
    return table.concat(notes, " ")
end

local function done(msg)
    net.Start("ridestudio_done") net.WriteString(msg or "") net.SendToServer()
end
RIDESTUDIO_RESTORE = restoreSettings

-- Cameras in the vehicle's own space (x forward, y left, z up), in multiples of a
-- size that follows the vehicle, aimed at a point `at` up from its origin.
RIDESTUDIO_VIEWS = RIDESTUDIO_VIEWS or {
    { name = "side1",  pos = Vector(0.35, -1.55, 0.55), at = 0.5, fov = 42 },
    { name = "side2",  pos = Vector(0.35, -1.55, 0.55), at = 0.5, fov = 42, wait = 0.13 },
    { name = "side3",  pos = Vector(0.35, -1.55, 0.55), at = 0.5, fov = 42, wait = 0.13 },
    { name = "front",  pos = Vector(1.6, -0.45, 0.6),   at = 0.5, fov = 42 },
    { name = "rear",   pos = Vector(-1.5, 0.7, 0.75),   at = 0.5, fov = 42 },
    { name = "legs",   pos = Vector(0.15, -0.95, 0.3),  at = 0.3,  fov = 45 },
    { name = "top",    pos = Vector(0.3, -0.5, 1.6),    at = 0.4,  fov = 42 },
    -- the bars close up, the bell's lever caught mid-flick (local units)
    { name = "bell",   lpos = Vector(20, 16, 36), lat = Vector(9, 2.7, 24.5), fov = 34, ring = true },
}

local function shoot(id, ent, rider)
    local views = RIDESTUDIO_VIEWS
    local size = 70
    if ent.Cfg then
        local C = ent:Cfg()
        size = math.max(60, (C.Wheel.wheelbase or 40) + 2 * (C.Wheel.radius or 10)) * 1.3
    end
    local i = 0
    local function nextView()
        i = i + 1
        local v = views[i]
        if not v then return done() end
        timer.Simple(v.wait or 0.25, function()
            if not IsValid(ent) then return done(id .. ": gone") end
            hook.Add("PostRender", "ridestudio", function()
                hook.Remove("PostRender", "ridestudio")
                local base = ent:GetPos()
                local yawAng = Angle(0, ent:GetAngles().y, 0)
                local f, r, u = yawAng:Forward(), yawAng:Right(), Vector(0, 0, 1)
                local at, pos
                if v.lpos then
                    local k = ent.Cfg and ent:Cfg().Wheel.wheelbase / 39 or 1
                    at, pos = ent:LocalToWorld(v.lat * k), ent:LocalToWorld(v.lpos * k)
                else
                    at = base + u * (size * v.at)
                    pos = base + f * (v.pos.x * size) - r * (v.pos.y * size) + u * (v.pos.z * size)
                end
                if v.ring then ent.bellRungAt = CurTime() - 0.055 end
                local ang = (at - pos):Angle()
                render.PushRenderTarget(rt)
                render.Clear(0, 0, 0, 255, true, true)
                render.RenderView({ origin = pos, angles = ang, x = 0, y = 0, w = W, h = H, fov = v.fov,
                    drawviewmodel = false, drawhud = false, dopostprocess = false, drawmonitors = false })
                local data = render.Capture({ format = "jpeg", quality = 88, x = 0, y = 0, w = W, h = H })
                render.PopRenderTarget()
                if not data then return done(id .. ": capture failed") end
                send(id .. "_" .. v.name, data, nextView)
            end)
        end)
    end
    nextView()
end

-- A sequence: a follow camera on the vehicle's right, a frame every `dt`, so the
-- rider's motion (pedalling, a turn, a hop and its landing) can be read frame by frame.
local function sequence(id, ent, n, dt)
    local size = 70
    if ent.Cfg then
        local C = ent:Cfg()
        size = math.max(60, (C.Wheel.wheelbase or 40) + 2 * (C.Wheel.radius or 10)) * 1.3
    end
    local i = 0
    local yaw0
    local frames = {}
    local function upload(j)
        if j > #frames then return timer.Simple(0.5, function() done() end) end
        send(string.format("%s_seq%02d", id, j), frames[j], function() upload(j + 1) end)
    end
    local function shot()
        i = i + 1
        if i > n then return upload(1) end
        hook.Add("PostRender", "ridestudio", function()
            hook.Remove("PostRender", "ridestudio")
            if not IsValid(ent) then return done(id .. ": gone") end
            local base = ent:GetPos()
            yaw0 = yaw0 or ent:GetAngles().y
            -- the camera keeps its own heading (the start's) so a turn shows as a turn
            local ya = Angle(0, yaw0, 0)
            local f, r, u = ya:Forward(), ya:Right(), Vector(0, 0, 1)
            local at = base + u * (size * 0.42)
            local pos = base + f * (0.25 * size) + r * (1.5 * size) + u * (0.5 * size)
            render.PushRenderTarget(rt)
            render.Clear(0, 0, 0, 255, true, true)
            render.RenderView({ origin = pos, angles = (at - pos):Angle(), x = 0, y = 0, w = W, h = H, fov = 46,
                drawviewmodel = false, drawhud = false, dopostprocess = false, drawmonitors = false })
            frames[i] = render.Capture({ format = "jpeg", quality = 72, x = 0, y = 0, w = W, h = H })
            render.PopRenderTarget()
            timer.Simple(dt, shot)
        end)
    end
    shot()
end

-- Wait for the vehicle's built model (cl_init BMX.BikeModelFor advances its build;
-- the owner's own view is elsewhere, so nothing else would), up to 30 s.
local function whenBuilt(ent, fn)
    local t0 = RealTime()
    local function step()
        if not IsValid(ent) then return fn() end
        local ready = not (ent.Cfg and BMX.BikeModelFor) or BMX.BikeModelFor(ent) ~= nil
            or (ent.Bike and not ent:Bike().look)
        if ready or RealTime() - t0 > 30 then return timer.Simple(0.3, fn) end
        timer.Simple(0, step)
    end
    step()
end

net.Receive("ridestudio_cap", function()
    if not saved then
        local d = { "mesh=" .. tostring(Mesh ~= nil), "geo=" .. tostring(BMX.BikeGeo ~= nil),
            "kinds=" .. tostring(BMX.BikeGeo and table.Count(BMX.BikeGeo.Kinds)),
            "enabledBefore=" .. tostring(BMX.BikeMesh and BMX.BikeMesh.Enabled()) }
        for _, n in ipairs({ "bmx_debug", "bmx_bike_model", "bmx_lod_scale", "bmx_bike_build_ms" }) do
            local cv = GetConVar(n)
            d[#d + 1] = n .. "=" .. (cv and cv:GetString() or "nil")
        end
        net.Start("ridestudio_diag") net.WriteString(table.concat(d, " ")) net.SendToServer()
    end
    studioSettings()
    local id = net.ReadString()
    local ent, rider = net.ReadEntity(), net.ReadEntity()
    local mode = net.ReadString()
    if mode == "seq" then
        return whenBuilt(ent, function() sequence(id, ent, 26, 0.12) end)
    end
    local tries = 0
    local function attempt()
        if IsValid(ent) then return whenBuilt(ent, function() shoot(id, ent, rider) end) end
        tries = tries + 1
        if tries > 40 then return done(id .. ": never arrived") end
        timer.Simple(0.1, attempt)
    end
    attempt()
end)
print("[ride] client ready")

-- The server says the run is over: the client's settings go back.
net.Receive("ridestudio_end", function()
    local was = restoreSettings()
    net.Start("ridestudio_done") net.WriteString("settings restored: " .. was) net.SendToServer()
end)
