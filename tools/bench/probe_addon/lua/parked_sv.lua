-- 8 parked vehicles of mixed kinds in front of the player (tools/bench/sp.sh parked).
PARKED = PARKED or {}
for _, e in ipairs(PARKED) do if IsValid(e) then e:Remove() end end
PARKED = {}
local o = player.GetHumans()[1]
local base = Vector(4000, 4000, -11000)
local tr = util.TraceLine({ start = base, endpos = base - Vector(0, 0, 3000), mask = MASK_SOLID_BRUSHONLY })
local g = tr.HitPos
o:SetPos(g + Vector(-300, 0, 8)) o:SetEyeAngles(Angle(10, 0, 0))
for i, id in ipairs(PARKED_IDS or { "stock", "road", "dirtbike", "emoto", "scooter", "tandem", "penny", "dh" }) do
    local b = ents.Create(BMX.ClassFor(id))
    b:SetPos(g + Vector(0, (i - 4.5) * 70, 14)) b:SetAngles(Angle(0, 90, 0))
    b:Spawn() b:Activate()
    PARKED[#PARKED + 1] = b
end
