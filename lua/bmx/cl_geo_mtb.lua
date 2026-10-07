--[[--------------------------------------------------------------------------
    bmx/cl_geo_mtb.lua

    The models of the downhill bike and the e-bike, built in code (docs/MODELS.md).
    Kinds: dh, ebike.

    dh     a long-travel single-pivot downhill bike: a hydroformed front
           triangle, a triangulated swingarm (group "swingarm", about
           layout.swingPivot) with a yoke reaching forward past the seat tube
           to the coil shock (drawn live between layout.shock's points), a
           dual-crown fork whose lowers, arch and caliper slide (group
           "forkLower", layout.forkSlide), 2.5" knobbly tyres on wide rims,
           203 mm rotors and four-piston calipers, a 36t ring in a chain guide
           with a bash guard, a 7-speed DH cassette and a short-cage
           derailleur, 800 mm riser bars on a direct-mount stem, lock-on
           grips, flat pedals with pins, a low saddle.
    ebike  a pedal-assist trekking e-bike: an aluminium hardtail whose fat down
           tube holds the battery, a mid-drive motor round the bottom
           bracket, a suspension fork (rigid in the drawing: the frame is
           pitched to its wheels), hydraulic discs, 2.25" tyres, a 9-speed
           cassette and derailleur, fenders, a rack with its tail light, a
           headlamp, the handlebar display and its remote, the bell.

    Built in real units round the registry's sizes: the axles at -wb/2 and
    +wb/2, the saddle's top at seat + (-0.5, 0, 2).
----------------------------------------------------------------------------]]

BMX = BMX or {}
local G = BMX.BikeGeo
if not G then return end

local Vv = G.vec
local V, add, sub, mul, dot, cross, len, norm, lerp = Vv.V, Vv.add, Vv.sub, Vv.mul, Vv.dot, Vv.cross, Vv.len, Vv.norm, Vv.lerp
local Pm = G.prim
local sweep, lathe, plate, ringPlate, box = Pm.sweep, Pm.lathe, Pm.plate, Pm.ringPlate, Pm.box
local roundRect, circle, bez3, spline, tri, grid, cap, bead = Pm.roundRect, Pm.circle, Pm.bez3, Pm.spline, Pm.tri, Pm.grid, Pm.cap, Pm.bead
local earclip, area2 = Pm.earclip, Pm.area2
local sqrt, sin, cos, pi, abs, max, min, floor, atan2 = math.sqrt, math.sin, math.cos, math.pi, math.abs, math.max, math.min, math.floor, math.atan2
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

-- A closed 2D profile carried through frames { o, eu, ev } (u along eu, v
-- along ev). `prof` is a loop or function(i, n) giving one per frame (same
-- point count). Ends capped unless opt.caps == false.
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
    local F = {}
    local N
    for i = 1, n do
        local T = norm(sub(pts[min(n, i + 1)], pts[max(1, i - 1)]))
        if not N then N = Vv.perp(T, up)
        else
            local q = sub(N, mul(T, dot(N, T)))
            N = len(q) > 1e-6 and norm(q) or Vv.perp(T, up)
        end
        F[i] = { pts[i], N, cross(T, N) }
    end
    return F
end

-- A closed rounded rectangle resampled to n points evenly by length, from the
-- +u side's middle, counter-clockwise.
local function rrLoop(hu, hv, rc, n, cu, cv)
    rc = max(0.01, min(rc, hu - 1e-3, hv - 1e-3))
    local dense = { { hu, 0 } }
    local segs = 8
    local corners = { { hu - rc, hv - rc, 0 }, { -hu + rc, hv - rc, 0.25 }, { -hu + rc, -hv + rc, 0.5 }, { hu - rc, -hv + rc, 0.75 } }
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

-- A tube of rounded-rectangle section along a path: hu(t) across in the
-- `up` direction, hv(t) the other way (the y side for a frame tube).
local function rrTube(B, pts, hu, hv, rc, n, up, opt)
    local F = pathFrames(pts, up)
    local L = { 0 }
    for i = 2, #pts do L[i] = L[i - 1] + len(sub(pts[i], pts[i - 1])) end
    return ext(B, F, function(i)
        local t = L[i] / max(L[#L], 1e-9)
        local a = type(hu) == "function" and hu(t) or hu
        local b = type(hv) == "function" and hv(t) or hv
        return rrLoop(a, b, min(rc, a * 0.95, b * 0.95), n or 20)
    end, opt)
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

-- A hex bolt head at `p` facing `n`.
local function bolt(B, p, n, r, h)
    r, h = r or 0.14, h or 0.12
    lathe(B, { { 0, 0, true }, { r, 0, true }, { r, h * 0.8 }, { r * 0.7, h, true }, { 0, h, true } }, p, n, 6, { flat = true })
end

-- A socket-head cap screw (round, with a dark hex socket look).
local function capScrew(B, p, n, r, h)
    r, h = r or 0.13, h or 0.14
    lathe(B, { { 0, h * 0.6, true }, { r * 0.5, h * 0.6, true }, { r * 0.5, h, true }, { r, h, true }, { r, 0 }, { 0, 0, true } }, p, n, 10)
end

-- A helix (a coil spring) from a to b.
local function coil(B, a, b, rc, rw, turns, sides)
    local d = norm(sub(b, a))
    local L = len(sub(b, a))
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

-- A fender: a C-section shell round `axle` (x/z plane, angle 0 = forward)
-- from a0 to a1, half width w, edges rolled by `curl`. Returns a function
-- (angle, y, drop) -> a point on it.
local function fender(B, axle, rg, a0, a1, w, curl, opt)
    opt = opt or {}
    local t = opt.t or 0.08
    local prof = {}
    local nv = 7
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
    local n = opt.segs or 40
    local frames = {}
    for i = 0, n do
        local a = a0 + (a1 - a0) * i / n
        local rad = V(cos(a), 0, sin(a))
        frames[#frames + 1] = { add(axle, mul(rad, rg)), rad, Y }
    end
    ext(B, frames, prof)
    for _, s in ipairs({ 1, -1 }) do
        local pts = {}
        for i = 0, n do
            local a = a0 + (a1 - a0) * i / n
            pts[#pts + 1] = add(add(axle, mul(V(cos(a), 0, sin(a)), rg - curl - 0.02)), V(0, w * s, 0))
        end
        sweep(B, pts, t * 0.9, 5)
    end
    return function(a, side, drop)
        return add(add(axle, mul(V(cos(a), 0, sin(a)), rg - (drop or 0))), V(0, side or 0, 0))
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

-- The hull of some circles { {u, v, r}, ... }, as a 2D loop.
local function circleHull(cs, n)
    local pts = {}
    for _, c in ipairs(cs) do
        for i = 0, (n or 32) - 1 do
            local a = i / (n or 32) * TAU
            pts[#pts + 1] = { c[1] + cos(a) * c[3], c[2] + sin(a) * c[3] }
        end
    end
    return hull2(pts)
end

local pitchRadius = G.parts.pitchRadius
local toothLoop = G.parts.toothLoop

-- A sprocket in the x/z plane at y, `teeth`, bored to `bore`.
local function sprocket(B, c, y, teeth, thick, bore, ppt)
    local pr = pitchRadius(teeth)
    local outer = toothLoop(teeth, pr, ppt or 4)
    local inner = {}
    for i = 1, #outer do
        local a = (i - 1) / #outer * TAU
        inner[i] = { c[1] + cos(a) * bore, c[3] + sin(a) * bore }
        outer[i] = { outer[i][1] + c[1], outer[i][2] + c[3] }
    end
    ringPlate(B, outer, inner, V(0, y, 0), V(1, 0, 0), V(0, 0, 1), thick)
    return pr
end

-- THE CHAIN round a set of pulleys. `circ` = { {x, z, r, side}, ... } in the
-- order the chain runs; side +1 for a pulley inside the loop (ring, cog, the
-- lower jockey), -1 for one it wraps the other way (the upper jockey). Returns
-- the dense 2D path; `links` lays the plates and rollers along it at y.
local function chainPath(circ)
    local m = #circ
    local tang = {}
    for i = 1, m do
        local A, Bc = circ[i], circ[i % m + 1]
        local r1, r2 = A[3] * A[4], Bc[3] * Bc[4]
        local dx, dz = Bc[1] - A[1], Bc[2] - A[2]
        local D = sqrt(dx * dx + dz * dz)
        local hx, hz = dx / D, dz / D
        local ex, ez = -hz, hx
        local a = (r2 - r1) / D
        local b = sqrt(max(0, 1 - a * a))
        local nx, nz = a * hx + b * ex, a * hz + b * ez
        tang[i] = { { A[1] - r1 * nx, A[2] - r1 * nz }, { Bc[1] - r2 * nx, Bc[2] - r2 * nz } }
    end
    local path = {}
    for i = 1, m do
        local c = circ[i]
        local pin = tang[(i - 2) % m + 1][2]
        local pout = tang[i][1]
        local a0 = atan2(pin[2] - c[2], pin[1] - c[1])
        local a1 = atan2(pout[2] - c[2], pout[1] - c[1])
        if c[4] > 0 then while a1 < a0 do a1 = a1 + TAU end
        else while a1 > a0 do a1 = a1 - TAU end end
        local steps = max(2, floor(abs(a1 - a0) * c[3] / 0.12))
        for s = 0, steps do
            local a = a0 + (a1 - a0) * s / steps
            path[#path + 1] = { c[1] + cos(a) * c[3], c[2] + sin(a) * c[3] }
        end
    end
    path[#path + 1] = path[1]
    return path
end

local function chainLinks(B, path, y, pitchIn)
    local cum = { 0 }
    for i = 2, #path do
        cum[i] = cum[i - 1] + sqrt((path[i][1] - path[i - 1][1]) ^ 2 + (path[i][2] - path[i - 1][2]) ^ 2)
    end
    local total = cum[#cum]
    local nl = floor(total / (pitchIn or 0.5) / 2 + 0.5) * 2
    local pitch = total / nl
    local k = 2
    local function at(s)
        s = s % total
        if s < cum[k - 1] then k = 2 end
        while k < #cum and cum[k] < s do k = k + 1 end
        local t = (s - cum[k - 1]) / max(cum[k] - cum[k - 1], 1e-9)
        return { path[k - 1][1] + (path[k][1] - path[k - 1][1]) * t, path[k - 1][2] + (path[k][2] - path[k - 1][2]) * t }
    end
    local pins = {}
    for i = 0, nl - 1 do pins[i] = at(i * pitch) end
    for i = 0, nl - 1 do
        local a, b = pins[i], pins[(i + 1) % nl]
        local du, dv = b[1] - a[1], b[2] - a[2]
        local l = max(sqrt(du * du + dv * dv), 1e-6)
        local eu = V(du / l, 0, dv / l)
        local ev = V(-dv / l, 0, du / l)
        local off = (i % 2 == 0) and 0.19 or 0.12
        local loop = { { -0.15, -0.07 }, { -0.15, 0.07 }, { -0.07, 0.15 }, { l * 0.5, 0.11 }, { l + 0.07, 0.15 },
                       { l + 0.15, 0.07 }, { l + 0.15, -0.07 }, { l + 0.07, -0.15 }, { l * 0.5, -0.11 }, { -0.07, -0.15 } }
        for _, s in ipairs({ 1, -1 }) do plate(B, loop, V(a[1], y + off * s, a[2]), eu, ev, 0.05) end
        sweep(B, { V(a[1], y - 0.12, a[2]), V(a[1], y + 0.12, a[2]) }, 0.1, 5, { capStart = false, capEnd = false })
    end
    return nl
end

-- A cassette on the rear wheel (group), cogs { teeth... } inboard to outboard
-- from y0 by `step`; returns the y of cog i.
local function cassette(M, group, cogs, y0, step)
    local St = M:bucket(group, "steel")
    local Bk = M:bucket(group, "black")
    for i, n in ipairs(cogs) do
        local y = y0 - step * (i - 1)
        local pr = pitchRadius(n)
        sprocket(St, V(0, 0, 0), y, n, 0.075, max(0.7, pr - 0.75), 4)
        if pr > 1.6 then
            -- the big cogs on a spider
            lathe(Bk, { { 0.68, -0.05, true }, { pr - 0.7, -0.05, true }, { pr - 0.7, 0.05, true }, { 0.68, 0.05, true } }, V(0, y + step * 0.5, 0), Y, 24)
        end
    end
    -- the freehub's body and the lockring
    local yl = y0 - step * (#cogs - 1)
    sweep(Bk, { V(0, y0 + 0.4, 0), V(0, yl - 0.05, 0) }, 0.68, 18, { capStart = false })
    lathe(Bk, { { 0.4, 0, true }, { 0.82, 0, true }, { 0.82, 0.14, true }, { 0.4, 0.14, true } }, V(0, yl - 0.05, 0), V(0, -1, 0), 12, { flat = true })
    return function(i) return y0 - step * (i - 1) end
end

-- A rear derailleur: hanger at `hang` (on the dropout's outside), the jockey
-- wheels' centres up and lo at chain plane y.
local function derailleur(M, group, hang, up, lo, y)
    local Bk = M:bucket(group, "black")
    local Al = M:bucket(group, "alloy")
    local Pl = M:bucket(group, "plastic")
    local Cd = M:bucket(group, "chrome", true)
    local yo = y - 0.75                                  -- the body's plane, outboard of the chain
    -- B-knuckle on the hanger bolt
    local bk = V(hang[1] - 0.2, yo - 0.15, hang[3] - 0.25)
    lathe(Bk, { { 0, -0.45, true }, { 0.48, -0.45, true }, { 0.52, -0.3 }, { 0.52, 0.3 }, { 0.48, 0.45, true }, { 0, 0.45, true } }, bk, Y, 16)
    capScrew(Cd, V(bk[1], bk[2] - 0.45, bk[3]), V(0, -1, 0), 0.2, 0.1)
    -- the parallelogram: two links back and down to the P-knuckle
    local pk = V(up[1] - 0.65, yo + 0.1, up[3] + 1.3)
    for _, dz in ipairs({ 0.32, -0.32 }) do
        sweep(Bk, { add(bk, V(-0.1, 0.1, dz)), add(pk, V(0.15, 0, dz)) }, function() return 0.26, 0.18 end, 8, { up = V(0, 1, 0) })
    end
    plate(Al, roundRect(1.4, 0.9, 0.3, 3), lerp(bk, pk, 0.5), norm(sub(pk, bk)), V(0, 0, 1), 0.06)
    local plane = V(lerp(bk, pk, 0.5)[1], yo - 0.25, lerp(bk, pk, 0.5)[3])
    box(Al, plane, mul(norm(sub(pk, bk)), 0.75), V(0, 0.04, 0), V(0, 0, 0.38))
    lathe(Bk, { { 0, -0.4, true }, { 0.44, -0.4, true }, { 0.46, 0 }, { 0.44, 0.4, true }, { 0, 0.4, true } }, pk, Y, 14)
    -- the cage: an outer and an inner plate round both jockeys
    local function cageLoop(r)
        local cs = { { up[1], up[3], r }, { lo[1], lo[3], r + 0.05 }, { pk[1], pk[3], 0.35 } }
        return circleHull(cs, 14)
    end
    plate(Bk, cageLoop(0.95), V(0, y - 0.38, 0), V(1, 0, 0), V(0, 0, 1), 0.08)
    plate(Bk, cageLoop(0.82), V(0, y + 0.38, 0), V(1, 0, 0), V(0, 0, 1), 0.07)
    -- the jockey wheels
    for _, c in ipairs({ up, lo }) do
        sprocket(Pl, c, y, 11, 0.12, 0.25, 3)
        lathe(Al, { { 0, -0.36, true }, { 0.22, -0.36, true }, { 0.22, 0.36, true }, { 0, 0.36, true } }, V(c[1], y, c[3]), Y, 10)
        capScrew(Cd, V(c[1], y - 0.42, c[3]), V(0, -1, 0), 0.16, 0.08)
    end
end

-- A disc caliper (4-piston when big), clamping the rotor of radius rr at y,
-- at angle `ang` round the axle (x/z plane), on its post mount.
local function caliper(M, group, axle, rr, y, ang, big)
    local Bk = M:bucket(group, "black")
    local Cd = M:bucket(group, "chrome", true)
    local rad = V(cos(ang), 0, sin(ang))
    local tng = V(-sin(ang), 0, cos(ang))
    local c = add(add(axle, mul(rad, rr - 0.45)), V(0, y, 0))
    local L = big and 1.55 or 1.15
    -- two halves either side of the rotor, bridged over its edge
    for _, s in ipairs({ 1, -1 }) do
        local hc = add(c, V(0, 0.42 * s, 0))
        local fr = { { add(hc, V(0, -0.26, 0)), tng, rad }, { add(hc, V(0, 0.26, 0)), tng, rad } }
        ext(Bk, fr, rrLoop(L, 0.62, 0.3, 20))
        -- piston bores' bulges
        for _, q in ipairs(big and { -0.55, 0.55 } or { 0 }) do
            lathe(Bk, { { 0, 0, true }, { 0.38, 0, true }, { 0.38, 0.12 }, { 0.3, 0.18, true }, { 0, 0.18, true } },
                  add(add(hc, mul(tng, q)), V(0, 0.26 * s, 0)), V(0, s, 0), 14)
        end
    end
    box(Bk, add(c, mul(rad, 0.55)), mul(tng, L * 0.9), V(0, 0.68, 0), mul(rad, 0.16))
    -- the bolts through to the post mount (outboard face)
    for _, q in ipairs({ -L + 0.35, L - 0.35 }) do
        capScrew(Cd, add(add(c, mul(tng, q)), add(mul(rad, -0.25), V(0, 0.7 * (y > 0 and 1 or -1), 0))), V(0, y > 0 and 1 or -1, 0), 0.15, 0.12)
    end
    return c, rad, tng
end

-- A hydraulic brake lever on a bar at `at` (bar centreline), bar direction
-- `bd` (outward), `fwd` ahead; the blade reaches out along the grip.
local function brakeLever(M, group, at, bd, fwd, reach)
    local Bk = M:bucket(group, "black")
    local Al = M:bucket(group, "alloy")
    local Cd = M:bucket(group, "chrome", true)
    local up = norm(cross(fwd, bd))
    if up[3] < 0 then up = mul(up, -1) end
    lathe(Bk, { { 0.44, -0.32, true }, { 0.62, -0.3 }, { 0.62, 0.3 }, { 0.44, 0.32, true } }, at, bd, 16)
    -- master cylinder and its reservoir
    local mc = add(add(at, mul(fwd, 1.0)), mul(up, 0.15))
    sweep(Bk, { add(at, mul(fwd, 0.45)), mc, add(mc, mul(bd, 0.15)) }, function() return 0.36, 0.4 end, 12, { up = up })
    local res = add(mc, add(mul(up, 0.45), mul(fwd, -0.15)))
    box(Bk, res, mul(fwd, 0.55), mul(bd, 0.45), mul(up, 0.25))
    box(Al, add(res, mul(up, 0.26)), mul(fwd, 0.45), mul(bd, 0.37), mul(up, 0.02))
    -- the blade: down and out along the front of the grip, a hooked tip
    local p0 = add(mc, mul(fwd, 0.4))
    local blade = spline({ p0, add(p0, add(mul(fwd, 0.5), mul(up, -0.25))), add(add(at, mul(bd, reach * 0.6)), add(mul(fwd, 1.55), mul(up, -0.45))),
                           add(add(at, mul(bd, reach)), add(mul(fwd, 1.45), mul(up, -0.4))) }, 5)
    sweep(Al, blade, function(t) return 0.13, 0.28 - 0.06 * t end, 10, { up = up })
    capScrew(Cd, add(at, mul(fwd, -0.6)), mul(fwd, -1), 0.12, 0.1)
    return mc
end

-- A saddle lofted from tail to nose round `top` (the sit point on its top):
-- o.back, o.front, o.w(t) half width, o.h thickness, o.role.
local function saddle(B, top, o)
    local st, ring = o.stations or 16, o.ring or 20
    local P = {}
    for i = 0, st do
        local t = i / st
        local x = -o.back + t * (o.back + o.front)
        local w = max(o.w(t), 0.05)
        local h = o.h * (1 - 0.35 * t)
        if t < 0.03 or t > 0.97 then h = h * 0.45 end
        local topz = top[3] - (x < 0 and o.kick or o.drop) * (x / (x < 0 and o.back or o.front)) ^ 2
        P[#P + 1] = {}
        for j = 0, ring - 1 do
            local a = j / ring * TAU
            local ca, sa = cos(a), sin(a)
            local e = 2.8
            local cy = (abs(ca) ^ (2 / e)) * (ca < 0 and -1 or 1)
            local cz = (abs(sa) ^ (2 / e)) * (sa < 0 and -1 or 1)
            local z
            if cz > 0 then z = topz - (1 - cz) * h * 0.5 - 0.12 * cy * cy
            else z = topz - h * 0.5 + cz * h * 0.5 end
            P[#P][j + 1] = V(top[1] + x, top[2] + cy * w, z)
        end
    end
    grid(B, P, true, function(i)
        local s = V(0, 0, 0)
        for _, p in ipairs(P[i]) do s = add(s, p) end
        return mul(s, 1 / #P[i])
    end)
    cap(B, P[1], V(-1, 0, 0))
    cap(B, P[#P], V(1, 0, 0))
end

-- A flat pedal about its own centre: a concave alloy platform with pins
-- (w along the spindle, d front to back).
local function flatPedal(M, group, role, w, d, t, pins)
    local B = M:bucket(group, role)
    local Pin = pins and M:bucket(group, "steel", true)
    local outer = roundRect(d, w, 0.55, 4)
    local inner = roundRect(d - 1.1, w - 1.2, 0.35, 4)
    ringPlate(B, outer, inner, V(0, 0, 0), V(1, 0, 0), V(0, 1, 0), t)
    sweep(B, { V(0, -w / 2 + 0.05, 0), V(0, w / 2 - 0.05, 0) }, function() return 0.36, 0.3 end, 14)
    box(B, V(0, 0, 0), V(0.1, 0, 0), V(0, w / 2 - 0.4, 0), V(0, 0, t * 0.42))
    if pins then
        local pts = {}
        for _, u in ipairs({ -d / 2 + 0.28, d / 2 - 0.28 }) do
            for _, v in ipairs({ -1.55, -0.78, 0, 0.78, 1.55 }) do pts[#pts + 1] = { u, v * w / 4.2 } end
        end
        pts[#pts + 1] = { -0.55, -w / 2 + 0.3 }
        pts[#pts + 1] = { 0.55, w / 2 - 0.3 }
        for _, s in ipairs({ 1, -1 }) do
            for _, q in ipairs(pts) do
                lathe(Pin, { { 0, 0, true }, { 0.075, 0, true }, { 0.075, 0.22 }, { 0.05, 0.26, true }, { 0, 0.26, true } },
                      V(q[1], q[2], t / 2 * s), V(0, 0, s), 6)
            end
        end
    end
end

-- Crank arms, spindle and a chainring (group "cranks") about bb; the arms
-- end ty out, the pedal axles reach to the pedals' inner edges.
local function cranks(M, bb, o)
    local Ar = M:bucket("cranks", o.role or "black")
    local Cd = M:bucket("cranks", "chrome", true)
    sweep(M:bucket("cranks", "steel"), { add(bb, V(0, -o.root - 0.2, 0)), add(bb, V(0, o.root + 0.2, 0)) }, 0.45, 16)
    for _, s in ipairs({ -1, 1 }) do                       -- -1 right: forward at angle 0
        local dir = (s == -1) and V(1, 0, 0) or V(-1, 0, 0)
        local root = V(bb[1], o.root * s, bb[3])
        local tip = add(V(bb[1], o.tip * s, bb[3]), mul(dir, o.len))
        local P = {}
        for i = 0, 12 do
            local t = i / 12
            local c = lerp(root, tip, t)
            local wv = 0.72 - 0.2 * t
            local wy = 0.38 - 0.05 * t
            P[#P + 1] = {}
            for j = 0, 13 do
                local a = j / 14 * TAU
                local ca, sa = cos(a), sin(a)
                local e = 3.4
                P[#P][j + 1] = add(c, V(0, (abs(ca) ^ (2 / e)) * (ca < 0 and -1 or 1) * wy, (abs(sa) ^ (2 / e)) * (sa < 0 and -1 or 1) * wv))
            end
        end
        grid(Ar, P, true, function(i) return lerp(root, tip, (i - 1) / 12) end)
        lathe(Ar, { { 0, -0.45, true }, { 0.95, -0.45, true }, { 1.0, -0.3 }, { 1.0, 0.3 }, { 0.95, 0.45, true }, { 0, 0.45, true } }, root, Y, 22)
        lathe(Ar, { { 0, -0.4, true }, { 0.58, -0.4, true }, { 0.62, -0.25 }, { 0.62, 0.25 }, { 0.58, 0.4, true }, { 0, 0.4, true } }, tip, Y, 16)
        capScrew(Cd, add(root, V(0, 0.45 * s, 0)), V(0, s, 0), 0.36, 0.1)
        sweep(M:bucket("cranks", "steel"), { tip, V(tip[1], o.pedalIn * s, tip[3]) }, 0.24, 8)
    end
    -- the chainring and its spider / direct mount
    local cy = o.chainY
    local pr = sprocket(M:bucket("cranks", o.ringRole or "black"), bb, cy, o.teeth, 0.12, pitchRadius(o.teeth) - 0.62, 6)
    local Al = M:bucket("cranks", o.ringRole or "black")
    lathe(Al, { { pr - 0.72, -0.1, true }, { pr - 0.4, -0.1, true }, { pr - 0.4, 0.1, true }, { pr - 0.72, 0.1, true } }, V(bb[1], cy, bb[3]), Y, 40)
    for i = 0, 3 do
        local a = i / 4 * TAU + 0.4
        local d = V(cos(a), 0, sin(a))
        box(Al, add(V(bb[1], cy + 0.08, bb[3]), mul(d, (pr - 0.55 + 0.9) * 0.5)), mul(d, (pr - 0.55 - 0.9) * 0.5),
            V(0, 0.12, 0), mul(V(-sin(a), 0, cos(a)), 0.32))
        capScrew(Cd, add(V(bb[1], cy - 0.12, bb[3]), mul(d, pr - 0.62)), V(0, -1, 0), 0.12, 0.08)
    end
    lathe(Al, { { 0.45, -0.25, true }, { 1.0, -0.25, true }, { 1.05, 0 }, { 1.0, 0.25, true }, { 0.45, 0.25, true } }, V(bb[1], cy + 0.25, bb[3]), Y, 22)
    return pr
end

-- Grips: ribbed rubber between g0 and g1 (inner to outer), lock-on collars.
local function lockGrip(M, group, g0, g1, collarRole)
    local Rb = M:bucket(group, "rubber")
    local Cl = M:bucket(group, collarRole or "black")
    local Cd = M:bucket(group, "chrome", true)
    local d = norm(sub(g1, g0))
    local gl = len(sub(g1, g0))
    local prof = { { 0.44, 0.35, true }, { 0.7, 0.35, true } }
    local h = 0.45
    while h < gl - 0.6 do
        prof[#prof + 1] = { 0.7, h }
        prof[#prof + 1] = { 0.76, h + 0.08 }
        prof[#prof + 1] = { 0.76, h + 0.2 }
        prof[#prof + 1] = { 0.7, h + 0.28 }
        h = h + 0.36
    end
    prof[#prof + 1] = { 0.7, gl - 0.35, true }
    prof[#prof + 1] = { 0.44, gl - 0.35, true }
    lathe(Rb, prof, g0, d, 20)
    for _, e in ipairs({ { 0, 0.35 }, { gl - 0.35, gl } }) do
        lathe(Cl, { { 0.44, e[1], true }, { 0.74, e[1], true }, { 0.76, (e[1] + e[2]) * 0.5 }, { 0.74, e[2], true }, { 0.44, e[2], true } }, g0, d, 20)
        capScrew(Cd, add(g0, add(mul(d, (e[1] + e[2]) * 0.5), V(0, 0, -0.74))), V(0, 0, -1), 0.1, 0.07)
    end
    lathe(Cl, { { 0, gl, true }, { 0.6, gl, true }, { 0.55, gl + 0.08 }, { 0, gl + 0.1, true } }, g0, d, 16)
end

-- A tread of blocks for a trekking tyre, on the casing G.parts.wheel built.
local function trekTread(M, group, R, n)
    local K = M:bucket(group, "rubber", true)
    local c = (R.outer + R.bead) * 0.5 + 0.05 * R.s
    local a = R.outer - c
    local b = R.tyreW * 0.5
    for ri, yf in ipairs({ -0.62, -0.3, 0, 0.3, 0.62 }) do
        local y = yf * b
        local tt = math.asin(max(-1, min(1, y / b)))
        local rr = c + cos(tt) * a
        local nr, ny = cos(tt) / a, sin(tt) / b
        local nl = sqrt(nr * nr + ny * ny)
        nr, ny = nr / nl, ny / nl
        local m = (yf == 0) and n or floor(n * 0.6)
        for i = 0, m - 1 do
            local ang = (i + (ri % 2) * 0.5) / m * TAU
            local rad = V(cos(ang), 0, sin(ang))
            local tang = V(-sin(ang), 0, cos(ang))
            local nrm = norm(add(mul(rad, nr), V(0, ny, 0)))
            local side = norm(cross(nrm, tang))
            local h = 0.09
            local ctr = add(add(mul(rad, rr - 0.02), V(0, y, 0)), mul(nrm, h * 0.5))
            if yf == 0 then
                box(K, ctr, mul(tang, 0.1), mul(side, 0.3), mul(nrm, h * 0.5))
            else
                local sk = (yf < 0) and 0.35 or -0.35
                box(K, ctr, add(mul(tang, 0.17), mul(side, sk * 0.17)), mul(side, 0.2), mul(nrm, h * 0.5))
            end
        end
    end
end

-- An axle along y at p, half length h, with end nuts/caps.
local function axleParts(M, group, p, h, r)
    sweep(M:bucket(group, "alloy"), { add(p, V(0, -h, 0)), add(p, V(0, h, 0)) }, r or 0.3, 12)
    for _, s in ipairs({ 1, -1 }) do
        lathe(M:bucket(group, "black", true), { { 0, 0, true }, { 0.48, 0, true }, { 0.5, 0.1 }, { 0.48, 0.2, true }, { 0, 0.22, true } },
              add(p, V(0, h * s, 0)), V(0, s, 0), 12)
    end
end

--------------------------------------------------------------------------
-- THE DOWNHILL BIKE
--------------------------------------------------------------------------
G.RegisterKind("dh", function(opt, G)
    local M = Pm.newModel()
    local wb = opt.wheelbase or 46
    local R = opt.radius or 13.5
    local k = opt.k or wb / 39
    local seat = opt.seat or { -12.4, 0, 21.2 }
    local rear, front = V(-wb / 2, 0, 0), V(wb / 2, 0, 0)
    local sit = V(seat[1] - 0.5, 0, seat[3] + 2.0)
    local bb = V(-4.5 * k, 0, 2.5 * k)
    local travel = 6.0

    local P = M:bucket("frame", "paint")
    local Bk = M:bucket("frame", "black")
    local Cd = M:bucket("frame", "chrome", true)
    local Al = M:bucket("frame", "alloy")

    -- STEERING: 63 degrees, dual-crown offset, axle to crown for the travel
    local ha = math.rad(63)
    local u = V(-cos(ha), 0, sin(ha))
    local fwdP = V(sin(ha), 0, cos(ha))
    local off = 2.2
    local legY = 2.95
    local a2c = R + travel + 2.6                          -- axle to the lower crown's middle, along the legs
    local lcLeg = add(front, mul(u, a2c))                 -- lower crown on the legs' axis
    local lcSt = sub(lcLeg, mul(fwdP, off))               -- ... and on the steer axis
    local headB = add(lcSt, mul(u, 0.9))
    local htLen = 4.8
    local headT = add(headB, mul(u, htLen))
    local ucSt = add(headT, mul(u, 0.95))                 -- upper crown on the steer axis
    local ucLeg = add(ucSt, mul(fwdP, off))
    local stemTop = add(ucSt, mul(u, 0.9))

    -- seat tube toward the saddle
    local stDir = norm(sub(add(sit, V(0.9, 0, -3.0)), bb))
    local function onST(z) return add(bb, mul(stDir, (z - bb[3]) / stDir[3])) end
    local stTop = onST(sit[3] - 4.4)
    local postTop = onST(sit[3] - 1.4)

    -- REAR SUSPENSION: a single pivot above the ring, a yoke to the shock
    local piv = V(bb[1] + 2.0, 0, bb[3] + 4.5)
    local shS = V(bb[1] - 1.1, 0, bb[3] + 13.3)           -- the shock's swingarm eye
    local shDir = norm(V(0.978, 0, -0.208))
    local shF = add(shS, mul(shDir, 9.5))                 -- the shock's frame eye
    local bridge = V(sit[1] + 0.6, 0, bb[3] + 11.9)       -- where the stays meet behind the seat tube
    local dropY = 3.15
    local hubR, hubF = 3.0, 2.3

    ------------------------------------------------------------------
    -- FRONT TRIANGLE
    ------------------------------------------------------------------
    -- head tube: tapered, with the headset's cups
    do
        local h1 = htLen
        lathe(P, { { 0, -0.35, true }, { 1.2, -0.35, true }, { 1.22, -0.2 }, { 1.12, 0.6 }, { 1.0, 1.8 }, { 0.96, h1 - 0.6 },
                   { 1.0, h1 - 0.1 }, { 0.98, h1 + 0.3, true }, { 0, h1 + 0.3, true } }, headB, u, 28)
        lathe(Bk, { { 0.7, 0, true }, { 1.18, 0, true }, { 1.18, 0.3, true }, { 0.7, 0.3, true } }, sub(headB, mul(u, 0.65)), u, 28)
        lathe(Bk, { { 0.7, 0, true }, { 1.0, 0, true }, { 1.0, 0.25, true }, { 0.7, 0.25, true } }, add(headT, mul(u, 0.3)), u, 28)
    end
    -- down tube: big, square-ish, from the head tube to the bb junction
    local dt0 = add(headB, mul(u, 1.1))
    local dt1 = add(bb, V(1.0, 0, 0.9))
    local dtPts = bez3(add(dt0, mul(fwdP, -0.3)), lerp(dt0, dt1, 0.33), add(lerp(dt0, dt1, 0.7), V(0, 0, -0.25)), dt1, 18)
    rrTube(P, dtPts, function(t) return 1.2 - 0.15 * t end, function(t) return 0.95 - 0.1 * t end, 0.55, 24, V(0, 0, 1))
    -- top tube: from high on the head tube, down to the seat tube
    local tt0 = sub(headT, mul(u, 1.0))
    local tt1 = onST(sit[3] - 6.3)
    local ttPts = bez3(add(tt0, mul(fwdP, -0.4)), add(lerp(tt0, tt1, 0.35), V(0, 0, 0.35)), lerp(tt0, tt1, 0.7), tt1, 16)
    rrTube(P, ttPts, function(t) return 0.9 - 0.2 * t end, function(t) return 0.68 - 0.08 * t end, 0.45, 22, V(0, 0, 1))
    -- seat tube
    sweep(P, { add(bb, mul(stDir, 0.8)), stTop }, function(t) return 0.86 - 0.08 * t end, 22, { capStart = false })
    lathe(Bk, { { 0.78, -0.55, true }, { 0.92, -0.5 }, { 0.92, 0.2 }, { 0.78, 0.25, true } }, stTop, stDir, 20)
    capScrew(Cd, add(sub(stTop, mul(stDir, 0.15)), V(-0.95, 0, 0)), V(-1, 0, 0), 0.13, 0.1)
    -- gusset under the top tube / seat tube joint
    do
        local a = ttPts[#ttPts - 3]
        local b = onST(tt1[3] - 3.0)
        local loop = { { tt1[1] + 0.2, tt1[3] }, { a[1], a[3] - 0.5 }, { lerp(a, b, 0.5)[1] + 0.6, lerp(a, b, 0.5)[3] + 0.0 }, { b[1] + 0.5, b[3] } }
        plate(P, loop, V(0, 0, 0), V(1, 0, 0), V(0, 0, 1), 0.5, { smooth = true })
    end
    -- BB shell (83 mm) and the forged junction that carries the pivot
    lathe(P, { { 0, -1.68, true }, { 0.98, -1.68, true }, { 1.04, -1.5 }, { 1.04, 1.5 }, { 0.98, 1.68, true }, { 0, 1.68, true } }, bb, Y, 28)
    do
        local loop = circleHull({ { bb[1], bb[3], 1.25 }, { piv[1], piv[3], 1.25 }, { dt1[1] + 1.6, dt1[3] + 1.4, 1.0 },
                                  { onST(bb[3] + 5.2)[1], bb[3] + 5.2, 0.85 } }, 20)
        local fr = {}
        for i, yy in ipairs({ -1.25, -1.05, 1.05, 1.25 }) do
            fr[i] = { V(0, yy, 0), V(1, 0, 0), V(0, 0, 1) }
        end
        ext(P, fr, function(i)
            if i == 1 or i == 4 then
                local c = { 0, 0 }
                for _, q in ipairs(loop) do c[1], c[2] = c[1] + q[1], c[2] + q[2] end
                c[1], c[2] = c[1] / #loop, c[2] / #loop
                local out = {}
                for j, q in ipairs(loop) do out[j] = { c[1] + (q[1] - c[1]) * 0.94, c[2] + (q[2] - c[2]) * 0.94 } end
                return out
            end
            return loop
        end)
    end
    -- the main pivot's axle and its caps
    sweep(Al, { add(piv, V(0, -2.55, 0)), add(piv, V(0, 2.55, 0)) }, 0.42, 16)
    for _, s in ipairs({ 1, -1 }) do
        lathe(Bk, { { 0, 0, true }, { 0.62, 0, true }, { 0.62, 0.15 }, { 0.5, 0.22, true }, { 0, 0.22, true } }, add(piv, V(0, 2.55 * s, 0)), V(0, s, 0), 16)
    end
    -- the shock's frame mount: two ears on the down tube with the bolt
    do
        local dtAt = shF[1]
        local best, bi = 1e9, 1
        for i, q in ipairs(dtPts) do local d = abs(q[1] - dtAt) if d < best then best, bi = d, i end end
        local base = dtPts[bi]
        for _, s in ipairs({ 1, -1 }) do
            local loop = circleHull({ { shF[1], shF[3], 0.62 }, { base[1] - 1.1, base[3] + 0.4, 0.5 }, { base[1] + 1.2, base[3] + 0.4, 0.5 } }, 16)
            plate(P, loop, V(0, 0.95 * s, 0), V(1, 0, 0), V(0, 0, 1), 0.3, { smooth = true })
            capScrew(Cd, V(shF[1], 1.12 * s, shF[3]), V(0, s, 0), 0.2, 0.12)
        end
        sweep(Al, { V(shF[1], -1.1, shF[3]), V(shF[1], 1.1, shF[3]) }, 0.18, 10)
    end
    -- cable and hose runs under the down tube
    for _, yy in ipairs({ 0.45, -0.45 }) do
        local run = {}
        for i = 2, #dtPts - 3 do
            local q = dtPts[i]
            run[#run + 1] = add(q, V(0, yy, -1.25))
        end
        sweep(M:bucket("frame", "black", true), run, 0.1, 6)
    end
    -- the chain guide: ISCG backplate, the upper guide, a bash guard
    local ringT = 36
    local ringPR = pitchRadius(ringT)
    local chainY = -1.97
    do
        local Gb = M:bucket("frame", "black")
        local bp = circleHull({ { bb[1], bb[3], 1.6 }, { bb[1] - 2.0, bb[3] + 2.1, 0.5 }, { bb[1] + 2.5, bb[3] + 1.4, 0.5 }, { bb[1] + 0.6, bb[3] - 2.3, 0.5 } }, 16)
        plate(Gb, bp, V(0, -1.75, 0), V(1, 0, 0), V(0, 0, 1), 0.14)
        -- upper guide: a slider box over the ring's top, behind
        local ga = math.rad(118)
        local gp = V(bb[1] + cos(ga) * (ringPR + 0.15), chainY, bb[3] + sin(ga) * (ringPR + 0.15))
        local gt = V(-sin(ga), 0, cos(ga))
        local gr = V(cos(ga), 0, sin(ga))
        for _, s in ipairs({ 1, -1 }) do
            box(Gb, add(gp, V(0, 0.32 * s, 0)), mul(gt, 0.9), V(0, 0.07, 0), mul(gr, 0.55))
        end
        box(Gb, add(gp, mul(gr, 0.55)), mul(gt, 0.9), V(0, 0.39, 0), mul(gr, 0.07))
        sweep(Gb, { add(bb, V(-2.0, -1.75, 2.1)), add(gp, V(0, 0.35, 0)) }, function() return 0.32, 0.1 end, 8, { up = Y })
        -- bash guard: an arc of plate under the ring, outboard of the chain
        local loop = {}
        for i = 0, 16 do
            local a = math.rad(195) + i / 16 * math.rad(150)
            loop[#loop + 1] = { bb[1] + cos(a) * (ringPR + 0.75), bb[3] + sin(a) * (ringPR + 0.75) }
        end
        for i = 16, 0, -1 do
            local a = math.rad(195) + i / 16 * math.rad(150)
            loop[#loop + 1] = { bb[1] + cos(a) * (ringPR - 0.25), bb[3] + sin(a) * (ringPR - 0.25) }
        end
        plate(Gb, loop, V(0, -2.42, 0), V(1, 0, 0), V(0, 0, 1), 0.2, { smooth = false })
        for _, a in ipairs({ math.rad(215), math.rad(325) }) do
            local p = V(bb[1] + cos(a) * (ringPR - 0.05), -2.55, bb[3] + sin(a) * (ringPR - 0.05))
            capScrew(Cd, p, V(0, -1, 0), 0.13, 0.08)
            sweep(Gb, { add(p, V(0, 0.15, 0)), V(p[1], -1.75, p[3]) }, 0.12, 6)
        end
    end
    -- the saddle: low, flat, on a short black post
    do
        local Bp = M:bucket("frame", "black")
        sweep(Bp, { sub(stTop, mul(stDir, 2.5)), postTop }, 0.6, 18, { capStart = false })
        local hd = add(postTop, mul(stDir, 0.2))
        box(Bp, add(hd, V(0, 0, 0.25)), V(1.0, 0, 0), V(0, 0.55, 0), V(0, 0, 0.22))
        capScrew(Cd, add(hd, V(-0.7, 0, 0.47)), V(0, 0, 1), 0.13, 0.1)
        capScrew(Cd, add(hd, V(0.7, 0, 0.47)), V(0, 0, 1), 0.13, 0.1)
        for _, s in ipairs({ 1, -1 }) do
            sweep(M:bucket("frame", "steel"), spline({ V(sit[1] - 3.1, 1.15 * s, sit[3] - 0.95), V(hd[1] - 1.5, 0.75 * s, hd[3] + 0.5),
                V(hd[1] + 1.5, 0.75 * s, hd[3] + 0.5), V(sit[1] + 5.2, 0.4 * s, sit[3] - 0.85) }, 4), 0.11, 8)
        end
        saddle(M:bucket("frame", "seat"), sit, { back = 3.9, front = 6.4, h = 1.25, kick = 0.1, drop = 0.35,
            w = function(t)
                if t < 0.08 then return 2.6 * sqrt(max(0.02, t / 0.08)) end
                if t < 0.38 then return 2.7 - 0.25 * (t - 0.08) / 0.3 end
                local w2 = 2.45 - 1.85 * min(1, (t - 0.38) / 0.55) ^ 0.8
                if t > 0.95 then w2 = w2 * sqrt(max(0.05, (1 - t) / 0.05)) end
                return w2
            end })
    end

    ------------------------------------------------------------------
    -- SWINGARM (turns about the pivot)
    ------------------------------------------------------------------
    local SP = M:bucket("swingarm", "paint")
    local SB = M:bucket("swingarm", "black")
    local SCd = M:bucket("swingarm", "chrome", true)
    do
        -- pivot bosses outside the junction
        for _, s in ipairs({ 1, -1 }) do
            lathe(SP, { { 0, -0.55, true }, { 0.9, -0.55, true }, { 0.98, -0.4 }, { 0.98, 0.4 }, { 0.9, 0.55, true }, { 0, 0.55, true } },
                  add(piv, V(0, 1.85 * s, 0)), Y, 22)
        end
        -- chain stays: inboard of the chain until behind the ring, then out to the dropouts
        local function cstay(s)
            local yIn = (s < 0) and 1.35 or 1.85
            return spline({ add(piv, V(-0.4, 1.85 * s, -0.1)), add(piv, V(-3.5, yIn * s, -1.6)), V(rear[1] + 7.5, yIn * s, rear[3] + 1.6),
                            V(rear[1] + 3.2, (dropY - 0.1) * s, rear[3] + 0.55), V(rear[1] + 1.3, dropY * s, rear[3] + 0.35) }, 5)
        end
        local function sstay(s)
            return spline({ V(rear[1] + 0.9, dropY * s, rear[3] + 1.0), V(rear[1] + 3.5, (dropY - 0.25) * s, rear[3] + 4.6),
                            add(bridge, V(-1.6, 2.0 * s, -1.9)), add(bridge, V(0, 1.75 * s, 0)) }, 6)
        end
        for _, s in ipairs({ 1, -1 }) do
            rrTube(SP, cstay(s), function(t) return 0.75 - 0.3 * t end, function(t) return 0.45 - 0.1 * t end, 0.3, 18, V(0, 0, 1))
            rrTube(SP, sstay(s), function(t) return 0.42 + 0.2 * t end, 0.36, 0.28, 16, V(0, 0, 1))
            -- the yoke: from the bridge forward past the seat tube to the shock
            local yk = spline({ add(bridge, V(-0.2, 1.75 * s, 0)), add(bridge, V(2.0, 1.6 * s, 1.1)), add(shS, V(-1.5, 1.15 * s, 0.1)), add(shS, V(0.3, 1.05 * s, 0)) }, 5)
            rrTube(SP, yk, function(t) return 0.75 - 0.15 * t end, 0.32, 0.25, 16, V(0, 0, 1))
            -- the brace: from the bridge down to the pivot boss, closing the triangle
            local br = spline({ add(bridge, V(0.1, 1.85 * s, -0.2)), lerp(add(bridge, V(0, 1.9 * s, 0)), add(piv, V(0, 1.85 * s, 0)), 0.5),
                                add(piv, V(-0.5, 1.85 * s, 0.6)) }, 5)
            rrTube(SP, br, 0.55, 0.36, 0.25, 16, V(0, 0, 1))
            -- the dropout plate round the axle
            local loop = circleHull({ { rear[1], rear[3], 0.95 }, { rear[1] + 1.5, rear[3] + 0.45, 0.55 }, { rear[1] + 0.9, rear[3] + 1.25, 0.5 } }, 16)
            plate(SP, loop, V(0, dropY * s, 0), V(1, 0, 0), V(0, 0, 1), 0.36, { smooth = true })
        end
        -- the bridges
        sweep(SP, { add(bridge, V(0, 1.8, 0)), add(bridge, V(0, -1.8, 0)) }, 0.48, 14, { capStart = false, capEnd = false })
        do
            local l, r = cstay(1), cstay(-1)
            local i = floor(#l * 0.45)
            rrTube(SP, { l[i], r[i] }, 0.45, 0.4, 0.2, 14, V(0, 0, 1))
        end
        -- the shock's swingarm eye: a cross bolt through the yoke's ends
        sweep(M:bucket("swingarm", "alloy"), { add(shS, V(0.3, -1.25, 0)), add(shS, V(0.3, 1.25, 0)) }, 0.2, 10)
        for _, s in ipairs({ 1, -1 }) do capScrew(SCd, add(shS, V(0.3, 1.25 * s, 0)), V(0, s, 0), 0.2, 0.1) end
        -- the rear thru-axle
        axleParts(M, "swingarm", rear, dropY + 0.25, 0.3)
        -- the hanger and the derailleur, the brake on the left
        local hang = V(rear[1] - 0.2, -dropY - 0.3, rear[3] - 1.0)
        plate(SB, circleHull({ { rear[1], rear[3], 0.6 }, { hang[1], hang[3], 0.45 } }, 12), V(0, -dropY - 0.24, 0), V(1, 0, 0), V(0, 0, 1), 0.14)
    end

    -- THE REAR WHEEL'S DRIVE: cassette (on the wheel), chain and derailleur
    local cogs = { 24, 21, 18, 16, 14, 12, 11 }
    local cogY = cassette(M, "wheelR", cogs, -1.46, 0.17)
    local onCog = 4
    local up = V(rear[1] - 0.25, chainY, rear[3] - pitchRadius(cogs[onCog]) - pitchRadius(11) - 0.35)
    local lo = V(up[1] + 0.85, chainY, up[3] - 2.65)
    derailleur(M, "swingarm", V(rear[1] - 0.2, -dropY - 0.3, rear[3] - 1.0), up, lo, chainY)
    do
        local path = chainPath({ { bb[1], bb[3], ringPR, 1 }, { rear[1], rear[3], pitchRadius(cogs[onCog]), 1 },
                                 { up[1], up[3], pitchRadius(11), -1 }, { lo[1], lo[3], pitchRadius(11), 1 } })
        chainLinks(M:bucket("swingarm", "steel", true), path, chainY)
    end
    -- rear brake: 203 mm rotor (on the wheel), four-piston caliper on the left
    local rotor = 4.0
    do
        local cc = caliper(M, "swingarm", rear, rotor, hubR - 0.12, math.rad(148), true)
        -- its post mount out of the seat stay
        local a = math.rad(148)
        local pm = add(rear, mul(V(cos(a), 0, sin(a)), rotor + 0.2))
        box(SB, V(pm[1], hubR + 0.25, pm[3]), V(0.9, 0, 0.3), V(0, 0.18, 0), V(-0.15, 0, 0.5))
        sweep(M:bucket("swingarm", "black", true), spline({ add(cc, V(0.2, 0.8, 0.5)), V(rear[1] + 4.0, 2.4, 3.6), add(bridge, V(1.5, 2.2, -2.5)), add(piv, V(-0.5, 2.6, 1.0)) }, 6), 0.1, 6)
    end

    ------------------------------------------------------------------
    -- FORK: crowns, stanchions and steerer (steer); lowers slide
    ------------------------------------------------------------------
    local FB = M:bucket("fork", "black")
    local FA = M:bucket("fork", "alloy")
    local FCd = M:bucket("fork", "chrome", true)
    local sealD = R + 1.1                                  -- along the legs from the axle, the lowers' seals
    do
        -- steerer through the head tube
        sweep(FB, { lcSt, add(ucSt, mul(u, 0.3)) }, 0.62, 18, { capStart = false, capEnd = false })
        -- the crowns: forged plates clamping the stanchions and the steerer
        local function crownAt(cSt, th)
            local fr = {}
            for i = 0, 3 do
                local q = i / 3
                fr[#fr + 1] = { add(cSt, mul(u, (q - 0.5) * th)), fwdP, Y }
            end
            local loop = circleHull({ { 0, 0, 1.05 }, { off, legY, 1.15 }, { off, -legY, 1.15 }, { off + 0.4, 0, 0.6 } }, 18)
            ext(FB, fr, function(i)
                if i == 1 or i == 4 then
                    local out = {}
                    for j, q in ipairs(loop) do out[j] = { q[1] * 0.96 + off * 0.02, q[2] * 0.97 } end
                    return out
                end
                return loop
            end)
            for _, s in ipairs({ 1, -1 }) do
                capScrew(FCd, add(add(cSt, add(mul(fwdP, off + 1.15), V(0, legY * s, 0))), V(0, 0, 0)), fwdP, 0.13, 0.1)
            end
        end
        crownAt(lcSt, 1.3)
        crownAt(ucSt, 0.9)
        -- stanchions: from above the upper crown to inside the lowers
        for _, s in ipairs({ 1, -1 }) do
            local top = add(add(ucLeg, mul(u, 0.75)), V(0, legY * s, 0))
            local bot = add(add(front, mul(u, sealD - 1.5)), V(0, legY * s, 0))
            sweep(FA, { bot, top }, 0.74, 22, { capStart = false })
            lathe(FB, { { 0, 0, true }, { 0.7, 0, true }, { 0.72, 0.2 }, { 0.6, 0.3, true }, { 0, 0.32, true } }, top, u, 18)
            lathe(M:bucket("fork", "redlens", true), { { 0, 0, true }, { 0.28, 0, true }, { 0.28, 0.22, true }, { 0, 0.22, true } }, add(top, mul(u, 0.3)), u, 12)
        end
        -- the stem's top cap
        lathe(FB, { { 0, 0, true }, { 0.7, 0, true }, { 0.66, 0.15 }, { 0, 0.18, true } }, add(ucSt, mul(u, 0.45)), u, 16)
    end
    -- LOWERS (slide): legs, arch, axle, caliper
    local LB = M:bucket("forkLower", "black")
    local LR = M:bucket("forkLower", "rubber")
    do
        for _, s in ipairs({ 1, -1 }) do
            local o = add(front, V(0, legY * s, 0))
            lathe(LB, { { 0, -0.95, true }, { 0.75, -0.95, true }, { 0.98, -0.6 }, { 1.02, 0.2 }, { 0.99, 3.0 }, { 0.97, sealD - 1.6 },
                        { 1.02, sealD - 0.9 }, { 1.02, sealD - 0.25, true }, { 0.82, sealD - 0.2, true }, { 0, sealD - 0.2, true } }, o, u, 24)
            lathe(LR, { { 0.74, 0, true }, { 0.98, 0, true }, { 0.92, 0.3 }, { 0.76, 0.42, true } }, add(o, mul(u, sealD - 0.22)), u, 22)
            -- the axle boss at the foot
            lathe(LB, { { 0, -0.55, true }, { 0.85, -0.55, true }, { 0.9, -0.3 }, { 0.9, 0.3 }, { 0.85, 0.55, true }, { 0, 0.55, true } },
                  V(front[1], (legY - 0.1) * s, front[3]), Y, 20)
        end
        -- the arch over the tyre, in front
        local arch = {}
        for i = 0, 14 do
            local t = i / 14
            local y = (t * 2 - 1) * legY
            local e = 1 - (y / legY) ^ 2
            arch[#arch + 1] = add(add(front, mul(u, sealD - 2.2 + 1.3 * e)), add(mul(fwdP, 0.65 + 0.85 * e), V(0, y, 0)))
        end
        rrTube(LB, arch, function(t) return 0.62 + 0.1 * sin(t * pi) end, 0.42, 0.3, 16, u)
        axleParts(M, "forkLower", front, legY + 0.6, 0.32)
        -- caliper on the left leg's post mount, behind and above the axle
        local a = atan2(u[3] * 0.85 - fwdP[3] * 0.55, u[1] * 0.85 - fwdP[1] * 0.55)
        local cc = caliper(M, "forkLower", front, rotor, hubF - 0.12, a, true)
        local pm = add(front, mul(V(cos(a), 0, sin(a)), rotor + 0.1))
        box(LB, V(pm[1], legY - 0.3, pm[3]), mul(norm(V(-sin(a), 0, cos(a))), 1.0), V(0, 0.4, 0), mul(V(cos(a), 0, sin(a)), 0.35))
        sweep(M:bucket("forkLower", "black", true), spline({ add(cc, V(0, 0.75, 0.3)), add(add(front, mul(u, 7)), add(mul(fwdP, -1.4), V(0, legY - 0.3, 0))),
            add(add(front, mul(u, sealD - 0.8)), add(mul(fwdP, -1.2), V(0, legY - 0.2, 0))) }, 6), 0.1, 6)
    end

    ------------------------------------------------------------------
    -- BARS: direct-mount stem, 800 mm risers, lock-on grips, levers
    ------------------------------------------------------------------
    local gripR, gripL
    local bellAt
    local clamp = add(add(ucSt, mul(u, 1.5)), V(3.3, 0, 0))
    do
        local BB = M:bucket("bars", "black")
        local BCd = M:bucket("bars", "chrome", true)
        -- the stem: a block on the upper crown, the bar clamp at its nose
        local base = add(ucSt, mul(u, 0.55))
        local fr = {}
        local sp = { base, add(base, add(mul(fwdP, 1.2), mul(u, 0.3))), sub(clamp, V(0.7, 0, 0.1)) }
        rrTube(BB, spline(sp, 4), 0.6, 1.05, 0.3, 20, V(0, 0, 1))
        lathe(BB, { { 0, -1.25, true }, { 0.82, -1.25, true }, { 0.86, -1.1 }, { 0.86, 1.1 }, { 0.82, 1.25, true }, { 0, 1.25, true } }, clamp, Y, 22)
        box(BB, add(clamp, V(0.8, 0, 0)), V(0.18, 0, 0), V(0, 1.15, 0), V(0, 0, 0.75))
        for _, s in ipairs({ 1, -1 }) do
            for _, zz in ipairs({ 0.45, -0.45 }) do capScrew(BCd, add(clamp, V(0.98, 0.75 * s, zz)), V(1, 0, 0), 0.13, 0.1) end
            capScrew(BCd, add(base, V(0.2, 0.95 * s, 0.35)), V(0, 0, 1), 0.13, 0.1)
        end
        -- the bars: 31.8 at the clamp, 22.2 at the grips, rise and backsweep
        local rise = 2.7
        local gz = clamp[3] + rise
        local function side(s)
            return { clamp, add(clamp, V(0, 1.6 * s, 0)), add(clamp, V(-0.05, 3.4 * s, 0.25)), add(clamp, V(-0.2, 5.0 * s, rise - 0.6)),
                     V(clamp[1] - 0.2, 6.4 * s, gz), V(clamp[1] - 0.45, 11.0 * s, gz + 0.12), V(clamp[1] - 0.75, 15.9 * s, gz + 0.25) }
        end
        local L, Rr = side(1), side(-1)
        local all = {}
        for i = #Rr, 2, -1 do all[#all + 1] = Rr[i] end
        for i = 1, #L do all[#all + 1] = L[i] end
        local path = spline(all, 6)
        sweep(BB, path, function(t)
            local e = abs(t * 2 - 1)
            return 0.44 + 0.2 * max(0, 1 - e / 0.3)
        end, 16)
        -- grips
        for _, s in ipairs({ 1, -1 }) do
            local sd = side(s)
            local d = norm(sub(sd[7], sd[6]))
            local g0 = add(sd[6], mul(d, (10.85 - 11.0) / max(abs(d[2]), 0.5)))
            local g1 = add(sd[7], mul(d, 0.05))
            lockGrip(M, "bars", g0, g1, "black")
            if s < 0 then gripR = { A = add(g0, mul(d, 0.3)), B = sub(g1, mul(d, 0.2)) }
            else gripL = { A = add(g0, mul(d, 0.3)), B = sub(g1, mul(d, 0.2)) } end
            -- the brake lever just inboard of the grip
            local la = sub(g0, mul(d, 0.55))
            brakeLever(M, "bars", la, d, V(1, 0, 0), 3.2)
            if s < 0 then
                -- the shifter pod under the bar, inboard of the lever
                local sp2 = sub(la, mul(d, 1.0))
                lathe(BB, { { 0.44, -0.25, true }, { 0.6, -0.25, true }, { 0.6, 0.25, true }, { 0.44, 0.25, true } }, sp2, d, 14)
                box(BB, add(sp2, V(0.2, 0, -0.75)), V(0.7, 0, 0.1), V(0, 0.32, 0), V(-0.1, 0, 0.45))
                sweep(M:bucket("bars", "alloy"), { add(sp2, V(0.4, -0.1, -1.1)), add(sp2, V(1.2, -0.3, -1.25)) }, function() return 0.25, 0.07 end, 8, { up = V(0, 0, 1) })
            else
                bellAt = sub(la, mul(d, 1.15))
            end
            -- the hose from the lever, looping down in front
            local mc = add(la, V(1.0, 0, 0.15))
            sweep(M:bucket("bars", "black", true), spline({ add(mc, V(0.4, 0, -0.2)), add(mc, V(2.0, -1.5 * s, -2.5)),
                add(clamp, V(2.2, 1.6 * s, -3.6)), add(lcLeg, V(0.6, 1.4 * s, 0.9)) }, 6), 0.1, 6)
        end
    end
    local bellPivot, bellAxis = G.parts.bell(M, "bars", "bellLever", bellAt, V(0, 1, 0), V(0, 0, 1), V(-1, 0, 0))

    ------------------------------------------------------------------
    -- WHEELS: 27.5 x 2.5 knobblies on wide black rims, big rotors
    ------------------------------------------------------------------
    local RD = G.WheelDims(R, { width = 2.5, rimW = 1.3 })
    G.parts.wheel(M, "wheelF", RD, { tread = "knobby", wall = "rubber", rim = "black", spokes = 32, cross = 3,
        spokeR = 0.05, hubHalf = hubF, hubRole = "black", disc = rotor })
    G.parts.wheel(M, "wheelR", RD, { rear = true, cog = false, tread = "knobby", wall = "rubber", rim = "black",
        spokes = 32, cross = 3, spokeR = 0.05, hubHalf = hubR, hubRole = "black", disc = rotor })

    ------------------------------------------------------------------
    -- CRANKS AND PEDALS
    ------------------------------------------------------------------
    local crankL, pedalY = 6.8, 5.3
    cranks(M, bb, { root = 2.3, tip = 2.75, len = crankL, pedalIn = pedalY - 2.0, chainY = chainY, teeth = ringT, role = "black", ringRole = "black" })
    flatPedal(M, "pedal", "black", 4.1, 4.0, 0.55, true)

    M.layout = {
        k = k, steer = u,
        headT = headT, headB = headB, stemTop = stemTop,
        rear = rear, front = front, bb = bb,
        crank = crankL, pedalY = pedalY,
        gripR = gripR, gripL = gripL,
        bellPivot = bellPivot, bellAxis = bellAxis,
        swingPivot = piv,
        shock = { frame = shF, swing = shS, r = 0.9 },
        forkSlide = travel,
        stand = add(bb, V(-3.5, 1.8, 0.3)),
    }
    return M
end)

--------------------------------------------------------------------------
-- THE E-BIKE
--------------------------------------------------------------------------
G.RegisterKind("ebike", function(opt, G)
    local M = Pm.newModel()
    local wb = opt.wheelbase or 44
    local R = opt.radius or 11.5
    local k = opt.k or wb / 39
    local seat = opt.seat or { -11.85, 0, 20.3 }
    local rear, front = V(-wb / 2, 0, 0), V(wb / 2, 0, 0)
    local sit = V(seat[1] - 0.5, 0, seat[3] + 2.0)
    local bb = V(-4.5 * k, 0, 2.5 * k)

    local P = M:bucket("frame", "paint")
    local Bk = M:bucket("frame", "black")
    local Pl = M:bucket("frame", "plastic")
    local Cd = M:bucket("frame", "chrome", true)
    local Al = M:bucket("frame", "alloy")

    local ha = math.rad(69)
    local u = V(-cos(ha), 0, sin(ha))
    local fwdP = V(sin(ha), 0, cos(ha))
    local off = 1.8
    local legY = 2.55
    local travel = 3.2
    local a2c = R + travel + 2.4
    local crLeg = add(front, mul(u, a2c))
    local crSt = sub(crLeg, mul(fwdP, off))
    local headB = add(crSt, mul(u, 0.85))
    local htLen = 7.6
    local headT = add(headB, mul(u, htLen))
    local stemBase = add(headT, mul(u, 1.5))
    local stemTop = stemBase
    local stDir = norm(sub(add(sit, V(0.9, 0, -3.0)), bb))
    local function onST(z) return add(bb, mul(stDir, (z - bb[3]) / stDir[3])) end
    local stTop = onST(sit[3] - 5.2)
    local postTop = onST(sit[3] - 1.6)
    local dropY = 2.75
    local hubR, hubF = 2.65, 2.0
    local RD = G.WheelDims(R, { width = 2.25 })

    ------------------------------------------------------------------
    -- FRAME: aluminium, smooth welds, the battery in the down tube
    ------------------------------------------------------------------
    lathe(P, { { 0, -0.3, true }, { 1.12, -0.3, true }, { 1.15, -0.15 }, { 1.05, 0.6 }, { 0.98, 1.6 }, { 0.95, htLen - 0.5 },
               { 0.98, htLen - 0.1 }, { 0.96, htLen + 0.25, true }, { 0, htLen + 0.25, true } }, headB, u, 28)
    lathe(Bk, { { 0.6, 0, true }, { 0.98, 0, true }, { 0.98, 0.3, true }, { 0.6, 0.3, true } }, add(headT, mul(u, 0.25)), u, 24)
    -- the motor: a housing round the bottom bracket
    local mot = {}
    do
        local loop = circleHull({ { bb[1], bb[3], 2.0 }, { bb[1] + 2.9, bb[3] + 2.1, 1.5 }, { bb[1] - 3.4, bb[3] - 0.2, 1.9 },
                                  { bb[1] + 1.0, bb[3] - 1.0, 2.0 }, { bb[1] - 2.2, bb[3] + 2.4, 1.0 } }, 24)
        local fr = {}
        local ys = { -1.6, -1.45, -1.2, 1.55, 1.8, 1.95 }
        local sc = { 0.88, 0.96, 1, 1, 0.96, 0.88 }
        for i, yy in ipairs(ys) do fr[i] = { V(0, yy, 0), V(1, 0, 0), V(0, 0, 1) } end
        local c = { 0, 0 }
        for _, q in ipairs(loop) do c[1], c[2] = c[1] + q[1], c[2] + q[2] end
        c[1], c[2] = c[1] / #loop, c[2] / #loop
        ext(Pl, fr, function(i)
            local out = {}
            for j, q in ipairs(loop) do out[j] = { c[1] + (q[1] - c[1]) * sc[i], c[2] + (q[2] - c[2]) * sc[i] } end
            return out
        end)
        mot.c = c
        -- the frame's motor cradle: painted plates over the housing's top
        for _, s in ipairs({ 1, -1 }) do
            local cr = circleHull({ { bb[1] + 2.7, bb[3] + 2.4, 1.35 }, { bb[1] - 1.9, bb[3] + 2.7, 1.0 }, { bb[1] + 0.3, bb[3] + 3.2, 1.0 } }, 16)
            plate(P, cr, V(0, 1.75 * s, 0), V(1, 0, 0), V(0, 0, 1), 0.5, { smooth = true })
            for _, q in ipairs({ { bb[1] + 2.4, bb[3] + 1.9 }, { bb[1] - 1.7, bb[3] + 2.4 }, { bb[1] + 0.2, bb[3] + 2.8 } }) do
                capScrew(Cd, V(q[1], 2.0 * s, q[2]), V(0, s, 0), 0.15, 0.08)
            end
        end
        -- the drive's logo badge and the speed sensor cable
        plate(M:bucket("frame", "white", true), roundRect(1.6, 0.45, 0.15, 2), V(bb[1] - 0.6, 1.97, bb[3] - 0.9), V(1, 0, 0), V(0, 0, 1), 0.04)
    end
    -- the down tube: a fat rounded box, the battery's black underside
    local dt0 = add(headB, mul(u, 1.2))
    local dt1 = V(bb[1] + 2.8, 0, bb[3] + 2.4)
    local dtPts = bez3(add(dt0, mul(fwdP, -0.2)), lerp(dt0, dt1, 0.35), lerp(dt0, dt1, 0.7), dt1, 16)
    rrTube(P, dtPts, function(t) return 1.75 - 0.1 * t end, 1.35, 0.75, 28, V(0, 0, 1))
    do
        -- the battery: the black panel along the underside, with its lock and a charge port
        local F = pathFrames(dtPts, V(0, 0, 1))
        local fr = {}
        for i = 2, #dtPts - 1 do
            local f = F[i]
            -- f[2] is across the tube, in the frame's plane; down is the side facing -z
            local dn = f[2]
            if dn[3] > 0 then dn = mul(dn, -1) end
            fr[#fr + 1] = { add(dtPts[i], mul(dn, 1.52)), dn, Y }
        end
        ext(Bk, fr, rrLoop(0.55, 1.39, 0.4, 22))
        local mid = fr[floor(#fr * 0.25)]
        lathe(Cd, { { 0, 0, true }, { 0.3, 0, true }, { 0.28, 0.12 }, { 0, 0.14, true } }, add(add(mid[1], mul(mid[2], 0.28)), V(0, 0.75, 0)), mid[2], 14)
        lathe(M:bucket("frame", "rubber"), { { 0, 0, true }, { 0.36, 0, true }, { 0.34, 0.18 }, { 0, 0.2, true } }, add(dtPts[floor(#dtPts * 0.8)], V(0, 1.36, 0)), Y, 14)
    end
    -- top tube: sloping, from the head tube to the seat tube
    local tt0 = sub(headT, mul(u, 1.1))
    local tt1 = onST(stTop[3] - 1.4)
    local ttPts = bez3(add(tt0, mul(fwdP, -0.3)), lerp(tt0, tt1, 0.35), add(lerp(tt0, tt1, 0.7), V(0, 0, 0.2)), tt1, 14)
    rrTube(P, ttPts, function(t) return 0.85 - 0.18 * t end, 0.72, 0.5, 22, V(0, 0, 1))
    -- seat tube from the motor's top
    sweep(P, { onST(bb[3] + 2.8), stTop }, 0.78, 22, { capStart = false })
    lathe(Bk, { { 0.72, -0.5, true }, { 0.86, -0.45 }, { 0.86, 0.2 }, { 0.72, 0.25, true } }, stTop, stDir, 20)
    capScrew(Cd, add(sub(stTop, mul(stDir, 0.15)), V(-0.9, 0, 0)), V(-1, 0, 0), 0.13, 0.1)
    -- stays to the dropouts
    local function cstay(s)
        return bez3(V(bb[1] - 2.4, 1.55 * s, bb[3] + 0.6), V(bb[1] - 6, 2.0 * s, bb[3] + 0.2), V(rear[1] + 6, dropY * s, 0.6), V(rear[1] + 1.2, dropY * s, 0.25), 14)
    end
    local function sstay(s)
        return bez3(add(sub(stTop, mul(stDir, 1.0)), V(-0.4, 0.75 * s, 0)), add(sub(stTop, mul(stDir, 4.0)), V(-2.5, 1.8 * s, 0)),
                    V(rear[1] + 4, dropY * s, 3.5), V(rear[1] + 0.8, dropY * s, 1.0), 16)
    end
    for _, s in ipairs({ 1, -1 }) do
        rrTube(P, cstay(s), function(t) return 0.62 - 0.22 * t end, function(t) return 0.5 - 0.15 * t end, 0.3, 16, V(0, 0, 1))
        sweep(P, sstay(s), function(t) return 0.46 - 0.1 * t end, 16, { capStart = false })
        local loop = circleHull({ { rear[1], rear[3], 0.85 }, { rear[1] + 1.4, rear[3] + 0.3, 0.55 }, { rear[1] + 0.9, rear[3] + 1.2, 0.5 }, { rear[1] - 0.5, rear[3] + 0.9, 0.4 } }, 16)
        plate(P, loop, V(0, dropY * s, 0), V(1, 0, 0), V(0, 0, 1), 0.34, { smooth = true })
    end
    do
        local l, r = sstay(1), sstay(-1)
        sweep(P, { l[6], r[6] }, 0.3, 12, { capStart = false, capEnd = false })
    end
    axleParts(M, "frame", rear, dropY + 0.25, 0.28)
    -- hanger
    plate(Bk, circleHull({ { rear[1], rear[3], 0.55 }, { rear[1] - 0.2, rear[3] - 0.95, 0.42 } }, 12), V(0, -dropY - 0.24, 0), V(1, 0, 0), V(0, 0, 1), 0.14)

    -- REAR: fender, rack and its tail light
    local rackZ = R + 3.2
    do
        local FB = M:bucket("frame", "black")
        local g = fender(FB, rear, RD.outer + 0.7, math.rad(-18), math.rad(195), 1.6, 0.55, { segs = 44 })
        for _, s in ipairs({ 1, -1 }) do
            for _, a in ipairs({ math.rad(165) }) do
                sweep(Al, { g(a, 1.45 * s, 0.55), add(rear, V(-0.6, (dropY + 0.3) * s, -0.4)) }, 0.09, 6)
            end
        end
        local cl, cr = cstay(1), cstay(-1)
        sweep(FB, { g(math.rad(-16), 0, 0.3), lerp(cl[5], cr[5], 0.5) }, 0.15, 6)
        sweep(P, { cl[5], cr[5] }, 0.25, 10, { capStart = false, capEnd = false })
        -- the rack: tubes, a platform of rails, stays to the dropouts
        local RB = M:bucket("frame", "black")
        local xF, xB, hw = stTop[1] - 2.5, rear[1] - 8.6, 2.6
        local outline = { V(xF, hw, rackZ), V(xB + 1.4, hw, rackZ) }
        for i = 1, 7 do
            local a = pi / 2 + i / 8 * pi
            outline[#outline + 1] = V(xB + 1.4 + cos(a) * 1.4, sin(a) * hw, rackZ)
        end
        outline[#outline + 1] = V(xB + 1.4, -hw, rackZ)
        outline[#outline + 1] = V(xF, -hw, rackZ)
        sweep(RB, spline(outline, 3), 0.24, 12)
        for _, y in ipairs({ 0.9, -0.9 }) do sweep(RB, { V(xF + 0.3, y, rackZ), V(xB + 0.1, y, rackZ) }, 0.17, 8) end
        for _, x in ipairs({ xF + 0.5, lerp(V(xF, 0, 0), V(xB, 0, 0), 0.5)[1] }) do
            sweep(RB, { V(x, hw, rackZ - 0.05), V(x, -hw, rackZ - 0.05) }, 0.18, 8, { capStart = false, capEnd = false })
        end
        for _, s in ipairs({ 1, -1 }) do
            local foot = add(rear, V(-0.8, (dropY + 0.3) * s, 0.9))
            for _, x in ipairs({ xB + 1.0, lerp(V(xF, 0, 0), V(xB, 0, 0), 0.55)[1] }) do
                sweep(RB, { V(x, hw * s, rackZ - 0.1), foot }, 0.2, 10)
            end
            capScrew(Cd, foot, V(0, s, 0), 0.18, 0.12)
            local ss = sstay(s)
            sweep(RB, { V(xF, hw * s, rackZ), add(ss[5], V(0, 0.3 * s, 0)) }, 0.16, 8)
        end
        -- the tail light in the rack's end
        local tl = V(xB - 0.1, 0, rackZ - 0.55)
        local fr = {}
        for i = 0, 2 do fr[#fr + 1] = { add(tl, V(0.6 - i * 0.4, 0, 0)), V(0, 0, 1), V(0, 1, 0) } end
        ext(RB, fr, rrLoop(0.5, 2.0, 0.3, 20))
        plate(M:bucket("frame", "redlens"), roundRect(0.75, 3.6, 0.3, 3), add(tl, V(-0.2, 0, 0)), V(0, 0, 1), V(0, 1, 0), 0.25)
        -- reflector on the fender's tail
        local ra = math.rad(186)
        local rc = g(ra, 0, -0.05)
        plate(M:bucket("frame", "redlens"), roundRect(1.3, 0.9, 0.2, 3), add(rc, mul(V(cos(ra), 0, sin(ra)), 0.1)), Y, V(-sin(ra), 0, cos(ra)), 0.14)
    end
    -- kickstand mount behind the motor, left
    local standAt = V(bb[1] - 6.5, 2.1, bb[3] - 0.9)
    box(Bk, standAt, V(1.0, 0, 0), V(0, 0.3, 0), V(0, 0, 0.4))
    -- the saddle: a comfort saddle on a black post
    do
        sweep(Bk, { sub(stTop, mul(stDir, 2.5)), postTop }, 0.58, 18, { capStart = false })
        local hd = add(postTop, mul(stDir, 0.2))
        box(Bk, add(hd, V(0, 0, 0.25)), V(1.0, 0, 0), V(0, 0.55, 0), V(0, 0, 0.22))
        for _, s in ipairs({ 1, -1 }) do
            sweep(M:bucket("frame", "steel"), spline({ V(sit[1] - 2.8, 1.2 * s, sit[3] - 1.2), V(hd[1] - 1.5, 0.75 * s, hd[3] + 0.5),
                V(hd[1] + 1.5, 0.75 * s, hd[3] + 0.5), V(sit[1] + 5.0, 0.4 * s, sit[3] - 1.0) }, 4), 0.11, 8)
        end
        saddle(M:bucket("frame", "seat"), sit, { back = 3.6, front = 6.2, h = 1.6, kick = 0.15, drop = 0.4,
            w = function(t)
                if t < 0.08 then return 3.2 * sqrt(max(0.02, t / 0.08)) end
                if t < 0.35 then return 3.3 - 0.3 * (t - 0.08) / 0.27 end
                local w2 = 3.0 - 2.2 * min(1, (t - 0.35) / 0.55) ^ 0.75
                if t > 0.95 then w2 = w2 * sqrt(max(0.05, (1 - t) / 0.05)) end
                return w2
            end })
    end

    ------------------------------------------------------------------
    -- DRIVETRAIN: chain, derailleur (frame), 9-speed cassette (wheel)
    ------------------------------------------------------------------
    local ringT = 38
    local ringPR = pitchRadius(ringT)
    local chainY = -1.86
    local cogs = { 36, 32, 28, 24, 21, 18, 15, 13, 11 }
    cassette(M, "wheelR", cogs, -1.25, 0.152)
    local onCog = 5
    local up = V(rear[1] - 0.3, chainY, rear[3] - pitchRadius(cogs[onCog]) - pitchRadius(11) - 0.35)
    local lo = V(up[1] + 0.7, chainY, up[3] - 3.0)
    derailleur(M, "frame", V(rear[1] - 0.2, -dropY - 0.3, rear[3] - 0.95), up, lo, chainY)
    do
        local path = chainPath({ { bb[1], bb[3], ringPR, 1 }, { rear[1], rear[3], pitchRadius(cogs[onCog]), 1 },
                                 { up[1], up[3], pitchRadius(11), -1 }, { lo[1], lo[3], pitchRadius(11), 1 } })
        chainLinks(M:bucket("frame", "steel", true), path, chainY)
    end
    -- rear brake: caliper on the left between the stays
    local rotR, rotF = 3.2, 3.55
    do
        local cc = caliper(M, "frame", rear, rotR, hubR - 0.12, math.rad(145), false)
        sweep(M:bucket("frame", "black", true), spline({ add(cc, V(0.3, 0.7, 0.5)), V(rear[1] + 6, 2.2, 3.3), V(bb[1] - 3, 2.0, bb[3] + 3.2) }, 6), 0.1, 6)
    end

    ------------------------------------------------------------------
    -- FORK: a suspension fork (drawn rigid), fender, headlamp
    ------------------------------------------------------------------
    do
        local FB = M:bucket("fork", "black")
        local FA = M:bucket("fork", "alloy")
        local FCd = M:bucket("fork", "chrome", true)
        sweep(FB, { crSt, stemBase }, 0.6, 18, { capStart = false, capEnd = false })
        -- crown
        local fr = {}
        for i = 0, 3 do fr[#fr + 1] = { add(crSt, mul(u, (i / 3 - 0.5) * 1.2)), fwdP, Y } end
        local loop = circleHull({ { 0, 0, 1.05 }, { off, legY, 1.05 }, { off, -legY, 1.05 } }, 18)
        ext(FB, fr, function(i)
            if i == 1 or i == 4 then
                local out = {}
                for j, q in ipairs(loop) do out[j] = { q[1] * 0.96, q[2] * 0.97 } end
                return out
            end
            return loop
        end)
        local sealD = R + 1.3
        for _, s in ipairs({ 1, -1 }) do
            local o = add(front, V(0, legY * s, 0))
            sweep(FA, { add(o, mul(u, sealD - 1.2)), add(add(crLeg, mul(u, 0.6)), V(0, legY * s, 0)) }, 0.6, 20, { capStart = false })
            lathe(FB, { { 0, 0, true }, { 0.58, 0, true }, { 0.5, 0.15 }, { 0, 0.18, true } }, add(add(crLeg, mul(u, 0.6)), V(0, legY * s, 0)), u, 14)
            lathe(FB, { { 0, -0.8, true }, { 0.65, -0.8, true }, { 0.85, -0.5 }, { 0.88, 0.3 }, { 0.84, sealD - 1.4 },
                        { 0.88, sealD - 0.7 }, { 0.88, sealD - 0.2, true }, { 0.7, sealD - 0.15, true }, { 0, sealD - 0.15, true } }, o, u, 22)
            lathe(M:bucket("fork", "rubber"), { { 0.62, 0, true }, { 0.84, 0, true }, { 0.78, 0.25 }, { 0.64, 0.32, true } }, add(o, mul(u, sealD - 0.18)), u, 18)
            lathe(FB, { { 0, -0.45, true }, { 0.72, -0.45, true }, { 0.75, 0 }, { 0.72, 0.45, true }, { 0, 0.45, true } }, V(front[1], (legY - 0.05) * s, front[3]), Y, 18)
        end
        -- arch, behind (the fender passes under)
        local arch = {}
        for i = 0, 12 do
            local t = i / 12
            local y = (t * 2 - 1) * legY
            local e = 1 - (y / legY) ^ 2
            arch[#arch + 1] = add(add(front, mul(u, sealD - 1.8 + 0.9 * e)), add(mul(fwdP, 0.4 + 0.6 * e), V(0, y, 0)))
        end
        rrTube(FB, arch, function(t) return 0.5 + 0.08 * sin(t * pi) end, 0.36, 0.25, 14, u)
        axleParts(M, "fork", front, legY + 0.5, 0.3)
        -- front caliper on the left leg
        local a = atan2(u[3] * 0.85 - fwdP[3] * 0.55, u[1] * 0.85 - fwdP[1] * 0.55)
        local cc = caliper(M, "fork", front, rotF, hubF - 0.12, a, false)
        -- fender, under the crown, with stays
        local g = fender(FB, front, RD.outer + 0.7, math.rad(-20), math.rad(150), 1.6, 0.55, { segs = 36 })
        for _, s in ipairs({ 1, -1 }) do
            sweep(Al, { g(math.rad(20), 1.45 * s, 0.55), add(front, V(0.2, (legY + 0.55) * s, 0.2)) }, 0.09, 6)
        end
        local topA = atan2(crSt[3] - front[3], crSt[1] - front[1])
        local gt = g(topA, 0, 0)
        box(FB, lerp(gt, crSt, 0.5), mul(norm(sub(crSt, gt)), len(sub(crSt, gt)) * 0.5 - 0.2), V(0, 0.5, 0), mul(fwdP, 0.1))
        -- headlamp on the crown's front
        local lp = add(add(crLeg, mul(fwdP, 1.4)), mul(u, 0.2))
        local hb = M:bucket("fork", "black")
        local fr2 = {}
        for i = 0, 3 do fr2[#fr2 + 1] = { add(lp, V(-1.0 + i * 0.6, 0, 0)), V(0, 0, 1), V(0, 1, 0) } end
        ext(hb, fr2, function(i) local sc = (i == 1) and 0.7 or 1 return rrLoop(0.85 * sc, 1.25 * sc, 0.5, 24) end)
        plate(M:bucket("fork", "lens"), roundRect(1.4, 2.2, 0.45, 4), add(lp, V(0.85, 0, 0)), V(0, 0, 1), V(0, 1, 0), 0.12)
        box(hb, lerp(lp, crLeg, 0.6), mul(fwdP, 0.6), V(0, 0.35, 0), mul(u, 0.18))
        sweep(M:bucket("fork", "black", true), spline({ add(cc, V(0, 0.7, 0.3)), add(add(front, mul(u, 7)), add(mul(fwdP, -1.1), V(0, legY - 0.2, 0))),
            add(add(front, mul(u, sealD + 1.5)), add(mul(fwdP, -1.2), V(0, 1.3, 0))) }, 6), 0.1, 6)
    end

    ------------------------------------------------------------------
    -- BARS: a riser stem, a swept trekking bar, ergo grips, levers, the
    -- display and its remote
    ------------------------------------------------------------------
    local gripR, gripL, bellAt
    local clamp = add(stemBase, V(3.15, 0, 2.25))
    do
        local BB = M:bucket("bars", "black")
        local BCd = M:bucket("bars", "chrome", true)
        lathe(BB, { { 0, 0, true }, { 0.82, 0, true }, { 0.86, 0.1 }, { 0.86, 1.5 }, { 0.82, 1.6, true }, { 0, 1.6, true } }, sub(stemBase, mul(u, 0.6)), u, 20)
        rrTube(BB, { add(stemBase, mul(u, 0.25)), sub(clamp, mul(norm(sub(clamp, stemBase)), 0.6)) }, 0.62, 0.72, 0.4, 18, Y)
        lathe(BB, { { 0, -1.15, true }, { 0.72, -1.15, true }, { 0.76, -1.0 }, { 0.76, 1.0 }, { 0.72, 1.15, true }, { 0, 1.15, true } }, clamp, Y, 20)
        capScrew(BCd, add(stemBase, mul(u, 1.0)), u, 0.2, 0.1)
        local rise = 1.6
        local gz = clamp[3] + rise
        local function side(s)
            return { clamp, add(clamp, V(0, 1.5 * s, 0)), add(clamp, V(-0.1, 3.4 * s, 0.3)), add(clamp, V(-0.5, 5.6 * s, rise - 0.3)),
                     V(clamp[1] - 1.0, 8.0 * s, gz), V(clamp[1] - 1.6, 12.4 * s, gz + 0.1), V(clamp[1] - 2.6, 16.4 * s, gz + 0.15) }
        end
        local L, Rr = side(1), side(-1)
        local all = {}
        for i = #Rr, 2, -1 do all[#all + 1] = Rr[i] end
        for i = 1, #L do all[#all + 1] = L[i] end
        sweep(BB, spline(all, 6), function(t)
            local e = abs(t * 2 - 1)
            return 0.44 + 0.18 * max(0, 1 - e / 0.25)
        end, 16)
        for _, s in ipairs({ 1, -1 }) do
            local sd = side(s)
            local d = norm(sub(sd[7], sd[6]))
            local g0 = add(sd[6], mul(d, -0.15))
            local g1 = add(sd[7], mul(d, 0.05))
            -- ergonomic grip: a palm wing on the outer half
            local Rb = M:bucket("bars", "rubber")
            local gl = len(sub(g1, g0))
            local prof = { { 0.44, 0, true }, { 0.72, 0, true }, { 0.74, 0.3 } }
            for i = 1, 8 do
                local t = i / 9
                prof[#prof + 1] = { 0.74 + 0.05 * ((i % 2 == 0) and 1 or 0), t * (gl - 0.4) }
            end
            prof[#prof + 1] = { 0.78, gl - 0.25 }
            prof[#prof + 1] = { 0.7, gl, true }
            prof[#prof + 1] = { 0, gl + 0.02, true }
            lathe(Rb, prof, g0, d, 20)
            local wing = {}
            local back = norm(cross(d, V(0, 0, 1)))
            if back[1] > 0 then back = mul(back, -1) end
            for i = 0, 8 do
                local t = 0.35 + i / 8 * 0.6
                local c = add(g0, mul(d, t * gl))
                wing[#wing + 1] = add(add(c, mul(back, 0.5 + 0.7 * sin((t - 0.35) / 0.6 * pi * 0.8))), V(0, 0, 0.1))
            end
            sweep(Rb, wing, function(t) return 0.32 + 0.15 * sin(t * pi), 0.22 end, 10, { up = V(0, 0, 1) })
            if s < 0 then gripR = { A = add(g0, mul(d, 0.3)), B = sub(g1, mul(d, 0.2)) }
            else gripL = { A = add(g0, mul(d, 0.3)), B = sub(g1, mul(d, 0.2)) } end
            local la = sub(g0, mul(d, 0.5))
            brakeLever(M, "bars", la, d, V(1, 0, 0), 2.6)
            if s < 0 then
                local sp2 = sub(la, mul(d, 0.9))
                lathe(BB, { { 0.44, -0.22, true }, { 0.58, -0.22, true }, { 0.58, 0.22, true }, { 0.44, 0.22, true } }, sp2, d, 14)
                box(BB, add(sp2, V(0.15, 0, -0.7)), V(0.6, 0, 0.1), V(0, 0.3, 0), V(-0.1, 0, 0.4))
            else
                -- the assist remote: a pod with up/down buttons, inboard of the lever
                local rp = sub(la, mul(d, 1.1))
                lathe(BB, { { 0.44, -0.3, true }, { 0.6, -0.3, true }, { 0.6, 0.3, true }, { 0.44, 0.3, true } }, rp, d, 14)
                box(BB, add(rp, V(-0.55, 0, 0.25)), V(0.55, 0, 0.0), V(0, 0.45, 0), V(0, 0, 0.3))
                box(M:bucket("bars", "plastic"), add(rp, V(-0.85, 0.12, 0.6)), V(0.18, 0, 0), V(0, 0.18, 0), V(0, 0, 0.06))
                box(M:bucket("bars", "plastic"), add(rp, V(-0.85, -0.25, 0.6)), V(0.18, 0, 0), V(0, 0.18, 0), V(0, 0, 0.06))
                bellAt = sub(rp, mul(d, 1.0))
            end
            local mc = add(la, V(1.0, 0, 0.15))
            sweep(M:bucket("bars", "black", true), spline({ add(mc, V(0.4, 0, -0.2)), add(mc, V(2.0, -1.2 * s, -2.5)),
                add(clamp, V(1.0, 1.4 * s, -4.0)), add(crLeg, V(0.0, 1.3 * s, 1.5)) }, 6), 0.1, 6)
        end
        -- the display: centred on the bar, tilted to the rider
        local dp = add(clamp, V(-0.2, 0, 1.15))
        local tilt = norm(V(-0.5, 0, 0.87))
        local dfw = norm(cross(Y, tilt))
        local fr = {}
        for i = 0, 2 do fr[#fr + 1] = { add(dp, mul(tilt, -0.3 + i * 0.3)), dfw, Y } end
        ext(BB, fr, function(i) local sc = (i == 1) and 0.85 or 1 return rrLoop(1.3 * sc, 1.05 * sc, 0.3, 20) end)
        plate(M:bucket("bars", "lens"), roundRect(2.0, 1.6, 0.18, 3), add(dp, mul(tilt, 0.33)), dfw, Y, 0.04)
        box(BB, add(clamp, V(-0.1, 0, 0.6)), V(0.35, 0, 0), V(0, 0.55, 0), V(0, 0, 0.35))
    end
    local bellPivot, bellAxis = G.parts.bell(M, "bars", "bellLever", bellAt, V(0, 1, 0), V(0, 0, 1), V(-1, 0, 0))

    ------------------------------------------------------------------
    -- WHEELS: 2.25" trekking tyres, black rims, 32 spokes, rotors
    ------------------------------------------------------------------
    G.parts.wheel(M, "wheelF", RD, { tread = "road", wall = "rubber", rim = "black", spokes = 32, cross = 3, spokeR = 0.05,
        hubHalf = hubF, hubRole = "black", disc = rotF })
    G.parts.wheel(M, "wheelR", RD, { rear = true, cog = false, tread = "road", wall = "rubber", rim = "black", spokes = 32,
        cross = 3, spokeR = 0.05, hubHalf = hubR, hubRole = "black", disc = rotR })
    trekTread(M, "wheelF", RD, 64)
    trekTread(M, "wheelR", RD, 64)

    ------------------------------------------------------------------
    -- CRANKS (on the motor's spindle), the ring's guard, pedals
    ------------------------------------------------------------------
    local crankL, pedalY = 6.8, 5.2
    cranks(M, bb, { root = 2.35, tip = 2.75, len = crankL, pedalIn = pedalY - 1.95, chainY = chainY, teeth = ringT, role = "black", ringRole = "black" })
    do
        -- a clip-on guard ring outside the chainring
        local gr = ringPR + 0.45
        local loop = circle(gr, 48)
        local inner = circle(gr - 0.35, 48)
        for i = 1, #loop do loop[i] = { loop[i][1] + bb[1], loop[i][2] + bb[3] } inner[i] = { inner[i][1] + bb[1], inner[i][2] + bb[3] } end
        ringPlate(M:bucket("cranks", "plastic"), loop, inner, V(0, chainY - 0.32, 0), V(1, 0, 0), V(0, 0, 1), 0.14)
    end
    do
        flatPedal(M, "pedal", "black", 3.9, 3.6, 0.6, false)
        for _, s in ipairs({ 1, -1 }) do
            plate(M:bucket("pedal", "amber", true), roundRect(0.35, 2.0, 0.1, 2), V(s * 1.78, 0, 0), V(0, 0, 1), V(0, 1, 0), 0.1)
        end
    end

    M.layout = {
        k = k, steer = u,
        headT = headT, headB = headB, stemTop = stemTop,
        rear = rear, front = front, bb = bb,
        crank = crankL, pedalY = pedalY,
        gripR = gripR, gripL = gripL,
        bellPivot = bellPivot, bellAxis = bellAxis,
        stand = standAt,
    }
    return M
end)
