-- THE ANIMATION SWEEP, server half (tools/ride/sweep.sh; see tools/ride/README.md).
-- Rides a bot on each vehicle in turn (a second bot as passenger on two of them) through
-- the same timeline -- pedal, sprint, stances, a hop with a style pose -- and tells the
-- owner's client when to watch. The client half (sweep_cl.lua) measures every frame.
util.AddNetworkString("sweep_code")
util.AddNetworkString("sweep_go")
util.AddNetworkString("sweep_result")
util.AddNetworkString("sweep_cv")
SWEEP = SWEEP or {}
local SW = SWEEP
-- Only the named client is ever sent code (sweep_owner <name>).
local function owner()
    for _, p in ipairs(player.GetHumans()) do if p:Nick() == SW.owner then return p end end
end
concommand.Add("sweep_owner", function(p, _, args) if IsValid(p) then return end SW.owner = args[1] end)
file.CreateDir("sweep")
net.Receive("sweep_result", function(_, ply)
    if ply ~= owner() then return end
    file.Append("sweep/result.txt", net.ReadString() .. "\n")
end)

concommand.Add("sweep_push", function(p)
    if IsValid(p) then return end
    local o = owner() if not IsValid(o) then print("[sweep] no client") return end
    o:SendLua([[net.Receive("sweep_code",function() RunString(net.ReadString(),"sweep") end)]])
    timer.Simple(1, function()
        net.Start("sweep_code") net.WriteString(file.Read("sweep_cl.txt", "DATA")) net.Send(o)
        print("[sweep] pushed")
    end)
end)

-- Every server setting's value, for the client to compare with its own copy.
concommand.Add("sweep_cv", function(p, _, args)
    if IsValid(p) then return end
    local o = owner() if not IsValid(o) then return end
    local rows = {}
    for _, r in ipairs(BMX.Settings.List) do
        if r.scope == "server" then
            local c = GetConVar(r.name)
            if c then rows[#rows + 1] = r.name .. "=" .. c:GetString() end
        end
    end
    net.Start("sweep_cv") net.WriteString(args[1] or "") net.WriteString(table.concat(rows, "\n")) net.Send(o)
end)

local function bot(name)
    for _, b in ipairs(player.GetBots()) do if b:Nick() == name then return b end end
    return player.CreateNextBot(name)
end

local function ground()
    -- gm_flatgrass's open lower plane by default (the spawn is on a slab 512 u up: ride
    -- off its edge and the run measures a drop); sweep_ground x y z for another map.
    local p = SW.ground or Vector(4000, 4000, -11000)
    local tr = util.TraceLine({ start = p, endpos = p - Vector(0, 0, 3000), mask = MASK_SOLID_BRUSHONLY })
    return tr.HitPos
end

local function cleanup()
    hook.Remove("Think", "sweep_drive")
    for _, p in ipairs({ SW.pax, SW.rider }) do
        if IsValid(p) and IsValid(p:GetVehicle()) then p:ExitVehicle() end
    end
    if IsValid(SW.bike) then SW.bike:Remove() end
    local g = ground()
    if IsValid(SW.rider) then SW.rider:SetNWInt("BMXStance", 1) SW.rider:SetPos(g + Vector(-400, 300, 8)) end
    if IsValid(SW.pax) then SW.pax:SetPos(g + Vector(-400, 380, 8)) end
end

