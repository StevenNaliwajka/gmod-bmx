--[[--------------------------------------------------------------------------
    THE SKATES UNDER REAL PING, offline (G25, G30).

    The skates are the one vehicle whose movement the client PREDICTS (the player
    is the chassis: cl_skates.lua runs the shared step in the engine's own
    SetupMove). An audit found that nothing had ever run it with a ping. These run
    a server and a client against each other over a delayed, jittery, lossy link
    (tests/lib/netsim.lua: the engine's replay-on-correction loop, a stand-in for
    its movement after the hooks, the same on both ends) and measure what the
    player would see: the client's picture of each command against where the
    server put them for it, every correction's jump, and whether the client
    thought it was on a rail when the server did.

    What it found on 1.3.4 (main), and what these hold fixed:

      * ON A RAIL the client handed the move to the engine with the keys still in
        it. A and D, the balance, walked the skater off the side of the rail on
        their own screen: 15 units off (95th percentile, 25 at worst) at 100 ms,
        37 (50) at 200, snapped back every snapshot: 17 and 20 corrections of more
        than 4 units in a one-second grind.
      * THE POP off a rail was the server's alone: the client sat on the rail for
        a ping after SPACE was let go, then jumped 22 units (100 ms), about 40 (200).
      * A REPLAY never settled: the engine predicts every unacknowledged command
        again after a correction, and the client's own state (stride clock,
        heading, last SPACE, the speed it wrote) ran on from the newest command,
        so the replay disagreed with the server too, and the next one, for good.
        Forced to replay every snapshot, a carve at 100 ms was off by 14 units
        (95th percentile) with 21 snaps.
      * HOLSTERING: the client glided on for a ping after the server had put the
        skater on their feet: a 14-unit snap at 100 ms, 40 at 200.

    And what is still the server's, and pinned here as a known limit: the LOCK
    onto a rail. The client lands on the rail's top and rolls until the server's
    flag comes; along a rail that is close to a grind (a correction under 1.1
    units at 200 ms), turned across it (a backslide) the wheels grip and it is not.

    BMX_PING_REPORT=1 prints the whole table: every scenario at 50, 100 and 200 ms
    RTT, and a bike under the same link (lua5.1 tests/run.lua test_skates_ping).
----------------------------------------------------------------------------]]

local NS = require("lib.netsim")
local DT = NS.DT

local function secs(s) return math.floor(s / DT + 0.5) end

--------------------------------------------------------------------------
-- THE SCENARIOS: what a player does, tick by tick. A hand reads only what that
-- player's own client shows (its predicted position, the networked flags and
-- meter), as a player would.
--------------------------------------------------------------------------
local SC = {}

SC.straight = function(sim)
    sim:play(secs(0.5))
    sim:play(secs(4), function() return { w = true } end)
    sim:play(secs(1), function() return {} end)
end

-- a mouse slalom (+-45 degrees at 0.5 Hz), then keyboard crossovers
SC.carve = function(sim)
    sim:play(secs(0.5))
    sim:play(secs(1.5), function() return { w = true } end)
    local t = 0
    sim:play(secs(4), function()
        t = t + DT
        return { w = true, turn = 45 * math.pi * math.cos(math.pi * t) * DT }
    end)
    sim:play(secs(1), function() return { w = true, a = true } end)
    sim:play(secs(1), function() return { w = true, d = true } end)
    sim:play(secs(0.5), function() return {} end)
end

SC.jump = function(sim)
    sim:play(secs(0.5))
    sim:play(secs(2.5), function() return { w = true } end)
    sim:play(secs(0.15), function() return { jump = true } end)
    sim:play(secs(1.5), function() return {} end)
end

SC.stop = function(sim)
    sim:play(secs(0.5))
    sim:play(secs(3), function() return { w = true } end)
    sim:play(secs(2.5), function() return { s = true } end)
    sim:play(secs(0.5), function() return {} end)
end

local function grinding(s) return s.cp:GetNWInt("BMXSkateFlags", 0) % 8 >= 4 end

