--[[--------------------------------------------------------------------------
    The bike's navmesh (sv_nav.lua) and park
    pieces settling on the ground (sv_park.lua).

    The mesh itself needs a map and is checked on a real server (bmx_nav_build
    on gm_skatepark: one connected floor, ramps as slopes, the floor under them
    gone). What is checked here is the arithmetic it is made of:
      - which cells a bike can ride (planar, not too steep)
      - coplanar cells merging into one area, and a beam and the floor under
        it staying two
      - A* finding the cheap way round, and parts of a graph
      - a piece resting on the HIGHEST ground under its footprint
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local function env()
    local sv = F.server()
    return sv.env, sv
end

T.test("nav: a flat cell and a 20 degree ramp ride; a step, a twist and a wall do not", function()
    local E = env()
    local N = E.BMX.Nav
    local s = 32
    T.ok(N.CellPlane({ z00 = 64, z10 = 64, z01 = 64, z11 = 64, zc = 64 }, s), "flat")
    local rise = s * math.tan(math.rad(20))
    local ok, slope = N.CellPlane({ z00 = 64, z10 = 64 + rise, z01 = 64, z11 = 64 + rise, zc = 64 + rise / 2 }, s)
    T.ok(ok, "a 20 degree ramp") T.near(slope, 20, 0.01, "measured as 20")
    local bad, _, why = N.CellPlane({ z00 = 64, z10 = 64, z01 = 64, z11 = 64, zc = 80 }, s)
    T.ok(not bad, "a rail through the middle") T.eq(why, "not planar", "is not planar")
    bad, _, why = N.CellPlane({ z00 = 64, z10 = 80, z01 = 80, z11 = 64, zc = 72 }, s)
    T.ok(not bad, "a saddle") T.eq(why, "twisted", "is twisted")
    local wall = s * math.tan(math.rad(70))
    bad, _, why = N.CellPlane({ z00 = 64, z10 = 64 + wall, z01 = 64, z11 = 64 + wall, zc = 64 + wall / 2 }, s)
    T.ok(not bad, "a quarter pipe's top") T.eq(why, "too steep", "is too steep")
    bad, _, why = N.CellPlane({ z00 = 64, z10 = 64, z01 = 64, zc = 64 }, s)
    T.ok(not bad, "a corner over a pit") T.eq(why, "no ground", "has no ground")
end)

-- A grid of cells from a height function, one surface per column unless
-- `beam(i, j)` gives a second.
local function grid(nx, ny, h, beam)
    local cells = {}
    for j = 0, ny - 1 do
        for i = 0, nx - 1 do
            local list = { { z00 = h(i, j), z10 = h(i + 1, j), z01 = h(i, j + 1), z11 = h(i + 1, j + 1) } }
            local b = beam and beam(i, j)
            if b then list[#list + 1] = { z00 = b, z10 = b, z01 = b, z11 = b } end
            cells[i * 65536 + j] = list
        end
    end
    return function(i, j) return cells[i * 65536 + j] end
end

T.test("nav: a flat floor merges into few areas, capped in size", function()
    local E = env()
    local N = E.BMX.Nav
    local rects = N.Merge(24, 24, grid(24, 24, function() return 64 end), 1, 12)
    T.eq(#rects, 4, "24 x 24 cells, 12 a side: four areas")
    local n = 0
    for _, r in ipairs(rects) do
        T.ok(r.i1 - r.i0 <= 12 and r.j1 - r.j0 <= 12, "no side over the cap")
        n = n + (r.i1 - r.i0) * (r.j1 - r.j0)
    end
    T.eq(n, 24 * 24, "every cell in one area, once")
end)

T.test("nav: a ramp is its own area, not merged into the floor beside it", function()
    local E = env()
    local N = E.BMX.Nav
    -- columns 0-3 flat, 4-7 rising 8 u a cell
    local rects = N.Merge(8, 4, grid(8, 4, function(i) return i <= 4 and 64 or 64 + (i - 4) * 8 end), 1, 12)
    T.eq(#rects, 2, "floor and ramp")
    local ramp
    for _, r in ipairs(rects) do if r.i0 == 4 then ramp = r end end
    T.ok(ramp, "the ramp starts where the slope does")
    T.eq(ramp.i1, 8, "and runs to the end")
end)

T.test("nav: a beam over the floor is a second layer, and the floor under it is still there", function()
    local E = env()
    local N = E.BMX.Nav
    local rects = N.Merge(6, 6, grid(6, 6, function() return 64 end, function(i) return i == 2 and 300 or nil end), 1, 12)
    local floorCells, beamCells = 0, 0
    for _, r in ipairs(rects) do
        for _, c in pairs(r.recs) do
            if c.z00 == 64 then floorCells = floorCells + 1 else beamCells = beamCells + 1 end
        end
    end
    T.eq(floorCells, 36, "the whole floor, under the beam too")
    T.eq(beamCells, 6, "and the beam's top on its own")
end)

T.test("nav: A* takes the cheap way round, and parts of a graph are found", function()
    local E = env()
    local N = E.BMX.Nav
    -- a - b - d costs 1 + 10; a - c - d costs 2 + 2
    local G = { a = { { "b", 1 }, { "c", 2 } }, b = { { "d", 10 } }, c = { { "d", 2 } }, d = {} }
    local path, cost = N.AStar("a", "d", function(n) return G[n] end, function() return 0 end)
    T.eq(table.concat(path, ""), "acd", "round by c")
    T.eq(cost, 4, "for 4")
    T.eq(N.AStar("d", "a", function(n) return G[n] end, function() return 0 end), nil, "no way back")
    local comps = N.Components({ 1, 2, 3, 4, 5 }, function(n)
        return ({ [1] = { 2 }, [2] = { 1 }, [3] = { 4 }, [4] = { 3 }, [5] = {} })[n]
    end)
    T.eq(#comps, 3, "three parts")
end)

T.test("park: a piece rests on the highest ground under its footprint", function()
    local E = env()
    local P = E.BMX.Park
    local b = P.Build("kicker", { 2, 1 })
    -- floor at 0, a 12 u kerb under the piece's +x end
    local z = P.GroundZ(b, E.Vector(100, 50, 40), 0, function(x)
        return x > 100 + b.hl * 0.5 and 12 or 0
    end)
    T.eq(z, 12, "on the kerb, not sunk into it")
    T.eq(P.GroundZ(b, E.Vector(0, 0, 0), 0, function() return nil end), nil, "over a pit: nothing to rest on")
    -- turned 90: the kerb under +y is now under its long side
    z = P.GroundZ(b, E.Vector(0, 0, 40), 90, function(_, y) return y > b.hl * 0.5 and 7 or 0 end)
    T.eq(z, 7, "turned, it still finds the high side")
end)

-- A remesh takes away the areas round a placed piece and builds that ground again,
-- the box grown ONCE to cover them. (Grown until it cut through nothing, it took in
-- most of a real mesh, whose rows do not line up, for every piece; the build skips
-- the ground the areas its edges cut through still cover, test below.)
T.test("nav: a remesh's box is grown once, to the areas the piece's box touches", function()
    local E = env()
    local N = E.BMX.Nav
    local function floor(brick)
        local areas = {}
        for row = 0, 7 do
            local off = brick and (row % 2) * 48 or 0
            for col = -1, 7 do
                local lo = E.Vector(col * 96 + off, row * 64, 0)
                local a = { e = { lo = lo, hi = lo + E.Vector(96, 64, 0) } }
                function a:GetExtentInfo() return self.e end
                areas[#areas + 1] = a
            end
        end
        return function(lo, hi)
            local o = {}
            for _, a in ipairs(areas) do
                if a.e.lo.x < hi.x and a.e.hi.x > lo.x and a.e.lo.y < hi.y and a.e.hi.y > lo.y then o[#o + 1] = a end
            end
            return o
        end
    end
    local gone, lo, hi = N.RemeshBox(E.Vector(200, 150, 0), E.Vector(260, 200, 0), floor(false))
    T.eq(#gone, 2, "two areas touched, two gone")
    T.eq(hi.x - lo.x, 96, "and the box is theirs: " .. (hi.x - lo.x))
    gone, lo, hi = N.RemeshBox(E.Vector(200, 150, 0), E.Vector(260, 200, 0), floor(true))
    T.eq(#gone, 3, "out of line: only what the box touched (one row's joint is under it)")
    T.ok(hi.x - lo.x <= 96 * 2, "a box of two areas, not the floor: " .. (hi.x - lo.x))
end)

--------------------------------------------------------------------------
-- A remesh on a real build. The engine's navmesh is not in the shim: this one
-- keeps rectangles at a height, with links, which is all Build and Remesh ask of it.
--------------------------------------------------------------------------
local function fakeNavmesh(E)
    local areas, nextId = {}, 1
    local A = {}
    A.__index = A
    function A:IsValid() return not self.gone end
    function A:Remove() self.gone = true end
    function A:SetCorner() end
    function A:GetID() return self.id end
    function A:GetExtentInfo() return { lo = E.Vector(self.x0, self.y0, self.z), hi = E.Vector(self.x1, self.y1, self.z) } end
    function A:GetZ() return self.z end
    function A:GetCenter() return E.Vector((self.x0 + self.x1) / 2, (self.y0 + self.y1) / 2, self.z) end
    function A:IsConnected(b) return self.links[b] == true end
    function A:ConnectTo(b) self.links[b] = true end
    local live = function()
        local o = {}
        for _, a in ipairs(areas) do if not a.gone then o[#o + 1] = a end end
        return o
    end
    return {
        live = live,
        CreateNavArea = function(nw, se)
            local a = setmetatable({ id = nextId, x0 = math.min(nw.x, se.x), x1 = math.max(nw.x, se.x),
                y0 = math.min(nw.y, se.y), y1 = math.max(nw.y, se.y), z = nw.z, links = {} }, A)
            nextId = nextId + 1
            areas[#areas + 1] = a
            return a
        end,
        Reset = function() for _, a in ipairs(areas) do a.gone = true end end,
        GetNavAreaCount = function() return #live() end,
        GetAllNavAreas = live,
        FindInBox = function(lo, hi)
            local o = {}
            for _, a in ipairs(live()) do
                if a.x0 < hi.x and a.x1 > lo.x and a.y0 < hi.y and a.y1 > lo.y and a.z >= lo.z and a.z <= hi.z then o[#o + 1] = a end
            end
            return o
        end,
        GetNavArea = function(p, below)
            for _, a in ipairs(live()) do
                if p.x >= a.x0 and p.x <= a.x1 and p.y >= a.y0 and p.y <= a.y1 and a.z <= p.z and a.z >= p.z - below then
                    return a
                end
            end
        end,
    }
end

T.test("nav: RectMinus leaves exactly the rest of a rectangle, in pieces that do not overlap", function()
    local E = env()
    local N = E.BMX.Nav
    local function area(rs) local t = 0 for _, r in ipairs(rs) do t = t + (r[3] - r[1]) * (r[4] - r[2]) end return t end
    local cell = { { 0, 0, 32, 32 } }
    T.eq(#N.RectMinus(cell, { 40, 0, 80, 32 }), 1, "apart: the cell, whole")
    T.eq(#N.RectMinus(cell, { -10, -10, 50, 50 }), 0, "covered: nothing")
    local strip = N.RectMinus(cell, { -48, -48, 20, 80 })
    T.eq(#strip, 1, "cut by one edge: one strip")
    T.eq(area(strip), 12 * 32, "and it is the uncovered 12 u")
    local ell = N.RectMinus(cell, { 10, 10, 50, 50 })
    T.eq(area(ell), 32 * 32 - 22 * 22, "a corner in it: the L that is left")
    local hole = N.RectMinus(cell, { 8, 8, 24, 24 })
    T.eq(#hole, 4, "inside it: a frame of four")
    T.eq(area(hole), 32 * 32 - 16 * 16, "with the middle gone")
    for _, rs in ipairs({ ell, hole }) do
        for i = 1, #rs do for j = i + 1, #rs do
            local a, b = rs[i], rs[j]
            T.ok(not (a[1] < b[3] and a[3] > b[1] and a[2] < b[4] and a[4] > b[2]), "pieces do not overlap")
        end end
    end
end)

T.test("nav: a remesh round a piece leaves no ground covered twice, and the new ground is linked to the old", function()
    local E, sv = env()
    local N = E.BMX.Nav
    local nm = fakeNavmesh(E)
    E.navmesh = nm
    E.SysTime = E.SysTime or os.clock
    local g = sv.world.groundZ
    E.game.GetWorld().GetModelBounds = function() return E.Vector(-700, -700, g - 64), E.Vector(700, 700, g + 300) end
    local lo, hi = N.WorldBox()
    -- A whole build on a coarser grid (a big map's is: Build widens the cell until
    -- the map fits maxCells), so the remesh's own grid does not line up with it and
    -- the grown box's edges run through areas that stay.
    local cell = N.Config.cell
    N.Config.cell = 48
    N.Build(lo, hi)
    N.Config.cell = cell
    local before = #nm.live()
    T.ok(before > 4, "a floor of areas: " .. before)
    local r = N.Remesh(E.Vector(-40, -40, g), E.Vector(40, 40, g + 20))
    T.ok(r and r.areas > 0, "the remesh built ground: " .. tostring(r and r.areas))
    -- No point of the floor under two areas.
    local live = nm.live()
    local twice = 0
    for i = 1, #live do
        for j = i + 1, #live do
            local a, b = live[i], live[j]
            if a.x0 < b.x1 - 0.5 and a.x1 > b.x0 + 0.5 and a.y0 < b.y1 - 0.5 and a.y1 > b.y0 + 0.5 then twice = twice + 1 end
        end
    end
    T.eq(twice, 0, "no ground covered twice")
    -- And no ground left uncovered: the old grid does not line up with the new one, and a
    -- cell skipped because its centre lay on a kept area left the rest of it bare -- strips
    -- with no area along the box's edges, which a bot's straight line fell into and routed
    -- round, off flatgrass's ledge (BMX (Mode) suite, 2026-11-10).
    local bare, where = 0, nil
    for x = lo.x + 4, hi.x - 4, 6 do
        for y = lo.y + 4, hi.y - 4, 6 do
            if not nm.GetNavArea(E.Vector(x, y, g + 16), 64) then
                bare = bare + 1
                where = where or string.format("(%.0f %.0f)", x, y)
            end
        end
    end
    T.eq(bare, 0, "no ground left bare" .. (where and (", first at " .. where) or ""))
    -- Every area that shares an edge with another is linked to it.
    local unlinked = 0
    for i = 1, #live do
        for j = 1, #live do
            local a, b = live[i], live[j]
            if a ~= b then
                local touchX = (math.abs(a.x1 - b.x0) < 0.5) and a.y0 < b.y1 and a.y1 > b.y0
                local touchY = (math.abs(a.y1 - b.y0) < 0.5) and a.x0 < b.x1 and a.x1 > b.x0
                if (touchX or touchY) and not (a:IsConnected(b) and b:IsConnected(a)) then unlinked = unlinked + 1 end
            end
        end
    end
    T.eq(unlinked, 0, "every neighbour linked both ways")
    T.eq(#sv.errors, 0, "no errors: " .. table.concat(sv.errors, " | "))
end)

-- THE TRICK SPOTS ARE FOUND WHEN SOMETHING ASKS. Every server searched the map for the
-- bot's spots as it loaded, and remeshed and searched again whenever park pieces came or
-- went: ~45 s of 4 ms ticks each time, ~30% of a core in a sandbox game nobody started
-- the bot in (a real game, 2026-11-08). Now only the BMX gamemode does that up front;
-- elsewhere a park's changes wait for the first ask, and a host's ticks get 1 ms.
T.test("nav: outside the BMX gamemode the spots are searched for only when asked, at a host's gentler pace", function()
    local E, sv = env()
    local N = E.BMX.Nav
    E.navmesh = E.navmesh or {}
    E.navmesh.GetNavAreaCount = function() return 10 end
    E.navmesh.FindInBox = function() return {} end
    local gamemode = "sandbox"
    E.engine.ActiveGamemode = function() return gamemode end
    local dedicated = false
    E.game.IsDedicated = function() return dedicated end
    N.jobs = {}
    local ran = {}
    local run0 = N.Run
    N.Run = function(name, ...) ran[#ran + 1] = name return run0(name, ...) end
    -- joining: nothing searched
    E.hook.Run("InitPostEntity")
    sv:run(3)
    T.eq(#ran, 0, "no search when the map loads")
    -- a park piece placed: remembered, not remeshed
    N.Touch(E.Vector(0, 0, 0), E.Vector(100, 100, 50))
    sv:run(1)
    T.eq(#ran, 0, "no remesh for a park piece")
    N.Run = run0
    T.ok(N.Pending(), "the change is remembered")
    -- the bot (or auto-ride) asks: the remesh runs then, and the search after it
    N.Spots()
    T.ok(#N.jobs >= 1 and N.jobs[1].name == "remesh", "asked for: the remesh starts")
    T.ok(not N.Pending(), "and is no longer waiting")
    T.near(N.Budget(), 0.001, 1e-9, "a host's tick budget")
    dedicated = true
    T.near(N.Budget(), 0.004, 1e-9, "a dedicated server's")
    -- under the BMX gamemode: up front, as before
    N.jobs = {}
    local started = {}
    local run = N.Run
    N.Run = function(name, ...) started[#started + 1] = name return run(name, ...) end
    gamemode = "bmx"
    N.Touch(E.Vector(0, 0, 0), E.Vector(100, 100, 50))
    sv:run(1)
    N.Run = run
    T.eq(started[1], "remesh", "the BMX gamemode remeshes a park change straight away")
end)

-- A ROUTE IS RIDDEN, NOT WALKED. A navmesh links a ledge's top to the ground below it,
-- and A* took the drop: the trick bot rode off gm_flatgrass's 515 u ledge on the way to
-- its run-up and crashed (bot_finds_a_ramp_in_the_world, 2026-11-10).
T.test("nav: a path goes round a drop a bike cannot ride, and finds none where the drop is the only way", function()
    local E, sv = env()
    local N = E.BMX.Nav
    local nm = fakeNavmesh(E)
    E.navmesh = nm
    local g = sv.world.groundZ
    local meta = getmetatable(nm.CreateNavArea(E.Vector(9000, 9000, g), E.Vector(9001, 9001, g)))
    function meta:GetAdjacentAreas() local o = {} for b in pairs(self.links) do if not b.gone then o[#o + 1] = b end end return o end
    function meta:ComputeAdjacentConnectionHeightChange(b) return b.z - self.z end
    nm.GetNearestNavArea = function(p)
        local best, bd
        for _, a in ipairs(nm.live()) do
            if p.x >= a.x0 and p.x <= a.x1 and p.y >= a.y0 and p.y <= a.y1 then
                local d = math.abs(a.z - p.z)
                if not bd or d < bd then best, bd = a, d end
            end
        end
        return best
    end
    local function area(x0, y0, x1, y1, z) return nm.CreateNavArea(E.Vector(x0, y0, z), E.Vector(x1, y1, z)) end
    local function link(a, b) a:ConnectTo(b) b:ConnectTo(a) end
    -- Start S and goal G on the upper floor; the short way is down a 500 u drop (D,
    -- linked one way, as a navmesh does) and back up a ramp R; the long way round
    -- (W1, W2) stays on the floor.
    local S  = area(0, 0, 100, 100, g)
    local D  = area(100, 0, 200, 100, g - 500)
    local R  = area(200, 0, 300, 100, g - 10)
    local Gl = area(300, 0, 400, 100, g)
    local W1 = area(0, 100, 200, 600, g)
    local W2 = area(200, 100, 400, 600, g)
    S:ConnectTo(D)                  -- off the ledge, one way
    link(D, R) link(R, Gl)
    link(S, W1) link(W1, W2) link(W2, Gl)
    local A, B = S, Gl
    local okA = N.Rideable(S, D)
    T.ok(not okA, "a 500 u drop is not rideable")
    T.ok(N.Rideable(S, W1), "level ground is")
    local areas = N.AStar(A, B, function(n)
        local out = {}
        for _, m in ipairs(n:GetAdjacentAreas()) do
            if N.Rideable(n, m) then out[#out + 1] = { m, n:GetCenter():Distance(m:GetCenter()) } end
        end
        return out
    end, function(n) return n:GetCenter():Distance(B:GetCenter()) end, function(n) return n:GetID() end, 1000)
    T.ok(areas, "a way there")
    local viaDrop = false
    for _, a in ipairs(areas or {}) do if a == D then viaDrop = true end end
    T.ok(not viaDrop, "and it goes round, not off the ledge")
    -- With the way round gone, the drop is no way at all.
    W1:Remove() W2:Remove()
    local none = N.AStar(A, B, function(n)
        local out = {}
        for _, m in ipairs(n:GetAdjacentAreas()) do
            if N.Rideable(n, m) then out[#out + 1] = { m, 1 } end
        end
        return out
    end, function() return 0 end, function(n) return n:GetID() end, 1000)
    T.eq(none, nil, "no route that only a fall makes")
    -- And Nav.Path itself, the route the bot rides.
    local pts, why = N.Path(S:GetCenter() + E.Vector(0, 0, 4), Gl:GetCenter() + E.Vector(0, 0, 4))
    T.eq(pts, nil, "Nav.Path finds none either")
    T.eq(why, "no way there on the mesh", "because the mesh has no ridden way, not because it is missing")
end)
