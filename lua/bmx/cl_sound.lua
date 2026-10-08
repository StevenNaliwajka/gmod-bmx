--[[--------------------------------------------------------------------------
    bmx/cl_sound.lua

    What a BMX sounds like. The sound table itself is sh_sound.lua: most entries
    are sounds that ship with Garry's Mod (zero content dependencies, nothing
    lifted from another game; docs/DESIGN.md section 8), and the ones that matter
    most -- the bell, the freewheel, the tyres, the engines -- are the addon's own,
    synthesised by tools/sound/make_sounds.py.

    WHAT PLAYS IS WHAT THE VEHICLE HAS. A skateboard has no freewheel to tick and
    no tyres to hum; a motorbike has no pawls. Each loop asks the vehicle
    (BMX.HasFreewheel, BMX.RollSoundKey) rather than assuming a BMX.

    WHY THE LOOPS ARE CLIENT-SIDE. A looping sound wants to start, stop and
    change pitch many times a second in response to speed. Doing that from the
    server means a network message per change; doing it here costs nothing,
    because everything it reads -- speed, grounded, cadence, skidding -- is
    already networked for the HUD.

    THE ONE-SHOTS ARE SERVER-SIDE, in init.lua, because they are events rather
    than states: a landing happens once, at a moment the server decides.
----------------------------------------------------------------------------]]

BMX = BMX or {}

-- The sound set itself lives in sh_sound.lua, because the server plays the
-- one-shots out of the same table.
if not CLIENT then return end

-- Precache, so the first skid is not the first time the engine goes looking for
-- the file. These all ship with the game, so this is cheap and cannot fail.
-- A sound with variants is a pattern (a %d in the path): each numbered file is
-- precached, not the pattern, which names no file at all.
for _, s in pairs(BMX.Sounds) do
    if s.path and s.variants then
        for i = 1, s.variants do util.PrecacheSound(string.format(s.path, i)) end
    elseif s.path then
        util.PrecacheSound(s.path)
    end
end

--------------------------------------------------------------------------
-- Volumes, per player. 0..1 each, archived, and multiplied onto the sound's own
-- level rather than replacing it, so 1 is "as designed" and 0 is silent.
--
--   bmx_vol_ride   tyres, skids, the freewheel tick (and the grind scrape)
--   bmx_vol_wind   the speed whoosh
--   bmx_vol_bell   the bell, whoever rings it
--
-- The admin's bmx_sounds 0 (sh_sound.lua) is checked on top of these: it mutes
-- everything for everybody, whatever their sliders say.
--------------------------------------------------------------------------
local cvRide = CreateClientConVar("bmx_vol_ride", "1", true, false, "BMX: volume of tyre, skid and freewheel sounds, 0-1.")
local cvWind = CreateClientConVar("bmx_vol_wind", "1", true, false, "BMX: volume of the wind whoosh, 0-1.")
local cvBell = CreateClientConVar("bmx_vol_bell", "1", true, false, "BMX: volume of bike bells, 0-1.")

local function vol(cv) return math.Clamp(cv:GetFloat(), 0, 1) end
BMX.VolRide = function() return vol(cvRide) end
BMX.VolWind = function() return vol(cvWind) end
BMX.VolBell = function() return vol(cvBell) end

--------------------------------------------------------------------------
-- THE BELL (sh_bell.lua). Played here, at the listener's own bmx_vol_bell.
--
-- The rider's own press rings AT ONCE, from this client, without waiting for the
-- server: a bell is a button, and one that answers a round trip late feels like a
-- press that did not take. It rings only when the rule is sure to agree -- on the
-- ground, the bike level and neither weight key held, which is when R cannot be a
-- barspin in a manual -- and otherwise leaves it to the server. The server's
-- message reaches this client as well, and is dropped when it is the echo of a
-- ring already played here.
--------------------------------------------------------------------------
local ownRing = setmetatable({}, { __mode = "k" })    -- bike -> when this client rang it
local ECHO = 0.75                                      -- seconds an echo can take to come back

