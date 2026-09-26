--[[--------------------------------------------------------------------------
    bmx/sv_seat.lua

    Binding a player to a bike, and unbinding them again in every way it can
    happen: getting off, dying, disconnecting, or the bike being removed
    underneath them.

    These are global hooks rather than entity methods because PlayerEnteredVehicle
    and friends fire on the gamemode, not on the vehicle, and because the unbind
    path has to survive the bike already being NULL.
----------------------------------------------------------------------------]]

BMX = BMX or {}

local function bind(ply, bike)
    if not IsValid(ply) or not IsValid(bike) then return end

    bike:SetDriver(ply)
    ply.BMXBike = bike

    -- A fresh input table per rider. Reusing the old one hands the new rider
    -- the previous one's half-held brake, which is a bug that only shows up on
    -- a busy server and is miserable to track down.
    bike.input = BMX.BlankInput()
    bike.hopHeld, bike.hopRelease, bike.hopCharge = false, false, 0

    -- Re-arm the crash grace period. Mounting a bike that is mid-tumble should
    -- not immediately throw the person who just got on it.
    bike.spawnTime = CurTime()

    bike:RebuildTraceFilter()

    local phys = bike:GetPhysicsObject()
    if IsValid(phys) then phys:Wake() end

    BMX.PickUp(bike)

    hook.Run("BMX_RiderMounted", bike, ply)
end

--------------------------------------------------------------------------
-- Getting on a bike that is lying on its side picks it up, as a rider would.
--
-- Nothing else can: the kickstand and the foot (C.Stand) only hold a bike
-- that is still up, and the lean assist needs speed. Before this, a bike that
-- had been knocked over or crashed was scenery for the rest of the map.
--
-- Stood up where it lies, facing the way it was pointing, lifted clear of
-- the ground and stopped, with the controller's history reset so the first
-- substep does not read the righting as a roll rate of hundreds of degrees a
-- second.
--------------------------------------------------------------------------
function BMX.IsFallen(bike)
    local roll, pitch = BMX.Attitude(bike, vector_up)
    local S = bike:Cfg().Stand
    return math.abs(roll) > S.maxRoll or math.abs(pitch) > S.maxRoll
end

-- Where a picked-up bike ends: upright, facing the way it pointed, standing on
-- the ground under it AT ITS RESTING HEIGHT. It used to be put down a wheel
-- radius and 4 units up, and dropped, so every pick-up ended in a bounce.
local function uprightPose(bike)
    local fwd = bike:GetForward()
    local yaw = (math.abs(fwd.x) + math.abs(fwd.y) > 1e-3)
        and math.deg(math.atan2(fwd.y, fwd.x)) or bike:GetAngles().y
    local from = bike:GetPos() + Vector(0, 0, 40)
    local tr = util.TraceLine({ start = from, endpos = from - Vector(0, 0, 200),
        filter = { bike, bike:GetPod() }, mask = MASK_SOLID })
    local ground = tr.Hit and tr.HitPos or (bike:GetPos() - Vector(0, 0, 20))
    return ground + Vector(0, 0, BMX.RestHeight(bike:Cfg())), Angle(0, yaw, 0)
end

-- THE PHYSICS OBJECT, not only the entity. On a VPhysics entity the physics
-- object is the authority: Entity:SetAngles alone was measured on the live
-- server to read -1 degrees a quarter second after being told 85.
local function setPose(bike, pos, ang)
    bike:SetAngles(ang)
    bike:SetPos(pos)
    local phys = bike:GetPhysicsObject()
    if IsValid(phys) then
        phys:SetAngles(ang)
        phys:SetPos(pos, true)
        phys:SetVelocity(vector_origin)
        phys:SetAngleVelocity(vector_origin)
    end
end

local function resetController(bike)
    local st = bike.st
    if not st then return end
    local roll, pitch = BMX.Attitude(bike, vector_up)
    st.lastRoll, st.lastPitch, st.roll, st.pitch = roll, pitch, roll, pitch
    st.rollRate, st.pitchRate = 0, 0
    st.prevF, st.prevR, st.prevU = nil, nil, nil
end

