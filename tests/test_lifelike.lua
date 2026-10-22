--[[--------------------------------------------------------------------------
    DOES THE RIDER MOVE AS A REAL ONE DOES? kleiner's real skeleton
    (lib/skeleton_real.lua) ridden through the moments a rider is seen in -- the
    board's cruise, the ollie's crouch, its pop, its tuck in the air, the landing, a
    push, a grab; the BMX seated, standing and in the attack stance -- and at each the
    joint angles measured as they were measured on footage of real riders: MediaPipe's
    pose model run over CC-licensed clips (tests/data/reference_angles.lua has the
    numbers, how they were made and the sources).

    1.3.9's skater bent only at the knees over an upright back: hips 7 degrees and the
    trunk 4 rolling along, 27 and 7 in the ollie's crouch (the footage: 42-78 and 7-40,
    78-133 and 38-55), the legs nearly straight in the air (61; the footage 85-128).
    Every one of those is a range here, so a change that makes the rider stiff again
    fails.

    THE MEASURES are tools/rider/angles.py's, on the posed bones: flexion from the joint
    centres (0 for straight); the hip is the trunk's line against the thigh; the trunk
    is the lean of the shoulders' middle over the hips' toward the way the hips face, less
    what kleiner's own idle has (it leans back 7 degrees by this measure, as a person
    standing reads a few degrees on the footage). A range is the footage's 10th to 90th
    percentile widened by SLACK: kleiner is not a twelve-year-old, and the estimate off a
    single camera is a few degrees out at best.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local SR = require("lib.skeleton_real")
local REF = dofile((debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "tests") .. "/data/reference_angles.lua")

local SLACK = 10

local function V(ply, name)
    return ply:GetBoneMatrix(ply:LookupBone("ValveBiped.Bip01_" .. name)):GetTranslation()
end
local function flex(a, b, c)
    local u, v = (a - b):GetNormalized(), (c - b):GetNormalized()
    return 180 - math.deg(math.acos(math.max(-1, math.min(1, u:Dot(v)))))
end

-- The angles of a posed player, as tools/rider/angles.py measures them.
local function angles(E, ply, trunk0)
    ply:InvalidateBoneCache(); ply:SetupBones()
    local lh, rh, lk, rk, la, ra = V(ply, "L_Thigh"), V(ply, "R_Thigh"), V(ply, "L_Calf"), V(ply, "R_Calf"),
        V(ply, "L_Foot"), V(ply, "R_Foot")
    local ls, rs, le, re, lw, rw = V(ply, "L_UpperArm"), V(ply, "R_UpperArm"), V(ply, "L_Forearm"),
        V(ply, "R_Forearm"), V(ply, "L_Hand"), V(ply, "R_Hand")
    local hipm, shm = (lh + rh) / 2, (ls + rs) / 2
    local up = E.Vector(0, 0, 1)
    local face = (lh - rh):Cross(up):GetNormalized()
    local t = shm - hipm
    local down = hipm - shm
    local function abd(s, e)
        local u, v = (e - s):GetNormalized(), down:GetNormalized()
        return math.deg(math.acos(math.max(-1, math.min(1, u:Dot(v)))))
    end
    return {
        kneeL = flex(lh, lk, la), kneeR = flex(rh, rk, ra),
        hipL = flex(shm, lh, lk), hipR = flex(shm, rh, rk),
        elbowL = flex(ls, le, lw), elbowR = flex(rs, re, rw),
        abdL = abd(ls, le), abdR = abd(rs, re),
        trunk = math.deg(math.atan2(t:Dot(face), t:Dot(up))) - (trunk0 or 0),
    }
end

local function within(v, range, what)
    T.ok(v >= range[1] - SLACK and v <= range[2] + SLACK,
        string.format("%s: %.0f, real riders %d-%d (+/- %d)", what, v, range[1], range[2], SLACK))
end
local function mean(a, b) return (a + b) * 0.5 end

local function seatPod(cl, ent, seat)
    local pod = cl.makeEntity("prop_vehicle_prisoner_pod")
    pod:SetParent(ent)
    pod:SetPos(ent:LocalToWorld(seat.offset))
    pod:SetAngles(ent:LocalToWorldAngles(seat.angles or cl.env.Angle(0, 0, 0)))
    return pod
end

