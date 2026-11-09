--[[--------------------------------------------------------------------------
    bmx/sv_grind.lua

    Grinding: hop onto a rail or the edge of a ledge, moving roughly along
    it, and the bike locks on and slides until the rail ends, you hop off, or
    it runs out of speed.

        crank grind       a pipe under the middle of the bike, the chainring on
                          it, the bike turned across it so a wheel hangs down
                          either side
        double peg grind  an edge: the bike off the drop side, both pegs on top

    NOTHING IN THE MAP IS MARKED. A rail is found by tracing down round the
    point the bike would grind on: the highest surface in reach is the top;
    if everything round it is that high too it is just the ground, and if the
    ground falls away on BOTH sides within pipeMaxWidth it is a pipe, on ONE
    side an edge. So brush rails, props, kerbs and coping all work, in any map.

    ON THE RAIL THE BIKE IS PLACED, NOT PUSHED. Every substep the rail is found
    again a step further along (which is what follows a curved or sloped rail,
    and what notices it has ended), and the bike's position, angles and
    velocity are set on its physics object. Forces would have to fight the
    contact with the rail and the wheels' suspension, which would be tuning a
    fight rather than modelling a grind; and the grind is an arcade move, so
    it is written as one.

    Config: C.Grind in sh_config.lua.
----------------------------------------------------------------------------]]

BMX = BMX or {}

local abs, min, max, sqrt, floor = math.abs, math.min, math.max, math.sqrt, math.floor
local UP = Vector(0, 0, 1)

-- The names come from the trick registry (sh_tricks.lua).
local NAMES = { crank = BMX.Tricks.crank_grind.name, peg = BMX.Tricks.peg_grind.name }
-- The finder (FindRail, MightBeRail, GrindPose, GrindPoseClear) is shared: sh_railfind.lua.
local locate, perp = BMX.RailLocate, BMX.RailPerp


local function place(ent, phys, g, cfg)
    local pos, ang = BMX.GrindPose(g, cfg)
    phys:SetAngles(ang)
    phys:SetPos(pos)
    phys:SetVelocity(g.dir * g.speed)
    phys:SetAngleVelocity(Vector(0, 0, 0))
end

-- The wheels are off the ground: no load, and they wind down on their
-- bearings the way they do in the air.
local function freeWheels(ent, dt)
    for _, w in ipairs(ent.wheels or {}) do
        w.onGround, w.load, w.slipLong, w.slipLat = false, 0, 0, 0
        w.latForce, w.saturation, w.compression = 0, 0, 0
        w.omega = (w.omega or 0) * (1 - min(0.4 * dt, 0.5))
        w.spinAngle = (w.spinAngle or 0) + w.omega * dt
    end
end

local function code(g)
    if g.kind == "crank" then return 1 end
    return g.localPoint.y > 0 and 2 or 3
end


