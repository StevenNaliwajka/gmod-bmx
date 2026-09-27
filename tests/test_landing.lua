--[[--------------------------------------------------------------------------
    Landing on SLOPES. A skatepark is mostly slopes: transitions, banks, the
    faces of quarter pipes. The air assist used to level the bike to WORLD up
    whatever it was about to land on, so a rider with hands off came down
    onto a 30-degree transition 30 degrees off it -- a slap, a bounce, and
    past the landing limit a crash. It now levels toward the surface the bike
    is heading for (sv_air.lua, BMX.LandingNormal).
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

-- A bike `h` units above a `deg` ramp (rising toward +x) at x = x0, level,
-- moving at `vel`, nobody touching the controls. Runs until it lands.
local function dropOnto(deg, x0, h, yaw, vel)
    local sv = F.server({ groundSlope = deg })
    local E = sv.env
    local bike = F.bike(sv)
    local ply = F.scripted(sv, bike)
    sv:run(0.2)
    local surf = math.tan(math.rad(deg)) * x0
    F.place(bike, E.Vector(x0, 0, surf + h), E.Angle(0, yaw, 0))
    bike:GetPhysicsObject():SetVelocity(E.Vector(vel.x, vel.y, vel.z))
    -- It settled on the ramp before being lifted here: take that spin off, or
    -- the test measures the leftover rotation instead of the air control.
    bike:GetPhysicsObject():SetAngleVelocity(E.Vector(0, 0, 0))
    bike.st.angVel, bike.st.prevF = E.Vector(0, 0, 0), nil
    bike.st.grounded, bike.st.airMode = false, false
    F.input(bike, {})
    local off
    sv:run(3, function()
        if bike.st.grounded and bike.st.airSince == 0 and not off then
            local n = E.Vector(-math.sin(math.rad(deg)), 0, math.cos(math.rad(deg)))
            off = math.deg(math.acos(math.max(-1, math.min(1, bike:GetUp():Dot(n)))))
            return true
        end
    end)
    if os.getenv("BMX_TRACE") then print(string.format("    touchdown off %.1f deg, pitch %.1f roll %.1f", off or -1,
        bike:GetAngles().p, bike:GetAngles().r)) end
    sv:run(1)
    return off, bike, sv
end

local function V(x, y, z) return { x = x, y = y, z = z } end

T.test("landing: hands off, down onto a 30-degree transition, it arrives matching the slope", function()
    -- Riding DOWN the ramp's fall line (facing -x): the slope drops away in
    -- front, so a good landing is nose-down by 30.
    local off, bike, sv = dropOnto(30, 400, 70, 180, V(-250, 0, 0))
    T.ok(off, "landed")
    T.between(off or 99, 0, 12, "off the surface at touchdown, deg")
    T.ok(sv.env.IsValid(bike:GetDriver()), "rider aboard")
end)

T.test("landing: across a 25-degree bank, it arrives rolled to match", function()
    -- Moving along +y, across the fall line: the bank tilts the bike's ROLL.
    local off, bike, sv = dropOnto(25, 300, 70, 90, V(0, 250, 0))
    T.ok(off, "landed")
    T.between(off or 99, 0, 12, "off the surface at touchdown, deg")
    T.ok(sv.env.IsValid(bike:GetDriver()), "rider aboard")
end)

T.test("landing: onto flat ground it still levels to flat", function()
    local off, bike, sv = dropOnto(0, 0, 70, 0, V(250, 0, 0))
    T.between(off or 99, 0, 6, "off the ground at touchdown, deg")
    T.ok(sv.env.IsValid(bike:GetDriver()), "rider aboard")
end)

T.test("landing: a barrel roll under way is not wrenched back when the key is let go", function()
    local sv = F.server({ groundSlope = 25 })
    local E = sv.env
    local bike = F.bike(sv)
    F.scripted(sv, bike)
    sv:run(0.2)
    F.place(bike, E.Vector(300, 0, math.tan(math.rad(25)) * 300 + 250), E.Angle(0, 90, 0))
    local p = bike:GetPhysicsObject()
    p:SetVelocity(E.Vector(0, 250, 200))
    p:SetAngleVelocity(E.Vector(0, 0, 0))
    bike.st.angVel, bike.st.prevF = E.Vector(0, 0, 0), nil
    bike.st.grounded, bike.st.airMode = false, false
    F.input(bike, { lean = 1 })
    sv:run(0.12)
    local function spun() return math.abs(bike.st.spinRoll or 0) end
    sv:run(1.5, function() return spun() > math.pi * 0.6 end)
    T.ok(spun() > math.pi * 0.6, "a good way into a barrel roll: " .. math.deg(spun()))
    local before = bike.st.spinRoll
    F.input(bike, {})
    local rate0 = bike.st.angVel:Dot(bike:GetForward())
    sv:run(0.1)
    local rate1 = bike.st.angVel:Dot(bike:GetForward())
    T.ok(rate0 * rate1 > 0, "still turning the same way after letting go")
    T.ok(math.abs(bike.st.spinRoll) >= math.abs(before), "the roll carried on, not back")
end)
