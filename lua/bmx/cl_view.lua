--[[--------------------------------------------------------------------------
    bmx/cl_view.lua

    The chase camera.

    Three things do most of the work here, and none of them are the camera's
    position:

      * PULLBACK WITH SPEED. The camera drifts back as you accelerate. This is
        the oldest trick in the racing-game book and it is still the strongest
        single cue for speed.
      * FOV WITH SPEED. Same idea from the other direction.
      * VIEW ROLL. A fraction of the bike's actual lean is applied to the view.
        Not all of it: full roll is nauseating and hides the horizon, which is
        the reference a rider judges lean against. A third reads as commitment.

    The camera is an ORBIT driven by the player's eye angles rather than
    something that auto-chases the bike's heading. Auto-chase needs to steal the
    mouse to work, and a camera that fights the player's hand is worse than one
    that simply does what the hand says.
----------------------------------------------------------------------------]]

BMX = BMX or {}

local cv_dist  = CreateClientConVar("bmx_cam_dist",  "115", true, false,
    "Chase camera distance at a standstill.")
local cv_height = CreateClientConVar("bmx_cam_height", "26", true, false,
    "Chase camera height above the bike's origin.")
local cv_roll  = CreateClientConVar("bmx_cam_roll",  "0.34", true, false,
    "Fraction of the bike's lean applied to the view. 0 disables.")
local cv_fp    = CreateClientConVar("bmx_cam_first", "0", true, false,
    "1 for a first-person view from the bars.")
local cv_smooth = CreateClientConVar("bmx_cam_smooth", "1", true, false,
    "1: the chase camera eases after the bike's turns and ramps. 0: it is bolted to the bike.")

local cv_air = CreateClientConVar("bmx_cam_air", "0.6", true, false,
    "Trick camera: how far the chase camera pulls back and widens in the air. 0 disables.")

--------------------------------------------------------------------------
-- THE TRICK CAMERA (G21). In the air the chase camera pulls back and widens
-- its field of view a little, then eases back on landing: it is what makes a
-- Skate or THPS air read, because the whole trick fits in frame.
--
-- CONTINUOUS BY CONSTRUCTION. Nothing here is a switch on "grounded": that
-- flag flickers on a lip or a bump and a camera that jumped with it would
-- shake. Instead an AIRBORNE TIMER decides what the camera WANTS (a short
-- hang time first, so a bump is not an air), and a PHASE moves toward that at
-- a fixed rate, through a smoothstep. The phase can only change by rate*dt a
-- frame, and the smoothstep has zero slope at both ends, so neither the
-- distance nor the field of view has a step at takeoff or landing, at any
-- frame time. tests/test_stance.lua steps it frame by frame and checks.
--------------------------------------------------------------------------
BMX.AirCam = { hang = 0.12, secondsIn = 0.35, secondsOut = 0.6,
               dist = 0.40, fov = 14 }

-- `st` is { t = seconds airborne, phase = 0..1 }; call once a frame.
-- Returns the eased 0..1 blend.
function BMX.AirCamStep(st, grounded, dt)
    local A = BMX.AirCam
    st.t = grounded and 0 or ((st.t or 0) + dt)
    local want = (not grounded and st.t >= A.hang) and 1 or 0
    local ph = st.phase or 0
    local step = dt / (want == 1 and A.secondsIn or A.secondsOut)
    if ph < want then ph = math.min(want, ph + step)
    elseif ph > want then ph = math.max(want, ph - step) end
    st.phase = ph
    return ph * ph * (3 - 2 * ph)
end

-- What the blend adds: a multiplier for the camera distance and degrees of FOV.
-- `amount` is the player's bmx_cam_air (0 = off).
function BMX.AirCamExtras(blend, amount)
    local A = BMX.AirCam
    amount = math.max(0, amount or 0)
    return 1 + A.dist * amount * blend, A.fov * amount * blend
end
local airState = { t = 0, phase = 0 }

-- Smoothed state, so the camera does not snap when speed or geometry changes.
--
-- SEEDED ON MOUNT, not left at zero. The smoothers ease toward their targets,
-- so starting them at 0 meant the first view after getting on a bike had a
-- field of view of a few degrees and a camera inside the rider, zooming out
-- over most of a second. `sBike` is the bike the state belongs to: a different
-- bike (or the first one) starts from its targets rather than easing in.
local sDist, sFov, sRoll = 0, 0, 0
local sBike = nil

-- THE CAMERA'S HEIGHT RIDES ON ITS OWN SPRING. A landing stops the bike in
-- a tick or two, and a camera bolted to it stops just as hard: the jolt is
-- felt through the view more than anywhere. So the view's height follows the
-- bike through a critically damped spring (no overshoot, no bounce) with a
-- short time constant, and a capped lag so it can never lose the bike. A
-- landing then reads as the view dipping and settling, a cushioned one.
local sZ, sZv = nil, 0
local CAM_OMEGA = 16        -- rad/s: about a 60 ms settle
local CAM_MAXLAG = 12       -- units

