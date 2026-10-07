--[[--------------------------------------------------------------------------
    bmx/cl_passenger.lua

    THE PASSENGER, drawn (G11). The client's half of the second seat: who is a
    passenger rather than a rider, how they sit, where their hands and feet go, and
    the child seat that is drawn when it is on.

    WHO IS A PASSENGER. Every pod is parented to the bike, and the rider's is the
    one the bike names (`GetPod`); a player in any other pod of that bike is a
    passenger, and the bike's networked `PaxPegs` / `PaxChild` say which seat. So
    nothing about it is networked separately: it is what the client already knows.

    HOW THEY SIT. The rider's pose is a function of the bike (cl_rider.lua), and a
    passenger must NOT get it -- the bars are not in their hands. Theirs is the
    PASSENGER pose: the same drive_airboat sit as everyone's, the torso leaning
    forward over the rider's back, and IK for the four limbs:

        hands   on the rider's shoulders (the rider's upper-arm bones, read off
                the rider's own skeleton this frame)
        feet    on the rear pegs (on the pegs' passenger), or tucked either side of
                the child seat's footrest (the child)

    A passenger the IK cannot reach (the rider's bones are not set up, the rider has
    left) keeps the plain seated pose; this never errors a frame.

    FREE LOOK. The camera hook (cl_view.lua) leaves a passenger's view to the engine,
    which is the pod's own: the passenger looks wherever they like and may use the
    mouse, which is also the "camera person" a clip wants (G28).
----------------------------------------------------------------------------]]

BMX = BMX or {}

-- Is this player in a passenger seat of a bike, rather than at the bars?
function BMX.IsPassenger(ply)
    if not IsValid(ply) then return false end
    local veh = ply:GetVehicle()
    if not IsValid(veh) then return false end
    local bike = veh:GetParent()
    return IsValid(bike) and bike.IsBMX == true and veh ~= bike:GetPod()
end

-- Which seat: "pegs", "child", or nil.
function BMX.PassengerKind(ply, bike)
    if not IsValid(bike) then return nil end
    if bike.GetPaxChild and bike:GetPaxChild() == ply then return "child" end
    if bike.GetPaxPegs and bike:GetPaxPegs() == ply then return "pegs" end
    return nil
end

local SHOULDER = { r = "ValveBiped.Bip01_R_UpperArm", l = "ValveBiped.Bip01_L_UpperArm" }

-- The world-space targets for a passenger's limbs, as BMX.SolveRiderIK takes them.
-- `rider` may be nil (nobody at the bars): the hands then go to where the rider's
-- shoulders would be.
function BMX.PassengerTargets(ply, bike, kind, rider)
    -- A TANDEM'S STOKER (G13) has their own pedals and bars, drawn where the
    -- registration puts them (cl_oddbikes.lua), not the pegs and the rider's shoulders.
    if kind == "pegs" and bike.ikTargetsStoker and bike.ikTargetsStoker.rFoot then
        return bike.ikTargetsStoker
    end
    local C = bike:Cfg()
    local half = C.Wheel.wheelbase * 0.5
    local so = C.Chassis.seatOffset
    local t = {}

    -- Hands: the rider's shoulders, or their expected place.
    for _, s in ipairs({ "r", "l" }) do
        local p
        if IsValid(rider) then
            local b = rider:LookupBone(SHOULDER[s])
            if b then p = rider:GetBonePosition(b) end
        end
        p = p or bike:LocalToWorld(Vector(so.x + 2, (s == "r") and -7 or 7, so.z + 20))
        t[s == "r" and "rHand" or "lHand"] = p + bike:GetUp() * 1.5
    end

    -- Feet.
    if kind == "child" then
        -- Either side of the footrest, low on the rear stays.
        t.rFoot = bike:LocalToWorld(Vector(-half * 0.8 + 3, -5, 4))
        t.lFoot = bike:LocalToWorld(Vector(-half * 0.8 + 3,  5, 4))
    else
        -- On the pegs: on the rear axle, out where the peg sticks from it.
        local G = C.Grind
        local y = G.pegY + 3
        t.rFoot = bike:LocalToWorld(Vector(-half, -y, G.pegZ + 2.5))
        t.lFoot = bike:LocalToWorld(Vector(-half,  y, G.pegZ + 2.5))
    end
    return t
end

-- The torso: forward over the rider's back (a standing passenger leans on them),
-- upright in a child seat.
local LEAN = { pegs = 16, child = 4 }

function BMX.PassengerPose(ply, bike)
    local kind = BMX.PassengerKind(ply, bike) or "pegs"
    local b = ply:LookupBone("ValveBiped.Bip01_Spine2")
    if b then ply:ManipulateBoneAngles(b, Angle(0, LEAN[kind], 0)) end
    local head = ply:LookupBone("ValveBiped.Bip01_Head1")
    if head then ply:ManipulateBoneAngles(head, Angle(0, -LEAN[kind] * 0.7, 0)) end
    if BMX.SolveRiderIK and GetConVar("bmx_rider_ik"):GetBool() then
        local targets = BMX.PassengerTargets(ply, bike, kind, bike:GetDriver())
        BMX.SolveRiderIK(ply, targets, bike)
    end
end

-- bmx_rider_anim 0 leaves every rider in the plain seated pose, a passenger too:
-- cl_rider.lua asks, and clears the bones when it does not.