-- Instant pick-up, for anything that seats a rider without going through Use
-- (a script, another addon). Use goes through BMX.BeginPickUp instead.
function BMX.PickUp(bike)
    if not IsValid(bike) or not bike.st or not BMX.IsFallen(bike) then return false end
    local pos, ang = uprightPose(bike)
    setPose(bike, pos, ang)
    local phys = bike:GetPhysicsObject()
    if IsValid(phys) then phys:Wake() end
    resetController(bike)
    return true
end

--------------------------------------------------------------------------
-- PICKING A BIKE UP, where the player can see it. Pressing E on a bike lying
-- on its side used to snap it upright and drop it, in one tick, with the
-- rider already on: it teleported and bounced. Now the bike is held still and
-- swung upright over PICKUP_TIME while the player plays the reach-down
-- gesture, set down at its resting height, and only then do they get on.
--------------------------------------------------------------------------
local PICKUP_TIME = 0.7
BMX.PickupTime = PICKUP_TIME

util.AddNetworkString("bmx_gesture")
util.AddNetworkString("bmx_quiet")

function BMX.BeginPickUp(bike, ply)
    if not IsValid(bike) or not IsValid(ply) or bike.pickingUp then return false end
    local phys = bike:GetPhysicsObject()
    if not IsValid(phys) then return false end

    local pos0, ang0 = bike:GetPos(), bike:GetAngles()
    local pos1, ang1 = uprightPose(bike)
    bike.pickingUp = true
    phys:EnableMotion(false)

    net.Start("bmx_gesture")
        net.WriteEntity(ply)
        net.WriteString("pickup")
    net.Broadcast()

    local t0 = CurTime()
    local id = "BMX.PickUp." .. bike:EntIndex()
    hook.Add("Think", id, function()
        local done = not IsValid(bike) or not IsValid(ply) or not ply:Alive()
            or ply:InVehicle() or ply:GetPos():Distance(bike:GetPos()) > 160
        local f = done and 1 or math.min(1, (CurTime() - t0) / PICKUP_TIME)
        if IsValid(bike) then
            -- Ease in and out: a bike is lifted, not flicked.
            local e = f * f * (3 - 2 * f)
            local ang = LerpAngle(e, ang0, ang1)
            local pos = LerpVector(e, pos0, pos1)
            local p = bike:GetPhysicsObject()
            if IsValid(p) then p:SetAngles(ang) p:SetPos(pos, true) end
            bike:SetAngles(ang)
            bike:SetPos(pos)
        end
        if f < 1 then return end

        hook.Remove("Think", id)
        if not IsValid(bike) then return end
        bike.pickingUp = nil
        setPose(bike, pos1, ang1)
        local p = bike:GetPhysicsObject()
        if IsValid(p) then p:EnableMotion(true) p:Wake() end
        resetController(bike)
        if not done and IsValid(bike:GetPod()) and not IsValid(bike:GetDriver()) then
            ply:EnterVehicle(bike:GetPod())
        end
    end)
    return true
end

--------------------------------------------------------------------------
-- THROWN OFF AS A BODY. A crash used to shove the player out of the seat
-- standing up: a bike that fell over sideways left its rider sliding out of
-- it upright, legs through the floor on the way. Now they are swapped for a
-- ragdoll of themselves carrying the bike's momentum, the camera follows it,
-- and after TUMBLE_TIME they are back on their feet where it came to rest,
-- with the health, armour, weapons and ammo they had.
--
-- Returns false if it could not (no ragdoll, a dead player), and the caller
-- falls back to the shove.
--------------------------------------------------------------------------
local TUMBLE_TIME = 1.6
BMX.TumbleTime = TUMBLE_TIME

CreateConVar("bmx_crash_ragdoll", "1", bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY),
    "Throw crashed riders off as a ragdoll for a moment (0 = the old shove).")

