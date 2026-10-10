-- Export a park piece (lua/bmx/sh_park.lua) in tools/bike/export.lua's format,
-- for tools/bike/showcase.py: its faces as triangles with flat normals, one
-- bucket per surface (wood, deck, metal...), and that surface's colour from
-- BMX.Park.Colors on a C line.
--
--   lua5.1 tools/bike/export_park.lua quarterpipe [size] [variant] > qp.txt
--   lua5.1 tools/bike/export_park.lua list           every shape and its variants
--   lua5.1 tools/bike/export_park.lua preset vert_ramp   a ready-made park, laid out
--        the way the game lays it out (BMX.Park.Layout)
--
-- size 1-3 is Small, Medium, Large; variant is the shape's own (a quarter
-- pipe's height, a ledge or a manual pad). The addon is booted the way the
-- offline suite boots it (tests/lib/gmod.lua), so the shapes are the real ones.
local here = (arg and arg[0] or "tools/bike/export_park.lua"):match("^(.*)/[^/]*$") or "."
package.path = here .. "/../../tests/?.lua;" .. package.path
local gmod = require("lib.gmod")
gmod.ROOT = here .. "/../.."
local F = require("lib.fixture")
local sv = F.server()
local P = sv.env.BMX.Park

local id = arg[1] or "list"
if id == "list" then
    for _, s in ipairs(P.Order) do
        local d = P.Shapes[s]
        io.write(s, "\t", d.name, "\t", d.variants and table.concat(d.variants, ", ") or "-", "\n")
    end
    return
end
-- The pieces to write: one, or every piece of a preset in its place.
local pieces = {}
if id == "preset" then
    local layout = P.Layout(arg[2] or "")
    assert(layout, "no park preset " .. tostring(arg[2]))
    for _, it in ipairs(layout) do
        pieces[#pieces + 1] = { b = P.Build(it.shape, it.params), x = it.x, y = it.y, yaw = it.yaw }
    end
else
    local b = P.Build(id, { tonumber(arg[2] or "2"), tonumber(arg[3] or "1") })
    assert(b, "no park shape " .. id)
    pieces[1] = { b = b, x = 0, y = 0, yaw = 0 }
end

local function xyz(v) return { v.x, v.y, v.z } end
local function sub(a, c) return { a[1] - c[1], a[2] - c[2], a[3] - c[3] } end
local function cross(a, c) return { a[2] * c[3] - a[3] * c[2], a[3] * c[1] - a[1] * c[3], a[1] * c[2] - a[2] * c[1] } end

local buckets, order = {}, {}
local nfaces = 0
local function face(pc, fc)
    local c, s = math.cos(math.rad(pc.yaw)), math.sin(math.rad(pc.yaw))
    local pts = {}
    for i, v in ipairs(fc.pts) do
        local q = xyz(v)
        pts[i] = { q[1] * c - q[2] * s + pc.x, q[1] * s + q[2] * c + pc.y, q[3] }
    end
    local n = cross(sub(pts[2], pts[1]), sub(pts[3], pts[1]))
    local l = math.sqrt(n[1] ^ 2 + n[2] ^ 2 + n[3] ^ 2)
    if l < 1e-9 then return end
    n = { n[1] / l, n[2] / l, n[3] / l }
    local key = "park_" .. fc.key
    if not buckets[key] then buckets[key] = {} order[#order + 1] = key end
    local B = buckets[key]
    for i = 2, #pts - 1 do                      -- a fan, as cl_park.lua draws it
        for _, p in ipairs({ pts[1], pts[i], pts[i + 1] }) do B[#B + 1] = { p, n } end
    end
end
for _, pc in ipairs(pieces) do
    for _, fc in ipairs(pc.b.faces) do
        nfaces = nfaces + 1
        face(pc, fc)
    end
end

io.write("L 1 0 0 1\n")
for key, c in pairs(P.Colors) do io.write(string.format("C park_%s %d %d %d\n", key, c[1], c[2], c[3])) end
for _, key in ipairs(order) do
    local B = buckets[key]
    io.write(string.format("B piece %s 0 %d\n", key, #B))
    for _, v in ipairs(B) do
        local p, n = v[1], v[2]
        io.write(string.format("%.4f %.4f %.4f %.3f %.3f %.3f\n", p[1], p[2], p[3], n[1], n[2], n[3]))
    end
end
io.stderr:write(string.format("%s: %d pieces, %d faces\n", id == "preset" and arg[2] or id, #pieces, nfaces))
