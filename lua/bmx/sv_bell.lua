--[[--------------------------------------------------------------------------
    bmx/sv_bell.lua

    The bell. R on the ground.

      bmx_bell 0|1               the bell exists at all (server)
      bmx_bell_cooldown SECONDS  least time between rings, per bike (server)

    WHY A NET MESSAGE AND NOT bike:EmitSound. The volume a listener wants for a
    bell is THEIR setting (bmx_vol_bell, client), and a server-side sound has
    one volume for everybody. So the server only decides THAT it rang -- the
    rules, the cooldown, the mute -- and every client plays it at its own level.
    One small unreliable message per ring; nobody rings a bell sixty times a
    second, and the cooldown makes sure of it.

    THE KEY IS READ IN sv_input.lua, in one place, because R is shared: in the
    air or in a manual it belongs to the barspin (G03). This file does not know
    about that; it is asked to ring, and rings.

    A bike picks its own sound in the registry: `bell = "horn"` (any key in
    BMX.Sounds), or `bell = false` for none -- a skateboard has no bell. Absent,
    it is the bike bell.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Bell = BMX.Bell or {}

local FLAGS = bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY)

CreateConVar("bmx_bell", "1", FLAGS,
    "BMX: 1 = R rings the bike's bell; 0 = no bell.")
CreateConVar("bmx_bell_cooldown", "0.6", FLAGS,
    "BMX: seconds before the same bike's bell can ring again.")

util.AddNetworkString("bmx_bell")

-- Which sound key this bike rings, or nil for none.
function BMX.Bell.KeyFor(bike)
    local def = bike.Bike and bike:Bike() or nil
    local k = def and def.bell
    if k == false then return nil end
    k = k or "bell"
    return BMX.Sounds[k] and k or nil
end

-- Ring `bike`'s bell. Returns true if it rang. `now` is for tests.
function BMX.Bell.Ring(bike, now)
    if not IsValid(bike) then return false end
    if not GetConVar("bmx_bell"):GetBool() or not BMX.SoundsOn() then return false end
    local key = BMX.Bell.KeyFor(bike)
    if not key then return false end

    now = now or CurTime()
    -- The cooldown is per BIKE, not per player: someone hopping on and off to
    -- reset it is not a thing worth defending against, but a held key must not
    -- fire every tick, and per bike is the cheapest place to keep that.
    if now < (bike.bellNext or 0) then return false end
    bike.bellNext = now + math.max(GetConVar("bmx_bell_cooldown"):GetFloat(), 0)

    net.Start("bmx_bell", true)
        net.WriteEntity(bike)
        net.WriteString(key)
    net.Broadcast()
    return true
end
