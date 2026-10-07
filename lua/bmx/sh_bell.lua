--[[--------------------------------------------------------------------------
    bmx/sh_bell.lua

    The bell. R on the ground.

      bmx_bell 0|1               the bell exists at all (server)
      bmx_bell_cooldown SECONDS  least time between rings, per bike (server)

    WHY A NET MESSAGE AND NOT bike:EmitSound. The volume a listener wants for a
    bell is THEIR setting (bmx_vol_bell, client), and a server-side sound has
    one volume for everybody. So the server only decides THAT it rang -- the
    rules, the cooldown, the mute -- and every client plays it at its own level.
    One small unreliable message per ring.

    A BELL IS A BUTTON, SO IT ANSWERS AT ONCE. A ring decided only here reaches
    the rider a round trip after their thumb went down, and at 80 ms of ping that
    reads as a button that did not take. So the RIDER'S OWN client rings the
    moment R goes down (cl_sound.lua), under the same rules (BMX.Bell.Allowed,
    shared, below), and this message tells everybody else. The rider's client
    gets it too and drops it when it has just rung that bike itself; when it did
    not (a press it could not judge: RMB held, so maybe a manual), the server's
    ring is the one they hear.

    THE KEY IS READ IN sv_input.lua, in one place, because R is shared: in the
    air or in a manual it belongs to the barspin (G03). On the ground it is ALWAYS
    the bell, whatever else is held: it used to be swallowed while RMB was down
    (a wheelie, no manual yet), when it was neither a ring nor a barspin and the
    key seemed to do nothing.

    A bike picks its own sound in the registry: `bell = "horn"` (any key in
    BMX.Sounds), or `bell = false` for none -- a skateboard has no bell. Absent,
    it is the bike bell.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Bell = BMX.Bell or {}

-- The shortest gap between two rings of one bike. Short: a real lever bell rings
-- as fast as a thumb can flick it, and two quick presses are two rings. It only
-- has to stop a held key, or a macro, ringing every tick.
BMX.Bell.DEFAULT_COOLDOWN = 0.3

local FLAGS = bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED)

-- Created on the server only (the engine's rule for a replicated convar); the
-- client sees the server's values, so the rider's instant ring obeys them too.
if SERVER then
    CreateConVar("bmx_bell", "1", FLAGS,
        "BMX: 1 = R rings the bike's bell; 0 = no bell.")
    CreateConVar("bmx_bell_cooldown", tostring(BMX.Bell.DEFAULT_COOLDOWN), FLAGS,
        "BMX: seconds before the same bike's bell can ring again.")
end

-- Which sound key this bike rings, or nil for none.
function BMX.Bell.KeyFor(bike)
    local def = bike.Bike and bike:Bike() or nil
    local k = def and def.bell
    if k == false then return nil end
    k = k or "bell"
    return BMX.Sounds[k] and k or nil
end

function BMX.Bell.Cooldown()
    local cv = GetConVar("bmx_bell_cooldown")
    return math.max(cv and cv:GetFloat() or BMX.Bell.DEFAULT_COOLDOWN, 0)
end

-- May this bike ring at all, right now (the switches, the registry, the clock)?
-- Shared: the server's decision and the rider's own instant one are the same rule.
function BMX.Bell.Allowed(bike, now)
    if not IsValid(bike) then return false end
    local cv = GetConVar("bmx_bell")
    if cv and not cv:GetBool() then return false end
    if BMX.SoundsOn and not BMX.SoundsOn() then return false end
    if not BMX.Bell.KeyFor(bike) then return false end
    return (now or CurTime()) >= (bike.bellNext or 0)
end

if not SERVER then return end

util.AddNetworkString("bmx_bell")

-- Ring `bike`'s bell. Returns true if it rang. `now` is for tests.
function BMX.Bell.Ring(bike, now)
    now = now or CurTime()
    if not BMX.Bell.Allowed(bike, now) then return false end
    -- The cooldown is per BIKE, not per player: someone hopping on and off to
    -- reset it is not a thing worth defending against, but a held key must not
    -- fire every tick, and per bike is the cheapest place to keep that.
    bike.bellNext = now + BMX.Bell.Cooldown()

    net.Start("bmx_bell", true)
        net.WriteEntity(bike)
        net.WriteString(BMX.Bell.KeyFor(bike))
    net.Broadcast()
    return true
end
