--[[--------------------------------------------------------------------------
    bmx/sv_rules.lua

    What a server owner can decide without touching the code.

      bmx_max_per_player N   bikes one player may have out at once, 0 = no
                             limit of our own (sbox_maxsents still applies).
                             Counted across every kind of bike.
      bmx_scoring 0|1        tricks score at all: points, callouts, combos.
      bmx_combos  0|1        tricks chain into combos for a bonus.

    THE LIMIT IS A PlayerSpawnSENT HOOK, not a check in bmx_spawn, because that
    hook is the one door every spawn goes through: the spawn menu, bmx_spawn
    (which asks it on purpose, see sv_seat.lua) and admin mods that wrap it. A
    check in only one of them is a limit you walk round by spawning the other
    way. It only ever says no: a nil return leaves the gamemode's own
    sbox_maxsents and any admin mod's verdict exactly as they were.

    SCORING AND COMBOS ARE NOT IN C.ConVars, though they look like they belong
    there. That plumbing stores a convar's FLOAT into the config, and these
    gate on a boolean: 0 is true in Lua, so `bmx_combos 0` would have turned
    combos on.
----------------------------------------------------------------------------]]

BMX = BMX or {}

-- REPLICATED so the Options > BMX > Server panel can show every player (and an
-- admin) what the server is using; changing them still only happens on the
-- server, through sv_settings.lua.
local FLAGS = bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED)

local maxPer  = CreateConVar("bmx_max_per_player", "0", FLAGS,
    "BMX: bikes one player may have spawned at once (0 = no BMX limit; sbox_maxsents still applies).")
local scoring = CreateConVar("bmx_scoring", "1", FLAGS,
    "BMX: 1 = tricks score points, callouts and combos; 0 = no scoring at all.")
local combos  = CreateConVar("bmx_combos", "1", FLAGS,
    "BMX: 1 = chained tricks build a combo that pays a bonus when landed; 0 = off.")

function BMX.ScoringEnabled() return scoring:GetBool() end
function BMX.CombosEnabled() return scoring:GetBool() and combos:GetBool() end

-- Is this entity class one of ours?
local function isBikeClass(class)
    for _, id in ipairs(BMX.BikeIDs()) do
        if BMX.ClassFor(id) == class then return true end
    end
    return false
end
BMX.IsBikeClass = isBikeClass

-- The bikes this player has out right now.
function BMX.BikesOwnedBy(ply)
    local n = 0
    for _, id in ipairs(BMX.BikeIDs()) do
        for _, e in ipairs(ents.FindByClass(BMX.ClassFor(id))) do
            if e.BMXOwner == ply then n = n + 1 end
        end
    end
    return n
end

hook.Add("PlayerSpawnSENT", "BMX.Limit", function(ply, class)
    if not isBikeClass(class) then return end
    local limit = maxPer:GetInt()
    if limit <= 0 or not IsValid(ply) then return end
    if BMX.BikesOwnedBy(ply) >= limit then
        ply:ChatPrint(string.format("[BMX] you already have %d bike%s out " ..
            "(bmx_max_per_player %d). Remove one first.",
            limit, limit == 1 and "" or "s", limit))
        return false
    end
end)

-- Whoever spawned it owns it, by either door. Set here rather than in
-- bmx_spawn so a bike from the spawn menu is counted too.
hook.Add("PlayerSpawnedSENT", "BMX.Owner", function(ply, ent)
    if IsValid(ent) and ent.IsBMX then ent.BMXOwner = ply end
end)
