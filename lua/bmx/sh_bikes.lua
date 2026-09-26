--[[--------------------------------------------------------------------------
    bmx/sh_bikes.lua

    The bike registry. Adding a bike is one table in here plus its model files.

    An entry describes a bike's APPEARANCE, its mount points, and -- since the
    per-bike physics work -- an optional `physics` table of config overrides.

    THE OVERRIDES ARE CHECKED AT REGISTRATION, against the real config, and a
    key that does not exist is a loud error rather than a value that goes
    nowhere. That check is the reason the field did not exist for so long: a
    `physics = {}` that silently does nothing is worse than no field at all, and
    the difference between the two is entirely whether it validates.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Bikes = BMX.Bikes or {}

-- The tyre model the client draws (cl_init.lua). Precached on the server so it
-- is in the model table every client receives; a client-only precache of a
-- model the server never used is what left riders looking at the fallback.
BMX.TyreModel = "models/props_phx/wheels/moped_tire.mdl"
if util.PrecacheModel then util.PrecacheModel(BMX.TyreModel) end

local pending = {}
local derived = false

--------------------------------------------------------------------------
-- DUPLICATOR SUPPORT.
--
-- Without this a bike cannot be Ctrl+C'd, cannot be saved in a dupe, and
-- vanishes from a saved game -- and it fails SILENTLY, because the duplicator
-- simply skips a class it has never been told about. For a Workshop vehicle
-- that is the first thing a player tries after spawning one.
--
-- A bike carries no per-instance construction data: which bike it is, is which
-- CLASS it is, and everything else is rebuilt by Initialize. So the generic
-- path is exactly right, and there is deliberately nothing clever here.
-- duplicator.GenericDuplicatorFunction is the stock equivalent and was verified
-- to behave identically; this is spelled out only because the explicit
-- DoGenericPhysics call is the part worth being able to see.
--
-- The seat is marked DoNotDuplicate where it is created. It is parented to the
-- bike, so the duplicator would otherwise copy it as a child in its own right
-- and the pasted bike would come up with two of them -- one built by
-- Initialize and one pasted on top.
--------------------------------------------------------------------------
local function registerDuplicator(class)
    if not SERVER then return end

    duplicator.RegisterEntityClass(class, function(ply, data)
        local e = ents.Create(data.Class)
        if not IsValid(e) then return end

        duplicator.DoGeneric(e, data)
        e:Spawn()
        e:Activate()
        duplicator.DoGenericPhysics(e, ply, data)
        return e
    end, "Data")
end

-- Forward declaration. RegisterBike is defined above the body of this and calls
-- it, and a `local function` declared later would not be the same name: the
-- earlier reference would resolve as a global and be nil at call time.
local deriveOne

--------------------------------------------------------------------------
-- Register a bike.
--
--   id            unique, lowercase. Becomes entity class "bmx_<id>".
--   def.printName spawnmenu label
--   def.model     frame model. Optional: without one the whole bike is drawn
--                 procedurally, which is what the stock bike does.
--   def.frameColor Color for the procedural frame.
--   def.seatModel model the invisible pod uses; only its seat attachment and
--                 sit animation matter, since it is never drawn.
--   def.wheelModel optional. Absent, the client draws procedural wheels, which
--                 is both an honest placeholder and a useful debug view: you
--                 can SEE where the raycast wheel thinks it is.
--   def.forkModel optional, drawn steered with the front wheel.
--   def.frameOffset / def.frameAngles  model alignment against the axle line
--   def.scale     model scale, for stand-in props that are not bike-sized
--   def.physics   optional per-bike config overrides, grouped exactly as
--                 BMX.Config is. Anything omitted comes from the base, and a
--                 bike with no `physics` at all shares the base table by
--                 reference rather than copying it:
--
--                     physics = {
--                         Chassis = { mass = 94 },
--                         Wheel   = { radius = 12, wheelbase = 43 },
--                         Drive   = { crankTorque = 260000 },
--                     }
--
--                 Overriding a field that has a convar opts this bike out of
--                 LIVE tuning for that one field, because an explicit override
--                 is meant to win. See the note in sh_config.lua.
--------------------------------------------------------------------------
function BMX.RegisterBike(id, def)
    id = string.lower(id)

    def.id        = id
    def.printName = def.printName or id
    -- NO MODEL MEANS DRAWN IN CODE (cl_init.lua): tubes, fork, bars, seat,
    -- cranks and chain, sized from the bike's own geometry. The entity still
    -- needs SOME model for the engine's bookkeeping, so it gets a small base
    -- prop that is never drawn and casts no shadow.
    def.hasModel  = def.model ~= nil
    def.model     = def.model or "models/hunter/plates/plate05x05.mdl"
    def.seatModel = def.seatModel or "models/nova/airboat_seat.mdl"
    def.frameOffset = def.frameOffset or Vector(0, 0, 0)
    def.frameAngles = def.frameAngles or Angle(0, 0, 0)
    def.scale     = def.scale or 1

    -- Loudly, and before anything can ride it.
    BMX.ValidatePhysics(id, def.physics)

    BMX.Bikes[id] = def

    -- "stock" IS bmx_base rather than a derivative, so the base class stays
    -- spawnable on its own and a broken registry still leaves something to ride.
    if id ~= "stock" then
        -- REGISTERING AFTER LOAD HAS TO WORK. The deferred pass below runs once
        -- on a timer at load, so a bike registered later -- by another addon, by
        -- a test fixture, from the console -- used to go on a queue that had
        -- already been drained. BMX.ClassFor would hand back "bmx_<id>" for a
        -- class that scripted_ents had never heard of, and the only symptom was
        -- ents.Create returning nothing.
        if derived and scripted_ents.GetStored("bmx_base") then
            deriveOne(id)
        else
            pending[#pending + 1] = id
        end
    end

    list.Set("SpawnableEntities", BMX.ClassFor(id), {
        PrintName = def.printName,
        ClassName = BMX.ClassFor(id),
        Category  = "BMX",
        Author    = def.author or "naliwajka",
        Information = def.description or "",
    })
end

function BMX.ClassFor(id)
    id = string.lower(id or "")
    if not BMX.Bikes[id] then return nil end
    return id == "stock" and "bmx_base" or ("bmx_" .. id)
end

function BMX.BikeIDs()
    local out = {}
    for id in pairs(BMX.Bikes) do out[#out + 1] = id end
    table.sort(out)
    return out
end

--------------------------------------------------------------------------
-- Derive the extra entity classes.
--
-- Deferred to the next tick because lua/entities is loaded by the engine and
-- lua/autorun by the gamemode, and the order between them is not something to
-- rely on: scripted_ents.Get("bmx_base") has to already exist. One timer at
-- load is cheaper than a fragile ordering assumption.
--------------------------------------------------------------------------
function deriveOne(id)
    -- A MINIMAL table, not a copy of the base. Setting Base is what makes
    -- inheritance happen; copying the base's methods on top of that gives
    -- every derived bike its own frozen snapshot of them, so a later fix to
    -- bmx_base silently does not reach the derived classes.
    scripted_ents.Register({
        Type      = "anim",
        Base      = "bmx_base",
        BikeID    = id,
        PrintName = BMX.Bikes[id].printName,
        Category  = "BMX",
        Spawnable = true,
    }, "bmx_" .. id)

    registerDuplicator("bmx_" .. id)
end

local function derive()
    local base = scripted_ents.GetStored("bmx_base")
    if not base then
        ErrorNoHalt("[BMX] bmx_base is not registered -- extra bikes skipped\n")
        return
    end

    for _, id in ipairs(pending) do
        deriveOne(id)
    end

    pending = {}
    derived = true
end

timer.Simple(0, derive)

-- bmx_base is registered by the engine from lua/entities, not by derive(), so
-- the stock bike needs its own line or the one bike everybody actually spawns
-- is the one that cannot be duplicated.
registerDuplicator("bmx_base")

--------------------------------------------------------------------------
-- THE BIKES
--------------------------------------------------------------------------

-- The stock bike. It ships NO model: cl_init.lua draws a 20-inch BMX from
-- tubes and boxes (frame, fork, tall bars, seat, cranks that turn with the
-- rider's cadence, chain, pegs), sized from the config's own geometry. That
-- keeps the zero-content-dependency property and the no-ripped-assets rule,
-- and it still shows the wheels exactly where the simulation has them.
--
-- A real model is a `model` line here plus frameOffset / frameAngles to line
-- it up with the axle line. See docs/DESIGN.md, "Content".
BMX.RegisterBike("stock", {
    printName   = "BMX",
    description = "Street BMX with lean-driven handling.",
    frameColor  = Color(205, 35, 45),
})