-- One run: spawn at s, seated at s + 0.6, watched from s + 4 for 14 s.
local function run(spec)
    cleanup()
    local o = owner()
    if not IsValid(o) then print("[sweep] the owner is not connected") return end
    local rider = bot("SweepRider")
    rider.BMXScripted = true
    SW.rider = rider
    local pax
    if spec.pax then pax = bot("SweepPax") pax.BMXScripted = true SW.pax = pax end
    local g = ground()
    local bike = ents.Create(BMX.ClassFor(spec.id))
    bike:SetPos(g + Vector(0, 0, 14))
    bike:SetAngles(Angle(0, 90, 0))
    bike:Spawn() bike:Activate()
    SW.bike = bike
    rider:SetNWInt("BMXStance", 1)
    if IsValid(o) then
        net.Start("sweep_go")
        net.WriteString(spec.id .. (spec.pax and "+passenger" or "") .. (spec.pose and (" pose " .. spec.pose) or ""))
        net.WriteUInt(bike:EntIndex(), 16) net.WriteUInt(rider:EntIndex(), 16)
        net.WriteUInt(pax and pax:EntIndex() or 0, 16)
        net.WriteBool(SW.detail == true)
        net.Send(o)
    end
    timer.Simple(0.6, function()
        if not IsValid(bike) then return end
        rider:EnterVehicle(bike:GetPod())
        if pax then
            timer.Simple(0.4, function()
                if IsValid(bike) and IsValid(pax) then
                    pax:SetPos(bike:GetPos() + bike:GetForward() * -60 + Vector(0, 0, 8))
                    BMX.Passenger.TryBoard(bike, pax, true)
                end
            end)
        end
        local t0 = CurTime() + 3.4
        local hopped, boosted
        hook.Add("Think", "sweep_drive", function()
            if not IsValid(bike) or not bike.input then return end
            local inp, t, st = bike.input, CurTime() - t0, bike.st or {}
            local thr = spec.throttle or 0.4
            inp.throttle = (t > 0 and t < 13) and thr or 0
            inp.leanTarget = (t > 0) and (spec.lean or 0.18) or 0
            inp.brakeRear, inp.brakeFront = 0, 0
            if spec.uni then
                -- The unicycle stands up only if it is balanced (unicycle_balances).
                inp.leanTarget = math.Clamp(-4 * ((st.roll or 0) + 0.15 * (st.rollRate or 0)) + 0.05, -1, 1)
                local x = math.Clamp((t > 0 and 0.25 or 0) - 4 * ((st.pitch or 0) + 0.15 * (st.pitchRate or 0)), -1, 1)
                inp.throttle, inp.brakeRear = math.max(x, 0), math.max(-x, 0)
            end
            if spec.board then
                local b = BMX.Board.InputOf(inp)
                b.fwd = (t > 0 and t < 13) and 1 or 0
                b.side = (t > 0) and 0.3 or 0
                b.jump = t > 10.6 and t < 11.0
                if b.jump and not b.jumpTap then b.jumpTap, b.jumpTapKeys = true, BMX.Board.Keys(inp) end
            end
            inp.sprint = t > 3 and t < 5
            local stance = (t > 6 and t < 8) and 3 or ((t >= 8 and t < 9.5) and 2 or 1)
            if rider:GetNWInt("BMXStance", 1) ~= stance then rider:SetNWInt("BMXStance", stance) end
            if not spec.uni and not spec.board then
                if t > 10.5 and t < 11.1 then
                    if not hopped then bike.hopCharge, bike.hopHeld, hopped = 0, true, true end
                    inp.hop = true
                else
                    if hopped == true and t >= 11.1 then bike.hopRelease, hopped = true, "done" end
                    inp.hop = false
                end
            end
            -- More air than a flat-ground hop gives, so a style pose has time to blend in and out.
            if not spec.uni and t >= 11.15 and not boosted then
                boosted = true
                local ph = bike:GetPhysicsObject()
                if IsValid(ph) then ph:AddVelocity(Vector(0, 0, spec.boost or 230)) end
            end
            inp.pose = (spec.pose and t > 11.25 and t < 11.85) and spec.pose or nil
            if t > 15 then cleanup() end
        end)
    end)
    print("[sweep] running " .. spec.id)
end

SW.RUNS = {
    { id = "stock", pose = "nohander" },
    { id = "stock", pax = true, pose = "cancan_r" },
    { id = "road" },
    { id = "tandem", pax = true },
    { id = "unicycle", uni = true },
    { id = "penny", throttle = 0.3 },
    { id = "dirtbike", throttle = 0.15, lean = 0.1, pose = "superman", boost = 260 },
    { id = "scooter" },
    { id = "skateboard", board = true },
    { id = "cruiser" },
    { id = "mini" },
    { id = "fixie" },
    { id = "city", throttle = 0.3 },
    { id = "dh" },
    { id = "ebike", throttle = 0.2 },
    { id = "emoto", throttle = 0.12, lean = 0.1 },
    { id = "moped", throttle = 0.15, lean = 0.1 },
    { id = "dirtbike", throttle = 0.06, lean = 0.6 },     -- slow, at full lock
}
-- sweep_run <detail 0|1> [run numbers...]: every run in SW.RUNS, or the ones named.
concommand.Add("sweep_ground", function(p, _, args)
    if IsValid(p) then return end
    SW.ground = Vector(tonumber(args[1]) or 0, tonumber(args[2]) or 0, tonumber(args[3]) or 0)
end)
concommand.Add("sweep_run", function(p, _, args)
    if IsValid(p) then return end
    SW.detail = args[1] == "1"
    local list = SW.RUNS
    if args[2] then
        list = {}
        for i = 2, #args do list[#list + 1] = SW.RUNS[tonumber(args[i])] end
    end
    file.Delete("sweep/result.txt")
    for k = 1, #list do timer.Simple((k - 1) * 20, function() run(list[k]) end) end
    timer.Simple(#list * 20, function()
        cleanup()
        for _, n in ipairs({ "SweepRider", "SweepPax" }) do
            for _, b in ipairs(player.GetBots()) do if b:Nick() == n then b:Kick("sweep done") end end
        end
        file.Append("sweep/result.txt", "DONE\n")
        print("[sweep] all done")
    end)
end)
print("[sweep] server ready")
