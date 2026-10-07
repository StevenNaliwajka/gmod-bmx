--[[--------------------------------------------------------------------------
    bmx/sh_bikes.lua

    The vehicle registry. Adding a bike is one table in here plus its model files.

    An entry describes a vehicle's APPEARANCE, its mount points, and -- since the
    per-bike physics work -- an optional `physics` table of config overrides.

    SINCE G22 THE REGISTRY IS A VEHICLE PLATFORM. BMX.RegisterVehicle{...} is the
    one door (wheels, balance mode, drive, seats, input map, pose set, tricks,
    grind points, physics; the vocabulary and the checks are sh_vehicles.lua), and
    BMX.RegisterBike(id, def) is the bike-shaped way in: it fills in the bike's
    wheels, balance, drive, input map and pose set and hands over. BMX.Bikes is
    the same table as BMX.Vehicles, so everything written against the bike
    registry -- bmx_spawn <id>, the spawn menu rows, the duplicator, the
    `bmx_base` class and the `bmx_<id>` classes, the convars -- still works.

    THE OVERRIDES ARE CHECKED AT REGISTRATION, against the real config, and a
    key that does not exist is a loud error rather than a value that goes
    nowhere. That check is the reason the field did not exist for so long: a
    `physics = {}` that silently does nothing is worse than no field at all, and
    the difference between the two is entirely whether it validates.
----------------------------------------------------------------------------]]

BMX = BMX or {}
-- BMX.Vehicles and its alias BMX.Bikes: one table (sh_vehicles.lua).
BMX.Vehicles = BMX.Vehicles or BMX.Bikes or {}
BMX.Bikes    = BMX.Vehicles

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
-- THE RIG CHECK (G01). A bike with a real model may say which bone is which:
--
--     bones = { bars = "bars", fork = "fork", frontWheel = "wheel_f",
--               rearWheel = "wheel_r", cranks = "cranks",
--               pedalL = "pedal_l", pedalR = "pedal_r" }
--
-- The first five are REQUIRED once a `bones` table is given at all, and the
-- last two optional; anything else is a typo. It is checked at registration, the
-- way `physics` is and for the same reason: a part pointed at a bone that
-- does not exist is a brake cable left behind on the frame when the bars turn,
-- and that is a bug nobody notices until the model has shipped. A bike with no
-- `bones` table is not checked (the procedural bike has no bones).
--
-- Whether each named bone EXISTS IN THE MODEL can only be asked on a client
-- with the model loaded; bmx_debug 2 draws each one's axes (cl_init.lua), which
-- is the visual half of the check.
--------------------------------------------------------------------------
local BONES_REQUIRED = { "bars", "fork", "frontWheel", "rearWheel", "cranks" }
local BONES_OPTIONAL = { "pedalL", "pedalR" }

