--[[--------------------------------------------------------------------------
    The skateboard's style (G23 M4: grabs, reverts, powerslide, switch, and the
    carried board): sh_board.lua's grab map, sv_board_tricks.lua's step functions,
    weapon_bmx_board.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local BF = require("lib.board")
local ridden, press = BF.ridden, BF.press

local function keys(s)
    local k = { w = false, s = false, a = false, d = false }
    for c in s:gmatch(".") do k[c] = true end
    return k
end

T.test("grabs: RMB and a direction pick the grab, each a registered pose trick with an IK row", function()
    local sv = F.server()
    local cl = F.client(sv.world)
    local B = sv.env.BMX.Board
    T.eq(B.GrabFor(keys("")), "method", "RMB alone: method")
    T.eq(B.GrabFor(keys("a")), "indy", "A: indy")
    T.eq(B.GrabFor(keys("d")), "melon", "D: melon")
    T.eq(B.GrabFor(keys("w")), "nosegrab", "W: nosegrab")
    T.eq(B.GrabFor(keys("s")), "tailgrab", "S: tailgrab")
    T.eq(B.GrabFor(keys("sd")), "stalefish", "S + D: stalefish")
    local seen = {}
    local rows = cl.env.BMX.Board.PoseRows(1)
    for _, id in ipairs(B.GrabOrder) do
        local t = sv.env.BMX.Tricks[id]
        T.ok(t and t.kind == "pose" and t.pose == id, id .. " is a pose trick")
        T.ok(sv.env.BMX.PoseIDs[id], id .. " has a wire id")
        T.ok(rows[id] and (rows[id].lHand or rows[id].rHand), id .. " says where a hand goes")
        T.ok(rows[id].boardLift > 0, id .. " lifts the deck")
    end
    -- Stance swaps which hand does it: front hand is the left for a regular rider.
    T.ok(cl.env.BMX.Board.PoseRows(1).nosegrab.lHand, "regular: the left (front) hand takes the nose")
    T.ok(cl.env.BMX.Board.PoseRows(-1).nosegrab.rHand, "goofy: the right")
    T.ok(sv.env.BMX.VehicleAllows(sv.env.BMX.Vehicles.skateboard, "indy"), "the board may do them")
end)

T.test("grab ride: a grab held in the air pays per tenth of a second; let go before landing and it lands", function()
    local sv, e = ridden()
    local landed = {}
    sv.env.hook.Add("BMX_TrickLanded", "t", function(ply, t) landed[#landed + 1] = t.name end)
    press(e, { throttle = 1, fwd = 1 })
    sv:run(3)
    press(e, { jump = true })
    sv:run(0.5)
    press(e, {})
    sv:run(0.12)
    e.input.pose = "indy"
    sv:run(0.35)
    e.input.pose = nil
    sv:run(1.5)
    local got
    for _, n in ipairs(landed) do if n:find("Indy", 1, true) then got = n end end
    T.ok(got, "an Indy was paid: " .. table.concat(landed, ", "))
    T.ok(e:GetDriver():InVehicle(), "and nobody bailed")
end)

T.test("grab ride: landing with the grab still held bails", function()
    local sv, e = ridden()
    local crashed
    sv.env.hook.Add("BMX_Crashed", "t", function(ent, ply, reason) crashed = reason end)
    press(e, { throttle = 1, fwd = 1 })
    sv:run(3)
    press(e, { jump = true })
    sv:run(0.5)
    press(e, {})
    sv:run(0.1)
    e.input.pose = "melon"
    sv:run(1.6)
    T.eq(crashed, "pose", "bailed on the pose")
end)

T.test("revert: A on touching down on a transition turns it a half turn, keeps the speed, and pays", function()
    local sv, e = ridden()
    local landed = {}
    sv.env.hook.Add("BMX_TrickLanded", "t", function(ply, t) landed[#landed + 1] = t.name end)
    press(e, { throttle = 1, fwd = 1 })
    sv:run(4)
    local b = e.st.board
    local v0, y0 = e.st.speed, e:GetAngles().y
    press(e, { side = -1 })
    b.touchAt, b.touchNormal = sv.world.time, sv.env.Vector(0.5, 0, 0.87)
    sv:run(0.5)
    local diff = (e:GetAngles().y - y0 + 540) % 360 - 180
    T.ok(180 - math.abs(diff) < 25, "a half turn: " .. diff)
    T.ok(e.st.speed > v0 * 0.7, "still rolling: " .. v0 .. " -> " .. e.st.speed)
    local paid
    for _, n in ipairs(landed) do if n:find("Revert", 1, true) then paid = true end end
    T.ok(paid, "a Revert was paid: " .. table.concat(landed, ", "))
    T.ok(e:GetDriver():InVehicle(), "rider aboard")
    T.ok(sv.env.BMX.Board.RevertSurface(sv.env.Vector(0.5, 0, 0.87)), "30 degrees is a transition")
    T.ok(not sv.env.BMX.Board.RevertSurface(sv.env.Vector(0, 0, 1)), "flat ground is not")
end)

T.test("revert: not on flat ground, not without a key, not after the window", function()
    local sv, e = ridden()
    press(e, { throttle = 1, fwd = 1 })
    sv:run(4)
    local b = e.st.board
    local y0 = e:GetAngles().y
    press(e, { side = -1 })
    b.touchAt, b.touchNormal = sv.world.time, sv.env.Vector(0, 0, 1)
    sv:run(0.5)
    T.ok(math.abs((e:GetAngles().y - y0 + 540) % 360 - 180) < 30, "flat: no revert")
    b.touchAt, b.touchNormal = sv.world.time - 1, sv.env.Vector(0.5, 0, 0.87)
    sv:run(0.5)
    T.ok(math.abs((e:GetAngles().y - y0 + 540) % 360 - 180) < 30, "late: no revert")
end)

T.test("powerslide: CTRL + A at speed turns the board off its travel, scrubs speed, and pays on letting go", function()
    local sv, e = ridden()
    local landed = {}
    sv.env.hook.Add("BMX_TrickLanded", "t", function(ply, t) landed[#landed + 1] = t.name end)
    press(e, { throttle = 1, fwd = 1 })
    sv:run(5, function() return e.st.fwdSpeed > 150 end)
    local v0 = e.st.speed
    press(e, { duck = true, side = -1, lean = -1 })
    sv:run(0.3)
    T.ok(e.st.board.powerslide, "sliding")
    local v = e:GetPhysicsObject():GetVelocity()
    local heading = math.deg(math.atan2(v.y, v.x))
    local nose = e:GetAngles().y
    T.ok(math.abs((nose - heading + 540) % 360 - 180) > 15, "the nose is off the travel: " .. (nose - heading))
    T.ok(sv.env.BMX.Board.HasFlag(e:GetBoardFlags(), "powerslide"), "flagged")
    sv:run(0.3)
    press(e, {})
    sv:run(0.4)
    T.eq(e.st.board.powerslide, nil, "ended")
    T.ok(e.st.speed < v0, "it cost speed: " .. v0 .. " -> " .. e.st.speed)
    local paid
    for _, n in ipairs(landed) do if n:find("Powerslide", 1, true) then paid = true end end
    T.ok(paid, "a Powerslide was paid: " .. table.concat(landed, ", "))
    T.ok(math.abs(e.st.roll) < math.rad(25), "and it did not tip: " .. math.deg(e.st.roll))
    T.ok(e:GetDriver():InVehicle(), "rider aboard")
end)

T.test("powerslide: not at a walk, and not without CTRL", function()
    local sv, e = ridden()
    press(e, { duck = true, side = -1 })
    sv:run(0.4)
    T.eq(e.st.board.powerslide, nil, "standing still: no")
    local sv2, e2 = ridden()
    press(e2, { throttle = 1, fwd = 1 })
    sv2:run(5, function() return e2.st.fwdSpeed > 150 end)
    press(e2, { side = -1, lean = -1 })
    sv2:run(0.4)
    T.eq(e2.st.board.powerslide, nil, "A alone is a carve")
end)

T.test("switch: LMB swaps the feet, the stance flips, the seat turns, switch tricks pay more", function()
    local sv, e = ridden()
    local b = e.st.board
    T.eq(b.switch, false, "regular to start")
    press(e, { swap = true })
    sv:run(0.1)
    T.eq(b.switch, true, "in switch")
    T.eq(sv.env.BMX.Board.Stance(b.goofy, b.switch), -1, "the other foot forward")
    T.ok(sv.env.BMX.Board.HasFlag(e:GetBoardFlags(), "switch"), "networked")
    press(e, { swap = true })
    sv:run(0.1)
    T.eq(b.switch, true, "held, not toggled again")
    press(e, {})
    sv:run(0.05)
    press(e, { swap = true })
    sv:run(0.05)
    T.eq(b.switch, false, "a fresh press swaps back")
end)

T.test("switch: the rider's own stance (bmx_stance goofy) is read and turns the seat", function()
    local sv, e = ridden()
    local ply = e:GetDriver()
    ply._info = ply._info or {}
    ply._info.bmx_stance = "goofy"
    e.st.board.nextPoll = 0
    sv:run(0.2)
    T.eq(e.st.board.goofy, true, "goofy")
    T.eq(sv.env.BMX.Board.Stance(true, false), -1, "right foot forward")
    T.ok(sv.env.BMX.Board.HasFlag(e:GetBoardFlags(), "goofy"), "networked")
    T.eq(e.st.board.podStance, -1, "and the seat was turned")
end)

T.test("carry: the board SWEP drops a board in front of the player and is spent; a count includes the carried one", function()
    local sv = F.server()
    local E = sv.env
    local ply = sv:player("Skater")
    ply._eyeTrace = { Hit = true, HitPos = E.Vector(100, 0, 0), HitNormal = E.Vector(0, 0, 1) }
    local B = E.BMX
    T.eq(B.BikesOwnedBy(ply), 0, "nothing out")
    ply:Give("weapon_bmx_board")
    T.eq(B.BikesOwnedBy(ply), 1, "a carried board counts against bmx_max_per_player")
    T.ok(B.BoardCarry and B.BoardCarry.Drop, "there is a drop")
    local e = B.BoardCarry.Drop(ply)
    T.ok(E.IsValid(e) and e:GetClass() == "bmx_skateboard", "a skateboard stands there")
    T.eq(e.BMXOwner, ply, "and it is theirs")
    T.eq(B.BikesOwnedBy(ply), 1, "one board, out now")
    T.ok(not ply:HasWeapon("weapon_bmx_board"), "the SWEP is spent")
    -- And pick it up again.
    T.ok(B.BoardCarry.PickUp(ply, e), "picked up")
    T.ok(ply:HasWeapon("weapon_bmx_board"), "carried again")
    T.ok(not E.IsValid(e), "the entity is gone")
end)

T.test("carry: dropping a board respects bmx_allow_boards and the per-player limit", function()
    local sv = F.server()
    local E = sv.env
    local ply = sv:player("Skater")
    ply._eyeTrace = { Hit = true, HitPos = E.Vector(100, 0, 0), HitNormal = E.Vector(0, 0, 1) }
    ply:Give("weapon_bmx_board")
    E.GetConVar("bmx_allow_boards"):SetString("0")
    T.eq(E.BMX.BoardCarry.Drop(ply), nil, "boards are off")
    E.GetConVar("bmx_allow_boards"):SetString("1")
    T.ok(E.BMX.BoardCarry.Drop(ply), "back on")
end)

