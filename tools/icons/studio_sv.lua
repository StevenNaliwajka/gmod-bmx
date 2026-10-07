--[[--------------------------------------------------------------------------
    tools/icons/studio_sv.lua -- the icon studio, server half (NOT shipped: tools/
    is ignored by the .gma). tools/icons/shoot.sh copies it onto a test server and
    runs it; see tools/icons/README.md.

    One job at a time: spawn the entry at the stage, freeze it, tell the owner's
    client to shoot it, wait for the PNGs, remove it, next. Park pieces go L, M, S
    so the client can reuse the L camera and the three show their real sizes.
----------------------------------------------------------------------------]]
util.AddNetworkString("bmxstudio_code")
util.AddNetworkString("bmxstudio_shoot")
util.AddNetworkString("bmxstudio_img")
util.AddNetworkString("bmxstudio_done")

STUDIO = STUDIO or {}
local S = STUDIO
-- Up in the air over a corner of the map, away from every spawn point: what is shot
-- here is frozen in place and drawn on its own, so nothing needs to stand under it.
S.STAGE = Vector(300, 700, 1300)

hook.Add("SetupPlayerVisibility", "bmxstudio", function() AddOriginToPVS(S.STAGE + Vector(0, 0, 40)) end)

-- The client that renders: bmxstudio_owner <name> picks one, else the first human.
S.ownerName = S.ownerName
local function owner()
    for _, p in ipairs(player.GetHumans()) do
        if not S.ownerName or p:Nick() == S.ownerName then return p end
    end
end

concommand.Add("bmxstudio_owner", function(p, _, args)
    if IsValid(p) then return end
    S.ownerName = args[1]
end)

