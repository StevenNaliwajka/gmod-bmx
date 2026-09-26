--[[--------------------------------------------------------------------------
    The pure pieces, one at a time: maths helpers, the wheel's contact
    geometry, one wheel substep in isolation, and trick scoring.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local V = require("lib.vecang").Vector

local function realm()
    local sv = F.server()
    return sv.env.BMX, sv.env, sv
end

T.test("Clamp and Ramp, including the degenerate range", function()
    local B = realm()
    T.eq(B.Clamp(5, 0, 1), 1, "clamp high")
    T.eq(B.Clamp(-5, 0, 1), 0, "clamp low")
    T.eq(B.Ramp(50, 0, 100), 0.5, "ramp middle")
    T.eq(B.Ramp(-1, 0, 100), 0, "ramp below")
    T.eq(B.Ramp(200, 0, 100), 1, "ramp above")
    T.eq(B.Ramp(5, 10, 10), 0, "lo == hi, below")
    T.eq(B.Ramp(10, 10, 10), 1, "lo == hi, at")
end)

T.test("ProjectPerp refuses the parallel case instead of making a NaN", function()
    local B, E = realm()
    T.eq(B.ProjectPerp(E.Vector(0, 0, 5), E.Vector(0, 0, 1)), nil, "parallel")
    local p = B.ProjectPerp(E.Vector(1, 0, 1), E.Vector(0, 0, 1))
    T.near(p.x, 1, 1e-12, "perpendicular part, normalised")
end)

T.test("Attitude: roll right is positive, nose up is positive", function()
    local B, E, sv = realm()
    local e = sv.makeEntity("thing")
    e:SetAngles(E.Angle(0, 37, 20))         -- Source roll +20: right side down
    local roll, pitch = B.Attitude(e)
    T.near(math.deg(roll), 20, 1e-6, "roll")
    T.near(pitch, 0, 1e-9, "no pitch")
    e:SetAngles(E.Angle(-15, 37, 0))        -- Source pitch -15: nose UP
    roll, pitch = B.Attitude(e)
    T.near(math.deg(pitch), 15, 1e-6, "pitch is the addon's nose-up convention")
    T.near(roll, 0, 1e-9, "no roll")
end)

T.test("Attitude against a banked ground normal measures lean off the bank", function()
    local B, E, sv = realm()
    local e = sv.makeEntity("thing")
    e:SetAngles(E.Angle(0, 0, 30))
    local bank = E.Angle(0, 0, 30):Up()
    local roll = B.Attitude(e, bank)
    T.near(roll, 0, 1e-9, "a bike square to a 30-degree bank is upright on it")
end)

T.test("ApplyTorque is a pure couple: no net linear impulse, the asked-for spin", function()
    local B, E, sv = realm()
    local e = sv.makeEntity("thing")
    e:SetAngles(E.Angle(0, 20, 10))
    e:PhysicsInitBox(E.Vector(-18, -4, 2), E.Vector(14, 4, 38))
    local p = e:GetPhysicsObject()
    p:SetMass(86)
    B.CacheInertia(e, p)
    local I = B.IRoll(e)
    B.ApplyTorque(p, e, e:GetForward(), I * 3 / 0.015, 0.015)
    T.near(p:GetVelocity():Length(), 0, 1e-9, "no linear velocity")
    T.near(p.w:Dot(e:GetForward()), 3, 1e-6, "3 rad/s about the axis asked for")
    T.near(p.w:Dot(e:GetUp()), 0, 1e-6, "and nothing about the others")
end)

T.test("CacheInertia converts VPhysics' metres to units, and falls back loudly", function()
    local B, E, sv = realm()
    local e = sv.makeEntity("thing")
    e:PhysicsInitBox(E.Vector(-18, -4, 2), E.Vector(14, 4, 38))
    local p = e:GetPhysicsObject()
    p:SetMass(86)
    local I, measured = B.CacheInertia(e, p)
    T.ok(measured, "measured")
    T.near(I.x, 9299, 1, "roll inertia in kg*u^2")
    p.GetInertia = function() return E.Vector(0, 0, 0) end
    local J, m2 = B.CacheInertia(e, p)
    T.ok(not m2, "a zero inertia is not believed")
    T.eq(J.x, B.Config.Chassis.inertiaRoll, "the config estimate is used instead")
end)

T.test("DiscContact: level, it is exactly the ray", function()
    local B, E = realm()
    local s, c = B.DiscContact(E.Vector(0, 0, 13), E.Vector(0, 0, -1), E.Vector(0, -1, 0),
        13, E.Vector(0, 0, 1), 10)
    T.near(s, 3, 1e-9, "axle 3 down the strut, 10 above the ground")
    T.near(c.z, 0, 1e-9, "contact on the ground")
    T.near(c.x, 0, 1e-9, "directly below the mount")
end)

T.test("DiscContact: leaning, the contact stays IN the wheel's plane", function()
    local B, E = realm()
    local a = E.Angle(0, 0, 30)
    local f, r, u = a:Forward(), a:Right(), a:Up()
    local mount = u * 13
    -- Where the strut meets the ground: the mount's height over the cosine
    -- of the strut's tilt.
    local dist = mount.z / math.cos(math.rad(30))
    local s, c = B.DiscContact(mount, -u, r, dist, E.Vector(0, 0, 1), 10)
    T.near(s, dist - 10, 1e-9, "same as the ray under pure roll")
    T.near(c.z, 0, 1e-9, "on the ground")
    T.near((c - (mount - u * dist)):Length(), 0, 1e-9, "at the ray's hit: the tyre's edge")
end)

T.test("DiscContact: pitched, the contact is BELOW the axle, not along the ray", function()
    local B, E = realm()
    local th = math.rad(35)
    local a = E.Angle(-35, 0, 0)            -- nose up 35
    local f, r, u = a:Forward(), a:Right(), a:Up()
    local mount = E.Vector(0, 0, 20)
    local dist = 20 / math.cos(th)
    local s, c = B.DiscContact(mount, -u, r, dist, E.Vector(0, 0, 1), 10)
    local axle = mount - u * s
    T.near(axle.z, 10, 1e-9, "the axle is one radius up")
    T.near(c.x, axle.x, 1e-9, "the contact is directly below it")
    local rayHit = mount - u * dist
    T.near(math.abs(rayHit.x - c.x), 10 * math.sin(th) / math.cos(th) + 0, 3,
        "and several units from where the ray hit, which is the error this fixes")
end)

T.test("DiscContact refuses a wall it cannot stand on", function()
    local B, E = realm()
    T.eq(B.DiscContact(E.Vector(), E.Vector(0, 0, -1), E.Vector(0, -1, 0), 5,
        E.Vector(1, 0, 0), 10), nil, "ground normal square to the strut")
end)

-- One wheel against a stubbed body, to see its forces without the plant.
local function wheelRig(opts)
    opts = opts or {}
    local B, E, sv = realm()
    local e = sv.makeEntity("thing")
    e:SetPos(E.Vector(0, 0, opts.z or 7.2))
    e:SetAngles(opts.ang or E.Angle(0, 0, 0))
    e:PhysicsInitBox(E.Vector(-18, -4, 2), E.Vector(14, 4, 38))
    local p = e:GetPhysicsObject()
    p:SetMass(86)
    B.CacheInertia(e, p)
    p:SetVelocity(opts.vel or E.Vector())
    local applied = {}
    p.ApplyForceOffset = function(self, J, at) applied[#applied + 1] = { J = J, at = at } end
    local w = B.NewWheel(E.Vector(-19.5, 0, 6), false)
    w.omega = opts.omega or 0
    return B, E, e, p, w, applied
end

T.test("Wheel: at rest it pushes up with spring force and nothing else", function()
    local B, E, e, p, w, applied = wheelRig()
    w:Simulate(e, p, B.Config, 1 / 66, 0, 0, { e })
    T.ok(w.onGround, "on the ground")
    local C = B.Config.Wheel
    T.near(w.load, C.spring * w.compression, 1, "N = k*x with no motion")
    T.eq(#applied, 1, "one impulse")
    T.near(applied[1].J.x, 0, 1e-6, "no longitudinal force")
    T.near(applied[1].J.z, w.load / 66, 1e-6, "normal impulse = N*dt")
end)

T.test("Wheel: out of reach it is airborne and applies nothing", function()
    local B, E, e, p, w, applied = wheelRig({ z = 40 })
    w:Simulate(e, p, B.Config, 1 / 66, 0, 0, { e })
    T.ok(not w.onGround, "airborne")
    T.eq(#applied, 0, "no force")
    T.eq(w.load, 0, "no load")
end)

T.test("Wheel: drive torque on the ground hooks up rather than spinning up", function()
    local B, E, e, p, w, applied = wheelRig()
    w:Simulate(e, p, B.Config, 1 / 66, 40000, 0, { e })
    T.ok(applied[1].J.x > 0, "a forward push")
    T.ok(w.omega * 10 < 20, "the tyre hooked up: rim speed stayed small, not spun out")
end)

T.test("Wheel: a locked wheel skids on the friction circle, never beyond it", function()
    local B, E, e, p, w, applied = wheelRig({ vel = V(250, 0, 0), omega = 25 })
    w:Simulate(e, p, B.Config, 1 / 66, 0, 1e7, { e })
    T.eq(w.omega, 0, "locked")
    T.near(w.saturation, 1, 1e-9, "saturated")
    local J = applied[1].J * 66
    local tangential = math.sqrt(J.x * J.x + J.y * J.y)
    local limit = B.Config.Wheel.grip * w.load + B.Config.Wheel.rollingResistance * w.load
    T.ok(tangential <= limit + 1e-6, "friction force within grip*N (+ rolling resistance)")
    T.ok(J.x < 0, "and it opposes the motion")
end)

T.test("Wheel: tyre force never exceeds grip*N, over a sweep of states", function()
    math.randomseed(42)
    for i = 1, 400 do
        local B, E = realm()
        local vel = E.Vector(math.random(-300, 300), math.random(-150, 150), math.random(-50, 20))
        local _, _, e, p, w, applied = wheelRig({ vel = vel, omega = math.random(-40, 40),
            z = 5 + math.random() * 4 })
        local drive = math.random() < 0.5 and math.random(0, 150000) or 0
        local brake = math.random() < 0.3 and math.random(0, 200000) or 0
        w:Simulate(e, p, B.Config, 1 / 66, drive, brake, { e })
        if #applied > 0 then
            local J = applied[1].J * 66
            T.finite(J, "force at sample " .. i)
            local t = math.sqrt(J.x * J.x + J.y * J.y)
            local cap = (B.Config.Wheel.grip + B.Config.Wheel.rollingResistance) * w.load
            T.ok(t <= cap + 1e-3, string.format("sample %d: %.0f > %.0f", i, t, cap))
        end
    end
end)

T.test("Wheel: the damper never reverses the approach it is damping", function()
    -- The bug this cap exists for pumped the suspension until the bike was
    -- thrown into the sky: an explicit damper applied for a whole substep can
    -- overshoot, reverse the approach and add energy. So with an ABSURD damping
    -- coefficient, the damper's share of the impulse must change the contact
    -- point's approach speed by exactly the approach speed: nulled, not reversed.
    local function impulse(damper)
        local B, E, e, p, w, applied = wheelRig({ z = 5, vel = V(0, 0, -60) })
        local saved = B.Config.Wheel.damper
        B.Config.Wheel.damper = damper
        w:Simulate(e, p, B.Config, 1 / 66, 0, 0, { e })
        B.Config.Wheel.damper = saved
        return applied[1], p, E
    end
    local undamped = impulse(0)
    local damped, p, E = impulse(1e7)
    local dJ = (damped.J - undamped.J).z
    local r  = damped.at - p:COM()
    local n  = E.Vector(0, 0, 1)
    local rn = r:Cross(n)
    local mEff = 1 / (1 / p:GetMass() + rn:Dot(p:invI(rn)))
    T.near(dJ / mEff, 60, 0.01, "change in the contact's approach speed from the damper")
end)

T.test("ScoreAir: a full backflip, a front flip, a barrel roll and air time", function()
    local B = realm()
    local TAU = math.pi * 2
    local out = B.ScoreAir({ spinPitch = TAU * 1.1, spinRoll = 0, spinYaw = 0, airTime = 0.5 })
    T.eq(#out, 1, "one trick")
    T.eq(out[1].name, "Backflip", "nose-up rotation is a backflip")
    out = B.ScoreAir({ spinPitch = -TAU * 2.2, airTime = 0.5 })
    T.eq(out[1].name, "Frontflip", "nose-down is a front flip")
    T.eq(out[1].count, 2, "two of them")
    T.eq(out[1].points, 1000, "500 each")
    out = B.ScoreAir({ spinRoll = TAU * 1.05, airTime = 0.5 })
    T.eq(out[1].name, "Barrel Roll", "roll")
    out = B.ScoreAir({ spinPitch = TAU * 0.9, airTime = 0.5 })
    T.eq(#out, 0, "nine tenths of a flip is not a flip")
    out = B.ScoreAir({ airTime = 2 })
    T.eq(out[1].name, "Air Time", "air time on its own")
    T.eq(out[1].points, 240, "120 per second")
    T.eq(#B.ScoreAir({ airTime = 1.0 }), 0, "a hop's air time is not a trick")
end)

-- Drive TrackManual through a sequence of (frontDown, rearDown, speed, seconds).
local function manual(steps)
    local B, E = realm()
    local st, cfg = {}, B.Config
    local f, r = { onGround = true }, { onGround = true }
    local paid = {}
    local dt = 1 / 66
    for _, s in ipairs(steps) do
        f.onGround, r.onGround = s[1], s[2]
        for _ = 1, math.floor(s[4] / dt + 0.5) do
            local t = B.TrackManual(st, cfg, f, r, s[3], dt)
            if t then paid[#paid + 1] = t[1] end
        end
    end
    return paid, B.Config.Tricks
end

T.test("TrackManual: a wheelie held past the minimum pays by the second", function()
    local paid, K = manual({ { false, true, 150, 2.0 }, { true, true, 150, 0.5 } })
    T.eq(#paid, 1, "one payout")
    T.eq(paid[1].name, "Wheelie", "named")
    T.near(paid[1].held, 2.0, 0.05, "held")
    T.near(paid[1].points, 2.0 * K.wheeliePerSec, K.wheeliePerSec * 0.05, "points")
end)

T.test("TrackManual: too short, too slow, or riderless-looking does not pay", function()
    T.eq(#manual({ { false, true, 150, 0.6 }, { true, true, 150, 0.5 } }), 0, "a hop's lift")
    T.eq(#manual({ { false, true, 10, 3 }, { true, true, 10, 0.5 } }), 0, "at a standstill")
end)

T.test("TrackManual: a one-substep bounce does not end a wheelie", function()
    local paid = manual({
        { false, true, 150, 0.8 },
        { false, false, 150, 1 / 66 },      -- rear unloads for a tick
        { false, true, 150, 0.8 },
        { true, true, 150, 0.5 },
    })
    T.eq(#paid, 1, "one wheelie, not two short ones")
    T.near(paid[1].held, 1.6, 0.05, "the whole of it")
end)

T.test("TrackManual: a stoppie keeps counting down to a standstill", function()
    local paid, K = manual({
        { true, false, 180, 0.2 },
        { true, false, 12, 0.4 },          -- below the START speed, still going
        { true, true, 0, 0.5 },
    })
    T.eq(#paid, 1, "paid")
    T.eq(paid[1].name, "Stoppie", "named")
    T.near(paid[1].held, 0.6, 0.05, "including the slow half")
end)

T.test("TrackManual: wheelie straight into stoppie is two tricks", function()
    local paid = manual({
        { false, true, 150, 1.5 },
        { true, false, 150, 0.6 },
        { true, true, 150, 0.5 },
    })
    T.eq(#paid, 2, "both")
    T.eq(paid[1].name, "Wheelie", "first")
    T.eq(paid[2].name, "Stoppie", "second")
end)
