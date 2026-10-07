--[[--------------------------------------------------------------------------
    bmx/sv_scooter.lua

    THE KICK SCOOTER, SERVER SIDE (G24). Very little: the scooter rides on code that
    already exists, and this file is only the places where it had to learn about one.

        riding        the bike's singletrack balance and input decoder (sv_balance.lua,
                      sv_input.lua) with the board's push drive (sv_board.lua), which
                      takes `footBrake = false` for exactly this vehicle
        whip, spin    G03's, untouched (sv_tricks.lua): on a scooter the part that turns
                      round the steer tube is the deck, which is what a tailwhip is
        grinds        sv_grind.lua's finder and placement, asked for the scooter's own
                      moves (below), as the board's are
        bri flip      the whip and the flip of one air paid as one trick (below)

    WHAT WRAPS WHAT. sv_physics.lua and sv_air.lua call BMX.TryGrind, BMX.ScoreExtras and
    BMX.TrackManual by name, so this file replaces those names with versions that do
    the scooter's part and hand on to what was there (the board's wrappers, loaded
    before this file, are among them). Nothing in a bike's or a board's path changes: each
    wrapper starts by asking whether the vehicle is a scooter.
----------------------------------------------------------------------------]]

BMX = BMX or {}
local SC = BMX.Scooter

local function isScooter(ent)
    local def = ent and ent.Bike and ent:Bike()
    return def ~= nil and def.family == "scooter"
end
SC.IsScooter = isScooter

--------------------------------------------------------------------------
-- THE MOVES, as TryGrind asks for them: (ent, st, rail, dh, vel) -> a move or nil.
-- `rail.kind` is "crank" (a round rail, which both sides drop away from) or "peg" (an
-- edge); `dh` the rail's horizontal direction.
--
-- A scooter grinds ALONG a rail and no other way: a deck turned across it is a slide
-- the vehicle does not have, so across is no grind (the answer is nil and the
-- scooter simply flies on, as a bike does that meets a rail side-on). The keys held
-- as it locks on (W, S) choose the move; on a round rail they cannot, since there is
-- no edge to hang a peg off, and it is a 50-50.
--------------------------------------------------------------------------
function SC.GrindMoves(ent, st, rail, dh, vel)
    local f = ent:GetForward()
    local fh = Vector(f.x, f.y, 0)
    local len = fh:Length()
    if len < 1e-3 then return nil end
    fh = fh / len

    local angle = math.acos(BMX.Clamp(math.abs(fh:Dot(dh)), 0, 1))
    if not SC.IsAlong(angle) then return nil end

    local edge = rail.kind == "peg"
    local id = SC.ClassifyGrind(SC.Keys(ent.input), edge)
    local g = SC.Grinds[id]
    local half = ent:Cfg().Wheel.wheelbase * 0.5

    -- Turned off the rail's line the way it already is (the side its nose is on); one
    -- going against the rail's direction (fakie) is turned round half a turn, and the
    -- angle then runs the other way for the nose to stay on the same side.
    local L = (dh.x * fh.y - dh.y * fh.x) >= 0 and 1 or -1
    if g.toward and edge then
        -- The peg grinds: which side the nose goes to is the rule (SC.Grinds), not the way
        -- it happened to be turned. The ledge's top is on the left of the rail's direction
        -- when UP x dh points onto it.
        local topLeft = Vector(0, 0, 1):Cross(dh):Dot(rail.side) > 0
        local top = topLeft and 1 or -1
        L = (g.toward == "top") and top or -top
    end
    local reverse = fh:Dot(dh) < 0
    local yaw
    if reverse then yaw = -L * math.abs(g.yaw) + math.pi else yaw = L * math.abs(g.yaw) end

    return {
        id = id, name = g.name, mult = g.mult,
        yaw = yaw, pitch = g.pitch, signed = false, reverse = false,
        crank = SC.GrindContact(id, half, false),
        peg = function(sgn) return SC.GrindContact(id, half, true, sgn) end,
    }
end

--------------------------------------------------------------------------
-- LOCKING ON: once the base has locked a scooter on, the spark code is the move's own
-- (the base set the bike's), so the sparks come off the deck or the peg. A trick's
-- name and rate came with the move (g.name, g.mult), and are paid by EndGrind.
--------------------------------------------------------------------------
local baseTry = BMX.TryGrind

function BMX.TryGrind(ent, phys, cfg, st, vel)
    if not baseTry(ent, phys, cfg, st, vel) then return false end
    if isScooter(ent) and st.grind and st.grind.move and ent.SetGrind then
        ent:SetGrind(SC.SparkCode[st.grind.move] or 10)
    end
    return true
end

--------------------------------------------------------------------------
-- BRI FLIP. BMX.ScoreExtras(st, out) is what the base of the landing's score is
-- completed with (the parts, the poses, the compounds), and the board wraps it too;
-- this one runs after, on a scooter's list, and turns a whip and a flip into one trick.
--------------------------------------------------------------------------
local baseExtras = BMX.ScoreExtras
function BMX.ScoreExtras(st, out)
    out = baseExtras(st, out)
    if st.def and st.def.family == "scooter" then SC.MergeBri(out) end
    return out
end

--------------------------------------------------------------------------
-- A MANUAL IS NOT A WHEELIE. The bike's rear-wheel trick is held on the ground and paid by
-- the second; on a scooter it is called what scooter riders call it.
--------------------------------------------------------------------------
local baseManual = BMX.TrackManual
function BMX.TrackManual(st, cfg, front, rear, speed, dt)
    local done = baseManual(st, cfg, front, rear, speed, dt)
    if done and st.def and st.def.family == "scooter" then
        for _, e in ipairs(done) do
            if e.name == BMX.Tricks.wheelie.name then e.name = "Manual" end
        end
    end
    return done
end
