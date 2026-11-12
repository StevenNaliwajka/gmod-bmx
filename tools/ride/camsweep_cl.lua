-- THE CAMERA SWEEP, client half (tools/ride/camsweep.sh). The owner rides each vehicle
-- (the server drives it); this swings the REAL chase camera round them by turning the
-- view angles the way a mouse does, and every frame records
--  * where the camera is, round the vehicle: azimuth in the vehicle's frame (0 = in
--    front, 180 = behind), elevation;
--  * whether the rider was drawn, whether the riding pose was applied to them that
--    frame (cl_rider.lua's PrePlayerDraw stamps bmxPoseFrame), whether the vehicle was
--    drawn, and how far the fists and feet are from the grips and pedals the vehicle
--    drew (the airboat sit holds its hands a foot from any bars);
--  * the frame time, on this machine's GPU.
-- Pictures (320x240) go to this client's data/camsweep/: one per stage and 45 degrees of
-- azimuth on the first pass, every stage in first person, and any frame judged bad.
CAMSWEEPCL = CAMSWEEPCL or {}
local C = CAMSWEEPCL
local STAGES = {
    { "parked", 0, 1.2 }, { "pedal", 1.2, 3.2 }, { "sprint", 3.2, 4.6 }, { "standing", 4.6, 5.8 },
    { "attack", 5.8, 7.0 }, { "hop", 7.0, 7.6 }, { "air", 7.6, 8.9 }, { "landing", 8.9, 10.0 },
    { "turn", 10.0, 11.5 },
}
local function stageAt(t)
    for _, s in ipairs(STAGES) do if t >= s[2] and t < s[3] then return s[1] end end
    return nil
end
-- Each pass: the camera's pitch (positive looks down on the rider) and its mode.
local PASSES = {
    { pitch = 12, mode = "chase", shots = true },
    { pitch = 40, mode = "chase" },
    { pitch = -12, mode = "chase" },
    { pitch = 8, mode = "first", shots = true },
}
-- No pictures (data/camsweep_noshots.txt present; sp.sh with BMX_SWEEP_NOSHOTS=1): to tell
-- a stall the sweep's own captures cause from one the riding does (runs 12-13, 2026-11-12:
-- one 55-65 ms frame in the 12th vehicle's second pass, whatever vehicle that was).
local NOSHOTS = file.Exists("camsweep_noshots.txt", "DATA")
local ORBIT = 300          -- degrees a second the mouse turns the view
local BAD_MISS = 7         -- units: a fist or foot this far off its grip or pedal
local BONE = { rFoot = "ValveBiped.Bip01_R_Foot", lFoot = "ValveBiped.Bip01_L_Foot" }
local TOE = { rFoot = "ValveBiped.Bip01_R_Toe0", lFoot = "ValveBiped.Bip01_L_Toe0" }

local cur
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

local function clock()
    if not cur then return end
    local T = CurTime() - cur.t0
    if T < 0 then return end
    local pass = math.floor(T / cur.passLen) + 1
    if pass > cur.passes then return end
    return pass, T - (pass - 1) * cur.passLen
end

-- The mouse.
hook.Add("CreateMove", "camsweep", function(cmd)
    local pass, t = clock()
    if not pass then return end
    local P = PASSES[pass] or PASSES[1]
    local cv = GetConVar("bmx_cam_first")
    local wantFirst = P.mode == "first"
    if cv and cv:GetBool() ~= wantFirst then RunConsoleCommand("bmx_cam_first", wantFirst and "1" or "0") end
    cmd:SetViewAngles(Angle(P.pitch, (t * ORBIT) % 360, 0))
end)

local function newCell() return { n = 0, drawn = 0, posed = 0, bikeDrawn = 0, bad = 0, miss = {} } end

-- Where the camera is, round the vehicle (or round the player, on worn skates).
local function camAround(subject)
    local eye = (C.view and C.viewFrame == FrameNumber() and C.view.origin) or EyePos()
    local d = eye - (subject:GetPos() + Vector(0, 0, 30))
    local l = subject:WorldToLocal(subject:GetPos() + d) -- direction in the subject's frame
    local az = math.deg(math.atan2(l.y, l.x)) % 360
    local el = math.deg(math.atan2(l.z, math.sqrt(l.x * l.x + l.y * l.y)))
    return az, el
end

hook.Add("PostPlayerDraw", "camsweep", function(p)
    if cur and p == LocalPlayer() then cur.plyDrawn = FrameNumber() end
end)

local function handMiss(p, ik, side)
    local fc = BMX.RiderFistCentre and BMX.RiderFistCentre(p, side:upper())
    local k = side .. "Hand"
    if not (fc and ik[k]) then return nil end
    local A, B = ik[k .. "A"], ik[k .. "B"]
    return (A and B) and segDist(fc, A, B) or (fc - ik[k]):Length()
end
local function footMiss(p, ik, k)
    local a, t = bp(p, BONE[k]), bp(p, TOE[k])
    if not (a and t and ik[k]) then return nil end
    return segDist(ik[k], a, t)
end

-- What the player saw: the frame itself, read back whole (a view rebuilt from EyePos and
-- EyeAngles is not the chase camera's: half the first pictures were empty grass).
local function shoot(name)
    local data = render.Capture({ format = "jpeg", quality = 55, x = 0, y = 0, w = ScrW(), h = ScrH(), alpha = false })
    if data then file.Write("camsweep/" .. name .. ".jpg", data) cur.shots = cur.shots + 1 end
    cur.shotFrame = FrameNumber()
end

-- The camera the chase view chose this frame (BMX.ChaseCam's own answer), or nil when it
-- left the view to the engine.
local function wrapChase()
    local t = hook.GetTable().CalcView
    local orig = t and t["BMX.ChaseCam"]
    if not orig or C.chaseWrapped == orig then return end
    C.origChase = C.origChase or orig
    local w = function(...)
        local v = C.origChase(...)
        C.view = v
        C.viewFrame = FrameNumber()
        return v
    end
    C.chaseWrapped = w
    hook.Add("CalcView", "BMX.ChaseCam", w)
end
wrapChase()

-- WHERE A SLOW FRAME WENT: every BMX hook and the vehicle's Draw timed, per frame, and a slow
-- frame's note names the three dearest. Without it the e-bike's 60-64 ms frame in pass 2
-- (all three whole gate runs, 2026-11-11: no collection, no model building) could not be
-- told from an engine stall. Put back by camsweep_unhook.
C.parts = C.parts or {}
C.wrappedHooks = C.wrappedHooks or {}
local function timed(name, fn)
    return function(...)
        local s0 = SysTime()
        local a, b, c, d, e = fn(...)
        local P = C.parts
        P[name] = (P[name] or 0) + (SysTime() - s0)
        return a, b, c, d, e
    end
end
if not C.hooksTimed then
    C.hooksTimed = true
    for ev, list in pairs(hook.GetTable()) do
        for id, fn in pairs(list) do
            if isstring(id) and id:sub(1, 3) == "BMX" and not (ev == "CalcView" and id == "BMX.ChaseCam") then
                C.wrappedHooks[#C.wrappedHooks + 1] = { ev, id, fn }
                hook.Add(ev, id, timed(ev .. ":" .. id, fn))
            end
        end
    end
end
local function dearest(tbl)
    local rows = {}
    for k, v in pairs(tbl) do rows[#rows + 1] = { k, v } end
    table.sort(rows, function(a, b) return a[2] > b[2] end)
    local out = {}
    for i = 1, math.min(3, #rows) do out[i] = string.format("%s %.1f", rows[i][1], rows[i][2] * 1000) end
    return #out > 0 and table.concat(out, ", ") or "none"
end

-- After the frame is drawn: judge it.
hook.Add("PostRender", "camsweep", function()
    local now = SysTime()
    local dt = C.last and (now - C.last) or 0
    C.last = now
    local spent = C.parts or {}
    C.parts = {}
    if not cur then return end
    local pass, t = clock()
    if not pass then
        if cur.pre and CurTime() < cur.t0 then cur.pre[#cur.pre + 1] = dt end
        return
    end
    local stage = stageAt(t)
    if not stage then return end
    local f = FrameNumber()
    -- What the frame had in it, for a slow one's note: the Lua heap against the last frame
    -- (a drop is a collection) and the models still building (BM.Status). The e-bike's
    -- one 60-64 ms frame in pass 2, both whole gate runs (2026-11-11), said only where it
    -- was.
    local heap = collectgarbage("count")
    local dHeap = heap - (cur.lastHeap or heap)
    cur.lastHeap = heap
    local ply = LocalPlayer()
    local bike = cur.bike
    local subject = IsValid(bike) and bike or ply
    local az, el = camAround(subject)
    local bucket = math.floor(((az + 22.5) % 360) / 45) * 45
    local key = pass .. "|" .. stage .. "|" .. bucket
    local cell = cur.cells[key] or newCell()
    cur.cells[key] = cell
    cell.n = cell.n + 1
    -- (the two frames after a picture are not fair frame times: a capture stalls the GPU's
    -- queue, and the stall can land a frame later -- a 63 ms frame "2 frames after a
    -- picture", 2026-11-09)
    if not (cur.shotFrame and f - cur.shotFrame <= 2) then
        local ft = cur.ft[pass .. "|" .. stage] or {}
        cur.ft[pass .. "|" .. stage] = ft
        ft[#ft + 1] = dt
        -- a slow frame, noted with where it was and how long since a picture was taken
        if dt > 0.03 then
            cur.slow = cur.slow or {}
            local building = 0
            local BM = BMX.BikeMesh
            for _, v in pairs(BM and BM.Status and BM.Status() or {}) do
                if v == "building" or v == "warming" then building = building + 1 end
            end
            cur.slow[#cur.slow + 1] = string.format("%.1f ms p%d %s t%.2f at %s, %.0f s into the session (%s frames after a picture; heap %+.0f KB, %d models building; BMX Lua ms: %s)",
                dt * 1000, pass, stage, t, os.date("%H:%M:%S"), SysTime(), cur.shotFrame and tostring(f - cur.shotFrame) or "no", dHeap, building, dearest(spent))
        end
    end
    local drawn = cur.plyDrawn == f
    local posed = ply.bmxPoseFrame == f
    if drawn then cell.drawn = cell.drawn + 1 end
    if drawn and posed then cell.posed = cell.posed + 1 end
    if IsValid(bike) and cur.bikeDrawnAt == f then cell.bikeDrawn = cell.bikeDrawn + 1 end
    local P = PASSES[pass]
    -- The fists and feet against what the vehicle drew, judged where the rider means to
    -- hold the bars: not a style pose in the air, not a board (it has no bars).
    local bad
    -- (not the frame after a picture: the capture made it ~60 ms long, and a rider posed
    -- from the frame before's targets is that much behind: 8-12 u on a scooter's or a
    -- board's kicking foot. Not what a player sees; counted apart.)
    local afterShot = cur.shotFrame == f - 1
    if afterShot then cell.afterShot = (cell.afterShot or 0) + 1 end
    if not afterShot and drawn and IsValid(bike) and bike.ikTargets and not (bike.poseW and next(bike.poseW)) and stage ~= "air" then
        local ik = bike.ikTargets
        local worst, worstK = 0, "?"
        -- (a board has no grips: its hand targets are not where the hands belong)
        local board = bike.Bike and bike:Bike().family == "board"
        for _, side in ipairs(board and {} or { "r", "l" }) do
            local m = handMiss(ply, ik, side)
            if m and m > worst then worst, worstK = m, side .. "Hand" end
        end
        for _, k in ipairs({ "rFoot", "lFoot" }) do
            local m = footMiss(ply, ik, k)
            if m and m > worst then worst, worstK = m, k end
        end
        cell.miss[#cell.miss + 1] = worst
        if worst <= BAD_MISS and not cur.pelvisUsual then
            local seatOff = BMX.SeatFor and BMX.SeatFor(bike:Bike(), bike:Cfg(), "rider")
            local pb = ply:LookupBone("ValveBiped.Bip01_Pelvis")
            local pp = pb and ply:GetBonePosition(pb)
            if seatOff and pp then
                cur.pelvisUsual = (pp - bike:LocalToWorld(seatOff.offset)):Length()
                cur.originUsual = (ply:GetPos() - bike:LocalToWorld(seatOff.offset)):Length()
            end
        end
        if worst > BAD_MISS then
            -- where the body is against the seat: the whole rider displaced (the engine's
            -- interpolation of the player after a jump) or only a limb (the pose)
            local seatOff = BMX.SeatFor and BMX.SeatFor(bike:Bike(), bike:Cfg(), "rider")
            local pb = ply:LookupBone("ValveBiped.Bip01_Pelvis")
            local pp = pb and ply:GetBonePosition(pb)
            local d = (seatOff and pp) and (pp - bike:LocalToWorld(seatOff.offset)):Length() or -1
            cur.pelvisSeen = cur.pelvisSeen or {}
            local od = seatOff and (ply:GetPos() - bike:LocalToWorld(seatOff.offset)):Length() or -1
            local R = bike.bmxRide
            local extra = R and string.format(", grounded %s push %.2f air %.2f kick %.2f", tostring(bike:GetGrounded()),
                bike.GetPushPhase and bike:GetPushPhase() or -9, R.air or -1, R.pushBend or -1) or ""
            bad = string.format("%s %.0fu off, pelvis %.0fu from the seat (usually %.0f), the player's origin %.0fu (usually %.0f), %.0f u/s",
                worstK, worst, d, cur.pelvisUsual or -1, od, cur.originUsual or -1, bike:GetVelocity():Length()) .. extra
        end
    end
    if drawn and not posed and IsValid(bike) then bad = "drawn without the pose" end
    if bad then
        cell.bad = cell.bad + 1
        cell.why = bad
    end
    -- Pictures.
    local shotKey = P.mode == "first" and (pass .. "|" .. stage) or key
    if P.shots and not NOSHOTS and not cur.shotDone[shotKey] and cur.shotFrame ~= f - 1 then
        cur.shotDone[shotKey] = true
        shoot(string.format("%s_%s_%s_az%03d_el%+03d", cur.id, P.mode, stage, bucket, math.floor(el + 0.5)))
    end
    if bad and cur.badShots < 40 and not cur.shotDone["bad" .. key] then
        cur.shotDone["bad" .. key] = true
        cur.badShots = cur.badShots + 1
        shoot(string.format("BAD_%s_p%d_%s_az%03d_el%+03d", cur.id, pass, stage, bucket, math.floor(el + 0.5)))
    end
end)

local function q(list, f)
    if #list == 0 then return 0 end
    local c = {}
    for i, v in ipairs(list) do c[i] = v end
    table.sort(c)
    return c[math.max(1, math.ceil(f * #c))]
end

local function finish()
    if not cur then return end
    local r = cur
    cur = nil
    RunConsoleCommand("bmx_cam_first", "0")
    local out = {}
    local pre = q(r.pre, 0.5) * 1000
    local allFt = {}
    for _, l in pairs(r.ft) do for _, v in ipairs(l) do allFt[#allFt + 1] = v end end
    out[#out + 1] = string.format("== %s: frames on foot before %.1f ms median | riding %.1f ms median, p95 %.1f, max %.1f | pictures %d",
        r.id, pre, q(allFt, 0.5) * 1000, q(allFt, 0.95) * 1000, q(allFt, 1) * 1000, r.shots)
    if r.slow then out[#out + 1] = "  slow frames: " .. table.concat(r.slow, "; ", 1, math.min(#r.slow, 8)) end
    -- Per pass: frames, the rider drawn and posed, worst cells.
    for pass = 1, r.passes do
        local P = PASSES[pass]
        local n, drawn, posed, bikeDrawn, bad, misses = 0, 0, 0, 0, 0, {}
        local skipped = 0
        local badCells = {}
        for key, c in pairs(r.cells) do
            local kp, ks, kb = key:match("^(%d+)|([^|]+)|(%d+)$")
            if tonumber(kp) == pass then
                n, drawn, posed, bikeDrawn, bad = n + c.n, drawn + c.drawn, posed + c.posed, bikeDrawn + c.bikeDrawn, bad + c.bad
                skipped = skipped + (c.afterShot or 0)
                for _, m in ipairs(c.miss) do misses[#misses + 1] = m end
                if c.bad > 0 then badCells[#badCells + 1] = string.format("%s@%s %d/%d (%s)", ks, kb, c.bad, c.n, c.why or "?") end
            end
        end
        table.sort(badCells)
        local ftl = {}
        for _, s in ipairs(STAGES) do
            local l = r.ft[pass .. "|" .. s[1]]
            if l then ftl[#ftl + 1] = string.format("%s %.1f", s[1], q(l, 0.95) * 1000) end
        end
        out[#out + 1] = string.format("  pass %d (%s, pitch %d): %d frames, rider drawn %d, posed %d, vehicle drawn %d, bad %d (%d after a picture not judged) | limb miss median %.1f p95 %.1f max %.1f u",
            pass, P.mode, P.pitch, n, drawn, posed, bikeDrawn, bad, skipped, q(misses, 0.5), q(misses, 0.95), q(misses, 1))
        out[#out + 1] = "    p95 frame ms by stage: " .. table.concat(ftl, ", ")
        if #badCells > 0 then
            local shown = {}
            for i = 1, math.min(8, #badCells) do shown[i] = badCells[i] end
            out[#out + 1] = string.format("    BAD cells %d of %d (stage@azimuth bad/frames): %s%s", #badCells, table.Count(r.cells) / r.passes,
                table.concat(shown, "; "), #badCells > 8 and "; ..." or "")
        end
    end
    local s = table.concat(out, "\n")
    print("[camsweep] " .. s)
    net.Start("camsweep_result") net.WriteString(s) net.SendToServer()
end

net.Receive("camsweep_go", function()
    local id = net.ReadString()
    local bi = net.ReadUInt(16)
    local passes = net.ReadUInt(8)
    local passLen = net.ReadFloat()
    local t0 = net.ReadFloat()
    if cur then finish() end
    file.CreateDir("camsweep")
    local r = { id = id, passes = passes, passLen = passLen, t0 = t0, cells = {}, ft = {}, pre = {},
                shots = 0, badShots = 0, shotDone = {} }
    cur = r
    timer.Simple(1.0, function()
        if cur ~= r or bi == 0 then return end
        r.bike = Entity(bi)
        if IsValid(r.bike) then
            local orig = r.bike.Draw
            local timedDraw = timed("vehicle Draw", orig)
            r.bike.Draw = function(self, ...) r.bikeDrawnAt = FrameNumber() return timedDraw(self, ...) end
        end
    end)
    timer.Simple(math.max(0, t0 - CurTime()) + passes * passLen + 0.3, function() if cur == r then finish() end end)
end)

concommand.Add("camsweep_unhook", function()
    for _, h in ipairs({ "CreateMove", "PostPlayerDraw", "PostRender" }) do hook.Remove(h, "camsweep") end
    if C.origChase then hook.Add("CalcView", "BMX.ChaseCam", C.origChase) C.origChase, C.chaseWrapped = nil, nil end
    for _, h in ipairs(C.wrappedHooks or {}) do hook.Add(h[1], h[2], h[3]) end
    C.wrappedHooks, C.hooksTimed = {}, nil
    cur = nil
end)
print("[camsweep] client ready " .. BMX.Version)
