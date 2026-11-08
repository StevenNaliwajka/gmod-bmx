-- THE CAMERA SWEEP, server half (tools/ride/camsweep.sh; see tools/ride/README.md).
--
-- The animation sweep (sweep_sv.lua) rides a BOT and films it from a fixed camera. A
-- player sees their OWN rider through the chase camera (cl_view.lua), from wherever
-- they have turned the mouse: a report (Workshop bug thread, 2026-11-04) said the
-- riding pose "only shows up in certain camera positions; other ways the character
-- uses the jeep/airboat driving animation". So here the OWNER is the rider: seated on
-- each vehicle in turn and driven through one timeline (parked, pedal, sprint,
-- standing, attack, hop, air with a style pose, landing, a braking turn) several
-- times, while the client half (camsweep_cl.lua) swings the real chase camera round
-- them (it turns the view angles, as a mouse does) and measures every frame.
util.AddNetworkString("camsweep_code")
util.AddNetworkString("camsweep_go")
util.AddNetworkString("camsweep_result")
CAMSWEEP = CAMSWEEP or {}
local SW = CAMSWEEP
local function owner()
    -- "*": the only human (a singleplayer or listen session, where the name may not be known)
    for _, p in ipairs(player.GetHumans()) do if p:Nick() == SW.owner or SW.owner == "*" then return p end end
end
concommand.Add("camsweep_owner", function(p, _, args) if IsValid(p) then return end SW.owner = args[1] end)
file.CreateDir("camsweep")
net.Receive("camsweep_result", function(_, ply)
    if ply ~= owner() then return end
    file.Append("camsweep/result.txt", net.ReadString() .. "\n")
end)
concommand.Add("camsweep_push", function(p)
    if IsValid(p) then return end
    local o = owner() if not IsValid(o) then print("[camsweep] no client") return end
    o:SendLua([[net.Receive("camsweep_code",function() RunString(net.ReadString(),"camsweep") end)]])
    timer.Simple(1, function()
        net.Start("camsweep_code") net.WriteString(file.Read("camsweep_cl.txt", "DATA")) net.Send(o)
        print("[camsweep] pushed")
    end)
end)

local function ground()
    local p = SW.ground or Vector(4000, 4000, -11000)
    local tr = util.TraceLine({ start = p, endpos = p - Vector(0, 0, 3000), mask = MASK_SOLID_BRUSHONLY })
    return tr.HitPos
end

-- The timeline, seconds from the start of a pass. `stage` is what the client files each
-- frame under.
SW.STAGES = {
    { "parked", 0, 1.2 }, { "pedal", 1.2, 3.2 }, { "sprint", 3.2, 4.6 }, { "standing", 4.6, 5.8 },
    { "attack", 5.8, 7.0 }, { "hop", 7.0, 7.6 }, { "air", 7.6, 8.9 }, { "landing", 8.9, 10.0 },
    { "turn", 10.0, 11.5 },
}
SW.PASS = 11.5

function SW.StageAt(t)
    for _, s in ipairs(SW.STAGES) do if t >= s[2] and t < s[3] then return s[1] end end
    return "end"
end

local function cleanup()
    hook.Remove("Think", "camsweep_drive")
    local o = owner()
    if IsValid(o) then
        if IsValid(o:GetVehicle()) then o:ExitVehicle() end
        if BMX.Worn and BMX.Worn.Of(o) then BMX.Worn.Unequip(o) end
        o.BMXScripted = nil
        o:SetNWInt("BMXStance", 1)
    end
    if IsValid(SW.bike) then SW.bike:Remove() end
    SW.bike = nil
end

