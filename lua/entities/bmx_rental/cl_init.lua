include("shared.lua")

--[[--------------------------------------------------------------------------
    entities/bmx_rental/cl_init.lua

    The vending machine, with a sign across its face that says what it is and
    what to press, so nobody has to be told.
----------------------------------------------------------------------------]]

surface.CreateFont("BMX.RentalBig",   { font = "Roboto", size = 64, weight = 900 })
surface.CreateFont("BMX.RentalSmall", { font = "Roboto", size = 34, weight = 700 })

local SIGN_FAR = 900 * 900   -- u^2: past this the sign is not drawn

function ENT:Draw()
    self:DrawModel()
    if EyePos():DistToSqr(self:GetPos()) > SIGN_FAR then return end

    local mn, mx = self:OBBMins(), self:OBBMaxs()
    local ang = self:GetAngles()
    ang:RotateAroundAxis(ang:Up(), 90)
    ang:RotateAroundAxis(ang:Forward(), 90)
    -- A panel on the face, in the upper half, 0.1 u proud of it.
    local pos = self:LocalToWorld(Vector(mx.x + 0.6, 0, mn.z + (mx.z - mn.z) * 0.78))
    local w, h = 460, 230
    cam.Start3D2D(pos, ang, 0.1)
        draw.RoundedBox(12, -w / 2, -h / 2, w, h, Color(24, 28, 34, 235))
        surface.SetDrawColor(232, 64, 52)
        surface.DrawRect(-w / 2, -h / 2, w, 8)
        draw.SimpleText("BIKE RENTAL", "BMX.RentalBig", 0, -38, Color(255, 255, 255),
            TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        draw.SimpleText("FREE", "BMX.RentalBig", 0, 22, Color(255, 214, 64),
            TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        draw.SimpleText("press  E", "BMX.RentalSmall", 0, 78, Color(200, 206, 214),
            TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    cam.End3D2D()
end
