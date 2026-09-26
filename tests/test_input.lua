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
    local sv, bike, _, send = rig()
    sv.env.CreateConVar("sv_forwardspeed", "10000")
    sv.env.CreateConVar("sv_sidespeed", "10000")
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

T.test("smoothing ramps the lean and returns to centre faster", function()
    local sv = F.server()
    local B = sv.env.BMX
    local inp = B.BlankInput()
    inp.leanTarget = 1
    B.SmoothInput(inp, 0.1)
    T.near(inp.lean, 0.42, 1e-9, "4.2/s toward the target")
    for _ = 1, 10 do B.SmoothInput(inp, 0.1) end
    T.eq(inp.lean, 1, "reaches it and stops, no overshoot")
    inp.leanTarget = 0
    B.SmoothInput(inp, 0.1)
    T.near(inp.lean, 0.35, 1e-9, "6.5/s back to centre")
end)
