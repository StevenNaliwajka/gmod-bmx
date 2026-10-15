--[[--------------------------------------------------------------------------
    bmx/cl_skates.lua

    INLINE SKATES, CLIENT SIDE (G25): what a skater looks like and the one thing the client
    has to do for the controls.

      * THE CROSSOVER TURN. The server steers a skater by where they LOOK (their heading
        chases the view, rate-limited, sh_skates.lua S.Step), so A and D are made into view
        turns here, in CreateMove, at the same rate the server will allow: a keyboard carve
        and a mouse carve are then the same thing, and the view and the skater agree.
      * THE SKATES THEMSELVES, on every skater's feet, from what the server networks on the
        player (NW values: sv_skates.lua, `sync`): aggressive skates built in code
        (cl_geo_board.lua's "skates": a hard shell, a cuff, liner, laces, buckles and a
        power strap, a soul plate, an H-block frame, four wheels), boxes and spheres until
        the model is built, the wheels turning with the skater's speed.
      * THE LEGS. The stock walk or run animation would have a gliding player running on
        the spot, so a skater is held in a standing pose with the knees bent (the pelvis
        lowered by the board's calibrated nudge, cl_board.lua), the torso leaning into the
        speed, and the striding leg swung back on its stroke. Nobody has watched this on a
        real model: every angle is a number in a table below.
      * THE SPARKS of a grind, off both boots, and the balance meter of one.
      * THE PREDICTION of the local skater's own movement (below): the shared step in the
        engine's SetupMove, its state kept per command for the engine's replays, the rail
        taken over as the server takes it over, on and off at the weapon switch.

    Apart from the prediction, everything here is a function of the networked state.
----------------------------------------------------------------------------]]

BMX = BMX or {}
local S = BMX.Skates
local T = S.Tune
local B = BMX.Board

CreateClientConVar("bmx_skates_brake", "tstop", true, true,
    "BMX skates: tstop (the dragged foot, a hard stop that scuffs the turning) or heel (the rear pad, gentler).")

local abs, min, max, sin, cos = math.abs, math.min, math.max, math.sin, math.cos

local function wearing(ply)
    return IsValid(ply) and ply.GetNWString ~= nil and ply:GetNWString("BMXWorn", "") == S.ID
end
S.ClientWearing = wearing

--------------------------------------------------------------------------
-- PREDICTION. The engine predicts a player's own movement (SetupMove and Move run on the client
-- as well as the server), so a client that predicted walking against a server that skates
-- would be corrected every tick. The part of skating that is only the velocity -- the keys, the
-- wheels' cast, the step -- is shared (sh_skates.lua: S.Decode, S.Observe, S.Apply) and run here
-- on the local player with a state of its own. What scores the skater (the air, the landing, the
-- lock onto a rail) is the server's alone.
--
-- THE REPLAY (G30, tests/test_skates_ping.lua). When the server's answer for a command differs
-- from what the client predicted for it, the engine puts the player back where the server had
-- them and predicts every later command AGAIN. It knows nothing of this file's state (the
-- heading, the stride's clock, whose foot, the last SPACE, the speed last written), so that used
-- to run on from the NEWEST command: a replay strode early, turned twice and started from the
-- client's own speed instead of the server's, which made the next answer differ too, and the
-- client never settled again. Now that state is kept per command (cmd:CommandNumber()): a
-- command predicted again starts from the state this client had going into it, and the first
-- one of a replay takes the server's velocity the engine has just put back.
--
-- ON A RAIL the server places the skater and the engine's movement is skipped (sv_skates.lua,
-- Mode.Move). The client used to leave the movement to the engine there with the keys as they
-- were, so A and D (the balance) walked the skater off the side of the rail, W walked, and
-- gravity and the rail's top were the engine's. Now, while the server says grind, the client
-- does what the server does: no walking, no engine jump, the skater carried along the rail at
-- the rail's speed (S.GrindSpeed), the boots turned the server's way (S.GrindHeading), and the
-- engine's movement skipped. Letting go of SPACE pops off at once, as it does on the server, and
-- a rail that has nothing left under the skates ends; the networked flag, a ping late, is then
-- not obeyed until the server agrees or a second has gone by.
--
-- ON AND OFF. The server puts the skates on in the SWEP's Deploy and takes them off in its
-- Holster, at the command that switched weapons, and a switch made from the weapon selector is
-- predicted: the client switches at that same command. The networked BMXWorn only arrives a ping
-- later, and the client used to wait for it, so it walked for a ping while the server skated
-- (the strides then fell at other times than the server's for as long as W was held) and glided
-- on for a ping after the server had put the skater back on their feet. Now the weapon in hand
-- starts and stops the prediction at the server's command, and BMXWorn confirms it: a pair in
-- hand the server has not confirmed within GRACE (it refused them: bmx_allow_boards 0) is
-- walked on again. Skates worn with no weapon (a script) still go by BMXWorn alone.
--------------------------------------------------------------------------
local predicted        -- the local player's predicted wearer state, or nil
local HISTORY = 132    -- commands of state kept: 2 s at 66 tick, past any replay
local POP_WAIT = 1.0   -- s a predicted pop or end ignores a grind flag the server has not cleared
local GRACE = 1.0      -- s skates in hand are predicted before the server has said they are on

-- The keys a fresh pair starts with, as the server's (sv_skates.lua, Mode.Equip): its first
-- command runs before the server has read any.
local function neutral()
    return { fwd = 0, turn = 0, jump = false, crouch = false, brake = false, brakeMode = "tstop",
             w = false, s = false, a = false, d = false }
end

-- The state that lives between commands, as it was after one.
local OFF = { active = false }
local function keep(p)
    if not p.active and not p.since then return OFF end
    local h = { active = p.active, since = p.since }
    if not p.active then return h end
    local sk, ps = p.sk, p.sk.ps
    h.heading, h.foot, h.jumpWas = sk.heading, sk.foot, sk.jumpWas
    h.phase, h.kicking, h.dv = ps.phase, ps.kicking, ps.dv
    h.expect = p.expect and { x = p.expect.x, y = p.expect.y }
    h.lastOrigin, h.nextPoll, h.brakeMode, h.auto, h.popped = p.lastOrigin, p.nextPoll, p.brakeMode, p.auto, p.popped
    return h
end

local function takeBack(p, h)
    p.active, p.since = h.active, h.since
    if not h.active then return end
    local sk = p.sk or S.New(0)
    p.sk = sk
    sk.heading, sk.foot, sk.jumpWas = h.heading, h.foot, h.jumpWas
    sk.ps = { phase = h.phase, kicking = h.kicking, dv = h.dv }
    p.expect = h.expect and { x = h.expect.x, y = h.expect.y }
    p.lastOrigin, p.nextPoll, p.brakeMode, p.auto, p.popped = h.lastOrigin, h.nextPoll, h.brakeMode, h.auto, h.popped
end

-- Skates on, at this command: what the server's Mode.Equip does, from the angles the player had
-- before this command's (the server equips in the weapon switch, before it reads the view).
local function startSkating(p, ply, mv)
    local old = mv.GetOldAngles and mv:GetOldAngles() or ply:EyeAngles()
    p.active = true
    p.sk = S.New(math.rad(old.y))
    local v = ply:GetVelocity()
    p.sk.vx, p.sk.vy = v.x, v.y
    p.input = neutral()
    p.expect, p.lastOrigin, p.nextPoll, p.popped = nil, nil, 0, nil
    p.friction = ply.GetFriction and ply:GetFriction() or 1
    ply:SetFriction(0)
end

-- Skates off, at this command: the friction back, and none of this command's keys (the server
-- read them for the skates, which took them, before the switch took the skates off).
local function stopSkating(p, ply, mv)
    p.active = false
    if ply.SetFriction then ply:SetFriction(p.friction or 1) end
    if mv then
        mv:SetForwardSpeed(0)
        mv:SetSideSpeed(0)
        mv:SetButtons(bit.band(mv:GetButtons(), bit.bnot(IN_JUMP)))
    end
