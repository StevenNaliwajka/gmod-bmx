--[[--------------------------------------------------------------------------
    tools/ride/ride_sv.lua -- the ride studio, server half (NOT shipped: tools/ is
    ignored by the .gma). tools/ride/shoot.sh copies it onto a test server and runs
    it; see tools/ride/README.md.

    The icon studio shoots a vehicle standing alone. This one shoots it RIDDEN: a
    scripted bot gets on, rolls forward at a set throttle, and the owner's client
    photographs bike and rider together from a few angles, so the rider's pose and
    the pedalling can be looked at without anyone having to ride.

    One job at a time: spawn the vehicle on the floor, mount the bot, roll, tell the
    client to shoot, wait for the pictures, get off, remove, next.
----------------------------------------------------------------------------]]
util.AddNetworkString("ridestudio_code")
util.AddNetworkString("ridestudio_cap")
util.AddNetworkString("ridestudio_img")
util.AddNetworkString("ridestudio_done")
util.AddNetworkString("ridestudio_end")

RIDESTUDIO = RIDESTUDIO or {}
local S = RIDESTUDIO
S.FLOOR = S.FLOOR or Vector(2700, 150, 64)
S.BOT = "BMX Studio"
S.throttle = S.throttle or 0.45

hook.Add("SetupPlayerVisibility", "ridestudio", function()
    if S.cur and IsValid(S.cur.bike) then AddOriginToPVS(S.cur.bike:GetPos()) end
end)

-- Only ever the NAMED owner's client: a public test server can have strangers on it,
-- and nobody else's game should be pushed code or made to render.
local function owner()
    if not S.ownerName then return nil end
    for _, p in ipairs(player.GetHumans()) do
        if p:Nick() == S.ownerName then return p end
    end
end
concommand.Add("ridestudio_owner", function(p, _, a) if IsValid(p) then return end S.ownerName = a[1] end)

local function bot()
    for _, p in ipairs(player.GetBots()) do if p:Nick() == S.BOT then return p end end
    return player.CreateNextBot(S.BOT)
end

-- The floor under S.FLOOR, and the yaw with the longest clear run along it.
local function stage()
    local tr = util.TraceLine({ start = S.FLOOR + Vector(0, 0, 200), endpos = S.FLOOR - Vector(0, 0, 400), mask = MASK_SOLID_BRUSHONLY })
    local g = tr.HitPos
    local best, bestYaw = -1, 0
    for yaw = 0, 315, 45 do
        local d = Angle(0, yaw, 0):Forward()
        local t = util.TraceHull({ start = g + Vector(0, 0, 30), endpos = g + Vector(0, 0, 30) + d * 2000,
            mins = Vector(-30, -30, -20), maxs = Vector(30, 30, 40), mask = MASK_SOLID })
        local run = t.Fraction * 2000
        if run > best then best, bestYaw = run, yaw end
    end
    return g, bestYaw, best
end

local function cleanup()
    local c = S.cur
    if not c then return end
    hook.Remove("Think", "ridestudio_drive")
    local b = c.bot
    if IsValid(b) then
        if BMX.Worn and BMX.Worn.Unequip then pcall(BMX.Worn.Unequip, b) end
        if IsValid(b:GetVehicle()) then b:ExitVehicle() end
        b.BMXScripted = nil
        b:SetPos(c.ground + Vector(-200, 0, 10))
    end
    if IsValid(c.bike) then c.bike:Remove() end
    S.cur = nil
end

