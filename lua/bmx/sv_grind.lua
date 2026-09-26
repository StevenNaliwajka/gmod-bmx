--[[--------------------------------------------------------------------------
    bmx/sv_grind.lua

    Grinding: hop onto a rail or the edge of a ledge, moving roughly along
    it, and the bike locks on and slides until the rail ends, you hop off, or
    it runs out of speed.

        crank grind       a pipe under the middle of the bike, the chainring on
                          it, the bike turned across it so a wheel hangs down
                          either side
        double peg grind  an edge: the bike off the drop side, both pegs on top

    NOTHING IN THE MAP IS MARKED. A rail is found by tracing down round the
    point the bike would grind on: the highest surface in reach is the top;
    if everything round it is that high too it is just the ground, and if the
    ground falls away on BOTH sides within pipeMaxWidth it is a pipe, on ONE
    side an edge. So brush rails, props, kerbs and coping all work, in any map.

    ON THE RAIL THE BIKE IS PLACED, NOT PUSHED. Every substep the rail is found
    again a step further along (which is what follows a curved or sloped rail,
    and what notices it has ended), and the bike's position, angles and
    velocity are set on its physics object. Forces would have to fight the
    contact with the rail and the wheels' suspension, which would be tuning a
    fight rather than modelling a grind; and the grind is an arcade move, so
    it is written as one.

    Config: C.Grind in sh_config.lua.
----------------------------------------------------------------------------]]

BMX = BMX or {}

local abs, min, max, sqrt, floor = math.abs, math.min, math.max, math.sqrt, math.floor
local UP = Vector(0, 0, 1)

local NAMES = { crank = "Crank Grind", peg = "Double Peg Grind" }

-- A player or an NPC is not a rail.
local function solidOK(tr)
    local e = tr.Entity
    if e and IsValid(e) and (e.IsPlayer and e:IsPlayer() or e.IsNPC and e:IsNPC()) then
        return false
    end
    return true
end

local function down(p, from, to, filter)
    return util.TraceLine({ start = Vector(p.x, p.y, from), endpos = Vector(p.x, p.y, to),
        filter = filter, mask = MASK_SOLID })
end

-- What is at (x, y), judged against a rail top at zTop:
--   "on"    the top is here (within topTol)
--   "off"   it falls away (nothing, or lower than zTop - topTol)
--   "wall"  something rises out of it: this is not an edge to hang off
local function probe(p, zTop, G, filter)
    local tr = down(p, zTop + 3, zTop - G.drop - 4, filter)
    if tr.StartSolid then return "wall" end
    if not tr.Hit or not solidOK(tr) then return "off" end
    local z = tr.HitPos.z
    if z > zTop + G.topTol then return "wall" end
    if z >= zTop - G.topTol then return "on", z end
    return "off"
end

-- How far from `from` (on the top) along `dir` the top ends. nil if it does
-- not end within `maxd`, or ends in a wall.
local function edgeDist(from, dir, zTop, maxd, G, filter)
    local step, last = 1.5, 0
    local d = step
    while d <= maxd + 1e-6 do
        local what = probe(from + dir * d, zTop, G, filter)
        if what == "wall" then return nil end
        if what == "off" then
            local a, b = last, d
            for _ = 1, 4 do
                local m = (a + b) * 0.5
                if probe(from + dir * m, zTop, G, filter) == "on" then a = m else b = m end
            end
            return (a + b) * 0.5
        end
        last = d
        d = d + step
    end
    return nil
end

-- The horizontal unit vector a quarter turn left of `d`.
local function perp(d)
    local v = Vector(-d.y, d.x, 0)
    local l = v:Length()
    return l > 1e-6 and v / l or Vector(0, 1, 0)
end

