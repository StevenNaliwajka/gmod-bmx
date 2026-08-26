--[[--------------------------------------------------------------------------
    bmx/sv_test_cases.lua

    The cases. Each one is a coroutine that gets a context and asserts on the
    simulation's own state.

    A NOTE ON THE BANDS. Every expectation here is a RANGE, not a value, and the
    ranges are wide. That is deliberate. These are regression tests, not a
    specification: their job is to catch "the drivetrain gearing changed by 3x"
    or "leaning right now steers left", not to freeze numbers that
    docs/TUNING.md explicitly expects a human to change. A band tight enough to
    fail on an honest tuning pass is a band that will be deleted rather than
    fixed.

    Where a case asserts a SIGN or a DIRECTION rather than a magnitude, that
    assertion IS the specification and should be tightened, not loosened.
----------------------------------------------------------------------------]]

local T = BMX.Test

--------------------------------------------------------------------------
T.Case("forces", { rider = false, timeout = 15,
    desc = "ApplyForceCenter takes an impulse, which every force here assumes" },
function(ctx)
    -- The single assumption the whole simulation rests on. If this fails, every
    -- other number in the suite is wrong by a factor of the tick interval and
    -- nothing else will say so.
    local test = ents.Create("prop_physics")
    test:SetModel("models/hunter/blocks/cube025x025x025.mdl")
    test:SetPos(ctx.ground + Vector(0, 0, 300))
    test:Spawn()

    local phys = test:GetPhysicsObject()
    if not ctx:ok(IsValid(phys), "test prop has a physics object") then return end

    local mass, want = 100, 100
    phys:SetMass(mass)
    phys:EnableGravity(false)
    phys:EnableDrag(false)
    phys:SetDamping(0, 0)
    phys:SetVelocity(vector_origin)
    phys:Wake()
    phys:ApplyForceCenter(Vector(0, 0, 1) * mass * want)

    ctx:wait(0.25)

    local dv = IsValid(phys) and phys:GetVelocity().z or 0
    ctx:log(string.format("tick %.4fs, gravity %.0f u/s^2",
        engine.TickInterval(), physenv.GetGravity():Length()))
    ctx:between(dv, want * 0.85, want * 1.15, "dv from a mass*100 impulse", "u/s")

    if math.abs(dv - want * engine.TickInterval()) < want * 0.05 then
        ctx:log("^ that is FORCE semantics, not impulse. Every ApplyForce* call")
        ctx:log("  in sv_wheel.lua and sv_physics.lua is multiplied by dt and")
        ctx:log("  must NOT be. Fix that before trusting anything below.")
    end

    SafeRemoveEntity(test)
end)

--------------------------------------------------------------------------
T.Case("torque", { rider = false, timeout = 20,
    desc = "commanding an angular acceleration actually produces it" },
function(ctx)
    -- The rotational twin of `forces`, and it exists because the original
    -- version of this addon got it wrong. Every controller here commands an
    -- angular ACCELERATION and converts with T = I*alpha, so if I is wrong then
    -- every torque is wrong by the same factor and the bike rotates that much
    -- too fast. The invented constants were ~2x the real inertia, which is what
    -- made the balance controller flip the bike.
    --
    -- VPhysics reports inertia in kg*m^2 while this addon works in kg*units^2,
    -- so the conversion is 39.37^2. This asserts the whole chain end to end
    -- rather than the conversion in isolation.
    local probe = ents.Create("bmx_base")
    probe:SetPos(ctx.ground + Vector(0, 0, 260))
    probe:SetAngles(Angle(0, 0, 0))
    probe:Spawn()
    probe:Activate()

    -- Neuter the simulation on this one: PhysicsStep bails out without state,
    -- so nothing but our own impulse acts on it.
    probe.st = nil

    local phys = probe:GetPhysicsObject()
    if not ctx:ok(IsValid(phys), "probe has a physics object") then
        SafeRemoveEntity(probe) return
    end

    phys:EnableGravity(false)
    phys:SetDamping(0, 0)
    phys:SetVelocity(vector_origin)
    phys:Wake()

    ctx:log(string.format("inertia (roll,pitch,yaw) = %.0f, %.0f, %.0f kg*u^2",
        BMX.IRoll(probe), BMX.IPitch(probe), BMX.IYaw(probe)))

    -- Command exactly 2 rad/s^2 about the roll axis for one substep-sized
    -- impulse, so the expected result is a clean 2 * dt rad/s.
    local ALPHA, DT = 2.0, 0.0152
    local r0, t0 = probe:GetAngles().r, CurTime()
    BMX.ApplyTorque(phys, probe, probe:GetForward(),
        BMX.TorqueFor(BMX.IRoll(probe), ALPHA / DT), DT)

    ctx:wait(1.5)

    local elapsed = CurTime() - t0
    local swept = math.rad(math.AngleDifference(probe:GetAngles().r, r0))
    local omega = swept / elapsed

    ctx:log(string.format("swept %.1f deg in %.2fs", math.deg(swept), elapsed))
    -- Commanded alpha/DT for DT seconds is an angular impulse of I*ALPHA, so
    -- the body should end up rotating at ALPHA rad/s.
    ctx:between(math.abs(omega), ALPHA * 0.7, ALPHA * 1.4,
        "resulting omega for a commanded 2.0", "rad/s")

    SafeRemoveEntity(probe)
end)

