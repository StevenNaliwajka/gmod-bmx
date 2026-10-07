--[[--------------------------------------------------------------------------
    The motor vehicles' models: lua/bmx/cl_geo_moto.lua (the dirt bike, the
    e-moto, the moped), built in code like the BMX (docs/MODELS.md).

    Runs the real builders in a bare environment (they must not need the game)
    at each vehicle's registry size and checks the contract the drawing and the
    rider rely on: the budget, sound triangles, the groups DrawDetailed moves (a
    swingarm and sliding fork lowers on the motorbikes, cranks and a pedal on the
    moped), the anchors, and that the saddle, grips, pegs, pedals and wheels are
    where the rider and the simulation put them.
----------------------------------------------------------------------------]]

local here = (arg and arg[0] or "tests/run.lua"):match("^(.*)/[^/]*$") or "tests"
local ROOT = here .. "/.."

local function geo()
    local env = setmetatable({ BMX = {} }, { __index = _G })
    for _, f in ipairs({ "/lua/bmx/cl_bikegeo.lua", "/lua/bmx/cl_geo_moto.lua" }) do
        local chunk = assert(loadfile(ROOT .. f))
        setfenv(chunk, env)
        chunk()
    end
    return env.BMX.BikeGeo
end

local KINDS = { "dirtbike", "emoto", "moped" }
local MOTO = { dirtbike = true, emoto = true }

-- Built once each, on first use (building costs a second).
local G, SIZES
local built, times = {}, {}
local function model(kind)
    if not G then
        G = geo()
        SIZES = dofile(ROOT .. "/tools/bike/sizes.lua")
    end
    if not built[kind] then
        local S = SIZES[kind]
        local t0 = os.clock()
        built[kind] = G.Build({ kind = kind, wheelbase = S.wheelbase, radius = S.radius, seat = S.seat,
                                restLength = S.restLength, k = S.wheelbase / 39 })
        times[kind] = os.clock() - t0
    end
    return built[kind], SIZES[kind]
end

local function each(M, group, fn, filter)
    for _, b in ipairs(M.groups[group] or {}) do
        if not filter or filter(b) then
            for _, v in ipairs(b.v) do fn(v, b) end
        end
    end
end

local function dist(a, b)
    return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2)
end

-- How near a group comes to a line across the bike (an axle, a pivot) through p.
local function nearestAcross(M, group, p, ymax)
    local best = math.huge
    each(M, group, function(v)
        if math.abs(v.p[2]) < ymax then best = math.min(best, math.sqrt((v.p[1] - p[1]) ^ 2 + (v.p[3] - p[3]) ^ 2)) end
    end)
    return best
end

-- The nearest vertex of a group to a point.
local function nearest(M, group, p)
    local best = math.huge
    each(M, group, function(v) best = math.min(best, dist(v.p, p)) end)
    return best
end

T.test("moto models: all three register and build at their registry sizes, in budget", function()
    for _, kind in ipairs(KINDS) do
        local M = model(kind)
        local st = G.Stats(M)
        T.between(st.total, 40000, 90000, kind .. " triangles in all")
        -- export.lua's budget is 2 s; a slow CI box gets some headroom
        T.ok(times[kind] < 3.0, kind .. " builds in " .. string.format("%.2f", times[kind]) .. " s")
        for _, g in ipairs({ "frame", "fork", "bars", "wheelF", "wheelR" }) do
            T.ok((st[g] or 0) > 500, kind .. " " .. g .. " has real geometry: " .. tostring(st[g]))
        end
        T.ok(st.frame > 12000, kind .. " is a motorbike's worth of frame, engine and bodywork, not a bicycle's: " .. st.frame)
    end
end)

