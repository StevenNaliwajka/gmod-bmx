include("shared.lua")

--[[--------------------------------------------------------------------------
    entities/bmx_bike_rack/cl_init.lua

    The rack drawn in code: a base bar, a post, a cradle (two arms in a V and a strap
    bar) for each of its two bikes, in the same primitives the bikes use (BMX.Draw).
    Empty cradles are drawn paler, loaded ones darker, so a rack says at a glance how many
    it holds.
----------------------------------------------------------------------------]]

local COL_ARM  = Color(70, 74, 82)
local COL_FREE = Color(150, 156, 168)

function ENT:Initialize()
    self:SetRenderBounds(Vector(-40, -50, -4), Vector(40, 50, 44))
end

function ENT:Draw()
    local H = BMX.Draw
    if not H then return end
    local at = function(x, y, z) return self:LocalToWorld(Vector(x, y, z)) end

    -- The base bar, the post, and the two uprights.
    H.tube(at(0, -22, 2), at(0, 22, 2), 2.2, H.COL.part)
    H.tube(at(0, 0, 2), at(0, 0, 10), 2.0, H.COL.part)
    H.tube(at(0, -22, 2), at(0, -22, 12), 1.4, H.COL.part)
    H.tube(at(0, 22, 2), at(0, 22, 12), 1.4, H.COL.part)

    -- Two cradles: each a pair of arms in a V under the bike's wheels, and a strap.
    for i, y in ipairs({ 15, -15 }) do
        local loaded = (self:GetLoaded() or 0) >= i
        local col = loaded and COL_ARM or COL_FREE
        for _, dx in ipairs({ -13, 13 }) do
            H.tube(at(0, y, 4), at(dx, y, 14), 1.2, col)
            H.tube(at(dx, y, 14), at(dx, y, 16), 1.0, col)
        end
        H.tube(at(-13, y, 4), at(13, y, 4), 1.4, col)
        H.tube(at(-13, y, 17), at(13, y, 17), 0.8, H.COL.chrome)
    end
    -- The hitch it hangs from, when it is on a car.
    if self:GetCarried() then
        H.tube(at(0, 0, 2), at(-14, 0, 2), 2.0, H.COL.chrome)
    end
end