function BMX.ValidateBones(id, bones)
    if bones == nil then return true end
    local bad = {}
    if not istable(bones) then
        bad[#bad + 1] = "bones is not a table"
    else
        local known = {}
        for _, k in ipairs(BONES_REQUIRED) do known[k] = true end
        for _, k in ipairs(BONES_OPTIONAL) do known[k] = true end
        for k, v in pairs(bones) do
            if not known[k] then
                bad[#bad + 1] = string.format("unknown bone role %q", tostring(k))
            elseif type(v) ~= "string" or v == "" then
                bad[#bad + 1] = string.format("%s needs a bone name", k)
            end
        end
        for _, k in ipairs(BONES_REQUIRED) do
            if bones[k] == nil then bad[#bad + 1] = "missing required bone " .. k end
        end
    end
    if #bad > 0 then
        table.sort(bad)
        ErrorNoHalt(string.format("[BMX] bike %q has a bad `bones` table: %s.\n",
            tostring(id), table.concat(bad, ", ")))
        return false
    end
    return true
end

--------------------------------------------------------------------------
-- Register a vehicle.
--
--   id            unique, lowercase. Becomes entity class "bmx_<id>".
--   family        "bike" | "board" | "skates" | "scooter" | "moto": the spawn
--                 menu heading and the admin toggle that switches it off.
--   wheels        a list of { pos, radius, steer, drive, front, name }, or a
--                 function of the config returning one (a bike's wheelbase is
--                 per-bike). `pos` is the AXLE in chassis space; the suspension
--                 mount is restLength above it. `radius` overrides the config's
--                 for this wheel. `steer` is false, "fork" (the single-track
--                 balance steers it) or a function
--                 (wheel, ent, st, inp, cfg, dt, speed) -> radians, called
--                 every grounded substep: a skateboard's truck lean is one.
--                 `drive` takes a share of the drive torque. `front` is which
--                 axle's brake it takes (default: pos.x > 0).
--   balance       "singletrack" | "board" | "none": sv_balance.lua.
--   drive         { kind = "pedal" | "throttle" | "push" | "none", ... }
--   seats         { { model, offset, angles } }: the rider's seat. Omitted, it
--                 is the config's Chassis.seatOffset / seatAngles.
--   input         an id in BMX.InputMaps (sh_vehicles.lua).
--   pose          an id in BMX.PoseSets (cl_rider.lua fills each in).
--   tricks        "all", or a list of trick ids this vehicle can do.
--   grindPoints   false, or { crank = Vector|fn(cfg)|false, pegs = {y, z, x}|fn|false }
--   physics       per-vehicle config overrides, below.
--   hidden        left out of the spawn menu and BikeIDs.
--   debugOnly     bmx_spawn needs bmx_debug >= 1 (the test cart).
--
-- Every field is CHECKED (BMX.ValidateVehicle), and a bad one is a loud error
-- and the vehicle is NOT registered: it could not ride anyway.
--
-- The appearance fields are the ones RegisterBike has always taken:
--
--   def.printName spawnmenu label
--   def.model     frame model. Optional: without one the whole bike is drawn
--                 procedurally, which is what the stock bike does.
--   def.colorIndex which BMX.Palette colour it starts in (sh_color.lua).
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
--
--   def.bones     optional rig map for a model, checked at registration: see
--                 BMX.ValidateBones above. Unknown keys are a loud error.
--
-- An invalid `physics` or `bones` is reported and the vehicle is still
-- registered, as it always was: those two were checked before there was a
-- platform, and the tests pin it.
--------------------------------------------------------------------------
function BMX.RegisterVehicle(def)
    if not istable(def) then
        ErrorNoHalt("[BMX] RegisterVehicle wants a table.\n")
        return false
    end
    if isstring(def.id) then def.id = string.lower(def.id) end

    -- What a vehicle that says nothing gets: it stands on its wheels, takes the
    -- plain controls, sits in the stock pose, does no tricks and cannot grind.
    -- Everything the bike needs is spelled out by RegisterBike instead.
    if def.balance == nil then def.balance = "none" end
    if def.drive == nil then def.drive = { kind = "none" } end
    if def.input == nil then def.input = "drive" end
    if def.pose == nil then def.pose = "seated" end
    if def.tricks == nil then def.tricks = {} end
    if def.grindPoints == nil then def.grindPoints = false end

    -- Loudly, and before anything can ride it.
    local valid = BMX.ValidateVehicle(def)
    local id = def.id
    BMX.ValidatePhysics(id, def.physics)
    BMX.ValidateBones(id, def.bones)
    if not valid then return false end

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

    BMX.Vehicles[id] = def

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

    -- THE SPAWN MENU. `Category` stays "BMX" -- the one heading every vehicle
    -- has always been under, and what the suite pins -- and the family's heading
    -- (Bikes, Boards, Scooters, Motor) rides along as `Subcategory`, so moving
    -- the menu over to the four headings is a change to this one row, not to
    -- the registry. A hidden vehicle (the test cart) gets no row at all.
    if not def.hidden then
        list.Set("SpawnableEntities", BMX.ClassFor(id), {
            PrintName = def.printName,
            ClassName = BMX.ClassFor(id),
            Category  = "BMX",
            Subcategory = BMX.Families[def.family].category,
            Family    = def.family,
            Author    = def.author or "naliwajka",
            Information = def.description or "",
        })
    end
    return def
end

--------------------------------------------------------------------------
-- Register a bike: RegisterVehicle with the bike's platform fields filled in
-- (two wheels in line, the front one steered by the fork; single-track balance;
-- the pedal drive; the bike's keys and rider pose; every trick; a chainring and
-- pegs to grind on). Anything the table says itself wins.
--------------------------------------------------------------------------
function BMX.RegisterBike(id, def)
    def = def or {}
    def.id          = string.lower(id)
    def.family      = def.family      or "bike"
    if def.wheels == nil then def.wheels = BMX.BikeWheels end
    def.balance     = def.balance     or "singletrack"
    def.drive       = def.drive       or { kind = "pedal" }
    def.input       = def.input       or "bike"
    def.pose        = def.pose        or "bike"
    if def.tricks == nil then def.tricks = "all" end
    if def.grindPoints == nil then def.grindPoints = BMX.BikeGrindPoints end
    return BMX.RegisterVehicle(def)
end

function BMX.ClassFor(id)
    id = string.lower(id or "")
    if not BMX.Bikes[id] then return nil end
    return id == "stock" and "bmx_base" or ("bmx_" .. id)
end

-- The vehicles a player can see and spawn: everything but the hidden ones.
-- (Named for the bikes it was written for; boards and scooters are in it.)
function BMX.BikeIDs()
    local out = {}
    for id, def in pairs(BMX.Vehicles) do
        if not def.hidden then out[#out + 1] = id end
    end
    table.sort(out)
    return out
end

-- Every registered vehicle, hidden ones too: what "is this entity class one of
-- ours?" and the per-player limit have to count.
function BMX.VehicleIDs()
    local out = {}
    for id in pairs(BMX.Vehicles) do out[#out + 1] = id end
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
    colorIndex  = 1,            -- red; see BMX.Palette in sh_color.lua
})

-- THE OTHER TWO are the stock bike with other geometry, and nothing else: no
-- model, no new code, only `physics` overrides. Everything that depends on
-- size follows from them -- the hull is rebuilt from wheelbase and radius and
-- balanced onto massCenterExpected (BMX.CollisionBoxes), the inertia is
-- measured off the real body (BMX.CacheInertia), and the procedural frame is
-- drawn scaled by wheelbase / 39. The one thing that does NOT scale on its own
-- is the seat, which is where the rider is put; so each one scales it by the
-- same wheelbase / 39 the frame is drawn at, or the rider would hover above a
-- small saddle or sink into a big one.
--
-- Every headless case that is about riding runs again on each of them
-- (sv_test_cases.lua, T.Variant), against the same bands as the stock bike.

-- 24-inch cruiser: longer and heavier. The bigger wheel at the same gearing
-- and cadence is a higher top speed (~420 u/s against ~350), and the same
-- crank torque through a bigger wheel pushes a heavier bike less, so it is
-- slower off the line: crankTorque is raised only far enough that it still
-- climbs a funbox. Steadier, because a longer wheelbase is.
BMX.RegisterBike("cruiser", {
    printName   = "BMX Cruiser",
    description = "24-inch cruiser: longer, heavier and faster at the top end, slower off the line.",
    colorIndex  = 8,            -- blue
    physics = {
        Chassis = { mass = 94, seatOffset = Vector(-11.6, 0, 19.8) },  -- x 43/39
        -- restLength 10 rather than 8: more travel for a bigger wheel, and
        -- the wheel boxes' floor -(radius - restLength) back at the stock -2.
        -- At 8 it was -4, below the chainring, and a crank grind is held by
        -- whichever is lower -- so the cruiser ground on its wheel boxes'
        -- floor 2.6 u above the pipe (grind_pipe@cruiser, on the dev server).
        Wheel   = { radius = 12, wheelbase = 43, restLength = 10 },
        Drive   = { crankTorque = 340000 },
    },
})

-- 16-inch mini: short and light. Lower top speed (~270 u/s), quicker to turn,
-- and a ridden mini is mostly a big rider on a small bike, which is the joke.
BMX.RegisterBike("mini", {
    printName   = "Mini BMX",
    description = "16-inch mini: short, light and twitchy, with a low top speed.",
    colorIndex  = 3,            -- yellow
    physics = {
        Chassis = { mass = 82, seatOffset = Vector(-9.2, 0, 15.7) },   -- x 34/39
        Wheel   = { radius = 8, wheelbase = 34 },
    },
})

--------------------------------------------------------------------------
-- THE TEST CART: the platform's proof that it is not a bicycle.
--
-- Four wheels in a rectangle, no balance mode at all (`none`: it stands on its
-- suspension), a throttle drive on the two rear wheels, and the front pair
-- steered by a FUNCTION of the rider's key rather than by a fork. Nothing in
-- it is a bike except the code that has been generalised to run it, which is
-- the point: it exercises N wheels, per-wheel steer and drive, the `none`
-- balance, the throttle drive and the plain input map before the skateboard
-- (G23) depends on any of them.
--
-- HIDDEN and debugOnly. It is not in the spawn menu or BikeIDs, and bmx_spawn
-- refuses it unless the player has bmx_debug >= 1; the suites spawn the class
-- directly. It is registered in every game because the offline and headless
-- suites run against the shipped files, and a vehicle that exists only in the
-- tests would be a vehicle the tests do not test.
--
-- The layout is a go-kart's, a 32 by 22 rectangle about the origin, on the
-- stock wheel (radius 10). Its torque and top speed are chosen to be
-- unremarkable: a cart that drives forward, not a tuned vehicle.
--------------------------------------------------------------------------
-- The steer function: the key's lean, a third of a radian at a crawl and less as
-- it goes faster, so the sideways acceleration stays under ~120 u/s^2
-- (v^2 * tan(steer) / wheelbase, with the wheelbase 32): a cart this narrow rolls
-- over a pull of a third of a g and there is no balance mode to hold it.
-- (wheel, ent, st, inp, cfg, dt, speed) -> radians.
local function cartSteer(w, ent, st, inp, cfg, dt, speed)
    local v2 = math.max((speed or 0) ^ 2, 1)
    return inp.lean * math.min(0.3, 120 * 32 / v2)
end

BMX.RegisterVehicle({
    id          = "testcart",
    printName   = "Test cart",
    description = "Four wheels and a throttle: the platform's test vehicle. Not in the menu.",
    family      = "board",
    hidden      = true,
    debugOnly   = true,
    colorIndex  = 5,
    wheels = {
        { pos = Vector( 16,  11, 0), steer = cartSteer, drive = false, name = "front_l" },
        { pos = Vector( 16, -11, 0), steer = cartSteer, drive = false, name = "front_r" },
        { pos = Vector(-16,  11, 0), steer = false,     drive = true,  name = "rear_l" },
        { pos = Vector(-16, -11, 0), steer = false,     drive = true,  name = "rear_r" },
    },
    balance = "none",
    drive   = { kind = "throttle", torque = 110000, maxSpeed = 320 },
    input   = "drive",
    pose    = "seated",
    tricks  = {},
    grindPoints = false,
})
