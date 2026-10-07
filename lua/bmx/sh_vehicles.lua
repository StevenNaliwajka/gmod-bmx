--[[--------------------------------------------------------------------------
    bmx/sh_vehicles.lua

    THE VEHICLE PLATFORM (G22): what a vehicle IS, as data, and the checks that
    make it loud when the data is wrong. The registry itself (RegisterVehicle,
    RegisterBike, the entity classes, the spawn menu) is sh_bikes.lua; this file
    holds the vocabulary it is written in, so that a new vehicle is

        a registry entry + a balance mode + an input map + a pose set + a trick list

    and the bike is one client of the platform rather than the thing the core was
    shaped around. (The competitor's architecture is a bicycle, and their author
    stopped at the skateboard for exactly that reason.)

    WHAT LIVES HERE
        BMX.Families          family -> spawn menu category and the admin toggle
        BMX.BalanceModeNames  the balance modules a vehicle may name (sv_balance.lua
                              holds the code; the NAMES are here because a
                              registration is checked before any server file loads)
        BMX.DriveKinds        the drives, and what each one may be given
        BMX.InputMaps         action -> key + context, per kind of vehicle
        BMX.PoseSets          the rider pose sets cl_rider.lua fills in
        BMX.ValidateVehicle   the whole-definition check

    WHY THE VALIDATION IS SO FUSSY. It is the same bargain BMX.ValidatePhysics
    made: a `wheels = {...}` with a misspelt key that silently does nothing is
    worse than no field at all, because the vehicle then rides on whatever the
    default was and nobody finds out until somebody wonders why it feels wrong.
    Every unknown key, at every level, is an error at REGISTRATION.

    INPUT MAPS ARE TABLES, not a block of IN_* tests in the middle of a usercmd
    hook, so that G19's keybind panel is generated from the same table the
    simulation reads and the two cannot disagree about what a key does.
----------------------------------------------------------------------------]]

BMX = BMX or {}

-- BMX.Bikes is the vehicle registry under its old name. They are THE SAME
-- TABLE, not a copy, so `BMX.Bikes[id]`, `BMX.Bikes.stock` and a test that
-- writes `BMX.Bikes.x = nil` keep meaning what they always did, and a skateboard
-- registered tomorrow is in it too.
BMX.Vehicles = BMX.Vehicles or BMX.Bikes or {}
BMX.Bikes    = BMX.Vehicles

--------------------------------------------------------------------------
-- FAMILIES. Which spawn menu heading a vehicle sits under, and the one server
-- toggle that switches the whole heading off (bmx_allow_<key>, sv_rules.lua).
--
-- Five families, four headings: skates are wheeled footwear and live with the
-- boards. Only Bikes has anything in it today; the rest are ready for G23, G24,
-- G25, G14 and G15 so none of them has to touch the menu or the settings.
--------------------------------------------------------------------------
BMX.Families = {
    bike    = { category = "Bikes",    key = "bikes"    },
    board   = { category = "Boards",   key = "boards"   },
    skates  = { category = "Boards",   key = "boards"   },
    scooter = { category = "Scooters", key = "scooters" },
    moto    = { category = "Motor",    key = "motor"    },
}

-- The headings, in menu order, for the settings rows and the menu.
BMX.SpawnCategories = {
    { key = "bikes",    label = "Bikes"    },
    { key = "boards",   label = "Boards"   },
    { key = "scooters", label = "Scooters" },
    { key = "motor",    label = "Motor"    },
}

--------------------------------------------------------------------------
-- BALANCE MODES. Code in sv_balance.lua (BMX.BalanceModes[name]); only the
-- names are needed to check a registration.
--
--   singletrack   today's code, moved: lean-derived steering, wheelies, the
--                 kickstand. Needs exactly one front and one rear wheel.
--   board         G23's. Named now so a board can be registered against it; until
--                 its module exists a vehicle that names it is run as `none` and
--                 the server says so, once.
--   none          nothing holds the vehicle up. It stands on its wheels
--                 (a motor vehicle with a low centre of mass, a cart).
--------------------------------------------------------------------------
BMX.BalanceModeNames = { singletrack = true, board = true, none = true }

--------------------------------------------------------------------------
-- DRIVES: what turns the rider's keys into wheel torque (sv_physics.lua).
-- Each kind lists the keys it takes; anything else is a typo.
--
--   pedal      the bike's legs, with the stamina and the climbing assist, all of
--              it read from the config's Drive group
--   throttle   a motor: torque, falling to nothing at maxSpeed
--   push       reserved for the skateboard (G23): a kick every kickInterval
--   none       coasts
--------------------------------------------------------------------------
BMX.DriveKinds = {
    pedal    = {},
    throttle = { torque = "number", maxSpeed = "number" },
    push     = { torque = "number", maxSpeed = "number", kickInterval = "number" },
    none     = {},
}

