--[[--------------------------------------------------------------------------
    tools/rider/studio/studio.lua

    THE PHOTO STUDIO, offline: a vehicle ridden by kleiner's REAL skeleton (the
    capture in tests/data, lib/skeleton_real.lua) through a scripted scenario,
    posed by the shipped cl_rider.lua and the vehicle's own drawing, and every
    captured frame written out as JSON -- each bone's matrix, the vehicle's built
    model as it was drawn (mesh triangles and the matrix of each group), the IK's
    targets. render.py then skins kleiner's own mesh on those bones and draws it
    with the vehicle, so what a player would see is looked at in seconds, without
    a game client. tools/rider/studio/studio.sh runs both.

        lua5.1 tools/rider/studio/studio.lua <id> [scenario] > shots.json

    Scenarios: `bike` (pedalling, the stances, full lock, a hop, a no-hander), `stroke`
    (a shot every eighth of a pedal turn),
    `styles` (each style pose in the air), `board` (cruise, pushes, carves, the
    crouch, an ollie, a grab, a manual), `flips` (a kickflip and a shove-it),
    `scooter` (kicks, steer, a hop) and, for worn vehicles, the skates' strides;
    `rest` is the capture with nothing moved. The default is the vehicle's own.
    `skate_session`, `bike_session` and `scooter_session` are rides for VIDEO (below).
    STUDIO_PAX=1 puts a passenger on the pegs (or a tandem's stoker).

    It is the same offline client the suite runs (tests/lib/gmod.lua), so the
    engine's own animation is not here: the base sequence is the capture's frame,
    with the head where the capture's bot was looking. tools/ride/shoot.sh is the
    real client's photograph.

    VIDEO (STUDIO_VIDEO=1, which tools/rider/studio/video.sh sets): a shot is
    written for EVERY simulated frame of the scenario instead of at its labels,
    each with its time and the phase it is in, so the frames can be played as a
    film. A still is enough to see a cocked wrist; it takes motion to see a foot
    sliding on the deck, a knee that pops between two frames or a crouch that
    comes too late for the pop. The `*_session` scenarios are written for it: the
    vehicle really travels (its position advances every frame at its speed and
    the rider's seat goes with it), an air is a parabola under the world's
    gravity, and every phase is timed in seconds, so they run at any frame rate
    (STUDIO_FPS, default 30). The other scenarios still work in video mode but
    teleport, as they were written to for stills.
----------------------------------------------------------------------------]]
local here = (arg and arg[0] or "tools/rider/studio/studio.lua"):match("^(.*)/[^/]*$") or "."
local root = here .. "/../../.."
package.path = root .. "/tests/?.lua;" .. package.path
local gmod = require("lib.gmod")
gmod.ROOT = root
_G.T = require("lib.t")
local F  = require("lib.fixture")
local J  = require("lib.json")
local MF = require("lib.meshfake")
local SR = require("lib.skeleton_real")

local ID, SCEN = arg[1] or "skateboard", (arg[2] ~= "" and arg[2]) or "default"
-- VIDEO MODE (see the header): every frame recorded, at STUDIO_FPS frames a second.
local VIDEO = os.getenv("STUDIO_VIDEO") == "1"
local FPS = tonumber(os.getenv("STUDIO_FPS") or "") or 30
local sv, world = F.server()
local cl = F.client(world)
local E, B = cl.env, cl.env.BMX
MF.enable(cl)

-- Record every mesh's triangles (positions) as it is built.
local meshes, meshOf = {}, {}
local origMesh = E.Mesh
E.Mesh = function(...)
    local m = origMesh(...)
    local id = #meshes + 1
    meshes[id] = false
    meshOf[m] = id
    function m:BuildFromTriangles(verts)
        local p = {}
        for _, v in ipairs(verts) do
            local q = v.pos
            p[#p + 1] = math.floor(q.x * 1000 + 0.5) / 1000
            p[#p + 1] = math.floor(q.y * 1000 + 0.5) / 1000
            p[#p + 1] = math.floor(q.z * 1000 + 0.5) / 1000
        end
        meshes[id] = p
    end
    return m
end
-- Which meshes each drawn group is, under which matrix.
local drawn = {}
local BM = B.BikeMesh
local dg = BM.DrawGroup
BM.DrawGroup = function(model, name, mtx, paint, lod)
    local list = model.groups[name]
    if list then
        for _, e in ipairs(list) do
            if not (e.detail and (lod or 0) >= 2) then
                for _, m in ipairs(e.meshes) do
                    local r = mtx.rows
                    drawn[#drawn + 1] = { mesh = meshOf[m], mat = tostring(e.mat), name = name,
                        paint = paint and { paint.r, paint.g, paint.b } or nil,
                        m = { r[1][1], r[1][2], r[1][3], r[1][4], r[2][1], r[2][2], r[2][3], r[2][4],
                              r[3][1], r[3][2], r[3][3], r[3][4] } }
                end
            end
        end
    end
    return dg(model, name, mtx, paint, lod)
end
-- Tubes drawn immediately (cables, kickstand): as line segments.
local tubes = {}
local dt_ = BM.DrawTube
BM.DrawTube = function(pts, radius, role, sides, paint)
    local t = { r = radius, pts = {} }
    for _, p in ipairs(pts) do t.pts[#t.pts + 1] = { p.x, p.y, p.z } end
    tubes[#tubes + 1] = t
    return dt_(pts, radius, role, sides, paint)
end

local function seatPod(ent, seat)
    local pod = cl.makeEntity("prop_vehicle_prisoner_pod")
    pod:SetParent(ent)
    pod:SetPos(ent:LocalToWorld(seat.offset))
    pod:SetAngles(ent:LocalToWorldAngles(seat.angles or E.Angle(0, 0, 0)))
    return pod
end

local def = B.Vehicles[ID]
-- CARRY: the skateboard in hand (weapon_bmx_board), on a player standing in the idle
-- the "normal" hold is (the standing capture): the idle's arm, then the carry's.
if SCEN == "carry" then
    local ply = cl:player("Carrier")
    ply._skel = SR.load("kleiner_standing")
    ply:SetPos(E.Vector(0, 0, 0))
    ply._eyeAngles = E.Angle(0, 0, 0)
    cl.localPlayer = sv:player("Looker")
    cl:loadWeapon("weapon_bmx_board")
    local SW = cl.sweps.weapon_bmx_board
    local wep = setmetatable({ GetOwner = function() return ply end, DrawModel = function() end }, { __index = SW })
    local shots = {}
    local function draw() drawn, tubes = {}, {} SW.DrawWorldModel(wep) end
    for _ = 1, 8000 do draw() if #drawn > 0 then break end end    -- (the model builds)
    local function shot(label)
        ply:InvalidateBoneCache(); ply:SetupBones()
        local out = {}
        for i, b in ipairs(ply._skel.BONES) do
            local m = ply:GetBoneMatrix(i)
            local t, f, r, u = m:GetTranslation(), m:GetForward(), m:GetRight(), m:GetUp()
            out[b[1]] = { t.x, t.y, t.z, f.x, f.y, f.z, -r.x, -r.y, -r.z, u.x, u.y, u.z }
        end
        draw()
        shots[#shots + 1] = { label = label, bones = out, drawn = drawn, tubes = tubes, targets = {},
            ent = { 0, 0, 0, 0, 0, 0 }, fwd = { 1, 0, 0 } }
    end
    shot("the idle's arm")
    B.Board.CarryPose(ply)
    shot("the arm brought in")
    io.write(J.encode({ id = ID, pose = "carry", model = #drawn > 0, meshes = meshes, shots = shots, errors = cl.errors }), "\n")
    os.exit(0)
end
if def.worn then
    -- WORN (the skates): the player is the vehicle.
    local ply = cl:player("Skater")
    ply._skel = SR.load("kleiner_standing")
    ply:SetPos(E.Vector(0, 0, 0))
    ply._eyeAngles = E.Angle(0, 0, 0)
    ply:SetNWString("BMXWorn", ID)
    cl.localPlayer = sv:player("Looker")
    cl.eyePos = E.Vector(100, 100, 50)
    world.dt = VIDEO and 1 / FPS or 1 / 30
    local shots = {}
    local recording, phaseLabel = false, ""
    local record
    local function frame()
        world.time = world.time + world.dt
        -- (video: the skater travels at their speed, and the view stays with them)
        if recording then
            ply:SetPos(ply:GetPos() + ply._vel * world.dt)
            cl.eyePos = ply:GetPos() + E.Vector(100, 100, 50)
        end
        drawn, tubes = {}, {}
        E.hook.Run("PrePlayerDraw", ply)
        E.hook.Run("PostPlayerDraw", ply)
        if recording then record() end
    end
    local function bones(p)
        p:InvalidateBoneCache(); p:SetupBones()
        local out = {}
        for i, b in ipairs(p._skel.BONES) do
            local m = p:GetBoneMatrix(i)
            local t, f, r, u = m:GetTranslation(), m:GetForward(), m:GetRight(), m:GetUp()
            out[b[1]] = { t.x, t.y, t.z, f.x, f.y, f.z, -r.x, -r.y, -r.z, u.x, u.y, u.z }
        end
        return out
    end
    local function shot(label)
        if VIDEO then phaseLabel = label return end
        shots[#shots + 1] = { label = label, bones = bones(ply), drawn = drawn, tubes = tubes, targets = {},
            ent = { 0, 0, 0, 0, 0, 0 }, fwd = { 1, 0, 0 } }
    end
    local t0 = 0
    record = function()
        local p = ply:GetPos()
        shots[#shots + 1] = { label = phaseLabel, phase = phaseLabel, t = world.time - t0, bones = bones(ply),
            drawn = drawn, tubes = tubes, targets = {}, ent = { p.x, p.y, p.z, 0, 0, 0 }, fwd = { 1, 0, 0 },
            st = { v = ply._vel:Length(), z = 0, grounded = true } }
    end
    ply._vel = E.Vector(0, 0, 0)
    for _ = 1, 8000 do frame() if #drawn > 0 then break end end      -- (the boots' model builds)
    -- (t0 one frame on: the clock moves before a frame is drawn, and the first is t = 0)
    if VIDEO then recording, t0, phaseLabel = true, world.time + world.dt, "standing still" end
    for _ = 1, 20 do frame() end
    shot("standing still")
    ply._vel = E.Vector(250, 0, 0)
    for _ = 1, 20 do frame() end
    shot("rolling")
    for i = 1, 30 do
        ply:SetNWFloat("BMXSkatePhase", (i / 30) * B.Skates.Tune.strideInterval)
        ply:SetNWInt("BMXSkateFoot", 1)
        frame()
        if i == 8 or i == 16 or i == 24 then shot(string.format("stride L %.2f", i / 30)) end
    end
    for i = 1, 30 do
        ply:SetNWFloat("BMXSkatePhase", (i / 30) * B.Skates.Tune.strideInterval)
        ply:SetNWInt("BMXSkateFoot", -1)
        frame()
        if i == 16 then shot("stride R .53") end
    end
    ply:SetNWFloat("BMXSkatePhase", -1)
    for _ = 1, 20 do frame() end
    shot("rolling again")
    io.write(J.encode({ id = ID, pose = "skates", model = true, meshes = meshes, shots = shots, errors = cl.errors,
        video = VIDEO and { fps = FPS, ground = world.groundZ or 0 } or nil }), "\n")
    os.exit(0)
end
local standing = def.pose == "board" or def.pose == "scooter" or def.pose == "skates"
local ent = cl:clientEntity(B.ClassFor(ID))
ent:SetPos(E.Vector(0, 0, standing and (ID == "skateboard" and 1.3 or 3) or F.restHeight(sv)))
ent:SetGrounded(true)
if ent.SetPedalling then ent:SetPedalling(true) end
if ent.SetPushPhase then ent:SetPushPhase(-1) end
local ply = cl:player("Rider")
ply._skel = SR.load(standing and "kleiner_standing" or "kleiner_seated")
ply._vehicle = seatPod(ent, B.SeatFor(ent:Bike(), ent:Cfg(), "rider"))
ent:SetPod(ply._vehicle)
ent:SetDriver(ply)
-- A PASSENGER (STUDIO_PAX=1): on the pegs, or a tandem's stoker.
local pax
if os.getenv("STUDIO_PAX") == "1" and B.HasSeat(ent:Bike(), "pegs") then
    pax = cl:player("Pax")
    pax._skel = SR.load("kleiner_seated")
    pax._vehicle = seatPod(ent, B.SeatFor(ent:Bike(), ent:Cfg(), "pegs"))
    ent._nw.PaxPegs = pax
end
cl.localPlayer = sv:player("Looker")
cl.eyePos = ent:GetPos() + E.Vector(0, 150, 50)
world.dt = VIDEO and 1 / FPS or 1 / 30

local crank = 0
local useCrank = false
ent.CrankAngle = function() return crank end

-- (video: `record` writes the frame just drawn, once the scenario has begun)
local recording, phaseLabel, record = false, "", nil
local function frame()
    world.time = world.time + world.dt
    drawn, tubes = {}, {}
    MF.draw(cl, ent)
    E.hook.Run("PrePlayerDraw", ply)
    if pax then E.hook.Run("PrePlayerDraw", pax) end
    if recording then record() end
end

local function bones(p)
    p:InvalidateBoneCache(); p:SetupBones()
    local out = {}
    for i, b in ipairs(p._skel.BONES) do
        local m = p:GetBoneMatrix(i)
        local t, f, r, u = m:GetTranslation(), m:GetForward(), m:GetRight(), m:GetUp()
        out[b[1]] = { t.x, t.y, t.z, f.x, f.y, f.z, -r.x, -r.y, -r.z, u.x, u.y, u.z }
    end
    return out
end

local shots = {}
local okRun, err = true, nil
local function shot(label)
    -- In video mode every frame is a shot already; a label names what follows.
    if VIDEO then phaseLabel = label return end
    local tg = {}
    for k, v in pairs(ent.ikTargets or {}) do
        if type(v) == "table" and v.x then tg[k] = { v.x, v.y, v.z } end
    end
    local pos, ang = ent:GetPos(), ent:GetAngles()
    shots[#shots + 1] = { label = label, bones = bones(ply), drawn = drawn, tubes = tubes, targets = tg,
        reach = { lean = ply.bmxSpineLean, shown = ply.bmxSpineLeanShown, twist = ply.bmxSpineTwist },
        paxBones = pax and bones(pax) or nil,
        ent = { pos.x, pos.y, pos.z, ang.p, ang.y, ang.r },
        fwd = { ent:GetForward().x, ent:GetForward().y, ent:GetForward().z } }
end

-- ONE VIDEO FRAME: the shot above, with when it is in the scenario, the phase it is
-- in, and what the label strip prints (speed along the ground, the vehicle's height
-- over where it stood at the start, whether it is down). The IK's targets go too, so
-- a foot that drifts off its bolt can be measured frame by frame.
local t0, restZ = 0, ent:GetPos().z
record = function()
    local tg = {}
    for k, v in pairs(ent.ikTargets or {}) do
        if type(v) == "table" and v.x then tg[k] = { v.x, v.y, v.z } end
    end
    local pos, ang, vel = ent:GetPos(), ent:GetAngles(), ent:GetVelocity()
    local f = ent:GetForward()
    shots[#shots + 1] = { label = phaseLabel, phase = phaseLabel, t = world.time - t0,
        bones = bones(ply), drawn = drawn, tubes = tubes, targets = tg,
        paxBones = pax and bones(pax) or nil,
        ent = { pos.x, pos.y, pos.z, ang.p, ang.y, ang.r }, fwd = { f.x, f.y, f.z },
        st = { v = math.sqrt(vel.x * vel.x + vel.y * vel.y), z = pos.z - restZ, grounded = ent:GetGrounded() } }
end

-- SCENARIOS --------------------------------------------------------------
local PI = math.pi
local S = {}
local function run(n, fn) for i = 1, n do if fn then fn(i) end frame() end end
local function setSpeed(v)
    ent._vel = ent:GetForward() * v
    if ent.SetSpeedUPS then ent:SetSpeedUPS(math.abs(v)) end
end
local function flags(t) ent:SetBoardFlags(B.Board.PackFlags(t)) end
-- (the shim does not carry children with a parent: the seat goes up with the board)
local function lift(dz)
    local d = E.Vector(0, 0, dz)
    ent:SetPos(ent:GetPos() + d)
    ply._vehicle:SetPos(ply._vehicle:GetPos() + d)
end

S.board = function()
    local Bd = B.Board
    -- STUDIO_GOOFY=1: the right foot forward; STUDIO_FAKIE=1: rolling tail first.
    local base = { goofy = os.getenv("STUDIO_GOOFY") == "1" or nil, fakie = os.getenv("STUDIO_FAKIE") == "1" or nil }
    local function flags(t)
        local u = { goofy = base.goofy, fakie = base.fakie }
        for k, v in pairs(t) do u[k] = v end
        ent:SetBoardFlags(Bd.PackFlags(u))
    end
    flags({})
    -- (the server turns a goofy rider's seat round: sv_board.lua, B.Tune.seatYaw)
    if base.goofy then ply._vehicle:SetAngles(ent:LocalToWorldAngles(E.Angle(0, Bd.Tune.seatYaw.goofy, 0))) end
    setSpeed(base.fakie and -220 or 220)
    run(30)
    shot("cruise")
    -- pushes: a phase through a second
    for i = 1, 40 do
        local ph = (i / 30) % 1
        ent:SetPushPhase(ph < 0.95 and ph or -1)
        frame()
        if i == 6 or i == 12 or i == 18 or i == 24 then shot(string.format("push %.2f", ph)) end
    end
    ent:SetPushPhase(-1)
    run(45)
    shot("after push")
    ent:SetBoardLean(0.3) run(20) shot("carve +0.3")
    ent:SetBoardLean(-0.3) run(20) shot("carve -0.3")
    ent:SetBoardLean(0) run(15)
    for i = 1, 12 do ent:SetCrouch(math.min(1, i / 10)) frame() end
    shot("crouch")
    ent:SetCrouch(0)
    ent:SetGrounded(false)
    lift(18)
    run(2) shot("ollie pop")
    run(5) shot("ollie air .23")
    ent:SetTrickBits(B.PoseIDs.indy * 65536)
    run(9) shot("indy grab")
    ent:SetTrickBits(0)
    run(9)
    ent:SetGrounded(true)
    lift(-18)
    run(30)
    flags({ meter = true, manual = true })
    for i = 1, 20 do ent:SetMeter(math.sin(i / 6) * 0.7) frame() end
    shot("manual")
    flags({})
    run(20)
    shot("cruise again")
end

-- A scooter leant into a turn and steered, kicking, and the hop after: the vehicle
-- and its seat turned and rolled together (`place`), as the game's parenting does.
S.scooter_turn = function()
    local seat = B.SeatFor(ent:Bike(), ent:Cfg(), "rider")
    local base = ent:GetPos()
    local function place(roll, yaw)
        ent:SetAngles(E.Angle(0, yaw, roll))
        ply._vehicle:SetPos(ent:LocalToWorld(seat.offset))
        ply._vehicle:SetAngles(ent:LocalToWorldAngles(seat.angles or E.Angle(0, 0, 0)))
    end
    setSpeed(250)
    run(30)
    local yaw = 0
    for i = 1, 40 do
        local k = math.min(1, i / 10)
        yaw = yaw + 60 * world.dt * k
        place(-18 * k, yaw)
        ent:SetSteer(math.rad(14 * k))
        ent:SetPushPhase(((i / 30) % 1) < 0.95 and ((i / 30) % 1) or -1)
        setSpeed(250)
        frame()
        if i == 12 or i == 24 or i == 36 then shot("turning " .. i) end
    end
    ent:SetPushPhase(-1)
    place(0, yaw) ent:SetSteer(0) run(20) shot("after the turn")
end

S.scooter = function()
    setSpeed(200)
    run(30)
    shot("cruise")
    for i = 1, 40 do
        local ph = (i / 30) % 1
        ent:SetPushPhase(ph < 0.95 and ph or -1)
        frame()
        if i == 6 or i == 12 or i == 18 or i == 24 then shot(string.format("kick %.2f", ph)) end
    end
    ent:SetPushPhase(-1)
    run(30)
    ent:SetSteer(math.rad(30)) run(20) shot("steer 30")
    ent:SetSteer(0) run(10)
    ent:SetHopCharge(1) run(15) shot("hop crouch")
    ent:SetHopCharge(0)
    ent:SetGrounded(false) lift(14) run(8) shot("air")
    ent:SetGrounded(true) lift(-14) run(20)
    shot("cruise again")
end

S.styles = function()
    setSpeed(150)
    run(30)
    ent:SetGrounded(false)
    lift(20)
    for _, name in ipairs({ "nohander", "nofooter", "cancan_r", "superman", "nothing", "xup", "turndown", "tabletop" }) do
        if B.PoseIDs[name] then
            ent:SetTrickBits(B.PoseIDs[name] * 65536)
            run(12)
            shot(name)
            ent:SetTrickBits(0)
            run(10)
        end
    end
end

S.flips = function()
    local Bd = B.Board
    setSpeed(220)
    run(30)
    for _, trick in ipairs({ { "kickflip", 1, 0 }, { "shove-it", 0, 1 } }) do
        for i = 1, 12 do ent:SetCrouch(math.min(1, i / 10)) frame() end
        ent:SetCrouch(0)
        ent:SetGrounded(false)
        lift(16)
        local n = 14
        for i = 1, n do
            local a = (i / n) * 2 * math.pi
            ent:SetBoardBits(Bd.PackBits(trick[2] * a, trick[3] * (a / 2), 0))
            frame()
            if i == 4 or i == 7 or i == 10 then shot(string.format("%s %d%%", trick[1], math.floor(i / n * 100))) end
        end
        ent:SetBoardBits(0)
        run(4)
        ent:SetGrounded(true)
        lift(-16)
        run(20)
    end
end

-- A pedal stroke: a shot every eighth of a turn (the knees' tracking, the ankles).
S.stroke = function()
    local function pedal(n) for _ = 1, n do crank = crank + 7 * world.dt frame() end end
    setSpeed(150)
    pedal(40)
    local start = crank
    for i = 0, 7 do
        local to = start + i * math.pi / 4
        while crank < to do crank = math.min(to, crank + 7 * world.dt) frame() end
        shot(string.format("crank %d", i * 45))
    end
end

S.bike = function()
    useCrank = true
    local function pedal(n, rate)
        for i = 1, n do crank = crank + (rate or 7) * world.dt frame() end
    end
    setSpeed(150)
    pedal(40)
    for i = 0, 3 do pedal(4) shot("seated crank " .. i) end
    ply:SetNWInt("BMXStance", B.RiderStanceId and B.RiderStanceId.attack or 3)
    pedal(30)
    shot("attack")
    ply:SetNWInt("BMXStance", B.RiderStanceId and B.RiderStanceId.standing or 2)
    pedal(30)
    shot("standing")
    ply:SetNWInt("BMXStance", 1)
    ent:SetSteer(math.rad(35))
    pedal(30) shot("full lock")
    ent:SetSteer(0)
    pedal(20)
    ent:SetHopCharge(1) pedal(15) shot("hop crouch")
    ent:SetHopCharge(0)
    pedal(20)
    if B.PoseIDs and B.PoseIDs.nohander then
        ent:SetGrounded(false)
        ent:SetTrickBits(B.PoseIDs.nohander * 65536) pedal(12) shot("nohander")
        ent:SetTrickBits(0) pedal(12)
        ent:SetGrounded(true)
    end
end

--------------------------------------------------------------------------
-- THE VIDEO SCENARIOS (`*_session`): a ride, not a set of poses.
--
-- The scenarios above were written for stills: a board that "ollies" is lifted 18
-- units in one frame and put down again, nothing travels, and a phase lasts as
-- many frames as made a good picture. On film every one of those is a pop. These
-- drive the vehicle the way the server would, from the server's own numbers:
--
--   * it TRAVELS: its position advances every frame at its speed along its
--     heading, and the seat goes with it (the shim does not carry a child with its
--     parent, so `place` moves the pod, as `lift` does), so the ground passes
--     under the wheels and a camera can follow;
--   * a push is the server's (Board.PushStep / PushPhaseOf: a kick every
--     kickInterval, its speed added over kickTime, less of it the faster it goes),
--     so the push phase on the wire and the speed it gives agree;
--   * a board's carve is the deck's lean spring (LeanStep) and the trucks' steer
--     (TruckSteer), and it turns by what the trucks steer; a scooter leans and
--     turns as a single-track vehicle does (tan(roll) = v^2 / (g R)), with the
--     bars at the balance's derived steer;
--   * an air is a parabola under the world's gravity, from the speed the server's
--     pop gives (PopHeight / PopSpeed from how long the crouch was held, or
--     Hop.popSpeed times the charge), with the nose-up kick the server adds and
--     the attitude hold bringing it level, the nose turning about the back axle;
--     the vehicle's velocity is set, so the knee-soak on landing (cl_rider.lua,
--     bmxLandHit) sees how hard it came down;
--   * every phase is in SECONDS (`R.hold`), so the timing reads as a rider's and
--     does not change with the frame rate.
--
-- What it is not is the physics: no suspension, no tyre slip, no bumps. The
-- vehicle goes where the script says, and what is judged is the rider on it.
-- `still` marks the moments a contact sheet of the session shows (studio.sh with
-- a session, no video); `phase` names what the label strip prints.
--------------------------------------------------------------------------
local function phase(s) phaseLabel = s end
local function still(s) if not VIDEO then shot(s) end end

local function rig(o)
    o = o or {}
    local seat = B.SeatFor(ent:Bike(), ent:Cfg(), "rider")
    local seatAng = o.seatAngles or seat.angles or E.Angle(0, 0, 0)
    local paxSeat = pax and B.SeatFor(ent:Bike(), ent:Cfg(), "pegs")
    local start = ent:GetPos()
    local gz = world.groundZ or 0
    local h = start.z - gz                  -- the origin over the ground: the axle line
    local half = ent:Cfg().Wheel.wheelbase * 0.5
    local R = {
        x = start.x, y = start.y, z = 0, vz = 0, air = false,     -- z: off the ground
        v = o.speed or 0, yaw = 0, yawRate = 0,                   -- u/s; degrees, a second
        pitch = 0, pitchRate = 0, pitchTarget = 0, roll = 0,      -- degrees nose up (rad/s); right
        t = 0, g = world.gravity or 600, half = half,
    }
    -- Where the vehicle and its seats are. A roll turns it about the line its tyres
    -- touch the ground on and a pitch about the axle that stays down (the back one
    -- nose up, the front one nose down), as a wheelie or an ollie's pop does, so
    -- neither sinks a wheel into the ground nor lifts it.
    function R.place()
        ent:SetAngles(E.Angle(-R.pitch, R.yaw, R.roll))
        local yr, rr = math.rad(R.yaw), math.rad(R.roll)
        local f0 = E.Vector(math.cos(yr), math.sin(yr), 0)
        local up = E.Vector(math.sin(yr) * math.sin(rr), -math.cos(yr) * math.sin(rr), math.cos(rr))
        local a = (R.pitch > 0 and -half) or (R.pitch < 0 and half) or 0
        local pos = E.Vector(R.x, R.y, gz + R.z) + f0 * a - ent:GetForward() * a + up * h
        ent:SetPos(pos)
        ply._vehicle:SetPos(ent:LocalToWorld(seat.offset))
        ply._vehicle:SetAngles(ent:LocalToWorldAngles(seatAng))
        if pax then
            pax._vehicle:SetPos(ent:LocalToWorld(paxSeat.offset))
            pax._vehicle:SetAngles(ent:LocalToWorldAngles(paxSeat.angles or E.Angle(0, 0, 0)))
        end
        -- (the view goes along: the model's LOD and the rider's IK are measured from it)
        cl.eyePos = pos + E.Vector(0, 150, 50)
    end
    -- One frame: travel, fall, turn the nose (the attitude hold's PD, o.pitchHold
    -- giving its gains), then draw.
    function R.step()
        local dt = world.dt
        R.yaw = R.yaw + R.yawRate * dt
        local yr = math.rad(R.yaw)
        R.x, R.y = R.x + math.cos(yr) * R.v * dt, R.y + math.sin(yr) * R.v * dt
        R.landed = false
        if R.air then
            R.vz = R.vz - R.g * dt
            R.z = R.z + R.vz * dt
            if R.z <= 0 then
                R.z, R.air, R.landed, R.landVz = 0, false, true, R.vz
                ent:SetGrounded(true)
            end
        end
        if o.pitchHold then
            local kp, kd = o.pitchHold(R)
            local th = math.rad(R.pitch)
            R.pitchRate = R.pitchRate + (kp * (math.rad(R.pitchTarget) - th) - kd * R.pitchRate) * dt
            th = th + R.pitchRate * dt
            -- (down, a nose coming level stops on its wheels rather than going through)
            if not R.air and th < 0 and R.pitchTarget >= 0 then th, R.pitchRate = 0, 0 end
            R.pitch = math.deg(th)
        end
        ent._vel = E.Vector(math.cos(yr) * R.v, math.sin(yr) * R.v, R.air and R.vz or 0)
        if ent.SetSpeedUPS then ent:SetSpeedUPS(math.abs(R.v)) end
        R.place()
        R.t = R.t + dt
        frame()
    end
    -- `sec` seconds of frames, `fn(t, k)` (seconds and fraction into it) before each.
    function R.hold(sec, fn)
        local n = math.max(1, math.floor(sec / world.dt + 0.5))
        for i = 1, n do
            if fn then fn((i - 1) * world.dt, (i - 1) / n) end
            R.step()
        end
    end
    -- Frames until it is down again, `fn(t)` (seconds since the pop) before each; the
    -- frame it touches down on is already `landPhase`.
    function R.untilLanded(fn, landPhase)
        local t = 0
        while R.air do
            if fn then fn(t) end
            local dt = world.dt
            if landPhase and R.z + (R.vz - R.g * dt) * dt <= 0 then phase(landPhase) end
            R.step()
            t = t + dt
        end
    end
    -- Off the ground: `vz` up and `fwd` more along it (a pop leans a little forward).
    function R.pop(vz, fwd)
        R.air, R.vz, R.v = true, vz, R.v + (fwd or 0)
        ent:SetGrounded(false)
    end
    R.place()
    return R
end

-- THE SKATEBOARD: about 14 s. Rolled in at a jog's pace, three pushes, a carve each
-- way, an ollie from a 0.3 s crouch, a kickflip from a 0.35 s one, a manual.
S.skate_session = function()
    local Bd = B.Board
    local T = Bd.Tune
    local goofy = os.getenv("STUDIO_GOOFY") == "1" or nil
    local function flags(t)
        local u = { goofy = goofy }
        for k, v in pairs(t) do u[k] = v end
        ent:SetBoardFlags(Bd.PackFlags(u))
    end
    flags({})
    local drive = ent:Bike().drive or {}
    local interval = drive.kickInterval or T.kickInterval
    local wb = ent:Cfg().Wheel.wheelbase
    local manual = false
    local R = rig({
        speed = 110,
        seatAngles = goofy and E.Angle(0, T.seatYaw.goofy, 0) or nil,
        -- the server's pitch hold: hard for a manual (and on the wheels), soft in the air
        pitchHold = function(R)
            if R.air and not manual then return T.levelKp, T.levelKd end
            return T.pitchKp, T.pitchKd
        end,
    })
    local ps, kicks = {}, 0
    local lean, leanRate, leanTarget = 0, 0, 0
    local DRAG = 3                          -- u/s^2: a board on smooth concrete barely slows
    -- What runs every frame whatever the phase: the deck's lean and the turn it
    -- makes, the push cycle, and `fn` for the phase's own.
    local function ride(fn)
        return function(t, k)
            if fn then fn(t, k) end
            for _ = 1, 4 do lean, leanRate = Bd.LeanStep(lean, leanRate, leanTarget, world.dt / 4) end
            ent:SetBoardLean(lean)
            -- both trucks steer, the back one the other way: it turns about the middle
            local steer = Bd.TruckSteer(lean, R.v, wb)
            R.yawRate = -math.deg(2 * R.v * math.tan(steer) / wb)   -- (a lean to the right turns right)
            if R.air then
                ps.phase = interval                                  -- (as the server: no push in the air)
                ent:SetPushPhase(-1)
            else
                local add, began = Bd.PushStep(ps, world.dt, kicks > 0, R.v, drive)
                if began then kicks = kicks - 1 end
                R.v = R.v + add - DRAG * world.dt
                ent:SetPushPhase(Bd.PushPhaseOf(ps, interval))
            end
        end
    end
    -- An ollie (or a flip): the crouch held `held` seconds, the pop the server gives
    -- for it, the flip begun as a player's key would (flipSettle after the pop).
    local function ollie(name, held, flip)
        phase(name .. ": crouch")
        R.hold(held, ride(function(t) ent:SetCrouch(math.min(1, (t + world.dt) / T.crouchMax)) end))
        still(name .. " crouch")
        local v = Bd.PopSpeed(Bd.PopHeight(held), R.g)
        local n = math.sqrt(1 + T.popForward * T.popForward)
        ent:SetCrouch(0)
        R.pop(v / n, v * T.popForward / n)
        R.pitchRate = T.popNoseKick
        phase(name .. ": air")
        local airT = 2 * v / n / R.g
        local mid = false
        R.untilLanded(ride(function(t)
            if flip then
                ent:SetBoardBits(Bd.PackBits(Bd.FlipAngles(Bd.Flips[flip], t - T.flipSettle)))
            end
            if not mid and t >= airT / 2 then mid = true still(name .. " top") end
        end), name .. ": land")
        ent:SetBoardBits(0)
    end

    phase("roll in")
    R.hold(1.0, ride())
    still("roll in")
    phase("push x3")
    kicks = 3
    R.hold(0.25, ride())
    still("push (in the stroke)")
    R.hold(3 * interval - 0.25, ride())
    phase("cruise")
    R.hold(1.0, ride())
    still("cruise")
    phase("carve left")
    leanTarget = -0.25
    R.hold(1.2, ride())
    still("carve left")
    phase("carve right")
    leanTarget = 0.25
    R.hold(1.2, ride())
    still("carve right")
    phase("straighten")
    leanTarget = 0
    R.hold(0.6, ride())
    ollie("ollie", 0.3)
    R.hold(0.6, ride())
    phase("roll")
    R.hold(0.9, ride())
    ollie("kickflip", 0.35, "kickflip")
    R.hold(0.6, ride())
    phase("manual")
    flags({ meter = true, manual = true })
    manual = true
    R.hold(1.6, ride(function(t)
        local m = 0.35 * math.sin(2 * PI * t / 1.3)
        ent:SetMeter(m)
        R.pitchTarget = math.deg(T.manualPitch * (1 + 0.3 * m))
    end))
    still("manual")
    flags({})
    manual = false
    R.pitchTarget = 0
    ent:SetMeter(0)
    phase("roll out")
    R.hold(1.5, ride())
    still("roll out")
end

-- A BMX (or any bike): about 12 s. Pedalled seated, stood up for a sprint, coasted
-- with the cranks level, a full-charge bunny hop, a few strokes, a hop with a style
-- pose. The cranks are the bike's own (ENT:CrankAngle: the rear wheel's turn through
-- the gear, eased level when it coasts), not the studio's stand-in, so the cadence
-- is the one the speed gives.
S.bike_session = function()
    ent.CrankAngle = nil
    local C = ent:Cfg()
    local H = C.Hop
    local ids = B.RiderStanceId or {}
    local function stance(n) ply:SetNWInt("BMXStance", ids[n] or 1) end
    local R = rig({
        speed = 140,
        pitchHold = function(R) if R.air then return 25, 8 end return 60, 13 end,
    })
    -- `acc` is what the legs give; rolling and the air take some back, more the faster
    -- it goes (about 0.3 m/s^2 at 25 km/h), so a coast slows and a sprint levels off.
    local acc = 0
    local function ride(fn)
        return function(t, k)
            if fn then fn(t, k) end
            R.v = math.max(0, R.v + (acc - 4 - R.v * R.v / 9000) * world.dt)
        end
    end
    local function hop(name, pose)
        phase(name .. ": preload")
        R.hold(H.chargeTime, ride(function(t) ent:SetHopCharge(math.min(1, (t + world.dt) / H.chargeTime)) end))
        still(name .. " preload")
        local dv = H.popSpeed * math.max(H.minCharge, 1)
        local n = math.sqrt(1 + H.forwardBias * H.forwardBias)
        ent:SetHopCharge(0)
        R.pop(dv / n, dv * H.forwardBias / n)
        R.pitchRate = H.pitchImpulse
        phase(name .. ": air")
        local airT = 2 * dv / n / R.g
        local mid = false
        R.untilLanded(ride(function(t)
            -- a style pose: in just after the pop, out in time to land on the pedals
            if pose and B.PoseIDs[pose] then
                ent:SetTrickBits((t > 0.08 and t < airT - 0.3) and B.PoseIDs[pose] * 65536 or 0)
            end
            if not mid and t >= airT / 2 then mid = true still(name .. " top") end
        end), name .. ": land")
        ent:SetTrickBits(0)
    end

    ent:SetPedalling(true)
    stance("seated")
    phase("pedal seated")
    acc = 10
    R.hold(3.0, ride())
    still("pedal seated")
    phase("stand + sprint")
    stance("standing")
    ent:SetSprinting(true)
    acc = 35
    R.hold(2.5, ride())
    still("sprint")
    phase("coast")
    ent:SetSprinting(false)
    ent:SetPedalling(false)
    acc = 0
    R.hold(1.5, ride())
    still("coast")
    hop("hop")
    R.hold(0.6, ride())
    phase("pedal")
    stance("seated")
    ent:SetPedalling(true)
    acc = 10
    R.hold(1.0, ride())
    acc = 0
    ent:SetPedalling(false)
    hop("hop + tabletop", "tabletop")
    R.hold(0.6, ride())
    phase("roll out")
    R.hold(1.2, ride())
    still("roll out")
end

-- THE KICK SCOOTER: about 12 s. Rolled in, four kicks, a lean into a turn each way
-- (the bars at the balance's derived steer), a full-charge hop, two kicks, rolled out.
S.scooter_session = function()
    local Bd, SC = B.Board, B.Scooter
    local C = ent:Cfg()
    local H = C.Hop
    local drive = ent:Bike().drive or {}
    local interval = drive.kickInterval or (SC.Tune and SC.Tune.kickInterval) or 0.55
    local wb = C.Wheel.wheelbase
    local R = rig({
        speed = 120,
        pitchHold = function(R) if R.air then return 25, 8 end return 60, 13 end,
    })
    local ps, kicks = {}, 0
    local roll, rollTarget = 0, 0
    local LEAN_RATE = 40                    -- degrees a second into and out of a lean
    local function ride(fn)
        return function(t, k)
            if fn then fn(t, k) end
            roll = roll + math.max(-LEAN_RATE * world.dt, math.min(LEAN_RATE * world.dt, rollTarget - roll))
            R.roll = roll
            local r = math.rad(roll)
            R.yawRate = -math.deg(R.g * math.tan(r) / math.max(R.v, 1))  -- (leant right, it turns right)
            if ent.SetSteer then ent:SetSteer(B.Lean.DerivedSteer(wb, R.g, r, math.max(R.v, 1))) end
            if R.air then
                ps.phase = interval
                ent:SetPushPhase(-1)
            else
                local add, began = Bd.PushStep(ps, world.dt, kicks > 0, R.v, drive)
                if began then kicks = kicks - 1 end
                R.v = R.v + add - 4 * world.dt
                ent:SetPushPhase(Bd.PushPhaseOf(ps, interval))
            end
        end
    end

    phase("roll in")
    R.hold(0.8, ride())
    phase("kick x4")
    kicks = 4
    R.hold(0.25, ride())
    still("kick (in the stroke)")
    R.hold(4 * interval - 0.25, ride())
    phase("cruise")
    R.hold(1.0, ride())
    still("cruise")
    phase("lean left")
    rollTarget = -14
    R.hold(1.4, ride())
    still("lean left")
    phase("lean right")
    rollTarget = 14
    R.hold(1.4, ride())
    still("lean right")
    phase("straighten")
    rollTarget = 0
    R.hold(0.6, ride())
    phase("hop: preload")
    R.hold(H.chargeTime, ride(function(t) ent:SetHopCharge(math.min(1, (t + world.dt) / H.chargeTime)) end))
    still("hop preload")
    local dv = H.popSpeed
    local n = math.sqrt(1 + (H.forwardBias or 0) ^ 2)
    ent:SetHopCharge(0)
    R.pop(dv / n, dv * (H.forwardBias or 0) / n)
    R.pitchRate = H.pitchImpulse or 0
    phase("hop: air")
    local mid = false
    R.untilLanded(ride(function(t) if not mid and t >= dv / n / R.g then mid = true still("hop top") end end),
        "hop: land")
    R.hold(0.6, ride())
    phase("kick x2")
    kicks = 2
    R.hold(2 * interval, ride())
    phase("roll out")
    R.hold(1.2, ride())
    still("roll out")
end

S.rest = function()
    -- the capture as the client drew it: nothing manipulated
    shots[#shots + 1] = { label = "rest (no rider code)", bones = bones(ply), drawn = drawn, tubes = tubes, targets = {},
        ent = { ent:GetPos().x, ent:GetPos().y, ent:GetPos().z, 0, 0, 0 }, fwd = { ent:GetForward().x, ent:GetForward().y, ent:GetForward().z } }
end
local fam = (def.pose == "board" or def.pose == "scooter") and def.pose or "bike"
local ok = MF.ready(cl, ent)
if SCEN == "rest" then drawn, tubes = {}, {} MF.draw(cl, ent) S.rest() else
run(20)
do
    local fn = S[SCEN] or S[fam]
    -- (video: from the scenario's first frame; the model's build and the settling are not filmed)
    -- (t0 one frame on: the clock moves before a frame is drawn, and the first is t = 0,
    -- so a time in the film is the same time in the scenario)
    if VIDEO then recording, t0, restZ = true, world.time + world.dt, ent:GetPos().z end
    okRun, err = pcall(fn)
    recording = false
end
end
io.write(J.encode({ id = ID, pose = def.pose, model = ok, meshes = meshes, shots = shots,
    errors = cl.errors, err = not okRun and tostring(err) or nil,
    video = VIDEO and { fps = FPS, ground = world.groundZ or 0, scenario = SCEN } or nil }), "\n")
