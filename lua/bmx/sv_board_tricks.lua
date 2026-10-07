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
-- THE TICK'S PART: called from BMX.BoardTick (sv_board.lua) every substep.
--------------------------------------------------------------------------
function BMX.BoardTricks(ent, phys, C, dt, inp, st, b, now)
    pickFlip(ent, st, b, inp, now)
    advanceFlip(b, now)
    groundResolve(ent, st, b, now)
end
