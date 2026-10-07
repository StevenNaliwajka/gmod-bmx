--[[--------------------------------------------------------------------------
    tools/ride/ride_cl.lua -- the ride studio, client half (NOT shipped). Pushed to
    the rendering client by ride_sv.lua; see tools/ride/README.md.

    Renders the world (bike, rider and all) from cameras placed relative to the
    vehicle into a render target, and sends each frame back as a JPEG.
----------------------------------------------------------------------------]]
local W, H = 960, 640
local rt = GetRenderTargetEx("ridestudio_rt1", W, H, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_SEPARATE,
    bit.bor(4, 8), 0, IMAGE_FORMAT_RGBA8888)

local function send(name, data, after)
    local n = math.ceil(#data / 60000)
    for i = 1, n do
        timer.Simple(i * 0.12, function()
            local s = data:sub((i - 1) * 60000 + 1, i * 60000)
            net.Start("ridestudio_img")
            net.WriteString(name) net.WriteUInt(i, 16) net.WriteUInt(n, 16)
            net.WriteUInt(#s, 32) net.WriteData(s, #s)
            net.SendToServer()
        end)
    end
    timer.Simple(n * 0.12 + 0.1, after)
end

local function done(msg)
    net.Start("ridestudio_done") net.WriteString(msg or "") net.SendToServer()
end

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
                local at = base + u * (size * v.at)
                local pos = base + f * (v.pos.x * size) - r * (v.pos.y * size) + u * (v.pos.z * size)
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

net.Receive("ridestudio_cap", function()
    local id = net.ReadString()
    local ent, rider = net.ReadEntity(), net.ReadEntity()
    local tries = 0
    local function attempt()
        if IsValid(ent) then return shoot(id, ent, rider) end
        tries = tries + 1
        if tries > 40 then return done(id .. ": never arrived") end
        timer.Simple(0.1, attempt)
    end
    attempt()
end)
print("[ride] client ready")
