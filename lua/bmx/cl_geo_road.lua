--[[--------------------------------------------------------------------------
    bmx/cl_geo_road.lua

    The models of the road bike and the fixie, built in code (docs/MODELS.md).
    Kinds: road, fixie.

    ROAD: a modern 700c endurance road bike. 700 x 25 slicks on black alloy
    rims (24 radial front, 28 two-cross rear), a welded alloy diamond frame
    with a sloping top tube, an oversized down tube, a tapered head tube and
    dropped skinny seat stays; a tapered-blade fork; a threadless stem on a
    spacer stack; drop bars with hoods, brake/shift levers and bar tape; dual-
    pivot calipers; a 50/34 chainset on a four-arm spider; front and rear
    derailleurs; an 11-speed cassette; the chain from the big ring over the
    17 and through the jockey wheels; a slim saddle on a seatpost; clipless
    pedals; a bottle in a cage; quick-release skewers; the bell.

    FIXIE: a fixed-gear track bike. Horizontal top tube, fastback seat stays,
    rear-facing track ends, a straight fork with a flat crown, deep-V rims on
    high-flange hubs (32 spokes), skinwall 700 x 25s, a 46t ring on a five-arm
    crank, a 17t fixed cog and its lockring, no brakes, bullhorn bars with tape
    on a tall quill stem, track pedals with toe clips and straps, the bell.

    THE RIDER'S PLACES ARE FIXED (the pose is tuned to them): the saddle's top
    at seat + (-0.5, 0, 2), the bottom bracket at (-4.5k, 0, 2.5k), 6.8 cranks,
    the hands near the BMX's grips scaled by k. A rider that size sits upright
    on small wheels, so both frames are tall in front and their heads a little
    slacker than a racer's: the head angle is SOLVED so the steer axis passes
    through the stem and the fork has its offset (geom below).

    Built in REAL units (the registry's wheelbase and radius), x forward, y
    left, z up, origin midway between the axles. Pure Lua, no game calls.
----------------------------------------------------------------------------]]

BMX = BMX or {}
local G = BMX.BikeGeo
if not G then return end

local Pm, Vm = G.prim, G.vec
local sweep, lathe, plate, ringPlate, box = Pm.sweep, Pm.lathe, Pm.plate, Pm.ringPlate, Pm.box
local roundRect, circle, bez3, spline, grid, cap, bead = Pm.roundRect, Pm.circle, Pm.bez3, Pm.spline, Pm.grid, Pm.cap, Pm.bead
local quad = Pm.quad
local V, add, sub, mul, dot, cross, len, norm, lerp = Vm.V, Vm.add, Vm.sub, Vm.mul, Vm.dot, Vm.cross, Vm.len, Vm.norm, Vm.lerp
local perp = Vm.perp
local sqrt, sin, cos, pi, abs = math.sqrt, math.sin, math.cos, math.pi, math.abs
local max, min, floor, atan2, acos = math.max, math.min, math.floor, math.atan2, math.acos
local TAU = pi * 2
local Y = V(0, 1, 0)
local Z = V(0, 0, 1)

local PITCH = 0.52                      -- chain pitch (1/2" at the wheels' scale)
local function pitchR(n) return PITCH / (2 * sin(pi / n)) end

--------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------
local function smooth01(t) t = max(0, min(1, t)) return t * t * (3 - 2 * t) end

-- A path evenly resampled every `step` along its length.
local function resample(pts, step)
    local out = { pts[1] }
    local carry = 0
    for i = 2, #pts do
        local a, b = pts[i - 1], pts[i]
        local seg = len(sub(b, a))
        if seg > 1e-9 then
            local pos = step - carry
            while pos <= seg do
                out[#out + 1] = lerp(a, b, pos / seg)
                pos = pos + step
            end
            carry = seg - (pos - step)
        end
    end
    if len(sub(out[#out], pts[#pts])) > step * 0.35 then out[#out + 1] = pts[#pts] else out[#out] = pts[#pts] end
    return out
end

local function pathLen(pts)
    local l = 0
    for i = 2, #pts do l = l + len(sub(pts[i], pts[i - 1])) end
    return l
end

-- Tangents and a twist-free normal along a path (as the sweep carries them).
local function frameAlong(pts, up)
    local n = #pts
    local T, N = {}, {}
    for i = 1, n do T[i] = norm(sub(pts[min(n, i + 1)], pts[max(1, i - 1)])) end
    N[1] = perp(T[1], up)
    for i = 2, n do
        local q = sub(N[i - 1], mul(T[i], dot(N[i - 1], T[i])))
        N[i] = len(q) > 1e-6 and norm(q) or perp(T[i], up)
    end
    return T, N
end

-- Bar tape: a tube whose radius steps up along a helix, each wrap overlapping
-- the last, so it reads as a wound strip and not a hose.
local function tapeTube(B, pts, r0, ridge, pitch, sides)
    local T, N = frameAlong(pts, Z)
    local L = { 0 }
    for i = 2, #pts do L[i] = L[i - 1] + len(sub(pts[i], pts[i - 1])) end
    local P = {}
    for i = 1, #pts do
        local bn = cross(T[i], N[i])
        P[i] = {}
        for j = 1, sides do
            local a = (j - 1) / sides * TAU
            local f = (L[i] / pitch + (j - 1) / sides) % 1
            local r = r0 + ridge * (f < 0.82 and f / 0.82 or (1 - f) / 0.18)
            P[i][j] = add(pts[i], add(mul(N[i], cos(a) * r), mul(bn, sin(a) * r)))
        end
    end
    grid(B, P, true, function(i) return pts[i] end)
end

-- A lofted body along x through stations { x, zc, halfW, halfH } (in a local
-- frame o + ex*x + ey*y + ez*z), superelliptic sections. Hoods, saddles.
local function loft(B, o, ex, ey, ez, st, ring, ex2, capEnds)
    local P = {}
    local C = {}
    for i, s in ipairs(st) do
        P[i] = {}
        local c = add(o, add(mul(ex, s[1]), add(mul(ey, s[5] or 0), mul(ez, s[2]))))
        C[i] = c
        for j = 0, ring - 1 do
            local a = j / ring * TAU
            local ca, sa = cos(a), sin(a)
            local e = ex2 or 2.6
            local cy = (abs(ca) ^ (2 / e)) * (ca < 0 and -1 or 1)
            local cz = (abs(sa) ^ (2 / e)) * (sa < 0 and -1 or 1)
            P[i][j + 1] = add(c, add(mul(ey, cy * s[3]), mul(ez, cz * s[4])))
        end
    end
    grid(B, P, true, function(i) return C[i] end)
    if capEnds ~= false then
        cap(B, P[1], mul(ex, -1))
        cap(B, P[#P], ex)
    end
end

-- Chain or belt routing. Circles { x, z, r, o, y } in loop order, o = 1 for a
-- counter-clockwise wrap seen from +y... (x right, z up), -1 clockwise. Returns
-- the closed path (3D, y from each circle; the straight runs blend between).
local function belt(C, step)
    local m = #C
    local outP, inP = {}, {}
    for i = 1, m do
        local a, b = C[i], C[i % m + 1]
        local ra, rb = a.o * a.r, b.o * b.r
        local Dx, Dz = b.x - a.x, b.z - a.z
        local D2 = Dx * Dx + Dz * Dz
        local dl = rb - ra
        local Lt = sqrt(max(D2 - dl * dl, 1e-9))
        local dx = (Lt * Dx + dl * Dz) / D2
        local dz = (Lt * Dz - dl * Dx) / D2
        local nx, nz = -dz, dx
        outP[i] = { a.x - ra * nx, a.z - ra * nz }
        inP[i % m + 1] = { b.x - rb * nx, b.z - rb * nz }
    end
    local pts = {}
    for i = 1, m do
        local c = C[i]
        local a0 = atan2(inP[i][2] - c.z, inP[i][1] - c.x)
        local a1 = atan2(outP[i][2] - c.z, outP[i][1] - c.x)
        local d = a1 - a0
        if c.o > 0 then while d < 0 do d = d + TAU end else while d > 0 do d = d - TAU end end
        local n = max(2, floor(abs(d) * c.r / step + 0.5))
        for s = 0, n do
            local a = a0 + d * s / n
            pts[#pts + 1] = V(c.x + cos(a) * c.r, c.y, c.z + sin(a) * c.r)
        end
    end
    pts[#pts + 1] = V(pts[1][1], pts[1][2], pts[1][3])
    return pts
end

-- A roller chain along a closed path: waisted inner and outer plates and a
-- roller at every pin, as the BMX's.
local function chainLinks(B, path, scale)
    local cum = { 0 }
    for i = 2, #path do cum[i] = cum[i - 1] + len(sub(path[i], path[i - 1])) end
    local total = cum[#cum]
    local nl = floor(total / PITCH / 2 + 0.5) * 2
    local p = total / nl
    local seg = 2
    local function at(s)
        while seg < #cum and cum[seg] < s do seg = seg + 1 end
        local t = (s - cum[seg - 1]) / max(cum[seg] - cum[seg - 1], 1e-9)
        return lerp(path[seg - 1], path[seg], t)
    end
    local pins = {}
    for i = 0, nl - 1 do pins[i] = at(i * p) end
    local sc = scale or 1
    local ro, rw = 0.16 * sc, 0.12 * sc
    for i = 0, nl - 1 do
        local a, b = pins[i], pins[(i + 1) % nl]
        local d = sub(b, a)
        local l = len(d)
        local eu = mul(d, 1 / l)
        local w = norm(sub(Y, mul(eu, dot(Y, eu))))
        local ev = cross(w, eu)
        local off = ((i % 2 == 0) and 0.2 or 0.13) * sc
        local lp = {}
        for j = 0, 4 do local t = -pi / 2 + j / 4 * pi lp[#lp + 1] = { l + cos(t) * ro, sin(t) * ro } end
        lp[#lp + 1] = { 0.5 * l, rw }
        for j = 0, 4 do local t = pi / 2 + j / 4 * pi lp[#lp + 1] = { cos(t) * ro, sin(t) * ro } end
        lp[#lp + 1] = { 0.5 * l, -rw }
        for _, s in ipairs({ 1, -1 }) do
            plate(B, lp, add(a, mul(w, off * s)), eu, ev, 0.05 * sc)
        end
        sweep(B, { sub(a, mul(w, 0.12 * sc)), add(a, mul(w, 0.12 * sc)) }, 0.11 * sc, 6, { capStart = false, capEnd = false })
    end
end

-- A toothed sprocket in the x/z plane at y, `m` outline points a tooth.
local function sprocket(B, n, cx, cz, y, t, innerR, m)
    local outer = G.parts.toothLoop(n, pitchR(n), m or 6)
    local inner = {}
    for i = 1, #outer do
        local a = (i - 1) / #outer * TAU
        inner[i] = { cx + cos(a) * innerR, cz + sin(a) * innerR }
        outer[i] = { outer[i][1] + cx, outer[i][2] + cz }
    end
    ringPlate(B, outer, inner, V(0, y, 0), V(1, 0, 0), V(0, 0, 1), t)
end

-- A hex bolt head / nut on an axis.
local function hexHead(B, p, axis, r, h)
    lathe(B, { { 0, 0, true }, { r, 0, true }, { r, h * 0.8 }, { r * 0.7, h, true }, { 0, h, true } }, p, axis, 6, { flat = true })
end
local function capBolt(B, p, axis, r, h)
    lathe(B, { { 0, 0, true }, { r, 0, true }, { r, h * 0.85 }, { r * 0.85, h, true }, { r * 0.45, h, true }, { r * 0.45, h * 0.6, true }, { 0, h * 0.6, true } }, p, axis, 10)
end

-- The down tube's graphic, as the BMX's (role "decal", u along the tube).
local function decalTube(M, a, b, rad, t0, t1)
    local D = M:bucket("frame", "decal")
    local dir = norm(sub(b, a))
    local up = norm(sub(Z, mul(dir, dir[3])))
    local ni, nj, arc = 24, 10, 0.95
    for _, s in ipairs({ 1, -1 }) do
        local side = V(0, s, 0)
        local P, N, U = {}, {}, {}
        for i = 0, ni do
            local t = t0 + (t1 - t0) * i / ni
            local c = lerp(a, b, t)
            local r = type(rad) == "function" and rad(t) or rad
            P[i], N[i], U[i] = {}, {}, {}
            for j = 0, nj do
                local ang = (j / nj * 2 - 1) * arc
                local n = add(mul(side, cos(ang)), mul(up, sin(ang)))
                P[i][j] = add(c, mul(n, r + 0.012))
                N[i][j] = n
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
-- GEOMETRY: every hard point, from the registry's numbers and the design D.
--------------------------------------------------------------------------
local function geom(opt, D)
    local L = {}
    local wb = opt.wheelbase or D.wb
    local k = opt.k or wb / 39
    L.k, L.R = k, opt.radius or 13.8
    L.rear, L.front = V(-wb / 2, 0, 0), V(wb / 2, 0, 0)
    L.bb = V(-4.5 * k, 0, 2.5 * k)
    local seat = opt.seat or D.seat
    L.seat = V(seat[1], 0, seat[3])
    L.saddleTop = V(seat[1] - 0.5, 0, seat[3] + 2.0)
    L.gripRef = V(10.5 * k, 0, 26 * k)
    -- the cockpit: the bar clamp from where the hands go, the stem back to the steerer
    L.clamp = add(L.gripRef, V(D.clampDx, 0, D.clampDz))
    local sa = math.rad(D.stemAngle)
    L.stemDir = V(cos(sa), 0, sin(sa))
    L.S = sub(L.clamp, mul(L.stemDir, D.stemL))
    -- the head angle that puts the steer axis through the stem with the fork's offset
    local dx, dz = L.front[1] - L.S[1], L.front[3] - L.S[3]
    local R0 = sqrt(dx * dx + dz * dz)
    local th = atan2(dz, dx) + acos(D.offset / R0)
    L.s = V(-sin(th), 0, cos(th))         -- up the steer axis
    L.n = V(cos(th), 0, sin(th))          -- forward, square to it
    L.headAngle = 90 - math.deg(th)
    local foot = sub(L.front, mul(L.n, D.offset))
    L.crown = add(foot, mul(L.s, sqrt(D.forkL * D.forkL - D.offset * D.offset)))
    L.htB = add(L.crown, mul(L.s, D.crownGap))
    if D.htLen then
        L.htT = add(L.htB, mul(L.s, D.htLen))
    else
        L.htT = sub(L.S, mul(L.s, D.stack))
    end
    -- seat tube from the bottom bracket
    local sta = math.rad(D.seatAngle)
    L.sd = V(-cos(sta), 0, sin(sta))
    local function onST(z) return add(L.bb, mul(L.sd, (z - L.bb[3]) / L.sd[3])) end
    L.onST = onST
    L.ttHead = sub(L.htT, mul(L.s, D.ttDrop))
    L.seatJ = onST(D.seatJz or L.ttHead[3])
    L.stTop = add(L.seatJ, mul(L.sd, D.stExt))
    L.dtHead = add(L.htB, mul(L.s, D.dtUp))
    return L
end

--------------------------------------------------------------------------
-- FRAME (paint): head tube, bottom bracket, main tubes, stays, dropouts
--------------------------------------------------------------------------
local function buildFrame(M, L, D)
    local P = M:bucket("frame", "paint")
    local Pd = M:bucket("frame", "paint", true)
    local Ch = M:bucket("frame", "chrome")
    local bb = L.bb

    -- head tube (tapered on the road bike, with the bearing covers' flares)
    do
        local h1 = len(sub(L.htT, L.htB))
        local rb, rt = D.htRb, D.htRt
        local prof = { { 0, -0.02, true }, { rb + 0.03, 0, true }, { rb + 0.07, 0.12 }, { rb + 0.02, 0.45 } }
        for i = 1, 5 do
            local t = i / 6
            prof[#prof + 1] = { rb + (rt - rb) * smooth01(t * 1.2) , 0.45 + (h1 - 0.9) * t }
        end
        prof[#prof + 1] = { rt + 0.02, h1 - 0.45 }
        prof[#prof + 1] = { rt + 0.06, h1 - 0.12 }
        prof[#prof + 1] = { rt + 0.03, h1, true }
        prof[#prof + 1] = { 0, h1 + 0.02, true }
        lathe(P, prof, L.htB, L.s, 32)
    end
    -- bottom bracket shell
    local bh, br = D.bbHalf, D.bbR
    lathe(P, { { 0, -bh, true }, { br - 0.04, -bh, true }, { br, -bh + 0.12 }, { br, bh - 0.12 },
               { br - 0.04, bh, true }, { 0, bh, true } }, bb, Y, 28)

    -- main tubes
    local tt0, tt1 = L.ttHead, L.seatJ
    local ttd = norm(sub(tt1, tt0))
    sweep(P, { tt0, lerp(tt0, tt1, 0.5), tt1 }, D.ttR, 24, { up = Y, capStart = false, capEnd = false })
    local dt0 = L.dtHead
    local dtd = norm(sub(bb, dt0))
    sweep(P, { dt0, lerp(dt0, bb, 0.5), bb }, D.dtR, 26, { up = Y, capStart = false, capEnd = false })
    local stR = D.stR
    sweep(P, { bb, L.stTop }, stR, 24, { capStart = false })
    -- seat clamp collar and its bolt
    local back = norm(cross(Y, L.sd))
    if back[1] > 0 then back = mul(back, -1) end
    local Bk = M:bucket("frame", D.collarRole or "black")
    lathe(Bk, { { stR - 0.02, -0.5, true }, { stR + 0.08, -0.46 }, { stR + 0.1, 0 }, { stR + 0.08, 0.46 },
                { stR - 0.02, 0.5, true }, { stR - 0.14, 0.5, true } }, add(L.stTop, mul(L.sd, -0.05)), L.sd, 24)
    box(Bk, add(add(L.stTop, mul(L.sd, -0.05)), mul(back, stR + 0.2)), mul(back, 0.2), V(0, 0.32, 0), mul(L.sd, 0.36))
    capBolt(M:bucket("frame", "chrome", true), add(add(L.stTop, mul(L.sd, -0.05)), add(mul(back, stR + 0.25), V(0, 0.32, 0))), Y, 0.15, 0.18)

    -- joints: weld beads (alloy) or lug sleeves (steel)
    if D.lugs then
        local Lg = M:bucket("frame", D.lugRole or "chrome")
        local function sleeve(c, dir, r, l)
            lathe(Lg, { { r - 0.05, -0.02, true }, { r + 0.06, 0.05 }, { r + 0.07, l * 0.5 }, { r + 0.02, l, true }, { r - 0.05, l, true } }, c, dir, 24)
        end
        local h1 = len(sub(L.htT, L.htB))
        sleeve(add(L.htT, mul(L.s, 0.0)), mul(L.s, -1), D.htRt + 0.01, 1.6)
        sleeve(L.htB, L.s, D.htRb + 0.01, 1.5)
        sleeve(add(tt0, mul(ttd, D.htRt * 0.95)), ttd, D.ttR, 1.1)
        sleeve(add(dt0, mul(dtd, D.htRb * 0.95)), dtd, D.dtR, 1.2)
        sleeve(add(tt1, mul(ttd, -stR * 0.95)), mul(ttd, -1), D.ttR, 1.0)
        sleeve(add(L.seatJ, mul(L.sd, -0.9)), L.sd, stR, 1.6)
        sleeve(add(bb, mul(dtd, -(br + 0.1))), mul(dtd, -1), D.dtR, 1.0)
        sleeve(add(bb, mul(L.sd, br * 0.9)), L.sd, stR, 1.0)
        local _ = h1
    else
        bead(Pd, add(tt0, mul(ttd, D.htRt * 1.02)), ttd, D.ttRmax, 0.09)
        bead(Pd, add(dt0, mul(dtd, D.htRb * 1.0)), dtd, D.dtRmax, 0.1)
        bead(Pd, add(tt1, mul(ttd, -stR * 1.05)), ttd, D.ttRmax * 0.95, 0.08)
        bead(Pd, add(bb, mul(L.sd, br * 1.02)), L.sd, stR * 1.02, 0.08)
        bead(Pd, add(bb, mul(dtd, -br * 1.02)), dtd, D.dtRmax, 0.09)
    end

    -- chain stays and seat stays to the dropouts
    local dy = D.dropY
    local cs, ss = {}, {}
    for _, s in ipairs({ 1, -1 }) do
        local cs0 = add(bb, V(-0.55, D.csY0 * s, -0.1))
        local cs1 = add(L.rear, V(D.csEnd[1], (dy - 0.12) * s, D.csEnd[2]))
        local c = bez3(cs0, add(cs0, V(-4.2, 0.05 * s, -0.35)), add(cs1, V(6.5, -0.75 * s, 0.35)), cs1, 18)
        cs[s] = c
        sweep(P, c, function(t) return D.csR[1] - (D.csR[1] - D.csR[2]) * t, D.csR[3] - (D.csR[3] - D.csR[4]) * t end, 16,
            { up = Z, capStart = false })
        local ss0 = add(L.onST(L.seatJ[3] + D.ssJoin), V(-D.ssBack, D.ssY0 * s, 0))
        local ss1 = add(L.rear, V(D.ssEnd[1], (dy - 0.12) * s, D.ssEnd[2]))
        local c2 = bez3(ss0, add(lerp(ss0, ss1, 0.3), V(0, 0.45 * s, 0)), add(lerp(ss0, ss1, 0.72), V(0, 0.12 * s, 0)), ss1, 18)
        ss[s] = c2
        sweep(P, c2, function(t) return D.ssR[1] - (D.ssR[1] - D.ssR[2]) * t, D.ssR[3] - (D.ssR[3] - D.ssR[4]) * t end, 14,
            { up = Y, capStart = false })
        -- dropout plate
        plate(P, D.dropLoop(L), V(0, dy * s, 0), V(1, 0, 0), V(0, 0, 1), 0.24, { smooth = false })
    end
    -- fastback: the stays meet in a cap behind the seat cluster
    if D.fastback then
        local a, b = ss[1][1], ss[-1][1]
        sweep(P, { a, lerp(a, b, 0.5), b }, D.ssR[1] * 1.02, 14)
    end
    L.ss, L.cs = ss, cs
    -- a bridge between the chain stays behind the bottom bracket
    do
        local i = 5
        sweep(P, { cs[1][i], cs[-1][i] }, 0.22, 10, { capStart = false, capEnd = false })
    end
end

--------------------------------------------------------------------------
-- SADDLE AND SEATPOST (frame group)
--------------------------------------------------------------------------
local function buildSaddle(M, L, D)
    local top = L.saddleTop
    local Ls, wMax, wNose, tSit = D.saddleL, D.saddleW, D.saddleNose, D.saddleSit
    local SB = M:bucket("frame", "seat")
    local function width(t)
        local w
        if t < 0.12 then w = wMax * (0.62 + 0.38 * sqrt(t / 0.12))
        elseif t < 0.32 then w = wMax
        elseif t < 0.78 then w = wMax + (wNose - wMax) * smooth01((t - 0.32) / 0.46)
        else w = wNose end
        if t > 0.94 then w = w * sqrt(max(0.06, (1 - t) / 0.06)) end
        return max(w, 0.06)
    end
    local function ztop(t) return -0.42 * (t - tSit) ^ 2 + (t < 0.08 and 0.05 * (0.08 - t) / 0.08 or 0) end
    local function thick(t)
        local h = 0.78 - 0.4 * smooth01((t - 0.25) / 0.6)
        if t > 0.96 then h = h * max(0.35, (1 - t) / 0.04) end
        if t < 0.02 then h = h * 0.75 end
        return h
    end
    local function X(t) return (t - tSit) * Ls end
    local P = {}
    local ring, stations = 24, 20
    local cen = {}
    for i = 0, stations do
        local t = i / stations
        local w, h, zt = width(t), thick(t), ztop(t)
        local zc = zt - h * 0.55
        local row = {}
        for j = 0, ring - 1 do
            local a = j / ring * TAU
            local ca, sa = cos(a), sin(a)
            local e = 2.8
            local cy = (abs(ca) ^ (2 / e)) * (ca < 0 and -1 or 1)
            local cz = (abs(sa) ^ (2 / e)) * (sa < 0 and -1 or 1)
            local z
            if cz > 0 then z = zc + cz * h * 0.55 * (1 - 0.12 * cy * cy) else z = zc + cz * h * 0.45 end
            row[j + 1] = add(top, V(X(t), cy * w, z))
        end
        P[#P + 1] = row
        cen[#cen + 1] = add(top, V(X(t), 0, zc))
    end
    grid(SB, P, true, function(i) return cen[i] end)
    cap(SB, P[1], V(-1, 0, 0))
    cap(SB, P[#P], V(1, 0, 0))

    -- rails
    local St = M:bucket("frame", "steel")
    local zr = -D.railDrop
    for _, s in ipairs({ 1, -1 }) do
        local pts = {
            add(top, V(X(0.92), 0.22 * s, ztop(0.92) - thick(0.92) * 0.8)),
            add(top, V(X(0.8), 0.55 * s, zr + 0.25)),
            add(top, V(X(0.66), 0.78 * s, zr)),
            add(top, V(X(0.24), 0.78 * s, zr)),
            add(top, V(X(0.12), 1.2 * s, zr + 0.3)),
            add(top, V(X(0.07), 1.45 * s, ztop(0.07) - thick(0.07) * 0.9)),
        }
        sweep(St, spline(pts, 5), 0.09, 8)
    end
    -- the seatpost on the seat tube's line, its head clamping the rails
    local zc = top[3] + zr
    local head = L.onST(zc - 0.35)
    local post0 = add(L.stTop, mul(L.sd, -1.0))
    local Pr = M:bucket("frame", D.postRole or "black")
    sweep(Pr, { post0, head }, D.postR, 20, { capStart = false })
    local Bk = M:bucket("frame", D.postRole or "black")
    -- cradle
    lathe(Bk, { { 0, -0.95, true }, { 0.28, -0.95, true }, { 0.3, -0.85 }, { 0.3, 0.85 }, { 0.28, 0.95, true }, { 0, 0.95, true } },
          V(head[1], 0, zc - 0.12), Y, 14)
    box(Bk, V(head[1], 0, zc - 0.32), V(0.75, 0, 0), V(0, 0.45, 0), V(0, 0, 0.16))
    box(Bk, V(head[1], 0, zc + 0.08), V(0.65, 0, 0), V(0, 0.95, 0), V(0, 0, 0.08))
    for _, xo in ipairs({ -0.5, 0.5 }) do
        capBolt(M:bucket("frame", "chrome", true), V(head[1] + xo, 0, zc - 0.48), V(0, 0, -1), 0.13, 0.15)
    end
    -- minimum-insertion marks
    lathe(M:bucket("frame", "white", true), { { D.postR + 0.006, 0 }, { D.postR + 0.006, 0.08 } }, add(L.stTop, mul(L.sd, 1.3)), L.sd, 20)
end

--------------------------------------------------------------------------
-- WHEELS
--------------------------------------------------------------------------
-- A deep-V: squeeze the box section the shared wheel builds into a V below
-- the braking track (positions and normals, exactly: n' = J^-T n).
local function deepV(M, group, role, R, tip)
    local rTop = R.rimOut - 0.8
    local rBot = R.rimIn - 0.1
    local function f(r)
        if r >= rTop then return 1, 0 end
        local u = (r - rBot) / (rTop - rBot)
        return tip + (1 - tip) * u, (1 - tip) / (rTop - rBot)
    end
    for _, b in ipairs(M.groups[group]) do
        if b.mat == role and not b.detail then
            for _, vt in ipairs(b.v) do
                local p = vt.p
                local r = sqrt(p[1] * p[1] + p[3] * p[3])
                if r > rBot and r < rTop + 1e-6 and r > 2.5 then
                    local fr, df = f(r)
                    local ux, uz = p[1] / r, p[3] / r
                    local nr = vt.n[1] * ux + vt.n[3] * uz
                    local ny = vt.n[2]
                    local y = p[2]
                    vt.p = { p[1], y * fr, p[3] }
                    local n2r, n2y = nr * fr - ny * y * df, ny
                    local l = sqrt(n2r * n2r + n2y * n2y)
                    if l > 1e-9 then vt.n = { ux * n2r / l, n2y / l, uz * n2r / l } end
                end
            end
        end
    end
end

local function buildWheels(M, L, D)
    local R = G.WheelDims(L.R, { width = D.tyreW, height = D.tyreH, rimDepth = D.rimDepth, rimW = D.rimW, flangeR = D.flangeR })
    G.parts.wheel(M, "wheelF", R, { tread = "slick", wall = D.wall, rim = D.rimRole, spokes = D.spokesF, cross = D.crossF,
        hubHalf = D.hubF, spokeR = 0.04 })
    G.parts.wheel(M, "wheelR", R, { tread = "slick", wall = D.wall, rim = D.rimRole, spokes = D.spokesR, cross = D.crossR,
        hubHalf = D.hubR, rear = true, cog = false, spokeR = 0.04 })
    if D.deepV then
        deepV(M, "wheelF", D.rimRole, R, D.deepV)
        deepV(M, "wheelR", D.rimRole, R, D.deepV)
    end
    -- axle ends and spacers out to the dropouts (they spin; nobody can tell)
    local Al = M:bucket("wheelF", "alloy")
    for _, s in ipairs({ 1, -1 }) do
        lathe(Al, { { 0.2, D.hubF - 0.02, true }, { 0.5, D.hubF - 0.02, true }, { 0.5, D.dropF - 0.12 }, { 0.42, D.dropF - 0.12, true }, { 0.2, D.dropF - 0.12, true } },
              V(0, 0, 0), mul(Y, s), 18)
    end
    local AlR = M:bucket("wheelR", "alloy")
    lathe(AlR, { { 0.2, D.hubR - 0.02, true }, { 0.5, D.hubR - 0.02, true }, { 0.5, D.dropY - 0.12 }, { 0.42, D.dropY - 0.12, true }, { 0.2, D.dropY - 0.12, true } },
          V(0, 0, 0), Y, 18)
    return R
end

-- The 11-speed cassette on its freehub, in wheelR.
local CASSETTE = { 11, 12, 13, 14, 15, 17, 19, 21, 23, 25, 28 }
local function cogY(i) return -2.45 + (i - 1) * 0.13 end
local function buildCassette(M, D)
    local St = M:bucket("wheelR", "steel")
    local Al = M:bucket("wheelR", "alloy")
    local Bk = M:bucket("wheelR", "black")
    -- freehub body
    lathe(Bk, { { 0.2, -(D.hubR - 0.05), true }, { 0.66, -(D.hubR - 0.05), true }, { 0.66, -(D.dropY - 0.15) },
                { 0.4, -(D.dropY - 0.13), true }, { 0.2, -(D.dropY - 0.13), true } }, V(0, 0, 0), mul(Y, -1), 24)
    for i, n in ipairs(CASSETTE) do
        local y = cogY(i)
        local pr = pitchR(n)
        local role = (n >= 21) and Al or St
        if n >= 21 then
            -- the big cogs ride on a spider: a ring of teeth and five arms
            sprocket(role, n, 0, 0, y, 0.075, pr - 0.42, 5)
            ringPlate(Bk, circle(pr - 0.38, 40), circle(0.72, 40), V(0, y - 0.0, 0), V(1, 0, 0), V(0, 0, 1), 0.04)
        else
            sprocket(role, n, 0, 0, y, 0.075, 0.7, 5)
        end
    end
    -- lockring with its splines
    lathe(St, { { 0.35, 0, true }, { 0.82, 0, true }, { 0.85, 0.04 }, { 0.85, 0.12 }, { 0.75, 0.16, true }, { 0.35, 0.16, true } },
          V(0, cogY(1) - 0.05, 0), mul(Y, -1), 12, { flat = true })
end

-- The fixie's rear: threads, a 17t fixed cog, the left-hand lockring.
local function buildFixedCog(M, D)
    local St = M:bucket("wheelR", "steel")
    local Ch = M:bucket("wheelR", "chrome")
    local y = D.chainY
    lathe(M:bucket("wheelR", "alloy"), { { 0.2, D.hubR - 0.05, true }, { 0.62, D.hubR - 0.05, true }, { 0.62, D.dropY - 0.14 },
                { 0.45, D.dropY - 0.12, true }, { 0.2, D.dropY - 0.12, true } }, V(0, 0, 0), mul(Y, -1), 22)
    sprocket(St, D.cogT, 0, 0, y, 0.13, 0.62, 6)
    lathe(St, { { 0.6, -0.12, true }, { 0.85, -0.12, true }, { 0.85, 0.12, true }, { 0.6, 0.12, true } }, V(0, y, 0), Y, 24)
    -- lockring: notched outside
    local outer, inner = {}, {}
    for i = 0, 47 do
        local a = i / 48 * TAU
        local notch = (i % 8 == 0) and 0.12 or 0
        outer[#outer + 1] = { cos(a) * (0.98 - notch), sin(a) * (0.98 - notch) }
        inner[#inner + 1] = { cos(a) * 0.6, sin(a) * 0.6 }
    end
    ringPlate(Ch, outer, inner, V(0, y - 0.24, 0), V(1, 0, 0), V(0, 0, 1), 0.14)
end

--------------------------------------------------------------------------
-- FORKS
--------------------------------------------------------------------------
local function forkDropout(B, axle, y, t)
    local loop = {}
    local function at(u, v) loop[#loop + 1] = { axle[1] + u, axle[3] + v } end
    at(0.22, -0.75); at(0.22, 0)
    for i = 1, 7 do local a = i / 8 * pi at(cos(a) * 0.22, sin(a) * 0.22) end
    at(-0.22, 0); at(-0.22, -0.75)
    at(-0.55, -0.6); at(-0.75, 0.15); at(-0.6, 0.85); at(-0.1, 1.15); at(0.45, 0.9); at(0.7, 0.2); at(0.55, -0.6)
    plate(B, loop, V(0, y, 0), V(1, 0, 0), V(0, 0, 1), t)
end

local function buildFork(M, L, D)
    local P = M:bucket("fork", D.forkRole or "paint")
    local axle = L.front
    local s, n = L.s, L.n
    -- crown
    local crown = L.crown
    if D.flatCrown then
        -- a classic flat-top track crown, chromed, with sloping shoulders
        local Ch = M:bucket("fork", "chrome")
        local loop = {}
        local hw = 1.75
        loop = { { -hw, -0.3 }, { hw, -0.3 }, { hw + 0.08, 0.05 }, { hw - 0.25, 0.42 }, { 0.75, 0.55 }, { -0.75, 0.55 }, { -hw + 0.25, 0.42 }, { -hw - 0.08, 0.05 } }
        plate(Ch, loop, add(crown, mul(s, 0.05)), Y, s, 1.05, { smooth = true })
        lathe(Ch, { { 0.55, 0, true }, { 0.8, 0, true }, { 0.82, 0.12 }, { 0.62, 0.3, true }, { 0.55, 0.3, true } }, add(crown, mul(s, 0.55)), s, 24)
    else
        -- a carbon crown: deep in the middle, its shoulders rolling down into the blades
        local st = {}
        for i = 0, 16 do
            local t = i / 16
            local yy = (t * 2 - 1) * 1.82
            local e = max(0, (abs(yy) - 1.15) / 0.67)
            st[#st + 1] = { yy, -0.05 - 0.45 * e * e, 0.98 - 0.42 * e ^ 3, 0.6 - 0.32 * e ^ 3, 0.08 }
        end
        loft(P, crown, Y, n, s, st, 22, 2.3)
        -- the crown's flare up into the lower bearing
        lathe(P, { { D.htRb + 0.02, 0, true }, { D.htRb + 0.12, 0.15 }, { D.htRb + 0.05, 0.42 }, { 0.75, 0.6, true }, { 0, 0.62, true } }, crown, s, 28)
    end
    -- blades
    for _, sd in ipairs({ 1, -1 }) do
        local top = add(add(crown, V(0, D.bladeY0 * sd, 0)), mul(s, -0.1))
        local bot = add(add(axle, V(0, D.dropF * sd, 0)), mul(s, 0.55))
        local pts
        if D.straightFork then
            pts = {}
            for i = 0, 14 do pts[#pts + 1] = lerp(top, bot, i / 14) end
        else
            pts = bez3(top, add(top, mul(s, -5.5)), add(add(bot, mul(s, 4.2)), mul(n, -0.9)), bot, 20)
        end
        sweep(P, pts, function(t) return D.bladeR[1] + (D.bladeR[2] - D.bladeR[1]) * t, D.bladeR[3] + (D.bladeR[4] - D.bladeR[3]) * t end, 18,
            { up = n, capStart = false })
        forkDropout(M:bucket("fork", D.forkRole or "paint"), axle, D.dropF * sd + 0.05 * sd, 0.22)
    end
end

--------------------------------------------------------------------------
-- STEERER, SPACERS (fork) AND STEMS (bars)
--------------------------------------------------------------------------
local function buildThreadless(M, L, D)
    local Bk = M:bucket("fork", "black")
    local s = L.s
    -- top bearing cover
    lathe(Bk, { { 0.6, 0, true }, { D.htRt + 0.06, 0, true }, { D.htRt + 0.03, 0.12 }, { 0.72, 0.4, true }, { 0.6, 0.4, true } }, L.htT, s, 28)
    -- spacer stack to the stem
    local top = len(sub(L.S, L.htT)) - D.stemH * 0.5
    local h = 0.4
    while h < top - 0.06 do
        local hh = min(D.spacer, top - h)
        lathe(Bk, { { 0.6, h, true }, { 0.72, h, true }, { 0.75, h + 0.03 }, { 0.75, h + hh - 0.03 }, { 0.72, h + hh, true }, { 0.6, h + hh, true } }, L.htT, s, 24)
        h = h + hh
    end
    -- the stem: steerer clamp, the extension, the bar clamp and its faceplate
    local B = M:bucket("bars", "black")
    local Cd = M:bucket("bars", "chrome", true)
    local hs = D.stemH * 0.5
    lathe(B, { { 0, -hs, true }, { 0.8, -hs, true }, { 0.84, -hs + 0.08 }, { 0.84, hs - 0.08 }, { 0.8, hs, true }, { 0, hs, true } }, L.S, s, 26)
    -- top cap and bolt
    lathe(B, { { 0, 0, true }, { 0.8, 0, true }, { 0.74, 0.12 }, { 0, 0.16, true } }, add(L.S, mul(s, hs)), s, 24)
    capBolt(Cd, add(L.S, mul(s, hs + 0.14)), s, 0.22, 0.1)
    local fwd = L.stemDir
    local c = L.clamp
    local e0 = add(L.S, mul(fwd, 0.55))
    local e1 = sub(c, mul(fwd, 0.55))
    sweep(B, { e0, lerp(e0, e1, 0.5), e1 }, function(t) return 0.64 - 0.1 * t, 0.5 - 0.06 * t end, 20, { up = norm(cross(fwd, Y)) })
    lathe(B, { { 0, -1.0, true }, { 0.7, -1.0, true }, { 0.74, -0.9 }, { 0.74, 0.9 }, { 0.7, 1.0, true }, { 0, 1.0, true } }, c, Y, 26)
    -- faceplate
    local up = norm(cross(Y, fwd))
    if up[3] < 0 then up = mul(up, -1) end
    box(B, add(c, mul(fwd, 0.72)), mul(fwd, 0.1), V(0, 0.95, 0), mul(up, 0.72))
    for _, sy in ipairs({ 1, -1 }) do
        for _, sz in ipairs({ 1, -1 }) do
            capBolt(Cd, add(add(c, mul(fwd, 0.82)), add(V(0, 0.68 * sy, 0), mul(up, 0.5 * sz))), fwd, 0.14, 0.1)
        end
        -- steerer pinch bolts at the back
        capBolt(Cd, add(add(L.S, mul(fwd, -0.82)), add(mul(s, 0.35 * sy), V(0, 0.35, 0))), Y, 0.13, 0.12)
    end
    box(B, add(L.S, mul(fwd, -0.82)), mul(fwd, 0.12), V(0, 0.35, 0), mul(s, hs * 0.9))
end

local function buildQuill(M, L, D)
    -- threaded headset (frame cups, fork locknut) and a tall chromed quill stem
    local s = L.s
    local Ch = M:bucket("frame", "chrome")
    lathe(Ch, { { 0.6, -0.32, true }, { D.htRb + 0.06, -0.32, true }, { D.htRb + 0.08, -0.2 }, { D.htRb + 0.04, 0.05, true }, { 0.6, 0.05, true } }, L.htB, s, 28)
    lathe(Ch, { { 0.6, -0.05, true }, { D.htRt + 0.04, -0.05, true }, { D.htRt + 0.08, 0.2 }, { D.htRt + 0.06, 0.3, true }, { 0.6, 0.3, true } }, L.htT, s, 28)
    local FC = M:bucket("fork", "chrome")
    lathe(FC, { { 0.5, 0.3, true }, { 0.78, 0.3, true }, { 0.78, 0.36, true }, { 0.5, 0.36, true } }, L.htT, s, 24)
    lathe(FC, { { 0.5, 0.36, true }, { 0.82, 0.36, true }, { 0.82, 0.66 }, { 0.7, 0.72, true }, { 0.5, 0.72, true } }, L.htT, s, 6, { flat = true })
    -- the quill
    local B = M:bucket("bars", "chrome")
    local h0 = 0.55
    local h1 = len(sub(L.S, L.htT))
    lathe(B, { { 0, h0, true }, { 0.46, h0, true }, { 0.47, h0 + 0.1 }, { 0.47, h1 - 0.25 }, { 0.5, h1 - 0.1 }, { 0.5, h1 + 0.25 },
               { 0.42, h1 + 0.42 }, { 0.22, h1 + 0.5, true }, { 0, h1 + 0.5, true } }, L.htT, s, 24)
    hexHead(M:bucket("bars", "chrome", true), add(L.S, mul(s, 0.48)), s, 0.2, 0.12)
    -- the extension to the clamp
    local fwd = L.stemDir
    local c = L.clamp
    local e0 = add(L.S, mul(fwd, 0.2))
    local e1 = sub(c, mul(fwd, 0.5))
    sweep(B, { e0, lerp(e0, e1, 0.5), e1 }, function(t) return 0.46 - 0.06 * t, 0.42 - 0.04 * t end, 18, { up = norm(cross(fwd, Y)) })
    lathe(B, { { 0, -0.85, true }, { 0.6, -0.85, true }, { 0.64, -0.75 }, { 0.64, 0.75 }, { 0.6, 0.85, true }, { 0, 0.85, true } }, c, Y, 24)
    -- pinch bolt under the clamp
    local dn = norm(cross(fwd, Y))
    if dn[3] > 0 then dn = mul(dn, -1) end
    box(B, add(c, mul(dn, 0.7)), mul(fwd, 0.22), V(0, 0.3, 0), mul(dn, 0.2))
    capBolt(M:bucket("bars", "chrome", true), add(add(c, mul(dn, 0.75)), V(0, 0.3, 0)), Y, 0.13, 0.12)
end

--------------------------------------------------------------------------
-- BARS: drop bars with hoods and levers, or bullhorns; the tape; the bell
--------------------------------------------------------------------------
local DROP = {   -- one side, from the clamp: x forward, y out, z up
    { 0, 2.2, 0 }, { 0, 4.6, 0 }, { 0.12, 6.0, 0.0 }, { 0.95, 7.2, -0.06 }, { 2.1, 7.85, -0.22 },
    { 3.0, 8.05, -0.62 }, { 3.42, 8.15, -1.6 }, { 3.15, 8.25, -3.0 }, { 2.15, 8.3, -4.3 },
    { 0.65, 8.3, -4.95 }, { -1.15, 8.3, -5.05 }, { -2.55, 8.3, -4.95 },
}
local HORN = {
    { 0, 2.2, 0 }, { 0, 4.6, 0 }, { 0.15, 6.3, 0.02 }, { 0.85, 7.45, 0.08 }, { 2.0, 8.05, 0.2 },
    { 3.4, 8.2, 0.42 }, { 4.6, 8.25, 0.75 }, { 5.4, 8.25, 1.15 },
}

local function barPoint(L, p, side) return add(L.clamp, V(p[1], p[2] * side, p[3])) end

local function buildBars(M, L, D)
    local Bk = M:bucket("bars", "black")
    local Rb = M:bucket("bars", D.tapeRole or "rubber")
    -- the bar's middle: 31.8 at the clamp, stepping down
    lathe(Bk, { { 0, -2.3, true }, { 0.46, -2.3, true }, { 0.47, -2.2 }, { 0.62, -1.35 }, { 0.62, 1.35 }, { 0.47, 2.2 }, { 0.46, 2.3, true }, { 0, 2.3, true } },
          L.clamp, Y, 22)
    local ctrl = D.drops and DROP or HORN
    local tapeFrom = D.drops and 2.95 or 4.2
    for _, side in ipairs({ 1, -1 }) do
        local pts = {}
        for i, p in ipairs(ctrl) do pts[i] = barPoint(L, p, side) end
        local path = resample(spline(pts, 6), 0.15)
        -- tape from just out of the tops to the end; bare bar inboard of it
        local i0 = 1
        for i, p in ipairs(path) do if abs(p[2]) >= tapeFrom then i0 = i break end end
        local bare = {}
        for i = 1, min(#path, i0 + 2) do bare[i] = path[i] end
        sweep(Bk, bare, 0.46, 16, { capStart = false, capEnd = false })
        local tp = {}
        for i = i0, #path do tp[#tp + 1] = path[i] end
        tapeTube(Rb, tp, 0.5, 0.035, 0.85, 13)
        -- finishing tape where it starts, and the bar-end plug
        local d0 = norm(sub(tp[2], tp[1]))
        lathe(Bk, { { 0.5, -0.1, true }, { 0.56, -0.08 }, { 0.56, 0.4 }, { 0.5, 0.45, true } }, tp[1], d0, 18)
        local dn = norm(sub(tp[#tp], tp[#tp - 1]))
        lathe(M:bucket("bars", "plastic"), { { 0, 0.12, true }, { 0.5, 0.12, true }, { 0.56, 0.05 }, { 0.56, -0.05 }, { 0.52, -0.08, true }, { 0.4, -0.08, true }, { 0.4, -0.3, true } },
              tp[#tp], dn, 18)
        if D.drops then
            -- the hood: rubber over the lever body
            local yc = 8.05 * side
            local o = barPoint(L, { 0, 0, 0 }, 1)
            local st = {
                { 2.15, -0.22, 0.46, 0.55 }, { 2.6, -0.32, 0.56, 0.7 }, { 3.2, -0.4, 0.6, 0.82 },
                { 3.9, -0.32, 0.6, 0.8 }, { 4.5, -0.12, 0.54, 0.72 }, { 4.95, 0.15, 0.46, 0.6 },
                { 5.25, 0.45, 0.34, 0.42 }, { 5.42, 0.62, 0.14, 0.16 },
            }
            for _, q in ipairs(st) do q[5] = yc end
            loft(M:bucket("bars", "rubber"), o, V(1, 0, 0), Y, Z, st, 20, 2.4)
            -- brake lever blade and the shift paddle behind it
            local blade = spline({ add(o, V(4.6, yc, -0.45)), add(o, V(5.05, yc + 0.05 * side, -1.2)),
                                   add(o, V(5.12, yc + 0.15 * side, -2.4)), add(o, V(4.72, yc + 0.32 * side, -3.7)),
                                   add(o, V(4.05, yc + 0.42 * side, -4.55)) }, 5)
            sweep(M:bucket("bars", D.leverRole or "black"), blade, function(t) return 0.1, 0.3 - 0.08 * t end, 12, { up = V(1, 0, 0) })
            local paddle = spline({ add(o, V(4.35, yc, -0.85)), add(o, V(4.5, yc - 0.05 * side, -1.9)),
                                    add(o, V(4.3, yc, -2.9)) }, 4)
            sweep(Bk, paddle, function(t) return 0.07, 0.2 - 0.05 * t end, 10, { up = V(1, 0, 0) })
            -- the hood's clamp band under the bar
            lathe(Bk, { { 0.47, -0.25, true }, { 0.55, -0.25, true }, { 0.55, 0.25, true }, { 0.47, 0.25, true } },
                  barPoint(L, { 3.2, 8.1, -0.95 }, side), norm(V(0.35, 0, -1)), 16)
        end
    end
    -- the bell on the left top, by the stem
    local at = barPoint(L, { 0, D.bellY, 0 }, 1)
    local pv, ax = G.parts.bell(M, "bars", "bellLever", at, Y, Z, V(-1, 0, 0))
    -- the hands: inner/rear end A, outer/front end B (right is -y)
    local gA, gB = D.gripA, D.gripB
    local function grip(side)
        return { A = barPoint(L, gA, side), B = barPoint(L, gB, side) }
    end
    return pv, ax, grip(-1), grip(1)
end

-- Cable housing from the bars to the frame: a hanging loop (bars group).
local function buildHousing(M, L, D)
    local H = M:bucket("bars", "plastic", true)
    for _, side in ipairs({ 1, -1 }) do
        local a = barPoint(L, { 0.1, 2.95, -0.42 }, side)
        local port = add(add(L.htT, mul(L.s, -1.6)), add(mul(L.n, 0.4), V(0, 0.72 * side, 0)))
        local pts = { a, add(a, V(0.5, 0.15 * side, -0.9)), add(lerp(a, port, 0.5), V(1.9, 0.6 * side, -0.2)),
                      add(port, add(mul(L.n, 1.3), V(0, 0.2 * side, 0.35))), port }
        sweep(H, spline(pts, 6), 0.12, 8)
    end
end

--------------------------------------------------------------------------
-- BRAKES: dual-pivot calipers
--------------------------------------------------------------------------
local function caliper(M, group, axle, mount, toward, R, tyreHalf)
    local u0 = norm(sub(mount, axle))
    local t = norm(sub(toward, mul(u0, dot(toward, u0))))   -- the side it hangs on
    local C = add(mount, mul(t, 0.72))
    local u = norm(sub(C, axle))
    local rc = len(sub(C, axle))
    local rp = R.rimOut - 0.42
    local Al = M:bucket(group, "alloy")
    local Bk = M:bucket(group, "black")
    local Pl = M:bucket(group, "plastic")
    local Ch = M:bucket(group, "chrome", true)
    local function at(rr, y, off) return add(add(axle, mul(u, rr)), add(V(0, y, 0), mul(t, off or 0))) end
    -- the centre bolt through the mount
    sweep(M:bucket(group, "steel"), { sub(mount, mul(t, 0.6)), add(C, mul(t, 0.3)) }, 0.13, 10)
    hexHead(Ch, sub(mount, mul(t, 0.6)), mul(t, -1), 0.24, 0.2)
    for _, s in ipairs({ 1, -1 }) do
        local yw = tyreHalf + 0.38
        local arm = spline({ at(rc + 0.2, 0.15 * s), at(rc + 0.05, 0.75 * s), at(rc - 0.55, yw * s),
                             at(R.outer - 0.2, (yw - 0.02) * s), at(R.rimOut + 0.25, (R.rimW * 0.5 + 0.42) * s),
                             at(rp, (R.rimW * 0.5 + 0.34) * s) }, 5)
        sweep(Al, arm, function(tt) return 0.16, 0.42 - 0.14 * tt end, 14, { up = t })
        -- pad holder and pad, along the rim
        local tang = norm(cross(Y, u))
        box(Bk, at(rp, (R.rimW * 0.5 + 0.24) * s), mul(tang, 0.62), V(0, 0.07, 0), mul(u, 0.16))
        box(Pl, at(rp, (R.rimW * 0.5 + 0.12) * s), mul(tang, 0.55), V(0, 0.06, 0), mul(u, 0.13))
        hexHead(Ch, at(rp, (R.rimW * 0.5 + 0.32) * s), V(0, s, 0), 0.12, 0.12)
    end
    -- the body: the two pivots, the spring and the quick-release cam
    lathe(Al, { { 0, -0.24, true }, { 0.52, -0.24, true }, { 0.56, -0.12 }, { 0.56, 0.12 }, { 0.52, 0.24, true }, { 0, 0.24, true } }, C, t, 20)
    lathe(Al, { { 0, -0.18, true }, { 0.3, -0.18, true }, { 0.32, 0 }, { 0.3, 0.18, true }, { 0, 0.18, true } }, at(rc - 0.35, -0.85), t, 14)
    box(Bk, at(rc + 0.38, 0.1), mul(u, 0.12), V(0, 0.5, 0), mul(t, 0.15))
    local qr = spline({ at(rc + 0.35, 0.55), at(rc + 0.7, 0.75), at(rc + 0.95, 0.6) }, 3)
    sweep(Al, qr, function() return 0.07, 0.16 end, 8, { up = t })
    -- barrel adjuster and the cable anchor bolt
    lathe(Ch, { { 0, 0, true }, { 0.16, 0, true }, { 0.16, 0.5 }, { 0.12, 0.55, true }, { 0, 0.55, true } }, at(rc + 0.15, 0.75), u, 10)
    hexHead(Ch, at(rc - 0.3, -0.75, 0.1), t, 0.14, 0.14)
    return at(rc + 0.7, 0.75)
end

--------------------------------------------------------------------------
-- DRIVETRAIN
--------------------------------------------------------------------------
-- A crank arm lofted from root to tip, as the BMX's.
local function crankArm(B, root, tip, wv0, wv1, wy0, wy1)
    local P = {}
    local st = 12
    for i = 0, st do
        local t = i / st
        local c = lerp(root, tip, t)
        local wv, wy = wv0 + (wv1 - wv0) * t, wy0 + (wy1 - wy0) * t
        local d = norm(sub(tip, root))
        local across = norm(cross(Y, d))
        P[#P + 1] = {}
        for j = 0, 15 do
            local a = j / 16 * TAU
            local ca, sa = cos(a), sin(a)
            local e = 3.0
            local cu = (abs(ca) ^ (2 / e)) * (ca < 0 and -1 or 1)
            local cv = (abs(sa) ^ (2 / e)) * (sa < 0 and -1 or 1)
            P[#P][j + 1] = add(c, add(V(0, cu * wy, 0), mul(across, cv * wv)))
        end
    end
    grid(B, P, true, function(i) return lerp(root, tip, (i - 1) / st) end)
end

local function buildCranks(M, L, D)
    local bb = L.bb
    local armRole = D.armRole
    local A = M:bucket("cranks", armRole)
    local Ch = M:bucket("cranks", "chrome", true)
    local St = M:bucket("cranks", "steel")
    sweep(St, { add(bb, V(0, -D.armY0 - 0.2, 0)), add(bb, V(0, D.armY0 + 0.2, 0)) }, D.spindleR, 18)
    for _, s in ipairs({ -1, 1 }) do
        local dir = (s == -1) and V(1, 0, 0) or V(-1, 0, 0)
        local root = add(bb, V(0, D.armY0 * s, 0))
        local tip = add(add(bb, V(0, D.armY1 * s, 0)), mul(dir, 6.8))
        crankArm(A, root, tip, 0.62, 0.42, D.armT, D.armT * 0.8)
        lathe(A, { { 0, -0.4, true }, { 0.85, -0.4, true }, { 0.9, -0.28 }, { 0.9, 0.28 }, { 0.85, 0.4, true }, { 0, 0.4, true } }, root, Y, 24)
        lathe(A, { { 0, -0.34, true }, { 0.5, -0.34, true }, { 0.54, -0.22 }, { 0.54, 0.22 }, { 0.5, 0.34, true }, { 0, 0.34, true } }, tip, Y, 18)
        -- the pedal's spindle out to the pedal body
        sweep(St, { tip, add(tip, V(0, (D.pedalIn - D.armY1) * s, 0)) }, 0.27, 12)
        lathe(St, { { 0.27, 0, true }, { 0.4, 0, true }, { 0.4, 0.18, true }, { 0.27, 0.18, true } }, add(tip, V(0, 0.32 * s, 0)), V(0, s, 0), 6, { flat = true })
        -- the arm's fixing: a crank bolt cap or the pinch bolts
        lathe(Ch, { { 0, 0, true }, { 0.45, 0, true }, { 0.45, 0.1 }, { 0.3, 0.14, true }, { 0, 0.14, true } }, add(root, V(0, 0.4 * s, 0)), V(0, s, 0), 16)
        if s == 1 and D.pinch then
            for _, zo in ipairs({ 0.25, -0.25 }) do
                capBolt(Ch, add(root, V(-0.95, 0, zo)), V(0, 1, 0), 0.12, 0.16)
            end
        end
    end
    -- spider arms and the rings
    local Rg = M:bucket("cranks", D.ringRole or "alloy")
    local root = add(bb, V(0, -D.armY0 + 0.15, 0))
    local nArms, bcd = D.spiderArms, D.bcdR
    for i = 0, nArms - 1 do
        local a = D.spiderPhase + i / nArms * TAU
        local d = V(cos(a), 0, sin(a))
        local p0 = add(root, mul(d, 0.7))
        local p1 = add(V(bb[1], D.spiderY, bb[3]), mul(d, bcd))
        sweep(A, { p0, lerp(p0, p1, 0.5), p1 }, function(t) return 0.17 - 0.03 * t, 0.58 - 0.3 * t end, 12, { up = Y })
        -- chainring bolt
        local bp = add(V(bb[1], D.rings[1].y - 0.12, bb[3]), mul(d, bcd))
        lathe(Ch, { { 0, 0, true }, { 0.2, 0, true }, { 0.2, 0.1 }, { 0.12, 0.13, true }, { 0, 0.13, true } }, bp, V(0, -1, 0), 10)
        lathe(Rg, { { 0, -0.2, true }, { 0.24, -0.2, true }, { 0.24, 0.2, true }, { 0, 0.2, true } }, add(V(bb[1], D.spiderY, bb[3]), mul(d, bcd)), Y, 12)
    end
    for ri, rg in ipairs(D.rings) do
        local pr = pitchR(rg.n)
        local inner = rg.inner or (pr - 0.7)
        sprocket(Rg, rg.n, bb[1], bb[3], rg.y, 0.12, inner, 6)
        -- tabs from the ring in to the bolts
        if inner > bcd + 0.15 then
            for i = 0, nArms - 1 do
                local a = D.spiderPhase + i / nArms * TAU
                local d = V(cos(a), 0, sin(a))
                local tg = V(-sin(a), 0, cos(a))
                local r0 = bcd - 0.25
                local mid = add(V(bb[1], rg.y, bb[3]), mul(d, (r0 + inner + 0.1) * 0.5))
                box(Rg, mid, mul(d, (inner + 0.1 - r0) * 0.5), V(0, 0.06, 0), mul(tg, 0.32))
            end
        end
        -- a chain guard pin on the big ring's outside
        if ri == 1 and #D.rings > 1 then
            local a = D.spiderPhase + 0.4
            lathe(Ch, { { 0, 0, true }, { 0.12, 0, true }, { 0.12, 0.22 }, { 0, 0.22, true } },
                  add(V(bb[1], rg.y - 0.06, bb[3]), V(cos(a) * (pr - 0.45), 0, sin(a) * (pr - 0.45))), V(0, -1, 0), 8)
        end
    end
end

-- The chain, static in the frame group.
local function buildChain(M, L, D)
    local St = M:bucket("frame", "steel", true)
    local bb, rear = L.bb, L.rear
    local C = { { x = bb[1], z = bb[3], r = pitchR(D.rings[1].n), o = 1, y = D.rings[1].y } }
    local cog = D.chainCog
    C[#C + 1] = { x = rear[1], z = rear[3], r = pitchR(cog.n), o = 1, y = cog.y }
    if D.rd then
        local j1, j2 = D.rd.j1, D.rd.j2
        local rj = pitchR(11)
        C[#C + 1] = { x = rear[1] + j1[1], z = rear[3] + j1[2], r = rj, o = -1, y = cog.y }
        C[#C + 1] = { x = rear[1] + j2[1], z = rear[3] + j2[2], r = rj, o = 1, y = cog.y }
    end
    local path = belt(C, 0.08)
    chainLinks(St, path, 1.04)
end

-- The rear derailleur and its housing (frame group).
local function buildRD(M, L, D)
    local rear = L.rear
    local Bk = M:bucket("frame", "black")
    local Al = M:bucket("frame", "alloy")
    local Pl = M:bucket("frame", "plastic")
    local Ch = M:bucket("frame", "chrome", true)
    local y = D.chainCog.y
    local j1 = V(rear[1] + D.rd.j1[1], y, rear[3] + D.rd.j1[2])
    local j2 = V(rear[1] + D.rd.j2[1], y, rear[3] + D.rd.j2[2])
    local dy = D.dropY
    -- the hanger, bolted outside the drive-side dropout
    local hb = add(rear, V(0.15, 0, -1.4))
    do
        local loop = {}
        local function at(u, v) loop[#loop + 1] = { rear[1] + u, rear[3] + v } end
        at(0.55, 0.45); at(-0.35, 0.55); at(-0.6, 0.0); at(-0.3, -1.25); at(0.05, -1.85); at(0.55, -1.75); at(0.6, -1.0); at(0.75, -0.2)
        plate(Al, loop, V(0, -(dy + 0.2), 0), V(1, 0, 0), V(0, 0, 1), 0.16, { smooth = true })
    end
    -- B-knuckle
    local bk = V(hb[1], -(dy + 0.45), hb[3])
    lathe(Bk, { { 0, -0.25, true }, { 0.42, -0.25, true }, { 0.45, -0.15 }, { 0.45, 0.15 }, { 0.42, 0.25, true }, { 0, 0.25, true } }, bk, Y, 18)
    hexHead(Ch, V(hb[1], -(dy + 0.7), hb[3]), V(0, -1, 0), 0.18, 0.12)
    -- P-knuckle near the cage pivot
    local pk = add(j1, V(0.15, -0.62, 0.62))
    lathe(Bk, { { 0, -0.22, true }, { 0.4, -0.22, true }, { 0.43, -0.12 }, { 0.43, 0.12 }, { 0.4, 0.22, true }, { 0, 0.22, true } }, pk, Y, 18)
    -- the parallelogram: two links and the outer cover
    local up = norm(sub(pk, bk))
    for _, o in ipairs({ -0.22, 0.22 }) do
        local off = V(-o * 0.6, 0, o)
        sweep(Al, { add(bk, add(off, V(0, -0.05, 0))), add(pk, add(off, V(0, -0.05, 0))) }, function() return 0.1, 0.16 end, 10, { up = Y })
    end
    local mid = lerp(bk, pk, 0.5)
    local side = norm(cross(up, Y))
    box(Bk, add(mid, V(0, -0.3, 0)), mul(up, len(sub(pk, bk)) * 0.42), V(0, 0.08, 0), mul(side, 0.42))
    -- the cage: outer and inner plates round both jockeys
    local function cageLoop(ro, rt, waist)
        local loop = {}
        local d = sub(j2, j1)
        local base = atan2(d[3], d[1])
        local cA = { j1[1], j1[3] }
        local cB = { j2[1], j2[3] }
        local function wp(side)
            local a = base + side * pi / 2
            local m = { (cA[1] + cB[1]) * 0.5, (cA[2] + cB[2]) * 0.5 }
            local r = (ro + rt) * 0.5 - waist
            loop[#loop + 1] = { m[1] + cos(a) * r, m[2] + sin(a) * r }
        end
        for i = 0, 10 do
            local a = base + pi / 2 + i / 10 * pi
            loop[#loop + 1] = { cA[1] + cos(a) * rt, cA[2] + sin(a) * rt }
        end
        wp(-1)
        for i = 0, 10 do
            local a = base - pi / 2 + i / 10 * pi
            loop[#loop + 1] = { cB[1] + cos(a) * ro, cB[2] + sin(a) * ro }
        end
        wp(1)
        return loop
    end
    plate(Bk, cageLoop(0.82, 0.78, 0.32), V(0, y - 0.3, 0), V(1, 0, 0), V(0, 0, 1), 0.08, { smooth = true })
    plate(Al, cageLoop(0.72, 0.7, 0.3), V(0, y + 0.3, 0), V(1, 0, 0), V(0, 0, 1), 0.06, { smooth = true })
    -- jockey wheels
    for _, j in ipairs({ j1, j2 }) do
        sprocket(Pl, 11, j[1], j[3], y, 0.14, 0.3, 4)
        lathe(Al, { { 0, -0.32, true }, { 0.3, -0.32, true }, { 0.3, 0.32, true }, { 0, 0.32, true } }, j, Y, 14)
        hexHead(Ch, V(j[1], y - 0.36, j[3]), V(0, -1, 0), 0.15, 0.1)
    end
    -- the cable housing from the chain stay to the barrel adjuster on the B-knuckle
    local H = M:bucket("frame", "plastic", true)
    local cs = L.cs[-1]
    local a = add(cs[#cs - 4], V(0, -0.35, 0.2))
    local barrel = add(bk, V(0.2, -0.35, 0.45))
    sweep(H, spline({ a, add(a, V(-1.2, -0.5, 0.2)), add(barrel, V(1.0, -0.15, 0.9)), barrel }, 6), 0.11, 8)
    lathe(M:bucket("frame", "alloy", true), { { 0, 0, true }, { 0.16, 0, true }, { 0.16, 0.4 }, { 0, 0.42, true } }, barrel, norm(V(-0.5, 0, -1)), 10)
end

-- The front derailleur on the seat tube (frame group).
local function buildFD(M, L, D)
    local bb = L.bb
    local big = D.rings[1]
    local pr = pitchR(big.n) + 0.17
    local Bk = M:bucket("frame", "black")
    local Al = M:bucket("frame", "alloy")
    local function arcLoop(r0, r1, a0, a1, tail)
        local loop = {}
        local n = 10
        for i = 0, n do
            local a = math.rad(a0 + (a1 - a0) * i / n)
            loop[#loop + 1] = { bb[1] + cos(a) * r0, bb[3] + sin(a) * r0 }
        end
        for i = n, 0, -1 do
            local a = math.rad(a0 + (a1 - a0) * i / n)
            local rr = r1 + (i == n and tail or 0)
            loop[#loop + 1] = { bb[1] + cos(a) * rr, bb[3] + sin(a) * rr }
        end
        return loop
    end
    plate(Bk, arcLoop(pr + 0.15, pr + 0.8, 96, 134, -0.25), V(0, big.y - 0.34, 0), V(1, 0, 0), V(0, 0, 1), 0.07, { smooth = true })
    plate(Al, arcLoop(pr + 0.2, pr + 0.65, 100, 130, 0), V(0, big.y + 0.5, 0), V(1, 0, 0), V(0, 0, 1), 0.06, { smooth = true })
    -- the bridges between the plates
    for _, a in ipairs({ 100, 128 }) do
        local ar = math.rad(a)
        local c = V(bb[1] + cos(ar) * (pr + 0.7), big.y + 0.08, bb[3] + sin(ar) * (pr + 0.7))
        box(Bk, c, V(0.12, 0, 0), V(0, 0.42, 0), V(0, 0, 0.1))
    end
    -- the clamp band on the seat tube and the linkage to the cage
    local d = pr + 1.25
    local cp = add(bb, mul(L.sd, d))
    lathe(Bk, { { D.stR - 0.01, -0.35, true }, { D.stR + 0.1, -0.3 }, { D.stR + 0.12, 0 }, { D.stR + 0.1, 0.3 }, { D.stR - 0.01, 0.35, true } }, cp, L.sd, 22)
    local cageTop = V(bb[1] + cos(math.rad(112)) * (pr + 0.85), big.y - 0.05, bb[3] + sin(math.rad(112)) * (pr + 0.85))
    local m0 = add(cp, V(0, -D.stR - 0.1, 0))
    sweep(Bk, { m0, add(lerp(m0, cageTop, 0.5), V(0.3, -0.25, 0.1)), cageTop }, function() return 0.32, 0.2 end, 12, { up = Y })
    sweep(Al, { add(m0, V(0.4, -0.2, -0.3)), add(cageTop, V(0.55, -0.25, -0.05)) }, function() return 0.1, 0.16 end, 8, { up = Y })
    hexHead(M:bucket("frame", "chrome", true), add(cp, V(0, -D.stR - 0.35, 0.0)), V(0, -1, 0), 0.14, 0.12)
end

--------------------------------------------------------------------------
-- PEDALS (one, about its own centre: x fwd, y along the spindle, z up)
--------------------------------------------------------------------------
local function buildRoadPedal(M)
    local Bk = M:bucket("pedal", "black")
    local Al = M:bucket("pedal", "alloy")
    local St = M:bucket("pedal", "steel", true)
    -- the spindle barrel
    lathe(Al, { { 0, -1.3, true }, { 0.3, -1.3, true }, { 0.34, -1.2 }, { 0.34, 1.15 }, { 0.28, 1.3, true }, { 0, 1.32, true } }, V(0, 0, 0), Y, 16)
    -- the body: a wide low platform, the cleat's front hook and rear binding
    local outline = {}
    local pts = { { 1.85, -0.75 }, { 1.95, 0 }, { 1.85, 0.75 }, { 1.2, 1.25 }, { -0.9, 1.3 }, { -1.5, 1.05 }, { -1.6, 0 }, { -1.5, -1.05 }, { -0.9, -1.3 }, { 1.2, -1.25 } }
    for _, p in ipairs(pts) do outline[#outline + 1] = p end
    plate(Bk, outline, V(0, 0, 0.12), V(1, 0, 0), V(0, 1, 0), 0.34, { smooth = true })
    -- a stainless wear plate on top
    plate(St, roundRect(1.9, 1.7, 0.4, 3, -0.1, 0), V(0, 0, 0.3), V(1, 0, 0), V(0, 1, 0), 0.03)
    -- the front hook
    sweep(Bk, { V(1.55, -0.8, 0.25), V(1.55, 0, 0.42), V(1.55, 0.8, 0.25) }, function() return 0.22, 0.16 end, 10, { up = Z })
    -- the rear binding and its spring housing
    box(Bk, V(-1.35, 0, 0.32), V(0.25, 0, 0), V(0, 0.7, 0), V(0, 0, 0.14))
    lathe(Bk, { { 0, -0.6, true }, { 0.18, -0.6, true }, { 0.18, 0.6, true }, { 0, 0.6, true } }, V(-1.1, 0, -0.08), Y, 10)
    capBolt(St, V(-1.45, 0, -0.1), V(0, 0, -1), 0.12, 0.15)
    -- underside ribs
    for _, yy in ipairs({ -0.6, 0.6 }) do box(Bk, V(0.4, yy, -0.12), V(1.2, 0, 0), V(0, 0.08, 0), V(0, 0, 0.14)) end
end

local function buildTrackPedal(M)
    local Al = M:bucket("pedal", "alloy")
    local Ch = M:bucket("pedal", "chrome")
    local St = M:bucket("pedal", "steel", true)
    local hw = 1.75
    -- barrel and end cap
    lathe(Al, { { 0, -hw, true }, { 0.32, -hw, true }, { 0.36, -hw + 0.1 }, { 0.36, hw - 0.1 }, { 0.32, hw, true }, { 0, hw, true } }, V(0, 0, 0), Y, 16)
    -- front and rear cage plates, toothed on top and bottom
    for _, x in ipairs({ 1.3, -1.3 }) do
        local loop = {}
        local n = 8
        for i = 0, n do
            local yy = -hw + 0.1 + (2 * hw - 0.2) * i / n
            loop[#loop + 1] = { yy, 0.45 + ((i % 2 == 0) and 0.1 or 0) }
        end
        for i = n, 0, -1 do
            local yy = -hw + 0.1 + (2 * hw - 0.2) * i / n
            loop[#loop + 1] = { yy, -0.45 - ((i % 2 == 0) and 0.1 or 0) }
        end
        plate(Al, loop, V(x, 0, 0), Y, Z, 0.12)
    end
    -- side plates joining the cage to the barrel
    for _, yy in ipairs({ -hw + 0.12, hw - 0.12 }) do
        plate(Al, roundRect(2.75, 0.75, 0.3, 3), V(0, yy, 0), V(1, 0, 0), Z, 0.12)
    end
    -- the toe clip: a chromed wire cage in front, and the strap through the pedal
    local clip = {}
    for _, p in ipairs({ { 1.35, -0.85, 0.45 }, { 2.4, -0.95, 0.75 }, { 3.15, -0.8, 1.45 }, { 3.35, -0.35, 2.15 },
                         { 3.35, 0.35, 2.15 }, { 3.15, 0.8, 1.45 }, { 2.4, 0.95, 0.75 }, { 1.35, 0.85, 0.45 } }) do
        clip[#clip + 1] = V(p[1], p[2], p[3])
    end
    sweep(Ch, spline(clip, 5), function() return 0.07, 0.14 end, 8, { up = V(1, 0, 0) })
    box(Ch, V(1.42, 0, 0.45), V(0.04, 0, 0), V(0, 0.85, 0), V(0, 0, 0.12))
    local Lt = M:bucket("pedal", "leather")
    local strap = {}
    for _, p in ipairs({ { 0.2, -1.35, -0.25 }, { 0.3, -1.45, 0.8 }, { 1.1, -1.4, 1.9 }, { 2.4, -0.8, 2.6 }, { 3.3, 0, 2.35 },
                         { 2.4, 0.8, 2.6 }, { 1.1, 1.4, 1.9 }, { 0.3, 1.45, 0.8 }, { 0.2, 1.35, -0.25 } }) do
        strap[#strap + 1] = V(p[1], p[2], p[3])
    end
    sweep(Lt, spline(strap, 5), function() return 0.32, 0.04 end, 8, { up = V(1, 0, 0.3) })
    box(Ch, V(0.45, 1.5, 1.0), V(0.2, 0, 0), V(0, 0.06, 0), V(0, 0, 0.25))
end

--------------------------------------------------------------------------
-- BOTTLE, CAGE, QUICK RELEASES, AXLE NUTS
--------------------------------------------------------------------------
local function buildBottle(M, L, D)
    local bb = L.bb
    local dd = norm(sub(L.dtHead, bb))
    local nUp = V(-dd[3], 0, dd[1])
    local base = add(add(bb, mul(dd, D.bottleAt)), mul(nUp, D.dtRmax + 0.3 + 1.45))
    lathe(M:bucket("frame", "white"), { { 0, 0, true }, { 1.2, 0, true }, { 1.4, 0.12 }, { 1.45, 0.45 }, { 1.45, 2.8 }, { 1.36, 3.25 },
        { 1.36, 4.6 }, { 1.45, 5.05 }, { 1.45, 6.55 }, { 1.3, 7.25 }, { 0.92, 7.75 }, { 0.86, 7.9, true }, { 0, 7.9, true } }, base, dd, 28)
    local Pl = M:bucket("frame", "plastic")
    local ctop = add(base, mul(dd, 7.85))
    lathe(Pl, { { 0, 0, true }, { 0.9, 0, true }, { 0.92, 0.45 }, { 0.6, 0.62, true }, { 0.42, 0.65 }, { 0.42, 0.95 }, { 0.22, 1.05, true }, { 0, 1.05, true } }, ctop, dd, 20)
    -- the cage: two rails round the bottle, a hook under it, bolted to the tube
    local Bk = M:bucket("frame", "black")
    local tubeTop = add(bb, mul(nUp, D.dtRmax))
    for _, s in ipairs({ 1, -1 }) do
        local function at(h, ang, r)
            local a = math.rad(ang)
            return add(add(base, mul(dd, h)), add(mul(nUp, -cos(a) * r), V(0, sin(a) * r * s, 0)))
        end
        local rail = { at(0.3, 30, 1.5), at(1.5, 70, 1.52), at(3.5, 80, 1.5), at(5.5, 70, 1.52), at(6.3, 35, 1.5), at(6.4, 0, 1.6) }
        sweep(Bk, spline(rail, 5), 0.1, 8)
    end
    local hook = {}
    for i = 0, 8 do
        local a = math.rad(-60 + 120 * i / 8)
        hook[#hook + 1] = add(add(base, mul(dd, -0.12)), add(mul(nUp, -cos(a) * 1.0), V(0, sin(a) * 1.0, 0)))
    end
    sweep(Bk, hook, 0.1, 8)
    for _, h in ipairs({ 1.7, 5.2 }) do
        local foot = add(add(bb, mul(dd, D.bottleAt + h)), mul(nUp, D.dtRmax + 0.12))
        box(Bk, foot, mul(dd, 0.45), V(0, 0.3, 0), mul(nUp, 0.12))
        capBolt(M:bucket("frame", "chrome", true), add(foot, mul(nUp, 0.12)), nUp, 0.15, 0.12)
    end
    local _ = tubeTop
end

local function quickRelease(M, group, axle, half, leverSide, toward)
    local Al = M:bucket(group, "alloy")
    local St = M:bucket(group, "steel")
    sweep(St, { add(axle, V(0, -(half + 0.35), 0)), add(axle, V(0, half + 0.35, 0)) }, 0.1, 8)
    local s = leverSide
    -- the cam and lever
    local c = add(axle, V(0, (half + 0.12) * s, 0))
    lathe(Al, { { 0, 0, true }, { 0.45, 0, true }, { 0.48, 0.1 }, { 0.42, 0.42, true }, { 0, 0.45, true } }, c, V(0, s, 0), 18)
    local tip = add(add(axle, mul(toward, 3.0)), V(0, (half + 0.45) * s, 0))
    local lever = spline({ add(c, V(0, 0.42 * s, 0)), add(lerp(c, tip, 0.35), V(0, 0.42 * s, 0)), tip }, 5)
    sweep(Al, lever, function(t) return 0.08, 0.32 - 0.08 * t end, 10, { up = V(0, s, 0) })
    -- the nut on the other side
    lathe(Al, { { 0, 0, true }, { 0.4, 0, true }, { 0.42, 0.1 }, { 0.3, 0.38, true }, { 0, 0.4, true } }, add(axle, V(0, -(half + 0.12) * s, 0)), V(0, -s, 0), 18)
end

local function trackNuts(M, group, axle, half)
    local Ch = M:bucket(group, "chrome")
    sweep(M:bucket(group, "steel"), { add(axle, V(0, -(half + 0.65), 0)), add(axle, V(0, half + 0.65, 0)) }, 0.22, 10)
    for _, s in ipairs({ 1, -1 }) do
        lathe(Ch, { { 0.22, 0, true }, { 0.62, 0, true }, { 0.62, 0.08, true }, { 0.22, 0.08, true } }, add(axle, V(0, (half + 0.12) * s, 0)), V(0, s, 0), 20)
        lathe(Ch, { { 0.22, 0, true }, { 0.5, 0, true }, { 0.5, 0.35 }, { 0.42, 0.42, true }, { 0.22, 0.42, true } }, add(axle, V(0, (half + 0.2) * s, 0)), V(0, s, 0), 6, { flat = true })
    end
end

--------------------------------------------------------------------------
-- THE DESIGNS
--------------------------------------------------------------------------
local ROAD = {
    wb = 48, seat = { -12.9, 0, 22.2 },
    -- cockpit: the bar clamp against the BMX's scaled grip, the stem
    clampDx = 0.9, clampDz = -2.55, stemL = 3.3, stemAngle = 6, stemH = 1.65, spacer = 0.38,
    offset = 2.6, forkL = 14.75, crownGap = 0.62, stack = 2.6,
    seatAngle = 74, seatJz = 19.4, stExt = 1.2, ttDrop = 0.95, dtUp = 1.05,
    htRb = 0.98, htRt = 0.8, bbHalf = 1.42, bbR = 0.95,
    ttR = function(t) return 0.66 - 0.04 * t, 0.62 - 0.06 * t end,
    dtR = function(t) return 0.98 - 0.02 * t, 0.84 + 0.1 * t end,
    dtRmax = 0.95, ttRmax = 0.67,
    stR = 0.72, csY0 = 1.05, csEnd = { 1.85, 0.12 }, csR = { 0.46, 0.3, 0.38, 0.25 },
    ssJoin = -1.9, ssBack = -0.12, ssY0 = 0.3, ssEnd = { 0.85, 1.55 }, ssR = { 0.3, 0.24, 0.27, 0.22 },
    dropY = 2.72,
    -- saddle
    saddleL = 11.0, saddleW = 2.65, saddleNose = 0.68, saddleSit = 0.28, railDrop = 1.15, postR = 0.62, postRole = "black",
    -- wheels: 700 x 25 on 21 mm alloy rims
    tyreW = 1.02, tyreH = 0.86, rimDepth = 0.95, rimW = 0.82, flangeR = 1.0, wall = "rubber", rimRole = "black",
    spokesF = 24, crossF = 0, spokesR = 28, crossR = 2, hubF = 1.95, dropF = 2.05, hubR = 1.25,
    -- forks
    bladeY0 = 1.28, bladeR = { 0.82, 0.4, 0.56, 0.3 },
    -- bars
    drops = true, bellY = 2.35, tapeRole = "rubber",
    gripA = { 1.65, 7.75, 0.0 }, gripB = { 4.45, 8.05, 0.32 },
    -- drivetrain
    armRole = "black", ringRole = "alloy", armY0 = 2.5, armY1 = 2.95, armT = 0.42, spindleR = 0.47, pedalIn = 3.9, pinch = true,
    spiderArms = 4, bcdR = 2.3, spiderPhase = math.rad(45), spiderY = -2.25,
    rings = { { n = 50, y = -2.05 }, { n = 34, y = -1.82 } },
    chainCog = { n = 17, y = cogY(6) },
    rd = { j1 = { -0.45, -2.6 }, j2 = { 0.55, -5.35 } },
    bottleAt = 4.6,
}
ROAD.dropLoop = function(L)
    local r = L.rear
    local loop = {}
    local function at(u, v) loop[#loop + 1] = { r[1] + u, r[3] + v } end
    -- a vertical dropout, the slot opening down and a little forward
    at(0.28, -0.85); at(0.24, 0)
    for i = 1, 7 do local a = i / 8 * pi at(cos(a) * 0.24, sin(a) * 0.24) end
    at(-0.24, 0); at(-0.32, -0.6)
    at(-0.62, -0.45); at(-0.75, 0.3); at(-0.3, 1.0); at(0.6, 1.9); at(1.15, 1.65); at(2.3, 0.45); at(2.2, -0.2); at(1.2, -0.55); at(0.6, -0.85)
    return loop
end

local FIXIE = {
    wb = 44, seat = { -11.85, 0, 20.3 },
    clampDx = 1.55, clampDz = -2.35, stemL = 3.1, stemAngle = 8, stemH = 0,
    offset = 1.75, forkL = 14.55, crownGap = 0.5, htLen = 7.4,
    seatAngle = 73, stExt = 1.0, ttDrop = 1.9, dtUp = 0.9,
    htRb = 0.66, htRt = 0.66, bbHalf = 1.36, bbR = 0.8, lugs = true, lugRole = "chrome",
    ttR = 0.56, dtR = 0.6, dtRmax = 0.6, stR = 0.58,
    csY0 = 1.0, csEnd = { 1.6, 0.05 }, csR = { 0.4, 0.26, 0.34, 0.22 },
    ssJoin = 0.25, ssBack = 0.62, ssY0 = 0.42, ssEnd = { 0.9, 1.25 }, ssR = { 0.28, 0.22, 0.28, 0.22 }, fastback = true,
    dropY = 2.57,
    saddleL = 10.4, saddleW = 2.35, saddleNose = 0.62, saddleSit = 0.3, railDrop = 1.1, postR = 0.55, postRole = "alloy",
    collarRole = "chrome",
    tyreW = 1.02, tyreH = 0.86, rimDepth = 1.6, rimW = 0.85, flangeR = 1.3, wall = "gum", rimRole = "alloy", deepV = 0.32,
    spokesF = 32, crossF = 2, spokesR = 32, crossR = 3, hubF = 1.9, dropF = 2.05, hubR = 1.5,
    straightFork = true, flatCrown = true, bladeY0 = 1.3, bladeR = { 0.52, 0.32, 0.52, 0.32 },
    drops = false, bellY = 2.35, tapeRole = "rubber",
    gripA = { 1.0, 7.65, 0.1 }, gripB = { 5.2, 8.25, 1.05 },
    armRole = "alloy", ringRole = "black", armY0 = 2.25, armY1 = 2.75, armT = 0.38, spindleR = 0.38, pedalIn = 3.45,
    spiderArms = 5, bcdR = 2.95, spiderPhase = math.rad(18), spiderY = -1.95,
    rings = { { n = 46, y = -1.72, inner = 2.72 } },
    chainY = -1.72, cogT = 17,
    chainCog = { n = 17, y = -1.72 },
}
FIXIE.dropLoop = function(L)
    local r = L.rear
    local loop = {}
    local function at(u, v) loop[#loop + 1] = { r[1] + u, r[3] + v } end
    -- a track end: the slot opens to the rear, the axle pulled back in it
    at(-1.6, 0.25); at(0.35, 0.25)
    for i = 1, 7 do local a = pi / 2 - i / 8 * pi at(0.35 + cos(a) * 0.25, sin(a) * 0.25) end
    at(0.35, -0.25); at(-1.6, -0.25)
    at(-1.6, -0.58); at(0.4, -0.75); at(1.85, -0.35); at(1.95, 0.35); at(1.5, 1.1); at(0.6, 1.5); at(-0.3, 1.05); at(-1.2, 0.62)
    return loop
end

--------------------------------------------------------------------------
-- BUILD
--------------------------------------------------------------------------
local function build(opt, D)
    local M = Pm.newModel()
    local L = geom(opt, D)
    buildFrame(M, L, D)
    decalTube(M, L.dtHead, L.bb, D.dtRmax, 0.2, 0.75)
    buildSaddle(M, L, D)
    local R = buildWheels(M, L, D)
    buildFork(M, L, D)
    if D.drops then buildThreadless(M, L, D) else buildQuill(M, L, D) end
    local pv, ax, gripR, gripL = buildBars(M, L, D)
    buildCranks(M, L, D)
    buildChain(M, L, D)
    if D.drops then
        buildCassette(M, D)
        buildRD(M, L, D)
        buildFD(M, L, D)
        buildHousing(M, L, D)
        buildRoadPedal(M)
        buildBottle(M, L, D)
        -- brakes: the front on the crown, the rear on the seat-stay bridge
        local tyreHalf = R.tyreW * 0.5
        local fm = add(L.crown, mul(L.n, 0.15))
        caliper(M, "fork", L.front, fm, L.n, R, tyreHalf)
        -- the bridge: where the seat stays are a caliper's reach above the rim
        local ss = L.ss[1]
        local want = R.outer + 1.0
        local bi = #ss
        for i = #ss, 1, -1 do
            local p = ss[i]
            if len(sub(V(p[1], 0, p[3]), L.rear)) >= want then bi = i break end
        end
        local a, b = L.ss[1][bi], L.ss[-1][bi]
        sweep(M:bucket("frame", "paint"), { a, lerp(a, b, 0.5), b }, 0.2, 12, { capStart = false, capEnd = false })
        local bm = lerp(a, b, 0.5)
        caliper(M, "frame", L.rear, bm, V(-1, 0, 0.3), R, tyreHalf)
        -- the rear brake's housing from the top tube's exit port
        local H = M:bucket("frame", "plastic", true)
        local ttd = norm(sub(L.seatJ, L.ttHead))
        local port = add(sub(L.seatJ, mul(ttd, 2.2)), V(0, 0.35, 0.55))
        local br = add(bm, add(mul(norm(sub(bm, L.rear)), 1.4), V(0, 0.75, 0)))
        sweep(H, spline({ port, add(port, V(-1.4, 0.15, 0.35)), add(br, V(1.0, 0.1, 1.0)), br }, 6), 0.11, 8)
        quickRelease(M, "fork", L.front, D.dropF + 0.12, 1, norm(add(L.s, mul(L.n, -0.25))))
        quickRelease(M, "frame", L.rear, D.dropY + 0.12, 1, norm(V(1, 0, 0.25)))
    else
        buildFixedCog(M, D)
        buildTrackPedal(M)
        trackNuts(M, "fork", L.front, D.dropF + 0.12)
        trackNuts(M, "frame", L.rear, D.dropY + 0.12)
    end
    -- drop buckets nothing was put in (a slick tyre's tread)
    for _, name in ipairs(M.order) do
        local g = M.groups[name]
        for i = #g, 1, -1 do if g[i].tris == 0 then table.remove(g, i) end end
    end
    M.layout = {
        k = L.k, steer = L.s, headT = L.htT, headB = L.htB,
        rear = L.rear, front = L.front, bb = L.bb, crank = 6.8, pedalY = 5.2,
        gripR = gripR, gripL = gripL, stemTop = L.S, clamp = L.clamp,
        bellPivot = pv, bellAxis = ax, headAngle = L.headAngle, saddleTop = L.saddleTop,
    }
    return M
end

G.RegisterKind("road", function(opt) return build(opt or {}, ROAD) end)
G.RegisterKind("fixie", function(opt) return build(opt or {}, FIXIE) end)
G.RoadDesigns = { road = ROAD, fixie = FIXIE }
