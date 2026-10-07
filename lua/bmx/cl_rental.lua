--[[--------------------------------------------------------------------------
    bmx/cl_rental.lua

    The rental machine's window (sh_rental.lua says what it is): the /bike
    window's vehicle tabs, every vehicle with its picture, and a click rents it
    from the machine that opened the window.
----------------------------------------------------------------------------]]

local R = BMX.Rental
local M = BMX.Menu

function R.OpenWindow(machine)
    if IsValid(R.Frame) then R.Frame:Remove() end
    local COL = M.Colors
    local f = vgui.Create("DFrame")
    R.Frame = f
    f:SetSize(math.min(640, ScrW() - 40), math.min(540, ScrH() - 40))
    f:Center()
    f:SetTitle("")
    f:MakePopup()
    f.Paint = function(_, w, h)
        draw.RoundedBox(6, 0, 0, w, h, COL.bg)
        surface.SetDrawColor(COL.accent)
        surface.DrawRect(0, 0, w, 3)
        draw.SimpleText("BIKE RENTAL", "BMX.MenuTitle", 14, 12, COL.text)
        draw.SimpleText("free -- pick one and you're on it", "BMX.MenuInfo", 166, 18, COL.dim)
    end

    local function pick(id)
        net.Start(R.NET_RENT)
        net.WriteEntity(machine)
        net.WriteString(id)
        net.SendToServer()
    end

    local sheet = vgui.Create("DPropertySheet", f)
    sheet:Dock(FILL)
    sheet:DockMargin(0, 18, 0, 0)
    sheet.Paint = nil
    for _, sec in ipairs(R.Catalog()) do
        sheet:AddSheet(sec.title, M.VehicleTab(sheet, sec, f, pick))
    end
end

net.Receive(R.NET_OPEN, function()
    local machine = net.ReadEntity()
    if IsValid(machine) then R.OpenWindow(machine) end
end)
