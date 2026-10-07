--[[--------------------------------------------------------------------------
    bmx/sh_autoride.lua

    AUTO RIDE: the bike rides itself, the way the trick bot rides.

        O (while riding)     auto ride on; O again, or any ride key, and
                             the bars are yours again (bmx_autoride_key)
        bmx_autoride         the same, from the console or a bind
        bmx_autoride_allow   0 turns it off for everyone on the server

    THE RIDING IS NOT HERE. What steers -- the routes round the park on the
    navmesh, the ramps it picks, the tricks, getting itself unstuck, getting
    back on after a fall -- is the trick bot's brain, and the bot is BMX
    (Mode)'s (gamemodes/bmx/gamemode/sv_bot.lua), not this addon's. So this
    file is the button and the hand-over, and nothing else:

      BMX_AutoRideStart (ply, bike)   asks whoever drives. A listener that
                                      takes the bike returns true, and drives
                                      it the way the bot does: ply.BMXScripted,
                                      and bike.input written each tick (the
                                      seam in sv_input.lua). Nobody answering
                                      is "this server has no auto rider".
      BMX_AutoRideStop (ply, bike, why)   tells it to let go.

    TAKING THE BARS BACK. Any ride key PRESSED while it rides ends it, and
    that key does what it always does on the same tick: W pedals, E gets off.
    A key that was already held when auto ride began does not count until it
    is let go and pressed again, or holding W while pressing O would end it
    at once.

    It is a scripted rider, so the scoring the gamemode keeps (personal bests,
    the leaderboard, the games) does not count what it lands.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.AutoRide = BMX.AutoRide or {}
local A = BMX.AutoRide

A.NW = "BMXAutoRide"
A.DEFAULT_KEY = 25      -- KEY_O

-- The keys that hand the bars back: every one a rider steers, pedals, brakes,
-- hops or gets off with.
A.TAKEOVER = bit.bor(IN_FORWARD, IN_BACK, IN_MOVELEFT, IN_MOVERIGHT,
                     IN_JUMP, IN_ATTACK, IN_ATTACK2, IN_USE)

function A.Active(ply)
    return IsValid(ply) and ply:GetNWBool(A.NW, false) or false
end

if SERVER then
    CreateConVar("bmx_autoride_allow", "1", bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY),
        "BMX: riders may let their bike ride itself the way the trick bot rides (O, bmx_autoride)")

    local NO_RIDER = "this server has no auto rider (it comes with the BMX (Mode) gamemode)"

    local function tell(ply, msg)
        if IsValid(ply) then ply:ChatPrint("[BMX] " .. msg) end
    end

    local function ridingBike(ply)
        local bike = IsValid(ply) and ply.BMXBike
        if IsValid(bike) and bike:GetDriver() == ply then return bike end
    end

    -- Auto ride on for `ply`, on the bike they ride. Returns true, or false
    -- and why not.
    function A.Start(ply)
        if A.Active(ply) then return true end
        local bike = ridingBike(ply)
        if not bike then return false, "get on a bike first" end
        local cv = GetConVar("bmx_autoride_allow")
        if cv and not cv:GetBool() then return false, "auto ride is turned off on this server" end
        -- Something else already writes this rider's input (the test harness,
        -- a bot): not ours to take.
        if ply.BMXScripted then return false, "something else is riding for you" end
        local ok, why = hook.Run("BMX_AutoRideStart", ply, bike)
        if ok ~= true then return false, isstring(why) and why or NO_RIDER end
        ply.BMXAutoRide = bike
        ply.BMXAutoRideKeys = nil       -- the first usercmd says what was already held
        ply:SetNWBool(A.NW, true)
        return true
    end

    -- Auto ride off. Safe to call when it is not on (returns false), and from
    -- inside a BMX_AutoRideStop listener: the flag is down before it is asked.
    function A.Stop(ply, why)
        if not IsValid(ply) or not ply.BMXAutoRide then return false end
        local bike = ply.BMXAutoRide
        ply.BMXAutoRide = nil
        ply.BMXAutoRideKeys = nil
        ply:SetNWBool(A.NW, false)
        hook.Run("BMX_AutoRideStop", ply, bike, why or "stopped")
        return true
    end

    function A.Toggle(ply)
        if A.Active(ply) then
            A.Stop(ply, "toggled off")
            tell(ply, "auto ride off: the bars are yours")
            return true
        end
        local ok, why = A.Start(ply)
        if ok then
            tell(ply, "auto ride on: O again, or any ride key, takes the bars back")
        else
            tell(ply, "no auto ride: " .. tostring(why))
        end
        return ok
    end

    -- Called by sv_input.lua's StartCommand, before the scripted-rider seam:
    -- a ride key freshly pressed ends auto ride, and returns true. The key is
    -- then read as usual on the same tick.
    function A.TakeOver(ply, cmd)
        if not ply.BMXAutoRide then return false end
        local held = bit.band(cmd:GetButtons(), A.TAKEOVER)
        local before = ply.BMXAutoRideKeys
        ply.BMXAutoRideKeys = held
        if before == nil then return false end
        if bit.band(held, bit.bnot(before)) == 0 then return false end
        A.Stop(ply, "took the bars")
        return true
    end

    concommand.Add("bmx_autoride", function(ply)
        if not IsValid(ply) then print("[BMX] bmx_autoride is a rider's command") return end
        A.Toggle(ply)
    end)

    -- The key (O by default; bmx_autoride_key, 0 for none). PlayerButtonDown
    -- because no usercmd bit is O: the same way K recolours (sh_color.lua).
    hook.Add("PlayerButtonDown", "BMX.AutoRideKey", function(ply, button)
        local key = ply:GetInfoNum("bmx_autoride_key", A.DEFAULT_KEY)
        if key == 0 or button ~= key then return end
        if not ridingBike(ply) and not A.Active(ply) then return end
        if CurTime() < (ply.BMXAutoRideNext or 0) then return end
        ply.BMXAutoRideNext = CurTime() + 0.3
        A.Toggle(ply)
    end)

    -- Its bike gone, or the rider on another one, or dead, or gone: over. (A
    -- crash is not: the rider tumbles, and the auto rider gets them back on,
    -- as the bot gets back on.)
    timer.Create("BMX.AutoRideWatch", 0.5, 0, function()
        for _, ply in ipairs(player.GetAll()) do
            local bike = ply.BMXAutoRide
            if bike then
                if not IsValid(bike) then
                    A.Stop(ply, "the bike is gone")
                elseif IsValid(ply.BMXBike) and ply.BMXBike ~= bike and ply.BMXBike:GetDriver() == ply then
                    A.Stop(ply, "on another bike")
                end
            end
        end
    end)
    hook.Add("PlayerDeath", "BMX.AutoRideDeath", function(ply) A.Stop(ply, "died") end)
    hook.Add("PlayerDisconnected", "BMX.AutoRideGone", function(ply) A.Stop(ply, "left") end)
