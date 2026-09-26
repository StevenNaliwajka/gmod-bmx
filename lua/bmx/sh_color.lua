--[[--------------------------------------------------------------------------
    bmx/sh_color.lua

    The bike's paint: a rainbow palette, and every way to choose from it.

        K (riding)            the next colour, in a puff of smoke of that colour
        context menu (C)      right-click the bike: Bike colour -> any of them
        bmx_color <name|n>    the bike you are on, or the one you are looking at
        bmx_color_default     the colour bikes YOU spawn start in (client convar)

    The colour is one networked integer, an index into BMX.Palette, so every
    client draws the same bike and a duplicator copy keeps its paint.

    WHY K IS READ WITH PlayerButtonDown. The usercmd a seated player sends
    carries IN_* action bits, and none of them is "K". PlayerButtonDown sees
    raw keys, and it runs on the server, which is the one realm allowed to
    change a networked variable.
----------------------------------------------------------------------------]]

BMX = BMX or {}

-- Rainbow order, then the two neutrals. The first entry is the stock bike's.
BMX.Palette = {
    { name = "Red",     color = Color(205,  35,  45) },
    { name = "Orange",  color = Color(240, 120,  30) },
    { name = "Yellow",  color = Color(245, 205,  40) },
    { name = "Lime",    color = Color(150, 215,  40) },
    { name = "Green",   color = Color( 40, 170,  70) },
    { name = "Teal",    color = Color( 30, 170, 160) },
    { name = "Cyan",    color = Color( 40, 190, 230) },
    { name = "Blue",    color = Color( 40,  90, 220) },
    { name = "Indigo",  color = Color( 80,  60, 190) },
    { name = "Purple",  color = Color(140,  60, 200) },
    { name = "Magenta", color = Color(215,  50, 170) },
    { name = "Pink",    color = Color(245, 130, 180) },
    { name = "White",   color = Color(235, 235, 238) },
    { name = "Black",   color = Color( 30,  30,  34) },
}

function BMX.PaletteColor(i)
    local p = BMX.Palette[i] or BMX.Palette[1]
    return p.color
end

-- A palette index from a name ("blue", any case) or a number, or nil.
function BMX.PaletteIndex(v)
    local n = tonumber(v)
    if n then
        n = math.floor(n)
        return BMX.Palette[n] and n or nil
    end
    v = string.lower(tostring(v or ""))
    for i, p in ipairs(BMX.Palette) do
        if string.lower(p.name) == v then return i end
    end
    return nil
end

local COOLDOWN = 0.35      -- seconds between K presses that count

