--[[--------------------------------------------------------------------------
    bmx/sh_permissions.lua

    WHO MAY DO WHAT, through CAMI.

    CAMI is the common permissions interface that ULX, SAM, Serverguard, Helix
    and the rest implement. If one of them is installed, a server owner gives
    their moderators exactly the BMX powers they want in that tool's own
    screen. If none is, every privilege falls back to the plain admin check its
    default asks for, which is what the addon did before.

    THE PRIVILEGES, and who has them unless told otherwise:

        BMX - Change Server Settings   superadmin   the Server panel, bmx_reset_server
        BMX - Physgun Ridden           admin        pick up a bike with a rider on it
        BMX - Spawn Motor Vehicles     admin        engines (nothing uses it yet)
        BMX - Remove Any Bike          admin        remove other people's bikes (nothing uses it yet)
        BMX - Unlock Any Lock          admin        unlock a bike someone else locked (weapon_bmx_lock)
        BMX - Build Parks              admin        bmx_park_save / _load / _preset / _clear

    The two marked "nothing uses it yet" belong to goals that have not been
    built. They are registered now so a server owner's permission setup does
    not change when those land, and so those goals only have to call BMX.Can.
    (The bike lock, G13, is the first to: BMX.Lock.CanUnlock, sv_lock.lua.)

    BMX.Can(ply, name) IS THE ONE QUESTION. Everything that gates on a
    privilege asks it, so no caller knows about CAMI. A player of NULL or nil is
    the server console, which may do anything.

    CAMI CAN ANSWER LATE. Its callback style allows an admin mod to look a
    group up from a database and answer a frame later. A hook that has to say
    yes or no this instant cannot wait, so Can only trusts an answer that
    arrives before PlayerHasAccess returns, and otherwise falls back to the
    default. ULX, SAM and CAMI's own built-in fallback all answer immediately.

    REGISTRATION IS RETRIED at InitPostEntity, because autorun files load in
    no promised order and CAMI may arrive after this one.
----------------------------------------------------------------------------]]

BMX = BMX or {}

BMX.Privileges = {
    { name = "BMX - Change Server Settings", min = "superadmin",
      desc = "Change BMX server settings in the Options menu or with bmx_reset_server." },
    { name = "BMX - Physgun Ridden", min = "admin",
      desc = "Pick up a bike with a rider on it using the physgun." },
    { name = "BMX - Spawn Motor Vehicles", min = "admin",
      desc = "Spawn motorised vehicles." },
    { name = "BMX - Remove Any Bike", min = "admin",
      desc = "Remove bikes that belong to other players." },
    { name = "BMX - Unlock Any Lock", min = "admin",
      desc = "Unlock bikes that other players have locked." },
    { name = "BMX - Build Parks", min = "admin",
      desc = "Save, load, build a preset and clear the park pieces (bmx_park_*)." },
}

local BY_NAME = {}
for _, p in ipairs(BMX.Privileges) do BY_NAME[p.name] = p end

-- A privilege from outside the addon (the BMX (Mode) gamemode's "BMX - Bot",
-- say), checked with BMX.Can like the addon's own. Registered with CAMI now if
-- CAMI is up, and at InitPostEntity with the rest otherwise. Adding a name
-- again replaces it, so a Lua reload is harmless.
function BMX.AddPrivilege(p)
    assert(isstring(p.name) and isstring(p.min) and isstring(p.desc), "BMX.AddPrivilege{ name, min, desc }")
    if BY_NAME[p.name] then
        for i, q in ipairs(BMX.Privileges) do if q.name == p.name then BMX.Privileges[i] = p end end
    else
        BMX.Privileges[#BMX.Privileges + 1] = p
    end
    BY_NAME[p.name] = p
    if CAMI and CAMI.RegisterPrivilege and BMX._camiRegistered == CAMI then
        CAMI.RegisterPrivilege({ Name = p.name, MinAccess = p.min, Description = p.desc })
    end
    return p
end

-- Register with whichever CAMI is loaded. Safe to call again; it registers
-- once per CAMI table, so a late CAMI is picked up and a repeat is free.
function BMX.RegisterPrivileges()
    if not CAMI or not CAMI.RegisterPrivilege then return false end
    if BMX._camiRegistered == CAMI then return true end
    for _, p in ipairs(BMX.Privileges) do
        CAMI.RegisterPrivilege({ Name = p.name, MinAccess = p.min, Description = p.desc })
    end
    BMX._camiRegistered = CAMI
    return true
end

-- The answer with no admin mod to ask.
local function fallback(ply, min)
    if min == "superadmin" then return ply:IsSuperAdmin() end
    return ply:IsAdmin()
end

function BMX.Can(ply, name)
    local p = BY_NAME[name]
    if not p then
        ErrorNoHalt("[BMX] BMX.Can: unknown privilege '" .. tostring(name) .. "'\n")
        return false
    end
    if ply == nil or not IsValid(ply) then return true end       -- the server console

    if CAMI and CAMI.PlayerHasAccess then
        BMX.RegisterPrivileges()
        local answer
        CAMI.PlayerHasAccess(ply, name, function(ok) answer = ok end)
        if answer ~= nil then return answer and true or false end
    end
    return fallback(ply, p.min) and true or false
end

-- A wrapper, not the function itself: a hook that RETURNS a value stops every
-- other InitPostEntity hook after it, and RegisterPrivileges returns a boolean.
hook.Add("InitPostEntity", "BMX.RegisterPrivileges", function() BMX.RegisterPrivileges() end)
BMX.RegisterPrivileges()
