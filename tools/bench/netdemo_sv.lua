-- The server half of tools/bench/netdemo.sh, on a real dedicated server (run over RCON:
-- lua_run RunString(file.Read("netdemo_sv.txt","DATA"))). gm_flatgrass's open lower plane:
-- a stock bike spawned facing +x for the first human, who is seated on it, and the bike
-- carried back 20000 units whenever it reaches the far side, velocity and angles kept, so
-- a straight ride can go on as long as the latency table takes. Then the client's half is
-- sent (data/latency_cl.txt on the CLIENT's own disk).
NETDEMO = NETDEMO or {}
local N = NETDEMO
local o = player.GetHumans()[1]
if not IsValid(o) then print("[netdemo] no human connected") return end
if IsValid(N.bike) then N.bike:Remove() end
local start = Vector(-10000, 4000, -11000)
local g = util.TraceLine({ start = start, endpos = start - Vector(0, 0, 3000), mask = MASK_SOLID_BRUSHONLY }).HitPos
local bike = ents.Create(BMX.ClassFor("stock"))
bike:SetPos(g + Vector(0, 0, 14))
bike:SetAngles(Angle(0, 0, 0))
bike:Spawn() bike:Activate()
N.bike = bike
o:SetPos(g + Vector(-60, 0, 8))
timer.Simple(0.5, function()
    if not (IsValid(bike) and IsValid(o)) then return end
    o:EnterVehicle(bike:GetPod())
    print("[netdemo] seated " .. o:Nick() .. " on " .. tostring(bike))
    timer.Simple(1.5, function()
        if IsValid(o) then o:SendLua([[RunString(file.Read("latency_cl.txt","DATA"),"latency_cl")]]) end
    end)
end)
hook.Add("Think", "netdemo_wrap", function()
    if not IsValid(bike) then hook.Remove("Think", "netdemo_wrap") return end
    local p = bike:GetPos()
    if p.x > g.x + 20000 or math.abs(p.y - g.y) > 3000 then
        local phys = bike:GetPhysicsObject()
        local v = IsValid(phys) and phys:GetVelocity()
        bike:SetPos(Vector(g.x, g.y, p.z))
        if v then phys:SetVelocity(v) end
    end
end)
