--[[--------------------------------------------------------------------------
    bmx/sv_nav.lua

    A navmesh a BIKE can use, and the trick spots on it.

        bmx_nav_build           mesh this map (props and park pieces included),
                                save it as maps/<map>.nav
        bmx_nav_status          what is loaded, and what the catalog found
        bmx_nav_catalog         find the trick spots again (runways, launches,
                                rails)

    WHY NOT nav_generate. The engine's generator only sees BRUSHES. On
    gm_skatepark every ramp is a prop_dynamic, so its mesh is 84 big floor
    areas that run straight under the halfpipe, the funboxes and the spines:
    a path through them rides into a wall. This one traces with MASK_SOLID,
    the way a wheel does, so a ramp is a ramp:

      1. HEIGHTFIELD. A grid of vertices (Nav.Config.cell apart) over the map,
         each traced straight down to the first surface. Sky and start-solid
         are traced through.
      2. CELLS. A square between four vertices is rideable when it is planar
         (the centre sample on the corners' plane, no twist), no steeper than
         maxSlope, and there is room above it for a rider (a hull swept up
         from the top corner). A cell across a step, a rail or a ramp's side
         wall is not planar, so the mesh breaks there -- which is exactly
         where a bike cannot roll across.
      3. MERGE. Coplanar cells merge greedily into rectangles (at most
         maxMerge cells a side, so paths stay smooth), one NavArea each, with
         its four corners at the real heights: a ramp's areas slope.
      4. LINKS. Two areas link where they share a cell edge. Neighbouring
         cells share their vertices, so a shared edge is at one height by
         construction: nothing links across a step.

    Park pieces are meshed too (they are solid). Placing or removing one
    REMESHES the ground under it (Nav.Remesh), in memory; the saved file is
    the map as it ships.

    THE CATALOG is what the trick bot (BMX (Mode), sv_botnav.lua) uses: RUNWAYS
    (straight, flat, clear stretches, longest first), LAUNCHES (BMX.FindLaunch
    from points all over the mesh, deduplicated by lip) and RAILS (a park
    piece's grind lines, and thin long map props). It is found once per mesh,
    spread over ticks.

    The pure parts (the cell test, the merge, the A*) take plain tables and
    are tested offline (tests/test_nav.lua).
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Nav = BMX.Nav or {}
local Nav = BMX.Nav

local UP = Vector(0, 0, 1)
local abs, sqrt, max, min, floor = math.abs, math.sqrt, math.max, math.min, math.floor

Nav.Config = {
    cell      = 32,     -- u between heightfield vertices
    maxCells  = 300000, -- a bigger map gets a coarser grid
    planeTol  = 3,      -- u a cell may be off its plane (curves are chords)
    maxSlope  = 50,     -- deg; a quarter pipe's top is not somewhere to ride TO
    clear     = 56,     -- u of room above the surface for a rider
    maxMerge  = 12,     -- cells a side of one area
    budget    = 0.004,  -- s of traces per tick while building
    flatSlope = 4,      -- deg still counted flat for a runway
    runStep   = 32,     -- u between runway samples
    runMin    = 500,    -- u: shorter than this is not a runway
    runMax    = 2400,
}

Nav.cells = Nav.cells or nil      -- the last build's grid (for remeshing)
Nav.catalog = Nav.catalog or { runways = {}, launches = {}, rails = {}, at = 0 }
Nav.version = Nav.version or 0    -- bumps on every mesh change

-- A mesh to use: loaded, and not empty.
local function meshed() return navmesh ~= nil and navmesh.GetNavAreaCount() > 0 end
Nav.Meshed = meshed

--------------------------------------------------------------------------
-- Pure: the cell test. `c` = { z00, z10, z01, z11, zc } (x then y), `s` the
-- cell size. Returns ok, slope (deg), why.
--------------------------------------------------------------------------
function Nav.CellPlane(c, s, C)
    C = C or Nav.Config
    if not (c.z00 and c.z10 and c.z01 and c.z11 and c.zc) then return false, 0, "no ground" end
    local twist = abs((c.z00 + c.z11) - (c.z10 + c.z01))
    if twist > C.planeTol * 2 then return false, 0, "twisted" end
    local avg = (c.z00 + c.z10 + c.z01 + c.z11) * 0.25
    if abs(c.zc - avg) > C.planeTol then return false, 0, "not planar" end
    local gx = ((c.z10 - c.z00) + (c.z11 - c.z01)) * 0.5 / s
    local gy = ((c.z01 - c.z00) + (c.z11 - c.z10)) * 0.5 / s
    local slope = math.deg(math.atan(sqrt(gx * gx + gy * gy)))
    if slope > C.maxSlope then return false, slope, "too steep" end
    return true, slope, nil, gx, gy
end

--------------------------------------------------------------------------
-- Pure: greedy merge, layer by layer. `cells(i, j)` returns the rideable
-- cells in that column, each { z00, z10, z01, z11 } (a floor under a beam
-- and the beam's top are two). Cells merge with a seed when the seed's plane
-- predicts their corners to within `tol`. Returns rectangles
-- { i0, j0, i1, j1, recs = { [i*65536+j] = cell } } (cells i0..i1-1, j0..j1-1).
--------------------------------------------------------------------------
local CORNER_OF = { { 0, 0, "z00" }, { 1, 0, "z10" }, { 0, 1, "z01" }, { 1, 1, "z11" } }

function Nav.Merge(nx, ny, cells, tol, cap)
    tol, cap = tol or 1, cap or 12
    local function key(i, j) return i * 65536 + j end
    local rects = {}
    for j = 0, ny - 1 do
        for i = 0, nx - 1 do
            for _, seed in ipairs(cells(i, j) or {}) do
                if not seed.used then
                    local z00 = seed.z00
                    local gx, gy = seed.z10 - z00, seed.z01 - z00
                    local function fits(a, b)
                        for _, c in ipairs(cells(a, b) or {}) do
                            if not c.used then
                                local ok = true
                                for _, d in ipairs(CORNER_OF) do
                                    local want = z00 + gx * (a + d[1] - i) + gy * (b + d[2] - j)
                                    if abs(c[d[3]] - want) > tol then ok = false break end
                                end
                                if ok then return c end
                            end
                        end
                    end
                    local recs = { [key(i, j)] = seed }
                    seed.used = true
                    local i1 = i + 1
                    while i1 < nx and i1 - i < cap do
                        local c = fits(i1, j)
                        if not c then break end
                        c.used, recs[key(i1, j)] = true, c
                        i1 = i1 + 1
                    end
                    local j1 = j + 1
                    while j1 < ny and j1 - j < cap do
                        local row = {}
                        for x = i, i1 - 1 do
                            local c = fits(x, j1)
                            if not c then row = nil break end
                            row[x] = c
                        end
                        if not row then break end
                        for x, c in pairs(row) do c.used, recs[key(x, j1)] = true, c end
                        j1 = j1 + 1
                    end
                    rects[#rects + 1] = { i0 = i, j0 = j, i1 = i1, j1 = j1, recs = recs }
                end
            end
        end
    end
    return rects
end

-- Pure: the parts of a graph. `nodes` a list, `nbrs(n)` its neighbours.
-- Returns a list of lists.
function Nav.Components(nodes, nbrs, key)
    key = key or function(n) return n end
    local seen, out = {}, {}
    for _, n in ipairs(nodes) do
        if not seen[key(n)] then
            local comp, stack = {}, { n }
            seen[key(n)] = true
            while #stack > 0 do
                local m = table.remove(stack)
                comp[#comp + 1] = m
                for _, o in ipairs(nbrs(m)) do
                    if not seen[key(o)] then seen[key(o)] = true stack[#stack + 1] = o end
                end
            end
            out[#out + 1] = comp
        end
    end
    return out
end

--------------------------------------------------------------------------
-- Pure: A*. `nbrs(n)` returns a list of { node, cost }, `h(n)` the estimate
-- to the goal, `key(n)` a table key. Returns the node list or nil.
--------------------------------------------------------------------------
local function heapPush(h, item, pri)
    h.n = h.n + 1
    local i = h.n
    h.items[i], h.pri[i] = item, pri
    while i > 1 do
        local p = floor(i / 2)
        if h.pri[p] <= h.pri[i] then break end
        h.items[p], h.items[i] = h.items[i], h.items[p]
        h.pri[p], h.pri[i] = h.pri[i], h.pri[p]
        i = p
    end
end

local function heapPop(h)
    if h.n == 0 then return nil end
    local top = h.items[1]
    h.items[1], h.pri[1] = h.items[h.n], h.pri[h.n]
    h.items[h.n], h.pri[h.n] = nil, nil
    h.n = h.n - 1
    local i = 1
    while true do
        local l, r, s = i * 2, i * 2 + 1, i
        if l <= h.n and h.pri[l] < h.pri[s] then s = l end
        if r <= h.n and h.pri[r] < h.pri[s] then s = r end
        if s == i then break end
        h.items[s], h.items[i] = h.items[i], h.items[s]
        h.pri[s], h.pri[i] = h.pri[i], h.pri[s]
        i = s
    end
    return top
end

function Nav.AStar(start, goal, nbrs, h, key, limit)
    key = key or function(n) return n end
    local open = { n = 0, items = {}, pri = {} }
    local g, from, closed = { [key(start)] = 0 }, {}, {}
    heapPush(open, start, h(start))
    local expanded = 0
    while open.n > 0 do
        local cur = heapPop(open)
        local ck = key(cur)
        if ck == key(goal) then
            local path = { cur }
            while from[key(path[1])] do table.insert(path, 1, from[key(path[1])]) end
            return path, g[ck]
        end
        if not closed[ck] then
            closed[ck] = true
            expanded = expanded + 1
            if limit and expanded > limit then return nil end
            for _, e in ipairs(nbrs(cur)) do
                local nk = key(e[1])
                local ng = g[ck] + e[2]
                if not closed[nk] and (g[nk] == nil or ng < g[nk]) then
                    g[nk], from[nk] = ng, cur
                    heapPush(open, e[1], ng + h(e[1]))
                end
            end
        end
    end
    return nil
end

--------------------------------------------------------------------------
-- The world: tracing the ground.
--------------------------------------------------------------------------
local function groundAt(x, y, top, bottom, filter)
    local from = Vector(x, y, top)
    for _ = 1, 6 do
        local tr = util.TraceLine({ start = from, endpos = Vector(x, y, bottom), mask = MASK_SOLID, filter = filter })
        if tr.StartSolid then
            if tr.FractionLeftSolid >= 1 then return nil end
            from = Vector(x, y, from.z + (bottom - from.z) * tr.FractionLeftSolid - 1)
        elseif not tr.Hit then
            return nil
        elseif tr.HitSky or (tr.HitTexture and tr.HitTexture:find("TOOLSSKYBOX", 1, true)) then
            from = Vector(x, y, tr.HitPos.z - 2)
        else
            return tr.HitPos.z, tr.HitNormal, (not tr.HitWorld) and tr.Entity or nil
        end
    end
    return nil
end
Nav.GroundAt = groundAt

-- Every surface under a point, top down (a beam, the floor under it, ...),
-- up to `layers` of them. Sky is traced through.
local function surfacesAt(x, y, top, bottom, layers)
    local out = {}
    local from = top
    for _ = 1, (layers or 6) + 4 do
        if from <= bottom then break end
        local z, _, ent = groundAt(x, y, from, bottom)
        if not z then break end
        out[#out + 1] = z
        if #out >= (layers or 6) then break end
        from = z - 1
        -- A trace that starts inside an ENTITY never says where it leaves
        -- it (FractionLeftSolid is the world's), so go on from under it: a
        -- subway viaduct over the park is 344 u thick, a ramp sits on the floor.
        if IsValid(ent) then
            local lo = ent:WorldSpaceAABB()
            from = math.min(from, lo.z - 1)
        end
    end
    return out
end
Nav.SurfacesAt = surfacesAt

-- Room above a cell for a rider: a hull swept up from just over its top corner.
local function roomAbove(cx, cy, zTop, half, C, filter)
    local s = Vector(cx, cy, zTop + 3)
    local tr = util.TraceHull({ start = s, endpos = s + UP * C.clear,
        mins = Vector(-half + 2, -half + 2, 0), maxs = Vector(half - 2, half - 2, 4),
        mask = MASK_SOLID, filter = filter })
    return not tr.Hit and not tr.StartSolid
end

-- The map's box: the world's bounds, a little in.
function Nav.WorldBox()
    local lo, hi = game.GetWorld():GetModelBounds()
    return Vector(lo.x + 1, lo.y + 1, lo.z), Vector(hi.x - 1, hi.y - 1, hi.z - 1)
end

local function tickBudget(t0, C)
    if coroutine.running() and SysTime() - t0 > C.budget then
        coroutine.yield()
        return SysTime()
    end
    return t0
end

--------------------------------------------------------------------------
-- Build: sample the heightfield in [lo, hi] and make areas. Runs inside a
-- coroutine (Nav.Run) and yields to keep ticks short. `keep` = areas outside
-- the box are kept and linked to (a remesh); otherwise the mesh is reset.
--------------------------------------------------------------------------
local CORNERS = function()
    return NORTH_WEST or 0, NORTH_EAST or 1, SOUTH_EAST or 2, SOUTH_WEST or 3
end

function Nav.Build(lo, hi, opts)
    opts = opts or {}
    local C = Nav.Config
    local s = C.cell
    while ((hi.x - lo.x) / s) * ((hi.y - lo.y) / s) > C.maxCells do s = s * 1.5 end
    local x0, y0 = floor(lo.x / s) * s, floor(lo.y / s) * s
    local nx, ny = math.ceil((hi.x - x0) / s), math.ceil((hi.y - y0) / s)
    local top, bottom = hi.z, lo.z - 64
    local t0 = SysTime()
    local function vk(i, j) return i * 65536 + j end
    -- How far a corner may sit from the centre and still be one surface:
    -- the steepest slope across half a diagonal, plus the tolerance.
    local reach = s * 0.75 * math.tan(math.rad(C.maxSlope)) + C.planeTol

    -- 1. Vertices: every surface in each column.
    local V = {}
    for j = 0, ny do
        for i = 0, nx do
            V[vk(i, j)] = surfacesAt(x0 + i * s, y0 + j * s, top, bottom)
            t0 = tickBudget(t0, C)
        end
    end
    -- The vertex surface nearest `z`, within `reach`.
    local function near(i, j, z)
        local best, bd
        for _, v in ipairs(V[vk(i, j)] or {}) do
            local d = abs(v - z)
            if d <= reach and (not bd or d < bd) then best, bd = v, d end
        end
        return best
    end

    -- 2. Cells: one per surface the centre column has.
    local CELLS, why = {}, {}
    local function count(w) why[w] = (why[w] or 0) + 1 end
    for j = 0, ny - 1 do
        for i = 0, nx - 1 do
            local cx, cy = x0 + (i + 0.5) * s, y0 + (j + 0.5) * s
            local list = {}
            local centres = surfacesAt(cx, cy, top, bottom)
            if #centres == 0 then count("no ground") end
            for _, zc in ipairs(centres) do
                local c = { zc = zc, z00 = near(i, j, zc), z10 = near(i + 1, j, zc),
                            z01 = near(i, j + 1, zc), z11 = near(i + 1, j + 1, zc) }
                local ok, slope, w = Nav.CellPlane(c, s, C)
                if ok then
                    ok = roomAbove(cx, cy, max(c.z00, c.z10, c.z01, c.z11), s * 0.5, C)
                    if not ok then w = "no room above" end
                end
                count(w or "ok")
                if ok then c.slope = slope list[#list + 1] = c end
            end
            if #list > 0 then CELLS[vk(i, j)] = list end
            t0 = tickBudget(t0, C)
        end
    end

    -- 3. Merge.
    local rects = Nav.Merge(nx, ny, function(i, j) return CELLS[vk(i, j)] end, 1, C.maxMerge)
    for ri, r in ipairs(rects) do for _, c in pairs(r.recs) do c.rect = ri end end

    -- 4. Links, between rectangles: across every cell edge whose two
    -- vertices both cells share.
    local function same(p, q) return abs(p - q) <= 1 end
    local links, adj = {}, {}
    local function addLink(a, b)
        if a == b then return end
        local k = a < b and (a .. ":" .. b) or (b .. ":" .. a)
        if links[k] then return end
        links[k] = { a, b }
        adj[a] = adj[a] or {} adj[a][#adj[a] + 1] = b
        adj[b] = adj[b] or {} adj[b][#adj[b] + 1] = a
    end
    for j = 0, ny - 1 do
        for i = 0, nx - 1 do
            for _, c in ipairs(CELLS[vk(i, j)] or {}) do
                if c.rect then
                    for _, r in ipairs(CELLS[vk(i + 1, j)] or {}) do
                        if r.rect and same(c.z10, r.z00) and same(c.z11, r.z01) then addLink(c.rect, r.rect) end
                    end
                    for _, u in ipairs(CELLS[vk(i, j + 1)] or {}) do
                        if u.rect and same(c.z01, u.z00) and same(c.z11, u.z10) then addLink(c.rect, u.rect) end
                    end
                end
            end
        end
        t0 = tickBudget(t0, C)
    end

    -- 5. Prune, on a whole build: only what a rider can get to from a spawn
    -- (the tops of beams, walls and viaducts are surfaces, not places).
    -- Done BEFORE any area exists: a removed NavArea still gets saved.
    local keepRect, pruned = nil, 0
    if not opts.keep then
        local starts = {}
        for _, cls in ipairs({ "info_player_start", "info_player_deathmatch", "info_player_terrorist",
                               "info_player_counterterrorist", "info_player_combine", "info_player_rebel" }) do
            for _, e in ipairs(ents.FindByClass(cls)) do starts[#starts + 1] = e:GetPos() end
        end
        if #starts > 0 then
            local seedsR = {}
            for _, p in ipairs(starts) do
                local i, j = floor((p.x - x0) / s), floor((p.y - y0) / s)
                -- The cell under the spawn, or the nearest one round it.
                for rad = 0, 4 do
                    local found
                    for b2 = j - rad, j + rad do
                        for a2 = i - rad, i + rad do
                            for _, c in ipairs(CELLS[vk(a2, b2)] or {}) do
                                if c.rect and abs(c.zc - p.z) < 72 then seedsR[c.rect] = true found = true end
                            end
                        end
                    end
                    if found then break end
                end
            end
            local nodes = {}
            for ri in ipairs(rects) do nodes[#nodes + 1] = ri end
            keepRect = {}
            for _, comp in ipairs(Nav.Components(nodes, function(n) return adj[n] or {} end)) do
                local hit = false
                for _, n in ipairs(comp) do if seedsR[n] then hit = true break end end
                for _, n in ipairs(comp) do
                    if hit then keepRect[n] = true else pruned = pruned + 1 end
                end
            end
            if next(keepRect) == nil then keepRect = nil pruned = 0 end   -- spawns off the mesh: keep it all
        end
    end

    -- 6. Areas, and their links.
    if not opts.keep then navmesh.Reset() end
    local NW, NE, SE, SW = CORNERS()
    local made, areaOf = {}, {}
    for ri, r in ipairs(rects) do
        if not keepRect or keepRect[ri] then
            local ax0, ay0, ax1, ay1 = x0 + r.i0 * s, y0 + r.j0 * s, x0 + r.i1 * s, y0 + r.j1 * s
            local c00 = r.recs[vk(r.i0, r.j0)]
            local c10 = r.recs[vk(r.i1 - 1, r.j0)]
            local c01 = r.recs[vk(r.i0, r.j1 - 1)]
            local c11 = r.recs[vk(r.i1 - 1, r.j1 - 1)]
            local nw, ne = Vector(ax0, ay0, c00.z00), Vector(ax1, ay0, c10.z10)
            local se, sw = Vector(ax1, ay1, c11.z11), Vector(ax0, ay1, c01.z01)
            local a = navmesh.CreateNavArea(nw, se)
            if IsValid(a) then
                a:SetCorner(NW, nw) a:SetCorner(NE, ne) a:SetCorner(SE, se) a:SetCorner(SW, sw)
                made[#made + 1] = a
                areaOf[ri] = a
            end
            t0 = tickBudget(t0, C)
        end
    end
    local function link(a, b)
        if a ~= b and IsValid(a) and IsValid(b) then
            if not a:IsConnected(b) then a:ConnectTo(b) end
            if not b:IsConnected(a) then b:ConnectTo(a) end
        end
    end
    for _, l in pairs(links) do
        if areaOf[l[1]] and areaOf[l[2]] then link(areaOf[l[1]], areaOf[l[2]]) end
    end
    -- A remesh: link to the kept areas just outside the box.
    if opts.keep then
        for j = 0, ny - 1 do
            for i = 0, nx - 1 do
                for _, c in ipairs(CELLS[vk(i, j)] or {}) do
                    local area = c.rect and areaOf[c.rect]
                    if area then
                        for _, d in ipairs({ { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }) do
                            local ni, nj = i + d[1], j + d[2]
                            if ni < 0 or nj < 0 or ni >= nx or nj >= ny then
                                local ex, ey = x0 + (i + 0.5 + d[1] * 0.75) * s, y0 + (j + 0.5 + d[2] * 0.75) * s
                                local ez
                                if d[1] ~= 0 then ez = d[1] > 0 and (c.z10 + c.z11) * 0.5 or (c.z00 + c.z01) * 0.5
                                else ez = d[2] > 0 and (c.z01 + c.z11) * 0.5 or (c.z00 + c.z10) * 0.5 end
                                local o = navmesh.GetNavArea(Vector(ex, ey, ez + 8), 24)
                                if IsValid(o) and o ~= area and abs(o:GetZ(Vector(ex, ey, 0)) - ez) <= 6 then link(area, o) end
                            end
                        end
                    end
                end
            end
            t0 = tickBudget(t0, C)
        end
    end

    Nav.version = Nav.version + 1
    Nav.catalog = { runways = {}, launches = {}, rails = {}, at = 0 }
    return { areas = #made, cells = nx * ny, cell = s, why = why, pruned = pruned }
end

--------------------------------------------------------------------------
-- Remesh the ground around a box (a park piece placed, moved or removed):
-- the areas touching it go, and the box -- grown to cover them -- is built
-- again and linked into what is left.
--------------------------------------------------------------------------
function Nav.Remesh(lo, hi)
    if not meshed() then return nil, "no navmesh" end
    local pad = Nav.Config.cell * 2
    lo, hi = lo - Vector(pad, pad, 0), hi + Vector(pad, pad, 0)
    local wlo, whi = Nav.WorldBox()
    local areas = navmesh.FindInBox(Vector(lo.x, lo.y, wlo.z), Vector(hi.x, hi.y, whi.z), 1e5, 1e5) or {}
    for _, a in ipairs(areas) do
        local e = a:GetExtentInfo()
        lo = Vector(min(lo.x, e.lo.x), min(lo.y, e.lo.y), lo.z)
        hi = Vector(max(hi.x, e.hi.x), max(hi.y, e.hi.y), hi.z)
    end
    for _, a in ipairs(areas) do a:Remove() end
    return Nav.Build(Vector(lo.x, lo.y, wlo.z), Vector(hi.x, hi.y, whi.z), { keep = true })
end

--------------------------------------------------------------------------
-- Jobs: builds and the catalog run as coroutines, one at a time, a slice a
-- tick. An empty server hibernates and runs no Think, so a job started with
-- nobody on waits for the first player (or sv_hibernate_think 1).
--------------------------------------------------------------------------
Nav.jobs = Nav.jobs or {}

function Nav.Run(name, fn, done)
    Nav.jobs[#Nav.jobs + 1] = { name = name, co = coroutine.create(fn), done = done }
end

function Nav.Busy() return #Nav.jobs > 0 end

hook.Add("Think", "BMX.Nav.Jobs", function()
    local j = Nav.jobs[1]
    if not j then return end
    local ok, a, b = coroutine.resume(j.co)
    if not ok then
        table.remove(Nav.jobs, 1)
        ErrorNoHalt("[BMX] nav " .. j.name .. " failed: " .. tostring(a) .. "\n")
        if j.done then j.done(nil, tostring(a)) end
    elseif coroutine.status(j.co) == "dead" then
        table.remove(Nav.jobs, 1)
        if j.done then j.done(a, b) end
    end
end)

--------------------------------------------------------------------------
-- Ground facts used by the catalog and the bot.
--------------------------------------------------------------------------
-- An area's slope (deg) and uphill direction (unit, or nil when flat).
function Nav.AreaSlope(a)
    local NW, NE, SE, SW = CORNERS()
    local nw, ne, se, sw = a:GetCorner(NW), a:GetCorner(NE), a:GetCorner(SE), a:GetCorner(SW)
    local sx, sy = max(ne.x - nw.x, 1), max(sw.y - nw.y, 1)
    local gx = ((ne.z - nw.z) + (se.z - sw.z)) * 0.5 / sx
    local gy = ((sw.z - nw.z) + (se.z - ne.z)) * 0.5 / sy
    local g = sqrt(gx * gx + gy * gy)
    return math.deg(math.atan(g)), g > 1e-4 and Vector(gx / g, gy / g, 0) or nil
end

-- The area under a point (within `down` u), or nil.
function Nav.AreaAt(p, down)
    return navmesh.GetNavArea(p + UP * 16, (down or 48) + 16)
end

-- Can a bike roll from a to b in a straight line on the mesh: every sample
-- on an area, no step between samples. Returns ok, how far it got.
function Nav.Straight(a, b, opts)
    opts = opts or {}
    local d = b - a
    d.z = 0
    local len = d:Length()
    if len < 1 then return true, 0 end
    local dir = d / len
    local step = opts.step or Nav.Config.runStep
    local lastZ
    local flat = opts.flat
    for t = 0, len, step do
        local p = a + dir * t
        local area = Nav.AreaAt(Vector(p.x, p.y, (lastZ or a.z)), 64)
        if not area then return false, t end
        local zz = area:GetZ(p)
        if lastZ and abs(zz - lastZ) > (opts.stepUp or 8) then return false, t end
        if flat and Nav.AreaSlope(area) > flat then return false, t end
        lastZ = zz
    end
    return true, len
end

--------------------------------------------------------------------------
-- Paths. Cost = distance, more for slope, a lot for steep (a bike climbs a
-- ramp slowly and falls off its side), and a tax on areas a caller wants
-- kept clear (another rider's run, say: opts.avoid(area) -> extra cost).
--------------------------------------------------------------------------
local function areaCost(a, b, opts)
    local d = a:GetCenter():Distance(b:GetCenter())
    local slope = Nav.AreaSlope(b)
    local k = 1 + (slope / 20) ^ 2 * 2
    if slope > 30 then k = k + 6 end
    local extra = opts.avoid and opts.avoid(b) or 0
    return d * k + extra
end

function Nav.Path(from, to, opts)
    opts = opts or {}
    if not meshed() then return nil, "no navmesh" end
    local A = navmesh.GetNearestNavArea(from, false, 400, false, true)
    local B = navmesh.GetNearestNavArea(to, false, 400, false, true)
    if not IsValid(A) or not IsValid(B) then return nil, "off the mesh" end
    local goalC = B:GetCenter()
    local areas = Nav.AStar(A, B, function(n)
        local out = {}
        for _, m in ipairs(n:GetAdjacentAreas()) do out[#out + 1] = { m, areaCost(n, m, opts) } end
        return out
    end, function(n) return n:GetCenter():Distance(goalC) end, function(n) return n:GetID() end, 20000)
    if not areas then return nil, "no way there on the mesh" end
    -- Waypoints: through each shared edge's closest point, then pulled tight
    -- (skip ahead to the farthest one the bike can reach straight).
    local pts = { from }
    for i = 2, #areas do
        local p = areas[i - 1]:GetClosestPointOnArea(pts[#pts])
        local q = areas[i]:GetClosestPointOnArea(p)
        pts[#pts + 1] = (p + q) * 0.5
    end
    pts[#pts + 1] = to
    local out, i = { from }, 1
    while i < #pts do
        local j = #pts
        while j > i + 1 and not Nav.Straight(pts[i], pts[j], { stepUp = 8 }) do j = j - 1 end
        out[#out + 1] = pts[j]
        i = j
    end
    return out, areas
end

--------------------------------------------------------------------------
-- The catalog.
--------------------------------------------------------------------------
local function dirOf(yaw) local r = math.rad(yaw) return Vector(math.cos(r), math.sin(r), 0) end

-- Points to search from: flat area centres, thinned to one per `grid` u.
local function seeds(grid)
    local seen, out = {}, {}
    for _, a in ipairs(navmesh.GetAllNavAreas()) do
        if Nav.AreaSlope(a) <= Nav.Config.flatSlope and a:GetSizeX() >= 48 and a:GetSizeY() >= 48 then
            local c = a:GetCenter()
            local k = floor(c.x / grid) .. "," .. floor(c.y / grid) .. "," .. floor(c.z / 64)
            if not seen[k] then seen[k] = true out[#out + 1] = c end
        end
    end
    return out
end

function Nav.FindRunways()
    local C = Nav.Config
    local out = {}
    local t0 = SysTime()
    for _, p in ipairs(seeds(160)) do
        for h = 0, 15 do
            local dir = dirOf(h * 22.5)
            local _, len = Nav.Straight(p, p + dir * C.runMax, { flat = C.flatSlope, stepUp = 3 })
            if len >= C.runMin then
                -- Back up to where the flat begins, so the run is all of it.
                local _, back = Nav.Straight(p, p - dir * C.runMax, { flat = C.flatSlope, stepUp = 3 })
                local from = p - dir * math.max(back - 48, 0)
                local total = len + math.max(back - 48, 0)
                -- And clear of whatever the mesh does not know about (a prop).
                total = math.min(total, BMX.Launch.Runway(from + UP * 4, dir, total, {}))
                if total >= C.runMin then
                    out[#out + 1] = { from = from, dir = dir, len = total, yaw = h * 22.5 }
                end
            end
            t0 = tickBudget(t0, C)
        end
    end
    table.sort(out, function(a, b) return a.len > b.len end)
    -- One per stretch: drop a runway that starts near and points like a longer one.
    local kept = {}
    for _, r in ipairs(out) do
        local dup = false
        for _, k in ipairs(kept) do
            if k.dir:Dot(r.dir) > 0.97 and abs((r.from - k.from):Dot(Vector(-k.dir.y, k.dir.x, 0))) < 96 then
                dup = true break
            end
        end
        if not dup then kept[#kept + 1] = r end
        if #kept >= 60 then break end
    end
    return kept
end

function Nav.FindLaunches()
    local C = Nav.Config
    local coarse = setmetatable({ headings = 16, step = 24, reach = 1200 }, { __index = BMX.Launch.Config })
    local out = {}
    local t0 = SysTime()
    for _, p in ipairs(seeds(320)) do
        local l = BMX.FindLaunch(p + UP * 4, { config = coarse, filter = {} })
        if l then
            local dup = false
            for _, k in ipairs(out) do
                if k.lip:Distance(l.lip) < 64 and k.dir:Dot(l.dir) > 0.8 then
                    if l.height > k.height then k.height = l.height end
                    dup = true break
                end
            end
            if not dup then l.navSeed = p out[#out + 1] = l end
        end
        t0 = tickBudget(t0, C)
        coroutine.yield()
    end
    table.sort(out, function(a, b) return a.height > b.height end)
    return out
end

-- Rails: every park piece's grind lines, and map props that are a rail's
-- shape (thin, long, low).
function Nav.FindRails()
    local out = {}
    local P = BMX.Park
    if P and P.All then
        for _, e in ipairs(P.All()) do
            if IsValid(e) and e.GrindLines then
                for _, g in ipairs(e:GrindLines() or {}) do
                    out[#out + 1] = { a = g.a, b = g.b, kind = g.kind, entity = e }
                end
            end
        end
    end
    for _, e in ipairs(ents.FindByClass("prop_*")) do
        if IsValid(e) and not (P and P.IsPiece and P.IsPiece(e)) then
            local lo, hi = e:WorldSpaceAABB()
            local dx, dy, dz = hi.x - lo.x, hi.y - lo.y, hi.z - lo.z
            local long, thin = max(dx, dy), min(dx, dy)
            if long >= 120 and thin <= 24 and dz >= 20 and dz <= 90 then
                local c = (lo + hi) * 0.5
                local axis = dx >= dy and Vector(1, 0, 0) or Vector(0, 1, 0)
                out[#out + 1] = { a = Vector(c.x, c.y, hi.z) - axis * long * 0.5,
                                  b = Vector(c.x, c.y, hi.z) + axis * long * 0.5, kind = "rail", entity = e }
            end
        end
    end
    return out
end

function Nav.Catalog(done)
    if Nav.cataloguing then return end
    Nav.cataloguing = true
    local v = Nav.version
    Nav.Run("catalog", function()
        local cat = { runways = Nav.FindRunways(), rails = Nav.FindRails() }
        cat.launches = Nav.FindLaunches()
        cat.at, cat.version = CurTime(), v
        return cat
    end, function(cat, err)
        Nav.cataloguing = false
        if cat then
            Nav.catalog = cat
            print(string.format("[BMX] nav catalog: %d runways, %d launches, %d rails",
                #cat.runways, #cat.launches, #cat.rails))
        end
        if done then done(cat, err) end
    end)
end

-- The catalog for this mesh, starting the search when it is stale.
function Nav.Spots()
    local c = Nav.catalog
    if meshed() and (c.version ~= Nav.version) and not Nav.cataloguing then
        Nav.Catalog()
    end
    return c
end

--------------------------------------------------------------------------
-- Park pieces: their ground is remeshed when they come and go (debounced:
-- a preset places a dozen at once).
--------------------------------------------------------------------------
local pending
function Nav.Touch(lo, hi)
    if not meshed() then return end
    if pending then
        pending.lo = Vector(min(pending.lo.x, lo.x), min(pending.lo.y, lo.y), min(pending.lo.z, lo.z))
        pending.hi = Vector(max(pending.hi.x, hi.x), max(pending.hi.y, hi.y), max(pending.hi.z, hi.z))
    else
        pending = { lo = lo, hi = hi }
    end
    timer.Create("BMX.Nav.Remesh", 0.5, 1, function()
        local p = pending
        pending = nil
        if not p then return end
        Nav.Run("remesh", function() return Nav.Remesh(p.lo, p.hi) end, function(r)
            if r then Nav.Catalog() end
        end)
    end)
end

--------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------
local function allowed(ply) return not IsValid(ply) or BMX.Can(ply, "BMX - Build Parks") end
local function reply(ply, msg)
    if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, msg) end
    print(msg)
end

concommand.Add("bmx_nav_build", function(ply)
    if not allowed(ply) then return end
    if Nav.Busy() then reply(ply, "[BMX] nav: already working") return end
    local lo, hi = Nav.WorldBox()
    reply(ply, "[BMX] nav: meshing " .. game.GetMap() .. " ...")
    local t = SysTime()
    Nav.Run("build", function() return Nav.Build(lo, hi) end, function(r, err)
        if not r then reply(ply, "[BMX] nav: failed: " .. tostring(err)) return end
        navmesh.Save()
        local parts = {}
        for k, n in SortedPairs(r.why) do parts[#parts + 1] = k .. " " .. n end
        reply(ply, string.format("[BMX] nav: %d areas (%d unreachable pruned) from %d cells of %d u in %.1f s, saved maps/%s.nav (%s)",
            r.areas, r.pruned, r.cells, r.cell, SysTime() - t, game.GetMap(), table.concat(parts, ", ")))
        Nav.Catalog()
    end)
end, nil, "BMX: mesh this map for the bot (props and park pieces count) and save maps/<map>.nav")

concommand.Add("bmx_nav_catalog", function(ply)
    if not allowed(ply) then return end
    Nav.Catalog(function(c) if c then reply(ply, "[BMX] nav catalog done") end end)
end, nil, "BMX: find the trick spots on the navmesh again")

concommand.Add("bmx_nav_status", function(ply)
    if not allowed(ply) then return end
    local c = Nav.catalog
    reply(ply, string.format("[BMX] nav: %s, %d areas, version %d; catalog %d runways, %d launches, %d rails%s",
        meshed() and "loaded" or "none", navmesh and navmesh.GetNavAreaCount() or 0, Nav.version,
        #c.runways, #c.launches, #c.rails, Nav.Busy() and " (working)" or ""))
    for i, r in ipairs(c.runways) do
        if i > 5 then break end
        reply(ply, string.format("  runway %.0f u from (%.0f %.0f %.0f) heading %.0f", r.len, r.from.x, r.from.y, r.from.z, r.yaw))
    end
    for i, l in ipairs(c.launches) do
        if i > 8 then break end
        reply(ply, string.format("  launch %.0f u high, %.0f deg, lip (%.0f %.0f %.0f)", l.height, math.deg(l.angle), l.lip.x, l.lip.y, l.lip.z))
    end
end, nil, "BMX: the navmesh and the trick spots found on it")

-- A mesh loaded with the map: find its spots once something is running.
hook.Add("InitPostEntity", "BMX.Nav.Catalog", function()
    timer.Simple(2, function() Nav.Spots() end)
end)
