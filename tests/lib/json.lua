--[[--------------------------------------------------------------------------
    tests/lib/json.lua

    Enough of util.TableToJSON / util.JSONToTable for the scores file and the
    game HUD snapshot: nested tables, strings, numbers, booleans. A table whose
    keys are 1..n is an array, anything else an object, as the engine's is.

    Written here, not borrowed, because stock Lua 5.1 has no JSON and the suite
    is meant to need nothing installed.
----------------------------------------------------------------------------]]

local J = {}

local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\t"] = "\\t" }

local function enc(v)
    local t = type(v)
    if t == "string" then
        return '"' .. v:gsub('[%c"\\]', function(c)
            return ESC[c] or string.format("\\u%04x", c:byte())
        end) .. '"'
    elseif t == "number" then
        if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
        return string.format("%.17g", v)
    elseif t == "boolean" then
        return tostring(v)
    elseif t == "table" then
        local n = 0
        for _ in pairs(v) do n = n + 1 end
        if n > 0 and n == #v then
            local o = {}
            for i = 1, n do o[i] = enc(v[i]) end
            return "[" .. table.concat(o, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local o = {}
        for _, k in ipairs(keys) do o[#o + 1] = enc(tostring(k)) .. ":" .. enc(v[k]) end
        return "{" .. table.concat(o, ",") .. "}"
    end
    return "null"
end

local function dec(s)
    local i = 1
    local function ws() i = s:find("%S", i) or (#s + 1) end

    local function str()
        local out = {}
        i = i + 1
        while true do
            local c = s:sub(i, i)
            if c == "" then error("unterminated string") end
            if c == '"' then i = i + 1 break end
            if c == "\\" then
                local n = s:sub(i + 1, i + 1)
                if n == "u" then
                    out[#out + 1] = string.char(tonumber(s:sub(i + 2, i + 5), 16) % 256)
                    i = i + 6
                else
                    out[#out + 1] = ({ n = "\n", t = "\t" })[n] or n
                    i = i + 2
                end
            else
                out[#out + 1] = c
                i = i + 1
            end
        end
        return table.concat(out)
    end

    local val
    function val()
        ws()
        local c = s:sub(i, i)
        if c == "{" then
            local o = {}
            i = i + 1
            ws()
            if s:sub(i, i) == "}" then i = i + 1 return o end
            while true do
                ws()
                local k = str()
                ws()
                assert(s:sub(i, i) == ":", "expected :")
                i = i + 1
                o[k] = val()
                ws()
                local d = s:sub(i, i)
                i = i + 1
                if d == "}" then return o end
                assert(d == ",", "expected ,")
            end
        elseif c == "[" then
            local o = {}
            i = i + 1
            ws()
            if s:sub(i, i) == "]" then i = i + 1 return o end
            while true do
                o[#o + 1] = val()
                ws()
                local d = s:sub(i, i)
                i = i + 1
                if d == "]" then return o end
                assert(d == ",", "expected ,")
            end
        elseif c == '"' then
            return str()
        elseif s:sub(i, i + 3) == "true" then i = i + 4 return true
        elseif s:sub(i, i + 4) == "false" then i = i + 5 return false
        elseif s:sub(i, i + 3) == "null" then i = i + 4 return nil
        end
        local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
        assert(num and num ~= "", "bad json at " .. i)
        i = i + #num
        return tonumber(num)
    end

    return val()
end

J.encode = enc
function J.decode(s)
    local ok, r = pcall(dec, s)
    if ok then return r end
    return nil
end

return J
