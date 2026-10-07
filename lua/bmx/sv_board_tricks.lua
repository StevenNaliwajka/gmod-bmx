--[[--------------------------------------------------------------------------
    bmx/sv_board_tricks.lua

    THE SKATEBOARD'S AIR TRICKS (G23): the flips, the catch, and what a landing
    pays. The vocabulary (which keys pick which flip, the angles, the catch
    window) is sh_board.lua; the ollie that opens the window is sv_board.lua.

    THE DECK IS KINEMATIC, LIKE THE TAILWHIP'S FRAME (sv_tricks.lua). A flip does
    not rotate the physics body: the chassis, which is the trucks and the rider's
    weight, flies its own ballistic path and levels itself as it always does, and
    the DECK's three angles are a function of the time since the flip began
    (B.FlipAngles), networked as one byte each and drawn by cl_board.lua. That is
    why a flip cannot fling the rider about and why the catch is a rule and not a
    physics outcome:

        landing, the deck must be within 20 degrees of flat and wheels down,
        or the landing bails through the same Crash path as any bad one.

    PAYING. A caught flip pays its points times the catch (clean more, late less),
    the stance (switch and fakie more) and the nollie, under its own name ("Switch
    Nollie Kickflip"), through the ordinary landing list, so the combo, the score
    hooks and the callout need nothing new. It is added to BMX.ScoreExtras, which
    BMX.ScoreAir already calls on every landing, by WRAPPING it: the file that owns
    ScoreExtras (sv_tricks.lua) is not edited.
----------------------------------------------------------------------------]]

BMX = BMX or {}
local B = BMX.Board
local T = B.Tune

local abs, min, max, floor = math.abs, math.min, math.max, math.floor
local TAU = math.pi * 2

--------------------------------------------------------------------------
-- LATCHED KEYS. A key held when the crouch began is not a flip until it has been
-- let go and pressed again: a rider who was pushing with W and crouched is not
-- asking for a front shove-it, and one carving with D is not asking for a heelflip.
-- (sv_input.lua does the same for a key held into the air.)
--------------------------------------------------------------------------
local KEYS = { "w", "s", "a", "d" }

local function freshKeys(b, keys)
    local l = b.latch
    if not l then return keys end
    local fresh = {}
    for _, k in ipairs(KEYS) do
        if not keys[k] then l[k] = false end
        fresh[k] = keys[k] and not l[k]
    end
    return fresh
end

--------------------------------------------------------------------------
-- STARTING A FLIP, in the window after the pop.
--------------------------------------------------------------------------
local function startFlip(ent, st, b, id, now)
    b.flip = { id = id, def = B.Flips[id], t0 = now, nollie = b.nollie,
               switch = b.switch, fakie = b.fakie }
    hook.Run("BMX_BoardFlipStarted", ent, ent:GetDriver(), id)
end

local function pickFlip(ent, st, b, inp, now)
    if b.flip or not b.popAt or now > b.popAt + T.flipWindow then
        b.flipArm = nil
        return
    end
    local keys = freshKeys(b, B.Keys(inp))
    if not (keys.w or keys.s or keys.a or keys.d) then
        b.flipArm = nil
        return
    end
    b.flipArm = b.flipArm or now
    if now - b.flipArm < T.flipSettle then return end
    local id = B.FlipFor(keys)
    if id then startFlip(ent, st, b, id, now) end
end

-- Where the deck is in its flip, every substep: the three angles the client
-- draws.
local function advanceFlip(b, now)
    local f = b.flip
    if not f then
        b.flipRoll, b.flipYaw, b.flipPitch = 0, 0, 0
        return
    end
    b.flipRoll, b.flipYaw, b.flipPitch = B.FlipAngles(f.def, now - f.t0)
end

--------------------------------------------------------------------------
-- THE LANDING. `landing(st, b, now)` judges the flip in progress, if any, against
-- the clock: the entry to pay (or nil), and a fault (or nil) for the landing
-- judge. It is pure over its arguments, so the offline suite checks every flip's
-- window through it.
--------------------------------------------------------------------------
function B.JudgeFlip(flip, now)
    local err = B.CatchError(flip.def, now - flip.t0)
    local grade = B.CatchGrade(err)
    if grade then
        local mult = B.FlipPoints(flip.def, grade, flip.switch, flip.fakie, flip.nollie)
        local name = flip.def.name
        if flip.nollie then name = "Nollie " .. name end
        if flip.switch then name = "Switch " .. name
        elseif flip.fakie then name = "Fakie " .. name end
        return { name = name, count = 1, points = mult, flip = flip.def and flip.id, catch = grade }, nil, err
    end
    local sev = BMX.Clamp(0.35 + (err - T.catchAngle) / math.pi * 0.65, 0, 1)
    return nil, { reason = "flip", severity = sev }, err
end

-- A half turn of body spin, landed: a 180 (a whole turn is the 360 the registry
-- already pays). The board ends up rolling fakie, which the stance tracking sees.
local function spinEntry(st, b)
    local y = abs(st.spinYaw or 0)
    if y >= math.rad(150) and y <= math.rad(230) then
        return { name = BMX.Tricks.board180.name, count = 1, points = BMX.Tricks.board180.points }
    end
end

-- THE WRAP. BMX.ScoreExtras(st, out) is what BMX.ScoreAir adds the frame and bar
-- spins and the poses with; this adds the board's, after.
local baseExtras = BMX.ScoreExtras
function BMX.ScoreExtras(st, out)
    out = baseExtras(st, out)
    local b = st.board
    if not b or not st.def or st.def.balance ~= "board" then return out end
    local now = CurTime()

    -- The stance's multiplier on what the base paid (an air time, a 360).
    local mult = b.switch and T.switchMult or (b.fakie and T.fakieMult or 1)
    if mult ~= 1 then
        for _, o in ipairs(out) do o.points = floor(o.points * mult + 0.5) end
    end

    local s = spinEntry(st, b)
    if s then
        s.points = floor(s.points * mult + 0.5)
        out[#out + 1] = s
    end

    local f = b.flip
    if f then
        local entry, fault = B.JudgeFlip(f, now)
        if entry then
            out[#out + 1] = entry
        elseif fault then
            -- The base may have set a fault of its own (a pose held, a part out of
            -- line); the worse of the two is the landing's.
            local cur = st.landFault
            if not cur or (cur.severity or 0) < fault.severity then st.landFault = fault end
        end
        b.flip = nil
    end
    b.flipRoll, b.flipYaw, b.flipPitch = 0, 0, 0
    return out
end

--------------------------------------------------------------------------
-- A FLIP THAT NEVER BECAME AN AIR. A pop so low that the wheels were back on the
-- ground before the air mode's debounce engaged is not a landing the physics step
-- scores (that only happens leaving air mode), so a flip started and still pending
-- on the ground a moment later is judged here: caught or bailed.
--------------------------------------------------------------------------
local function groundResolve(ent, st, b, now)
    local f = b.flip
    if not f or st.airMode or not st.grounded then return end
    if now - f.t0 < 0.12 then return end
    local entry, fault = B.JudgeFlip(f, now)
    b.flip = nil
    b.flipRoll, b.flipYaw, b.flipPitch = 0, 0, 0
    if entry then
        if ent.AwardTricks then ent:AwardTricks({ entry }) end
    elseif fault and ent.QueueCrash then
        ent:QueueCrash("flip", fault.severity)
    end
end

--------------------------------------------------------------------------
-- TURNING THE BOARD ON THE SPOT. A revert and a powerslide both turn the whole
-- chassis about its vertical axis faster than four tyres will let a torque do it
-- (they resist yaw with every wheel), so, like the kick-turn, the physics object
-- is turned directly: `dyaw` radians about the mass centre.
--------------------------------------------------------------------------
local function turn(phys, dyaw)
    if dyaw == 0 then return end
    local com = phys:LocalToWorld(phys:GetMassCenter())
    local pos = phys:GetPos()
    local c, s = math.cos(dyaw), math.sin(dyaw)
    local rel = pos - com
    local ang = phys:GetAngles()
    ang.y = ang.y + math.deg(dyaw)
    phys:SetAngles(ang)
    phys:SetPos(com + Vector(rel.x * c - rel.y * s, rel.x * s + rel.y * c, rel.z))
    phys:SetAngleVelocity(Vector(0, 0, 0))
end

local function award(ent, b, name, points, extra)
    if not ent.AwardTricks then return end
    local e = { name = B.StancePrefix(b) .. name, count = 1, points = floor(points * B.StanceMult(b) + 0.5) }
    for k, v in pairs(extra or {}) do e[k] = v end
    ent:AwardTricks({ e })
end

--------------------------------------------------------------------------
-- THE REVERT: touch down on a transition and press A or D inside revertWindow, and
-- the board comes round a half turn, still rolling, and the combo stays open (it
-- is a trick of its own, which is how a combo is kept going: sv_combo.lua). The
-- rider's weight is on the surface, so the speed is held through the turn.
--------------------------------------------------------------------------
local function revertStep(ent, phys, C, dt, inp, st, b, now)
    local air = st.airMode and true or false
    if b.wasAir and not air and st.grounded then
        b.touchAt, b.touchNormal = now, st.groundNormal or vector_up
    end
    b.wasAir = air

    if not b.revert and b.touchAt and now - b.touchAt <= T.revertWindow
        and B.RevertSurface(b.touchNormal or vector_up) and (st.speed or 0) > 60 then
        local k = B.Keys(inp)
        if (k.a or k.d) and not (k.a and k.d) then
            b.revert = { t = 0, prev = 0, dir = k.a and 1 or -1, vel = phys:GetVelocity() }
            b.touchAt = nil
        end
    end

    local r = b.revert
    if not r then return end
    r.t = r.t + dt
    local f = min(1, r.t / T.revertTime)
    local e = f * f * (3 - 2 * f)
    turn(phys, r.dir * math.pi * (e - r.prev))
    r.prev = e
    phys:SetVelocity(r.vel * (1 - 0.1 * f))
    if f >= 1 then
        b.revert = nil
        if st.combo then st.combo.last = now end
        award(ent, b, BMX.Tricks.board_revert.name, T.revertPoints)
    end
end

--------------------------------------------------------------------------
-- THE POWERSLIDE: CTRL with A or D on the ground at speed. The board is turned
-- slideAngle off its travel toward the key, and the tyres, taking the speed
-- sideways, scrub it: the slide is the turn and the cost is real. Held at least
-- slideMinTime it pays per second, with the stance's multiplier.
--------------------------------------------------------------------------
local function slideStep(ent, phys, C, dt, inp, st, b, now)
    local bi = B.InputOf(inp)
    local k = B.Keys(inp)
    local speed = st.speed or 0
    local side = (k.a and not k.d) and 1 or ((k.d and not k.a) and -1 or 0)
    local ok = bi.duck and side ~= 0 and st.grounded and not st.grind and not b.manual
        and not b.crouching and not b.kt and not b.revert
    if b.powerslide then
        ok = ok and speed >= T.slideMinSpeed * 0.5
    else
        ok = ok and speed >= T.slideMinSpeed
    end

    if ok then
        if not b.powerslide then b.powerslide, b.slideT = side, 0 end
        b.powerslide = side
        b.slideT = b.slideT + dt
        -- Aim the nose at the travel direction turned slideAngle toward the key.
        local v = phys:GetVelocity()
        local heading = math.atan2(v.y, v.x)
        local want = heading + side * T.slideAngle
        local cur = math.rad(phys:GetAngles().y)
        local err = math.atan2(math.sin(want - cur), math.cos(want - cur))
        turn(phys, BMX.Clamp(err, -T.slideRate * dt, T.slideRate * dt))
    elseif b.powerslide then
        if b.slideT >= T.slideMinTime then
            award(ent, b, BMX.Tricks.board_powerslide.name, b.slideT * T.slideRatePay)
        end
        b.powerslide, b.slideT = nil, nil
    end
end

--------------------------------------------------------------------------
-- SWITCH: LMB on the ground at a roll swaps the feet (a fresh press), so the same
-- board is ridden in the other stance, and what is done in it pays more.
--------------------------------------------------------------------------
local function switchStep(ent, st, b, inp)
    local bi = B.InputOf(inp)
    if bi.swap and not b.swapWas and st.grounded and (st.speed or 0) <= T.swapMaxSpeed
        and not b.manual and not b.crouching then
        b.switch = not b.switch
        if B.SeatStance then B.SeatStance(ent, b) end
    end
    b.swapWas = bi.swap and true or false
end

--------------------------------------------------------------------------
-- THE TICK'S PART: called from BMX.BoardTick (sv_board.lua) every substep.
--------------------------------------------------------------------------
function BMX.BoardTricks(ent, phys, C, dt, inp, st, b, now)
    switchStep(ent, st, b, inp)
    pickFlip(ent, st, b, inp, now)
    advanceFlip(b, now)
    groundResolve(ent, st, b, now)
    revertStep(ent, phys, C, dt, inp, st, b, now)
    slideStep(ent, phys, C, dt, inp, st, b, now)
    if B.ManualStep then B.ManualStep(ent, phys, C, dt, inp, st, b, now) end
end
