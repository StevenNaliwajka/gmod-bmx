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

