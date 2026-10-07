--[[--------------------------------------------------------------------------
    Combos (sv_combo.lua): tricks chained together pay a bonus when landed,
    and nothing extra when the rider bails.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local function riding()
    local sv = F.server()
    local bike = F.bike(sv)
    local ply = F.rider(sv, bike, { name = "Rider" })
    sv:run(0.5)
    return sv, bike, ply
end

local function lastCombo(sv)
    local msg
    for _, m in ipairs(sv.world.wire) do if m.name == "bmx_combo" then msg = m end end
    return msg
end

T.test("combo: two tricks linked pay double when the rider rides away clean", function()
    local sv, bike = riding()
    local score0 = bike:GetScore()
    bike:AwardTricks({ { name = "Backflip", count = 1, points = 500 } })
    sv:run(0.3)
    bike:AwardTricks({ { name = "Crank Grind", count = 1, points = 140 } })
    T.eq(bike.st.combo.n, 2, "two tricks in the combo")
    T.eq(bike:GetScore(), score0 + 640, "the tricks' own points, straight away")
    sv:run(1.2)
    T.eq(bike.st.combo, nil, "banked once riding plainly for Combo.grace")
    T.eq(bike:GetScore(), score0 + 640 + 640, "plus a bonus of 640 x (2 - 1)")
    local m = lastCombo(sv)
    T.ok(m, "the rider was told")
    T.eq(m.items[1].value, 1, "LANDED")
    T.eq(m.items[4].value, 640, "with the bonus")
end)

T.test("combo: three tricks triple it", function()
    local sv, bike = riding()
    local s0 = bike:GetScore()
    for _, t in ipairs({ { "Backflip", 500 }, { "Manual", 150 }, { "Double Peg Grind", 200 } }) do
        bike:AwardTricks({ { name = t[1], count = 1, points = t[2] } })
        sv:run(0.2)
    end
    sv:run(1.2)
    T.eq(bike:GetScore(), s0 + 850 * 3, "850 of tricks, and a bonus of 850 x 2")
end)

T.test("combo: a lone trick is just a trick", function()
    local sv, bike = riding()
    local s0 = bike:GetScore()
    bike:AwardTricks({ { name = "Backflip", count = 1, points = 500 } })
    sv:run(1.5)
    T.eq(bike:GetScore(), s0 + 500, "no bonus for a combo of one")
end)

T.test("combo: grinding or a manual holds it open past the grace", function()
    local sv, bike = riding()
    bike:AwardTricks({ { name = "Backflip", count = 1, points = 500 } })
    bike.st.grind = { kind = "crank" }          -- stands in for a grind under way
    bike.st.combo.last = sv.world.time - 5
    sv.env.BMX.ComboThink(bike, bike.st)
    T.ok(bike.st.combo, "still open while grinding")
    bike.st.grind = nil
    bike.st.manual = { shape = "wheelie" }
    bike.st.combo.last = sv.world.time - 5
    sv.env.BMX.ComboThink(bike, bike.st)
    T.ok(bike.st.combo, "still open in a manual")
    bike.st.manual = nil
end)

T.test("combo: a crash before it banks loses the bonus, not the tricks", function()
    local sv, bike = riding()
    local s0 = bike:GetScore()
    bike:AwardTricks({ { name = "Backflip", count = 1, points = 500 } })
    bike:AwardTricks({ { name = "Barrel Roll", count = 1, points = 400 } })
    bike:Crash("impact", 0.5)
    T.eq(bike.st.combo, nil, "combo gone")
    T.eq(bike:GetScore(), s0 + 900, "the tricks' own points stay; no bonus")
    local m = lastCombo(sv)
    T.ok(m, "the rider was told, before being thrown off")
    T.eq(m.items[1].value, 2, "BAILED")
end)

T.test("combo: the rider's screen builds the chain, then shows it landed", function()
    local sv, world = F.server()
    local bike = F.bike(sv)
    F.rider(sv, bike, { name = "Human" })
    sv:run(0.3)
    local cl = F.client(world)
    cl.localPlayer = cl:player("Human")
    bike:AwardTricks({ { name = "Backflip", count = 1, points = 500 } })
    bike:AwardTricks({ { name = "Crank Grind", count = 1, points = 140 } })
    cl:deliver(lastCombo(sv))
    cl.texts = {}
    cl.env.hook.Run("HUDPaint")
    local all = table.concat(cl.texts, " | ")
    T.ok(all:find("Backflip + Crank Grind", 1, true), "the chain: " .. all)
    T.ok(all:find("x2", 1, true), "the multiplier: " .. all)
    sv:run(1.2)
    cl:deliver(lastCombo(sv))
    cl.texts = {}
    cl.env.hook.Run("HUDPaint")
    all = table.concat(cl.texts, " | ")
    T.ok(all:find("COMBO LANDED  +640", 1, true), "landed, with the bonus: " .. all)
end)

-- The bike that found the missing merge groups: one with physics overrides.
T.test("combo: a bike with physics overrides scores and banks combos too", function()
    local sv = F.server()
    sv.env.BMX.RegisterBike("heavy", { physics = { Chassis = { mass = 100 } } })
    local bike = F.bike(sv, "bmx_heavy")
    F.rider(sv, bike, { name = "Rider" })
    sv:run(0.5)
    local s0 = bike:GetScore()
    bike:AwardTricks({ { name = "Backflip", count = 1, points = 500 } })
    bike:AwardTricks({ { name = "Manual", count = 1, points = 150 } })
    T.eq(bike.st.combo and bike.st.combo.n, 2, "the combo opened on the override bike")
    sv:run(1.2)
    T.eq(bike:GetScore(), s0 + 650 * 2, "and banked")
end)
