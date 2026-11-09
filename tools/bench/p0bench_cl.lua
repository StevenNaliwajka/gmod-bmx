-- Is the bike's per-part point mapping worth rewriting? (docs/PERFORMANCE.md, "Next round":
-- the per-part matrix maths in ENT:DrawDetailed.) On the real client, time the two ways of
-- putting a chassis point in the world that the draw could use, 200k times each:
--   A  ent:LocalToWorld(m + lift)          what P0 does now, once per point
--   B  o + ex * m.x + ey * m.y + ez * m.z  a basis worked out once per frame
-- and the whole of matFromMap's work for one part (four points through A, then the matrix).
-- Writes data/probe/p0.txt. Run from tools/bench/sp.sh (singleplayer, the session up).
local ent = LocalPlayer()
local N = 200000
local lift = Vector(0, 0, 1.5)
local pts = {}
for i = 1, 64 do pts[i] = Vector(math.random(-20, 20), math.random(-5, 5), math.random(0, 40)) end
local o = ent:LocalToWorld(lift)
local ex = ent:LocalToWorld(lift + Vector(1, 0, 0)) - o
local ey = ent:LocalToWorld(lift + Vector(0, 1, 0)) - o
local ez = ent:LocalToWorld(lift + Vector(0, 0, 1)) - o

local function time(f)
    collectgarbage("collect")
    local t0 = SysTime()
    f()
    return (SysTime() - t0) / N * 1e6
end
local a = time(function() for i = 1, N do local m = pts[i % 64 + 1] local _ = ent:LocalToWorld(m + lift) end end)
local b = time(function() for i = 1, N do local m = pts[i % 64 + 1] local _ = o + ex * m.x + ey * m.y + ez * m.z end end)
local maxErr = 0
for _, m in ipairs(pts) do
    maxErr = math.max(maxErr, (ent:LocalToWorld(m + lift) - (o + ex * m.x + ey * m.y + ez * m.z)):Length())
end
local mat = time(function()
    for i = 1, N / 4 do
        local f = function(m) return ent:LocalToWorld(m + lift) end
        local p = f(Vector(0, 0, 0))
        local _ = BMX.BikeMesh.Matrix(p, f(Vector(1, 0, 0)) - p, f(Vector(0, 1, 0)) - p, f(Vector(0, 0, 1)) - p)
    end
end) * 4
file.CreateDir("probe")
file.Write("probe/p0.txt", string.format(
    "A LocalToWorld per point %.3f us | B cached basis %.3f us | B/A %.2f | max difference %.2g u | one part's matrix (4 points + Matrix) %.3f us\n",
    a, b, b / a, maxErr, mat))