--------------------------------------------------------------------------
-- Try to lock on. Called each substep while not grinding; true if it did.
--------------------------------------------------------------------------
function BMX.TryGrind(ent, phys, cfg, st, vel)
    local G = cfg.Grind
    if not G or not G.enabled then return false end
    if CurTime() < (st.grindReady or 0) then return false end
    if st.grounded and (st.groundedFor or 0) > G.landedWindow then return false end
    if vel.z > G.maxEntryVz then return false end
    local vh = Vector(vel.x, vel.y, 0)
    if vh:Length() < G.minSpeed then return false end

    -- THE VEHICLE'S GRIND POINTS (`grindPoints` in its registration): the crank
    -- point is where a rail is looked for and what a pipe is ridden on, the pegs
    -- are what an edge is ridden on. A vehicle with none cannot grind at all; one
    -- with only a crank grinds pipes and not edges.
    local gp = BMX.GrindPointsFor(ent.Bike and ent:Bike(), cfg)
    local crank = gp.crank
    if not crank then return false end
    local point = ent:LocalToWorld(crank)
    if not BMX.MightBeRail(point, cfg, ent.traceFilter) then return false end
    local centre = phys:LocalToWorld(phys:GetMassCenter())
    local rail = BMX.FindRail(point, vel, cfg, ent.traceFilter, centre)
    if not rail then return false end

    local along = vel:Dot(rail.dir)
    if along < G.minSpeed then return false end
    local dh = Vector(rail.dir.x, rail.dir.y, 0):GetNormalized()
    if math.acos(BMX.Clamp(vh:GetNormalized():Dot(dh), -1, 1)) > G.maxEntryAngle then
        return false
    end

    -- THE VEHICLE'S OWN MOVES (`grindPoints.moves`: the skateboard's, sv_board_grind.lua).
    -- A function of the rail and the keys that answers with a move -- which point
    -- of the vehicle rides it, how it is turned and pitched, what it is called and
    -- what it pays -- or nothing, in which case there is no grind here.
    local mv
    if gp.moves then
        mv = gp.moves(ent, st, rail, dh, vel)
        if not mv then return false end
    end

    local g = { kind = rail.kind, point = rail.point, dir = rail.dir, n = rail.n,
                side = rail.side, speed = along, started = CurTime() }
    -- Turn the way the bike is already turned off the rail.
    local f0 = ent:GetForward()
    g.yawSide = (dh.x * f0.y - dh.y * f0.x) >= 0 and 1 or -1
    if rail.kind == "crank" then
        if mv then
            g.localPoint = mv.crank
        else
            -- The pipe meets the chainring, or the wheel boxes' floor if that is
            -- lower: the boxes then clear the pipe instead of sitting in it.
            local CH, W = cfg.Chassis, cfg.Wheel
            local floor = CH.wheelHullBottom or -(W.radius - W.restLength)
            g.localPoint = Vector(crank.x, crank.y, math.min(crank.z, floor))
        end
    else
        -- Pegs on the side the top is on; the bike hangs off the other.
        if not gp.pegs and not mv then return false end
        local left = UP:Cross(dh)
        local sgn = left:Dot(rail.side) > 0 and 1 or -1
        if mv then
            g.localPoint = mv.peg(sgn)
        else
            g.localPoint = Vector(0, sgn * gp.pegs.y, gp.pegs.z)
        end
        g.point = g.point + rail.side * G.pegInset
    end
    if mv then
        g.name, g.mult, g.move = mv.name, mv.mult, mv.id
        g.yaw = mv.yaw * (mv.signed and g.yawSide or 1) + (mv.reverse and math.pi or 0)
        g.pitch = mv.pitch
    end
    g.n = perp(dh)

    local pos, ang = BMX.GrindPose(g, cfg)
    if not BMX.GrindPoseClear(pos, ang, cfg, ent.traceFilter) then return false end

    -- Not out of line: a bike part way round a tailwhip or a barspin, or a rider
    -- still in a pose, is no landing on a rail either. It goes on through the air
    -- and is judged where it comes down.
    if st.airMode and BMX.AirFault and BMX.AirFault(st) then return false end

    -- Landed a trick onto it: that trick is paid now, the grind on its own
    -- when it ends.
    if st.airMode then
        st.airMode = false
        local tricks = BMX.ScoreAir(st)
        if #tricks > 0 and ent.AwardTricks then ent:AwardTricks(tricks) end
    end

    ent.bmxTouchdown = nil
    st.airSince = 0
    st.grind = g
    st.grounded = true
    if ent.SetGrind then ent:SetGrind(code(g)) end
    place(ent, phys, g, cfg)
    hook.Run("BMX_GrindStarted", ent, g.kind)
    return true
end

