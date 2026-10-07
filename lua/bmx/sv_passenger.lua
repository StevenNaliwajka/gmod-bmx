--[[--------------------------------------------------------------------------
    bmx/sv_passenger.lua

    A SECOND PERSON ON THE BIKE (G11): a passenger on the rear pegs (BMX, cruiser),
    or in a child seat (the city bike). The seats and their defaults are
    sh_passenger.lua; this is what happens on the server when somebody takes one.

    THE PODS. A passenger sits in a prop_vehicle_prisoner_pod of their own, parented
    to the bike exactly as the rider's is (ENT:BuildPod), invisible and
    non-solid, and DoNotDuplicate for the same reason as the rider's: the duplicator
    would copy it as a child of the bike and the pasted bike would come up with two.
    They are made the first time somebody boards that seat, not when the bike is
    spawned: most bikes never carry anyone, and a server with a hundred of them does
    not want a hundred extra pods. A passenger can look round and use the mouse
    (`limitview 0`), cannot steer (the usercmd decode reads only the rider's), and
    gets off with E like the rider does.

    WHAT A PASSENGER DOES TO THE BIKE.
      Mass          the passenger's `massFactor` of the bike's Chassis.mass is added to
                    the physics object and to the config the bike runs on (ENT:Cfg),
                    and the inertia is measured again. Wheelies and the balance get
                    harder because the bike IS heavier, through the same numbers
                    everything else reads.
      Centre of mass  VPhysics cannot move a body's mass centre at runtime, so the
                    passenger's WEIGHT is applied where they actually sit: the engine
                    pulls the whole mass down at the mass centre, and this step adds
                    the couple that is the difference (weight down at the seat, the
                    same weight up at the mass centre). Net force nothing; torque the
                    one a person on the back of a bike really puts on it.
      Score         every trick scores x2 with a passenger aboard, on top of the
                    vehicle's own multiplier (BMX.PassengerScoreMult, ENT:AwardTricks).

    A CRASH takes both. The rider is thrown the way they always were; every passenger
    is thrown too, with the bike's momentum and a little of their own, and goes the
    same ladder: BMX_RiderCrashed(ply, vel, bike) first, so any ragdoll addon may
    take them, then RagMod, then our own tumble, then the shove. Hurt as the rider is.
    The passenger of a rider who gets off (or dies, or leaves) gets off too: a bike
    with only a passenger on it is nobody's.

    bmx_passengers 0 turns it all off: nobody can board, and nobody already aboard is
    left aboard.
----------------------------------------------------------------------------]]

BMX = BMX or {}
local P = BMX.Passenger

local FLAGS = bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED)
local cvOn = CreateConVar("bmx_passengers", "1", FLAGS,
    "BMX: 1 = a second player may ride on a bike's pegs or child seat; 0 = nobody can.")

function BMX.PassengersEnabled() return cvOn:GetBool() end