--------------------------------------------------------------------------
T.Case("rest", { timeout = 15,
    desc = "settles on both wheels at the designed ride height" },
function(ctx)
    -- READ THE SUSPENSION WHILE THE BIKE IS STILL UPRIGHT.
    --
    -- With no speed there is no balance authority, by design -- and that gate is
    -- on SPEED (Balance.fadeInLow), not on whether anyone is aboard, so a
    -- stationary RIDDEN bike topples exactly like a riderless one. It does it
    -- quickly, too: the roll time constant is sqrt(I_roll / m*g*h) = 95 ms, so
    -- it is a good way over inside a second.
    --
    -- This case used to read at a flat 0.75s and call that "early". It was, back
    -- when a tyre bug shook the bike hard enough to keep it moving and therefore
    -- upright. With that fixed, the bike honestly topples, and reading
    -- compression and load off one that is already 27 degrees over measures the
    -- geometry of a falling bike rather than the spring: it reported 0.64 of the
    -- bike's weight supported, with both wheels legitimately on the ground and
    -- the suspension behaving perfectly.
    local UPRIGHT = math.rad(5)
    local t0, snap = CurTime(), nil

    ctx:runUntil(2.5, function()
        -- Skip the spawn transient: the bike is dropped one unit and bounces.
        if CurTime() - t0 < 0.35 then return false end
        if math.abs(ctx:st().roll) > UPRIGHT then return true end

        local f, r = ctx:wheels()
        snap = {
            fg = f.onGround, rg = r.onGround,
            fc = f.compression, rc = r.compression,
            load = f.load + r.load,
            h = ctx.bike:GetPos().z - ctx.ground.z,
            at = CurTime() - t0,
        }
        return false
    end)

    if not ctx:ok(snap ~= nil,
        "the bike was upright and settled at some point in the first 2.5s") then
        return
    end
    ctx:log(string.format("read at t=%.2fs, still within %.0f deg of upright",
        snap.at, math.deg(UPRIGHT)))

    ctx:ok(snap.fg, "front wheel found ground")
    ctx:ok(snap.rg, "rear wheel found ground")

    local WC = BMX.Config.Wheel
    ctx:between(snap.fc, 0.15, WC.restLength, "front compression", "u")
    ctx:between(snap.rc, 0.15, WC.restLength, "rear compression", "u")

    -- Both wheels carrying load, and between them roughly the whole bike.
    local weight = BMX.Config.Chassis.mass * physenv.GetGravity():Length()
    ctx:between(snap.load / weight, 0.75, 1.35, "supported weight / actual weight")

    -- Ride height: the origin sits on the design axle line, so at rest it sits
    -- one wheel radius up MINUS the static sag. Derived from the config rather
    -- than hardcoded, so retuning the spring does not "break" this test.
    local sag = (weight * 0.5) / WC.spring
    ctx:log(string.format("predicted sag %.2f u -> ride height %.2f u",
        sag, WC.radius - sag))
    ctx:between(snap.h, WC.radius - sag - 2, WC.radius - sag + 2, "ride height", "u")

    -- And then it falls over, which is the DESIGN and not a bug. Asserted here
    -- so that someone "fixing" a stationary bike that will not stand up trips a
    -- test rather than shipping a hovering prop. riderless_falls makes the same
    -- claim without a rider; this one is the half people assume is different.
    local fell = ctx:waitUntil(function()
        return math.abs(ctx:st().roll) > math.rad(35)
    end, 4, "the ridden stationary bike to topple")
    ctx:ok(fell, "a RIDDEN bike at a standstill topples too (the assist gate " ..
        "is on speed, not on having a rider)")
end)

