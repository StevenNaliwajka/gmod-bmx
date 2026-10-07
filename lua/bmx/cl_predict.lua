--[[--------------------------------------------------------------------------
    bmx/cl_predict.lua

    FEEL UNDER REAL PING (G30), the client half.

        bmx_predict 0|1        draw your OWN bike's lean and steer ahead of the
                               network, from your own keys (default 0)
        bmx_latency_probe [n]  measure input-to-visible-lean latency, n trials

    DISPLAY ONLY. The simulation is, and stays, the server's (docs/DESIGN.md
    section 5: GMod has no vehicle prediction API). What this changes is a
    picture: the roll the rider's bike is DRAWN at and the angle its bars are
    drawn at, by what the shared controller (sh_lean.lua, through
    BMX.Predict.Lead) says they will be once the rider's input has made the trip.
    Nothing is sent, nothing the server reads is touched, and other riders'
    bikes are drawn exactly as the network interpolates them.

    WHY IT CAN'T RUBBER-BAND THE WAY A FULL PREDICTION DOES. The lead is rooted
    in the NETWORKED state every frame (it is "the server's roll + what the
    controller says happens next"), so there is no accumulated predicted state to
    disagree with the server and be snapped back. A bad guess is bounded by the
    horizon (at most 0.3 s of the controller's motion) and fades through
    BMX.Predict.Blend: under 4 units of change it is taken as it is, over it
    eases in over 100 ms.

    WHAT IS PREDICTED: the ground lean (roll) and the bars, of a single-track
    bike, only while it is on the ground and the rider is on it. In the air, on a
    rail, on a board or any other balance mode, the offset eases back to nothing
    and the networked state is drawn as before.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Predict = BMX.Predict or {}
local P = BMX.Predict

local cv_predict = CreateClientConVar("bmx_predict", "0", true, false,
    "BMX: 1 = draw your own bike's lean and steer ahead of the network (display only); 0 = as networked.")

local KEEP = 0.8        -- s of input history kept

-- THE RIDER'S OWN INPUT, as the server will decode it: the side axis scaled and
-- dead-zoned exactly the way sv_input.lua does (BMX.Lean.Deadzone), with the same
-- digital fallback. Recorded every usercmd with the smoothed lean the shared
-- controller makes of it, which is what Lead replays.
local history = {}
local lean, lastCmdT = 0, nil

local function scale(value, cvName, fallback)
    local cv = GetConVar(cvName)
    local s = cv and cv:GetFloat() or fallback
    if s <= 0 then s = fallback end
    return BMX.Clamp(value / s, -1, 1)
end

hook.Add("CreateMove", "BMX.PredictInput", function(cmd)
    local ply = LocalPlayer()
    if not IsValid(ply) then return end
    local bike = BMX.LocalBike and BMX.LocalBike(ply)
    if not bike then history, lean, lastCmdT = {}, 0, nil return end

    local map = BMX.InputMapFor(bike)
    local buttons = cmd:GetButtons()
    local dz = BMX.Clamp(ply:GetInfoNum("bmx_stick_deadzone", 0.1), 0, 0.9)
    local side = BMX.Lean.Deadzone(scale(cmd:GetSideMove(), "sv_sidespeed", 400), dz)
    if side == 0 then
        local r, l = map.actions.right, map.actions.left
        if r and bit.band(buttons, r.key) ~= 0 then side = 1
        elseif l and bit.band(buttons, l.key) ~= 0 then side = -1 end
    end

    local now = SysTime()
    local dt = lastCmdT and math.min(now - lastCmdT, 0.1) or 0
    lastCmdT = now
    lean = BMX.Lean.StepLean(lean, side, dt)
    history[#history + 1] = { t = now, target = side, lean = lean }
    while #history > 2 and history[1].t < now - KEEP do table.remove(history, 1) end

    -- THE PROBE reads the same command and the roll as it is DRAWN.
    local pr = P.probe
    if pr and bike:GetDriver() == ply then
        P.ProbeObserve(now, side, bike)
    end
end)

--------------------------------------------------------------------------
-- The drawn offsets, per bike entity, blended.
--------------------------------------------------------------------------
local function singletrack(bike)
    local def = bike.Bike and bike:Bike()
    return (def and def.balance or "singletrack") == "singletrack"
end

local function active(bike)
    if not cv_predict:GetBool() then return false end
    local ply = LocalPlayer()
    return IsValid(ply) and bike:GetDriver() == ply and singletrack(bike)
        and not bike:GetStandDown()
end

-- Compute, once a frame, where the displayed roll and steer should be.
-- Returns rollOffset, steer (both radians) for this bike, blended.
local function update(bike)
    local now, frame = SysTime(), FrameTime()
    local s = bike.predState
    if s and s.frame == FrameNumber() then return s end
    s = s or { roll = 0, rollOffset = 0, steerShown = nil, lastRoll = nil }
    bike.predState = s
    s.frame = FrameNumber()

    local C = bike:Cfg()
    local roll = (BMX.Attitude(bike, vector_up))
    local target, steerTarget = 0, nil

    if active(bike) and bike:GetGrounded() then
        local ping = (LocalPlayer():Ping() or 0) / 1000
        local interp = GetConVar("cl_interp") and GetConVar("cl_interp"):GetFloat() or 0.1
        -- The networked roll's own rate, filtered as the server filters it.
        s.rollRate = BMX.Lean.FilterRate(s.rollRate or 0, s.lastRoll or roll, roll, math.max(frame, 1e-3))
        local r, st = P.Lead{
            roll = roll, rollRate = s.rollRate, steer = bike:GetSteer(),
            speed = bike:GetSpeedUPS(), now = now, horizon = P.Horizon(ping, interp),
            history = history, B = C.Balance,
            mass = C.Chassis.mass, g = physenv.GetGravity():Length(),
            h = C.Chassis.massCenterExpected.z + C.Wheel.radius,
            inertia = BMX.IRoll(bike), wheelbase = C.Wheel.wheelbase,
        }
        target, steerTarget = r - roll, st
    end
    s.lastRoll = roll

    -- ARM: a roll of r moves the top of the bike about r * the centre-of-mass
    -- height, which is what P.Blend's 4-unit snap is measured in.
    local arm = C.Chassis.massCenterExpected.z + C.Wheel.radius
    s.rollOffset = P.Blend(s.rollOffset, target, arm, frame)
    s.steerShown = steerTarget and P.Blend(s.steerShown or steerTarget, steerTarget,
        C.Wheel.wheelbase, frame) or nil
    return s
end

-- Called from ENT:Draw (entities/bmx_base/cl_init.lua). Zero for any bike that
-- is not the local rider's, or with the switch off: the networked state, drawn
-- as it always was.
function BMX.PredictRollOffset(bike)
    -- Another rider's bike never gets a state at all: nothing to ease out.
    if not bike.predState and not active(bike) then return 0 end
    local off = update(bike).rollOffset
    if off == 0 and not cv_predict:GetBool() then bike.predState = nil end
    return off
end

function BMX.PredictSteer(bike, networked)
    if not cv_predict:GetBool() then return networked end
    local s = update(bike)
    return s.steerShown or networked
end

--------------------------------------------------------------------------
-- THE PROBE: bmx_latency_probe [n]
--
-- Ride in a straight line at a steady speed on flat ground, hands off, then tap
-- D (or A) and let go, n times, a couple of seconds apart. Each tap is one
-- trial; the report is min / median / max in ms. With bmx_predict 1 it
-- reports both what the NETWORK shows and what the PREDICTION shows, so the
-- number the rider feels is next to the one the server delivers.
-- docs/TUNING.md, "Measuring input-to-visible-lean latency", has the procedure
-- and the table to fill.
--------------------------------------------------------------------------
function P.ProbeObserve(now, side, bike)
    local pr = P.probe
    local netRoll = (BMX.Attitude(bike, vector_up))
    local shown = netRoll + (bike.predState and bike.predState.rollOffset or 0)
    local lat = P.ProbeFeed(pr, now, side, netRoll)
    P.ProbeFeed(P.probeShown, now, side, shown)
    if lat then
        chat.AddText(Color(120, 200, 255), string.format("[BMX probe] %d/%d: %.0f ms",
            #pr.results, pr.want, lat * 1000))
    end
    if P.ProbeFinished(pr) then P.ProbeReport() end
end

function P.ProbeReport()
    local pr, shown = P.probe, P.probeShown
    P.probe, P.probeShown = nil, nil
    local ping = LocalPlayer():Ping()
    local fake = GetConVar("net_fakelag")
    local function line(label, p)
        local s = P.Summary(p.results)
        if not s then return label .. ": no trial completed" end
        return string.format("%s: min %.0f  median %.0f  max %.0f ms  (%d trials, %d dropped)",
            label, s.min, s.median, s.max, s.n, p.dropped)
    end
    local out = {
        string.format("[BMX probe] ping %d ms, net_fakelag %s, bmx_predict %d", ping,
            fake and fake:GetString() or "n/a", cv_predict:GetInt()),
        "[BMX probe] " .. line("networked lean", pr),
    }
    if cv_predict:GetBool() then out[#out + 1] = "[BMX probe] " .. line("drawn (predicted) lean", shown) end
    for _, l in ipairs(out) do MsgC(Color(120, 200, 255), l, "\n") end
    chat.AddText(Color(120, 200, 255), out[2])
end

concommand.Add("bmx_latency_probe", function(_, _, args)
    local n = math.Clamp(tonumber(args[1]) or 5, 1, 30)
    if not BMX.LocalBike(LocalPlayer()) then
        print("[BMX probe] get on a bike first, ride straight and level, then run it again.")
        return
    end
    P.probe, P.probeShown = P.ProbeNew(n), P.ProbeNew(n)
    print(string.format("[BMX probe] ready: %d trials. Ride straight, hands off, then tap D and let go, " ..
        "waiting about 2 s between taps.", n))
end)
