--[[--------------------------------------------------------------------------
    bmx/sv_city.lua

    The server's half of the city: spawning the colliders (bmx_city_solid) for
    the parts of it that stand inside the park, and the admin commands. The
    buildings themselves need nothing here -- they are outside the map's box,
    where nobody can reach them, and cl_city.lua draws them.

    Commands:
        bmx_city_rebuild   respawn the colliders (after changing bmx_city)
        bmx_city_info      what the current map's city contains
----------------------------------------------------------------------------]]

local City = BMX.City

function City.SpawnSolids()
    for _, e in ipairs(ents.FindByClass("bmx_city_solid")) do e:Remove() end
    City._layoutMap = nil
    if not City.Enabled() then return 0 end
    local L = City.Layout()
    if not L then return 0 end
    local n = 0
    for _, s in ipairs(L.solids) do
        local b = s.boxes[1]
        local e = ents.Create("bmx_city_solid")
        if IsValid(e) then
            -- handed over as a field and networked from Initialize: the
            -- datatable is set up by Spawn, not before it, in the test shim
            e.CitySolidName = s.name
            -- origin at the first box's centre: inside the park, so the entity
            -- is in a real visleaf
            e:SetPos(Vector((b[1] + b[4]) / 2, (b[2] + b[5]) / 2, (b[3] + b[6]) / 2))
            e:Spawn()
            n = n + 1
        end
    end
    MsgN(string.format("[BMX] city: %d buildings, %d subway lines, %d solids on %s",
        #L.buildings, #L.lines, n, game.GetMap()))
    return n
end

hook.Add("InitPostEntity", "BMXCity", function() City.SpawnSolids() end)
hook.Add("PostCleanupMap", "BMXCity", function() City.SpawnSolids() end)

-- Nobody picks up a viaduct.
hook.Add("PhysgunPickup", "BMXCity", function(_, ent)
    if IsValid(ent) and ent:GetClass() == "bmx_city_solid" then return false end
end)
hook.Add("CanTool", "BMXCity", function(_, tr)
    if tr and IsValid(tr.Entity) and tr.Entity:GetClass() == "bmx_city_solid" then return false end
end)
hook.Add("CanProperty", "BMXCity", function(_, _, ent)
    if IsValid(ent) and ent:GetClass() == "bmx_city_solid" then return false end
end)

concommand.Add("bmx_city_rebuild", function(ply)
    if IsValid(ply) and not ply:IsAdmin() then return end
    local n = City.SpawnSolids()
    local msg = "[BMX] city rebuilt: " .. n .. " solids"
    if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, msg) else MsgN(msg) end
end, nil, "BMX: respawn the city's colliders on this map (admin)")

concommand.Add("bmx_city_info", function(ply)
    local L = City.Layout()
    local lines = {}
    if not L then
        lines[1] = "[BMX] no city for " .. game.GetMap()
    else
        lines[1] = string.format("[BMX] city on %s: %s, %d buildings, %d quads, %d lines, %d solids",
            game.GetMap(), City.Enabled() and "on" or "off (bmx_city 0)", #L.buildings, L.quads, #L.lines, #L.solids)
        for _, l in ipairs(L.lines) do
            lines[#lines + 1] = string.format("  %s along %s at %d, deck z %d, every %ds, %d cars",
                l.name, l.axis, l.at, l.deck, l.period, l.cars)
        end
    end
    for _, s in ipairs(lines) do
        if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, s) else MsgN(s) end
    end
end, nil, "BMX: describe this map's city")
