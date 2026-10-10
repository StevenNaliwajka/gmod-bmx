--[[--------------------------------------------------------------------------
    A second rider (G11): the seat registry, boarding, what a passenger does to the
    bike, the crash that takes both, and the client's view of it.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local function classOf(sv, id) return sv.env.BMX.ClassFor(id) end

-- A bike with a child seat and nothing else: the city bike (G12) has one, but the
-- seat is G11's, so it is tested on a bike made here.
local function kidBike(B)
    if not B.Bikes.kidbike then B.RegisterBike("kidbike", { printName = "Kid bike", seats = { child = {} } }) end
end

-- A bike with a scripted rider, settled.
local function ridden(id)
    local sv, world = F.server()
    local B = sv.env.BMX
    kidBike(B)
    local cfg = B.ConfigFor(B.Bikes[id or "stock"])
    local bike = F.bike(sv, classOf(sv, id or "stock"),
        sv.env.Vector(0, 0, sv.world.groundZ + B.RestHeight(cfg)))
    local rider = F.scripted(sv, bike)
    sv:run(0.5)
    return sv, bike, rider, world
end

-- Another player pressing E on the bike, looking at the rear of it unless told.
local function board(sv, bike, name, at)
    local p = sv:player(name or "Passenger")
    at = at or sv.env.Vector(-16, 0, 8)
    p._eyeTrace = { Hit = true, Entity = bike, HitPos = bike:LocalToWorld(at) }
    bike:Use(p)
    return p
end

--------------------------------------------------------------------------
-- The seat registry
--------------------------------------------------------------------------

local function two(E, over)
    local d = {
        id = "seat_t", family = "bike", printName = "x",
        wheels = { { pos = E.Vector(20, 0, 0), steer = "fork" }, { pos = E.Vector(-20, 0, 0), drive = true } },
        balance = "singletrack", drive = { kind = "pedal" }, input = "bike", pose = "bike", tricks = "all",
        grindPoints = false,
    }
    for k, v in pairs(over or {}) do d[k] = v end
    return d
end

T.test("seats: the shipped bikes say what they carry", function()
    local sv = F.server()
    local B = sv.env.BMX
    T.eq(#sv.errors, 0, table.concat(sv.errors, " | "))
    for _, id in ipairs({ "stock", "cruiser" }) do
        T.ok(B.HasSeat(B.Bikes[id], "pegs"), id .. " has pegs")
        T.ok(not B.HasSeat(B.Bikes[id], "child"), id .. " has no child seat")
    end
    T.ok(B.HasSeat(B.Bikes.stock, "rider"), "everything has a rider's seat")
    T.ok(not B.HasSeat(B.Bikes.mini, "pegs"), "the mini is too small to carry anyone")
    T.ok(not B.HasSeat(B.Bikes.road, "pegs"), "a road bike has no pegs")
end)

T.test("seats: every form is accepted: the old list, a map, empty seats, every key", function()
    local sv = F.server()
    local B, E = sv.env.BMX, sv.env
    T.ok(B.RegisterVehicle(two(E, { id = "s_list", seats = { { offset = E.Vector(-10, 0, 18) } } })), "the old list form")
    T.ok(B.RegisterVehicle(two(E, { id = "s_none" })), "no seats at all")
    T.ok(B.RegisterVehicle(two(E, { id = "s_map", seats = { pegs = {}, child = {} } })), "empty seats are all defaults")
    T.ok(B.RegisterVehicle(two(E, { id = "s_full", seats = {
        rider = { model = "models/nova/airboat_seat.mdl", offset = E.Vector(-9, 0, 17), angles = E.Angle(0, -90, 0) },
        pegs  = { offset = function(cfg) return E.Vector(-cfg.Wheel.wheelbase * 0.6, 0, 22) end, massFactor = 0.5 },
        child = { massFactor = 0.2 } } })), "every key")
    T.eq(#sv.errors, 0, table.concat(sv.errors, " | "))
end)

local BAD = {
    { "an unknown seat",            function(d, E) d.seats = { lap = {} } end,                         "lap" },
    { "a stray key on a seat",      function(d, E) d.seats = { pegs = { colour = 1 } } end,            "colour" },
    { "a seat that is a number",    function(d, E) d.seats = { pegs = 5 } end,                         "pegs" },
    { "a negative mass factor",     function(d, E) d.seats = { pegs = { massFactor = -1 } } end,       "massFactor" },
    { "a huge mass factor",         function(d, E) d.seats = { pegs = { massFactor = 40 } } end,       "massFactor" },
    { "an offset that is a number", function(d, E) d.seats = { child = { offset = 3 } } end,           "offset" },
    { "angles that are a vector",   function(d, E) d.seats = { pegs = { angles = E.Vector(0, 0, 0) } } end, "angles" },
    { "a model that is a number",   function(d, E) d.seats = { pegs = { model = 5 } } end,             "model" },
    { "seats that are text",        function(d, E) d.seats = "two" end,                                "seats" },
    { "two seats in a list",        function(d, E) d.seats = { {}, {} } end,                           "seats" },
    { "the list's stray key",       function(d, E) d.seats = { { colour = 1 } } end,                   "colour" },
}

for _, c in ipairs(BAD) do
    T.test("seats: rejected, loudly: " .. c[1], function()
        local sv = F.server()
        local B, E = sv.env.BMX, sv.env
        local d = two(E)
        c[2](d, E)
        T.eq(B.RegisterVehicle(d), false, "refused")
        T.ok(#sv.errors > 0 and sv.errors[1]:find(c[3], 1, true), "reported with `" .. c[3] .. "`: " .. tostring(sv.errors[1]))
        T.ok(not B.Vehicles.seat_t, "and not registered")
    end)
end

T.test("seats: defaults put the pegs behind the rear axle and the child seat over the rear wheel", function()
    local sv = F.server()
    local B = sv.env.BMX
    for _, id in ipairs({ "stock", "cruiser" }) do
        local cfg = B.ConfigFor(B.Bikes[id])
        local rider = B.SeatFor(B.Bikes[id], cfg, "rider")
        local pegs = B.SeatFor(B.Bikes[id], cfg, "pegs")
        T.near(rider.offset.x, cfg.Chassis.seatOffset.x, 1e-9, id .. " rider where the config puts them")
        T.ok(pegs.offset.x < -cfg.Wheel.wheelbase * 0.5, id .. " pegs seat behind the rear axle")
        T.ok(pegs.offset.z > rider.offset.z, id .. " and higher than the rider")
        T.near(pegs.massFactor, 0.6, 1e-9, id .. " an adult is 0.6 of the bike's mass")
        T.ok(B.SeatFor(B.Bikes[id], cfg, "child") == nil, id .. " no child seat to ask for")
    end
    local list = B.SeatFor({ seats = { { offset = sv.env.Vector(-1, 2, 3) } } }, B.Config, "rider")
    T.eq(list.offset.y, 2, "the list form is still the rider's seat")
    local fn = B.SeatFor({ seats = { pegs = { offset = function(c) return sv.env.Vector(c.Wheel.wheelbase, 0, 0) end } } },
        B.ConfigFor(B.Bikes.cruiser), "pegs")
    T.eq(fn.offset.x, 43, "an offset that is a function of the config")
    T.eq(#B.SeatKindsOf(B.Bikes.stock), 2, "rider and pegs")
end)

T.test("seats: the rider's pod is where the registration puts it, for the old list and the new map", function()
    local sv = F.server()
    local B, E = sv.env.BMX, sv.env
    B.RegisterBike("seat_old", { seats = { { offset = E.Vector(-12, 0, 19) } } })
    B.RegisterBike("seat_new", { seats = { rider = { offset = E.Vector(-13, 0, 20) }, pegs = {} } })
    for id, want in pairs({ seat_old = E.Vector(-12, 0, 19), seat_new = E.Vector(-13, 0, 20) }) do
        local e = F.bike(sv, classOf(sv, id))
        T.near((e:GetPod():GetPos() - e:LocalToWorld(want)):Length(), 0, 0.01, id)
    end
end)

--------------------------------------------------------------------------
-- Boarding
--------------------------------------------------------------------------

T.test("pegs: E on an occupied bike seats a second player on the pegs, in a pod of their own", function()
    local sv, bike, rider = ridden()
    local p = board(sv, bike)
    T.ok(p:InVehicle(), "aboard")
    T.eq(bike:GetPaxPegs(), p, "the bike knows who")
    T.eq(bike:GetDriver(), rider, "the rider is undisturbed")
    local pod = p:GetVehicle()
    T.ok(pod ~= bike:GetPod(), "a pod of its own")
    T.eq(pod:GetParent(), bike, "parented to the bike like the rider's")
    T.eq(pod.BMXBike, bike, "knows its bike")
    T.eq(pod.BMXPassenger, "pegs", "and its seat")
    T.ok(pod.DoNotDuplicate, "and the duplicator is told not to copy it")
    T.ok(bike:GetPod().DoNotDuplicate, "as the rider's is")
    T.eq(p.BMXBike, nil, "a passenger is not the rider: no input is read from them")
    local before = #sv.env.ents.FindByClass("prop_vehicle_prisoner_pod")
    local q = board(sv, bike, "Third")
    T.ok(not q:InVehicle(), "only one on the pegs")
    T.eq(#sv.env.ents.FindByClass("prop_vehicle_prisoner_pod"), before, "and no pod made for the refused")
end)

T.test("pegs: the pod sits where the seat registration puts it", function()
    local sv, bike = ridden()
    local p = board(sv, bike)
    local seat = sv.env.BMX.SeatFor(bike:Bike(), bike:Cfg(), "pegs")
    T.near((p:GetVehicle():GetPos() - bike:LocalToWorld(seat.offset)):Length(), 0, 0.01, "pod position")
end)

T.test("pegs: nobody boards a bike with no rider (E gets them in the saddle), or one without pegs", function()
    local sv = F.server()
    local B = sv.env.BMX
    local bike = F.bike(sv, "bmx_base")
    local p = sv:player("Alone")
    bike:Use(p)
    T.eq(bike:GetDriver(), p, "an empty bike's E is the rider's seat")
    local mini = F.bike(sv, classOf(sv, "mini"))
    local r = sv:player("R")
    mini:Use(r)
    local q = sv:player("Q")
    mini:Use(q)
    T.ok(not q:InVehicle(), "a mini has nowhere for a second rider")
end)

T.test("pegs: E on an occupied bike with nobody pointing at its rear does nothing, as it always did", function()
    local sv, bike, rider = ridden()
    local p = sv:player("Walker")
    bike:Use(p, p, 1, 0)
    T.ok(not p:InVehicle(), "no trace: nowhere")
    p._eyeTrace = { Hit = true, Entity = sv.env.ents.Create("prop_physics"), HitPos = sv.env.Vector() }
    bike:Use(p, p, 1, 0)
    T.ok(not p:InVehicle(), "looking at something else: nowhere")
    T.eq(bike:GetDriver(), rider, "and the rider is undisturbed")
    T.ok(sv.env.BMX.Passenger.TryBoard(bike, p, true), "a script may seat somebody without pointing")
    T.ok(p:InVehicle(), "and they are on the pegs")
end)

T.test("pegs: E on the FRONT of an occupied bike does not board", function()
    local sv, bike = ridden()
    local p = board(sv, bike, "Front", sv.env.Vector(14, 0, 20))
    T.ok(not p:InVehicle(), "the front is the rider's")
    local q = board(sv, bike, "Rear", sv.env.Vector(-16, 0, 10))
    T.ok(q:InVehicle(), "the rear is the pegs'")
end)

T.test("pegs: bmx_passengers 0 stops boarding, and puts everyone aboard off", function()
    local sv, bike = ridden()
    local cv = sv.env.GetConVar("bmx_passengers")
    T.eq(cv:GetInt(), 1, "on by default")
    local p = board(sv, bike)
    T.ok(p:InVehicle(), "aboard")
    cv:SetString("0")
    T.ok(not p:InVehicle(), "put off the moment it was switched off")
    local q = board(sv, bike, "Late")
    T.ok(not q:InVehicle(), "and nobody boards")
    cv:SetString("1")
    local r = board(sv, bike, "Again")
    T.ok(r:InVehicle(), "back on")
end)

T.test("pegs: the passenger gets off with E and the bike is the rider's again", function()
    local sv, bike, rider = ridden()
    local p = board(sv, bike)
    p:ExitVehicle()
    T.ok(not p:InVehicle(), "off")
    T.ok(not sv.env.IsValid(bike:GetPaxPegs()), "the bike says nobody")
    T.eq(bike:GetDriver(), rider, "the rider rode on")
    local q = board(sv, bike, "Next")
    T.ok(q:InVehicle(), "and the pegs are free again")
    T.eq(bike.paxPods.pegs, q:GetVehicle(), "in the same pod")
end)

T.test("pegs: a rider who gets off takes the passenger off too", function()
    local sv, bike, rider = ridden()
    local p = board(sv, bike)
    rider:ExitVehicle()
    T.ok(not p:InVehicle(), "the passenger is off")
    T.ok(not sv.env.IsValid(bike:GetPaxPegs()), "and the bike is empty")
end)

T.test("pegs: a rider who dies or leaves takes the passenger off too", function()
    for _, how in ipairs({ "death", "leave" }) do
        local sv, bike, rider = ridden()
        local p = board(sv, bike)
        if how == "death" then sv.env.hook.Run("PlayerDeath", rider) else sv.env.hook.Run("PlayerDisconnected", rider) end
        T.ok(not p:InVehicle() or bike:GetDriver() ~= rider, how .. ": the rider is gone")
        T.eq(sv.env.IsValid(bike:GetDriver()), false, how .. ": nobody at the bars")
        T.ok(not p:InVehicle(), how .. ": and the passenger with them")
    end
end)

T.test("pegs: a passenger who disconnects or dies leaves the bike clean", function()
    for _, how in ipairs({ "death", "leave" }) do
        local sv, bike = ridden()
        local base = bike:Cfg().Chassis.mass
        local p = board(sv, bike)
        if how == "death" then sv.env.hook.Run("PlayerDeath", p) else sv.env.hook.Run("PlayerDisconnected", p) end
        T.ok(not sv.env.IsValid(bike:GetPaxPegs()), how .. ": the seat is free")
        T.eq(bike:GetPhysicsObject():GetMass(), base, how .. ": the mass is back")
        T.eq(p.BMXPax, nil, how .. ": forgotten")
    end
end)

T.test("pegs: nobody grabs a passenger's pod with the physgun", function()
    local sv, bike = ridden()
    local p = board(sv, bike)
    T.eq(sv.env.hook.Run("PhysgunPickup", sv:player("Griefer"), p:GetVehicle()), false, "no")
end)

T.test("pegs: a passenger is not in the way of the rider or the wheels' traces", function()
    local sv, bike, rider = ridden()
    local p = board(sv, bike)
    local ok = false
    for _, f in ipairs(bike.traceFilter) do if f == p then ok = true end end
    T.ok(ok, "in the wheel trace filter")
    T.eq(sv.env.hook.Run("ShouldCollide", bike, p), false, "no collision with the bike")
    T.eq(sv.env.hook.Run("ShouldCollide", bike, p:GetVehicle()), false, "nor with their pod")
end)

--------------------------------------------------------------------------
-- What a passenger does to the bike
--------------------------------------------------------------------------

T.test("mass: a passenger adds 0.6 of the bike's mass to the body, the config and the inertia, and gives it back", function()
    local sv, bike = ridden()
    local B = sv.env.BMX
    local base = bike:Cfg().Chassis.mass
    local phys = bike:GetPhysicsObject()
    local I0 = bike.I.y
    local p = board(sv, bike)
    T.near(phys:GetMass(), base * 1.6, 1e-6, "the physics object")
    T.near(bike:Cfg().Chassis.mass, base * 1.6, 1e-6, "and the config the bike runs on")
    T.ok(bike.I.y > I0 * 1.4, string.format("the inertia is measured again: %.0f -> %.0f", I0, bike.I.y))
    T.eq(B.Config.Chassis.mass, base, "the base config is untouched")
    T.eq(B.Bikes.stock.physics, nil, "and so is the registry")
    p:ExitVehicle()
    T.near(phys:GetMass(), base, 1e-6, "mass back")
    T.near(bike.I.y, I0, 1e-6, "inertia back")
    T.eq(bike:Cfg().Chassis.mass, base, "config back")
end)

T.test("mass: if the engine does not rescale the inertia with the mass, it is rescaled here", function()
    local sv, bike = ridden()
    local phys = bike:GetPhysicsObject()
    local fixed = phys:GetInertia()               -- an engine that keeps the moments through a SetMass
    phys.GetInertia = function() return fixed end
    local I0 = bike.I.y
    local p = board(sv, bike)
    T.near(bike.I.y, I0 * 1.6, 1e-6, "the moments follow the mass: " .. bike.I.y)
    p:ExitVehicle()
    T.near(bike.I.y, I0, 1e-6, "and come back")
end)

T.test("mass: the cruiser's passenger is a fraction of the cruiser's own mass", function()
    local sv, bike = ridden("cruiser")
    local base = bike:Cfg().Chassis.mass
    board(sv, bike)
    T.near(bike:GetPhysicsObject():GetMass(), base * 1.6, 1e-6, "0.6 of 94")
end)

T.test("mass: the passenger's weight sits on the pegs: the rear sags and the front lightens", function()
    local sv, bike = ridden()
    sv:run(1.5)
    local f, r = F.wheels(bike)
    local share0 = r.load / math.max(f.load + r.load, 1)
    board(sv, bike)
    sv:run(2)
    local share1 = r.load / math.max(f.load + r.load, 1)
    T.ok(share1 > share0 + 0.03, string.format("the rear carries %.0f%% of the weight, up from %.0f%%", share1 * 100, share0 * 100))
    T.ok(f.onGround and r.onGround, "both wheels still down")
    T.ok(math.abs(bike.st.roll) < math.rad(10) and sv.env.IsValid(bike:GetDriver()), "and it stays up with the rider")
    T.eq(#sv.errors, 0, table.concat(sv.errors, " | "))
end)

T.test("mass: the couple is only a couple: no net force, so it does not push the bike about", function()
    local sv, bike = ridden()
    board(sv, bike)
    local phys = bike:GetPhysicsObject()
    local v0 = phys:GetVelocity()
    sv.env.BMX.Passenger.ApplyWeight(bike, phys, 1 / 66)
    local dv = phys:GetVelocity() - v0
    T.near(dv:Length(), 0, 1e-9, "the weight down and the same weight up cancel")
    T.ok(phys.w:Length() > 0, "but there is a torque")
end)

T.test("mass: a heavier bike rides on, with the wheelie harder to hold", function()
    local sv, bike = ridden()
    F.accelerateTo(sv, bike, 160)
    local sv2, b2 = ridden()
    board(sv2, b2)
    F.accelerateTo(sv2, b2, 160)
    local t1, t2 = sv.world.time, sv2.world.time
    T.ok(t2 > t1, string.format("slower to 160 u/s with two on: %.2fs against %.2fs", t2, t1))
end)

T.test("score: every trick is x2 with a passenger aboard, and x1 again when they get off", function()
    local sv, bike = ridden()
    local p = board(sv, bike)
    bike:AwardTricks({ { name = "Backflip", count = 1, points = 500 } })
    T.eq(bike:GetScore(), 1000, "x2")
    p:ExitVehicle()
    bike:AwardTricks({ { name = "Backflip", count = 1, points = 500 } })
    T.eq(bike:GetScore(), 1500, "and x1 again")
end)

T.test("score: a road bike's x1.5 and a passenger's x2 multiply", function()
    local B = F.server().env.BMX
    local sv, bike = ridden("road")
    T.eq(sv.env.BMX.Bikes.road.scoreMult, 1.5, "the road bike's")
    -- the road bike has no pegs, so the second multiplier is checked directly
    sv.env.BMX.PassengerScoreMult = function() return 2 end
    bike:AwardTricks({ { name = "Backflip", count = 1, points = 100 } })
    T.eq(bike:GetScore(), 300, "100 x 1.5 x 2")
end)

--------------------------------------------------------------------------
-- A crash takes both
--------------------------------------------------------------------------

T.test("crash: both are thrown, each as a ragdoll of their own, and BMX_RiderCrashed fires for each", function()
    local sv, bike, rider = ridden()
    local p = board(sv, bike)
    F.accelerateTo(sv, bike, 150)
    local took = {}
    sv.env.hook.Add("BMX_RiderCrashed", "t", function(ply, vel, b)
        took[#took + 1] = { ply = ply, vel = vel, bike = b }
        return true
    end)
    bike:Crash("angle", 0.6)
    sv:run(0.2)
    T.ok(not rider:InVehicle() and not p:InVehicle(), "both off the bike")
    T.eq(#took, 2, "the hook fired for each")
    local who = {}
    for _, t in ipairs(took) do who[t.ply] = t end
    T.ok(who[rider] and who[p], "the rider and the passenger")
    T.eq(who[p].bike, bike, "with the bike")
    T.ok(who[p].vel:Length() > 50, "the passenger carries the bike's speed: " .. who[p].vel:Length())
    T.ok((who[rider].vel - who[p].vel):Length() > 5, "and not exactly the rider's")
    T.ok(not sv.env.IsValid(bike:GetPaxPegs()), "the pegs are empty")
    T.near(bike:GetPhysicsObject():GetMass(), bike:Cfg().Chassis.mass, 1e-6, "the mass is back")
end)

T.test("crash: with nobody taking them, both tumble as ragdolls and are hurt", function()
    local sv, bike, rider = ridden()
    local p = board(sv, bike)
    F.accelerateTo(sv, bike, 220)
    bike:Crash("angle", 0.9)
    sv:run(0.1)
    T.ok(rider.BMXTumbling, "the rider is a ragdoll")
    T.ok(p.BMXTumbling, "so is the passenger")
    sv:run(sv.env.BMX.TumbleTime + 0.5)
    T.ok(not rider.BMXTumbling and not p.BMXTumbling, "and both are back on their feet")
    T.ok((p._damage or 0) > 0, "hurt, as the rider is: " .. tostring(p._damage))
    T.eq(#sv.errors, 0, table.concat(sv.errors, " | "))
end)

T.test("crash: a gamemode's BMX_Crash veto keeps the passenger on too", function()
    local sv, bike, rider = ridden()
    local p = board(sv, bike)
    sv.env.hook.Add("BMX_Crash", "t", function() return false end)
    bike:Crash("angle", 0.6)
    sv:run(0.2)
    T.ok(rider:InVehicle() and p:InVehicle(), "nobody was thrown")
end)

T.test("crash: a tipped-over bike with a passenger throws them both (the physics path, not a call)", function()
    local sv, bike, rider = ridden()
    local p = board(sv, bike)
    sv.world.time = sv.world.time + 1
    bike.spawnTime = -10
    F.layDown(sv, bike)
    sv:run(3)
    T.ok(not rider:InVehicle(), "the rider is off")
    T.ok(not p:InVehicle(), "and so is the passenger")
end)

--------------------------------------------------------------------------
-- The child seat
--------------------------------------------------------------------------

T.test("child: a bike with the seat gets its switch as a context-menu property, and a BMX does not", function()
    local sv, world = F.server()
    kidBike(sv.env.BMX)
    local prop = sv.properties and sv.properties.bmx_childseat
    T.ok(prop, "the property is registered")
    T.eq(prop.MenuLabel, "Child seat", "labelled")
    T.eq(prop.Type, "toggle", "a toggle")
    local bmx = F.bike(sv, "bmx_base")
    local kid = F.bike(sv, classOf(sv, "kidbike"))
    local me = sv:player("Owner")
    T.ok(not prop:Filter(bmx, me), "not offered on a BMX")
    T.ok(prop:Filter(kid, me), "offered on a bike with a child seat")
    T.eq(prop:Checked(kid, me), false, "off to begin with")
end)

T.test("child: switching it on seats a second player in it, scaled down, with a smaller weight", function()
    local sv, bike, rider = ridden("kidbike")
    local prop = sv.properties.bmx_childseat
    local owner = sv:player("Owner")
    -- The server end of the property, as the engine calls it: Receive reads the
    -- entity off the wire.
    local function receive(ply)
        local net = sv.env.net
        local read = net.ReadEntity
        net.ReadEntity = function() return bike end
        local ok, err = pcall(prop.Receive, prop, 0, ply)
        net.ReadEntity = read
        T.ok(ok, tostring(err))
    end
    local p = board(sv, bike, "Kid")
    T.ok(not p:InVehicle(), "with the seat off and no pegs: nobody boards")
    receive(owner)
    T.eq(bike:GetChildSeat(), true, "switched on")
    local q = board(sv, bike, "Kid2")
    T.ok(q:InVehicle(), "and now somebody can")
    T.eq(bike:GetPaxChild(), q, "in the child seat")
    T.eq(q:GetVehicle().BMXPassenger, "child", "of the child kind")
    T.near(q._modelScale or 1, 0.6, 1e-9, "a child is small")
    T.near(bike:GetPhysicsObject():GetMass(), bike:Cfg().Chassis.mass, 1e-6, "(mass is the config's with the child)")
    local base = sv.env.BMX.ConfigFor(sv.env.BMX.Bikes.kidbike).Chassis.mass
    T.near(bike:GetPhysicsObject():GetMass(), base * 1.25, 1e-6, "a child is 0.25 of the bike's mass")
    receive(owner)
    T.eq(bike:GetChildSeat(), true, "not switched off with somebody in it")
    q:ExitVehicle()
    T.near(q._modelScale or 1, 1, 1e-9, "and full size again once off")
    receive(owner)
    T.eq(bike:GetChildSeat(), false, "switched off when empty")
end)

T.test("child: a stranger cannot switch another player's bike's child seat", function()
    local sv = F.server()
    kidBike(sv.env.BMX)
    local kid = F.bike(sv, classOf(sv, "kidbike"))
    local owner, thief = sv:player("Owner"), sv:player("Thief")
    kid.BMXOwner = owner
    T.ok(sv.env.BMX.Passenger.CanToggleChild(kid, owner), "the owner can")
    T.ok(not sv.env.BMX.Passenger.CanToggleChild(kid, thief), "a stranger cannot")
    thief._admin = true
    T.ok(sv.env.BMX.Passenger.CanToggleChild(kid, thief), "an admin can")
end)

--------------------------------------------------------------------------
-- The client
--------------------------------------------------------------------------

local function clientScene(world)
    local cl = F.client(world)
    local cb = cl:clientEntity("bmx_base")
    local pod1 = cl.makeEntity("prop_vehicle_prisoner_pod")
    local pod2 = cl.makeEntity("prop_vehicle_prisoner_pod")
    pod1:SetParent(cb)
    pod2:SetParent(cb)
    cb:SetPod(pod1)
    local rider, pax = cl:player("Rider"), cl:player("Pax")
    rider._vehicle, pax._vehicle = pod1, pod2
    cb:SetDriver(rider)
    cb._nw.PaxPegs = pax
    return cl, cb, rider, pax
end

T.test("client: a player in any other pod of the bike is a passenger, and the rider is not", function()
    local _, world = F.server()
    local cl, cb, rider, pax = clientScene(world)
    local B = cl.env.BMX
    T.ok(B.IsPassenger(pax), "the pegs' rider is a passenger")
    T.ok(not B.IsPassenger(rider), "the rider is not")
    T.eq(B.PassengerKind(pax, cb), "pegs", "which seat")
    T.ok(not B.IsPassenger(cl:player("Walker")), "nor is somebody on foot")
end)

T.test("client: the passenger's targets are the rider's shoulders and the rear pegs", function()
    local _, world = F.server()
    local cl, cb, rider, pax = clientScene(world)
    local B, E = cl.env.BMX, cl.env
    cb:SetPos(E.Vector(0, 0, 10))
    local t = B.PassengerTargets(pax, cb, "pegs", rider)
    for _, k in ipairs({ "rHand", "lHand", "rFoot", "lFoot" }) do T.ok(t[k], k .. " has a target") end
    local half = cb:Cfg().Wheel.wheelbase * 0.5
    T.near(cb:WorldToLocal(t.rFoot).x, -half, 0.01, "the right foot is on the rear axle's peg")
    T.near(cb:WorldToLocal(t.lFoot).x, -half, 0.01, "so is the left")
    T.ok(cb:WorldToLocal(t.rFoot).y * cb:WorldToLocal(t.lFoot).y < 0, "one each side")
    -- The shoulders: the rider's upper-arm bones (their own skeleton).
    local sh = rider:GetBonePosition(rider:LookupBone("ValveBiped.Bip01_R_UpperArm"))
    T.ok((t.rHand - sh):Length() < 3, "the right hand is on the rider's right shoulder")
    local none = B.PassengerTargets(pax, cb, "pegs", nil)
    T.ok(none.rHand and none.lHand, "with nobody at the bars the hands still have somewhere to go")
    local kid = B.PassengerTargets(pax, cb, "child", rider)
    T.ok(kid.rFoot.x ~= t.rFoot.x or kid.rFoot.z ~= t.rFoot.z, "the child's feet are on the footrest, not the pegs")
end)

T.test("client: a passenger is posed as one: leaning on the rider, not holding the bars", function()
    local sv, world = F.server()
    local cl, cb, rider, pax = clientScene(world)
    cl.env.hook.Run("PrePlayerDraw", pax)
    local lean = pax._bones and pax._bones["ValveBiped.Bip01_Spine2"]
    T.ok(lean and lean.y > 8, "the torso is forward over the rider: " .. tostring(lean and lean.y))
    T.eq(#cl.errors, 0, "no errors: " .. table.concat(cl.errors, " | "))
    -- The rider's own pose is the bike's, untouched by any of this.
    cl.env.hook.Run("PrePlayerDraw", rider)
    T.eq(#cl.errors, 0, "and the rider draws too: " .. table.concat(cl.errors, " | "))
end)

-- A TANDEM'S STOKER gets their hands onto their own bars and their feet onto their
-- own pedals, as the captain does. Drawn through the model, since the stoker's bars
-- and pedals come only from it (tests/lib/meshfake.lua); the seats where
-- ENT:BuildPod puts them -- a stoker's pod left unturned faces the bike's side, and
-- the IK then reaches the bars only by wringing the torso round.
T.test("client: a tandem's stoker gets their hands onto their own bars", function()
    local MF = require("lib.meshfake")
    local sv, world = F.server()
    local cl = F.client(world)
    local E, B = cl.env, cl.env.BMX
    MF.enable(cl)
    local cb = cl:clientEntity("bmx_tandem")
    cb:SetPos(E.Vector(0, 0, F.restHeight(sv)))
    -- Both seats where ENT:BuildPod puts them (BMX.SeatFor fills in the angles).
    local front = B.SeatFor(B.Vehicles.tandem, cb:Cfg(), "rider")
    local back = B.SeatFor(B.Vehicles.tandem, cb:Cfg(), "pegs")
    local pod1 = cl.makeEntity("prop_vehicle_prisoner_pod")
    local pod2 = cl.makeEntity("prop_vehicle_prisoner_pod")
    pod1:SetParent(cb)
    pod2:SetParent(cb)
    pod1:SetPos(cb:LocalToWorld(front.offset))
    pod1:SetAngles(cb:LocalToWorldAngles(front.angles))
    pod2:SetPos(cb:LocalToWorld(back.offset))
    pod2:SetAngles(cb:LocalToWorldAngles(back.angles))
    cb:SetPod(pod1)
    local rider, stoker = cl:player("Captain"), cl:player("Stoker")
    rider._vehicle, stoker._vehicle = pod1, pod2
    cb:SetDriver(rider)
    cb._nw.PaxPegs = stoker
    T.ok(MF.ready(cl, cb), "the model builds")
    for _ = 1, 40 do
        MF.draw(cl, cb)
        E.hook.Run("PrePlayerDraw", rider)
        E.hook.Run("PrePlayerDraw", stoker)
    end
    local stk = cb.ikTargetsStoker
    T.ok(stk and stk.rHand and stk.lHand, "the stoker's bars")
    for _, side in ipairs({ "R", "L" }) do
        local key = side == "R" and "rHand" or "lHand"
        local d = (B.RiderFistCentre(stoker, side) - (stk[key .. "Held"] or stk[key])):Length()
        T.between(d, 0, 3, key .. " to the stoker's grip, units")
    end
    T.eq(#cl.errors, 0, "no errors: " .. table.concat(cl.errors, " | "))
end)

T.test("client: a passenger looks where they like: the chase camera leaves their view to the pod", function()
    local sv, world = F.server()
    local cl, cb, rider, pax = clientScene(world)
    local E = cl.env
    local r = E.hook.Run("CalcView", rider, E.Vector(0, 0, 50), E.Angle(), 90)
    T.ok(r ~= nil, "the rider gets the chase camera")
    local q = E.hook.Run("CalcView", pax, E.Vector(0, 0, 50), E.Angle(), 90)
    T.eq(q, nil, "a passenger's view is the engine's: free look")
end)

T.test("client: the child seat is drawn when it is on, and only then", function()
    local sv, world = F.server()
    local cl = F.client(world)
    kidBike(cl.env.BMX)
    local cb = cl:clientEntity("bmx_kidbike")
    cb:SetPos(cl.env.Vector(0, 0, 20))
    cl.beams, cl.boxes3d = {}, 0
    cb:Draw()
    local off = #cl.beams
    cb._nw.ChildSeat = true
    cl.beams = {}
    cb:Draw()
    T.ok(#cl.beams > off, string.format("%d tubes with the seat, %d without", #cl.beams, off))
    T.eq(#cl.errors, 0, table.concat(cl.errors, " | "))
end)
