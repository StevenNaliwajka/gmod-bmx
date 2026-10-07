--[[--------------------------------------------------------------------------
    bmx_report   (client console command)

    A ready-to-paste block for a bug report: type it in the console, paste into
    the issue (see .github/ISSUE_TEMPLATE). It carries what we would otherwise
    have to ask for, in the order we would ask:

        version, map, gamemode, singleplayer or multiplayer, tick rate,
        the bike you are on, every setting that is NOT at its default, and the
        last 20 [BMX] console lines.

    It is also copied to the clipboard, so the report is one paste.

    SIZE. Under 4 KB, always (BMX.ReportMaxBytes). A GitHub issue field and a
    chat message both take that happily, and a report that is "too long to
    paste" is one nobody sends. When it would be longer, the OLDEST console lines
    go first, then the settings list is cut -- the header is never cut.

    WHY WE BUFFER THE CONSOLE OURSELVES. GMod has no "read the console back"
    call. So MsgN and ErrorNoHalt are wrapped, once, to remember any line that
    starts with "[BMX]" before passing it on unchanged. Only lines printed after
    this file loads are seen, which is every line the addon prints at run time;
    it is the Lua errors and warnings that matter, and those are all [BMX]
    prefixed on purpose. This is the client's console: a SERVER-side error is in
    the server's console, and the report says so.

    NOTHING HERE MAY THROW. Every lookup that depends on the engine is guarded,
    because a report command that errors is the one tool you cannot then use to
    report the error.
----------------------------------------------------------------------------]]

BMX = BMX or {}
if not CLIENT then return end

BMX.ReportMaxBytes = 4000
BMX.ReportLogLines = 20
local LINE_CAP     = 160     -- chars kept of any one console line

--------------------------------------------------------------------------
-- The console buffer.
--------------------------------------------------------------------------
local ring = {}

function BMX.ReportRemember(line)
    line = tostring(line)
    if line:sub(1, 5) ~= "[BMX]" then return end
    line = line:gsub("[\r\n]+$", "")
    if #line > LINE_CAP then line = line:sub(1, LINE_CAP - 3) .. "..." end
    ring[#ring + 1] = line
    if #ring > BMX.ReportLogLines then table.remove(ring, 1) end
end

local function wrap(name)
    local G = getfenv(1)       -- the global table; spelled this way so a test sandbox is wrapped, not the host
    local orig = G[name]
    if type(orig) ~= "function" then return end
    G[name] = function(...)
        -- MsgN joins its arguments with nothing between them; so do we.
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        BMX.ReportRemember(table.concat(parts))
        return orig(...)
    end
end
-- Once: a reload must not wrap the wrapper.
if not BMX.ReportWrapped then
    BMX.ReportWrapped = true
    wrap("MsgN")
    wrap("ErrorNoHalt")
end

-- The addon's own load line was printed before this file existed; put it in.
if BMX.Version then ring[#ring + 1] = "[BMX] " .. BMX.Version .. " loaded (client)" end

--------------------------------------------------------------------------
-- Settings that differ from their default.
--
-- The tuning convars (BMX.Config.ConVars) carry their defaults with them; the
-- rest are listed here with theirs. A convar the client cannot see (a server
-- one that is not replicated) is simply not listed: the report says what the
-- CLIENT knows.
--------------------------------------------------------------------------
local EXTRA = {
    { "bmx_scoring", "1" }, { "bmx_combos", "1" }, { "bmx_max_per_player", "0" },
    { "bmx_air_assist", "1" }, { "bmx_nose_manual", "0" },
    { "bmx_crash_ragdoll", "1" }, { "bmx_ragmod", "1" },
    { "bmx_bell", "1" }, { "bmx_bell_cooldown", "0.3" },
    { "bmx_water", "1" }, { "bmx_water_eject", "1" }, { "bmx_sounds", "1" },
    { "bmx_vol_ride", "1" }, { "bmx_vol_wind", "1" }, { "bmx_vol_bell", "1" },
    { "bmx_hud", "1" }, { "bmx_units", "kmh" }, { "bmx_stick_deadzone", "0.1" },
    { "bmx_cam_dist", "115" },
}

local function same(a, b)
    local na, nb = tonumber(a), tonumber(b)
    if na and nb then return math.abs(na - nb) < 1e-6 end
    return tostring(a) == tostring(b)
end

function BMX.ReportDiff()
    local rows = {}
    for _, r in ipairs(BMX.Config.ConVars or {}) do rows[#rows + 1] = { r[1], r[2] } end
    for _, r in ipairs(EXTRA) do rows[#rows + 1] = r end

    local out = {}
    for _, r in ipairs(rows) do
        local cv = GetConVar(r[1])
        if cv then
            local now = cv:GetString()
            if not same(now, r[2]) then
                out[#out + 1] = string.format("%s %s (default %s)", r[1], now, tostring(r[2]))
            end
        end
    end
    return out
end

--------------------------------------------------------------------------
-- The report.
--------------------------------------------------------------------------
local function safe(fn, default)
    local ok, v = pcall(fn)
    if ok and v ~= nil then return v end
    return default
end

local function bikeLine()
    local ply = LocalPlayer and LocalPlayer()
    if not IsValid(ply) then return "no player" end
    local bike = BMX.LocalBike and BMX.LocalBike(ply)
    if not IsValid(bike) then return "not on a bike" end
    return string.format("%s (%s)", tostring(bike.BikeID or "?"), bike:GetClass())
end

function BMX.BuildReport()
    local tick = safe(function() return math.floor(1 / engine.TickInterval() + 0.5) end, "?")
    local sp = safe(function() return game.SinglePlayer() and "singleplayer" or "multiplayer" end, "?")
    local head = {
        "=== BMX report ===",
        "version:   " .. tostring(BMX.Version),
        "map:       " .. tostring(safe(function() return game.GetMap() end, "?")),
        "gamemode:  " .. tostring(safe(function() return engine.ActiveGamemode() end, "?")),
        "mode:      " .. sp,
        "tickrate:  " .. tostring(tick),
        "bike:      " .. safe(bikeLine, "?"),
    }

    local diff = safe(BMX.ReportDiff, {})
    local log  = {}
    for i, l in ipairs(ring) do log[i] = l end

    local function build()
        local t = {}
        for _, l in ipairs(head) do t[#t + 1] = l end
        t[#t + 1] = "settings changed from default:" .. (#diff == 0 and " none" or "")
        for _, l in ipairs(diff) do t[#t + 1] = "  " .. l end
        t[#t + 1] = "last client [BMX] console lines (server errors are in the server console):"
        if #log == 0 then t[#t + 1] = "  (none)" end
        for _, l in ipairs(log) do t[#t + 1] = "  " .. l end
        t[#t + 1] = "=== end ==="
        return table.concat(t, "\n")
    end

    local text = build()
    -- Over budget: oldest console lines first, then the settings list.
    while #text > BMX.ReportMaxBytes and #log > 0 do table.remove(log, 1); text = build() end
    while #text > BMX.ReportMaxBytes and #diff > 0 do table.remove(diff); text = build() end
    return text
end

concommand.Add("bmx_report", function()
    local text = BMX.BuildReport()
    print(text)
    if SetClipboardText then SetClipboardText(text) end
    print("[BMX] report copied to the clipboard (" .. #text .. " bytes). Paste it into your issue.")
end)
