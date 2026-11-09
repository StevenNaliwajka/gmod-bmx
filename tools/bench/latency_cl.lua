-- THE LATENCY TABLE, ridden (tools/bench/netdemo.sh). Sent to a real client connected to a
-- real server (RunString of data/latency_cl.txt), already seated on a stock bike on open
-- ground. For each row of LAT_ROWS ({ net_fakelag, bmx_predict }): set them, ride straight at
-- about 270 u/s, run `bmx_latency_probe` and tap D (the keyboard's +moveright, so the probe
-- reads exactly what a key sends) every 2.5 s until it reports. Each report goes to
-- data/probe/latency.txt; "DONE" when every row is in. docs/TUNING.md has the method.
LAT = LAT or {}
local L = LAT
local P = BMX.Predict
local ROWS = LAT_ROWS or { { 0, 0 }, { 0, 1 }, { 50, 0 }, { 50, 1 }, { 100, 0 }, { 100, 1 }, { 150, 0 }, { 150, 1 } }
local TRIALS = LAT_TRIALS or 8
local OUT = "probe/latency.txt"
file.CreateDir("probe")
file.Write(OUT, "")

-- the probe's own report, kept: both columns, as the table has them
L.report = L.report or P.ProbeReport
P.ProbeReport = function(...)
    local pr, shown = P.probe, P.probeShown
    local a, b = pr and P.Summary(pr.results), shown and P.Summary(shown.results)
    local row = ROWS[L.i] or { -1, -1 }
    local function f(s) return s and string.format("median %.0f min %.0f max %.0f n %d", s.median, s.min, s.max, s.n) or "none" end
    file.Append(OUT, string.format("net_fakelag %d bmx_predict %d ping %d | networked %s | drawn %s\n",
        row[1], row[2], LocalPlayer():Ping(), f(a), f(b)))
    L.phase, L.t = "next", RealTime()
    return L.report(...)
end

local function key(name, down)
    if L[name] == down then return end
    L[name] = down
    RunConsoleCommand((down and "+" or "-") .. name)
end

L.i, L.phase, L.t = 0, "next", RealTime()
hook.Add("Think", "bmx_latdemo", function()
    local ply = LocalPlayer()
    local bike = BMX.LocalBike and BMX.LocalBike(ply)
    local now = RealTime()
    -- the speed: W while under 260 u/s, off over 280
    if IsValid(bike) then
        local v = bike:GetVelocity():Length()
        if v < 260 then key("forward", true) elseif v > 280 then key("forward", false) end
    end
    if L.phase == "next" then
        key("moveright", false)
        L.i = L.i + 1
        local row = ROWS[L.i]
        if not row then
            key("forward", false)
            hook.Remove("Think", "bmx_latdemo")
            RunConsoleCommand("net_fakelag", "0")
            P.ProbeReport = L.report
            file.Append(OUT, "DONE\n")
            return
        end
        RunConsoleCommand("net_fakelag", tostring(row[1]))
        RunConsoleCommand("bmx_predict", tostring(row[2]))
        L.phase, L.t = "settle", now
    elseif L.phase == "settle" and now - L.t > 4 then
        RunConsoleCommand("bmx_latency_probe", tostring(TRIALS))
        L.phase, L.t, L.tap = "probe", now, now + 1.5
    elseif L.phase == "probe" then
        -- a tap: D down 0.15 s, then up, every 2.5 s
        if now >= L.tap then key("moveright", true) L.tap = now + 2.5 L.up = now + 0.15 end
        if L.up and now >= L.up then key("moveright", false) L.up = nil end
        if now - L.t > TRIALS * 2.5 + 20 then           -- a probe that never finished
            file.Append(OUT, string.format("net_fakelag %d bmx_predict %d: timed out\n", ROWS[L.i][1], ROWS[L.i][2]))
            P.probe, P.probeShown = nil, nil
            L.phase = "next"
        end
    end
end)
