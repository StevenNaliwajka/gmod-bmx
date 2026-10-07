--[[--------------------------------------------------------------------------
    bmx/cl_filmer.lua

    Looking through a bmx_filmer_cam (entities/bmx_filmer_cam), and the
    camera maths the replay's fixed and "filmer follow" cameras share (G21,
    G28).

        bmx_filmer_view     toggle the view through the nearest filmer camera
                            (none in the map: it says so and does nothing)

    A FILMER CAMERA HAS A HUMAN'S HANDS. It does not snap to the rider: the
    aim is eased toward the subject (BMX.FilmerTrack), so it lags a fast rider
    a touch and settles on a slow one, the way a person panning a camcorder
    does, and the field of view is worked out from the distance so the rider
    stays about the same size in frame as they approach and leave
    (BMX.FilmerAim). Both are pure functions of numbers, so
    tests/test_replay.lua checks them without a renderer.

    NOTHING IS NETWORKED. The nearest rider is found from the bikes this
    client already has, so a filmer camera costs the server nothing.
----------------------------------------------------------------------------]]

BMX = BMX or {}

-- How tall the subject should look in frame, in units: a rider and a bike
-- with room for a trick above. Sets the zoom.
local FRAME_HEIGHT = 130
local FOV_MIN, FOV_MAX = 18, 80
local AIM_RATE = 5            -- 1/s: how quickly the operator catches up

-- The angles that look from `from` at `at`.
function BMX.FilmerAim(from, at)
    local d = at - from
    local flat = math.sqrt(d.x * d.x + d.y * d.y)
    local yaw = math.deg(math.atan2(d.y, d.x))
    local pitch = -math.deg(math.atan2(d.z, flat))
    return Angle(pitch, yaw, 0)
end

-- The field of view that frames the subject at `dist` units.
function BMX.FilmerFov(dist)
    local fov = math.deg(2 * math.atan((FRAME_HEIGHT * 0.5) / math.max(dist, 1)))
    return math.Clamp(fov, FOV_MIN, FOV_MAX)
end

-- Ease the camera's aim toward `want` (an Angle); `st` keeps the current one.
-- The first call lands on the target. Returns the eased Angle.
function BMX.FilmerTrack(st, want, dt)
    if not st.ang then st.ang = Angle(want.p, want.y, 0) return st.ang end
    local k = math.min(1, AIM_RATE * dt)
    st.ang = Angle(
        st.ang.p + math.AngleDifference(want.p, st.ang.p) * k,
        math.NormalizeAngle(st.ang.y + math.AngleDifference(want.y, st.ang.y) * k),
        0)
    return st.ang
end

-- The closest entry of `list` (anything with GetPos) to `pos` within `range`.
function BMX.FilmerNearest(pos, list, range)
    local best, bestD = nil, (range or math.huge)
    for _, e in ipairs(list) do
        local d = pos:Distance(e:GetPos())
        if d <= bestD then best, bestD = e, d end
    end
    return best
end

-- Every bike on this client, cached for a second: a walk of the entity list is
-- cheap, but not something to do every frame for every camera.
local bikeCache, bikeCacheAt = {}, -10
function BMX.AllBikes()
    local now = CurTime()
    if now - bikeCacheAt > 1 then
        bikeCache, bikeCacheAt = {}, now
        for _, e in ipairs(ents.GetAll()) do
            if e.IsBMX then bikeCache[#bikeCache + 1] = e end
        end
    end
    return bikeCache
end

-- The nearest bike with a rider on it to `pos`.
function BMX.FilmerNearestRider(pos, range)
    local ridden = {}
    for _, b in ipairs(BMX.AllBikes()) do
        if IsValid(b) and IsValid(b:GetDriver()) then ridden[#ridden + 1] = b end
    end
    return BMX.FilmerNearest(pos, ridden, range)
end

function BMX.Filmers()
    local out = {}
    for _, e in ipairs(ents.GetAll()) do
        if IsValid(e) and e.IsBMXFilmer then out[#out + 1] = e end
    end
    return out
end

--------------------------------------------------------------------------
-- The view
--------------------------------------------------------------------------
local viewing = nil          -- the camera entity we are looking through
local track = {}
local lastSubject = nil

function BMX.FilmerViewing() return IsValid(viewing) end

concommand.Add("bmx_filmer_view", function()
    if IsValid(viewing) then viewing = nil return end
    local ply = LocalPlayer()
    local cam = BMX.FilmerNearest(ply:GetPos(), BMX.Filmers())
    if not cam then
        chat.AddText(Color(255, 214, 90), "[BMX] ",
            Color(255, 255, 255), "no filmer camera in this map (an admin can place one: Q menu > BMX)")
        return
    end
    viewing, track, lastSubject = cam, {}, nil
end)

hook.Add("CalcView", "BMX.FilmerView", function(ply, origin, angles, fov)
    if not IsValid(viewing) then return end
    local pos = viewing:GetPos() + Vector(0, 0, 6)
    local subject = BMX.FilmerNearestRider(pos, viewing.FollowRange or 3500)
    local at
    if subject then
        at = subject:GetPos() + Vector(0, 0, 30)
        lastSubject = at
    else
        at = lastSubject or (pos + viewing:GetForward() * 200)
    end
    local ang = BMX.FilmerTrack(track, BMX.FilmerAim(pos, at), FrameTime())
    return { origin = pos, angles = ang, fov = BMX.FilmerFov(pos:Distance(at)),
             drawviewer = true }
end)

hook.Add("HUDPaint", "BMX.FilmerTag", function()
    if not IsValid(viewing) then return end
    draw.SimpleText("FILMER CAM", "BMX.Small", 28, 24, Color(238, 105, 85),
        TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
end)
