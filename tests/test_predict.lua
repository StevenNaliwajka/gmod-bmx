--[[--------------------------------------------------------------------------
    G30: feel under real ping. The pure parts (sh_lean.lua, sh_predict.lua), the
    client's offsets, the probe, the lag compensation and the settings rows.

    Prediction is DISPLAY-ONLY, and the tests hold it to that: the server is
    unchanged bit for bit (test_predict_server_unchanged.lua), the shared
    controller is the same code on both realms, and a client that never sends
    anything cannot move a server number.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local gmod = require("lib.gmod")
local IN = gmod.IN

local function both()
    local sv, world = F.server()
    local cl = F.client(world)
    return sv, cl
end

-- A recorded input sequence: A/D taps and holds at a fixed tick.
local function recorded()
    local seq, state = {}, 0
    local script = { { 20, 1 }, { 30, 0 }, { 25, -1 }, { 15, 0 }, { 40, 1 }, { 10, -1 }, { 30, 0 } }
    for _, leg in ipairs(script) do
        for _ = 1, leg[1] do seq[#seq + 1] = leg[2] end
    end
    return seq
end

-- One whole controller run through the shared functions of a realm's BMX.
local function run(B, seq)
    local dt = 1 / 66
    local lean, roll, rate, last, steer = 0, 0, 0, 0, 0
    local out = {}
    local Bc = B.Config.Balance
    for i, target in ipairs(seq) do
        lean = B.Lean.StepLean(lean, target, dt)
        rate = B.Lean.FilterRate(rate, last, roll, dt)
        last = roll
        local topple = B.Lean.Topple(B.Config.Chassis.mass, 600, 30, roll, B.Config.Chassis.inertiaRoll)
        local alpha = B.Lean.RollAlpha(topple, Bc.leanKp, Bc.leanKd, lean * Bc.maxLean - roll,
            rate, Bc.maxAssistAccel, 1)
        roll = roll + (rate + alpha * dt) * dt
        local d = B.Lean.DerivedSteer(B.Config.Wheel.wheelbase, 600, roll, 300)
        local tg = B.Lean.SteerTarget(d, lean, 300, Bc.walkSpeed, Bc.maxSteer)
        steer = B.Lean.SteerLag(steer, tg, Bc.steerRate, dt)
        out[i] = string.format("%.17g %.17g %.17g", lean, roll, steer)
    end
    return out
end

T.test("predict: the shared controller is identical on the client and the server", function()
    local sv, cl = both()
    local a, b = run(sv.env.BMX, recorded()), run(cl.env.BMX, recorded())
    T.eq(#a, #b, "steps")
    for i = 1, #a do T.eq(a[i], b[i], "step " .. i) end
    T.ok(a[#a] ~= a[1], "the sequence actually moved")
end)

T.test("predict: the lead is identical on the client and the server", function()
    local sv, cl = both()
    local function lead(B)
        local C = B.Config
        local hist = {}
        for i = 0, 30 do hist[#hist + 1] = { t = 10 + i / 66, target = i < 15 and 1 or 0, lean = math.min(i / 66 * 3, 1) } end
        return B.Predict.Lead{ roll = 0.05, rollRate = 0.2, steer = 0.01, speed = 300, now = 10.45,
            horizon = 0.25, history = hist, B = C.Balance, mass = C.Chassis.mass, g = 600, h = 30,
            inertia = C.Chassis.inertiaRoll, wheelbase = C.Wheel.wheelbase }
    end
    local r1, s1 = lead(sv.env.BMX)
    local r2, s2 = lead(cl.env.BMX)
    T.eq(string.format("%.17g", r1), string.format("%.17g", r2), "roll")
    T.eq(string.format("%.17g", s1), string.format("%.17g", s2), "steer")
end)

T.test("predict: the lead goes toward the lean the rider asked for, and a zero horizon is the networked state", function()
    local sv = F.server()
    local B, C = sv.env.BMX, sv.env.BMX.Config
    local function lead(h, target)
        return B.Predict.Lead{ roll = 0, rollRate = 0, steer = 0, speed = 300, now = 5, horizon = h,
            history = { { t = 4, target = target, lean = target } }, B = C.Balance,
            mass = C.Chassis.mass, g = 600, h = 30, inertia = C.Chassis.inertiaRoll,
            wheelbase = C.Wheel.wheelbase }
    end
    local r0, s0 = lead(0, 1)
    T.eq(r0, 0, "no horizon, no lead")
    T.eq(s0, 0, "no horizon, no lead (steer)")
    local rr, sr = lead(0.2, 1)
    local rl, sl = lead(0.2, -1)
    T.ok(rr > 0.02 and sr > 0, "D leans and steers right: " .. rr .. " " .. sr)
    T.ok(rl < -0.02 and sl < 0, "A leans and steers left")
    T.near(rr, -rl, 1e-12, "symmetric")
    T.ok(lead(0.1, 1) < rr, "a longer horizon leads further")
end)

T.test("predict: horizon is ping plus interp, capped", function()
    local P = F.server().env.BMX.Predict
    T.near(P.Horizon(0.1, 0.1), 0.2, 1e-12, "100 ms ping")
    T.eq(P.Horizon(2, 0.1), P.MAX_HORIZON, "capped")
    T.eq(P.Horizon(-1, 0), 0, "never negative")
end)

--------------------------------------------------------------------------
-- The blend
--------------------------------------------------------------------------
T.test("predict: an error under 4 units snaps, a larger one eases over 100 ms", function()
    local P = F.server().env.BMX.Predict
    local arm = 30
    T.eq(P.Blend(0, 3.9 / arm, arm, 1 / 60), 3.9 / arm, "3.9 u: snapped to the target")
    T.eq(P.Blend(0, -3.9 / arm, arm, 1 / 60), -3.9 / arm, "and the other way")

    local target = 10 / arm          -- 10 units off
    local x = P.Blend(0, target, arm, 1 / 60)
    T.ok(x > 0 and x < target, "10 u: moved toward it, not all the way")
    -- 100 ms of 60 fps frames: at least 95% of the way
    x = 0
    for _ = 1, 6 do x = P.Blend(x, target, arm, 1 / 60) end
    T.ok(x / target >= 0.80, "within 100 ms it is most of the way: " .. x / target)
    for _ = 1, 40 do x = P.Blend(x, target, arm, 1 / 60) end
    T.near(x, target, 4 / arm, "and it arrives (snap takes the last 4 u)")
    -- Never overshoots, whatever the frame time.
    T.ok(P.Blend(0, target, arm, 5) <= target, "a hitch of 5 s does not overshoot")
    -- Frame-rate independent to the extent the exponential is.
    local a = P.Blend(P.Blend(0, target, arm, 0.01), target, arm, 0.01)
    local b = P.Blend(0, target, arm, 0.02)
    T.near(a, b, 1e-12, "two 10 ms frames equal one 20 ms")
end)

--------------------------------------------------------------------------
-- The latency probe's arithmetic
--------------------------------------------------------------------------
-- Feed a synthetic bike: roll starts moving `delay` s after the key goes down.
local function trial(P, pr, t, delay, rate)
    local t0 = t
    local roll = 0
    local result
    while t < t0 + 1.2 do
        local pressed = t >= t0 + 0.1
        roll = pressed and math.max(0, (t - (t0 + 0.1) - delay)) * rate or math.max(0, roll - 0.05)
        local lat = P.ProbeFeed(pr, t, (t >= t0 + 0.1 and t < t0 + 0.6) and 1 or 0, roll)
        result = lat or result
        t = t + 1 / 66
    end
    return t, result
end

T.test("probe: the latency is the time from the key to the first visible lean", function()
    local P = F.server().env.BMX.Predict
    local pr = P.ProbeNew(3)
    local t = 100
    -- settle: no key, no motion
    for _ = 1, 5 do P.ProbeFeed(pr, t, 0, 0) t = t + 1 / 66 end
    local got
    t, got = trial(P, pr, t, 0.150, 0.8)    -- 150 ms before it moves at 0.8 rad/s
    -- visible at 1.5 deg = 0.0262 rad: 0.0327 s after it starts moving
    T.ok(got, "a trial completed")
    T.near(got, 0.150 + math.rad(1.5) / 0.8, 0.03, "latency")
    T.eq(#pr.results, 1, "recorded")
end)

T.test("probe: a still bike is the baseline, so a lean already under way is not a trial", function()
    local P = F.server().env.BMX.Predict
    local pr = P.ProbeNew(3)
    -- the key is down and the bike is already leaning when it starts watching
    for i = 1, 10 do P.ProbeFeed(pr, i / 66, 1, i * 0.01) end
    T.eq(#pr.results, 0, "nothing counted")
    T.ok(pr.state ~= "waiting", "never armed on a held key")
end)

T.test("probe: a lean in the wrong direction is not the visible lean; no lean times out", function()
    local P = F.server().env.BMX.Predict
    local pr = P.ProbeNew(3)
    local t = 0
    for _ = 1, 3 do P.ProbeFeed(pr, t, 0, 0) t = t + 0.02 end
    P.ProbeFeed(pr, t, 1, 0)             -- D pressed
    for _ = 1, 20 do t = t + 0.02 P.ProbeFeed(pr, t, 1, -0.1) end   -- it goes LEFT
    T.eq(#pr.results, 0, "left is not the lean that was asked for")
    for _ = 1, 120 do t = t + 0.02 P.ProbeFeed(pr, t, 1, 0) end     -- and then nothing
    T.eq(pr.dropped, 1, "timed out and counted as dropped")
end)

T.test("probe: finishes after n trials and summarises min / median / max in ms", function()
    local P = F.server().env.BMX.Predict
    local pr = P.ProbeNew(3)
    local t = 50
    for _ = 1, 5 do P.ProbeFeed(pr, t, 0, 0) t = t + 1 / 66 end
    for _, d in ipairs({ 0.2, 0.1, 0.3 }) do
        t = trial(P, pr, t, d, 1.0)
        for _ = 1, 30 do P.ProbeFeed(pr, t, 0, 0) t = t + 1 / 66 end   -- quiet between trials
    end
    T.ok(P.ProbeFinished(pr), "finished")
    local s = P.Summary(pr.results)
    T.eq(s.n, 3, "n")
    T.ok(s.min < s.median and s.median < s.max, "ordered")
    T.near(s.median, 1000 * (0.2 + math.rad(1.5)), 40, "median ms")
    T.eq(P.Summary({}), nil, "an empty run has no summary")
    T.near(P.Summary({ 0.1, 0.3 }).median, 200, 1e-9, "even count: the mean of the middle two")
end)

--------------------------------------------------------------------------
-- Lag compensation
--------------------------------------------------------------------------
T.test("lagcomp: a command's age is the time since the tick it saw, clamped by ping and the maximum", function()
    local P = F.server().env.BMX.Predict
    local dt = 1 / 66
    -- server tick 1000, command stamped 1006 ticks...: it saw tick 1000 - 6, lerp 0.1 = 6.6 ticks
    local age = P.CmdAge(1000, 994, 0.1, dt, 0.5, 0.2)
    T.near(age, (1000 - (994 - 0.1 / dt)) * dt, 1e-12, "(now - (cmd - lerp)) ticks")
    T.eq(P.CmdAge(1000, 0, 0.1, dt, 0.5, 0.2), 0, "no stamp (a bot): no age")
    T.eq(P.CmdAge(1000, 2000, 0.1, dt, 0.5, 0.2), 0, "a stamp from the future: no age")
    T.eq(P.CmdAge(1000, 100, 0.1, dt, 0.15, 5), 0.15, "capped at the maximum")
    T.near(P.CmdAge(1000, 100, 0.1, dt, 5, 0.05), 0.05 + 0.1 + 2 * dt, 1e-12,
        "and at what the player's own ping explains")
end)

T.test("lagcomp: the grounded history answers 'was it on the ground then'", function()
    local P = F.server().env.BMX.Predict
    local h = { { t = 1.0, grounded = true }, { t = 1.1, grounded = true },
                { t = 1.2, grounded = false }, { t = 1.3, grounded = false } }
    T.eq(P.GroundedAt(h, 1.15), true, "before it left")
    T.eq(P.GroundedAt(h, 1.25), false, "after")
    T.eq(P.GroundedAt(h, 0.2), true, "older than the record: the oldest sample")
    T.eq(P.GroundedAt({}, 1), false, "no record: no")
end)

-- A usercmd that carries a tick stamp.
local function cmd(buttons, tick)
    local c = { buttons = buttons or 0, fwd = 0, side = 0, tick = tick or 0 }
    function c:GetButtons() return self.buttons end
    function c:SetButtons(b) self.buttons = b end
    function c:GetForwardMove() return self.fwd end
    function c:GetSideMove() return self.side end
    function c:SetForwardMove(v) self.fwd = v end
    function c:SetSideMove(v) self.side = v end
    function c:SetUpMove() end
    function c:TickCount() return self.tick end
    return c
end

local function rig()
    local sv = F.server()
    local bike = F.bike(sv)
    local ply = F.rider(sv, bike)
    sv.env.engine.TickCount = function() return 1000 end
    return sv, bike, ply
end

T.test("lagcomp: off, every input's age is 0 and nothing changes", function()
    local sv, bike, ply = rig()
    sv.env.hook.Run("StartCommand", ply, cmd(IN.JUMP, 900))
    T.eq(bike.input.cmdAge, 0, "no age with bmx_lagcomp 0")
    sv.env.hook.Run("StartCommand", ply, cmd(0, 900))
    T.eq(bike.hopReleaseAge, 0, "the release is not back-dated")
    T.eq(sv.env.BMX.LagCompGrace(bike, 0.1), false, "and there is no grace")
end)

T.test("lagcomp: on, a release is stamped with its age and the grace covers a bike that just left the ground", function()
    local sv, bike, ply = rig()
    sv.env.GetConVar("bmx_lagcomp"):SetString("1")
    function ply:Ping() return 100 end
    local E = sv.env
    E.hook.Run("StartCommand", ply, cmd(IN.JUMP, 990))
    E.hook.Run("StartCommand", ply, cmd(0, 990))
    T.ok(bike.hopReleaseAge > 0 and bike.hopReleaseAge <= 0.15, "stamped: " .. tostring(bike.hopReleaseAge))
    -- On the ground for the last 0.1 s, in the air now.
    local now = E.CurTime()
    bike.lagHist = { { t = now - 0.2, grounded = true }, { t = now - 0.1, grounded = true },
                     { t = now - 0.02, grounded = false } }
    bike.st.grounded = false
    bike.st.groundNormal = E.Vector(0, 0, 1)
    T.eq(E.BMX.LagCompGrace(bike, 0.1), true, "pressed while it was on the ground")
    T.eq(E.BMX.LagCompGrace(bike, 0.01), false, "pressed after it had left")
    T.eq(E.BMX.LagCompGrace(bike, 0), false, "no age, no grace")
    bike.st.grounded = true
    T.eq(E.BMX.LagCompGrace(bike, 0.1), false, "grounded now: the ordinary path, no grace")
end)

T.test("lagcomp: it only changes WHEN an input counts: a hop released in the air with no history is dropped as before", function()
    local sv, bike, ply = rig()
    sv.env.GetConVar("bmx_lagcomp"):SetString("1")
    bike.st.grounded = false
    bike.st.groundNormal = sv.env.Vector(0, 0, 1)
    bike.lagHist = nil
    T.eq(sv.env.BMX.LagCompGrace(bike, 0.1), false, "no record of the ground: no hop")
end)

T.test("lagcomp: the spine press is dated to when it was made", function()
    -- sv_air.lua: st.spineWPress = now - inp.cmdAge. The window test uses it as is.
    local sv = F.server()
    local src = io.open(gmod.ROOT .. "/lua/bmx/sv_air.lua"):read("*a")
    T.ok(src:find("st.spineWPress = now - (inp.cmdAge or 0)", 1, true), "the press is back-dated by the age")
end)

--------------------------------------------------------------------------
-- The client: nothing for the server to see
--------------------------------------------------------------------------
T.test("predict: bmx_predict exists on the client, defaults off, and is described", function()
    local sv, cl = both()
    local cv = cl.env.GetConVar("bmx_predict")
    T.ok(cv, "the convar exists on the client")
    T.eq(cv:GetInt(), 0, "default off")
    T.ok(cl.env.BMX.PredictRollOffset, "the client's drawing hooks exist")
    T.eq(sv.env.BMX.PredictRollOffset, nil, "and the server has none")
end)

T.test("settings: the G30 rows exist, with their defaults", function()
    local sv = F.server()
    local S = sv.env.BMX.Settings
    local p, l, m = S.Get("bmx_predict"), S.Get("bmx_lagcomp"), S.Get("bmx_lagcomp_max")
    T.ok(p and p.scope == "client" and p.default == false, "bmx_predict: client, off")
    T.ok(l and l.scope == "server" and l.default == false, "bmx_lagcomp: server, off")
    T.ok(m and m.scope == "server" and m.default == 0.15 and m.max <= 0.5, "bmx_lagcomp_max: server, 0.15 s")
    T.eq(sv.env.GetConVar("bmx_lagcomp"):GetInt(), 0, "bmx_lagcomp convar is off")
end)
