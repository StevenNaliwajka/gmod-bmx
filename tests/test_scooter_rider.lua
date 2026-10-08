--[[--------------------------------------------------------------------------
    The kick scooter's rider (cl_scooter.lua): where the feet and the hands are
    told to go, checked against the scooter they stand on and hold.

    A person on a client says whether it looks right. This pins the geometry: the
    standing foot stays on the deck through a kick, the kicking foot steps off the
    deck's edge (not through it), is flat on the ground beside it for the whole
    stroke and sweeps back past the rear wheel, the hands are on the grips however
    the bars are steered, and they let go of a spinning bar and take it again.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local function scene()
    local sv, world = F.server()
    local cl = F.client(world)
    local E = cl.env
    local ent = cl:clientEntity("bmx_scooter")
    ent:SetPos(E.Vector(0, 0, 3))          -- the scooter's origin is 3 over the ground at rest
    ent:SetGrounded(true)
    ent:SetPushPhase(-1)
    cl.localPlayer = sv:player("Looker")
    return cl, ent, E, E.BMX.Scooter, E.BMX.Board
end

local function draw(cl, ent)
    cl.lines, cl.beams, cl.drawnModels, cl.boxes3d = 0, {}, 0, 0
    ent:Draw()
    return ent.ikTargets
end

T.test("scooter kick: the standing foot stays on the deck; the kicking foot steps off its edge, is flat on the ground beside it for the stroke, sweeps back past the rear wheel and comes home over it", function()
    local _, _, E, SC, B = scene()
    local T0 = SC.Tune
    local half = 14
    local g = SC.KickGeo(5, half)
    local F0 = SC.Frame(half)
    local a, b, c = B.PushMarks(g)
    T.ok(b >= g.share, "down for the whole stroke the server pushes in")
    local prev, prevX, planted, lastX
    for i = 0, 500 do
        local p = i / 500
        local t = SC.RiderTargets({ push = p, geo = g }, F0)
        local f, s = t.rFoot, t.lFoot
        T.near(s.z, T0.deckTop + B.Ankle, 1e-9, "the standing foot on the deck at " .. p)
        T.ok(s.x < T0.deckFront and s.x > T0.deckBack, "...and over it")
        T.ok(f.z >= g.ground - 1e-6, "never under the ground at " .. p)
        if math.abs(f.y) < g.deckHalf + 1.6 then
            T.ok(f.z >= g.stand - 0.05, "never through the deck at " .. p .. ": y " .. f.y .. " z " .. f.z)
        end
        if f.x < -half + 6 and math.abs(f.y) < 2.5 then
            T.ok(f.z > 5 + 1.6, "never through the rear wheel or its fender at " .. p)
        end
        if prev then T.ok((f - prev):Length() < 1.2, "no jump at " .. p .. ": " .. (f - prev):Length()) end
        if p >= a and p <= b then
            T.near(f.z, g.ground, 1e-6, "flat on the ground through the stroke at " .. p)
            T.ok(f.y < -(g.deckHalf + 2), "beside the deck, on the right: " .. f.y)
            if prevX then T.ok(f.x <= prevX + 1e-9, "sweeping back at " .. p) end
            prevX = f.x
            planted = planted or f
        end
        prev = f
    end
    T.ok(prevX < -half, "swept back past the rear axle: " .. prevX)
    T.ok(planted.x > T0.footBack, "planted ahead of where it stood: " .. planted.x)
    local home = SC.RiderTargets({ push = -1, geo = g }, F0).rFoot
    T.near((prev - home):Length(), 0, 1e-9, "home on the deck with the cycle")
    T.ok(B.PushBend((a + b) / 2, g) > 0.8, "the standing knee folds as the other foot reaches down")
    T.ok(SC.BodyDrop({ pushBend = 1 }) > SC.BodyDrop({}) + 6, "the pelvis goes well down for it")
end)

T.test("scooter draw: mid-kick the foot is on the ground in the world, an ankle over it, beside the deck", function()
    local cl, ent, E, SC, B = scene()
    local ik0 = draw(cl, ent)
    ent:SetPushPhase(0.3)
    local ik = draw(cl, ent)
    -- At rest the axles stand the static sag over the origin and one radius over the
    -- ground; the scene puts the origin at 3, which is that to within a tenth.
    T.near(ik.rFoot.z, B.Ankle, 0.1, "the kicking foot's ankle an ankle over the ground (z = 0): " .. ik.rFoot.z)
    T.ok(ik.rFoot.y < -4.5, "on the right of the deck: " .. ik.rFoot.y)
    T.near((ik.lFoot - ik0.lFoot):Length(), 0, 1e-9, "the standing foot did not move")
    local C = ent:Cfg()
    local sag = C.Chassis.mass * E.physenv.GetGravity():Length() * 0.5 / C.Wheel.spring
    T.near(ik0.lFoot.z - 3 - sag, SC.Tune.deckTop + B.Ankle, 1e-6,
        "standing on the deck: an ankle over its grip (the origin is 3 up, the axles the sag over it)")
    ent:SetGrounded(false)
    local air = draw(cl, ent)
    T.near((air.rFoot - ik0.rFoot):Length(), 0, 1e-9, "no kicking in the air: the foot is on the deck")
end)

T.test("scooter hands: on the grips however the bars are steered, the left hand on the left", function()
    local cl, ent, E, SC = scene()
    local T0 = SC.Tune
    local F0 = SC.Frame(14)
    for _, deg in ipairs({ 0, 20, -30, 40 }) do
        ent:SetSteer(math.rad(deg))
        local ik = draw(cl, ent)
        -- Where the grips are, worked out the model's way: the front turned about the
        -- steer axis through the head tube's foot (SC.ModelMaps).
        local steer = E.BMX.VisualSteer(ent:GetSteer(), ent:GetSpeedUPS(), ent:Cfg())
        local C = ent:Cfg()
        local sag = C.Chassis.mass * E.physenv.GetGravity():Length() * 0.5 / C.Wheel.spring
        local function P(v) return ent:LocalToWorld(v + E.Vector(0, 0, sag)) end
        local hb, ht = P(F0.headB), P(F0.headT)
        local ax = (ht - hb):GetNormalized()
        local function front(v)
            local p = P(v) - hb
            local c, s = math.cos(-steer), math.sin(-steer)
            return hb + p * c + ax:Cross(p) * s + ax * (ax:Dot(p) * (1 - c))
        end
        local w = T0.barWidth * 0.5 - 1.8
        local gr = front(F0.bars + E.Vector(0, -w, 0))
        local gl = front(F0.bars + E.Vector(0, w, 0))
        T.ok((ik.rHand - gr):Length() < 1e-6, "steered " .. deg .. ": the right hand on the right grip: " .. (ik.rHand - gr):Length())
        T.ok((ik.lHand - gl):Length() < 1e-6, "steered " .. deg .. ": the left hand on the left grip")
        T.ok(ik.rHandA and ik.rHandB and (ik.rHandB - ik.rHandA):Length() > 3, "a grip's length to hold along")
    end
end)
