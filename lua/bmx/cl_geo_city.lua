--[[--------------------------------------------------------------------------
    bmx/cl_geo_city.lua

    The models of the city bike, built in code (docs/MODELS.md).
    Kinds: city.

    A Dutch "omafiets": an upright lugged steel step-through with a double loop
    (a curved upper tube over a curved down tube), a long head tube and a quill
    gooseneck under swept-back North Road bars with brown grips, a sprung
    leather saddle, a closed chaincase, full mudguards with a white tip, a ring
    lock, a coaster-brake rear hub and a dynamo front hub, a rear rack with its
    lamp, a wicker basket on a frame-mounted (non-steering) front carrier, a
    lamp under it, 28 x 1.75 tyres with cream walls on chrome 36-hole rims, and
    a child seat over the rack (group "childSeat", drawn when switched on).

    Everything is built in real units round the registry's own sizes: the
    axles at -wb/2 and +wb/2, the saddle's top at seat + (-0.5, 0, 2).
----------------------------------------------------------------------------]]

BMX = BMX or {}
local G = BMX.BikeGeo
if not G then return end

local Vv = G.vec
local V, add, sub, mul, dot, cross, len, norm, lerp = Vv.V, Vv.add, Vv.sub, Vv.mul, Vv.dot, Vv.cross, Vv.len, Vv.norm, Vv.lerp
local rot = Vv.rot
local Pm = G.prim
local sweep, lathe, plate, ringPlate, box = Pm.sweep, Pm.lathe, Pm.plate, Pm.ringPlate, Pm.box
local roundRect, circle, bez3, spline, tri, grid, cap, bead = Pm.roundRect, Pm.circle, Pm.bez3, Pm.spline, Pm.tri, Pm.grid, Pm.cap, Pm.bead
local earclip, area2 = Pm.earclip, Pm.area2
local sqrt, sin, cos, pi, abs, max, min, floor = math.sqrt, math.sin, math.cos, math.pi, math.abs, math.max, math.min, math.floor
local TAU = pi * 2
local Y = V(0, 1, 0)

