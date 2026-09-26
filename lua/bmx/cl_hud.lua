--[[--------------------------------------------------------------------------
    bmx/cl_hud.lua

    Rider HUD, and the tuning overlay behind bmx_debug.

    The rider HUD is deliberately small: speed, cadence, stamina, hop charge,
    score. A BMX has no dashboard and the screen is where the track is.

    The tuning overlay is the opposite and unapologetically dense. It exists so
    a tuner can see WHY the bike did what it did: whether the balance assist ran
    out of authority, whether a tyre saturated, whether a wheel is actually on
    the ground. Reading those off a graph beats guessing at a Kp.
----------------------------------------------------------------------------]]

BMX = BMX or {}

CreateClientConVar("bmx_debug", "0", true, true,
    "Stream this bike's simulation state from the server and draw the tuning overlay.")
local cv_hud = CreateClientConVar("bmx_hud", "1", true, false, "Draw the rider HUD.")
local cv_units = CreateClientConVar("bmx_units", "kmh", true, false,
    "Speed units on the HUD: kmh, mph or ups.")

surface.CreateFont("BMX.Big",   { font = "Roboto", size = 34, weight = 700 })
surface.CreateFont("BMX.Small", { font = "Roboto", size = 17, weight = 500 })
surface.CreateFont("BMX.Mono",  { font = "Consolas", size = 15, weight = 400 })

local COL_BG    = Color(16, 18, 22, 205)
local COL_FG    = Color(232, 236, 242)
local COL_DIM   = Color(150, 158, 170)
local COL_GOOD  = Color(110, 205, 140)
local COL_WARN  = Color(240, 185, 90)
local COL_BAD   = Color(238, 105, 85)

--------------------------------------------------------------------------
-- Debug payload. Read in exactly the order sv_debug.lua writes it.
--------------------------------------------------------------------------
local dbg = nil

local function readWheel()
    return {
        onGround    = net.ReadBool(),
        load        = net.ReadFloat(),
        slipLong    = net.ReadFloat(),
        slipLat     = net.ReadFloat(),
        saturation  = net.ReadFloat(),
        compression = net.ReadFloat(),
        omega       = net.ReadFloat(),
        steer       = net.ReadFloat(),
    }
end

net.Receive("bmx_debug", function()
    dbg = {
        roll        = net.ReadFloat(),
        targetRoll  = net.ReadFloat(),
        rollRate    = net.ReadFloat(),
        authority   = net.ReadFloat(),
        steer       = net.ReadFloat(),

        pitch       = net.ReadFloat(),
        pitchRate   = net.ReadFloat(),

        speed       = net.ReadFloat(),
        fwdSpeed    = net.ReadFloat(),
        cadence     = net.ReadFloat(),
        stamina     = net.ReadFloat(),

        airMode     = net.ReadBool(),
        airTime     = net.ReadFloat(),
        spinPitch   = net.ReadFloat(),
        spinRoll    = net.ReadFloat(),
        spinYaw     = net.ReadFloat(),

        lean        = net.ReadFloat(),
        pitchIn     = net.ReadFloat(),
        throttle    = net.ReadFloat(),
    }
    dbg.front = readWheel()
    dbg.rear  = readWheel()
    dbg.at    = CurTime()
end)

--------------------------------------------------------------------------
-- Drawing helpers
--------------------------------------------------------------------------
local function bar(x, y, w, h, frac, col, bg)
    draw.RoundedBox(3, x, y, w, h, bg or Color(0, 0, 0, 140))
    local fw = math.floor(w * math.Clamp(frac, 0, 1))
    if fw > 0 then draw.RoundedBox(3, x, y, fw, h, col) end
end

