--[[--------------------------------------------------------------------------
    The models of the unicycle, the penny-farthing and the tandem
    (lua/bmx/cl_geo_odd.lua), and their drawing: the unicycle's and the penny's own
    drawers (cl_oddbikes.lua) and the tandem through DrawDetailed (cl_init.lua).

    The geometry half runs the real builders in a bare Lua at the registry's sizes
    and holds them to docs/MODELS.md: whole, sound triangles, in budget, the saddles
    where the riders sit, the pedals and grips where their feet and hands go. The
    drawing half gives the client a fake Mesh (as tests/test_bikemodel.lua does) and
    checks each vehicle draws its model once it is built, and still records the
    riders' IK targets where the simple drawing had them.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local here = (arg and arg[0] or "tests/run.lua"):match("^(.*)/[^/]*$") or "tests"
local ROOT = here .. "/.."

-- The builders in a bare environment: they must not need the game.
local function geo()
    local env = setmetatable({ BMX = {} }, { __index = _G })
    for _, f in ipairs({ "/lua/bmx/cl_bikegeo.lua", "/lua/bmx/cl_geo_odd.lua" }) do
        local chunk = assert(loadfile(ROOT .. f))
        setfenv(chunk, env)
        chunk()
    end
    return env.BMX.BikeGeo
end

local G = geo()
local SIZES = dofile(ROOT .. "/tools/bike/sizes.lua")
local KINDS = { "unicycle", "penny", "tandem" }

local built, times = {}, {}
local function model(kind)
    if not built[kind] then
        local S = SIZES[kind]
        local t0 = os.clock()
        built[kind] = G.Build({ kind = kind, wheelbase = S.wheelbase, radius = S.radius, rearRadius = S.rearRadius,
            seat = S.seat, k = math.max(S.wheelbase, 1) / 39, extra = S.extra })
        times[kind] = os.clock() - t0
    end
    return built[kind]
end

local function each(M, group, fn)
    for _, b in ipairs(M.groups[group] or {}) do
        for _, v in ipairs(b.v) do fn(v, b) end
    end
end

local function dist(a, b) return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2) end

local GROUPS = {
    unicycle = { "frame", "wheel", "cranks", "pedal" },
    penny = { "frame", "fork", "wheelF", "wheelR", "cranks", "pedal" },
    tandem = { "frame", "fork", "bars", "wheelF", "wheelR", "cranks", "pedal", "bellLever" },
}

T.test("odd models: each kind is registered and builds at its registry size, in budget, with sound triangles", function()
    for _, kind in ipairs(KINDS) do
        T.ok(G.Kinds[kind], kind .. " is a registered kind")
        local M = model(kind)
        local st = G.Stats(M)
        for _, g in ipairs(GROUPS[kind]) do
            T.ok((st[g] or 0) > 100, kind .. "/" .. g .. " has real geometry: " .. tostring(st[g]))
        end
        T.between(st.total, 15000, 90000, kind .. " triangles in all")
        T.ok(times[kind] < 6.0, kind .. " builds in under a few seconds (loose: a loaded CI box): " .. string.format("%.2f", times[kind]))
        local bad, n, agree, total = 0, 0, 0, 0
        for _, g in ipairs(M.order) do
            for _, b in ipairs(M.groups[g]) do
                T.ok(#b.v > 0 and #b.v % 3 == 0, kind .. "/" .. g .. "/" .. b.mat .. " is whole triangles")
                T.ok(b.mat ~= "tyretext" and b.mat ~= "decal", kind .. ": no BMX lettering or decal")
                for i = 1, #b.v, 3 do
                    local a, c, d = b.v[i], b.v[i + 1], b.v[i + 2]
                    for _, v in ipairs({ a, c, d }) do
                        n = n + 1
                        local p, q = v.p, v.n
                        if not (p[1] == p[1] and p[2] == p[2] and p[3] == p[3]) then bad = bad + 1 end
                        if math.abs(math.sqrt(q[1] ^ 2 + q[2] ^ 2 + q[3] ^ 2) - 1) > 1e-3 then bad = bad + 1 end
                    end
                    local gn = G.vec.cross(G.vec.sub(c.p, a.p), G.vec.sub(d.p, a.p))
                    total = total + 1
                    if G.vec.dot(gn, G.vec.add(G.vec.add(a.n, c.n), d.n)) >= 0 then agree = agree + 1 end
                end
            end
        end
        T.eq(bad, 0, kind .. ": every position finite and every normal unit length, of " .. n)
        T.eq(agree, total, kind .. ": winding agrees with normals")
        local again = G.Stats(G.Build({ kind = kind, wheelbase = SIZES[kind].wheelbase, radius = SIZES[kind].radius,
            rearRadius = SIZES[kind].rearRadius, seat = SIZES[kind].seat, extra = SIZES[kind].extra }))
        T.eq(again.total, st.total, kind .. ": deterministic")
    end
end)

T.test("odd models: the tyres are the simulation's wheels", function()
    local function outer(M, g)
        local r = 0
        each(M, g, function(v) r = math.max(r, math.sqrt(v.p[1] ^ 2 + v.p[3] ^ 2)) end)
        return r
    end
    T.between(outer(model("unicycle"), "wheel"), 10 - 0.05, 10 + 0.45, "the unicycle's 20 inch wheel (knobs stand proud)")
    T.near(outer(model("penny"), "wheelF"), 26, 0.05, "the penny's big wheel")
    T.near(outer(model("penny"), "wheelR"), 6, 0.05, "the penny's little wheel")
    T.between(outer(model("tandem"), "wheelF"), 13 - 0.05, 13 + 0.05, "the tandem's front")
    T.between(outer(model("tandem"), "wheelR"), 13 - 0.05, 13 + 0.05, "the tandem's rear")
    local L = model("penny").layout
    T.near(L.rear[1], -22, 1e-6, "the penny's rear axle at -wheelbase/2")
    T.near(L.rear[3], -20, 1e-6, "and radius - rearRadius below the front's")
end)

T.test("odd models: each saddle's top is where its rider sits: seat + (-0.5, 0, 2)", function()
    for _, kind in ipairs(KINDS) do
        local S = SIZES[kind]
        local seats = { S.seat }
        if S.extra and S.extra.stoker then seats[2] = S.extra.stoker end
        for _, s in ipairs(seats) do
            local top = -1e9
            each(model(kind), "frame", function(v, b)
                if (b.mat == "seat" or b.mat == "leather") and math.abs(v.p[1] - (s[1] - 0.5)) < 0.6 and math.abs(v.p[2]) < 0.6 then
                    top = math.max(top, v.p[3])
                end
            end)
            T.near(top, s[3] + 2, 0.15, kind .. ": the saddle over " .. s[1] .. " tops out at the seat + 2")
        end
    end
end)

T.test("odd models: the feet and hands go where the riders' poses expect them", function()
    -- the unicycle: 5 in cranks on the hub, the pedals about where the simple drawing's were
    local U = model("unicycle").layout
    T.near(U.bb[1], 0, 1e-9, "the unicycle's cranks are on its hub")
    T.near(U.bb[3], 0, 1e-9, "(at the axle)")
    T.between(U.crank, 4.8, 6.6, "a unicycle's crank length")
    T.near(U.pedalY, 5.0, 1.0, "the pedals' centres out where the feet were")
    -- the penny: on the big hub, the hands on the moustache bar's grips
    local P = model("penny").layout
    T.near(dist(P.bb, P.front), 0, 1e-9, "the penny's cranks are on the big wheel's hub")
    local function hold(g)
        local d = G.vec.sub(g.B, g.A)
        local l = G.vec.len(d)
        return G.vec.madd(g.A, d, math.min(1.75, l * 0.5) / l)
    end
    local oldFoot = { 22 + 8, -(4.5 + 1.8), 0 }
    T.ok(dist({ P.bb[1] + P.crank, P.bb[2] - P.pedalY, 0 }, oldFoot) < 2, "the penny's right pedal near the old foot")
    T.ok(dist(hold(P.gripR), { 23, -10.5, 34 }) < 2, "the penny's right hand near the old one")
    T.ok(dist(hold(P.gripL), { 23, 10.5, 34 }) < 2, "and the left")
    T.ok(P.gripR.A[2] < 0 and P.gripL.A[2] > 0, "right is -y")
    -- the tandem: a bike's bottom bracket under each saddle, the captain's hands on
    -- the hoods, the stoker's on the bar behind the captain's saddle
    local L = model("tandem").layout
    local S = SIZES.tandem
    for i, s in ipairs({ S.seat, S.extra.stoker }) do
        local bb = (i == 1) and L.bb or L.bb2
        T.between(bb[1] - s[1], 4, 7, "bottom bracket " .. i .. " ahead of its saddle")
        T.between(s[3] - bb[3], 18, 20.5, "and a leg's length under it")
    end
    T.near(L.crank, 6.8, 1e-9, "172.5 mm cranks")
    T.near(L.pedalY, 5.2, 0.3, "the pedals out where a bike's are")
    T.ok(dist(hold(L.gripR), { 31, -10.5, 24 }) < 3, "the captain's right hand near the old one")
    T.ok(dist(hold(L.gripL), { 31, 10.5, 24 }) < 3, "and the left")
    T.ok(L.gripS.r[1] < S.seat[1] - 2 and L.gripS.r[1] > S.extra.stoker[1] + 15, "the stoker's grips behind the captain's saddle, in reach")
    T.ok(L.gripS.r[3] < S.seat[3] + 2 and L.gripS.r[3] > S.seat[3] - 3, "at about the captain's saddle's height")
    T.ok(L.gripS.r[2] < -5 and L.gripS.l[2] > 5, "either side of the captain")
    T.ok(L.bellPivot and L.bellAxis, "the bell's lever hinge")
end)

T.test("odd models: the tandem's timing chain is on the left, the drive chain on the right", function()
    local L = model("tandem").layout
    local left, right = 0, 0
    each(model("tandem"), "frame", function(v, b)
        if b.mat == "steel" and b.detail and v.p[3] < L.bb[3] + 3.5 and v.p[3] > L.bb[3] - 3.5
           and v.p[1] > L.bb2[1] + 3 and v.p[1] < L.bb[1] - 3 then
            if v.p[2] > 1 then left = left + 1 elseif v.p[2] < -1 then right = right + 1 end
        end
    end)
    T.ok(left > 1000, "a chain of links on the left between the bottom brackets: " .. left)
    local rearRun = 0
    each(model("tandem"), "frame", function(v, b)
        if b.mat == "steel" and b.detail and v.p[1] < L.bb2[1] - 4 and v.p[1] > L.rear[1] + 4 and v.p[2] < -1.4 and v.p[2] > -2.6 then
            rearRun = rearRun + 1
        end
    end)
    T.ok(rearRun > 1000, "and on the right from the stoker's rings back to the cassette: " .. rearRun)
end)

--------------------------------------------------------------------------
-- DRAWING, with a fake mesh API (as tests/test_bikemodel.lua)
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
    R.groups, R.meshVerts, R.tubes = {}, 0, 0
    local orig = E.Matrix
    E.Matrix = function(t) if type(t) == "table" then return fakeMatrix(E, t) end return orig() end
    E.SysTime = os.clock
    E.FrameNumber = function() frame = frame + 1 return frame end
    E.GetRenderTargetEx = function(name) return { name = name } end
    E.CreateMaterial = function(name, shader, kv)
        local m = { name = name, shader = shader, kv = kv }
        function m:SetTexture(k, t) self[k] = t end
        function m:GetTexture(k) return self[k] end
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
        function m:Draw() R.drawn = (R.drawn or 0) + 1 end
        function m:Destroy() self.valid = false end
        function m:IsValid() return self.valid end
        return m
    end
    local r = E.render
    for _, k in ipairs({ "PushRenderTarget", "PopRenderTarget", "Clear", "SetModelLighting", "SetLocalModelLights" }) do
        r[k] = function() end
    end
    r.SuppressEngineLighting = function(b) R.suppressed = b end
    r.OverrideAlphaWriteEnable = function() end
    E.cam.Start2D = function() end
    E.cam.End2D = function() end
    E.surface.DrawPoly = function() end
    E.draw.NoTexture = function() end
    E.draw.SimpleTextOutlined = function() end
    r.ComputeLighting = function(pos, dir) return E.Vector(0.1, 0.1, 0.1) + E.Vector(0.4, 0.4, 0.35) * math.max(dir.z, 0) end
    r.ComputeDynamicLighting = function() return E.Vector(0, 0, 0) end
    r.SetMaterial = function(m) R.material = m end
    E.cam.PushModelMatrix = function() end
    E.cam.PopModelMatrix = function() end
    E.mesh = {}
    for _, k in ipairs({ "Normal", "TangentS", "TangentT", "UserData", "TexCoord", "AdvanceVertex" }) do
        E.mesh[k] = function() end
    end
    E.mesh.Begin = function() R.tubes = R.tubes + 1 end
    E.mesh.Position = function(p) assert(p.x == p.x and p.z == p.z, "a tube vertex is a NaN") end
    E.mesh.End = function() end
    local BM = E.BMX.BikeMesh
    local drawGroup = BM.DrawGroup
    BM.DrawGroup = function(model, name, mtx, paint, lod)
        R.groups[#R.groups + 1] = { name = name, m = mtx, paint = paint, lod = lod }
        return drawGroup(model, name, mtx, paint, lod)
    end
end

local function scene(id)
    local sv, world = F.server()
    local B = sv.env.BMX
    local cfg = B.ConfigFor(B.Bikes[id])
    local bike = F.bike(sv, B.ClassFor(id), sv.env.Vector(0, 0, sv.world.groundZ + B.RestHeight(cfg)))
    local cl = F.client(world)
    local cb = cl:clientEntity(B.ClassFor(id))
    cb:SetPos(bike:GetPos())
    cb:SetAngles(bike:GetAngles())
    for k, v in pairs(bike._nw) do cb._nw[k] = v end
    return { sv = sv, cl = cl, bike = bike, cb = cb }
end

local function draw(s)
    s.cl.lines, s.cl.beams, s.cl.drawnModels, s.cl.boxes3d = 0, {}, 0, 0
    s.cl.drawnCS, s.cl.groups, s.cl.drawn, s.cl.tubes = {}, {}, 0, 0
    s.cb:Draw()
end

local function ready(s)
    for _ = 1, 8000 do
        draw(s)
        if #s.cl.groups > 0 then return true end
    end
end

local function count(s)
    local n = {}
    for _, g in ipairs(s.cl.groups) do n[g.name] = (n[g.name] or 0) + 1 end
    return n
end

local function group(s, name, nth)
    local i = 0
    for _, g in ipairs(s.cl.groups) do
        if g.name == name then
            i = i + 1
            if i == (nth or 1) then return g.m end
        end
    end
end

local function rigid(s)
    for _, g in ipairs(s.cl.groups) do
        local x, y, z = g.m:Col(1), g.m:Col(2), g.m:Col(3)
        if math.abs(x:Length() - 1) > 1e-6 or math.abs(y:Length() - 1) > 1e-6 or math.abs(x:Dot(y)) > 1e-6
           or math.abs(x:Cross(y):Dot(z) - 1) > 1e-6 then
            return false, g.name
        end
    end
    return true
end

-- The simple drawing's targets (bmx_bike_model 0), then the model's.
local function bothTargets(s)
    local cv = s.cl.env.GetConVar("bmx_bike_model")
    cv:SetInt(0)
    draw(s)
    local old = s.cb.ikTargets
    T.ok(#s.cl.groups == 0 and #s.cl.drawnCS > 0, "bmx_bike_model 0: the simple drawing, no model")
    cv:SetInt(1)
    draw(s)
    return old, s.cb.ikTargets
end

T.test("odd models (client): the unicycle draws its model once built, and the rider's feet and hands stay put", function()
    local s = scene("unicycle")
    enableMeshes(s.cl)
    draw(s)
    T.eq(#s.cl.groups, 0, "first frame: still building")
    T.ok(s.cb.ikTargets and s.cb.ikTargets.rFoot, "...and the simple one is drawn, with the targets, meanwhile")
    T.ok(ready(s), "the model finishes building")
    T.eq(s.cl.ccw or 0, 0, "every triangle wound the way Source draws front faces")
    local n = count(s)
    T.eq(n.frame, 1, "the frame") T.eq(n.wheel, 1, "the wheel") T.eq(n.cranks, 1, "the cranks") T.eq(n.pedal, 2, "two pedals")
    T.eq(#s.cl.drawnCS, 0, "no props drawn with the model")
    T.eq(s.cl.suppressed, false, "engine lighting restored")
    local ok, which = rigid(s)
    T.ok(ok, "every group placed by a rigid transform: " .. tostring(which))
    local ik = s.cb.ikTargets
    for _, k in ipairs({ "rFoot", "lFoot", "rHand", "lHand", "rHandA", "rHandB", "lHandA", "lHandB" }) do T.ok(ik[k], k) end
    T.near((ik.rFoot - group(s, "pedal", 1):GetTranslation()):Length(), 0.9, 0.05, "the right foot on its pedal")
    T.near((ik.lFoot - group(s, "pedal", 2):GetTranslation()):Length(), 0.9, 0.05, "the left foot on its pedal")
    T.near((group(s, "wheel"):GetTranslation() - group(s, "frame"):GetTranslation()):Length(), 0, 1e-6, "the wheel on the fork's bearings")
    -- the cranks turn WITH the wheel
    T.near((group(s, "cranks"):Col(1) - group(s, "wheel"):Col(1)):Length(), 0, 1e-6, "cranks and wheel turned together")
    s.cb.oddSpin.wheel.angle = s.cb.oddSpin.wheel.angle + 1
    s.cb.oddSpin.wheel.rate = 0
    local w0 = group(s, "wheel"):Col(1)
    draw(s)
    local w1 = group(s, "wheel"):Col(1)
    T.near(math.acos(math.max(-1, math.min(1, w0:Dot(w1)))), 1, 0.05, "the wheel turned a radian")
    T.near((group(s, "cranks"):Col(1) - w1):Length(), 0, 1e-6, "and the cranks with it")
    local old, new = bothTargets(s)
    T.ok((old.rHand - new.rHand):Length() < 1e-6 and (old.lHand - new.lHand):Length() < 1e-6, "the hands where they were")
    T.ok((old.rFoot - new.rFoot):Length() < 2, "the right foot within 2 of the simple drawing's: " .. (old.rFoot - new.rFoot):Length())
    T.ok((old.lFoot - new.lFoot):Length() < 2, "the left foot too: " .. (old.lFoot - new.lFoot):Length())
    s.cl.env.GetConVar("bmx_debug"):SetInt(1)
    draw(s)
    T.eq(#s.cl.groups, 0, "bmx_debug draws the simple one")
    s.cl.env.GetConVar("bmx_debug"):SetInt(0)
end)

T.test("odd models (client): the penny draws its model, steers its front end, and the rider's feet and hands stay put", function()
    local s = scene("penny")
    enableMeshes(s.cl)
    T.ok(ready(s), "the model finishes building")
    T.eq(s.cl.ccw or 0, 0, "every triangle wound the way Source draws front faces")
    local n = count(s)
    for _, g in ipairs({ "frame", "fork", "wheelF", "wheelR", "cranks" }) do T.eq(n[g], 1, g .. " drawn once") end
    T.eq(n.pedal, 2, "two pedals")
    local ok, which = rigid(s)
    T.ok(ok, "every group placed by a rigid transform: " .. tostring(which))
    local ik = s.cb.ikTargets
    T.near((ik.rFoot - group(s, "pedal", 1):GetTranslation()):Length(), 0.9, 0.05, "the right foot on its pedal")
    -- the wheels on the axles the simple drawing has
    s.cl.env.GetConVar("bmx_bike_model"):SetInt(0)
    draw(s)
    local hubs = {}
    for _, b in ipairs(s.cl.beams) do hubs[#hubs + 1] = (b.a + b.b) * 0.5 end
    s.cl.env.GetConVar("bmx_bike_model"):SetInt(1)
    draw(s)
    local function nearestHub(p)
        local best = math.huge
        for _, h in ipairs(hubs) do best = math.min(best, (h - p):Length()) end
        return best
    end
    T.ok(nearestHub(group(s, "wheelF"):GetTranslation()) < 0.5, "the big wheel on its axle")
    T.ok(nearestHub(group(s, "wheelR"):GetTranslation()) < 0.5, "the little wheel on its axle")
    -- the steer turns the fork, the bars and the big wheel, not the frame
    local f0, b0, fr0 = group(s, "fork"):Col(1), group(s, "wheelF"):Col(2), group(s, "frame"):Col(1)
    s.cb:SetSteer(math.rad(20))
    draw(s)
    local f1 = group(s, "fork"):Col(1)
    local a = math.deg(math.atan2(f1.y, f1.x) - math.atan2(f0.y, f0.x))
    T.between(math.abs(a), 12, 25, "the fork yawed by the steer: " .. a)
    T.ok((group(s, "wheelF"):Col(2) - b0):Length() > 0.1, "the big wheel's axle turned with it")
    T.near((group(s, "frame"):Col(1) - fr0):Length(), 0, 1e-6, "the frame did not")
    T.ok((s.cb.ikTargets.rHand - ik.rHand):Length() > 0.5, "the hands go with the bars")
    s.cb:SetSteer(0)
    draw(s)
    local old, new = bothTargets(s)
    for _, k in ipairs({ "rFoot", "lFoot", "rHand", "lHand" }) do
        T.ok((old[k] - new[k]):Length() < 2.5, k .. " within reach of the simple drawing's: " .. (old[k] - new[k]):Length())
    end
    T.ok(new.rHandA and new.rHandB and new.lHandA and new.lHandB, "the grips' ends, for the IK to slide along")
end)

T.test("odd models (client): the tandem draws as a bike, both cranksets, and the stoker has hands and feet of their own", function()
    local s = scene("tandem")
    enableMeshes(s.cl)
    T.ok(ready(s), "the model finishes building")
    T.eq(s.cl.ccw or 0, 0, "every triangle wound the way Source draws front faces")
    local n = count(s)
    for _, g in ipairs({ "frame", "fork", "bars", "wheelF", "wheelR", "bellLever" }) do T.eq(n[g], 1, g .. " drawn once") end
    T.eq(n.cranks, 2, "two crank sets")
    T.eq(n.pedal, 4, "four pedals")
    local ok, which = rigid(s)
    T.ok(ok, "every group placed by a rigid transform: " .. tostring(which))
    local cb = s.cb
    local ik, stk = cb.ikTargets, cb.ikTargetsStoker
    T.ok(ik and ik.rFoot and ik.rHand, "the captain's targets")
    T.ok(stk and stk.rFoot and stk.lFoot and stk.rHand and stk.lHand, "the stoker's targets")
    T.ok(cb:WorldToLocal(stk.rFoot).x < cb:WorldToLocal(ik.rFoot).x - 20, "the stoker's feet behind the captain's")
    T.ok(cb:WorldToLocal(stk.rHand).x < cb:WorldToLocal(ik.rFoot).x, "and their hands on the bar behind the captain")
    T.near((stk.rFoot - group(s, "pedal", 3):GetTranslation()):Length(), (ik.rFoot - group(s, "pedal", 1):GetTranslation()):Length(), 1e-6,
        "the stoker's foot on their pedal as the captain's on theirs")
    -- the captain's hands within a short reach of where the old drawing had them
    local C = cb:Cfg()
    local sag = C.Chassis.mass * 600 * 0.5 / C.Wheel.spring
    for _, side in ipairs({ { "rHand", -10.5 }, { "lHand", 10.5 } }) do
        local h = cb:WorldToLocal(ik[side[1]])
        T.ok((h - s.cl.env.Vector(31, side[2], 24 + sag)):Length() < 3.5, side[1] .. " on the hoods: " .. tostring(h))
    end
    -- and the passenger code hands the stoker those targets, not the pegs'
    T.ok(s.cl.env.BMX.PassengerTargets(nil, cb, "pegs", nil) == stk, "the passenger pose takes them")
    T.ok(s.cl.env.BMX.PassengerTargets(nil, cb, "child", nil) ~= stk, "(a child seat does not)")
end)
