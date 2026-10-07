--[[--------------------------------------------------------------------------
    bmx/cl_sound.lua

    What a BMX sounds like, built entirely out of sounds that ship with Garry's
    Mod.

    WHY NOTHING IS SHIPPED IN THE ADDON. Two reasons, and the second is the one
    that matters. The addon has zero content dependencies on purpose (see
    docs/DESIGN.md section 8): clone it, ride it, no mounts, no downloads, no
    "you are missing content" pink checkerboard for half a server. And audio
    lifted out of another game is the fastest way to have a public Workshop item
    and its repository taken down. Base-game sounds have neither problem: they
    are already on every client, they cost nothing to license, and they add not
    one byte to the .gma.

    They are also, obviously, PLACEHOLDERS chosen by reading filenames. Nobody
    has heard this. Each entry below says what it is standing in for, so that
    replacing it with something recorded or CC0 is a one-line edit against a
    stated intent rather than a guess at what the previous person meant.

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
for _, s in pairs(BMX.Sounds) do
    if s.path then util.PrecacheSound(s.path) end
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

-- The server decided a bell rang (sv_bell.lua); how loud is this listener's.
net.Receive("bmx_bell", function()
    local ent = net.ReadEntity()
    local key = net.ReadString()
    local S = BMX.Sounds[key]
    if not IsValid(ent) or not S or not BMX.SoundsOn() then return end
    local v = BMX.VolBell()
    if v <= 0 then return end
    ent:EmitSound(BMX.SoundFile(key), S.level, S.pitch and math.random(S.pitch[1], S.pitch[2]) or 100,
        S.vol * v)
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

local function stopAll(state)
    if state.roll then state.roll:Stop() end
    if state.skid then state.skid:Stop() end
    if state.wind then state.wind:Stop() end
end

local function channel(ent, state, key)
    if not state[key] then
        state[key] = CreateSound(ent, BMX.Sounds[key].path)
    end
    return state[key]
end

local function playing(patch) return patch and patch:IsPlaying() end

local function update(ent, state, dt)
    local cfg      = ent:Cfg()
    local speed    = ent:GetSpeedUPS()
    local grounded = ent:GetGrounded()

    -- Terminal speed is the natural scale for "how fast is fast": it is what
    -- the drivetrain tops out at, so the mapping stays right if someone retunes
    -- the gearing.
    local topSpeed = BMX.Gears.TopCeiling(ent, cfg)
    local frac     = math.Clamp(speed / math.max(topSpeed, 1), 0, 1)

    -- Muted by the server: stop what is playing and make nothing.
    if not BMX.SoundsOn() then stopAll(state) return end
    local vRide = BMX.VolRide()

    ----------------------------------------------------------------------
    -- Rolling
    ----------------------------------------------------------------------
    local S = BMX.Sounds.roll
    local roll = channel(ent, state, "roll")
    if grounded and speed > 12 then
        if not playing(roll) then roll:PlayEx(0, S.pitch[1]) end
        roll:ChangeVolume(S.vol * math.min(1, frac * 2.2) * vRide, 0.1)
        roll:ChangePitch(Lerp(frac, S.pitch[1], S.pitch[2]), 0.1)
        state.rollStop = nil
    elseif playing(roll) then
        -- Fade, then stop once the fade is done. A deadline in the state, not
        -- a timer.Simple: this branch runs EVERY FRAME while the fade plays out,
        -- and it used to queue a fresh timer each time -- a dozen closures per
        -- jump per bike, all racing to stop the same patch.
        if not state.rollStop then
            roll:ChangeVolume(0, 0.15)
            state.rollStop = CurTime() + 0.2
        elseif CurTime() >= state.rollStop then
            roll:Stop()
            state.rollStop = nil
        end
    end

    ----------------------------------------------------------------------
    -- Skidding
    ----------------------------------------------------------------------
    S = BMX.Sounds.skid
    local skid = channel(ent, state, "skid")
    if grounded and ent:GetSkidding() and speed > 25 then
        if not playing(skid) then skid:PlayEx(0, S.pitch[1]) end
        skid:ChangeVolume(S.vol * vRide, 0.05)
        skid:ChangePitch(Lerp(frac, S.pitch[1], S.pitch[2]), 0.08)
        state.skidStop = nil
    elseif playing(skid) then
        if not state.skidStop then
            skid:ChangeVolume(0, 0.08)
            state.skidStop = CurTime() + 0.12
        elseif CurTime() >= state.skidStop then
            skid:Stop()
            state.skidStop = nil
        end
    end

    ----------------------------------------------------------------------
    -- Freewheel ticks, while coasting
    --
    -- Coasting is "moving, on the ground, cranks not turning". The client has
    -- cadence networked for the HUD, so it can tell without being told.
    ----------------------------------------------------------------------
    S = BMX.Sounds.tick
    -- A FIXED GEAR HAS NO FREEWHEEL (G10): the cranks are on the wheel, so a
    -- coasting fixie is silent where a BMX ticks.
    local fixed = ent:Bike().drive.kind == "fixed"
        -- A motor has no freewheel to tick (cl_motor.lua has its own sound): an engine or an
        -- e-moto is never "coasting with the cranks still".
        or (BMX.Motor and BMX.Motor.IsMotor(ent) and not BMX.Motor.IsAssist(ent))
    local coasting = grounded and speed > 20 and not fixed
        and ent:GetCadence() < cfg.Drive.maxCadence * 0.06

    if coasting and vRide > 0 then
        -- One tick per pawl. Rate follows wheel speed, which is what makes it
        -- read as a freewheel rather than a metronome.
        local rate = math.max(0.02, 1 / math.max(speed * 0.22, 1))
        state.tickAt = (state.tickAt or 0) - dt
        if state.tickAt <= 0 then
            state.tickAt = rate
            ent:EmitSound(S.path, S.level, Lerp(frac, S.pitch[1], S.pitch[2]), S.vol * vRide)
        end
    else
        state.tickAt = 0
    end

    ----------------------------------------------------------------------
    -- Wind. Loudness follows speed squared (BMX.WindVolume), and it is the
    -- one sound that does NOT stop in the air: a big air is exactly when it
    -- should be loudest. Only a ridden bike has any: a riderless one rolling
    -- to a stop does not whoosh.
    ----------------------------------------------------------------------
    S = BMX.Sounds.wind
    local wind = channel(ent, state, "wind")
    -- Wind is measured against a bike's own top speed, so a ridden-out cruiser
    -- and a mini both reach full whoosh at their own top.
    local wv = IsValid(ent:GetDriver()) and BMX.WindVolume(speed, topSpeed * 1.3) * S.vol * BMX.VolWind() or 0
    if wv > 0.01 then
        if not playing(wind) then wind:PlayEx(0, S.pitch[1]) end
        wind:ChangeVolume(wv, 0.15)
        wind:ChangePitch(Lerp(frac, S.pitch[1], S.pitch[2]), 0.2)
    elseif playing(wind) then
        wind:Stop()
    end
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
