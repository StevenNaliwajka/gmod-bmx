--[[--------------------------------------------------------------------------
    bmx/sv_water.lua

    Water. A bike in a pond should not ride as it does on tarmac.

      bmx_water 0|1        water affects bikes at all (server)
      bmx_water_eject 0|1  a rider whose chest goes under is thrown off

    HOW IT LOOKS. Once per bike Think (20 Hz, not per physics substep) the
    points that matter are asked util.PointContents whether they are in water:
    three heights up each wheel, and the rider's chest. A wheel's DEPTH is the
    fraction of those three that are wet, 0, 1/3, 2/3 or 1 -- crude, and exactly
    as precise as drag that scales with it needs to be. The result is kept on
    st.water and the physics substep only reads it, so water costs a handful of
    point queries at 20 Hz per bike and nothing per substep.

    DRAG. Each submerged wheel decelerates the bike by depth * (a*v + b*v^2):
    the quadratic is what water really does, and the small linear term is what
    makes a bike at walking pace STOP in it instead of creeping through
    forever. Applied along -velocity, and never more than the speed it is
    removing, so it can slow a bike to a halt but not push it backwards.

    EJECT. Chest under water for BMX.Water.ejectDelay seconds throws the rider
    (QueueCrash "water": the same ejection, ragdoll, hooks and veto as any
    other crash). The delay is a debounce: a wave of splash or a ramp lip dipping
    into a shallow stream must not unseat anyone for one sample.

    SPLASH. A wheel going from dry to wet at speed plays the splash and the
    engine's own watersplash effect, once, with a short cooldown.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Water = BMX.Water or {}

local W = BMX.Water

local FLAGS = bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY)
CreateConVar("bmx_water", "1", FLAGS,
    "BMX: 1 = water slows bikes and splashes; 0 = water changes nothing.")
CreateConVar("bmx_water_eject", "1", FLAGS,
    "BMX: 1 = a rider whose chest goes under water is thrown off; 0 = they ride on.")

-- Tunables. Per-wheel deceleration in units/s^2 = depth * (linear*v + quad*v^2):
-- a wheel fully under at 300 u/s sheds ~ 3*300 + 0.0035*90000 = ~1200 u/s^2,
-- which stops a bike in under a second, and at 60 u/s a little under 200.
W.linear     = 3.0
W.quad       = 0.0035
W.ejectDelay = 0.3      -- s of chest under water before the rider is thrown
W.splashMin  = 90       -- u/s: slower than this is wading, not splashing
W.splashGap  = 0.6      -- s between splashes on one bike
W.chestRise  = 20       -- units above the seat origin: roughly sternum height

-- CONTENTS_WATER is 32 and CONTENTS_SLIME 16 in the Source engine. Spelled out
-- as a fallback so the offline shim, which has no engine constants, still runs.
local WET = bit.bor(CONTENTS_WATER or 32, CONTENTS_SLIME or 16)

local function wet(pos)
    return bit.band(util.PointContents(pos), WET) ~= 0
end

-- Deceleration (units/s^2) one wheel at `depth` (0..1) puts on a bike at `speed`.
function W.DragAccel(depth, speed)
    if depth <= 0 or speed <= 0 then return 0 end
    return depth * (W.linear * speed + W.quad * speed * speed)
end

-- Should a chest that has been under for `t` seconds throw the rider?
function W.ShouldEject(t) return t >= W.ejectDelay end

-- 0..1: how much of the wheel at `hub` is under, from three points up its
-- diameter along the bike's own up.
function W.WheelDepth(hub, up, radius)
    local n = 0
    for _, k in ipairs({ -0.75, 0, 0.75 }) do
        if wet(hub + up * (k * radius)) then n = n + 1 end
    end
    return n / 3
end

-- Sample the bike (called at 20 Hz from ENT:Think) and act on it: record
-- st.water for the substep, splash, and eject.
function W.Think(ent, now)
    local st = ent.st
    if not st then return end
    if not GetConVar("bmx_water"):GetBool() then
        st.water = nil
        return
    end
    now = now or CurTime()

    local C   = ent:Cfg()
    local up  = ent:GetUp()
    local rest = C.Wheel.restLength
    local depths = {}
    local any = false
    for i, w in ipairs(ent.wheels) do
        -- The hub: the mount dropped by the strut's travel, i.e. the design axle line.
        local hub = ent:LocalToWorld(w.mount - Vector(0, 0, rest))
        depths[i] = W.WheelDepth(hub, up, C.Wheel.radius)
        if depths[i] > 0 then any = true end
    end

    local prev = st.water
    local chest = false
    if IsValid(ent:GetDriver()) then
        chest = wet(ent:LocalToWorld(C.Chassis.seatOffset) + up * W.chestRise)
    end

    st.water = { depths = depths, wet = any, chest = chest,
                 chestSince = chest and (prev and prev.chestSince or now) or nil }

    -- Splash: dry -> wet, at speed.
    if any and not (prev and prev.wet) and (st.speed or 0) >= W.splashMin
        and now >= (ent.splashNext or 0) then
        ent.splashNext = now + W.splashGap
        if BMX.SoundsOn() then
            local S = BMX.Sounds.splash
            ent:EmitSound(BMX.SoundFile("splash"), S.level, math.random(94, 106),
                S.vol * BMX.Clamp((st.speed or 0) / 300, 0.3, 1))
        end
        if util.Effect and EffectData then
            local ed = EffectData()
            ed:SetOrigin(ent:GetPos())
            ed:SetScale(BMX.Clamp((st.speed or 0) / 150, 1, 6))
            util.Effect("watersplash", ed)
        end
    end

    -- Eject: only a rider can be thrown, and only when asked to.
    if chest and GetConVar("bmx_water_eject"):GetBool()
        and W.ShouldEject(now - st.water.chestSince) and ent.QueueCrash then
        ent:QueueCrash("water", 0.25)
    end
end

-- Called from the physics substep: the drag, from what Think last measured.
function W.Drag(ent, phys, vel, dt)
    local st = ent.st
    local w = st and st.water
    if not w or not w.wet then return end
    local speed = vel:Length()
    if speed < 1 then return end
    local a = 0
    for _, d in ipairs(w.depths) do a = a + W.DragAccel(d, speed) end
    -- Never more than the speed there is to remove.
    local dv = math.min(a * dt, speed)
    local f = vel:GetNormalized() * (-dv * phys:GetMass())
    if BMX.FiniteVec(f) then phys:ApplyForceCenter(f) end
end
