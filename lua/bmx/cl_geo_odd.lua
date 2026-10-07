--[[--------------------------------------------------------------------------
    bmx/cl_geo_odd.lua

    The models of the unicycle, the penny-farthing and the tandem, built in code (docs/MODELS.md).
    Kinds: unicycle, penny, tandem.

    All three are built in REAL inches (Source units at the vehicle's own registry
    size): the unicycle's wheel is a 20", the penny's a 52", the tandem's 700c. None
    of them is scaled from the BMX: their sizes are their registrations'.

    UNICYCLE   a 20" trials/freestyle unicycle. Groups: frame (fork, bearing
               housings, seat post, saddle with its handle and bumper), wheel (about
               its own axle), cranks (about the hub: they turn WITH the wheel), pedal.
               Its drawer (cl_oddbikes.lua) places them.
    PENNY      a 52" ordinary. Groups: frame (backbone, neck, spring, saddle, step,
               rear fork), fork (front fork, head, moustache bars with wooden grips,
               spoon brake: all steer), wheelF and wheelR (about their own axles),
               cranks (in place about the front hub, layout.bb), pedal. Its drawer
               places them.
    TANDEM     a road/touring tandem, bike-shaped: DrawDetailed (cl_init.lua) draws it
               from frame/fork/bars/wheelF/wheelR/cranks/pedal and the layout's bb, bb2
               and gripS, with no drawer of its own.
----------------------------------------------------------------------------]]

BMX = BMX or {}
local G = BMX.BikeGeo
if not G then return end

local sqrt, sin, cos, pi, abs = math.sqrt, math.sin, math.cos, math.pi, math.abs
local max, min, floor = math.max, math.min, math.floor
local TAU = pi * 2

local Pm = G.prim
local sweep, lathe, plate, ringPlate, box = Pm.sweep, Pm.lathe, Pm.plate, Pm.ringPlate, Pm.box
local roundRect, circle, bez3, spline = Pm.roundRect, Pm.circle, Pm.bez3, Pm.spline
local grid, cap, bead, quad, tri = Pm.grid, Pm.cap, Pm.bead, Pm.quad, Pm.tri
local Vv = G.vec
local V, add, sub, mul, dot, cross = Vv.V, Vv.add, Vv.sub, Vv.mul, Vv.dot, Vv.cross
local len, norm, lerp, rot, madd, perp = Vv.len, Vv.norm, Vv.lerp, Vv.rot, Vv.madd, Vv.perp

local Y = V(0, 1, 0)
local Z = V(0, 0, 1)
local X = V(1, 0, 0)

--------------------------------------------------------------------------
-- SHARED HELPERS
--------------------------------------------------------------------------

