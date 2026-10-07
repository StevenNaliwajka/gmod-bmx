--[[--------------------------------------------------------------------------
    Many bikes on one server at once.

    test_perf.lua holds ONE bike to a trace budget. This is the other half of
    the question a public server asks: does the cost stay per bike as the
    server fills up, does anything a bike sends reach riders it is not for,
    and does a crowd of bikes interfere with each other's simulation. The real
    tick cost is measured on a real server by the headless "crowd" case.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local N = 16

-- N bikes in a row 150 units apart, each with its own scripted rider.
local function crowd(n, ids)
    local sv, world = F.server()
    local E, B = sv.env, sv.env.BMX
    local bikes, riders = {}, {}
    for i = 1, n do
        local id = ids and ids[(i - 1) % #ids + 1] or "stock"
        local cfg = B.ConfigFor(B.Bikes[id])
        local b = F.bike(sv, B.ClassFor(id),
            E.Vector(0, (i - 1) * 150, sv.world.groundZ + B.RestHeight(cfg)))
        local p = F.rider(sv, b, { bot = true, name = "Rider" .. i })
        p.BMXScripted = true
        bikes[i], riders[i] = b, p
    end
    sv:run(0.5)
    return sv, bikes, riders, world
end

local function countTraces(sv)
    local E = sv.env
    local n = { 0 }
    local tl, th = E.util.TraceLine, E.util.TraceHull
    E.util.TraceLine = function(t) n[1] = n[1] + 1 return tl(t) end
    E.util.TraceHull = function(t) n[1] = n[1] + 1 return th(t) end
    return n
end

local function perTick(sv, n, secs)
    n[1] = 0
    local ticks = math.max(1, math.floor(secs / sv.world.dt + 0.5))
    sv:run(secs)
    return n[1] / ticks
end

T.test("load: sixteen riders on one server all settle, upright and error-free", function()
    local sv, bikes = crowd(N)
    for i, b in ipairs(bikes) do
        local f, r = F.wheels(b)
        T.ok(f.onGround and r.onGround, "bike " .. i .. " on both wheels")
        T.ok(math.abs(b.st.roll) < math.rad(10), "bike " .. i .. " upright")
    end
    T.eq(#sv.errors, 0, "no errors: " .. table.concat(sv.errors, " | "))
end)

T.test("load: trace cost stays per bike: sixteen riding cost sixteen times one", function()
    local sv1, b1 = crowd(1)
    local n1 = countTraces(sv1)
    F.input(b1[1], { throttle = 1 })
    local one = perTick(sv1, n1, 1)

    local sv, bikes = crowd(N)
    local n = countTraces(sv)
    for _, b in ipairs(bikes) do F.input(b, { throttle = 1 }) end
    local many = perTick(sv, n, 1)
    T.between(many, 0, 2.5 * N, "sixteen riding: traces a tick")
    T.between(many / math.max(one, 1e-9), N * 0.8, N * 1.2,
        string.format("linear in the number of bikes (%.1f vs %.1f)", many, one))
end)

T.test("load: plain riding sends nothing over the net, however many are riding", function()
    local sv, bikes, _, world = crowd(N)
    for _, b in ipairs(bikes) do F.input(b, { throttle = 0.7 }) end
    local before = #world.wire
    sv:run(3)
    local sent = {}
    for i = before + 1, #world.wire do sent[#sent + 1] = world.wire[i].name end
    T.eq(#sent, 0, "no messages in 3 s of riding: " .. table.concat(sent, ", "))
end)

T.test("load: each rider's trick callouts and combos go to that rider only", function()
    local sv, bikes, riders, world = crowd(N)
    local before = #world.wire
    for _, b in ipairs(bikes) do
        b:AwardTricks({ { name = "Backflip", count = 1, points = 500 } })
        b:AwardTricks({ { name = "Manual", count = 1, points = 150 } })
    end
    sv:run(1.5)
    local per = {}
    for i = before + 1, #world.wire do
        local m = world.wire[i]
        if m.name == "bmx_tricks" or m.name == "bmx_combo" then
            T.ok(m.to ~= nil, m.name .. " is addressed, not broadcast")
            per[m.to] = (per[m.to] or 0) + 1
        end
    end
    for i, p in ipairs(riders) do
        -- Two callouts, two combo updates (open) and one LANDED.
        T.eq(per[p], 5, "rider " .. i .. " got exactly their own five messages")
    end
end)

T.test("load: every rider's combo banks on its own, at its own score", function()
    local sv, bikes = crowd(N)
    for i, b in ipairs(bikes) do
        for k = 1, (i % 3) + 1 do
            b:AwardTricks({ { name = "Trick" .. k, count = 1, points = 100 } })
        end
    end
    sv:run(1.5)
    for i, b in ipairs(bikes) do
        local n = (i % 3) + 1
        local want = 100 * n + (n >= 2 and 100 * n * (n - 1) or 0)
        T.eq(b:GetScore(), want, "bike " .. i .. " with " .. n .. " tricks")
        T.eq(b.st.combo, nil, "bike " .. i .. " banked")
    end
end)

T.test("load: one rider crashing does not disturb the bikes beside it", function()
    local sv, bikes = crowd(4)
    for _, b in ipairs(bikes) do F.input(b, { throttle = 0.5 }) end
    sv:run(1)
    bikes[2]:Crash("impact", 0.5)
    sv:run(1)
    T.ok(not sv.env.IsValid(bikes[2]:GetDriver()), "the crashed rider is off")
    for _, i in ipairs({ 1, 3, 4 }) do
        T.ok(sv.env.IsValid(bikes[i]:GetDriver()), "bike " .. i .. " still ridden")
        T.ok(math.abs(bikes[i].st.roll) < math.rad(10), "bike " .. i .. " still upright")
    end
end)

T.test("load: a mixed crowd of all three bikes rides at three different speeds", function()
    local sv, bikes = crowd(9, { "stock", "cruiser", "mini" })
    for _, b in ipairs(bikes) do F.input(b, { throttle = 1 }) end
    sv:run(12)
    local by = {}
    for _, b in ipairs(bikes) do
        local id = b:Bike().id
        by[id] = by[id] or {}
        table.insert(by[id], b.st.speed)
    end
    for id, speeds in pairs(by) do
        T.between(math.max(unpack(speeds)) - math.min(unpack(speeds)), 0, 5,
            id .. ": the same bike rides the same in a crowd")
    end
    T.ok(by.mini[1] < by.stock[1] and by.stock[1] < by.cruiser[1], "and the kinds differ")
    T.eq(#sv.errors, 0, "no errors")
end)

T.test("load: sixteen bikes spawned and removed leave nothing behind", function()
    local sv, bikes = crowd(N)
    local E = sv.env
    for _, b in ipairs(bikes) do b:Remove() end
    sv:run(0.5)
    local left = 0
    for _, id in ipairs(E.BMX.BikeIDs()) do left = left + #E.ents.FindByClass(E.BMX.ClassFor(id)) end
    T.eq(left, 0, "no bikes")
    local pods = 0
    for _, p in ipairs(E.ents.FindByClass("prop_vehicle_prisoner_pod")) do
        if E.IsValid(p) then pods = pods + 1 end
    end
    T.eq(pods, 0, "no orphaned seats")
    local thinks = 0
    for name in pairs(E.hook.GetTable().Think or {}) do
        if tostring(name):find("BMX.PickUp", 1, true) then thinks = thinks + 1 end
    end
    T.eq(thinks, 0, "no per-bike hooks left running")
end)
