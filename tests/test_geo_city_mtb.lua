--[[--------------------------------------------------------------------------
    The city bike, the downhill bike and the e-bike as built models
    (lua/bmx/cl_geo_city.lua, cl_geo_mtb.lua; docs/MODELS.md).

    Each kind is built by its real builder in a bare Lua (no game), at the size
    its vehicle is REGISTERED at (the registry is read from a booted server
    realm, so a change to a vehicle's wheelbase or seat is a change these
    models are checked against), and held to the contract the rider and the
    drawing code depend on: the saddle under the rider, the grips under the
    hands, the cranks on the bottom bracket, the wheels the simulation's size,
    the basket where the server holds props, the suspension's moving parts in
    their own groups.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local here = (arg and arg[0] or "tests/run.lua"):match("^(.*)/[^/]*$") or "tests"
local ROOT = here .. "/../lua/bmx/"

-- The builders in a bare environment: they must not need the game.
local function geo()
    local env = setmetatable({ BMX = {} }, { __index = _G })
    for _, f in ipairs({ "cl_bikegeo.lua", "cl_geo_city.lua", "cl_geo_mtb.lua" }) do
        local chunk = assert(loadfile(ROOT .. f))
        setfenv(chunk, env)
        chunk()
    end
    return env.BMX.BikeGeo
end

local G = geo()
local KINDS = { "city", "dh", "ebike" }

-- The registry, as the game has it.
local sv = F.server()
local B = sv.env.BMX
local function defOf(kind)
    for id, d in pairs(B.Bikes) do
        if d.look == kind then return d, id end
    end
end
local function optsFor(kind)
    local d = defOf(kind)
    local C = B.ConfigFor(d)
    local W = C.Wheel
    local so = C.Chassis.seatOffset
    return {
        kind = kind, wheelbase = W.wheelbase, radius = W.radius, rearRadius = W.rearRadius,
        restLength = W.restLength, k = W.wheelbase / 39, seat = { so.x, so.y, so.z },
    }, d, C
end

local built, opts, times = {}, {}, {}
for _, kind in ipairs(KINDS) do
    opts[kind] = optsFor(kind)
    local t0 = os.clock()
    built[kind] = G.Build(opts[kind])
    times[kind] = os.clock() - t0
end

local function each(M, group, fn, filter)
    for _, b in ipairs(M.groups[group] or {}) do
        if not filter or filter(b) then
            for _, v in ipairs(b.v) do fn(v, b) end
        end
    end
end
local function dist(a, b) return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2) end
local function nearest(M, group, p, filter)
    local best = math.huge
    each(M, group, function(v) best = math.min(best, dist(v.p, p)) end, filter)
    return best
end

T.test("geo city/mtb: every kind is registered, looked up by its vehicle, and builds", function()
    for _, kind in ipairs(KINDS) do
        T.ok(G.Kinds[kind] ~= nil, kind .. " registers a builder")
        T.ok(defOf(kind) ~= nil, "a vehicle asks for look = " .. kind)
        local st = G.Stats(built[kind])
        for _, g in ipairs({ "frame", "fork", "bars", "wheelF", "wheelR", "cranks", "pedal", "bellLever" }) do
            T.ok((st[g] or 0) > 100, kind .. ": " .. g .. " has real geometry: " .. tostring(st[g]))
        end
        T.ok(st.frame > 4000 and st.wheelF > 8000, kind .. ": a frame and wheels worth the name")
    end
end)

T.test("geo city/mtb: in budget, whole, finite, wound the way the normals face", function()
    local V = G.vec
    for _, kind in ipairs(KINDS) do
        local M = built[kind]
        local st = G.Stats(M)
        T.between(st.total, 40000, 90000, kind .. ": triangles in all")
        T.ok(times[kind] < 2.5, kind .. ": builds in under 2 s (offline): " .. string.format("%.2f", times[kind]))
        local bad, wrong, n = 0, 0, 0
        for _, g in ipairs(M.order) do
            for _, b in ipairs(M.groups[g]) do
                T.ok(#b.v > 0, kind .. ": no empty bucket (" .. g .. "/" .. b.mat .. ")")
                T.eq(#b.v % 3, 0, kind .. ": " .. g .. "/" .. b.mat .. " is whole triangles")
                for i = 1, #b.v, 3 do
                    local a, c, d = b.v[i], b.v[i + 1], b.v[i + 2]
                    local gn = V.cross(V.sub(c.p, a.p), V.sub(d.p, a.p))
                    if V.dot(gn, V.add(V.add(a.n, c.n), d.n)) < 0 then wrong = wrong + 1 end
                end
                for _, v in ipairs(b.v) do
                    n = n + 1
                    local p, q = v.p, v.n
                    if not (p[1] == p[1] and p[2] == p[2] and p[3] == p[3]) or math.abs(p[1]) > 200 then bad = bad + 1 end
                    local l = math.sqrt(q[1] * q[1] + q[2] * q[2] + q[3] * q[3])
                    if math.abs(l - 1) > 1e-3 then bad = bad + 1 end
                end
            end
        end
        T.eq(bad, 0, kind .. ": every position finite and every normal unit length, of " .. n)
        T.eq(wrong, 0, kind .. ": winding agrees with normals")
        local again = G.Stats(G.Build(opts[kind]))
        T.eq(again.total, st.total, kind .. ": deterministic")
    end
end)

T.test("geo city/mtb: the layout has every anchor the drawing and the rider use", function()
    for _, kind in ipairs(KINDS) do
        local L = built[kind].layout
        for _, key in ipairs({ "headT", "headB", "steer", "rear", "front", "bb", "stemTop", "bellPivot", "bellAxis" }) do
            local v = L[key]
            T.ok(type(v) == "table" and #v == 3 and v[1] == v[1], kind .. ": layout." .. key)
        end
        for _, g in ipairs({ "gripR", "gripL" }) do
            T.ok(L[g] and L[g].A and L[g].B, kind .. ": layout." .. g .. " has both ends")
        end
        local wb = opts[kind].wheelbase
        T.near(L.rear[1], -wb / 2, 1e-6, kind .. ": rear axle")
        T.near(L.front[1], wb / 2, 1e-6, kind .. ": front axle")
        T.near(L.rear[3], 0, 1e-6, kind .. ": rear axle on the axle line")
        T.near(L.crank, 6.8, 0.3, kind .. ": crank length")
        T.near(L.pedalY, 5.2, 0.3, kind .. ": pedal's offset out")
        local s = L.steer
        T.near(math.sqrt(s[1] ^ 2 + s[2] ^ 2 + s[3] ^ 2), 1, 1e-6, kind .. ": steer is a unit vector")
        T.ok(s[3] > 0.8 and s[1] < 0, kind .. ": the steer axis leans back, up")
        -- the head tube points lie on the steer axis
        local d = G.vec.norm(G.vec.sub(L.headT, L.headB))
        T.ok(G.vec.dot(d, s) > 0.999, kind .. ": headT-headB is along steer")
    end
end)

T.test("geo city/mtb: the saddle's top is where the rider sits", function()
    local role = { city = "leather", dh = "seat", ebike = "seat" }
    for _, kind in ipairs(KINDS) do
        local seat = opts[kind].seat
        local want = { seat[1] - 0.5, 0, seat[3] + 2.0 }
        local top = -math.huge
        local xlo, xhi = math.huge, -math.huge
        each(built[kind], "frame", function(v)
            local p = v.p
            if math.abs(p[1] - want[1]) < 0.8 and math.abs(p[2]) < 1.2 then top = math.max(top, p[3]) end
            if math.abs(p[2]) < 0.5 and p[3] > want[3] - 1.5 then xlo, xhi = math.min(xlo, p[1]), math.max(xhi, p[1]) end
        end, function(b) return b.mat == role[kind] end)
        T.near(top, want[3], 0.6, kind .. ": the saddle's top over the seat")
        T.ok(xlo < want[1] - 2 and xhi > want[1] + 4, kind .. ": a saddle, tail behind and nose ahead: " .. xlo .. ".." .. xhi)
    end
end)

T.test("geo city/mtb: the bottom bracket, the cranks and the grips are where the rider's limbs go", function()
    for _, kind in ipairs(KINDS) do
        local M, k = built[kind], opts[kind].k
        local L = M.layout
        T.ok(dist(L.bb, { -4.5 * k, 0, 2.5 * k }) < 1.0, kind .. ": bb near the BMX's, scaled")
        -- the crank arms end where the layout says the pedals are
        local tip = -math.huge
        each(M, "cranks", function(v)
            if v.p[2] < -2 then tip = math.max(tip, v.p[1] - L.bb[1]) end
        end, function(b) return b.mat ~= "steel" end)
        T.near(tip, L.crank + 0.6, 0.4, kind .. ": the drive-side arm reaches the pedal")
        -- grips: in the envelope the rider's pose is tuned for
        local bx, bz, yin, yout = 10.5 * k, 26 * k, 11 * k, 14.5 * k
        local env = {
            city  = { x = { bx - 7.5, bx + 0.5 }, z = { bz - 1.0, bz + 2.5 }, y = { yin - 1.5, yout + 0.5 } },
            dh    = { x = { bx - 3.0, bx + 1.0 }, z = { bz - 3.2, bz + 0.5 }, y = { 10.0, 16.0 } },
            ebike = { x = { bx - 1.5, bx + 1.5 }, z = { bz - 1.5, bz + 1.0 }, y = { yin - 1.0, yout + 0.5 } },
        }
        local e = env[kind]
        for _, g in ipairs({ "gripR", "gripL" }) do
            local side = (g == "gripR") and -1 or 1
            for _, endp in ipairs({ "A", "B" }) do
                local p = L[g][endp]
                T.between(p[1], e.x[1], e.x[2], kind .. ": " .. g .. "." .. endp .. " x")
                T.between(p[3], e.z[1], e.z[2], kind .. ": " .. g .. "." .. endp .. " z")
                T.between(p[2] * side, e.y[1], e.y[2], kind .. ": " .. g .. "." .. endp .. " y, on its own side")
            end
            T.ok(math.abs(L[g].B[2]) > math.abs(L[g].A[2]), kind .. ": " .. g .. " runs inner to outer")
            -- and there is a grip under the hand: rubber or leather at the hold point
            local A, Bq = L[g].A, L[g].B
            local d = G.vec.norm(G.vec.sub(Bq, A))
            local hold = G.vec.add(A, G.vec.mul(d, math.min(1.75 * k, G.vec.len(G.vec.sub(Bq, A)) * 0.5)))
            local gap = nearest(M, "bars", hold, function(b) return b.mat == "rubber" or b.mat == "leather" end)
            T.ok(gap < 1.1, kind .. ": " .. g .. " has a grip under the hand (" .. string.format("%.2f", gap) .. " away)")
        end
    end
end)

T.test("geo city/mtb: the wheels are the simulation's size, on their own axles", function()
    for _, kind in ipairs(KINDS) do
        local M, R = built[kind], opts[kind].radius
        for _, g in ipairs({ "wheelF", "wheelR" }) do
            local casing, all, ymax = 0, 0, 0
            each(M, g, function(v, b)
                local r = math.sqrt(v.p[1] ^ 2 + v.p[3] ^ 2)
                all = math.max(all, r)
                if not b.detail then casing = math.max(casing, r) end
                ymax = math.max(ymax, math.abs(v.p[2]))
            end)
            T.near(casing, R, 0.06, kind .. " " .. g .. ": the tyre's casing is the wheel radius")
            T.between(all, R - 0.05, R + 0.4, kind .. " " .. g .. ": tread no prouder than a knob")
            T.ok(ymax < 4.5, kind .. " " .. g .. ": built about its own axle (|y| " .. ymax .. ")")
        end
    end
end)

T.test("geo city/mtb: the bell is on the left of the bars, its lever on the hinge", function()
    for _, kind in ipairs(KINDS) do
        local M = built[kind]
        local L = M.layout
        T.ok(L.bellPivot[2] > 5, kind .. ": the bell is on the left")
        T.ok(nearest(M, "bellLever", L.bellPivot) < 0.3, kind .. ": the lever hinges at bellPivot")
        T.ok(nearest(M, "bars", L.bellPivot) < 1.0, kind .. ": the bell sits on the bars")
    end
end)

T.test("geo city: the basket fills the server's basket box, on the frame (it does not steer)", function()
    local M = built.city
    local d = defOf("city")
    local bk = d.basket
    T.ok(bk ~= nil, "the city bike has a basket")
    local lo, hi = { math.huge, math.huge, math.huge }, { -math.huge, -math.huge, -math.huge }
    each(M, "frame", function(v)
        for i = 1, 3 do lo[i], hi[i] = math.min(lo[i], v.p[i]), math.max(hi[i], v.p[i]) end
    end, function(b) return b.mat == "wood" end)
    local mins, maxs = { bk.mins.x, bk.mins.y, bk.mins.z }, { bk.maxs.x, bk.maxs.y, bk.maxs.z }
    for i, axis in ipairs({ "x", "y", "z" }) do
        T.between(lo[i], mins[i] - 0.3, mins[i] + 0.8, "the basket's " .. axis .. " min at the box's")
        T.between(hi[i], maxs[i] - 0.8, maxs[i] + 0.3, "the basket's " .. axis .. " max at the box's")
    end
    for _, g in ipairs({ "fork", "bars", "forkLower" }) do
        local n = 0
        each(M, g, function() n = n + 1 end, function(b) return b.mat == "wood" end)
        T.eq(n, 0, "no basket in the " .. g .. " group")
    end
    -- a carrier under it, on the frame
    local under = 0
    each(M, "frame", function(v)
        local p = v.p
        if p[1] > mins[1] and p[1] < maxs[1] and p[3] < mins[3] and p[3] > mins[3] - 1.5 then under = under + 1 end
    end, function(b) return b.mat == "black" end)
    T.ok(under > 200, "a carrier holds the basket up: " .. under)
    -- and nothing that steers reaches into it
    for _, g in ipairs({ "fork", "bars" }) do
        local inside = 0
        each(M, g, function(v)
            local p = v.p
            if p[1] > mins[1] + 0.5 and p[2] > mins[2] and p[2] < maxs[2] and p[3] > mins[3] and p[3] < maxs[3] then inside = inside + 1 end
        end)
        T.eq(inside, 0, "the " .. g .. " stays out of the basket")
    end
end)

T.test("geo city: the child seat is its own group, where the child sits, clear of the saddle", function()
    local M = built.city
    local o, d, C = optsFor("city")
    local seat = B.SeatFor(d, C, "child")
    T.ok(seat ~= nil, "the city bike has a child seat")
    T.ok((G.Stats(M).childSeat or 0) > 1000, "the child seat is modelled")
    local want = { seat.offset.x - 0.5, 0, seat.offset.z + 2.0 }
    local top = -math.huge
    each(M, "childSeat", function(v)
        if math.abs(v.p[1] - want[1]) < 0.8 and math.abs(v.p[2]) < 0.6 then top = math.max(top, v.p[3]) end
    end, function(b) return b.mat == "seat" end)
    T.near(top, want[3], 0.9, "the cushion's top where the child sits")
    -- nothing of it over the saddle
    local tail = math.huge
    each(M, "frame", function(v) tail = math.min(tail, v.p[1]) end, function(b) return b.mat == "leather" end)
    local front = -math.huge
    each(M, "childSeat", function(v)
        if v.p[3] > o.seat[3] then front = math.max(front, v.p[1]) end
    end)
    T.ok(front < tail - 0.2, "the child seat stays behind the saddle: " .. front .. " vs " .. tail)
end)

T.test("geo dh: a swingarm about its pivot, a shock between frame and swingarm, sliding lowers", function()
    local M = built.dh
    local L = M.layout
    local st = G.Stats(M)
    T.ok((st.swingarm or 0) > 3000, "a swingarm group")
    T.ok((st.forkLower or 0) > 1000, "a forkLower group")
    T.ok(L.swingPivot and L.shock and L.shock.frame and L.shock.swing and L.shock.r, "the layout has the pivot and the shock")
    T.near(L.forkSlide, 6, 1.0, "the fork's travel")
    -- the pivot joins the two; the shock's ends are on their parts
    T.ok(nearest(M, "frame", L.swingPivot) < 1.0, "the pivot is on the frame")
    for _, s in ipairs({ 1, -1 }) do
        local p = { L.swingPivot[1], 1.8 * s, L.swingPivot[3] }
        T.ok(nearest(M, "swingarm", p) < 1.0, "the swingarm hangs on the pivot's axle, side " .. s)
        T.ok(nearest(M, "frame", p) < 1.0, "the pivot's axle runs through, side " .. s)
    end
    T.ok(nearest(M, "frame", L.shock.frame) < 1.0, "the shock's front eye is on the frame")
    T.ok(nearest(M, "swingarm", L.shock.swing) < 1.0, "the shock's rear eye is on the swingarm")
    local sl = dist(L.shock.frame, L.shock.swing)
    T.between(sl, 6, 13, "a shock's length")
    -- the swingarm carries the rear axle at rest, both sides
    for _, s in ipairs({ 1, -1 }) do
        local p = { L.rear[1], L.rear[2] + 3.1 * s, L.rear[3] }
        T.ok(nearest(M, "swingarm", p) < 1.0, "a dropout on the swingarm, side " .. s)
    end
    -- the lowers carry the front axle; the stanchions and crowns do not
    for _, s in ipairs({ 1, -1 }) do
        T.ok(nearest(M, "forkLower", { L.front[1], 2.9 * s, L.front[3] }) < 1.0, "the front axle is in the lowers, side " .. s)
    end
    -- at full travel the lowers stay under the lower crown, the tyre clear of it
    local s = L.steer
    local function along(p) return (p[1] - L.front[1]) * s[1] + (p[2] - L.front[2]) * s[2] + (p[3] - L.front[3]) * s[3] end
    local lowTop = -math.huge
    each(M, "forkLower", function(v) lowTop = math.max(lowTop, along(v.p)) end)
    local crownLo = math.huge
    each(M, "fork", function(v)
        if math.abs(v.p[2]) > 1.5 then crownLo = math.min(crownLo, along(v.p)) end
    end, function(b) return b.mat == "black" end)
    T.ok(lowTop + L.forkSlide < crownLo, "fully compressed, the lowers miss the crown: " .. lowTop .. " + " .. L.forkSlide .. " < " .. crownLo)
    T.ok(crownLo - L.forkSlide > opts.dh.radius + 0.4, "fully compressed, the tyre misses the crown")
end)

T.test("geo ebike: a motor round the bottom bracket, the battery in the down tube", function()
    local M = built.ebike
    local L = M.layout
    local motor = 0
    each(M, "frame", function(v) if dist(v.p, L.bb) < 4.5 then motor = motor + 1 end end, function(b) return b.mat == "plastic" end)
    T.ok(motor > 200, "a motor housing at the bb: " .. motor)
    local batt = 0
    local a, b = L.headB, L.bb
    each(M, "frame", function(v)
        local p = v.p
        local t = ((p[1] - b[1]) * (a[1] - b[1]) + (p[3] - b[3]) * (a[3] - b[3])) / ((a[1] - b[1]) ^ 2 + (a[3] - b[3]) ^ 2)
        if t > 0.25 and t < 0.75 then batt = batt + 1 end
    end, function(bk) return bk.mat == "black" end)
    T.ok(batt > 300, "the battery's cover along the down tube: " .. batt)
end)
