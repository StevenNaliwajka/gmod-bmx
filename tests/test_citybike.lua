--[[--------------------------------------------------------------------------
    The city bike (G12): an upright, heavy, slow bike with swept bars, a coaster
    brake, a kickstand, a child seat and a BASKET.

    The basket is the part with a rule worth testing: a small prop in it stays in
    while the bike is ridden gently (10 mph for 20 m) and is out the moment the bike
    is hopped, crashed or knocked over. The box is the vehicle's own (a volume in
    its space, not an entity), so it is exercised on the offline plant with real
    props.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local gmod = require("lib.gmod")
local IN = gmod.IN

local function classOf(sv, id) return sv.env.BMX.ClassFor(id) end

local function ridden(id)
    local sv, world = F.server()
    local B = sv.env.BMX
    local cfg = B.ConfigFor(B.Bikes[id or "city"])
    local bike = F.bike(sv, classOf(sv, id or "city"),
        sv.env.Vector(0, 0, sv.world.groundZ + B.RestHeight(cfg)))
    local ply = F.scripted(sv, bike)
    sv:run(0.5)
    return sv, bike, ply, world
end

-- A small prop put down in the middle of the basket.
local function prop(sv, bike, mass, at)
    local E = sv.env
    local b = E.BMX.Basket.Of(bike)
    local e = E.ents.Create("prop_physics")
    e:SetPos(at or bike:LocalToWorld((b.mins + b.maxs) * 0.5))
    e:Spawn()
    e:GetPhysicsObject():SetMass(mass or 5)
    return e
end

--------------------------------------------------------------------------
-- The registry
--------------------------------------------------------------------------

T.test("city: it registers clean: 28-inch wheels, heavy, upright, swept bars, coaster brake, a child seat and a basket", function()
    local sv = F.server()
    local B = sv.env.BMX
    local d = B.Bikes.city
    T.ok(d, "registered")
    T.eq(#sv.errors, 0, "nothing rejected: " .. table.concat(sv.errors, " | "))
    T.eq(d.family, "bike", "a bike")
    T.eq(d.drive.kind, "coaster", "a coaster brake")
    T.eq(d.input, "bike_rearonly", "no front brake")
    T.eq(d.pose, "upright", "sat up")
    T.eq(d.barStyle, "swept", "swept-back bars")
    T.ok(B.HasSeat(d, "child"), "a child seat")
    T.ok(not B.HasSeat(d, "pegs"), "and no pegs: a Dutch bike carries a child on the back")
    T.ok(d.basket, "a basket")
    local cfg, cr = B.ConfigFor(d), B.ConfigFor(B.Bikes.cruiser)
    T.eq(cfg.Wheel.radius * 2, 28, "28-inch wheels")
    T.ok(cfg.Chassis.mass > cr.Chassis.mass * 1.15, "heavier than the cruiser: " .. cfg.Chassis.mass)
    T.ok(cfg.Wheel.wheelbase > cr.Wheel.wheelbase, "longer")
    local k = cfg.Wheel.wheelbase / 39
    T.near(cfg.Chassis.seatOffset.x, B.Config.Chassis.seatOffset.x * k, 0.1, "the seat scales with the frame")
    T.eq(B.ClassFor("city"), "bmx_city", "its class")
    local row = sv.lists.SpawnableEntities.bmx_city
    T.eq(row.Subcategory, "Bikes", "in the spawn menu under Bikes")
    T.ok(sv.dupe.bmx_city, "the duplicator knows it")
end)

T.test("city: bmx_spawn city spawns it, built, and respects bmx_allow_bikes", function()
    local sv = F.server()
    local ply = sv:player("Spawner")
    ply:SetPos(sv.env.Vector(0, 0, 0))
    ply._eyeTrace = { Hit = true, HitPos = sv.env.Vector(100, 0, 0), HitNormal = sv.env.Vector(0, 0, 1) }
    sv:command("bmx_spawn", ply, "city")
    local found = sv.env.ents.FindByClass("bmx_city")
    T.eq(#found, 1, "one")
    T.ok(found[1]:AssertBuilt(), "built")
    sv.env.GetConVar("bmx_allow_bikes"):SetString("0")
    sv.world.time = sv.world.time + 2
    sv:command("bmx_spawn", ply, "city")
    T.eq(#sv.env.ents.FindByClass("bmx_city"), 1, "switched off: no second")
    T.eq(sv.env.hook.Run("PlayerSpawnSENT", ply, "bmx_city"), false, "and the menu's door is shut")
end)

local function two(E, over)
    local d = {
        id = "bsk_t", family = "bike", printName = "x",
        wheels = { { pos = E.Vector(20, 0, 0), steer = "fork" }, { pos = E.Vector(-20, 0, 0), drive = true } },
        balance = "singletrack", drive = { kind = "pedal" }, input = "bike", pose = "bike", tricks = "all",
        grindPoints = false,
    }
    for k, v in pairs(over or {}) do d[k] = v end
    return d
end

T.test("basket: a good one is accepted", function()
    local sv = F.server()
    local B, E = sv.env.BMX, sv.env
    T.ok(B.RegisterVehicle(two(E, { basket = { mins = E.Vector(20, -8, 18), maxs = E.Vector(34, 8, 30) } })), "mins and maxs")
    T.ok(B.RegisterVehicle(two(E, { id = "bsk_u", basket = { mins = E.Vector(20, -8, 18), maxs = E.Vector(34, 8, 30), maxMass = 30, hold = 3000 } })), "with its limits")
    T.eq(#sv.errors, 0, table.concat(sv.errors, " | "))
end)

local BAD = {
    { "no mins",              function(d, E) d.basket = { maxs = E.Vector(1, 1, 1) } end,                     "mins" },
    { "no maxs",              function(d, E) d.basket = { mins = E.Vector(0, 0, 0) } end,                     "maxs" },
    { "an inside-out box",    function(d, E) d.basket = { mins = E.Vector(5, 5, 5), maxs = E.Vector(1, 9, 9) } end, "above" },
    { "a flat box",           function(d, E) d.basket = { mins = E.Vector(0, 0, 0), maxs = E.Vector(4, 4, 0) } end, "above" },
    { "corners that are numbers", function(d, E) d.basket = { mins = 1, maxs = 2 } end,                       "Vector" },
    { "a stray key",          function(d, E) d.basket = { mins = E.Vector(0, 0, 0), maxs = E.Vector(1, 1, 1), lid = true } end, "lid" },
    { "a mass limit of 0",    function(d, E) d.basket = { mins = E.Vector(0, 0, 0), maxs = E.Vector(1, 1, 1), maxMass = 0 } end, "maxMass" },
    { "a hold limit of text", function(d, E) d.basket = { mins = E.Vector(0, 0, 0), maxs = E.Vector(1, 1, 1), hold = "lots" } end, "hold" },
    { "a basket that is a number", function(d, E) d.basket = 3 end,                                          "basket" },
}
for _, c in ipairs(BAD) do
    T.test("basket: rejected, loudly: " .. c[1], function()
        local sv = F.server()
        local B, E = sv.env.BMX, sv.env
        local d = two(E)
        c[2](d, E)
        T.eq(B.RegisterVehicle(d), false, "refused")
        T.ok(#sv.errors > 0 and sv.errors[1]:find(c[3], 1, true), "reported with `" .. c[3] .. "`: " .. tostring(sv.errors[1]))
        T.ok(not B.Vehicles.bsk_t, "and not registered")
    end)
end

--------------------------------------------------------------------------
-- Riding it
--------------------------------------------------------------------------

T.test("city: it is slower than the BMX, heavier to get going, and a coaster-braked bike coasts freely", function()
    local peak = {}
    for _, id in ipairs({ "stock", "city" }) do
        local sv, e = ridden(id)
        F.input(e, { throttle = 1 })
        local top = 0
        sv:run(25, function() top = math.max(top, e.st.speed) return false end)
        peak[id] = top
    end
    T.ok(peak.city < peak.stock * 0.85, string.format("top speed %.0f against the BMX's %.0f", peak.city, peak.stock))
    T.ok(peak.city > 130, "but it goes: " .. peak.city)
    local sv, e = ridden("city")
    F.accelerateTo(sv, e, 150)
    F.input(e, {})
    local v0 = e.st.speed
    sv:run(3)
    T.ok(e.st.speed > v0 * 0.6, "a freewheel: no engine braking: " .. v0 .. " -> " .. e.st.speed)
    T.eq(e.st.crankA, nil, "no crank locked to the wheel")
end)

T.test("city: S is the coaster brake and stops it; it stays upright and aboard", function()
    local sv, e = ridden("city")
    F.accelerateTo(sv, e, 150)
    F.input(e, { brakeRear = 1 })
    sv:run(6, function() return e.st.speed < 5 end)
    T.ok(e.st.speed < 5, "stopped: " .. e.st.speed)
    T.ok(sv.env.IsValid(e:GetDriver()), "still aboard")
end)

local function cmd(buttons)
    local c = { buttons = buttons or 0, fwd = 0, side = 0, up = 0 }
    function c:GetButtons() return self.buttons end
    function c:SetButtons(b) self.buttons = b end
    function c:GetForwardMove() return self.fwd end
    function c:GetSideMove() return self.side end
    function c:SetForwardMove(v) self.fwd = v end
    function c:SetSideMove(v) self.side = v end
    function c:SetUpMove(v) self.up = v end
    return c
end

T.test("city: LMB does nothing on the ground, even with bmx_fixie_frontbrake 1", function()
    local sv = F.server()
    local e = F.bike(sv, classOf(sv, "city"))
    local ply = F.rider(sv, e)
    sv.env.hook.Run("StartCommand", ply, cmd(IN.ATTACK))
    T.eq(e.input.brakeFront, 0, "no front brake")
    T.eq(e.input.pitchTarget, 0, "and no weight forward")
    sv.env.GetConVar("bmx_fixie_frontbrake"):SetString("1")
    sv.env.hook.Run("StartCommand", ply, cmd(IN.ATTACK))
    T.eq(e.input.brakeFront, 0, "the fixie's switch is the fixie's alone")
    sv.env.hook.Run("StartCommand", ply, cmd(IN.BACK))
    T.eq(e.input.brakeRear, 1, "S is the brake")
end)

T.test("city: parked, it stands on its kickstand, and a bell rings", function()
    local sv = F.server()
    local B = sv.env.BMX
    local cfg = B.ConfigFor(B.Bikes.city)
    local bike = F.bike(sv, classOf(sv, "city"), sv.env.Vector(0, 0, sv.world.groundZ + B.RestHeight(cfg)))
    sv:run(2)
    T.ok(bike:GetStandDown(), "the stand is down")
    T.ok(math.abs(bike.st.roll) < bike:Cfg().Stand.maxRoll and bike.st.roll < 0, "leaning on it")
    T.ok(B.Bell and B.Bell.Ring, "the bell is the existing one (sv_bell.lua)")
end)

T.test("city: the upright pose sits further back than the BMX's and does not tuck with speed", function()
    local sv, world = F.server()
    local cl = F.client(world)
    local B = cl.env.BMX
    local s = { crank = 0, speed = 0, topSpeed = 300, pitch = 0, steer = 0 }
    local bmx, city = B.PoseSets.bike.rider(s), B.PoseSets.upright.rider(s)
    T.ok(city.spine.y < bmx.spine.y - 5, "the spine is back: " .. city.spine.y .. " vs " .. bmx.spine.y)
    s.speed = 300
    local fast = B.PoseSets.upright.rider(s)
    T.ok(fast.spine.y - city.spine.y < 6, "and barely tucks at speed")
    s.crank = math.pi / 2
    s.speed = 0
    T.ok(math.abs(B.PoseSets.upright.rider(s).rThigh.y) < math.abs(B.PoseSets.bike.rider(s).rThigh.y), "an unhurried stroke")
end)

--------------------------------------------------------------------------
-- The basket
--------------------------------------------------------------------------

T.test("basket: a small prop put in the box is caught, and rides with the bike", function()
    local sv, bike = ridden()
    local B = sv.env.BMX
    local e = prop(sv, bike)
    sv:run(0.3)
    T.eq(e.BMXBasket, bike, "caught")
    T.eq(#B.Basket.Held(bike), 1, "the bike counts it")
    T.ok(not e:GetPhysicsObject().gravity, "no gravity of its own while held")
    local b = B.Basket.Of(bike)
    T.ok(B.Basket.Contains(bike, b, e:GetPos()), "and it is inside the box")
end)

T.test("basket: a heavy prop, a fast one and one somebody is holding are not caught", function()
    local sv, bike = ridden()
    local big = prop(sv, bike, 60)
    local fast = prop(sv, bike, 5)
    fast:GetPhysicsObject():SetVelocity(sv.env.Vector(0, 0, -600))
    local held = prop(sv, bike, 5)
    held.IsPlayerHolding = function() return true end
    local outside = prop(sv, bike, 5, bike:LocalToWorld(sv.env.Vector(-40, 0, 25)))
    sv:run(0.3)
    T.eq(big.BMXBasket, nil, "60 kg is not a parcel")
    T.eq(fast.BMXBasket, nil, "thrown in too hard")
    T.eq(held.BMXBasket, nil, "in somebody's hands")
    T.eq(outside.BMXBasket, nil, "not in the box")
end)

T.test("basket: ridden gently, 20 m at 10 mph, the prop is still in it, still where it was put", function()
    local sv, bike = ridden()
    local B = sv.env.BMX
    local e = prop(sv, bike)
    sv:run(0.3)
    local at = bike:WorldToLocal(e:GetPos())
    local mph10 = 10 * 17.6
    F.accelerateTo(sv, bike, mph10)
    local start = bike:GetPos()
    local peakAccel = 0
    F.input(bike, { throttle = 0.45 })
    sv:run(12, function()
        peakAccel = math.max(peakAccel, bike.basketAccel or 0)
        return (bike:GetPos() - start):Length() >= 20 * 39.37
    end)
    T.ok((bike:GetPos() - start):Length() >= 20 * 39.37, "it rode 20 m")
    T.eq(e.BMXBasket, bike, "the prop is still in the basket")
    T.ok((bike:WorldToLocal(e:GetPos()) - at):Length() < 3, "where it was put: " .. tostring(bike:WorldToLocal(e:GetPos()) - at))
    T.ok(peakAccel < (B.Basket.Of(bike) and select(3, B.Basket.Of(bike))), string.format("the ride's peak was %.0f u/s^2, under the hold", peakAccel))
    T.ok((e:GetPhysicsObject():GetVelocity() - bike:GetPhysicsObject():GetVelocity()):Length() < 5, "moving as the bike moves")
    T.eq(#sv.errors, 0, table.concat(sv.errors, " | "))
end)

T.test("basket: a hop at full speed throws it out, and it flies", function()
    local sv, bike = ridden()
    local e = prop(sv, bike)
    sv:run(0.3)
    F.accelerateTo(sv, bike, 190)
    F.input(bike, { throttle = 0.5 })
    sv:run(0.5)
    T.eq(e.BMXBasket, bike, "in, before the hop")
    bike.hopHeld, bike.hopCharge = true, 0
    sv:run(bike:Cfg().Hop.chargeTime + 0.05)
    bike.hopRelease = true
    local out = false
    sv:run(0.6, function()
        if e.BMXBasket == nil then out = true end
        return out
    end)
    T.ok(out, "released by the hop")
    T.ok(e:GetPhysicsObject().gravity, "gravity is its own again")
    T.ok(e:GetPhysicsObject():GetVelocity().z > 20 or e:GetPos().z > bike:GetPos().z - 5, "with a flick up: " .. e:GetPhysicsObject():GetVelocity().z)
    sv:run(2)
    local b = sv.env.BMX.Basket.Of(bike)
    T.ok(not sv.env.BMX.Basket.Contains(bike, b, e:GetPos()), "and it is not in the basket any more")
    T.eq(e.BMXBasket, nil, "not caught again as it left")
end)

T.test("basket: a crash empties it", function()
    local sv, bike = ridden()
    local e = prop(sv, bike)
    sv:run(0.3)
    F.accelerateTo(sv, bike, 150)
    bike:Crash("angle", 0.5)
    sv:run(0.2)
    T.eq(e.BMXBasket, nil, "out")
    T.eq(#sv.env.BMX.Basket.Held(bike), 0, "and the bike carries nothing")
end)

T.test("basket: a bike knocked over drops its load", function()
    local sv, bike = ridden()
    local e = prop(sv, bike)
    sv:run(0.3)
    T.eq(e.BMXBasket, bike, "in")
    F.layDown(sv, bike)
    sv:run(1.5)
    T.eq(e.BMXBasket, nil, "out")
end)

T.test("basket: a removed bike frees its props", function()
    local sv, bike = ridden()
    local e = prop(sv, bike)
    sv:run(0.3)
    bike:Remove()
    T.eq(e.BMXBasket, nil, "freed")
    T.ok(e:GetPhysicsObject().gravity, "with its gravity back")
end)

T.test("basket: a prop that is picked up with the physgun is let go", function()
    local sv, bike = ridden()
    local e = prop(sv, bike)
    sv:run(0.3)
    e.IsPlayerHolding = function() return true end
    sv:run(0.1)
    T.eq(e.BMXBasket, nil, "released")
    T.ok(e:GetPhysicsObject().gravity, "and it is the world's")
end)

T.test("basket: the held prop does not collide with the bike it rides in", function()
    local sv, bike = ridden()
    local e = prop(sv, bike)
    sv:run(0.3)
    T.eq(sv.env.hook.Run("ShouldCollide", bike, e), false, "no")
    T.eq(sv.env.hook.Run("ShouldCollide", e, bike), false, "either way round")
end)

T.test("basket: a released prop is not taken straight back", function()
    local sv, bike = ridden()
    local e = prop(sv, bike)
    sv:run(0.3)
    sv.env.BMX.Basket.ReleaseOne(bike, e, "test")
    e:SetPos(bike:LocalToWorld(sv.env.Vector(32, 0, 26)))
    e:GetPhysicsObject():SetVelocity(bike:GetPhysicsObject():GetVelocity())
    sv:run(0.5)
    T.eq(e.BMXBasket, nil, "within the cooldown it stays out")
end)

T.test("basket: only a bike with a basket looks for props", function()
    local sv = F.server()
    local bike = F.bike(sv, "bmx_base")
    local e = sv.env.ents.Create("prop_physics")
    e:SetPos(bike:LocalToWorld(sv.env.Vector(32, 0, 26)))
    e:Spawn()
    sv:run(0.5)
    T.eq(e.BMXBasket, nil, "a BMX has none")
end)

T.test("basket: the acceleration is read over a window, so a bumpy road is not a hop", function()
    local sv, bike = ridden()
    local e = prop(sv, bike)
    sv:run(0.3)
    F.accelerateTo(sv, bike, 160)
    F.input(bike, { throttle = 0.4 })
    -- 40 small kicks of 40 u/s, which is not a hop.
    for _ = 1, 20 do
        local po = bike:GetPhysicsObject()
        po:SetVelocity(po:GetVelocity() + sv.env.Vector(0, 0, 25))
        sv:run(0.1)
        po:SetVelocity(po:GetVelocity() - sv.env.Vector(0, 0, 25))
        sv:run(0.1)
    end
    T.eq(e.BMXBasket, bike, "kept")
end)

--------------------------------------------------------------------------
-- Drawn
--------------------------------------------------------------------------

local function clientScene(id, set)
    local sv, world = F.server()
    local cl = F.client(world)
    local cb = cl:clientEntity(classOf(sv, id))
    cb:SetPos(cl.env.Vector(0, 0, 20))
    for k, v in pairs(set or {}) do cb._nw[k] = v end
    return cl, cb
end

T.test("city: the client draws it, swept bars and the basket included, without an error", function()
    local cl, cb = clientScene("city")
    cl.beams = {}
    cb:Draw()
    T.eq(#cl.errors, 0, "no errors: " .. table.concat(cl.errors, " | "))
    local clB, bmx = clientScene("stock")
    clB.beams = {}
    bmx:Draw()
    T.ok(#cl.beams >= #clB.beams + 14, string.format("%d tubes against the BMX's %d: swept bars and a carrier", #cl.beams, #clB.beams))
    local b = cb:Bike().basket
    local inBasket = 0
    for _, bm in ipairs(cl.beams) do
        local l = cb:WorldToLocal(bm.a)
        if l.x >= b.mins.x - 1 and l.x <= b.maxs.x + 1 and l.z >= b.mins.z - 1 and l.z <= b.maxs.z + 1
            and math.abs(l.y) <= b.maxs.y + 1 then
            inBasket = inBasket + 1
        end
    end
    T.ok(inBasket >= 8, "the basket's rim and floor are drawn where the box is: " .. inBasket)
end)

T.test("city: the child seat is a switch on the city bike's context menu, and seats a child", function()
    local sv, bike = ridden("city")
    T.ok(sv.env.BMX.HasSeat(bike:Bike(), "child"), "it has the seat")
    local owner = sv:player("Owner")
    local prop = sv.properties.bmx_childseat
    T.ok(prop:Filter(bike, owner), "offered on the city bike")
    bike:SetChildSeat(true)
    local kid = sv:player("Kid")
    kid._eyeTrace = { Hit = true, Entity = bike, HitPos = bike:LocalToWorld(sv.env.Vector(-20, 0, 8)) }
    bike:Use(kid)
    T.ok(kid:InVehicle() and bike:GetPaxChild() == kid, "a child in the seat")
    T.near(bike:GetPhysicsObject():GetMass(), bike:Cfg().Chassis.mass, 1e-6, "(the config is the heavier one)")
    T.near(bike.paxMass, bike.paxBaseMass * 0.25, 1e-6, "a child is a quarter of the bike")
end)
