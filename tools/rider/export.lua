--[[--------------------------------------------------------------------------
    tools/rider/export.lua

    Every vehicle's RIDER, posed by the real cl_rider.lua through a pedal
    stroke, as JSON -- so the rider's animation can be looked at (and its
    reach checked) without a game client:

        lua5.1 tools/rider/export.lua [ids] [frames] [speed] [stance] > rider.json
        python3 tools/rider/render.py rider.json out/

    ids: comma-separated vehicle ids (stock,road,...) or "all" (the default:
    every vehicle with a rider pose). frames: samples per crank turn, default
    12. speed: 0..1 of the bike's top speed (the tuck grows with it), default 0.
    stance: seated | standing | attack (sh_stance.lua), default seated.

    It boots the client realm of the offline suite (tests/lib/gmod.lua) and
    seats its stand-in skeleton (tests/lib/skeleton.lua: ValveBiped's bones at
    a standard player's lengths) on each bike, exactly as tests/test_rider.lua
    does, then draws the bike and runs the PrePlayerDraw hook frame by frame
    with the cranks turned to each sample. So the IK, the pose set, the stance
    and the bike's own grip and pedal positions are all the shipped code's.
    What it cannot show is a real player model's mesh: the skeleton is a
    stand-in, and a model whose bone axes differ will still want eyes on a
    client (tools/ride/shoot.sh).
----------------------------------------------------------------------------]]

local here = (arg and arg[0] or "tools/rider/export.lua"):match("^(.*)/[^/]*$") or "."
local root = here .. "/../.."
package.path = root .. "/tests/?.lua;" .. package.path

local gmod = require("lib.gmod")
gmod.ROOT = root
_G.T = require("lib.t")
local F  = require("lib.fixture")
local SK = require("lib.skeleton")
local J  = require("lib.json")
local MF = require("lib.meshfake")

local wantIds = arg[1] and arg[1] ~= "" and arg[1] ~= "all" and arg[1] or nil
local FRAMES  = tonumber(arg[2] or "") or 12
local SPEED   = tonumber(arg[3] or "") or 0
local STANCE  = arg[4] or "seated"
local WARMUP, SETTLE = 40, 4

local sv, world = F.server()
local cl = F.client(world)
local E, B = cl.env, cl.env.BMX
-- THE DETAILED MODELS, which is what players see (bmx_bike_model 1): built and
-- "drawn" through the suite's fake mesh API, so the grips and pedals the riders
-- reach for are the models' own. Without it the simple bike of beams stands in,
-- whose grips and pedals are near but not the same, and a tandem's stoker has
-- none at all (they come only from its model).
MF.enable(cl)

local function vec(v) return { v.x, v.y, v.z } end

