--[[--------------------------------------------------------------------------
    bmx/sv_launch.lua

    Somewhere to get air: find a ramp in the world, or put one down.

    An air trick needs more air than a bunny hop gives. A flip is a full turn
    of the bike, and the air controls (C.Air) spin it at most ~18 rad/s tucked,
    which takes about 0.9 s of flight; a hop off flat ground is ~0.75 s. So a
    rider -- or the bot (sv_bot.lua) -- needs a LAUNCH: a slope that ends in a
    lip, ridden at speed and hopped off the top.

    BMX.FindLaunch looks for one in the world as it is, by tracing the ground
    around a point: a run of surface that climbs at 12-40 degrees, ends at a
    lip that drops away, has flat clear ground to ride at it from, and open
    ground beyond to come down on. It does not care what the slope is -- a map
    brush, a skatepark kicker, a prop somebody tilted -- only its shape, which
    is what a rider cares about too. A quarter pipe is steeper than 40 and is
    not a launch: it sends you straight up, not over.

    BMX.SpawnKicker puts one down where the world has none: a frozen PHX plate
    from base Garry's Mod, tilted. No content, nothing to mount.

    Every trace here goes through `opts.trace` when a caller gives one, so the
    geometry can be tested without a world (tests/test_launch.lua).
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Launch = BMX.Launch or {}
local L = BMX.Launch

L.Config = {
    headings   = 24,        -- directions searched
    step       = 20,        -- u between ground samples along one
    reach      = 1100,      -- u searched out from the origin
    minSlope   = math.rad(12),
    maxSlope   = math.rad(40),
    minRampLen = 50,        -- u of slope at least: a kerb is not a ramp
    minHeight  = 25,        -- u the lip must stand above the ramp's foot
    lipDrop    = 12,        -- u the ground must fall just past the lip
    runup      = 420,       -- u of flat, clear ground needed before the foot
    landing    = 500,       -- u past the lip that must be open to fly through
    flatTol    = 4,         -- u of rise per sample still counted as flat
    kickerModel = "models/hunter/plates/plate4x4.mdl",
    kickerAngle = math.rad(30),
}

local UP = Vector(0, 0, 1)

-- The ground under a point: z and normal, or nil over a pit.
local function defaultTrace(p, filter)
    local tr = util.TraceLine({
        start = p + UP * 400, endpos = p - UP * 1200,
        filter = filter, mask = MASK_SOLID,
    })
    if not tr.Hit or tr.StartSolid then return nil end
    return tr.HitPos.z, tr.HitNormal, tr.Entity
end

local function defaultClear(a, b, filter)
    local tr = util.TraceHull({
        start = a, endpos = b, mins = Vector(-14, -14, 0), maxs = Vector(14, 14, 36),
        filter = filter, mask = MASK_SOLID,
    })
    return not tr.Hit, tr.Fraction
end

local function dirOf(yaw)
    local r = math.rad(yaw)
    return Vector(math.cos(r), math.sin(r), 0)
end
L.DirOf = dirOf

--------------------------------------------------------------------------
-- How far a rider could go from `from` along `dir`: clear of walls and with
-- ground under every sample (no pits, no cliff). The cheap question the bot
-- asks before it picks a direction to do anything in.
--------------------------------------------------------------------------
function L.Runway(from, dir, maxLen, opts)
    opts = opts or {}
    local trace, clear = opts.trace or defaultTrace, opts.clear or defaultClear
    local z0 = select(1, trace(from, opts.filter))
    if not z0 then return 0 end
    local ok, frac = clear(Vector(from.x, from.y, z0 + 8), Vector(from.x, from.y, z0 + 8) + dir * maxLen, opts.filter)
    local len = ok and maxLen or maxLen * frac
    local d, step, last = 0, 60, z0
    while d <= len do
        local z = select(1, trace(from + dir * d, opts.filter))
        if not z or math.abs(z - last) > 10 then return math.max(d - step, 0) end
        last = z
        d = d + step
    end
    return len
end

--------------------------------------------------------------------------
-- The ground profile along one heading: z, normal and entity at every step.
--------------------------------------------------------------------------
local function profile(origin, dir, C, opts)
    local trace = opts.trace or defaultTrace
    local out = {}
    for i = 0, math.floor(C.reach / C.step) do
        local p = origin + dir * (i * C.step)
        local z, n, e = trace(p, opts.filter)
        out[#out + 1] = { d = i * C.step, z = z, n = n, e = e }
    end
    return out
end

-- Every launch along one profile: a flat run-in, a climb, a lip that drops.
local function launchesIn(prof, origin, dir, yaw, C, opts)
    local found = {}
    local tanMin, tanMax = math.tan(C.minSlope), math.tan(C.maxSlope)
    local i = 2
    while i < #prof do
        local a, b = prof[i - 1], prof[i]
        local rise = (a.z and b.z) and (b.z - a.z) / C.step or nil
        if rise and rise >= tanMin and rise <= tanMax then
            -- The climb starts at a; follow it while it keeps climbing.
            local foot, j = i - 1, i
            while j + 1 <= #prof and prof[j + 1].z and
                  (prof[j + 1].z - prof[j].z) / C.step >= tanMin * 0.6 and
                  (prof[j + 1].z - prof[j].z) / C.step <= tanMax * 1.3 do
                j = j + 1
            end
            local top = j
            local nextZ = prof[top + 1] and prof[top + 1].z
            local len = prof[top].d - prof[foot].d
            local height = prof[top].z - prof[foot].z
            local drops = (nextZ == nil) or (prof[top].z - nextZ >= C.lipDrop)
            if len >= C.minRampLen and height >= C.minHeight and drops then
                found[#found + 1] = {
                    foot   = origin + dir * prof[foot].d + UP * (prof[foot].z - origin.z),
                    lip    = origin + dir * prof[top].d + UP * (prof[top].z - origin.z),
                    dir    = dir, yaw = yaw,
                    angle  = math.atan(height / len),
                    height = height, length = len,
                    entity = prof[top].e,
                }
            end
            i = top + 1
        else
            i = i + 1
        end
    end
    return found
end

-- Can this launch be used: flat clear ground to ride at it, open air past it?
local function usable(l, C, opts)
    local trace, clear = opts.trace or defaultTrace, opts.clear or defaultClear
    -- The run-up, back from the foot: flat and clear for C.runup.
    local back = -l.dir
    local footZ = l.foot.z
    for d = C.step, C.runup, 40 do
        local z = select(1, trace(l.foot + back * d, opts.filter))
        if not z or math.abs(z - footZ) > C.flatTol * 3 then return false, "no flat run-up" end
    end
    local a = Vector(l.foot.x, l.foot.y, footZ + 8)
    if not clear(a + back * C.runup, a, opts.filter) then return false, "run-up blocked" end
    -- The flight: from just over the lip, out and a little up, must be open.
    local lip = l.lip + UP * 12
    if not clear(lip + l.dir * 8, lip + l.dir * C.landing + UP * 30, opts.filter) then
        return false, "something in the way past the lip"
    end
    -- And there is ground to land on, not a pit, within reach of the jump.
    local z = select(1, trace(l.lip + l.dir * C.landing * 0.8, opts.filter))
    if not z or l.lip.z - z > 600 then return false, "nothing to land on" end
    l.landZ = z
    return true
end

--------------------------------------------------------------------------
-- Find the best launch near `origin`. Returns the launch table or nil, and
-- the number of candidates considered (for the bot's log line).
--
--   opts.trace(p, filter)   -> z, normal, entity   ground under p, or nil
--   opts.clear(a, b, filter) -> bool, fraction     a hull can travel a -> b
--   opts.filter             entities the traces ignore (the bike, the rider)
--------------------------------------------------------------------------
function L.Find(origin, opts)
    opts = opts or {}
    local C = opts.config or L.Config
    local best, bestScore, n = nil, -math.huge, 0
    for h = 0, C.headings - 1 do
        local yaw = h * 360 / C.headings
        local dir = dirOf(yaw)
        for _, l in ipairs(launchesIn(profile(origin, dir, C, opts), origin, dir, yaw, C, opts)) do
            n = n + 1
            if usable(l, C, opts) then
                -- Taller is more air; nearer is less riding to get there.
                local score = l.height * 2 - (l.foot - origin):Length() * 0.05
                if score > bestScore then best, bestScore = l, score end
            end
        end
    end
    return best, n
end
BMX.FindLaunch = L.Find

--------------------------------------------------------------------------
-- Put a kicker down: a PHX plate, frozen, tilted to C.kickerAngle, its low
-- edge at `foot`, rising along `yaw`. Returns the prop and the launch table
-- describing it (the same shape BMX.FindLaunch returns).
--------------------------------------------------------------------------
function L.KickerGeometry(foot, yaw, length, thickness, angle)
    local dir = dirOf(yaw)
    local c, s = math.cos(angle), math.sin(angle)
    -- The plate's centre: half its length up the slope from the foot, lifted
    -- by half its thickness along the slope's normal so the riding surface,
    -- not the plate's middle, starts at the foot.
    local normal = UP * c - dir * s
    local centre = foot + dir * (length * 0.5 * c) + UP * (length * 0.5 * s) + normal * (thickness * 0.5)
    local lip = foot + dir * (length * c) + UP * (length * s)
    return centre, Angle(-math.deg(angle), yaw, 0), {
        foot = foot, lip = lip, dir = dir, yaw = yaw, angle = angle,
        height = length * s, length = length * c, spawned = true,
    }
end

function L.SpawnKicker(foot, yaw, opts)
    opts = opts or {}
    local C = opts.config or L.Config
    local e = ents.Create("prop_physics")
    if not IsValid(e) then return nil end
    e:SetModel(C.kickerModel)
    e:Spawn()
    local mn, mx = e:OBBMins(), e:OBBMaxs()
    local length = math.max(mx.x - mn.x, mx.y - mn.y)
    local thick = mx.z - mn.z
    local centre, ang, launch = L.KickerGeometry(foot, yaw, length, thick, opts.angle or C.kickerAngle)
    e:SetPos(centre)
    e:SetAngles(ang)
    local p = e:GetPhysicsObject()
    if IsValid(p) then p:EnableMotion(false) end
    e.BMXKicker = true
    launch.entity = e
    return e, launch
end
BMX.SpawnKicker = L.SpawnKicker

-- Where to put a kicker near `origin`: the heading with the longest runway,
-- far enough out that there is room to get up to speed before it.
function L.PlanKicker(origin, opts)
    opts = opts or {}
    local C = opts.config or L.Config
    local need = C.runup + 200 + C.landing + 300
    local bestYaw, bestLen = nil, 0
    for h = 0, C.headings - 1 do
        local yaw = h * 360 / C.headings
        local len = L.Runway(origin, dirOf(yaw), need + 200, opts)
        if len > bestLen then bestYaw, bestLen = yaw, len end
    end
    if not bestYaw or bestLen < need * 0.75 then return nil, bestLen end
    local z = select(1, (opts.trace or defaultTrace)(origin, opts.filter)) or origin.z
    local foot = Vector(origin.x, origin.y, z) + dirOf(bestYaw) * C.runup
    return foot, bestYaw, bestLen
end
