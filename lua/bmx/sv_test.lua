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
        timeout = opts.timeout or 40,
        desc    = opts.desc or "",
    }
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
                if spread <= MAX_SPREAD then return hits[1], nil end
            end
        end
    end

    if best then
        return best, string.format(
            "ground is not level: %.1f units of variation across 400u", bestSpread)
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
end

function Ctx:st() return self.bike.st end

function Ctx:wheels()
    local f, r
    for _, w in ipairs(self.bike.wheels) do
        if w.isFront then f = w else r = w end
    end
    return f, r
end

-- Get up to speed, because half the cases need to start from there.
function Ctx:accelerateTo(speed, timeout)
    self:input({ throttle = 1 })
    local reached = self:waitUntil(function()
        return self.bike.st.speed >= speed
    end, timeout or 12, string.format("speed >= %d u/s", speed))
    return reached
end

function Ctx:hop()
    self.bike.hopHeld   = true
    self.bike.hopCharge = 0
    self:wait(BMX.Config.Hop.chargeTime + 0.05)
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
    end
end

local function setupCase(case)
    local ground, groundNote = findTestGround()
    if not ground then
        return nil, (groundNote or "no ground") .. " on " .. game.GetMap()
    end

    local bike = ents.Create("bmx_base")
    if not IsValid(bike) then return nil, "could not create bmx_base" end
    -- Spawn at the bike's ACTUAL resting height, computed rather than guessed:
    -- the origin sits on the design axle line, so at rest it is one radius up
    -- minus the static sag, and the sag is m*g/2 divided by the spring rate.
    --
    -- The previous version used radius + 1, which was 4 units above equilibrium
    -- once the spring was retuned, and dropping the bike that far produced a
    -- transient big enough to fail cases that were measuring something else
    -- entirely. Deriving it means a future spring change cannot silently
    -- reintroduce that.
    local WC  = BMX.Config.Wheel
    local sag = (BMX.Config.Chassis.mass * physenv.GetGravity():Length() * 0.5)
        / WC.spring
    bike:SetPos(ground + Vector(0, 0, WC.radius - sag + 1))
    bike:SetAngles(Angle(0, 0, 0))
    bike:Spawn()
    bike:Activate()

    local ctx = setmetatable({
        bike = bike, checks = {}, lines = {}, failed = false,
        ground = ground,
    }, Ctx)

    -- Not fatal, but every number below assumes level ground, so say it out
    -- loud in the results rather than letting a slope masquerade as a tuning
    -- problem.
    if groundNote then ctx:log("WARNING: " .. groundNote) end

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
local function finiteCheck(ctx)
    local b = ctx.bike
    if not IsValid(b) then
        ctx:ok(false, "bike entity did not survive the case")
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

    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("%d passed, %d failed, %d total",
        passed, failed, passed + failed)
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

    if not run.co then
        finiteCheck(ctx)
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

    local queue = {}
    if only and only ~= "" then
        if not T.cases[only] then return false, "no such case: " .. only end
        queue[1] = only
    else
        for _, n in ipairs(T.order) do queue[#queue + 1] = n end
    end

    run = { queue = queue, idx = 1, results = {} }
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
