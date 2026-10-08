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

local TYRE = "models/props_phx/wheels/moped_tire.mdl"
local function tyreDraws(s)
    local o = {}
    for _, d in ipairs(s.cl.drawnCS) do if d.model == TYRE then o[#o + 1] = d end end
    return o
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
    T.eq(#tyreDraws(s), 2, "two tyre models")
    T.ok(#s.cl.beams > 35, "frame, fork, bars, drivetrain, pegs: " .. #s.cl.beams)
    local solids = 0
    for _, d in ipairs(s.cl.drawnCS) do
        if d.model:find("sphere025") or d.model:find("cube025") then solids = solids + 1 end
    end
    T.ok(solids >= 3, "saddle, pedals and joints are solid shapes: " .. solids)
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

T.test("the pedals are geared to the rear wheel: still with it, forward with it, back with it", function()
    local s = scene()
    local C = s.cb:Cfg()
    s.cb:SetCadence(12)                    -- the rider's legs are not what turns them
    s.cb._vel = s.cb:GetForward() * 0
    draw(s)
    local a0 = s.cb.crankAngle
    draw(s)
    T.eq(s.cb.crankAngle, a0, "wheel still: pedals still, whatever the cadence says")

    s.cb._vel = s.cb:GetForward() * 200
    draw(s)
    T.near(s.cb.crankAngle, s.cb.spin.rear.angle / C.Drive.gearRatio, 1e-9,
        "crank angle is the rear wheel's through the gear")
    local fwdA = s.cb.crankAngle
    draw(s)
    T.ok(s.cb.crankAngle > fwdA, "rolling forward: pedals forward")
    local back0 = s.cb.crankAngle
    s.cb._vel = s.cb:GetForward() * -60
    draw(s)
    T.ok(s.cb.crankAngle < back0, "rolling back: pedals back")
end)

T.test("the kickstand is drawn exactly when it is down", function()
    local s = scene()
    local function standDrawn()
        draw(s)
        for _, b in ipairs(s.cl.beams) do
            if math.abs(b.w - 0.8) < 1e-9 then return true end
        end
        return false
    end
    s.cb:SetStandDown(false)
    T.ok(not standDrawn(), "up: not drawn")
    s.cb:SetStandDown(true)
    T.ok(standDrawn(), "down: drawn")
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
    local function ticks()
        local n = 0
        for _, x in ipairs(s.cl.sounds) do if x.name:find("^bmx/tick%d%.wav$") then n = n + 1 end end
        return n
    end
    local function buzz()
        for _, p in ipairs(s.cl.patches) do
            if p.path == E.BMX.Sounds.freewheel.path then return p.playing end
        end
        return false
    end
    s.cb:SetGrounded(true)

    -- A slow roll: single ticks, as many as the pawls pass.
    s.cb:SetSpeedUPS(25)
    s.cb:SetCadence(0)
    s.cl.sounds = {}
    s.cl:run(1.0)
    T.between(ticks(), 6, 30, "freewheel ticks in a second of coasting at 25 u/s")

    -- Coasting fast: too many to hear apart, so the buzz loop.
    s.cb:SetSpeedUPS(200)
    s.cl.sounds = {}
    s.cl:run(0.5)
    T.ok(buzz(), "the freewheel buzzes coasting at 200 u/s")

    -- Pedalling at the wheel's pace: locked, silent.
    s.cb:SetCadence(10)
    s.cl.sounds = {}
    s.cl:run(1.0)
    T.eq(ticks(), 0, "no freewheel tick while the cranks are turning")
    T.ok(not buzz(), "and no buzz")
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
    for i, d in ipairs(tyreDraws(s)) do
        T.eq(d.model, TYRE, "a base-game tyre")
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
    local before = tyreDraws(s)[1].ang:Forward()
    s.cl.drawnCS = {}
    draw(s)
    local after = tyreDraws(s)[1].ang:Forward()
    T.ok(before:Dot(after) < 0.9999, "the tyre turned between frames")
end)

T.test("without the tyre model, the beam tyre and spokes are drawn instead", function()
    local s = scene()
    s.cl.missingModels["models/props_phx/wheels/moped_tire.mdl"] = true
    s.cl.drawnCS = {}
    draw(s)
    T.eq(#tyreDraws(s), 0, "no tyre model")
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
    T.eq(#tyreDraws(s), 0, "fallback first")
    s.cl.missingModels[M] = nil
    s.cl.drawnCS = {}
    draw(s)
    T.eq(#tyreDraws(s), 0, "not retried every frame")
    s.world.time = s.world.time + 4
    s.cl.drawnCS = {}
    draw(s)
    T.eq(#tyreDraws(s), 2, "retried a few seconds later, and drawn")
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
    -- Two tyres and one of each primitive shape (cylinder, sphere, box).
    T.eq(#s.cl.csModels, 5, "five clientside models, however many frames")
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

T.test("a crash ragdoll shows its rider's colour even if the colour arrives late", function()
    local s = scene()
    local E = s.cl.env
    local rag = s.cl.makeEntity("prop_ragdoll")
    E.hook.Run("OnEntityCreated", rag)          -- created before any networked vars
    T.ok(rag.GetPlayerColor, "the ragdoll can answer the PlayerColor proxy")
    T.eq(rag:GetPlayerColor(), nil, "nothing yet")
    local red = E.Vector(0.9, 0.1, 0.1)
    rag:SetNWVector("BMXPlayerColor", red)      -- arrives a moment later
    T.ok(rag:GetPlayerColor() == red, "and shows it once it arrives")

    local rag2 = s.cl.makeEntity("prop_ragdoll")
    E.hook.Run("OnEntityCreated", rag2)
    s.me.GetPlayerColor = function() return E.Vector(0.1, 0.9, 0.1) end
    rag2:SetNWEntity("BMXRider", s.me)
    T.ok(rag2:GetPlayerColor().y > 0.8, "or asks its rider")
end)

T.test("the frame is solid 3D tubes in glossy paint, with round joints", function()
    local s = scene()
    s.cl.drawnCS = {}
    draw(s)
    local cyl, sph, painted = 0, 0, 0
    for _, d in ipairs(s.cl.drawnCS) do
        if d.model == "models/xqm/cylinderx1.mdl" then cyl = cyl + 1 end
        if d.model == "models/hunter/misc/sphere025x025.mdl" then sph = sph + 1 end
        if d.material and d.material ~= "" then painted = painted + 1 end
    end
    T.ok(cyl >= 25, "tubes are cylinders: " .. cyl)
    T.ok(sph >= 5, "joints and saddle are spheres: " .. sph)
    T.eq(painted, #s.cl.drawnCS - #tyreDraws(s), "every shape has a material")
    -- The top tube runs seat cluster to head tube, and is the frame's colour.
    local red = 0
    for _, b in ipairs(s.cl.beams) do
        if b.cylinder and b.col.r == 205 and b.col.g == 35 then red = red + 1 end
    end
    T.ok(red >= 8, "frame tubes in the bike's red: " .. red)
end)

T.test("changing the networked colour repaints the frame", function()
    local s = scene()
    local B = s.cl.env.BMX
    s.cb:SetColorIndex(B.PaletteIndex("blue"))
    draw(s)
    local blue = B.PaletteColor(B.PaletteIndex("blue"))
    local n = 0
    for _, b in ipairs(s.cl.beams) do
        if b.cylinder and b.col.r == blue.r and b.col.g == blue.g and b.col.b == blue.b then n = n + 1 end
    end
    T.ok(n >= 8, "frame tubes in blue: " .. n)
end)

T.test("without the shape models, the frame falls back to flat tubes", function()
    local s = scene()
    s.cl.missingModels["models/xqm/cylinderx1.mdl"] = true
    local orig = s.cl.env.ClientsideModel
    s.cl.env.ClientsideModel = function(m) if s.cl.missingModels[m] then return nil end return orig(m) end
    draw(s)
    local flat = 0
    for _, b in ipairs(s.cl.beams) do if not b.cylinder then flat = flat + 1 end end
    T.ok(flat >= 25, "beams instead: " .. flat)
end)

T.test("a recolour arrives as a puff of smoke in the new colour", function()
    local s = scene()
    local B = s.cl.env.BMX
    s.bike:SetColorIndex(1)
    B.SetBikeColor = B.SetBikeColor      -- client has none; the server sends it
    s.sv.env.BMX.SetBikeColor(s.bike, 8, true)
    local msg
    for _, m in ipairs(s.world.wire) do if m.name == "bmx_puff" then msg = m end end
    T.ok(msg and msg.pvs, "sent to everyone who can see the bike")
    msg.items[1].value = s.cb                 -- the client's copy of the entity
    s.cl.particles = {}
    s.cl:deliver(msg)
    T.ok(#s.cl.particles >= 20, "a puff: " .. #s.cl.particles)
    local blue = B.PaletteColor(8)
    local coloured = 0
    for _, p in ipairs(s.cl.particles) do
        if p.color and p.color.r == blue.r and p.color.b == blue.b then coloured = coloured + 1 end
    end
    T.ok(coloured > #s.cl.particles / 2, "mostly in the new colour")
end)

T.test("materials by part: metallic paint frame, chrome metal, matte saddle and grips", function()
    local s = scene()
    local M = s.cl.env.BMX.BikeMaterials
    s.cl.drawnCS = {}
    draw(s)
    local byMat = {}
    for _, d in ipairs(s.cl.drawnCS) do
        if d.material then byMat[d.material] = (byMat[d.material] or 0) + 1 end
    end
    T.ok((byMat[M.paint] or 0) >= 10, "the frame in metallic paint")
    T.ok((byMat[M.chrome] or 0) >= 3, "seat post, spindle and pegs in chrome")
    T.ok((byMat[M.satin] or 0) >= 5, "bars, fork and cranks anodised")
    T.ok((byMat[M.matte] or 0) >= 3, "saddle and grips matte")
    local saddle
    for _, d in ipairs(s.cl.drawnCS) do
        if d.model:find("sphere025") and d.scale.x > d.scale.y * 2 then saddle = d end
    end
    T.ok(saddle and saddle.material == M.matte, "the saddle is not shiny")
    T.ok(not byMat["models/shiny"], "nothing left in the old mirror finish")
end)

T.test("the camera eases through a landing instead of stopping dead with the bike", function()
    local s = scene()
    local E = s.cl.env
    local B = E.BMX
    local z0 = 100
    B.CameraFollowHeight(z0, 1 / 66)           -- seed
    -- The bike stops 8 units lower in one tick (a landing).
    local first = B.CameraFollowHeight(z0 - 8, 1 / 66)
    T.ok(first > z0 - 8 + 2, "the view does not jump the whole way at once: " .. first)
    local z, over = first, false
    for _ = 1, 40 do
        z = B.CameraFollowHeight(z0 - 8, 1 / 66)
        if z < z0 - 8 - 0.05 then over = true end
    end
    T.near(z, z0 - 8, 0.05, "it settles where the bike is")
    T.ok(not over, "without bouncing past it")
    B.CameraFollowHeight(z0 - 100, 1 / 66)
    local lagged = B.CameraFollowHeight(z0 - 100, 1 / 66)
    T.ok(lagged <= z0 - 100 + 12.001, "and never lags more than 12 units")
end)

-- Cinematic mode (cl_cinematic.lua).
local function cine(s)
    local E = s.cl.env
    s.cb:SetGrounded(true)
    s.cb._vel = s.cb:GetForward() * 250
    return E
end

local function seq(vals)
    local i = 0
    return function() i = i + 1; return vals[((i - 1) % #vals) + 1] end
end

T.test("L toggles the cinematic camera while riding, and not on foot", function()
    local s = scene()
    local E = cine(s)
    E.hook.Run("PlayerButtonDown", s.me, E.KEY_L)
    T.ok(E.BMX.CinematicActive(s.me), "L: on")
    local view = E.hook.Run("CalcView", s.me, E.Vector(), E.Angle(), 90)
    local subject = s.cb:LocalToWorld(E.Vector(0, 0, 30))
    T.ok((view.origin - subject):Length() > 50, "the camera is off the bike, outside")
    T.ok(view.angles:Forward():Dot((subject - view.origin):GetNormalized()) > 0.999,
        "and looking straight at the rider")
    E.hook.Run("PlayerButtonDown", s.me, E.KEY_L)
    T.ok(not E.BMX.CinematicActive(s.me), "L again: off")
    s.me._vehicle = nil
    E.hook.Run("PlayerButtonDown", s.me, E.KEY_L)
    T.ok(not E.GetConVar("bmx_cinematic"):GetBool(), "on foot, L does nothing")
end)

T.test("a trackside shot holds still, pans with the bike and zooms as it goes", function()
    local s = scene()
    local E = cine(s)
    E.BMX.CinematicState.shot = nil
    local rng = seq({ 0.0, 0.3, 0.5, 0.2, 0.9 })
    local v1 = E.BMX.CinematicView(s.cb, 1 / 66, 0, rng)
    T.eq(E.BMX.CinematicState.shot.kind, "trackside", "riding along, it opens trackside")
    -- The bike rides past the camera.
    s.cb:SetPos(s.cb:GetPos() + s.cb:GetForward() * 300)
    local v2 = E.BMX.CinematicView(s.cb, 1 / 66, 0.2, rng)
    T.ok((v2.origin - v1.origin):Length() < 1e-6, "the camera did not move")
    T.ok(math.abs(math.AngleDifference(v2.angles.y, v1.angles.y)) > 5, "it panned to follow")
    s.cb:SetPos(s.cb:GetPos() + s.cb:GetForward() * 400)
    local v3 = E.BMX.CinematicView(s.cb, 1 / 66, 0.4, rng)
    if E.BMX.CinematicState.shot.kind == "trackside" then
        T.ok(v3.fov < v2.fov, "and tightened the lens as the bike went away")
    end
end)

T.test("shots cut on a timer, and at once when the bike leaves the frame", function()
    local s = scene()
    local E = cine(s)
    E.BMX.CinematicState.shot = nil
    E.BMX.CinematicState.cuts = 0
    local rng = seq({ 0.6, 0.1, 0.4, 0.8 })
    E.BMX.CinematicView(s.cb, 1 / 66, 0, rng)
    local first = E.BMX.CinematicState.shot
    E.BMX.CinematicView(s.cb, 1 / 66, 1, rng)
    T.ok(E.BMX.CinematicState.shot == first, "no cut after a second")
    E.BMX.CinematicView(s.cb, 1 / 66, 10, rng)
    T.ok(E.BMX.CinematicState.shot ~= first, "a cut after the shot's time")
    local second = E.BMX.CinematicState.shot
    -- Turn the camera to face directly AWAY from the rider.
    local sh = E.BMX.CinematicState.shot
    sh.lastAng = (sh.lastOrigin - s.cb:LocalToWorld(E.Vector(0, 0, 30))):Angle()
    E.BMX.CinematicView(s.cb, 1 / 66, 10.1, rng)
    T.ok(E.BMX.CinematicState.shot ~= second, "a cut when the bike is out of frame")
end)

T.test("in the air it cuts to the air shot; standing still, it orbits", function()
    local s = scene()
    local E = cine(s)
    E.BMX.CinematicState.shot = nil
    s.cb:SetGrounded(false)
    E.BMX.CinematicView(s.cb, 1 / 66, 0, seq({ 0.3 }))
    T.eq(E.BMX.CinematicState.shot.kind, "air", "airborne: the air shot")
    s.cb:SetGrounded(true)
    s.cb._vel = E.Vector()
    E.BMX.CinematicView(s.cb, 1 / 66, 0.1, seq({ 0.3 }))
    T.eq(E.BMX.CinematicState.shot.kind, "orbit", "landed and stopped: an orbit")
end)

T.test("cinematic mode letterboxes the screen, hides the HUD, and ends when you get off", function()
    local s = scene()
    local E = cine(s)
    s.cb:SetSpeedUPS(250)
    E.GetConVar("bmx_cinematic"):SetBool(true)
    s.cl.rects, s.cl.texts = {}, {}
    E.hook.Run("HUDPaint")
    T.eq(#s.cl.rects, 2, "two letterbox bars")
    for _, t in ipairs(s.cl.texts) do T.ok(not t:find("km/h"), "no rider HUD: " .. t) end
    s.me._vehicle = nil
    E.hook.Run("Think")
    T.ok(not E.GetConVar("bmx_cinematic"):GetBool(), "off once they get off")
end)

T.test("cinematic mode keeps filming through a crash, until the rider is back up", function()
    local s = scene()
    local E = cine(s)
    E.GetConVar("bmx_cinematic"):SetBool(true)
    E.hook.Run("CalcView", s.me, E.Vector(), E.Angle(), 90)          -- riding shot
    local ridingFrom = E.BMX.CinematicState.shot.lastOrigin

    -- Thrown off: out of the seat, spectating their own ragdoll.
    local rag = s.cl.makeEntity("prop_ragdoll")
    rag:SetPos(s.cb:GetPos() + E.Vector(40, 0, 10))
    rag:SetNWEntity("BMXRider", s.me)
    s.me._vehicle = nil
    s.me._spectating, s.me._spectatee = E.OBS_MODE_CHASE, rag

    E.hook.Run("Think")
    T.ok(E.GetConVar("bmx_cinematic"):GetBool(), "still on while they tumble")
    local v = E.hook.Run("CalcView", s.me, E.Vector(), E.Angle(), 90)
    T.ok(v, "the cinematic camera still has the view")
    local target = rag:GetPos() + E.Vector(0, 0, 8)
    T.ok(v.angles:Forward():Dot((target - v.origin):GetNormalized()) > 0.999, "looking at the ragdoll")
    T.ok(v.origin:Distance(ridingFrom) < 1, "from where the ride was being filmed")
    s.cl.rects = {}
    E.hook.Run("HUDPaint")
    T.eq(#s.cl.rects, 2, "letterbox still up")

    -- The body tumbles on: the shot holds and pans.
    rag:SetPos(rag:GetPos() + E.Vector(120, 60, 0))
    local v2 = E.hook.Run("CalcView", s.me, E.Vector(), E.Angle(), 90)
    T.ok(v2.origin:Distance(v.origin) < 1e-6, "held, not cut")
    T.ok(v2.angles:Forward():Dot((rag:GetPos() + E.Vector(0, 0, 8) - v2.origin):GetNormalized()) > 0.999,
        "panning with the body")

    -- Back on their feet.
    s.me._spectating, s.me._spectatee = nil, nil
    E.hook.Run("Think")
    T.ok(not E.GetConVar("bmx_cinematic"):GetBool(), "off once they are up")
end)

T.test("someone else's crash ragdoll does not keep your cinematic camera on", function()
    local s = scene()
    local E = cine(s)
    E.GetConVar("bmx_cinematic"):SetBool(true)
    local rag = s.cl.makeEntity("prop_ragdoll")
    rag:SetNWEntity("BMXRider", s.cl:player("SomeoneElse"))
    s.me._vehicle = nil
    s.me._spectating, s.me._spectatee = E.OBS_MODE_CHASE, rag
    E.hook.Run("Think")
    T.ok(not E.GetConVar("bmx_cinematic"):GetBool(), "off: that is not their crash")
end)

T.test("a grind throws sparks off the contact and scrapes, and both stop with it", function()
    local s = scene()
    local E = s.cl.env
    s.cl.particles, s.cl.patches = {}, {}
    s.cb:SetGrind(1)
    -- A second at a standstill: the slowest the sparks ever come.
    for _ = 1, 20 do
        s.world.time = s.world.time + 0.05
        E.hook.Run("Think")
    end
    T.ok(#s.cl.particles >= 8, "sparks: " .. #s.cl.particles)
    local crank = s.cb:LocalToWorld(E.BMX.GrindCrankPoint(s.cb:Cfg()))
    T.ok(s.cl.particles[1].pos:Distance(crank) < 0.01, "from the chainring's contact")
    T.eq(s.cl.particles[1].mat, "effects/spark", "spark material")
    local scrape
    for _, p in ipairs(s.cl.patches) do if p.path == E.BMX.Sounds.grind.path then scrape = p end end
    T.ok(scrape and scrape.playing, "scraping")

    -- Pegs on the right: two contacts, on the right (-Y) side.
    s.cl.particles = {}
    s.cb:SetGrind(3)
    for _ = 1, 10 do
        s.world.time = s.world.time + 0.05
        E.hook.Run("Think")
    end
    local right = 0
    for _, p in ipairs(s.cl.particles) do
        if s.cb:WorldToLocal(p.pos).y < 0 then right = right + 1 end
    end
    T.ok(#s.cl.particles > 0 and right == #s.cl.particles, "peg sparks on the right: " .. right)

    s.cb:SetGrind(0)
    s.world.time = s.world.time + 0.05
    E.hook.Run("Think")
    T.ok(not scrape.playing, "the scrape stops when the grind does")
end)

--------------------------------------------------------------------------
-- A CALM CAMERA. The chase camera aimed at a point on the bike's own up
-- axis, so every degree the bike rolled swung the view sideways (26 units up,
-- 20 degrees of roll is 9 units of sway), and its height spring settled in
-- 60 ms, following every bump in the floor one for one.
--------------------------------------------------------------------------
local function chase(s, E)
    return E.hook.Run("CalcView", s.me, E.Vector(), E.Angle(10, 0, 0), 90)
end

T.test("calm camera: the bike rocking side to side does not sway the view", function()
    local s = scene()
    local E = s.cl.env
    local base = s.cb:GetPos()
    local ys = {}
    for i = 0, 60 do
        s.world.time = s.world.time + s.world.dt
        s.cb:SetAngles(E.Angle(0, 0, 20 * math.sin(i * 0.4)))
        s.cb:SetPos(base)
        local v = chase(s, E)
        if i > 10 then ys[#ys + 1] = v.origin.y end
    end
    local lo, hi = math.huge, -math.huge
    for _, y in ipairs(ys) do lo, hi = math.min(lo, y), math.max(hi, y) end
    T.between(hi - lo, 0, 1.5, "sideways sway of the camera while the bike rocks +-20 degrees, units")
end)

T.test("calm camera: a bump is eased into, not copied", function()
    local s = scene()
    local E = s.cl.env
    local base = s.cb:GetPos()
    for _ = 1, 30 do
        s.world.time = s.world.time + s.world.dt
        chase(s, E)
    end
    local before = chase(s, E).origin.z
    s.cb:SetPos(base + E.Vector(0, 0, 5))           -- over a 5-unit bump
    s.world.time = s.world.time + s.world.dt
    local first = chase(s, E).origin.z - before
    local after = 0
    for _ = 1, 40 do
        s.world.time = s.world.time + s.world.dt
        after = chase(s, E).origin.z - before
    end
    T.between(first, 0, 1.2, "the view's rise on the first frame of a 5-unit bump, units")
    T.between(after, 4.5, 5.5, "and it has followed the bike up within 0.6 s, units")
end)

--------------------------------------------------------------------------
-- THE CAMERA EASES AFTER THE BIKE'S TURNS AND RAMPS.
--
-- What the engine really hands CalcView: the rider's look COMPOSED with the
-- seat, and the seat is bolted to the bike (yaw -90, see Chassis.seatAngles).
-- The calm-camera tests above passed angles straight in, so they could not
-- see that every turn and ramp went into the view the same frame -- which a
-- rider on the live test server called sharp and jolting (2026-10-07).
--------------------------------------------------------------------------
local SEAT = { p = 0, y = -90, r = 0 }
local LOOK_AHEAD = { p = 10, y = 90, r = 0 }     -- along the bike, a little down

local function pose(s, E, ang)
    s.cb:SetAngles(ang)
    s.cb:GetPod():SetAngles(s.cb:LocalToWorldAngles(E.Angle(SEAT.p, SEAT.y, SEAT.r)))
end

local function frame(s, E, look, dt)
    s.world.time = s.world.time + (dt or s.world.dt)
    local l = look or LOOK_AHEAD
    local world = s.cb:GetPod():LocalToWorldAngles(E.Angle(l.p, l.y, l.r))
    return E.hook.Run("CalcView", s.me, E.Vector(), world, 90)
end

local function camYaw(v) return v.angles.y end

local function settled(s, E, ang)
    pose(s, E, ang)
    local v
    for _ = 1, 120 do v = frame(s, E) end
    return v
end

T.test("eased camera: a bike riding straight is looked along, as before", function()
    local s = scene()
    local E = s.cl.env
    local v = settled(s, E, E.Angle(0, 30, 0))
    T.near(math.AngleDifference(camYaw(v), 30), 0, 0.5, "camera faces the way the bike goes")
    T.near(v.angles.p, 10, 0.5, "with the rider's own downward look")
end)

T.test("eased camera: a sudden 45-degree turn of the bike is eased into, not copied", function()
    local s = scene()
    local E = s.cl.env
    settled(s, E, E.Angle(0, 0, 0))
    pose(s, E, E.Angle(0, 45, 0))
    local first = camYaw(frame(s, E))
    T.between(math.abs(math.AngleDifference(first, 0)), 0, 8, "the first frame moves only a little, degrees")
    local v
    for _ = 1, 66 do v = frame(s, E) end           -- one second
    T.near(math.AngleDifference(camYaw(v), 45), 0, 1.5, "and within a second it has followed")
end)

T.test("eased camera: following a turn does not overshoot it", function()
    local s = scene()
    local E = s.cl.env
    settled(s, E, E.Angle(0, 0, 0))
    pose(s, E, E.Angle(0, 60, 0))
    local most = 0
    for _ = 1, 200 do most = math.max(most, math.AngleDifference(camYaw(frame(s, E)), 0)) end
    T.between(most, 0, 60.5, "never swings past the bike, degrees")
end)

T.test("eased camera: in a hard 120 deg/s carve it trails smoothly, by a bounded amount", function()
    local s = scene()
    local E = s.cl.env
    settled(s, E, E.Angle(0, 0, 0))
    local yaw, last, worstStep, lag = 0, nil, 0, 0
    for _ = 1, 200 do
        yaw = yaw + 120 * s.world.dt
        pose(s, E, E.Angle(0, yaw, 0))
        local c = camYaw(frame(s, E))
        if last then worstStep = math.max(worstStep, math.abs(math.AngleDifference(c, last))) end
        last = c
        lag = math.abs(math.AngleDifference(yaw, c))
    end
    T.between(lag, 5, 30, "steady lag behind the carve, degrees")
    T.between(worstStep, 0, 120 * s.world.dt * 1.2, "no frame jumps more than the bike turns")
end)

T.test("eased camera: it never trails the bike by more than its cap", function()
    local s = scene()
    local E = s.cl.env
    settled(s, E, E.Angle(0, 0, 0))
    pose(s, E, E.Angle(0, 170, 0))                 -- spun round in one tick
    local v = frame(s, E)
    T.between(math.abs(math.AngleDifference(camYaw(v), 170)), 0, 60.01, "lag capped at 60 degrees")
end)

T.test("eased camera: the foot of a ramp tilts the view a little, gently", function()
    local s = scene()
    local E = s.cl.env
    settled(s, E, E.Angle(0, 0, 0))
    pose(s, E, E.Angle(-40, 0, 0))                 -- nose up 40 degrees, at once
    local first = frame(s, E).angles.p
    T.between(math.abs(first - 10), 0, 2, "the first frame barely tilts, degrees")
    local v
    for _ = 1, 120 do v = frame(s, E) end
    -- Settled: the rider's 10 down, less 35% of the bike's 40 up = -4.
    T.near(v.angles.p, 10 - 40 * 0.35, 1, "settles on a share of the slope, not all of it")
end)

T.test("eased camera: the bike leaning does not tip or swing the view", function()
    local s = scene()
    local E = s.cl.env
    local base = settled(s, E, E.Angle(0, 0, 0))
    local v = settled(s, E, E.Angle(0, 0, 30))
    T.near(math.AngleDifference(camYaw(v), camYaw(base)), 0, 0.5, "lean does not turn the view")
    T.near(v.angles.p, base.angles.p, 0.5, "or pitch it")
end)

T.test("eased camera: the mouse still moves the view on the frame it moves", function()
    local s = scene()
    local E = s.cl.env
    settled(s, E, E.Angle(0, 0, 0))
    local v = frame(s, E, { p = 10, y = 120, r = 0 })      -- looked 30 degrees left
    T.near(math.AngleDifference(camYaw(v), 30), 0, 0.5, "the full 30 degrees, at once")
    v = frame(s, E, { p = -20, y = 90, r = 0 })            -- and up
    T.near(v.angles.p, -20, 0.5, "pitch from the mouse, at once")
end)

T.test("eased camera: bmx_cam_smooth 0 is the old camera, bolted to the bike", function()
    local s = scene()
    local E = s.cl.env
    E.GetConVar("bmx_cam_smooth"):SetString("0")
    settled(s, E, E.Angle(0, 0, 0))
    pose(s, E, E.Angle(0, 45, 0))
    T.near(math.AngleDifference(camYaw(frame(s, E)), 45), 0, 0.5, "follows the turn the same frame")
end)

T.test("eased camera: getting on a bike facing anywhere starts behind it, without a swing", function()
    local s = scene()
    local E = s.cl.env
    pose(s, E, E.Angle(0, 135, 0))
    local v = frame(s, E)
    T.near(math.AngleDifference(camYaw(v), 135), 0, 0.5, "seeded on mount")
end)

T.test("eased camera: the chase position follows the eased view, and stays out of the bike", function()
    local s = scene()
    local E = s.cl.env
    local v = settled(s, E, E.Angle(0, 0, 0))
    local back = s.cb:GetPos() - v.origin
    T.ok(back.x > 50, "the camera is behind the bike: " .. tostring(back))
    T.between(math.abs(back.y), 0, 1, "and on its line")
end)
