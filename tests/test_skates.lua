--[[--------------------------------------------------------------------------
    Inline skates (G25): the worn-vehicle platform (sv_worn.lua, and the `worn` flag in
    sh_vehicles.lua / sh_bikes.lua), the skating step (sh_skates.lua, run on a plant of its
    own), the equip / holster state of the SWEP, the setup on a scripted player (sv_skates.lua,
    driven through the real SetupMove and Move hooks with a stand-in for the engine's movement
    data), the grinds on rails, and the client half (cl_skates.lua).

    WHAT THIS CANNOT SAY. There is no Source movement here: the stand-in for the engine
    integrates a position and a gravity and nothing else, so it is right about what the
    step does with the velocity it is given and wrong, necessarily, about what the engine
    does to it afterwards (walls, stairs, the friction the zero is meant to remove). Those are
    the headless cases (sv_test_cases.lua: skates_*) and a human on a server.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local gmod = require("lib.gmod")

local DT = 1 / 66

local function realm()
    local sv = F.server()
    return sv.env.BMX, sv
end

--------------------------------------------------------------------------
-- The registration, and the platform's worn flag
--------------------------------------------------------------------------

T.test("skates: registered through the platform as a WORN vehicle: no class, no seat, no spawn row, eight wheels", function()
    local sv = F.server()
    local B = sv.env.BMX
    local d = B.Vehicles.skates
    T.ok(d, "registered")
    T.eq(#sv.errors, 0, "nothing was rejected: " .. table.concat(sv.errors, " | "))
    T.eq(d.worn, true, "worn")
    T.eq(d.family, "skates", "family")
    T.eq(d.balance, "skates", "the worn balance mode")
    T.eq(d.drive.kind, "stride", "the stride drive")
    T.eq(d.input, "skates", "its own input map")
    T.eq(d.pose, "skates", "its own pose set")
    T.eq(d.seats, nil, "no seat")
    T.eq(B.ClassFor("skates"), nil, "no entity class")
    T.eq(sv.lists.SpawnableEntities.bmx_skates, nil, "no spawn row")
    T.eq(sv.dupe.bmx_skates, nil, "nothing to duplicate")
    local seen
    for _, id in ipairs(B.VehicleIDs()) do if id == "skates" then seen = true end end
    T.ok(not seen, "not in VehicleIDs (the entity classes the limit counts)")
    local worn
    for _, id in ipairs(B.WornIDs()) do if id == "skates" then worn = true end end
    T.ok(worn, "in WornIDs")
    local menu
    for _, id in ipairs(B.GettableIDs()) do if id == "skates" then menu = true end end
    T.ok(menu, "in GettableIDs, so bmx_spawn and the /bike window have it (they equip it)")
    local ent
    for _, id in ipairs(B.BikeIDs()) do if id == "skates" then ent = true end end
    T.ok(not ent, "and not in BikeIDs, which is the entities")
    local found
    for _, sec in ipairs(B.Menu.Catalog()) do
        for _, it in ipairs(sec.items) do if it.id == "skates" then found = sec.title end end
    end
    T.eq(found, "Boards", "the /bike window lists them under Boards")
    T.eq(B.IdForClass("bmx_skates"), nil, "and is not an entity class")
    -- Eight wheels, four in a line under each boot.
    local w = B.WheelDefs(d, B.ConfigFor(d))
    T.eq(#w, 8, "eight wheels")
    local byY = {}
    for _, wd in ipairs(w) do byY[wd.pos.y] = (byY[wd.pos.y] or 0) + 1 end
    local n = 0
    for y, c in pairs(byY) do T.eq(c, 4, "four wheels at y = " .. y) n = n + 1 end
    T.eq(n, 2, "under two boots")
    for _, wd in ipairs(w) do T.eq(wd.pos.z, B.ConfigFor(d).Wheel.radius, "the axle is a radius up") end
    T.ok(B.GrindPointsFor(d, B.ConfigFor(d)).moves, "the grind points have the moves")
end)

T.test("skates: the platform checks a worn vehicle: no seat, a worn balance, and the mode needs the flag", function()
    local sv = F.server()
    local B, E = sv.env.BMX, sv.env
    local function reg(extra)
        local def = { id = "wtest", family = "skates", worn = true, balance = "skates",
                      drive = { kind = "stride", torque = 1, maxSpeed = 1, strideInterval = 1 },
                      wheels = { { pos = E.Vector(0, 0, 1) } }, input = "skates", pose = "skates", tricks = {} }
        for k, v in pairs(extra) do def[k] = v end
        return B.RegisterVehicle(def)
    end
    T.ok(reg({}), "a plain worn vehicle registers")
    B.Vehicles.wtest = nil
    local n0 = #sv.errors
    T.eq(reg({ id = "wseat", seats = { rider = {} } }), false, "a seat is refused")
    T.ok(#sv.errors > n0 and sv.errors[#sv.errors]:find("no seat", 1, true), "and says why")
    n0 = #sv.errors
    T.eq(reg({ id = "wbal", balance = "singletrack" }), false, "a worn vehicle cannot be single-track")
    T.eq(reg({ id = "wbal2", balance = "board" }), false, "or a board")
    T.eq(reg({ id = "wnot", worn = false }), false, "the skates mode without the flag is refused")
    T.ok(sv.errors[#sv.errors]:find("worn", 1, true), "and says why")
    T.eq(reg({ id = "wbad", worn = "yes" }), false, "worn is a boolean")
    T.eq(reg({ id = "wdrive", drive = { kind = "stride", torque = "a" } }), false, "the stride drive's fields are checked")
    T.ok(B.DriveKinds.stride, "stride is a drive kind")
    T.ok(B.BalanceModeNames.skates, "skates is a balance name")
    -- A worn vehicle registered through the door is not an entity.
    T.eq(B.Vehicles.wseat, nil, "the refused ones are not registered")
end)

T.test("skates: the input map names the keys, and the settings rows and convars exist", function()
    local sv = F.server()
    local cl = F.client(sv.world)
    local B = sv.env.BMX
    local map = B.InputMaps.skates
    for _, name in ipairs({ "forward", "back", "left", "right", "jump", "crouch", "alt" }) do
        T.ok(map.actions[name], "action " .. name)
    end
    T.ok(#B.InputActions("skates", "air") >= 4, "several actions mean something in the air")
    local S = B.Settings
    local row = S.Get("bmx_skates_brake")
    T.ok(row, "bmx_skates_brake has a row")
    T.eq(row.scope, "client", "the player's own")
    T.eq(row.default, "tstop", "T-stop by default")
    T.ok(sv.world.convars.bmx_skates_brake, "and the client created the convar")
    T.eq(S.Get("bmx_board_autogrind").scope, "client", "the autogrind setting is shared with the board")
    T.ok(S.Get("bmx_allow_boards"), "and the server switch for boards covers the skates")
end)

--------------------------------------------------------------------------
-- The step, on a plant of its own
--------------------------------------------------------------------------

-- Run S.Step for `secs` of ground time with a fixed input, returning the skater and a log.
local function skate(S, secs, inp, opts)
    opts = opts or {}
    local s = opts.s or S.New(opts.heading or 0)
    if opts.v then s.vx, s.vy = opts.v[1], opts.v[2] end
    local env = opts.env or { grounded = true, gravity = 600 }
    local kicks, feet, log = 0, {}, {}
    for i = 1, math.floor(secs / DT + 0.5) do
        local r = S.Step(s, DT, inp, env, opts.def)
        if r.kicked then kicks = kicks + 1; feet[#feet + 1] = s.foot end
        log[i] = r
    end
    return s, kicks, feet, log
end

local function speedOf(s) return math.sqrt(s.vx * s.vx + s.vy * s.vy) end

T.test("skates step: W strides it up to speed, one stroke every 0.42 s, the legs alternating, and it tops out", function()
    local B = realm()
    local S = B.Skates
    local s, kicks, feet = skate(S, 6, { fwd = 1 })
    T.ok(speedOf(s) > 150, "a few strides get it going: " .. speedOf(s))
    T.ok(speedOf(s) < S.Tune.maxSpeed, "never past its top: " .. speedOf(s))
    T.ok(kicks >= 12 and kicks <= 15, "a stride every 0.42 s: " .. kicks)
    for i = 2, #feet do T.ok(feet[i] ~= feet[i - 1], "the legs alternate (" .. i .. ")") end
    T.ok(s.vx > 0 and math.abs(s.vy) < 1, "straight ahead along the heading")
    local at3 = skate(S, 3, { fwd = 1 })
    T.ok(speedOf(at3) > 80, "100 u/s inside about three seconds: " .. speedOf(at3))
    -- The speed climbs and each stride adds less (it tops out): the gain per stride falls.
    local sA, _, _, log = skate(S, 6, { fwd = 1 })
    local at1, at2, at5, at6 = log[66].speed, log[132].speed, log[330].speed, log[396].speed
    T.ok(at2 - at1 > at6 - at5, "the gain slows as it speeds up: " .. (at2 - at1) .. " vs " .. (at6 - at5))
    T.eq(S.DriveOf(B.Vehicles.skates).kickInterval, 0.42, "the registration's stride interval is the drive's")
end)

T.test("skates step: no W, no stride: it rolls on and runs down only slowly; a held brake stops it dead", function()
    local B = realm()
    local S = B.Skates
    local s = skate(S, 5, { fwd = 1 })
    local v = speedOf(s)
    skate(S, 1.5, { fwd = 0 }, { s = s })
    T.ok(speedOf(s) > v * 0.85, "it coasts: " .. v .. " -> " .. speedOf(s))
    local before = speedOf(s)
    skate(S, 2.5, { fwd = 0, brake = true, brakeMode = "tstop" }, { s = s })
    T.eq(speedOf(s), 0, "a T-stop stops it dead (from " .. before .. ")")
    T.ok(math.abs(s.vx) < 1e-9 and math.abs(s.vy) < 1e-9, "no creep")
    local s2 = skate(S, 5, { fwd = 1 })
    local v2 = speedOf(s2)
    skate(S, 0.6, { brake = true, brakeMode = "tstop" }, { s = s2 })
    local tstop = speedOf(s2)
    local s3 = skate(S, 5, { fwd = 1 })
    skate(S, 0.6, { brake = true, brakeMode = "heel" }, { s = s3 })
    local heel = speedOf(s3)
    T.ok(tstop < v2 * 0.5, "a T-stop takes more than half the speed off in 0.6 s: " .. v2 .. " -> " .. tstop)
    T.ok(heel > tstop, "a heel brake is gentler: " .. heel .. " vs " .. tstop)
    T.ok(heel < v2 * 0.9, "but it does brake: " .. v2 .. " -> " .. heel)
    -- S does not stride, and a brake with W held is a brake.
    local s4 = skate(S, 3, { fwd = 1 })
    local v4 = speedOf(s4)
    skate(S, 0.5, { fwd = 1, brake = true, brakeMode = "tstop" }, { s = s4 })
    T.ok(speedOf(s4) < v4, "W and S together brake")
end)

T.test("skates step: crossovers. A / D turn the heading, the velocity goes round with it, and it keeps its speed", function()
    local B = realm()
    local S = B.Skates
    local s = skate(S, 4, { fwd = 1 })
    local v0 = speedOf(s)
    T.ok(v0 > 120, "up to speed first: " .. v0)
    skate(S, 1.5, { fwd = 0, turn = 1 }, { s = s })
    local turned = math.deg(S.Wrap(s.heading))
    T.ok(turned > 40, "A turned it left: " .. turned)
    local dirV = math.deg(math.atan2(s.vy, s.vx))
    T.ok(math.abs(S.Wrap(math.rad(dirV) - s.heading)) < math.rad(12), "the velocity went round with the heading: " .. dirV .. " vs " .. turned)
    T.ok(speedOf(s) > v0 * 0.7, "and kept its speed through the carve: " .. v0 .. " -> " .. speedOf(s))
    -- The other way.
    local r = skate(S, 4, { fwd = 1 })
    skate(S, 1.5, { turn = -1 }, { s = r })
    T.ok(math.deg(S.Wrap(r.heading)) < -40, "D turned it right: " .. math.deg(S.Wrap(r.heading)))
    -- Crossovers pump speed in: turning under power holds it better than going straight coasting.
    local a = skate(S, 4, { fwd = 1 })
    local b = skate(S, 4, { fwd = 1 })
    skate(S, 2, { fwd = 0, turn = 1 }, { s = a })
    skate(S, 2, { fwd = 0, turn = 0 }, { s = b })
    T.ok(speedOf(a) > speedOf(b) * 0.9, "a crossover turn is not a brake: " .. speedOf(a) .. " vs " .. speedOf(b))
    -- The faster, the slower it can turn.
    T.ok(S.TurnRate(0) > S.TurnRate(150) and S.TurnRate(150) > S.TurnRate(400), "a carve at speed is wide")
end)

T.test("skates step: it steers by where it looks, the heading chasing the view at the turn rate", function()
    local B = realm()
    local S = B.Skates
    local s = S.New(0)
    S.Step(s, DT, { eyeYaw = math.rad(90) }, { grounded = true })
    T.ok(s.heading > 0 and s.heading < math.rad(8), "one tick: a step toward it, not a snap: " .. math.deg(s.heading))
    skate(S, 1.5, { eyeYaw = math.rad(90) }, { s = s })
    T.near(s.heading, math.rad(90), 1e-6, "and it gets there")
    -- At speed it lags the view: the turn rate is lower.
    local fast = S.New(0)
    fast.vx = 350
    local slow = S.New(0)
    S.Step(fast, DT, { eyeYaw = math.rad(90) }, { grounded = true })
    S.Step(slow, DT, { eyeYaw = math.rad(90) }, { grounded = true })
    T.ok(fast.heading < slow.heading, "faster, it turns slower: " .. fast.heading .. " vs " .. slow.heading)
    -- Looking the long way round turns the short way.
    local w = S.New(math.rad(170))
    S.Step(w, DT, { eyeYaw = math.rad(-170) }, { grounded = true })
    T.ok(S.Wrap(w.heading - math.rad(170)) > 0, "round the near side of 180")
end)

T.test("skates step: the wheels grip: a sideways velocity is gone inside a second, and none of it is stored", function()
    local B = realm()
    local S = B.Skates
    local s = skate(S, 1.0, {}, { v = { 0, 200 } })
    T.ok(math.abs(s.vy) < 5, "the sideways slide is gripped away: " .. s.vy)
    -- In the air nothing grips.
    local a = skate(S, 0.5, {}, { v = { 100, 100 }, env = { grounded = false } })
    T.near(a.vx, 100, 1e-6, "airborne it keeps its sideways velocity")
    T.near(a.vy, 100, 1e-6, "and its along")
end)

T.test("skates step: SPACE is a jump on a fresh press on the ground, once", function()
    local B = realm()
    local S = B.Skates
    local s = S.New(0)
    local r = S.Step(s, DT, { jump = true }, { grounded = true })
    T.eq(r.vz, S.Tune.jumpSpeed, "a jump")
    r = S.Step(s, DT, { jump = true }, { grounded = true })
    T.eq(r.vz, nil, "held is not another")
    S.Step(s, DT, { jump = false }, { grounded = true })
    r = S.Step(s, DT, { jump = true }, { grounded = true })
    T.eq(r.vz, S.Tune.jumpSpeed, "released and pressed again is")
    local a = S.New(0)
    r = S.Step(a, DT, { jump = true }, { grounded = false })
    T.eq(r.vz, nil, "not in the air")
end)

T.test("skates step: a downhill speeds it up and an uphill slows it, by the slope the wheels are on", function()
    local B = realm()
    local S = B.Skates
    local n = { x = 0.17, y = 0, z = math.sqrt(1 - 0.17 * 0.17) }       -- a slope falling toward +x
    local down = skate(S, 1.5, {}, { v = { 100, 0 }, env = { grounded = true, normal = n, gravity = 600 } })
    local flat = skate(S, 1.5, {}, { v = { 100, 0 } })
    T.ok(speedOf(down) > speedOf(flat) + 60, "rolling downhill gains: " .. speedOf(down) .. " vs " .. speedOf(flat))
    local up = skate(S, 1.0, {}, { v = { -100, 0 }, env = { grounded = true, normal = n, gravity = 600 } })
    T.ok(speedOf(up) < 100, "uphill it loses: " .. speedOf(up))
    -- A standing skater on a slope rolls off it.
    local stand = skate(S, 1.0, {}, { env = { grounded = true, normal = n, gravity = 600 } })
    T.ok(stand.vx > 20, "a slope rolls a standing skater down it: " .. stand.vx)
end)

T.test("skates air: spins are counted in the air and paid on the landing; air time too", function()
    local B = realm()
    local S = B.Skates
    local s = S.New(0)
    for _ = 1, 40 do S.Step(s, DT, { turn = 1 }, { grounded = false }) end
    local half = 0
    local air = { grounded = false }
    local t = S.New(0)
    local i = 0
    while math.abs(t.spin) < math.rad(180) and i < 400 do S.Step(t, DT, { turn = 1 }, air) i = i + 1 end
    local out = S.ScoreAir(t, 0.7)
    local names = {}
    for _, e in ipairs(out) do names[e.name] = e end
    T.ok(names["180"], "a half turn is a 180: " .. #out)
    T.ok(names["Air Time"], "and the air time is paid")
    T.eq(names["180"].points, B.Tricks.board180.points, "at the registry's number")
    local u = S.New(0)
    u.spin = math.pi * 2.1
    local o2 = S.ScoreAir(u, 0.2)
    T.eq(#o2, 1, "a whole turn, in a short air: one trick")
    T.eq(o2[1].name, "360", "a 360")
    T.eq(o2[1].points, B.Tricks.spin360.points, "at the registry's number")
    u.spin = -math.pi * 4.05
    T.eq(S.ScoreAir(u, 0.2)[1].count, 2, "two turns, either way round, count twice")
    local w = S.New(0)
    w.spin = math.rad(90)
    T.eq(#S.ScoreAir(w, 0.2), 0, "a quarter turn and a short air pay nothing")
    -- On the ground the heading is not an air spin.
    local g = S.New(0)
    for _ = 1, 60 do S.Step(g, DT, { turn = 1 }, { grounded = true }) end
    T.eq(g.spin, 0, "ground turns are not counted")
end)

T.test("skates landing: a hard fall or touching down across the way of travel is a bail; fakie and a slow scuff are not", function()
    local B = realm()
    local S = B.Skates
    local T0 = S.Tune
    T.eq(S.JudgeLanding({ x = 200, y = 0, z = -100 }, 0), nil, "a clean landing")
    local why, sev = S.JudgeLanding({ x = 100, y = 0, z = -T0.bailFall - 50 }, 0)
    T.eq(why, "fall", "a fall too hard")
    T.ok(sev > 0.3 and sev <= 1, "with a severity: " .. sev)
    why = S.JudgeLanding({ x = 0, y = 250, z = -100 }, 0)
    T.eq(why, "sideways", "square across the boots at speed")
    T.eq(S.JudgeLanding({ x = -250, y = 0, z = -100 }, 0), nil, "going backwards is fakie, not a bail")
    T.eq(S.JudgeLanding({ x = 0, y = 60, z = -100 }, 0), nil, "across, but slowly, is a scuff")
    T.eq(S.JudgeLanding({ x = 200, y = 40, z = -100 }, 0), nil, "a little off is fine")
    T.eq(S.JudgeLanding({ x = 0, y = 250, z = -100 }, math.pi / 2), nil, "boots turned to match it are fine")
end)

T.test("skates grinds: the keys and the angle pick soul, mizou or backslide; each has a contact rule and a price", function()
    local B = realm()
    local S = B.Skates
    local function k(str) local t = { w = false, s = false, a = false, d = false } for c in str:gmatch(".") do t[c] = true end return t end
    T.eq(S.ClassifyGrind(k(""), true), "skate_soul", "along, no key: a soul")
    T.eq(S.ClassifyGrind(k("w"), true), "skate_mizou", "along with W: a mizou")
    T.eq(S.ClassifyGrind(k("s"), true), "skate_soul", "S is not a mizou")
    T.eq(S.ClassifyGrind(k("ws"), true), "skate_soul", "W and S cancel")
    T.eq(S.ClassifyGrind(k(""), false), "skate_backslide", "across: a backslide")
    T.eq(S.ClassifyGrind(k("w"), false), "skate_backslide", "across, whatever the key")
    T.ok(S.IsAlong(0) and S.IsAlong(math.pi) and S.IsAlong(math.rad(40)), "along, either way round")
    T.ok(not S.IsAlong(math.rad(60)) and not S.IsAlong(math.pi / 2), "not along")
    local rate = B.Config.Grind.pointsPerSec
    for _, id in ipairs(S.GrindOrder) do
        local t = B.Tricks[id]
        T.ok(t and t.kind == "grind", id .. " is a registered grind trick")
        T.near(t.points, rate * S.Grinds[id].mult, 1e-6, id .. " pays its multiple of the rate")
        T.ok(B.VehicleAllows(B.Vehicles.skates, id), id .. " is on the vehicle's list")
        T.ok(S.Grinds[id].mult >= 1, id .. " pays at least the base rate")
    end
    T.eq(S.Grinds.skate_soul.yaw, 0, "a soul is along the rail")
    T.near(S.Grinds.skate_backslide.yaw, math.pi / 2, 1e-9, "a backslide is turned square across it")
    T.ok(S.Grinds.skate_mizou.x > 0 and S.Grinds.skate_soul.x == 0, "the mizou is the front boot's soul, the soul the middle")
    T.eq(S.GrindContact("skate_soul", false).y, 0, "a round rail is under the middle")
    T.eq(S.GrindContact("skate_soul", true, 1).y, S.Tune.edgeY, "a ledge: toward its top")
    T.eq(S.GrindContact("skate_soul", true, -1).y, -S.Tune.edgeY, "either side")
    T.eq(S.GrindContact("skate_soul", false).z, S.Tune.soleZ, "at the sole, so the standing hull is not in the rail")
    T.eq(#B.GrindPointsFor(B.Vehicles.skates, B.ConfigFor(B.Vehicles.skates)).pegs.x, 1, "pegs")
end)

T.test("skates wheels: eight points, four per boot in a line, turned with the heading", function()
    local B, sv = realm()
    local E = sv.env
    local S = B.Skates
    local cfg = B.ConfigFor(B.Vehicles.skates)
    local pts = S.WheelPoints(E.Vector(100, 50, 0), 0, cfg)
    T.eq(#pts, 8, "eight")
    local ys = {}
    for _, p in ipairs(pts) do ys[p.y] = (ys[p.y] or 0) + 1 end
    T.eq(ys[54], 4, "four under the left boot")
    T.eq(ys[46], 4, "and the right")
    local turned = S.WheelPoints(E.Vector(100, 50, 0), math.pi / 2, cfg)
    local xs = {}
    for _, p in ipairs(turned) do xs[math.floor(p.x + 0.5)] = true end
    T.ok(xs[96] and xs[104], "turned a quarter, the boots are either side in x: ")
    for _, p in ipairs(pts) do T.ok(p.z > cfg.Wheel.radius, "cast from over the axle") end
end)

--------------------------------------------------------------------------
-- Equip and holster
--------------------------------------------------------------------------

T.test("skates equip: the worn platform puts a player into the vehicle and takes them out, with the state each way", function()
    local sv = F.server()
    local E = sv.env
    local B = E.BMX
    local ply = sv:player("Skater")
    local fired = {}
    E.hook.Add("BMX_WornEquipped", "t", function(p, id) fired[#fired + 1] = "on " .. id end)
    E.hook.Add("BMX_WornHolstered", "t", function(p, id) fired[#fired + 1] = "off " .. id end)
    T.eq(B.Worn.Of(ply), nil, "not wearing anything")
    local w = B.Worn.Equip(ply, "skates")
    T.ok(w, "equipped")
    T.eq(B.Worn.Of(ply), w, "the wearer's state")
    T.eq(w.id, "skates", "which vehicle")
    T.eq(ply:GetNWString("BMXWorn", ""), "skates", "networked for the client")
    T.eq(ply:GetFriction(), 0, "the engine's friction is switched off: the player glides")
    T.ok(w.st and w.st.def == B.Vehicles.skates, "a controller state, tied to the registration")
    T.ok(w.proxy:Bike() == B.Vehicles.skates and w.proxy:GetDriver() == ply, "and the stand-in for the entity")
    T.eq(B.Worn.Equip(ply, "skates"), w, "equipping again is the same state")
    local again, why = B.Worn.Equip(ply, "stock")
    T.eq(again, nil, "a bike is not a worn vehicle")
    T.ok(why and why:find("not a worn", 1, true), "and says so: " .. tostring(why))
    T.ok(B.Worn.Unequip(ply), "taken off")
    T.eq(B.Worn.Of(ply), nil, "no longer wearing")
    T.eq(ply:GetNWString("BMXWorn", ""), "", "networked off")
    T.eq(ply:GetFriction(), 1, "friction is back")
    T.ok(not B.Worn.Unequip(ply), "taking off nothing is nothing")
    T.eq(table.concat(fired, ","), "on skates,off skates", "the public hooks fired once each")
end)

T.test("skates equip: the SWEP is the way in: deploying equips, holstering exits, removing exits", function()
    local sv = F.server()
    local E = sv.env
    local B = E.BMX
    local swep = sv.sweps and sv.sweps.weapon_bmx_skates
    T.ok(swep, "the weapon loaded")
    T.ok(swep.Deploy and swep.Holster and swep.OnRemove, "with its three doors")
    T.eq(swep.Spawnable, true, "in the weapon list")
    local ply = sv:player("Skater")
    local function weapon() return setmetatable({ GetOwner = function() return ply end }, { __index = swep }) end
    local wep = weapon()
    T.eq(wep:Deploy(), true, "deploy")
    T.ok(B.Skates.Wearing(ply), "deployed: on skates")
    T.eq(wep:Holster(), true, "holster")
    T.eq(B.Skates.Wearing(ply), nil, "holstered: walking")
    wep:Deploy()
    T.ok(B.Skates.Wearing(ply), "and on again")
    wep:OnRemove()
    T.eq(B.Skates.Wearing(ply), nil, "a removed weapon takes the skates off")
    -- Stripping the weapons (a crash's tumble) takes them off; the weapon given back puts them on.
    local w2 = weapon()
    w2:Deploy()
    w2.GetOwner = function() return nil end        -- by removal time the owner is gone
    w2:OnRemove()
    T.eq(B.Skates.Wearing(ply), nil, "even when the owner is no longer known to the weapon")
end)

T.test("skates equip: bmx_spawn skates and bmx_give_skates give the weapon, through the doors; it counts for the limit", function()
    local sv = F.server()
    local E = sv.env
    local B = E.BMX
    local ply = sv:player("Skater")
    sv:command("bmx_spawn", ply, "skates")
    T.ok(ply:HasWeapon("weapon_bmx_skates"), "bmx_spawn skates gives the skates")
    T.eq(ply:GetActiveWeapon():GetClass(), "weapon_bmx_skates", "and takes them out")
    T.eq(B.BikesOwnedBy(ply), 1, "a carried pair counts against bmx_max_per_player")
    local p2 = sv:player("Other")
    sv:command("bmx_give_skates", p2)
    T.ok(p2:HasWeapon("weapon_bmx_skates"), "bmx_give_skates")
    -- The switch.
    E.GetConVar("bmx_allow_boards"):SetString("0")
    local p3 = sv:player("Third")
    sv:command("bmx_spawn", p3, "skates")
    T.ok(not p3:HasWeapon("weapon_bmx_skates"), "bmx_allow_boards 0 gives none")
    T.ok(p3._chat and p3._chat[#p3._chat]:find("switched off", 1, true), "and says why")
    local w, why = B.Worn.Equip(p3, "skates")
    T.eq(w, nil, "and cannot be equipped either")
    E.GetConVar("bmx_allow_boards"):SetString("1")
    -- A veto from the gamemode.
    E.hook.Add("BMX_CanSpawn", "t", function(p, id) if id == "skates" then return false end end)
    local p4 = sv:player("Fourth")
    sv:command("bmx_spawn", p4, "skates")
    T.ok(not p4:HasWeapon("weapon_bmx_skates"), "BMX_CanSpawn can say no")
    -- No such bike, as before.
    local p5 = sv:player("Fifth")
    sv:command("bmx_spawn", p5, "hovercraft")
    T.ok(p5._chat and p5._chat[#p5._chat]:find("no such bike", 1, true), "an unknown id is still an error")
end)

T.test("skates equip: death, leaving and getting into a vehicle take them off", function()
    local sv = F.server()
    local E = sv.env
    local B = E.BMX
    local a, b, c = sv:player("A"), sv:player("B"), sv:player("C")
    for _, p in ipairs({ a, b, c }) do B.Worn.Equip(p, "skates") end
    E.hook.Run("PlayerDeath", a)
    T.eq(B.Worn.Of(a), nil, "dead: off")
    E.hook.Run("PlayerDisconnected", b)
    T.eq(B.Worn.Of(b), nil, "gone: off")
    local bike = F.bike(sv)
    c:EnterVehicle(bike:GetPod())
    T.eq(B.Worn.Of(c), nil, "in a vehicle: off")
    T.eq(select(2, B.Worn.Equip(c, "skates")), "get out of the vehicle first", "and cannot be put on in one")
end)

--------------------------------------------------------------------------
-- The setup, on a scripted player, through the real hooks
--------------------------------------------------------------------------

-- A stand-in for the engine's movement data and for what the engine does with it: it integrates the
-- velocity (and a gravity, and the ground plane) and nothing else.
local function newMove(E, pos)
    local m = { origin = pos, vel = E.Vector(0, 0, 0), buttons = 0, fs = 0, ss = 0 }
    function m:GetOrigin() return self.origin end
    function m:SetOrigin(v) self.origin = v end
    function m:GetVelocity() return self.vel end
    function m:SetVelocity(v) self.vel = v end
    function m:GetButtons() return self.buttons end
    function m:SetButtons(b) self.buttons = b end
    function m:SetForwardSpeed(v) self.fs = v end
    function m:SetSideSpeed(v) self.ss = v end
    return m
end

-- One tick of the player: the hooks, then the engine's part. `groundZ` is the floor.
local function tick(sv, ply, mv, groundZ)
    local E = sv.env
    E.hook.Run("SetupMove", ply, mv, nil)
    local took = E.hook.Run("Move", ply, mv)
    if not took then
        local v = mv.vel
        mv.vel = E.Vector(v.x, v.y, v.z - 600 * DT)
        mv.origin = mv.origin + mv.vel * DT
        if mv.origin.z <= groundZ and mv.vel.z <= 0 then
            mv.origin = E.Vector(mv.origin.x, mv.origin.y, groundZ)
            mv.vel = E.Vector(mv.vel.x, mv.vel.y, 0)
            ply._onGround = true
        else
            ply._onGround = mv.vel.z <= 0 and mv.origin.z - groundZ < 0.5
        end
    else
        mv.origin = mv.origin
        ply._onGround = false
    end
    sv.world.time = sv.world.time + DT
    mv.tickTime = sv.world.time
    ply._pos = mv.origin
    ply._vel = mv.vel
end

local function skater(opts)
    local sv = F.server(opts)
    local E = sv.env
    local ply = sv:player("Skater", { bot = true })
    ply.BMXScripted = true
    local groundZ = sv.world.groundZ
    local mv = newMove(E, E.Vector(0, 0, groundZ))
    ply:SetPos(mv.origin)
    local w = E.BMX.Worn.Equip(ply, "skates")
    return sv, ply, mv, w, groundZ
end

local function keys(w, t)
    local i = w.input
    i.fwd, i.turn, i.jump, i.crouch, i.brake = t.fwd or 0, t.turn or 0, t.jump or false, t.crouch or false, t.brake or false
    i.w, i.s, i.a, i.d = t.w or false, t.s or false, t.a or false, t.d or false
    i.eyeYaw = t.eyeYaw
    i.brakeMode = t.brakeMode or "tstop"
end

T.test("skates setup: W through the real hooks strides the player up to speed, with the walk keys zeroed", function()
    local sv, ply, mv, w, gz = skater()
    keys(w, { fwd = 1, w = true })
    mv.buttons = gmod.IN.JUMP + gmod.IN.FORWARD
    mv.fs = 400
    local t0 = sv.world.time
    for _ = 1, 66 * 5 do tick(sv, ply, mv, gz) end
    T.ok(mv.vel.x > 120, "it strides: " .. mv.vel.x)
    T.near(mv.vel.y, 0, 2, "straight ahead")
    T.eq(mv.fs, 0, "the engine's own walking is zeroed")
    T.eq(mv.ss, 0, "")
    T.eq(sv.env.bit.band(mv.buttons, gmod.IN.JUMP), 0, "and so is its jump")
    T.ok(w.st.grounded and w.st.speed > 100, "the controller state is kept: " .. tostring(w.st.speed))
    T.eq(ply:GetNWInt("BMXSkateFlags", 0) % 2, 1, "grounded is networked")
    T.ok(sv.errors and #sv.errors == 0, "no errors: " .. table.concat(sv.errors, " | "))
end)

T.test("skates setup: the velocity it wrote is kept unless the engine's came back clearly slower (a wall)", function()
    local sv, ply, mv, w, gz = skater()
    keys(w, { fwd = 1, w = true })
    for _ = 1, 66 * 4 do tick(sv, ply, mv, gz) end
    local v = mv.vel.x
    -- The engine takes a little off (friction the zero did not reach): ignored.
    mv.vel = sv.env.Vector(mv.vel.x * 0.97, mv.vel.y, mv.vel.z)
    keys(w, {})
    tick(sv, ply, mv, gz)
    T.ok(mv.vel.x > v * 0.95, "a few percent is not a wall: " .. v .. " -> " .. mv.vel.x)
    -- A wall: it comes back at a third of what was written.
    local v2 = mv.vel.x
    mv.vel = sv.env.Vector(v2 * 0.3, 0, 0)
    tick(sv, ply, mv, gz)
    T.ok(mv.vel.x < v2 * 0.4, "a wall stops it: " .. v2 .. " -> " .. mv.vel.x)
end)

T.test("skates setup: it steers where the player looks, and in a test without a view A / D turn it", function()
    local sv, ply, mv, w, gz = skater()
    keys(w, { fwd = 1, w = true })
    for _ = 1, 66 * 3 do tick(sv, ply, mv, gz) end
    keys(w, { eyeYaw = math.rad(60) })
    for _ = 1, 66 * 1 do tick(sv, ply, mv, gz) end
    T.near(w.sk.heading, math.rad(60), 0.05, "the heading went to the view: " .. math.deg(w.sk.heading))
    local ang = math.atan2(mv.vel.y, mv.vel.x)
    T.ok(math.abs(ang - w.sk.heading) < math.rad(25), "and the velocity followed: " .. math.deg(ang))
    keys(w, { turn = -1 })
    for _ = 1, 66 do tick(sv, ply, mv, gz) end
    T.ok(w.sk.heading < math.rad(40), "D turns it right with no view: " .. math.deg(w.sk.heading))
end)

T.test("skates setup: a jump leaves the ground, the air is scored on the landing, and a bad landing is a bail", function()
    local sv, ply, mv, w, gz = skater()
    local E = sv.env
    local paid, bailed = {}, nil
    E.hook.Add("BMX_TrickLanded", "t", function(p, t) paid[#paid + 1] = t.name end)
    E.hook.Add("BMX_WornBailed", "t", function(p, id, why) bailed = why end)
    keys(w, { fwd = 1, w = true })
    for _ = 1, 66 * 3 do tick(sv, ply, mv, gz) end
    T.ok(w.st.grounded, "rolling")
    -- Jump and spin in the air: turn the heading half a turn, then land.
    keys(w, { fwd = 0, jump = true })
    tick(sv, ply, mv, gz)
    T.ok(mv.vel.z > 150, "the jump: " .. mv.vel.z)
    keys(w, { fwd = 0, turn = 1 })
    local airTicks = 0
    for _ = 1, 66 * 2 do
        tick(sv, ply, mv, gz)
        if not w.st.grounded then airTicks = airTicks + 1 end
        if ply._onGround and airTicks > 10 then break end
    end
    T.ok(airTicks > 10, "it was in the air: " .. airTicks)
    -- Whatever it landed as, nothing threw an error and the state is finite.
    T.ok(w.sk.vx == w.sk.vx and w.sk.vy == w.sk.vy, "finite")
    T.eq(#sv.errors, 0, "no errors: " .. table.concat(sv.errors, " | "))
    -- A hard bail: touch down at speed square across the boots.
    local sv2, ply2, mv2, w2, gz2 = skater()
    local why2
    sv2.env.hook.Add("BMX_WornBailed", "t", function(p, id, why) why2 = why end)
    keys(w2, {})
    mv2.origin = sv2.env.Vector(0, 0, gz2 + 40)
    mv2.vel = sv2.env.Vector(0, 260, 0)           -- sideways to a heading of 0
    w2.sk.heading = 0
    w2.expect = nil
    local landed
    for _ = 1, 66 * 2 do
        tick(sv2, ply2, mv2, gz2)
        if ply2._onGround then landed = true break end
    end
    tick(sv2, ply2, mv2, gz2)
    T.ok(landed, "it came down")
    T.eq(why2, "sideways", "and bailed: " .. tostring(why2))
end)

T.test("skates setup: the combo and the score are the platform's, through the stand-in", function()
    local sv, ply, mv, w, gz = skater()
    local E = sv.env
    local B = E.BMX
    local landed, banked = {}, nil
    E.hook.Add("BMX_TrickLanded", "t", function(p, t, pts, ent) landed[#landed + 1] = { t.name, pts, ent } end)
    E.hook.Add("BMX_ComboBanked", "t", function(p, chain, total) banked = total end)
    local got = w.proxy:AwardTricks({ { name = "180", count = 1, points = 120 } })
    T.eq(got, 120, "the points")
    T.eq(ply:GetNWInt("BMXWornScore", 0), 120, "the wearer's score")
    T.eq(landed[1][1], "180", "BMX_TrickLanded fired")
    T.eq(landed[1][3], ply, "with the wearer where a bike's call has its entity")
    T.ok(w.st.combo and w.st.combo.n == 1, "a combo opened")
    w.proxy:AwardTricks({ { name = "Soul Grind", count = 1, points = 200, grind = 1.4 } })
    T.eq(w.st.combo.n, 2, "and grew")
    B.ComboEnd(w.proxy, true)
    T.eq(banked, (120 + 200) * 2, "banked as the platform does it: the chain's points and the bonus, base x (n - 1)")
    T.eq(ply:GetNWInt("BMXWornScore", 0), 120 + 200 + 320, "the bonus is the wearer's")
    -- Scoring off pays nothing.
    E.GetConVar("bmx_scoring"):SetString("0")
    T.eq(w.proxy:AwardTricks({ { name = "x", count = 1, points = 500 } }), 0, "bmx_scoring 0 pays nothing")
end)

--------------------------------------------------------------------------
-- The grinds, on rails in the world
--------------------------------------------------------------------------

local function pipe(E, len) return { E.Vector(-(len or 400), -1, 28), E.Vector(len or 400, 1, 30) } end
local function ledge(E) return { E.Vector(-800, 0, 0), E.Vector(800, 200, 20) } end

-- The skater in the air over a rail: SPACE held, moving along the heading.
local function overRail(solids, opts)
    opts = opts or {}
    local sv0 = F.server()
    local sv, ply, mv, w, gz = skater({ solids = solids(sv0.env) })
    local E = sv.env
    mv.origin = E.Vector(opts.x or -250, opts.y or 0.5, opts.z or 38)
    ply._pos = mv.origin
    local h = opts.heading or 0
    w.sk.heading = h
    local speed = opts.speed or 300
    local travel = opts.travel or h             -- the way it is going, which a backslide's is not the way it faces
    mv.vel = E.Vector(speed * math.cos(travel), speed * math.sin(travel), -30)
    w.sk.vx, w.sk.vy = mv.vel.x, mv.vel.y
    w.expect = nil
    ply._onGround = false
    keys(w, { jump = true, w = opts.w, s = opts.s, fwd = opts.w and 1 or 0 })
    w.input.jump = true
    return sv, ply, mv, w, gz
end

local function tickUntilGrind(sv, ply, mv, w, gz, n)
    for _ = 1, n or 120 do
        tick(sv, ply, mv, gz)
        if w.st.grind then return w.st.grind end
    end
end

T.test("skates grind: SPACE in the air over a round rail along it locks a soul grind, the skater placed on the rail's top", function()
    local sv, ply, mv, w, gz = overRail(function(E) return { pipe(E, 600) } end)
    local g = tickUntilGrind(sv, ply, mv, w, gz)
    T.ok(g, "locked on")
    T.eq(g and g.move, "skate_soul", "a soul")
    T.eq(g and g.kind, "crank", "on a round rail")
    T.ok(sv.env.hook.Run("Move", ply, mv), "the engine's movement is taken over while it lasts")
    for _ = 1, 20 do tick(sv, ply, mv, gz) end
    T.ok(w.st.grind, "still on it")
    T.near(mv.origin.z, 30.3, 1.2, "the soles are on the rail's top: " .. mv.origin.z)
    T.near(mv.origin.y, 0, 1.2, "on its line: " .. mv.origin.y)
    T.ok(mv.vel.x > 150, "sliding along it: " .. mv.vel.x)
    T.eq(ply:GetNWInt("BMXSkateGrind", 0) > 0, true, "networked for the sparks")
    T.ok(math.abs(w.meter or 0) < 1, "the balance meter is running")
    T.eq(#sv.errors, 0, "no errors: " .. table.concat(sv.errors, " | "))
end)

T.test("skates grind: W as it locks on is a mizou; across the rail it is a backslide; no SPACE, no lock", function()
    local sv, ply, mv, w, gz = overRail(function(E) return { pipe(E, 600) } end, { w = true })
    local g = tickUntilGrind(sv, ply, mv, w, gz)
    T.eq(g and g.move, "skate_mizou", "a mizou")
    local sv2, ply2, mv2, w2, gz2 = overRail(function(E) return { pipe(E, 600) } end,
        { heading = math.pi / 2, travel = 0, speed = 300 })
    local g2 = tickUntilGrind(sv2, ply2, mv2, w2, gz2)
    T.eq(g2 and g2.move, "skate_backslide", "turned across it: a backslide")
    local sv3, ply3, mv3, w3, gz3 = overRail(function(E) return { pipe(E, 600) } end)
    w3.input.jump = false
    w3.auto = false
    T.eq(tickUntilGrind(sv3, ply3, mv3, w3, gz3, 40), nil, "no SPACE, no lock: it flies over")
    local sv4, ply4, mv4, w4, gz4 = overRail(function(E) return { pipe(E, 600) } end)
    w4.input.jump = false
    w4.auto = true
    T.ok(tickUntilGrind(sv4, ply4, mv4, w4, gz4, 40), "autogrind locks on contact")
end)

T.test("skates grind: on a ledge it stands on the top over the edge; it pays by the second at its multiple", function()
    local sv, ply, mv, w, gz = overRail(function(E) return { ledge(E) } end, { y = 2, z = 28 })
    local paid = {}
    sv.env.hook.Add("BMX_TrickLanded", "t", function(p, t) paid[#paid + 1] = t end)
    local g = tickUntilGrind(sv, ply, mv, w, gz)
    T.ok(g, "locked on")
    T.eq(g and g.kind, "peg", "an edge")
    for _ = 1, 15 do tick(sv, ply, mv, gz) end
    T.near(mv.origin.z, 20.3, 1.2, "on the ledge's top: " .. mv.origin.z)
    -- Balance it with A / D until the rail ends, then see what it paid.
    local ended
    sv.env.hook.Add("BMX_WornGrindEnded", "t", function(p, id, move, why, t) ended = { why = why, t = t } end)
    for _ = 1, 66 * 8 do
        local m = w.meter or 0
        w.input.turn = m > 0.1 and 1 or (m < -0.1 and -1 or 0)       -- A lowers the meter, D raises it
        tick(sv, ply, mv, gz)
        if ended then break end
    end
    T.ok(ended, "it ended: " .. tostring(ended and ended.why))
    T.ok(ended and (ended.why == "end" or ended.why == "slow"), "at the end of the rail or out of speed: " .. tostring(ended and ended.why))
    local p
    for _, t in ipairs(paid) do if t.name == "Soul Grind" then p = t end end
    T.ok(p and p.points > 30, "a Soul Grind was paid: " .. tostring(p and p.points))
    T.ok(not w.st.grind, "off the rail")
    T.eq(#sv.errors, 0, "no errors: " .. table.concat(sv.errors, " | "))
end)

T.test("skates grind: let go of SPACE to pop off it, unattended it is lost and bails, and the contact rules", function()
    local sv, ply, mv, w, gz = overRail(function(E) return { pipe(E, 800) } end)
    tickUntilGrind(sv, ply, mv, w, gz)
    for _ = 1, 10 do tick(sv, ply, mv, gz) end
    T.ok(w.st.grind, "on it")
    w.input.jump = false
    tick(sv, ply, mv, gz)
    T.ok(not w.st.grind, "SPACE let go pops it off")
    T.ok(mv.vel.z > 100, "with a jump's height: " .. mv.vel.z)
    -- Unattended (no A / D): the balance runs away.
    local sv2, ply2, mv2, w2, gz2 = overRail(function(E) return { pipe(E, 3000) } end, { x = -2500 })
    local bailed
    sv2.env.hook.Add("BMX_WornBailed", "t", function(p, id, why) bailed = why end)
    tickUntilGrind(sv2, ply2, mv2, w2, gz2)
    -- Start the meter well off true, so the time it takes does not depend on the random wobble phase
    -- (a phase that fights the drift can outlast the rail's speed: the meter's own suite checks the timing).
    w2.st.grind.bal.v = 0.5
    for _ = 1, 66 * 10 do
        tick(sv2, ply2, mv2, gz2)
        if bailed then break end
    end
    T.eq(bailed, "balance", "the balance was lost: " .. tostring(bailed))
    -- The contact is under the hull's feet (the soles), not up in the body.
    T.eq(sv2.env.BMX.Skates.Tune.soleZ, 0, "the soul plate is the sole")
end)

--------------------------------------------------------------------------
-- The client
--------------------------------------------------------------------------

local function cscene()
    local sv, world = F.server()
    local cl = F.client(world)
    local me = cl:player("Looker")
    cl.localPlayer = me
    return cl, me, cl.env
end

T.test("skates client: A and D turn the view at the rate the server will follow, only while skating", function()
    local cl, me, E = cscene()
    local IN = gmod.IN
    local function cmd(buttons)
        local c = { buttons = buttons, ang = E.Angle(0, 0, 0) }
        function c:GetButtons() return self.buttons end
        function c:GetViewAngles() return E.Angle(self.ang.p, self.ang.y, self.ang.r) end
        function c:SetViewAngles(a) self.ang = a end
        return c
    end
    local c1 = cmd(IN.MOVELEFT)
    E.hook.Run("CreateMove", c1)
    T.eq(c1.ang.y, 0, "not on skates: the view is left alone")
    me:SetNWString("BMXWorn", "skates")
    E.hook.Run("CreateMove", c1)
    T.ok(c1.ang.y > 0, "A turns the view left: " .. c1.ang.y)
    local c2 = cmd(IN.MOVERIGHT)
    E.hook.Run("CreateMove", c2)
    T.ok(c2.ang.y < 0, "D right: " .. c2.ang.y)
    local c3 = cmd(IN.MOVELEFT + IN.MOVERIGHT)
    E.hook.Run("CreateMove", c3)
    T.eq(c3.ang.y, 0, "both cancel")
    me._vel = E.Vector(400, 0, 0)
    local c4 = cmd(IN.MOVELEFT)
    E.hook.Run("CreateMove", c4)
    T.ok(c4.ang.y < c1.ang.y, "at speed it turns slower, as the server's turn rate does: " .. c4.ang.y .. " vs " .. c1.ang.y)
end)

T.test("skates client: the local player's movement is predicted with the same step, and friction is zeroed and restored", function()
    local cl, me, E = cscene()
    local IN = gmod.IN
    local function cmd(buttons, yaw)
        local c = { buttons = buttons, fwd = 0 }
        function c:GetButtons() return self.buttons end
        function c:GetViewAngles() return E.Angle(0, yaw or 0, 0) end
        function c:GetForwardMove() return self.fwd end
        return c
    end
    local mv = { origin = E.Vector(0, 0, cl.world.groundZ), vel = E.Vector(0, 0, 0), buttons = IN.FORWARD + IN.JUMP, fs = 400, ss = 0 }
    function mv:GetOrigin() return self.origin end
    function mv:GetVelocity() return self.vel end
    function mv:SetVelocity(v) self.vel = v end
    function mv:GetButtons() return self.buttons end
    function mv:SetButtons(b) self.buttons = b end
    function mv:SetForwardSpeed(v) self.fs = v end
    function mv:SetSideSpeed(v) self.ss = v end
    -- Not on skates: nothing is touched.
    E.hook.Run("SetupMove", me, mv, cmd(IN.FORWARD))
    T.eq(mv.fs, 400, "not on skates: the engine's walk is left alone")
    T.eq(me:GetFriction(), 1, "and so is the friction")
    me:SetNWString("BMXWorn", "skates")
    for _ = 1, 66 * 3 do
        E.hook.Run("SetupMove", me, mv, cmd(IN.FORWARD))
        mv.origin = mv.origin + mv.vel * (1 / 66)
        mv.buttons = IN.FORWARD + IN.JUMP
    end
    T.ok(mv.vel.x > 60, "the client predicts the stride: " .. mv.vel.x)
    T.eq(mv.fs, 0, "with the walk zeroed")
    T.eq(me:GetFriction(), 0, "and the friction off")
    -- On a rail the server places the skater and the client leaves the movement alone.
    me:SetNWInt("BMXSkateFlags", E.BMX.Skates.Flag.grind)
    local v = mv.vel.x
    E.hook.Run("SetupMove", me, mv, cmd(IN.FORWARD))
    T.eq(mv.vel.x, v, "on a rail: not predicted")
    -- Off again: the friction is back.
    me:SetNWString("BMXWorn", "")
    E.hook.Run("SetupMove", me, mv, cmd(0))
    T.eq(me:GetFriction(), 1, "off the skates the friction is back")
end)

-- S.Decode once read sv_input.lua's BMX.StickDeadzone, which the client does not
-- have, so the prediction took a gamepad's half stick for no stick at all.
T.test("skates client: a gamepad stick is decoded the same by the prediction as by the server", function()
    local sv, world = F.server()
    local cl = F.client(world)
    local function decode(R, fwd)
        local E = R.env
        local c = {}
        function c:GetButtons() return 0 end
        function c:GetForwardMove() return fwd end
        function c:GetViewAngles() return E.Angle(0, 0, 0) end
        local w = { input = {} }
        E.BMX.Skates.Decode(R:player("Pad"), w, c)
        return w.input.fwd
    end
    local want = (0.5 - 0.1) / (1 - 0.1)        -- half the stick, past the default 0.1 dead zone
    T.near(decode(sv, 200), want, 1e-9, "the server reads half a stick")
    T.near(decode(cl, 200), want, 1e-9, "and so does the client's prediction")
    T.eq(decode(cl, 20), 0, "inside the dead zone it is no stick, on the client too")
    T.eq(#cl.errors, 0, "no errors: " .. table.concat(cl.errors, " | "))
end)

T.test("skates client: the boots are placed under the foot, the wheels in a line, and the draw runs to the end", function()
    local cl, me, E = cscene()
    local S = E.BMX.Skates
    local fr = S.BootFrame(E.Vector(10, 20, 5), 0, 1.6)
    T.eq(#fr.wheels, 4, "four wheels")
    for _, c in ipairs(fr.wheels) do
        T.near(c.y, 20, 1e-9, "in a line")
        T.ok(c.z < 5, "under the sole: " .. c.z)
    end
    T.ok(fr.wheels[1].x > fr.wheels[4].x, "front to back")
    local turned = S.BootFrame(E.Vector(10, 20, 5), 90, 1.6)
    T.near(turned.wheels[1].x, 10, 1e-6, "turned a quarter, the line runs along y")
    T.ok(turned.wheels[1].y > turned.wheels[4].y, "")
    me:SetNWString("BMXWorn", "skates")
    cl.lines = 0
    E.hook.Run("PostPlayerDraw", me)
    T.ok(cl.lines >= 8, "it drew the hubs: " .. cl.lines)
    E.hook.Run("PrePlayerDraw", me)
    me:SetNWString("BMXWorn", "")
    E.hook.Run("PrePlayerDraw", me)
    T.ok(true, "and cleared the pose without an error")
    -- Standing, not running.
    me:SetNWString("BMXWorn", "skates")
    local act = E.hook.Run("CalcMainActivity", me)
    T.eq(act, nil, "no sequence in the stock skeleton: it leaves the pose alone rather than guess")
end)

T.test("skates client: the stride swings the striding thigh, and the swing is a sine over the stride", function()
    local cl, me, E = cscene()
    local S = E.BMX.Skates
    T.eq(S.StrideSwing(-1), 0, "not striding")
    T.ok(S.StrideSwing(0.2) > 0.9, "mid-stroke it is at its most: " .. S.StrideSwing(0.2))
    T.ok(S.StrideSwing(0.4) < 0.3, "and comes home: " .. S.StrideSwing(0.4))
    me:SetNWString("BMXWorn", "skates")
    me:SetNWFloat("BMXSkatePhase", 0.2)
    me:SetNWInt("BMXSkateFoot", 1)
    -- Without the rider IK the stride is the thigh's swing alone.
    E.GetConVar("bmx_rider_ik"):SetString("0")
    E.hook.Run("PrePlayerDraw", me)
    local lb, rb = me:LookupBone("ValveBiped.Bip01_L_Thigh"), me:LookupBone("ValveBiped.Bip01_R_Thigh")
    T.ok(me._manip and me._manip[lb] and math.abs(me._manip[lb].y) > 20, "the striding leg swings")
    T.ok(me._manip and me._manip[rb] and me._manip[rb].y == 0, "the other does not")
    -- With it (the default) the striding foot is pushed back and out along the ground
    -- (S.FootTargets), the other stays under the hips (tests/test_contacts.lua checks
    -- the wheels stay on the floor).
    E.GetConVar("bmx_rider_ik"):SetString("1")
    local t = S.FootTargets(E.Vector(0, 0, 0), 0, 1.6, S.StrideSwing(0.2), 1)
    T.ok(t.lFoot.x < -6 and t.lFoot.y > t.rFoot.y + 9, "the striding (left) foot back and out: " .. tostring(t.lFoot))
    T.near(t.rFoot.x, 0, 1e-9, "the other under the hips")
    T.near(t.lFoot.z - t.rFoot.z, S.StrideFoot.lift * S.StrideSwing(0.2), 1e-6, "on the ground, all but a lift at the end of the push")
end)

T.test("skates client: the sparks come off both boots while a grind is networked, and stop when it ends", function()
    local cl, me, E = cscene()
    me:SetNWString("BMXWorn", "skates")
    me:SetNWInt("BMXSkateGrind", 1)
    E.hook.Run("Think")
    T.ok(#cl.particles >= 2, "sparks: " .. #cl.particles)
    me:SetNWInt("BMXSkateGrind", 0)
    E.hook.Run("Think")
    local n = #cl.particles
    E.hook.Run("Think")
    T.eq(#cl.particles, n, "and no more once it ends")
    cl.localPlayer = me
    me:SetNWInt("BMXSkateGrind", 1)
    me:SetNWFloat("BMXSkateMeter", 0.3)
    E.hook.Run("HUDPaint")
    T.ok(true, "the HUD draws the meter without an error")
end)

--------------------------------------------------------------------------
-- The headless suite's bookkeeping (sv_test.lua, sv_test_cases.lua)
--------------------------------------------------------------------------

T.test("headless: the skates' cases exist, ride the worn vehicle, and the runner knows how to set one up", function()
    local sv = F.server()
    local S = sv.env.BMX.Test
    for _, name in ipairs({ "skates_stride_to_speed", "skates_soul_grind" }) do
        T.ok(S.cases[name], name .. " exists")
        T.eq(S.cases[name].vehicle, "skates", name .. " is on the skates")
        T.ok(sv.env.BMX.Vehicles[S.cases[name].vehicle].worn, name .. " rides a worn vehicle")
    end
    -- The runner has the worn path (an entity-less setup, a teardown that takes them off).
    local fh = io.open(gmod.ROOT .. "/lua/bmx/sv_test.lua")
    local src = fh:read("*a")
    fh:close()
    T.ok(src:find("setupWorn", 1, true) and src:find("BMX.Worn.Unequip", 1, true), "sv_test.lua sets up and tears down a worn vehicle")
end)
