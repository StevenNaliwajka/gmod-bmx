-- MANY RIDERS IN VIEW (tools/bench/sp.sh riders N): N bots, each on a vehicle of its own,
-- riding circles in front of the player, who stands and watches. Every other rider is posed
-- by this client every frame (cl_rider.lua's IK, the vehicle's Draw, the wheels' sounds), so
-- this is what a busy server costs a player, which one rider alone never shows. Two scenes:
-- the riders in view, then the same riders behind the camera (what culling saves). Client
-- and server cost as `sp.sh features` measures them; results in data/probe/riders.txt.
--
-- Bots need free player slots: the session must be launched with BMX_SP_MAXPLAYERS above N
-- (a listen server). Without them this writes why and DONE, and the gate leaves it out.
RIDERS = RIDERS or {}
local R = RIDERS
local N = RIDERS_N or 8
local OUT = "probe/riders.txt"
local o = player.GetHumans()[1]
local base = Vector(4000, 4000, -11000)
local g = util.TraceLine({ start = base, endpos = base - Vector(0, 0, 3000), mask = MASK_SOLID_BRUSHONLY }).HitPos
file.Delete(OUT)

local function done() file.Append(OUT, "DONE\n") end

if game.MaxPlayers() < N + 1 then
    file.Write(OUT, string.format("riders: not run: %d bots need maxplayers %d, the session has %d (BMX_SP_MAXPLAYERS)\n",
        N, N + 1, game.MaxPlayers()))
    done()
    return
end

hook.Remove("Think", "riders_drive")
for _, e in ipairs(R.ents or {}) do if IsValid(e) then e:Remove() end end
R.ents = {}

local KINDS = { "stock", "road", "dirtbike", "emoto", "scooter", "tandem", "penny", "dh", "cruiser", "city",
                "mini", "fixie", "ebike", "moped", "unicycle" }
local bots = {}
for _, b in ipairs(player.GetBots()) do bots[#bots + 1] = b end
while #bots < N do
    local b = player.CreateNextBot("Rider" .. (#bots + 1))
    if not IsValid(b) then break end
    bots[#bots + 1] = b
end
if #bots < N then
    file.Write(OUT, string.format("riders: not run: only %d of %d bots joined\n", #bots, N))
    done()
    return
end

-- the ring the riders circle on, in front of the watcher
local centre = g + Vector(500, 0, 0)
local bikes = {}
for i = 1, N do
    local a = (i - 1) / N * math.pi * 2
    local id = KINDS[(i - 1) % #KINDS + 1]
    local e = ents.Create(BMX.ClassFor(id))
    e:SetPos(centre + Vector(math.cos(a) * 260, math.sin(a) * 260, 14))
    e:SetAngles(Angle(0, math.deg(a) + 90, 0))
    e:Spawn() e:Activate()
    R.ents[#R.ents + 1] = e
    bikes[i] = { ent = e, id = id, rider = bots[i] }
    bots[i].BMXScripted = true
end
timer.Simple(0.6, function()
    for _, b in ipairs(bikes) do
        if IsValid(b.ent) and IsValid(b.rider) then
            b.rider:SetPos(b.ent:GetPos() + Vector(0, 0, 30))
            b.rider:EnterVehicle(b.ent:GetPod())
        end
    end
end)
local t0 = CurTime() + 1
hook.Add("Think", "riders_drive", function()
    for _, b in ipairs(bikes) do
        local e = b.ent
        if IsValid(e) and e.input then
            local inp, st = e.input, e.st or {}
            inp.throttle, inp.leanTarget, inp.brakeRear, inp.brakeFront = 0.3, 0.3, 0, 0
            if b.id == "unicycle" then
                inp.leanTarget = math.Clamp(-4 * ((st.roll or 0) + 0.15 * (st.rollRate or 0)) + 0.05, -1, 1)
                local x = math.Clamp(0.25 - 4 * ((st.pitch or 0) + 0.15 * (st.pitchRate or 0)), -1, 1)
                inp.throttle, inp.brakeRear = math.max(x, 0), math.max(-x, 0)
            end
            if BMX.Vehicles[b.id] and BMX.Vehicles[b.id].family == "board" then
                local bi = BMX.Board.InputOf(inp)
                bi.fwd, bi.side = 1, 0.3
            end
        end
    end
end)

-- the server's cost: every BMX hook and each vehicle's methods (as features_sv.lua)
local function serverMeasure(label, secs, k)
    local acc, wrapped, entsW = {}, {}, {}
    local function wrap(name, fn)
        return function(...)
            local s = SysTime()
            local a, b, c, d, e = fn(...)
            acc[name] = (acc[name] or 0) + (SysTime() - s)
            return a, b, c, d, e
        end
    end
    for ev, list in pairs(hook.GetTable()) do
        for id, fn in pairs(list) do
            if isstring(id) and id:sub(1, 3) == "BMX" then
                wrapped[#wrapped + 1] = { ev, id, fn }
                hook.Add(ev, id, wrap("hook " .. ev, fn))
            end
        end
    end
    for _, e in ipairs(ents.FindByClass("bmx_*")) do
        for _, m in ipairs({ "Think", "PhysicsSimulate", "PhysicsCollide" }) do
            if isfunction(e[m]) then entsW[#entsW + 1] = { e, m, e[m] } e[m] = wrap(m, e[m]) end
        end
    end
    local s0 = SysTime()
    timer.Simple(secs, function()
        for _, h in ipairs(wrapped) do hook.Add(h[1], h[2], h[3]) end
        for _, x in ipairs(entsW) do if IsValid(x[1]) then x[1][x[2]] = x[3] end end
        local total = 0
        for _, v in pairs(acc) do total = total + v end
        file.Append(OUT, string.format("%-34s server %6.2f ms/s\n", label, total * 1000 / (SysTime() - s0)))
        k()
    end)
end

local function measure(label, k)
    o:SendLua(string.format([[REALPROBE.Measure(%q, 6, function(s) file.Append(%q, s .. "\n") end)]], label, OUT))
    serverMeasure(label, 6, function() timer.Simple(1.5, k) end)
end

o:SetPos(g + Vector(-150, 0, 8))
o:SetEyeAngles(Angle(12, 0, 0))

-- THE MODELS FIRST. Eight kinds spawned at once build eight models, a slice a frame; measured
-- 5 s in (the first whole gate run, 2026-11-11) the scene was still building them, so its
-- frames were the builds' as much as the riders'. The first spawn's hitch is the spawns
-- bench's to judge: this one waits for every model to be ready (the client says so in
-- probe/riders_ready.txt; a listen server shares the data folder), up to 30 s, and writes
-- how long that took.
local READY = "probe/riders_ready.txt"
file.Delete(READY)
o:SendLua([[local t0 = RealTime() timer.Create("riders_ready", 0.25, 0, function()
    local st = BMX.BikeMesh and BMX.BikeMesh.Status and BMX.BikeMesh.Status() or {}
    local n, busy = 0, 0
    for _, v in pairs(st) do n = n + 1 if v == "building" or v == "warming" then busy = busy + 1 end end
    if (n > 0 and busy == 0) or RealTime() - t0 > 30 then
        file.Write("probe/riders_ready.txt", string.format("%d models, %d still building, after %.1f s", n, busy, RealTime() - t0))
        timer.Remove("riders_ready")
    end
end)]])
local function whenReady(k)
    local tries = 0
    timer.Create("riders_wait", 0.25, 0, function()
        tries = tries + 1
        if file.Exists(READY, "DATA") or tries > 160 then
            timer.Remove("riders_wait")
            file.Append(OUT, "(models: " .. (file.Read(READY, "DATA") or "the client never said") .. ")\n")
            k()
        end
    end)
end

timer.Simple(2, function() whenReady(function()
    measure(N .. " riders in view", function()
        o:SetEyeAngles(Angle(12, 180, 0))
        timer.Simple(1, function()
            measure(N .. " riders behind the camera", function()
                hook.Remove("Think", "riders_drive")
                for _, b in ipairs(bikes) do
                    if IsValid(b.rider) and IsValid(b.rider:GetVehicle()) then b.rider:ExitVehicle() end
                end
                for _, e in ipairs(R.ents) do if IsValid(e) then e:Remove() end end
                done()
            end)
        end)
    end)
end) end)
