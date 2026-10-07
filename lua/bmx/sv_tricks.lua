--[[--------------------------------------------------------------------------
    bmx/sv_tricks.lua

    TAILWHIP, BARSPIN AND STYLE POSES (G03, G17): the tricks that are not a
    rotation of the whole bike. sv_air.lua counts how far the BIKE has turned;
    this counts how far a PART has, and which pose the rider is holding.

    THE PARTS ARE KINEMATIC. A tailwhip swings the frame (rear wheel, cranks,
    seat) round the steer axis while the bars and the rider stay put; a barspin
    spins the bars. Neither is simulated. While the input is held the part
    turns at Tricks.whipRate / barRate, and what the physics sees of it is one
    small thing: the rider throws the frame, so the chassis answers with a
    little yaw the other way (Tricks.whipKick). The angle lives on the state
    (st.parts.whip.angle, radians) and is networked as one byte, which is all
    cl_init.lua needs to draw it.

    LETTING GO. A rider who lets go past 270 degrees of a turn has done it
    and the part finishes by itself; before 90 degrees it springs back to
    where it started; in between it stays where it is, out of line, and the
    landing is judged on that:

        landing with a part further than Tricks.partMaxOut (30 deg) from a
        whole turn BAILS through the same Crash path as any bad landing, so
        the combo is lost and the tricks are not paid.

    POSES are held, scored per Tricks.poseTick (0.1 s) once held
    Tricks.poseMinHold, and you must be out of one before the wheels touch:
    landing in a pose bails. A pose and a rotation in the same air are ONE
    trick with a compound name ("Backflip Superman"), paid as both plus
    Tricks.compoundBonus; a whip and a bar in the same air are "Tailwhip to
    Barspin".

    The keys are decoded in sv_input.lua (inp.whip, inp.bar, inp.pose); the
    registry they are paid through is sh_tricks.lua.
----------------------------------------------------------------------------]]

BMX = BMX or {}

local abs, floor, min, max = math.abs, math.floor, math.min, math.max
local TAU = math.pi * 2

--------------------------------------------------------------------------
-- State. Created lazily so a state built before this file loaded (or by a
-- test) works the same.
--------------------------------------------------------------------------
local function parts(st)
    local P = st.parts
    if not P then
        P = { whip = { angle = 0, dir = 0 }, bar = { angle = 0, dir = 0 } }
        st.parts = P
    end
    return P
end

local function poseState(st)
    local p = st.pose
    if not p then
        p = { cur = nil, held = {} }
        st.pose = p
    end
    return p
end

local function done(st)
    st.partDone = st.partDone or { whip = 0, bar = 0 }
    return st.partDone
end

-- How far a part is from the nearest whole turn, radians, 0 .. pi.
function BMX.PartOffLine(angle)
    local a = abs(angle) % TAU
    return min(a, TAU - a)
end

-- Out of line, as the rule on landing measures it, for both parts.
function BMX.PartsOffLine(st)
    local P = parts(st)
    return BMX.PartOffLine(P.whip.angle), BMX.PartOffLine(P.bar.angle)
end

-- The part is back on a whole turn: bank the turns it made.
local function settle(st, name, p)
    local n = floor(abs(p.angle) / TAU + 0.5)
    if n > 0 then done(st)[name] = done(st)[name] + n end
    p.angle, p.mode, p.dir = 0, nil, 0
end

--------------------------------------------------------------------------
-- One part, one substep. `input` is -1, 0 or +1 (the way to turn).
--
--   hold     the key is down: turn at `rate`, the way it was first pressed
--   finish   let go with > autoComplete of the turn done: carry on to the top
--   back     let go with < snapBack: turn back to where it started
--   (none)   let go in between: stay put, out of line
--------------------------------------------------------------------------
local function stepPart(st, name, p, input, rate, dt, K)
    if input ~= 0 then
        if p.mode == nil or p.mode == "stuck" or p.mode == "finish" or p.mode == "back" then
            -- A press starts, or restarts, a spin. Its way is the way it was
            -- already going, or the key's if it is on a whole turn.
            if p.angle == 0 or p.dir == 0 then p.dir = input end
            p.mode = "hold"
        end
        p.angle = p.angle + p.dir * rate * dt
        return
    end

    if p.mode == "hold" then
        local frac = abs(p.angle) % TAU
        if frac >= K.autoComplete then p.mode = "finish"
        elseif frac < K.snapBack then p.mode = "back"
        else p.mode = "stuck" end
    end

    local mode = p.mode
    if mode == "finish" then
        -- On to the next whole turn, the way it was going.
        local mag = abs(p.angle) + rate * dt
        local target = (floor(abs(p.angle) / TAU + 1e-9) + 1) * TAU
        if mag >= target - 1e-9 then
            p.angle = p.dir * target
            settle(st, name, p)
        else
            p.angle = p.dir * mag
        end
    elseif mode == "back" then
        -- Back to the whole turn it had already made (none, for a first one).
        local mag = abs(p.angle) - rate * dt
        local base = floor(abs(p.angle) / TAU + 1e-9) * TAU
        if mag <= base + 1e-9 then
            p.angle = p.dir * base
            settle(st, name, p)
        else
            p.angle = p.dir * mag
        end
    end
