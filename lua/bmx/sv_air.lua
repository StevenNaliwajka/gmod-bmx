--[[--------------------------------------------------------------------------
    bmx/sv_air.lua

    Air mode: rotation control while both wheels are off the ground, plus the
    rotation bookkeeping that a trick system reads.

    Air control is deliberately far more authoritative than anything on the
    ground. That is not a cheat: a rider in the air really can whip a 11 kg bike
    around underneath 75 kg of themselves, and it is the entire reason the
    genre exists. GTA is generous here too.

    The one honest cheat is `autoLevel`: a weak pull back toward upright applied
    only while descending. Without it every jump ends in a crash for a casual
    player. Set bmx_autolevel 0 for the simulation-purist version.
----------------------------------------------------------------------------]]

BMX = BMX or {}

local abs, min, max = math.abs, math.min, math.max
local TAU = math.pi * 2

--------------------------------------------------------------------------
-- One physics substep of air control.
--
-- `st.angVel` is a WORLD-space angular velocity vector estimated in
-- sv_physics.lua from successive orientations, not from
-- PhysObj:GetAngleVelocity(). See the note there for why.
--------------------------------------------------------------------------
function BMX.AirControl(ent, phys, cfg, dt, inp, st)
    local C = cfg
    local A = C.Air

    local fwd, right, up = ent:GetForward(), ent:GetRight(), ent:GetUp()
    local w = st.angVel or vector_origin

    -- Tucking spins you up, exactly as it does on a real bike and on a diving
    -- board: less moment of inertia, same input.
    local tuck = inp.tuck and 1.35 or 1.0

    -- Rotation rates about each local axis, rad/s.
    local wPitch = w:Dot(right)
    local wRoll  = w:Dot(fwd)
    local wYaw   = w:Dot(up)

    ----------------------------------------------------------------------
    -- Rider input. Terminal rate is accel/damping, so the two numbers
    -- together set both how fast you spin up and how fast you can ever spin.
    ----------------------------------------------------------------------
    local damp = A.damping / tuck

    local aPitch = inp.pitch * A.pitchAccel * tuck - damp * wPitch
    local aRoll  = inp.lean  * A.rollAccel  * tuck - damp * wRoll
    local aYaw   =                                 - damp * wYaw

    -- Yaw is deliberately weak and unbound to a key: bikes barely yaw in the
    -- air, and giving the rider free yaw makes every landing survivable.
    if inp.wheelieMod then
        aYaw = aYaw + inp.lean * A.yawAccel * tuck
    end

    ----------------------------------------------------------------------
    -- Auto-level, descending only.
    ----------------------------------------------------------------------
    if A.autoLevel > 0 then
        local vel = phys:GetVelocity()
        if vel.z < -40 then
            -- Roll only. Levelling PITCH would fight every intentional flip and
            -- would also cancel the nose-down attitude a rider wants going into
            -- a landing.
            local roll = select(1, BMX.Attitude(ent, vector_up))
            local strength = A.autoLevel * (1 - abs(inp.lean))
            aRoll = aRoll - roll * strength
        end
    end

    ----------------------------------------------------------------------
    -- Apply
    ----------------------------------------------------------------------
    BMX.ApplyTorque(phys, ent, right, BMX.TorqueFor(BMX.IPitch(ent), aPitch), dt)
    BMX.ApplyTorque(phys, ent, fwd,   BMX.TorqueFor(BMX.IRoll(ent),  aRoll),  dt)
    BMX.ApplyTorque(phys, ent, up,    BMX.TorqueFor(BMX.IYaw(ent),   aYaw),   dt)

    ----------------------------------------------------------------------
    -- Trick bookkeeping. Integrating the angular velocity about each local
    -- axis is the only way to tell a backflip from a bike that happens to be
    -- upside down: the ANGLE tells you where it is, the INTEGRAL tells you
    -- how it got there.
    ----------------------------------------------------------------------
    st.spinPitch = (st.spinPitch or 0) + wPitch * dt
    st.spinRoll  = (st.spinRoll  or 0) + wRoll  * dt
    st.spinYaw   = (st.spinYaw   or 0) + wYaw   * dt
    st.airTime   = (st.airTime   or 0) + dt
end

--------------------------------------------------------------------------
-- Reset the accumulators. Called the moment air mode engages.
--------------------------------------------------------------------------
function BMX.AirReset(st)
    st.spinPitch = 0
    st.spinRoll  = 0
    st.spinYaw   = 0
    st.airTime   = 0
end

--------------------------------------------------------------------------
-- Score what just happened. Called on landing, before the crash check, so a
-- trick that ends in a crash is still reported (it just does not count).
--
-- Returns a list of { name = string, count = number, points = number }.
--------------------------------------------------------------------------
local TRICKS = {
    -- axis key      full rotations counted    name for +ve / -ve      points per rotation
    { "spinPitch", "Backflip",  "Frontflip", 500 },
    { "spinRoll",  "Barrel Roll", "Barrel Roll", 400 },
    { "spinYaw",   "360",       "360",       250 },
}

function BMX.ScoreAir(st)
    local out = {}

    for _, t in ipairs(TRICKS) do
        local key, posName, negName, per = t[1], t[2], t[3], t[4]
        local total = st[key] or 0
        local n = math.floor(abs(total) / TAU)
        if n > 0 then
            out[#out + 1] = {
                name   = total > 0 and posName or negName,
                count  = n,
                points = n * per,
            }
        end
    end

    -- Air time is worth something on its own, so a big gap with no rotation is
    -- still rewarded. Threshold is above what a bunny hop can produce.
    local t = st.airTime or 0
    if t > 1.1 then
        out[#out + 1] = { name = "Air Time", count = 1, points = math.floor(t * 120) }
    end

    return out
end
