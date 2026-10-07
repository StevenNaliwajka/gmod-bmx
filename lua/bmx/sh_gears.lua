--[[--------------------------------------------------------------------------
    bmx/sh_gears.lua

    THE GEAR MODEL (G09). A bike with `gears = { ratios = {...}, start = n }` in
    its registration has 2 to 11 of them; every other bike is single-speed and
    this file is not asked about it.

    A RATIO IS WHAT Drive.gearRatio ALWAYS WAS: wheel revolutions per crank
    revolution (the BMX's 25t ring over a 9t driver is 2.78). The drivetrain
    (sv_physics.lua) used one constant for it; it now asks BMX.GearRatio(ent, cfg),
    which is that constant for a bike with no gears and the current gear's ratio for
    one with. Nothing else about the drive changed, which is the point: a gear is
    only a different answer to "how fast do the legs turn for this wheel speed",
    and so to "how hard does the wheel get pushed for this much leg".

    WHAT KEEPS THE CADENCE SANE. The legs have a torque that falls to nothing at
    Drive.maxCadence (120 rpm), and a bike tops out where that falling torque meets
    drag, a little under it. In a low gear that happens at a low speed and in a high
    one at a high speed; a rider changes gear so the legs stay in the band they
    work best in, and the model's job is only to make every gear's band overlap its
    neighbours', so that SOMEWHERE in the box there is a gear that puts the cadence
    between CAD_LOW and CAD_HIGH at any speed from walking pace up to the top gear's
    top speed. BMX.Gears.Covers checks exactly that, and the registry's own bikes
    are tested against it.

    THE GEAR LIVES ON THE ENTITY, as a networked integer (`Gear`, bmx_base), because
    the client draws the cranks and the HUD from it as well as the server driving
    the wheel from it. 0 means "not set yet" and reads as the registration's start.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Gears = BMX.Gears or {}
local G = BMX.Gears

-- The band a rider's legs are comfortable in, rpm. 60 is where a cyclist labours,
-- 110 is where they spin out; a fit one rides 80-100.
G.CAD_LOW, G.CAD_HIGH = 60, 110

-- The least time between two shifts, seconds. A held wheel notch or a key
-- repeating must not run the whole box in one frame.
G.SHIFT_COOLDOWN = 0.15

local RPM = 60 / (2 * math.pi)

-- The gears definition of a vehicle (an entity, or the registry table), or nil.
function G.Def(thing)
    local def = thing
    if thing and thing.Bike then def = thing:Bike() end
    return def and def.gears or nil
end

function G.Count(thing)
    local g = G.Def(thing)
    return g and #g.ratios or 0
end

-- The gear a bike is in, 1-based, clamped into its box. An entity that has not
-- been told (0) is in the registration's `start`.
function G.Index(ent)
    local g = G.Def(ent)
    if not g then return 0 end
    local i = ent.GetGear and ent:GetGear() or 0
    if i < 1 then i = g.start or math.ceil(#g.ratios / 2) end
    return math.max(1, math.min(#g.ratios, i))
end

-- The ratio the drive runs on for this entity and its config.
function BMX.GearRatio(ent, cfg)
    local g = G.Def(ent)
    if not g then return cfg.Drive.gearRatio end
    return g.ratios[G.Index(ent)]
end

-- Crank speed, in rpm, for a wheel speed in u/s in a given ratio.
function G.CadenceRpm(cfg, ratio, speed)
    return speed / cfg.Wheel.radius / ratio * RPM
end

-- The speed, in u/s, at which a given crank speed is reached in a ratio.
function G.SpeedAt(cfg, ratio, rpm)
    return rpm / RPM * ratio * cfg.Wheel.radius
end

-- The legs' ceiling in a ratio: the speed at Drive.maxCadence. Terminal speed
-- is a little under it, where the falling torque meets drag.
function G.CeilingSpeed(cfg, ratio)
    return cfg.Drive.maxCadence * ratio * cfg.Wheel.radius
end

-- The fastest the legs can take a vehicle: the top gear's ceiling for a bike with
-- gears, the one ratio's for any other. What "how fast is fast" is measured
-- against for the wind and the grind's pitch and the rider's tuck.
function G.TopCeiling(ent, cfg)
    -- A motor's own top speed (sh_motor.lua): an engine's redline in the top gear,
    -- a throttle motor's maxSpeed. The legs' ceiling below means nothing to either.
    local top = BMX.Motor and BMX.Motor.TopSpeed and BMX.Motor.TopSpeed(ent, cfg)
    if top then return top end
    local g = G.Def(ent)
    return G.CeilingSpeed(cfg, g and g.ratios[#g.ratios] or cfg.Drive.gearRatio)
end

-- The gears, if any, whose cadence at `speed` is in the comfortable band, as a
-- list of indices, lowest gear first.
function G.InBand(def, cfg, speed)
    local g = G.Def(def)
    local out = {}
    if not g then return out end
    for i, r in ipairs(g.ratios) do
        local c = G.CadenceRpm(cfg, r, speed)
        if c >= G.CAD_LOW and c <= G.CAD_HIGH then out[#out + 1] = i end
    end
    return out
end

-- The gear that puts the cadence nearest `rpm` (default 90) at `speed`: what an
-- automatic gearbox, a bot or a test that wants a sensible gear asks for.
function G.Best(def, cfg, speed, rpm)
    local g = G.Def(def)
    if not g then return 0 end
    rpm = rpm or 90
    local best, bestD = 1, math.huge
    for i, r in ipairs(g.ratios) do
        local d = math.abs(G.CadenceRpm(cfg, r, speed) - rpm)
        if d < bestD then best, bestD = i, d end
    end
    return best
end

-- Does the box keep the cadence in the band at every speed from `lowSpeed` up to
-- the top gear's ceiling? Returns true, or false and the first speed it fails
-- at. Checked by stepping the speed, which is as exact as it needs to be: the
-- bands are intervals, so a gap would be wider than the step.
function G.Covers(def, cfg, lowSpeed)
    local g = G.Def(def)
    if not g then return false, 0 end
    local top = G.SpeedAt(cfg, g.ratios[#g.ratios], G.CAD_HIGH)
    local v = lowSpeed
    while v <= top do
        if #G.InBand(def, cfg, v) == 0 then return false, v end
        v = v + 2
    end
    return true
end

-- "gear 4/9" for the HUD, or nil for a bike with one speed.
function G.Label(ent)
    local n = G.Count(ent)
    if n == 0 then return nil end
    return string.format("gear %d/%d", G.Index(ent), n)
end