-- A board ridden by kleiner, standing; `frame()` draws it and poses him; `lift(dz)`
-- moves the board and his seat together (the shim does not carry a parented pod).
local function boardRider()
    local sv, world = F.server()
    local cl = F.client(world)
    local E, B = cl.env, cl.env.BMX
    world.dt = 1 / 30
    local ent = cl:clientEntity("bmx_skateboard")
    ent:SetPos(E.Vector(0, 0, 1.3))
    ent:SetGrounded(true)
    ent:SetPushPhase(-1)
    local ply = cl:player("Rider")
    ply._skel = SR.load("kleiner_standing")
    -- (his own idle's trunk, before anything is moved: the zero of the trunk's lean)
    ply:SetPos(E.Vector(0, 0, 0))
    local trunk0 = angles(E, ply).trunk
    ply._vehicle = seatPod(cl, ent, B.SeatFor(ent:Bike(), ent:Cfg(), "rider"))
    ent:SetPod(ply._vehicle)
    ent:SetDriver(ply)
    cl.localPlayer = sv:player("Looker")
    cl.eyePos = ent:GetPos() + E.Vector(0, 150, 50)
    ent._vel = ent:GetForward() * 200
    ent:SetSpeedUPS(200)
    local r = { cl = cl, E = E, B = B, ent = ent, ply = ply, world = world }
    function r.frame(n)
        for _ = 1, n or 1 do
            world.time = world.time + world.dt
            ent:Draw()
            E.hook.Run("PrePlayerDraw", ply)
        end
    end
    function r.lift(dz)
        local d = E.Vector(0, 0, dz)
        ent:SetPos(ent:GetPos() + d)
        ply._vehicle:SetPos(ply._vehicle:GetPos() + d)
    end
    function r.angles() return angles(E, ply, trunk0) end
    return r
end

