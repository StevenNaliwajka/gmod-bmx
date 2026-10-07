-- Export the procedural bike (lua/bmx/cl_bikegeo.lua) for the offline
-- preview: one block per bucket, a header line then one vertex a line.
--
--   lua5.1 tools/bike/export.lua [k] [radius] > bike.txt
--   python3 tools/bike/preview.py bike.txt out.png [view]
--
-- Runs the real builder in a stock Lua, the same code the client runs.
local here = (arg and arg[0] or "tools/bike/export.lua"):match("^(.*)/[^/]*$") or "."
dofile(here .. "/../../lua/bmx/cl_bikegeo.lua")
local k = tonumber(arg[1] or "1")
local radius = tonumber(arg[2] or tostring(10 * k))
local t0 = os.clock()
local M = BMX.BikeGeo.Build({ k = k, radius = radius })
io.stderr:write(string.format("built in %.2fs\n", os.clock() - t0))
local st = BMX.BikeGeo.Stats(M)
for _, g in ipairs(M.order) do io.stderr:write(string.format("  %-8s %6d tris\n", g, st[g])) end
io.stderr:write(string.format("  total    %6d tris\n", st.total))
local L = M.layout
io.write(string.format("L %g %g %g %g\n", L.k, L.steer[1], L.steer[2], L.steer[3]))
local out = {}
for _, g in ipairs(M.order) do
    for _, b in ipairs(M.groups[g]) do
        io.write(string.format("B %s %s %d %d\n", g, b.mat, b.detail and 1 or 0, #b.v))
        for _, v in ipairs(b.v) do
            io.write(string.format("%.4f %.4f %.4f %.3f %.3f %.3f\n", v.p[1], v.p[2], v.p[3], v.n[1], v.n[2], v.n[3]))
        end
    end
end
