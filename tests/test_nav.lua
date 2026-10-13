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

-- A remesh takes away the areas round a placed piece and builds that ground again.
-- The box was grown ONCE, to the areas the first box touched; its new edges cut
-- through areas that were left standing, and the build laid new ones over them.
T.test("nav: a remesh's box grows until no area left standing overlaps it", function()
    local E = env()
    local N = E.BMX.Nav
    -- A floor of areas in rows that do not line up (a brick wall): every row's joints
    -- are offset from the next one's, as a mesh built at another cell size is.
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
        -- FindInBox: what OVERLAPS the rectangle (an edge shared is not an overlap).
        return function(lo, hi)
            local o = {}
            for _, a in ipairs(areas) do
                if a.e.lo.x < hi.x and a.e.hi.x > lo.x and a.e.lo.y < hi.y and a.e.hi.y > lo.y then o[#o + 1] = a end
            end
            return o
        end
    end
    local function standing(find, gone, lo, hi)
        local removed, left = {}, 0
        for _, a in ipairs(gone) do removed[a] = true end
        for _, a in ipairs(find(lo, hi)) do if not removed[a] then left = left + 1 end end
        return left
    end
    local find = floor(true)
    local gone, lo, hi = N.RemeshBox(E.Vector(200, 150, 0), E.Vector(260, 200, 0), find)
    T.eq(standing(find, gone, lo, hi), 0, "nothing left standing under the box it builds")
    T.ok(#gone > 2, "the areas round it go: " .. #gone)
    -- On a floor whose joints line up, it stops at the areas the first box touched.
    find = floor(false)
    gone, lo, hi = N.RemeshBox(E.Vector(200, 150, 0), E.Vector(260, 200, 0), find)
    T.eq(standing(find, gone, lo, hi), 0, "lined up: nothing left standing either")
    T.eq(#gone, 2, "two areas touched, two gone")
    T.eq(hi.x - lo.x, 96, "and the box is theirs: " .. (hi.x - lo.x))
end)
