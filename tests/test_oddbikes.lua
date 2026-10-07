--[[--------------------------------------------------------------------------
    The penny-farthing, the tandem and the downhill bike (G13). The unicycle is
    tests/test_unicycle.lua; the rack and the lock are tests/test_rack_lock.lua.

    PENNY. Two wheels of 26 and 6 units, the cranks on the big one (`front-direct`), the
    rider high up, and the header: a hard front brake at speed takes the whole thing over
    the bars. That is the physics of the plant; the rule (sv_penny.lua) is only what calls
    it a crash.

    TANDEM. Two seats, both pedalling: the pedal drive's torque is the sum of the two
    riders', the front rider steers, and the stoker's keys are read for nothing else.

    DH. The stock bike with more travel, bigger tyres and a heavier frame, and nothing new
    in the code: long travel is a spring, a damper and a stepMax, and what it does on a drop
    is the plant's to say.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local gmod = require("lib.gmod")
local IN = gmod.IN

local function classOf(sv, id) return sv.env.BMX.ClassFor(id) end

local function ridden(id)
    local sv, world = F.server()
    local B = sv.env.BMX
    local cfg = B.ConfigFor(B.Bikes[id])
    local bike = F.bike(sv, classOf(sv, id), sv.env.Vector(0, 0, sv.world.groundZ + B.RestHeight(cfg)))
    local ply = F.scripted(sv, bike)
    sv:run(0.5)
    return sv, bike, ply, world
end

local MPH = 17.6          -- u/s

-- How far the yaw has turned, -180..180 (the engine's angles wrap).
local function turned(a, b)
    local d = (b - a) % 360
    if d > 180 then d = d - 360 end
    return d
end

--------------------------------------------------------------------------
-- The penny-farthing
--------------------------------------------------------------------------

T.test("penny: it registers clean: a 26-unit front wheel that drives, a 6-unit rear, the header's balance", function()
    local sv = F.server()
    local B = sv.env.BMX
    local d = B.Bikes.penny
    T.ok(d, "registered")
    T.eq(#sv.errors, 0, "nothing rejected: " .. table.concat(sv.errors, " | "))
    local wheels = B.WheelDefs(d, B.ConfigFor(d))
    T.eq(#wheels, 2, "two wheels")
    T.eq(wheels[1].name, "front", "the front first")
    T.ok(wheels[1].drive and not wheels[2].drive, "the FRONT one is the drive wheel")
    T.eq(wheels[1].steer, "fork", "and the fork steers it")
    T.eq(wheels[2].radius, 6, "the rear wheel is 6 units across the radius")
    local cfg = B.ConfigFor(d)
    T.eq(cfg.Wheel.radius, 26, "the front wheel is 26")
    T.eq(cfg.Wheel.rearRadius, 6, "the rear radius is in the config for the hull")
    T.near(wheels[2].pos.z, -20, 1e-9, "the rear axle is the difference lower")
    T.eq(d.drive.kind, "front-direct", "the front-direct drive")
    T.eq(d.balance, "pennyfarthing", "its own balance mode")
    T.ok(B.BalanceModes.pennyfarthing and B.Drives["front-direct"], "which have code")
    T.eq(d.input, "penny", "its own map")
    T.ok(B.InputMaps.penny.actions.brakeFront, "with a front brake")
    T.eq(B.ClassFor("penny"), "bmx_penny", "its class")
    T.eq(sv.lists.SpawnableEntities.bmx_penny.Subcategory, "Bikes", "in the spawn menu under Bikes")
    T.ok(cfg.Chassis.massCenterExpected.z + cfg.Wheel.radius > 55, "the mass centre is high: " .. (cfg.Chassis.massCenterExpected.z + cfg.Wheel.radius))
end)

T.test("penny: a rear wheel of its own size: the hull is built from it, the flywheel scales with it", function()
    local sv, e = ridden("penny")
    local B = sv.env.BMX
    local C = e:Cfg()
    local boxes = B.CollisionBoxes(C)
    -- the two wheel boxes: 52 across for the big one, 12 for the small
    local widths = {}
    for _, b in ipairs(boxes) do widths[#widths + 1] = math.floor((b[2].x - b[1].x) + 0.5) end
    local has52, has12 = false, false
    for _, w in ipairs(widths) do if w == 52 then has52 = true end if w == 12 then has12 = true end end
    T.ok(has52 and has12, "a 52-wide box and a 12-wide one: " .. table.concat(widths, ","))
    local mc = e:GetPhysicsObject():GetMassCenter()
    T.near(mc.x, C.Chassis.massCenterExpected.x, 0.5, "mass centre x")
    T.near(mc.z, C.Chassis.massCenterExpected.z, 0.5, "mass centre z")
    local f, r = e.wheels[1], e.wheels[2]
    local big = f:WheelConfig(C).inertia
    local small = r:WheelConfig(C).inertia
    T.near(small, big * (6 / 26) ^ 2, 1e-6, "the small wheel's inertia is the big one's x (6/26)^2")
    T.ok(f.onGround and r.onGround, "both wheels on the ground at rest")
    T.ok(math.abs(math.deg(e.st.pitch)) < 3, "and it stands about level: " .. math.deg(e.st.pitch))
end)

T.test("penny: it pedals up to a penny-farthing's top speed with its legs on the big wheel, and the rider is high up", function()
    local sv, e, ply = ridden("penny")
    F.input(e, { throttle = 1 })
    sv:run(15, function() return e.st.speed > 262 end)
    T.ok(e.st.speed > 262, "15 mph is reachable: " .. e.st.speed)
    T.ok(sv.env.IsValid(e:GetDriver()), "aboard")
    -- the DRIVE wheel is the front one: its rate follows the speed, the rear free
    local f, r = e.wheels[1], e.wheels[2]
    T.near(f.omega * 26, e.st.fwdSpeed, 40, "the big wheel turns with the ground")
    T.ok(r.omega * 6 > 0, "and the small one rolls")
    T.ok(e:GetPod():GetPos().z - e:GetPos().z > 30 or e:Cfg().Chassis.seatOffset.z > 30, "the saddle is over the big wheel")
    T.ok(math.abs(e.st.roll) < math.rad(5), "upright")
end)

T.test("penny: it leans and steers like a bike", function()
    local sv, e = ridden("penny")
    F.input(e, { throttle = 1 })
    sv:run(15, function() return e.st.speed > 150 end)
    local y0 = e:GetAngles().y
    F.input(e, { throttle = 0.4, lean = 1 })
    sv:run(1.2)
    local dy = turned(y0, e:GetAngles().y)
    T.ok(dy < -15, "D turns it right (yaw falls): " .. dy)
    T.ok(sv.env.IsValid(e:GetDriver()), "and it stays up")
end)

-- The header, as its own test of the claim in the goal.
local function header(brake, speed)
    local sv, e, ply = ridden("penny")
    local E = sv.env
    F.input(e, { throttle = 1 })
    sv:run(25, function() return e.st.speed > speed end)
    local why, thrown = nil, nil
    E.hook.Add("BMX_Crashed", "t", function(b, p, reason, sev) why = reason end)
    E.hook.Add("BMX_RiderCrashed", "t", function(p, throw, b) thrown = { p = p, v = throw, fwd = b:GetForward() } return true end)
    local v0 = e.st.speed
    F.input(e, { brakeFront = brake })
    local t = 0
    for i = 1, 3 * 66 do
        sv:run(1 / 66)
        t = i / 66
        if not E.IsValid(e:GetDriver()) then break end
    end
    return sv, e, ply, why, thrown, v0, t
end

T.test("penny_header: full front brake at 15 mph takes the rider over the bars, forward, as a header", function()
    local sv, e, ply, why, thrown, v0, t = header(1, 262)
    T.ok(v0 >= 260, "at 15 mph: " .. v0)
    T.ok(not sv.env.IsValid(e:GetDriver()), "the rider is off")
    T.eq(why, "header", "the crash is a header")
    T.ok(thrown, "BMX_RiderCrashed fired")
    T.ok(thrown.p == ply, "for the rider")
    T.ok(thrown.v:Dot(thrown.fwd) > v0 * 0.6 + 100, "thrown FORWARD, over the bars, faster than the bike was going: " .. thrown.v:Dot(thrown.fwd))
    T.ok(thrown.v.z > 0, "and up")
    T.ok(t < 1.5, "in under a second and a half: " .. t)
end)

T.test("penny_header: the back wheel is off the ground before it goes: that is the physics, not a script", function()
    local sv, e = ridden("penny")
    F.input(e, { throttle = 1 })
    sv:run(25, function() return e.st.speed > 262 end)
    local rearLoadBefore = e.wheels[2].load
    F.input(e, { brakeFront = 1 })
    local lifted
    for i = 1, 60 do
        sv:run(1 / 66)
        if sv.env.IsValid(e:GetDriver()) and e.wheels[2].load <= 0 then lifted = true break end
        if not sv.env.IsValid(e:GetDriver()) then break end
    end
    T.ok(lifted, "the rear wheel carried nothing under hard braking")
    T.ok(e.st.pitch < 0, "the nose is down: " .. math.deg(e.st.pitch))
end)

T.test("penny_header: half a pull, or a hard pull at walking pace, is not a header", function()
    local sv, e = header(0.35, 240)
    T.ok(sv.env.IsValid(e:GetDriver()), "half a pull: still aboard")
    local sv2, e2 = ridden("penny")
    F.input(e2, { throttle = 1 })
    sv2:run(10, function() return e2.st.speed > 50 end)
    F.input(e2, { brakeFront = 1 })
    sv2:run(3)
    T.ok(sv2.env.IsValid(e2:GetDriver()), "full brake from 3 mph: aboard")
    T.ok(e2.st.speed < 5, "and stopped: " .. e2.st.speed)
end)

T.test("penny_header: a bike with a front brake does not do it: the BMX stoppie from 15 mph is held", function()
    local sv, e = ridden("stock")
    F.input(e, { throttle = 1 })
    sv:run(15, function() return e.st.speed > 262 end)
    F.input(e, { brakeFront = 1 })
    local why
    sv.env.hook.Add("BMX_Crashed", "t", function(b, p, reason) why = reason end)
    sv:run(2)
    T.ok(why ~= "header", "no header on a BMX")
end)

T.test("penny: the header rule's three conditions, and nothing else", function()
    local sv, e = ridden("penny")
    local B = sv.env.BMX
    local C = e:Cfg()
    local st = { speed = 200, pitch = -math.rad(20) }
    T.ok(B.Penny.IsHeader(C, { brakeFront = 1 }, st), "hard, fast, nose down")
    T.ok(not B.Penny.IsHeader(C, { brakeFront = 0.3 }, st), "a gentle brake")
    T.ok(not B.Penny.IsHeader(C, { brakeFront = 1 }, { speed = 40, pitch = st.pitch }), "walking pace")
    T.ok(not B.Penny.IsHeader(C, { brakeFront = 1 }, { speed = 200, pitch = -math.rad(5) }), "nose not down")
end)

T.test("penny: the front brake is LMB on its map, and the keys are the right ones", function()
    local sv = F.server()
    local B = sv.env.BMX
    local map = B.InputMaps.penny
    T.eq(map.actions.brakeFront.key, IN.ATTACK, "LMB")
    T.eq(map.actions.forward.key, IN.FORWARD, "W")
    T.ok(not map.actions.weightBack, "no wheelie key")
end)

T.test("penny: bmx_spawn penny spawns it, built, and respects bmx_allow_bikes", function()
    local sv = F.server()
    local ply = sv:player("Spawner")
    ply:SetPos(sv.env.Vector(0, 0, 0))
    ply._eyeTrace = { Hit = true, HitPos = sv.env.Vector(100, 0, 0), HitNormal = sv.env.Vector(0, 0, 1) }
    sv:command("bmx_spawn", ply, "penny")
    local found = sv.env.ents.FindByClass("bmx_penny")
    T.eq(#found, 1, "one")
    T.ok(found[1]:AssertBuilt(), "built")
    sv.env.GetConVar("bmx_allow_bikes"):SetString("0")
    sv.world.time = sv.world.time + 2
    sv:command("bmx_spawn", ply, "penny")
    T.eq(#sv.env.ents.FindByClass("bmx_penny"), 1, "switched off: no second")
end)

T.test("penny: it is drawn: a big wheel and a small one, cranks on the big hub, hands on the bars", function()
    local sv, world = F.server()
    local bike = F.bike(sv, classOf(sv, "penny"))
    local cl = F.client(world)
    local cb = cl:clientEntity("bmx_penny")
    cb:SetPos(bike:GetPos())
    cb:SetAngles(bike:GetAngles())
    for k, v in pairs(bike._nw) do cb._nw[k] = v end
    cl.lines, cl.beams, cl.drawnModels, cl.boxes3d = 0, {}, 0, 0
    cl.drawnCS = {}
    cb:Draw()
    T.ok(cb.ikTargets and cb.ikTargets.rFoot and cb.ikTargets.rHand, "feet and hands are recorded")
    -- the feet are on the BIG hub's pedal circle: within a crank's reach of the front axle
    local hubZ = bike:GetPos().z + 0
    local front = bike:LocalToWorld(sv.env.Vector(bike:Cfg().Wheel.wheelbase * 0.5, 0, 0))
    T.ok((cb.ikTargets.rFoot - front):Length() < 14, "the right foot is at the front hub: " .. (cb.ikTargets.rFoot - front):Length())
    T.ok(cb.ikTargets.rHand.z > front.z + 20, "and the hands are high over it: " .. (cb.ikTargets.rHand.z - front.z))
    T.ok(#cl.beams + (cl.drawnModels or 0) + #(cl.drawnCS or {}) > 10, "something was drawn")
end)

--------------------------------------------------------------------------
-- The tandem
--------------------------------------------------------------------------

local function board(sv, bike, name)
    local p = sv:player(name or "Stoker")
    p._eyeTrace = { Hit = true, Entity = bike, HitPos = bike:LocalToWorld(sv.env.Vector(-30, 0, 8)) }
    bike:Use(p)
    return p
end

T.test("tandem: it registers clean: two seats, the second one pedals, the front one steers", function()
    local sv = F.server()
    local B = sv.env.BMX
    local d = B.Bikes.tandem
    T.ok(d, "registered")
    T.eq(#sv.errors, 0, "nothing rejected: " .. table.concat(sv.errors, " | "))
    local cfg = B.ConfigFor(d)
    local cap, stk = B.SeatFor(d, cfg, "rider"), B.SeatFor(d, cfg, "pegs")
    T.ok(cap and stk, "two seats")
    T.eq(cap.pedals, true, "the captain pedals")
    T.eq(stk.pedals, true, "and the stoker")
    T.ok(stk.offset.x < cap.offset.x - 20, "the stoker is behind, far enough for a frame between: " .. (cap.offset.x - stk.offset.x))
    T.near(stk.massFactor, 0.6, 1e-9, "the stoker weighs 0.6 of the bike's mass")
    T.ok(not B.HasSeat(d, "child"), "no child seat")
    T.ok(cfg.Wheel.wheelbase > 1.5 * B.Config.Wheel.wheelbase, "a long frame: " .. cfg.Wheel.wheelbase)
    T.eq(d.drawer, nil, "drawn as a bike: no drawer of its own")
    T.eq(d.look, "tandem", "its model (cl_geo_odd.lua), through DrawDetailed")
    T.eq(sv.lists.SpawnableEntities.bmx_tandem.Subcategory, "Bikes", "in the spawn menu under Bikes")
end)

T.test("tandem: a seat that does not pedal adds nothing: the BMX's pegs", function()
    local sv = F.server()
    local B = sv.env.BMX
    T.ok(B.Tandem.SeatPedals(B.Bikes.tandem, B.ConfigFor(B.Bikes.tandem), "pegs"), "the tandem's stoker")
    T.ok(not B.Tandem.SeatPedals(B.Bikes.stock, B.ConfigFor(B.Bikes.stock), "pegs"), "a BMX's pegs")
end)

-- The drive's torque with a given driver and stoker throttle, at a standstill so the
-- legs' falling curve is whole: the torque is then exactly linear in the throttle.
local function torque(sv, e, driver, stoker)
    local B = sv.env.BMX
    local w = e.wheels[2]
    w.omega = 0
    e.st.stamina = 100
    e.input.throttle, e.input.brakeRear, e.input.sprint = driver, 0, false
    e.input.paxThrottle = stoker
    return B.Drives.pedal(e, e:Cfg(), 1 / 66, e.input, e.st, w, e:Bike())
end

T.test("tandem: the torque is the SUM of the two riders'", function()
    local sv, e = ridden("tandem")
    local one = torque(sv, e, 1, 0)
    T.ok(one > 0, "the captain alone drives: " .. one)
    board(sv, e)
    T.ok(e.passengers.pegs, "the stoker is aboard")
    local both = torque(sv, e, 1, 1)
    T.near(both, 2 * one, one * 0.001, "both at full effort: twice the torque")
    local stokerOnly = torque(sv, e, 0, 1)
    T.near(stokerOnly, one, one * 0.001, "the stoker alone, the captain coasting: still one rider's torque")
    local half = torque(sv, e, 1, 0.5)
    T.near(half, 1.5 * one, one * 0.001, "analog: a captain at full and a stoker at half")
    local none = torque(sv, e, 0, 0)
    T.near(none, 0, 1e-9, "nobody pedalling: nothing")
end)

T.test("tandem: a stoker who is not on the seat adds nothing, whatever the last throttle was", function()
    local sv, e = ridden("tandem")
    local one = torque(sv, e, 1, 0)
    local p = board(sv, e)
    T.near(torque(sv, e, 1, 1), 2 * one, one * 0.001, "aboard: two")
    p:ExitVehicle()
    T.near(torque(sv, e, 1, 1), one, one * 0.001, "got off: one, with the stale throttle still on the input")
end)

T.test("tandem: the stoker's W is read from their usercmd and nothing else is", function()
    local sv, e, ply = ridden("tandem")
    local p = board(sv, e)
    p.BMXScripted = nil
    local function cmd(buttons)
        local c = { buttons = buttons or 0, fwd = 0, side = 0 }
        function c:GetButtons() return self.buttons end
        function c:GetForwardMove() return self.fwd end
        function c:GetSideMove() return self.side end
        function c:SetButtons(b) self.buttons = b end
        function c:SetForwardMove(v) self.fwd = v end
        function c:SetSideMove(v) self.side = v end
        function c:SetUpMove(v) end
        return c
    end
    e.input.leanTarget, e.input.brakeRear, e.input.brakeFront = 0, 0, 0
    sv.env.hook.Run("StartCommand", p, cmd(IN.FORWARD))
    T.eq(e.input.paxThrottle, 1, "the stoker's W is their pedalling")
    sv.env.hook.Run("StartCommand", p, cmd(0))
    T.eq(e.input.paxThrottle, 0, "and releasing it stops it")
    sv.env.hook.Run("StartCommand", p, cmd(bit and bit.bor(IN.MOVERIGHT, IN.BACK, IN.ATTACK) or (IN.MOVERIGHT + IN.BACK + IN.ATTACK)))
    T.eq(e.input.leanTarget, 0, "the stoker's A / D do not lean it: the front rider steers")
    T.eq(e.input.brakeRear, 0, "nor brake it")
    T.eq(e.input.brakeFront, 0, "nor the front")
    T.eq(e.input.paxThrottle, 0, "and S is not W")
end)

T.test("tandem: on a BMX's pegs a passenger's W does not stamp a throttle (the seat does not pedal)", function()
    local sv, e = ridden("stock")
    local p = sv:player("Pax")
    p._eyeTrace = { Hit = true, Entity = e, HitPos = e:LocalToWorld(sv.env.Vector(-16, 0, 8)) }
    e:Use(p)
    p.BMXScripted = nil
    local c = { buttons = IN.FORWARD }
    function c:GetButtons() return self.buttons end
    function c:GetForwardMove() return 0 end
    sv.env.hook.Run("StartCommand", p, c)
    T.eq(e.input.paxThrottle, nil, "nothing")
end)

T.test("tandem: with both pedalling it gets away quicker than with one, and the stoker adds weight", function()
    local speeds = {}
    for _, stoker in ipairs({ false, true }) do
        local sv, e = ridden("tandem")
        if stoker then
            local p = board(sv, e)
            p.BMXScripted = true
            e.input.paxThrottle = 1
            T.near(e.paxMass, 0.6 * 118, 0.01, "the stoker's mass")
        end
        F.input(e, { throttle = 1 })
        sv:run(2)
        speeds[#speeds + 1] = e.st.speed
        T.ok(sv.env.IsValid(e:GetDriver()), "aboard")
    end
    T.ok(speeds[2] > speeds[1] * 1.05, string.format("two riders are quicker off the line: %.0f vs %.0f", speeds[2], speeds[1]))
end)

T.test("tandem: it rides straight and steers, with both aboard", function()
    local sv, e = ridden("tandem")
    local p = board(sv, e)
    p.BMXScripted = true
    e.input.paxThrottle = 1
    F.input(e, { throttle = 1 })
    sv:run(15, function() return e.st.speed > 150 end)
    T.ok(math.abs(e.st.roll) < math.rad(4), "upright")
    local y0 = e:GetAngles().y
    F.input(e, { throttle = 0.5, lean = 1 })
    sv:run(1.5)
    T.ok(turned(y0, e:GetAngles().y) < -10, "the captain's D turns it right: " .. turned(y0, e:GetAngles().y))
    T.ok(sv.env.IsValid(e:GetDriver()) and sv.env.IsValid(e.passengers.pegs), "both aboard")
end)

-- The model's own drawing (both bottom brackets, both saddles, the stoker's hands and
-- feet through DrawDetailed's bb2 / gripS) needs a Mesh, which the shim does not have:
-- tests/test_geo_odd.lua draws it with a fake one. Without, the simple bike stands in.
T.test("tandem: it is drawn, with the simple bike standing in while there is no model", function()
    local sv, world = F.server()
    local bike = F.bike(sv, classOf(sv, "tandem"))
    local cl = F.client(world)
    local cb = cl:clientEntity("bmx_tandem")
    cb:SetPos(bike:GetPos())
    cb:SetAngles(bike:GetAngles())
    for k, v in pairs(bike._nw) do cb._nw[k] = v end
    cl.lines, cl.beams, cl.drawnModels, cl.boxes3d = 0, {}, 0, 0
    cl.drawnCS = {}
    cb:Draw()
    T.ok(cb.ikTargets and cb.ikTargets.rFoot and cb.ikTargets.rHand, "the captain's targets")
    T.ok(#cl.beams + (cl.drawnModels or 0) + #(cl.drawnCS or {}) > 10, "something was drawn")
end)

--------------------------------------------------------------------------
-- The downhill bike
--------------------------------------------------------------------------

T.test("dh: it registers clean, with more travel, bigger tyres and more weight than the BMX", function()
    local sv = F.server()
    local B = sv.env.BMX
    T.ok(B.Bikes.dh, "registered")
    T.eq(#sv.errors, 0, "nothing rejected: " .. table.concat(sv.errors, " | "))
    local dh, st = B.ConfigFor(B.Bikes.dh), B.ConfigFor(B.Bikes.stock)
    T.ok(dh.Wheel.restLength >= 2 * st.Wheel.restLength, "twice the travel: " .. dh.Wheel.restLength)
    T.ok(dh.Wheel.radius > st.Wheel.radius, "bigger wheels")
    T.ok(dh.Wheel.grip > st.Wheel.grip, "more grip")
    T.ok(dh.Chassis.mass >= 1.3 * st.Chassis.mass, "heavy: " .. dh.Chassis.mass)
    T.ok(dh.Wheel.damper > st.Wheel.damper, "a stiffer damper")
    T.eq(B.Bikes.dh.family, "bike", "a bike")
    T.eq(sv.lists.SpawnableEntities.bmx_dh.Subcategory, "Bikes", "in the spawn menu under Bikes")
    -- THE SAG MUST BE UNDER stepMax, or the spring never compresses (see the registry's note).
    local sag = dh.Chassis.mass * 600 * 0.5 / dh.Wheel.spring
    T.ok(sag < dh.Wheel.stepMax, "the sag " .. sag .. " is under the step limit " .. dh.Wheel.stepMax)
    T.ok(sag < dh.Wheel.restLength * 0.4, "and a good deal of the travel is left")
end)

T.test("dh: it rests ON ITS SPRINGS, not on its hull (the bug the step limit would have been)", function()
    local sv, e = ridden("dh")
    local C = e:Cfg()
    sv:run(1)
    for i, w in ipairs(e.wheels) do
        T.ok(w.compression > 2 and w.compression < C.Wheel.restLength * 0.5, "wheel " .. i .. " is sprung: " .. w.compression)
        T.ok(w.load > 10000, "and carries weight: " .. w.load)
    end
    T.ok(e:GetPos().z > 6, "up off its hull: " .. e:GetPos().z)
end)

T.test("dh_lands_drop: a 4 m drop at speed is soaked: more of the travel left than a BMX's, no crash, still aboard", function()
    local peak = {}
    for _, id in ipairs({ "stock", "dh" }) do
        local sv, e = ridden(id)
        local E = sv.env
        local crashed = {}
        E.hook.Add("BMX_Crashed", "t", function(b, ply, why) crashed[#crashed + 1] = why end)
        F.input(e, { throttle = 0.5 })
        sv:run(3)
        local p = e:GetPhysicsObject()
        p:SetPos(e:GetPos() + E.Vector(0, 0, 160))
        p:SetVelocity(E.Vector(150, 0, 0))
        local pc = 0
        for i = 1, 4 * 66 do
            sv:run(1 / 66)
            pc = math.max(pc, e.wheels[1].compression, e.wheels[2].compression)
        end
        T.ok(E.IsValid(e:GetDriver()), id .. ": aboard after the drop")
        T.eq(#crashed, 0, id .. ": no crash: " .. table.concat(crashed, ","))
        peak[id] = pc / e:Cfg().Wheel.restLength
    end
    T.ok(peak.stock > 0.95, "the BMX bottoms out on it: " .. peak.stock)
    T.ok(peak.dh < 0.9, "the DH does not: " .. peak.dh)
end)

T.test("dh: it gets up to speed, and is steadier at speed than the BMX when knocked", function()
    local out = {}
    for _, id in ipairs({ "stock", "dh" }) do
        local sv, e = ridden(id)
        F.input(e, { throttle = 1 })
        sv:run(30, function() return e.st.speed > 200 end)
        T.ok(e.st.speed > 200, id .. " gets to 200: " .. e.st.speed)
        F.input(e, { throttle = 0.5 })
        e:GetPhysicsObject():SetAngleVelocity(sv.env.Vector(80, 0, 0))
        local peak = 0
        for i = 1, 3 * 66 do
            sv:run(1 / 66)
            peak = math.max(peak, math.abs(e.st.roll))
        end
        T.ok(sv.env.IsValid(e:GetDriver()), id .. " aboard")
        out[id] = peak
    end
    T.ok(out.dh <= out.stock, string.format("a knock moves the DH no more than the BMX: %.2f vs %.2f deg",
        math.deg(out.dh), math.deg(out.stock)))
end)

T.test("dh: bmx_spawn dh spawns it, built, and respects bmx_allow_bikes", function()
    local sv = F.server()
    local ply = sv:player("Spawner")
    ply:SetPos(sv.env.Vector(0, 0, 0))
    ply._eyeTrace = { Hit = true, HitPos = sv.env.Vector(100, 0, 0), HitNormal = sv.env.Vector(0, 0, 1) }
    sv:command("bmx_spawn", ply, "dh")
    T.eq(#sv.env.ents.FindByClass("bmx_dh"), 1, "one")
    sv.env.GetConVar("bmx_allow_bikes"):SetString("0")
    sv.world.time = sv.world.time + 2
    sv:command("bmx_spawn", ply, "dh")
    T.eq(#sv.env.ents.FindByClass("bmx_dh"), 1, "switched off: no second")
end)