--------------------------------------------------------------------------
-- Off the rail. `why` is "hop", "end", "slow" or "rider".
--------------------------------------------------------------------------
function BMX.EndGrind(ent, phys, cfg, st, why, charge)
    local g = st.grind
    if not g then return end
    local G = cfg.Grind
    st.grind = nil
    if ent.SetGrind then ent:SetGrind(0) end

    local vel = g.dir * max(g.speed, 0)
    if why == "hop" then
        vel = vel + UP * (G.hopSpeed * (charge or 1))
        if g.side then vel = vel - g.side * G.hopAway end
    end
    phys:SetVelocity(vel)
    phys:SetAngleVelocity(Vector(0, 0, 0))
    st.grindExit = { vel = vel, untilT = CurTime() + G.exitGuard }

    st.grindReady = CurTime() + G.cooldown
    st.grindEnded = CurTime()
    st.grounded, st.groundedFor = false, 0
    st.airSince, st.airMode = 0, false
    -- The rate estimates must not differentiate across the grind.
    st.roll, st.pitch = BMX.Attitude(ent, vector_up)
    st.lastRoll, st.lastPitch = st.roll, st.pitch
    st.rollRate, st.pitchRate = 0, 0

    -- A move of its own (g.name, g.mult) pays under its name and at its rate; one
    -- that was lost (g.void: a board's balance) pays nothing.
    local t = CurTime() - g.started
    if t >= G.minTime and ent.AwardTricks and IsValid(ent:GetDriver()) and not g.void then
        ent:AwardTricks({ { name = g.name or NAMES[g.kind], count = 1,
                            points = floor(t * G.pointsPerSec * (g.mult or 1)),
                            grind = t } })     -- seconds on the rail, for BMX (Mode)'s scores
    end
    hook.Run("BMX_GrindEnded", ent, g.kind, why, t)
end

--------------------------------------------------------------------------
-- One substep on the rail.
--------------------------------------------------------------------------
function BMX.GrindStep(ent, phys, cfg, dt, inp, st)
    local g = st.grind
    local G = cfg.Grind
    freeWheels(ent, dt)

    -- Hop off: the jump key, charged or not.
    if ent.hopHeld then
        ent.hopCharge = min(cfg.Hop.chargeTime, (ent.hopCharge or 0) + dt)
    end
    if ent.hopRelease then
        ent.hopRelease, ent.hopHeld = false, false
        -- A tap is enough to get off: the rail is already under the bike, so
        -- there is no preload to wind up, and a quarter hop barely cleared it.
        local charge = max(G.minHop or 0.6, (ent.hopCharge or 0) / cfg.Hop.chargeTime)
        ent.hopCharge = 0
        ent.hopReady = CurTime() + cfg.Hop.cooldown
        return BMX.EndGrind(ent, phys, cfg, st, "hop", charge)
    end

    local brake = max(inp.brakeRear or 0, inp.brakeFront or 0)
    local v = g.speed - physenv.GetGravity():Length() * g.dir.z * dt
        - (G.friction + G.brakeDecel * brake) * dt
    g.speed = v
    if v < G.stopSpeed then return BMX.EndGrind(ent, phys, cfg, st, "slow") end

    local guess = g.point + g.dir * (v * dt)
    local look = g.point
    if g.kind == "peg" then look = g.point - g.side * G.pegInset end
    g.tick = (g.tick or 0) + 1
    local full = g.tick % G.fullEvery == 0
    local p = locate(g, look + g.dir * (v * dt), guess.z, G, ent.traceFilter, not full)
    if not p then return BMX.EndGrind(ent, phys, cfg, st, "end") end
    if g.kind == "peg" then p = p + g.side * G.pegInset end
    -- A rail does not jump. A top found well above or below where this one
    -- was going is something else -- a step, a wall, the ground under the end
    -- of it -- and following it would put the bike inside it.
    if abs(p.z - guess.z) > G.maxStepZ then return BMX.EndGrind(ent, phys, cfg, st, "end") end

    -- Follow the rail round a bend and up or down a slope, smoothly: the
    -- measured line is noisy by a fraction of a unit per step.
    local step = p - g.point
    if step:Length() > 0.25 then
        local d = step:GetNormalized()
        if d:Dot(g.dir) > 0.5 then
            g.dir = (g.dir * 0.75 + d * 0.25):GetNormalized()
            g.n = perp(g.dir)
            if g.side then
                -- Keep `side` pointing onto the top as the edge turns.
                g.side = g.n:Dot(g.side) >= 0 and g.n or -g.n
            end
        end
    end
    local oldPoint, oldDir, oldN, oldSide = g.point, g.dir, g.n, g.side
    g.point = p
    local pos, ang = BMX.GrindPose(g, cfg)
    if not BMX.GrindPoseClear(pos, ang, cfg, ent.traceFilter, g.tick % G.fullEvery ~= 0) then
        -- No room further on: let go from the last pose that had it.
        g.point, g.dir, g.n, g.side = oldPoint, oldDir, oldN, oldSide
        return BMX.EndGrind(ent, phys, cfg, st, "blocked")
    end

    st.speed, st.fwdSpeed = v, v
    st.grindTime = CurTime() - g.started
    place(ent, phys, g, cfg)
end
