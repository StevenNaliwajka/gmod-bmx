--[[--------------------------------------------------------------------------
    How the ride FEELS: calm, like the Tony Hawk games, not twitchy.

    A rider on the live server: "the bike seems to bounce back and forth
    really quickly", and "it always tries to make me stand up even when going
    up slopes diagonally, so I flip over". A recording of their ride found
    three things, each held here to a number:

      1. Letting go of a lean swung the bike through upright and over the
         other side: 24% overshoot, every tap of A or D.      -> under 10%
      2. Bumps in the floor rolled the bike by themselves, up to 16 degrees
         hands-off, because lean was held against the raw ground normal,
         which a floor's seams swing tick to tick. Holding it against
         gravity (3) fixes this on its own; the smoothed normal steadies
         pitch.                                                  -> under 6
      3. Lean was held square to the GROUND, so across or diagonally up a
         slope the bike leaned with it: 32 degrees off vertical across a
         25-degree bank, 45 across a 35.            -> upright to gravity
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local function worldRoll(E, bike)
    return math.deg((E.BMX.Attitude(bike, E.Vector(0, 0, 1))))
end

T.test("feel: letting go of a full lean comes back to upright without swinging past it", function()
    local sv = F.server()
    local bike = F.bike(sv)
    F.scripted(sv, bike)
    sv:run(0.5)
    F.accelerateTo(sv, bike, 250, 6)
    F.input(bike, { throttle = 0.8, lean = 1 })
    local peak = 0
    sv:run(0.8, function() peak = math.max(peak, bike.st.roll) end)
    F.input(bike, { throttle = 0.8 })
    local over, t, settled = 0, 0, 0
    sv:run(2.5, function()
        t = t + sv.world.dt
        over = math.min(over, bike.st.roll)
        if math.abs(bike.st.roll) > math.rad(2) then settled = t end
    end)
    T.between(math.deg(peak), 20, 45, "leaned in, deg")
    T.between(-over / peak * 100, 0, 10, "overshoot past upright, % of the lean (was 24)")
    T.between(settled, 0, 0.8, "back within 2 degrees of upright after, s")
end)

T.test("feel: riding hands-off over a bumpy floor, the bike does not rock itself", function()
    for _, b in ipairs({ { amp = 1.0, wave = 60 }, { amp = 1.5, wave = 40 }, { amp = 2.0, wave = 80 } }) do
        local sv = F.server({ groundBumps = b })
        local E = sv.env
        local bike = F.bike(sv)
        F.scripted(sv, bike)
        sv:run(0.5)
        F.input(bike, { throttle = 0.7 })
        sv:run(2)
        local worst = 0
        sv:run(4, function() worst = math.max(worst, math.abs(worldRoll(E, bike))) end)
        local label = string.format("bumps %.1f high every %d: worst roll, deg", b.amp, b.wave)
        T.between(worst, 0, 6, label .. " (was up to 16)")
        T.ok(E.IsValid(bike:GetDriver()), "rider aboard")
    end
end)

T.test("feel: across or diagonally up a slope, the bike stays upright to GRAVITY", function()
    for _, d in ipairs({ 15, 25, 35 }) do
        for _, yaw in ipairs({ 90, 45, 135 }) do
            local sv = F.server({ groundSlope = d })
            local E = sv.env
            local bike = F.bike(sv)
            F.scripted(sv, bike)
            sv:run(0.1)
            local a = math.rad(d)
            local n = E.Vector(-math.sin(a), 0, math.cos(a))
            local f = E.Angle(0, yaw, 0):Forward()
            f = (f - n * f:Dot(n)):GetNormalized()
            -- Arriving upright, as from the flat: heading along the slope.
            F.place(bike, n * (F.restHeight(sv) + 1) + E.Vector(0, 0, 3), f:AngleEx(E.Vector(0, 0, 1)))
            bike:GetPhysicsObject():SetVelocity(f * 220)
            bike:GetPhysicsObject():SetAngleVelocity(E.Vector())
            bike.st.angVel, bike.st.prevF = E.Vector(), nil
            F.input(bike, { throttle = 0.8 })
            sv:run(0.5)
            local sum, k, worst = 0, 0, 0
            sv:run(3, function()
                local r = worldRoll(E, bike)
                sum, k, worst = sum + r, k + 1, math.max(worst, math.abs(r))
            end)
            local tag = string.format("%d-degree slope, heading %d", d, yaw)
            T.between(math.abs(sum / k), 0, 2, tag .. ": average lean off vertical, deg (was 15-45)")
            T.between(worst, 0, 10, tag .. ": worst lean off vertical, deg")
            T.ok(E.IsValid(bike:GetDriver()), tag .. ": rider aboard")
        end
    end
end)

T.test("feel: straight up a ramp is riding, not a wheelie", function()
    local sv = F.server({ groundSlope = 25 })
    local E = sv.env
    local bike = F.bike(sv)
    F.scripted(sv, bike)
    local a = math.rad(25)
    local h = F.restHeight(sv)
    F.place(bike, E.Vector(-math.sin(a) * h, 0, math.cos(a) * h), E.Angle(-25, 0, 0))
    F.input(bike, { throttle = 1 })
    local worst = 0
    sv:run(2, function() worst = math.max(worst, math.abs(bike.st.pitch)) end)
    T.between(math.deg(worst), 0, 8, "pitch off the RAMP (what a wheelie is judged on), deg")
    T.ok(not bike.st.manual, "no wheelie being scored")
end)

T.test("feel: pointed up a steep face the balance goes square to the surface", function()
    local sv = F.server()
    local E = sv.env
    local bike = F.bike(sv)
    local C = bike:Cfg()
    local n60 = E.Vector(-math.sin(math.rad(75)), 0, math.cos(math.rad(75)))
    F.place(bike, E.Vector(0, 0, 50), E.Angle(-75, 0, 0))       -- climbing a 75-degree face
    local up = E.BMX.BalanceUp(bike, C, n60)
    T.ok(up:Dot(n60) > 0.99, "square to the face: " .. up:Dot(n60))
    F.place(bike, E.Vector(0, 0, 50), E.Angle(-20, 0, 0))       -- a 20-degree climb
    up = E.BMX.BalanceUp(bike, C, E.Vector(-math.sin(math.rad(20)), 0, math.cos(math.rad(20))))
    T.ok(up.z > 0.999, "upright to gravity: " .. up.z)
end)

--------------------------------------------------------------------------
-- 4. Riding INTO a ledge launched the bike: the suspension ray landed on the
--    ledge's top the tick the fork crossed its edge, and the bump stop threw
--    the bike up -- 226 u/s off a 16-unit ledge, 483 off a 40.   -> no throw
--------------------------------------------------------------------------
local function intoLedge(h)
    local E0 = F.server().env
    local sv = F.server({ solids = { { E0.Vector(300, -200, 0), E0.Vector(900, 200, h) } } })
    local E = sv.env
    local bike = F.bike(sv)
    F.scripted(sv, bike)
    sv:run(0.3)
    F.input(bike, { throttle = 1 })
    bike:GetPhysicsObject():SetVelocity(E.Vector(250, 0, 0))
    local maxVz, maxZ = -1e9, -1e9
    sv:run(2.5, function()
        maxVz = math.max(maxVz, bike:GetPhysicsObject():GetVelocity().z)
        maxZ = math.max(maxZ, bike:GetPos().z)
    end)
    return maxVz, maxZ - F.restHeight(sv), E.IsValid(bike:GetDriver())
end

T.test("feel: riding into a ledge does not throw the bike into the air", function()
    for _, h in ipairs({ 10, 16, 24, 40 }) do
        local vz, rise = intoLedge(h)
        T.between(vz, -1e9, 40, h .. "-unit ledge: fastest upward, u/s (was up to 483)")
        T.between(rise, -1e9, 8, h .. "-unit ledge: highest the bike went, units")
    end
end)

T.test("feel: a kerb a wheel can roll up is rolled up, gently", function()
    local vz, rise, on = intoLedge(3)
    T.between(vz, 0, 60, "3-unit kerb: upward speed rolling onto it, u/s")
    T.between(rise, 1, 8, "and it is up on it")
    T.ok(on, "rider aboard")
end)
