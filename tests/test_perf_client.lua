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
    n.by = {}
    P.SetupBones = function(...)
        n.setup = n.setup + 1
        if os.getenv("BMX_SB_BY") then
            local k = {}
            for lv = 3, 6 do local i = debug.getinfo(lv, "Sl") if i and i.source:find("cl_rider") then k[#k + 1] = i.currentline end end
            local key = table.concat(k, "<")
            n.by[key] = (n.by[key] or 0) + 1
        end
        return setup(...)
    end
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
-- How far the fists and feet are from what the vehicle drew for them (as the camera
-- sweep judges it): a cheaper pose that lands worse is no saving.
local function limbMiss(B, ply, ik)
    if not ik then return nil end
    local function seg(P, A, Bv)
        local g = Bv - A
        local t = math.max(0, math.min(1, (P - A):Dot(g) / math.max(g:Dot(g), 1e-6)))
        return (A + g * t - P):Length()
    end
    local function bpos(name)
        local b = ply:LookupBone(name)
        local m = b and ply:GetBoneMatrix(b)
        return m and m:GetTranslation()
    end
    local miss = 0
    for _, side in ipairs({ "r", "l" }) do
        local k = side .. "Hand"
        local fc = B.RiderFistCentre and B.RiderFistCentre(ply, side:upper())
        if fc and ik[k] then
            local A2, B2 = ik[k .. "A"], ik[k .. "B"]
            miss = math.max(miss, (A2 and B2) and seg(fc, A2, B2) or (fc - ik[k]):Length())
        end
    end
    for k, bones in pairs({ rFoot = { "ValveBiped.Bip01_R_Foot", "ValveBiped.Bip01_R_Toe0" },
                            lFoot = { "ValveBiped.Bip01_L_Foot", "ValveBiped.Bip01_L_Toe0" } }) do
        local a, t = bpos(bones[1]), bpos(bones[2])
        if a and t and ik[k] then miss = math.max(miss, seg(ik[k], a, t)) end
    end
    return miss
end

local function rideCost(id, speed, frames, warm, prev)
    local sv, world = F.server()
    local cl = F.client(world)
    local E, B = cl.env, cl.env.BMX
    world.dt = 1 / 60
    if prev then
        -- ridden first, in this client, and got off: on foot for a second
        local p = cl:player("Rider")
        p._skel = SR.load("kleiner_seated")
        cl.localPlayer = sv:player("Looker")
        local e = cl:clientEntity(B.ClassFor(prev))
        local C0 = e:Cfg()
        e:SetPos(E.Vector(0, 0, C0.Wheel.radius)); e:SetGrounded(true)
        if e.SetPedalling then e:SetPedalling(true) end
        e:SetSpeedUPS(speed); e._vel = e:GetForward() * speed
        local pod = seatPod(cl, e, B.SeatFor(e:Bike(), C0, "rider"))
        e:SetPod(pod); e:SetDriver(p); p._vehicle = pod
        cl.eyePos = p:GetPos() + E.Vector(-110, 0, 60)
        for _ = 1, 30 do
            world.time = world.time + world.dt
            e:Draw(); E.hook.Run("PrePlayerDraw", p); E.hook.Run("PostPlayerDraw", p)
        end
        e:SetDriver(nil); p._vehicle = nil
        for _ = 1, 60 do
            world.time = world.time + world.dt
            E.hook.Run("PrePlayerDraw", p); E.hook.Run("PostPlayerDraw", p)
        end
        e:Remove()
    end
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
    for _ = 1, warm or 30 do frame() end
    local n = counter(cl)
    local worst, last = 0, 0
    for _ = 1, frames do
        frame()
        worst = math.max(worst, n.setup - last)
        if os.getenv("BMX_SB_BY") then io.write(" [", n.setup - last, "]") end
        last = n.setup
    end
    n.stop()
    if os.getenv("BMX_SB_BY") then
        local rows = {}
        for k, v in pairs(n.by) do rows[#rows + 1] = { k, v } end
        table.sort(rows, function(a, b) return a[2] > b[2] end)
        for i = 1, math.min(8, #rows) do print("      " .. id .. " " .. rows[i][1] .. " x" .. rows[i][2]) end
    end
    T.eq(#cl.errors, 0, id .. ": no errors: " .. table.concat(cl.errors, " | "))
    local out = { setup = n.setup / frames, lookup = n.lookup / frames, vec = n.vec / frames, worst = worst }
    out.miss = ent and limbMiss(B, ply, ent.ikTargets)
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

T.test("client perf: the first frames on a vehicle pose the rider at most a few ordinary frames' worth each", function()
    for _, id in ipairs({ "stock", "mini", "penny", "unicycle" }) do
        local c = rideCost(id, 150, 4, 0)
        if os.getenv("BMX_TRACE") then
            print(string.format("    mount %s: worst %d SetupBones in a frame of the first 4, %.1f a frame", id, c.worst, c.setup))
        end
        -- 2026-11-11: 61 (stock), 58 (mini), 72 (penny), 42 (unicycle) in the first frame,
        -- the hand calibration included, against ~11 an ordinary frame: every joint starts
        -- from the animation's pose. On a real client that frame was 11-15 ms of Lua, and
        -- each first spawn of the mini, penny and unicycle went just over 16.7 ms (the first
        -- whole GPU gate run). A cap on poses a frame cut it to 31-43 but starved a rider
        -- posed twice at one time (the preview tool, a re-pose before the bike is drawn):
        -- not shipped. This holds today's level until a warm start does better.
        T.between(c.worst, 1, 80, id .. ": SetupBones in the worst of the first frames on it")
    end
end)

if os.getenv("BMX_PAIRS") then
    T.test("client perf: (diagnostic) the first frame after each previous vehicle", function()
        for pair in os.getenv("BMX_PAIRS"):gmatch("[^,]+") do
            local prev, id = pair:match("([^:]+):([^:]+)")
            local c = rideCost(id, 150, 4, 0, prev)
            print(string.format("    %s after %s: worst %d", id, prev, c.worst))
        end
    end)
end

T.test("client perf: back on a bike after another, the rider starts from the pose they had (a warm start)", function()
    -- The spawn benchmark's first-ride frames (mini, road, city; 17-20 ms on a real client,
    -- the GPU gate run 11, 2026-11-12) came after another bike had been ridden. The solve
    -- starts where the model's last one settled, not from the animation's pose.
    for _, id in ipairs({ "mini", "road", "city", "penny" }) do
        local cold = rideCost(id, 150, 4, 0)
        local warm = rideCost(id, 150, 4, 0, "stock")
        if os.getenv("BMX_TRACE") then
            print(string.format("    mount %s: worst %d cold, %d after the stock bike; limbs off %.2f cold, %.2f warm",
                id, cold.worst, warm.worst, cold.miss or -1, warm.miss or -1))
        end
        T.ok(cold.miss and warm.miss, id .. ": the limbs were measured")
        T.between(warm.miss or 99, 0, math.max((cold.miss or 0) + 0.5, 1.5), id .. ": the fists and feet land as well after another ride (u)")
        T.between(warm.worst, 1, math.max(cold.worst * 0.75, 12), id .. ": SetupBones in the worst first frame, after another ride")
    end
end)

T.test("client perf: back on the SAME vehicle after a pause, the rider is posed from a clean skeleton, not the pose before", function()
    -- The warm start is for a different vehicle. Seeded on the same one after a pause,
    -- a parked dirt bike's foot-down came 14 u off its mark in every pass of the camera
    -- sweep (the GPU gate, run 14, 2026-11-12).
    for _, id in ipairs({ "dirtbike", "stock", "city" }) do
        local sv, world = F.server()
        local cl = F.client(world)
        local E, B = cl.env, cl.env.BMX
        world.dt = 1 / 60
        local ply = cl:player("Rider")
        ply._skel = SR.load("kleiner_seated")
        cl.localPlayer = sv:player("Looker")
        local ent = cl:clientEntity(B.ClassFor(id))
        local C = ent:Cfg()
        ent:SetPos(E.Vector(0, 0, C.Wheel.radius)); ent:SetGrounded(true)
        if ent.SetPedalling then ent:SetPedalling(true) end
        ent:SetSpeedUPS(250); ent._vel = ent:GetForward() * 250
        local pod = seatPod(cl, ent, B.SeatFor(ent:Bike(), C, "rider"))
        ent:SetPod(pod); ent:SetDriver(ply); ply._vehicle = pod
        cl.eyePos = ply:GetPos() + E.Vector(-110, 0, 60)
        local function frame()
            world.time = world.time + world.dt
            ent:Draw(); E.hook.Run("PrePlayerDraw", ply); E.hook.Run("PostPlayerDraw", ply)
        end
        for _ = 1, 40 do frame() end
        -- a second not drawn, and parked when next seen
        world.time = world.time + 1
        if ent.SetPedalling then ent:SetPedalling(false) end
        ent:SetSpeedUPS(0); ent._vel = E.Vector(0, 0, 0)
        frame()
        local first = limbMiss(B, ply, ent.ikTargets)
        for _ = 1, 3 do frame() end
        local settled = limbMiss(B, ply, ent.ikTargets)
        if os.getenv("BMX_TRACE") then
            print(string.format("    %s parked after a pause: limbs off %.2f the first frame, %.2f settled", id, first or -1, settled or -1))
        end
        T.eq(#cl.errors, 0, id .. ": no errors")
        T.between(first or 99, 0, 7, id .. ": the first frame back, every fist and foot within 7 u (the sweep's bad frame)")
    end
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

-- THE STAND-IN'S SHAPES LOADED WHILE JOINING: the first spawn of a session drew its
-- stand-in from base-game models (a cylinder, a ball, a box, the tyre) nothing had
-- loaded, in four materials, all in that spawn's frames. Each is drawn once after
-- joining, invisibly, a shape a frame, and nothing is left behind.
T.test("client perf: after joining, the stand-in's shapes are drawn once each, invisibly, and let go", function()
    local _, world = F.server()
    local cl = F.client(world)
    local E, B = cl.env, cl.env.BMX
    T.ok(E.hook.GetTable().InitPostEntity["BMX.WarmStandIn"] ~= nil, "it starts after joining")
    local writesOff, hidden, visible = false, {}, 0
    E.render.OverrideColorWriteEnable = function(on, write) writesOff = on and not write end
    E.render.OverrideDepthEnable = function() end
    local made = {}
    local CSM = E.ClientsideModel
    E.ClientsideModel = function(...)
        local m = CSM(...)
        if m then
            made[#made + 1] = m
            local d = m.DrawModel
            m.DrawModel = function(self)
                if writesOff then hidden[self.model .. "|" .. tostring(self.material)] = true else visible = visible + 1 end
                return d(self)
            end
        end
        return m
    end
    B.WarmStandIn()
    local frames = 0
    for _ = 1, 40 do E.hook.Run("PostDrawOpaqueRenderables", false, false) frames = frames + 1 end
    for _, kind in ipairs({ "cyl", "sph", "box" }) do
        for _, mt in pairs(B.BikeMaterials) do
            T.ok(hidden[B.BikePrimitives[kind].model .. "|" .. mt], kind .. " drawn in " .. mt)
        end
    end
    T.ok(hidden[B.TyreModel .. "|nil"], "the tyre drawn")
    T.eq(visible, 0, "nothing drawn visibly")
    T.ok(#made >= 13 and #made <= 14, "a shape a frame: " .. #made .. " made")
    for _, m in ipairs(made) do T.ok(m.removed, "let go: " .. m.model) end
    T.eq(E.hook.GetTable().PostDrawOpaqueRenderables["BMX.WarmStandIn"], nil, "and its hook gone when done")
    E.ClientsideModel = CSM
    T.eq(#cl.errors, 0, "no errors: " .. table.concat(cl.errors, " | "))
end)

-- THE STAND-IN, CHEAPER: while a vehicle's model is on its way it is drawn from shapes,
-- a prop draw per tube and joint (67 for a BMX up close: dearer than the model it
-- stands in for). It is drawn at the middle detail meanwhile, about half the draws. Not
-- for a vehicle with the models off (that is its look, in full), and not past 10 s (a
-- build that has given up leaves the full stand-in).
T.test("client perf: while its model builds, a vehicle up close is drawn from half the shapes", function()
    local _, world = F.server()
    local cl = F.client(world)
    MF.enable(cl)
    local E, B = cl.env, cl.env.BMX
    local ent = cl:clientEntity(B.ClassFor("stock"))
    ent:SetPos(E.Vector(0, 0, 10))
    ent:SetGrounded(true)
    cl.eyePos = E.Vector(-110, 0, 60)
    local real = B.BikeModelFor
    B.BikeModelFor = function() return nil end
    local function shapes()
        cl.drawnCS = {}
        ent:Draw()
        return #cl.drawnCS
    end
    world.time = world.time + 0.1
    local pending = shapes()
    E.GetConVar("bmx_bike_model"):SetInt(0)
    local full = shapes()
    E.GetConVar("bmx_bike_model"):SetInt(1)
    T.ok(full >= 60, "the full stand-in: " .. full .. " shapes")
    T.ok(pending <= full * 0.65, "while the model builds: " .. pending .. " of " .. full)
    T.ok(B.StandingIn(ent), "standing in")
    -- asking whether it stands in does not ask for the model (an ask advances its build)
    local asked = 0
    B.BikeModelFor = function() asked = asked + 1 return nil end
    B.StandingIn(ent)
    T.eq(asked, 0, "StandingIn reads the memo, it does not ask for the model")
    B.BikeModelFor = function() return nil end
    world.time = world.time + 11
    T.eq(shapes(), full, "a build that never finishes: the full stand-in after 10 s")
    B.BikeModelFor = real
    T.eq(#cl.errors, 0, "no errors: " .. table.concat(cl.errors, " | "))
end)

-- SOUNDS HEARD ONCE, SILENTLY, WHILE JOINING: the first play of a sound of ours loaded it
-- inside PlayEx (10.9 ms on a real client; the e-bike's first motor whine). Every sound,
-- every variant, is played at volume 0 and stopped after joining.
T.test("client perf: after joining, every sound is played once at volume 0 and stopped", function()
    local sv, world = F.server()
    local cl = F.client(world)
    local E, B = cl.env, cl.env.BMX
    cl.localPlayer = sv:player("Joiner")
    T.ok(E.hook.GetTable().InitPostEntity["BMX.WarmSounds"] ~= nil, "it starts after joining")
    local n0 = #cl.patches
    B.WarmSounds()
    -- held a while, silent, so the engine has loaded it before it is stopped (stopped in the
    -- frame it started, the e-bike's whine still cost its first ride a 60-65 ms frame)
    for _ = 1, 6 do world.time = world.time + 0.05 cl:runTimers() end
    local first = cl.patches[n0 + 1]
    T.ok(first and first.playing and first.vol == 0, "the first is still playing, silent, 0.1 s after it started")
    for _ = 1, 400 do world.time = world.time + 0.05 cl:runTimers() end
    local warmed = {}
    for i = n0 + 1, #cl.patches do
        local p = cl.patches[i]
        T.eq(p.vol, 0, "silent: " .. p.path)
        T.ok(not p.playing, "stopped: " .. p.path)
        warmed[p.path] = true
    end
    local want = 0
    for _, snd in pairs(B.Sounds) do
        if snd.path then
            for i = 1, snd.variants or 1 do
                local path = snd.variants and string.format(snd.path, i) or snd.path
                want = want + 1
                T.ok(warmed[path], "warmed: " .. path)
            end
        end
    end
    T.ok(want >= 10 and warmed["bmx/motor.wav"], "the motor's whine among " .. want)
    T.eq(#cl.errors, 0, "no errors: " .. table.concat(cl.errors, " | "))
end)

-- A BUSY FRAME GETS HALF A SLICE: after a long frame (the collector working through a
-- build's garbage, charged to the rider's pose) the build takes half its slice, so the
-- two together stay under a 60 fps frame.
T.test("client perf: after a long frame the model build takes half its slice", function()
    local _, world = F.server()
    local cl = F.client(world)
    local BM = cl.env.BMX.BikeMesh
    local full = cl.env.GetConVar("bmx_bike_build_ms"):GetFloat()
    local function settle(dt) world.dt = dt for _ = 1, 300 do cl.env.hook.Run("Think") end end
    settle(1 / 250)
    T.near(BM.SliceBudget(), full, 1e-9, "a quick frame: the whole slice")
    world.dt = 0.018
    T.near(BM.SliceBudget(), full * 0.5, 1e-9, "an 18 ms frame on a 250 fps machine: half")
    settle(1 / 60)
    T.near(BM.SliceBudget(), full, 1e-9, "a steady 60 fps machine: the whole slice, every frame")
    world.dt = 0.034
    T.near(BM.SliceBudget(), full * 0.5, 1e-9, "and half after a 34 ms frame there")
    -- the frame a vehicle arrives (the engine makes it and its seat then): no slice
    world.dt = 1 / 60
    local fn = 100
    cl.env.FrameNumber = function() return fn end
    local e = cl:clientEntity(cl.env.BMX.ClassFor("stock"))
    cl.env.hook.Run("OnEntityCreated", e)
    T.eq(BM.SliceBudget(), 0, "none in the frame a vehicle arrives")
    fn = 101
    T.near(BM.SliceBudget(), full, 1e-9, "the whole slice the frame after")
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