--------------------------------------------------------------------------
T.Case("riderless_falls", { rider = false, timeout = 20,
    desc = "an unattended bike tips over, which is the DESIGN not a bug" },
function(ctx)
    -- This asserts intended behaviour, so that someone "fixing" a bike that
    -- will not stand up on its own trips a test instead of shipping a hovering
    -- prop. See sh_config.lua, Balance.fadeInLow.
    ctx:wait(1)

    -- Nudge it, because a perfectly upright bike sits in unstable equilibrium
    -- and could balance there indefinitely in a noiseless simulation. A real
    -- one gets bumped; so does this one.
    local phys = ctx.bike:GetPhysicsObject()
    if IsValid(phys) then
        phys:ApplyForceOffset(ctx.bike:GetRight() * (phys:GetMass() * 12),
            ctx.bike:LocalToWorld(Vector(0, 0, 30)))
    end

    local fell = ctx:waitUntil(function()
        return math.abs(ctx:st().roll) > math.rad(45)
    end, 12, "the bike to tip past 45 degrees")

    ctx:ok(fell, "a riderless bike falls over (no balance authority at rest)")
    ctx:log(string.format("final roll %.0f deg", math.deg(ctx:st().roll)))
end)

--------------------------------------------------------------------------
T.Case("accelerate", { timeout = 25,
    desc = "pedalling reaches a plausible speed, capped by cadence not drag" },
function(ctx)
    -- RUN UNTIL THE SPEED STOPS RISING, not for a fixed number of seconds. A
    -- fixed wait is really a DISTANCE, and the test ground is finite: nine
    -- seconds at terminal speed is about 2,800 units against roughly 1,300 of
    -- runway on gm_flatgrass. The old version of this case rode off the edge at
    -- eight seconds and then reported the speed of a bike falling down a pit --
    -- 453 u/s, comfortably inside the band, from a bike that was not touching
    -- anything.
    local peak, cadence = 0, 0
    local mark, markSpeed = CurTime(), 0
    local start, ranOut = ctx.bike:GetPos(), false

    local grounded = ctx:runUntil(9, function()
        local st = ctx:st()

        -- ONLY WHILE A WHEEL IS ON THE GROUND. runUntil tolerates half a second
        -- of no contact before it gives up, because a bump unloads both wheels
        -- for a substep or two -- and half a second of free fall is 300 u/s of
        -- vertical velocity, which `speed` (a magnitude, not a ground speed)
        -- happily counts. That grace period was quietly feeding the peak: the
        -- case reported 467 u/s while also, correctly, reporting that the bike
        -- had left the ground.
        if st.grounded and st.speed > peak then peak, cadence = st.speed, st.cadence end

        -- Stop before the edge rather than at it. Terminal speed is an
        -- asymptote and chasing the last few u/s costs a lot of ground, so on a
        -- short runway this case reports the best it could actually reach and
        -- says the run was cut short -- which is a far more useful answer than
        -- the speed of a bike falling into a pit.
        if ctx.runway > 0 and ctx.bike:GetPos():Distance(start) > ctx.runway then
            ranOut = true
            return true
        end

        -- Terminal speed is an asymptote, so stop when the approach to it has
        -- gone flat. MEASURED OVER HALF A SECOND, not per tick: the gain
        -- between two consecutive substeps at 66 Hz is 1/66th of the
        -- acceleration, so comparing it against a threshold written in u/s
        -- declares victory at 33 u/s^2 and walks away with the bike still
        -- pulling hard. That stopped the run at 237 u/s of a 312 u/s terminal,
        -- which is inside the speed band and therefore looked fine -- except
        -- the cadence check, which reads the throttle the rider still has left,
        -- failed at exactly the boundary and gave it away.
        if CurTime() - mark >= 0.5 then
            if st.speed - markSpeed < 1 then return true end
            mark, markSpeed = CurTime(), st.speed
        end
        return false
    end, { throttle = 1 })

    -- Said first, because every number below is meaningless without it.
    ctx:ok(grounded, "the bike stayed on the ground for the whole run")

    local cut = ranOut or ctx.stoppedAtEdge
    if cut then
        ctx:log(string.format(
            "run cut short after %.0f units by the edge of the test ground: the " ..
            "speed below is a FLOOR, not the terminal speed",
            ctx.bike:GetPos():Distance(start)))
    end

    -- ~350 u/s is the design target: 120 rpm crank * 2.78 gear * 10u radius.
    -- The band is deliberately generous; it catches a gearing or torque error
    -- of the kind that changes the answer by a factor, not by 10%.
    ctx:between(peak, 210, 460, "top speed", "u/s")
    ctx:log(string.format("that is %.1f km/h", BMX.ToKMH(peak)))

    -- Cadence, not drag, is what caps speed. If this is well short of the
    -- ceiling then something else is limiting and the model has changed shape.
    -- It is not a redundant check on the line above: a bike held back by drag
    -- reaches a perfectly plausible top speed with the rider barely turning the
    -- cranks, which is exactly how an 18x drag error survived unnoticed.
    --
    -- Only assertable on a run that finished, though. A bike still pulling hard
    -- when it reaches the edge of the map has cadence in hand BY DEFINITION, and
    -- failing it for that is reporting the size of gm_flatgrass as a bug in the
    -- drivetrain. The top-speed floor above still catches a factor-level change.
    local ratio = cadence / BMX.Config.Drive.maxCadence
    if cut then
        ctx:log(string.format("cadence / maxCadence = %.2f, not asserted: the " ..
            "run never reached terminal speed", ratio))
    else
        ctx:between(ratio, 0.75, 1.05, "cadence / maxCadence")
    end

    local _, r = ctx:wheels()
    ctx:ok(r.onGround, "rear wheel still driving on the ground")
end)

