--[[--------------------------------------------------------------------------
    bmx/cl_cinematic.lua

    Cinematic mode, after GTA's: press L while riding and the camera leaves
    the chase position for a run of external shots that cut from one to the
    next while you ride.

        trackside   set up ahead of where the bike is going and off to one
                    side; it does not move, it pans as the bike rides past,
                    and it zooms in as the bike gets further away
        low chase   close behind at wheel height, a little off to one side
        dolly       alongside at the bike's own speed, looking across at it
        front       ahead of the bike, looking back at the rider
        air         wide and to the side while the bike is in the air
        orbit       a slow circle round a bike that is standing still

    A shot is cut after a few seconds, or at once if the bike leaves the frame
    or something comes between it and the camera, and the next is chosen for
    what the bike is doing. No camera position is ever used without a trace
    from the bike to it, so the camera never sits inside a wall.

    L toggles it, bmx_cinematic does the same from the console, and getting
    off ends it. The letterbox bars are the tell that it is on.
----------------------------------------------------------------------------]]

BMX = BMX or {}

local cv = CreateClientConVar("bmx_cinematic", "0", false, false,
    "Cinematic camera while riding a BMX (L toggles it).")

local SHOT_MIN, SHOT_MAX = 3.0, 6.0     -- seconds a shot lasts
local HULL = Vector(6, 6, 6)

local state = { shot = nil }
BMX.CinematicState = state

-- Is there a clear line from the bike to `pos`? Also returns where the line
-- stops, so a blocked shot can be pulled in instead of discarded.
local function clearFrom(bike, from, to)
    local tr = util.TraceHull({
        start = from, endpos = to, mins = -HULL, maxs = HULL,
        filter = { bike, bike:GetPod(), bike:GetDriver() }, mask = MASK_SOLID_BRUSHONLY,
    })
    return not tr.Hit, tr.HitPos
end

-- The point the camera looks at: the rider's chest, roughly.
local function subject(bike)
    return bike:LocalToWorld(Vector(0, 0, 30))
end

local function flatForward(bike)
    local v = bike:GetVelocity()
    v.z = 0
    if v:Length() > 30 then return v:GetNormalized(), v:Length() end
    local f = bike:GetForward()
    f.z = 0
    return f:GetNormalized(), 0
end

--------------------------------------------------------------------------
-- The shots. Each `make` returns a table with `kind` and whatever it needs,
-- or nil if it cannot be set up from here (blocked, say). `view` returns an
-- origin and a FOV for this frame.
--------------------------------------------------------------------------
local SHOTS = {}

SHOTS.trackside = {
    make = function(bike, rng)
        local fwd, speed = flatForward(bike)
        if speed < 60 then return nil end
        local side = fwd:Cross(Vector(0, 0, 1)) * (rng() < 0.5 and -1 or 1)
        local ahead = math.Clamp(speed * 1.6, 250, 900)
        local want = subject(bike) + fwd * ahead + side * (140 + rng() * 120)
            + Vector(0, 0, 10 + rng() * 60)
        local ok = clearFrom(bike, subject(bike), want)
        if not ok then return nil end
        return { kind = "trackside", pos = want }
    end,
    view = function(shot, bike)
        -- Fixed; the lens tightens with distance so the bike stays a size.
        local d = shot.pos:Distance(subject(bike))
        return shot.pos, math.Clamp(9000 / math.max(d, 1), 18, 70)
    end,
}

SHOTS.lowchase = {
    make = function(bike, rng)
        return { kind = "lowchase", side = (rng() < 0.5 and -1 or 1) * (20 + rng() * 25) }
    end,
    view = function(shot, bike)
        local fwd = flatForward(bike)
        local side = fwd:Cross(Vector(0, 0, 1))
        local want = bike:GetPos() - fwd * 75 + side * shot.side + Vector(0, 0, 8)
        local _, at = clearFrom(bike, subject(bike), want)
        return at, 80
    end,
}

SHOTS.dolly = {
    make = function(bike, rng)
        return { kind = "dolly", side = (rng() < 0.5 and -1 or 1) * (130 + rng() * 60),
                 height = 20 + rng() * 25 }
    end,
    view = function(shot, bike)
        local fwd = flatForward(bike)
        local side = fwd:Cross(Vector(0, 0, 1))
        local want = subject(bike) + side * shot.side + Vector(0, 0, shot.height)
        local _, at = clearFrom(bike, subject(bike), want)
        return at, 60
    end,
}

SHOTS.front = {
    make = function(bike, rng)
        local _, speed = flatForward(bike)
        if speed < 40 then return nil end
        return { kind = "front", side = (rng() - 0.5) * 60 }
    end,
    view = function(shot, bike)
        local fwd = flatForward(bike)
        local side = fwd:Cross(Vector(0, 0, 1))
        local want = subject(bike) + fwd * 110 + side * shot.side + Vector(0, 0, 6)
        local _, at = clearFrom(bike, subject(bike), want)
        return at, 70
    end,
}

