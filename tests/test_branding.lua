--[[--------------------------------------------------------------------------
    The addon is branded Burrito.

    THE RULE (owner, 2026-10-07). The owner's mods are published under
    "Burrito": every author field a player can see (the Q menu's tooltip, the
    weapon's info, a vehicle's registry entry) says Burrito. "naliwajka" belongs
    only in an address (gmod.naliwajka.com, www.naliwajka.com/...), never as a
    mod's author or brand.

    Checked twice: by reading the source, so an author line nobody spawns still
    fails, and by booting the server, so a default filled in at run time
    (sh_bikes.lua's `def.author or ...`) is caught as well.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local gmod = require("lib.gmod")

local BRAND = "Burrito"

local function luaFiles()
    local out = {}
    local p = io.popen('find "' .. gmod.ROOT .. '/lua" -name "*.lua" | sort')
    for line in p:lines() do out[#out + 1] = line end
    p:close()
    return out
end

T.test("branding: the source scan sees the addon's files", function()
    T.ok(#luaFiles() >= 50, "found " .. #luaFiles() .. " lua files")
end)

T.test("branding: every author field in lua/ is Burrito", function()
    local bad, seen = {}, 0
    for _, path in ipairs(luaFiles()) do
        local fh = io.open(path, "r")
        local n = 0
        for line in fh:lines() do
            n = n + 1
            -- ENT.Author = "...", SWEP.Author = "...", { author = "..." }, Author = def.author or "..."
            if not line:match("^%s*%-%-") then
                for value in line:gmatch('[%.%s{,][Aa]uthor%s*=%s*[^"\n]-"([^"]*)"') do
                    seen = seen + 1
                    if value ~= BRAND then
                        bad[#bad + 1] = path:gsub("^.*/lua/", "lua/") .. ":" .. n .. ' "' .. value .. '"'
                    end
                end
            end
        end
        fh:close()
    end
    T.ok(seen >= 10, "found " .. seen .. " author fields (the pattern still matches them)")
    T.eq(#bad, 0, "author must be " .. BRAND .. ": " .. table.concat(bad, ", "))
end)

T.test("branding: naliwajka appears in lua/ only as an address", function()
    local bad = {}
    for _, path in ipairs(luaFiles()) do
        local fh = io.open(path, "r")
        local n = 0
        for line in fh:lines() do
            n = n + 1
            local rest = line:lower():gsub("[%w%-]*%.?naliwajka%.com", "")
            if rest:find("naliwajka", 1, true) then
                bad[#bad + 1] = path:gsub("^.*/lua/", "lua/") .. ":" .. n
            end
        end
        fh:close()
    end
    T.eq(#bad, 0, "naliwajka outside an address: " .. table.concat(bad, ", "))
end)

T.test("branding: every spawnable entry, weapon and vehicle the server registers says Burrito", function()
    local sv = F.server()
    local bad, seen = {}, 0
    local function check(kind, class, author)
        if author == nil then return end
        seen = seen + 1
        if author ~= BRAND then bad[#bad + 1] = kind .. " " .. class .. ' "' .. tostring(author) .. '"' end
    end
    for class, t in pairs(sv.lists.SpawnableEntities or {}) do check("menu row", class, t.Author) end
    for class, t in pairs(sv.stored or {}) do check("entity", class, t.Author) end
    for class, t in pairs(sv.sweps or {}) do check("weapon", class, t.Author) end
    for id, def in pairs(sv.env.BMX.Vehicles or {}) do check("vehicle", id, def.author) end
    table.sort(bad)
    T.ok(seen >= 20, "found " .. seen .. " registered authors")
    T.eq(#bad, 0, "author must be " .. BRAND .. ": " .. table.concat(bad, ", "))
end)