--------------------------------------------------------------------------
T.Case("brake_locks", { timeout = 30,
    desc = "the rear brake locks the wheel and the bike stops" },
function(ctx)
    if not ctx:accelerateTo(230, 14) then return end

    local _, rear = ctx:wheels()
    ctx:input({ brakeRear = 1 })

    -- Catch it mid-stop: a locked wheel means omega at zero while the bike is
    -- still moving, which is what makes the tyre saturate and skid. Sampling
    -- after it stops would prove nothing.
    local locked, sat = false, 0
    local deadline = CurTime() + 3
    while CurTime() < deadline and ctx:st().speed > 60 do
        if math.abs(rear.omega) < 1.5 then locked = true end
        sat = math.max(sat, rear.saturation)
        coroutine.yield()
    end

    ctx:ok(locked, "rear wheel locked (omega ~ 0 while still moving)")
    ctx:between(sat, 0.85, 1.0, "peak rear friction-circle saturation")

    local stopped = ctx:waitUntil(function() return ctx:st().speed < 25 end,
        8, "the bike to stop")
    ctx:ok(stopped, "braking brings it to a stop")
end)

--------------------------------------------------------------------------
T.Case("lean_steers", { timeout = 35,
    desc = "leaning turns, and leaning the OTHER way turns the other way" },
function(ctx)
    -- The core claim of the whole design: steering is an output of lean. A
    -- single-direction test would pass with the sign inverted, so this measures
    -- both and asserts they are opposites.
    -- 150 u/s, not 230. What these cases actually require is that the balance
    -- assist be at FULL authority, and that happens at Balance.fadeInHigh, which
    -- is 110 -- so 150 is comfortable margin and everything above it is just
    -- distance. 230 was an arbitrary number that cost a thousand extra units of
    -- runway, and once the bike could really accelerate that bought a turn taken
    -- past the edge of the map.
    local ENOUGH = 150

    local function sweep(lean)
        if not ctx:accelerateTo(ENOUGH, 14) then return nil end
        local yaw0 = ctx.bike:GetAngles().y
        ctx:input({ throttle = 0.6, lean = lean })
        ctx:wait(2.5)
        local st = ctx:st()
        local d = math.AngleDifference(ctx.bike:GetAngles().y, yaw0)
        ctx:input({})
        return { yaw = d, roll = st.roll, steer = st.steer }
    end

    local right = sweep(1)
    if not right then return end
    ctx:log(string.format("lean right: roll %+.0f deg, steer %+.1f deg, yaw %+.0f deg",
        math.deg(right.roll), math.deg(right.steer), right.yaw))

    -- roll > 0 is leaning right; in Source, turning right DECREASES yaw.
    ctx:ok(right.roll > math.rad(8), "leaning right produces a positive roll")
    ctx:ok(right.steer > 0, "positive roll derives a positive (right) steer angle")
    ctx:ok(right.yaw < -12, "and the bike actually turns right")

    ctx:waitUntil(function() return math.abs(ctx:st().roll) < math.rad(10) end, 4)

    local left = sweep(-1)
    if not left then return end
    ctx:log(string.format("lean left:  roll %+.0f deg, steer %+.1f deg, yaw %+.0f deg",
        math.deg(left.roll), math.deg(left.steer), left.yaw))

    ctx:ok(left.roll < -math.rad(8), "leaning left produces a negative roll")
    ctx:ok(left.yaw > 12, "and the bike turns left")

    -- Symmetry. A big asymmetry means a sign or a bias has crept in somewhere.
    local ratio = math.abs(left.yaw) / math.max(math.abs(right.yaw), 0.001)
    ctx:between(ratio, 0.55, 1.8, "left/right turn symmetry")
end)

