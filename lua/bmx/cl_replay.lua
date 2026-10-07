--[[--------------------------------------------------------------------------
    bmx/cl_replay.lua

    REPLAYS AND A CLIP CAMERA (G28). Watch your last line back from any angle,
    and save it for a friend.

        bmx_replay                 start / stop watching the last 30 seconds
                                   (also J, or any key you bind; bmx_replay_key)
        bmx_replay_mode <m>        chase | free | filmer | follow
        bmx_replay_speed <x>       0.1 .. 2 (negative plays it backwards)
        bmx_replay_seek <s|n%>     jump to a second, or a percentage
        bmx_replay_pause           pause / resume
        bmx_replay_save [name]     data/bmx/replays/<name>.txt
        bmx_replay_load <name>     watch a saved one (same map only)
        bmx_replay_list            what is saved

    While it plays: P pause, LEFT / RIGHT scrub a second, UP / DOWN speed,
    1-4 the four cameras. In the free camera: WASD fly, Space / Ctrl up and
    down, Shift fast. Your bike gets NO input while a replay plays, so it
    coasts to a stop: stop the replay with the same key to ride again.

    ENTIRELY CLIENT-SIDE. The bikes already network a small state struct and
    the client already runs everything else (the wheels are traced locally, the
    pedals follow the wheel), so a replay is just that state, written down.
    No net message, no server file, no server cost: a server never knows it
    exists. That is also why it is cheap enough to leave on (bmx_replay_buffer
    turns it off): 33 samples a second of a handful of bikes is a few hundred
    kilobytes of Lua tables.

    WHAT IS RECORDED, per bike near you (and yours), every 1/33 s:
        position, angles, steer, front/rear wheel angle, crank angle, frame
        spin and bar spin (tailwhips, barspins), the rider's style pose id and
        stance, and whether it was in the air.
    plus two streams of EVENTS from the HUD: tricks landed, and the combo as
    it builds, lands or bails, so the combo text replays in step.

    THE BUFFER IS A RING of fixed size (BMX.Replay.NewRing): the newest frame
    overwrites the oldest and nothing is ever shifted or reallocated.

    PLAYBACK DRAWS STAND-INS, not the bike entity. ENT:Draw reads the entity
    all the way down (its position, trace-placed wheels, networked vars), and
    there is no entity at the buffered pose, so the stand-in is a simplified
    wireframe bike (two wheel rings, spokes, a frame, a fork that steers and a
    tailwhip that swings) in the bike's colour, with the rider as a static
    clientside player model in the airboat sitting pose. It is clearly a
    replay, and a saved clip plays on a client that has no such bike at all.
    Unverified in a live client: where the rider's feet land is eyeballed
    (BMX.Replay.RiderOffset).

    SAVED FILES. "BMXR1" + util.Compress'd JSON, or "BMXR0" + plain JSON where
    util.Compress is missing. Numbers are stored as integers (position to a
    tenth of a unit, angles to a tenth of a degree), which is both smaller and
    exact. A loaded file is a stranger's: every size is checked before it is
    believed, and it is refused on another map (the stand-ins would float).
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Replay = BMX.Replay or {}
local R = BMX.Replay

local cv_buf = CreateClientConVar("bmx_replay_buffer", "1", true, false,
    "Keep the last 30 seconds of you and nearby riders for bmx_replay.")
local cv_key = CreateClientConVar("bmx_replay_key", "20", true, false,
    "Key that starts and stops the replay (a KEY_ number; 20 is J, 0 is off).")
local cv_fov = CreateClientConVar("bmx_replay_fov", "112", true, false,
    "Field of view of the fisheye 'filmer follow' replay camera.")

R.WINDOW   = 30            -- seconds kept
R.HZ       = 33            -- samples a second
R.CAP      = R.WINDOW * R.HZ + 2
R.RANGE    = 3000          -- units: other riders this near are recorded too
R.MAXGAP   = 0.25          -- seconds: a bigger hole between samples is not interpolated
R.VERSION  = 1
R.DIR      = "bmx/replays"
R.MAX_FRAMES, R.MAX_ENTS = 4000, 64      -- what a loaded file may claim

--------------------------------------------------------------------------
-- THE RING. A fixed table with a write head: Push overwrites the oldest once
-- full. Index 1 is always the OLDEST item, Count the newest.
--------------------------------------------------------------------------
function R.NewRing(cap) return { cap = cap, n = 0, head = 0, buf = {} } end

function R.RingPush(r, v)
    r.head = r.head % r.cap + 1
    r.buf[r.head] = v
    if r.n < r.cap then r.n = r.n + 1 end
end

function R.RingGet(r, i)
    if i < 1 or i > r.n then return nil end
    return r.buf[(r.head - r.n + i - 1) % r.cap + 1]
end

function R.RingToArray(r)
    local out = {}
    for i = 1, r.n do out[i] = R.RingGet(r, i) end
    return out
end

function R.RingClear(r) r.n, r.head, r.buf = 0, 0, {} end

--------------------------------------------------------------------------
-- SAMPLING A RECORDING at a time. `frames` is chronological, each
-- { t = seconds, e = { entry, ... } } and an entry is
--   id x y z   p yw r   st wf wr cr   wp br   pose stance air
--   (position, angles in degrees, steer / wheel / crank / whip / bar in
--   radians, ids, air as 0 or 1)
--------------------------------------------------------------------------
local function angDiff(a, b)       -- shortest signed a - b, degrees
    local d = (a - b + 180) % 360 - 180
    return d
end

local function lerp(a, b, f) return a + (b - a) * f end
local function lerpAng(a, b, f) return a + angDiff(b, a) * f end

-- Index of the last frame at or before t (1 if t is before them all).
function R.FindFrame(frames, t)
    local lo, hi = 1, #frames
    if hi == 0 then return nil end
    if t <= frames[1].t then return 1 end
    if t >= frames[hi].t then return hi end
    while hi - lo > 1 do
        local mid = math.floor((lo + hi) / 2)
        if frames[mid].t <= t then lo = mid else hi = mid end
    end
    return lo
end

local function blend(a, b, f)
    local o = { id = a.id }
    o.x, o.y, o.z = lerp(a.x, b.x, f), lerp(a.y, b.y, f), lerp(a.z, b.z, f)
    o.p, o.yw, o.r = lerpAng(a.p, b.p, f), lerpAng(a.yw, b.yw, f), lerpAng(a.r, b.r, f)
    o.st, o.wf, o.wr, o.cr = lerp(a.st, b.st, f), lerp(a.wf, b.wf, f),
        lerp(a.wr, b.wr, f), lerp(a.cr, b.cr, f)
    -- Whip and bar are angles that wrap a turn: take the short way.
    local function wrap(x, y)
        local d = (y - x + math.pi) % (math.pi * 2) - math.pi
        return x + d * f
    end
    o.wp, o.br = wrap(a.wp, b.wp), wrap(a.br, b.br)
    -- Discrete things switch at the half way mark.
    local from = f < 0.5 and a or b
    o.pose, o.stance, o.air = from.pose, from.stance, from.air
    return o
end

-- Every bike's pose at time t, as { [id] = entry }. A bike missing from the
-- next frame (it left range) holds its last pose; a gap bigger than MAXGAP
-- holds too, rather than gliding across a hole.
function R.Sample(frames, t)
    local i = R.FindFrame(frames, t)
    if not i then return {} end
    local fa, fb = frames[i], frames[math.min(i + 1, #frames)]
    local span = fb.t - fa.t
    local f = (span > 0 and span <= R.MAXGAP) and math.Clamp((t - fa.t) / span, 0, 1) or 0
    local out = {}
    for _, a in ipairs(fa.e) do
        local b
        if f > 0 then
            for _, c in ipairs(fb.e) do if c.id == a.id then b = c break end end
        end
        out[a.id] = b and blend(a, b, f) or a
    end
    return out
end

--------------------------------------------------------------------------
-- THE HUD'S COMBO TEXT, IN SYNC. Events are { t, k = "trick", text, pts } and
-- { t, k = "combo", state, n, base, bonus, names }. What is on screen at time
-- t follows the live HUD's rules (cl_hud.lua) in replay time.
--------------------------------------------------------------------------
function R.OverlayAt(events, t)
    local combo, tricks = nil, {}
    for _, e in ipairs(events or {}) do
        if e.t > t then break end
        if e.k == "combo" then combo = e
        elseif e.k == "trick" and t - e.t < 2.4 then tricks[#tricks + 1] = e end
    end
    local shown
    if combo then
        local age = t - combo.t
        if combo.state == 0 then
            if combo.n >= 2 and age <= 6 then shown = combo end
        elseif age <= 2.2 and not (combo.state == 1 and combo.bonus <= 0) then
            shown = combo
        end
    end
    return shown, tricks
end

--------------------------------------------------------------------------
-- SAVING AND LOADING. Positions to a tenth of a unit, angles to a tenth of a
-- degree, the rest to a hundredth, all stored as INTEGERS.
--------------------------------------------------------------------------
local function q(v, scale) return math.floor(v * scale + 0.5) end
local function qa(v) return q(math.NormalizeAngle(v), 10) end

function R.Encode(rep)
    local t0 = rep.frames[1] and rep.frames[1].t or 0
    local rows = {}
    for i, fr in ipairs(rep.frames) do
        local row = { q(fr.t - t0, 1000), #fr.e }
        for _, e in ipairs(fr.e) do
            local n = #row
            row[n + 1], row[n + 2], row[n + 3], row[n + 4] = e.id, q(e.x, 10), q(e.y, 10), q(e.z, 10)
            row[n + 5], row[n + 6], row[n + 7] = qa(e.p), qa(e.yw), qa(e.r)
            row[n + 8], row[n + 9], row[n + 10], row[n + 11] = q(e.st, 1000), q(e.wf, 100),
                q(e.wr, 100), q(e.cr, 100)
            row[n + 12], row[n + 13] = q(e.wp, 100), q(e.br, 100)
            row[n + 14], row[n + 15], row[n + 16] = e.pose, e.stance, e.air
        end
        rows[i] = row
    end
    local ev = {}
    for i, e in ipairs(rep.events or {}) do
        local c = {}
        for k, v in pairs(e) do c[k] = v end
        c.t = q(e.t - t0, 1000) / 1000
        ev[i] = c
    end
    return util.TableToJSON({
        v = R.VERSION, map = rep.map, date = rep.date, subject = rep.subject,
        meta = rep.meta, f = rows, ev = ev,
    })
end

local STRIDE = 16

-- JSON text back to a replay, or nil and why.
function R.Decode(json)
    local d = util.JSONToTable(json or "")
    if type(d) ~= "table" or d.v ~= R.VERSION then return nil, "not a BMX replay (or a newer version)" end
    if type(d.f) ~= "table" or #d.f < 2 or #d.f > R.MAX_FRAMES then return nil, "bad frame count" end
    local frames = {}
    for i, row in ipairs(d.f) do
        local n = row[2]
        if type(n) ~= "number" or n < 0 or n > R.MAX_ENTS or #row ~= 2 + n * STRIDE then
            return nil, "damaged frame " .. i
        end
        local fr = { t = row[1] / 1000, e = {} }
        for j = 0, n - 1 do
            local o = 2 + j * STRIDE
            for k = 1, STRIDE do
                if type(row[o + k]) ~= "number" then return nil, "damaged frame " .. i end
            end
            fr.e[j + 1] = { id = row[o + 1], x = row[o + 2] / 10, y = row[o + 3] / 10,
                z = row[o + 4] / 10, p = row[o + 5] / 10, yw = row[o + 6] / 10,
                r = row[o + 7] / 10, st = row[o + 8] / 1000, wf = row[o + 9] / 100,
                wr = row[o + 10] / 100, cr = row[o + 11] / 100, wp = row[o + 12] / 100,
                br = row[o + 13] / 100, pose = row[o + 14], stance = row[o + 15],
                air = row[o + 16] }
        end
        frames[i] = fr
    end
    return { map = tostring(d.map or ""), date = d.date, subject = d.subject,
             meta = type(d.meta) == "table" and d.meta or {}, frames = frames,
             events = type(d.ev) == "table" and d.ev or {} }
end

-- Compressed where the engine can, plain where it cannot. The first line says
-- which, so a file is read the way it was written.
function R.Pack(json)
    if util.Compress then
        local c = util.Compress(json)
        if c then return "BMXR1\n" .. c end
    end
    return "BMXR0\n" .. json
end

function R.Unpack(blob)
    if type(blob) ~= "string" then return nil, "empty" end
    local head, body = blob:sub(1, 6), blob:sub(7)
    if head == "BMXR0\n" then return body end
    if head == "BMXR1\n" then
        if not util.Decompress then return nil, "this game cannot decompress replays" end
        local out = util.Decompress(body)
        if not out then return nil, "the file is damaged" end
        return out
    end
    return nil, "not a BMX replay"
end

local function cleanName(name)
    name = tostring(name or ""):gsub("[^%w_%-]", "_"):sub(1, 40)
    return name ~= "" and name or nil
end

function R.Save(name, rep)
    name = cleanName(name)
    if not name then return nil, "give it a name (letters, numbers, - and _)" end
    file.CreateDir("bmx")
    file.CreateDir(R.DIR)
    local path = R.DIR .. "/" .. name .. ".txt"
    file.Write(path, R.Pack(R.Encode(rep)))
    return path
end

function R.LoadFile(name)
    name = cleanName(name)
    if not name then return nil, "give it a name" end
    local blob = file.Read(R.DIR .. "/" .. name .. ".txt", "DATA")
    if not blob then return nil, "no replay called " .. name end
    local json, why = R.Unpack(blob)
    if not json then return nil, why end
    return R.Decode(json)
end

--------------------------------------------------------------------------
-- THE STAND-IN BIKE: line segments in the world for an entry. Pure (no
-- drawing), so the tests can check a tyre is round and sits on its axle.
-- The geometry is the bike's own config (wheelbase, wheel radius) and the
-- frame's design points from entities/bmx_base/cl_init.lua, scaled the same.
--------------------------------------------------------------------------
local FRAME = {
    bb    = { -4.5, 0, 2.5 },  seatJ = { -9.5, 0, 14 }, seat  = { -10.5, 0, 18.5 },
    headT = { 12.5, 0, 17.5 }, headB = { 14.5, 0, 10.5 }, bars = { 10.5, 0, 26 },
}
R.RING_SEGMENTS = 20

-- Where the rider's feet are, in the bike's space: eyeballed, see above.
R.RiderOffset = { -8, 0, -6 }

-- A bike-local point to the world, for a bike at `pos` with angles `ang`.
local function toWorld(pos, f, r, u, lx, ly, lz)
    return pos + f * lx - r * ly + u * lz
end

-- Segments for one wheel: a ring in the plane spanned by `side`-less axes
-- (a, b), centred at c, and one spoke turned by `spin`.
local function wheelSegments(out, c, a, b, radius, spin, col)
    local n = R.RING_SEGMENTS
    local prev
    for i = 0, n do
        local th = i / n * math.pi * 2
        local p = c + a * (math.cos(th) * radius) + b * (math.sin(th) * radius)
        if prev then out[#out + 1] = { prev, p, col or "tyre" } end
        prev = p
    end
    local s = c + a * (math.cos(spin) * radius) + b * (math.sin(spin) * radius)
    local s2 = c - a * (math.cos(spin) * radius) - b * (math.sin(spin) * radius)
    out[#out + 1] = { s, s2, "spoke" }
end

-- `cfg` is the bike's BMX.ConfigFor table. Returns { {a, b, kind}, ... } with
-- kinds "tyre", "spoke", "frame", "fork", "bars".
function R.StandInLines(entry, cfg)
    local out = {}
    local pos = Vector(entry.x, entry.y, entry.z)
    local ang = Angle(entry.p, entry.yw, entry.r)
    local f, r, u = ang:Forward(), ang:Right(), ang:Up()
    local WC = cfg.Wheel
    local k = WC.wheelbase / 39
    local half = WC.wheelbase * 0.5
    local function P(p3) return toWorld(pos, f, r, u, p3[1] * k, p3[2] * k, p3[3] * k) end

    -- The frame swings about the steer axis in a tailwhip: turn its points
    -- about the vertical through the head tube by the whip angle.
    local hx = FRAME.headB[1] * k
    local cw, sw = math.cos(entry.wp), math.sin(entry.wp)
    local function F(p3)
        local dx, dy = p3[1] * k - hx, p3[2] * k
        return toWorld(pos, f, r, u, hx + dx * cw - dy * sw, dx * sw + dy * cw, p3[3] * k)
    end

    -- Rear wheel, on the axle line, turning with the frame's whip.
    local rc = F({ -half / k, 0, 0 })
    wheelSegments(out, rc, f, u, WC.radius, entry.wr)

    -- Front wheel turns with the bars about the head tube, by the steer angle
    -- (and the bar spin, a spin of the bars alone).
    local ts = entry.st + entry.br
    local cs, ss = math.cos(ts), math.sin(ts)
    local dx = half - hx
    local fcx, fcy = hx + dx * cs, dx * ss
    local fc = toWorld(pos, f, r, u, fcx, fcy, 0)
    -- Left (+Y) is -r, and a positive steer swings the front wheel toward it.
    local fa = f * cs + (-r) * ss
    wheelSegments(out, fc, fa, u, WC.radius, entry.wf)

    -- Frame: bottom bracket, seat, head, stays; the fork to the front axle.
    local bb, sj, st = F(FRAME.bb), F(FRAME.seatJ), F(FRAME.seat)
    local ht, hb = F(FRAME.headT), F(FRAME.headB)
    out[#out + 1] = { rc, bb, "frame" }
    out[#out + 1] = { rc, sj, "frame" }
    out[#out + 1] = { bb, sj, "frame" }
    out[#out + 1] = { sj, ht, "frame" }
    out[#out + 1] = { bb, hb, "frame" }
    out[#out + 1] = { ht, hb, "frame" }
    out[#out + 1] = { sj, st, "frame" }
    out[#out + 1] = { hb, fc, "fork" }
    out[#out + 1] = { ht, fc, "fork" }
    local bars = F(FRAME.bars)
    out[#out + 1] = { ht, bars, "bars" }
    out[#out + 1] = { bars - r * (3.5 * k), bars + r * (3.5 * k), "bars" }
    return out
end

--------------------------------------------------------------------------
-- RECORDING
--------------------------------------------------------------------------
local ring = R.NewRing(R.CAP)
local events = {}              -- chronological; pruned to the window
local meta = {}                -- id -> { bike, color, name, model }
local ownId = nil
local nextRec, lastCombo = 0, nil
R.Ring = ring

local function pushEvent(e)
    events[#events + 1] = e
    local cut = e.t - R.WINDOW - 2
    while events[1] and events[1].t < cut do table.remove(events, 1) end
end

local function entryFor(b)
    local pos, ang = b:GetPos(), b:GetAngles()
    local whip, bar, pose = BMX.UnpackTrickBits(b:GetTrickBits())
    local sp = b.spin or {}
    local drv = b:GetDriver()
    local stance = BMX.RiderStanceId[BMX.StanceOf(drv)] or 1
    return { id = b:EntIndex(), x = pos.x, y = pos.y, z = pos.z,
             p = ang.p, yw = ang.y, r = ang.r,
             st = b:GetSteer(), wf = sp.front and sp.front.angle or 0,
             wr = sp.rear and sp.rear.angle or 0, cr = b.crankAngle or 0,
             wp = whip, br = bar, pose = pose or 0, stance = stance,
             air = b:GetGrounded() and 0 or 1 }
end

local function noteMeta(b)
    local drv = b:GetDriver()
    meta[b:EntIndex()] = { bike = b.BikeID or "stock",
        color = b:GetColorIndex(),
        name = IsValid(drv) and drv:Nick() or "",
        model = IsValid(drv) and drv:GetModel() or "" }
end

-- One sample. Split from the hook so the tests can call it with a clock.
function R.Record(now)
    local ply = LocalPlayer()
    if not IsValid(ply) then return end
    local own = BMX.LocalBike(ply)
    local centre = IsValid(own) and own:GetPos() or EyePos()
    local near = R.RANGE * R.RANGE
    local es = {}
    for _, b in ipairs(BMX.AllBikes()) do
        if IsValid(b) and not (b.IsDormant and b:IsDormant())
            and (b:GetPos() - centre):LengthSqr() < near then
            es[#es + 1] = entryFor(b)
            if not meta[b:EntIndex()] or b == own then noteMeta(b) end
            if b == own then ownId = b:EntIndex() end
        end
    end
    if #es == 0 then return end
    R.RingPush(ring, { t = now, e = es })

    local c = BMX.ComboHUD and BMX.ComboHUD()
    if c and c ~= lastCombo then
        pushEvent({ t = now, k = "combo", state = c.state, n = c.n, base = c.base,
                    bonus = c.bonus, names = c.names })
    end
    lastCombo = c
end

hook.Add("BMX_TricksLandedClient", "BMX.ReplayTricks", function(tricks)
    for _, t in ipairs(tricks or {}) do
        pushEvent({ t = CurTime(), k = "trick",
                    text = (t.count > 1 and (t.count .. "x ") or "") .. t.name,
                    pts = t.points })
    end
end)

local pb = nil                 -- the playback in progress, or nil
function BMX.ReplayActive() return pb ~= nil end

hook.Add("Think", "BMX.ReplayRecord", function()
    if pb or not cv_buf:GetBool() then return end
    local now = CurTime()
    if now < nextRec then return end
    -- After a stall (a loading screen, a pause) do not try to catch up.
    nextRec = (now > nextRec + 0.5 and now or nextRec) + 1 / R.HZ
    R.Record(now)
end)

-- The last window as a replay, or nil if there is not enough of it.
function R.Snapshot()
    local frames = R.RingToArray(ring)
    if #frames < 2 then return nil end
    local t0 = frames[1].t
    local ev = {}
    for _, e in ipairs(events) do if e.t >= t0 - 1 then ev[#ev + 1] = e end end
    local m = {}
    for id, v in pairs(meta) do m[#m + 1] = { id = id, bike = v.bike, color = v.color,
                                              name = v.name, model = v.model } end
    return { map = game.GetMap(), date = os.time(), subject = ownId,
             meta = m, frames = frames, events = ev }
end

--------------------------------------------------------------------------
-- PLAYBACK
--------------------------------------------------------------------------
local MODES = { "chase", "free", "filmer", "follow" }
local SPEEDS = { 0.1, 0.25, 0.5, 1, 2 }
local models, cfgs = {}, {}        -- id -> clientside rider; bike id -> config
local lastOrigin = Vector(0, 0, 0)

local function say(msg)
    if chat and chat.AddText then
        chat.AddText(Color(255, 214, 90), "[BMX] ", Color(255, 255, 255), msg)
    else
        MsgN("[BMX] " .. msg)
    end
end

local function metaOf(id)
    for _, m in ipairs(pb.rep.meta) do if m.id == id then return m end end
    return {}
end

local function subjectEntry(sample)
    return sample[pb.subject] or select(2, next(sample))
end

local function entryPos(e) return Vector(e.x, e.y, e.z) end

-- A fixed camera for the "filmer" view: a real bmx_filmer_cam near the line if
-- the map has one, otherwise a spot beside the middle of the run.
local function pickFixed(rep)
    local mid = rep.frames[math.max(1, math.floor(#rep.frames / 2))]
    local s = mid.e[1]
    local sp = s and entryPos(s) or Vector(0, 0, 0)
    for _, e in ipairs(mid.e) do if e.id == rep.subject then sp = entryPos(e) end end
    local cam = BMX.FilmerNearest and BMX.FilmerNearest(sp, BMX.Filmers())
    if cam then return cam:GetPos() + Vector(0, 0, 6), true end
    local head = Angle(0, s and s.yw or 0, 0)
    local want = sp + head:Right() * 420 + Vector(0, 0, 70)
    local tr = util.TraceLine({ start = sp + Vector(0, 0, 40), endpos = want,
                                mask = MASK_SOLID_BRUSHONLY })
    return tr.HitPos - (want - sp):GetNormalized() * (tr.Hit and 20 or 0), false
end

function R.Start(rep, mode)
    if not rep or #rep.frames < 2 then say("nothing recorded yet: ride for a few seconds first") return end
    R.Stop()
    local first = rep.frames[1].t
    pb = { rep = rep, t = first, t0 = first, t1 = rep.frames[#rep.frames].t,
           speed = 1, paused = false, mode = mode or "chase",
           subject = rep.subject, track = {}, free = nil }
    pb.fixed = pickFixed(rep)
    pb.viewAng = Angle(12, rep.frames[1].e[1] and rep.frames[1].e[1].yw or 0, 0)
    if IsValid(LocalPlayer()) then LocalPlayer():SetEyeAngles(pb.viewAng) end
    say("replay: P pause, arrows scrub and change speed, 1-4 cameras, " ..
        (cv_key:GetInt() > 0 and "J" or "bmx_replay") .. " to stop")
end

function R.Stop()
    if not pb then return end
    for _, m in pairs(models) do if IsValid(m) then m:Remove() end end
    models, cfgs, pb = {}, {}, nil
    nextRec = 0
end

function R.SetMode(m)
    if not pb then return end
    for _, v in ipairs(MODES) do
        if v == m then
            pb.mode = m
            pb.free, pb.follow = nil, nil
            local s = subjectEntry(R.Sample(pb.rep.frames, pb.t))
            if s and IsValid(LocalPlayer()) then
                LocalPlayer():SetEyeAngles(Angle(12, s.yw, 0))
            end
            return
        end
    end
end

function R.Seek(t)
    if pb then pb.t = math.Clamp(t, pb.t0, pb.t1) end
end

function R.SetSpeed(x)
    if pb and x and x ~= 0 then pb.speed = math.Clamp(x, -2, 2) end
end

concommand.Add("bmx_replay", function()
    if pb then R.Stop() return end
    R.Start(R.Snapshot())
end)
concommand.Add("bmx_replay_mode", function(_, _, a) R.SetMode(a[1]) end)
concommand.Add("bmx_replay_speed", function(_, _, a) R.SetSpeed(tonumber(a[1])) end)
concommand.Add("bmx_replay_pause", function() if pb then pb.paused = not pb.paused end end)
concommand.Add("bmx_replay_seek", function(_, _, a)
    if not pb or not a[1] then return end
    local pct = tostring(a[1]):match("^(%-?[%d%.]+)%%$")
    if pct then R.Seek(pb.t0 + (pb.t1 - pb.t0) * tonumber(pct) / 100)
    elseif tonumber(a[1]) then R.Seek(pb.t0 + tonumber(a[1])) end
end)

concommand.Add("bmx_replay_save", function(_, _, a)
    local rep = pb and pb.rep or R.Snapshot()
    if not rep then say("nothing recorded yet") return end
    local name = a[1] or os.date("%Y%m%d_%H%M%S")
    local path, why = R.Save(name, rep)
    if path then say("saved to data/" .. path .. " (give the file to a friend: it plays on " ..
        rep.map .. ")") else say(why) end
end)

concommand.Add("bmx_replay_load", function(_, _, a)
    local rep, why = R.LoadFile(a[1])
    if not rep then say(why or "could not load that replay") return end
    if rep.map ~= game.GetMap() and a[2] ~= "force" then
        say("that replay was recorded on " .. rep.map .. ", this is " .. game.GetMap() ..
            " (add 'force' to watch it anyway)")
        return
    end
    R.Start(rep)
end)

concommand.Add("bmx_replay_list", function()
    local files = file.Find and file.Find(R.DIR .. "/*.txt", "DATA") or {}
    if #files == 0 then say("no saved replays") return end
    for _, f in ipairs(files) do say(f:gsub("%.txt$", "")) end
end)

hook.Add("PlayerButtonDown", "BMX.ReplayKeys", function(ply, button)
    if not IsFirstTimePredicted or IsFirstTimePredicted() then
        if ply ~= LocalPlayer() then return end
        if ply.IsTyping and ply:IsTyping() then return end
        local key = cv_key:GetInt()
        if key > 0 and button == key and (pb or BMX.LocalBike(ply)) then
            if pb then R.Stop() else R.Start(R.Snapshot()) end
            return
        end
        if not pb then return end
        if button == KEY_P then pb.paused = not pb.paused
        elseif button == KEY_LEFT then R.Seek(pb.t - 1)
        elseif button == KEY_RIGHT then R.Seek(pb.t + 1)
        elseif button == KEY_UP or button == KEY_DOWN then
            local at = 4
            for i, s in ipairs(SPEEDS) do if math.abs(pb.speed) == s then at = i end end
            at = math.Clamp(at + (button == KEY_UP and 1 or -1), 1, #SPEEDS)
            pb.speed = SPEEDS[at] * (pb.speed < 0 and -1 or 1)
        elseif button >= KEY_1 and button <= KEY_4 then R.SetMode(MODES[button - KEY_1 + 1])
        end
    end
end)

-- Time runs here, so a paused game does not lose its place.
hook.Add("Think", "BMX.ReplayTime", function()
    if not pb or pb.paused then return end
    pb.t = math.Clamp(pb.t + FrameTime() * pb.speed, pb.t0, pb.t1)
end)

-- The free camera flies on the player's own keys; the live bike gets none.
hook.Add("CreateMove", "BMX.ReplayMove", function(cmd)
    if not pb then return end
    local ang = cmd:GetViewAngles()
    pb.viewAng = ang
    if pb.mode == "free" and pb.free then
        local sp = (cmd:KeyDown(IN_SPEED) and 1500 or 500) * FrameTime()
        local v = Vector(0, 0, 0)
        if cmd:KeyDown(IN_FORWARD) then v = v + ang:Forward() end
        if cmd:KeyDown(IN_BACK) then v = v - ang:Forward() end
        if cmd:KeyDown(IN_MOVERIGHT) then v = v + ang:Right() end
        if cmd:KeyDown(IN_MOVELEFT) then v = v - ang:Right() end
        if cmd:KeyDown(IN_JUMP) then v = v + Vector(0, 0, 1) end
        if cmd:KeyDown(IN_DUCK) then v = v - Vector(0, 0, 1) end
        pb.free = pb.free + v * sp
    end
    cmd:ClearMovement()
    cmd:ClearButtons()
    cmd:SetViewAngles(ang)
end)

hook.Add("CalcView", "BMX.ReplayView", function(ply, origin, angles, fov)
    if not pb then return end
    local sample = R.Sample(pb.rep.frames, pb.t)
    local s = subjectEntry(sample)
    if not s then return end
    local sp = entryPos(s)
    local dt = FrameTime()
    local view = { drawviewer = true, fov = fov }
    local aim = sp + Vector(0, 0, 28)

    if pb.mode == "free" then
        pb.free = pb.free or lastOrigin
        view.origin, view.angles = pb.free, pb.viewAng
    elseif pb.mode == "filmer" then
        view.origin = pb.fixed
        view.angles = BMX.FilmerTrack(pb.track, BMX.FilmerAim(pb.fixed, aim), dt)
        view.fov = BMX.FilmerFov(pb.fixed:Distance(aim))
    elseif pb.mode == "follow" then
        -- THE CLASSIC SKATE-VIDEO LOOK: the camera low and close behind the
        -- rider, on a loose lag like a hand-held lens, with a very wide view.
        local head = Angle(0, s.yw, 0)
        local want = sp - head:Forward() * 80 + head:Right() * 14 + Vector(0, 0, 16)
        pb.follow = pb.follow or want
        pb.follow = pb.follow + (want - pb.follow) * math.min(1, 7 * dt)
        view.origin = pb.follow
        view.angles = BMX.FilmerAim(pb.follow, sp + Vector(0, 0, 22))
        view.fov = cv_fov:GetFloat()
    else
        local want = aim - pb.viewAng:Forward() * 115
        local tr = util.TraceHull({ start = aim, endpos = want,
            mins = Vector(-8, -8, -8), maxs = Vector(8, 8, 8),
            mask = MASK_SOLID_BRUSHONLY })
        view.origin, view.angles = tr.HitPos, pb.viewAng
    end
    lastOrigin = view.origin
    return view
end)

--------------------------------------------------------------------------
-- DRAWING THE STAND-INS
--------------------------------------------------------------------------
local COL = { tyre = Color(30, 30, 34), spoke = Color(170, 175, 185),
              frame = Color(235, 90, 60), fork = Color(200, 204, 212),
              bars = Color(40, 40, 44) }

local function configOf(m)
    local id = m.bike or "stock"
    if not cfgs[id] then cfgs[id] = BMX.ConfigFor(BMX.Bikes[id] or BMX.Bikes.stock) end
    return cfgs[id]
end

local function riderModel(id, m)
    local cs = models[id]
    if cs and IsValid(cs) then return cs end
    local path = (m.model and m.model ~= "" and util.IsValidModel(m.model)) and m.model
        or "models/player/kleiner.mdl"
    cs = ClientsideModel(path)
    if not cs then return nil end
    cs:SetNoDraw(true)
    local seq = cs:LookupSequence("drive_airboat")
    if seq and seq >= 0 then cs:SetSequence(seq) end
    cs:SetPlaybackRate(0)
    models[id] = cs
    return cs
end

hook.Add("PostDrawOpaqueRenderables", "BMX.ReplayDraw", function()
    if not pb then return end
    local sample = R.Sample(pb.rep.frames, pb.t)
    render.SetColorMaterial()
    for id, e in pairs(sample) do
        local m = metaOf(id)
        local cfg = configOf(m)
        local body = BMX.PaletteColor and BMX.PaletteColor(m.color or 1)
        for _, seg in ipairs(R.StandInLines(e, cfg)) do
            local c = COL[seg[3]] or color_white
            if seg[3] == "frame" and body then c = body end
            render.DrawBeam(seg[1], seg[2], seg[3] == "tyre" and 1.6 or 0.8, 0, 1, c)
        end

        local cs = riderModel(id, m)
        if cs then
            local ang = Angle(e.p, e.yw, e.r)
            local o = R.RiderOffset
            local k = cfg.Wheel.wheelbase / 39
            local pos = Vector(e.x, e.y, e.z) + ang:Forward() * (o[1] * k)
                - ang:Right() * (o[2] * k) + ang:Up() * (o[3] * k)
            cs:SetPos(pos)
            cs:SetAngles(ang)
            local spine = cs:LookupBone(BMX.RiderBones and BMX.RiderBones.spine or "")
            if spine then
                local lean = BMX.RiderPoseOffset(BMX.StanceName(e.stance)).spineLean or 0
                cs:ManipulateBoneAngles(spine, Angle(0, lean, 0))
            end
            cs:SetupBones()
            cs:DrawModel()
        end
    end
    -- Riders that left the clip leave nothing behind.
    for id, cs in pairs(models) do
        if not sample[id] then if IsValid(cs) then cs:Remove() end models[id] = nil end
    end
end)

--------------------------------------------------------------------------
-- THE REPLAY HUD: the timeline, the camera and speed, the replayed combo text.
--------------------------------------------------------------------------
local function commas(n)
    local s = tostring(math.floor(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

hook.Add("HUDPaint", "BMX.ReplayHUD", function()
    if not pb then return end
    local sw, sh = ScrW(), ScrH()

    -- A vignette for the fisheye camera, where the edges go dark.
    if pb.mode == "follow" and surface and surface.SetMaterial then
        surface.SetDrawColor(0, 0, 0, 170)
        surface.SetMaterial(Material("gui/gradient"))
        surface.DrawTexturedRect(0, 0, sw * 0.12, sh)
        surface.DrawTexturedRectRotated(sw - sw * 0.06, sh * 0.5, sw * 0.12, sh, 180)
    end

    draw.SimpleText(string.format("REPLAY   %s   %sx%s", pb.mode,
        pb.paused and "paused " or "", tostring(pb.speed)),
        "BMX.Small", 28, 24, Color(238, 105, 85), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    local bw, bx, by = sw * 0.5, sw * 0.25, sh - 56
    local frac = (pb.t - pb.t0) / math.max(pb.t1 - pb.t0, 1e-6)
    draw.RoundedBox(3, bx, by, bw, 6, Color(0, 0, 0, 160))
    draw.RoundedBox(3, bx, by, bw * frac, 6, Color(238, 105, 85))
    draw.SimpleText(string.format("%.1f / %.1f s", pb.t - pb.t0, pb.t1 - pb.t0),
        "BMX.Small", sw * 0.5, by + 10, Color(230, 230, 235), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)

    -- The combo text, as it was.
    local combo, tricks = R.OverlayAt(pb.rep.events, pb.t)
    local y = sh * 0.34
    for i = #tricks, 1, -1 do
        local e = tricks[i]
        local age = pb.t - e.t
        local a = 255 * (1 - math.max(0, (age - 1.6) / 0.8))
        draw.SimpleText(e.text, "BMX.Big", sw * 0.5, y - age * 22,
            Color(255, 255, 255, a), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        draw.SimpleText("+" .. e.pts, "BMX.Small", sw * 0.5, y - age * 22 + 26,
            Color(110, 205, 140, a), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        y = y - 60
    end
    if combo then
        local cy = sh * 0.72
        if combo.state == 0 then
            draw.SimpleText(table.concat(combo.names or {}, " + "), "BMX.Small", sw * 0.5, cy,
                Color(255, 255, 255, 230), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            draw.SimpleText(commas(combo.base) .. "  x" .. combo.n, "BMX.Big", sw * 0.5, cy + 30,
                Color(255, 214, 90), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        elseif combo.state == 1 then
            draw.SimpleText("COMBO LANDED  +" .. commas(combo.bonus), "BMX.Big", sw * 0.5, cy + 30,
                Color(110, 230, 120), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        else
            draw.SimpleText("BAILED", "BMX.Big", sw * 0.5, cy + 30,
                Color(235, 80, 70), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
    end
end)

-- A replay does not outlive the map it was for.
hook.Add("ShutDown", "BMX.ReplayShutdown", function() R.Stop() end)
