-- THE FLIP PHOTOGRAPHS, client half (tools/bench/sp.sh flipshot). Rides the skateboard the
-- server half seated us on and does each flip with the real keys, through the real usercmd
-- (RunConsoleCommand +forward / +jump / +back / +moveleft / +duck ...), so what is drawn is
-- what a player's keys do. A camera of our own, beside the board on the toe side, takes a
-- picture 0.08, 0.16 ... 0.56 s after the pop: data/flipshot/<id>_<n>.jpg. DONE in
-- data/flipshot/done.txt.
FLIPSHOT = FLIPSHOT or {}
local F = FLIPSHOT
local IDS = FLIPSHOT_IDS or { "kickflip", "heelflip", "popshove", "frontshove", "varialkick", "varialheel",
    "hardflip", "inwardheel", "impossible", "shove360", "front360", "flip360", "laserflip", "hardflip360", "inward360" }
local KEY = { w = "forward", s = "back", a = "moveleft", d = "moveright", c = "duck" }
file.CreateDir("flipshot")
RunConsoleCommand("bmx_cam_own", "0")

local function bike()
    local ply = LocalPlayer()
    local v = IsValid(ply) and ply:GetVehicle()
    return IsValid(v) and BMX.LocalBike and BMX.LocalBike(ply) or nil
end

hook.Add("CalcView", "flipshot_cam", function(ply, origin, angles, fov)
    local b = bike()
    if not b then return end
    local up = Vector(0, 0, 1)
    local f = b:GetForward() f.z = 0 f:Normalize()
    local toe = -f:Cross(up)       -- the board's right (a regular rider faces it)
    local at = b:GetPos() + up * 30
    local eye = at + toe * 120 + f * 25 + up * 12
    return { origin = eye, angles = (at - eye):Angle(), fov = 60, drawviewer = true }
end)

local shots = {}       -- { at = RealTime, name = ... } waiting for a frame
hook.Add("PostRender", "flipshot_cap", function()
    local s = shots[1]
    if not s or RealTime() < s.at then return end
    table.remove(shots, 1)
    local data = render.Capture({ format = "jpeg", x = 0, y = 0, w = ScrW(), h = ScrH(), quality = 88 })
    if data then file.Write("flipshot/" .. s.name .. ".jpg", data) end
end)

local function press(keys, on)
    for c in keys:gmatch(".") do RunConsoleCommand((on and "+" or "-") .. KEY[c]) end
end

local function run(i)
    local id = IDS[i]
    if not id then
        file.Write("flipshot/done.txt", "DONE")
        hook.Remove("CalcView", "flipshot_cam")
        RunConsoleCommand("bmx_cam_own", "1")
        return
    end
    local keys = BMX.Board.Flips[id].full and "c" or ""
    local f = BMX.Board.Flips[id]
    for _, c in ipairs({ "w", "s", "a", "d" }) do if f[c] then keys = keys .. c end end
    press("w", true)                                          -- push up to speed
    timer.Simple(2.6, function() press("w", false) end)
    timer.Simple(3.0, function() RunConsoleCommand("+jump") end)
    timer.Simple(3.45, function()
        RunConsoleCommand("-jump")
        press(keys, true)
        local t0 = RealTime()
        for n = 1, 7 do shots[#shots + 1] = { at = t0 + 0.08 * n, name = string.format("%02d_%s_%d", i, id, n) } end
    end)
    timer.Simple(4.1, function() press(keys, false) end)
    timer.Simple(6.0, function() run(i + 1) end)
end
timer.Simple(2, function() run(1) end)
print("[flipshot] client half running " .. #IDS .. " flips")
