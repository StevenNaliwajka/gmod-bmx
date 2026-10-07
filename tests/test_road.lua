--[[--------------------------------------------------------------------------
    The road bike and the gear model (G09).

    The road bike is the first vehicle with a `gears` registry field, so most of
    what is checked here is the field: that it is validated like every other, that
    the gear model keeps the legs' cadence in a sane band in SOME gear at every
    speed, that shifting is the server's decision, and that the drive actually
    runs on the current gear's ratio. Then the bike itself on the offline plant:
    fast, long, light, x1.5 on a trick.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local gmod = require("lib.gmod")

local function classOf(sv, id) return sv.env.BMX.ClassFor(id) end

local function ridden(id, gear)
    local sv, world = F.server()
    local B = sv.env.BMX
    local cfg = B.ConfigFor(B.Bikes[id])
    local pos = sv.env.Vector(0, 0, sv.world.groundZ + B.RestHeight(cfg))
    local bike = F.bike(sv, classOf(sv, id), pos)
    local ply = F.scripted(sv, bike)
    sv:run(0.5)
    if gear then B.SetGear(bike, gear) end
    return sv, bike, ply, world
end

-- The fastest a bike gets with the throttle held, in 25 s, and the crank speed
-- (rpm) it was doing at that moment.
local function topSpeed(id, gear)
    local sv, bike = ridden(id, gear)
    F.input(bike, { throttle = 1 })
    local peak, rpm = 0, 0
    sv:run(25, function()
        if bike.st.speed > peak then peak, rpm = bike.st.speed, bike.st.cadence * 60 / (2 * math.pi) end
        return false
    end)
    return peak, rpm, bike, sv
end

--------------------------------------------------------------------------
-- The registry
--------------------------------------------------------------------------

T.test("road: it registers clean, as a bike, with its own class, row and name", function()
    local sv = F.server()
    local B = sv.env.BMX
    local d = B.Bikes.road
    T.ok(d, "registered")
    T.eq(#sv.errors, 0, "nothing rejected: " .. table.concat(sv.errors, " | "))
    T.eq(d.family, "bike", "a bike")
    T.eq(B.ClassFor("road"), "bmx_road", "its class")
    local row = sv.lists.SpawnableEntities.bmx_road
    T.ok(row, "a spawn menu row")
    T.eq(row.Subcategory, "Bikes", "under Bikes")
    T.eq(row.PrintName, "Road Bike", "named")
    T.ok(sv.dupe.bmx_road, "the duplicator knows it")
    T.eq(d.balance, "singletrack", "it balances like a bike")
    T.eq(d.input, "road", "reads the road map")
    T.eq(d.pose, "road", "has the tucked pose")
    T.eq(d.barStyle, "drop", "drop bars")
    T.eq(d.scoreMult, 1.5, "tricks score x1.5")
    T.ok(d.tricks == "all", "and tricks are allowed")
end)

T.test("road: bmx_spawn road spawns it at its own rest height", function()
    local sv = F.server()
    local ply = sv:player("Spawner")
    ply:SetPos(sv.env.Vector(0, 0, 0))
    ply._eyeTrace = { Hit = true, HitPos = sv.env.Vector(100, 0, 0), HitNormal = sv.env.Vector(0, 0, 1) }
    sv:command("bmx_spawn", ply, "road")
    local found = sv.env.ents.FindByClass("bmx_road")
    T.eq(#found, 1, "one road bike")
    T.ok(found[1]:AssertBuilt(), "built")
    T.near(found[1]:GetPos().z, sv.env.BMX.RestHeight(found[1]:Cfg()) + 0.5, 0.01, "at rest, not dropped")
end)

T.test("road: 700c wheels, a long light frame, narrow grippy tyres", function()
    local sv = F.server()
    local B = sv.env.BMX
    local r, s = B.ConfigFor(B.Bikes.road), B.ConfigFor(B.Bikes.stock)
    T.ok(r.Wheel.radius > 13.5 and r.Wheel.radius < 14.2, "700c: ~13.8 u radius, " .. r.Wheel.radius)
    T.ok(r.Wheel.wheelbase > s.Wheel.wheelbase * 1.15, "a long wheelbase")
    T.ok(r.Chassis.mass < s.Chassis.mass, "lighter than the BMX")
    T.ok(r.Wheel.grip > s.Wheel.grip, "more grip")
    T.ok(r.Wheel.rollingResistance < s.Wheel.rollingResistance, "less rolling loss")
    T.ok(r.Hop.popSpeed < s.Hop.popSpeed, "poor on jumps")
    T.ok(r.Balance.leanKp > s.Balance.leanKp and r.Balance.fadeInHigh < s.Balance.fadeInHigh,
        "the lean, and so the steer, is answered sooner at speed")
    local k = r.Wheel.wheelbase / 39
    T.near(r.Chassis.seatOffset.x, s.Chassis.seatOffset.x * k, 0.1, "the seat scales with the frame")
    T.near(r.Chassis.seatOffset.z, s.Chassis.seatOffset.z * k, 0.1, "...in height too")
end)

--------------------------------------------------------------------------
-- The gears field: validated like everything else in the registry
--------------------------------------------------------------------------

local function bike(over)
    local d = { printName = "G test", gears = { ratios = { 1.5, 2, 2.5 }, start = 2 } }
    for k, v in pairs(over or {}) do d[k] = v end
    return d
end

T.test("gears: a good field is accepted, and a bike without one is single-speed", function()
    local sv = F.server()
    local B = sv.env.BMX
    T.ok(B.RegisterBike("gearok", bike()), "accepted")
    T.eq(#sv.errors, 0, table.concat(sv.errors, " | "))
    T.eq(B.Gears.Count(B.Bikes.gearok), 3, "three gears")
    T.eq(B.Gears.Count(B.Bikes.stock), 0, "the BMX has none")
    T.ok(B.RegisterBike("gearmin", bike({ gears = { ratios = { 2, 3 } } })), "two gears is the least")
    local eleven = {}
    for i = 1, 11 do eleven[i] = 1 + i * 0.2 end
    T.ok(B.RegisterBike("gearmax", bike({ gears = { ratios = eleven, start = 11 } })), "eleven is the most")
end)

local BAD = {
    { "a single ratio",        function(d) d.gears = { ratios = { 2 } } end,                    "2 to 11" },
    { "twelve ratios",         function(d) local r = {} for i = 1, 12 do r[i] = i end d.gears = { ratios = r } end, "2 to 11" },
    { "no ratios",             function(d) d.gears = { start = 1 } end,                         "ratios" },
    { "ratios out of order",   function(d) d.gears = { ratios = { 2, 1.5, 3 } } end,            "rise" },
    { "equal ratios",          function(d) d.gears = { ratios = { 2, 2, 3 } } end,              "rise" },
    { "a ratio of zero",       function(d) d.gears = { ratios = { 0, 2 } } end,                 "above 0" },
    { "a ratio that is text",  function(d) d.gears = { ratios = { 2, "3" } } end,               "above 0" },
    { "an absurd ratio",       function(d) d.gears = { ratios = { 2, 40 } } end,                "under 20" },
    { "a start past the box",  function(d) d.gears = { ratios = { 1, 2, 3 }, start = 4 } end,   "start" },
    { "a start of zero",       function(d) d.gears = { ratios = { 1, 2, 3 }, start = 0 } end,   "start" },
    { "a fractional start",    function(d) d.gears = { ratios = { 1, 2, 3 }, start = 1.5 } end, "start" },
    { "an unknown key",        function(d) d.gears = { ratios = { 1, 2 }, cogs = 9 } end,       "cogs" },
    { "gears that are a number", function(d) d.gears = 8 end,                                  "gears" },
    { "a bad bar style",       function(d) d.barStyle = "ape-hanger" end,                       "barStyle" },
    { "a score multiplier of 0", function(d) d.scoreMult = 0 end,                              "scoreMult" },
    { "a score multiplier of text", function(d) d.scoreMult = "x2" end,                        "scoreMult" },
}
for _, c in ipairs(BAD) do
    T.test("gears: rejected, loudly: " .. c[1], function()
        local sv = F.server()
        local B = sv.env.BMX
        local d = bike()
        c[2](d)
        T.eq(B.RegisterBike("gearbad", d), false, "refused")
        T.ok(#sv.errors > 0 and sv.errors[1]:find(c[3], 1, true), "reported with `" .. c[3] .. "`: " .. tostring(sv.errors[1]))
        T.ok(not B.Bikes.gearbad, "and not registered")
    end)
end

--------------------------------------------------------------------------
-- The gear model
--------------------------------------------------------------------------

T.test("gears: a bike with none runs on Drive.gearRatio, whatever its Gear says", function()
    local sv = F.server()
    local B = sv.env.BMX
    local e = F.bike(sv, "bmx_base")
    T.eq(B.GearRatio(e, e:Cfg()), B.Config.Drive.gearRatio, "the config's ratio")
    e:SetGear(5)
    T.eq(B.GearRatio(e, e:Cfg()), B.Config.Drive.gearRatio, "unmoved by a gear it does not have")
    T.eq(B.Gears.Label(e), nil, "and nothing for the HUD")
    T.eq(B.Shift(e, 1), nil, "and a shift does nothing")
end)

T.test("gears: a new road bike is in its start gear, and the ratio follows the gear", function()
    local sv, e = ridden("road")
    local B = sv.env.BMX
    local g = B.Bikes.road.gears
    T.eq(B.Gears.Index(e), g.start, "the registration's start")
    T.eq(B.GearRatio(e, e:Cfg()), g.ratios[g.start], "its ratio")
    B.SetGear(e, 1)
    T.eq(B.GearRatio(e, e:Cfg()), g.ratios[1], "gear 1")
    B.SetGear(e, #g.ratios)
    T.eq(B.GearRatio(e, e:Cfg()), g.ratios[#g.ratios], "the top gear")
    T.eq(B.Gears.Label(e), string.format("gear %d/%d", #g.ratios, #g.ratios), "the HUD says so")
end)

T.test("gears: the road bike's gears are 2 to 11, rising, and keep the legs in band at every speed from a jog to the top", function()
    local sv = F.server()
    local B = sv.env.BMX
    local g = B.Bikes.road.gears
    T.between(#g.ratios, 2, 11, "how many")
    for i = 2, #g.ratios do T.ok(g.ratios[i] > g.ratios[i - 1], "gear " .. i .. " is higher than gear " .. (i - 1)) end
    local cfg = B.ConfigFor(B.Bikes.road)
    -- 110 u/s is 2.8 m/s, a jog: below it a standing start is on the cranks' torque, not a band.
    local ok, at = B.Gears.Covers(B.Bikes.road, cfg, 110)
    T.ok(ok, "some gear has the legs between 60 and 110 rpm at every speed; none at " .. tostring(at))
    -- Neighbouring bands overlap, so a shift never lands out of the band.
    for i = 1, #g.ratios - 1 do
        local hi = B.Gears.SpeedAt(cfg, g.ratios[i], B.Gears.CAD_HIGH)
        local lo = B.Gears.SpeedAt(cfg, g.ratios[i + 1], B.Gears.CAD_LOW)
        T.ok(lo < hi, string.format("gears %d and %d overlap (%.0f < %.0f)", i, i + 1, lo, hi))
    end
    -- And the best gear for a speed is a gear that is in band.
    for _, v in ipairs({ 110, 160, 220, 300, 400, 480 }) do
        local best = B.Gears.Best(B.Bikes.road, cfg, v)
        local rpm = B.Gears.CadenceRpm(cfg, g.ratios[best], v)
        T.between(rpm, 60, 110, "the best gear at " .. v .. " u/s is at " .. string.format("%.0f", rpm) .. " rpm")
    end
end)

T.test("gears: a box with a gap in its bands is found out", function()
    local sv = F.server()
    local B = sv.env.BMX
    local cfg = B.ConfigFor(B.Bikes.road)
    local gappy = { gears = { ratios = { 1.2, 3.4 } } }
    local ok, at = B.Gears.Covers(gappy, cfg, 110)
    T.ok(not ok and at > 110, "two gears far apart leave a hole, at " .. tostring(at))
end)

--------------------------------------------------------------------------
-- Shifting: the server's decision
--------------------------------------------------------------------------

T.test("shift: up and down by one, clamped to the box, no faster than the cooldown", function()
    local sv, e = ridden("road")
    local B = sv.env.BMX
    local n = B.Gears.Count(e)
    local g0 = B.Gears.Index(e)
    T.eq(B.Shift(e, 1), g0 + 1, "up")
    T.eq(B.Shift(e, 1), nil, "a second one at once is ignored")
    sv:run(B.Gears.SHIFT_COOLDOWN + 0.05)
    T.eq(B.Shift(e, -1), g0, "down")
    B.SetGear(e, n)
    sv:run(0.3)
    T.eq(B.Shift(e, 1), nil, "no gear above the top")
    B.SetGear(e, 1)
    sv:run(0.3)
    T.eq(B.Shift(e, -1), nil, "none below the bottom")
    T.eq(B.SetGear(e, 99), n, "SetGear clamps")
end)

-- A client with a road bike and a rider seated on it, as the network gives it.
local function riderClient(world)
    local cl = F.client(world)
    local cb = cl:clientEntity("bmx_road")
    local pod = cl.makeEntity("prop_vehicle_prisoner_pod")
    pod:SetParent(cb)
    cb:SetPod(pod)
    local me = cl:player("Rider")
    me._vehicle = pod
    cb:SetDriver(me)
    cl.localPlayer = me
    return cl, cb, me
end

T.test("shift: the keys are the road map's; they are buttons, not usercmd bits", function()
    local sv = F.server()
    local B, E = sv.env.BMX, sv.env
    local map = B.InputMaps.road
    T.ok(map.actions.shiftUp and map.actions.shiftDown, "the map has both")
    T.eq(map.actions.shiftUp.key, nil, "a button, not a usercmd bit")
    T.eq(map.actions.shiftUp.buttons[1], E.KEY_RBRACKET, "] shifts up")
    T.eq(map.actions.shiftUp.buttons[2], E.MOUSE_WHEEL_UP, "and so does wheel up")
    T.eq(map.actions.shiftDown.buttons[1], E.KEY_LBRACKET, "[ shifts down")
    T.eq(map.actions.shiftDown.buttons[2], E.MOUSE_WHEEL_DOWN, "and wheel down")
    T.eq(#B.InputActions("road", "ground"), #B.InputActions("bike", "ground") + 2, "listed for a keybind panel")
    T.ok(not B.InputMaps.bike.actions.shiftUp, "the BMX's map has no shift")
    -- A button-only action is allowed; an action with neither is not.
    T.errors(function() B.RegisterInputMap{ id = "bad", actions = { x = { ctx = { "ground" } } } } end,
        "key", "an action with no key and no buttons is refused")
end)

T.test("shift: a press on the client is a message, and the server shifts the rider's bike", function()
    local sv, e, ply, world = ridden("road")
    local B = sv.env.BMX
    local cl, cb, me = riderClient(world)
    local KEY = cl.env
    local g0 = B.Gears.Index(e)
    local function press(button, as)
        local before = #world.wire
        cl.env.hook.Run("PlayerButtonDown", me, button)
        T.eq(#world.wire - before, 1, "one message for button " .. button)
        sv.localPlayer = as or ply
        sv:deliver(world.wire[#world.wire])
    end
    press(KEY.KEY_RBRACKET)
    T.eq(B.Gears.Index(e), g0 + 1, "] shifted up")
    sv:run(0.3)
    press(KEY.MOUSE_WHEEL_DOWN)
    T.eq(B.Gears.Index(e), g0, "wheel down shifted down")
    sv:run(0.3)
    -- Somebody who is not riding it cannot shift it, whatever they send.
    local stranger = sv:player("Bystander")
    press(KEY.KEY_RBRACKET, stranger)
    T.eq(B.Gears.Index(e), g0, "a stranger's message changes nothing")
    -- A key that is not a shift key sends nothing.
    local before = #world.wire
    cl.env.hook.Run("PlayerButtonDown", me, KEY.KEY_K)
    T.eq(#world.wire, before, "another key sends nothing")
    -- The wheel is the player's to give back.
    cl.env.GetConVar("bmx_shift_wheel"):SetString("0")
    cl.env.hook.Run("PlayerButtonDown", me, KEY.MOUSE_WHEEL_UP)
    T.eq(#world.wire, before, "the wheel is ignored when bmx_shift_wheel is 0")
    cl.env.hook.Run("PlayerButtonDown", me, KEY.KEY_RBRACKET)
    T.eq(#world.wire, before + 1, "but the brackets still work")
end)

T.test("shift: a rider on a BMX sends nothing", function()
    local sv, world = F.server()
    local cl = F.client(world)
    local cb = cl:clientEntity("bmx_base")
    local pod = cl.makeEntity("prop_vehicle_prisoner_pod")
    pod:SetParent(cb)
    cb:SetPod(pod)
    local me = cl:player("Rider")
    me._vehicle = pod
    cb:SetDriver(me)
    cl.localPlayer = me
    local before = #world.wire
    cl.env.hook.Run("PlayerButtonDown", me, cl.env.KEY_RBRACKET)
    T.eq(#world.wire, before, "a single-speed bike has no shift")
end)

--------------------------------------------------------------------------
-- The drive runs on the gear
--------------------------------------------------------------------------

T.test("road: the legs' cadence follows the gear: the same wheel speed is a lower cadence in a higher gear", function()
    local sv, e = ridden("road", 1)
    local B = sv.env.BMX
    F.accelerateTo(sv, e, 120)
    F.input(e, { throttle = 0.2 })
    sv:run(0.3)
    local low = e.st.cadence
    B.SetGear(e, 6)
    sv:run(0.2)
    local hi = e.st.cadence
    T.ok(hi < low * 0.75, string.format("cadence %.1f rad/s in gear 1, %.1f in gear 6", low, hi))
end)

T.test("road: top speed is ~1.6x the BMX's, with the legs at 60-110 rpm in the top gear", function()
    local stock = topSpeed("stock")
    local peak, rpm = topSpeed("road", 8)
    T.between(peak / stock, 1.45, 1.8, string.format("road %.0f / BMX %.0f", peak, stock))
    T.between(rpm, 60, 110, "cadence at top speed in the top gear")
end)

T.test("road: every gear has its own top speed, rising with the gear, and the cadence at each stays in the legs' range", function()
    local prev = 0
    for _, gear in ipairs({ 1, 3, 5, 8 }) do
        local peak, rpm = topSpeed("road", gear)
        T.ok(peak > prev, string.format("gear %d tops out higher (%.0f) than the one before (%.0f)", gear, peak, prev))
        T.between(rpm, 60, 120, "cadence at the top of gear " .. gear)
        prev = peak
    end
end)

T.test("road: a low gear gets away quicker than a high one", function()
    local t = {}
    for _, gear in ipairs({ 1, 8 }) do
        local sv, e = ridden("road", gear)
        F.input(e, { throttle = 1 })
        local t0 = sv.world.time
        sv:run(12, function() return e.st.speed >= 120 end)
        t[gear] = e.st.speed >= 120 and (sv.world.time - t0) or 99
    end
    T.ok(t[1] < t[8], string.format("gear 1 reaches 120 u/s in %.2fs, gear 8 in %.2fs", t[1], t[8]))
end)

T.test("road: quicker steering at speed than the BMX (the lean builds sooner)", function()
    local rise = {}
    for _, id in ipairs({ "stock", "road" }) do
        local sv, e = ridden(id)
        local B = sv.env.BMX
        if id == "road" then B.SetGear(e, B.Gears.Best(B.Bikes.road, e:Cfg(), 250)) end
        F.accelerateTo(sv, e, 250)
        F.input(e, { throttle = 0.5, lean = 1 })
        local target = e:Cfg().Balance.maxLean
        local t0 = sv.world.time
        sv:run(3, function() return e.st.roll >= target * 0.6 end)
        rise[id] = sv.world.time - t0
        T.ok(e.st.roll >= target * 0.6, id .. " reached 60% of full lean")
    end
    T.ok(rise.road <= rise.stock, string.format("road %.2fs <= BMX %.2fs to 60%% lean", rise.road, rise.stock))
end)

T.test("road: it hops less than the BMX, and still lands", function()
    local peak = {}
    for _, id in ipairs({ "stock", "road" }) do
        local sv, e = ridden(id)
        F.accelerateTo(sv, e, 160)
        F.input(e, { throttle = 0.5 })
        local z0 = e:GetPos().z
        e.hopHeld, e.hopCharge = true, 0
        sv:run(e:Cfg().Hop.chargeTime + 0.05)
        e.hopRelease = true
        local top = 0
        sv:run(1.6, function() top = math.max(top, e:GetPos().z - z0) return false end)
        peak[id] = top
        T.ok(e.st.grounded and sv.env.IsValid(e:GetDriver()), id .. " landed, still aboard")
    end
    T.ok(peak.road < peak.stock, string.format("hop height: road %.1f < BMX %.1f", peak.road, peak.stock))
end)

T.test("road: it brakes to a stop, and settles upright on its own wheels", function()
    local sv, e = ridden("road")
    local B = sv.env.BMX
    local f, r = F.wheels(e)
    T.ok(f.onGround and r.onGround, "both wheels down")
    T.ok(math.abs(e.st.roll) < math.rad(10), "upright")
    F.accelerateTo(sv, e, 250)
    F.input(e, { brakeRear = 1, brakeFront = 0.5 })
    sv:run(6, function() return e.st.speed < 5 end)
    T.ok(e.st.speed < 5, "stopped: " .. e.st.speed)
    T.ok(sv.env.IsValid(e:GetDriver()), "still on it")
    T.eq(#sv.errors, 0, table.concat(sv.errors, " | "))
end)

--------------------------------------------------------------------------
-- The score
--------------------------------------------------------------------------

T.test("road: a trick scores x1.5, the BMX's does not", function()
    local sv, e = ridden("road")
    local sv2, b = ridden("stock")
    local hooks = {}
    sv.env.hook.Add("BMX_TrickLanded", "t", function(ply, t, pts) hooks[#hooks + 1] = pts end)
    e:AwardTricks({ { name = "Backflip", count = 1, points = 500 } })
    b:AwardTricks({ { name = "Backflip", count = 1, points = 500 } })
    T.eq(e:GetScore(), 750, "500 -> 750 on the road bike")
    T.eq(b:GetScore(), 500, "500 on the BMX")
    T.eq(hooks[1], 750, "the public hook hears the multiplied number too")
end)

T.test("road: the caller's trick list is not rewritten", function()
    local sv, e = ridden("road")
    local list = { { name = "Backflip", count = 1, points = 500 } }
    e:AwardTricks(list)
    T.eq(list[1].points, 500, "left as it was")
end)

--------------------------------------------------------------------------
-- Drawn, and posed
--------------------------------------------------------------------------

local function clientScene(id)
    local sv, world = F.server()
    local cfg = sv.env.BMX.ConfigFor(sv.env.BMX.Bikes[id])
    local pos = sv.env.Vector(0, 0, sv.world.groundZ + sv.env.BMX.RestHeight(cfg))
    local bike = F.bike(sv, classOf(sv, id), pos)
    sv:run(0.3)
    local cl = F.client(world)
    local cb = cl:clientEntity(classOf(sv, id))
    cb:SetPos(bike:GetPos())
    cb:SetAngles(bike:GetAngles())
    for k, v in pairs(bike._nw) do
        if k ~= "Driver" and k ~= "Pod" then cb._nw[k] = v end
    end
    return sv, cl, cb, bike
end

T.test("road: the client draws it, with drop bars the BMX does not have", function()
    local _, cl, cb = clientScene("road")
    cl.beams = {}
    cb:Draw()
    local road = #cl.beams
    T.eq(#cl.errors, 0, "no errors: " .. table.concat(cl.errors, " | "))
    local _, cl2, cb2 = clientScene("stock")
    cl2.beams = {}
    cb2:Draw()
    T.ok(road >= #cl2.beams + 6, string.format("%d tubes against the BMX's %d: the drops are drawn", road, #cl2.beams))
end)

T.test("road: the tucked pose folds the rider lower than the BMX's, and lower still when fast", function()
    local sv, world = F.server()
    local cl = F.client(world)
    local B = cl.env.BMX
    local s = { crank = 0, speed = 0, topSpeed = 500, pitch = 0, steer = 0 }
    local bmx = B.PoseSets.bike.rider(s)
    local road = B.PoseSets.road.rider(s)
    T.ok(road.spine.y > bmx.spine.y + 15, "spine forward at a standstill: " .. road.spine.y .. " vs " .. bmx.spine.y)
    s.speed = 500
    local fast = B.PoseSets.road.rider(s)
    T.ok(fast.spine.y > road.spine.y + 5, "and lower at speed")
    T.ok(road.head.y < 0, "the head comes up against it")
    T.eq(B.PoseSets.road.poses, B.RiderPoses, "the style tricks have their poses")
end)

