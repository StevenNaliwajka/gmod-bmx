--[[--------------------------------------------------------------------------
    The vehicle platform (G22): the registry's validation, the generalised
    wheel loop, the balance and drive modules, the input map, and the test cart
    -- four wheels, no balance -- driving forward on the offline plant.

    The refactor's own acceptance test is every OTHER file in this directory
    passing unchanged on the bike. These are about the new things: a vehicle that
    is not a bike has to register, be refused when it is wrong, and ride.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local gmod = require("lib.gmod")
local IN = gmod.IN

local function board(E, over)
    local def = {
        id = "plat_board", family = "board", printName = "Plat board",
        wheels = {
            { pos = E.Vector( 10,  5, 0), steer = function(w, ent, st, inp) return inp.lean * 0.2 end },
            { pos = E.Vector( 10, -5, 0), steer = function(w, ent, st, inp) return inp.lean * 0.2 end },
            { pos = E.Vector(-10,  5, 0), drive = true },
            { pos = E.Vector(-10, -5, 0), drive = true },
        },
        balance = "board", drive = { kind = "push", torque = 50000 },
        input = "drive", pose = "seated", tricks = { "backflip", "frontflip" },
        grindPoints = false,
    }
    for k, v in pairs(over or {}) do def[k] = v end
    return def
end

--------------------------------------------------------------------------
-- Registration: accepted
--------------------------------------------------------------------------

T.test("platform: a 4-wheel board layout is accepted", function()
    local sv = F.server()
    local B, E = sv.env.BMX, sv.env
    local def = B.RegisterVehicle(board(E))
    T.ok(def, "registered")
    T.eq(#sv.errors, 0, table.concat(sv.errors, " | "))
    T.eq(B.ClassFor("plat_board"), "bmx_plat_board", "it has a class")
    T.eq(#B.WheelDefs(B.Vehicles.plat_board), 4, "four wheels")
    T.ok(sv.lists.SpawnableEntities.bmx_plat_board, "and a spawn menu row")
    T.eq(sv.lists.SpawnableEntities.bmx_plat_board.Subcategory, "Boards", "under Boards")
end)

T.test("platform: a 1-wheel unicycle layout is accepted", function()
    local sv = F.server()
    local B, E = sv.env.BMX, sv.env
    local def = B.RegisterVehicle{
        id = "plat_uni", family = "bike", printName = "Plat unicycle",
        wheels = { { pos = E.Vector(0, 0, 0), radius = 14, drive = true, steer = false } },
        balance = "none", drive = { kind = "throttle", torque = 40000 },
    }
    T.ok(def, "registered")
    T.eq(#sv.errors, 0, table.concat(sv.errors, " | "))
    T.eq(#B.WheelDefs(B.Vehicles.plat_uni), 1, "one wheel")
end)

T.test("platform: wheels may be a function of the config", function()
    local sv = F.server()
    local B, E = sv.env.BMX, sv.env
    T.ok(B.RegisterVehicle{
        id = "plat_fn", family = "scooter",
        wheels = function(cfg)
            local h = cfg.Wheel.wheelbase * 0.5
            return { { pos = E.Vector(h, 0, 0), steer = false }, { pos = E.Vector(-h, 0, 0), drive = true } }
        end,
        balance = "none", drive = { kind = "throttle", torque = 30000 },
    }, "accepted")
    local w = B.WheelDefs(B.Vehicles.plat_fn, B.Config)
    T.near(w[1].pos.x, B.Config.Wheel.wheelbase * 0.5, 1e-9, "resolved against the config")
end)

T.test("platform: the shipped bikes register through it, clean, and keep every alias", function()
    local sv = F.server()
    local B = sv.env.BMX
    T.eq(#sv.errors, 0, table.concat(sv.errors, " | "))
    T.ok(B.Bikes == B.Vehicles, "BMX.Bikes is the registry")
    for _, id in ipairs({ "stock", "cruiser", "mini" }) do
        local d = B.Bikes[id]
        T.eq(d.family, "bike", id .. " is a bike")
        T.eq(d.balance, "singletrack", id .. " balances single-track")
        T.eq(d.drive.kind, "pedal", id .. " pedals")
        T.eq(d.input, "bike", id .. " reads the bike's keys")
        T.eq(d.pose, "bike", id .. " has the bike's rider pose")
        T.eq(d.tricks, "all", id .. " does every trick")
        T.eq(sv.lists.SpawnableEntities[B.ClassFor(id)].Subcategory, "Bikes", id .. " is under Bikes")
    end
    local w = B.WheelDefs(B.Bikes.stock, B.Config)
    T.eq(#w, 2, "two wheels")
    T.ok(w[1].steer == "fork" and w[1].front, "the front one steers by fork")
    T.ok(w[2].drive and not w[1].drive, "the rear one drives")
end)

--------------------------------------------------------------------------
-- Registration: rejected, loudly, and not registered
--------------------------------------------------------------------------

local BAD = {
    { "an unknown field",          function(d) d.bogus = 1 end,                       "bogus" },
    { "an unknown family",         function(d) d.family = "hovercraft" end,            "family" },
    { "no wheels",                 function(d) d.wheels = {} end,                      "wheels" },
    { "wheels not a table",        function(d) d.wheels = 4 end,                       "wheels" },
    { "a wheel with no position",  function(d, E) d.wheels[1].pos = nil end,           "pos" },
    { "an unknown wheel key",      function(d) d.wheels[1].camber = 3 end,             "camber" },
    { "a bad wheel radius",        function(d) d.wheels[1].radius = -2 end,            "radius" },
    { "a bad steer",               function(d) d.wheels[1].steer = "tiller" end,       "steer" },
    { "too many wheels",           function(d, E) for i = 1, 9 do d.wheels[i] = { pos = E.Vector(i, 0, 0) } end end, "at most" },
    { "an unknown balance mode",   function(d) d.balance = "gyro" end,                 "balance" },
    { "single-track on 4 wheels",  function(d) d.balance = "singletrack" end,          "singletrack" },
    { "fork steer without it",     function(d) d.wheels[1].steer = "fork" end,         "fork" },
    { "an unknown drive kind",     function(d) d.drive = { kind = "steam" } end,       "drive.kind" },
    { "a stray drive key",         function(d) d.drive = { kind = "none", torque = 1 } end, "drive.torque" },
    { "a throttle with no driver", function(d) d.drive = { kind = "throttle", torque = 1 }
                                                for _, w in ipairs(d.wheels) do w.drive = false end end, "drive = true" },
    { "a throttle with no torque", function(d) d.drive = { kind = "throttle" } end,    "torque" },
    { "two seats",                 function(d) d.seats = { {}, {} } end,               "seats" },
    { "a stray seat key",          function(d) d.seats = { { colour = 1 } } end,       "colour" },
    { "an unknown input map",      function(d) d.input = "joystick" end,               "input" },
    { "an unknown pose set",       function(d) d.pose = "yoga" end,                    "pose" },
    { "an unknown trick",          function(d) d.tricks = { "moonwalk" } end,          "moonwalk" },
    { "tricks of the wrong type",  function(d) d.tricks = 7 end,                       "tricks" },
    { "a stray grind key",         function(d) d.grindPoints = { toes = true } end,    "toes" },
    { "grind points of a bad type", function(d) d.grindPoints = 3 end,                 "grindPoints" },
    { "a bad id",                  function(d) d.id = "has space" end,                 "id" },
}

for _, c in ipairs(BAD) do
    T.test("platform: rejected, loudly: " .. c[1], function()
        local sv = F.server()
        local B, E = sv.env.BMX, sv.env
        local d = board(E)
        c[2](d, E)
        local id = d.id
        T.eq(B.RegisterVehicle(d), false, "refused")
        T.ok(#sv.errors > 0 and sv.errors[1]:find(c[3], 1, true),
            "reported with `" .. c[3] .. "`: " .. tostring(sv.errors[1]))
        T.ok(not B.Vehicles[id], "and not registered")
        T.eq(B.ClassFor(id), nil, "so it has no class")
    end)
end

T.test("platform: a bad physics override is still reported (and as before, still registers)", function()
    local sv = F.server()
    local B, E = sv.env.BMX, sv.env
    local d = board(E, { physics = { Wheel = { raduis = 3 } }, balance = "none", drive = { kind = "none" } })
    B.RegisterVehicle(d)
    T.ok(sv.errors[1] and sv.errors[1]:find("raduis"), "reported")
end)

--------------------------------------------------------------------------
-- Input maps, pose sets, grind points: data a vehicle names
--------------------------------------------------------------------------

T.test("platform: the bike's input map is a table of action -> key + context", function()
    local sv = F.server()
    local B = sv.env.BMX
    local m = B.InputMaps.bike
    T.eq(m.actions.sprint.key, IN.SPEED, "sprint is Shift")
    T.eq(m.actions.hop.key, IN.JUMP, "hop is Space")
    local air = {}
    for _, a in ipairs(B.InputActions("bike", "air")) do air[a.name] = true end
    T.ok(air.alt and air.hop and air.tuck, "the air actions include the style modifier, the hop and the tuck")
    T.ok(not air.sprint, "and not sprint")
    local gnd = {}
    for _, a in ipairs(B.InputActions("bike", "ground")) do gnd[a.name] = true end
    T.ok(gnd.sprint, "sprint is a ground action")
    local all = B.InputActions("bike")
    T.ok(#all >= 10, "a keybind panel can list them all")
    for _, a in ipairs(all) do
        for _, c in ipairs(a.ctx) do T.ok(B.InputContexts[c], a.name .. ": " .. c .. " is a context") end
    end
end)

T.test("platform: an input map with a bad context or key is refused", function()
    local sv = F.server()
    local B = sv.env.BMX
    T.errors(function() B.RegisterInputMap{ id = "x", actions = { a = { key = 1, ctx = { "space" } } } } end,
        "context", "unknown context")
    T.errors(function() B.RegisterInputMap{ id = "x", actions = { a = { key = "W", ctx = { "air" } } } } end,
        "key", "key must be a bit")
    T.errors(function() B.RegisterInputMap{ id = "x", actions = { a = { key = 1, ctx = { "air" }, lable = "x" } } } end,
        "unknown field", "stray field")
end)

local function cmd(buttons)
    local c = { buttons = buttons or 0, fwd = 0, side = 0 }
    function c:GetButtons() return self.buttons end
    function c:SetButtons(b) self.buttons = b end
    function c:GetForwardMove() return self.fwd end
    function c:GetSideMove() return self.side end
    function c:SetForwardMove(v) self.fwd = v end
    function c:SetSideMove(v) self.side = v end
    function c:SetUpMove() end
    return c
end

T.test("platform: sv_input reads its keys from the vehicle's map", function()
    local sv = F.server()
    local bike = F.bike(sv)
    local bplayer = F.rider(sv, bike, { name = "BikeRider" })
    local cart = F.bike(sv, "bmx_testcart", sv.env.Vector(400, 0, sv.world.groundZ + 12))
    local cplayer = F.rider(sv, cart, { name = "CartRider" })
    local function press(ply, buttons)
        sv.env.hook.Run("StartCommand", ply, cmd(buttons))
    end

    press(bplayer, IN.SPEED + IN.ATTACK2 + IN.ATTACK + IN.FORWARD)
    T.ok(bike.input.sprint and bike.input.wheelieMod and bike.input.brakeFront == 1, "the bike's map has all three")
    T.eq(bike.input.throttle, 1, "and W")

    press(cplayer, IN.SPEED + IN.ATTACK2 + IN.ATTACK + IN.FORWARD)
    T.ok(not cart.input.sprint, "the cart's map has no sprint")
    T.ok(not cart.input.wheelieMod, "no weight shift")
    T.eq(cart.input.brakeFront, 0, "no front brake")
    T.eq(cart.input.throttle, 1, "but W accelerates")
    press(cplayer, IN.MOVERIGHT)
    T.eq(cart.input.leanTarget, 1, "and D steers right")
end)

T.test("platform: the pose sets and grind points a vehicle names are real", function()
    local sv = F.server()
    local B = sv.env.BMX
    T.ok(B.PoseSets.bike and B.PoseSets.seated, "pose sets are declared")
    T.eq(B.PoseSetFor(F.bike(sv)).id, "bike", "a bike has the bike's pose set")
    T.eq(B.PoseSetFor(F.bike(sv, "bmx_testcart")).id, "seated", "the cart's is the plain seated one")
    local gp = B.GrindPointsFor(B.Bikes.stock, B.Config)
    T.near(gp.crank.z, B.GrindCrankPoint(B.Config).z, 1e-9, "a bike's crank point is the old function's")
    T.eq(gp.pegs.y, B.Config.Grind.pegY, "its pegs are the config's")
    T.eq(#gp.pegs.x, 2, "one per axle")
    T.eq(next(B.GrindPointsFor(B.Vehicles.testcart, B.Config)), nil, "the cart cannot grind")
end)

T.test("platform: a trick list limits what a vehicle can score", function()
    local sv = F.server()
    local B = sv.env.BMX
    T.ok(B.VehicleAllows(B.Bikes.stock, "frontflip"), "a bike does everything")
    T.ok(B.VehicleAllows(nil, "frontflip"), "no definition allows everything")
    T.ok(not B.VehicleAllows(B.Vehicles.testcart, "frontflip"), "the cart does nothing")
    local st = B.NewState(B.Config)
    st.spinPitch = -12.7
    local with = #B.ScoreAir(st)
    st.def = B.Vehicles.testcart
    T.ok(#B.ScoreAir(st) < with or with == 0, "a vehicle with no tricks is not paid for a flip")
end)

--------------------------------------------------------------------------
-- Settings: vehicles switched on and off
--------------------------------------------------------------------------

T.test("platform: a Vehicles settings row for each spawn menu heading, matching the convars", function()
    local sv = F.server()
    local B, E = sv.env.BMX, sv.env
    local S = B.Settings
    T.eq(#B.SpawnCategories, 4, "Bikes, Boards, Scooters, Motor")
    for _, c in ipairs(B.SpawnCategories) do
        local row = S.Get("bmx_allow_" .. c.key)
        T.ok(row, c.label .. " has a settings row")
        T.eq(row.scope, "server", c.label .. " is a server setting")
        T.eq(row.category, "vehicles", c.label .. " is in the Vehicles group")
        T.eq(row.default, true, c.label .. " is on by default")
        T.ok(E.GetConVar("bmx_allow_" .. c.key), c.label .. " has its convar")
    end
    for _, fam in pairs(B.Families) do
        T.ok(S.Get("bmx_allow_" .. fam.key), fam.category .. " is a heading with a switch")
    end
end)

local function looker(sv, name)
    local E = sv.env
    local ply = sv:player(name or "Spawner")
    ply:SetPos(E.Vector(0, 0, 0))
    ply._eyeTrace = { Hit = true, HitPos = E.Vector(100, 0, 0), HitNormal = E.Vector(0, 0, 1) }
    return ply
end

local function spawn(sv, ply, id)
    sv.world.time = sv.world.time + 2
    sv:command("bmx_spawn", ply, id)
end

T.test("platform: switching a heading off stops spawning from it, from bmx_spawn and the menu door", function()
    local sv = F.server()
    local E = sv.env
    local ply = looker(sv)
    spawn(sv, ply)
    T.eq(#E.ents.FindByClass("bmx_base"), 1, "bikes spawn by default")
    E.GetConVar("bmx_allow_bikes"):SetString("0")
    ply._chat = {}
    spawn(sv, ply)
    T.eq(#E.ents.FindByClass("bmx_base"), 1, "switched off: no second bike")
    T.ok(ply._chat[1] and ply._chat[1]:find("bmx_allow_bikes", 1, true), "and the player is told why")
    spawn(sv, ply, "cruiser")
    T.eq(#E.ents.FindByClass("bmx_cruiser"), 0, "any bike, not just the stock one")
    T.eq(E.hook.Run("PlayerSpawnSENT", ply, "bmx_mini"), false, "the spawn menu's door is shut too")
    T.eq(E.BMX.VehicleEnabled("stock"), false, "BMX.VehicleEnabled says so")
    E.GetConVar("bmx_allow_bikes"):SetString("1")
    spawn(sv, ply)
    T.eq(#E.ents.FindByClass("bmx_base"), 2, "and back on")
end)

T.test("platform: another heading's switch does not touch the bikes", function()
    local sv = F.server()
    local E = sv.env
    E.GetConVar("bmx_allow_boards"):SetString("0")
    T.eq(E.BMX.VehicleEnabled("stock"), true, "bikes still allowed")
    T.eq(E.BMX.VehicleEnabled("testcart"), false, "but a board is not")
    T.eq(E.BMX.VehicleEnabled("nonexistent"), true, "an unknown id is not this check's business")
end)

T.test("platform: the test cart is hidden, and bmx_spawn refuses it without bmx_debug", function()
    local sv = F.server()
    local B, E = sv.env.BMX, sv.env
    T.ok(B.Vehicles.testcart.hidden and B.Vehicles.testcart.debugOnly, "hidden and debug-only")
    for _, id in ipairs(B.BikeIDs()) do T.ok(id ~= "testcart", "not in BikeIDs") end
    T.ok(not sv.lists.SpawnableEntities.bmx_testcart, "no spawn menu row")
    T.eq(B.ClassFor("testcart"), "bmx_testcart", "but it has a class")
    local ply = looker(sv)
    spawn(sv, ply, "testcart")
    T.eq(#E.ents.FindByClass("bmx_testcart"), 0, "refused without bmx_debug")
    T.ok(ply._chat and ply._chat[#ply._chat]:find("bmx_debug", 1, true), "and told how")
    ply._info = { bmx_debug = 1 }
    spawn(sv, ply, "testcart")
    T.eq(#E.ents.FindByClass("bmx_testcart"), 1, "with bmx_debug 1 it spawns")
    T.ok(E.ents.FindByClass("bmx_testcart")[1]:AssertBuilt(), "built")
end)

--------------------------------------------------------------------------
-- The cart: four wheels, no balance, a throttle
--------------------------------------------------------------------------

local function cart(sv)
    local sag = sv.env.BMX.Config.Chassis.mass * sv.world.gravity / 4 / sv.env.BMX.Config.Wheel.spring
    local e = F.bike(sv, "bmx_testcart",
        sv.env.Vector(0, 0, sv.world.groundZ + sv.env.BMX.Config.Wheel.radius - sag))
    return e
end

T.test("cart: it builds four wheels from its registration, two driven, the front pair steered", function()
    local sv = F.server()
    local e = cart(sv)
    T.ok(e:AssertBuilt(), "built")
    T.eq(#e.wheels, 4, "four wheels")
    local drive, front = 0, 0
    for _, w in ipairs(e.wheels) do
        if w.drive then drive = drive + 1 end
        if w.isFront then front = front + 1; T.eq(type(w.steerMode), "function", "front steers by function") end
    end
    T.eq(drive, 2, "two drive wheels")
    T.eq(front, 2, "two front wheels")
    local m = e.wheels[1].mount
    T.near(m.z, sv.env.BMX.Config.Wheel.restLength, 1e-9, "mounts are restLength above the axle line")
end)

T.test("cart: a wheel with its own radius reads its own Wheel config", function()
    local sv = F.server()
    local B, E = sv.env.BMX, sv.env
    local w = B.NewWheel(E.Vector(0, 0, 8), false, { radius = 14 })
    local WC = w:WheelConfig(B.Config)
    T.eq(WC.radius, 14, "its radius")
    T.eq(WC.spring, B.Config.Wheel.spring, "everything else the vehicle's")
    local plain = B.NewWheel(E.Vector(0, 0, 8), false)
    T.ok(plain:WheelConfig(B.Config) == B.Config.Wheel, "a wheel with no radius gets the group itself")
end)

T.test("cart: it settles on all four wheels with nothing balancing it", function()
    local sv = F.server()
    local e = cart(sv)
    F.scripted(sv, e)
    sv:run(1.5)
    local down = 0
    for _, w in ipairs(e.wheels) do if w.onGround then down = down + 1 end end
    T.eq(down, 4, "all four on the ground")
    T.ok(math.abs(e.st.roll) < math.rad(6), "upright: roll " .. math.deg(e.st.roll))
    T.ok(math.abs(e.st.pitch) < math.rad(6), "level: pitch " .. math.deg(e.st.pitch))
    T.eq(e.st.onStand, false, "no kickstand logic runs on it")
end)

T.test("cart: it drives FORWARD under throttle, and the drive wheels are what push", function()
    local sv = F.server()
    local e = cart(sv)
    F.scripted(sv, e)
    sv:run(0.5)
    local x0 = e:GetPos().x
    F.input(e, { throttle = 1 })
    sv:run(4)
    local moved = e:GetPos().x - x0
    T.ok(moved > 150, "moved forward " .. moved)
    T.ok(e.st.speed > 100, "speed " .. e.st.speed)
    T.ok(e.st.fwdSpeed > 100, "and it is FORWARD speed: " .. e.st.fwdSpeed)
    local rear, front = 0, 0
    for _, w in ipairs(e.wheels) do
        if w.drive then rear = rear + math.abs(w.omega) else front = front + math.abs(w.omega) end
    end
    T.ok(rear > 0 and front > 0, "every wheel is turning")
    T.ok(e.st.speed < 360, "and the throttle drive tops out: " .. e.st.speed)
end)

T.test("cart: no throttle, no drive; brake stops it", function()
    local sv = F.server()
    local e = cart(sv)
    F.scripted(sv, e)
    sv:run(0.5)
    sv:run(1)
    T.ok(e.st.speed < 1, "stands still with the throttle off: " .. e.st.speed)
    F.input(e, { throttle = 1 })
    sv:run(3)
    local v = e.st.speed
    T.ok(v > 80, "gets going " .. v)
    F.input(e, { brakeRear = 1 })
    sv:run(3)
    T.ok(e.st.speed < v * 0.5, "the brake slows it: " .. v .. " -> " .. e.st.speed)
end)

T.test("cart: the front wheels steer by their function, the rear ones do not, and it turns the right way", function()
    local sv = F.server()
    local e = cart(sv)
    F.scripted(sv, e)
    sv:run(0.5)
    F.input(e, { throttle = 1 })
    sv:run(3)
    local yaw0 = e:GetAngles().y
    F.input(e, { throttle = 0.3, lean = 1 })
    sv:run(1.5)
    for _, w in ipairs(e.wheels) do
        if w.isFront then T.ok(w.steer > 0.03, "front steers right: " .. w.steer)
        else T.eq(w.steer, 0, "rear does not steer") end
    end
    local turned = (e:GetAngles().y - yaw0 + 540) % 360 - 180
    T.ok(turned < -5, "turned right (yaw decreases): " .. turned)
    T.ok(math.abs(e.st.roll) < math.rad(12), "and stayed up: roll " .. math.deg(e.st.roll))
    T.eq(e.st.steer, e.wheels[1].steer, "st.steer follows the steered wheels")
end)

T.test("cart: a vehicle whose balance mode has no module runs as none, and says so once", function()
    local sv = F.server()
    local B, E = sv.env.BMX, sv.env
    -- `board` has a module now (the skateboard, G23, sv_board.lua); take it away in
    -- this realm to have a name that is valid but has no code behind it.
    B.BalanceModes.board = nil
    B.RegisterVehicle(board(E, { id = "plat_nomod", balance = "board", drive = { kind = "none" } }))
    local e = F.bike(sv, "bmx_plat_nomod", E.Vector(0, 0, sv.world.groundZ + 12))
    F.scripted(sv, e)
    sv:run(0.5)
    T.ok(e:AssertBuilt(), "it spawns and simulates")
    local n = 0
    for _, m in ipairs(sv.errors) do if m:find("balance mode", 1, true) then n = n + 1 end end
    T.eq(n, 1, "one message, not one per substep")
end)

T.test("cart: the bike is unchanged by sharing the loop with it (stock still pedals forward on 2 wheels)", function()
    local sv = F.server()
    local bike = F.bike(sv)
    F.scripted(sv, bike)
    T.eq(#bike.wheels, 2, "two wheels")
    local f, r = F.wheels(bike)
    T.ok(f.isFront and f.steerMode == "fork" and not f.drive, "front: fork, undriven")
    T.ok(not r.isFront and r.drive, "rear: driven")
    F.accelerateTo(sv, bike, 150)
    T.ok(bike.st.speed >= 150, "pedals up to speed")
end)
