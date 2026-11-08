-- WHAT THE ADDON COSTS ON A REAL CLIENT, server half (tools/bench/realprobe.sh): stages
-- the scenes the client times (realprobe_cl.lua) -- nothing of ours in view, the owner
-- riding, the owner riding among 4 and then 8 bot riders of mixed vehicles, and a burst
-- of first spawns (each new kind builds its model on the client: the hitch players see
-- "whenever I spawn something").
util.AddNetworkString("realprobe_code")
util.AddNetworkString("realprobe_scene")
util.AddNetworkString("realprobe_result")
REALPROBE = REALPROBE or {}
local R = REALPROBE
local function owner()
    -- "*": the only human (a singleplayer or listen session, where the name may not be known)
    for _, p in ipairs(player.GetHumans()) do if p:Nick() == R.owner or R.owner == "*" then return p end end
end
concommand.Add("realprobe_owner", function(p, _, a) if IsValid(p) then return end R.owner = a[1] end)
file.CreateDir("realprobe")
net.Receive("realprobe_result", function(_, ply)
    if ply ~= owner() then return end
    file.Append("realprobe/result.txt", net.ReadString() .. "\n")
end)
concommand.Add("realprobe_push", function(p)
    if IsValid(p) then return end
    local o = owner() if not IsValid(o) then print("[realprobe] no client") return end
    o:SendLua([[net.Receive("realprobe_code",function() RunString(net.ReadString(),"realprobe") end)]])
    timer.Simple(1, function()
        net.Start("realprobe_code") net.WriteString(file.Read("realprobe_cl.txt", "DATA")) net.Send(o)
    end)
end)

local function ground(off)
    local p = (R.ground or Vector(4000, 4000, -11000)) + (off or vector_origin)
    local tr = util.TraceLine({ start = p, endpos = p - Vector(0, 0, 3000), mask = MASK_SOLID_BRUSHONLY })
    return tr.HitPos
end

R.ents, R.bots = R.ents or {}, R.bots or {}
local function bot(i)
    local name = "ProbeRider" .. i
    for _, b in ipairs(player.GetBots()) do if b:Nick() == name then return b end end
    return player.CreateNextBot(name)
end
local function clear()
    hook.Remove("Think", "realprobe_drive")
    for _, p in ipairs(player.GetAll()) do
        if (p:IsBot() and p:Nick():find("^ProbeRider")) or p == owner() then
            if IsValid(p:GetVehicle()) then p:ExitVehicle() end
            p.BMXScripted = nil
        end
    end
    for _, e in ipairs(R.ents) do if IsValid(e) then e:Remove() end end
    R.ents, R.riding = {}, {}
end

-- A rider on vehicle `id` at offset `off`, driven round a circle.
local function ride(ply, id, off, lean)
    if not IsValid(ply) then return end     -- no bot slots (a singleplayer session)
    local b = ents.Create(BMX.ClassFor(id))
    b:SetPos(ground(off) + Vector(0, 0, 14)) b:SetAngles(Angle(0, 90, 0))
    b:Spawn() b:Activate()
    R.ents[#R.ents + 1] = b
    ply.BMXScripted = true
    timer.Simple(0.5, function() if IsValid(b) and IsValid(ply) then ply:EnterVehicle(b:GetPod()) end end)
    R.riding[#R.riding + 1] = { bike = b, lean = lean or 0.35 }
    return b
end
local function drive()
    hook.Add("Think", "realprobe_drive", function()
        for _, r in ipairs(R.riding) do
            local inp = IsValid(r.bike) and r.bike.input
            if inp then
                inp.throttle, inp.leanTarget, inp.brakeRear, inp.brakeFront = 0.3, r.lean, 0, 0
            end
        end
    end)
end

local function scene(label, secs, k)
    local o = owner()
    if not IsValid(o) then return end
    net.Start("realprobe_scene") net.WriteString(label) net.WriteFloat(secs) net.Send(o)
    timer.Simple(secs + 1, k)
end

local MIX = { "stock", "road", "dirtbike", "emoto", "scooter", "tandem", "penny", "dh" }

concommand.Add("realprobe_run", function(p)
    if IsValid(p) then return end
    local o = owner()
    if not IsValid(o) then print("[realprobe] no owner") return end
    file.Delete("realprobe/result.txt")
    clear()
    o:SetPos(ground(Vector(-300, 0, 0)) + Vector(0, 0, 8))
    o:SetEyeAngles(Angle(10, 0, 0))
    local steps = {}
    -- 1. nothing of ours in the world.
    steps[#steps + 1] = function(k) scene("empty (addon loaded, nothing spawned)", 8, k) end
    -- 2. a first spawn of every mixed kind, one every 0.6 s, in view (the build hitches).
    steps[#steps + 1] = function(k)
        net.Start("realprobe_scene") net.WriteString("first spawns: 8 kinds, one every 0.6 s, parked in view") net.WriteFloat(8) net.Send(o)
        for i, id in ipairs(MIX) do
            timer.Simple((i - 1) * 0.6, function()
                local b = ents.Create(BMX.ClassFor(id))
                b:SetPos(ground(Vector(0, (i - 4.5) * 70, 0)) + Vector(0, 0, 14)) b:SetAngles(Angle(0, 90, 0))
                b:Spawn() b:Activate()
                R.ents[#R.ents + 1] = b
            end)
        end
        timer.Simple(9, k)
    end
    steps[#steps + 1] = function(k) scene("8 parked vehicles in view, nobody riding", 8, k) end
    steps[#steps + 1] = function(k) clear() timer.Simple(1, k) end
    -- 3. the owner riding, alone.
    steps[#steps + 1] = function(k) ride(o, "stock", Vector(0, 0, 0), 0.3) drive() timer.Simple(3, k) end
    steps[#steps + 1] = function(k) scene("owner riding a BMX, chase camera", 8, k) end
    -- 4. among 4, then 8, riders.
    steps[#steps + 1] = function(k)
        for i = 1, 4 do ride(bot(i), MIX[i], Vector(math.cos(i * 1.57) * 250, math.sin(i * 1.57) * 250, 0), 0.4) end
        timer.Simple(4, k)
    end
    steps[#steps + 1] = function(k)
        if #player.GetBots() == 0 then k() return end        -- singleplayer: no bots
        scene("owner riding + 4 bot riders (stock road dirtbike emoto)", 8, k)
    end
    steps[#steps + 1] = function(k)
        for i = 5, 8 do ride(bot(i), MIX[i], Vector(math.cos(i * 0.785) * 450, math.sin(i * 0.785) * 450, 0), 0.4) end
        timer.Simple(4, k)
    end
    steps[#steps + 1] = function(k)
        if #player.GetBots() == 0 then k() return end
        scene("owner riding + 8 bot riders (mixed)", 8, k)
    end
    steps[#steps + 1] = function(k)
        clear()
        for _, b in ipairs(player.GetBots()) do if b:Nick():find("^ProbeRider") then b:Kick("probe done") end end
        file.Append("realprobe/result.txt", "DONE\n")
        print("[realprobe] done")
    end
    local i = 0
    local function nxt() i = i + 1 if steps[i] then steps[i](nxt) end end
    nxt()
end)
concommand.Add("realprobe_stop", function(p) if IsValid(p) then return end clear() end)
print("[realprobe] server ready")
