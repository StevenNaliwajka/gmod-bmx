--[[--------------------------------------------------------------------------
    bmx/sh_railfind.lua

    THE RAIL FINDER, shared. Split out of sv_grind.lua (2026-11-09) so a client
    can run it too: the skates' prediction (cl_skates.lua) locks onto a rail at
    the same command the server does, instead of landing on the rail's top for a
    ping and being corrected once the server's grind flag arrives (G30, the
    known limit in docs/goals/G30-netcode-feel.md). Everything here is a
    function of the map's geometry and its arguments: no entity, no state.

    BMX.FindRail, BMX.MightBeRail, BMX.GrindPose, BMX.GrindPoseClear, and the
    tracking step's BMX.RailLocate / BMX.RailPerp (sv_grind.lua's substeps).
----------------------------------------------------------------------------]]

BMX = BMX or {}

local abs, min, max, sqrt, floor = math.abs, math.min, math.max, math.sqrt, math.floor
local UP = Vector(0, 0, 1)


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
    if not tr.Hit or not solidOK(tr) then return "off", nil end
    local z = tr.HitPos.z
    if z > zTop + G.topTol then return "wall" end
    if z >= zTop - G.topTol then return "on", z end
    return "off", z
end

-- A REAL DROP, not a slope. Just past where the top ends, the surface must
-- be at least `drop` lower (or not there at all). Without this a bare ramp
-- was an "edge": its surface falls away to one side of any point on it, so
-- a bike flying across a 15-40 degree slope locked into a peg grind on
-- nothing, pinned into the ramp. Measured in tests/test_grind.lua.
local function dropsAt(p, zTop, G, filter)
    local tr = down(p, zTop + 3, zTop - G.drop - 4, filter)
    if tr.StartSolid then return false end
    if not tr.Hit or not solidOK(tr) then return true end
    return tr.HitPos.z < zTop - G.drop
end

-- How far from `from` (on the top) along `dir` the top ends. nil if it does
-- not end within `maxd`, or ends in a wall.
local function edgeDist(from, dir, zTop, maxd, G, filter, quick)
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
            local edge = (a + b) * 0.5
            if not quick and not dropsAt(from + dir * (edge + G.edgeCheck), zTop, G, filter) then
                return nil
            end
            return edge
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
--
-- `quick` is the per-substep tracking case: a rail already known to be a rail
-- is followed along ONE side (a pipe's centre is that edge less half the
-- width it was measured at), without re-proving the drop. Every few substeps
-- it is found in full again, so a rail that widens or runs out onto a ramp is
-- still noticed within a tenth of a second.
local function locate(rail, guess, zGuess, G, filter, quick)
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
        if quick and rail.width then
            local a = edgeDist(base, n, zTop, G.edgeSearch, G, filter, true)
            if not a then return nil end
            local c = base + n * (a - rail.width * 0.5)
            return Vector(c.x, c.y, zTop), zTop
        end
        local a = edgeDist(base, n, zTop, G.edgeSearch, G, filter)
        local b = edgeDist(base, -n, zTop, G.edgeSearch, G, filter)
        if not a or not b or a + b > G.pipeMaxWidth then return nil end
        rail.width = a + b
        local c = base + n * ((a - b) * 0.5)
        return Vector(c.x, c.y, zTop), zTop
    end
    local e = edgeDist(base, -rail.side, zTop, G.edgeSearch, G, filter, quick)
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
        rail = { kind = "crank", point = Vector(c.x, c.y, zTop), n = n, width = a + b }
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
    -- A bike on a pipe is turned across it by Grind.crankYaw; a move of a vehicle's
    -- own (g.yaw, a board's: along the rail, angled to it, across it) says how far.
    if g.kind == "crank" or g.yaw then
        local th = g.yaw or (g.yawSide * G.crankYaw)
        local c, s = math.cos(th), math.sin(th)
        f = Vector(f.x * c - f.y * s, f.x * s + f.y * c, f.z)
    end
    local ang = f:Angle()
    ang.r = 0
    -- ...and the angle the nose is held at (g.pitch, radians, nose up): a 5-0 or a
    -- nosegrind. The contact point below is found in the pitched frame, so it stays
    -- on the rail.
    if g.pitch then ang.p = ang.p - math.deg(g.pitch) end
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
--
-- `low` checks only the boxes that hang down beside a rail -- the wheels and
-- the pegs, corners only -- which is what a grind under way can run into from
-- one substep to the next; the whole bike is checked on the way on, and again
-- every Grind.fullEvery substeps.
function BMX.GrindPoseClear(pos, ang, cfg, filter, low)
    local fa, ra, ua = ang:Forward(), ang:Right(), ang:Up()
    local function world(v) return pos + fa * v.x - ra * v.y + ua * v.z end
    local boxes = BMX.CollisionBoxes(cfg)
    for i, b in ipairs(boxes) do
        local lo, hi = b[1], b[2]
        local cx, cy = (lo.x + hi.x) * 0.5, (lo.y + hi.y) * 0.5
        local pts = { { lo.x, lo.y }, { lo.x, hi.y }, { hi.x, lo.y }, { hi.x, hi.y } }
        if not low then pts[5] = { cx, cy } end
        -- Box 1 is the body and the last the bars: high, and only checked in full.
        if low and (i == 1 or (cfg.Chassis.barHullCentre and i == #boxes)) then pts = {} end
        for _, xy in ipairs(pts) do
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

--------------------------------------------------------------------------
-- CHEAP FIRST. The full search (FindRail) is ~40 traces, and TryGrind runs
-- on every airborne substep -- 66 a second, per bike, for every jump -- where
-- nearly always the answer is "that is just the ground". So two quick
-- questions before it:
--
--   1. Is there anything at all in the lock-on window? One hull the size of
--      the search, swept down through it. High in the air: no, done.
--   2. Is it one plane? Five lines: the middle and the four corners. If all
--      five hit, facing the same way, with each diagonal's ends averaging
--      to the middle, it is flat ground or an even ramp, and neither is a
--      rail. (A rail or an edge breaks the plane: a corner misses, or drops.)
--
-- Only what survives both pays for the search. Measured in
-- tests/test_perf.lua: in the air over flat ground 27 traces a tick -> 8.
--------------------------------------------------------------------------
function BMX.MightBeRail(point, cfg, filter)
    local G = cfg.Grind
    local r = G.reach
    local pre = util.TraceHull({ start = point + UP * G.snapBelow, endpos = point - UP * G.snapAbove,
        mins = Vector(-r, -r, 0), maxs = Vector(r, r, 0.5), filter = filter, mask = MASK_SOLID })
    if not pre.Hit then return false end
    if pre.StartSolid then return true end

    local z, n = {}, nil
    local offs = { Vector(0, 0, 0), Vector(r, r, 0), Vector(-r, -r, 0), Vector(r, -r, 0), Vector(-r, r, 0) }
    for i, o in ipairs(offs) do
        local p = point + o
        local tr = down(p, point.z + G.snapBelow, point.z - G.snapAbove - G.drop, filter)
        if not tr.Hit or tr.StartSolid or not solidOK(tr) then return true end
        if i == 1 then
            n = tr.HitNormal
        elseif tr.HitNormal:Dot(n) < 0.98 then
            return true
        end
        z[i] = tr.HitPos.z
    end
    local tol = 0.5
    if abs(z[2] + z[3] - 2 * z[1]) > tol or abs(z[4] + z[5] - 2 * z[1]) > tol then return true end
    return false
end

BMX.RailLocate, BMX.RailPerp = locate, perp