end

-- On skates for this command? The weapon in hand says so at the server's own command; BMXWorn
-- confirms it a ping later.
local function onSkates(ply, p)
    local nw = wearing(ply)
    local wep = ply.GetActiveWeapon and ply:GetActiveWeapon()
    if IsValid(wep) and wep:GetClass() == S.Class then
        p.since = p.since or CurTime()
        return nw or CurTime() - p.since < GRACE
    end
    p.since = nil
    if ply.HasWeapon and ply:HasWeapon(S.Class) then return false end   -- holstered: BMXWorn is late
    return nw
end

-- Is there anything under the skates? A thin box straight down from the skater's origin, as
-- wide as the server looks for a rail round the soul plates (Grind.reach): on a rail or a
-- ledge the rail is under it; past the rail's end nothing is.
local function railUnder(ply, origin, G)
    local r = G.reach or 6
    local tr = util.TraceHull({ start = origin + Vector(0, 0, 2), endpos = origin - Vector(0, 0, 6),
        mins = Vector(-r, -r, 0), maxs = Vector(r, r, 1), filter = ply, mask = MASK_PLAYERSOLID })
    return tr.Hit and not tr.StartSolid
end

-- ONE COMMAND ON A RAIL the server is placing the skater on. Returns true while the skater is
-- still on it (the move is ours: Move returns true); false when this command pops off or comes
-- off, with the velocity it leaves with written into `mv`, and the ordinary step to follow.
local function onRail(ply, p, mv, n, dt)
    local i, sk = p.input, p.sk
    mv:SetForwardSpeed(0)
    mv:SetSideSpeed(0)
    mv:SetButtons(bit.band(mv:GetButtons(), bit.bnot(IN_JUMP)))
    local vel = mv:GetVelocity()
    local speed = vel:Length()
    local dir = speed > 1e-3 and vel / speed or Vector(0, 0, 0)
    local G = BMX.ConfigFor(p.def).Grind
    local function off(v)
        mv:SetVelocity(v)
        p.expect = { x = v.x, y = v.y }
        sk.vx, sk.vy = v.x, v.y
        p.popped = n
        return false
    end
    -- SPACE let go: the server's pop (sv_skates.lua endGrind "hop"), at the speed it was going,
    -- and off an edge away from its top (BMXSkateSide, zero on a rail).
    if sk.jumpWas and not i.jump then
        sk.jumpWas = false
        local side = ply:GetNWVector("BMXSkateSide", vector_origin)
        return off(vel + Vector(0, 0, G.hopSpeed) - Vector(side.x, side.y, 0) * G.hopAway)
    end
    sk.jumpWas = i.jump
    local g = physenv.GetGravity()
    local v = S.GrindSpeed(speed, dir.z, i.brake and 1 or 0, dt, G, g and g:Length() or 600)
    if v < G.stopSpeed then return off(dir * math.max(v, 0)) end
    local to = mv:GetOrigin() + dir * (v * dt)
    if not railUnder(ply, to, G) then return off(dir * v) end
    mv:SetOrigin(to)
    mv:SetVelocity(dir * v)
    sk.heading = S.GrindHeading(sk.heading, dir.x, dir.y, ply:GetNWInt("BMXSkateGrind", 1))
    sk.vx, sk.vy = dir.x * v, dir.y * v
    p.expect = { x = sk.vx, y = sk.vy }
    return true
