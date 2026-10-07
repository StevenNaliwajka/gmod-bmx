--[[--------------------------------------------------------------------------
    tests/lib/gmod.lua

    Enough of Garry's Mod to EXECUTE this addon in a stock Lua 5.1, with no
    game, no server and no client.

    WHY THIS EXISTS when the addon already has a headless suite. The headless
    suite runs on a real dedicated server and is the authority on how the bike
    behaves in VPhysics. It has two blind spots by construction, and both have
    shipped bugs:

      * It has NO CLIENT. The HUD, the chase camera, the wheel drawing and the
        sound loops never execute on a dedicated server. When this shim was
        first pointed at them, two of those files threw on every frame they
        ever ran (a nil `self` in the wheel drawing, a nil `bike` in the tuning
        overlay), which means nobody had ever seen the procedural wheels the
        docs call the most useful debugging aid in the project.
      * It bypasses the usercmd DECODE on purpose (a scripted rider writes
        bike.input directly), so nothing tested which key does what.

    And it needs a game server, so it cannot run on GitHub, on a laptop, or for
    a contributor who has never installed srcds.

    WHAT IT IS. Two REALMS (server and client), each a separate global
    environment that the real addon files are loaded into with setfenv, exactly
    as GMod runs one file set per realm. They share a WORLD: the clock, a flat
    ground, the replicated convars, and a net WIRE that type-checks every read
    against the write it is consuming, so a HUD that reads the debug stream in a
    different order from the server that writes it fails loudly here.

    The server realm also integrates rigid bodies: impulses at points, a real
    inertia tensor on the body's principal axes, gravity, and a crude box-versus-
    ground contact for the hull. It is NOT VPhysics and the tests that use it are
    written to survive the difference -- they assert signs, orderings and bands
    wide enough that a plant which is right in kind passes, and they stay out of
    anything VPhysics decides for itself.
----------------------------------------------------------------------------]]

local VA = require("lib.vecang")
local SK = require("lib.skeleton")
SK.install(VA.AMT)
local Vector, Angle = VA.Vector, VA.Angle

local M = {}

M.ROOT = M.ROOT or "."

