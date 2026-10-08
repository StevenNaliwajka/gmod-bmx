--[[--------------------------------------------------------------------------
    bmx/sv_board.lua

    THE SKATEBOARD, SERVER SIDE (G23): the `board` balance mode, the `push` drive,
    the usercmd decoder, the ollie, stance, and the bail rules. The vocabulary and
    the pure functions are sh_board.lua; the vehicle is registered in
    sh_boards.lua. The tricks that come on top (flips, grinds, manuals, grabs,
    reverts) are sv_board_tricks.lua and sv_board_grind.lua.

    HOW IT PLUGS IN. The platform (G22) asks the vehicle for three things and this
    file answers them:

        BMX.BalanceModes.board   Ground / Pitch hold the chassis flat to the ground;
                                 Tick runs once a substep with a rider, in the air as
                                 well as on the ground (the lean, the ollie, the bail)
        BMX.Drives.push          a kick every kickInterval while W is down, a foot
                                 dragged for the brake, a kick-turn at a standstill
        BMX.InputMaps.board.decode
                                 sv_input.lua hands the usercmd over: the board's keys
                                 mean different things from a bike's

    A BOARD IS HELD FLAT, NOT BALANCED. A bike falls over unless a controller
    holds it up; four wheels in a rectangle do not. What the `board` mode does is
    keep the chassis square to the ground it is on (a PD on roll and pitch against
    the surface's normal, so a bank or a quarter-pipe face is ridden flat on it) and
    cancel the roll the tyres' own sideways force would give it. The deck's LEAN, the
    thing the rider steers with, is a separate state (st.board.lean) that a spring
    drives toward the key and the trucks turn by (sh_boards.lua). Nothing about the
    physical body leans, so it cannot tip in a corner and a wheel never lifts.

    THE RIDER INPUT is st.input.board (sh_board.lua, B.NewInput): the raw W S A D
    (b.fwd, b.side), SPACE, ALT, RMB, CTRL, LMB. The standard fields (throttle,
    brakeRear, leanTarget) are filled too, so a scripted rider or a bot that only
    knows those still pushes, brakes and carves.
----------------------------------------------------------------------------]]

BMX = BMX or {}
local B = BMX.Board
local T = B.Tune

local abs, min, max, sqrt = math.abs, math.min, math.max, math.sqrt

local function isBoard(ent)
    local def = ent and ent.Bike and ent:Bike()
    return def ~= nil and def.balance == "board"
end
B.IsBoard = isBoard

-- The board's state on the controller state, made on first use.
function BMX.BoardState(st)
    local b = st.board
    if not b then
        b = {
            lean = 0, leanRate = 0,
            ps = {},                    -- the push cycle (B.PushStep)
            crouching = false, crouchT = 0,
            goofy = false, switch = false, fakie = false,
            rollRateS = 0,
            catchT = 0,
            popReady = 0, lastGround = 0,
        }
        st.board = b
    end
    return b
end

--------------------------------------------------------------------------
-- STANCE. The rider's own (the bmx_stance userinfo convar, cl_board.lua) is read
-- twice a second, and turns the seat: a regular rider faces the board's right
-- side, a goofy one the left (Tune.seatYaw). A switch stance is the other one.
--------------------------------------------------------------------------
local function seatStance(ent, b)
    local pod = ent:GetPod()
    if not IsValid(pod) then return end
    local s = B.Stance(b.goofy, b.switch)
    if b.podStance == s then return end
    b.podStance = s
    local yaw = s > 0 and T.seatYaw.regular or T.seatYaw.goofy
    if pod.SetLocalAngles then pod:SetLocalAngles(Angle(0, yaw, 0)) end
end
B.SeatStance = seatStance

local function readStance(ent, ply, b)
    if not IsValid(ply) then return end
    local goofy = string.lower(ply:GetInfo("bmx_stance") or "") == "goofy"
    if goofy ~= b.goofy then b.goofy = goofy end
    seatStance(ent, b)
end

hook.Add("BMX_Mounted", "BMX.Board.Stance", function(ply, bike)
    if not isBoard(bike) or not bike.st then return end
    local b = BMX.BoardState(bike.st)
    b.nextPoll = 0
    b.podStance = nil
    readStance(bike, ply, b)
end)

--------------------------------------------------------------------------
-- THE BALANCE MODE.
--------------------------------------------------------------------------
BMX.BalanceModes = BMX.BalanceModes or {}

local function gravity()
    local g = physenv.GetGravity()
    return g and g:Length() or 600
end

-- Ground: the bookkeeping every mode keeps (st.roll and st.pitch against gravity
-- and the ground, their rates, which the landing judge, the tip rule, the camera
-- and the HUD read) and the roll hold.
local function Ground(ent, phys, cfg, dt, inp, st, wheels, groundNormal, speed)
    local b = BMX.BoardState(st)
    local roll  = select(1, BMX.Attitude(ent, BMX.BalanceUp(ent, cfg, groundNormal)))
    local pitch = select(2, BMX.Attitude(ent, groundNormal))
    st.rollRate  = st.rollRate  + ((roll  - st.lastRoll)  / dt - st.rollRate)  * min(1, 18 * dt)
    st.pitchRate = st.pitchRate + ((pitch - st.lastPitch) / dt - st.pitchRate) * min(1, 18 * dt)
    st.lastRoll, st.lastPitch = roll, pitch
    st.roll, st.pitch = roll, pitch
    st.onStand = false
    st.leanAuthority, st.leanError = 0, 0

    -- THE ROLL HOLD, against the SURFACE and not gravity: a board on a 25-degree
    -- bank lies flat on the bank, and one on a quarter-pipe's face lies flat on
    -- that, which is what the four wheels do on their own. What the hold adds is
    -- the roll the tyres give it. A sideways force at the contact patch, below the
    -- mass centre, rolls the body to the outside; cancelling it (lat * h / I, the
    -- same figure the single-track balance reports as `rightingAccel`) keeps it
    -- level, and since the steering comes from the LEAN state and not from this
    -- roll there is no loop through it: the thing cancelled does not depend on the
    -- thing controlled.
    local rollS = select(1, BMX.Attitude(ent, groundNormal))
    b.rollRateS = b.rollRateS + ((rollS - (b.lastRollS or rollS)) / dt - b.rollRateS) * min(1, 25 * dt)
    b.lastRollS = rollS
    local lat = 0
    for _, w in ipairs(wheels) do
        if w.onGround then lat = lat + (w.latForce or 0) end
    end
    local I = BMX.IRoll(ent)
    local h = cfg.Chassis.massCenterExpected.z + cfg.Wheel.radius
    local alpha = lat * h / I - T.rollKp * rollS - T.rollKd * b.rollRateS
    alpha = BMX.Clamp(alpha, -T.rollMax, T.rollMax)
    BMX.ApplyTorque(phys, ent, ent:GetForward(), BMX.TorqueFor(I, alpha), dt)
end

-- Pitch: held to a target against the surface. Level (0) when nothing is asked of
-- it, which is what rights a board that landed on one end; the manuals set a
-- target (sv_board_grind.lua) and the same hold carries them.
local function Pitch(ent, phys, cfg, dt, inp, st, wheels)
    local b = BMX.BoardState(st)
    local target = b.pitchTarget or 0
    local hard = target ~= 0 or (st.recoverUntil or 0) > CurTime()
    local kp = hard and T.pitchKp or T.levelKp
    local kd = hard and T.pitchKd or T.levelKd
    local alpha = kp * (target - st.pitch) - kd * st.pitchRate + (b.pitchFF or 0)
    alpha = BMX.Clamp(alpha, -T.pitchMax, T.pitchMax)
    BMX.ApplyTorque(phys, ent, ent:GetRight(), BMX.TorqueFor(BMX.IPitch(ent), alpha), dt)
end

BMX.BalanceModes.board = { Ground = Ground, Pitch = Pitch }

--------------------------------------------------------------------------
-- THE PUSH DRIVE. Kicks, a dragged foot, and a kick-turn at a standstill. It
-- applies its forces at the mass centre, where they cannot pitch the board (a
-- rider's foot on the ground pushes the whole of them), and returns no wheel
-- torque: the wheels roll free.
--------------------------------------------------------------------------
local function anyGround(wheels)
    for _, w in ipairs(wheels or {}) do if w.onGround then return true end end
    return false
end

BMX.Drives = BMX.Drives or {}
BMX.Drives.push = function(ent, cfg, dt, inp, st, wheel, vdef)
    local b = BMX.BoardState(st)
    local d = vdef.drive
    local phys = ent:GetPhysicsObject()
    local grounded = anyGround(ent.wheels)
    local vel = phys:GetVelocity()
    local n = st.groundNormal or vector_up
    local fwd = BMX.ProjectPerp(ent:GetForward(), n) or ent:GetForward()
    local along = vel:Dot(fwd)
    local speed = vel:Length()

    -- THE WHEELS' SPEED FOR THE SOUNDS AND THE HUD. A board has no cadence; what
    -- cl_sound reads as one (the freewheel tick plays when it is low) is the wheels'
    -- spin, so a rolling board is never "coasting" in a bike's sense.
    st.cadence = abs(along) / cfg.Wheel.radius

    if not grounded then
        b.ps.phase = d.kickInterval
        return 0
    end

    -- The pushing foot is busy while the rider crouches, holds a manual, slides or
    -- turns on the spot.
    local busy = b.crouching or b.kt or b.manual or b.powerslide or b.revert
    local want = inp.throttle > 0.3 and not busy
    local add, began = B.PushStep(b.ps, dt, want, max(along, 0), d)
    if add > 0 then phys:ApplyForceCenter(fwd * (add * phys:GetMass())) end
    if began and BMX.SoundsOn() then
        local S = BMX.Sounds.board_push
        if S then ent:EmitSound(BMX.SoundFile("board_push"), S.level, math.random(94, 106), S.vol) end
    end

    -- A DRIVE WITHOUT A FOOT BRAKE (`footBrake = false`: the kick scooter, G24). It kicks
    -- the same way, but it brakes with the wheel (S is the rear fender brake, which
    -- the physics step applies to the wheels from inp.brakeRear), and it has no
    -- kick-turn: it is held up by the single-track balance and not by four wheels, so
    -- there is nothing here for a foot to drag or turn on. The board's sync (the push
    -- phase for the rider's foot) does not run on a scooter, so it is sent from here.
    if d.footBrake == false then
        local push = B.PushPhaseOf(b.ps, d.kickInterval or T.kickInterval)
        if ent.SetPushPhase and abs(ent:GetPushPhase() - push) > 0.01 then ent:SetPushPhase(push) end
        return 0
    end

    -- The foot drag: S with the board rolling takes speed off along its travel,
    -- on the ground, the way a shoe on tarmac does. At a walk it is a kick-turn
    -- instead, started by a fresh press so holding S does not spin it for ever.
    local brake = inp.brakeRear > 0.3
    if brake and not busy then
        if speed > T.kickTurnSpeed then
            local vs = vel - n * vel:Dot(n)
            local len = vs:Length()
            if len > 1e-3 then
                local dv = min(len, T.footBrake * inp.brakeRear * dt)
                phys:ApplyForceCenter(vs * (-dv / len * phys:GetMass()))
            end
        elseif not b.brakeWas and not b.kt then
            local bi = B.InputOf(inp)
            b.kt = { t = 0, prev = 0, dir = (bi.side > 0.3 or inp.leanTarget > 0.3) and -1 or 1 }
        end
    end
    b.brakeWas = brake
    return 0
end

--------------------------------------------------------------------------
-- THE KICK-TURN: a 180 about the rear wheels at a standstill, eased in and out
-- over kickTurnTime. Kinematic (the physics object is turned about the rear
-- axle), because four tyres on the ground resist a yaw torque with more than a
-- rider's foot can give; a kick-turn lifts the nose, which a raycast chassis does
-- not model. Ends if the board starts rolling or leaves the ground.
--------------------------------------------------------------------------
local function kickTurn(ent, phys, cfg, dt, st, b)
    local kt = b.kt
    if not kt then return end
    local speed = st.speed or 0
    if not st.grounded or speed > T.kickTurnSpeed * 2 then b.kt = nil return end
    kt.t = kt.t + dt
    local f = min(1, kt.t / T.kickTurnTime)
    local e = f * f * (3 - 2 * f)
    local dyaw = kt.dir * math.pi * (e - kt.prev)
    kt.prev = e

    local half = cfg.Wheel.wheelbase * 0.5
    local pivot = ent:LocalToWorld(Vector(-half, 0, 0))
    local pos = phys:GetPos()
    local c, s = math.cos(dyaw), math.sin(dyaw)
    local rel = pos - pivot
    local ang = ent:GetAngles()
    ang.y = ang.y + math.deg(dyaw)
    phys:SetAngles(ang)
    phys:SetPos(pivot + Vector(rel.x * c - rel.y * s, rel.x * s + rel.y * c, rel.z))
    phys:SetVelocity(Vector(0, 0, phys:GetVelocity().z))
    phys:SetAngleVelocity(Vector(0, 0, 0))
    if f >= 1 then b.kt = nil end
end

--------------------------------------------------------------------------
-- THE OLLIE. Hold SPACE to crouch, release to pop; the height is proportional to
-- how long it was held (B.PopHeight). A nollie (ALT held as it is released) pops
-- off the nose: the same height, the nose-kick the other way.
--
-- Keys held when the crouch BEGAN are latched until they are let go, the way
-- sv_input.lua latches a key held into the air: a rider pushing with W who
-- crouches is not asking for a front shove-it (sv_board_tricks.lua reads the
-- latch).
--------------------------------------------------------------------------
local function dirLatch(inp)
    local k = B.Keys(inp)
    return { w = k.w, s = k.s, a = k.a, d = k.d }
end

local function pop(ent, phys, cfg, dt, inp, st, b, now)
    local held = b.crouchT
    local h = B.PopHeight(held)
    local v = B.PopSpeed(h, gravity())
    local n = st.groundNormal or vector_up
    local fwd = ent:GetForward()
    local dir = (n + fwd * T.popForward):GetNormalized()
    phys:ApplyForceCenter(dir * (v * phys:GetMass()))

    local bi = B.InputOf(inp)
    local nollie = bi.alt and true or false
    local kick = T.popNoseKick * (nollie and -1 or 1)
    BMX.ApplyTorque(phys, ent, ent:GetRight(), BMX.TorqueFor(BMX.IPitch(ent), kick / dt), dt)

    b.popAt, b.popHeld, b.popHeight, b.nollie = now, held, h, nollie
    b.popReady = now + T.popCooldown
    b.crouching, b.crouchT = false, 0
    if BMX.SoundsOn() then
        local S = BMX.Sounds.board_pop
        if S then ent:EmitSound(BMX.SoundFile("board_pop"), S.level, math.random(96, 108), S.vol) end
    end
    hook.Run("BMX_BoardPopped", ent, ent:GetDriver(), h, nollie)
    return h
end

local function ollie(ent, phys, cfg, dt, inp, st, b, now)
    local bi = B.InputOf(inp)
    if st.grounded then b.lastGround = now end
    -- G30: the coyote window is measured to when the rider pressed (inp.cmdAge,
    -- 0 unless bmx_lagcomp), not to when it arrived. now - 0 == now.
    local pressed = now - (inp.cmdAge or 0)
    local canPop = (pressed - b.lastGround) <= T.coyote and now >= b.popReady

    -- The latched press (the decoder's jumpTap) counts as held for one step.
    local jump, tapKeys = bi.jump or bi.jumpTap, (not bi.jump) and bi.jumpTapKeys or nil
    bi.jumpTap, bi.jumpTapKeys = nil, nil
    if jump then
        if not b.crouching and canPop and not st.grind and not b.kt then
            b.crouching, b.crouchT = true, 0
            b.latch = tapKeys and { w = tapKeys.w, s = tapKeys.s, a = tapKeys.a, d = tapKeys.d }
                or dirLatch(inp)
        end
        if b.crouching then b.crouchT = min(T.crouchMax, b.crouchT + dt) end
    elseif b.crouching then
        if canPop then
            pop(ent, phys, cfg, dt, inp, st, b, now)
        else
            b.crouching, b.crouchT = false, 0
        end
    end
    -- Off the ground with SPACE down and no way to pop: not a crouch any more.
    if b.crouching and (pressed - b.lastGround) > T.coyote then b.crouching, b.crouchT = false, 0 end
end

--------------------------------------------------------------------------
-- THE BAIL ON AN EDGE: a wheel that meets a rise it cannot roll onto (the wheel
-- code flags it, `stepBlocked`, for a rise of Wheel.stepMax in one substep) at
-- speed throws the rider. A bump at a walk is not a catch.
--------------------------------------------------------------------------
local function edgeCatch(ent, dt, st, b, wheels)
    local hit = false
    if st.grounded and (st.speed or 0) >= T.catchSpeed and not st.grind then
        for _, w in ipairs(wheels) do
            if w.stepBlocked then hit = true break end
        end
    end
    if hit then
        b.catchT = b.catchT + dt
        if b.catchT >= T.catchTime and ent.QueueCrash then
            b.catchT = 0
            ent:QueueCrash("edge", BMX.Clamp((st.speed or 0) / 450, 0.3, 1))
        end
    else
        b.catchT = max(0, b.catchT - dt * 2)
    end
end

--------------------------------------------------------------------------
-- THE NETWORK. A few floats and two ints (shared.lua): the lean, the push phase,
-- the crouch, the meter, the deck's flip bytes and the flags. Written only when
-- they change by enough to draw.
--------------------------------------------------------------------------
local function sync(ent, st, b, now)
    local function setf(set, get, v, eps)
        if abs(get(ent) - v) > eps then set(ent, v) end
    end
    setf(ent.SetBoardLean, ent.GetBoardLean, b.lean, 0.004)
    setf(ent.SetCrouch, ent.GetCrouch, b.crouching and (b.crouchT / T.crouchMax) or 0, 0.02)
    local push = B.PushPhaseOf(b.ps, (ent:Bike().drive or {}).kickInterval or T.kickInterval)
    setf(ent.SetPushPhase, ent.GetPushPhase, push, 0.01)
    setf(ent.SetMeter, ent.GetMeter, b.meter or 0, 0.01)
    local bits = B.PackBits(b.flipRoll or 0, b.flipYaw or 0, b.flipPitch or 0)
    if bits ~= ent:GetBoardBits() then ent:SetBoardBits(bits) end
    local flags = B.PackFlags({
        goofy = b.goofy, switch = b.switch, fakie = b.fakie, meter = b.meter ~= nil,
        manual = b.manual == "manual", nose = b.manual == "nose",
        slide = b.slide, powerslide = b.powerslide, nollie = b.nollie and (now - (b.popAt or -9) < 1),
        grind = st.grind ~= nil,
    })
    if flags ~= ent:GetBoardFlags() then ent:SetBoardFlags(flags) end
end

B.Sync = sync

-- What the stance multiplies a trick by: switch pays most, fakie a little.
function B.StanceMult(b)
    return b.switch and T.switchMult or (b.fakie and T.fakieMult or 1)
end

-- The stance's words for a trick's name ("Switch " / "Fakie " / ""), so every trick
-- that pays says how it was done.
function B.StancePrefix(b)
    return b.switch and "Switch " or (b.fakie and "Fakie " or "")
end

--------------------------------------------------------------------------
-- ON THE TRANSITION: DROPPING IN. Rolled off the top of a quarter pipe, the
-- board's nose tips over the coping and the face then falls away faster than a
-- body flung off it falls: left to VPhysics it flew out level, came down on the
-- transition's foot nose-first and went over (a 75 degree drop-in: "crash
-- impact", or upside down, on a real server). A skater keeps the trucks on the
-- face. So with no wheel down and the board coming down over a surface it could
-- ride (Tune.stick*), the speed it has is turned along that surface, kept whole,
-- and the deck is turned onto it. The concave transition below then holds the
-- wheels on by itself (the push it needs is v^2 / R plus gravity's share).
--
-- Not on the way up (a launch off a lip or a kicker is an air), not in the
-- first stickAfterPop of an ollie, not on a wall (stickMaxAngle), not on a rail,
-- in a manual or a kick-turn; and nothing at all with any wheel on the ground,
-- where the wheels do it.
--------------------------------------------------------------------------
local function transition(ent, phys, C, dt, st, b, now)
    if st.grind or b.manual or b.kt or b.revert then return end
    if b.popAt and now - b.popAt < T.stickAfterPop then return end
    local wheels = ent.wheels
    if not wheels or #wheels == 0 then return end
    -- Which trucks are down. Both: the wheels have it. One (the front come down
    -- onto the transition, the back still over it): the other is swung down
    -- onto the surface about the one that is down.
    local fDown, rDown = false, false
    for _, w in ipairs(wheels) do
        if w.onGround then if w.isFront then fDown = true else rDown = true end end
    end
    if fDown and rDown then return end
    local partial = fDown or rDown
    local vel = phys:GetVelocity()
    if vel.z > 0 then return end
    local speed = vel:Length()
    if speed < T.stickMinSpeed then return end

    -- Under EVERY wheel, along the deck's down, the same surface: a board still
    -- across the coping (the back wheels over the deck, the front over the face)
    -- is pivoting over it, which VPhysics does, and is left to.
    local up = ent:GetUp()
    local WC = C.Wheel
    local len = WC.restLength + WC.radius + T.stickReach
    local sum, gap, normals = Vector(0, 0, 0), math.huge, {}
    local front, rear, nf, nr = Vector(0, 0, 0), Vector(0, 0, 0), 0, 0
    for i, w in ipairs(wheels) do
        local m = ent:LocalToWorld(w.mount)
        local tr = util.TraceLine({ start = m, endpos = m - up * len,
            filter = ent.traceFilter or ent, mask = MASK_SOLID })
        if not tr.Hit or tr.StartSolid or tr.HitNormal.z < math.cos(T.stickMaxAngle) then return end
        normals[i] = tr.HitNormal
        sum = sum + tr.HitNormal
        if w.isFront then front, nf = front + tr.HitPos, nf + 1 else rear, nr = rear + tr.HitPos, nr + 1 end
        if not w.onGround then gap = math.min(gap, tr.Fraction * len - (WC.restLength + WC.radius)) end
    end
    if nf == 0 or nr == 0 or gap < T.stickMinGap then return end
    local n = sum:GetNormalized()
    for _, hn in ipairs(normals) do
        if hn:Dot(n) < math.cos(T.stickSpread) then return end
    end
    front, rear = front / nf, rear / nr

    -- THE ATTITUDE TO TAKE: along the CHORD between the points under the front
    -- and back trucks, not square to the averaged normal. On a transition's
    -- curve the two differ by the bend over a wheelbase, and square to the
    -- average the back trucks met the steeper face above first and kicked the
    -- nose down into it (a real server: thrown back up onto the deck).
    local chord = front - rear
    local cl = chord:Length()
    if cl < 1 then return end
    chord = chord / cl
    local target = n - chord * n:Dot(chord)
    if target:LengthSqr() < 1e-6 then return end
    target:Normalize()

    -- Its speed along the surface: what was carrying it off is turned onto it,
    -- the whole of it kept, and the gap to the surface closed at stickClose...
    -- (With a truck down, its speed is the wheels', untouched.)
    local v = vel
    local vn = v:Dot(n)
    local close = -math.min(gap * T.stickClose, T.stickCloseMax)
    if not partial and vn > close then
        local vt = v - n * vn
        local lt = vt:Length()
        local keep = math.sqrt(math.max(speed * speed - close * close, 0))
        if lt > 1 then v = vt * (keep / lt) + n * close end
    elseif not partial and vn < -T.stickApproach then
        -- ...and it does not slam into it either: past stickApproach toward the
        -- surface is soaked, as a landing's is.
        v = v - n * (vn + T.stickApproach)
    end

    -- The deck onto the surface: up turned toward the target, the yaw kept.
    -- About the mass centre: turned about the point under the wheels, the mass
    -- centre's share of the turn was speed made from nothing (116 u/s over the
    -- coping became 174) and lost again as the turn ended.
    local f, l = ent:GetForward(), -ent:GetRight()
    local av = phys:GetAngleVelocity()                          -- body axes, deg/s
    local axis = up:Cross(target)
    local sinA = axis:Length()
    local rate = 0
    if sinA > 1e-4 then
        local ang = math.asin(math.min(sinA, 1))
        if up:Dot(target) < 0 then ang = math.pi - ang end
        rate = math.min(ang * T.stickGain, T.stickRate)
        axis = axis / sinA
    end
    local omega = axis * rate
    -- ADDED, not set: a SetVelocity here, in the motion controller, pinned the
    -- board where it was for good (a real server: it hung on the coping with
    -- its velocity counting up and its position never changing).
    phys:AddVelocity(v - vel)
    phys:AddAngleVelocity(Vector(math.deg(omega:Dot(f)) - av.x, math.deg(omega:Dot(l)) - av.y, 0))
    b.onTransition = now
end

--------------------------------------------------------------------------
-- THE TICK: once a substep with a rider aboard (sv_physics.lua, 6b), on the ground
-- and in the air alike.
--------------------------------------------------------------------------
function BMX.BoardTick(ent, phys, C, dt, inp, st, vdef)
    local b = BMX.BoardState(st)
    local now = CurTime()
    local ply = ent:GetDriver()

    if now >= (b.nextPoll or 0) then
        b.nextPoll = now + 0.5
        readStance(ent, ply, b)
        b.autogrind = IsValid(ply) and ply:GetInfoNum("bmx_board_autogrind", 0) > 0 or false
        b.flickOn   = IsValid(ply) and ply:GetInfoNum("bmx_board_flick", 0) > 0 or false
    end

    -- The lean: the key's lean (already smoothed, st.input) is the target, the
    -- spring follows it. In the air there is nothing to lean on.
    local target = (st.airMode and 0 or BMX.Clamp(inp.lean or 0, -1, 1)) * T.maxLean
    b.lean, b.leanRate = B.LeanStep(b.lean, b.leanRate, target, dt)

    b.fakie = B.IsFakie(st.fwdSpeed or 0, b.fakie)

    ollie(ent, phys, C, dt, inp, st, b, now)
    transition(ent, phys, C, dt, st, b, now)
    kickTurn(ent, phys, C, dt, st, b)
    edgeCatch(ent, dt, st, b, ent.wheels)

    if BMX.BoardTricks then BMX.BoardTricks(ent, phys, C, dt, inp, st, b, now) end
    sync(ent, st, b, now)
end

-- The mode's Tick, called by the physics step.
BMX.BalanceModes.board.Tick = BMX.BoardTick
BMX.BalanceModes.board.Idle = function(ent, st) return BMX.BoardIdle(ent, st) end

-- Nobody aboard: the lean springs back and the flags clear, so a parked board is
-- drawn flat.
function BMX.BoardIdle(ent, st)
    local b = st.board
    if not b then return end
    b.crouching, b.crouchT, b.kt, b.manual, b.meter = false, 0, nil, nil, nil
    b.pitchTarget, b.pitchFF, b.mtr, st.manual = 0, 0, nil, nil
    b.revert, b.powerslide, b.slideT = nil, nil, nil
    b.lean, b.leanRate = 0, 0
    b.flipRoll, b.flipYaw, b.flipPitch, b.flip, b.latch, b.popAt = 0, 0, 0, nil, nil, nil
    b.ps = {}
    sync(ent, st, b, CurTime())
end

--------------------------------------------------------------------------
-- THE USERCMD DECODER, called by sv_input.lua for a vehicle whose input map has
-- one. Writes the board's keys onto the input table; everything after is the
-- simulation's. `down(action)` asks the map which key an action is on.
--------------------------------------------------------------------------
local function decode(ply, bike, cmd, down, fwd, side)
    local inp = bike.input
    local st = bike.st or {}
    local b = B.InputOf(inp)
    local air = st.airMode and true or false

    b.fwd, b.side = fwd, side
    b.w, b.s = down("forward"), down("back")
    b.jump, b.alt = down("jump"), down("alt")
    -- A TAP SHORTER THAN A TICK. The decoder runs per usercmd and the simulation
    -- per tick, and a client batches usercmds: a quick SPACE tap could be down in
    -- one usercmd and up in the next, both inside one tick, and the simulation
    -- never saw it (no crouch, no pop). The press is latched until a step has
    -- read it (ollie(), below), so the shortest tap is a one-tick crouch: a
    -- popMin ollie. The direction keys down at that press are kept with it: they
    -- are what the crouch's latch holds (a key pressed as SPACE came back up is a
    -- flip, not one held into the crouch).
    if b.jump and not b.jumpTap then b.jumpTap, b.jumpTapKeys = true, B.Keys(inp) end
    b.grab, b.duck, b.swap = down("grab"), down("crouch"), down("swap")

    -- THE FLICK SCHEME (bmx_board_flick, a userinfo convar, cl_board.lua): the
    -- mouse's recent movement is a direction, as in Skate, for the flip tricks
    -- only. A quick stroke past a threshold sets it, and it fades.
    if ply:GetInfoNum("bmx_board_flick", 0) > 0 then
        local now = CurTime()
        local dt = now - (b.flickT or now)
        b.flickT = now
        local decay = math.exp(-dt / 0.18)
        b.mx = (b.mx or 0) * decay + cmd:GetMouseX()
        b.my = (b.my or 0) * decay + cmd:GetMouseY()
        local thr = 90
        local f = abs(b.my) > thr and (b.my < 0 and 1 or -1) or 0
        local s = abs(b.mx) > thr and (b.mx > 0 and 1 or -1) or 0
        b.flickF, b.flickS = f, s
    else
        b.flickF, b.flickS = 0, 0
    end

    inp.brakeFront, inp.sprint, inp.tuck = 0, false, false
    inp.whip, inp.bar, inp.pitchTarget = 0, 0, 0
    inp.hop = b.jump
    inp.throttle  = (not air and fwd > 0) and fwd or 0
    inp.brakeRear = (not air and fwd < 0) and -fwd or 0

    -- In the air A and D are flip flicks, not a roll, and CTRL with them is a body
    -- spin, which sv_air.lua already does on `wheelieMod` (RMB + A/D on a bike).
    local spin = air and b.duck and side ~= 0 and not b.grab
    inp.wheelieMod = spin
    inp.leanTarget = air and (spin and side or 0) or side

    -- A grab is RMB in the air with a direction, a pose of G17's.
    inp.pose = (air and b.grab) and B.GrabFor(B.Keys(inp)) or nil

    -- A hop off a rail is the bike's (sv_grind.lua reads these); the board's own
    -- grind step reads b.jump, so they stay clear.
    bike.hopHeld, bike.hopRelease = false, false

    -- Like the bike's decoder: the engine's own use of these keys is not wanted.
    local buttons = cmd:GetButtons()
    cmd:SetButtons(bit.band(buttons, bit.bnot(bit.bor(IN_JUMP, IN_DUCK))))
    cmd:SetForwardMove(0)
    cmd:SetSideMove(0)
    cmd:SetUpMove(0)
end

BMX.InputMaps.board.decode = decode
