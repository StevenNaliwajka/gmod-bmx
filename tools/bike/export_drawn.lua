-- Export the things the addon draws in code from BMX.Draw primitives (tubes,
-- rings, boxes, balls), in tools/bike/export.lua's format, for
-- tools/bike/showcase.py. Each runs its own drawing code against a BMX.Draw that
-- records the primitives instead of drawing them; each primitive becomes triangles.
--
--   lua5.1 tools/bike/export_drawn.lua rack [loaded 0-2] > rack.txt
--        the bike rack (entities/bmx_bike_rack/cl_init.lua), a model of its own
--   lua5.1 tools/bike/export_drawn.lua lock > lock.txt
--        the bike lock's chain and padlock (BMX.DrawLock, bmx/cl_oddbikes.lua) on
--        the stock BMX, in the bike's space: no L line, so it appends to a bike
--        export (cat bmx.txt lock.txt > bmx_locked.txt)
local here = (arg and arg[0] or "tools/bike/export_drawn.lua"):match("^(.*)/[^/]*$") or "."
local root = here .. "/../.."
local what = arg and arg[1] or "rack"

-- Just enough of GMod for a drawer: vectors that add, scale and normalise.
local V = {}
V.__index = V
function Vector(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, V) end
V.__add = function(a, b) return Vector(a.x + b.x, a.y + b.y, a.z + b.z) end
V.__sub = function(a, b) return Vector(a.x - b.x, a.y - b.y, a.z - b.z) end
V.__unm = function(a) return Vector(-a.x, -a.y, -a.z) end
V.__mul = function(a, b)
    if type(a) == "number" then a, b = b, a end
    return Vector(a.x * b, a.y * b, a.z * b)
