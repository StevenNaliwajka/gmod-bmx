-- Export the bike rack (lua/entities/bmx_bike_rack/cl_init.lua) in
-- tools/bike/export.lua's format, for tools/bike/showcase.py. The rack is drawn
-- in code from BMX.Draw tubes; this runs its own ENT:Draw with a BMX.Draw that
-- records each tube instead of drawing it, then makes each one a cylinder.
--
--   lua5.1 tools/bike/export_rack.lua [loaded 0-2] > rack.txt
local here = (arg and arg[0] or "tools/bike/export_rack.lua"):match("^(.*)/[^/]*$") or "."
local root = here .. "/../.."
local loaded = tonumber(arg and arg[1] or "0") or 0

-- Just enough of GMod for the drawer.
local V = {}
V.__index = V
function Vector(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, V) end
function Color(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end
function include() end
function IsValid() return false end

local tubes = {}
local COL_PART, COL_CHROME = Color(34, 34, 38), Color(200, 204, 212)   -- entities/bmx_base/cl_init.lua
BMX = { Draw = { COL = { part = COL_PART, chrome = COL_CHROME },
                 tube = function(a, b, width, col) tubes[#tubes + 1] = { a = a, b = b, w = width, col = col } end } }
ENT = {}
dofile(root .. "/lua/entities/bmx_bike_rack/cl_init.lua")
local self = setmetatable({}, { __index = ENT })
function self:LocalToWorld(v) return v end
function self:GetLoaded() return loaded end
function self:GetCarried() return false end
self:Draw()

-- A colour is a material: the part and chrome colours are the bikes' own roles.
local function role(c)
    if c == COL_PART then return "black" end
    if c == COL_CHROME then return "chrome" end
    return string.format("rack_%d_%d_%d", c.r, c.g, c.b)
end

local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function cross(a, b) return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] } end
local function norm(a) local l = math.sqrt(a[1] ^ 2 + a[2] ^ 2 + a[3] ^ 2) return { a[1] / l, a[2] / l, a[3] / l } end

local buckets, order, own = {}, {}, {}
local SIDES = 20
for _, t in ipairs(tubes) do
    local a, b = { t.a.x, t.a.y, t.a.z }, { t.b.x, t.b.y, t.b.z }
    local ax = norm(sub(b, a))
    local hint = math.abs(ax[3]) < 0.9 and { 0, 0, 1 } or { 1, 0, 0 }
    local u = norm(cross(ax, hint))
    local v = cross(ax, u)
    local r = t.w / 2
    local key = role(t.col)
    if key:sub(1, 5) == "rack_" then own[key] = t.col end
    if not buckets[key] then buckets[key] = {} order[#order + 1] = key end
    local B = buckets[key]
    local function ring(c, i)
        local ang = 2 * math.pi * i / SIDES
        local n = { u[1] * math.cos(ang) + v[1] * math.sin(ang), u[2] * math.cos(ang) + v[2] * math.sin(ang),
                    u[3] * math.cos(ang) + v[3] * math.sin(ang) }
        return { c[1] + n[1] * r, c[2] + n[2] * r, c[3] + n[3] * r }, n
    end
    for i = 0, SIDES - 1 do
        local p1, n1 = ring(a, i)
        local p2, n2 = ring(a, i + 1)
        local p3 = ring(b, i)
        local p4 = ring(b, i + 1)
        for _, q in ipairs({ { p1, n1 }, { p2, n2 }, { p4, n2 }, { p1, n1 }, { p4, n2 }, { p3, n1 } }) do B[#B + 1] = q end
        -- end caps
        local na, nb = { -ax[1], -ax[2], -ax[3] }, ax
        for _, q in ipairs({ { a, na }, { p2, na }, { p1, na }, { b, nb }, { p3, nb }, { p4, nb } }) do B[#B + 1] = q end
    end
end

io.write("L 1 0 0 1\n")
for key, c in pairs(own) do io.write(string.format("C %s %d %d %d\n", key, c.r, c.g, c.b)) end
for _, key in ipairs(order) do
    local B = buckets[key]
    io.write(string.format("B rack %s 0 %d\n", key, #B))
    for _, q in ipairs(B) do
        local p, n = q[1], q[2]
        io.write(string.format("%.4f %.4f %.4f %.3f %.3f %.3f\n", p[1], p[2], p[3], n[1], n[2], n[3]))
    end
end
io.stderr:write(string.format("rack: %d tubes, loaded %d\n", #tubes, loaded))
