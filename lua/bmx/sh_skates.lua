--[[--------------------------------------------------------------------------
    bmx/sh_skates.lua

    AGGRESSIVE INLINE SKATES (G25): the vocabulary and the registration, the shared
    half. The platform side of "worn" is sv_worn.lua; the skating is sv_skates.lua; the
    drawing is cl_skates.lua.

    THE ONE NEW IDEA: A WORN VEHICLE. Every other vehicle is an entity the rider sits
    in. Skates are not: there is no chassis, no seat and nothing to spawn, and the
    player's own entity is the thing that moves. The platform learns it as one
    registration flag:

        worn = true       no entity class, no spawn row, no seat; the player is the
                          chassis. It is equipped (a SWEP) and holstered, not spawned.

    and the registration is otherwise the platform's: wheels (here EIGHT, four in a
    line under each foot, and they are CAST FROM THE FEET, sv_skates.lua, since a
    skater's wheels are wherever their boots are), a balance mode (`skates`, which is
    this file's pure step), a drive (`stride`), an input map, a pose set, the tricks
    and the grind points.

    WHAT SKATING IS, in one paragraph. Wheels roll along the boot and grip across it.
    So the skater has a HEADING (where the boots point) and a velocity, and the part of
    the velocity across the heading is killed by the wheels' grip while the part along it
    only runs down by rolling resistance: that is a carve, and it is the whole of
    steering. W strides: each foot in turn pushes off, a stroke that adds speed along the
    heading (the board's push cycle, B.PushStep), less and less as the skater speeds up.
    A and D are crossovers: the heading turns, and the velocity goes round with it, and
    the crossing legs pump a little speed back in. S is a T-stop (the back foot dragged
    across, a hard brake that scuffs the turning) or a heel brake (the rear wheel's pad,
    gentler); SPACE jumps.

    THE PHYSICS IS A PURE STEP (S.Step), like the board's push and lean, so the suite can
    run it on a plant of its own and the engine's part is only to feed it the player's
    velocity and apply what it returns (sv_skates.lua).

    EVERYTHING NUMERIC IS IN BMX.Skates.Tune, in one table.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Skates = BMX.Skates or {}
local S = BMX.Skates
local B = BMX.Board

-- The vehicle's id and its weapon's class, and the flags the server networks about the
-- skater (sv_skates.lua writes them, cl_skates.lua reads them), here so both agree.
S.ID, S.Class = "skates", "weapon_bmx_skates"
S.Flag = { ground = 1, brake = 2, grind = 4, crouch = 8 }

local abs, min, max, sqrt, floor, cos, sin, atan2 = math.abs, math.min, math.max, math.sqrt, math.floor, math.cos, math.sin, math.atan2
local PI, TAU = math.pi, math.pi * 2

--------------------------------------------------------------------------
-- THE TUNING. Source units: inches, seconds. A player's walk is ~200 u/s; a good skater
-- is faster than that and slower than a bike.
--------------------------------------------------------------------------
S.Tune = {
    -- The stride: each push adds `stride` u/s from a standstill and less as the skater
    -- speeds up (B.KickDv), to nothing at maxSpeed; it is spread over B.Tune.kickTime so
    -- it reads as a stroke. The legs alternate. Held W strides again every strideInterval.
    stride = 44, strideInterval = 0.42, maxSpeed = 430,

    -- Rolling and air resistance: a constant (bearings) and a quadratic term.
    rollDrag = 8, airDrag = 0.00006,

    -- Steering. The heading turns toward the way the rider looks (or by A / D) at most
    -- turnRate rad/s at a standstill, and ever slower the faster they go: a carve at
    -- speed is wide, and a skater cannot snap round at 400 u/s.
    turnRate = math.rad(170), turnSpeed = 260,
    gripRate = 6.5,                 -- 1/s: the sideways part of the velocity decays this fast
    -- The crossing legs of a turn pump some speed back in: u/s^2 while turning, up to
    -- crossTo of the top speed (past it a crossover pays nothing).
    crossGain = 16, crossTo = 0.8,

    -- Braking. A T-stop is hard and scuffs the turning (the dragged foot is also the
    -- one steering); a heel brake is softer and costs nothing. Both stop dead below
    -- stopSpeed.
    tstopDecel = 340, heelDecel = 200, tstopTurnScale = 0.45, stopSpeed = 14,

    -- The jump.
    jumpSpeed = 235,

    -- The slope: the part of gravity along a slope speeds a skater up on a downhill, as
    -- a bike's tyres do on one. Scaled by slopeGain; 1 is physical.
    slopeGain = 1.0,

    -- Landing (S.JudgeLanding). A fall faster than bailFall, or touching down with the
    -- boots more than bailSide across the way of travel at speed, is a bail.
    bailFall = 720, bailSide = math.rad(62), bailMinSpeed = 140,

    -- Air and spins: how far the heading must have turned in the air for a 180 and for a
    -- 360, what an air pays, and the shortest air that counts.
    spin180 = { math.rad(150), math.rad(230) },
    airPerSec = 100, airMin = 0.45,

    -- The wheels: four per boot in a line (`wheelPitch` apart), the boots `track` apart,
    -- radius from the registration's Wheel. Cast down from `castUp` over the axle for
    -- `castReach` below it.
    wheelPitch = 3.0, track = 4.0, castUp = 2.0, castReach = 5.0,

    -- Grinds. The soul plates ride a rail: the contact is at the boot's sole (`soleZ`
    -- over the player's origin, which stands on the ground). `balance` is the same
    -- meter as a board's grind.
    soleZ = 0.0, edgeY = 2.0, mizouX = 4.5,
    alongAngle = math.rad(45),
}
local T = S.Tune

--------------------------------------------------------------------------
-- THE INPUT MAP. W strides, S brakes, A and D are the crossovers, SPACE jumps (and
-- in the air near a rail locks a grind, a tap off the rail pops out), CTRL crouches,
-- RMB is the manual-style hold and ALT the style modifier (reserved for the tricks
-- still to come: grabs and flips). Read from the player's own usercmd (sv_skates.lua):
-- there is no vehicle to hold the keys.
--------------------------------------------------------------------------
local G, A, GR = "ground", "air", "grind"
BMX.RegisterInputMap{
    id = "skates", label = "Inline skates",
    actions = {
        forward = { key = IN_FORWARD,   ctx = { G, A, GR }, label = "Stride (alternate legs) / mizou" },
        back    = { key = IN_BACK,      ctx = { G, A, GR }, label = "T-stop or heel brake" },
        left    = { key = IN_MOVELEFT,  ctx = { G, A, GR }, label = "Crossover left (balance on a grind)" },
        right   = { key = IN_MOVERIGHT, ctx = { G, A, GR }, label = "Crossover right (balance on a grind)" },
        jump    = { key = IN_JUMP,      ctx = { G, A, GR }, label = "Jump; hold in the air near a rail to grind, tap to pop off" },
        crouch  = { key = IN_DUCK,      ctx = { G, A },     label = "Crouch" },
        alt     = { key = IN_WALK,      ctx = { G, A },     label = "Style modifier (reserved)" },
    },
}

BMX.RegisterPoseSet("skates", { label = "Skates: standing, knees bent, boots on the ground" })

--------------------------------------------------------------------------
-- THE WHEELS: eight, four in a line under each boot, as the platform's `wheels` (a
-- function of the config). `pos` is the AXLE in the player's own space, x forward, y
-- left, the origin on the ground the player stands on; the wheels' radius is the
-- config's. None steers or drives: the heading and the stride are the step's.
--------------------------------------------------------------------------
function S.Wheels(cfg)
    local r = (cfg or BMX.Config).Wheel.radius
    local out = {}
    for _, y in ipairs({ T.track, -T.track }) do
        for i = 0, 3 do
            local x = (1.5 - i) * T.wheelPitch
            out[#out + 1] = { pos = Vector(x, y, r), steer = false, drive = false,
                              name = (y > 0 and "l" or "r") .. (i + 1) }
        end
    end
    return out
end

--------------------------------------------------------------------------
-- WHERE THE WHEELS ARE ON THE GROUND (a pure function of the player's origin and
-- heading, so the casts are a loop and the suite can place them): the eight points,
-- world space, that a ray is cast down from.
--------------------------------------------------------------------------
function S.WheelPoints(origin, heading, cfg)
    local c, s = cos(heading), sin(heading)
    local out = {}
    for _, w in ipairs(S.Wheels(cfg)) do
        local x, y = w.pos.x, w.pos.y
        out[#out + 1] = Vector(origin.x + x * c - y * s, origin.y + x * s + y * c, origin.z + w.pos.z + T.castUp)
    end
    return out
end

--------------------------------------------------------------------------
-- THE STEP. One tick of a skater's velocity. Pure: nothing in it knows about the
-- engine, so the suite runs it on a plant of its own.
--
--   s     the skater: { heading = rad, vx, vy = horizontal velocity,
--                       ps = the stride (B.PushStep's), foot = +1 / -1 (whose turn),
--                       braking, jumpWas }, made by S.New
--   inp   { fwd = -1..1, turn = -1..1 (A is +1: yaw turns left), eyeYaw = rad or nil,
--           brake = bool, brakeMode = "tstop" | "heel", jump = bool, crouch = bool }
--   env   { grounded = bool, normal = {x, y, z} or nil (the ground's, from the wheels),
--           gravity = 600 }
--
-- It updates `s` in place and returns { vx, vy, vz = a jump's vertical speed, or nil,
-- kicked = a stroke began this tick, speed }. When `inp.eyeYaw` is given the heading
-- CHASES it, turn-rate-limited (the rider turns by looking, as in any first person
-- game; cl_skates.lua turns the view with A and D, so a keyboard carve is the same
-- thing); without one (a bot, a test) A and D turn the heading themselves.
--------------------------------------------------------------------------
function S.New(heading)
    return { heading = heading or 0, vx = 0, vy = 0, ps = {}, foot = 1, braking = false,
             jumpWas = false, spin = 0, airT = 0 }
end

local function wrap(a) return (a + PI) % TAU - PI end
S.Wrap = wrap

-- The fastest the heading may turn at a given speed.
function S.TurnRate(speed)
    return T.turnRate / (1 + (speed or 0) / T.turnSpeed)
end

-- The drive table the stride cycle reads, from a vehicle's `drive = { kind = "stride" }`.
function S.DriveOf(def)
    local d = def and def.drive or {}
    return { torque = d.torque or T.stride, maxSpeed = d.maxSpeed or T.maxSpeed,
             kickInterval = d.strideInterval or T.strideInterval }
end

function S.Step(s, dt, inp, env, def)
    local drive = S.DriveOf(def)
    local speed = sqrt(s.vx * s.vx + s.vy * s.vy)
    local res = { kicked = false }

    -- THE HEADING.
    s.braking = inp.brake and env.grounded and inp.brakeMode ~= "heel" or false
    local rate = S.TurnRate(speed) * (s.braking and T.tstopTurnScale or 1)
    local dh
    if inp.eyeYaw ~= nil then
        dh = BMX.Clamp(wrap(inp.eyeYaw - s.heading), -rate * dt, rate * dt)
    else
        dh = (inp.turn or 0) * rate * dt
    end
    -- In the air nothing grips: the heading is the body's alone (a spin), and it is
    -- counted for the 180s and 360s.
    s.heading = wrap(s.heading + dh)
    if not env.grounded then s.spin = (s.spin or 0) + dh end

    local h = { x = cos(s.heading), y = sin(s.heading) }
    local vx, vy = s.vx, s.vy

    if env.grounded then
        -- A CARVE: the velocity goes round with the heading (the wheels point where the
        -- boots do)...
        if dh ~= 0 then
            local c, sn = cos(dh), sin(dh)
            vx, vy = vx * c - vy * sn, vx * sn + vy * c
        end
        -- ...and what is left across the boots is gripped away.
        local along = vx * h.x + vy * h.y
        local side = -vx * h.y + vy * h.x
        side = side * math.exp(-T.gripRate * dt)

        -- THE STRIDE. W, with nothing else asking for the legs.
        local want = (inp.fwd or 0) > 0.3 and not s.braking and not inp.crouch
        local add, began = B.PushStep(s.ps, dt, want, max(along, 0), drive)
        if began then s.foot = -s.foot; res.kicked = true end
        along = along + add

        -- CROSSOVERS pump the speed back in while the heading is turning.
        local turning = inp.eyeYaw ~= nil and abs(dh) / max(dt, 1e-6) / max(rate, 1e-6) or abs(inp.turn or 0)
        if turning > 0.05 and along > 0 and along < T.crossTo * drive.maxSpeed then
            along = along + T.crossGain * min(turning, 1) * dt
        end

        -- BRAKING: the T-stop and the heel brake (a skater who is not braking stops nothing).
        -- Dead stop under stopSpeed.
        if inp.brake then
            local decel = (inp.brakeMode == "heel") and T.heelDecel or T.tstopDecel
            local mag = sqrt(along * along + side * side)
            if mag <= T.stopSpeed then
                along, side = 0, 0
            else
                local d = min(mag, decel * dt)
                along, side = along * (1 - d / mag), side * (1 - d / mag)
            end
        end

        -- ROLLING RESISTANCE and the air's.
        local sp = sqrt(along * along + side * side)
        if sp > 0 then
            local drag = min(sp, T.rollDrag * dt + T.airDrag * sp * sp * dt)
            along, side = along * (1 - drag / sp), side * (1 - drag / sp)
        end

        vx = along * h.x - side * h.y
        vy = along * h.y + side * h.x

        -- THE SLOPE: the part of gravity along the surface the wheels are on.
        local n = env.normal
        if n and n.z < 0.999 and n.z > 0.2 then
            local g = (env.gravity or 600) * T.slopeGain
            vx = vx + g * n.z * n.x * dt
            vy = vy + g * n.z * n.y * dt
        end

        -- THE JUMP: a fresh press of SPACE on the ground.
        if inp.jump and not s.jumpWas then res.vz = T.jumpSpeed end
    end
    s.jumpWas = inp.jump and true or false

    s.vx, s.vy = vx, vy
    res.vx, res.vy = vx, vy
    res.speed = sqrt(vx * vx + vy * vy)
    return res
end

--------------------------------------------------------------------------
-- THE TICK, IN BOTH REALMS. The server is the authority on a skater, but a player's own
-- movement is PREDICTED by their client (the engine runs SetupMove and Move on both ends),
-- and a client that predicted ordinary walking against a server that skates would be
-- corrected by it every tick. So the part of a skater that is only the velocity -- reading
-- the keys, the wheels' cast, the step -- is here, and the client runs it as well
-- (cl_skates.lua). What stays on the server is everything that scores or places the
-- player: the landing, the air, the grinds. `w` is the wearer's state: { def, st, input,
-- sk, expect }, which the client keeps its own copy of.
--------------------------------------------------------------------------

-- Eight rays down from over each axle (the registration's wheels, placed by the boots'
-- heading): the slope under the skater is the mean of the normals they hit, and how many were
-- down is their footing. Returns { n = how many hit, normal = Vector (up if none),
-- hits = { Vector|false x 8 } }.
function S.Cast(ply, origin, heading, def)
    local cfg = BMX.ConfigFor(def or BMX.Vehicles[S.ID])
    local pts = S.WheelPoints(origin, heading, cfg)
    local reach = cfg.Wheel.radius + T.castUp + T.castReach
    local sum, n, hits = Vector(0, 0, 0), 0, {}
    for i, p in ipairs(pts) do
        local tr = util.TraceLine({ start = p, endpos = p - Vector(0, 0, 1) * reach, filter = ply, mask = MASK_SOLID })
        if tr.Hit and not tr.StartSolid and tr.HitNormal.z > 0.3 then
            n = n + 1
            sum = sum + tr.HitNormal
            hits[i] = tr.HitPos
        else
            hits[i] = false
        end
    end
    local normal = n > 0 and sum:GetNormalized() or Vector(0, 0, 1)
    return { n = n, normal = normal, hits = hits }
end

-- A client convar of the player's own: the local copy on the client (a player's userinfo is
-- only readable for others through the server), the player's userinfo on the server.
local function info(ply, name, default)
    if CLIENT then
        local cv = GetConVar(name)
        return cv and cv:GetFloat() or default
    end
    return ply:GetInfoNum(name, default)
end

local function infoString(ply, name)
    if CLIENT then
        local cv = GetConVar(name)
        return cv and cv:GetString() or ""
    end
    return ply:GetInfo(name) or ""
end

local function axis(value, cvName, fallback)
    local cv = GetConVar(cvName)
    local scale = cv and cv:GetFloat() or fallback
    if scale <= 0 then scale = fallback end
    return BMX.Clamp(value / scale, -1, 1)
end

-- THE KEYS: the player's usercmd, through the registration's input map, into w.input. Only what
-- the map names is read.
function S.Decode(ply, w, cmd)
    local map = BMX.InputMaps.skates
    local buttons = cmd:GetButtons()
    local function down(a) local x = map.actions[a] return x ~= nil and bit.band(buttons, x.key) ~= 0 end
    local i = w.input

    local dz = BMX.Clamp(info(ply, "bmx_stick_deadzone", 0.1), 0, 0.9)
    local fwd = BMX.StickDeadzone and BMX.StickDeadzone(axis(cmd:GetForwardMove(), "sv_forwardspeed", 400), dz) or 0
    if fwd == 0 then
        if down("forward") then fwd = 1 elseif down("back") then fwd = -1 end
    end
    i.w, i.s, i.a, i.d = down("forward"), down("back"), down("left"), down("right")
    i.fwd = fwd
    i.turn = (i.a and 1 or 0) - (i.d and 1 or 0)       -- A is left, which is a positive yaw
    i.eyeYaw = math.rad(cmd:GetViewAngles().y)
    i.jump, i.crouch = down("jump"), down("crouch")
    i.brake = fwd < -0.3 or i.s
    if CurTime() >= (w.nextPoll or 0) then
        w.nextPoll = CurTime() + 0.5
        w.brakeMode = string.lower(infoString(ply, "bmx_skates_brake")) == "heel" and "heel" or "tstop"
        w.auto = info(ply, "bmx_board_autogrind", 0) > 0
    end
    i.brakeMode = w.brakeMode
end

-- WHAT THE PLAYER IS DOING THIS TICK, before the step: the engine's walk keys and jump are
-- not wanted (the usercmd's were zeroed by the server's decoder; a predicted client's are
-- not), the velocity is the one we last wrote unless the engine's came back clearly slower (a
-- wall, a stair: sv_skates.lua says why), and the ground is from the engine and the slope from
-- the wheels. Returns the velocity (a Vector), whether the skater is on the ground, and the
-- cast.
function S.Observe(ply, w, mv, dt)
    local sk = w.sk
    local origin = mv:GetOrigin()
    local vel = mv:GetVelocity()

    mv:SetForwardSpeed(0)
    mv:SetSideSpeed(0)
    mv:SetButtons(bit.band(mv:GetButtons(), bit.bnot(IN_JUMP)))

    if w.expect then
        local es = sqrt(vel.x * vel.x + vel.y * vel.y)
        local xs = sqrt(w.expect.x * w.expect.x + w.expect.y * w.expect.y)
        if xs >= 30 and es >= xs * 0.88 then
            vel = Vector(w.expect.x, w.expect.y, vel.z)
        end
    end
    sk.vx, sk.vy = vel.x, vel.y

    local cast = S.Cast(ply, origin, sk.heading, w.def)
    w.cast = cast
    -- THE GROUND. The engine's flag is from its last move, at the last origin. A
    -- skater moved since by something other than their own motion (a teleport: a
    -- respawn, a rental, a script's SetPos) can be in the air with the flag still
    -- saying ground, and SPACE then jumped from mid-air -- straight up past a rail
    -- the skater was put over, instead of locking onto it. After such a jump the
    -- wheels' own cast says.
    local grounded = ply:IsOnGround()
    local last = w.lastOrigin
    if grounded and last then
        local moved = (origin - last):Length()
        if moved > 32 + vel:Length() * (dt or 0) * 2 then grounded = cast.n > 0 end
    end
    w.lastOrigin = origin
    return vel, grounded, cast
end

-- THE STEP, and writing what it says into the player's velocity. Returns S.Step's result.
function S.Apply(ply, w, mv, dt, vel, grounded, cast)
    local sk = w.sk
    local g = physenv.GetGravity()
    local res = S.Step(sk, dt, w.input, { grounded = grounded, normal = cast.normal,
        gravity = g and g:Length() or 600 }, w.def)
    mv:SetVelocity(Vector(res.vx, res.vy, res.vz or vel.z))
    w.expect = { x = res.vx, y = res.vy }
    return res
end

--------------------------------------------------------------------------
-- THE AIR, scored on landing (pure over the state the step keeps): how long it was up
-- and how far the boots turned. A half turn is a 180 (the board's), a whole one a 360 and
-- each further whole turn another. Returns a list of { name, count, points }.
--------------------------------------------------------------------------
function S.ScoreAir(s, airT)
    local out = {}
    airT = airT or s.airT or 0
    local spin = abs(s.spin or 0)
    if spin >= T.spin180[1] and spin <= T.spin180[2] then
        local t = BMX.Tricks.board180
        out[#out + 1] = { name = t.name, count = 1, points = t.points }
    else
        local turns = floor(spin / TAU + 0.5)
        if turns >= 1 then
            local t = BMX.Tricks.spin360
            out[#out + 1] = { name = t.name, count = turns, points = turns * t.points }
        end
    end
    if airT >= T.airMin then
        out[#out + 1] = { name = "Air Time", count = 1, points = floor(airT * T.airPerSec) }
    end
    return out
end

-- Was that a landing or an accident? `v` is the velocity at touchdown {x, y, z}, `heading`
-- the boots' yaw. Returns reason, severity or nil. A boot facing straight back is just
-- skating backwards (fakie): it is the ACROSS that bails.
function S.JudgeLanding(v, heading)
    local fall = -(v.z or 0)
    if fall > T.bailFall then
        return "fall", BMX.Clamp((fall - T.bailFall) / T.bailFall + 0.4, 0, 1)
    end
    local sp = sqrt(v.x * v.x + v.y * v.y)
    if sp >= T.bailMinSpeed then
        local a = abs(wrap(atan2(v.y, v.x) - heading))
        a = min(a, PI - a)                   -- fakie is the same as forward, to a wheel
        if a > T.bailSide then
            return "sideways", BMX.Clamp(0.3 + (a - T.bailSide) / (PI / 2 - T.bailSide) * 0.5, 0, 1)
        end
    end
    return nil
end

--------------------------------------------------------------------------
-- THE GRINDS. The soul plates, between the wheels, on the rail. WHICH grind is the
-- way the skater is turned to it and the key held as they locked on:
--
--        along the rail              across it
--   none   soul                      backslide
--   W      mizou
--
-- A SOUL is both boots' soul plates on the rail, side by side in line; a MIZOU the
-- front boot's soul with the back boot behind it; a BACKSLIDE is turned across the
-- rail, the rail between the boots. (Makio, topside, royale, unity and frontside are
-- the next to add: docs/goals/G25-inline-skates.md.) `x` is where on the boots the rail
-- is, `yaw` how far the skater is turned off the rail's line, `mult` the points
-- multiplier on the grind's rate.
--------------------------------------------------------------------------
S.Grinds = {
    skate_soul      = { name = "Soul Grind", along = true,  x = 0,          yaw = 0,       mult = 1.0,
                        input = "hold SPACE in the air near a rail, along it" },
    skate_mizou     = { name = "Mizou Grind", along = true, x = T.mizouX,   yaw = 0,       mult = 1.4,
                        input = "W as you lock onto a rail, along it" },
    skate_backslide = { name = "Backslide",  along = false, x = 0,          yaw = PI / 2,  mult = 1.6,
                        input = "hold SPACE in the air near a rail, turned across it" },
}
S.GrindOrder = { "skate_soul", "skate_mizou", "skate_backslide" }

function S.ClassifyGrind(k, along)
    if not along then return "skate_backslide" end
    if k.w and not k.s then return "skate_mizou" end
    return "skate_soul"
end

function S.IsAlong(angle)
    local a = abs(angle) % PI
    if a > PI / 2 then a = PI - a end
    return a <= T.alongAngle
end

-- The point of the skater (own space) that rides the rail. On a ledge the skater stands on
-- the top, a little over the edge toward the top side `sgn`; on a round rail it is under
-- the middle.
function S.GrindContact(id, edge, sgn)
    local g = S.Grinds[id]
    return Vector(g.x, edge and (sgn or 1) * T.edgeY or 0, T.soleZ)
end

for _, id in ipairs(S.GrindOrder) do
    local g = S.Grinds[id]
    BMX.RegisterTrick{ id = id, name = g.name, kind = "grind",
        points = BMX.Config.Grind.pointsPerSec * g.mult, input = g.input }
end

--------------------------------------------------------------------------
-- THE GRIND POINTS, the platform's (`grindPoints`): where a rail is looked for (the soul
-- plates, `crank`), what an edge is ridden on (`pegs`: the boots' track) and the moves.
--------------------------------------------------------------------------
S.GrindPoints = {
    moves = function(...) return S.GrindMoves(...) end,
    crank = Vector(0, 0, 1.0),
    pegs  = function() return { y = T.edgeY, z = T.soleZ, x = { 0 } } end,
}

--------------------------------------------------------------------------
-- THE REGISTRATION: a worn vehicle. No seat, no entity, no spawn row.
--
--   Wheel.radius 1.6    an 80 mm aggressive skate wheel is 1.6 inches across; the wheels
--                       are cast from the feet, so this is the ray's reach and the
--                       drawing's size, not a spring (there is none: the legs are the
--                       suspension, and the player's own hull does the standing)
--   Wheel.wheelbase 9   one boot's frame
--   Grind.hopSpeed      a pop off a rail is a jump
--------------------------------------------------------------------------
BMX.RegisterVehicle({
    id          = "skates",
    look        = "skates",        -- its model (docs/MODELS.md)
    printName   = "Inline skates",
    description = "Aggressive inline skates: stride (W), crossover (A / D), T-stop (S), jump, and soul, mizou and backslide grinds. Equip them from the weapon list; holster to walk.",
    author      = "Burrito",
    family      = "skates",
    worn        = true,
    wheels      = S.Wheels,
    balance     = "skates",
    drive       = { kind = "stride", torque = T.stride, maxSpeed = T.maxSpeed, strideInterval = T.strideInterval },
    input       = "skates",
    pose        = "skates",
    tricks      = { "board180", "spin360", "skate_soul", "skate_mizou", "skate_backslide" },
    grindPoints = S.GrindPoints,
    physics = {
        Wheel = { radius = 1.6, wheelbase = 9, restLength = 2 },
        Grind = { hopSpeed = T.jumpSpeed, minHop = 1.0 },
    },
})
