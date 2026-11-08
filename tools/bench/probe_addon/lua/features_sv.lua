-- EVERY FEATURE, BENCHMARKED (tools/bench/sp.sh features): in one singleplayer session,
-- scene after scene, the player riding or using each thing the addon does, measured the
-- same way each time: the client's frame (realprobe_cl.lua: frame times, the addon's hooks,
-- each vehicle's Draw) and the server's cost (every BMX hook and vehicle method, timed
-- here). Results: data/probe/features_cl.txt and features_sv.txt.
FEAT = FEAT or {}
local F = FEAT
local o = player.GetHumans()[1]
local base = Vector(4000, 4000, -11000)
local g = util.TraceLine({ start = base, endpos = base - Vector(0, 0, 3000), mask = MASK_SOLID_BRUSHONLY }).HitPos
F.ents = F.ents or {}
file.Delete("probe/features_cl.txt")
file.Delete("probe/features_sv.txt")

local function clearAll()
    hook.Remove("Think", "feat_drive")
    if IsValid(o) then
        if IsValid(o:GetVehicle()) then o:ExitVehicle() end
        if BMX.Worn and BMX.Worn.Of(o) then BMX.Worn.Unequip(o) end
        o.BMXScripted = nil
    end
    for _, e in ipairs(F.ents) do if IsValid(e) then e:Remove() end end
    F.ents = {}
    if BMX.Park and BMX.Park.Clear then pcall(BMX.Park.Clear) end
    o:SendLua([[RunConsoleCommand("bmx_cinematic","0") RunConsoleCommand("bmx_cam_first","0") RunConsoleCommand("bmx_replay_buffer","1") if BMX.ReplayActive and BMX.ReplayActive() then RunConsoleCommand("bmx_replay") end if BMX.FilmerViewing and BMX.FilmerViewing() then RunConsoleCommand("bmx_filmer_view") end if IsValid(BMX_FEAT_MENU) then BMX_FEAT_MENU:Close() end]])
end

