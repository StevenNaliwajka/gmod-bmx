--[[--------------------------------------------------------------------------
    Finding somewhere to get air (sv_launch.lua).

    BMX.FindLaunch only ever asks two questions of the world -- what is the
    ground under this point, and can a hull get from here to there -- so these
    tests answer them from a made-up world: a height field and a list of
    walls. That lets every shape a map might have be put in front of it: a
    kicker it should use, and a quarter pipe, a kerb, a funbox, a blocked
    run-up and a jump into a pit it should not.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local function env()
    local sv = F.server()
    return sv.env, sv
end

-- A world: ground height as a function of (x, y), nil for a pit, and walls
-- as axis-aligned boxes that block a hull.
local function world(E, height, walls)
    walls = walls or {}
    local function trace(p)
        local z = height(p.x, p.y)
        if not z then return nil end
        return z, E.Vector(0, 0, 1), nil
    end
    local function segHitsBox(a, b, w)
        -- Sample the segment every few units, so a thin wall is not stepped over.
        local n = math.max(40, math.ceil((b - a):Length() / 5))
        for i = 0, n do
            local t = i / n
            local x, y, z = a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t
            if x >= w[1].x and x <= w[2].x and y >= w[1].y and y <= w[2].y and z <= w[2].z and z + 36 >= w[1].z then
                return true, t
            end
        end
        return false
    end
    local function clear(a, b)
        local first = 1
        for _, w in ipairs(walls) do
            local hit, t = segHitsBox(a, b, w)
            if hit and t < first then first = t end
        end
        return first >= 1, first
    end
    return { trace = trace, clear = clear }
end

-- Flat ground with one kicker along +x: foot at `at`, climbing `len` at
-- `deg`, dropping straight back to the ground past the lip.
local function kicker(at, len, deg, width)
    local tanA = math.tan(math.rad(deg))
    return function(x, y)
        if math.abs(y) > (width or 95) then return 0 end
        if x >= at and x <= at + len then return (x - at) * tanA end
        return 0
    end
end

T.test("launch: a kicker on flat ground is found, with its angle, height and lip", function()
    local E = env()
    local w = world(E, kicker(400, 160, 26))
    local l = E.BMX.FindLaunch(E.Vector(0, 0, 0), w)
    T.ok(l, "found it")
    T.near(math.deg(l.angle), 26, 3, "its angle, degrees")
    T.near(l.height, 160 * math.tan(math.rad(26)), 12, "its height")
    T.near(l.dir.x, 1, 1e-6, "it rises along +x")
    T.between(l.foot.x, 380, 420, "the foot")
    T.between(l.lip.x, 540, 565, "the lip")
end)

T.test("launch: a kicker off to the side is found pointing the right way", function()
    local E = env()
    local base = kicker(400, 160, 26)
    local w = world(E, function(x, y) return base(y, x) end)     -- rises along +y
    local l = E.BMX.FindLaunch(E.Vector(0, 0, 0), w)
    T.ok(l, "found it")
    T.near(l.dir.y, 1, 1e-6, "pointing along +y")
end)

T.test("launch: a quarter pipe is not a launch -- it sends you up, not over", function()
    local E = env()
    local w = world(E, function(x, y)
        if x >= 400 and x <= 520 then return (x - 400) * math.tan(math.rad(62)) end
        return 0
    end)
    T.eq(E.BMX.FindLaunch(E.Vector(0, 0, 0), w), nil, "62 degrees: refused")
end)

T.test("launch: a kerb is not a launch", function()
    local E = env()
    local w = world(E, kicker(400, 30, 20))
    T.eq(E.BMX.FindLaunch(E.Vector(0, 0, 0), w), nil, "11 u high: refused")
end)

T.test("launch: a slope with a flat top and no drop is a funbox deck, not a lip", function()
    local E = env()
    local tanA = math.tan(math.rad(25))
    local w = world(E, function(x, y)
        if x < 400 then return 0 end
        if x <= 560 then return (x - 400) * tanA end
        return 160 * tanA                                  -- a deck that goes on
    end)
    T.eq(E.BMX.FindLaunch(E.Vector(0, 0, 0), w), nil, "no lip: refused")
end)

T.test("launch: a kicker with a wall across its run-up is not used", function()
    local E = env()
    local w = world(E, kicker(400, 160, 26),
        { { E.Vector(150, -200, 0), E.Vector(170, 200, 200) } })
    local l = E.BMX.FindLaunch(E.Vector(0, 0, 0), w)
    T.ok(not l or l.dir.x < 0.99, "not that one: blocked run-up")
end)

T.test("launch: a kicker with a wall just past the lip is not used", function()
    local E = env()
    local w = world(E, kicker(400, 160, 26),
        { { E.Vector(700, -200, 0), E.Vector(720, 200, 400) } })
    local l = E.BMX.FindLaunch(E.Vector(0, 0, 0), w)
    T.ok(not l or l.dir.x < 0.99, "not that one: something in the way of the flight")
end)

T.test("launch: a kicker into a pit is not used", function()
    local E = env()
    local base = kicker(400, 160, 26)
    local w = world(E, function(x, y)
        if x > 600 and x < 1400 then return nil end
        return base(x, y)
    end)
    local l = E.BMX.FindLaunch(E.Vector(0, 0, 0), w)
    T.ok(not l or l.dir.x < 0.99, "not that one: nothing to land on")
end)

T.test("launch: of two kickers the taller one is chosen", function()
    local E = env()
    local small, big = kicker(400, 100, 20), kicker(400, 180, 30)
    local w = world(E, function(x, y)
        if x >= 0 then return small(x, y) end
        return big(-x, y)
    end)
    local l = E.BMX.FindLaunch(E.Vector(0, 0, 0), w)
    T.ok(l, "found one")
    T.near(l.dir.x, -1, 1e-6, "the 30-degree one, along -x")
end)

T.test("launch: flat ground everywhere has no launch", function()
    local E = env()
    T.eq(E.BMX.FindLaunch(E.Vector(0, 0, 0), world(E, function() return 0 end)), nil, "none")
end)

T.test("launch: the search reports how many slopes it looked at", function()
    local E = env()
    local _, n = E.BMX.FindLaunch(E.Vector(0, 0, 0), world(E, kicker(400, 160, 26)))
    T.ok(n >= 1, "at least the kicker: " .. n)
end)

--------------------------------------------------------------------------
-- Runway
--------------------------------------------------------------------------

T.test("runway: open flat ground is as long as asked", function()
    local E = env()
    local len = E.BMX.Launch.Runway(E.Vector(0, 0, 0), E.Vector(1, 0, 0), 1000, world(E, function() return 0 end))
    T.near(len, 1000, 1e-6, "all of it")
end)

T.test("runway: a wall ends it", function()
    local E = env()
    local w = world(E, function() return 0 end, { { E.Vector(300, -50, 0), E.Vector(320, 50, 100) } })
    local len = E.BMX.Launch.Runway(E.Vector(0, 0, 0), E.Vector(1, 0, 0), 1000, w)
    T.between(len, 270, 320, "up to the wall")
end)

T.test("runway: a pit ends it", function()
    local E = env()
    local w = world(E, function(x) if x > 500 then return nil end return 0 end)
    local len = E.BMX.Launch.Runway(E.Vector(0, 0, 0), E.Vector(1, 0, 0), 1000, w)
    T.between(len, 400, 500, "up to the edge")
end)

T.test("runway: a step up ends it, a gentle bump does not", function()
    local E = env()
    local step = world(E, function(x) if x > 400 then return 30 end return 0 end)
    T.between(E.BMX.Launch.Runway(E.Vector(0, 0, 0), E.Vector(1, 0, 0), 1000, step), 300, 400, "the step")
    local bump = world(E, function(x) return math.sin(x / 200) * 4 end)
    T.near(E.BMX.Launch.Runway(E.Vector(0, 0, 0), E.Vector(1, 0, 0), 1000, bump), 1000, 1e-6, "the bumps")
end)

T.test("runway: nothing under the start is no runway", function()
    local E = env()
    T.eq(E.BMX.Launch.Runway(E.Vector(0, 0, 0), E.Vector(1, 0, 0), 1000, world(E, function() return nil end)), 0, "none")
end)

--------------------------------------------------------------------------
-- The kicker the bot puts down
--------------------------------------------------------------------------

T.test("kicker: its riding surface starts at the foot and its lip is where the angle says", function()
    local E = env()
    local foot = E.Vector(100, 50, 0)
    local centre, ang, l = E.BMX.Launch.KickerGeometry(foot, 0, 189.8, 3.4, math.rad(30))
    T.near(l.height, 189.8 * 0.5, 1e-6, "lip height = L sin 30")
    T.near(l.lip.x - foot.x, 189.8 * math.cos(math.rad(30)), 1e-6, "lip along")
    T.near(ang.p, -30, 1e-9, "nose-up pitch")
    T.near(ang.y, 0, 1e-9, "facing the yaw given")
    -- The surface the plate presents: its centre plus half its thickness up
    -- its normal, minus half its length down its slope, is the foot.
    local f = ang:Forward()
    local u = ang:Up()
    local low = centre - f * (189.8 * 0.5) + u * (3.4 * 0.5)
    T.near((low - foot):Length(), 0, 0.05, "the top surface meets the ground at the foot")
end)

T.test("kicker: any heading", function()
    local E = env()
    local _, ang, l = E.BMX.Launch.KickerGeometry(E.Vector(0, 0, 0), 135, 189.8, 3.4, math.rad(30))
    T.near(ang.y, 135, 1e-9, "yaw")
    T.near(l.dir.x, math.cos(math.rad(135)), 1e-9, "dir x")
    T.near(l.dir.y, math.sin(math.rad(135)), 1e-9, "dir y")
    T.ok(l.lip.x < 0 and l.lip.y > 0, "the lip out that way")
end)

T.test("kicker: SpawnKicker puts down a frozen PHX plate, tilted", function()
    local E = env()
    local e, l = E.BMX.SpawnKicker(E.Vector(0, 0, 0), 90)
    T.ok(E.IsValid(e), "a prop")
    T.eq(e:GetModel(), "models/hunter/plates/plate8x8.mdl", "the base-game plate")
    T.ok(e.BMXKicker, "marked as the bot's")
    T.near(e:GetAngles().p, -14, 1e-6, "tilted to kickerAngle")
    T.ok(l.spawned, "described as a launch")
    T.eq(#l.plates, 2, "two plates end to end")
    T.ok(l.plates[1] == e, "the first one returned")
    T.near(l.height, 2 * 379.6 * math.sin(math.rad(14)), 1e-6, "one slope, twice as high as one plate")
    local p1, p2 = l.plates[1]:GetPos(), l.plates[2]:GetPos()
    T.near(math.deg(math.atan2(p2.z - p1.z, p2.y - p1.y)), 14, 1e-6, "the second plate carries on the first's slope")
    T.near(l.dir.y, 1, 1e-9, "rising along the yaw")
end)

T.test("kicker: planned on the side with room, not into a wall", function()
    local E = env()
    -- Walls on every side but +y.
    local walls = {
        { E.Vector(200, -3000, 0), E.Vector(220, 3000, 300) },
        { E.Vector(-220, -3000, 0), E.Vector(-200, 3000, 300) },
        { E.Vector(-3000, -220, 0), E.Vector(3000, -200, 300) },
    }
    local foot, yaw = E.BMX.Launch.PlanKicker(E.Vector(0, 0, 0), world(E, function() return 0 end, walls))
    T.ok(foot, "somewhere")
    T.near(math.abs(math.AngleDifference(yaw, 90)), 0, 1e-6, "toward the open side")
end)

T.test("kicker: boxed in, nowhere is planned", function()
    local E = env()
    local walls = {
        { E.Vector(200, -3000, 0), E.Vector(220, 3000, 300) },
        { E.Vector(-220, -3000, 0), E.Vector(-200, 3000, 300) },
        { E.Vector(-3000, -220, 0), E.Vector(3000, -200, 300) },
        { E.Vector(-3000, 200, 0), E.Vector(3000, 220, 300) },
    }
    T.eq(E.BMX.Launch.PlanKicker(E.Vector(0, 0, 0), world(E, function() return 0 end, walls)), nil, "no room")
end)

T.test("kicker: the finder recognises the bot's own kicker shape", function()
    local E = env()
    local _, _, l = E.BMX.Launch.KickerGeometry(E.Vector(400, 0, 0), 0, 189.8, 3.4, math.rad(30))
    local w = world(E, kicker(400, l.length, 30))
    local found = E.BMX.FindLaunch(E.Vector(0, 0, 0), w)
    T.ok(found, "found")
    T.near(found.height, l.height, 12, "the same height")
end)

--------------------------------------------------------------------------
-- Flying the jump (L.Flight): what a launch is judged by
--------------------------------------------------------------------------

T.test("flight: off a lip over flat ground, the arc's air time is the ballistics'", function()
    local E = env()
    local C = E.BMX.Launch.Config
    local w = world(E, function() return 0 end)
    local l = { lip = E.Vector(0, 0, 100), dir = E.Vector(1, 0, 0) }
    local f = E.BMX.Launch.Flight(l, C, w)
    T.ok(f, "it comes down")
    local vz, h = C.flightVz, 100
    local t = (vz + math.sqrt(vz * vz + 2 * 600 * h)) / 600
    T.near(f.t, t, 0.07, "air time, s")
    T.near(f.at.x, C.flightSpeed * t, 25, "lands where the arc says")
end)

T.test("flight: a landing ramp past a kicker is a landing, not something in the way", function()
    local E = env()
    local tanUp, tanDown = math.tan(math.rad(24)), math.tan(math.rad(20))
    -- Kicker 400-560 up to 71 u, a gap, then a landing deck from 760 sloping
    -- down from 60 u back to the ground: a funbox with a gap.
    local w = world(E, function(x, y)
        if math.abs(y) > 200 then return 0 end
        if x >= 400 and x <= 560 then return (x - 400) * tanUp end
        if x >= 760 and x <= 760 + 60 / tanDown then return 60 - (x - 760) * tanDown end
        return 0
    end)
    local l = E.BMX.FindLaunch(E.Vector(0, 0, 0), w)
    T.ok(l, "found, with the landing ramp in its flight")
    T.ok(l and l.airTime and l.airTime > 0.9, "and enough air: " .. tostring(l and l.airTime))
end)

T.test("flight: a kicker too small for a trick's air is refused, and says so", function()
    local E = env()
    local C = setmetatable({ minAir = 1.6 }, { __index = E.BMX.Launch.Config })
    local w = world(E, kicker(400, 160, 26))
    local l, n, why = E.BMX.FindLaunch(E.Vector(0, 0, 0), { trace = w.trace, clear = w.clear, config = C })
    T.eq(l, nil, "refused")
    T.ok(why:find("of air", 1, true), "why: " .. why)
end)

T.test("flight: coming down onto a ledge face is landing on a wall", function()
    local E = env()
    local base = kicker(400, 160, 26)
    local w = world(E, base, { { E.Vector(800, -300, 0), E.Vector(820, 300, 120) } })
    local l, n, why = E.BMX.FindLaunch(E.Vector(0, 0, 0), w)
    T.ok(not l or l.dir.x < 0.99, "not that way")
end)

T.test("plan kicker: not where the jump would come down in a hole", function()
    local E = env()
    -- Open everywhere, but along +x there is a pit where a kicker's jump lands.
    local w = world(E, function(x, y)
        if y > -150 and y < 150 and x > 1700 and x < 2400 then return -400 end
        return 0
    end)
    local foot, yaw = E.BMX.Launch.PlanKicker(E.Vector(0, 0, 0), w)
    T.ok(foot, "somewhere")
    T.ok(math.abs(math.AngleDifference(yaw, 0)) > 1, "but not toward the pit: " .. tostring(yaw))
end)

T.test("flight: the launch table carries the air time and where it lands", function()
    local E = env()
    local l = E.BMX.FindLaunch(E.Vector(0, 0, 0), world(E, kicker(400, 160, 26)))
    T.ok(l and l.airTime and l.landAt, "both")
    T.ok(l.landAt.x > l.lip.x, "beyond the lip")
end)

T.test("flight: a hull swept into the floor on the last slice is a landing, not a wall", function()
    local E = env()
    local C = E.BMX.Launch.Config
    -- A clear() that reports the floor as a hit with an upward normal, as
    -- the engine's hull trace does when a slice ends below the ground.
    local function trace(p) return 0, E.Vector(0, 0, 1) end
    local function clear(a, b)
        if b.z < 0 then return false, a.z / (a.z - b.z), E.Vector(0, 0, 1) end
        return true, 1
    end
    local f = E.BMX.Launch.Flight({ lip = E.Vector(0, 0, 100), dir = E.Vector(1, 0, 0) }, C, { trace = trace, clear = clear })
    T.ok(f and not f.wall, "landed")
end)

T.test("flight: a face hit on the way is a wall", function()
    local E = env()
    local C = E.BMX.Launch.Config
    local function trace(p) return 0, E.Vector(0, 0, 1) end
    local function clear(a, b)
        if b.x > 200 then return false, 0.5, E.Vector(-1, 0, 0) end
        return true, 1
    end
    local f = E.BMX.Launch.Flight({ lip = E.Vector(0, 0, 100), dir = E.Vector(1, 0, 0) }, C, { trace = trace, clear = clear })
    T.ok(f and f.wall, "a wall")
end)
