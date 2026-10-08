--[[--------------------------------------------------------------------------
    bmx/sv_board_grind.lua

    THE SKATEBOARD'S GRINDS, SLIDES AND MANUALS (G23 M3), and the balance meter
    they share.

    GRINDS ARE sv_grind.lua's. The rail finder, the lock-on, the placing of the
    vehicle on the rail every substep and the end of it are the bike's and are
    reused whole. What the board adds is a VEHICLE'S OWN MOVES
    (`grindPoints.moves`, one more key in the platform's grind points): when the
    rail is found, the vehicle is asked which move this is, and answers with the
    point of itself that rides the rail, how it is turned and pitched, and what it
    is called and pays. The ten moves and the rule for choosing among them are
    data in sh_board.lua (B.Grinds, B.ClassifyGrind): a board turned along the rail
    is grinding (50-50, 5-0, nosegrind, crooked, smith, feeble), turned across it
    sliding (boardslide, lipslide, noseslide, tailslide), and the keys held as it
    locks on pick the one.

    WHAT WRAPS WHAT. sv_physics.lua calls BMX.TryGrind, BMX.GrindStep and
    BMX.EndGrind by name every substep, so this file replaces those names with
    versions that do the board's part and hand on to the originals for a bike (and
    for the board, after its own part). sv_grind.lua is edited only where the
    originals had to learn about a move.

    THE BALANCE METER (B.MeterStep) is what keeps a long grind or manual from being
    free: it drifts away from zero, faster the further it is, and A and D (on a
    rail) or W and S (in a manual) push it back. Past one either way the trick is
    lost: a grind throws the rider off the rail and a manual that loops out bails;
    one that simply drops back to the ground ends and pays.

    HOLD SPACE TO GRIND, RELEASE TO POP OUT. The rail is locked on while SPACE is
    down in the air (or on contact with bmx_board_autogrind) and the release is an
    ollie off it, the board's own preload-and-pop in sv_grind.lua's terms (the
    bike's hop). The pop opens the flip window, so a grind can end in a kickflip.
----------------------------------------------------------------------------]]

BMX = BMX or {}
local B = BMX.Board
local T = B.Tune

local abs, min, max, floor = math.abs, math.min, math.max, math.floor

local function isBoard(ent) return B.IsBoard and B.IsBoard(ent) end

local function gravity()
    local g = physenv.GetGravity()
    return g and g:Length() or 600
end

--------------------------------------------------------------------------
-- THE MOVES, as sv_grind.lua's TryGrind asks for them: (ent, st, rail, dh, vel)
-- -> a move or nil. `rail.kind` is "crank" (a round rail, which both sides drop
-- away from) or "peg" (an edge); `dh` the rail's horizontal direction.
--------------------------------------------------------------------------
function B.GrindMoves(ent, st, rail, dh, vel)
    local b = BMX.BoardState(st)
    local f = ent:GetForward()
    local fh = Vector(f.x, f.y, 0)
    local len = fh:Length()
    if len < 1e-3 then return nil end
    fh = fh / len

    -- A flip not yet caught is not a board that can lock on: it would be placed
    -- on the rail upside down. (Inside the 20 degrees it is a caught flip, paid by
    -- BMX.ScoreAir on the way in.)
    local fl = b.flip
    if fl and B.CatchError(fl.def, CurTime() - fl.t0) > T.catchAngle then return nil end

    local angle = math.acos(BMX.Clamp(abs(fh:Dot(dh)), 0, 1))
    local along = B.IsAlong(angle)
    local edge = rail.kind == "peg"
    local id = B.ClassifyGrind(B.Keys(ent.input), along, edge)
    local g = B.Grinds[id]

    -- WHICH WAY IT IS TURNED off the rail's line: the way the board already is (the
    -- side its nose is on), or for a smith and a feeble the side of the ledge they
    -- are about -- the drop, or the top. A board pointing against the rail's
    -- direction (fakie) is turned round half a turn, and the angle off the line is
    -- then the other way for the nose to stay on the same side.
    local L = (dh.x * fh.y - dh.y * fh.x) >= 0 and 1 or -1
    if g.toward and edge then
        local topLeft = Vector(0, 0, 1):Cross(dh):Dot(rail.side) > 0
        local drop = topLeft and -1 or 1
        L = (g.toward == "drop") and drop or -drop
    end
    local reverse = along and fh:Dot(dh) < 0
    local yaw
    if not along then
        yaw = L * g.yaw
    elseif reverse then
        yaw = -L * abs(g.yaw) + math.pi
    else
        yaw = L * abs(g.yaw)
    end

    local name = B.StancePrefix(b) .. g.name
    return {
        id = id, name = name, mult = g.mult * B.StanceMult(b),
        yaw = yaw, pitch = g.pitch, signed = false, reverse = false,
        crank = B.GrindContact(id, false),
        peg = function(sgn) return B.GrindContact(id, true, sgn) end,
    }
