--[[--------------------------------------------------------------------------
    The skateboard, the kick scooter and the inline skates as built models:
    lua/bmx/cl_geo_board.lua (the triangles) and their drawers (cl_board.lua,
    cl_scooter.lua, cl_skates.lua) placing them.

    The geometry half runs the real builders at the registry's sizes and checks
    each model is sound, in budget, and built to the simulation: the board's
    wheels on the ground under its axles and its deck where the rider stands, the
    scooter's tyres the simulation's and its grips where the hands go, the skates'
    wheels where BootFrame stands them. The drawing half gives the client the fake
    Mesh API test_bikemodel.lua uses and checks each drawer draws the model's
    groups once it is built, by rigid transforms, and hands the rider EXACTLY the
    targets the primitive drawing does.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local here = (arg and arg[0] or "tests/run.lua"):match("^(.*)/[^/]*$") or "tests"
local GEO = here .. "/../lua/bmx/cl_bikegeo.lua"
local BOARD = here .. "/../lua/bmx/cl_geo_board.lua"

-- The builders in a bare environment: they must not need the game.
local function geo()
    local env = setmetatable({ BMX = {} }, { __index = _G })
    for _, f in ipairs({ GEO, BOARD }) do
        local chunk = assert(loadfile(f))
        setfenv(chunk, env)
        chunk()
    end
    return env.BMX.BikeGeo
end
local G = geo()

-- The registry's sizes, from a booted server, as each drawer hands them to the builder.
local SV = F.server()
local BX = SV.env.BMX
local function cfgOf(id) return BX.ConfigFor(BX.Vehicles[id]) end
local function opts(id)
    local C = cfgOf(id)
    local WC = C.Wheel
    local o = { kind = BX.Vehicles[id].look, k = WC.wheelbase / 39, radius = WC.radius, wheelbase = WC.wheelbase,
                restLength = WC.restLength }
    if id == "skateboard" then
        o.extra = { track = math.abs(BX.Board.Wheels(C)[1].pos.y) }
    elseif id == "scooter" then
        local T = BX.Scooter.Tune
        o.extra = { deckTop = T.deckTop, deckFront = T.deckFront, deckBack = T.deckBack, deckWidth = T.deckWidth,
                    barHeight = T.barHeight, barWidth = T.barWidth, headFoot = T.headFoot, headLean = T.headLean,
                    pegY = T.pegY }
    elseif id == "skates" then
        o.k = 1
        o.extra = { wheelPitch = BX.Skates.Tune.wheelPitch }
    end
    return o
end

local IDS = { "skateboard", "scooter", "skates" }
local GROUPS = {
    skateboard = { "deck", "truck", "hanger", "wheel" },
    scooter = { "deck", "fork", "bars", "bellLever", "wheel" },
    skates = { "skate", "skateOutL", "skateOutR", "wheel", "wheelAR" },
}
local built, took = {}, {}
for _, id in ipairs(IDS) do
    local t0 = os.clock()
    built[id] = G.Build(opts(id))
    took[id] = os.clock() - t0
end

local function each(M, group, fn)
    for _, b in ipairs(M.groups[group] or {}) do
        for _, v in ipairs(b.v) do fn(v, b) end
    end
end

T.test("board models: each kind builds at its registry size, every part, in budget, quickly", function()
    for _, id in ipairs(IDS) do
        local M = built[id]
        T.eq(BX.Vehicles[id].look, id, id .. " asks for its own model")
        local st = G.Stats(M)
        for _, g in ipairs(GROUPS[id]) do
            T.ok((st[g] or 0) > 60, id .. ": " .. g .. " has real geometry: " .. tostring(st[g]))
        end
        T.between(st.total, 8000, 60000, id .. ": triangles in all")
        T.ok(took[id] < 2, id .. " builds in under 2 s: " .. string.format("%.2f", took[id]))
        T.eq(M.groups.wheelR, nil, id .. ": no preview-only group in the game's model")
    end
end)

T.test("board models: no broken vertices, whole triangles, no empty buckets, faces the way the normals do", function()
    local V = G.vec
    for _, id in ipairs(IDS) do
        local M = built[id]
        local bad, n, agree, total = 0, 0, 0, 0
        for _, g in ipairs(M.order) do
            for _, b in ipairs(M.groups[g]) do
                T.ok(#b.v > 0, id .. "/" .. g .. "/" .. b.mat .. " is not empty")
                T.eq(#b.v % 3, 0, id .. "/" .. g .. "/" .. b.mat .. " is whole triangles")
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
                    local l = math.sqrt(q[1] * q[1] + q[2] * q[2] + q[3] * q[3])
                    if math.abs(l - 1) > 1e-3 then bad = bad + 1 end
                end
            end
        end
        T.eq(bad, 0, id .. ": every position finite and every normal unit length, of " .. n)
        T.eq(agree, total, id .. ": winding agrees with normals")
    end
end)

T.test("board models: the offline preview's sizes (tools/bike/sizes.lua) are the registry's", function()
    local sizes = dofile(here .. "/../tools/bike/sizes.lua")
    for _, id in ipairs(IDS) do
        local o, s = opts(id), sizes[BX.Vehicles[id].look]
        T.ok(s, id .. " has a preview size")
        T.eq(s.wheelbase, o.wheelbase, id .. ": wheelbase")
        T.eq(s.radius, o.radius, id .. ": wheel radius")
        for k, v in pairs(o.extra or {}) do
            T.eq(s.extra and s.extra[k], v, id .. ": " .. k)
        end
    end
end)

T.test("board models: the builders need nothing from the game and build the same model twice", function()
    for _, id in ipairs(IDS) do
        T.eq(G.Stats(G.Build(opts(id))).total, G.Stats(built[id]).total, id .. " is deterministic")
    end
end)

--------------------------------------------------------------------------
-- Built to the simulation
--------------------------------------------------------------------------
T.test("skateboard model: an 8.0 x 31.75 deck where the rider stands, 54 mm wheels on the ground under the axles", function()
    local M = built.skateboard
    local L = M.layout
    local C = cfgOf("skateboard")
    local lo, hi, wmax, top = math.huge, -math.huge, 0, -math.huge
    each(M, "deck", function(v)
        lo, hi = math.min(lo, v.p[1]), math.max(hi, v.p[1])
        wmax = math.max(wmax, math.abs(v.p[2]))
        if math.abs(v.p[1]) < 3 and math.abs(v.p[2]) < 0.3 then top = math.max(top, v.p[3]) end
    end)
    T.near(hi - lo, 31.75, 0.15, "a 31.75 deck")
    T.near(wmax, 4.0, 0.05, "8.0 wide")
    T.near(top, 1.8, 0.05, "its top where the board's feet are (FOOT_Z 4.6 is the ankle over it)")
    -- the nose and tail are kicked up
    local tipZ = -math.huge
    each(M, "deck", function(v) if v.p[1] > hi - 0.5 then tipZ = math.max(tipZ, v.p[3]) end end)
    T.ok(tipZ > top + 1.5, "the nose kicks up: " .. tipZ)
    -- the wheel: 54 mm, 32 wide, round its own axle
    local rmax, ymax = 0, 0
    each(M, "wheel", function(v)
        rmax = math.max(rmax, math.sqrt(v.p[1] ^ 2 + v.p[3] ^ 2))
        ymax = math.max(ymax, math.abs(v.p[2]))
    end)
    T.near(rmax, 54 / 25.4 / 2, 0.02, "a 54 mm wheel")
    T.between(ymax, 0.6, 0.7, "32 mm wide")
    -- on the axles the simulation has, standing on its ground (the static sag's)
    local g = SV.world.gravity
    local sag = math.min(C.Chassis.mass * g / 4 / C.Wheel.spring, C.Wheel.restLength)
    local ground = -(C.Wheel.radius - sag)
    T.near(L.front[1], C.Wheel.wheelbase / 2, 1e-9, "the front axle over the simulation's")
    T.near(L.rear[1], -C.Wheel.wheelbase / 2, 1e-9, "the rear one")
    T.near(L.front[3] - L.wheelR, ground, 0.02, "the wheels stand on the ground")
    T.near(L.truckAt[1] + L.axle[1], C.Wheel.wheelbase / 2, 1e-9, "the truck's axle is the wheel's")
    T.near(L.truckAt[3] + L.axle[3], L.front[3], 1e-9, "...at the wheel's height")
    T.near(L.track, 4.6, 1e-9, "the simulation's track")
    -- the deck clears the wheels
    T.ok(L.front[3] + L.wheelR < top - 0.45 - 0.2, "wheel bite: the wheels clear the deck's underside")
    -- the hanger's underside is where a 50-50 grinds (sh_board.lua T.truckZ)
    local hz = math.huge
    each(M, "hanger", function(v, b) if b.mat == "alloy" and math.abs(v.p[2]) < 3 then hz = math.min(hz, v.p[3]) end end)
    T.near(L.truckAt[3] + hz, BX.Board.Tune.truckZ - 0.3, 0.35, "the hanger's grinding face near the truck grinds' contact")
end)

T.test("scooter model: the simulation's tyres, the grips where the hands go, the deck where the feet do, clear of the tyres", function()
    local M = built.scooter
    local L = M.layout
    local C = cfgOf("scooter")
    local T0 = BX.Scooter.Tune
    local R = C.Wheel.radius
    local rmax = 0
    each(M, "wheel", function(v) rmax = math.max(rmax, math.sqrt(v.p[1] ^ 2 + v.p[3] ^ 2)) end)
    T.between(rmax, R - 0.05, R + 0.05, "the tyre is the simulation's wheel")
    T.near(L.front[1], C.Wheel.wheelbase / 2, 1e-9, "front axle")
    T.near(L.rear[1], -C.Wheel.wheelbase / 2, 1e-9, "rear axle")
    -- cl_scooter.lua's hands: on the bar at the bars' point, 1.8 in from each end
    for _, s in ipairs({ 1, -1 }) do
        local n, cx, cy, cz = 0, 0, 0, 0
        for _, b in ipairs(M.groups.bars) do
            if b.mat == "rubber" then
                for _, v in ipairs(b.v) do
                    if v.p[2] * s > 0 then n, cx, cy, cz = n + 1, cx + v.p[1], cy + v.p[2], cz + v.p[3] end
                end
            end
        end
        T.ok(n > 100, "a grip on each side")
        T.near(cx / n, L.bars[1], 0.05, "grip on the bar line")
        T.near(cz / n, T0.barHeight, 0.05, "at the bars' height")
        local hand = T0.barWidth * 0.5 - 1.8
        T.between(math.abs(cy / n), hand - 1.2, hand + 1.2, "round where the hand holds")
    end
    local top = -math.huge
    each(M, "deck", function(v, b) if b.mat == "rubber" then top = math.max(top, v.p[3]) end end)
    T.near(top, T0.deckTop, 0.02, "the grip tape is the deck's top the feet stand on")
    -- nothing of the deck or the fork inside a tyre (the hub's axle and spacers excepted)
    local tw = 0.4 * R
    local inside = 0
    for _, g in ipairs({ "deck", "fork" }) do
        each(M, g, function(v)
            if math.abs(v.p[2]) < tw * 0.5 - 0.05 then
                for _, a in ipairs({ L.front, L.rear }) do
                    local d = math.sqrt((v.p[1] - a[1]) ^ 2 + (v.p[3] - a[3]) ^ 2)
                    if d > 1.2 and d < R + 0.2 then inside = inside + 1 end
                end
            end
        end)
    end
    T.eq(inside, 0, "the deck, neck and fork clear the tyres by a fifth of an inch")
    T.ok(L.bellPivot and L.bellAxis, "the bell's lever has its hinge")
end)

T.test("skates model: 55 mm wheels where BootFrame stands them, the anti-rockers clear of the ground", function()
    local M = built.skates
    local L = M.layout
    local C = cfgOf("skates")
    -- BootFrame is the client's (cl_skates.lua)
    local CL = F.client(SV.world)
    local S = CL.env.BMX.Skates
    local Vc = CL.env.Vector
    local fr = S.BootFrame(Vc(0, 0, 0), 0, C.Wheel.radius)
    local contact = fr.wheels[1].z - C.Wheel.radius
    T.near(L.contact, contact, 1e-9, "the contact is BootFrame's")
    T.eq(#L.wheels + #L.antiRockers, 4, "four wheels a boot")
    local xs = {}
    for _, w in ipairs(L.wheels) do
        T.near(w[3] - L.wheelR, contact, 1e-9, "a wheel on the ground")
        xs[#xs + 1] = w[1]
    end
    for _, w in ipairs(L.antiRockers) do
        T.ok(w[3] - L.arR > contact + 0.15, "an anti-rocker clear of it")
        xs[#xs + 1] = w[1]
    end
    table.sort(xs)
    local want = {}
    for _, c in ipairs(fr.wheels) do want[#want + 1] = c.x end
    table.sort(want)
    for i = 1, 4 do T.near(xs[i], want[i], 1e-9, "wheel " .. i .. " at BootFrame's pitch") end
    T.near(L.wheelR * 2 * 25.4, 55, 0.5, "55 mm")
    -- the boot covers the foot: heel behind the ankle, toes well ahead, a cuff up the shin
    local lo, hi, ztop = math.huge, -math.huge, 0
    each(M, "skate", function(v)
        lo, hi = math.min(lo, v.p[1]), math.max(hi, v.p[1])
        ztop = math.max(ztop, v.p[3])
    end)
    T.ok(lo < -3.5 and hi > 6.5, "a boot from the heel to past the toes: " .. lo .. ".." .. hi)
    T.between(ztop, 8.5, 10.5, "its cuff up the shin")
    -- nothing of the boot or the frame inside a wheel
    local inside = 0
    each(M, "skate", function(v)
        if math.abs(v.p[2]) < 0.4 then
            for _, w in ipairs(L.wheels) do
                local d = math.sqrt((v.p[1] - w[1]) ^ 2 + (v.p[3] - w[3]) ^ 2)
                if d > 0.3 and d < L.wheelR - 0.02 then inside = inside + 1 end
            end
        end
    end)
    T.eq(inside, 0, "the frame and the soul plate clear the wheels")
end)

--------------------------------------------------------------------------
-- DRAWING, with a fake mesh API (test_bikemodel.lua's)
--------------------------------------------------------------------------
local function fakeMatrix(E, rows)
    local m = { rows = rows }
    function m:Col(i) return E.Vector(rows[1][i], rows[2][i], rows[3][i]) end
    function m:GetTranslation() return self:Col(4) end
    function m:Apply(p)
        return E.Vector(rows[1][1] * p.x + rows[1][2] * p.y + rows[1][3] * p.z + rows[1][4],
                        rows[2][1] * p.x + rows[2][2] * p.y + rows[2][3] * p.z + rows[2][4],
                        rows[3][1] * p.x + rows[3][2] * p.y + rows[3][3] * p.z + rows[3][4])
    end
    return m
end

local function enableMeshes(cl)
    local E, R = cl.env, cl
    local frame = 0
    R.groups, R.meshVerts, R.drawn = {}, 0, 0
    local orig = E.Matrix
    E.Matrix = function(t) if type(t) == "table" then return fakeMatrix(E, t) end return orig() end
    E.SysTime = os.clock
    E.FrameNumber = function() frame = frame + 1 return frame end
    E.GetRenderTargetEx = function(name) return { name = name } end
    E.CreateMaterial = function(name, shader, kv)
        local m = { name = name, shader = shader, kv = kv }
        function m:SetTexture(k, t) self[k] = t end
        return m
    end
    E.Mesh = function()
        local m = { valid = true }
        function m:BuildFromTriangles(v)
            assert(#v > 0 and #v % 3 == 0 and #v <= 65535, "a mesh of whole triangles under the limit")
            R.meshVerts = R.meshVerts + #v
            for i = 1, #v, 3 do
                local a, b, c = v[i], v[i + 1], v[i + 2]
                local g = (b.pos - a.pos):Cross(c.pos - a.pos)
                if g:Dot(a.normal + b.normal + c.normal) > 0 then R.ccw = (R.ccw or 0) + 1 end
            end
        end
        function m:Draw() R.drawn = R.drawn + 1 end
        function m:Destroy() self.valid = false end
        function m:IsValid() return self.valid end
        return m
    end
    local r = E.render
    for _, k in ipairs({ "PushRenderTarget", "PopRenderTarget", "Clear", "SetModelLighting", "SetLocalModelLights",
            "OverrideAlphaWriteEnable" }) do r[k] = function() end end
    r.SuppressEngineLighting = function(b) R.suppressed = b end
    E.cam.Start2D = function() end
    E.cam.End2D = function() end
    r.ComputeLighting = function(pos, dir) return E.Vector(0.1, 0.1, 0.1) + E.Vector(0.4, 0.4, 0.35) * math.max(dir.z, 0) end
    r.ComputeDynamicLighting = function() return E.Vector(0, 0, 0) end
    r.SetMaterial = function(m) R.material = m end
    E.cam.PushModelMatrix = function() end
    E.cam.PopModelMatrix = function() end
    local BM = E.BMX.BikeMesh
    local drawGroup = BM.DrawGroup
    BM.DrawGroup = function(model, name, mtx, paint, lod)
        R.groups[#R.groups + 1] = { name = name, m = mtx, paint = paint, lod = lod }
        return drawGroup(model, name, mtx, paint, lod)
    end
end

local function reset(cl)
    cl.lines, cl.beams, cl.drawnModels, cl.boxes3d = 0, {}, 0, 0
    cl.drawnCS, cl.groups, cl.drawn = {}, {}, 0
end

local function named(cl, name)
    local out = {}
    for _, g in ipairs(cl.groups) do if g.name == name then out[#out + 1] = g.m end end
    return out
end

local function counts(cl)
    local c = {}
    for _, g in ipairs(cl.groups) do c[g.name] = (c[g.name] or 0) + 1 end
    return c
end

local function rigid(cl, label)
    for _, g in ipairs(cl.groups) do
        local x, y, z = g.m:Col(1), g.m:Col(2), g.m:Col(3)
        T.near(x:Length(), 1, 1e-6, label .. " " .. g.name .. " x unit")
        T.near(y:Length(), 1, 1e-6, label .. " " .. g.name .. " y unit")
        T.near(z:Length(), 1, 1e-6, label .. " " .. g.name .. " z unit")
        T.near(x:Dot(y), 0, 1e-6, label .. " " .. g.name .. " x.y")
        T.near(x:Cross(y):Dot(z), 1, 1e-6, label .. " " .. g.name .. " right-handed")
        T.finite(g.m:GetTranslation(), label .. " " .. g.name .. " placed")
    end
end

local function sameTargets(a, b, label)
    local n = 0
    for k, v in pairs(a) do
        n = n + 1
        T.ok(b[k] ~= nil, label .. ": " .. k .. " is still a target")
        if b[k] then T.near((b[k] - v):Length(), 0, 1e-9, label .. ": " .. k .. " where the primitive drawing put it") end
    end
    for k in pairs(b) do T.ok(a[k] ~= nil, label .. ": no new target " .. k) end
    T.ok(n >= 4, label .. ": both hands and both feet")
end

-- A client entity drawn until its model is built; its targets with the model off first.
local function entScene(class, pos)
    local sv, world = F.server()
    local cl = F.client(world)
    local E = cl.env
    local ent = cl:clientEntity(class)
    ent:SetPos(pos)
    cl.localPlayer = sv:player("Looker")
    enableMeshes(cl)
    local cv = E.GetConVar("bmx_bike_model")
    return { sv = sv, cl = cl, E = E, ent = ent, cv = cv }
end

local function drawUntilBuilt(s)
    for _ = 1, 8000 do
        reset(s.cl)
        s.ent:Draw()
        if #s.cl.groups > 0 then return true end
    end
end

local function primitiveTargets(s)
    s.cv:SetInt(0)
    reset(s.cl)
    s.ent:Draw()
    reset(s.cl)
    s.ent:Draw()
    local ik = {}
    for k, v in pairs(s.ent.ikTargets) do ik[k] = v end
    local drew = #s.cl.beams + #s.cl.drawnCS
    s.cv:SetInt(1)
    return ik, drew
end

T.test("skateboard drawing: the primitive board stands in, then the model: deck, two trucks, two hangers, four wheels; the rider's targets unchanged", function()
    local s = entScene("bmx_skateboard", nil)
    s.ent:SetPos(s.E.Vector(0, 0, 1.3))
    local ik0, drew0 = primitiveTargets(s)
    T.ok(drew0 > 8, "bmx_bike_model 0: the primitive board")
    reset(s.cl)
    s.ent:Draw()
    T.eq(#s.cl.groups, 0, "first frame: still building")
    T.ok(#s.cl.beams + #s.cl.drawnCS > 8, "...and the primitive board meanwhile")
    T.ok(drawUntilBuilt(s), "the model finishes building")
    T.eq(s.cl.ccw or 0, 0, "every triangle wound the way Source draws front faces")
    local c = counts(s.cl)
    T.eq(c.deck, 1, "the deck once")
    T.eq(c.truck, 2, "two trucks")
    T.eq(c.hanger, 2, "two hangers")
    T.eq(c.wheel, 4, "four wheels")
    T.eq(#s.cl.beams + #s.cl.drawnCS, 0, "no primitives with the model")
    T.eq(s.cl.suppressed, false, "engine lighting restored")
    rigid(s.cl, "board")
    sameTargets(ik0, s.ent.ikTargets, "board")
    -- the wheels stand on the ground (the board's origin is 1.3 over it)
    local L = s.E.BMX.BikeMesh.Get(16 / 39, 2.2, "skateboard", { wheelbase = 16, restLength = 4, extra = { track = 4.6 } }).layout
    for _, m in ipairs(named(s.cl, "wheel")) do
        T.near(m:GetTranslation().z - L.wheelR, 0, 0.06, "a wheel on the ground")
        T.near(math.abs(m:GetTranslation().x), 8, 0.05, "on an axle")
    end
    -- the hangers stay level while the deck leans over them, and turn as the board carves
    s.ent:SetBoardLean(math.rad(20))
    s.ent.GetSpeedUPS = function() return 60 end
    reset(s.cl)
    s.ent:Draw()
    local deckUp = named(s.cl, "deck")[1]:Col(3)
    T.ok(deckUp.z < 0.97, "the deck leans: " .. deckUp.z)
    local h = named(s.cl, "hanger")
    for _, m in ipairs(h) do T.near(m:Col(3).z, 1, 1e-6, "a hanger stays level") end
    local yawF = math.atan2(h[1]:Col(1).y, h[1]:Col(1).x)
    local yawR = math.atan2(-h[2]:Col(1).y, -h[2]:Col(1).x)
    T.ok(yawF < -0.05, "the front truck turns into the lean (right): " .. yawF)
    T.ok(yawR > 0.05, "and the rear against it: " .. yawR)
    local ikL = s.ent.ikTargets
    s.cv:SetInt(0)
    reset(s.cl)
    s.ent:Draw()
    sameTargets(s.ent.ikTargets, ikL, "board, leaning")
    s.cv:SetInt(1)
    -- a kickflip turns the deck, the trucks and the wheels together; the feet stay
    s.ent:SetBoardLean(0)
    s.ent.drawFlip = { roll = math.pi * 0.5, yaw = 0, pitch = 0 }
    s.ent:SetBoardBits(s.E.BMX.Board.PackBits and s.E.BMX.Board.PackBits(math.pi * 0.5, 0, 0) or 0)
    reset(s.cl)
    s.ent:Draw()
    T.ok(math.abs(named(s.cl, "hanger")[1]:Col(3).z) < 0.2, "mid-flip the hangers are on their side with the deck")
    rigid(s.cl, "board mid-flip")
end)

T.test("scooter drawing: the model's deck, fork, bars, bell lever and two wheels; whips, barspins and steer move the right parts; the targets unchanged", function()
    local s = entScene("bmx_scooter")
    s.ent:SetPos(s.E.Vector(0, 0, 3))
    local ik0, drew0 = primitiveTargets(s)
    T.ok(drew0 > 12, "bmx_bike_model 0: the primitive scooter")
    T.ok(drawUntilBuilt(s), "the model finishes building")
    T.eq(s.cl.ccw or 0, 0, "wound for Source")
    local c = counts(s.cl)
    for _, g in ipairs({ "deck", "fork", "bars", "bellLever" }) do T.eq(c[g], 1, g .. " once") end
    T.eq(c.wheel, 2, "two wheels")
    T.eq(#s.cl.beams + #s.cl.drawnCS, 0, "no primitives with the model")
    rigid(s.cl, "scooter")
    sameTargets(ik0, s.ent.ikTargets, "scooter")
    -- the hands are on the model's grips
    local bars = named(s.cl, "bars")[1]
    local T0 = s.E.BMX.Scooter.Tune
    local half = 14
    local F0 = s.E.BMX.Scooter.Frame(half)
    for _, side in ipairs({ 1, -1 }) do
        local grip = bars:Apply(s.E.Vector(F0.bars.x, -side * (T0.barWidth * 0.5 - 1.8), F0.bars.z))
        local hand = side > 0 and s.ent.ikTargets.rHand or s.ent.ikTargets.lHand
        T.ok((grip - hand):Length() < 0.5, "a hand on its grip: " .. (grip - hand):Length())
    end
    -- the wheels: on their axles, standing on the ground (the scooter's origin is 3 over
    -- it, its axles the static sag over that)
    local ws = named(s.cl, "wheel")
    T.near(ws[1]:GetTranslation().x, -14, 0.05, "the rear wheel on the rear axle")
    T.near(ws[2]:GetTranslation().x, 14, 0.05, "the front wheel on the front axle")
    for _, m in ipairs(ws) do T.near(m:GetTranslation().z, 5, 0.15, "a wheel one radius over the ground") end
    -- a whip turns the deck and leaves the bars; a barspin the other way round
    local d0, b0 = named(s.cl, "deck")[1]:Col(1), bars:Col(1)
    s.ent.drawWhip = math.pi
    s.ent:SetTrickBits(128)
    reset(s.cl)
    s.ent:Draw()
    T.ok((named(s.cl, "deck")[1]:Col(1) + d0):Length() < 0.6, "the deck half way round")
    T.near((named(s.cl, "bars")[1]:Col(1) - b0):Length(), 0, 1e-6, "the bars stayed")
    -- mid-whip the hands stay on the bars and the feet have jumped straight up off the
    -- deck to let it pass under them (SC.RiderTargets)
    for k, v in pairs(ik0) do
        local d = s.ent.ikTargets[k] - v
        if k:find("Foot") then
            T.near(d.x, 0, 1e-6, "scooter mid-whip: " .. k .. " stays over its place on the deck")
            T.near(d.y, 0, 1e-6, "scooter mid-whip: " .. k .. " not sideways")
            T.ok(d.z > 3, "scooter mid-whip: " .. k .. " jumped off the deck: " .. d.z)
        else
            T.near(d:Length(), 0, 1e-9, "scooter mid-whip: " .. k .. " where the primitive drawing put it")
        end
    end
    s.ent.drawWhip, s.ent.drawBar = 0, math.pi
    s.ent:SetTrickBits(128 * 256)
    reset(s.cl)
    s.ent:Draw()
    T.ok((named(s.cl, "bars")[1]:Col(1) + b0):Length() < 0.6, "the bars half way round")
    T.near((named(s.cl, "deck")[1]:Col(1) - d0):Length(), 0, 1e-6, "the deck stayed")
    s.ent.drawBar = 0
    s.ent:SetTrickBits(0)
    -- the steer turns the front about the head tube
    s.ent:SetSteer(math.rad(20))
    reset(s.cl)
    s.ent:Draw()
    local b1 = named(s.cl, "bars")[1]:Col(1)
    T.ok(math.atan2(b1.y, b1.x) < -0.1, "steered right: " .. math.atan2(b1.y, b1.x))
    T.near((named(s.cl, "deck")[1]:Col(1) - d0):Length(), 0, 1e-6, "the deck did not")
    -- ...and the hands went round with the grips
    local bs = named(s.cl, "bars")[1]
    for _, side in ipairs({ 1, -1 }) do
        local grip = bs:Apply(s.E.Vector(F0.bars.x, -side * (T0.barWidth * 0.5 - 1.8), F0.bars.z))
        local hand = side > 0 and s.ent.ikTargets.rHand or s.ent.ikTargets.lHand
        T.ok((grip - hand):Length() < 0.5, "steered, a hand still on its grip: " .. (grip - hand):Length())
    end
    rigid(s.cl, "scooter steered")
    -- the bell's lever flicks when it rings
    s.ent:SetSteer(0)
    reset(s.cl)
    s.ent:Draw()
    local lv0 = named(s.cl, "bellLever")[1]:Col(1)
    s.ent.bellRungAt = s.E.CurTime() - 0.05
    reset(s.cl)
    s.ent:Draw()
    T.ok((named(s.cl, "bellLever")[1]:Col(1) - lv0):Length() > 0.1, "the lever flicked")
end)

T.test("skates drawing: both boots from the model on the feet, wheels on BootFrame's ground; DrawBoots is what the icon studio calls", function()
    local sv, world = F.server()
    local cl = F.client(world)
    local E = cl.env
    local me = cl:player("Looker")
    cl.localPlayer = me
    enableMeshes(cl)
    local S = E.BMX.Skates
    me:SetNWString("BMXWorn", "skates")
    -- the primitive boots first (bmx_bike_model 0)
    E.GetConVar("bmx_bike_model"):SetInt(0)
    reset(cl)
    E.hook.Run("PostPlayerDraw", me)
    T.ok(cl.lines >= 8, "the primitive skates' hubs: " .. cl.lines)
    E.GetConVar("bmx_bike_model"):SetInt(1)
    local ok = false
    for _ = 1, 8000 do
        reset(cl)
        E.hook.Run("PostPlayerDraw", me)
        if #cl.groups > 0 then ok = true break end
    end
    T.ok(ok, "the model finishes building")
    T.eq(cl.ccw or 0, 0, "wound for Source")
    local c = counts(cl)
    T.eq(c.skate, 2, "two boots")
    T.eq(c.skateOutL, 1, "a left boot's levers")
    T.eq(c.skateOutR, 1, "a right boot's levers")
    T.eq(c.wheel, 4, "two wheels a boot")
    T.eq(c.wheelAR, 4, "two anti-rockers a boot")
    T.eq(cl.lines, 0, "no primitive hubs with the model")
    rigid(cl, "skates")
    -- each boot at its foot's sole, its wheels on the ground BootFrame stands them on
    local M = S.Model()
    local radius = E.BMX.ConfigFor(E.BMX.Vehicles.skates).Wheel.radius
    local boots = named(cl, "skate")
    local soles = {}
    for _, name in ipairs({ "ValveBiped.Bip01_L_Foot", "ValveBiped.Bip01_R_Foot" }) do
        local p = me:GetBonePosition(me:LookupBone(name))
        soles[#soles + 1] = E.Vector(p.x, p.y, p.z - 2.6)
    end
    T.near((boots[1]:GetTranslation() - soles[1]):Length(), 0, 1e-6, "the left boot on the left foot")
    T.near((boots[2]:GetTranslation() - soles[2]):Length(), 0, 1e-6, "the right on the right")
    local fr = S.BootFrame(soles[1], me:GetRenderAngles().y, radius)
    local ground = fr.wheels[1].z - radius
    for i, m in ipairs(named(cl, "wheel")) do
        if i <= 2 then T.near(m:GetTranslation().z - M.layout.wheelR, ground, 1e-6, "a wheel on BootFrame's ground") end
    end
    -- the studio's call: a pair drawn with no player
    reset(cl)
    T.eq(S.DrawBoots(nil, { { sole = E.Vector(0, 0, 2.8), side = 1 }, { sole = E.Vector(0, 8, 2.8), side = -1 } }, 0, radius, 0, false),
        true, "DrawBoots draws the model")
    T.eq(counts(cl).skate, 2, "both boots")
    me:SetNWString("BMXWorn", "")
end)
