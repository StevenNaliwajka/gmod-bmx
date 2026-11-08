-- The SERVER half's cost in a running game (a singleplayer session runs it in the same
-- process as the client, every tick): every BMX hook and each live vehicle's methods
-- timed for SECS, written to data/probe/<tag>.txt. Usage (tools/bench/sp.sh): SVPROBE_TAG,
-- SVPROBE_SECS set, then include("svprobe.lua").
local acc, wrapped = {}, {}
local function wrap(name, fn)
    return function(...)
        local s = SysTime()
        local a, b, c, d, e = fn(...)
        local x = acc[name] or { t = 0, n = 0 }
        acc[name] = x
        x.t, x.n = x.t + SysTime() - s, x.n + 1
        return a, b, c, d, e
    end
end
for ev, list in pairs(hook.GetTable()) do
    for id, fn in pairs(list) do
        if isstring(id) and id:sub(1, 3) == "BMX" then
            wrapped[#wrapped + 1] = { ev, id, fn }
            hook.Add(ev, id, wrap(ev .. ":" .. id, fn))
        end
    end
end
local ents_ = {}
for _, e in ipairs(ents.FindByClass("bmx_*")) do
    for _, m in ipairs({ "Think", "PhysicsSimulate", "PhysicsCollide" }) do
        if isfunction(e[m]) then
            ents_[#ents_ + 1] = { e, m, e[m] }
            e[m] = wrap(m .. " (" .. e:GetClass() .. ")", e[m])
        end
    end
end
local secs, tag = SVPROBE_SECS or 6, SVPROBE_TAG or "sv"
local t0, ticks0 = SysTime(), engine.TickCount()
timer.Simple(secs, function()
    for _, h in ipairs(wrapped) do hook.Add(h[1], h[2], h[3]) end
    for _, x in ipairs(ents_) do if IsValid(x[1]) then x[1][x[2]] = x[3] end end
    local ticks = math.max(1, engine.TickCount() - ticks0)
    local rows, total = {}, 0
    for k, x in pairs(acc) do rows[#rows + 1] = { k, x.t, x.n } total = total + x.t end
    table.sort(rows, function(a, b) return a[2] > b[2] end)
    local out = { string.format("%s (server): %d ticks in %.1f s | the addon's server Lua %.3f ms a tick, %.2f ms a second",
        tag, ticks, SysTime() - t0, total * 1000 / ticks, total * 1000 / (SysTime() - t0)) }
    for i = 1, math.min(15, #rows) do
        out[#out + 1] = string.format("    %-46s %7.3f ms/tick %6.1f calls/tick", rows[i][1], rows[i][2] * 1000 / ticks, rows[i][3] / ticks)
    end
    file.Write("probe/" .. tag .. ".txt", table.concat(out, "\n"))
end)
