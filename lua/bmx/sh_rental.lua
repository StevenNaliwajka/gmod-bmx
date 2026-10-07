--[[--------------------------------------------------------------------------
    bmx/sh_rental.lua

    THE BIKE RENTAL: a vending machine (entity bmx_rental) that hands out any
    vehicle for free. Walk up, press E, click a picture, and you are on it. No
    console, no Q menu, no chat command: a player who has never heard of /bike
    can still ride. A map puts the machines where people spawn
    (petopia_bmx_fall does); an admin can put more down with `ent_create bmx_rental`.

    ONE RENTAL EACH. Renting again returns the last one first, so a player can
    swap vehicles as often as they like and the park never fills with them.
    A rental nobody is riding goes back by itself after R.IDLE seconds, and it
    goes back when its renter leaves the server.

    It goes through the same doors as every other way of getting a vehicle
    (BMX_CanSpawn, the bmx_allow_* switches, the debug-only rule), but not
    sandbox's PlayerSpawnSENT: the rental is the machine's, not the player's
    spawn budget, which is the point on a server whose gamemode has no Q menu.

        sv_rental.lua  renting, returning, the idle sweep
        cl_rental.lua  the window
        entities/bmx_rental  the machine
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Rental = BMX.Rental or {}
local R = BMX.Rental

R.NET_OPEN = "bmx_rental_open"   -- server -> client: open the window for this machine
R.NET_RENT = "bmx_rental_rent"   -- client -> server: this machine, this vehicle

R.Model    = "models/props_interiors/vendingmachinesoda01a.mdl"
R.REACH    = 160    -- u: how close to the machine a rent is honoured
R.BAY      = 40     -- u: how far in front of the machine's face the vehicle appears
R.IDLE     = 90     -- s: an empty rental is returned after this long
R.COOLDOWN = 2      -- s: between two rents by one player

-- Where a machine's vehicle appears, and which way it faces: in front of the
-- machine's face (its +X side), on the floor it stands on, lying across its
-- front so the renter is standing beside it.
function R.Bay(machine)
    local mn, mx = machine:OBBMins(), machine:OBBMaxs()
    local pos = machine:LocalToWorld(Vector(mx.x + R.BAY, 0, mn.z))
    local ang = machine:GetAngles()
    return pos, Angle(0, ang.y + 90, 0)
end

-- What the machine offers: the vehicle tabs of the /bike window (every
-- visible vehicle, worn ones too, each with its picture), not the park.
function R.Catalog()
    local out = {}
    for _, sec in ipairs(BMX.Menu.Catalog()) do
        if sec.kind == "vehicle" then out[#out + 1] = sec end
    end
    return out
end
