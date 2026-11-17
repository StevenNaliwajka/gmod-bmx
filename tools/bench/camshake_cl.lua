-- THE CAMERA SHAKE PROBE, client half (sent as data/camshake_cl.txt; RunString). Rides each
-- kind on the open plane (camshake_sv.lua seats it) through four segments: straight at about
-- 250 u/s, a held turn, a slalom (A and D every 0.7 s) and standing still; at full rate and
-- held to 30 fps; bmx_cam_smooth 1 and 0; third person, and first person as the control.
--
-- WHAT IS MEASURED is what a player sees shake: every drawn frame (HUDPaint, after the
-- view is set) the vehicle's centre on screen, and the view's angles and origin. A camera
-- that follows smoothly moves those by about the same amount each frame; a shaking one goes
-- back and forth. So per segment: the SECOND DIFFERENCE of each (this frame's step minus
-- the last one's), its RMS and 99th percentile, and the vehicle's REVERSALS on screen a second
-- (its horizontal or vertical step changing sign with both steps over 0.5 px).
-- data/probe/camshake.txt, "DONE" at the end.
CAMSHAKE_CL = CAMSHAKE_CL or {}
local C = CAMSHAKE_CL
local KINDS = CAMSHAKE_KINDS or { "stock", "cruiser", "dh", "skateboard", "scooter" }
local SEG = { { "straight", 4 }, { "turn", 4 }, { "slalom", 4.2 }, { "still", 3 } }
local SETTLE = 1.2
local OUT = "probe/camshake.txt"
file.CreateDir("probe")
-- on a server: the faked ping the whole probe rides at (CAMSHAKE_LAG ms; sv_cheats 1)
if CAMSHAKE_LAG then RunConsoleCommand("net_fakelag", tostring(CAMSHAKE_LAG)) end
file.Write(OUT, string.format("camshake %s, %s\n", os.date(), game.SinglePlayer() and "singleplayer" or ("server, ping " .. LocalPlayer():Ping())))

-- the plan: per kind, (fps, smooth, firstperson) passes, each the four segments
local PASSES = CAMSHAKE_PASSES or {
    { 0, 1, 0 }, { 0, 0, 0 }, { 30, 1, 0 }, { 30, 0, 0 }, { 0, 1, 1 },
}
local plan = {}
for _, k in ipairs(KINDS) do
    plan[#plan + 1] = { seat = k }
    for _, p in ipairs(PASSES) do
        for _, s in ipairs(SEG) do
            plan[#plan + 1] = { kind = k, fps = p[1], smooth = p[2], fp = p[3], seg = s[1], len = s[2] }
        end
    end
end

local function key(name, down)
    C.keys = C.keys or {}
    if C.keys[name] == down then return end
    C.keys[name] = down
    RunConsoleCommand((down and "+" or "-") .. name)
end
local function allUp() for _, k in ipairs({ "forward", "back", "moveleft", "moveright" }) do key(k, false) end end

-- held to a frame rate the way the camera sweep is: each frame waits out its share
local holdFps = 0
hook.Remove("PostRender", "camshake_hold")
local last = SysTime()
hook.Add("PostRender", "camshake_hold", function()
    if holdFps > 0 then
        local due = last + 1 / holdFps
        while SysTime() < due do end
    end
    last = SysTime()
end)

local function pct(t, q)
    if #t == 0 then return 0 end
    local s = {}
    for i, v in ipairs(t) do s[i] = v end
    table.sort(s)
    return s[math.max(1, math.ceil(#s * q))]
end
local function rms(t)
    if #t == 0 then return 0 end
    local a = 0
    for _, v in ipairs(t) do a = a + v * v end
    return math.sqrt(a / #t)
end

local function report(st)
    local s, rec = st.step, st.rec
    local scr, ang, pos, rev, fts = {}, {}, {}, 0, {}
    for i = 3, #rec do
        local a, b, c = rec[i - 2], rec[i - 1], rec[i]
        if not (a.jump or b.jump or c.jump) then
            local dx1, dy1 = b.sx - a.sx, b.sy - a.sy
            local dx2, dy2 = c.sx - b.sx, c.sy - b.sy
            scr[#scr + 1] = math.sqrt((dx2 - dx1) ^ 2 + (dy2 - dy1) ^ 2)
            if (dx1 * dx2 < 0 and math.abs(dx1) > 0.5 and math.abs(dx2) > 0.5)
                or (dy1 * dy2 < 0 and math.abs(dy1) > 0.5 and math.abs(dy2) > 0.5) then rev = rev + 1 end
            local function d2(f) return math.AngleDifference(math.AngleDifference(c[f], b[f]), math.AngleDifference(b[f], a[f])) end
            ang[#ang + 1] = math.sqrt(d2("p") ^ 2 + d2("y") ^ 2 + d2("r") ^ 2)
            pos[#pos + 1] = ((c.o - b.o) - (b.o - a.o)):Length()
            fts[#fts + 1] = c.ft
        end
    end
    local secs = 0
    for _, f in ipairs(fts) do secs = secs + f end
    file.Append(OUT, string.format(
        "%-10s fps %-3s smooth %d %s %-8s | screen d2 rms %5.2f p99 %6.2f max %6.2f px | reversals %5.1f/s | view ang d2 rms %5.3f p99 %6.3f deg | origin d2 rms %5.2f p99 %6.2f u | frames %d ft %.1f ms | speed %3.0f\n",
        s.kind, s.fps == 0 and "max" or tostring(s.fps), s.smooth, s.fp == 1 and "1st" or "3rd", s.seg,
        rms(scr), pct(scr, 0.99), pct(scr, 1), secs > 0 and rev / secs or 0, rms(ang), pct(ang, 0.99), rms(pos), pct(pos, 0.99),
        #fts, #fts > 0 and secs / #fts * 1000 or 0, st.speed or 0))
end

C.i, C.st = 0, nil
local function nextStep()
    C.i = C.i + 1
    local s = plan[C.i]
    allUp()
    if not s then
        holdFps = 0
        RunConsoleCommand("bmx_cam_smooth", "1") RunConsoleCommand("bmx_cam_first", "0")
        hook.Remove("Think", "camshake") hook.Remove("HUDPaint", "camshake") hook.Remove("PostRender", "camshake_hold")
        RunConsoleCommand("camshake_done")
        if CAMSHAKE_LAG then RunConsoleCommand("net_fakelag", "0") end
        file.Append(OUT, "DONE\n")
        return
    end
    if s.seat then
        RunConsoleCommand("camshake_seat", s.seat)
        C.st = { seatT = RealTime(), step = s }
        return
    end
    holdFps = s.fps
    RunConsoleCommand("bmx_cam_smooth", tostring(s.smooth))
    RunConsoleCommand("bmx_cam_first", tostring(s.fp))
    C.st = { step = s, t0 = RealTime(), rec = {}, speeds = 0, n = 0 }
end

hook.Add("Think", "camshake", function()
    local st = C.st
    if not st then nextStep() return end
    local now = RealTime()
    local s = st.step
    local bike = BMX.LocalBike and BMX.LocalBike(LocalPlayer())
    if s.seat then
        if bike and now - st.seatT > 2.5 then nextStep()
        elseif now - st.seatT > 15 then
            file.Append(OUT, s.seat .. ": never seated\n")
            -- skip this kind's steps
            while plan[C.i + 1] and plan[C.i + 1].kind == s.seat do C.i = C.i + 1 end
            C.st = nil
        end
        return
    end
    if not bike then file.Append(OUT, s.kind .. ": off the vehicle\n") C.st = nil return end
    local t = now - st.t0
    local v = bike:GetVelocity():Length2D()
    if s.seg ~= "still" then
        if v < 230 then key("forward", true) elseif v > 270 then key("forward", false) end
        key("back", false)
    else
        key("forward", false)
        key("back", v > 15)
    end
    if s.seg == "turn" then key("moveleft", true) key("moveright", false)
    elseif s.seg == "slalom" then
        local left = math.floor(t / 0.7) % 2 == 0
        key("moveleft", left) key("moveright", not left)
    else key("moveleft", false) key("moveright", false) end
    if t >= SETTLE then st.speeds, st.n = st.speeds + v, st.n + 1 end
    if t >= s.len + SETTLE then
        st.speed = st.n > 0 and st.speeds / st.n or 0
        report(st)
        C.st = nil
    end
end)

hook.Add("HUDPaint", "camshake", function()
    local st = C.st
    if not st or st.step.seat or RealTime() - st.t0 < SETTLE then return end
    local bike = BMX.LocalBike and BMX.LocalBike(LocalPlayer())
    if not bike then return end
    -- (first person: a point ahead of the vehicle, the centre being behind the eye)
    local at = bike:WorldSpaceCenter()
    if st.step.fp == 1 then at = at + bike:GetForward() * 300 end
    local sp = at:ToScreen()
    local a, o = EyeAngles(), EyePos()
    local prev = st.rec[#st.rec]
    st.rec[#st.rec + 1] = { sx = sp.x, sy = sp.y, p = a.p, y = a.y, r = a.r, o = o, ft = FrameTime(),
        jump = prev and (o - prev.o):Length() > 200 or false }
end)
print("[camshake] client half running, " .. #plan .. " steps")