end
function V:Length() return math.sqrt(self.x ^ 2 + self.y ^ 2 + self.z ^ 2) end
function V:GetNormalized() local l = self:Length() return Vector(self.x / l, self.y / l, self.z / l) end
function Color(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end
function Angle() return {} end
function include() end
function IsValid() return false end

-- The recorder: BMX.Draw's primitives, as entities/bmx_base/cl_init.lua shapes them.
local prims = {}
local COL_PART, COL_CHROME = Color(34, 34, 38), Color(200, 204, 212)   -- entities/bmx_base/cl_init.lua
local function tube(a, b, width, col) prims[#prims + 1] = { kind = "tube", a = a, b = b, w = width, col = col } end
local function ring(center, e1, e2, radius, width, col, segments)    -- as cl_init.lua's ring: tubes round a circle
    local prev
    for i = 0, segments do
        local t = (i / segments) * math.pi * 2
        local p = center + (e1 * math.cos(t) + e2 * math.sin(t)) * radius
        if prev then
            local d = (p - prev):GetNormalized() * (width * 0.5)
            tube(prev - d, p + d, width, col)
        end
        prev = p
    end
end
local function solid(kind, p, ang, dims, col) prims[#prims + 1] = { kind = "box", p = p, dims = dims, col = col } end
local function joint(p, dia, col) prims[#prims + 1] = { kind = "ball", p = p, d = dia, col = col } end
BMX = { Draw = { COL = { part = COL_PART, chrome = COL_CHROME }, MAT = {},
                 tube = tube, ring = ring, solid = solid, joint = joint } }

local emitL = true
if what == "rack" then
    local loaded = tonumber(arg[2] or "0") or 0
    ENT = {}
    dofile(root .. "/lua/entities/bmx_bike_rack/cl_init.lua")
    local self = setmetatable({}, { __index = ENT })
    function self:LocalToWorld(v) return v end
    function self:GetLoaded() return loaded end
    function self:GetCarried() return false end
    self:Draw()
elseif what == "lock" then
    -- BMX.DrawLock is defined in cl_oddbikes.lua among the other drawers; take just it.
    local src = io.open(root .. "/lua/bmx/cl_oddbikes.lua"):read("*a")
    local body = src:match("(function BMX%.DrawLock%(ent%).-\nend)\n")
    assert(body, "BMX.DrawLock not found in cl_oddbikes.lua")
    assert(loadstring(body))()
    local ent = {}                               -- the stock BMX (sh_config.lua: 39 wheelbase, 10 radius)
    function ent:Cfg() return { Wheel = { wheelbase = 39, radius = 10 } } end
    function ent:GetForward() return Vector(1, 0, 0) end
    function ent:GetUp() return Vector(0, 0, 1) end
    function ent:GetRight() return Vector(0, -1, 0) end   -- Source's y is left
    function ent:GetAngles() return Angle() end
    function ent:LocalToWorld(v) return v end
    BMX.DrawLock(ent)
    emitL = false
else
    error("export_drawn.lua: rack or lock, not " .. tostring(what))
end

-- A colour is a material: the part and chrome colours are the bikes' own roles.
local function role(c)
    if c == COL_PART then return "black" end
    if c == COL_CHROME then return "chrome" end
    return string.format("drawn_%d_%d_%d", c.r, c.g, c.b)
end
local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function cross(a, b) return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] } end
local function norm(a) local l = math.sqrt(a[1] ^ 2 + a[2] ^ 2 + a[3] ^ 2) return { a[1] / l, a[2] / l, a[3] / l } end
local function xyz(v) return { v.x, v.y, v.z } end

local buckets, order, own = {}, {}, {}
local function bucket(col)
    local key = role(col)
    if key:sub(1, 6) == "drawn_" then own[key] = col end
    if not buckets[key] then buckets[key] = {} order[#order + 1] = key end
    return buckets[key]
end
local SIDES = 20
for _, t in ipairs(prims) do
    local B = bucket(t.col)
    if t.kind == "tube" then
        local a, b = xyz(t.a), xyz(t.b)
        local ax = norm(sub(b, a))
        local hint = math.abs(ax[3]) < 0.9 and { 0, 0, 1 } or { 1, 0, 0 }
        local u = norm(cross(ax, hint))
        local v = cross(ax, u)
        local r = t.w / 2
        local function at(c, i)
            local g = 2 * math.pi * i / SIDES
            local n = { u[1] * math.cos(g) + v[1] * math.sin(g), u[2] * math.cos(g) + v[2] * math.sin(g),
                        u[3] * math.cos(g) + v[3] * math.sin(g) }
            return { c[1] + n[1] * r, c[2] + n[2] * r, c[3] + n[3] * r }, n
        end
        local na, nb = { -ax[1], -ax[2], -ax[3] }, ax
        for i = 0, SIDES - 1 do
            local p1, n1 = at(a, i)
            local p2, n2 = at(a, i + 1)
            local p3 = at(b, i)
            local p4 = at(b, i + 1)
            for _, q in ipairs({ { p1, n1 }, { p2, n2 }, { p4, n2 }, { p1, n1 }, { p4, n2 }, { p3, n1 },
                                 { a, na }, { p2, na }, { p1, na }, { b, nb }, { p3, nb }, { p4, nb } }) do
                B[#B + 1] = q
            end
        end
    elseif t.kind == "box" then
        local c, h = xyz(t.p), { t.dims.x / 2, t.dims.y / 2, t.dims.z / 2 }
        for axis = 1, 3 do
            for _, s in ipairs({ -1, 1 }) do
                local n = { 0, 0, 0 }
                n[axis] = s
                local i, j = axis % 3 + 1, (axis + 1) % 3 + 1
                local corner = function(a, b)
                    local p = { c[1], c[2], c[3] }
                    p[axis] = p[axis] + s * h[axis]; p[i] = p[i] + a * h[i]; p[j] = p[j] + b * h[j]
                    return p
                end
                local p1, p2, p3, p4 = corner(-1, -1), corner(1, -1), corner(1, 1), corner(-1, 1)
                for _, p in ipairs({ p1, p2, p3, p1, p3, p4 }) do B[#B + 1] = { p, n } end
            end
        end
    elseif t.kind == "ball" then
        local c, r, N = xyz(t.p), t.d / 2, 12
        local function pt(i, j)
            local th, ph = math.pi * i / N, 2 * math.pi * j / N
            local n = { math.sin(th) * math.cos(ph), math.sin(th) * math.sin(ph), math.cos(th) }
            return { c[1] + n[1] * r, c[2] + n[2] * r, c[3] + n[3] * r }, n
        end
        for i = 0, N - 1 do
            for j = 0, N - 1 do
                local a, na = pt(i, j); local b, nb = pt(i + 1, j)
                local cc, nc = pt(i + 1, j + 1); local d, nd = pt(i, j + 1)
                for _, q in ipairs({ { a, na }, { b, nb }, { cc, nc }, { a, na }, { cc, nc }, { d, nd } }) do B[#B + 1] = q end
            end
        end
    end
end

if emitL then io.write("L 1 0 0 1\n") end
for key, c in pairs(own) do io.write(string.format("C %s %d %d %d\n", key, c.r, c.g, c.b)) end
for _, key in ipairs(order) do
    local B = buckets[key]
    io.write(string.format("B %s %s 0 %d\n", what, key, #B))
    for _, q in ipairs(B) do
        local p, n = q[1], q[2]
        io.write(string.format("%.4f %.4f %.4f %.3f %.3f %.3f\n", p[1], p[2], p[3], n[1], n[2], n[3]))
    end
end
io.stderr:write(string.format("%s: %d primitives\n", what, #prims))
