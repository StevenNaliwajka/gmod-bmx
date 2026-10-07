--[[--------------------------------------------------------------------------
    bmx/sh_stance.lua

    HOW A RIDER SITS ON THE BIKE (G21): seated, standing, or "attack
    position" (the crouch a BMX rider holds into a jump, weight low and
    forward). The competitor offers a sitting pose; this is a choice of three
    per rider, and it changes ONLY the IK targets and the torso lean that
    cl_rider.lua already solves, so there is no new animation to maintain.

    A STANCE IS A TABLE OF OFFSETS, not a pose. Each row names a hand or foot
    target and moves it by a vector in the bike's own space (X forward, Y
    left, Z up, inches at the stock wheelbase; the bike's size scales them),
    plus `spineLean`, degrees the torso folds forward. The offsets are added
    to wherever the bike says the grip or pedal is that frame, so the hands
    still follow the bars through a turn and the feet still ride the pedals.
    Nobody has watched these on a real model: they are numbers in a table,
    same as BMX.RiderPoses, and the solver is the same guarded one.

    WHY IT CROSSES THE NETWORK AT ALL. A userinfo convar (bmx_rider_pose) is
    each rider's choice, but a client cannot read another client's convars, so
    sv_stance.lua copies it onto the player as a networked int and every
    client reads that. It is a player var, not a bike var, so none of the
    entity's data tables (which the vehicle core refactor is moving) are
    touched.

    THE HOOK INTO cl_rider.lua is two calls, both optional: StanceTargets
    (returns the IK targets with the offsets applied) and StanceLean (the
    torso). They are plain functions so tests/test_stance.lua checks them
    without a renderer.
----------------------------------------------------------------------------]]

BMX = BMX or {}

BMX.RiderStances = { "seated", "standing", "attack" }

-- Name -> id (1-based) and back; the id is what a replay stores.
BMX.RiderStanceId = {}
for i, n in ipairs(BMX.RiderStances) do BMX.RiderStanceId[n] = i end

-- Offsets from the grip / pedal, bike space, inches at the stock wheelbase.
BMX.StanceOffsets = {
    seated   = {},
    -- Up out of the saddle, arms a little straighter, weight on the pedals.
    standing = { rHand = Vector(0.5, 0, 3), lHand = Vector(0.5, 0, 3),
                 rFoot = Vector(0, 0, 0.8), lFoot = Vector(0, 0, 0.8),
                 spineLean = -6 },
    -- Low and forward over the bars: elbows out, chest down, heels dropped.
    attack   = { rHand = Vector(1.5, 0, -1.5), lHand = Vector(1.5, 0, -1.5),
                 rFoot = Vector(0, 0, -0.5), lFoot = Vector(0, 0, -0.5),
                 spineLean = 22 },
}

local LIMB_KEYS = { "rHand", "lHand", "rFoot", "lFoot" }

-- The stance table for a name; anything unknown is seated.
function BMX.RiderPoseOffset(name)
    return BMX.StanceOffsets[name] or BMX.StanceOffsets.seated
end

function BMX.StanceName(id)
    return BMX.RiderStances[id] or BMX.RiderStances[1]
end

if CLIENT then
    -- Userinfo: the server's sv_stance.lua reads it and puts it on the player.
    local cv = CreateClientConVar("bmx_rider_pose", "seated", true, true,
        "How you sit on the bike: seated, standing or attack. Others see it too.")

    -- Which stance `ply` holds. Your own comes straight from the convar (no
    -- round trip, so a menu change shows at once); everyone else's from the
    -- networked int.
    function BMX.StanceOf(ply)
        if not IsValid(ply) then return "seated" end
        if ply == LocalPlayer() then
            local n = cv:GetString()
            return BMX.RiderStanceId[n] and n or "seated"
        end
        return BMX.StanceName(ply:GetNWInt("BMXStance", 1))
    end
else
    function BMX.StanceOf(ply)
        if not IsValid(ply) then return "seated" end
        return BMX.StanceName(ply:GetNWInt("BMXStance", 1))
    end
end

-- The bike's IK targets with `ply`'s stance applied: a COPY, because the bike
-- rebuilds its own table in Draw and applying twice between draws must not
-- stack. `bike` supplies the space and the scale.
function BMX.StanceTargets(ply, bike, ik)
    local off = BMX.RiderPoseOffset(BMX.StanceOf(ply))
    if not ik or next(off) == nil then return ik end
    local k = bike:Cfg().Wheel.wheelbase / 39
    local origin = bike:LocalToWorld(Vector(0, 0, 0))
    local out = {}
    for key, v in pairs(ik) do out[key] = v end
    for _, key in ipairs(LIMB_KEYS) do
        local d = off[key]
        if d and out[key] then
            local delta = bike:LocalToWorld(d * k) - origin
            out[key] = out[key] + delta
            -- A hand's grip RANGE moves with it, or the solver would pull
            -- the hand back to the nearest point of the unmoved bar.
            if out[key .. "A"] then out[key .. "A"] = out[key .. "A"] + delta end
            if out[key .. "B"] then out[key .. "B"] = out[key .. "B"] + delta end
        end
    end
    return out
end

-- Degrees the torso folds forward for this rider's stance.
function BMX.StanceLean(ply)
    return BMX.RiderPoseOffset(BMX.StanceOf(ply)).spineLean or 0
end
