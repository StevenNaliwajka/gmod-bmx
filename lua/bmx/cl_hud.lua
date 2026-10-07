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
-- Userinfo, so the server's usercmd decode (sv_input.lua) reads each rider's own.
CreateClientConVar("bmx_stick_deadzone", "0.1", true, true,
    "Gamepad stick deadzone for riding, 0..0.9: stick travel inside it counts as centred.")
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
-- THE SPEEDOMETER'S EXTRA LINE (G21): the combo multiplier and the airtime,
-- under the speed box. The combo HUD already says all of this in the middle
-- of the screen; this is the same two numbers where the eye is already
-- looking at the speed. Pure, so tests/test_stance.lua can read it.
--------------------------------------------------------------------------
-- Airtime in seconds: running while the bike is off the ground, then held for
-- 2.5 s after landing so there is time to read it. Air shorter than a quarter
-- of a second is a bump, not an air, and is never shown.
function BMX.AirClock(st, grounded, now)
    if grounded then
        if st.start then st.last, st.lastAt, st.start = now - st.start, now, nil end
    else
        st.start = st.start or now
    end
    if st.start then
        local t = now - st.start
        return t >= 0.25 and t or 0, true
    end
    if st.last and st.last >= 0.25 and now - st.lastAt < 2.5 then return st.last, false end
    return 0, false
end

