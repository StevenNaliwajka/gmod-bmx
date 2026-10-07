--[[--------------------------------------------------------------------------
    The fixed gear (G10): the cranks locked to the rear wheel.

    What matters about a fixie is what a freewheel lets a BMX NOT do, so most of
    these compare it with the BMX on the same plant: coasting turns the cranks (and
    drags the bike back a little), S is a skid stop and not a gentle brake, LMB does
    nothing, S at a standstill rolls it backwards, and a rider rocking the cranks can
    hold it still. Each of the last two is a trick, scored.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local gmod = require("lib.gmod")
local IN = gmod.IN

local function classOf(sv, id) return sv.env.BMX.ClassFor(id) end

local function ridden(id)
    local sv, world = F.server()
    local B = sv.env.BMX
    local cfg = B.ConfigFor(B.Bikes[id])
    local pos = sv.env.Vector(0, 0, sv.world.groundZ + B.RestHeight(cfg))
    local bike = F.bike(sv, classOf(sv, id), pos)
    local ply = F.scripted(sv, bike)
    sv:run(0.5)
    return sv, bike, ply
end

--------------------------------------------------------------------------
-- The registry
--------------------------------------------------------------------------

T.test("fixie: it registers clean, as a fixed-gear bike with one brake", function()
    local sv = F.server()
    local B = sv.env.BMX
    local d = B.Bikes.fixie
    T.ok(d, "registered")
    T.eq(#sv.errors, 0, "nothing rejected: " .. table.concat(sv.errors, " | "))
    T.eq(d.family, "bike", "a bike")
    T.eq(d.drive.kind, "fixed", "a fixed drive")
    T.eq(d.input, "bike_rearonly", "no front brake on the ground")
    T.eq(B.ClassFor("fixie"), "bmx_fixie", "its class")
    T.eq(sv.lists.SpawnableEntities.bmx_fixie.Subcategory, "Bikes", "under Bikes")
    T.ok(sv.dupe.bmx_fixie, "the duplicator knows it")
    T.eq(B.ConfigFor(d).Drive.fixedGear, true, "the wheel has no freewheel floor")
    T.eq(B.Gears.Count(d), 0, "a single speed")
end)

T.test("fixie: bmx_spawn fixie spawns it, built", function()
    local sv = F.server()
    local ply = sv:player("Spawner")
    ply:SetPos(sv.env.Vector(0, 0, 0))
    ply._eyeTrace = { Hit = true, HitPos = sv.env.Vector(100, 0, 0), HitNormal = sv.env.Vector(0, 0, 1) }
    sv:command("bmx_spawn", ply, "fixie")
    local found = sv.env.ents.FindByClass("bmx_fixie")
    T.eq(#found, 1, "one")
    T.ok(found[1]:AssertBuilt(), "built")
end)

T.test("fixie: the fixed drive kind validates like the others", function()
    local sv = F.server()
    local B = sv.env.BMX
    local E = sv.env
    local function two(kind, over)
        local d = { id = "drv_" .. kind, family = "bike", printName = "x",
            wheels = { { pos = E.Vector(20, 0, 0), steer = "fork" }, { pos = E.Vector(-20, 0, 0), drive = true } },
            balance = "singletrack", drive = { kind = kind }, input = "bike", pose = "bike", tricks = "all",
            grindPoints = false }
        for k, v in pairs(over or {}) do d[k] = v end
        return d
    end
    T.ok(B.RegisterVehicle(two("fixed")), "fixed accepted")
    T.eq(#sv.errors, 0, table.concat(sv.errors, " | "))
    local d = two("fixed", { id = "drv_nodrive" })
    d.wheels[2].drive = false
    T.eq(B.RegisterVehicle(d), false, "a fixed drive needs a drive wheel")
    T.ok(sv.errors[1]:find("drive = true", 1, true), "and says so: " .. tostring(sv.errors[1]))
    sv.errors = {}
    T.eq(B.RegisterVehicle(two("fixed", { id = "drv_extra", drive = { kind = "fixed", torque = 5 } })), false,
        "a fixed drive takes no torque key")
end)

--------------------------------------------------------------------------
-- No freewheel
--------------------------------------------------------------------------

T.test("fixie: coasting, the cranks stay locked to the rear wheel and keep turning", function()
    local sv, e = ridden("fixie")
    local B = sv.env.BMX
    F.accelerateTo(sv, e, 200)
    F.input(e, {})                       -- stop pedalling
    local _, r = F.wheels(e)
    local ratio = B.GearRatio(e, e:Cfg())
    local worst, turned, a0 = 0, 0, e.st.crankA
    sv:run(3, function()
        worst = math.max(worst, math.abs(e.st.crankA - r.spinAngle))
        return false
    end)
    turned = (e.st.crankA - a0) / ratio
    T.ok(e.st.speed > 60, "still rolling: " .. e.st.speed)
    T.ok(turned > 6, string.format("the cranks turned %.1f rad while it coasted", turned))
    T.ok(worst < 0.2, string.format("and never more than %.3f rad (wheel space) from the wheel", worst))
    -- The angle the client draws is the wheel's over the ratio: the same thing.
    T.near(B.Fixie.CrankAngle(e.st, ratio), B.Fixie.LockedAngle(r, ratio), 0.2 / ratio, "crank angle = wheel angle / ratio")
end)

T.test("fixie: a BMX has no crank state at all: its legs are not on the wheel", function()
    local sv, e = ridden("stock")
    F.accelerateTo(sv, e, 150)
    F.input(e, {})
    sv:run(1)
    T.eq(e.st.crankA, nil, "no crank")
end)

T.test("fixie: coasting, the legs drag the bike down more than a BMX's freewheel does", function()
    local drop = {}
    for _, id in ipairs({ "stock", "fixie" }) do
        local sv, e = ridden(id)
        F.accelerateTo(sv, e, 220)
        local v0 = e.st.speed
        F.input(e, {})
        sv:run(3)
        drop[id] = (v0 - e.st.speed) / v0
    end
    T.ok(drop.fixie > drop.stock * 1.15, string.format("lost %.0f%% against the BMX's %.0f%% in 3 s", drop.fixie * 100, drop.stock * 100))
    T.ok(drop.fixie < 0.5, "but it is a nuisance, not a brake: " .. drop.fixie)
end)

T.test("fixie: it still pedals up to speed, and the legs do not blow up the integration", function()
    local sv, e = ridden("fixie")
    local peak = 0
    F.input(e, { throttle = 1 })
    sv:run(14, function() peak = math.max(peak, e.st.speed) return false end)
    T.between(peak, 250, 520, "top speed")
    T.ok(sv.env.BMX.Finite(e.st.crankA) and sv.env.BMX.Finite(e.st.crankW), "finite crank state")
    T.eq(#sv.errors, 0, table.concat(sv.errors, " | "))
end)

T.test("fixie: the drive is stable at any step, even a stalled server's", function()
    local sv, e = ridden("fixie")
    local B = sv.env.BMX
    local _, r = F.wheels(e)
    local st = e.st
    local inp = e.input
    for _, dt in ipairs({ 1 / 200, 1 / 66, 1 / 20, 0.2 }) do
        st.crankA, st.crankW = nil, nil
        r.omega, r.spinAngle = 25, 0
        inp.throttle = 1
        for _ = 1, 200 do
            local tq = B.Drives.fixed(e, e:Cfg(), dt, inp, st, r, e:Bike())
            T.finite(tq, "torque at dt " .. dt)
            r.omega = r.omega + tq / r:WheelConfig(e:Cfg()).inertia * dt
            r.spinAngle = r.spinAngle + r.omega * dt
        end
        T.finite(st.crankW, "crank speed at dt " .. dt)
        T.ok(math.abs(st.crankA - r.spinAngle) < 5, "and the legs stayed with the wheel at dt " .. dt)
    end
end)

--------------------------------------------------------------------------
-- Skid stop
--------------------------------------------------------------------------

T.test("fixie: S from 15 mph is a skid stop in under 8 m, with the tyre skidding", function()
    local sv, e = ridden("fixie")
    local mph15 = 15 * 17.6                  -- u/s
    F.accelerateTo(sv, e, mph15)
    F.input(e, {})
    local x0 = e:GetPos()
    local skid = false
    F.input(e, { brakeRear = 1 })
    sv:run(5, function()
        skid = skid or e:GetSkidding()
        return e.st.speed < 5
    end)
    local dist = (e:GetPos() - x0):Length()
    T.ok(e.st.speed < 5, "it stopped: " .. e.st.speed)
    T.ok(dist < 8 * 39.37, string.format("in %.1f m", dist / 39.37))
    T.ok(skid, "and the skid was networked")
    T.ok(sv.env.IsValid(e:GetDriver()), "with the rider still aboard")
end)

T.test("fixie: the skid is not mistaken for pedalling backwards: the brake is held at speed", function()
    local sv, e = ridden("fixie")
    F.accelerateTo(sv, e, 200)
    F.input(e, { brakeRear = 1 })
    sv:run(0.5)
    local _, r = F.wheels(e)
    T.ok(e.st.speed < 200, "slowing already")
    T.ok(r.omega < 21 or e:GetSkidding(), "the rear wheel is held, not freewheeling: " .. r.omega)
end)

--------------------------------------------------------------------------
-- LMB does nothing
--------------------------------------------------------------------------

local function cmd(buttons)
    local c = { buttons = buttons or 0, fwd = 0, side = 0, up = 0 }
    function c:GetButtons() return self.buttons end
    function c:SetButtons(b) self.buttons = b end
    function c:GetForwardMove() return self.fwd end
    function c:GetSideMove() return self.side end
    function c:SetForwardMove(v) self.fwd = v end
    function c:SetSideMove(v) self.side = v end
    function c:SetUpMove(v) self.up = v end
    return c
end

local function realRider(id)
    local sv = F.server()
    local B = sv.env.BMX
    local e = F.bike(sv, classOf(sv, id))
    local ply = F.rider(sv, e)
    return sv, e, function(buttons)
        sv.env.hook.Run("StartCommand", ply, cmd(buttons))
    end
end

T.test("fixie: LMB does nothing on the ground; on a BMX it is the front brake", function()
    local _, bmx, bsend = realRider("stock")
    bsend(IN.ATTACK)
    T.eq(bmx.input.brakeFront, 1, "the BMX brakes")
    local _, fix, fsend = realRider("fixie")
    fsend(IN.ATTACK)
    T.eq(fix.input.brakeFront, 0, "the fixie does not")
    T.eq(fix.input.pitchTarget, 0, "and the weight does not go forward")
    fsend(IN.BACK)
    T.eq(fix.input.brakeRear, 1, "S is still the brake")
end)

T.test("fixie: bmx_fixie_frontbrake 1 gives the front brake back", function()
    local sv, fix, send = realRider("fixie")
    T.eq(sv.env.GetConVar("bmx_fixie_frontbrake"):GetInt(), 0, "off by default")
    sv.env.GetConVar("bmx_fixie_frontbrake"):SetString("1")
    send(IN.ATTACK)
    T.eq(fix.input.brakeFront, 1, "it brakes")
end)

--------------------------------------------------------------------------
-- Fakie and trackstand
--------------------------------------------------------------------------

T.test("fixie: S at a standstill pedals backwards and the bike rolls back", function()
    local sv, e = ridden("fixie")
    F.input(e, { brakeRear = 1 })
    sv:run(3)
    T.ok(e.st.fwdSpeed < -15, "rolling back: " .. e.st.fwdSpeed)
    T.ok(e.st.speed < 60, "at walking pace: " .. e.st.speed)
    T.ok(sv.env.IsValid(e:GetDriver()), "still aboard")
    T.ok(math.abs(e.st.roll) < math.rad(15), "and upright")
end)

T.test("fixie: riding fakie is a trick, scored per second, and only on a fixie", function()
    local sv, e = ridden("fixie")
    local B = sv.env.BMX
    T.ok(B.Tricks.fakie and B.Tricks.fakie.points > 0, "it is registered with a value")
    local names = {}
    sv.env.hook.Add("BMX_TrickLanded", "t", function(ply, t) names[#names + 1] = t.name end)
    F.input(e, { brakeRear = 1 })
    sv:run(5)
    T.ok(e:GetScore() >= B.Tricks.fakie.points, "scored: " .. e:GetScore())
    T.eq(names[1], "Fakie", "under its name")
    local sv2, b = ridden("stock")
    F.input(b, { brakeRear = 1 })
    sv2:run(5)
    T.eq(b:GetScore(), 0, "a BMX paddling back is not doing one")
end)

T.test("fixie: a trackstand is held at a standstill with A or D, and scored per second", function()
    local sv, e = ridden("fixie")
    local B = sv.env.BMX
    T.ok(B.Tricks.trackstand and B.Tricks.trackstand.points > 0, "it is registered with a value")
    F.input(e, { lean = 1 })
    sv:run(0.6)
    T.eq(e:GetScore(), 0, "not paid before the first second")
    sv:run(2.2)
    T.ok(e:GetScore() >= 2 * B.Tricks.trackstand.points, "two seconds paid: " .. e:GetScore())
    T.ok(e.st.speed < 12, "and it stayed put: " .. e.st.speed)
    -- Letting go ends it.
    local s = e:GetScore()
    F.input(e, {})
    sv:run(2)
    T.eq(e:GetScore(), s, "nothing more once the keys are up")
    local sv2, b = ridden("stock")
    F.input(b, { lean = 1 })
    sv2:run(3)
    T.eq(b:GetScore(), 0, "and the BMX's rider holding D at a standstill is not doing a trackstand")
end)

T.test("fixie: moving, the trackstand clock is not running", function()
    local sv, e = ridden("fixie")
    F.accelerateTo(sv, e, 120)
    F.input(e, { lean = 1, throttle = 0.5 })
    sv:run(2)
    T.ok(not sv.env.BMX.Fixie.Running("trackstand", e.st, e.input), "not at a standstill")
end)

T.test("fixie: the freewheel tick is silent on a fixie", function()
    local sv, world = F.server()
    local cl = F.client(world)
    local cb = cl:clientEntity("bmx_fixie")
    T.eq(cb:Bike().drive.kind, "fixed", "the client knows it is a fixed gear")
end)
