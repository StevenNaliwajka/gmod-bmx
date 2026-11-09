-- THE FIRST-SPAWN HITCH, measured (tools/bench/sp.sh spawns): each kind spawned once in
-- front of the player, 6 s apart, the client watching every frame for 5 s after each
-- (spawnprobe_cl.txt): frame time, the Lua heap (a drop is a collection), and the model
-- build's own time in that frame (BM.Get runs the build's slice).
util.AddNetworkString("spawnprobe")
SPAWNPROBE = SPAWNPROBE or {}
local P = SPAWNPROBE
for _, e in ipairs(P.ents or {}) do if IsValid(e) then e:Remove() end end
P.ents = {}
local o = player.GetHumans()[1]
local base = Vector(4000, 4000, -11000)
local g = util.TraceLine({ start = base, endpos = base - Vector(0, 0, 3000), mask = MASK_SOLID_BRUSHONLY }).HitPos
o:SetPos(g + Vector(-260, 0, 8)) o:SetEyeAngles(Angle(8, 0, 0))
o:SendLua([[RunString(file.Read("spawnprobe_cl.txt","DATA"),"spawnprobe")]])
file.Delete("probe/spawns.txt")
local ids = SPAWNPROBE_IDS or { "stock", "cruiser", "mini", "road", "fixie", "city", "unicycle", "penny", "tandem", "dh",
    "scooter", "ebike", "emoto", "dirtbike", "moped", "skateboard" }
for i, id in ipairs(ids) do
    timer.Simple(2 + (i - 1) * (6 + (SPAWNPROBE_INTENT or 0)), function()
        if not IsValid(o) then return end
        net.Start("spawnprobe") net.WriteString(id) net.WriteFloat(5) net.Send(o)
        -- SPAWNPROBE_INTENT seconds before the spawn, the player "points at it in the menu"
        -- (what hovering a /bike or Q menu entry does: BMX.ModelIntent)
        if SPAWNPROBE_INTENT and SPAWNPROBE_INTENT > 0 then
            o:SendLua(string.format("BMX.ModelIntent(%q)", id))
        end
        if IsValid(o) and IsValid(o:GetVehicle()) then o:ExitVehicle() end
        hook.Remove("Think", "spawnprobe_drive")
        -- alone: the last one goes first, so each spawn is measured on its own
        for _, e in ipairs(P.ents) do if IsValid(e) then e:Remove() end end
        P.ents = {}
        timer.Simple(0.5, function()
            local t0 = SysTime()
            local b = ents.Create(BMX.ClassFor(id))
            b:SetPos(g + Vector(0, 0, 14)) b:SetAngles(Angle(0, 90, 0))
            b:Spawn() b:Activate()
            local ms = (SysTime() - t0) * 1000
            file.Append("probe/spawns.txt", string.format("  (server spawn of %s: %.1f ms)\n", id, ms))
            P.ents[#P.ents + 1] = b
            -- SPAWNPROBE_RIDE: the player gets on and rides it round a circle (the camera
            -- sweep's e-bike spike was while riding: its motor, its HUD, its sounds)
            if SPAWNPROBE_RIDE then
                timer.Simple(0.3, function()
                    if not (IsValid(b) and IsValid(o)) then return end
                    if IsValid(o:GetVehicle()) then o:ExitVehicle() end
                    o.BMXScripted = true
                    o:EnterVehicle(b:GetPod())
                end)
                hook.Add("Think", "spawnprobe_drive", function()
                    local inp = IsValid(b) and b.input
                    if inp then inp.throttle, inp.leanTarget, inp.brakeRear, inp.brakeFront = 0.35, 0.3, 0, 0 end
                end)
            end
        end)
    end)
end
timer.Simple(2 + #ids * (6 + (SPAWNPROBE_INTENT or 0)) + 1, function() file.Append("probe/spawns.txt", "DONE\n") end)