end

--------------------------------------------------------------------------
-- LOCKING ON.
--------------------------------------------------------------------------
local baseTry, baseStep, baseEnd = BMX.TryGrind, BMX.GrindStep, BMX.EndGrind

function BMX.TryGrind(ent, phys, cfg, st, vel)
    if not isBoard(ent) then return baseTry(ent, phys, cfg, st, vel) end
    local b = BMX.BoardState(st)
    local bi = B.InputOf(ent.input)
    -- SPACE held in the air, or the rider's own bmx_board_autogrind.
    if not (bi.jump or b.autogrind) then return false end
    if not baseTry(ent, phys, cfg, st, vel) then return false end

    local g = st.grind
    if g and g.move then
        -- A flip caught on the way in is paid now. (BMX.ScoreAir does it when the air
        -- mode was engaged; a lock-on inside its debounce leaves the flip standing.)
        if b.flip then
            local entry = B.JudgeFlip(b.flip, CurTime())
            b.flip = nil
            b.flipRoll, b.flipYaw, b.flipPitch = 0, 0, 0
            if entry and ent.AwardTricks then ent:AwardTricks({ entry }) end
        end
        ent:SetGrind(B.SparkCode[g.move] or 4)
        g.bal = B.MeterStart(math.random() * 6.28, T.meterGrind)
        b.meter = 0
        b.slide = not B.Grinds[g.move].along
        b.jumpWas = bi.jump
        b.crouching, b.crouchT, b.kt = false, 0, nil
        b.manual, b.pitchTarget, b.pitchFF = nil, 0, 0
        B.Sync(ent, st, b, CurTime())
        hook.Run("BMX_BoardGrind", ent, ent:GetDriver(), g.move)
    end
    return true
end