local function playBell(ent, key)
    local S = BMX.Sounds[key]
    if not S or not BMX.SoundsOn() then return false end
    -- The lever on the bars flicks (cl_init.lua reads this), heard or not.
    ent.bellRungAt = CurTime()
    local v = BMX.VolBell()
    if v <= 0 then return true end
    ent:EmitSound(BMX.SoundFile(key), S.level, S.pitch and math.random(S.pitch[1], S.pitch[2]) or 100,
        S.vol * v)
    return true
end
BMX.PlayBell = playBell

-- The server decided a bell rang; how loud is this listener's.
net.Receive("bmx_bell", function()
    local ent = net.ReadEntity()
    local key = net.ReadString()
    if not IsValid(ent) or not BMX.Sounds[key] then return end
    local mine = ownRing[ent]
    if mine and CurTime() - mine < ECHO then
        ownRing[ent] = nil           -- the echo of the ring already heard
        return
    end
    playBell(ent, key)
end)

-- Would the server ring for this press, for certain? (Its rule is sh_bell.lua and
-- sv_input.lua: on the ground, not in a manual.) A manual is not networked, but it
-- cannot begin without a weight key and it holds the bike off level, so a press
-- with neither key down and the bike level is a ring.
function BMX.BellPredictable(bike, weightKeyDown)
    if not bike:GetGrounded() or weightKeyDown then return false end
    if (bike.GetLeanFwd and bike:GetLeanFwd() or 0) > 0.05 then return false end
    local _, pitch = BMX.Attitude(bike, vector_up)
    return math.abs(pitch or 0) < math.rad(8)
end

local bellHeld = false
hook.Add("CreateMove", "BMX.BellNow", function(cmd)
    local ply = LocalPlayer()
    local bike = IsValid(ply) and BMX.LocalBike and BMX.LocalBike(ply)
    if not bike or bike:GetDriver() ~= ply then bellHeld = false return end
    local map = BMX.InputMapFor(bike)
    local a = map.actions.bar
    local down = a ~= nil and a.key ~= nil and cmd:KeyDown(a.key)
    if down and not bellHeld and not map.decode and BMX.Bell and BMX.Bell.Allowed(bike) then
        local wb, lf = map.actions.weightBack, map.actions.brakeFront
        local weight = (wb and cmd:KeyDown(wb.key)) or (lf and cmd:KeyDown(lf.key) and cmd:KeyDown(IN_DUCK))
        if BMX.BellPredictable(bike, weight) and playBell(bike, BMX.Bell.KeyFor(bike)) then
            ownRing[bike] = CurTime()
            -- The same clock as the server's, so a fast double press is not judged
            -- twice differently here and there.
            bike.bellNext = CurTime() + BMX.Bell.Cooldown()
        end
    end
    bellHeld = down
end)

--------------------------------------------------------------------------
-- Per-bike sound state.
--
-- Keyed by entity rather than stored on it so that a removed bike cannot leave
-- a CSoundPatch playing: the sweep below drops any entry whose entity has gone
-- and stops its channels first. A leaked looping sound in Source plays until
-- the map changes, which is a genuinely unpleasant bug to ship.
--------------------------------------------------------------------------
local live = {}

-- Every loop a bike can have, so stopAll and the sweep never miss one.
local LOOPS = { "roll", "roll_wheel", "skid", "wind", "freewheel", "chain" }

local function stopAll(state)
    for _, key in ipairs(LOOPS) do
        if state[key] then state[key]:Stop() end
    end
end

local function channel(ent, state, key)
    if not state[key] then
        state[key] = CreateSound(ent, BMX.Sounds[key].path)
    end
    return state[key]
end

local function playing(patch) return patch and patch:IsPlaying() end

-- One loop, toward what it should be this frame: playing at `vol` and `pitch`, or
-- (vol nil) faded out over `fadeOut` and then stopped. A deadline in the state, not
-- a timer.Simple: this runs EVERY FRAME while a fade plays out, and it used to queue
-- a fresh timer each time -- a dozen closures per jump per bike, all racing to stop
-- the same patch. A loop that comes back mid-fade simply picks up again.
local function drive(ent, state, key, vol, pitch, fadeIn, fadeOut)
    local stopKey = key .. "Stop"
    if vol and vol > 0.003 then
        local patch = channel(ent, state, key)
        if not playing(patch) then patch:PlayEx(0, pitch) end
        patch:ChangeVolume(vol, fadeIn)
        patch:ChangePitch(math.Clamp(pitch, 1, 255), fadeIn)
        state[stopKey] = nil
        return
    end
    local patch = state[key]
    if not playing(patch) then state[stopKey] = nil return end
    if not state[stopKey] then
        patch:ChangeVolume(0, fadeOut)
        state[stopKey] = CurTime() + fadeOut + 0.05
    elseif CurTime() >= state[stopKey] then
        patch:Stop()
        state[stopKey] = nil
    end
