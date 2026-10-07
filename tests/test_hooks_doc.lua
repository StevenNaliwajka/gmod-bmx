--[[--------------------------------------------------------------------------
    The public hooks (docs/MODDING.md): the document and the code agree, and
    each hook fires when it says it does, with the arguments it says.

    THE DOCUMENT AND THE CODE ARE CHECKED BOTH WAYS. A hook that is documented
    but never fired is a promise nobody keeps; one that is fired but not
    documented is an API nobody was told about, and so one that is broken the
    first time somebody tidies it. Either fails here.

    A hook may be listed in PENDING while it is documented ahead of its code;
    delete it from PENDING once it fires. It is empty now.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local gmod = require("lib.gmod")

local PENDING = {}

local function slurp(path)
    local fh = assert(io.open(path, "r"), "cannot read " .. path)
    local s = fh:read("*a")
    fh:close()
    return s
end

-- Every hook name the code fires: hook.Run("BMX_...") or hook.Call("BMX_...").
local function fired()
    local out = {}
    local p = io.popen('find "' .. gmod.ROOT .. '/lua" -name "*.lua" | sort')
    for path in p:lines() do
        local n = 0
        for line in slurp(path):gmatch("[^\n]+") do
            n = n + 1
            if not line:match("^%s*%-%-") then
                for _, fn in ipairs({ "Run", "Call" }) do
                    for name in line:gmatch("hook%." .. fn .. '%s*%(%s*"(BMX_[%w_]+)"') do
                        out[name] = out[name] or (path:gsub("^.*/lua/", "lua/") .. ":" .. n)
                    end
                end
            end
        end
    end
    p:close()
    return out
end

-- Every hook the guide documents: a heading of the form ### `BMX_Name` (args).
local function documented()
    local out = {}
    for line in slurp(gmod.ROOT .. "/docs/MODDING.md"):gmatch("[^\n]+") do
        local name = line:match("^###%s+`(BMX_[%w_]+)`")
        if name then out[name] = true end
    end
    return out
end

T.test("hooks doc: the guide documents the hooks it was asked to", function()
    local d = documented()
    for _, name in ipairs({ "BMX_Mounted", "BMX_Dismounted", "BMX_TrickLanded", "BMX_ComboBanked",
                            "BMX_ComboBailed", "BMX_RiderCrashed", "BMX_CanSpawn", "BMX_CanMount" }) do
        T.ok(d[name], name .. " is in docs/MODDING.md")
    end
end)

T.test("hooks doc: every documented hook is fired somewhere in lua/", function()
    local f = fired()
    for name in pairs(documented()) do
        if not PENDING[name] then
            T.ok(f[name], name .. " is documented in docs/MODDING.md but nothing in lua/ fires it")
        end
    end
end)

T.test("hooks doc: every hook the code fires is documented", function()
    local d = documented()
    for name, where in pairs(fired()) do
        T.ok(d[name], name .. " is fired (" .. where .. ") but is not documented in docs/MODDING.md")
    end
end)

T.test("hooks doc: a pending hook that is now fired should leave PENDING", function()
    local f = fired()
    for name in pairs(PENDING) do
        T.ok(not f[name], name .. " is fired now: remove it from PENDING in this file")
    end
end)

-- The arguments, as documented: recorded by listeners and compared.
local function listen(E, names)
    local calls = {}
    for _, n in ipairs(names) do
        E.hook.Add(n, "doc", function(...)
            calls[#calls + 1] = { name = n, args = { ... } }
        end)
    end
    return calls
end

local function find(calls, name)
    for _, c in ipairs(calls) do if c.name == name then return c end end
end

T.test("hooks doc: BMX_Mounted and BMX_Dismounted are (ply, bike); the old names still fire", function()
    local sv = F.server()
    local E = sv.env
    local calls = listen(E, { "BMX_Mounted", "BMX_Dismounted", "BMX_RiderMounted", "BMX_RiderDismounted" })
    local bike = F.bike(sv)
    local ply = F.rider(sv, bike)
    local m = find(calls, "BMX_Mounted")
    T.ok(m and m.args[1] == ply and m.args[2] == bike, "BMX_Mounted(ply, bike)")
    local old = find(calls, "BMX_RiderMounted")
    T.ok(old and old.args[1] == bike and old.args[2] == ply, "BMX_RiderMounted(bike, ply), as before")
    ply:ExitVehicle()
    local d = find(calls, "BMX_Dismounted")
    T.ok(d and d.args[1] == ply and d.args[2] == bike, "BMX_Dismounted(ply, bike)")
    T.ok(find(calls, "BMX_RiderDismounted"), "the alias too")
end)

T.test("hooks doc: BMX_CanMount (ply, bike) can refuse a rider", function()
    local sv = F.server()
    local E = sv.env
    local bike = F.bike(sv)
    local ply = sv:player("Wants on")
    local seen
    E.hook.Add("BMX_CanMount", "doc", function(p, b) seen = { p, b } return false end)
    bike:Use(ply)
    T.ok(seen and seen[1] == ply and seen[2] == bike, "asked with (ply, bike)")
    T.ok(not E.IsValid(bike:GetDriver()), "and the veto held")
    E.hook.Remove("BMX_CanMount", "doc")
    bike:Use(ply)
    T.ok(bike:GetDriver() == ply, "without it they get on")
end)

T.test("hooks doc: BMX_CanSpawn (ply, bikeId) can refuse a spawn", function()
    local sv = F.server()
    local E = sv.env
    local ply = sv:player("Spawner")
    ply:SetPos(E.Vector(0, 0, 0))
    ply._eyeTrace = { Hit = true, HitPos = E.Vector(100, 0, 0), HitNormal = E.Vector(0, 0, 1) }
    local seen
    E.hook.Add("BMX_CanSpawn", "doc", function(p, id) seen = { p, id } return false end)
    sv:command("bmx_spawn", ply, "cruiser")
    T.ok(seen and seen[1] == ply and seen[2] == "cruiser", "asked with the registry id")
    T.eq(#E.ents.FindByClass("bmx_cruiser"), 0, "refused")
    E.hook.Remove("BMX_CanSpawn", "doc")
    sv.world.time = sv.world.time + 5
    sv:command("bmx_spawn", ply, "cruiser")
    T.eq(#E.ents.FindByClass("bmx_cruiser"), 1, "allowed without it")
end)

T.test("hooks doc: BMX_TrickLanded is once per trick, (ply, trick, points, bike)", function()
    local sv = F.server()
    local E = sv.env
    local calls = listen(E, { "BMX_TrickLanded", "BMX_TricksLanded" })
    local bike = F.bike(sv)
    local ply = F.rider(sv, bike)
    bike:AwardTricks({ { name = "Backflip", count = 1, points = 500 },
                       { name = "Air Time", count = 1, points = 130 } })
    local n = 0
    for _, c in ipairs(calls) do if c.name == "BMX_TrickLanded" then n = n + 1 end end
    T.eq(n, 2, "one call per trick")
    local c = find(calls, "BMX_TrickLanded")
    T.ok(c.args[1] == ply, "ply")
    T.eq(c.args[2].name, "Backflip", "trick")
    T.eq(c.args[3], 500, "points")
    T.ok(c.args[4] == bike, "and the bike, as an extra")
    local old = find(calls, "BMX_TricksLanded")
    T.ok(old and #old.args[3] == 2 and old.args[4] == 630, "the whole-landing alias still fires")
end)

T.test("hooks doc: BMX_TrickLanded does not fire with scoring off", function()
    local sv = F.server()
    local E = sv.env
    E.GetConVar("bmx_scoring"):SetString("0")
    local calls = listen(E, { "BMX_TrickLanded" })
    local bike = F.bike(sv)
    F.rider(sv, bike)
    bike:AwardTricks({ { name = "Backflip", count = 1, points = 500 } })
    T.eq(#calls, 0, "none")
end)

T.test("hooks doc: BMX_ComboBanked (ply, chain, total) and BMX_ComboBailed (ply, chain)", function()
    local sv = F.server()
    local E = sv.env
    local calls = listen(E, { "BMX_ComboBanked", "BMX_ComboBailed", "BMX_ComboEnded" })
    local bike = F.bike(sv)
    local ply = F.rider(sv, bike)
    sv:run(0.5)

    bike:AwardTricks({ { name = "Backflip", count = 1, points = 500 } })
    sv:run(0.3)
    bike:AwardTricks({ { name = "Crank Grind", count = 1, points = 140 } })
    sv:run(1.3)
    local b = find(calls, "BMX_ComboBanked")
    T.ok(b and b.args[1] == ply, "banked: ply")
    T.eq(b.args[2].n, 2, "chain.n")
    T.eq(b.args[2].base, 640, "chain.base")
    T.eq(b.args[2].bonus, 640, "chain.bonus")
    T.eq(b.args[3], 1280, "total is base + bonus")
    T.ok(not find(calls, "BMX_ComboBailed"), "and not bailed")

    bike:AwardTricks({ { name = "Backflip", count = 1, points = 500 } })
    bike:AwardTricks({ { name = "Barrel Roll", count = 1, points = 400 } })
    bike:Crash("impact", 0.5)
    local l = find(calls, "BMX_ComboBailed")
    T.ok(l and l.args[1] == ply and l.args[2].n == 2, "bailed: (ply, chain)")
    T.ok(find(calls, "BMX_ComboEnded"), "the old BMX_ComboEnded still fires")
end)

T.test("hooks doc: a lone trick is not a combo: neither banked nor bailed", function()
    local sv = F.server()
    local E = sv.env
    local calls = listen(E, { "BMX_ComboBanked", "BMX_ComboBailed" })
    local bike = F.bike(sv)
    F.rider(sv, bike)
    sv:run(0.5)
    bike:AwardTricks({ { name = "Backflip", count = 1, points = 500 } })
    sv:run(1.5)
    bike:AwardTricks({ { name = "Backflip", count = 1, points = 500 } })
    bike:Crash("impact", 0.5)
    T.eq(#calls, 0, "no combo events for one trick")
end)
