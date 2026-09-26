--[[--------------------------------------------------------------------------
    tests/lib/vecang.lua

    Vector and Angle, with Source's conventions, in plain Lua 5.1.

    The one place in the shim where being subtly wrong would make every test
    lie, so the conventions are written out and test_shim.lua checks them
    against values worked by hand:

      * X forward, Y LEFT, Z up. Right-handed.
      * Angle(pitch, yaw, roll) in degrees. Positive PITCH is nose DOWN, which is
        the opposite of what the addon means by pitch; positive ROLL puts the
        right side down. AngleVectors below is Source's mathlib, transcribed.
      * Vector * Vector is component-wise, as in GMod.
----------------------------------------------------------------------------]]

local M = {}

local sqrt, sin, cos, rad, deg = math.sqrt, math.sin, math.cos, math.rad, math.deg
local atan2 = math.atan2

local VMT = {}
VMT.__index = VMT

local function V(x, y, z)
    return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, VMT)
end
M.Vector = function(x, y, z)
    if type(x) == "table" and getmetatable(x) == VMT then return V(x.x, x.y, x.z) end
    return V(x, y, z)
end

local function isvec(v) return type(v) == "table" and getmetatable(v) == VMT end
M.isvector = isvec

VMT.__add = function(a, b) return V(a.x + b.x, a.y + b.y, a.z + b.z) end
VMT.__sub = function(a, b) return V(a.x - b.x, a.y - b.y, a.z - b.z) end
VMT.__unm = function(a) return V(-a.x, -a.y, -a.z) end
VMT.__mul = function(a, b)
    if type(a) == "number" then return V(b.x * a, b.y * a, b.z * a) end
    if type(b) == "number" then return V(a.x * b, a.y * b, a.z * b) end
    return V(a.x * b.x, a.y * b.y, a.z * b.z)
end
VMT.__div = function(a, b)
    if type(b) == "number" then return V(a.x / b, a.y / b, a.z / b) end
    return V(a.x / b.x, a.y / b.y, a.z / b.z)
end
VMT.__eq = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
VMT.__tostring = function(a) return string.format("%g %g %g", a.x, a.y, a.z) end

function VMT:Dot(b) return self.x * b.x + self.y * b.y + self.z * b.z end
function VMT:Cross(b)
    return V(self.y * b.z - self.z * b.y,
             self.z * b.x - self.x * b.z,
             self.x * b.y - self.y * b.x)
end
function VMT:LengthSqr() return self.x * self.x + self.y * self.y + self.z * self.z end
function VMT:Length() return sqrt(self:LengthSqr()) end
function VMT:Distance(b) return (self - b):Length() end
function VMT:GetNormalized()
    local l = self:Length()
    if l == 0 then return V(0, 0, 0) end
    return V(self.x / l, self.y / l, self.z / l)
end
VMT.GetNormal = VMT.GetNormalized
function VMT:Normalize()
    local l = self:Length()
    if l > 0 then self.x, self.y, self.z = self.x / l, self.y / l, self.z / l end
end
function VMT:IsZero() return self.x == 0 and self.y == 0 and self.z == 0 end
function VMT:Set(b) self.x, self.y, self.z = b.x, b.y, b.z end

-- Direction -> Angle, roll 0. Source's VectorAngles.
function VMT:Angle()
    local x, y, z = self.x, self.y, self.z
    local yaw, pitch
    if x == 0 and y == 0 then
        yaw = 0
        pitch = z > 0 and 270 or 90
    else
        yaw = deg(atan2(y, x))
        if yaw < 0 then yaw = yaw + 360 end
        pitch = deg(atan2(-z, sqrt(x * x + y * y)))
        if pitch < 0 then pitch = pitch + 360 end
    end
    return M.Angle(pitch, yaw, 0)
end

--------------------------------------------------------------------------
local AMT = {}
AMT.__index = AMT

function M.Angle(p, y, r)
    if type(p) == "table" and getmetatable(p) == AMT then return M.Angle(p.p, p.y, p.r) end
    return setmetatable({ p = p or 0, y = y or 0, r = r or 0 }, AMT)
end
M.isangle = function(a) return type(a) == "table" and getmetatable(a) == AMT end
AMT.__tostring = function(a) return string.format("%g %g %g", a.p, a.y, a.r) end
AMT.__eq = function(a, b) return a.p == b.p and a.y == b.y and a.r == b.r end

-- Source mathlib AngleVectors. Returns forward, right, up.
function M.AngleVectors(a)
    local sp, cp = sin(rad(a.p)), cos(rad(a.p))
    local sy, cy = sin(rad(a.y)), cos(rad(a.y))
    local sr, cr = sin(rad(a.r)), cos(rad(a.r))

    local f = V(cp * cy, cp * sy, -sp)
    local r = V(-1 * sr * sp * cy + -1 * cr * -sy,
                -1 * sr * sp * sy + -1 * cr * cy,
                -1 * sr * cp)
    local u = V(cr * sp * cy + -sr * -sy,
                cr * sp * sy + -sr * cy,
                cr * cp)
    return f, r, u
end

function AMT:Forward() local f = M.AngleVectors(self) return f end
function AMT:Right() local _, r = M.AngleVectors(self) return r end
function AMT:Up() local _, _, u = M.AngleVectors(self) return u end

-- Orthonormal basis (forward, LEFT, up) -> Angle. Source's MatrixAngles, whose
-- matrix columns are exactly forward, left and up.
function M.BasisAngle(f, l, u)
    local xy = sqrt(f.x * f.x + f.y * f.y)
    local p, y, r
    if xy > 0.001 then
        y = deg(atan2(f.y, f.x))
        p = deg(atan2(-f.z, xy))
        r = deg(atan2(l.z, u.z))
    else
        y = deg(atan2(-l.x, l.y))
        p = deg(atan2(-f.z, xy))
        r = 0
    end
    return M.Angle(p, y, r)
end

return M
