--[[--------------------------------------------------------------------------
    DOES THE RIDER GO THROUGH THE BIKE? Every vehicle a player rides, ridden by
    kleiner's real skeleton (lib/skeleton_real.lua) through its motion -- a bike's
    whole pedal stroke seated, standing and in the attack stance, full lock both ways,
    the hop's crouch, a landing, every style pose; the board's pushes, carves, ollie,
    grabs, manuals and flips, regular and goofy; the scooter's kicks; the skates'
    strides -- and at each shot every part of the body checked against every triangle
    the vehicle was drawn with that frame, and against every part of the body it does
    not join (and the passenger's, the stoker's).

    HOW. The body is kleiner's own, as capsules (tools/rider/studio/capsules.py measures
    them off his mesh: tests/data/body_capsules_kleiner.lua), posed on the skeleton the
    shipped cl_rider.lua (cl_board.lua, cl_scooter.lua, cl_skates.lua, cl_passenger.lua)
    posed. The vehicle is the model it builds (cl_geo_*.lua), every triangle recorded as
    the fake mesh builds it and every group drawn with its matrix (lib/bodyclip.lua's
    recorder). The distance between a capsule and a triangle is exact: a deck is two
    big triangles, and a shin through one has no vertex anywhere near it.

    WHAT IS ALLOWED. A fist is round its grip, a foot on its pedal or peg, the hips on
    their own saddle, a passenger's hands on the rider's shoulders, a skate's boot on
    its own foot (bodyclip.lua's BC.ALLOW and BC.CROSS_ALLOW, each with why).
    Everything else that goes in further than the tolerance is a clip.

    THE TOLERANCES. Each capsule sits a little inside the skin (the radius is the 20th
    percentile of its skin's distance from its bones), but not everywhere: where the
    skin is thinnest it stands proud of it, by `out` (the 95th percentile of how far it
    stands out; 0.65 at the most, the top of the chest). So:
      TOL_VEHICLE 0.75   a surface 0.75 into a capsule is inside the skin, not on it,
                         wherever on the capsule it is (asserted below: every `out` is
                         under it).
      TOL_BODY    1.0    two capsules, each standing out a little where they meet: two
                         skins touching can read as much as the two `out`s together. A
                         unit in, they are through each other.

    TODAY'S CLIPS. The animation has many (the style poses especially): KNOWN lists
    each, as "who part into what" and how deep at worst, and the test holds the line --
    a clip not in KNOWN, or deeper than KNOWN says by more than MARGIN, fails; one gone
    is printed. KNOWN is tests/data/body_clip_known.lua, written by BMX_CLIP_REPORT=1
    for the vehicles that run (so a fix is a diff of that file). BMX_CLIP_STRICT=1
    fails on every clip, known or not: the goal.
    BMX_CLIP_DUMP=1 prints every contact, under the tolerance too. BMX_CLIP_SHOTS=dir
    writes each vehicle's shots as tools/rider/studio/studio.lua does, so render.py
    draws kleiner's mesh where the test saw him:

        BMX_CLIP_SHOTS=/tmp/s tools/run-tests.sh "body clip: stock"
        python3 tools/rider/studio/render.py /tmp/s/stock.json out.png "superman,tabletop"

    COST. Not the model builds (a second or two each) and not the clipping (10 ms a body
    a shot, on a grid of each mesh's triangles): the riders. A frame here is a full IK
    solve on 69 bones in plain Lua, 50 to 90 ms a rider (the shim re-poses the whole
    skeleton a dozen and a half times a solve), and a passenger doubles it. The motion is
    stepped a tenth of a second a frame wherever the body only has to settle, and a
    vehicle takes 3 to 17 seconds: the file about 3 1/4 minutes (194 s, 2026-10-22), at
    most 750 MB. One vehicle: tools/run-tests.sh "body clip: stock".
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local MF = require("lib.meshfake")
local SR = require("lib.skeleton_real")
local BC = require("lib.bodyclip")

local PI = math.pi
local sqrt = math.sqrt
local TOL_VEHICLE = 0.75
local TOL_BODY = 1.0
local MARGIN = 0.1           -- a known clip deeper than KNOWN by more than this fails
local DUMP = os.getenv("BMX_CLIP_DUMP") == "1"
local REPORT = os.getenv("BMX_CLIP_REPORT") == "1"
local STRICT = os.getenv("BMX_CLIP_STRICT") == "1"
local EXPORT = os.getenv("BMX_CLIP_SHOTS")

--------------------------------------------------------------------------
-- KNOWN CLIPS: tests/data/body_clip_known.lua, what each vehicle's riders go into today,
-- how deep at worst (units) and the shot it was worst in. GENERATED: BMX_CLIP_REPORT=1
-- writes each vehicle it runs back into it (the rest kept), so after a fix
--     BMX_CLIP_REPORT=1 tools/run-tests.sh "body clip: stock"
-- and the diff of that file is what the fix did.
--------------------------------------------------------------------------
local KNOWN_FILE = "tests/data/body_clip_known.lua"
local KNOWN = (function()
    local f = loadfile(KNOWN_FILE)
    return f and f() or {}
end)()

local function writeKnown()
    local names = {}
    for name in pairs(KNOWN) do names[#names + 1] = name end
    table.sort(names)
    local out = {
        "-- Today's clips: every (who, body part, what it goes into) deeper than the tolerance,",
        "-- per vehicle, the deepest it went (units) and the shot it went deepest in.",
        "-- GENERATED by tests/test_body_clip.lua (BMX_CLIP_REPORT=1): run it again rather than",
        "-- editing this. A vehicle's riders may clip as deep as listed here and no deeper; a fixed",
        "-- clip drops out when its vehicle is run again.",
        "return {",
    }
    for _, name in ipairs(names) do
        out[#out + 1] = string.format("    [%q] = {", name)
        local rows = {}
        for key, v in pairs(KNOWN[name]) do rows[#rows + 1] = { key = key, v = v } end
        table.sort(rows, function(a, b) return a.v.depth > b.v.depth or (a.v.depth == b.v.depth and a.key < b.key) end)
        for _, r in ipairs(rows) do
            out[#out + 1] = string.format("        [%q] = { depth = %.2f, at = %q },", r.key, r.v.depth, r.v.at)
        end
        out[#out + 1] = "    },"
    end
    out[#out + 1] = "}"
    local fh = assert(io.open(KNOWN_FILE, "w"))
    fh:write(table.concat(out, "\n"), "\n")
    fh:close()
end

--------------------------------------------------------------------------
-- THE GEOMETRY ITSELF
--------------------------------------------------------------------------
local function segTri(p, q, a, b, c)
    return sqrt(BC.segTri2(p[1], p[2], p[3], q[1], q[2], q[3], a[1], a[2], a[3], b[1], b[2], b[3], c[1], c[2], c[3]))
end
local function segSeg(p, q, a, b)
    return sqrt(BC.segSeg2(p[1], p[2], p[3], q[1], q[2], q[3], a[1], a[2], a[3], b[1], b[2], b[3]))
end
local function ptTri(p, a, b, c)
    return sqrt(BC.pointTri2(p[1], p[2], p[3], a[1], a[2], a[3], b[1], b[2], b[3], c[1], c[2], c[3]))
end

T.test("body clip: the exact distances, on cases worked by hand", function()
    local A, B, C = { 0, 0, 0 }, { 10, 0, 0 }, { 0, 10, 0 }
    T.near(segTri({ 2, 2, -5 }, { 2, 2, 5 }, A, B, C), 0, 1e-12, "a segment through the middle of a triangle")
    T.near(segTri({ 1, 1, 3 }, { 4, 4, 3 }, A, B, C), 3, 1e-12, "parallel to it, 3 over its inside")
    T.near(segTri({ 1, 1, -3 }, { 4, 4, -3 }, A, B, C), 3, 1e-12, "...and 3 under it")
    T.near(segTri({ -2, 3, -1 }, { -2, 3, 1 }, A, B, C), 2, 1e-12, "beside an edge, crossing its plane")
    T.near(segTri({ 12, -1, -1 }, { 12, -1, 1 }, A, B, C), sqrt(5), 1e-12, "off a corner")
    T.near(segTri({ 4, 4, 1 }, { 9, 9, 1 }, A, B, C), 1, 1e-12, "running out past the long edge, 1 over it")
    T.near(segTri({ 3, 3, 2 }, { 3, 3, 2 }, A, B, C), 2, 1e-12, "a segment that is a point")
    T.near(segTri({ 0, 0, 1 }, { 0, 0, 2 }, { 0, 0, 0 }, { 1, 0, 0 }, { 2, 0, 0 }), 1, 1e-12,
        "a triangle with no area is its edges")
    -- THE DECK: one big triangle, a shin straight through it, neither end of either
    -- anywhere near the other's corners. A vertex test sees nothing.
    local d1, d2, d3 = { -16, -4, 0 }, { 16, -4, 0 }, { 16, 4, 0 }
    T.near(segTri({ 6, -1, -9 }, { 6, -1, 9 }, d1, d2, d3), 0, 1e-12, "a shin through the middle of a deck")
    T.near(segTri({ 6, -1, 0.5 }, { 6, -1, 9 }, d1, d2, d3), 0.5, 1e-12, "a shin stood half a unit over it")
    T.near(segSeg({ 0, 0, 0 }, { 10, 0, 0 }, { 0, 2, 0 }, { 10, 2, 0 }), 2, 1e-12, "parallel segments 2 apart")
    T.near(segSeg({ 0, 0, 0 }, { 10, 0, 0 }, { 5, -5, 3 }, { 5, 5, 3 }), 3, 1e-12, "skew, 3 apart where they cross")
    T.near(segSeg({ 0, 0, 0 }, { 10, 0, 0 }, { 5, -5, 0 }, { 5, 5, 0 }), 0, 1e-12, "crossing")
    T.near(segSeg({ 0, 0, 0 }, { 1, 0, 0 }, { 3, 0, 0 }, { 5, 0, 0 }), 2, 1e-12, "in line with a gap of 2")
    T.near(segSeg({ 0, 0, 0 }, { 4, 0, 0 }, { 2, 1, 0 }, { 6, 1, 0 }), 1, 1e-12, "parallel and overlapping")
    T.near(segSeg({ 1, 1, 1 }, { 1, 1, 1 }, { 4, 5, 1 }, { 4, 5, 1 }), 5, 1e-12, "two points")
end)

T.test("body clip: the exact distances never claim more room than a brute-force search finds, nor much less", function()
    math.randomseed(11)
    local function rnd() return { math.random() * 20 - 10, math.random() * 20 - 10, math.random() * 20 - 10 } end
    local K = 400
    for n = 1, 300 do
        local p, q, a, b, c = rnd(), rnd(), rnd(), rnd(), rnd()
        local exact = segTri(p, q, a, b, c)
        -- the segment walked in K steps, each point's exact distance to the triangle
        local best = math.huge
        for i = 0, K do
            local t = i / K
            best = math.min(best, ptTri({ p[1] + (q[1] - p[1]) * t, p[2] + (q[2] - p[2]) * t, p[3] + (q[3] - p[3]) * t }, a, b, c))
        end
        local step = sqrt((q[1] - p[1]) ^ 2 + (q[2] - p[2]) ^ 2 + (q[3] - p[3]) ^ 2) / K
        T.ok(exact <= best + 1e-9, string.format("case %d: the exact %.4f is no more than the search's %.4f", n, exact, best))
        T.ok(best - exact <= step / 2 + 1e-9, string.format("case %d: the search %.4f within half a step of the exact %.4f", n, best, exact))
        -- and a point to the triangle against points spread over the triangle
        local x = rnd()
        local pt = ptTri(x, a, b, c)
        local over = math.huge
        for i = 0, 40 do
            for j = 0, 40 - i do
                local u, v = i / 40, j / 40
                local y = { a[1] + (b[1] - a[1]) * u + (c[1] - a[1]) * v, a[2] + (b[2] - a[2]) * u + (c[2] - a[2]) * v,
                            a[3] + (b[3] - a[3]) * u + (c[3] - a[3]) * v }
                over = math.min(over, sqrt((x[1] - y[1]) ^ 2 + (x[2] - y[2]) ^ 2 + (x[3] - y[3]) ^ 2))
            end
        end
        T.ok(pt <= over + 1e-9, string.format("case %d: a point's exact distance %.4f is no more than any of the triangle's points' %.4f", n, pt, over))
    end
end)

T.test("body clip: the grid finds the same deepest triangle as looking at every one", function()
    -- A made-up model: 1500 small triangles in a box, and two big ones across it (a deck).
    math.randomseed(5)
    local flat = {}
    local function tri(a, b, c)
        for _, v in ipairs({ a, b, c }) do flat[#flat + 1], flat[#flat + 1], flat[#flat + 1] = v[1], v[2], v[3] end
    end
    for _ = 1, 1500 do
        local o = { math.random() * 40 - 20, math.random() * 20 - 10, math.random() * 30 }
        local function near() return { o[1] + math.random() * 3 - 1.5, o[2] + math.random() * 3 - 1.5, o[3] + math.random() * 3 - 1.5 } end
        tri(o, near(), near())
    end
    tri({ -20, -8, 12 }, { 20, -8, 12 }, { 20, 8, 12.5 })
    tri({ -20, -8, 12 }, { 20, 8, 12.5 }, { -20, 8, 12.5 })
    local rec = BC.fromStudio({ meshes = { flat } })
    local g = rec:grid(1)
    local n = #flat / 9
    for k = 1, 300 do
        local p = { math.random() * 44 - 22, math.random() * 24 - 12, math.random() * 34 - 2 }
        local q = { p[1] + math.random() * 16 - 8, p[2] + math.random() * 16 - 8, p[3] + math.random() * 16 - 8 }
        local r = 0.5 + math.random() * 5
        local d = BC.deepest(g, flat, p[1], p[2], p[3], q[1], q[2], q[3], r)
        local brute = math.huge
        for t = 0, n - 1 do
            local o = t * 9
            local dd = segTri(p, q, { flat[o + 1], flat[o + 2], flat[o + 3] }, { flat[o + 4], flat[o + 5], flat[o + 6] },
                { flat[o + 7], flat[o + 8], flat[o + 9] })
            if dd < brute then brute = dd end
        end
        if brute >= r then
            T.eq(d, math.huge, "capsule " .. k .. ": nothing within its radius, and the grid says so")
        else
            T.near(d, brute, 1e-9, "capsule " .. k .. ": the grid's deepest is the deepest")
        end
    end
    -- a rotated, moved draw: distances are the same in the model's space as in the world's
    local c, s = math.cos(0.7), math.sin(0.7)
    local toModel, toWorld = BC.invRigid({ c, -s, 0, 5, s, c, 0, -3, 0, 0, 1, 2 })
    local x, y, z = toWorld(toModel(1, 2, 3))
    T.near(x + y + z, 6, 1e-12, "the draw's matrix inverted")
    T.eq(BC.invRigid({ 2, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 }), nil, "a scaled matrix is refused, not measured wrong")
end)

--------------------------------------------------------------------------
-- THE BODY
--------------------------------------------------------------------------
local function capturePlayer(name)
    local sv, world = F.server()
    local cl = F.client(world)
    local ply = cl:player("Model")
    ply._skel = SR.load(name)
    ply:SetPos(cl.env.Vector(0, 0, 0))
    return ply, cl
end

T.test("body clip: kleiner's capsules sit inside his skin, on his joints, and his own poses do not clip", function()
    local set = BC.load()
    T.eq(#set.pieces, 30, "thirty pieces: trunk four, neck, head, and each side's arm, hand, leg and foot")
    for _, p in ipairs(set.pieces) do
        T.between(p.r, 0.4, 6, p.name .. ": radius")
        T.between(p.out, 0, TOL_VEHICLE, p.name .. ": stands proud of the skin by less than the tolerance")
    end
    -- the limbs' ends are at their joints (the capsule moved across to the middle of the
    -- sleeve or trouser leg, under a unit)
    local ply = capturePlayer("kleiner_seated")
    local caps = {}
    for _, c in ipairs(BC.capsules(ply, set, "rider")) do caps[c.name] = c end
    local function joint(b)
        local m = ply:GetBoneMatrix(ply:LookupBone("ValveBiped.Bip01_" .. b))
        return m:GetTranslation()
    end
    local function dist(c, e, v) return sqrt((c[e .. "x"] - v.x) ^ 2 + (c[e .. "y"] - v.y) ^ 2 + (c[e .. "z"] - v.z) ^ 2) end
    for _, s in ipairs({ "r", "l" }) do
        local S = s:upper()
        for _, j in ipairs({ { "_thigh_hip", "a", "Thigh" }, { "_thigh_knee", "b", "Calf" }, { "_shin_knee", "a", "Calf" },
                             { "_shin_ankle", "b", "Foot" }, { "_upperarm_shoulder", "a", "UpperArm" },
                             { "_upperarm_elbow", "b", "Forearm" }, { "_forearm_elbow", "a", "Forearm" },
                             { "_forearm_wrist", "b", "Hand" }, { "_palm", "a", "Hand" }, { "_palm", "b", "Finger2" } }) do
            T.between(dist(caps[s .. j[1]], j[2], joint(S .. "_" .. j[3])), 0, 1.5,
                s .. j[1] .. ": its end at the " .. j[3] .. " joint, units")
        end
    end
    -- kleiner sat and stood as the engine drew him, nothing moved: no part in another
    for _, pose in ipairs({ "kleiner_seated", "kleiner_standing" }) do
        local p = capturePlayer(pose)
        local hits = BC.bodyHits(BC.capsules(p, set, "rider"), nil, { tol = TOL_BODY })
        T.eq(#hits, 0, pose .. ": nothing clips: " .. table.concat((function()
            local o = {} for _, h in ipairs(hits) do o[#o + 1] = BC.describe(h) end return o end)(), "; "))
    end
end)

--------------------------------------------------------------------------
-- A RIDE: a vehicle on a client of its own (its model built once, and let go with the
-- case), its riders on kleiner's skeleton, every triangle drawn recorded; a shot checks
-- every part of every body.
--------------------------------------------------------------------------
local function seatPod(cl, ent, seat)
    local E = cl.env
    local pod = cl.makeEntity("prop_vehicle_prisoner_pod")
    pod:SetParent(ent)
    pod:SetPos(ent:LocalToWorld(seat.offset))
    pod:SetAngles(ent:LocalToWorldAngles(seat.angles or E.Angle(0, 0, 0)))
    return pod
end

local Ride = {}
Ride.__index = Ride

local function newRide(id)
    local sv, world = F.server()
    local cl = F.client(world)
    local E, B = cl.env, cl.env.BMX
    MF.enable(cl)
    local R = setmetatable({ id = id, sv = sv, world = world, cl = cl, E = E, B = B, def = B.Vehicles[id],
        rec = BC.recorder(cl), people = {}, worst = {}, order = {}, shots = 0, set = BC.load() }, Ride)
    world.dt = 1 / 20
    cl.localPlayer = sv:player("Looker")
    return R
end

-- Someone on the vehicle: `targets()` their IK targets this frame (what their hands and
-- feet are allowed to be on), `seat` their pod (their saddle is near it).
function Ride:person(who, ply, targets)
    self.people[#self.people + 1] = { who = who, ply = ply, targets = targets }
end

local function bonesOf(ply)
    ply:InvalidateBoneCache(); ply:SetupBones()
    local out = {}
    for i, b in ipairs(ply._skel.BONES) do
        local m = ply:GetBoneMatrix(i)
        local t, f, r, u = m:GetTranslation(), m:GetForward(), m:GetRight(), m:GetUp()
        out[b[1]] = { t.x, t.y, t.z, f.x, f.y, f.z, -r.x, -r.y, -r.z, u.x, u.y, u.z }
    end
    return out
end

-- BMX_CLIP_SHOTS: the shot as studio.lua writes one.
function Ride:export(label)
    self.exported = self.exported or {}
    local drawn, tubes = {}, {}
    for _, d in ipairs(self.rec.draws) do drawn[#drawn + 1] = { mesh = d.mesh, mat = d.mat, name = d.name, m = d.m } end
    for _, t in ipairs(self.rec.tubes) do
        local pts = {}
        for i = 1, #t do pts[i] = t[i] end
        tubes[#tubes + 1] = { r = t.r, pts = pts }
    end
    local e = self.ent or self.rider
    local pos, fwd = e:GetPos(), e:GetForward()
    self.exported[#self.exported + 1] = { label = label, bones = bonesOf(self.rider), drawn = drawn, tubes = tubes,
        paxBones = self.pax and bonesOf(self.pax) or nil, targets = {}, ent = { pos.x, pos.y, pos.z, 0, 0, 0 },
        fwd = { fwd.x, fwd.y, fwd.z } }
end

function Ride:writeShots(name)
    if not (EXPORT and self.exported) then return end
    local J = require("lib.json")
    local meshes = {}
    for i, p in ipairs(self.rec.meshes) do meshes[i] = p or {} end
    local fh = assert(io.open(EXPORT .. "/" .. name:gsub("[^%w]+", "_"):gsub("_$", "") .. ".json", "w"))
    fh:write(J.encode({ id = self.id, pose = self.def.pose, model = true, meshes = meshes, shots = self.exported }))
    fh:close()
end

-- A SHOT: every body's capsules against the vehicle as drawn this frame, against
-- themselves, and against each other; the deepest of each (who, part, what) kept.
local SEAT = { __index = function(t, k) return rawget(t, "_t")[k] end }
function Ride:shot(label)
    self.shots = self.shots + 1
    if EXPORT then self:export(label) end
    local people = {}
    for _, p in ipairs(self.people) do
        local pod = p.ply._vehicle
        people[#people + 1] = { who = p.who, src = p.ply,
            targets = setmetatable({ _t = p.targets and p.targets() or {}, seat = pod and pod:GetPos() or nil }, SEAT) }
    end
    local hits = BC.check(people, self.rec, { set = self.set, label = label })
    for _, h in ipairs(hits) do
        -- (one entry a vehicle GROUP, its material noted: "frame (seat)")
        local key = h.who .. " " .. h.part .. " into " .. (h.body and h.with or h.group)
        local w = self.worst[key]
        if not w then
            w = { key = key, depth = h.depth, label = label, n = 0, body = h.body, mat = h.mat }
            self.worst[key] = w
            self.order[#self.order + 1] = w
        elseif h.depth > w.depth then
            w.depth, w.label, w.mat = h.depth, label, h.mat
        end
        w.n = w.n + 1
    end
end

function Ride:clips(all)
    local out = {}
    for _, w in ipairs(self.order) do
        if all or w.depth > (w.body and TOL_BODY or TOL_VEHICLE) then out[#out + 1] = w end
    end
    table.sort(out, function(a, b) return a.depth > b.depth end)
    return out
end

-- A vehicle with a seat: a bike, a motorbike (and a passenger on its pegs, a tandem's
-- stoker, a child seat's child), the scooter, the board.
function Ride:mount(pax)
    local cl, E, B, id, sv = self.cl, self.E, self.B, self.id, self.sv
    local standing = self.def.pose == "board" or self.def.pose == "scooter"
    local ent = cl:clientEntity(B.ClassFor(id))
    ent:SetPos(E.Vector(0, 0, standing and (id == "skateboard" and 1.3 or 3) or F.restHeight(sv)))
    ent:SetGrounded(true)
    if ent.SetPedalling then ent:SetPedalling(true) end
    if ent.SetPushPhase then ent:SetPushPhase(-1) end
    self.ent = ent
    local ply = cl:player("Rider")
    ply._skel = SR.load(standing and "kleiner_standing" or "kleiner_seated")
    ply._vehicle = seatPod(cl, ent, B.SeatFor(ent:Bike(), ent:Cfg(), "rider"))
    ent:SetPod(ply._vehicle)
    ent:SetDriver(ply)
    self.rider = ply
    self:person("rider", ply, function() return ent.ikTargets end)
    if pax then
        local p = cl:player("Pax")
        p._skel = SR.load("kleiner_seated")
        p._vehicle = seatPod(cl, ent, B.SeatFor(ent:Bike(), ent:Cfg(), pax))
        local stoker = pax == "pegs" and ent:Bike().seats.pegs.pedals
        if pax == "child" then
            ent._nw.PaxChild = p
            if ent.SetChildSeat then ent:SetChildSeat(true) end
        else
            ent._nw.PaxPegs = p
        end
        self.pax = p
        self:person(stoker and "stoker" or (pax == "child" and "child" or "pax"), p, function()
            if stoker then return ent.ikTargetsStoker end
            return B.PassengerTargets(p, ent, pax, ply)
        end)
    end
    cl.eyePos = ent:GetPos() + E.Vector(0, 150, 50)
    self.built = MF.ready(cl, ent)
    -- THE CRANKS, turned by the test: a bike's drawing asks ENT:CrankAngle (the unicycle
    -- and the penny-farthing turn theirs with the wheel: those are rolled instead).
    self.crank, self.cadence = 0, 7.85
    ent.CrankAngle = function() return self.crank end
    self.drawFrame = function() MF.draw(cl, ent) end
end

function Ride:frame()
    local E = self.E
    self.world.time = self.world.time + self.world.dt
    self.rec:frame()
    self.drawFrame()
    for _, p in ipairs(self.people) do E.hook.Run("PrePlayerDraw", p.ply) end
    if self.post then for _, p in ipairs(self.people) do E.hook.Run("PostPlayerDraw", p.ply) end end
end

-- n frames (at `dt`, else the world's), the cranks turning while `turning`.
function Ride:run(n, fn, dt)
    local was = self.world.dt
    self.world.dt = dt or was
    for i = 1, n do
        if fn then fn(i) end
        if self.turning then self.crank = self.crank + self.cadence * self.world.dt end
        self:frame()
    end
    self.world.dt = was
end

-- SETTLING, a tenth of a second a frame: the rider's smoothing is a spring in seconds,
-- the same at any frame rate (cl_rider.lua's SMOOTH), so a stance settles in half the
-- frames it takes at 20 a second, and each frame is a whole IK solve.
function Ride:settle(seconds, fn)
    self:run(math.max(1, math.floor(seconds / 0.1 + 0.5)), fn, 0.1)
end

-- Is the body still on its way somewhere? One more frame, and how far any capsule's end
-- moved in it.
function Ride:moving()
    local before = {}
    for _, p in ipairs(self.people) do
        for _, c in ipairs(BC.capsules(p.ply, self.set, p.who)) do before[#before + 1] = c end
    end
    self:run(1, nil, 0.1)
    local i, m = 0, 0
    for _, p in ipairs(self.people) do
        for _, c in ipairs(BC.capsules(p.ply, self.set, p.who)) do
            i = i + 1
            local o = before[i]
            m = math.max(m, math.abs(c.ax - o.ax) + math.abs(c.ay - o.ay) + math.abs(c.az - o.az),
                math.abs(c.bx - o.bx) + math.abs(c.by - o.by) + math.abs(c.bz - o.bz))
        end
    end
    return m > 0.5
end

function Ride:speed(v)
    local ent = self.ent
    ent._vel = ent:GetForward() * v
    if ent.SetSpeedUPS then ent:SetSpeedUPS(math.abs(v)) end
end

-- Up into the air (the shim does not carry a parent's children: the seats go up too).
function Ride:lift(dz)
    local d = self.E.Vector(0, 0, dz)
    self.ent:SetPos(self.ent:GetPos() + d)
    for _, p in ipairs(self.people) do
        if p.ply._vehicle then p.ply._vehicle:SetPos(p.ply._vehicle:GetPos() + d) end
    end
end

function Ride:crankNow() return self.ent.crankAngle or self.crank end

-- A FULL PEDAL STROKE: a shot every eighth of a turn, a frame apart (15.7 rad/s at 20
-- frames a second: the legs work no harder past cl_rider.lua's PEDAL_FULL, 7, and the
-- feet land on pedals that moved in a frame, test_rider_real.lua). Named by the right
-- crank's angle from where the stroke began.
local STEP = PI / 4
function Ride:stroke(prefix)
    local was = self.turning
    self.turning = false
    local start = self:crankNow()
    local mark = 1
    for _ = 1, 40 do
        self.crank = self.crank + STEP
        self:frame()
        if self:crankNow() - start >= mark * STEP - 1e-6 then
            self:shot(string.format("%s crank %d", prefix, (mark * 45) % 360))
            mark = mark + 1
            if mark > 8 then break end
        end
    end
    T.ok(mark > 8, self.id .. ": a whole stroke, " .. prefix)
    self.turning = was
end

--------------------------------------------------------------------------
-- SCENARIOS
--------------------------------------------------------------------------
local S = {}

-- The style poses a vehicle's pose set has, in the order the server numbers them.
local function poseNames(B, def)
    local set = B.PoseSets[def.pose]
    local out = {}
    for name in pairs(set and set.poses or {}) do
        if B.PoseIDs[name] then out[#out + 1] = name end
    end
    table.sort(out, function(a, b) return B.PoseIDs[a] < B.PoseIDs[b] end)
    return out
end

-- EACH STYLE POSE in the air, one after another (each blends from the last over
-- BMX.PoseBlendTime): a shot once it is in, and if the body is still on its way (a
-- can-can's leg takes a second to come over the top tube), another where it ends up.
local function styles(R, names)
    local B, ent = R.B, R.ent
    ent:SetGrounded(false)
    for _, name in ipairs(names) do
        ent:SetTrickBits(B.PoseIDs[name] * 65536)
        R:settle(0.3)
        R:shot(name)
        if R:moving() then
            for _ = 1, 6 do if not R:moving() then break end end
            R:shot(name .. " held")
        end
    end
    ent:SetTrickBits(0)
    R:settle(0.3)
    ent:SetGrounded(true)
end

-- A BIKE (a motorbike too): a whole pedal stroke seated, standing and in the attack
-- stance (a motorbike, with no pedals, a shot in each); full lock either way; the hop's
-- crouch; a landing at 400 u/s; each style pose.
S.bike = function(R)
    local B, ent, ply = R.B, R.ent, R.rider
    local kind = R.def.drive and R.def.drive.kind
    local pedals = kind ~= "engine" and kind ~= "throttle"
    local odd = R.id == "unicycle" or R.id == "penny"
    if odd then
        -- (the cranks turn with the wheel: rolled so they go round at the test's rate,
        -- the wheel's radius from the drawing's own spin)
        R:speed(60)
        R:run(2)
        local w = ent.oddSpin and ent.oddSpin.front
        R.oddRadius = (w and w.rate ~= 0) and 60 / w.rate or 12
        R:speed(R.cadence * R.oddRadius)
    else
        R:speed(pedals and 150 or 250)
    end
    R.turning = true
    R:settle(0.5)
    for _, stance in ipairs({ "seated", "standing", "attack" }) do
        ply:SetNWInt("BMXStance", B.RiderStanceId[stance])
        if stance ~= "seated" then R:settle(0.6) end
        if pedals then
            if R.oddRadius then R:speed(STEP / R.world.dt * R.oddRadius) end
            R:stroke(stance)
            if R.oddRadius then R:speed(R.cadence * R.oddRadius) end
        else
            R:shot(stance)
        end
    end
    ply:SetNWInt("BMXStance", B.RiderStanceId.seated)
    R:settle(0.5)
    local lock = R.def.family == "moto" and 30 or 35
    for _, s in ipairs({ 1, -1 }) do
        ent:SetSteer(math.rad(lock * s))
        R:settle(0.4)
        R:shot(s > 0 and "full lock left" or "full lock right")
    end
    ent:SetSteer(0)
    ent:SetHopCharge(1)
    R:run(5)
    R:shot("hop crouch")
    ent:SetHopCharge(0)
    -- A LANDING: three frames falling at 400 u/s, then the crouch that soaks it up. (In the
    -- air a freewheel's cranks stand level: cl_motor.lua's RestCrank.)
    R.turning = false
    if not odd then R.crank = math.floor(R.crank / PI + 0.5) * PI end
    ent:SetGrounded(false)
    local v = ent:GetForward() * 150 - ent:GetUp() * 400
    R:run(3, function() ent._vel = v end)
    ent:SetGrounded(true)
    R:speed(150)
    R:run(2)
    R:shot("landing")
    styles(R, poseNames(B, R.def))
end

-- THE BOARD, regular or goofy: rolling, a whole push, carving each way, the ollie's
-- crouch, the pop, the slide and the air, every grab, the landing, a manual and a nose
-- manual, a kickflip and a shove-it.
S.board = function(R, goofy)
    local B, ent = R.B, R.ent
    local Bd = B.Board
    local function flags(t)
        local u = { goofy = goofy or nil }
        for k, v in pairs(t or {}) do u[k] = v end
        ent:SetBoardFlags(Bd.PackFlags(u))
    end
    flags()
    -- (the server turns a goofy rider's seat round: sv_board.lua, Tune.seatYaw)
    if goofy then R.rider._vehicle:SetAngles(ent:LocalToWorldAngles(R.E.Angle(0, Bd.Tune.seatYaw.goofy, 0))) end
    R:speed(220)
    R:settle(0.5)
    R:shot("cruise")
    for i = 1, 20 do
        local ph = i / 20
        ent:SetPushPhase(ph < 0.95 and ph or -1)
        R:run(1)
        if i % 3 == 0 then R:shot(string.format("push %.2f", ph)) end
    end
    ent:SetPushPhase(-1)
    R:settle(0.5)
    for _, lean in ipairs({ 0.3, -0.3 }) do
        ent:SetBoardLean(lean)
        R:settle(0.4)
        R:shot(string.format("carve %+.1f", lean))
    end
    ent:SetBoardLean(0)
    R:run(5, function(i) ent:SetCrouch(i / 5) end)
    R:shot("crouch")
    ent:SetCrouch(0)
    ent:SetGrounded(false)
    R:lift(18)
    R:run(2)
    R:shot("ollie pop")
    R:run(3)
    R:shot("ollie slide")
    R:run(3)
    R:shot("ollie air")
    for _, name in ipairs(poseNames(B, R.def)) do
        ent:SetTrickBits(B.PoseIDs[name] * 65536)
        R:settle(0.3)
        R:shot(name)
        if R:moving() then
            for _ = 1, 5 do if not R:moving() then break end end
            R:shot(name .. " held")
        end
    end
    ent:SetTrickBits(0)
    R:settle(0.3)
    R:run(2, function() ent._vel = ent:GetForward() * 220 - ent:GetUp() * 350 end)
    ent:SetGrounded(true)
    R:lift(-18)
    R:speed(220)
    R:run(2)
    R:shot("ollie landing")
    R:settle(0.5)
    for _, m in ipairs({ { "manual", "manual" }, { "nose manual", "nose" } }) do
        flags({ meter = true, [m[2]] = true })
        R:settle(0.5, function(i) ent:SetMeter(math.sin(i / 2) * 0.7) end)
        R:shot(m[1])
    end
    flags()
    R:settle(0.3)
    for _, trick in ipairs({ { "kickflip", 1, 0 }, { "shove-it", 0, 1 } }) do
        R:run(4, function(i) ent:SetCrouch(i / 4) end)
        ent:SetCrouch(0)
        ent:SetGrounded(false)
        R:lift(16)
        for i = 1, 12 do
            local a = (i / 12) * 2 * PI
            ent:SetBoardBits(Bd.PackBits(trick[2] * a, trick[3] * (a / 2), 0))
            R:run(1)
            if i % 3 == 0 then R:shot(string.format("%s %d%%", trick[1], math.floor(i / 12 * 100))) end
        end
        ent:SetBoardBits(0)
        ent:SetGrounded(true)
        R:lift(-16)
        R:settle(0.3)
    end
end

-- THE SCOOTER: rolling, a whole kick, the bars turned each way, the hop's crouch, the
-- air and the landing, each style pose.
S.scooter = function(R)
    local B, ent = R.B, R.ent
    R:speed(200)
    R:settle(0.5)
    R:shot("cruise")
    for i = 1, 20 do
        local ph = i / 20
        ent:SetPushPhase(ph < 0.95 and ph or -1)
        R:run(1)
        if i % 3 == 0 then R:shot(string.format("kick %.2f", ph)) end
    end
    ent:SetPushPhase(-1)
    R:settle(0.4)
    for _, s in ipairs({ 1, -1 }) do
        ent:SetSteer(math.rad(30 * s))
        R:settle(0.4)
        R:shot(s > 0 and "steer left" or "steer right")
    end
    ent:SetSteer(0)
    ent:SetHopCharge(1)
    R:run(5)
    R:shot("hop crouch")
    ent:SetHopCharge(0)
    ent:SetGrounded(false)
    R:lift(14)
    R:run(4)
    R:shot("air")
    R:run(2, function() ent._vel = ent:GetForward() * 200 - ent:GetUp() * 350 end)
    ent:SetGrounded(true)
    R:lift(-14)
    R:speed(200)
    R:run(2)
    R:shot("landing")
    styles(R, poseNames(B, R.def))
end

-- THE SKATES, worn: the player is the vehicle, posed by cl_skates.lua as they are drawn
-- (PrePlayerDraw) and the boots drawn on the feet after (PostPlayerDraw). Standing,
-- rolling, and a stride on each foot.
S.skates = function(R)
    local cl, E, B = R.cl, R.E, R.B
    local ply = cl:player("Skater")
    ply._skel = SR.load("kleiner_standing")
    ply:SetPos(E.Vector(0, 0, 0))
    ply._eyeAngles = E.Angle(0, 0, 0)
    ply:SetNWString("BMXWorn", R.id)
    cl.eyePos = E.Vector(100, 100, 50)
    R.rider = ply
    R:person("skater", ply)
    R.post = true
    R.drawFrame = function() end
    -- (which boot is which: each is drawn about its own foot's sole)
    local Sk = B.Skates
    local place = Sk.BootPlacements
    Sk.BootPlacements = function(model, sole, yaw, side, spin)
        R.rec.tag = side > 0 and "l" or "r"
        return place(model, sole, yaw, side, spin)
    end
    ply._vel = E.Vector(0, 0, 0)
    for _ = 1, 8000 do R:frame() if #R.rec.draws > 0 then break end end      -- (the boots' model builds)
    R.built = #R.rec.draws > 0
    T.ok(R.built, "the skates' model builds")
    R:settle(0.5)
    R:shot("standing still")
    ply._vel = E.Vector(250, 0, 0)
    R:settle(0.5)
    R:shot("rolling")
    local interval = Sk.Tune.strideInterval
    for _, foot in ipairs({ 1, -1 }) do
        ply:SetNWInt("BMXSkateFoot", foot)
        for i = 1, 12 do
            ply:SetNWFloat("BMXSkatePhase", (i / 12) * interval)
            R:run(1, nil, interval / 12)
            if i % 3 == 0 then R:shot(string.format("stride %s %.2f", foot > 0 and "L" or "R", i / 12)) end
        end
    end
    ply:SetNWFloat("BMXSkatePhase", -1)
    R:settle(0.5)
    R:shot("rolling again")
    Sk.BootPlacements = place
end

--------------------------------------------------------------------------
-- EVERY VEHICLE A PLAYER RIDES. (Not "testcart": the platform's debug-only test vehicle,
-- hidden from the menu, with no model and no rider pose of its own.) A pegs passenger
-- where there are pegs, a tandem's stoker on theirs, a child in the child seat.
--------------------------------------------------------------------------
local RIDES = {}
for _, id in ipairs({ "stock", "cruiser", "dh", "fixie", "mini", "road", "tandem", "city", "penny", "unicycle", "ebike",
                      "dirtbike", "emoto", "moped" }) do
    RIDES[#RIDES + 1] = { id = id, name = id, scen = S.bike }
end
RIDES[#RIDES + 1] = { id = "scooter", name = "scooter", scen = S.scooter }
RIDES[#RIDES + 1] = { id = "skateboard", name = "skateboard regular", scen = function(R) S.board(R, false) end }
RIDES[#RIDES + 1] = { id = "skateboard", name = "skateboard goofy", scen = function(R) S.board(R, true) end }
RIDES[#RIDES + 1] = { id = "skates", name = "skates", scen = S.skates, worn = true }

T.test("body clip: every vehicle a player rides is ridden here", function()
    local sv = F.server()
    local B = sv.env.BMX
    local covered = {}
    for _, r in ipairs(RIDES) do covered[r.id] = true end
    for id, def in pairs(B.Vehicles) do
        if not def.debugOnly then T.ok(covered[id], id .. " is ridden by this file") end
    end
end)

local function line(w)
    local what = w.mat and not w.body and (" (" .. w.mat .. ")") or ""
    return string.format("%s%s %.2f, at %s", w.key, what, w.depth, w.label)
end

for _, r in ipairs(RIDES) do
    T.test("body clip: " .. r.name, function()
        local t0 = os.clock()
        local R = newRide(r.id)
        if not r.worn then
            local def = R.def
            local pax = (R.B.HasSeat(def, "pegs") and "pegs") or (R.B.HasSeat(def, "child") and "child") or nil
            R:mount(pax)
            T.ok(R.built, r.id .. ": the model builds")
        end
        r.scen(R)
        R:writeShots(r.name)
        T.eq(#R.cl.errors, 0, r.name .. ": no errors: " .. table.concat(R.cl.errors, " | "))

        -- AGAINST WHAT IS KNOWN
        local known = KNOWN[r.name] or {}
        local clips = R:clips(DUMP)
        local seen, new, worse, held = {}, {}, {}, {}
        for _, w in ipairs(clips) do
            local over = w.depth > (w.body and TOL_BODY or TOL_VEHICLE)
            if over then
                seen[w.key] = true
                local k = known[w.key]
                if not k then new[#new + 1] = w
                elseif w.depth > k.depth + MARGIN then worse[#worse + 1] = w
                else held[#held + 1] = w end
            end
        end
        local gone = {}
        for key in pairs(known) do if not seen[key] then gone[#gone + 1] = key end end
        table.sort(gone)
        print(string.format("    %s: %d shots, %.1fs; %d clips (%d known, %d new, %d deeper), %d known ones gone",
            r.name, R.shots, os.clock() - t0, #held + #new + #worse, #held, #new, #worse, #gone))
        for _, w in ipairs(DUMP and clips or {}) do print("      " .. line(w)) end
        if not DUMP then
            for i = 1, math.min(3, #held) do print("      known: " .. line(held[i])) end
        end
        for _, w in ipairs(new) do print("      NEW: " .. line(w)) end
        for _, w in ipairs(worse) do print(string.format("      DEEPER than the known %.2f: %s", known[w.key].depth, line(w))) end
        for _, key in ipairs(gone) do print("      gone (BMX_CLIP_REPORT=1 drops it from the known list): " .. key) end
        if REPORT then
            -- (rounded UP to the hundredth: the depth as measured passes against it)
            local rows = {}
            for _, w in ipairs(clips) do
                if w.depth > (w.body and TOL_BODY or TOL_VEHICLE) then
                    rows[w.key] = { depth = math.ceil(w.depth * 100) / 100,
                                    at = w.label .. (w.mat and not w.body and (", " .. w.mat) or "") }
                end
            end
            KNOWN[r.name] = next(rows) and rows or nil
            writeKnown()
            return
        end
        local function list(ws)
            local o = {}
            for _, w in ipairs(ws) do o[#o + 1] = line(w) end
            return table.concat(o, "; ")
        end
        T.eq(#new, 0, r.name .. ": clips nobody has seen before: " .. list(new))
        T.eq(#worse, 0, r.name .. ": known clips gone deeper: " .. list(worse))
        if STRICT then T.eq(#held, 0, r.name .. ": BMX_CLIP_STRICT, and it still clips: " .. list(held)) end
    end)
end
