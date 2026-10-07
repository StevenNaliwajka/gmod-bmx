--[[--------------------------------------------------------------------------
    The bike rental machine (sh_rental.lua, sv_rental.lua, cl_rental.lua,
    entities/bmx_rental): E opens its window, a click puts the player on what
    they picked in front of the machine, for free, one rental each, and an
    abandoned rental goes back by itself.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local gmod = require("lib.gmod")

-- A machine at the origin facing +X, and a player standing in front of it.
local function scene()
    local sv, world = F.server()
    local E = sv.env
    local m = E.ents.Create("bmx_rental")
    m:SetPos(E.Vector(0, 0, sv.world.groundZ + 48.3))   -- the model's origin is its middle
    m:SetAngles(E.Angle(0, 0, 0))
    m:Spawn()
    local ply = sv:player("Renter")
    ply:SetPos(E.Vector(90, 0, sv.world.groundZ))
    return sv, m, ply, world
end

local function rentals(sv)
    local n = 0
    for e in pairs(sv.env.BMX.Rental.Out) do if e:IsValid() then n = n + 1 end end
    return n
end

local function later(sv, s) sv.world.time = sv.world.time + (s or 3) end

T.test("rental: the machine is a scripted entity a map can place, not a spawn-menu row", function()
    local sv = F.server()
    local t = sv.env.scripted_ents.Get("bmx_rental")
    T.ok(t, "registered")
    T.ok(not t.Spawnable, "not in the Q menu: maps and admins place it")
    T.ok(not (sv.lists.SpawnableEntities or {}).bmx_rental, "no menu row")
    T.eq(#sv.errors, 0, "nothing threw: " .. table.concat(sv.errors, " | "))
end)

T.test("rental: E on the machine opens its window on that player's client", function()
    local sv, m, ply, world = scene()
    local cl = F.client(world)
    local before = #sv.world.wire
    m:Use(ply)
    local msg = sv.world.wire[#sv.world.wire]
    T.ok(#sv.world.wire == before + 1 and msg.name == "bmx_rental_open", "the open message")
    T.eq(msg.to, ply, "to the player who pressed E")
    local opened
    cl.env.BMX.Rental.OpenWindow = function(machine) opened = machine end
    cl:deliver(msg)
    T.eq(opened, m, "the client opens the window for that machine")
end)

T.test("rental: a pick puts the player on that vehicle, in front of the machine, owned by them", function()
    local sv, m, ply = scene()
    local E = sv.env
    local bike = E.BMX.Rental.Rent(ply, m, "stock")
    T.ok(bike and bike:IsValid(), "a bike")
    T.eq(bike:GetClass(), "bmx_base", "the one picked")
    T.ok(bike:GetPos().x > m:OBBMaxs().x, "in front of the machine's face")
    T.near(bike:GetAngles().y, 90, 1e-6, "lying across the machine's front")
    T.ok(bike:GetPos().z > sv.world.groundZ and bike:GetPos().z < sv.world.groundZ + 40,
        "on the floor the machine stands on, not under it or in the air")
    T.eq(ply:GetVehicle(), bike:GetPod(), "and the player is on it")
    T.eq(bike.BMXOwner, ply, "theirs")
    T.eq(ply.BMXRental, bike, "remembered as their rental")
end)

T.test("rental: the window's click goes over the wire to the same door", function()
    local sv, m, ply, world = scene()
    local cl = F.client(world)
    local before = #sv.world.wire
    cl.env.net.Start("bmx_rental_rent")
    cl.env.net.WriteEntity(m)
    cl.env.net.WriteString("stock")
    cl.env.net.SendToServer()
    sv.localPlayer = ply
    for i = before + 1, #sv.world.wire do
        if sv.world.wire[i].name == "bmx_rental_rent" then sv:deliver(sv.world.wire[i]) end
    end
    T.ok(ply.BMXRental and ply.BMXRental:IsValid(), "rented")
end)

T.test("rental: one each -- renting again returns the last one", function()
    local sv, m, ply = scene()
    local R = sv.env.BMX.Rental
    local first = R.Rent(ply, m, "stock")
    ply:ExitVehicle()
    later(sv)
    local ids = sv.env.BMX.BikeIDs()
    local other = ids[1] == "stock" and ids[2] or ids[1]
    local second = R.Rent(ply, m, other)
    T.ok(second and second:IsValid(), "the second")
    T.ok(not first:IsValid(), "the first went back")
    T.eq(rentals(sv), 1, "one out")
    local friend = sv:player("Friend")
    friend:SetPos(m:GetPos() + sv.env.Vector(60, 30, 0))
    T.ok(R.Rent(friend, m, "stock"), "someone else gets their own")
    T.eq(rentals(sv), 2, "two out")
end)

T.test("rental: refused from afar, on a vehicle, too fast, for junk, a hidden vehicle, a veto or a switch", function()
    local sv, m, ply = scene()
    local E, R = sv.env, sv.env.BMX.Rental
    local far = sv:player("Far")
    far:SetPos(E.Vector(2000, 0, 0))
    T.ok(not R.Rent(far, m, "stock"), "too far from the machine")
    T.ok(table.concat(far._chat or {}, "\n"):find("walk up", 1, true), "and told why")
    T.ok(not R.Rent(ply, m, "banana"), "no such vehicle")
    for id, def in pairs(E.BMX.Vehicles) do
        if def.hidden then T.ok(not R.Rent(ply, m, id), "hidden " .. id) end
    end
    T.ok(not R.Rent(ply, E.ents.Create("prop_physics"), "stock"), "not a machine")

    E.hook.Add("BMX_CanSpawn", "test", function() return false end)
    later(sv)
    T.ok(not R.Rent(ply, m, "stock"), "the gamemode said no")
    E.hook.Remove("BMX_CanSpawn", "test")

    E.GetConVar("bmx_allow_bikes"):SetString("0")
    later(sv)
    T.ok(not R.Rent(ply, m, "stock"), "bikes switched off")
    E.GetConVar("bmx_allow_bikes"):SetString("1")

    later(sv)
    T.ok(R.Rent(ply, m, "stock"), "a good one")
    T.ok(not R.Rent(ply, m, "stock"), "already on it")
    ply:ExitVehicle()
    T.ok(not R.Rent(ply, m, "stock"), "again in the same instant is too fast")
    T.eq(rentals(sv), 1, "still one")
end)

T.test("rental: sandbox's spawn limit does not apply: the machine pays", function()
    local sv, m, ply = scene()
    sv.gm.PlayerSpawnSENT = function() return false end
    T.ok(sv.env.BMX.Rental.Rent(ply, m, "stock"), "rented anyway")
end)

T.test("rental: an empty rental goes back after a while, a ridden or locked one does not", function()
    local sv, m, ply = scene()
    local R = sv.env.BMX.Rental
    local bike = R.Rent(ply, m, "stock")
    later(sv, R.IDLE * 2)
    R.Sweep()
    T.ok(bike:IsValid(), "ridden: kept")
    ply:ExitVehicle()
    R.Sweep()
    later(sv, R.IDLE - 5)
    R.Sweep()
    T.ok(bike:IsValid(), "not empty for long enough yet")
    later(sv, 10)
    R.Sweep()
    T.ok(not bike:IsValid(), "returned")
    T.eq(ply.BMXRental, nil, "and forgotten")

    later(sv)
    local locked = R.Rent(ply, m, "stock")
    ply:ExitVehicle()
    locked.BMXLock = {}
    R.Sweep()
    later(sv, R.IDLE * 2)
    R.Sweep()
    T.ok(locked:IsValid(), "a locked one is kept")
end)

T.test("rental: leaving the server returns it", function()
    local sv, m, ply = scene()
    local bike = sv.env.BMX.Rental.Rent(ply, m, "stock")
    ply:Kick("bye")
    T.ok(not bike:IsValid(), "gone with them")
end)

T.test("rental: only an admin can move or remove a machine", function()
    local sv, m, ply = scene()
    local H = sv.env.hook
    T.eq(H.Run("PhysgunPickup", ply, m), false, "no physgun")
    T.eq(H.Run("GravGunPunt", ply, m), false, "no punt")
    T.eq(H.Run("CanTool", ply, { Entity = m }, "remover"), false, "no remover")
    local admin = sv:player("Admin", { admin = true })
    admin._admin = true
    T.ok(H.Run("PhysgunPickup", admin, m) ~= false, "an admin may")
end)

T.test("rental: every vehicle the machine offers has a picture, and the window opens on the client", function()
    local sv, m, ply, world = scene()
    local cl = F.client(world)
    local n = 0
    for _, sec in ipairs(sv.env.BMX.Rental.Catalog()) do
        T.eq(sec.kind, "vehicle", sec.title .. " is vehicles, not park pieces")
        for _, it in ipairs(sec.items) do
            n = n + 1
            local fh = it.icon and io.open(gmod.ROOT .. "/materials/" .. it.icon, "rb")
            T.ok(fh, it.name .. ": no picture (" .. tostring(it.icon) .. ")")
            if fh then fh:close() end
        end
    end
    T.ok(n >= 10, "the machine offers the lot (" .. n .. ")")
    T.ok(type(cl.env.BMX.Rental.OpenWindow) == "function", "the client has the window")
end)