end

-- Is it moving by itself right now (for the wobble)? Returns the way, or 0.
local function moving(p)
    if p.mode == "hold" or p.mode == "finish" then return p.dir end
    if p.mode == "back" then return -p.dir end
    return 0
end

--------------------------------------------------------------------------
-- Pay held poses (and clear them). Used on landing (ScoreExtras) and when a
-- manual ends. Returns a list of { name, count, points, pose, held }.
--------------------------------------------------------------------------
local function payPoses(st, K)
    local ps = poseState(st)
    local out = {}
    for _, name in ipairs(BMX.PoseNames) do
        local held = ps.held[name]
        if held and held >= K.poseMinHold then
            local t = BMX.TrickForPose(name)
            local ticks = floor(held / K.poseTick + 1e-6)
            if t and ticks > 0 then
                out[#out + 1] = { name = t.name, count = 1, points = ticks * t.points,
                                  pose = name, held = held }
            end
        end
    end
    ps.held = {}
    return out
end

--------------------------------------------------------------------------
-- Compound names. Called on a trick list.
--
--   Tailwhip + Barspin             -> "Tailwhip to Barspin"
--   a rotation + a pose            -> "Backflip Superman"
--
-- `tricks` on a merged entry is how many tricks it stands for, which the
-- combo counts (sv_combo.lua) so a compound does not shrink the chain.
--------------------------------------------------------------------------
local function isRotation(name)
    for _, t in pairs(BMX.Tricks) do
        if (t.kind == "spin" or t.kind == "part") and t.name == name then return true end
    end
    return false
end

local function label(e) return ((e.count or 1) > 1 and (e.count .. "x ") or "") .. e.name end

function BMX.MergeCompounds(out, K)
    local whip, bar
    for i, e in ipairs(out) do
        if e.name == BMX.Tricks.tailwhip.name then whip = i end
        if e.name == BMX.Tricks.barspin.name then bar = i end
    end
    if whip and bar then
        local w, b = out[whip], out[bar]
        local merged = { name = label(w) .. " to " .. label(b), count = 1,
                         points = w.points + b.points, tricks = 2 }
        local first, second = min(whip, bar), max(whip, bar)
        table.remove(out, second)
        out[first] = merged
    end

    -- One rotation (the most valuable) and one pose (the most valuable).
    local rot, pose
    for i, e in ipairs(out) do
        if e.pose then
            if not pose or e.points > out[pose].points then pose = i end
        elseif e.tricks or isRotation(e.name) then
            if not rot or e.points > out[rot].points then rot = i end
        end
    end
    if rot and pose then
        local r, p = out[rot], out[pose]
        local sum = r.points + p.points
        local merged = {
            name = r.name .. " " .. p.name, count = r.count or 1,
            points = sum + floor(sum * K.compoundBonus),
            tricks = (r.tricks or 1) + 1, pose = p.pose,
        }
        out[rot] = merged
        table.remove(out, pose)
    end
    return out
end

