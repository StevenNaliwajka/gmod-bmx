--[[--------------------------------------------------------------------------
    bmx/sv_menu.lua

    The server half of the /bike menu (sh_menu.lua says what it is).

    THE CHAT COMMAND opens the window on the typist's client and is swallowed,
    so "/bike" never shows in chat.

    A VEHICLE is spawned by the client running bmx_spawn, the same door the
    console uses, so the cooldown, BMX_CanSpawn, PlayerSpawnSENT and
    bmx_max_per_player all apply unchanged. Nothing for it here.

    A PARK PIECE has no console command of its own, so the click arrives as
    bmx_menu_spawn (shape, size, variant). It goes through the same doors as
    the Q menu: PlayerSpawnSENT with the piece's own class (which is where the
    park cap, bmx_park_max, and a gamemode's veto live), then an undo entry and
    PlayerSpawnedSENT.
----------------------------------------------------------------------------]]

local M = BMX.Menu
local P = BMX.Park

util.AddNetworkString(M.NET_OPEN)
util.AddNetworkString(M.NET_SPAWN)

local COOLDOWN = 0.4

hook.Add("PlayerSay", "BMX.Menu", function(ply, text)
    if not M.IsChatCommand(text) then return end
    net.Start(M.NET_OPEN)
    net.Send(ply)
    return ""
end)

-- Place one piece where `ply` is looking. Returns the entity, or nil and why.
function M.SpawnPiece(ply, shape, size, variant)
    if not IsValid(ply) then return nil, "no player" end
    if not (P and P.Shapes[shape]) then return nil, "no such piece" end
    if CurTime() < (ply.BMXNextMenuSpawn or 0) then return nil, "too fast" end
    ply.BMXNextMenuSpawn = CurTime() + COOLDOWN

    local params = P.Params(shape, { size, variant })
    local class = P.ClassName(shape, params)
    if hook.Run("PlayerSpawnSENT", ply, class) == false then return nil, "not allowed" end

    local tr = ply:GetEyeTrace()
    if not tr.Hit or tr.HitPos:Distance(ply:GetPos()) > M.REACH then
        ply:ChatPrint("[BMX] look at the ground within " .. M.REACH .. " units.")
        return nil, "out of reach"
    end

    -- Facing the way you look, so a ramp is ridden away from you.
    local ent, why = P.Place(ply, shape, params, tr.HitPos, Angle(0, ply:EyeAngles().y, 0))
    if not ent then
        ply:ChatPrint("[BMX] " .. tostring(why))
        return nil, why
    end

    undo.Create("BMX Park")
        undo.AddEntity(ent)
        undo.SetPlayer(ply)
    undo.Finish()
    hook.Run("PlayerSpawnedSENT", ply, ent)
    return ent
end

net.Receive(M.NET_SPAWN, function(_, ply)
    local shape   = net.ReadString()
    local size    = net.ReadUInt(4)
    local variant = net.ReadUInt(4)
    M.SpawnPiece(ply, shape, size, variant)
end)
