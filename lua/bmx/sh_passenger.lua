--[[--------------------------------------------------------------------------
    bmx/sh_passenger.lua

    SEATS (G11), the shared half: what seats a vehicle has and where they are, the
    mass a passenger adds, and the one context-menu property (the child seat).

    A VEHICLE'S SEATS are its registry `seats`:

        seats = { rider = {...}, pegs = {...}, child = {...} }

    `rider` is the driver's (always there: omitted, it is the config's
    Chassis.seatOffset and seatAngles, which is what every bike used before there
    was a second seat). `pegs` is a second rider standing on the rear pegs, with
    their hands on the first's shoulders; `child` is a child seat over the rear
    wheel. A seat with an empty table is a seat with every default, which is how
    the BMX asks for pegs: `seats = { pegs = {} }`. Each seat may say

        model       the pod's model (its seat attachment and sit animation matter)
        offset      a Vector, or a function of the config: where the pod sits
        angles      an Angle
        massFactor  the passenger's mass, as a fraction of the bike's own Chassis.mass
                    (which is the rider's weight plus the bike's, see sh_config.lua)

    The older list form, `seats = { { model, offset, angles } }`, is still the rider's
    seat and still works; it cannot say more than that.

    WHY A FRACTION OF THE CONFIG'S MASS and not kilograms: Chassis.mass already IS a
    rider on a bike (86 for the BMX), so "a second rider" is most naturally "most of
    that again", and a heavier or lighter bike carries a proportionally heavier or
    lighter second person. 0.6 for an adult on pegs (a rider is about 0.8 of the 86;
    the other 0.2 is bike) is +70% of the rider's weight, a child 0.25.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Passenger = BMX.Passenger or {}

-- (The kinds of seat, BMX.SeatKinds, are sh_vehicles.lua's: a registration is checked
-- against them before this file loads.)

-- Defaults, as functions of a config: where a seat is when its registration does
-- not say. The pegs' pod sits just behind the rear axle and a little above the
-- saddle (the rider's hips are over the saddle and the passenger's are behind and
-- higher, over the pegs); the child seat is over the rear wheel, a hand's width
-- above the rider's. `massFactor` as in the header.
local DEFAULTS = {
    rider = function(cfg)
        return { offset = cfg.Chassis.seatOffset, angles = cfg.Chassis.seatAngles, massFactor = 0 }
    end,
    pegs = function(cfg)
        local so = cfg.Chassis.seatOffset
        return { offset = Vector(-cfg.Wheel.wheelbase * 0.5 - 3, 0, so.z + 3),
                 angles = cfg.Chassis.seatAngles, massFactor = 0.6 }
    end,
    child = function(cfg)
        local so = cfg.Chassis.seatOffset
        return { offset = Vector(-cfg.Wheel.wheelbase * 0.5 * 0.8, 0, so.z + 2),
                 angles = cfg.Chassis.seatAngles, massFactor = 0.25 }
    end,
}

-- Does this vehicle have a seat of this kind? (The rider's is always there.)
function BMX.HasSeat(def, kind)
    if kind == "rider" then return true end
    return def ~= nil and istable(def.seats) and def.seats[kind] ~= nil
end

-- The seat of a kind for a vehicle and its config, resolved: { model, offset,
-- angles, massFactor }, or nil if the vehicle has no such seat.
function BMX.SeatFor(def, cfg, kind)
    if not BMX.HasSeat(def, kind) then return nil end
    local out = DEFAULTS[kind](cfg)
    local seats = def.seats
    local given
    if istable(seats) then
        -- The list form is the rider's seat; the map form names its seats.
        given = (kind == "rider" and (seats.rider or seats[1])) or (kind ~= "rider" and seats[kind]) or nil
    end
    out.model = nil
    for k, v in pairs(given or {}) do
        if k == "offset" and isfunction(v) then v = v(cfg) end
        out[k] = v
    end
    out.model = out.model or def.seatModel or "models/nova/airboat_seat.mdl"
    return out
end

-- The seat kinds a vehicle has, rider first.
function BMX.SeatKindsOf(def)
    local out = {}
    for _, k in ipairs(BMX.SeatKinds) do
        if BMX.HasSeat(def, k) then out[#out + 1] = k end
    end
    return out
end

-- A config with `extra` kilograms more Chassis.mass, over the same base by
-- reference (so a convar moving the base still reaches it). What a bike runs on
-- while somebody rides on its pegs (ENT:Cfg).
function BMX.WithMass(cfg, extra)
    local out = setmetatable({}, { __index = cfg })
    out.Chassis = setmetatable({ mass = cfg.Chassis.mass + extra }, { __index = cfg.Chassis })
    return out
end

--------------------------------------------------------------------------
-- THE CHILD SEAT'S SWITCH. A bike with a `child` seat gets "Child seat" on its
-- context menu (hold C and right-click it), a toggle. Off, the seat is not drawn
-- and nobody can get on it; on, E on the bike's rear half seats a second player
-- in it. Not while somebody is already in it.
--------------------------------------------------------------------------
local function hasChildSeat(ent)
    return IsValid(ent) and ent.IsBMX and BMX.HasSeat(ent:Bike(), "child")
end

function BMX.Passenger.CanToggleChild(ent, ply)
    if not hasChildSeat(ent) then return false end
    if SERVER then
        if IsValid(ent:GetPaxChild()) then return false end
        local owner = ent.BMXOwner
        if IsValid(owner) and owner ~= ply and not (IsValid(ply) and ply:IsAdmin()) then return false end
    end
    return true
end

if properties and properties.Add then
    properties.Add("bmx_childseat", {
        MenuLabel = "Child seat",
        Type      = "toggle",
        Order     = 1810,
        Filter = function(self, ent, ply)
            return hasChildSeat(ent) and properties.CanBeTargeted(ent, ply)
        end,
        Checked = function(self, ent, ply)
            return IsValid(ent) and ent.GetChildSeat and ent:GetChildSeat() or false
        end,
        Action = function(self, ent)
            self:MsgStart()
                net.WriteEntity(ent)
            self:MsgEnd()
        end,
        Receive = function(self, length, ply)
            local ent = net.ReadEntity()
            if not IsValid(ent) or not properties.CanBeTargeted(ent, ply) then return end
            if not BMX.Passenger.CanToggleChild(ent, ply) then return end
            ent:SetChildSeat(not ent:GetChildSeat())
        end,
    })
end
