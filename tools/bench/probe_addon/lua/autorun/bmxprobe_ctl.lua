-- A control channel for a game with no rcon (a singleplayer session on a test client):
-- the server reads data/probe/cmd.txt twice a second, deletes it, and runs each line as a
-- console command ("lua <code>" runs Lua). Install it only on a test client:
-- tools/bench/sp.sh puts it in and takes it out again.
if not SERVER then return end
file.CreateDir("probe")
timer.Create("bmxprobe_ctl", 0.5, 0, function()
    local s = file.Read("probe/cmd.txt", "DATA")
    if not s then return end
    file.Delete("probe/cmd.txt")
    for line in string.gmatch(s, "[^\n]+") do
        if line:sub(1, 4) == "lua " then
            local ok, err = pcall(RunString, line:sub(5), "bmxprobe")
            if not ok then file.Append("probe/log.txt", "ERR " .. tostring(err) .. "\n") end
        else
            -- A Lua console command is called as the server console calls it (no player):
            -- through game.ConsoleCommand a singleplayer session runs it as the host
            -- player, and the tools' commands only take orders from the console.
            local name, rest = line:match("^(%S+)%s*(.*)$")
            local fn = name and concommand.GetTable()[name]
            if fn then
                local args = {}
                for a in string.gmatch(rest or "", "%S+") do args[#args + 1] = a end
                local ok, err = pcall(fn, NULL, name, args, rest or "")
                if not ok then file.Append("probe/log.txt", "ERR " .. name .. ": " .. tostring(err) .. "\n") end
            else
                game.ConsoleCommand(line .. "\n")
            end
        end
    end
end)
file.Append("probe/log.txt", "ctl ready " .. os.date() .. "\n")
-- The player in the game (not only the server up): what the scripts wait for before
-- sending anything that needs a client.
hook.Add("PlayerInitialSpawn", "bmxprobe_ready", function()
    timer.Simple(5, function() file.Append("probe/log.txt", "player ready " .. os.date() .. "\n") end)
end)
