--[[--------------------------------------------------------------------------
    Weight forward and the nose manual (G02): LMB + Ctrl leans the rider over the
    bars, and a stoppie whose brake comes off with the weight still forward keeps
    rolling on the front wheel.

    The key decode is the real StartCommand (as tests/test_input.lua does it); the
    nose manual is flown on the shim's plant, which is right in kind and not
    VPhysics, so the bands are wide and the headless case nose_manual_holds is the
    one that says how it rides on a real server.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local gmod = require("lib.gmod")
local IN = gmod.IN

local function cmd(buttons, fwd, side)
    local c = { buttons = buttons or 0, fwd = fwd or 0, side = side or 0, up = 0 }
    function c:GetButtons() return self.buttons end
    function c:SetButtons(b) self.buttons = b end
    function c:GetForwardMove() return self.fwd end
    function c:GetSideMove() return self.side end
    function c:SetForwardMove(v) self.fwd = v end
    function c:SetSideMove(v) self.side = v end
    function c:SetUpMove(v) self.up = v end
    return c
end

local function rig(noseOn)
    local sv = F.server()
    if noseOn then sv.env.GetConVar("bmx_nose_manual"):SetString("1") end
    local bike = F.bike(sv)
    local ply = F.rider(sv, bike)
    local function send(buttons, fwd, side)
        local c = cmd(buttons, fwd, side)
        sv.env.hook.Run("StartCommand", ply, c)
        return c
    end
    return sv, bike, ply, send
end

--------------------------------------------------------------------------
-- The keys
--------------------------------------------------------------------------
T.test("lean keys: LMB alone brakes as it always did, and does not lean", function()
    local _, bike, _, send = rig(true)
    send(IN.ATTACK)
    T.eq(bike.input.brakeFront, 1, "the front brake")
    T.eq(bike.input.leanFwd, false, "no lean")
    T.near(bike.input.pitchTarget, -0.6, 1e-9, "and the weight shift the brake always brought")
end)

T.test("lean keys: LMB + Ctrl brakes and leans; letting go of LMB keeps the lean, brake off", function()
    local _, bike, _, send = rig(true)
    send(IN.ATTACK + IN.DUCK)
    T.eq(bike.input.brakeFront, 1, "braking")
    T.eq(bike.input.leanFwd, true, "and leaning")
    send(IN.DUCK)
    T.eq(bike.input.brakeFront, 0, "LMB up: the brake is off")
    T.eq(bike.input.leanFwd, true, "with Ctrl still down the lean stays")
    T.near(bike.input.pitchTarget, -0.35, 1e-9, "a lean, not a stoppie's weight shift")
    send(0)
    T.eq(bike.input.leanFwd, false, "Ctrl up: the lean is gone")
    T.eq(bike.input.pitchTarget, 0, "and nothing is held")
end)

T.test("lean keys: Ctrl alone is still only the tuck", function()
    local _, bike, _, send = rig(true)
    send(IN.DUCK)
    T.eq(bike.input.tuck, true, "tuck")
    T.eq(bike.input.leanFwd, false, "no lean")
    T.eq(bike.input.brakeFront, 0, "no brake")
end)

T.test("lean keys: with the nose manual off a lean without the brake holds nothing", function()
    local _, bike, _, send = rig(false)
    send(IN.ATTACK + IN.DUCK)
    send(IN.DUCK)
    T.eq(bike.input.leanFwd, true, "still leaning (the weight shifts)")
    T.eq(bike.input.pitchTarget, 0, "but nothing asks the pitch controller for anything")
end)

T.test("lean keys: bmx_lmb_mode lean makes LMB the lean, and Ctrl the brake", function()
    local _, bike, ply, send = rig(true)
    ply:ConCommand("bmx_lmb_mode lean")
    send(IN.ATTACK)
    T.eq(bike.input.leanFwd, true, "LMB leans")
    T.eq(bike.input.brakeFront, 0, "and does not brake")
    send(IN.ATTACK + IN.DUCK)
    T.eq(bike.input.brakeFront, 1, "with Ctrl it brakes too")
    send(IN.ATTACK)
    T.eq(bike.input.brakeFront, 0, "Ctrl up: the brake is off")
    T.eq(bike.input.leanFwd, true, "LMB still down: still leaning")
    send(0)
    T.eq(bike.input.leanFwd, false, "LMB up: upright")
end)

T.test("lean keys: RMB (weight back) wins, and the air is the tailwhip's, not a lean", function()
    local _, bike, _, send = rig(true)
    send(IN.ATTACK + IN.DUCK + IN.ATTACK2)
    T.eq(bike.input.leanFwd, false, "no lean with RMB down")
    T.eq(bike.input.pitchTarget, 1, "weight back")
    send(0)
    bike.st.airMode = true
    send(IN.ATTACK + IN.DUCK)
    T.eq(bike.input.leanFwd, false, "no lean in the air")
    bike.st.airMode = false
end)

T.test("lean keys: W and S trim the nose manual on the ground", function()
    local _, bike, _, send = rig(true)
    send(IN.FORWARD)
    T.eq(bike.input.noseTrim, 1, "W: further over")
    send(IN.BACK)
    T.eq(bike.input.noseTrim, -1, "S: sit up")
    send(0)
    T.eq(bike.input.noseTrim, 0, "neither")
end)

T.test("lean setting: bmx_lmb_mode is a client row with brake and lean, bmx_nose_manual a server row off by default", function()
    local sv = F.server()
    local S = sv.env.BMX.Settings
    local row = S.Get("bmx_lmb_mode")
    T.ok(row, "bmx_lmb_mode is described")
    T.eq(row.scope, "client", "a rider's own")
    T.eq(row.default, "brake", "brake by default")
    T.eq(#row.choices, 2, "brake or lean")
    local nose = S.Get("bmx_nose_manual")
    T.ok(nose, "bmx_nose_manual is described")
    T.eq(nose.scope, "server", "an admin's")
    T.eq(nose.default, false, "off until it has been ridden on a real server")
    T.ok(not sv.env.GetConVar("bmx_nose_manual"):GetBool(), "and the convar agrees")
    T.ok(sv.env.BMX.Tricks.nose_manual, "Nose Manual is a registered trick")
    T.eq(sv.env.BMX.Tricks.nose_manual.kind, "ground", "a ground trick")
end)

--------------------------------------------------------------------------
-- Weight forward
--------------------------------------------------------------------------
T.test("weight forward: it comes on over a fraction of a second and loads the front tyre", function()
    local sv = F.server()
    local bike = F.bike(sv)
    F.scripted(sv, bike)
    sv:run(0.6)
    local f = F.wheels(bike)
    local base = f.load
    F.input(bike, { leanFwd = true })
    sv:run(0.05)
    T.ok(bike.st.leanFwd > 0.1 and bike.st.leanFwd < 0.9, "on its way: " .. bike.st.leanFwd)
    sv:run(1.0)
    T.near(bike.st.leanFwd, 1, 1e-6, "full")
    T.ok(f.load > base, "the front tyre carries more: " .. base .. " -> " .. f.load)
    F.input(bike, {})
    sv:run(1.0)
    T.near(bike.st.leanFwd, 0, 1e-6, "and off again")
end)

T.test("weight forward: it is networked for the rider's IK, and the torso folds by it", function()
    local sv, world = F.server()
    local bike = F.bike(sv)
    F.scripted(sv, bike)
    sv:run(0.6)
    F.input(bike, { leanFwd = true })
    sv:run(1.0)
    bike:Think()
    T.near(bike:GetLeanFwd(), 1, 1e-6, "LeanFwd on the entity")
    local cl = F.client(world)
    local B = cl.env.BMX
    local flat = B.RiderPose({ speed = 0, topSpeed = 400, pitch = 0 })
    local over = B.RiderPose({ speed = 0, topSpeed = 400, pitch = 0, leanFwd = 1 })
    T.ok(over.spine.y > flat.spine.y + 10, "the spine folds further forward: " .. flat.spine.y .. " -> " .. over.spine.y)
    T.ok(over.rThigh.y < flat.rThigh.y, "and the thighs fold under it")
    local half = B.RiderPose({ speed = 0, topSpeed = 400, pitch = 0, leanFwd = 0.5 })
    T.near(half.spine.y - flat.spine.y, (over.spine.y - flat.spine.y) * 0.5, 1e-6, "in proportion")
end)

--------------------------------------------------------------------------
-- The nose manual, flown
--------------------------------------------------------------------------
-- 15 mph, a stoppie with the weight forward until the rear is up, then the brake
-- off with the lean held. Returns what the next `seconds` did.
local function noseManual(opts)
    opts = opts or {}
    local sv = F.server()
    local E = sv.env
    if opts.on ~= false then E.GetConVar("bmx_nose_manual"):SetString("1") end
    local bike = F.bike(sv)
    F.scripted(sv, bike)
    sv:run(0.5)
    F.accelerateTo(sv, bike, 264)
    local f, r = F.wheels(bike)
    F.input(bike, { brakeFront = 1, pitch = -0.6, leanFwd = true })
    local up = sv:run(2, function() return f.onGround and not r.onGround and bike.st.pitch < -0.12 end)
    local out = { sv = sv, bike = bike, f = f, r = r, lifted = up, speed0 = bike.st.speed }
    -- The brake comes off; the weight stays forward. (-0.35 is what sv_input.lua
    -- asks for with the brake off and the nose manual on.)
    F.input(bike, { pitch = -0.35, leanFwd = true, noseTrim = opts.trim or 0 })
    local up_ticks, n, deepest, shallowest = 0, 0, 0, -9
    out.held = sv:run(opts.seconds or 2.6, function()
        n = n + 1
        if f.onGround and not r.onGround then up_ticks = up_ticks + 1 end
        deepest = math.min(deepest, bike.st.pitch)
        if bike.st.noseHold then shallowest = math.max(shallowest, bike.st.pitch) end
        return false
    end)
    out.share, out.deepest, out.shallowest = up_ticks / math.max(n, 1), deepest, shallowest
    return out
end

T.test("nose manual: brake off with the weight forward keeps the front wheel rolling, rear up, for over 2 s", function()
    local o = noseManual({ seconds = 2.4 })
    T.ok(o.lifted, "the stoppie lifted the rear first")
    T.ok(o.share > 0.9, string.format("rear up for %.0f%% of the 2.4 s after the brake came off", o.share * 100))
    T.ok(math.deg(o.deepest) > -45, "never over the bars: " .. math.deg(o.deepest))
    T.ok(o.bike.st.noseHold, "still a nose manual")
    T.ok(o.bike.st.speed > 25, "still rolling: " .. o.bike.st.speed)
    T.ok(o.sv.env.IsValid(o.bike:GetDriver()), "and the rider is aboard")
    T.eq(#o.sv.errors, 0, "no errors: " .. table.concat(o.sv.errors, " | "))
end)

T.test("nose manual: W leans it further over and S sits it up", function()
    local deep = noseManual({ trim = 1, seconds = 1.5 })
    local shallow = noseManual({ trim = -1, seconds = 1.5 })
    T.ok(deep.bike.st.pitch < shallow.bike.st.pitch,
        string.format("W %.1f deg, S %.1f deg", math.deg(deep.bike.st.pitch), math.deg(shallow.bike.st.pitch)))
    T.ok(deep.bike.st.noseHold and shallow.bike.st.noseHold, "both held it")
end)

T.test("nose manual: letting go of the lean puts the rear back down, and it pays by the second", function()
    local o = noseManual({ seconds = 2.0 })
    local landed = {}
    o.sv.env.hook.Add("BMX_TricksLanded", "t", function(b, ply, tricks, total)
        for _, t in ipairs(tricks) do landed[#landed + 1] = t end
    end)
    F.input(o.bike, {})
    o.sv:run(1.5)
    T.ok(o.r.onGround, "the rear is down")
    T.ok(not o.bike.st.noseHold, "no longer a nose manual")
    local got
    for _, t in ipairs(landed) do if t.name == "Nose Manual" then got = t end end
    T.ok(got, "paid as a Nose Manual")
    T.between(got and got.held or 0, 1.5, 4, "held for about its two seconds")
    T.eq(got and got.points, math.floor((got and got.held or 0) * o.sv.env.BMX.Config.Tricks.noseManualPerSec),
        "at the config's points per second")
end)

T.test("nose manual: bmx_nose_manual 0 and the stoppie ends with the brake, as before", function()
    local o = noseManual({ on = false, seconds = 1.5 })
    T.ok(not o.bike.st.noseHold, "never a nose manual")
    T.ok(o.r.onGround, "the rear came down")
end)

T.test("nose manual: it lets go when the front wheel has stopped rolling", function()
    local sv, bike = (function()
        local o = noseManual({ seconds = 0.2 })
        return o.sv, o.bike
    end)()
    bike:GetPhysicsObject():SetVelocity(sv.env.Vector(0, 0, 0))
    sv:run(0.6)
    T.ok(not bike.st.noseHold, "below Pitch.noseMinSpeed it is not held")
end)

T.test("nose manual: a lean alone, with the rear on the ground, starts nothing", function()
    local sv = F.server()
    sv.env.GetConVar("bmx_nose_manual"):SetString("1")
    local bike = F.bike(sv)
    F.scripted(sv, bike)
    sv:run(0.5)
    F.accelerateTo(sv, bike, 264)
    F.input(bike, { pitch = -0.35, leanFwd = true })
    local f, r = F.wheels(bike)
    local lifted = false
    sv:run(2, function() if not r.onGround then lifted = true end end)
    T.ok(not lifted, "the rear never left the ground")
    T.ok(not bike.st.noseHold, "no nose manual")
    T.ok(bike.st.leanFwd > 0.99, "though the weight is forward")
end)

--------------------------------------------------------------------------
-- Combos
--------------------------------------------------------------------------
T.test("combo: a Nose Manual chains from a trick and into a hop, and the manual holds the combo open", function()
    local o = noseManual({ seconds = 1.6 })
    local sv, bike = o.sv, o.bike
    -- The combo was opened by an earlier trick, a good while ago: only the held
    -- manual keeps it alive (sv_combo.lua), then the paid manual joins it.
    bike:AwardTricks({ { name = "Backflip", count = 1, points = 500 } })
    bike.st.combo.last = sv.world.time - 5
    sv:run(0.5)
    T.ok(bike.st.combo, "the nose manual holds the combo open past its grace")
    F.input(bike, {})
    sv:run(0.6)
    T.ok(bike.st.combo and bike.st.combo.n == 2, "the Nose Manual joined it: " .. tostring(bike.st.combo and bike.st.combo.n))
    T.eq(bike.st.combo.names[2], "Nose Manual", "by name")
    -- And on into a hop: it is still open as the bike leaves the ground.
    bike.hopHeld, bike.hopCharge = true, 0
    sv:run(0.3)
    bike.hopRelease = true
    local air = sv:run(0.5, function() return not bike.st.grounded end)
    T.ok(air, "the bike hopped")
    T.ok(bike.st.combo, "the combo is still open in the hop")
    sv:run(2.5)
    T.eq(bike.st.combo, nil, "and banked once riding plainly again")
end)
