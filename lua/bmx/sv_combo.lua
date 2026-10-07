--[[--------------------------------------------------------------------------
    bmx/sv_combo.lua

    COMBOS, the way the Tony Hawk games do them. Every trick already pays its
    own points the moment it lands (ENT:AwardTricks). Tricks chained together
    -- air into a grind, the grind into a manual, the manual into a hop --
    also build one combo, and a combo that is LANDED pays a bonus on top:

        bonus = (the combo's trick points) x (tricks in it - 1)

    so two tricks double the chain's points, three triple them. The combo is
    open while the bike is in the air, grinding, or holding a manual, and for
    Combo.grace seconds on the ground after its last trick, which is the time
    a rider has to link the next one. Crash before it banks and the bonus is
    gone ("BAILED"); the tricks' own points stay, as they always did.

    The rider sees it build (cl_hud.lua): the chain, the multiplier, and then
    LANDED with the bonus, or BAILED.
----------------------------------------------------------------------------]]

BMX = BMX or {}

util.AddNetworkString("bmx_combo")

local STATE = { open = 0, landed = 1, bailed = 2 }
BMX.ComboState = STATE
local SHOW = 6          -- names sent: the latest few, which is what fits

local function send(ent, state, c, bonus)
    local ply = ent:GetDriver()
    if not IsValid(ply) then return end
    net.Start("bmx_combo", true)
        net.WriteUInt(state, 2)
        net.WriteUInt(math.min(c.n, 255), 8)
        net.WriteUInt(math.min(c.base, 1048575), 20)
        net.WriteUInt(math.min(bonus or 0, 4194303), 22)
        local first = math.max(1, #c.names - SHOW + 1)
        net.WriteUInt(#c.names - first + 1, 3)
        for i = first, #c.names do net.WriteString(c.names[i]) end
    net.Send(ply)
end

-- Tricks just awarded join the combo (opening one if there is none).
function BMX.ComboAdd(ent, tricks)
    local st = ent.st
    if not st or not ent:Cfg().Combo.enabled then return end
    if BMX.CombosEnabled and not BMX.CombosEnabled() then return end   -- bmx_combos 0
    local c = st.combo or { n = 0, base = 0, names = {} }
    for _, t in ipairs(tricks) do
        -- A compound ("Backflip Superman") stands for the tricks it is made of.
        c.n = c.n + (t.tricks or 1)
        c.base = c.base + (t.points or 0)
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
        bonus = c.base * (c.n - 1)
        ent:SetScore(ent:GetScore() + bonus)
    end
    hook.Run("BMX_ComboEnded", ent, ent:GetDriver(), c, landed, bonus)
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
