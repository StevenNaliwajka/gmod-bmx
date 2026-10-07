--[[--------------------------------------------------------------------------
    tests/lib/hull.lua

    Convex hulls, checked the slow honest way: every triple of points is a
    candidate plane, and a plane with every other point on one side of it is a
    face of the hull. From the faces: whether the point set is a proper solid
    (at least four faces, a volume, every edge shared by exactly two faces),
    whether a point is inside it, and where a vertical line enters and leaves
    it. O(n^4) in the points, and a park piece's hulls have a dozen at most.

    The engine builds its own hull from the points it is given (a point set
    is always "convex"), so what can actually go wrong is a degenerate set:
    flat, collinear, repeated or NaN points. These checks catch exactly that.
----------------------------------------------------------------------------]]

local H = {}

local TOL = 1e-4

local function sub(a, b) return { a.x - b.x, a.y - b.y, a.z - b.z } end
local function cross(u, v) return { u[2] * v[3] - u[3] * v[2], u[3] * v[1] - u[1] * v[3], u[1] * v[2] - u[2] * v[1] } end
local function dot(u, v) return u[1] * v[1] + u[2] * v[2] + u[3] * v[3] end

-- The faces of the hull of `pts` (Vectors). Each: { n = {x,y,z} outward unit,
-- d, idx = { point indices on the plane, ordered round it } }.
function H.faces(pts)
    local n = #pts
    local seen, faces = {}, {}
    for i = 1, n - 2 do
        for j = i + 1, n - 1 do
            for k = j + 1, n do
                local c = cross(sub(pts[j], pts[i]), sub(pts[k], pts[i]))
                local len = math.sqrt(dot(c, c))
                if len > 1e-6 then
                    local nn = { c[1] / len, c[2] / len, c[3] / len }
                    local d = nn[1] * pts[i].x + nn[2] * pts[i].y + nn[3] * pts[i].z
                    local pos, neg, on = 0, 0, {}
                    for m = 1, n do
                        local s = nn[1] * pts[m].x + nn[2] * pts[m].y + nn[3] * pts[m].z - d
                        if s > TOL then pos = pos + 1 elseif s < -TOL then neg = neg + 1 else on[#on + 1] = m end
                    end
                    if pos == 0 or neg == 0 then
                        if pos > 0 then nn, d = { -nn[1], -nn[2], -nn[3] }, -d end
                        local key = table.concat(on, ",")
                        if not seen[key] then
                            seen[key] = true
                            faces[#faces + 1] = { n = nn, d = d, idx = on }
                        end
                    end
                end
            end
        end
    end
    -- order each face's points round its centre
    for _, f in ipairs(faces) do
        local cx, cy, cz = 0, 0, 0
        for _, m in ipairs(f.idx) do cx, cy, cz = cx + pts[m].x, cy + pts[m].y, cz + pts[m].z end
        local k = #f.idx
        cx, cy, cz = cx / k, cy / k, cz / k
        local ref = sub(pts[f.idx[1]], { x = cx, y = cy, z = cz })
        local rl = math.sqrt(dot(ref, ref))
        local u = { ref[1] / rl, ref[2] / rl, ref[3] / rl }
        local v = cross(f.n, u)
        local ang = {}
        for _, m in ipairs(f.idx) do
            local r = sub(pts[m], { x = cx, y = cy, z = cz })
            ang[m] = math.atan2(dot(r, v), dot(r, u))
        end
        table.sort(f.idx, function(a, b) return ang[a] < ang[b] end)
        f.centre = { cx, cy, cz }
    end
    return faces
end

-- { ok, why, faces, volume }: a proper, closed solid with a volume.
function H.check(pts)
    if #pts < 4 then return { ok = false, why = "fewer than four points" } end
    for i, p in ipairs(pts) do
        for _, c in ipairs({ p.x, p.y, p.z }) do
            if c ~= c or c == math.huge or c == -math.huge then
                return { ok = false, why = "point " .. i .. " is not finite" }
            end
        end
    end
    local faces = H.faces(pts)
    if #faces < 4 then return { ok = false, why = "flat or collinear: " .. #faces .. " faces" } end
    -- closed: every edge of every face is an edge of exactly one other face
    local edges = {}
    for _, f in ipairs(faces) do
        local k = #f.idx
        for i = 1, k do
            local a, b = f.idx[i], f.idx[i % k + 1]
            local key = math.min(a, b) .. "-" .. math.max(a, b)
            edges[key] = (edges[key] or 0) + 1
        end
    end
    for key, c in pairs(edges) do
        if c ~= 2 then return { ok = false, why = "edge " .. key .. " belongs to " .. c .. " faces", faces = faces } end
    end
    -- volume: the faces as cones from the centroid of the points
    local mx, my, mz = 0, 0, 0
    for _, p in ipairs(pts) do mx, my, mz = mx + p.x, my + p.y, mz + p.z end
    mx, my, mz = mx / #pts, my / #pts, mz / #pts
    local vol = 0
    for _, f in ipairs(faces) do
        local area = 0
        local p1 = pts[f.idx[1]]
        for i = 2, #f.idx - 1 do
            local c = cross(sub(pts[f.idx[i]], p1), sub(pts[f.idx[i + 1]], p1))
            area = area + 0.5 * math.sqrt(dot(c, c))
        end
        local h = f.d - (f.n[1] * mx + f.n[2] * my + f.n[3] * mz)
        vol = vol + area * h / 3
    end
    if vol < 1e-3 then return { ok = false, why = "no volume (" .. vol .. ")", faces = faces } end
    return { ok = true, faces = faces, volume = vol }
end

function H.contains(faces, p, tol)
    tol = tol or 1e-3
    for _, f in ipairs(faces) do
        if f.n[1] * p.x + f.n[2] * p.y + f.n[3] * p.z - f.d > tol then return false end
    end
    return true
end

-- Where the vertical line at (x, y) is inside the hull: zlo, zhi or nil.
function H.column(faces, x, y)
    local lo, hi = -math.huge, math.huge
    for _, f in ipairs(faces) do
        local rest = f.d - f.n[1] * x - f.n[2] * y
        local nz = f.n[3]
        if math.abs(nz) < 1e-9 then
            if rest < -1e-6 then return nil end
        elseif nz > 0 then
            hi = math.min(hi, rest / nz)
        else
            lo = math.max(lo, rest / nz)
        end
    end
    if lo > hi + 1e-6 then return nil end
    return lo, hi
end

return H
