--[[--------------------------------------------------------------------------
    bmx/sv_board_carry.lua

    CARRYING A BOARD (G23 M4): weapon_bmx_board is the board under your arm. Left
    mouse puts it down on the ground in front of you, ready to ride; the console
    command bmx_pickup_board (bind it) picks one up. It is how skaters actually carry one, and it means a player is not
    spawning a new entity for every trip to the park.

    A CARRIED BOARD COUNTS. It is one of the player's boards for
    bmx_max_per_player (BMX.BikesOwnedBy, sv_rules.lua, counts the SWEP), so the
    limit is about boards a player has, not boards that happen to be on the floor.
    Dropping one goes through the same doors every spawn does: BMX_CanSpawn and
    PlayerSpawnSENT, which is where bmx_allow_boards and the limit live. The SWEP is
    taken from the player first, so the limit does not count the board twice, and
    given back if a door says no.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.BoardCarry = BMX.BoardCarry or {}
local C = BMX.BoardCarry

C.Class = "weapon_bmx_board"
local VEHICLE = "skateboard"

-- Put the player's carried board down: returns the entity, or nil if it was not
-- allowed (the SWEP stays in hand).
function C.Drop(ply)
    if not IsValid(ply) or not ply:HasWeapon(C.Class) then return nil end
    local class = BMX.ClassFor(VEHICLE)
    if not class then return nil end

    ply:StripWeapon(C.Class)
    local denied = hook.Run("BMX_CanSpawn", ply, VEHICLE) == false
        or hook.Run("PlayerSpawnSENT", ply, class) == false
    if denied then
        ply:Give(C.Class)
        return nil
    end

    -- Where the player is looking, if that is close; else just in front of them.
    local tr = ply:GetEyeTrace()
    local at, normal
    if tr and tr.Hit and tr.HitPos:Distance(ply:GetPos()) <= 160 then
        at, normal = tr.HitPos, tr.HitNormal or Vector(0, 0, 1)
    else
        local yaw = ply:EyeAngles().y
        local ahead = ply:GetPos() + Angle(0, yaw, 0):Forward() * 60
        local down = util.TraceLine({ start = ahead + Vector(0, 0, 40), endpos = ahead - Vector(0, 0, 200),
            filter = ply, mask = MASK_SOLID })
        at, normal = down.Hit and down.HitPos or ahead, down.Hit and down.HitNormal or Vector(0, 0, 1)
    end

    local ent = ents.Create(class)
    if not IsValid(ent) then
        ply:Give(C.Class)
        return nil
    end
    ent:SetPos(at + normal * (BMX.RestHeight(ent:Cfg()) + 0.5))
    ent:SetAngles(Angle(0, ply:EyeAngles().y, 0))
    ent:Spawn()
    ent:Activate()
    hook.Run("PlayerSpawnedSENT", ply, ent)
    if BMX.PaintAsPreferred then BMX.PaintAsPreferred(ent, ply) end
    return ent
end

-- Pick a board up: it goes back under the player's arm. Only a board nobody is
-- on, that is theirs or nobody's, within reach.
function C.PickUp(ply, ent)
    if not IsValid(ply) or not IsValid(ent) or not ent.IsBMX then return false end
    if ent:Bike().id ~= VEHICLE or IsValid(ent:GetDriver()) then return false end
    if IsValid(ent.BMXOwner) and ent.BMXOwner ~= ply then return false end
    if ent:GetPos():Distance(ply:GetPos()) > 200 then return false end
    if ply:HasWeapon(C.Class) then return false end
    SafeRemoveEntity(ent)
    ply:Give(C.Class)
    return true
end

-- The board the player is aiming at, within reach.
function C.Aimed(ply)
    local tr = ply:GetEyeTrace()
    local e = tr and tr.Entity
    if IsValid(e) and e.IsBMX and e:Bike().id == VEHICLE then return e end
    local best, bd = nil, 150
    for _, b in ipairs(ents.FindByClass(BMX.ClassFor(VEHICLE))) do
        local d = b:GetPos():Distance(ply:GetPos())
        if d < bd and (not IsValid(b.BMXOwner) or b.BMXOwner == ply) then best, bd = b, d end
    end
    return best
end

-- bmx_give_board: the board under your arm, without the Weapons tab.
concommand.Add("bmx_give_board", function(ply)
    if not IsValid(ply) or ply:HasWeapon(C.Class) then return end
    local class = BMX.ClassFor(VEHICLE)
    if hook.Run("BMX_CanSpawn", ply, VEHICLE) == false then return end
    if hook.Run("PlayerSpawnSENT", ply, class) == false then return end
    ply:Give(C.Class)
end)

concommand.Add("bmx_pickup_board", function(ply)
    if not IsValid(ply) then return end
    local e = C.Aimed(ply)
    if e then C.PickUp(ply, e) end
end)
