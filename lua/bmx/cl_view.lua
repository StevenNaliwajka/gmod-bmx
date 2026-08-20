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

-- Smoothed state, so the camera does not snap when speed or geometry changes.
local sDist, sFov, sRoll = 0, 0, 0

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
    local bike = BMX.LocalBike(ply)
    if not bike then return end

    local speed = bike:GetSpeedUPS()
    local frac  = BMX.Ramp(speed, 0, 340)      -- 340 u/s is about top speed

    ----------------------------------------------------------------------
    -- Lean
    ----------------------------------------------------------------------
    local roll = select(1, BMX.Attitude(bike, vector_up))
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
    local target = bike:LocalToWorld(Vector(0, 0, cv_height:GetFloat()))
    sDist = approach(sDist, cv_dist:GetFloat() * (1 + frac * 0.35), 4)
    sFov  = approach(sFov,  fov + frac * 16, 4)

    local wanted = target - angles:Forward() * sDist

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
        fov    = sFov,
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
