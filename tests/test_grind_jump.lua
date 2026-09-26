--[[--------------------------------------------------------------------------
    A PLAYER JUMPING ONTO A RAIL, start to finish, through the real keys.

    test_grind.lua places the bike over a rail and lets go. These do what a
    rider does: hold W to ride, hold SPACE to preload, let go to pop, come down
    on the rail, grind it, and leave it -- every tick's buttons handed to the
    real StartCommand hook (sv_input.lua), so the key decode, the hop, the
    lock-on and the exit are one sequence, as on a server.

    Every run is watched for being LAUNCHED: the bike may move no further in a
    tick than its speed allows (the snap onto the rail aside), and after a
    grind it may go no faster, and no higher, than it left. The launch a rider
    reported came from VPhysics pushing the hull out of the rail it had been
    placed in; the shim does not collide with the rail, so it cannot show that
    push, but it can show every pose was clear of the rail (GrindPoseClear) --
    which is what makes the push impossible -- and that the backstop never had
    to fire.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local gmod = require("lib.gmod")
local IN = gmod.IN

local function cmd(buttons)
    local c = { buttons = buttons or 0, fwd = 0, side = 0, up = 0 }
    function c:GetButtons() return self.buttons end
    function c:SetButtons(b) self.buttons = b end
    function c:GetForwardMove() return self.fwd end
    function c:GetSideMove() return self.side end
    function c:SetForwardMove(v) self.fwd = v end
    function c:SetSideMove(v) self.side = v end
    function c:SetUpMove(v) self.up = v end
    return c
end

-- A world with `solids`, a HUMAN rider (the keys go through StartCommand),
-- the bike at (0, y) facing `yaw` and already rolling at `speed`.
local function setup(solids, y, yaw, speed)
    local sv = F.server({ solids = solids })
    local E = sv.env
    local bike = F.bike(sv)
    local ply = F.rider(sv, bike, { name = "Rider" })
    sv:run(0.3)
    local ang = E.Angle(0, yaw or 0, 0)
    F.place(bike, E.Vector(0, y or 0, F.restHeight(sv)), ang)
    bike:GetPhysicsObject():SetVelocity(ang:Forward() * (speed or 260))
    return sv, bike, ply
end

-- Ride for `seconds`, pressing whatever `keys(t)` returns each tick, and
-- keep a record of the whole run.
local function ride(sv, bike, ply, seconds, keys)
    local E = sv.env
    local rec = { ticks = {}, started = nil, ended = nil, paid = {}, crashed = false }
    E.hook.Add("BMX_GrindStarted", "test", function(e, kind)
        if e == bike then rec.started = rec.started or { kind = kind, t = sv.world.time } end
    end)
    E.hook.Add("BMX_GrindEnded", "test", function(e, kind, why, t)
        if e == bike then rec.ended = rec.ended or { kind = kind, why = why, t = t,
            vel = bike.st.grindExit and bike.st.grindExit.vel } end
    end)
    local award = bike.AwardTricks
    bike.AwardTricks = function(self, list)
        for _, tr in ipairs(list) do rec.paid[#rec.paid + 1] = tr end
        return award(self, list)
    end
    local crash = bike.Crash
    bike.Crash = function(self, ...) rec.crashed = true return crash(self, ...) end

    local t0 = sv.world.time
    local n = math.floor(seconds / sv.world.dt + 0.5)
    for _ = 1, n do
        local t = sv.world.time - t0
        E.hook.Run("StartCommand", ply, cmd(keys(t)))
        sv:tick()
        local phys = bike:GetPhysicsObject()
        rec.ticks[#rec.ticks + 1] = {
            t = t, pos = bike:GetPos(), vel = phys:GetVelocity(),
            grind = bike.st.grind and bike.st.grind.kind or nil,
            clear = bike.st.grind and E.BMX.GrindPoseClear(bike:GetPos(), bike:GetAngles(),
                bike:Cfg(), bike.traceFilter) or nil,
            rider = E.IsValid(bike:GetDriver()),
            grounded = bike.st.grounded and not bike.st.grind,
        }
    end
    E.hook.Remove("BMX_GrindStarted", "test")
    E.hook.Remove("BMX_GrindEnded", "test")
    return rec
end

-- Hold W the whole way; SPACE from `from` until `to` (release = the pop).
local function hopAt(from, to)
    return function(t)
        local b = IN.FORWARD
        if t >= from and t < to then b = b + IN.JUMP end
        return b
    end
end

-- Nothing was launched: no tick moved the bike further than its speed allows
-- (the one snap onto the rail aside), and after the grind it never went
-- faster or higher than it left.
local function notLaunched(rec, sv, label)
    local dt = sv.world.dt
    local snaps = 0
    -- Up to the first landing after a grind: past that the shim's bike is
    -- riding through boxes it does not collide with, which says nothing.
    local stop, seen = #rec.ticks, false
    for i, k in ipairs(rec.ticks) do
        if k.grind then seen = true elseif seen and k.grounded then stop = i break end
    end
    for i = 2, stop do
        local a, b = rec.ticks[i - 1], rec.ticks[i]
        local moved = (b.pos - a.pos):Length()
        local allowed = math.max(a.vel:Length(), b.vel:Length()) * dt + 1.5
        if moved > allowed then
            if b.grind and not a.grind and moved < 14 then
                snaps = snaps + 1                 -- locking on: a short snap
            else
                T.ok(false, string.format("%s: moved %.1f units in one tick at t=%.2f (allowed %.1f)",
                    label, moved, b.t, allowed))
                return
            end
        end
    end
    T.between(snaps, 0, 1, label .. ": snaps onto a rail")
    -- Off the rail and in the air, up to the first touch of the ground: no
    -- faster and no more upward than it left. (Landing then compresses the
    -- suspension and rebounds, which is riding, not a launch.)
    if rec.ended and rec.ended.vel then
        local out = rec.ended.vel
        local worstUp, worstFast, after, n = -math.huge, -math.huge, false, 0
        for _, k in ipairs(rec.ticks) do
            if after then
                if k.grounded or k.grind then break end
                n = n + 1
                worstUp = math.max(worstUp, k.vel.z - math.max(out.z, 0))
                worstFast = math.max(worstFast, k.vel:Length() - out:Length())
            end
            if k.grind then after = true end
        end
        if n > 0 then
            T.between(worstUp, -1e9, 5, label .. ": climbing faster than it left the rail, u/s")
            T.between(worstFast, -1e9, 30, label .. ": going faster than it left the rail, u/s")
        end
    end
end

-- A pipe along x from x0 to x1, top at `top`, `w` wide, centred on y = 0.
local function pipe(E, x0, x1, top, w)
    w = (w or 2) * 0.5
    return { E.Vector(x0, -w, top - 3), E.Vector(x1, w, top) }
end

--------------------------------------------------------------------------
T.test("jump onto a pipe: W to ride, SPACE to pop, a crank grind to the end", function()
    local E = F.server().env
    local sv, bike, ply = setup({ pipe(E, 150, 700, 18) }, -3, 0, 260)
    local rec = ride(sv, bike, ply, 3.5, hopAt(0.02, 0.47))

    T.ok(rec.started, "locked onto the pipe")
    T.eq(rec.started and rec.started.kind, "crank", "a crank grind")
    T.ok(rec.ended, "and came off it")
    T.eq(rec.ended and rec.ended.why, "end", "at the end of the pipe")
    T.between(rec.ended and rec.ended.t or 0, 0.8, 3, "grind time, s")
    local worstClear = true
    for _, k in ipairs(rec.ticks) do
        if k.grind and not k.clear then worstClear = false end
    end
    T.ok(worstClear, "nothing of the bike inside the pipe at any tick of the grind")
    notLaunched(rec, sv, "pipe")
    local grindPaid
    for _, p in ipairs(rec.paid) do if p.name == "Crank Grind" then grindPaid = p end end
    T.ok(grindPaid, "a Crank Grind was paid")
    for _, k in ipairs(rec.ticks) do T.ok(k.rider, "rider aboard at t=" .. k.t) if not k.rider then break end end
    T.ok(not rec.crashed, "no crash")
    T.ok((bike.st.grindExitClamped or 0) == 0, "the exit guard never had to hold it down")
    T.eq(#sv.errors, 0, "no errors: " .. table.concat(sv.errors, " | "))
end)

T.test("jump onto a FAT pipe (5 wide): the wheels still clear it, no launch", function()
    local E = F.server().env
    local sv, bike, ply = setup({ pipe(E, 150, 700, 18, 5) }, -3, 0, 260)
    local rec = ride(sv, bike, ply, 3.5, hopAt(0.02, 0.47))
    T.ok(rec.started, "locked on")
    for _, k in ipairs(rec.ticks) do
        if k.grind then T.ok(k.clear, "hull clear of the pipe at t=" .. k.t) if not k.clear then break end end
    end
    notLaunched(rec, sv, "fat pipe")
    T.ok((bike.st.grindExitClamped or 0) == 0, "the exit guard never had to hold it down")
end)

T.test("jump onto a ledge from beside it: a double peg grind, pegs on the ledge side", function()
    local E0 = F.server().env
    -- The ledge's top at 18, its edge along x at y = 18, the top over +y.
    local sv, bike, ply = setup({ { E0.Vector(150, 18, 0), E0.Vector(800, 300, 18) } }, 0, 4, 260)
    local codes = {}
    local rec = ride(sv, bike, ply, 3.5, function(t)
        if bike.st.grind then codes[bike:GetGrind()] = true end
        return hopAt(0.02, 0.47)(t)
    end)
    T.ok(rec.started, "locked on")
    T.eq(rec.started and rec.started.kind, "peg", "a peg grind")
    T.ok(codes[2], "pegs on the LEFT, the ledge's side")
    for _, k in ipairs(rec.ticks) do
        if k.grind then T.ok(k.clear, "hull clear of the ledge at t=" .. k.t) if not k.clear then break end end
    end
    notLaunched(rec, sv, "ledge")
    T.ok(not rec.crashed, "no crash")
end)

T.test("jump and hop off mid-grind: up and away, back on the ground on the wheels", function()
    local E = F.server().env
    local sv, bike, ply = setup({ pipe(E, 150, 3000, 18) }, -3, 0, 260)
    local hopped
    local rec = ride(sv, bike, ply, 4, function(t)
        local b = hopAt(0.02, 0.47)(t)
        -- A second SPACE, 0.4 s into the grind: tap it.
        if bike.st.grind and bike.st.grindTime and bike.st.grindTime > 0.4 and not hopped then
            hopped = sv.world.time
            b = b + IN.JUMP
        end
        return b
    end)
    T.ok(rec.started, "locked on")
    T.eq(rec.ended and rec.ended.why, "hop", "left by the jump key")
    notLaunched(rec, sv, "hop off")
    local last = rec.ticks[#rec.ticks]
    T.ok(bike.st.grounded, "back on the ground")
    T.ok(last.rider, "rider aboard")
    T.ok(not rec.crashed, "no crash")
end)

T.test("a hop too low for the rail: no grind, no snap", function()
    local E = F.server().env
    local sv, bike, ply = setup({ pipe(E, 150, 700, 70) }, -3, 0, 260)
    local rec = ride(sv, bike, ply, 2, hopAt(0.02, 0.47))
    T.ok(not rec.started, "did not lock onto a rail it could not reach")
    notLaunched(rec, sv, "too low")
end)

T.test("jumping ACROSS a pipe: no grind, no snap", function()
    local E = F.server().env
    local sv, bike, ply = setup({ pipe(E, -400, 400, 18) }, -150, 70, 260)
    local rec = ride(sv, bike, ply, 2, hopAt(0.02, 0.47))
    T.ok(not rec.started, "crossing at 70 degrees does not grind")
    notLaunched(rec, sv, "across")
end)

T.test("a pipe against a wall: no room for a wheel, so no grind (and no launch)", function()
    local E = F.server().env
    local sv, bike, ply = setup({ pipe(E, 150, 700, 18),
                                  { E.Vector(150, 3, 0), E.Vector(700, 60, 80) } }, -3, 0, 260)
    local rec = ride(sv, bike, ply, 3, hopAt(0.02, 0.47))
    T.ok(not rec.started, "refused: one wheel would be inside the wall")
    notLaunched(rec, sv, "against a wall")
end)

T.test("a pipe that runs into a higher block: the grind ends, it does not climb onto it", function()
    local E = F.server().env
    local sv, bike, ply = setup({ pipe(E, 150, 400, 18),
                                  { E.Vector(400, -6, 0), E.Vector(600, 6, 22) } }, -3, 0, 260)
    local rec = ride(sv, bike, ply, 3, hopAt(0.02, 0.47))
    T.ok(rec.started, "locked on")
    T.ok(rec.ended and (rec.ended.why == "end" or rec.ended.why == "blocked"),
        "ended at the block: " .. tostring(rec.ended and rec.ended.why))
    notLaunched(rec, sv, "into a block")
end)
