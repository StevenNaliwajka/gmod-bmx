--[[--------------------------------------------------------------------------
    tests/lib/bodyclip.lua

    DOES THE BODY GO THROUGH THE BIKE? A rider's body as capsules (kleiner's own,
    measured off his mesh: tools/rider/studio/capsules.py, tests/data/
    body_capsules_kleiner.lua), the vehicle as the triangles it was drawn with this
    frame, and the exact distance between them: how far each part of the body is
    pushed into the vehicle, or into another part of the body.

    WHY CAPSULES AND EXACT DISTANCES. A capsule (a segment and a radius) is what a limb
    is, near enough, and the distance from a segment to a triangle is exact and cheap.
    Sampling instead -- is any vertex of the body inside the bike? -- misses the cases
    that matter: a deck is two big triangles and a shin can go clean through one with
    no vertex of either on the other side. Each capsule sits a little INSIDE the skin
    (capsules.py's header), so skin on a pedal or a hand on a thigh is not a hit;
    what is, is a part pushed into something.

    THE PIECES OF IT
        BC.load(name)            the capsule set (default "kleiner": tests/data/
                                 body_capsules_kleiner.lua)
        BC.capsules(src, set, who)   the posed capsules, a list of { name, part, side,
                                 who, r, out, ax, ay, az, bx, by, bz }: `src` a player (its
                                 GetBoneMatrix, set up here) or a bones table (name -> the
                                 12 numbers studio.lua writes: origin, forward, left, up)
        BC.recorder(cl)          on a client realm, after lib/meshfake's enable and before
                                 any model builds: records every mesh's triangles as it is
                                 built and every group drawn (BikeMesh.DrawGroup, with its
                                 matrix) and tube (BikeMesh.DrawTube). rec:frame() starts a
                                 frame's record; rec.tag labels what is drawn next (a
                                 skate's boot: "l" or "r")
        BC.fromStudio(json)      the same record from a studio.lua JSON's `meshes`;
                                 rec:studioShot(shot) takes a shot's draws as the frame
        BC.vehicleHits(caps, rec, opts)   each piece's deepest push into each group and
                                 material drawn this frame (and each tube): a list of
                                 { who, piece, part, with = "group/mat", group, mat, depth,
                                 label }. opts: tol, allow (default BC.ALLOW), targets
                                 ({ [who] = { rHand = Vector, ..., seat = Vector } }),
                                 label, only (a piece-name pattern)
        BC.bodyHits(capsA, capsB, opts)   piece into piece, deepest per pair of parts: two
                                 bodies (every pair), or one (capsB nil: the pairs that do
                                 not join, BC.joined). opts: tol, allow ({ a, b, whoA, whoB }
                                 part/who patterns, either way round), label
        BC.check(people, rec, opts)   all of it for everyone on a vehicle this frame:
                                 people = { { who, src, targets } }; the hits, `body` true
                                 for body on body (what tests/test_body_clip.lua calls)
        BC.studioHits(json, opts)    the same for every shot of a studio.lua JSON
        BC.segSeg2, BC.pointTri2, BC.segTri2, BC.deepest   the exact squared distances, and
                                 the grid's search
        BC.describe(hit)         one line

    From the studio's photographs, offline (lua5.1, package.path at tests/):
        local J, BC = require("lib.json"), require("lib.bodyclip")
        local d = J.decode(io.open("shots.json"):read("*a"))
        for _, h in ipairs(BC.studioHits(d, { tol = 0.75, bodyTol = 1.0 })) do
            print(BC.describe(h))
        end
    (a studio shot carries the rider's IK targets as { x, y, z } lists, which the
    allowed contacts read too; its passenger's, and the seats, it does not.)

    A HIT'S DEPTH is how far into the capsule the other thing reaches: the radius less
    the distance (two radii less the distance, body on body). Only hits deeper than
    opts.tol (default 0) are returned.

    THE ALLOWED CONTACTS. A fist is closed round a grip, so the grip is inside it; a
    foot stands on its pedal. Those are not clipping, and `opts.allow` says which they
    are: a list of rules, each
        { part = pattern, who = pattern, group = pattern, mat = pattern,
          near = "Foot" | "Hand" | key, within = units, depth = units, sameSide = true,
          why = "..." }
    (a pattern may be a list of them) matched against the piece's part ("r_hand"), whose
    body it is ("rider"), and the group and material drawn ("bars", "rubber"). `near`:
    only the triangles within `within` of that target (opts.targets[who][side .. near],
    e.g. rFoot; or the key itself, e.g. "seat") are excused -- a foot may stand on the
    frame's peg, not go through the frame's top tube. `depth`: excused only that deep (a
    sole may press into a deck, not sink through it). `sameSide`: only what was drawn
    tagged with the piece's own side (a skate's boot is its own foot's). BC.ALLOW is
    the set every vehicle shares.
----------------------------------------------------------------------------]]

local M = {}
local sqrt, min, max, floor, huge = math.sqrt, math.min, math.max, math.floor, math.huge

--------------------------------------------------------------------------
-- EXACT DISTANCES (Ericson, Real-Time Collision Detection, 5.1.5 and 5.1.9).
-- Plain numbers, not Vectors: these run a few hundred thousand times a frame.
--------------------------------------------------------------------------
local EPS = 1e-12

local function clamp01(x) if x < 0 then return 0 elseif x > 1 then return 1 end return x end

-- Squared distance between the segments p1-q1 and p2-q2.
local function segSeg2(p1x, p1y, p1z, q1x, q1y, q1z, p2x, p2y, p2z, q2x, q2y, q2z)
    local d1x, d1y, d1z = q1x - p1x, q1y - p1y, q1z - p1z
    local d2x, d2y, d2z = q2x - p2x, q2y - p2y, q2z - p2z
    local rx, ry, rz = p1x - p2x, p1y - p2y, p1z - p2z
    local a = d1x * d1x + d1y * d1y + d1z * d1z
    local e = d2x * d2x + d2y * d2y + d2z * d2z
    local f = d2x * rx + d2y * ry + d2z * rz
    local s, t
    if a <= EPS and e <= EPS then
        return rx * rx + ry * ry + rz * rz
    end
    if a <= EPS then
        s, t = 0, clamp01(f / e)
    else
        local c = d1x * rx + d1y * ry + d1z * rz
        if e <= EPS then
            t, s = 0, clamp01(-c / a)
        else
            local b = d1x * d2x + d1y * d2y + d1z * d2z
            local denom = a * e - b * b
            s = denom > EPS * a * e and clamp01((b * f - c * e) / denom) or 0
            t = (b * s + f) / e
            if t < 0 then
                t, s = 0, clamp01(-c / a)
            elseif t > 1 then
                t, s = 1, clamp01((b - c) / a)
            end
        end
    end
    local x = (p1x + d1x * s) - (p2x + d2x * t)
    local y = (p1y + d1y * s) - (p2y + d2y * t)
    local z = (p1z + d1z * s) - (p2z + d2z * t)
    return x * x + y * y + z * z
end
M.segSeg2 = segSeg2

-- Squared distance from the point p to the triangle abc (Ericson's closest point by
-- Voronoi region). A triangle with no area is its three edges.
local function pointTri2(px, py, pz, ax, ay, az, bx, by, bz, cx, cy, cz)
    local abx, aby, abz = bx - ax, by - ay, bz - az
    local acx, acy, acz = cx - ax, cy - ay, cz - az
    local apx, apy, apz = px - ax, py - ay, pz - az
    local d1 = abx * apx + aby * apy + abz * apz
    local d2 = acx * apx + acy * apy + acz * apz
    local qx, qy, qz
    if d1 <= 0 and d2 <= 0 then
        qx, qy, qz = ax, ay, az
    else
        local bpx, bpy, bpz = px - bx, py - by, pz - bz
        local d3 = abx * bpx + aby * bpy + abz * bpz
        local d4 = acx * bpx + acy * bpy + acz * bpz
        if d3 >= 0 and d4 <= d3 then
            qx, qy, qz = bx, by, bz
        else
            local vc = d1 * d4 - d3 * d2
            if vc <= 0 and d1 >= 0 and d3 <= 0 and d1 - d3 > 0 then
                local v = d1 / (d1 - d3)
                qx, qy, qz = ax + abx * v, ay + aby * v, az + abz * v
            else
                local cpx, cpy, cpz = px - cx, py - cy, pz - cz
                local d5 = abx * cpx + aby * cpy + abz * cpz
                local d6 = acx * cpx + acy * cpy + acz * cpz
                if d6 >= 0 and d5 <= d6 then
                    qx, qy, qz = cx, cy, cz
                else
                    local vb = d5 * d2 - d1 * d6
                    if vb <= 0 and d2 >= 0 and d6 <= 0 and d2 - d6 > 0 then
                        local w = d2 / (d2 - d6)
                        qx, qy, qz = ax + acx * w, ay + acy * w, az + acz * w
                    else
                        local va = d3 * d6 - d5 * d4
                        if va <= 0 and (d4 - d3) >= 0 and (d5 - d6) >= 0 and (d4 - d3) + (d5 - d6) > 0 then
                            local w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
                            qx, qy, qz = bx + (cx - bx) * w, by + (cy - by) * w, bz + (cz - bz) * w
                        else
                            local den = va + vb + vc
                            if den <= EPS then
                                -- no area: the nearest of its edges
                                return min(segSeg2(px, py, pz, px, py, pz, ax, ay, az, bx, by, bz),
                                           segSeg2(px, py, pz, px, py, pz, bx, by, bz, cx, cy, cz),
                                           segSeg2(px, py, pz, px, py, pz, cx, cy, cz, ax, ay, az))
                            end
                            local v, w = vb / den, vc / den
                            qx = ax + abx * v + acx * w
                            qy = ay + aby * v + acy * w
                            qz = az + abz * v + acz * w
                        end
                    end
                end
            end
        end
    end
    local x, y, z = px - qx, py - qy, pz - qz
    return x * x + y * y + z * z
end
M.pointTri2 = pointTri2

-- Does the segment p-q pass through the triangle abc (Moller-Trumbore, t in 0..1)?
local function segHitsTri(px, py, pz, qx, qy, qz, ax, ay, az, bx, by, bz, cx, cy, cz)
    local dx, dy, dz = qx - px, qy - py, qz - pz
    local e1x, e1y, e1z = bx - ax, by - ay, bz - az
    local e2x, e2y, e2z = cx - ax, cy - ay, cz - az
    local hx, hy, hz = dy * e2z - dz * e2y, dz * e2x - dx * e2z, dx * e2y - dy * e2x
    local det = e1x * hx + e1y * hy + e1z * hz
    if det > -1e-12 and det < 1e-12 then return false end
    local inv = 1 / det
    local sx, sy, sz = px - ax, py - ay, pz - az
    local u = (sx * hx + sy * hy + sz * hz) * inv
    if u < 0 or u > 1 then return false end
    local qx2, qy2, qz2 = sy * e1z - sz * e1y, sz * e1x - sx * e1z, sx * e1y - sy * e1x
    local v = (dx * qx2 + dy * qy2 + dz * qz2) * inv
    if v < 0 or u + v > 1 then return false end
    local t = (e2x * qx2 + e2y * qy2 + e2z * qz2) * inv
    return t >= 0 and t <= 1
end

-- Squared distance between the segment p-q and the triangle abc: 0 if it passes
-- through, else the least of its ends to the triangle and it to the triangle's edges
-- (two convex sets that do not meet are nearest at a boundary of one of them).
local function segTri2(px, py, pz, qx, qy, qz, ax, ay, az, bx, by, bz, cx, cy, cz)
    if segHitsTri(px, py, pz, qx, qy, qz, ax, ay, az, bx, by, bz, cx, cy, cz) then return 0 end
    local d = pointTri2(px, py, pz, ax, ay, az, bx, by, bz, cx, cy, cz)
    d = min(d, pointTri2(qx, qy, qz, ax, ay, az, bx, by, bz, cx, cy, cz))
    d = min(d, segSeg2(px, py, pz, qx, qy, qz, ax, ay, az, bx, by, bz))
    d = min(d, segSeg2(px, py, pz, qx, qy, qz, bx, by, bz, cx, cy, cz))
    d = min(d, segSeg2(px, py, pz, qx, qy, qz, cx, cy, cz, ax, ay, az))
    return d
end
M.segTri2 = segTri2
M.segHitsTri = segHitsTri

--------------------------------------------------------------------------
-- THE BODY
--------------------------------------------------------------------------
local sets = {}
function M.load(name)
    name = name or "kleiner"
    if sets[name] then return sets[name] end
    local here = debug.getinfo(1, "S").source:match("^@(.*)/lib/[^/]*$") or "tests"
    local data = dofile(here .. "/data/body_capsules_" .. name .. ".lua")
    local byName = {}
    for _, p in ipairs(data.pieces) do
        byName[p.name] = p
        p.side = p.part:match("^([rl])_")
    end
    data.byName = byName
    sets[name] = data
    return data
end

-- A bone's frame as 12 numbers: origin, forward, left, up.
local function frameOf(src, bone, cache)
    local f = cache[bone]
    if f then return f end
    if src.GetBoneMatrix then
        local i = src:LookupBone(bone)
        local m = i and src:GetBoneMatrix(i)
        if not m then return nil end
        local t, fw, r, u = m:GetTranslation(), m:GetForward(), m:GetRight(), m:GetUp()
        f = { t.x, t.y, t.z, fw.x, fw.y, fw.z, -r.x, -r.y, -r.z, u.x, u.y, u.z }
    else
        f = src[bone]
        if not f then return nil end
    end
    cache[bone] = f
    return f
end

local function place(f, o)
    local x, y, z = o[1], o[2], o[3]
    return f[1] + f[4] * x + f[7] * y + f[10] * z,
           f[2] + f[5] * x + f[8] * y + f[11] * z,
           f[3] + f[6] * x + f[9] * y + f[12] * z
end

-- The posed capsules: a list of { name, part, side, who, r, out, ax..az, bx..bz }.
-- `src`: a player (set up here) or a bones table (name -> 12 numbers, as studio.lua writes).
function M.capsules(src, set, who)
    set = set or M.load()
    if src.GetBoneMatrix and src.InvalidateBoneCache then
        src:InvalidateBoneCache()
        if src.SetupBones then src:SetupBones() end
    end
    local cache, out = {}, {}
    for _, p in ipairs(set.pieces) do
        local fa, fb = frameOf(src, p.a[1], cache), frameOf(src, p.b[1], cache)
        if fa and fb then
            local ax, ay, az = place(fa, p.a[2])
            local bx, by, bz = place(fb, p.b[2])
            out[#out + 1] = { name = p.name, part = p.part, side = p.side, who = who or "body", r = p.r, out = p.out,
                              ax = ax, ay = ay, az = az, bx = bx, by = by, bz = bz }
        end
    end
    return out
end

--------------------------------------------------------------------------
-- THE VEHICLE, as drawn: a recorder of the client's built meshes and draws.
--------------------------------------------------------------------------
local REC = {}
REC.__index = REC

-- Install on a client realm (after lib/meshfake's enable, before any model builds).
function M.recorder(cl)
    local E, B = cl.env, cl.env.BMX
    local rec = setmetatable({ meshes = {}, draws = {}, tubes = {}, grids = {}, tag = nil }, REC)
    local meshOf = setmetatable({}, { __mode = "k" })
    local origMesh = E.Mesh
    E.Mesh = function(...)
        local m = origMesh(...)
        local id = #rec.meshes + 1
        rec.meshes[id] = false
        meshOf[m] = id
        local build = m.BuildFromTriangles
        -- (the vertices are a pool the builder reuses: copied now)
        function m:BuildFromTriangles(verts)
            local p, n = {}, 0
            for i = 1, #verts do
                local q = verts[i].pos
                p[n + 1], p[n + 2], p[n + 3] = q.x, q.y, q.z
                n = n + 3
            end
            rec.meshes[id] = p
            if build then return build(self, verts) end
        end
        return m
    end
    local BM = B.BikeMesh
    local drawGroup, drawTube = BM.DrawGroup, BM.DrawTube
    BM.DrawGroup = function(model, name, mtx, paint, lod)
        local list = model.groups[name]
        if list then
            local r = mtx.rows
            local m12 = { r[1][1], r[1][2], r[1][3], r[1][4], r[2][1], r[2][2], r[2][3], r[2][4],
                          r[3][1], r[3][2], r[3][3], r[3][4] }
            for _, e in ipairs(list) do
                if not (e.detail and (lod or 0) >= 2) then
                    for _, m in ipairs(e.meshes) do
                        local id = meshOf[m]
                        if id then
                            rec.draws[#rec.draws + 1] = { mesh = id, name = name, mat = tostring(e.mat), m = m12, tag = rec.tag }
                        end
                    end
                end
            end
        end
        return drawGroup(model, name, mtx, paint, lod)
    end
    BM.DrawTube = function(pts, radius, role, sides, paint)
        local t = { r = radius, role = tostring(role), tag = rec.tag }
        for i, p in ipairs(pts) do t[i] = { p.x, p.y, p.z } end
        rec.tubes[#rec.tubes + 1] = t
        return drawTube(pts, radius, role, sides, paint)
    end
    return rec
end

-- A new frame: what is drawn from now on is this frame's.
function REC:frame()
    self.draws, self.tubes, self.tag = {}, {}, nil
end

-- A studio.lua JSON's record (its `meshes`), so its shots can be checked offline.
function M.fromStudio(data)
    local rec = setmetatable({ meshes = {}, draws = {}, tubes = {}, grids = {} }, REC)
    for i, p in ipairs(data.meshes) do rec.meshes[i] = p or false end
    return rec
end

-- Take a studio shot's draws and tubes as this record's frame.
function REC:studioShot(shot)
    self.draws, self.tubes = {}, {}
    for _, d in ipairs(shot.drawn or {}) do
        self.draws[#self.draws + 1] = { mesh = d.mesh, name = d.name, mat = d.mat, m = d.m }
    end
    for _, t in ipairs(shot.tubes or {}) do
        local u = { r = t.r, role = "tube" }
        for i, p in ipairs(t.pts) do u[i] = p end
        self.tubes[#self.tubes + 1] = u
    end
end

-- THE GRID. Each mesh's triangles, in its own model space, binned in cubes of CELL
-- units (a triangle in every cube its bounds touch), with the mesh's bounds. Built the
-- first time the mesh is asked about. (A grid rather than a tree: it is built in one
-- pass, and Lua is slow at the sorting a tree takes.)
local CELL = 2.0
local KEY = 4096          -- cells along an axis, about the model's origin
local HALF = KEY / 2
local function cellOf(v) return floor(v / CELL) end

function REC:grid(id)
    local g = self.grids[id]
    if g then return g end
    local p = self.meshes[id]
    if not p then return nil end
    local cells, sph = {}, {}
    local n = floor(#p / 9)
    local mnx, mny, mnz, mxx, mxy, mxz = huge, huge, huge, -huge, -huge, -huge
    for t = 0, n - 1 do
        local o = t * 9
        local ax, ay, az, bx, by, bz, cx, cy, cz = p[o + 1], p[o + 2], p[o + 3], p[o + 4], p[o + 5], p[o + 6], p[o + 7], p[o + 8], p[o + 9]
        -- a sphere round it (the middle of its corners, out to the furthest)
        local mx, my, mz = (ax + bx + cx) / 3, (ay + by + cy) / 3, (az + bz + cz) / 3
        sph[t * 4 + 1], sph[t * 4 + 2], sph[t * 4 + 3] = mx, my, mz
        sph[t * 4 + 4] = sqrt(max((ax - mx) ^ 2 + (ay - my) ^ 2 + (az - mz) ^ 2, (bx - mx) ^ 2 + (by - my) ^ 2 + (bz - mz) ^ 2,
                                  (cx - mx) ^ 2 + (cy - my) ^ 2 + (cz - mz) ^ 2))
        local x0, x1 = min(ax, bx, cx), max(ax, bx, cx)
        local y0, y1 = min(ay, by, cy), max(ay, by, cy)
        local z0, z1 = min(az, bz, cz), max(az, bz, cz)
        if x0 < mnx then mnx = x0 end
        if y0 < mny then mny = y0 end
        if z0 < mnz then mnz = z0 end
        if x1 > mxx then mxx = x1 end
        if y1 > mxy then mxy = y1 end
        if z1 > mxz then mxz = z1 end
        for i = cellOf(x0), cellOf(x1) do
            for j = cellOf(y0), cellOf(y1) do
                for k = cellOf(z0), cellOf(z1) do
                    local key = ((i + HALF) * KEY + (j + HALF)) * KEY + (k + HALF)
                    local c = cells[key]
                    if not c then c = {} cells[key] = c end
                    c[#c + 1] = t + 1
                end
            end
        end
    end
    local stamp = {}
    for t = 1, n do stamp[t] = 0 end
    g = { cells = cells, sph = sph, n = n, box = { mnx, mny, mnz, mxx, mxy, mxz }, stamp = stamp, q = 0 }
    self.grids[id] = g
    return g
end

-- A draw's matrix inverted, on the assumption it is a rotation and a translation (and
-- a check that it is: a scaled or sheared matrix would make model-space distances
-- wrong, and is said so loudly).
local function invRigid(m)
    local r11, r12, r13, tx = m[1], m[2], m[3], m[4]
    local r21, r22, r23, ty = m[5], m[6], m[7], m[8]
    local r31, r32, r33, tz = m[9], m[10], m[11], m[12]
    local c1 = r11 * r11 + r21 * r21 + r31 * r31
    local c2 = r12 * r12 + r22 * r22 + r32 * r32
    local c3 = r13 * r13 + r23 * r23 + r33 * r33
    local d12 = r11 * r12 + r21 * r22 + r31 * r32
    local d13 = r11 * r13 + r21 * r23 + r31 * r33
    local d23 = r12 * r13 + r22 * r23 + r32 * r33
    if math.abs(c1 - 1) > 1e-3 or math.abs(c2 - 1) > 1e-3 or math.abs(c3 - 1) > 1e-3
        or math.abs(d12) > 1e-3 or math.abs(d13) > 1e-3 or math.abs(d23) > 1e-3 then
        return nil
    end
    -- world -> model: R^T (p - t)
    return function(x, y, z)
        x, y, z = x - tx, y - ty, z - tz
        return r11 * x + r21 * y + r31 * z, r12 * x + r22 * y + r32 * z, r13 * x + r23 * y + r33 * z
    end, function(x, y, z)     -- model -> world
        return r11 * x + r12 * y + r13 * z + tx, r21 * x + r22 * y + r23 * z + ty, r31 * x + r32 * y + r33 * z + tz
    end
end
M.invRigid = invRigid

-- The deepest a capsule (model space: p-q, radius r) is pushed into the grid's
-- triangles, less the ones `skip(o)` excuses: returns the distance (huge if none is
-- within r) and the triangle's offset. Every cube along the capsule is visited a
-- piece of the segment at a time, so a long slanting limb does not visit the whole
-- box round it.
local function deepest(g, p, px, py, pz, qx, qy, qz, r, skip)
    local b = g.box
    if min(px, qx) - r > b[4] or max(px, qx) + r < b[1] or min(py, qy) - r > b[5] or max(py, qy) + r < b[2]
        or min(pz, qz) - r > b[6] or max(pz, qz) + r < b[3] then
        return huge
    end
    g.q = g.q + 1
    local stamp, q, cells, sph = g.stamp, g.q, g.cells, g.sph
    local best, bestO = r * r, nil
    local dx, dy, dz = qx - px, qy - py, qz - pz
    local dd = dx * dx + dy * dy + dz * dz
    local inv = dd > EPS and 1 / dd or 0
    local len = sqrt(dd)
    local steps = max(1, math.ceil(len / CELL))
    for s = 0, steps - 1 do
        local t0, t1 = s / steps, (s + 1) / steps
        local sx, sy, sz = px + dx * t0, py + dy * t0, pz + dz * t0
        local ex, ey, ez = px + dx * t1, py + dy * t1, pz + dz * t1
        for i = cellOf(min(sx, ex) - r), cellOf(max(sx, ex) + r) do
            for j = cellOf(min(sy, ey) - r), cellOf(max(sy, ey) + r) do
                for k = cellOf(min(sz, ez) - r), cellOf(max(sz, ez) + r) do
                    local c = cells[((i + HALF) * KEY + (j + HALF)) * KEY + (k + HALF)]
                    if c then
                        for n = 1, #c do
                            local t = c[n]
                            if stamp[t] ~= q then
                                stamp[t] = q
                                -- the sphere round the triangle first: far from the segment, done
                                local h = t * 4 - 4
                                local wx, wy, wz = sph[h + 1] - px, sph[h + 2] - py, sph[h + 3] - pz
                                local u = (wx * dx + wy * dy + wz * dz) * inv
                                if u < 0 then u = 0 elseif u > 1 then u = 1 end
                                wx, wy, wz = wx - dx * u, wy - dy * u, wz - dz * u
                                local dc = sqrt(wx * wx + wy * wy + wz * wz) - sph[h + 4]
                                if dc < 0 or dc * dc < best then
                                    local o = h / 4 * 9
                                    local ax, ay, az, bx, by, bz, cx, cy, cz = p[o + 1], p[o + 2], p[o + 3], p[o + 4], p[o + 5], p[o + 6], p[o + 7], p[o + 8], p[o + 9]
                                    local d = segTri2(px, py, pz, qx, qy, qz, ax, ay, az, bx, by, bz, cx, cy, cz)
                                    if d < best and not (skip and skip(o, ax, ay, az, bx, by, bz, cx, cy, cz)) then
                                        best, bestO = d, o
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if not bestO then return huge end
    return sqrt(best), bestO
end
M.deepest = deepest

--------------------------------------------------------------------------
-- THE CONTACTS EVERY VEHICLE ALLOWS. See the header for the rule's fields.
--------------------------------------------------------------------------
M.ALLOW = {
    -- A closed fist is round its grip: the grip is inside the hand, the fingers are on the
    -- brake lever and the bar runs on out of the fist. The bars' group (grips, levers, the
    -- bar, a bell's lever) is the hands'.
    { part = "_hand$", group = { "^bars$", "^bellLever$" }, why = "a fist round its grip" },
    -- ...and whatever else a hand is told to hold, near where it is told to (a stoker's
    -- bars, a grab's deck, a passenger's hand on the rider: that one is body on body).
    { part = "_hand$", near = "Hand", within = 3.5, why = "the hand on what it holds" },
    -- The ball of the foot is put on the pedal's spindle (cl_rider.lua), so the pedal is
    -- in the sole.
    { part = "_foot$", group = "^pedal$", why = "the foot round its pedal" },
    -- A foot on what it stands on -- a peg, a footpeg, the deck -- presses into it no
    -- further than the sole's own give: deeper, it has sunk in.
    -- (within a foot's length of its target: a deck's foot target is the ANKLE, cl_rider.lua's
    -- `targets.ankles`, and the sole runs 3 behind it to 9 ahead)
    { part = "_foot$", near = "Foot", within = 9, depth = 1.5, why = "the foot on what it stands on" },
    -- Sat on a saddle, the hips sink into it a little (the seat is where the game's pod
    -- puts the body, and a saddle is drawn as a hard shell): near the person's own seat
    -- (`targets[who].seat`), as far as that. Not a saddle anywhere else: a passenger's
    -- thighs in the rider's saddle are a clip.
    -- The pelvis bone sits 10 units from its pod (kleiner seated: 5 ahead, 9 up), so the
    -- seat under it is that far off; a saddle runs 5 or 6 units either side of its middle,
    -- and a rider sits on its nose as much as anywhere; sat on, the flesh under the capsule
    -- gives a couple of units more than the capsule's own half unit inside the skin.
    { part = { "^pelvis$", "_thigh$" }, near = "seat", within = 12, depth = 3.0, why = "sat on the saddle" },
    { part = { "^pelvis$", "_thigh$" }, mat = { "^seat$", "^leather$" }, near = "seat", within = 13, depth = 3.0,
      why = "sat on the saddle's nose" },
    -- A skate's boot is on its own foot, its cuff round the ankle (rec.tag: the side of
    -- the boot drawn).
    { part = { "_foot$", "_shin$" }, sameSide = true, why = "the skate's boot on its own foot" },
}

-- A pattern, or a list of them (any).
local function like(s, pat)
    if pat == nil then return true end
    if type(pat) == "table" then
        for _, p in ipairs(pat) do if s:find(p) then return true end end
        return false
    end
    return s:find(pat) ~= nil
end
M.like = like

-- Does a rule match this piece and draw?
local function matches(rule, cap, name, mat)
    return like(cap.part, rule.part) and like(cap.who, rule.who) and like(name, rule.group) and like(mat or "", rule.mat)
end

-- The rules that match a piece and a draw, worked out once for each kind of pair (the
-- patterns are a dozen string searches, for every piece and every draw, every shot).
local ruleCache = setmetatable({}, { __mode = "k" })
local NONE = {}
local function rulesFor(allow, cap, d)
    local c = ruleCache[allow]
    if not c then c = {} ruleCache[allow] = c end
    local key = cap.who .. "|" .. cap.part .. "|" .. (cap.side or "") .. "|" .. d.name .. "|" .. (d.mat or "") .. "|" .. (d.tag or "")
    local list = c[key]
    if list then return list end
    for _, rule in ipairs(allow) do
        -- (a skate's boot is its own foot's, not the other's)
        if matches(rule, cap, d.name, d.mat) and not (rule.sameSide and d.tag ~= cap.side) then
            list = list or {}
            list[#list + 1] = rule
        end
    end
    list = list or NONE
    c[key] = list
    return list
end

local function targetFor(rule, cap, targets)
    local t = targets and targets[cap.who]
    if not t then return nil end
    local key = rule.near
    if key == "Foot" or key == "Hand" then key = (cap.side or "r") .. key end
    local v = t[key]
    if not v then return nil end
    if v.x then return v.x, v.y, v.z end
    return v[1], v[2], v[3]
end

-- Each capsule's deepest push into each group/material drawn this frame (and each tube).
-- opts: tol (report deeper than this, default 0), allow (rules, default M.ALLOW), targets
-- ({ [who] = { rFoot = Vector, ... } }), label (copied onto each hit), only (a piece
-- name pattern). Returns a list of hits { who, piece, part, with, group, mat, depth, label }.
function M.vehicleHits(caps, rec, opts)
    opts = opts or {}
    local tol, allow = opts.tol or 0, opts.allow or M.ALLOW
    local worst = {}
    local order = {}
    local function note(cap, with, group, mat, depth, tag)
        local k = cap.who .. "|" .. cap.name .. "|" .. with
        local h = worst[k]
        if not h then
            h = { who = cap.who, piece = cap.name, part = cap.part, with = with, group = group, mat = mat, depth = depth,
                  label = opts.label, tag = tag }
            worst[k] = h
            order[#order + 1] = h
        elseif depth > h.depth then
            h.depth = depth
        end
    end
    for _, d in ipairs(rec.draws) do
        local p = rec.meshes[d.mesh]
        local g = p and rec:grid(d.mesh)
        if g and g.n > 0 then
            local toModel, toWorld = invRigid(d.m)
            if not toModel then
                error("bodyclip: the group " .. d.name .. " is drawn under a matrix that is not a rotation and a translation")
            end
            for _, cap in ipairs(caps) do
                if not (opts.only and not cap.name:find(opts.only)) then
                    -- the rules for this piece and draw: excused outright, or near a target
                    local excused, near = false, nil
                    for _, rule in ipairs(rulesFor(allow, cap, d)) do
                        if rule.near then
                            local tx, ty, tz = targetFor(rule, cap, opts.targets)
                            if tx then
                                near = near or {}
                                local mx, my, mz = toModel(tx, ty, tz)
                                near[#near + 1] = { mx, my, mz, rule.within or 3, rule.depth }
                            end
                        elseif not rule.depth then
                            excused = true
                            break
                        else
                            near = near or {}
                            near[#near + 1] = { nil, nil, nil, nil, rule.depth }
                        end
                    end
                    if not excused then
                        local px, py, pz = toModel(cap.ax, cap.ay, cap.az)
                        local qx, qy, qz = toModel(cap.bx, cap.by, cap.bz)
                        local r = cap.r
                        local skip
                        if near then
                            -- a triangle near an allowed target is excused, as deep as the rule says
                            skip = function(o, ax, ay, az, bx, by, bz, cx, cy, cz)
                                for _, n in ipairs(near) do
                                    local ok = n[1] == nil or pointTri2(n[1], n[2], n[3], ax, ay, az, bx, by, bz, cx, cy, cz) <= n[4] * n[4]
                                    if ok then
                                        if not n[5] then return true end
                                        local dd = segTri2(px, py, pz, qx, qy, qz, ax, ay, az, bx, by, bz, cx, cy, cz)
                                        if r - sqrt(dd) <= n[5] then return true end
                                    end
                                end
                                return false
                            end
                        end
                        local dist = deepest(g, p, px, py, pz, qx, qy, qz, r, skip)
                        if r - dist > tol then note(cap, d.name .. "/" .. d.mat, d.name, d.mat, r - dist, d.tag) end
                    end
                end
            end
        end
    end
    -- TUBES (cables, a kickstand, a shock's spring): capsules themselves, as group "tube".
    for _, t in ipairs(rec.tubes) do
        for i = 1, #t - 1 do
            local a, b = t[i], t[i + 1]
            for _, cap in ipairs(caps) do
                if not (opts.only and not cap.name:find(opts.only)) then
                    local d = sqrt(segSeg2(cap.ax, cap.ay, cap.az, cap.bx, cap.by, cap.bz, a[1], a[2], a[3], b[1], b[2], b[3])) - t.r
                    local depth = cap.r - d
                    if depth > tol then
                        local excused = false
                        for _, rule in ipairs(allow) do
                            if matches(rule, cap, "tube", t.role) and not (rule.sameSide and t.tag ~= cap.side) then
                                local ok = true
                                if rule.near then
                                    local tx, ty, tz = targetFor(rule, cap, opts.targets)
                                    local w = rule.within or 3
                                    ok = tx ~= nil and segSeg2(tx, ty, tz, tx, ty, tz, a[1], a[2], a[3], b[1], b[2], b[3]) <= w * w
                                end
                                if ok and (not rule.depth or depth <= rule.depth) then excused = true break end
                            end
                        end
                        if not excused then note(cap, "tube/" .. t.role, "tube", t.role, depth, t.tag) end
                    end
                end
            end
        end
    end
    return order
end

--------------------------------------------------------------------------
-- BODY ON BODY. Pieces that join are left alone (a thigh is meant to meet the
-- pelvis); everything else is checked.
--------------------------------------------------------------------------
-- THE TRUNK is one thing: the pelvis, belly, chest, its top and the neck are slices of
-- it, and a bend of the spine squeezes them together as skin does.
local TRUNK = { pelvis = true, belly = true, chest = true, chest_hi = true, neck = true }
-- Which parts JOIN, by part (sides stripped): a limb's own pieces, a limb and the trunk
-- where it is fixed on, the head on the neck and the top of the chest.
local JOINS = {
    upperarm = { chest = true, chest_hi = true, neck = true },
    thigh = { pelvis = true },
    head = { neck = true, chest_hi = true },
}
local LIMB = { upperarm = "arm", forearm = "arm", hand = "arm", thigh = "leg", shin = "leg", foot = "leg" }
-- ...and two PIECES that meet at a crease: the top of the thigh folds up against the
-- belly at the hip (kleiner's own standing idle has them 2.2 into each other: the
-- capsules' ends round the joint, not a fault of the pose). The thigh's knee half is
-- still checked against the belly: a knee in the stomach is.
local JOIN_PIECES = {
    { "^belly$", "_thigh_hip$" },
}

local function bare(part) return (part:gsub("^[rl]_", "")) end

-- Are these two pieces of ONE body joined (not to be checked against each other)?
function M.joined(a, b)
    if a.name == b.name then return true end
    local pa, pb = bare(a.part), bare(b.part)
    if TRUNK[pa] and TRUNK[pb] then return true end
    -- the same limb, from shoulder to fingertip or hip to toe
    if a.side and a.side == b.side and LIMB[pa] and LIMB[pa] == LIMB[pb] then return true end
    if (JOINS[pa] and JOINS[pa][pb]) or (JOINS[pb] and JOINS[pb][pa]) then return true end
    for _, j in ipairs(JOIN_PIECES) do
        if (a.name:find(j[1]) and b.name:find(j[2])) or (b.name:find(j[1]) and a.name:find(j[2])) then return true end
    end
    return false
end

-- Body on body: capsA against capsB (two bodies: every pair), or capsA against itself
-- (capsB nil: the pairs that do not join). opts: tol, allow (a list of
-- { a = part pattern, b = part pattern, whoA, whoB, why }: excused pairs, either way
-- round), label. Returns hits { who, piece, part, with, withWho, withPart, depth, label }.
function M.bodyHits(capsA, capsB, opts)
    opts = opts or {}
    local tol, allow = opts.tol or 0, opts.allow or {}
    local out, worst = {}, {}
    local self = capsB == nil
    capsB = capsB or capsA
    local function excused(a, b)
        for _, rule in ipairs(allow) do
            local function m(x, y)
                return like(x.part, rule.a) and like(y.part, rule.b) and like(x.who, rule.whoA) and like(y.who, rule.whoB)
            end
            if m(a, b) or m(b, a) then return true end
        end
        return false
    end
    for i, a in ipairs(capsA) do
        for j = self and i + 1 or 1, #capsB do
            local b = capsB[j]
            if not (self and M.joined(a, b)) then
                local reach = a.r + b.r
                -- (bounds first: most pairs are a body's length apart)
                if min(a.ax, a.bx) - reach <= max(b.ax, b.bx) and min(b.ax, b.bx) - reach <= max(a.ax, a.bx)
                    and min(a.ay, a.by) - reach <= max(b.ay, b.by) and min(b.ay, b.by) - reach <= max(a.ay, a.by)
                    and min(a.az, a.bz) - reach <= max(b.az, b.bz) and min(b.az, b.bz) - reach <= max(a.az, a.bz) then
                    local d = sqrt(segSeg2(a.ax, a.ay, a.az, a.bx, a.by, a.bz, b.ax, b.ay, b.az, b.bx, b.by, b.bz))
                    local depth = reach - d
                    if depth > tol and not excused(a, b) then
                        -- one hit per pair of PARTS, the deepest of their pieces
                        local k = a.who .. "|" .. a.part .. "|" .. b.who .. "|" .. b.part
                        local h = worst[k]
                        if not h then
                            h = { who = a.who, piece = a.name, part = a.part, withWho = b.who, withPiece = b.name, withPart = b.part,
                                  with = (b.who ~= a.who and (b.who .. ":") or "") .. b.part, depth = depth, label = opts.label }
                            worst[k] = h
                            out[#out + 1] = h
                        elseif depth > h.depth then
                            h.depth, h.piece, h.withPiece = depth, a.name, b.name
                        end
                    end
                end
            end
        end
    end
    return out
end

-- One body on another: a passenger's hands rest on the rider's shoulders
-- (cl_passenger.lua: on the rider's upper arms, a soft grip).
M.CROSS_ALLOW = {
    { whoA = { "^pax$", "^child$" }, a = "_hand$", whoB = "^rider$", b = { "_upperarm$", "^chest", "^neck$" },
      why = "the passenger's hands on the rider's shoulders" },
}

--------------------------------------------------------------------------
-- EVERYTHING AT ONCE
--------------------------------------------------------------------------
-- Everyone on a vehicle this frame: `people` a list of { who, src, targets } (src a
-- player or a bones table, targets their IK targets and `seat`), `rec` the record of
-- what was drawn. Every body against the vehicle, against itself and against each
-- other. opts: tol (vehicle), bodyTol, allow, crossAllow, label, set. Returns the hits,
-- each with `body` true when the other thing is a body.
function M.check(people, rec, opts)
    opts = opts or {}
    local set = opts.set or M.load()
    local caps, targets, hits = {}, {}, {}
    for i, p in ipairs(people) do
        caps[i] = M.capsules(p.src, set, p.who)
        targets[p.who] = p.targets
    end
    local function add(list, body)
        for _, h in ipairs(list) do h.body = body hits[#hits + 1] = h end
    end
    for i, p in ipairs(people) do
        if rec then
            add(M.vehicleHits(caps[i], rec, { tol = opts.tol, allow = opts.allow, targets = targets, label = opts.label }), false)
        end
        add(M.bodyHits(caps[i], nil, { tol = opts.bodyTol or opts.tol, label = opts.label }), true)
        for j = i + 1, #people do
            add(M.bodyHits(caps[i], caps[j], { tol = opts.bodyTol or opts.tol, allow = opts.crossAllow or M.CROSS_ALLOW,
                label = opts.label }), true)
        end
    end
    return hits
end

-- Every shot of a studio.lua JSON (decoded: lib/json's J.decode), checked as M.check
-- does: the rider (`bones`) and a passenger (`paxBones`), the shot's own targets for
-- the rider's hands and feet. Returns the hits, each labelled with its shot.
function M.studioHits(data, opts)
    opts = opts or {}
    local rec = M.fromStudio(data)
    local out = {}
    for _, shot in ipairs(data.shots) do
        rec:studioShot(shot)
        local people = { { who = "rider", src = shot.bones, targets = shot.targets } }
        if shot.paxBones then people[2] = { who = "pax", src = shot.paxBones } end
        local o = {}
        for k, v in pairs(opts) do o[k] = v end
        o.label = shot.label
        for _, h in ipairs(M.check(people, rec, o)) do out[#out + 1] = h end
    end
    return out
end

-- A hit as one line.
function M.describe(h)
    return string.format("%s %s into %s by %.2f%s", h.who, h.part, h.with, h.depth, h.label and (" (" .. h.label .. ")") or "")
end

return M
