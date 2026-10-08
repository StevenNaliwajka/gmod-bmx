--[[--------------------------------------------------------------------------
    The skateboard's grinds, slides and manuals (G23 M3: sv_board_grind.lua, the
    moves in sh_board.lua, and the hooks into sv_grind.lua).

    On the shim's plant with box "rails" in the world, as test_grind.lua does for
    the bike: the boxes are traced against and not collided with, because on a
    rail the board is PLACED, so what is tested is where it is put, which move it
    is, what it pays and when it lets go. Real rails and park pieces are the
    headless suite's.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local BF = require("lib.board")
local press = BF.press

local function world(solids)
    local sv = F.server({ solids = solids })
    local e = BF.board(sv)
    F.scripted(sv, e)
    sv:run(0.3)
    return sv, e
end

-- A 2x2 round rail along x, top at z = 30, and a ledge: top at z = 20, edge along
-- x at y = 0, the ledge over +y.
local function pipe(E, len) return { E.Vector(-(len or 400), -1, 28), E.Vector(len or 400, 1, 30) } end
local function ledge(E) return { E.Vector(-800, 0, 0), E.Vector(800, 200, 20) } end

-- The board in the air with the middle of its underside `above` over (x, y, zTop),
-- facing `yaw`, moving at `vel`.
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

--------------------------------------------------------------------------
-- The rules
--------------------------------------------------------------------------

local function keys(s)
    local k = { w = false, s = false, a = false, d = false }
    for c in s:gmatch(".") do k[c] = true end
    return k
end

T.test("grinds: the board turned along a rail grinds, across it slides, and the keys pick the move", function()
    local sv = F.server()
    local B = sv.env.BMX.Board
    local function pick(k, along, edge) return B.ClassifyGrind(keys(k), along, edge) end
    -- Along, on a ledge: all six.
    T.eq(pick("", true, true), "grind5050", "no key: 50-50")
    T.eq(pick("s", true, true), "grind50", "S: 5-0")
    T.eq(pick("w", true, true), "nosegrind", "W: nosegrind")
    T.eq(pick("wa", true, true), "crooked", "W + A: crooked")
    T.eq(pick("wd", true, true), "crooked", "W + D: crooked")
    T.eq(pick("sa", true, true), "smith", "S + A: smith")
    T.eq(pick("sd", true, true), "feeble", "S + D: feeble")
    -- Across, on a ledge: all four.
    T.eq(pick("", false, true), "boardslide", "no key: boardslide")
    T.eq(pick("a", false, true), "lipslide", "A: lipslide")
    T.eq(pick("d", false, true), "lipslide", "D: lipslide")
    T.eq(pick("w", false, true), "noseslide", "W: noseslide")
    T.eq(pick("s", false, true), "tailslide", "S: tailslide")
    -- On a round rail the ledge-only ones fall back.
    T.eq(pick("sa", true, false), "grind50", "smith needs an edge: a 5-0 on a round rail")
    T.eq(pick("sd", true, false), "grind50", "so does feeble")
    T.eq(pick("a", false, false), "boardslide", "lipslide needs an edge")
    T.eq(pick("w", false, false), "boardslide", "so does noseslide")
    T.eq(pick("s", false, false), "boardslide", "and tailslide")
    T.eq(pick("w", true, false), "nosegrind", "a nosegrind is fine on a round rail")
    T.eq(pick("wa", true, false), "crooked", "and a crooked grind")
    T.eq(pick("ws", true, true), "grind5050", "W + S cancel")
    -- Every move is reachable.
    local seen = {}
    for _, along in ipairs({ true, false }) do
        for _, ks in ipairs({ "", "w", "s", "a", "d", "wa", "sa", "sd" }) do
            seen[pick(ks, along, true)] = true
        end
    end
    for _, id in ipairs(B.GrindOrder) do T.ok(seen[id], id .. " is reachable") end
    T.eq(#B.GrindOrder, 10, "ten of them")
end)

T.test("grinds: along is within 45 degrees of the rail's line, either way round", function()
    local sv = F.server()
    local B = sv.env.BMX.Board
    T.ok(B.IsAlong(0), "straight along")
    T.ok(B.IsAlong(math.pi), "straight along, backwards")
    T.ok(B.IsAlong(math.rad(30)), "30 degrees off")
    T.ok(B.IsAlong(math.rad(150)), "30 degrees off, backwards")
    T.ok(not B.IsAlong(math.rad(60)), "60 degrees is a slide")
    T.ok(not B.IsAlong(math.pi / 2), "square across")
    T.ok(not B.IsAlong(-math.pi / 2), "either side")
end)

T.test("grinds: each move's contact rule, which point of the board rides the rail and how it sits", function()
    local sv = F.server()
    local B = sv.env.BMX.Board
    local T0 = B.Tune
    local nose = { nosegrind = true, crooked = true, smith = true, noseslide = true }
    for _, id in ipairs(B.GrindOrder) do
        local g = B.Grinds[id]
        T.ok(g.name and #g.name > 0, id .. " has a name")
        T.ok(math.abs(g.x) <= T0.tipX + 0.01, id .. " rides a point on the deck: x " .. g.x)
        if g.along then
            T.eq(g.z, T0.truckZ, id .. ": a grind rides the trucks' hangers")
            T.ok(math.abs(g.yaw) < math.rad(40), id .. " is turned (at most) a little off the rail")
        else
            T.eq(g.z, T0.deckZ, id .. ": a slide rides the deck's underside")
            T.near(g.yaw, math.pi / 2, 1e-9, id .. " is turned square across the rail")
            T.ok(g.edge or id == "boardslide", id .. " needs a ledge unless it is the plain boardslide")
        end
        T.ok(g.mult >= 1, id .. " pays at least the base rate")
    end
    -- Which truck: the 50-50 is the middle (both trucks over the rail), the 5-0 the
    -- back truck with the nose up, the nosegrind the front with the tail up.
    T.eq(B.Grinds.grind5050.x, 0, "50-50: the middle of the board, both trucks along the rail")
    T.eq(B.Grinds.grind50.x, -T0.truckX, "5-0: the back truck")
    T.ok(B.Grinds.grind50.pitch > 0, "5-0: nose up")
    T.eq(B.Grinds.nosegrind.x, T0.truckX, "nosegrind: the front truck")
    T.ok(B.Grinds.nosegrind.pitch < 0, "nosegrind: tail up (nose down)")
    T.ok(B.Grinds.crooked.yaw > 0 and B.Grinds.crooked.x == T0.truckX, "crooked: the front truck, angled to the rail")
    T.ok(B.Grinds.smith.pitch < 0 and B.Grinds.smith.x == -T0.truckX, "smith: the back truck, the front hanging below")
    T.ok(B.Grinds.feeble.pitch > 0 and B.Grinds.feeble.x == -T0.truckX, "feeble: the back truck, the front over the top")
    T.ok(B.Grinds.noseslide.x > T0.truckX and B.Grinds.tailslide.x < -T0.truckX, "nose and tail slides are on the tips")
    T.ok(B.Grinds.boardslide.x > 0 and B.Grinds.lipslide.x < 0, "boardslide and lipslide are either side of the middle")
    T.ok(B.Grinds.noseslide.pitch < 0 and B.Grinds.tailslide.pitch > 0, "the tip on the rail, the other end up")
    -- On a ledge the board hangs over the drop; on a round rail the line is straight under it.
    local pipe_ = B.GrindContact("grind5050", false)
    T.eq(pipe_.y, 0, "a round rail is under the middle")
    local edge1, edge2 = B.GrindContact("grind5050", true, 1), B.GrindContact("grind5050", true, -1)
    T.eq(edge1.y, T0.grindEdgeY, "a ledge on one side")
    T.eq(edge2.y, -T0.grindEdgeY, "or the other")
    T.eq(B.GrindContact("boardslide", true, 1).y, 0, "a slide has the edge straight under it")
    -- Each is a registered grind, paid at its multiple of the rate, with sparks from its contact.
    local rate = sv.env.BMX.Config.Grind.pointsPerSec
    for _, id in ipairs(B.GrindOrder) do
        local t = sv.env.BMX.Tricks[id]
        T.ok(t and t.kind == "grind", id .. " is a registered grind trick")
        T.near(t.points, rate * B.Grinds[id].mult, 1e-6, id .. " pays its multiple of the grind rate")
        T.ok(B.SparkCode[id] and #B.SparkPoints(B.SparkCode[id]) > 0, id .. " throws sparks from somewhere")
    end
    T.eq(#B.SparkPoints(4), 2, "a 50-50 sparks at both trucks")
    T.eq(#B.SparkPoints(5), 1, "a 5-0 at one")
end)

T.test("manuals: the balance meter runs away unattended, is held by the keys, and is the same either run", function()
    local sv = F.server()
    local B = sv.env.BMX.Board
    for _, P in ipairs({ B.Tune.meterGrind, B.Tune.meterManual }) do
        -- Unattended: it gets to 1 within a few seconds, for EVERY wobble phase --
        -- a fresh meter (B.MeterStart, as the rides start one) and a bare one alike.
        -- Swept finely: started at 0 some phases held it near true for 12-14 s.
        local lo, hi = math.huge, 0
        for i = 0, 628 do
            local ph = i / 100
            for _, m in ipairs({ B.MeterStart(ph, P), { phase = ph } }) do
                local t = 0
                while math.abs(m.v or 0) < 1 and t < 20 do B.MeterStep(m, 1 / 66, 0, P) t = t + 1 / 66 end
                lo, hi = math.min(lo, t), math.max(hi, t)
            end
        end
        T.ok(lo > 1.2 and hi < 4, string.format("unattended it is lost in %.2f-%.2f s over every phase", lo, hi))
        T.near(math.abs(B.MeterStart(1, P).v), 0.12, 1e-9, "a fresh meter starts off true by 0.12")
        -- Held: a rider pushing against it keeps it for as long as they like.
        local m, worst = { phase = 1.1 }, 0
        for _ = 1, 66 * 30 do
            local v = m.v or 0
            B.MeterStep(m, 1 / 66, v > 0.05 and -1 or (v < -0.05 and 1 or 0), P)
            worst = math.max(worst, math.abs(m.v))
        end
        T.ok(worst < 0.6, "held for thirty seconds, never past " .. worst)
        -- The sign: a positive push raises it.
        local u = { v = 0, phase = 0 }
        B.MeterStep(u, 1 / 66, 1, { unstable = 0, wobble = 0, control = 1 })
        T.ok(u.v > 0, "a positive push raises the meter")
    end
end)

--------------------------------------------------------------------------
-- On the plant: locking on
--------------------------------------------------------------------------

T.test("grind ride: SPACE in the air over a round rail locks into a 50-50, trucks on the rail", function()
    local sv0 = F.server()
    local sv, e = world({ pipe(sv0.env, 600) })
    local E = sv.env
    local got = paid(e)
    press(e, { jump = true })
    launch(sv, e, -200, 0.5, 30, 5, 5, E.Vector(280, 0, -30))
    local locked
    sv:run(0.3, function() locked = locked or e.st.grind end)
    T.ok(locked, "locked on")
    T.eq(locked and locked.move, "grind5050", "a 50-50")
    T.eq(locked and locked.kind, "crank", "on a round rail")
    T.eq(e:GetGrind(), 4, "networked as a 50-50, for the sparks")
    sv:run(0.3)
    T.ok(e.st.grind, "still on it")
    -- The rail runs along the board, under its middle, at the trucks' hanger height.
    local contact = e:LocalToWorld(E.BMX.Board.GrindContact("grind5050", false))
    T.near(contact.y, 0, 0.8, "the rail is on the board's middle line: y " .. contact.y)
    T.near(contact.z, 30.3, 0.8, "at the hangers: z " .. contact.z)
    local fwd = e:GetForward()
    T.ok(math.abs(fwd.y) < 0.2 and fwd.x > 0.9, "the board is turned along it")
    T.ok(math.abs(e.st.pitch) < math.rad(6), "level")
    T.ok(e:GetPhysicsObject():GetVelocity().x > 150, "sliding along it")
    T.ok(E.IsValid(e:GetDriver()), "rider aboard")
    T.eq(#sv.errors, 0, "no errors: " .. table.concat(sv.errors, " | "))
    -- Off the end it lets go and pays a 50-50.
    press(e, { jump = true })
    sv:run(4, function() press(e, { jump = true, side = -math.max(-1, math.min(1, (e.st.board.meter or 0) * 4)) }) end)
    local p
    for _, t in ipairs(got) do if t.name == "50-50" then p = t end end
    T.ok(p and p.points > 50, "a 50-50 was paid: " .. tostring(p and p.points))
end)

T.test("grind ride: no SPACE, no lock; bmx_board_autogrind locks without it", function()
    local sv0 = F.server()
    local sv, e = world({ pipe(sv0.env, 600) })
    local E = sv.env
    press(e, {})
    launch(sv, e, -200, 0.5, 30, 5, 5, E.Vector(280, 0, -30))
    local any = false
    sv:run(0.5, function() any = any or e.st.grind ~= nil end)
    T.ok(not any, "without SPACE it just flies over the rail")

    local sv2, e2 = world({ pipe(sv0.env, 600) })
    press(e2, {})
    e2.st.board = e2.st.board or sv2.env.BMX.BoardState(e2.st)
    e2.st.board.autogrind = true
    e2.st.board.nextPoll = 1e9              -- the poll would read the convar and clear it
    launch(sv2, e2, -200, 0.5, 30, 5, 5, sv2.env.Vector(280, 0, -30))
    local locked
    sv2:run(0.4, function() locked = locked or e2.st.grind end)
    T.ok(locked, "with autogrind on it locks on contact")
end)

-- A grind or slide of each kind, on a long rail or ledge, judged by where it puts
-- the board and what it calls it.
local CASES = {
    -- id          keys   ledge  yaw  expected state
    { "grind5050", "",    false, 5 },
    { "grind50",   "s",   false, 5 },
    { "nosegrind", "w",   false, 5 },
    { "crooked",   "wa",  false, 5 },
    { "boardslide", "",   false, 90 },
    { "smith",     "sa",  true,  5 },
    { "feeble",    "sd",  true,  5 },
    { "lipslide",  "a",   true,  90 },
    { "noseslide", "w",   true,  90 },
    { "tailslide", "s",   true,  90 },
}

T.test("grind ride: each move, off its keys and its approach angle, is the one the rule says and sits as it should", function()
    for _, c in ipairs(CASES) do
        local id, ks, edge, yaw = c[1], c[2], c[3], c[4]
        local sv0 = F.server()
        local sv, e = world({ edge and ledge(sv0.env) or pipe(sv0.env, 800) })
        local E = sv.env
        local k = keys(ks)
        press(e, { jump = true, fwd = (k.w and 1 or 0) - (k.s and 1 or 0), side = (k.d and 1 or 0) - (k.a and 1 or 0),
                   w = k.w, s = k.s })
        local y = edge and 2 or 0.5
        local top = edge and 20 or 30
        launch(sv, e, -300, y, top, 5, yaw, E.Vector(300, 0, -30))
        local g
        sv:run(0.35, function() g = g or e.st.grind end)
        T.ok(g, id .. ": locked on")
        if g then
            T.eq(g.move, id, id .. ": the move the keys and the angle pick")
            local def = E.BMX.Board.Grinds[id]
            T.eq(g.kind, edge and "peg" or "crank", id .. ": the rail it is on")
            T.near(e:GetGrind(), E.BMX.Board.SparkCode[id], 0, id .. ": networked for the sparks")
            -- The contact point is on the rail's line, at its top.
            local sgn = g.localPoint.y >= 0 and 1 or -1
            local contact = e:LocalToWorld(g.localPoint)
            T.near(contact.z, top + 0.3, 0.9, id .. ": the contact is on the rail's top: z " .. contact.z)
            -- How it is turned: along (a grind) or across (a slide).
            local f = e:GetForward()
            local along = math.abs(f.x)
            if def.along then
                T.ok(along > 0.8, id .. ": turned along the rail: " .. along)
            else
                T.ok(along < 0.35, id .. ": turned across the rail: " .. along)
            end
            -- The nose attitude.
            local pitch = select(2, E.BMX.Attitude(e, E.Vector(0, 0, 1)))
            if def.pitch > 0.05 then T.ok(pitch > 0.05, id .. ": nose up: " .. math.deg(pitch))
            elseif def.pitch < -0.05 then T.ok(pitch < -0.05, id .. ": nose down: " .. math.deg(pitch)) end
            T.ok(E.IsValid(e:GetDriver()), id .. ": rider aboard")
        end
        T.eq(#sv.errors, 0, id .. ": no errors: " .. table.concat(sv.errors, " | "))
    end
end)

T.test("grind ride: a grind pays under its name at its multiple, with the stance in front of it", function()
    local function ride(prefixSwitch)
        local sv0 = F.server()
        local sv, e = world({ pipe(sv0.env, 400) })
        local E = sv.env
        local got = paid(e)
        local b = E.BMX.BoardState(e.st)
        b.switch = prefixSwitch and true or false
        b.nextPoll = 1e9
        press(e, { jump = true, fwd = -1, s = true })
        launch(sv, e, -200, 0.5, 30, 5, 5, E.Vector(330, 0, -30))
        sv:run(0.2)
        local g = e.st.grind
        -- Stay on, balanced, until it ends by itself.
        sv:run(3, function()
            local m = e.st.board.meter or 0
            press(e, { jump = true, fwd = -1, s = true, side = -math.max(-1, math.min(1, m * 4)) })
        end)
        return got, g
    end
    local got, g = ride(false)
    local p
    for _, t in ipairs(got) do if t.name == "5-0" then p = t end end
    T.ok(p, "paid as a 5-0: " .. (got[1] and got[1].name or "nothing"))
    local gs, gg = ride(true)
    local q
    for _, t in ipairs(gs) do if t.name == "Switch 5-0" then q = t end end
    T.ok(q, "in switch it says so: " .. (gs[1] and gs[1].name or "nothing"))
    T.ok(gg and gg.mult > g.mult, "and pays more for it: " .. tostring(gg and gg.mult) .. " vs " .. tostring(g and g.mult))
end)

T.test("grind ride: letting go of SPACE pops off the rail, and the flip window is open", function()
    local sv0 = F.server()
    local sv, e = world({ pipe(sv0.env, 2000) })
    local E = sv.env
    press(e, { jump = true })
    launch(sv, e, -200, 0, 30, 5, 0, E.Vector(300, 0, -20))
    sv:run(0.4)
    T.ok(e.st.grind, "grinding")
    press(e, {})                            -- SPACE released
    sv:tick()
    T.ok(not e.st.grind, "off the rail")
    T.ok(e:GetPhysicsObject():GetVelocity().z > 60, "popped up: " .. e:GetPhysicsObject():GetVelocity().z)
    T.ok(e.st.board.popAt, "an ollie: the pop window is open")
    press(e, { side = -1 })
    sv:run(0.3)
    T.ok(e.st.board.flip and e.st.board.flip.id == "kickflip", "so A is a kickflip out of the grind")
    T.ok(E.IsValid(e:GetDriver()), "rider aboard")
    sv:run(0.2)
    T.ok(not e.st.grind, "and it does not lock straight back on")
end)

T.test("grind ride: unattended the meter is lost and the rider bails; held with A and D it is not", function()
    local sv0 = F.server()
    local sv, e = world({ pipe(sv0.env, 3000) })
    local E = sv.env
    local why
    E.hook.Add("BMX_GrindEnded", "test", function(ent, kind, w) why = w end)
    press(e, { jump = true })
    launch(sv, e, -300, 0, 30, 5, 0, E.Vector(330, 0, -20))
    sv:run(9, function() press(e, { jump = true }) end)
    T.eq(why, "balance", "it ended on the balance")
    T.ok(not E.IsValid(e:GetDriver()), "and the rider is off")

    local sv2, e2 = world({ pipe(sv0.env, 3000) })
    local E2 = sv2.env
    local why2
    E2.hook.Add("BMX_GrindEnded", "test", function(ent, kind, w) why2 = w end)
    press(e2, { jump = true })
    launch(sv2, e2, -300, 0, 30, 5, 0, E2.Vector(330, 0, -20))
    local peak = 0
    sv2:run(4, function()
        local m = e2.st.board.meter or 0
        peak = math.max(peak, math.abs(m))
        press(e2, { jump = true, side = m > 0.05 and -1 or (m < -0.05 and 1 or 0) })
    end)
    T.ok(why2 == nil and e2.st.grind, "held through four seconds, still on the rail: " .. tostring(why2))
    T.ok(peak < 0.9, "the meter stayed in range: " .. peak)
    T.ok(E2.IsValid(e2:GetDriver()), "rider aboard")
end)

T.test("grind ride: a flip not yet caught does not lock on, and a caught one does and is paid", function()
    local sv0 = F.server()
    local sv, e = world({ pipe(sv0.env, 800) })
    local E = sv.env
    local B = E.BMX
    local b = B.BoardState(e.st)
    press(e, { jump = true })
    b.flip = { id = "kickflip", def = B.Board.Flips.kickflip, t0 = sv.world.time - 0.05 }
    launch(sv, e, -200, 0.5, 30, 5, 5, E.Vector(280, 0, -30))
    local any = false
    sv:run(0.12, function() any = any or e.st.grind ~= nil end)
    T.ok(not any, "mid-flip it is not placed on a rail upside down")

    local sv2, e2 = world({ pipe(sv0.env, 800) })
    local E2 = sv2.env
    local got = paid(e2)
    local b2 = E2.BMX.BoardState(e2.st)
    press(e2, { jump = true })
    b2.flip = { id = "kickflip", def = E2.BMX.Board.Flips.kickflip, t0 = sv2.world.time - 0.5 }
    b2.flipRoll = 6
    launch(sv2, e2, -200, 0.5, 30, 5, 5, E2.Vector(280, 0, -30))
    local locked
    sv2:run(0.4, function() locked = locked or e2.st.grind end)
    T.ok(locked, "a finished flip lets it lock on")
    local kf
    for _, t in ipairs(got) do if t.name:find("Kickflip") then kf = t end end
    T.ok(kf, "and the kickflip is paid on the way in: " .. (got[1] and got[1].name or "nothing"))
    T.eq(e2.st.board.flip, nil, "the flip is over")
    T.eq(e2:GetBoardBits(), 0, "and the deck is flat for the grind")
end)

T.test("grind ride: the bike's grind is untouched by the board's wrappers", function()
    local sv = F.server({ solids = { pipe(F.server().env, 600) } })
    local bike = F.bike(sv)
    F.scripted(sv, bike)
    sv:run(0.3)
    local E = sv.env
    local crank = E.BMX.GrindCrankPoint(bike:Cfg())
    local ang = E.Angle(0, 8, 0)
    local off = ang:Forward() * crank.x - ang:Right() * crank.y + ang:Up() * crank.z
    F.place(bike, E.Vector(-200, 0.5, 35) - off, ang)
    bike:GetPhysicsObject():SetVelocity(E.Vector(300, 0, -40))
    bike.st.grounded, bike.st.groundedFor = false, 0
    local g
    sv:run(0.3, function() g = g or bike.st.grind end)
    T.ok(g and g.kind == "crank" and not g.move, "a crank grind, no move")
    T.eq(bike:GetGrind(), 1, "networked as the bike's code")
end)

--------------------------------------------------------------------------
-- On the plant: manuals
--------------------------------------------------------------------------

local function rolling(speed)
    local sv, e = BF.ridden()
    press(e, { throttle = 1, fwd = 1 })
    sv:run(5, function() return e.st.fwdSpeed > speed end)
    return sv, e
end

-- Hold the meter near zero with W / S, the way a rider does.
local function balanced(e, nose)
    local m = e.st.board.meter or 0
    local push = (m > 0.1 and -1) or (m < -0.1 and 1) or 0
    if nose then push = -push end
    -- push > 0 is S (raises the meter) in a manual.
    return { grab = true, alt = nose or false, fwd = push < 0 and 1 or (push > 0 and -1 or 0),
             w = push < 0, s = push > 0 }
end

T.test("manual ride: RMB lifts the nose and holds it, balanced with W and S, and releasing pays it", function()
    local sv, e = rolling(90)
    local got, combo = {}, nil
    sv.env.hook.Add("BMX_TrickLanded", "test", function(ply, t) got[#got + 1] = t end)
    press(e, { grab = true })
    sv:run(0.5)
    T.eq(e.st.board.manual, "manual", "a manual")
    T.ok(e.st.manual, "the combo system sees it (st.manual)")
    T.ok(math.abs(e:GetMeter()) <= 1.2, "the meter is networked")
    local front, rear = 0, 0
    for _, w in ipairs(e.wheels) do
        if w.isFront and w.onGround then front = front + 1 end
        if not w.isFront and w.onGround then rear = rear + 1 end
    end
    T.ok(e.st.pitch > math.rad(6), "the nose is up: " .. math.deg(e.st.pitch))
    T.ok(rear == 2 and front == 0, "on the back wheels only: " .. rear .. " rear, " .. front .. " front")
    sv:run(2.0, function() press(e, balanced(e)) end)
    T.eq(e.st.board.manual, "manual", "still holding it a couple of seconds on")
    T.ok(e.st.pitch > math.rad(6) and e.st.pitch < math.rad(25), "at about the manual pitch: " .. math.deg(e.st.pitch))
    T.ok(math.abs(e.st.board.meter) < 0.8, "the meter is in range: " .. e.st.board.meter)
    T.ok(e:GetBoardFlags() ~= 0 and sv.env.BMX.Board.HasFlag(e:GetBoardFlags(), "manual"), "flagged for the HUD")
    press(e, {})
    sv:run(0.5)
    T.eq(e.st.board.manual, nil, "released")
    local m
    for _, t in ipairs(got) do if t.name:find("Manual") then m = t end end
    T.ok(m and m.points > 150, "a Manual was paid: " .. tostring(m and m.points))
    T.ok(math.abs(e.st.pitch) < math.rad(5), "and the board is level again: " .. math.deg(e.st.pitch))
    T.ok(e:GetDriver():InVehicle(), "rider aboard")
end)

T.test("manual ride: ALT with RMB is a nose manual, the tail up", function()
    local sv, e = rolling(90)
    press(e, { grab = true, alt = true })
    sv:run(0.5)
    T.eq(e.st.board.manual, "nose", "a nose manual")
    local front, rear = 0, 0
    for _, w in ipairs(e.wheels) do
        if w.isFront and w.onGround then front = front + 1 end
        if not w.isFront and w.onGround then rear = rear + 1 end
    end
    T.ok(e.st.pitch < -math.rad(6), "the tail is up: " .. math.deg(e.st.pitch))
    T.ok(front == 2 and rear == 0, "on the front wheels only: " .. front .. " front, " .. rear .. " rear")
    sv:run(1.5, function() press(e, balanced(e, true)) end)
    T.eq(e.st.board.manual, "nose", "held")
end)

T.test("manual ride: unattended the meter is lost: it loops out and bails, or drops and ends", function()
    local sv, e = rolling(90)
    local crashed
    sv.env.hook.Add("BMX_Crashed", "test", function(ent, ply, reason) crashed = reason end)
    press(e, { grab = true })
    sv:run(7, function() press(e, { grab = true }) end)
    T.eq(e.st.board.manual, nil, "it ended")
    T.ok(crashed == "manual" or e.st.speed > 0, "a loop-out is a bail: " .. tostring(crashed))
end)

T.test("manual ride: no manual below walking pace, none off the ground, and none while crouching", function()
    local sv, e = BF.ridden()
    press(e, { grab = true })
    sv:run(0.5)
    T.eq(e.st.board.manual, nil, "standing still it is not a manual")
    local sv2, e2 = rolling(90)
    press(e2, { grab = true, jump = true })
    sv2:run(0.3)
    T.eq(e2.st.board.manual, nil, "crouching for an ollie it is not")
end)

T.test("manual ride: a grind into a manual into a flip keeps one combo open", function()
    local sv, e = rolling(90)
    local E = sv.env
    press(e, { grab = true })
    sv:run(1.4, function() press(e, balanced(e)) end)
    press(e, {})
    sv:run(0.3)
    T.ok(e.st.combo, "the manual opened a combo: " .. tostring(e.st.combo))
    local n = e.st.combo and e.st.combo.n or 0
    T.ok(n >= 1, "with the manual in it")
end)
