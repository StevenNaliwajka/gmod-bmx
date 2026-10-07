--[[--------------------------------------------------------------------------
    weapons/gmod_tool/stools/bmx_park.lua

    THE PARK TOOL. Left click puts the chosen piece where you aim; aimed at
    another park piece it snaps edge to edge against the side you are nearest
    (BMX.Park.Snap, sh_park.lua, where the arithmetic is and is tested).
    Right click turns the next piece a quarter turn. Reload removes the piece
    you are aiming at.

    Everything with a rule in it is BMX.Park's: this file is the buttons and
    the panel. The count cap, the freeze and the owner are BMX.Park.Place's.
    A stool file is sent to clients by the toolgun itself; the AddCSLuaFile
    below is only so the offline loader test sees it sent.

    Tool options are the tool's own client convars (bmx_park_shape and so on),
    which the toolgun makes; they are a piece of the toolgun's panel, not
    Options > BMX settings.
----------------------------------------------------------------------------]]

AddCSLuaFile()

TOOL.Category = "Construction"
TOOL.Name = "BMX Park"
TOOL.Command = nil
TOOL.ConfigName = ""

TOOL.ClientConVar = {
    shape = "quarterpipe",
    size = "2",
    variant = "1",
    rot = "0",
    snap = "1",
    slide = "0",
}

if CLIENT then
    TOOL.Information = {
        { name = "left" }, { name = "right" }, { name = "reload" },
    }
end

local function options(self)
    return {
        snap = self:GetClientNumber("snap", 1) ~= 0,
        slide = self:GetClientNumber("slide", 0) ~= 0,
        rot = self:GetClientNumber("rot", 0) * 90,
        yaw = self:GetOwner():EyeAngles().y,
    }
end

function TOOL:LeftClick(trace)
    if CLIENT then return true end
    local P = BMX.Park
    local ply = self:GetOwner()
    local shape = self:GetClientInfo("shape")
    local params = { self:GetClientNumber("size", 2), self:GetClientNumber("variant", 1) }
    if not P.Shapes[shape] then return false end
    local pos, yaw = P.Placement(trace, shape, params, options(self))
    if not pos then return false end
    local e, why = P.Place(ply, shape, params, pos, Angle(0, yaw, 0))
    if not e then
        ply:ChatPrint("[BMX] " .. tostring(why))
        return false
    end
    undo.Create("BMX park piece")
    undo.AddEntity(e)
    undo.SetPlayer(ply)
    undo.Finish()
    return true
end

function TOOL:RightClick()
    if CLIENT then return true end
    local rot = (self:GetClientNumber("rot", 0) + 1) % 4
    self:GetOwner():ConCommand("bmx_park_rot " .. rot)
    return true
end

function TOOL:Reload(trace)
    if CLIENT then return true end
    if BMX.Park.IsPiece(trace.Entity) then
        trace.Entity:Remove()
        return true
    end
    return false
end

if CLIENT then
    -- The ghost: where a click would put the piece, as a footprint box.
    function TOOL:Think()
        local P = BMX.Park
        local ply = LocalPlayer()
        local shape = self:GetClientInfo("shape")
        local params = { self:GetClientNumber("size", 2), self:GetClientNumber("variant", 1) }
        local b = P.Build(shape, params)
        if not b then return end
        local pos, yaw = P.Placement(ply:GetEyeTrace(), shape, params, options(self))
        if not pos then return end
        P.Ghost = { pos = pos, ang = Angle(0, yaw, 0), mins = b.mins, maxs = b.maxs, t = CurTime() }
    end

    function TOOL.BuildCPanel(panel)
        local P = BMX.Park
        panel:Help("Pieces snap edge to edge when you aim at another piece. Right click turns the next piece; reload removes one.")
        local combo = panel:ComboBox("Piece", "bmx_park_shape")
        for _, id in ipairs(P.Order) do combo:AddChoice(P.Shapes[id].name, id) end
        panel:NumSlider("Size (1 S, 2 M, 3 L)", "bmx_park_size", 1, 3, 0)
        panel:NumSlider("Variant (height, gap, ledge or pad)", "bmx_park_variant", 1, 3, 0)
        panel:NumSlider("Turn (quarter turns)", "bmx_park_rot", 0, 3, 0)
        panel:CheckBox("Snap to pieces", "bmx_park_snap")
        panel:CheckBox("Slide along the side you snap to", "bmx_park_slide")
        panel:Help("bmx_park_save <name>, bmx_park_load <name> and bmx_park_preset <name> keep and build whole parks (admins).")
    end
end
