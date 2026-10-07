--[[--------------------------------------------------------------------------
    bmx/sv_rack.lua

    THE BIKE RACK (G13): a prop that welds to a car and carries up to two bikes.

    The entity is lua/entities/bmx_bike_rack; the rules are here, so the entity is a
    shell and the suite can run them without a world.

    A RACK AND ITS CARRIER. Placed against a vehicle it welds to it (constraint.Weld) and
    is carried with it. What counts as a vehicle is deliberately wide, because the three
    families of GMod car have nothing in common but being cars: the engine's own
    (prop_vehicle_jeep and the rest of prop_vehicle_*), simfphys's
    (gmod_sent_vehicle_fphysics_*) and LVS's (lvs_*, or anything carrying an LVS flag). A
    rack with nothing to weld to is still a rack, and sits where it was put.

    TWO BIKES, WELDED. A bike put on a rack is moved to a slot (two: one each side of the
    rack's middle, lying across it, the way a hitch rack carries them), welded to
    the rack, set not to collide with the rack or the car, and RELEASED FROM ITS OWN
    SIMULATION: a racked bike runs no wheels and no balance (sv_physics.lua stops at
    ent.BMXRack), because it is bolted to a car and the tyre model against a body it is
    welded to would only shake both. It cannot be mounted: E on it lets it down first,
    and a second E gets on. A removed rack, a removed bike and a removed car all let go.

    CAPACITY is Rack.Capacity, two, and is the rack's and not the bike's: a third bike is
    refused with a reason. A bike that is ridden, locked, fallen or already on a rack is
    refused too.

    Every function returns (ok, why): the entity and the tests ask the same ones.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Rack = BMX.Rack or {}
local R = BMX.Rack

R.Capacity   = 2
R.LoadRange  = 90     -- u: a bike this close to the rack is the one E loads
R.WeldRange  = 160    -- u: the carrier a rack looks for when it is spawned or used

-- THE SLOTS, in the rack's own space: a bike each side of the middle, lying across the
-- rack (its forward along the rack's width), its origin the height of a bike's axle above
-- the plate. Angles are relative to the rack.
R.SlotsLocal = {
    { pos = Vector(0,  15, 17), ang = Angle(0, 90, 0) },
    { pos = Vector(0, -15, 17), ang = Angle(0, 90, 0) },
}

--------------------------------------------------------------------------
-- WHAT IS A CARRIER.
--------------------------------------------------------------------------
function R.IsCarrier(ent)
    if not IsValid(ent) then return false end
    local c = ent:GetClass() or ""
    if c:find("^prop_vehicle_") and c ~= "prop_vehicle_prisoner_pod" then return true end
    if c:find("^gmod_sent_vehicle_fphysics") then return true end
    if c:find("^lvs_") or ent.LVS then return true end
    return false
end

-- The nearest carrier to a point, within `range` (the weld range by default).
function R.FindCarrier(pos, range)
    local best, bestD = nil, (range or R.WeldRange)
    for _, e in ipairs(ents.GetAll()) do
        if R.IsCarrier(e) then
            local d = e:GetPos():Distance(pos)
            local near = e.NearestPoint and e:NearestPoint(pos)
            if near then d = math.min(d, near:Distance(pos)) end
            if d <= bestD then best, bestD = e, d end
        end
    end
    return best
end

function R.AccessoriesEnabled()
    return BMX.VehicleEnabled == nil or BMX.VehicleEnabled("stock")
end

--------------------------------------------------------------------------
-- THE CARRIER: welding a rack to it.
--------------------------------------------------------------------------
function R.Attach(rack, carrier)
    if not IsValid(rack) or not R.IsCarrier(carrier) then return false, "that is not a vehicle" end
    R.Detach(rack)
    local weld = constraint.Weld(rack, carrier, 0, 0, 0, true, false)
    if not weld then return false, "could not weld" end
    rack.carrier, rack.carrierWeld = carrier, weld
    if rack.SetCarried then rack:SetCarried(true) end
    return true
end

function R.Detach(rack)
    if rack.carrierWeld and IsValid(rack.carrierWeld) then rack.carrierWeld:Remove() end
    rack.carrier, rack.carrierWeld = nil, nil
    if rack.SetCarried then rack:SetCarried(false) end
end

--------------------------------------------------------------------------
-- WHAT IS ON IT.
--------------------------------------------------------------------------
-- The bikes held, by slot (a table with holes where a slot is empty).
function R.Slots(rack)
    rack.held = rack.held or {}
    return rack.held
end

function R.Count(rack)
    local n = 0
    for i = 1, R.Capacity do
        if IsValid(R.Slots(rack)[i]) then n = n + 1 end
    end
    return n
end

function R.FreeSlot(rack)
    for i = 1, R.Capacity do
        if not IsValid(R.Slots(rack)[i]) then return i end
    end
    return nil
end

function R.IsFull(rack) return R.FreeSlot(rack) == nil end

-- Where slot i is, in the world.
function R.SlotPos(rack, i)
    local s = R.SlotsLocal[i]
    return rack:LocalToWorld(s.pos), rack:LocalToWorldAngles(s.ang)
end

-- May this bike go on this rack? Not if the rack is full, the bike has somebody on it,
-- is locked, is already racked, or is not a bike of ours.
function R.CanLoad(rack, bike)
    if not IsValid(rack) or not IsValid(bike) or not bike.IsBMX then return false, "that is not a bike" end
    if bike.BMXRack then return false, "that bike is already on a rack" end
    if IsValid(bike:GetDriver()) then return false, "somebody is riding it" end
    if BMX.Lock and BMX.Lock.Of(bike) then return false, "that bike is locked" end
    if R.IsFull(rack) then return false, "the rack is full" end
    return true
end

-- Put a bike on the rack, in the first free slot.
function R.Load(rack, bike)
    local ok, why = R.CanLoad(rack, bike)
    if not ok then return false, why end
    local i = R.FreeSlot(rack)
    local pos, ang = R.SlotPos(rack, i)

    local phys = bike:GetPhysicsObject()
    if IsValid(phys) then
        phys:SetAngles(ang)
        phys:SetPos(pos)
        phys:SetVelocity(vector_origin)
        phys:SetAngleVelocity(vector_origin)
    end
    bike.BMXRack, bike.BMXRackSlot = rack, i
    bike:SetStandDown(false)

    local weld = constraint.Weld(bike, rack, 0, 0, 0, true, false)
    bike.BMXRackWeld = weld
    -- It must not fight the rack or the car it is bolted to.
    local nc = { constraint.NoCollide(bike, rack, 0, 0) }
    if IsValid(rack.carrier) then nc[#nc + 1] = constraint.NoCollide(bike, rack.carrier, 0, 0) end
    bike.BMXRackNoCollide = nc

    R.Slots(rack)[i] = bike
    if rack.SetLoaded then rack:SetLoaded(R.Count(rack)) end
    hook.Run("BMX_BikeRacked", bike, rack, i)
    return true, i
end

-- Take a bike off (by whatever way: E on it, E on the rack, the rack removed). The bike
-- is set down where it hangs, upright, and runs its own wheels again.
function R.Release(bike, ply)
    local rack = bike and bike.BMXRack
    if not rack then return false, "that bike is not on a rack" end
    if bike.BMXRackWeld and IsValid(bike.BMXRackWeld) then bike.BMXRackWeld:Remove() end
    for _, c in ipairs(bike.BMXRackNoCollide or {}) do
        if c and IsValid(c) then c:Remove() end
    end
    local i = bike.BMXRackSlot
    if IsValid(rack) and i and R.Slots(rack)[i] == bike then R.Slots(rack)[i] = nil end
    bike.BMXRack, bike.BMXRackSlot, bike.BMXRackWeld, bike.BMXRackNoCollide = nil, nil, nil, nil
    if IsValid(rack) and rack.SetLoaded then rack:SetLoaded(R.Count(rack)) end
    local phys = bike:GetPhysicsObject()
    if IsValid(phys) then phys:Wake() end
    hook.Run("BMX_BikeUnracked", bike, rack, ply)
    return true
end

function R.ReleaseAll(rack, ply)
    for i = 1, R.Capacity do
        local b = R.Slots(rack)[i]
        if IsValid(b) then R.Release(b, ply) end
    end
end

-- The loose bike nearest the rack, within range, that could go on it.
function R.NearestLoadable(rack, range)
    local best, bestD = nil, range or R.LoadRange
    for _, id in ipairs(BMX.VehicleIDs()) do
        for _, e in ipairs(ents.FindByClass(BMX.ClassFor(id))) do
            if R.CanLoad(rack, e) then
                local d = e:GetPos():Distance(rack:GetPos())
                if d <= bestD then best, bestD = e, d end
            end
        end
    end
    return best
end

-- E on the rack: a bike beside it goes on, otherwise the last one on comes off; a rack
-- not yet on a car looks for one first. Returns what it did, for the chat.
function R.Use(rack, ply)
    if not R.AccessoriesEnabled() then return "off" end
    if not IsValid(rack.carrier) then
        local car = R.FindCarrier(rack:GetPos())
        if car and R.Attach(rack, car) then return "attached" end
    end
    local loose = R.NearestLoadable(rack)
    if loose then
        local ok = R.Load(rack, loose)
        if ok then return "loaded" end
    end
    for i = R.Capacity, 1, -1 do
        local b = R.Slots(rack)[i]
        if IsValid(b) then R.Release(b, ply) return "released" end
    end
    return "nothing"
end

-- The racked bike's own E: let it down (the next E gets on). See ENT:Use.
hook.Add("PlayerSpawnSENT", "BMX.RackEnabled", function(ply, class)
    if class ~= "bmx_bike_rack" then return end
    if not R.AccessoriesEnabled() then
        if IsValid(ply) then ply:ChatPrint("[BMX] bikes are switched off on this server (bmx_allow_bikes 0).") end
        return false
    end
end)