SHOTS.air = {
    make = function(bike, rng)
        local fwd = flatForward(bike)
        local side = fwd:Cross(Vector(0, 0, 1)) * (rng() < 0.5 and -1 or 1)
        return { kind = "air", pos = subject(bike) + side * 260 + fwd * 120 - Vector(0, 0, 30) }
    end,
    view = function(shot, bike)
        local ok, at = clearFrom(bike, subject(bike), shot.pos)
        return ok and shot.pos or at, 75
    end,
}

SHOTS.orbit = {
    make = function(bike, rng)
        return { kind = "orbit", yaw = rng() * 360 }
    end,
    view = function(shot, bike, dt)
        shot.yaw = shot.yaw + 12 * dt
        local a = Angle(0, shot.yaw, 0)
        local want = subject(bike) + a:Forward() * 140 + Vector(0, 0, 25)
        local _, at = clearFrom(bike, subject(bike), want)
        return at, 65
    end,
}
BMX.CinematicShots = SHOTS

-- What to cut to, for what the bike is doing. Never the same kind twice.
local function choose(bike, last, rng)
    local _, speed = flatForward(bike)
    local airborne = not bike:GetGrounded()
    local order
    if airborne then
        order = { "air", "dolly", "trackside" }
    elseif speed < 25 then
        order = { "orbit" }
    else
        -- The riding shots, from a random starting point, so the run of cuts
        -- is not the same every time.
        local base = { "trackside", "lowchase", "dolly", "front" }
        local k = math.floor(rng() * #base)
        order = {}
        for i = 0, #base - 1 do order[#order + 1] = base[((k + i) % #base) + 1] end
    end
    for _, kind in ipairs(order) do
        if kind ~= last or #order == 1 then
            local s = SHOTS[kind].make(bike, rng)
            if s then return s end
        end
    end
    return SHOTS.lowchase.make(bike, rng)       -- always possible
end

-- One frame of the cinematic camera: a view table, cutting when it is time.
function BMX.CinematicView(bike, dt, now, rng)
    rng = rng or math.random
    local shot = state.shot
    local cut = not shot or now >= shot.untilT
    if shot and not cut then
        -- Lost the bike: out of the frame, or something in the way.
        local origin = shot.lastOrigin
        if origin then
            local ok = clearFrom(bike, subject(bike), origin)
            local dir = (subject(bike) - origin):GetNormalized()
            local toward = shot.lastAng and shot.lastAng:Forward():Dot(dir) or 1
            if not ok or toward < 0.8 then cut = true end
        end
        -- Took off or landed: a new shot for the new situation.
        if (shot.air or false) ~= (not bike:GetGrounded()) then cut = true end
    end
    if cut then
        shot = choose(bike, shot and shot.kind, rng)
        shot.untilT = now + SHOT_MIN + rng() * (SHOT_MAX - SHOT_MIN)
        shot.air = not bike:GetGrounded()
        state.shot = shot
        state.cuts = (state.cuts or 0) + 1
    end
    local origin, fov = SHOTS[shot.kind].view(shot, bike, dt)
    local ang = (subject(bike) - origin):Angle()
    shot.lastOrigin, shot.lastAng = origin, ang
    return { origin = origin, angles = ang, fov = fov, drawviewer = true }
end

function BMX.CinematicActive(ply)
    return cv:GetBool() and BMX.LocalBike(ply) ~= nil
end

--------------------------------------------------------------------------
-- L toggles it. PlayerButtonDown runs client-side for the local player; the
-- first-time check stops prediction firing it twice.
--------------------------------------------------------------------------
hook.Add("PlayerButtonDown", "BMX.CinematicKey", function(ply, button)
    if button ~= KEY_L or ply ~= LocalPlayer() then return end
    if IsFirstTimePredicted and not IsFirstTimePredicted() then return end
    if not BMX.LocalBike(ply) then return end
    cv:SetBool(not cv:GetBool())
    state.shot = nil
end)

-- Getting off ends it, so the next ride starts on the normal camera.
hook.Add("Think", "BMX.CinematicOff", function()
    local ply = LocalPlayer()
    if cv:GetBool() and IsValid(ply) and not BMX.LocalBike(ply) then
        cv:SetBool(false)
        state.shot = nil
    end
end)

--------------------------------------------------------------------------
-- Letterbox bars: the tell that it is on.
--------------------------------------------------------------------------
hook.Add("HUDPaint", "BMX.CinematicBars", function()
    local ply = LocalPlayer()
    if not IsValid(ply) or not BMX.CinematicActive(ply) then return end
    local h = math.floor(ScrH() * 0.1)
    surface.SetDrawColor(0, 0, 0, 255)
    surface.DrawRect(0, 0, ScrW(), h)
    surface.DrawRect(0, ScrH() - h, ScrW(), h)
end)
