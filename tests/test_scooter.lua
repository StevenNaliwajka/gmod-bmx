--[[--------------------------------------------------------------------------
    The kick scooter (G24: sh_scooter.lua, sv_scooter.lua, cl_scooter.lua, and the
    `push` drive's footBrake switch in sv_board.lua): the registration, the keys, the
    grinds' contact rules, and closed-loop rides on the plant -- the kick, the fender
    brake, the carve, the TAILWHIP that completes by itself on the scooter, the bri
    flip, the grinds -- and the drawing.

    WHAT THE PLANT CAN AND CANNOT TELL YOU. It runs the real wheel, balance and
    physics-step code against a rigid body on a plane, so it is right about stability,
    direction and magnitude, not about how a scooter FEELS: that is the headless cases
    (sv_test_cases.lua, vehicle "scooter") and a human on a server.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local SF = require("lib.scooter")
local gmod = require("lib.gmod")
local IN = gmod.IN
local scooter, ridden = SF.scooter, SF.ridden

local TAU = math.pi * 2

--------------------------------------------------------------------------
-- The registration
--------------------------------------------------------------------------

T.test("scooter: it is registered through the platform, valid, under Scooters, two wheels in line", function()
    local sv = F.server()
    local B, E = sv.env.BMX, sv.env
    local d = B.Vehicles.scooter
    T.ok(d, "registered")
    T.eq(#sv.errors, 0, "nothing was rejected: " .. table.concat(sv.errors, " | "))
    T.eq(d.family, "scooter", "family")
    T.eq(d.balance, "singletrack", "the bike's balance")
    T.eq(d.drive.kind, "push", "the board's push drive")
    T.eq(d.drive.footBrake, false, "without the foot brake: the fender is the brake")
    T.eq(d.input, "scooter", "its own input map")
    T.eq(d.pose, "scooter", "its own pose set")
    local w = B.WheelDefs(d, B.ConfigFor(d))
    T.eq(#w, 2, "two wheels")
    T.eq(w[1].steer, "fork", "the front one steered by the fork")
    T.eq(w[1].pos.y, 0, "in line")
    T.eq(w[2].pos.y, 0, "in line")
    T.eq(B.ClassFor("scooter"), "bmx_scooter", "class")
    local row = sv.lists.SpawnableEntities.bmx_scooter
    T.ok(row, "a spawn menu row")
    T.eq(row.Subcategory, "Scooters", "under Scooters")
    T.eq(row.Category, "BMX", "the one BMX heading")
    T.ok(sv.dupe.bmx_scooter, "duplicable")
    local found
    for _, id in ipairs(B.BikeIDs()) do if id == "scooter" then found = true end end
    T.ok(found, "in the menu's list")
    T.eq(E.BMX.VehicleEnabled("scooter"), true, "allowed by default")
    E.GetConVar("bmx_allow_scooters"):SetString("0")
    T.eq(E.BMX.VehicleEnabled("scooter"), false, "bmx_allow_scooters 0 stops it")
    T.eq(E.BMX.VehicleEnabled("stock"), true, "and only it")
end)

T.test("scooter: it adds no convar of its own: the switch is bmx_allow_scooters, which has its row and a convar", function()
    local sv = F.server()
    local S = sv.env.BMX.Settings
    local row = S.Get("bmx_allow_scooters")
    T.ok(row, "the server row exists")
    T.eq(row.scope, "server", "an admin's")
    T.eq(row.default, true, "on by default")
    T.eq(row.category, "vehicles", "under Vehicles")
    T.ok(sv.world.convars.bmx_allow_scooters, "the convar exists")
    T.ok(row.label:lower():find("scooter", 1, true) and row.help:lower():find("scooter", 1, true), "and says what it is")
    -- The settings suite fails on any bmx_ convar without a row; this is the check that the scooter did not add one.
    local n = 0
    for name in pairs(sv.world.convars) do
        if name:find("scooter", 1, true) then n = n + 1 end
    end
    T.eq(n, 1, "the only convar with 'scooter' in its name is the switch")
end)

T.test("scooter: small wheels, a short wheelbase and a small trail (a fast steering lag)", function()
    local sv = F.server()
    local B = sv.env.BMX
    local sc = B.ConfigFor(B.Vehicles.scooter)
    local bike = B.ConfigFor(B.Vehicles.stock)
    T.ok(sc.Wheel.radius < bike.Wheel.radius * 0.6, "small wheels: " .. sc.Wheel.radius)
    T.ok(sc.Wheel.wheelbase < bike.Wheel.wheelbase, "a short wheelbase")
    T.ok(sc.Balance.steerRate > bike.Balance.steerRate, "the bars follow faster: the trail is small")
    T.ok(sc.Chassis.mass < bike.Chassis.mass, "lighter")
    T.ok(sc.Drive.rearBrake > 0 and sc.Drive.frontBrake == 0, "a rear brake and no front one")
end)

T.test("scooter: the input map is the bike's without a sprint, and LMB is only a whip", function()
    local sv = F.server()
    local B = sv.env.BMX
    local map = B.InputMaps.scooter
    for _, name in ipairs({ "forward", "back", "left", "right", "hop", "tuck", "weightBack", "bar", "alt", "brakeFront" }) do
        T.ok(map.actions[name], "action " .. name)
    end
    T.eq(map.actions.sprint, nil, "no sprint")
    local lmb = map.actions.brakeFront
    local ground = false
    for _, c in ipairs(lmb.ctx) do if c == "ground" then ground = true end end
    T.ok(not ground, "LMB is no ground brake: the scooter has no front brake")
    T.eq(map.decode, nil, "and the bike's decoder reads it")
end)

T.test("scooter: the usercmd decode is the bike's: W kicks, S brakes the rear, LMB on the ground does nothing", function()
    local sv = F.server()
    local e = scooter(sv)
    local ply = F.rider(sv, e, { name = "Scooterist" })
    local function cmd(b)
        local c = { buttons = b, fwd = 0, side = 0 }
        function c:GetButtons() return self.buttons end
        function c:SetButtons(x) self.buttons = x end
        function c:GetForwardMove() return self.fwd end
        function c:GetSideMove() return self.side end
        function c:SetForwardMove() end
        function c:SetSideMove() end
        function c:SetUpMove() end
        function c:GetMouseX() return 0 end
        function c:GetMouseY() return 0 end
        return c
    end
    sv.env.hook.Run("StartCommand", ply, cmd(IN.FORWARD + IN.SPEED + IN.ATTACK))
    T.eq(e.input.throttle, 1, "W is the kick")
    T.eq(e.input.sprint, false, "SHIFT is no sprint")
    T.eq(e.input.brakeFront, 0, "LMB on the ground brakes nothing")
    sv.env.hook.Run("StartCommand", ply, cmd(IN.BACK))
    T.eq(e.input.brakeRear, 1, "S is the rear brake")
end)

--------------------------------------------------------------------------
-- The grinds' contact rules, pure
--------------------------------------------------------------------------

local function keys(s)
    local k = { w = false, s = false, a = false, d = false }
    for c in s:gmatch(".") do k[c] = true end
    return k
end

T.test("scooter grinds: the keys pick the move, and only a ledge has the peg grinds", function()
    local sv = F.server()
    local SC = sv.env.BMX.Scooter
    T.eq(SC.ClassifyGrind(keys(""), false), "scooter_5050", "a round rail: the deck")
    T.eq(SC.ClassifyGrind(keys(""), true), "scooter_5050", "a ledge, no key: the deck")
    T.eq(SC.ClassifyGrind(keys("w"), true), "scooter_smith", "W on a ledge: smith, the front peg")
    T.eq(SC.ClassifyGrind(keys("s"), true), "scooter_feeble", "S on a ledge: feeble, the back peg")
    T.eq(SC.ClassifyGrind(keys("w"), false), "scooter_5050", "a pipe has no edge for a peg: 50-50")
    T.eq(SC.ClassifyGrind(keys("s"), false), "scooter_5050", "...either")
    T.eq(SC.ClassifyGrind(keys("ws"), true), "scooter_5050", "W and S cancel")
    T.eq(SC.ClassifyGrind(keys("wa"), true), "scooter_smith", "a side key does not change it")
    local seen = {}
    for _, e in ipairs({ true, false }) do
        for _, ks in ipairs({ "", "w", "s" }) do seen[SC.ClassifyGrind(keys(ks), e)] = true end
    end
    for _, id in ipairs(SC.GrindOrder) do T.ok(seen[id], id .. " is reachable") end
end)

T.test("scooter grinds: along the rail's line only, within 45 degrees either way round", function()
    local sv = F.server()
    local SC = sv.env.BMX.Scooter
    T.ok(SC.IsAlong(0) and SC.IsAlong(math.pi), "straight along, either way")
    T.ok(SC.IsAlong(math.rad(40)) and SC.IsAlong(math.rad(140)), "40 degrees off")
    T.ok(not SC.IsAlong(math.rad(60)) and not SC.IsAlong(math.pi / 2), "across is no grind")
end)

T.test("scooter grinds: each contact is below what the hull has, on the rail's side, and registered and paid", function()
    local sv = F.server()
    local B = sv.env.BMX
    local SC = B.Scooter
    local T0 = SC.Tune
    local cfg = B.ConfigFor(B.Vehicles.scooter)
    local half = cfg.Wheel.wheelbase * 0.5
    local floor = -(cfg.Wheel.radius - cfg.Wheel.restLength)          -- the wheel boxes' floor
    -- The deck is under the wheel boxes (so they clear a pipe, as the chainring's point does); the pegs
    -- are under the peg boxes (which start at the axle line).
    T.ok(T0.deckZ <= floor, "the deck's contact is at or below the wheel boxes' floor: " .. T0.deckZ .. " vs " .. floor)
    T.ok(T0.pegZ < 0, "the peg contact is below the peg boxes' floor (the axle line)")
    T.ok(T0.pegY > cfg.Chassis.wheelHullHalfWidth + 0.8, "the pegs clear the wheels over the drop")
    T.ok(T0.pegY < cfg.Chassis.pegHullHalfWidth, "and are inside the peg boxes' reach")
    -- Points.
    local c = SC.GrindContact("scooter_5050", half, false)
    T.eq(c.y, 0, "a pipe is under the middle of the deck")
    T.eq(SC.GrindContact("scooter_5050", half, true, 1).y, T0.edgeY, "a ledge on the left")
    T.eq(SC.GrindContact("scooter_5050", half, true, -1).y, -T0.edgeY, "or the right")
    local sm, fe = SC.GrindContact("scooter_smith", half, true, 1), SC.GrindContact("scooter_feeble", half, true, 1)
    T.eq(sm.x, half, "the smith is the front axle's peg")
    T.eq(fe.x, -half, "the feeble the back axle's")
    T.ok(SC.Grinds.scooter_smith.pitch < 0 and SC.Grinds.scooter_feeble.pitch > 0, "nose down for the smith, up for the feeble")
    -- The wheel at the peg is a box (radius long, the hull's width wide) and has to stay over the drop
    -- at the angle the pose turns it to: its far corner, a radius past the axle and half a width to
    -- the top side of the scooter's axis, turned by the yaw, is still under the edge (less the inset).
    for _, id in ipairs({ "scooter_smith", "scooter_feeble" }) do
        local yaw = SC.Grinds[id].yaw
        local far = cfg.Wheel.radius * math.sin(yaw) - (T0.pegY - cfg.Chassis.wheelHullHalfWidth) * math.cos(yaw)
        T.ok(far + cfg.Grind.pegInset < 0, id .. ": the peg's wheel stays over the drop: " .. far)
    end
    T.ok(SC.Grinds.scooter_smith.edge and SC.Grinds.scooter_feeble.edge and not SC.Grinds.scooter_5050.edge,
        "the peg grinds need an edge")
    local rate = B.Config.Grind.pointsPerSec
    for _, id in ipairs(SC.GrindOrder) do
        local t = B.Tricks[id]
        T.ok(t and t.kind == "grind", id .. " is a registered grind")
        T.near(t.points, rate * SC.Grinds[id].mult, 1e-6, id .. " pays its multiple of the rate")
        local code = SC.SparkCode[id]
        T.ok(code and code >= 10 and #SC.SparkPoints(code, half, 1) == 1, id .. " throws sparks from one contact")
    end
    -- The vehicle's own trick list names every one, and the grind points name the moves.
    for _, id in ipairs(SC.GrindOrder) do
        T.ok(B.VehicleAllows(B.Vehicles.scooter, id), id .. " is on the scooter's trick list")
    end
    local gp = B.GrindPointsFor(B.Vehicles.scooter, cfg)
    T.ok(gp.crank and gp.pegs and gp.moves, "the grind points: a crank point, pegs and the moves")
end)

T.test("scooter: the whip and a flip in one air are one Bri Flip, paying both and a bonus, counting as two", function()
    local sv = F.server()
    local B = sv.env.BMX
    local SC = B.Scooter
    local out = { { name = "Tailwhip", count = 1, points = 600 }, { name = "Backflip", count = 1, points = 500 } }
    SC.MergeBri(out)
    T.eq(#out, 1, "one entry")
    T.eq(out[1].name, "Bri Flip", "named")
    T.eq(out[1].points, 1100 + math.floor(1100 * SC.Tune.briBonus), "both and the bonus")
    T.eq(out[1].tricks, 2, "two tricks for the combo")
    local out2 = { { name = "Frontflip", count = 2, points = 1000 }, { name = "Air Time", count = 1, points = 80 },
                   { name = "Tailwhip", count = 1, points = 600 } }
    SC.MergeBri(out2)
    T.eq(#out2, 2, "the rest stays")
    local names = {}
    for _, e in ipairs(out2) do names[e.name] = true end
    T.ok(names["Bri Flip"] and names["Air Time"], "a front flip does it too, and the air time is kept")
    local out3 = { { name = "Tailwhip", count = 1, points = 600 } }
    SC.MergeBri(out3)
    T.eq(out3[1].name, "Tailwhip", "a whip alone is a whip")
    local out4 = { { name = "Backflip", count = 1, points = 500 } }
    SC.MergeBri(out4)
    T.eq(out4[1].name, "Backflip", "and a flip alone a flip")
    T.ok(B.Tricks.briflip and B.VehicleAllows(B.Vehicles.scooter, "briflip"), "registered, and on the list")
end)

--------------------------------------------------------------------------
-- Closed loop on the plant: riding
--------------------------------------------------------------------------

T.test("scooter ride: it builds, settles on both wheels and stands with a rider on it", function()
    local sv, e = ridden()
    T.ok(e:AssertBuilt(), "built")
    T.eq(#e.wheels, 2, "two wheels")
    T.ok(e.wheels[1].onGround and e.wheels[2].onGround, "both on the ground")
    T.ok(e.st.speed < 6, "at rest: " .. e.st.speed)
    T.ok(math.abs(e.st.roll) < math.rad(12), "upright with a rider: roll " .. math.deg(e.st.roll))
    T.ok(e:GetDriver():InVehicle(), "the rider is on")
    T.eq(#sv.errors, 0, "no errors: " .. table.concat(sv.errors, " | "))
end)

T.test("scooter ride: W kicks it up to speed, stroke by stroke, and it tops out below its limit", function()
    local sv, e = ridden()
    local kicks, last = 0, nil
    F.input(e, { throttle = 1 })
    local at3
    sv:run(8, function()
        local k = e.st.board.ps.kicking
        if k and not last then kicks = kicks + 1 end
        last = k
        if not at3 and sv.world.time > 4.6 then at3 = e.st.fwdSpeed end
        return false
    end)
    local v = e.st.fwdSpeed
    T.ok(v > 150, "a few kicks get it going: " .. v)
    T.ok(at3 and at3 > 90, "100 u/s inside three seconds of kicking: " .. tostring(at3))
    T.ok(v < sv.env.BMX.Vehicles.scooter.drive.maxSpeed, "never past its top: " .. v)
    T.ok(kicks >= 8, "about every 0.55 s: " .. kicks)
    T.ok(e:GetPos().x > 200, "forward along +X")
    T.ok(math.abs(e.st.roll) < math.rad(15), "balanced the whole way: roll " .. math.deg(e.st.roll))
    T.ok(e:GetPushPhase() >= -1, "the push phase is networked, for the rider's foot")
    T.ok(e:GetDriver():InVehicle(), "and nobody fell off")
end)

T.test("scooter ride: it rolls on when W is let go, and S, the rear fender brake, stops it", function()
    local sv, e = ridden()
    F.input(e, { throttle = 1 })
    sv:run(5)
    local v = e.st.fwdSpeed
    T.ok(v > 100, "up to speed: " .. v)
    F.input(e, {})
    sv:run(1.5)
    T.ok(e.st.fwdSpeed > v * 0.75, "it coasts: " .. v .. " -> " .. e.st.fwdSpeed)
    local c = e.st.fwdSpeed
    F.input(e, { brakeRear = 1 })
    sv:run(1.5)
    T.ok(e.st.fwdSpeed < c * 0.45, "the fender brake slows it hard: " .. c .. " -> " .. e.st.fwdSpeed)
    T.eq(e.st.board.kt, nil, "no foot, no kick-turn: " .. tostring(e.st.board.kt))
    T.ok(e:GetDriver():InVehicle(), "and it did not throw the rider")
    -- Without the wheel's brake the speed would not fall this fast: the board's foot drag is OFF.
    local sv2, e2 = ridden()
    F.input(e2, { throttle = 1 })
    sv2:run(5)
    F.input(e2, {})
    sv2:run(1.5)
    local c2 = e2.st.fwdSpeed
    sv2:run(1.5)
    T.ok(e2.st.fwdSpeed > c2 * 0.8, "no S, no braking: " .. c2 .. " -> " .. e2.st.fwdSpeed)
end)

T.test("scooter ride: A and D lean it round, both ways, the bars follow and the rider stays on", function()
    local sv, e = ridden()
    F.input(e, { throttle = 1 })
    sv:run(5)
    local v = e.st.fwdSpeed
    T.ok(v > 100, "up to speed first: " .. v)
    local function turn(lean)
        F.input(e, { lean = lean })
        local last, total, steer, peakRoll = e:GetAngles().y, 0, 0, 0
        sv:run(2.2, function()
            local y = e:GetAngles().y
            total = total + ((y - last + 540) % 360 - 180)
            last = y
            steer = math.max(steer, math.abs(e.wheels[1].steer))
            peakRoll = math.max(peakRoll, math.abs(e.st.roll))
        end)
        return total, steer, peakRoll
    end
    local right, sr, rr = turn(1)
    T.ok(right < -20, "D goes round to the right (yaw falls): " .. right)
    T.ok(sr > 0.02, "the fork turned: " .. sr)
    T.ok(rr > math.rad(5), "it leaned into it: " .. math.deg(rr))
    local left = turn(-1)
    T.ok(left > 20, "and A to the left: " .. left)
    T.ok(e:GetDriver():InVehicle(), "still aboard")
end)

T.test("scooter ride: SPACE bunny hops it off the ground", function()
    local sv, e = ridden()
    F.input(e, { throttle = 1 })
    sv:run(4)
    F.input(e, {})
    local ground = e:GetPos().z
    e.hopHeld = true
    sv:run(0.4)
    e.hopHeld, e.hopRelease = false, true
    local peak, air = ground, false
    sv:run(1.5, function()
        peak = math.max(peak, e:GetPos().z)
        if not e.st.grounded then air = true end
    end)
    T.ok(air, "it left the ground")
    T.ok(peak - ground > 6, "a real hop: " .. (peak - ground))
    T.ok(e:GetDriver():InVehicle(), "and landed with the rider on")
end)

--------------------------------------------------------------------------
-- Closed loop on the plant: the tricks
--------------------------------------------------------------------------

-- A scripted rider, kicked into the air off flat ground, with `script(t, inp, e)` called every tick to write
-- the input; run until it has landed. The same as tests/test_tricks.lua's, on a scooter.
local function fly(script, opts)
    opts = opts or {}
    local sv, e = ridden()
    local E = sv.env
    local crash, landed
    E.hook.Add("BMX_Crash", "test", function(_, _, reason) crash = reason end)
    E.hook.Add("BMX_TricksLanded", "test", function(_, _, tricks) landed = tricks end)
    F.input(e, {})
    e.input.whip, e.input.bar, e.input.pose = 0, 0, nil
    local score0 = e:GetScore()
    e:GetPhysicsObject():SetVelocity(E.Vector(opts.vx or 0, 0, opts.vz or 330))
    local t0, was = sv.world.time, false
    sv:run(5, function()
        local t = sv.world.time - t0
        script(t, e.input, e)
        if e.st.airMode then was = true end
        if was and e.st.grounded and not e.st.airMode then return true end
    end)
    sv:run(0.4)
    return { sv = sv, e = e, crash = crash, landed = landed, score = e:GetScore() - score0,
             aboard = E.IsValid(e:GetDriver()) }
end

local function between(t, a, b) return t >= a and t < b end
local function named(list, name)
    for _, t in ipairs(list or {}) do if t.name == name then return t end end
end

T.test("scooter tricks: a tailwhip held 0.47 s completes by itself, pays 600, and the scooter lands rideable", function()
    local r = fly(function(t, inp) inp.whip = between(t, 0.15, 0.62) and 1 or 0 end)
    T.eq(r.crash, nil, "no crash: " .. tostring(r.crash))
    T.ok(r.aboard, "the rider is still on")
    T.ok(r.score >= 600, "scored: " .. r.score)
    T.ok(named(r.landed, "Tailwhip"), "reported as a Tailwhip")
    T.eq(r.e.st.parts.whip.angle, 0, "the deck is back in line")
    -- It is the DECK that turns: the kinematic part is the rear group, which cl_scooter.lua draws as the deck.
    T.ok(r.e:Bike().tricks and r.sv.env.BMX.VehicleAllows(r.e:Bike(), "tailwhip"), "tailwhip is on its list")
end)

T.test("scooter tricks: let go of a whip past 270 degrees and it auto-completes; before 90 it snaps back for nothing", function()
    local r = fly(function(t, inp) inp.whip = between(t, 0.15, 0.58) and 1 or 0 end)   -- ~283 degrees
    T.eq(r.crash, nil, "no crash")
    T.ok(named(r.landed, "Tailwhip"), "finished past 270: " .. tostring(r.crash))
    local r2 = fly(function(t, inp) inp.whip = between(t, 0.15, 0.27) and 1 or 0 end)  -- ~80 degrees
    T.eq(r2.crash, nil, "no crash")
    T.eq(r2.score, 0, "snapped back: nothing paid")
end)

T.test("scooter tricks: a whip left half done is out of line and bails", function()
    local r = fly(function(t, inp) inp.whip = between(t, 0.15, 0.45) and 1 or 0 end)
    T.eq(r.crash, "whip", "out of line: " .. tostring(r.crash))
    T.ok(not r.aboard, "thrown off")
end)

T.test("scooter tricks: a barspin pays, and a whip and a barspin are one 'Tailwhip to Barspin'", function()
    local r = fly(function(t, inp) inp.bar = between(t, 0.15, 0.55) and 1 or 0 end)
    T.eq(r.crash, nil, "no crash: " .. tostring(r.crash))
    T.ok(named(r.landed, "Barspin"), "a barspin")
    local r2 = fly(function(t, inp)
        inp.whip = between(t, 0.1, 0.65) and 1 or 0
        inp.bar = between(t, 0.1, 0.5) and 1 or 0
    end)
    T.eq(r2.crash, nil, "no crash: " .. tostring(r2.crash))
    T.ok(named(r2.landed, "Tailwhip to Barspin"), "chained into one trick")
end)

T.test("scooter tricks: a tailwhip and a backflip in one air land as a Bri Flip", function()
    local r = fly(function(t, inp, e)
        inp.whip = between(t, 0.12, 0.6) and 1 or 0
        -- A back flip: nose up (S in the air), held until a whole turn is nearly done, then let go.
        local turned = math.abs(e.st.spinPitch or 0)
        inp.pitchTarget = (t > 0.05 and turned < TAU * 0.78) and 1 or 0
    end, { vz = 420 })
    local names = {}
    for _, t in ipairs(r.landed or {}) do names[#names + 1] = t.name .. " x" .. t.count end
    local landedAny = r.landed and #r.landed > 0
    T.ok(landedAny, "it landed with a score: crash " .. tostring(r.crash))
    if r.crash == nil and named(r.landed, "Backflip") == nil then
        T.ok(named(r.landed, "Bri Flip") ~= nil, "the whip and the flip are one trick: " .. table.concat(names, ", "))
        T.ok(named(r.landed, "Tailwhip") == nil, "and not also paid alone")
    end
end)

T.test("scooter tricks: the rear-wheel manual is paid as a Manual, not a Wheelie", function()
    local sv = F.server()
    local B = sv.env.BMX
    local st = B.NewState(B.Config)
    st.def = B.Vehicles.scooter
    local front = { onGround = false }
    local rear = { onGround = true }
    local paid
    for _ = 1, 66 * 3 do
        paid = B.TrackManual(st, B.Config, front, rear, 150, 1 / 66) or paid
    end
    paid = B.TrackManual(st, B.Config, { onGround = true }, { onGround = true }, 150, 1 / 66)
    for _ = 1, 66 do paid = paid or B.TrackManual(st, B.Config, { onGround = true }, { onGround = true }, 150, 1 / 66) end
    T.ok(paid and paid[1], "a held manual pays")
    T.eq(paid[1].name, "Manual", "under a scooter's name")
    local bike = B.NewState(B.Config)
    bike.def = B.Vehicles.stock
    for _ = 1, 66 * 3 do B.TrackManual(bike, B.Config, front, rear, 150, 1 / 66) end
    local bp
    for _ = 1, 66 do bp = bp or B.TrackManual(bike, B.Config, { onGround = true }, { onGround = true }, 150, 1 / 66) end
    T.eq(bp and bp[1].name, "Wheelie", "a bike's is still a wheelie")
end)

--------------------------------------------------------------------------
-- Closed loop on the plant: grinds
--------------------------------------------------------------------------

local function world(solids)
    local sv = F.server({ solids = solids })
    local e = scooter(sv)
    F.scripted(sv, e)
    sv:run(1.3)
    return sv, e
end

local function pipe(E, len) return { E.Vector(-(len or 400), -1, 28), E.Vector(len or 400, 1, 30) } end
local function ledge(E) return { E.Vector(-800, 0, 0), E.Vector(800, 200, 20) } end

-- The scooter in the air with its crank point `above` over (x, y, zTop), facing `yaw`, moving at `vel`.
local function launch(sv, e, x, y, zTop, above, yaw, vel)
    local E = sv.env
    local ang = E.Angle(0, yaw or 0, 0)
    local crank = E.BMX.GrindPointsFor(e:Bike(), e:Cfg()).crank
    local off = ang:Forward() * crank.x - ang:Right() * crank.y + ang:Up() * crank.z
    F.place(e, E.Vector(x, y, zTop + above) - off, ang)
    e:GetPhysicsObject():SetVelocity(vel)
    e.st.grounded, e.st.groundedFor = false, 0
end

local function paid(e)
    local got = {}
    local orig = e.AwardTricks
    e.AwardTricks = function(self, list)
        for _, t in ipairs(list) do got[#got + 1] = t end
        return orig(self, list)
    end
    return got
end

T.test("scooter grind: a hop onto a round rail along it locks a 50-50, the deck on the rail, and pays it", function()
    local sv0 = F.server()
    local sv, e = world({ pipe(sv0.env, 600) })
    local E = sv.env
    local got = paid(e)
    F.input(e, {})
    launch(sv, e, -200, 0.5, 30, 5, 5, E.Vector(280, 0, -30))
    local locked
    sv:run(0.3, function() locked = locked or e.st.grind end)
    T.ok(locked, "locked on")
    T.eq(locked and locked.move, "scooter_5050", "a 50-50")
    T.eq(locked and locked.kind, "crank", "on a round rail")
    T.eq(e:GetGrind(), E.BMX.Scooter.SparkCode.scooter_5050, "networked as the scooter's deck, for the sparks")
    local contact = e:LocalToWorld(locked.localPoint)
    T.near(contact.z, 30.3, 0.9, "the deck's contact is on the rail's top: " .. contact.z)
    T.near(contact.y, 0, 1.0, "on its line: " .. contact.y)
    T.ok(math.abs(e:GetForward().y) < 0.25, "turned along it")
    T.ok(E.IsValid(e:GetDriver()), "rider aboard")
    T.eq(#sv.errors, 0, "no errors: " .. table.concat(sv.errors, " | "))
    sv:run(4)
    local p = named(got, "50-50")
    T.ok(p and p.points > 40, "a 50-50 was paid: " .. tostring(p and p.points))
end)

T.test("scooter grind: W as it lands on a ledge is a smith (the front peg), S a feeble (the back peg), and no key the deck", function()
    local function ride(key)
        local sv0 = F.server()
        local sv, e = world({ ledge(sv0.env) })
        local E = sv.env
        local inp = { throttle = key == "w" and 1 or 0, brakeRear = key == "s" and 1 or 0 }
        -- In the air the bike's decoder turns W / S into the pitch target.
        F.input(e, inp)
        e.input.pitchTarget = key == "w" and -1 or (key == "s" and 1 or 0)
        launch(sv, e, -300, 2, 20, 5, 5, E.Vector(300, 0, -30))
        local g
        sv:run(0.4, function() g = g or e.st.grind end)
        return sv, e, g
    end
    local half
    for key, want in pairs({ [""] = "scooter_5050", w = "scooter_smith", s = "scooter_feeble" }) do
        local sv, e, g = ride(key)
        T.ok(g, "key '" .. key .. "': locked on")
        if g then
            T.eq(g.move, want, "key '" .. key .. "': the move")
            T.eq(g.kind, "peg", "on a ledge's edge")
            half = e:Cfg().Wheel.wheelbase * 0.5
            local contact = e:LocalToWorld(g.localPoint)
            T.near(contact.z, 20.3, 0.9, want .. ": the contact is on the ledge's top: " .. contact.z)
            if want ~= "scooter_5050" then
                T.near(math.abs(g.localPoint.x), half, 0.01, want .. ": a peg, on an axle")
                T.ok(e:GetPhysicsObject():GetVelocity().x > 100, want .. ": sliding along it")
            end
            T.ok(sv.env.IsValid(e:GetDriver()), want .. ": rider aboard")
        end
        T.eq(#sv.errors, 0, "no errors: " .. table.concat(sv.errors, " | "))
    end
end)

T.test("scooter grind: a scooter coming across a rail does not lock on: there is no slide", function()
    local sv0 = F.server()
    local sv, e = world({ pipe(sv0.env, 600) })
    local E = sv.env
    F.input(e, {})
    launch(sv, e, -200, 0.5, 30, 5, 90, E.Vector(0, 280, -30))
    local any = false
    sv:run(0.5, function() any = any or e.st.grind ~= nil end)
    T.ok(not any, "no grind across the rail")
end)

T.test("scooter grind: a bike and a board still lock on as they did, with their own moves untouched", function()
    local sv0 = F.server()
    local sv = F.server({ solids = { pipe(sv0.env, 600) } })
    local bike = F.bike(sv)
    F.scripted(sv, bike)
    sv:run(1.3)
    F.input(bike, {})
    local E = sv.env
    local ang = E.Angle(0, 5, 0)
    local crank = E.BMX.GrindCrankPoint(bike:Cfg())
    local off = ang:Forward() * crank.x - ang:Right() * crank.y + ang:Up() * crank.z
    F.place(bike, E.Vector(-200, 0.5, 35) - off, ang)
    bike:GetPhysicsObject():SetVelocity(E.Vector(280, 0, -30))
    bike.st.grounded, bike.st.groundedFor = false, 0
    local g
    sv:run(0.4, function() g = g or bike.st.grind end)
    T.ok(g and g.kind == "crank" and g.move == nil, "a bike's crank grind has no scooter move")
    T.eq(bike:GetGrind(), 1, "and its own spark code")
end)

--------------------------------------------------------------------------
-- The drawing
--------------------------------------------------------------------------

local function cscene()
    local sv, world = F.server()
    local cl = F.client(world)
    local E = cl.env
    local ent = cl:clientEntity("bmx_scooter")
    ent:SetPos(E.Vector(0, 0, 3))
    cl.localPlayer = sv:player("Looker")
    return cl, ent, E
end

local function cdraw(cl, ent)
    cl.lines, cl.beams, cl.drawnModels, cl.boxes3d = 0, {}, 0, 0
    ent:Draw()
end

T.test("scooter draw: it draws to the end, with finite parts, and records both hands and both feet", function()
    local cl, ent = cscene()
    cdraw(cl, ent)
    T.ok(ent.ikTargets, "the IK targets were recorded")
    for _, k in ipairs({ "lFoot", "rFoot", "lHand", "rHand" }) do
        local p = ent.ikTargets[k]
        T.ok(p and p.x == p.x and p.y == p.y and p.z == p.z, k .. " is a real point")
    end
    T.ok(#cl.beams + #cl.drawnCS > 12, "something was drawn: " .. (#cl.beams + #cl.drawnCS))
    for _, b in ipairs(cl.beams) do T.ok(b.a.x == b.a.x and b.b.z == b.b.z, "no NaN in a part") end
    -- Both feet on the deck (its top is about 1.7 over the axle line), the left one ahead; the hands at the bars.
    local ik = ent.ikTargets
    T.ok(ik.lFoot.x > ik.rFoot.x, "the front foot is ahead of the back one")
    T.ok(ik.lFoot.z > 2 and ik.lFoot.z < 12, "on the deck: " .. ik.lFoot.z)
    T.ok(ik.rHand.z > 25 and ik.lHand.z > 25, "the hands are up at the bars: " .. ik.rHand.z)
    T.ok(ik.rHand.y ~= ik.lHand.y, "one on each grip")
end)

T.test("scooter draw: a whip turns the deck about the steer tube and leaves the bars, the hands and the feet", function()
    local cl, ent, E = cscene()
    cdraw(cl, ent)
    local h0, f0 = ent.ikTargets.rHand, ent.ikTargets.rFoot
    local n0 = #cl.beams
    ent.drawWhip = math.pi
    ent:SetTrickBits(128)
    cdraw(cl, ent)
    local h1, f1 = ent.ikTargets.rHand, ent.ikTargets.rFoot
    T.near((h1 - h0):Length(), 0, 1e-6, "the hands are where the bars were")
    T.near((f1 - f0 - E.Vector(0, 0, f1.z - f0.z)):Length(), 0, 1e-6, "the feet stay over where the deck was")
    T.ok(f1.z - f0.z > 3, "and have jumped up off it to let it pass under: " .. (f1.z - f0.z))
    ent.drawWhip = 0
    ent:SetTrickBits(0)
    cdraw(cl, ent)
    T.near((ent.ikTargets.rFoot - f0):Length(), 0, 1e-6, "and come down on it again as it comes home")
    T.ok(#cl.beams + #cl.drawnCS >= 12, "and it is still a whole scooter")
    for _, b in ipairs(cl.beams) do T.ok(b.a.x == b.a.x and b.b.z == b.b.z, "no NaN mid-whip") end
end)

T.test("scooter draw: a barspin lets the hands stay on the unspun bars; every pose draws", function()
    local cl, ent = cscene()
    cdraw(cl, ent)
    local h0 = ent.ikTargets.rHand
    ent.drawBar = math.pi
    ent:SetTrickBits(128 * 256)
    cdraw(cl, ent)
    local off = ent.ikTargets.rHand - h0
    T.ok(off.z > 1.5 and off:Length() < 5, "the hands let go, up off the bar, while it goes round: " .. off.z)
    T.ok((ent.ikTargets.rHand - ent.ikTargets.lHand):Length() > 12, "still a hand each side")
    ent.drawBar = 0
    ent:SetTrickBits(0)
    cdraw(cl, ent)
    T.near((ent.ikTargets.rHand - h0):Length(), 0, 1e-6, "and take the grips again as the bars come home")
    local B = cl.env.BMX
    for _, n in ipairs(B.PoseNames) do
        ent:SetTrickBits(B.PoseIDs[n] * 65536)
        for _ = 1, 12 do cdraw(cl, ent) end
        for _, k in ipairs({ "lFoot", "rFoot", "lHand", "rHand" }) do
            local p = ent.ikTargets[k]
            T.ok(p.x == p.x and p.z == p.z, n .. ": " .. k .. " is finite")
        end
    end
end)

T.test("scooter draw: the pose set has its own style poses, hands raised for a standing rider", function()
    local cl = cscene()
    local B = cl.env.BMX
    local set = B.PoseSets.scooter
    T.ok(set.rider and set.poses and set.solveIK and set.activity, "the pose set is filled in")
    T.ok(set.poses.nohander.rHand.z > B.RiderPoses.nohander.rHand.z, "a no-hander's hands are higher than a seated rider's")
    local row = set.rider({ ply = nil, hop = 0.5, speed = 200, pitch = 0, steer = 0.1 })
    T.ok(row.spine and row.head, "the torso and head offsets")
end)

T.test("scooter draw: a scooter's sparks come off the deck and the pegs, the bike's and the board's unchanged", function()
    local cl, ent = cscene()
    local B = cl.env.BMX
    local pts = B.GrindContacts(ent, 10)
    T.eq(#pts, 1, "the deck")
    T.ok(pts[1].z < 0, "under the deck: " .. pts[1].z)
    T.eq(#B.GrindContacts(ent, 11), 1, "the front peg")
    T.eq(#B.GrindContacts(ent, 12), 1, "the back peg")
    T.ok(B.GrindContacts(ent, 11)[1].x > 0 and B.GrindContacts(ent, 12)[1].x < 0, "front and back")
    T.eq(#B.GrindContacts(ent, 4), 2, "a board's 50-50 is still two trucks")
end)

--------------------------------------------------------------------------
-- The headless suite's bookkeeping (sv_test_cases.lua)
--------------------------------------------------------------------------

T.test("headless: the scooter has its own cases and the pedal-free riding cases run on it too", function()
    local sv = F.server()
    local S = sv.env.BMX.Test
    for _, name in ipairs({ "scooter_pushes_to_speed", "scooter_carves_without_tipping", "scooter_tailwhip_lands",
                            "scooter_50_50_on_rail" }) do
        T.ok(S.cases[name], name .. " exists")
        T.eq(S.cases[name].vehicle, "scooter", name .. " rides the scooter")
        T.ok(S.cases[name].rider, name .. " seats a rider")
    end
    for _, name in ipairs({ "rest", "parked_on_stand", "fallen_is_picked_up", "lean_steers", "lean_tracks_target",
                            "bunny_hop", "air_mode", "crash_ejects", "into_a_wall_stops", "climbs_curb_slow",
                            "curb_no_pop" }) do
        local v = S.cases[name .. "@scooter"]
        T.ok(v, name .. "@scooter exists")
        if v then
            T.eq(v.bike, "scooter", name .. "@scooter rides the scooter")
            T.ok(v.fn == S.cases[name].fn, name .. "@scooter is the same case body")
        end
    end
    -- None of the cases that need a pedal or a front brake is on it.
    for _, name in ipairs({ "wheelie@scooter", "stoppie@scooter", "accelerate@scooter", "brake_locks@scooter" }) do
        T.eq(S.cases[name], nil, name .. " is not run: the scooter has no pedals and no front brake")
    end
end)
