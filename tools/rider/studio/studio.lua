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
    STUDIO_PAX=1 puts a passenger on the pegs (or a tandem's stoker).

    It is the same offline client the suite runs (tests/lib/gmod.lua), so the
    engine's own animation is not here: the base sequence is the capture's frame,
    with the head where the capture's bot was looking. tools/ride/shoot.sh is the
    real client's photograph.
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
    world.dt = 1 / 30
    local shots = {}
    local function frame()
        world.time = world.time + world.dt
        drawn, tubes = {}, {}
        E.hook.Run("PrePlayerDraw", ply)
        E.hook.Run("PostPlayerDraw", ply)
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
        shots[#shots + 1] = { label = label, bones = bones(ply), drawn = drawn, tubes = tubes, targets = {},
            ent = { 0, 0, 0, 0, 0, 0 }, fwd = { 1, 0, 0 } }
    end
    ply._vel = E.Vector(0, 0, 0)
    for _ = 1, 8000 do frame() if #drawn > 0 then break end end      -- (the boots' model builds)
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
    io.write(J.encode({ id = ID, pose = "skates", model = true, meshes = meshes, shots = shots, errors = cl.errors }), "\n")
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
world.dt = 1 / 30

local crank = 0
local useCrank = false
ent.CrankAngle = function() return crank end

local function frame()
    world.time = world.time + world.dt
    drawn, tubes = {}, {}
    MF.draw(cl, ent)
    E.hook.Run("PrePlayerDraw", ply)
    if pax then E.hook.Run("PrePlayerDraw", pax) end
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
    okRun, err = pcall(fn)
end
end
io.write(J.encode({ id = ID, pose = def.pose, model = ok, meshes = meshes, shots = shots,
    errors = cl.errors, err = not okRun and tostring(err) or nil }), "\n")
