--[[--------------------------------------------------------------------------
    The config, and the derivations written next to its numbers, EXECUTED.

    sh_config.lua is mostly comments explaining where each number came from,
    and several of them record a number that was once wrong by a factor while
    looking carefully worked out: the roll ceiling (twice), the wheelie gains,
    the drag. Each derivation that can be written as arithmetic on the config is
    written as a test here, so a retune that quietly breaks the reasoning fails
    instead of shipping. The bands are the ones the comments themselves state.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local function cfg()
    local sv = F.server()
    return sv.env.BMX.Config, sv.env.BMX, sv
end

-- The MEASURED inertia the config's derivations are written against.
local I_ROLL, I_PITCH = 9299, 11837

T.test("static sag is about half the suspension travel", function()
    local C = cfg()
    local sag = C.Chassis.mass * 600 / 2 / C.Wheel.spring
    T.between(sag / C.Wheel.restLength, 0.35, 0.65, "sag / travel")
end)

T.test("the spring is integrable at 66 Hz against the EFFECTIVE mass", function()
    local C = cfg()
    -- The comment's own check: w*dt against m_eff ~ 20 kg at the patch, not the
    -- 43 kg per-wheel share. 0.71 rang and pumped energy; 0.32 is comfortable.
    local w = math.sqrt(C.Wheel.spring / 19.8)
    T.between(w / 66, 0, 0.5, "w*dt")
end)

T.test("the bump stop is a real stop, not its own explosion", function()
    local C = cfg()
    T.between(C.Wheel.bumpStop / C.Wheel.spring, 4, 12, "bumpStop / spring")
end)

T.test("the lean Kp is above the floor that can meet its own spec", function()
    local C = cfg()
    -- Steady state: Kp*(target - roll) = topple(roll). For the suite's target
    -- (0.6 of maxLean) and the 12 degrees of shortfall the design allows:
    local h = C.Chassis.massCenterExpected.z + C.Wheel.radius
    local target = 0.6 * C.Balance.maxLean
    local roll = target - math.rad(12)
    local topple = C.Chassis.mass * 600 * h * math.sin(roll) / I_ROLL
    local floor = topple / math.rad(12)
    T.ok(C.Balance.leanKp >= floor,
        string.format("leanKp %g is below the %.0f the spec needs", C.Balance.leanKp, floor))
end)

T.test("the lean Kd is past critical for its Kp: a calm ride, not a lively one", function()
    -- It was held near critical (0.6-1.2 on paper), and the real bike, whose
    -- tyres go on righting it after a lean is let go, overshot every release
    -- by 24%. The ride is meant to be calm, so the paper ratio sits well past
    -- 1; tests/test_ride_feel.lua measures what that buys (overshoot < 10%).
    -- The ceiling stops it being so heavy that leaning in turns sluggish.
    local C = cfg()
    local zeta = C.Balance.leanKd / (2 * math.sqrt(C.Balance.leanKp))
    T.between(zeta, 1.3, 2.6, "lean damping ratio, on paper")
end)

T.test("the assist ceiling beats gravity at full lean, with margin", function()
    local C = cfg()
    -- To the CONTACT PATCH (radius below the axle line), not the axle line.
    -- Using 20 instead of 30 once made a ceiling below requirement look like a
    -- 1.5x margin.
    local h = C.Chassis.massCenterExpected.z + C.Wheel.radius
    local need = C.Chassis.mass * 600 * h * math.sin(C.Balance.maxLean) / I_ROLL
    T.between(C.Balance.maxAssistAccel / need, 1.3, 3, "maxAssistAccel / requirement")
end)

T.test("the wheelie aims short of its balance point and gives up past it", function()
    local C, B = cfg()
    local bal = B.WheelieBalance(C)
    T.near(math.deg(bal), 41.2, 0.2, "balance point for the shipped geometry")
    local aim = C.Pitch.holdAim * bal
    T.ok(aim < bal, "the hold aims short of the balance point")
    T.ok(C.Pitch.holdMax > bal, "and gives up only after it")
    T.between(math.deg(aim), 25, 40, "where a wheelie sits")
end)

T.test("the wheelie hold is well damped against the PIVOT inertia", function()
    local C, B, sv = cfg()
    local e = F.bike(sv)
    -- The reason this helper exists: I_pitch + m*d^2 about the axle, not the
    -- free-body I_pitch. (The figures in the comments, 72,574 and 85,990, are
    -- for the old single-box hull; the wheel boxes add real pitch inertia.)
    local m, mc, half = C.Chassis.mass, C.Chassis.massCenterExpected, C.Wheel.wheelbase / 2
    local iEff = B.PivotInertia(e, C, false)
    T.near(iEff, B.IPitch(e) + m * ((mc.x + half) ^ 2 + mc.z ^ 2), 1e-6, "rear axle")
    T.near(B.PivotInertia(e, C, true), B.IPitch(e) + m * ((half - mc.x) ^ 2 + mc.z ^ 2), 1e-6,
        "front axle")
    T.ok(iEff > B.IPitch(e) * 4, "several times the free-body figure")
    -- zeta for the hold against its own restoring gradient (15.4 1/s^2).
    local zeta = C.Pitch.holdKd / (2 * math.sqrt(15.4))
    T.between(zeta, 0.7, 1.3, "wheelie hold damping ratio")
end)

T.test("the stand and foot are stiffer than the bike topples", function()
    local C = cfg()
    local h = C.Chassis.massCenterExpected.z + C.Wheel.radius
    local gradient = C.Chassis.mass * 600 * h / I_ROLL      -- rad/s^2 per rad
    T.ok(C.Stand.kp > gradient * 1.5, string.format(
        "Stand.kp %g against a toppling gradient of %.0f", C.Stand.kp, gradient))
    local zeta = C.Stand.kd / (2 * math.sqrt(C.Stand.kp - gradient))
    T.between(zeta, 0.7, 1.6, "stand damping ratio")
    T.ok(C.Stand.standLean < 0, "parked bikes lean LEFT, onto the stand")
    T.ok(math.abs(C.Stand.standLean) < C.Stand.maxRoll, "and that is not 'fallen'")
end)

T.test("top speed is capped by cadence, not by drag", function()
    local C = cfg()
    local D = C.Drive
    local cadenceTop = D.maxCadence * D.gearRatio * C.Wheel.radius
    T.between(cadenceTop, 300, 380, "cadence-limited top speed, u/s")
    -- Drag alone at that speed must be well under the drive force still
    -- available near the top of the cadence range, or drag sets the speed and
    -- the cadence ceiling is decorative (which is what a drag 18x too big did).
    local drag = D.dragArea * cadenceTop * cadenceTop
    local driveAt90 = D.crankTorque * 0.1 / D.gearRatio / C.Wheel.radius
    T.ok(drag < driveAt90, string.format(
        "drag %.0f at cadence top speed exceeds the drive left at 90%% cadence %.0f",
        drag, driveAt90))
end)

T.test("drag is the real-world figure, without the gravity scaling", function()
    local C = cfg()
    T.near(C.Drive.dragArea, 0.5 * 1.225 * 0.9 * 0.4 / 39.37, 0.0003, "0.5*rho*Cd*A per unit")
end)

T.test("a full-charge hop is about a metre and a half", function()
    local C = cfg()
    local v = C.Hop.popSpeed
    T.between(v * v / (2 * 600), 40, 80, "hop apex, units")
    T.ok(C.Hop.minCharge > 0 and C.Hop.minCharge < 1, "minCharge is a fraction")
end)

T.test("a held ground trick has to outlast what a hop does by accident", function()
    local C = cfg()
    local airtime = 2 * C.Hop.popSpeed / 600
    T.ok(C.Tricks.manualMin > airtime * 0.9,
        "a hop's own nose-up should not score as a wheelie")
    T.ok(C.Tricks.manualGrace < C.Tricks.manualMin, "grace is shorter than the trick")
end)

T.test("the hull puts the mass centre where the config says", function()
    local C = cfg()
    local c = (C.Chassis.hullMin + C.Chassis.hullMax) * 0.5
    T.eq(c.x, C.Chassis.massCenterExpected.x, "COM x")
    T.eq(c.y, C.Chassis.massCenterExpected.y, "COM y")
    T.eq(c.z, C.Chassis.massCenterExpected.z, "COM z")
    T.ok(C.Chassis.hullMin.z > 0, "the hull floor clears the axle line")
end)

T.test("every convar points at a real config field, and its default is that field", function()
    local C = cfg()
    for _, row in ipairs(C.ConVars) do
        local g, k = row[3]:match("^(%w+)%.(%w+)$")
        T.ok(g and C[g] and C[g][k] ~= nil, row[1] .. " -> " .. row[3] .. " exists")
        local want = row[4] and math.deg(C[g][k]) or C[g][k]
        T.near(row[2], want, 1e-9, row[1] .. " default")
    end
end)

T.test("ApplyConVars converts degrees and bumps the revision only on a real change", function()
    local C, B, sv = cfg()
    local rev = B.ConfigRevision
    B.ApplyConVars()
    T.eq(B.ConfigRevision, rev, "nothing moved, no bump")

    sv.env.GetConVar("bmx_max_lean"):SetString("30")
    B.ApplyConVars()
    T.near(C.Balance.maxLean, math.rad(30), 1e-12, "degrees in, radians stored")
    T.eq(B.ConfigRevision, rev + 1, "a real change bumps it once")
    B.ApplyConVars()
    T.eq(B.ConfigRevision, rev + 1, "and not again")
end)

T.test("ValidatePhysics rejects every kind of override that would go nowhere", function()
    local _, B, sv = cfg()
    T.ok(B.ValidatePhysics("a", nil), "no physics is fine")
    T.ok(B.ValidatePhysics("a", { Wheel = { radius = 12 } }), "a real field")
    T.ok(not B.ValidatePhysics("b", { Wheel = { raduis = 12 } }), "typo'd key")
    T.ok(not B.ValidatePhysics("c", { Wheels = { radius = 12 } }), "typo'd group")
    T.ok(not B.ValidatePhysics("d", { Wheel = 12 }), "group that is not a table")
    T.eq(#sv.errors, 3, "each rejection is a loud error")
    T.ok(sv.errors[1]:find("raduis"), "and names the bad key: " .. sv.errors[1])
end)

T.test("ConfigFor shares the base by reference, and merges an override into a copy", function()
    local C, B = cfg()
    T.ok(B.ConfigFor({}) == C, "no physics: the base itself, no copy")
    local def = { physics = { Wheel = { radius = 12 }, Tricks = { manualMin = 2 } } }
    local m = B.ConfigFor(def)
    T.ok(m ~= C, "a copy")
    T.eq(m.Wheel.radius, 12, "the override")
    T.eq(m.Wheel.spring, C.Wheel.spring, "everything else from the base")
    T.eq(m.Tricks.manualMin, 2, "the new Tricks group merges like the rest")
    T.eq(C.Wheel.radius, 10, "the base is untouched")
    T.ok(B.ConfigFor(def) == m, "cached while the base has not moved")
    B.ConfigRevision = B.ConfigRevision + 1
    T.ok(B.ConfigFor(def) ~= m, "rebuilt after it has")
end)

T.test("every config group the merge knows is dumped by bmx_dump_config", function()
    local _, B, sv = cfg()
    local ply = sv:player("Tuner")
    sv:command("bmx_dump_config", ply)
    local joined = table.concat(ply._chat, "\n")
    for _, g in ipairs(B.ConfigGroups) do
        T.ok(joined:find("C." .. g .. " = {", 1, true), "dump includes " .. g)
    end
    T.ok(joined:find("manualMin", 1, true), "including the fields")
end)