--------------------------------------------------------------------------
T.Case("lean_tracks_target", { timeout = 30,
    desc = "the balance PD actually holds the lean it was asked for" },
function(ctx)
    -- 150 rather than 280, for the reason spelled out in lean_steers: the
    -- assist is at full authority from 110 u/s (Balance.fadeInHigh) and the
    -- extra speed only bought runway this map does not have.
    if not ctx:accelerateTo(150, 14) then return end

    ctx:input({ throttle = 0.7, lean = 0.6 })
    ctx:wait(2.5)

    local st = ctx:st()
    local target = 0.6 * BMX.Config.Balance.maxLean
    ctx:log(string.format("authority %.2f at %.0f u/s", st.leanAuthority, st.speed))

    ctx:between(st.leanAuthority, 0.6, 1.0, "assist authority at speed")
    -- Tracking within 12 degrees. A persistent gap larger than that means the
    -- assist ran out of authority, which is the exact failure the overlay's
    -- "roll / target" line exists to show.
    ctx:between(math.deg(math.abs(target - st.roll)), 0, 12,
        "|target - actual| roll", "deg")
end)

--------------------------------------------------------------------------
T.Case("bunny_hop", { timeout = 30,
    desc = "a preloaded hop leaves the ground and gains height" },
function(ctx)
    if not ctx:accelerateTo(160, 12) then return end
    ctx:input({ throttle = 0.5 })

    local z0 = ctx.bike:GetPos().z
    ctx:hop()

    local airborne = ctx:waitUntil(function()
        local f, r = ctx:wheels()
        return not f.onGround and not r.onGround
    end, 1.5, "both wheels to leave the ground")
    ctx:ok(airborne, "the hop leaves the ground")

    local peak = 0
    local deadline = CurTime() + 1.6
    while CurTime() < deadline do
        peak = math.max(peak, ctx.bike:GetPos().z - z0)
        coroutine.yield()
    end

    -- popSpeed 265 against 600 u/s^2 is ~56 units of rise. Wide band because
    -- forwardBias and the ground normal both shave off some of it.
    ctx:between(peak, 18, 100, "peak hop height", "u")
end)

