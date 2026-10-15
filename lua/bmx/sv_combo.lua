--[[--------------------------------------------------------------------------
    bmx/sv_combo.lua

    COMBOS, the way the Tony Hawk games do them. Every trick already pays its
    own points the moment it lands (ENT:AwardTricks). Tricks chained together
    -- air into a grind, the grind into a manual, the manual into a hop --
    also build one combo, and a combo that is LANDED pays a bonus on top:

        bonus = (the chain's points) x (the multiplier - 1)

    The multiplier is the tricks in the chain, so two tricks double the
    chain's points, three triple them. The combo is open while the bike is in
    the air, grinding, or holding a manual, and for Combo.grace seconds on the
    ground after its last trick, which is the time a rider has to link the
    next one. Crash before it banks and the bonus is gone ("BAILED"); the
    tricks' own points stay, as they always did.

    VARIETY (bmx_combo_variety, on by default; Combo.repeats). The same trick
    again in the same combo counts for less. The k-th time one trick -- by
    name: "Backflip", "Switch Kickflip", "50-50", "Air Time" -- is in the
    chain, it adds Combo.repeats[k] of its points to the chain and one to the
    multiplier: all of it, then 3/4, 1/2, 1/4. The fifth time and after it adds
    nothing to either, though it still pays its own points and still keeps the
    combo going. So one trick can lift a combo to x4 at most and only a varied
    line goes further. Before it, every trick raised the multiplier whatever it
    was, the chain's value grew as the square of its length, and the best
    combo was the most valuable trick spammed: ten backflips (50,000) beat ten
    different tricks (35,550), and twenty skate jumps on the spot were a 30,000
    combo out of 1,500 points of jumps.

    So a chain keeps two sums:

        base    every trick's own points, as they were paid
        value   the same with repeats scaled: what the multiplier multiplies
                (with variety off, or no repeats, value is base)
        n       the multiplier

        bonus = value x (n - 1)          total = value + bonus = value x n

    The rider sees it build (cl_hud.lua): the chain, value x n, and then
    LANDED with the bonus, or BAILED.
----------------------------------------------------------------------------]]

BMX = BMX or {}

util.AddNetworkString("bmx_combo")

local floor, max = math.floor, math.max

local STATE = { open = 0, landed = 1, bailed = 2 }
BMX.ComboState = STATE
local SHOW = 6          -- names sent: the latest few, which is what fits

-- The wire's points are the chain's VALUE (what the HUD multiplies by n); a combo
-- opened before a Lua reload has only its base.
local function valueOf(c) return c.value or c.base end

local function send(ent, state, c, bonus)
    local ply = ent:GetDriver()
    if not IsValid(ply) then return end
    net.Start("bmx_combo", true)
        net.WriteUInt(state, 2)
        net.WriteUInt(math.min(c.n, 255), 8)
        net.WriteUInt(math.min(valueOf(c), 1048575), 20)
        net.WriteUInt(math.min(bonus or 0, 4194303), 22)
        local first = math.max(1, #c.names - SHOW + 1)
        net.WriteUInt(#c.names - first + 1, 3)
        for i = first, #c.names do net.WriteString(c.names[i]) end
    net.Send(ply)
end

-- What share of its points a trick adds to the chain the k-th time it is in one
-- combo, 0..1. 0 means it adds nothing and does not raise the multiplier either.
-- `cfg` is the vehicle's config (ent:Cfg()).
function BMX.ComboRepeatShare(cfg, k)
    if BMX.ComboVarietyOn and not BMX.ComboVarietyOn() then return 1 end
    local list = cfg and cfg.Combo and cfg.Combo.repeats
    if type(list) ~= "table" then return 1 end
    local s = tonumber(list[k]) or 0
    return s > 0 and s or 0
end

-- Tricks just awarded join the combo (opening one if there is none).
function BMX.ComboAdd(ent, tricks)
    local st = ent.st
    local cfg = ent:Cfg()
    if not st or not cfg.Combo.enabled then return end
    if BMX.CombosEnabled and not BMX.CombosEnabled() then return end   -- bmx_combos 0
    local c = st.combo or { n = 0, base = 0, value = 0, names = {}, seen = {} }
    c.seen = c.seen or {}
    c.value = c.value or c.base
    for _, t in ipairs(tricks) do
        local pts = t.points or 0
        local k = (c.seen[t.name] or 0) + 1
        c.seen[t.name] = k
        local share = BMX.ComboRepeatShare(cfg, k)
        c.base = c.base + pts
        if share > 0 then
            -- A compound ("Backflip Superman") stands for the tricks it is made of.
            c.n = c.n + (t.tricks or 1)
            c.value = c.value + max(0, floor(pts * share + 0.5))
        end
        c.names[#c.names + 1] = ((t.count or 1) > 1 and (t.count .. "x ") or "") .. t.name
    end
    c.last = CurTime()
    st.combo = c
    send(ent, STATE.open, c)
end

-- Bank it (landed) or lose it (bailed). Returns the bonus paid.
function BMX.ComboEnd(ent, landed)
    local st = ent.st
    local c = st and st.combo
    if not c then return 0 end
    st.combo = nil
    local bonus = 0
    -- Switched off mid-combo (bmx_scoring / bmx_combos): the chain closes
    -- without paying, as if it had never been a combo.
    if landed and c.n >= 2 and (not BMX.CombosEnabled or BMX.CombosEnabled()) then
        bonus = valueOf(c) * (c.n - 1)
        ent:SetScore(ent:GetScore() + bonus)
    end
    local rider = ent:GetDriver()
    -- What a listener wants to know about the chain, on the chain itself.
    c.value = valueOf(c)
    c.bonus, c.total = bonus, c.value + bonus
    -- Public names (docs/MODDING.md). A "combo" is two or more tricks: a lone
    -- trick that lands or is lost is a trick (BMX_TrickLanded), not a combo.
    if IsValid(rider) and c.n >= 2 then
        if landed and bonus > 0 then
            hook.Run("BMX_ComboBanked", rider, c, c.total)
        elseif not landed then
            hook.Run("BMX_ComboBailed", rider, c)
        end
    end
    hook.Run("BMX_ComboEnded", ent, rider, c, landed, bonus)    -- deprecated alias
    send(ent, landed and STATE.landed or STATE.bailed, c, bonus)
    return bonus
end

-- Each substep: keep it open while something is going on, bank it once the
-- rider has been plainly riding for Combo.grace.
function BMX.ComboThink(ent, st)
    local c = st.combo
    if not c then return end
    if not st.grounded or st.grind or st.manual then
        c.last = CurTime()
        return
    end
    if CurTime() - c.last >= ent:Cfg().Combo.grace then BMX.ComboEnd(ent, true) end
end
