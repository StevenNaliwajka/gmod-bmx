--[[--------------------------------------------------------------------------
    bmx/cl_options.lua

    The settings menu: spawn menu > Options > BMX.

      Rider    your own settings (camera, display, rider, scenery). Each one is
               a convar of yours, saved by the engine; the controls set it.
      Server   everyone's settings. Only someone with the CAMI privilege
               "BMX - Change Server Settings" can change them; for anyone else
               the panel shows the values and says why it is locked.

    NOTHING IS LISTED HERE. Both panels are built from BMX.Settings
    (sh_settings.lua): one control per row, in its category, with the row's
    help text as a tooltip and as the line under it, and a reset button that
    puts that row back to its default. A goal that adds a setting adds a row
    there and it appears; a goal that wants a heading adds a category there.

    A SERVER ROW IS NOT A CONVAR TO US. We cannot set it, so the control sends
    a bmx_setting net message, and the server checks permission and range again
    (sv_settings.lua). The value shown is the replicated convar's. A slider
    sends once it has been still for a moment, not on every pixel of a drag.

    Commands: bmx_reset_client puts every Rider setting back; bmx_reset_server
    asks the server to put every Server setting back (same permission check).
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Options = BMX.Options or {}
local O = BMX.Options
local S = BMX.Settings

local SEND_DELAY = 0.35     -- s a control must be still before it is sent

--------------------------------------------------------------------------
-- Changing a setting. Pure of any panel, so the buttons, the reset commands
-- and the tests all use the same two functions.
--------------------------------------------------------------------------
function O.Send(op, name, value)
    net.Start("bmx_setting")
        net.WriteUInt(op, 2)
        net.WriteString(name or "")
        net.WriteString(tostring(value or ""))
    net.SendToServer()
end

-- Set one row to a value (any type Coerce accepts). Returns whether it was
-- accepted; a client row is set now, a server row is asked for.
function O.Set(row, value)
    local v = S.Coerce(row, value)
    if v == nil then return false end
    if row.scope == "client" then
        RunConsoleCommand(row.name, S.ToConVar(row, v))
    else
        O.Send(S.OP_SET, row.name, S.ToConVar(row, v))
    end
    return true
end

function O.Reset(row)
    if row.scope == "client" then
        RunConsoleCommand(row.name, S.ToConVar(row, row.default))
    else
        O.Send(S.OP_RESET, row.name, "")
    end
end

function O.ResetClient()
    for _, row in ipairs(S.Rows("client")) do O.Reset(row) end
end

concommand.Add("bmx_reset_client", function() O.ResetClient() end)

-- The server console reaches the server's own command; a player's console
-- reaches this one, which asks the server.
concommand.Add("bmx_reset_server", function() O.Send(S.OP_RESET_ALL, "", "") end)

--------------------------------------------------------------------------
-- The panels
--------------------------------------------------------------------------

-- One control for one row, inside a holder with a reset button on its right.
-- Returns the holder. `locked` greys it out.
local function addRow(panel, row, locked)
    local holder = vgui.Create("DPanel", panel)
    holder:SetPaintBackground(false)
    holder:SetTall(row.kind == "bool" and 24 or 32)

    local filling = true        -- while the control is being SET, not USED
    local ctrl
    local current = S.Current(row)
    if current == nil then current = row.default end

    local function queue(value)
        if filling then return end
        timer.Create("bmx_opt_" .. row.name, SEND_DELAY, 1, function() O.Set(row, value) end)
    end

    if row.kind == "bool" then
        ctrl = vgui.Create("DCheckBoxLabel", holder)
        ctrl:SetText(row.label)
        ctrl:SetTextColor(Color(40, 40, 40))
        ctrl:SetValue(current and 1 or 0)
        ctrl.OnChange = function(_, v) queue(v) end
        ctrl:SetTall(20)
    elseif row.kind == "int" or row.kind == "float" then
        ctrl = vgui.Create("DNumSlider", holder)
        ctrl:SetText(row.label)
        ctrl:SetMin(row.min)
        ctrl:SetMax(row.max)
        ctrl:SetDecimals(row.kind == "int" and 0 or (row.decimals or 2))
        ctrl:SetValue(current)
        ctrl.Label:SetTextColor(Color(40, 40, 40))
        ctrl.OnValueChanged = function(_, v) queue(v) end
    elseif row.kind == "choice" then
        ctrl = vgui.Create("DComboBox", holder)
        for _, c in ipairs(row.choices) do ctrl:AddChoice(c, c, c == current) end
        ctrl.OnSelect = function(_, _, _, data) queue(data) end
    else
        ctrl = vgui.Create("DTextEntry", holder)
        ctrl:SetText(tostring(current))
        ctrl.OnEnter = function(self) O.Set(row, self:GetValue()) end
    end
    filling = false

    ctrl:SetTooltip(row.help)
    ctrl:Dock(FILL)

    local reset = vgui.Create("DButton", holder)
    reset:SetText("Reset")
    reset:SetWide(48)
    reset:Dock(RIGHT)
    reset:SetTooltip("Put \"" .. row.label .. "\" back to its default (" ..
        S.ToConVar(row, row.default) .. ").")
    reset.DoClick = function()
        O.Reset(row)
        -- Show it at once. A server row is confirmed by the replicated convar
        -- on the next panel build; this is just the control keeping up.
        filling = true
        if row.kind == "bool" then ctrl:SetValue(row.default and 1 or 0)
        elseif row.kind == "int" or row.kind == "float" then ctrl:SetValue(row.default)
        elseif row.kind == "choice" then ctrl:ChooseOption(row.default)
        else ctrl:SetText(tostring(row.default)) end
        filling = false
    end

    if locked then
        ctrl:SetEnabled(false)
        reset:SetEnabled(false)
    end

    panel:AddItem(holder)
    -- The help under the control, so nobody has to find the tooltip.
    panel:ControlHelp(row.help)
    return holder
end

-- Fill `panel` with the rows of one scope, under their category headings.
function O.Build(panel, scope)
    panel:ClearControls()

    local locked = false
    if scope == "server" then
        locked = not BMX.Can(LocalPlayer(), S.PRIV)
        if locked then
            panel:Help("You do not have permission to change these. You can see what " ..
                "the server is using, but only an admin with \"" .. S.PRIV ..
                "\" can change it.")
        end
    end

    -- Categories in their registered order; any row whose category was never
    -- registered goes last under "Other" rather than vanishing.
    local known = {}
    local order = {}
    for _, c in ipairs(S.Categories[scope]) do
        known[c.id] = true
        order[#order + 1] = c
    end
    for _, r in ipairs(S.Rows(scope)) do
        if not known[r.category] then
            known[r.category] = true
            order[#order + 1] = { id = r.category, label = "Other" }
        end
    end

    for _, cat in ipairs(order) do
        local rows = S.Rows(scope, cat.id)
        if #rows > 0 then
            local head = panel:Help(cat.label)
            head:SetFont("DermaDefaultBold")
            for _, row in ipairs(rows) do addRow(panel, row, locked) end
        end
    end

    local all = panel:Button("Reset every setting on this page to its default",
        scope == "client" and "bmx_reset_client" or "bmx_reset_server")
    if locked then all:SetEnabled(false) end
end

hook.Add("PopulateToolMenu", "BMX.Options", function()
    spawnmenu.AddToolMenuOption("Options", "BMX", "bmx_options_rider", "Rider", "", "",
        function(panel) O.Build(panel, "client") end)
    spawnmenu.AddToolMenuOption("Options", "BMX", "bmx_options_server", "Server", "", "",
        function(panel) O.Build(panel, "server") end)
end)
