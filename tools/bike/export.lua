-- Export a procedural vehicle model (lua/bmx/cl_bikegeo.lua and the kinds in
-- lua/bmx/cl_geo_*.lua) for the offline preview: one block per bucket, a header
-- line then one vertex a line, after the layout's anchors.
--
--   lua5.1 tools/bike/export.lua [k] [radius] > bike.txt            the BMX
--   lua5.1 tools/bike/export.lua kind=road > road.txt               a kind, at its
--        registry size (tools/bike/sizes.lua), or override any of
--        wb=48 r=13.8 rr=6 seat=-12.9,0,22.2 k=1.23
--   python3 tools/bike/preview.py bike.txt out.png [view]
--
-- Runs the real builders in a stock Lua, the same code the client runs.
local here = (arg and arg[0] or "tools/bike/export.lua"):match("^(.*)/[^/]*$") or "."
local root = here .. "/../.."
dofile(root .. "/lua/bmx/cl_bikegeo.lua")
local p = io.popen('ls "' .. root .. '/lua/bmx/" 2>/dev/null')
for f in p:lines() do
    if f:match("^cl_geo_.*%.lua$") then dofile(root .. "/lua/bmx/" .. f) end
end
p:close()

local opt = {}
local pos = {}
for _, a in ipairs(arg or {}) do
    local key, val = a:match("^(%w+)=(.*)$")
    if key then opt[key] = val else pos[#pos + 1] = a end
end
local G = BMX.BikeGeo
local build
if opt.kind and opt.kind ~= "bmx" then
    local sizes = dofile(here .. "/sizes.lua")
    local S = sizes[opt.kind] or {}
    local function vec(s) local x, y, z = s:match("([^,]+),([^,]+),([^,]+)") return { tonumber(x), tonumber(y), tonumber(z) } end
    build = {
        kind = opt.kind,
        wheelbase = tonumber(opt.wb or "") or S.wheelbase,
        radius = tonumber(opt.r or "") or S.radius,
        rearRadius = tonumber(opt.rr or "") or S.rearRadius,
        seat = opt.seat and vec(opt.seat) or S.seat,
        restLength = S.restLength,
        k = tonumber(opt.k or "") or (S.wheelbase and S.wheelbase / 39) or 1,
        extra = S.extra,
    }
else
    local k = tonumber(pos[1] or opt.k or "1")
    build = { k = k, radius = tonumber(pos[2] or opt.r or tostring(10 * k)) }
end
local t0 = os.clock()
local M = G.Build(build)
io.stderr:write(string.format("built %s in %.2fs\n", build.kind or "bmx", os.clock() - t0))
local st = G.Stats(M)
for _, g in ipairs(M.order) do io.stderr:write(string.format("  %-10s %6d tris\n", g, st[g])) end
io.stderr:write(string.format("  total      %6d tris\n", st.total))
local L = M.layout or {}
local steer = L.steer or { 0, 0, 1 }
io.write(string.format("L %g %g %g %g\n", L.k or 1, steer[1], steer[2], steer[3]))
-- anchors: vectors as A, numbers as N, nested tables flattened with dots
local function emit(prefix, t)
    for key, v in pairs(t) do
        local name = prefix .. tostring(key)
        if type(v) == "table" and type(v[1]) == "number" and #v == 3 then
            io.write(string.format("A %s %g %g %g\n", name, v[1], v[2], v[3]))
        elseif type(v) == "table" then
            emit(name .. ".", v)
        elseif type(v) == "number" then
            io.write(string.format("N %s %g\n", name, v))
        end
    end
end
emit("", L)
for _, g in ipairs(M.order) do
    for _, b in ipairs(M.groups[g]) do
        io.write(string.format("B %s %s %d %d\n", g, b.mat, b.detail and 1 or 0, #b.v))
        for _, v in ipairs(b.v) do
            io.write(string.format("%.4f %.4f %.4f %.3f %.3f %.3f\n", v.p[1], v.p[2], v.p[3], v.n[1], v.n[2], v.n[3]))
        end
    end
end
