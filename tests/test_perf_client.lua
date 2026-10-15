--[[--------------------------------------------------------------------------
    What a CLIENT frame costs, held to a budget.

    test_perf.lua budgets the server's traces; this budgets the client's frame:
    the engine work a rider near the view costs every frame on every player's
    machine, counted, not timed (a count is the same on any box, every run).

    The dearest thing a client does for this addon is have the engine pose a
    rider's whole skeleton (InvalidateBoneCache + SetupBones): the IK reads bones
    after every joint it turns. Until 1.3.5 it posed 58 times a frame for each
    BMX rider in view, 49 for a scooter's, 42 for a board's, about half of them on
    a skeleton nothing had touched (tools/bench/client_frame.lua). The budgets carry
    headroom: they catch a doubling, not noise. tools/bench/client_frame.lua is
    where to look when one fails: it times and counts every hook.
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
