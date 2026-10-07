--[[--------------------------------------------------------------------------
    Which key does what: the usercmd decode in sv_input.lua.

    The headless suite skips this layer ON PURPOSE (a scripted rider writes
    bike.input directly, because injecting usercmds would mean winning a hook
    race every tick). So nothing tested that W pedals, that W in the air is a
    FRONT flip, or that the front brake shifts weight forward. This does, by
    handing the real StartCommand hook a usercmd.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local gmod = require("lib.gmod")
local IN = gmod.IN

-- A usercmd: buttons plus analog axes, and a record of what the hook does to it.
local function cmd(buttons, fwd, side)
    local c = { buttons = buttons or 0, fwd = fwd or 0, side = side or 0, up = 0 }
    function c:GetButtons() return self.buttons end
    function c:SetButtons(b) self.buttons = b end
    function c:GetForwardMove() return self.fwd end
    function c:GetSideMove() return self.side end
    function c:SetForwardMove(v) self.fwd = v end
    function c:SetSideMove(v) self.side = v end
    function c:SetUpMove(v) self.up = v end
    return c
end

local function rig()
    local sv = F.server()
    local bike = F.bike(sv)
    local ply = F.rider(sv, bike)
    local function send(buttons, fwd, side)
        local c = cmd(buttons, fwd, side)
        sv.env.hook.Run("StartCommand", ply, c)
        return c
    end
    return sv, bike, ply, send
end

T.test("W pedals, S brakes the rear, nothing is neutral", function()
    local _, bike, _, send = rig()
    send(IN.FORWARD)
    T.eq(bike.input.throttle, 1, "W throttle")
    T.eq(bike.input.brakeRear, 0, "W does not brake")
    send(IN.BACK)
    T.eq(bike.input.throttle, 0, "S no throttle")
    T.eq(bike.input.brakeRear, 1, "S rear brake")
    send(0)
    T.eq(bike.input.throttle, 0, "released")
    T.eq(bike.input.brakeRear, 0, "released")
end)

T.test("A/D set the lean target: D is right (+), A is left (-)", function()
    local _, bike, _, send = rig()
    send(IN.MOVERIGHT)
    T.eq(bike.input.leanTarget, 1, "D")
    send(IN.MOVELEFT)
    T.eq(bike.input.leanTarget, -1, "A")
end)

T.test("analog axes are scaled by sv_forwardspeed / sv_sidespeed, and clamped", function()
    local sv, bike, ply_, send = rig()
    sv.env.CreateConVar("sv_forwardspeed", "10000")
    sv.env.CreateConVar("sv_sidespeed", "10000")
    ply_:ConCommand("bmx_stick_deadzone 0")   -- the scaling alone, no deadzone
    send(0, 5000, -2500)
    T.near(bike.input.throttle, 0.5, 1e-9, "half stick forward")
    T.near(bike.input.leanTarget, -0.25, 1e-9, "quarter stick left")
    send(0, 99999, 0)
    T.eq(bike.input.throttle, 1, "clamped to 1")
end)

T.test("RMB is weight back on the ground; the front brake is weight forward", function()
    local _, bike, _, send = rig()
    send(IN.ATTACK2 + IN.FORWARD)
    T.eq(bike.input.pitchTarget, 1, "RMB: weight back")
    T.eq(bike.input.throttle, 1, "and you keep pedalling (a wheelie under power)")
    send(IN.ATTACK)
    T.eq(bike.input.brakeFront, 1, "LMB front brake")
    T.near(bike.input.pitchTarget, -0.6, 1e-9, "front brake throws the weight forward")
end)

T.test("in the air, W is nose DOWN (a front flip) and S is nose up", function()
    local _, bike, _, send = rig()
    bike.st.airMode = true
    send(IN.FORWARD)
    T.eq(bike.input.pitchTarget, -1, "W in the air: front flip")
    T.eq(bike.input.throttle, 0, "no drivetrain in the air")
    send(IN.BACK)
    T.eq(bike.input.pitchTarget, 1, "S in the air: back flip")
    T.eq(bike.input.brakeRear, 0, "and not a brake")
end)

T.test("SPACE preloads on press and hops on RELEASE, once", function()
    local _, bike, _, send = rig()
    send(IN.JUMP)
    T.ok(bike.hopHeld, "press starts the preload")
    T.ok(not bike.hopRelease, "press does not hop")
    send(IN.JUMP)
    T.ok(not bike.hopRelease, "holding does not hop")
    send(0)
    T.ok(bike.hopRelease, "release hops")
end)

T.test("sprint and tuck are read, and the engine's own jump/duck are stripped", function()
    local _, bike, _, send = rig()
    local c = send(IN.SPEED + IN.DUCK + IN.JUMP + IN.FORWARD)
    T.ok(bike.input.sprint, "SHIFT sprints")
    T.ok(bike.input.tuck, "CTRL tucks")
    T.eq(gmod.bit.band(c.buttons, IN.JUMP + IN.DUCK), 0,
        "JUMP and DUCK removed so the pod does not try to make the player jump")
    T.eq(c.fwd, 0, "movement zeroed")
end)

T.test("a scripted rider's input is left alone", function()
    local _, bike, ply, send = rig()
    ply.BMXScripted = true
    bike.input.throttle = 0.42
    send(0)
    T.eq(bike.input.throttle, 0.42, "StartCommand bails out for the harness bot")
end)

T.test("someone who is not the driver cannot steer the bike", function()
    local sv, bike = rig()
    local other = sv:player("Passerby")
    other.BMXBike = bike            -- a stale reference, the dangerous case
    sv.env.hook.Run("StartCommand", other, cmd(IN.FORWARD))
    T.eq(bike.input.throttle, 0, "a usercmd from a non-driver changes nothing")
end)

T.test("smoothing glides the lean in and glides it back, never a snap", function()
    -- A keyboard's A and D are all or nothing; the ramp is what turns a tap
    -- into a lean. The return used to be faster (6.5/s, "crisper corner
    -- exits"), and every release was a snap the bike overshot. Now both ways
    -- are the same glide.
    local sv = F.server()
    local B = sv.env.BMX
    local inp = B.BlankInput()
    inp.leanTarget = 1
    B.SmoothInput(inp, 0.1)
    T.near(inp.lean, 0.30, 1e-9, "3.0/s toward the target")
    for _ = 1, 10 do B.SmoothInput(inp, 0.1) end
    T.eq(inp.lean, 1, "reaches it and stops, no overshoot")
    inp.leanTarget = 0
    B.SmoothInput(inp, 0.1)
    T.near(inp.lean, 0.70, 1e-9, "3.0/s back to centre: no faster than in")
end)

T.test("holding W into a hop is not a front flip; pressing it again in the air is", function()
    local _, bike, _, send = rig()
    send(IN.FORWARD)                                 -- pedalling on the ground
    T.eq(bike.input.throttle, 1, "pedalling")
    bike.st.airMode = true                           -- leaves the ground, W still held
    send(IN.FORWARD)
    T.eq(bike.input.pitchTarget, 0, "held-over W is ignored in the air")
    send(IN.FORWARD)
    T.eq(bike.input.pitchTarget, 0, "for as long as it stays held")
    send(0)                                          -- let go...
    send(IN.FORWARD)                                 -- ...and press again
    T.eq(bike.input.pitchTarget, -1, "a fresh press flips")
end)

T.test("a key pressed only after takeoff works at once", function()
    local _, bike, _, send = rig()
    send(0)
    bike.st.airMode = true
    send(IN.BACK)
    T.eq(bike.input.pitchTarget, 1, "S in the air is a backflip straight away")
    send(IN.FORWARD)
    T.eq(bike.input.pitchTarget, -1, "switching keys counts as a fresh press")
end)

--------------------------------------------------------------------------
-- The gamepad deadzone (bmx_stick_deadzone)
--------------------------------------------------------------------------

local function stickRig(dz)
    local sv, bike, ply, send = rig()
    sv.env.CreateConVar("sv_forwardspeed", "10000")
    sv.env.CreateConVar("sv_sidespeed", "10000")
    if dz then ply:ConCommand("bmx_stick_deadzone " .. dz) end
    return sv, bike, ply, send
end

T.test("deadzone: a stick resting a little off centre does not lean the bike", function()
    local _, bike, _, send = stickRig()
    send(0, 0, 600)                         -- 6% right, a worn stick at rest
    T.eq(bike.input.leanTarget, 0, "no lean from 6% of side axis")
    send(0, -800, 0)                        -- 8% back
    T.eq(bike.input.brakeRear, 0, "and no brake from 8% back")
    T.eq(bike.input.throttle, 0, "or throttle")
end)

T.test("deadzone: the default is 0.1, and a rider's own setting is used", function()
    local _, bike, ply, send = stickRig()
    send(0, 0, 1200)
    T.ok(bike.input.leanTarget > 0, "12% is past the default 0.1")
    ply:ConCommand("bmx_stick_deadzone 0.2")
    send(0, 0, 1200)
    T.eq(bike.input.leanTarget, 0, "but inside this rider's 0.2")
end)

T.test("deadzone: past it the travel is rescaled, with no jump at the edge", function()
    local _, bike, _, send = stickRig(0.1)
    send(0, 0, 1001)
    T.between(bike.input.leanTarget, 0, 0.001, "just past the edge is just above zero")
    send(0, 0, 5500)
    T.near(bike.input.leanTarget, 0.5, 1e-9, "55% of travel is half lean: (0.55 - 0.1) / 0.9")
    send(0, 0, 10000)
    T.eq(bike.input.leanTarget, 1, "a full stick is still full lean")
    send(0, 0, -10000)
    T.eq(bike.input.leanTarget, -1, "full left too")
end)

T.test("deadzone: keyboard keys are untouched by it", function()
    local _, bike, _, send = stickRig(0.5)
    send(IN.MOVERIGHT)
    T.eq(bike.input.leanTarget, 1, "D is full lean")
    send(IN.FORWARD)
    T.eq(bike.input.throttle, 1, "W is full throttle")
    send(0, 0, 10000)
    T.eq(bike.input.leanTarget, 1, "and a full-scale axis (what a keyboard sends) is full")
end)

T.test("deadzone: an out-of-range setting is clamped, never a divide by zero", function()
    local _, bike, ply, send = stickRig()
    ply:ConCommand("bmx_stick_deadzone 1")
    send(0, 0, 10000)
    T.finite(bike.input.leanTarget, "finite at a deadzone of 1")
    T.eq(bike.input.leanTarget, 1, "clamped to 0.9, so a full stick still steers")
    ply:ConCommand("bmx_stick_deadzone -3")
    send(0, 0, 300)
    T.near(bike.input.leanTarget, 0.03, 1e-9, "a negative one is no deadzone")
    ply:ConCommand("bmx_stick_deadzone banana")
    send(0, 0, 600)
    T.eq(bike.input.leanTarget, 0, "garbage falls back to the default 0.1")
end)

T.test("deadzone: in the air the same stick rolls and pitches proportionally", function()
    local _, bike, _, send = stickRig(0.1)
    bike.st.airMode = true
    send(0, 5500, 0)
    T.near(math.abs(bike.input.pitchTarget), 0.5, 1e-9, "half pitch from 55% stick")
    T.eq(bike.input.throttle, 0, "no pedalling in the air")
end)

T.test("deadzone: the function itself is odd, monotonic and bounded", function()
    local sv = F.server()
    local dz = sv.env.BMX.StickDeadzone
    local last = -math.huge
    for i = -100, 100 do
        local v = dz(i / 100, 0.15)
        T.ok(v >= last, "monotonic at " .. i)
        T.near(v, -dz(-i / 100, 0.15), 1e-12, "odd at " .. i)
        T.between(v, -1, 1, "bounded at " .. i)
        last = v
    end
    T.eq(dz(2, 0.1), 1, "beyond full scale is still 1")
end)

T.test("deadzone: the client offers the setting, and sends it to the server", function()
    local sv, world = F.server()
    local cl = F.client(world)
    local cv = world.convars.bmx_stick_deadzone
    T.ok(cv, "bmx_stick_deadzone exists")
    T.ok(cv.userinfo, "as userinfo, so the server can read each rider's")
    T.eq(cv:GetFloat(), 0.1, "default 0.1")
end)