end

-- SPEED IS SPEED. The tyres, the wind and a skid are pitched and levelled by how
-- fast the vehicle is really going, not by how close to its own top speed: they
-- used to be scaled by each vehicle's top, so a city bike at its 20 km/h roared
-- like a road bike at 45. ROLL_REF is where the tyre loop reaches the top of its
-- pitch range (about 45 km/h); WIND_FULL is where the wind is at its loudest.
local ROLL_REF, WIND_FULL = 500, 520
BMX.SoundSpeedRefs = { roll = ROLL_REF, wind = WIND_FULL }

-- The freewheel goes from single ticks to its loop at this many clicks a second.
local BUZZ_AT = 24

local function update(ent, state, dt)
    local def      = ent:Bike()
    local cfg      = ent:Cfg()
    local speed    = ent:GetSpeedUPS()
    local grounded = ent:GetGrounded()
    local frac     = math.Clamp(speed / ROLL_REF, 0, 1)

    -- Muted by the server: stop what is playing and make nothing.
    if not BMX.SoundsOn() then stopAll(state) return end
    local vRide = BMX.VolRide()

    ----------------------------------------------------------------------
    -- Rolling. Tyres hum; a board's, a scooter's and skates' urethane wheels
    -- grind. It comes in over the first walking pace, so a bike creeping
    -- off the line is nearly silent.
    ----------------------------------------------------------------------
    local rollKey = BMX.RollSoundKey(def)
    local S = BMX.Sounds[rollKey]
    drive(ent, state, rollKey, grounded and speed > 12 and S.vol * math.min(1, speed / 160) * vRide or nil,
        Lerp(frac, S.pitch[1], S.pitch[2]), 0.08, 0.15)

    ----------------------------------------------------------------------
    -- Skidding: on at once (a locked wheel is heard the instant it slides),
    -- off quickly.
    ----------------------------------------------------------------------
    S = BMX.Sounds.skid
    drive(ent, state, "skid", grounded and ent:GetSkidding() and speed > 25 and S.vol * vRide or nil,
        Lerp(frac, S.pitch[1], S.pitch[2]), 0.04, 0.08)

    ----------------------------------------------------------------------
    -- THE FREEWHEEL. It clicks whenever the wheel is turning faster than the
    -- cranks are driving it (BMX.FreewheelRate): coasting, and soft-pedalling
    -- too, at the rate the pawls really pass the ratchet's teeth -- the wheel's
    -- turns a second against the cranks', times the hub's engagement points.
    -- Slow, single ticks, each one when its tooth comes round (a phase, not a
    -- timer, so the rhythm follows the wheel as it speeds up). Fast, the loop,
    -- pitched to the same rate. ONLY A FREEWHEEL TICKS (BMX.HasFreewheel): a
    -- fixed gear, a unicycle, a penny-farthing, a coaster hub, a motorbike and
    -- anything pushed or skated used to tick like a BMX whenever they rolled.
    ----------------------------------------------------------------------
    local ratio = BMX.GearRatio(ent, cfg)
    local cadence = ent:GetCadence()
    local rate = speed > 8 and BMX.FreewheelRate(def, speed, cfg.Wheel.radius, ratio, cadence) or 0
    BMX.LastFreewheelRate = rate
    if rate > 0 and rate < BUZZ_AT and vRide > 0 then
        S = BMX.Sounds.tick
        state.tickPhase = (state.tickPhase or 0) + rate * dt
        if state.tickPhase >= 1 then
            -- Never a burst after a hitch: one click, and the phase starts over.
            state.tickPhase = math.min(state.tickPhase - 1, 0.5)
            ent:EmitSound(BMX.SoundFile("tick"), S.level, math.random(S.pitch[1], S.pitch[2]), S.vol * vRide)
        end
    else
        state.tickPhase = 0.9      -- the first tick of the next coast comes at once
    end
    S = BMX.Sounds.freewheel
    drive(ent, state, "freewheel", rate >= BUZZ_AT and S.vol * vRide or nil,
        100 * rate / S.clickHz, 0.05, 0.06)

    ----------------------------------------------------------------------
    -- THE CHAIN, while the cranks turn (BMX.HasChain): rollers meshing on the
    -- ring, pitched to the crank's real speed. A fixed gear's cranks turn
    -- whenever the wheel does, pedalled or not. Louder stamping (sprinting)
    -- than spinning.
    ----------------------------------------------------------------------
    local crank = cadence
    if def.drive.kind == "fixed" then crank = math.max(crank, speed / math.max(cfg.Wheel.radius, 1) / ratio) end
    S = BMX.Sounds.chain
    local meshHz = crank / (2 * math.pi) * S.teeth
    local cv = BMX.HasChain(def) and crank > 0.8 and vRide > 0
        and S.vol * math.Clamp(crank / cfg.Drive.maxCadence, 0.35, 1) * (ent:GetSprinting() and 1.4 or 1) * vRide
    drive(ent, state, "chain", cv or nil, 100 * meshHz / S.meshHz, 0.06, 0.1)

    ----------------------------------------------------------------------
    -- THE MECHANISM'S ONE-SHOTS, from networked state changing: a gear change
    -- (the derailleur; a motorbike's gearbox clunks lower), the kickstand down
    -- and up. The first look at a bike only records the state: a bike spawned
    -- parked is not heard putting its stand down.
    ----------------------------------------------------------------------
    local gear = ent:GetGear()
    if state.gear ~= nil and gear ~= state.gear and gear > 0 and BMX.Gears.Def(ent) then
        S = BMX.Sounds.shift
        ent:EmitSound(BMX.SoundFile("shift"), S.level,
            def.drive.kind == "engine" and math.random(62, 70) or math.random(96, 104), S.vol * vRide)
    end
    state.gear = gear
    local stand = ent:GetStandDown()
    if state.stand ~= nil and stand ~= state.stand and BMX.HasKickstand(def) then
        local key = stand and "stand_down" or "stand_up"
        S = BMX.Sounds[key]
        ent:EmitSound(S.path, S.level, math.random(96, 104), S.vol * vRide)
    end
    state.stand = stand

    ----------------------------------------------------------------------
    -- Wind. Loudness follows speed squared (BMX.WindVolume), and it is the
    -- one sound that does NOT stop in the air: a big air is exactly when it
    -- should be loudest. Only a ridden bike has any: a riderless one rolling
    -- to a stop does not whoosh.
    ----------------------------------------------------------------------
    S = BMX.Sounds.wind
    local wv = IsValid(ent:GetDriver()) and BMX.WindVolume(speed, WIND_FULL) * S.vol * BMX.VolWind() or 0
    drive(ent, state, "wind", wv > 0.01 and wv or nil,
        Lerp(math.Clamp(speed / WIND_FULL, 0, 1), S.pitch[1], S.pitch[2]), 0.15, 0.12)
end

--------------------------------------------------------------------------
-- One sweep for every bike, rather than a Think on each entity: the work is
-- proportional to how many bikes exist and there is exactly one place that
-- cleans up after a removed one.
--------------------------------------------------------------------------
local last = 0

hook.Add("Think", "BMX.Sound", function()
    local now = CurTime()
    local dt  = now - last
    if dt <= 0 then return end
    last = now

    -- Anything that has gone away, or lost its physics, stops making noise.
    for ent, state in pairs(live) do
        if not IsValid(ent) then
            stopAll(state)
            live[ent] = nil
        end
    end

    for _, ent in ipairs(ents.FindByClass("bmx_*")) do
        if ent.IsBMX then
            live[ent] = live[ent] or {}
            update(ent, live[ent], dt)
        end
    end
end)

-- A map change or a disconnect leaves CSoundPatches behind otherwise.
hook.Add("ShutDown", "BMX.SoundStop", function()
    for _, state in pairs(live) do stopAll(state) end
    live = {}
end)
