--[[--------------------------------------------------------------------------
    Lua autorefresh: a file run again, ALONE, on a running game.

    Save a file under a running server (or copy a new version of the addon over
    one) and Garry's Mod re-runs each changed file by itself, in no particular
    order, on the server and on every client. The trick registry used to start
    again from empty whenever sh_tricks.lua ran, which threw away every trick
    another file had registered (the board's 180, the motorbikes' heel clicker):
    the skates then failed their own check, "tricks lists board180, which is not
    a registered trick", and pose ids were dealt out again in a new order. And a
    file that registers tricks, run again by itself, stopped at its first trick
    on "duplicate id".
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local function copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

-- What the registry holds, to compare after a reload.
local function snapshot(B)
    return { order = copy(B.TrickOrder), poseIDs = copy(B.PoseIDs), poseNames = copy(B.PoseNames),
             ticks = #B.TickList, tricks = copy(B.Tricks), vehicles = copy(B.Vehicles) }
end

local function sameRegistry(B, s, what)
    T.eq(#B.TrickOrder, #s.order, what .. ": the number of registered tricks")
    for i, id in ipairs(s.order) do
        T.eq(B.TrickOrder[i], id, what .. ": trick " .. i .. " in registration order")
        T.ok(B.Tricks[id] == s.tricks[id], what .. ": " .. id .. " is the same table (references to it stay good)")
    end
    for name, n in pairs(s.poseIDs) do
        T.eq(B.PoseIDs[name], n, what .. ": pose " .. name .. " keeps its wire id")
    end
    T.eq(#B.PoseNames, #s.poseNames, what .. ": the number of pose ids")
    T.eq(#B.TickList, s.ticks, what .. ": the tricks with an onTick")
    for id in pairs(s.vehicles) do
        T.ok(B.Vehicles[id], what .. ": vehicle " .. id .. " is still registered")
    end
end

-- Run `rel` again in a booted realm; it must neither throw nor log an error.
local function rerun(R, rel)
    local before = #R.errors
    local ok, err = pcall(function() R:runFile(rel) end)
    T.ok(ok, rel .. " run again alone threw: " .. tostring(err))
    T.eq(#R.errors, before, rel .. " run again alone logged: " .. table.concat(R.errors, " | ", before + 1))
end

T.test("the trick registry run again keeps the tricks other files registered", function()
    local sv = F.server()
    local B = sv.env.BMX
    T.ok(B.Tricks.board180 and B.Tricks.heel_clicker, "the board and the motorbikes registered theirs")
    local s = snapshot(B)
    rerun(sv, "bmx/sh_tricks.lua")
    -- The order the reported error came in: the skates re-checked after the registry.
    rerun(sv, "bmx/sh_skates.lua")
    rerun(sv, "bmx/sh_motorbikes.lua")
    sameRegistry(B, s, "after sh_tricks.lua")
end)

T.test("a file that registers tricks can run again by itself", function()
    for _, rel in ipairs({ "bmx/sh_motor.lua", "bmx/sh_board.lua", "bmx/sh_scooter.lua", "bmx/sh_skates.lua" }) do
        local sv = F.server()
        local B = sv.env.BMX
        local s = snapshot(B)
        rerun(sv, rel)
        sameRegistry(B, s, "after " .. rel)
    end
end)

T.test("a trick run again takes its new definition", function()
    local sv = F.server()
    local B = sv.env.BMX
    local held = B.Tricks.board180
    local was = held.points
    -- What a saved edit looks like: the same file, a new number.
    local src = io.open(require("lib.gmod").ROOT .. "/lua/bmx/sh_board.lua"):read("*a")
    local edited = src:gsub('(id = "board180", name = "180", kind = "custom", points = )120', "%1777", 1)
    T.ok(edited ~= src, "the test found board180's points to edit")
    local chunk = assert(loadstring(edited, "@lua/bmx/sh_board.lua"))
    setfenv(chunk, sv.env)
    chunk()
    T.ok(B.Tricks.board180 == held, "the same table, so whatever held it sees the change")
    T.eq(held.points, 777, "the edit took (was " .. was .. ")")
end)

-- Every lua/bmx file, shared, server and client, in the order the realm loaded
-- them. (Entities, weapons and tools are left out: the engine hands those an
-- ENT / SWEP / TOOL table when it reloads them, which the shim does not.)
T.test("every bmx file can run again alone, in both realms", function()
    local sv, world = F.server()
    local cl = F.client(world)
    for name, R in pairs({ server = sv, client = cl }) do
        local B = R.env.BMX
        local s = snapshot(B)
        local files = {}
        for _, rel in ipairs(R.loaded) do
            if rel:match("^bmx/") then files[#files + 1] = rel end
        end
        T.ok(#files > 40, name .. ": found the bmx files (" .. #files .. ")")
        for _, rel in ipairs(files) do rerun(R, rel) end
        sameRegistry(B, s, name)
    end
end)

T.test("two files registering one trick id is still a clash", function()
    local sv = F.server()
    T.errors(function()
        sv.env.BMX.RegisterTrick{ id = "board180", name = "Another 180", input = "x", points = 1 }
    end, "duplicate id %(bmx/sh_board.lua registered it first%)", "a trick id another file owns")
end)

T.test("one run of a file registering an id twice is still a clash", function()
    local sv = F.server()
    local chunk = assert(loadstring([[
        BMX.RegisterTrick{ id = "t_twice", name = "Twice", input = "x", points = 1 }
        BMX.RegisterTrick{ id = "t_twice", name = "Twice again", input = "x", points = 2 }
    ]], "@lua/bmx/sh_mine.lua"))
    setfenv(chunk, sv.env)
    T.errors(chunk, "duplicate id", "the same id twice in one run (a copy-paste slip)")
    T.eq(sv.env.BMX.Tricks.t_twice.name, "Twice", "the first one stands")
end)