T.test("lifelike: a skater rolls along on soft knees, the hips back and the chest over the toes", function()
    local r = boardRider()
    r.frame(40)
    local a = r.angles()
    local ref = REF.board.cruise
    within(mean(a.kneeL, a.kneeR), ref.knee, "knees")
    within(mean(a.hipL, a.hipR), ref.hip, "hips")
    within(a.trunk, ref.trunk, "trunk lean")
    T.eq(#r.cl.errors, 0, "no errors: " .. table.concat(r.cl.errors, " | "))
end)

T.test("lifelike: the ollie -- a deep crouch, the legs straight off the tail, the knees up in the air, a soft landing", function()
    local r = boardRider()
    r.frame(30)
    local cruise = r.angles()
    for i = 1, 15 do r.ent:SetCrouch(math.min(1, i / 12)) r.frame() end
    local crouch = r.angles()
    local ref = REF.board
    within(mean(crouch.kneeL, crouch.kneeR), ref.crouch.knee, "crouch: knees")
    within(mean(crouch.hipL, crouch.hipR), ref.crouch.hip, "crouch: hips")
    within(crouch.trunk, ref.crouch.trunk, "crouch: trunk lean")
    -- the pop: the board leaves the ground and the crouch is let go
    r.ent:SetCrouch(0)
    r.ent:SetGrounded(false)
    local vz = 260
    local function airFrame()
        r.ent._vel = r.ent:GetForward() * 200 + r.E.Vector(0, 0, vz)
        r.lift(vz * r.world.dt)
        vz = vz - 600 * r.world.dt
        r.frame()
    end
    local backMin, tuck, abd = 180, 0, 0
    for i = 1, 26 do
        airFrame()
        local a = r.angles()
        if i <= 8 then backMin = math.min(backMin, a.kneeR) end   -- (regular: the right foot pops)
        tuck = math.max(tuck, mean(a.kneeL, a.kneeR))
        abd = math.max(abd, mean(a.abdL, a.abdR))
    end
    within(backMin, ref.pop.knee, "the pop: the back leg straightens off the tail")
    within(tuck, ref.tuck.knee, "the air: the knees pulled up")
    within(abd, ref.tuck.abd, "the air: the arms out")
    -- down, hard: the deepest of the fold
    r.ent:SetGrounded(true)
    local land = { knee = 0, trunk = -90 }
    for _ = 1, 12 do
        r.frame()
        local a = r.angles()
        land.knee, land.trunk = math.max(land.knee, mean(a.kneeL, a.kneeR)), math.max(land.trunk, a.trunk)
    end
    within(land.knee, ref.landing.knee, "landing: knees")
    within(land.trunk, ref.landing.trunk, "landing: trunk lean")
    T.ok(land.knee > mean(cruise.kneeL, cruise.kneeR) + 8, "the landing folds the knees deeper than the cruise")
    r.frame(45)
    local after = r.angles()
    T.ok(math.abs(mean(after.kneeL, after.kneeR) - mean(cruise.kneeL, cruise.kneeR)) < 8, "and comes back up to the cruise")
    T.eq(#r.cl.errors, 0, "no errors: " .. table.concat(r.cl.errors, " | "))
end)

T.test("lifelike: a push folds the standing knee as the other foot reaches the ground", function()
    local r = boardRider()
    r.frame(20)
    local deepest = 0
    for i = 1, 18 do
        r.ent:SetPushPhase((i / 18) * 0.9)
        r.frame()
        deepest = math.max(deepest, r.angles().kneeL)       -- (regular: the left foot stands)
    end
    within(deepest, REF.board.push.standKnee, "the standing knee at the bottom of the push")
end)

T.test("lifelike: a grab is a tuck, the knees up to the chest, not a rider bent down to the board", function()
    local r = boardRider()
    r.frame(20)
    r.ent:SetGrounded(false)
    r.lift(20)
    for _, name in ipairs({ "indy", "melon", "stalefish", "tailgrab" }) do
        r.ent:SetTrickBits(r.B.PoseIDs[name] * 65536)
        r.frame(14)
        local a = r.angles()
        T.ok(mean(a.kneeL, a.kneeR) >= REF.board.tuck.knee[1], string.format("%s: the knees at %.0f", name, mean(a.kneeL, a.kneeR)))
        T.ok(mean(a.hipL, a.hipR) >= 70, string.format("%s: the hips folded, %.0f", name, mean(a.hipL, a.hipR)))
        r.ent:SetTrickBits(0)
        r.frame(12)
    end
end)

--------------------------------------------------------------------------
-- The BMX
--------------------------------------------------------------------------
local function bikeRider(id)
    local sv, world = F.server()
    local cl = F.client(world)
    local E, B = cl.env, cl.env.BMX
    world.dt = 1 / 30
    local ent = cl:clientEntity(B.ClassFor(id))
    ent:SetPos(E.Vector(0, 0, F.restHeight(sv)))
    ent:SetGrounded(true)
    ent:SetPedalling(true)
    local ply = cl:player("Rider")
    ply._skel = SR.load("kleiner_standing")
    ply:SetPos(E.Vector(0, 0, 0))
    local trunk0 = angles(E, ply).trunk
    ply._skel = SR.load("kleiner_seated")
    ply._vehicle = seatPod(cl, ent, B.SeatFor(ent:Bike(), ent:Cfg(), "rider"))
    ent:SetPod(ply._vehicle)
    ent:SetDriver(ply)
    cl.localPlayer = sv:player("Looker")
    cl.eyePos = ent:GetPos() + E.Vector(0, 150, 50)
    ent._vel = ent:GetForward() * 150
    ent:SetSpeedUPS(150)
    local crank = 0
    ent.CrankAngle = function() return crank end
    local r = { cl = cl, E = E, B = B, ent = ent, ply = ply }
    function r.frame(n)
        for _ = 1, n or 1 do
            world.time = world.time + world.dt
            crank = crank + 7 * world.dt
            ent:Draw()
            E.hook.Run("PrePlayerDraw", ply)
        end
    end
    function r.angles() return angles(E, ply, trunk0) end
    return r
end

T.test("lifelike: a BMX rider sits leaning to the bars, the knees working through the stroke", function()
    local r = bikeRider("stock")
    r.frame(30)
    local lo, hi, trunk = 180, 0, 0
    for _ = 1, 30 do
        r.frame()
        local a = r.angles()
        lo, hi, trunk = math.min(lo, a.kneeR), math.max(hi, a.kneeR), trunk + a.trunk / 30
    end
    T.ok(hi - lo > 25, string.format("the knee works through the stroke: %.0f to %.0f", lo, hi))
    -- (a BMX's saddle is low: the knee closes further than on the footage's city bike,
    -- so only how far forward the rider leans is held to it, and only from below)
    T.ok(trunk >= REF.bike.seated.trunk[1] - SLACK, string.format("leaning to the bars: %.0f (real riders %d-%d)",
        trunk, REF.bike.seated.trunk[1], REF.bike.seated.trunk[2]))
end)

T.test("lifelike: stood up out of the saddle and in the attack stance, the back folds over the bars", function()
    local r = bikeRider("stock")
    r.frame(20)
    local seated = r.angles()
    r.ply:SetNWInt("BMXStance", 2)                      -- standing
    r.frame(40)
    local standing = r.angles()
    r.ply:SetNWInt("BMXStance", 3)                      -- attack
    r.frame(40)
    local attack = r.angles()
    T.ok(standing.trunk > seated.trunk + 2, string.format("standing leans further than seated: %.0f vs %.0f", standing.trunk, seated.trunk))
    T.ok(attack.trunk > standing.trunk + 8, string.format("the attack stance further still: %.0f", attack.trunk))
    within(attack.trunk, REF.bike.attack.trunk, "attack: trunk lean")
    within(mean(standing.elbowL, standing.elbowR), REF.bike.standing.elbow, "standing: elbows")
end)
