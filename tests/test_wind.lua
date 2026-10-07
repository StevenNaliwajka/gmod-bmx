--[[--------------------------------------------------------------------------
    The client half of G18's sound settings: the wind loop and the volumes
    (cl_sound.lua). The bell's client side is in test_ambient.lua.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local function windScene()
    local sv, world = F.server()
    local bike = F.bike(sv)
    F.rider(sv, bike, { name = "Human" })
    local cl = F.client(world)
    local cb = cl:clientEntity("bmx_base")
    cb:SetPos(bike:GetPos())
    local pod = cl.makeEntity("prop_vehicle_prisoner_pod")
    pod:SetParent(cb)
    cb:SetPod(pod)
    local me = cl:player("Human")
    me._vehicle = pod
    cl.localPlayer = me
    cb:SetDriver(me)
    cb:SetGrounded(true)
    return cl, cb, world
end

local function windPatch(cl)
    for _, p in ipairs(cl.patches) do
        if p.path == cl.env.BMX.Sounds.wind.path then return p end
    end
end

T.test("wind: loud fast, quiet slow, scaled by bmx_vol_wind, gone with bmx_sounds 0", function()
    local cl, cb, world = windScene()
    local E = cl.env
    cb:SetSpeedUPS(60)
    cl:run(0.2)
    local slow = windPatch(cl)
    local vSlow = slow and slow.playing and slow.vol or 0
    cb:SetSpeedUPS(330)
    cl:run(0.2)
    local fast = windPatch(cl)
    T.ok(fast and fast.playing, "the whoosh plays at speed")
    T.ok(fast.vol > vSlow * 3, string.format("fast %.3f vs slow %.3f", fast.vol, vSlow))

    local full = fast.vol
    E.GetConVar("bmx_vol_wind"):SetString("0.5")
    cl:run(0.2)
    T.near(fast.vol, full * 0.5, 1e-6, "half the player's volume, half the whoosh")
    E.GetConVar("bmx_vol_wind"):SetString("0")
    cl:run(0.2)
    T.ok(not fast.playing, "bmx_vol_wind 0 stops it")

    E.GetConVar("bmx_vol_wind"):SetString("1")
    cl:run(0.2)
    T.ok(fast.playing, "and back")
    world.convars.bmx_sounds:SetString("0")
    cl:run(0.2)
    T.ok(not fast.playing, "bmx_sounds 0 silences the client loops too")
end)

T.test("wind: a riderless bike does not whoosh", function()
    local cl, cb = windScene()
    cb:SetDriver(cl.env.NULL)
    cb:SetSpeedUPS(330)
    cl:run(0.2)
    local w = windPatch(cl)
    T.ok(not (w and w.playing), "no rider, no wind")
end)
