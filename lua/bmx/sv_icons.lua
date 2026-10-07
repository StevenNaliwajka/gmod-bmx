--[[--------------------------------------------------------------------------
    bmx/sv_icons.lua

    THE SPAWN-MENU PICTURES REACH EVERY CLIENT. Each Q-menu entry has an icon,
    materials/entities/<class>.png (tools/icons/README.md). A client subscribed to
    the Workshop item has them already. A server that runs the addon from a folder,
    as a test server or a private copy does, sends a client its Lua but not its
    materials, so without this every entry is the grey placeholder on such a server.

    resource.AddFile skips a file the client already has, so a Workshop client
    downloads nothing here. Only our own icons are listed: bmx_* and weapon_bmx_*.
----------------------------------------------------------------------------]]

if not resource or not resource.AddFile then return end

local files = file.Find("materials/entities/*.png", "GAME") or {}
for _, name in ipairs(files) do
    if name:find("^bmx_") or name:find("^weapon_bmx_") then
        resource.AddFile("materials/entities/" .. name)
    end
end
