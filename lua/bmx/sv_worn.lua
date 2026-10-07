--[[--------------------------------------------------------------------------
    bmx/sv_worn.lua

    WORN VEHICLES, THE PLATFORM'S SIDE (G25). Every vehicle until the skates was an
    entity with a seat. A worn one is not: the player is the chassis, nothing is
    spawned, and what a vehicle IS to the platform -- a registry entry, a state, an
    input map, a trick list, scoring, combos -- has to work with no entity at all.
    This file is that, and nothing about skates in particular:

        BMX.Worn.Equip(ply, id)     put a player into a worn vehicle
        BMX.Worn.Unequip(ply)       and out of it
        BMX.Worn.Of(ply)            the wearer's state, or nil
        BMX.WornModes[name]         a mode's functions (below), named by a registration's
                                    `balance`, as a sat-in vehicle's balance mode is

    A MODE is a table of four functions, each handed the player and the wearer's
    state `w` (w.def the registration, w.st the controller state the platform's trick
    and combo code reads, w.input what the rider is pressing):

        Decode(ply, w, cmd)         once per usercmd: read the keys into w.input
        Setup(ply, w, mv, dt)       once per movement tick, before the engine moves
                                    the player: feed the player's velocity to the
                                    simulation and write what it says back
        Move(ply, w, mv, dt)        return true to take the movement over entirely (a
                                    grind sets the position itself)
        Equip(ply, w) / Unequip(ply, w)     the mode's own set-up and tear-down

    THE WEARER STANDS IN FOR THE ENTITY. The scoring (ENT:AwardTricks), the combo chain
    (sv_combo.lua) and the trick tracking (sv_tricks.lua) take an entity and ask it for
    its state (`st`), its config (`Cfg`), its registration (`Bike`), its rider (`GetDriver`)
    and its score. `w.proxy` is a plain table that answers all of those from the
    wearer, so the one scoring path is the only one: a trick on skates pays, builds a
    combo, fires BMX_TrickLanded and shows a callout exactly as a bike's does. The
    player's score is the networked int "BMXWornScore".

    WHAT ENDS IT. Death, leaving the server, getting into a vehicle, the vehicle being
    switched off (bmx_allow_boards 0), and holstering (the mode's SWEP). None of them
    needs the mode's help.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Worn = BMX.Worn or {}
BMX.WornModes = BMX.WornModes or {}
local W = BMX.Worn

-- The wearer's state, or nil when the player is not wearing anything.
function W.Of(ply)
    return IsValid(ply) and ply.BMXWorn or nil
end

--------------------------------------------------------------------------
-- THE STAND-IN FOR THE ENTITY. A table with the handful of methods the scoring and the
-- combo code call on a vehicle. (It is not an Entity and says so: IsValid is false, which
-- is what keeps a listener from treating it as one; the hooks that take a vehicle
-- are handed the PLAYER, below.)
--------------------------------------------------------------------------
local function newProxy(ply, def, st)
    local P = { st = st, IsWornProxy = true }
    function P:Bike() return def end
    function P:Cfg() return BMX.ConfigFor(def) end
    function P:GetDriver() return ply end
    function P:GetScore() return IsValid(ply) and ply:GetNWInt("BMXWornScore", 0) or 0 end
    function P:SetScore(v) if IsValid(ply) then ply:SetNWInt("BMXWornScore", v) end end

    -- ENT:AwardTricks (entities/bmx_base/init.lua), for a player. The same rules: scoring
    -- off pays nothing; the vehicle's multiplier on a copy of the list; one public
    -- BMX_TrickLanded a trick, with the wearer where a bike's call has its entity.
    function P:AwardTricks(tricks)
        if BMX.ScoringEnabled and not BMX.ScoringEnabled() then return 0 end
        local mult = def.scoreMult or 1
        if mult ~= 1 then
            local scaled = {}
            for i, t in ipairs(tricks) do
                local c = {}
                for k, v in pairs(t) do c[k] = v end
                c.points = math.floor((t.points or 0) * mult + 0.5)
                scaled[i] = c
            end
            tricks = scaled
        end
        local total = 0
        for _, t in ipairs(tricks) do total = total + (t.points or 0) end
        if total <= 0 then return 0 end
        self:SetScore(self:GetScore() + total)
        if IsValid(ply) then
            for _, t in ipairs(tricks) do hook.Run("BMX_TrickLanded", ply, t, t.points or 0, ply) end
        end
        hook.Run("BMX_TricksLanded", ply, ply, tricks, total)
        self:SendTrickCallout(tricks, total)
        if BMX.ComboAdd then BMX.ComboAdd(self, tricks) end
        return total
    end

    function P:SendTrickCallout(tricks, total)
        if not IsValid(ply) then return end
        net.Start("bmx_tricks", true)
            net.WriteUInt(math.min(#tricks, 7), 3)
            for i = 1, math.min(#tricks, 7) do
                net.WriteString(tricks[i].name)
                net.WriteUInt(math.min(tricks[i].count or 1, 15), 4)
                net.WriteUInt(math.min(tricks[i].points or 0, 65535), 16)
            end
            net.WriteUInt(math.min(total, 1048575), 20)
        net.Send(ply)
    end
    return P
end

--------------------------------------------------------------------------
-- EQUIPPING.
--------------------------------------------------------------------------
-- Put `ply` into the worn vehicle `id`. Returns the wearer's state, or nil and why: not a
-- worn vehicle, switched off by the server, or already wearing something.
function W.Equip(ply, id)
    if not IsValid(ply) or not ply:IsPlayer() then return nil, "no player" end
    id = string.lower(id or "")
    local def = BMX.Vehicles[id]
    if not (def and def.worn) then return nil, "not a worn vehicle" end
    local mode = BMX.WornModes[def.balance]
    if not mode then return nil, "no mode for " .. tostring(def.balance) end
    if ply.BMXWorn then
        if ply.BMXWorn.id == id then return ply.BMXWorn end
        return nil, "already wearing " .. ply.BMXWorn.id
    end
    if BMX.VehicleEnabled and not BMX.VehicleEnabled(id) then
        return nil, string.lower(BMX.Families[def.family].category) .. " are switched off on this server (bmx_allow_" ..
            BMX.Families[def.family].key .. " 0)"
    end
    if ply:InVehicle() then return nil, "get out of the vehicle first" end

    local st = BMX.NewState(BMX.ConfigFor(def))
    st.def = def
    local w = { id = id, def = def, mode = mode, st = st, input = {}, since = CurTime() }
    w.proxy = newProxy(ply, def, st)
    ply.BMXWorn = w
    ply:SetNWString("BMXWorn", id)
    if mode.Equip then mode.Equip(ply, w) end
    hook.Run("BMX_WornEquipped", ply, id)
    return w
end

-- Take it off: the combo closes (landed: they chose to stop), the mode tears down.
function W.Unequip(ply)
    local w = IsValid(ply) and ply.BMXWorn
    if not w then return false end
    if w.st.combo and BMX.ComboEnd then BMX.ComboEnd(w.proxy, true) end
    if w.mode.Unequip then w.mode.Unequip(ply, w) end
    ply.BMXWorn = nil
    ply:SetNWString("BMXWorn", "")
    hook.Run("BMX_WornHolstered", ply, w.id)
    return true
end

--------------------------------------------------------------------------
-- THE HOOKS. One of each, for every mode.
--------------------------------------------------------------------------
hook.Add("StartCommand", "BMX.Worn.Input", function(ply, cmd)
    local w = ply.BMXWorn
    if not w or ply.BMXScripted then return end      -- a scripted wearer writes w.input itself
    if w.mode.Decode then w.mode.Decode(ply, w, cmd) end
end)

hook.Add("SetupMove", "BMX.Worn.Setup", function(ply, mv, cmd)
    local w = ply.BMXWorn
    if not w then return end
    -- Not while the engine owns the player: a vehicle, a ladder, noclip, a ragdoll tumble.
    if ply:InVehicle() or ply.BMXTumbling or ply:GetMoveType() ~= MOVETYPE_WALK or not ply:Alive() then
        w.inactive = true
        return
    end
    -- bmx_allow_* switched off under them.
    if BMX.VehicleEnabled and not BMX.VehicleEnabled(w.id) then
        W.Unequip(ply)
        return
    end
    w.inactive = false
    w.mode.Setup(ply, w, mv, FrameTime())
end)

hook.Add("Move", "BMX.Worn.Move", function(ply, mv)
    local w = ply.BMXWorn
    if not w or w.inactive or not w.mode.Move then return end
    return w.mode.Move(ply, w, mv, FrameTime())
end)

local function drop(ply)
    if IsValid(ply) and ply.BMXWorn then W.Unequip(ply) end
end
-- A wearer's boots are not footsteps: the engine's step sounds would play at the skater's
-- speed, as a running player's. (The client's copy is cl_skates.lua.)
hook.Add("PlayerFootstep", "BMX.Worn.Quiet", function(ply)
    if ply.BMXWorn then return true end
end)

hook.Add("PlayerDeath", "BMX.Worn.Death", drop)
hook.Add("PlayerDisconnected", "BMX.Worn.Gone", drop)
hook.Add("PlayerEnteredVehicle", "BMX.Worn.Vehicle", drop)

--------------------------------------------------------------------------
-- bmx_spawn <worn id>, from the console and the /bike window, equips: there is nothing to
-- put on the ground, so the way to "spawn" skates is to be given them. It goes through
-- the same doors a spawn does (BMX_CanSpawn, bmx_allow_boards), and the SWEP that
-- carries the vehicle is the mode's (`Give`).
--------------------------------------------------------------------------
function W.Give(ply, id)
    local def = BMX.Vehicles[string.lower(id or "")]
    if not (IsValid(ply) and def and def.worn) then return false end
    local mode = BMX.WornModes[def.balance]
    local class = mode and mode.Weapon
    if not class then return false end
    if hook.Run("BMX_CanSpawn", ply, def.id) == false then return false end
    if not BMX.VehicleEnabled(def.id) then
        ply:ChatPrint("[BMX] " .. string.lower(BMX.Families[def.family].category) ..
            " are switched off on this server (bmx_allow_" .. BMX.Families[def.family].key .. " 0).")
        return false
    end
    if not ply:HasWeapon(class) then ply:Give(class) end
    ply:SelectWeapon(class)
    return true
end
