--[[--------------------------------------------------------------------------
    bmx/sv_gears.lua

    CHANGING GEAR (G09). The model is sh_gears.lua; this is the one way the gear
    on a bike changes while somebody rides it.

    THE KEYS ARE THE CLIENT'S. [ and ] and the mouse wheel are not usercmd bits
    (the usercmd carries IN_ buttons and the wheel as an axis the engine already
    spends on the weapon switch), so the client sees the press (cl_gears.lua) and
    sends one small message: up or down. Everything that matters is decided HERE:
    the sender must be the rider of a bike that has gears, and a bike takes at
    most one shift per G.SHIFT_COOLDOWN, so a held key or a spinning wheel cannot
    run through the box in a frame and a client cannot change anyone else's gear.
----------------------------------------------------------------------------]]

BMX = BMX or {}

util.AddNetworkString("bmx_shift")

-- Shift a bike up (+1) or down (-1) one gear. Returns the gear it is in now, or
-- nil if it did not move (single-speed, at the end of the box, or too soon).
function BMX.Shift(bike, dir)
    if not IsValid(bike) or not bike.Bike then return nil end
    local n = BMX.Gears.Count(bike)
    if n == 0 then return nil end
    local now = CurTime()
    if now < (bike.bmxShiftReady or 0) then return nil end
    local from = BMX.Gears.Index(bike)
    local to = math.max(1, math.min(n, from + (dir > 0 and 1 or -1)))
    if to == from then return nil end
    bike.bmxShiftReady = now + BMX.Gears.SHIFT_COOLDOWN
    bike:SetGear(to)
    return to
end

-- Go straight to a gear (a test, a bot, an automatic box). No cooldown: it is a
-- deliberate set, not a key.
function BMX.SetGear(bike, i)
    if not IsValid(bike) or BMX.Gears.Count(bike) == 0 then return nil end
    i = math.max(1, math.min(BMX.Gears.Count(bike), math.floor(i)))
    bike:SetGear(i)
    return i
end

net.Receive("bmx_shift", function(_, ply)
    local up = net.ReadBool()
    if not IsValid(ply) then return end
    local bike = ply.BMXBike
    if not IsValid(bike) or bike:GetDriver() ~= ply then return end
    BMX.Shift(bike, up and 1 or -1)
end)
