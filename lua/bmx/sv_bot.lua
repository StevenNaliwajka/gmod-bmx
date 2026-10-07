--[[--------------------------------------------------------------------------
    bmx/sv_bot.lua

    A bot that rides a BMX and does tricks.

        bmx_bot_spawn [bike]     a bot rider on a bike where you are looking
        bmx_bot_remove           every bot rider gone (and their ramps)
        bmx_bot_trick <name>     the bots do that trick next
        bmx_bot_status           what each bot has tried and landed

        bmx_bot_name   "Peter Griffin"   what the bot is called
        bmx_bot_model  ""                its player model; empty keeps the default

    THE MODEL IS NOT IN THIS ADDON. The addon is public and ships no content
    that is not its own (README, "Licence and content"). A server that wants
    the bot to look like somebody mounts that player model itself -- from the
    Workshop, say -- and points bmx_bot_model at it.

    HOW IT RIDES. The bot is an ordinary bot player sitting on an ordinary
    bike. It does not touch the simulation: it writes the same bike.input a
    rider's keys produce (exactly as the headless harness does, through the
    BMXScripted seam in sv_input.lua), so whatever it can do, a player can.
    Steering is the bike's own: lean, and the lean derives the steer.

    HOW IT DOES TRICKS. Each trick is a coroutine (Bot.Tricks) that finds
    somewhere to do it, rides there, does it, and reports what the ADDON'S OWN
    SCORING said happened -- BMX_TricksLanded and BMX_ComboEnded -- rather than
    what the bot thinks it did. An air trick needs a launch: the bot looks for
    a ramp in the world first (BMX.FindLaunch: a map's kicker, a funbox, a prop
    somebody tilted) and only if there is none puts its own kicker down.

    THE AIR CONTROLLER is the interesting part. A flip is scored as a full
    turn of the spin integral, and landed only if the wheels come down first;
    so the bot predicts when it will touch down and paces the rotation to
    finish just past one turn as it gets there, then brakes the spin.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Bot = BMX.Bot or {}
local Bot = BMX.Bot

Bot.brains = Bot.brains or {}

local cvName  = CreateConVar("bmx_bot_name", "Peter Griffin", FCVAR_ARCHIVE,
    "BMX: what a bot rider spawned by bmx_bot_spawn is called.")
local cvModel = CreateConVar("bmx_bot_model", "", FCVAR_ARCHIVE,
    "BMX: player model for bot riders (empty = the default). The server must have it mounted.")

local TAU = math.pi * 2
local UP = Vector(0, 0, 1)

-- The order the show runs in, and the names the scoring uses.
Bot.TrickList = { "Bunny Hop", "Wheelie", "Stoppie", "Combo", "Backflip",
                  "Frontflip", "Barrel Roll", "360", "Crank Grind", "Double Peg Grind",
                  "Tailwhip", "Barspin", "Superman", "Superman Backflip" }

Bot.Config = {
    flipSpeed  = 340,   -- u/s at a launch's foot, for the air tricks
    stageBack  = 750,   -- u behind a launch's foot where the run at it starts
    margin     = 0.12,  -- rad past a full turn the air controller aims for
    settle     = 0.15,  -- s before touchdown the spin should be finished
    spinGain   = 9,     -- 1/s, rate loop gain in the air
    ahead      = 1.15,  -- how far ahead of an on-time spin to run
    brakeShare = 1.0,   -- of an axis's full braking the pacing counts on
    attempts   = 3,     -- per trick, before the bot gives up on it
}

--------------------------------------------------------------------------
-- Brains
--------------------------------------------------------------------------
local Brain = {}
Brain.__index = Brain

function Bot.Attach(ply, bike, opts)
    opts = opts or {}
    local b = setmetatable({
        ply = ply, bike = bike, home = opts.home or bike:GetPos(),
        scored = {}, combos = {}, results = {}, log = {}, props = {},
        allowSpawnRamp = opts.allowSpawnRamp ~= false,
        allowFindRamp  = opts.allowFindRamp ~= false,
        quiet = opts.quiet or false,
        wasScripted = ply.BMXScripted,
    }, Brain)
    ply.BMXScripted = true
    ply.BMXBotBrain = b
    Bot.brains[ply] = b
    b:set({})
    return b
end

function Bot.Detach(b)
    if not b then return end
    for _, e in ipairs(b.props) do SafeRemoveEntity(e) end
    b.props = {}
    if IsValid(b.bike) and b.bike.input then b:set({}) end
    if IsValid(b.ply) then
        b.ply.BMXBotBrain = nil
        b.ply.BMXScripted = b.wasScripted
    end
    Bot.brains[b.ply] = nil
    b.job = nil
end

function Brain:say(msg)
    self.log[#self.log + 1] = string.format("%.2f %s", CurTime(), msg)
    if #self.log > 200 then table.remove(self.log, 1) end
end

-- Write the bike's input the way a rider's keys would. Omitted is neutral.
function Brain:set(t)
    local i = self.bike.input
    if not i then return end
    i.throttle    = t.throttle   or 0
    i.brakeRear   = t.brakeRear  or 0
    i.brakeFront  = t.brakeFront or 0
    i.leanTarget  = t.lean       or 0
    i.pitchTarget = t.pitch      or 0
    i.tuck        = t.tuck       or false
    i.sprint      = t.sprint     or false
    i.wheelieMod  = t.wheelieMod or false
    -- Frame and bar spins and style poses (sv_tricks.lua).
    i.whip        = t.whip or 0
    i.bar         = t.bar or 0
    i.pose        = t.pose
end

function Brain:st() return self.bike.st or {} end
function Brain:speed() return self:st().speed or 0 end
function Brain:yaw() return self.bike:GetAngles().y end
function Brain:riding() return IsValid(self.bike) and self.bike:GetDriver() == self.ply end

-- What the scoring paid since `t0`, by trick name.
function Brain:scoredSince(t0, name)
    for _, s in ipairs(self.scored) do
        if s.t >= t0 and (not name or s.name == name) then return s end
    end
end
function Brain:comboSince(t0)
    for _, c in ipairs(self.combos) do
        if c.t >= t0 and c.landed and c.n >= 2 then return c end
    end
end

hook.Add("BMX_TricksLanded", "BMX.Bot.Score", function(ent, driver, tricks)
    local b = IsValid(driver) and driver.BMXBotBrain
    if not b or b.bike ~= ent then return end
    for _, t in ipairs(tricks) do
        b.scored[#b.scored + 1] = { t = CurTime(), name = t.name, count = t.count, points = t.points }
        b:say("scored " .. t.name)
    end
end)

hook.Add("BMX_ComboEnded", "BMX.Bot.Combo", function(ent, driver, c, landed, bonus)
    local b = IsValid(driver) and driver.BMXBotBrain
    if not b or b.bike ~= ent then return end
    b.combos[#b.combos + 1] = { t = CurTime(), n = c.n, landed = landed, bonus = bonus }
end)

--------------------------------------------------------------------------
-- Riding. All of these run inside a trick's coroutine and yield a tick.
--------------------------------------------------------------------------
local function tick() coroutine.yield() end

-- Lean to bring the bike's heading to `want` (degrees). The bike turns the
-- way it leans (D, +, is right, and right is yaw going DOWN), so the lean is
-- against the heading error, damped by the yaw rate so it does not weave.
function Brain:steerLean(want)
    local err = math.AngleDifference(want, self:yaw())
    local w = self:st().angVel
    local yawRate = w and math.deg(w.z) or 0
    return math.Clamp(-err / 25 + yawRate / 260, -1, 1), err
end

-- Throttle and brake toward a target speed.
function Brain:pace(target)
    local v = self:speed()
    if v < target then return math.Clamp((target - v) / 45 + 0.3, 0, 1), 0 end
    if v > target + 40 then return 0, 0.6 end
    return 0.15, 0
end

-- Heading that brings the bike onto the line through `a` along `dir`.
function Brain:lineHeading(a, dir)
    local p = self.bike:GetPos()
    local rel = p - a
    local lateral = dir.x * rel.y - dir.y * rel.x       -- + is left of the line
    local lineYaw = math.deg(math.atan2(dir.y, dir.x))
    return lineYaw - math.Clamp(lateral * 0.5, -35, 35), lateral, rel:Dot(dir)
end

-- Ride along a line at `speed` until `done()` says so or `timeout` passes.
-- `extra(t)` may return fields to merge into the input (tuck, pitch, ...).
function Brain:rideLine(a, dir, speed, done, timeout, extra)
    local t0 = CurTime()
    while CurTime() - t0 < (timeout or 10) do
        if not self:riding() then return false, "off the bike" end
        local want, lateral, along = self:lineHeading(a, dir)
        local lean = self:steerLean(want)
        local thr, brk = self:pace(speed)
        local inp = { throttle = thr, brakeRear = brk, lean = lean }
        if extra then for k, v in pairs(extra(CurTime() - t0, along, lateral) or {}) do inp[k] = v end end
        self:set(inp)
        if done and done(along, lateral) then return true end
        tick()
    end
    return false, "timed out"
end

-- Ride to a point and stop near it.
function Brain:rideTo(p, speed, radius, timeout)
    local t0 = CurTime()
    while CurTime() - t0 < (timeout or 15) do
        if not self:riding() then return false, "off the bike" end
        local d = p - self.bike:GetPos()
        d.z = 0
        local dist = d:Length()
        if dist < (radius or 60) then
            self:set({ brakeRear = 1 })
            return true
        end
        local want = math.deg(math.atan2(d.y, d.x))
        local lean, err = self:steerLean(want)
        -- A big turn is taken slowly: lean-steering cannot turn round on the
        -- spot at speed, and walking pace steers directly.
        local target = math.min(speed, math.abs(err) > 90 and 60 or (math.abs(err) > 40 and 140 or speed))
        if dist < 250 then target = math.min(target, 90 + dist * 0.4) end
        local thr, brk = self:pace(target)
        self:set({ throttle = thr, brakeRear = brk, lean = lean })
        tick()
    end
    return false, "could not reach the spot"
end

-- Stop and stand still.
function Brain:stop(timeout)
    local t0 = CurTime()
    while self:speed() > 10 and CurTime() - t0 < (timeout or 4) do
        self:set({ brakeRear = 1, brakeFront = 0.3 })
        tick()
    end
    self:set({})
end

function Brain:wait(s)
    local t0 = CurTime()
    while CurTime() - t0 < s do tick() end
end

-- Wait until the bike has been on the ground (or off the bike) for `hold`.
function Brain:waitLanded(hold, timeout)
    local t0, since = CurTime(), nil
    while CurTime() - t0 < (timeout or 4) do
        if not self:riding() then return false end
        if self:st().grounded and not self:st().airMode then
            since = since or CurTime()
            if CurTime() - since >= hold then return true end
        else
            since = nil
        end
        tick()
    end
    return false
end

-- A straight run from here: the heading with the most clear ground ahead,
-- preferring the way the bike already points. Returns a unit dir and length.
function Brain:openRun(need)
    local p = self.bike:GetPos()
    local opts = { filter = self:filter() }
    local cur = self:yaw()
    local best, bestLen = nil, 0
    for k = 0, 11 do
        local yaw = cur + (k % 2 == 0 and 1 or -1) * math.floor((k + 1) / 2) * 30
        local dir = BMX.Launch.DirOf(yaw)
        local len = BMX.Launch.Runway(p, dir, need + 100, opts)
        if len >= need then return dir, len end
        if len > bestLen then best, bestLen = dir, len end
    end
    return best, bestLen
end

function Brain:filter()
    local f = { self.bike, self.ply }
    if IsValid(self.bike) and self.bike.GetPod then f[#f + 1] = self.bike:GetPod() end
    for _, e in ipairs(self.props) do if e.BMXRail then f[#f + 1] = e end end
    return f
end

-- Face along `dir` and pull away along it from where the bike is now.
function Brain:lineUp(dir, speed, dist)
    local a = self.bike:GetPos()
    return self:rideLine(a, dir, speed, function(along) return along >= (dist or 0) end, 8)
end

--------------------------------------------------------------------------
-- In the air: pace one axis's spin to finish just past a full turn as the
-- bike touches down, then brake it.
--------------------------------------------------------------------------

-- Seconds until the bike's wheels reach the ground below its flight path.
function Brain:timeToLand()
    local phys = self.bike:GetPhysicsObject()
    if not IsValid(phys) then return 0 end
    local p, v = self.bike:GetPos(), phys:GetVelocity()
    local g = physenv.GetGravity():Length()
    local floor = self.bike:Cfg().Wheel.radius
    local t = 0.3
    for _ = 1, 3 do
        local at = p + Vector(v.x, v.y, 0) * t
        local tr = util.TraceLine({ start = at + UP * 64, endpos = at - UP * 2000,
                                    filter = self:filter(), mask = MASK_SOLID })
        local gz = tr.Hit and tr.HitPos.z or (p.z - 2000)
        local h = p.z - floor - gz
        -- z(t) = h + vz t - g t^2 / 2 = 0
        local disc = v.z * v.z + 2 * g * math.max(h, 0)
        t = (v.z + math.sqrt(disc)) / g
    end
    return t
end

local AXES = {
    pitch = { spin = "spinPitch", input = "pitch",  accel = "pitchAccel",
              rate = function(st, e) return (st.angVel or vector_origin):Dot(e:GetRight()) end },
    roll  = { spin = "spinRoll",  input = "lean",   accel = "rollAccel",
              rate = function(st, e) return (st.angVel or vector_origin):Dot(e:GetForward()) end },
    yaw   = { spin = "spinYaw",   input = "lean",   accel = "yawAccel", wheelieMod = true,
              rate = function(st, e) return (st.angVel or vector_origin):Dot(e:GetUp()) end },
}
Bot.Axes = AXES

-- The input in -1..1 that drives an axis's rate toward `want`, given the
-- air model: a = u * accel * tuck - (damping / tuck) * w.
function Bot.SpinInput(want, w, A, accel, tuck)
    local k = tuck and 1.35 or 1
    local damp = A.damping / k
    local need = damp * want + Bot.Config.spinGain * (want - w)
    return math.Clamp(need / (accel * k), -1, 1)
end

-- The pacing: how fast the axis should be spinning with `remaining` radians
-- to go and `tLeft` seconds to do them in.
--
-- TWO LIMITS, and the second is the one that lands it. Spinning just fast
-- enough to finish on time front-loads nothing, falls behind while the spin
-- builds, and arrives at full rate -- and a bike at 10 rad/s cannot stop in
-- the few degrees left, so it went 45 degrees past and came down on its back
-- wheel at 82 (the offline plant, first try). So the rate is also capped at
-- what can be braked to nothing in the rotation remaining, sqrt(2 a r), and
-- the schedule runs `ahead` of time.
function Bot.SpinPace(remaining, tLeft, maxRate, brakeAccel)
    if remaining <= 0 then return 0 end
    local onTime = remaining / math.max(tLeft, 0.05) * Bot.Config.ahead
    local stoppable = math.sqrt(2 * (brakeAccel or math.huge) * remaining)
    return math.min(onTime, stoppable, maxRate)
end

-- Fly one air trick. `axis` is pitch / roll / yaw, `sign` its direction
-- (+1 nose up / right / left), `target` the spin to finish on, radians.
function Brain:flySpin(axis, sign, target, pose)
    local Ax = AXES[axis]
    local A = self.bike:Cfg().Air
    local accel = A[Ax.accel]
    local maxRate = accel * 1.35 / (A.damping / 1.35) * 0.95
    local landedFor = 0
    while true do
        if not self:riding() then return false end
        local st = self:st()
        if st.grounded and not st.airMode then
            landedFor = landedFor + engine.TickInterval()
            if landedFor > 0.1 then return true end
        else
            landedFor = 0
        end
        local spun = (st[Ax.spin] or 0) * sign
        local remaining = target - spun
        local w = Ax.rate(st, self.bike) * sign
        local tLeft = self:timeToLand() - Bot.Config.settle
        local want = Bot.SpinPace(remaining, tLeft, maxRate, accel * Bot.Config.brakeShare)
        local u = Bot.SpinInput(want, w, A, accel, true) * sign
        if remaining <= 0 then
            -- Turned enough: brake the spin, never reverse it (that would
            -- take back rotation the scoring has already counted).
            u = sign * math.Clamp(-Bot.Config.spinGain * 2 * w / accel, -1, 0)
        end
        local inp = { tuck = remaining > 0 }
        -- A pose to hold during the spin: pose(spun, target) -> a pose name
        -- or nil (the Superman Backflip's superman).
        if pose then inp.pose = pose(spun, target) end
        inp[Ax.input] = u
        if Ax.wheelieMod then inp.wheelieMod = true end
        self:set(inp)
        tick()
    end
end

--------------------------------------------------------------------------
-- Launches: find one in the world, or put a kicker down.
--------------------------------------------------------------------------
function Brain:launch()
    local here = self.bike:GetPos()
    if self.allowFindRamp then
        local l, n = BMX.FindLaunch(here, { filter = self:filter() })
        if l then
            self:say(string.format("found a launch: %.0f u high, %.0f deg, %.0f u away (%d seen)",
                l.height, math.deg(l.angle), (l.foot - here):Length(), n))
            return l
        end
        self:say("no launch in the world here (" .. n .. " seen)")
    end
    if not self.allowSpawnRamp then return nil end
    local C = BMX.Launch.Config
    local opts = { filter = self:filter(), config = setmetatable({ runup = Bot.Config.stageBack }, { __index = C }) }
    local foot, yaw = BMX.Launch.PlanKicker(here, opts)
    if not foot then return nil end
    local e, l = BMX.SpawnKicker(foot, yaw)
    if not e then return nil end
    self.props[#self.props + 1] = e
    self:say(string.format("put a kicker down: %.0f u high", l.height))
    return l
end

-- Ride at a launch and leave its lip with a hop. Returns true once airborne.
function Brain:hitLaunch(l, speed)
    local back = math.min(Bot.Config.stageBack,
        BMX.Launch.Runway(l.foot, -l.dir, Bot.Config.stageBack + 50, { filter = self:filter() }) - 30)
    if back < 300 then return false, "no room to ride at it" end
    local stage = l.foot - l.dir * back
    local ok, why = self:rideTo(stage, 200, 70, 20)
    if not ok then return false, why end
    self:stop(3)
    -- Ride the line through the foot and the lip; preload the hop so it is
    -- released on the lip, and go once the wheels leave the ramp.
    local C = self.bike:Cfg()
    local lipAlong = (l.lip - l.foot):Dot(l.dir)
    local held, released = false, false
    local airborne = false
    ok, why = self:rideLine(l.foot, l.dir, speed, function(along)
        local st = self:st()
        if released and (st.airMode or not st.grounded) then airborne = true return true end
        local toLip = lipAlong - along
        if not held and toLip <= self:speed() * (C.Hop.chargeTime + 0.03) then
            self.bike.hopHeld, self.bike.hopCharge, held = true, 0, true
        end
        if held and not released and toLip <= 8 then
            self.bike.hopRelease, released = true, true
        end
        return false
    end, 14)
    if not airborne then return false, why or "never left the lip" end
    return true
end

--------------------------------------------------------------------------
-- The tricks. Each returns ok, why.
--------------------------------------------------------------------------
Bot.Tricks = {}
local T = Bot.Tricks

T["Bunny Hop"] = function(b)
    local dir, len = b:openRun(600)
    if not dir or len < 400 then return false, "no room" end
    local ok, why = b:lineUp(dir, 200)
    if not ok then return false, why end
    local a = b.bike:GetPos()
    b:rideLine(a, dir, 200, function() return b:speed() >= 185 end, 6)
    local t0 = CurTime()
    b.bike.hopHeld, b.bike.hopCharge = true, 0
    b:rideLine(a, dir, 200, function() return CurTime() - t0 >= b.bike:Cfg().Hop.chargeTime + 0.05 end, 1)
    b.bike.hopRelease = true
    local flew = false
    b:rideLine(a, dir, 200, function()
        if b:st().airMode or not b:st().grounded then flew = true end
        return flew and b:st().grounded and not b:st().airMode
    end, 3)
    if not flew then return false, "did not leave the ground" end
    if not b:waitLanded(0.5) then return false, "did not land on it" end
    b:say("landed a Bunny Hop")
    return true
end

T["Wheelie"] = function(b)
    local dir, len = b:openRun(800)
    if not dir or len < 600 then return false, "no room" end
    local t0 = CurTime()
    b:lineUp(dir, 150)
    local a = b.bike:GetPos()
    b:rideLine(a, dir, 150, function() return b:speed() >= 140 end, 6)
    local start = CurTime()
    b:rideLine(a, dir, 170, function() return CurTime() - start > 2.2 end, 3,
        function() return { throttle = 1, pitch = 1 } end)
    b:rideLine(a, dir, 120, function() return CurTime() - start > 3.0 end, 1)
    if b:scoredSince(t0, "Wheelie") then return true end
    return false, "no wheelie scored"
end

T["Stoppie"] = function(b)
    local dir, len = b:openRun(900)
    if not dir or len < 700 then return false, "no room" end
    local t0 = CurTime()
    b:lineUp(dir, 230)
    local a = b.bike:GetPos()
    b:rideLine(a, dir, 240, function() return b:speed() >= 220 end, 6)
    b:rideLine(a, dir, 0, function() return b:speed() < 4 end, 4,
        function() return { throttle = 0, brakeRear = 0, brakeFront = 1, pitch = -0.6 } end)
    b:set({})
    b:wait(0.6)
    if b:scoredSince(t0, "Stoppie") then return true end
    return false, "no stoppie scored"
end

-- Two tricks chained: a wheelie straight into a stoppie, landed.
T["Combo"] = function(b)
    local dir, len = b:openRun(900)
    if not dir or len < 700 then return false, "no room" end
    local t0 = CurTime()
    b:lineUp(dir, 170)
    local a = b.bike:GetPos()
    b:rideLine(a, dir, 180, function() return b:speed() >= 165 end, 6)
    local start = CurTime()
    b:rideLine(a, dir, 190, function() return CurTime() - start > 1.7 end, 3,
        function() return { throttle = 1, pitch = 1 } end)
    -- Let the front wheel come down and settle before grabbing the brake:
    -- braking on the slam stops the bike before the rear has lifted long
    -- enough to count. The combo stays open for Combo.grace meanwhile.
    local down = CurTime()
    b:rideLine(a, dir, 230, function() return CurTime() - down > 0.45 end, 1,
        function() return { throttle = 0.6 } end)
    -- (The wheelie's landing leaves the bike pitching for a moment; braking
    -- into that bounces the rear on and off and every touch ends the stoppie.)
    b:rideLine(a, dir, 0, function() return b:speed() < 4 end, 4,
        function() return { throttle = 0, brakeFront = 1, pitch = -0.6 } end)
    b:set({})
    b:wait(1.4)
    if b:comboSince(t0) then return true end
    return false, "no combo landed"
end

-- The air tricks, and the axis and direction each spins.
Bot.AirTricks = {
    ["Backflip"]    = { axis = "pitch", sign =  1 },
    ["Frontflip"]   = { axis = "pitch", sign = -1 },
    ["Barrel Roll"] = { axis = "roll",  sign =  1 },
    ["360"]         = { axis = "yaw",   sign =  1 },
}

-- The part of an air trick done in the air: from takeoff to touchdown, and
-- the landing checked. Its own function so a bike already in the air -- off
-- a map's gap, or a test's launch -- can do it too.
function Brain:airPart(name, t0, pose, scored)
    local A = Bot.AirTricks[name]
    -- Aim to finish on a turn plus margin; a frontflip leaves a nose-up ramp,
    -- so it turns that much further to come down level.
    local target = TAU + Bot.Config.margin
    if A.axis == "pitch" and A.sign < 0 then
        local p0 = select(2, BMX.Attitude(self.bike, UP))
        target = math.max(target, TAU + p0)
    end
    self:say(string.format("airborne: %.2f s to land, aiming for %.0f deg", self:timeToLand(), math.deg(target)))
    self:flySpin(A.axis, A.sign, target, pose)
    self:set({})
    self:waitLanded(0.8, 3)
    if self:scoredSince(t0, scored or name) and self:riding() then return true end
    local got = self:scoredSince(t0)
    return false, got and ("scored " .. got.name .. " instead") or "nothing scored"
end

for name in pairs(Bot.AirTricks) do
    T[name] = function(b)
        local l = b:launch()
        if not l then return false, "nowhere to get air" end
        local t0 = CurTime()
        local ok, why = b:hitLaunch(l, Bot.Config.flipSpeed)
        if not ok then return false, why end
        return b:airPart(name, t0)
    end
end

--------------------------------------------------------------------------
-- Frame and bar spins, and poses (G03, G17). Written to the same bike.input a
-- rider's keys make: inp.whip / inp.bar / inp.pose (sv_input.lua).
--------------------------------------------------------------------------

-- Turn a part (st.parts[field]) in the air until it is past the 270 degrees
-- from which letting go finishes it, then let go. `name` is what the scoring
-- calls it.
function Brain:airPartSpin(name, field, t0)
    local want = TAU * 0.85
    self:say(string.format("airborne: %.2f s to land, spinning the %s", self:timeToLand(), field))
    local landedFor = 0
    while true do
        if not self:riding() then return false end
        local st = self:st()
        if st.grounded and not st.airMode then
            landedFor = landedFor + engine.TickInterval()
            if landedFor > 0.1 then break end
        else
            landedFor = 0
        end
        local part = st.parts and st.parts[field]
        local inp = {}
        if st.airMode and (not part or math.abs(part.angle) < want) then inp[field] = 1 end
        self:set(inp)
        tick()
    end
    self:set({})
    self:waitLanded(0.8, 3)
    if self:scoredSince(t0, name) and self:riding() then return true end
    local got = self:scoredSince(t0)
    return false, got and ("scored " .. got.name .. " instead") or "nothing scored"
end

-- Hold a pose through the middle of the air, and be out of it well before
-- touchdown (landing in a pose bails).
function Brain:airPose(name, pose, t0)
    self:say(string.format("airborne: %.2f s to land, holding %s", self:timeToLand(), pose))
    local landedFor = 0
    while true do
        if not self:riding() then return false end
        local st = self:st()
        if st.grounded and not st.airMode then
            landedFor = landedFor + engine.TickInterval()
            if landedFor > 0.1 then break end
        else
            landedFor = 0
        end
        local inp = {}
        if st.airMode and (st.airTime or 0) >= 0.12 and self:timeToLand() > 0.4 then inp.pose = pose end
        self:set(inp)
        tick()
    end
    self:set({})
    self:waitLanded(0.8, 3)
    if self:scoredSince(t0, name) and self:riding() then return true end
    local got = self:scoredSince(t0)
    return false, got and ("scored " .. got.name .. " instead") or "nothing scored"
end

local function partTrick(name, fn)
    T[name] = function(b)
        local l = b:launch()
        if not l then return false, "nowhere to get air" end
        local t0 = CurTime()
        local ok, why = b:hitLaunch(l, Bot.Config.flipSpeed)
        if not ok then return false, why end
        return fn(b, t0)
    end
end
partTrick("Tailwhip", function(b, t0) return b:airPartSpin("Tailwhip", "whip", t0) end)
partTrick("Barspin",  function(b, t0) return b:airPartSpin("Barspin",  "bar",  t0) end)
partTrick("Superman", function(b, t0) return b:airPose("Superman", "superman", t0) end)

-- A backflip with the superman held through the middle of it: one compound,
-- "Backflip Superman". The pose is up from a fifth of the way round to
-- three quarters, long enough to count and over before it comes down.
partTrick("Superman Backflip", function(b, t0)
    return b:airPart("Backflip", t0, function(spun, target)
        local f = spun / target
        return (f >= 0.2 and f <= 0.72) and "superman" or nil
    end, "Backflip Superman")
end)

-- Run just the air part of a trick on a bike already in the air.
function Bot.PerformAir(b, name, done)
    b.job = coroutine.create(function() return b:airPart(name, CurTime() - 0.01) end)
    b.jobDone = function(ok, why) b.job = nil if done then done(ok, why) end end
end

-- A rail to grind: a thin pole (crank) or a beam (pegs), raised `top` u and
-- laid along `dir`. The recipe is the headless grind_hop_on case's, which is
-- the one proved on a real server: 18 u up, met at 6 degrees, at 260 u/s.
local RAILS = {
    ["Crank Grind"]      = { model = "models/props_c17/signpole001.mdl", top = 18, edge = false },
    ["Double Peg Grind"] = { model = "models/hunter/blocks/cube025x8x025.mdl", top = 18, edge = true },
}
Bot.Rails = RAILS
local GRIND_SPEED, GRIND_YAW = 260, 6

function Brain:layRail(kind, centre, dir)
    local R = RAILS[kind]
    local e = ents.Create("prop_physics")
    if not IsValid(e) then return nil end
    e:SetModel(R.model)
    e:Spawn()
    local mn, mx = e:OBBMins(), e:OBBMaxs()
    local size = mx - mn
    local yaw = math.deg(math.atan2(dir.y, dir.x))
    -- Lay the model's long axis along dir.
    local ang
    if size.z >= size.x and size.z >= size.y then ang = Angle(90, yaw, 0)
    elseif size.y >= size.x then ang = Angle(0, yaw - 90, 0)
    else ang = Angle(0, yaw, 0) end
    e:SetAngles(ang)
    e:SetPos(centre)
    local p = e:GetPhysicsObject()
    if IsValid(p) then p:EnableMotion(false) end
    -- Centre it over `centre`, its top R.top above the ground there.
    local lo, hi = e:WorldSpaceAABB()
    local shift = Vector(centre.x - (lo.x + hi.x) * 0.5, centre.y - (lo.y + hi.y) * 0.5,
                         centre.z + R.top - hi.z)
    e:SetPos(e:GetPos() + shift)
    if IsValid(p) then p:SetPos(e:GetPos()) p:EnableMotion(false) end
    e.BMXRail = true
    self.props[#self.props + 1] = e
    return e
end

-- The line to ride at a rail along `dir` (unit) centred at `centre`, of
-- length `len` and width `w`, so the crank point arrives over `lateral`
-- (left of the rail's axis) 60 u along it as the hop comes down onto it.
-- Returns the point to press the hop at and the direction to ride in.
function Bot.GrindApproach(cfg, centre, dir, len, lateral, top, g)
    local H = cfg.Hop
    local left = Vector(-dir.y, dir.x, 0)
    local vz = H.popSpeed / math.sqrt(1 + H.forwardBias ^ 2)
    local crank0 = BMX.RestHeight(cfg) + BMX.GrindCrankPoint(cfg).z
    local rise = top + 4 - crank0
    local tDown = (vz + math.sqrt(math.max(vz * vz - 2 * g * rise, 0))) / g
    local t = H.chargeTime + 0.05 + tDown
    local c, s = math.cos(math.rad(GRIND_YAW)), math.sin(math.rad(GRIND_YAW))
    local press = centre + dir * (-len * 0.5 + 60 - GRIND_SPEED * c * t)
                         + left * (lateral - GRIND_SPEED * s * t)
    return press, (dir * c + left * s):GetNormalized(), t
end

local function grindTrick(name)
    T[name] = function(b)
        local dir, len = b:openRun(1500)
        if not dir or len < 1200 then return false, "no room" end
        local cfg = b.bike:Cfg()
        local start = b.bike:GetPos()
        local ground = start - UP * BMX.RestHeight(cfg)
        local e = b:layRail(name, ground + dir * 950, dir)
        if not e then return false, "could not lay a rail" end
        local lo, hi = e:WorldSpaceAABB()
        local centre = (lo + hi) * 0.5
        centre.z = ground.z
        local size = hi - lo
        local railLen = math.abs(size.x * dir.x) + math.abs(size.y * dir.y)
        local width = math.abs(size.x * dir.y) + math.abs(size.y * dir.x)
        -- A peg grind lands on the near (right-hand) edge, a crank on the middle.
        local lateral = RAILS[name].edge and (-width * 0.5 + 2) or 0
        local press, rideDir = Bot.GrindApproach(cfg, centre, dir, railLen, lateral,
            RAILS[name].top, physenv.GetGravity():Length())
        local stage = press - rideDir * 650
        local ok, why = b:rideTo(stage, 200, 60, 20)
        if not ok then return false, why end
        b:stop(3)
        local t0 = CurTime()
        local pressedAt, released = nil, false
        local C = cfg
        ok, why = b:rideLine(press, rideDir, GRIND_SPEED, function(along)
            if b:st().grind then return true end
            if not pressedAt and along >= 0 then
                b.bike.hopHeld, b.bike.hopCharge, pressedAt = true, 0, CurTime()
            end
            if pressedAt and not released and CurTime() - pressedAt >= C.Hop.chargeTime + 0.05 then
                b.bike.hopRelease, released = true, true
            end
            return released and CurTime() - pressedAt > 2
        end, 14)
        -- On it: hold still and let the rail's end finish it.
        local tg = CurTime()
        while b:st().grind and CurTime() - tg < 6 do b:set({}) tick() end
        b:waitLanded(0.6, 3)
        if b:scoredSince(t0, name) and b:riding() then return true end
        local got = b:scoredSince(t0)
        return false, got and ("scored " .. got.name .. " instead") or (why or "no grind scored")
    end
end
grindTrick("Crank Grind")
grindTrick("Double Peg Grind")

--------------------------------------------------------------------------
-- Running: one trick at a time, recovered from crashes.
--------------------------------------------------------------------------

-- Start a trick. The brain runs it from its Think; `done(ok, why)` is called
-- when it finishes. Returns false if there is no such trick.
function Bot.Perform(b, name, done)
    local fn = Bot.Tricks[name]
    if not fn then return false end
    local r = b.results[name] or { tries = 0, landed = 0 }
    b.results[name] = r
    r.tries = r.tries + 1
    b.current = name
    b.job = coroutine.create(function()
        local ok, why = fn(b)
        return ok, why
    end)
    b.jobDone = function(ok, why)
        b.current = nil
        if ok then r.landed = r.landed + 1 end
        r.last = ok and "landed" or ("missed: " .. tostring(why))
        b:say(name .. ": " .. r.last)
        if not b.quiet and ok and IsValid(b.ply) then
            for _, p in ipairs(player.GetHumans()) do
                p:ChatPrint(string.format("[BMX] %s landed a %s!", b.ply:Nick(), name))
            end
        end
        -- Tidy: a ramp or rail it put down for this trick goes.
        for _, e in ipairs(b.props) do SafeRemoveEntity(e) end
        b.props = {}
        if done then done(ok, why) end
    end
    return true
end

-- Back on the bike after a crash: the tumble ends, the player respawns
-- beside it, and gets on (which picks a fallen bike up).
function Brain:recover()
    local ply, bike = self.ply, self.bike
    if not IsValid(bike) then return end
    if ply.BMXTumbling or not ply:Alive() then return end
    if IsValid(ply:GetVehicle()) then return end
    if (self.nextMount or 0) > CurTime() then return end
    self.nextMount = CurTime() + 0.5
    ply:SetPos(BMX.ExitPoint and BMX.ExitPoint(bike, ply) or bike:GetPos() + Vector(0, 40, 8))
    ply:EnterVehicle(bike:GetPod())
end

function Bot.Think()
    for ply, b in pairs(Bot.brains) do
        if not IsValid(ply) or not IsValid(b.bike) then
            Bot.Detach(b)
        else
            if not b:riding() then
                if b.job then
                    local done = b.jobDone
                    b.job = nil
                    if done then done(false, "crashed") end
                end
                b:recover()
            elseif b.job then
                local ok, a, c = coroutine.resume(b.job)
                if not ok then
                    b.job = nil
                    ErrorNoHalt("[BMX] bot trick failed: " .. tostring(a) .. "\n")
                    if b.jobDone then b.jobDone(false, "error: " .. tostring(a)) end
                elseif coroutine.status(b.job) == "dead" then
                    b.job = nil
                    if b.jobDone then b.jobDone(a, c) end
                end
            elseif b.show then
                b:nextInShow()
            end
        end
    end
end
hook.Add("Think", "BMX.Bot", Bot.Think)

-- The show: every trick in the list, over and over, retrying a miss.
function Brain:nextInShow()
    if (self.showRest or 0) > CurTime() then
        self:set({})
        return
    end
    local name = table.remove(self.queue or {}, 1)
    if not name then
        self.queue = {}
        for _, n in ipairs(Bot.TrickList) do self.queue[#self.queue + 1] = n end
        name = table.remove(self.queue, 1)
    end
    Bot.Perform(self, name, function(ok)
        local r = self.results[name]
        if not ok and (self.retries or 0) < Bot.Config.attempts - 1 then
            self.retries = (self.retries or 0) + 1
            table.insert(self.queue, 1, name)
        else
            self.retries = 0
        end
        self.showRest = CurTime() + 1.5
    end)
end

--------------------------------------------------------------------------
-- The bot player: its name, its model, kept through every respawn.
--------------------------------------------------------------------------
hook.Add("PlayerSetModel", "BMX.Bot.Model", function(ply)
    local m = ply.BMXBotModel
    if m and m ~= "" then
        ply:SetModel(m)
        return true
    end
end)

function Bot.Spawn(at, yaw, bikeId)
    if #player.GetAll() >= game.MaxPlayers() then return nil, "no free player slot" end
    local ply = player.CreateNextBot(cvName:GetString())
    if not IsValid(ply) then return nil, "could not create a bot" end
    local model = cvModel:GetString()
    if model ~= "" and util.IsValidModel(model) then
        ply.BMXBotModel = model
        ply:SetModel(model)
    elseif model ~= "" then
        ErrorNoHalt("[BMX] bmx_bot_model " .. model .. " is not mounted on this server; default model used\n")
    end
    local class = BMX.ClassFor(bikeId or "stock") or "bmx_base"
    local bike = ents.Create(class)
    if not IsValid(bike) then ply:Kick("no bike") return nil, "could not create the bike" end
    bike:SetPos(at + Vector(0, 0, BMX.RestHeight(bike:Cfg()) + 0.5))
    bike:SetAngles(Angle(0, yaw or 0, 0))
    bike:Spawn()
    bike:Activate()
    bike.BMXBotBike = true
    ply:SetPos(at + Vector(0, 40, 8))
    ply:EnterVehicle(bike:GetPod())
    local b = Bot.Attach(ply, bike, { home = at })
    b.show = true
    return b
end

local function allowed(ply)
    return not IsValid(ply) or ply:IsAdmin()
end

concommand.Add("bmx_bot_spawn", function(ply, _, args)
    if not allowed(ply) then return end
    local at, yaw = Vector(0, 0, 0), 0
    if IsValid(ply) then
        local tr = ply:GetEyeTrace()
        at, yaw = tr.HitPos, ply:EyeAngles().y
    else
        local s = ents.FindByClass("info_player_start")[1]
        if IsValid(s) then at = s:GetPos() end
    end
    local b, err = Bot.Spawn(at, yaw, args[1])
    local msg = b and ("[BMX] " .. b.ply:Nick() .. " is riding") or ("[BMX] no bot: " .. tostring(err))
    if IsValid(ply) then ply:ChatPrint(msg) else print(msg) end
end)

concommand.Add("bmx_bot_remove", function(ply)
    if not allowed(ply) then return end
    for p, b in pairs(Bot.brains) do
        local bike = b.bike
        Bot.Detach(b)
        if IsValid(p) and p:IsBot() then p:Kick("BMX bot removed") end
        if IsValid(bike) and bike.BMXBotBike then SafeRemoveEntity(bike) end
    end
end)

concommand.Add("bmx_bot_trick", function(ply, _, args)
    if not allowed(ply) then return end
    local name = table.concat(args, " ")
    if not Bot.Tricks[name] then
        local m = "[BMX] tricks: " .. table.concat(Bot.TrickList, ", ")
        if IsValid(ply) then ply:ChatPrint(m) else print(m) end
        return
    end
    for _, b in pairs(Bot.brains) do
        b.queue = b.queue or {}
        table.insert(b.queue, 1, name)
    end
end)

function Bot.Status(b)
    local out = { b.ply:Nick() .. (b.current and (" -- doing " .. b.current) or "") }
    for _, name in ipairs(Bot.TrickList) do
        local r = b.results[name]
        out[#out + 1] = string.format("  %-16s %s", name,
            r and string.format("%d/%d  %s", r.landed, r.tries, r.last or "") or "not tried")
    end
    return out
end

concommand.Add("bmx_bot_status", function(ply)
    for _, b in pairs(Bot.brains) do
        for _, line in ipairs(Bot.Status(b)) do
            if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, line) else print(line) end
        end
    end
end)