end

hook.Add("SetupMove", "BMX.Skates.Predict", function(ply, mv, cmd)
    if ply ~= LocalPlayer() then return end
    local n = cmd and cmd.CommandNumber and cmd:CommandNumber() or 0
    local p = predicted
    if not p then
        -- Nothing to predict and nothing kept: the common case, a player not on skates.
        if not wearing(ply) and not (ply.HasWeapon and ply:HasWeapon(S.Class)) then return end
        p = { id = S.ID, def = BMX.Vehicles[S.ID], st = {}, input = neutral(), hist = {}, newest = 0, prev = 0,
              active = false }
        predicted = p
    end
    p.onRail = false
    if n > 0 then
        -- Predicted AGAIN: from the state going into this command, not the newest one's (and a
        -- command from before any kept was not on skates).
        if n <= p.newest then takeBack(p, p.hist[n - 1] or OFF) end
        -- The first command of a replay: the engine has put the server's velocity back, and
        -- that is what the step starts from, not the speed this client wrote last.
        if n ~= p.prev + 1 then p.expect, p.lastOrigin = nil, nil end
        p.prev = n
        if n > p.newest then p.newest = n end
    end

    local function done()
        if n > 0 then
            p.hist[n] = keep(p)
            p.hist[n - HISTORY] = nil
        end
    end
    local on = onSkates(ply, p)
    if not on then
        if p.active then stopSkating(p, ply, mv) end
        done()
        -- Off them and not even carrying them, in the present (not a replay): let the state go.
        if n >= p.newest and not wearing(ply) and not (ply.HasWeapon and ply:HasWeapon(S.Class)) then
            predicted = nil
        end
        return
    end
    if ply:InVehicle() or ply:GetMoveType() ~= MOVETYPE_WALK or not ply:Alive() then done() return end
    local fresh = not p.active
    if fresh then startSkating(p, ply, mv) end

    -- The server's first command on a pair it has just equipped runs on its neutral keys (the
    -- switch came after it read them); every later one reads the usercmd.
    if not (fresh and p.since == CurTime()) then S.Decode(ply, p, cmd) end
    local dt = FrameTime()
    local grinding = bit.band(ply:GetNWInt("BMXSkateFlags", 0), S.Flag.grind) ~= 0
    if not grinding or (p.popped and (n - p.popped) * engine.TickInterval() > POP_WAIT) then p.popped = nil end
    if grinding and not p.popped then p.onRail = onRail(ply, p, mv, n, dt) end
    if not p.onRail then
        local vel, grounded, cast = S.Observe(ply, p, mv, dt)
        S.Apply(ply, p, mv, dt, vel, grounded, cast)
    end
    done()
