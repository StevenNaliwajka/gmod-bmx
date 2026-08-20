--[[--------------------------------------------------------------------------
    bmx/sv_input.lua

    Rider input, read server-side.

    WHY NO net MESSAGES. The obvious design sends lean from the client every
    frame. It is also the wrong one: the usercmd already crosses the wire every
    tick, is already ordered, already rate-limited by the engine, and already
    carries analog axes for gamepads. Reading it in StartCommand server-side
    gets all of that for free and adds zero packets. A net message would only
    add a second, unordered, unvalidated channel saying the same thing.

    CONTROLS. Context-sensitive, the same way GTA's are: W/S and A/D mean
    different things on the ground and in the air, because a rider's hands do.

        W / S            ground: pedal / rear brake     air: pitch (flips)
        A / D            ground: lean (which steers)    air: roll
        RMB (hold)       ground: wheelie modifier, W/S becomes pitch
        LMB              front brake  (front-heavy braking = stoppies)
        SPACE            hold to preload, release to bunny hop
        SHIFT            sprint (drains stamina)
        CTRL             tuck (less drag, tighter rotation in the air)

    Nothing here is predicted. GMod has no vehicle prediction API, so the
    simulation is server-authoritative exactly like simfphys and LVS. High-ping
    riders will feel it; that is a property of the engine, not of this addon,
    and pretending otherwise by predicting locally would only add rubber-banding.
----------------------------------------------------------------------------]]

BMX = BMX or {}

-- Keyboard usercmds are clamped to sv_sidespeed / sv_forwardspeed. Dividing by
-- that recovers a -1..1 axis that a gamepad fills in continuously and a keyboard
-- fills in at the extremes.
local function axis(value, cvName, fallback)
    local cv = GetConVar(cvName)
    local scale = (cv and cv:GetFloat() or fallback)
    if scale <= 0 then scale = fallback end
    return BMX.Clamp(value / scale, -1, 1)
end

-- A fresh, all-neutral input table. Kept as a constructor rather than a shared
-- constant so a stale reference can never leak between riders.
function BMX.BlankInput()
    return {
        throttle    = 0,   -- 0..1
        brakeRear   = 0,   -- 0..1
        brakeFront  = 0,   -- 0..1
        leanTarget  = 0,   -- -1..1, raw; smoothed in the physics step
        pitchTarget = 0,   -- -1..1, raw
        hop         = false,
        tuck        = false,
        sprint      = false,
        wheelieMod  = false,

        -- smoothed, owned by the physics step
        lean        = 0,
        pitch       = 0,
    }
end

hook.Add("StartCommand", "BMX.ReadInput", function(ply, cmd)
    local bike = ply.BMXBike
    if not IsValid(bike) or bike:GetDriver() ~= ply then return end

    local inp = bike.input
    if not inp then return end

    local buttons = cmd:GetButtons()
    local function down(bit_) return bit.band(buttons, bit_) ~= 0 end

    local fwd  = axis(cmd:GetForwardMove(), "sv_forwardspeed", 400)
    local side = axis(cmd:GetSideMove(),    "sv_sidespeed",    400)

    -- Digital fallback: some clients (and every bot) send buttons with zero
    -- move axes. Without this the bike is unrideable and the cause is invisible.
    if fwd == 0 then
        if down(IN_FORWARD) then fwd = 1 elseif down(IN_BACK) then fwd = -1 end
    end
    if side == 0 then
        if down(IN_MOVERIGHT) then side = 1 elseif down(IN_MOVELEFT) then side = -1 end
    end

    inp.sprint     = down(IN_SPEED)
    inp.tuck       = down(IN_DUCK)
    inp.wheelieMod = down(IN_ATTACK2)
    inp.brakeFront = down(IN_ATTACK) and 1 or 0

    local airborne = not bike:GetGrounded()

    if airborne then
        -- In the air the rider has no drivetrain to worry about, so both sticks
        -- become rotation.
        inp.throttle    = 0
        inp.brakeRear   = 0
        inp.pitchTarget = fwd
        inp.leanTarget  = side
    elseif inp.wheelieMod then
        -- Ground, modifier held: weight shift instead of drive.
        inp.throttle    = math.max(fwd, 0) * 0.55   -- keep a little drive so a
                                                    -- wheelie can be held under power
        inp.brakeRear   = 0
        inp.pitchTarget = fwd
        inp.leanTarget  = side
    else
        inp.throttle    = math.max(fwd, 0)
        inp.brakeRear   = math.max(-fwd, 0)
        inp.pitchTarget = 0
        inp.leanTarget  = side
    end

    -- Bunny hop: edge-triggered on release, so the press starts a preload and
    -- the release spends it. Holding SPACE forever must not hop.
    local jump = down(IN_JUMP)
    if jump and not inp.hop then
        bike.hopCharge = 0
        bike.hopHeld   = true
    elseif not jump and inp.hop then
        bike.hopRelease = true
    end
    inp.hop = jump

    -- Stop the engine's own use of these keys while seated: without this the
    -- pod tries to make the player jump and duck inside a vehicle, which
    -- produces a stuttering view and, on some maps, an exit.
    cmd:SetButtons(bit.band(buttons, bit.bnot(bit.bor(IN_JUMP, IN_DUCK))))
    cmd:SetForwardMove(0)
    cmd:SetSideMove(0)
    cmd:SetUpMove(0)
end)

--------------------------------------------------------------------------
-- Smoothing.
--
-- A keyboard hands you a square wave. Feeding that straight into the lean
-- target makes the bike snap between full-left and full-right, which is the
-- single most common reason a Source vehicle feels like a shopping trolley.
-- Ramping the target (not the output) keeps the PD controller honest while
-- giving the rider a continuous input.
--------------------------------------------------------------------------
local LEAN_RATE   = 4.2    -- units of target per second
local LEAN_RETURN = 6.5    -- faster when returning to centre: crisper corner exits
local PITCH_RATE  = 6.0

local function approach(cur, target, rate, dt)
    local d = target - cur
    local step = rate * dt
    if math.abs(d) <= step then return target end
    return cur + step * (d > 0 and 1 or -1)
end

function BMX.SmoothInput(inp, dt)
    local rate = (math.abs(inp.leanTarget) < math.abs(inp.lean)) and LEAN_RETURN or LEAN_RATE
    inp.lean  = approach(inp.lean,  inp.leanTarget,  rate,       dt)
    inp.pitch = approach(inp.pitch, inp.pitchTarget, PITCH_RATE, dt)
end
