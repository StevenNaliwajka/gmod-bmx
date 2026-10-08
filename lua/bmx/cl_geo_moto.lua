--[[--------------------------------------------------------------------------
    bmx/cl_geo_moto.lua

    The models of the e-moto, the dirt bike and the moped, built in code (docs/MODELS.md).
    Kinds: emoto, dirtbike, moped.

    These are MOTORBIKES, not bicycles: an engine or a battery and a motor, bodywork,
    long-travel suspension (a swingarm and a sliding fork, which DrawDetailed moves
    with the wheels), moto wheels with knobbies and discs, pegs for the feet. Each is
    built in REAL inches at its registry size: the dirt bike after a 250 four-stroke
    motocrosser (perimeter frame, finned head, radiators under louvred shrouds, a
    header curling round to a silencer up the right side, upside-down fork), the
    e-moto after a Sur-Ron / Talaria (twin-spar frame round a battery box, the motor
    at the swingarm pivot with its belt primary), the moped after a Piaggio Ciao
    (pressed-steel step-through, a 50 cc two-stroke with a belt variator, pedals to
    start it).

    The drive side is as on the real machines: the chain on the LEFT (+y) of the
    motorbikes, the rear disc on the right; the moped's belt on the left and its
    pedal chain on the right. Pure Lua, no game calls: the same code runs in the
    preview (tools/bike/export.lua) and the tests (tests/test_geo_moto.lua).
----------------------------------------------------------------------------]]

BMX = BMX or {}
local G = BMX.BikeGeo
if not G then return end

local vec = G.vec
local V, add, sub, mul, dot, cross = vec.V, vec.add, vec.sub, vec.mul, vec.dot, vec.cross
local len, norm, lerp, rot = vec.len, vec.norm, vec.lerp, vec.rot
local madd, perp = vec.madd, vec.perp
local Pm = G.prim
local sweep, lathe, plate, ringPlate, box = Pm.sweep, Pm.lathe, Pm.plate, Pm.ringPlate, Pm.box
local roundRect, circle, bez3, spline = Pm.roundRect, Pm.circle, Pm.bez3, Pm.spline
local tri, quad, grid, cap, bead = Pm.tri, Pm.quad, Pm.grid, Pm.cap, Pm.bead
local earclip, area2, newModel = Pm.earclip, Pm.area2, Pm.newModel

local sqrt, sin, cos, pi, abs = math.sqrt, math.sin, math.cos, math.pi, math.abs
local max, min, floor = math.max, math.min, math.floor
local TAU = pi * 2
local Y = V(0, 1, 0)
local Z = V(0, 0, 1)
local X = V(1, 0, 0)

--------------------------------------------------------------------------
-- SHAPES the bodywork needs beyond the BMX's tubes and plates.
--------------------------------------------------------------------------
local function sgnpow(x, p)
    local a = abs(x) ^ p
    return x < 0 and -a or a
end

-- A superellipse ring round `c` in the plane eu/ev, half sizes a (along eu) and b;
-- ex = 2 is an ellipse, higher is boxier.
local function ring(c, eu, ev, a, b, n, ex, phase)
    ex = ex or 2
    local out = {}
    for j = 0, n - 1 do
        local t = (phase or 0) + j / n * TAU
        out[j + 1] = add(c, add(mul(eu, sgnpow(cos(t), 2 / ex) * a), mul(ev, sgnpow(sin(t), 2 / ex) * b)))
    end
    return out
end

