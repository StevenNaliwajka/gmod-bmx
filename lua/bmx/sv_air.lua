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
-- AIR CONTROL OFF VERT (G06): the turn, the landing aim and the spine transfer.
-- Called from AirControl for a flight that was classified "vert" (sv_launch.lua)
-- with bmx_air_assist on.
--
-- THE TURN. Riding a bowl or a vert ramp should flow: up, round, back down,
-- without a perfect hand-timed 180 every time. A/D (no RMB) turn the bike about
-- WORLD up at up to Air.vertYawRate; let go and a PD settles the heading on the
-- nearest half turn (a tap under Air.vertMin settles back where it started).
-- The heading is st.vertSpin, integrated from the angular velocity about world
-- up, and scored as "Air 180" with points that grow with the height of the
-- flight (BMX.ScoreAir). Held past a half turn it keeps turning: the assist
-- completes a turn, it does not cap one.
--
-- WORLD UP, not the bike's: off a 70-degree wall the bike is nose-up, so
-- turning about world up is mostly a ROLL of the frame about its long axis, and
-- yaw about the bike's own up axis would swing the nose sideways instead.
--
-- THE LANDING AIM. Coming down, with no key held, a bike within vertAimMax of
-- the fall line of the surface it is about to land on (BMX.LandingNormal) is
-- turned the rest of the way to face down it, back into the ramp. On the landing
-- only, never during the turn: how much of it the rider did stays the rider's.
-- The points are the same with it on or off, so nobody is punished for it.
--
-- THE SPINE TRANSFER. Near the apex (|vz| under Air.spineApexVz) look for the far
-- face (BMX.Launch.FindSpine) and keep it as st.spineTarget. A fresh W press
-- (the key held at takeoff is already ignored until it is let go: sv_input.lua)
-- inside Air.spineWindow of finding it blends the velocity down that face over
-- Air.spineBlend; W is also the nose-down rotation, which pitches the bike over
-- onto it. It is paid as "Spine Transfer" on landing, and being an ordinary
-- trick the combo stays alive across it.
--------------------------------------------------------------------------
function BMX.VertAir(ent, phys, cfg, dt, inp, st, w)
    local A = cfg.Air
    local now = CurTime()
    local vel = phys:GetVelocity()
    local com = phys:LocalToWorld(phys:GetMassCenter())
    st.airPeakZ = max(st.airPeakZ or com.z, com.z)

    -- The heading, about world up. Integrated here (not read off the yaw spin)
    -- because spinYaw is about the BIKE's up axis, which is the wrong one here.
    local wUp = w:Dot(vector_up)
    st.vertSpin = (st.vertSpin or 0) + wUp * dt

    -- WORLD-UP INERTIA: the three principal inertias weighted by how much of
    -- world up each axis carries, so a commanded angular acceleration costs what
    -- it really does at this attitude.
    local fwd, right, up = ent:GetForward(), ent:GetRight(), ent:GetUp()
    local fx, fy, fz = fwd.z, right.z, up.z
    local I = BMX.IRoll(ent) * fx * fx + BMX.IPitch(ent) * fy * fy + BMX.IYaw(ent) * fz * fz

    local held = not inp.wheelieMod and abs(inp.lean) > 0.05
    local alpha
    if held then
        -- Clockwise from above is D. A velocity servo onto the commanded rate.
        st.vertTarget = nil
        st.vertDir = inp.lean > 0 and -1 or 1
        local want = -inp.lean * A.vertYawRate
        alpha = A.vertKd * (want - wUp)
        st.vertTurning = true
    else
        if st.vertTurning then
            -- Let go: settle on a half turn, or back to nothing for a tap.
            st.vertTurning = false
            local spin = st.vertSpin
            if abs(spin) < A.vertMin then
                st.vertTarget = 0
            else
                local n = floor(abs(spin) / math.pi + 0.5)
                if n < 1 then n = 1 end
                st.vertTarget = (spin < 0 and -1 or 1) * n * math.pi
            end
        end
        if st.vertTarget then
            alpha = A.vertKp * (st.vertTarget - st.vertSpin) - A.vertKd * wUp
        end
    end

    -- THE LANDING AIM, descending, with a surface in sight and no turn in
    -- progress (none held, any settle finished).
    local settled = not st.vertTarget or abs(st.vertTarget - st.vertSpin) < 0.25
    -- The fall line of the surface in sight, or of the face the bike left when
    -- that is too steep to count as a landing (LandingNormal wants 60 degrees
    -- or less): coming back down a quarter pipe lands on its lower, flatter
    -- part, but the line it falls along is the whole face's.
    local ref = st.landRef or st.launchNormal
    if not held and settled and vel.z < 0 and ref and not inp.wheelieMod then
        local fall = Vector(ref.x, ref.y, 0)
        local fl = fall:Length()
        local fh = Vector(fwd.x, fwd.y, 0)
        local hl = fh:Length()
        if fl > 0.1 and hl > 0.3 then
            local err = BMX.SignedAngle(fh / hl, fall / fl, vector_up)
            if abs(err) <= A.vertAimMax then
                alpha = A.vertAimKp * err - A.vertAimKd * wUp
            end
        end
    end
    if alpha then
        BMX.ApplyTorque(phys, ent, vector_up, BMX.TorqueFor(I, alpha), dt)
    end

    ----------------------------------------------------------------------
    -- Spine transfer.
    ----------------------------------------------------------------------
    local wDown = inp.pitchTarget < -0.1
    -- G30: dated to when the rider pressed it (inp.cmdAge, 0 unless bmx_lagcomp).
    if wDown and not st.spineW then st.spineWPress = now - (inp.cmdAge or 0) end
    st.spineW = wDown

    if not st.spineTarget and abs(vel.z) < A.spineApexVz and not st.spineDone then
        st.spineTick = (st.spineTick or 0) + 1
        if st.spineTick % 4 == 1 and BMX.Launch and st.launchNormal then
            local sp = BMX.Launch.FindSpine(com, st.launchNormal, cfg, { filter = ent.traceFilter })
            if sp then st.spineTarget, st.spineSeen = sp, now end
        end
    end

    local sp = st.spineTarget
    if sp and not st.spineBlend and not st.spineDone and st.spineWPress
       and now - st.spineSeen <= A.spineWindow and st.spineWPress >= st.spineSeen - A.spineWindow then
        st.spineBlend, st.spineDone = 0, true
    end
    if st.spineBlend and sp then
        -- Toward the way down the far face, at least spineSpeed. The step is a
        -- share of what is left of the blend, so it lands on the target at 0.3 s.
        local want = sp.dir * max(vel:Length(), A.spineSpeed)
        local k = min(1, dt / max(A.spineBlend - st.spineBlend, dt))
        local dv = (want - vel) * k
        if BMX.FiniteVec(dv) then phys:ApplyForceCenter(dv * phys:GetMass()) end
        st.spineBlend = st.spineBlend + dt
        if st.spineBlend >= A.spineBlend then st.spineBlend = nil end
    end
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

    -- OFF A VERT RAMP A/D ARE A TURN, NOT A ROLL (G06, bmx_air_assist). See
    -- VertTurn below. Anywhere else, and with RMB held (the 360), nothing here
    -- changes: the barrel roll stays on A/D.
    local vert = st.launchKind == "vert" and (not BMX.AirAssistOn or BMX.AirAssistOn())
    if vert and not inp.wheelieMod then rollIn = 0 end

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
            if st.landRef and A.landPitchKp then
                -- A surface is coming: match it as firmly as roll is.
                local k = A.autoLevel / 1.6
                aPitch = aPitch - (A.landPitchKp * pitch + A.landPitchKd * wPitch) * k
            else
                aPitch = aPitch - A.pitchLevelKp * pitch - A.pitchLevelKd * wPitch
            end
        end
    end

    if vert then BMX.VertAir(ent, phys, C, dt, inp, st, w) end

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
    -- Vert flights (VertAir): nothing carried over from the last air.
    st.vertSpin, st.vertTarget, st.vertTurning, st.vertDir = 0, nil, false, nil
    st.spineTarget, st.spineSeen, st.spineBlend, st.spineDone = nil, nil, nil, nil
    st.spineW, st.spineWPress, st.spineTick = false, nil, 0
    st.airPeakZ, st.launchKind = nil, nil
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

    -- THE VERT TRICKS (G06, VertAir above). Air 180: a half turn about world up
    -- off a vert wall, per half turn, worth more the higher the flight. Spine
    -- Transfer: the velocity was carried over onto the far face. Neither
    -- is in the rotation table: the heading they count is about WORLD up, not an
    -- axis of the bike.
    if st.launchKind == "vert" and st.vertSpin and BMX.VehicleAllows(st.def, "air180") then
        local A = BMX.Config.Air
        local n = floor(abs(st.vertSpin) / math.pi + 0.25)
        if n > 0 then
            local height = max(0, (st.airPeakZ or 0) - (st.launchZ or 0))
            out[#out + 1] = { name = BMX.Tricks.air180.name, count = n,
                points = n * floor(A.vertBase + A.vertPerUnit * height) }
        end
    end
    if st.spineDone and BMX.VehicleAllows(st.def, "spine_transfer") then
        out[#out + 1] = { name = BMX.Tricks.spine_transfer.name, count = 1,
            points = BMX.Config.Air.spinePoints }
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
local MANUAL_NAME = { wheelie = BMX.Tricks.wheelie.name, stoppie = BMX.Tricks.stoppie.name,
    nosemanual = BMX.Tricks.nose_manual.name }

function BMX.TrackManual(st, cfg, front, rear, speed, dt)
    local K = cfg.Tricks

    local shape = nil
    if rear.onGround and not front.onGround then
        shape = "wheelie"
    elseif front.onGround and not rear.onGround then
        shape = "stoppie"
        -- A stoppie that carries on with the brake off and the weight forward is
        -- a nose manual (PitchControl sets st.noseHold): its own trick, paid by
        -- the second, which chains from the stoppie it grew out of.
        if st.noseHold and BMX.VehicleAllows(st.def, "nose_manual") then shape = "nosemanual" end
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

    local min = m.kind == "stoppie" and K.stoppieMin
        or (m.kind == "nosemanual" and K.noseManualMin or K.manualMin)
    if m.held < min then return nil end

    local per = m.kind == "wheelie" and K.wheeliePerSec
        or (m.kind == "nosemanual" and K.noseManualPerSec or K.stoppiePerSec)
    return { {
        name   = MANUAL_NAME[m.kind],
        count  = 1,
        points = math.floor(m.held * per),
        held   = m.held,
    } }
end
