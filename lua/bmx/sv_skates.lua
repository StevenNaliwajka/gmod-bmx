--[[--------------------------------------------------------------------------
    bmx/sv_skates.lua

    INLINE SKATES, SERVER SIDE (G25): the `skates` worn mode. The vocabulary, the pure
    step and the registration are sh_skates.lua; the platform's worn side (equipping,
    the hooks, the scoring stand-in) is sv_worn.lua. This file is what is specific to
    skating on the real engine:

        the SWEP's two doors      Equip / Unequip, called by weapon_bmx_skates
        the decoder               the player's own usercmd -> w.input
        the setup                 the player's velocity -> S.Step -> the player's velocity
        the wheels                eight rays cast from the feet: the slope under them and
                                  which are down (the legs are the suspension, so these are
                                  not springs)
        the air and the landing   spins, air time, and a bad landing is a bail
        the grinds                soul, mizou, backslide: sv_grind.lua's finder, and the
                                  skater PLACED on the rail every tick, as a bike is

    HOW A PLAYER IS MADE TO SKATE WITHOUT TAKING THEIR MOVEMENT AWAY. The engine's own
    walking does the collisions, the steps and the stairs; what it cannot do is glide.
    So each tick, before it moves the player (SetupMove), their velocity is taken, run
    through S.Step (which is a skater's physics: the stride, the carve, the brake) and
    written back; their walk keys are zeroed so the engine adds no walking of its own,
    their friction is zero (Entity:SetFriction) so it takes none away, and JUMP is ours (it
    would otherwise be the engine's, at the engine's height). What the engine then does to
    that velocity is collide with the world, which is exactly right. The one thing it can
    do wrong is to leave a velocity that is slower than ours for a reason that is NOT a
    wall (some friction the zero did not reach); so the velocity we last wrote is kept
    (w.expect), and the engine's is taken in its place only when it came back clearly
    slower, which a wall or a stair does and friction at zero does not.

    NOBODY HAS SKATED THIS ON A SERVER. Every number is in BMX.Skates.Tune and every
    assumption about the engine is above; the closed-loop suite runs S.Step on a plant of
    its own and the setup on a scripted player.
----------------------------------------------------------------------------]]

BMX = BMX or {}
local S = BMX.Skates
local T = S.Tune
local W = BMX.Worn
local B = BMX.Board

local abs, min, max, sqrt, floor, cos, sin = math.abs, math.min, math.max, math.sqrt, math.floor, math.cos, math.sin
local UP = Vector(0, 0, 1)

-- The wearer's state if the player is wearing THESE skates.
function S.Wearing(ply)
    local w = W.Of(ply)
    return w and w.id == S.ID and w or nil
end

-- The SWEP's doors. A refusal (the server switched them off) is said once, in chat.
function S.Equip(ply)
    local w, why = W.Equip(ply, S.ID)
    if not w and why and IsValid(ply) and not ply.BMXWorn then
        ply:ChatPrint("[BMX] " .. tostring(why))
    end
    return w
end

function S.Unequip(ply)
    return W.Unequip(ply)
end

--------------------------------------------------------------------------
-- THE DECODER: the keys are read by S.Decode (sh_skates.lua: the client predicts with the
-- same one); the server's part is to take the keys away from the engine, which would
-- otherwise walk and jump with them.
--------------------------------------------------------------------------
local function decode(ply, w, cmd)
    S.Decode(ply, w, cmd)
    cmd:SetButtons(bit.band(cmd:GetButtons(), bit.bnot(IN_JUMP)))
    cmd:SetForwardMove(0)
    cmd:SetSideMove(0)
    cmd:SetUpMove(0)
end

