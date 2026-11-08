--[[--------------------------------------------------------------------------
    What a CLIENT frame costs, held to a budget.

    test_perf.lua budgets the server's traces; this budgets the client's frame:
    the engine work a rider near the view costs every frame on every player's
    machine, counted, not timed (a count is the same on any box, every run).

    The dearest thing a client does for this addon is have the engine pose a
    rider's whole skeleton (InvalidateBoneCache + SetupBones): the IK reads bones
    after every joint it turns. 1.3.4 posed 58 times a frame for each
    BMX rider in view, 49 for a scooter's, 42 for a board's, about half of them on
    a skeleton nothing had touched (tools/bench/client_frame.lua). The budgets carry
    headroom: they catch a doubling, not noise. tools/bench/client_frame.lua is
    where to look when one fails: it times and counts every hook.

    The first sight of a vehicle kind builds its model, a few ms a frame: the
    longest stretch the build runs without looking at its clock, and the largest
    mesh it hands the engine in one call, are budgeted here too (--build in the
    bench times it).
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local SR = require("lib.skeleton_real")
local VA = require("lib.vecang")
local MF = require("lib.meshfake")

local function seatPod(cl, ent, seat)
    local pod = cl.makeEntity("prop_vehicle_prisoner_pod")
    pod:SetParent(ent)
    pod:SetPos(ent:LocalToWorld(seat.offset))
    pod:SetAngles(ent:LocalToWorldAngles(seat.angles))
    return pod
end

-- Engine calls a client frame makes, counted on the client realm: every explicit
-- SetupBones (the engine posing a skeleton), every bone looked up by name, and
-- every Vector the addon's own Lua makes (constructed, or out of an operator in a
-- file under lua/: the shim's stand-ins for the engine make their own, uncounted).
local function counter(cl)
    local E, P = cl.env, cl.ENGINE.player
    local n = { setup = 0, lookup = 0, vec = 0 }
    local setup, lookup = P.SetupBones, P.LookupBone
    P.SetupBones = function(...) n.setup = n.setup + 1 return setup(...) end
    P.LookupBone = function(...) n.lookup = n.lookup + 1 return lookup(...) end
    local V0 = E.Vector
    E.Vector = function(...) n.vec = n.vec + 1 return V0(...) end
    local getinfo = debug.getinfo
    local VMT, saved = VA.VMT, {}
    for _, k in ipairs({ "__add", "__sub", "__mul", "__div", "__unm", "Cross", "GetNormalized" }) do
        local f = VMT[k]
        saved[k] = f
        VMT[k] = function(...)
            if getinfo(2, "S").source:sub(1, 5) == "@lua/" then n.vec = n.vec + 1 end
            return f(...)
        end
    end
    function n.stop()
        P.SetupBones, P.LookupBone, E.Vector = setup, lookup, V0
        for k, f in pairs(saved) do VMT[k] = f end
    end
    return n
end

-- `id` ridden by kleiner near the view at `speed`, at 60 frames a second: what one
-- frame costs, averaged over `frames` after half a settling second. Worn skates have no
-- entity: the skater is drawn in PrePlayerDraw / PostPlayerDraw.
local function rideCost(id, speed, frames)
    local sv, world = F.server()
    local cl = F.client(world)
    local E, B = cl.env, cl.env.BMX
    world.dt = 1 / 60
    local def = B.Vehicles[id] or B.Bikes[id]
    local standing = def.family == "board" or def.family == "scooter" or def.worn
    local ply = cl:player("Rider")
    ply._skel = SR.load(standing and "kleiner_standing" or "kleiner_seated")
    cl.localPlayer = sv:player("Looker")
    local ent
    if def.worn then
        ply._pos = E.Vector(0, 0, 0)
        ply._vel = E.Vector(speed, 0, 0)
        ply:SetNWString("BMXWorn", id)
        ply:SetNWFloat("BMXSkatePhase", -1)
    else
        ent = cl:clientEntity(B.ClassFor(id))
        local C = ent:Cfg()
        ent:SetPos(E.Vector(0, 0, C.Wheel.radius))
        ent:SetGrounded(true)
        if ent.SetPedalling then ent:SetPedalling(true) end
        if ent.SetPushPhase then ent:SetPushPhase(-1) end
        ent:SetSpeedUPS(speed)
        ent._vel = ent:GetForward() * speed
        local pod = seatPod(cl, ent, B.SeatFor(ent:Bike(), C, "rider"))
        ent:SetPod(pod)
        ent:SetDriver(ply)
        ply._vehicle = pod
    end
    cl.eyePos = ply:GetPos() + E.Vector(-110, 0, 60)
    local function frame()
        world.time = world.time + world.dt
        if ent then ent:Draw() end
        E.hook.Run("PrePlayerDraw", ply)
        E.hook.Run("PostPlayerDraw", ply)
    end
    for _ = 1, 30 do frame() end
    local n = counter(cl)
    for _ = 1, frames do frame() end
    n.stop()
    T.eq(#cl.errors, 0, id .. ": no errors: " .. table.concat(cl.errors, " | "))
    local out = { setup = n.setup / frames, lookup = n.lookup / frames, vec = n.vec / frames }
    if os.getenv("BMX_TRACE") then
        print(string.format("    %s: %.1f SetupBones, %.1f LookupBone, %.0f Vectors a frame",
            id, out.setup, out.lookup, out.vec))
    end
    return out
end

T.test("client perf: a BMX rider near the view poses the skeleton a dozen times a frame, not sixty", function()
    local c = rideCost("stock", 150, 20)
    -- 1.3.4: 58 a frame; now about 11 (the legs follow the cranks: each joint turned is seen)
    T.between(c.setup, 1, 24, "SetupBones a frame, a BMX rider pedalling")
    T.between(c.lookup, 0, 4, "bones looked up by name a frame (1.3.4: 82)")
    -- the IK and the simple bike's drawing together: about 1,100
    T.between(c.vec, 0, 2200, "Vectors made a frame, the rider and the bike drawn")
end)

T.test("client perf: a rider standing still on a scooter or a board is barely posed at all", function()
    -- 1.3.4: 49 (scooter) and 42 (board) a frame for a rider who did not move; now 2
    T.between(rideCost("scooter", 0, 20).setup, 0, 6, "SetupBones a frame, a scooter rider standing")
    T.between(rideCost("skateboard", 0, 20).setup, 0, 6, "SetupBones a frame, a board rider standing")
end)

T.test("client perf: a skater's legs on the ground cost a few poses a frame", function()
    -- 1.3.4: 20 a frame; now 4
    T.between(rideCost("skates", 150, 20).setup, 0, 9, "SetupBones a frame, a skater gliding")
end)

T.test("client perf: a coiled shock spring works out each ring once, not once per corner", function()
    local _, world = F.server()
    local cl = F.client(world)
    MF.enable(cl)
    local E, BM = cl.env, cl.env.BMX.BikeMesh
    local verts = 0
    E.mesh = setmetatable({ AdvanceVertex = function() verts = verts + 1 end },
        { __index = function() return function() end end })
    E.render.SetMaterial = function() end
    -- the dirt bike's spring: 7 turns, 71 rings, 5 sides
    local pts = {}
    for i = 0, 70 do
        local t = i / 70
        local an = t * 7 * math.pi * 2
        pts[#pts + 1] = E.Vector(t * 12, math.cos(an) * 1.4, math.sin(an) * 1.4)
    end
    local n = counter(cl)
    BM.DrawTube(pts, 0.2, "chrome", 5)
    n.stop()
    T.eq(verts, 70 * 5 * 4, "every quad's four corners emitted")
    -- each ring point's direction, tangent frame and position once (1.3.4: 27 a ring point)
    local per = n.vec / (71 * 6)
    if os.getenv("BMX_TRACE") then print(string.format("    spring: %.1f Vectors a ring point", per)) end
    T.between(per, 0, 14, "Vectors made per ring point")
    T.eq(#cl.errors, 0, "no errors")
end)

-- A MODEL BUILD KEEPS TO ITS SLICE. The first time a client sees a vehicle kind it
-- builds its model, a slice a frame (cl_bikemesh.lua): the build looks at the clock
-- every few dozen triangles or vertices and gives the frame back once its
-- bmx_bike_build_ms are spent, so a frame is the budget plus the longest stretch it
-- runs WITHOUT looking. That stretch is counted here, not timed: a clock that moves a
-- second at every look makes the build give the frame back at every look, and a count
-- hook gives each resume's Lua instructions (the same on every machine). 1.3.6 gave
-- way every 128 triangles or 1500 vertices and stepped the collector there: its steps
-- were up to 367,000 instructions (the BMX) and 347,000 (the dirt bike), collector not
-- counted, and its frames 20-90 ms. Now 22,000-55,000 for every kind. And no mesh is
-- handed to the engine in one call over 12,288 vertices (it was up to 58,000).
local MAX_MESH_VERTS = 12288      -- 4096 triangles (cl_bikemesh.lua MAX_TRIS)
-- A MOTORBIKE'S SHOCK IS BUILT ONCE. Its body, shaft and coil were streamed to the engine
-- vertex by vertex every frame (the coil alone 1,400 vertices, ~10,000 engine calls, the
-- dearest thing a motorbike drew: tools/bench --sites, 2026-11-08). Now they are meshes
-- built the first frame and drawn under a matrix from the frame's mount to the swingarm's.
T.test("client perf: a motorbike's shock is built once and drawn under a matrix, its ends on their mounts", function()
    for _, id in ipairs({ "dirtbike", "dh" }) do
        local _, world = F.server()
        local cl = F.client(world)
        MF.enable(cl)
        local E, B = cl.env, cl.env.BMX
        B.BikeMesh.Clear()
        local streamed, built, pushed, drawnUnder = 0, 0, {}, {}
        local into
        E.mesh.Begin = function(a) into = type(a) == "table" end
        E.mesh.AdvanceVertex = function() if not into then streamed = streamed + 1 end end
        local tubes = {}
        local realTube = B.BikeMesh.TubeMesh
        B.BikeMesh.TubeMesh = function(pts, ...)
            built = built + 1
            local m = realTube(pts, ...)
            local mine = { pts = pts }
            function mine:Draw() drawnUnder[#drawnUnder + 1] = { mesh = self, m = pushed[#pushed] } end
            tubes[#tubes + 1] = mine
            return mine
        end
        E.cam.PushModelMatrix = function(m) pushed[#pushed + 1] = m end
        E.cam.PopModelMatrix = function() pushed[#pushed] = nil end
        local ent = cl:clientEntity(B.ClassFor(id))
        ent:SetPos(E.Vector(0, 0, ent:Cfg().Wheel.radius))
        cl.eyePos = E.Vector(-80, 0, 40)
        local shock
        local dd = ent.DrawDetailed
        ent.DrawDetailed = function(self, model, S) shock = model.layout and model.layout.shock return dd(self, model, S) end
        T.ok(MF.ready(cl, ent), id .. ": the model is built")
        local before = built
        for _ = 1, 3 do
            streamed, drawnUnder = 0, {}
            MF.draw(cl, ent)
        end
        T.eq(built, before, id .. ": no shock part is rebuilt after its first frame")
        T.ok(before >= 3, id .. ": the shock's body, shaft and coil are meshes (" .. before .. ")")
        -- What is still streamed is what really bends (a cable, a stand), far less than a coil.
        T.between(streamed, 0, 400, id .. ": vertices streamed a frame")
        -- The shaft (the second tube built) ends on the swingarm's mount, the body starts on the frame's.
        local frameM, swingM = MF.group(cl, "frame"), MF.group(cl, "swingarm")
        local L = nil
        for _, d in ipairs(drawnUnder) do
            if d.mesh == tubes[2] and d.m then
                local shaftEnd = d.mesh.pts[#d.mesh.pts]
                L = { a = d.m:Apply(E.Vector(0, 0, 0)), b = d.m:Apply(shaftEnd) }
            end
        end
        T.ok(L ~= nil, id .. ": the shaft is drawn under a matrix")
        if L and frameM and swingM and shock then
            T.between((L.a - frameM:Apply(shock.frame)):Length(), 0, 0.05, id .. ": the shock's top on the frame's mount")
            T.between((L.b - swingM:Apply(shock.swing)):Length(), 0, 0.05, id .. ": the shaft's end on the swingarm's mount")
        else
            T.ok(shock ~= nil, id .. ": the layout's shock is known to the test")
        end
        T.eq(#cl.errors, 0, id .. ": no errors: " .. table.concat(cl.errors, " | "))
    end
end)

-- A PARKED BMX'S CABLE AND STAND HOLD STILL, so after a frame they are a mesh drawn under the
-- bike's matrix, not ~1,500 engine calls a frame (2026-11-08, the real-client profile);
-- drawn either way, the cable's points are the same places in the world.
T.test("client perf: a parked bike's cable and stand are built once they hold still, in the same place", function()
    local _, world = F.server()
    local cl = F.client(world)
    MF.enable(cl)
    local E, B = cl.env, cl.env.BMX
    B.BikeMesh.Clear()
    local streamed, into = 0, false
    E.mesh.Begin = function(a) into = type(a) == "table" end
    E.mesh.AdvanceVertex = function() if not into then streamed = streamed + 1 end end
    local pushed, cableDraw = {}, nil
    E.cam.PushModelMatrix = function(m) pushed[#pushed + 1] = m end
    E.cam.PopModelMatrix = function() pushed[#pushed] = nil end
    local realTube = B.BikeMesh.TubeMesh
    local streamedPts
    local realDraw = B.BikeMesh.DrawTube
    B.BikeMesh.DrawTube = function(pts, r, role, ...)
        if role == "plastic" then streamedPts = pts end
        return realDraw(pts, r, role, ...)
    end
    B.BikeMesh.TubeMesh = function(pts, r, sides)
        local m = realTube(pts, r, sides)
        local mine = { pts = pts, r = r }
        function mine:Draw() if r < 0.2 then cableDraw = { pts = self.pts, m = pushed[#pushed] } end end
        function mine:Destroy() end
        return mine
    end
    local ent = cl:clientEntity(B.ClassFor("stock"))
    ent:SetPos(E.Vector(10, 20, ent:Cfg().Wheel.radius))
    ent:SetAngles(E.Angle(0, 37, 0))
    if ent.SetStandDown then ent:SetStandDown(true) end
    cl.eyePos = E.Vector(-80, 0, 40)
    T.ok(MF.ready(cl, ent), "the model is built")
    MF.draw(cl, ent)
    local firstPts = streamedPts
    for _ = 1, 3 do streamed = 0 MF.draw(cl, ent) end
    T.eq(streamed, 0, "no vertices streamed a frame once the bike holds still")
    T.ok(cableDraw ~= nil and cableDraw.m ~= nil, "the cable is drawn as a mesh under a matrix")
    if cableDraw and cableDraw.m and firstPts then
        local worst = 0
        for i, p in ipairs(cableDraw.pts) do
            local w = cableDraw.m:GetTranslation() + cableDraw.m:Dir(p)
            worst = math.max(worst, (w - firstPts[i]):Length())
        end
        T.between(worst, 0, 0.06, "the cable's points where the streamed cable had them (u)")
    end
    T.eq(#cl.errors, 0, "no errors: " .. table.concat(cl.errors, " | "))
end)

-- THE ENGINE TAKES A MESH IN ONE CALL, so a mesh is no bigger than a slice can afford:
-- BuildFromTriangles measured 0.73 us a vertex on a real client (2026-11-08), and a
-- 4096-triangle mesh was a 9 ms frame -- every build's worst.
T.test("client perf: no mesh handed to the engine is more than a build slice can take", function()
    local _, world = F.server()
    local cl = F.client(world)
    MF.enable(cl)
    local BM = cl.env.BMX.BikeMesh
    local budgetMs = 4
    T.between(BM.MAX_TRIS * 3 * 0.73e-3, 0, budgetMs, "the biggest mesh's handover at the measured rate, ms")
end)

-- A FINISHED MODEL IS WARMED BEFORE IT IS SHOWN: the first frame that drew one handed
-- every mesh to the GPU at once (a 30 ms frame on a real client). Each mesh is drawn once
-- with colour and depth writes off, a slice a frame, from a drawn vehicle only (the
-- prebuild's Think has no 3D draw), and the model is ready after the last.
T.test("client perf: a built model is warmed a slice a frame before it is drawn, never from the prebuild", function()
    local _, world = F.server()
    local cl = F.client(world)
    MF.enable(cl)
    local E, B = cl.env, cl.env.BMX
    local BM = B.BikeMesh
    BM.Clear()
    local writesOff, warmDraws, visibleDraws = false, 0, 0
    E.render.OverrideColorWriteEnable = function(on, write) writesOff = on and not write end
    E.render.OverrideDepthEnable = function() end
    E.Mesh = function()
        local m = { valid = true }
        function m:BuildFromTriangles() end
        function m:Draw() if writesOff then warmDraws = warmDraws + 1 else visibleDraws = visibleDraws + 1 end end
        function m:Destroy() self.valid = false end
        function m:IsValid() return self.valid end
        return m
    end
    local clock = 0
    E.SysTime = function() clock = clock + 0.0001 return clock end
    -- build it to the end, asked by a drawn vehicle each frame
    local m
    for _ = 1, 20000 do
        m = BM.Get(1, 10)
        if m or BM.Status()["1.000/10.000"] == "warming" then break end
    end
    T.eq(m, nil, "not ready the moment the build ends")
    T.eq(BM.Status()["1.000/10.000"], "warming", "warming")
    -- the prebuild's asks do not warm it
    local before = warmDraws
    BM.Background(true)
    for _ = 1, 5 do BM.Get(1, 10) end
    BM.Background(false)
    T.eq(warmDraws, before, "no warming from the prebuild")
    -- drawn asks do, a slice a frame, until it is ready
    local frames = 0
    while not m and frames < 1000 do m = BM.Get(1, 10) frames = frames + 1 end
    T.ok(m ~= nil and m.ready, "ready once warmed")
    T.ok(frames > 1, "spread over frames (" .. frames .. ")")
    local meshes = 0
    for _, list in pairs(m.groups) do for _, e in ipairs(list) do meshes = meshes + #e.meshes end end
    T.eq(warmDraws, meshes, "every mesh drawn once with nothing written")
    T.eq(visibleDraws, 0, "and none drawn visibly before it is ready")
    T.eq(#cl.errors, 0, "no errors: " .. table.concat(cl.errors, " | "))
end)

-- BUILT WHILE YOU CHOOSE: pointing at a vehicle in the /bike menu (or the Q menu's icon)
-- builds that kind's model before the click, so the spawn has nothing left to build.
-- Only that kind (all of them would be ~200 MB of a 32-bit game), and nothing drawn from
-- outside a 3D draw: the spawned vehicle's own Draw warms it.
T.test("client perf: pointing at a vehicle in the menu builds its model before the click, that one only", function()
    local _, world = F.server()
    local cl = F.client(world)
    MF.enable(cl)
    local E, B = cl.env, cl.env.BMX
    local BM = B.BikeMesh
    BM.Clear()
    local drawn = 0
    E.render.OverrideColorWriteEnable = function() end
    E.render.OverrideDepthEnable = function() end
    E.Mesh = function()
        local m = { valid = true }
        function m:BuildFromTriangles() end
        function m:Draw() drawn = drawn + 1 end
        function m:Destroy() self.valid = false end
        function m:IsValid() return self.valid end
        return m
    end
    local clock = 0
    E.SysTime = function() clock = clock + 0.0001 return clock end
    local button = { BMXVehicleId = "road" }
    function button:IsValid() return true end
    function button:GetParent() return nil end
    local hovered = button
    E.vgui = E.vgui or {}
    E.vgui.GetHoveredPanel = function() return hovered end
    local think = E.hook.GetTable().Think["BMX.ModelIntent"]
    T.ok(think ~= nil, "the menu-intent hook is there")
    local function status()
        local n, st = 0, nil
        for k, v in pairs(BM.Status()) do n = n + 1 st = v end
        return n, st
    end
    for _ = 1, 20000 do
        think()
        local n, st = status()
        if st == "warming" or st == "ready" then break end
    end
    local n, st = status()
    T.eq(n, 1, "one model asked for: the one pointed at")
    T.ok(st == "warming", "built, left to warm in a 3D draw (" .. tostring(st) .. ")")
    T.eq(drawn, 0, "nothing drawn from the menu's Think")
    -- the world's 3D pass under the open menu warms it: ready before any click
    local warm = E.hook.GetTable().PostDrawOpaqueRenderables["BMX.ModelIntentWarm"]
    T.ok(warm ~= nil, "the menu-intent warming hook is there")
    warm(true, false)
    T.eq(drawn, 0, "not in the depth pass")
    for _ = 1, 2000 do
        warm(false, false)
        local _, st2 = status()
        if st2 == "ready" then break end
    end
    local _, st3 = status()
    T.eq(st3, "ready", "ready before the click")
    T.ok(drawn > 0, "warmed in the 3D pass")
    -- pointing away: it keeps going a few seconds, then nothing more is asked
    hovered = nil
    E.RealTime = function() return 1e6 end
    think()
    T.eq((status()), 1, "no other model started")
    T.eq(#cl.errors, 0, "no errors: " .. table.concat(cl.errors, " | "))
end)

-- MODELS NOBODY USES ARE LET GO: every model built stayed for the session, ~200 MB of a
-- 32-bit game's memory once every kind had been seen. Idle 5 minutes, a model is freed,
-- but the bmx_model_keep most recent are kept to 15; one a vehicle asks for, never.
T.test("client perf: a model nothing uses is freed after a while, a few kept, one in use never", function()
    local _, world = F.server()
    local cl = F.client(world)
    MF.enable(cl)
    local E, B = cl.env, cl.env.BMX
    local BM = B.BikeMesh
    BM.Clear()
    local destroyed = 0
    E.Mesh = function()
        local m = { valid = true }
        function m:BuildFromTriangles() end
        function m:Draw() end
        function m:Destroy() self.valid = false destroyed = destroyed + 1 end
        function m:IsValid() return self.valid end
        return m
    end
    local clock, now = 0, 0
    E.SysTime = function() clock = clock + 0.0001 return clock end
    E.RealTime = function() return now end
    local function build(k, r) local m for _ = 1, 20000 do m = BM.Get(k, r) if m then return m end end end
    local a, b = build(1, 10), build(1.1, 12)
    T.ok(a and b, "two models built")
    local function count() local n = 0 for _ in pairs(BM.Status()) do n = n + 1 end return n end
    -- keep 0: both idle past 5 minutes are freed; while one is still asked for it stays
    E.GetConVar("bmx_model_keep"):SetInt(0)
    for t = 10, 400, 10 do now = t BM.Get(1, 10) BM.Sweep() end
    T.eq(count(), 1, "the idle one freed, the one still asked for kept")
    T.ok(b.cleared and destroyed > 0, "its meshes destroyed")
    T.ok(not a.cleared, "the one in use untouched")
    -- keep 4: idle, it stays until fifteen minutes
    E.GetConVar("bmx_model_keep"):SetInt(4)
    for t = 410, 1250, 10 do now = t BM.Sweep() end
    T.eq(count(), 1, "kept while idle under fifteen minutes")
    for t = 1260, 1400, 10 do now = t BM.Sweep() end
    T.eq(count(), 0, "freed after fifteen minutes idle")
    T.eq(#cl.errors, 0, "no errors: " .. table.concat(cl.errors, " | "))
end)

-- THE MATERIALS ARE MADE WHILE THE GAME LOADS, one a tick after joining, not all in the
-- frame of the session's first spawn (26 ms of it on a real client).
T.test("client perf: after joining, every vehicle material is made one a tick, before any spawn", function()
    local _, world = F.server()
    local cl = F.client(world)
    MF.enable(cl)
    local E, BM = cl.env, cl.env.BMX.BikeMesh
    local made = {}
    local real = BM.Material
    BM.Material = function(role, ...) made[role] = true return real(role, ...) end
    T.ok(E.hook.GetTable().InitPostEntity["BMX.WarmMaterials"] ~= nil, "it starts after joining")
    BM.WarmMaterials()
    for _ = 1, 400 do world.time = world.time + 0.05 cl:runTimers() end
    for _, role in ipairs({ "decal", "tyretext", "paint", "black", "chrome", "rubber", "lens" }) do
        T.ok(made[role], role .. " made")
    end
    BM.Material = real
    T.eq(#cl.errors, 0, "no errors: " .. table.concat(cl.errors, " | "))
end)

local function buildStretches(id)
    local _, world = F.server()
    local cl = F.client(world)
    MF.enable(cl)
    local E, B = cl.env, cl.env.BMX
    local BM = B.BikeMesh
    BM.Clear()
    local sizes = {}
    E.Mesh = function()
        local m = { valid = true }
        function m:BuildFromTriangles(v) sizes[#sizes + 1] = #v end
        function m:Draw() end
        function m:Destroy() self.valid = false end
        function m:IsValid() return self.valid end
        return m
    end
    local clock = 0
    E.SysTime = function() clock = clock + 1 return clock end
    local resumes, k = {}, 0
    local realResume = coroutine.resume
    E.coroutine = setmetatable({ resume = function(co, ...)
        k = 0
        debug.sethook(co, function() k = k + 1 end, "", 100)
        local r = { realResume(co, ...) }
        debug.sethook(co)
        resumes[#resumes + 1] = k
        return unpack(r)
    end }, { __index = coroutine })
    -- (the skates are worn, not an entity: their model is asked for by the skater's drawing)
    local ask
    if B.Vehicles[id].worn then
        ask = B.Skates.Model
    else
        local ent = cl:clientEntity(B.ClassFor(id))
        ask = function() return B.BikeModelFor(ent) end
    end
    cl.eyePos = E.Vector(-100, 0, 50)
    local model
    for _ = 1, 200000 do
        model = ask()
        if model then break end
    end
    E.coroutine = nil
    T.ok(model, id .. ": the model was built")
    T.eq(#cl.errors, 0, id .. ": no errors: " .. table.concat(cl.errors, " | "))
    local worst, total = 0, 0
    for _, n in ipairs(resumes) do worst, total = math.max(worst, n), total + n end
    local verts, big = 0, 0
    for _, n in ipairs(sizes) do verts, big = verts + n, math.max(big, n) end
    if os.getenv("BMX_TRACE") then
        print(string.format("    %s: %d resumes, longest %d00 instructions of %d00; %d meshes, the largest %d vertices",
            id, #resumes, worst, total, #sizes, big))
    end
    return { worst = worst * 100, total = total * 100, resumes = #resumes, meshes = #sizes, biggest = big,
             verts = verts, tris = model.stats.total }
end

T.test("client perf: a model build gives the frame back within a few thousand instructions, a mesh at a time", function()
    for _, id in ipairs({ "stock", "dirtbike", "road", "scooter", "unicycle", "skates" }) do
        local b = buildStretches(id)
        T.eq(b.verts, b.tris * 3, id .. ": every triangle meshed, once")
        T.ok(b.biggest <= MAX_MESH_VERTS, string.format("%s: no mesh over %d vertices in one call: %d",
            id, MAX_MESH_VERTS, b.biggest))
        T.ok(b.worst <= 60000, string.format("%s: the longest stretch without looking at the clock: %d instructions (budget 60000)",
            id, b.worst))
    end
end)

-- THE VEHICLE ON SCREEN FIRST. The prebuild Think asks for every vehicle in the world's
-- model, drawn or not, and the first ask of a frame used to run its build: a bike in
-- view could wait behind one across the map. A build a drawing asks for now runs first
-- (and at the full budget); the prebuild's own, after it.
T.test("client perf: the vehicle being drawn has its model built first, the rest of the world's after", function()
    local _, world = F.server()
    local cl = F.client(world)
    MF.enable(cl)
    local E, B = cl.env, cl.env.BMX
    local BM = B.BikeMesh
    BM.Clear()
    local frame, t = 0, 0
    E.FrameNumber = function() return frame end
    E.RealTime = function() return t end
    local away = cl:clientEntity(B.ClassFor("stock"))
    away:SetPos(E.Vector(-3000, 0, 20))
    local inView = cl:clientEntity(B.ClassFor("road"))
    inView:SetPos(E.Vector(0, 0, 20))
    cl.eyePos = E.Vector(-100, 0, 50)
    local think = cl.hooks.Think and cl.hooks.Think["BMX.BikeModelPrebuild"]
    T.ok(think, "the prebuild Think")
    -- (the BMX's key is its size alone, "k/radius"; every other kind's begins with its name)
    local roadAt, bmxAt
    for f = 1, 40000 do
        frame, t = f, f / 60
        think()
        MF.draw(cl, inView)          -- the road bike is on screen, the BMX is not
        for key, st in pairs(BM.Status()) do
            if st == "ready" then
                if key:find("^road/") then roadAt = roadAt or f
                elseif not key:find("/.*/") then bmxAt = bmxAt or f end
            end
        end
        if roadAt and bmxAt then break end
    end
    T.ok(roadAt and bmxAt, "both built (the BMX by the prebuild alone)")
    T.ok((roadAt or 1e9) < (bmxAt or 0), string.format("the drawn road bike first: frame %s, the BMX frame %s",
        tostring(roadAt), tostring(bmxAt)))
    T.eq(#cl.errors, 0, "no errors: " .. table.concat(cl.errors, " | "))
end)

T.test("client perf: a vehicle's ready model is remembered, and forgotten when it must be", function()
    local _, world = F.server()
    local cl = F.client(world)
    local E, B = cl.env, cl.env.BMX
    local BM = B.BikeMesh
    local owner, bike, C = {}, { look = "x" }, {}
    local asks, model = 0, { ready = true }
    local function get() asks = asks + 1 return model end
    E.Mesh = E.Mesh or function() return {} end
    local enabled = BM.Enabled
    BM.Enabled = function() return true end
    T.eq(BM.Remembered(owner, bike, C, get), model, "asked the first time")
    T.eq(BM.Remembered(owner, bike, C, get), model, "remembered after")
    T.eq(asks, 1, "asked once for two frames")
    B.ConfigRevision = B.ConfigRevision + 1
    BM.Remembered(owner, bike, C, get)
    T.eq(asks, 2, "asked again when the config moved")
    BM.Remembered(owner, bike, {}, get)
    T.eq(asks, 3, "asked again for another config table")
    model.cleared = true
    local fresh = { ready = true }
    model = fresh
    T.eq(BM.Remembered(owner, bike, {}, get), fresh, "a cleared model is never handed back")
    BM.Enabled = function() return false end
    T.eq(BM.Remembered(owner, bike, {}, get), nil, "nothing with the models switched off")
    -- still building (nil): asked for again every time, nothing remembered
    BM.Enabled = function() return true end
    local building, owner2 = 0, {}
    local function none() building = building + 1 return nil end
    T.eq(BM.Remembered(owner2, bike, C, none), nil, "still building: nil")
    T.eq(BM.Remembered(owner2, bike, C, none), nil, "and again")
    T.eq(building, 2, "asked both times")
    BM.Enabled = enabled
end)