if SERVER then
    util.AddNetworkString("bmx_puff")

    --------------------------------------------------------------------------
    -- Paint a bike. `puff` adds the smoke and the pop, which is what K and the
    -- menu do; a bike spawned in a colour just is that colour.
    --------------------------------------------------------------------------
    function BMX.SetBikeColor(bike, i, puff, by)
        if not IsValid(bike) or not bike.IsBMX or not BMX.Palette[i] then return false end
        if hook.Run("BMX_CanRecolor", bike, i) == false then return false end
        bike:SetColorIndex(i)
        if IsValid(by) then BMX.RememberColor(by, i) end
        duplicator.StoreEntityModifier(bike, "bmx_color", { i = i })
        if puff then
            net.Start("bmx_puff")
                net.WriteEntity(bike)
                net.WriteUInt(i, 5)
            net.SendPVS(bike:GetPos())
            local S = BMX.Sounds.recolor
            bike:EmitSound(BMX.SoundFile("recolor"), S.level, math.random(96, 108), S.vol)
        end
        return true
    end

    --------------------------------------------------------------------------
    -- A COLOUR YOU CHOOSE IS YOUR COLOUR. Recolouring a bike (K, the menu,
    -- bmx_color) makes that the colour your next bike spawns in: remembered
    -- here for this session, and written to your bmx_color_default so it is
    -- still yours after a rejoin (it is an archived client convar). The
    -- server-side copy is what a spawn reads first, because the convar's new
    -- value takes a round trip to reach the server.
    --------------------------------------------------------------------------
    function BMX.RememberColor(ply, i)
        if not IsValid(ply) or not BMX.Palette[i] then return end
        ply.BMXColor = i
        ply:ConCommand("bmx_color_default " .. string.lower(BMX.Palette[i].name))
    end

    function BMX.PreferredColor(ply)
        if not IsValid(ply) then return nil end
        if ply.BMXColor and BMX.Palette[ply.BMXColor] then return ply.BMXColor end
        return ply.GetInfo and BMX.PaletteIndex(ply:GetInfo("bmx_color_default")) or nil
    end

    duplicator.RegisterEntityModifier("bmx_color", function(ply, ent, data)
        if data and data.i then BMX.SetBikeColor(ent, data.i, false) end
    end)

    -- K, while riding: the next colour round the palette.
    hook.Add("PlayerButtonDown", "BMX.RecolorKey", function(ply, button)
        if button ~= KEY_K then return end
        local bike = ply.BMXBike
        if not IsValid(bike) or bike:GetDriver() ~= ply then return end
        if CurTime() < (ply.BMXNextRecolor or 0) then return end
        ply.BMXNextRecolor = CurTime() + COOLDOWN
        local n = #BMX.Palette
        BMX.SetBikeColor(bike, (bike:GetColorIndex() % n) + 1, true, ply)
    end)

    -- The bike a player means: the one they ride, else the one they look at.
    local function bikeFor(ply)
        if IsValid(ply.BMXBike) and ply.BMXBike:GetDriver() == ply then return ply.BMXBike end
        local tr = ply:GetEyeTrace()
        local e = tr and tr.Entity
        if IsValid(e) and e.IsBMX and e:GetPos():Distance(ply:GetPos()) < 250
            and not IsValid(e:GetDriver()) then
            return e
        end
    end
    BMX.BikeFor = bikeFor

    concommand.Add("bmx_color", function(ply, _, args)
        if not IsValid(ply) then return end
        local names = {}
        for _, p in ipairs(BMX.Palette) do names[#names + 1] = string.lower(p.name) end
        local i = BMX.PaletteIndex(args[1])
        if not i then
            ply:ChatPrint("[BMX] colours: " .. table.concat(names, ", "))
            return
        end
        local bike = bikeFor(ply)
        if not bike then
            ply:ChatPrint("[BMX] ride a bike, or look at one nearby, to paint it.")
            return
        end
        if CurTime() < (ply.BMXNextRecolor or 0) then return end
        ply.BMXNextRecolor = CurTime() + COOLDOWN
        BMX.SetBikeColor(bike, i, true, ply)
    end)
end

if CLIENT then
    CreateClientConVar("bmx_color_default", "red", true, true,
        "Colour of the bikes you spawn: a name (red, blue, ...) or a number.")

    --------------------------------------------------------------------------
    -- The puff: smoke in the new colour, with some of the old white through
    -- it, thrown outward from the frame and fading as it spreads.
    --------------------------------------------------------------------------
    net.Receive("bmx_puff", function()
        local bike = net.ReadEntity()
        local i = net.ReadUInt(5)
        if not IsValid(bike) then return end
        local col = BMX.PaletteColor(i)
        local centre = bike:LocalToWorld(Vector(0, 0, 14))
        local em = ParticleEmitter(centre)
        if not em then return end
        for n = 1, 28 do
            local p = em:Add("particle/particle_smokegrenade", centre + VectorRand() * 8)
            if p then
                local white = n % 4 == 0
                p:SetVelocity(VectorRand():GetNormalized() * math.Rand(40, 110) + Vector(0, 0, 30))
                p:SetDieTime(math.Rand(0.8, 1.4))
                p:SetStartAlpha(210)
                p:SetEndAlpha(0)
                p:SetStartSize(math.Rand(6, 10))
                p:SetEndSize(math.Rand(28, 42))
                p:SetRoll(math.Rand(0, 360))
                p:SetRollDelta(math.Rand(-1, 1))
                p:SetAirResistance(90)
                if white then p:SetColor(240, 240, 240) else p:SetColor(col.r, col.g, col.b) end
            end
        end
        em:Finish()
    end)
end

--------------------------------------------------------------------------
-- The context menu (hold C, right-click the bike): Bike colour -> a colour.
--------------------------------------------------------------------------
if properties then
    properties.Add("bmx_color", {
        MenuLabel = "Bike colour",
        Order = 600,
        MenuIcon = "icon16/color_wheel.png",

        Filter = function(self, ent, ply)
            if not IsValid(ent) or not ent.IsBMX then return false end
            if not gamemode.Call("CanProperty", ply, "bmx_color", ent) then return false end
            return true
        end,

        MenuOpen = function(self, option, ent)
            local sub = option:AddSubMenu()
            for i, p in ipairs(BMX.Palette) do
                sub:AddOption(p.name, function() self:Paint(ent, i) end)
            end
        end,

        Action = function() end,

        Paint = function(self, ent, i)
            self:MsgStart()
                net.WriteEntity(ent)
                net.WriteUInt(i, 5)
            self:MsgEnd()
        end,

        Receive = function(self, length, ply)
            local ent = net.ReadEntity()
            local i = net.ReadUInt(5)
            if not properties.CanBeTargeted(ent, ply) then return end
            if not self:Filter(ent, ply) then return end
            BMX.SetBikeColor(ent, i, true, ply)
        end,
    })
end