--------------------------------------------------------------------------
-- THE NETWORK. A few NW values on the player, for cl_skates.lua (the boots, the legs and the
-- sparks): the stride phase (-1 not striding, else 0..1 through a stride), whose foot, the
-- flags, the grind move.
--------------------------------------------------------------------------
local function sync(ply, w)
    local sk, st = w.sk, w.st
    local phase = -1
    if sk.ps.kicking then phase = (sk.ps.phase or 0) / (w.def.drive.strideInterval or T.strideInterval) end
    if abs(ply:GetNWFloat("BMXSkatePhase", -1) - phase) > 0.01 then ply:SetNWFloat("BMXSkatePhase", phase) end
    local foot = sk.foot
    if ply:GetNWInt("BMXSkateFoot", 1) ~= foot then ply:SetNWInt("BMXSkateFoot", foot) end
    local flags = (st.grounded and S.Flag.ground or 0) + (sk.braking and S.Flag.brake or 0)
        + (st.grind and S.Flag.grind or 0) + (w.input.crouch and S.Flag.crouch or 0)
    if ply:GetNWInt("BMXSkateFlags", 0) ~= flags then ply:SetNWInt("BMXSkateFlags", flags) end
    local gid = st.grind and (st.grind.moveIndex or 1) or 0
    if ply:GetNWInt("BMXSkateGrind", 0) ~= gid then ply:SetNWInt("BMXSkateGrind", gid) end
    local meter = st.grind and w.meter or 0
    if abs(ply:GetNWFloat("BMXSkateMeter", 0) - meter) > 0.02 then ply:SetNWFloat("BMXSkateMeter", meter) end
end

--------------------------------------------------------------------------
-- THE BAIL: the combo is lost, whatever the air would have paid is not paid, and the
-- skater comes off the way a rider does (RagMod, a ragdoll tumble, or a shove). The
-- tumble strips and gives back the weapons, which holsters the skates and equips them
-- again on the way up (weapon_bmx_skates.lua).
--------------------------------------------------------------------------
function S.Bail(ply, w, reason, severity, vel)
    severity = BMX.Clamp(severity or 0.5, 0, 1)
    if BMX.ComboEnd then BMX.ComboEnd(w.proxy, false) end
    hook.Run("BMX_WornBailed", ply, w.id, reason, severity)
    local CR = BMX.ConfigFor(w.def).Crash
    local throw = (vel or ply:GetVelocity()) + Vector(0, 0, CR.ejectLift * severity)
    local dmg = math.floor(severity * throw:Length() * CR.damageScale)
    local function hurt()
        if not IsValid(ply) or dmg <= 1 then return end
        local d = DamageInfo()
        d:SetDamage(dmg)
        d:SetDamageType(DMG_FALL)
        d:SetAttacker(ply)
        d:SetInflictor(ply)
        ply:TakeDamageInfo(d)
    end
    timer.Simple(0, function()
        if not IsValid(ply) then return end
        if hook.Run("BMX_RiderCrashed", ply, throw, ply) == true
            or (BMX.Compat and BMX.Compat.Ragdoll and BMX.Compat.Ragdoll(ply, throw)) then
            hurt()
            return
        end
        if GetConVar("bmx_crash_ragdoll"):GetBool() and BMX.Tumble and BMX.Tumble(ply, throw, hurt) then return end
        ply:SetVelocity(throw)
        hurt()
    end)
end

--------------------------------------------------------------------------
-- THE GRINDS. The moves, as TryGrind asks for them: (ply, st, rail, dh, vel) -> a move or
-- nil. A skater grinds along a rail or across it, and every angle in between is a
-- fall onto it, which is no grind (nil).
--------------------------------------------------------------------------
function S.GrindMoves(ply, st, rail, dh, vel)
    local w = ply.BMXWorn
    if not w then return nil end
    local h = w.sk.heading
    local fh = Vector(cos(h), sin(h), 0)
    local angle = math.acos(BMX.Clamp(abs(fh:Dot(dh)), 0, 1))
    local along = S.IsAlong(angle)
    local across = abs(angle - math.pi / 2) <= T.alongAngle
    if not (along or across) then return nil end

    local edge = rail.kind == "peg"
    local id = S.ClassifyGrind({ w = w.input.w, s = w.input.s, a = w.input.a, d = w.input.d }, along)
    local g = S.Grinds[id]

    -- Turned off the rail the way the skater already is; one going against the rail's
    -- direction is turned round half a turn so the same shoulder leads.
    local L = (dh.x * fh.y - dh.y * fh.x) >= 0 and 1 or -1
    local reverse = along and fh:Dot(dh) < 0
    local yaw
    if not along then yaw = L * g.yaw
    elseif reverse then yaw = math.pi
    else yaw = 0 end
    for i, gid in ipairs(S.GrindOrder) do if gid == id then st.moveIndex = i end end

    return {
        id = id, name = g.name, mult = g.mult, yaw = yaw, pitch = 0, signed = false, reverse = false,
        crank = S.GrindContact(id, false),
        peg = function(sgn) return S.GrindContact(id, true, sgn) end,
    }
