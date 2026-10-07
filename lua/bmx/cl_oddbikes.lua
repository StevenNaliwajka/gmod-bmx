--[[--------------------------------------------------------------------------
    bmx/cl_oddbikes.lua

    THE DRAWING OF THE ODD ONES (G13), in code like the stock bike's: a unicycle, a
    penny-farthing and a tandem. No model, no material but the base game's.

    WHY THEY DRAW THEMSELVES. ENT:Draw (entities/bmx_base/cl_init.lua) is the stock bike
    from the first line: two wheels on the same radius, a fork on the front one, a seat
    tube at the rear. A unicycle has no front wheel; a penny-farthing's two wheels are
    26 and 6 units and its seat is over the big one; a tandem has two saddles, two sets
    of cranks and two sets of bars. A vehicle names one of the functions here as its
    `drawer`, and the entity hands itself over to it with its own primitives (BMX.Draw:
    tube, joint, solid, ring, the wheel and the axle trace), so these look like the rest.

    Every one of them does what Draw does for the bike and no more:
      * the wheels where the simulation has them (the same downward trace, the same disc
        contact: the wheels turn red under bmx_debug when there is no ground)
      * the frame, drawn from the vehicle's own registered geometry and the static sag
      * the cranks and pedals turning with the driven wheel, and the rider's hands and
        feet recorded as IK targets (bike.ikTargets) for cl_rider.lua
      * the paint (the palette colour the owner picked)
    and nothing of the bike's tricks (frame spins, poses, brake cable): none of these has
    them.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Drawers = BMX.Drawers or {}

local function wheelDefs(ent)
    return BMX.WheelDefs(ent:Bike(), ent:Cfg())
end

-- The static sag the frame is drawn lifted by, as the bike's drawing does it, for a
-- vehicle whose weight the wheels share by `loadShare`.
local function sagOf(C)
    local g = physenv.GetGravity():Length()
    return math.Clamp(C.Chassis.mass * g * (C.Wheel.loadShare or 0.5) / C.Wheel.spring, 0, C.Wheel.restLength)
end

-- One wheel's drawn spin: the angle it has turned, kept per wheel on the entity. On the
-- ground it rolls at the vehicle's forward speed; off it, it winds down slowly (the
-- bike's rule, ENT:WheelSpin, but for a wheel of ANY radius).
local function spinOf(ent, key, radius, grounded, dt)
    ent.oddSpin = ent.oddSpin or {}
    local w = ent.oddSpin[key] or { angle = 0, rate = 0 }
    ent.oddSpin[key] = w
    if grounded then
        w.rate = ent:GetVelocity():Dot(ent:GetForward()) / radius
    else
        w.rate = w.rate * math.exp(-0.5 * dt)
    end
    w.angle = w.angle + w.rate * dt
    return w.angle
end
BMX.OddSpin = spinOf

-- The wheel's axle point and whether it found ground, at every level of detail.
local function axleOf(ent, H, wd, C, lod, sag)
    local lift = C.Wheel.restLength
    local r = wd.radius or C.Wheel.radius
    if lod >= 2 then
        return ent:LocalToWorld(wd.pos + Vector(0, 0, sag)), ent:GetGrounded()
    end
    return H.axle(ent, wd.pos + Vector(0, 0, lift), r)
end

-- The two cranks and pedals on a hub, and the IK targets for the feet. `angle` is the
-- crank's angle as the wheel has turned it (a fixed gear, a penny's direct drive).
local function cranks(ent, H, hub, fwd, up, right, angle, len, q, ik, lod, col)
    for _, side in ipairs({ 1, -1 }) do
        local t = angle + (side == 1 and 0 or math.pi)
        local arm = (fwd * math.cos(t) - up * math.sin(t)) * len
        local root = hub + right * (q * side)
        local pedal = root + arm
        ik[side == 1 and "rFoot" or "lFoot"] = pedal + right * (1.8 * side) + up * 0.9
        if lod < 2 then H.tube(root, pedal, 0.9, H.COL.part) end
        if lod == 0 then
            H.solid("box", pedal + right * (1.8 * side), fwd:AngleEx(up), Vector(3.6, 3.6, 1.0), H.COL.part, H.MAT.matte)
        end
    end
    if lod == 0 then H.tube(hub - right * q, hub + right * q, 1.3, H.COL.part) end
end

--------------------------------------------------------------------------
-- THE UNICYCLE. A wheel, a fork over it (two blades to a crown), a seat post and a
-- saddle, cranks on the hub, and the rider's arms out to the sides for balance.
--------------------------------------------------------------------------
BMX.Drawers.unicycle = function(ent, H, lod, debug)
    local bike, C = ent:Bike(), ent:Cfg()
    local dt = FrameTime()
    local fwd, up, right = ent:GetForward(), ent:GetUp(), ent:GetRight()
    local sag = sagOf(C)
    local wd = wheelDefs(ent)[1]
    local r = wd.radius or C.Wheel.radius
    local col = BMX.PaletteColor(ent:GetColorIndex())

    render.SetColorMaterial()
    local hub, hit = axleOf(ent, H, wd, C, lod, sag)
    local spin = spinOf(ent, "wheel", r, hit, dt)
    H.wheel(ent, "wheel", hub, right, spin, r, hit, debug, lod)

    -- The fork: two blades from the hub to a crown over the tyre, and the seat post
    -- up from the crown to the saddle at the rider's seat.
    local crown = hub + up * (r + 2.5)
    local seat = ent:LocalToWorld(Vector(0, 0, C.Chassis.seatOffset.z + sag - 1.5))
    for _, side in ipairs({ 1, -1 }) do
        local off = right * (2.2 * side)
        H.tube(hub + off, crown + off, 1.1, col)
    end
    H.tube(crown - right * 2.2, crown + right * 2.2, 1.4, col)
    H.tube(crown, seat, 1.3, H.COL.chrome)
    H.solid("sph", seat + up * 0.8, ent:GetAngles(), Vector(9, 4, 2), H.COL.part, H.MAT.matte)
    if lod == 0 then H.joint(crown, 2.4, col) end

    local ik = {}
    cranks(ent, H, hub, fwd, up, right, spin, 6.5, 3.2, ik, lod, col)
    -- Arms out to the sides, a little forward and up: a unicyclist's wings.
    ik.rHand = seat + right * 15 + fwd * 3 + up * 9
    ik.lHand = seat - right * 15 + fwd * 3 + up * 9
    ik.rHandA, ik.rHandB = ik.rHand, ik.rHand
    ik.lHandA, ik.lHandB = ik.lHand, ik.lHand
    ent.ikTargets = ik
    ent.crankAngle = spin
end

--------------------------------------------------------------------------
-- THE PENNY-FARTHING. A very large front wheel with the cranks on its hub, a very small
-- one at the back, a backbone from the fork crown to the small wheel's fork, the saddle
-- on it over the big wheel and the bars over the saddle's front. The rider sits a
-- long way up.
--------------------------------------------------------------------------
BMX.Drawers.pennyfarthing = function(ent, H, lod, debug)
    local bike, C = ent:Bike(), ent:Cfg()
    local dt = FrameTime()
    local fwd, up, right = ent:GetForward(), ent:GetUp(), ent:GetRight()
    local sag = sagOf(C)
    local wds = wheelDefs(ent)
    local fwdDef, rearDef = wds[1], wds[2]
    local col = BMX.PaletteColor(ent:GetColorIndex())
    local rf = fwdDef.radius or C.Wheel.radius
    local rr = rearDef.radius or C.Wheel.rearRadius or 6

    render.SetColorMaterial()
    -- The big wheel steers (the fork turns the whole front end), the small one does not.
    local steer = BMX.VisualSteer(ent:GetSteer(), ent:GetSpeedUPS(), C)
    local sFwd, fAxle = fwd, right
    if steer ~= 0 then
        local c, s = math.cos(steer), math.sin(steer)
        sFwd = fwd * c + right * s
        fAxle = sFwd:Cross(up)
        fAxle:Normalize()
    end
    local fPos, fHit = axleOf(ent, H, fwdDef, C, lod, sag)
    local rPos, rHit = axleOf(ent, H, rearDef, C, lod, sag)
    local fSpin = spinOf(ent, "front", rf, fHit, dt)
    local rSpin = spinOf(ent, "rear", rr, rHit, dt)
    H.wheel(ent, "front", fPos, fAxle, fSpin, rf, fHit, debug, lod)
    H.wheel(ent, "rear", rPos, right, rSpin, rr, rHit, debug, lod)

    -- The fork: two blades up from the big hub to a crown over the tyre's top.
    local crown = fPos + up * (rf + 3)
    for _, side in ipairs({ 1, -1 }) do
        local off = fAxle * (2.6 * side)
        H.tube(fPos + off, crown + off, 1.2, H.COL.part)
    end
    H.tube(crown - fAxle * 2.6, crown + fAxle * 2.6, 1.5, H.COL.part)
    -- The bars, a plain bar over the crown and a stem up to it.
    local barsC = crown + up * 5 + sFwd * 1
    H.tube(crown, barsC, 1.3, H.COL.part)
    H.tube(barsC - fAxle * 11, barsC + fAxle * 11, 1.0, H.COL.part)
    local gripL, gripR = barsC - fAxle * 12, barsC + fAxle * 12

    -- The backbone: from the crown, curving down and back to the small wheel's fork, and
    -- the saddle on it a little behind the big wheel's top.
    local backbone = crown - sFwd * 4
    local saddle = ent:LocalToWorld(Vector(C.Chassis.seatOffset.x, 0, C.Chassis.seatOffset.z + sag - 2))
    H.tube(crown, saddle, 1.6, col)
    H.tube(saddle, rPos + up * (rr + 2.5), 1.6, col)
    H.tube(rPos + up * (rr + 2.5) + right * 1.8, rPos + right * 1.8, 1.0, H.COL.part)
    H.tube(rPos + up * (rr + 2.5) - right * 1.8, rPos - right * 1.8, 1.0, H.COL.part)
    H.solid("sph", saddle + up * 1.5, ent:GetAngles(), Vector(9, 4, 2), H.COL.part, H.MAT.matte)
    if lod == 0 then H.joint(crown, 2.6, col) end

    local ik = {}
    cranks(ent, H, fPos, sFwd, up, fAxle, fSpin, 8, 4.5, ik, lod, col)
    ik.rHand = gripR - fAxle * 1.5
    ik.lHand = gripL + fAxle * 1.5
    ik.rHandA, ik.rHandB = ik.rHand, gripR
    ik.lHandA, ik.lHandB = ik.lHand, gripL
    ent.ikTargets = ik
    ent.crankAngle = fSpin
end

--------------------------------------------------------------------------
-- THE TANDEM. A long frame with two saddles, two sets of bars (the stoker holds
-- their own, fixed), and TWO sets of cranks on a timing chain, which is why they turn
-- together. The geometry is the registration's: where the seats are says where the
-- bottom brackets go.
--------------------------------------------------------------------------
BMX.Drawers.tandem = function(ent, H, lod, debug)
    local bike, C = ent:Bike(), ent:Cfg()
    local dt = FrameTime()
    local fwd, up, right = ent:GetForward(), ent:GetUp(), ent:GetRight()
    local sag = sagOf(C)
    local half = C.Wheel.wheelbase * 0.5
    local wds = wheelDefs(ent)
    local col = BMX.PaletteColor(ent:GetColorIndex())
    local r = C.Wheel.radius
    local function P(v) return ent:LocalToWorld(v + Vector(0, 0, sag)) end

    render.SetColorMaterial()
    local steer = BMX.VisualSteer(ent:GetSteer(), ent:GetSpeedUPS(), C)
    local sFwd, fAxle = fwd, right
    if steer ~= 0 then
        local c, s = math.cos(steer), math.sin(steer)
        sFwd = fwd * c + right * s
        fAxle = sFwd:Cross(up)
        fAxle:Normalize()
    end
    local fPos, fHit = axleOf(ent, H, wds[1], C, lod, sag)
    local rPos, rHit = axleOf(ent, H, wds[2], C, lod, sag)
    local fSpin = spinOf(ent, "front", r, fHit, dt)
    local rSpin = spinOf(ent, "rear", r, rHit, dt)
    H.wheel(ent, "front", fPos, fAxle, fSpin, r, fHit, debug, lod)
    H.wheel(ent, "rear", rPos, right, rSpin, r, rHit, debug, lod)

    -- The frame: a head tube over the front wheel, a long top tube to the rear seat
    -- tube, two seat tubes, a down tube between the two bottom brackets (the long
    -- one the timing chain runs along), stays to the rear wheel.
    local capSeat = BMX.SeatFor(bike, C, "rider")
    local stkSeat = BMX.SeatFor(bike, C, "pegs")
    local headT = P(Vector(half - 3, 0, r + 8))
    local headB = P(Vector(half - 1, 0, r - 1))
    local sj1 = P(Vector(capSeat.offset.x, 0, r + 2))        -- the captain's seat tube foot
    local sj2 = P(Vector(stkSeat.offset.x, 0, r + 2))        -- the stoker's
    local bb1 = P(Vector(capSeat.offset.x + 1, 0, 1.5))
    local bb2 = P(Vector(stkSeat.offset.x + 1, 0, 1.5))
    local seat1 = P(Vector(capSeat.offset.x, 0, capSeat.offset.z - 1))
    local seat2 = P(Vector(stkSeat.offset.x, 0, stkSeat.offset.z - 1))
    H.tube(headT, sj1, 1.7, col)
    H.tube(headB, bb1, 2.0, col)
    H.tube(bb1, bb2, 1.8, col)
    H.tube(sj1, sj2, 1.7, col)
    H.tube(sj2, bb2, 1.6, col)
    H.tube(bb1, sj1, 1.6, col)
    H.tube(headT, headB, 2.0, col)
    for _, side in ipairs({ 1, -1 }) do
        local off = right * (1.7 * side)
        H.tube(bb2 + off, rPos + off, 1.0, col)
        H.tube(sj2 + off, rPos + off, 1.0, col)
        H.tube(headB + fAxle * (2.0 * side), fPos + fAxle * (2.0 * side), 1.1, H.COL.part)
    end
    for _, s in ipairs({ { sj1, seat1 }, { sj2, seat2 } }) do
        H.tube(s[1], s[2], 1.1, H.COL.chrome)
        H.solid("sph", s[2] + up * 0.8, ent:GetAngles(), Vector(9.5, 4, 2), H.COL.part, H.MAT.matte)
    end

    -- The captain's bars, steered with the front wheel; the stoker's, fixed to the
    -- seat tube behind the captain, which is where a tandem's stoker holds on.
    local barsC = headT + up * 3 + sFwd * -1
    H.tube(headT, barsC, 1.3, H.COL.part)
    H.tube(barsC - fAxle * 11, barsC + fAxle * 11, 1.0, H.COL.part)
    local stoker = seat1 + up * 11 + fwd * -1
    H.tube(sj1 + up * 0.5, stoker, 1.0, H.COL.part)
    H.tube(stoker - right * 9, stoker + right * 9, 0.9, H.COL.part)

    -- The cranks: both bottom brackets, turning together with the wheel (a timing chain
    -- between them; the drivetrain's own is a ring on the left of the rear one).
    local ik, ikS = {}, {}
    local angle = rSpin / (C.Drive.gearRatio or 1)
    cranks(ent, H, bb1, fwd, up, right, angle, 6.5, 3.4, ik, lod, col)
    cranks(ent, H, bb2, fwd, up, right, angle, 6.5, 3.4, ikS, lod, col)
    H.tube(bb1 - right * 3, bb2 - right * 3, 0.5, H.COL.part)
    if lod < 2 then H.ring(bb2 - right * 3, fwd, up, 4.5, 0.6, H.COL.chrome, lod == 0 and 14 or 6) end

    local gripL, gripR = barsC - fAxle * 12, barsC + fAxle * 12
    ik.rHand, ik.lHand = gripR - fAxle * 1.5, gripL + fAxle * 1.5
    ik.rHandA, ik.rHandB, ik.lHandA, ik.lHandB = ik.rHand, gripR, ik.lHand, gripL
    ent.ikTargets = ik
    ent.ikTargetsStoker = ikS
    ikS.rHand, ikS.lHand = stoker + right * 8, stoker - right * 8
    ent.crankAngle = angle
end

--------------------------------------------------------------------------
-- THE BIKE LOCK, drawn (G13, sv_lock.lua): a chain looped round the rear wheel and down to
-- the ground, and a padlock where it closes. For every vehicle, whoever draws it: the
-- bike's own Draw and the drawers above both call it when the bike's `Locked` is set.
--------------------------------------------------------------------------
function BMX.DrawLock(ent)
    local H = BMX.Draw
    if not H then return end
    local C = ent:Cfg()
    local fwd, up, right = ent:GetForward(), ent:GetUp(), ent:GetRight()
    local half = C.Wheel.wheelbase * 0.5
    local r = C.Wheel.radius
    local hub = ent:LocalToWorld(Vector(-half, 0, 0))
    local col = H.COL.chrome
    -- The links: a ring in the wheel's plane, a little inside the tyre, not turning.
    H.ring(hub + right * 3, fwd, up, r * 0.78, 0.9, col, 14)
    -- ...and the chain from the ring to the ground, and a padlock at the join.
    local foot = hub - up * (r + 1) + fwd * 2
    local at = hub - up * (r * 0.78) + right * 3
    H.tube(at, foot + right * 3, 0.9, col)
    H.solid("box", at - up * 2, ent:GetAngles(), Vector(3.2, 2.2, 4), H.COL.part, H.MAT.satin)
end
