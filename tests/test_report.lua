--[[--------------------------------------------------------------------------
    bmx_report (G08): the paste-able bug-report block, and the issue templates
    it is written for.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local gmod = require("lib.gmod")

local function client()
    local sv, world = F.server()
    local cl = F.client(world)
    return cl, sv, world
end

T.test("report: every field is there", function()
    local cl = client()
    local E = cl.env
    cl.localPlayer = cl:player("Human")
    local r = E.BMX.BuildReport()
    for _, field in ipairs({ "version:", "map:", "gamemode:", "mode:", "tickrate:", "bike:",
            "settings changed from default:", "last client [BMX] console lines" }) do
        T.ok(r:find(field, 1, true), "has " .. field)
    end
    T.ok(r:find(E.BMX.Version, 1, true), "the real version")
    T.ok(r:find("gm_flatgrass", 1, true), "the map")
    T.ok(r:find("tickrate:  66", 1, true), "the tick rate, from the engine")
    T.ok(r:find("not on a bike", 1, true), "no bike when on foot")
end)

T.test("report: the bike you are riding is named", function()
    local sv, world = F.server()
    local bike = F.bike(sv)
    F.rider(sv, bike, { name = "Human" })
    local cl = F.client(world)
    local E = cl.env
    local cb = cl:clientEntity("bmx_base")
    local pod = cl.makeEntity("prop_vehicle_prisoner_pod")
    pod:SetParent(cb)
    cb:SetPod(pod)
    local me = cl:player("Human")
    me._vehicle = pod
    cl.localPlayer = me
    T.ok(E.BMX.BuildReport():find("bike:      stock (bmx_base)", 1, true), "stock (bmx_base)")
end)

T.test("report: only settings that differ from default are listed, with the default", function()
    local cl = client()
    local E = cl.env
    local before = E.BMX.BuildReport()
    T.ok(not before:find("bmx_grip", 1, true), "defaults are not listed")
    E.GetConVar("bmx_grip"):SetString("2.5")
    E.GetConVar("bmx_vol_wind"):SetString("0.25")
    local r = E.BMX.BuildReport()
    T.ok(r:find("bmx_grip 2.5 (default ", 1, true), "a tuning convar, with its default")
    T.ok(r:find("bmx_vol_wind 0.25 (default 1)", 1, true), "a client setting")
    E.GetConVar("bmx_vol_wind"):SetString("1.0")
    T.ok(not E.BMX.BuildReport():find("bmx_vol_wind", 1, true), "1.0 is the default 1, not a change")
end)

T.test("report: the last 20 [BMX] console lines, and only those", function()
    local cl = client()
    local E = cl.env
    for i = 1, 30 do E.MsgN("[BMX] line ", i) end
    E.MsgN("some other addon's chatter")
    E.ErrorNoHalt("[BMX] an error\n")
    local r = E.BMX.BuildReport()
    T.ok(not r:find("chatter", 1, true), "other addons' lines are not ours")
    T.ok(r:find("[BMX] an error", 1, true), "ErrorNoHalt lines are kept")
    T.ok(r:find("[BMX] line 30", 1, true), "the newest")
    T.ok(not r:find("[BMX] line 10\n", 1, true), "old ones fall off")
    local n = 0
    local inLog = false
    for l in (r .. "\n"):gmatch("[^\n]*") do
        if l:find("last client", 1, true) then inLog = true
        elseif inLog and l:find("%[BMX%]") then n = n + 1 end
    end
    T.eq(n, 20, "exactly twenty")
end)

T.test("report: under 4 KB, even when everything is long", function()
    local cl = client()
    local E = cl.env
    local long = string.rep("x", 400)
    for i = 1, 40 do E.MsgN("[BMX] ", long) end
    for _, row in ipairs(E.BMX.Config.ConVars) do E.GetConVar(row[1]):SetString("123456") end
    local r = E.BMX.BuildReport()
    T.ok(#r < 4096, "report is " .. #r .. " bytes")
    T.ok(#r <= E.BMX.ReportMaxBytes, "and within its own cap")
    T.ok(r:find("version:", 1, true) and r:find("=== end ===", 1, true), "header and footer intact")

    -- Squeeze: the console goes first, then the settings, never the header.
    E.BMX.ReportMaxBytes = 500
    local small = E.BMX.BuildReport()
    T.ok(#small <= 500, "squeezed to " .. #small)
    T.ok(small:find("version:", 1, true) and small:find("map:", 1, true), "header kept")
end)

T.test("report: the command prints the block and copies it", function()
    local cl = client()
    local E = cl.env
    local copied
    E.SetClipboardText = function(t) copied = t end
    cl:command("bmx_report", cl.localPlayer)
    T.ok(copied and copied:find("=== BMX report ===", 1, true), "on the clipboard")
    local printed = false
    for _, l in ipairs(cl.log) do if l:find("=== BMX report ===", 1, true) then printed = true end end
    T.ok(printed, "and in the console")
end)

-- ----------------------------------------------------------- the templates

local function read(rel)
    local f = io.open(gmod.ROOT .. "/" .. rel, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

T.test("issue templates: bug, feel and suggestion exist and are shaped like GitHub forms", function()
    for _, name in ipairs({ "bug", "feel", "suggestion" }) do
        local s = read(".github/ISSUE_TEMPLATE/" .. name .. ".yml")
        T.ok(s, name .. ".yml exists")
        T.ok(s:match("^name: ") and s:find("\ndescription: ", 1, true) and s:find("\nbody:\n", 1, true),
            name .. ".yml has name, description and body")
        T.ok(not s:find("\t"), name .. ".yml has no tabs (YAML forbids them)")
        T.ok(s:find("type: textarea", 1, true), name .. ".yml asks for something")
    end
    local bug = read(".github/ISSUE_TEMPLATE/bug.yml")
    for _, want in ipairs({ "Which bike?", "All bikes", "Map and gamemode", "Singleplayer",
            "branch", "Console errors", "bmx_report", "bmx_dump_config" }) do
        T.ok(bug:find(want, 1, true), "the bug form asks for " .. want)
    end
    T.ok(read(".github/ISSUE_TEMPLATE/feel.yml"):find("video", 1, true) or
         read(".github/ISSUE_TEMPLATE/feel.yml"):find("Video", 1, true), "the feel form asks for a video")
end)
