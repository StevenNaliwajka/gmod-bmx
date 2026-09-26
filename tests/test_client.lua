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

T.test("Draw runs to the end and draws both wheels and the fork", function()
    local s = scene()
    s.cl.lines = 0
    s.cb:Draw()
    -- Two rings of 20 segments, four spokes each, and the fork's two lines.
    T.eq(s.cl.lines, 2 * (20 + 4) + 2, "lines drawn")
    T.eq(s.cl.drawnModels, 1, "the frame model is drawn once")
end)

T.test("Draw copes with a bike in the air and a steered front wheel", function()
    local s = scene()
    s.cb:SetPos(s.cb:GetPos() + s.cl.env.Vector(0, 0, 200))
    s.cb:SetSteer(math.rad(25))
    s.cl.lines = 0
    s.cb:Draw()
    T.eq(s.cl.lines, 50, "still draws everything off the ground")
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