-- One vehicle, `passes` times over the timeline (the client changes the camera's pitch
-- and mode each pass).
local function run(spec, passes)
    cleanup()
    local o = owner()
    if not IsValid(o) then print("[camsweep] the owner is not connected") return end
    if not o:Alive() then o:Spawn() end
    o.BMXScripted = true
    local g = ground()
    o:SetPos(g + Vector(-80, 0, 8))
    local bike, worn
    local def = BMX.Vehicles and BMX.Vehicles[spec.id]
    if def and def.worn then
        worn = BMX.Worn.Equip(o, spec.id)
    else
        bike = ents.Create(BMX.ClassFor(spec.id))
        bike:SetPos(g + Vector(0, 0, 14))
        bike:SetAngles(Angle(0, 90, 0))
        bike:Spawn() bike:Activate()
        SW.bike = bike
    end
    net.Start("camsweep_go")
    net.WriteString(spec.id)
    net.WriteUInt(IsValid(bike) and bike:EntIndex() or 0, 16)
    net.WriteUInt(passes, 8)
    local t0 = CurTime() + 2.0
    net.WriteFloat(SW.PASS)
    net.WriteFloat(t0)
    net.Send(o)
    timer.Simple(0.6, function()
        if IsValid(bike) then o:EnterVehicle(bike:GetPod()) end
        local hopped, boosted, lastPass = nil, nil, -1
        hook.Add("Think", "camsweep_drive", function()
            local inp
            if IsValid(bike) then inp = bike.input
            elseif worn then local w = BMX.Worn.Of(o) inp = w and w.input end
            if not inp then return end
            local T = CurTime() - t0
            if T < 0 then return end
            local pass = math.floor(T / SW.PASS)
            if pass >= passes then return end
            if pass ~= lastPass then
                lastPass, hopped, boosted = pass, nil, nil
                -- Each pass starts from the same place and heading, at rest, so every
                -- pass's stages are alike (a bike ridden on would leave the open floor).
                if IsValid(bike) then
                    local ph = bike:GetPhysicsObject()
                    bike:SetPos(g + Vector(0, 0, 14)) bike:SetAngles(Angle(0, 90, 0))
                    if IsValid(ph) then ph:SetVelocity(vector_origin) ph:SetAngleVelocity(vector_origin) end
                    bike.st = bike.st or {}
                    -- Thrown off last pass (a hard landing is a crash): back on, or every
                    -- later pass films an empty bike.
                    if o:GetVehicle() ~= bike:GetPod() then
                        if not o:Alive() then o:Spawn() end
                        if IsValid(o:GetVehicle()) then o:ExitVehicle() end
                        o:SetPos(g + Vector(-80, 0, 8))
                        o:EnterVehicle(bike:GetPod())
                        SW.remounts = (SW.remounts or 0) + 1
                        print("[camsweep] " .. spec.id .. ": back on the bike for pass " .. (pass + 1))
                    end
                end
            end
            local t = T - pass * SW.PASS
            local stage = SW.StageAt(t)
            local st = IsValid(bike) and bike.st or {}
            local thr = spec.throttle or 0.4
            local moving = stage ~= "parked" and stage ~= "end"
            inp.throttle = moving and thr or 0
            inp.leanTarget = (stage == "turn") and (spec.lean or 0.45) or 0
            inp.brakeRear = (stage == "turn") and 0.4 or 0
            inp.brakeFront = 0
            if spec.uni then
                inp.leanTarget = math.Clamp(-4 * ((st.roll or 0) + 0.15 * (st.rollRate or 0)) + 0.05, -1, 1)
                local x = math.Clamp((moving and 0.25 or 0) - 4 * ((st.pitch or 0) + 0.15 * (st.pitchRate or 0)), -1, 1)
                inp.throttle, inp.brakeRear = math.max(x, 0), math.max(-x, 0)
            end
            if spec.board then
                local b = BMX.Board.InputOf(inp)
                b.fwd = moving and 1 or 0
                b.side = (stage == "turn") and 0.5 or 0
                b.jump = stage == "hop"
                if b.jump and not b.jumpTap then b.jumpTap, b.jumpTapKeys = true, BMX.Board.Keys(inp) end
            end
            if worn then
                inp.fwd, inp.w, inp.s, inp.a, inp.d = moving and 1 or 0, moving, false, stage == "turn", false
                inp.turn = (stage == "turn") and 1 or 0
                inp.eyeYaw = math.rad(90)
                inp.jump, inp.crouch, inp.brake = stage == "hop", false, false
            end
            inp.sprint = stage == "sprint"
            local stance = (stage == "standing") and 2 or ((stage == "attack") and 3 or 1)
            if o:GetNWInt("BMXStance", 1) ~= stance then o:SetNWInt("BMXStance", stance) end
            if IsValid(bike) and not spec.uni and not spec.board then
                if stage == "hop" then
                    if not hopped then bike.hopCharge, bike.hopHeld, hopped = 0, true, true end
                    inp.hop = true
                else
                    if hopped == true then bike.hopRelease, hopped = true, "done" end
                    inp.hop = false
                end
            end
            if IsValid(bike) and stage == "air" and not boosted then
                boosted = true
                local ph = bike:GetPhysicsObject()
                if IsValid(ph) then ph:AddVelocity(Vector(0, 0, spec.boost or 240)) end
            end
            inp.pose = (spec.pose and stage == "air") and spec.pose or nil
        end)
    end)
    print("[camsweep] running " .. spec.id)
end

-- Every vehicle a player can ride.
SW.RUNS = {
    { id = "stock", pose = "nohander" }, { id = "cruiser" }, { id = "mini" }, { id = "road" },
    { id = "fixie" }, { id = "city", throttle = 0.3 }, { id = "unicycle", uni = true },
    { id = "penny", throttle = 0.3 }, { id = "tandem" }, { id = "dh" },
    { id = "scooter" }, { id = "ebike", throttle = 0.2 }, { id = "emoto", throttle = 0.12, lean = 0.2 },
    { id = "dirtbike", throttle = 0.15, lean = 0.2, pose = "superman", boost = 260 },
    { id = "moped", throttle = 0.15, lean = 0.2 }, { id = "skateboard", board = true },
    { id = "skates" },
}
SW.byId = {}
for _, r in ipairs(SW.RUNS) do SW.byId[r.id] = r end

concommand.Add("camsweep_ground", function(p, _, args)
    if IsValid(p) then return end
    SW.ground = Vector(tonumber(args[1]) or 0, tonumber(args[2]) or 0, tonumber(args[3]) or 0)
end)
-- camsweep_run <passes> [ids...]
concommand.Add("camsweep_run", function(p, _, args)
    if IsValid(p) then return end
    local passes = tonumber(args[1]) or 4
    local list = {}
    for i = 2, #args do if SW.byId[args[i]] then list[#list + 1] = SW.byId[args[i]] end end
    if #list == 0 then list = SW.RUNS end
    file.Delete("camsweep/result.txt")
    local each = 2 + 1.4 + passes * SW.PASS + 1.5
    for k = 1, #list do timer.Simple((k - 1) * each, function() run(list[k], passes) end) end
    timer.Simple(#list * each, function()
        cleanup()
        file.Append("camsweep/result.txt", "DONE\n")
        print("[camsweep] all done")
    end)
    print(string.format("[camsweep] %d vehicles, %.0f s each", #list, each))
end)
concommand.Add("camsweep_stop", function(p) if IsValid(p) then return end cleanup() end)
print("[camsweep] server ready")