T.test("moto models: every triangle whole and finite, its winding agrees with its normals", function()
    local V = nil
    for _, kind in ipairs(KINDS) do
        local M = model(kind)
        V = G.vec
        local bad, n, agree, total = 0, 0, 0, 0
        for _, g in ipairs(M.order) do
            for _, b in ipairs(M.groups[g]) do
                T.eq(#b.v % 3, 0, kind .. " " .. g .. "/" .. b.mat .. " is whole triangles")
                T.ok(#b.v > 0, kind .. " " .. g .. "/" .. b.mat .. " is not an empty bucket")
                for i = 1, #b.v, 3 do
                    local a, c, d = b.v[i], b.v[i + 1], b.v[i + 2]
                    local gn = V.cross(V.sub(c.p, a.p), V.sub(d.p, a.p))
                    local s = V.add(V.add(a.n, c.n), d.n)
                    total = total + 1
                    if V.dot(gn, s) >= 0 then agree = agree + 1 end
                end
                for _, v in ipairs(b.v) do
                    n = n + 1
                    local p, q = v.p, v.n
                    if not (p[1] == p[1] and p[2] == p[2] and p[3] == p[3]) then bad = bad + 1 end
                    if math.abs(math.sqrt(q[1] * q[1] + q[2] * q[2] + q[3] * q[3]) - 1) > 1e-3 then bad = bad + 1 end
                end
            end
        end
        T.eq(bad, 0, kind .. ": every position finite and every normal unit length, of " .. n)
        T.eq(agree, total, kind .. ": winding agrees with normals")
    end
end)

T.test("moto models: the groups the drawing moves are there", function()
    for _, kind in ipairs(KINDS) do
        local M = model(kind)
        if MOTO[kind] then
            for _, g in ipairs({ "swingarm", "forkLower" }) do
                T.ok(M.groups[g] and G.Stats(M)[g] > 500, kind .. " has a " .. g)
            end
            T.ok(M.groups.cranks == nil and M.groups.pedal == nil, kind .. " has pegs, not cranks")
        else
            T.ok(M.groups.cranks and G.Stats(M).cranks > 500, kind .. " has cranks")
            T.ok(M.groups.pedal and G.Stats(M).pedal > 100, kind .. " has a pedal")
            T.ok(M.groups.swingarm == nil and M.groups.forkLower == nil, kind .. " is rigid")
        end
        T.ok(M.groups.bellLever == nil, kind .. " honks: no bell lever")
    end
end)

T.test("moto models: the layout has every anchor the drawing and the rider need", function()
    for _, kind in ipairs(KINDS) do
        local M, S = model(kind)
        local L = M.layout
        local function vec(v, what) T.ok(type(v) == "table" and type(v[1]) == "number" and #v == 3, kind .. " layout." .. what) end
        for _, key in ipairs({ "headT", "headB", "steer", "rear", "front", "stemTop" }) do vec(L[key], key) end
        for _, g in ipairs({ "gripR", "gripL" }) do vec(L[g] and L[g].A, g .. ".A"); vec(L[g] and L[g].B, g .. ".B") end
        T.near(G.vec.len(L.steer), 1, 1e-6, kind .. " steer is a unit vector")
        T.ok(L.steer[3] > 0.85 and L.steer[1] < 0, kind .. " steer points up and back (rake)")
        T.near(L.rear[1], -S.wheelbase / 2, 1e-6, kind .. " rear axle")
        T.near(L.front[1], S.wheelbase / 2, 1e-6, kind .. " front axle")
        T.near(L.rear[3], 0, 1e-6, kind .. " rear axle height")
        T.near(L.front[3], 0, 1e-6, kind .. " front axle height")
        T.ok(L.bellPivot == nil, kind .. " has no bell")
        -- the head tube's anchors lie on the steer axis
        local d = G.vec.norm(G.vec.sub(L.headT, L.headB))
        T.near(G.vec.dot(d, L.steer), 1, 1e-6, kind .. " headT-headB along steer")
        if MOTO[kind] then
            vec(L.pegs and L.pegs.r, "pegs.r"); vec(L.pegs and L.pegs.l, "pegs.l")
            vec(L.swingPivot, "swingPivot")
            vec(L.shock and L.shock.frame, "shock.frame"); vec(L.shock and L.shock.swing, "shock.swing")
            T.ok(type(L.shock.r) == "number" and L.shock.r > 0.5, kind .. " shock radius")
            T.between(L.forkSlide or 0, 4, 9, kind .. " forkSlide")
        else
            vec(L.bb, "bb")
            T.ok(type(L.crank) == "number" and type(L.pedalY) == "number", kind .. " crank and pedalY")
            T.ok(L.pegs == nil and L.swingPivot == nil and L.forkSlide == nil, kind .. " is rigid and pedals")
        end
    end
end)

T.test("moto models: the saddle's top is where the rider sits", function()
    for _, kind in ipairs(KINDS) do
        local M, S = model(kind)
        local want = { S.seat[1] - 0.5, 0, S.seat[3] + 2.0 }
        local top = -math.huge
        each(M, "frame", function(v)
            if math.abs(v.p[1] - want[1]) < 0.8 and math.abs(v.p[2]) < 0.6 then top = math.max(top, v.p[3]) end
        end, function(b) return b.mat == "seat" end)
        T.near(top, want[3], 0.6, kind .. " saddle top at seat + (-0.5, 0, 2)")
        -- and nothing of the frame stands above it there (the rider would sit in it)
        local over = -math.huge
        each(M, "frame", function(v)
            if math.abs(v.p[1] - want[1]) < 1.5 and math.abs(v.p[2]) < 2 then over = math.max(over, v.p[3]) end
        end, function(b) return b.mat ~= "seat" end)
        T.ok(over < top, kind .. " nothing but the saddle at the rider's seat: " .. over)
    end
end)

T.test("moto models: the grips are where a seated rider's hands land", function()
    for _, kind in ipairs(KINDS) do
        local M, S = model(kind)
        local k = S.wheelbase / 39
        local L = M.layout
        local bx, bz = 10.5 * k, 26 * k                      -- the BMX's grips, scaled
        local back = (kind == "moped") and 6.5 or 3.2         -- swept or MX bars sit further back
        for _, side in ipairs({ { "gripR", -1 }, { "gripL", 1 } }) do
            local g, sd = L[side[1]], side[2]
            for _, e in ipairs({ "A", "B" }) do
                local p = g[e]
                T.between(p[1], bx - back, bx + 0.5, kind .. " " .. side[1] .. "." .. e .. " x")
                T.between(p[3], bz - 4.2, bz + 0.5, kind .. " " .. side[1] .. "." .. e .. " z")
                T.ok(p[2] * sd > 0, kind .. " " .. side[1] .. " is on its side (right is -y)")
            end
            T.between(math.abs(g.A[2]), 8.5, 12, kind .. " " .. side[1] .. " inner end")
            T.between(math.abs(g.B[2]), 13, 16.5, kind .. " " .. side[1] .. " outer end")
            T.ok(math.abs(g.B[2]) - math.abs(g.A[2]) > 3.5, kind .. " a grip's length")
            -- rubber on the bar where the hand goes
            local mid = { (g.A[1] + g.B[1]) / 2, (g.A[2] + g.B[2]) / 2, (g.A[3] + g.B[3]) / 2 }
            local near = math.huge
            each(M, "bars", function(v) near = math.min(near, dist(v.p, mid)) end, function(b) return b.mat == "rubber" end)
            T.ok(near < 1.0, kind .. " a rubber grip at " .. side[1] .. ": " .. near)
        end
    end
end)

T.test("moto models: the feet go on pegs under the seat, or on the pedals", function()
    for _, kind in ipairs(KINDS) do
        local M, S = model(kind)
        local k = S.wheelbase / 39
        local bb = { -4.5 * k, 0, 2.5 * k }                  -- the BMX's bottom bracket, scaled
        local L = M.layout
        if MOTO[kind] then
            for _, side in ipairs({ { "r", -1 }, { "l", 1 } }) do
                local p = L.pegs[side[1]]
                T.near(p[1], bb[1], 2, kind .. " peg " .. side[1] .. " x")
                T.near(p[3], bb[3], 2, kind .. " peg " .. side[1] .. " z")
                T.between(p[2] * side[2], 5.5, 7, kind .. " peg " .. side[1] .. " out to the side")
                T.ok(nearest(M, "frame", p) < 0.6, kind .. " a footpeg is built at peg " .. side[1])
            end
            T.ok(L.pegs.r[1] > S.seat[1], kind .. " pegs ahead of the seat")
        else
            T.near(L.bb[1], bb[1], 0.6, kind .. " bb x")
            T.near(L.bb[3], bb[3], 0.6, kind .. " bb z")
            T.near(L.bb[2], 0, 1e-9, kind .. " bb on the centre line")
            T.near(L.crank, 6.8, 0.3, kind .. " crank length")
            T.between(L.pedalY, 4.5, 6, kind .. " pedal out from the bb")
            -- the cranks are built about the bb, the right arm forward
            local fwdR = 0
            each(M, "cranks", function(v)
                if v.p[2] < -2.5 and v.p[1] > L.bb[1] + L.crank - 0.8 then fwdR = fwdR + 1 end
            end)
            T.ok(fwdR > 20, kind .. " the right crank points forward at rest")
            -- the pedal clears the ground at the bottom of its stroke
            T.ok(L.bb[3] - L.crank > -S.radius + 3, kind .. " pedal clears the ground")
        end
    end
end)

T.test("moto models: the wheels are the simulation's, each about its own axle", function()
    for _, kind in ipairs(KINDS) do
        local M, S = model(kind)
        for _, g in ipairs({ "wheelF", "wheelR" }) do
            local rmax, lo, hi = 0, math.huge, -math.huge
            each(M, g, function(v)
                local r = math.sqrt(v.p[1] ^ 2 + v.p[3] ^ 2)
                rmax = math.max(rmax, r)
                lo, hi = math.min(lo, v.p[1]), math.max(hi, v.p[1])
            end)
            T.between(rmax, S.radius - 0.1, S.radius + 0.12, kind .. " " .. g .. " outer radius")
            T.near((lo + hi) / 2, 0, 0.1, kind .. " " .. g .. " centred on its axle")
            -- a moto tyre, not a bicycle's
            local w = 0
            each(M, g, function(v) w = math.max(w, math.abs(v.p[2])) end, function(b) return b.mat == "rubber" and not b.detail end)
            T.between(w, 1.0, 2.2, kind .. " " .. g .. " tyre half-width")
        end
    end
end)

T.test("moto models: the swingarm holds the rear axle, the shock joins frame and swingarm", function()
    for _, kind in ipairs({ "dirtbike", "emoto" }) do
        local M = model(kind)
        local L = M.layout
        T.ok(nearestAcross(M, "swingarm", L.rear, 6) < 0.6, kind .. " the swingarm holds the rear axle")
        T.ok(nearestAcross(M, "swingarm", L.swingPivot, 6) < 1.3, kind .. " the swingarm is on its pivot")
        T.ok(nearestAcross(M, "frame", L.swingPivot, 6) < 0.6, kind .. " the frame carries the pivot")
        T.ok(nearest(M, "frame", L.shock.frame) < 1.2, kind .. " the shock's top mount is on the frame")
        T.ok(nearest(M, "swingarm", L.shock.swing) < 1.2, kind .. " the shock's bottom mount is on the swingarm")
        T.ok(L.swingPivot[1] > L.rear[1] + 12 and L.swingPivot[1] < 0, kind .. " the pivot is ahead of the wheel, behind the middle")
        -- the fork lowers carry the front axle; the uppers clear it by the slide
        T.ok(nearestAcross(M, "forkLower", L.front, 6) < 0.6, kind .. " the fork lowers hold the front axle")
    end
end)

T.test("moto models: a motorbike's parts, not a bicycle's", function()
    local function has(M, group, mat)
        for _, b in ipairs(M.groups[group] or {}) do if b.mat == mat and b.tris > 0 then return true end end
    end
    local db = model("dirtbike")
    T.ok(has(db, "frame", "white") and has(db, "fork", "white"), "dirt bike: white plastics (fenders, plates)")
    T.ok(has(db, "swingarm", "steel"), "dirt bike: a chain")
    local em = model("emoto")
    T.ok(has(em, "fork", "lens"), "e-moto: a headlight")
    T.ok(has(em, "frame", "redlens"), "e-moto: a tail light")
    local mp = model("moped")
    T.ok(has(mp, "bars", "lens"), "moped: a headlight on the bars")
    T.ok(has(mp, "frame", "redlens"), "moped: a tail light")
    -- the exhaust runs up the dirt bike's right side
    local right = 0
    each(db, "frame", function(v) if v.p[2] < -5 and v.p[1] < -20 then right = right + 1 end end,
         function(b) return b.mat == "alloy" end)
    T.ok(right > 200, "dirt bike: the silencer is on the right")
end)

T.test("moto models: the builders need nothing from the game, and build the same twice", function()
    local a = model("moped")
    local G2 = geo()
    local S = SIZES.moped
    local b = G2.Build({ kind = "moped", wheelbase = S.wheelbase, radius = S.radius, seat = S.seat, k = S.wheelbase / 39 })
    T.eq(G.Stats(a).total, G2.Stats(b).total, "deterministic")
    -- another size scales the model with it (the frame), the wheels at their own radius
    local c = G2.Build({ kind = "dirtbike", wheelbase = 52, radius = 13, seat = { -13.4, 0, 22.9 }, k = 52 / 39 })
    T.near(c.layout.rear[1], -26, 1e-6, "a smaller dirt bike's rear axle")
    local rmax = 0
    for _, bk in ipairs(c.groups.wheelF) do for _, v in ipairs(bk.v) do rmax = math.max(rmax, math.sqrt(v.p[1] ^ 2 + v.p[3] ^ 2)) end end
    T.between(rmax, 12.9, 13.12, "its front wheel at its radius")
end)
