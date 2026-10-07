--[[--------------------------------------------------------------------------
    bmx/sv_compat_ragmod.lua

    RagMod, if the server has it.

    WHAT IT IS FOR. A player who installed RagMod or RagMod Reworked did it for
    ITS ragdoll: its grab, its get-up, its look. When they go over the bars on a
    bike they should get that one, not our own tumble (BMX.Tumble, sv_seat.lua),
    which stays as the fallback for everyone without it. The crash path
    (ENT:Crash in entities/bmx_base/init.lua) calls BMX.Compat.Ragdoll first.

    NOTHING HERE MAY THROW. RagMod's API is not documented or stable (the
    original and Reworked do not agree, and either may change under an update),
    so every call into it is a pcall, and ANY failure -- missing, errored,
    returned false -- hands back false and the caller uses our own ragdoll. A
    crash that ends in a Lua error and a rider stuck standing in mid-air is a
    far worse outcome than "it used our ragdoll instead".

    WHAT WE CALL, pinned here so that when RagMod changes it is one edit:

        a global table named one of GLOBALS (ragmod / RagMod / Ragmod / RAGMOD)
        holding a function named one of ENTRIES, called as tbl.fn(ply) and, if
        that throws, as tbl:fn(ply) (the colon-style form of the same API).

    These names were chosen from how the two addons are written about, NOT
    from a copy of their source; nobody on this project has had RagMod on a
    test server yet. G07's manual test (crash once with RagMod Reworked
    installed) is what turns this guess into a fact. Until then the fallback
    is what players get, which is no worse than before this file existed.

    THE VELOCITY is set on every physics bone of the ragdoll the call returns
    (or, failing that, the one the player entity reports), so the rider is
    thrown the way our own ragdoll throws them.

    bmx_ragmod 0 (server) turns the whole thing off.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Compat = BMX.Compat or {}

CreateConVar("bmx_ragmod", "1", bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY),
    "Hand crashed riders to RagMod / RagMod Reworked when it is installed (0 = always use the built-in tumble).")

local GLOBALS = { "ragmod", "RagMod", "Ragmod", "RAGMOD" }
local ENTRIES = { "Ragdollize", "Ragdollise", "RagdollPlayer", "MakeRagdoll",
                  "PlayerRagdoll", "EnableRagdoll", "Ragdoll" }

-- The detected entry point: { name = "ragmod.Ragdollize", tbl = t, fn = f }, or nil.
BMX.Compat.RagMod = nil

-- Look for RagMod. Safe to call again; InitPostEntity runs it once, after every
-- addon has loaded (load order between addons is not ours to rely on).
function BMX.Compat.DetectRagMod()
    BMX.Compat.RagMod = nil
    for _, g in ipairs(GLOBALS) do
        local t = _G[g]
        if type(t) == "table" then
            for _, e in ipairs(ENTRIES) do
                if type(t[e]) == "function" then
                    BMX.Compat.RagMod = { name = g .. "." .. e, tbl = t, fn = t[e] }
                    return BMX.Compat.RagMod
                end
            end
        end
    end
    return nil
end

hook.Add("InitPostEntity", "BMX.DetectRagMod", function()
    local r = BMX.Compat.DetectRagMod()
    -- Silent when absent: it is the normal case, and the loader's "loaded" line
    -- is meant to stay the last thing the addon prints at startup.
    if r then MsgN("[BMX] RagMod found (", r.name, "): crashes hand the rider to it") end
end)

local warned = false
local function complain(err)
    -- Once, not on every crash: a broken adapter should be visible without
    -- turning every fall into console spam.
    if warned then return end
    warned = true
    ErrorNoHalt("[BMX] RagMod call failed (" .. tostring(err) ..
        "); falling back to the built-in tumble. Set bmx_ragmod 0 to silence this.\n")
end

local function throwRagdoll(rag, vel)
    if not IsValid(rag) or not rag.GetPhysicsObjectCount then return end
    for i = 0, rag:GetPhysicsObjectCount() - 1 do
        local po = rag:GetPhysicsObjectNum(i)
        if IsValid(po) then po:SetVelocity(vel) end
    end
end

-- Returns true when RagMod took the rider (the caller then does NOT make its
-- own ragdoll), false for "do it yourself".
function BMX.Compat.Ragdoll(ply, vel)
    local cv = GetConVar("bmx_ragmod")
    if cv and not cv:GetBool() then return false end
    local r = BMX.Compat.RagMod
    if not r or not IsValid(ply) then return false end

    local ok, res = pcall(r.fn, ply)
    if not ok then
        -- Colon-style API: tbl:fn(ply) is tbl.fn(tbl, ply).
        ok, res = pcall(r.fn, r.tbl, ply)
    end
    if not ok then complain(res) return false end
    if res == false then return false end

    local rag = res
    if type(rag) ~= "table" and type(rag) ~= "userdata" then rag = nil end
    if not (rag and IsValid(rag)) and ply.GetRagdollEntity then
        local ok2, e = pcall(ply.GetRagdollEntity, ply)
        rag = ok2 and e or nil
    end
    local ok3, err3 = pcall(throwRagdoll, rag, vel or Vector())
    if not ok3 then complain(err3) end
    return true
end
