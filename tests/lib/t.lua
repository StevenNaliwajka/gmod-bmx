--[[--------------------------------------------------------------------------
    tests/lib/t.lua

    The smallest test framework that reports the ACTUAL value on failure.
    A failed band that does not say what it measured is a test someone widens
    rather than reads.
----------------------------------------------------------------------------]]

local T = { cases = {}, current = nil }

function T.test(name, fn)
    T.cases[#T.cases + 1] = { name = name, fn = fn, file = T.current }
end

local function fail(msg, level)
    error({ bmx_test_failure = true, msg = msg }, (level or 2) + 1)
end

function T.ok(cond, msg)
    if not cond then fail(msg or "expected a true value", 2) end
end

function T.eq(got, want, msg)
    if got ~= want then
        fail(string.format("%s: got %s, want %s", msg or "eq", tostring(got), tostring(want)), 2)
    end
end

function T.near(got, want, tol, msg)
    if type(got) ~= "number" or got ~= got or math.abs(got - want) > tol then
        fail(string.format("%s: got %s, want %g +/- %g", msg or "near", tostring(got),
            want, tol), 2)
    end
end

function T.between(got, lo, hi, msg)
    if type(got) ~= "number" or got ~= got or got < lo or got > hi then
        fail(string.format("%s: got %s, want %g..%g", msg or "between", tostring(got),
            lo, hi), 2)
    end
end

-- fn must throw, and the message must match `pattern` when one is given.
function T.errors(fn, pattern, msg)
    local ok, err = pcall(fn)
    if ok then fail((msg or "expected an error") .. ": it did not throw", 2) end
    local text = type(err) == "table" and tostring(err.msg) or tostring(err)
    if pattern and not text:find(pattern) then
        fail(string.format("%s: threw %q, which does not match %q", msg or "errors",
            text, pattern), 2)
    end
end

function T.finite(v, msg)
    local function f(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end
    local okv = type(v) == "number" and f(v) or (type(v) == "table" and f(v.x) and f(v.y) and f(v.z))
    if not okv then fail((msg or "finite") .. ": got " .. tostring(v), 2) end
end

return T