--------------------------------------------------------------------------
-- INPUT MAPS.
--
--   BMX.RegisterInputMap{
--       id = "bike", label = "...",
--       actions = {
--           sprint = { key = IN_SPEED, ctx = { "ground" }, label = "Sprint" },
--           ...
--       },
--   }
--
-- `key` is the usercmd bit the action reads (what sv_input.lua tests), and `ctx`
-- the situations the key means something in: ground, air, grind, manual. An
-- action may be listed in several: R is the bell on the ground and a barspin in
-- the air. sv_input.lua reads the KEY from here; what the key does in each
-- situation is still its own decoding, because a context decides meaning, not
-- just binding.
--------------------------------------------------------------------------
BMX.InputMaps = BMX.InputMaps or {}
BMX.InputContexts = { ground = true, air = true, grind = true, manual = true }

function BMX.RegisterInputMap(def)
    assert(istable(def) and isstring(def.id) and def.id ~= "", "an input map needs an id")
    assert(istable(def.actions), def.id .. ": an input map needs actions")
    for name, a in pairs(def.actions) do
        assert(isstring(name), def.id .. ": action names are strings")
        assert(istable(a) and isnumber(a.key), def.id .. "." .. name .. ": needs a numeric key (an IN_ bit)")
        assert(istable(a.ctx) and #a.ctx > 0, def.id .. "." .. name .. ": needs a ctx list")
        for _, c in ipairs(a.ctx) do
            assert(BMX.InputContexts[c], def.id .. "." .. name .. ": unknown context " .. tostring(c))
        end
        for k in pairs(a) do
            assert(k == "key" or k == "ctx" or k == "label",
                def.id .. "." .. name .. ": unknown field " .. tostring(k))
        end
    end
    BMX.InputMaps[def.id] = def
    return def
end

-- The actions of a map that mean something in `ctx` (all of them when nil),
-- sorted by name: what a keybind panel is generated from.
function BMX.InputActions(mapId, ctx)
    local map = BMX.InputMaps[mapId]
    local out = {}
    if not map then return out end
    for name, a in pairs(map.actions) do
        local hit = ctx == nil
        for _, c in ipairs(a.ctx) do if c == ctx then hit = true end end
        if hit then out[#out + 1] = { name = name, key = a.key, ctx = a.ctx, label = a.label or name } end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- The map the bike (or any vehicle entity) reads. An unknown id falls back to
-- the bike's rather than leaving a seated rider with no controls at all.
function BMX.InputMapFor(ent)
    local def = ent and ent.Bike and ent:Bike()
    return BMX.InputMaps[def and def.input or "bike"] or BMX.InputMaps.bike
end

local G, A, GR, M = "ground", "air", "grind", "manual"

-- THE BIKE'S MAP: the controls sv_input.lua's header documents, as data.
BMX.RegisterInputMap{
    id = "bike", label = "Bike",
    actions = {
        forward     = { key = IN_FORWARD,  ctx = { G, A, GR }, label = "Pedal / nose down" },
        back        = { key = IN_BACK,     ctx = { G, A, GR }, label = "Rear brake / nose up" },
        left        = { key = IN_MOVELEFT,  ctx = { G, A },    label = "Lean left" },
        right       = { key = IN_MOVERIGHT, ctx = { G, A },    label = "Lean right" },
        sprint      = { key = IN_SPEED,    ctx = { G },        label = "Sprint" },
        tuck        = { key = IN_DUCK,     ctx = { G, A },     label = "Tuck" },
        brakeFront  = { key = IN_ATTACK,   ctx = { G, A, GR }, label = "Front brake / tailwhip" },
        weightBack  = { key = IN_ATTACK2,  ctx = { G, A, M },  label = "Weight back: wheelie, manual, 360" },
        hop         = { key = IN_JUMP,     ctx = { G, A },     label = "Bunny hop" },
        bar         = { key = IN_RELOAD,   ctx = { G, A, M },  label = "Bell / barspin" },
        alt         = { key = IN_WALK,     ctx = { A, M },     label = "Style modifier" },
    },
}

-- THE PLAIN MAP: steer, accelerate, brake, jump. A vehicle with no trick keys
-- yet (the test cart) reads this; a key that is not in the map is simply never
-- down, so none of the trick decoding can fire.
BMX.RegisterInputMap{
    id = "drive", label = "Drive",
    actions = {
        forward = { key = IN_FORWARD,   ctx = { G, A }, label = "Accelerate" },
        back    = { key = IN_BACK,      ctx = { G, A }, label = "Brake" },
        left    = { key = IN_MOVELEFT,  ctx = { G, A }, label = "Steer left" },
        right   = { key = IN_MOVERIGHT, ctx = { G, A }, label = "Steer right" },
        hop     = { key = IN_JUMP,      ctx = { G, A }, label = "Jump" },
    },
}

--------------------------------------------------------------------------
-- RIDER POSE SETS. The ids are declared here, shared, so a registration can be
-- checked; cl_rider.lua fills in the `rider` function (the bone offsets) and
-- the `poses` table (the style-trick IK targets) of each on the client.
--------------------------------------------------------------------------
BMX.PoseSets = BMX.PoseSets or {}
function BMX.RegisterPoseSet(id, meta)
    assert(isstring(id) and id ~= "", "a pose set needs an id")
    local s = BMX.PoseSets[id] or {}
    for k, v in pairs(meta or {}) do s[k] = v end
    s.id = id
    BMX.PoseSets[id] = s
    return s
end
BMX.RegisterPoseSet("bike",   { label = "Bike: hands on the bars, feet on the pedals" })
BMX.RegisterPoseSet("seated", { label = "Seated: the stock pose, no limbs animated" })

-- The pose set a vehicle entity's rider uses (client).
function BMX.PoseSetFor(ent)
    local def = ent and ent.Bike and ent:Bike()
    return BMX.PoseSets[def and def.pose or "bike"] or BMX.PoseSets.bike
end

--------------------------------------------------------------------------
-- THE CHECK. Everything is collected and reported together, sorted, the way
-- BMX.ValidatePhysics does, so one bad registration is one message.
--------------------------------------------------------------------------
local TOP_LEVEL = {
    -- the platform
    id = true, family = true, wheels = true, balance = true, drive = true,
    seats = true, input = true, pose = true, tricks = true, grindPoints = true,
    physics = true,
    -- appearance and mount points (as RegisterBike always took them)
    printName = true, description = true, author = true, model = true,
    colorIndex = true, seatModel = true, wheelModel = true, forkModel = true,
    frameOffset = true, frameAngles = true, scale = true, bones = true,
    -- spawn menu behaviour
    hidden = true,      -- not in the spawn menu
    debugOnly = true,   -- bmx_spawn needs bmx_debug >= 1
}
BMX.VehicleKeys = TOP_LEVEL

local WHEEL_KEYS = { pos = true, radius = true, steer = true, drive = true, front = true, name = true }
local SEAT_KEYS  = { model = true, offset = true, angles = true }
local GRIND_KEYS = { crank = true, pegs = true, moves = true }

local MAX_WHEELS = 8

local function checkWheel(i, w, bad)
    local at = "wheels[" .. i .. "]"
    if not istable(w) then bad[#bad + 1] = at .. " is not a table" return end
    for k in pairs(w) do
        if not WHEEL_KEYS[k] then bad[#bad + 1] = string.format("%s has unknown key %q", at, tostring(k)) end
    end
    if not isvector(w.pos) then bad[#bad + 1] = at .. ".pos must be a Vector (the axle, in chassis space)" end
    if w.radius ~= nil and not (isnumber(w.radius) and w.radius > 0) then
        bad[#bad + 1] = at .. ".radius must be a positive number"
    end
    local s = w.steer
    if not (s == nil or s == false or s == "fork" or isfunction(s)) then
        bad[#bad + 1] = at .. ".steer must be false, \"fork\" or a function"
    end
    if w.drive ~= nil and not isbool(w.drive) then bad[#bad + 1] = at .. ".drive must be a boolean" end
    if w.front ~= nil and not isbool(w.front) then bad[#bad + 1] = at .. ".front must be a boolean" end
    if w.name ~= nil and not isstring(w.name) then bad[#bad + 1] = at .. ".name must be a string" end
end

-- Resolve a vehicle's wheel list for a config: a table as written, or the
-- result of the function it gave (a bike's wheelbase is the config's, which is
-- per-bike, so its layout is a function of it).
function BMX.WheelDefs(def, cfg)
    local w = def.wheels
    if isfunction(w) then return w(cfg or BMX.Config) end
    return w
end

-- Is the field a function of the config or plain data? (Either is accepted.)
local function resolved(v, cfg)
    if isfunction(v) then return v(cfg) end
    return v
end
BMX.Resolved = resolved

function BMX.ValidateVehicle(def)
    local bad = {}
    local id = tostring(def.id)

    for k in pairs(def) do
        if not TOP_LEVEL[k] then bad[#bad + 1] = string.format("unknown field %q", tostring(k)) end
    end

    if not (isstring(def.id) and def.id:match("^[%w_]+$")) then
        bad[#bad + 1] = "id must be letters, digits and underscores"
    end

    if not BMX.Families[def.family] then
        bad[#bad + 1] = string.format("family %q is not one of bike, board, skates, scooter, moto", tostring(def.family))
    end

    -- Wheels.
    local wheels = def.wheels
    if isfunction(wheels) then
        local ok, res = pcall(wheels, BMX.Config)
        if not ok then
            bad[#bad + 1] = "wheels() failed: " .. tostring(res)
            wheels = nil
        else
            wheels = res
        end
    end
    local nWheels, nFront, nRear, nDrive, steerFork = 0, 0, 0, 0, false
    if not istable(wheels) or #wheels == 0 then
        bad[#bad + 1] = "wheels must be a non-empty list (or a function returning one)"
    elseif #wheels > MAX_WHEELS then
        bad[#bad + 1] = "at most " .. MAX_WHEELS .. " wheels"
    else
        nWheels = #wheels
        for i, w in ipairs(wheels) do
            checkWheel(i, w, bad)
            if istable(w) and isvector(w.pos) then
                local front = w.front
                if front == nil then front = w.pos.x > 0 end
                if front then nFront = nFront + 1 else nRear = nRear + 1 end
                if w.drive then nDrive = nDrive + 1 end
                if w.steer == "fork" then steerFork = true end
            end
        end
    end

    -- Balance.
    local balance = def.balance
    if not BMX.BalanceModeNames[balance] then
        bad[#bad + 1] = string.format("balance %q is not one of singletrack, board, none", tostring(balance))
    elseif balance == "singletrack" and nWheels > 0 and not (nWheels == 2 and nFront == 1 and nRear == 1) then
        bad[#bad + 1] = "balance singletrack needs exactly one front and one rear wheel"
    end
    if steerFork and balance ~= "singletrack" then
        bad[#bad + 1] = "steer = \"fork\" is the single-track balance's; use a function"
    end

    -- Drive.
    local drive = def.drive
    if not istable(drive) or not BMX.DriveKinds[drive.kind] then
        bad[#bad + 1] = "drive.kind must be one of pedal, throttle, push, none"
    else
        local allowed = BMX.DriveKinds[drive.kind]
        for k, v in pairs(drive) do
            if k ~= "kind" then
                if not allowed[k] then
                    bad[#bad + 1] = string.format("drive.%s is not a field of a %s drive", tostring(k), drive.kind)
                elseif type(v) ~= allowed[k] then
                    bad[#bad + 1] = string.format("drive.%s must be a %s", k, allowed[k])
                end
            end
        end
        if (drive.kind == "pedal" or drive.kind == "throttle") and nWheels > 0 and nDrive == 0 then
            bad[#bad + 1] = "a " .. drive.kind .. " drive needs at least one wheel with drive = true"
        end
        if drive.kind == "throttle" and not (isnumber(drive.torque) and drive.torque > 0) then
            bad[#bad + 1] = "a throttle drive needs a torque"
        end
    end

    -- Seats: one for now (a passenger is G11).
    if def.seats ~= nil then
        if not istable(def.seats) or #def.seats > 1 then
            bad[#bad + 1] = "seats must be a list of at most one seat (passengers are G11)"
        else
            for i, s in ipairs(def.seats) do
                if not istable(s) then
                    bad[#bad + 1] = "seats[" .. i .. "] is not a table"
                else
                    for k in pairs(s) do
                        if not SEAT_KEYS[k] then
                            bad[#bad + 1] = string.format("seats[%d] has unknown key %q", i, tostring(k))
                        end
                    end
                    if s.offset ~= nil and not isvector(s.offset) then bad[#bad + 1] = "seats[" .. i .. "].offset must be a Vector" end
                    if s.angles ~= nil and not isangle(s.angles) then bad[#bad + 1] = "seats[" .. i .. "].angles must be an Angle" end
                    if s.model ~= nil and not isstring(s.model) then bad[#bad + 1] = "seats[" .. i .. "].model must be a string" end
                end
            end
        end
    end

    -- Input map and pose set: by id.
    if not BMX.InputMaps[def.input] then
        bad[#bad + 1] = string.format("input %q is not a registered input map", tostring(def.input))
    end
    if not BMX.PoseSets[def.pose] then
        bad[#bad + 1] = string.format("pose %q is not a registered pose set", tostring(def.pose))
    end

    -- Tricks: "all", or the ids it may do.
    local tr = def.tricks
    if tr ~= "all" then
        if not istable(tr) then
            bad[#bad + 1] = "tricks must be \"all\" or a list of trick ids"
        else
            for _, t in ipairs(tr) do
                if not (BMX.Tricks and BMX.Tricks[t]) then
                    bad[#bad + 1] = string.format("tricks lists %q, which is not a registered trick", tostring(t))
                end
            end
        end
    end

    -- Grind points: false (no grinds) or { crank = Vector|fn|false, pegs = table|fn|false }.
    local gp = def.grindPoints
    if gp ~= false then
        if not istable(gp) then
            bad[#bad + 1] = "grindPoints must be false or a table"
        else
            for k, v in pairs(gp) do
                if not GRIND_KEYS[k] then
                    bad[#bad + 1] = string.format("grindPoints has unknown key %q", tostring(k))
                elseif k == "crank" and not (v == false or isvector(v) or isfunction(v)) then
                    bad[#bad + 1] = "grindPoints.crank must be a Vector, a function of the config, or false"
                elseif k == "pegs" and not (v == false or istable(v) or isfunction(v)) then
                    bad[#bad + 1] = "grindPoints.pegs must be { y, z, x = {...} }, a function of the config, or false"
                elseif k == "moves" and not (v == false or isfunction(v)) then
                    bad[#bad + 1] = "grindPoints.moves must be a function (ent, st, rail, dh, vel) -> move, or false"
                end
            end
        end
    end

    if #bad > 0 then
        table.sort(bad)
        ErrorNoHalt(string.format("[BMX] vehicle %q is not valid: %s.\n", id, table.concat(bad, "; ")))
        return false
    end
    return true
end

--------------------------------------------------------------------------
-- The two layouts every bike has, as functions of the bike's own config.
-- They are what `wheels` and `grindPoints` mean for the bike family, and the
-- defaults RegisterBike fills in.
--
-- pos is the AXLE, in chassis space, where the chassis origin is on the design
-- axle line; the suspension mount is restLength above it (sv_wheel.lua, and the
-- long note in ENT:Initialize about why).
--------------------------------------------------------------------------
function BMX.BikeWheels(cfg)
    local half = cfg.Wheel.wheelbase * 0.5
    return {
        { pos = Vector( half, 0, 0), steer = "fork", front = true,  drive = false, name = "front" },
        { pos = Vector(-half, 0, 0), steer = false,  front = false, drive = true,  name = "rear" },
    }
end

-- The chainring's contact (BMX.GrindCrankPoint, sh_util.lua) and the pegs, which
-- sit on the axles: where the sparks are thrown from, and where a grind is held.
function BMX.BikePegs(cfg)
    local G = cfg.Grind
    local half = cfg.Wheel.wheelbase * 0.5
    return { y = G.pegY, z = G.pegZ, x = { half, -half } }
end

BMX.BikeGrindPoints = { crank = function(cfg) return BMX.GrindCrankPoint(cfg) end, pegs = BMX.BikePegs }

-- A vehicle's grind contacts for a config, resolved: { crank = Vector|nil,
-- pegs = {y, z, x = {...}}|nil }. nil is "this vehicle cannot grind that way".
function BMX.GrindPointsFor(def, cfg)
    local gp = def and def.grindPoints
    if not gp then return {} end
    local out = {}
    local c = resolved(gp.crank, cfg)
    if c then out.crank = c end
    local p = resolved(gp.pegs, cfg)
    if p then out.pegs = p end
    -- Not resolved against the config: a move is a function of the grind that is
    -- about to happen, and is called as one (sv_grind.lua, TryGrind).
    if gp.moves then out.moves = gp.moves end
    return out
end

--------------------------------------------------------------------------
-- TRICK LISTS. `tricks = "all"` (the bike) or a list of registered trick ids.
-- No definition at all (a bare state in a test) allows everything. Enforced
-- where a trick is DETECTED from motion -- the spins in the air, the held
-- wheelie and stoppie, the registered custom ticks -- since the held-key tricks
-- (frame and bar spins, poses) are only reachable through an input map that has
-- their keys.
--------------------------------------------------------------------------
function BMX.VehicleAllows(def, trickId)
    if not def then return true end
    local t = def.tricks
    if t == nil or t == "all" then return true end
    local set = def._trickSet
    if not set then
        set = {}
        for _, id in ipairs(t) do set[id] = true end
        def._trickSet = set
    end
    return set[trickId] == true
end
