--[[--------------------------------------------------------------------------
    bmx/sv_rules.lua

    What a server owner can decide without touching the code.

      bmx_max_per_player N   bikes one player may have out at once, 0 = no
                             limit of our own (sbox_maxsents still applies).
                             Counted across every kind of bike.
      bmx_scoring 0|1        tricks score at all: points, callouts, combos.
      bmx_combos  0|1        tricks chain into combos for a bonus.
      bmx_nose_manual 0|1    the nose manual: rolling on the front wheel (G02).
                             Off by default until it has been ridden live.
      bmx_air_assist 0|1     the air turn, landing aim and spine transfer off a
                             vert ramp (G06).

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

-- AIR ASSIST (G06): the turn off a vert ramp, the landing aim and the spine
-- transfer (sv_air.lua, VertAir). Off leaves the air exactly as it was before
-- them: A/D roll, nothing aims the landing.
local airAssist = CreateConVar("bmx_air_assist", "1", FLAGS,
    "BMX: 1 = A/D turn the bike round off a vert ramp, the landing aims back down it and a W press carries a spine transfer; 0 = off.")
function BMX.AirAssistOn() return airAssist:GetBool() end

-- THE NOSE MANUAL (G02): rolling on the front wheel after the brake comes off,
-- weight still forward (sv_balance.lua, PitchControl). It touches the pitch
-- controller every rider uses, so it stays OFF until it has been ridden on a real
-- server: with it off, leaning forward only shifts the weight and a stoppie ends
-- when the brake does, exactly as before.
local noseManual = CreateConVar("bmx_nose_manual", "0", FLAGS,
    "BMX: 1 = lean forward (LMB + Ctrl) and let go of the brake to hold a nose manual; 0 = no nose manual.")
function BMX.NoseManualOn() return noseManual:GetBool() end

-- VEHICLES SWITCHED ON AND OFF, per spawn menu heading (G22): bmx_allow_bikes,
-- _boards, _scooters, _motor, one per BMX.SpawnCategories entry, described in
-- sh_settings.lua's Vehicles group. REPLICATED like the rest, so the panel can
-- show everyone what the server allows.
local allow = {}
for _, c in ipairs(BMX.SpawnCategories) do
    allow[c.key] = CreateConVar("bmx_allow_" .. c.key, "1", FLAGS,
        "BMX: 1 = players may spawn " .. string.lower(c.label) .. "; 0 = they may not.")
end

-- May this vehicle id be spawned right now? Asked by bmx_spawn and the spawn
-- menu door (below) alike; the hook BMX_CanSpawn stays the gamemode's own veto
-- on top of it.
function BMX.VehicleEnabled(id)
    local def = BMX.Vehicles[string.lower(id or "")]
    local fam = def and BMX.Families[def.family]
    local cv = fam and allow[fam.key]
    return cv == nil or cv:GetBool()
end

-- Which registered vehicle an entity class is, or nil.
function BMX.IdForClass(class)
    for _, id in ipairs(BMX.VehicleIDs()) do
        if BMX.ClassFor(id) == class then return id end
    end
end

-- A debug-only vehicle (the test cart) is spawned only by someone with the
-- overlay on: bmx_debug is a client convar, which the server reads as the
-- player's own info.
function BMX.DebugAllowed(def, ply)
    if not def or not def.debugOnly then return true end
    return IsValid(ply) and ply:GetInfoNum("bmx_debug", 0) >= 1
end

function BMX.ScoringEnabled() return scoring:GetBool() end
function BMX.CombosEnabled() return scoring:GetBool() and combos:GetBool() end

-- Is this entity class one of ours?
local function isBikeClass(class)
    return BMX.IdForClass(class) ~= nil
end
BMX.IsBikeClass = isBikeClass

-- The bikes this player has out right now. Every vehicle counts, the hidden ones
-- included: the limit is about what a player has spawned, not what the menu lists.
function BMX.BikesOwnedBy(ply)
    local n = 0
    for _, id in ipairs(BMX.VehicleIDs()) do
        for _, e in ipairs(ents.FindByClass(BMX.ClassFor(id))) do
            if e.BMXOwner == ply then n = n + 1 end
        end
    end
    return n
end

-- THE SPAWN MENU'S DOOR for the vehicle switches and the debug-only rule: the
-- spawn menu and `gm_spawnsent` go through PlayerSpawnSENT, not through
-- bmx_spawn, so a toggle that only bmx_spawn honoured would be a toggle with a
-- hole in it.
hook.Add("PlayerSpawnSENT", "BMX.Enabled", function(ply, class)
    local id = BMX.IdForClass(class)
    if not id then return end
    if not BMX.VehicleEnabled(id) then
        if IsValid(ply) then ply:ChatPrint("[BMX] " .. string.lower(BMX.Families[BMX.Vehicles[id].family].category) ..
            " are switched off on this server (bmx_allow_" .. BMX.Families[BMX.Vehicles[id].family].key .. " 0).") end
        return false
    end
    if not BMX.DebugAllowed(BMX.Vehicles[id], ply) then
        if IsValid(ply) then ply:ChatPrint("[BMX] " .. id .. " is a debug vehicle: set bmx_debug 1 to spawn it.") end
        return false
    end
end)

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
