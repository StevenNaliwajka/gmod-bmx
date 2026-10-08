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
        -- Base-game folders, or the addon's own synthesised sounds (sound/bmx/).
        T.ok(p:match("^buttons/") or p:match("^ambient/") or p:match("^physics/")
            or p:match("^garrysmod/") or p:match("^bmx/"), key .. " is under a base-game sound folder or sound/bmx/")
        T.eq(S[key].variants ~= nil, p:find("%%d") ~= nil, key .. ": variants <=> %d in the path")
    end
    for key, s in pairs(S) do
        T.ok(s.path and #s.path > 0, key .. " has a path")
        T.ok(not s.path:find("^sound/"), key .. " is relative to sound/")
    end
end)

T.test("sounds: the addon's own (sound/bmx/) are on disk, every variant, and licensed", function()
    local sv = F.server()
    local S = sv.env.BMX.Sounds
    local n = 0
    for key, s in pairs(S) do
        if s.path:match("^bmx/") then
            for i = 1, s.variants or 1 do
                local p = "sound/" .. (s.variants and string.format(s.path, i) or s.path)
                local f = io.open(p, "rb")
                T.ok(f ~= nil, key .. ": " .. p .. " is in the repository")
                if f then
                    local head = f:read(12) or ""
                    f:close()
                    T.ok(head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WAVE", p .. " is a WAV file")
                end
                n = n + 1
            end
        end
    end
    T.ok(n >= 3, "the bell's variants are among them")
    T.eq(S.bell.path:match("^bmx/") ~= nil, true, "the bell is the addon's own, not a door chime")
    local lic = io.open("sound/bmx/LICENSE.txt", "r")
    T.ok(lic ~= nil, "sound/bmx/LICENSE.txt states their licence")
    if lic then lic:close() end
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

T.test("bell: R rings on the ground whatever else is held (RMB in a wheelie, W, Shift)", function()
    local sv = F.server()
    local E = sv.env
    local bike = F.bike(sv)
    local ply = F.rider(sv, bike)
    -- RMB down, no manual begun: this press used to be neither a ring nor a barspin.
    E.hook.Run("StartCommand", ply, cmd(IN.ATTACK2 + IN.RELOAD))
    T.eq(bells(sv), 1, "RMB + R rings")
    sv:run(E.GetConVar("bmx_bell_cooldown"):GetFloat() + 0.1)
    E.hook.Run("StartCommand", ply, cmd(IN.FORWARD))
    E.hook.Run("StartCommand", ply, cmd(IN.FORWARD + IN.SPEED + IN.RELOAD))
    T.eq(bells(sv), 2, "W + Shift + R rings")
    T.eq(bike.input.bar, 0, "and never starts a barspin on the ground")
end)

T.test("bell: two quick presses are two rings (the default cooldown is a thumb's flick)", function()
    local sv = F.server()
    local E = sv.env
    local bike = F.bike(sv)
    local ply = F.rider(sv, bike)
    T.ok(E.GetConVar("bmx_bell_cooldown"):GetFloat() <= 0.3, "the default is short")
    E.hook.Run("StartCommand", ply, cmd(IN.RELOAD))
    E.hook.Run("StartCommand", ply, cmd(0))
    sv:run(0.35)
    E.hook.Run("StartCommand", ply, cmd(IN.RELOAD))
    T.eq(bells(sv), 2, "ring, ring")
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

-- The rider's own client, on its own bike, as test_client.lua builds one.
local function ownBike()
    local sv, world = F.server()
    local bike = F.bike(sv)
    F.rider(sv, bike, { name = "Human" })
    local cl = F.client(world)
    local cb = cl:clientEntity("bmx_base")
    cb:SetPos(bike:GetPos())
    cb:SetAngles(bike:GetAngles())
    local pod = cl.makeEntity("prop_vehicle_prisoner_pod")
    pod:SetParent(cb)
    cb:SetPod(pod)
    local me = cl:player("Human")
    me._vehicle = pod
    cl.localPlayer = me
    cb:SetDriver(me)
    cb:SetGrounded(true)
    return sv, cl, bike, cb, world
end

local function ccmd(buttons)
    return { KeyDown = function(_, k) return (buttons % (k * 2)) >= k end,
             GetButtons = function() return buttons end, GetForwardMove = function() return 0 end,
             GetSideMove = function() return 0 end, CommandNumber = function() return 0 end }
end

local function bellSounds(cl)
    local n = 0
    for _, snd in ipairs(cl.sounds) do if snd.name:find("^bmx/bell") then n = n + 1 end end
    return n
end

T.test("bell: the rider hears their own press AT ONCE, and the server's echo is not a second ring", function()
    local sv, cl, bike, cb, world = ownBike()
    local E = cl.env
    cl.sounds = {}
    E.hook.GetTable().CreateMove["BMX.BellNow"](ccmd(IN.RELOAD))
    T.eq(bellSounds(cl), 1, "rang on the press, before any message")
    T.ok(cb.bellRungAt ~= nil, "and the lever on the bars knows")
    E.hook.GetTable().CreateMove["BMX.BellNow"](ccmd(IN.RELOAD))
    T.eq(bellSounds(cl), 1, "held: once per press")
    -- the server rings the same press and tells everyone
    sv.env.BMX.Bell.Ring(bike, 50)
    local msg
    for _, m in ipairs(world.wire) do if m.name == "bmx_bell" then msg = m end end
    msg.items[1].value = cb
    cl:deliver(msg)
    T.eq(bellSounds(cl), 1, "its echo is dropped")
    -- a ring the client did not play itself (another rider's, or one it could not judge)
    cl:deliver(msg)
    T.eq(bellSounds(cl), 2, "a ring it did not play is heard")
end)

T.test("bell: the rider's client leaves to the server a press that could be a barspin", function()
    local _, cl, _, cb = ownBike()
    local E = cl.env
    cl.sounds = {}
    E.hook.GetTable().CreateMove["BMX.BellNow"](ccmd(IN.ATTACK2 + IN.RELOAD))
    T.eq(bellSounds(cl), 0, "RMB held (maybe a manual): the server decides")
    E.hook.GetTable().CreateMove["BMX.BellNow"](ccmd(0))
    cb:SetGrounded(false)
    E.hook.GetTable().CreateMove["BMX.BellNow"](ccmd(IN.RELOAD))
    T.eq(bellSounds(cl), 0, "in the air it is a barspin")
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

-- ------------------------------------------------------- what each vehicle sounds like

T.test("sounds: only a vehicle with a freewheel ticks when it coasts", function()
    local _, world = F.server()
    local cl = F.client(world)
    local B = cl.env.BMX
    for id, want in pairs({ stock = true, road = true, dh = true, ebike = true,
                            fixie = false, unicycle = false, penny = false, city = false,
                            emoto = false, dirtbike = false, moped = false,
                            skateboard = false, scooter = false, skates = false }) do
        T.eq(B.HasFreewheel(B.Bikes[id]), want, id .. (want and " has" or " has no") .. " freewheel")
    end
    -- And the loop asks: a coasting skateboard used to tick like a BMX.
    local function ticks(id)
        local cb = cl:clientEntity(B.ClassFor(id))
        cb:SetGrounded(true)
        cb:SetSpeedUPS(30)          -- a slow roll: single ticks, not the buzz
        cb:SetCadence(0)
        local n0 = #cl.sounds
        cl:run(1)
        local n = 0
        for i = n0 + 1, #cl.sounds do
            if cl.sounds[i].ent == cb and cl.sounds[i].name:find("^bmx/tick%d%.wav$") then n = n + 1 end
        end
        cb:Remove()
        return n
    end
    T.ok(ticks("stock") > 3, "a coasting BMX ticks")
    T.eq(ticks("skateboard"), 0, "a coasting skateboard does not")
    T.eq(ticks("scooter"), 0, "nor a scooter")
end)

T.test("sounds: tyres hum, urethane grinds, and decks land as wood and metal", function()
    local sv = F.server()
    local B = sv.env.BMX
    T.eq(B.RollSoundKey(B.Bikes.stock), "roll", "a BMX rolls on tyres")
    T.eq(B.RollSoundKey(B.Bikes.dirtbike), "roll", "so does a motorbike")
    for _, id in ipairs({ "skateboard", "scooter", "skates" }) do
        T.eq(B.RollSoundKey(B.Bikes[id]), "roll_wheel", id .. " rolls on urethane")
    end
    T.eq(B.LandSoundKey(B.Bikes.stock, "land_hard"), "land_hard", "a BMX lands on its tyres")
    T.eq(B.LandSoundKey(B.Bikes.skateboard, "land_soft"), "land_wood", "a skateboard lands on its maple deck")
    T.eq(B.LandSoundKey(B.Bikes.scooter, "land_soft"), "land_metal", "a scooter on its metal deck")
    for _, key in ipairs({ "roll", "roll_wheel", "tick", "land_wood", "land_metal" }) do
        T.ok(B.Sounds[key], key .. " is in the table")
    end
    -- The rolling loops are the addon's own, and carry a loop cue.
    for _, key in ipairs({ "roll", "roll_wheel" }) do
        local f = io.open("sound/" .. B.Sounds[key].path, "rb")
        local raw = f and f:read("*a") or ""
        if f then f:close() end
        T.ok(raw:find("cue ", 13, true) ~= nil, key .. ": a WAV with a loop cue")
    end
end)

T.test("bell: the ting bell, four presses, each a pair of strikes", function()
    local sv = F.server()
    local S = sv.env.BMX.Sounds.bell
    T.eq(S.variants, 4, "four bells")
    -- Bright, like the bell it is modelled on: its strongest partial is near 10 kHz,
    -- so most of the file's sign changes come fast. A 2.3 kHz "ding" (the old
    -- bell) crosses zero about 4,600 times a second; this one far more.
    for i = 1, 4 do
        local f = io.open(string.format("sound/bmx/bell%d.wav", i), "rb")
        local raw = f:read("*a")
        f:close()
        local data = raw:find("data", 13, true)
        local n, cross, prev = 0, 0, 0
        for p = data + 8, math.min(#raw - 1, data + 8 + 2 * 22050), 2 do
            local lo, hi = raw:byte(p, p + 1)
            local v = hi * 256 + lo
            if v >= 32768 then v = v - 65536 end
            if (v > 0 and prev < 0) or (v < 0 and prev > 0) then cross = cross + 1 end
            if v ~= 0 then prev = v end
            n = n + 1
        end
        local perSecond = cross / (n / 44100)
        T.ok(perSecond > 9000, string.format("bell%d is a bright ting: %.0f zero crossings a second", i, perSecond))
    end
end)

T.test("sounds: the freewheel clicks at the rate its pawls really pass", function()
    local sv = F.server()
    local B = sv.env.BMX
    local stock = B.Bikes.stock
    -- 250 u/s on a 10 u wheel is 25 rad/s, 3.98 turns a second, times 36 points.
    T.near(B.FreewheelRate(stock, 250, 10, 25 / 9, 0), 25 / (2 * math.pi) * 36, 1e-6, "coasting: wheel turns x points")
    T.eq(B.FreewheelRate(stock, 250, 10, 25 / 9, 9), 0, "pedalling at the wheel's pace: engaged, silent")
    local soft = B.FreewheelRate(stock, 250, 10, 25 / 9, 4)
    T.ok(soft > 0 and soft < B.FreewheelRate(stock, 250, 10, 25 / 9, 0), "soft-pedalling: slower clicks")
    T.ok(B.FreewheelRate(B.Bikes.dh, 250, 10, 2.78, 0) > B.FreewheelRate(stock, 250, 10, 2.78, 0),
        "a downhill hub buzzes quicker than a BMX's")
    T.eq(B.FreewheelRate(B.Bikes.fixie, 250, 10, 2.78, 0), 0, "a fixie has none")
    for id, want in pairs({ stock = true, fixie = true, city = true, ebike = true, moped = true,
                            unicycle = false, penny = false, dirtbike = false, emoto = false,
                            skateboard = false, scooter = false, skates = false }) do
        T.eq(B.HasChain(B.Bikes[id]), want, id .. (want and " has" or " has no") .. " chain to hear")
    end
    for id, want in pairs({ stock = true, city = true, dirtbike = true, unicycle = false,
                            skateboard = false, scooter = false, skates = false }) do
        T.eq(B.HasKickstand(B.Bikes[id]), want, id .. (want and " has" or " has no") .. " kickstand")
    end
end)

T.test("sounds: a bike's mechanism is heard -- chain, buzz, shift, kickstand", function()
    local _, world = F.server()
    local cl = F.client(world)
    local B = cl.env.BMX
    local function patch(path)
        for _, p in ipairs(cl.patches) do if p.path == path then return p end end
    end
    local function heard(cb, pat, n0)
        local n = 0
        for i = n0 + 1, #cl.sounds do
            if cl.sounds[i].ent == cb and cl.sounds[i].name:find(pat) then n = n + 1 end
        end
        return n
    end
    -- Pedalling: the chain plays, pitched to the cranks; the freewheel is silent.
    local cb = cl:clientEntity(B.ClassFor("stock"))
    cb:SetGrounded(true)
    cb:SetSpeedUPS(250)
    cb:SetCadence(250 / cb:Cfg().Wheel.radius / B.GearRatio(cb, cb:Cfg()))
    local n0 = #cl.sounds
    cl:run(0.5)
    local ch = patch(B.Sounds.chain.path)
    T.ok(ch and ch.playing, "pedalling: the chain is heard")
    T.eq(heard(cb, "^bmx/tick", n0), 0, "and the freewheel is locked")
    local fw = patch(B.Sounds.freewheel.path)
    T.ok(not fw or not fw.playing, "no buzz either")
    -- Coasting fast: the chain stops, the freewheel buzzes, pitched to its rate.
    cb:SetCadence(0)
    cl:run(0.5)
    T.ok(not ch.playing, "coasting: the chain stops with the cranks")
    fw = patch(B.Sounds.freewheel.path)
    T.ok(fw and fw.playing, "and the freewheel buzzes")
    T.near(fw.pitch, math.min(100 * B.LastFreewheelRate / 60, 255), 1, "pitched to the click rate")
    -- Slowing to a roll: single ticks, at the real rate.
    cb:SetSpeedUPS(40)
    n0 = #cl.sounds
    cl:run(2)
    local want = B.FreewheelRate(cb:Bike(), 40, cb:Cfg().Wheel.radius, 1, 0) * 2
    local got = heard(cb, "^bmx/tick%d%.wav$", n0)
    T.ok(math.abs(got - want) <= 2, string.format("slow: %d ticks in 2 s, the pawls give %.1f", got, want))
    -- The kickstand, heard going down and up (not on the first look).
    n0 = #cl.sounds
    cb:SetStandDown(true)
    cl:run(0.1)
    cb:SetStandDown(false)
    cl:run(0.1)
    T.eq(heard(cb, "kickstand_down", n0), 1, "stand down, heard once")
    T.eq(heard(cb, "kickstand_up", n0), 1, "stand up, heard once")
    -- A road bike's derailleur, heard when the gear changes.
    local rd = cl:clientEntity(B.ClassFor("road"))
    rd:SetGear(4)
    cl:run(0.1)
    n0 = #cl.sounds
    rd:SetGear(5)
    cl:run(0.1)
    T.eq(heard(rd, "^bmx/shift%d%.wav$", n0), 1, "a gear change clicks the derailleur")
end)
