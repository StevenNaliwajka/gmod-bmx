--[[--------------------------------------------------------------------------
    The /bike menu (sh_menu.lua, sv_menu.lua, cl_menu.lua): what it lists,
    the chat command, and placing a park piece from a click.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local function both()
    local sv, world = F.server()
    local cl = F.client(world)
    return sv, cl
end

local function looker(sv, name, dist)
    local E = sv.env
    local ply = sv:player(name or "Rider")
    ply:SetPos(E.Vector(0, 0, 0))
    ply._eyeTrace = { Hit = true, HitPos = E.Vector(dist or 200, 0, 0), HitNormal = E.Vector(0, 0, 1) }
    ply._eyeAngles = E.Angle(0, 90, 0)
    return ply
end

-- Deliver every new wire message called `name` to `realm` as `ply`.
local function deliver(realm, from, name, ply)
    local n = 0
    realm.localPlayer = ply
    for i = from + 1, #realm.world.wire do
        local m = realm.world.wire[i]
        if m.name == name then realm:deliver(m); n = n + 1 end
    end
    return n
end

local function pieces(sv) return #sv.env.ents.FindByClass("bmx_park_piece") end

T.test("menu: the chat command is /bike, !bike, /bikes and /bmx, nothing else", function()
    local sv = F.server()
    local M = sv.env.BMX.Menu
    for _, s in ipairs({ "/bike", "!bike", "/BIKE", "  /bikes ", "/bmx" }) do
        T.ok(M.IsChatCommand(s), s .. " opens the menu")
    end
    for _, s in ipairs({ "bike", "/bike please", "/bik", "i want a /bike", "", "/bikeshed" }) do
        T.ok(not M.IsChatCommand(s), "'" .. s .. "' is just chat")
    end
end)

T.test("menu: the catalogue lists every visible vehicle, Bikes first, and every park piece", function()
    local sv = F.server()
    local E = sv.env
    local cat = E.BMX.Menu.Catalog()
    T.eq(cat[1].title, "Bikes", "Bikes is the first tab")
    local ids = {}
    for _, sec in ipairs(cat) do
        if sec.kind == "vehicle" then for _, it in ipairs(sec.items) do ids[it.id] = it end end
    end
    for _, id in ipairs(E.BMX.BikeIDs()) do T.ok(ids[id], id .. " is in the menu") end
    for id, def in pairs(E.BMX.Bikes) do
        if def.hidden then T.ok(not ids[id], "hidden " .. id .. " is not") end
    end
    T.eq(ids.stock.name, "BMX", "named as the spawn menu names it")
    local park = cat[#cat]
    T.eq(park.kind, "park", "the park is the last tab")
    T.eq(#park.items, #E.BMX.Park.Order, "every park shape")
end)

T.test("menu: /bike in chat opens the window on that player's client and is swallowed", function()
    local sv, cl = both()
    local ply = looker(sv)
    local before = #sv.world.wire
    T.eq(sv.env.hook.Run("PlayerSay", ply, "/bike", false), "", "the line never reaches chat")
    local m = sv.world.wire[#sv.world.wire]
    T.eq(m.name, "bmx_menu_open", "the open message")
    T.eq(m.to, ply, "sent to the typist only")
    local opened = 0
    cl.env.BMX.Menu.Open = function() opened = opened + 1 end
    deliver(cl, before, "bmx_menu_open", nil)
    T.eq(opened, 1, "the client opens the window")
    T.eq(sv.env.hook.Run("PlayerSay", ply, "nice bike", false), nil, "other chat is left alone")
end)

T.test("menu: a park click places that piece where the player looks, facing their way, with undo", function()
    local sv, cl = both()
    local ply = looker(sv)
    local before = #sv.world.wire
    cl.env.net.Start("bmx_menu_spawn")
    cl.env.net.WriteString("kicker")
    cl.env.net.WriteUInt(3, 4)
    cl.env.net.WriteUInt(1, 4)
    cl.env.net.SendToServer()
    T.eq(deliver(sv, before, "bmx_menu_spawn", ply), 1, "delivered")
    local e = sv.env.ents.FindByClass("bmx_park_piece")[1]
    T.ok(e, "a piece stands")
    T.eq(e:GetShape(), "kicker", "the kicker")
    T.eq(e:GetParams(), "3,1", "large")
    T.near(e:GetPos().x, 200, 1e-6, "at the eye trace")
    T.near(e:GetAngles().y, 90, 1e-6, "facing the way the player looks")
    local u = sv.undo[#sv.undo]
    T.ok(u and u.ents[1] == e and u.ply == ply and u.done, "an undo entry for the player")
end)

T.test("menu: a park click is refused for junk, out of reach, too fast, a veto, or a full park", function()
    local sv = F.server()
    local M = sv.env.BMX.Menu
    local ply = looker(sv)
    local function try(shape, s, v)
        sv.world.time = sv.world.time + 1
        return M.SpawnPiece(ply, shape, s, v)
    end
    T.ok(not try("banana", 1, 1), "an unknown shape")
    T.ok(try("kicker", 0, 15), "out-of-range sizes are clamped, not refused")
    T.eq(pieces(sv), 1, "one so far")

    local far = looker(sv, "Far", 5000)
    sv.world.time = sv.world.time + 1
    T.ok(not M.SpawnPiece(far, "kicker", 2, 1), "too far away")
    T.ok(table.concat(far._chat or {}, "\n"):find("look at the ground", 1, true), "and told why")

    T.ok(try("kicker", 2, 1), "a second")
    T.ok(not M.SpawnPiece(ply, "kicker", 2, 1), "a third in the same instant is too fast")

    sv.gm.PlayerSpawnSENT = function() return false end
    T.ok(not try("kicker", 2, 1), "the gamemode said no")
    sv.gm.PlayerSpawnSENT = nil

    sv.env.GetConVar("bmx_park_max"):SetString(tostring(pieces(sv)))
    T.ok(not try("kicker", 2, 1), "the park is full")
    T.eq(pieces(sv), 2, "still two")
end)

T.test("menu: bmx_menu exists on the client", function()
    local _, cl = both()
    T.ok(cl.commands.bmx_menu, "the console command")
end)
