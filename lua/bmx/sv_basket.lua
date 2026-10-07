--[[--------------------------------------------------------------------------
    bmx/sv_basket.lua

    THE BASKET (G12): a box on the front of a city bike that small props ride in.
    A parcel for a delivery job on an RP server, a prop dropped in for a laugh: it
    stays in while the bike is ridden gently and comes out when the ride stops being
    gentle.

    A VOLUME, NOT AN ENTITY. The registration says where the box is in the bike's own
    space (`basket = { mins, maxs, maxMass, hold }`), which is what "welded to the
    frame" means: the box is the bike's and moves with it, and it needs no second
    physics object, no constraint to break and nothing to duplicate. The basket is
    drawn by the client (cl_init.lua) from the same numbers.

    WHAT IT HOLDS. A loose prop_physics whose mass is at most `maxMass` (a basket
    carries a parcel, not an engine block), that comes to rest inside the box, not
    being thrown in faster than a person could place it, and not held by somebody's
    physgun or gravity gun. It is CAPTURED: remembered by where it sits in the box
    and from then on placed there every tick with the bike's velocity and no gravity
    of its own, so it rides as a thing in a basket does and does not sink through a
    floor that is not there. It collides with the world as ever, and not with the
    bike it is riding in (BMX.RiderPassthrough, sv_seat.lua).

    WHEN IT COMES OUT. The bike's acceleration is measured over a short window (not
    tick to tick, which reads every contact as a spike); past `hold` (default 1,500
    u/s^2, two and a half g) the whole load is released at once, each prop leaving
    with the bike's velocity and a flick up and to the side, so it FLIES out and is
    not just dropped. That is a bunny hop (the city bike's pop of 150 u/s in one step
    measures ~2,500 over the window on the plant, a BMX's more), a hard landing, a
    crash, running into something. Pedalling, braking and turning are nowhere near it
    (the plant reads ~20 u/s^2 riding at 10 mph), which is what the headroom is for:
    the engine's contact noise is not the plant's.
    A bike knocked over, or removed, drops its load too, and a prop released is not
    taken back for a moment, or it would be caught again as it left.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Basket = BMX.Basket or {}
local B = BMX.Basket

local abs = math.abs

B.DEFAULT_MAX_MASS = 12      -- kg: a parcel, a bucket, a chair
B.DEFAULT_HOLD     = 1500    -- u/s^2 over B.WINDOW: two and a half g
B.WINDOW           = 0.05    -- s over which the acceleration is measured
B.SCAN_EVERY       = 0.1     -- s between looks for something to catch
B.COOLDOWN         = 1.5     -- s a released prop is not caught again
B.CATCH_SPEED      = 140     -- u/s relative to the bike, at most, to be caught

-- The basket of a bike, with its defaults filled in, or nil.
function B.Of(bike)
    local def = bike.Bike and bike:Bike()
    local b = def and def.basket
    if not b then return nil end
    return b, b.maxMass or B.DEFAULT_MAX_MASS, b.hold or B.DEFAULT_HOLD
end

-- The props a bike is carrying, as a list.
function B.Held(bike)
    local out = {}
    for e in pairs(bike.basketHeld or {}) do
        if IsValid(e) then out[#out + 1] = e end
    end
    return out
end

-- The bike's centre point of the box in the world, and the box's half sizes.
function B.Centre(bike, b)
    return bike:LocalToWorld((b.mins + b.maxs) * 0.5), (b.maxs - b.mins) * 0.5
end

-- Is a world point inside the box?
function B.Contains(bike, b, p)
    local l = bike:WorldToLocal(p)
    return l.x >= b.mins.x and l.x <= b.maxs.x and l.y >= b.mins.y and l.y <= b.maxs.y
        and l.z >= b.mins.z and l.z <= b.maxs.z
end

local function clampInto(b, l)
    return Vector(math.Clamp(l.x, b.mins.x + 1, b.maxs.x - 1),
                  math.Clamp(l.y, b.mins.y + 1, b.maxs.y - 1),
                  math.Clamp(l.z, b.mins.z + 1, b.maxs.z - 1))
end

local function isProp(e)
    return IsValid(e) and e:GetClass() == "prop_physics"
end

-- Is somebody holding it (physgun, gravity gun, +use)? Asked of the engine where
-- the engine can say.
local function carried(e)
    return e.IsPlayerHolding and e:IsPlayerHolding() or false
end

--------------------------------------------------------------------------
-- Catching and releasing.
--------------------------------------------------------------------------
function B.Capture(bike, e)
    local b = B.Of(bike)
    if not b then return false end
    local po = e:GetPhysicsObject()
    if not IsValid(po) then return false end
    bike.basketHeld = bike.basketHeld or {}
    local at = clampInto(b, bike:WorldToLocal(e:GetPos()))
    local ang = bike.WorldToLocalAngles and bike:WorldToLocalAngles(e:GetAngles()) or Angle()
    bike.basketHeld[e] = { at = at, ang = ang }
    e.BMXBasket = bike
    po:EnableGravity(false)
    po:SetVelocity(bike:GetPhysicsObject():GetVelocity())
    po:Wake()
    return true
end

-- Let one prop go: gravity back, the bike's velocity and a flick up and to a
-- side, so it flies. `why` is for a log, not the logic.
function B.ReleaseOne(bike, e, why)
    local held = bike.basketHeld
    if not held or not held[e] then return end
    held[e] = nil
    if not IsValid(e) then return end
    e.BMXBasket = nil
    e.BMXBasketUntil = CurTime() + B.COOLDOWN
    local po = e:GetPhysicsObject()
    if IsValid(po) then
        po:EnableGravity(true)
        local v = IsValid(bike:GetPhysicsObject()) and bike:GetPhysicsObject():GetVelocity() or Vector()
        -- Each prop a different way: by who it is.
        local side = ((e:EntIndex() % 2 == 0) and 1 or -1)
        po:SetVelocity(v + Vector(0, 0, 90) + bike:GetRight() * (side * 45))
        po:Wake()
    end
end

function B.Release(bike, why)
    for _, e in ipairs(B.Held(bike)) do B.ReleaseOne(bike, e, why) end
    bike.basketHeld = nil
end

-- A crash empties it (BMX_Crashed fires before the rider is thrown).
hook.Add("BMX_Crashed", "BMX.BasketCrash", function(bike)
    if IsValid(bike) and bike.basketHeld then B.Release(bike, "crash") end
end)

--------------------------------------------------------------------------
-- The acceleration, over a short window of the bike's velocity.
--------------------------------------------------------------------------
local function accel(bike, v, now)
    local h = bike.basketHist
    if not h then h = {} bike.basketHist = h end
    h[#h + 1] = { t = now, v = v }
    -- Newest sample that is at least a window old; drop what is older than it.
    local ref
    for i = #h, 1, -1 do
        if now - h[i].t >= B.WINDOW then ref = i break end
    end
    if not ref then return 0 end
    for _ = 1, ref - 1 do table.remove(h, 1) end
    local r = h[1]
    return (v - r.v):Length() / math.max(now - r.t, 1e-3)
end

--------------------------------------------------------------------------
-- One tick, for one bike.
--------------------------------------------------------------------------
function B.Tick(bike, now)
    local b, maxMass, hold = B.Of(bike)
    if not b then return end
    local phys = bike:GetPhysicsObject()
    if not IsValid(phys) then return end
    local v = phys:GetVelocity()
    local a = accel(bike, v, now)
    bike.basketAccel = a

    -- Lying on its side: a basket on a fallen bike is a basket on the floor.
    local fallen = BMX.IsFallen and BMX.IsFallen(bike)

    if bike.basketHeld and next(bike.basketHeld) ~= nil then
        if a > hold or fallen then
            B.Release(bike, fallen and "fallen" or "accel")
        else
            for e, h in pairs(bike.basketHeld) do
                if not IsValid(e) or carried(e) or not IsValid(e:GetPhysicsObject()) then
                    bike.basketHeld[e] = nil
                    if IsValid(e) then
                        e.BMXBasket = nil
                        local po = e:GetPhysicsObject()
                        if IsValid(po) then po:EnableGravity(true) end
                    end
                else
                    -- Placed where it was put, moving as the bike moves.
                    local po = e:GetPhysicsObject()
                    po:SetPos(bike:LocalToWorld(h.at))
                    if bike.LocalToWorldAngles then po:SetAngles(bike:LocalToWorldAngles(h.ang)) end
                    po:SetVelocity(v)
                    po:SetAngleVelocity(Vector(0, 0, 0))
                end
            end
        end
    end

    -- Something to catch? Not on a fallen bike, and not while it is being thrown about.
    if fallen or a > hold or now < (bike.basketScanAt or 0) then return end
    bike.basketScanAt = now + B.SCAN_EVERY
    local lo, hi = bike:BoundsWorld(b.mins, b.maxs, 2)
    for _, e in ipairs(ents.FindInBox(lo, hi)) do
        if isProp(e) and not (bike.basketHeld and bike.basketHeld[e]) and not e.BMXBasket
            and now >= (e.BMXBasketUntil or 0) and not carried(e) then
            local po = e:GetPhysicsObject()
            if IsValid(po) and po:GetMass() <= maxMass and B.Contains(bike, b, e:GetPos())
                and (po:GetVelocity() - v):Length() <= B.CATCH_SPEED then
                B.Capture(bike, e)
            end
        end
    end
end

hook.Add("Think", "BMX.Basket", function()
    local now = CurTime()
    for id, def in pairs(BMX.Vehicles) do
        if def.basket then
            for _, e in ipairs(ents.FindByClass(BMX.ClassFor(id))) do
                if e.st then B.Tick(e, now) end
            end
        end
    end
end)
