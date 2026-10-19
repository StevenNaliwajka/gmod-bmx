--[[--------------------------------------------------------------------------
    tests/lib/netsim.lua

    A SERVER AND A CLIENT OVER A BAD LINK, for the skates' prediction (G25, G30).

    The skates are the one vehicle whose movement the client PREDICTS: the player
    is the chassis, and the engine runs SetupMove / Move on the client for the
    local player as it does on the server (cl_skates.lua). Nothing offline had
    ever run the two against each other with a ping between them. This does:

      * a server realm and a client realm on the same world (rails and all),
        each running the addon's real hooks for its own copy of the player;
      * a LINK each way: a one-way delay, uniform jitter, independent loss, and
        packets that arrive after a newer one dropped (the engine's rule);
      * the client side of the engine's prediction loop, as Source 2013's
        CPrediction does it: a usercmd a tick, predicted at once
        (IsFirstTimePredicted true); on a snapshot, the networked fields
        (origin, velocity, the ground flag, the old buttons, friction, the
        active weapon) are restored to the server's for the command it
        acknowledged, compared with what the client had predicted for that
        command, and on a difference every later command is predicted AGAIN
        (IsFirstTimePredicted false); with none, the client keeps its own
        (cl_pred_optimize 2). Lua state is NOT rolled back: the engine knows
        nothing about it.
      * the server side: commands run in order as they arrive, a lost one the
        backups did not cover replaced by the last one (CBasePlayer's rule),
        a snapshot every `snapEvery` ticks;
      * a stand-in for CGameMovement after the hooks (gravity, the engine's own
        jump on a fresh IN_JUMP, ground friction scaled by Entity:SetFriction,
        walk and air acceleration from the forward / side speeds, a hull swept
        against the world, the ground check). It is the SAME function on both
        ends, so it can only show a difference the Lua makes.

    And for the baseline, a BIKE under the same link: not predicted at all (its
    physics is the server's, docs/DESIGN.md section 5), drawn by interpolating
    snapshots cl_interp behind. Late, but smooth: the feel the owner accepts.

    WHAT THIS IS NOT. It is not the engine. Source's real prediction compares
    every predicted field with its own tolerances, quantises the origin on the
    wire, smooths the eye's error over cl_smoothtime, sends NW vars (which the
    skates' grind flag is) on a channel of their own, and moves the player with
    the full CGameMovement (steps, stairs, sv_optimizedmovement, ducking). Here
    the NW vars ride with the snapshot they belong to, which is the BEST case.
    A real client with net_fakelag is the check (docs/TESTING.md).
----------------------------------------------------------------------------]]

local gmod = require("lib.gmod")
local F = require("lib.fixture")
local IN = gmod.IN

local NS = {}
NS.DT = 1 / 66

-- The engine's numbers (GMod defaults): sv_gravity, the player's jump power,
-- sv_accelerate, sv_airaccelerate and its 30 u/s cap, sv_friction,
-- sv_stopspeed, the walk speed, NON_JUMP_VELOCITY.
NS.Move = { gravity = 600, jumpPower = 200, accelerate = 10, airAccelerate = 10, airCap = 30,
            friction = 8, stopSpeed = 10, maxSpeed = 200, nonJump = 140, optimizedLift = 250 }
-- What the prediction calls a difference: origin and velocity (Source's
-- velocity tolerance is 0.5; the origin's here is an eighth of a unit).
NS.TOL_POS, NS.TOL_VEL = 0.125, 0.5
NS.SNAP = 4            -- a correction larger than this is a visible snap (sh_predict.lua's SNAP_UNITS)

local EPS = 0.03125
local band, bor, bnot

--------------------------------------------------------------------------
-- A seeded random source of its own, so the link does not draw on the
-- math.random the addon uses (a grind's meter phase).
--------------------------------------------------------------------------
function NS.rng(seed)
    local s = (seed or 1) % 2147483647
    if s <= 0 then s = s + 2147483646 end
    return function()
        s = (s * 16807) % 2147483647
        return s / 2147483647
    end
end

--------------------------------------------------------------------------
-- THE LINK. send(now, payload) and recv(now) -> payloads in arrival order. A
-- packet older than one already delivered is dropped, as the engine drops an
-- out-of-order datagram.
--------------------------------------------------------------------------
function NS.link(rng, owd, jitter, loss, outages)
    local L = { q = {}, seq = 0, last = 0, sent = 0, lost = 0, late = 0 }
    function L:send(now, payload)
        self.seq, self.sent = self.seq + 1, self.sent + 1
        local r = rng()
        for _, o in ipairs(outages or {}) do
            if now >= o[1] and now < o[2] then self.lost = self.lost + 1 return end
        end
        if r < loss then self.lost = self.lost + 1 return end
        local d = owd + (rng() * 2 - 1) * jitter
        if d < 0.001 then d = 0.001 end
        self.q[#self.q + 1] = { at = now + d, seq = self.seq, p = payload }
    end
    function L:recv(now)
        table.sort(self.q, function(a, b) return a.at < b.at end)
        local out = {}
        while self.q[1] and self.q[1].at <= now + 1e-9 do
            local m = table.remove(self.q, 1)
            if m.seq > self.last then
                self.last = m.seq
                out[#out + 1] = m.p
            else
                self.late = self.late + 1
            end
        end
        return out
    end
    return L
end

--------------------------------------------------------------------------
-- A USERCMD and the MOVE DATA, with the methods the addon's hooks call.
--------------------------------------------------------------------------
local function newCmd(E, t)
    local c = { n = t.n, tick = t.tick or t.n, buttons = t.buttons or 0, fwd = t.fwd or 0,
                side = t.side or 0, up = 0, yaw = t.yaw or 0, weapon = t.weapon }
    function c:CommandNumber() return self.n end
    function c:TickCount() return self.tick end
    function c:GetButtons() return self.buttons end
    function c:SetButtons(b) self.buttons = b end
    function c:KeyDown(k) return band(self.buttons, k) ~= 0 end
    function c:GetForwardMove() return self.fwd end
    function c:SetForwardMove(v) self.fwd = v end
    function c:GetSideMove() return self.side end
    function c:SetSideMove(v) self.side = v end
    function c:GetUpMove() return self.up end
    function c:SetUpMove(v) self.up = v end
    function c:GetViewAngles() return E.Angle(0, self.yaw, 0) end
    function c:SetViewAngles(a) self.yaw = a.y end
    function c:ClearMovement() self.fwd, self.side, self.up = 0, 0, 0 end
    function c:ClearButtons() self.buttons = 0 end
    function c:GetMouseX() return 0 end
    function c:GetMouseY() return 0 end
    function c:GetMouseWheel() return 0 end
    function c:Copy()
        return newCmd(E, { n = self.n, tick = self.tick, buttons = self.buttons, fwd = self.fwd,
                           side = self.side, yaw = self.yaw, weapon = self.weapon })
    end
    return c
end
NS.newCmd = newCmd

local function newMove(E, origin, vel, cmd, oldButtons)
    local m = { origin = E.Vector(origin), vel = E.Vector(vel), buttons = cmd.buttons,
                oldButtons = oldButtons or 0, fs = cmd.fwd, ss = cmd.side, yaw = cmd.yaw }
    function m:GetOrigin() return E.Vector(self.origin) end
    function m:SetOrigin(v) self.origin = E.Vector(v) end
    function m:GetVelocity() return E.Vector(self.vel) end
    function m:SetVelocity(v) self.vel = E.Vector(v) end
    function m:GetButtons() return self.buttons end
    function m:SetButtons(b) self.buttons = b end
    function m:GetOldButtons() return self.oldButtons end
    function m:KeyDown(k) return band(self.buttons, k) ~= 0 end
    function m:GetForwardSpeed() return self.fs end
    function m:SetForwardSpeed(v) self.fs = v end
    function m:GetSideSpeed() return self.ss end
    function m:SetSideSpeed(v) self.ss = v end
    function m:SetUpSpeed() end
    function m:GetAngles() return E.Angle(0, self.yaw, 0) end
    function m:GetOldAngles() return E.Angle(0, self.oldYaw or self.yaw, 0) end
    function m:GetMoveAngles() return E.Angle(0, self.yaw, 0) end
    return m
end
NS.newMove = newMove

--------------------------------------------------------------------------
-- THE ENGINE'S MOVEMENT after the hooks (CGameMovement::FullWalkMove, the
-- parts that matter here). The same function on both ends.
--------------------------------------------------------------------------
local function hull(R, s, e)
    local E = R.env
    return E.util.TraceHull({ start = s, endpos = e, mins = E.Vector(-16, -16, 0),
        maxs = E.Vector(16, 16, 72), mask = E.MASK_PLAYERSOLID })
end

local function tryMove(R, o, v, dt)
    local left = 1
    for _ = 1, 4 do
        local d = v * (dt * left)
        if d:Length() < 1e-9 then break end
        local e = o + d
        local tr = hull(R, o, e)
        if tr.StartSolid then break end
        if not tr.Hit or tr.Fraction >= 1 then o = e break end
        local n = tr.HitNormal
        o = tr.HitPos + n * EPS
        left = left * (1 - tr.Fraction)
        local back = v:Dot(n)
        if back < 0 then v = v - n * back end
    end
    return o, v
end

function NS.engineMove(R, ply, mv, dt)
    local E, M = R.env, NS.Move
    local V = E.Vector
    local v, o = V(mv.vel), V(mv.origin)
    local ground = ply._onGround ~= false
    -- PlayerMove, with sv_optimizedmovement 1 (the default): it does not categorize the
    -- position again first, and lets go of the ground only above 250 u/s up. (The 140 of
    -- CategorizePosition applies only after game code moved the player.) Below that, the
    -- walk move zeroes the vertical speed: a Lua jump has to clear the ground entity itself.
    if v.z > M.optimizedLift then ground = false end
    v.z = v.z - 0.5 * M.gravity * dt                                  -- StartGravity
    local jumped = false
    if band(mv.buttons, IN.JUMP) ~= 0 then                            -- CheckJumpButton
        if ground and band(mv.oldButtons, IN.JUMP) == 0 then
            ground, jumped = false, true
            v.z = v.z + M.jumpPower - 0.5 * M.gravity * dt
        end
    end
    if ground then                                                    -- Friction
        v.z = 0
        local fr = ply.GetFriction and ply:GetFriction() or 1
        local sp = v:Length()
        if sp >= 0.1 then
            local drop = math.max(sp, M.stopSpeed) * M.friction * fr * dt
            v = v * (math.max(sp - drop, 0) / sp)
        end
    end
    -- WalkMove / AirMove: the wish from the forward and side speeds, along the view.
    local yaw = math.rad(mv.yaw or 0)
    local fx, fy, rx, ry = math.cos(yaw), math.sin(yaw), math.sin(yaw), -math.cos(yaw)
    local wx, wy = fx * (mv.fs or 0) + rx * (mv.ss or 0), fy * (mv.fs or 0) + ry * (mv.ss or 0)
    local ws = math.sqrt(wx * wx + wy * wy)
    if ws > 1e-6 then
        local dx, dy = wx / ws, wy / ws
        ws = math.min(ws, M.maxSpeed)
        local cap = ground and ws or math.min(ws, M.airCap)
        local add = cap - (v.x * dx + v.y * dy)
        if add > 0 then
            local a = math.min((ground and M.accelerate or M.airAccelerate) * dt * ws, add)
            v = V(v.x + a * dx, v.y + a * dy, v.z)
        end
    end
    o, v = tryMove(R, o, v, dt)
    ground = false                                                    -- CategorizePosition
    if v.z <= M.nonJump then
        local tr = hull(R, o, o - V(0, 0, 2))
        if tr.Hit and not tr.StartSolid and tr.HitNormal.z >= 0.7 then
            ground = true
            o = V(o.x, o.y, tr.HitPos.z + EPS)
        end
    end
    if not jumped then v.z = v.z - 0.5 * M.gravity * dt end            -- FinishGravity
    if ground then v.z = 0 end
    mv.vel, mv.origin = v, o
    ply._onGround = ground
end

--------------------------------------------------------------------------
-- THE HANDS: what the player presses on tick k -> a usercmd's raw fields.
-- `h` = { w, s, a, d, jump, duck, turn = degrees of mouse yaw this tick,
-- weapon = a class to switch to }.
--------------------------------------------------------------------------
local function buttonsOf(h)
    local b = 0
    if h.w then b = b + IN.FORWARD end
    if h.s then b = b + IN.BACK end
    if h.a then b = b + IN.MOVELEFT end
    if h.d then b = b + IN.MOVERIGHT end
    if h.jump then b = b + IN.JUMP end
    if h.duck then b = b + IN.DUCK end
    return b
end
NS.buttonsOf = buttonsOf

local function copyNW(t)
    local o = {}
    for k, v in pairs(t) do o[k] = v end
    return o
end

local function stats(list)
    local n = #list
    if n == 0 then return { n = 0, mean = 0, p95 = 0, max = 0 } end
    local s, sum = {}, 0
    for i = 1, n do s[i] = list[i] sum = sum + list[i] end
    table.sort(s)
    return { n = n, mean = sum / n, p95 = s[math.max(1, math.ceil(n * 0.95))], max = s[n] }
end
NS.stats = stats

-- Runs of `true` in a per-tick boolean list -> their lengths in ms.
local function runs(flags, from, to)
    local out, cur = {}, 0
    for n = from, to do
        if flags[n] then cur = cur + 1
        elseif cur > 0 then out[#out + 1] = cur * NS.DT * 1000 cur = 0 end
    end
    if cur > 0 then out[#out + 1] = cur * NS.DT * 1000 end
    return out
end

--------------------------------------------------------------------------
-- THE SKATER: a server and a client predicting it, over the link.
--
--   opts = { rtt = s, jitter = s (one way, +/-), loss = 0..1, seed,
--            solids = function(Vector) -> { box... }, start = {x, y, z}, yaw = deg,
--            equipped = true (already on skates on both ends at t = 0),
--            cmdEvery = 2, snapEvery = 2 (cl_cmdrate / cl_updaterate 33), backup = 2 (cl_cmdbackup),
--            optimize = true (cl_pred_optimize 2; false predicts again on EVERY snapshot),
--            outages = { { from, to }, ... } seconds in which every packet both ways is lost }
--
-- sim:step(hands) runs one tick; sim:report(from) the measures.
--------------------------------------------------------------------------
function NS.Skater(opts)
    opts = opts or {}
    local DT = NS.DT
    local solids = opts.solids and opts.solids(require("lib.vecang").Vector) or nil
    local sv, world = F.server({ solids = solids })
    local cl = F.client(world)
    local E, CE = sv.env, cl.env
    band, bor, bnot = E.bit.band, E.bit.bor, E.bit.bnot
    local rng = NS.rng(opts.seed or 7)
    local owd = (opts.rtt or 0.1) / 2
    local up = NS.link(rng, owd, opts.jitter or 0.02, opts.loss or 0.01, opts.outages)
    local down = NS.link(rng, owd, opts.jitter or 0.02, opts.loss or 0.01, opts.outages)
    local cmdEvery, snapEvery, backup = opts.cmdEvery or 2, opts.snapEvery or 2, opts.backup or 2
    local optimize = opts.optimize ~= false

    local sp, cp = sv:player("Skater"), cl:player("Skater")
    cl.localPlayer = cp
    local st = opts.start or { 0, 0, 0 }
    for _, p in ipairs({ sp, cp }) do
        p._pos = E.Vector(st[1], st[2], st[3])
        p._vel = E.Vector(0, 0, 0)
        p._onGround = true
        p._eyeAngles = E.Angle(0, opts.yaw or 0, 0)
        p.oldButtons = 0
        p._activeWep = opts.equipped == false and "weapon_physgun" or "weapon_bmx_skates"
        p._weapons = { "weapon_physgun", "weapon_bmx_skates" }
    end
    local first = true
    CE.IsFirstTimePredicted = function() return first end

    local sim = { sv = sv, cl = cl, sp = sp, cp = cp, world = world, up = up, down = down,
                  k = 0, viewYaw = opts.yaw or 0,
                  cmds = {}, pred = {}, shown = {}, svHist = {}, svCmds = {}, svLast = 0,
                  svRanReal = {}, clAck = 0, corrections = {}, ackErr = {}, replays = 0,
                  sentUpTo = 0, events = {} }

    -- The SWEP's doors, as the engine calls them on a weapon switch: on the
    -- server when the command is run, on the client when it is predicted.
    local function weapon(R, ply, class)
        local swep = R.sweps and R.sweps[class]
        if not swep then return nil end
        return setmetatable({ GetOwner = function() return ply end, Owner = ply }, { __index = swep })
    end
    local function switch(R, ply, to)
        local from = ply._activeWep
        if from == to then return end
        local old = from and weapon(R, ply, from)
        if old and old.Holster then old:Holster() end
        ply._activeWep = to
        local new = weapon(R, ply, to)
        if new and new.Deploy then new:Deploy() end
    end
    sim.switch = switch

    if opts.equipped ~= false then
        E.BMX.Skates.Equip(sp)
        cp._nw = copyNW(sp._nw)
    end

    -- ONE COMMAND on one end, in the engine's order (CPlayerMove::RunCommand): GMod's
    -- StartCommand, the weapon switch (a SWEP's Deploy / Holster, with the eye angles still the
    -- last command's), the view angles from the command, then SetupMove, Move, FinishMove.
    -- `R` the realm, `ply` its copy of the player.
    local function run(R, ply, c)
        local RE = R.env
        world.time = c.n * DT
        if ply._velocity then                       -- Player:SetVelocity adds, at the next move
            ply._vel = ply._vel + ply._velocity
            ply._velocity = nil
        end
        local cc = c:Copy()
        RE.hook.Run("StartCommand", ply, cc)
        if c.weapon then switch(R, ply, c.weapon) end
        local oldAng = ply._eyeAngles or RE.Angle(0, c.yaw, 0)
        ply._eyeAngles = RE.Angle(0, c.yaw, 0)
        if ply._spectating then return end          -- a tumble: the engine moves an observer
        local mv = newMove(RE, ply._pos, ply._vel, cc, ply.oldButtons)
        mv.oldYaw = oldAng.y
        RE.hook.Run("SetupMove", ply, mv, cc)
        local took = RE.hook.Run("Move", ply, mv)
        if not took then NS.engineMove(R, ply, mv, DT) end
        RE.hook.Run("FinishMove", ply, mv)
        ply._pos, ply._vel, ply.oldButtons = mv.origin, mv.vel, mv.buttons
        ply.lastTook = took and true or false
    end
    sim.run = run

    local function clPredict(c, isFirst)
        first = isFirst
        run(cl, cp, c)
        first = true
        sim.pred[c.n] = { pos = cp._pos, vel = cp._vel, ground = cp._onGround, old = cp.oldButtons,
                          friction = cp:GetFriction(), wep = cp._activeWep, yaw = cp._eyeAngles.y }
    end

    local function grindingNW(ply)
        return band(ply:GetNWInt("BMXSkateFlags", 0), E.BMX.Skates.Flag.grind) ~= 0
    end

    function sim:step(h)
        h = h or {}
        self.k = self.k + 1
        local k, now = self.k, self.k * DT

        ---------------- CLIENT: snapshots in, reconcile ----------------
        for _, s in ipairs(down:recv(now)) do
            if s.ack > self.clAck then
                cp._nw = copyNW(s.nw)
                cp._spectating = s.spectating
                local p = self.pred[s.ack]
                local err = p and (p.pos - s.pos):Length() or 0
                local verr = p and (p.vel - s.vel):Length() or 0
                local bad = (not p) or err > NS.TOL_POS or verr > NS.TOL_VEL or p.ground ~= s.ground
                    or math.abs((p.friction or 1) - (s.friction or 1)) > 1e-3 or p.wep ~= s.wep
                self.ackErr[#self.ackErr + 1] = { k = k, ack = s.ack, err = err, verr = verr, bad = bad }
                local wasSpectating = self.spectatingNow
                self.spectatingNow = s.spectating
                self.lastSpectating = wasSpectating
                self.clAck = s.ack
                local head = k - 1
                local before = self.pred[head] and self.pred[head].pos
                cp._pos, cp._vel, cp._onGround, cp.oldButtons = E.Vector(s.pos), E.Vector(s.vel), s.ground, s.old
                cp:SetFriction(s.friction)
                cp._activeWep = s.wep
                cp._weapons = { unpack(s.weapons) }
                cp._eyeAngles = E.Angle(0, s.yaw, 0)
                if (bad or not optimize) and head > s.ack then
                    self.replays = self.replays + 1
                    for n = s.ack + 1, head do clPredict(self.cmds[n], false) end
                    if before then
                        -- A tumble's start (the view goes to the ragdoll) and its get-up (the
                        -- server puts the player where the ragdoll stopped) are not mispredictions.
                        self.corrections[#self.corrections + 1] = { k = k, d = (self.pred[head].pos - before):Length(),
                            dz = self.pred[head].pos.z - before.z,
                            tumble = (s.spectating or self.lastSpectating) and true or false }
                    end
                elseif self.pred[head] and head > s.ack then
                    local q = self.pred[head]
                    cp._pos, cp._vel, cp._onGround, cp.oldButtons = E.Vector(q.pos), E.Vector(q.vel), q.ground, q.old
                    cp:SetFriction(q.friction)
                    cp._activeWep = q.wep
                    cp._eyeAngles = E.Angle(0, q.yaw, 0)
                end
            end
        end

        ---------------- CLIENT: the new command ----------------
        self.viewYaw = self.viewYaw + (h.turn or 0)
        local c = newCmd(CE, { n = k, buttons = buttonsOf(h), yaw = self.viewYaw, weapon = h.weapon,
            fwd = (h.w and 10000 or 0) - (h.s and 10000 or 0), side = (h.d and 10000 or 0) - (h.a and 10000 or 0) })
        world.time = k * DT
        CE.hook.Run("CreateMove", c)
        self.viewYaw = c.yaw                 -- engine->SetViewAngles(cmd->viewangles)
        self.cmds[k] = c
        clPredict(c, true)
        -- What the client ACTED ON for this command: its own taking over of the move on a rail
        -- (Move returned true), or, for a client that never takes it over, the server's grind
        -- flag it deferred to.
        if cp.lastTook then self.clTook = true end
        self.shown[k] = { pos = cp._pos, flag = grindingNW(cp), rail = cp.lastTook,
                          worn = cp:GetNWString("BMXWorn", "") ~= "", spectating = cp._spectating }
        if k % cmdEvery == 0 then
            local list = {}
            for n = math.max(1, self.sentUpTo + 1 - backup), k do list[#list + 1] = self.cmds[n]:Copy() end
            up:send(now, list)
            self.sentUpTo = k
        end

        ---------------- SERVER: commands in, run in order ----------------
        local got = false
        for _, pk in ipairs(up:recv(now)) do
            for _, cc in ipairs(pk) do
                if cc.n > self.svLast and not self.svCmds[cc.n] then self.svCmds[cc.n] = cc end
                got = true
            end
        end
        if got then
            local newest = self.svLast
            for n in pairs(self.svCmds) do if n > newest then newest = n end end
            for n = self.svLast + 1, newest do
                local cc = self.svCmds[n]
                local real = cc ~= nil
                if not cc then                       -- lost past the backups: the last one again
                    local last = self.svCmds[self.svLast] or self.lastSvCmd
                    cc = last and last:Copy() or newCmd(E, { n = n })
                    cc.n, cc.tick, cc.weapon = n, n, nil
                end
                run(sv, sp, cc)
                self.lastSvCmd = cc
                self.svRanReal[n] = real
                local w = sp.BMXWorn
                self.svHist[n] = { pos = sp._pos, vel = sp._vel, grind = w and w.st.grind ~= nil or false,
                                   worn = w ~= nil, tumbling = sp.BMXTumbling ~= nil or sp._spectating ~= nil }
                self.svCmds[n - 4] = nil
                self.svLast = n
            end
        end
        world.time = self.svLast * DT
        sv:runTimers()
        E.hook.Run("Think")
        if k % snapEvery == 0 and self.svLast > 0 then
            down:send(now, { ack = self.svLast, pos = E.Vector(sp._pos), vel = E.Vector(sp._vel),
                ground = sp._onGround ~= false, old = sp.oldButtons, friction = sp:GetFriction(),
                wep = sp._activeWep, nw = copyNW(sp._nw), spectating = sp._spectating,
                yaw = sp._eyeAngles and sp._eyeAngles.y or 0, weapons = { unpack(sp._weapons or {}) } })
        end
        return self
    end

    -- Run `n` ticks, `hands(k)` giving each tick's keys.
    function sim:play(n, hands)
        for _ = 1, n do self:step(hands and hands(self.k + 1, self) or nil) end
        return self
    end

    -- THE MEASURES over commands from..to (default: all the server has run).
    --   err        what the client SHOWED for each command (its first prediction)
    --              against where the server put the player for it, units
    --   corrections each reconciliation's jump of the drawn position, units
    --   snaps      the corrections larger than NS.SNAP
    --   grindLate  runs of commands the server was grinding and the client did
    --              not know (ms); grindStale the reverse
    function sim:report(from, to)
        from = from or 1
        to = math.min(to or self.svLast, self.svLast, self.k)
        local errs, lateFlags, staleFlags = {}, {}, {}
        for n = from, to do
            local s, d = self.svHist[n], self.shown[n]
            if s and d and not s.tumbling and not d.spectating then
                errs[#errs + 1] = (d.pos - s.pos):Length()
            end
            if s and d then
                local g = d.rail or (d.flag and not self.clTook)
                lateFlags[n] = s.grind and not g
                staleFlags[n] = g and not s.grind
            end
        end
        local corr, snaps, big = {}, 0, 0
        local t0, t1 = from, to
        for _, c in ipairs(self.corrections) do
            if c.k >= t0 and c.k <= t1 + 20 and not c.tumble then
                corr[#corr + 1] = c.d
                if c.d > 1 then big = big + 1 end
                if c.d > NS.SNAP then snaps = snaps + 1 end
            end
        end
        local cs = stats(corr)
        return { err = stats(errs), corr = cs, corrOver1 = big, snaps = snaps, replays = self.replays,
                 grindLate = runs(lateFlags, from, to), grindStale = runs(staleFlags, from, to),
                 lost = { up = up.lost + up.late, down = down.lost + down.late } }
    end

    return sim
end

--------------------------------------------------------------------------
-- THE BIKE, under the same link: the server's physics, the client drawing
-- snapshots `interp` behind (cl_interp 0.1), never predicting a position.
--
--   opts = { rtt, jitter, loss, seed, solids, y, yaw, speed, interp = 0.1 }
--------------------------------------------------------------------------
function NS.Bike(opts)
    opts = opts or {}
    local DT = NS.DT
    local solids = opts.solids and opts.solids(require("lib.vecang").Vector) or nil
    local sv = F.server({ solids = solids })
    local E = sv.env
    band, bor, bnot = E.bit.band, E.bit.bor, E.bit.bnot
    local bike = F.bike(sv)
    local ply = F.rider(sv, bike, { name = "Rider" })
    sv:run(0.3)
    local ang = E.Angle(0, opts.yaw or 0, 0)
    F.place(bike, E.Vector(opts.x or 0, opts.y or 0, F.restHeight(sv)), ang)
    bike:GetPhysicsObject():SetVelocity(ang:Forward() * (opts.speed or 0))
    local rng = NS.rng(opts.seed or 7)
    local owd = (opts.rtt or 0.1) / 2
    local up = NS.link(rng, owd, opts.jitter or 0.02, opts.loss or 0.01)
    local down = NS.link(rng, owd, opts.jitter or 0.02, opts.loss or 0.01)
    local interp = opts.interp or 0.1
    local cmdEvery, snapEvery, backup = opts.cmdEvery or 2, opts.snapEvery or 2, opts.backup or 2

    local sim = { sv = sv, bike = bike, ply = ply, k = 0, t0 = sv.world.time, cmds = {}, sentUpTo = 0,
                  svLast = 0, svCmds = {}, hist = {}, snaps = {}, drawn = {}, viewYaw = opts.yaw or 0 }

    -- The server's position at server time t, between the two ticks either side of it.
    local function at(hist, t)
        for i = #hist, 1, -1 do
            local a, b = hist[i], hist[i + 1]
            if a.t <= t then
                if not b then return { pos = a.pos } end
                return { pos = a.pos + (b.pos - a.pos) * ((t - a.t) / (b.t - a.t)) }
            end
        end
        return hist[1]
    end

    function sim:step(h)
        h = h or {}
        self.k = self.k + 1
        local k, now = self.k, self.k * DT
        self.viewYaw = self.viewYaw + (h.turn or 0)
        local c = newCmd(E, { n = k, buttons = buttonsOf(h), yaw = self.viewYaw,
            fwd = (h.w and 10000 or 0) - (h.s and 10000 or 0), side = (h.d and 10000 or 0) - (h.a and 10000 or 0) })
        self.cmds[k] = c
        if k % cmdEvery == 0 then
            local list = {}
            for n = math.max(1, self.sentUpTo + 1 - backup), k do list[#list + 1] = self.cmds[n]:Copy() end
            up:send(now, list)
            self.sentUpTo = k
        end
        -- SERVER: the commands that came, in order (a lost one: the last again), then a tick.
        for _, pk in ipairs(up:recv(now)) do
            for _, cc in ipairs(pk) do
                if cc.n > self.svLast and not self.svCmds[cc.n] then self.svCmds[cc.n] = cc end
            end
        end
        local newest = self.svLast
        for n in pairs(self.svCmds) do if n > newest then newest = n end end
        for n = self.svLast + 1, newest do
            local cc = self.svCmds[n] or (self.lastCmd and self.lastCmd:Copy())
            if cc then
                cc.n = n
                E.hook.Run("StartCommand", ply, cc:Copy())
                self.lastCmd = cc
            end
            self.svLast = n
        end
        sv:tick()
        local st = bike.st
        local rec = { t = now, pos = bike:GetPos(), grind = st.grind ~= nil, grounded = st.grounded and true or false }
        self.hist[#self.hist + 1] = rec
        if k % snapEvery == 0 then down:send(now, rec) end
        -- CLIENT: the snapshots that came, then draw at now - owd - interp.
        for _, s in ipairs(down:recv(now)) do self.snaps[#self.snaps + 1] = s end
        local tr = now - owd - interp
        local a, b
        for i = #self.snaps, 1, -1 do
            if self.snaps[i].t <= tr then a, b = self.snaps[i], self.snaps[i + 1] break end
        end
        local pos, grind
        if a and b then
            local f = (tr - a.t) / (b.t - a.t)
            pos, grind = a.pos + (b.pos - a.pos) * f, a.grind
        elseif a then
            pos, grind = a.pos, a.grind                -- starved: hold the last
        end
        self.drawn[k] = pos and { pos = pos, grind = grind, tr = tr }
        return self
    end

    function sim:play(n, hands)
        for _ = 1, n do self:step(hands and hands(self.k + 1, self) or nil) end
        return self
    end

    --   lag     the drawn bike against the server's bike NOW, units (what the
    --           rider sees is this far behind where the bike is)
    --   err     the drawn bike against the server's bike at the time drawn,
    --           units (the interpolation's own error: loss, jitter)
    --   jumps   frames where that error changed by more than NS.SNAP
    --   grindLate  ms from the server's grind start to the drawn one
    function sim:report(from, to)
        from = from or 1
        to = math.min(to or self.k, self.k)
        local lag, err, jumps, prev = {}, {}, 0, nil
        for k = from, to do
            local d, now = self.drawn[k], self.hist[k]
            if d and now then
                lag[#lag + 1] = (d.pos - now.pos):Length()
                local truth = at(self.hist, d.tr)
                local e = truth and (d.pos - truth.pos):Length() or 0
                err[#err + 1] = e
                if prev and math.abs(e - prev) > NS.SNAP then jumps = jumps + 1 end
                prev = e
            end
        end
        local svStart, drawnStart, svEnd, drawnEnd
        for k = from, to do
            local now, d = self.hist[k], self.drawn[k]
            if now and now.grind and not svStart then svStart = k end
            if now and svStart and not now.grind and not svEnd then svEnd = k end
            if d and d.grind and not drawnStart then drawnStart = k end
            if d and drawnStart and not d.grind and not drawnEnd then drawnEnd = k end
        end
        return { lag = stats(lag), err = stats(err), jumps = jumps,
                 grindLate = (svStart and drawnStart) and (drawnStart - svStart) * NS.DT * 1000 or nil,
                 grindEndLate = (svEnd and drawnEnd) and (drawnEnd - svEnd) * NS.DT * 1000 or nil }
    end

    return sim
end

return NS