end)

-- On a rail the move is ours, as it is the server's (sv_skates.lua, Mode.Move).
hook.Add("Move", "BMX.Skates.Predict", function(ply)
    if ply == LocalPlayer() and predicted and predicted.onRail then return true end
end)

--------------------------------------------------------------------------
-- A AND D TURN THE VIEW, for the skater themselves, at the rate the server will follow.
-- Yaw is positive to the left, so A (left) adds. Not on a rail: there A and D are the balance,
-- the server holds the boots along the rail, and a view they had turned was carved toward the
-- moment the grind ended.
--------------------------------------------------------------------------
hook.Add("CreateMove", "BMX.Skates.Turn", function(cmd)
    local ply = LocalPlayer()
    if not IsValid(ply) or ply:InVehicle() then return end
    -- On skates, and on a rail, by this client's own prediction (on at the weapon switch, popped
    -- off when SPACE was let go); without one (singleplayer, where the client predicts nothing),
    -- by what the server networks.
    if predicted then
        if not predicted.active or predicted.onRail then return end
    elseif not wearing(ply) or bit.band(ply:GetNWInt("BMXSkateFlags", 0), S.Flag.grind) ~= 0 then
        return
    end
    local buttons = cmd:GetButtons()
    local map = BMX.InputMaps.skates
    local turn = 0
    if bit.band(buttons, map.actions.left.key) ~= 0 then turn = turn + 1 end
    if bit.band(buttons, map.actions.right.key) ~= 0 then turn = turn - 1 end
    if turn == 0 then return end
    local v = ply:GetVelocity()
    local speed = math.sqrt(v.x * v.x + v.y * v.y)
    local a = cmd:GetViewAngles()
    a.y = a.y + math.deg(S.TurnRate(speed)) * FrameTime() * turn * 0.8
    cmd:SetViewAngles(a)
end)

