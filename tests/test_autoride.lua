--[[--------------------------------------------------------------------------
    Auto ride (sh_autoride.lua): O hands the bike to whoever drives
    (BMX_AutoRideStart -- BMX (Mode)'s trick bot), and any ride key, freshly
    pressed, hands it back on that same tick.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local gmod = require("lib.gmod")
local IN = gmod.IN

local function cmd(buttons)
    local c = { buttons = buttons or 0 }
    function c:GetButtons() return self.buttons end
    function c:SetButtons(b) self.buttons = b end
    function c:GetForwardMove() return 0 end
    function c:GetSideMove() return 0 end
    function c:SetForwardMove() end
    function c:SetSideMove() end
    function c:SetUpMove() end
    return c
end

-- A rider on a bike, and a stand-in for the bot: it takes the bike the way
-- the docs say a driver does, and holds the throttle open while it drives.
local function rig(withDriver)
    local sv = F.server()
    local E = sv.env
    local bike = F.bike(sv)
    local ply = F.rider(sv, bike)
    local log = {}
    if withDriver ~= false then
        E.hook.Add("BMX_AutoRideStart", "test", function(p, b)
            log[#log + 1] = { "start", p, b }
            p.BMXScripted = true
            b.input.throttle = 0.5
            return true
        end)
        E.hook.Add("BMX_AutoRideStop", "test", function(p, b, why)
            log[#log + 1] = { "stop", p, b, why }
            p.BMXScripted = nil
        end)
    end
    local function send(buttons)
        E.hook.Run("StartCommand", ply, cmd(buttons))
    end
    return sv, E, bike, ply, log, send
end

T.test("autoride: O while riding hands the bike to the driver, and says so", function()
    local sv, E, bike, ply, log = rig()
    E.hook.Run("PlayerButtonDown", ply, E.KEY_O)
    T.ok(E.BMX.AutoRide.Active(ply), "on (the HUD reads the networked flag)")
    T.eq(log[1] and log[1][1], "start", "the driver was asked")
    T.ok(log[1][2] == ply and log[1][3] == bike, "with (ply, bike)")
    T.ok(ply.BMXScripted, "the driver writes the input now")
    T.eq(#sv.errors, 0, "nothing threw: " .. table.concat(sv.errors, " | "))
end)

T.test("autoride: its input stands -- the rider's empty usercmd does not zero it", function()
    local _, E, bike, ply, _, send = rig()
    E.BMX.AutoRide.Start(ply)
    send(0)
    send(0)
    T.eq(bike.input.throttle, 0.5, "the driver's throttle")
end)

T.test("autoride: a ride key pressed takes the bars back, and works on that same tick", function()
    local _, E, bike, ply, log, send = rig()
    E.BMX.AutoRide.Start(ply)
    send(0)
    send(IN.FORWARD)
    T.ok(not E.BMX.AutoRide.Active(ply), "off")
    local stop = log[#log]
    T.eq(stop[1], "stop", "the driver was told to let go")
    T.eq(stop[4], "took the bars", "and why")
    T.ok(not ply.BMXScripted, "the keys are the rider's again")
    T.eq(bike.input.throttle, 1, "W pedalled on the very keypress")
end)

T.test("autoride: a key already held when it began does not end it until pressed again", function()
    local _, E, _, ply, _, send = rig()
    send(IN.FORWARD)
    E.BMX.AutoRide.Start(ply)
    send(IN.FORWARD)
    send(IN.FORWARD)
    T.ok(E.BMX.AutoRide.Active(ply), "holding W through it")
    send(0)
    T.ok(E.BMX.AutoRide.Active(ply), "letting go")
    send(IN.FORWARD)
    T.ok(not E.BMX.AutoRide.Active(ply), "pressing it again")
end)

T.test("autoride: every ride key takes over -- steer, brake, hop, mouse, E", function()
    for _, k in ipairs({ "BACK", "MOVELEFT", "MOVERIGHT", "JUMP", "ATTACK", "ATTACK2", "USE" }) do
        local _, E, _, ply, _, send = rig()
        E.BMX.AutoRide.Start(ply)
        send(0)
        send(IN[k])
        T.ok(not E.BMX.AutoRide.Active(ply), k .. " ends it")
    end
end)

T.test("autoride: O again turns it off", function()
    local sv, E, _, ply, log = rig()
    E.hook.Run("PlayerButtonDown", ply, E.KEY_O)
    sv.world.time = sv.world.time + 1
    E.hook.Run("PlayerButtonDown", ply, E.KEY_O)
    T.ok(not E.BMX.AutoRide.Active(ply), "off")
    T.eq(log[#log][4], "toggled off", "and why")
end)

T.test("autoride: bmx_autoride toggles it too (the /bike window's button runs it)", function()
    local sv, E, _, ply = rig()
    sv:command("bmx_autoride", ply)
    T.ok(E.BMX.AutoRide.Active(ply), "on")
    sv:command("bmx_autoride", ply)
    T.ok(not E.BMX.AutoRide.Active(ply), "off")
end)

T.test("autoride: bmx_autoride_key moves it, and 0 is no key", function()
    local _, E, _, ply = rig()
    ply._info = { bmx_autoride_key = "0" }
    E.hook.Run("PlayerButtonDown", ply, E.KEY_O)
    T.ok(not E.BMX.AutoRide.Active(ply), "O does nothing with the key off")
    ply._info = { bmx_autoride_key = tostring(E.KEY_L) }
    E.hook.Run("PlayerButtonDown", ply, E.KEY_L)
    T.ok(E.BMX.AutoRide.Active(ply), "the key it was moved to")
end)

T.test("autoride: no driver on the server (no BMX (Mode)) says so, and nothing changes", function()
    local sv, E, bike, ply = rig(false)
    local ok, why = E.BMX.AutoRide.Start(ply)
    T.ok(not ok, "refused")
    T.ok(why:find("BMX %(Mode%)"), "it names what is missing: " .. tostring(why))
    T.ok(not E.BMX.AutoRide.Active(ply) and not ply.BMXScripted, "the keys are still the rider's")
    E.hook.Run("PlayerButtonDown", ply, E.KEY_O)
    local said = ply._chat and ply._chat[#ply._chat] or ""
    T.ok(tostring(said):find("no auto ride"), "the key tells the rider: " .. tostring(said))
end)

T.test("autoride: not on a bike, or turned off by the server, it does not start", function()
    local sv, E, bike, ply = rig()
    local walker = sv:player("Walker")
    T.ok(not E.BMX.AutoRide.Start(walker), "on foot")
    E.GetConVar("bmx_autoride_allow"):SetString("0")
    local ok, why = E.BMX.AutoRide.Start(ply)
    T.ok(not ok and why:find("off"), "server setting off: " .. tostring(why))
end)

T.test("autoride: the bike gone, or the rider dead, ends it", function()
    local sv, E, bike, ply, log = rig()
    E.BMX.AutoRide.Start(ply)
    E.hook.Run("PlayerDeath", ply)
    T.ok(not E.BMX.AutoRide.Active(ply), "died")
    T.eq(log[#log][4], "died", "and why")
    local sv2, E2, bike2, ply2 = rig()
    E2.BMX.AutoRide.Start(ply2)
    bike2:Remove()
    sv2:run(1)
    T.ok(not E2.BMX.AutoRide.Active(ply2), "bike removed")
end)

T.test("autoride: the settings rows exist (Options > BMX)", function()
    local sv = F.server()
    local S = sv.env.BMX.Settings
    local key, allow
    for _, r in ipairs(S.Rows("client")) do if r.name == "bmx_autoride_key" then key = r end end
    for _, r in ipairs(S.Rows("server")) do if r.name == "bmx_autoride_allow" then allow = r end end
    T.ok(key and key.default == 25, "the rider's key, O")
    T.ok(allow and allow.default == true, "the server's switch, on")
end)
