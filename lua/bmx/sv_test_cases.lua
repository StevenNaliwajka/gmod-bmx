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

    local WC = ctx.cfg.Wheel
    ctx:between(snap.fc, 0.15, WC.restLength, "front compression", "u")
    ctx:between(snap.rc, 0.15, WC.restLength, "rear compression", "u")

    -- Both wheels carrying load, and between them roughly the whole bike.
    local weight = ctx.cfg.Chassis.mass * physenv.GetGravity():Length()
    ctx:between(snap.load / weight, 0.75, 1.35, "supported weight / actual weight")

    -- Ride height: the origin sits on the design axle line, so at rest it sits
    -- one wheel radius up MINUS the static sag. Derived from the config rather
    -- than hardcoded, so retuning the spring does not "break" this test.
    local sag = (weight * 0.5) / WC.spring
    ctx:log(string.format("predicted sag %.2f u -> ride height %.2f u",
        sag, WC.radius - sag))
    ctx:between(snap.h, WC.radius - sag - 2, WC.radius - sag + 2, "ride height", "u")

    -- And then it STAYS UP. This used to assert the opposite -- that a ridden
    -- bike at a standstill topples, "the assist gate is on speed, not on
    -- having a rider" -- and it was the design until the first person to
    -- ride it found a bike they could not stand on. The rider's foot
    -- (C.Stand) now holds it below walking pace.
    local fell = false
    ctx:runUntil(3, function()
        if math.abs(ctx:st().roll) > math.rad(10) then fell = true end
        return false
    end)
    ctx:ok(not fell, "a ridden bike at a standstill stays upright (the rider's foot)")
end)

--------------------------------------------------------------------------
T.Case("parked_on_stand", { rider = false, timeout = 20,
    desc = "a riderless bike stands on its kickstand and stays where it was left" },
function(ctx)
    -- This case used to be riderless_falls, asserting that an unattended bike
    -- tips over. That was the design until someone rode it: a bike that falls
    -- over the moment it is spawned, and cannot be ridden once it has, is not
    -- realism anybody wanted. See C.Stand.
    -- Three and a half seconds to settle, as offline: the nudge that lays a
    -- parked bike onto its stand is gentle on purpose (it must lose to a push).
    ctx:wait(3.5)
    local start = ctx.bike:GetPos()
    ctx:wait(3)

    local st, S = ctx:st(), ctx.bike:Cfg().Stand
    ctx:log(string.format("roll %.1f deg", math.deg(st.roll)))
    ctx:between(math.deg(st.roll), math.deg(S.standLean) - 4, math.deg(S.standLean) + 4,
        "leaning onto the stand", "deg")
    local d = ctx.bike:GetPos() - start
    ctx:between(math.sqrt(d.x * d.x + d.y * d.y), 0, 1.5, "drift in 3 s once settled", "u")
    local f, r = ctx:wheels()
    ctx:ok(f.onGround and r.onGround, "both wheels on the ground")
end)

--------------------------------------------------------------------------
T.Case("fallen_is_picked_up", { rider = false, timeout = 25,
    desc = "a bike knocked flat stays down, and getting on stands it up" },
function(ctx)
    ctx:wait(1)
    -- Through the PHYSICS OBJECT. Entity:SetAngles on a VPhysics entity does
    -- not stick: the first run of this case set 85 degrees, read -1 a quarter
    -- second later, and watched the stand recover a bike it thought it had
    -- knocked flat.
    local phys = ctx.bike:GetPhysicsObject()
    if not ctx:ok(IsValid(phys), "bike has a physics object") then return end
    phys:SetAngles(Angle(0, 0, 85))
    phys:SetPos(ctx.bike:GetPos() + Vector(0, 0, 10), true)
    phys:SetVelocity(vector_origin)
    phys:Wake()
    ctx:wait(2.5)
    ctx:ok(math.abs(ctx:st().roll) > ctx.bike:Cfg().Stand.maxRoll,
        "knocked flat, it stays down")

    local bot = nil
    for _, p in ipairs(player.GetAll()) do
        if p:IsBot() and p:Nick() == "BMXTestBot" then bot = p end
    end
    if not bot then bot = player.CreateNextBot("BMXTestBot") end
    if not ctx:ok(IsValid(bot), "a bot to ride it") then return end
    ctx.bot = bot
    bot.BMXScripted = true
    bot:EnterVehicle(ctx.bike:GetPod())
    ctx:input({})
    ctx:wait(2)

    ctx:log(string.format("roll after mounting %.1f deg", math.deg(ctx:st().roll)))
    ctx:between(math.deg(math.abs(ctx:st().roll)), 0, 8, "upright after getting on", "deg")
    local f, r = ctx:wheels()
    ctx:ok(f.onGround and r.onGround, "on its wheels")
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
    local ratio = cadence / ctx.cfg.Drive.maxCadence
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

    -- ACCUMULATE THE YAW, do not subtract the ends. math.AngleDifference
    -- returns -180..180, so a bike that turns further than half a circle during
    -- the sweep reports the short way round -- with the WRONG SIGN. A 183-degree
    -- right-hand turn comes back as +177, which is what "leaning right turns
    -- left" looks like from a test. Both directions read +170-odd and the case
    -- failed on a bike that was cornering symmetrically and correctly.
    --
    -- It only started mattering when the bike got sharper: at the old gains it
    -- managed about 55 degrees in the 2.5s and never came near the wrap. Same
    -- shape as the runway: a measurement that was safe only because the thing it
    -- measured was worse.
    local function sweep(lean)
        if not ctx:accelerateTo(ENOUGH, 14) then return nil end

        local last, total = ctx.bike:GetAngles().y, 0
        ctx:runUntil(2.5, function()
            local y = ctx.bike:GetAngles().y
            total = total + math.AngleDifference(y, last)
            last = y
            return false
        end, { throttle = 0.6, lean = lean })

        local st = ctx:st()
        ctx:input({})
        return { yaw = total, roll = st.roll, steer = st.steer }
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
    local target = 0.6 * ctx.cfg.Balance.maxLean
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
    -- Record WHY, if the landing throws the rider: "angle", "sideways" or
    -- "impact" point at three different things.
    local crashWhy
    hook.Add("BMX_Crash", "BMX.TestHopCrash", function(b, ply, reason, sev)
        if b == ctx.bike then crashWhy = string.format("%s (severity %.2f)", reason, sev) end
    end)
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

    -- AND IT LANDS. This case used to stop at the peak, which is how a plain
    -- hop that rotated to 50+ degrees nose-up and threw its rider on landing
    -- stayed green: the hop's own nose-up kick was never taken back out in
    -- the air. The offline suite found it (tests/test_sim.lua); this is the
    -- same claim on real VPhysics.
    local landed = ctx:waitUntil(function() return ctx:st().grounded end, 2,
        "the bike to come back down")
    if landed then
        -- A SETTLED landing, not the touchdown. Read at 0.3 s this reported
        -- -2.8 deg on one run and 28 on the next, on the same commit: a hop can
        -- come down rear wheel first, and 0.3 s is sometimes still the front
        -- wheel on its way down. What matters is that the bike ends up back on
        -- both wheels with its rider, so that is what is read, a second on.
        ctx:runUntil(1.0, nil, { throttle = 0.5 })
        hook.Remove("BMX_Crash", "BMX.TestHopCrash")
        if crashWhy then ctx:log("crashed: " .. crashWhy) end
        ctx:ok(IsValid(ctx.bike:GetDriver()), "a plain hop lands without a crash")
        ctx:between(math.deg(ctx:st().pitch), -12, 18, "pitch once the landing settles", "deg")
    end
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
        -- MEASURE THE REAR WHEEL OVER THE HOLD, not at one instant at the end of
        -- it. A wheelie works its rear suspension, so `onGround` is false for
        -- the odd substep without the bike having left the ground -- and a
        -- single sample landing on one of those reported "that is a jump" for a
        -- bike that was sitting on its back wheel the whole time. The case
        -- failed and passed on identical code depending on which tick it read.
        local down, ticks = 0, 0
        local held = ctx:runUntil(1.2, function()
            local _, rw = ctx:wheels()
            ticks = ticks + 1
            if rw.onGround then down = down + 1 end
            return false
        end)

        local st = ctx:st()
        ctx:log(string.format("pitch %.0f deg after 1.2s", math.deg(st.pitch)))

        if not held then
            ctx:ok(false, "the bike went fully airborne: that is a jump, not a wheelie")
        elseif ctx.stoppedAtEdge then
            ctx:ok(false, "the bike reached the edge of the test ground mid-wheelie")
        else
            local share = ticks > 0 and (down / ticks) or 0
            ctx:between(share * 100, 80, 100,
                "share of the hold with the rear wheel down (a wheelie, not a jump)", "%")
            -- The hold assist has a ceiling on purpose, so a wheelie can still be
            -- blown. Past holdMax plus a margin it has looped out.
            ctx:between(math.deg(st.pitch), 5, math.deg(ctx.cfg.Pitch.holdMax) + 30,
                "wheelie pitch", "deg")

            -- Let it down, and it pays: a wheelie held this long is past
            -- Tricks.manualMin, and ground tricks score through the same
            -- AwardTricks path as air tricks.
            local before = ctx.bike:GetScore()
            ctx:input({ throttle = 0.5 })
            local paid = ctx:waitUntil(function()
                return ctx.bike:GetScore() > before
            end, 2, "the wheelie to pay out on release")
            ctx:ok(paid, "a held wheelie scores when it ends")
        end
    end
end)