--------------------------------------------------------------------------
-- ON THE RAIL: the meter, and SPACE's release as the pop.
--------------------------------------------------------------------------
function BMX.GrindStep(ent, phys, cfg, dt, inp, st)
    if isBoard(ent) and st.grind and st.grind.bal then
        local b = BMX.BoardState(st)
        local bi = B.InputOf(inp)
        local g = st.grind

        -- A and D push the meter: the key toward the side it is drifting is wrong.
        local side = bi.side ~= 0 and bi.side or (inp.leanTarget or 0)
        b.meter = BMX.Clamp(B.MeterStep(g.bal, dt, side, T.meterGrind), -1.2, 1.2)
        if abs(g.bal.v) >= 1 then
            g.void = true
            BMX.EndGrind(ent, phys, cfg, st, "balance")
            if ent.QueueCrash then ent:QueueCrash("balance", 0.45) end
            return
        end

        -- SPACE down is the preload, its release the pop (sv_grind.lua's hop).
        local down = bi.jump and true or false
        if down then
            ent.hopHeld = true
        else
            if b.jumpWas then ent.hopRelease = true end
            ent.hopHeld = false
        end
        b.jumpWas = down
        B.Sync(ent, st, b, CurTime())
    end
    return baseStep(ent, phys, cfg, dt, inp, st)
end

--------------------------------------------------------------------------
-- OFF THE RAIL. A hop is an ollie off it: the flip window opens with the keys held
-- now latched, so the grind's own direction key is not a front shove-it.
--------------------------------------------------------------------------
function BMX.EndGrind(ent, phys, cfg, st, why, charge)
    local wasBoard = isBoard(ent) and st.grind ~= nil
    baseEnd(ent, phys, cfg, st, why, charge)
    if not wasBoard then return end
    local b = BMX.BoardState(st)
    b.meter, b.slide, b.jumpWas = nil, false, false
    ent.hopHeld, ent.hopRelease = false, false
    if why == "hop" then
        local k = B.Keys(ent.input)
        b.latch = { w = k.w, s = k.s, a = k.a, d = k.d }
        b.popAt, b.nollie, b.flip = CurTime(), false, nil
        b.popReady = CurTime() + T.popCooldown
        if BMX.SoundsOn() then
            local S = BMX.Sounds.board_pop
            if S then ent:EmitSound(BMX.SoundFile("board_pop"), S.level, math.random(96, 108), S.vol) end
        end
    end
    B.Sync(ent, st, b, CurTime())
end

--------------------------------------------------------------------------
-- THE MANUAL. RMB on the ground at speed lifts the nose (ALT with it, the tail: a
-- nose manual) and the pitch hold carries it at manualPitch; W and S keep the
-- meter near zero. Held at least manualMin it pays per second, with the stance
-- multiplier; the combo stays open while it runs (st.manual, which sv_combo.lua
-- watches), so a grind can roll into one and a manual into a flip.
--------------------------------------------------------------------------
local function pitchFeedForward(ent, phys, st, b, kind)
    -- The weight of the board over the wheels that are on the ground: the support's
    -- force at the contact patch, below and behind (or ahead of) the mass centre,
    -- tips it back down, and what holds the pitch has to cancel that. Geometry
    -- and the weight, not the measured force, so it does not depend on the thing
    -- it controls (the same lesson as sv_balance.lua's roll feed-forward).
    local com = phys:LocalToWorld(phys:GetMassCenter())
    local f = ent:GetForward()
    local fh = Vector(f.x, f.y, 0)
    if fh:Length() < 1e-3 then return 0 end
    fh:Normalize()
    local sum, n = 0, 0
    for _, w in ipairs(ent.wheels) do
        local support = (kind == "manual") and not w.isFront or (kind == "nose") and w.isFront
        if w.onGround and support then
            sum = sum + (w.contactPos - com):Dot(fh)
            n = n + 1
        end
    end
    if n == 0 then return 0 end
    local d = -(sum / n)          -- how far the mass centre is ahead of the support
    local ff = phys:GetMass() * gravity() * d / BMX.IPitch(ent)
    return BMX.Clamp(ff, -120, 120)
end

local function endManual(ent, st, b, why)
    local held = b.manualT or 0
    local kind = b.manual
    b.manual, b.meter, b.pitchTarget, b.pitchFF, b.mtr = nil, nil, 0, 0, nil
    st.manual = nil
    -- A manual lost (dropped or looped out) is over until RMB is let go: held
    -- on, it lifted the nose again the same tick, and a rider who had stopped
    -- balancing was in a third manual seven seconds later.
    if why ~= "release" then b.manualSpent = true end
    if why == "loop" then
        if ent.QueueCrash then ent:QueueCrash("manual", 0.5) end
        return
    end
    if held >= T.manualMin and ent.AwardTricks then
        local id = kind == "nose" and "board_nosemanual" or "board_manual"
        local t = BMX.Tricks[id]
        local pts = floor(held * t.points * B.StanceMult(b) + 0.5)
        ent:AwardTricks({ { name = B.StancePrefix(b) .. t.name, count = 1, points = pts, held = held } })
    end
end

function B.ManualStep(ent, phys, C, dt, inp, st, b, now)
    local bi = B.InputOf(inp)
    local keys = B.Keys(inp)
    local speed = st.speed or 0
    local grounded = st.grounded

    if not bi.grab then b.manualSpent = nil end
    local free = grounded and not b.crouching and not b.kt and not b.powerslide and not st.grind
    local want = bi.grab and free and not b.manualSpent
    if b.manual then
        b.manualAir = grounded and 0 or ((b.manualAir or 0) + dt)
        want = bi.grab and (b.manualAir or 0) < 0.2 and speed >= 15 and not b.crouching
    else
        want = want and speed >= T.manualMinSpeed
    end

    if want and not b.manual then
        b.manual = bi.alt and "nose" or "manual"
        b.manualT, b.manualAir = 0, 0
        b.mtr = B.MeterStart(math.random() * 6.28, T.meterManual)
        st.manual = { kind = b.manual, held = 0, gone = 0 }
    end
    if not b.manual then return end

    if not want then
        endManual(ent, st, b, "release")
        return
    end

    b.manualT = b.manualT + dt
    st.manual.held, st.manual.gone = b.manualT, 0

    -- S leans the weight back (the nose up, the meter up) and W forward; in a nose
    -- manual it is the other way round, the tail being the end in the air.
    local push = (keys.s and 1 or 0) - (keys.w and 1 or 0)
    if b.manual == "nose" then push = -push end
    local v = B.MeterStep(b.mtr, dt, push, T.meterManual)
    b.meter = BMX.Clamp(v, -1.2, 1.2)
    if v >= 1 then endManual(ent, st, b, "loop") return end
    if v <= -1 then endManual(ent, st, b, "drop") return end

    -- The pitch hold: nose up for a manual, down for a nose manual, a little more
    -- of it as the meter climbs (the lifted end rising toward the loop-out).
    local sign = b.manual == "manual" and 1 or -1
    b.pitchTarget = sign * T.manualPitch * (1 + 0.3 * BMX.Clamp(v, -1, 1))
    b.pitchFF = pitchFeedForward(ent, phys, st, b, b.manual)
end
