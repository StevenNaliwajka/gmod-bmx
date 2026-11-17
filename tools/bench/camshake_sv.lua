-- THE CAMERA SHAKE PROBE, server half (tools/bench/sp.sh camshake; netdemo.sh with
-- BMX_NET_PROBE=camshake). Two Workshop players (2026-11-16) reported the third-person
-- camera shaking hard while riding, "a bit better with camera smoothing turned off", and
-- none in first person. The client half (camshake_cl.lua) rides each kind and asks for the
-- next one with `camshake_seat <kind>`: a fresh vehicle of that kind on gm_flatgrass's open
-- lower plane, the asking player seated on it. The vehicle is carried back across the plane
-- whenever it nears an edge, velocity kept, so a ride can go on as long as the probe needs.
CAMSHAKE = CAMSHAKE or {}
local C = CAMSHAKE
local start = Vector(-10000, 4000, -11000)
C.ground = util.TraceLine({ start = start, endpos = start - Vector(0, 0, 3000), mask = MASK_SOLID_BRUSHONLY }).HitPos

concommand.Add("camshake_seat", function(ply, _, args)
    if not IsValid(ply) then ply = player.GetHumans()[1] end
    if not IsValid(ply) then return end
    local cls = BMX.ClassFor(args[1] or "stock")
    if not cls then print("[camshake] no class for " .. tostring(args[1])) return end
    if ply:InVehicle() then ply:ExitVehicle() end
    if IsValid(C.bike) then C.bike:Remove() end
    local g = C.ground
    local bike = ents.Create(cls)
    bike:SetPos(g + Vector(0, 0, 14))
    bike:SetAngles(Angle(0, 0, 0))
    bike:Spawn() bike:Activate()
    C.bike = bike
    ply:SetPos(g + Vector(-60, 0, 8))
    timer.Simple(0.5, function()
        if IsValid(bike) and IsValid(ply) and bike.GetPod and IsValid(bike:GetPod()) then
            ply:EnterVehicle(bike:GetPod())
        end
    end)
end)

-- ROUGH GROUND: a strip of small frozen bumps (2-4 units high, across the path every 24-40
-- units, a few skewed) laid ahead of the asker's vehicle for the "bumps" segment, gone after.
concommand.Add("camshake_bumps", function(ply)
    if not IsValid(ply) then ply = player.GetHumans()[1] end
    for _, e in ipairs(C.bumps or {}) do if IsValid(e) then e:Remove() end end
    C.bumps = {}
    local bike = IsValid(C.bike) and C.bike
    if not bike then return end
    local f = bike:GetForward() f.z = 0 f:Normalize()
    local r = f:Cross(Vector(0, 0, 1))
    local p0 = bike:GetPos()
    local x = 120
    math.randomseed(17)
    while x < 1400 do
        local e = ents.Create("prop_physics")
        e:SetModel("models/hunter/plates/plate1x3.mdl")
        local at = p0 + f * x + r * math.Rand(-10, 10)
        local g = util.TraceLine({ start = at + Vector(0, 0, 64), endpos = at - Vector(0, 0, 256), mask = MASK_SOLID_BRUSHONLY }).HitPos
        e:SetPos(g + Vector(0, 0, math.Rand(0.5, 2.5)))
        e:SetAngles(f:Angle() + Angle(math.Rand(-4, 4), 90 + math.Rand(-15, 15), math.Rand(-3, 3)))
        e:Spawn()
        local ph = e:GetPhysicsObject()
        if IsValid(ph) then ph:EnableMotion(false) end
        C.bumps[#C.bumps + 1] = e
        x = x + math.Rand(24, 40)
    end
end)

concommand.Add("camshake_done", function()
    for _, e in ipairs(C.bumps or {}) do if IsValid(e) then e:Remove() end end
    if IsValid(C.bike) then C.bike:Remove() end
    hook.Remove("Think", "camshake_wrap")
end)

hook.Add("Think", "camshake_wrap", function()
    local bike = C.bike
    if not IsValid(bike) then return end
    local p, g = bike:GetPos(), C.ground
    if math.abs(p.x - g.x) > 9000 or math.abs(p.y - g.y) > 6000 then
        local phys = bike:GetPhysicsObject()
        local v = IsValid(phys) and phys:GetVelocity()
        bike:SetPos(Vector(g.x, g.y, p.z))
        if v then phys:SetVelocity(v) end
    end
end)
print("[camshake] server half ready")
