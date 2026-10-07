--[[--------------------------------------------------------------------------
    The loader, in both realms.

    The class of bug these exist for: a file that loads in singleplayer and is
    missing in multiplayer. Singleplayer runs the client from the server's own
    files, so a file never AddCSLuaFile'd works perfectly right up until a real
    client joins. The headless suite has no client and cannot see it; the
    loader once forgot to send ITSELF.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local gmod = require("lib.gmod")

local function listLua(dir)
    local out = {}
    local p = io.popen('cd "' .. gmod.ROOT .. '/lua" && find ' .. dir .. ' -name "*.lua" | sort')
    for l in p:lines() do out[#out + 1] = l end
    p:close()
    return out
end

T.test("the server realm loads every server file without an error", function()
    local sv = F.server()
    T.eq(#sv.errors, 0, "ErrorNoHalt during load: " .. table.concat(sv.errors, " | "))
    T.ok(sv.env.BMX.Version, "BMX.Version is set")
    T.ok(sv.log[#sv.log]:find("loaded %(server%)"), "the load line is printed: " .. tostring(sv.log[#sv.log]))
end)

T.test("the client realm loads every client file without an error", function()
    local sv, world = F.server()
    local cl = F.client(world)
    T.eq(#cl.errors, 0, "ErrorNoHalt during load: " .. table.concat(cl.errors, " | "))
    T.ok(cl.log[#cl.log]:find("loaded %(client%)"), "the load line is printed")
    T.ok(cl.env.BMX.LocalBike, "cl_view defined BMX.LocalBike")
end)

T.test("every file the CLIENT runs was sent to it by the server", function()
    local sv, world = F.server()
    local cl = F.client(world)
    for _, rel in ipairs(cl.loaded) do
        T.ok(sv.csfiles[rel], rel .. " runs on the client but is never AddCSLuaFile'd " ..
            "by the server: it would work in singleplayer and be missing in multiplayer")
    end
end)

T.test("every file in lua/ is loaded by some realm", function()
    local sv, world = F.server()
    local cl = F.client(world)
    local seen = {}
    for _, r in ipairs(sv.loaded) do seen[r] = true end
    for _, r in ipairs(cl.loaded) do seen[r] = true end
    for _, rel in ipairs(listLua(".")) do
        rel = rel:gsub("^%./", "")
        T.ok(seen[rel], rel .. " is in the addon but nothing loads it")
    end
end)

T.test("no server-only file is sent to clients", function()
    local sv = F.server()
    for rel in pairs(sv.csfiles) do
        T.ok(not rel:find("/sv_") and not rel:find("init%.lua$") or
             rel == "autorun/bmx_init.lua" or rel:find("cl_init%.lua$"),
            rel .. " is server code and should not be downloaded by every client")
    end
end)

T.test("replicated convars are created by the server and readable on the client", function()
    local sv, world = F.server()
    local cl = F.client(world)
    for _, row in ipairs(sv.env.BMX.Config.ConVars) do
        T.ok(cl.env.GetConVar(row[1]), row[1] .. " is visible to the client")
    end
end)

T.test("the stock bike registers a spawnable, duplicatable class", function()
    local sv = F.server()
    local B = sv.env.BMX
    T.eq(B.ClassFor("stock"), "bmx_base", "stock is the base class")
    T.ok(sv.lists.SpawnableEntities and sv.lists.SpawnableEntities.bmx_base,
        "listed in the spawn menu")
    T.ok(sv.dupe.bmx_base, "registered with the duplicator")
    T.eq(B.ClassFor("nope"), nil, "an unknown bike has no class")
end)
