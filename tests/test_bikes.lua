--[[--------------------------------------------------------------------------
    The shipped bikes (sh_bikes.lua): stock, cruiser and mini.

    The two extra bikes are the stock bike with other geometry and nothing
    else, so what is tested here is that "nothing else" holds: each registers,
    spawns built, sits on its own wheels, rides, steers the right way, hops,
    grinds-and-combos like the stock bike, and is drawn at its own size. The
    headless suite runs the riding cases again on each (T.Variant); these are
    the same questions asked of the shim's plant, on every commit.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local SHIPPED = { "stock", "cruiser", "mini" }
local EXTRA   = { "cruiser", "mini" }

local function classOf(sv, id) return sv.env.BMX.ClassFor(id) end

-- A ridden bike of the given kind, settled, with a scripted rider.
local function ridden(id)
    local sv, world = F.server()
    local cfg = sv.env.BMX.ConfigFor(sv.env.BMX.Bikes[id])
    local pos = sv.env.Vector(0, 0, sv.world.groundZ + sv.env.BMX.RestHeight(cfg))
    local bike = F.bike(sv, classOf(sv, id), pos)
    local ply = F.scripted(sv, bike)
    sv:run(0.5)
    return sv, bike, ply, world
end

local function topSpeed(id)
    local sv, bike = ridden(id)
    F.input(bike, { throttle = 1 })
    local peak = 0
    sv:run(20, function() peak = math.max(peak, bike.st.speed) return false end)
    return peak, bike, sv
end

--------------------------------------------------------------------------
-- The registry
--------------------------------------------------------------------------

T.test("bikes: the BMXs and the road bike are registered, with their own classes", function()
    local sv = F.server()
    local B = sv.env.BMX
    local ids = B.BikeIDs()
    T.eq(table.concat(ids, ","), "city,cruiser,dh,fixie,mini,penny,road,stock,tandem,unicycle", "the shipped bikes, sorted")
    T.eq(B.ClassFor("cruiser"), "bmx_cruiser", "cruiser class")
    T.eq(B.ClassFor("mini"), "bmx_mini", "mini class")
    T.eq(B.ClassFor("CRUISER"), "bmx_cruiser", "ids are case-insensitive")
    T.eq(#sv.errors, 0, "nothing in the registry was rejected: " .. table.concat(sv.errors, " | "))
end)

T.test("bikes: each is a real scripted entity, derived from bmx_base", function()
    local sv = F.server()
    local E = sv.env
    for _, id in ipairs(EXTRA) do
        local stored = E.scripted_ents.GetStored("bmx_" .. id)
        T.ok(stored, id .. " is registered with scripted_ents")
        local t = stored and (stored.t or stored)
        T.eq(t.Base, "bmx_base", id .. " derives from bmx_base")
        T.eq(t.BikeID, id, id .. " knows which bike it is")
    end
end)

T.test("bikes: each is in the spawn menu under BMX, with a name and a description", function()
    local sv = F.server()
    local E = sv.env
    for _, id in ipairs(SHIPPED) do
        local cls = classOf(sv, id)
        local row = E.list.Get("SpawnableEntities")[cls]
        T.ok(row, id .. " is in the spawn menu")
        T.eq(row.Category, "BMX", id .. " category")
        T.ok(#row.PrintName > 0, id .. " has a name")
        T.ok(#row.Information > 0, id .. " has a description")
    end
    local names = {}
    for _, id in ipairs(SHIPPED) do names[E.list.Get("SpawnableEntities")[classOf(sv, id)].PrintName] = true end
    T.ok(names["BMX"] and names["BMX Cruiser"] and names["Mini BMX"], "three different names")
end)

T.test("bikes: each can be duplicated", function()
    local sv = F.server()
    for _, id in ipairs(SHIPPED) do
        T.ok(sv.dupe[classOf(sv, id)], "the duplicator knows " .. id)
    end
end)

--------------------------------------------------------------------------
-- The geometry they were given
--------------------------------------------------------------------------

T.test("bikes: the cruiser is bigger and heavier, the mini smaller and lighter", function()
    local sv = F.server()
    local B = sv.env.BMX
    local s, c, m = B.ConfigFor(B.Bikes.stock), B.ConfigFor(B.Bikes.cruiser), B.ConfigFor(B.Bikes.mini)
    T.ok(c.Wheel.radius > s.Wheel.radius and s.Wheel.radius > m.Wheel.radius, "wheel radius ordered")
    T.ok(c.Wheel.wheelbase > s.Wheel.wheelbase and s.Wheel.wheelbase > m.Wheel.wheelbase, "wheelbase ordered")
    T.ok(c.Chassis.mass > s.Chassis.mass and s.Chassis.mass > m.Chassis.mass, "mass ordered")
    T.eq(c.Wheel.radius * 2, 24, "a 24-inch cruiser")
    T.eq(m.Wheel.radius * 2, 16, "a 16-inch mini")
    T.ok(s == B.Config, "the stock bike still shares the base by reference")
end)

T.test("bikes: each seat is scaled with its frame (wheelbase / 39)", function()
    local sv = F.server()
    local B = sv.env.BMX
    local stock = B.Config.Chassis.seatOffset
    for _, id in ipairs(EXTRA) do
        local cfg = B.ConfigFor(B.Bikes[id])
        local k = cfg.Wheel.wheelbase / 39
        T.near(cfg.Chassis.seatOffset.x, stock.x * k, 0.1, id .. " seat x")
        T.near(cfg.Chassis.seatOffset.z, stock.z * k, 0.1, id .. " seat z")
        T.eq(cfg.Chassis.seatOffset.y, 0, id .. " seat on the centre line")
    end
end)

T.test("bikes: each hull puts the mass centre where the balance maths expects it", function()
    local sv = F.server()
    local B = sv.env.BMX
    for _, id in ipairs(SHIPPED) do
        local cfg = B.ConfigFor(B.Bikes[id])
        local sumV, sum = 0, sv.env.Vector(0, 0, 0)
        for _, b in ipairs(B.CollisionBoxes(cfg)) do
            local d = b[2] - b[1]
            local v = d.x * d.y * d.z
            sumV = sumV + v
            sum = sum + (b[1] + b[2]) * 0.5 * v
        end
        local com = sum / sumV
        T.near((com - cfg.Chassis.massCenterExpected):Length(), 0, 0.01, id .. " volume centre")
    end
end)

T.test("bikes: each wheel box reaches its own wheel, not the stock one's", function()
    local sv = F.server()
    local B = sv.env.BMX
    for _, id in ipairs(SHIPPED) do
        local cfg = B.ConfigFor(B.Bikes[id])
        local half, r = cfg.Wheel.wheelbase * 0.5, cfg.Wheel.radius
        local mn, mx = B.CollisionBounds(cfg)
        T.near(mx.x, half + r, 0.01, id .. " front of the front wheel")
        T.near(mn.x, -half - r, 0.01, id .. " back of the rear wheel")
    end
end)

T.test("bikes: each has every config group, Grind and Combo included", function()
    local sv = F.server()
    local B = sv.env.BMX
    for _, id in ipairs(SHIPPED) do
        local cfg = B.ConfigFor(B.Bikes[id])
        for _, g in ipairs(B.ConfigGroups) do
            T.ok(type(cfg[g]) == "table", id .. " has " .. g)
        end
    end
end)

--------------------------------------------------------------------------
-- Spawned and ridden
--------------------------------------------------------------------------

T.test("bikes: each spawns fully built, with its own mass and wheel mounts", function()
    for _, id in ipairs(SHIPPED) do
        local sv = F.server()
        local e = F.bike(sv, classOf(sv, id))
        local cfg = e:Cfg()
        T.ok(e:AssertBuilt(), id .. " is fully built")
        T.eq(e:GetPhysicsObject():GetMass(), cfg.Chassis.mass, id .. " mass")
        local f, r = F.wheels(e)
        T.near(f.mount.x - r.mount.x, cfg.Wheel.wheelbase, 1e-9, id .. " wheelbase")
        T.ok(sv.env.IsValid(e:GetPod()), id .. " has a seat")
        T.eq(#sv.errors, 0, id .. " spawned without errors: " .. table.concat(sv.errors, " | "))
    end
end)

T.test("bikes: each seat is where its config puts it", function()
    for _, id in ipairs(SHIPPED) do
        local sv = F.server()
        local e = F.bike(sv, classOf(sv, id))
        local want = e:LocalToWorld(e:Cfg().Chassis.seatOffset)
        T.near((e:GetPod():GetPos() - want):Length(), 0, 0.01, id .. " seat position")
    end
end)

T.test("bikes: each settles on both wheels at its own ride height", function()
    for _, id in ipairs(SHIPPED) do
        local sv, bike = ridden(id)
        local cfg = bike:Cfg()
        local f, r = F.wheels(bike)
        T.ok(f.onGround and r.onGround, id .. ": both wheels down")
        local weight = cfg.Chassis.mass * 600
        T.between((f.load + r.load) / weight, 0.9, 1.1, id .. ": suspension carries the weight")
        local want = sv.world.groundZ + sv.env.BMX.RestHeight(cfg)
        T.between(bike:GetPos().z, want - 1, want + 1, id .. ": ride height")
        T.ok(math.abs(bike.st.roll) < math.rad(10), id .. ": upright")
        T.eq(#sv.errors, 0, id .. ": no errors " .. table.concat(sv.errors, " | "))
    end
end)

T.test("bikes: the spawned bikes sit at different heights, as their wheels say", function()
    local h = {}
    for _, id in ipairs(SHIPPED) do
        local sv, bike = ridden(id)
        h[id] = bike:GetPos().z - sv.world.groundZ
    end
    T.ok(h.cruiser > h.stock + 1, "cruiser sits higher than stock")
    T.ok(h.mini < h.stock - 1, "mini sits lower than stock")
end)

T.test("bikes: top speed follows wheel size (mini < stock < cruiser), capped by cadence", function()
    local peaks = {}
    for _, id in ipairs(SHIPPED) do
        local peak, bike = topSpeed(id)
        peaks[id] = peak
        T.between(bike.st.cadence / bike:Cfg().Drive.maxCadence, 0.8, 1.02,
            id .. ": cadence, not drag, is the limit")
        local _, r = F.wheels(bike)
        T.ok(r.onGround, id .. ": still driving on the ground")
    end
    T.ok(peaks.mini < peaks.stock and peaks.stock < peaks.cruiser,
        string.format("ordered: mini %.0f, stock %.0f, cruiser %.0f", peaks.mini, peaks.stock, peaks.cruiser))
    -- v = cadence * gear * radius, so the ratio is the radius ratio.
    T.between(peaks.cruiser / peaks.stock, 1.1, 1.3, "cruiser / stock ~ 12/10")
    T.between(peaks.mini / peaks.stock, 0.7, 0.9, "mini / stock ~ 8/10")
end)

T.test("bikes: the cruiser is slower off the line than the stock bike, the mini quicker", function()
    local t = {}
    for _, id in ipairs(SHIPPED) do
        local sv, bike = ridden(id)
        F.input(bike, { throttle = 1 })
        local t0 = sv.world.time
        sv:run(10, function() return bike.st.speed >= 150 end)
        t[id] = sv.world.time - t0
        T.ok(bike.st.speed >= 150, id .. " reached 150 u/s")
    end
    T.ok(t.cruiser > t.stock, string.format("cruiser %.2fs > stock %.2fs to 150", t.cruiser, t.stock))
    T.ok(t.mini < t.stock, string.format("mini %.2fs < stock %.2fs to 150", t.mini, t.stock))
end)

local function sweep(id, lean)
    local sv, bike = ridden(id)
    F.accelerateTo(sv, bike, 150)
    local E = sv.env
    local last, total = bike:GetAngles().y, 0
    F.input(bike, { throttle = 0.6, lean = lean })
    sv:run(2.5, function()
        local y = bike:GetAngles().y
        total = total + E.math.AngleDifference(y, last)
        last = y
        return false
    end)
    return total, bike
end

for _, id in ipairs(EXTRA) do
    T.test("bikes: the " .. id .. " leans right to turn right, left to turn left", function()
        local right, rb = sweep(id, 1)
        local left, lb = sweep(id, -1)
        T.ok(rb.st.roll > math.rad(8) and rb.st.steer > 0, "right lean, right steer")
        T.ok(right < -30, "turns right: " .. right)
        T.ok(lb.st.roll < -math.rad(8) and lb.st.steer < 0, "left lean, left steer")
        T.ok(left > 30, "turns left: " .. left)
        T.between(math.abs(left) / math.abs(right), 0.8, 1.25, "symmetric")
    end)

    T.test("bikes: the " .. id .. " holds a commanded lean within 12 degrees", function()
        local sv, bike = ridden(id)
        F.accelerateTo(sv, bike, 150)
        F.input(bike, { throttle = 0.7, lean = 0.6 })
        sv:run(2.5)
        local target = 0.6 * bike:Cfg().Balance.maxLean
        T.between(math.deg(math.abs(target - bike.st.roll)), 0, 12, "|target - roll|, deg")
    end)

    T.test("bikes: the " .. id .. " hops and lands on its wheels", function()
        local sv, bike = ridden(id)
        F.accelerateTo(sv, bike, 160)
        F.input(bike, { throttle = 0.5 })
        local z0 = bike:GetPos().z
        bike.hopHeld, bike.hopCharge = true, 0
        sv:run(bike:Cfg().Hop.chargeTime + 0.05)
        bike.hopRelease = true
        local peak, airborne = 0, false
        local f, r = F.wheels(bike)
        sv:run(1.6, function()
            peak = math.max(peak, bike:GetPos().z - z0)
            if not f.onGround and not r.onGround then airborne = true end
            return false
        end)
        T.ok(airborne, "both wheels left the ground")
        T.between(peak, 18, 100, "hop height")
        T.ok(bike.st.grounded, "and landed")
        T.ok(sv.env.IsValid(bike:GetDriver()), "without a crash")
    end)

    T.test("bikes: the " .. id .. " brakes to a stop", function()
        local sv, bike = ridden(id)
        F.accelerateTo(sv, bike, 200)
        F.input(bike, { brakeRear = 1, brakeFront = 0.5 })
        sv:run(4, function() return bike.st.speed < 5 end)
        T.ok(bike.st.speed < 5, "stopped: " .. bike.st.speed)
        T.ok(sv.env.IsValid(bike:GetDriver()), "still on it")
    end)

    T.test("bikes: the " .. id .. " scores and banks a combo", function()
        local sv, bike = ridden(id)
        local s0 = bike:GetScore()
        bike:AwardTricks({ { name = "Backflip", count = 1, points = 500 } })
        bike:AwardTricks({ { name = "Crank Grind", count = 1, points = 140 } })
        sv:run(1.5)
        T.eq(bike:GetScore(), s0 + 640 * 2, "tricks plus a x2 combo bonus")
    end)

    T.test("bikes: the " .. id .. " finds a grind point on its own geometry", function()
        local sv = F.server()
        local B = sv.env.BMX
        local cfg = B.ConfigFor(B.Bikes[id])
        local p = B.GrindCrankPoint(cfg)
        T.ok(p, "a crank point")
        T.ok(math.abs(p.x) < cfg.Wheel.wheelbase * 0.5, "between the axles")
        T.ok(p.z < cfg.Chassis.massCenterExpected.z, "below the mass centre")
    end)
end

T.test("bikes: a riderless cruiser and mini park on their stands", function()
    for _, id in ipairs(EXTRA) do
        local sv = F.server()
        local cfg = sv.env.BMX.ConfigFor(sv.env.BMX.Bikes[id])
        local pos = sv.env.Vector(0, 0, sv.world.groundZ + sv.env.BMX.RestHeight(cfg))
        local bike = F.bike(sv, classOf(sv, id), pos)
        sv:run(2)
        T.ok(math.abs(bike.st.roll) < bike:Cfg().Stand.maxRoll, id .. " is standing, not fallen")
        T.ok(bike.st.roll < 0, id .. " leans onto its stand (left)")
    end
end)

T.test("bikes: all three on one server at once, without touching each other's numbers", function()
    local sv = F.server()
    local E, B = sv.env, sv.env.BMX
    local made = {}
    for i, id in ipairs(SHIPPED) do
        local cfg = B.ConfigFor(B.Bikes[id])
        made[id] = F.bike(sv, classOf(sv, id), E.Vector(0, (i - 2) * 150, sv.world.groundZ + B.RestHeight(cfg)))
    end
    sv:run(1)
    T.eq(made.stock:Cfg().Wheel.radius, 10, "stock radius")
    T.eq(made.cruiser:Cfg().Wheel.radius, 12, "cruiser radius")
    T.eq(made.mini:Cfg().Wheel.radius, 8, "mini radius")
    T.eq(B.Config.Wheel.radius, 10, "the base is untouched")
    T.eq(#sv.errors, 0, "no errors: " .. table.concat(sv.errors, " | "))
end)

--------------------------------------------------------------------------
-- Spawning by name
--------------------------------------------------------------------------

local function looker(sv, name)
    local E = sv.env
    local ply = sv:player(name or "Spawner")
    ply:SetPos(E.Vector(0, 0, 0))
    ply._eyeTrace = { Hit = true, HitPos = E.Vector(100, 0, 0), HitNormal = E.Vector(0, 0, 1) }
    return ply
end

for _, id in ipairs(EXTRA) do
    T.test("bikes: bmx_spawn " .. id .. " spawns that bike, at its own rest height", function()
        local sv = F.server()
        local ply = looker(sv)
        sv:command("bmx_spawn", ply, id)
        local found = sv.env.ents.FindByClass("bmx_" .. id)
        T.eq(#found, 1, "one " .. id)
        local e = found[1]
        T.near(e:GetPos().z, sv.env.BMX.RestHeight(e:Cfg()) + 0.5, 0.01, "placed at rest, not dropped")
    end)
end

T.test("bikes: a fresh bike starts in its own colour when its spawner has no preference", function()
    for _, id in ipairs(SHIPPED) do
        local sv = F.server()
        local e = F.bike(sv, classOf(sv, id))
        T.eq(e:GetColorIndex(), sv.env.BMX.Bikes[id].colorIndex, id .. " colour")
    end
end)

T.test("bikes: an unknown bike name lists them all", function()
    local sv = F.server()
    local ply = looker(sv)
    sv:command("bmx_spawn", ply, "monowheel")
    local said = table.concat(ply._chat, "\n")
    T.ok(said:find("city, cruiser, dh, fixie, mini, penny, road, stock, tandem, unicycle", 1, true), "lists them: " .. said)
end)

--------------------------------------------------------------------------
-- Drawn
--------------------------------------------------------------------------

-- A client that can see a bike of this kind. Only what the network gives it.
local function clientScene(id)
    local sv, world = F.server()
    local cfg = sv.env.BMX.ConfigFor(sv.env.BMX.Bikes[id])
    local pos = sv.env.Vector(0, 0, sv.world.groundZ + sv.env.BMX.RestHeight(cfg))
    local bike = F.bike(sv, classOf(sv, id), pos)
    sv:run(0.3)
    local cl = F.client(world)
    local cb = cl:clientEntity(classOf(sv, id))
    cb:SetPos(bike:GetPos())
    cb:SetAngles(bike:GetAngles())
    for k, v in pairs(bike._nw) do
        if k ~= "Driver" and k ~= "Pod" then cb._nw[k] = v end
    end
    return sv, cl, cb, bike
end

for _, id in ipairs(SHIPPED) do
    T.test("bikes: the client draws the " .. id .. " without an error", function()
        local _, cl, cb = clientScene(id)
        cl.lines, cl.beams, cl.drawnModels, cl.drawnCS = 0, {}, 0, {}
        cb:Draw()
        T.ok(#cl.beams > 35, "a whole bike: " .. #cl.beams .. " tubes")
        T.eq(#cl.errors, 0, "no errors: " .. table.concat(cl.errors, " | "))
    end)
end

T.test("bikes: the client draws each at its own size", function()
    local span = {}
    for _, id in ipairs(SHIPPED) do
        local _, cl, cb = clientScene(id)
        cl.beams = {}
        cb:Draw()
        local mn, mx = math.huge, -math.huge
        for _, b in ipairs(cl.beams) do
            local a, c = cb:WorldToLocal(b.a), cb:WorldToLocal(b.b)
            mn = math.min(mn, a.x, c.x)
            mx = math.max(mx, a.x, c.x)
        end
        span[id] = mx - mn
    end
    T.ok(span.cruiser > span.stock and span.stock > span.mini,
        string.format("drawn length: mini %.1f < stock %.1f < cruiser %.1f", span.mini, span.stock, span.cruiser))
end)

T.test("bikes: the client resolves each bike's own config", function()
    for _, id in ipairs(EXTRA) do
        local _, _, cb = clientScene(id)
        T.eq(cb:Cfg().Wheel.wheelbase, (id == "cruiser") and 43 or 34, id .. " wheelbase on the client")
    end
end)

--------------------------------------------------------------------------
-- Grinding, on each bike's own geometry
--------------------------------------------------------------------------

-- A crank grind holds the bike by the chainring, or by the wheel boxes' floor
-- if that is lower (sv_grind.lua). A floor well below the chainring means the
-- bike grinds on thin air above the pipe: the cruiser did, by 2.6 u, on a real
-- server, before its suspension travel was set to match its wheel.
T.test("bikes: each crank grind is held by the chainring, not by a low hull floor", function()
    local sv = F.server()
    local B = sv.env.BMX
    for _, id in ipairs(SHIPPED) do
        local cfg = B.ConfigFor(B.Bikes[id])
        local crank = B.GrindCrankPoint(cfg)
        local floor = cfg.Chassis.wheelHullBottom or -(cfg.Wheel.radius - cfg.Wheel.restLength)
        local held = math.min(crank.z, floor)
        T.between(crank.z - held + cfg.Grind.clearance, 0, 1.5,
            id .. ": chainring height above the pipe while grinding")
    end
end)

-- The headless grind_pipe case, on the plant: a thin rail along x, the bike
-- placed just over it moving along it.
local function grindOnRail(id)
    local E0 = F.server().env
    local sv = F.server({ solids = { { E0.Vector(-3000, -1, 28), E0.Vector(3000, 1, 30) } } })
    local E, B = sv.env, sv.env.BMX
    local cfg = B.ConfigFor(B.Bikes[id])
    local bike = F.bike(sv, B.ClassFor(id), E.Vector(-2500, 400, sv.world.groundZ + B.RestHeight(cfg)))
    F.scripted(sv, bike)
    sv:run(0.3)
    local crank = B.GrindCrankPoint(cfg)
    F.place(bike, E.Vector(-2000, 0, 34 - crank.z), E.Angle(0, 0, 0))
    bike:GetPhysicsObject():SetVelocity(E.Vector(300, 0, -20))
    bike.st.grounded = false
    local worstUp, ground = 0, 0
    sv:run(1.2, function()
        local g = bike.st.grind
        if g then
            ground = ground + 1
            local c = bike:LocalToWorld(crank)
            worstUp = math.max(worstUp, math.abs(c.z - g.point.z))
        end
        return false
    end)
    return bike, worstUp, ground, sv
end

for _, id in ipairs(SHIPPED) do
    T.test("bikes: the " .. id .. " crank-grinds a rail with its chainring on top", function()
        local bike, worstUp, ticks, sv = grindOnRail(id)
        T.ok(ticks > 20, "it locked on and ground (" .. ticks .. " substeps)")
        T.between(worstUp, 0, 1.5, "chainring kept on the rail's top, u")
        T.ok(sv.env.IsValid(bike:GetDriver()), "rider still aboard")
        T.eq(#sv.errors, 0, "no errors: " .. table.concat(sv.errors, " | "))
    end)
end
