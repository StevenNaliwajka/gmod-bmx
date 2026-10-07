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
--   seats         { rider = {...}, pegs = {...}, child = {...} }: the seats. Each is
--                 { model, offset, angles, massFactor }, every key optional (an empty
--                 table is all defaults, sh_passenger.lua). `rider` is always there;
--                 omitted, it is the config's Chassis.seatOffset / seatAngles. `pegs` is
--                 a second rider on the rear pegs, `child` a child seat. The older list
--                 form, { { model, offset, angles } }, is still the rider's seat.
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

    -- A WORN VEHICLE (G25) is not an entity: nothing to derive a class for, no duplicator,
    -- no spawn row of its own and no entity for the per-player limit to count. It is
    -- still in BMX.Vehicles (the config, the trick list and the grind points are read from
    -- there), in WornIDs and in GettableIDs (the /bike window lists it, and bmx_spawn
    -- equips it), and NOT in BikeIDs, which is the entities.
    if def.worn then return def end

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
    -- A worn vehicle (skates) has no entity class: there is nothing to create.
    if BMX.Bikes[id].worn then return nil end
    return id == "stock" and "bmx_base" or ("bmx_" .. id)
end

-- The vehicles a player can see and spawn: everything but the hidden ones and the worn ones.
-- (Named for the bikes it was written for; boards and scooters are in it.)
function BMX.BikeIDs()
    local out = {}
    for id, def in pairs(BMX.Vehicles) do
        if not def.hidden and not def.worn then out[#out + 1] = id end
    end
    table.sort(out)
    return out
end

-- Everything a player can GET: the spawnable vehicles and the worn ones (BMX.WornIDs), which
-- they put on instead. What bmx_spawn accepts, and what the /bike window lists.
function BMX.GettableIDs()
    local out = BMX.BikeIDs()
    for id, def in pairs(BMX.Vehicles) do
        if def.worn and not def.hidden then out[#out + 1] = id end
    end
    table.sort(out)
    return out
end

-- Every registered vehicle, hidden ones too: what "is this entity class one of
-- ours?" and the per-player limit have to count.
function BMX.VehicleIDs()
    local out = {}
    for id, def in pairs(BMX.Vehicles) do
        if not def.worn then out[#out + 1] = id end
    end
    table.sort(out)
    return out
end

-- The worn vehicles (skates): registered, equipped rather than spawned, and with no
-- entity class, which is why VehicleIDs (the classes) leaves them out.
function BMX.WornIDs()
    local out = {}
    for id, def in pairs(BMX.Vehicles) do
        if def.worn then out[#out + 1] = id end
    end
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
    look        = "bmx",          -- the detailed BMX model (cl_bikegeo.lua)
    printName   = "BMX",
    description = "Street BMX with lean-driven handling.",
    colorIndex  = 1,            -- red; see BMX.Palette in sh_color.lua
    -- A second rider can stand on the rear pegs (G11): E on the back of a ridden bike.
    seats       = { pegs = {} },
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
    look        = "bmx",          -- the detailed BMX model (cl_bikegeo.lua)
    printName   = "BMX Cruiser",
    description = "24-inch cruiser: longer, heavier and faster at the top end, slower off the line.",
    colorIndex  = 8,            -- blue
    seats       = { pegs = {} },
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
    look        = "bmx",          -- the detailed BMX model (cl_bikegeo.lua)
    printName   = "Mini BMX",
    description = "16-inch mini: short, light and twitchy, with a low top speed.",
    colorIndex  = 3,            -- yellow
    physics = {
        Chassis = { mass = 82, seatOffset = Vector(-9.2, 0, 15.7) },   -- x 34/39
        Wheel   = { radius = 8, wheelbase = 34 },
    },
})

--------------------------------------------------------------------------
-- 700c ROAD BIKE (G09). The first bike with GEARS, and the first that is not a
-- BMX in different clothes: a long, light frame on big narrow tyres, drop bars, a
-- tucked rider, built to be fast on the flat and poor over a jump.
--
-- WHAT IS DIFFERENT, and why each number is where it is:
--   wheel 13.8 / wheelbase 48   a 700c wheel (~27 in across) and a bike a fifth
--                               longer than the BMX. Long means steady and slow to
--                               turn in, which is the road bike's character.
--   restLength 11.8            more travel for a bigger wheel, and the wheel boxes'
--                               floor -(radius - restLength) back at the stock -2,
--                               under the chainring by no more than a BMX's is (the
--                               cruiser's note, above, is why it matters to a grind).
--   mass 78                     the rider and a bike half the weight of a BMX's.
--   grip 1.5, rolling 0.007     narrow, hard, high-pressure tyres: more grip per
--                               contact patch and much less rolling loss.
--   dragArea 0.0037             a rider tucked over drops presents well under the
--                               BMX rider's frontal area.
--   gears                       eight ratios, 1.2 to 3.5. The bottom one (1.2) is a
--                               standing start in a low gear, the top one at the
--                               legs' ceiling is 12.6 * 3.5 * 13.8 = 608 u/s and
--                               terminal speed there is ~1.6x the BMX's (measured on
--                               the plant, tests/test_road.lua) with the legs at
--                               ~100 rpm. Neighbouring gears' 60-110 rpm bands
--                               overlap all the way up from a jog (BMX.Gears.Covers).
--   crankTorque 310000          a touch over the BMX's: the gears do the rest. A low
--                               gear multiplies the push at the wheel, which the
--                               tyre has grip for (1.5 * the rear's share of 78 kg).
--   Hop.popSpeed 190           a road bike does not bunny hop like a BMX does.
--   Balance leanKp/Kd, fadeInHigh   the lean (and so the steer that comes from it)
--                               is answered faster once the bike is moving: the
--                               assist is whole by 95 u/s, not 110. Quicker at
--                               speed, which is where a road bike lives.
--
-- THE SCORE IS x1.5, "the road bike tax": tricks are allowed and still pay, and
-- paying more is what makes a road bike backflip a thing a server remembers.
BMX.RegisterBike("road", {
    printName   = "Road Bike",
    description = "700c road bike: long, light and fast, with gears ([ ] or the mouse wheel), drop bars and a tucked rider. Tricks score x1.5.",
    colorIndex  = 13,           -- white
    gears       = { ratios = { 1.2, 1.5, 1.8, 2.15, 2.5, 2.85, 3.15, 3.5 }, start = 4 },
    input       = "road",
    pose        = "road",
    barStyle    = "drop",
    scoreMult   = 1.5,
    physics = {
        Chassis = { mass = 78, seatOffset = Vector(-12.9, 0, 22.2) },  -- x 48/39
        Wheel   = { radius = 13.8, wheelbase = 48, restLength = 11.8,
                    grip = 1.5, rollingResistance = 0.007 },
        Drive   = { crankTorque = 310000, dragArea = 0.0037 },
        Hop     = { popSpeed = 190 },
        Balance = { leanKp = 300, leanKd = 70, fadeInHigh = 95 },
    },
})

--------------------------------------------------------------------------
-- THE FIXIE (G10): a track bike with ONE gear and no freewheel. The cranks are
-- locked to the rear wheel (drive kind "fixed", sv_fixie.lua), so coasting turns the
-- legs and drags the bike down a little, S is a skid stop, S at a standstill pedals
-- backwards (fakie, scored) and A or D at a standstill is a trackstand (scored).
-- Its only brake is its legs, so LMB does nothing unless the server turns
-- bmx_fixie_frontbrake on: the `bike_rearonly` input map.
--
-- 700c wheels and a short, light frame (the numbers a road bike's, without the
-- gears): gearRatio 2.6, which is a 46t ring on a 17t cog (2.7) near enough, puts the
-- legs' ceiling at 12.6 * 2.6 * 13.8 = 452 u/s and the top speed under it. `fixedGear`
-- is the config's own switch for "the wheel has no freewheel floor" (sv_wheel.lua):
-- without it the wheel could not turn slower than the ground and the legs' drag
-- would be a number nothing read. `rearBrake` is twice a BMX's: the brake is the
-- rider's LEGS, which are a good deal stronger than a caliper, so S really does lock
-- the wheel and skid it (a skid stop from 15 mph is ~3.7 m on the plant; at the BMX's
-- 95,000 it was 7.6 m, which is a brake, not a skid).
BMX.RegisterBike("fixie", {
    printName   = "Fixie",
    description = "Fixed-gear track bike: the cranks are locked to the rear wheel. Coasting turns the legs, S skids, S at a standstill rolls it backwards (fakie), A/D at a standstill is a trackstand. No front brake.",
    colorIndex  = 2,            -- orange
    drive       = { kind = "fixed" },
    input       = "bike_rearonly",
    physics = {
        Chassis = { mass = 80, seatOffset = Vector(-11.85, 0, 20.3) },  -- x 44/39
        Wheel   = { radius = 13.8, wheelbase = 44, restLength = 11.8, grip = 1.6, rollingResistance = 0.008 },
        Drive   = { gearRatio = 2.6, fixedGear = true, dragArea = 0.0045, rearBrake = 200000 },
    },
})

--------------------------------------------------------------------------
-- THE CITY BIKE (G12): a Dutch bike. Upright, heavy and unhurried, with swept-back
-- bars, a coaster brake, a front basket, a kickstand (every bike has one), the bell
-- (sv_bell.lua, R) and a child seat that is on a context-menu switch.
--
--   wheel 14 / wheelbase 52     a 28-inch wheel and a long frame; the seat scales
--                               with it, x 52/39
--   mass 112                    heavy: the rider, a steel frame, a rack and a basket
--   Drive maxCadence 9.5        a rider in no hurry: the legs' ceiling is 91 rpm.
--                               With gearRatio 2.0 on the 28-inch wheel the top speed
--                               is ~235 u/s (21 km/h on the plant), three quarters of
--                               the BMX's, and a standing start takes a second longer
--   dragArea 0.0065             sat up straight, a sail
--   Hop.popSpeed 150            it is not a bike for hopping
--   Balance maxLean 34 deg      a Dutch bike does not lean into a corner like a BMX
--   coaster, bike_rearonly      S is the brake (a coaster brake); LMB does nothing
--   basket                      a box in front of the bars: 20 deep, 20 wide, 16 tall,
--                               its floor a hand over the wheel. Props up to 12 kg ride
--                               in it (sv_basket.lua)
--   seats = { child = {} }      no pegs: a Dutch bike carries a child on the back
BMX.RegisterBike("city", {
    printName   = "City Bike",
    description = "Dutch-style city bike: upright, heavy and slow, with a coaster brake (S), swept-back bars, a front basket (props stay in while you ride gently), a kickstand and a bell. A child seat is on the context menu. LMB does nothing.",
    colorIndex  = 14,           -- black
    drive       = { kind = "coaster" },
    input       = "bike_rearonly",
    pose        = "upright",
    barStyle    = "swept",
    seats       = { child = {} },
    basket      = { mins = Vector(23, -10, 21), maxs = Vector(43, 10, 37), maxMass = 12 },
    physics = {
        Chassis = { mass = 112, seatOffset = Vector(-14, 0, 24) },     -- x 52/39
        Wheel   = { radius = 14, wheelbase = 52, restLength = 12, grip = 1.35 },
        Drive   = { maxCadence = 9.5, gearRatio = 2.0, crankTorque = 360000, dragArea = 0.0065 },
        Hop     = { popSpeed = 150 },
        Balance = { maxLean = math.rad(34) },
    },
})

--------------------------------------------------------------------------
-- THE UNICYCLE (G13): one 20-inch wheel, a fixed gear (the cranks ARE the wheel's
-- axle: no freewheel, no brake, S pedals backwards) and nothing to hold it up but the
-- rider. The `unicycle` balance mode (sv_unicycle.lua) balances it on two axes at
-- once, with bmx_unicycle_assist (default 0.6) doing a share of the work.
--
--   wheelbase 0, one wheel at the origin   a one-wheeled vehicle: the hull is one wheel
--                               box and the body (sh_util.lua, BMX.CollisionBoxes)
--   mass 66, mass centre 20 up  a rider and a light frame, the weight a hand above the
--                               hub; with the 10-unit wheel, the contact is 30 below it
--   spring 15000, damper 650, loadShare 1   ONE wheel carries all of the weight, where a
--                               bike's two carry half each: the spring is stiffer to match
--                               (3 units of sag at 66 kg), and the rest height is derived
--                               from the share (BMX.RestHeight)
--   Drive gearRatio 1, maxCadence 15       direct drive: the top speed is the legs'
--                               ceiling, 15 * 10 = 150 u/s (3.8 m/s, 13.7 km/h), which is
--                               what a rider gets out of a 20-inch wheel
--   crankTorque 120000          a tenth of a g of acceleration is what a unicycle does and
--                               a good deal of what the pedals are FOR: the tyre force at
--                               the patch is also the fore-and-aft balance's actuator
--   Hop popSpeed 130, no kick   a pop straight up: no nose-up kick to roll into a manual
--   Crash tipRoll 36, tipPitch 40 deg   falls over and throws the rider long before a
--                               bike's 65 and 75: past ~32 the assist has let go anyway
--   tricks uni_idle, uni_hop    no flips, no grinds: a rider who spins a unicycle in the
--                               air is not what this vehicle is for
BMX.RegisterVehicle({
    id          = "unicycle",
    family      = "bike",
    printName   = "Unicycle",
    description = "One wheel, a fixed gear and no brake. W / S pedal forward and back to stay under yourself, A / D lean, the mouse twists you round. bmx_unicycle_assist sets how much is done for you. Tricks: idle (rock in place) and hop. Falls are ragdolls.",
    colorIndex  = 6,
    wheels = { { pos = Vector(0, 0, 0), drive = true, steer = false, name = "wheel" } },
    balance = "unicycle",
    drive   = { kind = "fixed", reverse = true },
    input   = "unicycle",
    pose    = "unicycle",
    tricks  = { "uni_idle", "uni_hop" },
    grindPoints = false,
    drawer  = "unicycle",
    physics = {
        Chassis = { mass = 66, hullMin = Vector(-4, -4, 2), hullMax = Vector(4, 4, 38),
                    massCenterExpected = Vector(0, 0, 20), seatOffset = Vector(0, 0, 19),
                    barHullCentre = false, pegHullHalfWidth = false },
        Wheel   = { radius = 10, wheelbase = 0, restLength = 8, spring = 15000, damper = 650, loadShare = 1,
                    grip = 1.4 },
        Drive   = { gearRatio = 1, maxCadence = 15, crankTorque = 120000, dragArea = 0.0045 },
        Hop     = { popSpeed = 130, forwardBias = 0, pitchImpulse = 0 },
        Crash   = { tipRoll = math.rad(36), tipPitch = math.rad(40) },
    },
})

--------------------------------------------------------------------------
-- THE PENNY-FARTHING (G13): a 26-unit front wheel with the cranks on its hub
-- (`front-direct`: the front wheel is the drive wheel), a 6-unit wheel at the back, and
-- a rider sat a long way up. The `pennyfarthing` balance is the single-track one with
-- the header on its pitch (sv_penny.lua): hard on the front brake at speed and the whole
-- thing goes over the bars. That is the physics, not a script: the mass centre is 62 units
-- off the ground and 18 behind the front patch, which a brake harder than ~0.3 g
-- (g * 18 / 62) takes the back wheel off with.
--
--   Wheel radius 26, rearRadius 6   the big wheel and the small one. The rear axle is
--                               radius - rearRadius LOWER on the chassis (-20): the
--                               wheels' registration gives it, and the hull is built
--                               from the same two numbers (BMX.CollisionBoxes)
--   wheelbase 44, loadShare 0.75   the axles' distance and the front's share of the weight:
--                               the rider is over the big wheel, which carries about three
--                               quarters of it (rest height is derived from the share)
--   mass centre (4, 0, 36)      36 above the front axle = 62 above the ground, and 18
--                               behind the front patch (the header's lever)
--   seat (8, 0, 33)             the saddle, behind the top of the big wheel
--   Drive gearRatio 1, maxCadence 9, crankTorque 340000   direct drive: a stroke is a
--                               wheel turn. The legs' ceiling is 9 * 26 = 234 u/s
--                               (21 km/h), a penny-farthing's top gear
--   frontBrake 700000           the spoon brake: ~0.5 g at the tyre, so a full pull is
--                               over the 0.3 g the header needs and half a pull is not
--   inertia 600                 the big wheel's flywheel; the small one's is that times
--                               (6/26)^2 (BMX.Wheel:WheelConfig), as a disc's goes
--   Balance maxLean 28, maxSteer 30 deg   it leans less than a BMX and steers less: it
--                               is a big wheel under a high rider
--   tricks none                 the header is the trick
BMX.RegisterVehicle({
    id          = "penny",
    family      = "bike",
    printName   = "Penny-Farthing",
    description = "A 26-unit front wheel with the pedals on its hub, a tiny one behind, the rider a long way up. It leans and steers like a bike, and a hard front brake at speed takes you over the bars: a header.",
    colorIndex  = 7,
    wheels = function(cfg)
        local half = cfg.Wheel.wheelbase * 0.5
        local rr = cfg.Wheel.rearRadius or 6
        return {
            { pos = Vector( half, 0, 0), steer = "fork", drive = true,  name = "front" },
            { pos = Vector(-half, 0, -(cfg.Wheel.radius - rr)), radius = rr, steer = false, drive = false, name = "rear" },
        }
    end,
    balance = "pennyfarthing",
    drive   = { kind = "front-direct" },
    input   = "penny",
    pose    = "upright",
    tricks  = {},
    grindPoints = false,
    drawer  = "pennyfarthing",
    physics = {
        Chassis = { mass = 84, hullMin = Vector(-6, -4, 14), hullMax = Vector(18, 4, 62),
                    massCenterExpected = Vector(4, 0, 36), seatOffset = Vector(8, 0, 33),
                    barHullCentre = false, pegHullHalfWidth = false },
        Wheel   = { radius = 26, rearRadius = 6, wheelbase = 44, restLength = 8, spring = 16000, damper = 800,
                    loadShare = 0.75, inertia = 600, grip = 1.3, rollingResistance = 0.010 },
        Drive   = { gearRatio = 1, maxCadence = 11, crankTorque = 340000, frontBrake = 700000, dragArea = 0.0065 },
        Balance = { maxLean = math.rad(28), maxSteer = math.rad(30) },
        Hop     = { popSpeed = 70 },
    },
})

--------------------------------------------------------------------------
-- THE TANDEM (G13): a long frame, two saddles, two pairs of legs. The second saddle is
-- G11's second seat (E at the back of an occupied tandem) with `pedals = true`: the
-- stoker's W adds their throttle to the captain's, and the two torques sum
-- (sv_tandem.lua). The front rider steers: a passenger's keys are not read for anything
-- but the pedalling.
--
--   wheelbase 70                a long frame, x 70/39 = 1.8: slow to turn, steady at speed
--   Wheel radius 13, spring 12000   28-inch wheels, and the spring for a bike that will carry
--                               two (about 190 kg with the stoker)
--   mass 118, stoker 0.6        the captain, the longer frame and its second set of
--                               cranks; the stoker adds 0.6 of that (71 kg), 1.6x in all
--   seats                       the captain at x = +9 over the front half, the stoker at
--                               x = -18, 27 units behind: both over the frame's midpoint
--   Drive gearRatio 2.4, maxCadence 11.5   three quarters of a road bike's gearing, for the
--                               weight: the top speed is the legs' ceiling, 11.5 * 2.4 * 13
--                               = 359 u/s, whoever is pedalling, and a tandem with both is
--                               quicker to GET there
--   tricks none                 it is a long bike with two people on it
BMX.RegisterBike("tandem", {
    printName   = "Tandem",
    description = "A long two-seat bike. The captain (E) steers and brakes; get on behind them with E at the back for the second seat: the stoker's W adds their pedalling to the captain's, and the torques sum.",
    colorIndex  = 8,
    pose        = "upright",
    input       = "bike_rearonly",
    tricks      = {},
    grindPoints = false,
    drawer      = "tandem",
    seats = {
        rider = { pedals = true },
        pegs  = { offset = Vector(-18, 0, 22), massFactor = 0.6, pedals = true },
    },
    physics = {
        Chassis = { mass = 118, hullMin = Vector(-30, -4, 2), hullMax = Vector(24, 4, 38),
                    massCenterExpected = Vector(-3, 0, 20), seatOffset = Vector(9, 0, 22) },
        Wheel   = { radius = 13, wheelbase = 70, restLength = 10, spring = 12000, damper = 700 },
        Drive   = { gearRatio = 2.4, maxCadence = 11.5, crankTorque = 340000, dragArea = 0.0075 },
        Hop     = { popSpeed = 110 },
        Balance = { maxLean = math.rad(34) },
    },
})

--------------------------------------------------------------------------
-- THE DOWNHILL BIKE (G13): long travel, big tyres, heavy, and stable at speed. It is the
-- stock bike with other numbers and no new code (the platform's `physics` overrides,
-- DESIGN 6c), which is the point: spring and damper are what a DH bike IS.
--
--   Wheel restLength 16, spring 8000, damper 900, bumpStop 90000   the travel is double a BMX's
--                               (8) and the spring a bit softer, so it sags 4.4 units and has
--                               11.6 left; the damper is heavy (about critical against the
--                               effective mass) so a drop is soaked and does not bounce, and
--                               the bump stop is the last resort. w * dt = 0.30 at 66 Hz
--   stepMax 6.5                 THE SAG MUST BE UNDER stepMax. A wheel's compression may rise
--                               at most stepMax in one substep (sv_wheel.lua, "a step is not
--                               a spring"), and a spawned wheel starts from none: a sag of
--                               more than stepMax is refused as a step, every substep, and the
--                               bike sits on its hull. (The stock 5 against a sag of 5.06 did
--                               exactly that: the spring never compressed.) Half the radius
--                               is the tallest step a wheel rolls onto, which is 6.75
--   radius 13.5, grip 1.7       27.5-inch wheels and knobbly tyres: grip, and more rolling loss
--   mass 118, wheelbase 46      heavy and long: steady, slow to turn
--   Crash soakSpeed 380, maxImpactSpeed 520   the landing soak and the hard-hit threshold,
--                               raised for the travel: a 4 m drop is a Tuesday
--   Balance leanKp 300, fadeInHigh 90   the lean answered a little faster and whole by
--                               90 u/s, as the road bike's is: stable at speed is the brief
BMX.RegisterBike("dh", {
    printName   = "Downhill Bike",
    description = "Long-travel downhill bike: big tyres, a soft heavy suspension that eats drops, heavy and very stable at speed. Built for the hill.",
    colorIndex  = 9,
    physics = {
        Chassis = { mass = 118, seatOffset = Vector(-12.4, 0, 21.2) },     -- x 46/39
        Wheel   = { radius = 13.5, wheelbase = 46, restLength = 16, spring = 8000, damper = 900,
                    bumpStop = 90000, stepMax = 6.5, grip = 1.7, rollingResistance = 0.016 },
        Drive   = { gearRatio = 2.2, crankTorque = 380000, maxCadence = 11, dragArea = 0.0062 },
        Hop     = { popSpeed = 160 },
        Crash   = { soakSpeed = 380, maxImpactSpeed = 520 },
        Balance = { leanKp = 300, fadeInHigh = 90 },
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
