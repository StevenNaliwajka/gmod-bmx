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

    Nothing here is simulated: it is all a function of the networked state.
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
-- on the local player with a state of its own. Everything that scores or places the
-- skater (the air, the landing, the grinds) is the server's alone: while it says the skater is
-- on a rail the client does not predict, and the server's placing stands.
--
-- BEST EFFORT, NOT EXACT: the client's stride timing and heading are its own copy, kept from the
-- tick it saw the skates go on, and the engine replays commands from the last tick the
-- server acknowledged without winding that copy back. The velocity is what is corrected, so a
-- drift is a small correction and not a fight, but nobody has played it with a real ping.
--------------------------------------------------------------------------
local predicted        -- the local player's predicted wearer state, or nil

local function stopPredicting(ply)
    if predicted then
        if IsValid(ply) and ply.SetFriction then ply:SetFriction(predicted.friction or 1) end
        predicted = nil
    end
end

hook.Add("SetupMove", "BMX.Skates.Predict", function(ply, mv, cmd)
    if ply ~= LocalPlayer() then return end
    if not wearing(ply) then stopPredicting(ply) return end
    if ply:InVehicle() or ply:GetMoveType() ~= MOVETYPE_WALK or not ply:Alive() then return end

    if not predicted then
        local def = BMX.Vehicles[S.ID]
        predicted = { id = S.ID, def = def, st = {}, input = {},
                      sk = S.New(math.rad(ply:EyeAngles().y)), friction = ply.GetFriction and ply:GetFriction() or 1 }
        local v = ply:GetVelocity()
        predicted.sk.vx, predicted.sk.vy = v.x, v.y
        ply:SetFriction(0)
    end
    -- On a rail it is the server's placing; leave the engine's movement alone.
    if bit.band(ply:GetNWInt("BMXSkateFlags", 0), S.Flag.grind) ~= 0 then return end

    S.Decode(ply, predicted, cmd)
    local dt = FrameTime()
    local vel, grounded, cast = S.Observe(ply, predicted, mv, dt)
    S.Apply(ply, predicted, mv, dt, vel, grounded, cast)
end)

--------------------------------------------------------------------------
-- A AND D TURN THE VIEW, for the skater themselves, at the rate the server will follow.
-- Yaw is positive to the left, so A (left) adds.
--------------------------------------------------------------------------
hook.Add("CreateMove", "BMX.Skates.Turn", function(cmd)
    local ply = LocalPlayer()
    if not wearing(ply) or ply:InVehicle() then return end
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

hook.Add("PrePlayerDraw", "BMX.Skates.Legs", function(ply)
    if not wearing(ply) then release(ply) return end
    local P = S.Pose
    local v = ply:GetVelocity()
    local speed = math.sqrt(v.x * v.x + v.y * v.y)
    local frac = math.Clamp(speed / T.maxSpeed, 0, 1)
    if B and B.LowerPelvis then B.LowerPelvis(ply, P.pelvis + P.pelvisFast * frac) end
    local spine = ply:LookupBone(BONE.spine)
    if spine then ply:ManipulateBoneAngles(spine, Angle(0, P.spine + P.spineFast * frac, 0)) end
    local swing = S.StrideSwing(ply:GetNWFloat("BMXSkatePhase", -1)) * P.swing
    local foot = ply:GetNWInt("BMXSkateFoot", 1)
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
        if wearing(ply) and ply:GetNWInt("BMXSkateGrind", 0) > 0 then
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
