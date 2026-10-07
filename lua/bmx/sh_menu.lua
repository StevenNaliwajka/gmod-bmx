--[[--------------------------------------------------------------------------
    bmx/sh_menu.lua

    THE SPAWN MENU A RIDER CAN REACH WITHOUT SANDBOX'S Q MENU: type /bike (or
    !bike, /bikes, /bmx) in chat, or bmx_menu in the console. A window lists
    every vehicle and every park piece; a click spawns it where you look.

    It matters on servers whose gamemode has no Q menu (Petopia's BMX mode),
    where bmx_spawn in the console was the only door.

    This file is the shared half: what the menu offers (BMX.Menu.Catalog) and
    what counts as the chat command. Both are plain functions of the registries,
    so tests/test_menu.lua checks them, and a vehicle or park piece registered
    later shows up in the menu with nothing to add here.

        sv_menu.lua  the chat command, and placing a park piece from a click
        cl_menu.lua  the window
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Menu = BMX.Menu or {}
local M = BMX.Menu

M.NET_OPEN  = "bmx_menu_open"
M.NET_SPAWN = "bmx_menu_spawn"
M.REACH     = 600       -- units: how far away a click may place a park piece

-- "/bike", "!bike", "/bikes", "/bmx", any case, surrounding spaces ignored.
local WORDS = { bike = true, bikes = true, bmx = true }
function M.IsChatCommand(text)
    if type(text) ~= "string" then return false end
    local word = text:lower():match("^%s*[/!](%a+)%s*$")
    return word ~= nil and WORDS[word] == true
end

-- EVERY ENTRY HAS A PICTURE (the spawn-menu icons, materials/entities/<class>.png,
-- rendered from the real thing: tools/icons/). A vehicle's is its entity class's;
-- a worn one (the skates) has no entity, so it is the weapon that carries it.
function M.IconFor(id)
    local def = BMX.Bikes[id] or (BMX.Vehicles and BMX.Vehicles[id])
    if def and def.worn then return "entities/weapon_bmx_" .. id .. ".png" end
    local class = BMX.ClassFor(id)
    return class and ("entities/" .. class .. ".png") or nil
end

-- A park piece's picture changes with its size and variant, as the Q menu's do.
function M.ParkIcon(shape, size, variant)
    return "entities/" .. BMX.Park.ClassName(shape, { size or 2, variant or 1 }) .. ".png"
end

-- What the menu lists, in order: one section per vehicle family that has a
-- visible vehicle (Bikes first), then the park pieces.
--   { { title, kind = "vehicle", items = { { id, name, info, icon } } },
--     { title, kind = "park",    items = { { id, name, variants, icon } } } }
function M.Catalog()
    local sections, byFamily = {}, {}
    -- Worn vehicles (the skates, G25) are listed with the rest: a click runs bmx_spawn, which
    -- gives the player the weapon that carries them.
    local ids = BMX.GettableIDs and BMX.GettableIDs() or (BMX.BikeIDs and BMX.BikeIDs() or {})
    for _, id in ipairs(ids) do
        local def = BMX.Bikes[id]
        local fam = def.family or "bike"
        local title = (BMX.Families and BMX.Families[fam] and BMX.Families[fam].category) or "Bikes"
        local sec = byFamily[title]
        if not sec then
            sec = { title = title, kind = "vehicle", items = {} }
            byFamily[title] = sec
            sections[#sections + 1] = sec
        end
        sec.items[#sec.items + 1] = { id = id, name = def.printName or id, info = def.description or "",
                                      icon = M.IconFor(id) }
    end
    table.sort(sections, function(a, b)
        if (a.title == "Bikes") ~= (b.title == "Bikes") then return a.title == "Bikes" end
        return a.title < b.title
    end)

    local P = BMX.Park
    if P and P.Order then
        local sec = { title = "Park", kind = "park", items = {} }
        for _, id in ipairs(P.Order) do
            local def = P.Shapes[id]
            sec.items[#sec.items + 1] = { id = id, name = def.name, variants = def.variants,
                                          icon = M.ParkIcon(id, 2, 1) }
        end
        if #sec.items > 0 then sections[#sections + 1] = sec end
    end
    return sections
end
