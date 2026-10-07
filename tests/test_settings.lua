--[[--------------------------------------------------------------------------
    The settings table, the Options menu's plumbing, server.json, and the CAMI
    privileges (sh_settings.lua, sv_settings.lua, cl_options.lua,
    sh_permissions.lua).

    What these protect: a setting with no help text or no range, a setting the
    menu forgot, a default that drifted from its convar, a player changing the
    server's settings without permission, and a saved file that does not come
    back the way it went out. The panels themselves are not built here (there
    is no vgui offline); everything they call is.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local gmod = require("lib.gmod")

local PRIV = "BMX - Change Server Settings"

local function both()
    local sv, world = F.server()
    local cl = F.client(world)
    return sv, cl, world
end

local function player(sv, nick, opts)
    return sv:player(nick, opts or {})
end

-- Send a bmx_setting message from the client realm and deliver it to the
-- server as `ply`. Returns nothing; look at the convar and the chat.
local function send(sv, cl, ply, op, name, value)
    local before = #sv.world.wire
    cl.env.BMX.Options.Send(op, name, value)
    sv.localPlayer = ply
    for i = before + 1, #sv.world.wire do
        local m = sv.world.wire[i]
        if m.name == "bmx_setting" then sv:deliver(m) end
    end
end

--------------------------------------------------------------------------
-- The table
--------------------------------------------------------------------------

T.test("settings: every setting has a label, plain help text, and a range", function()
    local sv = F.server()
    local S = sv.env.BMX.Settings
    T.ok(#S.List >= 30, "the table is not empty: " .. #S.List)
    for _, r in ipairs(S.List) do
        T.ok(type(r.label) == "string" and #r.label > 0, r.name .. " has a label")
        T.ok(type(r.help) == "string" and #r.help >= 20, r.name .. " has real help text")
        if r.kind == "int" or r.kind == "float" then
            T.ok(r.min < r.max, r.name .. " has a range")
            T.between(r.default, r.min, r.max, r.name .. " default is inside its range")
        elseif r.kind == "choice" then
            local found = false
            for _, c in ipairs(r.choices) do if c == r.default then found = true end end
            T.ok(found, r.name .. " default is one of its choices")
        elseif r.kind == "string" then
            T.ok(r.maxLen > 0 and #r.default <= r.maxLen, r.name .. " has a length limit")
        else
            T.eq(type(r.default), "boolean", r.name .. " default")
        end
    end
end)

T.test("settings: every row is in a registered category and has a known scope", function()
    local sv = F.server()
    local S = sv.env.BMX.Settings
    for _, r in ipairs(S.List) do
        local ok = false
        for _, c in ipairs(S.Categories[r.scope] or {}) do
            if c.id == r.category then ok = true end
        end
        T.ok(ok, r.name .. " is in category " .. tostring(r.category) .. " which " ..
            "is not registered for scope " .. tostring(r.scope))
    end
end)

T.test("settings: every bmx_ convar is described, with the default it was created with", function()
    local sv, cl, world = both()
    local S = sv.env.BMX.Settings
    local seen = {}
    for name, cv in pairs(world.convars) do
        -- bmx_test_* belong to the headless harness (sv_test.lua), not to players.
        if name:sub(1, 4) == "bmx_" and name:sub(1, 9) ~= "bmx_test_" then
            local row = S.Get(name)
            T.ok(row, name .. " is a convar the Options menu knows nothing about: add " ..
                "it to lua/bmx/sh_settings.lua")
            seen[name] = true
            local want = S.Coerce(row, cv:GetDefault())
            if row.kind == "float" then
                T.near(row.default, want, math.abs(want) * 1e-6 + 1e-9, name .. " default")
            else
                T.eq(row.default, want, name .. " default")
            end
        end
    end
    for _, r in ipairs(S.List) do
        T.ok(seen[r.name], r.name .. " is in the table but no realm creates that convar")
    end
end)

T.test("settings: a client row is created on the client, a server row on the server", function()
    local sv, cl = both()
    local S = sv.env.BMX.Settings
    for _, r in ipairs(S.List) do
        local cv = sv.world.convars[r.name]
        if r.scope == "server" then
            T.ok(sv.env.bit.band(cv.flags, sv.env.FCVAR_REPLICATED) ~= 0,
                r.name .. " is a server row, so it must be REPLICATED for the panel to show it")
        else
            T.eq(cv.flags, 0, r.name .. " is a client convar")
        end
    end
end)

T.test("settings: Coerce clamps numbers, rejects junk, and keeps strings tame", function()
    local sv = F.server()
    local S = sv.env.BMX.Settings
    local dist = S.Get("bmx_cam_dist")
    T.eq(S.Coerce(dist, 99999), dist.max, "clamped high")
    T.eq(S.Coerce(dist, -5), dist.min, "clamped low")
    T.eq(S.Coerce(dist, "150"), 150, "a string number")
    T.eq((S.Coerce(dist, "abc")), nil, "junk is refused")
    T.eq((S.Coerce(dist, 0 / 0)), nil, "NaN is refused")
    T.eq((S.Coerce(dist, math.huge)), nil, "infinity is refused")
    T.eq(S.Coerce(S.Get("bmx_max_per_player"), 2.6), 3, "an int rounds")
    T.eq(S.Coerce(S.Get("bmx_scoring"), "0"), false, "bool from 0")
    T.eq(S.Coerce(S.Get("bmx_scoring"), true), true, "bool from true")
    T.eq((S.Coerce(S.Get("bmx_scoring"), "maybe")), nil, "bool from nonsense")
    T.eq(S.Coerce(S.Get("bmx_units"), "MPH"), "mph", "a choice, any case")
    T.eq((S.Coerce(S.Get("bmx_units"), "furlongs")), nil, "not a choice")
    local name = S.Get("bmx_bot_name")
    T.eq(S.Coerce(name, 'a"b\\c\nd'), "abcd", "no quotes, slashes or control characters")
    T.eq(#S.Coerce(name, string.rep("x", 500)), name.maxLen, "cut to maxLen")
end)

T.test("settings: ToConVar writes a float without trailing noise", function()
    local sv = F.server()
    local S = sv.env.BMX.Settings
    T.eq(S.ToConVar(S.Get("bmx_cam_roll"), 0.34), "0.34", "0.34")
    T.eq(S.ToConVar(S.Get("bmx_cam_dist"), 115), "115", "115")
    T.eq(S.ToConVar(S.Get("bmx_scoring"), true), "1", "true")
end)

T.test("settings: Add is the extension point (a new row and category just work)", function()
    local sv = F.server()
    local S = sv.env.BMX.Settings
    S.AddCategory("server", "passengers", "Passengers")
    sv.env.CreateConVar("bmx_future_seats", "2", 0, "x")
    S.Add{ name = "bmx_future_seats", kind = "int", default = 2, min = 0, max = 4, scope = "server",
        category = "passengers", label = "Seats", help = "How many people can ride on one bike." }
    T.eq(#S.Rows("server", "passengers"), 1, "found by category")
    local before = #S.List
    S.Add(S.Get("bmx_future_seats"))
    T.eq(#S.List, before, "adding it twice does not list it twice")
    T.errors(function()
        S.Add{ name = "bmx_x", kind = "int", default = 1, scope = "server", category = "rules",
            label = "x", help = "no range given" }
    end, "min < max", "a number row without a range is refused")
    T.errors(function()
        S.Add{ name = "bmx_y", kind = "bool", default = true, scope = "server", category = "rules",
            label = "y", help = "" }
    end, "help", "a row without help is refused")
end)

T.test("settings: bmx_dump_config lists them and marks the changed ones", function()
    local sv = F.server()
    sv.env.GetConVar("bmx_scoring"):SetString("0")
    sv:command("bmx_dump_config", nil)
    local all = table.concat(sv.log, "\n")
    T.ok(all:find("* bmx_scoring", 1, true), "a changed setting is starred")
    T.ok(all:find("  bmx_combos", 1, true), "an unchanged one is not")
end)

--------------------------------------------------------------------------
-- Changing server settings: the net message, and who may
--------------------------------------------------------------------------

T.test("settings: a non-admin's change is rejected, and they are told", function()
    local sv, cl = both()
    local nobody = player(sv, "Nobody")
    local S = sv.env.BMX.Settings
    send(sv, cl, nobody, S.OP_SET, "bmx_max_per_player", "5")
    T.eq(sv.env.GetConVar("bmx_max_per_player"):GetInt(), 0, "unchanged")
    T.ok(table.concat(nobody._chat or {}, "\n"):find("permission", 1, true), "and told why")
end)

T.test("settings: an admin who is not a superadmin is rejected by default", function()
    local sv, cl = both()
    local adm = player(sv, "Admin")
    adm._admin = true
    send(sv, cl, adm, sv.env.BMX.Settings.OP_SET, "bmx_scoring", "0")
    T.eq(sv.env.GetConVar("bmx_scoring"):GetInt(), 1, "unchanged")
end)

T.test("settings: a superadmin's change lands, clamped to the range", function()
    local sv, cl = both()
    local boss = player(sv, "Boss", { superadmin = true })
    local S = sv.env.BMX.Settings
    send(sv, cl, boss, S.OP_SET, "bmx_scoring", "0")
    T.eq(sv.env.GetConVar("bmx_scoring"):GetInt(), 0, "scoring off")
    send(sv, cl, boss, S.OP_SET, "bmx_max_per_player", "9999")
    T.eq(sv.env.GetConVar("bmx_max_per_player"):GetInt(), 50, "clamped to the row's max")
    send(sv, cl, boss, S.OP_SET, "bmx_grip", "2.25")
    T.near(sv.env.GetConVar("bmx_grip"):GetFloat(), 2.25, 1e-9, "a float")
    send(sv, cl, boss, S.OP_SET, "bmx_bot_name", "Stewie")
    T.eq(sv.env.GetConVar("bmx_bot_name"):GetString(), "Stewie", "a string")
end)

T.test("settings: the net message cannot set a client setting or any other convar", function()
    local sv, cl = both()
    local boss = player(sv, "Boss", { superadmin = true })
    local S = sv.env.BMX.Settings
    send(sv, cl, boss, S.OP_SET, "bmx_cam_dist", "300")
    T.eq(sv.env.GetConVar("bmx_cam_dist"):GetInt(), 115, "a client row is not the server's to set")
    sv.env.CreateConVar("sv_cheats", "0", 0, "")
    send(sv, cl, boss, S.OP_SET, "sv_cheats", "1")
    T.eq(sv.env.GetConVar("sv_cheats"):GetInt(), 0, "an unlisted convar is untouchable")
    send(sv, cl, boss, S.OP_SET, "bmx_max_per_player", "banana")
    T.eq(sv.env.GetConVar("bmx_max_per_player"):GetInt(), 0, "junk is refused")
    T.ok(table.concat(boss._chat or {}, "\n"):find("not a number", 1, true), "and said so")
end)

T.test("settings: reset one and reset all, by message and by command", function()
    local sv, cl = both()
    local boss = player(sv, "Boss", { superadmin = true })
    local S = sv.env.BMX.Settings
    sv.env.GetConVar("bmx_grip"):SetString("2.5")
    sv.env.GetConVar("bmx_combos"):SetString("0")
    send(sv, cl, boss, S.OP_RESET, "bmx_grip", "")
    T.near(sv.env.GetConVar("bmx_grip"):GetFloat(), S.Get("bmx_grip").default, 1e-6, "reset one")
    T.eq(sv.env.GetConVar("bmx_combos"):GetInt(), 0, "and only that one")
    send(sv, cl, boss, S.OP_RESET_ALL, "", "")
    T.eq(sv.env.GetConVar("bmx_combos"):GetInt(), 1, "reset all")

    local nobody = player(sv, "Nobody")
    sv.env.GetConVar("bmx_combos"):SetString("0")
    sv:command("bmx_reset_server", nobody)
    T.eq(sv.env.GetConVar("bmx_combos"):GetInt(), 0, "bmx_reset_server refused for a non-admin")
    sv:command("bmx_reset_server", boss)
    T.eq(sv.env.GetConVar("bmx_combos"):GetInt(), 1, "bmx_reset_server for a superadmin")
    sv.env.GetConVar("bmx_combos"):SetString("0")
    sv:command("bmx_reset_server", nil)
    T.eq(sv.env.GetConVar("bmx_combos"):GetInt(), 1, "and the server console")
end)

--------------------------------------------------------------------------
-- The client side
--------------------------------------------------------------------------

T.test("settings: the Options menu registers a Rider and a Server panel", function()
    local sv, cl = both()
    local added = {}
    cl.env.spawnmenu = { AddToolMenuOption = function(tab, cat, class, name)
        added[#added + 1] = { tab, cat, class, name }
    end }
    cl.env.hook.Run("PopulateToolMenu")
    T.eq(#added, 2, "two panels")
    T.eq(added[1][1], "Options", "under Options")
    T.eq(added[1][2], "BMX", "in the BMX category")
    T.eq(added[1][4], "Rider", "Rider")
    T.eq(added[2][4], "Server", "Server")
end)

T.test("settings: bmx_reset_client puts every Rider setting back", function()
    local sv, cl = both()
    local S = cl.env.BMX.Settings
    for _, r in ipairs(S.Rows("client")) do
        local cv = cl.env.GetConVar(r.name)
        if r.kind == "bool" then cv:SetString(r.default and "0" or "1")
        elseif r.kind == "int" or r.kind == "float" then cv:SetString(tostring(r.max))
        elseif r.kind == "choice" then cv:SetString(r.choices[#r.choices] == r.default and r.choices[1] or r.choices[#r.choices])
        else cv:SetString("zzz") end
    end
    cl:command("bmx_reset_client")
    for _, r in ipairs(S.Rows("client")) do
        T.ok(S.IsDefault(r), r.name .. " is back at its default")
    end
end)

T.test("settings: the client's bmx_reset_server asks the server, which checks permission", function()
    local sv, cl, world = both()
    local boss = player(sv, "Boss", { superadmin = true })
    sv.env.GetConVar("bmx_scoring"):SetString("0")
    local before = #world.wire
    cl:command("bmx_reset_server")
    T.eq(#world.wire, before + 1, "one message")
    sv.localPlayer = boss
    sv:deliver(world.wire[#world.wire])
    T.eq(sv.env.GetConVar("bmx_scoring"):GetInt(), 1, "and it worked")
end)

--------------------------------------------------------------------------
-- server.json
--------------------------------------------------------------------------

T.test("settings: server settings round-trip through JSON", function()
    local sv = F.server()
    local S = sv.env.BMX.Settings
    sv.env.GetConVar("bmx_scoring"):SetString("0")
    sv.env.GetConVar("bmx_grip"):SetString("2.5")
    sv.env.GetConVar("bmx_bot_name"):SetString("Quagmire")
    sv.env.GetConVar("bmx_max_per_player"):SetString("7")
    S.SaveServer()
    local json = sv.files["bmx/server.json"]
    T.ok(json and json:find("bmx_scoring", 1, true), "the file is written")

    sv.env.GetConVar("bmx_scoring"):SetString("1")
    sv.env.GetConVar("bmx_grip"):SetString("1")
    sv.env.GetConVar("bmx_bot_name"):SetString("x")
    sv.env.GetConVar("bmx_max_per_player"):SetString("0")
    T.ok(S.LoadServer() >= 4, "loads")
    T.eq(sv.env.GetConVar("bmx_scoring"):GetInt(), 0, "bool back")
    T.near(sv.env.GetConVar("bmx_grip"):GetFloat(), 2.5, 1e-9, "float back")
    T.eq(sv.env.GetConVar("bmx_bot_name"):GetString(), "Quagmire", "string back")
    T.eq(sv.env.GetConVar("bmx_max_per_player"):GetInt(), 7, "int back")
end)

T.test("settings: the file is loaded at boot", function()
    local world = gmod.World()
    local R = gmod.Realm(world, "server")
    R.files["bmx/server.json"] = '{"bmx_combos": false, "bmx_max_per_player": 3, ' ..
        '"bmx_nonsense": 1, "bmx_cam_dist": 250, "bmx_grip": 99}'
    R:boot()
    T.ok(table.concat(R.log, "\n"):find("server setting", 1, true), table.concat(R.log, " | "))
    T.eq(R.env.GetConVar("bmx_combos"):GetInt(), 0, "a saved bool")
    T.eq(R.env.GetConVar("bmx_max_per_player"):GetInt(), 3, "a saved int")
    T.eq(R.env.GetConVar("bmx_grip"):GetFloat(), R.env.BMX.Settings.Get("bmx_grip").max,
        "a saved number out of range is clamped")
    T.eq(R.env.GetConVar("bmx_cam_dist"), nil, "a client setting in the file is ignored")
    T.eq(#R.errors, 0, "no errors")
end)

T.test("settings: a broken file is left alone", function()
    local world = gmod.World()
    local R = gmod.Realm(world, "server")
    R.files["bmx/server.json"] = "this is not json"
    R:boot()
    T.eq(R.env.GetConVar("bmx_scoring"):GetInt(), 1, "defaults stand")
    T.eq(R.files["bmx/server.json"], "this is not json", "and the file is not overwritten")
end)

T.test("settings: a change from the console is saved, once, a moment later", function()
    local sv = F.server()
    T.ok(sv.files["bmx/server.json"] == nil, "nothing written just by booting")
    sv.env.GetConVar("bmx_scoring"):SetString("0")
    sv.env.GetConVar("bmx_combos"):SetString("0")
    T.ok(sv.files["bmx/server.json"] == nil, "not yet: debounced")
    sv.world.time = sv.world.time + 1
    sv:runTimers()
    local json = sv.files["bmx/server.json"]
    T.ok(json and json:find('"bmx_scoring": false', 1, true), "saved: " .. tostring(json))
    T.ok(json:find('"bmx_combos": false', 1, true), "both changes in the one write")
end)

--------------------------------------------------------------------------
-- CAMI
--------------------------------------------------------------------------

-- A CAMI stand-in that answers from a table. `answers[priv][nick]`.
local function fakeCami(answers, late)
    local C = { registered = {}, asked = {} }
    function C.RegisterPrivilege(p) C.registered[p.Name] = p end
    function C.PlayerHasAccess(ply, priv, cb)
        C.asked[#C.asked + 1] = priv
        local a = answers[priv] and answers[priv][ply:Nick()]
        if late then return end             -- an admin mod that answers a frame later
        if a == nil then a = false end
        cb(a)
    end
    return C
end

T.test("cami: the six privileges are registered, with the right defaults", function()
    local sv = F.server()
    local C = fakeCami({})
    sv.env.CAMI = C
    T.ok(sv.env.BMX.RegisterPrivileges(), "registers")
    local want = {
        ["BMX - Change Server Settings"] = "superadmin",
        ["BMX - Physgun Ridden"] = "admin",
        ["BMX - Spawn Motor Vehicles"] = "admin",
        ["BMX - Remove Any Bike"] = "admin",
        ["BMX - Bot"] = "admin",
        ["BMX - Unlock Any Lock"] = "admin",
    }
    for name, min in pairs(want) do
        T.ok(C.registered[name], name .. " is registered")
        T.eq(C.registered[name].MinAccess, min, name .. " default")
        T.ok(#C.registered[name].Description > 5, name .. " is described")
    end
end)

T.test("cami: a CAMI that arrives after us is picked up at InitPostEntity", function()
    local sv = F.server()
    local C = fakeCami({})
    sv.env.CAMI = C
    sv.env.hook.Run("InitPostEntity")
    T.ok(C.registered["BMX - Bot"], "registered late")
end)

T.test("cami: the answer is CAMI's, in both directions", function()
    local sv = F.server()
    local grant = player(sv, "Granted")             -- no admin rights at all
    local deny = player(sv, "Denied", { superadmin = true })
    sv.env.CAMI = fakeCami({
        [PRIV] = { Granted = true, Denied = false },
        ["BMX - Bot"] = { Granted = true },
    })
    local B = sv.env.BMX
    T.eq(B.Can(grant, PRIV), true, "granted by CAMI though not an admin")
    T.eq(B.Can(deny, PRIV), false, "denied by CAMI though a superadmin")
    T.eq(B.Can(grant, "BMX - Bot"), true, "another privilege")
    T.eq(B.Can(deny, "BMX - Bot"), false, "unlisted means denied, as CAMI says")
end)

T.test("cami: with no CAMI, the defaults are the admin checks", function()
    local sv = F.server()
    local B = sv.env.BMX
    local nobody, adm, boss = player(sv, "N"), player(sv, "A"), player(sv, "S", { superadmin = true })
    adm._admin = true
    T.eq(B.Can(nobody, PRIV), false, "nobody: settings")
    T.eq(B.Can(adm, PRIV), false, "admin: settings need superadmin")
    T.eq(B.Can(boss, PRIV), true, "superadmin: settings")
    T.eq(B.Can(nobody, "BMX - Bot"), false, "nobody: bot")
    T.eq(B.Can(adm, "BMX - Bot"), true, "admin: bot")
    T.eq(B.Can(nil, PRIV), true, "the server console may do anything")
end)

T.test("cami: a late answer falls back to the default instead of waiting", function()
    local sv = F.server()
    sv.env.CAMI = fakeCami({}, true)
    local adm = player(sv, "A")
    adm._admin = true
    T.eq(sv.env.BMX.Can(adm, "BMX - Bot"), true, "admin still gets the default")
    T.eq(sv.env.BMX.Can(player(sv, "N"), "BMX - Bot"), false, "a player does not")
end)

T.test("cami: an unknown privilege name is refused loudly", function()
    local sv = F.server()
    T.eq(sv.env.BMX.Can(player(sv, "A", { superadmin = true }), "BMX - Nonsense"), false, "no")
    T.ok(#sv.errors >= 1, "and reported")
end)

T.test("cami: a CAMI grant lets a non-admin change server settings through the net message", function()
    local sv, cl = both()
    local mod = player(sv, "Moderator")
    sv.env.CAMI = fakeCami({ [PRIV] = { Moderator = true } })
    send(sv, cl, mod, sv.env.BMX.Settings.OP_SET, "bmx_combos", "0")
    T.eq(sv.env.GetConVar("bmx_combos"):GetInt(), 0, "changed")
end)

--------------------------------------------------------------------------
-- What the privileges gate
--------------------------------------------------------------------------

T.test("cami: bmx_bot_* commands need BMX - Bot", function()
    local sv = F.server()
    local spawned = 0
    sv.env.BMX.Bot.Spawn = function() spawned = spawned + 1 return nil, "test" end
    local nobody = player(sv, "N")
    local adm = player(sv, "A")
    adm._admin = true
    nobody._eyeTrace = { Hit = true, HitPos = sv.env.Vector(0, 0, 0), HitNormal = sv.env.Vector(0, 0, 1) }
    adm._eyeTrace = nobody._eyeTrace

    sv:command("bmx_bot_spawn", nobody)
    T.eq(spawned, 0, "a player without the privilege")
    sv:command("bmx_bot_spawn", adm)
    T.eq(spawned, 1, "an admin, by default")
    sv.env.CAMI = fakeCami({ ["BMX - Bot"] = { N = true } })
    sv:command("bmx_bot_spawn", nobody)
    T.eq(spawned, 2, "a non-admin CAMI grants it to")
    sv:command("bmx_bot_spawn", adm)
    T.eq(spawned, 2, "an admin CAMI does not list is refused")
    sv:command("bmx_bot_spawn", nil)
    T.eq(spawned, 3, "the console")
end)

T.test("cami: the physgun on a ridden bike needs BMX - Physgun Ridden", function()
    local sv = F.server()
    local E = sv.env
    local bike = F.bike(sv)
    F.rider(sv, bike)
    local stranger = player(sv, "Stranger")
    local adm = player(sv, "Admin")
    adm._admin = true
    T.eq(E.hook.Run("PhysgunPickup", stranger, bike), false, "a stranger: no")
    T.ok(E.hook.Run("PhysgunPickup", adm, bike) ~= false, "an admin: yes, by default")
    T.eq(E.hook.Run("PhysgunPickup", adm, bike:GetPod()), false, "the seat, never")
    E.CAMI = fakeCami({ ["BMX - Physgun Ridden"] = { Stranger = true } })
    T.ok(E.hook.Run("PhysgunPickup", stranger, bike) ~= false, "CAMI grants a stranger")
    T.eq(E.hook.Run("PhysgunPickup", adm, bike), false, "CAMI does not list the admin: no")
end)
