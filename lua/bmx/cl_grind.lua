--[[--------------------------------------------------------------------------
    bmx/cl_grind.lua

    What a grind looks and sounds like: sparks thrown back off the contact,
    and a metal scrape that rises in pitch with speed. The server decides the
    grind (sv_grind.lua) and networks which one it is (ENT:GetGrind):

        1  crank grind: the chainring on the pipe
        2  pegs on the left, 3 pegs on the right: both pegs on the edge
----------------------------------------------------------------------------]]

BMX = BMX or {}

-- Where sparks come from, entity-local, for a grind code.
function BMX.GrindContacts(ent, code)
    -- A skateboard's grinds have codes of their own (4 and up: sh_board.lua).
    if code >= 4 and BMX.Board and BMX.Board.SparkPoints then return BMX.Board.SparkPoints(code) end
    -- From the vehicle's own grind points (`grindPoints`, sh_vehicles.lua): the
    -- same ones the server grinds on.
    local gp = BMX.GrindPointsFor(ent:Bike(), ent:Cfg())
    if code == 1 then return gp.crank and { gp.crank } or {} end
    local p = gp.pegs
    if not p then return {} end
    local y = (code == 2 and 1 or -1) * p.y
    local out = {}
    for _, x in ipairs(p.x) do out[#out + 1] = Vector(x, y, p.z) end
    return out
end

local SPARK_RATE = 40      -- per second per contact, at full speed

local live = {}

local function sparks(ent, code, dt, frac)
    local em = live[ent].em
    if not em then
        em = ParticleEmitter(ent:GetPos())
        live[ent].em = em
    end
    if not em then return end
    local back = -ent:GetVelocity():GetNormalized()
    live[ent].owed = (live[ent].owed or 0) + SPARK_RATE * dt * (0.3 + frac)
    for _, lp in ipairs(BMX.GrindContacts(ent, code)) do
        local at = ent:LocalToWorld(lp)
        for _ = 1, math.floor(live[ent].owed) do
            local p = em:Add("effects/spark", at)
            if p then
                p:SetVelocity(back * math.Rand(60, 180) + VectorRand() * 50 + Vector(0, 0, math.Rand(20, 90)))
                p:SetDieTime(math.Rand(0.25, 0.6))
                p:SetStartAlpha(255)
                p:SetEndAlpha(0)
                p:SetStartSize(math.Rand(1, 2))
                p:SetEndSize(0)
                p:SetStartLength(math.Rand(3, 7))
                p:SetEndLength(0)
                p:SetGravity(Vector(0, 0, -500))
                p:SetColor(255, math.random(170, 220), 90)
                p:SetCollide(true)
                p:SetBounce(0.3)
            end
        end
    end
    live[ent].owed = live[ent].owed % 1
end

local last = 0
hook.Add("Think", "BMX.Grind", function()
    local now = CurTime()
    local dt = now - last
    if dt <= 0 then return end
    last = now

    for ent, s in pairs(live) do
        if not IsValid(ent) or (ent.GetGrind and ent:GetGrind() == 0) then
            if s.patch then s.patch:Stop() end
            if s.em then s.em:Finish() end
            live[ent] = nil
        end
    end

    for _, ent in ipairs(ents.FindByClass("bmx_*")) do
        local code = ent.IsBMX and ent.GetGrind and ent:GetGrind() or 0
        if code > 0 then
            live[ent] = live[ent] or {}
            local s = live[ent]
            local S = BMX.Sounds.grind
            local cfg = ent:Cfg()
            local top = BMX.Gears.TopCeiling(ent, cfg)
            local frac = math.Clamp(ent:GetVelocity():Length() / math.max(top, 1), 0, 1)
            if not s.patch then
                s.patch = CreateSound(ent, S.path)
                s.patch:SetSoundLevel(S.level)
                s.patch:PlayEx(S.vol * BMX.VolRide(), S.pitch[1])
            end
            -- The scrape follows the same two switches as the rest of the sound
            -- (cl_sound.lua): the player's ride volume, and the admin's mute.
            s.patch:ChangeVolume(BMX.SoundsOn() and S.vol * BMX.VolRide() or 0, 0.1)
            s.patch:ChangePitch(Lerp(frac, S.pitch[1], S.pitch[2]), 0.1)
            sparks(ent, code, dt, frac)
        end
    end
end)

hook.Add("ShutDown", "BMX.GrindStop", function()
    for _, s in pairs(live) do
        if s.patch then s.patch:Stop() end
        if s.em then s.em:Finish() end
    end
    live = {}
end)