end

local function gravityZ()
    local g = physenv.GetGravity()
    return g and g:Length() or 600
end

-- Try to lock on, once a tick while the skater is in the air with SPACE held (or on
-- contact with bmx_board_autogrind): sv_grind.lua's own checks, in the same order, for a
-- skater. Returns true when it did.
local function tryGrind(ply, w, mv, vel)
    local st, cfg, i = w.st, BMX.ConfigFor(w.def), w.input
    local G = cfg.Grind
    if not G or not G.enabled then return false end
    if not (i.jump or w.auto) then return false end
    if CurTime() < (st.grindReady or 0) then return false end
    if st.grounded and (st.groundedFor or 0) > G.landedWindow then return false end
    if vel.z > G.maxEntryVz then return false end
    local vh = Vector(vel.x, vel.y, 0)
    if vh:Length() < G.minSpeed then return false end

    local gp = BMX.GrindPointsFor(w.def, cfg)
    local origin = mv:GetOrigin()
    local c, s = cos(w.sk.heading), sin(w.sk.heading)
    local point = origin + Vector(gp.crank.x * c - gp.crank.y * s, gp.crank.x * s + gp.crank.y * c, gp.crank.z)
    if not BMX.MightBeRail(point, cfg, ply) then return false end
    local rail = BMX.FindRail(point, vel, cfg, ply, origin + Vector(0, 0, 36))
    if not rail then return false end

    local along = vel:Dot(rail.dir)
    if along < G.minSpeed then return false end
    local dh = Vector(rail.dir.x, rail.dir.y, 0):GetNormalized()

    local mvv = gp.moves(ply, st, rail, dh, vel)
    if not mvv then return false end

    local g = { kind = rail.kind, point = rail.point, dir = rail.dir, n = rail.n, side = rail.side,
                speed = along, started = CurTime(), name = mvv.name, mult = mvv.mult, move = mvv.id,
                moveIndex = st.moveIndex, yaw = mvv.yaw, pitch = mvv.pitch }
    if rail.kind == "crank" then
        g.localPoint = mvv.crank
    else
        local left = UP:Cross(dh)
        local sgn = left:Dot(rail.side) > 0 and 1 or -1
        g.localPoint = mvv.peg(sgn)
        g.point = g.point + rail.side * G.pegInset
    end

    -- Whatever the air had earned is paid on the way in, as a bike's is.
    local sk = w.sk
    if w.airT and w.airT > 0 then
        local tricks = S.ScoreAir(sk, w.airT)
        if #tricks > 0 then w.proxy:AwardTricks(tricks) end
    end
    sk.spin, w.airT = 0, 0

    st.airSince, st.grind, st.grounded = 0, g, true
    g.bal = B.MeterStart(math.random() * 6.28, B.Tune.meterGrind)
    w.meter = 0
    g.jumpWas = i.jump
    hook.Run("BMX_WornGrind", ply, w.id, g.move)
    return true
end

