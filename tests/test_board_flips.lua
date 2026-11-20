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
        for c in keys:gmatch(".") do if c == "c" then k.duck = true else k[c:lower()] = true end end
        return B.FlipFor(k)
    end
    T.eq(pick("a"), "kickflip", "A")
    T.eq(pick("d"), "heelflip", "D")
    T.eq(pick("s"), "popshove", "S")
    T.eq(pick("w"), "frontshove", "W")
    -- each combo is its parts: S backside, W frontside, A kick, D heel
    T.eq(pick("sa"), "varialkick", "S + A")
    T.eq(pick("wd"), "varialheel", "W + D")
    T.eq(pick("wa"), "hardflip", "W + A")
    T.eq(pick("sd"), "inwardheel", "S + D")
    -- CTRL ("c") held: the shove goes a whole turn
    T.eq(pick("cs"), "shove360", "CTRL + S")
    T.eq(pick("cw"), "front360", "CTRL + W")
    T.eq(pick("csa"), "flip360", "CTRL + S + A")
    T.eq(pick("cwd"), "laserflip", "CTRL + W + D")
    T.eq(pick("cwa"), "hardflip360", "CTRL + W + A")
    T.eq(pick("csd"), "inward360", "CTRL + S + D")
    T.eq(pick("ca"), nil, "CTRL + A is the body spin, not a flip")
    T.eq(pick("cd"), nil, "CTRL + D likewise")
    T.eq(pick("cws"), "impossible360", "CTRL + W + S is the 360 impossible (1.4.9)")
    T.eq(pick("ws"), "impossible", "W + S")
    T.eq(pick("wsa"), "impossible", "W + S + A is still the impossible")
    T.eq(pick(""), nil, "no keys, no flip")
    T.eq(pick("ad"), nil, "A + D cancel")
    T.eq(pick("aw"), "hardflip", "order does not matter")
    local seen = {}
    for _, id in ipairs(B.FlipOrder) do
        local f = B.Flips[id]
        local key = tostring(f.w) .. tostring(f.s) .. tostring(f.a) .. tostring(f.d) .. tostring(f.full or false)
            .. tostring(f.nollie or false)
        T.ok(not seen[key], id .. " has its own keys")
        seen[key] = true
        T.eq(sv.env.BMX.Tricks[id].name, f.name, id .. " is a registered trick")
    end
    T.eq(#B.FlipOrder, 17, "nine, six whole-turn ones, the 360 impossible and the dolphin")
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

-- A whole turn has to be finished: half way round its deck is flat, but that is the
-- half-turn flip it started as, and it pays as that, not as the 360.
T.test("flips: a whole-turn flip put down half way round pays as its half turn, not the 360", function()
    local sv = F.server()
    local B = sv.env.BMX.Board
    for full, half in pairs(B.HalfOf) do
        local def = B.Flips[full]
        local x = 1 - math.sqrt(0.5)              -- the ease puts the deck half way round here
        local t = def.dur * x
        T.ok(B.CatchError(def, t) > B.Tune.catchAngle, full .. ": half way round is not its catch")
        T.eq(B.HalfFlip(def, t), half, full .. " put down half way round is a " .. half)
        local entry = B.JudgeFlip({ id = full, def = def, t0 = 0 }, t)
        T.ok(entry and entry.name == B.Flips[half].name, full .. " half way pays as " .. B.Flips[half].name .. ": " .. tostring(entry and entry.name))
        local done = B.JudgeFlip({ id = full, def = def, t0 = 0 }, def.dur)
        T.ok(done and done.name == def.name and done.points > entry.points, full .. " finished pays as itself, and more")
        T.ok(B.CatchFrom(def) > t, full .. ": its catch window opens after half way")
    end
end)

-- The same player: "front shove and heel flip could possibly give a bit more points
-- than shuv and kickflip bc they are a bit more difficult in rl". And a whole turn is
-- worth more than the half turn it comes from.
T.test("flips: the harder way round pays more, and every whole turn more than its half", function()
    local sv = F.server()
    local B = sv.env.BMX.Board
    local P = function(id) return B.Flips[id].points end
    T.ok(P("heelflip") > P("kickflip"), "heelflip over kickflip")
    T.ok(P("frontshove") > P("popshove"), "front shove-it over pop shove-it")
    T.ok(P("varialheel") > P("varialkick"), "varial heelflip over varial kickflip")
    for half, full in pairs({ popshove = "shove360", frontshove = "front360", varialkick = "flip360",
                              varialheel = "laserflip", hardflip = "hardflip360", inwardheel = "inward360" }) do
        T.ok(P(full) > P(half), full .. " pays more than " .. half)
        T.ok(B.Flips[full].full and not B.Flips[half].full, full .. " is the CTRL one")
        T.eq(B.Flips[full].roll, B.Flips[half].roll, full .. " flips the same way as " .. half)
        T.eq(B.Flips[full].yaw, 2 * B.Flips[half].yaw, full .. " turns twice as far, the same way")
        T.ok(B.Flips[full].dur > B.Flips[half].dur, full .. " takes longer")
        T.ok(B.FullSpin(B.Flips[full]) and not B.FullSpin(B.Flips[half]), full .. " is a full spin for the feet")
    end
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
               w = k.w, s = k.s, duck = keys:find("c") ~= nil })
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

