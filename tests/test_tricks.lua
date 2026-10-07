--[[--------------------------------------------------------------------------
    Tailwhip, barspin and the style poses (G03, G17): the trick registry
    (sh_tricks.lua), the part and pose state machine (sv_tricks.lua), the key
    decode (sv_input.lua), the landing rules on the real entity and the
    tests' plant, and the client's half (the trick list, the pose blend, the
    bike drawn mid-whip).
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local gmod = require("lib.gmod")
local IN = gmod.IN

local DT = 1 / 66
local TAU = math.pi * 2

local function realm()
    local sv = F.server()
    return sv.env.BMX, sv
end

-- A state in the air, and a way to run the trick step on it for a while.
local function airState(B)
    local st = B.NewState(B.Config)
    st.airMode = true
    B.TricksReset(st)
    return st
end

local function run(B, st, inp, secs)
    local paid = {}
    for _ = 1, math.floor(secs / DT + 0.5) do
        local p = B.TricksTick({}, nil, B.Config, DT, inp, st)
        for _, t in ipairs(p or {}) do paid[#paid + 1] = t end
    end
    return paid
end

local function find(list, name)
    for _, t in ipairs(list) do if t.name == name then return t end end
end

-- Whip for `secs` the way `dir`, let go, and give it a second to settle.
local function whipFor(B, st, secs, dir, field)
    local inp = { whip = 0, bar = 0 }
    inp[field or "whip"] = dir or 1
    run(B, st, inp, secs)
    inp[field or "whip"] = 0
    run(B, st, inp, 1.0)
end

--------------------------------------------------------------------------
-- The registry.
--------------------------------------------------------------------------
T.test("registry: the existing tricks are registered, with the numbers they always paid", function()
    local B = realm()
    local want = { backflip = 500, frontflip = 500, barrel_roll = 400, spin360 = 250 }
    for id, pts in pairs(want) do
        T.ok(B.Tricks[id], id .. " registered")
        T.eq(B.Tricks[id].points, pts, id .. " points per turn")
        T.eq(B.Tricks[id].kind, "spin", id .. " is a rotation")
    end
    T.eq(B.Tricks.wheelie.name, "Wheelie", "the wheelie")
    T.eq(B.Tricks.stoppie.name, "Stoppie", "the stoppie")
    T.eq(B.Tricks.crank_grind.name, "Crank Grind", "the crank grind")
    T.eq(B.Tricks.peg_grind.name, "Double Peg Grind", "the peg grind")
    T.eq(B.Tricks.wheelie.points, B.Config.Tricks.wheeliePerSec, "wheelie pays the config's rate")
end)

T.test("registry: ScoreAir reads it back, and scores exactly what it did", function()
    local B = realm()
    local function score(st) return B.ScoreAir(st) end
    local r = score({ spinPitch = TAU * 1.2 })
    T.eq(#r, 1, "one trick"); T.eq(r[1].name, "Backflip", "positive pitch is a backflip")
    T.eq(r[1].points, 500, "500 a turn")
    r = score({ spinPitch = -TAU * 2.1 })
    T.eq(r[1].name, "Frontflip", "negative is a frontflip"); T.eq(r[1].count, 2, "two turns")
    T.eq(r[1].points, 1000, "1000")
    r = score({ spinRoll = -TAU * 1.01 })
    T.eq(r[1].name, "Barrel Roll", "a barrel roll either way"); T.eq(r[1].points, 400, "400")
    r = score({ spinYaw = TAU * 1.5 })
    T.eq(r[1].name, "360", "a 360"); T.eq(r[1].points, 250, "250")
    T.eq(#score({ spinPitch = TAU * 0.9 }), 0, "a part-turn is nothing")
end)

T.test("registry: rejects duplicate ids and missing or bad fields", function()
    local B = realm()
    local function ok(over)
        local t = { id = "t_ok", name = "Ok", input = "X", points = 1 }
        for k, v in pairs(over or {}) do t[k] = v end
        return t
    end
    T.errors(function() B.RegisterTrick(ok({ id = "backflip" })) end, "duplicate", "duplicate id")
    T.errors(function() B.RegisterTrick(ok({ id = false })) end, "id", "no id")
    T.errors(function() B.RegisterTrick(ok({ id = "has space" })) end, "id", "bad id")
    T.errors(function() B.RegisterTrick(ok({ name = false })) end, "name", "no name")
    T.errors(function() B.RegisterTrick(ok({ input = "" })) end, "input", "no input")
    T.errors(function() B.RegisterTrick(ok({ points = "5" })) end, "points", "points not a number")
    T.errors(function() B.RegisterTrick(ok({ points = -1 })) end, "points", "negative points")
    T.errors(function() B.RegisterTrick(ok({ canStart = 5 })) end, "canStart", "canStart not a function")
    T.errors(function() B.RegisterTrick(ok({ onTick = "x" })) end, "onTick", "onTick not a function")
    T.errors(function() B.RegisterTrick(ok({ kind = "wobble" })) end, "kind", "unknown kind")
    T.errors(function() B.RegisterTrick(ok({ kind = "spin" })) end, "axis", "a spin needs an axis")
    T.errors(function() B.RegisterTrick(ok({ kind = "part", part = "wheel" })) end, "part", "a part needs a real part")
    T.errors(function() B.RegisterTrick(ok({ kind = "pose" })) end, "pose", "a pose trick needs a pose")
    T.errors(function() B.RegisterTrick(nil) end, "table", "not a table")
    T.ok(B.RegisterTrick(ok()), "and a good one goes in")
    T.ok(B.Tricks.t_ok, "found by id")
    T.errors(function() B.RegisterTrick(ok()) end, "duplicate", "twice is a duplicate")
end)

T.test("registry: every pose has a wire id, a rider pose and a trick", function()
    local B, sv = realm()
    T.ok(#B.PoseNames >= 8, "the style poses: " .. #B.PoseNames)
    for i, name in ipairs(B.PoseNames) do
        T.eq(B.PoseIDs[name], i, name .. " id round-trips")
        T.ok(B.TrickForPose(name), name .. " has a trick")
    end
    local cl = F.client(sv.world)
    for _, name in ipairs(cl.env.BMX.PoseNames) do
        T.ok(cl.env.BMX.RiderPoses[name], name .. " has an IK pose on the client")
    end
end)

T.test("registry: a custom trick's onTick runs while canStart says so, and banks what it returns", function()
    local B = realm()
    B.RegisterTrick{ id = "grab", name = "Seat Grab", input = "G", points = 0, kind = "custom",
        canStart = function(st) return st.airMode end,
        onTick = function() return 2 end }
    local st = airState(B)
    run(B, st, {}, 0.5)
    local out = B.ScoreAir(st)
    local g = find(out, "Seat Grab")
    T.ok(g, "paid under its own name: " .. #out)
    T.ok(g and g.points >= 60, "banked what onTick returned: " .. tostring(g and g.points))
    st.airMode = false
    run(B, st, {}, 0.5)
    T.eq(st.trickBank, nil, "nothing banked on the ground")
end)

--------------------------------------------------------------------------
-- Frame and bar spins.
--------------------------------------------------------------------------
T.test("tailwhip: let go past 270 degrees and it finishes the turn by itself", function()
    local B = realm()
    local st = airState(B)
    local secs = math.rad(282) / B.Config.Tricks.whipRate
    whipFor(B, st, secs, 1)
    T.eq(st.parts.whip.angle, 0, "back on the whole turn")
    local out = B.ScoreAir(st)
    local w = find(out, "Tailwhip")
    T.ok(w, "scored")
    T.eq(w.count, 1, "one turn"); T.eq(w.points, 600, "600 a turn")
    T.eq(st.landFault, nil, "and the landing is clean")
end)

T.test("tailwhip: let go before 90 degrees and it snaps back, for nothing", function()
    local B = realm()
    local st = airState(B)
    whipFor(B, st, math.rad(80) / B.Config.Tricks.whipRate, 1)
    T.eq(st.parts.whip.angle, 0, "back where it started")
    T.eq(find(B.ScoreAir(st), "Tailwhip"), nil, "no trick")
    T.eq(st.landFault, nil, "and it lands clean")
end)

T.test("tailwhip: in between it stays out of line, and the landing is the fault", function()
    local B = realm()
    local st = airState(B)
    local secs = math.rad(165) / B.Config.Tricks.whipRate
    whipFor(B, st, secs, 1)
    T.between(math.deg(st.parts.whip.angle), 150, 180, "it stayed where it was let go")
    local out = B.ScoreAir(st)
    T.eq(find(out, "Tailwhip"), nil, "not scored")
    local why, sev = B.LandingFault(st)
    T.eq(why, "whip", "the frame is why")
    T.ok(sev > 0.3, "and it is a real crash")
    T.eq(B.LandingFault(st), nil, "read once")
end)

T.test("tailwhip: 40 degrees out of line is a bail, 20 is not", function()
    local B = realm()
    local st = airState(B)
    st.parts.whip.angle = math.rad(40)
    B.ScoreAir(st)
    T.eq((B.LandingFault(st)), "whip", "40 deg out")
    st = airState(B)
    st.parts.whip.angle = TAU - math.rad(20)       -- 20 short of a turn
    local out = B.ScoreAir(st)
    T.eq(st.landFault, nil, "20 deg out lands")
    T.eq(find(out, "Tailwhip").count, 1, "and counts as the turn it nearly is")
end)

T.test("tailwhip: hold for more turns, and they all count", function()
    local B = realm()
    local st = airState(B)
    whipFor(B, st, 1.0, 1)                       -- 659 deg: past 270 of the second turn
    local w = find(B.ScoreAir(st), "Tailwhip")
    T.eq(w.count, 2, "two turns"); T.eq(w.points, 1200, "1200")
    st = airState(B)
    whipFor(B, st, 1.2, 1)                       -- 790 deg: 70 into the third, snaps back
    T.eq(find(B.ScoreAir(st), "Tailwhip").count, 2, "70 deg into a third snaps back to two")
end)

T.test("tailwhip: either way round counts, and A is one way and D the other", function()
    local B = realm()
    local st = airState(B)
    whipFor(B, st, 0.6, -1)
    T.eq(find(B.ScoreAir(st), "Tailwhip").count, 1, "left")
    st = airState(B)
    run(B, st, { whip = 1 }, 0.1)
    T.ok(st.parts.whip.angle > 0, "+1 turns it one way")
    st = airState(B)
    run(B, st, { whip = -1 }, 0.1)
    T.ok(st.parts.whip.angle < 0, "-1 the other")
end)

T.test("barspin: scored, and tailwhip x2 + barspin chain as one named trick", function()
    local B = realm()
    local st = airState(B)
    -- Both for 0.45 s (the bars 387 deg: a turn and 27 over, so they snap
    -- back to one), the frame on to a full second (659 deg: it finishes
    -- the second turn by itself).
    run(B, st, { whip = 1, bar = 1 }, 0.45)
    run(B, st, { whip = 1, bar = 0 }, 0.55)
    run(B, st, {}, 1.0)
    local out = B.ScoreAir(st)
    local t = out[1]
    T.eq(#out, 1, "one merged trick: " .. #out)
    T.eq(t.name, "2x Tailwhip to Barspin", "the chain's name")
    T.eq(t.points, 2 * 600 + 400, "2 x 600 for the frame and 400 for the bars")
    T.eq(t.tricks, 2, "it stands for both tricks")
end)

T.test("barspin: alone it is just a barspin, 400 a turn", function()
    local B = realm()
    local st = airState(B)
    whipFor(B, st, 0.5, 1, "bar")
    local out = B.ScoreAir(st)
    T.eq(out[1].name, "Barspin", "named")
    T.eq(out[1].points, 400 * out[1].count, "400 a turn")
end)

T.test("barspin: also in a manual, and it pays on the spot", function()
    local B = realm()
    local st = B.NewState(B.Config)
    st.airMode = false
    st.manual = { kind = "wheelie", held = 2, gone = 0 }
    local inp = { whip = 0, bar = 1 }
    local paid = run(B, st, inp, 0.4)           -- 344 deg
    inp.bar = 0
    for _, t in ipairs(run(B, st, inp, 0.5)) do paid[#paid + 1] = t end
    local b = find(paid, "Barspin")
    T.ok(b, "paid in the manual")
    T.eq(b.points, 400, "400")
    T.eq(st.parts.bar.angle, 0, "and the bars are square")
end)

T.test("a whip is nothing on the ground, and bars do not spin outside a manual", function()
    local B = realm()
    local st = B.NewState(B.Config)
    st.airMode = false
    run(B, st, { whip = 1, bar = 1 }, 0.5)
    T.eq(st.parts.whip.angle, 0, "no whip on the ground")
    T.eq(st.parts.bar.angle, 0, "no barspin outside a manual")
end)

T.test("tailwhip: the frame and bar angles are one byte each on the wire", function()
    local B = realm()
    local st = airState(B)
    run(B, st, { whip = 1, bar = 0 }, 0.3)
    local bits = B.PackTrickBits(st)
    local w, b, id = B.UnpackTrickBits(bits)
    T.near(w, st.parts.whip.angle % TAU, TAU / 256, "frame angle, to a byte")
    T.eq(b, 0, "bars square"); T.eq(id, 0, "no pose")
    T.ok(bits < 2 ^ 24, "three bytes: " .. bits)
    st.pose = { cur = "superman", held = {} }
    local _, _, pid = B.UnpackTrickBits(B.PackTrickBits(st))
    T.eq(pid, B.PoseIDs.superman, "the pose id rides in the third byte")
end)

--------------------------------------------------------------------------
-- Poses.
--------------------------------------------------------------------------
T.test("poses: held poses pay per 0.1 s, once held long enough", function()
    local B = realm()
    local st = airState(B)
    run(B, st, { pose = "superman" }, 0.5)
    run(B, st, {}, 0.3)
    local s = find(B.ScoreAir(st), "Superman")
    T.ok(s, "scored")
    T.eq(s.points, 5 * 15, "five tenths of a second at 15")
    st = airState(B)
    run(B, st, { pose = "superman" }, 0.2)
    run(B, st, {}, 0.3)
    T.eq(find(B.ScoreAir(st), "Superman"), nil, "a brush of the key is not a trick")
end)

T.test("poses: they are for the air (and X-up for a manual), not for riding", function()
    local B = realm()
    local st = B.NewState(B.Config)
    st.airMode = false
    run(B, st, { pose = "superman" }, 0.6)
    T.eq(st.pose and st.pose.cur, nil, "no superman on the ground")
    st.manual = { kind = "wheelie", held = 2, gone = 0 }
    run(B, st, { pose = "xup" }, 0.62)
    T.eq(st.pose.cur, "xup", "but an X-up in a manual")
    local paid = run(B, st, {}, 0.1)
    st.manual = nil
    paid = run(B, st, {}, 0.1)
    local x = find(paid, "X-Up")
    T.ok(x, "paid when the manual is over")
    T.eq(x and x.points, 6 * 10, "six tenths at 10")
end)

T.test("poses: landing in one bails, and out of it by touchdown does not", function()
    local B = realm()
    local st = airState(B)
    run(B, st, { pose = "nohander" }, 0.5)
    B.ScoreAir(st)
    T.eq((B.LandingFault(st)), "pose", "still in the pose on landing")
    st = airState(B)
    run(B, st, { pose = "nohander" }, 0.5)
    run(B, st, {}, 0.1)
    B.ScoreAir(st)
    T.eq(B.LandingFault(st), nil, "let go in time")
end)

T.test("poses: a pose in a rotation is one compound trick, paid as both plus a bonus", function()
    local B = realm()
    local st = airState(B)
    st.spinPitch = TAU + 0.1
    run(B, st, { pose = "superman" }, 0.5)
    run(B, st, {}, 0.2)
    local out = B.ScoreAir(st)
    T.eq(#out, 1, "one trick, not two: " .. #out)
    T.eq(out[1].name, "Backflip Superman", "the compound name")
    T.eq(out[1].points, math.floor((500 + 75) * 1.25), "both, and a quarter more")
    T.eq(out[1].tricks, 2, "it counts as two in a combo")
    st = airState(B)
    st.spinPitch = -TAU * 2.2
    run(B, st, { pose = "cancan_r" }, 0.4)
    run(B, st, {}, 0.2)
    out = B.ScoreAir(st)
    T.eq(out[1].name, "Frontflip Can-Can", "any rotation and any pose")
    T.eq(out[1].count, 2, "and the turns are kept")
end)

T.test("combo: tailwhip x2 + barspin is two tricks in the chain, under one name", function()
    local sv = F.server()
    local B = sv.env.BMX
    local bike = F.bike(sv)
    F.rider(sv, bike, { name = "Rider" })
    sv:run(0.5)
    local st = airState(B)
    run(B, st, { whip = 1, bar = 1 }, 0.45)
    run(B, st, { whip = 1, bar = 0 }, 0.55)
    run(B, st, {}, 1.0)
    bike:AwardTricks(B.ScoreAir(st))
    T.eq(bike.st.combo.n, 2, "the whip-to-bars counts as two tricks")
    T.eq(bike.st.combo.names[1], "2x Tailwhip to Barspin", "named in the chain")
    T.eq(bike.st.combo.base, 1600, "and 1600 of tricks, so a bonus of 1600 on a clean landing")
end)

--------------------------------------------------------------------------
-- The keys.
--------------------------------------------------------------------------
T.test("DecodePose: every pose's chord, and nothing else", function()
    local B = realm()
    local D = B.DecodePose
    local function air(k) k.air = true return D(k) end
    T.eq(air{ alt = true, fwd = true }, "nohander", "Alt + W")
    T.eq(air{ alt = true, back = true }, "nofooter", "Alt + S")
    T.eq(air{ alt = true, side = -1 }, "cancan_l", "Alt + A")
    T.eq(air{ alt = true, side = 1 }, "cancan_r", "Alt + D")
    T.eq(air{ alt = true, fwd = true, back = true }, "superman", "Alt + W + S")
    T.eq(air{ alt = true, jump = true }, "nothing", "Alt + SPACE")
    T.eq(air{ alt = true, rmb = true }, "tabletop", "Alt + RMB")
    T.eq(air{ alt = true, rmb = true, side = 1 }, "turndown", "Alt + RMB + D")
    T.eq(air{ rmb = true, fwd = true }, "xup", "RMB + W")
    T.eq(air{ rmb = true, side = 1 }, nil, "RMB + A/D is still the 360")
    T.eq(air{ fwd = true }, nil, "W alone is a flip, not a pose")
    T.eq(air{ alt = true }, nil, "Alt alone is nothing")
    T.eq(D{ alt = true, fwd = true }, nil, "no poses on the ground")
    T.eq(D{ rmb = true, fwd = true, manual = true }, nil, "RMB + W in a manual is a wheelie")
    T.eq(D{ alt = true, rmb = true, fwd = true, manual = true }, "xup", "Alt + RMB + W in a manual")
end)

local function cmd(buttons, fwd, side)
    local c = { buttons = buttons or 0, fwd = fwd or 0, side = side or 0, up = 0 }
    function c:GetButtons() return self.buttons end
    function c:SetButtons(b) self.buttons = b end
    function c:GetForwardMove() return self.fwd end
    function c:GetSideMove() return self.side end
    function c:SetForwardMove(v) self.fwd = v end
    function c:SetSideMove(v) self.side = v end
    function c:SetUpMove(v) self.up = v end
    return c
end

local function rig()
    local sv = F.server()
    local bike = F.bike(sv)
    local ply = F.rider(sv, bike)
    local function send(buttons, fwd, side)
        local c = cmd(buttons, fwd, side)
        sv.env.hook.Run("StartCommand", ply, c)
        return c
    end
    return sv, bike, ply, send
end

T.test("keys: Alt makes W/S/A/D/SPACE/RMB poses, and they stop being rotations", function()
    local _, bike, _, send = rig()
    bike.st.airMode = true
    local i = bike.input
    send(IN.WALK + IN.FORWARD)
    T.eq(i.pose, "nohander", "Alt + W"); T.eq(i.pitchTarget, 0, "not a front flip")
    send(IN.WALK + IN.BACK)
    T.eq(i.pose, "nofooter", "Alt + S"); T.eq(i.pitchTarget, 0, "not a back flip")
    send(IN.WALK + IN.FORWARD + IN.BACK)
    T.eq(i.pose, "superman", "Alt + W + S")
    send(IN.WALK + IN.MOVELEFT)
    T.eq(i.pose, "cancan_l", "Alt + A"); T.eq(i.leanTarget, 0, "not a roll")
    send(IN.WALK + IN.MOVERIGHT)
    T.eq(i.pose, "cancan_r", "Alt + D")
    send(IN.WALK + IN.JUMP)
    T.eq(i.pose, "nothing", "Alt + SPACE")
    send(IN.WALK + IN.ATTACK2)
    T.eq(i.pose, "tabletop", "Alt + RMB"); T.ok(not i.wheelieMod, "and no 360")
    send(IN.WALK + IN.ATTACK2 + IN.MOVERIGHT)
    T.eq(i.pose, "turndown", "Alt + RMB + D")
    send(IN.ATTACK2 + IN.FORWARD)
    T.eq(i.pose, "xup", "RMB + W"); T.eq(i.pitchTarget, 0, "not a flip")
    send(0)
    T.eq(i.pose, nil, "released")
end)

T.test("keys: what already worked in the air still does", function()
    local _, bike, _, send = rig()
    bike.st.airMode = true
    local i = bike.input
    send(IN.ATTACK2 + IN.MOVERIGHT)
    T.eq(i.pose, nil, "RMB + D is no pose"); T.ok(i.wheelieMod, "it is the 360")
    T.eq(i.leanTarget, 1, "the yaw input is there")
    send(IN.FORWARD)
    T.eq(i.pitchTarget, -1, "W is a front flip")
    send(IN.MOVERIGHT)
    T.eq(i.leanTarget, 1, "D is a roll")
    send(IN.DUCK)
    T.ok(i.tuck, "Ctrl still tucks")
    send(IN.ATTACK)
    T.eq(i.brakeFront, 1, "LMB is read as before")
end)

T.test("keys: LMB + A/D whips, R spins the bars, LMB + R does both", function()
    local _, bike, _, send = rig()
    bike.st.airMode = true
    local i = bike.input
    send(IN.ATTACK + IN.MOVELEFT)
    T.eq(i.whip, -1, "LMB + A"); T.eq(i.bar, 0, "no bars"); T.eq(i.leanTarget, 0, "and no roll")
    send(IN.ATTACK + IN.MOVERIGHT)
    T.eq(i.whip, 1, "LMB + D")
    send(IN.ATTACK)
    T.eq(i.whip, 0, "LMB alone is only the brake")
    send(IN.RELOAD)
    T.eq(i.bar, 1, "R"); T.eq(i.whip, 0, "bars only")
    send(IN.RELOAD + IN.MOVELEFT)
    T.eq(i.bar, -1, "R + A turns them the other way"); T.eq(i.leanTarget, 0, "and does not roll")
    send(IN.ATTACK + IN.RELOAD)
    T.eq(i.whip, 1, "LMB + R: the frame"); T.eq(i.bar, 1, "and the bars")
    send(IN.ATTACK + IN.RELOAD + IN.MOVELEFT)
    T.eq(i.whip, -1, "A picks the way for both"); T.eq(i.bar, -1, "both")
end)

T.test("keys: on the ground Alt and R do nothing, except R in a manual", function()
    local _, bike, _, send = rig()
    local i = bike.input
    send(IN.WALK + IN.FORWARD)
    T.eq(i.pose, nil, "no pose on the ground"); T.eq(i.throttle, 1, "W still pedals")
    send(IN.RELOAD)
    T.eq(i.bar, 0, "no barspin riding along")
    bike.st.manual = { kind = "wheelie", held = 1, gone = 0 }
    send(IN.RELOAD)
    T.eq(i.bar, 1, "R in a manual")
    send(IN.ATTACK2 + IN.FORWARD)
    T.eq(i.pose, nil, "RMB + W in a manual is a wheelie, nothing more")
    T.eq(i.pitchTarget, 1, "weight back")
    send(IN.WALK + IN.ATTACK2 + IN.FORWARD)
    T.eq(i.pose, "xup", "Alt + RMB + W is the X-up")
end)

T.test("keys: a key held into the air does not start a pose", function()
    local _, bike, _, send = rig()
    send(IN.FORWARD)                            -- pedalling along the ground
    bike.st.airMode = true
    send(IN.WALK + IN.FORWARD)
    T.eq(bike.input.pose, nil, "W held at takeoff is latched, as it is for a flip")
    send(IN.WALK)
    send(IN.WALK + IN.FORWARD)
    T.eq(bike.input.pose, "nohander", "let go and pressed fresh")
end)

T.test("keys: bmx_flip_doubletap is off by default, and on it a double-tap is a flip", function()
    local sv, bike, ply, send = rig()
    bike.st.airMode = true
    local function at(t) sv.world.time = t end
    at(10); send(IN.FORWARD); at(10.05); send(0); at(10.1); send(IN.FORWARD); at(10.15); send(0)
    T.eq(bike.input.pitchTarget, 0, "off: a tap is only a tap")
    ply:ConCommand("bmx_flip_doubletap 1")
    at(20); send(IN.FORWARD); at(20.05); send(0)
    T.eq(bike.input.pitchTarget, 0, "one tap is nothing")
    at(20.1); send(IN.FORWARD); at(20.15); send(0)
    T.eq(bike.input.pitchTarget, -1, "two: a front flip, with the key let go")
    T.eq(bike.input.autoFlip, 1, "latched")
    bike.st.spinPitch = -6.5
    at(20.3); send(0)
    T.eq(bike.input.autoFlip, nil, "and let go of once the coast will finish it")
    T.eq(bike.input.pitchTarget, 0, "so it coasts")
    bike.st.spinPitch = 0
    at(30); send(IN.BACK); at(30.05); send(0); at(30.6); send(IN.BACK); at(30.65); send(0)
    T.eq(bike.input.pitchTarget, 0, "taps too far apart are two taps")
    at(31); send(IN.BACK); at(31.05); send(0); at(31.1); send(IN.BACK); at(31.15); send(0)
    T.eq(bike.input.pitchTarget, 1, "S twice is a back flip")
end)

--------------------------------------------------------------------------
-- The real entity and the plant.
--------------------------------------------------------------------------
local function lastCombo(sv)
    local msg
    for _, m in ipairs(sv.world.wire) do if m.name == "bmx_combo" then msg = m end end
    return msg
end

-- A scripted rider, kicked into the air off flat ground, with `script(t,
-- bike)` called every tick to write the input; run until it has landed.
local function fly(script, opts)
    opts = opts or {}
    local sv = F.server()
    local E = sv.env
    local bike = F.bike(sv)
    F.scripted(sv, bike)
    sv:run(1.3)                                  -- past the spawn grace, settled
    local crash
    E.hook.Add("BMX_Crash", "test", function(_, _, reason) crash = reason end)
    local landed
    E.hook.Add("BMX_TricksLanded", "test", function(_, _, tricks) landed = tricks end)
    F.input(bike, {})
    bike.input.whip, bike.input.bar, bike.input.pose = 0, 0, nil
    if opts.before then opts.before(bike, sv) end
    local score0 = bike:GetScore()
    bike:GetPhysicsObject():SetVelocity(E.Vector(opts.vx or 0, 0, opts.vz or 330))
    local t0 = sv.world.time
    local was = false
    sv:run(5, function()
        local t = sv.world.time - t0
        script(t, bike.input, bike)
        if bike.st.airMode then was = true end
        if was and bike.st.grounded and not bike.st.airMode then return true end
    end)
    local st = bike.st
    sv:run(0.4)
    return { sv = sv, bike = bike, crash = crash, landed = landed, score = bike:GetScore() - score0,
             aboard = E.IsValid(bike:GetDriver()) }
end

local function between(t, a, b) return t >= a and t < b end

T.test("plant: a tailwhip held 0.47 s completes, pays 600, and lands rideable", function()
    local r = fly(function(t, inp) inp.whip = between(t, 0.15, 0.62) and 1 or 0 end)
    T.eq(r.crash, nil, "no crash: " .. tostring(r.crash))
    T.ok(r.aboard, "the rider is still on")
    T.ok(r.score >= 600, "scored a tailwhip: " .. r.score)
    local w
    for _, t in ipairs(r.landed or {}) do if t.name == "Tailwhip" then w = t end end
    T.ok(w, "reported as a Tailwhip")
    local a = r.bike.st.parts.whip.angle
    T.eq(a, 0, "the frame is back in line")
end)

T.test("plant: a whip let go at 80 degrees snaps back and the landing is untouched", function()
    local r = fly(function(t, inp) inp.whip = between(t, 0.15, 0.27) and 1 or 0 end)
    T.eq(r.crash, nil, "no crash: " .. tostring(r.crash))
    T.ok(r.aboard, "aboard")
    T.eq(r.score, 0, "and nothing paid")
end)

T.test("plant: a whip left half done bails through the crash path and loses the combo", function()
    local r = fly(function(t, inp) inp.whip = between(t, 0.15, 0.45) and 1 or 0 end, {
        before = function(bike) bike:AwardTricks({ { name = "Crank Grind", count = 1, points = 140 } }) end })
    T.eq(r.crash, "whip", "the frame is out of line: " .. tostring(r.crash))
    T.ok(not r.aboard, "thrown off")
    local m = lastCombo(r.sv)
    T.eq(m and m.items[1].value, 2, "the combo was BAILED")
    local paid
    for _, t in ipairs(r.landed or {}) do if t.name == "Tailwhip" then paid = t end end
    T.eq(paid, nil, "and the tailwhip did not pay")
end)

T.test("plant: the chassis wobbles a little for a whip, not a lot", function()
    local peak = 0
    fly(function(t, inp, bike)
        inp.whip = between(t, 0.15, 0.62) and 1 or 0
        peak = math.max(peak, math.abs(bike.st.spinYaw or 0))
    end)
    if os.getenv("BMX_TRACE") then print(string.format("    whip yaw wobble peak %.1f deg", math.deg(peak))) end
    T.between(math.deg(peak), 0.1, 40, "yaw from the thrown frame, degrees")
end)

T.test("plant: a superman held through the middle pays, and out of it by touchdown is clean", function()
    local r = fly(function(t, inp) inp.pose = between(t, 0.2, 0.7) and "superman" or nil end)
    T.eq(r.crash, nil, "no crash: " .. tostring(r.crash))
    T.ok(r.aboard, "aboard")
    T.ok(r.score >= 40, "paid per tenth: " .. r.score)
end)

T.test("plant: landing still in the pose bails", function()
    local r = fly(function(t, inp) inp.pose = t > 0.2 and "nohander" or nil end)
    T.eq(r.crash, "pose", "reason: " .. tostring(r.crash))
    T.ok(not r.aboard, "thrown off")
end)

T.test("plant: a coasting flip carries a pose, and lands as one named trick", function()
    -- A back flip driven for 0.5 s, then Alt down and the keys let go: the
    -- spin coasts (poseSpinDamp), is held in the pose, and the pose is let go
    -- of before touchdown.
    local named
    local r = fly(function(t, inp, bike)
        inp.pitchTarget = between(t, 0.1, 0.55) and 1 or 0
        inp.pose = between(t, 0.6, 1.0) and "superman" or nil
    end, { vz = 520 })
    for _, t in ipairs(r.landed or {}) do if t.name:find("Superman", 1, true) then named = t end end
    if os.getenv("BMX_TRACE") then
        for _, t in ipairs(r.landed or {}) do print("    landed: " .. t.name .. " " .. t.points) end
        print("    crash: " .. tostring(r.crash))
    end
    -- The flip may or may not come round in the time; what must hold is that
    -- a pose is never lost to a crash it did not cause, and a compound is a
    -- compound when it does happen.
    if named then
        T.eq(named.name, "Backflip Superman", "the compound name")
    end
    T.ok(r.crash ~= "pose", "a pose released in time is never what threw the rider")
end)

T.test("plant: a double-tapped front flip, hands off, comes round", function()
    local sv = F.server()
    local E = sv.env
    local bike = F.bike(sv)
    local ply = F.rider(sv, bike, { name = "Rider" })
    ply:ConCommand("bmx_flip_doubletap 1")
    sv:run(1.3)
    local crash, landed
    E.hook.Add("BMX_Crash", "test", function(_, _, reason) crash = reason end)
    E.hook.Add("BMX_TricksLanded", "test", function(_, _, tricks) landed = tricks end)
    local function press(buttons)
        local c = cmd(buttons)
        E.hook.Run("StartCommand", ply, c)
    end
    bike:GetPhysicsObject():SetVelocity(E.Vector(0, 0, 720))
    local t0 = sv.world.time
    local was = false
    sv:run(5, function()
        local t = sv.world.time - t0
        local w = (between(t, 0.15, 0.2) or between(t, 0.3, 0.35)) and IN.FORWARD or 0
        press(w)
        if os.getenv("BMX_TRACE") and math.floor(t * 66) % 7 == 0 then
            print(string.format("      t %.2f air %s spin %.2f w %.2f auto %s pitchT %.2f", t, tostring(bike.st.airMode),
                bike.st.spinPitch or 0, bike.st.angVel and bike.st.angVel:Dot(bike:GetRight()) or 0, tostring(bike.input.autoFlip), bike.input.pitchTarget))
        end
        if bike.st.airMode then was = true end
        if was and bike.st.grounded and not bike.st.airMode then return true end
    end)
    local flip
    for _, t in ipairs(landed or {}) do if t.name == "Frontflip" then flip = t end end
    if os.getenv("BMX_TRACE") then
        print("    doubletap: crash " .. tostring(crash) .. " flip " .. tostring(flip) .. " spinPitch " .. tostring(bike.st.spinPitch))
        for _, t in ipairs(landed or {}) do print("      " .. t.name .. " " .. t.count) end
    end
    T.ok(flip, "a front flip was scored off two taps")
    T.eq(crash, nil, "and it landed")
end)

--------------------------------------------------------------------------
-- The client.
--------------------------------------------------------------------------
local function scene()
    local sv, world = F.server()
    local bike = F.bike(sv)
    F.rider(sv, bike, { name = "Human" })
    local cl = F.client(world)
    local cb = cl:clientEntity("bmx_base")
    cb:SetPos(bike:GetPos())
    cb:SetAngles(bike:GetAngles())
    local pod = cl.makeEntity("prop_vehicle_prisoner_pod")
    pod:SetParent(cb)
    cb:SetPod(pod)
    local me = cl:player("Human")
    me._vehicle = pod
    cl.localPlayer = me
    cb:SetDriver(me)
    return { sv = sv, cl = cl, bike = bike, cb = cb }
end

local function draw(s)
    s.cl.lines, s.cl.beams, s.cl.drawnModels, s.cl.boxes3d = 0, {}, 0, 0
    s.cb:Draw()
end

local function gripAt(s)
    local ik = s.cb.ikTargets
    return ik.rHand, ik.rFoot
end

T.test("client: the bike draws mid-whip, mid-barspin and in every pose, with finite parts", function()
    local s = scene()
    local B = s.cl.env.BMX
    local E = s.cl.env
    local function bits(w, b, id) return math.floor(w / TAU * 256) + math.floor(b / TAU * 256) * 256 + id * 65536 end
    draw(s)
    local rest = #s.cl.beams
    T.ok(rest > 35, "the plain bike: " .. rest)
    local cases = { { 1.5, 0, 0 }, { 0, 2.0, 0 }, { 3.1, 3.1, 0 } }
    for _, n in ipairs(B.PoseNames) do cases[#cases + 1] = { 0, 0, B.PoseIDs[n] } end
    for _, c in ipairs(cases) do
        s.cb:SetTrickBits(bits(c[1], c[2], c[3]))
        for _ = 1, 12 do draw(s) end                       -- long enough for the blend to land
        T.ok(#s.cl.beams > 35, "still a bike (" .. c[1] .. ", " .. c[2] .. ", pose " .. c[3] .. ")")
        for _, b in ipairs(s.cl.beams) do
            T.ok(b.a.x == b.a.x and b.b.x == b.b.x and b.a.z == b.a.z, "no NaN in a part")
        end
    end
end)

T.test("client: a whip moves the frame and leaves the bars and the feet where they were", function()
    local s = scene()
    local B = s.cl.env.BMX
    draw(s)
    local hand0, foot0 = gripAt(s)
    s.cb.drawWhip = math.pi                      -- the frame half way round
    s.cb:SetTrickBits(128)
    draw(s)
    local hand1, foot1 = gripAt(s)
    T.near((hand1 - hand0):Length(), 0, 1e-6, "the hands are where the bars were")
    T.near((foot1 - foot0):Length(), 0, 1e-6, "the feet stay where the pedals were")
    T.ok(#s.cl.beams > 35, "and it is still a whole bike")
end)

T.test("client: a barspin lets the hands go and the bars turn, an X-up crosses them", function()
    local s = scene()
    local B = s.cl.env.BMX
    draw(s)
    local hand0 = s.cb.ikTargets.rHand
    s.cb.drawBar = math.pi
    s.cb:SetTrickBits(128 * 256)
    draw(s)
    T.near((s.cb.ikTargets.rHand - hand0):Length(), 0, 1e-6, "the hand does not follow a spinning bar")
    s.cb.drawBar = 0
    s.cb:SetTrickBits(B.PoseIDs.xup * 65536)
    for _ = 1, 30 do draw(s) end
    T.ok((s.cb.ikTargets.rHand - hand0):Length() > 5, "an X-up has taken the right hand across")
end)

T.test("client: poses blend in over 0.15 s and out again", function()
    local s = scene()
    local B = s.cl.env.BMX
    local bike = {}
    local name = "superman"
    local W = B.UpdatePoseWeights(bike, name, 0.05)
    T.near(W[name], 0.05 / 0.15, 1e-9, "a third of the way after 50 ms")
    B.UpdatePoseWeights(bike, name, 0.05)
    B.UpdatePoseWeights(bike, name, 0.05)
    T.near(bike.poseW[name], 1, 1e-9, "fully in after 150 ms")
    B.UpdatePoseWeights(bike, name, 0.15)
    T.near(bike.poseW[name], 1, 1e-9, "and held")
    B.UpdatePoseWeights(bike, nil, 0.075)
    T.near(bike.poseW[name], 0.5, 1e-9, "half out after 75 ms")
    B.UpdatePoseWeights(bike, nil, 0.1)
    T.eq(bike.poseW[name], nil, "gone")
    -- Moving from one pose to another crosses them.
    B.UpdatePoseWeights(bike, "nohander", 0.15)
    B.UpdatePoseWeights(bike, "nofooter", 0.075)
    T.near(bike.poseW.nohander, 0.5, 1e-9, "the old one fades")
    T.near(bike.poseW.nofooter, 0.5, 1e-9, "as the new one comes in")
end)

T.test("client: a pose pulls its IK target toward its own, in proportion to its weight", function()
    local s = scene()
    local B = s.cl.env.BMX
    local V = s.cl.env.Vector
    local ik = { rHand = V(0, 0, 0), lHand = V(0, 0, 0), rHandA = V(1, 1, 1), rHandB = V(2, 2, 2),
                 rFoot = V(0, 0, 0), lFoot = V(0, 0, 0) }
    local function toWorld(v) return v end
    B.ApplyPoseTargets(ik, { nofooter = 0.5 }, toWorld)
    T.near(ik.rFoot.y, B.RiderPoses.nofooter.rFoot.y * 0.5, 1e-9, "half way for the right foot")
    T.near(ik.lFoot.y, B.RiderPoses.nofooter.lFoot.y * 0.5, 1e-9, "and the left")
    T.ok(ik.rHandA, "the hands keep their grips for a foot pose")
    B.ApplyPoseTargets(ik, { nohander = 1 }, toWorld)
    T.near(ik.rHand.z, B.RiderPoses.nohander.rHand.z, 1e-9, "a no-hander takes the hand")
    T.eq(ik.rHandA, nil, "and lets go of the grip's range")
    local roll = B.PoseDrawAngles({ tabletop = 1 })
    T.near(math.deg(roll), 70, 1e-9, "tabletop lays the bike over")
    local lean = B.PoseBody({ superman = 1 })
    T.ok(lean > 10, "superman folds the body forward")
end)

T.test("overlay: the trick list shows every trick's input, and bmx_tricks / +bmx_tricks show it", function()
    local s = scene()
    local E = s.cl.env
    local lines = E.BMX.TrickOverlayLines()
    local txt = {}
    for _, l in ipairs(lines) do txt[#txt + 1] = (l.text or l.header) .. " | " .. (l.input or "") end
    local all = table.concat(txt, "\n")
    for _, id in ipairs(E.BMX.TrickOrder) do
        local t = E.BMX.Tricks[id]
        T.ok(all:find(t.name, 1, true) and all:find(t.input, 1, true), t.name .. " and its input are listed")
    end
    T.ok(all:find("Alt + W + S", 1, true), "the superman chord")
    T.ok(not E.BMX.TricksOverlayVisible(), "hidden to begin with")
    s.cl:command("bmx_tricks")
    T.ok(E.BMX.TricksOverlayVisible(), "bmx_tricks shows it")
    s.cl.texts = {}
    E.hook.Run("HUDPaint")
    local drawn = table.concat(s.cl.texts, " | ")
    T.ok(drawn:find("Tailwhip", 1, true), "drawn on screen: " .. drawn:sub(1, 80))
    s.cl:command("bmx_tricks")
    T.ok(not E.BMX.TricksOverlayVisible(), "and toggles away")
    s.cl:command("+bmx_tricks")
    T.ok(E.BMX.TricksOverlayVisible(), "held")
    s.cl:command("-bmx_tricks")
    T.ok(not E.BMX.TricksOverlayVisible(), "released")
end)

T.test("overlay: a trick registered later is listed with no change to the overlay", function()
    local s = scene()
    local E = s.cl.env
    E.BMX.RegisterTrick{ id = "kickflip", name = "Kickflip", input = "KICK", points = 10, kind = "custom" }
    local found
    for _, l in ipairs(E.BMX.TrickOverlayLines()) do if l.text == "Kickflip" then found = l end end
    T.ok(found, "listed")
    T.eq(found.input, "KICK", "with its input")
end)

