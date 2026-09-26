--[[--------------------------------------------------------------------------
    tests/lib/skeleton.lua

    A seated player skeleton, for testing the rider IK (cl_rider.lua).

    Bones follow ValveBiped's convention: each bone's local +X points down the
    bone toward its child. A bone's world transform is

        parent * translate(offset) * rotate(rest) * rotate(manipulation)

    which is how the engine composes ManipulateBoneAngles: after the animated
    pose, in the bone's own frame. The rest pose is roughly the seated
    `drive_airboat` one: thighs forward and down, knees bent, arms reaching
    forward. The lengths are a standard player's (thigh 17, shin 16,
    upper arm 12, forearm 11).

    It is a stand-in. Its value is that the IK is tested against a skeleton
    whose joints really compose, so "the foot reached the pedal" is measured,
    not assumed; whether it looks right on a real model is still a question
    for a person on a client.
----------------------------------------------------------------------------]]

local VA = require("lib.vecang")
local Vector, Angle = VA.Vector, VA.Angle

local M = {}

--------------------------------------------------------------------------
-- Matrix: a rotation (as a forward/left/up basis) and a translation.
--------------------------------------------------------------------------
local MMT = {}
MMT.__index = MMT

function M.Matrix()
    return setmetatable({ f = Vector(1, 0, 0), l = Vector(0, 1, 0), u = Vector(0, 0, 1),
                          t = Vector() }, MMT)
end

function MMT:SetAngles(a)
    local f, r, u = VA.AngleVectors(a)
    self.f, self.l, self.u = f, -r, u
end
function MMT:GetAngles() return VA.BasisAngle(self.f, self.l, self.u) end
function MMT:SetTranslation(v) self.t = Vector(v) end
function MMT:GetTranslation() return Vector(self.t) end
function MMT:GetForward() return Vector(self.f) end
function MMT:GetRight() return -self.l end            -- GMod: the -Y column
function MMT:GetUp() return Vector(self.u) end
function MMT:Scale() end

-- A local vector expressed in world (rotation only).
function MMT:Dir(v) return self.f * v.x + self.l * v.y + self.u * v.z end

-- self = self * R(a): rotate in the matrix's OWN frame.
function MMT:Rotate(a)
    local f, r, u = VA.AngleVectors(a)
    local l = -r
    self.f, self.l, self.u = self:Dir(f), self:Dir(l), self:Dir(u)
end

function MMT:Copy()
    local m = M.Matrix()
    m.f, m.l, m.u, m.t = Vector(self.f), Vector(self.l), Vector(self.u), Vector(self.t)
    return m
end

--------------------------------------------------------------------------
-- Angle:RotateAroundAxis, right-handed: rotate the angle's frame about a
-- WORLD axis by `deg`. Installed on the shared Angle metatable.
--------------------------------------------------------------------------
local function rot(v, axis, ang)
    local c, s = math.cos(ang), math.sin(ang)
    return v * c + axis:Cross(v) * s + axis * (axis:Dot(v) * (1 - c))
end

function M.install(AMT)
    function AMT:RotateAroundAxis(axis, deg)
        local ax = axis:GetNormalized()
        local f, r, u = VA.AngleVectors(self)
        local a = math.rad(deg)
        local b = VA.BasisAngle(rot(f, ax, a), rot(-r, ax, a), rot(u, ax, a))
        self.p, self.y, self.r = b.p, b.y, b.r
    end
end

--------------------------------------------------------------------------
-- The skeleton.
--------------------------------------------------------------------------
local B = "ValveBiped.Bip01_"
M.BONES = {
    { B .. "Pelvis",     nil,              Vector(0, 0, 0),    Angle(0, 0, 0) },
    { B .. "R_Thigh",    B .. "Pelvis",    Vector(0, -4, 0),   Angle(40, 0, 0) },
    { B .. "R_Calf",     B .. "R_Thigh",   Vector(17, 0, 0),   Angle(70, 0, 0) },
    { B .. "R_Foot",     B .. "R_Calf",    Vector(16, 0, 0),   Angle(-60, 0, 0) },
    { B .. "L_Thigh",    B .. "Pelvis",    Vector(0, 4, 0),    Angle(40, 0, 0) },
    { B .. "L_Calf",     B .. "L_Thigh",   Vector(17, 0, 0),   Angle(70, 0, 0) },
    { B .. "L_Foot",     B .. "L_Calf",    Vector(16, 0, 0),   Angle(-60, 0, 0) },
    { B .. "Spine2",     B .. "Pelvis",    Vector(0, 0, 12),   Angle(-90, 0, 0) },
    { B .. "Head1",      B .. "Spine2",    Vector(12, 0, 0),   Angle(0, 0, 0) },
    { B .. "R_UpperArm", B .. "Pelvis",    Vector(0, -7, 18),  Angle(30, 0, 0) },
    { B .. "R_Forearm",  B .. "R_UpperArm", Vector(12, 0, 0),  Angle(-20, 0, 0) },
    { B .. "R_Hand",     B .. "R_Forearm", Vector(11, 0, 0),   Angle(0, 0, 0) },
    { B .. "L_UpperArm", B .. "Pelvis",    Vector(0, 7, 18),   Angle(30, 0, 0) },
    { B .. "L_Forearm",  B .. "L_UpperArm", Vector(12, 0, 0),  Angle(-20, 0, 0) },
    { B .. "L_Hand",     B .. "L_Forearm", Vector(11, 0, 0),   Angle(0, 0, 0) },
}
M.INDEX = {}
for i, b in ipairs(M.BONES) do M.INDEX[b[1]] = i end

-- World matrices for every bone, given the root's world pose and the
-- manipulations (by bone index).
function M.pose(rootPos, rootAng, manips)
    local out = {}
    for i, b in ipairs(M.BONES) do
        local m
        if b[2] then
            local p = out[M.INDEX[b[2]]]
            m = p:Copy()
            m.t = p.t + p:Dir(b[3])
        else
            m = M.Matrix()
            m:SetAngles(rootAng)
            m.t = Vector(rootPos)
        end
        m:Rotate(b[4])
        local manip = manips[i]
        if manip then m:Rotate(manip) end
        out[i] = m
    end
    return out
end

return M