-- Ride, jump when `go(pos)`, hold SPACE, keep the HUD meter level with A / D, let go
-- `popAfter` s after the grind showed (nil: ride it out). `turn` degrees a tick of mouse
-- for the first `turnFor` ticks of the air.
local function grindRun(sim, go, popAfter, turn, turnFor)
    sim:play(secs(0.5))
    local phase, seen, n = "ride", nil, 0
    sim:play(secs(7), function(k, s)
        if phase == "ride" then
            if go(s.cp._pos) then phase = "air" else return { w = true } end
        end
        if phase == "air" then
            n = n + 1
            if grinding(s) then phase, seen = "grind", k end
            return { jump = true, turn = (turn and n <= turnFor) and turn or 0 }
        end
        if phase == "grind" then
            if not grinding(s) and k - seen > secs(0.5) then phase = "after" return {} end
            if popAfter and (k - seen) * DT >= popAfter then phase = "after" return {} end
            local m = s.cp:GetNWFloat("BMXSkateMeter", 0)
            return { jump = true, a = m > 0.1, d = m < -0.1 }
        end
        return {}
    end)
end

SC.grind_pop = function(sim) grindRun(sim, function(p) return p.x >= 150 end, 1.0) end
SC.grind_end = function(sim) grindRun(sim, function(p) return p.x >= 150 end, nil) end
SC.backslide = function(sim) grindRun(sim, function(p) return p.x >= 120 end, 0.8, 6, 15) end
SC.ledge_pop = function(sim) grindRun(sim, function(p) return p.y >= -13 end, 0.8) end

-- jump, and turn the view 90 degrees in the first quarter second of the air: down sideways
local function bail(sim)
    sim:play(secs(0.5))
    sim:play(secs(2.5), function() return { w = true } end)
    local n = 0
    sim:play(secs(1.5), function()
        n = n + 1
        return { jump = n <= secs(0.15), turn = (n <= secs(0.25)) and (90 / secs(0.25)) or 0 }
    end)
    sim:play(secs(1.5), function() return {} end)
end
SC.bail = function(sim)
    sim.sv.env.GetConVar("bmx_crash_ragdoll"):SetString("0")       -- the shove: still on skates
    bail(sim)
end
SC.bail_ragdoll = bail

-- walking, the skates out of the weapon list holding W, skating, then the hands out again
SC.switch = function(sim)
    sim:play(secs(0.5))
    sim:play(secs(1), function() return { w = true } end)
    sim:play(1, function() return { w = true, weapon = "weapon_bmx_skates" } end)
    sim:play(secs(2.5), function() return { w = true } end)
    sim:play(1, function() return { weapon = "weapon_physgun" } end)
    sim:play(secs(2), function() return {} end)
end

local RAIL = function(V) return { { V(200, -1, 21), V(1500, 1, 24) } } end
local SHORT = function(V) return { { V(200, -1, 21), V(560, 1, 24) } } end
local LEDGE = function(V) return { { V(100, 18, 0), V(1500, 400, 20) } } end
local SETUP = {
    grind_pop = { solids = RAIL, start = { -500, 0, 0 } },
    grind_end = { solids = SHORT, start = { -500, 0, 0 } },
    backslide = { solids = RAIL, start = { -500, 0, 0 } },
    ledge_pop = { solids = LEDGE, start = { -500, -130, 0 }, yaw = 10 },
    switch = { equipped = false },
}

