--[[--------------------------------------------------------------------------
    The skateboard's rider (cl_board.lua): where the feet and the hands are told
    to go, checked against the board they stand on.

    Whether the rider LOOKS right needs a person on a client. What this can pin is
    the part that is geometry: a foot on the deck is on the deck (not in it, not
    floating, not sliding off it as it carves), a pushing foot is flat on the
    ground beside the board for the whole stroke and never passes through the deck
    on its way out or back, the ollie's feet are on the tail and the nose, a flip's
    flick goes the way the deck turns, and the arms move with the body.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local BF = require("lib.board")

local function client()
    local sv = F.server()
    local cl = F.client(sv.world)
    return sv, cl, cl.env, cl.env.BMX.Board
end

-- A drawn board, grounded, with what the test sets.
local function drawn(sv, cl, set)
    local E = cl.env
    local ent = cl:clientEntity("bmx_skateboard")
    ent:SetPos(E.Vector(0, 0, 1.3))
    ent:SetGrounded(true)
    ent:SetPushPhase(-1)                 -- what a ridden board's server sends when not pushing
    cl.localPlayer = sv:player("Looker")
    if set then set(ent) end
    cl.lines, cl.beams, cl.drawnModels, cl.boxes3d = 0, {}, 0, 0
    ent:Draw()
    return ent
end

--------------------------------------------------------------------------
-- The push
--------------------------------------------------------------------------

T.test("board push: out over the edge, flat on the ground beside the board for the whole stroke, back in over the deck", function()
    local _, _, E, B = client()
    for _, faceY in ipairs({ -1, 1 }) do
        local who = faceY < 0 and "regular" or "goofy"
        local g = B.PushGeo(B.Tune, faceY)
        local bolt = E.Vector(B.Tune.footBack, -faceY * 2.4, B.FootZ)
        local a, b, c = B.PushMarks(g)
        T.ok(b >= g.share, who .. ": the foot is down for all of the stroke the server pushes in: " .. b .. " vs " .. g.share)
        local prev, prevX
        local planted
        for i = 0, 500 do
            local p = i / 500
            local f, off = B.PushFoot(p, bolt, nil, g)
            T.finite(f, who .. " at " .. p)
            T.ok(f.z >= g.ground - 1e-6, who .. ": never under the ground at " .. p .. ": " .. f.z)
            if math.abs(f.y) < g.deckHalf + 1.6 then
                T.ok(f.z >= g.stand - 0.05, who .. ": never through the deck at " .. p .. ": y " .. f.y .. " z " .. f.z)
            end
            if prev then
                T.ok((f - prev):Length() < 1.0, who .. ": no jump at " .. p .. ": " .. (f - prev):Length())
            end
            if p >= a and p <= b then
                T.near(f.z, g.ground, 1e-6, who .. ": flat on the ground through the stroke at " .. p)
                T.ok(f.y * faceY > g.deckHalf + 2, who .. ": beside the board, on the side the rider faces: " .. f.y)
                if prevX then T.ok(f.x <= prevX + 1e-9, who .. ": sweeping back, never forward, at " .. p) end
                prevX = f.x
                planted = planted or f
            end
            prev = f
        end
        T.ok(math.abs(planted.x - B.Tune.footFront) < 2.5, who .. ": planted beside the front foot: " .. planted.x)
        T.ok(prevX <= -14, who .. ": and swept back past the tail's truck: " .. prevX)
        local home = B.PushFoot(c + 0.01, bolt, nil, g)
        T.near((home - bolt):Length(), 0, 1e-9, who .. ": home on its bolt well before the next kick")
        T.near((prev - bolt):Length(), 0, 1e-9, who .. ": and nothing left to snap back when the phase ends")
        T.eq(B.PushBend(-1, g), 0, who .. ": the standing knee is straight off a push")
        T.ok(B.PushBend((a + b) / 2, g) > 0.8, who .. ": and folds while the other foot reaches the ground")
    end
end)

T.test("board push on the wire: the phase runs on through the foot's way home, then goes to -1", function()
    local sv, e = BF.ridden()
    local B = sv.env.BMX.Board
    BF.press(e, { throttle = 1, fwd = 1 })
    sv:run(0.05)
    BF.press(e, {})
    local top, after = -1, nil
    sv:run(0.9, function()
        local p = e:GetPushPhase()
        if p > top then top = p end
        if sv.world.time and p < 0 and top > 0 then after = after or p end
        return false
    end)
    local stroke = B.Tune.kickTime / B.Tune.kickInterval
    T.ok(top > stroke + 0.2, "past the stroke, the foot still has its way home to go: " .. top)
    T.eq(e:GetPushPhase(), -1, "and once round, not pushing")
    T.eq(B.PushPhaseOf({ phase = 0.3 }, 0.6), -1, "no kick yet: -1")
    T.near(B.PushPhaseOf({ phase = 0.45, dv = 10 }, 0.6), 0.75, 1e-9, "a kick three quarters round")
    T.eq(B.PushPhaseOf({ phase = 0.6, dv = 10 }, 0.6), -1, "a kick all the way round: -1")
end)

T.test("board draw: a push puts the back foot on the ground beside the board, the front foot stays on its bolts", function()
    local sv, cl, E, B = client()
    local still = drawn(sv, cl)
    local ground = 1.3 - 1.3                     -- the board's origin is 1.3 over the ground
    for _, goofy in ipairs({ false, true }) do
        local ent = drawn(sv, cl, function(e)
            e:SetBoardFlags(goofy and B.PackFlags({ goofy = true }) or 0)
            e:SetPushPhase(0.3)
        end)
        local front = goofy and ent.ikTargets.rFoot or ent.ikTargets.lFoot
        local back  = goofy and ent.ikTargets.lFoot or ent.ikTargets.rFoot
        local who = goofy and "goofy" or "regular"
        T.near(back.z, ground + B.Ankle, 0.01, who .. ": the pushing foot's ankle is an ankle over the ground")
        T.ok(back.y * (goofy and 1 or -1) > 6, who .. ": out beside the board on the side the rider faces: " .. back.y)
        T.near(front.z, 1.3 + B.FootZ, 0.01, who .. ": the front foot still stands on the deck")
        T.ok(math.abs(front.x - 7.9) < 2.5, who .. ": by the front truck's bolts: " .. front.x)
    end
    -- Not pushing, both feet are on the deck.
    for _, k in ipairs({ "lFoot", "rFoot" }) do
        T.near(still.ikTargets[k].z, 1.3 + B.FootZ, 0.01, k .. " on the deck")
    end
end)

--------------------------------------------------------------------------
-- On the deck
--------------------------------------------------------------------------

T.test("board feet: over the bolts, heels in so the toes reach the toe edge, and on the deck as it leans into a carve", function()
    local sv, cl, E, B = client()
    for _, lean in ipairs({ 0, math.rad(20), -math.rad(20) }) do
        local ent = drawn(sv, cl, function(e) e:SetBoardLean(lean) end)
        local fr = B.Frame({ ent = ent, lean = lean, ground = -1.3 })
        local front, back = ent.ikTargets.lFoot, ent.ikTargets.rFoot     -- regular: the left foot leads
        for name, foot in pairs({ front = front, back = back }) do
            -- the ankle stands B.Ankle over the grip, along the deck's own up
            local d = foot - fr.P(E.Vector(0, 0, B.DeckTop))
            T.near(d:Dot(fr.u), B.Ankle, 0.01,
                name .. " foot an ankle over the deck at a lean of " .. math.deg(lean))
            -- toward the heel edge: a regular rider faces the board's right (-Y)
            T.ok(d:Dot(fr.l) > 1.5, name .. " foot's ankle on the heel side of the middle: " .. d:Dot(fr.l))
        end
        T.ok(math.abs((front - fr.center):Dot(fr.f) - 7.9) < 2, "the front foot by the front truck's bolts")
        T.ok(math.abs((back - fr.center):Dot(fr.f) + 7.9) < 1.2, "the back foot over the back truck's bolts")
        T.near(front.y - back.y, 0, 1e-9, "both feet the same way across the deck")
    end
end)

--------------------------------------------------------------------------
-- The ollie
--------------------------------------------------------------------------

T.test("board ollie: the crouch puts the back foot on the tail, the pop drags the front foot up to the nose, then both level over the bolts", function()
    local _, _, E, B = client()
    T.eq(B.DeckRise(0), 0, "the deck's middle is flat")
    T.eq(B.DeckRise(8), 0, "out to the trucks")
    T.ok(B.DeckRise(11.4) > 0.15 and B.DeckRise(11.4) < 1, "the tail rises where the back foot pops it: " .. B.DeckRise(11.4))
    T.ok(B.DeckRise(-15) > B.DeckRise(-12), "and keeps rising to its end")
    local rest = { B.RiderFeet({ stance = 1 }) }
    local set = { B.RiderFeet({ stance = 1, crouch = 1 }) }
    T.ok(set[2].x < -10.5, "crouched: the back foot is on the tail: " .. set[2].x)
    T.near(set[2].z, B.FootZ + B.DeckRise(set[2].x), 1e-9, "standing ON the tail, which is kicked up")
    T.ok(set[1].x < rest[1].x, "and the front foot has come back off the bolts")
    local pop = { B.RiderFeet({ stance = 1, airT = 0.1, ollie = true }) }
    T.ok(pop[1].x > rest[1].x + 1.5, "popped: the front foot drags up toward the nose: " .. pop[1].x)
    T.near(pop[1].z, B.FootZ + B.DeckRise(pop[1].x), 1e-9, "along the deck's top")
    T.ok(pop[2].x < -10.5, "while the back foot is still on the tail")
    local high = { B.RiderFeet({ stance = 1, airT = 0.6, ollie = true }) }
    T.near((high[1] - rest[1]):Length(), 0, 1e-9, "levelled: the front foot back over its bolts")
    T.near((high[2] - rest[2]):Length(), 0, 1e-9, "and the back foot over its")
    local drop = { B.RiderFeet({ stance = 1, airT = 0.1, ollie = false }) }
    T.near((drop[1] - rest[1]):Length(), 0, 1e-9, "rolling off a drop is not an ollie: the feet stay put")
    local nollie = { B.RiderFeet({ stance = 1, airT = 0.05, ollie = true, nollie = true }) }
    T.ok(nollie[1].x > 10.5, "a nollie pops the nose with the front foot: " .. nollie[1].x)
    T.ok(nollie[2].x > rest[2].x, "and drags the back foot up toward the tail... from the middle")
end)

--------------------------------------------------------------------------
-- The flips
--------------------------------------------------------------------------

-- Run a flip through its angles as the client sees them (a byte each, followed) and
-- return the most each foot went sideways, and their offsets at the catch.
local function flipFeet(B, id, nollie)
    local f = B.Flips[id]
    local st = {}
    local rest = { B.RiderFeet({ stance = 1 }) }
    local most = { 0, 0 }
    local last
    for i = 0, 40 do
        local t = f.dur * i / 40
        local r, y, p = B.UnpackBits(B.PackBits(B.FlipAngles(f, t)))
        B.TrackFlip(st, r, y, p)
        st.roll, st.yaw, st.pitch = r, y, p
        local fr, bk = B.RiderFeet({ stance = 1, airT = 0.4, ollie = true, flip = st, nollie = nollie })
        local d1, d2 = fr - rest[1], bk - rest[2]
        if math.abs(d1.y) > math.abs(most[1]) then most[1] = d1.y end
        if math.abs(d2.y) > math.abs(most[2]) then most[2] = d2.y end
        last = { d1, d2 }
    end
    return most, last
end

T.test("board flips: the flick goes off the edge the deck's top rolls toward, the scoop goes with the tail, and the feet come down for the catch", function()
    local _, _, E, B = client()
    local kick = flipFeet(B, "kickflip")
    local heel = flipFeet(B, "heelflip")
    T.ok(kick[1] < -3, "a kickflip (roll +, top toward -Y): the front foot flicks off toward -Y: " .. kick[1])
    T.ok(heel[1] > 3, "a heelflip: off the other edge: " .. heel[1])
    T.ok(math.abs(kick[2]) < 0.5, "the back foot only pops")
    local shove = flipFeet(B, "popshove")
    local front = flipFeet(B, "frontshove")
    T.ok(shove[2] < -2.5, "a pop shove-it (yaw +, tail toward -Y): the back foot scoops with the tail: " .. shove[2])
    T.ok(front[2] > 2.5, "a front shove-it the other way: " .. front[2])
    local nk = flipFeet(B, "kickflip", true)
    T.ok(nk[2] < -3, "a nollie kickflip is flicked by the back foot: " .. nk[2])
    for _, id in ipairs(B.FlipOrder) do
        local _, last = flipFeet(B, id)
        T.ok(last[1]:Length() < 0.6 and last[2]:Length() < 0.6,
            id .. ": both feet back on the deck at the catch: " .. last[1]:Length() .. ", " .. last[2]:Length())
    end
    -- and mid-kickflip both feet are up off the deck it is turning under them
    local st = {}
    local r = B.FlipAngles(B.Flips.kickflip, B.Flips.kickflip.dur * 0.3)
    B.TrackFlip(st, r, 0, 0)
    st.roll, st.yaw, st.pitch = r, 0, 0
    local fr, bk = B.RiderFeet({ stance = 1, airT = 0.4, ollie = true, flip = st })
    T.ok(fr.z > B.FootZ + 3 and bk.z > B.FootZ + 3, "both feet up out of its way: " .. fr.z .. ", " .. bk.z)
end)

--------------------------------------------------------------------------
-- The arms and the hips
--------------------------------------------------------------------------

T.test("board arms: down with the crouch, up and out in the air, wide and see-sawing on a manual, swung against the pushing leg", function()
    local _, _, E, B = client()
    local lead, trail = B.RiderHands({ stance = 1 })
    T.ok(lead.x > 8 and trail.x < -8, "out along the board, the lead hand on the nose's side")
    T.ok(lead.y < 0 and trail.y < 0, "in front of a rider facing the board's right")
    local cl_, ct_ = B.RiderHands({ stance = 1, crouch = 1, drop = 4 })
    T.ok(cl_.z < lead.z - 3, "a crouch takes the hands down with the shoulders")
    local al, at = B.RiderHands({ stance = 1, airT = 0.3 })
    T.ok(al.z > lead.z + 4 and at.z > trail.z + 4, "up in the air")
    local ml, mt = B.RiderHands({ stance = 1, balance = 0.8 })
    T.ok(ml.x > lead.x + 3 and mt.x < trail.x - 3, "out wide on a manual")
    T.ok(ml.z - mt.z > 8, "and see-sawing as the meter drifts: " .. (ml.z - mt.z))
    local _, gt = B.RiderHands({ stance = -1 })
    T.ok(gt.y > 0, "goofy faces the board's left")
    local g = B.PushGeo(B.Tune, -1)
    local a, b = B.PushMarks(g)
    local pl, pt = B.RiderHands({ stance = 1, pushW = 1, push = a })
    local ql, qt = B.RiderHands({ stance = 1, pushW = 1, push = b })
    T.ok(qt.x > pt.x + 4, "as the pushing foot goes back, its own side's arm swings forward")
    T.ok(ql.x < pl.x - 3, "and the other arm back")
    -- a lean takes the arms over with the body
    local ll = B.RiderHands({ stance = 1, lean = math.rad(20) })
    T.ok(ll.y < lead.y - 2, "leaning right, the arms go right with the body")
end)

T.test("board hips: a push turns the hips and the toes up the board, measured on the skeleton, and getting off puts them back", function()
    local sv, cl, E, B = client()
    local bike = cl:clientEntity("bmx_skateboard")
    bike:SetPos(E.Vector(0, 0, 1.3))
    local pod = cl.makeEntity("prop_vehicle_prisoner_pod")
    pod:SetParent(bike)
    bike:SetPod(pod)
    local ply = cl:player("Rider")
    ply._vehicle = pod
    local function hips()
        ply:InvalidateBoneCache()
        local r = ply:GetBoneMatrix(ply:LookupBone("ValveBiped.Bip01_R_Thigh")):GetTranslation()
        local l = ply:GetBoneMatrix(ply:LookupBone("ValveBiped.Bip01_L_Thigh")):GetTranslation()
        local d = l - r
        return math.deg(math.atan2(d.y, d.x))
    end
    local y0 = hips()
    B.TurnPelvis(ply, 40)
    local turned = (hips() - y0 + 540) % 360 - 180
    T.near(turned, 40, 4, "the hips came round 40 degrees anticlockwise: " .. turned)
    B.TurnPelvis(ply, -30)
    turned = (hips() - y0 + 540) % 360 - 180
    T.near(turned, -30, 4, "and the other way for the other stance: " .. turned)
    E.BMX.ClearRiderPose(ply)
    T.near((hips() - y0 + 540) % 360 - 180, 0, 1e-6, "off the board, square again")
    -- the IK's facing turns toward the nose with the push's weight
    local f0 = B.FacingFor(bike, 1, 0)
    local f1 = B.FacingFor(bike, 1, 1)
    T.near(f0:Dot(bike:GetForward()), 0, 1e-6, "riding, the toes point across the board")
    T.ok(f1:Dot(bike:GetForward()) > 0.8, "pushing, up it: " .. f1:Dot(bike:GetForward()))
    T.ok(f1:Dot(f0) > 0.3, "turned from the side the rider faces, not from behind")
end)