-- "combo x3   air 1.20s", or nil when neither is worth showing.
function BMX.HudStatsLine(comboN, airSeconds)
    local parts = {}
    if (comboN or 0) >= 1 then parts[#parts + 1] = "combo x" .. comboN end
    if (airSeconds or 0) > 0 then parts[#parts + 1] = string.format("air %.2fs", airSeconds) end
    if #parts == 0 then return nil end
    return table.concat(parts, "   ")
end

local airClock = {}

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

    -- THE GEAR (G09), on a bike that has them: "gear 4/8" at the right of the
    -- speed, with the cadence under it in rpm so the shift is a decision the
    -- rider can see (60-110 is where the legs want to be).
    local gear = BMX.Gears.Label(bike)
    -- A MOTOR'S LINES (G14, G15; cl_motor.lua): the assist level and the battery on an
    -- e-bike or e-moto, the engine's rpm and the clutch on a dirt bike.
    local mi = BMX.MotorHudInfo and BMX.MotorHudInfo(bike)
    if gear then
        label(gear, x + w - 14, y + 12, "BMX.Small", COL_FG, TEXT_ALIGN_RIGHT)
        label((mi and mi.rpmLabel) or string.format("%.0f rpm", bike:GetCadence() * 60 / (2 * math.pi)),
            x + w - 14, y + 30, "BMX.Small", mi and mi.clutch and COL_WARN or COL_DIM, TEXT_ALIGN_RIGHT)
    elseif mi and mi.assist then
        label(mi.assist, x + w - 14, y + 12, "BMX.Small", COL_FG, TEXT_ALIGN_RIGHT)
    end
    if mi and mi.batteryLabel then
        label(mi.batteryLabel, x + w - 14, y + 62, "BMX.Small", COL_DIM, TEXT_ALIGN_RIGHT)
        if mi.battery then
            bar(x + 14, y + 88, w - 28, 5, mi.battery, mi.battery < 0.15 and COL_BAD or COL_GOOD)
        end
    end

    ----------------------------------------------------------------------
    -- Combo multiplier and airtime, in a strip under the box.
    ----------------------------------------------------------------------
    local c = BMX.ComboHUD and BMX.ComboHUD()
    local comboN = (c and c.state == 0 and CurTime() - c.at < 6) and c.n or 0
    local air = BMX.AirClock(airClock, bike:GetGrounded(), CurTime())
    local line = BMX.HudStatsLine(comboN, air)
    if line then
        label(line, x + w - 14, y + h + 6, "BMX.Small", COL_FG, TEXT_ALIGN_RIGHT)
    end

    ----------------------------------------------------------------------
    -- Cadence: how close the rider is to spinning out. This is what actually
    -- caps top speed, so showing it explains why pedalling stopped helping.
    ----------------------------------------------------------------------
    -- Only a pedalled vehicle has a cadence or a stamina: a board is pushed.
    local dk = (bike:Bike().drive or {}).kind
    local pedals = dk == "pedal" or dk == "assist"     -- an e-bike is pedalled too (G14)
    local cadFrac = bike:GetCadence() / bike:Cfg().Drive.maxCadence
    if mi and mi.rpm then
        -- An engine's rev counter in the legs' place: red at the limiter.
        bar(x + 14, y + 54, w - 28, 6, mi.rpm, mi.rpm > 0.95 and COL_WARN or COL_GOOD)
        label(mi.clutch and "clutch" or "rpm", x + 14, y + 62, "BMX.Small", COL_DIM)
    elseif pedals then
        bar(x + 14, y + 54, w - 28, 6, cadFrac,
            cadFrac > 0.95 and COL_WARN or COL_GOOD)
        label("cadence", x + 14, y + 62, "BMX.Small", COL_DIM)
    end

    ----------------------------------------------------------------------
    -- Stamina, only once it has been spent: a permanently full bar is chrome.
    ----------------------------------------------------------------------
    local stam = bike:GetStamina() / bike:Cfg().Drive.staminaMax
    if pedals and stam < 0.999 then
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

    -- The cinematic camera hides the rider HUD, as GTA's does.
    local cinematic = (BMX.CinematicActive and BMX.CinematicActive(ply))
        or (BMX.ReplayActive and BMX.ReplayActive())
    if cv_hud:GetBool() and not cinematic then drawRiderHUD(bike) end
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
    if BMX.ReplayActive and BMX.ReplayActive() then return end   -- the replay draws its own
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

--------------------------------------------------------------------------
-- COMBOS (sv_combo.lua): the chain as it builds, then LANDED with the bonus
-- or BAILED. Lower centre, under the trick callouts.
--------------------------------------------------------------------------
local combo = nil        -- { state, n, base, bonus, names, at }
BMX.ComboHUD = function() return combo end

net.Receive("bmx_combo", function()
    local c = { state = net.ReadUInt(2), n = net.ReadUInt(8), base = net.ReadUInt(20),
                bonus = net.ReadUInt(22), names = {}, at = CurTime() }
    for i = 1, net.ReadUInt(3) do c.names[i] = net.ReadString() end
    combo = c
end)

local function commas(n)
    local s = tostring(math.floor(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

hook.Add("HUDPaint", "BMX.ComboPaint", function()
    if BMX.ReplayActive and BMX.ReplayActive() then return end
    local c = combo
    if not c then return end
    local age = CurTime() - c.at
    local sw, sh = ScrW(), ScrH()
    local y = sh * 0.72
    if c.state == 0 then
        if c.n < 2 then return end           -- one trick is not a combo yet
        if age > 6 then combo = nil return end
        draw.SimpleText(table.concat(c.names, " + "), "BMX.Small", sw * 0.5, y,
            Color(255, 255, 255, 230), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        draw.SimpleText(commas(c.base) .. "  x" .. c.n, "BMX.Big", sw * 0.5, y + 30,
            Color(255, 214, 90, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        return
    end
    if age > 2.2 or (c.state == 1 and c.bonus <= 0) then combo = nil return end
    local a = 255 * (1 - math.max(0, (age - 1.4) / 0.8))
    if c.state == 1 then
        draw.SimpleText("COMBO LANDED  +" .. commas(c.bonus), "BMX.Big", sw * 0.5, y + 30,
            Color(110, 230, 120, a), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    else
        draw.SimpleText("BAILED", "BMX.Big", sw * 0.5, y + 30,
            Color(235, 80, 70, a), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
end)
