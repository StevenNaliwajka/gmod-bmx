--[[--------------------------------------------------------------------------
    bmx/sv_lagcomp.lua

    LAG COMPENSATION FOR TAKEOFF DECISIONS (G30, bmx_lagcomp, default OFF).

    A trick pressed at the lip on the rider's screen should count at the lip on
    the server. Without this, a hop released as the front wheel leaves a ramp
    arrives a ping later, finds the bike airborne, and is dropped; an ollie's
    coyote window and the spine transfer's W press are judged by the clock they
    ARRIVED on, not the one they were pressed on.

    WHAT THIS DOES: it stamps each command's input with its AGE (how long before
    now the rider acted, sh_predict.lua's CmdAge) in inp.cmdAge, and keeps a
    short history of whether each ridden bike was on the ground. The three
    takeoff decisions then ask about the moment of the press:

        hop release    sv_physics.lua: grounded, OR was on the ground at the press
        ollie pop      sv_board.lua:   the coyote window is measured to the press
        spine W        sv_air.lua:     the press is dated to when it was made

    WHAT THIS DOES NOT DO: it never moves the bike, never re-runs physics, and
    never lets a press count that the rider could not have made: the age is
    clamped to bmx_lagcomp_max and to what their ping explains. With the switch
    off, inp.cmdAge is 0 and every expression it appears in is the arithmetic it
    was before, bit for bit (x - 0 == x).
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.LagComp = BMX.LagComp or {}
local LC = BMX.LagComp

local FLAGS = bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED)
local cvOn = CreateConVar("bmx_lagcomp", "0", FLAGS,
    "BMX: 1 = a trick pressed at the lip counts at the lip on the server (hop, ollie, spine transfer); 0 = judged when it arrives.")
local cvMax = CreateConVar("bmx_lagcomp_max", "0.15", FLAGS,
    "BMX: the most lag, in seconds, a trick press may be back-dated by.", 0, 0.5)

function BMX.LagCompOn() return cvOn:GetBool() end

local KEEP = 0.6     -- s of grounded history kept per bike

-- Called every tick for each ridden bike: one { t, grounded } sample. Only while
-- the switch is on, so off costs nothing.
function LC.Record(bike)
    local st = bike.st
    if not st then return end
    local h = bike.lagHist
    if not h then h = {} bike.lagHist = h end
    local now = CurTime()
    h[#h + 1] = { t = now, grounded = st.grounded and true or false }
    while #h > 1 and h[1].t < now - KEEP do table.remove(h, 1) end
end

-- The age to stamp on this command's input, seconds. 0 with the switch off.
function LC.Age(ply, cmd)
    if not cvOn:GetBool() then return 0 end
    local lerp = ply:GetInfoNum("cl_interp", 0.1)
    local ping = (ply.Ping and ply:Ping() or 0) / 1000
    return BMX.Predict.CmdAge(engine.TickCount and engine.TickCount() or 0,
        cmd.TickCount and cmd:TickCount() or 0, lerp, engine.TickInterval(),
        cvMax:GetFloat(), ping)
end

-- Was this bike on the ground `age` seconds ago, though it is not now? The
-- question a takeoff decision asks when the press is older than the tick it is
-- judged on. False with the switch off, with no age, or with no history.
function LC.Grace(bike, age)
    if not age or age <= 0 or not cvOn:GetBool() then return false end
    local st = bike.st
    if not st or st.grounded or not st.groundNormal then return false end
    local h = bike.lagHist
    if not h then return false end
    return BMX.Predict.GroundedAt(h, CurTime() - age)
end
function BMX.LagCompGrace(bike, age) return LC.Grace(bike, age) end

hook.Add("Tick", "BMX.LagComp", function()
    if not cvOn:GetBool() then return end
    for _, ply in ipairs(player.GetAll()) do
        local bike = ply.BMXBike
        if IsValid(bike) and bike:GetDriver() == ply then LC.Record(bike) end
    end
end)