--------------------------------------------------------------------------
-- LANDING. Called from BMX.ScoreAir with its trick list, so the one call
-- BMX.ScoreAir(st) still returns everything the air earned. It:
--   * works out the landing's FAULTS (a part out of line, a pose still held)
--     for ENT:JudgeLanding to read, before anything is cleared;
--   * settles the parts to their nearest whole turn;
--   * adds the part and pose tricks, merged into compounds.
--------------------------------------------------------------------------
function BMX.ScoreExtras(st, out)
    local K = BMX.Config.Tricks
    local P, ps = parts(st), poseState(st)

    st.landFault = nil
    local offW, offB = BMX.PartsOffLine(st)
    if ps.cur then
        st.landFault = { reason = "pose", severity = 0.6 }
    elseif offW > K.partMaxOut or offB > K.partMaxOut then
        local off = max(offW, offB)
        st.landFault = { reason = offW >= offB and "whip" or "bars",
                         severity = BMX.Clamp(0.35 + off / math.pi * 0.65, 0, 1) }
    end

    for _, name in ipairs({ "whip", "bar" }) do settle(st, name, P[name]) end
    local d = done(st)
    for _, t in ipairs(BMX.TricksOfKind("part")) do
        local n = d[t.part]
        if n > 0 then out[#out + 1] = { name = t.name, count = n, points = n * t.points } end
        d[t.part] = 0
    end

    -- Custom tricks' banked points (a registered trick with an onTick).
    for id, pts in pairs(st.trickBank or {}) do
        if pts > 0 and BMX.Tricks[id] then
            out[#out + 1] = { name = BMX.Tricks[id].name, count = 1, points = floor(pts) }
        end
    end
    st.trickBank = nil

    for _, e in ipairs(payPoses(st, K)) do out[#out + 1] = e end
    ps.cur = nil
    return BMX.MergeCompounds(out, K)
end

-- Read by ENT:JudgeLanding. Returns reason, severity or nil; consumed.
function BMX.LandingFault(st)
    local f = st.landFault
    st.landFault = nil
    if f then return f.reason, f.severity end
end

-- A new air: nothing carried over from the last one.
function BMX.TricksReset(st)
    parts(st)
    st.pose = { cur = nil, held = {} }
    st.partDone = { whip = 0, bar = 0 }
    st.trickBank = nil
    st.landFault = nil
end

-- The one byte of each: where a part is in its turn, 0..255.
local function byteOf(angle)
    local a = angle % TAU
    return floor(a / TAU * 256 + 0.5) % 256
end

function BMX.PackTrickBits(st)
    local P, ps = parts(st), poseState(st)
    local id = ps.cur and BMX.PoseIDs[ps.cur] or 0
    return byteOf(P.whip.angle) + byteOf(P.bar.angle) * 256 + id * 65536
end

--------------------------------------------------------------------------
-- One physics substep. Returns a trick list to pay on the ground (a barspin
-- finished in a manual, a pose held through one), or nil.
--------------------------------------------------------------------------
function BMX.TricksTick(ent, phys, cfg, dt, inp, st)
    local K = cfg.Tricks
    local P, ps = parts(st), poseState(st)
    local air = st.airMode and true or false
    local manual = (not air) and st.manual ~= nil
    local pay

    ------------------------------------------------------------------
    -- Parts.
    ------------------------------------------------------------------
    local whipIn = air and (inp.whip or 0) or 0
    local barIn  = (air or manual) and (inp.bar or 0) or 0
    stepPart(st, "whip", P.whip, whipIn, K.whipRate, dt, K)
    stepPart(st, "bar",  P.bar,  barIn,  K.barRate,  dt, K)

    if not air then
        -- On the ground a whip is not a thing, and the bars only spin in a
        -- manual. Anything left over springs back, nothing is paid for it.
        if P.whip.angle ~= 0 then P.whip.angle, P.whip.mode, P.whip.dir = 0, nil, 0 end
        if not manual and P.bar.angle ~= 0 then P.bar.angle, P.bar.mode, P.bar.dir = 0, nil, 0 end
        -- A barspin finished in a manual pays on the spot.
        local d = done(st)
        if d.bar > 0 then
            local t = BMX.Tricks.barspin
            pay = { { name = t.name, count = d.bar, points = d.bar * t.points } }
            d.bar = 0
        end
        d.whip = 0
    end

    -- The chassis answers a thrown frame with a little yaw the other way.
    if air and phys and K.whipKick > 0 then
        local w = moving(P.whip)
        if w ~= 0 then
            BMX.ApplyTorque(phys, ent, ent:GetUp(),
                BMX.TorqueFor(BMX.IYaw(ent), -w * K.whipKick), dt)
        end
    end

    ------------------------------------------------------------------
    -- Poses.
    ------------------------------------------------------------------
    local want = inp.pose
    local t = want and BMX.TrickForPose(want)
    if t and t.canStart and not t.canStart(st, inp) then t = nil end
    ps.cur = t and want or nil
    if ps.cur then ps.held[ps.cur] = (ps.held[ps.cur] or 0) + dt end

    -- Held through a manual and let go on the ground: that is where an X-up
    -- in a wheelie is paid, when the wheelie is over.
    if not air and not manual and next(ps.held) ~= nil then
        local list = payPoses(st, K)
        if #list > 0 then
            pay = pay or {}
            for _, e in ipairs(list) do pay[#pay + 1] = e end
        end
    end

    ------------------------------------------------------------------
    -- Whatever else is registered (a modder's trick, a vehicle's grab).
    ------------------------------------------------------------------
    for _, tr in ipairs(BMX.TickList) do
        if not tr.canStart or tr.canStart(st, inp) then
            local pts = tr.onTick(ent, st, inp, dt)
            if type(pts) == "number" and pts > 0 then
                st.trickBank = st.trickBank or {}
                st.trickBank[tr.id] = (st.trickBank[tr.id] or 0) + pts
            end
        end
    end

    ------------------------------------------------------------------
    -- The wire: one int, three bytes.
    ------------------------------------------------------------------
    if ent.SetTrickBits then
        local bits = BMX.PackTrickBits(st)
        if bits ~= st.trickBits then
            st.trickBits = bits
            ent:SetTrickBits(bits)
        end
    end
    return pay
end

-- No rider: nothing is held, nothing is spinning.
function BMX.TricksIdle(ent, st)
    if not st.parts and not st.pose then return end
    local P = parts(st)
    P.whip.angle, P.whip.mode, P.whip.dir = 0, nil, 0
    P.bar.angle, P.bar.mode, P.bar.dir = 0, nil, 0
    st.pose = { cur = nil, held = {} }
    st.partDone = { whip = 0, bar = 0 }
    if ent and ent.SetTrickBits and st.trickBits ~= 0 then
        st.trickBits = 0
        ent:SetTrickBits(0)
    end
end