--------------------------------------------------------------------------
-- TOOLS (this file's own; the other cl_geo files keep theirs)
--------------------------------------------------------------------------

-- Outward 2D normals at each vertex of a closed profile; a repeated point is
-- a crease (each copy takes the normal of its own edge).
local function profNormals(prof)
    local m = #prof
    local ccw = area2(prof) > 0
    local EN = {}
    for i = 1, m do
        local p, q = prof[i], prof[i % m + 1]
        local du, dv = q[1] - p[1], q[2] - p[2]
        local l = sqrt(du * du + dv * dv)
        if l < 1e-9 then EN[i] = false
        else
            local nu, nv = dv / l, -du / l
            if not ccw then nu, nv = -nu, -nv end
            EN[i] = { nu, nv }
        end
    end
    local VN = {}
    for i = 1, m do
        local a, b = EN[(i - 2) % m + 1], EN[i]
        local n
        if a and b then n = { a[1] + b[1], a[2] + b[2] } else n = a or b or { 1, 0 } end
        local l = sqrt(n[1] * n[1] + n[2] * n[2])
        VN[i] = l > 1e-9 and { n[1] / l, n[2] / l } or (a or b)
    end
    return VN
end

-- A closed 2D profile carried through a list of frames { o, eu, ev } (the
-- profile's u along eu, v along ev). `prof` is a loop or a function(i, n)
-- giving one per frame (same point count). Ends capped unless opt.caps == false.
local function ext(B, frames, prof, opt)
    opt = opt or {}
    local n = #frames
    local P, N, PR = {}, {}, {}
    for i = 1, n do
        local f = frames[i]
        local pr = type(prof) == "function" and prof(i, n) or prof
        PR[i] = pr
        local vn = profNormals(pr)
        P[i], N[i] = {}, {}
        for j = 1, #pr do
            local q = pr[j]
            P[i][j] = add(f[1], add(mul(f[2], q[1]), mul(f[3], q[2])))
            N[i][j] = norm(add(mul(f[2], vn[j][1]), mul(f[3], vn[j][2])))
        end
    end
    grid(B, P, true, function() return V(0, 0, 0) end, N)
    if opt.caps ~= false then
        for _, e in ipairs({ { 1, 2 }, { n, n - 1 } }) do
            local i = e[1]
            local nn = norm(sub(frames[i][1], frames[e[2]][1]))
            for _, t3 in ipairs(earclip(PR[i])) do
                tri(B, P[i][t3[1]], P[i][t3[2]], P[i][t3[3]], nn, nn, nn)
            end
        end
    end
    return P
end

-- Parallel-transport frames along a path (as sweep makes them): { o, N, B }.
local function pathFrames(pts, up)
    local n = #pts
    local T = {}
    for i = 1, n do T[i] = norm(sub(pts[min(n, i + 1)], pts[max(1, i - 1)])) end
    local F = {}
    local N = Vv.perp(T[1], up)
    for i = 1, n do
        if i > 1 then
            local q = sub(N, mul(T[i], dot(N, T[i])))
            N = len(q) > 1e-6 and norm(q) or Vv.perp(T[i], up)
        end
        F[i] = { pts[i], N, cross(T[i], N) }
    end
    return F
end

-- A closed rounded rectangle resampled to n points evenly by length, starting
-- on the +u side's middle and running counter-clockwise.
local function rrLoop(hu, hv, rc, n, cu, cv)
    rc = min(rc, hu - 1e-3, hv - 1e-3)
    local dense = {}
    local segs = 10
    local corners = { { hu - rc, hv - rc, 0 }, { -hu + rc, hv - rc, 0.25 }, { -hu + rc, -hv + rc, 0.5 }, { hu - rc, -hv + rc, 0.75 } }
    dense[1] = { hu, 0 }
    for _, c in ipairs(corners) do
        for i = 0, segs do
            local a = (c[3] + i / segs * 0.25) * TAU
            dense[#dense + 1] = { c[1] + cos(a) * rc, c[2] + sin(a) * rc }
        end
    end
    dense[#dense + 1] = { hu, 0 }
    local cum = { 0 }
    for i = 2, #dense do
        cum[i] = cum[i - 1] + sqrt((dense[i][1] - dense[i - 1][1]) ^ 2 + (dense[i][2] - dense[i - 1][2]) ^ 2)
    end
    local total = cum[#cum]
    local out, k = {}, 2
    for i = 0, n - 1 do
        local s = i / n * total
        while k < #cum and cum[k] < s do k = k + 1 end
        local t = (s - cum[k - 1]) / max(cum[k] - cum[k - 1], 1e-9)
        out[#out + 1] = { (cu or 0) + dense[k - 1][1] + (dense[k][1] - dense[k - 1][1]) * t,
                          (cv or 0) + dense[k - 1][2] + (dense[k][2] - dense[k - 1][2]) * t }
    end
    return out
end

-- A closed tube round a loop of points (the first is not repeated).
local function ringTube(B, pts, r, sides, opt)
    local p = {}
    for i = 1, #pts do p[i] = pts[i] end
    p[#p + 1] = pts[1]
    opt = opt or {}
    opt.capStart, opt.capEnd = false, false
    return sweep(B, p, r, sides, opt)
end

-- A hex bolt head (detail) at `p` facing `n`.
local function bolt(B, p, n, r, h)
    r, h = r or 0.14, h or 0.12
    lathe(B, { { 0, 0, true }, { r, 0, true }, { r, h * 0.8 }, { r * 0.7, h, true }, { 0, h, true } }, p, n, 6, { flat = true })
end

-- A helix (a coil spring) from a to b, radius rc, wire rw, `turns`.
local function coil(B, a, b, rc, rw, turns, sides)
    local ax = sub(b, a)
    local L = len(ax)
    local d = norm(ax)
    local e1 = Vv.perp(d, V(1, 0, 0))
    local e2 = cross(d, e1)
    local pts = {}
    local n = floor(turns * 14)
    for i = 0, n do
        local t = i / n
        local an = t * turns * TAU
        pts[#pts + 1] = add(add(a, mul(d, L * t)), add(mul(e1, cos(an) * rc), mul(e2, sin(an) * rc)))
    end
    sweep(B, pts, rw, sides or 6)
end

-- A mudguard: a C-section shell round `axle` at radius rg from angle a0 to a1
-- (in the x/z plane, 0 = forward, pi/2 = up), w half wide, its edges rolled
-- down by `curl`. Returns a function giving a point on its centreline.
local function mudguard(B, axle, rg, a0, a1, w, curl, opt)
    opt = opt or {}
    local t = opt.t or 0.07
    local prof = {}
    local nv = 7
    -- outer surface from -w to w, then the inner back, the edges rolled
    for i = 0, nv do
        local v = -w + 2 * w * i / nv
        local q = v / w
        prof[#prof + 1] = { -curl * q * q * q * q, v }
    end
    for i = nv, 0, -1 do
        local v = -w + 2 * w * i / nv
        local q = v / w
        prof[#prof + 1] = { -curl * q * q * q * q - t, v * (1 - t / w) }
    end
    local n = opt.segs or 48
    local frames = {}
    for i = 0, n do
        local a = a0 + (a1 - a0) * i / n
        local rad = V(cos(a), 0, sin(a))
        frames[#frames + 1] = { add(axle, mul(rad, rg)), rad, Y }
    end
    ext(B, frames, prof)
    -- the rolled edges
    if opt.bead ~= false then
        for _, s in ipairs({ 1, -1 }) do
            local pts = {}
            for i = 0, n do
                local a = a0 + (a1 - a0) * i / n
                local rad = V(cos(a), 0, sin(a))
                pts[#pts + 1] = add(add(axle, mul(rad, rg - curl - 0.02)), V(0, w * s, 0))
            end
            sweep(opt.beadB or B, pts, t * 0.9, 5)
        end
    end
    return function(a, side, drop)
        local rad = V(cos(a), 0, sin(a))
        return add(add(axle, mul(rad, rg - (drop or 0))), V(0, (side or 0), 0))
    end
end

-- 2D convex hull (monotone chain) of {u, v} points, counter-clockwise.
local function hull2(pts)
    table.sort(pts, function(a, b) return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2]) end)
    local function crs(o, a, b) return (a[1] - o[1]) * (b[2] - o[2]) - (a[2] - o[2]) * (b[1] - o[1]) end
    local lower, upper = {}, {}
    for _, p in ipairs(pts) do
        while #lower >= 2 and crs(lower[#lower - 1], lower[#lower], p) <= 0 do lower[#lower] = nil end
        lower[#lower + 1] = p
    end
    for i = #pts, 1, -1 do
        local p = pts[i]
        while #upper >= 2 and crs(upper[#upper - 1], upper[#upper], p) <= 0 do upper[#upper] = nil end
        upper[#upper + 1] = p
    end
    lower[#lower] = nil
    upper[#upper] = nil
    for _, p in ipairs(upper) do lower[#lower + 1] = p end
    return lower
end

-- A city tyre's tread: rows of fine slanted blocks either side of a plain
-- centre, on the casing G.parts.wheel built (its profile, as tyreProfile has it).
local function cityTread(M, group, R, n)
    local K = M:bucket(group, "rubber", true)
    local c = (R.outer + R.bead) * 0.5 + 0.05 * R.s
    local a = R.outer - c
    local b = R.tyreW * 0.5
    for ri, yf in ipairs({ -0.5, -0.22, 0.22, 0.5 }) do
        local y = yf * b
        local tt = math.asin(max(-1, min(1, y / b)))
        local rr = c + cos(tt) * a
        local nr, ny = cos(tt) / a, sin(tt) / b
        local nl = sqrt(nr * nr + ny * ny)
        nr, ny = nr / nl, ny / nl
        local m = (abs(yf) < 0.3) and n or floor(n * 0.75)
        for i = 0, m - 1 do
            local ang = (i + (ri % 2) * 0.5) / m * TAU
            local rad = V(cos(ang), 0, sin(ang))
            local tang = V(-sin(ang), 0, cos(ang))
            local nrm = norm(add(mul(rad, nr), V(0, ny, 0)))
            local side = norm(cross(nrm, tang))
            local h = 0.05
            local ctr = add(add(mul(rad, rr - 0.015), V(0, y, 0)), mul(nrm, h * 0.5))
            local sk = (yf < 0) and 0.5 or -0.5
            box(K, ctr, add(mul(tang, 0.11), mul(side, sk * 0.11)), mul(side, 0.12), mul(nrm, h * 0.5))
        end
    end
end

--------------------------------------------------------------------------
-- THE CITY BIKE
--------------------------------------------------------------------------
G.RegisterKind("city", function(opt, G)
    local M = Pm.newModel()
    local wb = opt.wheelbase or 52
    local R = opt.radius or 14
    local k = opt.k or wb / 39
    local seat = opt.seat or { -14, 0, 24 }
    local rear, front = V(-wb / 2, 0, 0), V(wb / 2, 0, 0)
    local sit = V(seat[1] - 0.5, 0, seat[3] + 2.0)          -- the saddle's top, where the rider sits
    local bb = V(-4.5 * k, 0, 2.5 * k)

    local P = M:bucket("frame", "paint")
    local C = M:bucket("frame", "chrome")
    local Cd = M:bucket("frame", "chrome", true)
    local Bk = M:bucket("frame", "black")
    local Bkd = M:bucket("frame", "black", true)

    ------------------------------------------------------------------
    -- GEOMETRY: a slack 67 degree head, a long head tube, the fork's rake
    ------------------------------------------------------------------
    local ha = math.rad(67)
    local u = V(-cos(ha), 0, sin(ha))                 -- up the steer axis
    local fwdP = V(sin(ha), 0, cos(ha))               -- forward, square to it
    local rake = 2.8
    local foot = sub(front, mul(fwdP, rake))          -- the axle's foot on the steer line
    local crownT = sqrt((R + 2.3) ^ 2 - rake * rake)
    local crown = add(foot, mul(u, crownT))
    local headB = add(crown, mul(u, 0.65))
    local headT = add(headB, mul(u, 10.0))
    local stemTop = add(headT, mul(u, 6.4))
    local clamp = add(stemTop, V(2.9, 0, 1.3))
    -- seat tube: from the bb toward the saddle
    local stDir = norm(sub(add(sit, V(0.9, 0, -3.0)), bb))
    local function onST(z) return add(bb, mul(stDir, (z - bb[3]) / stDir[3])) end
    local stTop = onST(sit[3] - 7.2)
    local postTop = onST(sit[3] - 2.75)
    local RD = G.WheelDims(R, { width = 1.75 })
    local hubR, hubF = 2.3, 1.95                      -- half the dropout spacing

    ------------------------------------------------------------------
    -- FRAME: lugged steel, a double loop
    ------------------------------------------------------------------
    local rHT, rDT, rLoop, rST = 0.8, 0.74, 0.62, 0.68
    -- head tube with its lug sleeves and the headset cups
    do
        local h1 = 10.0
        lathe(P, { { 0, -0.02, true }, { 0.92, 0, true }, { 0.95, 0.1 }, { 0.95, 1.4 }, { rHT, 1.75 }, { rHT, h1 - 1.75 },
                   { 0.95, h1 - 1.4 }, { 0.95, h1 - 0.1 }, { 0.92, h1, true }, { 0, h1 + 0.02, true } }, headB, u, 28)
        for _, e in ipairs({ { headB, -1 }, { headT, 1 } }) do
            lathe(C, { { 0.6, 0, true }, { 0.98, 0, true }, { 1.0, 0.1 }, { 0.98, 0.32, true }, { 0.6, 0.32, true } },
                  e[1], mul(u, e[2]), 28)
        end
    end
    -- the head badge riveted to the head tube's front
    do
        local bc = add(add(headB, mul(u, 5.6)), mul(fwdP, rHT - 0.04))
        local bl = {}
        for i = 0, 19 do
            local a = i / 20 * TAU
            bl[#bl + 1] = { cos(a) * 1.2, sin(a) * 0.46 }
        end
        plate(M:bucket("frame", "alloy"), bl, bc, u, Y, 0.14)
        for _, q in ipairs({ 1.0, -1.0 }) do
            lathe(Cd, { { 0, 0, true }, { 0.1, 0, true }, { 0.07, 0.06 }, { 0, 0.07, true } }, add(add(bc, mul(u, q)), mul(fwdP, 0.07)), fwdP, 8)
        end
    end
    -- bottom bracket shell
    lathe(P, { { 0, -1.45, true }, { 0.95, -1.45, true }, { 1.0, -1.3 }, { 1.0, 1.3 }, { 0.95, 1.45, true }, { 0, 1.45, true } }, bb, Y, 28)
    -- the down tube: from low on the head tube, swooping to the bb
    local H1 = add(headB, mul(u, 1.7))
    local dtPts = bez3(H1, add(H1, V(-5.2, 0, -4.6)), add(bb, V(7.5, 0, 0.9)), bb, 26)
    sweep(P, dtPts, rDT, 22, { capStart = false, capEnd = false })
    -- the upper loop: from high on the head tube, parallel to it, into the seat tube
    local H2 = sub(headT, mul(u, 1.5))
    local S1 = onST(bb[3] + 6.6)
    local lpPts = bez3(H2, add(H2, V(-4.6, 0, -5.4)), add(S1, V(8.6, 0, 1.6)), S1, 26)
    sweep(P, lpPts, rLoop, 20, { capStart = false, capEnd = false })
    -- seat tube
    sweep(P, { sub(bb, mul(stDir, 0.4)), stTop }, rST, 20, { capStart = false })
    -- lugs: sleeves where the tubes meet
    local function lug(pts, atEnd, r, l)
        local a = atEnd and pts[#pts] or pts[1]
        local b = atEnd and pts[#pts - 2] or pts[3]
        local d = norm(sub(b, a))
        lathe(P, { { r + 0.02, 0, true }, { r + 0.13, 0.05 }, { r + 0.13, l - 0.35 }, { r + 0.02, l, true } }, a, d, 22)
    end
    lug(dtPts, false, rDT, 2.2)
    lug(lpPts, false, rLoop, 2.0)
    lug(lpPts, true, rLoop, 1.7)
    -- seat lug with its binder bolt
    lathe(P, { { rST, -1.4, true }, { rST + 0.15, -1.3 }, { rST + 0.17, 0.2 }, { rST + 0.13, 0.42, true }, { 0.58, 0.42, true } }, stTop, stDir, 22)
    local back = norm(cross(Y, stDir))
    if back[1] > 0 then back = mul(back, -1) end
    do
        local bp = add(sub(stTop, mul(stDir, 0.5)), mul(back, rST + 0.35))
        box(P, bp, mul(back, 0.3), V(0, 0.42, 0), mul(stDir, 0.32))
        lathe(Cd, { { 0, -0.6, true }, { 0.12, -0.6, true }, { 0.12, 0.6, true }, { 0.2, 0.6, true }, { 0.2, 0.82, true }, { 0, 0.82, true } }, bp, Y, 6, { flat = true })
    end

    -- rear triangle: chain stays and seat stays to horizontal dropouts
    local dropY = hubR + 0.15
    local function chainStay(s)
        local a = add(bb, V(-0.6, 1.05 * s, -0.1))
        local b = add(rear, V(1.2, dropY * s, 0.15))
        return bez3(a, add(a, V(-4, 0.5 * s, -0.4)), add(b, V(5, 0, 0.3)), b, 16)
    end
    local function seatStay(s)
        local a = add(sub(stTop, mul(stDir, 0.55)), V(-0.45, 0.62 * s, 0))
        local b = add(rear, V(0.75, dropY * s, 0.95))
        return bez3(a, add(lerp(a, b, 0.3), V(0, 0.9 * s, 0)), add(lerp(a, b, 0.7), V(0, 0.25 * s, 0)), b, 18)
    end
    for _, s in ipairs({ 1, -1 }) do
        sweep(P, chainStay(s), function(t) return 0.46 - 0.1 * t, 0.52 - 0.14 * t end, 16, { up = V(0, 0, 1), capStart = false })
        sweep(P, seatStay(s), function(t) return 0.42 - 0.1 * t end, 16, { capStart = false })
        -- dropout: horizontal, the slot opening back, with a mudguard/rack eyelet
        local loop = {}
        local function at(du, dv) loop[#loop + 1] = { rear[1] + du, rear[3] + dv } end
        at(-1.6, 0.3); at(0.4, 0.3)
        for i = 1, 7 do local a = pi / 2 - i / 8 * pi at(0.4 + cos(a) * 0.3, sin(a) * 0.3) end
        at(0.4, -0.3); at(-1.6, -0.3)
        at(-1.6, -0.75); at(-0.4, -1.05); at(1.2, -0.85); at(2.1, -0.1); at(1.95, 0.9)
        at(1.3, 1.6); at(0.3, 1.6); at(-0.6, 1.1); at(-1.5, 0.95)
        plate(P, loop, V(0, dropY * s, 0), V(1, 0, 0), V(0, 0, 1), 0.26)
    end
    -- the bridges: seat stays and chain stays
    do
        local l, r = seatStay(1), seatStay(-1)
        sweep(P, { l[6], r[6] }, 0.3, 12, { capStart = false, capEnd = false })
        local cl, cr = chainStay(1), chainStay(-1)
        sweep(P, { cl[5], cr[5] }, 0.3, 12, { capStart = false, capEnd = false })
    end

    -- rear axle, nuts, and the coaster brake's reaction arm (left)
    sweep(M:bucket("frame", "steel"), { add(rear, V(0, -dropY - 0.7, 0)), add(rear, V(0, dropY + 0.7, 0)) }, 0.22, 10)
    for _, s in ipairs({ 1, -1 }) do
        lathe(Cd, { { 0.22, 0, true }, { 0.42, 0, true }, { 0.42, 0.34, true }, { 0.22, 0.34, true } },
              add(rear, V(0, (dropY + 0.16) * s, 0)), V(0, s, 0), 6, { flat = true })
    end
    do
        local cs = chainStay(1)
        local clipAt = cs[11]
        local a = add(rear, V(0, dropY - 0.3, 0))
        local arm = { add(a, V(-0.2, 0, 0)), add(a, V(3.2, 0, 0.35)), add(clipAt, V(0, -0.05, -0.55)) }
        sweep(Bk, spline(arm, 4), function() return 0.32, 0.08 end, 8, { up = V(0, 1, 0) })
        lathe(Bk, { { 0, -0.1, true }, { 0.75, -0.1, true }, { 0.75, 0.1, true }, { 0, 0.1, true } }, a, Y, 18)
        lathe(Bk, { { 0.35, -0.35, true }, { 0.55, -0.35, true }, { 0.55, 0.35, true }, { 0.35, 0.35, true } }, clipAt, norm(sub(cs[12], cs[10])), 12)
    end

    ------------------------------------------------------------------
    -- CHAINCASE: closed, painted, round the ring and the rear sprocket
    ------------------------------------------------------------------
    do
        local rr1, rr2 = 3.75, 2.35
        local pts = {}
        for i = 0, 47 do
            local a = i / 48 * TAU
            pts[#pts + 1] = { bb[1] + cos(a) * rr1, bb[3] + sin(a) * rr1 }
            pts[#pts + 1] = { rear[1] + cos(a) * rr2, rear[3] + sin(a) * rr2 }
        end
        local hl = hull2(pts)
        -- top and bottom of the outline at x
        local function span(x)
            local lo, hi = math.huge, -math.huge
            for i = 1, #hl do
                local p, q = hl[i], hl[i % #hl + 1]
                if (p[1] - x) * (q[1] - x) <= 0 and abs(q[1] - p[1]) > 1e-9 then
                    local t = (x - p[1]) / (q[1] - p[1])
                    local z = p[2] + (q[2] - p[2]) * t
                    lo, hi = min(lo, z), max(hi, z)
                end
            end
            return lo, hi
        end
        local x0, x1 = rear[1] - rr2 + 0.02, bb[1] + rr1 - 0.02
        local n = 40
        local frames, profs = {}, {}
        for i = 0, n do
            local tt = i / n
            local x = x0 + (x1 - x0) * (0.5 - 0.5 * cos(tt * pi))
            local lo, hi = span(x)
            if lo > hi then lo, hi = 0, 0 end
            local zc, hz = (lo + hi) * 0.5, max((hi - lo) * 0.5, 0.05)
            -- inner wall: wide at the ring, narrow at the rear
            local f = (x - rear[1]) / (bb[1] - rear[1])
            local yo, yi = -2.95, -2.25 + (-1.5 + 2.25) * max(0, min(1, (f - 0.25) / 0.6))
            local hy = (yo - yi) * 0.5
            local yc = (yo + yi) * 0.5
            frames[#frames + 1] = { V(x, yc, zc), V(0, 0, 1), V(0, 1, 0) }
            local rc = min(0.32, hz * 0.95, abs(hy) * 0.95)
            profs[#profs + 1] = rrLoop(hz, abs(hy), rc, 28)
        end
        ext(P, frames, function(i) return profs[i] end)
        -- the dome over the chainring and the crank's grommet
        lathe(P, { { 2.6, 0, true }, { 2.5, 0.12 }, { 2.0, 0.24 }, { 1.0, 0.3, true }, { 0, 0.3, true } }, V(bb[1], -2.93, bb[3]), V(0, -1, 0), 32)
        lathe(Bk, { { 0.55, 0, true }, { 0.85, 0, true }, { 0.85, 0.4, true }, { 0.55, 0.4, true } }, V(bb[1], -2.95, bb[3]), V(0, -1, 0), 20)
        -- its fixing screws
        for _, q in ipairs({ { -3.0, 2.8 }, { -12, 1.45 }, { -20, 0.6 } }) do
            local x = bb[1] + q[1]
            local lo, hi = span(x)
            bolt(Cd, V(x, -2.95, hi - 0.45), V(0, -1, 0), 0.12, 0.1)
        end
    end

    ------------------------------------------------------------------
    -- SEAT POST AND THE SPRUNG LEATHER SADDLE
    ------------------------------------------------------------------
    do
        sweep(C, { sub(stTop, mul(stDir, 2.0)), postTop }, 0.56, 18, { capStart = false })
        -- the clamp: a cradle round the rails
        local cl = add(postTop, mul(stDir, 0.25))
        lathe(Bk, { { 0, -0.6, true }, { 0.62, -0.6, true }, { 0.66, -0.45 }, { 0.66, 0.3 }, { 0.55, 0.42, true }, { 0, 0.42, true } }, postTop, stDir, 18)
        box(Bk, add(cl, V(0, 0, 0.35)), V(0.55, 0, 0), V(0, 1.05, 0), V(0, 0, 0.18))
        bolt(Cd, add(cl, V(0, 1.05, 0.35)), Y, 0.18, 0.15)
        bolt(Cd, add(cl, V(0, -1.05, 0.35)), V(0, -1, 0), 0.18, 0.15)
        local railZ = cl[3] + 0.38
        -- leather top: lofted, a broad tail, a slim nose, deep skirts
        local L = M:bucket("frame", "leather")
        local back, nose = 3.9, 6.8
        local st, ring = 18, 24
        local Pr = {}
        for i = 0, st do
            local t = i / st
            local x = -back + t * (back + nose)
            local w
            if t < 0.07 then w = 3.95 * sqrt(max(0.02, t / 0.07)) + 0.05
            elseif t < 0.35 then w = 4.0 - (t - 0.07) / 0.28 * 0.35
            else w = 3.65 - 2.85 * min(1, ((t - 0.35) / 0.55)) ^ 0.85 end
            if t > 0.95 then w = w * sqrt(max(0.05, (1 - t) / 0.05)) end
            w = max(w, 0.06)
            local topz = sit[3] - 0.025 * x * x * (x < 0 and 1.2 or 0.25) + (t > 0.85 and -0.25 * (t - 0.85) / 0.15 or 0)
            local h = 1.15 - 0.3 * t
            if t < 0.03 or t > 0.97 then h = h * 0.5 end
            Pr[#Pr + 1] = {}
            for j = 0, ring - 1 do
                local a = j / ring * TAU
                local ca, sa = cos(a), sin(a)
                local e = 3.2
                local cy = (abs(ca) ^ (2 / e)) * (ca < 0 and -1 or 1)
                local cz = (abs(sa) ^ (2 / e)) * (sa < 0 and -1 or 1)
                local z
                if cz > 0 then z = topz - (1 - cz) * h * 0.55 - 0.18 * cy * cy
                else z = topz - h * 0.55 - (-cz) * h * 0.5 end
                Pr[#Pr][j + 1] = V(sit[1] + x, cy * w, z)
            end
        end
        grid(L, Pr, true, function(i)
            local s = V(0, 0, 0)
            for _, p in ipairs(Pr[i]) do s = add(s, p) end
            return mul(s, 1 / #Pr[i])
        end)
        cap(L, Pr[1], V(-1, 0, 0))
        cap(L, Pr[#Pr], V(1, 0, 0))
        -- the cantle plate and its rivets
        local cz0 = sit[3] - 1.3
        local cant = {}
        for i = 0, 12 do
            local a = pi * i / 12
            cant[#cant + 1] = { -cos(a) * 3.3, sin(a) * 0.55 }
        end
        for i = 12, 0, -1 do
            local a = pi * i / 12
            cant[#cant + 1] = { -cos(a) * 3.1, sin(a) * 0.45 - 0.35 }
        end
        local tail = sit[1] - back + 0.32
        plate(Bk, cant, V(tail - 0.1, 0, cz0 + 0.42), V(0, 1, 0), V(0, 0, 1), 0.16)
        for i = -2, 2 do
            local y = i * 1.35
            lathe(Cd, { { 0, 0, true }, { 0.16, 0, true }, { 0.12, 0.08 }, { 0, 0.1, true } },
                  V(tail - 0.2, y, sit[3] - 0.55 - 0.025 * y * y), V(-1, 0, 0), 10)
        end
        lathe(Cd, { { 0, 0, true }, { 0.18, 0, true }, { 0.13, 0.09 }, { 0, 0.11, true } }, V(sit[1] + nose - 0.25, 0, sit[3] - 0.35), V(1, 0, 0), 10)
        -- the springs at the back and the wire frame
        local sx = sit[1] - back + 1.0
        for _, s in ipairs({ 1, -1 }) do
            local ya = 2.25 * s
            local bot, topP = V(sx, ya, railZ - 0.25), V(sx, ya, cz0 + 0.1)
            coil(C, bot, topP, 0.42, 0.085, 7, 6)
            -- the rail: spring foot forward through the clamp to the nose
            local rail = spline({ bot, V(cl[1] - 1.0, 0.75 * s, railZ), V(cl[1] + 1.2, 0.7 * s, railZ),
                                  V(sit[1] + nose - 1.6, 0.35 * s, sit[3] - 0.95), V(sit[1] + nose - 0.6, 0.12 * s, sit[3] - 0.6) }, 5)
            sweep(C, rail, 0.11, 8)
            -- the upper frame wire: spring top to the cantle and the nose
            sweep(C, spline({ topP, V(sx + 1.6, 1.7 * s, cz0 + 0.2), V(sit[1] + nose - 1.8, 0.45 * s, sit[3] - 0.75),
                              V(sit[1] + nose - 0.55, 0.12 * s, sit[3] - 0.55) }, 5), 0.1, 8)
            lathe(C, { { 0, -0.12, true }, { 0.55, -0.12, true }, { 0.55, 0.12, true }, { 0, 0.12, true } }, topP, V(0, 0, 1), 14)
        end
        sweep(C, { V(sx, 2.25, cz0 + 0.1), V(sx, -2.25, cz0 + 0.1) }, 0.12, 8)
        sweep(C, { V(sx, 2.25, railZ - 0.25), V(sx, -2.25, railZ - 0.25) }, 0.12, 8)
    end

    ------------------------------------------------------------------
    -- REAR MUDGUARD, RING LOCK, RACK AND ITS LAMP
    ------------------------------------------------------------------
    local rgR = RD.outer + 0.65
    local rackZ = R + 2.9
    do
        local MG = M:bucket("frame", "paint")
        local g = mudguard(MG, rear, rgR, math.rad(-24), math.rad(178), 1.4, 0.5, { segs = 56 })
        -- the white tip, low at the back
        mudguard(M:bucket("frame", "white"), rear, rgR + 0.012, math.rad(178), math.rad(206), 1.41, 0.5, { segs = 10 })
        -- reflector on the tip
        local ra = math.rad(192)
        local rc = g(ra, 0, -0.08)
        local rn = V(cos(ra), 0, sin(ra))
        local rt = V(-sin(ra), 0, cos(ra))
        local rr = roundRect(1.5, 1.05, 0.25, 3)
        plate(M:bucket("frame", "redlens"), rr, add(rc, mul(rn, 0.12)), Y, rt, 0.16)
        -- stays: a pair each side from the guard's edge to the dropout eyelets
        for _, s in ipairs({ 1, -1 }) do
            for _, a in ipairs({ math.rad(140), math.rad(196) }) do
                local p = g(a, 1.25 * s, 0.55)
                local e = add(rear, V(-1.0, (dropY + 0.25) * s, -0.55))
                sweep(Cd, { p, e }, 0.085, 6)
            end
        end
        -- the guard's front end clipped to the chain stay bridge
        local cl, cr = chainStay(1), chainStay(-1)
        local fb = lerp(cl[5], cr[5], 0.5)
        sweep(Bkd, { g(math.rad(-26), 0, 0.3), add(fb, V(-0.3, 0, 0.1)) }, 0.12, 6)
    end
    -- ring lock round the tyre, on the seat stays
    do
        local a0, a1 = math.rad(58), math.rad(86)
        local w = 1.45
        local ro = rgR + 0.55
        -- an inverted U: two cheeks and a top band, u radial, v lateral
        local pts = { { -2.3, -w }, { 0.35, -w }, { 0.55, -w + 0.2 }, { 0.55, w - 0.2 }, { 0.35, w }, { -2.3, w },
                      { -2.3, w - 0.35 }, { -0.1, w - 0.35 }, { -0.1, -w + 0.35 }, { -2.3, -w + 0.35 } }
        local frames = {}
        for i = 0, 16 do
            local a = a0 + (a1 - a0) * i / 16
            local rad = V(cos(a), 0, sin(a))
            frames[#frames + 1] = { add(rear, mul(rad, ro)), rad, Y }
        end
        ext(Bk, frames, pts)
        -- the key barrel on the right cheek
        local am = (a0 + a1) * 0.5
        local kp = add(add(rear, mul(V(cos(am), 0, sin(am)), ro - 0.9)), V(0, -w - 0.02, 0))
        lathe(Cd, { { 0, 0, true }, { 0.32, 0, true }, { 0.32, 0.18 }, { 0.2, 0.22, true }, { 0, 0.22, true } }, kp, V(0, -1, 0), 14)
        -- its brackets to the seat stays
        for _, s in ipairs({ 1, -1 }) do
            local ss = seatStay(s)
            local p = ss[11]
            local q = add(add(rear, mul(V(cos(am), 0, sin(am)), ro - 1.2)), V(0, w * s, 0))
            sweep(Bk, { q, p }, function() return 0.28, 0.08 end, 8, { up = V(1, 0, 0) })
        end
    end
    -- the rear rack: tubular, chromed, on the dropouts and the seat stays
    local rack = {}
    do
        local RkB = M:bucket("frame", "chrome")
        local xF, xB = stTop[1] - 2.2, rear[1] - 10.2
        local hw = 3.2
        rack.xF, rack.xB, rack.z, rack.hw = xF, xB, rackZ, hw
        -- the top: a U round the back, two inner rails, cross bars
        local outline = {}
        local nb = 10
        outline[#outline + 1] = V(xF, hw, rackZ)
        outline[#outline + 1] = V(xB + hw * 0.6, hw, rackZ)
        for i = 1, nb - 1 do
            local a = pi / 2 + i / nb * pi
            outline[#outline + 1] = V(xB + hw * 0.6 + cos(a) * hw * 0.6, sin(a) * hw, rackZ)
        end
        outline[#outline + 1] = V(xB + hw * 0.6, -hw, rackZ)
        outline[#outline + 1] = V(xF, -hw, rackZ)
        sweep(RkB, spline(outline, 3), 0.26, 12)
        for _, y in ipairs({ 1.1, -1.1 }) do
            sweep(RkB, { V(xF + 0.4, y, rackZ), V(xB + 0.2, y, rackZ) }, 0.19, 10)
        end
        for _, x in ipairs({ xF + 0.6, lerp(V(xF, 0, 0), V(xB, 0, 0), 0.38)[1], lerp(V(xF, 0, 0), V(xB, 0, 0), 0.72)[1] }) do
            sweep(RkB, { V(x, hw, rackZ - 0.05), V(x, -hw, rackZ - 0.05) }, 0.2, 10, { capStart = false, capEnd = false })
        end
        -- the spring clip ("snelbinder") on top
        local Sk = M:bucket("frame", "black")
        for _, y in ipairs({ 2.2, 0, -2.2 }) do
            sweep(Sk, { V(xF + 1.4, y, rackZ + 0.32), V(xB + 1.5, y, rackZ + 0.32) }, 0.12, 8)
        end
        sweep(Sk, { V(xF + 1.4, 2.4, rackZ + 0.32), V(xF + 1.4, -2.4, rackZ + 0.32) }, 0.2, 8)
        -- stays: three each side to the dropout
        for _, s in ipairs({ 1, -1 }) do
            local foot = add(rear, V(-0.9, (dropY + 0.32) * s, -0.75))
            for _, x in ipairs({ xB + 1.2, lerp(V(xF, 0, 0), V(xB, 0, 0), 0.62)[1], lerp(V(xF, 0, 0), V(xB, 0, 0), 0.3)[1] }) do
                sweep(RkB, { V(x, hw * s, rackZ - 0.1), add(foot, V(0, 0.15 * s, 0)) }, 0.2, 10)
            end
            lathe(Cd, { { 0, 0, true }, { 0.36, 0, true }, { 0.36, 0.2, true }, { 0, 0.2, true } }, foot, V(0, s, 0), 6, { flat = true })
        end
        -- the front bracket to the seat tube
        local stP = onST(rackZ - 0.2)
        sweep(RkB, { V(xF, hw, rackZ), add(stP, V(-0.9, 0.9, 0)), add(stP, V(-0.9, -0.9, 0)), V(xF, -hw, rackZ) }, 0.17, 8)
        lathe(Bk, { { rST, -0.35, true }, { rST + 0.13, -0.3 }, { rST + 0.13, 0.3 }, { rST, 0.35, true } }, stP, stDir, 18)
        -- the rear lamp on the rack's tail, with its reflector
        local lp = V(xB - 0.35, 0, rackZ - 1.1)
        local hb = M:bucket("frame", "black")
        local fr = {}
        for i = 0, 3 do fr[#fr + 1] = { add(lp, V(0.9 - i * 0.35, 0, 0)), V(0, 0, 1), V(0, 1, 0) } end
        ext(hb, fr, function(i) local s = 1 - (i == 4 and 0.06 or 0) return rrLoop(1.2 * s, 2.2 * s, 0.45, 24) end)
        plate(M:bucket("frame", "redlens"), roundRect(2.0, 3.9, 0.4, 4), add(lp, V(-0.2, 0, 0.3)), V(0, 0, 1), V(0, 1, 0), 0.3)
        lathe(M:bucket("frame", "redlens"), { { 0, 0, true }, { 0.55, 0, true }, { 0.5, 0.18 }, { 0, 0.22, true } }, add(lp, V(-0.3, 0, -0.55)), V(-1, 0, 0), 20)
        sweep(Bk, { add(lp, V(0.9, 0, 0.8)), V(xB + 0.05, 0, rackZ - 0.1) }, function() return 0.5, 0.12 end, 8, { up = Y })
    end

    ------------------------------------------------------------------
    -- KICKSTAND MOUNT (the stand itself is drawn live)
    ------------------------------------------------------------------
    local standAt
    do
        local cs = chainStay(1)
        standAt = add(cs[6], V(0, 0.35, -0.45))
        box(Bk, standAt, V(1.0, 0, 0), V(0, 0.32, 0), V(0, 0, 0.42))
        bolt(Cd, add(standAt, V(0, 0.33, 0)), Y, 0.16, 0.12)
    end

    ------------------------------------------------------------------
    -- FRONT CARRIER (on the head tube: it does not steer) AND THE BASKET
    ------------------------------------------------------------------
    local bx0, bx1, by, bz0, bz1 = 23, 43, 10, 21, 37        -- the server's basket box
    -- The registry's own box when the game hands it over (opt.extra, BMX.ModelExtra),
    -- moved DOWN by the static sag: the frame is drawn lifted by it, the box is not.
    local ex = opt.extra or {}
    if ex.basket then
        bx0, bx1 = ex.basket.mins[1], ex.basket.maxs[1]
        by = ex.basket.maxs[2]
        bz0, bz1 = ex.basket.mins[3], ex.basket.maxs[3]
    end
    bz0, bz1 = bz0 - (ex.sag or 0), bz1 - (ex.sag or 0)
    do
        local Kc = M:bucket("frame", "black")
        local cz = bz0 - 0.32
        local cx = (bx0 + bx1) * 0.5
        -- the platform: a rounded rectangle of tube and slats
        local per = rrLoop((bx1 - bx0) * 0.5 - 1.2, by - 1.4, 1.6, 40, cx, 0)
        local pts = {}
        for _, q in ipairs(per) do pts[#pts + 1] = V(q[1], q[2], cz) end
        ringTube(Kc, pts, 0.26, 10)
        for _, y in ipairs({ -5, -1.7, 1.7, 5 }) do
            sweep(Kc, { V(bx0 + 1.6, y, cz + 0.05), V(bx1 - 1.6, y, cz + 0.05) }, 0.17, 8, { capStart = false, capEnd = false })
        end
        for _, x in ipairs({ bx0 + 5, cx, bx1 - 5 }) do
            sweep(Kc, { V(x, by - 1.4, cz - 0.05), V(x, -by + 1.4, cz - 0.05) }, 0.2, 8, { capStart = false, capEnd = false })
        end
        -- the head-tube clamps and the struts out to the platform
        local cU, cL = sub(headT, mul(u, 2.3)), add(headB, mul(u, 0.9))
        for _, c in ipairs({ cU, cL }) do
            lathe(Kc, { { rHT, -0.55, true }, { rHT + 0.2, -0.5 }, { rHT + 0.2, 0.5 }, { rHT, 0.55, true } }, c, u, 22)
            box(Kc, add(c, mul(fwdP, rHT + 0.35)), mul(fwdP, 0.45), V(0, 1.0, 0), mul(u, 0.45))
        end
        local nU, nL = add(cU, mul(fwdP, rHT + 0.75)), add(cL, mul(fwdP, rHT + 0.75))
        for _, s in ipairs({ 1, -1 }) do
            -- top struts: level out to the platform's back corners
            sweep(Kc, spline({ add(nU, V(0, 0.75 * s, 0)), add(nU, V(2.5, 2.6 * s, cz - nU[3] - 0.2)), V(bx0 + 1.3, (by - 2.2) * s, cz) }, 5), 0.24, 10)
            -- braces: from the lower clamp under the platform to its front
            sweep(Kc, spline({ add(nL, V(0, 0.75 * s, 0)), add(nL, V(6, 3.5 * s, 1.0)), V(bx1 - 2.4, (by - 2.4) * s, cz - 0.1) }, 6), 0.22, 10)
        end
        -- the lamp: a chromed bullet under the platform's front, facing ahead
        local lp = V(bx1 - 0.7, 0, cz - 2.0)
        local LC = M:bucket("frame", "chrome")
        lathe(LC, { { 0, -2.6, true }, { 0.6, -2.55 }, { 1.05, -2.2 }, { 1.3, -1.4 }, { 1.38, -0.4 }, { 1.4, 0, true }, { 1.25, 0.08, true } }, lp, V(1, 0, 0), 28)
        lathe(M:bucket("frame", "lens"), { { 1.25, 0.06, true }, { 0.9, 0.3 }, { 0, 0.42, true } }, lp, V(1, 0, 0), 28)
        sweep(Kc, { add(lp, V(-1.2, 0, 1.0)), V(lp[1] - 1.2, 0, cz - 0.1) }, function() return 0.4, 0.12 end, 8, { up = Y })
        -- the dynamo's wire from the lamp back along the brace
        sweep(Bkd, spline({ add(lp, V(-2.3, 0.3, 0.2)), V(bx1 - 6, by - 3, cz - 0.5), add(nL, V(1.2, 1.2, 0.3)), add(cL, V(0, 0.9, -1.4)) }, 6), 0.07, 5)

        -- THE BASKET: wicker, a flared tub that fills the box
        local Wd = M:bucket("frame", "wood")
        local Wdd = M:bucket("frame", "wood", true)
        local hxB, hyB = (bx1 - bx0) * 0.5 - 1.1, by - 1.1
        local hxT, hyT = (bx1 - bx0) * 0.5 - 0.42, by - 0.42
        local rimZ = bz1 - 0.42
        local function sz(z)
            local t = (z - bz0) / (rimZ - bz0)
            return hxB + (hxT - hxB) * t, hyB + (hyT - hyB) * t
        end
        local nS = 54
        -- floor
        plate(Wd, roundRect(hxB * 2 + 0.2, hyB * 2 + 0.2, 2.0, 5, 0, 0), V(cx, 0, bz0 + 0.18), V(1, 0, 0), V(0, 1, 0), 0.36)
        -- the liner: the wall's inside, a smooth tub
        do
            local rings = {}
            for i, z in ipairs({ bz0 + 0.2, rimZ }) do
                local hx, hy = sz(z)
                local lp2 = rrLoop(hx - 0.2, hy - 0.2, 2.2, nS)
                rings[i] = {}
                for j, q in ipairs(lp2) do rings[i][j] = V(cx + q[1], q[2], z) end
            end
            grid(Wd, rings, true, function(i) return V(cx, 0, rings[i][1][3] + 50) end)
        end
        -- stakes
        do
            local lb = { sz(bz0 + 0.2) }
            local loB = rrLoop(lb[1], lb[2], 2.2, nS)
            local lt = { sz(rimZ) }
            local loT = rrLoop(lt[1], lt[2], 2.2, nS)
            for j = 1, nS do
                sweep(Wd, { V(cx + loB[j][1], loB[j][2], bz0 + 0.1), V(cx + loT[j][1], loT[j][2], rimZ) }, 0.13, 5,
                      { capStart = false, capEnd = false })
            end
        end
        -- the weave: strips in and out of the stakes
        local nR = 0
        local z = bz0 + 0.95
        while z < rimZ - 0.45 do
            nR = nR + 1
            local hx, hy = sz(z)
            local lo = rrLoop(hx, hy, 2.2, nS)
            local nrm = rrLoop(hx + 1, hy + 1, 3.2, nS)
            local pts = {}
            for j = 1, nS do
                local q, qn = lo[j], nrm[j]
                local du, dv = qn[1] - q[1], qn[2] - q[2]
                local l = sqrt(du * du + dv * dv)
                local off = ((j + nR) % 2 == 0) and 0.11 or -0.09
                pts[j] = V(cx + q[1] + du / l * off, q[2] + dv / l * off, z)
            end
            ringTube(Wdd, pts, function() return 0.31, 0.12 end, 4, { up = V(0, 0, 1) })
            z = z + 0.66
        end
        -- rims: a thick rolled top edge wrapped in cane, a plain foot
        do
            local hx, hy = sz(rimZ)
            local lo = rrLoop(hx, hy, 2.2, nS * 2)
            local pts = {}
            for j, q in ipairs(lo) do pts[j] = V(cx + q[1], q[2], rimZ) end
            ringTube(Wd, pts, 0.44, 10, { up = V(0, 0, 1) })
            -- the wrap: a helix of cane round the rim
            local wrap = {}
            local nW = #pts * 2
            local turns = 75
            for i = 0, nW do
                local f = i / nW * #pts
                local j0 = floor(f) % #pts + 1
                local j1 = j0 % #pts + 1
                local c0 = lerp(pts[j0], pts[j1], f - floor(f))
                local tng = norm(sub(pts[j1], pts[j0]))
                local side = norm(cross(tng, V(0, 0, 1)))
                local an = i / nW * turns * TAU
                wrap[#wrap + 1] = add(c0, add(mul(side, cos(an) * 0.47), V(0, 0, sin(an) * 0.47)))
            end
            sweep(Wdd, wrap, 0.09, 4, { capStart = false, capEnd = false })
            local hx0, hy0 = sz(bz0 + 0.35)
            local lo0 = rrLoop(hx0, hy0, 2.2, nS)
            local p0 = {}
            for j, q in ipairs(lo0) do p0[j] = V(cx + q[1], q[2], bz0 + 0.35) end
            ringTube(Wd, p0, 0.3, 8, { up = V(0, 0, 1) })
        end
        -- straps to the carrier
        for _, x in ipairs({ bx0 + 3, bx1 - 3 }) do
            for _, s in ipairs({ 1, -1 }) do
                local hx, hy = sz(bz0 + 1.6)
                box(Bk, V(x, (hy + 0.15) * s, bz0 + 0.55), V(0.45, 0, 0), V(0, 0.06, 0), V(0, 0, 1.0))
            end
        end
    end

    ------------------------------------------------------------------
    -- FORK (steers): crown, curved blades, steerer, front mudguard
    ------------------------------------------------------------------
    local FkP = M:bucket("fork", "paint")
    local FkC = M:bucket("fork", "chrome")
    local FkCd = M:bucket("fork", "chrome", true)
    do
        -- steerer above the head tube, the headset's lock nut
        sweep(M:bucket("fork", "steel"), { headT, add(headT, mul(u, 1.0)) }, 0.55, 16, { capStart = false })
        lathe(FkC, { { 0.55, 0, true }, { 0.98, 0, true }, { 1.0, 0.25 }, { 0.98, 0.5, true }, { 0.55, 0.5, true } }, add(headT, mul(u, 0.34)), u, 6, { flat = true })
        -- crown: a lugged chromed crown under the head tube
        local crn = add(crown, mul(fwdP, 0.15))
        sweep(FkC, { add(crn, V(0, 1.95, 0)), add(crn, V(0, -1.95, 0)) }, function(t)
            local e = abs(t * 2 - 1)
            return 0.68 + 0.12 * (1 - e * e), 0.55 + 0.1 * (1 - e * e)
        end, 18, { up = u })
        lathe(FkC, { { 0.6, -0.55, true }, { 0.98, -0.5, true }, { 1.0, 0.2 }, { 0.95, 0.55, true }, { 0.6, 0.55, true } }, crown, u, 24)
        -- blades: tapered, curved forward to the axle
        for _, s in ipairs({ 1, -1 }) do
            local a = add(crn, V(0, 1.75 * s, 0))
            local b = add(front, V(0, hubF * s, 0))
            local Lb = len(sub(a, b))
            local pts = bez3(a, sub(a, mul(u, Lb * 0.45)), add(b, mul(u, 4.0)), b, 20)
            sweep(FkP, pts, function(t) return 0.52 - 0.18 * t, 0.62 - 0.26 * t end, 16, { up = fwdP })
            -- dropout tip
            lathe(FkP, { { 0, -0.15, true }, { 0.5, -0.15, true }, { 0.52, 0 }, { 0.5, 0.15, true }, { 0, 0.15, true } }, b, Y, 16)
            lathe(FkCd, { { 0.2, 0, true }, { 0.4, 0, true }, { 0.4, 0.32, true }, { 0.2, 0.32, true } }, add(front, V(0, (hubF + 0.15) * s, 0)), V(0, s, 0), 6, { flat = true })
        end
        sweep(M:bucket("fork", "steel"), { add(front, V(0, -hubF - 0.6, 0)), add(front, V(0, hubF + 0.6, 0)) }, 0.2, 10)
        -- front mudguard and its stays
        local fgR = RD.outer + 0.65
        local g = mudguard(FkP, front, fgR, math.rad(-12), math.rad(158), 1.4, 0.5, { segs = 50 })
        for _, s in ipairs({ 1, -1 }) do
            local p = g(math.rad(10), 1.25 * s, 0.55)
            sweep(FkCd, { p, add(front, V(0.1, (hubF + 0.22) * s, 0.2)) }, 0.085, 6)
        end
        -- the guard's bracket up to the crown
        local top = g(math.atan2(crown[3] - front[3], crown[1] - front[1]), 0, 0)
        box(M:bucket("fork", "black"), lerp(top, crown, 0.45), mul(norm(sub(crown, top)), len(sub(crown, top)) * 0.5), V(0, 0.45, 0), mul(fwdP, 0.08))
        -- dynamo wire up the left blade
        local wirePts = {}
        for i = 0, 8 do
            local t = i / 8
            local a = add(crn, V(0, 1.75, 0))
            local b = add(front, V(0, hubF, 0))
            local Lb = len(sub(a, b))
            local pts = bez3(a, sub(a, mul(u, Lb * 0.45)), add(b, mul(u, 4.0)), b, 8)
            wirePts[#wirePts + 1] = add(pts[i + 1], add(mul(fwdP, -0.55), V(0, 0.1, 0)))
        end
        sweep(M:bucket("fork", "black", true), wirePts, 0.07, 5)
    end

    ------------------------------------------------------------------
    -- BARS (steer): quill gooseneck, North Road bars, leather grips
    ------------------------------------------------------------------
    local gripA, gripB = {}, {}
    local bellAt, bellDir
    do
        local Bc = M:bucket("bars", "chrome")
        local Bcd = M:bucket("bars", "chrome", true)
        -- the quill and the gooseneck
        sweep(Bc, { add(headT, mul(u, 0.6)), stemTop }, 0.5, 18, { capStart = false })
        lathe(Bc, { { 0.5, 0, true }, { 0.62, 0.1 }, { 0.62, 1.5 }, { 0.55, 1.6, true }, { 0, 1.62, true } }, sub(stemTop, mul(u, 0.4)), u, 18)
        local neck = bez3(add(stemTop, mul(u, 0.8)), add(stemTop, add(mul(u, 1.4), V(0.9, 0, 0))), sub(clamp, V(1.4, 0, 0.1)), clamp, 10)
        sweep(Bc, neck, function(t) return 0.5 - 0.06 * t end, 16, { capStart = false, capEnd = false })
        lathe(Bc, { { 0, 0, true }, { 0.35, 0, true }, { 0.3, 0.12 }, { 0, 0.16, true } }, add(stemTop, mul(u, 1.22)), u, 6, { flat = true })
        lathe(Bc, { { 0, -1.0, true }, { 0.58, -1.0, true }, { 0.64, -0.85 }, { 0.64, 0.85 }, { 0.58, 1.0, true }, { 0, 1.0, true } }, clamp, Y, 20)
        bolt(Bcd, add(clamp, V(0, 0, -0.62)), V(0, 0, -1), 0.17, 0.25)
        -- the bars: a continuous tube, swept back to the grips
        local gx, gz = 13.6 * (k / (52 / 39)) + (clamp[1] - 13.3), clamp[3] + 3.6
        local function side(s)
            return {
                clamp,
                add(clamp, V(0.05, 1.4 * s, 0)),
                add(clamp, V(0.55, 3.8 * s, 0.35)),
                add(clamp, V(1.7, 7.2 * s, 1.85)),
                V(clamp[1] + 1.75, 10.4 * s, gz - 0.55),
                V(clamp[1] + 0.35, 12.85 * s, gz - 0.1),
                V(clamp[1] - 1.3, 14.1 * s, gz),
                V(clamp[1] - 5.6, 17.2 * s, gz + 0.55),
            }
        end
        local L, Rr = side(1), side(-1)
        local all = {}
        for i = #Rr, 2, -1 do all[#all + 1] = Rr[i] end
        for i = 1, #L do all[#all + 1] = L[i] end
        local path = spline(all, 7)
        sweep(Bc, path, 0.44, 16)
        -- grips: brown leather-look, shaped, over the last stretch of each side
        local Lg = M:bucket("bars", "leather")
        for _, s in ipairs({ 1, -1 }) do
            local sd = side(s)
            local a, b = sd[7], sd[8]
            local d = norm(sub(b, a))
            local g0 = add(a, mul(d, -0.2))
            local gl = len(sub(b, g0)) + 0.35
            local prof = { { 0.44, -0.05, true }, { 0.82, -0.05, true }, { 0.86, 0.08 }, { 0.8, 0.3 }, { 0.74, 0.7 } }
            for i = 1, 6 do
                local t = i / 7
                prof[#prof + 1] = { 0.74 + 0.1 * sin(t * pi) + 0.02 * ((i % 2 == 0) and 1 or -1), 0.7 + t * (gl - 1.5) }
            end
            prof[#prof + 1] = { 0.8, gl - 0.6 }
            prof[#prof + 1] = { 0.88, gl - 0.25 }
            prof[#prof + 1] = { 0.84, gl, true }
            prof[#prof + 1] = { 0, gl + 0.02, true }
            lathe(Lg, prof, g0, d, 22)
            -- the grip as the hands hold it: inner (front) end to outer (back)
            if s < 0 then gripA.r, gripB.r = add(g0, mul(d, 0.3)), add(g0, mul(d, gl - 0.2))
            else gripA.l, gripB.l = add(g0, mul(d, 0.3)), add(g0, mul(d, gl - 0.2)) end
            if s > 0 then
                -- the bell sits on the bend just ahead of the left grip
                local q1, q2 = sd[6], sd[7]
                bellAt = lerp(q1, q2, 0.35)
                bellDir = norm(sub(q2, q1))
            end
        end
    end
    local bellPivot, bellAxis = G.parts.bell(M, "bars", "bellLever", bellAt, bellDir, V(0, 0, 1), V(-1, 0, 0))

    ------------------------------------------------------------------
    -- WHEELS: 28 x 1.75 cream walls, chrome rims; a dynamo front hub and a
    -- coaster-brake rear
    ------------------------------------------------------------------
    G.parts.wheel(M, "wheelF", RD, { wall = "gum", rim = "chrome", tread = "road", spokes = 36, cross = 3,
        spokeR = 0.05, hubHalf = hubF, hubShell = 1.05 })
    G.parts.wheel(M, "wheelR", RD, { rear = true, cog = false, wall = "gum", rim = "chrome", tread = "road",
        spokes = 36, cross = 3, spokeR = 0.05, hubHalf = hubR, hubShell = 1.3 })
    cityTread(M, "wheelF", RD, 80)
    cityTread(M, "wheelR", RD, 80)

    ------------------------------------------------------------------
    -- CRANKS (outside the chaincase) and the block pedals
    ------------------------------------------------------------------
    local crankL, pedalY = 6.8, 5.3
    do
        local Ck = M:bucket("cranks", "chrome")
        local Ckd = M:bucket("cranks", "chrome", true)
        sweep(M:bucket("cranks", "steel"), { add(bb, V(0, -3.3, 0)), add(bb, V(0, 3.3, 0)) }, 0.36, 14)
        for _, s in ipairs({ -1, 1 }) do                  -- -1 = right: forward at angle 0
            local dir = (s == -1) and V(1, 0, 0) or V(-1, 0, 0)
            local yRoot = 3.2 * s
            local root = V(bb[1], yRoot, bb[3])
            local tip = add(V(bb[1], 3.35 * s, bb[3]), mul(dir, crankL))
            local Pr = {}
            for i = 0, 12 do
                local t = i / 12
                local c = lerp(root, tip, t)
                local wv = 0.55 - 0.12 * t
                local wy = 0.3 - 0.04 * t
                Pr[#Pr + 1] = {}
                for j = 0, 13 do
                    local a = j / 14 * TAU
                    local ca, sa = cos(a), sin(a)
                    local e = 2.6
                    Pr[#Pr][j + 1] = add(c, V(0, (abs(ca) ^ (2 / e)) * (ca < 0 and -1 or 1) * wy, (abs(sa) ^ (2 / e)) * (sa < 0 and -1 or 1) * wv))
                end
            end
            grid(Ck, Pr, true, function(i) return lerp(root, tip, (i - 1) / 12) end)
            lathe(Ck, { { 0, -0.34, true }, { 0.8, -0.34, true }, { 0.84, -0.2 }, { 0.84, 0.2 }, { 0.8, 0.34, true }, { 0, 0.34, true } }, root, Y, 20)
            lathe(Ck, { { 0, -0.3, true }, { 0.5, -0.3, true }, { 0.53, -0.18 }, { 0.53, 0.18 }, { 0.5, 0.3, true }, { 0, 0.3, true } }, tip, Y, 16)
            -- the cotter pin, Dutch style
            lathe(Ckd, { { 0, 0, true }, { 0.16, 0, true }, { 0.16, 0.9 }, { 0.22, 0.95, true }, { 0.22, 1.15 }, { 0, 1.2, true } },
                  add(root, V(0, 0, -0.95)), V(0, 0, 1), 8)
            -- the pedal's spindle out to the pedal
            sweep(M:bucket("cranks", "steel"), { tip, V(tip[1], (pedalY - 1.5) * s, tip[3]) }, 0.2, 8)
        end
    end
    do
        -- block pedal: a steel cage round two rubber blocks, amber reflectors
        local Pb = M:bucket("pedal", "rubber")
        local Ps = M:bucket("pedal", "steel")
        local Pa = M:bucket("pedal", "amber", true)
        local w, d = 3.4, 2.9
        sweep(Ps, { V(0, -w / 2 - 0.1, 0), V(0, w / 2 + 0.1, 0) }, 0.32, 12)
        for _, s in ipairs({ 1, -1 }) do
            -- the end plates
            plate(Ps, roundRect(d + 0.2, 1.05, 0.3, 3), V(0, (w / 2 + 0.05) * s, 0), V(1, 0, 0), V(0, 0, 1), 0.12)
            -- a rubber block front and back, ribbed
            local bx = s * (d / 2 - 0.55)
            box(Pb, V(bx, 0, 0), V(0.5, 0, 0), V(0, w / 2 - 0.1, 0), V(0, 0, 0.42))
            for i = -4, 4 do
                box(Pb, V(bx, i * 0.4, 0), V(0.53, 0, 0), V(0, 0.08, 0), V(0, 0, 0.46))
            end
            -- reflector in the block's face
            plate(Pa, roundRect(1.3, 0.45, 0.1, 2), V(s * (d / 2 - 0.02), 0, 0), V(0, 1, 0), V(0, 0, 1), 0.08)
        end
    end

    ------------------------------------------------------------------
    -- THE CHILD SEAT (group childSeat): a moulded shell on the rack, its
    -- pan where the child sits (sh_passenger.lua's child pod)
    ------------------------------------------------------------------
    do
        local pod = V(-wb * 0.5 * 0.8, 0, seat[3] + 2)
        local cs = V(pod[1] - 0.5, 0, pod[3] + 2.0)            -- where the child sits
        local Wh = M:bucket("childSeat", "white")
        local Sb = M:bucket("childSeat", "seat")
        local Kb = M:bucket("childSeat", "black")
        local Kbd = M:bucket("childSeat", "black", true)
        local t = 0.38                                          -- the shell's wall
        local panZ = cs[3] - 1.25                               -- the shell's underside at the pan
        local front = cs[1] + 2.4
        local backX = cs[1] - 3.9
        local height = 13.5
        -- the spine: forward edge of the pan, back along it, round, up the back
        local spine = spline({ V(front, 0, panZ + 0.25), V(cs[1] + 0.2, 0, panZ), V(backX + 0.9, 0, panZ),
                               V(backX - 0.1, 0, panZ + 1.2), V(backX - 0.6, 0, panZ + 5.5),
                               V(backX - 1.3, 0, panZ + height - 2.5), V(backX - 1.5, 0, panZ + height) }, 5)
        local cum = { 0 }
        for i = 2, #spine do cum[i] = cum[i - 1] + len(sub(spine[i], spine[i - 1])) end
        local frames = {}
        for i = 1, #spine do
            local T = norm(sub(spine[min(#spine, i + 1)], spine[max(1, i - 1)]))
            frames[i] = { spine[i], V(T[3], 0, -T[1]), Y }
        end
        local Ltot = cum[#cum]
        local panLen = len(sub(spine[1], V(backX, 0, panZ)))
        -- the U section: wall height and half width along the spine
        local function section(i)
            local s = cum[i]
            local f = s / Ltot
            local hw, wall
            if s < panLen then
                local q = s / panLen
                hw = 3.3 + 0.5 * q
                wall = 1.0 + 2.2 * q
            else
                local q = (s - panLen) / (Ltot - panLen)
                local rt = (q > 0.8) and sqrt(max(0.1, 1 - ((q - 0.8) / 0.2) ^ 2)) or 1
                hw = (3.8 + 0.25 * sin(q * pi)) * (0.35 + 0.65 * rt)
                wall = (3.2 - 1.2 * sin(min(1, q / 0.6) * pi / 2) + 1.4 * max(0, q - 0.6) / 0.4) * (0.3 + 0.7 * rt)
            end
            local rc, n = 0.9, 4
            local pr = { { wall, -hw } }
            -- outer: right wall top, down to the right bottom corner, across, up the left
            for k2 = 0, n do
                local a = -pi / 2 - k2 / n * (pi / 2)          -- -90 .. -180
                pr[#pr + 1] = { rc + cos(a) * rc, -hw + rc + sin(a) * rc }
            end
            for k2 = 0, n do
                local a = pi + k2 / n * (pi / 2)                -- 180 .. 270 mirrored to the left
                pr[#pr + 1] = { rc + cos(a) * rc, hw - rc - sin(a) * rc }
            end
            pr[#pr + 1] = { wall, hw }
            pr[#pr + 1] = { wall, hw - t }
            local ri = rc - t * 0.6
            for k2 = 0, n do
                local a = pi / 2 + k2 / n * (pi / 2)            -- 90 .. 180 (inner left corner)
                pr[#pr + 1] = { t + ri + cos(a) * ri, hw - t - ri + sin(a) * ri }
            end
            for k2 = 0, n do
                local a = pi + k2 / n * (pi / 2)                -- 180 .. 270 (inner right corner)
                pr[#pr + 1] = { t + ri + cos(a) * ri, -hw + t + ri + sin(a) * ri }
            end
            pr[#pr + 1] = { wall, -hw + t }
            return pr
        end
        ext(Wh, frames, section)
        -- the moulded base under the pan, down to the rack
        do
            local base = rackZ + 0.55
            local rings = {}
            for i = 0, 6 do
                local q = i / 6
                local z = base + (panZ + 0.1 - base) * q
                local lp = rrLoop(2.5 + 1.0 * q * q, 2.3 + 1.4 * q * q, 1.0, 28)
                rings[#rings + 1] = {}
                for j, p2 in ipairs(lp) do rings[#rings][j] = V(cs[1] - 0.9 + p2[1], p2[2], z) end
            end
            grid(Wh, rings, true, function(i)
                local s = V(0, 0, 0)
                for _, p in ipairs(rings[i]) do s = add(s, p) end
                return mul(s, 1 / #rings[i])
            end)
            cap(Wh, rings[1], V(0, 0, -1))
        end
        -- cushions: on the pan and up the back
        local function pad(fr, hw, th)
            ext(Sb, fr, function(i, n)
                local q = (i - 1) / (n - 1)
                local w2 = hw * (0.75 + 0.25 * sqrt(max(0, 1 - (2 * q - 1) ^ 4)))
                local pr = {}
                for j = 0, 15 do
                    local a = j / 16 * TAU
                    pr[#pr + 1] = { th * 0.5 + sin(a) * th * 0.5, cos(a) * w2 }
                end
                return pr
            end)
        end
        do
            local fr = {}
            for i = 1, #spine do
                local s = cum[i]
                if s > 0.4 and s < Ltot - 1.2 then
                    local f = frames[i]
                    fr[#fr + 1] = { add(f[1], mul(f[2], t - 0.02)), f[2], f[3] }
                end
            end
            pad(fr, 2.7, 0.6)
        end
        -- harness: shoulder straps over the pad to a buckle on the pan
        for _, s in ipairs({ 1, -1 }) do
            local a = V(backX - 0.6 + 0.9, 1.3 * s, panZ + 9.0)
            local b = V(cs[1] + 1.2, 0.6 * s, panZ + 2.4)
            sweep(Kb, spline({ a, add(lerp(a, b, 0.45), V(0.9, 0.1 * s, 0)), b, V(cs[1] + 2.4, 0.35 * s, panZ + 1.0) }, 5),
                  function() return 0.42, 0.06 end, 6, { up = V(1, 0, 0) })
        end
        box(Kb, V(cs[1] + 2.0, 0, panZ + 1.5), V(0.14, 0, 0), V(0, 0.7, 0), V(0, 0, 0.55))
        -- the clamps onto the rack
        for _, x in ipairs({ cs[1] + 1.8, cs[1] - 2.8 }) do
            box(Kb, V(x, 0, rackZ + 0.42), V(0.6, 0, 0), V(0, rack.hw + 0.3, 0), V(0, 0, 0.16))
            for _, s in ipairs({ 1, -1 }) do
                box(Kb, V(x, (rack.hw + 0.3) * s, rackZ - 0.05), V(0.6, 0, 0), V(0, 0.1, 0), V(0, 0, 0.55))
                bolt(M:bucket("childSeat", "chrome", true), V(x, (rack.hw + 0.4) * s, rackZ - 0.1), V(0, s, 0), 0.14, 0.12)
            end
        end
        -- foot guards: a moulded stalk down each side to a cup with a strap
        for _, s in ipairs({ 1, -1 }) do
            local top = V(front - 1.3, 3.3 * s, panZ + 0.2)
            local bot = V(front + 0.4, 4.7 * s, rackZ - 8.5)
            sweep(Wh, spline({ top, add(lerp(top, bot, 0.5), V(0, 0.5 * s, 0)), bot }, 5), function() return 0.55, 0.25 end, 10, { up = Y })
            local cupC = add(bot, V(0.5, 0.2 * s, -0.5))
            local fr = {}
            for i = 0, 5 do fr[#fr + 1] = { add(cupC, V(-1.3 + i * 0.6, 0, 0)), V(0, 0, 1), V(0, 1, 0) } end
            ext(Wh, fr, function(i)
                local q = (i - 1) / 5
                local hw2 = 0.95 + 0.2 * sin(q * pi)
                return { { -0.5, -hw2 }, { -0.5, hw2 }, { 0.9, hw2 }, { 0.9, hw2 - 0.2 }, { -0.3, hw2 - 0.2 },
                         { -0.3, -hw2 + 0.2 }, { 0.9, -hw2 + 0.2 }, { 0.9, -hw2 } }
            end)
            box(Kbd, add(cupC, V(0.3, 0, 1.0)), V(0.35, 0, 0), V(0, 1.1, 0), V(0, 0, 0.06))
        end
    end

    ------------------------------------------------------------------
    -- LAYOUT
    ------------------------------------------------------------------
    M.layout = {
        k = k, steer = u,
        headT = headT, headB = headB, stemTop = stemTop,
        rear = rear, front = front, bb = bb,
        crank = crankL, pedalY = pedalY,
        gripR = { A = gripA.r, B = gripB.r }, gripL = { A = gripA.l, B = gripB.l },
        bellPivot = bellPivot, bellAxis = bellAxis,
        stand = standAt,
        basket = { mins = V(bx0, -by, bz0), maxs = V(bx1, by, bz1) },
    }
    return M
end)
