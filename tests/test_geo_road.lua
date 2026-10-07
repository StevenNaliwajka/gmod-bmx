--[[--------------------------------------------------------------------------
    The road bike and the fixie as built models: lua/bmx/cl_geo_road.lua.

    Runs the real builders in a bare environment (they must not need the
    game) at their registry sizes (tools/bike/sizes.lua) and checks them
    against docs/MODELS.md's contract: every group and layout anchor there,
    in budget, sound triangles, and the places the rider's pose is tuned to
    (the saddle's top, the bottom bracket, the hands) where they belong.
----------------------------------------------------------------------------]]

local here = (arg and arg[0] or "tests/run.lua"):match("^(.*)/[^/]*$") or "tests"
local ROOT = here .. "/.."

local function geo()
    local env = setmetatable({ BMX = {} }, { __index = _G })
    for _, f in ipairs({ "/lua/bmx/cl_bikegeo.lua", "/lua/bmx/cl_geo_road.lua" }) do
        local chunk = assert(loadfile(ROOT .. f))
        setfenv(chunk, env)
        chunk()
    end
    return env.BMX.BikeGeo
end

local G = geo()
local SIZES = dofile(ROOT .. "/tools/bike/sizes.lua")
local KINDS = { "road", "fixie" }

local function opts(kind)
    local S = SIZES[kind]
    return { kind = kind, wheelbase = S.wheelbase, radius = S.radius, seat = S.seat,
             k = S.wheelbase / 39, restLength = S.restLength }
end

local built, times = {}, {}
for _, kind in ipairs(KINDS) do
    local t0 = os.clock()
    local ok, M = pcall(G.Build, opts(kind))
    times[kind] = os.clock() - t0
    built[kind] = ok and M or nil
    if not ok then built[kind .. "_err"] = M end
end

local function each(M, group, fn)
    for _, b in ipairs(M.groups[group] or {}) do
        for _, v in ipairs(b.v) do fn(v, b) end
    end
end

T.test("road/fixie model: both kinds register and build at their registry size", function()
    for _, kind in ipairs(KINDS) do
        T.ok(G.Kinds[kind] ~= nil, kind .. " is registered")
        T.ok(built[kind] ~= nil, kind .. " builds: " .. tostring(built[kind .. "_err"]))
    end
end)

T.test("road/fixie model: every part, in budget, quickly, with sound triangles", function()
    local V = G.vec
    for _, kind in ipairs(KINDS) do
        local M = built[kind]
        local st = G.Stats(M)
        for _, g in ipairs({ "frame", "fork", "bars", "wheelF", "wheelR", "cranks", "pedal" }) do
            T.ok((st[g] or 0) > 300, kind .. " " .. g .. " has real geometry: " .. tostring(st[g]))
        end
        T.ok((st.bellLever or 0) > 0, kind .. " has the bell's lever")
        T.between(st.total, 40000, 90000, kind .. " triangles in all")
        T.ok(times[kind] < 6.0, kind .. " builds in a few seconds (loose: a loaded CI box): " .. string.format("%.2f", times[kind]))
        local bad, wrong, n = 0, 0, 0
        for _, g in ipairs(M.order) do
            for _, b in ipairs(M.groups[g]) do
                T.eq(#b.v % 3, 0, kind .. " " .. g .. "/" .. b.mat .. " is whole triangles")
                T.ok(b.tris > 0, kind .. " " .. g .. "/" .. b.mat .. " is not empty")
                for i = 1, #b.v, 3 do
                    local a, c, d = b.v[i], b.v[i + 1], b.v[i + 2]
                    for _, v in ipairs({ a, c, d }) do
                        n = n + 1
                        local p, q = v.p, v.n
                        if not (p[1] == p[1] and p[2] == p[2] and p[3] == p[3]) then bad = bad + 1 end
                        if math.abs(V.len(q) - 1) > 1e-3 then bad = bad + 1 end
                    end
                    local gn = V.cross(V.sub(c.p, a.p), V.sub(d.p, a.p))
                    if V.dot(gn, V.add(V.add(a.n, c.n), d.n)) < 0 then wrong = wrong + 1 end
                end
            end
        end
        T.eq(bad, 0, kind .. ": every position finite, every normal unit length, of " .. n)
        T.eq(wrong, 0, kind .. ": winding agrees with normals")
    end
end)

T.test("road/fixie model: every layout anchor the drawing needs", function()
    for _, kind in ipairs(KINDS) do
        local L = built[kind].layout
        local function vec(v, name)
            T.ok(type(v) == "table" and type(v[1]) == "number" and type(v[2]) == "number" and type(v[3]) == "number",
                kind .. " layout." .. name .. " is a point")
        end
        for _, key in ipairs({ "headT", "headB", "steer", "rear", "front", "bb", "stemTop", "bellPivot", "bellAxis" }) do
            vec(L[key], key)
        end
        for _, g in ipairs({ "gripR", "gripL" }) do
            T.ok(type(L[g]) == "table", kind .. " layout." .. g)
            vec(L[g].A, g .. ".A")
            vec(L[g].B, g .. ".B")
        end
        T.near(L.crank, 6.8, 1e-6, kind .. " crank length")
        T.near(L.pedalY, 5.2, 0.3, kind .. " pedal out from the frame")
        local wb = SIZES[kind].wheelbase
        T.near(L.rear[1], -wb / 2, 1e-6, kind .. " rear axle")
        T.near(L.front[1], wb / 2, 1e-6, kind .. " front axle")
        -- the steer axis: unit, up, through both head points
        local V = G.vec
        T.near(V.len(L.steer), 1, 1e-6, kind .. " steer is unit")
        T.ok(L.steer[3] > 0.9 and L.steer[1] < 0, kind .. " steer points up and back")
        local d = V.norm(V.sub(L.headT, L.headB))
        T.near(V.dot(d, L.steer), 1, 1e-6, kind .. " headT-headB lies along the steer axis")
        -- a fork's offset and a believable head angle
        local f = V.sub(L.front, L.headB)
        local off = V.len(V.sub(f, V.mul(L.steer, V.dot(f, L.steer))))
        T.between(off, 1.2, 3.2, kind .. " fork offset")
        local ha = math.deg(math.acos(L.steer[3]))
        T.between(90 - ha, 66, 76, kind .. " head angle")
    end
end)

T.test("road/fixie model: the saddle's top is where the rider sits", function()
    for _, kind in ipairs(KINDS) do
        local S = SIZES[kind]
        local want = { S.seat[1] - 0.5, 0, S.seat[3] + 2.0 }
        local top, highest = -math.huge, -math.huge
        each(built[kind], "frame", function(v, b)
            if b.mat == "seat" then
                highest = math.max(highest, v.p[3])
                if math.abs(v.p[1] - want[1]) < 0.6 and math.abs(v.p[2]) < 0.6 then top = math.max(top, v.p[3]) end
            end
        end)
        T.near(top, want[3], 0.6, kind .. " saddle top over the seat point")
        T.ok(highest < want[3] + 0.6, kind .. " nothing of the saddle stands higher: " .. highest)
    end
end)

T.test("road/fixie model: bottom bracket and hands within the rider's envelope", function()
    for _, kind in ipairs(KINDS) do
        local L = built[kind].layout
        local k = SIZES[kind].wheelbase / 39
        T.near(L.bb[1], -4.5 * k, 1.0, kind .. " bb x")
        T.near(L.bb[2], 0, 1e-6, kind .. " bb y")
        T.near(L.bb[3], 2.5 * k, 1.0, kind .. " bb z")
        -- the BMX's grips, scaled; the hand holds the end nearest the shoulder (A)
        local gx, gz = 10.5 * k, 26 * k
        for _, pair in ipairs({ { L.gripR, -1 }, { L.gripL, 1 } }) do
            local g, s = pair[1], pair[2]
            local A, B = g.A, g.B
            T.between(A[1] - gx, -1.0, 3.2, kind .. " grip A no further forward than the envelope")
            T.between(A[3] - gz, -3.2, 1.0, kind .. " grip A no lower than the envelope")
            T.between(A[2] * s, 6.5, 16.5, kind .. " grip A on its own side, bar-width out")
            T.between(B[2] * s, 6.5, 16.5, kind .. " grip B on its own side")
            T.ok(B[1] >= A[1] - 0.5 and B[1] - gx < 7.0, kind .. " grip B ahead along the hood/horn: " .. B[1])
            T.between(G.vec.len(G.vec.sub(B, A)), 2.0, 6.0, kind .. " a hand's length of grip")
        end
        T.near(L.gripR.A[2], -L.gripL.A[2], 1e-6, kind .. " grips mirror")
    end
end)

T.test("road/fixie model: the wheels are the simulation's size, about their own axles", function()
    for _, kind in ipairs(KINDS) do
        local R = SIZES[kind].radius
        for _, g in ipairs({ "wheelF", "wheelR" }) do
            local rmax, xmax, zmax = 0, 0, 0
            each(built[kind], g, function(v)
                rmax = math.max(rmax, math.sqrt(v.p[1] ^ 2 + v.p[3] ^ 2))
                xmax = math.max(xmax, math.abs(v.p[1]))
                zmax = math.max(zmax, math.abs(v.p[3]))
            end)
            T.between(rmax, R - 0.05, R + 0.15, kind .. " " .. g .. " outer radius")
            T.between(xmax, R - 0.1, R + 0.15, kind .. " " .. g .. " x extent")
            T.between(zmax, R - 0.1, R + 0.15, kind .. " " .. g .. " z extent")
        end
    end
end)

T.test("road/fixie model: a chain on the drive side, and one pedal for both sides", function()
    for _, kind in ipairs(KINDS) do
        local M = built[kind]
        local lo, hi, n = math.huge, -math.huge, 0
        each(M, "frame", function(v, b)
            if b.mat == "steel" and b.detail then
                n = n + 1
                lo, hi = math.min(lo, v.p[2]), math.max(hi, v.p[2])
            end
        end)
        T.ok(n > 3000, kind .. " a chain of links: " .. n)
        T.ok(hi < -1.2 and lo > -2.7, kind .. " chain on the drive side, inside the dropouts: " .. lo .. ".." .. hi)
        -- the pedal is drawn at both crank tips unmirrored: it must be symmetric in y
        local pl, ph = math.huge, -math.huge
        each(M, "pedal", function(v) pl, ph = math.min(pl, v.p[2]), math.max(ph, v.p[2]) end)
        T.near(pl, -ph, 0.05, kind .. " pedal symmetric about its centre")
        -- and it reaches in to the crank's spindle (pedalY out from the frame)
        T.ok(5.2 - ph < 4.0 and 5.2 + pl < 4.0, kind .. " pedal body meets the spindle stub")
    end
end)

T.test("road/fixie model: the builder needs nothing from the game and is deterministic", function()
    for _, kind in ipairs(KINDS) do
        local a = G.Stats(G.Build(opts(kind)))
        T.eq(a.total, G.Stats(built[kind]).total, kind .. " deterministic")
    end
    -- and other sizes still build (a vehicle may be registered bigger or smaller)
    for _, kind in ipairs(KINDS) do
        local o = opts(kind)
        o.wheelbase, o.k, o.radius = o.wheelbase * 0.9, o.k * 0.9, o.radius * 0.95
        o.seat = { o.seat[1] * 0.9, 0, o.seat[3] * 0.9 }
        local ok, err = pcall(G.Build, o)
        T.ok(ok, kind .. " builds at 0.9x: " .. tostring(err))
    end
end)
