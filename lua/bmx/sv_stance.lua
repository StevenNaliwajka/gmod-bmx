--[[--------------------------------------------------------------------------
    bmx/sv_stance.lua

    Copies each rider's bmx_rider_pose (a userinfo convar, G21) onto the
    player as a networked int so everyone's client can draw it
    (sh_stance.lua explains why). Polled twice a second rather than hooked: a
    client's convar change reaches the server with no event the addon can
    listen to, and half a second is faster than anyone changes their seat.

    Cost: one GetInfo per player per half second, and a network write only
    when the value changes. The value is validated against the stance list, so
    a hand-crafted userinfo cannot smuggle in anything else.
----------------------------------------------------------------------------]]

BMX = BMX or {}

local nextPoll = 0
hook.Add("Think", "BMX.StanceSync", function()
    local now = CurTime()
    if now < nextPoll then return end
    nextPoll = now + 0.5
    for _, ply in ipairs(player.GetAll()) do
        local id = BMX.RiderStanceId[ply:GetInfo("bmx_rider_pose")] or 1
        if ply:GetNWInt("BMXStance", 1) ~= id then ply:SetNWInt("BMXStance", id) end
    end
end)
