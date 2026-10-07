--[[--------------------------------------------------------------------------
    Server-owner settings (sv_rules.lua): the per-player bike limit, and
    switching scoring and combos off.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local function looker(sv, name, x)
    local E = sv.env
    local ply = sv:player(name or "Spawner")
    ply:SetPos(E.Vector(x or 0, 0, 0))
    ply._eyeTrace = { Hit = true, HitPos = E.Vector((x or 0) + 100, 0, 0), HitNormal = E.Vector(0, 0, 1) }
    return ply
end

local function spawn(sv, ply, id)
    sv.world.time = sv.world.time + 2           -- past the spawn cooldown
    sv:command("bmx_spawn", ply, id)
end

local function count(sv)
    local n = 0
    for _, id in ipairs(sv.env.BMX.BikeIDs()) do
        n = n + #sv.env.ents.FindByClass(sv.env.BMX.ClassFor(id))
    end
    return n
end

local function set(sv, name, v) sv.env.GetConVar(name):SetString(tostring(v)) end

--------------------------------------------------------------------------
-- The limit
--------------------------------------------------------------------------

T.test("rules: the three settings exist, archived, with safe defaults", function()
    local sv = F.server()
    T.eq(sv.env.GetConVar("bmx_max_per_player"):GetInt(), 0, "no BMX limit by default")
    T.eq(sv.env.GetConVar("bmx_scoring"):GetInt(), 1, "scoring on by default")
    T.eq(sv.env.GetConVar("bmx_combos"):GetInt(), 1, "combos on by default")
end)

T.test("rules: with no limit set, a player can spawn as many as sandbox allows", function()
    local sv = F.server()
    local ply = looker(sv)
    for _ = 1, 5 do spawn(sv, ply) end
    T.eq(count(sv), 5, "five bikes")
end)

T.test("rules: bmx_max_per_player stops the next bike and says why", function()
    local sv = F.server()
    set(sv, "bmx_max_per_player", 2)
    local ply = looker(sv)
    spawn(sv, ply) spawn(sv, ply)
    T.eq(count(sv), 2, "two allowed")
    ply._chat = {}
    spawn(sv, ply)
    T.eq(count(sv), 2, "the third refused")
    local said = table.concat(ply._chat, "\n")
    T.ok(said:find("bmx_max_per_player 2", 1, true), "and told: " .. said)
end)

T.test("rules: the limit counts every kind of bike together", function()
    local sv = F.server()
    set(sv, "bmx_max_per_player", 2)
    local ply = looker(sv)
    spawn(sv, ply, "cruiser") spawn(sv, ply, "mini")
    spawn(sv, ply, "stock")
    T.eq(count(sv), 2, "a cruiser and a mini, then no stock bike")
end)

T.test("rules: the limit is per player", function()
    local sv = F.server()
    set(sv, "bmx_max_per_player", 1)
    local a, b = looker(sv, "A"), looker(sv, "B", 500)
    spawn(sv, a) spawn(sv, b)
    T.eq(count(sv), 2, "one each")
    spawn(sv, a)
    T.eq(count(sv), 2, "not a second for A")
end)

T.test("rules: removing a bike frees the slot", function()
    local sv = F.server()
    set(sv, "bmx_max_per_player", 1)
    local ply = looker(sv)
    spawn(sv, ply)
    local e = sv.env.ents.FindByClass("bmx_base")[1]
    e:Remove()
    sv:run(0.1)
    spawn(sv, ply)
    T.eq(count(sv), 1, "a new one after the old one is gone")
end)

T.test("rules: the spawn menu's path is limited too, not only bmx_spawn", function()
    local sv = F.server()
    set(sv, "bmx_max_per_player", 1)
    local ply = looker(sv)
    spawn(sv, ply)
    -- What sandbox's spawn menu does: ask PlayerSpawnSENT before creating.
    T.eq(sv.env.hook.Run("PlayerSpawnSENT", ply, "bmx_cruiser"), false, "refused by the hook")
end)

T.test("rules: the limit says nothing about other entities", function()
    local sv = F.server()
    set(sv, "bmx_max_per_player", 1)
    local ply = looker(sv)
    spawn(sv, ply)
    T.eq(sv.env.hook.Run("PlayerSpawnSENT", ply, "sent_ball"), nil, "not ours: no opinion")
end)

T.test("rules: a bike spawned by either door is owned by its spawner", function()
    local sv = F.server()
    local ply = looker(sv)
    spawn(sv, ply, "mini")
    local e = sv.env.ents.FindByClass("bmx_mini")[1]
    T.ok(e.BMXOwner == ply, "bmx_spawn sets the owner")
    local other = F.bike(sv)
    sv.env.hook.Run("PlayerSpawnedSENT", ply, other)
    T.ok(other.BMXOwner == ply, "the spawn menu's PlayerSpawnedSENT sets it too")
    T.eq(sv.env.BMX.BikesOwnedBy(ply), 2, "both counted")
end)

T.test("rules: the gamemode's own veto still wins with the limit off", function()
    local sv = F.server()
    local ply = looker(sv)
    function sv.gm:PlayerSpawnSENT() return false end
    spawn(sv, ply)
    T.eq(count(sv), 0, "sandbox said no")
end)

T.test("rules: IsBikeClass knows our classes and only ours", function()
    local sv = F.server()
    local B = sv.env.BMX
    for _, c in ipairs({ "bmx_base", "bmx_cruiser", "bmx_mini" }) do T.ok(B.IsBikeClass(c), c) end
    for _, c in ipairs({ "bmx_nope", "prop_physics", "" }) do T.ok(not B.IsBikeClass(c), "not " .. c) end
end)

--------------------------------------------------------------------------
-- Scoring and combos
--------------------------------------------------------------------------

local function riding()
    local sv = F.server()
    local bike = F.bike(sv)
    local ply = F.rider(sv, bike, { name = "Rider" })
    sv:run(0.5)
    return sv, bike, ply
end

local function sent(sv, name)
    local n = 0
    for _, m in ipairs(sv.world.wire) do if m.name == name then n = n + 1 end end
    return n
end

T.test("rules: bmx_scoring 0 means no points, no callout and no combo", function()
    local sv, bike = riding()
    set(sv, "bmx_scoring", 0)
    local s0, calls = bike:GetScore(), sent(sv, "bmx_tricks")
    T.eq(bike:AwardTricks({ { name = "Backflip", count = 1, points = 500 } }), 0, "nothing awarded")
    T.eq(bike:GetScore(), s0, "score unchanged")
    T.eq(sent(sv, "bmx_tricks"), calls, "no callout sent")
    T.eq(bike.st.combo, nil, "no combo opened")
end)

T.test("rules: bmx_scoring 0 also silences the BMX_TricksLanded hook", function()
    local sv, bike = riding()
    set(sv, "bmx_scoring", 0)
    local heard = false
    sv.env.hook.Add("BMX_TricksLanded", "t", function() heard = true end)
    bike:AwardTricks({ { name = "Backflip", count = 1, points = 500 } })
    T.ok(not heard, "nothing landed, as far as other addons are told")
end)

T.test("rules: scoring back on scores again", function()
    local sv, bike = riding()
    set(sv, "bmx_scoring", 0)
    bike:AwardTricks({ { name = "Backflip", count = 1, points = 500 } })
    set(sv, "bmx_scoring", 1)
    local s0 = bike:GetScore()
    bike:AwardTricks({ { name = "Backflip", count = 1, points = 500 } })
    T.eq(bike:GetScore(), s0 + 500, "scored")
end)

T.test("rules: bmx_combos 0 keeps trick points but pays no combo bonus", function()
    local sv, bike = riding()
    set(sv, "bmx_combos", 0)
    local s0 = bike:GetScore()
    bike:AwardTricks({ { name = "Backflip", count = 1, points = 500 } })
    bike:AwardTricks({ { name = "Crank Grind", count = 1, points = 140 } })
    T.eq(bike.st.combo, nil, "no combo builds")
    sv:run(1.5)
    T.eq(bike:GetScore(), s0 + 640, "the tricks' own points and no bonus")
    T.eq(sent(sv, "bmx_combo"), 0, "no combo HUD messages")
end)

T.test("rules: switching combos off mid-combo closes it without the bonus", function()
    local sv, bike = riding()
    local s0 = bike:GetScore()
    bike:AwardTricks({ { name = "Backflip", count = 1, points = 500 } })
    bike:AwardTricks({ { name = "Crank Grind", count = 1, points = 140 } })
    T.ok(bike.st.combo, "a combo is open")
    set(sv, "bmx_combos", 0)
    sv:run(1.5)
    T.eq(bike.st.combo, nil, "closed")
    T.eq(bike:GetScore(), s0 + 640, "and nothing extra paid")
end)

T.test("rules: bmx_scoring 0 turns combos off whatever bmx_combos says", function()
    local sv = riding()
    set(sv, "bmx_scoring", 0)
    set(sv, "bmx_combos", 1)
    T.ok(not sv.env.BMX.CombosEnabled(), "no combos without scoring")
    T.ok(not sv.env.BMX.ScoringEnabled(), "and no scoring")
end)

T.test("rules: a grind under bmx_scoring 0 still grinds, it just scores nothing", function()
    local sv, bike = riding()
    set(sv, "bmx_scoring", 0)
    local s0 = bike:GetScore()
    -- The grind's own award path, as sv_grind calls it.
    bike:AwardTricks({ { name = "Crank Grind", count = 1, points = 140 } })
    T.eq(bike:GetScore(), s0, "no points")
    T.eq(#sv.errors, 0, "and no errors: " .. table.concat(sv.errors, " | "))
end)