function S.Next()
    cleanup()
    local id = table.remove(S.queue or {}, 1)
    if not id then
        print("[ride] done")
        local o = owner()
        if IsValid(o) and not S.ended then
            S.ended = true
            net.Start("ridestudio_end") net.Send(o)
            return
        end
        file.Write("ridestudio/_done.txt", "ok " .. (S.restored or ""))
        return
    end
    if not owner() then
        S.queue = {}
        file.Write("ridestudio/_done.txt", "owner " .. tostring(S.ownerName) .. " is not connected")
        return
    end
    local def = BMX.Vehicles[id]
    if not def then print("[ride] no vehicle " .. id) return S.Next() end
    local g, yaw, run = stage()
    local b = bot()
    if not IsValid(b) then print("[ride] no bot") file.Write("ridestudio/_done.txt", "no bot") return end
    local c = { id = id, bot = b, ground = g }
    S.cur = c
    b.BMXScripted = true
    if IsValid(b:GetVehicle()) then b:ExitVehicle() end
    if def.worn then
        b:SetPos(g + Vector(0, 0, 4))
        b:SetEyeAngles(Angle(0, yaw, 0))
        BMX.Worn.Equip(b, id)
        c.ent = b
    else
        local bike = ents.Create(BMX.ClassFor(id))
        local cfg = BMX.ConfigFor(def)
        bike:SetPos(g + Vector(0, 0, cfg.Wheel.radius + 2))
        bike:SetAngles(Angle(0, yaw, 0))
        bike:Spawn()
        bike:Activate()
        c.bike, c.ent = bike, bike
    end
    timer.Simple(0.6, function()
        if S.cur ~= c then return end
        if c.bike then
            local pod = c.bike:GetPod()
            if IsValid(pod) then b:EnterVehicle(pod) end
        end
        local t0 = CurTime()
        hook.Add("Think", "ridestudio_drive", function()
            if not IsValid(c.bike) or not c.bike.input then return end
            local inp = c.bike.input
            local t = CurTime() - t0
            local go = t > 0.4
            inp.throttle = go and S.throttle or 0
            inp.leanTarget, inp.brakeRear, inp.brakeFront = 0, 0, 0
            inp.hop, inp.pose = false, nil
            -- THE SEQUENCE (ridestudio_run ... seq): pedal off, a turn, a bunny hop
            if S.mode == "seq" then
                if t > 2.2 and t < 3.4 then inp.leanTarget = 0.7 end
                if t > 3.6 and t < 4.0 then
                    if not c.hopHeld then c.bike.hopCharge, c.bike.hopHeld, c.hopHeld = 0, true, true end
                    inp.hop = true
                elseif c.hopHeld and t >= 4.0 then
                    c.bike.hopRelease, c.hopHeld = true, false
                end
            end
        end)
    end)
    timer.Simple(S.mode == "seq" and 1.4 or 2.6, function()
        if S.cur ~= c then return end
        local o = owner()
        if not IsValid(o) then print("[ride] no owner") return S.Next() end
        net.Start("ridestudio_cap")
        net.WriteString(id)
        net.WriteEntity(c.ent)
        net.WriteEntity(b)
        net.WriteString(S.mode or "")
        net.Send(o)
        c.deadline = CurTime() + 120
    end)
end

hook.Add("Think", "ridestudio_watchdog", function()
    local c = S.cur
    if c and c.deadline and CurTime() > c.deadline then print("[ride] timed out on " .. c.id) S.Next() end
end)

local parts = {}
net.Receive("ridestudio_img", function()
    local name = net.ReadString()
    local i, n = net.ReadUInt(16), net.ReadUInt(16)
    local len = net.ReadUInt(32)
    parts[name] = parts[name] or {}
    parts[name][i] = net.ReadData(len)
    local cnt = 0
    for _ in pairs(parts[name]) do cnt = cnt + 1 end
    if cnt == n then
        file.CreateDir("ridestudio")
        file.Write("ridestudio/" .. name .. ".jpg", table.concat(parts[name]))
        parts[name] = nil
    end
end)

net.Receive("ridestudio_done", function()
    local msg = net.ReadString()
    if msg ~= "" then print("[ride] client: " .. msg) end
    if msg:find("^settings restored") then S.restored = msg end
    timer.Simple(0.3, S.Next)
end)

concommand.Add("ridestudio_push", function(p)
    if IsValid(p) then return end
    local code = file.Read("ridestudio_cl.txt", "DATA")
    net.Start("ridestudio_code") net.WriteString(code) net.Send(owner())
    print("[ride] pushed " .. #code .. " bytes")
end)

-- ridestudio_run [id,id,...|all] [throttle] [seq]: every vehicle in the menu, or the ones
-- named; "seq" rides a pedal-off, a turn and a bunny hop and films it frame by frame.
concommand.Add("ridestudio_run", function(p, _, a)
    if IsValid(p) then return end
    file.CreateDir("ridestudio")
    file.Delete("ridestudio/_done.txt")
    S.throttle = tonumber(a[2] or "") or 0.45
    S.mode = a[3]
    local q = {}
    if a[1] and a[1] ~= "" and a[1] ~= "all" then
        for id in a[1]:gmatch("[^,]+") do q[#q + 1] = id end
    else
        for id, def in SortedPairs(BMX.Vehicles) do
            if not def.hidden and not def.debugOnly then q[#q + 1] = id end
        end
    end
    S.queue = q
    S.ended, S.restored = nil, nil
    print("[ride] " .. #q .. " jobs")
    S.Next()
end)

concommand.Add("ridestudio_stop", function(p) if IsValid(p) then return end S.queue = {} cleanup() end)
print("[ride] server ready")