--------------------------------------------------------------------------
T.Case("wheelie", { timeout = 30,
    desc = "weight back under power lifts the front wheel and holds it" },
function(ctx)
    if not ctx:accelerateTo(140, 12) then return end

    ctx:input({ throttle = 1, pitch = 1 })

    local lifted = ctx:waitUntil(function()
        local f, r = ctx:wheels()
        return (not f.onGround) and r.onGround
    end, 4, "the front wheel to lift with the rear still down")
    ctx:ok(lifted, "front wheel lifts under power")

    if lifted then
        -- runUntil, not wait, so the hold inherits the edge guard. A plain wait
        -- had this case reading +15 degrees on one run and -50 on the next with
        -- nothing changed in between, because the bike was riding off the map
        -- mid-wheelie and the second number was a nose-dive into a pit. It also
        -- gives "it is a wheelie, not a jump" for free: a wheelie keeps the rear
        -- wheel down, so a bike that goes fully airborne fails the run itself.
        local held = ctx:runUntil(1.2)

        local st = ctx:st()
        local _, r = ctx:wheels()
        ctx:log(string.format("pitch %.0f deg after 1.2s", math.deg(st.pitch)))

        if not held then
            ctx:ok(false, "the bike went fully airborne: that is a jump, not a wheelie")
        elseif ctx.stoppedAtEdge then
            ctx:ok(false, "the bike reached the edge of the test ground mid-wheelie")
        else
            ctx:ok(r.onGround, "rear wheel still down (it is a wheelie, not a jump)")
            -- The hold assist has a ceiling on purpose, so a wheelie can still be
            -- blown. Past holdMax plus a margin it has looped out.
            ctx:between(math.deg(st.pitch), 5, math.deg(BMX.Config.Pitch.holdMax) + 30,
                "wheelie pitch", "deg")
        end
    end
end)

--------------------------------------------------------------------------
T.Case("air_mode", { timeout = 30,
    desc = "air mode engages off a jump and rotation accumulates" },
function(ctx)
    if not ctx:accelerateTo(200, 12) then return end
    ctx:input({ throttle = 0.6 })
    ctx:hop()

    local engaged = ctx:waitUntil(function() return ctx:st().airMode end,
        2, "air mode to engage")
    ctx:ok(engaged, "air mode engages after the debounce")
    if not engaged then return end

    -- Nose up: pitch +1 is a backflip. A hop only buys a fraction of a second,
    -- so this asserts that rotation ACCUMULATES, not that a flip completes.
    ctx:input({ pitch = 1 })
    local peak = 0
    local deadline = CurTime() + 1.4
    while CurTime() < deadline and ctx:st().airMode do
        peak = math.max(peak, math.abs(ctx:st().spinPitch or 0))
        coroutine.yield()
    end

    ctx:log(string.format("accumulated %.2f rad of pitch rotation", peak))
    ctx:between(peak, 0.35, 12, "|spinPitch| while airborne", "rad")
end)

--------------------------------------------------------------------------
T.Case("crash_ejects", { timeout = 25,
    desc = "a hard impact throws the rider off" },
function(ctx)
    ctx:wait(BMX.Config.Crash.grace + 0.3)   -- the grace period is real; respect it

    local phys = ctx.bike:GetPhysicsObject()
    if not ctx:ok(IsValid(phys), "bike has a physics object") then return end

    -- Drop it inverted from high enough that the hull arrives above
    -- Crash.maxImpactSpeed. sqrt(2 * 600 * 500) is ~775 u/s, comfortably over.
    ctx.bike:SetPos(ctx.ground + Vector(0, 0, 500))
    ctx.bike:SetAngles(Angle(0, 0, 165))
    phys:SetVelocity(Vector(0, 0, -150))
    phys:Wake()

    local ejected = ctx:waitUntil(function()
        return not IsValid(ctx.bike:GetDriver())
    end, 6, "the rider to be ejected")

    ctx:ok(ejected, "a hard inverted impact ejects the rider")
end)
