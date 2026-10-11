--[[--------------------------------------------------------------------------
    tests/lib/skeleton_real.lua

    A REAL player model's skeleton, for the rider IK: kleiner's 69 bones as a
    client drew them, seated (drive_airboat) or standing (idle_all_01), from the
    captures in tests/data/skeleton_kleiner_*.lua.

    WHY. The stand-in (lib/skeleton.lua) is a hand-built seated body. It reached
    bars and pedals a real model cannot: a tandem's, a penny-farthing's (2026-10-11,
    measured on a client with tools/ride/sweep.sh), so the suite passed what a
    player saw fail. This one has the real proportions, the real rest pose, the
    clavicles, Spine4, the neck and every finger, so a fit measured here is one a
    player gets.

    Same interface as the stand-in: BONES { name, parentName, offset, rest },
    INDEX, pose(rootPos, rootAng, manips, manipPos). The root is the SEAT: the
    captures are relative to the pod, as the shim's root pose is.

        local SR = require("lib.skeleton_real")
        ply._skel = SR.load("kleiner_seated")      -- this player only
----------------------------------------------------------------------------]]

local VA = require("lib.vecang")
local SK = require("lib.skeleton")
local Vector = VA.Vector

local M = {}
local cache = {}

local function V(a) return Vector(a[1], a[2], a[3]) end
local function unit(v) local l = v:Length() return l > 0 and v / l or v end

function M.load(name)
    if cache[name] then return cache[name] end
    local here = debug.getinfo(1, "S").source:match("^@(.*)/lib/[^/]*$") or "tests"
    local data = dofile(here .. "/data/skeleton_" .. name .. ".lua")
    local S = { name = name, BONES = {}, INDEX = {} }
    for i, b in ipairs(data.bones) do
        local t, f, l, u = V(b[3]), unit(V(b[4])), unit(V(b[5])), unit(V(b[6]))
        local pb = b[2] > 0 and data.bones[b[2]]
        local pt, pf, pl, pu
        if pb then
            pt, pf, pl, pu = V(pb[3]), unit(V(pb[4])), unit(V(pb[5])), unit(V(pb[6]))
        else
            pt, pf, pl, pu = Vector(0, 0, 0), Vector(1, 0, 0), Vector(0, 1, 0), Vector(0, 0, 1)
        end
        local d = t - pt
        local function inP(v) return Vector(v:Dot(pf), v:Dot(pl), v:Dot(pu)) end
        S.BONES[i] = { b[1], pb and pb[1] or nil, inP(d), VA.BasisAngle(inP(f), inP(l), inP(u)) }
        S.INDEX[b[1]] = i
    end
    -- World matrices for every bone: parent * translate(offset + position manipulation,
    -- in the parent's frame) * rotate(rest) * rotate(manipulation), as the stand-in's.
    function S.pose(rootPos, rootAng, manips, manipPos)
        local out = {}
        local root = SK.Matrix()
        root:SetAngles(rootAng)
        root.t = Vector(rootPos)
        for i, b in ipairs(S.BONES) do
            local p = b[2] and out[S.INDEX[b[2]]] or root
            local m = p:Copy()
            local off = b[3]
            local mp = manipPos and manipPos[i]
            if mp then off = off + mp end
            m.t = p.t + p:Dir(off)
            m:Rotate(b[4])
            local manip = manips[i]
            if manip then m:Rotate(manip) end
            out[i] = m
        end
        return out
    end
    cache[name] = S
    return S
end

return M
