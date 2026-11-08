-- WHAT THE ADDON COSTS ON A REAL CLIENT (tools/bench/realprobe.sh). The offline bench
-- (client_frame.lua) counts engine calls under a shim; this times the addon's own Lua
-- inside a running Garry's Mod, on the machine's GPU, with LuaJIT as GMod runs it:
-- every hook the addon added (identifiers starting "BMX") and every method of its
-- entities (Draw, Think, ...) is wrapped in a SysTime pair, and each scene reports the
-- frame time and the dearest of them, per frame.
REALPROBE = REALPROBE or {}
local R = REALPROBE

local acc = {}            -- name -> { t = seconds, n = calls }
local function wrap(name, fn)
    return function(...)
        local s = SysTime()
        local a, b, c, d, e, f = fn(...)
        local x = acc[name]
        if not x then x = { t = 0, n = 0 } acc[name] = x end
        x.t = x.t + (SysTime() - s)
        x.n = x.n + 1
        return a, b, c, d, e, f
    end
end

-- Hooks: wrap in place (hook.Add again with the same identifier replaces it).
function R.WrapHooks()
    if R.hooksWrapped then return end
    R.hooksWrapped = {}
    for event, list in pairs(hook.GetTable()) do
        for id, fn in pairs(list) do
            if isstring(id) and id:sub(1, 3) == "BMX" then
                R.hooksWrapped[#R.hooksWrapped + 1] = { event, id, fn }
                hook.Add(event, id, wrap(event .. ":" .. id, fn))
            end
        end
    end
    -- Entity classes: the stored tables (new entities pick up the wrapped methods) and the
    -- live ones.
    for _, cls in ipairs({ "bmx_base", "bmx_park_piece", "bmx_bike_rack", "bmx_rental", "bmx_filmer_cam" }) do
        local t = scripted_ents.GetStored(cls)
        t = t and t.t
        if t and not t.__probe then
            t.__probe = true
            for _, m in ipairs({ "Draw", "DrawTranslucent", "Think", "DrawDetailed" }) do
                if isfunction(t[m]) then t[m] = wrap(cls .. ":" .. m, t[m]) end
            end
        end
    end
end
function R.Unwrap()
    for _, h in ipairs(R.hooksWrapped or {}) do hook.Add(h[1], h[2], h[3]) end
    R.hooksWrapped = nil
end

-- A scene: `secs` of frames; returns the frame times and the per-frame cost of each.
-- Each live vehicle's own Draw, wrapped on the entity (a class registered from bmx_base
-- copied the method when it registered, so wrapping the stored base does not reach it).
function R.WrapEntities()
    for _, e in ipairs(ents.FindByClass("bmx_*")) do
        if not e.__probeDraw and isfunction(e.Draw) then
            e.__probeDraw = true
            e.Draw = wrap("vehicle Draw (" .. e:GetClass() .. ")", e.Draw)
        end
    end
end
function R.Measure(label, secs, cb)
    acc = {}
    R.WrapEntities()
    local ft, last = {}, SysTime()
    local f0 = FrameNumber()
    hook.Add("PostRender", "realprobe", function()
        local now = SysTime()
        ft[#ft + 1] = now - last
        last = now
    end)
    timer.Simple(secs, function()
        hook.Remove("PostRender", "realprobe")
        local frames = math.max(1, FrameNumber() - f0)
        table.sort(ft)
        local function q(p) return (ft[math.max(1, math.ceil(p * #ft))] or 0) * 1000 end
        local rows, total = {}, 0
        for name, x in pairs(acc) do rows[#rows + 1] = { name, x.t, x.n } total = total + x.t end
        -- The entity methods are inside the engine's draw, the hooks around it: the hooks'
        -- and the methods' times are separate (Draw is not inside any BMX hook).
        table.sort(rows, function(a, b) return a[2] > b[2] end)
        local out = { string.format("%s: %d frames, %.1f fps | frame ms median %.2f p95 %.2f p99 %.2f max %.2f | addon Lua %.2f ms/frame",
            label, frames, frames / secs, q(0.5), q(0.95), q(0.99), q(1), total * 1000 / frames) }
        for i = 1, math.min(18, #rows) do
            local r = rows[i]
            out[#out + 1] = string.format("    %-48s %7.3f ms/frame  %6.1f calls/frame", r[1], r[2] * 1000 / frames, r[3] / frames)
        end
        cb(table.concat(out, "\n"))
    end)
end
print("[realprobe] client ready " .. BMX.Version)

R.WrapHooks()
net.Receive("realprobe_scene", function()
    local label, secs = net.ReadString(), net.ReadFloat()
    R.Measure(label, secs, function(s)
        print("[realprobe] " .. s)
        net.Start("realprobe_result") net.WriteString(s) net.SendToServer()
    end)
end)

-- A SAMPLING PROFILE of the addon's Lua: every N instructions the line running is
-- tallied (LuaJIT's count hook fires in the interpreter, where GMod's draw paths spend
-- most of their time: they call into the engine constantly). Only lines under lua/bmx
-- and lua/entities are kept, with the function each is in.
function R.Profile(secs, cb)
    local hits, total = {}, 0
    debug.sethook(function()
        local i = debug.getinfo(2, "Sl")
        if not i then return end
        local src = i.short_src
        if src:find("lua/bmx/", 1, true) or src:find("lua/entities/bmx", 1, true) then
            local k = src:match("([^/]+/[^/]+)$") .. ":" .. (i.currentline or 0)
            hits[k] = (hits[k] or 0) + 1
            total = total + 1
        end
    end, "", 997)
    timer.Simple(secs, function()
        debug.sethook()
        local rows = {}
        for k, n in pairs(hits) do rows[#rows + 1] = { k, n } end
        table.sort(rows, function(a, b) return a[2] > b[2] end)
        local out = { string.format("profile: %d samples in the addon's lines", total) }
        for i = 1, math.min(40, #rows) do out[#out + 1] = string.format("    %5.1f%%  %s", rows[i][2] * 100 / math.max(total, 1), rows[i][1]) end
        cb(table.concat(out, "\n"))
    end)
end