-- The passengers aboard, as a list of { kind, ply }.
function P.List(bike)
    local out = {}
    for _, kind in ipairs({ "pegs", "child" }) do
        local ply = bike.passengers and bike.passengers[kind]
        if IsValid(ply) then out[#out + 1] = { kind = kind, ply = ply } end
    end
    return out
end

function P.Count(bike) return #P.List(bike) end

-- x2 for any passenger. Asked by ENT:AwardTricks.
function BMX.PassengerScoreMult(bike)
    return P.Count(bike) > 0 and 2 or 1
end

-- Is `ent` a passenger of `bike`? (The collision filter, the trace filter.)
function P.IsPassengerOf(ent, bike)
    return IsValid(ent) and ent.BMXPax ~= nil and ent.BMXPax.bike == bike
end

--------------------------------------------------------------------------
-- The mass. Rebuilt from the passengers aboard, every time one boards or leaves.
--------------------------------------------------------------------------
function P.Refresh(bike)
    if not IsValid(bike) then return end
    local def = bike:Bike()
    -- The config WITHOUT a passenger, to take the fractions of.
    bike.paxMass = 0
    bike._cfg = nil
    local base = bike:Cfg()
    local extra, seats = 0, {}
    for _, p in ipairs(P.List(bike)) do
        local seat = BMX.SeatFor(def, base, p.kind)
        if seat then
            seats[p.kind] = seat
            extra = extra + seat.massFactor * base.Chassis.mass
        end
    end
    bike.paxSeats = seats              -- resolved once, for the per-substep weight below
    bike.paxMass = extra
    bike.paxBaseMass = base.Chassis.mass       -- the passengers' fractions are of THIS, not of the heavier total
    bike._cfg = nil
    local phys = bike:GetPhysicsObject()
    if IsValid(phys) then
        local was, before = phys:GetMass(), bike.I and Vector(bike.I.x, bike.I.y, bike.I.z)
        local now = bike:Cfg().Chassis.mass
        phys:SetMass(now)
        -- The inertia of the heavier body, measured again: every torque the
        -- controllers command is T = I * alpha. If the engine did not rescale it
        -- with the mass (it is not documented either way), it is scaled here: a
        -- body made 60% heavier with the same moments would be a lighter one to
        -- turn than it looks.
        BMX.CacheInertia(bike, phys, bike:Cfg())
        local r = now / math.max(was, 1e-6)
        if before and bike.I and before.y > 0 and math.abs(bike.I.y / before.y - 1) < 0.5 * math.abs(r - 1) then
            bike.I = before * r
        end
        phys:Wake()
    end
end

-- The passengers' weight, where they sit (see the header: the couple). Called once
-- a substep by BMX.PhysicsStep, only for a bike with somebody on it.
function P.ApplyWeight(bike, phys, dt)
    if (bike.paxMass or 0) <= 0 or not bike.paxSeats then return end
    local g = physenv.GetGravity():Length()
    local base = bike.paxBaseMass or (bike:Cfg().Chassis.mass - bike.paxMass)
    local down = Vector(0, 0, -1)
    for _, seat in pairs(bike.paxSeats) do
        local J = seat.massFactor * base * g * dt
        phys:ApplyForceOffset(down * J, bike:LocalToWorld(seat.offset))
        phys:ApplyForceCenter(-down * J)
    end
end

--------------------------------------------------------------------------
-- Boarding. E on an occupied bike (ENT:Use), at its rear half.
--------------------------------------------------------------------------

-- Which seat a player pressing E would take: the child seat if it is switched on
-- and free, else the pegs if the bike has them and they are free. nil if none.
function P.SeatFor(bike)
    local def = bike:Bike()
    if BMX.HasSeat(def, "child") and bike:GetChildSeat() and not IsValid(bike:GetPaxChild()) then
        return "child"
    end
    if BMX.HasSeat(def, "pegs") and not IsValid(bike:GetPaxPegs()) then
        return "pegs"
    end
    return nil
end

local function podFor(bike, kind)
    bike.paxPods = bike.paxPods or {}
    local pod = bike.paxPods[kind]
    if IsValid(pod) then return pod end
    local seat = BMX.SeatFor(bike:Bike(), bike:Cfg(), kind)
    if not seat then return nil end
    pod = bike:BuildPod(seat)
    if not IsValid(pod) then return nil end
    pod.BMXPassenger = kind
    bike.paxPods[kind] = pod
    return pod
end
P.PodFor = podFor

-- E ON THE REAR PEGS means looking at the rear half of the bike: the front end is
-- the rider's, which is taken, and E on an occupied bike used to do nothing at all,
-- so it still does nothing unless the player is plainly pointing at the back of it.
-- (A script that wants somebody aboard without pointing passes `anywhere`.)
local function atRear(bike, ply)
    local tr = ply.GetEyeTrace and ply:GetEyeTrace()
    if not tr or not tr.Hit or tr.Entity ~= bike then return false end
    return bike:WorldToLocal(tr.HitPos).x <= 4
end

function P.TryBoard(bike, ply, anywhere)
    if not BMX.PassengersEnabled() then return false end
    if not IsValid(ply) or ply:InVehicle() or ply.BMXTumbling or bike.pickingUp then return false end
    if BMX.IsFallen(bike) then return false end
    if hook.Run("BMX_CanMount", ply, bike) == false then return false end
    if not anywhere and not atRear(bike, ply) then return false end
    local kind = P.SeatFor(bike)
    if not kind then return false end
    local pod = podFor(bike, kind)
    if not pod then return false end
    ply:EnterVehicle(pod)
    return true
end

-- Taking the seat: called from the PlayerEnteredVehicle hook (sv_seat.lua).
function P.Bind(ply, bike, pod)
    if not IsValid(ply) or not IsValid(bike) then return end
    local kind = pod.BMXPassenger
    bike.passengers = bike.passengers or {}
    bike.passengers[kind] = ply
    ply.BMXPax = { bike = bike, kind = kind }
    if kind == "pegs" then bike:SetPaxPegs(ply) else bike:SetPaxChild(ply) end
    -- A child is small. (A player's own model scale, which every client sees.)
    if kind == "child" and ply.SetModelScale then ply:SetModelScale(0.6, 0) end
    bike:RebuildTraceFilter()
    P.Refresh(bike)
end

-- Getting off, by whatever way: the PlayerLeaveVehicle hook, death, disconnect.
function P.Unbind(ply)
    local pax = ply and ply.BMXPax
    if not pax then return end
    ply.BMXPax = nil
    local bike = pax.bike
    if IsValid(ply) and pax.kind == "child" and ply.SetModelScale then ply:SetModelScale(1, 0) end
    if not IsValid(bike) then return end
    if bike.passengers and bike.passengers[pax.kind] == ply then bike.passengers[pax.kind] = nil end
    if pax.kind == "pegs" then bike:SetPaxPegs(NULL) else bike:SetPaxChild(NULL) end
    bike:RebuildTraceFilter()
    P.Refresh(bike)
end

-- Everyone off, politely: the rider got off, or bmx_passengers went to 0.
function P.DismountAll(bike)
    for _, p in ipairs(P.List(bike)) do
        if IsValid(p.ply) then p.ply:ExitVehicle() end
    end
end

--------------------------------------------------------------------------
-- A crash takes the passengers too. Called from ENT:Crash once the rider is out.
--------------------------------------------------------------------------
function P.Eject(bike, vel, severity)
    local CR = bike:Cfg().Crash
    local list = P.List(bike)
    for i, p in ipairs(list) do
        local ply = p.ply
        -- Thrown off the back and to a side, each their own way: the pegs' rider
        -- off to the left or right by who they are, the child straight back.
        local side = (p.kind == "child") and 0 or ((ply:EntIndex() % 2 == 0) and 1 or -1)
        local throw = vel + bike:GetRight() * (side * 55) - bike:GetForward() * 25
            + Vector(0, 0, CR.ejectLift * severity)
        local dmg = math.floor(severity * vel:Length() * CR.damageScale)
        ply:ExitVehicle()
        local function hurt()
            if not IsValid(ply) or dmg <= 1 then return end
            local d = DamageInfo()
            d:SetDamage(dmg)
            d:SetDamageType(DMG_FALL)
            d:SetAttacker(IsValid(bike) and bike or ply)
            d:SetInflictor(IsValid(bike) and bike or ply)
            ply:TakeDamageInfo(d)
        end
        timer.Simple(0, function()
            if not IsValid(ply) then return end
            if hook.Run("BMX_RiderCrashed", ply, throw, bike) == true
                or (BMX.Compat and BMX.Compat.Ragdoll and BMX.Compat.Ragdoll(ply, throw)) then
                hurt()
                return
            end
            if GetConVar("bmx_crash_ragdoll"):GetBool() and BMX.Tumble(ply, throw, hurt) then
                return
            end
            ply:SetVelocity(throw)
            hurt()
        end)
    end
    return #list
end

-- bmx_passengers 0 mid-ride: everybody off.
cvars.AddChangeCallback("bmx_passengers", function(_, _, new)
    if tonumber(new) ~= 0 then return end
    for _, id in ipairs(BMX.VehicleIDs()) do
        for _, e in ipairs(ents.FindByClass(BMX.ClassFor(id))) do
            if e.passengers then P.DismountAll(e) end
        end
    end
end, "BMX.Passengers")
