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

local abs, min, max, floor = math.abs, math.min, math.max, math.floor
local TAU = math.pi * 2

--------------------------------------------------------------------------
-- WHERE WILL IT LAND? The surface under the bike's falling path, found by
-- tracing that path (the mass centre's parabola) Air.landLookAhead seconds
-- ahead in three straight pieces. Its normal, or nil if the path meets
-- nothing in time or only a wall.
--
-- A skatepark is mostly slopes -- transitions, banks, quarter-pipe faces --
-- and the auto-level used to level the bike to WORLD up whatever was below
-- it, so hands off it came down onto a 30-degree transition 27 degrees off
-- it, and onto a 25-degree bank 21 off. Measured in tests/test_landing.lua.
--------------------------------------------------------------------------
function BMX.LandingNormal(ent, phys, cfg)
    local A = cfg.Air
    local vel = phys:GetVelocity()
    local g = physenv.GetGravity()
    local com = phys:LocalToWorld(phys:GetMassCenter())
    local T = A.landLookAhead
    local prev = com
    for i = 1, 3 do
        local t = T * i / 3
        local p = com + vel * t + g * (0.5 * t * t)
        local tr = util.TraceLine({ start = prev, endpos = p, filter = ent.traceFilter,
            mask = MASK_SOLID })
        if tr.Hit and not tr.StartSolid then
            if tr.HitNormal.z >= A.landMinNormalZ then return tr.HitNormal end
            return nil
        end
        prev = p
    end
    return nil
end

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

    -- RMB HELD IN THE AIR MAKES A/D A SPIN, NOT A ROLL. The README always
    -- said so ("RMB + A/D: yaw"); the code added the yaw ON TOP of the roll,
    -- so every 360 attempt was also a barrel roll and came down on its side.
    -- `rollIn` is what A/D mean for the roll axis right now.
    local rollIn = inp.wheelieMod and 0 or inp.lean

    -- A HELD POSE LETS THE SPIN COAST. In the air with Alt down the rotation
    -- keys are the pose keys (sv_input.lua), so a rider carrying a flip into
    -- a superman has let go of the flip: without help the damping stops it
    -- dead and there is no such thing as a Backflip Superman. With a pose up
    -- and the axis not being driven, the damping is only Tricks.poseSpinDamp
    -- of itself. An axis that IS being driven (a scripted rider writes its
    -- own input) keeps all of it, so nothing that steers a spin changes.
    local coast = inp.pose and C.Tricks.poseSpinDamp or 1
    local dPitch = (inp.pitch == 0) and damp * coast or damp
    local dRoll  = (rollIn == 0)    and damp * coast or damp
    local dYaw   = (not inp.wheelieMod or inp.lean == 0) and damp * coast or damp

    local aPitch = inp.pitch * A.pitchAccel * tuck - dPitch * wPitch
    local aRoll  = rollIn    * A.rollAccel  * tuck - dRoll  * wRoll
    local aYaw   =                                 - dYaw   * wYaw

    -- Yaw is unbound unless RMB is held: bikes barely yaw in the air on their
    -- own, and free yaw on A/D would make every landing survivable.
    if inp.wheelieMod then
        aYaw = aYaw + inp.lean * A.yawAccel * tuck
    end

    ----------------------------------------------------------------------
    -- Auto-level, descending only.
    ----------------------------------------------------------------------
    if A.autoLevel > 0 then
        local vel = phys:GetVelocity()

        -- LEVEL TO WHAT IT WILL LAND ON, not to world up. See LandingNormal.
        -- Looked for every third substep: the answer changes slowly and it
        -- costs three traces.
        --
        -- A CORRECTION, NOT A RESCUE: only with a rider, and only for a bike
        -- already within landAssistMax of the surface. A riderless bike
        -- falling over, or a rider coming down upside down, is a crash and
        -- stays one; matching it from there made both land on their wheels.
        st.landTick = (st.landTick or 0) + 1
        if st.landTick % 3 == 1 then
            local n = IsValid(ent:GetDriver()) and BMX.LandingNormal(ent, phys, C) or nil
            if n and math.acos(BMX.Clamp(up:Dot(n), -1, 1)) > A.landAssistMax then n = nil end
            st.landRef = n
        end
        local ref = st.landRef or vector_up

        -- World up only while descending (the original weak pull); a
        -- surface in sight, for the whole flight: a short hop is half over
        -- before it is falling at all.
        if vel.z < -40 or st.landRef then
            local roll = select(1, BMX.Attitude(ent, ref))
            local hands = 1 - abs(rollIn)
            -- Not mid barrel roll: past a quarter turn the rider meant it,
            -- and letting go of the key must not wrench them back.
            if st.landRef and abs(st.spinRoll or 0) < math.pi * 0.5 then
                -- A surface is coming: match it, as firmly as pitch is
                -- levelled. The weak world-up pull below turned a short hop
                -- about 5 degrees, nowhere near a 25-degree bank.
                local k = A.autoLevel / 1.6
                aRoll = aRoll - (A.landRollKp * roll + A.landRollKd * wRoll) * hands * k
            else
                aRoll = aRoll - roll * A.autoLevel * hands
            end
        end

        ------------------------------------------------------------------
        -- PITCH, BUT ONLY WHEN NOBODY IS ASKING FOR IT.
        --
        -- This block used to level roll only, because levelling pitch "would
        -- fight every intentional flip and cancel the nose-down attitude a
        -- rider wants going into a landing". Both of those are a rider
        -- HOLDING a pitch input, so gating on its absence keeps them intact.
        --
        -- What leaving pitch alone cost was every plain bunny hop. The pop
        -- adds Hop.pitchImpulse of nose-up so a hop rolls into a manual, and
        -- in the air nothing but the damping ever took it out again: with no
        -- input a full hop rotated to 50-57 degrees, came down on the back of
        -- the hull and threw the rider. Measured on the tests' plant; the
        -- headless bunny_hop case only ever checked how HIGH the hop went.
        --
        -- Not while flipping: past a quarter turn of accumulated pitch the
        -- rider meant it, and letting go of the stick mid-backflip must not
        -- pull them back the way they came.
        ------------------------------------------------------------------
        if inp.pitch == 0 and abs(st.spinPitch or 0) < math.pi * 0.5 then
            local pitch = select(2, BMX.Attitude(ent, ref))
            aPitch = aPitch - A.pitchLevelKp * pitch - A.pitchLevelKd * wPitch
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
    if BMX.TricksReset then BMX.TricksReset(st) end     -- sv_tricks.lua
end

--------------------------------------------------------------------------
-- Score what just happened. Called on landing, before the crash check, so a
-- trick that ends in a crash is still reported (it just does not count).
--
-- Returns a list of { name = string, count = number, points = number }.
--------------------------------------------------------------------------
-- The rotations are REGISTERED (sh_tricks.lua: Backflip, Frontflip, Barrel
-- Roll, 360), and this reads them back: for each, the full turns of its axis
-- in its direction, at its points a turn.
function BMX.ScoreAir(st)
    local out = {}

    for _, id in ipairs(BMX.TrickOrder) do
        local t = BMX.Tricks[id]
        if t.kind == "spin" and BMX.VehicleAllows(st.def, id) then
            local total = st[t.axis] or 0
            local n = floor(abs(total) / TAU)
            if n > 0 and (t.sign == 0 or (total > 0) == (t.sign > 0)) then
                out[#out + 1] = { name = t.name, count = n, points = n * t.points }
            end
        end
    end

    -- Air time is worth something on its own, so a big gap with no rotation is
    -- still rewarded. Threshold is above what a bunny hop can produce.
    local t = st.airTime or 0
    if t > 1.1 then
        out[#out + 1] = { name = "Air Time", count = 1, points = math.floor(t * 120) }
    end

    -- Frame and bar spins, poses, and the compounds they make (sv_tricks.lua).
    if BMX.ScoreExtras then out = BMX.ScoreExtras(st, out) end

    -- Every trick of this landing says how long the bike was up, so a score
    -- table (BMX (Mode)'s sv_scores.lua) can keep "biggest air" without a second hook. The
    -- table is the same shape it always was, with one more field.
    for _, o in ipairs(out) do o.air = st.airTime or 0 end

    return out
end

--------------------------------------------------------------------------
-- Ground tricks: wheelies and stoppies, scored by how long they were held.
--
-- Called every substep with the wheels' fresh contact state. Returns a trick
-- list (the same shape ScoreAir returns) on the substep a held trick ENDS, and
-- nil otherwise, so the caller only has to act when there is something to pay.
--
-- The state is a small table on `st`, not on the wheels: it has to survive a
-- wheel reporting no contact for a substep while the bike is plainly still on
-- its back wheel, which is what `grace` is for.
--------------------------------------------------------------------------
local MANUAL_NAME = { wheelie = BMX.Tricks.wheelie.name, stoppie = BMX.Tricks.stoppie.name }

function BMX.TrackManual(st, cfg, front, rear, speed, dt)
    local K = cfg.Tricks

    local shape = nil
    if rear.onGround and not front.onGround then
        shape = "wheelie"
    elseif front.onGround and not rear.onGround then
        shape = "stoppie"
    end

    local m = st.manual

    -- The speed floor is for STARTING a trick, not for keeping one. A stoppie
    -- is a hard stop by definition and spends its second half below walking
    -- pace; ending it there cut every stoppie off before it could count. A
    -- bike rocking onto one wheel at a standstill still never starts one.
    if shape and not m and speed < K.manualMinSpeed then shape = nil end
    if shape and (not m or m.kind == shape) then
        if not m then
            m = { kind = shape, held = 0, gone = 0 }
            st.manual = m
        end
        m.held = m.held + dt
        m.gone = 0
        return nil
    end

    if not m then return nil end

    -- The shape is gone (or became the other one). Give it the grace period
    -- before calling the trick over, unless it flipped straight into the other
    -- shape, which is a new trick starting now rather than a bump.
    m.gone = m.gone + dt
    if shape == nil and m.gone < K.manualGrace then return nil end

    st.manual = nil
    if shape then
        st.manual = { kind = shape, held = dt, gone = 0 }
    end

    local min = m.kind == "stoppie" and K.stoppieMin or K.manualMin
    if m.held < min then return nil end

    local per = m.kind == "wheelie" and K.wheeliePerSec or K.stoppiePerSec
    return { {
        name   = MANUAL_NAME[m.kind],
        count  = 1,
        points = math.floor(m.held * per),
        held   = m.held,
    } }
end