-- One run, by name and RTT (and any extra options): only its report is kept, so the realms can go.
local cache = {}
local function run(name, rtt, extra)
    local key = name .. "@" .. rtt .. (extra and extra.key or "")
    if cache[key] then return cache[key] end
    local opts = { rtt = rtt, jitter = 0.02, loss = 0.01, seed = 11 }
    for k, v in pairs(SETUP[name] or {}) do opts[k] = v end
    for k, v in pairs(extra or {}) do if k ~= "key" then opts[k] = v end end
    local sim = NS.Skater(opts)
    SC[name](sim)
    local r = sim:report(secs(0.5))
    r.errors = #sim.sv.errors + #sim.cl.errors
    r.errorText = table.concat(sim.sv.errors, " | ") .. table.concat(sim.cl.errors, " | ")
    -- the corrections, in order, and the error over the last second
    r.list = {}
    for _, c in ipairs(sim.corrections) do if not c.tumble then r.list[#r.list + 1] = c end end
    local tail = 0
    for n = math.max(1, sim.svLast - secs(1)), sim.svLast do
        local s, d = sim.svHist[n], sim.shown[n]
        if s and d and not s.tumbling then tail = math.max(tail, (d.pos - s.pos):Length()) end
    end
    r.tail = tail
    cache[key] = r
    sim = nil
    return r
end

local function clean(r, label)
    T.eq(r.errors, 0, label .. ": no Lua errors in either realm: " .. r.errorText)
end

-- The largest correction, and the number over `u` units.
local function over(r, u)
    local n, big = 0, 0
    for _, c in ipairs(r.list) do
        if c.d > u then n = n + 1 end
        if c.d > big then big = c.d end
    end
    return n, big
end

--------------------------------------------------------------------------
-- What was always right (a guard on it)
--------------------------------------------------------------------------
T.test("skates ping: straight, a carve, a jump and a T-stop are predicted exactly, at 100 and 200 ms", function()
    for _, c in ipairs({ { "straight", 0.2 }, { "carve", 0.1 }, { "carve", 0.2 }, { "jump", 0.2 }, { "stop", 0.2 } }) do
        local name, rtt = c[1], c[2]
        do
            local r = run(name, rtt)
            local label = string.format("%s at %d ms", name, rtt * 1000)
            clean(r, label)
            T.between(r.err.max, 0, 0.01, label .. ": the client's picture against the server's, worst, units")
            T.eq(r.corrOver1, 0, label .. ": corrections over a unit")
        end
    end
end)

--------------------------------------------------------------------------
-- The replay
--------------------------------------------------------------------------
T.test("skates ping: a command predicted again starts from the state the client had then, so a replay agrees with the server", function()
    -- cl_pred_optimize 0: the engine predicts every unacknowledged command again on every
    -- snapshot, which is what it does after any difference at all. 1.3.4's client ran its stride
    -- clock, heading and speed on from the newest command each time: a carve was 14 units off
    -- (95th percentile) with 21 snaps at 100 ms.
    for _, name in ipairs({ "carve", "switch" }) do
        local r = run(name, 0.1, { optimize = false, key = "/replay" })
        local label = name .. " at 100 ms, replayed every snapshot"
        clean(r, label)
        T.ok(r.replays > 50, label .. ": it did replay: " .. r.replays)
        T.between(r.err.max, 0, 0.01, label .. ": worst error, units")
        T.eq(r.corrOver1, 0, label .. ": corrections over a unit")
    end
end)

T.test("skates ping: a bail and a burst of lost commands are corrected once, and the client settles", function()
    -- The shove of a bail is the server's alone (the landing is judged there), and so is a
    -- lost command (the server runs the last one in its place). Each is one correction; 1.3.4
    -- went on correcting for a second or more after either (18 replays after the bail).
    local b = run("bail", 0.1)
    clean(b, "bail")
    T.between(b.replays, 1, 4, "bail at 100 ms: replays")
    local n4 = over(b, 4)
    T.eq(n4, 0, "bail at 100 ms: no correction over 4 units")
    T.between(b.tail, 0, 0.01, "bail at 100 ms: the error in the last second")
    local o = run("carve", 0.1, { outages = { { 2.0, 2.15 } }, key = "/outage" })
    clean(o, "outage")
    T.ok(o.replays >= 1, "a 150 ms outage mid-carve: it was corrected")
    T.between(o.tail, 0, 0.01, "and settled: the error in the last second")
    local rag = run("bail_ragdoll", 0.1)
    clean(rag, "bail with a ragdoll")
    T.between(over(rag, 4), 0, 0, "with a ragdoll: nothing over 4 units outside the tumble (the view is the ragdoll's)")
end)

--------------------------------------------------------------------------
-- On a rail
--------------------------------------------------------------------------
T.test("skates ping: on a rail, balancing with A / D, the client stays on the rail with the server", function()
    for _, rtt in ipairs({ 0.1, 0.2 }) do
        local r = run("grind_pop", rtt)
        local label = string.format("a one-second grind at %d ms", rtt * 1000)
        clean(r, label)
        T.eq(#r.grindLate, 1, label .. ": the server grinds once (" .. #r.grindLate .. " runs of a late start)")
        -- 1.3.4: 17 (100 ms) and 20 (200 ms) corrections over 4 units, the skater walked off the
        -- rail's side by A and D on their own screen
        local n4, big = over(r, 4)
        T.eq(n4, 0, label .. ": corrections over 4 units (largest " .. string.format("%.2f", big) .. ")")
        T.between(r.err.p95, 0, 0.5, label .. ": the client's picture against the server's, 95th percentile, units")
    end
end)

T.test("skates ping: letting go of SPACE pops off a rail on the client at the server's own command", function()
    for _, rtt in ipairs({ 0.1, 0.2 }) do
        local r = run("grind_pop", rtt)
        local label = string.format("the pop at %d ms", rtt * 1000)
        -- 1.3.4 held the skater on the rail for a ping after SPACE was let go, then jumped 22
        -- (100 ms) to 41 (200 ms) units up when the server's answer came
        T.eq(#r.grindStale, 0, label .. ": commands the client was on the rail and the server was not")
        local last = r.list[#r.list]
        T.ok(not last or last.d < 1.1, label .. ": the last correction (the lock-on's) is small: "
            .. string.format("%.2f", last and last.d or 0))
    end
end)

T.test("skates ping: a rail that runs out ends on the client too, within a tick or two of the server", function()
    local r = run("grind_end", 0.2)
    clean(r, "rail end")
    T.eq(#r.grindStale, 0, "rail end at 200 ms: on the rail on the client after the server came off")
    T.ok(#r.grindLate <= 2, "the lock (a ping) and at most the end")
    if #r.grindLate == 2 then T.between(r.grindLate[2], 0, 50, "the client came off early by, ms") end
    T.between(select(2, over(r, 0)), 0, 2, "rail end at 200 ms: the largest correction, units")
end)

T.test("skates ping: an edge grind's pop pushes away from the ledge on the client too (BMXSkateSide)", function()
    local r = run("ledge_pop", 0.2)
    clean(r, "ledge")
    T.eq(#r.grindLate, 1, "it locked onto the ledge's edge")
    -- one correction for the lock (the server's alone), none for the pop: without the side the
    -- client popped straight up and was 12 units off when the server's answer came
    T.between(over(r, 1), 0, 1, "corrections over a unit at 200 ms (the lock-on)")
    T.eq(#r.grindStale, 0, "on the ledge on the client after the server came off")
end)

T.test("skates ping: KNOWN LIMIT: the lock onto a rail is the server's; a backslide's first ping is corrected once", function()
    -- The client does not run the rail finder (sv_grind.lua), so until the server's flag comes it
    -- lands on the rail's top and rolls. Along the rail that is near enough a soul grind; turned
    -- across it the wheels grip and it veers. One correction, then the grind and the pop are
    -- predicted. Predicting the lock means sharing the finder (docs/goals/G30-netcode-feel.md).
    local r = run("backslide", 0.1)
    clean(r, "backslide")
    T.eq(#r.grindLate, 1, "it locked into a grind")
    local n1, big = over(r, 1)
    T.between(n1, 1, 2, "corrections over a unit: the lock-on (and a bail on landing across)")
    T.between(r.list[1] and r.list[1].d or 0, 4, 20, "the lock-on's correction at 100 ms, units")
    T.ok(big < 25, "nothing bigger: " .. big)
end)

--------------------------------------------------------------------------
-- On and off
--------------------------------------------------------------------------
T.test("skates ping: the skates start and stop being predicted at the weapon switch, the server's own command", function()
    for _, rtt in ipairs({ 0.1, 0.2 }) do
        local r = run("switch", rtt)
        local label = string.format("equip and holster at %d ms", rtt * 1000)
        clean(r, label)
        -- 1.3.4 waited for BMXWorn, a ping late: on the holster it glided on and snapped back 14
        -- units (100 ms) or 40 (200 ms)
        T.between(r.err.max, 0, 0.01, label .. ": worst error, units")
        T.eq(r.corrOver1, 0, label .. ": corrections over a unit")
    end
end)

T.test("skates ping: skates in hand the server never puts on (bmx_allow_boards 0) are walked on again", function()
    local sim = NS.Skater({ rtt = 0.1, jitter = 0.02, loss = 0.01, seed = 11, equipped = false })
    sim.sv.env.GetConVar("bmx_allow_boards"):SetString("0")
    SC.switch(sim)
    T.eq(sim.sp.BMXWorn, nil, "the server refused them")
    local worst = 0
    for n = math.max(1, sim.svLast - secs(1.5)), sim.svLast do
        local s, d = sim.svHist[n], sim.shown[n]
        if s and d then worst = math.max(worst, (d.pos - s.pos):Length()) end
    end
    T.between(worst, 0, 0.01, "after GRACE the client walks with the server again: the error in the last 1.5 s")
    T.eq(#sim.sv.errors + #sim.cl.errors, 0, "no errors")
end)

--------------------------------------------------------------------------
-- The arithmetic shared with the server
--------------------------------------------------------------------------
T.test("skates ping: S.GrindHeading turns the boots as the server's grind pose does; S.GrindSpeed is its arithmetic", function()
    local sv = require("lib.fixture").server()
    local E = sv.env
    local S = E.BMX.Skates
    local cfg = E.BMX.ConfigFor(E.BMX.Vehicles.skates)
    local function pose(dir, yaw)
        local _, ang = E.BMX.GrindPose({ dir = dir, yaw = yaw, kind = "crank", point = E.Vector(0, 0, 0),
                                         localPoint = E.Vector(0, 0, 0) }, cfg)
        return math.rad(ang.y)
    end
    local function same(a, b, label) T.near(math.abs(S.Wrap(a - b)), 0, 1e-9, label) end
    local d = E.Vector(math.cos(0.3), math.sin(0.3), 0)
    same(S.GrindHeading(0.35, d.x, d.y, 1), pose(d, 0), "a soul, facing along the rail")
    same(S.GrindHeading(0.3 + math.pi - 0.2, d.x, d.y, 2), pose(d, math.pi), "a mizou facing back up it: half a turn")
    same(S.GrindHeading(0.3 + 1.4, d.x, d.y, 3), pose(d, math.pi / 2), "a backslide turned left of the rail")
    same(S.GrindHeading(0.3 - 1.4, d.x, d.y, 3), pose(d, -math.pi / 2), "a backslide turned right of it")
    same(S.GrindHeading(0.3 + math.pi / 2, d.x, d.y, 3), 0.3 + math.pi / 2, "and it stays where it is put")
    local G = cfg.Grind
    T.eq(S.GrindSpeed(300, -0.1, 1, DT, G, 600), 300 - 600 * -0.1 * DT - (G.friction + G.brakeDecel * 1) * DT,
        "the speed on a rail: gravity along it, the friction, the brake")
end)

--------------------------------------------------------------------------
-- The baseline: a bike under the same link
--------------------------------------------------------------------------
T.test("skates ping: the bike under the same link is drawn a ping late but never corrected (the accepted baseline)", function()
    local sim = NS.Bike({ rtt = 0.1, jitter = 0.02, loss = 0.01, seed = 11 })
    sim:play(secs(0.5))
    sim:play(secs(3), function() return { w = true } end)
    local r = sim:report(secs(0.6))
    T.eq(r.jumps, 0, "the drawn bike never jumps")
    T.between(r.err.max, 0, 0.5, "it is the server's bike, interpolated: units off the server's at the time drawn")
    T.between(r.lag.mean, 10, 60, "and behind the server's bike now by, units")
end)

--------------------------------------------------------------------------
-- BMX_PING_REPORT=1: the whole table.
--------------------------------------------------------------------------
if os.getenv("BMX_PING_REPORT") then
    T.test("skates ping: REPORT (BMX_PING_REPORT)", function()
        local names = { "straight", "carve", "jump", "stop", "grind_pop", "grind_end", "backslide", "ledge_pop",
                        "bail", "bail_ragdoll", "switch" }
        print("")
        print("skates (predicted): err = the client's picture vs the server's for the same command, units;")
        print("corr = jumps of the drawn position at reconciliation; late/stale = ms the client was off / on a rail against the server")
        for _, name in ipairs(names) do
            for _, rtt in ipairs({ 0.05, 0.1, 0.2 }) do
                local r = run(name, rtt)
                local n4, big = over(r, 4)
                print(string.format("  %-12s %3d ms  err mean %5.2f p95 %5.2f max %6.2f | corr >1u %2d  >4u %2d  max %6.2f | replays %3d | late %s | stale %s",
                    name, rtt * 1000, r.err.mean, r.err.p95, r.err.max, r.corrOver1, n4, big, r.replays,
                    table.concat((function() local o = {} for i, v in ipairs(r.grindLate) do o[i] = math.floor(v) end return o end)(), ","),
                    table.concat((function() local o = {} for i, v in ipairs(r.grindStale) do o[i] = math.floor(v) end return o end)(), ",")))
            end
        end
        print("bike (not predicted, drawn cl_interp 0.1 behind): lag = drawn vs the server's bike now; jumps = frames off by > 4 u")
        local pipe = function(V) return { { V(150, -1, 15), V(700, 1, 18) } } end
        local BS = {
            straight = function(sim) sim:play(secs(0.5)) sim:play(secs(4), function() return { w = true } end) end,
            carve = function(sim)
                sim:play(secs(0.5)) sim:play(secs(1.5), function() return { w = true } end)
                for _ = 1, 3 do
                    sim:play(secs(1), function() return { w = true, a = true } end)
                    sim:play(secs(1), function() return { w = true, d = true } end)
                end
            end,
            hop = function(sim)
                sim:play(secs(0.5)) sim:play(secs(2.5), function() return { w = true } end)
                sim:play(secs(0.4), function() return { w = true, jump = true } end)
                sim.releaseAt = sim.k + 1
                sim:play(secs(1.5), function() return { w = true } end)
            end,
            stop = function(sim)
                sim:play(secs(0.5)) sim:play(secs(3), function() return { w = true } end)
                sim:play(secs(2.5), function() return { s = true } end)
            end,
            grind = function(sim)
                local t0 = sim.k
                sim:play(secs(3.5), function(k)
                    local t = (k - t0) * DT
                    return { w = true, jump = t >= 0.02 and t < 0.47 }
                end)
            end,
        }
        for _, name in ipairs({ "straight", "carve", "hop", "stop", "grind" }) do
            for _, rtt in ipairs({ 0.05, 0.1, 0.2 }) do
                local opts = { rtt = rtt, jitter = 0.02, loss = 0.01, seed = 11 }
                if name == "grind" then opts.solids, opts.y, opts.speed = pipe, -3, 260 end
                local sim = NS.Bike(opts)
                BS[name](sim)
                local r = sim:report(secs(0.6))
                local seen = ""
                if sim.releaseAt and sim.drawn[sim.releaseAt] then
                    local z0 = sim.drawn[sim.releaseAt].pos.z
                    for k = sim.releaseAt, sim.k do
                        local d = sim.drawn[k]
                        if d and d.pos.z > z0 + 2 then seen = string.format(" | the hop seen %d ms after the key", (k - sim.releaseAt) * DT * 1000) break end
                    end
                end
                if r.grindLate then seen = seen .. string.format(" | the grind seen %d ms after the server's", r.grindLate) end
                print(string.format("  bike %-8s %3d ms  lag mean %5.1f p95 %5.1f max %5.1f | jumps %d%s",
                    name, rtt * 1000, r.lag.mean, r.lag.p95, r.lag.max, r.jumps, seen))
                sim = nil
            end
        end
    end)
end
