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

--------------------------------------------------------------------------
-- VARIETY (bmx_combo_variety, Combo.repeats): a trick repeated in one combo adds
-- less to the chain each time, and from the fifth time nothing, not even to the
-- multiplier. Its own points are paid in full every time.
--------------------------------------------------------------------------

local function chain(sv, bike, landings)
    for _, l in ipairs(landings) do
        bike:AwardTricks(l)
        sv:run(0.2)
    end
end

local function same(n, name, pts)
    local out = {}
    for i = 1, n do out[i] = { { name = name, count = 1, points = pts } } end
    return out
end

local function one(name, pts) return { { name = name, count = 1, points = pts } } end

-- What a chain of landings adds to the score, banked.
local function scored(landings)
    local sv, bike = riding()
    local s0 = bike:GetScore()
    chain(sv, bike, landings)
    sv:run(1.5)
    return bike:GetScore() - s0
end

T.test("combo variety: a trick repeated in one combo adds less each time, and nothing from the fifth", function()
    local sv, bike = riding()
    local paid = {}
    sv.env.hook.Add("BMX_TrickLanded", "t", function(ply, t, pts) paid[#paid + 1] = pts end)
    local s0 = bike:GetScore()
    chain(sv, bike, same(6, "Backflip", 500))
    local c = bike.st.combo
    T.eq(#paid, 6, "every backflip is a trick landed")
    for i = 1, 6 do T.eq(paid[i], 500, "and pays its own 500, the sixth too (" .. i .. ")") end
    T.eq(bike:GetScore(), s0 + 3000, "all six paid in full as they landed")
    T.eq(c.base, 3000, "base: what the tricks paid")
    T.eq(c.value, 500 + 375 + 250 + 125, "value: all of it, 3/4, 1/2, 1/4, then nothing")
    T.eq(c.n, 4, "the fifth and sixth do not raise the multiplier")
    local open = lastCombo(sv)
    T.eq(open.items[2].value, 4, "the rider sees x4")
    T.eq(open.items[3].value, 1250, "of the chain's value")
    sv:run(1.2)
    T.eq(bike.st.combo, nil, "banked")
    T.eq(bike:GetScore(), s0 + 3000 + 1250 * 3, "the bonus is value x (n - 1): 3,750, not 15,000")
    T.eq(lastCombo(sv).items[4].value, 3750, "LANDED +3,750")
end)

T.test("combo variety: a dead repeat still keeps the combo going", function()
    local sv, bike = riding()
    chain(sv, bike, same(4, "Backflip", 500))
    bike.st.combo.last = sv.world.time - 0.7          -- nearly banked
    bike:AwardTricks(one("Backflip", 500))            -- the fifth: adds nothing
    sv:run(0.5)
    T.ok(bike.st.combo, "still open: the fifth backflip linked")
    bike:AwardTricks(one("Tailwhip", 600))
    T.eq(bike.st.combo.n, 5, "and the next new trick counts")
    T.eq(bike.st.combo.value, 1250 + 600, "in full")
end)

T.test("combo variety: ten different tricks out-score ten of the same, as a skate game should", function()
    local spam = scored(same(10, "Backflip", 500))
    local varied = scored({
        one("Backflip", 500), one("Frontflip", 500), one("Barrel Roll", 400), one("360", 250),
        one("Tailwhip", 600), one("Barspin", 400), one("Wheelie", 225), one("Stoppie", 120),
        one("Crank Grind", 280), one("Double Peg Grind", 280),
    })
    T.eq(varied, 3555 * 10, "ten different: 3,555 of tricks, x10, as before")
    T.eq(spam, 5000 + 1250 * 3, "ten backflips: 5,000 of tricks and a bonus of 1,250 x 3 (it was 50,000)")
    T.ok(varied > spam * 4, "variety wins by a mile: " .. varied .. " vs " .. spam)
end)

T.test("combo variety: one long grind, grind-manual-grind, and a second grind that is a different one", function()
    T.eq(scored({ one("Crank Grind", 1400) }), 1400, "10 s on one rail is one trick: no combo")
    T.eq(scored({ one("Crank Grind", 420), one("Wheelie", 600), one("Crank Grind", 420) }),
        1440 + (420 + 600 + 315) * 2, "the second crank grind adds 3/4 to the chain (4,110; it was 4,320)")
    T.eq(scored({ one("Crank Grind", 420), one("Wheelie", 600), one("Double Peg Grind", 420) }),
        1440 * 3, "a different grind counts in full: 4,320, as before")
end)

T.test("combo variety: the same trick is the same name; a compound or a stance is another trick", function()
    local sv, bike = riding()
    chain(sv, bike, {
        { { name = "Backflip", count = 2, points = 1000 } },              -- a double backflip
        one("Backflip", 500),                                             -- a backflip again
        { { name = "Backflip Superman", count = 1, points = 718, tricks = 2 } },
        one("Switch Kickflip", 360),
        one("Kickflip", 300),
    })
    local c = bike.st.combo
    T.eq(c.value, 1000 + 375 + 718 + 360 + 300, "only the second Backflip is a repeat")
    T.eq(c.n, 1 + 1 + 2 + 1 + 1, "and the compound still counts as the two tricks it is made of")
end)

T.test("combo variety: bmx_combo_variety 0 is the old rule, every repeat in full", function()
    local sv, bike = riding()
    sv.env.GetConVar("bmx_combo_variety"):SetString("0")
    local s0 = bike:GetScore()
    chain(sv, bike, same(6, "Backflip", 500))
    T.eq(bike.st.combo.n, 6, "six in the multiplier")
    T.eq(bike.st.combo.value, 3000, "value is base")
    sv:run(1.2)
    T.eq(bike:GetScore(), s0 + 3000 * 6, "3,000 x 6, as it always was")
end)

T.test("combo variety: on by default, and Combo.repeats is all, 3/4, 1/2, 1/4", function()
    local sv = F.server()
    local B = sv.env.BMX
    T.eq(sv.env.GetConVar("bmx_combo_variety"):GetInt(), 1, "on")
    local R = B.Config.Combo.repeats
    T.eq(#R, 4, "four counted")
    T.eq(R[1], 1, "all") T.eq(R[2], 0.75, "3/4") T.eq(R[3], 0.5, "1/2") T.eq(R[4], 0.25, "1/4")
    T.eq(B.ComboRepeatShare(B.Config, 5), 0, "the fifth adds nothing")
    sv.env.GetConVar("bmx_combo_variety"):SetString("0")
    T.eq(B.ComboRepeatShare(B.Config, 5), 1, "off: everything counts")
end)

T.test("combo variety: what BMX_ComboBanked says: base paid, value after repeats, total = value x n", function()
    local sv, bike = riding()
    local got
    sv.env.hook.Add("BMX_ComboBanked", "t", function(ply, c, total) got = { c = c, total = total } end)
    chain(sv, bike, { one("Backflip", 500), one("Wheelie", 200), one("Backflip", 500) })
    sv:run(1.2)
    T.ok(got, "banked")
    T.eq(got and got.c.base, 1200, "base: the tricks' own points, already paid")
    T.eq(got and got.c.value, 500 + 200 + 375, "value: the chain after repeats")
    T.eq(got and got.c.n, 3, "n: the multiplier")
    T.eq(got and got.c.bonus, 1075 * 2, "bonus: value x (n - 1), what the score gets on top")
    T.eq(got and got.total, 1075 * 3, "total: value + bonus, the combo's worth")
    T.eq(got and got.c.total, got and got.total, "on the chain as well")
end)

T.test("combo variety: the rider's screen shows the chain's value and the multiplier it really has", function()
    local sv, world = F.server()
    local bike = F.bike(sv)
    F.rider(sv, bike, { name = "Human" })
    sv:run(0.3)
    local cl = F.client(world)
    cl.localPlayer = cl:player("Human")
    for _ = 1, 5 do bike:AwardTricks(one("Backflip", 500)) end
    cl:deliver(lastCombo(sv))
    cl.texts = {}
    cl.env.hook.Run("HUDPaint")
    local all = table.concat(cl.texts, " | ")
    T.ok(all:find("1,250  x4", 1, true), "value x multiplier: " .. all)
    sv:run(1.2)
    cl:deliver(lastCombo(sv))
    cl.texts = {}
    cl.env.hook.Run("HUDPaint")
    all = table.concat(cl.texts, " | ")
    T.ok(all:find("COMBO LANDED  +3,750", 1, true), "landed, with the bonus: " .. all)
end)
