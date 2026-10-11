-- THE ANIMATION SWEEP, client half (tools/ride/sweep.sh): follow each run's bike, and
-- every frame measure
--  * how far each hand and foot is drawn from the target the IK was handed,
--  * how far from the grips and pedals the bike drew in the SAME frame (a rider
--    drawn before their bike would hold last frame's grips),
--  * how far each limb, the spine and the head move in a frame, and how sharply
--    that motion changes (a pop is a big change in one frame),
--  * the frame times while a vehicle's model is first built.
SWEEPCL = SWEEPCL or {}
local C = SWEEPCL
C.origSolve = C.origSolve or BMX.SolveRiderIK
local LIMBS = { "rHand", "lHand", "rFoot", "lFoot" }
local BONE = { rHand = "ValveBiped.Bip01_R_Hand", lHand = "ValveBiped.Bip01_L_Hand",
               rFoot = "ValveBiped.Bip01_R_Foot", lFoot = "ValveBiped.Bip01_L_Foot" }
local TOE = { rFoot = "ValveBiped.Bip01_R_Toe0", lFoot = "ValveBiped.Bip01_L_Toe0" }

local cur          -- the run being watched
local function bp(p, name)
    local b = p:LookupBone(name)
    local m = b and p:GetBoneMatrix(b)
    return m and m:GetTranslation()
end
local function segDist(P, A, B)
    local g = B - A
    local t = math.Clamp((P - A):Dot(g) / math.max(g:Dot(g), 1e-6), 0, 1)
    return (A + g * t - P):Length()
end
-- Where a limb is drawn: the fist's centre for a hand, the foot's sole line
-- (ankle to ball) for a foot.
local function limbMiss(p, key, T, A, B)
    if key:sub(2) == "Hand" then
        local fc = BMX.RiderFistCentre(p, key:sub(1, 1):upper())
        if not fc then return nil end
        if A and B then return segDist(fc, A, B) end
        return (fc - T):Length()
    end
    local a, t = bp(p, BONE[key]), bp(p, TOE[key])
    if not (a and t) then return nil end
    return segDist(T, a, t)
end

-- What the IK was handed, per player, this frame.
BMX.SolveRiderIK = function(ply, targets, bike)
    C.origSolve(ply, targets, bike)
    if not cur or not (ply == cur.rider or ply == cur.pax) then return end
    local rec = { frame = FrameNumber() }
    for _, k in ipairs(LIMBS) do
        local T = targets[k .. "Held"] or targets[k]
        if T then rec[k] = Vector(T) end
        if targets[k .. "Wrist"] then rec[k .. "Wrist"] = Vector(targets[k .. "Wrist"]) end
    end
    cur.used[ply] = rec
end

local function newSeries() return { n = 0 } end
local function add(s, v) if v then s.n = s.n + 1; s[s.n] = v end end
local function stats(s)
    if s.n == 0 then return "n/a" end
    local c = {}
    for i = 1, s.n do c[i] = s[i] end
    table.sort(c)
    local function q(f) return c[math.max(1, math.ceil(f * s.n))] end
    return string.format("%.2f/%.2f/%.2f", q(0.5), q(0.95), c[s.n])
end
local function maxOf(s) local m = 0 for i = 1, s.n do m = math.max(m, s[i]) end return m end

local function lean(p) return BMX.RiderSpineLean and BMX.RiderSpineLean(p) or 0 end
local function headAng(p)
    local b = p:LookupBone("ValveBiped.Bip01_Head1")
    return b and p:GetManipulateBoneAngles(b) or Angle()
end

local function newTrack(p)
    return { p = p, ikH = newSeries(), ikF = newSeries(), seenH = newSeries(), seenF = newSeries(),
             stepH = newSeries(), stepF = newSeries(), jerkH = newSeries(), jerkF = newSeries(),
             stepSpine = newSeries(), stepHead = newSeries(), last = nil, prevStep = {}, worst = {} }
end

-- Per frame, after the player is drawn: where the limbs are.
hook.Add("PostPlayerDraw", "sweep", function(p)
    if not cur or not cur.watch then return end
    local tr = cur.tracks[p]
    if not tr then return end
    local f = FrameNumber()
    if tr.frame == f then return end
    tr.frame = f
    local bike = cur.bike
    if not IsValid(bike) then return end
    local row = { t = CurTime() - cur.t0, dt = FrameTime(), lean = lean(p), head = headAng(p), loc = {}, world = {} }
    for _, k in ipairs(LIMBS) do
        local w = (k:sub(2) == "Hand") and BMX.RiderFistCentre(p, k:sub(1, 1):upper()) or bp(p, BONE[k])
        if w then row.world[k] = w; row.loc[k] = bike:WorldToLocal(w) end
    end
    -- against what the IK was handed this frame
    local used = cur.used[p]
    local miss = {}
    if used and used.frame == f then
        for _, k in ipairs(LIMBS) do
            if used[k] then
                local m = limbMiss(p, k, used[k])
                miss[k] = m
                add(k:sub(2) == "Hand" and tr.ikH or tr.ikF, m)
            end
        end
    end
    if cur.detail then
        tr.lines = tr.lines or {}
        local function f1(v) return v and string.format("%.1f", v) or "-" end
        local sp = bike:GetVelocity():Length()
        local function sh(side, key)
            local b = p:LookupBone("ValveBiped.Bip01_" .. side .. "_UpperArm")
            local W = used and used.frame == f and used[key .. "Wrist"]
            local m = b and p:GetBoneMatrix(b)
            return (W and m) and string.format("%.1f", (W - m:GetTranslation()):Length()) or "-"
        end
        tr.lines[#tr.lines + 1] = string.format("%.2f %s %s %s %s sp%.0f spr%d st%d gr%d lean%.1f reach%.0f/%.0f shR%s shL%s",
            row.t, f1(miss.rHand), f1(miss.lHand), f1(miss.rFoot), f1(miss.lFoot), sp,
            bike.GetSprinting and bike:GetSprinting() and 1 or 0, cur.rider:GetNWInt("BMXStance", 1),
            bike.GetGrounded and bike:GetGrounded() and 1 or 0, row.lean, p.bmxSpineLean or 0, p.bmxSpineLeanShown or 0,
            sh("R", "rHand"), sh("L", "lHand"))
    end
    -- frame to frame, in the bike's own frame, as rates scaled to a 60 fps frame
    -- (an uneven frame time is not a pop)
    local last = tr.last
    if last and row.dt > 0 then
        local per = 1 / (60 * row.dt)
        for _, k in ipairs(LIMBS) do
            if row.loc[k] and last.loc[k] then
                local v = (row.loc[k] - last.loc[k]) * per
                local hand = k:sub(2) == "Hand"
                add(hand and tr.stepH or tr.stepF, v:Length())
                local pv = tr.prevStep[k]
                if pv then
                    local j = (v - pv):Length()
                    add(hand and tr.jerkH or tr.jerkF, j)
                    local key = hand and "jerkH" or "jerkF"
                    if j > ((tr.worst[key] or {}).v or 0) then tr.worst[key] = { v = j, t = row.t } end
                end
                tr.prevStep[k] = v
            end
        end
        local ds = math.abs(row.lean - last.lean) * per
        add(tr.stepSpine, ds)
        if ds > ((tr.worst.spine or {}).v or 0) then tr.worst.spine = { v = ds, t = row.t } end
        local h = math.max(math.abs(row.head.p - last.head.p), math.abs(row.head.y - last.head.y), math.abs(row.head.r - last.head.r)) * per
        add(tr.stepHead, h)
        if h > ((tr.worst.head or {}).v or 0) then tr.worst.head = { v = h, t = row.t } end
    end
    tr.last = row
    tr.pending = row
end)

-- After everything opaque is drawn: the grips and pedals as the bike drew them THIS
-- frame, against where the rider's hands and feet were drawn.
hook.Add("PostDrawOpaqueRenderables", "sweep", function(depth, sky)
    if depth or sky or not cur or not cur.watch then return end
    local f = FrameNumber()
    if cur.seenFrame == f then return end
    cur.seenFrame = f
    local bike = cur.bike
    if not IsValid(bike) then return end
    if cur.drawn == f then cur.freshDraws = cur.freshDraws + 1 end
    local tr = cur.tracks[cur.rider]
    local row = tr and tr.pending
    if not row or tr.frame ~= f then return end
    tr.pending = nil
    cur.frames = cur.frames + 1
    -- ...only where the rider means to be on them: seated stance, no style pose.
    local W = bike.poseW
    local posing = W and next(W) ~= nil
    if posing then cur.poseSeen = true; for n, w in pairs(W) do cur.posePeak[n] = math.max(cur.posePeak[n] or 0, w) end end
    if posing or cur.rider:GetNWInt("BMXStance", 1) ~= 1 then return end
    local ik = bike.ikTargets
    if not ik or cur.drawn ~= f then return end
    for _, k in ipairs(LIMBS) do
        local T = ik[k]
        local w = row.world[k]
        if T and w then
            if k:sub(2) == "Hand" then
                local A, B = ik[k .. "A"], ik[k .. "B"]
                add(tr.seenH, (A and B) and segDist(w, A, B) or (w - T):Length())
            else
                local a, t = bp(cur.rider, BONE[k]), bp(cur.rider, TOE[k])
                if a and t then add(tr.seenF, segDist(T, a, t)) end
            end
        end
    end
end)

-- The model build: frame times from the spawn for 4 s, against the 1 s before.
hook.Add("PostRender", "sweep", function()
    local now = SysTime()
    local d = C.lastFrame and (now - C.lastFrame) or 0
    C.lastFrame = now
    C.recent = C.recent or {}
    table.insert(C.recent, d)
    if #C.recent > 90 then table.remove(C.recent, 1) end
    if cur and cur.spawnWin then
        local w = cur.spawnWin
        if now - w.start < 4 then
            w.n = w.n + 1
            w.worst = math.max(w.worst, d)
            if d > 0.05 then w.over50 = w.over50 + 1 end
            w.total = w.total + d
        else
            cur.spawnWin = nil
            cur.spawnRes = w
        end
    end
end)

hook.Add("CalcView", "sweep", function(ply, pos, ang, fov)
    if not cur or not IsValid(cur.bike) then return end
    local b = cur.bike
    local o = b:LocalToWorld(Vector(-30, 140, 50))
    return { origin = o, angles = (b:GetPos() + Vector(0, 0, 30) - o):Angle(), fov = 70, drawviewer = false }
end)

local function trackLine(name, tr)
    return string.format("  %s: IK miss (median/p95/max u) hands %s, feet %s | vs the grips/pedals drawn this frame: hands %s, feet %s\n" ..
        "    per 60 fps frame (median/p95/max): hands %s u, feet %s u, spine %s deg, head %s deg | sudden change (p99/max): hands %.1f/%.1f u at t %.1f, feet %.1f/%.1f u at t %.1f; worst spine step at t %.1f, head at t %.1f",
        name, stats(tr.ikH), stats(tr.ikF), stats(tr.seenH), stats(tr.seenF),
        stats(tr.stepH), stats(tr.stepF), stats(tr.stepSpine), stats(tr.stepHead),
        (function(s) if s.n == 0 then return 0 end local c = {} for i = 1, s.n do c[i] = s[i] end table.sort(c) return c[math.ceil(0.99 * s.n)] end)(tr.jerkH),
        maxOf(tr.jerkH), (tr.worst.jerkH or {}).t or -1,
        (function(s) if s.n == 0 then return 0 end local c = {} for i = 1, s.n do c[i] = s[i] end table.sort(c) return c[math.ceil(0.99 * s.n)] end)(tr.jerkF),
        maxOf(tr.jerkF), (tr.worst.jerkF or {}).t or -1,
        (tr.worst.spine or {}).t or -1, (tr.worst.head or {}).t or -1)
end

local function finish()
    if not cur then return end
    local r = cur
    cur = nil
    local base = {}
    for i, v in ipairs(r.baseline or {}) do base[i] = v end
    table.sort(base)
    local med = base[math.ceil(#base / 2)] or 0
    local sw = r.spawnRes
    local tr = r.tracks[r.rider]
    local poses = {}
    for n, w in pairs(r.posePeak) do poses[#poses + 1] = string.format("%s %.2f", n, w) end
    local lines = {}
    lines[1] = string.format("%s: %d frames | first-spawn window: %s | bike drawn before the rider read its targets in %d of %d frames | pose weights seen: %s",
        r.name, r.frames,
        sw and string.format("worst frame %.0f ms, %d frames over 50 ms (frames before the spawn: median %.0f ms)", sw.worst * 1000, sw.over50, med * 1000) or "n/a",
        r.freshDraws, r.frames, #poses > 0 and table.concat(poses, ", ") or "none")
    lines[2] = trackLine("rider", tr)
    if IsValid(r.pax) and r.tracks[r.pax] then
        local pk = BMX.PassengerKind and BMX.PassengerKind(r.pax, r.bike) or "?"
        lines[3] = trackLine("passenger (" .. tostring(pk) .. ")", r.tracks[r.pax])
    end
    local s = table.concat(lines, "\n")
    print("[sweep] " .. s)
    net.Start("sweep_result") net.WriteString(s) net.SendToServer()
    if r.detail then
        for p, t in pairs(r.tracks) do
            if t.lines then
                local who = (p == r.rider) and "rider" or "pax"
                net.Start("sweep_result")
                net.WriteString("DETAIL " .. r.name .. " " .. who .. " (t rHand lHand rFoot lFoot)\n" .. table.concat(t.lines, "\n"))
                net.SendToServer()
            end
        end
    end
end

net.Receive("sweep_go", function()
    local name = net.ReadString()
    local bi, ri, pi = net.ReadUInt(16), net.ReadUInt(16), net.ReadUInt(16)
    local detail = net.ReadBool()
    if cur then finish() end
    local r = { name = name, detail = detail, used = {}, tracks = {}, frames = 0, freshDraws = 0, posePeak = {},
                baseline = table.Copy(C.recent or {}),
                spawnWin = { start = SysTime(), n = 0, worst = 0, over50 = 0, total = 0 } }
    cur = r
    -- the entities arrive a moment after the message
    timer.Simple(1.2, function()
        if cur ~= r then return end
        r.bike, r.rider = Entity(bi), Entity(ri)
        r.pax = pi > 0 and Entity(pi) or nil
        if IsValid(r.bike) then
            local orig = r.bike.Draw
            r.bike.Draw = function(self, ...) r.drawn = FrameNumber() return orig(self, ...) end
        end
    end)
    timer.Simple(4, function()
        if cur ~= r then return end
        r.t0 = CurTime()
        r.tracks[r.rider] = newTrack(r.rider)
        if IsValid(r.pax) then r.tracks[r.pax] = newTrack(r.pax) end
        r.watch = true
        timer.Simple(14, function() if cur == r then finish() end end)
    end)
end)

-- The server's settings against this client's copy of them.
net.Receive("sweep_cv", function()
    local tag, body = net.ReadString(), net.ReadString()
    local n, same, diff = 0, 0, {}
    for line in string.gmatch(body, "[^\n]+") do
        local k, v = line:match("^([^=]+)=(.*)$")
        if k then
            n = n + 1
            local c = GetConVar(k)
            local mine = c and c:GetString()
            local eq = mine == v or (tonumber(mine) and tonumber(v) and math.abs(tonumber(mine) - tonumber(v)) < 1e-4)
            if eq then same = same + 1 else diff[#diff + 1] = k .. " server " .. v .. " client " .. tostring(mine) end
        end
    end
    local s = string.format("settings %s: %d of %d server settings match on the client%s", tag, same, n,
        #diff > 0 and (" -- differ: " .. table.concat(diff, "; ")) or "")
    print("[sweep] " .. s)
    net.Start("sweep_result") net.WriteString(s) net.SendToServer()
end)

concommand.Add("sweep_unhook", function()
    BMX.SolveRiderIK = C.origSolve
    for _, h in ipairs({ "PostPlayerDraw", "PostDrawOpaqueRenderables", "PostRender", "CalcView" }) do hook.Remove(h, "sweep") end
end)
print("[sweep] client ready " .. BMX.Version)