-- No footsteps from a skater (the server's hook is sv_worn.lua; the client predicts them too).
hook.Add("PlayerFootstep", "BMX.Skates.Quiet", function(ply)
    if wearing(ply) then return true end
end)

--------------------------------------------------------------------------
-- THE POSE: standing, not running.
--------------------------------------------------------------------------
hook.Add("CalcMainActivity", "BMX.Skates.Pose", function(ply)
    if not wearing(ply) then return end
    local seq = ply:LookupSequence("idle_all_01")
    if not seq or seq < 0 then return end
    return ACT_HL2MP_IDLE, seq
end)

-- The nudges, degrees: how far the knees are bent at rest and at speed, how far the torso
-- leans into the speed, how far the striding thigh swings.
S.Pose = { pelvis = 3.5, pelvisFast = 2.5, spine = 4, spineFast = 10, swing = 32 }

local BONE = { lThigh = "ValveBiped.Bip01_L_Thigh", rThigh = "ValveBiped.Bip01_R_Thigh",
               spine = "ValveBiped.Bip01_Spine1" }

local posed = {}      -- ply -> true while we have bones moved on them

local function release(ply)
    if posed[ply] then
        if BMX.ClearRiderPose then BMX.ClearRiderPose(ply) end
        for _, name in pairs(BONE) do
            local b = ply:LookupBone(name)
            if b then ply:ManipulateBoneAngles(b, Angle(0, 0, 0)) end
        end
        posed[ply] = nil
    end
end

-- The stride's leg: 0 to 1 across a stroke, easing out and back, from the networked phase.
function S.StrideSwing(phase)
    if not phase or phase < 0 then return 0 end
    local f = min(1, phase / (T.strideInterval * 0.95))
    return sin(f * math.pi)
end

--------------------------------------------------------------------------
-- THE SKATES STAND ON THE GROUND. The boots hang under the ankles (BootFrame's
-- sole is a fixed drop below the foot bone, the wheels a fixed drop below that), so
-- where the legs put the ankles is where the wheels are. Bent knees made by lowering
-- the pelvis, and the stride made by swinging a thigh, took the feet down with them:
-- the wheels sank into the floor, by the bend and more at speed. So, with the rider
-- IK on (bmx_rider_ik), each leg is put by the rider's two-bone solve (cl_rider.lua
-- BMX.RiderSolveLimb) with its ankle exactly the skate's height over the ground the
-- player stands on: the pelvis drop then bends the knees, and the striding foot is
-- pushed back and out along the ground, as a skater's is, instead of lifted. Toes
-- along the heading, the sole flat.
--
-- Where the feet go, the player's own space: under the hips a skate's width apart,
-- the striding one `S.StrideFoot` further back and out at the end of its push.
--------------------------------------------------------------------------
S.StrideFoot = { back = 8, out = 3, lift = 0.8 }
local IK_RANGE = 1200
function S.FootTargets(origin, yaw, radius, stride, foot)
    local f = Vector(cos(math.rad(yaw)), sin(math.rad(yaw)), 0)
    local l = Vector(-f.y, f.x, 0)
    -- the ankle over the ground by the boot's drop (BootFrame: 2.6) and the wheel
    local lift = 2.6 + 2 * radius - 0.4
    local out = {}
    for _, side in ipairs({ 1, -1 }) do                  -- 1 the left foot
        local mine = (side > 0) == (foot > 0)
        local s = mine and (stride or 0) or 0
        out[side > 0 and "lFoot" or "rFoot"] = origin - f * (S.StrideFoot.back * s)
            + l * (side * (T.track + S.StrideFoot.out * s)) + Vector(0, 0, lift + S.StrideFoot.lift * s)
    end
    return out
end

function S.LegsOnGround(ply, stride, foot)
    local cv = GetConVar("bmx_rider_ik")
    if not (cv and cv:GetBool() and BMX.RiderSolveLimb and BMX.RiderLimbs) then return false end
    if EyePos():Distance(ply:GetPos()) > IK_RANGE then return true end    -- keeps its last pose
    ply.bmxIK = ply.bmxIK or {}
    local yaw = ply:GetRenderAngles().y
    local radius = BMX.ConfigFor(BMX.Vehicles[S.ID]).Wheel.radius
    local targets = S.FootTargets(ply:GetPos(), yaw, radius, stride, foot)
    local f = Vector(cos(math.rad(yaw)), sin(math.rad(yaw)), 0)
    local up = Vector(0, 0, 1)
    local pole = (f + up * 0.2):GetNormalized()
    local toeDir = BMX.RiderFootDir and BMX.RiderFootDir(f, up, 0) or f
    for _, limb in ipairs(BMX.RiderLimbs) do
        local tgt = limb.leg and targets[limb.target]
        if tgt then
            BMX.RiderSolveLimb(ply, limb, tgt, pole)
            local fb = ply:LookupBone(limb.eff)
            local toe = ply:LookupBone("ValveBiped.Bip01_" .. (limb.side == 1 and "R" or "L") .. "_Toe0")
            if fb and toe then BMX.RiderAimBone(ply, fb, fb, toe, toeDir) end
        end
    end
    return true
