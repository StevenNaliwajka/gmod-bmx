--[[--------------------------------------------------------------------------
    bmx/sh_park.lua

    THE PARK PIECES: ramps, rails, quarter pipes, ledges, as pure geometry.

    One deterministic generator, two readers. BMX.Park.Build(shape, params)
    returns, for one piece, the convex hulls the SERVER builds its collision
    from (bmx_park_piece, PhysicsInitMultiConvex) and the faces the CLIENT
    draws (cl_park.lua). Both call this same function with the same two
    strings, so what you see and what you hit cannot drift apart: the rule
    sh_city.lua set for the city, applied to a prop you can pick up. A piece
    networks as its shape id and a parameter list ("2,1"), a few bytes; no
    vertex is ever sent, and no model file exists (a map with the addon
    mounted has nothing extra to download).

    COORDINATES. Entity space: +x is the way a rider goes (up the ramp, along
    the rail), +y is the left, +z up. The ORIGIN is the centre of the piece's
    footprint, on the floor: every piece is built anywhere and then shifted
    so, which is what makes edge-to-edge snapping a sum of two half-lengths.
    The lowest point of every piece is z = 0.

    PARAMETERS. A list of numbers: [1] the size (1 S, 2 M, 3 L) and [2] the
    variant (what the variant means is the shape's: the height of a quarter
    pipe, the gap of a dirt jump, ledge or manual pad). Out-of-range values are
    clamped, never refused, so a hand-edited save still loads.

    CURVES ARE STRIPS. A quarter pipe's transition is a polyline on a circle,
    and every segment of it is its own convex hull (the segment dropped to the
    floor). The rideable surface is the chords; the drawn mesh is the same
    chords, vertex for vertex. Nothing about a curve is ever approximated
    twice.

    GRIND TAGS. Rails, ledges, manual pads and coping are listed in `grind`
    as lines (kind, a, b) in entity space. sv_grind.lua still finds a rail by
    tracing, as it always has (it grinds a map's props the same way), so the
    tags do not change what it does. They are what we MEASURE against: the
    offline tests check that every tagged line is something that classifier
    would accept (a pipe no wider than pipeMaxWidth with the ground falling
    away at least `drop` either side, or an edge with a real drop), and the
    headless cases aim at them instead of guessing a point on a prop.

    SNAPPING and the PRESET PARKS live here too: they are arithmetic on the
    footprints, and the offline suite runs them.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Park = BMX.Park or {}
local P = BMX.Park

local abs, sin, cos, rad, deg, floor, max, min = math.abs, math.sin, math.cos, math.rad, math.deg,
    math.floor, math.max, math.min

P.CATEGORY = "BMX Park"

-- Size S, M, L scale a piece's plan (and, where a height is free, the
-- height). Fixed heights (the quarter pipe's) are the VARIANT, not the size.
P.SIZES = {
    { key = "S", name = "Small",  f = 0.75 },
    { key = "M", name = "Medium", f = 1.0 },
    { key = "L", name = "Large",  f = 1.5 },
}

-- Quarter pipe, spine, drop-in and bowl corner: the variant is the height.
local HEIGHTS = { 36, 56, 84 }
local HEIGHT_NAMES = { "Low", "Mid", "Tall" }
-- Where a transition leaves the vertical: 70 degrees, so it is a pipe and not
-- a wall. R = H / (1 - cos 70).
local TRANS_DEG = 70
local TRANS_N = 8

-- Surface colours by key; cl_park.lua reads these. Plain tables: this file
-- loads on the server too, where there is no Color.
P.Colors = {
    wood   = { 168, 126, 82 },
    deck   = { 150, 152, 158 },
    dirt   = { 112, 82, 54 },
    metal  = { 190, 196, 208 },
    coping = { 214, 214, 220 },
    stairs = { 132, 134, 140 },
}

local EPS = 1e-4

--------------------------------------------------------------------------
-- The accumulator. Points are {x, y, z} arrays until the very end.
--------------------------------------------------------------------------
local function newG() return { hulls = {}, faces = {}, grind = {}, padX = 0, padY = 0 } end

local function dedupe(pts)
    local out = {}
    for _, p in ipairs(pts) do
        local dup = false
        for _, q in ipairs(out) do
            if abs(p[1] - q[1]) < EPS and abs(p[2] - q[2]) < EPS and abs(p[3] - q[3]) < EPS then
                dup = true break
            end
        end
        if not dup then out[#out + 1] = p end
    end
    return out
end

local function addHull(G, pts) G.hulls[#G.hulls + 1] = dedupe(pts) end

-- A face is a polygon of 3 or 4 points; the client draws it as a fan, with
-- no culling, so the winding does not matter.
local function addFace(G, key, pts)
    local out = {}
    for _, p in ipairs(pts) do
        local last = out[#out]
        if not last or abs(p[1] - last[1]) > EPS or abs(p[2] - last[2]) > EPS or abs(p[3] - last[3]) > EPS then
            out[#out + 1] = p
        end
    end
    if #out > 1 then
        local f, l = out[1], out[#out]
        if abs(f[1] - l[1]) < EPS and abs(f[2] - l[2]) < EPS and abs(f[3] - l[3]) < EPS then out[#out] = nil end
    end
    if #out >= 3 then G.faces[#G.faces + 1] = { key = key, pts = out } end
end

-- `prof` is a convex polygon in (x, z), extruded from y0 to y1. `only` is a
-- set of edge numbers to draw (edge i runs prof[i] -> prof[i+1]); by default
-- every edge that is not on the floor. The end caps are drawn unless nocaps.
local function prism(G, prof, y0, y1, key, only, nocaps, hullProf)
    local pts = {}
    for _, p in ipairs(hullProf or prof) do
        pts[#pts + 1] = { p[1], y0, p[2] }
        pts[#pts + 1] = { p[1], y1, p[2] }
    end
    addHull(G, pts)
    local n = #prof
    for i = 1, n do
        local a, b = prof[i], prof[i % n + 1]
        local draw
        if only then draw = only[i] else draw = not (abs(a[2]) < EPS and abs(b[2]) < EPS) end
        if draw then
            addFace(G, key, { { a[1], y0, a[2] }, { b[1], y0, b[2] }, { b[1], y1, b[2] }, { a[1], y1, a[2] } })
        end
    end
    if not nocaps then
        local c0, c1 = {}, {}
        for i, p in ipairs(prof) do
            c0[i] = { p[1], y0, p[2] }
            c1[n + 1 - i] = { p[1], y1, p[2] }
        end
        addFace(G, key, c0)
        addFace(G, key, c1)
    end
end

local function box(G, x0, y0, z0, x1, y1, z1, key, nosides)
    addHull(G, {
        { x0, y0, z0 }, { x1, y0, z0 }, { x1, y1, z0 }, { x0, y1, z0 },
        { x0, y0, z1 }, { x1, y0, z1 }, { x1, y1, z1 }, { x0, y1, z1 },
    })
    addFace(G, key, { { x0, y0, z1 }, { x1, y0, z1 }, { x1, y1, z1 }, { x0, y1, z1 } })
    if nosides then return end
    addFace(G, key, { { x0, y0, z0 }, { x1, y0, z0 }, { x1, y0, z1 }, { x0, y0, z1 } })
    addFace(G, key, { { x0, y1, z0 }, { x1, y1, z0 }, { x1, y1, z1 }, { x0, y1, z1 } })
    addFace(G, key, { { x0, y0, z0 }, { x0, y1, z0 }, { x0, y1, z1 }, { x0, y0, z1 } })
    addFace(G, key, { { x1, y0, z0 }, { x1, y1, z0 }, { x1, y1, z1 }, { x1, y0, z1 } })
end

-- A bar between two points (the centre of its TOP at each end), `w` wide
-- across the horizontal and `t` thick below the top. Rails, and coping.
local function bar(G, a, b, w, t, key)
    local dx, dy = b[1] - a[1], b[2] - a[2]
    local l = math.sqrt(dx * dx + dy * dy)
    local px, py = -dy / l, dx / l
    local h = w * 0.5
    local pts, top = {}, {}
    for _, e in ipairs({ a, b }) do
        for _, s in ipairs({ -1, 1 }) do
            local x, y = e[1] + px * s * h, e[2] + py * s * h
            top[#top + 1] = { x, y, e[3] }
            pts[#pts + 1] = { x, y, e[3] }
            pts[#pts + 1] = { x, y, e[3] - t }
        end
    end
    addHull(G, pts)
    -- top, then the two sides and the two ends
    addFace(G, key, { top[1], top[2], top[4], top[3] })
    for _, s in ipairs({ 1, 2 }) do
        local p, q = top[s], top[s + 2]
        addFace(G, key, { p, q, { q[1], q[2], q[3] - t }, { p[1], p[2], p[3] - t } })
    end
    for _, s in ipairs({ 1, 3 }) do
        local p, q = top[s], top[s + 1]
        addFace(G, key, { p, q, { q[1], q[2], q[3] - t }, { p[1], p[2], p[3] - t } })
    end
end

local function tag(G, kind, a, b) G.grind[#G.grind + 1] = { kind = kind, a = a, b = b } end

-- A polyline of {x, z[, key]} (key of the segment that STARTS at the point) as
-- a strip of hulls: each segment dropped to the floor. Only the surface and
-- the two side caps are drawn: the strips' faces against each other are never
-- seen.
--
-- AT A CONCAVE JOINT (the surface turning up, as all through a transition) each
-- strip's HULL runs on past it along its own line, SEAM_BURY units, under the
-- other one's surface. Butted end to end, the two hulls' faces met in a plane
-- square to the floor whose top edge was the riding surface itself, and a wheel
-- box sliding over the joint caught that edge: a hit with a horizontal normal
-- halfway up a quarter pipe, and the bike stopped short or was popped off the
-- face (park quarter pipe and spine, real server). Buried, the joint is only
-- the crease between two planes. Not at a convex joint (a spine's top, a
-- lip), where running on would stand proud of the next surface. What is drawn
-- is unchanged.
local SEAM_BURY = 3
local function slopeOf(a, b) return (b[2] - a[2]) / (b[1] - a[1]) end
local function strips(G, line, y0, y1, defaultKey)
    for i = 1, #line - 1 do
        local a, b = line[i], line[i + 1]
        if abs(b[1] - a[1]) > EPS then
            local k = slopeOf(a, b)
            local u = 1 / math.sqrt(1 + k * k)                 -- x per unit along the line
            local back, fwd = 0, 0
            local p = line[i - 1]
            if p and abs(a[1] - p[1]) > EPS and k > slopeOf(p, a) + 1e-3 then back = SEAM_BURY * u end
            local q = line[i + 2]
            if q and abs(q[1] - b[1]) > EPS and slopeOf(b, q) > k + 1e-3 then fwd = SEAM_BURY * u end
            local hull
            if back > 0 or fwd > 0 then
                local xa, xb = a[1] - back, b[1] + fwd
                local za, zb = max(a[2] - k * back, 0), max(b[2] + k * fwd, 0)
                hull = { { xa, 0 }, { xb, 0 }, { xb, zb }, { xa, za } }
            end
            prism(G, { { a[1], 0 }, { b[1], 0 }, { b[1], b[2] }, { a[1], a[2] } }, y0, y1,
                a[3] or defaultKey, { [3] = true }, nil, hull)
        end
    end
end

-- A vertical wall at x, from the floor to z, across the width.
local function wall(G, x, y0, y1, z, key)
    addFace(G, key, { { x, y0, 0 }, { x, y1, 0 }, { x, y1, z }, { x, y0, z } })
end

-- A transition: a circular arc from the floor to TRANS_DEG, as a polyline
-- starting at (0, 0) and rising toward +x.
local function arcLine(H)
    local a = rad(TRANS_DEG)
    local R = H / (1 - cos(a))
    local line = {}
    for i = 0, TRANS_N do
        local t = a * i / TRANS_N
        line[#line + 1] = { R * sin(t), R * (1 - cos(t)) }
    end
    return line, R
end

-- Steps down along x beside something: `top(x)` is the height of the thing
-- next to them, and each step is `gap` lower than that (never under 2).
local function stairs(G, x0, x1, y0, y1, top, n, gap)
    local step = (x1 - x0) / n
    for i = 0, n - 1 do
        local xa, xb = x0 + i * step, x0 + (i + 1) * step
        local z = max(2, top((xa + xb) * 0.5) - gap)
        box(G, xa, y0, 0, xb, y1, z, "stairs")
    end
end

--------------------------------------------------------------------------
-- The shapes. build(G, f, v): f the size factor, v the variant.
--------------------------------------------------------------------------
P.Shapes = {}
P.Order = {}

local function shape(id, name, variants, build)
    P.Shapes[id] = { id = id, name = name, variants = variants, build = build }
    P.Order[#P.Order + 1] = id
end

shape("kicker", "Kicker", nil, function(G, f)
    local L, W, H = 96 * f, 80 * f, 20 * f
    prism(G, { { -L / 2, 0 }, { L / 2, 0 }, { L / 2, H } }, -W / 2, W / 2, "wood")
end)

shape("launch", "Launch ramp", nil, function(G, f)
    local L, W, H = 150 * f, 90 * f, 44 * f
    local line = {}
    for i = 0, 8 do
        local t = i / 8
        line[#line + 1] = { -L / 2 + L * t, H * t * t }
    end
    strips(G, line, -W / 2, W / 2, "wood")
    wall(G, L / 2, -W / 2, W / 2, H, "wood")
end)

-- The coping on a lip at x (a pipe a hand's width over the deck), tagged.
-- ON THE DECK SIDE of a lip (`onDeck`), its face flush with the transition's
-- top: centred on the lip it stood 2 u out over the face, and a wheel box
-- riding up a tall quarter pipe caught its underside -- a ledge across the
-- face, n = (1, 0, 0) -- and lost half its speed into it on the way past
-- (the front at the lip, then the rear: 311 u/s up the face, 131 left in
-- the air, real server). A tyre rolls over a pipe; a box cannot. A spine's
-- coping is centred on its 4 u top already, flush both sides.
local function coping(G, x, y0, y1, H, onDeck)
    if onDeck then x = x + 2 end
    bar(G, { x, y0, H + 3 }, { x, y1, H + 3 }, 4, 9, "coping")
    tag(G, "coping", { x, y0, H + 3 }, { x, y1, H + 3 })
end

shape("quarterpipe", "Quarter pipe", HEIGHT_NAMES, function(G, f, v)
    local H, W, deck = HEIGHTS[v], 120 * f, 28
    local line = arcLine(H)
    local xl = line[#line][1]
    line[#line + 1] = { xl, H, "deck" }
    line[#line + 1] = { xl + deck, H }
    for i = 1, #line - 2 do line[i][3] = "wood" end
    strips(G, line, -W / 2, W / 2, "wood")
    wall(G, xl + deck, -W / 2, W / 2, H, "deck")
    coping(G, xl, -W / 2, W / 2, H, true)
end)

shape("spine", "Spine", HEIGHT_NAMES, function(G, f, v)
    local H, W, top = HEIGHTS[v], 100 * f, 4
    local up = arcLine(H)
    local xl = up[#up][1]
    local line = {}
    for i, p in ipairs(up) do line[i] = { p[1], p[2], "wood" } end
    line[#line][3] = "deck"
    line[#line + 1] = { xl + top, H, "wood" }
    for i = #up - 1, 1, -1 do
        line[#line + 1] = { xl + top + (xl - up[i][1]), up[i][2], "wood" }
    end
    strips(G, line, -W / 2, W / 2, "wood")
    coping(G, xl + top / 2, -W / 2, W / 2, H)
end)

shape("bank", "Bank", nil, function(G, f)
    local run, H, deck, W = 120 * f, 44 * f, 36 * f, 110 * f
    local line = { { 0, 0, "wood" }, { run, H, "deck" }, { run + deck, H } }
    strips(G, line, -W / 2, W / 2, "wood")
    wall(G, run + deck, -W / 2, W / 2, H, "deck")
end)

shape("funbox", "Funbox", nil, function(G, f)
    local L, topL, H, W = 300 * f, 110 * f, 36 * f, 140 * f
    prism(G, { { -L / 2, 0 }, { L / 2, 0 }, { topL / 2, H }, { -topL / 2, H } },
        -W / 2, W / 2, "wood")
    -- the flat top has two real edges
    for _, y in ipairs({ -W / 2, W / 2 }) do
        tag(G, "ledge", { -topL / 2, y, H }, { topL / 2, y, H })
    end
end)

shape("pyramid", "Pyramid", nil, function(G, f)
    local B, T, H = 200 * f, 70 * f, 30 * f
    local b, t = B / 2, T / 2
    addHull(G, {
        { -b, -b, 0 }, { b, -b, 0 }, { b, b, 0 }, { -b, b, 0 },
        { -t, -t, H }, { t, -t, H }, { t, t, H }, { -t, t, H },
    })
    addFace(G, "deck", { { -t, -t, H }, { t, -t, H }, { t, t, H }, { -t, t, H } })
    addFace(G, "wood", { { -b, -b, 0 }, { b, -b, 0 }, { t, -t, H }, { -t, -t, H } })
    addFace(G, "wood", { { b, -b, 0 }, { b, b, 0 }, { t, t, H }, { t, -t, H } })
    addFace(G, "wood", { { b, b, 0 }, { -b, b, 0 }, { -t, t, H }, { t, t, H } })
    addFace(G, "wood", { { -b, b, 0 }, { -b, -b, 0 }, { -t, -t, H }, { -t, t, H } })
end)

-- A rail on posts. `pts` are the {x, z} of the top at each joint.
local RAIL_W, RAIL_T = 4, 4
local function railRun(G, pts, postEvery)
    for i = 1, #pts - 1 do
        local a, b = pts[i], pts[i + 1]
        bar(G, { a[1], 0, a[2] }, { b[1], 0, b[2] }, RAIL_W, RAIL_T, "metal")
        tag(G, "rail", { a[1], 0, a[2] }, { b[1], 0, b[2] })
    end
    -- posts at each joint and at least every `postEvery` between them
    local xs = {}
    for i = 1, #pts - 1 do
        local a, b = pts[i], pts[i + 1]
        local n = max(1, math.ceil((b[1] - a[1]) / postEvery))
        for k = 0, n - 1 do
            local t = k / n
            xs[#xs + 1] = { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t }
        end
    end
    xs[#xs + 1] = pts[#pts]
    for i, p in ipairs(xs) do
        local x = p[1]
        if i == 1 then x = x + 3 elseif i == #xs then x = x - 3 end
        local zTop = p[2] - RAIL_T - 0.5
        if zTop > 1 then box(G, x - 2.5, -2.5, 0, x + 2.5, 2.5, zTop, "metal") end
    end
    -- A rail is 4 wide; its footprint (for snapping) is wider.
    G.padY = max(G.padY, 24)
end

shape("flatrail", "Flat rail", nil, function(G, f)
    local L = 240 * f
    railRun(G, { { -L / 2, 22 }, { L / 2, 22 } }, 110)
end)

shape("downrail", "Down rail", nil, function(G, f)
    local L, zs, ze = 200 * f, 28, 28 - 12 * f
    railRun(G, { { -L / 2, zs }, { L / 2, ze } }, 100)
    local function top(x) return zs + (ze - zs) * ((x + L / 2) / L) end
    stairs(G, -L / 2, L / 2, 16, 72, top, 5, 12)
end)

shape("kinkedrail", "Kinked rail", nil, function(G, f)
    local L, zs, drop = 280 * f, 28, 12 * f
    railRun(G, { { -L / 2, zs }, { -L / 6, zs }, { L / 6, zs - drop }, { L / 2, zs - drop } }, 100)
end)

shape("ledge", "Ledge", { "Ledge", "Manual pad" }, function(G, f, v)
    local L = 192 * f
    if v == 1 then
        local w, h = 32, 20
        box(G, -L / 2, -w / 2, 0, L / 2, w / 2, h, "deck")
        for _, y in ipairs({ -w / 2, w / 2 }) do tag(G, "ledge", { -L / 2, y, h }, { L / 2, y, h }) end
    else
        local w, h = 56, 8
        box(G, -L / 2, -w / 2, 0, L / 2, w / 2, h, "deck")
        tag(G, "manual", { -L / 2, 0, h }, { L / 2, 0, h })
    end
end)

shape("hubba", "Hubba ledge", nil, function(G, f)
    local L, w = 200 * f, 30
    local h1 = 14
    local h0 = h1 + 20 * f
    local function top(x) return h0 + (h1 - h0) * ((x + L / 2) / L) end
    -- the ledge's top slopes down along x
    prism(G, { { -L / 2, 0 }, { L / 2, 0 }, { L / 2, h1 }, { -L / 2, h0 } }, 0, w, "deck")
    for _, y in ipairs({ 0, w }) do tag(G, "ledge", { -L / 2, y, h0 }, { L / 2, y, h1 }) end
    stairs(G, -L / 2, L / 2, w, w + 60, top, 5, 12)
end)

-- A bowl's corner: the floor curves up round a vertical axis at the corner
-- of the square footprint, and a deck fills the rest of the square.
shape("bowlcorner", "Bowl corner", HEIGHT_NAMES, function(G, f, v)
    local H, Rin, deckW = HEIGHTS[v], 56 * f, 24
    local line = arcLine(H)
    local xl = line[#line][1]
    local rTop = Rin + xl
    local S = rTop + deckW
    local N = 6
    local function at(r, th, z) return { r * cos(th), r * sin(th), z } end
    local function cell(th0, th1, ra, za, rb, zb, key)
        local a0, a1, b0, b1 = at(ra, th0, za), at(ra, th1, za), at(rb, th0, zb), at(rb, th1, zb)
        local pts = { a0, a1, b0, b1 }
        for _, p in ipairs({ a0, a1, b0, b1 }) do pts[#pts + 1] = { p[1], p[2], 0 } end
        addHull(G, pts)
        addFace(G, key, { a0, b0, b1 })
        addFace(G, key, { a0, b1, a1 })
    end
    for j = 0, N - 1 do
        local th0, th1 = rad(90) * j / N, rad(90) * (j + 1) / N
        for i = 1, #line - 1 do
            cell(th0, th1, Rin + line[i][1], line[i][2], Rin + line[i + 1][1], line[i + 1][2], "wood")
        end
        -- the deck beyond the lip, out to the square
        local function edge(th)
            local c, s = cos(th), sin(th)
            local r = (th <= rad(45) + 1e-9) and S / c or S / s
            return { r * c, r * s }
        end
        local p0, p1 = at(rTop, th0, H), at(rTop, th1, H)
        local q0, q1 = edge(th0), edge(th1)
        addHull(G, {
            p0, p1, { q0[1], q0[2], H }, { q1[1], q1[2], H },
            { p0[1], p0[2], 0 }, { p1[1], p1[2], 0 }, { q0[1], q0[2], 0 }, { q1[1], q1[2], 0 },
        })
        addFace(G, "deck", { p0, { q0[1], q0[2], H }, { q1[1], q1[2], H }, p1 })
        -- the outer walls
        if th1 <= rad(45) + 1e-9 then
            addFace(G, "deck", { { S, q0[2], 0 }, { S, q1[2], 0 }, { S, q1[2], H }, { S, q0[2], H } })
        else
            addFace(G, "deck", { { q0[1], S, 0 }, { q1[1], S, 0 }, { q1[1], S, H }, { q0[1], S, H } })
        end
        -- coping round the lip, a chord at a time
        bar(G, { p0[1], p0[2], H + 3 }, { p1[1], p1[2], H + 3 }, 4, 9, "coping")
        tag(G, "coping", { p0[1], p0[2], H + 3 }, { p1[1], p1[2], H + 3 })
    end
    -- the cut faces where the quarter meets its neighbours
    for i = 1, #line - 1 do
        local ra, za, rb, zb = Rin + line[i][1], line[i][2], Rin + line[i + 1][1], line[i + 1][2]
        addFace(G, "wood", { { ra, 0, 0 }, { rb, 0, 0 }, { rb, 0, zb }, { ra, 0, za } })
        addFace(G, "wood", { { 0, ra, 0 }, { 0, rb, 0 }, { 0, rb, zb }, { 0, ra, za } })
    end
    addFace(G, "deck", { { rTop, 0, 0 }, { S, 0, 0 }, { S, 0, H }, { rTop, 0, H } })
    addFace(G, "deck", { { 0, rTop, 0 }, { 0, S, 0 }, { 0, S, H }, { 0, rTop, H } })
end)

shape("dirtjump", "Dirt jump pair", { "Short gap", "Medium gap", "Long gap" }, function(G, f, v)
    local Lt, Ht, W = 130 * f, 30 * f, 70 * f
    local gap = ({ 110, 160, 220 })[v] * f
    local Ll, Hl = 150 * f, 0.85 * Ht
    local line = {}
    for i = 0, 8 do
        local t = i / 8
        line[#line + 1] = { Lt * t, Ht * t * t, "dirt" }
    end
    strips(G, line, -W / 2, W / 2, "dirt")
    wall(G, Lt, -W / 2, W / 2, Ht, "dirt")
    local xl = Lt + gap
    strips(G, { { xl, Hl, "dirt" }, { xl + Ll, 0 } }, -W / 2, W / 2, "dirt")
    wall(G, xl, -W / 2, W / 2, Hl, "dirt")
end)

shape("dropin", "Drop-in deck", HEIGHT_NAMES, function(G, f, v)
    local H, W, deck = HEIGHTS[v], 100 * f, 110 * f
    local line = arcLine(H)
    local xl = line[#line][1]
    for i = 1, #line do line[i][3] = "wood" end
    line[#line][3] = "deck"
    local xt = xl + deck
    line[#line + 1] = { xt, H, "deck" }
    -- back down to the floor at 22 degrees, so a rider can roll up to the deck
    line[#line + 1] = { xt + H / math.tan(rad(22)), 0 }
    strips(G, line, -W / 2, W / 2, "wood")
    coping(G, xl, -W / 2, W / 2, H, true)
end)

--------------------------------------------------------------------------
-- Parameters
--------------------------------------------------------------------------
local function clampInt(n, lo, hi)
    n = tonumber(n) or lo
    n = floor(n + 0.5)
    return max(lo, min(hi, n))
end

-- The two numbers of a parameter list, in range. Accepts "2,1", {2, 1} or
-- nil (medium, first variant).
function P.Params(shapeId, params)
    local s = P.Shapes[shapeId]
    if type(params) == "string" then
        local t = {}
        for n in params:gmatch("[^,%s]+") do t[#t + 1] = tonumber(n) end
        params = t
    end
    params = params or {}
    local nv = s and s.variants and #s.variants or 1
    return { clampInt(params[1] or 2, 1, #P.SIZES), clampInt(params[2] or 1, 1, nv) }
end

function P.EncodeParams(shapeId, params)
    local p = P.Params(shapeId, params)
    return p[1] .. "," .. p[2]
end

--------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------
local cache = {}

local function toVec(p) return Vector(p[1], p[2], p[3]) end

-- The piece, centred and in vectors. THE RESULT IS SHARED: do not change it.
function P.Build(shapeId, params)
    local def = P.Shapes[shapeId]
    if not def then return nil end
    local p = P.Params(shapeId, params)
    local key = shapeId .. "|" .. p[1] .. "," .. p[2]
    if cache[key] then return cache[key] end

    local G = newG()
    def.build(G, P.SIZES[p[1]].f, p[2])

    local lo = { math.huge, math.huge, math.huge }
    local hi = { -math.huge, -math.huge, -math.huge }
    for _, h in ipairs(G.hulls) do
        for _, q in ipairs(h) do
            for k = 1, 3 do lo[k] = min(lo[k], q[k]) hi[k] = max(hi[k], q[k]) end
        end
    end
    local cx, cy = (lo[1] + hi[1]) * 0.5, (lo[2] + hi[2]) * 0.5
    local function shift(q) return Vector(q[1] - cx, q[2] - cy, q[3] - lo[3]) end

    local out = { shape = shapeId, params = p, hulls = {}, faces = {}, grind = {} }
    for i, h in ipairs(G.hulls) do
        local pts = {}
        for j, q in ipairs(h) do pts[j] = shift(q) end
        out.hulls[i] = pts
    end
    for i, fc in ipairs(G.faces) do
        local pts = {}
        for j, q in ipairs(fc.pts) do pts[j] = shift(q) end
        out.faces[i] = { key = fc.key, pts = pts }
    end
    for i, g in ipairs(G.grind) do
        out.grind[i] = { kind = g.kind, a = shift(g.a), b = shift(g.b) }
    end
    out.mins = Vector(lo[1] - cx, lo[2] - cy, 0)
    out.maxs = Vector(hi[1] - cx, hi[2] - cy, hi[3] - lo[3])
    -- The footprint, for snapping: the hulls' own extent, or a wider pad
    -- (a rail is 4 across and would be a poor thing to snap to).
    out.hl = max(out.maxs.x, G.padX)
    out.hw = max(out.maxs.y, G.padY)
    cache[key] = out
    return out
end

-- The 3D pieces of a spawn-menu name, e.g. "Quarter pipe, Mid (M)".
function P.Label(shapeId, params)
    local def = P.Shapes[shapeId]
    if not def then return tostring(shapeId) end
    local p = P.Params(shapeId, params)
    local name = def.name
    if def.variants then name = name .. ", " .. def.variants[p[2]] end
    return name .. " (" .. P.SIZES[p[1]].key .. ")"
end

--------------------------------------------------------------------------
-- World space
--------------------------------------------------------------------------
local function rot(x, y, yawDeg)
    local c, s = cos(rad(yawDeg)), sin(rad(yawDeg))
    return x * c - y * s, x * s + y * c
end
P.Rotate = rot

-- The grind lines of a piece standing at pos / yaw, in the world.
function P.WorldGrind(b, pos, yawDeg)
    local out = {}
    for i, g in ipairs(b.grind) do
        local ax, ay = rot(g.a.x, g.a.y, yawDeg)
        local bx, by = rot(g.b.x, g.b.y, yawDeg)
        out[i] = { kind = g.kind,
            a = Vector(pos.x + ax, pos.y + ay, pos.z + g.a.z),
            b = Vector(pos.x + bx, pos.y + by, pos.z + g.b.z) }
    end
    return out
end

-- A footprint rectangle's four corners (x, y pairs) in the world.
function P.Footprint(b, pos, yawDeg)
    local out = {}
    for _, c in ipairs({ { 1, 1 }, { 1, -1 }, { -1, -1 }, { -1, 1 } }) do
        local x, y = rot(c[1] * b.hl, c[2] * b.hw, yawDeg)
        out[#out + 1] = { pos.x + x, pos.y + y }
    end
    return out
end

--------------------------------------------------------------------------
-- Snapping: place a new piece edge to edge against another.
--
-- `target` is { pos, yaw, hl, hw } (the piece aimed at), `aim` the world point
-- aimed at, `new` { hl, hw }, `relYaw` how far the new piece is turned from
-- the target (a multiple of 90, the tool's rotate). The side of the target
-- that is used is the one the aim point is nearest, judged in the target's own
-- units so a long thin piece is not always "hit on its end". The new piece
-- goes against that side, centred (or, with `slide`, where the aim was along
-- the side, in steps of 8). Both footprints are rectangles, so the distance
-- between the centres is a half-extent each along the normal.
--------------------------------------------------------------------------
function P.Snap(target, aim, new, relYaw, slide)
    local ty = target.yaw
    local dx, dy = aim.x - target.pos.x, aim.y - target.pos.y
    local lx, ly = rot(dx, dy, -ty)                    -- into the target's frame
    local nx, ny = lx / target.hl, ly / target.hw
    local nl                                           -- the side's normal, local
    local side
    if abs(nx) >= abs(ny) then
        nl = { nx >= 0 and 1 or -1, 0 }
        side = nx >= 0 and "front" or "back"
    else
        nl = { 0, ny >= 0 and 1 or -1 }
        side = ny >= 0 and "left" or "right"
    end
    local wnx, wny = rot(nl[1], nl[2], ty)             -- the normal, world
    local yaw = ty + (relYaw or 0)
    yaw = (yaw + 180) % 360 - 180
    local a1x, a1y = rot(1, 0, yaw)
    local a2x, a2y = rot(0, 1, yaw)
    local extNew = new.hl * abs(wnx * a1x + wny * a1y) + new.hw * abs(wnx * a2x + wny * a2y)
    local extTarget = nl[1] ~= 0 and target.hl or target.hw
    local d = extTarget + extNew
    local tx, ty2 = -wny, wnx                          -- along the side
    local lat = 0
    if slide then
        local along = dx * tx + dy * ty2
        local limit = nl[1] ~= 0 and target.hw or target.hl
        lat = max(-limit, min(limit, floor(along / 8 + 0.5) * 8))
    end
    return Vector(target.pos.x + wnx * d + tx * lat, target.pos.y + wny * d + ty2 * lat, target.pos.z),
        yaw, side
end

-- Where a click puts a piece. `tr` has HitPos and Entity; `opts` has snap,
-- rot (degrees), slide, yaw (the player's, degrees). Returns pos, yaw, snappedTo.
function P.Placement(tr, shapeId, params, opts)
    opts = opts or {}
    local b = P.Build(shapeId, params)
    if not b then return nil end
    local rotDeg = opts.rot or 0
    local ent = tr.Entity
    if opts.snap ~= false and ent and IsValid(ent) and P.IsPiece(ent) then
        local tb = P.Build(ent:GetShape(), ent:GetParams())
        if tb then
            local a = ent:GetAngles()
            local pos, yaw, side = P.Snap(
                { pos = ent:GetPos(), yaw = a.y, hl = tb.hl, hw = tb.hw },
                tr.HitPos, b, rotDeg, opts.slide)
            return pos, yaw, ent, side
        end
    end
    local yaw = floor((opts.yaw or 0) / 90 + 0.5) * 90 + rotDeg
    yaw = (yaw + 180) % 360 - 180
    return Vector(tr.HitPos.x, tr.HitPos.y, tr.HitPos.z), yaw, nil
end

--------------------------------------------------------------------------
-- Which entity classes are pieces
--------------------------------------------------------------------------
P.Classes = {}      -- the spawn-menu classes -> { shape, params }

function P.IsPieceClass(class)
    return class == "bmx_park_piece" or P.Classes[class] ~= nil
end

function P.IsPiece(ent)
    return ent and IsValid(ent) and P.IsPieceClass(ent:GetClass())
end

--------------------------------------------------------------------------
-- The spawn menu: one entity class per shape x variant x size, each an ENT
-- that derives from bmx_park_piece and only says which piece it is. A class
-- of its own (rather than one class with KeyValues) is what the spawn menu,
-- the duplicator, the undo list and PlayerSpawnSENT all understand without
-- being told anything.
--------------------------------------------------------------------------
function P.ClassName(shapeId, params)
    local p = P.Params(shapeId, params)
    local def = P.Shapes[shapeId]
    local c = "bmx_park_" .. shapeId
    if def.variants then c = c .. "_v" .. p[2] end
    return c .. "_" .. P.SIZES[p[1]].key:lower()
end

function P.RegisterSpawnClasses()
    for _, id in ipairs(P.Order) do
        local def = P.Shapes[id]
        for v = 1, (def.variants and #def.variants or 1) do
            for s = 1, #P.SIZES do
                local class = P.ClassName(id, { s, v })
                local params = s .. "," .. v
                P.Classes[class] = { shape = id, params = params }
                scripted_ents.Register({
                    Type = "anim", Base = "bmx_park_piece",
                    PrintName = P.Label(id, { s, v }), Category = P.CATEGORY,
                    Author = "Burrito", Spawnable = true, AdminOnly = false,
                    ParkShape = id, ParkParams = params,
                }, class)
            end
        end
    end
end

--------------------------------------------------------------------------
-- The preset parks. A layout is rows; each row is left to right along +x with
-- the piece's own footprint and a gap between, and rows stack along +y, so
-- nothing overlaps by construction (tests/test_park.lua checks it anyway).
-- {shape, size, variant, yaw, gap}: yaw 0 or 180 faces a rider +x or -x.
--------------------------------------------------------------------------
P.Presets = {
    street_plaza = {
        label = "Street plaza",
        help = "Rails, ledges, a hubba, a funbox and a pyramid: a street course.",
        rows = {
            { { "flatrail", 2 }, { "downrail", 2 }, { "kinkedrail", 2 }, { "flatrail", 3 } },
            { { "ledge", 2, 1 }, { "ledge", 2, 2 }, { "hubba", 2 }, { "ledge", 3, 1 } },
            { { "kicker", 2 }, { "funbox", 2 }, { "pyramid", 2 }, { "bank", 2 }, { "kicker", 1 } },
        },
    },
    vert_ramp = {
        label = "Vert ramp",
        help = "Facing quarter pipes, spines, a drop-in and a bowl corner.",
        rows = {
            { { "quarterpipe", 3, 3, 0 }, { "quarterpipe", 3, 3, 180, 380 } },
            { { "spine", 3, 3 }, { "spine", 2, 2, 0, 200 } },
            { { "dropin", 2, 3, 0 }, { "quarterpipe", 2, 2, 180, 300 } },
            { { "bowlcorner", 2, 3, 0 }, { "bowlcorner", 2, 3, 90, 40 },
              { "bowlcorner", 2, 3, 270, 40 }, { "bowlcorner", 2, 3, 180, 40 } },
        },
    },
    dirt_line = {
        label = "Dirt line",
        help = "Kickers and dirt jump pairs in a row, a bank to finish.",
        rows = {
            { { "kicker", 2 }, { "dirtjump", 2, 1, 0, 120 }, { "dirtjump", 2, 2, 0, 80 },
              { "dirtjump", 2, 3, 0, 80 }, { "bank", 2, 1, 0, 80 } },
            { { "launch", 2 }, { "dirtjump", 3, 2, 0, 120 }, { "dirtjump", 3, 3, 0, 80 },
              { "bank", 3, 1, 0, 80 } },
        },
    },
}
P.PresetOrder = { "street_plaza", "vert_ramp", "dirt_line" }

local ROW_GAP, PIECE_GAP = 120, 60

-- A preset as a flat list of { shape, params = {s, v}, x, y, yaw }, centred on
-- (0, 0).
function P.Layout(presetId)
    local preset = P.Presets[presetId]
    if not preset then return nil end
    local out = {}
    local y = 0
    local width = 0
    local rowsOut = {}
    for _, row in ipairs(preset.rows) do
        local x, hy = 0, 0
        local items = {}
        for _, spec in ipairs(row) do
            local id, size, var, yaw, gap = spec[1], spec[2] or 2, spec[3] or 1, spec[4] or 0, spec[5] or PIECE_GAP
            local b = P.Build(id, { size, var })
            local turned = (floor(yaw / 90 + 0.5) % 2) == 1
            local hx, hh = b.hl, b.hw
            if turned then hx, hh = b.hw, b.hl end
            x = x + gap + hx
            items[#items + 1] = { shape = id, params = { size, var }, x = x, yaw = yaw }
            x = x + hx
            hy = max(hy, hh)
        end
        rowsOut[#rowsOut + 1] = { items = items, hy = hy, w = x }
        width = max(width, x)
    end
    local total = 0
    for _, r in ipairs(rowsOut) do total = total + r.hy * 2 end
    total = total + ROW_GAP * (#rowsOut - 1)
    local cy = -total / 2
    for _, r in ipairs(rowsOut) do
        local yy = cy + r.hy
        for _, it in ipairs(r.items) do
            it.x = it.x - width / 2
            it.y = yy
            out[#out + 1] = it
        end
        cy = cy + r.hy * 2 + ROW_GAP
    end
    return out
end

--------------------------------------------------------------------------
-- Save format
--------------------------------------------------------------------------
P.SAVE_VERSION = 1

-- A park's name as a file name: letters, digits, _ and -, at most 32.
function P.SafeName(name)
    if type(name) ~= "string" then return nil end
    name = name:lower():gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" or #name > 32 or name:find("[^%w_%-]") then return nil end
    return name
end

function P.MapName(map)
    return (tostring(map or "unknown"):gsub("[^%w_%-%.]", "_"))
end

function P.Path(map, name)
    local n = P.SafeName(name)
    if not n then return nil end
    return "bmx/parks/" .. P.MapName(map) .. "/" .. n .. ".json"
end

-- A list of { shape, params, pos = Vector, ang = Angle } as plain tables.
function P.Encode(pieces, map)
    local out = { version = P.SAVE_VERSION, map = map, pieces = {} }
    for _, p in ipairs(pieces) do
        out.pieces[#out.pieces + 1] = {
            shape = p.shape, params = P.Params(p.shape, p.params),
            pos = { p.pos.x, p.pos.y, p.pos.z },
            ang = { p.ang.p, p.ang.y, p.ang.r },
        }
    end
    return out
end

-- The pieces back, validated: an unknown shape is dropped, numbers clamped.
function P.Decode(data)
    if type(data) ~= "table" or type(data.pieces) ~= "table" then return nil, "not a park file" end
    local out = {}
    for _, p in ipairs(data.pieces) do
        if type(p) == "table" and P.Shapes[p.shape] and type(p.pos) == "table" and #p.pos >= 3 then
            local a = type(p.ang) == "table" and p.ang or { 0, 0, 0 }
            out[#out + 1] = {
                shape = p.shape, params = P.Params(p.shape, p.params),
                pos = Vector(tonumber(p.pos[1]) or 0, tonumber(p.pos[2]) or 0, tonumber(p.pos[3]) or 0),
                ang = Angle(tonumber(a[1]) or 0, tonumber(a[2]) or 0, tonumber(a[3]) or 0),
            }
        end
    end
    return out
end

P.RegisterSpawnClasses()
