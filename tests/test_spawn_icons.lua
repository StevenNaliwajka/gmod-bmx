--[[--------------------------------------------------------------------------
    Every spawn-menu entry has a picture (materials/entities/<class>.png).

    THE RULE. Nobody should have to pick a bike, a ramp or a weapon from its name
    alone: the Q menu shows each entry's icon, and an entry without one is the
    engine's grey placeholder, which is what all 101 of ours were until 2026-10-07.
    So a new vehicle, park shape or SWEP fails here until it ships a picture, and an
    icon whose entry is gone fails too, so the folder never fills with dead files.

    The icons are rendered from the real thing in game, not drawn by hand:
    tools/icons/README.md says how to shoot new ones.

    WHAT COUNTS AS AN ENTRY is what the menu lists: a SpawnableEntities row, a
    scripted entity with Spawnable = true, and a weapon with Spawnable = true. A
    hidden vehicle (the debug test cart) is none of those, and is checked to stay so.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local gmod = require("lib.gmod")

local SIZE = 128
local DIR = gmod.ROOT .. "/materials/entities/"

local function entries()
    local sv = F.server()
    local out = {}
    for class in pairs(sv.lists.SpawnableEntities or {}) do out[class] = true end
    for class, t in pairs(sv.stored or {}) do
        if t.Spawnable then out[class] = true end
    end
    for class, t in pairs(sv.sweps or {}) do
        if t.Spawnable then out[class] = true end
    end
    return out, sv
end

-- width, height from a PNG's IHDR, or nil if it is not a PNG
local function pngSize(path)
    local fh = io.open(path, "rb")
    if not fh then return nil end
    local head = fh:read(24) or ""
    fh:close()
    if head:sub(1, 8) ~= "\137PNG\r\n\26\n" or head:sub(13, 16) ~= "IHDR" then return nil end
    local function u32(i)
        local a, b, c, d = head:byte(i, i + 3)
        return ((a * 256 + b) * 256 + c) * 256 + d
    end
    return u32(17), u32(21)
end

T.test("spawn icons: the menu has the entries this test expects to police", function()
    local list = entries()
    local n, park, sweps = 0, 0, 0
    for class in pairs(list) do
        n = n + 1
        if class:find("^bmx_park_") then park = park + 1 end
        if class:find("^weapon_") then sweps = sweps + 1 end
    end
    -- if these drop to nothing, the collection above broke, and the next test proves nothing
    T.ok(n >= 90, "found " .. n .. " entries")
    T.ok(park >= 60, "found " .. park .. " park pieces")
    T.ok(sweps >= 3, "found " .. sweps .. " weapons")
end)

T.test("spawn icons: every spawn-menu entry has a 128x128 PNG picture", function()
    local missing, bad = {}, {}
    for class in pairs(entries()) do
        local w, h = pngSize(DIR .. class .. ".png")
        if not w then missing[#missing + 1] = class
        elseif w ~= SIZE or h ~= SIZE then bad[#bad + 1] = class .. " (" .. w .. "x" .. h .. ")" end
    end
    table.sort(missing)
    table.sort(bad)
    T.eq(#missing, 0, "no picture (tools/icons/README.md): " .. table.concat(missing, ", "))
    T.eq(#bad, 0, "wrong size: " .. table.concat(bad, ", "))
end)

T.test("spawn icons: every icon belongs to an entry that is still in the menu", function()
    local list = entries()
    local stale = {}
    local p = io.popen('ls "' .. DIR .. '" 2>/dev/null')
    for name in p:lines() do
        local class = name:match("^(.+)%.png$")
        if not class or not list[class] then stale[#stale + 1] = name end
    end
    p:close()
    table.sort(stale)
    T.eq(#stale, 0, "icons for nothing: " .. table.concat(stale, ", "))
end)

T.test("spawn icons: a hidden vehicle (the test cart) is not in the menu at all", function()
    local list, sv = entries()
    local class = sv.env.BMX.ClassFor("testcart")
    T.ok(class, "the test cart is registered")
    T.ok(not list[class], class .. " must not be spawnable from the menu")
end)