end

hook.Add("PrePlayerDraw", "BMX.Skates.Legs", function(ply)
    if not wearing(ply) then release(ply) return end
    local P = S.Pose
    local v = ply:GetVelocity()
    local speed = math.sqrt(v.x * v.x + v.y * v.y)
    local frac = math.Clamp(speed / T.maxSpeed, 0, 1)
    if B and B.LowerPelvis then B.LowerPelvis(ply, P.pelvis + P.pelvisFast * frac) end
    local spine = ply:LookupBone(BONE.spine)
    if spine then ply:ManipulateBoneAngles(spine, Angle(0, P.spine + P.spineFast * frac, 0)) end
    local stride = S.StrideSwing(ply:GetNWFloat("BMXSkatePhase", -1))
    local swing = stride * P.swing
    local foot = ply:GetNWInt("BMXSkateFoot", 1)
    if S.LegsOnGround(ply, stride, foot) then posed[ply] = true return end
    for _, k in ipairs({ "lThigh", "rThigh" }) do
        local b = ply:LookupBone(BONE[k])
        if b then
            local mine = (k == "lThigh") == (foot > 0)
            ply:ManipulateBoneAngles(b, Angle(0, mine and swing or 0, 0))
        end
    end
    posed[ply] = true
end)

hook.Add("EntityRemoved", "BMX.Skates.Legs", function(ent) posed[ent] = nil end)

--------------------------------------------------------------------------
-- THE SKATES ON THE FEET. Where each boot is comes from the foot bone, and which way it points from the
-- skater's own heading; the frame is under the sole and the four wheels are in line under it.
-- Pure in S.BootFrame, so the suite can place them without a renderer.
--------------------------------------------------------------------------
local COL_BOOT  = Color(24, 24, 28)
local COL_FRAME = Color(170, 176, 188)
local COL_WHEEL = Color(236, 222, 120)
local COL_HUB   = Color(60, 60, 66)

