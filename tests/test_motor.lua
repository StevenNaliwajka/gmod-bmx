--[[--------------------------------------------------------------------------
    The motor vehicles (G14, G15): the e-bike, the e-moto, the dirt bike and the
    moped, and the model they run on (sh_motor.lua, sv_motor.lua, cl_motor.lua).

    Two kinds of test. The MODEL's are pure functions called with numbers: the
    assist's cut-off, the battery's arithmetic, the torque curve, the shift points,
    the clutch's three states. The VEHICLES' are on the offline plant: the e-bike
    holds its limit, the battery drains with the motor's work and no faster, the
    e-moto reaches about two and a half BMXs, a clutch pop lifts the front wheel and
    a plain launch does not, a big drop lands. The plant is right in kind and is not
    VPhysics (docs/TESTING.md); the headless cases in sv_test_cases.lua are what meet
    the real engine.
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
    return sv, bike, ply, world
end

local function topSpeed(id, level, secs)
    local sv, bike = ridden(id)
    if level then sv.env.BMX.SetAssist(bike, level) end
    F.input(bike, { throttle = 1 })
    local peak = 0
    sv:run(secs or 25, function() peak = math.max(peak, bike.st.speed) return false end)
    return peak, bike, sv
end

--------------------------------------------------------------------------
-- The registry, the spawn menu, the gate
--------------------------------------------------------------------------

T.test("motor: all four register clean, as motor vehicles, with their own class, row and name", function()
    local sv = F.server()
    local B = sv.env.BMX
    T.eq(#sv.errors, 0, "nothing rejected: " .. table.concat(sv.errors, " | "))
    local want = { ebike = "E-Bike", emoto = "E-Moto", dirtbike = "Dirt Bike", moped = "Moped" }
    for id, name in pairs(want) do
        local d = B.Bikes[id]
        T.ok(d, id .. " registered")
        T.eq(d.family, "moto", id .. " is a motor vehicle")
        T.eq(B.ClassFor(id), "bmx_" .. id, id .. "'s class")
        local row = sv.lists.SpawnableEntities["bmx_" .. id]
        T.ok(row, id .. " has a spawn menu row")
        T.eq(row.Subcategory, "Motor", id .. " is under Motor")
        T.eq(row.PrintName, name, id .. "'s name")
        T.ok(sv.dupe["bmx_" .. id], "the duplicator knows " .. id)
        T.eq(d.balance, "singletrack", id .. " is balanced like a bike")
    end
    T.eq(B.Bikes.ebike.drive.kind, "assist", "the e-bike's assist drive")
    T.eq(B.Bikes.emoto.drive.kind, "throttle", "the e-moto's throttle drive")
    T.eq(B.Bikes.dirtbike.drive.kind, "engine", "the dirt bike's engine")
    T.eq(B.Bikes.moped.drive.kind, "engine", "the moped's engine")
    T.eq(B.Gears.Count(B.Bikes.dirtbike), 5, "five gears, through the road bike's gear model")
    T.eq(B.Gears.Count(B.Bikes.moped), 0, "the moped has one ratio")
end)

T.test("motor: bmx_spawn builds each of them at its own rest height", function()
    for _, id in ipairs({ "ebike", "emoto", "dirtbike", "moped" }) do
        local sv = F.server()
        local ply = sv:player("Spawner", { superadmin = true })
        ply:SetPos(sv.env.Vector(0, 0, 0))
        ply._eyeTrace = { Hit = true, HitPos = sv.env.Vector(100, 0, 0), HitNormal = sv.env.Vector(0, 0, 1) }
        sv:command("bmx_spawn", ply, id)
        local found = sv.env.ents.FindByClass("bmx_" .. id)
        T.eq(#found, 1, "one " .. id)
        T.ok(found[1]:AssertBuilt(), id .. " is built")
        T.near(found[1]:GetPos().z, sv.env.BMX.RestHeight(found[1]:Cfg()) + 0.5, 0.01, id .. " at rest, not dropped")
    end
end)

T.test("motor: spawning one needs the CAMI privilege, from bmx_spawn and the spawn menu alike", function()
    local sv = F.server()
    local E = sv.env
    local function spawn(ply, id)
        sv.world.time = sv.world.time + 2
        sv:command("bmx_spawn", ply, id)
    end
    local function looker(name, opts)
        local ply = sv:player(name, opts)
        ply:SetPos(E.Vector(0, 0, 0))
        ply._eyeTrace = { Hit = true, HitPos = E.Vector(100, 0, 0), HitNormal = E.Vector(0, 0, 1) }
        return ply
    end
    local user, admin = looker("User"), looker("Admin", { superadmin = true })
    spawn(user, "dirtbike")
    T.eq(#E.ents.FindByClass("bmx_dirtbike"), 0, "a plain player gets no dirt bike")
    T.ok(user._chat[1] and user._chat[1]:find("Spawn Motor Vehicles", 1, true), "and is told which privilege")
    T.eq(E.hook.Run("PlayerSpawnSENT", user, "bmx_emoto"), false, "the spawn menu's door is shut to them too")
    spawn(user, "stock")
    T.eq(#E.ents.FindByClass("bmx_base"), 1, "bikes are not motor vehicles: nothing changed for them")
    spawn(admin, "dirtbike")
    T.eq(#E.ents.FindByClass("bmx_dirtbike"), 1, "an admin may")

    -- CAMI's word, both ways: a granted plain player may, a denied admin may not.
    local answers = {}
    E.CAMI = { RegisterPrivilege = function() end,
               PlayerHasAccess = function(ply, priv, cb) cb(answers[ply:Nick()] == true) end }
    answers.User = true
    spawn(user, "ebike")
    T.eq(#E.ents.FindByClass("bmx_ebike"), 1, "CAMI grants it to a plain player")
    answers.Admin = false
    spawn(admin, "moped")
    T.eq(#E.ents.FindByClass("bmx_moped"), 0, "CAMI denies it to an admin")
end)

T.test("motor: bmx_allow_motor 0 stops every motor vehicle, whoever asks", function()
    local sv = F.server()
    local E = sv.env
    local ply = sv:player("Boss", { superadmin = true })
    ply:SetPos(E.Vector(0, 0, 0))
    ply._eyeTrace = { Hit = true, HitPos = E.Vector(100, 0, 0), HitNormal = E.Vector(0, 0, 1) }
    E.GetConVar("bmx_allow_motor"):SetString("0")
    for _, id in ipairs({ "ebike", "emoto", "dirtbike", "moped" }) do
        sv.world.time = sv.world.time + 2
        sv:command("bmx_spawn", ply, id)
        T.eq(#E.ents.FindByClass("bmx_" .. id), 0, id .. " is switched off")
        T.eq(E.BMX.VehicleEnabled(id), false, id .. ": VehicleEnabled says so")
    end
    T.ok(E.BMX.VehicleEnabled("stock"), "bikes are not affected")
    E.GetConVar("bmx_allow_motor"):SetString("1")
    sv.world.time = sv.world.time + 2
    sv:command("bmx_spawn", ply, "emoto")
    T.eq(#E.ents.FindByClass("bmx_emoto"), 1, "and back on")
end)

T.test("motor: the settings are rows, with the convars' own defaults", function()
    local sv = F.server()
    local S = sv.env.BMX.Settings
    for name, def in pairs({ bmx_ebike_limit = 25, bmx_ebike_battery = 500 }) do
        local row = S.Get(name)
        T.ok(row, name .. " has a settings row")
        T.eq(row.scope, "server", name .. " is the server's")
        T.eq(row.default, def, name .. "'s default")
        T.eq(sv.env.GetConVar(name):GetFloat(), def, name .. "'s convar agrees")
        T.ok(#row.help > 20, name .. " is explained")
    end
    T.eq(S.Get("bmx_ebike_battery").min, 0, "0 is allowed: an infinite battery")
end)

T.test("motor: the registry refuses a bad engine, loudly", function()
    local B = F.server().env.BMX
    local sv = F.server()
    B = sv.env.BMX
    local function engine(over)
        local d = { kind = "engine", torque = 1000, idle = 1000, redline = 8000, inertia = 10, friction = 0.1,
                    clutch = 2, engageRpm = 3000, ratio = 0.05,
                    curve = { { 1000, 0.5 }, { 5000, 1 }, { 8000, 0.5 } } }
        for k, v in pairs(over or {}) do d[k] = v end
        return { printName = "E test", drive = d }
    end
    T.ok(B.RegisterBike("engok", engine()), "a good engine is accepted")
    T.eq(#sv.errors, 0, table.concat(sv.errors, " | "))
    local BAD = {
        { "no torque",        { torque = false },                         "torque" },
        { "idle over redline", { idle = 9000 },                           "idle" },
        { "a curve of one",   { curve = { { 1000, 1 } } },                "curve" },
        { "a curve that falls in rpm", { curve = { { 5000, 1 }, { 1000, 1 }, { 8000, 1 } } }, "rise" },
        { "a curve short of the redline", { curve = { { 1000, 1 }, { 5000, 1 } } }, "redline" },
        { "no ratio and no gears", { ratio = false },                     "ratio" },
        { "an unknown key",   { turbo = 2 },                              "turbo" },
        { "a key of the wrong type", { inertia = "heavy" },               "inertia" },
    }
    for _, c in ipairs(BAD) do
        local d = engine(c[2])
        for k, v in pairs(d.drive) do if v == false then d.drive[k] = nil end end
        T.eq(B.RegisterBike("engbad", d), false, c[1] .. ": refused")
        T.ok(sv.errors[#sv.errors] and sv.errors[#sv.errors]:find(c[3], 1, true),
            c[1] .. ": reported with `" .. c[3] .. "`: " .. tostring(sv.errors[#sv.errors]))
        T.ok(not B.Bikes.engbad, c[1] .. ": not registered")
    end
    T.eq(B.RegisterBike("assbad", { drive = { kind = "assist", assist = 5 } }), false, "an assist level of 5 is refused")
    T.eq(B.RegisterBike("assbad2", { drive = { kind = "assist", boost = 2 } }), false, "an unknown assist key is refused")
    T.ok(B.RegisterBike("assok", { drive = { kind = "assist", assist = 0 } }), "level 0 is a level")
    -- The test cart's plain throttle drive is untouched.
    T.ok(B.Vehicles.testcart, "the cart is still registered")
end)

--------------------------------------------------------------------------
-- The e-bike: the assist, the limit, the battery
--------------------------------------------------------------------------

T.test("assist: the motor is level x the rider's torque, and gone at the limit", function()
    local B = F.server().env.BMX
    local M = B.Motor
    local limit = M.KmhToUps(25)
    T.near(limit, 273.4, 0.5, "25 km/h in units a second")
    for level = 0, 3 do
        T.near(M.AssistTorque(level, 1000, 50, limit, true), level * 1000, 1e-6, "level " .. level .. " at a crawl")
    end
    T.eq(M.AssistTorque(3, 1000, limit, limit, true), 0, "nothing at the limit")
    T.eq(M.AssistTorque(3, 1000, limit + 40, limit, true), 0, "nothing past it")
    T.eq(M.AssistTorque(3, 1000, limit - 1, limit, true) > 0, true, "something just under it")
    -- A fade, not a wall: monotone from whole to nothing over the last RAMP_KMH.
    local prev = math.huge
    for v = limit - M.KmhToUps(M.RAMP_KMH) - 5, limit + 5, 2 do
        local t = M.AssistTorque(2, 1000, v, limit, true)
        T.ok(t <= prev + 1e-9, "never rises with speed at " .. v)
        prev = t
    end
    T.eq(M.AssistTorque(2, 1000, 50, limit, false), 0, "no motor on an empty battery")
    T.eq(M.AssistTorque(2, 0, 50, limit, true), 0, "nor when the rider is not pedalling")
end)

T.test("assist: bmx_ebike_limit moves the cut-off", function()
    local sv = F.server()
    local M = sv.env.BMX.Motor
    T.near(M.LimitUps(), M.KmhToUps(25), 1e-6, "25 by default")
    sv.env.GetConVar("bmx_ebike_limit"):SetString("45")
    T.near(M.LimitUps(), M.KmhToUps(45), 1e-6, "45 when the server says so")
    T.eq(M.AssistTorque(2, 1000, M.KmhToUps(30), M.LimitUps(), true), 2000, "30 km/h is under it now")
end)

T.test("assist: on the plant the e-bike holds the limit with the motor on, and 3 pulls harder than 1", function()
    local limit = 273.4
    local peaks = {}
    for level = 0, 3 do
        local peak, bike = topSpeed("ebike", level, 20)
        peaks[level] = peak
        T.ok(peak <= limit * 1.02, string.format("level %d tops out at %.0f u/s, under the 25 km/h limit (%.0f)", level, peak, limit))
        T.ok(bike.st.speed > 0 and bike.st.grounded, "level " .. level .. " is still riding")
    end
    T.ok(peaks[1] > peaks[0] + 5, "any assist beats the legs alone: " .. peaks[1] .. " vs " .. peaks[0])
    T.between(peaks[3], limit * 0.95, limit * 1.02, "with the motor on it sits at the limit")
    -- Quicker off the line, level by level.
    local function t150(level)
        local sv, bike = ridden("ebike")
        sv.env.BMX.SetAssist(bike, level)
        F.input(bike, { throttle = 1 })
        local t = 0
        sv:run(12, function() t = t + 1 / 66 return bike.st.speed >= 150 end)
        return t
    end
    local a, b, c = t150(0), t150(1), t150(3)
    T.ok(a > b and b > c, string.format("0-150 u/s in %.2f, %.2f and %.2f s at levels 0, 1, 3", a, b, c))
end)

T.test("assist: a raised limit raises the speed; the rider keeps the control", function()
    local sv, bike = ridden("ebike")
    sv.env.GetConVar("bmx_ebike_limit"):SetString("40")
    sv.env.BMX.SetAssist(bike, 3)
    F.input(bike, { throttle = 1 })
    local peak = 0
    sv:run(25, function() peak = math.max(peak, bike.st.speed) return false end)
    T.between(peak, 273.4 * 1.1, 40 * 10.936 * 1.02, "past 25 km/h, under 40: " .. peak)
    T.ok(sv.env.IsValid(bike:GetDriver()), "the rider is still aboard")
end)

T.test("assist: level 3 does not loop the bike over backwards (traction control)", function()
    local sv, bike = ridden("ebike")
    sv.env.BMX.SetAssist(bike, 3)
    F.input(bike, { throttle = 1 })
    local maxPitch = 0
    sv:run(6, function() maxPitch = math.max(maxPitch, bike.st.pitch) return false end)
    T.ok(math.deg(maxPitch) < 35, "the front comes up a little and no further: " .. math.deg(maxPitch))
    T.ok(sv.env.IsValid(bike:GetDriver()), "no crash")
end)

T.test("assist: the level is 0-3, spawns at 1, and the shift keys move it, with the gear cooldown", function()
    local sv, e = ridden("ebike")
    local B = sv.env.BMX
    local M = B.Motor
    T.eq(M.Level(e), 1, "it spawns in level 1")
    T.eq(B.Shift(e, 1), 2, "up")
    T.eq(B.Shift(e, 1), nil, "a second one at once is ignored")
    sv:run(B.Gears.SHIFT_COOLDOWN + 0.05)
    T.eq(B.Shift(e, 1), 3, "up to the top")
    sv:run(0.3)
    T.eq(B.Shift(e, 1), nil, "nothing above 3")
    T.eq(M.Level(e), 3, "still 3")
    for want = 2, 0, -1 do
        sv:run(0.3)
        T.eq(B.Shift(e, -1), want, "down to " .. want)
    end
    sv:run(0.3)
    T.eq(B.Shift(e, -1), nil, "nothing below 0")
    T.eq(M.Level(e), 0, "level 0 is a real level, not 'unset'")
    T.eq(B.SetAssist(e, 9), 3, "SetAssist clamps")
    T.eq(B.SetAssist(e, -4), 0, "both ends")
    -- A bike without an assist drive is not touched.
    local sv2, road = ridden("road")
    T.eq(sv2.env.BMX.SetAssist(road, 2), nil, "SetAssist on a road bike does nothing")
end)

T.test("assist: the wheel and [ ] reach it through the real wire, and only from the rider", function()
    local sv, e, ply, world = ridden("ebike")
    local B = sv.env.BMX
    local E = sv.env
    local map = B.InputMaps.ebike
    T.eq(map.actions.shiftUp.buttons[2], E.MOUSE_WHEEL_UP, "the wheel up")
    T.eq(map.actions.shiftDown.buttons[1], E.KEY_LBRACKET, "and [")
    T.eq(#B.InputActions("ebike", "ground"), #B.InputActions("bike", "ground") + 2, "listed for a keybind panel")
    -- The client's side: the e-bike is "geared" for the shift keys.
    local cl = F.client(world)
    local cb = cl:clientEntity("bmx_ebike")
    T.eq(cl.env.BMX.ShiftForButton(cb, cl.env.MOUSE_WHEEL_UP, true), true, "wheel up is up")
    T.eq(cl.env.BMX.ShiftForButton(cb, cl.env.KEY_LBRACKET, true), false, "[ is down")
    T.eq(cl.env.BMX.ShiftForButton(cb, cl.env.MOUSE_WHEEL_UP, false), nil, "bmx_shift_wheel 0 leaves the wheel alone")
    -- The whole wire: a press on the client, the server decides.
    local cb2 = cl:clientEntity("bmx_ebike")
    local pod = cl.makeEntity("prop_vehicle_prisoner_pod")
    pod:SetParent(cb2)
    cb2:SetPod(pod)
    local me = cl:player("Rider")
    me._vehicle = pod
    cb2:SetDriver(me)
    cl.localPlayer = me
    local function press(button, as)
        local before = #world.wire
        cl.env.hook.Run("PlayerButtonDown", me, button)
        T.eq(#world.wire - before, 1, "one message for button " .. button)
        sv.localPlayer = as or ply
        sv:deliver(world.wire[#world.wire])
    end
    press(cl.env.KEY_RBRACKET)
    T.eq(B.Motor.Level(e), 2, "] raised the level")
    sv:run(0.3)
    press(cl.env.MOUSE_WHEEL_DOWN)
    T.eq(B.Motor.Level(e), 1, "wheel down lowered it")
    sv:run(0.3)
    press(cl.env.KEY_RBRACKET, sv:player("Bystander"))
    T.eq(B.Motor.Level(e), 1, "a stranger's message changes nothing")
end)

--------------------------------------------------------------------------
-- The battery
--------------------------------------------------------------------------

T.test("battery: the arithmetic, efficiency against you both ways", function()
    local B = F.server().env.BMX
    local M = B.Motor
    -- 100 N m at 10 rad/s is 1000 W at the wheel.
    local tq = 100 / M.NM
    T.near(M.Watts(tq, 10), 1000, 1e-6, "mechanical watts")
    T.near(M.ElectricWatts(tq, 10), 1000 / M.EFFICIENCY, 1e-6, "driving costs more than it delivers")
    T.near(M.ElectricWatts(-tq, 10), -1000 * M.REGEN_EFF, 1e-6, "braking returns less than it took")
    T.ok(M.EFFICIENCY < 1 and M.REGEN_EFF < 1, "neither is above 100%")
    T.ok(M.REGEN_EFF < M.EFFICIENCY, "a round trip loses")
    T.near(M.Spend(100, 500, 3600, 1), 99, 1e-9, "3600 W for a second is 1 Wh")
    T.eq(M.Spend(0.5, 500, 3600, 1), 0, "never below empty")
    T.eq(M.Spend(499.5, 500, -3600, 1), 500, "never above full")
    T.near(M.Charge(0, 500, 1), 500 / M.CHARGE_SECONDS, 1e-9, "charging is a fixed share of the pack a second")
    T.eq(M.Charge(499.9, 500, 10), 500, "and stops at full")
end)

T.test("battery: the capacity is the setting, an e-moto's three times it, and 0 is infinite", function()
    local sv = F.server()
    local B = sv.env.BMX
    local M = B.Motor
    T.eq(M.CapacityWh(B.Bikes.ebike), 500, "500 Wh")
    T.eq(M.CapacityWh(B.Bikes.emoto), 1500, "three e-bikes' worth")
    sv.env.GetConVar("bmx_ebike_battery"):SetString("200")
    T.eq(M.CapacityWh(B.Bikes.ebike), 200, "the server's number")
    sv.env.GetConVar("bmx_ebike_battery"):SetString("0")
    T.eq(M.CapacityWh(B.Bikes.ebike), nil, "0 means infinite")
    T.ok(M.HasBattery(B.Bikes.ebike) and M.HasBattery(B.Bikes.emoto), "both carry one")
    T.ok(not M.HasBattery(B.Bikes.dirtbike) and not M.HasBattery(B.Bikes.stock), "a petrol bike and a BMX do not")
    T.ok(not M.HasBattery(B.Vehicles.testcart), "nor does the test cart")
end)

T.test("battery: what it drains is what the motor did, divided by the efficiency, and no free energy", function()
    local sv, bike = ridden("ebike")
    local B = sv.env.BMX
    local M = B.Motor
    B.SetAssist(bike, 2)
    -- THE WORK, MEASURED FROM OUTSIDE the model's own books: the legs' from what the pedal
    -- drive returns, the motor's from what the assist returns on top of it, each times the
    -- wheel's speed and the step.
    local legsJ, motorJ = 0, 0
    local pedal, assist = B.Drives.pedal, B.Drives.assist
    local rear = select(2, F.wheels(bike))
    local lastLegs = 0
    B.Drives.pedal = function(...)
        lastLegs = pedal(...)
        return lastLegs
    end
    B.Drives.assist = function(...)
        local tq = assist(...)
        local w = math.max(rear.omega, 0) * (1 / 66) * M.NM
        legsJ = legsJ + math.max(lastLegs, 0) * w
        motorJ = motorJ + math.max(tq - lastLegs, 0) * w
        return tq
    end
    F.input(bike, { throttle = 1 })
    local m = bike:GetPhysicsObject():GetMass()
    sv:run(14)
    B.Drives.pedal, B.Drives.assist = pedal, assist
    local used = (M.CapacityWh(bike:Bike()) - bike.st.battery) * 3600       -- joules out of the pack
    T.ok(used > 50, "the motor drew something: " .. used .. " J")
    T.near(used * M.EFFICIENCY, motorJ, motorJ * 0.03 + 1, "the pack gave up the motor's work over the efficiency")
    T.near(bike.st.motorJ, motorJ, motorJ * 0.03 + 1, "and the model's own books agree with the outside measure")
    local ke = 0.5 * m * bike.st.speed ^ 2 * M.NM
    T.ok(ke <= motorJ + legsJ, string.format("the bike's kinetic energy %.0f J is no more than the motor's %.0f plus the legs' %.0f", ke, motorJ, legsJ))
    T.ok(motorJ > legsJ * 0.5, "and at level 2 the motor is doing real work next to the legs")
    -- Spent in proportion to the work: level 3 draws more than level 1 for the same job.
    local function drawn(level)
        local sv2, b2 = ridden("ebike")
        sv2.env.BMX.SetAssist(b2, level)
        F.input(b2, { throttle = 1 })
        sv2:run(8)
        return M.CapacityWh(b2:Bike()) - b2.st.battery
    end
    T.ok(drawn(3) > drawn(1), "level 3 costs more than level 1")
    -- Nothing is drawn with the motor off, or coasting at the limit with no pedalling.
    local sv3, b3 = ridden("ebike")
    sv3.env.BMX.SetAssist(b3, 0)
    F.input(b3, { throttle = 1 })
    sv3:run(6)
    T.eq(b3.st.battery, M.CapacityWh(b3:Bike()), "level 0 draws nothing")
end)

T.test("battery: empty means a heavy bicycle, full again after a parked spell", function()
    local sv, bike = ridden("ebike")
    local B = sv.env.BMX
    local M = B.Motor
    B.SetAssist(bike, 3)
    bike.st.battery = 0
    F.input(bike, { throttle = 1 })
    local peak = 0
    sv:run(20, function() peak = math.max(peak, bike.st.speed) return false end)
    local legs = topSpeed("ebike", 0, 20)
    T.near(peak, legs, 8, string.format("an empty pack at level 3 rides like level 0: %.0f vs %.0f", peak, legs))
    T.eq(bike.st.battery, 0, "and nothing is drawn from an empty pack")
    T.ok(peak < 273.4 * 0.97, "short of the limit")
    -- Charging while parked: the rider gets off.
    bike:SetDriver(nil)
    bike.input.throttle = 0
    local sv2, b2, ply = ridden("ebike")
    b2.st.battery = 100
    sv2.env.hook.Run("PlayerLeaveVehicle", ply, b2:GetPod())
    ply:ExitVehicle()
    sv2:run(10)
    local gained = b2.st.battery - 100
    T.between(gained, 500 / M.CHARGE_SECONDS * 8, 500 / M.CHARGE_SECONDS * 11, "parked and unridden it gains a share of the pack a second: " .. gained)
    sv2:run(200)
    T.eq(b2.st.battery, 500, "and fills, and stops")
end)

T.test("battery: bmx_ebike_battery 0 never runs down, and the HUD says so", function()
    local sv, world = F.server()
    sv.env.GetConVar("bmx_ebike_battery"):SetString("0")
    local B = sv.env.BMX
    local cfg = B.ConfigFor(B.Bikes.ebike)
    local bike = F.bike(sv, "bmx_ebike", sv.env.Vector(0, 0, sv.world.groundZ + B.RestHeight(cfg)))
    F.scripted(sv, bike)
    sv:run(0.5)
    B.SetAssist(bike, 3)
    F.input(bike, { throttle = 1 })
    sv:run(10)
    T.eq(bike.st.battery, nil, "there is no charge to run down")
    T.ok(bike.st.speed > 200, "and the motor works")
    T.eq(bike:GetBattery(), -1, "networked as -1: infinite")
    local cl = F.client(world)
    local cb = cl:clientEntity("bmx_ebike")
    cb:SetBattery(-1)
    local info = cl.env.BMX.MotorHudInfo(cb)
    T.eq(info.battery, nil, "no bar")
    T.eq(info.batteryLabel, "battery inf", "the label")
end)

T.test("hud: the e-bike shows its level and its charge, the dirt bike its rpm, gear and clutch", function()
    local _, world = F.server()
    local cl = F.client(world)
    local B = cl.env.BMX
    local e = cl:clientEntity("bmx_ebike")
    e:SetAssist(3)             -- level 2
    e:SetBattery(0.625)
    local i = B.MotorHudInfo(e)
    T.eq(i.assist, "assist 2/3", "the level")
    T.near(i.battery, 0.625, 1e-9, "the bar")
    T.eq(i.batteryLabel, "battery 63%", "the label")
    e:SetAssist(0)
    T.eq(B.MotorHudInfo(e).assist, "assist 1/3", "unset reads as the spawn level")
    local d = cl:clientEntity("bmx_dirtbike")
    d:SetRpm(5250)
    d:SetGear(3)
    d:SetClutch(1)
    local j = B.MotorHudInfo(d)
    T.near(j.rpm, 0.5, 1e-9, "half the redline")
    T.eq(j.rpmLabel, "5250 rpm", "the number")
    T.eq(j.gear, "gear 3/5", "the road bike's gear label")
    T.eq(j.clutch, true, "the lever is in")
    T.eq(B.MotorHudInfo(cl:clientEntity("bmx_base")), nil, "a BMX has nothing to add")
    T.ok(cl.env.BMX.Motor.FixedCranks(d) and cl.env.BMX.Motor.FixedCranks(cl:clientEntity("bmx_emoto")), "motorbikes hold their cranks still")
    T.ok(not cl.env.BMX.Motor.FixedCranks(e) and not cl.env.BMX.Motor.FixedCranks(cl:clientEntity("bmx_moped")), "an e-bike and a moped pedal")
end)

--------------------------------------------------------------------------
-- The e-moto
--------------------------------------------------------------------------

T.test("emoto: about two and a half BMXs, heavier, with longer travel", function()
    local peak = topSpeed("emoto", nil, 30)
    local bmx = topSpeed("stock", nil, 25)
    T.between(peak / bmx, 2.2, 2.9, string.format("%.0f u/s against the BMX's %.0f", peak, bmx))
    local sv = F.server()
    local B = sv.env.BMX
    local m, s = B.ConfigFor(B.Bikes.emoto), B.ConfigFor(B.Bikes.stock)
    T.ok(m.Chassis.mass > s.Chassis.mass * 1.5, "heavier")
    T.ok(m.Wheel.restLength > s.Wheel.restLength * 1.2, "longer travel")
end)

T.test("emoto: no pedalling, W is the throttle, and an empty pack is no motor", function()
    local sv, bike = ridden("emoto")
    F.input(bike, { throttle = 1 })
    sv:run(3)
    T.eq(bike.st.cadence, 0, "nothing turns the cranks")
    T.ok(bike.st.speed > 200, "but it goes")
    T.ok(bike.st.rpm > 1000, "the motor is turning: " .. bike.st.rpm)
    local sv2, b2 = ridden("emoto")
    b2.st.battery = 0
    F.input(b2, { throttle = 1 })
    sv2:run(3)
    T.ok(b2.st.speed < 30, "an empty pack: " .. b2.st.speed)
end)

T.test("emoto: S brakes with the motor, and the pack gets the energy back, at a loss", function()
    local sv, bike = ridden("emoto")
    local B = sv.env.BMX
    local M = B.Motor
    F.input(bike, { throttle = 1 })
    sv:run(5)
    local v0 = bike.st.speed
    T.ok(v0 > 500, "up to speed: " .. v0)
    bike.st.battery = 600                           -- room to charge into
    local before = bike.st.battery
    F.input(bike, { brakeRear = 1 })
    local brakeJ = 0
    local rear = select(2, F.wheels(bike))
    local used0 = bike.st.motorJ or 0
    sv:run(2)
    T.ok(bike.st.speed < v0 * 0.6, "it slowed: " .. bike.st.speed)
    local gained = (bike.st.battery - before) * 3600
    T.ok(gained > 100, "regen put charge back: " .. gained .. " J")
    -- Never more than the kinetic energy it shed, at the regen efficiency.
    local m = bike:GetPhysicsObject():GetMass()
    local shed = 0.5 * m * (v0 ^ 2 - bike.st.speed ^ 2) * M.NM
    T.ok(gained <= shed * M.REGEN_EFF * 1.02, string.format("gained %.0f J of %.0f J shed (x %.2f max)", gained, shed, M.REGEN_EFF))
    -- With no battery to charge, braking still works the same.
    local sv2, b2 = ridden("emoto")
    F.input(b2, { throttle = 1 })
    sv2:run(5)
    F.input(b2, { brakeRear = 1 })
    sv2:run(2)
    T.near(b2.st.speed, bike.st.speed, 40, "regen is a brake either way")
end)

T.test("emoto: it stays upright at speed and steers", function()
    local sv, bike = ridden("emoto")
    F.input(bike, { throttle = 1 })
    sv:run(6)
    T.ok(math.abs(bike.st.roll) < math.rad(3), "upright at full speed: " .. math.deg(bike.st.roll))
    local y0 = bike:GetAngles().y
    F.input(bike, { throttle = 0.3, lean = 1 })
    sv:run(3)
    T.ok(math.abs(bike:GetAngles().y - y0) > 30, "a lean turns it")
    T.ok(sv.env.IsValid(bike:GetDriver()), "and nobody falls off")
end)

--------------------------------------------------------------------------
-- The engine: the curve, the gears, the clutch
--------------------------------------------------------------------------

local function dirt()
    local sv = F.server()
    local B = sv.env.BMX
    return B, B.Motor, B.Bikes.dirtbike.drive, B.ConfigFor(B.Bikes.dirtbike), B.Bikes.dirtbike.gears
end

T.test("engine: the torque curve rises to a peak in the middle, falls to the limiter, and cuts at the redline", function()
    local _, M, d = dirt()
    T.near(M.CurveAt(d.curve, 7500), 1.0, 1e-9, "the peak is at 7500")
    T.near(M.CurveAt(d.curve, 6250), 0.9, 1e-9, "linear between points")
    T.eq(M.CurveAt(d.curve, 100), d.curve[1][2], "clamped below the first point")
    T.eq(M.CurveAt(d.curve, 20000), d.curve[#d.curve][2], "and above the last")
    local best, bestRpm = 0, 0
    for rpm = d.idle, d.redline, 50 do
        local t = M.EngineTorque(d, rpm, 1)
        if t > best then best, bestRpm = t, rpm end
    end
    T.between(bestRpm, 6000, 9000, "the best torque is mid-range: " .. bestRpm)
    T.ok(M.EngineTorque(d, 3000, 1) < M.EngineTorque(d, 7500, 1), "less low down")
    T.ok(M.EngineTorque(d, 10400, 1) < M.EngineTorque(d, 7500, 1) * 0.5, "much less at the top")
    T.eq(M.EngineTorque(d, d.redline + 100, 1) <= 0, true, "the limiter takes the push away")
    T.ok(M.EngineTorque(d, 8000, 0) < 0, "a closed throttle at speed is engine braking")
    T.ok(M.EngineTorque(d, 8000, 0) > M.EngineTorque(d, 4000, 0) - d.torque, "and more of it with the revs")
    T.ok(M.EngineTorque(d, 500, 0) > 0, "the idle governor holds it up")
    T.ok(M.EngineTorque(d, d.idle + 400, 0) < 0, "and lets go above idle")
end)

T.test("engine: the shift points rise through the gears and sit in the power band", function()
    local B, M, d, cfg, g = dirt()
    local pts = {}
    for i = 1, #g.ratios - 1 do
        pts[i] = M.ShiftPoint(d, cfg, g.ratios, i)
        T.ok(pts[i], "a shift point out of gear " .. i)
        T.ok(M.ShiftPoint(d, cfg, g.ratios, #g.ratios) == nil, "none out of the top gear")
        local rpm = M.RpmAt(cfg, g.ratios[i], pts[i])
        T.between(rpm, 7000, d.redline, string.format("gear %d shifts at %.0f u/s, %.0f rpm", i, pts[i], rpm))
        local rpmAfter = M.RpmAt(cfg, g.ratios[i + 1], pts[i])
        T.ok(rpmAfter > 4500 and rpmAfter < rpm, string.format("and lands at %.0f rpm in the next, in the band", rpmAfter))
        -- At the shift point the next gear pulls at least as hard; just before it, it does not.
        T.ok(M.WheelTorqueAt(d, cfg, g.ratios[i + 1], pts[i]) >= M.WheelTorqueAt(d, cfg, g.ratios[i], pts[i]) - 1e-6,
            "gear " .. (i + 1) .. " is the stronger past it")
        T.ok(M.WheelTorqueAt(d, cfg, g.ratios[i + 1], pts[i] - 6) < M.WheelTorqueAt(d, cfg, g.ratios[i], pts[i] - 6),
            "and weaker before it")
        if i > 1 then T.ok(pts[i] > pts[i - 1], "each one later than the last") end
    end
    -- The box reaches the speeds it should.
    T.near(M.SpeedAt(cfg, g.ratios[#g.ratios], d.redline), 700, 25, "the top gear's redline is ~700 u/s")
    for i = 2, #g.ratios do
        T.ok(M.SpeedAt(cfg, g.ratios[i - 1], d.redline) > M.SpeedAt(cfg, g.ratios[i], 5000), "gear " .. i - 1 .. "'s redline is above gear " .. i .. "'s mid-range: no gap")
    end
end)

T.test("clutch: open lets the engine rev freely, locked ties it to the wheel, slipping passes only what it can", function()
    local _, M, d = dirt()
    local dt = 1 / 66
    -- OPEN (lever pulled): the engine revs on its own torque, and nothing goes to the wheel.
    local s = M.NewEngine(d)
    local thr
    local t0 = s.omega
    for _ = 1, 66 do M.EngineStep(d, s, 1, 0, 0, dt) end
    T.ok(s.omega * M.RPM > 5000, "a second of throttle with the clutch in: " .. s.omega * M.RPM .. " rpm")
    local tq, fly = M.EngineStep(d, s, 1, 0, 0, dt)
    T.eq(tq, 0, "nothing transmitted")
    T.ok(not fly and not s.locked, "and not tied to the wheel")
    for _ = 1, 200 do M.EngineStep(d, s, 1, 0, 0, dt) end
    T.between(s.omega * M.RPM, d.redline - 600, d.redline + 600, "the limiter holds it: " .. s.omega * M.RPM)

    -- NO CREEP, NO STALL: engaged but below the centrifugal bite, at a standstill.
    local c = M.NewEngine(d)
    for _ = 1, 120 do tq = M.EngineStep(d, c, 0, 1, 0, dt) end
    T.eq(tq, 0, "idling in gear passes nothing: it does not creep")
    T.between(c.omega * M.RPM, d.idle - 200, d.idle + 400, "and the governor holds the idle: " .. c.omega * M.RPM)

    -- LOCKED: engine speed equal to the wheel's, a flywheel the wheel must carry.
    local l = M.NewEngine(d)
    l.omega = 600
    tq, fly = M.EngineStep(d, l, 0.6, 1, 605, dt)
    T.ok(l.locked and fly, "within a few rad/s it locks")
    T.eq(l.omega, 605, "the engine is slaved to the shaft")
    T.eq(l.slip, 0, "no slip")
    T.near(tq, M.EngineTorque(d, 600 * M.RPM, 0.6), 1e-6, "and the wheel gets the engine's torque")

    -- SLIPPING: engine far above the shaft, lever half out: it passes what it can carry and no more.
    local p = M.NewEngine(d)
    p.omega = 1000
    local cap = M.ClutchCapacity(d, 0.3, 1000 * M.RPM)
    tq, fly = M.EngineStep(d, p, 0.2, 0.3, 100, dt)
    T.ok(not fly and not p.locked, "slipping")
    T.near(tq, cap, 1e-6, "it passes exactly its capacity")
    T.ok(p.omega < 1000, "and the engine, dragged, slows")
    -- ...but the tyre's grip caps it (the wheel cannot use more).
    local q = M.NewEngine(d)
    q.omega = 1000
    tq = M.EngineStep(d, q, 1, 1, 100, dt, nil, 700)
    T.eq(tq, 700, "limited to what the tyre can hold")
    -- And a lever pulled while locked lets go at once.
    local u = M.NewEngine(d)
    u.omega = 600
    M.EngineStep(d, u, 0.6, 1, 600, dt)
    T.ok(u.locked, "locked")
    tq = M.EngineStep(d, u, 0.6, 0, 600, dt)
    T.eq(tq, 0, "the lever drops it")
    T.ok(not u.locked, "open")

    -- The capacity: scales with the lever and the bite, and is nothing below it.
    T.eq(M.ClutchCapacity(d, 1, d.idle * M.RPM * 0 + d.idle), 0, "nothing at idle")
    T.near(M.ClutchCapacity(d, 1, d.engageRpm + 500), d.torque * d.clutch, 1e-6, "all of it above the bite, lever out")
    T.near(M.ClutchCapacity(d, 0.5, d.engageRpm + 500), d.torque * d.clutch * 0.5, 1e-6, "half with the lever half in")
    T.eq(M.ClutchCapacity(d, 0, d.redline), 0, "none with it pulled")
end)

T.test("engine: the dirt bike launches in first and runs up through its gears to ~2.2x the BMX", function()
    local sv, bike = ridden("dirtbike")
    local B = sv.env.BMX
    F.input(bike, { throttle = 1 })
    sv:run(1.5)
    T.eq(B.Gears.Index(bike), 1, "starts in first")
    T.ok(bike.st.speed > 60, "off the line: " .. bike.st.speed)
    T.ok(bike.st.engine.locked, "the clutch is holding")
    local peak = 0
    sv:run(14, function()
        peak = math.max(peak, bike.st.speed)
        local g = B.Gears.Index(bike)
        if bike.st.rpm > 8800 and g < 5 then B.SetGear(bike, g + 1) end
        return false
    end)
    T.eq(B.Gears.Index(bike), 5, "in top")
    local bmx = topSpeed("stock", nil, 25)
    T.between(peak / bmx, 1.9, 2.5, string.format("%.0f u/s against the BMX's %.0f", peak, bmx))
    T.between(bike.st.rpm, 9800, 10900, "on the limiter: " .. bike.st.rpm)
    T.eq(bike:GetRpm(), bike:GetRpm(), "networked rpm is a number")
    T.ok(sv.env.IsValid(bike:GetDriver()) and #sv.errors == 0, "no crash, no errors: " .. table.concat(sv.errors, " | "))
end)

T.test("engine: the shift keys change gear with the cooldown, and a held key does not run the box", function()
    local sv, bike = ridden("dirtbike")
    local B = sv.env.BMX
    T.eq(B.Shift(bike, 1), 2, "up")
    T.eq(B.Shift(bike, 1), nil, "too soon")
    sv:run(0.3)
    T.eq(B.Shift(bike, -1), 1, "down")
    T.eq(B.Gears.Label(bike), "gear 1/5", "the HUD's label")
    T.eq(B.InputMaps.moto.actions.shiftUp.buttons[1], sv.env.KEY_RBRACKET, "] is up")
end)

T.test("clutch pop: let the lever go with the throttle open and the front wheel comes up; a plain launch does not", function()
    local sv, bike = ridden("dirtbike")
    local f = F.wheels(bike)
    F.input(bike, { throttle = 1 })
    bike.input.clutch = true
    sv:run(1.5)
    T.ok(bike.st.rpm > 8000, "revved with the clutch in: " .. bike.st.rpm)
    T.ok(bike.st.speed < 5, "going nowhere")
    T.ok(bike.input.clutch and bike.st.clutchLever > 0.9, "the lever is in")
    bike.input.clutch = false
    local maxPitch, up = 0, 0
    sv:run(2.5, function()
        maxPitch = math.max(maxPitch, bike.st.pitch)
        if not f.onGround then up = up + 1 / 66 end
        return false
    end)
    T.ok(math.deg(maxPitch) > 12, "the nose came up: " .. math.deg(maxPitch) .. " deg")
    T.ok(up > 0.2, "the front wheel was in the air for " .. up .. " s")
    T.ok(sv.env.IsValid(bike:GetDriver()), "and the rider is still aboard")

    local sv2, b2 = ridden("dirtbike")
    local f2 = F.wheels(b2)
    F.input(b2, { throttle = 1 })
    local maxPitch2, up2 = 0, 0
    sv2:run(2.5, function()
        maxPitch2 = math.max(maxPitch2, b2.st.pitch)
        if not f2.onGround then up2 = up2 + 1 / 66 end
        return false
    end)
    T.ok(math.deg(maxPitch2) < 5, "the same throttle with the clutch left alone: " .. math.deg(maxPitch2) .. " deg")
    T.eq(up2, 0, "the front stays down")
end)

T.test("clutch pop: a pop with the throttle shut or the revs low is not a wheelie", function()
    local sv, bike = ridden("dirtbike")
    local f = F.wheels(bike)
    F.input(bike, { throttle = 0 })
    bike.input.clutch = true
    sv:run(1)
    bike.input.clutch = false
    local up = 0
    sv:run(1.5, function() if not f.onGround then up = up + 1 / 66 end end)
    T.eq(up, 0, "no throttle, no wheelie")
end)

T.test("clutch pop: RMB (weight back) holds it up like any wheelie", function()
    local sv, bike = ridden("dirtbike")
    local f = F.wheels(bike)
    F.input(bike, { throttle = 1 })
    bike.input.clutch = true
    sv:run(1.5)
    bike.input.clutch = false
    F.input(bike, { throttle = 0.6, pitch = 1, wheelieMod = true })
    sv:run(1.2)
    T.ok(not f.onGround, "still up a second on")
    T.ok(bike.st.pitch > math.rad(8), "held: " .. math.deg(bike.st.pitch))
    T.ok(sv.env.IsValid(bike:GetDriver()), "not looped out")
end)

T.test("clutch: the SHIFT key is the lever on a motorcycle and the sprint on a bike", function()
    local B = F.server().env.BMX
    T.eq(B.InputMaps.moto.actions.clutch.key, IN.SPEED, "SHIFT is the clutch")
    T.eq(B.InputMaps.moto.actions.sprint, nil, "a motorcycle has no sprint")
    T.eq(B.InputMaps.bike.actions.sprint.key, IN.SPEED, "the bike's is unchanged")
    T.eq(B.InputMaps.bike.actions.clutch, nil, "and has no clutch")
    local sv = F.server()
    local bike = F.bike(sv, "bmx_dirtbike")
    local ply = F.rider(sv, bike)
    local function send(buttons)
        local c = { buttons = buttons, fwd = 0, side = 0, up = 0 }
        function c:GetButtons() return self.buttons end
        function c:SetButtons(b) self.buttons = b end
        function c:GetForwardMove() return self.fwd end
        function c:GetSideMove() return self.side end
        function c:SetForwardMove(v) self.fwd = v end
        function c:SetSideMove(v) self.side = v end
        function c:SetUpMove(v) self.up = v end
        sv.env.hook.Run("StartCommand", ply, c)
    end
    send(IN.SPEED + IN.FORWARD)
    T.eq(bike.input.clutch, true, "SHIFT pulls the clutch in")
    T.eq(bike.input.sprint, false, "and is not a sprint")
    T.eq(bike.input.throttle, 1, "W is the throttle")
    send(IN.FORWARD)
    T.eq(bike.input.clutch, false, "let go")
    local b2 = F.bike(sv, "bmx_base")
    local p2 = F.rider(sv, b2, { name = "Other" })
    local c = { buttons = IN.SPEED, fwd = 0, side = 0, up = 0 }
    function c:GetButtons() return self.buttons end
    function c:SetButtons(b) self.buttons = b end
    function c:GetForwardMove() return 0 end
    function c:GetSideMove() return 0 end
    function c:SetForwardMove() end
    function c:SetSideMove() end
    function c:SetUpMove() end
    sv.env.hook.Run("StartCommand", p2, c)
    T.eq(b2.input.clutch, false, "on a BMX SHIFT is no clutch")
    T.eq(b2.input.sprint, true, "it sprints")
end)

--------------------------------------------------------------------------
-- Trials lean, FMX poses, the backflip, the landing
--------------------------------------------------------------------------

T.test("lean: the dirt bike moves its weight further and sooner than a BMX (the COM offset, G02)", function()
    local B = F.server().env.BMX
    local d, s = B.ConfigFor(B.Bikes.dirtbike), B.ConfigFor(B.Bikes.stock)
    T.ok(d.Pitch.leanShift >= s.Pitch.leanShift * 1.8, "twice the offset: " .. d.Pitch.leanShift .. " vs " .. s.Pitch.leanShift)
    T.ok(d.Pitch.leanRate > s.Pitch.leanRate, "and it comes on faster")
    -- On the plant: weight forward at a roll puts more of the load on the front wheel.
    local function frontShare(id, lean)
        local sv, bike = ridden(id)
        F.input(bike, { throttle = 0.25, leanFwd = lean })
        sv:run(2.5)
        local f, r = F.wheels(bike)
        return f.load / (f.load + r.load), bike.st.leanFwd
    end
    local back, _ = frontShare("dirtbike", false)
    local fwd, lean = frontShare("dirtbike", true)
    T.near(lean, 1, 0.01, "the lean came all the way on")
    T.ok(fwd > back + 0.02, string.format("front share %.3f leaning forward against %.3f", fwd, back))
end)

T.test("fmx: the motorcycle's poses decode (Alt in the air), a BMX's do not change", function()
    local B = F.server().env.BMX
    local D = B.DecodePose
    local function air(k, moto) k.air = true k.moto = moto return D(k) end
    T.eq(air({ alt = true, fwd = true, back = true }, true), "superman", "Alt + W + S: superman")
    T.eq(air({ alt = true, side = -1 }, true), "heelclicker", "Alt + A: a heel clicker")
    T.eq(air({ alt = true, side = 1 }, true), "heelclicker", "Alt + D")
    T.eq(air({ alt = true, back = true }, true), "cliffhanger", "Alt + S: a cliffhanger")
    T.eq(air({ alt = true, fwd = true }, true), "nohander", "Alt + W is still a no-hander")
    T.eq(air({ alt = true, rmb = true }, true), "tabletop", "and the rest are as they were")
    T.eq(air({ alt = true, side = -1 }, false), "cancan_l", "a BMX's Alt + A is a can-can")
    T.eq(air({ alt = true, back = true }, false), "nofooter", "a BMX's Alt + S is a no-footer")
    T.eq(D({ alt = true, side = 1, moto = true }), nil, "none of them on the ground")
    T.eq(air({ side = 1 }, true), nil, "and a pose needs Alt")
end)

T.test("fmx: heel clicker and cliffhanger are registered tricks with poses, wire ids and rider poses", function()
    local sv, world = F.server()
    local B = sv.env.BMX
    for _, id in ipairs({ "heel_clicker", "cliffhanger" }) do
        local t = B.Tricks[id]
        T.ok(t and t.kind == "pose", id .. " is a pose trick")
        T.ok(B.PoseIDs[t.pose], id .. " has a wire id")
        T.eq(B.TrickForPose(t.pose), t, id .. " owns its pose")
    end
    T.ok(B.PoseIDs.heelclicker ~= B.PoseIDs.cliffhanger, "distinct ids")
    local cl = F.client(world)
    T.ok(cl.env.BMX.RiderPoses.heelclicker.rFoot and cl.env.BMX.RiderPoses.cliffhanger.rFoot, "IK targets on the client")
    T.eq(cl.env.BMX.PoseSets.moto.poses, cl.env.BMX.RiderPoses, "the moto set uses the style poses")
    T.eq(B.Bikes.dirtbike.tricks, "all", "the dirt bike may do all of them")
    -- Held in the air, they pay, with a compound name over a flip.
    local st = B.NewState(B.Config)
    st.airMode = true
    B.AirReset(st)
    st.airTime = 1
    for _ = 1, 40 do
        B.TricksTick({ Bike = function() return B.Bikes.dirtbike end, GetDriver = function() return true end },
            nil, B.Config, 1 / 66, { pose = "heelclicker" }, st)
    end
    local out = B.ScoreAir(st)
    local found
    for _, t in ipairs(out) do if t.name:find("Heel Clicker", 1, true) then found = t end end
    T.ok(found, "a heel clicker held for 0.6 s is scored")
end)

T.test("fmx: the keys through the real decode on a dirt bike", function()
    local sv = F.server()
    local bike = F.bike(sv, "bmx_dirtbike")
    local ply = F.rider(sv, bike)
    local function send(buttons)
        local c = { buttons = buttons, fwd = 0, side = 0, up = 0 }
        function c:GetButtons() return self.buttons end
        function c:SetButtons(b) self.buttons = b end
        function c:GetForwardMove() return self.fwd end
        function c:GetSideMove() return self.side end
        function c:SetForwardMove(v) self.fwd = v end
        function c:SetSideMove(v) self.side = v end
        function c:SetUpMove(v) self.up = v end
        sv.env.hook.Run("StartCommand", ply, c)
    end
    bike.st.airMode = true
    send(IN.WALK + IN.MOVELEFT)
    T.eq(bike.input.pose, "heelclicker", "Alt + A on a dirt bike")
    T.eq(bike.input.leanTarget, 0, "not a roll")
    send(IN.WALK + IN.BACK)
    T.eq(bike.input.pose, "cliffhanger", "Alt + S")
    T.eq(bike.input.pitchTarget, 0, "not a backflip")
    send(IN.WALK + IN.FORWARD + IN.BACK)
    T.eq(bike.input.pose, "superman", "Alt + W + S")
    send(IN.BACK)
    T.eq(bike.input.pose, nil, "S alone is the backflip")
    T.eq(bike.input.pitchTarget, 1, "nose up")
end)

local function launched(id, vz, vx)
    local sv, bike = ridden(id)
    local E = sv.env
    F.place(bike, bike:GetPos() + E.Vector(0, 0, 30), E.Angle(0, 0, 0))
    bike:GetPhysicsObject():SetVelocity(E.Vector(vx or 250, 0, vz or 480))
    bike:GetPhysicsObject():SetAngleVelocity(E.Vector(0, 0, 0))
    bike.st.angVel, bike.st.prevF = E.Vector(0, 0, 0), nil
    F.input(bike, { throttle = 0.4 })
    return sv, bike
end

T.test("backflip: the dirt bike turns a whole backflip in the air, lands it, and is paid", function()
    local sv, bike = launched("dirtbike", 520, 220)
    local E = sv.env
    local B = E.BMX
    local K, A = bike:Cfg().Tricks, bike:Cfg().Air
    local paid
    E.hook.Add("BMX_TricksLanded", "t", function(b, ply, tricks, total) paid = { tricks = tricks, total = total } end)
    T.ok(sv:run(1, function() return bike.st.airMode end), "air mode")
    F.input(bike, { pitch = 1 })
    -- Let go the way the double-tap flip does (sv_input.lua, a little later: the plant coasts less): once the turn so far plus what
    -- the air damping will still carry reaches a whole turn, so the bike coasts round to it.
    local released = false
    sv:run(2, function()
        local w = bike.st.angVel:Dot(bike:GetRight())
        if (bike.st.spinPitch or 0) + math.abs(w) / A.damping >= K.doubleTapTurn + 0.5 then
            released = true
            return true
        end
    end)
    T.ok(released, "a whole turn was commanded")
    F.input(bike, { pitch = 0, throttle = 0 })
    sv:run(4, function() return paid ~= nil end)
    T.ok(E.IsValid(bike:GetDriver()), "rider still aboard after landing")
    T.ok(paid, "the landing paid")
    local names = {}
    for _, t in ipairs(paid and paid.tricks or {}) do names[#names + 1] = t.name end
    T.ok(table.concat(names, ","):find("Backflip", 1, true), "as a Backflip: " .. table.concat(names, ","))
end)

T.test("big jump: the dirt bike drops 250 units, lands on its wheels, and its long travel does the work", function()
    for _, id in ipairs({ "dirtbike", "emoto" }) do
        local sv, bike = ridden(id)
        local E = sv.env
        local cfg = bike:Cfg()
        F.place(bike, bike:GetPos() + E.Vector(0, 0, 250), E.Angle(0, 0, 0))
        bike:GetPhysicsObject():SetVelocity(E.Vector(280, 0, 0))
        F.input(bike, { throttle = 0.3 })
        local f, r = F.wheels(bike)
        local maxComp, crashed = 0, false
        E.hook.Add("BMX_Crash", "t", function() crashed = true end)
        sv:run(5, function()
            maxComp = math.max(maxComp, f.compression or 0, r.compression or 0)
            return false
        end)
        T.ok(not crashed and E.IsValid(bike:GetDriver()), id .. " lands a 250 u drop without a crash")
        T.ok(f.onGround and r.onGround, id .. " is on both wheels afterwards")
        T.ok(maxComp > cfg.Wheel.restLength * 0.5, string.format("%s used its travel: %.1f of %.1f", id, maxComp, cfg.Wheel.restLength))
        T.ok(math.abs(bike.st.roll) < math.rad(15), id .. " is upright again")
    end
end)

--------------------------------------------------------------------------
-- The moped
--------------------------------------------------------------------------

T.test("moped: pedal-start, then the engine takes over, about 45 km/h", function()
    local sv, bike = ridden("moped")
    local E = sv.env
    F.input(bike, { throttle = 1 })
    sv:run(0.6)
    T.ok(not bike.st.engine.started, "the engine is not running yet")
    T.eq(bike.st.rpm, 0, "silent")
    T.ok(bike.st.cadence > 0, "the legs are the drive")
    T.ok(bike.st.speed > 20, "and it is moving: " .. bike.st.speed)
    sv:run(4, function() return bike.st.engine.started end)
    T.ok(bike.st.engine.started, "the engine caught")
    T.ok(bike.st.engine.pedalled >= 4, "after the first four metres: " .. bike.st.engine.pedalled)
    sv:run(1)
    T.ok(bike.st.rpm > 1500, "and it is turning over: " .. bike.st.rpm)
    T.eq(bike.st.cadence, 0, "the pedals are no longer the drive")
    local peak = 0
    sv:run(10, function() peak = math.max(peak, bike.st.speed) return false end)
    T.between(E.BMX.ToKMH(peak), 40, 50, "its top speed, km/h: " .. E.BMX.ToKMH(peak))
    -- Get off: the engine is cold again and wants the pedals.
    bike.input.throttle = 0
    local ply = F.rider(sv, bike, { name = "Second" })
end)

T.test("moped: a fresh rider has to pedal it off again", function()
    local sv, bike, ply = ridden("moped")
    F.input(bike, { throttle = 1 })
    sv:run(5)
    T.ok(bike.st.engine.started, "running")
    F.input(bike, {})
    ply:ExitVehicle()
    sv:run(1)
    T.ok(not bike.st.engine.started, "off when nobody is on it")
    T.eq(bike:GetRpm(), 0, "and silent")
end)

--------------------------------------------------------------------------
-- The sound
--------------------------------------------------------------------------

T.test("sound: the motor and engines are the addon's own loops, and the pitch follows the rpm", function()
    local _, world = F.server()
    local cl = F.client(world)
    local B = cl.env.BMX
    for _, key in ipairs({ "motor", "engine", "engine2t" }) do
        local S = B.Sounds[key]
        T.ok(S, key .. " is in the table")
        T.ok(S.path:match("^bmx/[%w_]+%.wav$"), key .. " is the addon's own (sound/bmx/): " .. S.path)
        T.ok(not S.variants and not S.path:find("%%d"), key .. " is a loop, with no variants")
        -- A loop is a WAV with a cue point: Source plays a file without one once, and stops.
        local f = io.open("sound/" .. S.path, "rb")
        T.ok(f ~= nil, key .. ": the file is in the repository")
        if f then
            local raw = f:read("*a")
            f:close()
            T.ok(raw:sub(1, 4) == "RIFF" and raw:find("cue ", 13, true) ~= nil, key .. ": a WAV with a loop cue")
        end
        -- An engine across idle-ish to redline-ish; the whine across its range.
        local top = S.baseRpm and S.baseRpm * 2 or 1000
        local lo, vlo = B.MotorSoundParams(key, top * 0.15, top)
        local mid, vmid = B.MotorSoundParams(key, top * 0.5, top)
        local hi, vhi = B.MotorSoundParams(key, top, top)
        T.ok(lo < mid and mid < hi, key .. ": pitch rises with rpm: " .. lo .. " < " .. mid .. " < " .. hi)
        T.ok(vlo < vmid and vmid < vhi, key .. ": and so does the volume")
        if S.baseRpm then
            -- An engine's note is its firing rate: at the rpm its file was made at,
            -- it plays at 100 %, and twice the rpm is twice the pitch.
            T.near(B.MotorSoundParams(key, S.baseRpm, 9000), 100, 1e-9, key .. ": 100 % at its baseRpm")
            T.near(B.MotorSoundParams(key, S.baseRpm * 2, 20000), 200, 1e-9, key .. ": and pitch is proportional to rpm")
        else
            T.near(hi, S.pitch[2], 1e-9, key .. ": the top of the range at the top rpm")
        end
        local _, silent = B.MotorSoundParams(key, 0, 1000)
        T.eq(silent, 0, key .. ": silent at zero rpm")
    end
    -- Each vehicle its own note: the dirt bike a four-stroke, the moped a two-stroke,
    -- the e-bike and the e-moto the whine.
    T.eq(B.MotorSoundKey(B.Bikes.dirtbike), "engine", "dirt bike: the four-stroke")
    T.eq(B.MotorSoundKey(B.Bikes.moped), "engine2t", "moped: the two-stroke")
    T.eq(B.MotorSoundKey(B.Bikes.ebike), "motor", "e-bike: the whine")
    T.eq(B.MotorSoundKey(B.Bikes.emoto), "motor", "e-moto: the whine")
end)

T.test("sound: a motor vehicle plays its loop at the networked rpm, and a BMX plays none of it", function()
    local sv, world = F.server()
    local cl = F.client(world)
    local E = cl.env
    local function scene(class)
        local cb = cl:clientEntity(class)
        local pod = cl.makeEntity("prop_vehicle_prisoner_pod")
        pod:SetParent(cb)
        cb:SetPod(pod)
        cb:SetGrounded(true)
        return cb
    end
    local e = scene("bmx_ebike")
    local function patch(path)
        for _, p in ipairs(cl.patches) do if p.path == path then return p end end
    end
    e:SetRpm(0)
    cl:run(0.2)
    local whine = patch(E.BMX.Sounds.motor.path)
    T.ok(not whine or not whine.playing, "silent at rest")
    e:SetRpm(1500)
    cl:run(0.2)
    whine = patch(E.BMX.Sounds.motor.path)
    T.ok(whine and whine.playing, "the whine plays")
    local p1 = whine.pitch
    e:SetRpm(2600)
    cl:run(0.3)
    T.ok(whine.pitch > p1, string.format("and rises with rpm: %.0f -> %.0f", p1, whine.pitch))
    E.GetConVar("bmx_vol_ride"):SetString("0")
    cl:run(0.2)
    T.ok(not whine.playing, "bmx_vol_ride 0 stops it")
    E.GetConVar("bmx_vol_ride"):SetString("1")
    cl:run(0.2)
    T.ok(whine.playing, "and back")
    cl.world.convars.bmx_sounds:SetString("0")
    cl:run(0.2)
    T.ok(not whine.playing, "bmx_sounds 0 mutes it")
    cl.world.convars.bmx_sounds:SetString("1")
    -- The dirt bike has its own note.
    local d = scene("bmx_dirtbike")
    d:SetRpm(8000)
    cl:run(0.3)
    local note = patch(E.BMX.Sounds.engine.path)
    T.ok(note and note.playing, "the engine note plays")
    T.near(note.pitch, 100 * 8000 / E.BMX.Sounds.engine.baseRpm, 1, "at 8000 rpm, pitched to the rpm")
    -- THE MOPED IS SILENT UNTIL THE PEDALS START IT: sat on, 0 rpm, it is pedalled;
    -- it does not idle. Once it has caught, its two-stroke plays.
    local m = scene("bmx_moped")
    local mp = cl.makeEntity("player")
    m:SetDriver(mp)
    m:SetRpm(0)
    cl:run(0.3)
    local buzz = patch(E.BMX.Sounds.engine2t.path)
    T.ok(not buzz or not buzz.playing, "a moped being pedalled has no engine note yet")
    m:SetRpm(3000)
    cl:run(0.3)
    buzz = patch(E.BMX.Sounds.engine2t.path)
    T.ok(buzz and buzz.playing, "and once it has caught, the two-stroke plays")
end)
