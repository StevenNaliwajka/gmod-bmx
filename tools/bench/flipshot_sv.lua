-- THE FLIP PHOTOGRAPHS, server half (tools/bench/sp.sh flipshot): what each flip paid or
-- why it bailed, one line each, in data/flipshot/result.txt. The seat is camshake_sv.lua's.
file.CreateDir("flipshot")
file.Write("flipshot/result.txt", "")
local function note(s) file.Append("flipshot/result.txt", s .. "\n") end
hook.Add("BMX_BoardFlipStarted", "flipshot", function(ent, ply, id) note("started " .. id) end)
hook.Add("BMX_TrickLanded", "flipshot", function(ply, t) note("landed " .. tostring(t.name) .. " " .. tostring(t.points)) end)
hook.Add("BMX_Crashed", "flipshot", function(ent, ply, reason) note("crashed " .. tostring(reason)) end)
print("[flipshot] server half ready")
-- thrown off: back on a fresh board for the next one
hook.Add("BMX_Crashed", "flipshot_reseat", function()
    timer.Simple(1.2, function() concommand.Run(Entity(1), "camshake_seat", { "skateboard" }, "skateboard") end)
end)