local function centroid(r)
    local c = { 0, 0, 0 }
    for _, p in ipairs(r) do c = add(c, p) end
    return mul(c, 1 / #r)
end

-- A closed shell lofted through rings of equal count (a tank, a seat, a battery
-- box), capped at each end unless told not to.
local function loft(B, R, opt)
    opt = opt or {}
    local C = {}
    for i = 1, #R do C[i] = centroid(R[i]) end
    grid(B, R, true, function(i) return C[i] end)
    if opt.capStart ~= false then cap(B, R[1], norm(sub(C[1], C[2]))) end
    if opt.capEnd ~= false then cap(B, R[#R], norm(sub(C[#R], C[#R - 1]))) end
end

-- Round off a loft's first rings into a dome `depth` deep (a pressed nose).
local function domeStart(R, depth)
    local c1, c2 = centroid(R[1]), centroid(R[2])
    local dir = norm(sub(c1, c2))
    local out = {}
    for _, deg in ipairs({ 80, 62, 42, 20 }) do
        local a = math.rad(deg)
        local r = {}
        for j, p in ipairs(R[1]) do r[j] = add(add(c1, mul(sub(p, c1), cos(a))), mul(dir, depth * sin(a))) end
        out[#out + 1] = r
    end
    for _, r in ipairs(R) do out[#out + 1] = r end
    return out
end

-- A THICK SHEET: a pressed or moulded panel (a fender, a shroud, a number plate).
-- f(u, v) gives the outer surface for u, v in 0..1; `out` (a vector, or a function
-- of the point) says which way the outer face looks; the sheet is `t` thick, its
-- inner face in `Bi` if given (a fender's underside), and its edges are closed.
local function sheet(B, ni, nj, f, t, out, Bi)
    local P, N = {}, {}
    for i = 0, ni do
        P[i + 1] = {}
        for j = 0, nj do P[i + 1][j + 1] = f(i / ni, j / nj) end
    end
    local I, J = ni + 1, nj + 1
    for i = 1, I do
        N[i] = {}
        for j = 1, J do
            local du = sub(P[min(I, i + 1)][j], P[max(1, i - 1)][j])
            local dv = sub(P[i][min(J, j + 1)], P[i][max(1, j - 1)])
            local n = norm(cross(du, dv))
            local o = type(out) == "function" and out(P[i][j], (i - 1) / ni, (j - 1) / nj) or out
            if dot(n, o) < 0 then n = mul(n, -1) end
            N[i][j] = n
        end
    end
    grid(B, P, false, nil, N)
    if t <= 0 then return P, N end
    local Q, NQ = {}, {}
    for i = 1, I do
        Q[i], NQ[i] = {}, {}
        for j = 1, J do
            Q[i][j] = madd(P[i][j], N[i][j], -t)
            NQ[i][j] = mul(N[i][j], -1)
        end
    end
    grid(Bi or B, Q, false, nil, NQ)
    local function rim(idx)
        local E = {}
        for k, q in ipairs(idx) do
            local e = sub(P[q[1]][q[2]], P[q[3]][q[4]])
            local n = N[q[1]][q[2]]
            E[k] = norm(sub(e, mul(n, dot(e, n))))
        end
        for k = 1, #idx - 1 do
            local a, b = idx[k], idx[k + 1]
            quad(B, P[a[1]][a[2]], P[b[1]][b[2]], Q[b[1]][b[2]], Q[a[1]][a[2]], E[k], E[k + 1], E[k + 1], E[k])
        end
    end
    local e1, e2, e3, e4 = {}, {}, {}, {}
    for i = 1, I do e1[i] = { i, 1, i, 2 }; e2[i] = { i, J, i, J - 1 } end
    for j = 1, J do e3[j] = { 1, j, 2, j }; e4[j] = { I, j, I - 1, j } end
    rim(e1); rim(e2); rim(e3); rim(e4)
    return P, N
end

-- A BEVELLED SLAB: a 2D outline {u, v} in the plane through o (eu, ev), extruded
-- `depth` along their normal with rounded `bev` edges. Cast covers, crankcases,
-- clamps, a caliper.
local function slab(B, loop, o, eu, ev, depth, bev)
    bev = bev or 0
    if bev <= 0 then return plate(B, loop, o, eu, ev, depth) end
    local m = #loop
    if area2(loop) < 0 then
        local r = {}
        for i = m, 1, -1 do r[#r + 1] = loop[i] end
        loop = r
    end
    local en = norm(cross(eu, ev))
    local vn = {}
    local function edgeN(a, b)
        local du, dv = b[1] - a[1], b[2] - a[2]
        local l = sqrt(du * du + dv * dv)
        if l < 1e-9 then return { 0, 0 } end
        return { dv / l, -du / l }
    end
    for i = 1, m do
        local p0, p1, p2 = loop[(i - 2) % m + 1], loop[i], loop[i % m + 1]
        local a, b = edgeN(p0, p1), edgeN(p1, p2)
        local nx, ny = a[1] + b[1], a[2] + b[2]
        local l = sqrt(nx * nx + ny * ny)
        if l < 1e-9 then nx, ny, l = a[1], a[2], 1 end
        nx, ny = nx / l, ny / l
        local c = max(0.35, nx * a[1] + ny * a[2])
        vn[i] = { nx, ny, 1 / c }
    end
    local h = depth * 0.5
    local function P(i, inset, w)
        local q, n = loop[i], vn[i]
        local d = inset and bev * n[3] or 0
        return add(o, add(add(mul(eu, q[1] - n[1] * d), mul(ev, q[2] - n[2] * d)), mul(en, w)))
    end
    local rings, NN = {}, {}
    local spec = { { true, -h, 0.55, -1 }, { false, -h + bev, 1, -0.3 }, { false, h - bev, 1, 0.3 }, { true, h, 0.55, 1 } }
    for k, sp in ipairs(spec) do
        rings[k], NN[k] = {}, {}
        for i = 1, m do
            rings[k][i] = P(i, sp[1], sp[2])
            local n2 = add(mul(eu, vn[i][1]), mul(ev, vn[i][2]))
            NN[k][i] = norm(add(mul(n2, sp[3]), mul(en, sp[4])))
        end
    end
    grid(B, rings, true, nil, NN)
    local inset = {}
    for i = 1, m do
        local q, n = loop[i], vn[i]
        inset[i] = { q[1] - n[1] * bev * n[3], q[2] - n[2] * bev * n[3] }
    end
    local tris = earclip(inset)
    for _, w in ipairs({ h, -h }) do
        local n = mul(en, w > 0 and 1 or -1)
        for _, tr in ipairs(tris) do
            local a, b, c = tr[1], tr[2], tr[3]
            tri(B, rings[w > 0 and 4 or 1][a], rings[w > 0 and 4 or 1][b], rings[w > 0 and 4 or 1][c], n, n, n)
        end
    end
end

-- A hex bolt head (or nut) at p, looking along axis.
local function bolt(B, p, axis, r, h)
    r, h = r or 0.18, h or 0.14
    lathe(B, { { 0, 0, true }, { r, 0, true }, { r, h * 0.8 }, { r * 0.7, h, true }, { 0, h, true } }, p, axis, 6, { flat = true })
end

-- A tube through the given points, smoothed.
local function tube(B, pts, r, sides, n, opt)
    local path = (#pts > 2) and spline(pts, n or 5) or pts
    return sweep(B, path, r, sides or 12, opt)
end

-- Copy a group of one model into another, mirrored left to right (y -> -y).
local function mirrorInto(M, Mx, from, to)
    for _, b in ipairs(Mx.groups[from] or {}) do
        local d = M:bucket(to, b.mat, b.detail)
        local t = d.v
        for i = 1, #b.v, 3 do
            local a, c, e = b.v[i], b.v[i + 1], b.v[i + 2]
            local function m(vt)
                return { p = { vt.p[1], -vt.p[2], vt.p[3] }, n = { vt.n[1], -vt.n[2], vt.n[3] }, u = vt.u, v = vt.v }
            end
            t[#t + 1] = m(a); t[#t + 1] = m(e); t[#t + 1] = m(c)
            d.tris = d.tris + 1
        end
    end
end

-- Every group but the wheels by f (the model is designed at its registry size).
local function scaleGroups(M, f)
    if abs(f - 1) < 1e-9 then return end
    for _, name in ipairs(M.order) do
        if name ~= "wheelF" and name ~= "wheelR" then
            for _, b in ipairs(M.groups[name]) do
                for _, vt in ipairs(b.v) do vt.p = mul(vt.p, f) end
            end
        end
    end
end

-- Drop buckets nothing went into (a role asked for but unused).
local function pruneEmpty(M)
    local order = {}
    for _, name in ipairs(M.order) do
        local g, keep = M.groups[name], {}
        for _, b in ipairs(g) do if b.tris > 0 then keep[#keep + 1] = b end end
        if #keep > 0 then
            M.groups[name] = keep
            order[#order + 1] = name
        else
            M.groups[name] = nil
        end
    end
    M.order = order
end

local function scaleLayout(t, f)
    if abs(f - 1) < 1e-9 then return t end
    local out = {}
    for k, v in pairs(t) do
        if type(v) == "table" and type(v[1]) == "number" and #v == 3 and k ~= "steer" then
            out[k] = mul(v, f)
        elseif type(v) == "table" and type(v[1]) ~= "number" then
            out[k] = scaleLayout(v, f)
        elseif type(v) == "number" and (k == "forkSlide" or k == "crank" or k == "pedalY" or k == "r") then
            out[k] = v * f
        else
            out[k] = v
        end
    end
    return out
end

-- A SPROCKET in the x/z plane at (cx, y, cz): n teeth on the chain's pitch, a web
-- inside with `arms` spokes to a boss (arms = 0: a solid disc to rIn).
local function sprocket(B, Bd, n, pitch, cx, y, cz, t, rIn, arms, rBoss)
    local pr = pitch / (2 * sin(pi / n))
    local outer = G.parts.toothLoop(n, pr, n > 30 and 5 or 7)
    local inner = {}
    local ring0 = rIn or (pr - 0.75)
    for i = 1, #outer do
        local a = (i - 1) / #outer * TAU
        inner[i] = { cx + cos(a) * ring0, cz + sin(a) * ring0 }
        outer[i] = { outer[i][1] + cx, outer[i][2] + cz }
    end
    ringPlate(B, outer, inner, V(0, y, 0), X, Z, t)
    if arms and arms > 0 then
        local rb = rBoss or 1.4
        lathe(B, { { rb - 0.45, -t * 0.6, true }, { rb, -t * 0.6, true }, { rb, t * 0.6, true }, { rb - 0.45, t * 0.6, true } },
              V(cx, y, cz), Y, 24)
        for i = 0, arms - 1 do
            local a = i / arms * TAU + 0.2
            local d = V(cos(a), 0, sin(a))
            local tg = V(-sin(a), 0, cos(a))
            local r0, r1 = rb - 0.1, ring0 + 0.1
            box(B, add(V(cx, y, cz), mul(d, (r0 + r1) * 0.5)), mul(d, (r1 - r0) * 0.5), V(0, t * 0.45, 0), mul(tg, 0.42))
            if Bd then bolt(Bd, add(V(cx, y + t * 0.5, cz), mul(d, rb - 0.22)), Y, 0.16, 0.12) end
        end
    end
    return pr
end

-- A ROLLER CHAIN round two sprockets in the x/z plane at y: c1 = {x, z} the
-- front (countershaft) one, c2 the rear; link plates and rollers.
local function chainLoop(B, c1, r1, c2, r2, y, pitch)
    local dx, dz = c2[1] - c1[1], c2[2] - c1[2]
    local D = sqrt(dx * dx + dz * dz)
    local base = math.atan2(dz, dx)
    local beta = math.acos(max(-1, min(1, (r1 - r2) / D)))
    local path = {}
    local function arc(c, r, a0, a1, n)
        for i = 0, n do
            local a = a0 + (a1 - a0) * i / n
            path[#path + 1] = { c[1] + cos(a) * r, c[2] + sin(a) * r }
        end
    end
    local aTop, aBot = base + beta, base - beta
    arc(c1, r1, aBot + TAU, aTop, 24)
    arc(c2, r2, aTop, aBot, 40)
    path[#path + 1] = path[1]
    local cum = { 0 }
    for i = 2, #path do
        cum[i] = cum[i - 1] + sqrt((path[i][1] - path[i - 1][1]) ^ 2 + (path[i][2] - path[i - 1][2]) ^ 2)
    end
    local total = cum[#cum]
    local nl = floor(total / pitch / 2 + 0.5) * 2
    local p = total / nl
    local k = 2
    local function at(s)
        while k < #cum and cum[k] < s do k = k + 1 end
        local t = (s - cum[k - 1]) / max(cum[k] - cum[k - 1], 1e-9)
        return { path[k - 1][1] + (path[k][1] - path[k - 1][1]) * t, path[k - 1][2] + (path[k][2] - path[k - 1][2]) * t }
    end
    local pins = {}
    for i = 0, nl - 1 do pins[i] = at(i * p) end
    local rr = pitch * 0.3
    for i = 0, nl - 1 do
        local a, b = pins[i], pins[(i + 1) % nl]
        local du, dv = b[1] - a[1], b[2] - a[2]
        local l = sqrt(du * du + dv * dv)
        local eu = V(du / l, 0, dv / l)
        local ev = V(-dv / l, 0, du / l)
        local off = (i % 2 == 0) and pitch * 0.42 or pitch * 0.27
        local hw = pitch * 0.3
        local loop = { { -hw, 0 }, { 0, -hw }, { l * 0.5, -hw * 0.72 }, { l, -hw }, { l + hw, 0 },
                       { l, hw }, { l * 0.5, hw * 0.72 }, { 0, hw } }
        for _, sd in ipairs({ 1, -1 }) do
            plate(B, loop, V(a[1], y + off * sd, a[2]), eu, ev, pitch * 0.09)
        end
        sweep(B, { V(a[1], y - off, a[2]), V(a[1], y + off, a[2]) }, rr, 5, { capStart = false, capEnd = false })
    end
end

-- A moto grip from A outward along dir: waffle rubber with a flange, len long.
local function motoGrip(B, A, dir, l, r)
    r = r or 0.62
    local prof = { { 0.42, -0.15, true }, { r + 0.32, -0.15, true }, { r + 0.34, 0.0 }, { r + 0.3, 0.14, true }, { r, 0.2, true } }
    local h = 0.25
    while h < l - 0.4 do
        prof[#prof + 1] = { r, h + 0.03 }
        prof[#prof + 1] = { r + 0.07, h + 0.09 }
        prof[#prof + 1] = { r + 0.07, h + 0.2 }
        prof[#prof + 1] = { r, h + 0.26 }
        h = h + 0.42
    end
    prof[#prof + 1] = { r + 0.05, l - 0.18 }
    prof[#prof + 1] = { r - 0.05, l, true }
    prof[#prof + 1] = { 0.3, l + 0.02, true }
    prof[#prof + 1] = { 0, l + 0.02, true }
    lathe(B, prof, A, dir, 16)
end

-- A hand lever: a perch clamped round the bar at `at`, its blade reaching out
-- along `out` in front of the grip; `fwd` is forward and down for the blade.
local function handLever(Bk, Bl, at, out, fwd, reach, perchR)
    perchR = perchR or 0.5
    lathe(Bk, { { perchR - 0.05, -0.35, true }, { perchR + 0.2, -0.35, true }, { perchR + 0.22, 0 },
                { perchR + 0.2, 0.35, true }, { perchR - 0.05, 0.35, true } }, at, out, 16)
    local body = madd(at, fwd, perchR + 0.55)
    sweep(Bk, { madd(at, fwd, perchR * 0.6), body }, function() return 0.36, 0.3 end, 10, { up = out })
    local tipD = norm(add(mul(out, 1), mul(fwd, 0.18)))
    local blade = spline({ body, add(madd(body, out, 0.8), mul(fwd, 0.55)), add(madd(body, tipD, reach * 0.6), mul(fwd, 0.6)),
                           add(madd(body, tipD, reach), mul(fwd, 0.25)) }, 5)
    sweep(Bl, blade, function(t) return 0.3 - 0.06 * t, 0.12 end, 10, { up = Z })
    lathe(Bl, { { 0, -0.15, true }, { 0.18, -0.15, true }, { 0.18, 0.15, true }, { 0, 0.15, true } }, blade[#blade], norm(sub(blade[#blade], blade[#blade - 1])), 10)
    return body
end

-- A SERRATED FOOTPEG: a steel platform, top centre at `c`, from y0 out to y1 (signs
-- give the side), `w` front to back, teeth along its edges and two inner bars.
local function footpeg(B, Bd, c, y0, y1, w)
    local s = (y1 > y0) and 1 or -1
    local L = abs(y1 - y0)
    local ym = (y0 + y1) * 0.5
    local top = c[3]
    -- the hinge at the inner end, and a spring
    lathe(B, { { 0, -0.6, true }, { 0.36, -0.6, true }, { 0.36, 0.6, true }, { 0, 0.6, true } }, V(c[1], y0, top - 0.45), X, 12)
    for _, xo in ipairs({ -w * 0.5, w * 0.5 }) do
        -- a side rail with teeth
        box(B, V(c[1] + xo * 0.88, ym, top - 0.35), V(0.13, 0, 0), V(0, L * 0.5, 0), V(0, 0, 0.27))
        local nT = 7
        for i = 0, nT - 1 do
            local yy = y0 + s * (0.25 + (L - 0.5) * (i + 0.5) / nT)
            local tp = V(c[1] + xo * 0.88, yy, top - 0.02)
            lathe(Bd, { { 0.13, -0.08, true }, { 0.13, 0.02 }, { 0.02, 0.1, true }, { 0, 0.1, true } }, sub(tp, V(0, 0, 0.0)), Z, 4)
        end
    end
    for _, xo in ipairs({ -w * 0.17, w * 0.17 }) do
        box(B, V(c[1] + xo, ym, top - 0.38), V(0.08, 0, 0), V(0, L * 0.5 - 0.2, 0), V(0, 0, 0.26))
        for i = 0, 4 do
            local yy = y0 + s * (0.4 + (L - 0.8) * (i + 0.5) / 5)
            box(Bd, V(c[1] + xo, yy, top - 0.07), V(0.08, 0, 0), V(0, 0.07, 0), V(0, 0, 0.07))
        end
    end
    -- the cross webs and the outer end
    for i = 0, 3 do
        local yy = y0 + s * (0.2 + (L - 0.4) * i / 3)
        box(B, V(c[1], yy, top - 0.4), V(w * 0.45, 0, 0), V(0, 0.08, 0), V(0, 0, 0.22))
    end
end

-- A disc caliper: a two-part cast body straddling a rotor at y = dy, centred on
-- `c` (a point on the rotor's pad track), its long side along `tg`.
local function caliper(B, Bd, c, tg, dy, inner, outer)
    local up = norm(cross(tg, Y))
    local o1 = V(c[1], dy + 0.05 + outer * 0.5, c[3])
    local o2 = V(c[1], dy - 0.05 - inner * 0.5, c[3])
    local loop = roundRect(2.6, 1.15, 0.45, 3)
    slab(B, loop, o1, tg, up, outer, 0.16)
    slab(B, loop, o2, tg, up, inner, 0.14)
    -- the bridge over the rotor's edge
    box(B, add(V(c[1], dy, c[3]), mul(up, 0.55)), mul(tg, 1.1), V(0, (inner + outer) * 0.5 + 0.06, 0), mul(up, 0.22))
    for _, a in ipairs({ -0.8, 0.8 }) do
        bolt(Bd, add(madd(o1, tg, a), V(0, outer * 0.5, 0)), Y, 0.17, 0.12)
    end
end

-- A moto wheel about its own axle: the shared wheel with the tread's knobs standing
-- to `radius` (the casing below them), mirrored when the disc goes on the right.
local function motoWheel(M, group, radius, o)
    local knob = o.knob or 0.72
    local rc = radius - knob * 0.62 + 0.03
    local dims = G.WheelDims(rc, { width = o.width, height = o.height, rimDepth = o.rimDepth, rimW = o.rimW, flangeR = o.flangeR })
    local wopt = { tread = o.tread or "knobby", knob = knob, wall = "rubber", rim = o.rim or "black", spokes = o.spokes or 36,
                   cross = o.cross or 3, spokeR = o.spokeR or 0.08, hubHalf = o.hubHalf, hubShell = o.hubShell,
                   hubRole = o.hubRole or "alloy", disc = o.disc, mag = o.mag }
    if o.mirror then
        local Mx = newModel()
        G.parts.wheel(Mx, "w", dims, wopt)
        mirrorInto(M, Mx, "w", group)
    else
        G.parts.wheel(M, group, dims, wopt)
    end
    return dims
end

--------------------------------------------------------------------------
-- THE FOOTPEGS, as data: each motorbike's left peg's top centre at the size it is
-- designed at (`wb`), the right one its mirror. Here and not inside the builders
-- because the stand-in drawing (entities/bmx_base/cl_init.lua, while a model is still
-- building or with bmx_bike_model 0) puts its pegs, and the rider's feet, at exactly
-- these points without building anything.
--------------------------------------------------------------------------
G.Pegs = {
    dirtbike = { wb = 58, at = { -6.7, 6.4, 3.7 } },
    emoto    = { wb = 48, at = { -5.5, 6.0, 3.1 } },
}

-- A kind's pegs at wheelbase `wb`, model space, { r = {x,y,z}, l = {x,y,z} }; nil for
-- a kind without them.
function G.PegsFor(kind, wb)
    local p = G.Pegs[kind]
    if not p then return nil end
    local f = (wb or p.wb) / p.wb
    local a = p.at
    return { r = { a[1] * f, -a[2] * f, a[3] * f }, l = { a[1] * f, a[2] * f, a[3] * f } }
end

--------------------------------------------------------------------------
-- THE DIRT BIKE: a 250 four-stroke motocrosser. Designed at wheelbase 58 on
-- 14-radius wheels (a 21-inch front), x forward, y left, z up, axles on z = 0.
--------------------------------------------------------------------------
local function buildDirt(opt)
    local wb = opt.wheelbase or 58
    local f = wb / 58
    local Rw = opt.radius or 14
    local S = opt.seat or { -14.9, 0, 25.5 }
    local Sx, Sz = S[1] / f, S[3] / f
    local M = newModel()

    local RA, FA = V(-29, 0, 0), V(29, 0, 0)
    local st = norm(V(-0.446, 0, 0.895))          -- 26.5 degrees of rake
    local fw = V(st[3], 0, -st[1])                -- forward, square to the steer axis
    local OFF, LEGY = 1.2, 4.1                    -- fork offset, legs' half spacing
    local function SP(t) return add(madd(FA, fw, -OFF), mul(st, t)) end
    local function LP(t, sd) return add(madd(FA, st, t), V(0, sd * LEGY, 0)) end

    local Pf = M:bucket("frame", "paint")
    local Pfd = M:bucket("frame", "paint", true)
    local Bk = M:bucket("frame", "black")
    local Bkd = M:bucket("frame", "black", true)
    local Al = M:bucket("frame", "alloy")
    local Ald = M:bucket("frame", "alloy", true)
    local Wh = M:bucket("frame", "white")
    local Ch = M:bucket("frame", "chrome")
    local Chd = M:bucket("frame", "chrome", true)
    local St = M:bucket("frame", "steel")
    local Std = M:bucket("frame", "steel", true)
    local Rb = M:bucket("frame", "rubber")
    local Pl = M:bucket("frame", "plastic")

    ----------------------------------------------------------------------
    -- FRAME: a twin-spar steel perimeter frame, the spars running from the head
    -- round the back of the engine (the swingarm pivot through them) into the
    -- cradle rails under it, which meet the single down tube.
    ----------------------------------------------------------------------
    local hb, ht = SP(22.9), SP(31.9)
    lathe(Pf, { { 0, -0.02, true }, { 1.0, 0, true }, { 1.12, 0.15 }, { 1.05, 0.6 }, { 1.0, 1.2 }, { 1.0, 7.8 },
                { 1.05, 8.4 }, { 1.12, 8.85 }, { 1.0, 9.0, true }, { 0, 9.02, true } }, hb, st, 28)
    local PIV = V(-5.0, 0, 6.5)
    for _, sd in ipairs({ 1, -1 }) do
        local pts = {
            V(14.7, 0.7 * sd, 25.3), V(11.6, 3.0 * sd, 24.3), V(6.0, 4.45 * sd, 22.8), V(0.0, 4.75 * sd, 21.1),
            V(-4.3, 4.75 * sd, 19.2), V(-6.3, 4.65 * sd, 16.0), V(-6.3, 4.6 * sd, 11.2), V(-5.3, 4.55 * sd, 7.4),
            V(-4.9, 4.45 * sd, 3.6), V(-3.6, 3.8 * sd, 0.5), V(-1.2, 3.25 * sd, -0.55), V(3.5, 3.15 * sd, -0.75),
            V(8.6, 3.0 * sd, -0.3), V(11.7, 2.3 * sd, 2.8), V(13.4, 1.0 * sd, 7.6), V(13.75, 0.3 * sd, 9.3),
        }
        local path = spline(pts, 3)
        sweep(Pf, path, function(t)
            if t < 0.35 then return 0.95 - 0.5 * t, 0.5 end
            return 0.6, 0.5
        end, 14, { up = Z })
        -- the pivot boss through the spar, and the footpeg mount below it
        lathe(Pf, { { 0, -0.75, true }, { 1.05, -0.75, true }, { 1.15, -0.6 }, { 1.15, 0.6 }, { 1.05, 0.75, true }, { 0, 0.75, true } },
              V(PIV[1], 4.6 * sd, PIV[3]), Y, 22)
        bolt(Std, V(PIV[1], 5.35 * sd, PIV[3]), mul(Y, sd), 0.45, 0.32)
        -- gusset plates where the spar turns down behind the engine
        plate(Pf, { { -6.9, 17.5 }, { -3.6, 19.6 }, { -4.8, 15.5 }, { -5.6, 13.5 } }, V(0, 4.6 * sd, 0), X, Z, 0.28)
        plate(Pf, { { -5.9, 9.0 }, { -4.6, 9.0 }, { -4.2, 4.8 }, { -5.3, 2.6 }, { -6.2, 4.5 } }, V(0, 4.55 * sd, 0), X, Z, 0.3)
    end
    -- the down tube and its cast junction with the cradle
    local dtA, dtB = add(SP(24.8), V(-0.45, 0, -0.2)), V(13.7, 0, 9.4)
    tube(Pf, { dtA, V(15.4, 0, 16.0), dtB }, function() return 0.78, 0.95 end, 16, 5, { up = Y })
    lathe(Pf, { { 0, -1.3, true }, { 0.9, -1.3 }, { 1.25, -0.6 }, { 1.3, 0 }, { 1.25, 0.6 }, { 0.9, 1.3 }, { 0, 1.35, true } },
          V(13.75, 0, 9.0), Y, 18)
    -- head gussets: plates from the head tube under the spars and along the down tube
    plate(Pf, { { 12.2, 24.2 }, { 15.6, 25.8 }, { 17.4, 22.2 }, { 16.4, 19.6 }, { 14.0, 22.2 } }, V(0, 0, 0), X, Z, 1.0)
    -- cross tubes: under the tank (the shock's top mount) and at the back of the cradle
    tube(Pf, { V(-5.6, -4.5, 18.6), V(-5.6, 4.5, 18.6) }, 0.5, 12)
    tube(Pf, { V(-2.5, -3.2, -0.45), V(-2.5, 3.2, -0.45) }, 0.42, 10)
    -- the shock's top clevis
    slab(Al, roundRect(2.2, 1.6, 0.5, 3), V(-6.6, 0, 19.6), X, Z, 2.0, 0.2)
    bolt(Ald, V(-7.2, 1.05, 19.6), Y, 0.25, 0.15)
    -- the swingarm pivot bolt, through frame, engine and arm
    sweep(St, { V(PIV[1], -5.35, PIV[3]), V(PIV[1], 5.35, PIV[3]) }, 0.4, 10)

    -- SUBFRAME (aluminium, black): the seat rails and their lower struts
    for _, sd in ipairs({ 1, -1 }) do
        tube(Bk, { V(-4.0, 4.7 * sd, 19.4), V(-14, 4.05 * sd, 22.7), V(-31.2, 3.0 * sd, 23.6) }, 0.48, 12, 6)
        tube(Bk, { V(-6.3, 4.6 * sd, 13.2), V(-15, 4.1 * sd, 17.6), V(-27.0, 3.15 * sd, 23.3) }, 0.42, 12, 6)
    end
    tube(Bk, { V(-30.6, -3.0, 23.6), V(-30.6, 3.0, 23.6) }, 0.4, 10)
    tube(Bk, { V(-13.5, -4.1, 22.6), V(-13.5, 4.1, 22.6) }, 0.35, 10)

    ----------------------------------------------------------------------
    -- ENGINE: crankcase, the cylinder tilted forward with its fins, the head and
    -- its cam cover, clutch and ignition covers, the intake and throttle body.
    ----------------------------------------------------------------------
    local C0 = V(1.8, 0, 4.4)
    local ca = norm(V(0.30, 0, 1))
    local cf = V(ca[3], 0, -ca[1])
    do
        local case = { { -4.4, 2.0 }, { -3.3, 0.35 }, { 3.5, -0.05 }, { 7.2, 1.1 }, { 8.4, 4.0 }, { 7.8, 7.0 },
                       { 5.6, 8.8 }, { 1.0, 9.5 }, { -2.3, 9.3 }, { -4.3, 7.4 }, { -4.8, 4.5 } }
        slab(Bk, case, V(0, 0, 0), X, Z, 4.2, 0.45)
        -- the gearbox's rear lobe, narrower, round the countershaft
        slab(Bk, roundRect(4.0, 4.4, 1.6, 4, -3.0, 5.6), V(0, 0, 0), X, Z, 4.6, 0.35)
        -- clutch cover (right) with its raised centre, bolts round it, and the oil filler
        local cc = V(0.6, -2.1, 4.4)
        slab(Al, circle(3.3, 28, 0.6, 4.4), V(0, -2.75, 0), X, Z, 1.3, 0.4)
        slab(Al, circle(2.0, 24, 0.9, 4.6), V(0, -3.5, 0), X, Z, 0.5, 0.18)
        for i = 0, 8 do
            local a = i / 9 * TAU
            bolt(Ald, V(cc[1] + cos(a) * 2.95, -3.42, cc[3] + sin(a) * 2.95), mul(Y, -1), 0.16, 0.12)
        end
        lathe(Bk, { { 0, 0, true }, { 0.45, 0, true }, { 0.45, 0.3, true }, { 0.3, 0.32, true }, { 0, 0.33, true } }, V(-1.6, -3.4, 7.2), mul(Y, -1), 12)
        -- water pump cover (right, low, front)
        slab(Al, circle(1.35, 18, 5.6, 2.2), V(0, -2.55, 0), X, Z, 0.9, 0.25)
        -- ignition cover (left)
        slab(Al, circle(2.55, 26, 3.4, 3.7), V(0, 2.65, 0), X, Z, 1.1, 0.38)
        for i = 0, 6 do
            local a = i / 7 * TAU + 0.3
            bolt(Ald, V(3.4 + cos(a) * 2.25, 3.2, 3.7 + sin(a) * 2.25), Y, 0.15, 0.1)
        end
        -- the kickstarter boss and the shift shaft
        lathe(Al, { { 0, 0, true }, { 0.75, 0, true }, { 0.75, 1.4 }, { 0.6, 1.5, true }, { 0, 1.5, true } }, V(-2.8, -2.2, 7.9), mul(Y, -1), 14)
        sweep(St, { V(-3.0, 2.0, 3.4), V(-3.0, 3.75, 3.4) }, 0.22, 8)
        -- skid plate under the cradle
        sheet(Pl, 10, 4, function(u, v)
            local x = -2.8 + u * 13.5
            local z = -1.25 + (u > 0.75 and (u - 0.75) * 10 or 0)
            return V(x, (v * 2 - 1) * 3.6, z - 0.25 * (v * 2 - 1) ^ 2 * -1)
        end, 0.18, mul(Z, -1))
    end
    -- the cylinder: a core and its fins, the head, the cam cover
    do
        local function cyl(t) return madd(C0, ca, t) end
        loft(Bk, {
            ring(cyl(4.6), cf, Y, 1.7, 1.95, 24, 3.5), ring(cyl(10.2), cf, Y, 1.6, 1.85, 24, 3.5),
        })
        local fin = roundRect(4.2, 4.6, 0.9, 3)
        for i = 0, 9 do
            local t = 5.2 + i * 0.5
            plate(Bk, fin, cyl(t), cf, Y, 0.13)
        end
        loft(Bk, {
            ring(cyl(10.1), cf, Y, 2.0, 2.25, 24, 3.5), ring(cyl(12.9), cf, Y, 2.0, 2.25, 24, 3.5),
        })
        local finH = roundRect(4.9, 5.2, 1.0, 3)
        for i = 0, 4 do plate(Bk, finH, cyl(10.45 + i * 0.5), cf, Y, 0.14) end
        slab(Al, roundRect(4.0, 4.3, 1.1, 4), cyl(13.25), cf, Y, 0.8, 0.28)
        for _, q in ipairs({ { 1.5, 1.6 }, { -1.5, 1.6 }, { 1.5, -1.6 }, { -1.5, -1.6 } }) do
            bolt(Ald, add(cyl(13.65), add(mul(cf, q[1]), V(0, q[2], 0))), ca, 0.15, 0.12)
        end
        -- spark plug cap and its lead
        lathe(Bk, { { 0, 0, true }, { 0.42, 0, true }, { 0.42, 1.2 }, { 0.3, 1.4, true }, { 0, 1.4, true } }, add(cyl(13.6), mul(cf, -0.4)), ca, 12)
        tube(Bk, { add(cyl(14.9), mul(cf, -0.4)), add(cyl(15.1), V(-1.0, 0.5, 0)), add(cyl(14.4), V(-2.6, 1.2, 0)) }, 0.14, 6, 5)
        -- exhaust port spigot and flange at the front of the head
        local port = add(cyl(11.4), mul(cf, 2.0))
        lathe(Al, { { 0.95, 0, true }, { 1.15, 0, true }, { 1.15, 0.35, true }, { 0.95, 0.35, true } }, port, cf, 18)
        -- intake: the boot from the head's back to the throttle body, and on to the airbox
        local inP = add(cyl(11.2), mul(cf, -1.9))
        local tb = V(-3.6, 0.35, 14.7)
        tube(Rb, { inP, lerp(inP, tb, 0.5), tb }, 0.82, 14)
        lathe(Al, { { 0, -1.1, true }, { 1.0, -1.1, true }, { 1.1, -0.9 }, { 1.1, 0.9 }, { 1.0, 1.1, true }, { 0, 1.1, true } },
              tb, norm(sub(tb, inP)), 18)
        box(Al, add(tb, V(0, 1.3, 0.2)), V(0.6, 0, 0), V(0, 0.3, 0), V(0, 0, 0.6))
        tube(Rb, { add(tb, mul(norm(sub(tb, inP)), 0.9)), V(-6.6, 2.3, 16.6), V(-9.9, 2.5, 18.4) }, 1.05, 14, 5)
        -- the coolant hoses, radiators to cylinder and to the water pump
        for _, sd in ipairs({ 1, -1 }) do
            tube(Rb, { V(10.6, 3.1 * sd, 19.0), V(8.4, 1.7 * sd, 17.8), add(cyl(12.1), V(0, 1.6 * sd, 0)) }, 0.32, 8, 5)
            tube(Rb, { V(10.2, 2.6 * sd, 10.0), V(8.0, 2.7 * sd, 6.0), V(6.0, -2.6, 2.6) }, 0.32, 8, 5)
        end
        -- the head steady: a plate from the frame's spars to the head
        for _, sd in ipairs({ 1, -1 }) do
            box(Pf, V(4.6, 2.7 * sd, 18.4), V(1.0, 0, 0.4), V(0, 0.12, 0), V(-0.6, 0, 2.2))
        end
    end
    -- the countershaft sprocket (left) and its cover
    local CS = { -2.0, 6.2 }
    local CHY = 2.55
    local pr1 = sprocket(St, nil, 13, 0.625, CS[1], CHY, CS[2], 0.24, 0.55)
    lathe(St, { { 0, -0.3, true }, { 0.62, -0.3, true }, { 0.62, 0.3, true }, { 0, 0.32, true } }, V(CS[1], CHY, CS[2]), Y, 10, { flat = true })
    sheet(Pl, 8, 4, function(u, v)
        local a = pi * (0.25 + u * 1.15)
        local r = 1.9 + v * 0.0
        return V(CS[1] + cos(a) * r, CHY + 0.05 + v * 0.75, CS[2] + sin(a) * r)
    end, 0.12, function(p) return sub(p, V(CS[1], p[2], CS[2])) end)

    ----------------------------------------------------------------------
    -- RADIATORS: a core each side of the down tube, facing forward and toed out,
    -- with alloy end tanks, behind louvre slats.
    ----------------------------------------------------------------------
    for _, sd in ipairs({ 1, -1 }) do
        local nrm = norm(V(0.9, 0.42 * sd, 0.18))
        local hz = norm(cross(Z, nrm))
        local vz = norm(cross(nrm, hz))
        if vz[3] < 0 then vz = mul(vz, -1) end
        local c = V(11.0, 3.6 * sd, 14.4)
        box(Bk, c, mul(hz, 1.9), mul(vz, 5.1), mul(nrm, 0.62))
        for _, e in ipairs({ 1, -1 }) do
            local tc = madd(c, vz, e * 5.35)
            loft(Al, { ring(madd(tc, hz, -2.0), nrm, vz, 0.62, 0.32, 12, 3), ring(madd(tc, hz, 2.0), nrm, vz, 0.62, 0.32, 12, 3) })
        end
        -- the filler neck on the right one
        if sd < 0 then
            local fc = madd(madd(c, vz, 5.7), hz, 1.0)
            lathe(Al, { { 0, 0, true }, { 0.4, 0, true }, { 0.4, 0.6 }, { 0.62, 0.65, true }, { 0.62, 0.85, true }, { 0, 0.88, true } }, fc, vz, 14)
        end
        -- louvre slats across the core's face
        local face = madd(c, nrm, 0.85)
        for i = -4, 4 do
            local sc = madd(face, vz, i * 1.1)
            box(Pl, sc, mul(hz, 1.95), mul(norm(add(vz, mul(nrm, -0.9))), 0.42), mul(nrm, 0.05))
        end
        for _, e in ipairs({ 1, -1 }) do
            box(Pl, madd(face, hz, 2.0 * e), mul(hz, 0.12), mul(vz, 5.3), mul(nrm, 0.35))
        end
    end

    ----------------------------------------------------------------------
    -- BODYWORK: the tank (white), the shrouds (paint) over it and the radiators,
    -- the seat up onto the tank, side number plates, the rear fender.
    ----------------------------------------------------------------------
    do
        local stations = {
            { -2.6, 24.8, 3.0, 22.6 }, { 0.0, 25.6, 4.1, 20.6 }, { 3.0, 26.1, 4.5, 19.6 }, { 6.5, 26.5, 4.5, 19.4 },
            { 9.5, 26.8, 4.2, 20.0 }, { 12.0, 26.7, 3.6, 21.5 }, { 13.6, 26.1, 2.6, 23.2 }, { 14.3, 25.4, 1.2, 24.4 },
        }
        local R = {}
        for _, q in ipairs(stations) do
            local zc, hz = (q[2] + q[4]) * 0.5, (q[2] - q[4]) * 0.5
            R[#R + 1] = ring(V(q[1], 0, zc), Y, Z, q[3], hz, 28, 2.6)
        end
        loft(Wh, R)
        -- the filler cap and its breather
        lathe(Bk, { { 0, 0, true }, { 1.1, 0, true }, { 1.15, 0.15 }, { 1.1, 0.42, true }, { 0.6, 0.5 }, { 0, 0.52, true } }, V(8.6, 0, 26.6), Z, 24)
        tube(Bk, { V(8.6, 0, 27.1), V(10.4, 0, 28.5), V(12.5, 0, 29.3) }, 0.1, 6)
    end
    -- the shrouds: from the tank's side out over each radiator and forward of it
    for _, sd in ipairs({ 1, -1 }) do
        local topZ = { { 1.6, 25.4 }, { 6.0, 26.0 }, { 10.5, 26.3 }, { 13.5, 25.5 }, { 15.6, 23.2 }, { 16.6, 20.6 } }
        local botZ = { { 1.6, 21.6 }, { 6.0, 15.6 }, { 10.5, 9.4 }, { 13.5, 8.6 }, { 15.6, 10.6 }, { 16.6, 17.5 } }
        local function pw(tab, x)
            for i = 1, #tab - 1 do
                if x <= tab[i + 1][1] then
                    local t = (x - tab[i][1]) / (tab[i + 1][1] - tab[i][1])
                    t = t * t * (3 - 2 * t)
                    return tab[i][2] + (tab[i + 1][2] - tab[i][2]) * t
                end
            end
            return tab[#tab][2]
        end
        local function shroud(u, v)
            local x = 1.6 + u * 15.0
            local zb, zt = pw(botZ, x), pw(topZ, x)
            local z = zb + (zt - zb) * v
            -- out from the tank at the back and the top to over the radiator, the
            -- front edge turned in
            local bulge = min(1, u / 0.45) ^ 0.7
            local yy = 4.7 + 1.9 * bulge * (0.6 + 0.4 * sin(pi * v)) - 0.5 * v * v
            if u > 0.85 then yy = yy - (u - 0.85) * 6 end
            return V(x, yy * sd, z)
        end
        sheet(Pf, 22, 14, shroud, 0.14, V(0, sd, 0))
        -- the louvres: a dark vent let into the shroud over the radiator, and its
        -- blades standing out of it, angled back
        local u0, u1, v0, v1 = 0.6, 0.86, 0.22, 0.78
        local function vent(u, v, lift)
            local p = shroud(u0 + (u1 - u0) * u, v0 + (v1 - v0) * v)
            return add(p, V(0, sd * lift, 0))
        end
        sheet(Pl, 6, 8, function(u, v) return vent(u, v, 0.03) end, 0, V(0, sd, 0))
        for i = 0, 4 do
            local u = (i + 0.5) / 5
            local a, b = vent(u, 0.04, 0.05), vent(u, 0.96, 0.05)
            local along = norm(sub(b, a))
            local back = norm(add(V(-1, 0, 0), V(0, sd * 0.9, 0)))
            local c = lerp(a, b, 0.5)
            box(Pf, madd(c, back, 0.35), mul(along, len(sub(b, a)) * 0.5), mul(back, 0.42), mul(norm(cross(along, back)), 0.06))
        end
        -- the shroud's bolt to the tank
        bolt(Ald, V(4.0, 5.95 * sd, 23.6), mul(Y, sd), 0.22, 0.14)
    end
    -- the seat: long and flat, up over the tank, gripper cover
    do
        local x0, x1 = -31.6, 4.4
        local topAt = Sz + 2.0
        local xs = Sx - 0.5
        local R = {}
        local n = 22
        for i = 0, n do
            local t = i / n
            local x = x0 + (x1 - x0) * t
            local rise = (x > xs + 9) and (x - xs - 9) ^ 2 * 0.0042 or 0
            local zt = topAt + rise + ((x < -28) and (x + 28) * 0.03 or 0)
            local zb = 24.4
            if x > -2.5 then zb = 24.4 + (x + 2.5) * 0.24 end
            local w = 3.5
            if x > xs + 4 then w = 3.5 - (x - xs - 4) * 0.075 end
            if t < 0.06 then w = w * (0.55 + 0.45 * t / 0.06) end
            if t > 0.95 then w = w * (0.5 + 0.5 * (1 - t) / 0.05) end
            local zc, hz = (zt + zb) * 0.5, (zt - zb) * 0.5
            R[#R + 1] = ring(V(x, 0, zc), Y, Z, w, hz, 28, 3.2)
        end
        loft(M:bucket("frame", "seat"), R)
        -- the seat's base pan, black, a lip under the cover
        sheet(Pl, 18, 3, function(u, v)
            local x = x0 + 0.5 + (-4 - x0) * u
            return V(x, (v * 2 - 1) * 3.6, 24.25)
        end, 0.25, mul(Z, -1))
    end
    -- the airbox behind the side plates, and its filter cover
    loft(Bk, {
        ring(V(-9.6, 0, 20.0), Y, Z, 3.6, 4.0, 20, 4), ring(V(-18.0, 0, 20.8), Y, Z, 3.8, 3.6, 20, 4),
        ring(V(-26.0, 0, 22.4), Y, Z, 3.2, 1.6, 20, 4),
    })
    -- side number plates
    for _, sd in ipairs({ 1, -1 }) do
        sheet(Wh, 16, 8, function(u, v)
            local x = -7.2 - u * 23.0
            local zt = 24.5 + u * 0.4
            local zb = 15.0 + u * 7.2
            if u < 0.12 then zb = zb + (0.12 - u) ^ 2 * 180 end
            local z = zb + (zt - zb) * v
            local yy = 5.15 + 0.3 * sin(pi * v) * sin(pi * u) - u * 0.95
            return V(x, yy * sd, z)
        end, 0.13, V(0, sd, 0))
    end
    -- the rear fender: from under the seat's front out past the tail, arched
    sheet(Wh, 24, 10, function(u, v)
        local x = -8.5 - u * 36.0
        local zc = 24.35 + ((u > 0.6) and (u - 0.6) ^ 1.5 * 9 or 0)
        local w = 3.5 + 0.6 * sin(pi * min(1, u * 1.3)) - (u > 0.85 and (u - 0.85) * 6 or 0)
        local yy = (v * 2 - 1) * w
        local drop = 1.2 * (v * 2 - 1) ^ 2
        return V(x, yy, zc - drop)
    end, 0.14, Z)
    -- a tail light-less MX tail: the fender's mud flap edge, and its mounting bolts
    for _, q in ipairs({ { -23, 2.9 }, { -23, -2.9 }, { -30.6, 2.6 }, { -30.6, -2.6 } }) do
        bolt(Ald, V(q[1], q[2], 24.3), Z, 0.22, 0.14)
    end

    ----------------------------------------------------------------------
    -- EXHAUST: the header out of the head's front, round the right side between
    -- the cylinder and the radiator, back along the frame to the silencer.
    ----------------------------------------------------------------------
    do
        local port = add(madd(C0, ca, 11.4), mul(cf, 2.3))
        local silA, silB = V(-11.5, -6.7, 15.4), V(-32.0, -6.1, 20.6)
        local hdr = spline({ port, add(madd(port, cf, 1.3), V(0, -0.5, -0.5)), V(8.6, -2.1, 12.2), V(7.4, -3.0, 10.4),
                             V(4.4, -3.5, 9.8), V(0.8, -4.7, 10.6), V(-3.2, -5.8, 12.0), V(-7.8, -6.6, 13.8),
                             add(silA, mul(norm(sub(silA, silB)), 1.5)), silA }, 6)
        sweep(Ch, hdr, 0.7, 16)
        -- the silencer: a tapered canister, clamp bands, the end cap
        local ax = norm(sub(silB, silA))
        local Ls = len(sub(silB, silA))
        lathe(Al, { { 0.72, -0.4, true }, { 0.85, 0 }, { 1.65, 2.6 }, { 1.88, 3.6 }, { 1.88, Ls - 2.6 }, { 1.84, Ls - 2.3, true },
                    { 0, Ls - 2.3, true } }, silA, ax, 28)
        lathe(Bk, { { 1.84, Ls - 2.35, true }, { 1.9, Ls - 2.3, true }, { 1.85, Ls - 1.5 }, { 1.5, Ls - 0.4 }, { 1.2, Ls, true },
                    { 0.55, Ls, true }, { 0.55, Ls + 0.5, true }, { 0.45, Ls + 0.5, true }, { 0.45, Ls - 0.3, true }, { 0, Ls - 0.3, true } }, silA, ax, 28)
        for _, t in ipairs({ 4.2, Ls - 3.4 }) do
            lathe(Bk, { { 1.9, t - 0.35, true }, { 1.98, t - 0.3 }, { 1.98, t + 0.3 }, { 1.9, t + 0.35, true } }, silA, ax, 28)
        end
        -- its hanger to the subframe
        box(Al, V(-24.5, -4.6, 21.6), V(0.8, 0, 0), V(0, 0.9, 0), V(0, 0, 0.25))
        bolt(Ald, V(-24.5, -5.5, 22.4), mul(Y, -1), 0.2, 0.14)
        -- the header's spring hooks at the joint
        for _, sd in ipairs({ 1, -1 }) do
            tube(Std, { add(silA, V(0.6, 0, 0.9 * sd)), add(silA, V(2.2, 0, 1.0 * sd)) }, 0.07, 6)
        end
    end

    ----------------------------------------------------------------------
    -- CONTROLS ON THE FRAME: footpegs, kickstarter, gear lever, rear brake pedal
    -- and its master cylinder.
    ----------------------------------------------------------------------
    local PEG = V(G.Pegs.dirtbike.at[1], G.Pegs.dirtbike.at[2], G.Pegs.dirtbike.at[3])
    for _, sd in ipairs({ 1, -1 }) do
        -- the mount from the spar
        slab(Pf, { { -7.6, 2.4 }, { -4.8, 2.6 }, { -4.6, 4.4 }, { -6.0, 4.6 }, { -7.4, 3.6 } }, V(0, 4.75 * sd, 0), X, Z, 0.45, 0.1)
        footpeg(St, Std, V(PEG[1], PEG[2] * sd, PEG[3]), 4.95 * sd, 8.3 * sd, 2.1)
    end
    -- kickstarter (right): folded back along the side
    do
        local a, b = V(-2.8, -3.85, 7.9), V(-9.4, -5.15, 10.4)
        lathe(St, { { 0, -0.35, true }, { 0.55, -0.35, true }, { 0.55, 0.35, true }, { 0, 0.35, true } }, add(a, V(0, -0.3, 0)), Y, 12)
        tube(St, { add(a, V(-0.2, -0.45, 0.1)), V(-6.0, -4.95, 9.3), b }, function() return 0.32, 0.2 end, 10, 4, { up = Y })
        lathe(Bk, { { 0, 0, true }, { 0.36, 0, true }, { 0.36, 1.6 }, { 0.3, 1.7, true }, { 0, 1.7, true } }, b, mul(Y, -1), 12)
    end
    -- gear lever (left): from the shift shaft forward to ahead of the peg
    do
        local a, b = V(-3.0, 3.85, 3.4), V(0.4, 5.25, 4.5)
        lathe(St, { { 0, -0.3, true }, { 0.5, -0.3, true }, { 0.5, 0.3, true }, { 0, 0.3, true } }, a, Y, 12)
        tube(St, { a, V(-1.4, 4.7, 3.7), b }, function() return 0.26, 0.16 end, 10, 4, { up = Y })
        lathe(Rb, { { 0, 0, true }, { 0.3, 0, true }, { 0.34, 0.2 }, { 0.34, 1.2 }, { 0.28, 1.3, true }, { 0, 1.3, true } }, b, Y, 12)
    end
    -- rear brake pedal (right) and its master cylinder
    do
        local piv, tipP = V(-5.4, -5.05, 2.9), V(0.5, -5.45, 3.3)
        lathe(St, { { 0, -0.3, true }, { 0.45, -0.3, true }, { 0.45, 0.3, true }, { 0, 0.3, true } }, piv, Y, 12)
        tube(St, { piv, V(-2.4, -5.35, 2.3), tipP }, function() return 0.28, 0.17 end, 10, 4, { up = Y })
        slab(St, roundRect(1.4, 1.4, 0.45, 3), add(tipP, V(0.3, -0.7, 0.05)), X, Y, 0.3, 0.08)
        lathe(Bk, { { 0, 0, true }, { 0.42, 0, true }, { 0.42, 2.4 }, { 0.3, 2.5, true }, { 0, 2.5, true } }, V(-6.6, -4.7, 4.0), norm(V(-0.15, 0, 1)), 12)
        lathe(Bk, { { 0, 0, true }, { 0.45, 0, true }, { 0.45, 1.3 }, { 0.38, 1.4, true }, { 0, 1.4, true } }, V(-7.3, -4.6, 9.4), Z, 12)
        tube(Rb, { V(-6.9, -4.7, 6.5), V(-7.2, -4.6, 8.4), V(-7.3, -4.6, 9.4) }, 0.12, 6)
        -- the line from the master cylinder to the swingarm
        tube(Rb, { V(-6.6, -4.4, 6.3), V(-5.6, -3.6, 4.7), V(-5.2, -3.3, 4.0) }, 0.13, 6)
    end

    ----------------------------------------------------------------------
    -- SWINGARM (aluminium): two box-section arms from the pivot to the axle
    -- blocks, a cross brace with the shock's lower clevis, the chain slider and
    -- guide, the rear caliper hanging under the right arm.
    ----------------------------------------------------------------------
    local SAl = M:bucket("swingarm", "alloy")
    local SAld = M:bucket("swingarm", "alloy", true)
    local SBk = M:bucket("swingarm", "black")
    local SPl = M:bucket("swingarm", "plastic")
    local SSt = M:bucket("swingarm", "steel")
    local SStd = M:bucket("swingarm", "steel", true)
    local ARMY = 3.42
    for _, sd in ipairs({ 1, -1 }) do
        local a0, a1 = V(PIV[1] - 0.2, 0, PIV[3]), V(-30.6, 0, -0.1)
        local dir = norm(sub(a1, a0))
        local up = perp(dir, Z)
        local R = {}
        local n = 18
        for i = 0, n do
            local t = i / n
            local c = lerp(a0, a1, t)
            c[2] = sd * (ARMY + 0.22 * sin(pi * min(1, t * 1.15)))
            local h = 1.65 - 0.7 * t
            if t < 0.06 then h = h * (0.85 + 0.15 * t / 0.06) end
            R[#R + 1] = ring(c, Y, up, 0.48, h, 20, 4.5)
        end
        loft(SAl, R)
        -- the pivot boss
        lathe(SAl, { { 0, -0.5, true }, { 1.15, -0.5, true }, { 1.22, -0.4 }, { 1.22, 0.4 }, { 1.15, 0.5, true }, { 0, 0.5, true } },
              V(PIV[1], sd * 3.45, PIV[3]), Y, 22)
        -- the axle block and adjuster at the rear
        local ab = V(-29.0, sd * (ARMY + 0.05), 0)
        slab(SAl, roundRect(3.2, 1.5, 0.5, 3), ab, X, Z, 1.15, 0.15)
        box(SAld, V(-31.2, sd * ARMY, 0), V(0.35, 0, 0), V(0, 0.35, 0), V(0, 0, 0.35))
        sweep(SStd, { V(-31.5, sd * ARMY, 0), V(-30.1, sd * ARMY, 0) }, 0.14, 6)
        bolt(SStd, V(-29.0, sd * (ARMY + 0.62), 0), mul(Y, sd), 0.5, 0.35)
    end
    -- the brace and the shock's clevis on it
    sweep(SAl, { V(-10.9, -3.3, 5.0), V(-10.9, 3.3, 5.0) }, function() return 0.85, 1.2 end, 16, { up = X })
    slab(SAl, roundRect(1.8, 1.6, 0.4, 3), V(-10.8, 0, 6.1), X, Z, 1.9, 0.18)
    bolt(SAld, V(-10.8, 1.0, 6.4), Y, 0.25, 0.15)
    -- chain slider over the left arm's front, and the guide under it at the back
    do
        local a0, a1 = V(PIV[1] - 0.2, 0, PIV[3]), V(-30.6, 0, -0.1)
        local up = perp(norm(sub(a1, a0)), Z)
        sheet(SPl, 10, 8, function(u, v)
            local t = 0.03 + u * 0.3
            local c = lerp(a0, a1, t)
            local h = 1.65 - 0.7 * t
            local ang = pi * (v - 0.5) * 1.15
            local yc = ARMY + 0.22 * sin(pi * min(1, t * 1.15))
            return add(add(c, V(0, yc + sin(ang) * 0.68, 0)), mul(up, cos(ang) * (h + 0.05) + 0.12))
        end, 0.16, function(p) return up end)
        local g0 = V(-23.0, CHY, -5.6)
        slab(SPl, { { -24.6, -5.0 }, { -21.2, -4.4 }, { -20.6, -1.8 }, { -22.2, -1.1 }, { -24.4, -1.8 } }, V(0, CHY + 0.62, 0), X, Z, 0.25, 0.06)
        slab(SPl, { { -24.6, -5.0 }, { -21.2, -4.4 }, { -20.6, -3.4 }, { -24.4, -3.6 } }, V(0, CHY - 0.62, 0), X, Z, 0.25, 0.06)
        box(SPl, add(g0, V(0.2, 0, 0.35)), V(1.6, 0, 0.3), V(0, 0.62, 0), V(-0.05, 0, 0.18))
        tube(SAl, { V(-22.5, CHY + 0.6, -1.5), V(-22.5, ARMY - 0.4, -1.0) }, 0.3, 8)
    end
    -- the chain
    chainLoop(M:bucket("swingarm", "steel", true), CS, pr1, { RA[1], RA[3] }, 0.625 / (2 * sin(pi / 50)), CHY, 0.625)
    -- the rear caliper on the right, under the arm, its bracket and torque arm
    do
        local a = math.rad(282)
        local pc = add(RA, V(cos(a) * 3.85, 0, sin(a) * 3.85))
        local tg = V(-sin(a), 0, cos(a))
        caliper(SBk, SStd, pc, tg, -2.08, 0.75, 0.9)
        slab(SAl, { { -29.8, -0.5 }, { -28.0, -0.6 }, { -27.0, -3.6 }, { -28.4, -4.6 }, { -29.6, -3.0 } }, V(0, -3.15, 0), X, Z, 0.3, 0.08)
        tube(SAl, { V(-27.6, -3.15, -3.4), V(-21.0, -3.25, -0.6) }, function() return 0.32, 0.22 end, 8, 2, { up = Y })
        -- the disc guard (a fin over the caliper)
        slab(SPl, { { -31.3, -5.1 }, { -26.2, -5.1 }, { -25.0, -3.4 }, { -27.0, -2.4 }, { -30.0, -2.8 } }, V(0, -2.9, 0), X, Z, 0.2, 0.05)
        tube(M:bucket("swingarm", "rubber"), { add(pc, V(0.6, -0.9, 0.6)), V(-24.0, -3.95, 0.4), V(-13.0, -3.95, 3.2), V(-5.6, -3.4, 4.1) }, 0.13, 6, 6)
    end

    ----------------------------------------------------------------------
    -- FORK (steers): the upside-down fork's outer tubes, the triple clamps, the
    -- front fender off the bottom clamp, the front number plate, the brake hose.
    ----------------------------------------------------------------------
    local FBk = M:bucket("fork", "black")
    local FAl = M:bucket("fork", "alloy")
    local FAld = M:bucket("fork", "alloy", true)
    local FWh = M:bucket("fork", "white")
    for _, sd in ipairs({ 1, -1 }) do
        local o = LP(10.4, sd)
        local top = 23.3
        lathe(FBk, { { 0, -0.02, true }, { 0.9, 0, true }, { 1.12, 0.12 }, { 1.12, 1.0 }, { 1.03, 1.3 }, { 1.0, 2.0 },
                     { 1.0, top - 1.2 }, { 1.0, top, true }, { 0, top, true } }, o, st, 24)
        lathe(FAl, { { 0, 0, true }, { 0.85, 0, true }, { 0.85, 0.5 }, { 0.6, 0.62, true }, { 0.3, 0.75, true }, { 0, 0.78, true } }, LP(33.7, sd), st, 18)
        bolt(FAld, LP(34.45, sd), st, 0.25, 0.25)
    end
    -- triple clamps
    local function clamp(t, depth, thick)
        local c = madd(SP(t), fw, 0.6)
        slab(FAl, roundRect(depth, 11.6, 1.75, 5), c, fw, Y, thick, 0.25)
        for _, sd in ipairs({ 1, -1 }) do
            for _, k in ipairs({ -0.3, 0.3 }) do
                bolt(FAld, add(madd(madd(c, fw, depth * 0.5), st, k * thick), V(0, sd * (LEGY + 0.6), 0)), fw, 0.17, 0.14)
            end
        end
    end
    clamp(22.3, 4.0, 1.6)
    clamp(32.5, 3.7, 1.2)
    lathe(FAl, { { 0, 0, true }, { 0.85, 0, true }, { 0.85, 0.35 }, { 0.55, 0.45, true }, { 0, 0.45, true } }, SP(33.1), st, 6, { flat = true })
    -- front fender: off the bottom clamp, high over the wheel
    local fendBot = SP(21.4)
    sheet(FWh, 26, 10, function(u, v)
        local x = 15.5 + u * 25.0
        local zc = 18.5 - (x - 25.5) ^ 2 * 0.011
        local w = 2.6 + ((x > 23) and min(0.85, (x - 23) * 0.15) or 0) - ((x > 37) and (x - 37) * 0.25 or 0)
        local yy = (v * 2 - 1) * w
        return V(x, yy, zc - 0.85 * (v * 2 - 1) ^ 2)
    end, 0.14, Z)
    for _, k in ipairs({ { 1.3, 1.0 }, { 1.3, -1.0 }, { -0.4, 1.0 }, { -0.4, -1.0 } }) do
        bolt(FAld, add(madd(fendBot, fw, k[1] + 0.6), V(0, k[2], 0.2)), Z, 0.17, 0.12)
    end
    -- the front number plate on the fork tubes
    do
        local c0 = madd(SP(25.0), fw, 3.4)
        sheet(FWh, 10, 12, function(u, v)
            local a = (v * 2 - 1) * 0.95
            local hgt = (u * 2 - 1) * 4.4
            local wv = 4.8 - ((u > 0.8) and (u - 0.8) * 6 or 0) - ((u < 0.15) and (0.15 - u) * 9 or 0)
            local p = madd(c0, st, hgt)
            p = madd(p, fw, -(1 - cos(a)) * 2.6 + (u - 0.5) * 0.8)
            return add(p, V(0, sin(a) / sin(0.95) * wv, 0))
        end, 0.13, fw)
        -- its straps round the tubes
        for _, sd in ipairs({ 1, -1 }) do
            box(FBk, madd(LP(27.5, sd), fw, 1.2), mul(fw, 0.35), V(0, 0.5, 0), mul(st, 0.35))
        end
    end
    -- the hose guide on the bottom clamp and the brake hose down to the lowers
    tube(M:bucket("fork", "rubber"), { madd(SP(29.5), fw, 1.4), madd(SP(26.0), fw, 1.8), add(madd(LP(22.0, 1), fw, 1.3), V(0, 0.4, 0)),
                                       add(madd(LP(14.5, 1), fw, -1.15), V(0, 0.0, 0)), add(madd(LP(11.5, 1), fw, -1.25), V(0, 0, 0)) }, 0.15, 6, 5)

    ----------------------------------------------------------------------
    -- FORK LOWERS (slide): the inner tubes, the axle lugs, the fork guards, the
    -- axle, the front caliper.
    ----------------------------------------------------------------------
    local LCh = M:bucket("forkLower", "chrome")
    local LAl = M:bucket("forkLower", "alloy")
    local LAld = M:bucket("forkLower", "alloy", true)
    local LPl = M:bucket("forkLower", "plastic")
    local LBk = M:bucket("forkLower", "black")
    local LSt = M:bucket("forkLower", "steel")
    for _, sd in ipairs({ 1, -1 }) do
        lathe(LCh, { { 0.85, 0 }, { 0.85, 16.5, true }, { 0, 16.5, true } }, LP(1.5, sd), st, 20)
        -- the axle lug: a cast foot round the tube's bottom, the axle through it
        lathe(LAl, { { 0, -1.8, true }, { 0.85, -1.8, true }, { 1.05, -1.4 }, { 1.08, 1.6 }, { 0.95, 2.1, true }, { 0, 2.1, true } }, LP(0, sd), st, 20)
        lathe(LAl, { { 0, -0.75, true }, { 0.85, -0.75, true }, { 0.9, -0.6 }, { 0.9, 0.6 }, { 0.85, 0.75, true }, { 0, 0.75, true } },
              add(FA, V(0, sd * LEGY, 0)), Y, 18)
        for _, k in ipairs({ -0.5, 0.5 }) do
            bolt(LAld, add(add(FA, V(0, sd * LEGY, 0)), add(mul(fw, -1.0), mul(st, k * 1.1 - 0.3))), mul(fw, -1), 0.15, 0.12)
        end
        -- the fork guard: a moulded shell over the front of the inner tube
        sheet(LPl, 10, 8, function(u, v)
            local t = 1.4 + u * 9.2
            local a = (v - 0.5) * pi * 1.2
            local r = 1.18 + 0.12 * sin(pi * u)
            local p = LP(t, sd)
            return add(madd(p, fw, cos(a) * r), V(0, sin(a) * r * sd * 1.0, 0))
        end, 0.12, function(p) return fw end)
    end
    sweep(LSt, { add(FA, V(0, -LEGY - 0.8, 0)), add(FA, V(0, LEGY + 0.8, 0)) }, 0.36, 10)
    lathe(LAl, { { 0.36, -LEGY + 1.0, true }, { 0.6, -LEGY + 1.0, true }, { 0.6, -2.1, true }, { 0.36, -2.1, true } }, FA, Y, 14)
    lathe(LAl, { { 0.36, 2.1, true }, { 0.6, 2.1, true }, { 0.6, LEGY - 1.0, true }, { 0.36, LEGY - 1.0, true } }, FA, Y, 14)
    bolt(LAld, add(FA, V(0, LEGY + 0.8, 0)), Y, 0.5, 0.3)
    do
        local a = math.rad(160)
        local pc = add(FA, V(cos(a) * 4.75, 0, sin(a) * 4.75))
        local tg = V(-sin(a), 0, cos(a))
        caliper(LBk, LAld, pc, tg, 1.98, 0.7, 0.95)
        slab(LAl, { { 23.6, 2.6 }, { 25.8, 0.6 }, { 28.0, -0.6 }, { 29.2, 0.4 }, { 28.4, 2.4 }, { 25.4, 2.9 } }, V(0, 3.15, 0), X, Z, 0.35, 0.08)
        tube(M:bucket("forkLower", "rubber"), { add(pc, V(0.4, 1.0, 0.9)), add(madd(LP(4.0, 1), fw, -1.3), V(0, -0.1, 0)),
                                                 madd(LP(11.5, 1), fw, -1.25) }, 0.15, 6, 5)
    end

    ----------------------------------------------------------------------
    -- BARS (steer): risers and clamps on the top clamp, a 7/8 bar with a crossbar
    -- and its pad, grips, the clutch lever (left), the throttle and the front
    -- brake's master cylinder and lever (right), the kill button.
    ----------------------------------------------------------------------
    local BBk = M:bucket("bars", "black")
    local BAl = M:bucket("bars", "alloy")
    local BAld = M:bucket("bars", "alloy", true)
    local BRb = M:bucket("bars", "rubber")
    local barC = madd(SP(34.6), fw, 1.4)
    local GX, GZ, GIN, GOUT = barC[1] - 0.85, barC[3] + 4.2, 10.9, 15.8
    local function barPath(sd)
        return {
            barC, add(barC, V(0, 1.6 * sd, 0)), add(barC, V(-0.02, 3.4 * sd, 0.12)), add(barC, V(-0.2, 5.3 * sd, 1.6)),
            V(GX + 0.4, 7.1 * sd, GZ - 0.85), V(GX + 0.08, 8.9 * sd, GZ - 0.06), V(GX, 10.4 * sd, GZ), V(GX, (GOUT + 0.25) * sd, GZ),
        }
    end
    do
        local l, r = barPath(1), barPath(-1)
        local all = {}
        for i = #r, 2, -1 do all[#all + 1] = r[i] end
        for i = 1, #l do all[#all + 1] = l[i] end
        sweep(BAl, spline(all, 6), 0.44, 16)
        -- crossbar and its pad
        local cbz = barC[3] + 2.6
        local cbx = barC[1] - 0.3
        sweep(BAl, { V(cbx, -6.1, cbz), V(cbx, 6.1, cbz) }, 0.38, 12)
        lathe(M:bucket("bars", "paint"), { { 0.38, -3.6, true }, { 0.85, -3.6, true }, { 1.0, -3.3 }, { 1.0, 3.3 }, { 0.85, 3.6, true }, { 0.38, 3.6, true } },
              V(cbx, 0, cbz), Y, 20)
        -- risers and clamps
        for _, sd in ipairs({ 1, -1 }) do
            local base = add(madd(SP(33.1), fw, 1.3), V(0, 1.75 * sd, 0))
            local top = add(barC, V(0, 1.75 * sd, -0.55))
            lathe(BAl, { { 0, 0, true }, { 0.62, 0, true }, { 0.62, len(sub(top, base)) }, { 0, len(sub(top, base)), true } }, base, norm(sub(top, base)), 16)
            slab(BAl, roundRect(1.6, 1.2, 0.35, 3), add(barC, V(0, 1.75 * sd, 0.3)), X, Y, 1.3, 0.12)
            for _, k in ipairs({ -0.55, 0.55 }) do
                bolt(BAld, add(barC, V(k, 1.75 * sd, 0.95)), Z, 0.15, 0.12)
            end
        end
        -- grips (the right one on the throttle tube)
        motoGrip(BRb, V(GX, -GIN, GZ), mul(Y, -1), GOUT - GIN, 0.6)
        motoGrip(BRb, V(GX, GIN, GZ), Y, GOUT - GIN, 0.6)
        -- throttle housing (right) and kill button (left)
        slab(BBk, roundRect(1.6, 1.5, 0.5, 3), V(GX, -(GIN - 0.55), GZ), X, Z, 0.9, 0.2)
        tube(BBk, { V(GX + 0.3, -(GIN - 0.6), GZ + 0.5), V(GX + 0.9, -9.0, GZ + 0.6), V(barC[1] + 1.2, -4.0, barC[3] + 0.9),
                    madd(SP(30.0), fw, 1.4) }, 0.12, 6, 5)
        lathe(M:bucket("bars", "redlens"), { { 0, 0, true }, { 0.3, 0, true }, { 0.3, 0.25 }, { 0, 0.3, true } }, V(GX - 0.2, GIN - 1.7, GZ + 0.45), Z, 10)
        slab(BBk, roundRect(0.9, 1.1, 0.3, 3), V(GX, GIN - 1.7, GZ), X, Y, 0.8, 0.12)
        -- clutch (left): perch, lever, cable to the engine
        local cb = handLever(BBk, BAl, V(GX, GIN - 0.9, GZ), Y, norm(V(1, 0, -0.35)), 5.0, 0.48)
        tube(BBk, { add(cb, V(0.2, 0.0, 0.3)), V(GX + 2.0, GIN - 3.0, GZ - 1.2), V(barC[1] + 1.5, 4.0, barC[3] - 0.5), madd(SP(30.0), fw, 1.6) }, 0.13, 6, 5)
        -- front brake (right): the master cylinder with its reservoir, lever, hose
        local mb = handLever(BBk, BAl, V(GX, -(GIN - 1.5), GZ), mul(Y, -1), norm(V(1, 0, -0.35)), 4.8, 0.48)
        slab(BBk, roundRect(2.0, 1.4, 0.4, 3), V(GX - 0.3, -(GIN - 2.7), GZ + 0.95), X, Y, 1.1, 0.22)
        slab(BAl, roundRect(1.6, 1.1, 0.35, 3), V(GX - 0.3, -(GIN - 2.7), GZ + 1.55), X, Y, 0.12, 0.04)
        tube(M:bucket("bars", "rubber"), { add(mb, V(0.2, 0, -0.2)), V(GX + 1.8, -(GIN - 3.0), GZ - 1.4), V(barC[1] + 1.4, -2.0, barC[3] - 0.6),
                                           madd(SP(29.5), fw, 1.4) }, 0.15, 6, 5)
    end

    ----------------------------------------------------------------------
    -- WHEELS: a 21-inch front and a 19-inch-look rear on the same radius (the
    -- simulation has one), knobbies, 36 spokes, big hubs, the rear sprocket.
    ----------------------------------------------------------------------
    motoWheel(M, "wheelF", Rw, { width = 3.2, height = 3.2, rimDepth = 0.8, rimW = 1.6, flangeR = 1.6, hubHalf = 2.1,
                                 disc = 5.3, spokeR = 0.085, knob = 0.74 })
    motoWheel(M, "wheelR", Rw, { width = 3.9, height = 3.6, rimDepth = 0.8, rimW = 2.05, flangeR = 1.8, hubHalf = 2.2,
                                 disc = 4.3, spokeR = 0.09, knob = 0.82, mirror = true })
    do
        local W = M:bucket("wheelR", "alloy")
        local Wd = M:bucket("wheelR", "alloy", true)
        sprocket(W, Wd, 50, 0.625, 0, CHY, 0, 0.24, 3.75, 6, 1.6)
        lathe(W, { { 0.6, 2.15, true }, { 1.7, 2.15, true }, { 1.7, CHY - 0.1, true }, { 0.6, CHY - 0.1, true } }, V(0, 0, 0), Y, 24)
    end
    -- the rear axle and its spacers (swingarm), the axle through the blocks
    sweep(SSt, { V(-29, -ARMY - 0.62, 0), V(-29, ARMY + 0.62, 0) }, 0.36, 10)
    lathe(SAl, { { 0.36, 2.2, true }, { 0.62, 2.2, true }, { 0.62, ARMY - 0.5, true }, { 0.36, ARMY - 0.5, true } }, RA, Y, 14)
    lathe(SAl, { { 0.36, -ARMY + 0.5, true }, { 0.62, -ARMY + 0.5, true }, { 0.62, -2.2, true }, { 0.36, -2.2, true } }, RA, Y, 14)

    pruneEmpty(M)
    scaleGroups(M, f)
    local function gp(sd) return { A = V(GX, -GIN * sd, GZ), B = V(GX, -GOUT * sd, GZ) } end
    M.layout = scaleLayout({
        k = wb / 39, steer = st,
        headT = SP(31.3), headB = SP(23.5), stemTop = SP(33.1),
        rear = RA, front = FA,
        gripR = gp(1), gripL = gp(-1),
        pegs = { r = V(PEG[1], -PEG[2], PEG[3]), l = V(PEG[1], PEG[2], PEG[3]) },
        swingPivot = PIV,
        shock = { frame = V(-7.2, 0, 19.6), swing = V(-10.8, 0, 6.4), r = 0.95 },
        forkSlide = 7,
        stand = V(-4.5, 4.6, 1.2),
    }, f)
    return M
end
G.RegisterKind("dirtbike", buildDirt)

--------------------------------------------------------------------------
-- THE E-MOTO: a Sur-Ron / Talaria-style electric off-road motorbike. Designed at
-- wheelbase 48 on 12.5-radius wheels (19-inch). A forged twin-spar aluminium frame
-- round a tall battery box under painted side covers, the motor low at the front
-- of the swingarm with its reduction case and the output sprocket (chain on the
-- left), an inverted fork, a slim flat seat, a headlight cowl, an LED tail.
--------------------------------------------------------------------------
local function buildEmoto(opt)
    local wb = opt.wheelbase or 48
    local f = wb / 48
    local Rw = opt.radius or 12.5
    local S = opt.seat or { -12.9, 0, 22.2 }
    local Sx, Sz = S[1] / f, S[3] / f
    local M = newModel()

    local RA, FA = V(-24, 0, 0), V(24, 0, 0)
    local st = norm(V(-0.423, 0, 0.906))          -- 25 degrees of rake
    local fw = V(st[3], 0, -st[1])
    local OFF, LEGY = 1.3, 3.6
    local function SP(t) return add(madd(FA, fw, -OFF), mul(st, t)) end
    local function LP(t, sd) return add(madd(FA, st, t), V(0, sd * LEGY, 0)) end

    local Al = M:bucket("frame", "alloy")
    local Ald = M:bucket("frame", "alloy", true)
    local Pf = M:bucket("frame", "paint")
    local Bk = M:bucket("frame", "black")
    local Pl = M:bucket("frame", "plastic")
    local St = M:bucket("frame", "steel")
    local Std = M:bucket("frame", "steel", true)
    local Rb = M:bucket("frame", "rubber")

    ----------------------------------------------------------------------
    -- FRAME: forged twin spars from the head round the battery to the swingarm
    -- pivot plates, lower rails under the battery and the motor back up to the
    -- head; a tubular subframe to the tail.
    ----------------------------------------------------------------------
    local hb = SP(19.4)
    lathe(Al, { { 0, -0.02, true }, { 0.95, 0, true }, { 1.08, 0.15 }, { 1.0, 0.6 }, { 0.95, 1.2 }, { 0.95, 6.8 },
                { 1.0, 7.4 }, { 1.08, 7.85 }, { 0.95, 8.0, true }, { 0, 8.02, true } }, hb, st, 26)
    local PIV = V(-8.0, 0, 6.6)
    for _, sd in ipairs({ 1, -1 }) do
        local spar = spline({ V(12.0, 0.7 * sd, 22.4), V(8.0, 3.2 * sd, 20.5), V(0.0, 3.6 * sd, 17.4), V(-5.0, 3.7 * sd, 13.8),
                              V(-7.4, 4.5 * sd, 10.0), V(-8.3, 4.85 * sd, 6.6), V(-7.6, 4.6 * sd, 2.4), V(-5.0, 3.6 * sd, -1.2),
                              V(1.5, 3.25 * sd, -1.9), V(7.6, 3.05 * sd, -0.6), V(11.4, 2.2 * sd, 5.0), V(13.5, 1.0 * sd, 12.0),
                              V(14.4, 0.4 * sd, 16.4) }, 3)
        sweep(Al, spar, function(t)
            if t < 0.36 then return 1.15 - 0.4 * t, 0.45 end
            return 0.72, 0.42
        end, 14, { up = Z })
        -- the swingarm pivot plate and its boss
        slab(Al, { { -10.4, 4.6 }, { -8.2, 10.6 }, { -6.0, 9.6 }, { -5.8, 3.0 }, { -7.4, 1.0 }, { -9.6, 2.4 } }, V(0, 4.85 * sd, 0), X, Z, 0.5, 0.15)
        lathe(Al, { { 0, -0.5, true }, { 1.0, -0.5, true }, { 1.1, -0.35 }, { 1.1, 0.35 }, { 1.0, 0.5, true }, { 0, 0.5, true } },
              V(PIV[1], 5.2 * sd, PIV[3]), Y, 20)
        bolt(Std, V(PIV[1], 5.7 * sd, PIV[3]), mul(Y, sd), 0.42, 0.3)
        -- the footpeg mount
        slab(Al, { { -6.8, 1.2 }, { -4.2, 1.4 }, { -4.4, 3.2 }, { -6.6, 3.4 } }, V(0, 4.5 * sd, 0), X, Z, 0.5, 0.12)
    end
    -- the head's forged gussets, spar to spar and down the front
    plate(Al, { { 10.0, 21.6 }, { 12.6, 23.3 }, { 14.9, 18.0 }, { 14.0, 13.8 }, { 12.4, 15.8 }, { 11.4, 19.4 } }, V(0, 0, 0), X, Z, 1.4)
    -- cross members: under the battery, at the pivot, the shock's top mount
    tube(Al, { V(2.0, -3.3, -1.9), V(2.0, 3.3, -1.9) }, 0.45, 10)
    sweep(St, { V(PIV[1], -5.75, PIV[3]), V(PIV[1], 5.75, PIV[3]) }, 0.38, 10)
    for _, sd in ipairs({ 1, -1 }) do
        tube(Al, { V(-3.2, 3.55 * sd, 16.4), V(-12, 3.0 * sd, 19.7), V(-29.0, 2.2 * sd, 20.4) }, 0.42, 10, 6)
        tube(Al, { V(-7.6, 4.4 * sd, 10.0), V(-14, 3.2 * sd, 15.4), V(-21.0, 2.6 * sd, 20.0) }, 0.38, 10, 6)
    end
    tube(Al, { V(-10.2, -3.05, 19.2), V(-10.2, 3.05, 19.2) }, 0.42, 10)
    tube(Al, { V(-28.5, -2.2, 20.4), V(-28.5, 2.2, 20.4) }, 0.34, 10)
    slab(Al, roundRect(2.0, 1.5, 0.45, 3), V(-10.0, 0, 18.4), X, Z, 1.8, 0.18)
    bolt(Ald, V(-10.0, 0.95, 18.0), Y, 0.22, 0.14)

    ----------------------------------------------------------------------
    -- BATTERY, its covers, the controller; the motor and its reduction case.
    ----------------------------------------------------------------------
    do
        local st8 = { { -5.6, 8.2, 17.4, 2.8 }, { -4.6, 7.5, 18.4, 3.05 }, { -1.0, 6.4, 19.0, 3.1 }, { 4.0, 4.8, 19.5, 3.1 },
                      { 9.0, 3.6, 19.6, 3.0 }, { 11.6, 4.2, 18.6, 2.7 }, { 12.6, 5.6, 17.0, 2.2 } }
        local R = {}
        for _, q in ipairs(st8) do
            R[#R + 1] = ring(V(q[1], 0, (q[2] + q[3]) * 0.5), Y, Z, q[4], (q[3] - q[2]) * 0.5, 24, 6)
        end
        loft(Bk, R)
        -- painted side covers over the battery, vents moulded into each
        for _, sd in ipairs({ 1, -1 }) do
            local function cover(u, v)
                local x = -4.6 + u * 16.4
                local zb = 7.9 - u * 3.6 + ((u > 0.85) and (u - 0.85) ^ 2 * 60 or 0) + ((u < 0.1) and (0.1 - u) ^ 2 * 90 or 0)
                local zt = 18.6 + u * 0.8 - ((u > 0.9) and (u - 0.9) ^ 2 * 120 or 0) - ((u < 0.06) and (0.06 - u) ^ 2 * 300 or 0)
                local z = zb + (zt - zb) * v
                local yy = 3.3 + 0.32 * sin(pi * v) * sin(pi * u)
                return V(x, yy * sd, z)
            end
            sheet(Pf, 20, 12, cover, 0.12, V(0, sd, 0))
            for i = 0, 2 do
                local a, b = cover(0.58 + i * 0.07, 0.25), cover(0.72 + i * 0.07, 0.72)
                box(Pl, add(lerp(a, b, 0.5), V(0, 0.08 * sd, 0)), mul(sub(b, a), 0.5), mul(norm(cross(sub(b, a), Y)), 0.28), V(0, 0.08, 0))
            end
        end
        -- the top cover over the battery (where a tank would be)
        local tc = { { -2.4, 18.6, 22.0, 2.6 }, { 0.0, 18.4, 22.5, 3.45 }, { 4.5, 18.6, 22.7, 3.6 }, { 9.0, 19.2, 22.6, 3.3 },
                     { 11.6, 19.8, 22.3, 2.5 }, { 12.6, 20.6, 21.9, 1.4 } }
        local R2 = {}
        for _, q in ipairs(tc) do
            R2[#R2 + 1] = ring(V(q[1], 0, (q[2] + q[3]) * 0.5), Y, Z, q[4], (q[3] - q[2]) * 0.5, 24, 3)
        end
        loft(Pl, R2)
        -- the charge port's cap on top, and the key switch
        lathe(Bk, { { 0, 0, true }, { 0.7, 0, true }, { 0.7, 0.3 }, { 0.5, 0.4, true }, { 0, 0.42, true } }, V(7.0, 0, 22.6), Z, 18)
        lathe(Ald, { { 0, 0, true }, { 0.35, 0, true }, { 0.35, 0.15 }, { 0, 0.18, true } }, V(3.0, 0, 22.62), Z, 12)
        -- the controller, finned, behind the battery
        slab(Bk, roundRect(3.0, 5.0, 0.4, 3), V(-7.0, 0, 13.0), X, Z, 4.4, 0.2)
        for i = 0, 5 do
            box(Bk, V(-8.55, 0, 11.0 + i * 0.75), V(0.12, 0, 0), V(0, 2.0, 0), V(0, 0, 0.08))
        end
    end
    -- the motor: a finned drum across the frame, low at the swingarm's front
    local MC = V(-2.6, 0, 2.6)
    local J = { -6.4, 4.4 }
    do
        local prof = { { 0, -2.6, true }, { 2.4, -2.6, true }, { 2.8, -2.4 }, { 2.95, -2.0, true } }
        local y = -1.8
        while y < 1.6 do
            prof[#prof + 1] = { 2.95, y, true }
            prof[#prof + 1] = { 3.2, y + 0.05, true }
            prof[#prof + 1] = { 3.2, y + 0.2, true }
            prof[#prof + 1] = { 2.95, y + 0.25, true }
            y = y + 0.45
        end
        prof[#prof + 1] = { 2.95, 1.9, true }
        prof[#prof + 1] = { 2.8, 2.1 }
        prof[#prof + 1] = { 2.4, 2.2, true }
        prof[#prof + 1] = { 0, 2.2, true }
        lathe(Bk, prof, MC, Y, 30)
        -- the right end cap with its bolts, the phase leads to the controller
        lathe(Al, { { 0, 0, true }, { 2.2, 0, true }, { 2.35, 0.12 }, { 2.2, 0.35, true }, { 1.0, 0.5 }, { 0, 0.55, true } }, add(MC, V(0, -2.6, 0)), mul(Y, -1), 28)
        for i = 0, 5 do
            local a = i / 6 * TAU
            bolt(Ald, add(MC, V(cos(a) * 1.85, -2.95, sin(a) * 1.85)), mul(Y, -1), 0.14, 0.1)
        end
        tube(Rb, { add(MC, V(1.2, -2.0, 2.4)), add(MC, V(-1.0, -1.6, 5.4)), V(-6.0, -1.0, 11.0) }, 0.3, 8, 5)
        tube(M:bucket("frame", "redlens"), { add(MC, V(0.6, -2.2, 2.6)), add(MC, V(-1.6, -1.9, 5.6)), V(-6.2, -1.6, 11.0) }, 0.26, 8, 5)
        -- the reduction case on the left: from the motor's shaft back to the output
        local loop = {}
        for i = 0, 11 do
            local a = pi * 0.5 + i / 11 * pi
            loop[#loop + 1] = { J[1] + cos(a) * 1.9, J[2] + sin(a) * 1.9 }
        end
        for i = 0, 11 do
            local a = -pi * 0.5 + i / 11 * pi
            loop[#loop + 1] = { MC[1] + cos(a) * 2.6, MC[3] + sin(a) * 2.6 }
        end
        slab(Al, loop, V(0, 2.65, 0), X, Z, 1.0, 0.3)
        for _, q in ipairs({ { J[1] - 1.3, J[2] + 1.1 }, { J[1] - 1.2, J[2] - 1.2 }, { MC[1] + 2.0, MC[3] + 1.4 }, { MC[1] + 2.1, MC[3] - 1.4 },
                             { MC[1] - 0.4, MC[3] + 2.3 }, { -4.6, 1.2 } }) do
            bolt(Ald, V(q[1], 3.15, q[2]), Y, 0.15, 0.1)
        end
    end
    local CHY = 3.25
    local pr1 = sprocket(St, nil, 11, 0.5, J[1], CHY, J[2], 0.2, 0.42)
    lathe(St, { { 0, -0.3, true }, { 0.5, -0.3, true }, { 0.5, 0.3, true }, { 0, 0.32, true } }, V(J[1], CHY, J[2]), Y, 8, { flat = true })

    ----------------------------------------------------------------------
    -- SEAT, REAR FENDER, TAIL LIGHT, PLATE.
    ----------------------------------------------------------------------
    do
        local x0, x1 = -28.0, -0.8
        local topAt = Sz + 2.0
        local xs = Sx - 0.5
        local R = {}
        local n = 20
        for i = 0, n do
            local t = i / n
            local x = x0 + (x1 - x0) * t
            local zt = topAt + ((x > xs + 7) and -(x - xs - 7) * 0.035 or 0) + ((x < -25) and (-25 - x) * 0.04 or 0)
            local zb = 21.0 + ((x > -4) and (x + 4) * 0.25 or 0)
            local w = 2.75 + 0.35 * sin(pi * t)
            if t < 0.05 then w = w * (0.6 + 0.4 * t / 0.05) end
            if t > 0.93 then w = w * (0.45 + 0.55 * (1 - t) / 0.07) end
            R[#R + 1] = ring(V(x, 0, (zt + zb) * 0.5), Y, Z, w, (zt - zb) * 0.5, 28, 3.2)
        end
        loft(M:bucket("frame", "seat"), R)
        sheet(Pl, 14, 3, function(u, v) return V(-27.5 + u * 25.5, (v * 2 - 1) * 2.7, 20.95) end, 0.25, mul(Z, -1))
    end
    -- rear fender: a moulded tail under the seat, out past the wheel
    sheet(Pl, 20, 8, function(u, v)
        local x = -11.0 - u * 25.0
        local zc = 20.6 + ((u > 0.55) and (u - 0.55) ^ 1.4 * 4.0 or 0)
        local w = 2.8 + 0.6 * sin(pi * min(1, u * 1.4)) - ((u > 0.85) and (u - 0.85) * 5 or 0)
        local yy = (v * 2 - 1) * w
        return V(x, yy, zc - 1.0 * (v * 2 - 1) ^ 2)
    end, 0.14, Z)
    -- the LED tail light under the seat's tail
    do
        local c = V(-28.6, 0, 20.9)
        slab(Bk, roundRect(1.2, 4.2, 0.4, 3), c, Y, Z, 1.2, 0.15)
        slab(M:bucket("frame", "redlens"), roundRect(0.9, 3.8, 0.3, 3), add(c, V(-0.62, 0, 0)), Y, Z, 0.15, 0.05)
    end
    -- the plate hanger and its plate, with a reflector and the plate light
    do
        tube(Bk, { V(-31.5, 0, 21.2), V(-33.4, 0, 19.6), V(-33.8, 0, 17.0) }, function() return 0.3, 0.9 end, 8, 4, { up = Y })
        sheet(M:bucket("frame", "white"), 4, 4, function(u, v) return V(-34.1 - 0.4 * v, (u * 2 - 1) * 3.2, 13.0 + v * 4.6) end, 0.1, mul(X, -1))
        slab(M:bucket("frame", "redlens"), circle(0.75, 16), V(-33.95, 0, 12.1), Y, Z, 0.25, 0.08)
        lathe(Bk, { { 0, 0, true }, { 0.45, 0, true }, { 0.45, 0.4, true }, { 0, 0.4, true } }, V(-34.1, 0, 17.9), mul(X, -1), 12)
    end

    ----------------------------------------------------------------------
    -- FOOTPEGS (serrated, on the frame's mounts) and the side stand's pivot
    ----------------------------------------------------------------------
    local PEG = V(G.Pegs.emoto.at[1], G.Pegs.emoto.at[2], G.Pegs.emoto.at[3])
    for _, sd in ipairs({ 1, -1 }) do
        footpeg(St, Std, V(PEG[1], PEG[2] * sd, PEG[3]), 4.75 * sd, 7.7 * sd, 1.9)
    end
    lathe(Bk, { { 0, -0.4, true }, { 0.45, -0.4, true }, { 0.45, 0.4, true }, { 0, 0.4, true } }, V(-4.0, 4.4, 0.6), Y, 12)

    ----------------------------------------------------------------------
    -- SWINGARM: two forged arms from the pivot to the axle, the brace with the
    -- shock clevis, chain guide, rear caliper.
    ----------------------------------------------------------------------
    local SAl = M:bucket("swingarm", "alloy")
    local SAld = M:bucket("swingarm", "alloy", true)
    local SBk = M:bucket("swingarm", "black")
    local SPl = M:bucket("swingarm", "plastic")
    local SStd = M:bucket("swingarm", "steel", true)
    local ARMY = 3.95
    for _, sd in ipairs({ 1, -1 }) do
        local a0, a1 = V(PIV[1] - 0.2, 0, PIV[3]), V(-25.4, 0, -0.1)
        local up = perp(norm(sub(a1, a0)), Z)
        local R = {}
        for i = 0, 16 do
            local t = i / 16
            local c = lerp(a0, a1, t)
            c[2] = sd * ARMY
            local h = 1.35 - 0.5 * t
            R[#R + 1] = ring(c, Y, up, 0.42, h, 20, 4.5)
        end
        loft(SAl, R)
        lathe(SAl, { { 0, -0.42, true }, { 1.05, -0.42, true }, { 1.12, -0.3 }, { 1.12, 0.3 }, { 1.05, 0.42, true }, { 0, 0.42, true } },
              V(PIV[1], sd * ARMY, PIV[3]), Y, 20)
        slab(SAl, roundRect(2.8, 1.3, 0.45, 3), V(-24.0, sd * ARMY, 0), X, Z, 0.95, 0.14)
        box(SAld, V(-26.0, sd * ARMY, 0), V(0.3, 0, 0), V(0, 0.3, 0), V(0, 0, 0.3))
        bolt(SStd, V(-24.0, sd * (ARMY + 0.5), 0), mul(Y, sd), 0.42, 0.3)
    end
    sweep(SAl, { V(-11.9, -ARMY, 4.0), V(-11.9, ARMY, 4.0) }, function() return 0.7, 0.75 end, 14, { up = X })
    slab(SAl, roundRect(1.6, 1.6, 0.4, 3), V(-11.6, 0, 5.0), X, Z, 1.7, 0.16)
    bolt(SAld, V(-11.6, 0.9, 5.2), Y, 0.22, 0.14)
    chainLoop(M:bucket("swingarm", "steel", true), J, pr1, { RA[1], RA[3] }, 0.5 / (2 * sin(pi / 48)), CHY, 0.5)
    slab(SPl, { { -19.0, -3.6 }, { -16.4, -2.8 }, { -16.0, -1.3 }, { -18.8, -1.9 } }, V(0, CHY, 0), X, Z, 0.9, 0.12)
    do
        local a = math.rad(285)
        local pc = add(RA, V(cos(a) * 3.5, 0, sin(a) * 3.5))
        caliper(SBk, SStd, pc, V(-sin(a), 0, cos(a)), -1.78, 0.7, 0.8)
        slab(SAl, { { -25.0, -0.6 }, { -23.2, -0.6 }, { -22.4, -3.4 }, { -23.6, -4.2 }, { -24.8, -2.8 } }, V(0, -2.75, 0), X, Z, 0.3, 0.08)
        tube(M:bucket("swingarm", "rubber"), { add(pc, V(0.5, -0.8, 0.6)), V(-20.0, -3.4, 1.4), V(-11.0, -3.3, 5.4), V(-8.6, -3.0, 7.2) }, 0.12, 6, 6)
    end

    ----------------------------------------------------------------------
    -- FORK (steers): the inverted fork's uppers, triple clamps, fender, the
    -- headlight cowl with its lamp, the horn under it.
    ----------------------------------------------------------------------
    local FBk = M:bucket("fork", "black")
    local FAl = M:bucket("fork", "alloy")
    local FAld = M:bucket("fork", "alloy", true)
    local FPl = M:bucket("fork", "plastic")
    for _, sd in ipairs({ 1, -1 }) do
        local o = LP(9.2, sd)
        local top = 19.4
        lathe(FBk, { { 0, -0.02, true }, { 0.75, 0, true }, { 0.95, 0.12 }, { 0.95, 0.9 }, { 0.86, 1.15 }, { 0.82, 1.8 },
                     { 0.82, top }, { 0.82, top + 0.02, true }, { 0, top + 0.02, true } }, o, st, 22)
        lathe(FAl, { { 0, 0, true }, { 0.7, 0, true }, { 0.7, 0.45 }, { 0.5, 0.55, true }, { 0, 0.6, true } }, LP(28.6, sd), st, 16)
    end
    local function clamp(t, depth, thick)
        local c = madd(SP(t), fw, 0.65)
        slab(FAl, roundRect(depth, 10.0, 1.5, 5), c, fw, Y, thick, 0.22)
        for _, sd in ipairs({ 1, -1 }) do
            bolt(FAld, add(madd(c, fw, depth * 0.5), V(0, sd * (LEGY + 0.5), 0)), fw, 0.15, 0.12)
        end
    end
    clamp(18.9, 3.5, 1.4)
    clamp(27.7, 3.2, 1.1)
    lathe(FAl, { { 0, 0, true }, { 0.75, 0, true }, { 0.75, 0.3 }, { 0.5, 0.4, true }, { 0, 0.4, true } }, SP(28.25), st, 6, { flat = true })
    sheet(FPl, 22, 8, function(u, v)
        local x = 13.6 + u * 21.0
        local zc = 16.3 - (x - 22.5) ^ 2 * 0.012
        local w = 2.25 + ((x > 20) and min(0.7, (x - 20) * 0.14) or 0) - ((x > 31.5) and (x - 31.5) * 0.25 or 0)
        local yy = (v * 2 - 1) * w
        return V(x, yy, zc - 0.8 * (v * 2 - 1) ^ 2)
    end, 0.13, Z)
    do
        local c0 = madd(SP(23.2), fw, 3.2)
        sheet(FPl, 10, 12, function(u, v)
            local a = (v * 2 - 1) * 0.9
            local hgt = (u * 2 - 1) * 4.2
            local wv = 4.0 - ((u > 0.75) and (u - 0.75) * 7 or 0) - ((u < 0.15) and (0.15 - u) * 10 or 0)
            local p = madd(c0, st, hgt)
            p = madd(p, fw, -(1 - cos(a)) * 2.4 + (u - 0.5) * 0.7)
            return add(p, V(0, sin(a) / sin(0.9) * wv, 0))
        end, 0.13, fw)
        local lampC = madd(madd(c0, st, -0.4), fw, 0.25)
        lathe(FBk, { { 0, -0.6, true }, { 1.75, -0.6, true }, { 1.95, -0.3 }, { 1.95, 0.15, true }, { 1.65, 0.2, true }, { 0, 0.2, true } }, lampC, fw, 26)
        lathe(M:bucket("fork", "lens"), { { 0, 0.4, true }, { 0.8, 0.36 }, { 1.4, 0.28 }, { 1.65, 0.18, true } }, lampC, fw, 26)
        lathe(M:bucket("fork", "chrome"), { { 1.65, 0.2, true }, { 1.95, 0.18, true }, { 1.98, 0.22 }, { 1.65, 0.26, true } }, lampC, fw, 26)
        -- the horn under the cowl
        local hc = madd(madd(c0, st, -5.2), fw, -0.2)
        lathe(FBk, { { 0, 0, true }, { 1.0, 0, true }, { 1.05, 0.12 }, { 1.0, 0.5, true }, { 0, 0.5, true } }, hc, fw, 20)
        lathe(FAl, { { 0, 0.5, true }, { 0.6, 0.5, true }, { 0.6, 0.6 }, { 0, 0.62, true } }, hc, fw, 16)
        box(FBk, madd(hc, st, 0.9), mul(fw, 0.15), V(0, 0.3, 0), mul(st, 0.9))
        for _, sd in ipairs({ 1, -1 }) do
            box(FBk, madd(LP(24.0, sd), fw, 1.0), mul(fw, 0.3), V(0, 0.45, 0), mul(st, 0.3))
        end
    end
    tube(M:bucket("fork", "rubber"), { madd(SP(25.0), fw, 1.2), add(madd(LP(19.5, 1), fw, 1.1), V(0, 0.3, 0)),
                                       madd(LP(13.0, 1), fw, -1.0), madd(LP(10.6, 1), fw, -1.05) }, 0.13, 6, 5)

    ----------------------------------------------------------------------
    -- FORK LOWERS (slide): inner tubes, axle lugs, guards, axle, caliper.
    ----------------------------------------------------------------------
    local LCh = M:bucket("forkLower", "chrome")
    local LAl = M:bucket("forkLower", "alloy")
    local LAld = M:bucket("forkLower", "alloy", true)
    local LPl = M:bucket("forkLower", "plastic")
    local LBk = M:bucket("forkLower", "black")
    local LSt = M:bucket("forkLower", "steel")
    for _, sd in ipairs({ 1, -1 }) do
        lathe(LCh, { { 0.68, 0 }, { 0.68, 15.0, true }, { 0, 15.0, true } }, LP(1.2, sd), st, 18)
        lathe(LAl, { { 0, -1.5, true }, { 0.7, -1.5, true }, { 0.88, -1.2 }, { 0.9, 1.4 }, { 0.8, 1.8, true }, { 0, 1.8, true } }, LP(0, sd), st, 18)
        lathe(LAl, { { 0, -0.62, true }, { 0.72, -0.62, true }, { 0.76, -0.5 }, { 0.76, 0.5 }, { 0.72, 0.62, true }, { 0, 0.62, true } },
              add(FA, V(0, sd * LEGY, 0)), Y, 16)
        sheet(LPl, 8, 6, function(u, v)
            local t = 1.4 + u * 7.8
            local a = (v - 0.5) * pi * 1.15
            local r = 1.0 + 0.1 * sin(pi * u)
            return add(madd(LP(t, sd), fw, cos(a) * r), V(0, sin(a) * r * sd, 0))
        end, 0.1, function() return fw end)
    end
    sweep(LSt, { add(FA, V(0, -LEGY - 0.7, 0)), add(FA, V(0, LEGY + 0.7, 0)) }, 0.32, 10)
    lathe(LAl, { { 0.32, -LEGY + 0.9, true }, { 0.52, -LEGY + 0.9, true }, { 0.52, -1.9, true }, { 0.32, -1.9, true } }, FA, Y, 12)
    lathe(LAl, { { 0.32, 1.9, true }, { 0.52, 1.9, true }, { 0.52, LEGY - 0.9, true }, { 0.32, LEGY - 0.9, true } }, FA, Y, 12)
    bolt(LAld, add(FA, V(0, LEGY + 0.7, 0)), Y, 0.42, 0.28)
    do
        local a = math.rad(158)
        local pc = add(FA, V(cos(a) * 3.65, 0, sin(a) * 3.65))
        caliper(LBk, LAld, pc, V(-sin(a), 0, cos(a)), 1.78, 0.7, 0.9)
        slab(LAl, { { 19.6, 2.2 }, { 21.6, 0.4 }, { 23.4, -0.5 }, { 24.4, 0.4 }, { 23.6, 2.2 }, { 21.2, 2.6 } }, V(0, 2.85, 0), X, Z, 0.32, 0.08)
        tube(M:bucket("forkLower", "rubber"), { add(pc, V(0.4, 0.9, 0.8)), madd(LP(4.0, 1), fw, -1.1), madd(LP(10.6, 1), fw, -1.05) }, 0.13, 6, 5)
    end

    ----------------------------------------------------------------------
    -- BARS: a fat bar with its pad, clamps, grips, two brake levers (the left one
    -- is the rear brake: no clutch), twist throttle, the display.
    ----------------------------------------------------------------------
    local BBk = M:bucket("bars", "black")
    local BAl = M:bucket("bars", "alloy")
    local BRb = M:bucket("bars", "rubber")
    local barC = madd(SP(29.9), fw, 1.1)
    local GX, GZ, GIN, GOUT = barC[1] - 0.6, barC[3] + 2.4, 10.0, 14.6
    do
        local function half(sd)
            return { barC, add(barC, V(0, 1.6 * sd, 0)), add(barC, V(-0.02, 3.2 * sd, 0.1)), add(barC, V(-0.2, 5.0 * sd, 1.1)),
                     V(GX + 0.2, 6.8 * sd, GZ - 0.4), V(GX + 0.04, 8.4 * sd, GZ - 0.04), V(GX, 9.6 * sd, GZ), V(GX, (GOUT + 0.2) * sd, GZ) }
        end
        local l, r = half(1), half(-1)
        local all = {}
        for i = #r, 2, -1 do all[#all + 1] = r[i] end
        for i = 1, #l do all[#all + 1] = l[i] end
        sweep(BBk, spline(all, 6), function(t)
            local e = abs(t * 2 - 1)
            return (e < 0.35) and 0.56 or (e < 0.5 and 0.56 - (e - 0.35) / 0.15 * 0.12 or 0.44)
        end, 16)
        lathe(M:bucket("bars", "paint"), { { 0.56, -2.6, true }, { 0.95, -2.6, true }, { 1.05, -2.35 }, { 1.05, 2.35 }, { 0.95, 2.6, true }, { 0.56, 2.6, true } },
              barC, Y, 18)
        for _, sd in ipairs({ 1, -1 }) do
            local base = add(madd(SP(28.25), fw, 1.05), V(0, 1.6 * sd, 0))
            local top = add(barC, V(0, 1.6 * sd, -0.55))
            lathe(BAl, { { 0, 0, true }, { 0.55, 0, true }, { 0.55, len(sub(top, base)) }, { 0, len(sub(top, base)), true } }, base, norm(sub(top, base)), 14)
            slab(BAl, roundRect(1.5, 1.1, 0.35, 3), add(barC, V(0, 2.95 * sd, 0.3)), X, Y, 1.4, 0.12)
        end
        motoGrip(BRb, V(GX, -GIN, GZ), mul(Y, -1), GOUT - GIN, 0.58)
        motoGrip(BRb, V(GX, GIN, GZ), Y, GOUT - GIN, 0.58)
        slab(BBk, roundRect(1.5, 1.4, 0.45, 3), V(GX, -(GIN - 0.5), GZ), X, Z, 0.8, 0.18)
        for _, sd in ipairs({ 1, -1 }) do
            local mb = handLever(BBk, BAl, V(GX, sd * (GIN - 1.3), GZ), mul(Y, sd), norm(V(1, 0, -0.35)), 4.5, 0.46)
            slab(BBk, roundRect(1.8, 1.3, 0.4, 3), V(GX - 0.25, sd * (GIN - 2.4), GZ + 0.9), X, Y, 1.0, 0.2)
            tube(M:bucket("bars", "rubber"), { add(mb, V(0.2, 0, -0.2)), V(GX + 1.6, sd * (GIN - 2.8), GZ - 1.3), V(barC[1] + 1.2, sd * 2.0, barC[3] - 0.6),
                                               madd(SP(25.0), fw, 1.2) }, 0.13, 6, 5)
        end
        local dn = norm(V(0.5, 0, 1))
        local dc = add(barC, V(-0.6, 0, 1.3))
        slab(BBk, roundRect(2.6, 1.6, 0.35, 3), dc, Y, norm(V(-1, 0, 0.5)), 0.7, 0.18)
        slab(M:bucket("bars", "lens"), roundRect(2.1, 1.1, 0.25, 3), madd(dc, norm(cross(Y, norm(V(-1, 0, 0.5)))), -0.36), Y, norm(V(-1, 0, 0.5)), 0.05, 0)
        lathe(M:bucket("bars", "redlens"), { { 0, 0, true }, { 0.28, 0, true }, { 0.28, 0.22 }, { 0, 0.26, true } }, V(GX - 0.1, GIN - 0.6, GZ + 0.55), Z, 10)
    end

    ----------------------------------------------------------------------
    -- WHEELS: 19-inch knobbies on black rims, 36 spokes, discs (front left, rear
    -- right), the rear sprocket on the left.
    ----------------------------------------------------------------------
    motoWheel(M, "wheelF", Rw, { width = 2.8, height = 2.7, rimDepth = 0.7, rimW = 1.45, flangeR = 1.4, hubHalf = 1.9,
                                 disc = 4.2, spokeR = 0.075, knob = 0.62 })
    motoWheel(M, "wheelR", Rw, { width = 3.1, height = 2.9, rimDepth = 0.7, rimW = 1.65, flangeR = 1.5, hubHalf = 1.9,
                                 disc = 4.0, spokeR = 0.08, knob = 0.66, mirror = true })
    do
        local W = M:bucket("wheelR", "alloy")
        local Wd = M:bucket("wheelR", "alloy", true)
        sprocket(W, Wd, 48, 0.5, 0, CHY, 0, 0.2, 2.95, 6, 1.4)
        lathe(W, { { 0.55, 1.85, true }, { 1.45, 1.85, true }, { 1.45, CHY - 0.08, true }, { 0.55, CHY - 0.08, true } }, V(0, 0, 0), Y, 22)
    end
    local SSt = M:bucket("swingarm", "steel")
    sweep(SSt, { V(-24, -ARMY - 0.55, 0), V(-24, ARMY + 0.55, 0) }, 0.32, 10)
    lathe(SAl, { { 0.32, -ARMY + 0.42, true }, { 0.55, -ARMY + 0.42, true }, { 0.55, -1.9, true }, { 0.32, -1.9, true } }, RA, Y, 12)
    lathe(SAl, { { 0.32, CHY + 0.15, true }, { 0.55, CHY + 0.15, true }, { 0.55, ARMY - 0.42, true }, { 0.32, ARMY - 0.42, true } }, RA, Y, 12)

    pruneEmpty(M)
    scaleGroups(M, f)
    local function gp(sd) return { A = V(GX, -GIN * sd, GZ), B = V(GX, -GOUT * sd, GZ) } end
    M.layout = scaleLayout({
        k = wb / 39, steer = st,
        headT = SP(26.8), headB = SP(19.9), stemTop = SP(28.25),
        rear = RA, front = FA,
        gripR = gp(1), gripL = gp(-1),
        pegs = { r = V(PEG[1], -PEG[2], PEG[3]), l = V(PEG[1], PEG[2], PEG[3]) },
        swingPivot = PIV,
        shock = { frame = V(-10.0, 0, 18.0), swing = V(-11.6, 0, 5.4), r = 0.85 },
        forkSlide = 6,
        stand = V(-4.0, 4.4, 0.6),
    }, f)
    return M
end
G.RegisterKind("emoto", buildEmoto)

--------------------------------------------------------------------------
-- THE MOPED: a Piaggio Ciao-style pedal moped. Designed at wheelbase 48 on
-- 11-radius wheels (17-inch). A pressed-steel step-through spine with the fuel tank
-- in its tail, a 50 cc two-stroke slung under it with the cylinder pointing forward,
-- its belt variator on the left driving the rear wheel, a pedal chain on the right
-- (you pedal it to start), a sprung saddle, a rack, steel fenders, a headlight on the
-- bars with the horn under it. Rigid: no suspension the drawing has to move.
--------------------------------------------------------------------------
local function buildMoped(opt)
    local wb = opt.wheelbase or 48
    local f = wb / 48
    local Rw = opt.radius or 11
    local S = opt.seat or { -12.9, 0, 20.3 }
    local Sx, Sz = S[1] / f, S[3] / f
    local M = newModel()

    local RA, FA = V(-24, 0, 0), V(24, 0, 0)
    local st = norm(V(-0.39, 0, 0.92))
    local fw = V(st[3], 0, -st[1])
    local OFF, LEGY = 1.6, 2.75
    local function SP(t) return add(madd(FA, fw, -OFF), mul(st, t)) end
    local function LP(t, sd) return add(madd(FA, st, t), V(0, sd * LEGY, 0)) end
    local BB = V(-5.5, 0, 3.1)
    local CRANK, Q = 6.8, 3.4

    local Pf = M:bucket("frame", "paint")
    local Pfd = M:bucket("frame", "paint", true)
    local Bk = M:bucket("frame", "black")
    local Al = M:bucket("frame", "alloy")
    local Ald = M:bucket("frame", "alloy", true)
    local Ch = M:bucket("frame", "chrome")
    local Chd = M:bucket("frame", "chrome", true)
    local St = M:bucket("frame", "steel")
    local Std = M:bucket("frame", "steel", true)
    local Rb = M:bucket("frame", "rubber")
    local Pl = M:bucket("frame", "plastic")

    ----------------------------------------------------------------------
    -- THE SPINE: one pressed-steel beam from the head down through the step-
    -- through and up under the saddle, swelling into the fuel tank over the rear
    -- wheel. A welded flange runs along its underside.
    ----------------------------------------------------------------------
    local spine = spline({ V(13.6, 0, 22.6), V(12.4, 0, 18.6), V(9.6, 0, 13.4), V(5.0, 0, 10.6), V(0.0, 0, 10.3),
                           V(-5.0, 0, 11.6), V(-9.4, 0, 14.4), V(-12.6, 0, 16.4), V(-16.5, 0, 17.4), V(-22.0, 0, 17.3),
                           V(-27.5, 0, 16.6), V(-31.0, 0, 16.0) }, 5)
    do
        local n = #spine
        local L = { 0 }
        for i = 2, n do L[i] = L[i - 1] + len(sub(spine[i], spine[i - 1])) end
        local R = {}
        for i = 1, n do
            local p = spine[i]
            local tg = norm(sub(spine[min(n, i + 1)], spine[max(1, i - 1)]))
            local up = perp(tg, Z)
            local x = p[1]
            -- the section: a deep pressed oval, the tank's bulge behind the seat post
            local w, h = 1.65, 1.55
            local tank = 0
            if x < -12.0 and x > -29.5 then
                tank = sin(pi * (x + 12.0) / -17.5)
                tank = tank ^ 0.6
            end
            w = w + 1.55 * tank
            h = h + 1.35 * tank
            if x > 11.5 then w, h = w + (x - 11.5) * 0.15, h + (x - 11.5) * 0.2 end
            if i == n then w, h = w * 0.7, h * 0.7 end
            local c = madd(p, up, 0.6 * tank)
            R[i] = ring(c, Y, up, w, h, 26, 2.7)
        end
        loft(Pf, domeStart(R, 1.4))
        -- the weld flange along the underside
        local fl = {}
        for i = 1, n, 2 do
            local p = spine[i]
            local tg = norm(sub(spine[min(n, i + 1)], spine[max(1, i - 1)]))
            local up = perp(tg, Z)
            local x = p[1]
            local tank = (x < -12.0 and x > -29.5) and sin(pi * (x + 12.0) / -17.5) ^ 0.6 or 0
            fl[#fl + 1] = madd(p, up, -(1.55 + 1.35 * tank) + 0.6 * tank - 0.08)
        end
        sweep(Pf, fl, function() return 0.12, 0.3 end, 8, { up = Y })
    end
    -- the head tube, through the spine's nose, with its headset cups
    local hb, ht = SP(18.6), SP(26.2)
    lathe(Pf, { { 0, -0.02, true }, { 0.85, 0, true }, { 0.9, 0.15 }, { 0.85, 0.4 }, { 0.8, 0.6 }, { 0.8, 7.0 },
                { 0.85, 7.2 }, { 0.9, 7.45 }, { 0.85, 7.6, true }, { 0, 7.62, true } }, hb, st, 24)
    lathe(Ch, { { 0, 0, true }, { 0.95, 0, true }, { 0.95, 0.3, true }, { 0, 0.3, true } }, madd(ht, st, -0.1), st, 22)
    lathe(Ch, { { 0, 0, true }, { 0.95, 0, true }, { 0.95, 0.3, true }, { 0, 0.3, true } }, madd(hb, st, -0.25), st, 22)
    -- a badge on the nose
    slab(Al, roundRect(1.8, 2.6, 0.7, 4), madd(SP(20.4), fw, 0.95), Y, st, 0.2, 0.06)
    -- the fuel cap on the tank behind the saddle
    lathe(Ch, { { 0, 0, true }, { 1.05, 0, true }, { 1.1, 0.12 }, { 1.05, 0.35, true }, { 0.5, 0.45 }, { 0, 0.48, true } }, V(-20.6, 0, 20.4), Z, 22)
    -- rear stays: a seat stay each side from the tank to the dropouts, and on the
    -- right a chain stay from the engine; the left is the engine's belt arm
    for _, sd in ipairs({ 1, -1 }) do
        local yd = (sd > 0) and 3.75 or -3.25
        tube(Pf, { V(-15.0, 1.5 * sd, 15.6), V(-19.5, (abs(yd) - 0.6) * sd, 8.0), V(-23.6, yd, 1.0) }, 0.42, 12, 5)
        plate(Pf, { { -25.6, 0.5 }, { -24.0, 0.55 }, { -22.0, 1.6 }, { -22.6, 2.4 }, { -23.6, 1.8 }, { -25.4, 1.4 } }, V(0, yd, 0), X, Z, 0.28)
        plate(Pf, { { -26.2, -0.3 }, { -24.0, -0.45 }, { -22.2, 0.0 }, { -22.4, 0.9 }, { -24.0, 0.55 }, { -26.0, 0.4 } }, V(0, yd, 0), X, Z, 0.3)
    end
    tube(Pf, { V(-9.2, -2.3, 2.6), V(-16.0, -3.2, 1.0), V(-23.4, -3.25, -0.1) }, 0.36, 10, 5)

    ----------------------------------------------------------------------
    -- THE ENGINE: crankcase round the pedal shaft, the finned cylinder forward
    -- under the step-through, the flywheel fan's cover (right), the variator and
    -- its belt (left), carburettor, air filter, exhaust.
    ----------------------------------------------------------------------
    local CC = V(-7.0, 0, 3.8)
    do
        local case = { { -10.6, 2.6 }, { -9.6, 0.9 }, { -7.4, 0.2 }, { -4.6, 0.6 }, { -3.2, 2.2 }, { -3.0, 4.4 },
                       { -4.2, 6.4 }, { -6.6, 7.3 }, { -9.0, 6.8 }, { -10.6, 5.0 } }
        slab(Al, case, V(0, 0, 0), X, Z, 4.6, 0.45)
        -- the fan cover on the right: a round shell with its grille
        local fc = V(-7.0, -2.3, 4.0)
        lathe(Pl, { { 0, -0.02, true }, { 3.0, 0, true }, { 3.1, -0.15 }, { 3.05, -0.75 }, { 2.7, -1.15 }, { 1.0, -1.35 }, { 0, -1.38, true } },
              fc, Y, 30)
        for i = 0, 11 do
            local a = i / 12 * TAU
            local d = V(cos(a), 0, sin(a))
            box(Bk, add(add(fc, V(0, -1.38, 0)), mul(d, 1.8)), mul(d, 0.8), V(0, 0.04, 0), mul(V(-sin(a), 0, cos(a)), 0.1))
        end
        -- the variator cover on the left
        lathe(Al, { { 0, 0.0, true }, { 2.6, 0.0, true }, { 2.8, 0.2 }, { 2.75, 0.75 }, { 2.4, 1.0, true }, { 0.8, 1.1 }, { 0, 1.12, true } },
              V(CC[1], 2.3, CC[3]), Y, 28)
        for i = 0, 5 do
            local a = i / 6 * TAU + 0.3
            bolt(Ald, V(CC[1] + cos(a) * 2.45, 3.2, CC[3] + sin(a) * 2.45), Y, 0.13, 0.1)
        end
    end
    -- the cylinder, forward and a little up, fins round it, the head and plug
    local ca = norm(V(1, 0, 0.26))
    local cu = norm(cross(Y, ca))
    if cu[3] < 0 then cu = mul(cu, -1) end
    local C0 = V(-4.4, 0, 4.8)
    do
        local function cyl(t) return madd(C0, ca, t) end
        loft(St, { ring(cyl(0), Y, cu, 1.25, 1.25, 20, 2), ring(cyl(5.4), Y, cu, 1.2, 1.2, 20, 2) })
        local fin = roundRect(3.7, 3.6, 0.9, 3)
        for i = 0, 7 do plate(St, fin, cyl(1.2 + i * 0.45), Y, cu, 0.11) end
        loft(Al, { ring(cyl(4.9), Y, cu, 1.6, 1.6, 20, 3), ring(cyl(6.2), Y, cu, 1.5, 1.5, 20, 3) })
        local finH = roundRect(4.0, 4.0, 1.2, 3)
        for i = 0, 2 do plate(Al, finH, cyl(5.15 + i * 0.4), Y, cu, 0.12) end
        lathe(Bk, { { 0, 0, true }, { 0.4, 0, true }, { 0.4, 0.9 }, { 0.32, 1.1, true }, { 0, 1.1, true } }, add(cyl(6.2), mul(cu, 0.4)), ca, 12)
        tube(Bk, { add(cyl(7.2), mul(cu, 0.4)), add(cyl(7.6), V(0, -0.8, 1.6)), V(-1.0, -2.4, 7.6), V(-6.0, -2.6, 7.6) }, 0.12, 6, 5)
        -- the cooling shroud over the cylinder's top and right
        sheet(Pl, 8, 8, function(u, v)
            local t = -0.2 + u * 5.2
            local a = -pi * 0.15 + v * pi * 0.95
            return add(cyl(t), add(mul(cu, cos(a) * 2.3), V(0, -sin(a) * 2.3, 0)))
        end, 0.1, function(p) return sub(p, madd(C0, ca, dot(sub(p, C0), ca))) end)
        -- the exhaust: out under the cylinder, back under the engine to the silencer
        local ex = add(cyl(3.0), mul(cu, -1.25))
        local silA, silB = V(-13.6, -4.3, -0.4), V(-21.4, -4.4, -0.2)
        tube(Ch, { ex, add(ex, V(0.3, -0.4, -1.4)), V(-2.0, -1.9, -0.9), V(-7.5, -3.2, -1.1), V(-11.2, -4.2, -0.6), silA }, 0.5, 12, 5)
        local ax = norm(sub(silB, silA))
        local Ls = len(sub(silB, silA))
        lathe(Bk, { { 0.5, -0.3, true }, { 0.6, 0 }, { 1.25, 1.3 }, { 1.3, 1.8 }, { 1.3, Ls - 1.4 }, { 1.05, Ls - 0.3 }, { 0.4, Ls, true },
                    { 0.4, Ls + 0.8, true }, { 0.3, Ls + 0.8, true }, { 0, Ls + 0.7, true } }, silA, ax, 22)
        lathe(Ch, { { 1.31, 2.4, true }, { 1.33, 2.6 }, { 1.33, Ls - 2.2 }, { 1.31, Ls - 2.0, true } }, silA, ax, 22)
        -- the carburettor and the round air filter behind the cylinder
        local carb = V(-6.6, 0.6, 8.0)
        tube(Rb, { add(cyl(0.6), mul(cu, 1.1)), V(-5.0, 0.4, 7.2), carb }, 0.42, 10)
        lathe(Al, { { 0, -0.9, true }, { 0.7, -0.9, true }, { 0.75, -0.7 }, { 0.75, 0.7 }, { 0.7, 0.9, true }, { 0, 0.9, true } }, carb, norm(V(-1, 0.2, 0.3)), 14)
        lathe(Bk, { { 0, -0.9, true }, { 1.7, -0.9, true }, { 1.8, -0.7 }, { 1.8, 0.7 }, { 1.7, 0.9, true }, { 0, 0.9, true } }, V(-9.1, 1.0, 9.0), norm(V(-0.3, 1, 0.2)), 24)
        -- the fuel line down from the tank's tap
        tube(M:bucket("frame", "rubber"), { V(-14.2, 1.6, 14.6), V(-11.5, 1.8, 11.8), V(-7.6, 1.2, 8.8), carb }, 0.12, 6)
        lathe(Al, { { 0, 0, true }, { 0.4, 0, true }, { 0.4, 0.8, true }, { 0, 0.8, true } }, V(-14.4, 1.5, 15.2), Z, 10)
        -- the engine's hanger up to the spine
        slab(Pf, { { -7.4, 6.0 }, { -4.2, 6.0 }, { -1.8, 9.6 }, { -6.2, 12.0 } }, V(0, 1.5, 0), X, Z, 0.4, 0.1)
        slab(Pf, { { -7.4, 6.0 }, { -4.2, 6.0 }, { -1.8, 9.6 }, { -6.2, 12.0 } }, V(0, -1.5, 0), X, Z, 0.4, 0.1)
    end
    -- the belt: from the variator to the big pulley on the rear wheel, its arm
    -- (the engine's rear mount to the axle) outboard of it
    local BY = 2.85
    do
        local c1, r1, c2, r2 = { CC[1], CC[3] }, 2.0, { RA[1], RA[3] }, 4.0
        local dx, dz = c2[1] - c1[1], c2[2] - c1[2]
        local D = sqrt(dx * dx + dz * dz)
        local base = math.atan2(dz, dx)
        local beta = math.acos((r1 - r2) / D)
        local path = {}
        local function arc(c, r, a0, a1, n)
            for i = 0, n do
                local a = a0 + (a1 - a0) * i / n
                path[#path + 1] = V(c[1] + cos(a) * r, BY, c[2] + sin(a) * r)
            end
        end
        arc(c1, r1, base - beta + TAU, base + beta, 14)
        arc(c2, r2, base + beta, base - beta, 30)
        path[#path + 1] = path[1]
        sweep(Rb, path, function() return 0.18, 0.32 end, 6, { up = Y, capStart = false, capEnd = false })
        lathe(Al, { { 0.5, -0.45, true }, { 2.15, -0.45, true }, { 1.95, 0 }, { 2.15, 0.45, true }, { 0.5, 0.45, true } }, V(c1[1], BY, c1[2]), Y, 26)
        -- the arm: a pressed strip from the crankcase back to the axle
        local arm = { { -9.8, 5.6 }, { -6.0, 4.6 }, { -10.0, 2.4 }, { -22.0, -0.5 }, { -25.4, -1.0 }, { -25.6, 1.0 }, { -22.0, 1.4 } }
        slab(Pf, arm, V(0, 3.75, 0), X, Z, 0.4, 0.12)
    end

    ----------------------------------------------------------------------
    -- SADDLE on its post and springs; the rack with the tail light; fenders.
    ----------------------------------------------------------------------
    do
        local topAt = Sz + 2.0
        local xs = Sx - 0.5
        -- seat post from the spine, and the saddle's frame
        local post0, post1 = V(-12.2, 0, 16.0), V(xs + 1.6, 0, topAt - 2.5)
        sweep(Ch, { post0, post1 }, 0.55, 16, { capStart = false })
        lathe(Pf, { { 0.56, -0.5, true }, { 0.72, -0.45 }, { 0.72, 0.45 }, { 0.56, 0.5, true } }, lerp(post0, post1, 0.12), norm(sub(post1, post0)), 16)
        for _, sd in ipairs({ 1, -1 }) do
            tube(Ch, { add(post1, V(2.6, 0.6 * sd, 0.4)), add(post1, V(0.0, 0.9 * sd, 0.1)), V(xs - 3.0, 1.9 * sd, topAt - 2.5) }, 0.16, 8)
            -- the coil springs under the saddle's back
            local sb, stp = V(xs - 3.2, 1.9 * sd, topAt - 3.6), V(xs - 3.2, 1.9 * sd, topAt - 1.7)
            local coil = {}
            for i = 0, 48 do
                local tt = i / 48
                local a = tt * 7 * TAU
                coil[#coil + 1] = add(lerp(sb, stp, tt), V(cos(a) * 0.45, sin(a) * 0.45, 0))
            end
            sweep(Ch, coil, 0.08, 5)
            sweep(Ch, { add(sb, V(0, 0, -0.1)), add(sb, V(2.2, -0.9 * sd, 0.9)), add(post1, V(0, 0.4 * sd, 0)) }, 0.14, 8)
        end
        -- the saddle: a broad pan, padded, its nose narrow
        local R = {}
        local x0, x1 = xs - 5.0, xs + 5.4
        local function sw(t)
            local w = (t < 0.1) and (3.9 * sqrt(t / 0.1) * 0.7 + 1.2) or (4.1 - 2.6 * ((t - 0.1) / 0.9) ^ 1.4)
            if t > 0.95 then w = w * (0.55 + 0.45 * (1 - t) / 0.05) end
            return w
        end
        for i = 0, 16 do
            local t = i / 16
            local x = x0 + (x1 - x0) * t
            local w = sw(t)
            local zt = topAt - 0.25 * ((x - xs) / 5) ^ 2 + ((x > xs + 3) and (x - xs - 3) * 0.1 or 0)
            local zb = topAt - 2.3 + 0.2 * t
            if t < 0.04 or t > 0.97 then zt = zt - 0.5 end
            R[#R + 1] = ring(V(x, 0, (zt + zb) * 0.5), Y, Z, w, (zt - zb) * 0.5, 28, 2.8)
        end
        loft(M:bucket("frame", "seat"), R)
        -- the pan's chrome edge
        sheet(Ch, 12, 2, function(u, v)
            local t = 0.06 + u * 0.82
            return V(x0 + (x1 - x0) * t, (v * 2 - 1) * sw(t) * 0.92, topAt - 2.3 + 0.2 * t)
        end, 0.12, mul(Z, -1))
    end
    -- the rack over the tank and the rear wheel, its legs to the dropouts
    local rackZ = 20.6
    do
        for _, sd in ipairs({ 1, -1 }) do
            tube(Ch, { V(-17.0, 2.2 * sd, rackZ - 0.4), V(-19.0, 3.1 * sd, rackZ), V(-31.5, 3.1 * sd, rackZ), V(-33.6, 1.6 * sd, rackZ - 0.2) }, 0.28, 10, 5)
            tube(Ch, { V(-29.5, 3.1 * sd, rackZ), V(-28.4, 3.25 * sd, 12.0), V(-24.3, (sd > 0 and 3.75 or -3.25), 1.6) }, 0.24, 10, 5)
        end
        tube(Ch, { V(-33.6, 1.6, rackZ - 0.2), V(-34.2, 0, rackZ - 0.3), V(-33.6, -1.6, rackZ - 0.2) }, 0.28, 10, 3)
        tube(Ch, { V(-17.0, 2.2, rackZ - 0.4), V(-16.6, 0, rackZ - 0.5), V(-17.0, -2.2, rackZ - 0.4) }, 0.28, 10, 3)
        for _, x in ipairs({ -21.5, -24.5, -27.5, -30.5 }) do
            sweep(Ch, { V(x, -3.1, rackZ), V(x, 3.1, rackZ) }, 0.2, 8)
        end
        sweep(Ch, { V(-19.5, 0, rackZ - 0.05), V(-33.0, 0, rackZ - 0.05) }, 0.2, 8)
        -- the tail light: a chrome-rimmed red lamp at the rack's end, the plate under it
        local tl = V(-34.6, 0, rackZ - 1.9)
        slab(Pf, roundRect(3.0, 2.2, 0.8, 4), tl, Y, Z, 1.2, 0.3)
        slab(M:bucket("frame", "redlens"), roundRect(2.6, 1.8, 0.7, 4), add(tl, V(-0.65, 0, 0)), Y, Z, 0.3, 0.12)
        box(Pf, V(-33.9, 0, rackZ - 0.9), V(0.5, 0, 0), V(0, 0.6, 0), V(0, 0, 0.35))
        sheet(M:bucket("frame", "white"), 4, 4, function(u, v) return V(-34.4 - 0.2 * v, (u * 2 - 1) * 2.6, rackZ - 7.6 + v * 4.4) end, 0.08, mul(X, -1))
        slab(M:bucket("frame", "redlens"), circle(0.6, 14), V(-34.3, 0, rackZ - 8.3), Y, Z, 0.2, 0.06)
    end
    -- the rear fender, steel, close over the tyre under the rack
    sheet(Pf, 26, 6, function(u, v)
        local a = math.rad(25) + u * math.rad(140)
        local r = Rw + 0.9
        local wv = (v * 2 - 1) * 1.75
        local rr = r - 0.55 * (v * 2 - 1) ^ 2
        return V(RA[1] - cos(a) * rr, wv, sin(a) * rr)
    end, 0.08, function(p) return norm(V(p[1] - RA[1], 0, p[3])) end)

    ----------------------------------------------------------------------
    -- THE PEDAL DRIVE: the chainring is on the cranks; the chain (right) to the
    -- freewheel on the hub, its guard; the centre stand.
    ----------------------------------------------------------------------
    local CHY = -2.45
    local pitch = 0.5
    do
        local r1, r2 = pitch / (2 * sin(pi / 28)), pitch / (2 * sin(pi / 16))
        chainLoop(Std, { BB[1], BB[3] }, r1, { RA[1], RA[3] }, r2, CHY, pitch)
        -- the guard over the top run
        sheet(Pf, 16, 4, function(u, v)
            local p = lerp(V(BB[1] - 0.4, 0, BB[3] + r1 + 0.6), V(RA[1] + 2.6, 0, RA[3] + r2 + 0.55), u)
            local a = (v - 0.5) * pi * 0.9
            return V(p[1], CHY - sin(a) * 0.7, p[3] + cos(a) * 0.45)
        end, 0.06, Z)
    end
    -- the centre stand, folded up under the engine
    for _, sd in ipairs({ 1, -1 }) do
        tube(Bk, { V(-9.6, 2.4 * sd, 0.5), V(-12.6, 2.9 * sd, -0.8), V(-15.6, 3.0 * sd, -1.3) }, 0.26, 8, 3)
    end
    sweep(Bk, { V(-15.6, -3.0, -1.3), V(-15.6, 3.0, -1.3) }, 0.26, 8)
    sweep(St, { V(-9.6, -2.8, 0.5), V(-9.6, 2.8, 0.5) }, 0.22, 8)
    -- the rear brake's backing plate (left of the drum: it does not turn) and arm
    lathe(Al, { { 0.3, -0.12, true }, { 2.45, -0.12, true }, { 2.5, 0 }, { 2.45, 0.12, true }, { 0.3, 0.12, true } }, add(RA, V(0, -1.75, 0)), Y, 28)
    tube(Al, { add(RA, V(1.4, -1.95, 1.6)), add(RA, V(3.6, -2.15, 2.6)) }, function() return 0.22, 0.12 end, 8, 2, { up = Y })
    tube(Bk, { add(RA, V(3.6, -2.15, 2.6)), V(-14.0, -2.0, 6.2), V(-7.0, -1.8, 11.4), V(2.0, -1.6, 12.8), V(10.0, -1.2, 17.0) }, 0.1, 6, 6)
    sweep(St, { V(-24, -3.6, 0), V(-24, 4.1, 0) }, 0.3, 10)
    for _, y in ipairs({ -3.65, 4.15 }) do bolt(Std, V(-24, y, 0), mul(Y, y > 0 and 1 or -1), 0.4, 0.3) end

    ----------------------------------------------------------------------
    -- CRANKS (turn about the bottom bracket): steel arms, the chainring on the
    -- right; the pedals are rubber-block moped pedals.
    ----------------------------------------------------------------------
    do
        local Cb = M:bucket("cranks", "black")
        local Cc = M:bucket("cranks", "chrome")
        local Ccd = M:bucket("cranks", "chrome", true)
        sweep(M:bucket("cranks", "steel"), { add(BB, V(0, -Q + 0.3, 0)), add(BB, V(0, Q - 0.3, 0)) }, 0.36, 12)
        for _, sd in ipairs({ -1, 1 }) do
            local dir = (sd == -1) and X or mul(X, -1)
            local root = V(BB[1], (Q - 0.5) * sd, BB[3])
            local tipP = add(V(BB[1], Q * sd, BB[3]), mul(dir, CRANK))
            local P = {}
            for i = 0, 10 do
                local t = i / 10
                local c = lerp(root, tipP, t)
                P[#P + 1] = ring(c, Y, Z, 0.32 - 0.04 * t, 0.55 - 0.15 * t, 14, 3)
            end
            loft(Cc, P)
            lathe(Cc, { { 0, -0.36, true }, { 0.75, -0.36, true }, { 0.8, -0.25 }, { 0.8, 0.25 }, { 0.75, 0.36, true }, { 0, 0.36, true } }, root, Y, 18)
            lathe(Cc, { { 0, -0.3, true }, { 0.5, -0.3, true }, { 0.52, -0.2 }, { 0.52, 0.2 }, { 0.5, 0.3, true }, { 0, 0.3, true } }, tipP, Y, 14)
            -- the cotter pin
            sweep(Ccd, { add(root, V(-0.2, 0, 0.9)), add(root, V(-0.2, 0, -0.9)) }, 0.13, 6)
            -- the pedal spindle out to the pedal
            sweep(M:bucket("cranks", "steel"), { tipP, add(tipP, V(0, (1.8 + 0.25) * sd, 0)) }, 0.18, 8)
        end
        sprocket(Cb, Ccd, 28, pitch, BB[1], CHY, BB[3], 0.16, nil, 5, 1.0)
    end
    -- one pedal about its own centre: rubber blocks in a steel cage
    do
        local Pc = M:bucket("pedal", "steel")
        local Pr = M:bucket("pedal", "rubber")
        local w = 3.8
        sweep(Pc, { V(0, -w / 2, 0), V(0, w / 2, 0) }, 0.25, 10)
        for _, sd in ipairs({ 1, -1 }) do
            box(Pc, V(0, sd * (w / 2 - 0.12), 0), V(1.25, 0, 0), V(0, 0.12, 0), V(0, 0, 0.42))
        end
        for _, xo in ipairs({ -0.75, 0.75 }) do
            slab(Pr, roundRect(0.85, w - 0.4, 0.2, 2), V(xo, 0, 0), X, Y, 0.85, 0.12)
            for i = 0, 4 do
                box(Pr, V(xo, -1.4 + i * 0.7, 0.44), V(0.42, 0, 0), V(0, 0.08, 0), V(0, 0, 0.04))
                box(Pr, V(xo, -1.4 + i * 0.7, -0.44), V(0.42, 0, 0), V(0, 0.08, 0), V(0, 0, 0.04))
            end
        end
    end

    ----------------------------------------------------------------------
    -- FORK (steers): telescopic legs (painted shrouds over chrome sliders), the
    -- crown, the front fender, the drum's backing plate.
    ----------------------------------------------------------------------
    local FPf = M:bucket("fork", "paint")
    local FCh = M:bucket("fork", "chrome")
    local FAl = M:bucket("fork", "alloy")
    local FBk = M:bucket("fork", "black")
    local FStd = M:bucket("fork", "steel", true)
    local crown = madd(SP(17.6), fw, 0.8)
    slab(FPf, roundRect(2.6, 7.6, 1.2, 4), crown, fw, Y, 1.1, 0.25)
    sweep(FPf, { madd(SP(17.6), st, 0.4), madd(SP(26.6), st, 0.3) }, 0.55, 14)
    for _, sd in ipairs({ 1, -1 }) do
        lathe(FPf, { { 0, -0.02, true }, { 0.72, 0, true }, { 0.8, 0.2 }, { 0.75, 0.6 }, { 0.75, 8.6 }, { 0.62, 9.0, true }, { 0, 9.02, true } }, LP(9.4, sd), st, 18)
        lathe(FCh, { { 0, -0.6, true }, { 0.55, -0.6, true }, { 0.58, -0.3 }, { 0.58, 9.6 }, { 0, 9.6, true } }, LP(0.4, sd), st, 16)
        -- the axle lug (leading the leg)
        slab(FAl, roundRect(1.9, 1.1, 0.5, 3), add(madd(LP(0.0, sd), fw, -0.2), V(0, 0, 0)), fw, st, 0.6, 0.15)
        -- the fender stay
        tube(FCh, { madd(LP(3.0, sd), fw, -0.6), add(FA, V(-6.2, sd * 1.85, 9.6)) }, 0.12, 6)
    end
    sweep(M:bucket("fork", "steel"), { add(FA, V(0, -LEGY - 0.6, 0)), add(FA, V(0, LEGY + 0.6, 0)) }, 0.28, 10)
    for _, sd in ipairs({ 1, -1 }) do bolt(FStd, add(FA, V(0, sd * (LEGY + 0.6), 0)), mul(Y, sd), 0.38, 0.28) end
    lathe(FAl, { { 0.3, -0.12, true }, { 2.25, -0.12, true }, { 2.3, 0 }, { 2.25, 0.12, true }, { 0.3, 0.12, true } }, add(FA, V(0, -1.55, 0)), Y, 26)
    tube(FAl, { add(FA, V(-0.6, -1.75, 1.9)), add(FA, V(-1.6, -1.95, 3.6)) }, function() return 0.2, 0.11 end, 8, 2, { up = Y })
    -- the front fender: a steel guard over the tyre, crowned
    sheet(FPf, 24, 6, function(u, v)
        local a = math.rad(10) + u * math.rad(140)
        local r = Rw + 0.85
        local wv = (v * 2 - 1) * 1.65
        local rr = r - 0.5 * (v * 2 - 1) ^ 2
        return V(FA[1] + cos(a) * rr, wv, sin(a) * rr)
    end, 0.08, function(p) return norm(V(p[1] - FA[1], 0, p[3])) end)
    box(FPf, add(FA, V(-2.4, 0, Rw + 0.85)), V(0.9, 0, 0), V(0, 1.1, 0), V(0, 0, 0.22))

    ----------------------------------------------------------------------
    -- BARS (steer): the stem, swept-back chrome bars, grips, the two levers and
    -- the twist throttle, the headlight in its shell and the horn under it.
    ----------------------------------------------------------------------
    local BCh = M:bucket("bars", "chrome")
    local BChd = M:bucket("bars", "chrome", true)
    local BBk = M:bucket("bars", "black")
    local BPf = M:bucket("bars", "paint")
    local stemTop = madd(SP(30.4), fw, 0.0)
    sweep(BCh, { SP(26.4), stemTop }, 0.5, 14)
    lathe(BCh, { { 0, 0, true }, { 0.72, 0, true }, { 0.72, 1.1 }, { 0.6, 1.25, true }, { 0, 1.25, true } }, madd(stemTop, st, -0.8), st, 16)
    local barC = madd(stemTop, st, 0.1)
    local GX, GZ, GIN, GOUT = 8.0, 30.9, 9.6, 13.9
    do
        local function half(sd)
            return { barC, add(barC, V(0.1, 2.0 * sd, 0.15)), add(barC, V(-0.4, 4.6 * sd, 0.55)), V(GX + 1.4, 7.6 * sd, GZ - 0.35),
                     V(GX + 0.25, 9.0 * sd, GZ - 0.05), V(GX, 10.0 * sd, GZ), V(GX, (GOUT + 0.2) * sd, GZ) }
        end
        local l, r = half(1), half(-1)
        local all = {}
        for i = #r, 2, -1 do all[#all + 1] = r[i] end
        for i = 1, #l do all[#all + 1] = l[i] end
        sweep(BCh, spline(all, 6), 0.42, 14)
        lathe(BCh, { { 0, -0.9, true }, { 0.62, -0.9, true }, { 0.68, -0.8 }, { 0.68, 0.8 }, { 0.62, 0.9, true }, { 0, 0.9, true } }, barC, Y, 16)
        local Rbb = M:bucket("bars", "rubber")
        -- grips: the left a plain grip, the right on the twist throttle
        local function grip(sd)
            local A = V(GX, sd * GIN, GZ)
            local prof = { { 0.4, -0.1, true }, { 0.82, -0.1, true }, { 0.85, 0.05 }, { 0.62, 0.25, true } }
            local h = 0.3
            local gl = GOUT - GIN
            while h < gl - 0.3 do
                prof[#prof + 1] = { 0.62, h }
                prof[#prof + 1] = { 0.68, h + 0.12 }
                prof[#prof + 1] = { 0.62, h + 0.24 }
                h = h + 0.5
            end
            prof[#prof + 1] = { 0.72, gl - 0.1 }
            prof[#prof + 1] = { 0.66, gl, true }
            prof[#prof + 1] = { 0, gl + 0.02, true }
            lathe(Rbb, prof, A, mul(Y, sd), 16)
        end
        grip(1); grip(-1)
        lathe(BBk, { { 0.42, -0.5, true }, { 0.8, -0.5, true }, { 0.85, -0.35 }, { 0.85, 0.35 }, { 0.8, 0.5, true }, { 0.42, 0.5, true } }, V(GX, -(GIN - 0.45), GZ), Y, 16)
        -- levers: chrome blades with ball ends, cables down into the stem
        for _, sd in ipairs({ 1, -1 }) do
            local lb = handLever(BCh, BCh, V(GX + 0.05, sd * (GIN - 1.2), GZ), mul(Y, sd), norm(V(1, 0, -0.2)), 4.2, 0.45)
            tube(BBk, { add(lb, V(0.2, 0, 0.1)), V(GX + 2.2, sd * (GIN - 2.6), GZ - 0.6), add(barC, V(1.2, sd * 1.4, -0.9)), madd(SP(27.0), fw, 0.7) }, 0.11, 6, 5)
        end
        -- the start lever (decompressor) on the left, small
        handLever(BBk, BCh, V(GX + 0.4, GIN - 2.4, GZ - 0.05), Y, norm(V(0.3, 0, 1)), 1.6, 0.42)
    end
    -- the headlight: a painted shell on the bar's middle, a chrome rim, the lens
    do
        local lc = add(barC, V(2.1, 0, -0.9))
        lathe(BPf, { { 0, -2.0, true }, { 1.4, -1.9 }, { 2.05, -1.2 }, { 2.25, -0.3 }, { 2.25, 0.1, true }, { 0, 0.1, true } }, lc, X, 28)
        lathe(BCh, { { 1.95, 0.0, true }, { 2.32, 0.05 }, { 2.36, 0.25 }, { 2.2, 0.38, true }, { 1.95, 0.32, true } }, lc, X, 28)
        lathe(M:bucket("bars", "lens"), { { 0, 0.55, true }, { 0.9, 0.5 }, { 1.6, 0.42 }, { 2.0, 0.3, true } }, lc, X, 28)
        box(BPf, add(lc, V(-1.6, 0, 1.2)), V(1.0, 0, 0), V(0, 0.6, 0), V(0, 0, 0.35))
        -- the horn under it, its grille facing forward
        local hc = add(lc, V(-0.1, 0, -3.4))
        lathe(BBk, { { 0, -0.6, true }, { 1.2, -0.6, true }, { 1.3, -0.4 }, { 1.3, 0.1, true }, { 0, 0.1, true } }, hc, X, 22)
        lathe(BCh, { { 0, 0.1, true }, { 1.1, 0.1, true }, { 1.15, 0.2 }, { 0.9, 0.3 }, { 0, 0.32, true } }, hc, X, 22)
        for i = -2, 2 do box(BBk, add(hc, V(0.33, i * 0.35, 0)), V(0.02, 0, 0), V(0, 0.08, 0), V(0, 0, 0.75 - abs(i) * 0.12)) end
        box(BBk, add(hc, V(-0.9, 0, 1.4)), V(0.15, 0, 0), V(0, 0.4, 0), V(0, 0, 1.5))
    end

    ----------------------------------------------------------------------
    -- WHEELS: 17-inch spoked wheels on chrome rims, drum hubs; the rear with the
    -- belt pulley on its left and the pedal freewheel on its right.
    ----------------------------------------------------------------------
    local dimsF = G.WheelDims(Rw - 0.05, { width = 2.3, height = 2.25, rimDepth = 0.55, rimW = 1.3, flangeR = 2.4 })
    G.parts.wheel(M, "wheelF", dimsF, { tread = "file", wall = "rubber", rim = "chrome", spokes = 36, cross = 1, spokeR = 0.06,
                                         hubHalf = 1.6, hubShell = 2.3, hubRole = "alloy" })
    local dimsR = G.WheelDims(Rw - 0.05, { width = 2.4, height = 2.3, rimDepth = 0.55, rimW = 1.35, flangeR = 2.6 })
    G.parts.wheel(M, "wheelR", dimsR, { tread = "file", wall = "rubber", rim = "chrome", spokes = 36, cross = 1, spokeR = 0.06,
                                         hubHalf = 1.7, hubShell = 2.5, hubRole = "alloy", cog = false })
    do
        local W = M:bucket("wheelR", "alloy")
        local Wd = M:bucket("wheelR", "alloy", true)
        -- the belt's driven pulley: two cones and its hub to the shell
        lathe(W, { { 0.5, BY - 0.45, true }, { 4.15, BY - 0.45, true }, { 4.2, BY - 0.3 }, { 3.7, BY - 0.05, true }, { 3.7, BY + 0.05, true },
                   { 4.2, BY + 0.3 }, { 4.15, BY + 0.45, true }, { 0.5, BY + 0.45, true } }, V(0, 0, 0), Y, 36)
        lathe(W, { { 0.5, 1.6, true }, { 1.5, 1.6, true }, { 1.5, BY - 0.45, true }, { 0.5, BY - 0.45, true } }, V(0, 0, 0), Y, 20)
        for i = 0, 4 do
            local a = i / 5 * TAU
            bolt(Wd, V(cos(a) * 2.6, BY + 0.45, sin(a) * 2.6), Y, 0.16, 0.1)
        end
        -- the pedal freewheel on the right
        sprocket(M:bucket("wheelR", "steel"), nil, 16, pitch, 0, CHY, 0, 0.16, 0.75)
        lathe(M:bucket("wheelR", "steel"), { { 0.5, -1.7, true }, { 1.1, -1.7, true }, { 1.1, CHY + 0.1, true }, { 0.5, CHY + 0.1, true } }, V(0, 0, 0), Y, 18)
    end

    pruneEmpty(M)
    scaleGroups(M, f)
    local function gp(sd) return { A = V(GX, -GIN * sd, GZ), B = V(GX, -GOUT * sd, GZ) } end
    M.layout = scaleLayout({
        k = wb / 39, steer = st,
        headT = SP(26.2), headB = SP(18.6), stemTop = stemTop,
        rear = RA, front = FA,
        gripR = gp(1), gripL = gp(-1),
        bb = BB, crank = CRANK, pedalY = Q + 1.8,
        stand = V(-8.0, 2.6, 0.6),
    }, f)
    return M
end
G.RegisterKind("moped", buildMoped)
