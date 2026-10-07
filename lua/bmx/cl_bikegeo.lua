--[[--------------------------------------------------------------------------
    bmx/cl_bikegeo.lua

    THE BIKE AS A REAL 3D MODEL, built from code: every tube, weld, tooth,
    spoke, knob and pedal pin as triangles with smooth normals and UVs.

    It used to be ~55 base-game props (an XQM cylinder, a sphere, a cube)
    stretched into tubes, which reads as a toy at any distance. This builds
    the model a modeller would: a mid-school street BMX at real dimensions --
    20 x 2.3 skinwall tyres with a file tread on 36-hole double-wall rims laced
    three-cross, a 25/9 drivetrain with a modelled chain, three-piece tubular
    cranks, platform pedals with pins, 9" two-piece bars with a crossbar, a
    top-load stem, a gyro and a U-brake, an integrated head tube with a
    gusset, a pivotal seat, chromed pegs. cl_bikemesh.lua turns it into
    IMeshes and draws it; nothing here touches the game, so the same code
    runs offline (tools/bike/export.lua) for previews and tests.

    COORDINATES. Source's: x forward, y LEFT, z up, in inches (Source units),
    for a stock bike (39 wheelbase, 10 wheel radius) and then multiplied by
    the bike's own scale `k`. The design origin is the middle of the axle
    line, the same space as cl_init.lua's FRAME table, so the frame, fork and
    bars share it and are placed by rigid transforms of it. The wheels are
    built about their own axle, the pedals about their own centre.

    GROUPS. Parts that move together: frame (incl. the rear brake, the frame
    end of the cable, the chain, the rear pegs), fork (incl. front pegs and
    the gyro's top plate), bars (stem, bars, grips, lever), wheelF, wheelR
    (tyre, rim, spokes, hub shell -- the parts that spin), cranks (arms,
    spindle, chainring), pedal (one, drawn twice). Each group is a list of
    buckets by material role; a bucket marked `detail` is skipped far away.
----------------------------------------------------------------------------]]

BMX = BMX or {}
local G = {}
BMX.BikeGeo = G

local sqrt, sin, cos, pi, abs = math.sqrt, math.sin, math.cos, math.pi, math.abs
local max, min, floor = math.max, math.min, math.floor
local TAU = pi * 2

--------------------------------------------------------------------------
-- Vector maths on {x, y, z} arrays. Plain tables, not GMod Vectors, so the
-- builder runs in a stock Lua.
--------------------------------------------------------------------------
local function V(x, y, z) return { x, y, z } end
local function add(a, b) return { a[1] + b[1], a[2] + b[2], a[3] + b[3] } end
local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function mul(a, s) return { a[1] * s, a[2] * s, a[3] * s } end
local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function cross(a, b)
    return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] }
end
local function len(a) return sqrt(dot(a, a)) end
local function norm(a)
    local l = len(a)
    if l < 1e-9 then return { 0, 0, 1 } end
    return { a[1] / l, a[2] / l, a[3] / l }
end
local function lerp(a, b, t) return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t } end
-- a, b, c... weighted: madd(a, b, s) = a + b*s
local function madd(a, b, s) return { a[1] + b[1] * s, a[2] + b[2] * s, a[3] + b[3] * s } end
-- Any unit vector perpendicular to `a`, preferring the plane of `hint`.
local function perp(a, hint)
    local h = hint or { 0, 0, 1 }
    local p = sub(h, mul(a, dot(h, a)))
    if len(p) < 1e-4 then
        h = abs(a[3]) < 0.9 and { 0, 0, 1 } or { 1, 0, 0 }
        p = sub(h, mul(a, dot(h, a)))
    end
    return norm(p)
end
-- Rotate v about unit axis by ang (Rodrigues, right-handed).
local function rot(v, axis, ang)
    local c, s = cos(ang), sin(ang)
    return add(add(mul(v, c), mul(cross(axis, v), s)), mul(axis, dot(axis, v) * (1 - c)))
end
G.vec = { V = V, add = add, sub = sub, mul = mul, dot = dot, cross = cross,
          len = len, norm = norm, lerp = lerp, rot = rot }

--------------------------------------------------------------------------
-- THE BUFFER. A model is { groups = { name = { buckets } } }; a bucket is
-- { mat = role, detail = bool, tris = n, v = { p, n, u, v, ... } } with three
-- vertices a triangle, each { p = {x,y,z}, n = {x,y,z}, u, v }.
--------------------------------------------------------------------------
local Model = {}
Model.__index = Model

local function newModel() return setmetatable({ groups = {}, order = {} }, Model) end

