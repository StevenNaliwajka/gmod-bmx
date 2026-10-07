--[[--------------------------------------------------------------------------
    The skateboard's flips (G23 M2: sh_board.lua's B.Flips, sv_board_tricks.lua):
    which keys pick which flip, how the deck turns, where each flip's catch
    window is, what a landing pays, and closed-loop pops and flips on the plant.

    THE DECK IS KINEMATIC, so a flip's physics on the plant is just the ollie's;
    what these check is the rule (catch within 20 degrees or bail), the clock and
    the scoring, and that the rider is still aboard when it works.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local BF = require("lib.board")
local ridden, press = BF.ridden, BF.press

--------------------------------------------------------------------------
-- The pure rules
--------------------------------------------------------------------------

T.test("flips: each direction picks its own flip, W + S is the impossible, A + D together is neither", function()
    local sv = F.server()
    local B = sv.env.BMX.Board
    local function pick(keys)
        local k = { w = false, s = false, a = false, d = false }
        for c in keys:gmatch(".") do k[c:lower()] = true end
        return B.FlipFor(k)
    end
    T.eq(pick("a"), "kickflip", "A")
    T.eq(pick("d"), "heelflip", "D")
    T.eq(pick("s"), "popshove", "S")
    T.eq(pick("w"), "frontshove", "W")
    T.eq(pick("sa"), "flip360", "S + A")
    T.eq(pick("sd"), "varialheel", "S + D")
    T.eq(pick("wd"), "varialkick", "W + D")
    T.eq(pick("wa"), "hardflip", "W + A")
    T.eq(pick("ws"), "impossible", "W + S")
    T.eq(pick("wsa"), "impossible", "W + S + A is still the impossible")
    T.eq(pick(""), nil, "no keys, no flip")
    T.eq(pick("ad"), nil, "A + D cancel")
    T.eq(pick("aw"), "hardflip", "order does not matter")
    local seen = {}
    for _, id in ipairs(B.FlipOrder) do
        local f = B.Flips[id]
        local key = tostring(f.w) .. tostring(f.s) .. tostring(f.a) .. tostring(f.d)
        T.ok(not seen[key], id .. " has its own keys")
        seen[key] = true
        T.eq(sv.env.BMX.Tricks[id].name, f.name, id .. " is a registered trick")
    end
    T.eq(#B.FlipOrder, 9, "nine")
end)

T.test("flips: the keys come from the board record, or from the standard fields a scripted rider writes", function()
    local sv = F.server()
    local B = sv.env.BMX.Board
    local inp = { throttle = 1, brakeRear = 0, leanTarget = -1 }
    local k = B.Keys(inp)
    T.ok(k.w and not k.s and k.a and not k.d, "W and A from the standard fields")
    inp = { board = { fwd = 0, side = 0, w = true, s = true, flickF = 0, flickS = 0 },
            throttle = 0, brakeRear = 0, leanTarget = 0 }
    k = B.Keys(inp)
    T.ok(k.w and k.s, "W and S together, which one axis cannot say")
    inp = { board = { fwd = 0, side = 0, flickF = 1, flickS = -1 }, throttle = 0, brakeRear = 0, leanTarget = 0 }
    k = B.Keys(inp)
    T.ok(k.w and k.a and not k.s and not k.d, "a mouse flick up and left is W + A")
end)

T.test("flips: every flip turns the deck through its whole angle, ends flat, and is not flat a third of the way", function()
    local sv = F.server()
    local B = sv.env.BMX.Board
    for _, id in ipairs(B.FlipOrder) do
        local f = B.Flips[id]
        local r, y, p = B.FlipAngles(f, f.dur)
        T.near(r, f.roll, 1e-9, id .. " roll at the end")
        T.near(y, f.yaw, 1e-9, id .. " yaw at the end")
        T.near(p, f.pitch, 1e-9, id .. " pitch at the end")
        T.near(B.CatchError(f, f.dur), 0, 1e-9, id .. " is flat when it is done")
        T.near(B.CatchError(f, f.dur * 5), 0, 1e-9, id .. " and stays so")
        T.ok(B.CatchError(f, f.dur * 0.35) > B.Tune.catchAngle, id .. " is not flat a third of the way")
        local r1 = B.FlipAngles(f, f.dur * 0.2)
        local r2 = B.FlipAngles(f, f.dur * 0.6)
        T.ok(math.abs(r2) >= math.abs(r1), id .. " keeps turning")
        T.ok(f.dur > 0.3 and f.dur < 0.7, id .. " takes a believable time: " .. f.dur)
    end
end)

T.test("flips: each flip's catch window opens before it ends, is the last part of it, and is 20 degrees", function()
    local sv = F.server()
    local B = sv.env.BMX.Board
    for _, id in ipairs(B.FlipOrder) do
        local f = B.Flips[id]
        local from = B.CatchFrom(f)
        T.ok(from > f.dur * 0.55 and from < f.dur * 0.95, id .. " window opens at " .. from / f.dur .. " of the flip")
        T.ok(B.CatchError(f, from + 0.001) <= B.Tune.catchAngle, id .. " caught from there")
        T.ok(B.CatchError(f, from - 0.03) > B.Tune.catchAngle, id .. " not caught just before")
        T.near(B.CatchError(f, from), B.Tune.catchAngle, math.rad(2), id .. " the window edge is 20 degrees")
    end
    T.eq(B.CatchGrade(math.rad(3)), "clean", "3 deg is clean")
    T.eq(B.CatchGrade(math.rad(9)), "ok", "9 deg is ok")
    T.eq(B.CatchGrade(math.rad(17)), "late", "17 deg is late")
    T.eq(B.CatchGrade(math.rad(25)), nil, "25 deg is a bail")
end)

T.test("flips: a clean catch pays more than a late one, switch and nollie pay more, a bail pays nothing", function()
    local sv = F.server()
    local B = sv.env.BMX.Board
    local f = B.Flips.kickflip
    local clean = B.FlipPoints(f, "clean")
    local ok = B.FlipPoints(f, "ok")
    local late = B.FlipPoints(f, "late")
    T.ok(clean > ok and ok > late and late > 0, "clean > ok > late: " .. clean .. " " .. ok .. " " .. late)
    T.near(B.FlipPoints(f, "ok", true), ok * 1.2, 1, "switch is x1.2")
    T.near(B.FlipPoints(f, "ok", false, true), ok * 1.1, 1, "fakie a little")
    T.near(B.FlipPoints(f, "ok", false, false, true), ok * 1.1, 1, "nollie a little")
    T.eq(B.FlipPoints(f, nil), 0, "a bail pays nothing")
    T.ok(B.FlipPoints(B.Flips.flip360, "ok") > B.FlipPoints(B.Flips.kickflip, "ok"), "a 360 flip is worth more than a kickflip")
end)

T.test("flips: judging a landing, with the stance in the name and a fault for a bad catch", function()
    local sv = F.server()
    local B = sv.env.BMX.Board
    local def = B.Flips.heelflip
    local entry, fault = B.JudgeFlip({ id = "heelflip", def = def, t0 = 0 }, def.dur + 0.1)
    T.eq(entry.name, "Heelflip", "its name")
    T.eq(entry.catch, "clean", "done before landing: clean")
    T.ok(entry.points > 0 and fault == nil, "pays, no fault")
    entry = B.JudgeFlip({ id = "heelflip", def = def, t0 = 0, switch = true, nollie = true }, def.dur + 0.1)
    T.eq(entry.name, "Switch Nollie Heelflip", "switch and nollie are in the name")
    entry = B.JudgeFlip({ id = "heelflip", def = def, t0 = 0, fakie = true }, def.dur + 0.1)
    T.eq(entry.name, "Fakie Heelflip", "fakie")
    entry, fault = B.JudgeFlip({ id = "heelflip", def = def, t0 = 0 }, def.dur * 0.3)
    T.eq(entry, nil, "landed a third of the way round: not caught")
    T.eq(fault.reason, "flip", "the landing's fault is the flip")
    T.ok(fault.severity > 0.3 and fault.severity <= 1, "with a severity: " .. fault.severity)
    local late = B.JudgeFlip({ id = "heelflip", def = def, t0 = 0 }, B.CatchFrom(def) + 0.005)
    local clean = B.JudgeFlip({ id = "heelflip", def = def, t0 = 0 }, def.dur)
    T.ok(late and clean and late.points < clean.points, "a late catch scores less: " .. late.points .. " < " .. clean.points)
end)

T.test("flips: the wrapped ScoreExtras pays a caught flip and faults a bad one, and clears the deck", function()
    local sv = F.server()
    local B = sv.env.BMX
    local st = B.NewState(B.Config)
    st.def = B.Vehicles.skateboard
    local b = B.BoardState(st)
    local now = sv.world.time
    b.flip = { id = "kickflip", def = B.Board.Flips.kickflip, t0 = now - 0.6 }
    b.flipRoll = 3
    local out = B.ScoreExtras(st, {})
    T.eq(#out, 1, "one entry")
    T.eq(out[1].name, "Kickflip", "the kickflip")
    T.eq(st.landFault, nil, "no fault")
    T.eq(b.flip, nil, "the flip is over")
    T.eq(b.flipRoll, 0, "and the deck is flat")

    b.flip = { id = "kickflip", def = B.Board.Flips.kickflip, t0 = now - 0.1 }
    out = B.ScoreExtras(st, {})
    T.eq(#out, 0, "landed early: nothing paid")
    T.eq(st.landFault and st.landFault.reason, "flip", "a flip fault for the landing judge")

    -- A bike's state is untouched by the wrapper.
    local bs = B.NewState(B.Config)
    bs.def = B.Bikes.stock
    T.eq(#B.ScoreExtras(bs, {}), 0, "a bike scores what it always did")
end)

T.test("flips: switch stance multiplies what the air paid, and a half-turn spin lands as a 180", function()
    local sv = F.server()
    local B = sv.env.BMX
    local st = B.NewState(B.Config)
    st.def = B.Vehicles.skateboard
    local b = B.BoardState(st)
    b.switch = true
    st.spinYaw = math.rad(180)
    local out = B.ScoreExtras(st, { { name = "Air Time", count = 1, points = 100 } })
    T.eq(out[1].points, 120, "the air time x1.2 in switch")
    T.eq(out[2].name, "180", "the half turn is a 180")
    T.eq(out[2].points, math.floor(B.Tricks.board180.points * 1.2 + 0.5), "in switch too")
    b.switch = false
    st.spinYaw = math.rad(90)
    out = B.ScoreExtras(st, {})
    T.eq(#out, 0, "a quarter turn is nothing")
end)

--------------------------------------------------------------------------
-- Closed loop on the plant
--------------------------------------------------------------------------

-- Roll up, crouch for `hold`, release SPACE and press the flip's keys together.
local function popAndFlip(keys, hold)
    local sv, e = ridden()
    local landed, bailed = {}, nil
    sv.env.hook.Add("BMX_TrickLanded", "test", function(ply, t) landed[#landed + 1] = t end)
    sv.env.hook.Add("BMX_Crashed", "test", function(ent, ply, reason) bailed = reason end)
    press(e, { throttle = 1, fwd = 1 })
    sv:run(3)
    press(e, { jump = true })
    sv:run(hold)
    local k = { w = keys:find("w") ~= nil, s = keys:find("s") ~= nil,
                a = keys:find("a") ~= nil, d = keys:find("d") ~= nil }
    press(e, { side = (k.d and 1 or 0) - (k.a and 1 or 0), fwd = (k.w and 1 or 0) - (k.s and 1 or 0),
               w = k.w, s = k.s })
    local seenBits, id = false, nil
    sv:run(2.0, function()
        if e.st.board.flip then id = e.st.board.flip.id end
        if e:GetBoardBits() ~= 0 then seenBits = true end
        return false
    end)
    return sv, e, landed, bailed, id, seenBits
end

T.test("flip ride: a kickflip off a full pop is caught: the deck turns, it lands, it pays", function()
    local sv, e, landed, bailed, id, seenBits = popAndFlip("a", 0.45)
    T.eq(id, "kickflip", "the flip it picked")
    T.ok(seenBits, "the deck's angles were networked while it turned")
    T.eq(bailed, nil, "no bail")
    local names = {}
    local got = false
    for _, t in ipairs(landed) do
        names[#names + 1] = t.name
        if t.name:find("Kickflip", 1, true) then got = true end
    end
    T.ok(got, "it paid a Kickflip: " .. table.concat(names, ", "))
    T.ok(e:GetDriver():InVehicle(), "and the rider is still on")
    T.eq(e:GetBoardBits(), 0, "the deck is flat again on the ground")
    T.eq(e.st.board.flip, nil, "and the flip is over")
end)

T.test("flip ride: every flip off a full pop lands, caught, and pays under its own name", function()
    local keys = { kickflip = "a", heelflip = "d", popshove = "s", frontshove = "w", flip360 = "sa",
                   varialheel = "sd", varialkick = "wd", hardflip = "wa", impossible = "ws" }
    for id, k in pairs(keys) do
        local sv, e, landed, bailed, picked = popAndFlip(k, 0.5)
        local def = sv.env.BMX.Board.Flips[id]
        T.eq(picked, id, k .. " picks " .. id)
        local paid = false
        for _, t in ipairs(landed) do if t.name:find(def.name, 1, true) then paid = true end end
        T.ok(paid, id .. " paid: " .. (bailed and ("BAILED " .. bailed) or "no"))
        T.ok(not bailed, id .. " landed without a bail")
    end
end)

T.test("flip ride: a tap pop is too low for the board to finish a flip: the landing bails", function()
    local sv, e, landed, bailed = popAndFlip("a", 0.0)
    T.eq(bailed, "flip", "bailed on the flip")
    T.ok(not sv.env.IsValid(e:GetDriver()), "the rider is off")
    for _, t in ipairs(landed) do T.ok(not t.name:find("Kickflip"), "no Kickflip was paid") end
end)

T.test("flip ride: keys held when the crouch began are latched, and are not a flip until let go", function()
    local sv, e = ridden()
    press(e, { throttle = 1, fwd = 1 })
    sv:run(3)
    press(e, { throttle = 1, fwd = 1, jump = true })
    sv:run(0.4)
    press(e, { throttle = 1, fwd = 1 })
    sv:run(0.5)
    T.eq(e.st.board.flip, nil, "W held through the pop is not a front shove-it")

    local sv2, e2 = ridden()
    press(e2, { throttle = 1, fwd = 1 })
    sv2:run(3)
    press(e2, { throttle = 1, fwd = 1, jump = true })
    sv2:run(0.4)
    press(e2, {})
    sv2:run(0.04)
    press(e2, { throttle = 1, fwd = 1 })
    sv2:run(0.3)
    T.ok(e2.st.board.flip and e2.st.board.flip.id == "frontshove", "W pressed again after the pop is")
end)

T.test("flip ride: a flip starts only inside the window after the pop", function()
    local sv, e = ridden()
    press(e, { throttle = 1, fwd = 1 })
    sv:run(3)
    press(e, { jump = true })
    sv:run(0.45)
    press(e, {})
    sv:run(0.6)
    press(e, { side = -1 })
    sv:run(0.2)
    T.eq(e.st.board.flip, nil, "A well after the pop does nothing")
end)

T.test("flip ride: the mouse flick picks a flip too, when it is on", function()
    local sv, e = ridden()
    press(e, { throttle = 1, fwd = 1 })
    sv:run(3)
    press(e, { jump = true })
    sv:run(0.4)
    press(e, {})
    e.input.board.flickF, e.input.board.flickS = 0, -1      -- a flick to the left
    sv:run(0.3)
    T.ok(e.st.board.flip and e.st.board.flip.id == "kickflip", "a flick left is a kickflip")
end)
