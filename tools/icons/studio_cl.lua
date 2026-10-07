--[[--------------------------------------------------------------------------
    tools/icons/studio_cl.lua -- the icon studio, client half (NOT shipped). Pushed
    to the rendering client by studio_sv.lua; see tools/icons/README.md.

    It draws ONE entity, alone, into a render target, through the entity's own Draw:
    the picture is the thing the player will spawn, not an illustration of it. It is
    drawn twice, on black and on white, and compose.py takes the difference as the
    matte, so the icon has clean edges whatever the item's colours are.

    Things with no entity of their own (the skates, the lock) are drawn below with
    the same primitives and colours the game draws them with.
----------------------------------------------------------------------------]]
local SZ = 512
local rt = GetRenderTargetEx("bmxstudio_rt3", SZ, SZ, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_SEPARATE,
    bit.bor(4, 8), 0, IMAGE_FORMAT_RGBA8888)
STUDIOCL = { cams = {} }      -- fresh on every push: a camera is only good for one run
local C = STUDIOCL

local function send(name, data, after)
    local n = math.ceil(#data / 60000)
    for i = 1, n do
        timer.Simple(i * 0.12, function()
            local s = data:sub((i - 1) * 60000 + 1, i * 60000)
            net.Start("bmxstudio_img")
            net.WriteString(name) net.WriteUInt(i, 16) net.WriteUInt(n, 16)
            net.WriteUInt(#s, 32) net.WriteData(s, #s)
            net.SendToServer()
        end)
    end
    timer.Simple(n * 0.12 + 0.1, after)
end

local function done(msg)
    net.Start("bmxstudio_done") net.WriteString(msg or "") net.SendToServer()
end

-- Things with no entity of their own, drawn the way the game draws them.
local CUSTOM = {}
CUSTOM.weapon_bmx_skates = {
    mins = Vector(-10, -8, 0), maxs = Vector(10, 8, 9),
    draw = function(o)
        local SK = BMX.Skates
        local radius = BMX.ConfigFor(BMX.Vehicles[SK.ID]).Wheel.radius
        render.SetColorMaterial()
        for _, y in ipairs({ -4.5, 4.5 }) do
            local sole = o + Vector(y > 0 and 2.5 or -1, y, radius + 0.4)
            local fr = SK.BootFrame(sole, 0, radius)
            -- the boot: a shell, and a cuff up the ankle
            render.DrawBox(fr.shell, fr.ang, Vector(-5.2, -1.6, -1.6), Vector(5.8, 1.6, 2.2), Color(24, 24, 28))
            render.DrawBox(fr.shell, fr.ang, Vector(-5.2, -1.7, 2.2), Vector(-0.5, 1.7, 7.5), Color(36, 36, 42))
            render.DrawBox(fr.shell, fr.ang, Vector(-5.4, -1.8, 6.2), Vector(-0.3, 1.8, 7.0), Color(220, 60, 50))
            render.DrawBox(fr.frame, fr.ang, Vector(-6.6, -0.6, -0.3), Vector(6.6, 0.6, 0.3), Color(170, 176, 188))
            for _, c in ipairs(fr.wheels) do render.DrawSphere(c, radius, 16, 12, Color(236, 222, 120)) end
        end
    end,
}
CUSTOM.weapon_bmx_lock = {
    mins = Vector(-1, -6, 0), maxs = Vector(1, 6, 18),
    draw = function(o)
        render.SetColorMaterial()
        local steel = Color(112, 118, 130)
        local r, w = 4.6, 0.95
        local base = o + Vector(0, 0, 4)
        -- the shackle: two legs and a half circle on top
        for _, y in ipairs({ -r, r }) do
            render.DrawBox(base + Vector(0, y, 0), Angle(0, 0, 0), Vector(-w, -w, 0), Vector(w, w, 9), steel)
        end
        local top = base + Vector(0, 0, 9)
        local steps = 24
        for i = 0, steps - 1 do
            local a0, a1 = math.pi * i / steps, math.pi * (i + 1) / steps
            local p0 = top + Vector(0, r * math.cos(a0), r * math.sin(a0))
            local p1 = top + Vector(0, r * math.cos(a1), r * math.sin(a1))
            local mid, d = (p0 + p1) / 2, p1 - p0
            render.DrawBox(mid, d:Angle(), Vector(-d:Length() / 2 - 0.15, -w, -w), Vector(d:Length() / 2 + 0.15, w, w), steel)
        end
        -- the crossbar with the barrel lock
        render.DrawBox(base, Angle(0, 0, 0), Vector(-1.6, -r - 2.2, -2.2), Vector(1.6, r + 2.2, 1.6), Color(232, 190, 40))
        render.DrawBox(base, Angle(0, 0, 0), Vector(-1.7, -r - 2.3, -0.5), Vector(1.7, r + 2.3, 0.2), Color(30, 30, 34))
        render.DrawSphere(base + Vector(-1.65, r + 1.0, -0.3), 0.7, 12, 8, Color(150, 150, 150))
    end,
}

local VEHDIR = Vector(0.42, -1, 0.32)      -- the right-hand side, a little from the front
local PARKDIR = Vector(-0.85, -0.7, 0.75)  -- in front of the ramp face, from above

-- Their own camera directions (entity-local): the leaderboard is a plate stood on its
-- edge with the sign on its local +z, so it is shot from in front of that.
local DIRS = {
    weapon_bmx_skates = Vector(0.3, -1, 0.5),
    weapon_bmx_lock = Vector(0.5, -1, 0.25),
    bmx_leaderboard = Vector(-0.2, -0.35, 1),
    -- the rack's cradles run along its local y: seen from the side they stand apart
    bmx_bike_rack = Vector(-1, -0.4, 0.6),
}

local function camFor(center, radius, dir, fov)
    dir = dir:GetNormalized()
    local dist = radius / math.sin(math.rad(fov / 2)) * 1.02
    return center + dir * dist, (-dir):Angle()
end

local function shoot(class, group, ent, stage, gmins, gmaxs)
    local custom = CUSTOM[class]
    local mins, maxs, origin, toWorldDir
    if custom then
        mins, maxs, origin = custom.mins, custom.maxs, stage
        toWorldDir = function(v) return v end
    else
        mins, maxs = ent:GetRenderBounds()
        if gmins and gmaxs and gmaxs ~= gmins then mins, maxs = gmins, gmaxs end
        -- signs only draw their face to a reader in range: the camera is the reader here
        if ent.ReadRange then ent.ReadRange = 1e6 end
        origin = ent:GetPos()
        toWorldDir = function(v) return ent:LocalToWorld(v) - ent:GetPos() end
    end
    local fov = 30
    local pos, ang
    if group ~= "" and C.cams[group] then
        pos, ang = C.cams[group][1], C.cams[group][2]
    else
        local localCenter = (mins + maxs) / 2
        local center = custom and (origin + localCenter) or ent:LocalToWorld(localCenter)
        local radius = (maxs - mins):Length() / 2
        local isPark = class:find("^bmx_park_") ~= nil
        pos, ang = camFor(center, radius, toWorldDir(DIRS[class] or (isPark and PARKDIR or VEHDIR)), fov)
        if group ~= "" then C.cams[group] = { pos, ang } end
    end
    local shots = {}
    local lod = GetConVar("bmx_lod_scale")
    local oldLod = lod and lod:GetString()
    if lod then RunConsoleCommand("bmx_lod_scale", "0") end
    local frames = 0
    local function drawIt()
        if custom then return custom.draw(stage) end
        -- the drawing kit caches its shapes on the entity being drawn
        if BMX.DrawKit and BMX.DrawKit.begin then BMX.DrawKit.begin(ent) end
        ent:Draw(STUDIO_RENDER)
    end
    hook.Add("PostRender", "bmxstudio", function()
        frames = frames + 1
        if not custom and not IsValid(ent) then hook.Remove("PostRender", "bmxstudio") return done(class .. ": gone") end
        -- WARM UP: the bike eases its lean, bars and pose toward the networked state a
        -- frame at a time, so it is drawn (off screen) until it has stopped moving.
        if frames < 45 then
            render.PushRenderTarget(rt)
            cam.Start3D(pos, ang, fov, 0, 0, SZ, SZ, 2, 20000)
            pcall(drawIt)
            cam.End3D()
            render.PopRenderTarget()
            return
        end
        hook.Remove("PostRender", "bmxstudio")
        local err
        render.PushRenderTarget(rt)
        for _, bg in ipairs({ { "k", 0 }, { "w", 255 } }) do
            render.Clear(bg[2], bg[2], bg[2], 255, true, true)
            cam.Start3D(pos, ang, fov, 0, 0, SZ, SZ, 2, 20000)
            local ok, e = pcall(drawIt)
            if not ok then err = tostring(e) end
            cam.End3D()
            shots[bg[1]] = render.Capture({ format = "png", x = 0, y = 0, w = SZ, h = SZ, alpha = false })
        end
        render.PopRenderTarget()
        if lod then RunConsoleCommand("bmx_lod_scale", oldLod) end
        send(class .. "_k", shots.k, function()
            send(class .. "_w", shots.w, function() done(err and (class .. ": " .. err) or nil) end)
        end)
    end)
end

net.Receive("bmxstudio_shoot", function()
    local class, group, idx, stage = net.ReadString(), net.ReadString(), net.ReadUInt(16), net.ReadVector()
    local gmins, gmaxs = net.ReadVector(), net.ReadVector()
    local tries = 0
    local function attempt()
        local ent = Entity(idx)
        if CUSTOM[class] then return shoot(class, group, nil, stage) end
        if IsValid(ent) then
            -- one more beat so Think has built whatever the entity builds
            return timer.Simple(1.2, function()
                if IsValid(ent) then shoot(class, group, ent, stage, gmins, gmaxs) else done(class .. ": gone") end
            end)
        end
        tries = tries + 1
        if tries > 40 then return done(class .. ": never arrived (" .. idx .. ")") end
        timer.Simple(0.1, attempt)
    end
    attempt()
end)
print("[studio] client ready")