--------------------------------------------------------------------------
-- GMod's extensions to the standard library. Global, because they are the same
-- in both realms and GLua code reaches for them as math.Clamp, table.Copy...
--------------------------------------------------------------------------
math.Clamp = math.Clamp or function(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end
math.Round = math.Round or function(v, d)
    local m = 10 ^ (d or 0)
    return math.floor(v * m + 0.5) / m
end
math.NormalizeAngle = math.NormalizeAngle or function(a)
    return (a + 180) % 360 - 180
end
math.AngleDifference = math.AngleDifference or function(a, b)
    local d = math.NormalizeAngle(a - b)
    if d < -180 then d = d + 360 end
    return d
end
table.Copy = table.Copy or function(t)
    local o = {}
    for k, v in pairs(t) do o[k] = type(v) == "table" and table.Copy(v) or v end
    return setmetatable(o, getmetatable(t))
end
table.Count = table.Count or function(t)
    local n = 0 for _ in pairs(t) do n = n + 1 end return n
end
table.HasValue = table.HasValue or function(t, v)
    for _, x in pairs(t) do if x == v then return true end end
    return false
end

--------------------------------------------------------------------------
-- bit, which Lua 5.1 does not have. Unsigned 32-bit.
--------------------------------------------------------------------------
local bitlib = {}
local function tobits(x)
    x = x % 4294967296
    return x
end
local function bitop(a, b, f)
    a, b = tobits(a), tobits(b)
    local r, m = 0, 1
    for _ = 1, 32 do
        local x, y = a % 2, b % 2
        if f(x, y) then r = r + m end
        a, b, m = (a - x) / 2, (b - y) / 2, m * 2
    end
    return r
end
function bitlib.band(a, b, ...)
    local r = bitop(a, b, function(x, y) return x == 1 and y == 1 end)
    if ... then return bitlib.band(r, ...) end
    return r
end
function bitlib.bor(a, b, ...)
    local r = bitop(a, b or 0, function(x, y) return x == 1 or y == 1 end)
    if ... then return bitlib.bor(r, ...) end
    return r
end
function bitlib.bnot(a) return 4294967295 - tobits(a) end
M.bit = bitlib

M.IN = {
    ATTACK = 1, JUMP = 2, DUCK = 4, FORWARD = 8, BACK = 16, USE = 32,
    MOVELEFT = 512, MOVERIGHT = 1024, ATTACK2 = 2048, SPEED = 131072,
    RELOAD = 8192, WALK = 262144,
}

--------------------------------------------------------------------------
-- The WORLD: what both realms agree on.
--------------------------------------------------------------------------
function M.World(opts)
    opts = opts or {}
    return {
        time     = 0,
        dt       = opts.dt or (1 / 66),
        gravity  = opts.gravity or 600,
        groundZ  = opts.groundZ or 0,
        -- The ground is a square of this half-width about the origin. Anything
        -- outside it is a drop, which is how "ran off the edge" gets tested.
        groundHalf = opts.groundHalf or 1e6,
        -- A RAMP: the ground can be an inclined plane through (0, 0, groundZ)
        -- rising toward +x at this many degrees. 0 is the flat plane.
        groundSlope = opts.groundSlope or 0,
        groundBumps = opts.groundBumps,          -- see bump() below
        -- SOLIDS: axis-aligned boxes { mins, maxs } standing in for a map's
        -- rails and ledges. Traces hit them; the plant does not collide with
        -- them (a grind positions the bike itself, and that is what is tested).
        solids = opts.solids or {},
        convars  = {},
        cvarCallbacks = {},
        wire     = {},
    }
end

local function groundAt(world, p)
    return math.abs(p.x) <= world.groundHalf and math.abs(p.y) <= world.groundHalf
end

-- The ground plane's unit normal and a point's height above it (negative
-- below). Plain numbers, so it works on either realm's Vector.
local function groundNormal(world)
    local a = math.rad(world.groundSlope or 0)
    return -math.sin(a), 0, math.cos(a)
end

-- BUMPS: World{ groundBumps = { amp = , wave = } } lays a rolling surface of
-- height amp*sin(2 pi x/wave)*sin(2 pi y/(0.73 wave) + 1.1) over the plane -- a
-- skatepark floor's seams and undulations, tilting the surface both along and
-- across the direction of travel. nil is the smooth plane.
local function bump(world, x, y)
    local b = world.groundBumps
    if not b then return 0, 0, 0 end
    local kx, ky = 2 * math.pi / b.wave, 2 * math.pi / (b.wave * 0.73)
    local sx, cx = math.sin(kx * x), math.cos(kx * x)
    local sy, cy = math.sin(ky * y + 1.1), math.cos(ky * y + 1.1)   -- not flat along y = 0
    return b.amp * sx * sy, b.amp * kx * cx * sy, b.amp * ky * sx * cy
end

local function groundHeight(world, p)
    local nx, ny, nz = groundNormal(world)
    local f = bump(world, p.x, p.y)
    return p.x * nx + p.y * ny + (p.z - world.groundZ - f) * nz
end

-- The surface normal at (x, y): the plane's, tilted by the bumps' slope.
local function groundNormalAt(world, p)
    local nx, ny, nz = groundNormal(world)
    local _, fx, fy = bump(world, p.x, p.y)
    local vx, vy, vz = nx - fx * nz, ny - fy * nz, nz
    local l = math.sqrt(vx * vx + vy * vy + vz * vz)
    return vx / l, vy / l, vz / l
end
M.groundNormal, M.groundHeight, M.groundNormalAt = groundNormal, groundHeight, groundNormalAt

--------------------------------------------------------------------------
-- A convar. Shared between realms through the world, which is what
-- FCVAR_REPLICATED amounts to for a single-client test.
--------------------------------------------------------------------------
local function newConVar(name, default, flags, help)
    local cv = { name = name, value = tostring(default), default = tostring(default),
                 flags = flags, help = help }
    function cv:GetFloat() return tonumber(self.value) or 0 end
    function cv:GetInt() return math.floor(tonumber(self.value) or 0) end
    function cv:GetBool() return (tonumber(self.value) or 0) ~= 0 end
    function cv:GetString() return self.value end
    function cv:GetName() return self.name end
    function cv:GetDefault() return self.default end
    function cv:SetString(v)
        local old = self.value
        self.value = tostring(v)
        -- cvars.AddChangeCallback, as the engine runs them: on a real change.
        local cbs = self.world and self.world.cvarCallbacks[self.name]
        if cbs and old ~= self.value then
            for _, fn in pairs(cbs) do fn(self.name, old, self.value) end
        end
    end
    cv.SetFloat, cv.SetInt = cv.SetString, cv.SetString
    function cv:SetBool(b) self.value = b and "1" or "0" end
    return cv
end

--------------------------------------------------------------------------
-- The REALM.
--------------------------------------------------------------------------
function M.Realm(world, which)
    local SERVER = which == "server"
    local R = {
        world = world, name = which,
        errors = {},        -- every ErrorNoHalt, so a test can assert on none
        log    = {},        -- every MsgN
        sounds = {},        -- every EmitSound: { ent, name, level, pitch, vol }
        lines  = 0,         -- render.DrawLine calls this frame
        beams  = {},        -- render.DrawBeam calls: { a, b, w, col }
        texts  = {},        -- draw.SimpleText strings this frame
        csfiles = {},       -- AddCSLuaFile'd paths
        loaded  = {},       -- include()d paths, in order
        files   = {},       -- file.Write
        hooks   = {},
        timers  = {},
        commands = {},
        netHandlers = {},
        netStrings  = {},
        ents    = {},       -- index -> entity, in creation order
        stored  = {},       -- scripted_ents
        lists   = {},
        dupe    = {},
        players = {},
    }

    local env = setmetatable({}, { __index = _G })
    R.env = env

    env.SERVER, env.CLIENT = SERVER, not SERVER
    env.Vector, env.Angle = Vector, Angle
    env.isvector, env.isangle = VA.isvector, VA.isangle
    env.vector_up = Vector(0, 0, 1)
    env.vector_origin = Vector(0, 0, 0)
    env.bit = bitlib

    for k, v in pairs(M.IN) do env["IN_" .. k] = v end
    env.FCVAR_ARCHIVE, env.FCVAR_REPLICATED, env.FCVAR_NOTIFY = 128, 8192, 256
    env.FCVAR_PROTECTED = 32
    env.MASK_SOLID, env.MASK_SOLID_BRUSHONLY = 33570827, 16395
    env.MOVETYPE_VPHYSICS, env.SOLID_VPHYSICS = 6, 6
    env.SIM_NOTHING = 0
    env.SIMPLE_USE = 1
    env.KEY_K = 21
    env.KEY_L = 22
    env.IsFirstTimePredicted = function() return true end
    function env.VectorRand()
        return Vector(math.random() * 2 - 1, math.random() * 2 - 1, math.random() * 2 - 1)
    end
    math.Rand = math.Rand or function(a, b) return a + (b - a) * math.random() end
    env.OBS_MODE_CHASE = 5
    env.COLLISION_GROUP_WEAPON = 11
    env.GESTURE_SLOT_CUSTOM = 6
    env.ACT_GMOD_GESTURE_ITEM_PLACE = 2003
    env.ACT_DRIVE_AIRBOAT = 1996
    env.MASK_PLAYERSOLID = 33636363
    env.RENDERGROUP_OPAQUE, env.RENDERGROUP_BOTH = 7, 9
    env.HUD_PRINTCONSOLE, env.HUD_PRINTTALK = 2, 3
    env.DMG_FALL = 32
    env.TEXT_ALIGN_LEFT, env.TEXT_ALIGN_CENTER = 0, 1
    env.TEXT_ALIGN_RIGHT, env.TEXT_ALIGN_TOP = 2, 3

    function env.isnumber(v) return type(v) == "number" end
    function env.isstring(v) return type(v) == "string" end
    function env.istable(v) return type(v) == "table" end
    function env.isfunction(v) return type(v) == "function" end
    function env.isbool(v) return type(v) == "boolean" end
    function env.IsValid(v)
        if v == nil or v == false then return false end
        local ok, iv = pcall(function() return v.IsValid end)
        if not ok or not iv then return false end
        return v:IsValid() and true or false
    end

    function env.Color(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end
    function env.Lerp(t, a, b) return a + (b - a) * t end
    function env.LerpVector(t, a, b) return a + (b - a) * t end
    function env.LerpAngle(t, a, b)
        local function l(x, y) return x + math.AngleDifference(y, x) * t end
        return Angle(l(a.p, b.p), l(a.y, b.y), l(a.r, b.r))
    end
    function env.CurTime() return world.time end
    function env.RealTime() return world.time end
    function env.FrameTime() return world.dt end

    function env.MsgN(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        R.log[#R.log + 1] = table.concat(parts)
    end
    env.Msg = env.MsgN
    env.print = function(...) env.MsgN(...) end
    function env.ErrorNoHalt(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        R.errors[#R.errors + 1] = table.concat(parts)
    end

    ----------------------------------------------------------------------
    -- hook / timer / concommand / convars
    ----------------------------------------------------------------------
    R.gm = {}    -- a stand-in GAMEMODE; tests put PlayerSpawnSENT and friends on it
    R.properties = {}
    env.properties = {
        Add = function(name, t) t.InternalName = name; R.properties[name] = t end,
        CanBeTargeted = function(ent, ply) return env.IsValid(ent) end,
    }
    env.gamemode = { Call = function(ev, ...)
        local r = env.hook.Run(ev, ...)
        if r == nil then return true end
        return r
    end }
    env.GAMEMODE = R.gm
    env.hook = {
        Add = function(ev, id, fn)
            R.hooks[ev] = R.hooks[ev] or {}
            R.hooks[ev][id] = fn
        end,
        Remove = function(ev, id)
            if R.hooks[ev] then R.hooks[ev][id] = nil end
        end,
        GetTable = function() return R.hooks end,
    }
    function env.hook.Call(ev, gm, ...)
        -- Deterministic order: GMod's is a hash walk, and a test must not
        -- depend on it any more than the addon does.
        local ids = {}
        for id in pairs(R.hooks[ev] or {}) do ids[#ids + 1] = id end
        table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
        for _, id in ipairs(ids) do
            local fn = R.hooks[ev][id]
            if fn then
                local a, b, c, d = fn(...)
                if a ~= nil then return a, b, c, d end
            end
        end
        if gm and gm[ev] then return gm[ev](gm, ...) end
    end
    function env.hook.Run(ev, ...) return env.hook.Call(ev, R.gm, ...) end

    env.timer = {
        Simple = function(delay, fn)
            R.timersCreated = (R.timersCreated or 0) + 1
            R.timers[#R.timers + 1] = { at = world.time + (delay or 0), fn = fn }
        end,
        Create = function(name, delay, reps, fn)
            -- Replaces a timer of the same name, as the engine does.
            for i = #R.timers, 1, -1 do
                if R.timers[i].name == name then table.remove(R.timers, i) end
            end
            R.timers[#R.timers + 1] = { at = world.time + delay, fn = fn,
                name = name, every = delay, reps = reps }
        end,
        Remove = function(name)
            for i = #R.timers, 1, -1 do
                if R.timers[i].name == name then table.remove(R.timers, i) end
            end
        end,
        Exists = function(name)
            for _, t in ipairs(R.timers) do if t.name == name then return true end end
            return false
        end,
    }

    env.concommand = { Add = function(name, fn) R.commands[name] = fn end }

    function env.CreateConVar(name, default, flags, help)
        if not SERVER and flags and bitlib.band(flags, env.FCVAR_REPLICATED) ~= 0 then
            -- The engine's rule, and the reason sh_config only creates these
            -- on the server. Enforced so a regression of that guard fails here.
            error("CreateConVar(" .. name .. ") with FCVAR_REPLICATED on the client")
        end
        if not world.convars[name] then
            world.convars[name] = newConVar(name, default, flags, help)
            world.convars[name].world = world
        end
        return world.convars[name]
    end
    function env.CreateClientConVar(name, default, save, userinfo, help)
        if not world.convars[name] then
            world.convars[name] = newConVar(name, default, 0, help)
            world.convars[name].world = world
            world.convars[name].userinfo = userinfo
        end
        return world.convars[name]
    end
    function env.GetConVar(name) return world.convars[name] end
    env.cvars = { AddChangeCallback = function(name, fn, id)
        world.cvarCallbacks[name] = world.cvarCallbacks[name] or {}
        world.cvarCallbacks[name][id or fn] = fn
    end }
    function env.RunConsoleCommand(name, ...)
        if world.convars[name] then world.convars[name]:SetString(...) return end
        if R.commands[name] then R.commands[name](nil, name, { ... }) end
    end

    ----------------------------------------------------------------------
    -- net: a wire both realms share, TYPE-CHECKED on read.
    ----------------------------------------------------------------------
    local out, inbox = nil, nil

    local function read(kind, bits)
        if not inbox then error("net.Read" .. kind .. " outside a receive", 3) end
        inbox.pos = inbox.pos + 1
        local item = inbox.items[inbox.pos]
        if not item then
            error(string.format("net.Read%s past the end of %q (%d fields written)",
                kind, inbox.name, #inbox.items), 3)
        end
        if item.kind ~= kind or item.bits ~= bits then
            error(string.format("net.Read%s(%s) at field %d of %q, but the sender " ..
                "wrote %s(%s): the two sides disagree about the wire format",
                kind, tostring(bits), inbox.pos, inbox.name, item.kind,
                tostring(item.bits)), 3)
        end
        return item.value
    end

    local CHECK = {
        Float = "number", Bool = "boolean", String = "string",
        UInt = "number", Int = "number",
    }
    local function write(kind, v, bits)
        if not out then error("net.Write" .. kind .. " outside net.Start", 3) end
        if CHECK[kind] and type(v) ~= CHECK[kind] then
            error(string.format("net.Write%s(%s)", kind, tostring(v)), 3)
        end
        if kind == "Float" and v ~= v then error("net.WriteFloat(NaN)", 3) end
        if kind == "UInt" and not (v >= 0 and v < 2 ^ bits and v == math.floor(v)) then
            error(string.format("net.WriteUInt(%s, %d) does not fit", tostring(v), bits), 3)
        end
        out.items[#out.items + 1] = { kind = kind, value = v, bits = bits }
    end

    env.net = {
        Start = function(name, unreliable)
            if SERVER and not R.netStrings[name] then
                error("net.Start(" .. name .. ") without util.AddNetworkString", 2)
            end
            out = { name = name, items = {}, from = which, unreliable = unreliable }
        end,
        -- Client -> server: the server realm's handler gets it, with the sender
        -- the test names in R.localPlayer.
        SendToServer = function()
            out.to = "server"
            world.wire[#world.wire + 1] = out
            out = nil
        end,
        Send = function(to)
            out.to = to
            world.wire[#world.wire + 1] = out
            out = nil
        end,
        Broadcast = function()
            world.wire[#world.wire + 1] = out
            out = nil
        end,
        SendPVS = function(pos)
            out.pvs = pos
            world.wire[#world.wire + 1] = out
            out = nil
        end,
        Receive = function(name, fn) R.netHandlers[name] = fn end,
    }
    for _, k in ipairs({ "Float", "Bool", "String", "Entity", "Vector" }) do
        env.net["Write" .. k] = function(v) write(k, v, nil) end
        env.net["Read" .. k]  = function() return read(k, nil) end
    end
    -- Bits are part of the format for the integer types.
    for _, k in ipairs({ "UInt", "Int" }) do
        env.net["Write" .. k] = function(v, bits) write(k, v, bits) end
        env.net["Read" .. k]  = function(bits) return read(k, bits) end
    end

    -- Deliver one message to this realm. Every field must be consumed: a reader
    -- that stops early is just as out of step with its writer as one that
    -- reads too far.
    function R:deliver(msg)
        local fn = self.netHandlers[msg.name]
        if not fn then error("no net.Receive for " .. msg.name) end
        inbox = { name = msg.name, items = msg.items, pos = 0 }
        local ok, err = pcall(fn, #msg.items, self.localPlayer)
        local pos = inbox.pos
        inbox = nil
        if not ok then error(err, 0) end
        if pos ~= #msg.items then
            error(string.format("%q: the receiver read %d of %d fields", msg.name,
                pos, #msg.items), 0)
        end
    end

    ----------------------------------------------------------------------
    -- util / physenv / engine / game / file / list / undo / cleanup
    ----------------------------------------------------------------------
    -- A HULL trace sweeps a box, as the engine's does: against the ground
    -- plane that is the plane moved out by the box's deepest corner, against
    -- a solid box it is that box grown by the hull (Minkowski). HitPos is the
    -- hull's centre where it stops. A line trace is a hull of zero size.
    local function trace(t)
        local s, e = t.start, t.endpos
        local hmin, hmax = t.mins or Vector(0, 0, 0), t.maxs or Vector(0, 0, 0)
        local res = { Hit = false, Fraction = 1, HitPos = e, HitNormal = Vector(groundNormal(world)),
                      StartPos = s, HitWorld = false }
        local nx, ny, nz = groundNormal(world)
        local deep = math.min(nx * hmin.x, nx * hmax.x) + math.min(ny * hmin.y, ny * hmax.y)
            + math.min(nz * hmin.z, nz * hmax.z)
        local hs, he = groundHeight(world, s) + deep, groundHeight(world, e) + deep
        if hs < 0 and groundAt(world, s) then
            res.Hit, res.Fraction, res.HitPos, res.StartSolid = true, 0, s, true
            res.HitWorld = true
            return res
        end
        if world.groundBumps then
            -- Not a plane: march for the first crossing, then bisect it.
            local function h(f) return groundHeight(world, s + (e - s) * f) + deep end
            local N, prevF, prevH = 12, 0, hs
            for i = 1, N do
                local f = i / N
                local hf = h(f)
                if prevH >= 0 and hf <= 0 then
                    local a, b = prevF, f
                    for _ = 1, 20 do
                        local m = (a + b) * 0.5
                        if h(m) > 0 then a = m else b = m end
                    end
                    local p = s + (e - s) * b
                    if groundAt(world, p) then
                        res.Hit, res.Fraction, res.HitPos = true, b, p
                        res.HitNormal = Vector(groundNormalAt(world, p))
                        res.HitWorld = true
                    end
                    break
                end
                prevF, prevH = f, hf
            end
        elseif hs >= 0 and he <= 0 and hs ~= he then
            local f = hs / (hs - he)
            local p = s + (e - s) * f
            if groundAt(world, p) then
                res.Hit, res.Fraction, res.HitPos = true, f, p
                res.HitWorld = true
            end
        end
        -- Nearest solid box along the segment (slab method).
        local best = res.Hit and res.Fraction or 1
        for _, b in ipairs(world.solids or {}) do
            local lo, hi = b[1] - hmax, b[2] - hmin
            if s.x >= lo.x and s.x <= hi.x and s.y >= lo.y and s.y <= hi.y
                and s.z >= lo.z and s.z <= hi.z then
                res.Hit, res.Fraction, res.HitPos, res.StartSolid = true, 0, s, true
                res.HitWorld = true
                return res
            end
            local t0, t1, nrm = 0, best, nil
            local ok = true
            for _, ax in ipairs({ "x", "y", "z" }) do
                local d = e[ax] - s[ax]
                if math.abs(d) < 1e-9 then
                    if s[ax] < lo[ax] or s[ax] > hi[ax] then ok = false break end
                else
                    local ta, tb = (lo[ax] - s[ax]) / d, (hi[ax] - s[ax]) / d
                    local sign = -1
                    if ta > tb then ta, tb, sign = tb, ta, 1 end
                    if ta > t0 then
                        t0 = ta
                        nrm = { x = 0, y = 0, z = 0 }
                        nrm[ax] = sign
                    end
                    if tb < t1 then t1 = tb end
                    if t0 > t1 then ok = false break end
                end
            end
            if ok and nrm and t0 < best then
                best = t0
                res.Hit, res.Fraction, res.HitPos = true, t0, s + (e - s) * t0
                res.HitNormal = Vector(nrm.x, nrm.y, nrm.z)
                res.HitWorld = true
            end
        end
        return res
    end
    R.trace = trace

    R.precached = {}
    env.util = {
        PrecacheModel = function(m) R.precached[m] = true end,
        TraceLine = function(t) return trace({ start = t.start, endpos = t.endpos,
            filter = t.filter, mask = t.mask }) end,
        TraceHull = trace,
        AddNetworkString = function(name) R.netStrings[name] = true end,
        PrecacheSound = function() end,
    }
    env.physenv = { GetGravity = function() return Vector(0, 0, -world.gravity) end }
    env.engine = { TickInterval = function() return world.dt end }
    env.game = {
        GetMap = function() return "gm_flatgrass" end,
        MaxPlayers = function() return 8 end,
        ConsoleCommand = function(s) R.log[#R.log + 1] = "console: " .. s end,
    }
    env.file = {
        Write = function(name, data) R.files[name] = data end,
        Read = function(name) return R.files[name] end,
        -- Base-game content is not on this machine. The headless suite owns
        -- the "does this sound ship with the game" question.
        Exists = function(name) return R.files[name] ~= nil end,
        CreateDir = function() end,
        IsDir = function() return true end,
    }
    -- JSON for FLAT tables of strings, numbers and booleans: all the addon's
    -- own files (data/bmx/server.json) are. Real GMod's util.TableToJSON
    -- handles nesting; this shim deliberately does not pretend to.
    env.util.TableToJSON = function(t)
        local keys = {}
        for k in pairs(t) do keys[#keys + 1] = k end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do
            local v = t[k]
            local enc
            if type(v) == "string" then enc = '"' .. v:gsub('[\\"]', '\\%0') .. '"'
            elseif type(v) == "number" or type(v) == "boolean" then enc = tostring(v)
            else error("the shim's TableToJSON is flat only: " .. k) end
            parts[#parts + 1] = '"' .. k .. '": ' .. enc
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    env.util.JSONToTable = function(s)
        if type(s) ~= "string" or not s:match("^%s*{.*}%s*$") then return nil end
        local t = {}
        for k, v in s:gmatch('"([^"]+)"%s*:%s*([^,}]+)') do
            v = v:gsub("%s+$", "")
            if v == "true" then t[k] = true
            elseif v == "false" then t[k] = false
            elseif tonumber(v) then t[k] = tonumber(v)
            else t[k] = (v:gsub('^"', ""):gsub('"$', "")) end
        end
        return t
    end
    env.list = { Set = function(group, key, val)
        R.lists[group] = R.lists[group] or {}
        R.lists[group][key] = val
    end, Get = function(group) return R.lists[group] or {} end }
    R.undo = {}
    env.undo = {
        Create = function(n) R.undo[#R.undo + 1] = { name = n, ents = {} } end,
        AddEntity = function(e) local u = R.undo[#R.undo]; u.ents[#u.ents + 1] = e end,
        SetPlayer = function(p) R.undo[#R.undo].ply = p end,
        Finish = function() R.undo[#R.undo].done = true end,
    }
    R.cleanup = { registered = {}, added = {} }
    env.cleanup = {
        Register = function(t) R.cleanup.registered[t] = true end,
        Add = function(ply, t, e) R.cleanup.added[#R.cleanup.added + 1] = { ply, t, e } end,
    }

    ----------------------------------------------------------------------
    -- Entities
    ----------------------------------------------------------------------
    local Ent = {}          -- methods every entity has
    local nextIndex = 1

    local NULL = setmetatable({}, { __index = function(_, k)
        if k == "IsValid" then return function() return false end end
        return function() error("attempt to call a method on NULL: " .. tostring(k), 2) end
    end, __tostring = function() return "[NULL Entity]" end })
    env.NULL = NULL
    R.NULL = NULL

    -- Lookup chain: instance -> scripted class -> its Base... -> engine class
    -- extras -> Ent.
    local function classChain(class)
        local chain, seen = {}, {}
        local c = class
        while c and R.stored[c] and not seen[c] do
            seen[c] = true
            chain[#chain + 1] = R.stored[c]
            c = R.stored[c].Base
        end
        return chain
    end

    local ENGINE = {}       -- engine classes' extra methods, by class
    R.ENGINE = ENGINE

    local function makeEntity(class)
        local chain = classChain(class)
        local engine = ENGINE[class]
        local e = { _class = class, _index = nextIndex, _nw = {},
                    _pos = Vector(), _f = Vector(1, 0, 0), _l = Vector(0, 1, 0),
                    _u = Vector(0, 0, 1), _deleteOnRemove = {} }
        nextIndex = nextIndex + 1
        setmetatable(e, { __index = function(t, k)
            for _, c in ipairs(chain) do
                local v = rawget(c, k)
                if v ~= nil then return v end
            end
            if engine and engine[k] ~= nil then return engine[k] end
            return Ent[k]
        end, __tostring = function(t)
            return string.format("Entity [%d][%s]", t._index, t._class)
        end })
        R.ents[#R.ents + 1] = e
        return e
    end
    R.makeEntity = makeEntity

    function Ent:IsValid() return not self._removed end
    function Ent:IsPlayer() return false end
    function Ent:EntIndex() return self._index end
    function Ent:GetClass() return self._class end
    function Ent:SetModel(m) self._model = m end
    function Ent:GetModel() return self._model end
    for _, k in ipairs({ "SetMoveType", "SetSolid", "SetCollisionBounds",
            "SetCustomCollisionCheck", "SetNoDraw", "DrawShadow", "SetKeyValue",
            "Activate", "SetRenderMode", "StopSound",
            "SetRenderBounds", "SetUseType" }) do
        Ent[k] = function() end
    end
    function Ent:SetNotSolid(b) self._notSolid = b end
    function Ent:SetColor(c) self._color = c end
    function Ent:SetMaterial(m) self._material = m end
    function Ent:GetMaterial() return self._material or "" end
    function Ent:GetColor() return self._color or { r = 255, g = 255, b = 255, a = 255 } end
    function Ent:SetNWVector(k, v) self._nw["nw_" .. k] = v end
    function Ent:GetNWVector(k, d) local v = self._nw["nw_" .. k]; if v == nil then return d end return v end
    function Ent:SetNWEntity(k, v) self._nw["nw_" .. k] = v end
    function Ent:GetNWEntity(k, d)
        local v = self._nw["nw_" .. k]
        if v == nil then return d end
        return v
    end
    -- ON A PHYSICS ENTITY THE BODY IS THE AUTHORITY, as in the engine: once
    -- it has a physics object, Entity:SetPos / SetAngles are overwritten by
    -- the body on the next step, so only PhysObj:SetPos / SetAngles move it.
    -- The shim used to honour the entity setters, and so passed a pick-up
    -- that the live server showed did nothing. Before Spawn (placement) they
    -- work, as they do in the engine.
    function Ent:SetPos(p)
        if rawget(self, "_phys") and self._spawned then return end
        self._pos = Vector(p)
    end
    function Ent:GetPos() return Vector(self._pos) end
    function Ent:SetAngles(a)
        if rawget(self, "_phys") and self._spawned then return end
        local f, r, u = VA.AngleVectors(a)
        self._f, self._l, self._u = f, -r, u
    end
    function Ent:GetAngles() return VA.BasisAngle(self._f, self._l, self._u) end
    function Ent:GetForward() return Vector(self._f) end
    function Ent:GetRight() return -self._l end
    function Ent:GetUp() return Vector(self._u) end
    function Ent:LocalToWorld(v)
        return self._pos + self._f * v.x + self._l * v.y + self._u * v.z
    end
    function Ent:WorldToLocal(p)
        local d = p - self._pos
        return Vector(d:Dot(self._f), d:Dot(self._l), d:Dot(self._u))
    end
    function Ent:LocalToWorldAngles(a)
        local lf, lr, lu = VA.AngleVectors(a)
        local ll = -lr
        local function w(v) return self._f * v.x + self._l * v.y + self._u * v.z end
        return VA.BasisAngle(w(lf), w(ll), w(lu))
    end
    function Ent:SetParent(p) self._parent = p end
    function Ent:GetParent() return self._parent or NULL end
    function Ent:DeleteOnRemove(o) self._deleteOnRemove[#self._deleteOnRemove + 1] = o end
    function Ent:NextThink(t) self._nextThink = t end
    function Ent:EmitSound(name, level, pitch, vol)
        R.sounds[#R.sounds + 1] = { ent = self, name = name, level = level,
                                    pitch = pitch, vol = vol }
    end
    function Ent:DrawModel() R.drawnModels = (R.drawnModels or 0) + 1 end
    function Ent:GetVelocity()
        if self._vel then return Vector(self._vel) end   -- a test's client copy
        return self._phys and Vector(self._phys.v) or Vector()
    end
    function Ent:Spawn()
        -- An engine prop gets a small box body, which is all the self-test
        -- and the headless `forces` case ask of one.
        if self._class == "prop_physics" and not self._phys then
            self:PhysicsInitBox(Vector(-6, -6, -6), Vector(6, 6, 6))
        end
        if self._class == "prop_ragdoll" and not self._phys then
            self:PhysicsInitBox(Vector(-8, -8, 0), Vector(8, 8, 16))
            self._phys:SetMass(80)
        end
        if self.SetupDataTables then self:SetupDataTables() end
        if self.Initialize then self:Initialize() end
        self._spawned = true
    end
    -- Model bounds, for the props the bot and the ramp finder put down: the
    -- real sizes of those base-game models, a 16 u cube for anything else.
    local MODEL_BOUNDS = {
        ["models/hunter/plates/plate4x4.mdl"]          = { Vector(-94.9, -94.9, -1.7), Vector(94.9, 94.9, 1.7) },
        ["models/hunter/plates/plate8x8.mdl"]          = { Vector(-189.8, -189.8, -1.7), Vector(189.8, 189.8, 1.7) },
        ["models/hunter/blocks/cube025x8x025.mdl"]     = { Vector(-5.9, -189.8, -5.9), Vector(5.9, 189.8, 5.9) },
        ["models/props_c17/signpole001.mdl"]           = { Vector(-1.4, -1.4, 0), Vector(1.4, 1.4, 110) },
    }
    function Ent:OBBMins()
        local b = MODEL_BOUNDS[self._model or ""]
        return b and Vector(b[1]) or Vector(-8, -8, -8)
    end
    function Ent:OBBMaxs()
        local b = MODEL_BOUNDS[self._model or ""]
        return b and Vector(b[2]) or Vector(8, 8, 8)
    end
    function Ent:WorldSpaceAABB()
        local mn, mx = self:OBBMins(), self:OBBMaxs()
        local lo = Vector(math.huge, math.huge, math.huge)
        local hi = Vector(-math.huge, -math.huge, -math.huge)
        for _, x in ipairs({ mn.x, mx.x }) do for _, y in ipairs({ mn.y, mx.y }) do for _, z in ipairs({ mn.z, mx.z }) do
            local w = self:LocalToWorld(Vector(x, y, z))
            lo = Vector(math.min(lo.x, w.x), math.min(lo.y, w.y), math.min(lo.z, w.z))
            hi = Vector(math.max(hi.x, w.x), math.max(hi.y, w.y), math.max(hi.z, w.z))
        end end end
        return lo, hi
    end
    function Ent:Remove()
        if self._removed then return end
        if self.OnRemove then self:OnRemove() end
        -- Removing a vehicle ejects its driver first, as the engine does.
        if self._driver and env.IsValid(self._driver) then self._driver:ExitVehicle() end
        self._removed = true
        for _, o in ipairs(self._deleteOnRemove) do
            if env.IsValid(o) then o:Remove() end
        end
    end
    function Ent:NetworkVar(kind, slot, name)
        local default = ({ Entity = NULL, Bool = false, Float = 0, Int = 0,
                           String = "", Vector = Vector(), Angle = Angle() })[kind]
        rawset(self, "Get" .. name, function(s)
            local v = s._nw[name]
            if v == nil then return default end
            if kind == "Entity" and not env.IsValid(v) then return NULL end
            return v
        end)
        rawset(self, "Set" .. name, function(s, v) s._nw[name] = v end)
    end

    function env.SafeRemoveEntity(e) if env.IsValid(e) then e:Remove() end end
    env.Entity = function(i)
        for _, e in ipairs(R.ents) do if e._index == i then return e end end
        return NULL
    end

    local function matchClass(pattern, class)
        local lp = "^" .. pattern:gsub("[%-%.%+%[%]%(%)%$%^%%%?]", "%%%0")
            :gsub("%*", ".*") .. "$"
        return class:match(lp) ~= nil
    end

    env.ents = {
        Create = function(class)
            if not SERVER then error("ents.Create on the client", 2) end
            return makeEntity(class)
        end,
        GetAll = function()
            local o = {}
            for _, e in ipairs(R.ents) do if not e._removed then o[#o + 1] = e end end
            return o
        end,
        FindInBox = function(mn, mx)
            local o = {}
            for _, e in ipairs(R.ents) do
                local p = e._pos
                if not e._removed and p.x >= mn.x and p.x <= mx.x and p.y >= mn.y
                    and p.y <= mx.y and p.z >= mn.z and p.z <= mx.z then
                    o[#o + 1] = e
                end
            end
            return o
        end,
        FindByClass = function(pattern)
            local o = {}
            for _, e in ipairs(R.ents) do
                if not e._removed and matchClass(pattern, e._class) then o[#o + 1] = e end
            end
            return o
        end,
    }

    env.scripted_ents = {
        Register = function(t, class) t.ClassName = class; R.stored[class] = t end,
        GetStored = function(class)
            return R.stored[class] and { t = R.stored[class] } or nil
        end,
        Get = function(class) return R.stored[class] end,
    }

    ----------------------------------------------------------------------
    -- Physics objects, and the plant that integrates them.
    ----------------------------------------------------------------------
    local Phys = {}
    Phys.__index = Phys
    R.Phys = Phys

    local INVALID_PHYS = setmetatable({}, { __index = function(_, k)
        if k == "IsValid" then return function() return false end end
        return function() end
    end })

    -- The stock hull's inertia, MEASURED from VPhysics on the live server and
    -- recorded in sh_config.lua: 9,299 / 11,837 / 7,353 kg*u^2 at 86 kg. A
    -- solid box of the same bounds gives something a little different, so the
    -- plant uses the box formula scaled by the measured-to-box ratio per axis:
    -- exact for the stock hull, and in proportion for a bike that overrides it.
    local MEASURED = { 9299, 11837, 7353 }
    local function boxI(m, dx, dy, dz)
        return m / 12 * (dy * dy + dz * dz), m / 12 * (dx * dx + dz * dz),
               m / 12 * (dx * dx + dy * dy)
    end
    local SX, SY, SZ = boxI(86, 32, 8, 36)
    local KX, KY, KZ = MEASURED[1] / SX, MEASURED[2] / SY, MEASURED[3] / SZ

    -- A body made of boxes. The mass centre is their VOLUME centre, as
    -- VPhysics computes it for a uniform-density shape.
    local function makeBody(ent, boxes)
        local vol, m = 0, Vector()
        local lo = Vector(math.huge, math.huge, math.huge)
        local hi = -lo
        for _, b in ipairs(boxes) do
            local d = b[2] - b[1]
            local v = d.x * d.y * d.z
            vol, m = vol + v, m + (b[1] + b[2]) * 0.5 * v
            lo = Vector(math.min(lo.x, b[1].x), math.min(lo.y, b[1].y), math.min(lo.z, b[1].z))
            hi = Vector(math.max(hi.x, b[2].x), math.max(hi.y, b[2].y), math.max(hi.z, b[2].z))
        end
        local p = setmetatable({
            ent = ent, mass = 1, mc = m / vol, boxes = boxes, volume = vol,
            dims = hi - lo, mn = lo, mx = hi,
            v = Vector(), w = Vector(),
            gravity = true, motion = true, asleep = false,
            linDamp = 0, angDamp = 0,
        }, Phys)
        ent._phys = p
        return true
    end

    function Ent:PhysicsInitBox(mn, mx)
        return makeBody(self, { { Vector(mn), Vector(mx) } })
    end
    -- Only boxes are handed in by this addon: each vertex list is read back
    -- as its bounding box.
    function Ent:PhysicsInitMultiConvex(meshes)
        local boxes = {}
        for _, verts in ipairs(meshes) do
            local lo = Vector(math.huge, math.huge, math.huge)
            local hi = -lo
            for _, v in ipairs(verts) do
                lo = Vector(math.min(lo.x, v.x), math.min(lo.y, v.y), math.min(lo.z, v.z))
                hi = Vector(math.max(hi.x, v.x), math.max(hi.y, v.y), math.max(hi.z, v.z))
            end
            boxes[#boxes + 1] = { lo, hi }
        end
        return makeBody(self, boxes)
    end
    function Ent:EnableCustomCollisions() end
    function Ent:GetPhysicsObject() return self._phys or INVALID_PHYS end
    function Ent:StartMotionController() self._controller = true end
    function Ent:AddToMotionController(p) self._controlled = p end

    function Phys:IsValid() return env.IsValid(self.ent) end
    function Phys:SetMass(m) self.mass = m end
    function Phys:GetMass() return self.mass end
    function Phys:SetMaterial(m) self.material = m end
    function Phys:GetMassCenter() return Vector(self.mc) end
    function Phys:EnableDrag(b) self.drag = b end
    function Phys:SetDamping(l, a) self.linDamp, self.angDamp = l, a end
    function Phys:EnableMotion(b) self.motion = b end
    function Phys:EnableGravity(b) self.gravity = b end
    function Phys:EnableCollisions(b) self.collisions = b end
    function Phys:Wake() self.asleep = false end
    function Phys:Sleep() self.asleep = true end
    function Phys:LocalToWorld(v) return self.ent:LocalToWorld(v) end
    function Phys:GetVelocity() return Vector(self.v) end
    function Phys:SetVelocity(v) self.v = Vector(v) end
    -- GMod's angle velocity is LOCAL and in DEGREES per second.
    function Phys:SetAngleVelocity(v)
        local e, r = self.ent, math.rad
        self.w = e._f * r(v.x) + e._l * r(v.y) + e._u * r(v.z)
    end
    function Phys:GetPos() return self.ent:GetPos() end
    function Phys:SetPos(p) self.ent._pos = Vector(p) end
    function Phys:SetAngles(a)
        local f, r, u = VA.AngleVectors(a)
        self.ent._f, self.ent._l, self.ent._u = f, -r, u
    end
    function Phys:GetAngles() return self.ent:GetAngles() end

    -- Principal moments in kg*UNITS^2, as (roll, pitch, yaw): every box's own
    -- moment plus its parallel-axis term about the mass centre, scaled by the
    -- measured-to-box ratios (exact for the old single stock box).
    function Phys:InertiaU2()
        local X, Y, Z = 0, 0, 0
        for _, b in ipairs(self.boxes) do
            local d = b[2] - b[1]
            local mi = self.mass * (d.x * d.y * d.z) / self.volume
            local x, y, z = boxI(mi, d.x, d.y, d.z)
            local c = (b[1] + b[2]) * 0.5 - self.mc
            X = X + x + mi * (c.y * c.y + c.z * c.z)
            Y = Y + y + mi * (c.x * c.x + c.z * c.z)
            Z = Z + z + mi * (c.x * c.x + c.y * c.y)
        end
        return Vector(X * KX, Y * KY, Z * KZ)
    end
    -- What GetInertia returns: kg*METRES^2, as VPhysics does.
    function Phys:GetInertia() return self:InertiaU2() / ((1 / 0.0254) ^ 2) end

    function Phys:COM() return self.ent:LocalToWorld(self.mc) end
    function Phys:GetVelocityAtPoint(p)
        return self.v + self.w:Cross(p - self:COM())
    end

    -- World-space inverse inertia applied to an angular impulse.
    function Phys:invI(L)
        local e, I = self.ent, self:InertiaU2()
        return e._f * (L:Dot(e._f) / I.x)
             + e._l * (L:Dot(e._l) / I.y)
             + e._u * (L:Dot(e._u) / I.z)
    end

    -- IMPULSE semantics, which is what the addon's `forces` case establishes
    -- the real engine has: dv = J/m.
    function Phys:ApplyForceCenter(J)
        if not self.motion then return end
        self.v = self.v + J / self.mass
        R.impulses = (R.impulses or 0) + 1
    end
    function Phys:ApplyForceOffset(J, at)
        if not self.motion then return end
        self.v = self.v + J / self.mass
        self.w = self.w + self:invI((at - self:COM()):Cross(J))
        R.impulses = (R.impulses or 0) + 1
    end

    local function rotate(v, axis, ang)
        local c, s = math.cos(ang), math.sin(ang)
        return v * c + axis:Cross(v) * s + axis * (axis:Dot(v) * (1 - c))
    end

    -- The hull against the ground: one-sided impulse contact at each
    -- penetrating corner, with friction, then a position correction. Crude on
    -- purpose. Its job is to stop a fallen bike falling through the floor and
    -- to report an impact the way VPhysics reports one to PhysicsCollide.
    local CORNERS = {}
    for _, x in ipairs({ 0, 1 }) do for _, y in ipairs({ 0, 1 }) do for _, z in ipairs({ 0, 1 }) do
        CORNERS[#CORNERS + 1] = { x, y, z }
    end end end

    local function contact(p, dt)
        local e = p.ent
        local n = Vector(groundNormal(world))
        local deepest, impact, impactAt = 0, 0, nil
        local pts = {}
        for _, b in ipairs(p.boxes) do
            for _, c in ipairs(CORNERS) do
                pts[#pts + 1] = Vector(c[1] == 0 and b[1].x or b[2].x,
                                       c[2] == 0 and b[1].y or b[2].y,
                                       c[3] == 0 and b[1].z or b[2].z)
            end
        end
        for _, lc in ipairs(pts) do
            local wc = e:LocalToWorld(lc)
            local h = groundHeight(world, wc)
            if world.groundBumps then n = Vector(groundNormalAt(world, wc)) end
            if h < 0 and groundAt(world, wc) then
                deepest = math.max(deepest, -h)
                local r  = wc - p:COM()
                local vp = p.v + p.w:Cross(r)
                local vn = vp:Dot(n)
                if vn < 0 then
                    if -vn > impact then impact, impactAt = -vn, wc end
                    local rn = r:Cross(n)
                    local k = 1 / p.mass + rn:Dot(p:invI(rn))
                    local j = -vn * 1.1 / k
                    p.v = p.v + n * (j / p.mass)
                    p.w = p.w + p:invI(r:Cross(n * j))
                    -- Friction, capped by the normal impulse.
                    local vt = vp - n * vn
                    local vtl = vt:Length()
                    if vtl > 1e-3 then
                        local t = vt / vtl
                        local rt = r:Cross(t)
                        local kt = 1 / p.mass + rt:Dot(p:invI(rt))
                        -- Friction by surface, as VPhysics does it: the
                        -- addon's ice hull slides, anything else grips.
                        local mu = (p.material == "gmod_ice") and 0.05 or 0.8
                        local jt = math.min(vtl / kt, mu * j)
                        p.v = p.v - t * (jt / p.mass)
                        p.w = p.w - p:invI(r:Cross(t * jt))
                    end
                end
            end
        end
        if deepest > 0 then e._pos = e._pos + n * deepest end
        return impact, impactAt
    end

    local function integrate(p, dt)
        if not p.motion then return end
        local e = p.ent
        if p.gravity then p.v = p.v - Vector(0, 0, world.gravity * dt) end
        if p.angDamp > 0 then p.w = p.w * (1 - math.min(p.angDamp * dt, 1)) end

        local com = p:COM() + p.v * dt
        local wl = p.w:Length()
        if wl > 1e-9 then
            local axis, ang = p.w / wl, wl * dt
            local f, l, u = rotate(e._f, axis, ang), rotate(e._l, axis, ang), rotate(e._u, axis, ang)
            -- Gram-Schmidt, so rounding cannot shear the frame over a long run.
            f = f:GetNormalized()
            l = (l - f * l:Dot(f)):GetNormalized()
            u = f:Cross(l)
            e._f, e._l, e._u = f, l, u
        end
        e._pos = com - (e._f * p.mc.x + e._l * p.mc.y + e._u * p.mc.z)

        local impact, at = contact(p, dt)
        if impact > 30 and e.PhysicsCollide then
            e:PhysicsCollide({ Speed = impact, HitEntity = NULL,
                               HitPos = at, OurOldVelocity = Vector(p.v) }, p)
        end
    end
    R.integrate = integrate

    ----------------------------------------------------------------------
    -- Players and vehicles
    ----------------------------------------------------------------------
    -- A ragdoll: one real body, which is enough to be thrown, fall and slide.
    local Rag = {}
    ENGINE.prop_ragdoll = Rag
    function Rag:GetPhysicsObjectCount() return 1 end
    function Rag:GetPhysicsObjectNum(i) return i == 0 and self._phys or nil end
    function Rag:TranslatePhysBoneToBone(i) return i end
    function Rag:SetCollisionGroup(g) self._group = g end
    function Rag:SetSkin(n) self._skin = n end
    function Rag:SetBodygroup(i, v) self._bg = self._bg or {}; self._bg[i] = v end

    local Ply = {}
    ENGINE.player = Ply
    local Pod = {}
    ENGINE.prop_vehicle_prisoner_pod = Pod

    function Pod:GetDriver() return self._driver or NULL end
    function Pod:IsVehicle() return true end

    function Ply:IsPlayer() return true end
    -- Seated, a player is where their vehicle is, as in the engine.
    function Ply:GetPos()
        local v = self._vehicle
        if v and v.IsValid and v:IsValid() then return v:GetPos() end
        return Vector(self._pos)
    end
    -- Enough of a living player for a crash to take apart and put back:
    -- health, armour, weapons (the gamemode's loadout on every Spawn), ammo,
    -- spectating, and a stock skeleton to read bone positions from.
    local Wep = {}
    Wep.__index = Wep
    function Wep:GetClass() return self.class end
    function Wep:IsValid() return true end
    local function wep(c) return setmetatable({ class = c }, Wep) end
    local LOADOUT = { "weapon_physgun", "gmod_tool" }
    function Ply:Health() return self._health or 100 end
    function Ply:SetHealth(h) self._health = h end
    function Ply:Armor() return self._armor or 0 end
    function Ply:SetArmor(a) self._armor = a end
    function Ply:GetModel() return self._model or "models/player/kleiner.mdl" end
    function Ply:GetSkin() return self._skin or 0 end
    function Ply:GetNumBodyGroups() return 3 end
    function Ply:GetBodygroup(i) return (self._bg or {})[i] or 0 end
    function Ply:GetPlayerColor() return self._pcol or Vector(0.24, 0.34, 0.41) end
    function Ply:Alive() return (self._health or 100) > 0 end
    function Ply:GetWeapons()
        local o = {}
        for _, c in ipairs(self._weapons or {}) do o[#o + 1] = wep(c) end
        return o
    end
    function Ply:Give(c)
        self._weapons = self._weapons or {}
        self._weapons[#self._weapons + 1] = c
    end
    function Ply:StripWeapons() self._weapons, self._activeWep = {}, nil end
    function Ply:SelectWeapon(c) self._activeWep = c end
    function Ply:GetActiveWeapon() return self._activeWep and wep(self._activeWep) or NULL end
    function Ply:GetAmmo() return table.Copy(self._ammo or {}) end
    function Ply:SetAmmo(n, id) self._ammo = self._ammo or {}; self._ammo[id] = n end
    function Ply:RemoveAllAmmo() self._ammo = {} end
    function Ply:Spectate(mode) self._spectating = mode end
    function Ply:SpectateEntity(e) self._spectatee = e end
    function Ply:UnSpectate() self._spectating, self._spectatee = nil, nil end
    function Ply:Spawn()
        self._spawns = (self._spawns or 0) + 1
        self._health, self._armor = 100, 0
        self._weapons = { unpack(LOADOUT) }
        self._activeWep = LOADOUT[1]
        self._ammo = {}
    end
    function Ply:SetEyeAngles(a) self._eyeAngles = a end
    function Ply:GetBonePosition(b)
        local m = self:GetBoneMatrix(b)
        if not m then return self:GetPos() + Vector(0, 0, 40), Angle() end
        return m:GetTranslation(), m:GetAngles()
    end
    function Ply:GetGroundEntity() return self._groundEnt or NULL end
    function Ply:GetObserverTarget() return self._spectatee or NULL end
    function Ply:GetObserverMode() return self._spectating or 0 end
    function Ply:AnimRestartGesture(slot, act) self._gesture = act end
    function Ply:Nick() return self._nick end
    function Ply:Name() return self._nick end
    function Ply:IsBot() return self._bot end
    function Ply:IsSuperAdmin() return self._superadmin or false end
    function Ply:IsAdmin() return self._superadmin or self._admin or false end
    -- Kicked: gone from the server, as a disconnect.
    function Ply:Kick(reason)
        self._kicked = reason or ""
        if env.IsValid(self:GetVehicle()) then self:ExitVehicle() end
        env.hook.Run("PlayerDisconnected", self)
        self._removed = true
    end
    function Ply:Alive() return true end
    function Ply:GetVehicle() return self._vehicle or NULL end
    function Ply:InVehicle() return env.IsValid(self._vehicle) end
    function Ply:EnterVehicle(veh)
        if not env.IsValid(veh) or env.IsValid(veh._driver) then return end
        self._vehicle, veh._driver = veh, self
        env.hook.Run("PlayerEnteredVehicle", self, veh, 0)
    end
    function Ply:ExitVehicle()
        local veh = self._vehicle
        if not veh then return end
        env.hook.Run("PlayerLeaveVehicle", self, veh)
        self._vehicle, veh._driver = nil, nil
    end
    function Ply:SetVelocity(v) self._velocity = (self._velocity or Vector()) + v end
    function Ply:TakeDamageInfo(d)
        self._damage = (self._damage or 0) + d:GetDamage()
        self._health = (self._health or 100) - d:GetDamage()
    end
    function Ply:ChatPrint(s)
        self._chat = self._chat or {}
        self._chat[#self._chat + 1] = s
    end
    function Ply:PrintMessage(_, s) self:ChatPrint(s) end
    function Ply:GetEyeTrace() return self._eyeTrace or { Hit = false } end
    function Ply:EyeAngles() return self._eyeAngles or Angle() end
    -- Bones: the seated skeleton in lib/skeleton.lua, posed in the seat.
    -- Manipulations compose as the engine's do, and are also RECORDED by
    -- bone name (ply._bones) for tests that only care what was asked for.
    function Ply:LookupBone(name) return SK.INDEX[name] end
    function Ply:LookupSequence(name)
        if self._noSequences then return -1 end
        return name == "drive_airboat" and 42 or -1
    end
    function Ply:ManipulateBoneAngles(b, a)
        self._manip = self._manip or {}
        self._manip[b] = Angle(a.p, a.y, a.r)
        self._bones = self._bones or {}
        self._bones[SK.BONES[b][1]] = self._manip[b]
        self._pose = nil
    end
    function Ply:GetManipulateBoneAngles(b)
        local a = (self._manip or {})[b]
        return a and Angle(a.p, a.y, a.r) or Angle()
    end
    -- The root sits in the seat, facing where the seat faces: a seat model
    -- seats its occupant looking down its own +Y.
    local function rootPose(ply)
        local v = ply._vehicle
        if v and v.IsValid and v:IsValid() then
            return v:GetPos(), v:LocalToWorldAngles(Angle(0, 90, 0))
        end
        return ply:GetPos(), Angle(0, ply:EyeAngles().y, 0)
    end
    function Ply:SetupBones()
        local pos, ang = rootPose(self)
        self._pose = SK.pose(pos, ang, self._manip or {})
        R.setupBones = (R.setupBones or 0) + 1
    end
    function Ply:InvalidateBoneCache() self._pose = nil end
    function Ply:GetBoneMatrix(b)
        if not self._pose then self:SetupBones() end
        local m = self._pose[b]
        return m and m:Copy() or nil
    end
    function Ply:GetBoneCount() return #SK.BONES end
    -- The server telling this player's client to run a command. For a
    -- convar, that sets it, and (a userinfo convar) GetInfo then reports it.
    function Ply:ConCommand(line)
        self._concommands = self._concommands or {}
        self._concommands[#self._concommands + 1] = line
        local name, val = line:match("^(%S+)%s+(.*)$")
        if name then self._info = self._info or {}; self._info[name] = val end
    end
    function Ply:GetInfo(name)
        if self._info and self._info[name] ~= nil then return self._info[name] end
        local cv = world.convars[name]
        return cv and cv:GetString() or ""
    end
    function Ply:GetInfoNum(name, def)
        if self._info and self._info[name] ~= nil then return tonumber(self._info[name]) or def end
        local cv = world.convars[name]
        return cv and cv:GetFloat() or def
    end

    function R:player(nick, opts)
        opts = opts or {}
        local p = makeEntity("player")
        p._nick, p._bot = nick or "Player", opts.bot or false
        -- Somewhere out of the way: a player standing at the origin would be
        -- "touching" every bike a test spawns there.
        p:SetPos(Vector(5000, 5000, 0))
        p._superadmin = opts.superadmin
        self.players[#self.players + 1] = p
        return p
    end

    -- Both realms can ask whether a model is mounted; a test takes one away
    -- with R.missingModels (the client's own block below redefines the same).
    R.missingModels = R.missingModels or {}
    env.util.IsValidModel = env.util.IsValidModel or function(m) return not R.missingModels[m] end

    env.player = {
        GetAll = function()
            local o = {}
            for _, p in ipairs(R.players) do if env.IsValid(p) then o[#o + 1] = p end end
            return o
        end,
        GetHumans = function()
            local o = {}
            for _, p in ipairs(R.players) do
                if env.IsValid(p) and not p._bot then o[#o + 1] = p end
            end
            return o
        end,
        CreateNextBot = function(name) return R:player(name, { bot = true }) end,
    }

    function env.DamageInfo()
        local d = { dmg = 0 }
        function d:SetDamage(v) self.dmg = v end
        function d:GetDamage() return self.dmg end
        function d:SetDamageType(t) self.type = t end
        function d:SetAttacker(a) self.attacker = a end
        function d:SetInflictor(a) self.inflictor = a end
        return d
    end

    ----------------------------------------------------------------------
    -- duplicator
    ----------------------------------------------------------------------
    env.duplicator = {
        RegisterEntityClass = function(class, fn, ...)
            R.dupe[class] = { fn = fn, args = { ... } }
        end,
        Copy = function(ent)
            -- ONE entity table, as the real Copy returns. Paste wants a list.
            return { Class = ent:GetClass(), Pos = ent:GetPos(), Angle = ent:GetAngles(),
                     EntityMods = table.Copy(ent.EntityMods or {}) }
        end,
        StoreEntityModifier = function(ent, key, data)
            ent.EntityMods = ent.EntityMods or {}
            ent.EntityMods[key] = data
        end,
        RegisterEntityModifier = function(key, fn) R.dupeMods = R.dupeMods or {}; R.dupeMods[key] = fn end,
        Paste = function(ply, list)
            local out = {}
            for idx, data in pairs(list) do
                if type(data) ~= "table" or not data.Class then
                    error("duplicator.Paste wants a LIST of entity tables", 2)
                end
                local reg = R.dupe[data.Class]
                if reg then
                    out[idx] = reg.fn(ply, data)
                    for key, mod in pairs(data.EntityMods or {}) do
                        local fn = (R.dupeMods or {})[key]
                        if fn and out[idx] then fn(ply, out[idx], mod) end
                    end
                end
            end
            return out, {}
        end,
        DoGeneric = function(e, data)
            if data.Pos then e:SetPos(data.Pos) end
            if data.Angle then e:SetAngles(data.Angle) end
        end,
        DoGenericPhysics = function() end,
    }

    ----------------------------------------------------------------------
    -- Client-only drawing surface. Counted rather than rendered: a test wants
    -- to know that Draw ran to the end and drew something, not what it looked
    -- like.
    ----------------------------------------------------------------------
    if not SERVER then
        env.surface = { CreateFont = function() end, SetFont = function() end,
                        GetTextSize = function() return 10, 10 end,
                        SetDrawColor = function() end,
                        DrawRect = function(x, y, w, h) R.rects = R.rects or {}
                            R.rects[#R.rects + 1] = { x = x, y = y, w = w, h = h } end }
        env.draw = {
            RoundedBox = function() R.boxes = (R.boxes or 0) + 1 end,
            SimpleText = function(t) R.texts[#R.texts + 1] = tostring(t) end,
        }
        env.render = {
            DrawLine = function(a, b)
                assert(VA.isvector(a) and VA.isvector(b), "render.DrawLine wants vectors")
                assert(a.x == a.x and b.x == b.x, "render.DrawLine got a NaN")
                R.lines = R.lines + 1
            end,
            SetColorMaterial = function() end,
            SetColorModulation = function(r, g, b) R.colorMod = { r, g, b } end,
            -- Beams and boxes are the procedural bike's whole vocabulary, so
            -- they are RECORDED: a test can ask where the frame was drawn.
            DrawBeam = function(a, b, w, s0, s1, col)
                assert(VA.isvector(a) and VA.isvector(b), "render.DrawBeam wants vectors")
                assert(a.x == a.x and b.x == b.x and a.z == a.z and b.z == b.z,
                    "render.DrawBeam got a NaN")
                assert(type(w) == "number" and w > 0, "render.DrawBeam width")
                R.beams[#R.beams + 1] = { a = a, b = b, w = w, col = col }
            end,
            DrawBox = function(pos, ang, mn, mx, col)
                assert(VA.isvector(pos) and VA.isangle(ang), "render.DrawBox wants pos, ang")
                R.boxes3d = (R.boxes3d or 0) + 1
            end,
            DrawSphere = function() end,
        }
        env.cam = { PushModelMatrix = function() end, PopModelMatrix = function() end }
        env.Matrix = SK.Matrix
        env.ScrW = function() return 1920 end
        env.ScrH = function() return 1080 end
        env.LocalPlayer = function() return R.localPlayer or NULL end
        env.EyePos = function()
            return R.eyePos or (R.localPlayer and R.localPlayer:GetPos()) or Vector()
        end

        -- Clientside models: RECORDED, with where they were drawn, so a test
        -- can ask whether a tyre is round and on its axle. `R.missingModels`
        -- lets a test take a model away and check the fallback.
        R.csModels, R.drawnCS, R.missingModels = {}, {}, {}
        env.util.IsValidModel = function(m) return not R.missingModels[m] end
        function env.ClientsideModel(model)
            R.csAttempts = (R.csAttempts or 0) + 1
            if R.missingModels[model] then return nil end
            local m = { model = model, removed = false }
            function m:IsValid() return not self.removed end
            function m:Remove() self.removed = true end
            function m:SetNoDraw(b) self.nodraw = b end
            function m:SetPos(p) self.pos = p end
            function m:SetAngles(a) self.ang = a end
            function m:EnableMatrix(k, mat) self.matrix = mat end
            function m:SetupBones() end
            function m:SetMaterial(mat) self.material = mat end
            function m:DrawModel()
                assert(not self.removed, "drew a removed clientside model")
                local cm = R.colorMod or { 1, 1, 1 }
                local col = { r = math.floor(cm[1] * 255 + 0.5), g = math.floor(cm[2] * 255 + 0.5),
                              b = math.floor(cm[3] * 255 + 0.5) }
                local sc = self.matrix and self.matrix.s or Vector(1, 1, 1)
                R.drawnCS[#R.drawnCS + 1] = { model = self.model, pos = self.pos, ang = self.ang,
                                              scale = sc, col = col, material = self.material }
                -- A cylinder is a TUBE: recorded as the same {a, b, w, col}
                -- segment a beam is, so geometry tests read either path.
                if self.model == "models/xqm/cylinderx1.mdl" then
                    local f = self.ang:Forward()
                    local half = sc.x * 12.5 * 0.5
                    R.beams[#R.beams + 1] = { a = self.pos - f * half, b = self.pos + f * half,
                                              w = sc.y * 12.5, col = col, cylinder = true }
                end
            end
            R.csModels[#R.csModels + 1] = m
            return m
        end
        R.patches = {}
        R.particles = {}
        function env.ParticleEmitter(pos)
            local em = { pos = pos }
            function em:Add(mat, p)
                local part = { mat = mat, pos = p }
                for _, k in ipairs({ "SetVelocity", "SetDieTime", "SetStartAlpha", "SetEndAlpha",
                        "SetStartSize", "SetEndSize", "SetRoll", "SetRollDelta", "SetAirResistance",
                        "SetStartLength", "SetEndLength", "SetGravity", "SetCollide", "SetBounce" }) do
                    part[k] = function(self, v) self[k:sub(4)] = v end
                end
                function part:SetColor(r, g, b) self.color = { r = r, g = g, b = b } end
                R.particles[#R.particles + 1] = part
                return part
            end
            function em:Finish() self.finished = true end
            return em
        end
        function env.CreateSound(ent, path)
            local s = { path = path, playing = false, vol = 1, pitch = 100, ent = ent }
            function s:PlayEx(v, p) self.playing, self.vol, self.pitch = true, v, p end
            function s:Play() self.playing = true end
            function s:Stop() self.playing = false end
            function s:IsPlaying() return self.playing end
            function s:ChangeVolume(v) self.vol = v end
            function s:ChangePitch(p) self.pitch = p end
            function s:SetSoundLevel(l) self.level = l end
            R.patches[#R.patches + 1] = s
            return s
        end

        -- A client-side copy of a server entity: same class, same position,
        -- and the networked vars a test sets by hand, which is all the client
        -- ever receives.
        function R:clientEntity(class)
            local e = makeEntity(class)
            if e.SetupDataTables then e:SetupDataTables() end
            if e.Initialize then e:Initialize() end
            return e
        end
    end

    ----------------------------------------------------------------------
    -- Loading files
    ----------------------------------------------------------------------
    local dirStack = {}

    local function readFile(rel)
        local fh = io.open(M.ROOT .. "/lua/" .. rel, "r")
        if not fh then return nil end
        local src = fh:read("*a")
        fh:close()
        return src
    end

    local function resolve(path)
        local cur = dirStack[#dirStack]
        if cur then
            local rel = cur .. "/" .. path
            if readFile(rel) then return rel end
        end
        if readFile(path) then return path end
        error("include: cannot find " .. path .. " (from " .. tostring(cur) .. ")", 3)
    end

    function R:runFile(rel)
        local src = readFile(rel)
        if not src then error("no such file lua/" .. rel) end
        local chunk, err = loadstring(src, "@lua/" .. rel)
        if not chunk then error(err, 0) end
        setfenv(chunk, env)
        dirStack[#dirStack + 1] = rel:match("^(.*)/[^/]*$") or ""
        self.loaded[#self.loaded + 1] = rel
        local ok, e = pcall(chunk)
        table.remove(dirStack)
        if not ok then error(e, 0) end
    end

    function env.include(path) R:runFile(resolve(path)) end
    function env.AddCSLuaFile(path)
        local rel
        if path == nil then
            -- No argument sends the file currently being run.
            rel = R.loaded[#R.loaded]
            for i = #R.loaded, 1, -1 do
                local d = R.loaded[i]:match("^(.*)/[^/]*$") or ""
                if d == dirStack[#dirStack] then rel = R.loaded[i] break end
            end
        else
            rel = resolve(path)
        end
        R.csfiles[rel] = true
    end

    -- Load a scripted entity the way the engine does: a fresh ENT, the realm's
    -- entry file, then register.
    function R:loadEntity(class)
        env.ENT = { Folder = "entities/" .. class }
        self:runFile("entities/" .. class .. (SERVER and "/init.lua" or "/cl_init.lua"))
        env.scripted_ents.Register(env.ENT, class)
        env.ENT = nil
    end

    -- The whole addon, in the engine's order: autorun, then entities, then one
    -- tick so the deferred work in sh_bikes (derive) runs.
    function R:boot()
        self:runFile("autorun/bmx_init.lua")
        self:loadEntity("bmx_base")
        self:loadEntity("bmx_city_solid")
        env.hook.Run("InitPostEntity")
        self:runTimers()
        return self
    end

    ----------------------------------------------------------------------
    -- Time
    ----------------------------------------------------------------------
    function R:runTimers()
        local i = 1
        while i <= #self.timers do
            local t = self.timers[i]
            if t.at <= world.time then
                table.remove(self.timers, i)
                t.fn()
                if t.every and (t.reps == 0 or (t.reps or 1) > 1) then
                    t.at = world.time + t.every
                    if t.reps and t.reps > 0 then t.reps = t.reps - 1 end
                    table.insert(self.timers, t)
                end
            else
                i = i + 1
            end
        end
    end

    -- One server tick: physics substep (the motion controller, then the
    -- plant), timers, the Think hook, and every entity's Think on its own
    -- schedule. The server owns the clock.
    function R:tick()
        world.time = world.time + world.dt
        local dt = world.dt
        for _, e in ipairs(self.ents) do
            local p = rawget(e, "_phys")
            if not e._removed and p then
                if e._controlled and e.PhysicsSimulate and p.motion then
                    e:PhysicsSimulate(p, dt)
                end
                if not e._removed then integrate(p, dt) end
            end
        end
        self:runTimers()
        env.hook.Run("Think")
        for _, e in ipairs(self.ents) do
            if not e._removed and e._spawned and e.Think then
                if world.time >= (e._nextThink or 0) then
                    e._nextThink = world.time
                    e:Think()
                end
            end
        end
    end

    function R:run(seconds, each)
        local n = math.max(1, math.floor(seconds / world.dt + 0.5))
        for _ = 1, n do
            self:tick()
            if each and each() then return true end
        end
        return false
    end

    function R:command(name, ply, ...)
        local fn = self.commands[name]
        if not fn then error("no concommand " .. name) end
        return fn(ply, name, { ... })
    end

    return R
end

return M
