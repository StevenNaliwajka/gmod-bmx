--[[--------------------------------------------------------------------------
    The bell, water and the sound settings (G18).

    Water is built by hand here: the shim has no water, so util.PointContents
    is replaced by a function that says "wet below this height". What that
    proves is OUR logic -- drag scales with depth and speed, a splash happens
    once, the rider is ejected only when the chest is under for long enough and
    only when asked -- not the engine's idea of what water is. A headless
    rides_into_water case needs a map with water, and the test maps do not have
    any (gm_flatgrass is dry), so it is not written.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local gmod = require("lib.gmod")
local IN = gmod.IN

local function cmd(buttons)
    local c = { buttons = buttons or 0 }
    function c:GetButtons() return self.buttons end
    function c:SetButtons(b) self.buttons = b end
    function c:GetForwardMove() return 0 end
    function c:GetSideMove() return 0 end
    function c:SetForwardMove() end
    function c:SetSideMove() end
    function c:SetUpMove() end
    return c
end

local function bells(sv)
    local n = 0
    for _, m in ipairs(sv.world.wire) do if m.name == "bmx_bell" then n = n + 1 end end
    return n
end

-- Water below z = level.
local function flood(E, level)
    E.util.PointContents = function(p) return p.z < level and 32 or 0 end
end

-- ---------------------------------------------------------------- sounds

T.test("sounds: the new ones are base-game paths, and variants carry a %d", function()
    local sv = F.server()
    local S = sv.env.BMX.Sounds
    for _, key in ipairs({ "bell", "splash", "wind" }) do
        T.ok(S[key], key .. " is in the table")
        local p = S[key].path
        T.ok(p:match("^[%w_]+/[%w_/]*[%w_%%]+%.wav$"), key .. " looks like a sound path: " .. p)
        -- Nothing shipped in the addon: base-game folders only.
        T.ok(p:match("^buttons/") or p:match("^ambient/") or p:match("^physics/")
            or p:match("^garrysmod/"), key .. " is under a base-game sound folder")
        T.eq(S[key].variants ~= nil, p:find("%%d") ~= nil, key .. ": variants <=> %d in the path")
    end
    for key, s in pairs(S) do
        T.ok(s.path and #s.path > 0, key .. " has a path")
        T.ok(not s.path:find("^sound/"), key .. " is relative to sound/")
    end
end)

T.test("sounds: wind volume is speed squared, clamped", function()
    local sv = F.server()
    local B = sv.env.BMX
    T.eq(B.WindVolume(0, 400), 0, "silent at rest")
    T.near(B.WindVolume(200, 400), 0.25, 1e-9, "half speed is a quarter")
    T.near(B.WindVolume(400, 400), 1, 1e-9, "top speed is full")
    T.eq(B.WindVolume(900, 400), 1, "and no louder past it")
    T.ok(B.WindVolume(300, 400) > 2 * B.WindVolume(150, 400), "doubling speed more than doubles it")
end)

T.test("sounds: bmx_sounds 0 silences the server one-shots", function()
    local sv = F.server()
    local E = sv.env
    T.ok(E.GetConVar("bmx_sounds"):GetBool(), "defaults to on")
    E.GetConVar("bmx_sounds"):SetString("0")
    local bike = F.bike(sv)
    sv:run(0.5)
    F.scripted(sv, bike)
    sv:run(1.2)
    F.layDown(sv, bike)
    sv:run(1)
    for _, s in ipairs(sv.sounds) do
        T.ok(not s.name:find("metal_box_impact"), "no crash sound with the server muted")
    end
end)

-- ------------------------------------------------------------------ bell

T.test("bell: R on the ground rings once per press, not once per tick", function()
    local sv = F.server()
    local E = sv.env
    local bike = F.bike(sv)
    local ply = F.rider(sv, bike)
    E.hook.Run("StartCommand", ply, cmd(IN.RELOAD))
    E.hook.Run("StartCommand", ply, cmd(IN.RELOAD))
    E.hook.Run("StartCommand", ply, cmd(IN.RELOAD))
    T.eq(bells(sv), 1, "held R rang once")
    -- released and pressed again, but inside the cooldown
    E.hook.Run("StartCommand", ply, cmd(0))
    E.hook.Run("StartCommand", ply, cmd(IN.RELOAD))
    T.eq(bells(sv), 1, "inside bmx_bell_cooldown, no second ring")
    sv:run(E.GetConVar("bmx_bell_cooldown"):GetFloat() + 0.1)
    E.hook.Run("StartCommand", ply, cmd(0))
    E.hook.Run("StartCommand", ply, cmd(IN.RELOAD))
    T.eq(bells(sv), 2, "after the cooldown it rings again")
end)

T.test("bell: not in the air, not in a manual (R is the barspin there)", function()
    local sv = F.server()
    local E = sv.env
    local bike = F.bike(sv)
    local ply = F.rider(sv, bike)
    bike.st.airMode = true
    E.hook.Run("StartCommand", ply, cmd(IN.RELOAD))
    T.eq(bells(sv), 0, "airborne")
    bike.st.airMode = false
    E.hook.Run("StartCommand", ply, cmd(0))
    bike.st.manual = { kind = "wheelie", held = 1, gone = 0 }
    E.hook.Run("StartCommand", ply, cmd(IN.RELOAD))
    T.eq(bells(sv), 0, "in a manual")
    bike.st.manual = nil
    E.hook.Run("StartCommand", ply, cmd(0))
    -- A press that began in the air and is still down on landing is not a ring.
    bike.st.airMode = true
    E.hook.Run("StartCommand", ply, cmd(IN.RELOAD))
    bike.st.airMode = false
    E.hook.Run("StartCommand", ply, cmd(IN.RELOAD))
    T.eq(bells(sv), 0, "held through the landing")
end)

T.test("bell: bmx_bell 0, bmx_sounds 0 and a bike with no bell are all silent", function()
    local sv = F.server()
    local E = sv.env
    local bike = F.bike(sv)
    E.GetConVar("bmx_bell"):SetString("0")
    T.eq(E.BMX.Bell.Ring(bike, 100), false, "bmx_bell 0")
    E.GetConVar("bmx_bell"):SetString("1")
    E.GetConVar("bmx_sounds"):SetString("0")
    T.eq(E.BMX.Bell.Ring(bike, 100), false, "bmx_sounds 0")
    E.GetConVar("bmx_sounds"):SetString("1")
    local def = bike:Bike()
    def.bell = false
    T.eq(E.BMX.Bell.Ring(bike, 100), false, "bell = false in the registry (a skateboard)")
    def.bell = nil
    T.eq(E.BMX.Bell.Ring(bike, 100), true, "and rings again with the default")
    T.eq(bells(sv), 1, "exactly the one message went out")
end)

T.test("bell: the cooldown is the convar, per bike", function()
    local sv = F.server()
    local E = sv.env
    local a, b = F.bike(sv), F.bike(sv, nil, E.Vector(300, 0, F.restHeight(sv)))
    E.GetConVar("bmx_bell_cooldown"):SetString("2")
    T.eq(E.BMX.Bell.Ring(a, 10), true, "first")
    T.eq(E.BMX.Bell.Ring(a, 11.9), false, "inside 2 s")
    T.eq(E.BMX.Bell.Ring(a, 12.1), true, "after 2 s")
    T.eq(E.BMX.Bell.Ring(b, 10), true, "another bike is its own clock")
end)

T.test("bell: the client plays it at the listener's own bmx_vol_bell", function()
    local sv, world = F.server()
    local cl = F.client(world)
    local E = cl.env
    local ent = cl:clientEntity("bmx_base")
    E.GetConVar("bmx_vol_bell"):SetString("0.5")
    local bike = F.bike(sv)
    sv.env.BMX.Bell.Ring(bike, 50)
    local msg
    for _, m in ipairs(world.wire) do if m.name == "bmx_bell" then msg = m end end
    -- The server named ITS bike; the client resolves entities itself. Point the
    -- entity field at the client's copy, as the engine would.
    msg.items[1].value = ent
    cl.sounds = {}
    cl:deliver(msg)
    T.eq(#cl.sounds, 1, "one bell")
    T.near(cl.sounds[1].vol, E.BMX.Sounds.bell.vol * 0.5, 1e-9, "at half the listener's volume")
    E.GetConVar("bmx_vol_bell"):SetString("0")
    cl.sounds = {}
    cl:deliver(msg)
    T.eq(#cl.sounds, 0, "and nothing at 0")
end)

-- ----------------------------------------------------------------- water

-- A bike rolling at `speed` on flat ground, in water to `level` (or dry).
local function ride(level, speed, setup)
    local sv = F.server()
    local E = sv.env
    if setup then setup(E) end
    if level then flood(E, level) end
    local bike = F.bike(sv)
    sv:run(0.5)
    local ply = F.scripted(sv, bike)
    sv:run(0.3)
    bike:GetPhysicsObject():SetVelocity(E.Vector(speed, 0, 0))
    return sv, bike, ply
end

T.test("water: drag grows with depth and with speed, and is zero when dry", function()
    local sv = F.server()
    local W = sv.env.BMX.Water
    T.eq(W.DragAccel(0, 300), 0, "dry")
    T.eq(W.DragAccel(1, 0), 0, "still")
    T.ok(W.DragAccel(1, 300) > W.DragAccel(0.5, 300), "deeper is more")
    T.ok(W.DragAccel(1, 300) > W.DragAccel(1, 150), "faster is more")
    T.ok(W.DragAccel(1, 300) / W.DragAccel(1, 150) > 2, "faster than linearly (the v^2 term)")
    T.ok(W.DragAccel(1, 20) > 0, "but a slow bike is still held back (the v term)")
end)

T.test("water: a bike rolled into a pond slows far more than the same bike on dry ground", function()
    local function after(level)
        local sv, bike = ride(level, 250)
        sv:run(1.0)
        return bike:GetPhysicsObject():GetVelocity():Length()
    end
    local dry, wetv = after(nil), after(60)
    T.ok(dry > 150, "dry control still rolling: " .. dry)
    T.ok(wetv < dry * 0.6, string.format("wet %.0f vs dry %.0f", wetv, dry))
end)

T.test("water: bmx_water 0 changes nothing", function()
    local sv, bike = ride(60, 250, function(E) E.GetConVar("bmx_water"):SetString("0") end)
    sv:run(1.0)
    local sv2, b2 = ride(nil, 250)
    sv2:run(1.0)
    local dry = b2:GetPhysicsObject():GetVelocity():Length()
    T.near(bike:GetPhysicsObject():GetVelocity():Length(), dry, dry * 0.05, "same as dry")
end)

T.test("water: wheels wet but chest dry does not throw the rider", function()
    -- Low water: over the hubs, nowhere near the chest.
    local sv, bike = ride(20, 120)
    sv:run(1.5)
    T.ok(sv.env.IsValid(bike:GetDriver()), "still aboard")
    T.ok(bike.st.water and bike.st.water.wet, "the wheels are in it")
    T.ok(not bike.st.water.chest, "the chest is not")
end)

T.test("water: chest under for long enough throws the rider; eject 0 keeps them on", function()
    local sv, bike = ride(200, 20)
    T.ok(sv:run(2, function() return not sv.env.IsValid(bike:GetDriver()) end), "thrown off")

    local sv2, bike2 = ride(200, 20)
    sv2.env.GetConVar("bmx_water_eject"):SetString("0")
    sv2:run(2)
    T.ok(sv2.env.IsValid(bike2:GetDriver()), "bmx_water_eject 0: still aboard")
end)

T.test("water: the chest must stay under for the debounce, not one sample", function()
    local sv, bike = ride(nil, 20)
    local W = sv.env.BMX.Water
    T.ok(not W.ShouldEject(0), "not at once")
    T.ok(not W.ShouldEject(W.ejectDelay - 0.01), "not just before")
    T.ok(W.ShouldEject(W.ejectDelay), "at the delay")
    -- a brief dip: water for a tenth of a second, then dry again
    flood(sv.env, 200)
    sv:run(0.1)
    flood(sv.env, 0)
    sv:run(1)
    T.ok(sv.env.IsValid(bike:GetDriver()), "a dip is not an ejection")
end)

T.test("water: entering at speed splashes once, wading does not", function()
    local sv, bike = ride(nil, 200)
    local E = sv.env
    local effects = 0
    E.EffectData = function()
        return { SetOrigin = function() end, SetScale = function() end }
    end
    E.util.Effect = function(name) if name == "watersplash" then effects = effects + 1 end end
    local function splashes()
        local n = 0
        for _, s in ipairs(sv.sounds) do if s.name:find("water_splash") then n = n + 1 end end
        return n
    end
    sv:run(0.2)
    T.eq(splashes(), 0, "dry")
    flood(E, 60)
    bike:GetPhysicsObject():SetVelocity(E.Vector(200, 0, 0))
    sv:run(0.3)
    T.eq(splashes(), 1, "one splash going in")
    T.eq(effects, 1, "and one effect")
    sv:run(1)
    T.eq(splashes(), 1, "not again while it stays wet")
end)