local function followHeight(target, dt)
    if not sZ then sZ, sZv = target, 0 return target end
    local a = CAM_OMEGA * CAM_OMEGA * (target - sZ) - 2 * CAM_OMEGA * sZv
    sZv = sZv + a * dt
    sZ = sZ + sZv * dt
    if sZ > target + CAM_MAXLAG then sZ, sZv = target + CAM_MAXLAG, 0 end
    if sZ < target - CAM_MAXLAG then sZ, sZv = target - CAM_MAXLAG, 0 end
    return sZ
end
BMX.CameraFollowHeight = followHeight

-- THE CAMERA'S HEADING AND TILT RIDE ON SPRINGS TOO. The view angles the
-- engine hands CalcView are the rider's mouse look COMPOSED WITH THE SEAT, and
-- the seat is bolted to the bike: every degree the bike yaws or pitches went
-- straight into the view, the same frame. A hard turn swung the whole screen
-- at the bike's 120 deg/s, the foot of a ramp tipped it 30 degrees in a few
-- frames, and a rider (2026-10-07, on the cruiser) called it sharp and
-- jolting. So the look is taken out of the seat's frame and put back into a
-- LEVEL frame whose heading follows the seat through a critically damped
-- spring (~0.4 s, never more than CAM_MAXYAWLAG behind), and only CAM_TILT of
-- the bike's pitch, smoothed, is added back so a ramp still reads as a ramp.
-- The mouse is untouched: it moves the view on the frame it moves.
local CAM_TURN = 9            -- rad/s, the heading spring: ~0.4 s to settle
local CAM_MAXYAWLAG = 60      -- degrees the heading may trail the bike
local CAM_TILT = 0.35         -- of the bike's pitch shown
local CAM_TILTRATE = 5        -- 1/s
local sYaw, sYawV, sTilt = nil, 0, 0

local function followYaw(target, dt)
    if not sYaw then sYaw, sYawV = target, 0 return target end
    local d = math.AngleDifference(target, sYaw)
    local a = CAM_TURN * CAM_TURN * d - 2 * CAM_TURN * sYawV
    sYawV = sYawV + a * dt
    sYaw = math.NormalizeAngle(sYaw + sYawV * dt)
    local lag = math.AngleDifference(target, sYaw)
    if lag > CAM_MAXYAWLAG then sYaw = math.NormalizeAngle(target - CAM_MAXYAWLAG) end
    if lag < -CAM_MAXYAWLAG then sYaw = math.NormalizeAngle(target + CAM_MAXYAWLAG) end
    return sYaw
end

-- `angles`, re-expressed: the same look relative to the seat, but in a level
-- frame at the smoothed heading, tilted by the smoothed share of bike pitch.
local function easedAngles(bike, angles, dt)
    local pod = bike.GetPod and bike:GetPod()
    if not IsValid(pod) then return angles end
    local pa = pod:GetAngles()
    local pf, pl, pu = pa:Forward(), -pa:Right(), pa:Up()
    local look = angles:Forward()
    local lx, ly, lz = look:Dot(pf), look:Dot(pl), look:Dot(pu)

    -- The seat's heading in the world, from its forward projected flat; a
    -- seat pointing straight up or down has none, so keep the last one.
    local hf = Vector(pf.x, pf.y, 0)
    local heading = hf:LengthSqr() > 1e-6 and hf:Angle().y or (sYaw or pa.y)
    local yaw = followYaw(heading, dt)

    local _, pitch = BMX.Attitude(bike, vector_up)
    sTilt = sTilt + (math.deg(pitch) - sTilt) * math.min(1, CAM_TILTRATE * dt)

    local fa = Angle(0, yaw, 0)
    local ff, fl, fu = fa:Forward(), -fa:Right(), fa:Up()
    local out = (ff * lx + fl * ly + fu * lz):Angle()
    out.p = math.Clamp(math.NormalizeAngle(out.p) - sTilt * CAM_TILT, -89, 89)
    return out
end
BMX.CameraEasedAngles = easedAngles

local function approach(cur, target, rate)
    return cur + (target - cur) * math.min(1, rate * FrameTime())
end

--------------------------------------------------------------------------
-- Find the bike the local player is riding.
--
-- The pod is PARENTED to the bike, so the parent link is the answer and there
-- is nothing to network. The IsBMX flag on the class is what makes this safe
-- against every other parented seat in every other addon.
--------------------------------------------------------------------------
function BMX.LocalBike(ply)
    local veh = ply:GetVehicle()
    if not IsValid(veh) then return nil end

    local parent = veh:GetParent()
    if IsValid(parent) and parent.IsBMX then return parent end
    return nil
end

