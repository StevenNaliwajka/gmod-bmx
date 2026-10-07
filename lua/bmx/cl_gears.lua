--[[--------------------------------------------------------------------------
    bmx/cl_gears.lua

    SHIFTING (G09), the client's half. The keys are the vehicle's input map
    (`shiftUp` and `shiftDown`, sh_vehicles.lua: ] and the wheel up, [ and the
    wheel down on the road bike); they are buttons the client sees and the usercmd
    does not carry, so a press becomes one net message and the server (sv_gears.lua)
    decides whether it was allowed.

    bmx_shift_wheel 0 leaves the mouse wheel to the weapon switch, for somebody who
    wants it back; the bracket keys always shift.
----------------------------------------------------------------------------]]

BMX = BMX or {}

local cv_wheel = CreateClientConVar("bmx_shift_wheel", "1", true, false,
    "Shift gears with the mouse wheel on a bike that has gears. 0 = the bracket keys only.")

-- Which way does this button shift this bike, or nil. Pure, so the suite can
-- ask it without a keyboard: reads the bike's own input map.
function BMX.ShiftForButton(bike, button, wheelOn)
    -- An e-bike's shift keys are its assist level (sv_motor.lua), so it is "geared" here too.
    if not bike or (BMX.Gears.Count(bike) == 0 and not (BMX.Motor and BMX.Motor.IsAssist(bike))) then return nil end
    local map = BMX.InputMapFor(bike)
    for dir, action in pairs({ [true] = "shiftUp", [false] = "shiftDown" }) do
        local a = map.actions[action]
        for _, b in ipairs(a and a.buttons or {}) do
            if b == button then
                local isWheel = button == (MOUSE_WHEEL_UP or 112) or button == (MOUSE_WHEEL_DOWN or 113)
                if isWheel and not wheelOn then return nil end
                return dir
            end
        end
    end
    return nil
end

hook.Add("PlayerButtonDown", "BMX.Shift", function(ply, button)
    if ply ~= LocalPlayer() then return end
    if not IsFirstTimePredicted() then return end
    local bike = BMX.LocalBike(ply)
    if not bike or bike:GetDriver() ~= ply then return end
    local up = BMX.ShiftForButton(bike, button, cv_wheel:GetBool())
    if up == nil then return end
    net.Start("bmx_shift")
        net.WriteBool(up)
    net.SendToServer()
end)
