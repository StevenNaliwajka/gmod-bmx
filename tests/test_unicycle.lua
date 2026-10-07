--[[--------------------------------------------------------------------------
    The unicycle (G13): one wheel, a fixed gear and nothing to hold it up but the
    rider, balanced on two axes by the `unicycle` mode (sv_unicycle.lua) with
    bmx_unicycle_assist doing a share of the work.

    What is tested: that it registers (and that the registry's new vocabulary rejects
    what it should), that a rider with an ASSIST CONTROLLER on the offline plant holds it
    up for ten seconds, standing and riding, and that without the controller the assist
    is what decides whether it stands; that S is its brake; that the mouse twists it;
    the idle and hop tricks; the stand holding it parked; that it falls and the rider is
    thrown; and that it is drawn.

    The plant is a rigid body that is right in kind (tests/lib/gmod.lua), not VPhysics:
    these say the controller is built the right way round and the numbers are in a
    sensible band, and the headless case (unicycle_balances, sv_test_cases.lua) is the
    authority on a real engine.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local gmod = require("lib.gmod")
local IN = gmod.IN

local function classOf(sv, id) return sv.env.BMX.ClassFor(id) end

-- A unicycle with a scripted rider on it, settled.
local function ridden(assist)
    local sv, world = F.server()
    local B = sv.env.BMX
    local cfg = B.ConfigFor(B.Bikes.unicycle)
    local bike = F.bike(sv, classOf(sv, "unicycle"),
        sv.env.Vector(0, 0, sv.world.groundZ + B.RestHeight(cfg)))
    local ply = F.scripted(sv, bike)
    if assist then sv.env.GetConVar("bmx_unicycle_assist"):SetString(tostring(assist)) end
    sv:run(0.5)
    return sv, bike, ply, world
end

-- THE RIDER, as a controller: the keys a person would press to keep it up. Lean against
-- the roll (A / D), pedal against the pitch (W / S), with a little of the rate for phase
-- lead, plus whatever `base` pedalling and `lean0` the ride asks for. This is the "assist
-- controller" of the goal: it needs no knowledge of the plant beyond what the HUD shows.
local function rider(e, base, lean0, kr, kp)
    local st = e.st
    kr, kp = kr or 4, kp or 4
    local lean = math.max(-1, math.min(1, (lean0 or 0) - kr * (st.roll + 0.15 * st.rollRate)))
    local thr = math.max(-1, math.min(1, (base or 0) - kp * (st.pitch + 0.15 * st.pitchRate)))
    F.input(e, { lean = lean, throttle = math.max(thr, 0), brakeRear = math.max(-thr, 0) })
end

-- Step the plant a tick at a time with the rider's controller, for `secs`. Returns whether
-- the rider was still aboard, and the worst lean and pitch seen.
local function ride(sv, e, secs, base, lean0, ctl, each)
    local worstR, worstP = 0, 0
    for i = 1, math.floor(secs * 66) do
        if ctl ~= false then rider(e, base, lean0) end
        if each then each(i) end
        sv:run(1 / 66)
        worstR = math.max(worstR, math.abs(e.st.roll))
        worstP = math.max(worstP, math.abs(e.st.pitch))
        if not sv.env.IsValid(e:GetDriver()) then return false, worstR, worstP, i / 66 end
    end
    return true, worstR, worstP, secs
end

-- A shove: angular velocity about forward and right, deg/s.
local function kick(sv, e, roll, pitch)
    e:GetPhysicsObject():SetAngleVelocity(sv.env.Vector(roll or 0, pitch or 0, 0))
end

--------------------------------------------------------------------------
-- The registry
--------------------------------------------------------------------------

T.test("unicycle: it registers clean: one wheel, a fixed drive that reverses, its own balance, map, pose and tricks", function()
    local sv = F.server()
    local B = sv.env.BMX
    local d = B.Bikes.unicycle
    T.ok(d, "registered")
    T.eq(#sv.errors, 0, "nothing rejected: " .. table.concat(sv.errors, " | "))
    T.eq(#d.wheels, 1, "one wheel")
    T.ok(d.wheels[1].drive, "and it is the drive wheel")
    T.ok(not d.wheels[1].steer, "which does not steer")
    T.eq(d.balance, "unicycle", "its own balance mode")
    T.ok(B.BalanceModes.unicycle, "which has a module")
    T.eq(d.drive.kind, "fixed", "a fixed gear")
    T.eq(d.drive.reverse, true, "that pedals backwards instead of braking")
    T.eq(d.input, "unicycle", "its own map")
    T.ok(B.InputMaps.unicycle.actions.back, "which has S")
    T.ok(not B.InputMaps.unicycle.actions.brakeFront, "and no front brake")
    T.eq(d.pose, "unicycle", "its own pose set")
    T.eq(d.tricks[1], "uni_idle", "idle")
    T.eq(d.tricks[2], "uni_hop", "and hop")
    T.eq(d.drawer, "unicycle", "drawn in code")
    T.eq(d.family, "bike", "a bike for the menu and bmx_allow_bikes")
    T.eq(B.ClassFor("unicycle"), "bmx_unicycle", "its class")
    T.eq(sv.lists.SpawnableEntities.bmx_unicycle.Subcategory, "Bikes", "in the spawn menu under Bikes")
    T.ok(sv.dupe.bmx_unicycle, "the duplicator knows it")
    T.ok(B.Tricks.uni_idle and B.Tricks.uni_hop, "its tricks are registered")
end)

local function one(E, over)
    local d = {
        id = "uni_t", family = "bike", printName = "x",
        wheels = { { pos = E.Vector(0, 0, 0), drive = true } },
        balance = "unicycle", drive = { kind = "fixed", reverse = true }, input = "unicycle", pose = "unicycle",
        tricks = {}, grindPoints = false,
    }
    for k, v in pairs(over or {}) do d[k] = v end
    return d
end

T.test("unicycle: the registry's new vocabulary is accepted", function()
    local sv = F.server()
    local B, E = sv.env.BMX, sv.env
    T.ok(B.RegisterVehicle(one(E)), "a one-wheeled unicycle")
    T.ok(B.RegisterVehicle(one(E, { id = "uni_u", drive = { kind = "fixed" } })), "a fixed drive with no reverse")
    T.ok(B.RegisterVehicle(one(E, { id = "uni_v", drawer = "unicycle" })), "a drawer by id")
    T.ok(B.RegisterVehicle(one(E, { id = "uni_w", seats = { pegs = { pedals = true } } })), "a seat that pedals")
    T.eq(#sv.errors, 0, table.concat(sv.errors, " | "))
end)

local BAD = {
    { "a unicycle with two wheels",   function(d, E) d.wheels[2] = { pos = E.Vector(-10, 0, 0) } end,    "exactly one wheel" },
    { "reverse that is a word",       function(d) d.drive = { kind = "fixed", reverse = "yes" } end,     "reverse" },
    { "reverse on a pedal drive",     function(d) d.drive = { kind = "pedal", reverse = true } end,      "reverse" },
    { "a drawer that is a number",    function(d) d.drawer = 3 end,                                      "drawer" },
    { "pedals that are a number",     function(d) d.seats = { pegs = { pedals = 1 } } end,               "pedals" },
    { "a balance mode nobody wrote",  function(d) d.balance = "gyro" end,                                "balance" },
}
for _, c in ipairs(BAD) do
    T.test("unicycle: rejected, loudly: " .. c[1], function()
        local sv = F.server()
        local B, E = sv.env.BMX, sv.env
        local d = one(E)
        c[2](d, E)
        T.eq(B.RegisterVehicle(d), false, "refused")
        T.ok(#sv.errors > 0 and sv.errors[1]:find(c[3], 1, true), "reported with `" .. c[3] .. "`: " .. tostring(sv.errors[1]))
        T.ok(not B.Vehicles.uni_t, "and not registered")
    end)
end

T.test("unicycle: bmx_spawn unicycle spawns it, built, and respects bmx_allow_bikes", function()
    local sv = F.server()
    local ply = sv:player("Spawner")
    ply:SetPos(sv.env.Vector(0, 0, 0))
    ply._eyeTrace = { Hit = true, HitPos = sv.env.Vector(100, 0, 0), HitNormal = sv.env.Vector(0, 0, 1) }
    sv:command("bmx_spawn", ply, "unicycle")
    local found = sv.env.ents.FindByClass("bmx_unicycle")
    T.eq(#found, 1, "one")
    T.ok(found[1]:AssertBuilt(), "built")
    T.eq(#found[1].wheels, 1, "with one wheel")
    sv.env.GetConVar("bmx_allow_bikes"):SetString("0")
    sv.world.time = sv.world.time + 2
    sv:command("bmx_spawn", ply, "unicycle")
    T.eq(#sv.env.ents.FindByClass("bmx_unicycle"), 1, "switched off: no second")
    T.eq(sv.env.hook.Run("PlayerSpawnSENT", ply, "bmx_unicycle"), false, "and the menu's door is shut")
end)

T.test("unicycle: bmx_unicycle_assist is a server setting with a row, default 0.6, clamped to 0..1", function()
    local sv = F.server()
    local B = sv.env.BMX
    local row = B.Settings.Get("bmx_unicycle_assist")
    T.ok(row, "it has a row in the Options menu")
    T.eq(row.kind, "float", "a float")
    T.eq(row.scope, "server", "the server's")
    T.near(row.default, 0.6, 1e-9, "default")
    T.near(B.UnicycleAssist(), 0.6, 1e-9, "and it is that")
    sv.env.GetConVar("bmx_unicycle_assist"):SetString("7")
    T.eq(B.UnicycleAssist(), 1, "7 is 1")
    sv.env.GetConVar("bmx_unicycle_assist"):SetString("-3")
    T.eq(B.UnicycleAssist(), 0, "-3 is 0")
end)

--------------------------------------------------------------------------
-- The hull and the rest height of a one-wheeled vehicle
--------------------------------------------------------------------------

T.test("unicycle: one wheel box in the hull, the mass centre where the balance expects it, resting on its wheel", function()
    local sv, e = ridden()
    local B = sv.env.BMX
    local C = e:Cfg()
    -- (A bike's hull has a box for each wheel; a unicycle's has one, not two on top of each other.)
    local boxes = B.CollisionBoxes(C)
    local wheelBoxes = 0
    for _, b in ipairs(boxes) do
        if math.abs((b[2].x - b[1].x) - 2 * C.Wheel.radius) < 1e-6 then wheelBoxes = wheelBoxes + 1 end
    end
    T.eq(wheelBoxes, 1, "one wheel box")
    local mc = e:GetPhysicsObject():GetMassCenter()
    T.near(mc.x, C.Chassis.massCenterExpected.x, 0.5, "mass centre x")
    T.near(mc.z, C.Chassis.massCenterExpected.z, 0.5, "mass centre z")
    T.ok(e.wheels[1].onGround, "on the ground")
    T.eq(#e.wheels, 1, "one wheel")
    -- ONE wheel carries all of it: the sag is m*g/spring, and the rest height was derived from it.
    local sag = C.Chassis.mass * 600 / C.Wheel.spring
    T.near(e:GetPos().z, sv.world.groundZ + C.Wheel.radius - sag, 0.6, "the origin sits one radius up less the sag of the WHOLE weight")
    T.ok(math.abs(e.st.pitch) < 0.01 and math.abs(e.st.roll) < 0.01, "upright")
end)

--------------------------------------------------------------------------
-- BALANCE: the assist, and a rider
--------------------------------------------------------------------------

T.test("balance: a rider on the assist controller holds it for 10 s at the default assist, after a shove", function()
    local sv, e = ridden()
    T.near(sv.env.BMX.UnicycleAssist(), 0.6, 1e-9, "the default assist")
    kick(sv, e, 30, 30)
    local aboard, wr, wp = ride(sv, e, 10)
    T.ok(aboard, "still aboard after 10 s")
    T.ok(wr < math.rad(12), "roll never past 12 deg: " .. math.deg(wr))
    T.ok(wp < math.rad(12), "pitch never past 12 deg: " .. math.deg(wp))
    T.ok(math.abs(e.st.roll) < math.rad(2) and math.abs(e.st.pitch) < math.rad(2), "and upright at the end")
end)

T.test("balance: the same rider holds it riding, pedalling forward at a steady pace for 10 s", function()
    local sv, e = ridden()
    local aboard, wr, wp = ride(sv, e, 10, 0.5)
    T.ok(aboard, "still aboard")
    T.ok(e.st.speed > 60, "and going: " .. e.st.speed)
    T.ok(wr < math.rad(12) and wp < math.rad(14), "lean " .. math.deg(wr) .. ", pitch " .. math.deg(wp))
    local aboard2 = ride(sv, e, 4, -0.5)
    T.ok(aboard2, "and back the other way")
end)

T.test("balance: the controller holds it at LOW assist (0.2), where the assist alone would not", function()
    local sv, e = ridden(0.2)
    kick(sv, e, 30, 30)
    local aboard, wr = ride(sv, e, 10)
    T.ok(aboard, "a rider holds it up at 0.2: lean " .. math.deg(wr))
end)

T.test("balance: with nobody correcting it, the assist is what decides: 0.6 stands, 0.1 falls and throws the rider", function()
    local sv, e = ridden(0.6)
    kick(sv, e, 30, 30)
    local aboard, wr = ride(sv, e, 10, 0, 0, false)
    T.ok(aboard, "at 0.6 it stands with nobody correcting it: " .. math.deg(wr))
    T.ok(wr < math.rad(8), "and the wobble is small: " .. math.deg(wr))

    local sv2, e2 = ridden(0.1)
    local crashed = {}
    sv2.env.hook.Add("BMX_Crashed", "t", function(b, ply, why) crashed[#crashed + 1] = why end)
    kick(sv2, e2, 30, 30)
    local aboard2, _, _, t = ride(sv2, e2, 10, 0, 0, false)
    T.ok(not aboard2, "at 0.1 it falls and the rider is off")
    T.ok(t > 0.2 and t < 10, "after a moment: " .. t)
    T.eq(crashed[1], "tipped", "thrown by the tip rule, as a fall")
end)

T.test("balance: assist 1 is a vehicle that cannot fall: a hard shove is caught", function()
    local sv, e = ridden(1)
    kick(sv, e, 150, 150)
    local aboard, wr = ride(sv, e, 6, 0, 0, false)
    T.ok(aboard, "caught: " .. math.deg(wr))
end)

T.test("balance: the assist is monotonic: the less of it, the sooner it falls", function()
    local fell = {}
    for _, a in ipairs({ 0.0, 0.1, 0.2 }) do
        local sv, e = ridden(a)
        kick(sv, e, 30, 30)
        local aboard, _, _, t = ride(sv, e, 12, 0, 0, false)
        fell[#fell + 1] = aboard and 99 or t
    end
    T.ok(fell[1] <= fell[2] + 0.4 and fell[2] <= fell[3] + 0.4, string.format("times to fall at 0, 0.1, 0.2: %.2f %.2f %.2f", fell[1], fell[2], fell[3]))
    T.ok(fell[1] < 6, "no assist falls fast: " .. fell[1])
end)

T.test("balance: a rider who lets go while riding at 0.6 is carried on by the assist and settles", function()
    local sv, e = ridden(0.6)
    ride(sv, e, 4, 0.6)
    F.input(e, {})
    local aboard, wr = ride(sv, e, 6, 0, 0, false)
    T.ok(aboard, "still aboard")
    T.ok(wr < math.rad(14), "lean " .. math.deg(wr))
end)

T.test("balance: its inertia is allowed to be whatever the engine measures: the hold is a fraction of the toppling's gradient", function()
    -- The spring is hold * (m g h / I), so scaling the inertia moves the break-even assist not
    -- at all. 0.6 stands, and 0.1 falls, with the inertia 30% either way.
    for _, k in ipairs({ 0.7, 1.3 }) do
        local sv, e = ridden(0.6)
        e.I = sv.env.Vector(e.I.x * k, e.I.y * k, e.I.z)
        kick(sv, e, 30, 30)
        local aboard = ride(sv, e, 6, 0, 0, false)
        T.ok(aboard, "stands at 0.6 with the inertia x" .. k)
        local sv2, e2 = ridden(0.1)
        e2.I = sv2.env.Vector(e2.I.x * k, e2.I.y * k, e2.I.z)
        kick(sv2, e2, 30, 30)
        local aboard2 = ride(sv2, e2, 8, 0, 0, false)
        T.ok(not aboard2, "falls at 0.1 with the inertia x" .. k)
    end
end)

--------------------------------------------------------------------------
-- Pedalling and the brake
--------------------------------------------------------------------------

T.test("pedals: W accelerates it, to the legs' ceiling; the top speed is a unicycle's", function()
    local sv, e = ridden()
    local aboard = ride(sv, e, 8, 1)
    T.ok(aboard, "aboard")
    local top = e.st.speed
    T.between(top, 90, 160, "top speed u/s")
    T.ok(e.st.fwdSpeed > 0, "forwards")
end)

T.test("pedals: S has no brake in it: it pedals BACKWARDS at any speed, and stops it, then reverses it", function()
    local sv, e = ridden()
    ride(sv, e, 6, 0.8)
    local v0 = e.st.fwdSpeed
    T.ok(v0 > 80, "up to speed: " .. v0)
    local _, r = e.wheels[1], e.wheels[1]
    local t = 0
    local stopped
    local aboard = ride(sv, e, 6, -1, 0, true, function(i)
        t = i / 66
        if not stopped and e.st.fwdSpeed < 5 then stopped = t end
    end)
    T.ok(aboard, "aboard through it")
    T.ok(stopped and stopped < 4, "stopped within 4 s: " .. tostring(stopped))
    T.ok(e.st.fwdSpeed < 0, "and then rolling back: " .. e.st.fwdSpeed)
    T.ok(not e:GetSkidding(), "it does not skid: there is no brake to skid with")
end)

T.test("pedals: the rear brake is dropped on S, whatever the speed (the fixed drive's `reverse`)", function()
    local sv, e = ridden()
    local B = sv.env.BMX
    local w = e.wheels[1]
    w.omega = 12
    e.input.brakeRear = 1
    local tq, say = B.Drives.fixed(e, e:Cfg(), 1 / 66, e.input, e.st, w, e:Bike())
    T.eq(say, false, "the drive says: no rear brake")
    T.ok(tq < 0, "and its torque is the legs pushing back: " .. tq)
    local fix = sv.env.BMX.Bikes.fixie
    T.ok(fix, "(the fixie, which does not reverse, is unchanged)")
end)

--------------------------------------------------------------------------
-- Turning: the lean and the mouse
--------------------------------------------------------------------------

local function yawOf(e) return e:GetAngles().y end

T.test("turning: D leans it right and it turns right; A the other way", function()
    local result = {}
    for _, side in ipairs({ 1, -1 }) do
        local sv, e = ridden()
        ride(sv, e, 4, 0.7)
        local y0 = yawOf(e)
        ride(sv, e, 3, 0.5, side * 0.6)
        local dy = math.AngleDifference and math.AngleDifference(yawOf(e), y0) or (yawOf(e) - y0)
        result[side] = dy
    end
    T.ok(result[1] < -15, "right is a drop in yaw: " .. result[1])
    T.ok(result[-1] > 15, "left is a rise: " .. result[-1])
end)

T.test("turning: the mouse twists it round on the spot, and the other way for the other direction", function()
    local out = {}
    for _, dir in ipairs({ 1, -1 }) do
        local sv, e = ridden()
        e.input.mouseX = 4 * dir
        local y0 = yawOf(e)
        local aboard = ride(sv, e, 1.5)
        local dy = yawOf(e) - y0
        while dy > 180 do dy = dy - 360 end
        while dy < -180 do dy = dy + 360 end
        T.ok(aboard, "aboard while twisting")
        out[dir] = dy
    end
    T.ok(out[1] < -20, "mouse right turns it right (yaw falls): " .. out[1])
    T.ok(out[-1] > 20, "mouse left turns it left: " .. out[-1])
end)

T.test("turning: with the mouse still it does not spin on its own", function()
    local sv, e = ridden()
    local y0 = yawOf(e)
    ride(sv, e, 4)
    T.near(yawOf(e), y0, 2, "no drift in yaw")
end)

--------------------------------------------------------------------------
-- The usercmd: the mouse, and only for a unicycle
--------------------------------------------------------------------------

local function cmd(buttons, mouseX)
    local c = { buttons = buttons or 0, fwd = 0, side = 0, up = 0, mx = mouseX or 0 }
    function c:GetButtons() return self.buttons end
    function c:SetButtons(b) self.buttons = b end
    function c:GetForwardMove() return self.fwd end
    function c:GetSideMove() return self.side end
    function c:GetMouseX() return self.mx end
    function c:SetForwardMove(v) self.fwd = v end
    function c:SetSideMove(v) self.side = v end
    function c:SetUpMove(v) self.up = v end
    return c
end

T.test("usercmd: a unicycle's rider's W, S, A, D and mouse are read; S is a pedal, not a brake", function()
    local sv = F.server()
    local B = sv.env.BMX
    local e = F.bike(sv, classOf(sv, "unicycle"))
    local ply = F.rider(sv, e)
    sv.env.hook.Run("StartCommand", ply, cmd(IN.FORWARD, 12))
    T.eq(e.input.throttle, 1, "W is the throttle")
    T.eq(e.input.mouseX, 12, "the mouse's movement is read")
    sv.env.hook.Run("StartCommand", ply, cmd(IN.BACK, -7))
    T.eq(e.input.brakeRear, 1, "S is read (as the backwards pedal: the drive turns it)")
    T.eq(e.input.mouseX, -7, "the mouse again")
    sv.env.hook.Run("StartCommand", ply, cmd(IN.MOVERIGHT, 0))
    T.eq(e.input.leanTarget, 1, "D is the lean")
    sv.env.hook.Run("StartCommand", ply, cmd(IN.ATTACK, 0))
    T.eq(e.input.brakeFront, 0, "there is no front brake")
end)

T.test("usercmd: a bike's rider's mouse is not read (they steer with A and D)", function()
    local sv = F.server()
    local e = F.bike(sv, classOf(sv, "stock"))
    local ply = F.rider(sv, e)
    sv.env.hook.Run("StartCommand", ply, cmd(IN.FORWARD, 12))
    T.eq(e.input.mouseX, nil, "nothing stored")
end)

--------------------------------------------------------------------------
-- The tricks
--------------------------------------------------------------------------

T.test("tricks: a hop is paid, once, as it leaves the ground", function()
    local sv, e = ridden()
    local B = sv.env.BMX
    local names = {}
    sv.env.hook.Add("BMX_TrickLanded", "t", function(ply, t) names[#names + 1] = t.name end)
    ride(sv, e, 1)
    T.eq(e:GetScore(), 0, "nothing yet")
    e.hopHeld, e.hopCharge = true, 0
    ride(sv, e, e:Cfg().Hop.chargeTime + 0.05)
    e.hopRelease = true
    local up = false
    ride(sv, e, 1.2, 0, 0, true, function() if not e.st.grounded then up = true end end)
    T.ok(up, "it left the ground")
    T.eq(names[1], "Unicycle Hop", "and was paid under its name: " .. tostring(names[1]))
    T.eq(e:GetScore(), e:Cfg().Unicycle.hopPoints, "its points")
    T.eq(#names, 1, "once")
    T.ok(sv.env.IsValid(e:GetDriver()), "still aboard after the landing")
end)

T.test("tricks: idle is rocking in place, paid a second at a time; riding is not idle", function()
    local sv, e = ridden()
    local names = {}
    sv.env.hook.Add("BMX_TrickLanded", "t", function(ply, t) names[#names + 1] = t.name end)
    -- A rider who rolls along pedalling steadily is not idle.
    ride(sv, e, 5, 0.7)
    T.eq(#names, 0, "riding pays nothing")

    -- Rock: forward, back, forward, back, at a standstill, a third of a second at a time. On
    -- a fresh vehicle, the assist (0.6) keeping it up while the rider's pedalling is just rocking.
    local sv2, e2 = ridden()
    local names2 = {}
    sv2.env.hook.Add("BMX_TrickLanded", "t", function(ply, t) names2[#names2 + 1] = t.name end)
    local dir, peak = 1, 0
    local aboard, wr = ride(sv2, e2, 9, 0, 0, false, function(i)
        if i % 22 == 0 then dir = -dir end
        F.input(e2, { throttle = dir > 0 and 0.25 or 0, brakeRear = dir < 0 and 0.25 or 0 })
        peak = math.max(peak, e2.st.speed)
    end)
    T.ok(aboard, "aboard: " .. math.deg(wr))
    T.ok(peak < e2:Cfg().Unicycle.idleSpeed + 5, "it stayed in place: " .. peak)
    T.ok(#names2 >= 2, "idle paid " .. #names2 .. " times over 9 s")
    T.eq(names2[1], "Idle", "under its name")
    T.eq(e2:GetScore(), #names2 * e2:Cfg().Unicycle.idlePoints, "its points a second")
end)

T.test("tricks: they are the unicycle's alone: a bike rocking back and forth does not score idle", function()
    local sv = F.server()
    local B = sv.env.BMX
    local e = F.bike(sv, classOf(sv, "stock"))
    F.scripted(sv, e)
    sv:run(0.5)
    for i = 1, 6 do
        F.input(e, { throttle = (i % 2 == 0) and 1 or 0, brakeRear = (i % 2 == 1) and 1 or 0 })
        sv:run(0.4)
    end
    T.eq(e:GetScore(), 0, "no idle on a bike")
end)

--------------------------------------------------------------------------
-- Parked, fallen, ragdolled
--------------------------------------------------------------------------

T.test("parked: with nobody aboard and the stand down it is held upright, and a hard enough shove knocks it over", function()
    local sv = F.server()
    local B = sv.env.BMX
    local cfg = B.ConfigFor(B.Bikes.unicycle)
    local e = F.bike(sv, classOf(sv, "unicycle"), sv.env.Vector(0, 0, sv.world.groundZ + B.RestHeight(cfg)))
    sv:run(3)
    T.ok(math.abs(e.st.roll) < math.rad(1) and math.abs(e.st.pitch) < math.rad(1), "stands by itself")
    T.ok(e.st.onStand, "held by its stand")
    e:GetPhysicsObject():SetAngleVelocity(sv.env.Vector(25, 0, 0))
    sv:run(3)
    T.ok(math.abs(e.st.roll) < math.rad(2), "a small knock is held")
    e:GetPhysicsObject():SetAngleVelocity(sv.env.Vector(1200, 0, 0))
    sv:run(5)
    T.ok(math.abs(e.st.roll) > math.rad(40), "a hard one puts it on the ground: " .. math.deg(e.st.roll))
end)

T.test("parked: let go of at speed it has no stand and falls", function()
    local sv, e = ridden()
    ride(sv, e, 5, 0.8)
    e:GetDriver():ExitVehicle()
    e:SetStandDown(false)
    sv:run(8)
    T.ok(math.abs(e.st.roll) > math.rad(30) or math.abs(e.st.pitch) > math.rad(30), "down: " .. math.deg(e.st.roll) .. " / " .. math.deg(e.st.pitch))
end)

T.test("falling: the rider is thrown as a ragdoll, and a rider who lets go of it comes off it after the tip rule's time", function()
    local sv, e, ply = ridden(0)
    local thrown, tumbled = {}, {}
    sv.env.hook.Add("BMX_RiderCrashed", "t", function(p, v, b) thrown[#thrown + 1] = p return true end)
    kick(sv, e, 40, 0)
    local aboard, _, _, t = ride(sv, e, 6, 0, 0, false)
    T.ok(not aboard, "off")
    T.eq(#thrown, 1, "BMX_RiderCrashed fired once: the ragdoll hook has the rider")
    T.ok(thrown[1] == ply, "for the rider")
end)

T.test("falling: a landing is caught: a hop lands upright at the default assist, with a rider on the controller", function()
    local sv, e = ridden()
    e.hopHeld, e.hopCharge = true, 0
    ride(sv, e, e:Cfg().Hop.chargeTime + 0.05)
    e.hopRelease = true
    local aboard = ride(sv, e, 4)
    T.ok(aboard, "aboard through the hop")
    T.ok(e.st.grounded, "and on the wheel")
end)

--------------------------------------------------------------------------
-- The client: it is drawn
--------------------------------------------------------------------------

T.test("client: it draws itself: one wheel, a fork, a saddle, cranks, and records where the feet and hands go", function()
    local sv, world = F.server()
    local B = sv.env.BMX
    local bike = F.bike(sv, classOf(sv, "unicycle"))
    local cl = F.client(world)
    local cb = cl:clientEntity("bmx_unicycle")
    cb:SetPos(bike:GetPos())
    cb:SetAngles(bike:GetAngles())
    for k, v in pairs(bike._nw) do cb._nw[k] = v end
    cl.lines, cl.beams, cl.drawnModels, cl.boxes3d = 0, {}, 0, 0
    cl.drawnCS = {}
    cb:Draw()
    T.ok(cb.ikTargets, "the IK targets are recorded")
    for _, k in ipairs({ "rFoot", "lFoot", "rHand", "lHand" }) do T.ok(cb.ikTargets[k], k) end
    T.ok(#cl.beams + (cl.drawnModels or 0) + #(cl.drawnCS or {}) > 10, "something was drawn")
    -- and not a second wheel: one tyre model.
    local tyres = 0
    for _, d in ipairs(cl.drawnCS or {}) do if d.model == "models/props_phx/wheels/moped_tire.mdl" then tyres = tyres + 1 end end
    T.ok(tyres <= 1, "at most one tyre drawn: " .. tyres)
end)