-- Which vehicles: the ones a rider sits or stands on and is posed for.
local ids = {}
if wantIds then
    for id in wantIds:gmatch("[^,]+") do ids[#ids + 1] = id end
else
    for id, def in pairs(B.Vehicles) do
        if def.pose and not def.worn and not def.hidden then ids[#ids + 1] = id end
    end
    table.sort(ids)
end

local function classOf(id) return id == "stock" and "bmx_base" or ("bmx_" .. id) end

-- The rider seated in the pod, the pod where the bike puts it (test_rider.lua).
local function seat(id)
    local bike = cl:clientEntity(classOf(id))
    bike:SetPos(E.Vector(0, 0, F.restHeight(sv)))
    local pod = cl.makeEntity("prop_vehicle_prisoner_pod")
    pod:SetParent(bike)
    bike:SetPod(pod)
    local ply = cl:player("Rider_" .. id)
    ply._vehicle = pod
    bike:SetDriver(ply)
    -- Where ENT:BuildPod puts it: the seat as the registry resolves it.
    local seat = B.SeatFor(B.Vehicles[id], bike:Cfg(), "rider")
    if seat and seat.offset then pod:SetPos(bike:LocalToWorld(seat.offset)) end
    if seat and seat.angles then pod:SetAngles(bike:LocalToWorldAngles(seat.angles)) end
    return bike, ply, pod
end

-- How far what touches the bike is from where it should be, measured as
-- tests/test_rider.lua measures it: the inside of the fist to the grip it holds,
-- and the pedal to the sole between the ankle and the ball of the foot (over
-- the top of a low saddle's stroke the foot slides forward and the pedal is
-- under the arch, which is still a foot on its pedal). A pose set with open
-- hands (the unicycle's arms out for balance) holds nothing: there the hand
-- itself goes to the target, and a fist's centre is the wrong thing to measure.
local function miss(ply, key, ik, open)
    ply:InvalidateBoneCache(); ply:SetupBones()
    local side = key:sub(1, 1):upper()
    if key:find("Hand") then
        local t = ik[key .. "Held"] or ik[key]
        if t and open then
            local h = ply:LookupBone("ValveBiped.Bip01_" .. side .. "_Hand")
            return h and (ply:GetBoneMatrix(h):GetTranslation() - t):Length()
        end
        local c = t and B.RiderFistCentre and B.RiderFistCentre(ply, side)
        return c and (c - t):Length()
    end
    local t = ik[key]
    local fa = ply:LookupBone("ValveBiped.Bip01_" .. side .. "_Foot")
    local fb = ply:LookupBone("ValveBiped.Bip01_" .. side .. "_Toe0")
    if not (t and fa and fb) then return nil end
    local a = ply:GetBoneMatrix(fa):GetTranslation()
    local g = ply:GetBoneMatrix(fb):GetTranslation() - a
    local s = math.max(0, math.min(1, (t - a):Dot(g) / g:Dot(g)))
    return (a + g * s - t):Length()
end

local function sample(id)
    local bike, ply, pod = seat(id)
    -- A TANDEM'S STOKER: the pegs seat, when it pedals (sh_bikes.lua), posed by
    -- cl_passenger.lua on the bike's second cranks and bars (ikTargetsStoker).
    -- Resolved as the server builds it (BMX.SeatFor fills the angles the
    -- registry leaves out: without them the stoker sat facing the bike's side).
    local pegs = B.SeatFor(B.Vehicles[id], bike:Cfg(), "pegs")
    local stoker, stokerPod
    if pegs and pegs.pedals and pegs.offset then
        stokerPod = cl.makeEntity("prop_vehicle_prisoner_pod")
        stokerPod:SetParent(bike)
        stokerPod:SetPos(bike:LocalToWorld(pegs.offset))
        if pegs.angles then stokerPod:SetAngles(bike:LocalToWorldAngles(pegs.angles)) end
        stoker = cl:player("Stoker_" .. id)
        stoker._vehicle = stokerPod
        bike._nw.PaxPegs = stoker
    end
    local crank = 0
    -- The cranks at each sample, not wherever the rear wheel's spin puts them.
    bike.CrankAngle = function() return crank end
    -- Speed and stance as the network gives them to every client.
    ply:SetNWInt("BMXStance", B.RiderStanceId[STANCE] or 1)
    local top = B.Gears and B.Gears.TopCeiling and B.Gears.TopCeiling(bike, bike:Cfg()) or 0
    local function frame()
        bike:SetSpeedUPS(SPEED * top)
        MF.draw(cl, bike)
        E.hook.Run("PrePlayerDraw", ply)
        if stoker then E.hook.Run("PrePlayerDraw", stoker) end
    end
    local model = MF.ready(cl, bike)
    for _ = 1, WARMUP do frame() end
    local set = B.PoseSetFor and B.PoseSetFor(bike) or {}

    -- The wheels where cl_init.lua draws them at rest: the axle line lifted
    -- by the static sag.
    local C, WC = bike:Cfg(), bike:Cfg().Wheel
    local sag = math.max(0, math.min(WC.restLength,
        C.Chassis.mass * world.gravity * 0.5 / WC.spring))
    local half = WC.wheelbase * 0.5
    local out = {
        id = id, pose = B.Vehicles[id] and B.Vehicles[id].pose or "?",
        name = B.Vehicles[id] and B.Vehicles[id].printName or id,
        wheelbase = WC.wheelbase, radius = WC.radius,
        frontRadius = WC.frontRadius or WC.radius,
        front = vec(bike:LocalToWorld(E.Vector(half, 0, sag))),
        rear = vec(bike:LocalToWorld(E.Vector(-half, 0, sag))),
        ground = world.groundZ,
        origin = vec(bike:GetPos()), seat = vec(pod:GetPos()),
        stokerSeat = stokerPod and vec(stokerPod:GetPos()) or nil,
        model = model,         -- false: drawn as the simple bike (no model of its own)
        frames = {},
    }
    -- One rider's bones, the targets they were given, and how far each hand and
    -- foot is from its own.
    local function snapshot(p, ik, open)
        p:InvalidateBoneCache(); p:SetupBones()
        local bones = {}
        for _, b in ipairs(SK.BONES) do
            local bi = p:LookupBone(b[1])
            if bi then bones[b[1]:gsub("^ValveBiped%.Bip01_", "")] = vec(p:GetBoneMatrix(bi):GetTranslation()) end
        end
        local targets, reach = {}, {}
        for k, v in pairs(ik or {}) do
            if type(v) == "table" and v.x then targets[k] = vec(v) end
        end
        for _, k in ipairs({ "rHand", "lHand", "rFoot", "lFoot" }) do
            reach[k] = ik and miss(p, k, ik, open)
        end
        return bones, targets, reach
    end
    for i = 0, FRAMES - 1 do
        crank = i / FRAMES * 2 * math.pi
        for _ = 1, SETTLE do frame() end
        local bones, targets, reach = snapshot(ply, bike.ikTargets, set.openHands)
        local f = { crank = math.deg(crank), bones = bones, targets = targets, reach = reach }
        if stoker then
            local sb, st, sr = snapshot(stoker, bike.ikTargetsStoker, false)
            f.stoker = { bones = sb, targets = st, reach = sr }
        end
        out.frames[#out.frames + 1] = f
    end
    return out
end

local result = { frames = FRAMES, speed = SPEED, stance = STANCE,
                 parents = {}, vehicles = {}, errors = {} }
for _, b in ipairs(SK.BONES) do
    if b[2] then
        result.parents[b[1]:gsub("^ValveBiped%.Bip01_", "")] = b[2]:gsub("^ValveBiped%.Bip01_", "")
    end
end
for _, id in ipairs(ids) do
    local ok, res = pcall(sample, id)
    if ok then result.vehicles[#result.vehicles + 1] = res
    else result.errors[id] = tostring(res) end
end
io.write(J.encode(result), "\n")