-- Put the grind line under `guess` again: for a pipe its centre line, for an
-- edge the edge itself. `rail` carries the kind, the horizontal perpendicular
-- `n` and, for an edge, `side` (horizontal, pointing onto the top). Returns
-- the point on the grind line and its top height, or nil if there is no rail
-- there any more.
local function locate(rail, guess, zGuess, G, filter)
    local n = rail.n
    -- Find the top near the guess. A thin pipe is easy to miss with one line
    -- straight down, so look either side as well.
    local base, zTop
    local offs = { 0, 1.5, -1.5, 3, -3 }
    if rail.kind == "peg" then offs = { 1, 2.5, 0, 4 } end
    for _, o in ipairs(offs) do
        local p = guess + (rail.kind == "peg" and rail.side or n) * o
        local tr = down(p, zGuess + G.drop, zGuess - G.drop, filter)
        if tr.Hit and not tr.StartSolid and solidOK(tr) and tr.HitNormal.z > 0.3 then
            base, zTop = Vector(p.x, p.y, 0), tr.HitPos.z
            break
        end
    end
    if not base then return nil end

    if rail.kind == "crank" then
        local a = edgeDist(base, n, zTop, G.edgeSearch, G, filter)
        local b = edgeDist(base, -n, zTop, G.edgeSearch, G, filter)
        if not a or not b or a + b > G.pipeMaxWidth then return nil end
        local c = base + n * ((a - b) * 0.5)
        return Vector(c.x, c.y, zTop), zTop
    end
    local e = edgeDist(base, -rail.side, zTop, G.edgeSearch, G, filter)
    if not e then return nil end
    local c = base - rail.side * e
    return Vector(c.x, c.y, zTop), zTop
end

