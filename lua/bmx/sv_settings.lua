--[[--------------------------------------------------------------------------
    bmx/sv_settings.lua

    Changing the server's settings from the menu, and keeping them.

      bmx_setting (net, client -> server)   one change: set, reset one, reset all
      bmx_reset_server                      every server setting back to default
      data/bmx/server.json                  the saved values, loaded at boot

    THE MENU DOES NOT SET CONVARS. A client cannot set a server convar, and a
    server that let it would let anyone. The panel sends a net message, and
    this file asks BMX.Can (sh_permissions.lua, so CAMI) before touching
    anything. A refusal is said to the player in chat and changes nothing.

    EVERY CHANGE IS RE-VALIDATED HERE. The panel has sliders with ranges, but a
    net message is whatever a client chooses to send; BMX.Settings.Coerce
    clamps numbers into the row's range and rejects anything the row does not
    accept, and a name that is not a SERVER row in the settings table is
    refused outright, so this cannot be used to set an arbitrary convar.

    PERSISTENCE. The values are written to data/bmx/server.json whenever one
    changes, by ANY route: the menu, the console, an rcon, another admin mod.
    That is a convar change callback with a short debounce, so a slider drag is
    one write and not fifty. At boot the file is read back and applied. The
    engine already archives these convars in its own cfg, but only when the
    server shuts down cleanly and only if the cfg is the one that is read; this
    file is the one that always is. Values it does not mention keep what the
    engine has.

    THE FILE is a flat JSON object of name -> value, readable and editable by a
    server owner. Unknown names are ignored, bad values are clamped or skipped,
    and a file that does not parse is left alone and reported, not overwritten
    until something changes.
----------------------------------------------------------------------------]]

BMX = BMX or {}
local S = BMX.Settings

S.ServerFile = "bmx/server.json"

util.AddNetworkString("bmx_setting")

local function say(ply, msg)
    msg = "[BMX] " .. msg
    if IsValid(ply) then ply:ChatPrint(msg) else print(msg) end
end

local function setConVar(row, value)
    local cv = GetConVar(row.name)
    if not cv then return false end
    cv:SetString(S.ToConVar(row, value))
    return true
end

--------------------------------------------------------------------------
-- One request, from a player or the console. Returns ok, message. THE ONE
-- DOOR: the net handler and bmx_reset_server both come through here.
--------------------------------------------------------------------------
function S.Request(ply, op, name, value)
    if not BMX.Can(ply, S.PRIV) then
        return false, "you do not have permission to change BMX server settings"
    end

    if op == S.OP_RESET_ALL then
        for _, row in ipairs(S.Rows("server")) do setConVar(row, row.default) end
        return true, "every BMX server setting is back to its default"
    end

    local row = S.Get(name)
    if not row or row.scope ~= "server" then
        return false, tostring(name) .. " is not a BMX server setting"
    end
    if not GetConVar(row.name) then
        return false, row.name .. " is not available on this server"
    end

    if op == S.OP_RESET then
        setConVar(row, row.default)
        return true, row.label .. " is back to " .. S.ToConVar(row, row.default)
    elseif op == S.OP_SET then
        local v, why = S.Coerce(row, value)
        if v == nil then return false, row.label .. ": " .. why end
        setConVar(row, v)
        return true, row.label .. " is now " .. S.ToConVar(row, v)
    end
    return false, "unknown request"
end

net.Receive("bmx_setting", function(_, ply)
    if not IsValid(ply) then return end
    local op = net.ReadUInt(2)
    local name = net.ReadString()
    local value = net.ReadString()
    local ok, msg = S.Request(ply, op, name, value)
    if ok then
        MsgN("[BMX] ", ply:Nick(), ": ", msg)
    else
        say(ply, msg)
    end
end)

concommand.Add("bmx_reset_server", function(ply)
    local ok, msg = S.Request(ply, S.OP_RESET_ALL)
    say(ply, msg)
end)

--------------------------------------------------------------------------
-- server.json
--------------------------------------------------------------------------
function S.ServerValues()
    local t = {}
    for _, row in ipairs(S.Rows("server")) do
        local v = S.Current(row)
        if v ~= nil then t[row.name] = v end
    end
    return t
end

function S.SaveServer()
    file.CreateDir("bmx")
    file.Write(S.ServerFile, util.TableToJSON(S.ServerValues(), true))
end

-- Apply a decoded table. Returns how many settings it set.
function S.ApplyServerValues(t)
    local n = 0
    for name, raw in pairs(t) do
        local row = S.Get(name)
        if row and row.scope == "server" then
            local v = S.Coerce(row, raw)
            if v ~= nil and setConVar(row, v) then n = n + 1 end
        end
    end
    return n
end

function S.LoadServer()
    if not file.Exists(S.ServerFile, "DATA") then return 0 end
    local t = util.JSONToTable(file.Read(S.ServerFile, "DATA") or "")
    if not istable(t) then
        MsgN("[BMX] ", S.ServerFile, " could not be read; leaving it alone")
        return 0
    end
    S.loading = true
    local n = S.ApplyServerValues(t)
    S.loading = false
    MsgN("[BMX] loaded ", n, " server setting", n == 1 and "" or "s", " from ", S.ServerFile)
    return n
end

-- A change from anywhere writes the file, a moment later and once. Not while
-- the headless suite is running: what it turns (T.ConVar, the defaults it runs
-- on) is the test's, not the server's setting.
function S.QueueSave()
    if S.loading or S.testing then return end
    timer.Create("BMX.SaveSettings", 0.5, 1, S.SaveServer)
end

-- At InitPostEntity, when every file has created its convars: load, THEN start
-- listening, so loading the file does not write it straight back.
hook.Add("InitPostEntity", "BMX.Settings", function()
    S.LoadServer()
    for _, row in ipairs(S.Rows("server")) do
        if GetConVar(row.name) then
            cvars.AddChangeCallback(row.name, S.QueueSave, "BMX.Persist")
        end
    end
end)

--------------------------------------------------------------------------
-- THE HEADLESS SUITE RUNS ON THE DEFAULTS (sv_test.lua). Every case's bands were
-- set on the shipped values, and the CI server's server.json had come to hold
-- bmx_wheel_sweep 1 -- a sweep case's own T.ConVar, saved half a second after it
-- was set and never set back on that server -- so every case on it rode with
-- the swept wheel and the suite there measured something else (over_bumps and
-- rides_up_wedge_45@fixie red only there, pipelines 1123-1125). For a run the
-- server rows go to their defaults with saving off, and the saved file is put
-- back when it ends.
--------------------------------------------------------------------------
function S.BeginTestRun()
    S.testing = true
    S.loading = true
    for _, row in ipairs(S.Rows("server")) do setConVar(row, row.default) end
    S.loading = false
    if BMX.ApplyConVars then BMX.ApplyConVars() end
end

function S.EndTestRun()
    for _, row in ipairs(S.Rows("server")) do setConVar(row, row.default) end
    S.LoadServer()
    if BMX.ApplyConVars then BMX.ApplyConVars() end
    S.testing = false
end
