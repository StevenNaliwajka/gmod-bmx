--[[--------------------------------------------------------------------------
    The client never reads a name only the server has.

    GMod runs a separate Lua state for each realm, in singleplayer too: what
    an sv_ file sets does not exist on the client. A client file (or a shared
    one, running on the client) that reads it gets nil, and either throws (the
    Server settings panel in 1.2.0: S.PRIV, set only in sv_settings.lua) or
    quietly does something else (the skates' prediction: BMX.StickDeadzone,
    published only by sv_input.lua, so a gamepad stick read as no stick).

    THE CHECK. Boot both realms, then read every file the client ran, comments
    and strings out, for BMX.a.b paths and paths through a local alias of one
    (local S = BMX.Settings, then S.PRIV). A path that is nil on the client
    and set on the server is a failure. Assignments and function definitions
    are not reads. Code the client cannot reach is skipped: an `if SERVER`
    block, and the rest of a function after `if CLIENT then return`.

    SERVER_ONLY below is the code the check cannot tell is server-only by
    itself; each entry says who calls it.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local gmod = require("lib.gmod")

-- "file path" -> why the client never runs that read.
local SERVER_ONLY = {
    ["bmx/sh_tricks.lua BMX.Fixie"] = "a trick's canStart: only sv_tricks.lua calls it",
    ["bmx/sh_tricks.lua BMX.Unicycle"] = "a trick's canStart: only sv_tricks.lua calls it",
    ["bmx/sh_boards.lua BMX.Board.GrindMoves"] = "a grind's moves: only sv_grind.lua calls it",
    ["bmx/sh_scooter.lua BMX.Scooter.GrindMoves"] = "a grind's moves: only sv_grind.lua calls it",
    ["bmx/sh_skates.lua BMX.Skates.GrindMoves"] = "a grind's moves: only sv_skates.lua calls it",
    ["bmx/sh_color.lua BMX.SetBikeColor"] = "the Paint property's Receive: GMod runs it on the server",
}

local function read(rel)
    local fh = io.open(gmod.ROOT .. "/lua/" .. rel, "r")
    for _, root in ipairs(gmod.EXTRA_ROOTS) do
        if fh then break end
        fh = io.open(root .. "/" .. rel, "r")
    end
    if not fh then return nil end
    local src = fh:read("*a")
    fh:close()
    return src
end

local function blank(s) return (s:gsub("[^\n]", " ")) end

-- Comments and strings blanked (line breaks kept, so line numbers hold).
local function code(src)
    src = src:gsub("(%-%-%[(=*)%[.-%]%2%])", blank)
    src = src:gsub("(%[(=*)%[.-%]%2%])", blank)
    src = src:gsub('("[^"\n]-\\")', blank)
    src = src:gsub('("[^"\n]-")', blank):gsub("('[^'\n]-')", blank)
    src = src:gsub("(%-%-[^\n]*)", blank)
    return src
end

local OPENS = { ["function"] = true, ["if"] = true, ["do"] = true, ["repeat"] = true }
local CLOSES = { ["end"] = true, ["until"] = true }

-- `if CLIENT then return`, `if CLIENT or ... then return`, `if not SERVER then return`.
local function returnsOnClient(src, at)
    return src:find("^if%s+CLIENT%s+then%s+return%f[^%w_]", at)
        or src:find("^if%s+CLIENT%s+or%s[^\n]-%sthen%s+return%f[^%w_]", at)
        or src:find("^if%s+not%s+SERVER%s+then%s+return%f[^%w_]", at)
end

-- The client cannot reach an `if SERVER ...` block (up to its else), nor the
-- rest of a function, or of the file, after one of those returns.
local function clientCode(src)
    local cuts, stack = {}, {}
    for at, word in src:gmatch("()([%a_][%w_]*)") do
        local prev = at > 1 and src:sub(at - 1, at - 1) or ""
        if not prev:match("[%w_%.:]") then
            if word == "if" then
                stack[#stack + 1] = { word = word, from = src:find("^if%s+SERVER%f[^%w_]", at) and at }
                if returnsOnClient(src, at) then
                    local fn
                    for i = #stack - 1, 1, -1 do
                        if stack[i].word == "function" then fn = stack[i] break end
                    end
                    if fn then fn.serverFrom = fn.serverFrom or at
                    else cuts[#cuts + 1] = { at, #src } end
                end
            elseif OPENS[word] then
                stack[#stack + 1] = { word = word }
            elseif (word == "else" or word == "elseif") and stack[#stack] and stack[#stack].from then
                cuts[#cuts + 1] = { stack[#stack].from, at - 1 }
                stack[#stack].from = nil
            elseif CLOSES[word] then
                local b = table.remove(stack)
                if b and b.from then cuts[#cuts + 1] = { b.from, at + #word - 1 } end
                if b and b.serverFrom then cuts[#cuts + 1] = { b.serverFrom, at - 1 } end
            end
        end
    end
    for _, c in ipairs(cuts) do
        src = src:sub(1, c[1] - 1) .. blank(src:sub(c[1], c[2])) .. src:sub(c[2] + 1)
    end
    return src
end

local function lookup(env, path)
    local v = env
    for seg in path:gmatch("[^%.]+") do
        if type(v) ~= "table" then return nil, false end
        v = rawget(v, seg)
        if v == nil then return nil, true end
    end
    return v, true
end

-- Every "file:line  path" the client reads that only the server has.
local function serverOnlyReads(sv, cl)
    local found = {}
    for _, rel in ipairs(cl.loaded) do
        local src = read(rel)
        if src then
            src = clientCode(code(src))
            local alias = {}
            for name, path in src:gmatch("local%s+([%a_][%w_]*)%s*=%s*(BMX[%w_%.]*)") do
                alias[name] = path
            end
            local seen = {}
            for at, root, rest in src:gmatch("()([%a_][%w_]*)(%.[%a_][%w_%.]*)") do
                rest = (rest:match("^(.-)%.%.") or rest):gsub("%.+$", "")
                local prev = at > 1 and src:sub(at - 1, at - 1) or ""
                local after = src:sub(at + #root + #rest):match("^%s*(=?=?)")
                local defines = after == "=" or src:sub(1, at - 1):match("function%s+$")
                local base = root == "BMX" and "BMX" or alias[root]
                if base and not prev:match("[%w_%.:]") and not defines then
                    -- The first step of the path the client does not have.
                    local path = ""
                    for seg in (base .. rest):gmatch("[^%.]+") do
                        path = path == "" and seg or (path .. "." .. seg)
                        local c, cok = lookup(cl.env, path)
                        local s, sok = lookup(sv.env, path)
                        if not (cok and sok) then break end
                        if c == nil then
                            local key = rel .. " " .. path
                            if s ~= nil and not seen[path] and not SERVER_ONLY[key] then
                                seen[path] = true
                                local line = select(2, src:sub(1, at):gsub("\n", "")) + 1
                                found[#found + 1] = rel .. ":" .. line .. "  " .. path
                            end
                            break
                        end
                    end
                end
            end
        end
    end
    return found
end

T.test("realms: no client code reads a BMX name that only the server sets", function()
    local sv, world = F.server()
    local cl = F.client(world)
    T.ok(#cl.loaded > 50, "the client ran its files: " .. #cl.loaded)
    local found = serverOnlyReads(sv, cl)
    T.eq(#found, 0, "the client reads names only the server sets (define them in a " ..
        "sh_ file, or add the line to SERVER_ONLY with who calls it):\n      " ..
        table.concat(found, "\n      "))
end)

T.test("realms: the check sees through an alias, and skips server-only code", function()
    local probe = code([[
local S = BMX.Settings
if SERVER then x = S.OnlyServer end
function f() if CLIENT then return end y = S.AlsoServer end
function g() if CLIENT or busy then return end v = S.ThirdServer end
function h() if CLIENT and busy then return end u = S.Shared end
z = S.Read -- S.Comment
w = "S.String"
]])
    local kept = clientCode(probe)
    T.ok(not kept:find("OnlyServer", 1, true), "an if SERVER block is skipped")
    T.ok(not kept:find("AlsoServer", 1, true), "so is the rest of a function after if CLIENT then return")
    T.ok(not kept:find("ThirdServer", 1, true), "or after if CLIENT or ... then return")
    T.ok(kept:find("S.Shared", 1, true), "but not after if CLIENT and ... then return: the client can get past that")
    T.ok(kept:find("S.Read", 1, true), "a plain read is kept")
    T.ok(not kept:find("Comment", 1, true) and not kept:find("String", 1, true),
        "comments and strings are not code")
    T.eq(select(2, kept:gsub("\n", "")), 7, "line breaks are kept")
end)