function BMX.Tumble(ply, vel, after)
    if not IsValid(ply) or not ply:Alive() or ply.BMXTumbling then return false end
    local rag = ents.Create("prop_ragdoll")
    if not IsValid(rag) then return false end

    -- AN IMITATION OF THE PLAYER, not just their model: skin, bodygroups,
    -- material and player colour too, or a player in a customised outfit
    -- tumbles off as the plain default of whatever model they wear.
    rag:SetModel(ply:GetModel())
    rag:SetSkin(ply:GetSkin())
    for i = 0, (ply:GetNumBodyGroups() or 1) - 1 do
        rag:SetBodygroup(i, ply:GetBodygroup(i))
    end
    if ply:GetMaterial() ~= "" then rag:SetMaterial(ply:GetMaterial()) end
    rag:SetColor(ply:GetColor())
    -- Player colour is a material proxy that asks the ENTITY for
    -- GetPlayerColor, which a prop_ragdoll does not have: carried over on a
    -- networked var and answered client-side (cl_rider.lua).
    rag:SetNWVector("BMXPlayerColor", ply:GetPlayerColor())
    rag:SetNWEntity("BMXRider", ply)
    rag:SetPos(ply:GetPos())
    rag:SetAngles(Angle(0, ply:EyeAngles().y, 0))
    rag:Spawn()
    rag:Activate()
    -- Not into the bike it came off, nor into other players.
    rag:SetCollisionGroup(COLLISION_GROUP_WEAPON)

    -- Match the pose they were in and give every limb the throw.
    for i = 0, rag:GetPhysicsObjectCount() - 1 do
        local po = rag:GetPhysicsObjectNum(i)
        if IsValid(po) then
            local bone = rag:TranslatePhysBoneToBone(i)
            local bp, ba = ply:GetBonePosition(bone)
            if bp then po:SetPos(bp) end
            if ba then po:SetAngles(ba) end
            po:SetVelocity(vel)
            po:Wake()
        end
    end

    local saved = {
        health = ply:Health(), armor = ply:Armor(),
        weapons = {}, ammo = ply:GetAmmo(),
        active = IsValid(ply:GetActiveWeapon()) and ply:GetActiveWeapon():GetClass() or nil,
        eyes = ply:EyeAngles(),
    }
    for _, w in ipairs(ply:GetWeapons()) do saved.weapons[#saved.weapons + 1] = w:GetClass() end

    -- Nothing in their hand while they tumble: the held weapon stayed
    -- attached to a player who was only spectating, floating by the ragdoll.
    -- Everything was saved above and is given back when they get up.
    ply:StripWeapons()

    ply.BMXTumbling = rag
    ply:Spectate(OBS_MODE_CHASE)
    ply:SpectateEntity(rag)

    timer.Simple(TUMBLE_TIME, function()
        if not IsValid(ply) then SafeRemoveEntity(rag) return end
        ply.BMXTumbling = nil
        local at = IsValid(rag) and rag:GetPos() or ply:GetPos()
        SafeRemoveEntity(rag)

        -- Quiet, for the moment it takes: giving everything back fires a
        -- "picked up" notice per weapon and ammo type down the right of the
        -- screen, which reads as a pile of loot rather than getting up.
        net.Start("bmx_quiet")
            net.WriteFloat(0.75)
        net.Send(ply)

        ply:UnSpectate()
        ply:Spawn()
        ply:SetPos(at + Vector(0, 0, 4))
        ply:SetEyeAngles(Angle(0, saved.eyes.y, 0))
        ply:SetHealth(saved.health)
        ply:SetArmor(saved.armor)
        ply:StripWeapons()
        ply:RemoveAllAmmo()
        for _, class in ipairs(saved.weapons) do ply:Give(class, true) end
        for id, n in pairs(saved.ammo or {}) do ply:SetAmmo(n, id) end
        if saved.active then ply:SelectWeapon(saved.active) end

        if after then after() end
    end)
    return true
end

-- A player who leaves mid-tumble takes their ragdoll with them.
hook.Add("PlayerDisconnected", "BMX.TumbleCleanup", function(ply)
    if IsValid(ply.BMXTumbling) then SafeRemoveEntity(ply.BMXTumbling) end
end)

local function unbind(ply, bike)
    bike = IsValid(bike) and bike or (IsValid(ply) and ply.BMXBike)

    if IsValid(ply) then ply.BMXBike = nil end

    if IsValid(bike) then
        bike:SetDriver(NULL)
        bike.input = BMX.BlankInput()
        bike.hopHeld, bike.hopRelease, bike.hopCharge = false, false, 0
        bike:RebuildTraceFilter()
        hook.Run("BMX_RiderDismounted", bike, ply)
    end
end

BMX.BindRider   = bind
BMX.UnbindRider = unbind

hook.Add("PlayerEnteredVehicle", "BMX.Mount", function(ply, veh)
    if IsValid(veh) and IsValid(veh.BMXBike) then
        bind(ply, veh.BMXBike)
    end
end)

--------------------------------------------------------------------------
-- WHERE A RIDER GETS OFF. The pod's own exit point is inside the bike's
-- hull, which is tall on purpose (it stands in for the rider), so a player
-- set down there is embedded in the bike they just left: stuck to it, or
-- shoving it about as the engine tries to separate the two. So step off to
-- the left, the right, or behind, whichever has room, beside the hull.
--------------------------------------------------------------------------
local PLAYER_MIN, PLAYER_MAX = Vector(-16, -16, 0), Vector(16, 16, 72)

function BMX.ExitPoint(bike, ply)
    local C = bike:Cfg().Chassis
    local clear = math.max(math.abs(C.hullMin.y), math.abs(C.hullMax.y)) + 20
    local back  = math.abs(C.hullMin.x) + 24
    local ground = bike:GetPos() - Vector(0, 0, BMX.RestHeight(bike:Cfg()))
    for _, off in ipairs({ bike:GetRight() * -clear, bike:GetRight() * clear,
                           bike:GetForward() * -back }) do
        local spot = ground + Vector(off.x, off.y, 0) + Vector(0, 0, 4)
        local tr = util.TraceHull({ start = spot, endpos = spot, mins = PLAYER_MIN,
            maxs = PLAYER_MAX, filter = { bike, bike:GetPod(), ply }, mask = MASK_PLAYERSOLID })
        if not tr.StartSolid and not tr.Hit then return spot end
    end
    return nil
end

hook.Add("PlayerLeaveVehicle", "BMX.Dismount", function(ply, veh)
    if IsValid(veh) and veh.BMXBike then
        local bike = veh.BMXBike
        unbind(ply, bike)
        if IsValid(bike) and IsValid(ply) then
            local spot = BMX.ExitPoint(bike, ply)
            if spot then ply:SetPos(spot) end
        end
    end
end)

-- Dying in the seat does not always fire PlayerLeaveVehicle depending on the
-- gamemode, and a bike left holding a dead player's entity keeps steering.
hook.Add("PlayerDeath", "BMX.DismountOnDeath", function(ply)
    if IsValid(ply.BMXBike) then unbind(ply, ply.BMXBike) end
end)

hook.Add("PlayerDisconnected", "BMX.DismountOnDisconnect", function(ply)
    if IsValid(ply.BMXBike) then unbind(ply, ply.BMXBike) end
end)

--------------------------------------------------------------------------
-- THE RIDER MUST NOT COLLIDE WITH THE BIKE THEY ARE SITTING ON.
--
-- The chassis hull is deliberately tall enough to stand in for the rider's
-- body, and the seat sits inside it. So the moment a player is placed in the
-- pod, their own ~32x32x72 hull is interpenetrating the bike's, and the engine
-- resolves that the way it resolves any deep overlap: by pushing the two apart
-- as hard as it takes.
--
-- Measured before this existed: mounting a stationary, settled bike put it at
-- 88 u/s and airborne within one frame, and 500 units below the map shortly
-- after. Every downstream case failed for reasons that looked like physics
-- tuning -- the bike could not accelerate, could not hold a lean, could not
-- wheelie -- when in fact it was simply never on the ground after a rider got
-- on it.
--
-- SetCustomCollisionCheck(true) on the bike is what makes this hook get asked.
--------------------------------------------------------------------------
hook.Add("ShouldCollide", "BMX.RiderPassthrough", function(a, b)
    if not IsValid(a) or not IsValid(b) then return end

    local bike, other
    if a.IsBMX then bike, other = a, b
    elseif b.IsBMX then bike, other = b, a
    else return end

    if other == bike:GetPod() or other == bike:GetDriver() then
        return false
    end
end)

--------------------------------------------------------------------------
-- Physgun / toolgun etiquette
--------------------------------------------------------------------------

-- Never let anyone grab the seat: it is parented and invisible, and picking it
-- up detaches the rider's frame of reference from the bike in a way that looks
-- like the addon exploding.
hook.Add("PhysgunPickup", "BMX.NoPodGrab", function(ply, ent)
    if ent:GetClass() == "prop_vehicle_prisoner_pod" and ent.BMXBike then
        return false
    end
    -- AND NOT A BIKE WITH SOMEBODY ON IT. Holding a bike in the physgun puts
    -- its physics object under the engine's shadow controller while
    -- PhysicsSimulate keeps applying suspension and tyre forces to it every
    -- substep, and the rider is in a pod parented to the whole argument. There
    -- is no useful behaviour to define here, only degrees of mess, so the
    -- answer is no while it is occupied. An empty bike picks up normally.
    if ent.IsBMX and IsValid(ent:GetDriver()) then
        return false
    end
end)

-- Same reasoning for the gravity gun, which is the one a stranger on a public
-- server will actually reach for.
hook.Add("GravGunPickupAllowed", "BMX.NoGrabRidden", function(ply, ent)
    if not IsValid(ent) then return end
    if ent:GetClass() == "prop_vehicle_prisoner_pod" and ent.BMXBike then
        return false
    end
    if ent.IsBMX and IsValid(ent:GetDriver()) then
        return false
    end
end)

hook.Add("GravGunPunt", "BMX.NoPuntRidden", function(ply, ent)
    if IsValid(ent) and ent.IsBMX and IsValid(ent:GetDriver()) then
        return false
    end
end)

-- Dropping a bike out of the physgun should leave it awake, or it lands and
-- goes to sleep before the first PhysicsSimulate and never wakes.
hook.Add("PhysgunDrop", "BMX.WakeOnDrop", function(_, ent)
    if IsValid(ent) and ent.IsBMX then
        local phys = ent:GetPhysicsObject()
        if IsValid(phys) then phys:Wake() end
    end
end)

--------------------------------------------------------------------------
-- Spawning from the console, which is how you will actually test this.
--------------------------------------------------------------------------
--
-- IT ASKS THE GAMEMODE FIRST, exactly as the spawn menu does. The spawn menu
-- routes every entity through PlayerSpawnSENT, which is where sandbox applies
-- sbox_maxsents and where a server's admin mod applies its restrictions. A
-- console command that skipped it was a way round both: anyone on a public
-- server could type bmx_spawn in a loop. PlayerSpawnedSENT afterwards is what
-- counts the bike against that limit.
local SPAWN_COOLDOWN = 1.0

if cleanup then cleanup.Register("bmx") end

concommand.Add("bmx_spawn", function(ply, _, args)
    if not IsValid(ply) then return end

    local id    = args[1] or "stock"
    local class = BMX.ClassFor(id)
    if not class then
        ply:ChatPrint("[BMX] no such bike: " .. id ..
            " (try: " .. table.concat(BMX.BikeIDs(), ", ") .. ")")
        return
    end

    if CurTime() < (ply.BMXNextSpawn or 0) then return end
    ply.BMXNextSpawn = CurTime() + SPAWN_COOLDOWN

    if hook.Run("PlayerSpawnSENT", ply, class) == false then return end

    local tr = ply:GetEyeTrace()
    if not tr.Hit or tr.HitPos:Distance(ply:GetPos()) > 400 then
        ply:ChatPrint("[BMX] look at the ground within 400 units.")
        return
    end

    local ent = ents.Create(class)
    if not IsValid(ent) then return end

    -- At its resting height, not dropped from above: see BMX.RestHeight.
    ent:SetPos(tr.HitPos + tr.HitNormal * (BMX.RestHeight(ent:Cfg()) + 0.5))
    ent:SetAngles(Angle(0, ply:EyeAngles().y, 0))
    ent:Spawn()
    ent:Activate()

    hook.Run("PlayerSpawnedSENT", ply, ent)

    -- Undo history, so a tester can clean up with Z like any other spawn.
    undo.Create("BMX")
        undo.AddEntity(ent)
        undo.SetPlayer(ply)
    undo.Finish()

    if cleanup then cleanup.Add(ply, "bmx", ent) end
end)
