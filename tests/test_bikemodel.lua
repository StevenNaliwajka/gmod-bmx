--[[--------------------------------------------------------------------------
    The detailed bike model: lua/bmx/cl_bikegeo.lua (the triangles) and
    cl_bikemesh.lua + entities/bmx_base/cl_init.lua's DrawDetailed (placing
    them).

    The geometry half runs the real builder and checks the model is sound and
    built to the addon's contract: wheels the simulation's size, grips where
    the rider's hands go. The drawing half gives the client a fake Mesh /
    CreateMaterial / render-target API -- recorded, not rendered -- and checks
    every part lands where the simulation and the rider expect it, through
    steering, whips, barspins and the drivetrain.

    The shim has no Mesh, so every other client test still draws the simple
    bike; this file switches the detailed one on for itself.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local here = (arg and arg[0] or "tests/run.lua"):match("^(.*)/[^/]*$") or "tests"
local GEO = here .. "/../lua/bmx/cl_bikegeo.lua"

-- The builder in a bare environment: it must not need the game.
local function geo()
    local env = setmetatable({ BMX = {} }, { __index = _G })
    local chunk = assert(loadfile(GEO))
    setfenv(chunk, env)
    chunk()
    return env.BMX.BikeGeo
end

local G = geo()
local stock = G.Build({ k = 1, radius = 10 })

local function each(M, group, fn)
    for _, b in ipairs(M.groups[group]) do
        for _, v in ipairs(b.v) do fn(v, b) end
    end
end

T.test("bike model: builds every part, in budget, with no broken vertices", function()
    local st = G.Stats(stock)
    for _, g in ipairs({ "frame", "fork", "bars", "wheelF", "wheelR", "cranks", "pedal" }) do
        T.ok((st[g] or 0) > 300, g .. " has real geometry: " .. tostring(st[g]))
    end
    T.between(st.total, 40000, 95000, "triangles in all")
    local bad, n = 0, 0
    for _, g in ipairs(stock.order) do
        each(stock, g, function(v)
            n = n + 1
            local p, q = v.p, v.n
            if not (p[1] == p[1] and p[2] == p[2] and p[3] == p[3]) then bad = bad + 1 end
            local l = math.sqrt(q[1] * q[1] + q[2] * q[2] + q[3] * q[3])
            if math.abs(l - 1) > 1e-3 then bad = bad + 1 end
        end)
    end
    T.eq(bad, 0, "every position finite and every normal unit length, of " .. n)
    for _, g in ipairs(stock.order) do
        for _, b in ipairs(stock.groups[g]) do
            T.eq(#b.v % 3, 0, g .. "/" .. b.mat .. " is whole triangles")
            T.ok(#b.v / 3 <= 21000 * 4, "a bucket splits into few meshes")
        end
    end
end)

T.test("bike model: triangles face the way their normals do", function()
    -- tri() winds each triangle to agree with its normals; a builder that
    -- handed it inside-out normals would show as a lit back face.
    local V = G.vec
    local agree, total = 0, 0
    for _, g in ipairs(stock.order) do
        for _, b in ipairs(stock.groups[g]) do
            for i = 1, #b.v, 3 do
                local a, c, d = b.v[i], b.v[i + 1], b.v[i + 2]
                local gn = V.cross(V.sub(c.p, a.p), V.sub(d.p, a.p))
                local s = V.add(V.add(a.n, c.n), d.n)
                total = total + 1
                if V.dot(gn, s) >= 0 then agree = agree + 1 end
            end
        end
    end
    T.eq(agree, total, "winding agrees with normals")
end)

T.test("bike model: the tyres are the simulation's wheels, and on their axles", function()
    for _, case in ipairs({ { 1, 10 }, { 43 / 39, 12 }, { 34 / 39, 8 } }) do
        local k, R = case[1], case[2]
        local M = (k == 1) and stock or G.Build({ k = k, radius = R })
        for _, g in ipairs({ "wheelF", "wheelR" }) do
            local rmax, ymax = 0, 0
            each(M, g, function(v)
                local r = math.sqrt(v.p[1] ^ 2 + v.p[3] ^ 2)
                if r > rmax then rmax = r end
            end)
            for _, b in ipairs(M.groups[g]) do
                if (b.mat == "rubber" or b.mat == "gum") and not b.detail then
                    for _, v in ipairs(b.v) do ymax = math.max(ymax, math.abs(v.p[2])) end
                end
            end
            -- the casing is the radius; the tread blocks stand a little proud
            T.between(rmax, R - 0.05, R + 0.2 * k, g .. " outer radius at k=" .. k)
            T.between(ymax, 0.9 * k, 1.6 * k, g .. " is a BMX tyre's width")
        end
    end
end)

T.test("bike model: the grips are where the rider's hands go", function()
    -- cl_init.lua puts the hands on the bar from 11 to 14.5 out, at FRAME.bars.
    for _, s in ipairs({ 1, -1 }) do
        local n, cy, cz, cx = 0, 0, 0, 0
        for _, b in ipairs(stock.groups.bars) do
            if b.mat == "rubber" then
                for _, v in ipairs(b.v) do
                    if v.p[2] * s > 0 then
                        n = n + 1
                        cx, cy, cz = cx + v.p[1], cy + v.p[2], cz + v.p[3]
                    end
                end
            end
        end
        T.ok(n > 100, "a grip on each side")
        T.near(cx / n, 10.5, 0.2, "grip centred on the bar line (x)")
        T.near(cz / n, 26, 0.2, "grip at bar height")
        T.between(math.abs(cy / n), 11, 14.5, "grip between 11 and 14.5 out")
    end
end)

T.test("bike model: a 25/9 drivetrain whose chain closes round both sprockets", function()
    T.near(G.RING_T / G.COG_T, 25 / 9, 1e-9, "the stock gearing")
    -- chain plates: steel, detail, in the frame group at the chainline
    local ys = {}
    for _, b in ipairs(stock.groups.frame) do
        if b.mat == "steel" and b.detail then
            -- below 6: the chain loop, not the brake's straddle wire above the tyre
            for _, v in ipairs(b.v) do if v.p[3] < 6 then ys[#ys + 1] = v.p[2] end end
        end
    end
    T.ok(#ys > 3000, "a chain of links: " .. #ys .. " vertices")
    local lo, hi = math.huge, -math.huge
    for _, y in ipairs(ys) do lo, hi = math.min(lo, y), math.max(hi, y) end
    T.ok(hi < -1.3 and lo > -2.6, "on the drive side, inside the dropouts: " .. lo .. ".." .. hi)
end)

T.test("bike model: the builder needs nothing from the game", function()
    -- it ran above with only BMX in its environment; and a second build
    -- gives the same model (no hidden state)
    local a, b = G.Stats(G.Build({ k = 1, radius = 10 })), G.Stats(stock)
    T.eq(a.total, b.total, "deterministic")
end)

--------------------------------------------------------------------------
-- DRAWING, with a fake mesh API
--------------------------------------------------------------------------
local function scene()
    local sv, world = F.server()
    local bike = F.bike(sv)
    local ply = F.rider(sv, bike, { name = "Human" })
    local cl = F.client(world)
    local cb = cl:clientEntity("bmx_base")
    cb:SetPos(bike:GetPos())
    cb:SetAngles(bike:GetAngles())
    local pod = cl.makeEntity("prop_vehicle_prisoner_pod")
    pod:SetParent(cb)
    cb:SetPod(pod)
    local me = cl:player("Human")
    me._vehicle = pod
    cl.localPlayer = me
    cb:SetDriver(me)
    return { sv = sv, cl = cl, world = world, bike = bike, cb = cb, me = me }
end

-- A row-major 4x4 from Matrix({rows}), with what the tests read off it.
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

local function enableMeshes(s)
    local E, R = s.cl.env, s.cl
    local frame = 0
    R.groups, R.meshVerts, R.tubes, R.mats = {}, 0, 0, {}
    local orig = E.Matrix
    E.Matrix = function(t) if type(t) == "table" then return fakeMatrix(E, t) end return orig() end
    E.SysTime = os.clock
    E.FrameNumber = function() frame = frame + 1 return frame end
    E.GetRenderTargetEx = function(name) return { name = name } end
    E.CreateMaterial = function(name, shader, kv)
        local m = { name = name, shader = shader, kv = kv }
        function m:SetTexture(k, t) self[k] = t end
        function m:GetTexture(k) return self[k] end
        R.mats[name] = m
        return m
    end
    E.Mesh = function()
        local m = { valid = true }
        function m:BuildFromTriangles(v)
            assert(#v > 0 and #v % 3 == 0 and #v <= 65535, "a mesh of whole triangles under the limit")
            assert(v[1].pos and v[1].normal and v[1].userdata, "position, normal, tangent")
            R.meshVerts = R.meshVerts + #v
            -- Source culls counter-clockwise faces: every triangle must reach
            -- the engine wound clockwise seen from where its normals point
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
    for _, k in ipairs({ "PushRenderTarget", "PopRenderTarget", "Clear", "SetModelLighting",
            "SetLocalModelLights" }) do r[k] = function() end end
    r.SuppressEngineLighting = function(b) R.suppressed = b end
    r.OverrideAlphaWriteEnable = function() end
    E.cam.Start2D = function() R.decalDrawn = (R.decalDrawn or 0) + 1 end
    E.cam.End2D = function() end
    E.surface.DrawPoly = function(pts) for _, p in ipairs(pts) do assert(p.x and p.y, "a poly point") end end
    E.draw.NoTexture = function() end
    E.draw.SimpleTextOutlined = function() end
    r.ComputeLighting = function(pos, dir) return E.Vector(0.1, 0.1, 0.1) + E.Vector(0.4, 0.4, 0.35) * math.max(dir.z, 0) end
    r.ComputeDynamicLighting = function() return E.Vector(0, 0, 0) end
    r.SetMaterial = function(m) R.material = m end
    local stack = {}
    E.cam.PushModelMatrix = function(m) stack[#stack + 1] = m end
    E.cam.PopModelMatrix = function() stack[#stack] = nil end
    E.mesh = {}
    for _, k in ipairs({ "Normal", "TangentS", "TangentT", "UserData", "TexCoord", "AdvanceVertex" }) do
        E.mesh[k] = function() end
    end
    E.mesh.Begin = function() R.tubes = R.tubes + 1 end
    E.mesh.Position = function(p) assert(p.x == p.x and p.z == p.z, "a tube vertex is a NaN") end
    E.mesh.End = function() end
    -- record what each group was drawn under
    local BM = E.BMX.BikeMesh
    local drawGroup = BM.DrawGroup
    BM.DrawGroup = function(model, name, mtx, paint, lod)
        R.groups[#R.groups + 1] = { name = name, m = mtx, paint = paint, lod = lod }
        return drawGroup(model, name, mtx, paint, lod)
    end
end

local function draw(s)
    s.cl.lines, s.cl.beams, s.cl.drawnModels, s.cl.boxes3d = 0, {}, 0, 0
    s.cl.drawnCS, s.cl.groups, s.cl.drawn, s.cl.tubes = {}, {}, 0, 0
    s.cb:Draw()
end

-- Draw until the model has been built (it is built a slice a frame).
local function ready(s)
    for _ = 1, 5000 do
        draw(s)
        if #s.cl.groups > 0 then return true end
    end
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

-- Old-path axle positions: the hub beams of the simple bike.
local function oldHubs(s)
    local f, r
    for _, b in ipairs(s.cl.beams) do
        if math.abs((b.a - b.b):Length() - 4.4) < 1e-6 then
            local mid = (b.a + b.b) * 0.5
            if s.cb:WorldToLocal(mid).x > 0 then f = mid else r = mid end
        end
    end
    return f, r
end

local S                    -- one built scene, shared: building costs seconds

T.test("bike model (client): the simple bike stands in while the model builds, then the model draws", function()
    S = scene()
    enableMeshes(S)
    draw(S)
    T.eq(#S.cl.groups, 0, "first frame: still building")
    T.ok(#S.cl.drawnCS > 10, "...and the simple bike is drawn meanwhile")
    T.ok(ready(S), "the model finishes building")
    T.ok(S.cl.meshVerts > 100000, "meshes made: " .. S.cl.meshVerts .. " vertices")
    T.eq(S.cl.ccw or 0, 0, "every triangle wound the way Source draws front faces")
    local names = {}
    for _, g in ipairs(S.cl.groups) do names[g.name] = (names[g.name] or 0) + 1 end
    for _, n in ipairs({ "frame", "fork", "bars", "wheelF", "wheelR", "cranks" }) do
        T.eq(names[n], 1, n .. " drawn once")
    end
    T.eq(names.pedal, 2, "two pedals")
    T.eq(#S.cl.drawnCS, 0, "no props drawn for the detailed bike")
    T.ok(S.cl.drawn > 30, "mesh draws: " .. S.cl.drawn)
    T.eq(S.cl.suppressed, false, "engine lighting restored after drawing")
    T.ok(S.cl.tubes >= 1, "the brake cable's loop is drawn")
    T.ok((S.cl.decalDrawn or 0) >= 1, "the decal texture was drawn")
    local paint = S.cl.groups[1].paint
    T.ok(paint and paint.r == 205 and paint.g == 35, "frame drawn in the bike's palette colour")
end)

T.test("bike model (client): while a new size's model builds, the bike keeps its last model, not the old simple look", function()
    local E = S.cl.env
    local BM = E.BMX.BikeMesh
    local get = BM.Get
    BM.Get = function() return nil end           -- its new model: still building
    draw(S)
    BM.Get = get
    T.ok(#S.cl.groups > 0, "the last model is drawn while the new one builds")
    T.eq(#S.cl.drawnCS, 0, "no flash of the simple bike")
    -- After a rebuild the old meshes are gone: then, and only then, the simple bike.
    local held = S.cb.bmxDrawnModel
    BM.Clear()
    T.ok(held.cleared, "a rebuild marks the models it destroyed")
    BM.Get = function() return nil end
    draw(S)
    BM.Get = get
    T.eq(#S.cl.groups, 0, "a destroyed model is never drawn")
    T.ok(#S.cl.drawnCS > 10, "the simple bike stands in")
    T.ok(ready(S), "and the model is built again")
end)

T.test("bike model (client): a bike's model is built before it is ever drawn", function()
    local s = scene()
    enableMeshes(s)
    local E = s.cl.env
    E.BMX.BikeMesh.Clear()
    local think = s.cl.hooks and s.cl.hooks.Think and s.cl.hooks.Think["BMX.BikeModelPrebuild"]
        or (E.hook.GetTable and E.hook.GetTable().Think and E.hook.GetTable().Think["BMX.BikeModelPrebuild"])
    T.ok(think, "a Think hook builds models")
    local t = 0
    E.RealTime = function() return t end
    local built = false
    for i = 1, 5000 do
        t = t + 0.02
        think()
        -- Read off the cache, not by asking (asking would build it too).
        for _, st in pairs(E.BMX.BikeMesh.Status()) do if st == "ready" then built = true end end
        if built then break end
    end
    T.ok(built, "built with the bike never drawn")
    draw(s)
    T.ok(#s.cl.groups > 0, "so its first draw is the model")
    T.eq(#s.cl.drawnCS, 0, "never the simple bike")
end)

T.test("bike model (client): every part is placed by a rigid, finite transform", function()
    draw(S)
    for _, g in ipairs(S.cl.groups) do
        local x, y, z = g.m:Col(1), g.m:Col(2), g.m:Col(3)
        T.near(x:Length(), 1, 1e-6, g.name .. " x unit")
        T.near(y:Length(), 1, 1e-6, g.name .. " y unit")
        T.near(z:Length(), 1, 1e-6, g.name .. " z unit")
        T.near(x:Dot(y), 0, 1e-6, g.name .. " x.y")
        T.near(x:Cross(y):Dot(z), 1, 1e-6, g.name .. " right-handed")
        T.finite(g.m:GetTranslation(), g.name .. " placed")
    end
end)

T.test("bike model (client): the wheels sit where the simulation has its axles", function()
    local cv = S.cl.env.GetConVar("bmx_bike_model")
    cv:SetInt(0)
    draw(S)
    local f0, r0 = oldHubs(S)
    cv:SetInt(1)
    draw(S)
    T.ok(f0 and r0, "the simple bike's hubs, for reference")
    T.near((group(S, "wheelR"):GetTranslation() - r0):Length(), 0, 0.05, "rear wheel on the rear axle")
    T.near((group(S, "wheelF"):GetTranslation() - f0):Length(), 0, 0.3, "front wheel on the front axle")
    local R = S.cb:Cfg().Wheel.radius
    T.near(group(S, "wheelR"):GetTranslation().z, R, 0.3, "one radius up: on the ground")
end)

T.test("bike model (client): the bars steer, about the head tube", function()
    draw(S)
    local y0 = group(S, "bars"):Col(1)
    S.cb:SetSteer(math.rad(20))
    draw(S)
    local y1 = group(S, "bars"):Col(1)
    local a = math.deg(math.atan2(y1.y, y1.x) - math.atan2(y0.y, y0.x))
    -- about the raked head tube, so a little less than 20 in plan view
    T.between(math.abs(a), 17, 21, "bars yawed by the steer: " .. a)
    local fr = group(S, "frame"):Col(1)
    T.near((fr - y0):Length(), 0, 1e-6, "the frame did not")
    S.cb:SetSteer(0)
end)

T.test("bike model (client): the hands hold the grips, the feet the pedals", function()
    draw(S)
    local ik = S.cb.ikTargets
    local bars = group(S, "bars")
    local gr = bars:Apply(S.cl.env.Vector(10.5, -12.75, 26))
    T.ok((ik.rHand - gr):Length() < 1.6, "right hand on the right grip: " .. (ik.rHand - gr):Length())
    local gl = bars:Apply(S.cl.env.Vector(10.5, 12.75, 26))
    T.ok((ik.lHand - gl):Length() < 1.6, "left hand on the left grip")
    -- the right pedal's centre, up by the foot offset
    local p1 = group(S, "pedal", 1):GetTranslation()
    T.near((ik.rFoot - p1):Length(), 0.9, 0.05, "right foot on its pedal")
    local p2 = group(S, "pedal", 2):GetTranslation()
    T.near((ik.lFoot - p2):Length(), 0.9, 0.05, "left foot on its pedal")
end)

T.test("bike model (client): a whip turns the frame, a barspin the bars, and the hands let go", function()
    S.cb:SetTrickBits(0)
    S.cb.drawWhip, S.cb.drawBar = 0, 0
    draw(S)
    local fr0, br0, hand0 = group(S, "frame"):Col(1), group(S, "bars"):Col(1), S.cb.ikTargets.rHand
    S.cb.drawWhip = math.pi
    S.cb:SetTrickBits(128)
    draw(S)
    T.ok((group(S, "frame"):Col(1) + fr0):Length() < 0.6, "frame half way round")
    T.near((group(S, "bars"):Col(1) - br0):Length(), 0, 1e-6, "bars stayed")
    T.near((S.cb.ikTargets.rHand - hand0):Length(), 0, 1e-6, "hands stayed")
    S.cb.drawWhip = 0
    S.cb.drawBar = math.pi
    S.cb:SetTrickBits(128 * 256)
    draw(S)
    T.ok((group(S, "bars"):Col(1) + br0):Length() < 0.6, "bars half way round")
    T.near((group(S, "frame"):Col(1) - fr0):Length(), 0, 1e-6, "frame stayed")
    T.near((S.cb.ikTargets.rHand - hand0):Length(), 0, 1e-6, "the hand does not follow a spinning bar")
    S.cb.drawBar = 0
    S.cb:SetTrickBits(0)
end)

T.test("bike model (client): the cranks and wheels turn with the rear wheel", function()
    draw(S)
    local c0, w0 = group(S, "cranks"):Col(1), group(S, "wheelR"):Col(1)
    local C = S.cb:Cfg()
    S.cb.spin.rear.angle = S.cb.spin.rear.angle + 1.0
    S.cb.spin.rear.rate = 0
    draw(S)
    local c1, w1 = group(S, "cranks"):Col(1), group(S, "wheelR"):Col(1)
    local function ang(a, b) return math.acos(math.max(-1, math.min(1, a:Dot(b)))) end
    T.near(ang(w0, w1), 1.0, 0.05, "the wheel turned a radian")
    T.near(ang(c0, c1), 1.0 / C.Drive.gearRatio, 0.02, "the cranks through the gearing")
end)

T.test("bike model (client): far away the fine parts are skipped; bmx_debug draws the simple bike", function()
    draw(S)
    local near = S.cl.drawn
    S.cl.eyePos = S.cb:GetPos() + S.cl.env.Vector(0, -4000, 20)
    draw(S)
    T.ok(S.cl.drawn < near and S.cl.drawn > 10, "far: fewer mesh draws (" .. S.cl.drawn .. " of " .. near .. ")")
    S.cl.eyePos = nil
    S.cl.env.GetConVar("bmx_debug"):SetInt(1)
    draw(S)
    T.eq(#S.cl.groups, 0, "debug: no model")
    T.ok(#S.cl.drawnCS > 10, "debug: the simple bike")
    S.cl.env.GetConVar("bmx_debug"):SetInt(0)
end)

T.test("bike model (client): the kickstand goes down with the stand", function()
    S.cb:SetStandDown(false)
    draw(S)
    local t0 = S.cl.tubes
    S.cb:SetStandDown(true)
    draw(S)
    T.ok(S.cl.tubes >= t0 + 2, "the stand and its foot")
    S.cb:SetStandDown(false)
end)
