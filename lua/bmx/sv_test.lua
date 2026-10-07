--[[--------------------------------------------------------------------------
    bmx/sv_test.lua

    A headless regression harness. No client, no GPU, no human.

    WHY THIS IS POSSIBLE AT ALL. A dedicated server runs the entire simulation:
    PhysicsSimulate fires whether or not anyone is watching. The only thing
    missing is a rider, and a rider is just a Player, so the harness makes a bot,
    seats it, and drives it. Everything from input smoothing downwards -- the
    tyre model, the balance PD, the derived steering, air mode, crashes -- is
    then under test on a box with no graphics hardware.

    WHERE IT PLUGS IN. The harness writes `bike.input` directly, which is the
    same table StartCommand fills for a human. So the seam is one layer below the
    usercmd: everything downstream is covered, and the only thing NOT covered is
    the usercmd decode itself (which keys map to which fields). That is a
    deliberate trade -- injecting usercmds would mean winning a hook-ordering
    race every tick, and a test that has to win a race is not a test.

    WHAT IT CANNOT COVER, stated plainly so nobody trusts a green run too far:
    cl_view.lua, cl_hud.lua and the wheel drawing never execute on a dedicated
    server, and neither does feel. This suite catches regressions. It cannot tell
    you the bike is fun.

    RUN IT:
        bmx_test              every case
        bmx_test lean_turns   one case
    Results print to console and land in data/bmx_test_results.txt.
    With bmx_test_quit 1 the server exits when the run finishes, which is what
    makes this usable from CI.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Test = BMX.Test or {}

local T = BMX.Test
T.cases = T.cases or {}
T.order = T.order or {}

local BOT_NAME = "BMXTestBot"

CreateConVar("bmx_test_quit", "0", FCVAR_PROTECTED,
    "Shut the server down when a test run finishes. For CI.")
CreateConVar("bmx_test_onboot", "0", FCVAR_PROTECTED,
    "Run the suite automatically once the map has settled.")

--------------------------------------------------------------------------
-- Registration
--------------------------------------------------------------------------
function T.Case(name, opts, fn)
    if isfunction(opts) then fn, opts = opts, {} end
    opts = opts or {}
    if not T.cases[name] then T.order[#T.order + 1] = name end
    T.cases[name] = {
        name    = name,
        fn      = fn,
        rider   = opts.rider ~= false,   -- seat the bot unless told not to
        -- Set by a case that deliberately destroys its own bike. Without it the
        -- universal check below reads an intentional removal as the symptom of
        -- a NaN, which is the one thing it is there to catch.
        removesBike = opts.removesBike or false,
        timeout = opts.timeout or 40,
        desc    = opts.desc or "",
        -- WORK IN PROGRESS: written, not passing yet. The full run lists it
        -- and does not run it, so main stays green for everyone else while
        -- it is worked on; by name or prefix (bmx_test bot_*) it runs.
        wip     = opts.wip or false,
        -- Which bike the case rides: a registry id, the stock bike if omitted.
        -- Cases read the bike's numbers through ctx.cfg, never BMX.Config, so
        -- the same case means the same thing on a bike with other geometry.
        bike    = opts.bike or "stock",
        -- A vehicle that is not a bike, by registry id (setupCase). Nil for every
        -- case that rides a bike.
        vehicle = opts.vehicle,
    }
end

-- Run an existing case again on another bike, as "<case>@<bike>". The case
-- body is shared, so a shipped bike is held to exactly the bands the stock one
-- is -- or the band is wrong for it, which is worth finding out on purpose.
function T.Variant(name, bike, opts)
    local base = T.cases[name]
    if not base then error("T.Variant: no case " .. tostring(name)) end
    opts = opts or {}
    T.Case(name .. "@" .. bike, {
        rider = base.rider, removesBike = base.removesBike,
        timeout = opts.timeout or base.timeout,
        desc = base.desc .. " (on the " .. bike .. " bike)",
        bike = bike,
    }, base.fn)
end

-- A solid convex shape for a case to ride into, as a bmx_test_solid carrying
-- hulls (entities/bmx_test_solid/shared.lua, CustomHulls). Each hull is a list
-- of world-space points. Removed with the case, pass or fail.
function T.Solid(ctx, hulls)
    local e = ents.Create("bmx_test_solid")
    if not IsValid(e) then return nil end
    local lo, hi = Vector(math.huge, math.huge, math.huge), Vector(-math.huge, -math.huge, -math.huge)
    for _, h in ipairs(hulls) do
        for _, p in ipairs(h) do
            lo = Vector(math.min(lo.x, p.x), math.min(lo.y, p.y), math.min(lo.z, p.z))
            hi = Vector(math.max(hi.x, p.x), math.max(hi.y, p.y), math.max(hi.z, p.z))
        end
    end
    e.CustomHulls = hulls
    e:SetPos((lo + hi) * 0.5)
    e:Spawn()
    ctx.solids = ctx.solids or {}
    ctx.solids[#ctx.solids + 1] = e
    return e
end

-- Set a server convar for the length of a case and give it back after, however
-- the case ends: teardown runs the undo even when the case threw. Applied to
-- the config at once (BMX.ApplyConVars), not at the next 20 Hz tick.
function T.ConVar(ctx, name, value)
    local cv = GetConVar(name)
    if not cv then error("T.ConVar: no convar " .. tostring(name)) end
    local old = cv:GetString()
    ctx.undo = ctx.undo or {}
    ctx.undo[#ctx.undo + 1] = function() cv:SetString(old) BMX.ApplyConVars() end
    cv:SetString(tostring(value))
    BMX.ApplyConVars()
end

--------------------------------------------------------------------------
-- World setup
--------------------------------------------------------------------------

-- Find ground to test on.
--
-- ORIGINALLY this demanded near-perfect flatness (HitNormal.z >= 0.99, spread
-- under 2 units) and REFUSED to run otherwise. On the first live run it
-- rejected every candidate on **gm_flatgrass** -- the flattest map that ships
-- with the game -- and failed all eleven cases with "no flat ground found".
--
-- The reason is that flatgrass's ground is a DISPLACEMENT, not a brush face.
-- Displacements carry small per-vertex normal variation by construction, so
-- 0.99 is a threshold almost no real map surface meets. The lesson generalises:
-- a precondition strict enough to reject the best case you have is a bug in the
-- precondition, not a property of the world.
--
-- So now: tolerate real ground, prefer the flattest candidate, and if nothing
-- is properly flat still RETURN somewhere and say so, because a suite that
-- refuses to run tells you nothing at all.
--
-- Returns: position, flatness note (nil when genuinely flat).
local MAX_SLOPE_COS = 0.95   -- ~18 degrees; displacement noise is far below this
local MAX_SPREAD    = 8      -- units of height variation across the sample

-- How far a case may need to travel. Cases accelerate along +X, and a bike that
-- reaches its design terminal speed of ~310 u/s covers ground fast: the
-- brake case wants 230 u/s and then a stopping distance on top.
--
-- THIS IS MEASURED NOW BECAUSE IT USED TO BE FREE. The original note here said
-- an acceleration run travels about 1,200 units, and that was true -- while a
-- tyre bug held the bike to a third of its speed. The moment that was fixed,
-- runs went off the edge of the flat area at 1,310 units and four cases started
-- measuring lean and steering on a bike in free fall.
local WANT_RUNWAY = 2200
local RUNWAY_STEP = 100

-- How far ground continues in +X from `from`, up to WANT_RUNWAY.
local function runwayFrom(from)
    for d = RUNWAY_STEP, WANT_RUNWAY, RUNWAY_STEP do
        local p  = from + Vector(d, 0, 96)
        local tr = util.TraceLine({
            start = p, endpos = p - Vector(0, 0, 700), mask = MASK_SOLID,
        })
        if not tr.Hit then return d - RUNWAY_STEP end
    end
    return WANT_RUNWAY
end

local function findTestGround()
    local candidates = {}
    for _, c in ipairs({ "info_player_start", "info_player_deathmatch",
                         "info_player_terrorist", "gmod_player_start" }) do
        for _, e in ipairs(ents.FindByClass(c)) do
            candidates[#candidates + 1] = e:GetPos()
        end
    end
    candidates[#candidates + 1] = Vector(0, 0, 128)   -- last resort: world origin

    -- A 400-unit cross. An acceleration run travels ~1200 units, so this is a
    -- "did we spawn on a hill" check, not a track survey.
    local CROSS = { Vector(0, 0, 0), Vector(200, 0, 0), Vector(-200, 0, 0),
                    Vector(0, 200, 0), Vector(0, -200, 0) }

    local best, bestSpread = nil, math.huge
    local bestRunway, bestRunwayAt = -1, nil

    for _, base in ipairs(candidates) do
        for _, off in ipairs({ Vector(0, 0, 0), Vector(300, 0, 0), Vector(-300, 0, 0) }) do
            local centre, hits, ok = base + off, {}, true

            for _, corner in ipairs(CROSS) do
                local p = centre + corner + Vector(0, 0, 96)
                local tr = util.TraceLine({
                    start = p, endpos = p - Vector(0, 0, 700), mask = MASK_SOLID,
                })
                if not tr.Hit or tr.HitNormal.z < MAX_SLOPE_COS then ok = false break end
                hits[#hits + 1] = tr.HitPos
            end

            if ok and #hits == #CROSS then
                local lo, hi = math.huge, -math.huge
                for _, h in ipairs(hits) do lo = math.min(lo, h.z); hi = math.max(hi, h.z) end
                local spread = hi - lo
                if spread < bestSpread then
                    best, bestSpread = hits[1], spread   -- hits[1] is the centre
                end
                -- Flat AND long enough to ride down. Flatness alone was the old
                -- test, and it happily picked a billiard table 1,300 units from
                -- a cliff.
                if spread <= MAX_SPREAD then
                    local runway = runwayFrom(hits[1])
                    if runway >= WANT_RUNWAY then return hits[1], nil, runway end
                    if runway > bestRunway then
                        bestRunway, bestRunwayAt = runway, hits[1]
                    end
                end
            end
        end
    end

    -- Nothing had the full runway. Take the longest one that was at least flat,
    -- and SAY SO, because a short runway is the difference between "the balance
    -- controller is broken" and "the bike ran out of world". Still returning
    -- somewhere is deliberate: a suite that refuses to run tells you nothing,
    -- which is the lesson the flatness threshold above already taught once.
    if bestRunwayAt then
        return bestRunwayAt, string.format(
            "only %d units of runway (want %d): the fast cases will run out of " ..
            "ground before they finish", bestRunway, WANT_RUNWAY), bestRunway
    end

    if best then
        return best, string.format(
            "ground is not level: %.1f units of variation across 400u", bestSpread),
            runwayFrom(best)
    end
    return nil, "no ground found under any spawn point"
end

local function ensureBot()
    for _, p in ipairs(player.GetAll()) do
        if p:IsBot() and p:Nick() == BOT_NAME then return p end
    end
    if #player.GetAll() >= game.MaxPlayers() then return nil, "no free player slot" end
    local b = player.CreateNextBot(BOT_NAME)
    if not IsValid(b) then return nil, "player.CreateNextBot returned nothing" end
    return b
end

--------------------------------------------------------------------------
-- The context handed to each case
--------------------------------------------------------------------------
local Ctx = {}
Ctx.__index = Ctx

function Ctx:log(msg)
    self.lines[#self.lines + 1] = "      " .. msg
end

function Ctx:ok(cond, msg)
    self.checks[#self.checks + 1] = { pass = cond and true or false, msg = msg }
    if not cond then self.failed = true end
    return cond and true or false
end

-- The workhorse assertion. Reports the ACTUAL value on both pass and fail,
-- because a passing test whose number sits right at the edge of its band is
-- information you want before it starts failing.
function Ctx:between(v, lo, hi, label, unit)
    unit = unit and (" " .. unit) or ""
    local pass = isnumber(v) and v == v and v >= lo and v <= hi
    self.checks[#self.checks + 1] = {
        pass = pass,
        msg = string.format("%s = %s%s  (expected %g..%g%s)",
            label, isnumber(v) and string.format("%.2f", v) or tostring(v),
            unit, lo, hi, unit),
    }
    if not pass then self.failed = true end
    return pass
end

function Ctx:wait(seconds)
    local until_ = CurTime() + seconds
    while CurTime() < until_ do coroutine.yield() end
end

-- Wait for a predicate, or give up. Returns whether it came true, so a case can
-- assert on the timeout rather than silently carrying on with bad state.
function Ctx:waitUntil(fn, timeout, label)
    local deadline = CurTime() + (timeout or 10)
    while CurTime() < deadline do
        if fn() then return true end
        coroutine.yield()
    end
    self:ok(false, "timed out waiting for " .. (label or "condition"))
    return false
end

-- Write the same fields StartCommand would. Anything omitted is zeroed, so a
-- case cannot leak a held brake into the step after it.
function Ctx:input(t)
    t = t or {}
    local i = self.bike.input
    i.throttle    = t.throttle    or 0
    i.brakeRear   = t.brakeRear   or 0
    i.brakeFront  = t.brakeFront  or 0
    i.leanTarget  = t.lean        or 0
    i.pitchTarget = t.pitch       or 0
    i.tuck        = t.tuck        or false
    i.sprint      = t.sprint      or false
    i.wheelieMod  = t.wheelieMod  or false
    -- Weight forward and the nose manual's trim (G02, sv_input.lua).
    i.leanFwd     = t.leanFwd     or false
    i.noseTrim    = t.noseTrim    or 0
    -- The clutch lever (a motorcycle's SHIFT, G15).
    i.clutch      = t.clutch      or false
end

function Ctx:st() return self.bike.st end

function Ctx:wheels()
    local f, r
    for _, w in ipairs(self.bike.wheels) do
        if w.isFront then f = w else r = w end
    end
    return f, r
end

-- Hold an input and step until `fn` says stop, the time runs out, or the bike
-- leaves the ground for good. Returns whether it was still on the ground at the
-- end, which is the precondition for every measurement a ground case takes.
--
-- A wheel unloads for a substep or two over any real bump, which is why air
-- mode has a debounce; half a second of no contact at all is a bike that has
-- left the world, not a bike on a kerb.
-- Look this far ahead of the bike for ground. About a second of travel at the
-- design terminal speed, which is enough warning to stop on our own terms.
local LOOKAHEAD = 320

function Ctx:runUntil(seconds, fn, input)
    if input then self:input(input) end

    local deadline = CurTime() + seconds
    local airborneSince = nil
    self.stoppedAtEdge = false

    while CurTime() < deadline do
        if not self.bike.st.grounded then
            airborneSince = airborneSince or CurTime()
            if CurTime() - airborneSince > 0.5 then return false end
        else
            airborneSince = nil

            -- STOP BEFORE THE EDGE, not at it. findTestGround measures runway
            -- as a straight line in +X from the spawn point, and that is
            -- optimistic in exactly the way a straight line always is: the bike
            -- drifts, and a turning case leaves the line entirely. Asking the
            -- world what is under the bike RIGHT NOW, one second ahead, needs no
            -- prediction and cannot be wrong about the path actually taken.
            local ahead = self.bike:GetPos() + self.bike:GetForward() * LOOKAHEAD
            local tr = util.TraceLine({
                start  = ahead + Vector(0, 0, 32),
                endpos = ahead - Vector(0, 0, 400),
                filter = self.bike.traceFilter,
                mask   = MASK_SOLID,
            })
            if not tr.Hit then
                self.stoppedAtEdge = true
                self:input({})
                return true
            end
        end

        if fn and fn() then return true end
        coroutine.yield()
    end
    return true
end

-- Get up to speed, because half the cases need to start from there.
--
-- IT MUST FAIL IF THE BIKE LEAVES THE WORLD, and that is not a hypothetical.
-- `st.speed` is the magnitude of the whole velocity vector, so a bike falling
-- down a pit reports a speed that climbs forever and passes any target you name.
-- The test ground on gm_flatgrass runs out about 1,300 units from the spawn
-- point, an accelerating bike covers that in eight seconds, and every case that
-- called this then measured lean, steering and pitch on a bike in free fall:
-- four failures, all reported against the controller, none of them its fault.
--
-- Worse, it USED to be true that this could not happen -- the note in
-- findTestGround still says an acceleration run travels about 1,200 units, which
-- it did back when a tyre bug capped the bike at a third of its speed. An
-- assumption that was safe only because something else was broken is the kind
-- that comes due the moment you fix the other thing.
function Ctx:accelerateTo(speed, timeout)
    local hit = false
    local grounded = self:runUntil(timeout or 12, function()
        hit = self.bike.st.speed >= speed
        return hit
    end, { throttle = 1 })

    if not grounded then
        self:ok(false, string.format(
            "the bike left the ground before reaching %d u/s -- it has run out " ..
            "of test ground, so nothing measured after this would mean anything",
            speed))
        return false
    end
    if not hit then
        self:ok(false, string.format("timed out waiting for speed >= %d u/s", speed))
        return false
    end
    return true
end

function Ctx:hop()
    self.bike.hopHeld   = true
    self.bike.hopCharge = 0
    self:wait(self.bike:Cfg().Hop.chargeTime + 0.05)
    self.bike.hopRelease = true
end

--------------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------------
local run = nil

local function teardown(ctx)
    if ctx then
        if IsValid(ctx.bot) and IsValid(ctx.bot:GetVehicle()) then
            ctx.bot:ExitVehicle()
        end
        if IsValid(ctx.bike) then SafeRemoveEntity(ctx.bike) end
        -- Terrain a case built (T.Solid): it stays only as long as its case.
        for _, e in ipairs(ctx.solids or {}) do SafeRemoveEntity(e) end
        ctx.solids = nil
        -- A case that turned a server convar for its duration gets it back
        -- even when it threw (T.ConVar).
        for _, undo in ipairs(ctx.undo or {}) do pcall(undo) end
        ctx.undo = nil
    end
end

local function setupCase(case)
    local ground, groundNote, runway = findTestGround()
    if not ground then
        return nil, (groundNote or "no ground") .. " on " .. game.GetMap()
    end

    -- `vehicle` is a case that rides something that is not a bike (the test
    -- cart); `bike` stays the stock id for every case that is not a variant, which
    -- the suite's own bookkeeping checks.
    local vid = case.vehicle or case.bike
    local class = BMX.ClassFor(vid)
    if not class then return nil, "no such vehicle: " .. tostring(vid) end
    local bike = ents.Create(class)
    if not IsValid(bike) then return nil, "could not create " .. class end
    -- Spawn at the bike's ACTUAL resting height, computed rather than guessed:
    -- the origin sits on the design axle line, so at rest it is one radius up
    -- minus the static sag, and the sag is m*g/2 divided by the spring rate.
    --
    -- The previous version used radius + 1, which was 4 units above equilibrium
    -- once the spring was retuned, and dropping the bike that far produced a
    -- transient big enough to fail cases that were measuring something else
    -- entirely. Deriving it means a future spring change cannot silently
    -- reintroduce that.
    --
    -- The weight is shared by ALL the wheels (a bike's two give the 0.5 this
    -- always was; the four of a cart a quarter).
    local def = BMX.Vehicles[vid]
    local cfg = BMX.ConfigFor(def)
    local WC  = cfg.Wheel
    local sag = (cfg.Chassis.mass * physenv.GetGravity():Length() / #BMX.WheelDefs(def, cfg))
        / WC.spring
    bike:SetPos(ground + Vector(0, 0, WC.radius - sag + 1))
    bike:SetAngles(Angle(0, 0, 0))
    bike:Spawn()
    bike:Activate()

    local ctx = setmetatable({
        bike = bike, checks = {}, lines = {}, failed = false,
        cfg = bike:Cfg(),
        ground = ground,
        -- How far this spot can be ridden before the world runs out, minus a
        -- margin so a case stops on its own terms rather than off a cliff.
        runway = math.max((runway or 0) - 250, 0),
    }, Ctx)

    -- Not fatal, but every number below assumes level ground, so say it out
    -- loud in the results rather than letting a slope masquerade as a tuning
    -- problem.
    if groundNote then ctx:log("WARNING: " .. groundNote) end

    -- THE BOT IS A PLAYER, and a player standing beside a parked bike
    -- releases its hold (see 7c in sv_physics.lua), by design. A riderless
    -- case used to find the bot wherever the previous case had left it --
    -- on this same patch of ground -- and parked_on_stand measured the bot
    -- leaning on its bike (4.6 u of drift, against 0.02 with nobody near).
    if not case.rider then
        for _, p in ipairs(player.GetAll()) do
            if p:IsBot() and p:Nick() == BOT_NAME then
                if IsValid(p:GetVehicle()) then p:ExitVehicle() end
                p:SetPos(ground + Vector(-600, 0, 16))
            end
        end
    end

    if case.rider then
        local bot, err = ensureBot()
        if not bot then
            SafeRemoveEntity(bike)
            return nil, "bot: " .. tostring(err)
        end
        ctx.bot = bot

        -- The seam. sv_input.lua bails out for a scripted rider so an empty bot
        -- usercmd cannot zero what this harness just wrote.
        bot.BMXScripted = true

        bot:SetPos(ground + Vector(64, 0, 8))
        bot:EnterVehicle(bike:GetPod())

        if bike:GetDriver() ~= bot then
            SafeRemoveEntity(bike)
            return nil, "bot did not take the seat (EnterVehicle had no effect)"
        end
    end

    ctx:input({})
    return ctx
end

-- Every case ends with this. A NaN inside a PhysObj is unrecoverable and its
-- symptoms (a vanished entity, or an entire map's physics going still) look
-- nothing like their cause, so it is checked after every single case rather
-- than being its own test that might not run.
local function finiteCheck(ctx, case)
    local b = ctx.bike
    if not IsValid(b) then
        -- A vanished bike is normally the SYMPTOM this check exists for: a NaN
        -- inside a PhysObj takes the entity with it and looks nothing like its
        -- cause. But a case that says up front that it removes its own bike has
        -- not found a NaN, it has finished, and there is nothing left to
        -- inspect.
        if not (case and case.removesBike) then
            ctx:ok(false, "bike entity did not survive the case")
        end
        return
    end
    local phys = b:GetPhysicsObject()
    local okPos = BMX.FiniteVec(b:GetPos())
    local okVel = IsValid(phys) and BMX.FiniteVec(phys:GetVelocity()) or false
    local a = b:GetAngles()
    local okAng = BMX.Finite(a.p) and BMX.Finite(a.y) and BMX.Finite(a.r)
    ctx:ok(okPos and okVel and okAng, "no NaN in position, velocity or angles")
end

local function report()
    local lines = { "", "=== BMX headless test results ===",
        os.date("%Y-%m-%d %H:%M:%S") .. "   map " .. game.GetMap() ..
        "   tickrate " .. math.Round(1 / engine.TickInterval()) }
    lines[#lines + 1] = ""

    local passed, failed = 0, 0
    for _, r in ipairs(run.results) do
        local tag = r.failed and "FAIL" or "PASS"
        if r.failed then failed = failed + 1 else passed = passed + 1 end
        lines[#lines + 1] = string.format("[%s] %s", tag, r.name)
        if r.error then lines[#lines + 1] = "      ERROR: " .. r.error end
        for _, l in ipairs(r.lines or {}) do lines[#lines + 1] = l end
        for _, c in ipairs(r.checks or {}) do
            lines[#lines + 1] = string.format("      %s %s", c.pass and " ok " or "FAIL", c.msg)
        end
    end

    for _, n in ipairs(run.skipped or {}) do
        lines[#lines + 1] = string.format("[WIP ] %s  (work in progress: not run; bmx_test %s)", n, n)
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("%d passed, %d failed, %d total",
        passed, failed, passed + failed) ..
        ((run.skipped and #run.skipped > 0) and string.format(", %d in progress", #run.skipped) or "")
    -- The tickrate belongs in the summary, not just the header: these numbers
    -- are only comparable against runs at the same physics substep rate.
    lines[#lines + 1] = ""

    local txt = table.concat(lines, "\n")
    for _, l in ipairs(lines) do MsgN(l) end
    file.Write("bmx_test_results.txt", txt)

    return failed
end

local function advance()
    if not run then return end

    -- Start the next case
    if not run.co then
        local name = run.queue[run.idx]
        if not name then
            -- pcall: a throw in report() used to abort advance() BEFORE `run`
            -- was cleared, leaving the runner permanently "in progress" with
            -- the results it had just finished computing thrown away. The
            -- reporting step must never be able to lose the run it is
            -- reporting on.
            local rok, failed = pcall(report)
            if not rok then
                ErrorNoHalt("[BMX] report() failed: " .. tostring(failed) .. "\n")
                failed = -1
            end
            run = nil
            if GetConVar("bmx_test_quit"):GetBool() then
                timer.Simple(1, function()
                    MsgN("[BMX] bmx_test_quit is set -- shutting down (" ..
                        failed .. " failures)")
                    game.ConsoleCommand("quit\n")
                end)
            end
            hook.Remove("Think", "BMX.TestRunner")
            return
        end

        -- NOT WHILE THE RIDER IS STILL TUMBLING from the last case's crash:
        -- the tumble ends by respawning the player (sv_seat.lua), which
        -- throws them off whatever the next case has just sat them on.
        for _, p in ipairs(player.GetAll()) do
            if p:IsBot() and p:Nick() == BOT_NAME and p.BMXTumbling then return end
        end

        local case = T.cases[name]
        MsgN("[BMX] running " .. name)

        -- pcall, because setupCase touches entity code that can THROW, and an
        -- uncaught error here does not fail the case: it aborts advance()
        -- before run.idx is incremented, so the Think hook re-enters the same
        -- case forever. The run then looks "in progress" indefinitely with no
        -- bike, no bot and no results, which is exactly how the first live run
        -- of this suite behaved. A test harness that can hang on a bug in the
        -- thing it is testing is not a harness.
        local pok, ctx, err = pcall(setupCase, case)
        if not pok then
            ctx, err = nil, "setup threw: " .. tostring(ctx)
        end

        if not ctx then
            run.results[#run.results + 1] =
                { name = name, failed = true, error = err, checks = {} }
            run.idx = run.idx + 1
            return
        end

        run.ctx = ctx
        run.case = case
        -- Progress on disk, updated per case. Console output on a dedicated
        -- server is buffered and arrives in chunks minutes late, so a file is
        -- the only way to watch a run from outside while it happens.
        file.Write("bmx_test_progress.txt", string.format(
            "case %d/%d: %s\nstarted %s\n",
            run.idx, #run.queue, name, os.date("%H:%M:%S")))
        run.deadline = CurTime() + case.timeout
        run.co = coroutine.create(case.fn)
    end

    -- Step it
    local ctx = run.ctx
    if CurTime() > run.deadline then
        ctx:ok(false, "case exceeded its " .. run.case.timeout .. "s timeout")
        run.co = nil
    else
        local ok, err = coroutine.resume(run.co, ctx)   -- resume never throws
        if not ok then
            ctx.failed = true
            ctx.error = tostring(err)
            run.co = nil
        elseif coroutine.status(run.co) == "dead" then
            run.co = nil
        end
    end

    -- A HUMAN MAY HAVE JOINED MID-RUN. bmx_test refuses to START with one on,
    -- but a restart-per-run box is one a tester rejoins while the suite is
    -- going, and they spawn on the very ground the cases ride over: close
    -- enough to release a parked bike's hold, or to be ridden into. Two cases
    -- failed that way on 2026-09-26 and read as bike faults. Say so.
    if #player.GetHumans() > 0 then ctx.humanPresent = true end

    if not run.co then
        if ctx.humanPresent then
            ctx:log("WARNING: a human player was connected during this case; " ..
                "a failure here may be them, not the bike")
        end
        finiteCheck(ctx, run.case)
        teardown(ctx)
        run.results[#run.results + 1] = {
            name = run.case.name, failed = ctx.failed, error = ctx.error,
            checks = ctx.checks, lines = ctx.lines,
        }
        run.ctx, run.case = nil, nil
        run.idx = run.idx + 1
    end
end

function T.Run(only)
    if run then return false, "a run is already in progress" end

    local queue, skipped = {}, {}
    if only and only:sub(-1) == "*" then
        -- A prefix: every case whose name starts with it, in suite order
        -- (bmx_test bot_* runs the bot's cases and nothing else).
        local pre = only:sub(1, -2)
        for _, n in ipairs(T.order) do
            if n:sub(1, #pre) == pre then queue[#queue + 1] = n end
        end
        if #queue == 0 then return false, "no such case: " .. only end
    elseif only and only ~= "" then
        if not T.cases[only] then return false, "no such case: " .. only end
        queue[1] = only
    else
        for _, n in ipairs(T.order) do
            if T.cases[n].wip then skipped[#skipped + 1] = n else queue[#queue + 1] = n end
        end
    end

    run = { queue = queue, idx = 1, results = {}, skipped = skipped }
    hook.Add("Think", "BMX.TestRunner", advance)
    return true
end

--------------------------------------------------------------------------
concommand.Add("bmx_test", function(ply, _, args)
    -- Console or superadmin only, and never while humans are on: the harness
    -- spawns bikes, seats a bot and deliberately crashes things.
    if IsValid(ply) and not ply:IsSuperAdmin() then return end
    for _, p in ipairs(player.GetHumans()) do
        if p ~= ply then
            local m = "[BMX] refusing to run: human players are connected."
            if IsValid(ply) then ply:ChatPrint(m) else MsgN(m) end
            return
        end
    end

    local ok, err = T.Run(args[1])
    if not ok then MsgN("[BMX] " .. err) end
end)

-- Clearing a wedged run without bouncing the server. Needed the first time this
-- suite met a real bug, and cheap enough to keep.
concommand.Add("bmx_test_abort", function(ply)
    if IsValid(ply) and not ply:IsSuperAdmin() then return end
    if not run then MsgN("[BMX] no run in progress") return end
    teardown(run.ctx)
    run = nil
    hook.Remove("Think", "BMX.TestRunner")
    MsgN("[BMX] run aborted")
end)

concommand.Add("bmx_test_list", function()
    MsgN("[BMX] cases:")
    for _, n in ipairs(T.order) do
        MsgN(string.format("   %-18s %s", n, T.cases[n].desc))
    end
end)

hook.Add("InitPostEntity", "BMX.TestOnBoot", function()
    if not GetConVar("bmx_test_onboot"):GetBool() then return end
    -- Let the map settle first: entities spawn over several ticks and a bike
    -- created in the same frame as the world can land inside it.
    timer.Simple(8, function() T.Run() end)
end)

--------------------------------------------------------------------------
-- WHO WAS HERE. bmx-test (tools/server/bmx-test) will not swap this server
-- onto its test map under a rider, and it used to decide that by asking who
-- is connected RIGHT NOW. But the pipeline's deploy restarts the server first,
-- and a restart drops everyone to the menu -- Garry's Mod does not reconnect
-- them -- so the answer was always "nobody", and the swap went ahead under a
-- rider who had been on a minute before. So the server keeps the last time a
-- human was connected, every 15 seconds and at shutdown, and bmx-test skips
-- when that was recent.
--------------------------------------------------------------------------
BMX.LAST_HUMAN_FILE = "bmx_last_human.txt"

function BMX.NoteHumans()
    if player.GetHumans and #player.GetHumans() > 0 then
        file.Write(BMX.LAST_HUMAN_FILE, tostring(os.time()))
        return true
    end
    return false
end

timer.Create("BMX.LastHuman", 15, 0, BMX.NoteHumans)
-- Wrapped so the hook returns NOTHING: a hook that returns a value ends the
-- chain, and NoteHumans returns a boolean. Left bare it would stop every other
-- ShutDown listener that happened to run after it, including the scores save.
hook.Add("ShutDown", "BMX.LastHuman", function() BMX.NoteHumans() end)