-- Off the rail. `why` is "hop", "end", "slow", "balance" or "rider". A hop is a jump off it.
local function endGrind(ply, w, mv, why)
    local st, cfg = w.st, BMX.ConfigFor(w.def)
    local g = st.grind
    if not g then return end
    local G = cfg.Grind
    st.grind = nil
    local vel = g.dir * max(g.speed, 0)
    if why == "hop" then
        vel = vel + UP * G.hopSpeed
        if g.side then vel = vel - g.side * G.hopAway end
    end
    mv:SetVelocity(vel)
    w.expect = { x = vel.x, y = vel.y }
    w.sk.vx, w.sk.vy = vel.x, vel.y
    st.grindReady = CurTime() + G.cooldown
    st.grounded, st.groundedFor, st.airSince, st.airMode = false, 0, 0, false
    w.meter = nil
    local t = CurTime() - g.started
    if t >= G.minTime and why ~= "balance" then
        w.proxy:AwardTricks({ { name = g.name, count = 1, points = floor(t * G.pointsPerSec * (g.mult or 1)),
                                grind = t } })
    end
    hook.Run("BMX_WornGrindEnded", ply, w.id, g.move, why, t)
    if why == "balance" then S.Bail(ply, w, "balance", 0.45, vel) end
end

-- One tick on the rail: the meter, the pop, and the skater placed on the rail a step
-- further along (the rail is found again, which is what follows a bend and notices the
-- end). Sets the player's origin and velocity; Mode.Move then takes the movement over.
local function grindStep(ply, w, mv, dt)
    local st, cfg, i = w.st, BMX.ConfigFor(w.def), w.input
    local g, G = st.grind, BMX.ConfigFor(w.def).Grind

    -- A and D hold the meter near zero; past one it throws the skater.
    local side = -(i.turn or 0)
    w.meter = BMX.Clamp(B.MeterStep(g.bal, dt, side, B.Tune.meterGrind), -1.2, 1.2)
    if abs(g.bal.v) >= 1 then return endGrind(ply, w, mv, "balance") end

    -- SPACE let go is the pop.
    if g.jumpWas and not i.jump then return endGrind(ply, w, mv, "hop") end
    g.jumpWas = i.jump

    local brake = i.brake and 1 or 0
    local v = g.speed - gravityZ() * g.dir.z * dt - (G.friction + G.brakeDecel * brake) * dt
    g.speed = v
    if v < G.stopSpeed then return endGrind(ply, w, mv, "slow") end

    local predicted = g.point + g.dir * (v * dt)
    g.tick = (g.tick or 0) + 1
    if g.tick % 3 == 0 then
        local look = g.kind == "peg" and (predicted - g.side * G.pegInset) or predicted
        local rail = BMX.FindRail(look + UP * 0.3, g.dir * v, cfg, ply, mv:GetOrigin() + Vector(0, 0, 36))
        if not rail then return endGrind(ply, w, mv, "end") end
        local p = rail.point
        if g.kind == "peg" then p = p + rail.side * G.pegInset end
        if abs(p.z - predicted.z) > G.maxStepZ then return endGrind(ply, w, mv, "end") end
        local step = p - g.point
        if step:Length() > 0.25 then
            local d = step:GetNormalized()
            if d:Dot(g.dir) > 0.5 then g.dir = (g.dir * 0.75 + d * 0.25):GetNormalized() end
        end
        g.point = p
    else
        g.point = predicted
    end

    local pos, ang = BMX.GrindPose(g, cfg)
    mv:SetOrigin(pos)
    mv:SetVelocity(g.dir * v)
    w.sk.heading = S.Wrap(math.rad(ang.y))
    w.sk.vx, w.sk.vy = g.dir.x * v, g.dir.y * v
    w.expect = { x = g.dir.x * v, y = g.dir.y * v }
    st.speed, st.fwdSpeed = v, v
    st.grindTime = CurTime() - g.started
end

--------------------------------------------------------------------------
-- THE MODE.
--------------------------------------------------------------------------
local Mode = { Decode = decode, Weapon = S.Class }

function Mode.Equip(ply, w)
    local v = ply:GetVelocity()
    w.sk = S.New(math.rad(ply:EyeAngles().y))
    w.sk.vx, w.sk.vy = v.x, v.y
    w.input = { fwd = 0, turn = 0, jump = false, crouch = false, brake = false, brakeMode = "tstop",
                w = false, s = false, a = false, d = false, eyeYaw = nil }
    w.friction = ply.GetFriction and ply:GetFriction() or 1
    ply:SetFriction(0)
    w.airT, w.expect = 0, nil
    w.st.grounded = ply:IsOnGround()
    w.nextPoll = 0
