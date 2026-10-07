--[[--------------------------------------------------------------------------
    bmx/cl_geo_board.lua

    The models of the skateboard, the kick scooter and the inline skates, built in code (docs/MODELS.md).
    Kinds: skateboard, scooter, skates.

    All three have their own drawers (cl_board.lua, cl_scooter.lua, cl_skates.lua), so
    their groups are named for those drawers and each is built where its drawer places it:

    SKATEBOARD, board space (cl_board.lua B.Frame's P: x forward, y left, z up, the
    origin on the chassis's axle line; the rider stands on the deck's top at ~1.8, the
    ground is 1.3 under the origin at the static sag). A 31.75 x 8.0 popsicle deck of
    7-ply maple with a mellow concave and kicked nose and tail; two trucks on the
    simulation's axles (x = +-wheelbase/2) at the simulation's track (y = +-4.6); four
    54 mm wheels standing on the ground. The simulation's wheel is radius 2.2, twice a
    real one (it rolls over cracks): the drawn wheel is real and its axle sits a real
    wheel's radius over the ground the simulation stands on, which is what makes a
    truck a real truck's height.
        deck     the deck: grip on top, the graphic underneath, the plies on the
                 edge, the eight bolt heads
        truck    one truck's baseplate, kingpin, bushings and nut, about the truck's
                 own origin (the baseplate's middle on the deck's underside, x out
                 toward the nearer end of the board); drawn twice, the rear turned
                 half round
        hanger   one hanger with its axle, washers and nuts, in the same space; it
                 turns about layout.pivot when the board carves and stays level
                 when the deck leans
        wheel    one wheel about its own axle (y), with its bearings; drawn four times

    SCOOTER, chassis space as cl_scooter.lua has it (P: x forward, the origin on the
    axle line, the deck's top at Tune.deckTop): a pro stunt scooter on the
    registry's wheels. The registry's are radius 5 (a 10-inch wheel) under a frame
    drawn for small ones, so the deck stops short of each tyre and the head tube
    stands over the front one; at a 110 mm radius the same builder puts the deck
    over the dropouts and the head tube on Tune's head-tube foot.
        deck       deck, grip, neck, head tube, the rear dropouts, the flex fender,
                   the rear pegs (the whip turns this about the steer axis)
        fork       crown, legs, dropouts, axle, the front pegs (steers)
        bars       the 4-bolt clamp, the T-bar, grips, bar ends, the bell (steers)
        bellLever  the bell's lever
        wheel      one wheel about its own axle; drawn twice

    SKATES, one boot about its sole point (cl_skates.lua S.BootFrame's `sole`: the
    foot bone less 2.6, x along the skater's heading, z up). The wheels stand where
    BootFrame puts their contact, 2*radius - 0.4 under the sole, at its pitch.
        skate              shell, cuff, liner, tongue, laces, the buckles' straps,
                           the soul plate, the frame, the H-block, the axle bolts
        skateOutL/R        the buckles' levers, on the outside of a left/right boot
        wheel, wheelAR     a 55 mm wheel and a 44 mm anti-rocker about their axles

    The registry's wheels are bigger than real ones (a board's 2.2, a skate's 1.6:
    they roll over cracks): the board and the skates are drawn on real wheels
    standing on the simulation's ground; the scooter's frame is drawn round the
    registry's own (see SCOOTER above).
----------------------------------------------------------------------------]]

BMX = BMX or {}
local G = BMX.BikeGeo
if not G then return end

local sqrt, sin, cos, pi, abs = math.sqrt, math.sin, math.cos, math.pi, math.abs
local max, min, floor = math.max, math.min, math.floor
local TAU = pi * 2
local Vv = G.vec
local V, add, sub, mul, dot, cross = Vv.V, Vv.add, Vv.sub, Vv.mul, Vv.dot, Vv.cross
local len, norm, lerp, rot = Vv.len, Vv.norm, Vv.lerp, Vv.rot
local Pm = G.prim
local sweep, lathe, plate, box, cap = Pm.sweep, Pm.lathe, Pm.plate, Pm.box, Pm.cap
local roundRect, circle, bez3, spline = Pm.roundRect, Pm.circle, Pm.bez3, Pm.spline
local tri, quad, earclip = Pm.tri, Pm.quad, Pm.earclip

local function smooth(t) t = max(0, min(1, t)) return t * t * (3 - 2 * t) end

--------------------------------------------------------------------------
-- THE SLAB: a flat board with rounded edges lofted along a line of stations,
-- each { o, t, n, w, h, rr, c }: the middle of the board there, the way along
-- it, its up, its half width and half thickness, the edge's radius, and an
-- optional concave c(y) (the sheet's offset along n across it). The ring at a
-- station is the top (+w to -w), the -y edge, the bottom, the +y edge; a
-- station with w and h near zero closes the board to a rounded tip. Each
-- segment of the ring goes in the bucket opt.role(kind, frac) names, `kind`
-- top / side / bottom and `frac` how far down the edge (0 top, 1 bottom).
-- Normals by central differences, turned away from the station's middle.
--------------------------------------------------------------------------
local function slab(M, group, st, opt)
    opt = opt or {}
    local nTop, nBot = opt.nTop or 12, opt.nBot or opt.nTop or 12
    local na, ns = opt.nArc or 3, opt.nStraight or 2
    local extraZ = opt.cuts or {}           -- edge fractions (0..1 down) to cut at
    -- the edge's sample points as (angle or straight) parameters, top to bottom,
    -- each { kind = "arcT"/"str"/"arcB", a }
    local edge = {}
    for a = 1, na do edge[#edge + 1] = { "arcT", 1 - a / na } end          -- 1 = the top
    local fr = {}
    for k = 1, ns - 1 do fr[#fr + 1] = k / ns end
    for _, f in ipairs(extraZ) do fr[#fr + 1] = f end
    table.sort(fr)
    for _, f in ipairs(fr) do edge[#edge + 1] = { "str", f } end
    for a = 0, na - 1 do edge[#edge + 1] = { "arcB", a / na } end          -- 0 = where the side ends
    local function edgePt(s, e)
        local r = min(s.rr, s.h, s.w)
        local wi, hs = s.w - r, s.h - r
        if e[1] == "arcT" then
            local ph = e[2] * pi / 2
            return wi + r * cos(ph), hs + r * sin(ph)
        elseif e[1] == "str" then
            return s.w, hs - 2 * hs * e[2]
        else
            local ph = -e[2] * pi / 2
            return wi + r * cos(ph), -hs + r * sin(ph)
        end
    end
    local rings, kinds, fracs = {}, {}, {}
    for i, s in ipairs(st) do
        local side = norm(cross(s.n, s.t))
        local c = s.c
        local r = min(s.rr, s.h, s.w)
        local wi = s.w - r
        local function at(y, z) return add(add(s.o, mul(side, y)), mul(s.n, (c and c(y) or 0) + z)) end
        local ring = {}
        local function put(p, kind, f)
            ring[#ring + 1] = p
            if i == 1 then kinds[#ring], fracs[#ring] = kind, f end
        end
        for j = 0, nTop do put(at(wi * (1 - 2 * j / nTop), s.h), "top", 0) end
        for _, e in ipairs(edge) do
            local y, z = edgePt(s, e)
            put(at(-y, z), "side", (s.h - z) / (2 * max(s.h, 1e-6)))
        end
        for j = 0, nBot do put(at(-wi + 2 * wi * j / nBot, -s.h), "bottom", 1) end
        for k = #edge, 1, -1 do
            local y, z = edgePt(s, edge[k])
            put(at(y, z), "side", (s.h - z) / (2 * max(s.h, 1e-6)))
        end
        rings[i] = ring
    end
    -- the fraction of a side segment is fixed by its two ends at a full station
    local ref = st[opt.ref or max(1, floor(#st / 2))]
    do
        local j = 0
        local function f(z) return (ref.h - z) / (2 * ref.h) end
        local fl = {}
        for jj = 0, nTop do j = j + 1 fl[j] = 0 end
        for _, e in ipairs(edge) do j = j + 1 local _, z = edgePt(ref, e) fl[j] = f(z) end
        for jj = 0, nBot do j = j + 1 fl[j] = 1 end
        for k = #edge, 1, -1 do j = j + 1 local _, z = edgePt(ref, edge[k]) fl[j] = f(z) end
        fracs = fl
    end
    local m = #rings[1]
    local n = #rings
    local cen = {}
    for i = 1, n do
        local c = { 0, 0, 0 }
        for _, p in ipairs(rings[i]) do c = add(c, p) end
        cen[i] = mul(c, 1 / m)
    end
    local N = {}
    for i = 1, n do
        N[i] = {}
        local ia, ib = max(1, i - 1), min(n, i + 1)
        for j = 1, m do
            local ja, jb = (j - 2) % m + 1, j % m + 1
            local du = sub(rings[ib][j], rings[ia][j])
            local dv = sub(rings[i][jb], rings[i][ja])
            local c = cross(du, dv)
            local nn
            if len(c) < 1e-9 then
                nn = (i == 1) and mul(st[1].t, -1) or (i == n and st[n].t or norm(sub(rings[i][j], cen[i])))
            else
                nn = norm(c)
                local away = sub(rings[i][j], cen[i])
                if len(away) < 1e-6 then away = (i == 1) and mul(st[1].t, -1) or st[n].t end
                if dot(nn, away) < 0 then nn = mul(nn, -1) end
            end
            N[i][j] = nn
        end
    end
    local roleOf = opt.role or function() return opt.mat or "paint" end
    local segRole, segDet = {}, {}
    for j = 1, m do
        local j2 = j % m + 1
        local kind = (kinds[j] == kinds[j2]) and kinds[j] or "side"
        local f = (fracs[j] + fracs[j2]) * 0.5
        segRole[j], segDet[j] = roleOf(kind, f)
    end
    for i = 1, n - 1 do
        for j = 1, m do
            local j2 = j % m + 1
            local B = M:bucket(group, segRole[j], segDet[j] or opt.detail)
            local a, b, c, d = rings[i][j], rings[i + 1][j], rings[i + 1][j2], rings[i][j2]
            quad(B, a, b, c, d, N[i][j], N[i + 1][j], N[i + 1][j2], N[i][j2])
        end
    end
    if opt.caps then
        for _, e in ipairs({ { 1, -1 }, { n, 1 } }) do
            local s = st[e[1]]
            if s.w > 0.02 and s.h > 0.01 then
                cap(M:bucket(group, opt.capRole or segRole[1], opt.detail), rings[e[1]], mul(s.t, e[2]))
            end
        end
    end
    return rings
end

-- Triangles given in a 2D parameter space (u, v), split finely and carried onto
-- a curved surface by `map(u, v)` -> point, normal: a graphic printed on a deck.
local function decal(B, tris, map, nsub)
    for _, t in ipairs(tris) do
        local a, b, c = t[1], t[2], t[3]
        -- fine enough that no piece's chord sinks under a curved surface
        local function d(p, q) return sqrt((p[1] - q[1]) ^ 2 + (p[2] - q[2]) ^ 2) end
        local nsub = max(nsub or 3, math.ceil(max(d(a, b), d(b, c), d(c, a)) / 0.45))
        local function at(i, j)
            local k = nsub - i - j
            local u = (a[1] * k + b[1] * i + c[1] * j) / nsub
            local v = (a[2] * k + b[2] * i + c[2] * j) / nsub
            return map(u, v)
        end
        for i = 0, nsub - 1 do
            for j = 0, nsub - 1 - i do
                local p1, n1 = at(i, j)
                local p2, n2 = at(i + 1, j)
                local p3, n3 = at(i, j + 1)
                tri(B, p1, p2, p3, n1, n2, n3)
                if i + j < nsub - 1 then
                    local p4, n4 = at(i + 1, j + 1)
                    tri(B, p2, p4, p3, n2, n4, n3)
                end
            end
        end
    end
end

-- A 2D polygon (concave allowed) as triangles, for decal().
local function polyTris(loop)
    local out = {}
    for _, t in ipairs(earclip(loop)) do out[#out + 1] = { loop[t[1]], loop[t[2]], loop[t[3]] } end
    return out
end

-- An annulus (or a disc, r0 = 0) as triangles, for decal().
local function ringTris(cu, cv, r0, r1, n, a0, a1)
    local out = {}
    a0, a1 = a0 or 0, a1 or TAU
    for i = 0, n - 1 do
        local s, e = a0 + (a1 - a0) * i / n, a0 + (a1 - a0) * (i + 1) / n
        local A = { cu + cos(s) * r1, cv + sin(s) * r1 }
        local Bp = { cu + cos(e) * r1, cv + sin(e) * r1 }
        if r0 <= 0 then
            out[#out + 1] = { { cu, cv }, A, Bp }
        else
            local C = { cu + cos(e) * r0, cv + sin(e) * r0 }
            local D = { cu + cos(s) * r0, cv + sin(s) * r0 }
            out[#out + 1] = { A, Bp, C }
            out[#out + 1] = { A, C, D }
        end
    end
    return out
end

-- A hex nut / bolt head: a flat-sided lathe, `t` thick, across-flats radius r.
local function hexNut(B, o, axis, r, t, hole)
    lathe(B, { { hole or 0, 0, true }, { r, 0, true }, { r, t, true }, { hole or 0, t, true } }, o, axis, 6, { flat = true })
end

-- A socket-head (Allen) bolt head: a short cylinder with a chamfer and a dark hex
-- socket. `Hd` the head's bucket, `Hs` the socket's.
local function allenHead(Hd, Hs, o, axis, r, t, segs)
    axis = norm(axis)
    lathe(Hd, { { 0, 0, true }, { r, 0, true }, { r, t * 0.8 }, { r * 0.85, t, true }, { 0, t, true } }, o, axis, segs or 12)
    lathe(Hs, { { 0, t + 0.004, true }, { r * 0.45, t + 0.004, true } }, o, axis, 6, { flat = true })
end

-- Keep a model's buckets in `group` except those `drop(b)` says to throw away.
local function dropBuckets(M, group, drop)
    local g = M.groups[group]
    if not g then return end
    local keep = {}
    for _, b in ipairs(g) do if not drop(b) then keep[#keep + 1] = b end end
    M.groups[group] = keep
end

-- The offline preview (tools/bike/preview.py) lays its ground one wheelR radius under
-- the model's origin: in preview mode give it a speck there, at the real ground.
local function previewGround(M, depth)
    local B = M:bucket("wheelR", "rubber")
    local nn = V(0, 0, 1)
    tri(B, V(0, 0, -depth), V(0.01, 0, -depth), V(0, 0.01, -depth), nn, nn, nn)
    M.layout.at = M.layout.at or {}
    M.layout.at.wheelR = { V(0, 0, 0) }
end

G.boardParts = { slab = slab, decal = decal, polyTris = polyTris, ringTris = ringTris }

--==========================================================================
-- THE SKATEBOARD
--==========================================================================
local SB = {
    deckTop   = 1.80,       -- the top of the deck's middle, board space (the rider's feet)
    halfT     = 0.225,      -- half the deck's thickness: 7 plies, 11.5 mm
    edgeR     = 0.12,       -- the round-over on the deck's edge
    halfW     = 4.0,        -- an 8.0 deck
    concave   = 0.20,       -- how far the rails stand over the middle: mellow
    kickAt    = 9.3,        -- the kicks start just outside the outer truck bolts
    bend      = 2.6,        -- over this much deck
    noseA     = math.rad(20), tailA = math.rad(21),
    noseX     = 15.95, tailX = 15.80,   -- 31.75 long, the nose a touch longer
    endR      = 3.6,        -- the popsicle's round
    wheelR    = 1.063,      -- 54 mm
    wheelW    = 1.26,       -- 32 mm
    ground    = -1.3,       -- the ground under the board space's origin at the static sag
    truckIn   = 0.10,       -- the axle sits this far out from the baseplate's middle
    bolt      = { 1.0625, 0.8125 },  -- the new-school pattern, half its length and width
}

-- The deck's centre line: a point on the sheet's middle at y = 0 a distance `s`
-- along it (+ toward the nose), its tangent and its up; and its half width there.
local function deckLine(D, s)
    local sg = s >= 0 and 1 or -1
    local u = abs(s)
    local A = sg > 0 and D.noseA or D.tailA
    local Rb = D.bend / A
    local x, z, ph
    if u <= D.kickAt then
        x, z, ph = u, 0, 0
    elseif u <= D.kickAt + D.bend then
        ph = (u - D.kickAt) / Rb
        x, z = D.kickAt + Rb * sin(ph), Rb * (1 - cos(ph))
    else
        ph = A
        local e = u - D.kickAt - D.bend
        x, z = D.kickAt + Rb * sin(A) + e * cos(A), Rb * (1 - cos(A)) + e * sin(A)
    end
    local zmid = D.deckTop - D.halfT
    local o = V(x * sg, 0, zmid + z)
    -- the tangent along increasing s (so the loft runs one way end to end)
    local t = V(cos(ph), 0, sin(ph) * sg)
    local n = V(-sin(ph) * sg, 0, cos(ph))
    return o, t, n
end

-- The arc length at which each end's plan reaches its x.
local function deckEnds(D)
    local function solve(sg, X)
        local lo, hi = D.kickAt, D.kickAt + 12
        for _ = 1, 60 do
            local mid = (lo + hi) * 0.5
            local o = deckLine(D, mid * sg)
            if abs(o[1]) < X then lo = mid else hi = mid end
        end
        return (lo + hi) * 0.5
    end
    return solve(1, D.noseX), solve(-1, D.tailX)
end

-- Everything about the deck at arc length s: the frame, half width, half
-- thickness, the concave.
local function deckAt(D, s, uN, uT)
    local o, t, n = deckLine(D, s)
    local ue = s >= 0 and uN or uT
    local d = ue - abs(s)                    -- to the tip
    local w = D.halfW
    if d < D.endR then
        local q = (D.endR - d) / D.endR
        w = D.halfW * sqrt(max(0, 1 - q * q))
    end
    local h = D.halfT
    local tr = D.halfT                       -- the tip rounds over in elevation too
    if d < tr then
        local q = (tr - d) / tr
        h = D.halfT * sqrt(max(0, 1 - q * q))
    end
    -- the concave relaxes toward the tips
    local k = D.concave * (1 - 0.45 * smooth((abs(s) - D.kickAt) / (ue - D.kickAt)))
    local hw = D.halfW
    local c = function(y) return k * (y / hw) * (y / hw) end
    local dc = function(y) return 2 * k * y / (hw * hw) end
    return { o = o, t = t, n = n, w = max(w, 0), h = max(h, 0), rr = D.edgeR, c = c, dc = dc }
end

local function buildDeck(M, D)
    local uN, uT = deckEnds(D)
    -- stations: sparse in the flat, close through the bends and at the rounds
    local S = {}
    local function addRange(a, b, step)
        local n = math.max(1, math.ceil((b - a) / step))
        for i = 0, n - 1 do S[#S + 1] = a + (b - a) * i / n end
    end
    for _, sg in ipairs({ -1, 1 }) do
        local ue = sg > 0 and uN or uT
        local list = {}
        local function push(u) list[#list + 1] = u end
        local function range(a, b, step)
            local n = math.max(1, math.ceil((b - a) / step))
            for i = 0, n - 1 do push(a + (b - a) * i / n) end
        end
        range(0, D.kickAt - 1.8, 1.2)
        range(D.kickAt - 1.8, D.kickAt + D.bend + 0.4, 0.3)
        range(D.kickAt + D.bend + 0.4, ue - D.endR, 0.6)
        local K = 18
        for k = K, 1, -1 do push(ue - D.endR * (1 - cos(pi / 2 * k / K))) end
        push(ue)
        for _, u in ipairs(list) do
            if not (sg < 0 and u == 0) then S[#S + 1] = u * sg end
        end
    end
    table.sort(S)
    local st = {}
    for _, s in ipairs(S) do st[#st + 1] = deckAt(D, s, uN, uT) end
    -- seven plies on the edge: the outer veneers and the core natural, two dyed
    local function role(kind, f)
        if kind == "top" then return "rubber" end            -- the grip tape
        if kind == "bottom" then return "paint" end          -- the graphic's ground
        local ply = floor(min(0.999, max(0, f)) * 7)
        if ply == 1 or ply == 5 then return "paint" end
        return "wood"
    end
    local cuts = {}
    for k = 1, 6 do cuts[#cuts + 1] = k / 7 end
    -- the straight part of the edge is only (h - r) high; cut it at the plies'
    -- boundaries measured over the whole thickness
    local hs = D.halfT - D.edgeR
    local scuts = {}
    for _, f in ipairs(cuts) do
        local z = D.halfT - 2 * D.halfT * f
        if abs(z) < hs - 1e-3 then scuts[#scuts + 1] = (hs - z) / (2 * hs) end
    end
    slab(M, "deck", st, { nTop = 22, nBot = 22, nArc = 4, nStraight = 1, cuts = scuts, role = role })

    -- THE GRAPHIC, printed on the bottom: a roundel round a bolt of lightning in
    -- the middle, and a band with a slash at each end. Carried onto the underside
    -- (with its concave and kicks) a hair proud of it.
    local function under(s, y)
        local a = deckAt(D, s, uN, uT)
        local side = V(0, 1, 0)
        local p = add(add(a.o, mul(side, y)), mul(a.n, a.c(y) - a.h - 0.012))
        local nn = norm(sub(mul(side, a.dc(y)), a.n))
        return p, nn
    end
    local Wt, Bk = M:bucket("deck", "white"), M:bucket("deck", "black")
    decal(Wt, ringTris(-0.5, 0, 2.35, 2.75, 40), under, 2)
    decal(Bk, ringTris(-0.5, 0, 0, 2.35, 40), under, 2)
    -- the bolt, across the deck so it reads from the side the board is seen from
    local bolt = {}
    for _, q in ipairs({ { 0.1, 1.8 }, { 0.75, 1.8 }, { 0.2, 0.2 }, { 0.65, 0.2 }, { -0.35, -1.8 }, { -0.05, -0.2 }, { -0.5, -0.2 } }) do
        bolt[#bolt + 1] = { q[1] - 0.6, q[2] }
    end
    -- (over the roundel's disc, so a hair prouder than it)
    decal(Wt, polyTris(bolt), function(s, y)
        local p, nn = under(s, y)
        return add(p, mul(nn, 0.004)), nn
    end, 3)
    for _, sg in ipairs({ 1, -1 }) do
        local a, b = 3.3 * sg, 11.6 * sg
        -- a long band either side of the roundel, its outer end slashed
        local band = { { a, -1.55 }, { b, -1.55 }, { b + 1.0 * sg, 1.55 }, { a, 1.55 } }
        if sg < 0 then band = { band[4], band[3], band[2], band[1] } end
        local tris = polyTris(band)
        decal(Bk, tris, under, 4)
        local slash = { { b + 1.6 * sg, -1.55 }, { b + 2.1 * sg, -1.55 }, { b + 3.1 * sg, 1.55 }, { b + 2.6 * sg, 1.55 } }
        if sg < 0 then slash = { slash[4], slash[3], slash[2], slash[1] } end
        decal(Wt, polyTris(slash), under, 3)
        -- a pin stripe along it
        local pin = { { a + 0.3 * sg, -0.12 }, { b - 0.5 * sg, -0.12 }, { b - 0.5 * sg, 0.12 }, { a + 0.3 * sg, 0.12 } }
        if sg < 0 then pin = { pin[4], pin[3], pin[2], pin[1] } end
        decal(M:bucket("deck", "paint"), polyTris(pin), function(s, y)
            local p, nn = under(s, y)
            return add(p, mul(nn, 0.004)), nn
        end, 4)
    end

    -- THE BOLTS: eight countersunk heads through the grip, a hex socket in each.
    local Hd, Hs = M:bucket("deck", "steel", true), M:bucket("deck", "black", true)
    local tx = 8 - D.truckIn
    for _, sx in ipairs({ 1, -1 }) do
        for _, bx in ipairs({ -1, 1 }) do
            for _, by in ipairs({ -1, 1 }) do
                local x, y = sx * tx + bx * D.bolt[1], by * D.bolt[2]
                local a = deckAt(D, x, uN, uT)
                local up = norm(sub(a.n, mul(V(0, 1, 0), a.dc(y))))
                local top = add(add(a.o, V(0, y, 0)), mul(a.n, a.c(y) + a.h))
                lathe(Hd, { { 0.205, -0.01, true }, { 0.19, 0.012 }, { 0.12, 0.03 }, { 0, 0.035, true } }, top, up, 14)
                lathe(Hs, { { 0, 0.037, true }, { 0.07, 0.037, true } }, top, up, 6, { flat = true })
            end
        end
    end
    return uN, uT
end

-- ONE TRUCK'S STANDING PARTS, in truck space (origin: the baseplate's middle on the
-- deck's underside; x out toward the board's end, y left, z up). Returns the
-- points the hanger is built round.
local function truckGeom(D)
    local T = {}
    T.axle = V(D.truckIn, 0, D.ground + D.wheelR - (D.deckTop - 2 * D.halfT))   -- the axle, truck space
    T.kp0 = V(-0.45, 0, -0.16)                     -- where the kingpin leaves the baseplate
    T.kdir = norm(V(-0.55, 0, -1))                 -- down and in, toward the board's middle
    T.seat = add(T.kp0, mul(T.kdir, 0.86))         -- the hanger's bushing seat
    T.pdir = norm(V(-1, 0, -1))                    -- the pivot axis, down and in
    T.cup = V(1.12, 0, -0.42)                      -- the pivot cup
    T.nose = add(T.cup, mul(T.pdir, 0.62))         -- where the hanger's pivot arm starts
    T.pivot = lerp(T.seat, T.nose, 0.5)            -- what the hanger turns about when it carves
    T.hangerHalf = 4.6 - D.wheelW * 0.5 - 0.09     -- the hanger's end, inside the inner bearing
    return T
end

local function buildTruck(M, D, group)
    local T = truckGeom(D)
    local Al = M:bucket(group, "alloy")
    local St = M:bucket(group, "steel")
    local Std = M:bucket(group, "steel", true)
    local Bu = M:bucket(group, "paint")          -- the bushings and the pivot cup: urethane
    -- the baseplate's flange, the bolts' ends and their lock nuts under it
    plate(Al, roundRect(3.1, 2.3, 0.4, 5), V(0.05, 0, -0.085), V(1, 0, 0), V(0, 1, 0), 0.17, { smooth = true })
    for _, bx in ipairs({ -1, 1 }) do
        for _, by in ipairs({ -1, 1 }) do
            local c = V(-D.truckIn + bx * D.bolt[1], by * D.bolt[2], -0.17)
            hexNut(Std, c, V(0, 0, -1), 0.21, 0.17)
            lathe(M:bucket(group, "plastic", true), { { 0, 0.17, true }, { 0.17, 0.17, true }, { 0.15, 0.26 }, { 0, 0.27, true } },
                c, V(0, 0, -1), 10)
        end
    end
    -- the body under the flange: a web from the kingpin's boss out to the pivot cup's housing
    plate(Al, { { -1.05, -0.16 }, { 1.48, -0.16 }, { 1.42, -0.4 }, { 1.0, -0.66 }, { 0.45, -0.52 }, { -0.1, -0.42 },
                { -0.65, -0.5 }, { -0.95, -0.38 } }, V(0, 0, 0), V(1, 0, 0), V(0, 0, 1), 0.78, { smooth = true })
    -- the kingpin's boss, round the pin where it leaves the plate
    lathe(Al, { { 0.0, -0.05, true }, { 0.52, -0.05, true }, { 0.54, 0.1 }, { 0.5, 0.3, true }, { 0, 0.3, true } }, T.kp0, T.kdir, 22)
    -- the pivot cup's housing, and the cup at its mouth
    lathe(Al, { { 0, -0.42, true }, { 0.4, -0.42, true }, { 0.42, -0.2 }, { 0.42, 0.02 }, { 0.38, 0.1, true }, { 0.26, 0.1, true } },
        T.cup, T.pdir, 22)
    lathe(Bu, { { 0.22, 0.08, true }, { 0.36, 0.08, true }, { 0.36, 0.16 }, { 0.3, 0.2, true }, { 0.2, 0.2, true } }, T.cup, T.pdir, 18)
    -- the kingpin: a 3/8 bolt through the bushings, and its nut
    sweep(St, { add(T.kp0, mul(T.kdir, 0.25)), add(T.kp0, mul(T.kdir, 1.72)) }, 0.17, 12)
    local k = T.kdir
    local function along(d) return add(T.kp0, mul(k, d)) end
    -- cup washer, boardside bushing (a barrel), the seat is the hanger's, roadside (a cone), cup washer, nut
    lathe(Std, { { 0.17, 0.3, true }, { 0.47, 0.3, true }, { 0.5, 0.36, true }, { 0.17, 0.36, true } }, T.kp0, k, 20)
    lathe(Bu, { { 0.17, 0.36, true }, { 0.4, 0.36, true }, { 0.44, 0.42 }, { 0.45, 0.55 }, { 0.43, 0.68 }, { 0.38, 0.71, true }, { 0.17, 0.71, true } },
        T.kp0, k, 22)
    lathe(Bu, { { 0.17, 1.01, true }, { 0.38, 1.01, true }, { 0.39, 1.06 }, { 0.34, 1.2 }, { 0.3, 1.28, true }, { 0.17, 1.28, true } }, T.kp0, k, 22)
    lathe(Std, { { 0.17, 1.28, true }, { 0.36, 1.28, true }, { 0.39, 1.34, true }, { 0.17, 1.34, true } }, T.kp0, k, 20)
    hexNut(St, along(1.34), k, 0.29, 0.26)
    lathe(M:bucket(group, "plastic", true), { { 0, 1.6, true }, { 0.22, 1.6, true }, { 0.2, 1.68 }, { 0, 1.7, true } }, T.kp0, k, 12)
    return T
end

local function buildHanger(M, D, group)
    local T = truckGeom(D)
    local Al = M:bucket(group, "alloy")
    local St = M:bucket(group, "steel")
    local Std = M:bucket(group, "steel", true)
    local ax = T.axle
    local L = T.hangerHalf
    -- the hanger: a cast bar along the axle, round at its ends and deepening to the
    -- middle, its underside one straight line (the grinding face)
    local pts, R = {}, {}
    local nSt = 40
    for i = 0, nSt do
        local y = -L + 2 * L * i / nSt
        local m = max(0, 1 - (y / 2.7) ^ 2) ^ 2
        local rz, rx = 0.31 + 0.30 * m, 0.31 + 0.24 * m
        pts[#pts + 1] = V(ax[1] - 0.02 * m, y, ax[3] + 0.30 * m)
        R[#R + 1] = { rz, rx }
    end
    sweep(Al, pts, function(t)
        local i = floor(t * nSt + 0.5) + 1
        return R[i][1], R[i][2]
    end, 20, { up = V(0, 0, 1) })
    -- the bushing seat: a ring round the kingpin, and the bridge to it
    lathe(Al, { { 0.22, -0.15, true }, { 0.5, -0.15, true }, { 0.55, -0.06 }, { 0.55, 0.06 }, { 0.5, 0.15, true }, { 0.22, 0.15, true } },
        T.seat, T.kdir, 24)
    local hub = add(ax, V(-0.1, 0, 0.42))
    sweep(Al, bez3(hub, add(hub, V(-0.35, 0, 0.1)), add(T.seat, V(0.25, 0, -0.25)), add(T.seat, V(0.05, 0, -0.05)), 8),
        function(t) return 0.36 - 0.06 * t, 0.42 - 0.08 * t end, 16, { up = V(0, 1, 0) })
    -- the pivot arm, up and out into the cup
    local base = add(ax, V(0.12, 0, 0.35))
    sweep(Al, bez3(base, add(base, V(0.25, 0, 0.15)), sub(T.nose, mul(T.pdir, -0.0)), add(T.nose, mul(T.pdir, -0.3)), 8),
        function(t) return 0.34 - 0.1 * t end, 16, { up = V(0, 1, 0) })
    sweep(St, { add(T.nose, mul(T.pdir, -0.25)), add(T.cup, mul(T.pdir, 0.05)) }, 0.16, 12)
    -- the axle, the speed washers, the nuts
    sweep(St, { V(ax[1], -L - 1.7, ax[3]), V(ax[1], L + 1.7, ax[3]) }, 0.155, 12)
    for _, s in ipairs({ 1, -1 }) do
        local Y = V(0, s, 0)
        lathe(Std, { { 0.16, 0, true }, { 0.3, 0, true }, { 0.3, 0.06, true }, { 0.16, 0.06, true } }, add(ax, V(0, s * L, 0)), Y, 16)
        local outer = 4.6 + D.wheelW * 0.5
        lathe(Std, { { 0.16, 0, true }, { 0.3, 0, true }, { 0.3, 0.05, true }, { 0.16, 0.05, true } }, add(ax, V(0, s * (outer + 0.005), 0)), Y, 16)
        hexNut(St, add(ax, V(0, s * (outer + 0.055), 0)), Y, 0.26, 0.2, 0.15)
        lathe(M:bucket(group, "plastic", true), { { 0.155, 0.2, true }, { 0.24, 0.2, true }, { 0.2, 0.3, true }, { 0.155, 0.3, true } },
            add(ax, V(0, s * (outer + 0.055), 0)), Y, 12)
    end
    return T
end

-- A 54 mm street wheel about its own axle: urethane with a radiused lip, a 608
-- bearing in each face, a printed band so the spin shows.
local function buildSkateWheel(M, group, r, w, opt)
    opt = opt or {}
    local hw = w * 0.5
    local Ur = M:bucket(group, opt.role or "white")
    local Y = V(0, 1, 0)
    local o = V(0, 0, 0)
    local br = 0.433                         -- the bearing's outer race: 22 mm
    lathe(Ur, {
        { br, -hw + 0.08, true }, { br + 0.04, -hw + 0.02, true }, { r * 0.62, -hw }, { r * 0.82, -hw + 0.01 },
        { r * 0.92, -hw + 0.05 }, { r - 0.03, -hw * 0.62 }, { r, -hw * 0.3 }, { r + 0.003, 0 },
        { r, hw * 0.3 }, { r - 0.03, hw * 0.62 }, { r * 0.92, hw - 0.05 }, { r * 0.82, hw - 0.01 }, { r * 0.62, hw },
        { br + 0.04, hw - 0.02, true }, { br, hw - 0.08, true },
    }, o, Y, opt.segs or 40)
    -- the bearings, sat a little in: outer race, shield, inner race
    for _, s in ipairs({ 1, -1 }) do
        local yy = s * (hw - 0.08)
        local function ringAt(role, r0, r1, dy)
            local y = yy + s * (dy or 0)
            local prof = s > 0 and { { r1, y, true }, { r0, y, true } } or { { r0, y, true }, { r1, y, true } }
            lathe(M:bucket(group, role), prof, o, Y, 24)
        end
        ringAt("steel", 0.38, br, 0)
        ringAt(opt.shield or "black", 0.215, 0.38, -0.012)
        ringAt("steel", 0.157, 0.215, 0)
    end
    -- the print on each face: two arcs of lettering, so a turning wheel reads as one
    if opt.print ~= false then
        local Pr = M:bucket(group, opt.printRole or "black", true)
        for _, s in ipairs({ 1, -1 }) do
            local y = s * (hw + 0.004)
            for _, a0 in ipairs({ 0.3, pi + 0.3 }) do
                local n = 7
                for i = 0, n - 1 do
                    local a, b = a0 + i * 0.16, a0 + i * 0.16 + 0.11
                    local r0, r1 = r * 0.66, r * 0.8
                    if i == 3 then r0 = r * 0.7 end
                    local p = { V(cos(a) * r0, y, sin(a) * r0), V(cos(b) * r0, y, sin(b) * r0),
                                V(cos(b) * r1, y, sin(b) * r1), V(cos(a) * r1, y, sin(a) * r1) }
                    local nn = V(0, s, 0)
                    quad(Pr, p[1], p[2], p[3], p[4], nn, nn, nn, nn)
                end
            end
        end
    end
end

G.RegisterKind("skateboard", function(opt, G)
    local D = {}
    for k, v in pairs(SB) do D[k] = v end
    local half = (opt.wheelbase or 16) * 0.5
    D.truckIn = 0.10
    D.trackY = (opt.extra and opt.extra.track) or 4.6
    local M = Pm.newModel()
    local uN, uT = buildDeck(M, D)
    local T = buildTruck(M, D, "truck")
    buildHanger(M, D, "hanger")
    buildSkateWheel(M, "wheel", D.wheelR, D.wheelW)
    local truckZ = D.deckTop - 2 * D.halfT
    local tx = half - D.truckIn
    local wz = D.ground + D.wheelR
    M.layout = {
        k = 1,
        deckTop = D.deckTop,
        truckAt = V(tx, 0, truckZ),            -- the front truck's origin; the rear's is mirrored
        pivot = T.pivot,                       -- truck space: what the hanger turns about
        axle = T.axle,                         -- truck space
        track = D.trackY,
        wheelR = D.wheelR,
        front = V(half, 0, wz), rear = V(-half, 0, wz),
        at = {
            truck = { V(tx, 0, truckZ) },
            hanger = { V(tx, 0, truckZ) },
            wheel = { V(half, D.trackY, wz), V(half, -D.trackY, wz), V(-half, D.trackY, wz), V(-half, -D.trackY, wz) },
        },
    }
    -- the preview places groups by translation only: give it the rear truck as built
    if opt.extra and opt.extra.preview then
        local function copyTurned(src, dst)
            for _, b in ipairs(M.groups[src]) do
                local d = M:bucket(dst, b.mat, b.detail)
                for _, vt in ipairs(b.v) do
                    d.v[#d.v + 1] = { p = V(-vt.p[1], -vt.p[2], vt.p[3]), n = V(-vt.n[1], -vt.n[2], vt.n[3]), u = vt.u, v = vt.v }
                end
                d.tris = d.tris + b.tris
            end
        end
        copyTurned("truck", "truckRear")
        copyTurned("hanger", "hangerRear")
        M.layout.at.truckRear = { V(-tx, 0, truckZ) }
        M.layout.at.hangerRear = { V(-tx, 0, truckZ) }
        previewGround(M, -D.ground)
    end
    return M
end)

--==========================================================================
-- THE SCOOTER
--==========================================================================
local function scooterDims(opt)
    local e = opt.extra or {}
    local D = {
        half = (opt.wheelbase or 28) * 0.5, r = opt.radius or 5,
        deckTop = e.deckTop or 1.7, deckFront = e.deckFront or 12.2, deckBack = e.deckBack or -9,
        deckW = e.deckWidth or 5.0, barH = e.barHeight or 35, barW = e.barWidth or 22,
        headFoot = e.headFoot or 1.6, headLean = e.headLean or 4.0,
        pegY = e.pegY or 3.6,
    }
    D.headB = V(D.half - D.headFoot, 0, 2.2)
    D.headT = V(D.half - D.headFoot - D.headLean, 0, D.barH - 2.0)
    D.axis = norm(sub(D.headT, D.headB))
    D.fwd = norm(cross(V(0, 1, 0), D.axis))          -- square to the steer axis, forward
    D.bars = add(D.headT, V(0, 0, 2.0))
    D.tw = max(0.9, min(2.0, 0.4 * D.r))              -- the tyre's width
    D.deckH = 1.25                                    -- a box-section deck
    D.zb = D.deckTop - D.deckH
    D.legY = D.tw * 0.5 + 0.42                        -- the fork legs and the rear dropouts
    -- the deck stops short of each tyre (at a 10-inch wheel) or runs to Tune's ends
    local function reach(z) return sqrt(max(0, D.r * D.r - z * z)) end
    D.xf = min(D.deckFront, D.half - reach(D.zb) - 0.75)
    D.xb = max(D.deckBack, -D.half + reach(D.zb) + 0.55)
    -- the head tube's foot: Tune's, raised until the fork crown under it clears the tyre
    local zhb = D.headB[3]
    local front = V(D.half, 0, 0)
    for _ = 1, 400 do
        local cb = add(D.headB, mul(D.axis, (zhb - 1.05 - D.headB[3]) / D.axis[3]))
        local dx, dz = cb[1] - front[1], cb[3] - front[3]
        if sqrt(dx * dx + dz * dz) >= D.r + 0.45 then break end
        zhb = zhb + 0.05
    end
    D.zhb = zhb
    D.htLen = 4.8
    return D
end

local function axisAt(D, z) return add(D.headB, mul(D.axis, (z - D.headB[3]) / D.axis[3])) end

-- A knurled peg about +-y from `y0` out `len`, at `c` (the axle).
local function peg(B, c, s, y0, plen, r)
    local prof = { { 0.33, 0, true }, { r - 0.08, 0, true }, { r, 0.1 }, { r, 0.22, true } }
    local h = 0.32
    while h < plen - 0.35 do
        prof[#prof + 1] = { r, h, true }
        prof[#prof + 1] = { r - 0.03, h + 0.04, true }
        prof[#prof + 1] = { r - 0.03, h + 0.1, true }
        prof[#prof + 1] = { r, h + 0.14, true }
        h = h + 0.4
    end
    prof[#prof + 1] = { r, plen - 0.1, true }
    prof[#prof + 1] = { r - 0.1, plen, true }
    prof[#prof + 1] = { r * 0.6, plen, true }
    prof[#prof + 1] = { r * 0.55, plen - 0.35, true }
    prof[#prof + 1] = { 0, plen - 0.35, true }
    lathe(B, prof, add(c, V(0, y0 * s, 0)), V(0, s, 0), 24)
end

-- An axle bolt across a pair of dropouts at `c`, `half` out each side: the head
-- on +y, a nut on -y.
local function axleBolt(M, group, c, half)
    local Ch = M:bucket(group, "chrome")
    local Cd = M:bucket(group, "chrome", true)
    sweep(M:bucket(group, "steel"), { add(c, V(0, -half - 0.4, 0)), add(c, V(0, half + 0.25, 0)) }, 0.3, 14)
    allenHead(Ch, M:bucket(group, "black", true), add(c, V(0, half, 0)), V(0, 1, 0), 0.46, 0.3, 18)
    hexNut(Cd, add(c, V(0, -half, 0)), V(0, -1, 0), 0.46, 0.34, 0.3)
end

local function buildScooterDeck(M, D)
    local g = "deck"
    local Pt = M:bucket(g, "paint")
    -- the deck: a box section with rounded edges, grip on top, its nose and tail rounded in plan
    local st = {}
    local W = D.deckW * 0.5
    local n = 40
    local Rf, Rr = 1.6, 0.9
    for i = 0, n do
        local x = D.xb + (D.xf - D.xb) * i / n
        local w = W
        local dF, dR = D.xf - x, x - D.xb
        if dF < Rf then w = W - Rf + sqrt(max(0, Rf * Rf - (Rf - dF) ^ 2)) end
        if dR < Rr then w = W - Rr + sqrt(max(0, Rr * Rr - (Rr - dR) ^ 2)) end
        st[#st + 1] = { o = V(x, 0, D.deckTop - D.deckH * 0.5), t = V(1, 0, 0), n = V(0, 0, 1),
                        w = max(w, 0.05), h = D.deckH * 0.5, rr = 0.32 }
    end
    slab(M, g, st, { nTop = 10, nBot = 6, nArc = 4, nStraight = 2, caps = true, capRole = "paint",
        role = function(kind) return kind == "top" and "rubber" or "paint" end })
    -- the maker's name down each side, in block letters, so it is a deck and not a box
    local Bk = M:bucket(g, "black")
    for _, s in ipairs({ 1, -1 }) do
        local y = s * (W + 0.004)
        local x0, x1 = D.xb + 2.2, D.xf - 3.2
        local z0, z1 = D.deckTop - D.deckH * 0.5 - 0.22, D.deckTop - D.deckH * 0.5 + 0.22
        local nn = V(0, s, 0)
        local x = x0
        local k = 0
        while x < x1 - 0.3 do
            local wdt = (k % 3 == 2) and 0.18 or 0.42
            local zz1 = (k % 4 == 1) and z1 - 0.12 or z1
            quad(Bk, V(x, y, z0), V(x + wdt, y, z0), V(x + wdt, y, zz1), V(x, y, zz1), nn, nn, nn, nn)
            x = x + wdt + 0.14
            k = k + 1
        end
    end

    -- THE NECK, up from the deck's nose to the head tube, and a gusset under it
    local hbot = axisAt(D, D.zhb)
    local P0 = V(D.xf - 2.2, 0, D.deckTop - 0.6)
    local P1 = V(D.xf - 0.4, 0, D.deckTop - 0.5)
    local H0 = axisAt(D, D.zhb + 1.4)
    local path = bez3(P0, add(P1, V(0.35, 0, 1.3)), sub(sub(H0, mul(D.axis, 1.6)), mul(D.fwd, 1.1)), H0, 16)
    sweep(Pt, path, function(t) return 1.12 - 0.2 * t, 0.62 + 0.28 * t end, 22, { up = V(0, 1, 0) })
    local a = V(D.xf - 0.9, 0, D.zb + 0.2)
    local b = add(axisAt(D, D.zhb + 0.3), mul(D.fwd, -0.2))
    local mid = path[floor(#path * 0.55)]
    local gb = bez3(a, add(a, V(0.6, 0, 0.6)), sub(sub(b, mul(D.axis, 1.3)), mul(D.fwd, 0.6)), b, 10)
    local loop = {}
    for _, p in ipairs(gb) do loop[#loop + 1] = { p[1], p[3] } end
    loop[#loop + 1] = { mid[1] - 0.15, mid[3] - 0.25 }
    loop[#loop + 1] = { P1[1] - 0.6, P1[3] - 0.3 }
    plate(Pt, loop, V(0, 0, 0), V(1, 0, 0), V(0, 0, 1), 0.38, { smooth = true })

    -- THE HEAD TUBE, integrated, with the headset's cups at each end
    local L = D.htLen
    lathe(Pt, { { 0, 0, true }, { 0.98, 0, true }, { 1.03, 0.12 }, { 0.97, 0.42 }, { 0.95, 0.65 },
                { 0.95, L - 0.65 }, { 0.97, L - 0.42 }, { 1.03, L - 0.12 }, { 0.98, L, true }, { 0, L, true } },
        hbot, D.axis, 30)
    local Bkc = M:bucket(g, "black")
    lathe(Bkc, { { 0, -0.16, true }, { 0.99, -0.16, true }, { 1.0, -0.02 }, { 0.98, 0, true }, { 0, 0, true } }, hbot, D.axis, 30)
    lathe(Bkc, { { 0, L, true }, { 0.98, L, true }, { 1.0, L + 0.03 }, { 0.97, L + 0.16, true }, { 0, L + 0.16, true } }, hbot, D.axis, 30)

    -- THE REAR: the deck end's dropouts to the axle, the axle bolt, the pegs
    local ax = V(-D.half, 0, 0)
    for _, s in ipairs({ 1, -1 }) do
        local lp = {}
        local xa = D.xb + 1.0
        local function P(x, z) lp[#lp + 1] = { x, z } end
        P(xa, D.zb + 0.12)
        for _, q in ipairs(bez3(V(xa - 0.4, 0, D.zb + 0.1), V(xa - 1.6, 0, D.zb - 0.2), V(ax[1] + 1.4, 0, -0.75), V(ax[1] + 0.2, 0, -0.78), 8)) do
            P(q[1], q[3])
        end
        for k = 1, 11 do
            local th = -pi / 2 - k / 12 * pi
            P(ax[1] + cos(th) * 0.78, sin(th) * 0.78)
        end
        for _, q in ipairs(bez3(V(ax[1] + 0.2, 0, 0.78), V(ax[1] + 1.6, 0, 0.8), V(xa - 1.8, 0, D.deckTop - 0.25), V(xa - 0.4, 0, D.deckTop - 0.2), 8)) do
            P(q[1], q[3])
        end
        P(xa, D.deckTop - 0.2)
        plate(Pt, lp, V(0, D.legY * s, 0), V(1, 0, 0), V(0, 0, 1), 0.3, { smooth = true })
        -- a spacer between the hub and the dropout
        local y0 = D.tw * 0.5 + 0.06
        lathe(M:bucket(g, "alloy"), { { 0.3, 0, true }, { 0.42, 0, true }, { 0.42, D.legY - 0.15 - y0, true },
            { 0.3, D.legY - 0.15 - y0, true } }, add(ax, V(0, s * y0, 0)), V(0, s, 0), 16)
        peg(M:bucket(g, "alloy"), ax, s, D.legY + 0.45, D.pegY + 0.9 - D.legY - 0.45, 0.66)
    end
    axleBolt(M, g, ax, D.legY + 0.15)

    -- THE FLEX FENDER: spring steel bolted on the deck's tail, over the tyre
    local rf = D.r + 0.42
    local zf = D.deckTop + 0.075
    local th0 = math.asin(min(0.99, zf / rf))
    local fp = {}
    fp[#fp + 1] = V(D.xb + 1.9, 0, zf)
    fp[#fp + 1] = V(D.xb + 0.6, 0, zf)
    local a0 = V(ax[1] + rf * cos(th0), 0, rf * sin(th0))
    -- from the deck's end into the arc (a short bridge where the deck stops short of it)
    if D.xb - a0[1] > 0.3 then
        for _, q in ipairs(bez3(V(D.xb, 0, zf), V(D.xb - 0.25, 0, zf), add(a0, V(0.25, 0, -0.05)), a0, 4)) do fp[#fp + 1] = q end
    else
        fp[#fp + 1] = V(D.xb, 0, zf)
    end
    local th1 = math.rad(104)
    local na = 22
    for k = 1, na do
        local th = th0 + (th1 - th0) * k / na
        fp[#fp + 1] = V(ax[1] + rf * cos(th), 0, rf * sin(th))
    end
    local fst = {}
    for i, p in ipairs(fp) do
        local q0, q1 = fp[max(1, i - 1)], fp[min(#fp, i + 1)]
        local t = norm(sub(q1, q0))
        local nn = norm(cross(t, V(0, 1, 0)))
        if nn[3] < 0 and i < 3 then nn = mul(nn, -1) end
        if dot(nn, sub(p, ax)) < 0 and i >= 3 then nn = mul(nn, -1) end
        local w = 0.95
        local tail = #fp - i
        if tail < 3 then w = 0.95 - (3 - tail) * 0.12 end
        fst[#fst + 1] = { o = p, t = t, n = nn, w = w, h = 0.06, rr = 0.05 }
    end
    slab(M, g, fst, { nTop = 6, nBot = 4, nArc = 2, nStraight = 1, caps = true, mat = "black", capRole = "black" })
    local Hd, Hs = M:bucket(g, "chrome", true), M:bucket(g, "black", true)
    for _, x in ipairs({ D.xb + 0.55, D.xb + 1.45 }) do
        allenHead(Hd, Hs, V(x, 0, zf + 0.06), V(0, 0, 1), 0.24, 0.12, 12)
    end
end

local function buildScooterFork(M, D)
    local g = "fork"
    local Bk = M:bucket(g, "black")
    local crown = axisAt(D, D.zhb - 0.62)
    local Y = D.legY
    -- the crown: an oval bar across, under the headset
    local cp = {}
    for i = 0, 12 do
        local y = -(Y + 0.4) + 2 * (Y + 0.4) * i / 12
        cp[#cp + 1] = add(crown, V(0, y, 0))
    end
    sweep(Bk, cp, function(t)
        local e = abs(t * 2 - 1)
        return 0.42 + 0.08 * (1 - e * e), 0.62 + 0.1 * (1 - e * e)
    end, 18, { up = V(0, 0, 1) })
    -- the steerer's stub between the crown and the headset
    sweep(Bk, { add(crown, mul(D.axis, 0.2)), axisAt(D, D.zhb - 0.1) }, 0.6, 18, { capStart = false })
    -- the legs, straight to the dropouts
    local ax = V(D.half, 0, 0)
    for _, s in ipairs({ 1, -1 }) do
        local top = add(crown, V(0, Y * s, 0))
        local bot = add(ax, V(-0.05, Y * s, 0.45))
        local pts = {}
        for i = 0, 10 do pts[#pts + 1] = lerp(top, bot, i / 10) end
        sweep(Bk, pts, function(t) return 0.4 - 0.08 * t end, 18)
        -- the dropout: a boss round the axle
        lathe(Bk, { { 0.3, -0.17, true }, { 0.62, -0.17, true }, { 0.66, -0.08 }, { 0.66, 0.08 }, { 0.62, 0.17, true }, { 0.3, 0.17, true } },
            add(ax, V(0, Y * s, 0)), V(0, 1, 0), 22)
        local y0 = D.tw * 0.5 + 0.06
        lathe(M:bucket(g, "alloy"), { { 0.3, 0, true }, { 0.42, 0, true }, { 0.42, Y - 0.17 - y0, true },
            { 0.3, Y - 0.17 - y0, true } }, add(ax, V(0, s * y0, 0)), V(0, s, 0), 16)
        peg(M:bucket(g, "alloy"), ax, s, Y + 0.45, D.pegY + 0.9 - Y - 0.45, 0.66)
    end
    axleBolt(M, g, ax, Y + 0.17)
end

local function buildScooterBars(M, D)
    local g = "bars"
    local Bk = M:bucket(g, "black")
    local Bd = M:bucket(g, "black", true)
    local Ch = M:bucket(g, "chrome", true)
    local zt = D.zhb + D.htLen + 0.18
    -- the 4-bolt clamp round the bar's foot and the steerer, its slit and ears to the front
    local c0 = axisAt(D, zt)
    local CL = 2.1
    lathe(Bk, { { 0, 0, true }, { 1.0, 0, true }, { 1.04, 0.08 }, { 1.04, CL - 0.08 }, { 1.0, CL, true }, { 0.72, CL, true } },
        c0, D.axis, 28)
    local cm = add(c0, mul(D.axis, CL * 0.5))
    box(Bk, add(cm, mul(D.fwd, 1.08)), mul(D.fwd, 0.36), V(0, 0.58, 0), mul(D.axis, CL * 0.5 - 0.06))
    box(M:bucket(g, "plastic"), add(cm, mul(D.fwd, 1.45)), mul(D.fwd, 0.02), V(0, 0.05, 0), mul(D.axis, CL * 0.5 - 0.02))
    for _, h in ipairs({ -0.78, -0.3, 0.3, 0.78 }) do
        local bp = add(add(cm, mul(D.fwd, 1.08)), mul(D.axis, h))
        allenHead(Ch, Bd, add(bp, V(0, 0.58, 0)), V(0, 1, 0), 0.2, 0.17, 12)
        lathe(Ch, { { 0, 0, true }, { 0.13, 0, true }, { 0.13, 0.08 }, { 0, 0.1, true } }, add(bp, V(0, -0.58, 0)), V(0, -1, 0), 8)
    end
    -- the T-bar: an oversized downtube up to a straight crossbar, gussets at the T
    local bc = D.bars
    local foot = add(c0, mul(D.axis, 0.15))
    local top = axisAt(D, zt + CL + 0.1)
    sweep(Bk, { foot, top, lerp(top, bc, 0.5), bc }, 0.69, 24, { capStart = false })
    lathe(Bd, { { 0.62, -0.06, true }, { 0.74, -0.04 }, { 0.75, 0.04 }, { 0.62, 0.06, true } }, axisAt(D, zt + CL + 0.03), D.axis, 24)
    local half = D.barW * 0.5
    sweep(Bk, { V(bc[1], -half + 0.15, bc[3]), V(bc[1], half - 0.15, bc[3]) }, 0.5, 22)
    for _, s in ipairs({ 1, -1 }) do
        local a = sub(bc, mul(D.axis, 3.4))
        local b = V(bc[1], 3.6 * s, bc[3])
        sweep(Bk, { a, lerp(a, b, 0.5), b }, 0.27, 12)
        -- the grip: ribbed rubber with a flange, and the bar end's plug
        local prof = { { 0.5, 0, true }, { 0.82, 0, true }, { 0.82, 0.16, true }, { 0.68, 0.18, true } }
        local y = 0.3
        local gl = 4.2
        while y < gl - 0.25 do
            prof[#prof + 1] = { 0.68, y, true }
            prof[#prof + 1] = { 0.645, y + 0.05 }
            prof[#prof + 1] = { 0.645, y + 0.17 }
            prof[#prof + 1] = { 0.68, y + 0.22, true }
            y = y + 0.3
        end
        prof[#prof + 1] = { 0.7, gl - 0.05 }
        prof[#prof + 1] = { 0.6, gl, true }
        prof[#prof + 1] = { 0.0, gl, true }
        lathe(M:bucket(g, "rubber"), prof, V(bc[1], (half - gl) * s, bc[3]), V(0, s, 0), 24)
        lathe(M:bucket(g, "alloy"), { { 0, 0, true }, { 0.52, 0, true }, { 0.55, 0.08 }, { 0.5, 0.2, true }, { 0, 0.22, true } },
            V(bc[1], (half - 0.04) * s, bc[3]), V(0, s, 0), 18)
    end
    -- the bell, on the left of the bar inboard of the grip
    local bellAt = V(bc[1], half - 4.2 - 0.95, bc[3])
    local pv, axb = G.parts.bell(M, g, "bellLever", bellAt, V(0, 1, 0), V(0, 0, 1), V(-1, 0, 0))
    return pv, axb
end

G.RegisterKind("scooter", function(opt, G)
    local D = scooterDims(opt)
    local M = Pm.newModel()
    buildScooterDeck(M, D)
    buildScooterFork(M, D)
    local pv, axb = buildScooterBars(M, D)
    local R = G.WheelDims(D.r, { width = D.tw, height = 0.3 * D.r, rimDepth = 0.1 * D.r, rimW = D.tw * 0.86 })
    G.parts.wheel(M, "wheel", R, { tread = "slick", wall = "rubber", mag = 6, rim = "alloy", hubRole = "alloy",
        hubHalf = D.tw * 0.5 + 0.06 })
    -- a solid urethane wheel: no sidewall lettering, no valve
    dropBuckets(M, "wheel", function(b) return b.mat == "tyretext" or (b.mat == "steel" and b.detail) or #b.v == 0 end)
    local half = D.barW * 0.5
    local function grip(side)
        return { A = V(D.bars[1], -(half - 3.6) * side, D.bars[3]), B = V(D.bars[1], -half * side, D.bars[3]) }
    end
    M.layout = {
        k = 1, steer = D.axis, headB = D.headB, headT = D.headT,
        front = V(D.half, 0, 0), rear = V(-D.half, 0, 0),
        bars = D.bars, gripR = grip(1), gripL = grip(-1),
        bellPivot = pv, bellAxis = axb, deckTop = D.deckTop, wheelR = D.r,
        at = { wheel = { V(D.half, 0, 0), V(-D.half, 0, 0) } },
    }
    if opt.extra and opt.extra.preview then previewGround(M, D.r) end
    return M
end)

--==========================================================================
-- THE SKATES
--==========================================================================
-- A loft through rings of points (each ring the same count), closed round
-- (opt.open = false) or not. Normals by central differences; `opt.orient`
-- "out" turns each away from its ring's middle, "in" toward it, or a function
-- (i, j, n) -> bool saying whether to flip. `opt.role(j)` the bucket of the
-- segment from point j to j+1 (default opt.mat).
local function loft(M, group, rings, opt)
    opt = opt or {}
    local closed = opt.open ~= true
    local n, m = #rings, #rings[1]
    local cen = {}
    for i = 1, n do
        local c = { 0, 0, 0 }
        for _, p in ipairs(rings[i]) do c = add(c, p) end
        cen[i] = mul(c, 1 / m)
    end
    local N = {}
    for i = 1, n do
        N[i] = {}
        local ia, ib = max(1, i - 1), min(n, i + 1)
        for j = 1, m do
            local ja, jb
            if closed then ja, jb = (j - 2) % m + 1, j % m + 1 else ja, jb = max(1, j - 1), min(m, j + 1) end
            local du = sub(rings[ib][j], rings[ia][j])
            local dv = sub(rings[i][jb], rings[i][ja])
            local c = cross(du, dv)
            local nn
            if len(c) < 1e-10 then
                nn = norm(sub(rings[i][j], cen[i]))
                if len(sub(rings[i][j], cen[i])) < 1e-6 then nn = norm(du) end
            else
                nn = norm(c)
            end
            local o = opt.orient or "out"
            if type(o) == "function" then
                if o(i, j, nn) then nn = mul(nn, -1) end
            else
                local away = sub(rings[i][j], cen[i])
                if len(away) > 1e-6 then
                    local d = dot(nn, away)
                    if (o == "out" and d < 0) or (o == "in" and d > 0) then nn = mul(nn, -1) end
                end
            end
            N[i][j] = nn
        end
    end
    -- a ring closed to a line (a toe, a heel) faces straight off the end
    if opt.firstN then for j = 1, m do N[1][j] = opt.firstN end end
    if opt.lastN then for j = 1, m do N[n][j] = opt.lastN end end
    local jmax = closed and m or m - 1
    for i = 1, n - 1 do
        for j = 1, jmax do
            local j2 = j % m + 1
            local role, det = opt.mat or "paint", opt.detail
            if opt.role then role = opt.role(j, i) or role end
            local B = M:bucket(group, role, det)
            quad(B, rings[i][j], rings[i + 1][j], rings[i + 1][j2], rings[i][j2], N[i][j], N[i + 1][j], N[i + 1][j2], N[i][j2])
        end
    end
    return N
end

-- A closed strap (a slab whose stations run round a loop and meet).
local function band(M, group, pts, outward, w, h, opt)
    local st = {}
    local n = #pts
    for i = 1, n + 1 do
        local p = pts[(i - 1) % n + 1]
        local a, b = pts[(i - 2) % n + 1], pts[i % n + 1]
        local t = norm(sub(b, a))
        local nn = outward(p, t)
        st[#st + 1] = { o = p, t = t, n = nn, w = w, h = h, rr = min(h, 0.04) }
    end
    slab(M, group, st, { nTop = 3, nBot = 2, nArc = 2, nStraight = 1, mat = opt and opt.mat or "black" })
end

-- An open strap along `pts` (capped at both ends).
local function strap(M, group, pts, outward, w, h, opt)
    local st = {}
    local n = #pts
    for i = 1, n do
        local p = pts[i]
        local t = norm(sub(pts[min(n, i + 1)], pts[max(1, i - 1)]))
        st[#st + 1] = { o = p, t = t, n = outward(p, t, i), w = w, h = h, rr = min(h, 0.05) }
    end
    slab(M, group, st, { nTop = 3, nBot = 2, nArc = 2, nStraight = 1, caps = true, mat = opt and opt.mat or "black",
        capRole = opt and opt.mat or "black", detail = opt and opt.detail })
end

-- Piecewise-smooth interpolation through a table { {x, value}, ... }.
local function curve(tab, x)
    if x <= tab[1][1] then return tab[1][2] end
    for i = 1, #tab - 1 do
        local a, b = tab[i], tab[i + 1]
        if x <= b[1] then return a[2] + (b[2] - a[2]) * smooth((x - a[1]) / (b[1] - a[1])) end
    end
    return tab[#tab][2]
end

local SK = {
    heel = -4.3, toe = 7.3,                      -- the boot's length, about the ankle
    width = { { -4.3, 1.5 }, { -2.0, 1.58 }, { 0.5, 1.72 }, { 3.6, 1.98 }, { 5.6, 1.92 }, { 7.3, 1.6 } },
    top   = { { -4.3, 4.3 }, { -2.2, 4.75 }, { 0.2, 4.85 }, { 1.4, 4.4 }, { 2.8, 3.6 }, { 4.4, 2.9 }, { 6.0, 2.5 }, { 7.3, 2.15 } },
    cuffZ0 = 3.2, cuffZ1 = 8.75,
    soulT = 0.42,                                -- the soul plate's thickness
    wheelR = 1.083,                              -- 55 mm
    arR = 0.866,                                 -- 44 mm anti-rockers
    wheelW = 0.95,                               -- 24 mm
    wallY = 0.62,                                -- the frame's walls
}

-- The shell's ring at x: a superellipse in y-z, its bottom flat on the sole.
local function shellRing(x, nr)
    local w = curve(SK.width, x)
    local h = curve(SK.top, x)
    -- rounded in plan at the heel and the toe
    local dH, dT = x - SK.heel, SK.toe - x
    local q = 1
    if dH < 1.3 then q = sqrt(max(0, 1 - ((1.3 - dH) / 1.3) ^ 2)) end
    if dT < 1.9 then q = sqrt(max(0, 1 - ((1.9 - dT) / 1.9) ^ 2)) end
    w = w * q
    local hz = h * 0.5 * (0.55 + 0.45 * q)
    local zc = hz
    local ring = {}
    for j = 0, nr - 1 do
        local a = j / nr * TAU
        local ca, sa = cos(a), sin(a)
        local e = sa >= 0 and 2.6 or 5.0
        local cy = (abs(ca) ^ (2 / e)) * (ca < 0 and -1 or 1)
        local cz = (abs(sa) ^ (2 / e)) * (sa < 0 and -1 or 1)
        ring[j + 1] = V(x, cy * w, zc + cz * hz)
    end
    return ring, w, zc + hz
end

-- Where the shell's top is over (x, y): for the straps and the laces.
local function shellTopAt(x, y)
    local w = curve(SK.width, x)
    local h = curve(SK.top, x)
    local hz = h * 0.5
    local u = min(1, abs(y) / w)
    -- superellipse e = 2.6: |y/w|^(2/e)... solve for the top's z at this y
    local e = 2.6
    local ca = u ^ (e / 2)
    local sa = sqrt(max(0, 1 - ca * ca))
    return hz + (sa ^ (2 / e)) * hz
end

local function cuffCentre(z) return V(-0.6 + (z - SK.cuffZ0) * 0.12, 0, z) end
-- the cuff's top is cut lower at the front than at the back
local function cuffTop(a) return SK.cuffZ1 - 0.45 * cos(a) end
local function cuffR(z)
    local t = (z - SK.cuffZ0) / (SK.cuffZ1 - SK.cuffZ0)
    t = max(0, min(1, t))
    return 1.98 + 0.34 * t, 1.84 + 0.3 * t
end

local function buildBoot(M)
    local g = "skate"
    -- THE SHELL
    local rings = {}
    local nr = 40
    local xs = {}
    local K = 10
    for k = 0, K - 1 do xs[#xs + 1] = SK.heel + 1.3 * (1 - cos(pi / 2 * k / K)) end
    for x = SK.heel + 1.3, SK.toe - 1.9, 0.45 do xs[#xs + 1] = x end
    for k = K, 0, -1 do xs[#xs + 1] = SK.toe - 1.9 * (1 - cos(pi / 2 * k / K)) end
    for _, x in ipairs(xs) do rings[#rings + 1] = (shellRing(x, nr)) end
    loft(M, g, rings, { orient = function(i, j, nn)
        local p = rings[i][j]
        local c = V(max(SK.heel + 1.6, min(SK.toe - 2.2, p[1])), 0, 2.2)
        if i == 1 then return dot(nn, V(-1, 0, 0)) < -0.3 and dot(nn, sub(p, c)) < 0 end
        if i == #rings then return dot(nn, V(1, 0, 0)) < -0.3 and dot(nn, sub(p, c)) < 0 end
        return dot(nn, sub(p, c)) < 0
    end, firstN = V(-1, 0, 0), lastN = V(1, 0, 0), role = function(j)
        -- the sole's welt round the bottom: black
        local a = (j - 0.5) / nr * TAU
        return sin(a) < -0.55 and "plastic" or "paint"
    end })

    -- THE CUFF: a hard shell round the back and sides of the shin, open at the front
    local Ca = "plastic"
    local nz, na = 12, 26
    local a0, a1 = math.rad(38), math.rad(322)       -- from the front's right round the back to its left
    local outer, inner = {}, {}
    for i = 0, nz do
        outer[i + 1], inner[i + 1] = {}, {}
        for j = 0, na do
            local a = a0 + (a1 - a0) * j / na
            local z = SK.cuffZ0 + (cuffTop(a) - SK.cuffZ0) * i / nz
            local c = cuffCentre(z)
            local rx, ry = cuffR(z)
            local d = V(cos(a), sin(a), 0)
            outer[i + 1][j + 1] = add(c, V(d[1] * rx, d[2] * ry, 0))
            inner[i + 1][j + 1] = add(c, V(d[1] * (rx - 0.16), d[2] * (ry - 0.16), 0))
        end
    end
    loft(M, g, outer, { open = true, mat = Ca, orient = "out" })
    loft(M, g, inner, { open = true, mat = Ca, orient = "in" })
    -- the edges: top and bottom rims, and the two front edges (the tri winder sorts
    -- each quad's facing by its normal, so each is given the outward one)
    local function rim(i, up)
        local Bk = M:bucket(g, Ca)
        for j = 1, na do
            local p1, p2, p3, p4 = outer[i][j], outer[i][j + 1], inner[i][j + 1], inner[i][j]
            local nn = norm(cross(sub(p2, p1), sub(p4, p1)))
            if nn[3] * up < 0 then nn = mul(nn, -1) end
            quad(Bk, p1, p2, p3, p4, nn, nn, nn, nn)
        end
    end
    rim(nz + 1, 1)
    rim(1, -1)
    for _, j in ipairs({ 1, na + 1 }) do
        local Bk = M:bucket(g, Ca)
        for i = 1, nz do
            local p1, p2, p3, p4 = outer[i][j], outer[i + 1][j], inner[i + 1][j], inner[i][j]
            local tang = norm(sub(outer[i][j == 1 and 2 or na], p1))
            local nn = mul(tang, -1)
            quad(Bk, p1, p2, p3, p4, nn, nn, nn, nn)
        end
    end
    -- the cuff's rivets, at the ankle each side
    for _, s in ipairs({ 1, -1 }) do
        local c = cuffCentre(SK.cuffZ0 + 0.9)
        local rx, ry = cuffR(SK.cuffZ0 + 0.9)
        lathe(M:bucket(g, "chrome", true), { { 0, 0, true }, { 0.32, 0, true }, { 0.3, 0.08 }, { 0.18, 0.13 }, { 0, 0.14, true } },
            add(c, V(0, s * ry, 0)), V(0, s, 0), 14)
    end

    -- THE LINER: padding inside the cuff, rolled over its top into a collar
    local prof = { { -0.17, 4.4 }, { -0.17, 8.95 }, { -0.12, 9.25 }, { 0.0, 9.42 }, { 0.14, 9.42 }, { 0.24, 9.25 }, { 0.26, 9.0 }, { 0.2, 8.86 } }
    local lr = {}
    local nl = 32
    for i, pz in ipairs(prof) do
        lr[i] = {}
        for j = 0, nl - 1 do
            local a = j / nl * TAU
            local z = pz[2] + (cuffTop(a) - SK.cuffZ1) * smooth((pz[2] - 4.4) / (SK.cuffZ1 - 4.4))
            local zc = min(z, cuffTop(a))
            local c = cuffCentre(zc)
            local rx, ry = cuffR(zc)
            lr[i][j + 1] = add(c, V(cos(a) * (rx + pz[1]), sin(a) * (ry + pz[1]), z - c[3]))
        end
    end
    loft(M, g, lr, { mat = "seat", orient = function(i, j, nn)
        -- the inside wall faces the leg, the roll and the outside face away
        local p = lr[i][j]
        local c = cuffCentre(min(p[3], SK.cuffZ1))
        local away = sub(V(p[1], p[2], 0), V(c[1], c[2], 0))
        if i <= 2 then return dot(nn, away) > 0 end
        if i == 3 or i == 4 or i == 5 then return nn[3] < 0 end
        return dot(nn, away) < 0
    end })

    -- THE TONGUE, up the front of the shin from the toe box
    local tp = spline({ V(5.0, 0, shellTopAt(5.0, 0) - 0.05), V(3.6, 0, shellTopAt(3.6, 0) + 0.06), V(2.45, 0, 4.75),
                        V(1.95, 0, 6.3), V(1.9, 0, 7.6), V(2.0, 0, 8.75) }, 5)
    strap(M, g, tp, function(p, t)
        local nn = norm(cross(V(0, 1, 0), t))
        if nn[1] < 0 and nn[3] < 0.5 then nn = mul(nn, -1) end
        if dot(nn, V(0.7, 0, 0.7)) < 0 then nn = mul(nn, -1) end
        return nn
    end, 1.2, 0.2, { mat = "seat" })

    -- THE LACES, crossed over the tongue between eyelets on the shell
    local Lc = M:bucket(g, "white", true)
    local ey = {}
    for k = 0, 5 do
        local x = 4.5 - k * 0.62
        local y = 1.34
        ey[#ey + 1] = { x = x, z = shellTopAt(x, y) + 0.02 }
        for _, s in ipairs({ 1, -1 }) do
            lathe(M:bucket(g, "chrome", true), { { 0.06, 0, true }, { 0.13, 0, true }, { 0.13, 0.05, true }, { 0.06, 0.05, true } },
                V(x, y * s, ey[#ey].z), norm(V(0, 0.35 * s, 1)), 10)
        end
    end
    for k = 1, #ey - 1 do
        for _, s in ipairs({ 1, -1 }) do
            local a = V(ey[k].x, 1.3 * s, ey[k].z + 0.04)
            local b = V(ey[k + 1].x, -1.3 * s, ey[k + 1].z + 0.04)
            local m = lerp(a, b, 0.5)
            m = V(m[1], m[2], shellTopAt(m[1], 0) + 0.36 + 0.03 * s)
            sweep(Lc, spline({ a, m, b }, 4), 0.045, 6)
        end
    end
    do -- a bow at the top
        local x, z = ey[#ey].x - 0.2, shellTopAt(ey[#ey].x, 0) + 0.32
        for _, s in ipairs({ 1, -1 }) do
            sweep(Lc, spline({ V(x, 0, z), V(x + 0.15, 0.45 * s, z + 0.1), V(x - 0.35, 0.7 * s, z + 0.05), V(x - 0.1, 0.05 * s, z) }, 4), 0.045, 6)
        end
    end

    -- THE STRAPS: the cuff's buckle strap, the power strap over the ankle, the
    -- instep buckle over the forefoot
    do
        local pts = {}
        local z = 7.75
        local c = cuffCentre(z)
        local rx, ry = cuffR(z)
        for j = 0, 39 do
            local a = j / 40 * TAU
            pts[#pts + 1] = add(c, V(cos(a) * (rx + 0.07), sin(a) * (ry + 0.07), 0))
        end
        band(M, g, pts, function(p, t) return norm(sub(V(p[1], p[2], 0), V(c[1], c[2], 0))) end, 0.36, 0.05, { mat = "paint" })
    end
    do
        local pts = {}
        local zc = 4.55
        for k = 0, 24 do
            local a = math.rad(-112 + 224 * k / 24)
            local z = zc + 0.75 * cos(a)
            local c = cuffCentre(z)
            local rx, ry = cuffR(z)
            local fr = max(0, cos(a)) ^ 2
            pts[#pts + 1] = add(c, V(cos(a) * (rx + 0.24 + 0.5 * fr), sin(a) * (ry + 0.1), 0))
        end
        strap(M, g, pts, function(p, t)
            local c = cuffCentre(p[3])
            return norm(sub(V(p[1], p[2], 0), V(c[1], c[2], 0)))
        end, 0.55, 0.06, { mat = "rubber" })
    end
    do
        local pts = {}
        local x = 3.3
        local w = curve(SK.width, x)
        for k = 0, 16 do
            local y = -w * 0.98 + 2 * w * 0.98 * k / 16
            local zz = shellTopAt(x, y)
            if abs(y) > w * 0.9 then zz = zz - (abs(y) - w * 0.9) * 6 end
            -- over the tongue
            zz = zz + 0.27 * smooth((1.55 - abs(y)) / 0.35)
            pts[#pts + 1] = V(x, y * 1.03, zz + 0.07)
        end
        strap(M, g, pts, function(p, t)
            local nn = norm(cross(t, V(1, 0, 0)))
            if nn[3] < 0 then nn = mul(nn, -1) end
            return nn
        end, 0.38, 0.05, { mat = "black" })
    end
end

-- The levers of the cuff buckle and the instep buckle, on the outside of the boot
-- (s = 1: +y, a left boot; -1: a right one).
local function buildLevers(M, group, s)
    local Al = M:bucket(group, "alloy")
    local Bk = M:bucket(group, "black", true)
    -- cuff buckle: a lever along the strap, its hinge and its ladder
    local z = 7.75
    local c = cuffCentre(z)
    local rx, ry = cuffR(z)
    local a = math.rad(70) * s
    local p = add(c, V(cos(a) * (rx + 0.2), sin(a) * (ry + 0.2), 0))
    local t = norm(V(-sin(a) * rx, cos(a) * ry, 0))
    local out = norm(V(cos(a) * ry, sin(a) * rx, 0))
    box(Al, p, mul(t, 0.6), mul(out, 0.1), V(0, 0, 0.3))
    sweep(Bk, { add(add(p, mul(t, -0.55)), V(0, 0, -0.32)), add(add(p, mul(t, -0.55)), V(0, 0, 0.32)) }, 0.09, 8)
    for k = 1, 4 do
        local q = add(add(p, mul(t, -0.8 - k * 0.22)), mul(out, -0.08))
        box(Bk, q, mul(t, 0.05), mul(out, 0.05), V(0, 0, 0.3))
    end
    -- instep buckle: on the outside of the forefoot
    local x = 3.3
    local w = curve(SK.width, x)
    local q = V(x, s * (w + 0.12), 1.7)
    box(Al, q, V(0.32, 0, 0), V(0, 0.09, 0), V(0, 0, 0.55))
    sweep(Bk, { add(q, V(-0.33, 0, -0.5)), add(q, V(0.33, 0, -0.5)) }, 0.08, 8)
end

local function buildSoulAndFrame(M, R, pitch, axZ)
    local g = "skate"
    -- THE SOUL PLATE: under the whole boot, widest under the arch where it grinds
    local st = {}
    local n = 36
    local x0, x1 = SK.heel + 0.25, SK.toe - 0.35
    for i = 0, n do
        local x = x0 + (x1 - x0) * i / n
        local w = curve(SK.width, x) + 0.12
        local soul = smooth((x + 1.8) / 0.8) * smooth((2.8 - x) / 0.8)
        w = w + 0.3 * soul
        local dH, dT = x - x0, x1 - x
        if dH < 1.1 then w = w * sqrt(max(0, 1 - ((1.1 - dH) / 1.1) ^ 2)) end
        if dT < 1.6 then w = w * sqrt(max(0, 1 - ((1.6 - dT) / 1.6) ^ 2)) end
        st[#st + 1] = { o = V(x, 0, -SK.soulT * 0.5), t = V(1, 0, 0), n = V(0, 0, 1), w = max(w, 0.05), h = SK.soulT * 0.5, rr = 0.1 }
    end
    slab(M, g, st, { nTop = 10, nBot = 12, nArc = 3, nStraight = 1, mat = "plastic", caps = true, capRole = "plastic" })
    -- the soul's groove: a dark channel across the arch
    box(M:bucket(g, "black"), V(0.45, 0, -SK.soulT - 0.01), V(0.22, 0, 0), V(0, curve(SK.width, 0.45) + 0.38, 0), V(0, 0, 0.012))

    -- THE FRAME: two walls with a lug round each axle, scalloped between, joined under
    -- the soul plate, the H-block in the middle; four axle bolts
    local Fr = M:bucket(g, "black")
    local xs = { 1.5 * pitch, 0.5 * pitch, -0.5 * pitch, -1.5 * pitch }
    local top = -SK.soulT - 0.02
    local lugR = 0.5
    local xF, xB = xs[1], xs[4]
    local loop = {}
    local function put(x, z) loop[#loop + 1] = { x, z } end
    -- the top edge is the loop's last stretch; start at the front, over the front wheel
    for _, q in ipairs(bez3(V(xF + 0.15, 0, top), V(xF + 0.95, 0, top), V(xF + lugR + 0.25, 0, axZ + 0.55), V(xF + lugR, 0, axZ), 8)) do
        put(q[1], q[3])
    end
    for k = 1, 4 do
        local x = xs[k]
        for q = 1, 8 do
            local tt = -(q / 8) * pi
            put(x + cos(tt) * lugR, axZ + sin(tt) * lugR)
        end
        if k < 4 then
            local xm = (x + xs[k + 1]) * 0.5
            for _, q in ipairs(bez3(V(x - lugR, 0, axZ), V(x - lugR, 0, axZ + 0.5), V(xm + 0.2, 0, axZ + 0.5), V(xm, 0, axZ + 0.5), 4)) do
                if _ > 1 then put(q[1], q[3]) end
            end
            for _, q in ipairs(bez3(V(xm, 0, axZ + 0.5), V(xm - 0.2, 0, axZ + 0.5), V(xs[k + 1] + lugR, 0, axZ + 0.5), V(xs[k + 1] + lugR, 0, axZ), 4)) do
                if _ > 1 then put(q[1], q[3]) end
            end
        end
    end
    for _, q in ipairs(bez3(V(xB - lugR, 0, axZ), V(xB - lugR - 0.25, 0, axZ + 0.55), V(xB - 0.95, 0, top), V(xB - 0.15, 0, top), 8)) do
        if _ > 1 then put(q[1], q[3]) end
    end
    local xe = xF + 0.15
    for _, s in ipairs({ 1, -1 }) do
        plate(Fr, loop, V(0, SK.wallY * s, 0), V(1, 0, 0), V(0, 0, 1), 0.16, { smooth = true })
    end
    box(Fr, V(0, 0, top - 0.06), V(xe - 0.5, 0, 0), V(0, SK.wallY - 0.05, 0), V(0, 0, 0.06))
    -- the H-block: between the middle wheels, a channel underneath for the rail
    local hb = { { -SK.wallY - 0.08, top - 0.05 }, { SK.wallY + 0.08, top - 0.05 }, { SK.wallY + 0.08, axZ - 0.55 },
                 { 0.3, axZ - 0.55 }, { 0.3, axZ - 0.12 }, { -0.3, axZ - 0.12 }, { -0.3, axZ - 0.55 }, { -SK.wallY - 0.08, axZ - 0.55 } }
    plate(M:bucket(g, "plastic"), hb, V(0, 0, 0), V(0, 1, 0), V(0, 0, 1), 0.98, { smooth = false })
    -- the axle bolts: a socket head each side
    local Hd, Hs = M:bucket(g, "chrome", true), M:bucket(g, "black", true)
    for _, x in ipairs(xs) do
        sweep(M:bucket(g, "steel"), { V(x, -SK.wallY - 0.08, axZ), V(x, SK.wallY + 0.08, axZ) }, 0.16, 10)
        for _, s in ipairs({ 1, -1 }) do
            allenHead(Hd, Hs, V(x, s * (SK.wallY + 0.08), axZ), V(0, s, 0), 0.27, 0.11, 12)
        end
    end
end

-- An aggressive wheel: flat-faced urethane round a coloured core with five
-- windows, its bearings. And the anti-rocker: hard plastic, smaller.
local function buildAggWheel(M, group, r, w, core)
    local hw = w * 0.5
    local o, Y = V(0, 0, 0), V(0, 1, 0)
    local ur = core and r * 0.66 or 0.47
    lathe(M:bucket(group, core and "white" or "plastic"), {
        { ur, -hw + 0.05, true }, { ur + 0.03, -hw, true }, { r * 0.86, -hw }, { r * 0.95, -hw + 0.05 },
        { r - 0.015, -hw * 0.6 }, { r, -hw * 0.25 }, { r + 0.002, 0 }, { r, hw * 0.25 }, { r - 0.015, hw * 0.6 },
        { r * 0.95, hw - 0.05 }, { r * 0.86, hw }, { ur + 0.03, hw, true }, { ur, hw - 0.05, true },
    }, o, Y, 36)
    for _, s in ipairs({ 1, -1 }) do
        local yy = s * (hw - 0.05)
        local function ringAt(role, r0, r1, dy, det)
            local y = yy + s * (dy or 0)
            local prof = s > 0 and { { r1, y, true }, { r0, y, true } } or { { r0, y, true }, { r1, y, true } }
            lathe(M:bucket(group, role, det), prof, o, Y, 24)
        end
        if core then
            ringAt("paint", 0.433, ur, 0)
            -- five windows in the core, so a turning wheel shows it
            local Bk = M:bucket(group, "black", true)
            for k = 0, 4 do
                local a = k / 5 * TAU
                local c = V(cos(a) * (0.433 + ur) * 0.5, yy + s * 0.004, sin(a) * (0.433 + ur) * 0.5)
                local rr = (ur - 0.433) * 0.32
                local ring = {}
                for q = 0, 9 do
                    local b = q / 10 * TAU
                    ring[#ring + 1] = add(c, V(cos(b) * rr, 0, sin(b) * rr))
                end
                cap(Bk, ring, V(0, s, 0))
            end
        end
        ringAt("steel", 0.38, 0.433, -0.03)
        ringAt("black", 0.215, 0.38, -0.04)
        ringAt("steel", 0.157, 0.215, -0.03)
    end
end

G.RegisterKind("skates", function(opt, G)
    local e = opt.extra or {}
    local R0 = opt.radius or 1.6
    local pitch = e.wheelPitch or 3.0
    local contact = -(2 * R0 - 0.4)                  -- where BootFrame stands its wheels
    local axZ = contact + SK.wheelR
    local M = Pm.newModel()
    buildBoot(M)
    buildSoulAndFrame(M, R0, pitch, axZ)
    buildLevers(M, "skateOutL", 1)
    buildLevers(M, "skateOutR", -1)
    buildAggWheel(M, "wheel", SK.wheelR, SK.wheelW, true)
    buildAggWheel(M, "wheelAR", SK.arR, SK.wheelW * 0.86, false)
    local main = { V(1.5 * pitch, 0, axZ), V(-1.5 * pitch, 0, axZ) }
    local ar = { V(0.5 * pitch, 0, axZ), V(-0.5 * pitch, 0, axZ) }
    M.layout = {
        k = 1, wheelR = SK.wheelR, arR = SK.arR, contact = contact,
        wheels = main, antiRockers = ar,
        at = { wheel = main, wheelAR = ar },
    }
    if e.preview then previewGround(M, -contact) end
    return M
end)