-- Which entries to shoot: every BMX spawn-menu row, park L before M before S
-- (so S and M reuse the L camera and show their real size), plus the SWEPs.
function S.Jobs(filter)
    local jobs = {}
    for c, t in SortedPairs(list.Get("SpawnableEntities")) do
        if t.Category and t.Category:find("BMX") and (not filter or c:find(filter)) then
            -- A park shape is one group: every variant and size is shot from one camera,
            -- so Low / Mid / Tall and S / M / L show their real differences.
            local shape = BMX.Park and BMX.Park.Classes[c] and BMX.Park.Classes[c].shape
            local v, sz = c:match("_v(%d)_([sml])$")
            sz = sz or c:match("_([sml])$")
            jobs[#jobs + 1] = { class = c, group = shape and ("bmx_park_" .. shape), shape = shape,
                ord = ({ l = 0, m = 10, s = 20 })[sz or "l"] - tonumber(v or 0) }
        end
    end
    for _, c in ipairs({ "weapon_bmx_board", "weapon_bmx_skates", "weapon_bmx_lock" }) do
        if not filter or c:find(filter) then jobs[#jobs + 1] = { class = c, ord = 0 } end
    end
    table.sort(jobs, function(a, b)
        local ga, gb = a.group or a.class, b.group or b.class
        if ga ~= gb then return ga < gb end
        return a.ord < b.ord
    end)
    return jobs
end

local cur
-- Only what the studio itself made: anything created near the stage while a job spawns.
local made = {}
hook.Add("OnEntityCreated", "bmxstudio", function(e)
    if not (cur and cur.spawning) then return end
    timer.Simple(0, function()
        if IsValid(e) and e:GetPos():DistToSqr(S.STAGE) < 600 * 600 and not e:IsPlayer() then made[#made + 1] = e end
    end)
end)
local function cleanup()
    for _, e in ipairs(made) do SafeRemoveEntity(e) end
    made = {}
end

local function spawnFor(job, ply)
    local cls = job.class
    if cls == "weapon_bmx_board" then cls = "bmx_skateboard" end
    if cls:find("^weapon_") then return nil end              -- drawn by the client
    local stored = scripted_ents.GetStored(cls)
    local ent
    local tr = { Hit = true, HitPos = S.STAGE, HitNormal = Vector(0, 0, 1), Entity = game.GetWorld() }
    local sf = stored and stored.t and stored.t.SpawnFunction
    if sf then
        local ok, r = pcall(sf, stored.t, ply, tr, cls)
        ent = ok and r or nil
        if not ok then print("[studio] SpawnFunction failed", cls, r) end
    end
    if not IsValid(ent) then
        ent = ents.Create(cls)
        if not IsValid(ent) then return nil end
        ent:SetPos(S.STAGE)
        ent:Spawn()
        ent:Activate()
    end
    local a = ent:GetAngles()
    ent:SetAngles(Angle(a.p, 0, a.r))
    local po = ent:GetPhysicsObject()
    if IsValid(po) then po:EnableMotion(false) end
    return ent
end

function S.Next()
    cleanup()
    cur = table.remove(S.queue or {}, 1)
    if not cur then
        file.CreateDir("bmxstudio")
        file.Write("bmxstudio/_done.txt", "ok")
        print("[studio] all done")
        return
    end
    local ply = owner()
    if not IsValid(ply) then
        file.Write("bmxstudio/_done.txt", "owner gone")
        print("[studio] owner gone")
        return
    end
    cur.spawning = true
    local ent = spawnFor(cur, ply)
    if IsValid(ent) then made[#made + 1] = ent end
    timer.Simple(0.2, function() if cur then cur.spawning = false end end)
    timer.Simple(1.0, function()
        if not cur then return end
        local o = owner()
        if not IsValid(o) then return end
        if IsValid(ent) then
            local a = ent:GetAngles()
            ent:SetAngles(Angle(a.p, 0, a.r))
        end
        net.Start("bmxstudio_shoot")
        net.WriteString(cur.class)
        net.WriteString(cur.group or "")
        net.WriteUInt(IsValid(ent) and ent:EntIndex() or 0, 16)
        net.WriteVector(S.STAGE)
        -- the group's box, for its one camera: every variant of the shape at its largest size
        local mins, maxs = Vector(0, 0, 0), Vector(0, 0, 0)
        if cur.shape then
            local P = BMX.Park
            local def = P.Shapes[cur.shape]
            mins, maxs = Vector(1e9, 1e9, 1e9), Vector(-1e9, -1e9, -1e9)
            for v = 1, (def.variants and #def.variants or 1) do
                local b = P.Build(cur.shape, { #P.SIZES, v })
                for _, k in ipairs({ "x", "y", "z" }) do
                    mins[k] = math.min(mins[k], b.mins[k])
                    maxs[k] = math.max(maxs[k], b.maxs[k])
                end
            end
        end
        net.WriteVector(mins)
        net.WriteVector(maxs)
        net.Send(o)
        cur.deadline = CurTime() + 60
    end)
end

local parts = {}
net.Receive("bmxstudio_img", function(_, ply)
    local name = net.ReadString()
    local i, n = net.ReadUInt(16), net.ReadUInt(16)
    local len = net.ReadUInt(32)
    parts[name] = parts[name] or {}
    parts[name][i] = net.ReadData(len)
    local c = 0
    for _ in pairs(parts[name]) do c = c + 1 end
    if c == n then
        file.CreateDir("bmxstudio")
        file.Write("bmxstudio/" .. name .. ".png", table.concat(parts[name]))
        parts[name] = nil
    end
end)

net.Receive("bmxstudio_done", function()
    local msg = net.ReadString()
    if msg ~= "" then print("[studio] client: " .. msg) end
    timer.Simple(0.5, S.Next)
end)

concommand.Add("bmxstudio_push", function(p)
    if IsValid(p) then return end
    local code = file.Read("bmxstudio_cl.txt", "DATA")
    if not code then return print("[studio] data/bmxstudio_cl.txt is missing") end
    net.Start("bmxstudio_code") net.WriteString(code) net.Send(owner())
    print("[studio] pushed " .. #code .. " bytes")
end)

concommand.Add("bmxstudio_run", function(p, _, args)
    if IsValid(p) then return end
    S.queue = S.Jobs(args[1])
    print("[studio] " .. #S.queue .. " jobs")
    S.Next()
end)

concommand.Add("bmxstudio_stop", function(p)
    if IsValid(p) then return end
    S.queue = {}
    cleanup()
    cur = nil
end)
print("[studio] server ready")
