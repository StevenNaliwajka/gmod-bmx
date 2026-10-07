--[[--------------------------------------------------------------------------
    The brake cable and the rig check (G01).

    The competitor's bug was a cable left behind on the frame when the bars
    turned. The procedural bike cannot have THAT bug (there is no skin), but a
    cable computed from the wrong transform would look identical, so the
    geometry is checked: the lever end follows the bars at any angle, the gyro
    and the brake end do not move, and the loop between lever and gyro is the
    same length throughout a full barspin, so nothing winds up.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local function clientBMX()
    local sv, world = F.server()
    local cl = F.client(world)
    return cl, sv, world, cl.env.BMX, cl.env
end

-- Stock-ish rig, in world axes: forward +X, up +Z, right -Y.
local function rig(E)
    local fwd, up = E.Vector(1, 0, 0), E.Vector(0, 0, 1)
    local right = fwd:Cross(up)
    local headT = E.Vector(12.5, 0, 17.5)
    local d = E.Vector(-2, 0, 8.5)          -- bar centre from the head tube top
    local brake = E.Vector(-6, 0, 10)
    return fwd, right, up, headT, d, brake
end

local function cable(B, E, steer)
    local fwd, right, up, headT, d, brake = rig(E)
    local bars = B.SteeredBars(headT, fwd, right, up, steer, d, 1)
    return B.BrakeCable(bars, headT, up, brake, 1, 8), bars
end

local function length(pts)
    local n = 0
    for i = 1, #pts - 1 do n = n + pts[i]:Distance(pts[i + 1]) end
    return n
end

-- Where the lever must be, worked out independently of the code under test:
-- the steer-0 lever offset from the head tube, turned about the vertical by
-- the steer angle (turning right is a negative yaw in Source's axes).
local function expectedLever(B, E, steer)
    local c0 = cable(B, E, 0)
    local _, _, _, headT = rig(E)
    local o = c0.lever - headT
    local c, s = math.cos(steer), math.sin(steer)
    return headT + E.Vector(o.x * c + o.y * s, -o.x * s + o.y * c, o.z)
end

T.test("cable: the lever end stays on the bars at steer +-90 degrees", function()
    local _, _, _, B, E = clientBMX()
    for _, deg in ipairs({ -90, 90 }) do
        local steer = math.rad(deg)
        local c = cable(B, E, steer)
        T.ok(c.bar[1]:Distance(expectedLever(B, E, steer)) < 0.5,
            deg .. " degrees: cable starts " .. c.bar[1]:Distance(expectedLever(B, E, steer)) .. " u off the lever")
        T.ok(c.lever:Distance(c.bar[1]) < 1e-9, "the polyline starts at the lever")
    end
end)

T.test("cable: through a full barspin the lever follows and the frame ends do not move", function()
    local _, _, _, B, E = clientBMX()
    local rest, restBars = cable(B, E, 0)
    local loop = length(rest.bar)
    local restGrip = rest.lever:Distance(restBars.barR)
    for deg = -720, 720, 15 do
        local steer = math.rad(deg)
        local c, bars = cable(B, E, steer)
        T.ok(c.bar[1]:Distance(expectedLever(B, E, steer)) < 0.5, deg .. ": lever end on the bars")
        T.ok(c.gyro:Distance(rest.gyro) < 1e-9, deg .. ": the gyro does not turn with the bars")
        T.ok(c.brake:Distance(rest.brake) < 1e-9, deg .. ": the brake end is on the frame")
        T.ok(c.bar[#c.bar]:Distance(c.gyro) < 1e-9, deg .. ": the loop ends on the gyro")
        T.ok(c.frame[1]:Distance(c.gyro) < 1e-9 and c.frame[#c.frame]:Distance(c.brake) < 1e-9,
            deg .. ": the frame run joins gyro to brake")
        -- Nothing winds up: the loop is the same length at every angle, and a
        -- bar-end that stays on its grip is the same distance from the lever.
        T.near(length(c.bar), loop, 1e-6, deg .. ": loop length")
        T.near(c.lever:Distance(bars.barR), restGrip, 1e-6, deg .. ": lever to grip")
    end
end)

T.test("cable: the loop never reaches back through the head tube", function()
    local _, _, _, B, E = clientBMX()
    local _, _, _, headT = rig(E)
    local axisX, axisY = headT.x, headT.y
    for deg = 0, 360, 15 do
        local c = cable(B, E, math.rad(deg))
        for i, p in ipairs(c.bar) do
            -- Horizontal distance from the head tube axis: the cable hangs
            -- out at the bars' radius and comes in to the gyro on the axis,
            -- never past it to the far side (which is what winds round).
            local r = math.sqrt((p.x - axisX) ^ 2 + (p.y - axisY) ^ 2)
            local lever = c.bar[1]
            local rl = math.sqrt((lever.x - axisX) ^ 2 + (lever.y - axisY) ^ 2)
            T.ok(r <= rl + 1e-6, string.format("%d: point %d is %.2f from the axis, lever %.2f", deg, i, r, rl))
            -- and on the lever's side of it
            local dot = (p.x - axisX) * (lever.x - axisX) + (p.y - axisY) * (lever.y - axisY)
            T.ok(dot >= -1e-6, deg .. ": point " .. i .. " stays on the lever's side of the head tube")
        end
    end
end)

T.test("cable: the drawn bike has one, joined end to end, and only the lever end moves with the bars", function()
    local sv, world = F.server()
    local bike = F.bike(sv)
    local cl = F.client(world)
    local E = cl.env
    local cb = cl:clientEntity("bmx_base")
    cb:SetPos(bike:GetPos())
    cb:SetAngles(bike:GetAngles())
    cb:SetGrounded(true)

    local k = cb:Cfg().Wheel.wheelbase / 39
    local W = 0.35 * k
    local function chain(steer)
        cb:SetSteer(steer)
        cl.lines, cl.beams, cl.drawnModels, cl.boxes3d = 0, {}, 0, 0
        cb:Draw()
        local out = {}
        for _, b in ipairs(cl.beams) do
            if math.abs(b.w - W) < 1e-9 then out[#out + 1] = b end
        end
        return out
    end

    local rest = chain(0)
    T.eq(#rest, 10, "two runs of five segments")
    for i = 1, #rest - 1 do
        if i ~= 5 then T.ok(rest[i].b:Distance(rest[i + 1].a) < 1e-9, "segment " .. i .. " joins the next") end
    end
    local gyro, brake = rest[5].b, rest[10].b
    local max = cb:Cfg().Balance.maxSteer
    for _, steer in ipairs({ max, -max }) do
        local c = chain(steer)
        T.eq(#c, 10, "still 10 segments")
        T.ok(c[5].b:Distance(gyro) < 1e-6, "gyro fixed at steer " .. steer)
        T.ok(c[10].b:Distance(brake) < 1e-6, "brake end fixed at steer " .. steer)
        T.ok(c[1].a:Distance(rest[1].a) > 0.5, "the lever end moved with the bars at steer " .. steer)
        T.near(c[1].a:Distance(gyro), rest[1].a:Distance(gyro), 1e-6, "same loop span at steer " .. steer)
    end
end)

T.test("cable: bmx_debug 2 draws each part's axes, bmx_debug 1 does not", function()
    local sv, world = F.server()
    local bike = F.bike(sv)
    local cl = F.client(world)
    local E = cl.env
    local cb = cl:clientEntity("bmx_base")
    cb:SetPos(bike:GetPos())
    cb:SetGrounded(true)
    local function lines(level)
        E.GetConVar("bmx_debug"):SetString(tostring(level))
        cl.lines, cl.beams, cl.drawnModels, cl.boxes3d = 0, {}, 0, 0
        cb:Draw()
        return cl.lines
    end
    local one = lines(1)
    local two = lines(2)
    T.eq(two - one, 12, "four parts, three axes each")
end)

-- ---------------------------------------------------------- the rig check

local GOOD = { bars = "bars", fork = "fork", frontWheel = "wf", rearWheel = "wr", cranks = "cr" }

local function copy(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end

T.test("bones: a complete table, with or without pedals, and no table at all, are accepted", function()
    local sv = F.server()
    local B = sv.env.BMX
    T.eq(B.ValidateBones("t", nil), true, "no table: not checked")
    T.eq(B.ValidateBones("t", GOOD), true, "the five required")
    local g = copy(GOOD); g.pedalL = "pl"; g.pedalR = "pr"
    T.eq(B.ValidateBones("t", g), true, "and the pedals")
    T.eq(#sv.errors, 0, "nothing reported")
end)

T.test("bones: an unknown key is a loud error, naming it", function()
    local sv = F.server()
    local g = copy(GOOD); g.handlebars = "bars"
    T.eq(sv.env.BMX.ValidateBones("typo", g), false, "rejected")
    T.eq(#sv.errors, 1, "one error")
    T.ok(sv.errors[1]:find("handlebars", 1, true) and sv.errors[1]:find("typo", 1, true),
        "names the key and the bike: " .. sv.errors[1])
end)

T.test("bones: a missing required bone, an empty name or a non-table is rejected", function()
    local sv = F.server()
    local B = sv.env.BMX
    local g = copy(GOOD); g.cranks = nil
    T.eq(B.ValidateBones("a", g), false, "missing cranks")
    T.ok(sv.errors[1]:find("missing required bone cranks", 1, true), sv.errors[1])
    g = copy(GOOD); g.fork = ""
    T.eq(B.ValidateBones("b", g), false, "empty name")
    T.eq(B.ValidateBones("c", "bars"), false, "not a table")
    T.eq(#sv.errors, 3, "each reported")
end)

T.test("bones: the registry runs the check at registration", function()
    local sv = F.server()
    local B = sv.env.BMX
    local g = copy(GOOD); g.bogus = "x"
    B.RegisterBike("rigtest", { printName = "Rig test", bones = g })
    T.ok(#sv.errors >= 1 and sv.errors[#sv.errors]:find("bogus", 1, true), "the typo was caught")
    local before = #sv.errors
    B.RegisterBike("rigfine", { printName = "Rig fine", bones = copy(GOOD) })
    T.eq(#sv.errors, before, "a good table adds no error")
end)

T.test("bones: the shipped bikes still register clean (they carry no bones table)", function()
    local sv = F.server()
    T.eq(#sv.errors, 0, table.concat(sv.errors, " | "))
end)