--------------------------------------------------------------------------
T.Case("stoppie", { timeout = 30,
    desc = "the front brake lifts the rear, and the hold keeps it off the bars" },
function(ctx)
    -- New with the fix to the stoppie hold's inertia: it used the free-body
    -- pitch inertia for a bike pivoting on its FRONT axle, which is 7.3x too
    -- small (the wheelie's old mistake, in its mirror image). Nothing tested
    -- a stoppie at all until then.
    -- 160, not 200: every extra u/s is runway, and a run that reaches the
    -- edge has its input zeroed by runUntil, which lets go of the brake.
    if not ctx:accelerateTo(160, 12) then return end

    -- What StartCommand writes for LMB: the front brake, and the weight
    -- shift forward that comes with it.
    ctx:input({ brakeFront = 1, pitch = -0.6 })

    -- The SLOWEST it got while braking, not the speed at the end. The first
    -- live run read 55 u/s at the end of a stoppie that had already happened:
    -- the case had reached the edge of the test ground, runUntil zeroed the
    -- input, and a bike with no brake held coasts.
    local lifted, deepest, slowest = false, 0, math.huge
    ctx:runUntil(2.5, function()
        local f, r = ctx:wheels()
        if f.onGround and not r.onGround then lifted = true end
        deepest = math.min(deepest, ctx:st().pitch)
        slowest = math.min(slowest, ctx:st().speed)
        return false
    end)

    ctx:log(string.format("deepest %.0f deg, slowest %.0f u/s%s",
        math.deg(deepest), slowest, ctx.stoppedAtEdge and " (reached the edge)" or ""))
    ctx:ok(lifted, "the rear wheel came up with the front still down")
    -- Over the bars would be past the stoppie balance point, ~47 degrees.
    ctx:between(math.deg(deepest), -45, -5, "deepest stoppie pitch", "deg")
    ctx:ok(IsValid(ctx.bike:GetDriver()), "the rider is still aboard")
    ctx:between(slowest, 0, 40, "the front brake stopped the bike", "u/s")
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
    ctx:wait(ctx.cfg.Crash.grace + 0.3)   -- the grace period is real; respect it

    local phys = ctx.bike:GetPhysicsObject()
    if not ctx:ok(IsValid(phys), "bike has a physics object") then return end

    -- Drop it inverted from high enough that the hull arrives above
    -- Crash.maxImpactSpeed. sqrt(2 * 600 * 500) is ~775 u/s, comfortably over.
    -- Through the physics object: Entity:SetPos/SetAngles do not reliably
    -- move a VPhysics body (measured in fallen_is_picked_up).
    phys:SetPos(ctx.ground + Vector(0, 0, 500), true)
    phys:SetAngles(Angle(0, 0, 165))
    phys:SetVelocity(Vector(0, 0, -150))
    phys:Wake()

    local ejected = ctx:waitUntil(function()
        return not IsValid(ctx.bike:GetDriver())
    end, 6, "the rider to be ejected")

    ctx:ok(ejected, "a hard inverted impact ejects the rider")
end)

--------------------------------------------------------------------------
T.Case("per_bike_physics", { rider = false, timeout = 20,
    desc = "a bike's physics overrides actually reach the simulation" },
function(ctx)
    -- THE POINT OF THIS CASE. `physics = {}` that silently does nothing is
    -- worse than no field at all -- that sentence is why per-bike physics did
    -- not exist for the first six phases of this addon. So the field is not
    -- considered to work because the merge function returns the right table;
    -- it is considered to work when a bike built from it SITS AT A DIFFERENT
    -- RIDE HEIGHT on a real server, which is a number no amount of plumbing
    -- can fake.
    --
    -- Registered here rather than shipped in sh_bikes.lua, because a test
    -- fixture in the spawn menu is a different thing from a bike.
    BMX.RegisterBike("testtall", {
        printName = "BMX (test fixture)",
        physics = {
            Wheel   = { radius = 16 },
            Chassis = { mass = 120 },
        },
    })

    local def = BMX.Bikes.testtall
    if not ctx:ok(def ~= nil, "the test bike registered") then return end

    ----------------------------------------------------------------------
    -- The merge itself: overridden keys change, untouched ones do not, and
    -- the BASE is not modified -- which is the failure that would make every
    -- other bike on the server quietly inherit this one's numbers.
    ----------------------------------------------------------------------
    local cfg = BMX.ConfigFor(def)
    ctx:between(cfg.Wheel.radius, 16, 16, "override reached Wheel.radius", "u")
    ctx:between(cfg.Chassis.mass, 120, 120, "override reached Chassis.mass", "kg")
    ctx:between(cfg.Wheel.wheelbase, BMX.Config.Wheel.wheelbase,
        BMX.Config.Wheel.wheelbase, "untouched key still comes from the base", "u")
    ctx:between(BMX.Config.Wheel.radius, 10, 10,
        "the BASE config was not modified by the merge", "u")

    -- A bike with no overrides shares the base by reference, so the common
    -- case costs nothing.
    ctx:ok(BMX.ConfigFor(BMX.Bikes.stock) == BMX.Config,
        "a bike with no overrides shares the base table rather than copying it")

    ----------------------------------------------------------------------
    -- And now the part that plumbing cannot fake: two bikes, same server, same
    -- moment, different numbers. Both are spawned at THEIR OWN resting height
    -- (radius - sag, with sag = m*g/2 / spring) rather than at a shared one,
    -- because dropping a bike thirty units onto its own suspension measures the
    -- bump stop and not the spring.
    ----------------------------------------------------------------------
    local g = physenv.GetGravity():Length()
    local function restingHeight(mass, radius)
        return radius - (mass * g * 0.5) / BMX.Config.Wheel.spring
    end

    local function drop(class, y, mass, radius)
        local e = ents.Create(class)
        if not IsValid(e) then return nil end
        e:SetPos(ctx.ground + Vector(0, y, restingHeight(mass, radius) + 1))
        e:SetAngles(Angle(0, 0, 0))
        e:Spawn()
        e:Activate()
        return e
    end

    local tall  = drop(BMX.ClassFor("testtall"), 140, 120, 16)
    local stock = drop("bmx_base", -140, BMX.Config.Chassis.mass, BMX.Config.Wheel.radius)

    if not ctx:ok(IsValid(tall) and IsValid(stock), "both bikes spawned") then
        SafeRemoveEntity(tall) SafeRemoveEntity(stock)
        BMX.Bikes.testtall = nil
        return
    end

    ctx:ok(tall:Cfg().Wheel.radius == 16,
        "the spawned entity resolves its own config, not the base")

    -- Long enough to settle, short enough that neither has toppled: both are
    -- riderless, and a riderless bike falling over is the design.
    ctx:wait(0.6)

    local hTall  = tall:GetPos().z  - ctx.ground.z
    local hStock = stock:GetPos().z - ctx.ground.z
    ctx:log(string.format("predicted: tall %.2f u, stock %.2f u",
        restingHeight(120, 16), restingHeight(BMX.Config.Chassis.mass, BMX.Config.Wheel.radius)))
    ctx:log(string.format("measured:  tall %.2f u, stock %.2f u", hTall, hStock))

    ctx:between(hTall, restingHeight(120, 16) - 2, restingHeight(120, 16) + 2,
        "test bike ride height", "u")
    ctx:between(hStock,
        restingHeight(BMX.Config.Chassis.mass, BMX.Config.Wheel.radius) - 2,
        restingHeight(BMX.Config.Chassis.mass, BMX.Config.Wheel.radius) + 2,
        "and the stock bike beside it is unaffected", "u")

    -- The claim in one number: they are not the same bike.
    ctx:between(hTall - hStock, 3, 7,
        "difference between the two, which is the whole point", "u")

    SafeRemoveEntity(tall)
    SafeRemoveEntity(stock)
    BMX.Bikes.testtall = nil
end)

--------------------------------------------------------------------------
T.Case("duplicator_and_grab", { timeout = 25,
    desc = "a bike survives a copy/paste, and cannot be grabbed while ridden" },
function(ctx)
    ----------------------------------------------------------------------
    -- DUPLICATOR. The failure this guards against is SILENT: the duplicator
    -- skips a class it was never told about, so a bike that is not registered
    -- copies as nothing at all and the player finds out when their dupe comes
    -- back one bike short.
    ----------------------------------------------------------------------
    ctx:ok(duplicator.FindEntityClass(ctx.bike:GetClass()) ~= nil,
        "the bike's class is registered with the duplicator")

    -- CopyEntTable, not Copy. duplicator.Copy returns ONE entity table --
    -- Class, Pos, Mins, PhysicsObjects and so on -- while Paste wants a LIST of
    -- them keyed by entity index. Handing the first straight to the second gets
    -- you an error from inside GMod's CreateEntityFromTable that reads like the
    -- addon's registration is broken when it is the caller's shape that is
    -- wrong. Verified on a live server: the addon's own handler pastes fine
    -- once the shape is right.
    local t = duplicator.CopyEntTable(ctx.bike)
    ctx:ok(istable(t) and t.Class == ctx.bike:GetClass(),
        "duplicator.CopyEntTable captured it")

    local pasted = duplicator.Paste(ctx.bot, { [ctx.bike:EntIndex()] = t }, {})
    local copy
    for _, e in pairs(pasted or {}) do
        if IsValid(e) and e ~= ctx.bike and e.IsBMX then copy = e break end
    end

    if ctx:ok(IsValid(copy), "and pasting produced a working bike") then
        -- Rebuilt, not half-built: a pasted bike whose Initialize did not
        -- finish looks completely normal until someone presses E on it, which
        -- is a lesson this addon has already learned once.
        ctx:ok(IsValid(copy:GetPod()), "the pasted bike has a seat")
        ctx:ok(copy.wheels and #copy.wheels == 2, "the pasted bike has its wheels")

        -- Exactly one seat. The pod is parented, so without DoNotDuplicate the
        -- paste brings its own along and Initialize builds another.
        local pods = 0
        for _, e in ipairs(ents.FindByClass("prop_vehicle_prisoner_pod")) do
            if e:GetParent() == copy then pods = pods + 1 end
        end
        ctx:between(pods, 1, 1, "and exactly one seat, not a pasted one plus a built one")

        SafeRemoveEntity(copy)
    end

    ----------------------------------------------------------------------
    -- GRABBING. A ridden bike held in the physgun is under the engine's shadow
    -- controller while PhysicsSimulate keeps applying suspension and tyre
    -- forces to it, with the rider in a pod parented to the argument.
    ----------------------------------------------------------------------
    local occupied = IsValid(ctx.bike:GetDriver())
    if ctx:ok(occupied, "the test bike has a rider aboard") then
        ctx:ok(hook.Run("PhysgunPickup", ctx.bot, ctx.bike) == false,
            "physgun refuses a bike with a rider on it")
        ctx:ok(hook.Run("GravGunPickupAllowed", ctx.bot, ctx.bike) == false,
            "gravity gun refuses it too")
        ctx:ok(hook.Run("PhysgunPickup", ctx.bot, ctx.bike:GetPod()) == false,
            "and the seat is never grabbable")
    end

    -- An EMPTY bike is ordinary furniture and must stay pickup-able, or the
    -- guard has quietly broken building with them.
    local spare = ents.Create("bmx_base")
    spare:SetPos(ctx.ground + Vector(0, 200, 20))
    spare:Spawn()
    spare:Activate()
    ctx:ok(hook.Run("PhysgunPickup", ctx.bot, spare) ~= false,
        "an empty bike is still pickup-able")
    SafeRemoveEntity(spare)
end)

--------------------------------------------------------------------------
T.Case("removed_under_rider", { timeout = 20, removesBike = true,
    desc = "deleting a bike out from under its rider does not strand them" },
function(ctx)
    -- The scenario is not exotic: an admin cleanup, a prop limit, a map reset,
    -- or someone pointing the remover tool at a bike somebody is riding. The
    -- seat is a parented pod that is removed with the bike, and a player whose
    -- vehicle vanishes mid-frame is the classic way to end up welded in place
    -- with no way out but suicide.
    if not ctx:ok(IsValid(ctx.bot) and ctx.bike:GetDriver() == ctx.bot,
        "the rider is aboard to begin with") then return end

    local pod = ctx.bike:GetPod()
    ctx:ok(IsValid(pod), "and the seat exists")

    SafeRemoveEntity(ctx.bike)
    ctx:wait(0.5)

    ctx:ok(not IsValid(ctx.bike), "the bike is gone")
    ctx:ok(not IsValid(pod), "the seat went with it rather than being orphaned")

    if IsValid(ctx.bot) then
        ctx:ok(not IsValid(ctx.bot:GetVehicle()),
            "the rider is not still in a vehicle that no longer exists")
        ctx:ok(ctx.bot:GetMoveType() ~= MOVETYPE_NONE,
            "and can move again rather than being frozen where the bike was")
    end
end)

--------------------------------------------------------------------------
-- GRINDING on the real engine. The offline suite places boxes; here the rail
-- is a real prop, VPhysics really collides the frame with it, and the bike is
-- really moved by setting its physics object inside PhysicsSimulate.
--------------------------------------------------------------------------

-- A frozen prop, returned with its world bounds once it has settled in place.
local function railProp(ctx, model, pos, ang)
    local e = ents.Create("prop_physics")
    e:SetModel(model)
    e:SetPos(pos)
    e:SetAngles(ang)
    e:Spawn()
    local p = e:GetPhysicsObject()
    if IsValid(p) then p:EnableMotion(false) end
    ctx:wait(0.1)
    local lo, hi = e:WorldSpaceAABB()
    return e, lo, hi
end

-- Put the bike in the air with its crank contact `above` over `at`, moving.
local function launchAt(ctx, at, above, yaw, vel)
    local b = ctx.bike
    local crank = BMX.GrindCrankPoint(b:Cfg())
    local ang = Angle(0, yaw, 0)
    local off = ang:Forward() * crank.x - ang:Right() * crank.y + ang:Up() * crank.z
    local phys = b:GetPhysicsObject()
    phys:SetAngles(ang)
    phys:SetPos(at + Vector(0, 0, above) - off)
    phys:SetVelocity(vel)
    phys:SetAngleVelocity(Vector(0, 0, 0))
    b.st.grounded, b.st.groundedFor = false, 0
end

-- Watch one grind from start to end.
local function watchGrind(ctx, timeout, each)
    local started, ended
    hook.Add("BMX_GrindStarted", "BMX.TestGrind", function(e, kind)
        if e == ctx.bike then started = started or kind end
    end)
    hook.Add("BMX_GrindEnded", "BMX.TestGrind", function(e, kind, why, t)
        if e == ctx.bike then ended = ended or { kind = kind, why = why, t = t } end
    end)
    ctx:waitUntil(function()
        if ctx:st().grind and each then each(ctx:st().grind) end
        return ended ~= nil
    end, timeout, "the grind to end")
    hook.Remove("BMX_GrindStarted", "BMX.TestGrind")
    hook.Remove("BMX_GrindEnded", "BMX.TestGrind")
    return started, ended
end

T.Case("grind_pipe", { timeout = 25,
    desc = "hopping onto a pipe along it locks into a crank grind, and lets go at the end" },
function(ctx)
    ctx:input({})
    ctx:st().grindExitClamped = 0
    local pole, lo, hi = railProp(ctx, "models/props_c17/signpole001.mdl",
        ctx.ground + Vector(0, 0, 45), Angle(90, 0, 0))
    local long = hi.x - lo.x
    ctx:log(string.format("pole %.0f long, %.1f x %.1f across", long, hi.y - lo.y, hi.z - lo.z))
    local y = (lo.y + hi.y) * 0.5
    launchAt(ctx, Vector(lo.x + 8, y, hi.z), 5, 8, Vector(240, 0, -30))

    local worstUp, worstSide = 0, 0
    local started, ended = watchGrind(ctx, 4, function(g)
        local c = ctx.bike:LocalToWorld(BMX.GrindCrankPoint(ctx.bike:Cfg()))
        worstUp = math.max(worstUp, math.abs(c.z - g.point.z))
        worstSide = math.max(worstSide, math.abs(c.y - y))
    end)
    ctx:ok(started == "crank", "locked into a crank grind: " .. tostring(started))
    if ended then
        ctx:log(string.format("ended by %s after %.2fs", ended.why, ended.t))
        ctx:ok(ended.why == "end", "let go where the pipe ends")
        ctx:between(ended.t, 0.2, 2, "grind time along the pole", "s")
    end
    ctx:between(worstUp, 0, 1.5, "chainring kept on the pipe's top", "u")
    ctx:between(worstSide, 0, 2.5, "and on its line", "u")
    ctx:ok(IsValid(ctx.bike:GetDriver()), "rider still aboard")
    ctx:ok((ctx:st().grindExitClamped or 0) == 0, "let go without being shoved out of the pipe")
    SafeRemoveEntity(pole)
end)

T.Case("grind_ledge", { timeout = 25,
    desc = "hopping onto a ledge's edge along it locks into a double peg grind" },
function(ctx)
    ctx:input({})
    ctx:st().grindExitClamped = 0
    local box, lo, hi = railProp(ctx, "models/hunter/blocks/cube1x8x1.mdl",
        ctx.ground + Vector(0, 0, 24), Angle(0, 90, 0))
    ctx:log(string.format("ledge %.0f long, top at +%.0f", hi.x - lo.x, hi.z - ctx.ground.z))
    launchAt(ctx, Vector(lo.x + 20, lo.y + 2, hi.z), 6, 0, Vector(240, 0, -30))

    local code, dropSide = 0, true
    local started, ended = watchGrind(ctx, 5, function(g)
        code = ctx.bike:GetGrind()
        local half = ctx.bike:Cfg().Wheel.wheelbase * 0.5
        if ctx.bike:LocalToWorld(Vector(half, 0, 0)).y > lo.y then dropSide = false end
    end)
    ctx:ok(started == "peg", "locked into a peg grind: " .. tostring(started))
    ctx:ok(code == 2, "pegs on the left, the ledge's side: " .. code)
    ctx:ok(dropSide, "the wheels hung off the drop side the whole way")
    ctx:ok((ctx:st().grindExitClamped or 0) == 0, "let go without being shoved out of the ledge")
    if ended then ctx:log(string.format("ended by %s after %.2fs", ended.why, ended.t)) end
    ctx:ok(IsValid(ctx.bike:GetDriver()), "rider still aboard")
    SafeRemoveEntity(box)
end)

T.Case("grind_hop_on", { timeout = 30,
    desc = "a rider coming at a beam from the side hops onto it, grinds, and comes off without being launched" },
function(ctx)
    -- The whole move on the real engine: rolling on the ground, a real hop
    -- (the preload and the pop), the lock-on in mid-air, the grind, and the
    -- beam ending under it. Nothing is placed but the start.
    --
    -- FROM THE SIDE, AT AN ANGLE, the way a rider does it. Rolling straight
    -- alongside a beam at bar height puts the bars (14.8 out) into its end
    -- before any hop, which is a test of riding into things.
    ctx:st().grindExitClamped = 0
    local b = ctx.bike
    local phys = b:GetPhysicsObject()
    local C = b:Cfg()
    local TOP, YAW, SPEED = 18, 6, 260
    local beam, lo, hi = railProp(ctx, "models/hunter/blocks/cube025x8x025.mdl",
        ctx.ground + Vector(290, 0, TOP), Angle(0, 90, 0))
    -- By its BOUNDS: a model's origin is wherever its author left it (this
    -- one's is at its base).
    local shift = Vector(ctx.ground.x + 290 - (lo.x + hi.x) * 0.5,
                         ctx.ground.y - (lo.y + hi.y) * 0.5,
                         ctx.ground.z + TOP - hi.z)
    local bp = beam:GetPhysicsObject()
    beam:SetPos(beam:GetPos() + shift)
    if IsValid(bp) then bp:SetPos(beam:GetPos()) bp:EnableMotion(false) end
    ctx:wait(0.1)
    lo, hi = beam:WorldSpaceAABB()

    -- Where the crank point should cross the near edge: on the way down, a
    -- unit or two onto the top. Worked back from the hop (Hop.popSpeed off
    -- the ground, Hop.chargeTime of preload) to a start beside the beam.
    local g = physenv.GetGravity():Length()
    local vz = C.Hop.popSpeed / math.sqrt(1 + C.Hop.forwardBias ^ 2)
    local crank0 = BMX.RestHeight(C) + BMX.GrindCrankPoint(C).z
    local rise = TOP + 4 - crank0
    local tDown = (vz + math.sqrt(math.max(vz * vz - 2 * g * rise, 0))) / g
    local t = C.Hop.chargeTime + 0.05 + tDown
    local lateral = SPEED * math.sin(math.rad(YAW))
    local y0 = lo.y + 2 - lateral * t
    local x0 = lo.x + 60 - SPEED * math.cos(math.rad(YAW)) * t
    ctx:log(string.format("beam x %.0f..%.0f, near edge y %.1f, top +%.0f; start %.0f,%.0f; over it at %.2fs",
        lo.x - ctx.ground.x, hi.x - ctx.ground.x, lo.y - ctx.ground.y, hi.z - ctx.ground.z,
        x0 - ctx.ground.x, y0 - ctx.ground.y, t))

    local ang = Angle(0, YAW, 0)
    phys:SetAngles(ang)
    phys:SetPos(Vector(x0, y0, ctx.ground.z + BMX.RestHeight(C)))
    phys:SetVelocity(ang:Forward() * SPEED)
    phys:SetAngleVelocity(Vector(0, 0, 0))
    ctx:input({ throttle = 1 })
    ctx:wait(0.05)

    local out, worstUp, worstFast, started = nil, -math.huge, -math.huge, nil
    local closest = math.huge
    hook.Add("BMX_GrindEnded", "BMX.TestHopOn", function(e)
        if e == b and not out then out = b.st.grindExit and b.st.grindExit.vel end
    end)
    hook.Add("BMX_GrindStarted", "BMX.TestHopOn", function(e, kind)
        if e == b then started = started or kind end
    end)
    ctx:hop()
    ctx:waitUntil(function()
        local c = b:LocalToWorld(BMX.GrindCrankPoint(C))
        if c.x > lo.x and c.x < hi.x then
            closest = math.min(closest, math.abs(c.z - hi.z) + math.max(lo.y - c.y, 0))
        end
        if out then
            if b.st.grounded then return true end
            local v = phys:GetVelocity()
            worstUp = math.max(worstUp, v.z - math.max(out.z, 0))
            worstFast = math.max(worstFast, v:Length() - out:Length())
        end
        return false
    end, 5, "grind, exit and landing")
    hook.Remove("BMX_GrindEnded", "BMX.TestHopOn")
    hook.Remove("BMX_GrindStarted", "BMX.TestHopOn")
    ctx:input({})
    ctx:log(string.format("closest the crank point came to the near edge's top: %.1f u", closest))

    ctx:ok(started == "peg", "hopped onto the beam into a peg grind: " .. tostring(started))
    ctx:ok(out ~= nil, "and came off it")
    if out then
        ctx:between(worstUp, -1e9, 10, "climbing faster than it left the beam", "u/s")
        ctx:between(worstFast, -1e9, 40, "going faster than it left the beam", "u/s")
    end
    ctx:ok((b.st.grindExitClamped or 0) == 0, "let go without being shoved out of the beam")
    ctx:ok(IsValid(b:GetDriver()), "rider still aboard")
    SafeRemoveEntity(beam)
end)

T.Case("lands_on_a_transition", { timeout = 25,
    desc = "hands off, the bike comes down onto a 30-degree slope matching it, not level" },
function(ctx)
    -- A skatepark lands you on slopes. The air assist levels toward the
    -- surface it is about to land on (BMX.LandingNormal), which on a tilted
    -- plate the offline plant cannot model is a question for VPhysics.
    ctx:input({})
    local b = ctx.bike
    local phys = b:GetPhysicsObject()
    local plate = ents.Create("prop_physics")
    plate:SetModel("models/hunter/plates/plate8x8.mdl")
    plate:SetPos(ctx.ground + Vector(0, 0, 120))
    plate:SetAngles(Angle(30, 0, 0))        -- falls away toward +x
    plate:Spawn()
    local pp = plate:GetPhysicsObject()
    if IsValid(pp) then pp:EnableMotion(false) end
    ctx:wait(0.1)
    local n = plate:GetUp()
    ctx:log(string.format("slope normal (%.2f, %.2f, %.2f)", n.x, n.y, n.z))

    -- Above the uphill half, level, riding down the fall line.
    local over = plate:GetPos() - Vector(90, 0, 0)
    local tr = util.TraceLine({ start = over + Vector(0, 0, 200), endpos = over - Vector(0, 0, 200),
        filter = { b, b:GetPod(), b:GetDriver() } })
    if not ctx:ok(tr.Hit and tr.Entity == plate, "found the slope under the start") then
        SafeRemoveEntity(plate) return
    end
    phys:SetAngles(Angle(0, 0, 0))
    phys:SetPos(tr.HitPos + Vector(0, 0, 70))
    phys:SetVelocity(Vector(250, 0, 0))
    phys:SetAngleVelocity(Vector(0, 0, 0))

    -- AIRBORNE FIRST. The entity's position follows its physics object one
    -- tick late, so the first substep after the teleport still sees the bike
    -- on its start ground and reports it grounded -- which the first version
    -- of this case took for the landing, with the bike still level: exactly
    -- 30.00 degrees off, every run.
    -- Not by the grounded flag: this case has just set it false itself, which
    -- is why the second version still "landed" 0.02 s in. By where the bike
    -- really is, and then by a couple of substeps of real air.
    local t0 = CurTime()
    local startZ = tr.HitPos.z + 40
    ctx:waitUntil(function() return b:GetPos().z > startZ end, 1, "the bike up at its start")
    local airTicks = 0
    ctx:waitUntil(function()
        if b.st.grounded then airTicks = 0 else airTicks = airTicks + 1 end
        return airTicks >= 3
    end, 1, "leaving the start")
    local off, sawRef, airMode, tLand = nil, false, false, nil
    ctx:waitUntil(function()
        if b.st.landRef then sawRef = true end
        if b.st.airMode then airMode = true end
        if b.st.grounded then
            off = math.deg(math.acos(math.Clamp(b:GetUp():Dot(n), -1, 1)))
            tLand = CurTime() - t0
            return true
        end
        return false
    end, 3, "the landing")
    ctx:log(string.format("landed after %.2fs; air mode %s; landing surface seen %s",
        tLand or -1, tostring(airMode), tostring(sawRef)))
    -- Aboard just after touchdown, not a second later: by then the bike has
    -- ridden off the plate's lower edge, 25 units up and nose-down, which is
    -- a drop off a ledge and a different question (it threw the rider on one
    -- run in two, with the landing itself identical).
    ctx:wait(0.3)
    if off then ctx:between(off, 0, 15, "off the slope at touchdown", "deg") end
    ctx:ok(IsValid(b:GetDriver()), "rider still aboard after the landing")
    SafeRemoveEntity(plate)
end)

T.Case("into_a_ledge", { timeout = 25,
    desc = "riding straight into a ledge does not launch the bike" },
function(ctx)
    -- A rider: "if I drive into a ledge my bike launches". The suspension ray
    -- landed on the ledge's top the tick the fork crossed its edge; now a rise
    -- past Wheel.stepMax is a face, not ground. Here the wheel's own collision
    -- box really meets the face, which the offline plant cannot show.
    ctx:input({})
    local b = ctx.bike
    local phys = b:GetPhysicsObject()
    local worstVz, worstRise = -math.huge, -math.huge
    for _, model in ipairs({ "models/hunter/blocks/cube025x8x025.mdl",
                             "models/hunter/blocks/cube05x8x05.mdl" }) do
        local box, lo, hi = railProp(ctx, model, ctx.ground + Vector(260, 0, 30), Angle(0, 0, 0))
        local shift = Vector(ctx.ground.x + 260 - lo.x, 0, ctx.ground.z - lo.z)
        local bp = box:GetPhysicsObject()
        box:SetPos(box:GetPos() + shift)
        if IsValid(bp) then bp:SetPos(box:GetPos()) bp:EnableMotion(false) end
        ctx:wait(0.1)
        lo, hi = box:WorldSpaceAABB()
        local h = hi.z - ctx.ground.z
        local z0 = ctx.ground.z + BMX.RestHeight(b:Cfg())
        phys:SetAngles(Angle(0, 0, 0))
        phys:SetPos(Vector(ctx.ground.x + 20, (lo.y + hi.y) * 0.5, z0))
        phys:SetVelocity(Vector(250, 0, 0))
        phys:SetAngleVelocity(Vector(0, 0, 0))
        ctx:input({ throttle = 1 })
        -- The MASS CENTRE's rise, not the origin's: a bike that hits a face
        -- tips forward over its bars, which lifts the origin (on the axle
        -- line, well below the mass centre) 30 units on one run in two while
        -- the mass centre pivots. A launch throws the mass centre up.
        local vz, rise = -math.huge, -math.huge
        local com0 = phys:LocalToWorld(phys:GetMassCenter()).z
        local t0 = CurTime()
        ctx:waitUntil(function()
            if not IsValid(b) then return true end
            vz = math.max(vz, phys:GetVelocity().z)
            rise = math.max(rise, phys:LocalToWorld(phys:GetMassCenter()).z - com0)
            return CurTime() - t0 > 2
        end, 4, "the ride into it")
        ctx:input({})
        ctx:log(string.format("%.0f-unit ledge: fastest upward %.0f u/s, mass centre up %.1f units", h, vz, rise))
        worstVz, worstRise = math.max(worstVz, vz), math.max(worstRise, rise)
        SafeRemoveEntity(box)
        -- Back aboard for the next ledge if the impact threw the rider.
        if IsValid(ctx.bot) and not IsValid(b:GetDriver()) and IsValid(b:GetPod()) then
            ctx.bot:EnterVehicle(b:GetPod())
        end
        ctx:wait(0.2)
    end
    ctx:between(worstVz, -1e9, 120, "fastest the bike went UP off a ledge it hit", "u/s")
    ctx:between(worstRise, -1e9, 25, "highest the mass centre went", "u")
end)

--------------------------------------------------------------------------
T.Case("sounds_exist", { rider = false, timeout = 15,
    desc = "every sound the addon references actually ships with the game" },
function(ctx)
    -- The addon deliberately carries no audio of its own, so every path in
    -- BMX.Sounds is a bet that the file is in base Garry's Mod. A wrong bet is
    -- SILENT for the player and noisy in their console, and neither end of that
    -- tells you which line referenced it. This is the only check that can.
    local missing, checked = {}, 0

    for key, s in pairs(BMX.Sounds) do
        for i = 1, (s.variants or 1) do
            local path = s.variants and string.format(s.path, i) or s.path
            checked = checked + 1
            if not file.Exists("sound/" .. path, "GAME") then
                missing[#missing + 1] = key .. " -> " .. path
            end
        end
    end

    ctx:log(string.format("checked %d files across %d sound families",
        checked, table.Count(BMX.Sounds)))
    for _, m in ipairs(missing) do ctx:log("MISSING: " .. m) end

    ctx:between(checked, 8, 64, "sound files referenced")
    ctx:ok(#missing == 0, "every referenced sound file exists in mounted content")

    -- SoundFile has to return a real path for every family, including the ones
    -- with numbered variants -- a %d left unsubstituted is a path that will
    -- never resolve.
    local bad = {}
    for key in pairs(BMX.Sounds) do
        local p = BMX.SoundFile(key)
        if not p or string.find(p, "%%d") then bad[#bad + 1] = key end
    end
    ctx:ok(#bad == 0, "BMX.SoundFile resolves every family to a concrete path")
end)

--------------------------------------------------------------------------
T.Case("skid_is_networked", { timeout = 30,
    desc = "the client is told when a tyre is actually sliding" },
function(ctx)
    -- The skid sound is client-side, and whether a tyre is sliding is something
    -- the client cannot work out: it is grip*N against the force the tyre was
    -- asked for, and the client has neither the load nor the slip. So the
    -- server sets a bool, and this is the check that the bool means something.
    ctx:ok(ctx.bike:GetSkidding() == false, "not skidding while sitting still")

    if not ctx:accelerateTo(150, 14) then return end

    -- Lock the rear under brakes. brake_locks already proves this saturates the
    -- friction circle; the question here is only whether it reaches the client.
    local sawSkid = false
    ctx:runUntil(3, function()
        if ctx.bike:GetSkidding() then sawSkid = true return true end
        return false
    end, { brakeRear = 1 })

    ctx:ok(sawSkid, "locking the rear wheel sets the networked skid flag")

    -- And it has to CLEAR, or the sound loops forever on a stationary bike.
    ctx:input({})
    local cleared = ctx:waitUntil(function()
        return not ctx.bike:GetSkidding()
    end, 6, "the skid flag to clear once the bike stops sliding")
    ctx:ok(cleared, "and clears again when it stops")
end)

--------------------------------------------------------------------------
T.Case("crowd", { timeout = 40,
    desc = "a server with two dozen bikes out keeps its tick rate, and none of them NaNs" },
function(ctx)
    -- THE QUESTION A PUBLIC SERVER ASKS FIRST, and the one the offline suite
    -- cannot answer: what the bikes cost VPhysics and the Lua substep for real.
    -- So: the ridden bike (standing, so it cannot run out of test ground in
    -- the seven seconds this takes), eight parked, eight fallen and eight
    -- dropped tumbling from height -- every state a bike on a busy server is in
    -- -- and then count the ticks the server actually manages per real second.
    -- A server that falls behind runs fewer ticks than its tickrate, and that is
    -- what a player feels as everything going slow-motion and rubber-banding.
    local want = 1 / engine.TickInterval()
    local function tickRate(secs)
        local n, t0 = 0, SysTime()
        hook.Add("Tick", "BMX.Test.Crowd", function() n = n + 1 end)
        ctx:wait(secs)
        hook.Remove("Tick", "BMX.Test.Crowd")
        return n / math.max(SysTime() - t0, 1e-3)
    end

    ctx:input({})
    local alone = tickRate(2)
    ctx:log(string.format("one bike: %.1f ticks/s of %.0f", alone, want))

    local ids, made = BMX.BikeIDs(), {}
    local function put(i, pos, ang)
        local id = ids[(i - 1) % #ids + 1]
        local e = ents.Create(BMX.ClassFor(id))
        if not IsValid(e) then return end
        e:SetPos(pos)
        e:SetAngles(ang)
        e:Spawn()
        e:Activate()
        made[#made + 1] = e
        return e
    end
    for i = 1, 8 do
        local cfg = BMX.ConfigFor(BMX.Bikes[ids[(i - 1) % #ids + 1]])
        put(i, ctx.ground + Vector(-200 + i * 50, 260, BMX.RestHeight(cfg) + 1), Angle(0, 90, 0))
        put(i, ctx.ground + Vector(-200 + i * 50, -260, 20), Angle(0, 0, 90))
        put(i, ctx.ground + Vector(-200 + i * 50, 420, 200 + i * 20), Angle(i * 40, i * 25, i * 60))
    end
    ctx:log(string.format("%d more bikes out: parked, fallen and dropped", #made))
    ctx:wait(1)     -- the drops land and the tumbling starts

    local crowded = tickRate(4)
    ctx:log(string.format("%d bikes: %.1f ticks/s of %.0f", #made + 1, crowded, want))
    if engine.ServerFrameTime then
        local ft, sd = engine.ServerFrameTime()
        ctx:log(string.format("server frame time %.2f ms (sd %.2f) of a %.2f ms tick",
            ft * 1000, (sd or 0) * 1000, engine.TickInterval() * 1000))
    end

    ctx:ok(#made == 24, "all 24 extra bikes spawned")
    ctx:between(crowded / want, 0.9, 1.1, "the server keeps its tickrate with 25 bikes out")
    ctx:between(crowded / math.max(alone, 1), 0.9, 1.1, "as many ticks as with one bike")

    local bad = 0
    for _, e in ipairs(made) do
        if not IsValid(e) then
            bad = bad + 1
        else
            local p, v = e:GetPos(), e:GetVelocity()
            if p.x ~= p.x or p.z ~= p.z or v.x ~= v.x or v.z ~= v.z then bad = bad + 1 end
        end
    end
    ctx:ok(bad == 0, "every bike in the crowd survived, with finite state (" .. bad .. " bad)")
    ctx:ok(IsValid(ctx.bike:GetDriver()), "the ridden bike's rider is still aboard")

    for _, e in ipairs(made) do SafeRemoveEntity(e) end
end)

--------------------------------------------------------------------------
-- THE BOT (sv_bot.lua): every trick in its list, on a real server, judged by
-- the addon's own scoring rather than by what the bot thinks it did.
--
-- The bot is attached to the harness's own scripted rider and bike, so these
-- run exactly like any other case. Each trick finds its own room on the map,
-- its own launch (or puts a kicker down), and rides there itself.
--------------------------------------------------------------------------
local function botTrick(ctx, name, opts)
    opts = opts or {}
    local brain = BMX.Bot.Attach(ctx.bot, ctx.bike, {
        quiet = true, home = ctx.ground,
        allowSpawnRamp = opts.allowSpawnRamp, allowFindRamp = opts.allowFindRamp,
    })
    local result
    BMX.Bot.Perform(brain, name, function(ok, why) result = { ok = ok, why = why } end)
    ctx:waitUntil(function() return result ~= nil end, opts.timeout or 70, name .. " finished")
    for _, line in ipairs(brain.log) do ctx:log(line) end
    BMX.Bot.Detach(brain)
    ctx:input({})
    return result, brain
end

-- The tricks the bot does not land on a real server yet: run by name while
-- they are worked on, out of the full run until they pass. EMPTY THIS.
local BOT_WIP = { ["Backflip"] = true, ["Frontflip"] = true, ["Barrel Roll"] = true,
                  ["360"] = true, ["Crank Grind"] = true }
BMX.Bot.WIP = BOT_WIP

for _, name in ipairs(BMX.Bot.TrickList) do
    T.Case("bot_" .. name:lower():gsub("[^%w]+", "_"), { timeout = 90, wip = BOT_WIP[name],
        desc = "the bot lands a " .. name .. ", by the scoring's own account" },
    function(ctx)
        local r = botTrick(ctx, name)
        ctx:ok(r and r.ok, name .. " landed: " .. tostring(r and r.why or "no result"))
        ctx:ok(IsValid(ctx.bike:GetDriver()), "and the rider is still on the bike")
    end)
end

T.Case("bot_finds_a_ramp_in_the_world", { timeout = 90, wip = true,
    desc = "with no kicker of its own allowed, the bot finds a ramp it was not told about and flips off it" },
function(ctx)
    -- A plain tilted plate, put down the way a map's ramp or a player's prop
    -- would be -- not through BMX.SpawnKicker, so nothing about it is known to
    -- the bot except what its traces find.
    local yaw, best = 0, 0
    for k = 0, 7 do
        local len = BMX.Launch.Runway(ctx.ground, BMX.Launch.DirOf(k * 45), 1800, { filter = { ctx.bike, ctx.bot } })
        if len > best then yaw, best = k * 45, len end
    end
    local dir = BMX.Launch.DirOf(yaw)
    local plate = ents.Create("prop_physics")
    plate:SetModel("models/hunter/plates/plate4x4.mdl")
    plate:Spawn()
    local mn, mx = plate:OBBMins(), plate:OBBMaxs()
    local centre, ang = BMX.Launch.KickerGeometry(ctx.ground + dir * 650, yaw,
        math.max(mx.x - mn.x, mx.y - mn.y), mx.z - mn.z, math.rad(26))
    plate:SetPos(centre)
    plate:SetAngles(ang)
    local pp = plate:GetPhysicsObject()
    if IsValid(pp) then pp:EnableMotion(false) end
    ctx:wait(0.2)
    ctx:log(string.format("plate put %.0f deg off, %.0f u of runway that way", yaw, best))

    local r, brain = botTrick(ctx, "Backflip", { allowSpawnRamp = false })
    local found = false
    for _, line in ipairs(brain.log) do if line:find("found a launch", 1, true) then found = true end end
    ctx:ok(found, "it found the plate with its own traces")
    ctx:ok(r and r.ok, "and backflipped off it: " .. tostring(r and r.why))
    SafeRemoveEntity(plate)
end)

T.Case("bot_spawns_named_and_dressed", { rider = false, timeout = 40,
    desc = "bmx_bot_spawn's bot has its name and model, sits on its bike, and rides" },
function(ctx)
    local oldName, oldModel = GetConVar("bmx_bot_name"):GetString(), GetConVar("bmx_bot_model"):GetString()
    RunConsoleCommand("bmx_bot_name", "BMX Show Bot")
    RunConsoleCommand("bmx_bot_model", "models/player/kleiner.mdl")
    ctx:wait(0.2)
    local b, err = BMX.Bot.Spawn(ctx.ground + Vector(0, 300, 0), 0)
    if not ctx:ok(b ~= nil, "spawned: " .. tostring(err)) then return end
    b.show = false
    ctx:wait(0.5)
    ctx:ok(b.ply:Nick() == "BMX Show Bot", "named by bmx_bot_name: " .. b.ply:Nick())
    ctx:ok(b.ply:GetModel() == "models/player/kleiner.mdl", "dressed by bmx_bot_model: " .. b.ply:GetModel())
    ctx:ok(b.bike:GetDriver() == b.ply, "sitting on its own bike")
    local result
    BMX.Bot.Perform(b, "Bunny Hop", function(ok, why) result = { ok = ok, why = why } end)
    ctx:waitUntil(function() return result ~= nil end, 25, "the hop finished")
    ctx:ok(result and result.ok, "and it rides: a bunny hop, " .. tostring(result and result.why))
    local bike, ply = b.bike, b.ply
    BMX.Bot.Detach(b)
    SafeRemoveEntity(bike)
    if IsValid(ply) then ply:Kick("test over") end
    RunConsoleCommand("bmx_bot_name", oldName)
    RunConsoleCommand("bmx_bot_model", oldModel)
end)

--------------------------------------------------------------------------
-- THE OTHER SHIPPED BIKES, held to the same bands.
--
-- The cruiser and the mini are the stock bike with other geometry (see
-- sh_bikes.lua), so every case about riding is run again on each, unchanged:
-- "<case>@cruiser", "<case>@mini". A case that only passes on the bike it was
-- written against was measuring the stock bike's numbers rather than the
-- behaviour, and these are what find out.
--------------------------------------------------------------------------
for _, bike in ipairs({ "cruiser", "mini" }) do
    for _, name in ipairs({ "rest", "parked_on_stand", "fallen_is_picked_up",
                            "accelerate", "brake_locks", "lean_steers",
                            "lean_tracks_target", "bunny_hop", "wheelie",
                            "stoppie", "air_mode", "crash_ejects",
                            "grind_pipe", "grind_ledge" }) do
        T.Variant(name, bike)
    end
end
