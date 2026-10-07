--[[--------------------------------------------------------------------------
    The skateboard (G23, sh_board.lua, sh_boards.lua, sv_board.lua, cl_board.lua):
    the registration, the pure functions the simulation and the tests share (the
    truck formula, the push, the pop, stance and fakie), and closed-loop rides on
    the plant: pushing to speed, carving without tipping, an ollie.

    WHAT THE PLANT CAN AND CANNOT TELL YOU. It runs the real wheel, balance and
    physics-step code against a rigid body on a plane, so it is right about
    stability, direction and magnitude. It is not VPhysics and it has no rider, so
    how a board FEELS is for the headless cases (sv_test_cases.lua) and a human.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local function gravity(sv) return sv.world.gravity end

-- A board resting on the plant, upright, facing +X. Four wheels carry the weight,
-- so the static sag is m g / 4 / k.
local function board(sv, at)
    local B = sv.env.BMX
    local cfg = B.ConfigFor(B.Vehicles.skateboard)
    local sag = cfg.Chassis.mass * gravity(sv) / 4 / cfg.Wheel.spring
    local e = F.bike(sv, "bmx_skateboard",
        at or sv.env.Vector(0, 0, sv.world.groundZ + cfg.Wheel.radius - sag))
    return e
end

local function ridden(opts)
    local sv = F.server(opts)
    local e = board(sv)
    F.scripted(sv, e)
    sv:run(0.6)
    return sv, e
end

-- Write the standard input and the board record, the way a scripted rider (the
-- bot, the headless harness) does. Anything omitted is neutral.
local function press(e, t)
    t = t or {}
    F.input(e, { throttle = t.throttle, brakeRear = t.brake, lean = t.lean })
    local b = e.input.board or {}
    e.input.board = b
    b.fwd, b.side = t.fwd or 0, t.side or 0
    b.jump, b.alt, b.grab, b.duck, b.swap = t.jump or false, t.alt or false,
        t.grab or false, t.duck or false, t.swap or false
end

--------------------------------------------------------------------------
-- The registration
--------------------------------------------------------------------------

T.test("board: the skateboard is registered, valid, in the Boards menu, with four trucks' wheels", function()
    local sv = F.server()
    local B, E = sv.env.BMX, sv.env
    local d = B.Vehicles.skateboard
    T.ok(d, "registered")
    T.eq(#sv.errors, 0, "nothing was rejected: " .. table.concat(sv.errors, " | "))
    T.eq(d.family, "board", "family")
    T.eq(d.balance, "board", "the board balance")
    T.eq(d.drive.kind, "push", "the push drive")
    T.eq(d.input, "board", "its own input map")
    T.eq(d.pose, "board", "its own pose set")
    T.ok(B.BalanceModes.board and B.BalanceModes.board.Tick, "the balance mode has a module")
    T.ok(B.Drives.push, "the push drive has a function")
    T.ok(B.InputMaps.board.decode, "the input map has a decoder")
    T.eq(#B.WheelDefs(d, B.Config), 4, "four wheels")
    T.eq(B.ClassFor("skateboard"), "bmx_skateboard", "class")
    local row = sv.lists.SpawnableEntities.bmx_skateboard
    T.ok(row, "a spawn menu row")
    T.eq(row.Subcategory, "Boards", "under Boards")
    T.eq(row.Category, "BMX", "the one BMX heading")
    T.ok(sv.dupe.bmx_skateboard, "duplicable")
    -- It counts as a vehicle for the limit and for bmx_allow_boards.
    local found
    for _, id in ipairs(B.VehicleIDs()) do if id == "skateboard" then found = true end end
    T.ok(found, "in VehicleIDs, so it counts against bmx_max_per_player")
    T.eq(E.BMX.VehicleEnabled("skateboard"), true, "allowed by default")
    E.GetConVar("bmx_allow_boards"):SetString("0")
    T.eq(E.BMX.VehicleEnabled("skateboard"), false, "and bmx_allow_boards 0 stops it")
end)

T.test("board: the input map names every key the decoder reads, and each action has a context", function()
    local sv = F.server()
    local B = sv.env.BMX
    local map = B.InputMaps.board
    for _, name in ipairs({ "forward", "back", "left", "right", "jump", "alt", "grab", "crouch", "swap" }) do
        T.ok(map.actions[name], "action " .. name)
    end
    T.ok(#B.InputActions("board", "air") > 4, "several actions mean something in the air")
end)

T.test("board: the settings it adds exist, as client rows, and the client creates their convars", function()
    local sv = F.server()
    local cl = F.client(sv.world)
    local S = sv.env.BMX.Settings
    for _, name in ipairs({ "bmx_stance", "bmx_board_flick", "bmx_board_autogrind" }) do
        local row = S.Get(name)
        T.ok(row, name .. " has a row")
        T.eq(row.scope, "client", name .. " is the player's own")
        T.ok(sv.world.convars[name], name .. " exists")
    end
    T.eq(S.Get("bmx_stance").default, "regular", "regular by default")
end)

--------------------------------------------------------------------------
-- The pure functions
--------------------------------------------------------------------------

T.test("board: truck steer is atan(sin(lean) * k), and at speed no further than the tyres hold", function()
    local sv = F.server()
    local B = sv.env.BMX.Board
    local k = B.Tune.steerK
    local lean = math.rad(15)
    T.near(B.TruckSteer(lean, 20, 16), math.atan(math.sin(lean) * k), 1e-9, "the formula, at a walk")
    T.near(B.TruckSteer(-lean, 20, 16), -math.atan(math.sin(lean) * k), 1e-9, "odd in the lean")
    T.eq(B.TruckSteer(0, 100, 16), 0, "no lean, no steer")
    T.ok(B.TruckSteer(B.Tune.maxLean, 20, 16) > B.TruckSteer(lean, 20, 16), "more lean, more steer")
    -- At speed the sideways acceleration v^2 / R, R = wheelbase / (2 tan(steer)), is held to aLatMax.
    for _, v in ipairs({ 100, 200, 300 }) do
        local s = B.TruckSteer(B.Tune.maxLean, v, 16)
        local R = 16 / (2 * math.tan(s))
        T.ok(v * v / R <= B.Tune.aLatMax * 1.001, "at " .. v .. " u/s the turn asks for " .. v * v / R)
    end
    T.ok(B.TruckSteer(B.Tune.maxLean, 300, 16) < B.TruckSteer(B.Tune.maxLean, 100, 16), "less steer the faster it goes")
end)

T.test("board: the lean spring follows its target without overshooting much, and settles", function()
    local sv = F.server()
    local B = sv.env.BMX.Board
    local lean, rate, peak = 0, 0, 0
    local target = B.Tune.maxLean
    for i = 1, 100 do
        lean, rate = B.LeanStep(lean, rate, target, 1 / 66)
        peak = math.max(peak, lean)
        if i == 20 then T.ok(lean > target * 0.5, "most of the way after 0.3 s: " .. lean / target) end
    end
    T.ok(peak < target * 1.05, "overshoots under 5%: " .. peak / target)
    T.near(lean, target, target * 0.01, "settled")
end)

T.test("board: a kick adds the most at a standstill and nothing at top speed", function()
    local sv = F.server()
    local B = sv.env.BMX.Board
    T.near(B.KickDv(0), B.Tune.kick, 1e-9, "the full kick from a standstill")
    T.near(B.KickDv(B.Tune.maxSpeed), 0, 1e-9, "none at top speed")
    T.ok(B.KickDv(100) > B.KickDv(200), "less as it speeds up")
    T.near(B.KickDv(150, 40, 200), 10, 1e-9, "a vehicle's own kick and top speed")
end)

T.test("board: the push cycle kicks at once, then every kickInterval while W is held", function()
    local sv = F.server()
    local B = sv.env.BMX.Board
    local drive = { torque = 52, maxSpeed = 300, kickInterval = 0.6 }
    local ps, dt, kicks, total, speed, t = {}, 1 / 66, {}, 0, 0, 0
    for _ = 1, math.floor(3.0 / dt) do
        t = t + dt
        local add, began = B.PushStep(ps, dt, true, speed, drive)
        if began then kicks[#kicks + 1] = t end
        total = total + add
        speed = speed + add            -- no drag: the kick is the whole story
    end
    T.eq(#kicks, 5, "five kicks in three seconds: " .. #kicks)
    T.ok(kicks[1] < 0.05, "the first one at once: " .. kicks[1])
    T.near(kicks[2] - kicks[1], 0.6, 0.03, "then every 0.6 s")
    T.ok(total > 100 and total < 52 * 5, "the speed added is the kicks' (a kick shrinks as it speeds up): " .. total)
    -- Let go of W: no more kicks, and a stroke in progress finishes.
    local ps2 = {}
    local _, began = B.PushStep(ps2, dt, false, 0, drive)
    T.ok(not began, "no W, no kick")
end)

T.test("board: pop height is proportional to the hold, from a tap to the cap, and the speed reaches it", function()
    local sv = F.server()
    local B = sv.env.BMX.Board
    local T0 = B.Tune
    T.near(B.PopHeight(0), T0.popMin, 1e-9, "a tap")
    T.near(B.PopHeight(T0.crouchMax), T0.popMax, 1e-9, "a full crouch")
    T.near(B.PopHeight(T0.crouchMax * 5), T0.popMax, 1e-9, "held longer is no higher")
    T.near(B.PopHeight(T0.crouchMax * 0.5), (T0.popMin + T0.popMax) / 2, 1e-9, "linear in between")
    local last = -1
    for h = 0, T0.crouchMax, 0.05 do
        T.ok(B.PopHeight(h) > last - 1e-9, "never decreasing")
        last = B.PopHeight(h)
    end
    local v = B.PopSpeed(20, 600)
    T.near(v * v / (2 * 600), 20, 1e-6, "v = sqrt(2 g h) rises exactly that height")
end)

T.test("board: stance, switch and fakie are tracked from the rider's stance and the direction of travel", function()
    local sv = F.server()
    local B = sv.env.BMX.Board
    T.eq(B.Stance(false, false), 1, "regular: the left foot forward")
    T.eq(B.Stance(true, false), -1, "goofy: the right")
    T.eq(B.Stance(false, true), -1, "switch is the other foot")
    T.eq(B.Stance(true, true), 1, "goofy in switch is regular")
    T.eq(B.FrontFoot(1), "left", "left forward")
    T.eq(B.FrontFoot(-1), "right", "right forward")
    -- Fakie: backwards, with hysteresis.
    T.eq(B.IsFakie(-40, false), true, "rolling backwards fast enough")
    T.eq(B.IsFakie(-10, false), false, "a rock back and forth is not")
    T.eq(B.IsFakie(-10, true), true, "but once fakie, a slow roll back stays fakie")
    T.eq(B.IsFakie(20, true), false, "forwards again ends it")
    T.eq(B.IsFakie(100, false), false, "forwards is not")
end)

T.test("board: the flags and the flip bytes round-trip through the wire", function()
    local sv = F.server()
    local B = sv.env.BMX.Board
    local f = B.PackFlags({ goofy = true, fakie = true, manual = true })
    T.ok(B.HasFlag(f, "goofy") and B.HasFlag(f, "fakie") and B.HasFlag(f, "manual"), "set")
    T.ok(not B.HasFlag(f, "switch") and not B.HasFlag(f, "grind"), "and the others not")
    local r, y, p = B.UnpackBits(B.PackBits(1.0, 2.5, 4.0))
    T.near(r, 1.0, 2 * math.pi / 256, "roll")
    T.near(y, 2.5, 2 * math.pi / 256, "yaw")
    T.near(p, 4.0, 2 * math.pi / 256, "pitch")
    local r2 = B.UnpackBits(B.PackBits(2 * math.pi, 0, 0))
    T.near(r2, 0, 1e-9, "a whole turn is flat")
end)

--------------------------------------------------------------------------
-- The decoder
--------------------------------------------------------------------------

local function cmd(buttons, fwd, side, mx, my)
    local c = { buttons = buttons or 0, fwd = fwd or 0, side = side or 0, mx = mx or 0, my = my or 0 }
    function c:GetButtons() return self.buttons end
    function c:SetButtons(b) self.buttons = b end
    function c:GetForwardMove() return self.fwd end
    function c:GetSideMove() return self.side end
    function c:GetMouseX() return self.mx end
    function c:GetMouseY() return self.my end
    function c:SetForwardMove(v) self.fwd = v end
    function c:SetSideMove(v) self.side = v end
    function c:SetUpMove() end
    return c
end

T.test("board: the usercmd decoder reads the board's keys, not the bike's", function()
    local sv = F.server()
    local e = board(sv)
    local ply = F.rider(sv, e, { name = "Skater" })
    local IN = require("lib.gmod").IN
    local function press(buttons)
        sv.env.hook.Run("StartCommand", ply, cmd(buttons))
        return e.input, e.input.board
    end

    local inp, b = press(IN.FORWARD + IN.JUMP + IN.ATTACK2)
    T.eq(inp.throttle, 1, "W is the push")
    T.ok(b.jump and b.grab, "SPACE and RMB are the board record's")
    T.ok(not inp.hop or inp.hop == true, "the bike's hop flag follows SPACE")
    T.eq(e.hopHeld, false, "but the bike's hop never charges")
    T.ok(not inp.sprint and inp.brakeFront == 0, "no sprint, no front brake")

    inp, b = press(IN.BACK + IN.MOVERIGHT + IN.WALK + IN.DUCK)
    T.eq(inp.brakeRear, 1, "S is the foot")
    T.eq(inp.leanTarget, 1, "D leans right on the ground")
    T.ok(b.alt and b.duck, "ALT and CTRL")
    T.eq(b.side, 1, "the raw side")
end)

T.test("board: in the air A and D are flip flicks, not a roll, and CTRL + A / D is a body spin", function()
    local sv = F.server()
    local e = board(sv)
    local ply = F.rider(sv, e, { name = "Skater" })
    local IN = require("lib.gmod").IN
    e.st.airMode = true
    sv.env.hook.Run("StartCommand", ply, cmd(IN.MOVELEFT))
    T.eq(e.input.leanTarget, 0, "no roll from A in the air")
    T.eq(e.input.board.side, -1, "but it is the raw A")
    T.ok(not e.input.wheelieMod, "and no spin")
    sv.env.hook.Run("StartCommand", ply, cmd(IN.MOVELEFT + IN.DUCK))
    T.eq(e.input.leanTarget, -1, "CTRL + A spins")
    T.ok(e.input.wheelieMod, "through the same yaw path as RMB + A on a bike")
    T.eq(e.input.throttle, 0, "W is not a push in the air")
end)

T.test("board: the bike's decoder is unchanged: a bike still reads its own map", function()
    local sv = F.server()
    local bike = F.bike(sv)
    local ply = F.rider(sv, bike, { name = "BikeRider" })
    local IN = require("lib.gmod").IN
    sv.env.hook.Run("StartCommand", ply, cmd(IN.SPEED + IN.ATTACK2 + IN.ATTACK + IN.FORWARD))
    T.ok(bike.input.sprint and bike.input.wheelieMod and bike.input.brakeFront == 1, "the bike's keys")
    T.eq(bike.input.board, nil, "and no board record")
end)

--------------------------------------------------------------------------
-- Closed loop on the plant
--------------------------------------------------------------------------

T.test("board ride: it builds, settles on all four wheels, flat, with nothing balancing it", function()
    local sv, e = ridden()
    T.ok(e:AssertBuilt(), "built")
    T.eq(#e.wheels, 4, "four wheels")
    local down = 0
    for _, w in ipairs(e.wheels) do if w.onGround then down = down + 1 end end
    T.eq(down, 4, "all four on the ground")
    T.ok(math.abs(e.st.roll) < math.rad(3), "level: roll " .. math.deg(e.st.roll))
    T.ok(math.abs(e.st.pitch) < math.rad(3), "level: pitch " .. math.deg(e.st.pitch))
    T.ok(e.st.speed < 5, "at rest: " .. e.st.speed)
    T.near(e:GetPos().z - sv.world.groundZ, 1.3, 0.8, "at its ride height: " .. e:GetPos().z)
end)

T.test("board ride: W pushes it to speed, kick by kick, and it tops out", function()
    local sv, e = ridden()
    local kicks, last = 0, nil
    press(e, { throttle = 1, fwd = 1 })
    local at3
    sv:run(8, function()
        local k = e.st.board.ps.kicking
        if k and not last then kicks = kicks + 1 end
        last = k
        if not at3 and sv.world.time > 3.6 then at3 = e.st.fwdSpeed end
        return false
    end)
    local v = e.st.fwdSpeed
    T.ok(v > 150, "a few kicks get it going: " .. v)
    T.ok(at3 and at3 > 80, "100 u/s inside three seconds of pushing: " .. tostring(at3))
    T.ok(v < sv.env.BMX.Vehicles.skateboard.drive.maxSpeed, "never past its top: " .. v)
    T.ok(kicks >= 8, "it kicked about every 0.6 s: " .. kicks)
    T.ok(e:GetPos().x > 200, "forward, along +X")
    T.ok(math.abs(e.st.roll) < math.rad(4) and math.abs(e.st.pitch) < math.rad(4), "flat the whole way")
    T.ok(e:GetPushPhase() >= -1, "the push phase is networked")
end)

T.test("board ride: no W, no push; it rolls on and the foot (S) stops it", function()
    local sv, e = ridden()
    press(e, { throttle = 1, fwd = 1 })
    sv:run(4)
    local v = e.st.fwdSpeed
    press(e, {})
    sv:run(1.5)
    T.ok(e.st.fwdSpeed > v * 0.8, "it coasts, a skateboard rolls: " .. v .. " -> " .. e.st.fwdSpeed)
    press(e, { brake = 1, fwd = -1 })
    sv:run(1.2)
    T.ok(e.st.fwdSpeed < v * 0.5, "the foot drag takes the speed off: " .. v .. " -> " .. e.st.fwdSpeed)
    local vstop = e.st.speed
    sv:run(2)
    T.ok(e.st.speed < vstop, "and keeps going down")
end)

T.test("board ride: S at a standstill is a kick-turn, a half turn about the rear wheels", function()
    local sv, e = ridden()
    local yaw0 = e:GetAngles().y
    local x0 = e:GetPos()
    press(e, { brake = 1, fwd = -1 })
    sv:run(1.0)
    press(e, {})
    sv:run(0.3)
    local diff = (e:GetAngles().y - yaw0 + 540) % 360 - 180
    local off = 180 - math.abs(diff)
    T.ok(off < 25, "it came round to the other way: " .. off .. " deg off a half turn")
    T.ok(math.abs(e:GetPos():Distance(x0) - 16) < 4, "about its rear wheels (the middle swings a wheelbase round): " .. e:GetPos():Distance(x0))
    T.ok(e.st.speed < 30, "and it is not rolling")
    T.eq(e.st.board.kt, nil, "the turn is over")
end)

T.test("board ride: carving. A / D lean the deck, the trucks turn, it goes round, and it stays flat", function()
    local sv, e = ridden()
    press(e, { throttle = 1, fwd = 1 })
    sv:run(4)
    local v = e.st.fwdSpeed
    T.ok(v > 90, "up to speed first: " .. v)
    press(e, { throttle = 0, lean = 1, side = 1 })
    local yaw0, peakRoll, peakLean, steer = e:GetAngles().y, 0, 0, 0
    local total, last = 0, yaw0
    sv:run(2.5, function()
        peakRoll = math.max(peakRoll, math.abs(e.st.roll))
        peakLean = math.max(peakLean, math.abs(e.st.board.lean))
        local y = e:GetAngles().y
        total = total + ((y - last + 540) % 360 - 180)
        last = y
        local w = e.wheels[1]
        steer = math.max(steer, math.abs(w.steer))
        return false
    end)
    T.ok(peakLean > math.rad(18), "the deck leaned: " .. math.deg(peakLean))
    T.ok(steer > 0.03, "the front truck turned: " .. steer)
    T.ok(e.wheels[3].steer < -0.01, "the rear truck turned the other way: " .. e.wheels[3].steer)
    T.ok(total < -25, "it went round to the RIGHT (yaw falls): " .. total)
    T.ok(peakRoll < math.rad(8), "and the chassis never tipped: " .. math.deg(peakRoll))
    -- The same to the left.
    press(e, { lean = -1, side = -1 })
    local y1, t2, l2 = e:GetAngles().y, 0, e:GetAngles().y
    sv:run(2.5, function()
        local y = e:GetAngles().y
        t2 = t2 + ((y - l2 + 540) % 360 - 180)
        l2 = y
        peakRoll = math.max(peakRoll, math.abs(e.st.roll))
        return false
    end)
    T.ok(t2 > 25, "and to the LEFT: " .. t2)
    T.ok(peakRoll < math.rad(8), "still flat: " .. math.deg(peakRoll))
    T.ok(e.st.speed > 30, "still rolling")
end)

T.test("board ride: the deck's lean comes back to flat when the key is let go", function()
    local sv, e = ridden()
    press(e, { throttle = 1, fwd = 1 })
    sv:run(3)
    press(e, { lean = 1, side = 1 })
    sv:run(0.8)
    T.ok(e.st.board.lean > math.rad(15), "leaning: " .. math.deg(e.st.board.lean))
    press(e, {})
    sv:run(1.2)
    T.ok(math.abs(e.st.board.lean) < math.rad(2), "back to flat: " .. math.deg(e.st.board.lean))
    T.ok(math.abs(e:GetBoardLean()) < 0.05, "and networked flat")
end)

T.test("board ride: an ollie. Hold to crouch, release to pop; a longer hold goes higher; it lands on its wheels", function()
    local function ollie(hold)
        local sv, e = ridden()
        press(e, { throttle = 1, fwd = 1 })
        sv:run(3)
        press(e, { jump = true })
        sv:run(hold)
        local crouch = e:GetCrouch()
        press(e, {})
        local ground = e:GetPos().z
        local peak, airborne, t0 = ground, false, sv.world.time
        local landedAt
        sv:run(2.0, function()
            peak = math.max(peak, e:GetPos().z)
            if not e.st.grounded then airborne = true end
            if airborne and e.st.grounded and not landedAt then landedAt = sv.world.time end
            return false
        end)
        return peak - ground, airborne, crouch, e, sv, landedAt
    end
    local hTap, airTap = ollie(0.0)
    local hMid = ollie(0.2)
    local hFull, airFull, crouch, e, sv, landedAt = ollie(0.5)
    T.ok(airTap, "even a tap leaves the ground")
    T.ok(hTap > 3 and hTap < 20, "a tap is a low ollie: " .. hTap)
    T.ok(hMid > hTap + 2, "a half hold is higher: " .. hTap .. " < " .. hMid)
    T.ok(hFull > hMid + 2, "a full hold is higher again: " .. hMid .. " < " .. hFull)
    T.ok(hFull > 14 and hFull < 40, "a full ollie is about a body's height of the board: " .. hFull)
    T.ok(crouch > 0.9, "the crouch was networked for the rider's knees: " .. crouch)
    T.ok(landedAt, "it came down again")
    T.ok(math.abs(e.st.roll) < math.rad(15) and math.abs(e.st.pitch) < math.rad(25), "on its wheels")
    T.ok(e:GetDriver():InVehicle(), "and nobody was thrown")
end)

T.test("board ride: an ollie keeps its pop in the direction of travel, not straight up", function()
    local sv, e = ridden()
    press(e, { throttle = 1, fwd = 1 })
    sv:run(3)
    local x0 = e:GetPos().x
    press(e, { jump = true })
    sv:run(0.3)
    press(e, {})
    sv:run(1.5)
    T.ok(e:GetPos().x - x0 > 60, "it carried on forward through the air: " .. e:GetPos().x - x0)
end)

T.test("board ride: a nollie pops the nose; the same height, the other spin", function()
    local sv, e = ridden()
    press(e, { jump = true, alt = true })
    sv:run(0.3)
    press(e, { alt = true })
    local peakPitch = 0
    sv:run(0.35, function()
        peakPitch = math.min(peakPitch, e.st.pitch)
        return false
    end)
    T.ok(e.st.board.nollie, "it was a nollie")
    T.ok(peakPitch < -math.rad(3), "the nose went DOWN: " .. math.deg(peakPitch))
    local sv2, e2 = ridden()
    press(e2, { jump = true })
    sv2:run(0.3)
    press(e2, {})
    local pk = 0
    sv2:run(0.35, function() pk = math.max(pk, e2.st.pitch) return false end)
    T.ok(pk > math.rad(3), "an ollie's nose goes UP: " .. math.deg(pk))
end)

T.test("board ride: nobody aboard, it is idle and flat, and the board record clears", function()
    local sv = F.server()
    local e = board(sv)
    sv:run(1.5)
    T.ok(e:AssertBuilt(), "built")
    T.ok(math.abs(e.st.roll) < math.rad(3), "stands flat with nobody on it")
    local ply = F.rider(sv, e, { name = "Skater", bot = true })
    ply.BMXScripted = true
    press(e, { lean = 1, side = 1, throttle = 1, fwd = 1 })
    sv:run(2)
    ply:ExitVehicle()
    sv:run(0.3)
    T.eq(e:GetBoardLean(), 0, "the deck is flat again")
    T.eq(e.st.board.crouching, false, "not crouching")
end)

T.test("board ride: the bike on the same plant is unchanged by the board sharing the loop", function()
    local sv = F.server()
    local bike = F.bike(sv)
    F.scripted(sv, bike)
    F.accelerateTo(sv, bike, 150)
    T.ok(bike.st.speed >= 150, "a bike still pedals to speed")
    T.eq(bike.st.board, nil, "and carries no board state")
end)

--------------------------------------------------------------------------
-- The drawing
--------------------------------------------------------------------------

T.test("board draw: the frame puts the deck's points where the flip, the lean and the lift say", function()
    local sv = F.server()
    local cl = F.client(sv.world)
    local E = cl.env
    local B = E.BMX.Board
    local ent = cl:clientEntity("bmx_skateboard")
    ent:SetPos(E.Vector(100, 50, 20))
    local fr = B.Frame({ ent = ent, lean = 0, ground = -1.3 })
    local p = fr.P(E.Vector(10, 0, 1.4))
    T.near(p.x, 110, 1e-6, "x forward")
    T.near(p.y, 50, 1e-6, "no side")
    T.near(p.z, 21.4, 1e-6, "the deck's height over the origin")
    -- A left point (+Y) is to the board's left.
    local pl = fr.P(E.Vector(0, 4, 1.4))
    T.near(pl.y, 54, 1e-6, "+Y is left")
    -- A half roll puts the deck upside down about its middle.
    local fl = B.Frame({ ent = ent, roll = math.pi, ground = -1.3 })
    T.near(fl.u.z, -1, 1e-9, "its up points down")
    -- Lean about the ground line: the top moves to the right, the contact line does not.
    local fn = B.Frame({ ent = ent, lean = math.rad(20), ground = -1.3 })
    local top = fn.P(E.Vector(0, 0, 21.4))
    T.ok(top.y < 50, "the top moves to the RIGHT (-Y) on a right lean: " .. top.y)
    local foot = fn.P(E.Vector(0, 0, -1.3))
    T.near(foot.y, 50, 1e-6, "and the ground contact stays put")
    -- A grab lifts the deck.
    T.near(B.Frame({ ent = ent, lift = 3, ground = -1.3 }).center.z, 20 + 3 + 1.4, 1e-6, "lifted")
end)

T.test("board draw: the board draws to the end, its wheels round and on the ground, and records the rider's targets", function()
    local sv = F.server()
    local cl = F.client(sv.world)
    local E = cl.env
    local ent = cl:clientEntity("bmx_skateboard")
    ent:SetPos(E.Vector(0, 0, 1.3))
    cl.localPlayer = sv:player("Looker")
    cl.lines, cl.beams, cl.drawnModels, cl.boxes3d = 0, {}, 0, 0
    ent:Draw()
    T.ok(ent.ikTargets, "the IK targets were recorded")
    for _, k in ipairs({ "lFoot", "rFoot", "lHand", "rHand" }) do
        T.ok(ent.ikTargets[k] and ent.ikTargets[k].x == ent.ikTargets[k].x, k .. " is a real point")
    end
    T.ok(#cl.beams + #cl.drawnCS > 8, "something was drawn: " .. (#cl.beams + #cl.drawnCS))
end)

T.test("board draw: the feet are on the bolts, the front foot forward for a regular stance, swapped for goofy", function()
    local sv = F.server()
    local cl = F.client(sv.world)
    local E = cl.env
    local B = E.BMX.Board
    local function feet(flags)
        local ent = cl:clientEntity("bmx_skateboard")
        ent:SetPos(E.Vector(0, 0, 1.3))
        ent:SetBoardFlags(flags)
        cl.localPlayer = sv:player("Looker")
        ent:Draw()
        return ent.ikTargets, ent
    end
    local reg = feet(0)
    T.ok(reg.lFoot.x > reg.rFoot.x, "regular: the left foot is forward: " .. reg.lFoot.x .. " vs " .. reg.rFoot.x)
    local goofy = feet(B.PackFlags({ goofy = true }))
    T.ok(goofy.rFoot.x > goofy.lFoot.x, "goofy: the right foot is forward")
    local sw = feet(B.PackFlags({ switch = true }))
    T.ok(sw.rFoot.x > sw.lFoot.x, "regular in switch is the other foot forward")
    T.ok(reg.lFoot.z > 1 and reg.lFoot.z < 12, "and on the deck, not in the air or the floor: " .. reg.lFoot.z)
end)

T.test("board draw: the push moves the back foot to the ground and back, driven by the phase", function()
    local sv = F.server()
    local cl = F.client(sv.world)
    local E = cl.env
    local B = E.BMX.Board
    local bolt = E.Vector(B.Tune.footBack, 0, 4.6)
    local f0, p0 = B.PushFoot(-1, bolt)
    T.ok(not p0 and f0 == bolt, "not pushing: on its bolt")
    local seen = { low = false, back = false }
    for i = 0, 100 do
        local f, pushing = B.PushFoot(i / 100, bolt)
        T.ok(f.x == f.x and f.z == f.z, "a real point at " .. i)
        if f.z < 2 then seen.low = true end
        if f.x < B.Tune.footBack - 5 then seen.back = true end
    end
    T.ok(seen.low, "the foot reaches the ground")
    T.ok(seen.back, "and sweeps back behind the deck")
    local fe = B.PushFoot(0.99, bolt)
    T.near((fe - bolt):Length(), 0, 1e-6, "and it is home at the end")
end)
