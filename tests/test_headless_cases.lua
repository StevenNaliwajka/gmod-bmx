--[[--------------------------------------------------------------------------
    The headless suite's own bookkeeping (sv_test.lua / sv_test_cases.lua).

    The cases themselves only mean anything on a real server. What can be
    checked here is that the suite is put together the way it claims: every
    shipped bike has its variants, a variant runs the same body on the bike it
    names, and nothing in it is spelled wrong.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local function suite()
    local sv = F.server()
    return sv.env.BMX.Test, sv
end

local RIDING = { "rest", "parked_on_stand", "fallen_is_picked_up", "accelerate",
                 "brake_locks", "lean_steers", "lean_tracks_target", "bunny_hop",
                 "wheelie", "stoppie", "air_mode", "crash_ejects", "grind_pipe",
                 "grind_ledge" }

T.test("headless: every riding case also runs on the cruiser and the mini", function()
    local S = suite()
    for _, bike in ipairs({ "cruiser", "mini" }) do
        for _, name in ipairs(RIDING) do
            local v = S.cases[name .. "@" .. bike]
            T.ok(v, name .. "@" .. bike .. " exists")
            if v then
                T.eq(v.bike, bike, name .. "@" .. bike .. " rides the " .. bike)
                T.ok(v.fn == S.cases[name].fn, name .. "@" .. bike .. " is the same case body")
                T.eq(v.rider, S.cases[name].rider, name .. "@" .. bike .. " seats a rider the same way")
                T.ok(v.desc:find(bike, 1, true), name .. "@" .. bike .. " says which bike")
            end
        end
    end
end)

T.test("headless: the original cases still ride the stock bike", function()
    local S = suite()
    for _, name in ipairs(S.order) do
        if not name:find("@", 1, true) then
            T.eq(S.cases[name].bike, "stock", name .. " is a stock-bike case")
        end
    end
end)

T.test("headless: every case's bike is a real, registered bike", function()
    local S, sv = suite()
    for _, name in ipairs(S.order) do
        T.ok(sv.env.BMX.ClassFor(S.cases[name].bike), name .. " -> " .. S.cases[name].bike)
    end
end)

T.test("headless: the run order lists each case once, and only cases that exist", function()
    local S = suite()
    local seen = {}
    for _, name in ipairs(S.order) do
        T.ok(not seen[name], name .. " is listed once")
        T.ok(S.cases[name], name .. " exists")
        seen[name] = true
    end
    local n = 0
    for _ in pairs(S.cases) do n = n + 1 end
    T.eq(n, #S.order, "every case is in the run order")
end)

T.test("headless: a variant of a case that does not exist is a loud error", function()
    local S = suite()
    T.errors(function() S.Variant("no_such_case", "mini") end, "no case", "rejected")
end)

T.test("headless: a variant keeps the base case's timeout unless given one", function()
    local S = suite()
    S.Variant("rest", "mini", { timeout = 99 })
    T.eq(S.cases["rest@mini"].timeout, 99, "an explicit timeout")
    S.Variant("rest", "mini")
    T.eq(S.cases["rest@mini"].timeout, S.cases.rest.timeout, "the base case's timeout")
end)

T.test("headless: no case reads the stock bike's config where it means its own bike's", function()
    -- The cases that run on other bikes have to measure THAT bike against ITS
    -- numbers. BMX.Config in a case body is the stock bike's; only the
    -- per_bike_physics case, which is about the base on purpose, may use it.
    local f = io.open("lua/bmx/sv_test_cases.lua")
    local src = f:read("*a")
    f:close()
    local current, bad = nil, {}
    for line in src:gmatch("[^\n]+") do
        local name = line:match('^T%.Case%("([%w_]+)"')
        if name then current = name end
        if current and current ~= "per_bike_physics" and line:find("BMX%.Config[^%w]")
           and not line:match("^%s*%-%-") then
            bad[#bad + 1] = current .. ": " .. line
        end
    end
    T.eq(#bad, 0, "BMX.Config in a bike case: " .. table.concat(bad, " | "))
end)

T.test("headless: the crowd case exists and rides the stock bike among all three kinds", function()
    local S = suite()
    T.ok(S.cases.crowd, "crowd is a case")
    T.eq(S.cases.crowd.bike, "stock", "its ridden bike is the stock one")
    T.ok(S.cases.crowd.rider, "with the bot aboard")
end)

T.test("headless: bmx_test takes a prefix with a *, and runs just those", function()
    local S = suite()
    local ok = S.Run("grind_*")
    T.ok(ok, "accepted")
    S.Abort = S.Abort or function() end
    local sv = F.server()
    local S2 = sv.env.BMX.Test
    T.eq(select(2, S2.Run("nothing_like_this_*")), "no such case: nothing_like_this_*", "an empty prefix is refused")
end)

