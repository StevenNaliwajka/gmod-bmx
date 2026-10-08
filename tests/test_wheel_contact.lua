--[[--------------------------------------------------------------------------
    The wheel's contacts: the stick-slip anchor (G04) and the swept wheel
    (G05, G16).

    Both are tested here two ways. The SOLVERS are run on their own against
    geometry built by hand, which is exact and needs no plant. And the
    anchor is ridden closed-loop on the shim's plant, on a real incline, the
    way the headless cases do it on a real server.

    The plant is a rigid body and does NOT collide with the world's solid boxes
    (a grind positions the bike itself; see World.solids in lib/gmod.lua), so
    it cannot say whether a bike CLIMBS a curb. What it can say is what the
    wheels do about one, because the wheels' forces are all there is: the hull
    passes through the box and the tyre contact either lifts the bike or
    does not. The climbing cases that need VPhysics's hull are in
    lua/bmx/sv_test_cases.lua and are run by the headless suite.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local function drift(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2) end

-- A bike on an incline of `deg` degrees rising toward +x, facing uphill (or
-- down it, with opts.downhill), on the ground, settled.
--
-- THE FRONT BRAKE, NOT THE REAR. The rear brake key is also the paddle-back
-- key: below walking pace it releases the brake and pedals backwards
-- (drivetrain, sv_physics.lua), so at a standstill it can never be what holds
-- a bike. And which wheel holds matters: facing UPHILL the weight sits on the
-- rear, the front's grip budget is mu*N_front, and a front-only hold gives up
-- around 12 degrees; facing downhill the front carries the bike.
local function onSlope(deg, opts)
    local sv, world = F.server({ groundSlope = deg })
    local E = sv.env
    if opts and opts.stiction ~= nil then
        E.GetConVar("bmx_wheel_stiction"):SetInt(opts.stiction)
        E.BMX.ApplyConVars()
    end
    local bike = F.bike(sv)
    local rest = F.restHeight(sv)
    local a = math.rad(deg)
    if opts and opts.downhill then
        F.place(bike, E.Vector(0, 0, rest / math.cos(a)), E.Angle(deg, 180, 0))
    else
        F.place(bike, E.Vector(0, 0, rest / math.cos(a)), E.Angle(-deg, 0, 0))
    end
    local ply
    if not (opts and opts.riderless) then ply = F.scripted(sv, bike) end
    -- The brake is on from the first tick, as a rider would have it: a bike
    -- let go on 10 degrees is doing 100 u/s a second later, and braking THAT
    -- is a skid, which is a different test.
    if opts and opts.brake then F.input(bike, { brakeFront = 1 }) end
    sv:run(1.5)
    return sv, bike, ply, world
end

-- Hold the front brake and measure how far the bike goes in `seconds`.
local function heldDrift(deg, seconds, opts)
    opts = opts or {}
    opts.brake = true
    local sv, bike = onSlope(deg, opts)
    sv:run(1)
    local start = bike:GetPos()
    local peak = 0
    sv:run(seconds, function()
        peak = math.max(peak, bike.st.speed)
        return false
    end)
    return drift(bike:GetPos(), start), sv, bike, peak
end

T.test("anchor: with the front brake held, a bike on 10 degrees does not creep", function()
    local d, sv, bike = heldDrift(10, 10)
    T.between(d, 0, 1, "drift in 10 s, units")
    T.eq(#sv.errors, 0, "no errors: " .. table.concat(sv.errors, " | "))
end)

T.test("anchor: facing uphill on 5, and facing downhill on 20", function()
    T.between((heldDrift(5, 8)), 0, 1.5, "5 degrees uphill: drift in 8 s, units")
    T.between((heldDrift(20, 8, { downhill = true })), 0, 1.5, "20 degrees downhill: drift in 8 s, units")
end)

T.test("anchor: without it, the same bike on the same slope does creep (the control)", function()
    local d = heldDrift(10, 10, { stiction = 0 })
    T.ok(d > 3, string.format("a slip-velocity tyre has no static friction: crept %.2f u", d))
end)

T.test("anchor: it lets go when the slope is steeper than the tyre can hold", function()
    -- grip 1.35 holds up to atan(1.35) = 53 degrees; 60 is past it.
    local d = heldDrift(60, 3)
    T.ok(d > 5, string.format("sliding down 60 degrees, moved %.1f u", d))
end)

T.test("anchor: free rolling is untouched, a bike with no brake rolls down 2 degrees", function()
    local sv, bike = onSlope(2)
    local start = bike:GetPos()
    sv:run(4)
    T.ok(bike:GetPos().x < start.x - 8, string.format("rolled downhill: dx = %.1f",
        bike:GetPos().x - start.x))
    T.ok(bike.st.speed > 15, "and picked up speed: " .. bike.st.speed)
end)

T.test("anchor: parked on its stand on 10 and 20 degrees, it holds", function()
    for _, deg in ipairs({ 10, 20 }) do
        local sv, bike = onSlope(deg, { riderless = true })
        sv:run(2)
        local start = bike:GetPos()
        sv:run(30)
        T.between(drift(bike:GetPos(), start), 0, 1, deg .. " degrees: drift in 30 s, units")
        T.ok(bike.st.onStand, "on the stand")
    end
end)

T.test("anchor: parked, a patch is pinned; ridden and not braked, none is", function()
    local sv, bike = onSlope(10, { riderless = true })
    sv:run(2)
    local f, r = F.wheels(bike)
    -- (On the shim's plant a force is an impulse at once, so the second wheel
    -- reads the first wheel's kick as patch speed and may not stick; on the
    -- engine both read the start of the step. One of them is enough here.)
    T.ok(f.anchor or r.anchor, "a patch is pinned")
    local sv2, bike2 = onSlope(10)
    local f2, r2 = F.wheels(bike2)
    sv2:run(0.5)
    T.ok(not f2.anchor and not r2.anchor, "a ridden bike with no brake rolls")
end)

T.test("anchor: held still, the chassis is quiet (no buzz at rest)", function()
    local sv, bike = onSlope(10, { brake = true })
    sv:run(1.5)
    local sum, n = 0, 0
    sv:run(3, function() sum = sum + bike.st.speed ^ 2; n = n + 1 end)
    T.between(math.sqrt(sum / n), 0, 0.5, "RMS speed while held, u/s")
end)

T.test("anchor: holds at 33 ticks as well as 66", function()
    local sv, world = F.server({ groundSlope = 10, dt = 1 / 33 })
    local E = sv.env
    local bike = F.bike(sv)
    local a = math.rad(10)
    F.place(bike, E.Vector(0, 0, F.restHeight(sv) / math.cos(a)), E.Angle(-10, 0, 0))
    F.scripted(sv, bike)
    F.input(bike, { brakeFront = 1 })
    sv:run(2.5)
    local start = bike:GetPos()
    sv:run(8)
    T.between(drift(bike:GetPos(), start), 0, 1.5, "drift in 8 s at 33 Hz, units")
    T.between(bike.st.speed, 0, 0.8, "and still")
end)

-- A brake-locked tyre sliding slowly settles where its capped slip force equals
-- the slope's pull -- 7 u/s up 10 degrees on a real server, well above stickSpeed --
-- so a braked wheel catches from Wheel.brakeStickSpeed; and while a brake holds a
-- stopped, ridden bike the mass centre's motion is bled off (sv_physics.lua 7d).
T.test("anchor: a braked bike already sliding slowly down a slope is caught and held", function()
    local sv, world = F.server({ groundSlope = 10 })
    local E = sv.env
    local C = E.BMX.Config.Wheel
    T.ok(C.brakeStickSpeed > C.stickSpeed * 5, "a braked wheel catches well above stickSpeed")
    local bike = F.bike(sv)
    local a = math.rad(10)
    F.place(bike, E.Vector(0, 0, F.restHeight(sv) / math.cos(a)), E.Angle(-10, 0, 0))
    F.scripted(sv, bike)
    sv:run(0.3)
    F.input(bike, { brakeFront = 1 })
    -- sliding back down at 12 u/s, past stickSpeed, under brakeStickSpeed
    bike:GetPhysicsObject():SetVelocity(E.Vector(-12 * math.cos(a), 0, -12 * math.sin(a)))
    sv:run(1)
    local held = bike.st.brakeHeld
    local start = bike:GetPos()
    sv:run(5)
    T.ok(held, "the brake hold is on (7d)")
    T.between(drift(bike:GetPos(), start), 0, 1, "drift in the 5 s after, units")
    -- and pedalling lets go of it
    F.input(bike, { throttle = 1 })
    sv:run(0.5)
    T.ok(not bike.st.brakeHeld, "pedalling is not held")
end)

T.test("anchor: it is on by default, the sweep is off, and a braked bike at speed still skids and stops", function()
    local sv = F.server()
    T.eq(sv.env.BMX.Config.Wheel.stiction, 1, "stiction on by default")
    T.eq(sv.env.BMX.Config.Wheel.sweep, 0, "the sweep is off by default")
    local bike = F.bike(sv)
    F.scripted(sv, bike)
    sv:run(0.5)
    T.ok(F.accelerateTo(sv, bike, 230), "got up to speed")
    F.input(bike, { brakeRear = 1 })
    local skidded = false
    local _, rear = F.wheels(bike)
    T.ok(sv:run(8, function()
        if rear.saturation > 0.95 then skidded = true end
        return bike.st.speed < 25
    end), "stopped")
    T.ok(skidded, "by skidding, not by being held")
end)

--------------------------------------------------------------------------
-- THE SWEPT WHEEL, solver only. Geometry is a profile in the x-z plane (a
-- polyline, extruded along y), traced by hand, so the answers are exact and
-- the test needs no engine and no plant.
--------------------------------------------------------------------------

-- A ray against a polyline. Each segment's normal is the one on its upper /
-- front side; the test lays them out so that is the open side.
local function profileTracer(E, pts)
    local V = E.Vector
    return function(a, b)
        local best
        local dx, dz = b.x - a.x, b.z - a.z
        for i = 1, #pts - 1 do
            local p, q = pts[i], pts[i + 1]
            local ex, ez = q[1] - p[1], q[2] - p[2]
            local den = dx * ez - dz * ex
            if math.abs(den) > 1e-9 then
                local t = ((p[1] - a.x) * ez - (p[2] - a.z) * ex) / den
                local u = ((p[1] - a.x) * dz - (p[2] - a.z) * dx) / den
                if t > 0 and t <= 1 and u >= 0 and u <= 1 and (not best or t < best.t) then
                    local l = math.sqrt(ex * ex + ez * ez)
                    best = { t = t, n = V(-ez / l, 0, ex / l) }       -- left of p->q
                end
            end
        end
        if not best then return { Hit = false, Fraction = 1, HitPos = b, HitNormal = V(0, 0, 1) } end
        return { Hit = true, Fraction = best.t, HitPos = a + (b - a) * best.t, HitNormal = best.n }
    end
end

local FLAT = { { -200, 0 }, { 200, 0 } }
local function wedge(deg)         -- flat, then a ramp up from x = 0
    local run = 60
    return { { -200, 0 }, { 0, 0 }, { run, run * math.tan(math.rad(deg)) }, { 200, run * math.tan(math.rad(deg)) } }
end
local function step(h)            -- flat, then a vertical face at x = 0 up to a flat top
    return { { -200, 0 }, { 0, 0 }, { 0, h }, { 200, h } }
end
local function wall()
    return { { -200, 0 }, { 0, 0 }, { 0, 500 } }
end

-- The probe as the wheel fires it (BMX.SweepProbe), against the profile. The
-- floor under the strut is the profile's height at the axle's x, found with
-- a ray, as the wheel finds it.
local function probe(sv, profile, x, z, opts)
    local E, B = sv.env, sv.env.BMX
    opts = opts or {}
    local tracer = profileTracer(E, profile)
    local n = 0
    local trace = function(a, b) n = n + 1; return tracer(a, b) end
    local V = E.Vector
    local centre = V(x, 0, z)
    local down, axle = V(0, 0, -1), V(0, -1, 0)
    local floorPoint, floorNormal = opts.floorPoint, opts.floorNormal
    if opts.noFloor then
        floorPoint, floorNormal = nil, nil
    else
        floorNormal = floorNormal or V(0, 0, 1)
        floorPoint = floorPoint or V(x, 0, 0)
    end
    local c = B.SweepProbe(centre, down, axle, opts.dir or 1, 10, trace, floorPoint,
        floorNormal, opts.hot)
    return c, n
end

T.test("sweep: on flat ground it finds nothing different, and the whole probe is one ray", function()
    local sv = F.server()
    local c, n = probe(sv, FLAT, 0, 7)
    T.eq(c, nil, "no face on flat ground")
    T.eq(n, 1, "just the bumper")
end)

T.test("sweep: the full fan is nine rays, and a resolved contact costs at most one more", function()
    local sv = F.server()
    local _, n = probe(sv, step(4), -6, 7)
    T.between(n, 10, 11, "bumper + nine-ray fan + at most one verification")
    local _, n0 = probe(sv, FLAT, 0, 7, { hot = true })
    T.eq(n0, 9, "hot on flat ground: the fan, found nothing, no verification")
    local _, n1 = probe(sv, FLAT, 0, 7, { noFloor = true })
    T.between(n1, 9, 10, "no floor: the fan at once (and a verification if it found the ground)")
end)

T.test("sweep: at the foot of a 45 degree wedge the tyre's depth into the ramp is found exactly", function()
    local sv = F.server()
    local E = sv.env
    local prof = wedge(45)
    -- Axle at full extension, 7 above the floor. Distance to the ramp plane
    -- z = x is |z - x|/sqrt2; the tyre is inside it by 10 - that.
    local worst = 0
    local seen = 0
    for x = -9, 0, 0.5 do
        local want = 10 - math.abs(7 - x) / math.sqrt(2)
        local c = probe(sv, prof, x, 7)
        if want > 0.4 then
            T.ok(c, "wedge found at x = " .. x)
            seen = seen + 1
            worst = math.max(worst, math.abs(c.depth - want))
            T.near(c.normal.x, -math.sqrt(0.5), 0.05, "ramp normal x at " .. x)
            T.near(c.normal.z,  math.sqrt(0.5), 0.05, "ramp normal z at " .. x)
            -- the contact lies on the ramp
            T.near(c.point.z, c.point.x, 0.05, "contact on the plane z = x at " .. x)
        end
    end
    T.ok(seen > 8, "found over the approach: " .. seen)
    T.between(worst, 0, 0.1, "worst depth error against the analytic one, u")
end)

T.test("sweep: a steeper wedge (60) and a vert-ish quarter (75) are found too", function()
    local sv = F.server()
    for _, deg in ipairs({ 60, 75 }) do
        local prof = wedge(deg)
        local tn = math.tan(math.rad(deg))
        -- plane z = x*tn; distance from (x, 7): |7 - x*tn| / sqrt(1 + tn^2)
        local x = -3
        local want = 10 - math.abs(7 - x * tn) / math.sqrt(1 + tn * tn)
        local c = probe(sv, prof, x, 7, { hot = true })
        T.ok(c, deg .. " degrees found")
        T.near(c.depth, want, 0.15, deg .. " degrees: depth")
        T.near(c.normal.z, math.cos(math.rad(deg)), 0.05, deg .. " degrees: normal.z")
    end
end)

T.test("sweep: a curb's corner pushes back AND up, and the push turns upward as the wheel comes over", function()
    local sv = F.server()
    local prof = step(4)
    local last = -1
    for x = -8, -4, 1 do
        -- corner at (0, 4), axle at (x, 7): distance sqrt(x^2 + 9)
        local D = math.sqrt(x * x + 9)
        local want = 10 - D
        local c = probe(sv, prof, x, 7)
        T.ok(c, "corner found at x = " .. x)
        -- A fan has gaps and a corner lives in them: the nearest ray reads a
        -- little long, so the depth reads a little short (under 1 u at 4 u in).
        T.between(c.depth, want - 1.0, want + 0.2, "depth at x = " .. x)
        T.ok(c.normal.x < -0.3, "pushes back at x = " .. x)
        T.ok(c.normal.z > 0.1, "and up at x = " .. x)
        T.ok(c.normal.z >= last - 0.08, "more upward as it comes over: " .. c.normal.z)
        last = c.normal.z
    end
end)

T.test("sweep: a step too tall to roll onto is a wall of the tyre's own height: pure push back", function()
    local sv = F.server()
    local c = probe(sv, step(16), -8, 7)
    T.ok(c, "found")
    T.near(c.normal.x, -1, 0.05, "normal is horizontal")
    T.near(c.normal.z, 0, 0.1, "no lift")
    T.near(c.depth, 2, 0.3, "two units into it")
end)

T.test("sweep: a wall is found, flat on", function()
    local sv = F.server()
    local c = probe(sv, wall(), -8, 7)
    T.ok(c, "found")
    T.near(c.normal.x, -1, 0.02, "normal faces back")
    T.near(c.depth, 2, 0.2, "depth")
    T.ok(c.plane, "a plane")
end)

T.test("sweep: a face BEHIND the wheel is only looked for when it is rolling backwards", function()
    local sv = F.server()
    -- A wall behind a wheel rolling forwards (x > 0 side, mirrored).
    local behind = { { 0, 500 }, { 0, 0 }, { 200, 0 } }       -- wall faces +x
    local c = probe(sv, behind, 8, 7, { dir = 1 })
    T.eq(c, nil, "rolling forwards: not probed (the lite fan only points ahead)")
    local c2 = probe(sv, behind, 8, 7, { dir = -1 })
    T.ok(c2, "rolling backwards: it is the face ahead")
    T.near(c2.normal.x, 1, 0.05, "and it pushes forwards")
end)

T.test("sweep: ignoring the floor's normal is what keeps the floor from hiding a curb", function()
    local sv = F.server()
    local E, B = sv.env, sv.env.BMX
    local V = E.Vector
    local tracer = profileTracer(E, step(4))
    -- Without `ignore`, the floor (3 deep) out-ranks the first unit of the
    -- curb; with it, the curb is what the fan reports.
    local down, axle = V(0, 0, -1), V(0, -1, 0)
    local all = B.SweepContact(V(-8, 0, 7), down, axle, 1, 10, B.SWEEP_LITE, tracer, nil, nil)
    local curb = B.SweepContact(V(-8, 0, 7), down, axle, 1, 10, B.SWEEP_LITE, tracer, nil, V(0, 0, 1))
    T.ok(all and all.n.z > 0.99, "unfiltered, the best hit is the floor")
    T.ok(curb and curb.n.z < 0.1, "filtered, it is the curb's face")
end)

T.test("sweep: over a convex edge what falls away below the floor's plane is not a face (the wedge's lip)", function()
    local sv = F.server()
    local E, B = sv.env, sv.env.BMX
    local V = E.Vector
    local r2 = math.sqrt(0.5)
    -- A 45 degree face up to a plateau at z = 30 (rides_up_wedge_45), and the
    -- fixie's rear wheel as measured on a real server landing on it just under
    -- the lip: the bike nose up 30 degrees (its strut's `down` tilted
    -- forward), the strut 7.7 u into its travel on the face, so the fan, cast
    -- from full extension, sits inside the face and reaches the plateau past
    -- the lip -- geometry under the plane the tyre is on.
    local prof = { { -200, 0 }, { 0, 0 }, { 30, 30 }, { 200, 30 } }
    local tracer = profileTracer(E, prof)
    local centre = V(23.7, 0, 31.4)
    local down = V(0.5, 0, -0.866)
    local axle = V(0, -1, 0)
    local floorN, floorP = V(-r2, 0, r2), V(28.6, 0, 28.6)
    local c = B.SweepProbe(centre, down, axle, 1, 13.8, tracer, floorP, floorN, true)
    T.eq(c, nil, "nothing beyond the lip is reported")
    -- Filtered on the floor's normal alone (as it was), the plateau read as an
    -- edge with a level normal: a wall under the lip, which stopped the bike
    -- dead and rolled it back down the wedge.
    local raw = B.SweepContact(centre, down, axle, 1, 13.8, B.SWEEP_LITE, tracer, nil, floorN)
    raw = B.SweepContact(centre, down, axle, 1, 13.8, B.SWEEP_EXTRA, tracer, raw, floorN)
    local old = B.SweepResolve(centre, axle, 13.8, tracer, raw)
    T.ok(old and old.normal.z < 0.5 and old.normal.x < -0.8,
        "by the normal alone it was a wall: " .. tostring(old and old.normal.x) .. ", " .. tostring(old and old.normal.z))
    -- And at the FOOT of the face (concave) the face still stands up out of
    -- the floor and is found.
    local foot = probe(sv, prof, -4, 7)
    T.ok(foot and foot.normal.x < -0.5, "the foot of the face is still found")
end)

--------------------------------------------------------------------------
-- THE SWEPT WHEEL on the plant: a bike rolling into a box. The hull passes
-- through the box (the plant does not collide with solids), so what is
-- measured is what the WHEELS do about it, which is all the sweep is.
--------------------------------------------------------------------------
local function rideInto(boxTop, speed, opts)
    opts = opts or {}
    local sv, world = F.server(opts.world)
    local E = sv.env
    E.GetConVar("bmx_wheel_sweep"):SetInt(opts.sweep == false and 0 or 1)
    E.BMX.ApplyConVars()
    local x0 = opts.boxX or 120
    world.solids[#world.solids + 1] = { E.Vector(x0, -300, -1), E.Vector(x0 + (opts.boxLen or 400), 300, boxTop) }
    local bike = F.bike(sv)
    F.scripted(sv, bike)
    sv:run(0.5)
    bike:GetPhysicsObject():SetVelocity(E.Vector(speed, 0, 0))
    return sv, bike, world, x0
end

local function ridden(sv, bike, seconds, throttle)
    local f, r = F.wheels(bike)
    local rec = { maxVz = 0, maxAz = 0, maxRays = 0, minX = 1e9, peakZ = -1e9 }
    local lastVz, lastT = 0, nil
    F.input(bike, { throttle = throttle or 0.35 })
    sv:run(seconds, function()
        local v = bike:GetPhysicsObject():GetVelocity()
        local a = math.abs(v.z - lastVz) / sv.world.dt
        if lastT then rec.maxAz = math.max(rec.maxAz, a) end
        lastVz, lastT = v.z, true
        rec.maxVz = math.max(rec.maxVz, v.z)
        rec.maxRays = math.max(rec.maxRays, f.rays, r.rays)
        rec.peakZ = math.max(rec.peakZ, bike:GetPos().z)
        return false
    end)
    rec.f, rec.r = f, r
    return rec
end

T.test("sweep (plant): the sweep is off by default and the wheels fire one ray", function()
    local sv = F.server()
    local bike = F.bike(sv)
    sv:run(1)
    local f, r = F.wheels(bike)
    T.eq(f.rays, 1, "front: the strut ray only")
    T.eq(r.rays, 1, "rear: the strut ray only")
end)

T.test("sweep (plant): on flat ground it costs two rays a wheel, not nine", function()
    local sv, bike = rideInto(0.5, 0)
    sv.world.solids = {}
    sv:run(1)
    local f, r = F.wheels(bike)
    T.eq(f.rays, 2, "front: strut + bumper")
    T.eq(r.rays, 2, "rear: strut + bumper")
end)

T.test("sweep (plant): 3 mph into a curb of 0.4 of the radius, both wheels climb it", function()
    local sv, bike, _, x0 = rideInto(4, 53)
    local rec = ridden(sv, bike, 4)
    local rest = F.restHeight(sv)
    T.between(bike:GetPos().z, rest + 3, rest + 5, "ride height on the curb's top")
    T.ok(bike:GetPos().x > x0 + 20, "and across it: x = " .. bike:GetPos().x)
    T.ok(rec.f.onGround and rec.r.onGround, "both wheels down")
    T.eq(#sv.errors, 0, "no errors: " .. table.concat(sv.errors, " | "))
end)

T.test("sweep (plant): the fan only goes out near the curb", function()
    local sv, bike = rideInto(4, 53)
    local rec = ridden(sv, bike, 4)
    T.between(rec.maxRays, 10, 12, "peak rays in a substep: strut + bumper + the fan (+ a check)")
    sv:run(1)
    T.eq(rec.f.rays, 2, "and it is back to two a wheel afterwards")
end)

T.test("sweep (plant): over a curb at 10 mph the chassis is not popped upward", function()
    local sv, bike = rideInto(4, 176)
    local rec = ridden(sv, bike, 2, 0.6)
    T.between(rec.maxAz, 0, 3 * 600, "peak vertical acceleration, u/s^2 (3 g = 1800)")
end)

T.test("sweep (plant): a 16 u step stops the front wheel; the bike does not ride up it", function()
    local sv, bike, _, x0 = rideInto(16, 53)
    ridden(sv, bike, 3)
    local f = F.wheels(bike)
    -- The front axle is 19.5 ahead of the origin; the tyre's front is a radius
    -- beyond that. The face is at x0.
    local frontOfTyre = bike:GetPos().x + 19.5 + 10
    T.ok(frontOfTyre < x0 + 5, string.format("the tyre stopped at the face: front of tyre %.1f, face %.1f",
        frontOfTyre, x0))
    T.ok(bike:GetPos().z < F.restHeight(sv) + 6, "and did not climb it: z = " .. bike:GetPos().z)
end)

T.test("sweep (plant): the same bike with the sweep off goes through the curb unhindered", function()
    local sv, bike, _, x0 = rideInto(16, 53, { sweep = false })
    ridden(sv, bike, 3)
    T.ok(bike:GetPos().x > x0 + 40, "the plant has no hull for the box, and the strut ray sees nothing: x = " .. bike:GetPos().x)
end)

-- 3 mph, not 10: the plant has no hull for the wall, and at 10 mph it is the
-- hull that stops a bike in the engine (the wheel's spring alone, 8,600 a unit
-- against 1.3 million of kinetic energy, does not). The tyre's own part is the
-- slow end: not sinking into it, and not climbing it.
T.test("sweep (plant): 3 mph into a wall, the front tyre stops at it and is not driven up it", function()
    local sv, bike, _, x0 = rideInto(80, 53)
    local worstDepth = 0
    local f = F.wheels(bike)
    F.input(bike, { throttle = 1 })
    sv:run(3, function()
        -- how far the tyre's front has gone past the face
        worstDepth = math.max(worstDepth, bike:GetPos().x + 19.5 + 10 - x0)
        return false
    end)
    -- The spring is the strut: its travel is how far the CHASSIS may go toward a
    -- face (8 u of rider compliance, as against the ground), and the drawn
    -- wheel stays on the surface. So the bound is the travel, not zero.
    local travel = sv.env.BMX.Config.Wheel.restLength
    T.between(worstDepth, 0, travel + 1.5, "deepest the tyre's front went into the wall, u")
    T.ok(bike:GetPos().z < F.restHeight(sv) + 8, "it did not climb: z = " .. bike:GetPos().z)
    T.eq(#sv.errors, 0, "no errors: " .. table.concat(sv.errors, " | "))
end)

for _, id in ipairs({ "cruiser", "mini" }) do
    T.test("sweep (plant): the " .. id .. " climbs a curb of 0.4 of ITS radius", function()
        local sv, world = F.server()
        local E, B = sv.env, sv.env.BMX
        E.GetConVar("bmx_wheel_sweep"):SetInt(1)
        B.ApplyConVars()
        local cfg = B.ConfigFor(B.Bikes[id])
        local h = 0.4 * cfg.Wheel.radius
        world.solids[1] = { E.Vector(120, -300, -1), E.Vector(520, 300, h) }
        local rest = B.RestHeight(cfg)
        local bike = F.bike(sv, B.ClassFor(id), E.Vector(0, 0, world.groundZ + rest))
        F.scripted(sv, bike)
        sv:run(0.5)
        bike:GetPhysicsObject():SetVelocity(E.Vector(53, 0, 0))
        local rec = ridden(sv, bike, 4)
        T.between(bike:GetPos().z, rest + h - 1.2, rest + h + 1.2, id .. ": ride height on the curb's top")
        T.ok(bike:GetPos().x > 160, "across it: x = " .. bike:GetPos().x)
        T.ok(rec.f.onGround and rec.r.onGround, "both wheels down")
    end)
end

T.test("sweep (plant): on a 30 degree floor the fan is on, and the bike still sits on it and rolls down it", function()
    local sv, world = F.server({ groundSlope = 30 })
    local E = sv.env
    E.GetConVar("bmx_wheel_sweep"):SetInt(1)
    E.BMX.ApplyConVars()
    local bike = F.bike(sv)
    local a = math.rad(30)
    F.place(bike, E.Vector(0, 0, F.restHeight(sv) / math.cos(a)), E.Angle(-30, 0, 0))
    F.scripted(sv, bike)
    local f, r = F.wheels(bike)
    local rays, ground, n = 0, 0, 0
    sv:run(2, function()
        rays = math.max(rays, f.rays)
        if f.onGround and r.onGround then ground = ground + 1 end
        n = n + 1
    end)
    T.between(rays, 9, 12, "the fan went out on the steep floor")
    T.ok(ground > n * 0.8, string.format("on both wheels %d of %d substeps", ground, n))
    T.ok(bike:GetPos().x < -5, "and it rolled down: x = " .. bike:GetPos().x)
    T.eq(#sv.errors, 0, "no errors: " .. table.concat(sv.errors, " | "))
end)
