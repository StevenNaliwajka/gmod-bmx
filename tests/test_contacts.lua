--[[--------------------------------------------------------------------------
    Hands and feet on the vehicle, for EVERY vehicle (cl_init.lua, cl_oddbikes.lua,
    cl_rider.lua, cl_motor.lua, cl_skates.lua).

    The owner's brief: none of the motorised vehicles shows pedals unless pedals are
    its drive, and the rider's feet and hands are where the vehicle's pedals, pegs
    and grips are. So, vehicle by vehicle from the registry (a new one is checked
    the day it is registered):

      * NO PEDALS ON A MOTORBIKE, in any drawing. A vehicle Motor.HasPedals says has
        none (the e-moto, the dirt bike) draws no cranks, pedals, chainring or
        pedal chain, neither in its built model nor in the stand-in drawing (shown
        while the model builds, with bmx_bike_model 0 and under bmx_debug), and its
        feet go on its footpegs, the same pegs in both. The e-bike and the moped
        keep theirs: they are their drive (and the moped's starter).
      * THE TARGETS ARE THE ANCHORS. In both drawings, each foot target is on its
        drawn pedal or peg (0.9 k above its centre or top, the sole), following the
        crank as it turns; each hand's grip range is the drawn grip, and goes with
        the bars when they steer; right is right.
      * THE RIDER REACHES THEM. With a rider seated, the IK puts the pedal under
        the foot (the ball of the foot on it wherever the leg can fold that far),
        the bar inside the closed fist, and the knees forward of the hip-foot line.
      * THE MOPED rests its rider's feet on level cranks once its engine runs.
      * THE SKATES stand on the ground, wheels on the floor, however deep the knees.

    What only a person on a client can judge (does it LOOK right on a real player
    model) is not here; where everything is, is.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local MF = require("lib.meshfake")

-- One world, one client, every vehicle spawned side by side: the models are built
-- once each (seconds), and a vehicle's scene is made on first use.
local W
local function world()
    if W then return W end
    local sv, wd = F.server()
    local cl = F.client(wd)
    MF.enable(cl)
    W = { sv = sv, cl = cl, E = cl.env, scenes = {}, n = 0 }
    return W
end

local function ids()
    local B = world().E.BMX
    local out = {}
    for id, v in pairs(B.Vehicles) do
        if (v.family == "bike" or v.family == "moto") and not v.hidden then out[#out + 1] = id end
    end
    table.sort(out)
    return out
end

local function scene(id)
    local w = world()
    if w.scenes[id] then return w.scenes[id] end
    local E, B = w.E, w.E.BMX
    w.n = w.n + 1
    local cfg = B.ConfigFor(B.Vehicles[id])
    local pos = E.Vector(w.n * 400, 0, w.sv.world.groundZ + B.RestHeight(cfg))
    local sb = F.bike(w.sv, B.ClassFor(id), pos)
    local cb = w.cl:clientEntity(B.ClassFor(id))
    cb:SetPos(sb:GetPos())
    cb:SetAngles(sb:GetAngles())
    for k, v in pairs(sb._nw) do cb._nw[k] = v end
    local s = { id = id, cb = cb, sb = sb, def = B.Vehicles[id], cfg = cfg,
                k = math.max(cfg.Wheel.wheelbase, 1) / 39 }
    w.scenes[id] = s
    return s
end

-- Draw a scene with the eye beside it: the near level of detail (pedal blocks are
-- only drawn near) and inside the rider IK's range.
local function draw(s)
    local w = world()
    w.cl.eyePos = s.cb:GetPos() + w.E.Vector(0, -90, 30)
    MF.draw(w.cl, s.cb)
end

local function setModel(on)
    world().E.GetConVar("bmx_bike_model"):SetInt(on and 1 or 0)
end

-- The built model of a vehicle (its layout is the anchors), building it if need be.
local function model(s)
    local w = world()
    setModel(true)
    w.cl.eyePos = s.cb:GetPos() + w.E.Vector(0, -90, 30)
    T.ok(MF.ready(w.cl, s.cb), s.id .. ": the model builds")
    local B = w.E.BMX
    if s.def.drawer then return B.OddModel(s.cb, s.cb:Cfg(), false) end
    return B.BikeModelFor(s.cb)
end

local function V(E, t) return E.Vector(t[1] or t.x, t[2] or t.y, t[3] or t.z) end

-- The pieces of a crank set the stand-in drawing makes (cl_init.lua): crank arms
-- (CRANK * k long, 0.9 k across), the spindle (1.3 k across), the chainring's
-- segments (0.6 k) and the chain (0.45 k), and the pedal blocks (3.6 x 3.6 x 1).
local function crankParts(cl, k)
    local n = { arm = 0, spindle = 0, ring = 0, chain = 0, pedal = 0 }
    local function near(a, b) return math.abs(a - b) < 1e-3 end
    for _, b in ipairs(cl.beams) do
        if b.cylinder then
            local len = (b.a - b.b):Length()
            if near(b.w, 0.9 * k) and math.abs(len - 6.8 * k) < 0.01 then n.arm = n.arm + 1 end
            if near(b.w, 1.3 * k) and math.abs(len - 6.8 * k) < 0.01 then n.spindle = n.spindle + 1 end
            if near(b.w, 0.6 * k) then n.ring = n.ring + 1 end
            if near(b.w, 0.45 * k) then n.chain = n.chain + 1 end
        end
    end
    local pedals = {}
    for _, d in ipairs(cl.drawnCS) do
        if d.model:find("cube025x025x025", 1, true) then
            local sc = d.scale
            if math.abs(sc.x / sc.z - 3.6) < 0.01 and math.abs(sc.y / sc.z - 3.6) < 0.01 then
                n.pedal = n.pedal + 1
                pedals[#pedals + 1] = d.pos
            end
        end
    end
    return n, pedals
end

local function nearest(list, p)
    local best, bd = nil, math.huge
    for _, q in ipairs(list) do
        local d = (q - p):Length()
        if d < bd then best, bd = q, d end
    end
    return best, bd
end

-- The nearest point of segment a-b to p, and how far.
local function onSegment(p, a, b)
    local g = b - a
    local t = math.max(0, math.min(1, (p - a):Dot(g) / math.max(g:Dot(g), 1e-9)))
    local q = a + g * t
    return (q - p):Length(), t
end

--------------------------------------------------------------------------
-- NO PEDALS ON A MOTORBIKE
--------------------------------------------------------------------------

T.test("contacts: the registry says which vehicles pedal, and only throttle and plain engines do not", function()
    local B = world().E.BMX
    local without = {}
    for _, id in ipairs(ids()) do
        if not B.Motor.HasPedals(B.Vehicles[id]) then without[#without + 1] = id end
    end
    table.sort(without)
    T.eq(table.concat(without, " "), "dirtbike emoto", "the vehicles without pedals")
    T.ok(B.Motor.HasPedals(B.Vehicles.ebike), "the e-bike pedals (its motor assists the legs)")
    T.ok(B.Motor.HasPedals(B.Vehicles.moped), "the moped has pedals (they start it)")
    T.ok(not B.Motor.HasPedals(B.Vehicles.testcart), "a throttle has none (the test cart)")
end)

T.test("contacts: a vehicle without pedals never draws a crank or a pedal: stand-in drawing, built model, debug", function()
    local w = world()
    local B, E = w.E.BMX, w.E
    for _, id in ipairs(ids()) do
        local s = scene(id)
        local pedals = B.Motor.HasPedals(s.cb)
        for _, mode in ipairs({ "stand-in", "debug" }) do
            setModel(mode == "debug")
            E.GetConVar("bmx_debug"):SetInt(mode == "debug" and 1 or 0)
            draw(s)
            E.GetConVar("bmx_debug"):SetInt(0)
            if not s.def.drawer then
                local n = crankParts(w.cl, s.k)
                if pedals then
                    T.ok(n.arm >= 2 and n.pedal >= 2, id .. " " .. mode .. ": cranks and pedals drawn (" .. n.arm .. ", " .. n.pedal .. ")")
                else
                    T.eq(n.arm + n.spindle + n.pedal + n.ring + n.chain, 0,
                        id .. " " .. mode .. ": no crank arm, spindle, pedal, chainring or chain")
                end
            end
        end
        local M = model(s)
        T.ok(M ~= nil, id .. ": has a model")
        if not pedals then
            T.eq(MF.count(w.cl, "cranks") + MF.count(w.cl, "pedal"), 0, id .. " model: no cranks or pedals drawn")
            T.ok(M.groups.cranks == nil and M.groups.pedal == nil, id .. " model: has no crank or pedal parts at all")
            T.ok(M.layout.bb == nil and M.layout.crank == nil, id .. " model: no bottom bracket in its layout")
            T.ok(M.layout.pegs ~= nil, id .. " model: footpegs instead")
        else
            T.ok(MF.count(w.cl, "pedal") >= 2, id .. " model: its pedals are drawn")
        end
    end
end)

--------------------------------------------------------------------------
-- THE TARGETS ARE THE ANCHORS
--------------------------------------------------------------------------

-- Feet on the model's pedals or pegs, hands' grip ranges on the model's grips.
local function checkModelTargets(s, M, what)
    local w = world()
    local E = w.E
    local cb, k = s.cb, s.k
    local ik = cb.ikTargets
    local L = M.layout
    local up = cb:GetUp()
    local lift = s.def.drawer and 0.9 or 0.9 * k
    local right = cb:GetRight()
    local function sideOf(p) return (p - cb:GetPos()):Dot(right) end
    if L.pegs then
        local frame = MF.group(w.cl, "frame")
        for _, f in ipairs({ { "rFoot", L.pegs.r }, { "lFoot", L.pegs.l } }) do
            local want = frame:Apply(V(E, f[2])) + up * lift
            T.between((ik[f[1]] - want):Length(), 0, 0.05, s.id .. " " .. what .. ": " .. f[1] .. " on its peg")
        end
    elseif MF.count(w.cl, "pedal") >= 2 then
        for i, f in ipairs({ "rFoot", "lFoot" }) do
            local p = MF.group(w.cl, "pedal", i):GetTranslation()
            T.between((ik[f] - p):Length(), lift - 0.05, lift + 0.05, s.id .. " " .. what .. ": " .. f .. " on its pedal")
        end
    end
    T.ok(sideOf(ik.rFoot) > 2 and sideOf(ik.lFoot) < -2, s.id .. " " .. what .. ": the right foot on the right")
    if L.gripR then
        -- the bars for a bike, the steered front end (fork) for a penny-farthing
        local bars = MF.group(w.cl, "bars") or MF.group(w.cl, "fork")
        for _, h in ipairs({ { "rHand", L.gripR }, { "lHand", L.gripL } }) do
            local A, B = bars:Apply(V(E, h[2].A)), bars:Apply(V(E, h[2].B))
            T.between((ik[h[1] .. "A"] - A):Length(), 0, 0.01, s.id .. " " .. what .. ": " .. h[1] .. " grip's inner end")
            T.between((ik[h[1] .. "B"] - B):Length(), 0, 0.01, s.id .. " " .. what .. ": " .. h[1] .. " grip's outer end")
            T.between((onSegment(ik[h[1]], A, B)), 0, 0.01, s.id .. " " .. what .. ": " .. h[1] .. " on its grip")
        end
        T.ok(sideOf(ik.rHand) > 4 and sideOf(ik.lHand) < -4, s.id .. " " .. what .. ": the right hand on the right")
    end
    if L.bb2 and L.gripS then
        local stk = cb.ikTargetsStoker
        local frame = MF.group(w.cl, "frame")
        for i, f in ipairs({ "rFoot", "lFoot" }) do
            local p = MF.group(w.cl, "pedal", 2 + i):GetTranslation()
            T.between((stk[f] - p):Length(), lift - 0.05, lift + 0.05, s.id .. " " .. what .. ": stoker's " .. f .. " on their pedal")
        end
        T.between((stk.rHand - frame:Apply(V(E, L.gripS.r))):Length(), 0, 0.05, s.id .. " " .. what .. ": stoker's right hand on their bar")
        T.between((stk.lHand - frame:Apply(V(E, L.gripS.l))):Length(), 0, 0.05, s.id .. " " .. what .. ": stoker's left hand on their bar")
    end
end

T.test("contacts: every vehicle's model puts the hands on its grips and the feet on its pedals or pegs, as they move", function()
    local w = world()
    for _, id in ipairs(ids()) do
        local s = scene(id)
        local M = model(s)
        draw(s)
        checkModelTargets(s, M, "model")
        -- the cranks go round: the pedals with them, and the feet with the pedals
        local spin = s.def.drawer and s.cb.oddSpin and (s.cb.oddSpin.wheel or s.cb.oddSpin.front)
            or (s.cb.spin and s.cb.spin.rear)
        if spin and MF.count(w.cl, "pedal") >= 2 then
            local p0 = MF.group(w.cl, "pedal", 1):GetTranslation()
            spin.angle, spin.rate = spin.angle + 2.0, 0
            draw(s)
            T.ok((MF.group(w.cl, "pedal", 1):GetTranslation() - p0):Length() > 2, id .. ": the pedal moved round")
            checkModelTargets(s, M, "turned")
        end
        -- the bars steer: the grips and the hands with them
        if M.layout.gripR then
            local h0 = s.cb.ikTargets.rHand
            s.cb:SetSteer(0.3)
            draw(s)
            T.ok((s.cb.ikTargets.rHand - h0):Length() > 1, id .. ": the hands follow the bars")
            checkModelTargets(s, M, "steered")
            s.cb:SetSteer(0)
        end
    end
end)

T.test("contacts: the stand-in drawing puts the feet on ITS pedals, or on the model's own footpegs", function()
    local w = world()
    local B = w.E.BMX
    for _, id in ipairs(ids()) do
        local s = scene(id)
        local M = model(s)
        draw(s)
        local withModel = s.cb.ikTargets
        setModel(false)
        draw(s)
        local ik = s.cb.ikTargets
        local up = s.cb:GetUp()
        if not B.Motor.HasPedals(s.cb) then
            -- the very pegs the model has, so the feet do not move when it finishes building
            T.between((ik.rFoot - withModel.rFoot):Length(), 0, 0.05, id .. " stand-in: the right foot on the model's peg")
            T.between((ik.lFoot - withModel.lFoot):Length(), 0, 0.05, id .. " stand-in: the left foot on the model's peg")
        else
            local _, pedals = crankParts(w.cl, s.def.drawer and 1 or s.k)
            local lift = s.def.drawer and 0.9 or 0.9 * s.k
            for _, f in ipairs({ "rFoot", "lFoot" }) do
                local _, d = nearest(pedals, ik[f] - up * lift)
                T.between(d, 0, 0.05, id .. " stand-in: " .. f .. " on a drawn pedal")
            end
            -- and within a short step of where the model will have them
            -- and within a short step of where the model will have them. (Not the
            -- tandem's: its stand-in is the BMX's frame drawn long, with one crank
            -- set under a captain who sits far forward of it; the model is ready
            -- in a few frames.)
            if id ~= "tandem" then
                T.between((ik.rFoot - withModel.rFoot):Length(), 0, 3, id .. " stand-in: the right foot near the model's pedal")
            end
        end
        setModel(true)
    end
end)

--------------------------------------------------------------------------
-- THE MOPED: feet at rest on level cranks once the engine runs
--------------------------------------------------------------------------

T.test("contacts: the moped pedals with the wheel, then rests the feet on level cranks once its engine runs", function()
    local w = world()
    local s = scene("moped")
    model(s)
    local cb = s.cb
    cb.spin.rear.angle, cb.spin.rear.rate = 1.0, 0     -- cranks a little round from level
    cb:SetRpm(0)
    draw(s)
    local c0 = cb.crankAngle
    T.ok(math.abs(math.sin(c0)) > 0.2, "engine off: the cranks where the wheel has turned them: " .. c0)
    cb:SetRpm(3000)
    local prev = c0
    for _ = 1, 120 do
        draw(s)
        T.ok(math.abs(cb.crankAngle - prev) < 0.3, "eased, never snapped")
        prev = cb.crankAngle
    end
    T.near(math.sin(cb.crankAngle), 0, 1e-3, "engine running: the cranks level")
    local p1, p2 = MF.group(w.cl, "pedal", 1):GetTranslation(), MF.group(w.cl, "pedal", 2):GetTranslation()
    T.near(p1.z, p2.z, 0.01, "both pedals at the same height")
    checkModelTargets(s, model(s), "resting")
    -- the wheel rolls on and the cranks stay put
    cb.spin.rear.angle = cb.spin.rear.angle + 3
    draw(s)
    T.near(math.sin(cb.crankAngle), 0, 1e-3, "still level as the wheel turns")
    -- engine off again: the wheel takes the cranks from where they stood
    local held = cb.crankAngle
    cb:SetRpm(0)
    draw(s)
    T.near(cb.crankAngle, held, 1e-6, "picked up without a jump")
    cb.spin.rear.angle = cb.spin.rear.angle + 1
    draw(s)
    T.ok(math.abs(cb.crankAngle - held) > 0.2, "and pedalling again")
    -- a motorbike's cranks (it has none) are simply 0
    local d = scene("dirtbike")
    model(d)
    d.cb:SetRpm(6000)
    draw(d)
    T.eq(d.cb.crankAngle, 0, "the dirt bike has no crank angle to speak of")
end)

--------------------------------------------------------------------------
-- THE RIDER REACHES THEM
--------------------------------------------------------------------------

local function seat(s)
    local w = world()
    if s.ply then return s.ply end
    local cb = s.cb
    local C = cb:Cfg().Chassis
    local pod = w.cl.makeEntity("prop_vehicle_prisoner_pod")
    pod:SetParent(cb)
    cb:SetPod(pod)
    pod:SetPos(cb:LocalToWorld(C.seatOffset))
    pod:SetAngles(cb:LocalToWorldAngles(C.seatAngles))
    local ply = w.cl:player("Rider_" .. s.id)
    ply._vehicle = pod
    cb:SetDriver(ply)
    s.ply = ply
    return ply
end

local function bone(ply, name)
    return ply:GetBoneMatrix(ply:LookupBone("ValveBiped.Bip01_" .. name)):GetTranslation()
end

T.test("contacts: seated on every vehicle, the pedal or peg is under the foot, the grip in the fist, the knees forward", function()
    local w = world()
    local E = w.E
    for _, id in ipairs(ids()) do
        local s = scene(id)
        model(s)
        local ply = seat(s)
        local cb = s.cb
        cb.spin = cb.spin or {}
        for _ = 1, 30 do
            draw(s)
            E.hook.Run("PrePlayerDraw", ply)
        end
        ply:InvalidateBoneCache(); ply:SetupBones()
        local ik = cb.ikTargets
        local fwd = cb:GetForward()
        for _, sd in ipairs({ "R", "L" }) do
            local foot, toe = bone(ply, sd .. "_Foot"), bone(ply, sd .. "_Toe0")
            local tgt = ik[sd:lower() .. "Foot"]
            local d = onSegment(tgt, foot, toe)
            T.between(d, 0, 2, id .. ": the " .. sd .. " pedal or peg under the foot, units")
            local hip, knee = bone(ply, sd .. "_Thigh"), bone(ply, sd .. "_Calf")
            local line = (foot - hip):GetNormalized()
            local off = (knee - hip) - line * (knee - hip):Dot(line)
            T.ok(off:Dot(fwd) > 0, id .. ": the " .. sd .. " knee bends forward: " .. off:Dot(fwd))
            local hand = ik[sd:lower() .. "HandHeld"] or ik[sd:lower() .. "Hand"]
            if s.def.pose ~= "unicycle" then
                local fist = E.BMX.RiderFistCentre(ply, sd)
                -- Within the rig's reach: the suite's skeleton has no torso lean of
                -- its own, so the dirt bike's tall, far bars are a stretch for it. A
                -- grip out of reach is reached for: the arm straight at it.
                local sh, el, wr = bone(ply, sd .. "_UpperArm"), bone(ply, sd .. "_Forearm"), bone(ply, sd .. "_Hand")
                local arm = (el - sh):Length() + (wr - el):Length() + (fist - wr):Length()
                local short = math.max(0, (hand - sh):Length() - arm)
                T.between((fist - hand):Length(), 0, 2.5 + short, id .. ": the " .. sd .. " grip inside the fist (or reached for), units")
            else
                T.between((bone(ply, sd .. "_Hand") - hand):Length(), 0, 2.5, id .. ": the " .. sd .. " hand out where it balances")
            end
        end
    end
end)

T.test("contacts: on a motorbike the feet are on the pegs on the balls of the feet, and the legs alike", function()
    local w = world()
    for _, id in ipairs({ "dirtbike", "emoto" }) do
        local s = scene(id)
        local ply = seat(s)
        for _ = 1, 10 do
            draw(s)
            w.E.hook.Run("PrePlayerDraw", ply)
        end
        ply:InvalidateBoneCache(); ply:SetupBones()
        local ik = s.cb.ikTargets
        local function local_(p) return s.cb:WorldToLocal(p) end
        for _, sd in ipairs({ "R", "L" }) do
            local toe = bone(ply, sd .. "_Toe0")
            T.between((toe - ik[sd:lower() .. "Foot"]):Length(), 0, 1.5, id .. ": the ball of the " .. sd .. " foot on its peg")
        end
        -- mirror images: the two knees and the two feet the same distance forward and up
        local kr, kl = local_(bone(ply, "R_Calf")), local_(bone(ply, "L_Calf"))
        T.between(math.abs(kr.x - kl.x) + math.abs(kr.z - kl.z), 0, 1.5, id .. ": the knees alike")
    end
end)

--------------------------------------------------------------------------
-- THE SKATES STAND ON THE GROUND
--------------------------------------------------------------------------

T.test("contacts: the skates' wheels are on the floor, standing, striding, and however deep the knees", function()
    local w = world()
    local E = w.E
    local S = E.BMX.Skates
    local me = w.cl:player("Skater")
    me:SetPos(E.Vector(-400, 0, w.sv.world.groundZ))
    -- The suite's skeleton hangs from the player's ORIGIN (it is a seated rig); a
    -- standing player's hips are a leg's length up, so the rig is hung there, from a
    -- stand-in seat facing +x (lib/gmod.lua seats an occupant down the seat's +y).
    local hips = w.cl.makeEntity("prop_physics")
    hips:SetPos(me:GetPos() + E.Vector(0, 0, 34))
    hips:SetAngles(E.Angle(0, -90, 0))
    me._vehicle = hips
    me.GetPos = function() return E.Vector(-400, 0, w.sv.world.groundZ) end   -- still standing on the floor
    me:SetNWString("BMXWorn", "skates")
    w.cl.eyePos = me:GetPos() + E.Vector(100, 0, 40)
    local radius = E.BMX.ConfigFor(E.BMX.Vehicles[S.ID]).Wheel.radius
    local function wheelsLow()
        local low = {}
        me:InvalidateBoneCache(); me:SetupBones()
        for _, sd in ipairs({ "R", "L" }) do
            local ankle = bone(me, sd .. "_Foot")
            -- where cl_skates.lua hangs the boot: 2.6 under the ankle, its wheels under that
            local fr = S.BootFrame(E.Vector(ankle.x, ankle.y, ankle.z - 2.6), 0, radius)
            low[sd] = fr.wheels[1].z - radius
        end
        return low
    end
    for _, case in ipairs({ { phase = -1, speed = 0, what = "standing" }, { phase = 0.2, speed = 0, what = "mid-stride" },
                            { phase = -1, speed = 400, what = "fast, knees deep" } }) do
        me:SetNWFloat("BMXSkatePhase", case.phase)
        me:SetNWInt("BMXSkateFoot", 1)
        me._vel = E.Vector(case.speed, 0, 0)
        for _ = 1, 12 do E.hook.Run("PrePlayerDraw", me) end
        local low = wheelsLow()
        for _, sd in ipairs({ "R", "L" }) do
            local lift = (case.phase > 0 and sd == "L") and S.StrideFoot.lift * S.StrideSwing(case.phase) or 0
            T.between(low[sd] - w.sv.world.groundZ, lift - 0.3, lift + 0.3, case.what .. ": the " .. sd .. " skate's wheels on the floor")
        end
    end
    me:SetNWString("BMXWorn", "")
    E.hook.Run("PrePlayerDraw", me)
end)

-- A MODEL BUILD MUST GIVE ITS GARBAGE BACK. One build is 100-250 MB of short-lived
-- tables; a client that carried each build's heap into the next aborted at the
-- 32-bit address-space ceiling after about ten vehicle kinds (2026-10-08). After a
-- build completes, the heap is back near where it started.
T.test("memory: building a vehicle's model leaves the Lua heap where it was", function()
    local w = world()
    local s = scene("dirtbike")
    w.E.BMX.BikeMesh.Clear()          -- built afresh, not taken from an earlier test
    collectgarbage("collect")
    local before = collectgarbage("count") / 1024
    for _ = 1, 8000 do
        draw(s)
        if model(s) then break end
    end
    T.ok(model(s), "the dirt bike's model was built")
    local after = collectgarbage("count") / 1024
    T.ok(after - before < 40, string.format("heap %.0f MB -> %.0f MB after the build (a build is ~200 MB of garbage)", before, after))
end)
