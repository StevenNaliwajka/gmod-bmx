--[[--------------------------------------------------------------------------
    tools/bench/client_frame.lua

    WHAT A FRAME COSTS ON A CLIENT, offline. The real client files (the bike's
    Draw, the rider's pose and IK, the HUD, the chase camera, the sound, the
    prediction, the skates and the board) run against the suite's GMod shim
    (tests/lib/gmod.lua) with N riders in view, frame after frame, and this
    prints what a frame cost: milliseconds, Lua garbage, and the engine calls it
    made (SetupBones above all: every one is the engine re-posing a skeleton).

        luajit tools/bench/client_frame.lua                     every vehicle, 1 8 16 riders
        luajit tools/bench/client_frame.lua stock,road 8        those, 8 riders
        luajit tools/bench/client_frame.lua --root /path/to/an/older/checkout ...
        luajit tools/bench/client_frame.lua --count ...         + engine-call and Vector counts
        luajit tools/bench/client_frame.lua --spikes ...        + the frames that stood out, and why
        luajit tools/bench/client_frame.lua --profile ...       + LuaJIT's sampling profiler (-jp)

    Options: --frames N (measured, default 240), --warm N (default 60), --fps F
    (the client's frame rate the clock advances by, default 60), --spread D
    (riders D units apart, default 120: all within the IK's range), --joff (the
    JIT off: GMod's draw paths call the engine so often that much of them runs
    in the interpreter), --csv (one line per scene).

    WHAT THE NUMBERS ARE. `ms` is the whole frame in this process, shim
    included; `skel` is the part spent inside the shim's SetupBones (a Lua
    stand-in for the engine posing 69 bones, much slower than the engine's C++),
    and `lua` is the rest: the addon's own Lua plus the shim's cheap stubs.
    Read `lua` and the SetupBones count, not `ms`. `KB` is Lua garbage made per
    frame, the collector stopped (a shim Vector is a table, about 3x the bytes of
    GMod's userdata one: `vec` counts them). Nothing here is a GPU or the engine;
    see docs/TESTING.md, "What a client frame costs".

    The model builds (cl_bikemesh.lua) are done before the measuring starts and
    reported on their own: a build is a spike, not a frame cost.

    THE MODEL BUILD ITSELF (--build): each vehicle's model built from nothing, frame
    by frame, as a client sees a kind for the first time: the milliseconds a frame
    spent building and the whole frame's against the frame without it, frames over
    16 / 5 ms, the garbage made, the heap's high water. --heap MB gives the process a
    client-sized Lua heap first (a client's heap is every addon's: the collector's
    rounds are paced by it); --framelog prints every frame; --nogc stops the collector.

        luajit tools/bench/client_frame.lua --build stock,road,dirtbike --heap 200
        luajit tools/bench/client_frame.lua --build stock --root ../older-checkout

    --dump FILE records what each frame drew, built meshes included (their every
    vertex, hashed to the bit), so two versions can be shown to draw alike.
----------------------------------------------------------------------------]]

local script = (arg and arg[0]) or "tools/bench/client_frame.lua"
local here = script:match("^(.*)/[^/]*$") or "."
local REPO = here .. "/../.."

--------------------------------------------------------------------------
-- Arguments
--------------------------------------------------------------------------
local opt = { frames = 240, warm = 60, fps = 60, spread = 120 }
local drawBuf, hashMeshes, pumpBuilds -- --dump: the frame's record of what was drawn (below)
local positional = {}
do
    local i = 1
    while arg and arg[i] do
        local a = arg[i]
        local key = a:match("^%-%-(.+)$")
        if key == "count" or key == "spikes" or key == "profile" or key == "joff" or key == "csv" or key == "hooks"
            or key == "quiet" or key == "noik" or key == "varied" or key == "slowskel" or key == "buildlog" or key == "build" or key == "nogc" or key == "framelog" then
            opt[key] = true
        elseif key then
            opt[key] = arg[i + 1]
            i = i + 1
        else
            positional[#positional + 1] = a
        end
        i = i + 1
    end
end
for _, k in ipairs({ "frames", "warm", "fps", "spread" }) do opt[k] = tonumber(opt[k]) end
local ROOT = opt.root or REPO
local VEHICLES = {}
for id in (positional[1] or "stock,road,dirtbike,skateboard,skates,scooter"):gmatch("[^,]+") do
    VEHICLES[#VEHICLES + 1] = id
end
local COUNTS = {}
for n in (positional[2] or "1,8,16"):gmatch("[^,]+") do COUNTS[#COUNTS + 1] = tonumber(n) end

if opt.joff and jit then jit.off() end

package.path = REPO .. "/tests/?.lua;" .. package.path

--------------------------------------------------------------------------
-- A clock. LuaJIT's FFI reaches clock_gettime directly (a few tens of ns);
-- os.clock is the fallback (a syscall, and process CPU time).
--------------------------------------------------------------------------
local now
do
    local ok, ffi = pcall(require, "ffi")
    if ok then
        pcall(ffi.cdef, [[
            typedef struct { long tv_sec; long tv_nsec; } bmx_timespec;
            int clock_gettime(int clk, bmx_timespec *tp);
        ]])
        local ts = ffi.new("bmx_timespec")
        now = function()
            ffi.C.clock_gettime(1, ts)       -- CLOCK_MONOTONIC
            return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) * 1e-9
        end
    else
        now = os.clock
    end
end

--------------------------------------------------------------------------
-- COUNTING (--count): the shim's Vector and Angle constructors and the
-- metamethods that make new ones, wrapped BEFORE lib.gmod captures them. A
-- separate run from the timing, because the wrappers cost time themselves.
--------------------------------------------------------------------------
local tally = setmetatable({}, { __index = function() return 0 end })
local function bump(k) tally[k] = tally[k] + 1 end
if opt.count then
    local VA = require("lib.vecang")
    local V0, A0 = VA.Vector, VA.Angle
    VA.Vector = function(...) bump("vec") return V0(...) end
    VA.Angle = function(...) bump("ang") return A0(...) end
    local VMT = VA.VMT
    for _, k in ipairs({ "__add", "__sub", "__mul", "__div", "__unm", "Cross", "GetNormalized",
            "GetNormal", "AngleEx" }) do
        local f = VMT[k]
        VMT[k] = function(...) bump("vec") return f(...) end
    end
    local AV = VA.AngleVectors
    VA.AngleVectors = function(a) tally.vec = tally.vec + 3 return AV(a) end
end

local gmod = require("lib.gmod")
gmod.ROOT = ROOT
local F = require("lib.fixture")
local MF = require("lib.meshfake")
local SR = require("lib.skeleton_real")

--------------------------------------------------------------------------
-- A FAST SKELETON. The shim poses a real model's 69 bones (lib/skeleton_real.lua)
-- with its own Vector tables, about half a millisecond a pose here, and the IK
-- asks for dozens a frame per rider: the bench would spend its time in the
-- stand-in. This is the same composition (parent * translate(offset + position
-- manipulation) * rotate(rest) * rotate(manipulation)) on plain numbers, the
-- matrix made only when GetBoneMatrix asks for one. Checked against the shim's
-- own pose at start (--slowskel uses the shim's).
--------------------------------------------------------------------------
local VA = require("lib.vecang")
local SK = require("lib.skeleton")
local MMT = getmetatable(SK.Matrix())
local sin, cos, rad = math.sin, math.cos, math.rad

local function angleCols(a)
    local sp, cp = sin(rad(a.p)), cos(rad(a.p))
    local sy, cy = sin(rad(a.y)), cos(rad(a.y))
    local sr, cr = sin(rad(a.r)), cos(rad(a.r))
    -- forward, LEFT (minus Source's right), up: AngleVectors, as vecang.lua has it
    return cp * cy, cp * sy, -sp,
        -(-1 * sr * sp * cy + -1 * cr * -sy), -(-1 * sr * sp * sy + -1 * cr * cy), -(-1 * sr * cp),
        cr * sp * cy + -sr * -sy, cr * sp * sy + -sr * cy, cr * cp
end

local fastInfo = setmetatable({}, { __mode = "k" })
local function skelInfo(S)
    local info = fastInfo[S]
    if info then return info end
    info = { n = #S.BONES, parent = {}, off = {}, rest = {} }
    for i, b in ipairs(S.BONES) do
        info.parent[i] = b[2] and S.INDEX[b[2]] or 0
        info.off[i] = { b[3].x, b[3].y, b[3].z }
        info.rest[i] = { angleCols(b[4]) }
    end
    fastInfo[S] = info
    return info
end

-- out[(i-1)*12 + 1..12] = f, l, u, t of bone i.
local function fastPose(S, rootPos, rootAng, manips, manipPos)
    local info = skelInfo(S)
    local out = {}
    local rf1, rf2, rf3, rl1, rl2, rl3, ru1, ru2, ru3 = angleCols(rootAng)
    local rt1, rt2, rt3 = rootPos.x, rootPos.y, rootPos.z
    local parent, off, rest = info.parent, info.off, info.rest
    for i = 1, info.n do
        local pi = parent[i]
        local f1, f2, f3, l1, l2, l3, u1, u2, u3, t1, t2, t3
        if pi > 0 then
            local o = (pi - 1) * 12
            f1, f2, f3, l1, l2, l3 = out[o + 1], out[o + 2], out[o + 3], out[o + 4], out[o + 5], out[o + 6]
            u1, u2, u3, t1, t2, t3 = out[o + 7], out[o + 8], out[o + 9], out[o + 10], out[o + 11], out[o + 12]
        else
            f1, f2, f3, l1, l2, l3, u1, u2, u3, t1, t2, t3 = rf1, rf2, rf3, rl1, rl2, rl3, ru1, ru2, ru3, rt1, rt2, rt3
        end
        local of = off[i]
        local ox, oy, oz = of[1], of[2], of[3]
        local mp = manipPos and manipPos[i]
        if mp then ox, oy, oz = ox + mp.x, oy + mp.y, oz + mp.z end
        t1, t2, t3 = t1 + f1 * ox + l1 * oy + u1 * oz, t2 + f2 * ox + l2 * oy + u2 * oz, t3 + f3 * ox + l3 * oy + u3 * oz
        -- rotate by the rest, then by the manipulation, each in the bone's own frame
        for pass = 1, 2 do
            local a1, a2, a3, b1, b2, b3, c1, c2, c3
            if pass == 1 then
                local r = rest[i]
                a1, a2, a3, b1, b2, b3, c1, c2, c3 = r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9]
            else
                local m = manips[i]
                if not m then break end
                a1, a2, a3, b1, b2, b3, c1, c2, c3 = angleCols(m)
            end
            local nf1, nf2, nf3 = f1 * a1 + l1 * a2 + u1 * a3, f2 * a1 + l2 * a2 + u2 * a3, f3 * a1 + l3 * a2 + u3 * a3
            local nl1, nl2, nl3 = f1 * b1 + l1 * b2 + u1 * b3, f2 * b1 + l2 * b2 + u2 * b3, f3 * b1 + l3 * b2 + u3 * b3
            local nu1, nu2, nu3 = f1 * c1 + l1 * c2 + u1 * c3, f2 * c1 + l2 * c2 + u2 * c3, f3 * c1 + l3 * c2 + u3 * c3
            f1, f2, f3, l1, l2, l3, u1, u2, u3 = nf1, nf2, nf3, nl1, nl2, nl3, nu1, nu2, nu3
        end
        local o = (i - 1) * 12
        out[o + 1], out[o + 2], out[o + 3], out[o + 4], out[o + 5], out[o + 6] = f1, f2, f3, l1, l2, l3
        out[o + 7], out[o + 8], out[o + 9], out[o + 10], out[o + 11], out[o + 12] = u1, u2, u3, t1, t2, t3
    end
    out.fast = true
    return out
end

local function fastMatrix(P, b)
    local o = (b - 1) * 12
    if P[o + 12] == nil then return nil end
    local V = VA.Vector
    return setmetatable({ f = V(P[o + 1], P[o + 2], P[o + 3]), l = V(P[o + 4], P[o + 5], P[o + 6]),
                          u = V(P[o + 7], P[o + 8], P[o + 9]), t = V(P[o + 10], P[o + 11], P[o + 12]) }, MMT)
end

-- The fast pose is the shim's pose: every bone of both captured skeletons, with
-- manipulations on, within rounding.
local function checkFast()
    local SRm = require("lib.skeleton_real")
    math.randomseed(7)
    for _, name in ipairs({ "kleiner_seated", "kleiner_standing" }) do
        local S = SRm.load(name)
        local manips, manipPos = {}, {}
        for i = 1, #S.BONES, 3 do
            manips[i] = VA.Angle(math.random() * 60 - 30, math.random() * 60 - 30, math.random() * 60 - 30)
        end
        manipPos[1] = VA.Vector(1, -2, 3)
        local pos, ang = VA.Vector(10, 20, 30), VA.Angle(5, 100, -7)
        local a, b = S.pose(pos, ang, manips, manipPos), fastPose(S, pos, ang, manips, manipPos)
        local worst = 0
        for i = 1, #S.BONES do
            local m = fastMatrix(b, i)
            for _, k in ipairs({ "f", "l", "u", "t" }) do
                worst = math.max(worst, (a[i][k] - m[k]):Length())
            end
        end
        assert(worst < 1e-6, "the bench's fast skeleton disagrees with the shim's: " .. worst)
    end
end
if not opt.slowskel then checkFast() end

--------------------------------------------------------------------------
-- The engine, instrumented: every call that is engine work on a real client
-- is counted, and SetupBones is timed (it is the shim's dearest stand-in).
-- `SetupBones` counts the addon's own calls (each is the engine posing the
-- whole skeleton again); `SetupBones(lazy)` the shim posing on a GetBoneMatrix
-- after a manipulation, which the engine would not (it hands back the cached
-- bones).
--------------------------------------------------------------------------
local skel = { t = 0, kb = 0, gcStopped = false }

local function instrument(cl)
    local E = cl.env
    local P = cl.ENGINE.player
    local setup = P.SetupBones
    local function pose(self)
        local t0 = now()
        local k0 = skel.gcStopped and collectgarbage("count")
        local S = self._skel
        if S and S.BONES and S.pose and not opt.slowskel then
            local v = self._vehicle
            local pos, ang
            if v and v.IsValid and v:IsValid() then
                pos, ang = v:GetPos(), v:LocalToWorldAngles(VA.Angle(0, 90, 0))
            else
                pos, ang = self:GetPos(), VA.Angle(0, self:EyeAngles().y, 0)
            end
            self._pose = fastPose(S, pos, ang, self._manip or {}, self._manipPos)
        else
            setup(self)
        end
        if k0 then skel.kb = skel.kb + collectgarbage("count") - k0 end
        skel.t = skel.t + (now() - t0)
    end
    P.SetupBones = function(self) bump("SetupBones") pose(self) end
    P.GetBoneMatrix = function(self, b)
        bump("GetBoneMatrix")
        if not self._pose then bump("SetupBones(lazy)") pose(self) end
        local p = self._pose
        if p.fast then return fastMatrix(p, b) end
        local m = p[b]
        return m and m:Copy() or nil
    end
    local function count(tbl, name, key)
        local f = tbl[name]
        if type(f) ~= "function" then return end
        key = key or name
        tbl[name] = function(...) bump(key) return f(...) end
    end
    for _, k in ipairs({ "ManipulateBoneAngles", "ManipulateBonePosition",
            "InvalidateBoneCache", "LookupBone", "GetManipulateBoneAngles" }) do
        count(P, k)
    end
    count(E.util, "TraceLine"); count(E.util, "TraceHull")
    count(E, "ClientsideModel"); count(E, "CreateMaterial"); count(E, "Material")
    count(E, "Mesh"); count(E, "ParticleEmitter"); count(E, "CreateSound")
    count(E.render, "DrawBeam"); count(E.render, "DrawBox"); count(E.render, "SetMaterial")
    count(E.render, "ComputeLighting")
    count(E.cam, "PushModelMatrix")
    count(E.surface, "CreateFont")
    if E.file then
        for _, k in ipairs({ "Read", "Write", "Exists", "Append", "Find", "Open" }) do count(E.file, k, "file." .. k) end
    end
    if E.net then
        for k, f in pairs(E.net) do
            if type(f) == "function" and k:find("^Read") then count(E.net, k, "net.Read") end
        end
    end
    -- string.format: shared by both realms (it is the global string library).
    if opt.count and not string.bmxCounted then
        local sf = string.format
        string.format = function(...) bump("string.format") return sf(...) end
        string.bmxCounted = true
    end
    -- Matrix(): the bike draws a group under a fresh one; a skeleton's are the shim's.
    local M0 = E.Matrix
    E.Matrix = function(...) bump("Matrix") return M0(...) end
    -- A clientside model drawn (a tyre, a primitive part).
    local cs = E.ClientsideModel
    E.ClientsideModel = function(...)
        local m = cs(...)
        if m then
            local dm = m.DrawModel
            m.DrawModel = function(s) bump("DrawModel") return dm(s) end
        end
        return m
    end
    -- An IMesh drawn (each Draw is a draw call).
    local mk = E.Mesh
    if mk then
        E.Mesh = function(...)
            local m = mk(...)
            local d = m.Draw
            m.Draw = function(s) bump("Mesh:Draw") return d(s) end
            return m
        end
    end
end

--------------------------------------------------------------------------
-- A SCENE: N riders of one vehicle around the viewer, each on a client copy of
-- their vehicle, the first of them the local player (so the chase camera, the
-- HUD, the sound and the prediction run as well).
--------------------------------------------------------------------------
local SPEED = 180         -- u/s each rides at (wrapped back every couple of seconds)

local function seatPod(cl, ent, seat)
    local pod = cl.makeEntity("prop_vehicle_prisoner_pod")
    pod:SetParent(ent)
    pod:SetPos(ent:LocalToWorld(seat.offset))
    pod:SetAngles(ent:LocalToWorldAngles(seat.angles))
    return pod
end

--------------------------------------------------------------------------
-- --dump: WHAT A BUILT MESH HOLDS, to the bit. Every IMesh's BuildFromTriangles is
-- hashed (every vertex's position, normal, u, v, userdata, tangent and binormal, each
-- number by its exact bits), and each Mesh:Draw goes into the frame's record as that
-- hash. The hash is a polynomial one over the stream of numbers, so the draws of
-- consecutive meshes (with nothing drawn or set between them) are recorded as ONE
-- stream: a bucket built as one mesh or as several smaller ones, drawn one after the
-- other, records the same if the triangles reaching the screen, and their order, are
-- the same.
--------------------------------------------------------------------------
local HP1, HB1, HP2, HB2 = 67108859, 1000003, 33554393, 999983
local frexp = math.frexp
local function numKey(x)
    if x ~= x then return 77777 end
    if x == 0 then return (1 / x < 0) and 3 or 1 end
    local m, e = frexp(x)                       -- x = m * 2^e, 0.5 <= |m| < 1
    local mi = m * 9007199254740992             -- an integer, |mi| < 2^53: m's every bit
    return ((mi % HP1) * 2053 + e + 4100) % HP1
end
local VKEYS = { "pos", "normal", "tangent", "binormal" }
local function hashVerts(verts)
    local h1, h2, w1, w2, n = 0, 0, 1, 1, 0
    local function put(x)
        local k = numKey(x)
        h1 = (h1 * HB1 + k) % HP1
        h2 = (h2 * HB2 + k % HP2) % HP2
        w1 = (w1 * HB1) % HP1
        w2 = (w2 * HB2) % HP2
        n = n + 1
    end
    for i = 1, #verts do
        local v = verts[i]
        for _, key in ipairs(VKEYS) do
            local q = v[key]
            if q then put(q.x) put(q.y) put(q.z) else put(-1e300) end
        end
        put(v.u or -2e300) put(v.v or -2e300)
        local ud = v.userdata
        if ud then put(ud[1]) put(ud[2]) put(ud[3]) put(ud[4]) else put(-3e300) end
        put(v.color and 1 or 0)
    end
    return { h1 = h1, h2 = h2, w1 = w1, w2 = w2, n = n, verts = #verts }
end
-- A draw into the frame's record: merged into the run before it if that was a mesh too.
local function recMesh(m)
    if not drawBuf then return end
    local h = m.bmxHash
    if not h then drawBuf[#drawBuf + 1] = "Mempty" return end
    local last = drawBuf[#drawBuf]
    if type(last) == "table" then
        last.h1 = (last.h1 * h.w1 + h.h1) % HP1
        last.h2 = (last.h2 * h.w2 + h.h2) % HP2
        last.w1, last.w2 = (last.w1 * h.w1) % HP1, (last.w2 * h.w2) % HP2
        last.n, last.verts = last.n + h.n, last.verts + h.verts
    else
        drawBuf[#drawBuf + 1] = { h1 = h.h1, h2 = h.h2, w1 = h.w1, w2 = h.w2, n = h.n, verts = h.verts }
    end
end
local function runsToStrings(buf)
    for i, t in ipairs(buf) do
        if type(t) == "table" then buf[i] = string.format("M%d:%d:%d", t.h1, t.h2, t.verts) end
    end
end
function hashMeshes(E)
    local mk = E.Mesh
    E.Mesh = function(...)
        local m = mk(...)
        local build, draw = m.BuildFromTriangles, m.Draw
        m.BuildFromTriangles = function(self, verts)
            self.bmxHash = hashVerts(verts)
            return build(self, verts)
        end
        m.Draw = function(self)
            recMesh(self)
            return draw(self)
        end
        return m
    end
end

local function scene(id, n)
    local sv, world = F.server()
    local cl = F.client(world)
    MF.enable(cl)
    local E, B = cl.env, cl.env.BMX
    -- One frame number per frame (meshfake's advances on every call).
    local frameNo = 0
    E.FrameNumber = function() return frameNo end
    if opt.dump then
        -- Reproducible to the digit: the build's slices by a clock that only counts
        -- (a quarter of a millisecond a look), and the same random numbers. The model
        -- build's files have a clock of their own, so however often a build looks at
        -- the time, the rest of the client (the prediction's input history) sees the
        -- same clock in every version.
        local fake, fakeBuild = 0, 0
        local getinfo = debug.getinfo
        E.SysTime = function()
            local src = getinfo(2, "S").source
            if src:find("cl_bike", 1, true) or src:find("cl_geo_", 1, true) then
                fakeBuild = fakeBuild + 0.00025
                return fakeBuild
            end
            fake = fake + 0.00025
            return fake
        end
        math.randomseed(1)
        hashMeshes(E)
    end
    world.dt = 1 / opt.fps
    instrument(cl)
    local S = { id = id, n = n, cl = cl, sv = sv, world = world, E = E, B = B,
                riders = {}, ents = {}, pods = {} }
    function S.setFrame(f) frameNo = f end

    local def = B.Vehicles[id] or B.Bikes[id]
    assert(def, "no vehicle " .. id)
    local worn = def.worn
    local standing = def.family == "board" or def.family == "scooter" or worn
    local cols = math.ceil(math.sqrt(n))
    for i = 1, n do
        local x = ((i - 1) % cols) * opt.spread
        local y = math.floor((i - 1) / cols) * opt.spread
        local ply = cl:player("Rider" .. i)
        ply._skel = SR.load(standing and "kleiner_standing" or "kleiner_seated")
        local r = { ply = ply, start = E.Vector(x, y, 0) }
        if worn then
            ply._pos = E.Vector(x, y, 0)
            ply._vel = E.Vector(SPEED, 0, 0)
            ply:SetNWString("BMXWorn", id)
            ply:SetNWFloat("BMXSkatePhase", 0)
            ply:SetNWInt("BMXSkateFoot", 1)
        else
            local ent = cl:clientEntity(B.ClassFor(id))
            local cfg = ent:Cfg()
            local z = cfg.Wheel.radius - cfg.Chassis.mass * world.gravity * 0.5 / cfg.Wheel.spring
            if def.family == "board" then z = cfg.Wheel.radius end
            ent:SetPos(E.Vector(x, y, z))
            ent:SetGrounded(true)
            if ent.SetPedalling then ent:SetPedalling(true) end
            if ent.SetPushPhase then ent:SetPushPhase(-1) end
            if ent.SetSpeedUPS then ent:SetSpeedUPS(SPEED) end
            ent._vel = ent:GetForward() * SPEED
            local seat = B.SeatFor(ent:Bike(), cfg, "rider")
            local pod = seatPod(cl, ent, seat)
            ent:SetPod(pod)
            ent:SetDriver(ply)
            ply._vehicle = pod
            r.ent, r.pod, r.seat, r.z = ent, pod, seat, z
            S.ents[#S.ents + 1] = ent
        end
        S.riders[#S.riders + 1] = r
    end
    -- The viewer is rider 1, its eye behind and above it as the chase camera puts it.
    local me = S.riders[1].ply
    cl.localPlayer = me
    S.me = me
    return S
end

-- Everyone moves on along +x, and back to the start every two seconds.
-- --varied: riding as riders do, each on its own clock: steering, speeding up and
-- easing off, pitching and rolling over bumps, a hop, an air with the frame and bars
-- going round and a style pose, a hard landing, the stances, a sprint, weight forward,
-- the scooter's and the board's kicks. The steady default rides straight on.
local function vary(S, r, i, t)
    local E, B = S.E, S.B
    local ent = r.ent
    local u = t + i * 0.37
    local cyc = u % 3                                   -- a hop and an air every 3 s
    local air = cyc > 1.0 and cyc < 1.6
    ent:SetSteer(0.35 * math.sin(u * 1.3))
    local speed = SPEED * (0.6 + 0.4 * math.sin(u * 0.7))
    ent:SetSpeedUPS(speed)
    ent:SetGrounded(not air)
    ent:SetHopCharge((cyc > 0.6 and cyc < 1.0) and (cyc - 0.6) / 0.4 or 0)
    if ent.SetSprinting then ent:SetSprinting(math.floor(u / 2.3) % 2 == 1) end
    if ent.SetLeanFwd then ent:SetLeanFwd(math.max(0, math.sin(u * 0.9))) end
    if ent.SetPushPhase then
        local ph = u % 0.9
        ent:SetPushPhase(ph < 0.6 and ph / 0.6 or -1)
    end
    local whip, bar, pose = 0, 0, 0
    if air then
        local k = (cyc - 1.0) / 0.6
        whip, bar = k * 2 * math.pi, k * 4 * math.pi
        local names = B.PoseNames
        pose = (#names > 0) and ((math.floor(u / 3) + i) % #names + 1) or 0
    end
    local function byte(a) return math.floor((a % (2 * math.pi)) / (2 * math.pi) * 256 + 0.5) % 256 end
    ent:SetTrickBits(byte(whip) + byte(bar) * 256 + pose * 65536)
    local vz = air and (300 - 1000 * (cyc - 1.0)) or 0
    ent._vel = ent:GetForward() * speed + E.Vector(0, 0, vz)
    local pitch = 4 * math.sin(u * 2.1) + (air and -10 * math.sin((cyc - 1.0) / 0.6 * math.pi) or 0)
    ent:SetAngles(E.Angle(pitch, 0, 6 * math.sin(u * 1.7)))
    r.ply:SetNWInt("BMXStance", math.floor(u / 2.5) % 3 + 1)
    return air and 30 * math.sin((cyc - 1.0) / 0.6 * math.pi) or 0
end

local function move(S, t)
    local E = S.E
    local d = (t % 2) * SPEED
    for i, r in ipairs(S.riders) do
        local p = r.start + E.Vector(d, 0, 0)
        if r.ent then
            local lift = opt.varied and vary(S, r, i, t) or 0
            r.ent._pos = E.Vector(p.x, p.y, r.z + lift)
            r.pod._pos = r.ent:LocalToWorld(r.seat.offset)
            if opt.varied then r.pod:SetAngles(r.ent:LocalToWorldAngles(r.seat.angles)) end
        else
            r.ply._pos = p
            r.ply:SetNWFloat("BMXSkatePhase", (t % 0.9) < 0.6 and (t % 0.9) or -1)
            if opt.varied then
                r.ply._vel = E.Vector(SPEED * (0.6 + 0.4 * math.sin(t + i)), 0, 0)
                r.ply:SetNWInt("BMXSkateFoot", math.floor(t / 0.9) % 2 == 0 and 1 or -1)
            end
        end
    end
    S.cl.eyePos = S.me:GetPos() + E.Vector(-110, 0, 60)
end

-- A usercmd that answers anything (the client's CreateMove hooks read a few).
local function usercmd(E)
    local c = { buttons = 0, ang = E.Angle(0, 0, 0) }
    function c:GetButtons() return self.buttons end
    function c:SetButtons(b) self.buttons = b end
    function c:GetViewAngles() return E.Angle(self.ang.p, self.ang.y, self.ang.r) end
    function c:SetViewAngles(a) self.ang = a end
    function c:KeyDown() return false end
    return setmetatable(c, { __index = function() return function() return 0 end end })
end

local HUD_ELEMENTS = { "CHudCrosshair", "CHudHealth", "CHudBattery", "CHudAmmo",
    "CHudSecondaryAmmo", "CHudWeaponSelection", "CHudChat", "CHudDamageIndicator",
    "CHudZoom", "CHudGeiger", "CHudPoisonDamageIndicator", "CHudSquadStatus",
    "CHudTrain", "CHudMessage", "CHudHintDisplay", "CHudDeathNotice", "CHudVehicle",
    "CHudSuitPower", "CHudCloseCaption", "CHudHistoryResource" }

-- ONE CLIENT FRAME, in the engine's order: think, the view, the input, the
-- world (entities, then players), the HUD.
local function frame(S, f)
    local cl, E, world = S.cl, S.E, S.world
    S.setFrame(f)
    world.time = world.time + world.dt
    move(S, world.time)
    cl:runTimers()
    local hook = E.hook
    hook.Run("Think")
    for _, e in ipairs(S.ents) do if e.Think then e:Think() end end
    hook.Run("PreRender")
    local view = hook.Run("CalcView", S.me, S.me:GetPos(), E.Angle(0, 0, 0), 90)
    if view and view.origin then cl.eyePos = view.origin end
    hook.Run("CreateMove", S.cmd)
    hook.Run("PreDrawOpaqueRenderables", false, false)
    for _, e in ipairs(S.ents) do e:Draw() end
    for _, r in ipairs(S.riders) do
        hook.Run("CalcMainActivity", r.ply, r.ply:GetVelocity())
        hook.Run("PrePlayerDraw", r.ply)
        hook.Run("PostPlayerDraw", r.ply)
    end
    hook.Run("PostDrawOpaqueRenderables", false, false)
    hook.Run("PreDrawTranslucentRenderables", false, false)
    hook.Run("PostDrawTranslucentRenderables", false, false)
    hook.Run("RenderScreenspaceEffects")
    for _, h in ipairs(HUD_ELEMENTS) do hook.Run("HUDShouldDraw", h) end
    hook.Run("HUDPaint")
    -- What the shim records for the tests, dropped so it does not pile up here.
    cl.lines, cl.beams, cl.drawnCS, cl.groups, cl.texts = 0, {}, {}, {}, {}
end

--------------------------------------------------------------------------
-- The model builds, before anything is measured: drawn until every model this
-- scene asks for is ready. Reported: frames and the worst build slice.
--------------------------------------------------------------------------
local function prebuild(S)
    local t0, frames, worst = now(), 0, 0
    local BM = S.B.BikeMesh
    local f = 0
    local function pending()
        for _, st in pairs(BM.Status()) do if st == "building" then return true end end
        return false
    end
    -- the time each frame spent in the builds (BikeMesh.Get, whoever asked)
    local inGet = 0
    local get = BM.Get
    BM.Get = function(...)
        local a = now()
        local r = get(...)
        inGet = inGet + (now() - a)
        return r
    end
    local log = {}
    repeat
        f = f + 1
        inGet = 0
        local a = now()
        frame(S, f)
        local dt = now() - a
        worst = math.max(worst, dt)
        frames = frames + 1
        log[#log + 1] = { f = f, ms = dt * 1000, get = inGet * 1000 }
    until (frames > 30 and not pending()) or frames > 20000
    BM.Get = get
    S.frameAt = f
    if opt.buildlog then
        local over = { 0, 0, 0 }
        for _, e in ipairs(log) do
            if e.get > 8 then over[1] = over[1] + 1 end
            if e.get > 16 then over[2] = over[2] + 1 end
            if e.get > 33 then over[3] = over[3] + 1 end
        end
        table.sort(log, function(x, y) return x.get > y.get end)
        local parts = {}
        for i = 1, math.min(6, #log) do
            parts[#parts + 1] = string.format("#%d %.1f ms (build %.1f)", log[i].f, log[i].ms, log[i].get)
        end
        print(string.format("             build slices over 8/16/33 ms: %d/%d/%d of %d frames; worst: %s",
            over[1], over[2], over[3], frames, table.concat(parts, ", ")))
    end
    return { frames = frames, secs = now() - t0, worst = worst, status = BM.Status() }
end

-- --dump: the models built the same way in any version of the code. One frame asks for
-- every model the scene draws; then each is built to the end by asking for it again and
-- again (BikeMesh.Get, a fresh frame number each time) without the world moving on, so
-- the frames dumped start from the same world, whatever a version's build costs a frame.
function pumpBuilds(S)
    local BM, E = S.B.BikeMesh, S.E
    local asked, keys = {}, {}
    local get = BM.Get
    BM.Get = function(...)
        local args = { ... }
        local key = string.format("%s|%s|%s", tostring(args[1]), tostring(args[2]), tostring(args[3]))
        if not keys[key] then keys[key] = true asked[#asked + 1] = args end
        return get(...)
    end
    frame(S, 1)
    BM.Get = get
    local fn = E.FrameNumber
    local tick = 1e6
    for _, args in ipairs(asked) do
        for _ = 1, 200000 do
            tick = tick + 1
            E.FrameNumber = function() return tick end
            if get(unpack(args, 1, 4)) then break end
            local failed = false
            for _, st in pairs(BM.Status()) do if tostring(st):find("^failed") then failed = true end end
            if failed then break end
        end
    end
    E.FrameNumber = fn
    S.frameAt = 1
    return { frames = 1, secs = 0, worst = 0, status = BM.Status() }
end

local function pct(sorted, p)
    if #sorted == 0 then return 0 end
    return sorted[math.max(1, math.min(#sorted, math.floor(#sorted * p + 0.5)))]
end

local function resetTally() for k in pairs(tally) do tally[k] = nil end end

-- Measure a built scene: timing with the collector running as it would, then the
-- garbage with it stopped, then (--count) the engine calls.
-- --hooks: every hook function and every entity's Draw timed on its own, so a
-- frame's cost can be put down to what spent it (the skeleton's time included).
local hookTime, hookKB, hookVec = {}, {}, {}
local function timeHooks(S)
    local cl = S.cl
    local function timed(key, fn)
        return function(...)
            local k0 = skel.gcStopped and collectgarbage("count")
            local v0, s0 = tally.vec, tally.SetupBones
            local t0 = now()
            local a, b, c, d = fn(...)
            hookTime[key] = (hookTime[key] or 0) + (now() - t0)
            if k0 then
                hookKB[key] = (hookKB[key] or 0) + collectgarbage("count") - k0
                local hv = hookVec[key] or { 0, 0 }
                hv[1], hv[2] = hv[1] + tally.vec - v0, hv[2] + tally.SetupBones - s0
                hookVec[key] = hv
            end
            return a, b, c, d
        end
    end
    for ev, list in pairs(cl.hooks) do
        for id, fn in pairs(list) do list[id] = timed(ev .. " " .. tostring(id), fn) end
    end
    for _, e in ipairs(S.ents) do
        rawset(e, "Draw", timed("ENT:Draw " .. e:GetClass(), e.Draw))
    end
end

local function measure(S)
    local f = S.frameAt
    for _ = 1, opt.warm do f = f + 1; frame(S, f) end
    if opt.hooks then timeHooks(S) end
    for k in pairs(hookTime) do hookTime[k] = nil end
    collectgarbage("collect")
    -- timing
    local times, skels = {}, {}
    local spikes = {}
    for i = 1, opt.frames do
        f = f + 1
        skel.t = 0
        local a = now()
        frame(S, f)
        local dt = now() - a
        times[i], skels[i] = dt * 1000, skel.t * 1000
        if opt.spikes then spikes[#spikes + 1] = { i = i, ms = dt * 1000, skel = skel.t * 1000 } end
    end
    local hooks = {}
    for k, v in pairs(hookTime) do hooks[#hooks + 1] = { k, v * 1000 / opt.frames } end
    table.sort(hooks, function(a, z) return a[2] > z[2] end)
    for k in pairs(hookTime) do hookTime[k] = nil end
    for k in pairs(hookKB) do hookKB[k] = nil end
    for k in pairs(hookVec) do hookVec[k] = nil end
    -- garbage: each frame with the collector stopped, collected between (a
    -- frame here can make megabytes, and the box is shared)
    skel.gcStopped, skel.kb = true, 0
    resetTally()
    local G = math.min(opt.frames, 30)
    local perFrameKB, kbSum = {}, 0
    for i = 1, G do
        f = f + 1
        collectgarbage("collect")
        collectgarbage("stop")
        local a = collectgarbage("count")
        frame(S, f)
        perFrameKB[i] = collectgarbage("count") - a
        kbSum = kbSum + perFrameKB[i]
        collectgarbage("restart")
    end
    local kb = kbSum / G
    local skelKB = skel.kb / G
    local counts = {}
    for k, v in pairs(tally) do counts[k] = v / G end
    for _, h in ipairs(hooks) do
        h[3] = (hookKB[h[1]] or 0) / G
        local hv = hookVec[h[1]]
        h[4], h[5] = hv and hv[1] / G, hv and hv[2] / G
    end
    skel.gcStopped = false
    collectgarbage("collect")

    local sorted = {}
    local sum, sumSkel = 0, 0
    for i, t in ipairs(times) do sorted[i] = t; sum = sum + t; sumSkel = sumSkel + skels[i] end
    table.sort(sorted)
    local kbs = {}
    for i, v in ipairs(perFrameKB) do kbs[i] = v end
    table.sort(kbs)
    local out = {
        ms = sum / #times, p50 = pct(sorted, 0.5), p95 = pct(sorted, 0.95), max = sorted[#sorted],
        skel = sumSkel / #times, kb = kb, skelKB = skelKB, kbMax = kbs[#kbs] or 0,
        counts = counts, errors = #S.cl.errors, spikes = spikes, times = times, perFrameKB = perFrameKB,
        hooks = hooks,
    }
    out.lua = out.ms - out.skel
    return out
end

--------------------------------------------------------------------------
-- Report
--------------------------------------------------------------------------
local function fmt(x, d) return string.format("%." .. (d or 2) .. "f", x) end

if not opt.csv and not opt.quiet then
    print(string.format("client frame bench: root %s, %s, %d fps clock, %d frames (+%d warm), riders %d u apart",
        ROOT, (jit and (jit.status() and "LuaJIT, JIT on" or "LuaJIT, JIT off")) or _VERSION, opt.fps,
        opt.frames, opt.warm, opt.spread))
end
if opt.csv then
    print("vehicle,riders,ms,lua_ms,skel_ms,p95_ms,max_ms,kb,kb_noskel,setupbones,vec,errors")
end

local profiler
if opt.profile then
    profiler = require("jit.p")
end

-- --dump FILE: every rider's bone manipulations, frame by frame, to the digit, so two
-- versions of the code can be shown to pose the riders exactly alike (diff the files).
-- What was DRAWN goes in too, as a checksum a frame: every mesh vertex's fields, every
-- matrix a group was drawn under, every material set, model drawn, beam and box, and the
-- lighting. Two versions that draw alike to the digit have the same line.
local function rec(...)
    if not drawBuf then return end
    local n = select("#", ...)
    for i = 1, n do
        local v = select(i, ...)
        local tv = type(v)
        if tv == "number" then drawBuf[#drawBuf + 1] = string.format("%.17g", v)
        elseif tv == "table" then
            if v.x and v.y and v.z then drawBuf[#drawBuf + 1] = string.format("v%.17g,%.17g,%.17g", v.x, v.y, v.z)
            elseif v.p and v.y and v.r then drawBuf[#drawBuf + 1] = string.format("a%.17g,%.17g,%.17g", v.p, v.y, v.r)
            elseif v.rows then
                for _, row in ipairs(v.rows) do for _, x in ipairs(row) do drawBuf[#drawBuf + 1] = string.format("%.17g", x) end end
            elseif v.f and v.t then rec(v.f, v.l, v.u, v.t, v.s)
            elseif v.r and v.g and v.b then drawBuf[#drawBuf + 1] = string.format("c%d,%d,%d,%d", v.r, v.g, v.b, v.a or 255)
            elseif v.name then drawBuf[#drawBuf + 1] = "m" .. tostring(v.name)
            else drawBuf[#drawBuf + 1] = "t" .. #v; for _, x in ipairs(v) do rec(x) end
            end
        else drawBuf[#drawBuf + 1] = tostring(v) end
    end
end
local function checksum(str)
    local b = bit
    local h = 2166136261
    for i = 1, #str do h = b.tobit(b.bxor(h, str:byte(i)) * 16777619) end
    return string.format("%08x", h % 4294967296)
end
local function hookDraws(S)
    local E = S.E
    local function wrap(tbl, name)
        local f = tbl[name]
        if type(f) ~= "function" then return end
        tbl[name] = function(...) rec(name, ...) return f(...) end
    end
    for _, k in ipairs({ "Position", "Normal", "TangentS", "TangentT", "UserData", "TexCoord", "AdvanceVertex",
            "Begin", "End" }) do wrap(E.mesh, k) end
    for _, k in ipairs({ "DrawBeam", "DrawBox", "DrawLine", "DrawSphere", "SetMaterial", "SetColorModulation",
            "SetModelLighting", "SetLocalModelLights", "SuppressEngineLighting" }) do wrap(E.render, k) end
    wrap(E.cam, "PushModelMatrix")
    local cs = E.ClientsideModel
    E.ClientsideModel = function(model, ...)
        local m = cs(model, ...)
        if m then
            local dm = m.DrawModel
            m.DrawModel = function(s)
                rec("DrawModel", s.model, s.pos, s.ang, s.material, s.matrix)
                return dm(s)
            end
        end
        return m
    end
end

local function dumpScene(S, fh)
    local f = S.frameAt
    if bit then hookDraws(S) end
    for i = 1, opt.frames do
        f = f + 1
        drawBuf = bit and {} or nil
        frame(S, f)
        if drawBuf then
            runsToStrings(drawBuf)
            local all = table.concat(drawBuf, " ")
            fh:write(string.format("%s %d f%d draw %s %d\n", S.id, S.n, i, checksum(all), #drawBuf))
            drawBuf = nil
        end
        for ri, r in ipairs(S.riders) do
            local parts = {}
            local ply = r.ply
            local keys = {}
            for b in pairs(ply._manip or {}) do keys[#keys + 1] = b end
            table.sort(keys)
            for _, b in ipairs(keys) do
                local a = ply._manip[b]
                parts[#parts + 1] = string.format("%d:%.17g,%.17g,%.17g", b, a.p, a.y, a.r)
            end
            keys = {}
            for b in pairs(ply._manipPos or {}) do keys[#keys + 1] = b end
            table.sort(keys)
            for _, b in ipairs(keys) do
                local v = ply._manipPos[b]
                parts[#parts + 1] = string.format("p%d:%.17g,%.17g,%.17g", b, v.x, v.y, v.z)
            end
            fh:write(string.format("%s %d f%d r%d %s\n", S.id, S.n, i, ri, table.concat(parts, " ")))
        end
    end
end

local function report(id, n, S, b)
    if profiler then profiler.start(opt.profmode or "fl", opt.profout) end
    local m = measure(S)
    if profiler then profiler.stop() end
    local c = m.counts
    if opt.csv then
        print(table.concat({ id, n, fmt(m.ms), fmt(m.lua), fmt(m.skel), fmt(m.p95), fmt(m.max),
            fmt(m.kb, 1), fmt(m.kb - m.skelKB, 1), fmt(c.SetupBones or 0, 1), fmt(c.vec or 0, 0), m.errors }, ","))
    else
        print(string.format("%-10s x%-2d  frame %6s ms (lua %6s, skel %6s)  p95 %6s  max %6s | %7s KB/frame (%6s w/o skel) | SetupBones %6s/frame%s",
            id, n, fmt(m.ms), fmt(m.lua), fmt(m.skel), fmt(m.p95), fmt(m.max), fmt(m.kb, 1),
            fmt(m.kb - m.skelKB, 1), fmt(c.SetupBones or 0, 1),
            m.errors > 0 and ("  ERRORS " .. m.errors .. ": " .. tostring(S.cl.errors[1])) or ""))
        if not opt.quiet then
            print(string.format("             build: %d frames, worst frame while building %s ms", b.frames, fmt(b.worst * 1000)))
        end
        if opt.count then
            local keys = {}
            for k in pairs(c) do keys[#keys + 1] = k end
            table.sort(keys)
            local parts = {}
            for _, k in ipairs(keys) do parts[#parts + 1] = k .. " " .. fmt(c[k], 1) end
            print("             per frame: " .. table.concat(parts, ", "))
        end
        if opt.hooks then
            local parts = {}
            for i = 1, math.min(12, #m.hooks) do
                if m.hooks[i][2] >= 0.005 then
                    local h = m.hooks[i]
                    parts[#parts + 1] = string.format("%s %.3f ms %.0f KB", h[1], h[2], h[3] or 0)
                        .. (opt.count and h[4] and string.format(" %.0f vec %.1f SetupBones", h[4], h[5]) or "")
                end
            end
            print("             by hook, a frame: " .. table.concat(parts, ", "))
        end
        if opt.spikes then
            table.sort(m.spikes, function(a, z) return a.ms > z.ms end)
            local med = m.p50
            local parts = {}
            for i = 1, math.min(5, #m.spikes) do
                local s = m.spikes[i]
                parts[#parts + 1] = string.format("#%d %s ms (skel %s)", s.i, fmt(s.ms), fmt(s.skel))
            end
            print("             worst frames (median " .. fmt(med) .. "): " .. table.concat(parts, ", "))
            print(string.format("             garbage: worst frame %s KB, median %s KB", fmt(m.kbMax, 1),
                fmt(pct((function() local t = {} for i, v in ipairs(m.perFrameKB) do t[i] = v end table.sort(t) return t end)(), 0.5), 1)))
        end
    end
    io.stdout:flush()
end

--------------------------------------------------------------------------
-- --build: A MODEL BUILD, MEASURED ON ITS OWN. One rider of each vehicle (or N) is
-- drawn with the models off for --warm frames (the simple bike, as it is drawn while
-- a model builds: that frame's median is the baseline), then with them on, frame by
-- frame from nothing built until the model is ready, as a client sees a kind for the
-- first time. For each frame the build ran in:
--   build   the milliseconds spent in BikeMesh.Get (whoever asked: the build's own
--           slice, the collector's work inside it included)
--   extra   the whole frame less the baseline: the build AND what it left for the rest
--           of the frame (LuaJIT pays a collector's debt from the next allocation,
--           wherever it is). The number a player feels.
-- Then the same build again with the collector stopped, for the garbage it made (its
-- own, inside Get). The clock the build budgets by (SysTime) is the wall clock here, as
-- in the game. --nogc: the timed build with the collector stopped too.
--------------------------------------------------------------------------
-- --heap MB: a client's Lua heap is not this bench's few MB: every addon's tables live
-- in it (100-300 MB is usual on a server with a few dozen addons), and LuaJIT's
-- collector paces itself by the heap: a round starts when it has doubled, and every
-- round marks and sweeps all of it. Ballast of that many MB of small long-lived tables
-- makes this process's heap a client's, so the build's garbage is collected as it
-- would be there (a round every hundred-odd MB, not every few).
local ballast
local function makeBallast()
    local mb = tonumber(opt.heap)
    if not mb or ballast then return end
    -- in tables of 500, as an addon's state is many tables, not one array the
    -- collector would walk in one step
    ballast = {}
    local target = collectgarbage("count") + mb * 1024
    local i, group = 0, nil
    while collectgarbage("count") < target do
        i = i + 1
        if i % 500 == 1 then group = {} ballast[#ballast + 1] = group end
        group[#group + 1] = { id = i, name = "ent" .. (i % 977), x = i * 0.5, y = -i, flag = (i % 3 == 0), list = { i, i + 1 } }
    end
    collectgarbage("collect")
end

local function buildBench(id)
    makeBallast()
    local S = scene(id, tonumber(positional[2]) or 1)
    S.cmd = usercmd(S.E)
    local E, BM = S.E, S.B.BikeMesh
    if not opt.dump then E.SysTime = now end
    local get = BM.Get
    local inGet, kbGet, gcStopped = 0, 0, false
    BM.Get = function(...)
        local k0 = gcStopped and collectgarbage("count")
        local a = now()
        local r = get(...)
        inGet = inGet + (now() - a)
        if k0 then kbGet = kbGet + collectgarbage("count") - k0 end
        return r
    end
    -- every slice of the build (a coroutine resume) timed
    local steps = {}
    local realCo = coroutine
    E.coroutine = setmetatable({ resume = function(co, ...)
        local a = now()
        local r = { realCo.resume(co, ...) }
        steps[#steps + 1] = (now() - a) * 1000
        return unpack(r)
    end }, { __index = realCo })
    local function pending()
        for _, st in pairs(BM.Status()) do if st == "building" then return true end end
        return false
    end
    local f = 0
    -- the baseline: the simple bike, the models off
    local cvModel = E.GetConVar("bmx_bike_model")
    cvModel:SetInt(0)
    local base = {}
    for i = 1, math.max(opt.warm, 10) do
        f = f + 1
        local a = now()
        frame(S, f)
        base[i] = (now() - a) * 1000
    end
    table.sort(base)
    local baseMs = pct(base, 0.5)
    local baseP95, baseMax = pct(base, 0.95), base[#base]
    cvModel:SetInt(1)
    local peak = 0                       -- the heap's high water while it builds (KB)
    local function run()
        local log = {}
        local f0 = f
        repeat
            f = f + 1
            inGet = 0
            local a = now()
            frame(S, f)
            log[#log + 1] = { ms = (now() - a) * 1000, get = inGet * 1000 }
            peak = math.max(peak, collectgarbage("count"))
            if opt.framelog then
                print(string.format("  frame %d: %.2f ms, build %.2f ms, heap %.1f MB", f, log[#log].ms, log[#log].get,
                    collectgarbage("count") / 1024))
            end
        until (f - f0 > 2 and not pending()) or f - f0 > 40000
        -- the frames the build ran in (Get still spent time); the last ones may be a
        -- finished model looked up
        while #log > 0 and log[#log].get < 0.05 do log[#log] = nil end
        return log
    end
    collectgarbage("collect")
    local heap0 = collectgarbage("count")
    local cg = collectgarbage
    if opt.nogc then
        E.collectgarbage = function(what, ...) if what == "step" then return true end return cg(what, ...) end
        cg("stop")
    end
    if profiler then profiler.start(opt.profmode or "fl", opt.profout) end
    local t0 = now()
    local log = run()
    local wall = now() - t0
    if profiler then profiler.stop() end
    if opt.nogc then cg("restart") E.collectgarbage = nil end
    local heapAfter = collectgarbage("count")
    local peakMB = (peak - heap0) / 1024
    collectgarbage("collect")
    local heapKept = collectgarbage("count") - heap0
    -- garbage: the same build again, the collector stopped (and the build's own
    -- collector steps made no-ops, so they do not run it)
    local stepsTimed = steps
    steps = {}
    BM.Clear()
    collectgarbage("collect")
    E.collectgarbage = function(what, ...)
        if what == "step" then return true end
        return cg(what, ...)
    end
    gcStopped, kbGet = true, 0
    cg("stop")
    run()
    cg("restart")
    gcStopped = false
    E.collectgarbage = nil
    BM.Get = get
    E.coroutine = nil
    local garbageMB = kbGet / 1024
    collectgarbage("collect")

    local gets, extras, sum, extraSum = {}, {}, 0, 0
    local over16, over5, xover16, xover5 = 0, 0, 0, 0
    for i, e in ipairs(log) do
        local x = e.ms - baseMs
        gets[i], extras[i] = e.get, x
        sum, extraSum = sum + e.get, extraSum + math.max(x, 0)
        if e.get > 16 then over16 = over16 + 1 end
        if e.get > 5 then over5 = over5 + 1 end
        if x > 16 then xover16 = xover16 + 1 end
        if x > 5 then xover5 = xover5 + 1 end
    end
    table.sort(gets)
    table.sort(extras)
    table.sort(stepsTimed)
    local r = {
        id = id, frames = #log, p50 = pct(gets, 0.5), p95 = pct(gets, 0.95), max = gets[#gets] or 0,
        over16 = over16, over5 = over5, total = sum,
        xp50 = pct(extras, 0.5), xp95 = pct(extras, 0.95), xmax = extras[#extras] or 0,
        xover16 = xover16, xover5 = xover5, xtotal = extraSum, base = baseMs, baseP95 = baseP95, baseMax = baseMax,
        wall = wall, garbage = garbageMB, kept = heapKept / 1024, peak = peakMB,
        steps = #stepsTimed, stepMax = stepsTimed[#stepsTimed] or 0, errors = #S.cl.errors,
    }
    if opt.csv then
        print(table.concat({ id, r.frames, fmt(r.p50), fmt(r.p95), fmt(r.max), r.over16, r.over5, fmt(r.total, 0),
            fmt(r.xp50), fmt(r.xp95), fmt(r.xmax), r.xover16, r.xover5, fmt(r.xtotal, 0), fmt(r.garbage, 1),
            fmt(r.peak, 1), fmt(r.base), fmt(r.baseP95), fmt(r.baseMax), r.errors }, ","))
    else
        print(string.format("%-10s %4d frames | build ms p50 %5s p95 %5s max %6s  >16 %3d >5 %3d  total %5s | extra ms p50 %5s p95 %5s max %6s  >16 %3d >5 %3d  total %5s | garbage %6s MB, heap peak +%5s MB | base frame %s ms (p95 %s, max %s)%s",
            id, r.frames, fmt(r.p50), fmt(r.p95), fmt(r.max), r.over16, r.over5, fmt(r.total, 0),
            fmt(r.xp50), fmt(r.xp95), fmt(r.xmax), r.xover16, r.xover5, fmt(r.xtotal, 0),
            fmt(r.garbage, 1), fmt(r.peak, 1), fmt(r.base, 1), fmt(r.baseP95, 1), fmt(r.baseMax, 1),
            r.errors > 0 and ("  ERRORS " .. r.errors .. ": " .. tostring(S.cl.errors[1])) or ""))
    end
    io.stdout:flush()
    return r
end

if opt.build then
    if opt.csv then
        print("vehicle,frames,build_p50,build_p95,build_max,build_over16,build_over5,build_total,extra_p50,extra_p95,extra_max,extra_over16,extra_over5,extra_total,garbage_mb,heap_peak_mb,base_ms,base_p95_ms,base_max_ms,errors")
    end
    for _, id in ipairs(VEHICLES) do
        buildBench(id)
        collectgarbage("collect")
    end
    os.exit(0)
end

for _, id in ipairs(VEHICLES) do
    for _, n in ipairs(COUNTS) do
        local S = scene(id, n)
        S.cmd = usercmd(S.E)
        local b = opt.dump and pumpBuilds(S) or prebuild(S)
        if opt.dump then
            local fh = io.open(opt.dump, "a")
            dumpScene(S, fh)
            fh:close()
            print(string.format("%-10s x%-2d dumped %d frames (errors %d%s)", id, n, opt.frames, #S.cl.errors,
                #S.cl.errors > 0 and (": " .. S.cl.errors[1]) or ""))
        else
            report(id, n, S, b)
        end
        S = nil
        collectgarbage("collect")
    end
end