end

function Mode.Unequip(ply, w)
    if IsValid(ply) then
        ply:SetFriction(w.friction or 1)
        for _, k in ipairs({ "BMXSkatePhase" }) do ply:SetNWFloat(k, -1) end
        ply:SetNWFloat("BMXSkateMeter", 0)
        for _, k in ipairs({ "BMXSkateFlags", "BMXSkateGrind" }) do ply:SetNWInt(k, 0) end
    end
end

function Mode.Setup(ply, w, mv, dt)
    local st, sk, i = w.st, w.sk, w.input

    -- ON THE RAIL, the skater is placed (Mode.Move then keeps the engine's hands off).
    if st.grind then
        mv:SetForwardSpeed(0)
        mv:SetSideSpeed(0)
        grindStep(ply, w, mv, dt)
        if st.grind then
            sync(ply, w)
            if BMX.ComboThink then BMX.ComboThink(w.proxy, st) end
            return
        end
    end

    -- WHAT THE PLAYER IS DOING: the velocity (ours, unless the engine's came back clearly
    -- slower), the ground, the slope (S.Observe, shared with the client's prediction).
    local wasGrounded = st.grounded
    local vel, grounded, cast = S.Observe(ply, w, mv, dt)
    st.grounded = grounded
    st.groundedFor = grounded and (st.groundedFor or 0) + dt or 0
    if grounded then
        st.airSince = 0
        st.groundNormal = cast.normal
    else
        st.airSince = (st.airSince or 0) + dt
        w.airT = (w.airT or 0) + dt
    end
    st.airMode = (w.airT or 0) > 0.15

    -- A GRIND, from the air.
    if not grounded and tryGrind(ply, w, mv, vel) then
        grindStep(ply, w, mv, dt)
        if st.grind then
            sync(ply, w)
            return
        end
        vel = mv:GetVelocity()
        sk.vx, sk.vy = vel.x, vel.y
    end

    -- THE LANDING: judged on the velocity it arrived with, scored on the air it had.
    if grounded and not wasGrounded and (w.airT or 0) > 0.15 then
        local lv = Vector(vel.x, vel.y, w.lastVz or 0)
        local reason, severity = S.JudgeLanding(lv, sk.heading)
        local tricks = S.ScoreAir(sk, w.airT)
        if reason then
            if #tricks > 0 then hook.Run("BMX_WornTricksBailed", ply, w.id, tricks) end
            S.Bail(ply, w, reason, severity, lv)
        elseif #tricks > 0 then
            w.proxy:AwardTricks(tricks)
        end
    end
    if grounded then sk.spin, w.airT = 0, 0 end
    w.lastVz = vel.z

    -- THE STEP.
    local res = S.Apply(ply, w, mv, dt, vel, grounded, cast)
    st.speed, st.fwdSpeed = res.speed, res.vx * cos(sk.heading) + res.vy * sin(sk.heading)
    if res.kicked and BMX.SoundsOn() and BMX.Sounds.board_push then
        local snd = BMX.Sounds.board_push
        ply:EmitSound(BMX.SoundFile("board_push"), snd.level, math.random(110, 130), snd.vol * 0.7)
    end
    sync(ply, w)
    if BMX.ComboThink then BMX.ComboThink(w.proxy, st) end
end

-- On a rail the movement is ours alone (the skater was placed by Setup).
function Mode.Move(ply, w, mv, dt)
    if w.st.grind then return true end
end

BMX.WornModes.skates = Mode
S.Mode = Mode

--------------------------------------------------------------------------
-- bmx_give_skates: the skates under your arm without the Weapons tab, through the same
-- doors a spawn goes through (sv_worn.lua, W.Give).
--------------------------------------------------------------------------
concommand.Add("bmx_give_skates", function(ply)
    if IsValid(ply) then W.Give(ply, S.ID) end
end)
