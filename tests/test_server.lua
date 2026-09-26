--[[--------------------------------------------------------------------------
    The server's lifecycle: getting on and off, what other players may do to a
    bike, the duplicator, the spawn command, and per-bike physics.

    These are the things a public server finds first, and most of them fail
    SILENTLY -- a bike the duplicator skips, a command that bypasses the spawn
    limit, a rider stranded on a deleted bike -- so each is asserted directly.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

T.test("mounting binds the rider, and the bike stops colliding with them", function()
    local sv = F.server()
    local bike = F.bike(sv)
    local ply = F.rider(sv, bike)
    T.ok(bike:GetDriver() == ply, "driver")
    T.ok(ply.BMXBike == bike, "back-reference")
    local E = sv.env
    T.eq(E.hook.Run("ShouldCollide", bike, ply), false, "rider passes through the hull")
    T.eq(E.hook.Run("ShouldCollide", ply, bike), false, "either argument order")
    T.eq(E.hook.Run("ShouldCollide", bike, bike:GetPod()), false, "so does the seat")
    local other = sv:player("Other")
    T.eq(E.hook.Run("ShouldCollide", bike, other), nil, "anyone else collides normally")
    local filtered = false
    for _, e in ipairs(bike.traceFilter) do if e == ply then filtered = true end end
    T.ok(filtered, "the wheel traces ignore the rider, or the bike rides on them")
end)

T.test("each rider gets fresh input: no half-held brake handed on", function()
    local sv = F.server()
    local bike = F.bike(sv)
    local a = F.rider(sv, bike)
    bike.input.brakeRear, bike.hopHeld = 1, true
    a:ExitVehicle()
    T.eq(bike.input.brakeRear, 0, "cleared on dismount")
    local b = F.rider(sv, bike, { name = "B" })
    T.eq(bike.input.brakeRear, 0, "and the next rider starts neutral")
    T.ok(not bike.hopHeld, "no inherited hop preload")
    T.ok(bike:GetDriver() == b, "B is driving")
end)

T.test("dying or leaving the server lets go of the bike", function()
    for _, ev in ipairs({ "PlayerDeath", "PlayerDisconnected" }) do
        local sv = F.server()
        local bike = F.bike(sv)
        local ply = F.rider(sv, bike)
        sv.env.hook.Run(ev, ply)
        T.ok(not sv.env.IsValid(bike:GetDriver()), ev .. " clears the driver")
        T.eq(ply.BMXBike, nil, ev .. " clears the back-reference")
    end
end)

T.test("deleting a bike under its rider does not strand them", function()
    local sv = F.server()
    local bike = F.bike(sv)
    local ply = F.rider(sv, bike)
    local pod = bike:GetPod()
    bike:Remove()
    T.ok(not sv.env.IsValid(pod), "the seat goes with the bike")
    T.ok(not sv.env.IsValid(ply:GetVehicle()), "the rider is out of the vehicle")
    T.eq(ply.BMXBike, nil, "and not bound to a dead bike")
end)

T.test("nobody can physgun, gravgun or punt a bike with a rider on it", function()
    local sv = F.server()
    local E = sv.env
    local bike = F.bike(sv)
    local stranger = sv:player("Stranger")
    T.eq(E.hook.Run("PhysgunPickup", stranger, bike), nil, "an EMPTY bike picks up normally")
    T.eq(E.hook.Run("GravGunPickupAllowed", stranger, bike), nil, "gravgun too")
    F.rider(sv, bike)
    T.eq(E.hook.Run("PhysgunPickup", stranger, bike), false, "physgun refused while ridden")
    T.eq(E.hook.Run("GravGunPickupAllowed", stranger, bike), false, "gravgun refused")
    T.eq(E.hook.Run("GravGunPunt", stranger, bike), false, "punt refused")
    T.eq(E.hook.Run("PhysgunPickup", stranger, bike:GetPod()), false, "the seat, never")
end)

T.test("a bike survives the duplicator with exactly one seat", function()
    local sv = F.server()
    local E = sv.env
    local bike = F.bike(sv)
    T.ok(bike:GetPod().DoNotDuplicate, "the seat is excluded from dupes")
    local copy = E.duplicator.Copy(bike)
    local pasted = E.duplicator.Paste(sv:player("Builder"), { [bike:EntIndex()] = copy }, {})
    local nb = pasted[bike:EntIndex()]
    T.ok(E.IsValid(nb), "pasted")
    T.eq(nb:GetClass(), "bmx_base", "as a bike")
    T.ok(nb:AssertBuilt(), "fully built")
    local seats = 0
    for _, e in ipairs(E.ents.FindByClass("prop_vehicle_prisoner_pod")) do
        if e:GetParent() == nb then seats = seats + 1 end
    end
    T.eq(seats, 1, "one seat on the pasted bike")
end)

T.test("a bike registered after load gets its class, and is duplicatable", function()
    local sv = F.server()
    local B, E = sv.env.BMX, sv.env
    B.RegisterBike("late", { printName = "Late", physics = { Chassis = { mass = 90 } } })
    T.eq(B.ClassFor("late"), "bmx_late", "class name")
    T.ok(E.scripted_ents.GetStored("bmx_late"), "the class exists now, not on a drained queue")
    T.ok(sv.dupe.bmx_late, "and the duplicator knows it")
    local e = F.bike(sv, "bmx_late")
    T.ok(e:AssertBuilt(), "it spawns fully built")
    T.eq(e:GetPhysicsObject():GetMass(), 90, "with its own mass")
end)

T.test("per-bike physics reach the simulation, and leave the stock bike alone", function()
    local sv = F.server()
    local B = sv.env.BMX
    B.RegisterBike("big", { physics = { Wheel = { radius = 13, wheelbase = 45 },
                                        Chassis = { mass = 100 } } })
    local big, stock = F.bike(sv, "bmx_big"), F.bike(sv)
    local fb, rb = F.wheels(big)
    T.near(fb.mount.x - rb.mount.x, 45, 1e-9, "wheel mounts at the bike's wheelbase")
    T.eq(big:GetPhysicsObject():GetMass(), 100, "mass")
    T.eq(stock:Cfg().Wheel.radius, 10, "stock untouched")
    T.ok(stock:Cfg() == B.Config, "stock still shares the base by reference")
    T.eq(big:Cfg().Drive.crankTorque, B.Config.Drive.crankTorque, "unset fields from the base")
end)

T.test("live tuning reaches a bike with overrides, except in the fields it overrides", function()
    local sv = F.server()
    local B = sv.env.BMX
    B.RegisterBike("grippy", { physics = { Wheel = { grip = 2.0 } } })
    local e = F.bike(sv, "bmx_grippy")
    sv.env.GetConVar("bmx_spring"):SetString("9000")
    sv.env.GetConVar("bmx_grip"):SetString("0.5")
    sv:run(0.1)             -- the bike's Think applies convars
    T.eq(e:Cfg().Wheel.spring, 9000, "a convar reaches a bike with overrides")
    T.eq(e:Cfg().Wheel.grip, 2.0, "but an explicit override wins")
end)

T.test("an invalid physics override is a loud error at registration", function()
    local sv = F.server()
    sv.env.BMX.RegisterBike("typo", { physics = { Wheel = { raduis = 12 } } })
    T.ok(#sv.errors > 0 and sv.errors[1]:find("raduis"), "reported: " .. tostring(sv.errors[1]))
end)

-- A player looking at the ground in front of them.
local function looker(sv, name)
    local E = sv.env
    local ply = sv:player(name or "Spawner")
    ply._eyeTrace = { Hit = true, HitPos = E.Vector(100, 0, 0), HitNormal = E.Vector(0, 0, 1) }
    return ply
end

T.test("bmx_spawn spawns a bike where you look, with undo", function()
    local sv = F.server()
    local ply = looker(sv)
    sv:command("bmx_spawn", ply)
    local bikes = sv.env.ents.FindByClass("bmx_base")
    T.eq(#bikes, 1, "one bike")
    T.ok(bikes[1]:AssertBuilt(), "built")
    T.eq(#sv.undo, 1, "undoable")
    T.ok(sv.undo[1].ents[1] == bikes[1] and sv.undo[1].ply == ply, "for that player")
end)

T.test("bmx_spawn asks the gamemode first, as the spawn menu does", function()
    local sv = F.server()
    local ply = looker(sv)
    local asked, counted = nil, nil
    function sv.gm:PlayerSpawnSENT(p, class) asked = class return false end
    function sv.gm:PlayerSpawnedSENT(p, e) counted = e end
    sv:command("bmx_spawn", ply)
    T.eq(asked, "bmx_base", "PlayerSpawnSENT was consulted")
    T.eq(#sv.env.ents.FindByClass("bmx_base"), 0, "and its veto held")

    function sv.gm:PlayerSpawnSENT() return true end
    sv.world.time = sv.world.time + 5
    sv:command("bmx_spawn", ply)
    T.ok(counted, "PlayerSpawnedSENT told about the bike, so the limit counts it")
end)

T.test("bmx_spawn cannot be spammed", function()
    local sv = F.server()
    local ply = looker(sv)
    for _ = 1, 10 do sv:command("bmx_spawn", ply) end
    T.eq(#sv.env.ents.FindByClass("bmx_base"), 1, "ten in one tick make one bike")
    sv:run(1.1)
    sv:command("bmx_spawn", ply)
    T.eq(#sv.env.ents.FindByClass("bmx_base"), 2, "a second after the cooldown")
end)

T.test("bmx_spawn refuses an unknown bike and a far-away aim, and says why", function()
    local sv = F.server()
    local ply = looker(sv)
    sv:command("bmx_spawn", ply, "nope")
    T.ok(ply._chat and ply._chat[1]:find("no such bike"), "unknown bike")
    ply._eyeTrace.HitPos = sv.env.Vector(5000, 0, 0)
    sv.world.time = sv.world.time + 5
    sv:command("bmx_spawn", ply)
    T.ok(ply._chat[2] and ply._chat[2]:find("within 400"), "too far")
    T.eq(#sv.env.ents.FindByClass("bmx_base"), 0, "nothing spawned")
end)

T.test("bmx_test is refused while humans are connected", function()
    local sv = F.server()
    local admin = sv:player("Admin", { superadmin = true })
    sv:player("Someone")
    sv:command("bmx_test", admin)
    local refused = false
    for _, s in ipairs(admin._chat or {}) do if s:find("refusing") then refused = true end end
    T.ok(refused, "the harness never crashes bikes under real players")
    local p = sv:player("Rando")
    sv:command("bmx_test_abort", p)     -- not superadmin: silently ignored
end)

T.test("the tuning self-test and config dump run without a client", function()
    local sv = F.server()
    local ply = sv:player("Tuner")
    sv:command("bmx_selftest", ply)
    sv:run(0.2)
    local joined = table.concat(ply._chat or {}, "\n")
    T.ok(joined:find("IMPULSE %(expected%)"), "the shim is impulse-semantics: " .. joined)
end)
