--[[--------------------------------------------------------------------------
    The client half: drawing, the HUD, the tuning overlay, the chase camera and
    the sound loops.

    None of this runs on a dedicated server, so the headless suite has never
    executed a line of it. The first run of these tests found that two of the
    four files threw on every frame they had ever drawn:

      * cl_init.lua's axlePos read `self` inside a plain local function, so the
        procedural wheels -- "the single most useful debugging aid this addon
        has" -- had never been drawn at all.
      * cl_hud.lua's tuning overlay read a global `bike` that does not exist, so
        `bmx_debug 1`, which every page of docs/TUNING.md starts with, threw
        inside HUDPaint instead of drawing.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

-- A server with a ridden bike, and a client that can see it. The client's copy
-- of the bike carries only what the network would give it.
local function scene(opts)
    opts = opts or {}
    local sv, world = F.server()
    local bike = F.bike(sv)
    local ply = F.rider(sv, bike, { name = "Human" })
    local cl = F.client(world)

    local cb = cl:clientEntity("bmx_base")
    cb:SetPos(bike:GetPos())
    cb:SetAngles(bike:GetAngles())
    local pod = cl.makeEntity("prop_vehicle_prisoner_pod")
    pod:SetParent(cb)
    cb:SetPod(pod)

    local me = cl:player("Human")
    me._vehicle = pod
    cl.localPlayer = me
    cb:SetDriver(me)

    return { sv = sv, cl = cl, world = world, bike = bike, ply = ply, cb = cb, me = me }
end

-- Copy the networked vars across, as the engine would at 20 Hz.
local function sync(s)
    for k, v in pairs(s.bike._nw) do
        if k ~= "Driver" and k ~= "Pod" then s.cb._nw[k] = v end
    end
    s.cb:SetPos(s.bike:GetPos())
    s.cb:SetAngles(s.bike:GetAngles())
end

-- Where the client draws each axle: the centre of that wheel's hub beam.
local function hubs(s)
    local E = s.cl.env
    local WC = s.cb:Cfg().Wheel
    local f, r
    for _, b in ipairs(s.cl.beams) do
        local len = (b.a - b.b):Length()
        if math.abs(len - 4.4) < 1e-6 then        -- the 2 x 2.2 hub
            local mid = (b.a + b.b) * 0.5
            local loc = s.cb:WorldToLocal(mid)
            if loc.x > 0 then f = mid else r = mid end
        end
    end
    return f, r
end

local function draw(s)
    s.cl.lines, s.cl.beams, s.cl.drawnModels, s.cl.boxes3d = 0, {}, 0, 0
    s.cb:Draw()
end

T.test("the stock bike is DRAWN as a bike: frame, wheels, bars, drivetrain", function()
    local s = scene()
    s.cl.drawnCS = {}
    draw(s)
    T.eq(s.cl.drawnModels, 0, "the stand-in plate is never drawn")
    T.eq(#s.cl.drawnCS, 2, "two tyre models")
    T.ok(#s.cl.beams > 35, "frame, fork, bars, drivetrain, pegs: " .. #s.cl.beams)
    T.ok(s.cl.boxes3d >= 3, "seat and two pedals")
    local red = 0
    for _, b in ipairs(s.cl.beams) do
        if b.col and b.col.r == 205 and b.col.g == 35 then red = red + 1 end
    end
    T.ok(red >= 8, "the frame, in the bike's frameColor: " .. red .. " tubes")
end)

T.test("the tyres sit on the ground and the frame is attached to them", function()
    local s = scene()
    draw(s)
    local f, r = hubs(s)
    T.ok(f and r, "both hubs drawn")
    local R = s.cb:Cfg().Wheel.radius
    T.near(f.z, R, 0.3, "front axle one radius up")
    T.near(r.z, R, 0.3, "rear axle one radius up")
    -- Some frame tube must end at each axle: the stays at the back, the fork
    -- at the front. Offset sideways by half the tube spacing, so within 2.
    local function touches(p)
        for _, b in ipairs(s.cl.beams) do
            if (b.a - p):Length() < 2 or (b.b - p):Length() < 2 then
                if b.w >= 0.9 and b.w <= 1.1 then return true end
            end
        end
    end
    T.ok(touches(r), "chain/seat stays run to the rear axle")
    T.ok(touches(f), "fork legs run to the front axle")
end)

T.test("the bars turn with the steer angle", function()
    local s = scene()
    local function barYaw()
        draw(s)
        -- The bar is the widest-spaced near-horizontal tube, high up.
        local best, len = nil, 0
        for _, b in ipairs(s.cl.beams) do
            local d = b.b - b.a
            if b.a.z > 25 and math.abs(d.z) < 1 and d:Length() > len then best, len = d, d:Length() end
        end
        return math.deg(math.atan2(best.y, best.x))
    end
    local straight = barYaw()
    s.cb:SetSteer(math.rad(20))
    local turned = barYaw()
    T.near(math.abs(math.AngleDifference(turned, straight)), 20, 1.5, "bars rotated by the steer")
end)

T.test("the cranks turn with the cadence and stop when coasting", function()
    local s = scene()
    s.cb:SetCadence(0)
    draw(s)
    local a0 = s.cb.crankAngle
    draw(s)
    T.eq(s.cb.crankAngle, a0, "coasting: cranks still")
    s.cb:SetCadence(10)
    draw(s)
    T.near(s.cb.crankAngle - a0, 10 * s.world.dt, 1e-9, "pedalling: turned by cadence*dt")
end)

T.test("the kickstand shows only when the bike is parked", function()
    local s = scene()
    local function standDrawn()
        draw(s)
        for _, b in ipairs(s.cl.beams) do
            if math.abs(b.w - 0.8) < 1e-9 then return true end
        end
        return false
    end
    T.ok(not standDrawn(), "not with a rider")
    s.cb:SetDriver(s.cl.NULL)
    T.ok(standDrawn(), "parked: stand down")
    s.cb:SetSpeedUPS(100)
    T.ok(not standDrawn(), "rolling away riderless: stand up")
end)

T.test("red tyres off the ground are a bmx_debug aid, not the normal look", function()
    local s = scene()
    s.cb:SetPos(s.cb:GetPos() + s.cl.env.Vector(0, 0, 200))
    local function reds()
        draw(s)
        local n = 0
        for _, b in ipairs(s.cl.beams) do if b.col and b.col.r == 235 then n = n + 1 end end
        return n
    end
    T.eq(reds(), 0, "normal play: black tyres in the air")
    s.cl.env.GetConVar("bmx_debug"):SetString("1")
    T.ok(reds() > 0, "bmx_debug 1: red when the trace finds no ground")
end)

T.test("a bike that ships a model draws the model instead of the frame", function()
    local s = scene()
    s.cl.env.BMX.RegisterBike("modelled", { model = "models/some/bike.mdl" })
    local e = s.cl:clientEntity("bmx_base")
    e.BikeID = "modelled"
    e:SetPos(s.cb:GetPos())
    s.cl.drawnModels, s.cl.beams = 0, {}
    e:Draw()
    T.eq(s.cl.drawnModels, 1, "the model")
    for _, b in ipairs(s.cl.beams) do
        T.ok(not (b.col and b.col.r == 205 and b.col.g == 35),
            "no procedural frame tube on a modelled bike")
    end
    T.ok(#s.cl.beams > 0, "its wheels are still drawn")
end)

T.test("the rider HUD draws the speed in the chosen units", function()
    local s = scene()
    s.cb:SetSpeedUPS(300)
    s.cl.texts = {}
    s.cl.env.hook.Run("HUDPaint")
    local joined = table.concat(s.cl.texts, " ")
    T.ok(joined:find("km/h"), "km/h is the default unit: " .. joined)
    T.ok(joined:find("27"), "300 u/s is 27 km/h: " .. joined)

    s.cl.env.GetConVar("bmx_units"):SetString("mph")
    s.cl.texts = {}
    s.cl.env.hook.Run("HUDPaint")
    joined = table.concat(s.cl.texts, " ")
    T.ok(joined:find("mph") and joined:find("17"), "300 u/s is 17 mph: " .. joined)
end)

T.test("bmx_debug: the server's stream decodes on the client and the overlay draws", function()
    local s = scene()
    s.cl.env.GetConVar("bmx_debug"):SetString("1")
    s.sv:run(0.3)

    local msg
    for _, m in ipairs(s.world.wire) do
        if m.name == "bmx_debug" and m.to == s.ply then msg = m end
    end
    T.ok(msg, "the server streamed a debug frame to the rider who asked for one")

    -- Every field read, in order, with the right types: cl:deliver fails on a
    -- short read, a long read, or a type mismatch.
    s.cl:deliver(msg)

    s.cl.texts = {}
    s.cl.env.hook.Run("HUDPaint")
    local joined = table.concat(s.cl.texts, " ")
    for _, want in ipairs({ "BALANCE", "ATTITUDE", "DRIVE", "FRONT WHEEL", "REAR WHEEL",
                            "compression" }) do
        T.ok(joined:find(want, 1, true), "overlay row " .. want .. " drawn")
    end
    T.ok(not joined:find("waiting for server stream"), "the overlay had a frame to show")
end)

T.test("bmx_debug is only streamed to a rider who turned it on", function()
    local s = scene()
    s.cl.env.GetConVar("bmx_debug"):SetString("0")
    s.sv:run(0.5)
    for _, m in ipairs(s.world.wire) do
        T.ok(m.name ~= "bmx_debug", "no debug frame without bmx_debug 1")
    end
end)

T.test("a trick callout crosses the wire and is drawn", function()
    local s = scene()
    s.bike:AwardTricks({ { name = "Backflip", count = 2, points = 1000 },
                         { name = "Air Time", count = 1, points = 180 } })
    local msg
    for _, m in ipairs(s.world.wire) do if m.name == "bmx_tricks" then msg = m end end
    T.ok(msg, "the rider was sent a callout")
    T.eq(msg.to, s.ply, "only the rider")

    local heard
    s.cl.env.hook.Add("BMX_TricksLandedClient", "t", function(tr, total) heard = total end)
    s.cl:deliver(msg)
    T.eq(heard, 1180, "the total survives the trip")

    s.cl.texts = {}
    s.cl.env.hook.Run("HUDPaint")
    local joined = table.concat(s.cl.texts, " ")
    T.ok(joined:find("2x Backflip", 1, true), "callout text: " .. joined)
    T.ok(joined:find("+1000", 1, true), "points: " .. joined)
end)

T.test("a callout with more tricks than the wire carries is truncated, not garbled", function()
    local s = scene()
    local many = {}
    for i = 1, 11 do many[i] = { name = "T" .. i, count = 40, points = 99999 } end
    s.bike:AwardTricks(many)
    local msg
    for _, m in ipairs(s.world.wire) do if m.name == "bmx_tricks" then msg = m end end
    s.cl:deliver(msg)      -- clamped counts and points must still fit their bits
end)

T.test("the chase camera opens at the real field of view, not zoomed in", function()
    local s = scene()
    local E = s.cl.env
    local view = E.hook.Run("CalcView", s.me, E.Vector(), E.Angle(0, 0, 0), 90)
    T.ok(view, "CalcView returns a view while riding")
    -- The smoothers used to start at zero: the first frame on a bike had a FOV
    -- of about 6 degrees and zoomed out over most of a second.
    T.between(view.fov, 85, 110, "FOV on the first frame after mounting")
    T.ok(view.drawviewer, "third person draws the rider")

    local d = (view.origin - s.cb:LocalToWorld(E.Vector(0, 0, 26))):Length()
    T.between(d, 80, 160, "camera distance on the first frame")
end)

T.test("the chase camera leans with the bike, by a fraction", function()
    local s = scene()
    local E = s.cl.env
    s.cb:SetAngles(E.Angle(0, 0, 30))
    local view = E.hook.Run("CalcView", s.me, E.Vector(), E.Angle(0, 0, 0), 90)
    T.between(view.angles.r, 30 * 0.34 - 0.5, 30 * 0.34 + 0.5, "view roll = lean * bmx_cam_roll")
end)

T.test("the camera lets go when the rider gets off", function()
    local s = scene()
    local E = s.cl.env
    s.me._vehicle = nil
    T.eq(E.hook.Run("CalcView", s.me, E.Vector(), E.Angle(), 90), nil, "no override on foot")
    T.eq(E.hook.Run("HUDShouldDraw", "CHudCrosshair"), nil, "crosshair back on foot")
    s.me._vehicle = s.cb:GetPod()
    T.eq(E.hook.Run("HUDShouldDraw", "CHudCrosshair"), false, "crosshair hidden riding")
end)

T.test("sound: rolling starts on the ground and stops, once, in the air", function()
    local s = scene()
    local E = s.cl.env
    s.cb:SetGrounded(true)
    s.cb:SetSpeedUPS(250)
    s.cb:SetCadence(8)
    s.cl:run(0.1)

    local roll
    for _, p in ipairs(s.cl.patches) do
        if p.path == E.BMX.Sounds.roll.path then roll = p end
    end
    T.ok(roll and roll.playing, "the rolling loop plays at speed on the ground")

    s.cb:SetGrounded(false)
    local before = s.cl.timersCreated or 0
    s.cl:run(0.5)
    T.ok(not roll.playing, "and stops in the air")
    -- The fade used to queue a new timer on every frame it ran: a dozen
    -- closures per jump per bike, all racing to stop the same patch.
    T.eq((s.cl.timersCreated or 0) - before, 0, "timers created by the fade")
end)

T.test("sound: coasting ticks the freewheel, pedalling does not", function()
    local s = scene()
    local E = s.cl.env
    local tick = E.BMX.Sounds.tick.path
    s.cb:SetGrounded(true)
    s.cb:SetSpeedUPS(200)

    s.cb:SetCadence(0)
    s.cl.sounds = {}
    s.cl:run(1.0)
    local coasting = 0
    for _, x in ipairs(s.cl.sounds) do if x.name == tick then coasting = coasting + 1 end end
    T.between(coasting, 10, 66, "freewheel ticks in a second of coasting at 200 u/s")

    s.cb:SetCadence(10)
    s.cl.sounds = {}
    s.cl:run(1.0)
    for _, x in ipairs(s.cl.sounds) do
        T.ok(x.name ~= tick, "no freewheel tick while the cranks are turning")
    end
end)

T.test("sound: a skid is heard only when the server says the tyre is sliding", function()
    local s = scene()
    local E = s.cl.env
    s.cb:SetGrounded(true)
    s.cb:SetSpeedUPS(200)
    s.cl:run(0.2)
    local skid
    for _, p in ipairs(s.cl.patches) do
        if p.path == E.BMX.Sounds.skid.path then skid = p end
    end
    T.ok(not (skid and skid.playing), "no skid while gripping")
    s.cb:SetSkidding(true)
    s.cl:run(0.1)
    for _, p in ipairs(s.cl.patches) do
        if p.path == E.BMX.Sounds.skid.path then skid = p end
    end
    T.ok(skid and skid.playing, "skid plays when Skidding is networked true")
end)

T.test("sound: a removed bike leaves nothing playing", function()
    local s = scene()
    s.cb:SetGrounded(true)
    s.cb:SetSpeedUPS(250)
    s.cb:SetSkidding(true)
    s.cl:run(0.2)
    s.cb:Remove()
    s.cl:run(0.1)
    for _, p in ipairs(s.cl.patches) do
        T.ok(not p.playing, p.path .. " still playing after its bike was removed")
    end
end)

T.test("HUD values the client draws match what the server simulates", function()
    local s = scene()
    F.input(s.bike, { throttle = 1 })
    s.ply.BMXScripted = true
    s.sv:run(2)
    sync(s)
    T.near(s.cb:GetSpeedUPS(), s.bike.st.speed, 60,
        "networked speed tracks the simulation (20 Hz copy)")
    T.ok(s.cb:GetStamina() > 0, "stamina is networked")
end)

T.test("the tyres are real round models, centred on their axles and turning about them", function()
    local s = scene()
    s.cl.drawnCS = {}
    draw(s)
    local f, r = hubs(s)
    for i, d in ipairs(s.cl.drawnCS) do
        T.eq(d.model, "models/props_phx/wheels/moped_tire.mdl", "a base-game tyre")
        local axle = d.ang:Up()
        -- The model's origin is on one face; its centre is 4.37 model units up
        -- the axle, scaled. Put that back and it must be on a hub.
        local s0 = s.cb:Cfg().Wheel.radius / 19.19
        local centre = d.pos + axle * (4.37 * s0 * 0.62)
        local dF, dR = (centre - f):Length(), (centre - r):Length()
        T.ok(math.min(dF, dR) < 0.01, "tyre " .. i .. " centred on a hub: " .. math.min(dF, dR))
        T.near(math.abs(axle:Dot(s.cb:GetRight())), 1, 1e-6, "axle along the bike's right")
    end

    -- It rolls: the model's forward turns with the spin.
    s.cb._vel = s.cb:GetForward() * 200
    local before = s.cl.drawnCS[1].ang:Forward()
    s.cl.drawnCS = {}
    draw(s)
    local after = s.cl.drawnCS[1].ang:Forward()
    T.ok(before:Dot(after) < 0.9999, "the tyre turned between frames")
end)

T.test("without the tyre model, the beam tyre and spokes are drawn instead", function()
    local s = scene()
    s.cl.missingModels["models/props_phx/wheels/moped_tire.mdl"] = true
    s.cl.drawnCS = {}
    draw(s)
    T.eq(#s.cl.drawnCS, 0, "no model")
    T.eq(s.cl.lines, 24, "twelve spokes a wheel")
    T.ok(#s.cl.beams > 100, "beam tyres and rims")
    local said = false
    for _, l in ipairs(s.cl.log) do if l:find("did not load") then said = true end end
    T.ok(said, "and says so in the console, once")
end)

T.test("a tyre model that failed is tried again, not given up on for good", function()
    local s = scene()
    local M = "models/props_phx/wheels/moped_tire.mdl"
    s.cl.missingModels[M] = true
    draw(s)
    T.eq(#s.cl.drawnCS, 0, "fallback first")
    s.cl.missingModels[M] = nil
    s.cl.drawnCS = {}
    draw(s)
    T.eq(#s.cl.drawnCS, 0, "not retried every frame")
    s.world.time = s.world.time + 4
    s.cl.drawnCS = {}
    draw(s)
    T.eq(#s.cl.drawnCS, 2, "retried a few seconds later, and drawn")
end)

T.test("the server precaches the tyre model for every client", function()
    local s = scene()
    T.ok(s.sv.precached["models/props_phx/wheels/moped_tire.mdl"], "precached server-side")
end)

T.test("the fallback tyre has no gaps and its tread turns with the wheel", function()
    local s = scene()
    s.cl.missingModels["models/props_phx/wheels/moped_tire.mdl"] = true
    s.cb._vel = s.cb:GetForward() * 200
    draw(s)
    -- Consecutive tyre segments overlap: each beam reaches past the next's start.
    local tyres = {}
    for _, b in ipairs(s.cl.beams) do
        if b.col and b.col.r == 24 then tyres[#tyres + 1] = b end
    end
    T.ok(#tyres >= 96, "48 segments a tyre: " .. #tyres)
    local a, b = tyres[1], tyres[2]
    T.ok((a.b - b.a):Length() > a.w * 0.9, "neighbouring segments overlap by the beam width")
    local function treadAt()
        for _, x in ipairs(s.cl.beams) do
            if x.col and x.col.r == 58 then return (x.a + x.b) * 0.5 end
        end
    end
    local t0 = treadAt()
    draw(s)
    T.ok((treadAt() - t0):Length() > 0.05, "the tread moved: the tyre turns")
end)

T.test("each wheel spins from forward speed, and stops once the bike is down", function()
    local s = scene()
    local E = s.cl.env
    s.cb._vel = s.cb:GetForward() * 200
    draw(s)
    local rate = s.cb.spin.rear.rate
    T.near(rate, 200 / s.cb:Cfg().Wheel.radius, 1e-6, "rolling at ground speed")
    s.cb._vel = s.cb:GetForward() * -50
    draw(s)
    T.ok(s.cb.spin.rear.rate < 0, "backwards is backwards")

    -- Crashed: lying on its side, still sliding and tumbling.
    s.cb._vel = s.cb:GetForward() * 200
    draw(s)
    s.cb:SetAngles(E.Angle(0, 0, 85))
    s.cb._vel = E.Vector(0, 0, -300)                 -- falling: speed, not rolling
    for _ = 1, 66 do draw(s) end                     -- a second
    T.between(math.abs(s.cb.spin.rear.rate), 0, 0.1, "the wheels have stopped")
end)

T.test("a wheel in the air keeps turning and winds down slowly", function()
    local s = scene()
    local E = s.cl.env
    s.cb._vel = s.cb:GetForward() * 200
    draw(s)
    s.cb:SetPos(s.cb:GetPos() + E.Vector(0, 0, 100))    -- airborne, upright
    for _ = 1, 66 do draw(s) end
    local r = s.cb.spin.rear.rate
    T.between(r / (200 / s.cb:Cfg().Wheel.radius), 0.5, 0.7, "about exp(-0.5) of it after a second")
end)

T.test("tyre models are made once per wheel and removed with the bike", function()
    local s = scene()
    for _ = 1, 30 do draw(s) end
    T.eq(#s.cl.csModels, 2, "two clientside models, however many frames")
    s.cb:Remove()
    for _, m in ipairs(s.cl.csModels) do T.ok(m.removed, "removed with the bike") end
end)

T.test("at speed the bars are drawn turned more than the physics steer, never past the lock", function()
    local s = scene()
    local B = s.cl.env.BMX
    local C = s.cb:Cfg()
    local function barYaw()
        s.cl.beams = {}
        s.cb:Draw()
        local best, len = nil, 0
        for _, b in ipairs(s.cl.beams) do
            local d = b.b - b.a
            if b.a.z > 25 and math.abs(d.z) < 1 and d:Length() > len then best, len = d, d:Length() end
        end
        return math.deg(math.atan2(best.y, best.x))
    end
    local straight = barYaw()
    s.cb:SetSteer(math.rad(8))
    s.cb:SetSpeedUPS(280)
    local fast = math.abs(math.AngleDifference(barYaw(), straight))
    T.between(fast, 22, 26, "8 degrees of real steer at 280 u/s is drawn as ~24")
    s.cb:SetSpeedUPS(20)
    local slow = math.abs(math.AngleDifference(barYaw(), straight))
    T.near(slow, 8, 1, "at walking pace, drawn as it is")
    s.cb:SetSteer(math.rad(30))
    s.cb:SetSpeedUPS(280)
    T.ok(math.abs(math.AngleDifference(barYaw(), straight)) <= math.deg(C.Balance.maxSteer) + 0.5,
        "never drawn past the steering lock")
end)