-- CTRL with A or D on the ground is the powerslide; pressed with a flip's keys as the
-- board pops, it is the flip's (the in-game suite's 360 flip bailed, 2026-11-18: a slide
-- begun the tick of the pop turned the board sideways).
T.test("flip ride: CTRL + a flip's keys at the pop never starts a powerslide", function()
    for _, k in ipairs({ "csa", "csd", "cwa", "cwd" }) do
        local sv, e = ridden()
        press(e, { throttle = 1, fwd = 1 })
        sv:run(3)
        press(e, { jump = true })
        sv:run(0.45)
        local kk = { w = k:find("w") ~= nil, s = k:find("s") ~= nil, a = k:find("a") ~= nil, d = k:find("d") ~= nil }
        local slid = false
        press(e, { side = (kk.d and 1 or 0) - (kk.a and 1 or 0), fwd = (kk.w and 1 or 0) - (kk.s and 1 or 0),
                   w = kk.w, s = kk.s, duck = true })
        sv:run(1.0, function() if e.st.board.powerslide then slid = true end return false end)
        T.ok(not slid, k .. ": no powerslide out of the pop")
    end
end)

T.test("flip ride: every flip off a full pop lands, caught, and pays under its own name", function()
    local keys = { kickflip = "a", heelflip = "d", popshove = "s", frontshove = "w", varialkick = "sa",
                   varialheel = "wd", hardflip = "wa", inwardheel = "sd", impossible = "ws",
                   shove360 = "cs", front360 = "cw", flip360 = "csa", laserflip = "cwd",
                   hardflip360 = "cwa", inward360 = "csd" }
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

-- FLAT-GROUND KICKFLIPS, ONE AFTER ANOTHER. The crouch for the next pop (0.45 s)
-- fits inside Combo.grace, so every kickflip linked to the last: eight were one
-- combo of eight, 24,000 points out of 3,000 of flips, growing as the square of the
-- flips. With bmx_combo_variety the fifth kickflip on adds nothing to the combo.
local function kickflips(n, variety, flips)
    local sv, e = ridden()
    sv.env.GetConVar("bmx_combo_variety"):SetString(variety and "1" or "0")
    local ended, bailed = {}, nil
    sv.env.hook.Add("BMX_ComboEnded", "test", function(ent, ply, c) ended[#ended + 1] = c end)
    sv.env.hook.Add("BMX_Crashed", "test", function(ent, ply, reason) bailed = reason end)
    press(e, { throttle = 1, fwd = 1 })
    sv:run(3)
    local s0 = e:GetScore()
    for i = 1, n do
        local side = (flips and flips[i] == "d") and 1 or -1      -- A kickflip, D heelflip
        press(e, { jump = true })
        sv:run(0.45)
        press(e, { side = side, fwd = 0, w = false, s = false })
        sv:run(0.1)
        press(e, { throttle = 0.4 })
        local up = false
        sv:run(2.0, function()
            if not e.st.grounded then up = true end
            return up and e.st.grounded
        end)
        sv:run(0.1)
    end
    press(e, {})
    sv:run(2)
    return ended, e:GetScore() - s0, bailed
end

T.test("flip ride: kickflips one after another are one combo, and with variety it stops growing at x4", function()
    local ended, got, bailed = kickflips(8, true)
    T.eq(bailed, nil, "every one landed")
    T.eq(#ended, 1, "eight kickflips linked into one combo")
    local c = ended[1]
    T.eq(c.n, 4, "only four count")
    T.ok(got < c.base * 2, "the combo adds less than the flips paid: " .. got .. " for " .. c.base)
    local old, oldGot = kickflips(8, false)
    T.eq(old[1].n, 8, "the old rule: x8")
    T.eq(oldGot, old[1].base * 8, "eight times the flips: " .. oldGot)
    -- Kickflip, heelflip, kickflip, heelflip...: two tricks, four of each count.
    local mixed = kickflips(8, true, { "a", "d", "a", "d", "a", "d", "a", "d" })
    T.eq(mixed[1].n, 8, "mixed with heelflips, all eight count")
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

--------------------------------------------------------------------------
-- WHICH WAY THE DECK TURNS, against the side the rider faces (a Workshop player,
-- 2026-11-16: the shove-its and the 360 flip went frontside, and the tricks only
-- matched their names riding switch). The rider faces where the seat's +Y is turned
-- to (Tune.seatYaw); the toe side is that side. A kickflip's top rolls toward the
-- heels (the front foot flicks off toward the heels; clockwise seen from the nose for
-- a regular rider), a heelflip's toward the toes (the same player: these went the
-- wrong way too); a pop shove-it, a 360 flip and a varial
-- kickflip swing the tail behind, to the heels (backside); a front shove-it, a
-- hardflip and a varial heelflip swing it to the toes (frontside). Mirrored for the
-- other foot forward, whichever way that came about (goofy, or regular switch).
--------------------------------------------------------------------------
T.test("flips turn the right way for the side the rider faces, regular, goofy and switch", function()
    local sv = F.server()
    local B = sv.env.BMX.Board
    local function face(yawDeg)          -- the seat's +Y, turned by its yaw about Z
        local a = math.rad(yawDeg)
        return -math.sin(a), math.cos(a)
    end
    local want = {
        kickflip = { top = "heels" }, heelflip = { top = "toes" },
        popshove = { tail = "heels" }, frontshove = { tail = "toes" },
        varialkick = { top = "heels", tail = "heels" }, varialheel = { top = "toes", tail = "toes" },
        hardflip = { top = "heels", tail = "toes" }, inwardheel = { top = "toes", tail = "heels" },
        shove360 = { tail = "heels" }, front360 = { tail = "toes" },
        flip360 = { top = "heels", tail = "heels" }, laserflip = { top = "toes", tail = "toes" },
        hardflip360 = { top = "heels", tail = "toes" }, inward360 = { top = "toes", tail = "heels" },
    }
    local cases = {
        { "regular", B.Stance(false, false), B.Tune.seatYaw.regular },
        { "goofy", B.Stance(true, false), B.Tune.seatYaw.goofy },
        { "regular switch", B.Stance(false, true), B.Tune.seatYaw.goofy },
        { "goofy switch", B.Stance(true, true), B.Tune.seatYaw.regular },
    }
    for _, c in ipairs(cases) do
        local label, stance, yaw = c[1], c[2], c[3]
        local fx, fy = face(yaw)
        for id, w in pairs(want) do
            local r, y = B.FlipAnglesFor(B.Flips[id], 0.02, stance)
            -- the top (0,0,1) rolled about +X by r moves toward (0,-sin r); the tail
            -- (-1,0,0) yawed about +Z by y moves toward (0,-sin y)
            if w.top then
                local toward = (0 * fx + (-math.sin(r)) * fy) > 0 and "toes" or "heels"
                T.eq(toward, w.top, label .. " " .. id .. ": the deck's top rolls to the " .. w.top)
            end
            if w.tail then
                local toward = (0 * fx + (-math.sin(y)) * fy) > 0 and "toes" or "heels"
                T.eq(toward, w.tail, label .. " " .. id .. ": the tail swings to the " .. w.tail)
            end
        end
    end
end)

T.test("flip ride: a goofy rider's kickflip rolls the deck the other way to a regular one's", function()
    local rolls = {}
    for _, goofy in ipairs({ false, true }) do
        local sv, e = ridden()
        local ply = e:GetDriver()
        if sv.env.IsValid(ply) and ply.ConCommand then ply:ConCommand("bmx_stance " .. (goofy and "goofy" or "regular")) end
        e.st.board.goofy = goofy
        press(e, { throttle = 1, fwd = 1 })
        sv:run(3)
        press(e, { jump = true })
        sv:run(0.4)
        press(e, { side = -1 })
        sv:run(0.12)
        rolls[#rolls + 1] = e.st.board.flipRoll or 0
    end
    T.ok(rolls[1] < -0.1 and rolls[2] > 0.1, string.format("regular %.2f, goofy %.2f", rolls[1], rolls[2]))
end)

--------------------------------------------------------------------------
-- 1.4.9: MORE IN THE AIR. A key pressed again adds to the flip under way (a double,
-- a 540, a late shove-it), and a few pairs landed together are one named trick
-- (Bigspins, the Ghetto Bird, a flip then a grab). Plus the 360 impossible and the
-- dolphin flip.
--------------------------------------------------------------------------
T.test("flips 1.4.9: W + S off a nollie is the dolphin flip, with CTRL the 360 impossible; nothing else changes off a nollie", function()
    local sv = F.server()
    local B = sv.env.BMX.Board
    T.eq(B.FlipFor({ w = true, s = true, nollie = true }), "dolphin", "nollie W + S")
    T.eq(B.FlipFor({ w = true, s = true }), "impossible", "W + S")
    T.eq(B.FlipFor({ w = true, s = true, duck = true }), "impossible360", "CTRL + W + S")
    T.eq(B.FlipFor({ a = true, nollie = true }), "kickflip", "a nollie kickflip is still a kickflip")
    T.eq(B.FlipFor({ s = true, a = true, nollie = true }), "varialkick", "and so on")
    T.ok(B.Flips.dolphin.pitch < 0 and B.Flips.impossible.pitch > 0, "the dolphin goes over nose first, the other way to the impossible")
end)

T.test("flips 1.4.9: an add starts where the deck is, so it never jumps, and the turn ends on its target", function()
    local sv = F.server()
    local B = sv.env.BMX.Board
    local T_ = B.Tune
    for _, c in ipairs({ { "kickflip", -1, 0 }, { "shove360", 0, -1 }, { "heelflip", 1, 0 } }) do
        local def = B.Flips[c[1]]
        local f = { def = def, t0 = 0, stance = 1, adds = {} }
        local at = 0.15
        local r0, y0, p0 = B.StateAngles(f, at)
        f.adds[1] = { kind = "x", roll = c[2] * 2 * math.pi, yaw = c[3] * math.pi, pitch = 0, t = at }
        local r1, y1, p1 = B.StateAngles(f, at)
        T.near(r1, r0, 1e-9, c[1] .. ": no jump in roll")
        T.near(y1, y0, 1e-9, c[1] .. ": no jump in yaw")
        local tr, ty = B.StateTarget(f)
        local done = math.max(def.dur, at + T_.addDur) + 0.01
        local r2, y2 = B.StateAngles(f, done)
        T.near(r2, tr, 1e-6, c[1] .. ": the roll ends on its target")
        T.near(y2, ty, 1e-6, c[1] .. ": the yaw too")
        T.near(B.StateRemaining(f, done), 0, 1e-6, c[1] .. ": nothing left to turn")
        T.ok(B.StateRemaining(f, at + 0.05) > 1, c[1] .. ": plenty left just after it was added")
        T.ok(B.StateCatchError(f, done) < 1e-6, c[1] .. ": caught when it is all done")
    end
end)

T.test("flips 1.4.9: what the adds are called and pay", function()
    local sv = F.server()
    local B = sv.env.BMX.Board
    local function trick(id, adds)
        return B.StateTrick({ def = B.Flips[id], adds = adds })
    end
    local n, p = trick("kickflip", { { kind = "double" } })
    T.eq(n, "Double Kickflip", "kickflip + double") T.eq(p, 550, "its points")
    n = trick("varialkick", { { kind = "double" } })
    T.eq(n, "Nightmare Flip", "a varial kickflip doubled is the nightmare flip")
    n, p = trick("shove360", { { kind = "more" } })
    T.eq(n, "540 Shove-it", "a 360 shove-it with more") T.eq(p, 650, "its points")
    n, p = trick("kickflip", { { kind = "late" } })
    T.eq(n, "Kickflip Late Shove-it", "a late shove-it after a kickflip") T.eq(p, 300 + 200, "its points")
    n, p = trick("heelflip", { { kind = "late", front = true } })
    T.eq(n, "Heelflip Late Front Shove-it", "frontside") T.eq(p, 350 + 250, "pays the front's")
    n, p = trick("kickflip", { { kind = "double" }, { kind = "late" } })
    T.eq(n, "Double Kickflip Late Shove-it", "a double, then late") T.eq(p, 550 + 200, "both")
    for kind, t in pairs(B.Upgrades) do
        for base, u in pairs(t) do
            T.ok(u.points > B.Flips[base].points, base .. " " .. kind .. " pays more than " .. base)
            T.ok(sv.env.BMX.Tricks[base .. "_" .. kind], base .. "_" .. kind .. " is a registered trick")
        end
    end
end)

T.test("flips 1.4.9: a double has to be finished; pressed too late to start, the landing is the single flip", function()
    local sv = F.server()
    local B = sv.env.BMX.Board
    local def = B.Flips.kickflip
    local function state(addAt) return { id = "kickflip", def = def, t0 = 0, stance = 1,
        adds = { { kind = "double", roll = -2 * math.pi, yaw = 0, pitch = 0, t = addAt } } } end
    local f = state(0.12)
    local e = B.JudgeFlip(f, 0.12 + B.Tune.addDur + 0.35)
    T.ok(e and e.name == "Double Kickflip", "finished: a Double Kickflip: " .. tostring(e and e.name))
    local _, fault = B.JudgeFlip(state(0.12), 0.12 + B.Tune.addDur * 0.5)
    T.ok(fault and fault.reason == "flip", "landed half way through the second turn: a bail")
    e = B.JudgeFlip(state(def.dur + 0.1), def.dur + 0.1 + 0.005)
    T.ok(e and e.name == "Kickflip", "pressed as it landed: the kickflip it was: " .. tostring(e and e.name))
end)

T.test("flips 1.4.9: named pairs: Bigspin, the Ghetto Bird (no Nollie in its name), a flip then a grab", function()
    local sv = F.server()
    local B = sv.env.BMX.Board
    local function entry(id, nollie)
        local f = { id = id, def = B.Flips[id], t0 = 0, stance = 1, adds = {}, nollie = nollie }
        return (B.JudgeFlip(f, B.Flips[id].dur + 0.05)), f
    end
    local spin = { name = "180", count = 1, points = 120 }
    local e, f = entry("shove360")
    local out = { spin }
    local before = e.points
    e = B.ComboFor(e, spin, out, f)
    T.eq(e.name, "Bigspin", "a 360 shove-it and a 180 of the body")
    T.eq(e.points, math.floor((before + 120) * B.Tune.comboMult + 0.5), "its parts times the combo multiplier")
    T.eq(#out, 0, "the 180 is in it, not paid again")
    e, f = entry("hardflip", true)
    out = { spin }
    e = B.ComboFor(e, spin, out, f)
    T.eq(e.name, "Ghetto Bird", "a nollie hardflip and a 180")
    e, f = entry("hardflip", false)
    out = { spin }
    e = B.ComboFor(e, spin, out, f)
    T.eq(e.name, "Hardflip", "off the tail it is not the Ghetto Bird")
    T.eq(#out, 1, "and the 180 is paid on its own")
    local grab = { name = "Indy", count = 1, points = 90, pose = "indy" }
    e, f = entry("kickflip")
    out = { grab }
    before = e.points
    e = B.ComboFor(e, nil, out, f)
    T.eq(e.name, "Kickflip Indy", "a kickflip then an indy")
    T.eq(e.points, math.floor((before + 90) * B.Tune.grabComboMult + 0.5), "both, times the grab combo multiplier")
    T.eq(#out, 0, "the grab is in it")
end)

-- Roll up, pop off a full crouch, and play `steps`: { seconds, press } after the pop.
local function popSeq(steps, nollie)
    local sv, e = ridden()
    local landed, bailed = {}, nil
    sv.env.hook.Add("BMX_TrickLanded", "test", function(ply, t) landed[#landed + 1] = t end)
    sv.env.hook.Add("BMX_Crashed", "test", function(ent, ply, reason) bailed = reason end)
    press(e, { throttle = 1, fwd = 1 })
    sv:run(3)
    press(e, { jump = true, alt = nollie })
    sv:run(0.45)
    for _, st in ipairs(steps) do
        local k = st[2]
        local kk = { w = k:find("w") ~= nil, s = k:find("s") ~= nil, a = k:find("a") ~= nil, d = k:find("d") ~= nil }
        press(e, { side = (kk.d and 1 or 0) - (kk.a and 1 or 0), fwd = (kk.w and 1 or 0) - (kk.s and 1 or 0),
                   w = kk.w, s = kk.s, duck = k:find("c") ~= nil, grab = k:find("g") ~= nil, alt = nollie })
        sv:run(st[1])
    end
    sv:run(2.0)
    local names = {}
    for _, t in ipairs(landed) do names[#names + 1] = t.name end
    return table.concat(names, ", "), bailed, e
end

T.test("flip ride 1.4.9: pressed again in the air: a double kickflip, a 540 shove-it, a late shove-it; and the new flips", function()
    local got, bailed = popSeq({ { 0.1, "a" }, { 0.05, "" }, { 0.3, "a" }, { 0.01, "" } })
    T.ok(got:find("Double Kickflip", 1, true) and not bailed, "A, let go, A again: " .. got .. " " .. tostring(bailed))
    got, bailed = popSeq({ { 0.1, "cs" }, { 0.05, "c" }, { 0.3, "cs" }, { 0.01, "" } })
    T.ok(got:find("540 Shove-it", 1, true) and not bailed, "CTRL + S, S again: " .. got .. " " .. tostring(bailed))
    got, bailed = popSeq({ { 0.1, "a" }, { 0.3, "" }, { 0.3, "s" }, { 0.01, "" } })
    T.ok(got:find("Kickflip Late Shove-it", 1, true) and not bailed, "a kickflip, then S once caught: " .. got .. " " .. tostring(bailed))
    got, bailed = popSeq({ { 0.6, "cws" }, { 0.01, "" } })
    T.ok(got:find("360 Impossible", 1, true) and not bailed, "CTRL + W + S: " .. got .. " " .. tostring(bailed))
    got, bailed = popSeq({ { 0.6, "ws" }, { 0.01, "" } }, true)
    T.ok(got:find("Dolphin Flip", 1, true) and not bailed, "W + S off a nollie: " .. got .. " " .. tostring(bailed))
end)

T.test("flip ride 1.4.9: a grab waits for the catch, then pays with the flip as one trick", function()
    local got, bailed = popSeq({ { 0.04, "a" }, { 0.06, "ag" }, { 0.2, "ag" }, { 0.08, "" } })
    T.ok(got:find("Kickflip", 1, true) and not bailed, "a kickflip with RMB held through it lands: " .. got .. " " .. tostring(bailed))
end)
