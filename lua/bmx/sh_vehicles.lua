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
-- G13: `unicycle` balances one wheel on two axes at once (sv_unicycle.lua);
-- `pennyfarthing` is the single-track balance with the header rule on its pitch
-- (sv_penny.lua): two wheels in line, the front one steered by the fork.
BMX.BalanceModeNames = { singletrack = true, board = true, none = true,
                         unicycle = true, pennyfarthing = true }

--------------------------------------------------------------------------
-- DRIVES: what turns the rider's keys into wheel torque (sv_physics.lua).
-- Each kind lists the keys it takes; anything else is a typo.
--
--   pedal      the bike's legs, with the stamina and the climbing assist, all of
--              it read from the config's Drive group
--   fixed      a fixed gear (G10): the pedal drive with the cranks LOCKED to the
--              rear wheel through a stiff spring. No freewheel: coasting turns the
--              legs, S is a skid stop, S at a standstill pedals backwards.
--              `reverse = true` (the unicycle, G13) makes S pedal backwards at any
--              speed instead: a unicycle has no brake, only its legs
--   front-direct  a penny-farthing's (G13): the pedal drive with the cranks on the
--              FRONT wheel, which is the vehicle's drive wheel; no gearing to speak
--              of (the config's gearRatio is the one number for it)
--   coaster    a coaster brake (G12): the pedal drive, freewheeling; its brake is S
--              (the rear brake) and the vehicle has no front brake to speak of
--   throttle   a motor: torque, falling to nothing at maxSpeed
--   push       reserved for the skateboard (G23): a kick every kickInterval
--   assist     an e-bike (G14): the pedal drive plus a motor of LEVEL x the rider's
--              torque, fading out at bmx_ebike_limit; sh_motor.lua adds this kind
--   engine     a petrol engine (G15): a torque curve, a clutch, the road bike's gears
--              or one ratio; sh_motor.lua adds this kind
--   (throttle also takes `battery`, `regen`, `motorRatio` for the e-moto, G14)
--   none       coasts
--------------------------------------------------------------------------
BMX.DriveKinds = {
    pedal    = {},
    fixed    = { reverse = "boolean" },
    coaster  = {},
    ["front-direct"] = {},
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
        -- A usercmd bit (`key`, what sv_input.lua reads) and/or client-read BUTTONS
        -- (`buttons`: KEY_ and MOUSE_ codes, which are not usercmd bits and so
        -- cannot be tested in StartCommand). The gear shift is the second kind:
        -- [ and ] and the mouse wheel are seen by the client (cl_gears.lua), which
        -- tells the server, so an action with only `buttons` is never "down" to
        -- the usercmd decode and is still listed for a keybind panel.
        assert(istable(a) and (isnumber(a.key) or istable(a.buttons)),
            def.id .. "." .. name .. ": needs a numeric key (an IN_ bit) or a buttons list")
        assert(istable(a.ctx) and #a.ctx > 0, def.id .. "." .. name .. ": needs a ctx list")
        for _, c in ipairs(a.ctx) do
            assert(BMX.InputContexts[c], def.id .. "." .. name .. ": unknown context " .. tostring(c))
        end
        for k in pairs(a) do
            assert(k == "key" or k == "ctx" or k == "label" or k == "buttons",
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
        if hit then out[#out + 1] = { name = name, key = a.key, buttons = a.buttons, ctx = a.ctx, label = a.label or name } end
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

-- THE ROAD BIKE'S MAP (G09): the bike's keys, plus the gear shift. Shifting is
-- [ and ] or the mouse wheel; those are client buttons, not usercmd bits, so the
-- actions carry `buttons` rather than a `key` (see RegisterInputMap). (KEY_ and
-- MOUSE_ are engine enums in both realms; the numbers are the fallback for a
-- build that lacks one.)
do
    local actions = {}
    for name, a in pairs(BMX.InputMaps.bike.actions) do actions[name] = a end
    actions.shiftUp   = { buttons = { KEY_RBRACKET or 54, MOUSE_WHEEL_UP or 112 },
                          ctx = { G, A }, label = "Shift up (] or wheel up)" }
    actions.shiftDown = { buttons = { KEY_LBRACKET or 53, MOUSE_WHEEL_DOWN or 113 },
                          ctx = { G, A }, label = "Shift down ([ or wheel down)" }
    BMX.RegisterInputMap{ id = "road", label = "Road bike", actions = actions }
end

-- THE FIXIE'S AND THE CITY BIKE'S MAP (G10, G12): the bike's keys without the
-- front brake. A fixed gear's brake is its legs and a Dutch bike's is the
-- coaster, so LMB does nothing on the ground (sv_input.lua; the fixie takes it
-- back with bmx_fixie_frontbrake 1). It stays a key in the air and on a grind,
-- because a tailwhip is a frame trick, not a brake.
do
    local actions = {}
    for name, a in pairs(BMX.InputMaps.bike.actions) do actions[name] = a end
    actions.brakeFront = { key = IN_ATTACK, ctx = { A, GR }, label = "Tailwhip (there is no front brake)" }
    BMX.RegisterInputMap{ id = "bike_rearonly", label = "Bike, rear brake only", actions = actions }
end

-- THE PENNY-FARTHING'S MAP (G13): steer, pedal, the front brake (the spoon brake, the
-- one that takes the rider over the bars) and S, which back-pedals the direct drive
-- (the pedal drive's own reverse at a walk). No trick keys: it is not that kind of bike.
BMX.RegisterInputMap{
    id = "penny", label = "Penny-farthing",
    actions = {
        forward    = { key = IN_FORWARD,   ctx = { G, A }, label = "Pedal" },
        back       = { key = IN_BACK,      ctx = { G, A }, label = "Back-pedal / rear brake" },
        left       = { key = IN_MOVELEFT,  ctx = { G, A }, label = "Lean left" },
        right      = { key = IN_MOVERIGHT, ctx = { G, A }, label = "Lean right" },
        sprint     = { key = IN_SPEED,     ctx = { G },    label = "Sprint" },
        brakeFront = { key = IN_ATTACK,    ctx = { G, A }, label = "Front (spoon) brake: hard at speed and you go over the bars" },
        hop        = { key = IN_JUMP,      ctx = { G, A }, label = "Hop" },
    },
}

-- THE UNICYCLE'S MAP (G13): pedal forward and BACK (there is no brake, S pedals
-- backwards), lean, hop, sprint. No trick keys: the mouse's yaw, which twists it
-- round, is not a key and is read from the usercmd (sv_unicycle.lua).
BMX.RegisterInputMap{
    id = "unicycle", label = "Unicycle",
    actions = {
        forward = { key = IN_FORWARD,   ctx = { G, A }, label = "Pedal forward" },
        back    = { key = IN_BACK,      ctx = { G, A }, label = "Pedal backwards (the brake)" },
        left    = { key = IN_MOVELEFT,  ctx = { G, A }, label = "Lean left" },
        right   = { key = IN_MOVERIGHT, ctx = { G, A }, label = "Lean right" },
        sprint  = { key = IN_SPEED,     ctx = { G },    label = "Sprint" },
        hop     = { key = IN_JUMP,      ctx = { G, A }, label = "Hop" },
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
BMX.RegisterPoseSet("road",   { label = "Road: tucked over the bars, hands on the drops" })
BMX.RegisterPoseSet("upright", { label = "Upright: sat up, hands on swept-back bars" })
BMX.RegisterPoseSet("unicycle", { label = "Unicycle: upright on the saddle, arms out for balance" })

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
    -- the bikes' extras: gears (G09), a score multiplier (G09), the bar shape (G09)
    gears = true, scoreMult = true, barStyle = true,
    -- the built-in detailed model to draw: "bmx" (cl_bikegeo.lua), or nil for the simple bike
    look = true,
    -- a box small props ride in (G12, sv_basket.lua)
    basket = true,
    -- appearance and mount points (as RegisterBike always took them)
    printName = true, description = true, author = true, model = true,
    colorIndex = true, seatModel = true, wheelModel = true, forkModel = true,
    frameOffset = true, frameAngles = true, scale = true, bones = true,
    -- spawn menu behaviour
    -- the procedural drawing a vehicle that is not the stock bike's shape asks for
    -- (G13, BMX.Drawers in cl_oddbikes.lua): a unicycle, a penny-farthing, a tandem
    drawer = true,
    hidden = true,      -- not in the spawn menu
    debugOnly = true,   -- bmx_spawn needs bmx_debug >= 1
}
BMX.VehicleKeys = TOP_LEVEL

local WHEEL_KEYS = { pos = true, radius = true, steer = true, drive = true, front = true, name = true }
-- `pedals` (G13): the seat's rider pedals too, and their legs' torque adds to the
-- driver's (a tandem's stoker; sv_tandem.lua).
local SEAT_KEYS  = { model = true, offset = true, angles = true, massFactor = true, pedals = true }

-- The kinds of seat a vehicle may have (sh_passenger.lua says what each is).
BMX.SeatKinds = { "rider", "pegs", "child" }
BMX.SeatKindSet = { rider = true, pegs = true, child = true }
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

-- THE DRAWN BAR SHAPES (cl_init.lua): flat is the BMX's riser bar.
BMX.BarStyles = { flat = true, drop = true, swept = true }

-- GEARS (G09; the model is sh_gears.lua). `gears = { ratios = {...}, start = n }`:
-- 2 to 11 ratios, each wheel revolutions per crank revolution (what
-- Drive.gearRatio is for a single-speed bike), lowest first and strictly
-- rising, and the gear a new bike is in. Anything else is a typo, and a bike
-- whose ratios are out of order is a bike whose shift keys go the wrong way.
local GEAR_KEYS = { ratios = true, start = true }
function BMX.CheckGears(g, bad)
    if g == nil then return end
    if not istable(g) then bad[#bad + 1] = "gears must be { ratios = {...}, start = n }" return end
    for k in pairs(g) do
        if not GEAR_KEYS[k] then bad[#bad + 1] = string.format("gears has unknown key %q", tostring(k)) end
    end
    local r = g.ratios
    if not istable(r) or #r < 2 or #r > 11 then
        bad[#bad + 1] = "gears.ratios must be a list of 2 to 11 ratios"
        return
    end
    local prev = 0
    for i, v in ipairs(r) do
        if not (isnumber(v) and v == v and v > 0 and v < 20) then
            bad[#bad + 1] = "gears.ratios[" .. i .. "] must be a number above 0 and under 20"
        elseif v <= prev then
            bad[#bad + 1] = "gears.ratios must rise, lowest gear first (ratios[" .. i .. "])"
        else
            prev = v
        end
    end
    if g.start ~= nil and not (isnumber(g.start) and g.start >= 1 and g.start <= #r and g.start == math.floor(g.start)) then
        bad[#bad + 1] = "gears.start must be a whole gear number, 1 to " .. #r
    end
end

-- THE BASKET (G12; the model is sv_basket.lua): a box in chassis space the vehicle
-- carries small props in. `basket = { mins = Vector, maxs = Vector, maxMass = kg,
-- hold = u/s^2 }`: mins and maxs are the box's corners, maxMass the heaviest prop it
-- takes (default 12), hold the acceleration the load stays in through (default 1500,
-- two and a half g).
local BASKET_KEYS = { mins = "vector", maxs = "vector", maxMass = "number", hold = "number" }
function BMX.CheckBasket(b, bad)
    if b == nil then return end
    if not istable(b) then bad[#bad + 1] = "basket must be a table { mins, maxs }" return end
    for k, v in pairs(b) do
        if not BASKET_KEYS[k] then
            bad[#bad + 1] = string.format("basket has unknown key %q", tostring(k))
        elseif BASKET_KEYS[k] == "vector" and not isvector(v) then
            bad[#bad + 1] = "basket." .. k .. " must be a Vector"
        elseif BASKET_KEYS[k] == "number" and not (isnumber(v) and v > 0) then
            bad[#bad + 1] = "basket." .. k .. " must be a positive number"
        end
    end
    if not (isvector(b.mins) and isvector(b.maxs)) then
        if b.mins == nil or b.maxs == nil then bad[#bad + 1] = "a basket needs mins and maxs" end
    elseif not (b.maxs.x > b.mins.x and b.maxs.y > b.mins.y and b.maxs.z > b.mins.z) then
        bad[#bad + 1] = "basket.maxs must be above and beyond basket.mins on every axis"
    end
end

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
        bad[#bad + 1] = string.format("balance %q is not one of singletrack, board, none, unicycle, pennyfarthing", tostring(balance))
    elseif (balance == "singletrack" or balance == "pennyfarthing") and nWheels > 0
        and not (nWheels == 2 and nFront == 1 and nRear == 1) then
        bad[#bad + 1] = "balance " .. balance .. " needs exactly one front and one rear wheel"
    elseif balance == "unicycle" and nWheels > 0 and nWheels ~= 1 then
        bad[#bad + 1] = "balance unicycle needs exactly one wheel"
    end
    if steerFork and balance ~= "singletrack" and balance ~= "pennyfarthing" then
        bad[#bad + 1] = "steer = \"fork\" is the single-track balance's; use a function"
    end

    -- Drive.
    local drive = def.drive
    if not istable(drive) or not BMX.DriveKinds[drive.kind] then
        bad[#bad + 1] = "drive.kind must be one of pedal, fixed, coaster, front-direct, throttle, push, assist, engine, none"
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
        if (drive.kind == "pedal" or drive.kind == "fixed" or drive.kind == "coaster" or drive.kind == "throttle"
            or drive.kind == "front-direct" or drive.kind == "assist" or drive.kind == "engine")
            and nWheels > 0 and nDrive == 0 then
            bad[#bad + 1] = "a " .. drive.kind .. " drive needs at least one wheel with drive = true"
        end
        if drive.kind == "throttle" and not (isnumber(drive.torque) and drive.torque > 0) then
            bad[#bad + 1] = "a throttle drive needs a torque"
        end
        -- The motor kinds (sh_motor.lua) check their own fields: a torque curve, a
        -- redline, an assist level. Loaded after this file, so it is looked up here.
        local dc = BMX.DriveChecks and BMX.DriveChecks[drive.kind]
        if dc then dc(drive, bad, def) end
    end

    -- Seats (G11): the old list (the rider's seat, at most one), or a map by kind,
    -- { rider = {...}, pegs = {...}, child = {...} }. See sh_passenger.lua.
    if def.seats ~= nil then
        local function seat(label, sd)
            if not istable(sd) then bad[#bad + 1] = label .. " is not a table" return end
            for k in pairs(sd) do
                if not SEAT_KEYS[k] then bad[#bad + 1] = string.format("%s has unknown key %q", label, tostring(k)) end
            end
            if sd.offset ~= nil and not (isvector(sd.offset) or isfunction(sd.offset)) then
                bad[#bad + 1] = label .. ".offset must be a Vector or a function of the config"
            end
            if sd.angles ~= nil and not isangle(sd.angles) then bad[#bad + 1] = label .. ".angles must be an Angle" end
            if sd.model ~= nil and not isstring(sd.model) then bad[#bad + 1] = label .. ".model must be a string" end
            if sd.massFactor ~= nil and not (isnumber(sd.massFactor) and sd.massFactor >= 0 and sd.massFactor <= 2) then
                bad[#bad + 1] = label .. ".massFactor must be a number from 0 to 2 (a fraction of the bike's mass)"
            end
            if sd.pedals ~= nil and not isbool(sd.pedals) then
                bad[#bad + 1] = label .. ".pedals must be a boolean"
            end
        end
        if not istable(def.seats) then
            bad[#bad + 1] = "seats must be a list of at most one seat, or a table of rider / pegs / child seats"
        elseif #def.seats > 0 then
            if #def.seats > 1 then
                bad[#bad + 1] = "seats must be a list of at most one seat, or a table of rider / pegs / child seats"
            end
            for i, sd in ipairs(def.seats) do seat("seats[" .. i .. "]", sd) end
        else
            for kind, sd in pairs(def.seats) do
                if not BMX.SeatKindSet[kind] then
                    bad[#bad + 1] = string.format("seats has unknown seat %q (rider, pegs or child)", tostring(kind))
                else
                    seat("seats." .. kind, sd)
                end
            end
        end
    end

    -- Gears: absent (single speed) or { ratios = { ... }, start = n }.
    BMX.CheckGears(def.gears, bad)
    if def.scoreMult ~= nil and not (isnumber(def.scoreMult) and def.scoreMult > 0 and def.scoreMult <= 10) then
        bad[#bad + 1] = "scoreMult must be a number above 0 and at most 10"
    end
    if def.barStyle ~= nil and not BMX.BarStyles[def.barStyle] then
        bad[#bad + 1] = string.format("barStyle %q is not one of flat, drop, swept", tostring(def.barStyle))
    end

    BMX.CheckBasket(def.basket, bad)
    if def.drawer ~= nil and not (isstring(def.drawer) and def.drawer ~= "") then
        bad[#bad + 1] = "drawer must be the id of a procedural drawer (BMX.Drawers, cl_oddbikes.lua)"
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