local function label(txt, x, y, font, col, align)
    draw.SimpleText(txt, font or "BMX.Small", x, y, col or COL_FG,
        align or TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
end

--------------------------------------------------------------------------
-- Rider HUD
--------------------------------------------------------------------------
local function drawRiderHUD(bike)
    local sw, sh = ScrW(), ScrH()
    local w, h = 250, 96
    local x, y = sw - w - 28, sh - h - 34

    draw.RoundedBox(6, x, y, w, h, COL_BG)

    ----------------------------------------------------------------------
    -- Speed
    ----------------------------------------------------------------------
    local ups = bike:GetSpeedUPS()
    local units = cv_units:GetString()
    local shown, suffix
    if units == "mph" then
        shown, suffix = BMX.ToMPH(ups), "mph"
    elseif units == "ups" then
        shown, suffix = ups, "u/s"
    else
        shown, suffix = BMX.ToKMH(ups), "km/h"
    end

    -- Right-align the number against a fixed column and hang the unit off it.
    -- Measuring the string with surface.GetTextSize would need a matching
    -- surface.SetFont first (draw.SimpleText sets its own and does not leave it
    -- behind), and an unset font measures against whatever ran last.
    label(string.format("%.0f", shown), x + 108, y + 10, "BMX.Big", COL_FG, TEXT_ALIGN_RIGHT)
    label(suffix, x + 116, y + 26, "BMX.Small", COL_DIM)

    ----------------------------------------------------------------------
    -- Cadence: how close the rider is to spinning out. This is what actually
    -- caps top speed, so showing it explains why pedalling stopped helping.
    ----------------------------------------------------------------------
    local cadFrac = bike:GetCadence() / bike:Cfg().Drive.maxCadence
    bar(x + 14, y + 54, w - 28, 6, cadFrac,
        cadFrac > 0.95 and COL_WARN or COL_GOOD)
    label("cadence", x + 14, y + 62, "BMX.Small", COL_DIM)

    ----------------------------------------------------------------------
    -- Stamina, only once it has been spent: a permanently full bar is chrome.
    ----------------------------------------------------------------------
    local stam = bike:GetStamina() / bike:Cfg().Drive.staminaMax
    if stam < 0.999 then
        bar(x + 14, y + 80, w - 28, 6, stam,
            stam < 0.2 and COL_BAD or (bike:GetSprinting() and COL_WARN or COL_DIM))
        label("stamina", x + 14 + 62, y + 62, "BMX.Small", COL_DIM)
    end

    ----------------------------------------------------------------------
    -- Hop charge, centre screen: it is a timing input and the rider's eyes are
    -- on the obstacle, not in the corner.
    ----------------------------------------------------------------------
    local charge = bike:GetHopCharge()
    if charge > 0 then
        bar(sw * 0.5 - 60, sh * 0.62, 120, 5, charge,
            charge >= 0.999 and COL_GOOD or COL_WARN)
    end

    ----------------------------------------------------------------------
    -- Score
    ----------------------------------------------------------------------
    if bike:GetScore() > 0 then
        label(string.format("%d", bike:GetScore()), sw - 28, 30,
            "BMX.Big", COL_FG, TEXT_ALIGN_RIGHT)
    end
end

--------------------------------------------------------------------------
-- Tuning overlay
--------------------------------------------------------------------------
-- Takes the bike: the cadence and compression rows need ITS config. This used
-- to read a global `bike` that does not exist, so turning bmx_debug on threw
-- inside HUDPaint on every frame and the overlay the whole tuning guide leans
-- on never drew a single row.
local function drawDebug(bike)
    if not dbg or CurTime() - dbg.at > 0.6 then
        label("bmx_debug: waiting for server stream...", 24, 120, "BMX.Mono", COL_WARN)
        return
    end

    local x, y = 24, 110
    local lh = 17
    local w = 340

    draw.RoundedBox(4, x - 10, y - 8, w, 400, Color(10, 12, 15, 220))

    local function row(k, v, col)
        label(k, x, y, "BMX.Mono", COL_DIM)
        label(v, x + 150, y, "BMX.Mono", col or COL_FG)
        y = y + lh
    end

    local function head(t)
        y = y + 5
        label(t, x, y, "BMX.Mono", COL_WARN)
        y = y + lh + 2
    end

    head("BALANCE")
    -- Roll versus target is the single most useful line in the overlay: a
    -- persistent gap means the assist is out of authority, not mistuned.
    row("roll / target", string.format("%+6.1f / %+6.1f deg",
        math.deg(dbg.roll), math.deg(dbg.targetRoll)),
        math.abs(dbg.roll - dbg.targetRoll) > math.rad(12) and COL_BAD or COL_GOOD)
    row("roll rate", string.format("%+6.2f rad/s", dbg.rollRate))
    row("authority", string.format("%5.2f", dbg.authority),
        dbg.authority < 0.2 and COL_BAD or COL_FG)
    row("steer (derived)", string.format("%+6.2f deg", math.deg(dbg.steer)))
    row("lean input", string.format("%+5.2f", dbg.lean))

    head("ATTITUDE")
    row("pitch", string.format("%+6.1f deg", math.deg(dbg.pitch)))
    row("pitch rate", string.format("%+6.2f rad/s", dbg.pitchRate))
    row("pitch input", string.format("%+5.2f", dbg.pitchIn))

    head("DRIVE")
    row("speed", string.format("%6.1f u/s  (%.1f km/h)", dbg.speed, BMX.ToKMH(dbg.speed)))
    row("forward speed", string.format("%+6.1f u/s", dbg.fwdSpeed))
    row("cadence", string.format("%5.2f / %.2f rad/s", dbg.cadence, bike:Cfg().Drive.maxCadence),
        dbg.cadence > bike:Cfg().Drive.maxCadence * 0.95 and COL_WARN or COL_FG)
    row("throttle", string.format("%5.2f", dbg.throttle))
    row("stamina", string.format("%5.1f", dbg.stamina))

    head("AIR")
    row("mode", dbg.airMode and "AIRBORNE" or "ground",
        dbg.airMode and COL_WARN or COL_DIM)
    if dbg.airMode then
        row("air time", string.format("%5.2f s", dbg.airTime))
        row("flip / roll / spin", string.format("%+.2f %+.2f %+.2f rev",
            dbg.spinPitch / (math.pi * 2),
            dbg.spinRoll  / (math.pi * 2),
            dbg.spinYaw   / (math.pi * 2)))
    end

    local function wheel(name, wd)
        head(name)
        row("contact", wd.onGround and "GROUND" or "air",
            wd.onGround and COL_GOOD or COL_BAD)
        row("load", string.format("%8.0f", wd.load))
        -- Saturation at 1.00 means the friction circle is full: any more
        -- braking costs cornering and vice versa. This is the number that
        -- explains a washed-out front end.
        row("saturation", string.format("%5.2f", wd.saturation),
            wd.saturation > 0.98 and COL_BAD or
            (wd.saturation > 0.8 and COL_WARN or COL_GOOD))
        row("slip long / lat", string.format("%+6.1f / %+6.1f u/s", wd.slipLong, wd.slipLat))
        row("compression", string.format("%5.2f / %.2f u", wd.compression,
            bike:Cfg().Wheel.restLength))
    end

    wheel("FRONT WHEEL", dbg.front)
    wheel("REAR WHEEL",  dbg.rear)
end

--------------------------------------------------------------------------
hook.Add("HUDPaint", "BMX.HUD", function()
    local ply = LocalPlayer()
    if not IsValid(ply) then return end

    local bike = BMX.LocalBike(ply)
    if not bike then return end

    -- Keep the client's copy of the config in step with the replicated tuning
    -- convars, or the HUD's cadence bar and the camera's lean limit drift away
    -- from what the server is actually simulating.
    BMX.ApplyConVars()

    if cv_hud:GetBool() then drawRiderHUD(bike) end
    if GetConVar("bmx_debug"):GetInt() > 0 then drawDebug(bike) end
end)

--------------------------------------------------------------------------
-- Trick callouts
--------------------------------------------------------------------------
local callouts = {}

net.Receive("bmx_tricks", function()
    local n = net.ReadUInt(3)
    local tricks = {}

    for i = 1, n do
        local t = {
            name   = net.ReadString(),
            count  = net.ReadUInt(4),
            points = net.ReadUInt(16),
        }
        tricks[i] = t
        callouts[#callouts + 1] = {
            text   = (t.count > 1 and (t.count .. "x ") or "") .. t.name,
            points = t.points,
            born   = CurTime(),
        }
    end

    local total = net.ReadUInt(20)
    hook.Run("BMX_TricksLandedClient", tricks, total)
end)

hook.Add("HUDPaint", "BMX.CalloutPaint", function()
    local sw, sh = ScrW(), ScrH()
    local y = sh * 0.34

    for i = #callouts, 1, -1 do
        local c = callouts[i]
        local age = CurTime() - c.born
        if age > 2.4 then
            table.remove(callouts, i)
        else
            local a = 255 * (1 - math.max(0, (age - 1.6) / 0.8))
            draw.SimpleText(c.text, "BMX.Big", sw * 0.5, y - age * 22,
                Color(255, 255, 255, a), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            draw.SimpleText("+" .. c.points, "BMX.Small", sw * 0.5, y - age * 22 + 26,
                Color(COL_GOOD.r, COL_GOOD.g, COL_GOOD.b, a),
                TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            y = y - 60
        end
    end
end)
