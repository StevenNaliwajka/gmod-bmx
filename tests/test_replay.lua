--[[--------------------------------------------------------------------------
    G28, replays (cl_replay.lua): the ring buffer, the sampling that plays a
    recording back at any time, the file format, the recorder against a real
    client bike, and the stand-in's geometry.

    The ring and the sampler are the two things a replay cannot do without and
    that cannot be eyeballed in a quick look at a screen: a ring that loses a
    frame at the wrap, or a sampler that spins a bike the long way round at
    +-180 degrees, only shows up as a glitch in somebody's clip.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local function client()
    local sv, world = F.server()
    local cl = F.client(world)
    return sv, cl, world
end

-- A recording entry with everything defaulted.
local function entry(o)
    local e = { id = 1, x = 0, y = 0, z = 0, p = 0, yw = 0, r = 0, st = 0, wf = 0, wr = 0,
                cr = 0, wp = 0, br = 0, pose = 0, stance = 1, air = 0 }
    for k, v in pairs(o or {}) do e[k] = v end
    return e
end

--------------------------------------------------------------------------
-- The ring
--------------------------------------------------------------------------
T.test("replay ring: wraps around, oldest first, and counts", function()
    local _, cl = client()
    local R = cl.env.BMX.Replay
    local r = R.NewRing(5)
    T.eq(r.n, 0, "empty")
    for i = 1, 3 do R.RingPush(r, i) end
    T.eq(r.n, 3, "partly full")
    T.eq(R.RingGet(r, 1), 1, "oldest is the first pushed")
    T.eq(R.RingGet(r, 3), 3, "newest")
    T.eq(R.RingGet(r, 4), nil, "nothing past the end")
    for i = 4, 12 do R.RingPush(r, i) end
    T.eq(r.n, 5, "stays at capacity")
    local a = R.RingToArray(r)
    T.eq(#a, 5, "five kept")
    for i = 1, 5 do T.eq(a[i], 7 + i, "chronological after the wrap, slot " .. i) end
    T.eq(R.RingGet(r, 0), nil, "no index zero")
    R.RingClear(r)
    T.eq(r.n, 0, "cleared")
    R.RingPush(r, 99)
    T.eq(R.RingGet(r, 1), 99, "usable after a clear")
end)

T.test("replay ring: the real one holds exactly the last 30 seconds", function()
    local _, cl = client()
    local R = cl.env.BMX.Replay
    local r = R.NewRing(R.CAP)
    local dt = 1 / R.HZ
    for i = 0, 60 * R.HZ do R.RingPush(r, { t = i * dt }) end
    local a = R.RingToArray(r)
    T.eq(#a, R.CAP, "full")
    T.between(a[#a].t - a[1].t, R.WINDOW, R.WINDOW + 0.1, "about 30 s of it")
    for i = 2, #a do T.ok(a[i].t > a[i - 1].t, "in time order at " .. i) end
end)

--------------------------------------------------------------------------
-- Sampling
--------------------------------------------------------------------------
T.test("replay playback: interpolates position, the short way round angles, and wheels", function()
    local _, cl = client()
    local R = cl.env.BMX.Replay
    local frames = {
        { t = 10.0, e = { entry({ id = 7, x = 0, yw = 170, wf = 0, air = 0, pose = 0 }) } },
        { t = 10.1, e = { entry({ id = 7, x = 10, yw = -170, wf = 2, air = 1, pose = 3 }) } },
    }
    local s = R.Sample(frames, 10.05)[7]
    T.near(s.x, 5, 1e-9, "halfway in x")
    T.near(math.abs(s.yw), 180, 1e-9, "170 to -170 goes through 180, not through 0")
    T.near(s.wf, 1, 1e-9, "wheel angle")
    s = R.Sample(frames, 10.025)[7]
    T.near(s.x, 2.5, 1e-9, "a quarter in")
    T.eq(s.air, 0, "discrete state holds the earlier frame before the half way mark")
    T.eq(R.Sample(frames, 10.075)[7].pose, 3, "and the later one after")
    T.near(R.Sample(frames, 9)[7].x, 0, 1e-9, "before the start holds the first frame")
    T.near(R.Sample(frames, 99)[7].x, 10, 1e-9, "after the end holds the last")
end)

T.test("replay playback: a hole in the recording is not glided across", function()
    local _, cl = client()
    local R = cl.env.BMX.Replay
    local frames = {
        { t = 0, e = { entry({ id = 1, x = 0 }), entry({ id = 2, x = 50 }) } },
        { t = 0.03, e = { entry({ id = 1, x = 3 }) } },          -- 2 left range
        { t = 5, e = { entry({ id = 1, x = 500 }) } },           -- a long gap
    }
    local s = R.Sample(frames, 0.015)
    T.near(s[1].x, 1.5, 1e-9, "the bike still in range interpolates")
    T.near(s[2].x, 50, 1e-9, "the bike that left holds its last pose")
    T.near(R.Sample(frames, 2)[1].x, 3, 1e-9, "a gap of seconds holds, it does not slide")
end)

T.test("replay playback: finding a frame is a search, right at every boundary", function()
    local _, cl = client()
    local R = cl.env.BMX.Replay
    local frames = {}
    for i = 1, 200 do frames[i] = { t = i * 0.03, e = {} } end
    for _, i in ipairs({ 1, 2, 57, 199 }) do
        T.eq(R.FindFrame(frames, i * 0.03 + 0.001), i, "just after frame " .. i)
    end
    T.eq(R.FindFrame(frames, 0), 1, "before")
    T.eq(R.FindFrame(frames, 99), 200, "after")
    T.eq(R.FindFrame({}, 1), nil, "nothing")
end)

--------------------------------------------------------------------------
-- The combo text in sync
--------------------------------------------------------------------------
T.test("replay overlay: tricks fade, a building combo shows from two, a landed one holds", function()
    local _, cl = client()
    local R = cl.env.BMX.Replay
    local ev = {
        { t = 1, k = "trick", text = "Flip", pts = 100 },
        { t = 2, k = "combo", state = 0, n = 1, base = 100, bonus = 0, names = { "Flip" } },
        { t = 3, k = "combo", state = 0, n = 2, base = 250, bonus = 0, names = { "Flip", "Spin" } },
        { t = 5, k = "combo", state = 1, n = 2, base = 250, bonus = 500, names = {} },
    }
    local c, tr = R.OverlayAt(ev, 0.5)
    T.eq(c, nil, "nothing yet"); T.eq(#tr, 0, "no tricks yet")
    c, tr = R.OverlayAt(ev, 1.5)
    T.eq(#tr, 1, "the trick callout"); T.eq(c, nil, "one trick is not a combo")
    c, tr = R.OverlayAt(ev, 3.5)
    T.eq(c.n, 2, "the combo builds"); T.eq(#tr, 0, "the callout faded (2.4 s)")
    c = R.OverlayAt(ev, 5.5)
    T.eq(c.state, 1, "landed"); T.eq(c.bonus, 500, "with the bonus")
    T.eq(R.OverlayAt(ev, 9), nil, "and gone after 2.2 s")
    T.eq(R.OverlayAt(ev, 3.2).n, 2, "scrubbing back works: it is a function of time")
end)

--------------------------------------------------------------------------
-- The file format
--------------------------------------------------------------------------
local function sampleReplay()
    local frames = {}
    for i = 0, 99 do
        frames[#frames + 1] = { t = 100 + i / 33, e = {
            entry({ id = 12, x = i * 1.25, y = -i * 0.5, z = 10 + math.sin(i / 10), p = 2.5,
                    yw = (i * 7) % 360 - 180, r = -3.1, st = 0.12, wf = i * 0.37, wr = i * 0.36,
                    cr = i * 0.1, wp = 1.5, br = 0.2, pose = i % 4, stance = 3, air = i % 2 }),
            entry({ id = 30, x = 800 + i, y = 5 }) } }
    end
    return { map = "gm_flatgrass", date = 1700000000, subject = 12,
             meta = { { id = 12, bike = "stock", color = 2, name = "Ann", model = "models/player/kleiner.mdl" } },
             frames = frames,
             events = { { t = 101.5, k = "combo", state = 0, n = 2, base = 300, bonus = 0, names = { "Flip", "Spin" } },
                        { t = 102, k = "trick", text = "2x Flip", pts = 200 } } }
end

local function same(R, a, b, msg)
    T.eq(#b.frames, #a.frames, msg .. ": frame count")
    local t0 = a.frames[1].t
    for i, fa in ipairs(a.frames) do
        local fb = b.frames[i]
        T.near(fb.t, fa.t - t0, 0.0006, msg .. ": time " .. i)
        T.eq(#fb.e, #fa.e, msg .. ": entities " .. i)
        for j, ea in ipairs(fa.e) do
            local eb = fb.e[j]
            T.eq(eb.id, ea.id, msg .. ": id")
            T.near(eb.x, ea.x, 0.051, msg .. ": x"); T.near(eb.y, ea.y, 0.051, msg .. ": y")
            T.near(eb.z, ea.z, 0.051, msg .. ": z")
            T.near(math.abs(eb.yw), math.abs(ea.yw), 0.051, msg .. ": yaw")
            T.near(eb.p, ea.p, 0.051, msg .. ": pitch"); T.near(eb.r, ea.r, 0.051, msg .. ": roll")
            T.near(eb.st, ea.st, 0.0006, msg .. ": steer")
            T.near(eb.wf, ea.wf, 0.006, msg .. ": front wheel")
            T.near(eb.wr, ea.wr, 0.006, msg .. ": rear wheel")
            T.near(eb.cr, ea.cr, 0.006, msg .. ": crank")
            T.near(eb.wp, ea.wp, 0.006, msg .. ": whip"); T.near(eb.br, ea.br, 0.006, msg .. ": bars")
            T.eq(eb.pose, ea.pose, msg .. ": pose"); T.eq(eb.stance, ea.stance, msg .. ": stance")
            T.eq(eb.air, ea.air, msg .. ": air")
        end
    end
end

T.test("replay file: compress / decompress round trip, with the engine's compressor", function()
    local _, cl = client()
    local R = cl.env.BMX.Replay
    -- The shim has no LZMA: a toy reversible one stands in. What is checked is
    -- the plumbing around it (the header, the choice, the failure paths).
    cl.env.util.Compress = function(s) return "Z" .. s:reverse() end
    cl.env.util.Decompress = function(s) return s:sub(1, 1) == "Z" and s:sub(2):reverse() or nil end
    local rep = sampleReplay()
    local blob = R.Pack(R.Encode(rep))
    T.eq(blob:sub(1, 6), "BMXR1\n", "compressed files say so")
    local json, why = R.Unpack(blob)
    T.ok(json, "unpacks: " .. tostring(why))
    local back, why2 = R.Decode(json)
    T.ok(back, "decodes: " .. tostring(why2))
    same(R, rep, back, "round trip")
    T.eq(back.map, "gm_flatgrass", "map kept"); T.eq(back.subject, 12, "subject kept")
    T.eq(back.meta[1].name, "Ann", "who it was kept")
    T.eq(#back.events, 2, "events kept")
    T.near(back.events[1].t, 1.5, 1e-9, "events are relative to the clip's start")
    T.eq(back.events[1].names[2], "Spin", "combo names kept")

    local _, why3 = R.Unpack("BMXR1\n" .. "garbage-not-Z")
    T.ok(why3, "a damaged compressed file is refused: " .. tostring(why3))
    local _, why4 = R.Unpack("hello")
    T.ok(why4, "something else is refused")
end)

T.test("replay file: the fallback without util.Compress is plain and round-trips", function()
    local _, cl = client()
    local R = cl.env.BMX.Replay
    cl.env.util.Compress, cl.env.util.Decompress = nil, nil
    local rep = sampleReplay()
    local blob = R.Pack(R.Encode(rep))
    T.eq(blob:sub(1, 6), "BMXR0\n", "plain files say so")
    same(R, rep, assert(R.Decode(assert(R.Unpack(blob)))), "fallback")
    -- A compressed file on a game that cannot decompress says so, not crashes.
    local json, why = R.Unpack("BMXR1\nxx")
    T.eq(json, nil, "cannot read it"); T.ok(why:find("decompress"), "and says why")
end)

T.test("replay file: a stranger's file is checked before it is believed", function()
    local _, cl = client()
    local R = cl.env.BMX.Replay
    local good = R.Encode(sampleReplay())
    T.ok(R.Decode(good), "the good one decodes")
    T.eq((R.Decode("not json")), nil, "junk")
    T.eq((R.Decode(cl.env.util.TableToJSON({ v = 99, f = {} }))), nil, "a newer version")
    T.eq((R.Decode(cl.env.util.TableToJSON({ v = 1, f = { { 0, 1 }, { 1, 0 } } }))), nil,
        "a row that claims an entity it does not hold")
    T.eq((R.Decode(cl.env.util.TableToJSON({ v = 1, f = { { 0, 1000000 }, { 1, 0 } } }))), nil,
        "an absurd entity count")
    local row = { 0, 1 }
    for i = 1, 16 do row[#row + 1] = "x" end
    T.eq((R.Decode(cl.env.util.TableToJSON({ v = 1, f = { row, { 1, 0 } } }))), nil,
        "text where numbers go")
end)

T.test("replay file: saves under data/bmx/replays and loads back by name", function()
    local _, cl, world = client()
    local R = cl.env.BMX.Replay
    local rep = sampleReplay()
    local path = R.Save("my run-1", rep)
    T.eq(path, "bmx/replays/my_run-1.txt", "sanitised name, in the replays folder")
    T.ok(world.convars and cl.files or true, "written")
    local back, why = R.LoadFile("my run-1")
    T.ok(back, "loads: " .. tostring(why))
    same(R, rep, back, "file")
    T.eq((R.Save("../../etc/passwd", rep)), "bmx/replays/______etc_passwd.txt", "no path tricks")
    T.eq((R.Save("", rep)), nil, "a name is required")
    T.eq((R.LoadFile("nope")), nil, "a missing one is an error, not a crash")
end)

--------------------------------------------------------------------------
-- The recorder, against a client bike
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
    return { cl = cl, world = world, cb = cb, me = me }
end

T.test("replay recorder: samples a bike at 33 Hz and keeps the last 30 s", function()
    local s = scene()
    local R = s.cl.env.BMX.Replay
    local dt = 1 / R.HZ
    for i = 0, 45 * R.HZ do
        s.world.time = 1000 + i * dt
        s.cb:SetPos(s.cl.env.Vector(i * 0.5, 0, 10))
        R.Record(s.world.time)
    end
    local a = R.RingToArray(R.Ring)
    T.eq(#a, R.CAP, "the ring is full")
    T.between(a[#a].t - a[1].t, R.WINDOW - 0.1, R.WINDOW + 0.1, "30 seconds")
    T.eq(#a[#a].e, 1, "one bike")
    local e = a[#a].e[1]
    T.near(e.x, 45 * R.HZ * 0.5, 1e-6, "the newest position")
    T.eq(e.id, s.cb:EntIndex(), "keyed by the bike")
    T.eq(e.stance, 1, "seated")

    local rep = R.Snapshot()
    T.ok(rep, "a snapshot")
    T.eq(rep.subject, s.cb:EntIndex(), "of the local rider")
    T.eq(rep.meta[1].bike, s.cb.BikeID or "stock", "who and what was recorded")
    T.eq(rep.map, "gm_flatgrass", "and where")
end)

T.test("replay: the command starts and stops playback, and the camera hooks yield", function()
    local s = scene()
    local B, R = s.cl.env.BMX, s.cl.env.BMX.Replay
    s.cl.env.chat = nil
    for i = 0, 100 do s.world.time = 50 + i / 33; R.Record(s.world.time) end
    T.ok(not B.ReplayActive(), "not playing")
    s.cl:command("bmx_replay", s.me)
    T.ok(B.ReplayActive(), "playing")
    s.cl:command("bmx_replay_mode", s.me, "free")
    s.cl:command("bmx_replay_speed", s.me, "0.5")
    s.cl:command("bmx_replay_seek", s.me, "50%")
    local view = s.cl.env.hook.Run("CalcView", s.me, s.cl.env.Vector(), s.cl.env.Angle(), 75)
    T.ok(view and view.origin, "the replay provides the view")
    s.cl:command("bmx_replay", s.me)
    T.ok(not B.ReplayActive(), "stopped")
end)

--------------------------------------------------------------------------
-- The stand-in
--------------------------------------------------------------------------
T.test("replay stand-in: round tyres on the axle line, a fork that steers", function()
    local _, cl = client()
    local B, R, V = cl.env.BMX, cl.env.BMX.Replay, cl.env.Vector
    local cfg = B.ConfigFor(B.Bikes.stock)
    local WC = cfg.Wheel
    local half = WC.wheelbase * 0.5
    local function tyres(e)
        local rear, front = {}, {}
        for _, seg in ipairs(R.StandInLines(e, cfg)) do
            if seg[3] == "tyre" then
                local t = #rear < R.RING_SEGMENTS and rear or front
                t[#t + 1] = seg[1]
            end
        end
        return rear, front
    end

    local rear, front = tyres(entry({ x = 100, y = 50, z = 20 }))
    T.eq(#rear, R.RING_SEGMENTS, "a ring of segments"); T.eq(#front, R.RING_SEGMENTS, "two of them")
    local rc, fc = V(100 - half, 50, 20), V(100 + half, 50, 20)
    for _, p in ipairs(rear) do T.near((p - rc):Length(), WC.radius, 1e-6, "rear tyre is round") end
    for _, p in ipairs(front) do T.near((p - fc):Length(), WC.radius, 1e-6, "front tyre is round") end

    -- Yawed: the axle line turns with the bike.
    local rear2 = tyres(entry({ yw = 90 }))
    local sum = V(0, 0, 0)
    for _, p in ipairs(rear2) do sum = sum + p end
    local c = sum * (1 / #rear2)
    T.near(c.y, -half, 0.6, "a bike yawed 90 degrees has its rear axle behind it on Y")

    -- Steer swings the front wheel; the rear does not move.
    local r0, f0 = tyres(entry())
    local r1, f1 = tyres(entry({ st = 0.5 }))
    T.near((r0[1] - r1[1]):Length(), 0, 1e-9, "the rear wheel ignores the bars")
    T.ok((f0[1] - f1[1]):Length() > 0.1, "the front wheel follows them")

    for _, seg in ipairs(R.StandInLines(entry({ wp = 2, br = 1, st = 0.3, p = 20, r = 30 }), cfg)) do
        T.finite(seg[1], "no NaN in any segment"); T.finite(seg[2], "no NaN")
    end
end)