function Model:bucket(group, mat, detail)
    local g = self.groups[group]
    if not g then
        g = {}
        self.groups[group] = g
        self.order[#self.order + 1] = group
    end
    local key = mat .. (detail and "+" or "")
    for _, b in ipairs(g) do if b.key == key then return b end end
    local b = { key = key, mat = mat, detail = detail and true or false, tris = 0, v = {} }
    g[#g + 1] = b
    return b
end

-- One triangle, wound counter-clockwise seen from where its normals point
-- (right-handed): if the given order disagrees with the normals, it is
-- swapped, so no primitive has to get winding right by hand.
local function tri(B, pa, pb, pc, na, nb, nc, ua, va, ub, vb, uc, vc)
    local g = cross(sub(pb, pa), sub(pc, pa))
    local s = { na[1] + nb[1] + nc[1], na[2] + nb[2] + nc[2], na[3] + nb[3] + nc[3] }
    local t = B.v
    local i = #t
    if dot(g, s) < 0 then
        pb, pc, nb, nc, ub, uc, vb, vc = pc, pb, nc, nb, uc, ub, vc, vb
    end
    t[i + 1] = { p = pa, n = na, u = ua or 0, v = va or 0 }
    t[i + 2] = { p = pb, n = nb, u = ub or 0, v = vb or 0 }
    t[i + 3] = { p = pc, n = nc, u = uc or 0, v = vc or 0 }
    B.tris = B.tris + 1
end

-- A quad a-b-c-d (in order round its edge) as two triangles.
local function quad(B, pa, pb, pc, pd, na, nb, nc, nd, ua, va, ub, vb, uc, vc, ud, vd)
    tri(B, pa, pb, pc, na, nb, nc, ua, va, ub, vb, uc, vc)
    tri(B, pa, pc, pd, na, nc, nd, ua, va, uc, vc, ud, vd)
end

-- A grid of points P[i][j] (i along, j round) skinned with smooth normals.
-- `closedJ`: the last column joins the first. Normals come from central
-- differences, then are turned to face away from `inside(i, j)` (a point
-- inside the solid for that ring), so the caller never sets winding.
local function grid(B, P, closedJ, inside, Nfix)
    local ni, nj = #P, #P[1]
    local N = {}
    for i = 1, ni do
        N[i] = {}
        for j = 1, nj do
            local n
            if Nfix and Nfix[i] and Nfix[i][j] then
                n = Nfix[i][j]
            else
                local ia, ib = max(1, i - 1), min(ni, i + 1)
                local ja, jb = j - 1, j + 1
                if closedJ then
                    if ja < 1 then ja = nj end
                    if jb > nj then jb = 1 end
                else
                    ja, jb = max(1, ja), min(nj, jb)
                end
                local du = sub(P[ib][j], P[ia][j])
                local dv = sub(P[i][jb], P[i][ja])
                n = norm(cross(du, dv))
                local c = inside(i, j)
                if dot(n, sub(P[i][j], c)) < 0 then n = mul(n, -1) end
            end
            N[i][j] = n
        end
    end
    local jmax = closedJ and nj or nj - 1
    for i = 1, ni - 1 do
        for j = 1, jmax do
            local j2 = j % nj + 1
            local u1, u2 = (j - 1) / nj, j / nj
            local v1, v2 = (i - 1) / (ni - 1), i / (ni - 1)
            quad(B, P[i][j], P[i + 1][j], P[i + 1][j2], P[i][j2],
                N[i][j], N[i + 1][j], N[i + 1][j2], N[i][j2],
                u1, v1, u1, v2, u2, v2, u2, v1)
        end
    end
end

-- A flat cap over a closed ring of points (convex or star-shaped about its
-- centroid), facing `n`.
local function cap(B, ring, n)
    local c = { 0, 0, 0 }
    for _, p in ipairs(ring) do c = add(c, p) end
    c = mul(c, 1 / #ring)
    for j = 1, #ring do
        local a, b = ring[j], ring[j % #ring + 1]
        tri(B, c, a, b, n, n, n, 0.5, 0.5, 0, 0, 1, 0)
    end
end

--------------------------------------------------------------------------
-- SWEEP: a tube along a path. `r` is a number, or a function of t (0..1)
-- returning radius or (rx, ry) for an oval, rx along the frame's `n`. The
-- frame is carried along by parallel transport from `up` (a hint for which
-- way an oval's rx faces), so a bent tube does not twist.
--------------------------------------------------------------------------
local function sweep(B, pts, r, sides, opt)
    opt = opt or {}
    local n = #pts
    if n < 2 then return end
    -- cumulative length for t and v
    local L = { 0 }
    for i = 2, n do L[i] = L[i - 1] + len(sub(pts[i], pts[i - 1])) end
    local total = max(L[n], 1e-6)
    local T = {}
    for i = 1, n do
        local a, b = pts[max(1, i - 1)], pts[min(n, i + 1)]
        T[i] = norm(sub(b, a))
    end
    local N = { perp(T[1], opt.up) }
    for i = 2, n do
        local q = sub(N[i - 1], mul(T[i], dot(N[i - 1], T[i])))
        N[i] = len(q) > 1e-6 and norm(q) or perp(T[i], opt.up)
    end
    local P, NN = {}, {}
    for i = 1, n do
        local t = L[i] / total
        local rx, ry
        if type(r) == "function" then rx, ry = r(t) else rx = r end
        ry = ry or rx
        local bn = cross(T[i], N[i])
        P[i], NN[i] = {}, {}
        for j = 1, sides do
            local a = (j - 1) / sides * TAU + (opt.phase or 0)
            local ca, sa = cos(a), sin(a)
            P[i][j] = add(pts[i], add(mul(N[i], ca * rx), mul(bn, sa * ry)))
            NN[i][j] = norm(add(mul(N[i], ca * ry), mul(bn, sa * rx)))
        end
    end
    grid(B, P, true, function(i) return pts[i] end, NN)
    if opt.capStart ~= false then cap(B, P[1], mul(T[1], -1)) end
    if opt.capEnd ~= false then cap(B, P[n], T[n]) end
    return P
end

--------------------------------------------------------------------------
-- LATHE: a profile { {r, h, hard}, ... } turned about an axis through `o`.
-- `hard` puts a crease at that point (a machined edge); otherwise normals
-- are smooth along the profile. Normals face away from the axis where the
-- profile runs in +h, so list outer surfaces in increasing h.
-- `segs` round; `flat` gives faceted sides (a hex nut is segs = 6, flat).
--------------------------------------------------------------------------
local function lathe(B, prof, o, axis, segs, opt)
    opt = opt or {}
    axis = norm(axis)
    local ref = perp(axis, opt.ref)
    local side = cross(axis, ref)
    local m = #prof
    -- profile segment normals in (r, h)
    local segN = {}
    for i = 1, m - 1 do
        local dr, dh = prof[i + 1][1] - prof[i][1], prof[i + 1][2] - prof[i][2]
        local l = sqrt(dr * dr + dh * dh)
        if l < 1e-9 then segN[i] = { 1, 0 } else segN[i] = { dh / l, -dr / l } end
    end
    if opt.inward then for i = 1, m - 1 do segN[i] = { -segN[i][1], -segN[i][2] } end end
    local function radial(a)
        local ca, sa = cos(a), sin(a)
        return add(mul(ref, ca), mul(side, sa))
    end
    local a0 = opt.phase or 0
    for i = 1, m - 1 do
        local p1, p2 = prof[i], prof[i + 1]
        -- the normal at each end of this segment: its own if that end is a
        -- crease (or the profile's end), else averaged with the neighbour
        local function endN(k, other)
            if prof[k][3] or not segN[other] then return segN[i] end
            local a, b = segN[i], segN[other]
            local x, y = a[1] + b[1], a[2] + b[2]
            local l = sqrt(x * x + y * y)
            return l > 1e-9 and { x / l, y / l } or a
        end
        local n1, n2 = endN(i, i - 1), endN(i + 1, i + 1)
        if p1[1] > 1e-6 or p2[1] > 1e-6 then
            for j = 1, segs do
                local aa, ab = a0 + (j - 1) / segs * TAU, a0 + j / segs * TAU
                local ra, rb = radial(aa), radial(ab)
                local na1, nb1, na2, nb2
                if opt.flat then
                    local rm = radial((aa + ab) * 0.5)
                    na1 = norm(add(mul(rm, n1[1]), mul(axis, n1[2])))
                    na2 = norm(add(mul(rm, n2[1]), mul(axis, n2[2])))
                    nb1, nb2 = na1, na2
                else
                    na1 = norm(add(mul(ra, n1[1]), mul(axis, n1[2])))
                    nb1 = norm(add(mul(rb, n1[1]), mul(axis, n1[2])))
                    na2 = norm(add(mul(ra, n2[1]), mul(axis, n2[2])))
                    nb2 = norm(add(mul(rb, n2[1]), mul(axis, n2[2])))
                end
                local A = add(o, add(mul(ra, p1[1]), mul(axis, p1[2])))
                local Bp = add(o, add(mul(rb, p1[1]), mul(axis, p1[2])))
                local C = add(o, add(mul(rb, p2[1]), mul(axis, p2[2])))
                local D = add(o, add(mul(ra, p2[1]), mul(axis, p2[2])))
                local u1, u2 = (j - 1) / segs * (opt.uScale or 1), j / segs * (opt.uScale or 1)
                local v1, v2 = (i - 1) / (m - 1), i / (m - 1)
                if p1[1] < 1e-6 then
                    tri(B, A, C, D, na1, nb2, na2, u1, v1, u2, v2, u1, v2)
                elseif p2[1] < 1e-6 then
                    tri(B, A, Bp, C, na1, nb1, nb2, u1, v1, u2, v1, u2, v2)
                else
                    quad(B, A, Bp, C, D, na1, nb1, nb2, na2, u1, v1, u2, v1, u2, v2, u1, v2)
                end
            end
        end
    end
end

--------------------------------------------------------------------------
-- 2D OUTLINES, extruded. `loop` is a list of {u, v}; the plate lies in the
-- plane through `o` spanned by `eu`, `ev`, from -t/2 to +t/2 along their
-- normal. Caps are ear-clipped, so the outline may be concave (a dropout's
-- axle slot). Sides are hard-edged unless `smooth`.
--------------------------------------------------------------------------
local function area2(loop)
    local a = 0
    for i = 1, #loop do
        local p, q = loop[i], loop[i % #loop + 1]
        a = a + p[1] * q[2] - q[1] * p[2]
    end
    return a * 0.5
end

local function earclip(loop)
    local idx = {}
    for i = 1, #loop do idx[i] = i end
    if area2(loop) < 0 then
        local r = {}
        for i = #idx, 1, -1 do r[#r + 1] = idx[i] end
        idx = r
    end
    local out = {}
    local function cr(a, b, c)
        return (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1])
    end
    local function inTri(p, a, b, c)
        return cr(a, b, p) >= 0 and cr(b, c, p) >= 0 and cr(c, a, p) >= 0
    end
    local guard = 0
    while #idx > 3 and guard < 10000 do
        guard = guard + 1
        local found = false
        for i = 1, #idx do
            local ia, ib, ic = idx[(i - 2) % #idx + 1], idx[i], idx[i % #idx + 1]
            local a, b, c = loop[ia], loop[ib], loop[ic]
            if cr(a, b, c) > 1e-12 then
                local ok = true
                for _, j in ipairs(idx) do
                    if j ~= ia and j ~= ib and j ~= ic and inTri(loop[j], a, b, c) then ok = false break end
                end
                if ok then
                    out[#out + 1] = { ia, ib, ic }
                    table.remove(idx, i)
                    found = true
                    break
                end
            end
        end
        if not found then break end
    end
    if #idx == 3 then out[#out + 1] = { idx[1], idx[2], idx[3] } end
    return out
end
G.earclip = earclip

local function plate(B, loop, o, eu, ev, t, opt)
    opt = opt or {}
    local en = norm(cross(eu, ev))
    local h = t * 0.5
    local function P(q, s) return add(o, add(add(mul(eu, q[1]), mul(ev, q[2])), mul(en, s))) end
    local tris = earclip(loop)
    for _, s in ipairs({ h, -h }) do
        local n = mul(en, s > 0 and 1 or -1)
        for _, tr in ipairs(tris) do
            local a, b, c = loop[tr[1]], loop[tr[2]], loop[tr[3]]
            tri(B, P(a, s), P(b, s), P(c, s), n, n, n, a[1], a[2], b[1], b[2], c[1], c[2])
        end
    end
    -- sides: outward normal of each edge in the plane
    local ccw = area2(loop) > 0
    local m = #loop
    local function edgeN(i)
        local p, q = loop[i], loop[i % m + 1]
        local du, dv = q[1] - p[1], q[2] - p[2]
        local nu, nv = dv, -du
        if not ccw then nu, nv = -nu, -nv end
        local l = sqrt(nu * nu + nv * nv)
        if l < 1e-12 then return { 0, 0, 0 } end
        return norm(add(mul(eu, nu / l), mul(ev, nv / l)))
    end
    local EN = {}
    for i = 1, m do EN[i] = edgeN(i) end
    for i = 1, m do
        local i2 = i % m + 1
        local na, nb = EN[i], EN[i]
        if opt.smooth then
            na = norm(add(EN[i], EN[(i - 2) % m + 1]))
            nb = norm(add(EN[i], EN[i2]))
        end
        local p, q = loop[i], loop[i2]
        quad(B, P(p, h), P(q, h), P(q, -h), P(p, -h), na, nb, nb, na)
    end
end

-- An annulus between two loops of equal count (outer, inner), extruded:
-- a chainring, a sprocket, a pedal body with its window.
local function ringPlate(B, outer, inner, o, eu, ev, t)
    local en = norm(cross(eu, ev))
    local h = t * 0.5
    local m = #outer
    local function P(q, s) return add(o, add(add(mul(eu, q[1]), mul(ev, q[2])), mul(en, s))) end
    for _, s in ipairs({ h, -h }) do
        local n = mul(en, s > 0 and 1 or -1)
        for i = 1, m do
            local i2 = i % m + 1
            quad(B, P(outer[i], s), P(outer[i2], s), P(inner[i2], s), P(inner[i], s), n, n, n, n)
        end
    end
    local function walls(loop, sign)
        local cu, cv = 0, 0
        for _, q in ipairs(loop) do cu, cv = cu + q[1], cv + q[2] end
        cu, cv = cu / m, cv / m
        for i = 1, m do
            local i2 = i % m + 1
            local p, q = loop[i], loop[i2]
            local mu, mv = (p[1] + q[1]) * 0.5 - cu, (p[2] + q[2]) * 0.5 - cv
            local du, dv = q[1] - p[1], q[2] - p[2]
            local nu, nv = dv, -du
            if nu * mu + nv * mv < 0 then nu, nv = -nu, -nv end
            nu, nv = nu * sign, nv * sign
            local n = norm(add(mul(eu, nu), mul(ev, nv)))
            quad(B, P(p, h), P(q, h), P(q, -h), P(p, -h), n, n, n, n)
        end
    end
    walls(outer, 1)
    walls(inner, -1)
end

-- A box from its centre and three half-extent vectors, flat-shaded.
local function box(B, c, ax, ay, az)
    local faces = {
        { ax, ay, az }, { mul(ax, -1), az, ay }, { ay, az, ax },
        { mul(ay, -1), ax, az }, { az, ax, ay }, { mul(az, -1), ay, ax },
    }
    for _, f in ipairs(faces) do
        local n = norm(f[1])
        local fc = add(c, f[1])
        local a = add(add(fc, f[2]), f[3])
        local b = add(sub(fc, f[2]), f[3])
        local cc = sub(sub(fc, f[2]), f[3])
        local d = add(sub(fc, f[3]), f[2])
        quad(B, a, b, cc, d, n, n, n, n, 0, 0, 1, 0, 1, 1, 0, 1)
    end
end

-- A rounded rectangle outline (w x h, corner radius r), `seg` points a corner.
local function roundRect(w, h, r, seg, cu, cv)
    cu, cv = cu or 0, cv or 0
    local out = {}
    local corners = { { w / 2 - r, h / 2 - r, 0 }, { -w / 2 + r, h / 2 - r, 0.25 },
                      { -w / 2 + r, -h / 2 + r, 0.5 }, { w / 2 - r, -h / 2 + r, 0.75 } }
    for _, c in ipairs(corners) do
        for i = 0, seg do
            local a = (c[3] + i / seg * 0.25) * TAU
            out[#out + 1] = { cu + c[1] + cos(a) * r, cv + c[2] + sin(a) * r }
        end
    end
    return out
end

-- A circle outline.
local function circle(r, n, cu, cv, a0)
    local out = {}
    for i = 0, n - 1 do
        local a = (a0 or 0) + i / n * TAU
        out[#out + 1] = { (cu or 0) + cos(a) * r, (cv or 0) + sin(a) * r }
    end
    return out
end

-- Points along a cubic Bezier.
local function bez3(a, b, c, d, n)
    local out = {}
    for i = 0, n do
        local t = i / n
        local u = 1 - t
        out[#out + 1] = add(add(mul(a, u * u * u), mul(b, 3 * u * u * t)),
                            add(mul(c, 3 * u * t * t), mul(d, t * t * t)))
    end
    return out
end

-- A smooth curve through the given points (Catmull-Rom), `n` steps a span.
local function spline(pts, n)
    local out = { pts[1] }
    for i = 1, #pts - 1 do
        local p0, p1, p2, p3 = pts[max(1, i - 1)], pts[i], pts[i + 1], pts[min(#pts, i + 2)]
        for s = 1, n do
            local t = s / n
            local t2, t3 = t * t, t * t * t
            local function c(k)
                return 0.5 * ((2 * p1[k]) + (-p0[k] + p2[k]) * t +
                    (2 * p0[k] - 5 * p1[k] + 4 * p2[k] - p3[k]) * t2 +
                    (-p0[k] + 3 * p1[k] - 3 * p2[k] + p3[k]) * t3)
            end
            out[#out + 1] = { c(1), c(2), c(3) }
        end
    end
    return out
end

-- A torus-ish weld bead where a tube meets another: a ring of radius `r`
-- about `axis` at `c`, `t` thick.
local function bead(B, c, axis, r, t, segs)
    local prof = {}
    for i = 0, 6 do
        local a = pi * (i / 6) - pi / 2
        prof[#prof + 1] = { r + cos(a) * t, sin(a) * t }
    end
    lathe(B, prof, c, axis, segs or 20)
end

G.prim = { sweep = sweep, lathe = lathe, plate = plate, ringPlate = ringPlate,
           box = box, roundRect = roundRect, circle = circle, bez3 = bez3,
           spline = spline, tri = tri, quad = quad, grid = grid, cap = cap }

--------------------------------------------------------------------------
-- THE DESIGN. Stock dimensions in inches. cl_init.lua's FRAME points are the
-- contract with the rest of the addon (the rider's seat, grips and pedals
-- are placed from them), so the model is built around exactly those.
--------------------------------------------------------------------------
G.FRAME = {
    bb     = V(-4.5, 0,  2.5),
    seatJ  = V(-9.5, 0, 14.0),
    seat   = V(-10.5, 0, 18.5),
    headT  = V(12.5, 0, 17.5),
    headB  = V(14.5, 0, 10.5),
    bars   = V(10.5, 0, 26.0),
    rear   = V(-19.5, 0, 0),
    front  = V(19.5, 0, 0),
}
G.CRANK, G.Q, G.CHAINY = 6.8, 3.4, -1.85  -- crank length, half pedal spacing, chainline
-- (the chainline is the model's own: inside the 110 mm dropouts, so the
-- chain loop goes round the drive-side chain stay as on a real bike)
G.GRIP_IN, G.GRIP_OUT = 11, 14.5          -- grip from/to, along the bar
G.RING_T, G.COG_T = 25, 9                 -- teeth
G.PITCH = 0.5                             -- chain pitch, inches

local function pitchRadius(n) return G.PITCH / (2 * sin(pi / n)) end
G.pitchRadius = pitchRadius

-- Where the fork, bar and cable parts sit, derived once from FRAME.
function G.Layout()
    local F = G.FRAME
    local L = {}
    L.steer = norm(sub(F.headT, F.headB))                    -- up the head tube
    -- The seat tube runs from the bottom bracket straight at the saddle; the
    -- top tube meets it at the point on that line nearest FRAME.seatJ.
    L.stDir = norm(sub(F.seat, F.bb))
    L.seatJ = add(F.bb, mul(L.stDir, dot(sub(F.seatJ, F.bb), L.stDir)))
    L.stTop = add(L.seatJ, mul(L.stDir, 1.3))                -- seat clamp
    L.htTop = add(F.headT, mul(L.steer, 0.45))
    L.htBot = sub(F.headB, mul(L.steer, 0.35))
    L.ttHead = sub(F.headT, mul(L.steer, 0.75))              -- where the top tube meets it
    L.dtHead = add(F.headB, mul(L.steer, 1.0))
    L.gyro = add(L.htTop, mul(L.steer, 0.45))                -- the detangler's plates
    L.stemBase = add(L.htTop, mul(L.steer, 0.9))
    L.stemTop = add(L.stemBase, mul(L.steer, 1.75))
    L.clamp = add(add(L.stemBase, mul(L.steer, 0.85)), V(1.5, 0, 0.15))   -- bar clamp centre
    -- U-brake bosses on the seat stays, where a pad reaches the rim.
    L.brakeT = 0.5
    return L
end

--------------------------------------------------------------------------
-- MATERIAL ROLES (cl_bikemesh.lua makes the real materials):
--   paint   the frame and fork, in the bike's palette colour
--   black   anodised / powder-coated black: bars, stem, cranks, rims, hubs
--   chrome  pegs, spokes, seat post, bolts
--   alloy   polished aluminium: sprockets, hub flanges, gyro
--   steel   the chain, cables' inner wire, pins
--   rubber  tread, grips
--   gum     the tyres' tan skinwall
--   seat    the saddle's cover
--   plastic pedal bodies, cable housing, brake pads
--   decal   the down tube's graphic (a texture drawn at runtime, alpha-tested)
--   tyretext the sidewall lettering (likewise)
--------------------------------------------------------------------------
G.ROLES = { "paint", "black", "chrome", "alloy", "steel", "rubber", "gum", "seat", "plastic", "decal", "tyretext" }

--------------------------------------------------------------------------
-- FRAME
--------------------------------------------------------------------------
-- The stays, as point lists, shared by the frame and the brake (whose bosses
-- sit on the seat stays). `s` = 1 left, -1 right.
function G.SeatStay(L, s)
    local axle = G.FRAME.rear
    local ss0 = add(L.seatJ, add(mul(L.stDir, -0.25), V(-0.35, 0.5 * s, 0)))
    local ss1 = add(axle, V(0.7, 2.06 * s, 0.85))
    return bez3(ss0, add(lerp(ss0, ss1, 0.33), V(0, 0.55 * s, 0)),
                add(lerp(ss0, ss1, 0.7), V(0, 0.2 * s, 0)), ss1, 16)
end

function G.ChainStay(s)
    local F = G.FRAME
    local cs0 = add(F.bb, V(-0.5, 1.0 * s, -0.05))
    local cs1 = add(F.rear, V(1.05, 2.06 * s, 0.2))
    return bez3(cs0, add(cs0, V(-3.5, 0.3 * s, -0.35)), add(cs1, V(4.5, -0.1 * s, 0.25)), cs1, 16)
end

local function dropoutRear()
    -- in (x, z) about the axle; the slot opens to the rear
    local loop = {}
    local function at(u, v) loop[#loop + 1] = { G.FRAME.rear[1] + u, G.FRAME.rear[3] + v } end
    at(-1.45, 0.29); at(0, 0.29)
    for i = 1, 7 do local a = pi / 2 - i / 8 * pi at(cos(a) * 0.29, sin(a) * 0.29) end
    at(0, -0.29); at(-1.45, -0.29)
    at(-1.45, -0.62); at(0.5, -0.85); at(1.45, -0.6); at(1.95, 0.1); at(1.75, 0.85)
    at(1.2, 1.4); at(0.4, 1.55); at(-0.4, 1.2); at(-1.2, 0.75)
    return loop
end

local function buildFrame(M, L, k)
    local F = G.FRAME
    local P = M:bucket("frame", "paint")
    local Pd = M:bucket("frame", "paint", true)

    -- Head tube: integrated, with the headset cups' flare at each end.
    do
        local h1 = len(sub(L.htTop, L.htBot))
        lathe(P, {
            { 0, -0.02, true }, { 0.86, 0, true }, { 0.90, 0.12 }, { 0.84, 0.5 },
            { 0.80, 1.2 }, { 0.80, h1 - 1.2 }, { 0.84, h1 - 0.5 }, { 0.90, h1 - 0.12 },
            { 0.86, h1, true }, { 0, h1 + 0.02, true },
        }, L.htBot, L.steer, 28)
    end
    -- Bottom bracket shell (mid BB, 68 mm) with its bearing faces.
    lathe(P, { { 0, -1.36, true }, { 0.92, -1.36, true }, { 0.96, -1.2 }, { 0.96, 1.2 },
               { 0.92, 1.36, true }, { 0, 1.36, true } }, F.bb, V(0, 1, 0), 28)

    -- Main tubes: chromoly; the butted ends are hidden in the joints.
    local tt0, tt1 = L.ttHead, L.seatJ
    local ttd = norm(sub(tt1, tt0))
    sweep(P, { tt0, tt1 }, 0.58, 20, { capStart = false, capEnd = false })
    local dt0 = L.dtHead
    local dtd = norm(sub(F.bb, dt0))
    sweep(P, { dt0, F.bb }, 0.70, 22, { capStart = false, capEnd = false })
    sweep(P, { F.bb, L.stTop }, 0.60, 20, { capStart = false })
    -- Seat clamp collar and its bolt.
    lathe(P, { { 0.61, -0.55, true }, { 0.70, -0.5 }, { 0.72, 0 }, { 0.70, 0.5 }, { 0.62, 0.55, true },
               { 0.5, 0.55, true } }, L.stTop, L.stDir, 22)
    local back = norm(cross(V(0, 1, 0), L.stDir))
    if back[1] > 0 then back = mul(back, -1) end
    lathe(M:bucket("frame", "chrome", true), { { 0, -0.5, true }, { 0.13, -0.5, true }, { 0.13, 0.5, true },
               { 0.2, 0.5, true }, { 0.2, 0.75, true }, { 0, 0.75, true } },
          add(L.stTop, mul(back, 0.82)), V(0, 1, 0), 6, { flat = true })

    -- TIG weld beads where a tube comes out of the one it is welded to.
    bead(Pd, add(tt0, mul(ttd, 0.95)), ttd, 0.6, 0.075)
    bead(Pd, add(dt0, mul(dtd, 0.98)), dtd, 0.72, 0.08)
    bead(Pd, add(tt1, mul(ttd, -0.66)), ttd, 0.6, 0.07)
    bead(Pd, add(F.bb, mul(L.stDir, 1.05)), L.stDir, 0.62, 0.07)
    bead(Pd, add(F.bb, mul(dtd, -1.1)), dtd, 0.72, 0.08)

    -- Gussets: a small concave plate under the top tube and one over the
    -- down tube, where each meets the head tube.
    local function gusset(tubeStart, tubeDir, r, side, along, drop)
        -- side: -1 under the tube, 1 over it (in the frame's x/z plane)
        local nrm = { -tubeDir[3], 0, tubeDir[1] }        -- perpendicular, in plane
        if nrm[3] < 0 then nrm = mul(nrm, -1) end
        nrm = mul(nrm, side)
        local a = add(add(tubeStart, mul(tubeDir, 0.6)), mul(nrm, r * 0.6))
        local b = add(add(tubeStart, mul(tubeDir, along)), mul(nrm, r * 0.75))
        local c = add(add(tubeStart, mul(L.steer, side * drop)), mul(tubeDir, 0.55))
        local ctrl = lerp(lerp(b, c, 0.5), a, 0.45)
        local pts = { { a[1], a[3] }, { b[1], b[3] } }
        for i = 1, 7 do
            local t = i / 8
            local u = 1 - t
            local q = add(add(mul(b, u * u), mul(ctrl, 2 * u * t)), mul(c, t * t))
            pts[#pts + 1] = { q[1], q[3] }
        end
        pts[#pts + 1] = { c[1], c[3] }
        plate(P, pts, V(0, 0, 0), V(1, 0, 0), V(0, 0, 1), 0.18, { smooth = true })
    end
    gusset(tt0, ttd, 0.58, -1, 2.6, 1.5)
    gusset(dt0, dtd, 0.70, 1, 2.4, 1.3)

    -- Chain stays and seat stays to the dropouts. Rear spacing 110 mm.
    local rear = dropoutRear()
    for _, s in ipairs({ 1, -1 }) do
        sweep(P, G.ChainStay(s), function(t) return 0.40 - 0.08 * t, 0.47 - 0.13 * t end, 16,
            { up = V(0, 0, 1), capStart = false })
        local ss = G.SeatStay(L, s)
        sweep(P, ss, function(t) return 0.36 - 0.07 * t end, 16, { capStart = false })
        -- dropout: a 6 mm plate
        plate(P, rear, V(0, 2.06 * s, 0), V(1, 0, 0), V(0, 0, 1), 0.24)
        -- U-brake boss on the seat stay, pointing back
        local i = floor(#ss * L.brakeT + 0.5)
        local bp = ss[i]
        local tdir = norm(sub(ss[i + 1], ss[i - 1]))
        local bpn = norm(cross(tdir, V(0, 1, 0)))
        if bpn[1] > 0 then bpn = mul(bpn, -1) end
        lathe(M:bucket("frame", "chrome", true), { { 0, 0, true }, { 0.2, 0, true }, { 0.2, 0.7, true },
                   { 0.12, 0.7, true }, { 0, 0.7, true } }, bp, bpn, 10)
    end
    -- The seat stays' bridge.
    do
        local l, r = G.SeatStay(L, 1), G.SeatStay(L, -1)
        local i = floor(#l * 0.3)
        sweep(P, { l[i], r[i] }, 0.26, 12, { capStart = false, capEnd = false })
    end
end

--------------------------------------------------------------------------
-- SEAT POST AND SADDLE (pivotal): part of the frame group.
--------------------------------------------------------------------------
local function buildSeat(M, L, k)
    local F = G.FRAME
    local C = M:bucket("frame", "chrome")
    local postTop = add(F.seat, V(0, 0, 0.35))
    sweep(C, { add(L.stTop, mul(L.stDir, -1.5)), postTop }, 0.50, 18, { capStart = false })
    -- the saddle: lofted cross-sections from tail to nose
    local SB = M:bucket("frame", "seat")
    local c = add(F.seat, V(-0.5, 0, 0.8))
    local stations = 15
    local P = {}
    local ring = 20
    for i = 0, stations do
        local t = i / stations             -- 0 tail, 1 nose
        local x = -4.6 + t * 9.6
        -- half width: broad rounded tail, narrowing to a slim nose
        local w = (t < 0.08) and (1.9 * sqrt(max(0, t / 0.08)) + 0.15) or
                  (2.05 - 1.15 * ((t - 0.08) / 0.92) ^ 1.3)
        if t > 0.94 then w = w * sqrt(max(0.05, (1 - t) / 0.06)) end
        w = max(w, 0.06)
        -- thickness: padded tail, thinner nose, nose kicked up
        local h = 1.25 - 0.45 * t
        local z0 = -0.1 + 0.35 * t * t
        if t < 0.04 or t > 0.96 then h = h * 0.4 end
        P[#P + 1] = {}
        for j = 0, ring - 1 do
            local a = j / ring * TAU
            local ca, sa = cos(a), sin(a)
            -- superellipse: flat-ish top, flat bottom
            local ex = 2.6
            local cy = (abs(ca) ^ (2 / ex)) * (ca < 0 and -1 or 1)
            local cz = (abs(sa) ^ (2 / ex)) * (sa < 0 and -1 or 1)
            local zz = cz > 0 and cz * h or cz * h * 0.35
            P[#P][j + 1] = add(c, V(x, cy * w, z0 + zz + (cz > 0 and 0.12 * (1 - cy * cy) * h or 0)))
        end
    end
    grid(SB, P, true, function(i)
        local s = { 0, 0, 0 }
        for _, p in ipairs(P[i]) do s = add(s, p) end
        return mul(s, 1 / #P[i])
    end)
    cap(SB, P[1], V(-1, 0, 0))
    cap(SB, P[#P], V(1, 0, 0))
    -- the pivotal clamp under it
    local B = M:bucket("frame", "black", true)
    box(B, add(postTop, V(0, 0, 0.18)), V(1.0, 0, 0), V(0, 0.55, 0), V(0, 0, 0.22))
end

--------------------------------------------------------------------------
-- REAR U-BRAKE: arms on the seat-stay bosses, pads on the rim's braking
-- track, the straddle cable and its yoke over the tyre.
--------------------------------------------------------------------------
local function buildBrake(M, L, R, k)
    local F = G.FRAME
    local B = M:bucket("frame", "black")
    local Pl = M:bucket("frame", "plastic")
    local St = M:bucket("frame", "steel", true)
    local axle = F.rear
    local tops = {}
    for _, s in ipairs({ 1, -1 }) do
        local ss = G.SeatStay(L, s)
        local i = floor(#ss * L.brakeT + 0.5)
        local boss = ss[i]
        local dir = norm(sub(V(boss[1], 0, boss[3]), axle))      -- out from the axle
        local pad = add(axle, mul(dir, R.rimOut - 0.4))
        pad[2] = (R.rimW * 0.5 + 0.2) * s
        local top = add(axle, mul(dir, R.outer + 0.9))
        top[2] = 0.4 * s
        local pivot = { boss[1], boss[2] - 0.25 * s, boss[3] }
        tops[s] = top
        local arm = spline({ add(pad, mul(dir, -0.5)), add(pad, V(0, 0.2 * s, 0)), pivot,
                             add(lerp(pivot, top, 0.5), V(0, 0.25 * s, 0)), top }, 5)
        sweep(B, arm, function() return 0.2, 0.13 end, 10, { up = V(0, 1, 0) })
        local tang = norm(cross(V(0, 1, 0), dir))
        box(Pl, pad, mul(tang, 0.62), V(0, 0.12, 0), mul(dir, 0.17))
    end
    local yoke = lerp(tops[1], tops[-1], 0.5)
    yoke = add(yoke, mul(norm(sub(yoke, axle)), 1.0))
    sweep(St, { tops[1], yoke }, 0.04, 6)
    sweep(St, { tops[-1], yoke }, 0.04, 6)
    box(B, yoke, V(0.15, 0, 0), V(0, 0.15, 0), V(0, 0, 0.15))
    return yoke
end

-- The cable housing from the gyro along the top tube to the brake yoke.
local function buildCableFrame(M, L, yoke)
    local F = G.FRAME
    local H = M:bucket("frame", "plastic", true)
    local ttd = norm(sub(L.seatJ, L.ttHead))
    local g = add(L.gyro, V(-0.9, 0.0, -0.25))
    local p1 = add(add(L.ttHead, mul(ttd, 1.4)), V(0, 0.55, 0.45))
    local p2 = add(add(L.ttHead, mul(ttd, 14)), V(0, 0.55, 0.45))
    local p3 = add(L.seatJ, V(-0.9, 0.55, 0.2))
    local p4 = lerp(p3, yoke, 0.55)
    p4 = add(p4, V(-0.4, 0.2, 0))
    local path = spline({ g, p1, p2, p3, p4, yoke }, 6)
    sweep(H, path, 0.1, 8)
    -- cable guides on the top tube
    local Pd = M:bucket("frame", "paint", true)
    for _, t in ipairs({ 4, 11 }) do
        local c = add(add(L.ttHead, mul(ttd, t)), V(0, 0.42, 0.38))
        box(Pd, c, mul(ttd, 0.3), V(0, 0.16, 0), V(0, 0, 0.12))
    end
    -- the gyro's lower plate (fixed to the frame)
    lathe(M:bucket("frame", "alloy", true), { { 0.95, -0.06, true }, { 1.55, -0.06, true }, { 1.6, 0 },
              { 1.55, 0.06, true }, { 0.95, 0.06, true } }, L.gyro, L.steer, 28)
end

--------------------------------------------------------------------------
-- FORK (steers about the head tube)
--------------------------------------------------------------------------
local function buildFork(M, L, R)
    local F = G.FRAME
    local P = M:bucket("fork", "paint")
    local axle = F.front
    -- steerer above and below the head tube, and the top cap
    local Bk = M:bucket("fork", "black")
    sweep(Bk, { L.htTop, L.stemBase }, 0.58, 20, { capStart = false })
    -- headset spacer stack and the gyro's upper rotor
    lathe(M:bucket("fork", "alloy", true), { { 0.6, 0, true }, { 1.25, 0, true }, { 1.3, 0.05 }, { 1.25, 0.1, true },
              { 0.6, 0.1, true } }, add(L.gyro, mul(L.steer, 0.12)), L.steer, 28)
    -- crown: an oval bar between the legs, below the head tube
    local crown = sub(L.htBot, mul(L.steer, 0.55))
    local fwd = norm(cross(V(0, 1, 0), L.steer))
    if fwd[1] < 0 then fwd = mul(fwd, -1) end
    local legTop = {}
    for _, s in ipairs({ 1, -1 }) do
        legTop[s] = add(add(crown, V(0, 1.72 * s, 0)), mul(fwd, 0.25))
    end
    local cpts = {}
    for i = 0, 10 do
        local t = i / 10
        local y = (t * 2 - 1) * 1.95
        cpts[#cpts + 1] = add(add(crown, V(0, y, 0)), mul(fwd, 0.25 - 0.2 * (1 - (y / 1.95) ^ 2)))
    end
    sweep(P, cpts, function(t)
        local e = abs(t * 2 - 1)
        return 0.62 + 0.1 * (1 - e * e), 0.55 + 0.15 * (1 - e * e)
    end, 18, { up = L.steer })
    -- legs: tapered, straight, offset forward at the dropouts
    for _, s in ipairs({ 1, -1 }) do
        local top = add(legTop[s], mul(L.steer, 0.45))
        local bot = add(axle, V(-0.25, 1.95 * s, 0.55))
        local pts = {}
        for i = 0, 12 do pts[#pts + 1] = lerp(top, bot, i / 12) end
        sweep(P, pts, function(t) return 0.56 - 0.17 * t end, 18, { capStart = true })
        -- dropout: a thick plate with the slot opening downward
        local loop = {}
        local function at(u, v) loop[#loop + 1] = { axle[1] + u, axle[3] + v } end
        at(0.27, -0.95); at(0.27, 0)
        for i = 1, 7 do local a = i / 8 * pi at(cos(a) * 0.27, sin(a) * 0.27) end
        at(-0.27, 0); at(-0.27, -0.95)
        at(-0.75, -0.7); at(-1.05, 0.2); at(-0.8, 1.0); at(-0.15, 1.3); at(0.55, 1.0); at(0.9, 0.2); at(0.75, -0.7)
        plate(P, loop, V(0, 1.95 * s, 0), V(1, 0, 0), V(0, 0, 1), 0.28)
    end
end

--------------------------------------------------------------------------
-- STEM, BARS, GRIPS, LEVER (turn with the fork; spin in a barspin)
--------------------------------------------------------------------------
local function barPath(L, side)
    -- one side, from the clamp centre out to the bar end: 9" rise, swept back
    local c = L.clamp
    local gx, gz = G.FRAME.bars[1], G.FRAME.bars[3]
    return {
        c,
        add(c, V(0, 1.6 * side, 0)),
        add(c, V(-0.05, 3.0 * side, 0.15)),
        add(c, V(-0.45, 4.4 * side, 1.7)),
        V(gx + 1.4, 6.6 * side, gz - 2.6),
        V(gx + 0.45, 8.6 * side, gz - 0.5),
        V(gx, 9.6 * side, gz),
        V(gx, (G.GRIP_OUT + 0.35) * side, gz),
    }
end

local function buildBars(M, L)
    local F = G.FRAME
    local Bk = M:bucket("bars", "black")
    local Bd = M:bucket("bars", "black", true)
    -- top-load stem: a body round the steerer and the bar clamp ahead of it
    local sb, st = L.stemBase, L.stemTop
    lathe(Bk, { { 0, 0, true }, { 0.98, 0, true }, { 1.02, 0.08 }, { 1.02, 1.67 }, { 0.98, 1.75, true },
                { 0, 1.75, true } }, sb, L.steer, 24)
    local fwd = norm(cross(V(0, 1, 0), L.steer))
    if fwd[1] < 0 then fwd = mul(fwd, -1) end
    local clamp = L.clamp
    -- the stem's sides, joining body and clamp
    for _, s in ipairs({ 1, -1 }) do
        local a = add(lerp(sb, st, 0.5), V(0, 0.8 * s, 0))
        local b = add(clamp, V(-0.2, 1.05 * s, 0))
        sweep(Bk, { add(a, mul(fwd, -0.3)), b }, function() return 0.62, 0.22 end, 12, { up = L.steer })
    end
    -- bar clamp: a short cylinder along y with the cap plate in front
    lathe(Bk, { { 0, -1.25, true }, { 0.70, -1.25, true }, { 0.74, -1.15 }, { 0.74, 1.15 },
                { 0.70, 1.25, true }, { 0, 1.25, true } }, clamp, V(0, 1, 0), 24)
    -- top cap and the four clamp bolts
    local C = M:bucket("bars", "chrome", true)
    lathe(Bk, { { 0, 0, true }, { 0.85, 0, true }, { 0.8, 0.12 }, { 0, 0.14, true } }, st, L.steer, 20)
    lathe(C, { { 0, 0, true }, { 0.25, 0, true }, { 0.25, 0.1 }, { 0, 0.11, true } }, add(st, mul(L.steer, 0.13)), L.steer, 6, { flat = true })
    for _, s in ipairs({ 1, -1 }) do
        for _, zz in ipairs({ 0.38, -0.38 }) do
            local p = add(add(clamp, mul(fwd, 0.74)), V(0, 0.85 * s, zz))
            lathe(C, { { 0, 0, true }, { 0.15, 0, true }, { 0.15, 0.12 }, { 0, 0.13, true } }, p, fwd, 6, { flat = true })
        end
    end
    -- the bars: one continuous 22.2 mm tube, left end to right end
    local left, right = barPath(L, 1), barPath(L, -1)
    local all = {}
    for i = #right, 2, -1 do all[#all + 1] = right[i] end
    for i = 1, #left do all[#all + 1] = left[i] end
    local path = spline(all, 7)
    sweep(Bk, path, 0.44, 16)
    -- crossbar between the risers
    local cb = {}
    for _, s in ipairs({ 1, -1 }) do
        local p = barPath(L, s)
        cb[s] = lerp(p[4], p[5], 0.6)
    end
    sweep(Bk, { cb[1], cb[-1] }, 0.37, 14, { capStart = false, capEnd = false })
    for _, s in ipairs({ 1, -1 }) do bead(Bd, add(cb[s], V(0, -0.5 * s, 0)), V(0, 1, 0), 0.4, 0.05, 14) end
    -- grips: ribbed rubber with a flange at the inside end and a bar-end plug
    local Rb = M:bucket("bars", "rubber")
    for _, s in ipairs({ 1, -1 }) do
        local o = V(F.bars[1], G.GRIP_IN * s - 0.15 * s, F.bars[3])
        local prof = { { 0.44, -0.1, true }, { 0.95, -0.1, true }, { 0.98, 0.0 }, { 0.95, 0.12, true }, { 0.66, 0.16, true } }
        local h = 0.16
        local gl = G.GRIP_OUT - G.GRIP_IN + 0.5
        while h < gl - 0.3 do
            prof[#prof + 1] = { 0.66, h + 0.04 }
            prof[#prof + 1] = { 0.71, h + 0.1 }
            prof[#prof + 1] = { 0.71, h + 0.2 }
            prof[#prof + 1] = { 0.66, h + 0.26 }
            h = h + 0.3
        end
        prof[#prof + 1] = { 0.70, gl - 0.15 }
        prof[#prof + 1] = { 0.62, gl, true }
        prof[#prof + 1] = { 0.30, gl + 0.03, true }
        prof[#prof + 1] = { 0, gl + 0.03, true }
        lathe(Rb, prof, o, V(0, s, 0), 24)
    end
    -- brake lever on the right: perch round the bar, blade along the grip
    do
        local s = -1
        local perch = V(F.bars[1], (G.GRIP_IN - 0.55) * s, F.bars[3])
        lathe(Bk, { { 0.48, -0.3, true }, { 0.62, -0.3, true }, { 0.62, 0.3, true }, { 0.48, 0.3, true } },
              perch, V(0, 1, 0), 18)
        local body = add(perch, V(0.75, 0, -0.1))
        sweep(Bk, { add(perch, V(0.4, 0, 0)), body, add(body, V(0.35, 0.1 * s, 0.05)) },
              function() return 0.3, 0.42 end, 12, { up = V(0, 0, 1) })
        local blade = spline({ add(body, V(0.3, 0, 0)), add(body, V(1.05, -0.3 * s, -0.25)),
                               V(F.bars[1] + 1.35, -12.6, F.bars[3] - 0.7), V(F.bars[1] + 1.1, -14.4, F.bars[3] - 0.85) }, 5)
        sweep(Bk, blade, function(t) return 0.13, 0.3 - 0.08 * t end, 10, { up = V(0, 0, 1) })
        -- barrel adjuster where the housing leaves the lever
        lathe(M:bucket("bars", "chrome", true), { { 0, 0, true }, { 0.16, 0, true }, { 0.16, 0.45 }, { 0.12, 0.5, true }, { 0, 0.5, true } },
              add(body, V(0.35, 0, 0.15)), V(0.25, 0.9, 0.3), 10)
    end
end

--------------------------------------------------------------------------
-- WHEELS (built about their own axle: x fwd, y left = axle, z up)
--------------------------------------------------------------------------
function G.WheelDims(radius)
    local s = radius / 10
    return {
        outer = radius,
        tyreW = 2.3 * s,                 -- 20 x 2.3
        bead  = 7.99 * s,                -- ISO 406 bead seat
        rimOut = 8.4 * s,                -- rim flange top
        rimIn  = 7.35 * s,               -- spoke bed
        rimW   = 1.25 * s,
        flangeR = 1.15 * s,              -- hub flange hole circle
        s = s,
    }
end

local function tyreProfile(R)
    -- the casing as an ellipse from bead to bead; returns points (r, y)
    local c = (R.outer + R.bead) * 0.5 + 0.05 * R.s
    local a = R.outer - c                -- radial semi-axis
    local b = R.tyreW * 0.5              -- lateral
    local pts = {}
    -- angle 0 = crown; +-a0 = where the casing meets the rim flange
    local a0 = pi * 0.83
    for i = 0, 40 do
        local t = -a0 + (i / 40) * 2 * a0
        pts[#pts + 1] = { c + cos(t) * a, sin(t) * b, t }
    end
    return pts, c, a, b
end

local function buildWheel(M, group, R, opt)
    local o = V(0, 0, 0)
    local Y = V(0, 1, 0)
    local segs = 72
    -- TYRE. Sidewalls tan (gum), crown black with a file tread of knobs.
    do
        local pts, c, a, b = tyreProfile(R)
        local crownLim = 0.62           -- |sin(t)| below this is tread
        local function part(lo, hi)
            local prof = {}
            for _, p in ipairs(pts) do
                if p[3] >= lo - 1e-9 and p[3] <= hi + 1e-9 then prof[#prof + 1] = { p[1], p[2] } end
            end
            return prof
        end
        local tl = math.asin(crownLim)
        local function laY(prof, mat)
            -- profile runs from -y to +y over the crown: normals out = +r
            lathe(M:bucket(group, mat), prof, o, Y, segs, { inward = false })
        end
        -- the lathe's normals face +r for a profile with increasing h; the
        -- casing goes over the top with h increasing, which is outward.
        laY(part(-pi, -tl), opt.wall or "gum")
        laY(part(-tl, tl), "rubber")
        laY(part(tl, pi), opt.wall or "gum")
        -- Sidewall lettering: a band just proud of each skinwall, its u
        -- round the tyre (mirrored on the right so it reads from outside),
        -- its v from the outer edge in. Role "tyretext".
        do
            local Tt = M:bucket(group, "tyretext", true)
            local t0, t1 = 1.0, 1.42
            local nv, nu = 4, 120
            for _, sd in ipairs({ 1, -1 }) do
                local ring = {}
                for iv = 0, nv do
                    local t = (t0 + (t1 - t0) * iv / nv) * sd
                    local r = c + cos(t) * a
                    local y = sin(t) * b
                    local nr, ny = cos(t) / a, sin(t) / b
                    local nl = sqrt(nr * nr + ny * ny)
                    nr, ny = nr / nl, ny / nl
                    ring[iv] = { r + nr * 0.012, y + ny * 0.012, nr, ny }
                end
                for iu = 0, nu - 1 do
                    local p1, p2 = iu / nu * TAU, (iu + 1) / nu * TAU
                    local u1, u2 = iu / nu, (iu + 1) / nu
                    if sd < 0 then u1, u2 = 1 - u1, 1 - u2 end
                    for iv = 0, nv - 1 do
                        local A, B2 = ring[iv], ring[iv + 1]
                        local function P(q, ph) return V(cos(ph) * q[1], q[2], sin(ph) * q[1]) end
                        local function N(q, ph) return norm(V(cos(ph) * q[3], q[4], sin(ph) * q[3])) end
                        local v1, v2 = iv / nv, (iv + 1) / nv
                        quad(Tt, P(A, p1), P(A, p2), P(B2, p2), P(B2, p1), N(A, p1), N(A, p2), N(B2, p2), N(B2, p1),
                            u1, v1, u2, v1, u2, v2, u1, v2)
                    end
                end
            end
        end
        -- bead lip, black, where tyre meets rim (listed so its normal faces out)
        for _, s in ipairs({ 1, -1 }) do
            local y0 = (R.rimW * 0.5 + 0.03) * s
            local prof = { { R.bead + 0.02, y0 + 0.06 * s }, { R.rimOut + 0.18, y0 + 0.1 * s }, { R.rimOut + 0.45, y0 + 0.24 * s } }
            if s > 0 then prof = { prof[3], prof[2], prof[1] } end
            lathe(M:bucket(group, "rubber"), prof, o, Y, segs)
        end
        -- tread: four staggered rows of low file blocks
        local K = M:bucket(group, "rubber", true)
        local rows = { -0.62, -0.21, 0.21, 0.62 }
        local n = floor(TAU * R.outer / 0.62)
        for ri, yf in ipairs(rows) do
            local y = yf * b
            local tt = math.asin(max(-1, min(1, y / b)))
            local rr = c + cos(tt) * a
            -- surface normal in (r, y) at this point
            local nr, ny = cos(tt) / a, sin(tt) / b
            local nl = sqrt(nr * nr + ny * ny)
            nr, ny = nr / nl, ny / nl
            for i = 0, n - 1 do
                local ang = (i + (ri % 2) * 0.5) / n * TAU
                local rad = V(cos(ang), 0, sin(ang))
                local tang = V(-sin(ang), 0, cos(ang))
                local nrm = norm(add(mul(rad, nr), V(0, ny, 0)))
                local base = add(mul(rad, rr - 0.02), V(0, y, 0))
                local h = 0.075 * R.s
                local side = norm(cross(nrm, tang))
                local skew = (yf < 0) and 0.12 or -0.12   -- chevron
                local ctr = add(base, mul(nrm, h * 0.5))
                box(K, ctr, add(mul(tang, 0.16 * R.s), mul(side, skew * 0.16)), mul(side, 0.17 * R.s), mul(nrm, h * 0.5))
            end
        end
    end
    -- RIM: double wall, black, with a machined braking track.
    do
        local Bk = M:bucket(group, opt.rim or "black")
        local w = R.rimW * 0.5
        lathe(Bk, {
            { R.bead - 0.05, -w + 0.12, true }, { R.rimOut, -w + 0.02, true }, { R.rimOut + 0.03, -w - 0.04 },
            { R.rimOut - 0.12, -w - 0.08, true }, { R.rimIn + 0.45, -w - 0.06 }, { R.rimIn + 0.12, -w + 0.05 },
            { R.rimIn - 0.02, -0.3 }, { R.rimIn - 0.06, 0 }, { R.rimIn - 0.02, 0.3 },
            { R.rimIn + 0.12, w - 0.05 }, { R.rimIn + 0.45, w + 0.06 }, { R.rimOut - 0.12, w + 0.08, true },
            { R.rimOut + 0.03, w + 0.04 }, { R.rimOut, w - 0.02, true }, { R.bead - 0.05, w - 0.12, true },
        }, o, Y, segs, { inward = true })
        -- the braking track: a bright band on each side wall
        local Al = M:bucket(group, "alloy")
        for _, s in ipairs({ 1, -1 }) do
            local yy = (w + 0.085) * s
            lathe(Al, s > 0 and { { R.rimOut - 0.14, yy }, { R.rimOut - 0.75, yy } }
                         or { { R.rimOut - 0.75, yy }, { R.rimOut - 0.14, yy } }, o, Y, segs)
        end
        -- valve stem
        local St = M:bucket(group, "steel", true)
        lathe(St, { { 0, 0, true }, { 0.12, 0, true }, { 0.12, 0.85 }, { 0.15, 0.9, true }, { 0.15, 1.2 }, { 0, 1.25, true } },
              V(0, 0, R.rimIn), V(0, 0, -1), 10)
    end
    -- HUB: shell with two flanges; the cog on the rear's drive side.
    local flY = opt.rear and { 1.05, -1.25 } or { 1.15, -1.15 }
    do
        local Al = M:bucket(group, "alloy")
        local h0, h1 = -1.55, 1.55
        local prof = {
            { 0.0, h0, true }, { 0.55, h0, true }, { 0.6, h0 + 0.1 },
            { 0.6, flY[2] - 0.12 }, { R.flangeR + 0.22, flY[2] - 0.08, true }, { R.flangeR + 0.25, flY[2] }, { R.flangeR + 0.22, flY[2] + 0.08, true },
            { 0.66, flY[2] + 0.14 }, { 0.62, 0 }, { 0.66, flY[1] - 0.14 },
            { R.flangeR + 0.22, flY[1] - 0.08, true }, { R.flangeR + 0.25, flY[1] }, { R.flangeR + 0.22, flY[1] + 0.08, true },
            { 0.6, flY[1] + 0.12 }, { 0.6, h1 - 0.1 }, { 0.55, h1, true }, { 0.0, h1, true },
        }
        lathe(Al, prof, o, Y, 28)
        if opt.rear then
            -- the driver and a 9-tooth cog on the chainline
            local Stl = M:bucket(group, "steel")
            local cy = G.CHAINY
            local pr = pitchRadius(G.COG_T)
            local outer, inner = {}, {}
            local n = G.COG_T
            for i = 0, n * 6 - 1 do
                local tf = (i % 6) / 6
                local a = (i / (n * 6)) * TAU
                local rr
                if tf < 0.15 or tf >= 0.85 then rr = pr + 0.16
                elseif tf < 0.35 or tf >= 0.65 then rr = pr + 0.02
                else rr = pr - 0.13 end
                outer[#outer + 1] = { cos(a) * rr, sin(a) * rr }
                inner[#inner + 1] = { cos(a) * 0.42, sin(a) * 0.42 }
            end
            ringPlate(Stl, outer, inner, V(0, cy, 0), V(1, 0, 0), V(0, 0, 1), 0.16)
            lathe(Stl, { { 0.45, -0.25, true }, { 0.55, -0.25, true }, { 0.55, 0.25, true }, { 0.45, 0.25, true } }, V(0, cy, 0), Y, 18)
            sweep(Stl, { V(0, -1.5, 0), V(0, cy - 0.1, 0) }, 0.5, 18)
        end
    end
    -- SPOKES: 36, three-cross, with nipples at the rim.
    do
        local C = M:bucket(group, "chrome", true)
        local N = 36
        local cross3 = 3 * 720 / N * pi / 180
        for i = 0, N - 1 do
            local ra = i / N * TAU
            local side = (i % 2 == 0) and 1 or -1
            local dir = ((floor(i / 2)) % 2 == 0) and 1 or -1
            local ha = ra + dir * cross3
            local fy = side > 0 and flY[1] or flY[2]
            local hub = V(cos(ha) * R.flangeR, fy + 0.05 * dir * side, sin(ha) * R.flangeR)
            local rim = V(cos(ra) * (R.rimIn + 0.05), 0.18 * side, sin(ra) * (R.rimIn + 0.05))
            sweep(C, { hub, rim }, 0.042, 5, { capStart = false, capEnd = false })
            local nd = norm(sub(rim, hub))
            sweep(C, { sub(rim, mul(nd, 0.35)), add(rim, mul(nd, 0.05)) }, 0.075, 6, { capStart = false })
        end
    end
end

-- The static parts on each axle: axle, nuts and pegs (fork or frame group).
local function buildAxleParts(M, group, axle, front)
    local C = M:bucket(group, "chrome")
    local Cd = M:bucket(group, "chrome", true)
    local Y = V(0, 1, 0)
    local half = front and 1.95 or 2.06
    sweep(M:bucket(group, "steel"), { add(axle, V(0, -half - 0.6, 0)), add(axle, V(0, half + 0.6, 0)) }, 0.27, 10)
    for _, s in ipairs({ 1, -1 }) do
        local base = half + 0.14
        -- axle nut
        lathe(Cd, { { 0.28, 0, true }, { 0.5, 0, true }, { 0.5, 0.32, true }, { 0.28, 0.32, true } },
              add(axle, V(0, base * s, 0)), mul(Y, s), 6, { flat = true })
        -- peg: 4.25" chromoly with a chamfer, knurl rings and a bored end
        local p0 = base + 0.3
        local L = 4.1
        local prof = { { 0.3, 0, true }, { 0.62, 0, true }, { 0.72, 0.1 }, { 0.74, 0.25, true } }
        local h = 0.45
        while h < L - 0.4 do
            prof[#prof + 1] = { 0.74, h, true }
            prof[#prof + 1] = { 0.71, h + 0.05, true }
            prof[#prof + 1] = { 0.71, h + 0.12, true }
            prof[#prof + 1] = { 0.74, h + 0.17, true }
            h = h + 0.55
        end
        prof[#prof + 1] = { 0.74, L - 0.12, true }
        prof[#prof + 1] = { 0.66, L, true }
        prof[#prof + 1] = { 0.48, L, true }
        prof[#prof + 1] = { 0.44, L - 0.5, true }
        prof[#prof + 1] = { 0.0, L - 0.5, true }
        lathe(C, prof, add(axle, V(0, p0 * s, 0)), mul(Y, s), 28)
    end
end

--------------------------------------------------------------------------
-- DRIVETRAIN: cranks (rotate about the BB), chainring, chain, pedals
--------------------------------------------------------------------------
local function toothLoop(n, pr, ptsPerTooth)
    local out = {}
    local m = ptsPerTooth or 8
    for i = 0, n * m - 1 do
        local tf = (i % m) / m
        local a = (i / (n * m)) * TAU
        -- a tooth: flat tip, flanks, round valley between rollers
        local rr
        if tf < 0.12 or tf >= 0.88 then rr = pr + 0.17
        elseif tf < 0.3 then rr = pr + 0.17 - (tf - 0.12) / 0.18 * 0.2
        elseif tf >= 0.7 then rr = pr - 0.03 + (tf - 0.7) / 0.18 * 0.2
        else rr = pr - 0.03 - sin((tf - 0.3) / 0.4 * pi) * 0.13 end
        out[#out + 1] = { cos(a) * rr, sin(a) * rr }
    end
    return out
end

local function buildCranks(M)
    local F = G.FRAME
    local bb = F.bb
    local Bk = M:bucket("cranks", "black")
    local Bd = M:bucket("cranks", "chrome", true)
    -- spindle (19 mm) between the arms
    sweep(M:bucket("cranks", "steel"), { add(bb, V(0, -2.5, 0)), add(bb, V(0, 2.5, 0)) }, 0.37, 16)
    for _, s in ipairs({ -1, 1 }) do          -- -1 = right (drive) arm: forward at angle 0
        local dir = (s == -1) and V(1, 0, 0) or V(-1, 0, 0)
        local root = V(bb[1], 2.35 * s, bb[3])
        local tip = add(V(bb[1], G.Q * s, bb[3]), mul(dir, G.CRANK))
        -- the arm: a lofted rounded section, tapering, with bosses at each end
        local P = {}
        local stations = 12
        for i = 0, stations do
            local t = i / stations
            local c = lerp(root, tip, t)
            local wv = 0.62 - 0.17 * t      -- across the arm, in its rotation plane
            local wy = 0.36 - 0.06 * t      -- its thickness along the spindle
            P[#P + 1] = {}
            for j = 0, 15 do
                local a = j / 16 * TAU
                local ca, sa = cos(a), sin(a)
                local e = 3.2
                local cu = (abs(ca) ^ (2 / e)) * (ca < 0 and -1 or 1)
                local cv = (abs(sa) ^ (2 / e)) * (sa < 0 and -1 or 1)
                P[#P][j + 1] = add(c, V(0, cu * wy, cv * wv))
            end
        end
        grid(Bk, P, true, function(i) return lerp(root, tip, (i - 1) / stations) end)
        lathe(Bk, { { 0, -0.42, true }, { 0.82, -0.42, true }, { 0.86, -0.3 }, { 0.86, 0.3 }, { 0.82, 0.42, true }, { 0, 0.42, true } },
              root, V(0, 1, 0), 22)
        lathe(Bk, { { 0, -0.36, true }, { 0.52, -0.36, true }, { 0.56, -0.25 }, { 0.56, 0.25 }, { 0.52, 0.36, true }, { 0, 0.36, true } },
              tip, V(0, 1, 0), 18)
        -- spindle bolt
        lathe(Bd, { { 0, 0, true }, { 0.3, 0, true }, { 0.3, 0.12 }, { 0, 0.14, true } },
              add(root, V(0, 0.42 * s, 0)), V(0, s, 0), 6, { flat = true })
    end
    -- chainring: 25 teeth, a solid sprocket with lightening holes' look
    local pr = pitchRadius(G.RING_T)
    local outer = toothLoop(G.RING_T, pr, 8)
    local inner = {}
    for i = 1, #outer do
        local a = (i - 1) / #outer * TAU
        inner[i] = { cos(a) * 0.62, sin(a) * 0.62 }
    end
    local cy = bb[2] + G.CHAINY
    local Al = M:bucket("cranks", "alloy")
    -- uv in the xz plane: eu = x, ev = z
    for i = 1, #outer do outer[i] = { outer[i][1] + bb[1], outer[i][2] + bb[3] } end
    for i = 1, #inner do inner[i] = { inner[i][1] + bb[1], inner[i][2] + bb[3] } end
    ringPlate(Al, outer, inner, V(0, cy, 0), V(1, 0, 0), V(0, 0, 1), 0.19)
    -- a raised boss ring and three windows' rims drawn as raised spokes
    lathe(Al, { { 0.62, -0.18, true }, { 1.05, -0.18, true }, { 1.1, -0.1 }, { 1.05, 0.18, true }, { 0.62, 0.18, true } },
          V(bb[1], cy, bb[3]), V(0, 1, 0), 24)
    lathe(Al, { { pr - 0.5, -0.15, true }, { pr - 0.28, -0.15, true }, { pr - 0.28, 0.15, true }, { pr - 0.5, 0.15, true } },
          V(bb[1], cy, bb[3]), V(0, 1, 0), 36)
    for i = 0, 2 do
        local a = i / 3 * TAU + 0.3
        local d = V(cos(a), 0, sin(a))
        box(Al, add(V(bb[1], cy, bb[3]), mul(d, (1.05 + pr - 0.5) * 0.5)), mul(d, (pr - 0.5 - 1.05) * 0.5 + 0.08),
            V(0, 0.15, 0), mul(V(-sin(a), 0, cos(a)), 0.22))
    end
    -- sprocket bolts
    for i = 0, 2 do
        local a = i / 3 * TAU + 0.3 + pi / 3
        local p = V(bb[1] + cos(a) * 0.85, cy - 0.2, bb[3] + sin(a) * 0.85)
        lathe(Bd, { { 0, 0, true }, { 0.13, 0, true }, { 0.13, 0.12 }, { 0, 0.13, true } }, p, V(0, -1, 0), 6, { flat = true })
    end
end

-- One pedal, about its own centre (x fwd, y out to the side, z up): a
-- nylon/alloy platform with a window, a spindle housing and 10 pins a side.
local function buildPedal(M)
    local B = M:bucket("pedal", "plastic")
    local Pin = M:bucket("pedal", "steel", true)
    local w, d, t = 4.0, 3.9, 0.62       -- along the spindle, front-back, thick
    local outer = roundRect(d, w, 0.45, 4)
    local inner = roundRect(d - 1.3, w - 1.3, 0.25, 4)
    -- plate in the x/y plane, normal z
    ringPlate(B, outer, inner, V(0, 0, 0), V(1, 0, 0), V(0, 1, 0), t)
    -- spindle housing through the middle, and a cross web
    sweep(B, { V(0, -w / 2 + 0.05, 0), V(0, w / 2 - 0.05, 0) }, function() return 0.32, 0.28 end, 14)
    box(B, V(0, 0, 0), V(0.12, 0, 0), V(0, w / 2 - 0.4, 0), V(0, 0, t * 0.42))
    -- pins on both faces round the edge
    local pins = {}
    for _, u in ipairs({ -d / 2 + 0.32, d / 2 - 0.32 }) do
        for _, v in ipairs({ -1.45, -0.5, 0.5, 1.45 }) do pins[#pins + 1] = { u, v } end
    end
    pins[#pins + 1] = { 0, -w / 2 + 0.32 }
    pins[#pins + 1] = { 0, w / 2 - 0.32 }
    for _, s in ipairs({ 1, -1 }) do
        for _, q in ipairs(pins) do
            lathe(Pin, { { 0, 0, true }, { 0.075, 0, true }, { 0.075, 0.2 }, { 0.05, 0.24, true }, { 0, 0.24, true } },
                  V(q[1], q[2], t / 2 * s), V(0, 0, s), 6)
        end
    end
end

-- The chain: link plates and rollers round the ring and the cog. Static,
-- in the frame group (a moving chain would need rebuilding every frame;
-- the sprockets turning in it read as drive well enough).
local function buildChain(M, R)
    local F = G.FRAME
    local St = M:bucket("frame", "steel", true)
    local y = F.bb[2] + G.CHAINY
    local c1 = { F.bb[1], F.bb[3] }
    local c2 = { F.rear[1], F.rear[3] }
    local r1, r2 = pitchRadius(G.RING_T), pitchRadius(G.COG_T)
    -- the loop as a dense 2D path: top run, round the cog, bottom run, round the ring
    local dx, dz = c2[1] - c1[1], c2[2] - c1[2]
    local D = sqrt(dx * dx + dz * dz)
    local base = math.atan2(dz, dx)
    local beta = math.acos((r1 - r2) / D)         -- external tangents
    local path = {}
    local function arc(c, r, a0, a1, n)
        for i = 0, n do
            local a = a0 + (a1 - a0) * i / n
            path[#path + 1] = { c[1] + cos(a) * r, c[2] + sin(a) * r }
        end
    end
    -- tangent points: angle base +- beta on each circle (same angles)
    local aTop, aBot = base + beta, base - beta
    -- top run from ring to cog, wrap the cog's far side, bottom run, wrap the ring's front
    arc(c1, r1, aBot + TAU, aTop, 40)            -- ring: front half, round to the top tangent
    arc(c2, r2, aTop, aBot, 20)                  -- cog: rear half
    -- close back to the start
    path[#path + 1] = path[1]
    -- resample by arc length into links
    local cum = { 0 }
    for i = 2, #path do
        cum[i] = cum[i - 1] + sqrt((path[i][1] - path[i - 1][1]) ^ 2 + (path[i][2] - path[i - 1][2]) ^ 2)
    end
    local total = cum[#cum]
    local nl = floor(total / G.PITCH / 2 + 0.5) * 2
    local pitch = total / nl
    local function at(s)
        s = s % total
        for i = 2, #cum do
            if cum[i] >= s then
                local t = (s - cum[i - 1]) / max(cum[i] - cum[i - 1], 1e-9)
                return { path[i - 1][1] + (path[i][1] - path[i - 1][1]) * t, path[i - 1][2] + (path[i][2] - path[i - 1][2]) * t }
            end
        end
        return path[1]
    end
    local pins = {}
    for i = 0, nl - 1 do pins[i] = at(i * pitch) end
    for i = 0, nl - 1 do
        local a, b = pins[i], pins[(i + 1) % nl]
        local du, dv = b[1] - a[1], b[2] - a[2]
        local l = sqrt(du * du + dv * dv)
        local eu = V(du / l, 0, dv / l)
        local ev = V(-dv / l, 0, du / l)
        local off = (i % 2 == 0) and 0.2 or 0.13      -- outer and inner links
        -- a waisted plate round both pins
        local loop = {}
        for j = 0, 6 do local t = -pi / 2 + j / 6 * pi loop[#loop + 1] = { l + cos(t) * 0.16, sin(t) * 0.16 } end
        loop[#loop + 1] = { l * 0.5, 0.12 }
        for j = 0, 6 do local t = pi / 2 + j / 6 * pi loop[#loop + 1] = { cos(t) * 0.16, sin(t) * 0.16 } end
        loop[#loop + 1] = { l * 0.5, -0.12 }
        for _, s in ipairs({ 1, -1 }) do
            plate(St, loop, V(a[1], y + off * s, a[2]), eu, ev, 0.05)
        end
        -- roller
        sweep(St, { V(a[1], y - 0.12, a[2]), V(a[1], y + 0.12, a[2]) }, 0.11, 6, { capStart = false, capEnd = false })
    end
end

--------------------------------------------------------------------------
-- DECALS: a graphic wrapped round each side of the down tube, a hair above
-- the paint. Role "decal" (cl_bikemesh.lua draws its texture at runtime).
-- u runs along the tube so the lettering reads back-to-front on the drive
-- side and front-to-back on the other, the way a rider sees each side.
--------------------------------------------------------------------------
local function buildDecals(M, L)
    local F = G.FRAME
    local D = M:bucket("frame", "decal")
    local a, b = L.dtHead, F.bb
    local dir = norm(sub(b, a))
    local r = 0.70 + 0.012
    local up = norm(sub(V(0, 0, 1), mul(dir, dir[3])))   -- the tube's own "up", in the frame plane
    local t0, t1 = 0.2, 0.8
    local ni, nj = 24, 10
    local arc = 0.95                                     -- radians each side of the side-facing line
    for _, s in ipairs({ 1, -1 }) do
        local side = V(0, s, 0)
        local P, N, U = {}, {}, {}
        for i = 0, ni do
            local t = t0 + (t1 - t0) * i / ni
            local c = lerp(a, b, t)
            P[i], N[i], U[i] = {}, {}, {}
            for j = 0, nj do
                local ang = (j / nj * 2 - 1) * arc
                local n = add(mul(side, cos(ang)), mul(up, sin(ang)))
                P[i][j] = add(c, mul(n, r))
                N[i][j] = n
                -- u along the tube: back-to-front on the right (s = -1)
                local u = (s == -1) and (1 - i / ni) or (i / ni)
                U[i][j] = { u, 1 - j / nj }
            end
        end
        for i = 0, ni - 1 do
            for j = 0, nj - 1 do
                quad(D, P[i][j], P[i + 1][j], P[i + 1][j + 1], P[i][j + 1],
                    N[i][j], N[i + 1][j], N[i + 1][j + 1], N[i][j + 1],
                    U[i][j][1], U[i][j][2], U[i + 1][j][1], U[i + 1][j][2],
                    U[i + 1][j + 1][1], U[i + 1][j + 1][2], U[i][j + 1][1], U[i][j + 1][2])
            end
        end
    end
end

--------------------------------------------------------------------------
-- BUILD. `opt` = { k = scale, radius = wheel radius in units (scaled),
-- wall = sidewall role }. Returns the model with groups and the layout the
-- drawing code needs (pivots, the cable's frame end), scaled.
--------------------------------------------------------------------------
local function scaleModel(M, k)
    if k == 1 then return end
    for _, name in ipairs(M.order) do
        for _, b in ipairs(M.groups[name]) do
            for _, vt in ipairs(b.v) do vt.p = mul(vt.p, k) end
        end
    end
end

function G.Build(opt)
    opt = opt or {}
    local k = opt.k or 1
    -- wheels are built at their own radius in design inches (radius / k)
    local radius = (opt.radius or 10 * k) / k
    local M = newModel()
    local L = G.Layout()
    local R = G.WheelDims(radius)
    buildFrame(M, L, k)
    buildDecals(M, L)
    buildSeat(M, L, k)
    local yoke = buildBrake(M, L, R, k)
    buildCableFrame(M, L, yoke)
    buildChain(M, R)
    buildAxleParts(M, "frame", G.FRAME.rear, false)
    buildFork(M, L, R)
    buildAxleParts(M, "fork", G.FRAME.front, true)
    buildBars(M, L)
    buildWheel(M, "wheelF", R, { wall = opt.wall })
    buildWheel(M, "wheelR", R, { rear = true, wall = opt.wall })
    buildCranks(M)
    buildPedal(M)
    scaleModel(M, k)
    -- Points the drawing code needs, in scaled design space.
    M.layout = {
        k = k, steer = L.steer, gyro = mul(L.gyro, k), stemTop = mul(L.stemTop, k),
        clamp = mul(L.clamp, k), yoke = mul(yoke, k),
        lever = mul(V(G.FRAME.bars[1] + 0.75 + 0.35, -(G.GRIP_IN - 0.55), G.FRAME.bars[3] + 0.05), k),
    }
    return M
end

-- A count of what was built, for tests and the debug overlay.
function G.Stats(M)
    local out, total = {}, 0
    for _, name in ipairs(M.order) do
        local n = 0
        for _, b in ipairs(M.groups[name]) do n = n + b.tris end
        out[name] = n
        total = total + n
    end
    out.total = total
    return out
end

return G
