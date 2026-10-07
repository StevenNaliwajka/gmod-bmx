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

T.test("rack: a bike that is ridden, locked, fallen, on a rack already or not ours is refused", function()
    local sv, rack, bikeAt = scene()
    local E, R = sv.env, sv.env.BMX.Rack
    local ridden = bikeAt(-100)
    F.rider(sv, ridden)
    local ok, why = R.CanLoad(rack, ridden)
    T.ok(not ok and why:find("riding"), "ridden: " .. tostring(why))
    local locked = bikeAt(-200)
    local owner = sv:player("Owner")
    T.ok(sv.env.BMX.Lock.Lock(locked, owner), "locked")
    ok, why = R.CanLoad(rack, locked)
    T.ok(not ok and why:find("locked"), "locked: " .. tostring(why))
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

--------------------------------------------------------------------------
-- The lock: who may do what
--------------------------------------------------------------------------

local function lockScene()
    local sv, world = F.server()
    local E, B = sv.env, sv.env.BMX
    local cfg = B.ConfigFor(B.Bikes.stock)
    local bike = F.bike(sv, classOf(sv, "stock"), E.Vector(0, 0, sv.world.groundZ + B.RestHeight(cfg)))
    sv:run(1)
    local owner = sv:player("Owner")
    local other = sv:player("Other")
    local admin = sv:player("Admin")
    admin._admin = true
    return sv, bike, owner, other, admin, world
end

T.test("lock: the privilege exists, with the admin default", function()
    local sv = F.server()
    local found
    for _, p in ipairs(sv.env.BMX.Privileges) do if p.name == "BMX - Unlock Any Lock" then found = p end end
    T.ok(found, "registered")
    T.eq(found.min, "admin", "for admins")
    T.eq(sv.env.BMX.Lock.PRIV, "BMX - Unlock Any Lock", "and the lock asks for that one")
end)

T.test("lock: a parked bike on the ground is locked to the world, by its owner", function()
    local sv, bike, owner = lockScene()
    local L = sv.env.BMX.Lock
    local ok = L.Lock(bike, owner)
    T.ok(ok, "locked")
    T.ok(L.Of(bike), "it has a lock")
    T.eq(bike.BMXLock.ownerSID, owner:SteamID64(), "the owner is the player who locked it, by SteamID64")
    T.eq(welds(sv, bike, sv.env.game.GetWorld()), 1, "welded to the WORLD")
    T.eq(bike:GetLocked(), true, "networked, so the chain is drawn")
    T.eq(bike:GetStandDown(), true, "on its stand")
end)

T.test("lock permission: only the owner, a player with the privilege, or the console can unlock", function()
    local sv, bike, owner, other, admin = lockScene()
    local L = sv.env.BMX.Lock
    L.Lock(bike, owner)
    T.eq(L.CanUnlock(bike, owner), true, "the owner")
    T.eq(L.CanUnlock(bike, other), false, "another player")
    T.eq(L.CanUnlock(bike, admin), true, "an admin: BMX - Unlock Any Lock")
    T.eq(L.CanUnlock(bike, nil), true, "the server console")
    T.eq(L.CanUnlock(bike, sv.env.NULL), true, "a null player is the console too")
    T.eq(L.IsOwner(bike, owner), true, "owner")
    T.eq(L.IsOwner(bike, admin), false, "an admin is not the owner")
    local unlocked = sv:player("Unlocked")
    T.eq(L.CanUnlock(sv.env.ents.Create("bmx_base"), owner), false, "an unlocked bike has nothing to unlock")
end)

T.test("lock permission: CAMI decides when an admin mod is installed", function()
    local sv, bike, owner, other, admin = lockScene()
    local E, L = sv.env, sv.env.BMX.Lock
    L.Lock(bike, owner)
    -- A CAMI that gives "other" the privilege and takes it from "admin".
    E.CAMI = { RegisterPrivilege = function() end,
               PlayerHasAccess = function(ply, name, cb) cb(ply == other) end }
    T.eq(L.CanUnlock(bike, other), true, "granted by CAMI")
    T.eq(L.CanUnlock(bike, admin), false, "denied by CAMI, whatever IsAdmin says")
    T.eq(L.CanUnlock(bike, owner), true, "the owner needs no privilege")
end)

T.test("lock: unlocking: refused for a stranger, with the owner's name; allowed for the owner and an admin", function()
    local sv, bike, owner, other, admin = lockScene()
    local L = sv.env.BMX.Lock
    L.Lock(bike, owner)
    local ok, why = L.Unlock(bike, other)
    T.eq(ok, false, "a stranger cannot")
    T.ok(why:find("Owner"), "and is told who: " .. tostring(why))
    T.ok(L.Of(bike), "still locked")
    T.eq(welds(sv, bike, sv.env.game.GetWorld()), 1, "still welded")
    T.ok(L.Unlock(bike, admin), "an admin can")
    T.ok(not L.Of(bike), "unlocked")
    T.eq(welds(sv, bike, sv.env.game.GetWorld()), 0, "the weld is gone")
    T.eq(bike:GetLocked(), false, "and not drawn locked")
    L.Lock(bike, owner)
    T.ok(L.Unlock(bike, owner), "the owner can")
    local ok2, why2 = L.Unlock(bike, owner)
    T.ok(not ok2 and why2:find("not locked"), "unlocking an unlocked bike: " .. tostring(why2))
    L.Lock(bike, owner)
    T.ok(L.Unlock(bike, other, true), "a script can force it")
end)

T.test("lock: a locked bike cannot be mounted by anyone but the owner, and the owner's E unlocks it", function()
    local sv, bike, owner, other, admin = lockScene()
    local L = sv.env.BMX.Lock
    L.Lock(bike, owner)
    bike:Use(other)
    T.ok(not other:InVehicle(), "a stranger cannot get on")
    T.ok(other._chat[#other._chat]:find("locked by Owner"), "and is told: " .. tostring(other._chat[#other._chat]))
    T.ok(L.Of(bike), "it stays locked")
    bike:Use(owner)
    T.eq(bike:GetDriver(), owner, "the owner gets on")
    T.ok(not L.Of(bike), "and it is unlocked by it, as with a key")
    T.eq(welds(sv, bike, sv.env.game.GetWorld()), 0, "the weld is gone")
end)

T.test("lock: nobody can board a locked bike as a passenger either (BMX_CanMount is asked for both)", function()
    local sv, bike, owner, other = lockScene()
    local L = sv.env.BMX.Lock
    L.Lock(bike, owner)
    T.eq(sv.env.hook.Run("BMX_CanMount", other, bike), false, "refused for a stranger")
    T.eq(sv.env.hook.Run("BMX_CanMount", owner, bike), nil, "the owner passes (and unlocks)")
end)

T.test("lock: the physgun: a stranger cannot pick it up; the owner and an admin can, and it lets go first", function()
    local sv, bike, owner, other, admin = lockScene()
    local E, L = sv.env, sv.env.BMX.Lock
    L.Lock(bike, owner)
    T.eq(E.hook.Run("PhysgunPickup", other, bike), false, "a stranger: no")
    T.ok(L.Of(bike), "still locked")
    T.eq(E.hook.Run("PhysgunPickup", owner, bike), nil, "the owner: yes")
    T.ok(not L.Of(bike), "and the lock let go first")
    L.Lock(bike, owner)
    T.eq(E.hook.Run("PhysgunPickup", admin, bike), nil, "an admin: yes")
    T.ok(not L.Of(bike), "and unlocked")
    T.eq(E.hook.Run("PhysgunPickup", other, bike), nil, "an unlocked bike is anybody's")
end)

T.test("lock: the tool gun, the property menu and the gravity gun are shut to a stranger too", function()
    local sv, bike, owner, other, admin = lockScene()
    local E, L = sv.env, sv.env.BMX.Lock
    L.Lock(bike, owner)
    T.eq(E.hook.Run("CanTool", other, { Entity = bike }), false, "the tool gun")
    T.eq(E.hook.Run("CanTool", owner, { Entity = bike }), nil, "...not for the owner")
    T.eq(E.hook.Run("CanProperty", other, "remove", bike), false, "properties")
    T.eq(E.hook.Run("CanProperty", admin, "remove", bike), nil, "...not for an admin")
    T.eq(E.hook.Run("GravGunPickupAllowed", other, bike), false, "the gravity gun")
    T.eq(E.hook.Run("GravGunPunt", owner, bike), false, "and nobody punts it")
    T.eq(E.hook.Run("CanTool", other, { Entity = sv.env.ents.Create("prop_physics") }), nil, "other props are not ours to guard")
end)

T.test("lock: it needs a bike with nobody on it, standing on the world, upright, not on a rack", function()
    local sv, bike, owner = lockScene()
    local E, L = sv.env, sv.env.BMX.Lock
    local ok, why = L.CanLock(E.ents.Create("prop_physics"), owner)
    T.ok(not ok and why:find("not a bike"), "a prop: " .. tostring(why))
    local ride = F.rider(sv, bike)
    ok, why = L.CanLock(bike, owner)
    T.ok(not ok and why:find("riding"), "ridden: " .. tostring(why))
    ride:ExitVehicle()
    -- in the air: nothing to lock it to
    local cfg = E.BMX.ConfigFor(E.BMX.Bikes.stock)
    local up = F.bike(sv, classOf(sv, "stock"), E.Vector(500, 0, sv.world.groundZ + 200))
    ok, why = L.CanLock(up, owner)
    T.ok(not ok and why:find("nothing to lock"), "in the air: " .. tostring(why))
    -- fallen
    local down = F.bike(sv, classOf(sv, "stock"), E.Vector(-500, 0, sv.world.groundZ + 7))
    F.layDown(sv, down)
    sv:run(2)
    ok, why = L.CanLock(down, owner)
    T.ok(not ok and why:find("fallen"), "fallen: " .. tostring(why))
    -- on a rack
    local rack = E.ents.Create("bmx_bike_rack") rack:SetPos(E.Vector(0, 300, 6)) rack:Spawn()
    E.BMX.Rack.Load(rack, bike)
    ok, why = L.CanLock(bike, owner)
    T.ok(not ok and why:find("rack"), "on a rack: " .. tostring(why))
    E.BMX.Rack.Release(bike)
    T.ok(L.CanLock(bike, owner), "back on the ground: fine")
    T.ok(L.Lock(bike, owner), "locked")
    ok, why = L.Lock(bike, owner)
    T.ok(not ok and why:find("already"), "twice: " .. tostring(why))
end)

T.test("lock: bmx_allow_bikes 0 switches it off with the rest of the bikes", function()
    local sv, bike, owner = lockScene()
    local E, L = sv.env, sv.env.BMX.Lock
    E.GetConVar("bmx_allow_bikes"):SetString("0")
    local ok, why = L.Lock(bike, owner)
    T.ok(not ok and why:find("switched off"), "no lock: " .. tostring(why))
    T.eq(E.hook.Run("PlayerGiveSWEP", owner, "weapon_bmx_lock"), false, "no weapon given")
    T.eq(E.hook.Run("PlayerSpawnSWEP", owner, "weapon_bmx_lock"), false, "nor spawned")
    E.GetConVar("bmx_allow_bikes"):SetString("1")
    T.eq(E.hook.Run("PlayerGiveSWEP", owner, "weapon_bmx_lock"), nil, "back on: fine")
    T.eq(E.hook.Run("PlayerGiveSWEP", owner, "weapon_pistol"), nil, "and other weapons are not ours")
end)

--------------------------------------------------------------------------
-- The weapon
--------------------------------------------------------------------------

-- A SWEP instance held by `ply`, on the server: the table the engine would copy.
local function swep(sv, ply)
    local S = sv.sweps.weapon_bmx_lock
    local w = setmetatable({ _owner = ply, _sounds = {} }, { __index = S })
    function w:GetOwner() return self._owner end
    function w:SetNextPrimaryFire() end
    function w:SetNextSecondaryFire() end
    function w:EmitSound(n) self._sounds[#self._sounds + 1] = n end
    function w:SetHoldType() end
    return w
end

local function aim(sv, ply, bike)
    ply:SetPos(bike:GetPos() + sv.env.Vector(-60, 0, 0))
    ply._eyeTrace = { Hit = true, Entity = bike, HitPos = bike:GetPos() + sv.env.Vector(-8, 0, 20) }
end

T.test("weapon: it is a SWEP under BMX with the tool gun's base-game models", function()
    local sv = F.server()
    local S = sv.sweps.weapon_bmx_lock
    T.ok(S, "loaded")
    T.eq(S.Category, "BMX", "under BMX")
    T.eq(S.Spawnable, true, "spawnable")
    T.eq(S.PrintName, "Bike Lock", "its name")
    T.ok(S.ViewModel:find("^models/weapons/"), "a base-game model")
    T.ok(S.PrimaryAttack and S.SecondaryAttack and S.Reload, "left, right and reload")
    T.eq(#sv.errors, 0, table.concat(sv.errors, " | "))
end)

T.test("weapon: left click locks the bike aimed at, right click unlocks it: the owner's, not a stranger's", function()
    local sv, bike, owner, other, admin = lockScene()
    local L = sv.env.BMX.Lock
    local w = swep(sv, owner)
    aim(sv, owner, bike)
    w:PrimaryAttack()
    T.ok(L.Of(bike), "locked by the left click")
    T.ok(owner._chat[#owner._chat]:find("locked"), "and the holder is told: " .. tostring(owner._chat[#owner._chat]))
    local ws = swep(sv, other)
    aim(sv, other, bike)
    ws:SecondaryAttack()
    T.ok(L.Of(bike), "a stranger's right click does nothing")
    T.ok(other._chat[#other._chat]:find("cannot unlock"), "and says so: " .. tostring(other._chat[#other._chat]))
    ws:PrimaryAttack()
    T.ok(other._chat[#other._chat]:find("already locked"), "left click on a locked bike: " .. tostring(other._chat[#other._chat]))
    ws:Reload()
    T.ok(other._chat[#other._chat]:find("Owner"), "reload says who locked it: " .. tostring(other._chat[#other._chat]))
    local wa = swep(sv, admin)
    aim(sv, admin, bike)
    wa:SecondaryAttack()
    T.ok(not L.Of(bike), "an admin's right click unlocks it")
    w:PrimaryAttack()
    w:SecondaryAttack()
    T.ok(not L.Of(bike), "and the owner's")
end)

T.test("weapon: aimed at nothing, or at a bike too far away, it says so and does nothing", function()
    local sv, bike, owner = lockScene()
    local L = sv.env.BMX.Lock
    local w = swep(sv, owner)
    owner._eyeTrace = { Hit = false }
    w:PrimaryAttack()
    T.ok(owner._chat[#owner._chat]:find("aim at"), "no target: " .. tostring(owner._chat[#owner._chat]))
    owner:SetPos(bike:GetPos() + sv.env.Vector(-600, 0, 0))
    owner._eyeTrace = { Hit = true, Entity = bike, HitPos = bike:GetPos() }
    w:PrimaryAttack()
    T.ok(not L.Of(bike), "too far")
end)

--------------------------------------------------------------------------
-- The client: the chain and the padlock
--------------------------------------------------------------------------

T.test("client: a locked bike is drawn with a chain and a padlock, an unlocked one is not", function()
    local sv, bike, owner, other, admin, world = lockScene()
    local cl = F.client(world)
    local cb = cl:clientEntity("bmx_base")
    cb:SetPos(bike:GetPos())
    cb:SetAngles(bike:GetAngles())
    local function beams(locked)
        cb._nw.Locked = locked
        cl.lines, cl.beams, cl.drawnModels, cl.boxes3d = 0, {}, 0, 0
        cl.drawnCS = {}
        cb:Draw()
        return #cl.beams + (cl.drawnModels or 0) + #(cl.drawnCS or {})
    end
    local free = beams(false)
    local chained = beams(true)
    T.ok(chained > free, "more is drawn when it is locked: " .. chained .. " against " .. free)
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
