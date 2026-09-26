--[[--------------------------------------------------------------------------
    The simulation, closed-loop, on the shim's plant.

    These mirror the headless cases in lua/bmx/sv_test_cases.lua, on a rigid
    body that is right in kind but is NOT VPhysics. So the bands are the
    headless suite's own (wide), and a disagreement between the two is a
    question to take to a real server, not a verdict. What they buy is that
    every commit gets a ride before it reaches one: on a laptop, on GitHub,
    for a contributor with no srcds.

    The plant was checked against the live server's recorded figures before
    any of these were written: ride height 7.2-7.5 u (live 7.3-7.5, designed
    7.0), the full weight carried by the suspension, and a lean to the right
    turning the bike right.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local function ridden(opts)
    local sv, world = F.server(opts)
    local bike = F.bike(sv)
    local ply = F.scripted(sv, bike)
    sv:run(0.5)     -- settle the spawn drop
    return sv, bike, ply, world
end

T.test("rest: settles on both wheels at the designed ride height", function()
    local sv, bike = ridden()
    local f, r = F.wheels(bike)
    local C = sv.env.BMX.Config
    T.ok(f.onGround and r.onGround, "both wheels on the ground")
    local weight = C.Chassis.mass * 600
    T.between((f.load + r.load) / weight, 0.9, 1.1, "supported weight / weight")
    T.between(bike:GetPos().z, F.restHeight(sv) - 1, F.restHeight(sv) + 1, "ride height")
    T.between(f.load / (f.load + r.load), 0.3, 0.6, "front share of the load")
    T.eq(#sv.errors, 0, "no errors: " .. table.concat(sv.errors, " | "))
end)

T.test("parked: a riderless bike stands on its kickstand and stays put", function()
    local sv = F.server()
    local bike = F.bike(sv)
    -- Settle first: tipping 9 degrees onto the stand moves the origin (on the
    -- axle line, well above the tyres) sideways by a unit or so by geometry.
    sv:run(3)
    local start = bike:GetPos()
    sv:run(10)
    local C = bike:Cfg().Stand
    T.near(math.deg(bike.st.roll), math.deg(C.standLean), 2, "leaning onto the stand, deg")
    T.ok(bike.st.onStand, "on the stand")
    local f, r = F.wheels(bike)
    T.ok(f.onGround and r.onGround, "on both wheels")
    local moved = bike:GetPos() - start
    T.between(math.sqrt(moved.x ^ 2 + moved.y ^ 2), 0, 0.3, "drift over 10 s once settled, units")
    T.between(bike.st.speed, 0, 0.5, "and is still")
end)

T.test("parked: a bike knocked flat stays down (a stand does not stand it up)", function()
    local sv = F.server()
    local E = sv.env
    local bike = F.bike(sv)
    sv:run(1)
    F.place(bike, bike:GetPos() + E.Vector(0, 0, 8), E.Angle(0, 0, 80))
    sv:run(3)
    T.ok(math.abs(bike.st.roll) > bike:Cfg().Stand.maxRoll, "still lying down")
end)

T.test("getting on a fallen bike picks it up, facing the way it pointed", function()
    local sv = F.server()
    local E = sv.env
    local bike = F.bike(sv)
    sv:run(1)
    F.place(bike, bike:GetPos() + E.Vector(0, 0, 8), E.Angle(0, 30, 80))
    sv:run(2)
    -- Where it points NOW, lying down: it slides about on its side before
    -- anybody picks it up, and that is the heading a rider would pick up.
    local f = bike:GetForward()
    local lyingYaw = math.deg(math.atan2(f.y, f.x))
    T.ok(math.abs(bike.st.roll) > bike:Cfg().Stand.maxRoll, "it really was lying down")
    F.scripted(sv, bike)
    sv:run(2)
    T.between(math.deg(math.abs(bike.st.roll)), 0, 3, "upright, deg")
    T.near(math.AngleDifference(bike:GetAngles().y, lyingYaw), 0, 4, "same heading as it lay")
    local f, r = F.wheels(bike)
    T.ok(f.onGround and r.onGround, "on its wheels")
    T.between(bike:GetPos().z, F.restHeight(sv) - 1, F.restHeight(sv) + 1, "at ride height")
end)

T.test("ridden at a standstill: the rider's foot holds it up, and A/D lean it a little", function()
    local sv, bike = ridden()
    sv:run(2)
    T.between(math.deg(math.abs(bike.st.roll)), 0, 2, "upright with no input, deg")
    T.ok(not bike.st.onStand, "that is the foot, not the stand")
    F.input(bike, { lean = 1 })
    sv:run(2)
    local want = math.deg(bike:Cfg().Stand.footLean)
    T.between(math.deg(bike.st.roll), want * 0.6, want * 1.3, "D leans it right, deg")
end)

T.test("pulling away from a stop and stopping again stay upright", function()
    local sv, bike = ridden()
    F.input(bike, { throttle = 1 })
    local worst = 0
    sv:run(4, function() worst = math.max(worst, math.abs(bike.st.roll)) end)
    T.between(math.deg(worst), 0, 5, "worst roll pulling away, deg")
    F.input(bike, { brakeFront = 1, pitch = -0.6 })
    sv:run(4)
    T.between(bike.st.speed, 0, 3, "stopped")
    T.between(math.deg(math.abs(bike.st.roll)), 0, 5, "and still upright, deg")
    T.ok(sv.env.IsValid(bike:GetDriver()), "with the rider aboard")
end)

T.test("a riderless bike ignores whatever input it was left with", function()
    local sv = F.server()
    local bike = F.bike(sv)
    F.input(bike, { throttle = 1 })
    bike.input.lean = 1
    sv:run(1)
    T.between(bike.st.speed, 0, 5, "does not ride away on a stale throttle")
end)

T.test("accelerate: top speed is set by cadence, not drag", function()
    local sv, bike = ridden()
    local C = sv.env.BMX.Config
    F.input(bike, { throttle = 1 })
    local last, peak = 0, 0
    sv:run(20, function()
        peak = math.max(peak, bike.st.speed)
        return false
    end)
    T.between(peak, 280, 380, "top speed, u/s")
    T.between(bike.st.cadence / C.Drive.maxCadence, 0.8, 1.02, "cadence / maxCadence at top speed")
    local _, r = F.wheels(bike)
    T.ok(r.onGround, "still driving on the ground")
end)

T.test("sprint is faster and costs stamina; stamina comes back", function()
    local sv, bike = ridden()
    local C = sv.env.BMX.Config
    F.input(bike, { throttle = 1 })
    sv:run(12)
    local cruise = bike.st.speed
    F.input(bike, { throttle = 1, sprint = true })
    sv:run(2)
    T.ok(bike.st.speed > cruise + 20, string.format("sprinting %.0f vs %.0f", bike.st.speed, cruise))
    T.ok(bike.st.stamina < C.Drive.staminaMax - 50, "stamina drains")
    T.ok(sv:run(4, function() return bike.st.stamina <= 1 end), "and runs out")

    -- STILL HOLDING SHIFT. It used to flicker on and off every other tick here,
    -- regenerating past the threshold and spending it again at once.
    local flickered = false
    sv:run(2.5, function()
        if bike.st.sprinting then flickered = true end
        return bike.st.stamina >= C.Drive.staminaRecover
    end)
    T.ok(not flickered, "no sprint at all until staminaRecover is back")
    T.ok(bike.st.stamina > 15, "and it regenerates meanwhile")
    sv:run(0.2)
    T.ok(bike.st.sprinting, "then the sprint comes back")
end)

T.test("tuck is less drag: coasting from speed, a tucked rider keeps more", function()
    local function coast(tuck)
        local sv, bike = ridden()
        F.accelerateTo(sv, bike, 300, 25)
        F.input(bike, { tuck = tuck })
        sv:run(4)
        return bike.st.speed
    end
    local up, tucked = coast(false), coast(true)
    T.ok(tucked > up + 3, string.format("tucked %.1f vs upright %.1f", tucked, up))
end)

T.test("the rear brake locks the wheel, saturates the tyre and stops the bike", function()
    local sv, bike = ridden()
    T.ok(F.accelerateTo(sv, bike, 230), "got up to speed")
    local _, rear = F.wheels(bike)
    F.input(bike, { brakeRear = 1 })
    local locked, sat, skid = false, 0, false
    sv:run(3, function()
        if bike.st.speed > 60 then
            if math.abs(rear.omega) < 1.5 then locked = true end
            sat = math.max(sat, rear.saturation)
            if bike:GetSkidding() then skid = true end
        end
        return bike.st.speed < 25
    end)
    T.ok(locked, "rear wheel locked while moving")
    T.between(sat, 0.95, 1.0, "peak saturation")
    T.ok(skid, "the skid is networked for the client's sound")
    T.ok(sv:run(8, function() return bike.st.speed < 25 end) or bike.st.speed < 25, "stops")
end)

T.test("S at a standstill walks the bike backwards", function()
    local sv, bike = ridden()
    F.input(bike, { brakeRear = 1 })
    sv:run(1.5)
    T.ok(bike.st.fwdSpeed < -3, "paddled backwards: " .. bike.st.fwdSpeed)
end)

-- Lean one way at speed and measure the turn, accumulating yaw so a turn past
-- 180 degrees cannot wrap and flip its sign.
local function sweep(lean)
    local sv, bike = ridden()
    F.accelerateTo(sv, bike, 150)
    local E = sv.env
    local last, total = bike:GetAngles().y, 0
    F.input(bike, { throttle = 0.6, lean = lean })
    sv:run(2.5, function()
        local y = bike:GetAngles().y
        total = total + E.math.AngleDifference(y, last)
        last = y
        return false
    end)
    return { yaw = total, roll = bike.st.roll, steer = bike.st.steer, st = bike.st, sv = sv }
end

T.test("leaning right turns right, and leaning left turns left, symmetrically", function()
    local right, left = sweep(1), sweep(-1)
    T.ok(right.roll > math.rad(8), "right lean is positive roll")
    T.ok(right.steer > 0, "which derives a right steer")
    T.ok(right.yaw < -30, "and turns right (yaw decreases): " .. right.yaw)
    T.ok(left.roll < -math.rad(8), "left lean is negative roll")
    T.ok(left.steer < 0, "a left steer")
    T.ok(left.yaw > 30, "and turns left: " .. left.yaw)
    T.between(math.abs(left.yaw) / math.abs(right.yaw), 0.8, 1.25, "left/right symmetry")
end)

T.test("the balance PD holds a commanded lean within the design's 12 degrees", function()
    local sv, bike = ridden()
    F.accelerateTo(sv, bike, 150)
    F.input(bike, { throttle = 0.7, lean = 0.6 })
    sv:run(2.5)
    local target = 0.6 * sv.env.BMX.Config.Balance.maxLean
    T.between(bike.st.leanAuthority, 0.99, 1.0, "full authority at speed")
    T.between(math.deg(math.abs(target - bike.st.roll)), 0, 12, "|target - roll|, deg")
end)

T.test("hop: a preloaded hop leaves the ground, rises, and comes back down", function()
    local sv, bike = ridden()
    F.accelerateTo(sv, bike, 160)
    F.input(bike, { throttle = 0.5 })
    local z0 = bike:GetPos().z
    bike.hopHeld, bike.hopCharge = true, 0
    sv:run(bike:Cfg().Hop.chargeTime + 0.05)
    bike.hopRelease = true
    local peak = 0
    local f, r = F.wheels(bike)
    local airborne = false
    sv:run(1.6, function()
        peak = math.max(peak, bike:GetPos().z - z0)
        if not f.onGround and not r.onGround then airborne = true end
        return false
    end)
    T.ok(airborne, "both wheels left the ground")
    T.between(peak, 18, 100, "hop height")
    T.ok(bike.st.grounded, "and landed")
    -- The part the headless case never checked. With no pitch input a full
    -- hop used to rotate to 50-57 degrees nose-up and land on the hull.
    T.ok(sv.env.IsValid(bike:GetDriver()), "on its wheels, without a crash")
    T.between(math.deg(bike.st.pitch), -10, 15, "pitch after landing")
end)

T.test("hop: with autolevel off, the nose-up kick is left entirely to the rider", function()
    local sv, bike = ridden()
    sv.env.GetConVar("bmx_autolevel"):SetString("0")
    F.accelerateTo(sv, bike, 160)
    F.input(bike, { throttle = 0.5 })
    bike.hopHeld, bike.hopCharge = true, 0
    sv:run(bike:Cfg().Hop.chargeTime + 0.05)
    bike.hopRelease = true
    local peak = 0
    sv:run(0.8, function() peak = math.max(peak, bike.st.pitch) end)
    T.ok(math.deg(peak) > 35, "purist mode: nothing takes the kick back out, peak " ..
        math.deg(peak))
end)

T.test("hop: holding SPACE longer hops higher, and there is a cooldown", function()
    local function hop(hold)
        local sv, bike = ridden()
        F.accelerateTo(sv, bike, 120)
        F.input(bike, { throttle = 0.3 })
        local z0 = bike:GetPos().z
        bike.hopHeld, bike.hopCharge = true, 0
        sv:run(hold)
        bike.hopRelease = true
        local peak = 0
        sv:run(1.2, function() peak = math.max(peak, bike:GetPos().z - z0) end)
        return peak, sv, bike
    end
    local short, long = hop(0.05), hop(0.5)
    T.ok(long > short * 1.5, string.format("full charge %.0f vs a tap %.0f", long, short))
end)

T.test("wheelie: weight back under power lifts the front and HOLDS it", function()
    local sv, bike = ridden()
    F.accelerateTo(sv, bike, 140)
    F.input(bike, { throttle = 1, pitch = 1 })
    local f, r = F.wheels(bike)
    T.ok(sv:run(4, function() return not f.onGround and r.onGround end), "front lifts")

    -- The hold. The disc-contact fix is what makes this pass on the plant: with
    -- the tyre force applied where the RAY hit rather than below the axle, the
    -- rear spring pushed up behind the axle and levered the bike past its
    -- balance point in about a second.
    local down, n, maxPitch = 0, 0, 0
    sv:run(2.5, function()
        n = n + 1
        if r.onGround then down = down + 1 end
        maxPitch = math.max(maxPitch, bike.st.pitch)
        return false
    end)
    local bal = math.deg(sv.env.BMX.WheelieBalance(bike:Cfg()))
    T.between(down / n * 100, 90, 100, "share of the hold with the rear wheel down, %")
    T.between(math.deg(bike.st.pitch), 10, bal, "wheelie pitch after 2.5 s of full throttle")
    T.ok(math.deg(maxPitch) < bal, "never passed the balance point: " .. math.deg(maxPitch))
end)

T.test("wheelie: releasing brings the front down and pays out by the second", function()
    local sv, bike = ridden()
    F.accelerateTo(sv, bike, 140)
    F.input(bike, { throttle = 1, pitch = 1 })
    local f = F.wheels(bike)
    sv:run(4, function() return not f.onGround end)
    sv:run(2)
    local landed = {}
    sv.env.hook.Add("BMX_TricksLanded", "t", function(b, ply, tricks, total)
        landed[#landed + 1] = { tricks = tricks, total = total }
    end)
    F.input(bike, { throttle = 0.5 })
    sv:run(1.5)
    T.ok(f.onGround, "the front is back down")
    T.eq(#landed, 1, "one payout")
    T.eq(landed[1].tricks[1].name, "Wheelie", "named")
    T.between(landed[1].total, 250, 600, "points for ~2 s of wheelie")
    T.eq(bike:GetScore(), landed[1].total, "added to the bike's score")
end)

T.test("stoppie: the front brake lifts the rear, the hold stops it going over the bars", function()
    local sv, bike = ridden()
    F.accelerateTo(sv, bike, 200)
    F.input(bike, { brakeFront = 1, pitch = -0.6 })
    local f, r = F.wheels(bike)
    local lifted, minPitch = false, 0
    sv:run(2.5, function()
        if f.onGround and not r.onGround then lifted = true end
        minPitch = math.min(minPitch, bike.st.pitch)
        return false
    end)
    T.ok(lifted, "rear wheel came up with the front down")
    T.between(math.deg(minPitch), -45, -8, "deepest stoppie pitch")
    T.ok(sv.env.IsValid(bike:GetDriver()), "still on the bike")
    T.between(bike.st.speed, 0, 30, "and it stopped")
    T.ok(bike:GetScore() > 0, "a held stoppie scores")
end)

T.test("stoppie hold uses the inertia about the FRONT axle", function()
    local sv, bike = ridden()
    local B = sv.env.BMX
    local C = bike:Cfg()
    -- Measure the torque PitchControl applies for a known error, with the
    -- rear up and the front down, by reading the pitch-rate change it causes.
    local f, r = F.wheels(bike)
    f.onGround, r.onGround = true, false
    bike.st.pitch, bike.st.pitchRate = 0, 0
    local p = bike:GetPhysicsObject()
    p:SetVelocity(sv.env.Vector())
    p.w = sv.env.Vector()
    local inp = { pitch = -1 }
    B.PitchControl(bike, p, C, 1 / 66, inp, bike.st, bike.wheels)
    local wPitch = p.w:Dot(bike:GetRight())
    -- alpha = holdKp * (target - 0), target = -stoppieMax * pitch = -40 deg.
    local alpha = C.Pitch.holdKp * (inp.pitch * -C.Pitch.stoppieMax)
    local wantTorque = B.PivotInertia(bike, C, true) * alpha
    local freeBody = B.IPitch(bike) * alpha
    local got = wPitch * B.IPitch(bike) * 66     -- torque the plant felt
    T.near(got, wantTorque, math.abs(wantTorque) * 0.02, "stoppie hold torque")
    T.ok(math.abs(got) > math.abs(freeBody) * 5, "not the free-body figure")
end)

T.test("air: mode engages after the debounce, and nose-up input is a BACKflip", function()
    local sv, bike = ridden()
    F.accelerateTo(sv, bike, 200)
    F.input(bike, { throttle = 0.6 })
    bike.hopHeld, bike.hopCharge = true, 0
    sv:run(0.47)
    bike.hopRelease = true
    T.ok(sv:run(2, function() return bike.st.airMode end), "air mode engages")
    F.input(bike, { pitch = 1 })
    local peak = 0
    sv:run(0.6, function()
        if bike.st.airMode then peak = math.max(peak, bike.st.spinPitch) end
        return not bike.st.airMode
    end)
    T.between(peak, 0.35, 12, "positive spinPitch accumulated (backflip direction)")
end)

T.test("air: a bump does not engage air mode", function()
    local sv, bike = ridden()
    F.accelerateTo(sv, bike, 150)
    -- Two substeps with no contact: shorter than Air.engageDelay.
    local p = bike:GetPhysicsObject()
    p:SetVelocity(p:GetVelocity() + sv.env.Vector(0, 0, 25))
    local engaged = sv:run(0.5, function() return bike.st.airMode end)
    T.ok(not engaged, "a small bump is not a jump")
end)

T.test("crash: an inverted drop throws the rider, hurts them, and plays the crash", function()
    local sv, bike, ply = ridden()
    sv:run(1.2)         -- the grace period is real
    local p = bike:GetPhysicsObject()
    F.place(bike, bike:GetPos() + sv.env.Vector(0, 0, 500), sv.env.Angle(0, 0, 165))
    p:SetVelocity(sv.env.Vector(0, 0, -150))
    local ejected = sv:run(4, function() return not sv.env.IsValid(bike:GetDriver()) end)
    T.ok(ejected, "rider ejected")
    T.ok(not sv.env.IsValid(ply.BMXBike), "and unbound from the bike")
    T.ok((ply._damage or 0) > 0, "and hurt")
    local heard = false
    for _, s in ipairs(sv.sounds) do if s.name:find("metal_box_impact_hard") then heard = true end end
    T.ok(heard, "crash sound played")
end)

T.test("crash: an impact ejects on the NEXT tick, never inside the physics callback", function()
    local sv, bike = ridden()
    sv:run(1.2)
    local crashedIn = nil
    local orig = bike.Crash
    bike.Crash = function(self, ...)
        crashedIn = sv.inCallback and "callback" or "tick"
        return orig(self, ...)
    end
    local cb = bike.PhysicsCollide
    bike.PhysicsCollide = function(self, data, phys)
        sv.inCallback = true
        cb(self, data, phys)
        cb(self, data, phys)        -- one impact reports several contacts
        sv.inCallback = false
    end
    bike:PhysicsCollide({ Speed = 900 }, bike:GetPhysicsObject())
    T.eq(crashedIn, nil, "nothing happened inside the callback")
    sv:run(0.05)
    T.eq(crashedIn, "tick", "the crash ran on the next tick")
    T.ok(not sv.env.IsValid(bike:GetDriver()), "and ejected the rider, once")
end)

T.test("the spawn grace period protects a freshly mounted rider", function()
    local sv, bike = ridden()
    bike.spawnTime = sv.world.time
    bike:PhysicsCollide({ Speed = 900 }, bike:GetPhysicsObject())
    sv:run(0.1)
    T.ok(sv.env.IsValid(bike:GetDriver()), "still aboard inside the grace period")
end)

T.test("the physics step refuses an absurd dt rather than integrating it", function()
    local sv, bike = ridden()
    local p = bike:GetPhysicsObject()
    local before = sv.impulses or 0
    sv.env.BMX.PhysicsStep(bike, p, 0)
    sv.env.BMX.PhysicsStep(bike, p, 3.0)
    T.eq(sv.impulses or 0, before, "no forces applied for dt = 0 or a stalled 3 s")
end)

T.test("fuzz: random riding for a minute never produces a NaN", function()
    local sv, bike = ridden()
    math.randomseed(1234)
    local E = sv.env
    local t = 0
    sv:run(60, function()
        t = t + 1
        if t % 20 == 0 then
            F.input(bike, {
                throttle = math.random(), brakeRear = math.random() < 0.2 and 1 or 0,
                brakeFront = math.random() < 0.1 and 1 or 0,
                lean = math.random() * 2 - 1, pitch = math.random() * 2 - 1,
                tuck = math.random() < 0.3, sprint = math.random() < 0.3,
                wheelieMod = math.random() < 0.3,
            })
            if math.random() < 0.1 then bike.hopHeld, bike.hopCharge = true, 0 end
            if math.random() < 0.1 then bike.hopRelease = true end
        end
        -- Remount if a crash threw the bot off, so the whole minute is ridden.
        if not E.IsValid(bike:GetDriver()) then
            F.place(bike, bike:GetPos() + E.Vector(0, 0, 20), E.Angle(0, bike:GetAngles().y, 0))
            F.scripted(sv, bike)
        end
        local p = bike:GetPhysicsObject()
        T.finite(bike:GetPos(), "position at t=" .. sv.world.time)
        T.finite(p:GetVelocity(), "velocity at t=" .. sv.world.time)
        T.finite(p.w, "angular velocity at t=" .. sv.world.time)
        return false
    end)
    T.eq(#sv.errors, 0, "no errors: " .. table.concat(sv.errors, " | "))
end)

T.test("a fallen bike grips the ground with its frame instead of skating", function()
    local sv = F.server()
    local E = sv.env
    local bike = F.bike(sv)
    sv:run(1)
    local p = bike:GetPhysicsObject()
    -- Down on its side, sliding at a running pace.
    F.place(bike, bike:GetPos() + E.Vector(0, 0, 6), E.Angle(0, 0, 85))
    p:SetVelocity(E.Vector(200, 0, 0))
    local start = bike:GetPos()
    sv:run(2.5)
    T.eq(p.material, bike:Cfg().Chassis.fallenSurfaceProp, "grippy surface while down")
    local slid = (bike:GetPos() - start):Length()
    T.between(slid, 0, 90, "slide distance from 200 u/s, units")
    -- Horizontally: the shim's box-on-ground contact jitters a little in z
    -- (a VPhysics body at rest does not), and that is not the bike sliding.
    local at = bike:GetPos()
    sv:run(1)
    local d = bike:GetPos() - at
    T.between(math.sqrt(d.x * d.x + d.y * d.y), 0, 6, "and has stopped sliding (moved in the next second)")

    -- Stood back up (by getting on), it rides on ice again.
    F.scripted(sv, bike)
    sv:run(0.2)
    T.eq(p.material, bike:Cfg().Chassis.surfaceProp, "back to the ice hull upright")
end)
