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
function MMT:Scale(v) self.s = Vector(v) end

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
    -- THE SPINE BENDS FORWARD ABOUT ITS OWN Z, as ValveBiped's does (it is a
    -- Character Studio Biped: Z bends a spine link, X twists it, Y leans it to
    -- the side) and as cl_rider.lua's Angle(0, lean, 0) assumes. Spine2 points
    -- UP (its local +X) with +Y forward and +Z to the rider's left. It used to
    -- be a plain pitch, which left the side axis on Y, so every "forward" lean
    -- bent the rider to the LEFT -- +20 put the head 4 units left, not 4
    -- forward -- and the IK, solved in each bone's own frame, could not tell.
    { B .. "Spine2",     B .. "Pelvis",    Vector(0, 0, 12),   Angle(-90, 0, -90) },
    { B .. "Head1",      B .. "Spine2",    Vector(12, 0, 0),   Angle(0, 0, 0) },
    -- The arms hang off the SPINE, as ValveBiped's do (through the clavicles),
    -- so twisting the spine carries the shoulders round. A shoulder 18 up and 7
    -- out is (6, 0, -7) from Spine2, and the arm's rest is "forward and 30
    -- down" in a frame of its own unchanged by Spine2's axes: (0, 120, 90).
    { B .. "R_UpperArm", B .. "Spine2",    Vector(6, 0, -7),   Angle(0, 120, 90) },
    { B .. "R_Forearm",  B .. "R_UpperArm", Vector(12, 0, 0),  Angle(-20, 0, 0) },
    { B .. "R_Hand",     B .. "R_Forearm", Vector(11, 0, 0),   Angle(0, 0, 0) },
    { B .. "L_UpperArm", B .. "Spine2",    Vector(6, 0, 7),    Angle(0, 120, 90) },
    { B .. "L_Forearm",  B .. "L_UpperArm", Vector(12, 0, 0),  Angle(-20, 0, 0) },
    { B .. "L_Hand",     B .. "L_Forearm", Vector(11, 0, 0),   Angle(0, 0, 0) },
}
-- Toes, and a hand's fingers: four of three segments along the hand's +X,
-- and a thumb on the PALM side (-Z), so curling a finger (turning it toward
-- -Z) closes it on the thumb and bending it back opens it.
for _, s in ipairs({ "R", "L" }) do
    M.BONES[#M.BONES + 1] = { B .. s .. "_Toe0", B .. s .. "_Foot", Vector(6, 0, 0), Angle(0, 0, 0) }
    local hand = B .. s .. "_Hand"
    M.BONES[#M.BONES + 1] = { B .. s .. "_Finger0", hand, Vector(1.5, 0, -1.6), Angle(0, 0, 0) }
    for i, y in ipairs({ 0.9, 0.3, -0.3, -0.9 }) do
        local f = B .. s .. "_Finger" .. i
        M.BONES[#M.BONES + 1] = { f, hand, Vector(3.5, y, 0), Angle(0, 0, 0) }
        M.BONES[#M.BONES + 1] = { f .. "1", f, Vector(1.6, 0, 0), Angle(0, 0, 0) }
        M.BONES[#M.BONES + 1] = { f .. "2", f .. "1", Vector(1.3, 0, 0), Angle(0, 0, 0) }
    end
end
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