--------------------------------------------------------------------------
-- Is there a rail under `point`? Returns a rail table, or nil.
--
--   kind   "crank" (a pipe) or "peg" (an edge)
--   point  on the grind line: the pipe's top centre, or the edge's top
--   dir    unit, along the rail (with its slope), signed along `vel`
--   n      horizontal unit perpendicular to it
--   side   for an edge: horizontal unit pointing onto the top
--------------------------------------------------------------------------
function BMX.FindRail(point, vel, cfg, filter, centre)
    local G = (cfg or BMX.Config).Grind

    -- 1. The highest surface within the snap window, over a small grid.
    local cells, zTop = {}, nil
    local h = G.reach / 2
    for i = -2, 2 do
        for j = -2, 2 do
            local p = point + Vector(i * h, j * h, 0)
            local tr = down(p, point.z + G.snapBelow, point.z - G.snapAbove, filter)
            local z = nil
            if tr.Hit and not tr.StartSolid and solidOK(tr) and tr.HitNormal.z > 0.3 then
                z = tr.HitPos.z
                if not zTop or z > zTop then zTop = z end
            end
            cells[#cells + 1] = { p = p, z = z }
        end
    end
    if not zTop then return nil end

    -- Everything that high: flat ground or a ramp, not a rail.
    local sx, sy, on, off = 0, 0, 0, 0
    for _, c in ipairs(cells) do
        if c.z and c.z >= zTop - G.topTol then
            on = on + 1
            sx, sy = sx + c.p.x, sy + c.p.y
        elseif not c.z or c.z < zTop - G.drop then
            off = off + 1
        end
    end
    if off == 0 or on == 0 then return nil end
    local T = Vector(sx / on, sy / on, zTop)

    -- 2. Which way it runs: a ring round the top. A pipe is on in two
    -- opposite directions; an edge is on over half the ring.
    local mx, my, c2, s2, nOn = 0, 0, 0, 0, 0
    local N = 12
    for k = 0, N - 1 do
        local a = k * (2 * math.pi / N)
        local d = Vector(math.cos(a), math.sin(a), 0)
        if probe(T + d * G.ring, zTop, G, filter) == "on" then
            nOn = nOn + 1
            mx, my = mx + d.x, my + d.y
            c2, s2 = c2 + math.cos(2 * a), s2 + math.sin(2 * a)
        end
    end
    if nOn == 0 or nOn == N then return nil end
    local axis
    local mLen = sqrt(mx * mx + my * my) / nOn
    if mLen > 0.35 then
        -- Half the ring is on: an edge, running across the mean direction.
        axis = perp(Vector(mx, my, 0))
    else
        local th = math.atan2(s2, c2) * 0.5
        axis = Vector(math.cos(th), math.sin(th), 0)
    end
    local n = perp(axis)

    -- 3. Across it: a pipe ends both sides, close together; an edge one side
    -- (or a wide beam both sides, far apart: then grind the edge nearer the
    -- bike).
    local a = edgeDist(T, n, zTop, G.edgeSearch, G, filter)
    local b = edgeDist(T, -n, zTop, G.edgeSearch, G, filter)
    local rail
    if a and b and a + b <= G.pipeMaxWidth then
        local c = T + n * ((a - b) * 0.5)
        rail = { kind = "crank", point = Vector(c.x, c.y, zTop), n = n }
    elseif a or b then
        local useA = a ~= nil
        if a and b and centre then useA = (centre - T):Dot(n) >= 0 end
        local side = useA and -n or n                -- onto the top
        local e = T - side * (useA and a or b)
        rail = { kind = "peg", point = Vector(e.x, e.y, zTop), n = n, side = side }
    else
        return nil
    end

    -- 4. The slope: find the line again a little way along each direction.
    local p1 = locate(rail, rail.point + axis * 6, zTop, G, filter)
    local p0 = locate(rail, rail.point - axis * 6, zTop, G, filter)
    local dir
    if p1 and p0 and (p1 - p0):Length() > 4 then
        dir = (p1 - p0):GetNormalized()
    elseif p1 then
        dir = (p1 - rail.point):GetNormalized()
    elseif p0 then
        dir = (rail.point - p0):GetNormalized()
    else
        dir = axis
    end
    if dir:Dot(vel) < 0 then dir = -dir end
    rail.dir = dir
    return rail
end

--------------------------------------------------------------------------
-- Where the bike goes for a grind: its origin and angles.
--------------------------------------------------------------------------
function BMX.GrindPose(g, cfg)
    local G = cfg.Grind
    local f = g.dir
    if g.kind == "crank" then
        local th = g.yawSide * G.crankYaw
        local c, s = math.cos(th), math.sin(th)
        f = Vector(f.x * c - f.y * s, f.x * s + f.y * c, f.z)
    end
    local ang = f:Angle()
    ang.r = 0
    local L = g.localPoint
    local fa, ra, ua = ang:Forward(), ang:Right(), ang:Up()
    -- Entity:LocalToWorld without an entity: local +Y is -Right.
    local offset = fa * L.x - ra * L.y + ua * L.z
    return g.point + UP * G.clearance - offset, ang
end

--------------------------------------------------------------------------
-- IS THERE ROOM FOR THE BIKE THERE? A grind pose that overlaps the world is
-- the launch: while grinding, the bike is set in place every substep and the
-- overlap does nothing, but the moment it lets go VPhysics pushes the hull
-- out of whatever it is inside, all at once, and the bike is thrown. The
-- first version put the rear wheel's collision box 0.2 units below a pipe's
-- top and 1.4 off its centre line, so any pipe thicker than a signpole was
-- inside it for the whole grind.
--
-- Every collision box of the bike (sh_util.lua, BMX.CollisionBoxes) is
-- checked in the pose: a line down each of its four vertical edges and its
-- middle. Anything in the way and the pose is refused: a grind is not
-- started there, and one under way ends at the last pose that was clear.
--------------------------------------------------------------------------
function BMX.GrindPoseClear(pos, ang, cfg, filter)
    local fa, ra, ua = ang:Forward(), ang:Right(), ang:Up()
    local function world(v) return pos + fa * v.x - ra * v.y + ua * v.z end
    for _, b in ipairs(BMX.CollisionBoxes(cfg)) do
        local lo, hi = b[1], b[2]
        local cx, cy = (lo.x + hi.x) * 0.5, (lo.y + hi.y) * 0.5
        for _, xy in ipairs({ { lo.x, lo.y }, { lo.x, hi.y }, { hi.x, lo.y },
                               { hi.x, hi.y }, { cx, cy } }) do
            local tr = util.TraceLine({
                start  = world(Vector(xy[1], xy[2], hi.z)),
                endpos = world(Vector(xy[1], xy[2], lo.z)),
                filter = filter, mask = MASK_SOLID,
            })
            if tr.Hit or tr.StartSolid then return false end
        end
    end
    return true
end

local function place(ent, phys, g, cfg)
    local pos, ang = BMX.GrindPose(g, cfg)
    phys:SetAngles(ang)
    phys:SetPos(pos)
    phys:SetVelocity(g.dir * g.speed)
    phys:SetAngleVelocity(Vector(0, 0, 0))
end

-- The wheels are off the ground: no load, and they wind down on their
-- bearings the way they do in the air.
local function freeWheels(ent, dt)
    for _, w in ipairs(ent.wheels or {}) do
        w.onGround, w.load, w.slipLong, w.slipLat = false, 0, 0, 0
        w.latForce, w.saturation, w.compression = 0, 0, 0
        w.omega = (w.omega or 0) * (1 - min(0.4 * dt, 0.5))
        w.spinAngle = (w.spinAngle or 0) + w.omega * dt
    end
end

local function code(g)
    if g.kind == "crank" then return 1 end
    return g.localPoint.y > 0 and 2 or 3
end

--------------------------------------------------------------------------
-- Try to lock on. Called each substep while not grinding; true if it did.
--------------------------------------------------------------------------
function BMX.TryGrind(ent, phys, cfg, st, vel)
    local G = cfg.Grind
    if not G or not G.enabled then return false end
    if CurTime() < (st.grindReady or 0) then return false end
    if st.grounded and (st.groundedFor or 0) > G.landedWindow then return false end
    if vel.z > G.maxEntryVz then return false end
    local vh = Vector(vel.x, vel.y, 0)
    if vh:Length() < G.minSpeed then return false end

    local crank = BMX.GrindCrankPoint(cfg)
    local point = ent:LocalToWorld(crank)
    local centre = phys:LocalToWorld(phys:GetMassCenter())
    local rail = BMX.FindRail(point, vel, cfg, ent.traceFilter, centre)
    if not rail then return false end

    local along = vel:Dot(rail.dir)
    if along < G.minSpeed then return false end
    local dh = Vector(rail.dir.x, rail.dir.y, 0):GetNormalized()
    if math.acos(BMX.Clamp(vh:GetNormalized():Dot(dh), -1, 1)) > G.maxEntryAngle then
        return false
    end

    local g = { kind = rail.kind, point = rail.point, dir = rail.dir, n = rail.n,
                side = rail.side, speed = along, started = CurTime() }
    if rail.kind == "crank" then
        -- The pipe meets the chainring, or the wheel boxes' floor if that is
        -- lower: the boxes then clear the pipe instead of sitting in it.
        local CH, W = cfg.Chassis, cfg.Wheel
        local floor = CH.wheelHullBottom or -(W.radius - W.restLength)
        g.localPoint = Vector(crank.x, crank.y, math.min(crank.z, floor))
        -- Turn the way the bike is already turned off the pipe.
        local f = ent:GetForward()
        g.yawSide = (dh.x * f.y - dh.y * f.x) >= 0 and 1 or -1
    else
        -- Pegs on the side the top is on; the bike hangs off the other.
        local left = UP:Cross(dh)
        local sgn = left:Dot(rail.side) > 0 and 1 or -1
        g.localPoint = Vector(0, sgn * G.pegY, G.pegZ)
        g.point = g.point + rail.side * G.pegInset
    end
    g.n = perp(dh)

    local pos, ang = BMX.GrindPose(g, cfg)
    if not BMX.GrindPoseClear(pos, ang, cfg, ent.traceFilter) then return false end

    -- Landed a trick onto it: that trick is paid now, the grind on its own
    -- when it ends.
    if st.airMode then
        st.airMode = false
        local tricks = BMX.ScoreAir(st)
        if #tricks > 0 and ent.AwardTricks then ent:AwardTricks(tricks) end
    end

    ent.bmxTouchdown = nil
    st.airSince = 0
    st.grind = g
    st.grounded = true
    if ent.SetGrind then ent:SetGrind(code(g)) end
    place(ent, phys, g, cfg)
    hook.Run("BMX_GrindStarted", ent, g.kind)
    return true
end

--------------------------------------------------------------------------
-- Off the rail. `why` is "hop", "end", "slow" or "rider".
--------------------------------------------------------------------------
function BMX.EndGrind(ent, phys, cfg, st, why, charge)
    local g = st.grind
    if not g then return end
    local G = cfg.Grind
    st.grind = nil
    if ent.SetGrind then ent:SetGrind(0) end

    local vel = g.dir * max(g.speed, 0)
    if why == "hop" then
        vel = vel + UP * (G.hopSpeed * (charge or 1))
        if g.side then vel = vel - g.side * G.hopAway end
    end
    phys:SetVelocity(vel)
    phys:SetAngleVelocity(Vector(0, 0, 0))
    st.grindExit = { vel = vel, untilT = CurTime() + G.exitGuard }

    st.grindReady = CurTime() + G.cooldown
    st.grindEnded = CurTime()
    st.grounded, st.groundedFor = false, 0
    st.airSince, st.airMode = 0, false
    -- The rate estimates must not differentiate across the grind.
    st.roll, st.pitch = BMX.Attitude(ent, vector_up)
    st.lastRoll, st.lastPitch = st.roll, st.pitch
    st.rollRate, st.pitchRate = 0, 0

    local t = CurTime() - g.started
    if t >= G.minTime and ent.AwardTricks and IsValid(ent:GetDriver()) then
        ent:AwardTricks({ { name = NAMES[g.kind], count = 1,
                            points = floor(t * G.pointsPerSec) } })
    end
    hook.Run("BMX_GrindEnded", ent, g.kind, why, t)
end

--------------------------------------------------------------------------
-- One substep on the rail.
--------------------------------------------------------------------------
function BMX.GrindStep(ent, phys, cfg, dt, inp, st)
    local g = st.grind
    local G = cfg.Grind
    freeWheels(ent, dt)

    -- Hop off: the jump key, charged or not.
    if ent.hopHeld then
        ent.hopCharge = min(cfg.Hop.chargeTime, (ent.hopCharge or 0) + dt)
    end
    if ent.hopRelease then
        ent.hopRelease, ent.hopHeld = false, false
        -- A tap is enough to get off: the rail is already under the bike, so
        -- there is no preload to wind up, and a quarter hop barely cleared it.
        local charge = max(G.minHop or 0.6, (ent.hopCharge or 0) / cfg.Hop.chargeTime)
        ent.hopCharge = 0
        ent.hopReady = CurTime() + cfg.Hop.cooldown
        return BMX.EndGrind(ent, phys, cfg, st, "hop", charge)
    end

    local brake = max(inp.brakeRear or 0, inp.brakeFront or 0)
    local v = g.speed - physenv.GetGravity():Length() * g.dir.z * dt
        - (G.friction + G.brakeDecel * brake) * dt
    g.speed = v
    if v < G.stopSpeed then return BMX.EndGrind(ent, phys, cfg, st, "slow") end

    local guess = g.point + g.dir * (v * dt)
    local look = g.point
    if g.kind == "peg" then look = g.point - g.side * G.pegInset end
    local p = locate(g, look + g.dir * (v * dt), guess.z, G, ent.traceFilter)
    if not p then return BMX.EndGrind(ent, phys, cfg, st, "end") end
    if g.kind == "peg" then p = p + g.side * G.pegInset end
    -- A rail does not jump. A top found well above or below where this one
    -- was going is something else -- a step, a wall, the ground under the end
    -- of it -- and following it would put the bike inside it.
    if abs(p.z - guess.z) > G.maxStepZ then return BMX.EndGrind(ent, phys, cfg, st, "end") end

    -- Follow the rail round a bend and up or down a slope, smoothly: the
    -- measured line is noisy by a fraction of a unit per step.
    local step = p - g.point
    if step:Length() > 0.25 then
        local d = step:GetNormalized()
        if d:Dot(g.dir) > 0.5 then
            g.dir = (g.dir * 0.75 + d * 0.25):GetNormalized()
            g.n = perp(g.dir)
            if g.side then
                -- Keep `side` pointing onto the top as the edge turns.
                g.side = g.n:Dot(g.side) >= 0 and g.n or -g.n
            end
        end
    end
    local oldPoint, oldDir, oldN, oldSide = g.point, g.dir, g.n, g.side
    g.point = p
    local pos, ang = BMX.GrindPose(g, cfg)
    if not BMX.GrindPoseClear(pos, ang, cfg, ent.traceFilter) then
        -- No room further on: let go from the last pose that had it.
        g.point, g.dir, g.n, g.side = oldPoint, oldDir, oldN, oldSide
        return BMX.EndGrind(ent, phys, cfg, st, "blocked")
    end

    st.speed, st.fwdSpeed = v, v
    st.grindTime = CurTime() - g.started
    place(ent, phys, g, cfg)
end
