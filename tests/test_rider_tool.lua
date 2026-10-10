--[[--------------------------------------------------------------------------
    tools/rider: the rider preview keeps working as the code it draws changes.

    It runs the exporter as a person would (the same interpreter this suite
    runs on), so a change to cl_rider.lua, a pose set or the client realm that
    breaks the picture breaks here first, not the day somebody wants to look.
----------------------------------------------------------------------------]]

local gmod = require("lib.gmod")
local J = require("lib.json")

local function export(args)
    local lua = (arg and arg[-1]) or "lua5.1"
    local p = io.popen(string.format('cd "%s" && "%s" tools/rider/export.lua %s',
        gmod.ROOT, lua, args))
    local s = p:read("*a")
    p:close()
    return J.decode(s)
end

T.test("rider preview: the stock bike's rider through a stroke, hands and feet on the bike", function()
    local d = export("stock 4")
    T.eq(next(d.errors or {}), nil, "no vehicle failed")
    local v = d.vehicles[1]
    T.eq(v.id, "stock", "the vehicle asked for")
    T.eq(#v.frames, 4, "four samples")
    for _, f in ipairs(v.frames) do
        for _, k in ipairs({ "rHand", "lHand", "rFoot", "lFoot" }) do
            T.between(f.reach[k] or 99, 0, 3, k .. " to its grip or pedal at crank " .. f.crank)
        end
        T.ok(f.bones.Head1 and f.bones.R_Foot and f.bones.L_Hand, "the skeleton's bones")
    end
end)

T.test("rider preview: at speed the rider tucks FORWARD, not to the side (the spine bends about its Z)", function()
    local slow = export("stock 1 0").vehicles[1].frames[1].bones.Head1
    local fast = export("stock 1 1").vehicles[1].frames[1].bones.Head1
    T.ok(fast[1] - slow[1] > 2, string.format("the head forward: %.1f -> %.1f", slow[1], fast[1]))
    T.between(math.abs(fast[2] - slow[2]), 0, 0.5, "and not to the side, units")
end)