-- The frame's parts for a boot whose sole is at `sole`, pointing `yaw` degrees: the shell,
-- the frame, and the wheels (centre and radius), world space.
function S.BootFrame(sole, yaw, radius)
    local f = Vector(cos(math.rad(yaw)), sin(math.rad(yaw)), 0)
    local out = { shell = sole + Vector(0, 0, 2.2), frame = sole - Vector(0, 0, 0.4), wheels = {}, forward = f,
                  ang = Angle(0, yaw, 0) }
    for i = 0, 3 do
        out.wheels[#out.wheels + 1] = sole + f * ((1.5 - i) * T.wheelPitch) - Vector(0, 0, radius - 0.4)
    end
    return out
end

local FEET = { "ValveBiped.Bip01_L_Foot", "ValveBiped.Bip01_R_Foot" }

-- THE MODEL (cl_geo_board.lua's "skates"): one boot built about BootFrame's sole point,
-- its wheels standing where BootFrame stands them. nil until it is built, with
-- bmx_bike_model 0, or without Mesh support: the boxes below stand in.
function S.Model()
    local BM = BMX.BikeMesh
    local def = BMX.Vehicles and BMX.Vehicles[S.ID]
    if not (BM and def and def.look) then return nil end
    local cfg = BMX.ConfigFor(def)
    return BM.Get(1, cfg.Wheel.radius, def.look, {
        wheelbase = cfg.Wheel.wheelbase, extra = { wheelPitch = T.wheelPitch },
    })
end

-- The skates' colour: the registration's palette entry, else the first.
function S.Paint()
    local def = BMX.Vehicles and BMX.Vehicles[S.ID]
    return BMX.PaletteColor and BMX.PaletteColor(def and def.colorIndex or 1) or Color(205, 35, 45)
end

-- Where each group of one boot goes: `sole` (BootFrame's), `yaw` (degrees), `side` 1 a
-- left boot, -1 a right one (the buckles' levers are on the outside), `spin` (radians,
-- the wheels' roll). A list of { group, origin, ex, ey, ez }.
function S.BootPlacements(model, sole, yaw, side, spin)
    local lay = model.layout
    local f = Vector(cos(math.rad(yaw)), sin(math.rad(yaw)), 0)
    local l = Vector(-f.y, f.x, 0)
    local u = Vector(0, 0, 1)
    local function at(m) return sole + f * m.x + l * m.y + u * m.z end
    local out = {
        { "skate", sole, f, l, u },
        { side > 0 and "skateOutL" or "skateOutR", sole, f, l, u },
    }
    local c, sn = cos(spin or 0), sin(spin or 0)
    -- positive spin rolls the top of a wheel forward, as the bike's do
    local ex, ez = f * c - u * sn, u * c + f * sn
    for _, w in ipairs(lay.wheels or {}) do out[#out + 1] = { "wheel", at(w), ex, l, ez } end
    for _, w in ipairs(lay.antiRockers or {}) do out[#out + 1] = { "wheelAR", at(w), ex, l, ez } end
    return out
end

-- Draw a pair (or any number) of skates: `boots` = { { sole = Vector, side = 1 | -1 }, ... },
-- all at `yaw` degrees, their wheels rolled by `speed` (u/s) since the map began.
-- `radius` is the registration's wheel (the primitive boots' size). `lightEnt` caches
-- the lighting (a player; nil for none). The model once it is built, the boxes and
-- spheres until then. Shared with the icon studio (tools/icons/studio_cl.lua).
function S.DrawBoots(lightEnt, boots, yaw, radius, speed, grind)
    local model = S.Model()
    if model then
        local BM = BMX.BikeMesh
        local r = model.layout.wheelR or radius
        local spin = (CurTime() * (speed or 0) / r) % (math.pi * 2)
        local paint = S.Paint()
        BM.BeginLighting(boots[1].sole + Vector(0, 0, 4), lightEnt)
        for _, bt in ipairs(boots) do
            for _, pl in ipairs(S.BootPlacements(model, bt.sole, yaw, bt.side, spin)) do
                BM.DrawGroup(model, pl[1], BM.Matrix(pl[2], pl[3], pl[4], pl[5]), paint, 0)
            end
        end
        BM.EndLighting()
        return true
    end
    local spin = (CurTime() * (speed or 0) / radius) % (math.pi * 2)
    render.SetColorMaterial()
    for _, bt in ipairs(boots) do
        local fr = S.BootFrame(bt.sole, yaw, radius)
        render.DrawBox(fr.shell, fr.ang, Vector(-5.2, -1.6, -1.6), Vector(5.8, 1.6, 2.2), COL_BOOT)
        render.DrawBox(fr.frame, fr.ang, Vector(-6.6, -0.6, -0.3), Vector(6.6, 0.6, 0.3), COL_FRAME)
        for _, c in ipairs(fr.wheels) do
            -- On a rail the wheels hang clear of it, beside the soul plate.
            local at = grind and (c + Vector(0, 0, 0.6)) or c
            render.DrawSphere(at, radius, 8, 6, COL_WHEEL)
            -- A hub bolt, so the spin shows: in the vertical plane of the boot's heading.
            local pin = fr.forward * (cos(spin) * radius * 0.6) + Vector(0, 0, sin(spin) * radius * 0.6)
            render.DrawLine(at, at + pin, COL_HUB, true)
        end
    end
    return false
end

hook.Add("PostPlayerDraw", "BMX.Skates.Draw", function(ply)
    if not wearing(ply) then return end
    local cfg = BMX.ConfigFor(BMX.Vehicles[S.ID])
    local radius = cfg.Wheel.radius
    local yaw = ply:GetRenderAngles().y
    local v = ply:GetVelocity()
    local grind = bit.band(ply:GetNWInt("BMXSkateFlags", 0), S.Flag.grind) ~= 0
    local boots = {}
    for i, name in ipairs(FEET) do
        local b = ply:LookupBone(name)
        local pos = b and ply:GetBonePosition(b)
        if pos then
            -- The foot bone is at the ankle: the sole is a couple of units under it.
            boots[#boots + 1] = { sole = Vector(pos.x, pos.y, pos.z - 2.6), side = i == 1 and 1 or -1 }
        end
    end
    if #boots == 0 then return end
    S.DrawBoots(ply, boots, yaw, radius, math.sqrt(v.x * v.x + v.y * v.y), grind)
end)

--------------------------------------------------------------------------
-- SPARKS, off both boots while grinding, and the balance meter of a grind.
--------------------------------------------------------------------------
local emitters = {}

hook.Add("Think", "BMX.Skates.Sparks", function()
    for _, ply in ipairs(player.GetAll()) do
        -- Not one out of sight (dormant: its grind flag and position are stale).
        if wearing(ply) and not (ply.IsDormant and ply:IsDormant()) and ply:GetNWInt("BMXSkateGrind", 0) > 0 then
            local em = emitters[ply]
            if not em then em = ParticleEmitter(ply:GetPos()) emitters[ply] = em end
            if em then
                local back = -ply:GetVelocity():GetNormalized()
                for _, name in ipairs(FEET) do
                    local b = ply:LookupBone(name)
                    local pos = b and ply:GetBonePosition(b) or ply:GetPos()
                    for _ = 1, 2 do
                        local p = em:Add("effects/spark", pos - Vector(0, 0, 2.6))
                        if p then
                            p:SetVelocity(back * math.Rand(60, 160) + VectorRand() * 40 + Vector(0, 0, math.Rand(20, 80)))
                            p:SetDieTime(math.Rand(0.2, 0.5))
                            p:SetStartAlpha(255)
                            p:SetEndAlpha(0)
                            p:SetStartSize(math.Rand(1, 2))
                            p:SetEndSize(0)
                            p:SetStartLength(math.Rand(3, 6))
                            p:SetEndLength(0)
                            p:SetGravity(Vector(0, 0, -500))
                            p:SetColor(255, math.random(170, 220), 90)
                        end
                    end
                end
            end
        elseif emitters[ply] then
            emitters[ply]:Finish()
            emitters[ply] = nil
        end
    end
    -- A skater who left mid-grind is not in that list any more: their emitter was kept
    -- for the rest of the session.
    for ply, em in pairs(emitters) do
        if not IsValid(ply) then
            em:Finish()
            emitters[ply] = nil
        end
    end
end)

hook.Add("HUDPaint", "BMX.Skates.HUD", function()
    local ply = LocalPlayer()
    if not wearing(ply) or ply:InVehicle() then return end
    if BMX.CinematicActive and BMX.CinematicActive(ply) then return end
    local sw, sh = ScrW(), ScrH()
    if ply:GetNWInt("BMXSkateGrind", 0) > 0 and B and B.MeterLayout then
        local w, h = 240, 10
        local x, y = sw * 0.5 - w / 2, sh * 0.7
        draw.RoundedBox(4, x, y, w, h, Color(0, 0, 0, 150))
        draw.RoundedBox(4, x + w * 0.17, y, w * 0.66, h, Color(60, 120, 60, 120))
        local px, col = B.MeterLayout(ply:GetNWFloat("BMXSkateMeter", 0), w)
        draw.RoundedBox(3, x + px - 3, y - 3, 6, h + 6, col)
        draw.SimpleText("BALANCE  A / D", "BMX.Small", sw * 0.5, y + h + 6, Color(255, 255, 255, 220),
            TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
    end
    local v = ply:GetVelocity()
    local mph = math.sqrt(v.x * v.x + v.y * v.y) / 17.6          -- 1 mph is ~17.6 u/s
    draw.SimpleText(string.format("%d mph", math.Round(mph)), "BMX.Small", sw - 28 - 125, sh - 34 - 96 - 22,
        Color(255, 255, 255, 230), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
end)