hook.Add("CalcView", "BMX.ChaseCam", function(ply, origin, angles, fov)
    -- A replay (cl_replay.lua) or a filmer camera (cl_filmer.lua) owns the view.
    if BMX.ReplayActive and BMX.ReplayActive() then return end
    if BMX.FilmerViewing and BMX.FilmerViewing() then return end

    -- Thrown off in cinematic mode: keep filming, now the crash ragdoll.
    local rag = BMX.CinematicTumbling and BMX.CinematicTumbling(ply)
    if rag and BMX.CinematicActive(ply) then
        return BMX.CinematicTumbleView(rag, FrameTime(), CurTime())
    end

    local bike = BMX.LocalBike(ply)
    if not bike then sBike = nil return end

    -- Cinematic mode (cl_cinematic.lua, L) takes the whole view.
    if BMX.CinematicActive and BMX.CinematicActive(ply) then
        sBike = nil
        return BMX.CinematicView(bike, FrameTime(), CurTime())
    end

    local speed = bike:GetSpeedUPS()
    local frac  = BMX.Ramp(speed, 0, 340)      -- 340 u/s is about top speed

    local roll = select(1, BMX.Attitude(bike, vector_up))

    if sBike ~= bike then
        sBike = bike
        sZ = nil
        sDist = cv_dist:GetFloat() * (1 + frac * 0.35)
        sFov  = fov + frac * 16
        sRoll = math.deg(roll) * cv_roll:GetFloat()
        sYaw, sYawV, sTilt = nil, 0, 0
        airState.t, airState.phase = 0, 0
    end
    local airBlend = BMX.AirCamStep(airState, bike:GetGrounded(), FrameTime())

    if cv_smooth:GetBool() then angles = easedAngles(bike, angles, FrameTime()) end

    ----------------------------------------------------------------------
    -- Lean
    ----------------------------------------------------------------------
    sRoll = approach(sRoll, math.deg(roll) * cv_roll:GetFloat(), 9)

    ----------------------------------------------------------------------
    -- First person, from roughly where the bars are.
    ----------------------------------------------------------------------
    if cv_fp:GetBool() then
        local view = {
            origin = bike:LocalToWorld(Vector(6, 0, 40)),
            angles = Angle(angles.p, angles.y, sRoll),
            fov    = fov + frac * 12,
            drawviewer = false,
        }
        return view
    end

    ----------------------------------------------------------------------
    -- Chase
    ----------------------------------------------------------------------
    -- STRAIGHT UP from the bike, in the world: not up the bike's own axis.
    -- The camera looks over a rider, not along a mast bolted to the frame;
    -- aimed up the frame, every degree of lean swung the view sideways (17.8
    -- units of sway for a bike rocking +-20 degrees), and a calm ride felt
    -- like a boat. tests/test_client.lua, "calm camera".
    local target = bike:GetPos() + Vector(0, 0, cv_height:GetFloat())
    target.z = followHeight(target.z, FrameTime())
    sDist = approach(sDist, cv_dist:GetFloat() * (1 + frac * 0.35), 4)
    sFov  = approach(sFov,  fov + frac * 16, 4)

    -- The trick camera's share, on top of the smoothed speed pull-back.
    local airDist, airFov = BMX.AirCamExtras(airBlend, cv_air:GetFloat())
    local wanted = target - angles:Forward() * (sDist * airDist)

    -- Keep the camera out of the world. A hull trace rather than a line, so it
    -- does not squeeze through a doorframe and end up inside a wall.
    local tr = util.TraceHull({
        start  = target,
        endpos = wanted,
        mins   = Vector(-8, -8, -8),
        maxs   = Vector( 8,  8,  8),
        filter = { bike, ply, bike:GetPod() },
        mask   = MASK_SOLID_BRUSHONLY,
    })

    return {
        origin = tr.HitPos,
        angles = Angle(angles.p, angles.y, sRoll),
        fov    = sFov + airFov,
        drawviewer = true,
    }
end)

--------------------------------------------------------------------------
-- Let the rider look freely. Without this the pod clamps the view to a cone
-- around the seat's forward, which makes a chase camera useless.
--
-- The pod is also created with limitview 0 server-side; this is the client half
-- of the same statement, and both are needed.
--------------------------------------------------------------------------
hook.Add("CalcVehicleView", "BMX.FreeLook", function(veh, ply, view)
    local parent = veh:GetParent()
    if IsValid(parent) and parent.IsBMX then
        return view
    end
end)

--------------------------------------------------------------------------
-- Hide the viewmodel/crosshair while riding: there is no weapon in play and a
-- crosshair over a chase camera is just noise.
--------------------------------------------------------------------------
hook.Add("HUDShouldDraw", "BMX.HideCrosshair", function(name)
    if name == "CHudCrosshair" and BMX.LocalBike(LocalPlayer()) then
        return false
    end
end)