local function spawnAt(class, pos, ang)
    local e = ents.Create(class)
    e:SetPos(pos) e:SetAngles(ang or Angle(0, 90, 0))
    e:Spawn() e:Activate()
    F.ents[#F.ents + 1] = e
    return e
end

-- The player rides `id` round a wide circle, scripted (as the camera sweep does).
local function ride(id)
    o:SetPos(g + Vector(-80, 0, 8))
    o.BMXScripted = true
    local def = BMX.Vehicles[id]
    local bike, worn
    if def.worn then
        worn = BMX.Worn.Equip(o, id)
    else
        bike = spawnAt(BMX.ClassFor(id), g + Vector(0, 0, 14))
        timer.Simple(0.3, function() if IsValid(bike) then o:EnterVehicle(bike:GetPod()) end end)
    end
    local t0 = CurTime()
    hook.Add("Think", "feat_drive", function()
        local inp
        if IsValid(bike) then inp = bike.input elseif worn then local w = BMX.Worn.Of(o) inp = w and w.input end
        if not inp then return end
        local t = CurTime() - t0
        local st = IsValid(bike) and bike.st or {}
        inp.throttle, inp.leanTarget, inp.brakeRear, inp.brakeFront = 0.35, 0.3, 0, 0
        if id == "unicycle" then
            inp.leanTarget = math.Clamp(-4 * ((st.roll or 0) + 0.15 * (st.rollRate or 0)) + 0.05, -1, 1)
            local x = math.Clamp(0.25 - 4 * ((st.pitch or 0) + 0.15 * (st.pitchRate or 0)), -1, 1)
            inp.throttle, inp.brakeRear = math.max(x, 0), math.max(-x, 0)
        end
        if def.family == "board" then
            local b = BMX.Board.InputOf(inp)
            b.fwd, b.side = 1, 0.3
        end
        if worn then
            inp.fwd, inp.w, inp.turn, inp.eyeYaw = 1, true, 1, math.rad(90 + t * 20)
        end
        -- a hop every 4 s, so the air, the landing and their sounds are in the scene
        if IsValid(bike) and def.family ~= "board" and id ~= "unicycle" then
            local ph = t % 4
            if ph > 2.0 and ph < 2.4 then
                if not bike.featHop then bike.hopCharge, bike.hopHeld, bike.featHop = 0, true, true end
                inp.hop = true
            else
                if bike.featHop then bike.hopRelease, bike.featHop = true, nil end
                inp.hop = false
            end
        end
    end)
    return bike
end

-- Server cost during a scene: every BMX hook and each vehicle's methods, timed.
local function serverMeasure(label, secs)
    local acc, wrapped = {}, {}
    local function wrap(name, fn)
        return function(...)
            local s = SysTime()
            local a, b, c, d, e = fn(...)
            acc[name] = (acc[name] or 0) + (SysTime() - s)
            return a, b, c, d, e
        end
    end
    for ev, list in pairs(hook.GetTable()) do
        for id, fn in pairs(list) do
            if isstring(id) and id:sub(1, 3) == "BMX" then
                wrapped[#wrapped + 1] = { ev, id, fn }
                hook.Add(ev, id, wrap("hook " .. ev, fn))
            end
        end
    end
    local entsW = {}
    for _, e in ipairs(ents.FindByClass("bmx_*")) do
        for _, m in ipairs({ "Think", "PhysicsSimulate", "PhysicsCollide" }) do
            if isfunction(e[m]) then entsW[#entsW + 1] = { e, m, e[m] } e[m] = wrap(m, e[m]) end
        end
    end
    local t0 = SysTime()
    timer.Simple(secs, function()
        for _, h in ipairs(wrapped) do hook.Add(h[1], h[2], h[3]) end
        for _, x in ipairs(entsW) do if IsValid(x[1]) then x[1][x[2]] = x[3] end end
        local total, rows = 0, {}
        for k, v in pairs(acc) do total = total + v rows[#rows + 1] = { k, v } end
        table.sort(rows, function(a, b) return a[2] > b[2] end)
        local el = SysTime() - t0
        local top = {}
        for i = 1, math.min(3, #rows) do top[i] = string.format("%s %.1f", rows[i][1], rows[i][2] * 1000 / el) end
        file.Append("probe/features_sv.txt", string.format("%-34s server %6.2f ms/s | %s\n", label, total * 1000 / el, table.concat(top, ", ")))
    end)
end

local function measure(label, k)
    o:SendLua(string.format([[REALPROBE.Measure(%q, 6, function(s) file.Append("probe/features_cl.txt", s .. "\n") end)]], label))
    serverMeasure(label, 6)
    timer.Simple(7, k)
end

local scenes = {}
local function scene(label, setup, settle) scenes[#scenes + 1] = { label = label, setup = setup, settle = settle or 3 } end

scene("idle: addon loaded, nothing spawned", function() o:SetPos(g + Vector(-300, 0, 8)) o:SetEyeAngles(Angle(8, 0, 0)) end)
for _, id in ipairs({ "stock", "cruiser", "mini", "road", "fixie", "city", "unicycle", "penny", "tandem", "dh",
        "scooter", "ebike", "emoto", "dirtbike", "moped", "skateboard", "skates" }) do
    scene("riding " .. id, function() ride(id) end, 4)
end
scene("riding stock, replay buffer off", function() ride("stock") o:SendLua([[RunConsoleCommand("bmx_replay_buffer","0")]]) end, 4)
scene("replay playback", function()
    ride("stock")
    timer.Simple(5, function() o:SendLua([[RunConsoleCommand("bmx_replay")]]) end)
end, 7)
scene("cinematic camera", function() ride("stock") timer.Simple(1, function() o:SendLua([[RunConsoleCommand("bmx_cinematic","1")]]) end) end, 4)
scene("first-person camera", function() ride("stock") o:SendLua([[RunConsoleCommand("bmx_cam_first","1")]]) end, 4)
scene("filmer camera watching", function()
    ride("stock")
    spawnAt("bmx_filmer_cam", g + Vector(300, 300, 40), Angle(0, 0, 0))
    timer.Simple(1.5, function() o:SendLua([[RunConsoleCommand("bmx_filmer_view")]]) end)
end, 4)
scene("skate park preset (street_plaza) ridden through", function()
    if BMX.Park and BMX.Park.LoadPreset then pcall(BMX.Park.LoadPreset, o, "street_plaza", g + Vector(600, 0, 0), 0) end
    ride("stock")
end, 5)
scene("bike rack with 4 bikes + rental machine", function()
    o:SetPos(g + Vector(-300, 0, 8)) o:SetEyeAngles(Angle(8, 0, 0))
    spawnAt("bmx_bike_rack", g + Vector(0, -120, 4), Angle(0, 90, 0))
    spawnAt("bmx_rental", g + Vector(0, 120, 4), Angle(0, 180, 0))
    for i = 1, 4 do spawnAt(BMX.ClassFor("stock"), g + Vector(40, -180 + i * 30, 14)) end
end, 4)
scene("16 parked vehicles in view", function()
    o:SetPos(g + Vector(-400, 0, 8)) o:SetEyeAngles(Angle(8, 0, 0))
    local kinds = { "stock", "road", "dirtbike", "emoto", "scooter", "tandem", "penny", "dh" }
    for i = 1, 16 do spawnAt(BMX.ClassFor(kinds[(i - 1) % 8 + 1]), g + Vector(((i - 1) % 4) * 80, (math.floor((i - 1) / 4) - 1.5) * 70, 14)) end
end, 5)
scene("BMX menu open", function()
    o:SetPos(g + Vector(-300, 0, 8))
    o:SendLua([[RunConsoleCommand("bmx_menu") timer.Simple(0.5, function() for _, p in ipairs(vgui.GetWorldPanel():GetChildren()) do if p.GetTitle and tostring(p:GetTitle()):find("BMX") then BMX_FEAT_MENU = p end end end)]])
end, 3)

local i = 0
local function nextScene()
    clearAll()
    i = i + 1
    local sc = scenes[i]
    if not sc then
        file.Append("probe/features_sv.txt", "DONE\n")
        return
    end
    timer.Simple(1, function()
        sc.setup()
        timer.Simple(sc.settle, function() measure(sc.label, nextScene) end)
    end)
end
nextScene()