-- Drop the sidewall-lettering band the shared wheel adds (its texture reads
-- "STREET SKINWALL 20 x 2.30", which is the BMX's tyre, not these).
local function dropRole(M, group, role)
    local g = M.groups[group]
    if not g then return end
    for i = #g, 1, -1 do if g[i].mat == role then table.remove(g, i) end end
end

-- A closed loft through rings of points (each ring a closed loop, the same
-- count), capped at both ends: saddles, bumpers, the crank arms.
local function loft(B, rings, capEnds)
    grid(B, rings, true, function(i)
        local s = { 0, 0, 0 }
        for _, p in ipairs(rings[i]) do s = add(s, p) end
        return mul(s, 1 / #rings[i])
    end)
    if capEnds ~= false then
        local n = #rings
        local function centre(r)
            local s = { 0, 0, 0 }
            for _, p in ipairs(r) do s = add(s, p) end
            return mul(s, 1 / #r)
        end
        cap(B, rings[1], norm(sub(centre(rings[1]), centre(rings[2]))))
        cap(B, rings[n], norm(sub(centre(rings[n]), centre(rings[n - 1]))))
    end
end

-- A superellipse section about `c` in the plane of `eu`, `ev`: half sizes
-- `a` (along eu) and `b` (along ev, `bDown` below), exponent `e` (2 = ellipse,
-- larger = boxier), `n` points.
local function section(c, eu, ev, a, b, bDown, e, n, phase)
    local out = {}
    for j = 0, n - 1 do
        local t = (j / n) * TAU + (phase or 0)
        local ca, sa = cos(t), sin(t)
        local cu = (abs(ca) ^ (2 / e)) * (ca < 0 and -1 or 1)
        local cv = (abs(sa) ^ (2 / e)) * (sa < 0 and -1 or 1)
        local vv = cv >= 0 and cv * b or cv * (bDown or b)
        out[#out + 1] = add(c, add(mul(eu, cu * a), mul(ev, vv)))
    end
    return out
end

-- A hex bolt head (or nut) at `p`, its axis `ax` pointing out of the part.
local function bolt(B, p, ax, r, h)
    lathe(B, { { 0, 0, true }, { r, 0, true }, { r, h * 0.8 }, { r * 0.8, h, true }, { 0, h, true } }, p, ax, 6, { flat = true })
end

-- A socket-head cap screw: round head with a hex socket's dark centre.
local function capScrew(B, p, ax, r, h)
    lathe(B, { { 0, h - 0.04, true }, { r * 0.5, h - 0.04, true }, { r * 0.55, h, true }, { r * 0.92, h, true },
               { r, h * 0.8 }, { r, 0, true }, { 0, 0, true } }, p, ax, 12)
end

-- A crank arm: lofted rounded section from `root` to `tip` (both points on
-- the arm's centre line), `wRoot`/`wTip` its width in the plane of rotation,
-- `t` its thickness along y; bosses round the spindle and the pedal eye.
local function crankArm(B, root, tip, wRoot, wTip, tRoot, tTip, bossR, eyeR)
    local P = {}
    local st = 12
    local along = norm(sub(tip, root))
    local inPlane = norm(cross(Y, along))          -- the arm's width direction
    for i = 0, st do
        local t = i / st
        local c = lerp(root, tip, t)
        local w = wRoot + (wTip - wRoot) * t
        local th = tRoot + (tTip - tRoot) * t
        P[#P + 1] = section(c, Y, inPlane, th * 0.5, w * 0.5, nil, 3.2, 16)
    end
    loft(B, P, false)
    local function bossAt(c, r, th)
        lathe(B, { { 0, -th * 0.5, true }, { r - 0.04, -th * 0.5, true }, { r, -th * 0.5 + 0.06 }, { r, th * 0.5 - 0.06 },
                   { r - 0.04, th * 0.5, true }, { 0, th * 0.5, true } }, c, Y, 22)
    end
    bossAt(root, bossR, tRoot)
    bossAt(tip, eyeR, tTip)
end

-- Sprocket teeth as a ring plate in the x/z plane at `y`, about (cx, cz).
local function sprocket(B, n, cx, y, cz, t, innerR, ppt)
    local pr = G.parts.pitchRadius(n)
    local outer = G.parts.toothLoop(n, pr, ppt or 6)
    local inner = {}
    for i = 1, #outer do
        local a = (i - 1) / #outer * TAU
        inner[i] = { cx + cos(a) * innerR, cz + sin(a) * innerR }
        outer[i] = { outer[i][1] + cx, outer[i][2] + cz }
    end
    ringPlate(B, outer, inner, V(0, y, 0), X, Z, t)
    return pr
end

-- A chain round circles in the x/z plane at `y`: { {x, z, r, s}, ... } in the
-- order the chain meets them, s = 1 wrapping anticlockwise (seen with x right
-- and z up), -1 clockwise (a derailleur's upper jockey). Links of `pitch`.
local function chainLoop(M, group, circles, y, pitch)
    local n = #circles
    local tin, tout = {}, {}
    for i = 1, n do
        local A, B2 = circles[i], circles[i % n + 1]
        local Dx, Dz = B2[1] - A[1], B2[2] - A[2]
        local rA, rB = A[4] * A[3], B2[4] * B2[3]
        local D2 = Dx * Dx + Dz * Dz
        local dl = rB - rA
        local t = sqrt(max(D2 - dl * dl, 1e-9))
        local a = (t * Dx + dl * Dz) / D2
        local b = (-dl * Dx + t * Dz) / D2
        local Lx, Lz = -b, a
        tout[i] = { A[1] - rA * Lx, A[2] - rA * Lz }
        tin[i % n + 1] = { B2[1] - rB * Lx, B2[2] - rB * Lz }
    end
    local path = {}
    for i = 1, n do
        local C = circles[i]
        local a0 = math.atan2(tin[i][2] - C[2], tin[i][1] - C[1])
        local a1 = math.atan2(tout[i][2] - C[2], tout[i][1] - C[1])
        local sweepA
        if C[4] > 0 then sweepA = (a1 - a0) % TAU else sweepA = -((a0 - a1) % TAU) end
        local steps = max(2, floor(abs(sweepA) * C[3] / 0.15))
        for s = 0, steps do
            local a = a0 + sweepA * s / steps
            path[#path + 1] = { C[1] + cos(a) * C[3], C[2] + sin(a) * C[3] }
        end
    end
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
    local St = M:bucket(group, "steel", true)
    local hw = pitch * 0.3
    for i = 0, nl - 1 do
        local a, b = pins[i], pins[(i + 1) % nl]
        local du, dv = b[1] - a[1], b[2] - a[2]
        local l = sqrt(du * du + dv * dv)
        local eu = V(du / l, 0, dv / l)
        local ev = V(-dv / l, 0, du / l)
        local off = (i % 2 == 0) and pitch * 0.4 or pitch * 0.26
        local loop = {
            { -hw * 0.75, -hw * 0.6 }, { l * 0.5, -hw * 0.7 }, { l + hw * 0.75, -hw * 0.6 }, { l + hw, 0 },
            { l + hw * 0.75, hw * 0.6 }, { l * 0.5, hw * 0.7 }, { -hw * 0.75, hw * 0.6 }, { -hw, 0 },
        }
        for _, s in ipairs({ 1, -1 }) do
            plate(St, loop, V(a[1], y + off * s, a[2]), eu, ev, pitch * 0.1)
        end
        sweep(St, { V(a[1], y - off, a[2]), V(a[1], y + off, a[2]) }, pitch * 0.2, 5, { capStart = false, capEnd = false })
    end
    return nl
end

-- Drop buckets nothing was put in (a mesh of nothing is not a mesh).
local function tidy(M)
    for _, g in ipairs(M.order) do
        local list = M.groups[g]
        for i = #list, 1, -1 do if #list[i].v == 0 then table.remove(list, i) end end
    end
    return M
end

-- Copy every bucket of group `from` of model `S` into group `to` of `M`,
-- each vertex passed through `f` (positions) and `fn` (normals).
local function merge(M, to, S, from, f, fn)
    for _, b in ipairs(S.groups[from] or {}) do
        local dst = M:bucket(to, b.mat, b.detail)
        for _, vt in ipairs(b.v) do
            dst.v[#dst.v + 1] = { p = f(vt.p), n = fn and fn(vt.n) or vt.n, u = vt.u, v = vt.v }
        end
        dst.tris = dst.tris + b.tris
    end
end

-- A lofted saddle top: stations from tail (t = 0) to nose (t = 1) given by
-- shape(t) -> x, half width, top height, bottom drop, z of the base. Returns
-- the rings (for piping round its edge).
local function saddleShell(B, c, stations, ring, shape, e)
    local P = {}
    for i = 0, stations do
        local t = i / stations
        local x, w, h, d, z0 = shape(t)
        P[#P + 1] = section(add(c, V(x, 0, z0)), Y, Z, max(w, 0.04), max(h, 0.02), max(d, 0.02), e or 2.6, ring, -pi / 2)
    end
    loft(B, P, true)
    return P
end

--------------------------------------------------------------------------
-- THE UNICYCLE: a 20" trials/freestyle unicycle at the registry's size
-- (wheel radius 10 about the origin, the rider's seat at {0, 0, 19}).
--------------------------------------------------------------------------
local function buildUnicycle(opt)
    local M = Pm.newModel()
    local radius = opt.radius or 10
    local s = radius / 10                     -- everything is a 20" unicycle's, at this wheel
    local seat = opt.seat or { 0, 0, 19 }
    local saddleTop = add(seat, V(-0.5, 0, 2.0))

    -- THE WHEEL: 20 x 2.3 on a 36-hole rim, a wide-flange hub.
    local R = G.WheelDims(radius, { width = 2.3 * s, flangeR = 1.25 * s })
    G.parts.wheel(M, "wheel", R, { tread = "knobby", wall = "rubber", rim = "black", spokes = 36, cross = 3,
                                    hubHalf = 1.65 * s })
    dropRole(M, "wheel", "tyretext")

    local BY = 1.97 * s                        -- bearing centres: a 100 mm hub
    -- THE CRANKS, fixed to the axle: a splined axle through the bearings and two
    -- 127 mm arms, the right (-y) one forward at angle 0.
    local CR = 5.0 * s
    local armY = 2.62 * s
    local pedalY = armY + 0.38 * s + 2.0
    do
        local Al = M:bucket("cranks", "alloy")
        local St = M:bucket("cranks", "steel")
        local Cd = M:bucket("cranks", "chrome", true)
        -- the axle: plain between the bearings, splined (ISIS) where the arms go on
        lathe(St, { { 0, -2.9 * s, true }, { 0.38 * s, -2.9 * s, true }, { 0.38 * s, 2.9 * s, true }, { 0, 2.9 * s, true } },
              V(0, 0, 0), Y, 16)
        for _, sd in ipairs({ -1, 1 }) do
            local dir = (sd == -1) and X or mul(X, -1)
            local root = V(0, armY * sd, 0)
            local tip = add(V(0, (armY + 0.12 * s) * sd, 0), mul(dir, CR))
            crankArm(Al, root, tip, 1.15 * s, 0.78 * s, 0.62 * s, 0.5 * s, 0.86 * s, 0.56 * s)
            -- the crank bolt in its counterbore, and the pedal thread's boss
            capScrew(Cd, add(root, V(0, 0.31 * s * sd, 0)), mul(Y, sd), 0.42 * s, 0.08 * s)
            lathe(St, { { 0, 0, true }, { 0.3 * s, 0, true }, { 0.3 * s, 0.14 * s }, { 0, 0.15 * s, true } },
                  add(tip, V(0, 0.25 * s * sd, 0)), mul(Y, sd), 12)
        end
    end
    G.parts.pedal(M, "pedal")

    -- THE FORK: bearing housings with bolted caps, two legs, a flat crown and
    -- the seat tube.
    local P = M:bucket("frame", "paint")
    local Pd = M:bucket("frame", "paint", true)
    local Bk = M:bucket("frame", "black")
    local St = M:bucket("frame", "steel")
    local Cd = M:bucket("frame", "chrome", true)
    local crownZ0, crownZ1 = radius + 1.3 * s, radius + 2.5 * s
    local hr, hi = 1.12 * s, 0.86 * s          -- housing outer / bore
    local ht = 0.62 * s                        -- housing thickness along y
    for _, sd in ipairs({ 1, -1 }) do
        local y = BY * sd
        -- the bearing itself: a steel outer race and a black seal
        lathe(St, { { 0.4 * s, -0.3 * s, true }, { hi, -0.3 * s, true }, { hi, 0.3 * s, true }, { 0.4 * s, 0.3 * s, true } },
              V(0, y, 0), Y, 24)
        -- upper half of the housing: a half ring with ears, welded to the leg
        local up = {}
        up[#up + 1] = { hr + 0.42 * s, 0.03 * s }
        up[#up + 1] = { hr + 0.42 * s, 0.48 * s }
        up[#up + 1] = { hr * 0.8, 0.75 * s }
        for i = 1, 7 do
            local a = 0.42 + (pi - 0.84) * i / 8
            up[#up + 1] = { cos(a) * hr * 1.02, sin(a) * hr * 1.02 }
        end
        up[#up + 1] = { -hr * 0.8, 0.75 * s }
        up[#up + 1] = { -hr - 0.42 * s, 0.48 * s }
        up[#up + 1] = { -hr - 0.42 * s, 0.03 * s }
        for i = 0, 10 do
            local a = pi - i / 10 * pi
            up[#up + 1] = { cos(a) * hi, max(sin(a) * hi, 0.03 * s) }
        end
        plate(P, up, V(0, y, 0), X, Z, ht, { smooth = false })
        -- the cap: the lower half, its ears drilled for two bolts from below
        local lo = {}
        lo[#lo + 1] = { -hr - 0.42 * s, -0.03 * s }
        lo[#lo + 1] = { -hr - 0.42 * s, -0.42 * s }
        for i = 1, 9 do
            local a = pi + 0.25 + (pi - 0.5) * i / 10
            lo[#lo + 1] = { cos(a) * hr, sin(a) * hr }
        end
        lo[#lo + 1] = { hr + 0.42 * s, -0.42 * s }
        lo[#lo + 1] = { hr + 0.42 * s, -0.03 * s }
        for i = 0, 10 do
            local a = i / 10 * pi
            lo[#lo + 1] = { cos(a) * hi, -max(sin(a) * hi, 0.03 * s) }
        end
        plate(Bk, lo, V(0, y, 0), X, Z, ht * 0.96, { smooth = false })
        for _, bx in ipairs({ -1, 1 }) do
            local bp = V(bx * (hr + 0.2 * s), y, -0.42 * s)
            bolt(Cd, bp, V(0, 0, -1), 0.2 * s, 0.2 * s)
            sweep(Cd, { add(bp, V(0, 0, 0.0)), add(bp, V(0, 0, 0.95 * s)) }, 0.1 * s, 8)
        end
        -- the leg: an oval tube, a little wider fore-and-aft, from the housing to
        -- the crown, tapering down
        local l0 = V(0, y, 0.6 * s)
        local l1 = V(0, y, crownZ0 + 0.35 * s)
        local pts = {}
        for i = 0, 12 do pts[#pts + 1] = lerp(l0, l1, i / 12) end
        sweep(P, pts, function(t) return 0.42 * s + 0.08 * s * t, 0.33 * s + 0.04 * s * t end, 18,
              { up = X, capStart = false, capEnd = false })
        bead(Pd, V(0, y, 0.98 * s), Z, 0.4 * s, 0.06 * s, 18)
    end
    -- the crown: a flat-topped bridge across the tyre, rounded at its ends
    do
        local w, h = 2 * BY + 1.1 * s, crownZ1 - crownZ0
        local outline = roundRect(w, h, 0.42 * s, 4, 0, (crownZ0 + crownZ1) * 0.5)
        -- an arch underneath, over the tyre
        local o2 = {}
        for _, q in ipairs(outline) do
            local yy = q[1]
            local zz = q[2]
            if zz < (crownZ0 + crownZ1) * 0.5 and abs(yy) < BY - 0.3 * s then
                zz = zz + 0.35 * s * (1 - (yy / (BY - 0.3 * s)) ^ 2)
            end
            o2[#o2 + 1] = { yy, zz }
        end
        plate(P, o2, V(0, 0, 0), Y, Z, 1.9 * s, { smooth = true })
        -- the two bolts that hold the seat tube's insert, on top
        for _, sy in ipairs({ -1, 1 }) do
            capScrew(Cd, V(0, sy * (BY - 0.2 * s), crownZ1), Z, 0.2 * s, 0.1 * s)
        end
    end
    -- the seat tube: 28.6 mm, slotted at the back, a double-bolt clamp
    local stTop = crownZ1 + 3.0 * s
    lathe(P, { { 0.52 * s, crownZ1 - 0.05, true }, { 0.72 * s, crownZ1, true }, { 0.6 * s, crownZ1 + 0.35 * s },
               { 0.565 * s, crownZ1 + 0.6 * s }, { 0.565 * s, stTop - 0.05 * s }, { 0.5 * s, stTop, true } },
          V(0, 0, 0), Z, 24)
    box(Bk, V(-0.55 * s, 0, stTop - 0.55 * s), V(0.03 * s, 0, 0), V(0, 0.08 * s, 0), V(0, 0, 0.55 * s))
    local clampZ = stTop - 0.35 * s
    lathe(Bk, { { 0.54 * s, -0.42 * s, true }, { 0.66 * s, -0.42 * s, true }, { 0.7 * s, -0.3 * s }, { 0.7 * s, 0.3 * s },
                { 0.66 * s, 0.42 * s, true }, { 0.54 * s, 0.42 * s, true } }, V(0, 0, clampZ), Z, 24)
    for _, dz in ipairs({ -0.17 * s, 0.17 * s }) do
        -- the clamp's ears behind the tube, and a bolt through them
        box(Bk, V(-0.78 * s, 0, clampZ + dz), V(0.16 * s, 0, 0), V(0, 0.28 * s, 0), V(0, 0, 0.12 * s))
        bolt(Cd, V(-0.82 * s, 0.28 * s, clampZ + dz), Y, 0.14 * s, 0.12 * s)
        lathe(Cd, { { 0, 0, true }, { 0.12 * s, 0, true }, { 0.12 * s, 0.1 * s }, { 0, 0.11 * s, true } },
              V(-0.82 * s, -0.28 * s, clampZ + dz), mul(Y, -1), 6, { flat = true })
    end
    -- the seat post, 25.4 mm, up to the saddle's base
    local baseZ = saddleTop[3] - 2.25 * s
    local C = M:bucket("frame", "chrome")
    sweep(C, { V(0, 0, crownZ1 + 0.4 * s), V(0, 0, baseZ - 0.3 * s) }, 0.5 * s, 20, { capStart = false })
    -- a black post clamp plate under the saddle (the post's top)
    lathe(Bk, { { 0, -0.3 * s, true }, { 0.62 * s, -0.3 * s, true }, { 0.7 * s, -0.15 * s }, { 0.75 * s, 0.05 * s, true },
                { 0, 0.05 * s, true } }, V(0, 0, baseZ - 0.3 * s), Z, 20)

    -- THE SADDLE: a moulded base, a thick padded top, the handle at the front and
    -- a bumper round the back. Its top is at the rider's seat + (-0.5, 0, 2).
    local sc = V(saddleTop[1], 0, baseZ)       -- the saddle's base, under its middle
    local L0, L1 = -5.4 * s, 5.0 * s
    local Sb = M:bucket("frame", "seat")
    local topH = saddleTop[3] - baseZ           -- the cover's rise over the base
    saddleShell(Sb, sc, 18, 22, function(t)
        local x = L0 + (L1 - L0) * t
        -- broad and round behind, a narrower rounded nose, the top dished
        local w = 3.0 * s - 1.05 * s * t * t
        local endk = sqrt(max(0, 1 - ((2 * t - 1) ^ 8)))
        w = w * (0.35 + 0.65 * endk)
        local dish = 0.25 * s * (1 - (2 * t - 1) ^ 2)
        local h = (topH + 0.1 * s) * (0.55 + 0.45 * endk) - dish + 0.25 * s * (2 * t - 1) ^ 2
        return x, w, h, 0.18 * s, 0.15 * s
    end, 2.8)
    -- the base: a black plastic tray a little proud of the cover's sides
    local Pl = M:bucket("frame", "plastic")
    saddleShell(Pl, sc, 12, 22, function(t)
        local x = (L0 - 0.15 * s) + (L1 - L0 + 0.3 * s) * t
        local w = 3.08 * s - 1.05 * s * t * t
        local endk = sqrt(max(0, 1 - ((2 * t - 1) ^ 8)))
        return x, w * (0.35 + 0.65 * endk), 0.2 * s, 0.12 * s, 0
    end, 3.2)
    -- the front handle: a moulded loop off the nose, wide across
    sweep(Pl, spline({ add(sc, V(L1 - 0.6 * s, 0, 0.15 * s)), add(sc, V(L1 + 0.55 * s, 0, 0.35 * s)),
                       add(sc, V(L1 + 1.15 * s, 0, 1.2 * s)), add(sc, V(L1 + 0.95 * s, 0, 2.05 * s)),
                       add(sc, V(L1 + 0.1 * s, 0, 2.25 * s)), add(sc, V(L1 - 0.55 * s, 0, 1.75 * s)) }, 5),
          function() return 0.95 * s, 0.26 * s end, 16, { up = Y })
    -- the rear bumper: a rubbery block wrapped round the tail
    do
        local pts = {}
        for i = 0, 14 do
            local a = (i / 14 - 0.5) * 2.3
            pts[#pts + 1] = add(sc, V(L0 + 1.35 * s - cos(a) * 1.75 * s, sin(a) * 2.55 * s, 0.6 * s))
        end
        sweep(Pl, pts, function(t) return 0.62 * s, 0.42 * s end, 14, { up = Z })
    end
    -- piping round the cover's lower edge
    do
        local loopPts = {}
        local n = 24
        for i = 0, 2 * n do
            local u = i / n                         -- 0..1 down the +y side, 1..2 back up the -y side
            local t = (u <= 1) and u or (2 - u)
            local x = L0 + (L1 - L0) * (0.02 + 0.96 * t)
            local w = 3.0 * s - 1.05 * s * t * t
            local endk = sqrt(max(0, 1 - ((2 * (0.02 + 0.96 * t) - 1) ^ 8)))
            w = w * (0.35 + 0.65 * endk) + 0.02 * s
            loopPts[#loopPts + 1] = add(sc, V(x, (u <= 1) and w or -w, 0.42 * s))
        end
        sweep(M:bucket("frame", "plastic", true), loopPts, 0.07 * s, 6, { capStart = false, capEnd = false })
    end
    -- the four bolts of the post clamp, under the base
    for _, q in ipairs({ { 1.3, 0.9 }, { 1.3, -0.9 }, { -1.3, 0.9 }, { -1.3, -0.9 } }) do
        bolt(Cd, add(sc, V(q[1] * s, q[2] * s, -0.06 * s)), V(0, 0, -1), 0.13 * s, 0.1 * s)
    end

    M.layout = {
        k = 1, steer = { 0, 0, 1 },
        headT = { 0, 0, stTop }, headB = { 0, 0, crownZ0 },
        rear = { 0, 0, 0 }, front = { 0, 0, 0 },
        bb = { 0, 0, 0 }, crank = CR, pedalY = pedalY,
        seatTop = saddleTop,
        at = { wheel = { { 0, 0, 0 } } },
    }
    return M
end

G.RegisterKind("unicycle", function(opt) return tidy(buildUnicycle(opt)) end)

--------------------------------------------------------------------------
-- THE PENNY-FARTHING: a 52" ordinary at the registry's size (front axle at
-- +wheelbase/2, the 12" rear wheel's axle at -wheelbase/2 and radius -
-- rearRadius lower, the rider's seat at {8, 0, 33}).
--------------------------------------------------------------------------

-- An ordinary's wheel about its own axle: a solid round rubber tyre in a
-- crescent rim, radial spokes from two big flanges, a barrel hub.
local function solidWheel(M, group, o)
    local Rr, tr = o.radius, o.tyreR
    local c = Rr - tr                                  -- the tyre's section centre
    local segs = o.segs or 72
    -- tyre: a full round section
    do
        local prof = {}
        for i = 0, 16 do
            local a = -pi / 2 + i / 16 * TAU
            prof[#prof + 1] = { c + cos(a) * tr, sin(a) * tr }
        end
        lathe(M:bucket(group, "rubber"), prof, V(0, 0, 0), Y, segs)
    end
    -- rim: a rolled steel crescent cradling the tyre
    local rimIn = c - tr * 0.62 - o.rimDepth
    local w = o.rimW * 0.5
    do
        local prof = {
            { c - tr * 0.25, -w - 0.02, true }, { c - tr * 0.3, -w - 0.06 }, { c - tr * 0.55, -w * 0.92 },
            { rimIn + o.rimDepth * 0.35, -w * 0.55 }, { rimIn, 0 }, { rimIn + o.rimDepth * 0.35, w * 0.55 },
            { c - tr * 0.55, w * 0.92 }, { c - tr * 0.3, w + 0.06 }, { c - tr * 0.25, w + 0.02, true },
        }
        lathe(M:bucket(group, o.rim or "black"), prof, V(0, 0, 0), Y, segs, { inward = true })
        -- the crescent's inside, under the tyre
        lathe(M:bucket(group, o.rim or "black"), { { c - tr * 0.25, -w + 0.02 }, { c - tr * 0.75, 0 }, { c - tr * 0.25, w - 0.02 } },
              V(0, 0, 0), Y, segs)
    end
    -- hub: a barrel between two big flanges, polished
    local fy, fr = o.flangeY, o.flangeR
    local hh = o.hubHalf
    lathe(M:bucket(group, o.hubRole or "alloy"), {
        { 0, -hh, true }, { o.barrelR * 0.7, -hh, true }, { o.barrelR * 0.75, -hh + 0.1 },
        { o.barrelR * 0.8, -fy - 0.25, true }, { fr - 0.1, -fy - 0.1, true }, { fr, -fy - 0.04 }, { fr, -fy + 0.04 }, { fr - 0.1, -fy + 0.1, true },
        { o.barrelR, -fy + 0.3, true }, { o.barrelR * 0.92, 0 }, { o.barrelR, fy - 0.3, true },
        { fr - 0.1, fy - 0.1, true }, { fr, fy - 0.04 }, { fr, fy + 0.04 }, { fr - 0.1, fy + 0.1, true },
        { o.barrelR * 0.8, fy + 0.25, true }, { o.barrelR * 0.75, hh - 0.1 }, { o.barrelR * 0.7, hh, true }, { 0, hh, true },
    }, V(0, 0, 0), Y, 28)
    -- spokes: radial, alternate flanges, headed at the hub, nippled at the rim
    local C = M:bucket(group, "chrome", true)
    local N = o.spokes
    for i = 0, N - 1 do
        local a = (i + 0.5) / N * TAU
        local sd = (i % 2 == 0) and 1 or -1
        local d = V(cos(a), 0, sin(a))
        local hub = add(mul(d, fr - 0.22), V(0, fy * sd, 0))
        local rim = add(mul(d, rimIn + 0.04), V(0, 0.12 * sd, 0))
        sweep(C, { hub, rim }, o.spokeR, 5, { capStart = false, capEnd = false })
        local nd = norm(sub(rim, hub))
        sweep(C, { sub(rim, mul(nd, 0.4)), add(rim, mul(nd, 0.06)) }, o.spokeR * 1.9, 6, { capStart = false })
    end
    return rimIn
end

-- A rubber-block pedal about its own centre (x fwd, y along the spindle): two
-- steel end plates, two ribbed rubber blocks, the spindle and its tie rods.
local function blockPedal(M, group)
    local St = M:bucket(group, "chrome")
    local Rb = M:bucket(group, "rubber")
    local Sd = M:bucket(group, "steel", true)
    local hw = 1.95
    sweep(M:bucket(group, "steel"), { V(0, -hw - 0.15, 0), V(0, hw + 0.2, 0) }, 0.22, 12)
    lathe(Sd, { { 0, 0, true }, { 0.28, 0, true }, { 0.28, 0.2 }, { 0, 0.22, true } }, V(0, hw + 0.2, 0), Y, 6, { flat = true })
    for _, sy in ipairs({ -1, 1 }) do
        plate(St, roundRect(3.1, 1.0, 0.42, 4), V(0, sy * hw, 0), X, Z, 0.14)
    end
    for _, sx in ipairs({ -1, 1 }) do
        -- a block, ribbed across its tread face
        local prof = {}
        local L = 2 * hw - 0.14
        prof[#prof + 1] = { 0, -L / 2, true }
        prof[#prof + 1] = { 0.38, -L / 2, true }
        local h = -L / 2 + 0.12
        while h < L / 2 - 0.22 do
            prof[#prof + 1] = { 0.38, h, true }
            prof[#prof + 1] = { 0.33, h + 0.06, true }
            prof[#prof + 1] = { 0.33, h + 0.16, true }
            prof[#prof + 1] = { 0.38, h + 0.22, true }
            h = h + 0.3
        end
        prof[#prof + 1] = { 0.38, L / 2, true }
        prof[#prof + 1] = { 0, L / 2, true }
        lathe(Rb, prof, V(sx * 0.95, 0, 0), Y, 8, { phase = pi / 8 })
        sweep(Sd, { V(sx * 1.32, -hw, -0.3), V(sx * 1.32, hw, -0.3) }, 0.07, 6)
    end
end

local function buildPenny(opt)
    local M = Pm.newModel()
    local half = (opt.wheelbase or 44) * 0.5
    local RF = opt.radius or 26
    local RR = opt.rearRadius or 6
    local seat = opt.seat or { 8, 0, 33 }
    local saddleTop = add(seat, V(-0.5, 0, 2.0))
    local F = V(half, 0, 0)
    local Rx = V(-half, 0, -(RF - RR))

    -- the steer axis: through the front axle, raked back a little
    local st = norm(V(-0.105, 0, 1))
    local function A(s) return add(F, mul(st, s)) end
    local sCrown = RF + 1.7
    local sNeck0, sNeck1 = RF + 2.85, RF + 6.0
    local sTop = RF + 6.9

    local P = M:bucket("frame", "paint")
    local Pd = M:bucket("frame", "paint", true)
    local Fp = M:bucket("fork", "paint")
    local Fpd = M:bucket("fork", "paint", true)
    local Ch = M:bucket("fork", "chrome")
    local Chd = M:bucket("fork", "chrome", true)
    local Bk = M:bucket("frame", "black")

    -- THE WHEELS
    solidWheel(M, "wheelF", { radius = RF, tyreR = 0.47, rimDepth = 0.42, rimW = 1.12, segs = 96,
        flangeY = 2.45, flangeR = 2.55, barrelR = 0.95, hubHalf = 2.95, spokes = 64, spokeR = 0.055 })
    solidWheel(M, "wheelR", { radius = RR, tyreR = 0.38, rimDepth = 0.26, rimW = 0.82, segs = 48,
        flangeY = 0.75, flangeR = 0.95, barrelR = 0.42, hubHalf = 1.05, spokes = 20, spokeR = 0.045 })
    -- an oil cup on the big hub's barrel
    lathe(M:bucket("wheelF", "chrome", true), { { 0, 0, true }, { 0.22, 0, true }, { 0.22, 0.35 }, { 0.28, 0.4, true },
          { 0.28, 0.55 }, { 0, 0.6, true } }, V(0, 1.2, 0.85), Z, 10)

    -- THE FORK: oval blades from bearing boxes at the hub up to a crown over the
    -- tyre; the head's steerer above it.
    local BYF = 3.4
    for _, sd in ipairs({ 1, -1 }) do
        local box0 = V(F[1], BYF * sd, 0)
        -- bearing box: a split housing round the axle, its cap and an oiler
        lathe(Fp, { { 0.35, -0.48, true }, { 0.98, -0.48, true }, { 1.05, -0.38 }, { 1.05, 0.38 }, { 0.98, 0.48, true },
                    { 0.35, 0.48, true } }, box0, Y, 26)
        lathe(Chd, { { 0, 0, true }, { 0.16, 0, true }, { 0.16, 0.3 }, { 0.22, 0.34, true }, { 0, 0.42, true } },
              add(box0, mul(st, 1.0)), st, 8)
        -- the blade, curving in to the crown
        local top = add(A(sCrown), V(0, 1.75 * sd, 0))
        local bot = add(box0, mul(st, 0.75))
        local pts = bez3(bot, add(lerp(bot, top, 0.3), V(0, 0.15 * sd, 0)), add(lerp(bot, top, 0.75), V(0, 0.25 * sd, 0)), top, 24)
        sweep(Fp, pts, function(t) return 0.5 + 0.18 * t, 0.36 + 0.06 * t end, 18, { up = X, capStart = false, capEnd = false })
        bead(Fpd, add(box0, mul(st, 0.9)), st, 0.45, 0.07, 18)
    end
    -- the crown: an oval bar across the blades' tops
    do
        local cpts = {}
        for i = 0, 12 do
            local yy = (i / 12 * 2 - 1) * 2.15
            cpts[#cpts + 1] = add(A(sCrown + 0.1 * (1 - (yy / 2.15) ^ 2)), V(0, yy, 0))
        end
        sweep(Fp, cpts, function(t)
            local e = abs(t * 2 - 1)
            return 0.7 + 0.12 * (1 - e * e), 0.62 + 0.1 * (1 - e * e)
        end, 18, { up = st })
    end
    -- the steerer through the neck, the head's top nut and the bar clamp
    lathe(Fp, { { 0, sCrown - 0.1, true }, { 0.62, sCrown + 0.4, true }, { 0.55, sCrown + 0.9 }, { 0.55, sNeck0 } },
          F, st, 22)
    lathe(Ch, { { 0.55, sNeck0 - 0.2, true }, { 0.82, sNeck0 - 0.12, true }, { 0.82, sNeck0 - 0.02, true } }, F, st, 22)
    lathe(Ch, { { 0.82, sNeck1 + 0.02, true }, { 0.82, sNeck1 + 0.14, true }, { 0.55, sNeck1 + 0.22, true },
                { 0.55, sTop - 0.25 }, { 0.6, sTop - 0.2, true } }, F, st, 22)
    local barC = A(sTop + 0.15)
    lathe(Fp, { { 0, -0.75, true }, { 0.62, -0.75, true }, { 0.66, -0.6 }, { 0.66, 0.6 }, { 0.62, 0.75, true }, { 0, 0.75, true } },
          barC, Y, 22)
    lathe(Chd, { { 0, 0, true }, { 0.36, 0, true }, { 0.36, 0.2 }, { 0.2, 0.32, true }, { 0, 0.34, true } },
          add(barC, mul(st, 0.62)), st, 6, { flat = true })

    -- THE BARS: a moustache bar out to turned wooden grips, dropping at the ends.
    local fwdH = norm(cross(Y, st))
    if fwdH[1] < 0 then fwdH = mul(fwdH, -1) end
    local function barPts(sd)
        return {
            barC,
            add(barC, V(0.05, 1.2 * sd, 0.05)),
            add(barC, V(0.6, 3.6 * sd, 0.25)),
            add(barC, V(1.75, 6.4 * sd, 0.45)),
            add(barC, V(2.6, 8.3 * sd, 0.55)),
            add(barC, V(2.95, 9.0 * sd, 0.5)),
        }
    end
    local gripsAt = {}
    do
        local all = {}
        local r, l = barPts(-1), barPts(1)
        for i = #r, 2, -1 do all[#all + 1] = r[i] end
        for i = 1, #l do all[#all + 1] = l[i] end
        sweep(Ch, spline(all, 6), 0.4, 16)
        local Wd = M:bucket("fork", "wood")
        for _, sd in ipairs({ 1, -1 }) do
            local p = barPts(sd)
            local a, b = p[#p - 1], p[#p]
            local dir = norm(add(norm(sub(b, a)), V(0.05, 0, -0.1)))
            local g0 = add(b, mul(dir, -0.15))
            -- a ferrule, then the pear-shaped turned handle
            lathe(Ch, { { 0.38, -0.05, true }, { 0.5, 0, true }, { 0.5, 0.3, true }, { 0.4, 0.34, true } }, g0, dir, 18)
            lathe(Wd, { { 0.42, 0.3, true }, { 0.56, 0.45 }, { 0.62, 0.9 }, { 0.6, 1.6 }, { 0.68, 2.3 }, { 0.76, 2.9 },
                        { 0.72, 3.4 }, { 0.5, 3.75 }, { 0, 3.88, true } }, g0, dir, 20)
            gripsAt[sd] = { A = add(g0, mul(dir, 0.6)), B = add(g0, mul(dir, 3.5)) }
        end
    end

    -- THE SPOON BRAKE: a lever along the right bar, a rod down the front of the
    -- head, a spoon pressed onto the tyre's crown.
    do
        local Lv = Ch
        local piv = add(barC, V(0.75, -2.2, 0.15))
        lathe(Chd, { { 0, -0.3, true }, { 0.24, -0.3, true }, { 0.24, 0.3, true }, { 0, 0.3, true } }, piv, Z, 10)
        sweep(Lv, spline({ add(piv, V(0.0, 0, 0)), add(piv, V(0.55, -2.0, -0.2)), add(piv, V(1.35, -5.0, -0.35)),
                           add(piv, V(1.7, -6.2, -0.55)) }, 5), function(t) return 0.16, 0.24 - 0.06 * t end, 10, { up = Z })
        -- the spoon on the tyre's crown, ahead of the crown
        local a0, a1 = 1.18, 1.5
        local spts = {}
        for i = 0, 10 do
            local a = a0 + (a1 - a0) * i / 10
            spts[#spts + 1] = add(F, V(cos(a) * (RF + 0.1), 0, sin(a) * (RF + 0.1)))
        end
        sweep(Lv, spts, function(t) local e = (t * 2 - 1) return 0.5 * sqrt(max(0.05, 1 - e ^ 6)), 0.09 end, 12, { up = Y })
        local spoonTop = add(F, V(cos(1.32) * (RF + 0.25), 0, sin(1.32) * (RF + 0.25)))
        -- the rod, up the front of the head to the lever's crank
        local rodTop = add(piv, V(0.45, 1.0, -0.25))
        local guide = add(A(sCrown + 0.5), mul(fwdH, 1.0))
        sweep(Lv, spline({ spoonTop, add(lerp(spoonTop, guide, 0.5), mul(fwdH, 0.4)), guide, rodTop }, 6), 0.11, 8)
        lathe(Chd, { { 0.1, -0.25, true }, { 0.24, -0.25, true }, { 0.24, 0.25, true }, { 0.1, 0.25, true } }, guide, st, 10)
        sweep(Lv, { rodTop, add(piv, V(0.1, 0, 0)) }, 0.13, 8)
    end

    -- THE NECK AND BACKBONE: a sleeve round the steerer, then a tapering oval
    -- tube following the big wheel round and down to the little wheel's fork.
    lathe(P, { { 0.6, sNeck0, true }, { 0.98, sNeck0, true }, { 1.02, sNeck0 + 0.15 }, { 0.92, sNeck0 + 0.5 },
               { 0.92, sNeck1 - 0.5 }, { 1.02, sNeck1 - 0.15 }, { 0.98, sNeck1, true }, { 0.6, sNeck1, true } }, F, st, 26)
    local neckMid = A((sNeck0 + sNeck1) * 0.5)
    local bbPts = {
        add(neckMid, V(-0.5, 0, 0.1)),
        V(13.0, 0, 30.9), V(7.5, 0, 29.6), V(1.5, 0, 26.7), V(-4.0, 0, 21.6), V(-8.5, 0, 14.6),
        V(-12.6, 0, 6.6), V(-16.2, 0, -0.9), V(-19.0, 0, -6.5), V(Rx[1] + 1.05, 0, Rx[3] + RR + 2.4),
    }
    local bpath = spline(bbPts, 6)
    local bbR = function(t) return 0.98 - 0.4 * t, 0.82 - 0.32 * t end
    sweep(P, bpath, bbR, 20, { up = Y, capStart = false, capEnd = true })
    -- the backbone's socket on the neck: a collar where it is brazed in
    do
        local d = norm(sub(bpath[4], bpath[2]))
        lathe(P, { { 0.9, -0.2, true }, { 1.12, -0.12 }, { 1.14, 0.25 }, { 1.0, 0.6 }, { 0.92, 0.75, true } }, bpath[2], d, 22)
    end
    local function backboneZ(x)
        for i = 2, #bpath do
            local a, b = bpath[i - 1], bpath[i]
            if (a[1] - x) * (b[1] - x) <= 0 then
                local t = (x - a[1]) / (b[1] - a[1])
                return a[3] + (b[3] - a[3]) * t
            end
        end
        return bpath[#bpath][3]
    end

    -- THE REAR FORK: two short flat blades from the backbone's end to the
    -- little wheel's axle, and its axle and nuts.
    local bEnd = bpath[#bpath]
    for _, sd in ipairs({ 1, -1 }) do
        local a = add(bEnd, V(0.05, 0.35 * sd, -0.2))
        local b = V(Rx[1], 1.02 * sd, Rx[3] + 0.3)
        local pts = bez3(a, add(lerp(a, b, 0.3), V(0, 0.5 * sd, 0)), add(lerp(a, b, 0.7), V(0, 0.25 * sd, 0)), b, 12)
        sweep(P, pts, function(t) return 0.32, 0.24 - 0.05 * t end, 14, { up = X, capStart = false })
        plate(P, roundRect(1.1, 1.2, 0.45, 4, Rx[1], Rx[3] + 0.1), V(0, 1.05 * sd, 0), X, Z, 0.22)
        bolt(M:bucket("frame", "chrome", true), V(Rx[1], 1.18 * sd, Rx[3]), mul(Y, sd), 0.32, 0.26)
    end
    sweep(M:bucket("frame", "steel"), { V(Rx[1], -1.45, Rx[3]), V(Rx[1], 1.45, Rx[3]) }, 0.17, 10)
    bead(Pd, add(bEnd, V(0, 0, -0.1)), V(0, 0, 1), 0.55, 0.07, 16)

    -- THE MOUNTING STEP: a serrated round plate on a stalk, on the left of the
    -- backbone above the little wheel.
    do
        local zS = -3.0
        local xS
        for i = 2, #bpath do
            local a, b = bpath[i - 1], bpath[i]
            if (a[3] - zS) * (b[3] - zS) <= 0 then xS = a[1] + (b[1] - a[1]) * (zS - a[3]) / (b[3] - a[3]) break end
        end
        xS = xS or -16
        local base = V(xS, 0.55, zS)
        local stepC = V(xS - 0.7, 3.1, zS + 0.35)
        local Cs = M:bucket("frame", "chrome")
        sweep(Cs, spline({ base, V(xS - 0.2, 1.6, zS + 0.05), add(stepC, V(0.2, -0.4, -0.25)) }, 4), 0.22, 10)
        lathe(Cs, { { 0, -0.14, true }, { 1.45, -0.14, true }, { 1.5, -0.06 }, { 1.5, 0.06 }, { 1.42, 0.14, true }, { 0, 0.14, true } },
              stepC, Z, 28)
        local Sd = M:bucket("frame", "steel", true)
        for i = -2, 2 do
            box(Sd, add(stepC, V(i * 0.4, 0, 0.15)), V(0.06, 0, 0), V(0, sqrt(max(0, 1.4 ^ 2 - (i * 0.4) ^ 2)) * 0.92, 0), V(0, 0, 0.05))
        end
    end

    -- THE SPRING AND SADDLE: a long leaf spring clamped behind the neck, arched
    -- over the backbone, a hanger at its tail; a leather saddle on it.
    local sx = saddleTop[1]
    do
        local Sp = M:bucket("frame", "black")
        local front = V(neckMid[1] - 1.9, 0, backboneZ(neckMid[1] - 1.9) + 0.9)
        local tail = V(sx - 5.6, 0, saddleTop[3] - 3.1)
        local spts = spline({ front, V(sx + 4.2, 0, saddleTop[3] - 2.35), V(sx, 0, saddleTop[3] - 2.15),
                              V(sx - 3.6, 0, saddleTop[3] - 2.4), tail }, 6)
        sweep(Sp, spts, function() return 0.62, 0.11 end, 12, { up = Y })
        -- the clamp at the front, round the backbone
        local fz = backboneZ(front[1])
        lathe(Bk, { { 0.95, -0.4, true }, { 1.05, -0.38 }, { 1.05, 0.38 }, { 0.95, 0.4, true } }, V(front[1], 0, fz),
              norm(sub(V(front[1] - 1, 0, backboneZ(front[1] - 1)), V(front[1], 0, fz))), 22)
        -- the hanger at the tail, down to a clip on the backbone
        local hz = backboneZ(tail[1])
        local St2 = M:bucket("frame", "steel")
        for _, sd in ipairs({ 1, -1 }) do
            sweep(St2, { add(tail, V(0, 0.45 * sd, 0)), V(tail[1] + 0.2, 0.6 * sd, hz + 0.3) }, 0.1, 8)
        end
        lathe(Bk, { { 0.9, -0.3, true }, { 1.0, -0.28 }, { 1.0, 0.28 }, { 0.9, 0.3, true } }, V(tail[1] + 0.2, 0, hz),
              norm(sub(V(tail[1] - 1, 0, backboneZ(tail[1] - 1)), V(tail[1] + 0.2, 0, hz))), 22)
        sweep(St2, { V(tail[1] + 0.2, -0.75, hz + 0.3), V(tail[1] + 0.2, 0.75, hz + 0.3) }, 0.11, 8)
        -- the saddle's clips onto the spring
        for _, dx in ipairs({ -2.3, 2.3 }) do
            box(Bk, V(sx + dx, 0, saddleTop[3] - 2.05), V(0.35, 0, 0), V(0, 0.75, 0), V(0, 0, 0.18))
        end
    end
    -- the saddle: a broad leather top, tail cantle and rivets
    local Lb = M:bucket("frame", "leather")
    local sc = V(sx, 0, saddleTop[3] - 1.62)
    local SL0, SL1 = -4.7, 4.9
    saddleShell(Lb, sc, 18, 22, function(t)
        local x = SL0 + (SL1 - SL0) * t
        local w = (t < 0.1) and (3.3 * sqrt(max(0, t / 0.1)) + 0.25) or (3.55 - 2.65 * ((t - 0.1) / 0.9) ^ 1.5)
        if t > 0.95 then w = w * sqrt(max(0.05, (1 - t) / 0.05)) end
        local h = 1.75 + 0.15 * t - 0.2 * (1 - (2 * t - 1) ^ 2)
        if t < 0.04 or t > 0.96 then h = h * 0.6 end
        return x, w, h, 0.25, 0
    end, 3.4)
    -- the cantle plate across the tail and its rivets
    local Cc = M:bucket("frame", "chrome", true)
    do
        local pts = {}
        for i = 0, 12 do
            local a = (i / 12 - 0.5) * 2.4
            pts[#pts + 1] = add(sc, V(SL0 + 1.0 - cos(a) * 1.05, sin(a) * 3.0, 0.45))
        end
        sweep(M:bucket("frame", "black"), pts, function() return 0.36, 0.12 end, 10, { up = Z })
        for i = 0, 6 do
            local a = (i / 6 - 0.5) * 2.0
            local p = add(sc, V(SL0 + 1.0 - cos(a) * 1.18, sin(a) * 3.15, 1.25))
            lathe(Cc, { { 0, 0, true }, { 0.1, 0, true }, { 0.08, 0.06 }, { 0, 0.07, true } }, p,
                  norm(V(-cos(a), sin(a), 0.4)), 8)
        end
        lathe(Cc, { { 0, 0, true }, { 0.12, 0, true }, { 0.1, 0.07 }, { 0, 0.08, true } }, add(sc, V(SL1 - 0.45, 0, 1.6)), Z, 8)
    end

    -- THE CRANKS on the big hub: square axle ends, slotted steel arms (the
    -- throw is set by where the pedal sits in the slot), the right one forward.
    local CR = 6.75
    local armY = 4.2
    local pedalY = armY + 0.35 + 2.0
    do
        local Cc2 = M:bucket("cranks", "chrome")
        local Sd = M:bucket("cranks", "steel")
        local Bd = M:bucket("cranks", "black", true)
        sweep(Sd, { V(F[1], -armY - 0.35, 0), V(F[1], armY + 0.35, 0) }, 0.42, 4, { phase = pi / 4 })
        for _, sd in ipairs({ -1, 1 }) do
            local dir = (sd == -1) and X or mul(X, -1)
            local root = V(F[1], armY * sd, 0)
            local tip = add(V(F[1], (armY + 0.1) * sd, 0), mul(dir, CR))
            crankArm(Cc2, root, add(tip, mul(dir, 0.6)), 1.25, 0.9, 0.48, 0.4, 0.95, 0.62)
            -- the slot, along the outer face
            box(Bd, add(lerp(root, tip, 0.62), V(0, 0.22 * sd, 0)), mul(dir, CR * 0.3), V(0, 0.02, 0), V(0, 0, 0.18))
            -- the cotter and the pedal's nut
            bolt(Sd, add(root, V(0, 0.24 * sd, 0)), mul(Y, sd), 0.4, 0.25)
            bolt(Sd, add(tip, V(0, 0.2 * sd, 0)), mul(Y, sd), 0.3, 0.22)
        end
    end
    blockPedal(M, "pedal")

    M.layout = {
        k = 1, steer = st,
        headT = A(sTop), headB = A(sNeck0),
        rear = Rx, front = F,
        bb = F, crank = CR, pedalY = pedalY,
        gripR = { A = gripsAt[-1].A, B = gripsAt[-1].B },
        gripL = { A = gripsAt[1].A, B = gripsAt[1].B },
        seatTop = saddleTop,
    }
    return M
end

G.RegisterKind("penny", function(opt) return tidy(buildPenny(opt)) end)

--------------------------------------------------------------------------
-- THE TANDEM: a steel road/touring tandem at the registry's size (wheelbase
-- 70, 700c wheels of radius 13, the captain's seat {9, 0, 22}, the stoker's
-- {-18, 0, 22}). Double-diamond with a direct lateral, eccentric captain's
-- bottom bracket, the timing chain on the LEFT, the drive chain on the right
-- from the stoker's double to a nine-speed cassette, cantilever brakes, drop
-- bars for the captain and a stoker's bar on the captain's seat post.
--------------------------------------------------------------------------

-- A road saddle whose top is at `top` (x is the saddle's middle): a lofted
-- shell, its rails and the post's clamp. Returns the clamp's centre.
local function roadSaddle(M, group, top, postDir)
    local Sb = M:bucket(group, "seat")
    local L0, L1 = -4.6, 6.2
    local function shape(t)
        local x = L0 + (L1 - L0) * t
        local w = (t < 0.07) and (2.55 * sqrt(max(0, t / 0.07)) + 0.2) or (2.75 - 2.1 * ((t - 0.07) / 0.93) ^ 0.9)
        if t > 0.6 then w = max(w, 0.62) end
        if t > 0.96 then w = w * sqrt(max(0.05, (1 - t) / 0.04)) end
        local h = 0.95 - 0.3 * t
        if t < 0.04 or t > 0.96 then h = h * 0.45 end
        local z0 = 0.05 * t + 0.2 * t * t - 0.12
        return x, w, h, 0.18, z0
    end
    -- the top point is near the middle: put the shell's crest at `top`
    local _, _, hm, _, zm = shape((0 - L0) / (L1 - L0))
    local c = V(top[1], top[2], top[3] - hm - zm)
    saddleShell(Sb, c, 20, 20, shape, 2.6)
    -- rails: two steel rods under the shell, kinked up into its nose and tail
    local St = M:bucket(group, "steel", true)
    for _, sd in ipairs({ 1, -1 }) do
        sweep(St, spline({ add(c, V(L1 - 0.9, 0.3 * sd, -0.1)), add(c, V(L1 - 2.2, 0.75 * sd, -0.55)),
                           add(c, V(-1.6, 0.85 * sd, -0.62)), add(c, V(L0 + 1.0, 1.25 * sd, -0.35)),
                           add(c, V(L0 + 0.45, 1.3 * sd, -0.05)) }, 4), 0.09, 8)
    end
    -- the post's clamp round the rails
    local clamp = add(c, V(0.6, 0, -0.75))
    local Bk = M:bucket(group, "black")
    lathe(Bk, { { 0, -1.0, true }, { 0.24, -1.0, true }, { 0.26, -0.9 }, { 0.26, 0.9 }, { 0.24, 1.0, true }, { 0, 1.0, true } },
          add(clamp, V(0, 0, 0.12)), Y, 14)
    box(Bk, add(clamp, V(0, 0, -0.1)), V(0.75, 0, 0), V(0, 0.55, 0), V(0, 0, 0.2))
    return add(clamp, V(0, 0, -0.25))
end

-- A drop handlebar's centre line for one side (sd = 1 left, -1 right), about
-- its clamp, and where the hood sits on it.
local function dropBar(clampC, sd)
    local function P(x, y, z) return add(clampC, V(x, y * sd, z)) end
    return {
        P(0, 0, 0), P(0, 1.6, 0), P(0.08, 5.6, 0.0), P(0.75, 7.75, -0.05), P(2.15, 8.35, -0.45),
        P(3.0, 8.45, -1.55), P(2.8, 8.5, -3.6), P(1.4, 8.6, -4.85), P(-0.6, 8.65, -5.0), P(-1.9, 8.7, -4.95),
    }
end

-- A cantilever brake: bosses `boss[1]`/`boss[-1]` on the stays or legs, the
-- rim's braking track at `pad` distance along the line from `axle`; arms out
-- to the sides, a straddle wire to a yoke above the tyre. Returns the yoke.
local function cantilever(M, group, axle, boss, R, upDir)
    local Bk = M:bucket(group, "black")
    local Pl = M:bucket(group, "plastic")
    local St = M:bucket(group, "steel", true)
    local Cd = M:bucket(group, "chrome", true)
    local tips = {}
    for _, sd in ipairs({ 1, -1 }) do
        local b = boss[sd]
        local radial = norm(sub(V(b[1], 0, b[3]), V(axle[1], 0, axle[3])))
        local tang = norm(cross(Y, radial))
        local padC = add(V(axle[1], (R.rimW * 0.5 + 0.28) * sd, axle[3]), mul(radial, R.rimOut - 0.35))
        local tip = add(b, add(mul(radial, 1.2), V(0, 1.6 * sd, 0)))
        tips[sd] = tip
        -- the boss's sleeve, the arm out from it, the pad's post
        lathe(Cd, { { 0, 0, true }, { 0.24, 0, true }, { 0.24, 0.55, true }, { 0, 0.55, true } }, b, mul(Y, sd), 10)
        sweep(Bk, spline({ add(b, V(0, 0.35 * sd, 0)), add(b, add(mul(radial, 0.5), V(0, 0.95 * sd, 0))), tip }, 4),
              function(t) return 0.22 - 0.06 * t, 0.15 end, 10, { up = tang })
        sweep(Bk, { add(b, V(0, 0.3 * sd, 0)), add(padC, V(0, 0.35 * sd, 0)) }, 0.12, 8)
        box(Pl, padC, mul(tang, 0.75), V(0, 0.17 * sd, 0), mul(radial, 0.2))
        lathe(Cd, { { 0, 0, true }, { 0.15, 0, true }, { 0.15, 0.12 }, { 0, 0.13, true } }, add(tip, V(0, 0.08 * sd, 0)), mul(Y, sd), 6, { flat = true })
    end
    local mid = lerp(tips[1], tips[-1], 0.5)
    local yoke = add(mid, mul(upDir, 1.6))
    sweep(St, { tips[1], yoke }, 0.045, 6)
    sweep(St, { tips[-1], yoke }, 0.045, 6)
    lathe(Bk, { { 0, -0.2, true }, { 0.22, -0.2, true }, { 0.22, 0.2, true }, { 0, 0.2, true } }, yoke, X, 10)
    return yoke
end

local function buildTandem(opt)
    local M = Pm.newModel()
    local wb = opt.wheelbase or 70
    local half = wb * 0.5
    local RW = opt.radius or 13
    local seat1 = opt.seat or { 9, 0, 22 }
    local seat2 = (opt.extra and opt.extra.stoker) or { seat1[1] - 27 * wb / 70, 0, seat1[3] }
    local top1, top2 = add(seat1, V(-0.5, 0, 2.0)), add(seat2, V(-0.5, 0, 2.0))
    local rear, front = V(-half, 0, 0), V(half, 0, 0)
    -- the bottom brackets, under each saddle the way a road bike has it
    local bb1 = V(seat1[1] + 5.0, 0, seat1[3] - 19.3)
    local bb2 = V(seat2[1] + 5.0, 0, seat2[3] - 19.3)
    local CR, PEDALY = 6.8, 5.2

    local P = M:bucket("frame", "paint")
    local Pd = M:bucket("frame", "paint", true)
    local Bk = M:bucket("frame", "black")
    local Ch = M:bucket("frame", "chrome")
    local Cd = M:bucket("frame", "chrome", true)
    local Al = M:bucket("frame", "alloy")
    local St = M:bucket("frame", "steel")
    local Pl = M:bucket("frame", "plastic")

    -- THE WHEELS: 700 x 30 on 40-hole rims, three-cross
    local R = G.WheelDims(RW, { width = 1.18, height = 0.78, rimDepth = 0.75, rimW = 0.82, flangeR = 1.2 })
    G.parts.wheel(M, "wheelF", R, { tread = "road", wall = "rubber", rim = "alloy", spokes = 40, cross = 3,
                                    hubHalf = 1.97, hubRole = "alloy" })
    G.parts.wheel(M, "wheelR", R, { tread = "road", wall = "rubber", rim = "alloy", spokes = 40, cross = 3,
                                    hubHalf = 1.6, rear = true, cog = false, hubRole = "alloy" })
    dropRole(M, "wheelF", "tyretext")
    dropRole(M, "wheelR", "tyretext")
    -- the rear's freehub body and a nine-speed cassette, largest cog inboard
    local COGS = { 32, 28, 24, 21, 19, 17, 15, 13, 11 }
    local cogY = {}
    do
        local Sw = M:bucket("wheelR", "steel")
        local Bw = M:bucket("wheelR", "black")
        lathe(Bw, { { 0.62, -1.3, true }, { 0.7, -1.3, true }, { 0.7, -2.75, true }, { 0.62, -2.75, true } }, V(0, 0, 0), Y, 18)
        for i, n in ipairs(COGS) do
            local y = -1.3 - (i - 1) * 0.168
            cogY[n] = y
            sprocket(Sw, n, 0, y, 0, 0.07, 0.72, 4)
            -- the spacer behind each cog
            if i < #COGS then
                lathe(Bw, { { 0.72, y - 0.04, true }, { G.parts.pitchRadius(COGS[i + 1]) - 0.35, y - 0.04, true },
                            { G.parts.pitchRadius(COGS[i + 1]) - 0.35, y - 0.13, true }, { 0.72, y - 0.13, true } }, V(0, 0, 0), Y, 18)
            end
        end
        lathe(Sw, { { 0.35, -2.75, true }, { 0.72, -2.75, true }, { 0.72, -2.95, true }, { 0.35, -2.95, true } }, V(0, 0, 0), Y, 8, { flat = true })
    end

    -- THE HEAD: 72 degrees, 47 mm of fork offset
    local steer = norm(V(-0.309, 0, 0.951))
    local perpF = norm(cross(Y, steer))
    if perpF[1] < 0 then perpF = mul(perpF, -1) end
    local A0 = sub(front, mul(perpF, 1.85))
    local function A(s) return add(A0, mul(steer, s)) end
    local sCrown, sHB, sHT = RW + 1.45, RW + 2.25, RW + 8.6
    local headB, headT = A(sHB), A(sHT)
    lathe(P, { { 0, -0.02, true }, { 0.82, 0, true }, { 0.86, 0.15 }, { 0.8, 0.45 }, { 0.76, 1.0 }, { 0.76, sHT - sHB - 1.0 },
               { 0.8, sHT - sHB - 0.45 }, { 0.86, sHT - sHB - 0.15 }, { 0.82, sHT - sHB, true }, { 0, sHT - sHB + 0.02, true } },
          headB, steer, 26)
    -- headset cups, chrome, top and bottom
    lathe(Ch, { { 0.6, -0.4, true }, { 0.92, -0.4, true }, { 0.92, 0, true }, { 0.6, 0, true } }, headB, steer, 24)
    lathe(Ch, { { 0.6, 0, true }, { 0.92, 0, true }, { 0.92, 0.45, true }, { 0.6, 0.45, true } }, headT, steer, 24)

    -- THE SEAT TUBES: from each bottom bracket toward its saddle
    local function stDir(bb, top) return norm(sub(V(top[1] + 0.3, 0, top[3] - 1.6), bb)) end
    local sd1, sd2 = stDir(bb1, top1), stDir(bb2, top2)
    local lugZ = 18.9
    local function onST(bb, d, z) return add(bb, mul(d, (z - bb[3]) / d[3])) end
    local lug1, lug2 = onST(bb1, sd1, lugZ), onST(bb2, sd2, lugZ)

    -- THE TUBES
    local function tube(a, b, r, bucket) sweep(bucket or P, { a, b }, r, 20, { capStart = false, capEnd = false }) end
    local ttHead, dtHead, latHead = A(sHT - 0.75), A(sHB + 0.95), A(sHT - 2.35)
    local tt1 = onST(bb1, sd1, lugZ - 0.5)
    tube(ttHead, tt1, 0.62)                                   -- the captain's top tube
    tube(dtHead, bb1, 0.74)                                   -- the down tube
    tube(bb1, add(lug1, mul(sd1, 0.3)), 0.62)                 -- captain's seat tube
    tube(bb2, add(lug2, mul(sd2, 0.3)), 0.62)                 -- stoker's seat tube
    local mid0, mid1 = onST(bb1, sd1, lugZ - 1.3), onST(bb2, sd2, lugZ - 0.6)
    tube(mid0, mid1, 0.58)                                    -- the mid top tube
    tube(bb1, bb2, 0.74)                                      -- the boom
    tube(latHead, bb2, 0.52)                                  -- the direct lateral
    -- the bottom bracket shells: the captain's eccentric, the stoker's plain
    lathe(P, { { 0, -1.36, true }, { 1.12, -1.36, true }, { 1.16, -1.2 }, { 1.16, 1.2 }, { 1.12, 1.36, true }, { 0, 1.36, true } }, bb1, Y, 28)
    lathe(Al, { { 0, -1.42, true }, { 0.95, -1.42, true }, { 0.95, 1.42, true }, { 0, 1.42, true } }, add(bb1, V(0.18, 0, -0.1)), Y, 24)
    for _, dx in ipairs({ -0.35, 0.35 }) do
        box(P, add(bb1, V(-1.05 + dx * 0.2, 0, 0.75 + dx)), V(0.3, 0, 0), V(0, 0.22, 0), V(0, 0, 0.2))
        bolt(Cd, add(bb1, V(-1.05 + dx * 0.2, 0.22, 0.75 + dx)), Y, 0.16, 0.12)
    end
    lathe(P, { { 0, -1.36, true }, { 0.9, -1.36, true }, { 0.94, -1.2 }, { 0.94, 1.2 }, { 0.9, 1.36, true }, { 0, 1.36, true } }, bb2, Y, 28)
    -- seat lugs with their binder bolts, and the posts
    local posts = {}
    for i, set in ipairs({ { bb1, sd1, lug1, top1 }, { bb2, sd2, lug2, top2 } }) do
        local bb, d, lug, top = set[1], set[2], set[3], set[4]
        lathe(P, { { 0.6, -0.55, true }, { 0.72, -0.5 }, { 0.74, 0.25 }, { 0.7, 0.42 }, { 0.6, 0.48, true }, { 0.48, 0.48, true } }, lug, d, 22)
        local back = norm(cross(Y, d))
        if back[1] > 0 then back = mul(back, -1) end
        box(P, add(lug, mul(back, 0.85)), mul(back, 0.2), V(0, 0.32, 0), mul(d, 0.25))
        bolt(Cd, add(add(lug, mul(back, 0.85)), V(0, 0.32, 0)), Y, 0.15, 0.12)
        -- the saddle, and the post up to it
        local clamp = roadSaddle(M, "frame", top, d)
        local pTop = clamp
        local pBot = add(lug, mul(d, -1.5))
        sweep(Al, { pBot, add(onST(bb, d, pTop[3]), V(0, 0, 0)), pTop }, 0.53, 18, { capStart = false })
        posts[i] = { bb = bb, d = d, lug = lug, top = pTop }
    end

    -- STAYS AND DROPOUTS: 145 mm at the rear
    local DY = 2.85
    local ssTop = add(lug2, mul(sd2, -0.35))
    for _, s in ipairs({ 1, -1 }) do
        local cs0 = add(bb2, V(-0.7, 0.95 * s, -0.05))
        local cs1 = add(rear, V(1.15, (DY - 0.2) * s, 0.15))
        sweep(P, bez3(cs0, add(cs0, V(-4.5, 0.6 * s, -0.25)), add(cs1, V(5.5, -0.2 * s, 0.15)), cs1, 16),
              function(t) return 0.42 - 0.12 * t, 0.5 - 0.17 * t end, 16, { up = Z, capStart = false })
        local ss0 = add(ssTop, V(-0.4, 0.55 * s, 0))
        local ss1 = add(rear, V(0.75, (DY - 0.2) * s, 0.95))
        sweep(P, bez3(ss0, add(lerp(ss0, ss1, 0.3), V(0, 0.9 * s, 0)), add(lerp(ss0, ss1, 0.75), V(0, 0.35 * s, 0)), ss1, 16),
              function(t) return 0.36 - 0.08 * t end, 16, { capStart = false })
        -- the dropout: a plate, slotted forward-down for the axle
        local loop = {}
        local function at(u, v) loop[#loop + 1] = { rear[1] + u, rear[3] + v } end
        at(-0.28, 0.0); at(-0.28, -0.25)
        for i = 1, 5 do local a = pi + i / 6 * pi at(cos(a) * 0.28, sin(a) * 0.28) end
        at(0.28, -0.25); at(0.28, 0.0); at(1.55, 0.95); at(1.7, 0.2); at(1.4, -0.6); at(0.5, -1.05); at(-0.4, -0.95)
        at(-1.0, -0.4); at(-1.15, 0.45); at(-0.6, 1.2); at(0.4, 1.4); at(1.1, 1.3)
        plate(P, loop, V(0, DY * s, 0), X, Z, 0.24)
    end
    -- the bridge between the seat stays and the chain stays
    do
        local function ssAt(s, t)
            local ss0 = add(ssTop, V(-0.4, 0.55 * s, 0))
            local ss1 = add(rear, V(0.75, (DY - 0.2) * s, 0.95))
            return lerp(ss0, ss1, t)
        end
        sweep(P, { ssAt(1, 0.32), ssAt(-1, 0.32) }, 0.28, 12, { capStart = false, capEnd = false })
    end
    -- the derailleur hanger, below the right dropout
    local hanger = add(rear, V(0.1, -DY - 0.15, -1.2))
    plate(P, roundRect(1.0, 1.7, 0.4, 3, rear[1] + 0.1, rear[3] - 0.85), V(0, -DY - 0.15, 0), X, Z, 0.2)
    -- the rear axle, locknuts and the quick release
    sweep(St, { add(rear, V(0, -DY - 0.45, 0)), add(rear, V(0, DY + 0.45, 0)) }, 0.2, 10)
    lathe(Cd, { { 0, 0, true }, { 0.42, 0, true }, { 0.42, 0.35, true }, { 0.2, 0.42, true }, { 0, 0.42, true } }, add(rear, V(0, DY + 0.12, 0)), Y, 14)
    sweep(Cd, { add(rear, V(0, DY + 0.5, 0)), add(rear, V(1.2, DY + 0.6, -0.4)), add(rear, V(2.6, DY + 0.55, -0.6)) }, function() return 0.25, 0.12 end, 8, { up = Y })

    -- WELD BEADS where the tubes meet
    local function beadAt(p, d, r) bead(Pd, p, d, r, 0.07, 20) end
    beadAt(add(bb1, mul(sd1, 1.15)), sd1, 0.64)
    beadAt(add(bb2, mul(sd2, 1.0)), sd2, 0.64)
    beadAt(add(bb1, mul(norm(sub(dtHead, bb1)), 1.2)), norm(sub(dtHead, bb1)), 0.76)
    beadAt(add(bb1, V(-1.2, 0, 0)), X, 0.76)
    beadAt(add(bb2, V(1.0, 0, 0)), X, 0.76)
    beadAt(add(bb2, mul(norm(sub(latHead, bb2)), 1.15)), norm(sub(latHead, bb2)), 0.54)
    beadAt(add(ttHead, mul(norm(sub(tt1, ttHead)), 0.82)), norm(sub(tt1, ttHead)), 0.64)
    beadAt(add(dtHead, mul(norm(sub(bb1, dtHead)), 0.85)), norm(sub(bb1, dtHead)), 0.76)
    beadAt(add(latHead, mul(norm(sub(bb2, latHead)), 0.82)), norm(sub(bb2, latHead)), 0.54)

    -- A WATER BOTTLE on the down tube
    do
        local d = norm(sub(dtHead, bb1))
        local up = norm(cross(d, Y))
        if up[3] < 0 then up = mul(up, -1) end
        local base = add(add(bb1, mul(d, 4.2)), mul(up, 1.55))
        local Wt = M:bucket("frame", "white")
        lathe(Wt, { { 0, 0, true }, { 1.25, 0, true }, { 1.36, 0.2 }, { 1.36, 3.4 }, { 1.25, 3.7 }, { 1.36, 4.0 }, { 1.36, 6.4 },
                    { 1.1, 7.2 }, { 0.62, 7.45, true } }, base, d, 22)
        lathe(Bk, { { 0.62, 7.45, true }, { 0.62, 8.0 }, { 0.45, 8.15, true }, { 0.22, 8.6, true }, { 0, 8.65, true } }, base, d, 16)
        for _, s in ipairs({ 1, -1 }) do
            sweep(Cd, spline({ add(add(bb1, mul(d, 4.6)), mul(up, 0.55)), add(add(base, mul(d, 0.6)), V(0, 1.3 * s, 0)),
                               add(add(base, mul(d, 4.0)), V(0, 1.42 * s, 0.0)), add(add(base, mul(d, 6.0)), add(mul(up, 1.0), V(0, 1.1 * s, 0))) }, 5),
                  0.07, 6)
        end
    end

    -- THE FORK: a lugged crown, curved blades, cantilever bosses
    local F = M:bucket("fork", "paint")
    local Fd = M:bucket("fork", "paint", true)
    local FC = M:bucket("fork", "chrome")
    local crown = A(sCrown)
    do
        local cpts = {}
        for i = 0, 10 do
            local yy = (i / 10 * 2 - 1) * 1.75
            cpts[#cpts + 1] = add(add(crown, V(0, yy, 0)), mul(perpF, 0.12 * (1 - (yy / 1.75) ^ 2)))
        end
        sweep(FC, cpts, function(t) local e = abs(t * 2 - 1) return 0.62 + 0.08 * (1 - e * e), 0.56 + 0.1 * (1 - e * e) end, 18, { up = steer })
        sweep(F, { add(crown, mul(steer, 0.2)), A(sHB - 0.35) }, 0.6, 18, { capStart = false })
    end
    local legPts = {}
    for _, s in ipairs({ 1, -1 }) do
        local top = add(add(crown, V(0, 1.45 * s, 0)), mul(steer, -0.3))
        local bot = add(front, V(0, 1.97 * s, 0.35))
        local pts = bez3(top, add(A(sCrown * 0.45), V(0, 1.75 * s, 0)), add(add(A(3.2), mul(perpF, 0.9)), V(0, 1.95 * s, 0)), bot, 22)
        legPts[s] = pts
        sweep(F, pts, function(t) return 0.5 - 0.17 * t, 0.43 - 0.12 * t end, 16, { up = perpF, capStart = false })
        -- the fork end: a small forged dropout
        local loop = {}
        local function at(u, v) loop[#loop + 1] = { front[1] + u, front[3] + v } end
        at(0.27, -0.75); at(0.27, 0)
        for i = 1, 7 do local a = i / 8 * pi at(cos(a) * 0.27, sin(a) * 0.27) end
        at(-0.27, 0); at(-0.27, -0.75); at(-0.7, -0.5); at(-0.95, 0.3); at(-0.6, 1.0); at(0.2, 1.05); at(0.75, 0.5); at(0.75, -0.5)
        plate(F, loop, V(0, 1.97 * s, 0), X, Z, 0.24)
    end
    sweep(M:bucket("fork", "steel"), { add(front, V(0, -2.4, 0)), add(front, V(0, 2.4, 0)) }, 0.18, 10)
    lathe(M:bucket("fork", "chrome", true), { { 0, 0, true }, { 0.42, 0, true }, { 0.42, 0.35, true }, { 0.2, 0.42, true }, { 0, 0.42, true } },
          add(front, V(0, 2.1, 0)), Y, 14)

    -- CANTILEVER BRAKES: on the fork blades and on the seat stays
    local function legAt(s, rr)
        local best, bd = legPts[s][1], 1e9
        for _, p in ipairs(legPts[s]) do
            local d = abs(len(sub(V(p[1], 0, p[3]), V(front[1], 0, front[3]))) - rr)
            if d < bd then best, bd = p, d end
        end
        return best
    end
    local yokeF = cantilever(M, "fork", front, { [1] = legAt(1, R.rimOut - 0.75), [-1] = legAt(-1, R.rimOut - 0.75) }, R, steer)
    local ssBoss = {}
    for _, s in ipairs({ 1, -1 }) do
        local ss0 = add(ssTop, V(-0.4, 0.55 * s, 0))
        local ss1 = add(rear, V(0.75, (DY - 0.2) * s, 0.95))
        local pts = bez3(ss0, add(lerp(ss0, ss1, 0.3), V(0, 0.9 * s, 0)), add(lerp(ss0, ss1, 0.75), V(0, 0.35 * s, 0)), ss1, 40)
        local best, bd = pts[1], 1e9
        for _, p in ipairs(pts) do
            local d = abs(len(sub(V(p[1], 0, p[3]), V(rear[1], 0, rear[3]))) - (R.rimOut - 0.75))
            if d < bd then best, bd = p, d end
        end
        ssBoss[s] = best
    end
    local ssDir = norm(sub(ssTop, rear))
    local yokeR = cantilever(M, "frame", rear, ssBoss, R, ssDir)

    -- THE DRIVETRAIN. Timing rings (36) on the left of both crank sets, joined by
    -- the timing chain; the stoker's right-hand double (48/34) drives the
    -- cassette through the rear mech.
    local TY, DYc = 1.95, -2.0
    local prT = G.parts.pitchRadius(36)
    chainLoop(M, "frame", { { bb1[1], bb1[3], prT, 1 }, { bb2[1], bb2[3], prT, 1 } }, TY, 0.5)
    -- the drive rings: static on the frame (they are round; the spider that
    -- carries them turns with the cranks)
    local Rg = M:bucket("frame", "alloy")
    local pr48 = sprocket(Rg, 48, bb2[1], DYc, bb2[3], 0.15, G.parts.pitchRadius(48) - 0.62, 5)
    local pr34 = sprocket(Rg, 34, bb2[1], DYc + 0.27, bb2[3], 0.15, G.parts.pitchRadius(34) - 0.55, 5)
    lathe(Rg, { { pr48 - 0.66, DYc - 0.06, true }, { pr48 - 0.62, DYc - 0.06, true }, { pr48 - 0.62, DYc + 0.06, true },
                { pr48 - 0.66, DYc + 0.06, true } }, V(bb2[1], 0, bb2[3]), Y, 48)
    local cogN = 17
    local prC = G.parts.pitchRadius(cogN)
    local cy = cogY[cogN]
    local prJ = G.parts.pitchRadius(11)
    local up1 = { rear[1] + 0.45, rear[3] - prC - 1.35 }
    local lo1 = { up1[1] + 0.85, up1[2] - 2.55 }
    chainLoop(M, "frame", {
        { bb2[1], bb2[3], pr48, 1 }, { rear[1], rear[3], prC, 1 }, { up1[1], up1[2], prJ, -1 }, { lo1[1], lo1[2], prJ, 1 },
    }, (DYc + cy) * 0.5, 0.5)
    -- the rear mech: knuckle on the hanger, parallelogram, cage and jockeys
    do
        local RB = M:bucket("frame", "black")
        local RS = M:bucket("frame", "steel")
        local my = (DYc + cy) * 0.5
        local knuckle = add(hanger, V(-0.2, -0.35, -0.2))
        lathe(RB, { { 0, -0.35, true }, { 0.42, -0.35, true }, { 0.45, -0.25 }, { 0.45, 0.25 }, { 0.42, 0.35, true }, { 0, 0.35, true } }, knuckle, Y, 16)
        local body = V(rear[1] + 0.3, my - 0.75, rear[3] - prC - 0.6)
        sweep(RB, { knuckle, add(lerp(knuckle, body, 0.5), V(-0.35, -0.2, 0)), body },
              function() return 0.42, 0.3 end, 12, { up = Y })
        lathe(RB, { { 0, -0.3, true }, { 0.48, -0.3, true }, { 0.5, -0.2 }, { 0.5, 0.2 }, { 0.48, 0.3, true }, { 0, 0.3, true } }, body, Y, 16)
        for _, sy in ipairs({ -0.26, 0.26 }) do
            local loop = {}
            for i = 0, 8 do local a = pi * 0.5 + i / 8 * pi loop[#loop + 1] = { up1[1] + cos(a) * (prJ + 0.25), up1[2] + sin(a) * (prJ + 0.25) } end
            for i = 0, 8 do local a = -pi * 0.5 + i / 8 * pi loop[#loop + 1] = { lo1[1] + cos(a) * (prJ + 0.3), lo1[2] + sin(a) * (prJ + 0.3) } end
            if sy < 0 then plate(RS, loop, V(0, my + sy, 0), X, Z, 0.06) else plate(RB, loop, V(0, my + sy, 0), X, Z, 0.06) end
        end
        for _, j in ipairs({ up1, lo1 }) do
            sprocket(RB, 11, j[1], my, j[2], 0.2, 0.3, 4)
            lathe(RS, { { 0, -0.3, true }, { 0.16, -0.3, true }, { 0.16, 0.3, true }, { 0, 0.3, true } }, V(j[1], my, j[2]), Y, 8)
        end
    end
    -- the front mech on the stoker's seat tube, its cage over the rings
    do
        local fz = bb2[3] + pr48 + 0.75
        local onT = onST(bb2, sd2, fz + 0.4)
        lathe(Bk, { { 0.62, -0.3, true }, { 0.76, -0.3, true }, { 0.76, 0.3, true }, { 0.62, 0.3, true } }, onT, sd2, 18)
        local cage = {}
        for i = 0, 8 do
            local a = 0.55 + i / 8 * 0.75
            cage[#cage + 1] = { bb2[1] + cos(a) * (pr48 + 0.75), bb2[3] + sin(a) * (pr48 + 0.75) }
        end
        for i = 8, 0, -1 do
            local a = 0.55 + i / 8 * 0.75
            cage[#cage + 1] = { bb2[1] + cos(a) * (pr48 + 0.35), bb2[3] + sin(a) * (pr48 + 0.35) }
        end
        plate(M:bucket("frame", "alloy"), cage, V(0, DYc - 0.32, 0), X, Z, 0.07)
        plate(Bk, cage, V(0, DYc + 0.5, 0), X, Z, 0.07)
        sweep(Bk, { add(onT, V(0.5, -0.4, -0.35)), V(bb2[1] + cos(0.9) * (pr48 + 0.7), DYc - 0.1, bb2[3] + sin(0.9) * (pr48 + 0.7)) },
              function() return 0.22, 0.16 end, 8, { up = Y })
    end

    -- THE CRANKS (built about the captain's bottom bracket, drawn at both):
    -- a 24 mm spindle, five-arm spiders both sides, the timing ring on the left.
    do
        local Ca = M:bucket("cranks", "alloy")
        local Cb = M:bucket("cranks", "black")
        local Cc = M:bucket("cranks", "chrome", true)
        sweep(M:bucket("cranks", "steel"), { add(bb1, V(0, -2.75, 0)), add(bb1, V(0, 2.75, 0)) }, 0.47, 16)
        for _, sd in ipairs({ -1, 1 }) do
            local dir = (sd == -1) and X or mul(X, -1)
            local root = add(bb1, V(0, 2.9 * sd, 0))
            local tip = add(add(bb1, V(0, 3.25 * sd, 0)), mul(dir, CR))
            crankArm(Ca, root, tip, 1.15, 0.75, 0.55, 0.48, 0.9, 0.58)
            capScrew(Cc, add(root, V(0, 0.28 * sd, 0)), mul(Y, sd), 0.45, 0.08)
            -- the spider: five arms from the crank's root to a 130 mm bolt circle
            local ringY = (sd == -1) and DYc + 0.12 or TY - 0.1
            local bcd = 2.56
            for i = 0, 4 do
                local a = (sd == -1 and 0 or pi) + i / 5 * TAU
                local d = V(cos(a), 0, -sin(a))
                local a1 = add(add(bb1, V(0, (2.75 * sd + ringY) * 0.5, 0)), mul(d, 0.7))
                local a2 = add(add(bb1, V(0, ringY - 0.05 * sd, 0)), mul(d, bcd))
                sweep(Ca, { a1, a2 }, function(t) return 0.42 - 0.12 * t, 0.2 end, 10, { up = Y, capStart = false })
                lathe(Ca, { { 0, -0.12, true }, { 0.3, -0.12, true }, { 0.3, 0.12, true }, { 0, 0.12, true } }, a2, Y, 10)
                lathe(Cc, { { 0, 0, true }, { 0.18, 0, true }, { 0.18, 0.1 }, { 0, 0.12, true } }, add(a2, V(0, 0.12 * sd, 0)), mul(Y, sd), 8)
            end
        end
        -- the timing ring, turning with both crank sets
        local prt = sprocket(Ca, 36, bb1[1], TY, bb1[3], 0.15, G.parts.pitchRadius(36) - 0.6, 5)
        lathe(Ca, { { 2.4, TY - 0.06, true }, { prt - 0.55, TY - 0.06, true }, { prt - 0.55, TY + 0.06, true }, { 2.4, TY + 0.06, true } },
              V(bb1[1], 0, bb1[3]), Y, 40)
    end
    G.parts.pedal(M, "pedal")

    -- THE CAPTAIN'S COCKPIT: steerer, spacers, stem, drop bars, hoods, tape
    local Bb = M:bucket("bars", "black")
    local Ba = M:bucket("bars", "alloy")
    local Br = M:bucket("bars", "rubber")
    local stemS = sHT + 0.95
    sweep(Bb, { A(sHT + 0.4), A(stemS) }, 0.6, 18, { capStart = false })
    for i = 0, 1 do
        lathe(Bb, { { 0.58, 0, true }, { 0.75, 0, true }, { 0.75, 0.22, true }, { 0.58, 0.22, true } }, A(sHT + 0.45 + i * 0.25), steer, 20)
    end
    local stemH = 1.7
    lathe(Ba, { { 0, 0, true }, { 0.72, 0, true }, { 0.76, 0.1 }, { 0.76, stemH - 0.1 }, { 0.72, stemH, true }, { 0, stemH, true } },
          A(stemS), steer, 22)
    lathe(Bb, { { 0, 0, true }, { 0.7, 0, true }, { 0.62, 0.14 }, { 0, 0.16, true } }, A(stemS + stemH), steer, 20)
    local stemMid = A(stemS + stemH * 0.5)
    local clampC = add(stemMid, V(3.25, 0, 0.75))
    sweep(Ba, { add(stemMid, V(0.3, 0, 0)), clampC }, function() return 0.52, 0.62 end, 16, { up = Z })
    lathe(Ba, { { 0, -0.95, true }, { 0.68, -0.95, true }, { 0.72, -0.85 }, { 0.72, 0.85 }, { 0.68, 0.95, true }, { 0, 0.95, true } }, clampC, Y, 22)
    for _, sy in ipairs({ -0.62, 0.62 }) do
        for _, sz in ipairs({ -0.38, 0.38 }) do
            lathe(M:bucket("bars", "chrome", true), { { 0, 0, true }, { 0.13, 0, true }, { 0.13, 0.1 }, { 0, 0.11, true } },
                  add(clampC, V(0.72, sy, sz)), X, 6, { flat = true })
        end
    end
    local grips = {}
    do
        local all = {}
        local r, l = dropBar(clampC, -1), dropBar(clampC, 1)
        for i = #r, 2, -1 do all[#all + 1] = r[i] end
        for i = 1, #l do all[#all + 1] = l[i] end
        local path = spline(all, 6)
        sweep(Ba, path, function(t) local e = abs(t * 2 - 1) return (e < 0.12) and 0.5 or 0.43 end, 16)
        -- bar tape from the tops' outer half to the ends
        for _, sd in ipairs({ 1, -1 }) do
            local p = dropBar(clampC, sd)
            local seg = { lerp(p[2], p[3], 0.35) }
            for i = 3, #p do seg[#seg + 1] = p[i] end
            sweep(Br, spline(seg, 6), 0.52, 16)
            -- the hood: a lever body on the bend, and its blade down the drop
            local hb = add(clampC, V(2.15, 8.35 * sd, -0.25))
            local hf = add(clampC, V(4.35, 8.4 * sd, 0.55))
            local hrings = {}
            for i = 0, 10 do
                local t = i / 10
                local cc = add(lerp(hb, hf, t), V(0, 0, 0.35 * sin(t * pi) - 0.15 * t))
                local hw = 0.52 + 0.12 * sin(t * pi) - 0.22 * t * t
                local hh = 0.62 + 0.25 * sin(t * pi * 0.9) - 0.15 * t
                hrings[#hrings + 1] = section(cc, Y, Z, hw, hh, hh * 0.9, 2.6, 16)
            end
            loft(Br, hrings, true)
            local blade = spline({ add(hf, V(-0.35, 0, -0.45)), add(clampC, V(3.75, 8.42 * sd, -1.6)), add(clampC, V(3.5, 8.55 * sd, -3.5)),
                                   add(clampC, V(2.55, 8.6 * sd, -4.5)) }, 5)
            sweep(Ba, blade, function(t) return 0.16, 0.38 - 0.18 * t end, 10, { up = Y })
            grips[sd] = { A = add(clampC, V(1.45, 8.38 * sd, 0.55)), B = add(clampC, V(3.65, 8.42 * sd, 0.8)) }
        end
    end
    -- the bell on the left of the tops
    local bellPivot, bellAxis = G.parts.bell(M, "bars", "bellLever", add(clampC, V(0.02, 2.6, 0)), Y, Z, V(-1, 0, 0))
    -- cable housing from the hoods, looping forward
    local Hs = M:bucket("bars", "plastic", true)
    for _, sd in ipairs({ 1, -1 }) do
        local h0 = add(clampC, V(2.4, 7.95 * sd, -0.35))
        sweep(Hs, spline({ h0, add(clampC, V(1.4, 6.6 * sd, -0.55)), add(clampC, V(0.6, 4.2 * sd, -0.55)), add(clampC, V(-0.3, 1.8 * sd, -0.8)),
                           add(clampC, V(-1.6, 0.6 * sd, -1.6)) }, 5), 0.12, 8)
    end

    -- the front brake's hanger under the stem, and its cable to the yoke
    do
        local hng = add(A(sHT + 0.55), mul(perpF, 0.9))
        lathe(Ch, { { 0, 0, true }, { 0.2, 0, true }, { 0.2, 0.5, true }, { 0, 0.5, true } }, hng, steer, 10)
        sweep(M:bucket("fork", "steel", true), { hng, yokeF }, 0.04, 6)
        sweep(M:bucket("fork", "plastic", true), spline({ add(hng, mul(steer, 0.5)), add(hng, add(mul(steer, 2.0), mul(perpF, 1.2))),
              add(clampC, V(-1.0, 0.9, -1.2)), add(clampC, V(-1.6, 0.6, -1.6)) }, 5), 0.12, 8)
    end
    -- the rear brake's cable: along the top tubes to a hanger at the stoker's seat lug
    do
        local Hf = M:bucket("frame", "plastic", true)
        local function above(p, d) return add(p, V(0, -0.35, d or 0.7)) end
        local ttd = norm(sub(tt1, ttHead))
        local path = spline({ add(headT, add(mul(perpF, -0.6), V(0, -0.5, 0.4))), above(add(ttHead, mul(ttd, 1.5)), 0.84),
                              above(add(ttHead, mul(ttd, 9)), 0.8), above(lerp(mid0, mid1, 0.2), 0.78), above(lerp(mid0, mid1, 0.85), 0.76),
                              add(lug2, V(-0.9, -0.5, 0.2)) }, 6)
        sweep(Hf, path, 0.12, 8)
        local hng = add(ssTop, V(-1.9, 0, -0.9))
        lathe(Cd, { { 0, 0, true }, { 0.2, 0, true }, { 0.2, 0.45, true }, { 0, 0.45, true } }, hng, ssDir, 10)
        sweep(M:bucket("frame", "steel", true), { add(lug2, V(-0.9, -0.5, 0.2)), hng, yokeR }, 0.04, 6)
        for _, t in ipairs({ 0.25, 0.7 }) do
            box(Pd, above(add(ttHead, mul(ttd, t * len(sub(tt1, ttHead)))), 0.5), mul(ttd, 0.32), V(0, 0.18, 0), V(0, 0, 0.12))
        end
    end

    -- THE STOKER'S BARS: a stem clamped round the captain's seat post, a
    -- swept-back bar and grips just behind the captain's saddle.
    local stokerGrips = {}
    do
        local post = posts[1]
        local pc = onST(post.bb, post.d, top1[3] - 3.0)
        local Sbk = M:bucket("frame", "black")
        lathe(Sbk, { { 0.52, -0.6, true }, { 0.68, -0.6, true }, { 0.72, -0.5 }, { 0.72, 0.5 }, { 0.68, 0.6, true }, { 0.52, 0.6, true } }, pc, post.d, 20)
        box(Sbk, add(pc, V(0.85, 0, 0)), V(0.25, 0, 0), V(0, 0.32, 0), V(0, 0, 0.45))
        bolt(Cd, add(pc, V(0.9, 0.32, 0.2)), Y, 0.14, 0.12)
        bolt(Cd, add(pc, V(0.9, 0.32, -0.2)), Y, 0.14, 0.12)
        local sc = add(pc, V(-4.0, 0, 0.35))
        sweep(Sbk, { add(pc, V(-0.6, 0, 0.05)), sc }, function() return 0.48, 0.55 end, 14, { up = Z })
        lathe(Sbk, { { 0, -0.85, true }, { 0.6, -0.85, true }, { 0.64, -0.75 }, { 0.64, 0.75 }, { 0.6, 0.85, true }, { 0, 0.85, true } }, sc, Y, 20)
        local function side(sd)
            return { sc, add(sc, V(0, 1.4 * sd, 0)), add(sc, V(-0.15, 3.8 * sd, 0.25)), add(sc, V(-0.6, 6.0 * sd, 0.45)),
                     add(sc, V(-1.1, 9.4 * sd, 0.5)) }
        end
        local all = {}
        local r, l = side(-1), side(1)
        for i = #r, 2, -1 do all[#all + 1] = r[i] end
        for i = 1, #l do all[#all + 1] = l[i] end
        sweep(Sbk, spline(all, 6), 0.42, 14)
        local Rbr = M:bucket("frame", "rubber")
        for _, sd in ipairs({ 1, -1 }) do
            local p = side(sd)
            local g0 = lerp(p[4], p[5], 0.15)
            local dir = norm(sub(p[5], p[4]))
            local prof = { { 0.42, 0, true }, { 0.66, 0, true }, { 0.68, 0.12 }, { 0.6, 0.25, true } }
            local h = 0.3
            while h < 3.05 do
                prof[#prof + 1] = { 0.6, h }
                prof[#prof + 1] = { 0.64, h + 0.07 }
                prof[#prof + 1] = { 0.6, h + 0.14 }
                h = h + 0.22
            end
            prof[#prof + 1] = { 0.62, 3.25 }
            prof[#prof + 1] = { 0.5, 3.4, true }
            prof[#prof + 1] = { 0, 3.42, true }
            lathe(Rbr, prof, g0, dir, 18)
            stokerGrips[sd] = add(g0, mul(dir, 1.7))
        end
    end

    M.layout = {
        k = 1, steer = steer,
        headT = headT, headB = headB,
        rear = rear, front = front,
        bb = bb1, bb2 = bb2, crank = CR, pedalY = PEDALY,
        gripR = grips[-1], gripL = grips[1],
        gripS = { r = stokerGrips[-1], l = stokerGrips[1] },
        stemTop = A(stemS + stemH),
        bellPivot = bellPivot, bellAxis = bellAxis,
        stand = add(bb2, V(-3.2, 1.6, -0.3)),
        seatTop = top1, seatTop2 = top2,
    }
    return M
end

G.RegisterKind("tandem", function(opt) return tidy(buildTandem(opt)) end)