end

if CLIENT then
    -- Userinfo: the server reads it in PlayerButtonDown.
    CreateClientConVar("bmx_autoride_key", tostring(A.DEFAULT_KEY), true, true,
        "BMX: the key that turns auto ride on and off while riding (a KEY_ number; 25 is O, 0 is off)")

    surface.CreateFont("BMX.AutoRide",    { font = "Roboto", size = 22, weight = 800 })
    surface.CreateFont("BMX.AutoRideSub", { font = "Roboto", size = 15, weight = 500 })

    -- The key's name for the hint ("O"), or nil with no key.
    function A.KeyName()
        local cv = GetConVar("bmx_autoride_key")
        local key = cv and cv:GetInt() or A.DEFAULT_KEY
        if key == 0 then return nil end
        local name = input.GetKeyName(key)
        return name and string.upper(name) or nil
    end

    -- A pill at the top of the screen while it rides, so nobody wonders why
    -- the bike is going where they did not steer it.
    hook.Add("HUDPaint", "BMX.AutoRide", function()
        if not A.Active(LocalPlayer()) then return end
        local key = A.KeyName()
        local sub = (key and (key .. " or ") or "") .. "any ride key takes the bars back"
        surface.SetFont("BMX.AutoRideSub")
        local w = math.max(surface.GetTextSize(sub), 160) + 40
        local x, y = ScrW() / 2 - w / 2, 18
        local pulse = 0.75 + 0.25 * math.sin(RealTime() * 4)
        draw.RoundedBox(8, x, y, w, 54, Color(24, 28, 34, 220))
        surface.SetDrawColor(232, 64, 52, 255 * pulse)
        surface.DrawRect(x, y, w, 3)
        draw.SimpleText("AUTO RIDE", "BMX.AutoRide", ScrW() / 2, y + 7, Color(236, 238, 240), TEXT_ALIGN_CENTER)
        draw.SimpleText(sub, "BMX.AutoRideSub", ScrW() / 2, y + 32, Color(150, 158, 168), TEXT_ALIGN_CENTER)
    end)
end
