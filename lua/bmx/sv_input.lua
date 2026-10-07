--[[--------------------------------------------------------------------------
    bmx/sv_input.lua

    Rider input, read server-side.

    WHY NO net MESSAGES. The obvious design sends lean from the client every
    frame. It is also the wrong one: the usercmd already crosses the wire every
    tick, is already ordered, already rate-limited by the engine, and already
    carries analog axes for gamepads. Reading it in StartCommand server-side
    gets all of that for free and adds zero packets. A net message would only
    add a second, unordered, unvalidated channel saying the same thing.

    THE KEYS ARE DATA (G22). Which usercmd bit each action reads is the vehicle's
    INPUT MAP (BMX.InputMaps, sh_vehicles.lua): `down("sprint")` below asks the
    map which key sprint is on. The list that follows is the `bike` map, the one
    every bike registers with; a vehicle with other controls registers its own,
    and the keybind panel (G19) is generated from the same table.

    CONTROLS. Context-sensitive, the same way GTA's are: W/S and A/D mean
    different things on the ground and in the air, because a rider's hands do.

        W / S            ground: pedal / rear brake
                         air:    nose down / nose up (front flip / back flip)
        A / D            ground: lean, which steers     air: roll
        RMB (hold)       weight BACK: wheelie or manual, works under power
        LMB              front brake, and the weight shift forward that comes
                         with it, which is what makes a stoppie controllable
        LMB + CTRL       the same, leaning forward until CTRL is let go: LMB off
                         with CTRL held is a nose manual (G02, bmx_lmb_mode)
        SPACE            hold to preload, release to bunny hop
        SHIFT            sprint (drains stamina)
        CTRL             tuck (less drag, faster rotation in the air)
        R                the bell, on the ground (sh_bell.lua)

    TRICK KEYS (sv_tricks.lua, sh_tricks.lua; the full list is in the game,
    `bmx_tricks`). The ground and air controls above are untouched.

        LMB + A/D        air: TAILWHIP, the frame round the steer axis
        R                air or manual: BARSPIN (A/D picks the way)
        LMB + R          both at once
        ALT (hold)       in the air, W/S/A/D/RMB/SPACE become POSES, not
                         rotations: no-hander, no-footer, can-can, superman,
                         tabletop, turndown, nothing
        RMB + W          air: X-up
        double-tap W/S   a flip, if bmx_flip_doubletap 1 (off by default)

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

-- A STICK AT REST IS NOT AT ZERO. A worn gamepad sits a few percent off
-- centre, and on this bike a few percent of side axis is a few percent of lean,
-- which is a steady turn the rider never asked for. So each rider's axes go
-- through their own bmx_stick_deadzone (a userinfo convar, cl_hud.lua): inside
-- it is zero, and outside it the rest of the travel is stretched back to 0..1,
-- so there is no jump at its edge and a full stick is still a full command. A
-- keyboard sends 0 or full scale, which it leaves exactly as it was.
local deadzone = BMX.Lean.Deadzone      -- sh_lean.lua: the client's prediction reads its stick the same way
BMX.StickDeadzone = deadzone

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
        whip        = 0,   -- -1..1: tailwhip, the way it turns (0 = not whipping)
        bar         = 0,   -- -1..1: barspin
        pose        = nil, -- a pose name (sh_tricks.lua), or nil
        tuck        = false,
        sprint      = false,
        clutch      = false, -- the clutch lever pulled in (a motorcycle's SHIFT, G15)
        wheelieMod  = false,
        leanFwd     = false, -- weight forward over the bars (LMB + Ctrl, G02)
        noseTrim    = 0,     -- -1..1, W / S: trims a nose manual

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

    -- TEST SEAM. A scripted rider (sv_test.lua's headless harness) writes
    -- bike.input directly, so bail out rather than letting an empty bot usercmd
    -- zero it again every single tick. This is the one line of production code
    -- the harness needs, and it is here rather than in the harness because hook
    -- ordering in GLua is not guaranteed: racing this function is not something
    -- a test should have to win.
    --
    -- Except for auto ride (sh_autoride.lua), which is scripted too: a ride
    -- key freshly pressed ends it first, and is then read below as usual.
    if ply.BMXAutoRide and BMX.AutoRide then BMX.AutoRide.TakeOver(ply, cmd) end
    if ply.BMXScripted then return end

    local buttons = cmd:GetButtons()
    -- THE KEYS COME FROM THE VEHICLE'S INPUT MAP (sh_vehicles.lua), by action
    -- name: down("sprint") asks which key the map binds sprint to and whether it
    -- is held. An action the map does not have is never down, so a vehicle with
    -- the plain map simply has no trick keys, and a key rebinding or a G19
    -- keybind panel is a change to the table, not to this function.
    local map = BMX.InputMapFor(bike)
    local function down(action)
        local a = map.actions[action]
        return a ~= nil and bit.band(buttons, a.key) ~= 0
    end

    local dz   = BMX.Clamp(ply:GetInfoNum("bmx_stick_deadzone", 0.1), 0, 0.9)
    local fwd  = deadzone(axis(cmd:GetForwardMove(), "sv_forwardspeed", 400), dz)
    local side = deadzone(axis(cmd:GetSideMove(),    "sv_sidespeed",    400), dz)

    -- Digital fallback: some clients (and every bot) send buttons with zero
    -- move axes. Without this the bike is unrideable and the cause is invisible.
    if fwd == 0 then
        if down("forward") then fwd = 1 elseif down("back") then fwd = -1 end
    end
    if side == 0 then
        if down("right") then side = 1 elseif down("left") then side = -1 end
    end

    -- G30: THE AGE OF THIS INPUT, for the takeoff decisions (sv_lagcomp.lua). 0
    -- unless bmx_lagcomp is on. Set before the vehicle's own decoder, which
    -- returns below, so the skateboard's ollie sees it too.
    inp.cmdAge = BMX.LagComp and BMX.LagComp.Age(ply, cmd) or 0

    -- A VEHICLE WITH ITS OWN DECODER (the skateboard's: sv_board.lua) reads the keys
    -- itself: a board's W, S, SPACE and the rest mean other things than a bike's.
    if map.decode then return map.decode(ply, bike, cmd, down, fwd, side) end

    inp.sprint     = down("sprint")
    -- THE CLUTCH LEVER (G15), on SHIFT in a motorcycle's map, which has no sprint:
    -- a map without the action is never down, so no other vehicle has a clutch.
    inp.clutch     = down("clutch")
    inp.tuck       = down("tuck")
    inp.wheelieMod = down("weightBack")
    -- THE FRONT BRAKE is the map's `brakeFront` on the GROUND, which a fixie's and
    -- a city bike's map does not list (bike_rearonly: LMB is only a tailwhip,
    -- in the air). A fixie rider can ask for a front brake back with
    -- bmx_fixie_frontbrake 1; the city bike's coaster brake is S and that is all.
    local ba = map.actions.brakeFront
    local frontBrake = ba ~= nil and down("brakeFront")
    if frontBrake then
        local onGround = false
        for _, c in ipairs(ba.ctx) do if c == "ground" then onGround = true end end
        if not onGround and not (BMX.FrontBrakeConVar and BMX.FrontBrakeConVar(bike)) then
            frontBrake = false
        end
    end

    ----------------------------------------------------------------------
    -- LMB: THE FRONT BRAKE, AND WEIGHT FORWARD (G02).
    --
    -- bmx_lmb_mode, a userinfo convar of the rider's own (cl_tricks.lua):
    --
    --   brake (default)  LMB brakes the front wheel, as it always did. LMB with
    --                    Ctrl also leans the rider forward over the bars, and
    --                    the lean STAYS while Ctrl is held: let go of LMB and
    --                    the brake is off with the weight still forward, which
    --                    is what holds a nose manual.
    --   lean             LMB leans the rider forward, the way the competitor's
    --                    does, and brakes nothing; LMB with Ctrl brakes as well
    --                    (a stoppie). Let go of Ctrl with LMB held and the
    --                    brake comes off while the lean stays.
    --
    -- Ctrl alone is still the tuck, and on its own never starts a lean: in
    -- brake mode the latch needs LMB down with it. On the ground only (in the
    -- air LMB is the tailwhip, read below from the raw key).
    ----------------------------------------------------------------------
    local lmb, ctrl = frontBrake, inp.tuck
    local leanMode = ply:GetInfo("bmx_lmb_mode") == "lean"
    local leanFwd
    if leanMode then
        inp.brakeFront = (lmb and ctrl) and 1 or 0
        leanFwd = lmb
    else
        inp.brakeFront = lmb and 1 or 0
        if lmb and ctrl then inp.leanLatch = true end
        if not ctrl then inp.leanLatch = false end
        leanFwd = inp.leanLatch
    end

    -- Follow the DEBOUNCED air mode, not raw ground contact. Two reasons: the
    -- networked Grounded flag is a 20 Hz copy of something that changes at
    -- physics rate, and raw contact flickers over every kerb. Reading st.airMode
    -- server-side is both current and already debounced, so the controls do not
    -- reinterpret themselves for one tick every time you ride over a bump.
    local airborne = bike.st and bike.st.airMode or false

    inp.leanTarget = side

    ----------------------------------------------------------------------
    -- A KEY HELD INTO THE AIR IS NOT A FLIP COMMAND.
    --
    -- In the air W/S become rotation, so a rider holding W to keep pedalling
    -- through a bunny hop was, from the moment the wheels left the ground,
    -- commanding a front flip, and nose-dived into the landing. Whatever the
    -- forward axis says at takeoff is latched and ignored until it changes:
    -- let go of W (or press S) and the air controls are live. A fresh press
    -- in the air still flips exactly as before.
    ----------------------------------------------------------------------
    local fsign = fwd > 0.1 and 1 or (fwd < -0.1 and -1 or 0)
    -- The key held on the LAST GROUND COMMAND is the one carried over; a key
    -- first pressed in the air, even on the first airborne tick, is fresh.
    --
    -- A/D THE SAME WAY. On the ground they lean, which is how you steer, so a
    -- rider carving up a ramp is holding one at the lip -- and in the air A/D
    -- are ROLL. Unlatched, the steer became a barrel-roll command on the
    -- takeoff tick and the bike rolled onto its side before it came down
    -- (live, 2026-10-07: 27 -> 77 degrees in half a second, A held off a
    -- ramp). Held at takeoff it is ignored until let go; a fresh press rolls.
    local ssign = side > 0.1 and 1 or (side < -0.1 and -1 or 0)
    if airborne and not inp.wasAirborne then
        local held = inp.groundFwd or 0
        inp.airLatch = (held ~= 0 and held == fsign) and held or nil
        local heldS = inp.groundSide or 0
        inp.airLatchSide = (heldS ~= 0 and heldS == ssign) and heldS or nil
    end
    if inp.airLatch and fsign ~= inp.airLatch then inp.airLatch = nil end
    if inp.airLatchSide and ssign ~= inp.airLatchSide then inp.airLatchSide = nil end
    if not airborne then
        inp.groundFwd, inp.groundSide = fsign, ssign
        inp.airLatchSide = nil
    end
    inp.wasAirborne = airborne
    if airborne and inp.airLatch then fwd = 0 end
    if airborne and inp.airLatchSide then side = 0 end

    ----------------------------------------------------------------------
    -- TRICK KEYS: frame and bar spins, and style poses (sv_tricks.lua).
    --
    -- They TAKE their keys from the rotation controls, so a key that spins
    -- the bike is never also a trick: A/D under a whip or a barspin are the
    -- way to turn it, not a roll; with Alt down W/S/A/D are a pose, not a
    -- flip. RMB + A/D (the 360) and Ctrl (tuck) are left alone.
    ----------------------------------------------------------------------
    local manual = (not airborne) and bike.st and bike.st.manual ~= nil
    local sdir = side > 0.1 and 1 or (side < -0.1 and -1 or 0)
    inp.whip, inp.bar, inp.pose = 0, 0, nil
    if airborne or manual then
        local alt = down("alt")
        inp.poseMod = alt
        local wKey = fwd > 0.1  or (down("forward") and inp.airLatch ~= 1)
        local sKey = fwd < -0.1 or (down("back")    and inp.airLatch ~= -1)
        inp.pose = BMX.DecodePose({ alt = alt, rmb = inp.wheelieMod, fwd = wKey, back = sKey,
            side = sdir, jump = down("hop"), air = airborne, manual = manual,
            moto = bike:Bike().family == "moto" })
        if inp.pose and airborne then
            -- Hands are busy: no flip, no roll, no 360 under a pose.
            fwd, side = 0, 0
            inp.wheelieMod = false
        elseif airborne then
            local lmb, rKey = down("brakeFront"), down("bar")
            if lmb and rKey then
                local w = sdir ~= 0 and sdir or 1
                inp.whip, inp.bar = w, w
            elseif lmb and sdir ~= 0 then
                inp.whip = sdir
            elseif rKey then
                inp.bar = sdir ~= 0 and sdir or 1
            end
            if inp.whip ~= 0 or inp.bar ~= 0 then side = 0 end
        elseif manual and down("bar") then
            inp.bar = sdir ~= 0 and sdir or 1       -- a barspin in a manual
        end
    else
        inp.poseMod = false
    end

    ----------------------------------------------------------------------
    -- DOUBLE-TAP FLIP, an option (bmx_flip_doubletap 1; a userinfo convar,
    -- cl_tricks.lua). Two presses of W, or of S, inside a window command a
    -- flip that stops by itself near a full turn; holding the key still
    -- rotates as it always did, which is the better way to learn the bike.
    ----------------------------------------------------------------------
    if not airborne then
        inp.autoFlip, inp.tapSign, inp.lastF = nil, nil, 0
    elseif ply:GetInfoNum("bmx_flip_doubletap", 0) > 0 then
        local f = fwd > 0.1 and 1 or (fwd < -0.1 and -1 or 0)
        local K = bike:Cfg().Tricks
        if f ~= 0 and f ~= (inp.lastF or 0) then
            local now = CurTime()
            if inp.tapSign == f and now - (inp.tapTime or -1e9) <= K.doubleTapWindow then
                inp.autoFlip, inp.autoBase, inp.tapSign = f, bike.st and bike.st.spinPitch or 0, nil
            else
                inp.tapSign, inp.tapTime = f, now
            end
        end
        inp.lastF = f
        if inp.autoFlip then
            -- Let go once the coast will do the rest: the spin so far, plus
            -- the w / damping that the air will still carry it.
            local st = bike.st or {}
            local spun = math.abs((st.spinPitch or 0) - (inp.autoBase or 0))
            local w = st.angVel and st.angVel:Dot(bike:GetRight()) or 0
            local coast = math.abs(w) / bike:Cfg().Air.damping
            if spun + coast >= K.doubleTapTurn or inp.pose then inp.autoFlip = nil end
        end
    else
        inp.autoFlip = nil
    end

    inp.leanTarget = side
    -- Weight forward is a ground thing, and RMB (weight back) wins over it.
    inp.leanFwd = (leanFwd and not airborne and not inp.wheelieMod) and true or false
    -- W / S trim a nose manual (PitchControl): W leans further over, S sits up.
    inp.noseTrim = airborne and 0 or fwd

    -- THE BELL: R (IN_RELOAD), a fresh press, on the ground and out of a
    -- manual. R is also the barspin key in the air and in a manual (G03), so
    -- the bell takes only what that leaves -- and ALL of what that leaves:
    -- whatever else is held (RMB in a wheelie, W, Shift), R on the ground rings.
    -- It used to be swallowed while RMB was down and no manual had started yet,
    -- neither a ring nor a barspin, which played as a key that did nothing. A
    -- press that began in the air and is still held on landing is not a ring
    -- (ringHeld). See sh_bell.lua.
    local ringKey = down("bar")
    if ringKey and not inp.ringHeld and not airborne
        and not (bike.st and bike.st.manual) and BMX.Bell then
        BMX.Bell.Ring(bike)
    end
    inp.ringHeld = ringKey

    if airborne then
        ------------------------------------------------------------------
        -- In the air there is no drivetrain to worry about, so W/S become
        -- rotation.
        --
        -- NOTE THE SIGN. pitchTarget > 0 is NOSE UP, and pushing forward on a
        -- bike in the air puts the nose DOWN, so W has to negate. GTA maps it
        -- the same way (stick forward = frontflip) and it is what a rider's
        -- hands actually do. Getting this backwards costs nothing at load and
        -- makes every flip feel wrong in a way that is hard to name.
        ------------------------------------------------------------------
        inp.throttle    = 0
        inp.brakeRear   = 0
        inp.pitchTarget = inp.autoFlip and -inp.autoFlip or -fwd
    else
        inp.throttle  = math.max(fwd, 0)
        inp.brakeRear = math.max(-fwd, 0)

        ------------------------------------------------------------------
        -- Ground weight shift. Two rider actions, two keys, no new bindings:
        --
        --   RMB          weight BACK. Combined with W this is a wheelie under
        --                power, which is how a wheelie actually works; with S
        --                it is a manual rolling into a skid.
        --   front brake  weight FORWARD, automatically. A rider grabbing the
        --                front brake comes forward over the bars whether they
        --                mean to or not, and modelling that is what makes a
        --                stoppie controllable rather than an accident.
        ------------------------------------------------------------------
        --   lean forward with the brake off holds the weight over the bars
        --                (-0.35, a lean: the pitch controller's nose manual,
        --                bmx_nose_manual) and does nothing at all when that is off.
        if inp.wheelieMod then
            inp.pitchTarget = 1
        elseif inp.brakeFront > 0.5 then
            inp.pitchTarget = -0.6
        elseif inp.leanFwd and BMX.NoseManualOn and BMX.NoseManualOn() then
            inp.pitchTarget = -0.35
        else
            inp.pitchTarget = 0
        end
    end

    -- Bunny hop: edge-triggered on release, so the press starts a preload and
    -- the release spends it. Holding SPACE forever must not hop.
    local jump = down("hop")
    if jump and not inp.hop then
        bike.hopCharge = 0
        bike.hopHeld   = true
    elseif not jump and inp.hop then
        bike.hopRelease = true
        bike.hopReleaseAge = inp.cmdAge     -- G30: how old the release is (0 off)
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
-- The arithmetic (rates, approach) lives in sh_lean.lua so the client's prediction
-- shares it (G30); this is the same function it always was.
function BMX.SmoothInput(inp, dt)
    inp.lean  = BMX.Lean.StepLean(inp.lean, inp.leanTarget, dt)
    inp.pitch = BMX.Lean.Approach(inp.pitch, inp.pitchTarget, BMX.Lean.PITCH_RATE, dt)
end
