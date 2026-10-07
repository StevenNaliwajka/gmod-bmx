--[[--------------------------------------------------------------------------
    bmx/cl_menu.lua

    The /bike window (sh_menu.lua says what it is). One tab per section of
    BMX.Menu.Catalog(): a vehicle tab is a grid of big buttons, one per
    vehicle; the Park tab is a row per piece with its size and variant.

    A vehicle click runs bmx_spawn and closes the window, so you can ride at
    once. A park click sends bmx_menu_spawn and leaves the window open, since a
    park is built from several pieces.

        bmx_menu    open it from the console (or bind a key to it)
----------------------------------------------------------------------------]]

local M = BMX.Menu

local COL = {
    bg     = Color(24, 28, 34, 245),
    panel  = Color(36, 42, 50),
    hover  = Color(52, 60, 72),
    accent = Color(232, 64, 52),
    text   = Color(236, 238, 240),
    dim    = Color(150, 158, 168),
}

surface.CreateFont("BMX.MenuTitle", { font = "Roboto", size = 24, weight = 800 })
surface.CreateFont("BMX.MenuItem",  { font = "Roboto", size = 20, weight = 700 })
surface.CreateFont("BMX.MenuInfo",  { font = "Roboto", size = 15, weight = 500 })

local function flatButton(parent, label, font)
    local b = vgui.Create("DButton", parent)
    b:SetText("")
    b.Label = label
    b.Paint = function(self, w, h)
        draw.RoundedBox(4, 0, 0, w, h, self:IsHovered() and COL.hover or COL.panel)
        if self.Info then
            draw.SimpleText(self.Label, font or "BMX.MenuItem", 12, 10, COL.text)
            draw.DrawText(self.Info, "BMX.MenuInfo", 12, 36, COL.dim)
        else
            draw.SimpleText(self.Label, font or "BMX.MenuItem", w / 2, h / 2, COL.text,
                TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
        if self:IsHovered() then surface.SetDrawColor(COL.accent) surface.DrawRect(0, h - 3, w, 3) end
    end
    return b
end

-- Wrap `text` to fit `w` pixels in `font`, at most `lines` lines.
local function wrap(text, font, w, lines)
    surface.SetFont(font)
    local out, line = {}, ""
    for word in text:gmatch("%S+") do
        local try = line == "" and word or (line .. " " .. word)
        if surface.GetTextSize(try) > w and line ~= "" then
            out[#out + 1] = line
            line = word
            if #out == lines then return table.concat(out, "\n") end
        else
            line = try
        end
    end
    if line ~= "" and #out < lines then out[#out + 1] = line end
    return table.concat(out, "\n")
end

local function vehicleTab(sheet, sec, frame)
    local scroll = vgui.Create("DScrollPanel", sheet)
    local grid = vgui.Create("DIconLayout", scroll)
    grid:Dock(FILL)
    grid:SetSpaceX(8)
    grid:SetSpaceY(8)
    for _, it in ipairs(sec.items) do
        local b = flatButton(grid, it.name)
        b:SetSize(270, 92)
        b.Info = wrap(it.info, "BMX.MenuInfo", 246, 2)
        b:SetTooltip(it.info)
        b.DoClick = function()
            RunConsoleCommand("bmx_spawn", it.id)
            surface.PlaySound("ui/buttonclick.wav")
            frame:Close()
        end
    end
    return scroll
end

local function parkTab(sheet, sec)
    local scroll = vgui.Create("DScrollPanel", sheet)
    local hint = scroll:Add("DLabel")
    hint:Dock(TOP)
    hint:DockMargin(4, 0, 4, 6)
    hint:SetFont("BMX.MenuInfo")
    hint:SetTextColor(COL.dim)
    hint:SetText("Look where you want it, then click. Ramps face the way you look. Z undoes.")
    for _, it in ipairs(sec.items) do
        local row = scroll:Add("DPanel")
        row:Dock(TOP)
        row:DockMargin(0, 0, 0, 6)
        row:SetTall(44)
        row.Paint = function(_, w, h) draw.RoundedBox(4, 0, 0, w, h, COL.panel) end

        local name = vgui.Create("DLabel", row)
        name:Dock(LEFT)
        name:DockMargin(12, 0, 0, 0)
        name:SetWide(170)
        name:SetFont("BMX.MenuItem")
        name:SetTextColor(COL.text)
        name:SetText(it.name)

        local go = flatButton(row, "Spawn", "BMX.MenuInfo")
        go:Dock(RIGHT)
        go:DockMargin(0, 6, 6, 6)
        go:SetWide(80)

        local size = vgui.Create("DComboBox", row)
        size:Dock(RIGHT)
        size:DockMargin(0, 10, 8, 10)
        size:SetWide(90)
        for i, s in ipairs(BMX.Park.SIZES) do size:AddChoice(s.name, i, i == 2) end

        local variant
        if it.variants then
            variant = vgui.Create("DComboBox", row)
            variant:Dock(RIGHT)
            variant:DockMargin(0, 10, 8, 10)
            variant:SetWide(130)
            for i, v in ipairs(it.variants) do variant:AddChoice(v, i, i == 1) end
        end

        go.DoClick = function()
            local _, s = size:GetSelected()
            local v = 1
            if variant then local _, vv = variant:GetSelected(); v = vv or 1 end
            net.Start(M.NET_SPAWN)
            net.WriteString(it.id)
            net.WriteUInt(s or 2, 4)
            net.WriteUInt(v, 4)
            net.SendToServer()
            surface.PlaySound("ui/buttonclick.wav")
        end
    end
    return scroll
end

function M.Open()
    if IsValid(M.Frame) then M.Frame:Remove() end
    local f = vgui.Create("DFrame")
    M.Frame = f
    f:SetSize(math.min(600, ScrW() - 40), math.min(520, ScrH() - 40))
    f:Center()
    f:SetTitle("")
    f:MakePopup()
    f.Paint = function(_, w, h)
        draw.RoundedBox(6, 0, 0, w, h, COL.bg)
        surface.SetDrawColor(COL.accent)
        surface.DrawRect(0, 0, w, 3)
        draw.SimpleText("BMX", "BMX.MenuTitle", 14, 12, COL.text)
        draw.SimpleText("pick something to spawn", "BMX.MenuInfo", 72, 18, COL.dim)
    end

    local sheet = vgui.Create("DPropertySheet", f)
    sheet:Dock(FILL)
    sheet:DockMargin(0, 18, 0, 0)
    sheet.Paint = nil
    for _, sec in ipairs(M.Catalog()) do
        local panel = sec.kind == "park" and parkTab(sheet, sec) or vehicleTab(sheet, sec, f)
        sheet:AddSheet(sec.title, panel)
    end
end

net.Receive(M.NET_OPEN, function() M.Open() end)
concommand.Add("bmx_menu", function() M.Open() end)
