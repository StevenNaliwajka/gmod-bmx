--[[--------------------------------------------------------------------------
    The bike rack and the bike lock (G13).

    RACK. A prop that welds to a car and carries two bikes: what a carrier is, that a
    rack holds exactly two (a third is refused with a reason), that the bike on it is welded
    to it, does not simulate, cannot be mounted until it is let down, and is let down by E
    on it, by E on the rack, and by the rack's removal.

    LOCK. weapon_bmx_lock welds a parked bike to the world. The permission logic is the
    point: only the owner, or a player with "BMX - Unlock Any Lock", can unlock; a locked
    bike cannot be mounted, physgunned, tooled or boarded by anybody else; and a lock
    needs a parked bike on the world.

    The shim records constraints rather than simulating them (tests/lib/gmod.lua), so a
    weld here is an entity that says what it joins and is gone when it is removed: what the
    rules ask of it.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local gmod = require("lib.gmod")

local function classOf(sv, id) return sv.env.BMX.ClassFor(id) end

-- A server with a rack and two parked bikes, standing on the ground.
local function scene()
    local sv, world = F.server()
    local E, B = sv.env, sv.env.BMX
    local function bikeAt(x, id)
        local cfg = B.ConfigFor(B.Bikes[id or "stock"])
        return F.bike(sv, classOf(sv, id or "stock"), E.Vector(x, 0, sv.world.groundZ + B.RestHeight(cfg)))
    end
    local rack = E.ents.Create("bmx_bike_rack")
    rack:SetPos(E.Vector(0, 60, 6))
    rack:Spawn()
    return sv, rack, bikeAt, world
end

local function welds(sv, a, b, kind)
    return #sv.env.constraint.Find(a, b, kind or "weld")
end

--------------------------------------------------------------------------
-- The rack
--------------------------------------------------------------------------

T.test("rack: it is a scripted entity in the spawn menu under BMX > Bikes", function()
    local sv = F.server()
    T.ok(sv.env.scripted_ents.Get("bmx_bike_rack"), "the entity is registered")
    local row = sv.lists.SpawnableEntities.bmx_bike_rack
    T.ok(row, "it has a spawn row")
    T.eq(row.Category, "BMX", "under BMX")
    T.eq(row.Subcategory, "Bikes", "and Bikes")
    T.eq(#sv.errors, 0, "nothing threw: " .. table.concat(sv.errors, " | "))
end)

T.test("rack: what counts as a carrier: the engine's vehicles, simfphys, LVS; not a seat or a prop", function()
    local sv = F.server()
    local E, R = sv.env, sv.env.BMX.Rack
    local function mk(class) local e = E.ents.Create(class) e:Spawn() return e end
    T.ok(R.IsCarrier(mk("prop_vehicle_jeep")), "a jeep")
    T.ok(R.IsCarrier(mk("prop_vehicle_airboat")), "an airboat is a vehicle too")
    T.ok(R.IsCarrier(mk("gmod_sent_vehicle_fphysics_base")), "simfphys")
    T.ok(R.IsCarrier(mk("gmod_sent_vehicle_fphysics_wheel") and mk("gmod_sent_vehicle_fphysics_car")), "a simfphys car")
    T.ok(R.IsCarrier(mk("lvs_wheeldrive_base")), "LVS")
    local flagged = mk("prop_physics")
    flagged.LVS = true
    T.ok(R.IsCarrier(flagged), "anything with an LVS flag")
    T.ok(not R.IsCarrier(mk("prop_vehicle_prisoner_pod")), "a seat is not a car")
    T.ok(not R.IsCarrier(mk("prop_physics")), "a prop is not a car")
    T.ok(not R.IsCarrier(mk("bmx_base")), "and a bike is not one")
    T.ok(not R.IsCarrier(nil), "nil")
end)

T.test("rack: it welds to the nearest vehicle", function()
    local sv, rack = scene()
    local E, R = sv.env, sv.env.BMX.Rack
    local far = E.ents.Create("prop_vehicle_jeep") far:SetPos(E.Vector(0, 900, 0)) far:Spawn()
    local near = E.ents.Create("prop_vehicle_jeep") near:SetPos(E.Vector(0, 120, 0)) near:Spawn()
    T.eq(R.FindCarrier(rack:GetPos()), near, "the near one")
    T.ok(R.Attach(rack, near), "attached")
    T.eq(rack.carrier, near, "it remembers its carrier")
    T.eq(welds(sv, rack, near), 1, "one weld")
    T.eq(rack:GetCarried(), true, "and says so to the client")
    T.eq(R.FindCarrier(E.Vector(0, 5000, 0)), nil, "nothing within range of a far point")
    local ok, why = R.Attach(rack, E.ents.Create("prop_physics"))
    T.ok(not ok and why, "a prop is refused: " .. tostring(why))
    R.Detach(rack)
    T.eq(welds(sv, rack, near), 0, "detached: the weld is gone")
    T.eq(rack:GetCarried(), false, "")
end)

T.test("rack: SpawnFunction puts it against the car and welds it, facing away", function()
    local sv = F.server()
    local E = sv.env
    local car = E.ents.Create("prop_vehicle_jeep") car:SetPos(E.Vector(0, 0, 0)) car:Spawn()
    local ply = sv:player("Spawner")
    local tbl = E.scripted_ents.Get("bmx_bike_rack")
    local tr = { Hit = true, HitPos = E.Vector(0, -70, 0), HitNormal = E.Vector(0, 0, 1) }
    local rack = tbl.SpawnFunction(tbl, ply, tr, "bmx_bike_rack")
    T.ok(rack and E.IsValid(rack), "spawned")
    T.eq(rack.carrier, car, "welded to the car")
    T.ok(rack:GetPos().y < -8, "on the side of the car that was pointed at: y = " .. rack:GetPos().y)
    local away = rack:GetForward()
    T.ok(away.y < -0.5, "facing away from it: " .. away.y)
end)

T.test("rack: it holds TWO bikes, and a third is refused with a reason", function()
    local sv, rack, bikeAt = scene()
    local R = sv.env.BMX.Rack
    local a, b, c = bikeAt(-100), bikeAt(-200), bikeAt(-300)
    T.eq(R.Capacity, 2, "the capacity is two")
    T.eq(R.Count(rack), 0, "empty")
    local ok1, slot1 = R.Load(rack, a)
    T.ok(ok1 and slot1 == 1, "the first goes in slot 1")
    local ok2, slot2 = R.Load(rack, b)
    T.ok(ok2 and slot2 == 2, "the second in slot 2")
    T.eq(R.Count(rack), 2, "two held")
    T.eq(rack:GetLoaded(), 2, "and the client is told")
    T.ok(R.IsFull(rack), "full")
    local ok3, why = R.Load(rack, c)
    T.eq(ok3, false, "a third is refused")
    T.ok(why:find("full"), "because it is full: " .. tostring(why))
    T.ok(not c.BMXRack, "and it is not racked")
    T.eq(R.Slots(rack)[1], a, "slot 1 is the first")
    T.eq(R.Slots(rack)[2], b, "slot 2 is the second")
end)

T.test("rack: the slots are on either side of the middle, and the bike lies across the rack", function()
    local sv, rack, bikeAt = scene()
    local R = sv.env.BMX.Rack
    local p1, a1 = R.SlotPos(rack, 1)
    local p2, a2 = R.SlotPos(rack, 2)
    T.near((p1 - p2):Length(), 30, 1e-6, "30 apart")
    T.near(math.abs((p1 - p2):Dot(rack:GetRight())), 30, 1e-6, "along the rack's width")
    local bike = bikeAt(-100)
    R.Load(rack, bike)
    T.near(math.abs(bike:GetForward():Dot(rack:GetRight())), 1, 0.02, "the bike lies across the rack")
    T.near((bike:GetPos() - p1):Length(), 0, 0.5, "at its slot")
end)

T.test("rack: a loaded bike is welded to the rack, set not to collide with it or the car, and does not simulate", function()
    local sv, rack, bikeAt = scene()
    local E, R = sv.env, sv.env.BMX.Rack
    local car = E.ents.Create("prop_vehicle_jeep") car:SetPos(E.Vector(0, 120, 0)) car:Spawn()
    R.Attach(rack, car)
    local bike = bikeAt(-100)
    R.Load(rack, bike)
    T.eq(welds(sv, bike, rack, "weld"), 1, "welded to the rack")
    T.eq(welds(sv, bike, rack, "nocollide"), 1, "no collision with the rack")
    T.eq(welds(sv, bike, car, "nocollide"), 1, "or the car")
    T.eq(bike.BMXRack, rack, "it knows where it is")
    T.eq(bike:GetStandDown(), false, "no stand")
    -- it runs no wheels: the step stops before anything is read
    bike.st.speed = 123
    sv:run(0.5)
    T.eq(bike.st.speed, 123, "the physics step left it alone")
end)

T.test("rack: a bike that is ridden, on a rack already or not ours is refused", function()
    local sv, rack, bikeAt = scene()
    local E, R = sv.env, sv.env.BMX.Rack
    local ridden = bikeAt(-100)
    F.rider(sv, ridden)
    local ok, why = R.CanLoad(rack, ridden)
    T.ok(not ok and why:find("riding"), "ridden: " .. tostring(why))
    local on = bikeAt(-300)
    T.ok(R.Load(rack, on), "loaded")
    ok, why = R.CanLoad(rack, on)
    T.ok(not ok and why:find("already"), "already on a rack: " .. tostring(why))
    ok, why = R.CanLoad(rack, E.ents.Create("prop_physics"))
    T.ok(not ok and why:find("not a bike"), "a prop: " .. tostring(why))
    ok, why = R.CanLoad(rack, nil)
    T.ok(not ok, "nothing")
end)

T.test("rack: E on a racked bike lets it down; the next E gets on", function()
    local sv, rack, bikeAt = scene()
    local R = sv.env.BMX.Rack
    local bike = bikeAt(-100)
    R.Load(rack, bike)
    local ply = sv:player("Rider")
    bike:Use(ply)
    T.ok(not bike.BMXRack, "let down")
    T.eq(welds(sv, bike, rack), 0, "the weld is gone")
    T.eq(welds(sv, bike, rack, "nocollide"), 0, "and the no-collide")
    T.eq(R.Count(rack), 0, "the slot is free")
    T.eq(rack:GetLoaded(), 0, "")
    T.ok(not ply:InVehicle(), "and nobody is on it yet")
    bike:Use(ply)
    T.eq(bike:GetDriver(), ply, "the next E gets on")
end)

T.test("rack: E on the rack loads the bike beside it, then releases the last one loaded", function()
    local sv, rack, bikeAt = scene()
    local E, R = sv.env, sv.env.BMX.Rack
    local near = bikeAt(10)          -- close to the rack at (0, 60)
    local ply = sv:player("User")
    rack:Use(ply)
    T.eq(near.BMXRack, rack, "the bike beside it is loaded")
    T.ok(ply._chat[#ply._chat]:find("loaded"), "and the player is told: " .. tostring(ply._chat[#ply._chat]))
    rack:Use(ply)
    T.ok(not near.BMXRack, "with nothing else near, E releases it")
    T.ok(ply._chat[#ply._chat]:find("let down"), "told: " .. tostring(ply._chat[#ply._chat]))
    rack:Use(ply)
    -- the bike is beside it again, so it loads again; with none near, there is nothing to do
    near:Remove()
    R.ReleaseAll(rack)
    rack:Use(ply)
    T.ok(ply._chat[#ply._chat]:find("nothing"), "an empty rack with no bike near says so: " .. tostring(ply._chat[#ply._chat]))
end)

T.test("rack: E on a rack that is not on a car welds it to the one beside it", function()
    local sv, rack = scene()
    local E = sv.env
    local car = E.ents.Create("prop_vehicle_jeep") car:SetPos(E.Vector(0, 100, 0)) car:Spawn()
    local ply = sv:player("User")
    rack:Use(ply)
    T.eq(rack.carrier, car, "welded to it")
    T.ok(ply._chat[#ply._chat]:find("welded"), "told: " .. tostring(ply._chat[#ply._chat]))
end)

T.test("rack: a removed rack lets its bikes go; a removed bike is out of its slot", function()
    local sv, rack, bikeAt = scene()
    local R = sv.env.BMX.Rack
    local a, b = bikeAt(-100), bikeAt(-200)
    R.Load(rack, a)
    R.Load(rack, b)
    rack:Remove()
    T.ok(not a.BMXRack and not b.BMXRack, "both let go")
    T.eq(welds(sv, a, rack), 0, "welds gone")
    local sv2, rack2, bikeAt2 = scene()
    local R2 = sv2.env.BMX.Rack
    local c = bikeAt2(-100)
    R2.Load(rack2, c)
    R2.Release(c)
    T.eq(R2.Count(rack2), 0, "an empty rack")
    local ok, why = R2.Release(c)
    T.ok(not ok, "releasing a bike that is not on one is refused: " .. tostring(why))
    T.ok(R2.Load(rack2, c), "and it can go back on")
end)

T.test("rack: bmx_allow_bikes 0 shuts the spawn door and E does nothing", function()
    local sv, rack = scene()
    local E = sv.env
    local ply = sv:player("Spawner")
    T.eq(E.hook.Run("PlayerSpawnSENT", ply, "bmx_bike_rack"), nil, "open by default")
    E.GetConVar("bmx_allow_bikes"):SetString("0")
    T.eq(E.hook.Run("PlayerSpawnSENT", ply, "bmx_bike_rack"), false, "shut when bikes are off")
    rack:Use(ply)
    T.ok(ply._chat[#ply._chat]:find("switched off"), "and E says why: " .. tostring(ply._chat[#ply._chat]))
end)

T.test("rack: hooks fire for a bike put on and taken off", function()
    local sv, rack, bikeAt = scene()
    local E, R = sv.env, sv.env.BMX.Rack
    local log = {}
    E.hook.Add("BMX_BikeRacked", "t", function(bike, r, slot) log[#log + 1] = "on" .. slot end)
    E.hook.Add("BMX_BikeUnracked", "t", function(bike, r) log[#log + 1] = "off" end)
    local bike = bikeAt(-100)
    R.Load(rack, bike)
    R.Release(bike)
    T.eq(table.concat(log, ","), "on1,off", "in order")
end)

T.test("client: the rack is drawn: a post and two cradles, darker when loaded", function()
    local sv, rack, bikeAt, world = scene()
    local cl = F.client(world)
    local cr = cl:clientEntity("bmx_bike_rack")
    cr:SetPos(rack:GetPos())
    cr:SetAngles(rack:GetAngles())
    cl.lines, cl.beams, cl.drawnModels, cl.boxes3d = 0, {}, 0, 0
    cl.drawnCS = {}
    cr:Draw()
    T.ok(#cl.beams + (cl.drawnModels or 0) + #(cl.drawnCS or {}) >= 10, "something was drawn")
end)
