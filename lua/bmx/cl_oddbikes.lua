--[[--------------------------------------------------------------------------
    bmx/cl_oddbikes.lua

    THE DRAWING OF THE ODD ONES (G13): a unicycle and a penny-farthing. (The tandem
    is bike-shaped enough for the bike's own drawing: its model, cl_geo_odd.lua,
    gives DrawDetailed a second bottom bracket and the stoker's grips.)

    WHY THEY DRAW THEMSELVES. ENT:Draw (entities/bmx_base/cl_init.lua) places a bike's
    model by a front and a rear axle, a fork on the front one and cranks at a bottom
    bracket. A unicycle has no front wheel and its cranks are on its only hub; a
    penny-farthing's two wheels are 26 and 6 units and its cranks are on the big
    wheel's hub, steered with it. A vehicle names one of the functions here as its
    `drawer`, and the entity hands itself over to it with its own primitives (BMX.Draw:
    tube, joint, solid, ring, the wheel and the axle trace).

    THE MODEL. Each is drawn as its real 3D model (cl_geo_odd.lua: kinds "unicycle"
    and "penny", the registration's `look`), group by group through BMX.BikeMesh, each
    group under a matrix from the same physics the simple drawing uses: the wheels'
    traced axles and spin, the steer, the crank angle. While the model is still being
    built (BikeMesh.Get hands back nil until it is), with bmx_bike_model 0 or under
    bmx_debug, the simple drawing from shapes is drawn instead, as ENT:Draw does for
    the bike.

    Every one of them does what Draw does for the bike and no more:
      * the wheels where the simulation has them (the same downward trace, the same disc
        contact: the simple wheels turn red under bmx_debug when there is no ground)
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
-- THE MODEL, group by group (BMX.BikeMesh)
--------------------------------------------------------------------------

-- Rodrigues, on Vectors.
local function rotVec(v, axis, ang)
    if ang == 0 then return v end
    local c, s = math.cos(ang), math.sin(ang)
    return v * c + axis:Cross(v) * s + axis * (axis:Dot(v) * (1 - c))
end

-- `m` turned by `ang` about the model's y axis (the axles' direction) through `c`.
local function turnY(m, c, ang)
    local x, z = m.x - c.x, m.z - c.z
    local co, si = math.cos(ang), math.sin(ang)
    return Vector(c.x + x * co + z * si, m.y, c.z - x * si + z * co)
end

-- The matrix taking model space to the world through a map of points.
local function matOf(f)
    local o = f(Vector(0, 0, 0))
    return BMX.BikeMesh.Matrix(o, f(Vector(1, 0, 0)) - o, f(Vector(0, 1, 0)) - o, f(Vector(0, 0, 1)) - o)
end

-- This vehicle's model (its `look`, at its registry's sizes), or nil: while it is
-- being built, with bmx_bike_model 0, under bmx_debug, or with no BikeMesh at all.
local function modelOf(ent, C, debug)
    local bike = ent:Bike()
    local BM = BMX.BikeMesh
    if debug or not bike.look or not BM or not BM.Get then return nil end
    local WC = C.Wheel
    local so = C.Chassis.seatOffset
    return BM.Get(math.max(WC.wheelbase, 1) / 39, WC.radius, bike.look, {
        wheelbase = WC.wheelbase, rearRadius = WC.rearRadius, restLength = WC.restLength,
        seat = { so.x, so.y, so.z },
    })
end
BMX.OddModel = modelOf

-- Where a hand holds a grip from A (inner end) to B (outer): the IK slides it
-- along, `hold` is its middle (as DrawDetailed does it).
local function gripOf(map, g)
    local A, B = map(g.A), map(g.B)
    local d = B - A
    return A + d:GetNormalized() * math.min(1.75, d:Length() * 0.5), A, B
end

--------------------------------------------------------------------------
-- THE UNICYCLE. A wheel, a fork over it (two blades to a crown), a seat post and a
-- saddle, cranks on the hub, and the rider's arms out to the sides for balance.
--------------------------------------------------------------------------

-- The model: the frame rides the hub (the fork's bearings are on it), square to the
-- chassis; the wheel and the cranks fixed to its axle turn together; a pedal at each
-- crank's tip, level.
local function unicycleModel(ent, model, hub, fwd, up, right, spin, lod, col, ik)
    local BM = BMX.BikeMesh
    local L = model.layout
    local left = -right
    local function frameMap(m) return hub + fwd * m.x + left * m.y + up * m.z end
    local zero = Vector(0, 0, 0)
    local function wheelMap(m) return frameMap(turnY(m, zero, spin)) end
    local function tip(side)
        return turnY(Vector(L.crank * side, 0, 0), zero, spin) + Vector(0, -L.pedalY * side, 0)
    end
    BM.BeginLighting(hub + up * 10, ent)
        BM.DrawGroup(model, "frame", matOf(frameMap), col, lod)
        BM.DrawGroup(model, "wheel", matOf(wheelMap), col, lod)
        BM.DrawGroup(model, "cranks", matOf(wheelMap), col, lod)
        for _, side in ipairs({ 1, -1 }) do
            local t = tip(side)
            BM.DrawGroup(model, "pedal", matOf(function(m) return frameMap(t + m) end), col, lod)
        end
    BM.EndLighting()
    ik.rFoot = frameMap(tip(1)) + up * 0.9
    ik.lFoot = frameMap(tip(-1)) + up * 0.9
end

BMX.Drawers.unicycle = function(ent, H, lod, debug)
    local bike, C = ent:Bike(), ent:Cfg()
    local dt = FrameTime()
    local fwd, up, right = ent:GetForward(), ent:GetUp(), ent:GetRight()
    local sag = sagOf(C)
    local wd = wheelDefs(ent)[1]
    local r = wd.radius or C.Wheel.radius
    local col = BMX.PaletteColor(ent:GetColorIndex())

    local hub, hit = axleOf(ent, H, wd, C, lod, sag)
    local spin = spinOf(ent, "wheel", r, hit, dt)
    local seat = ent:LocalToWorld(Vector(0, 0, C.Chassis.seatOffset.z + sag - 1.5))
    local ik = {}

    local model = modelOf(ent, C, debug)
    if model then
        unicycleModel(ent, model, hub, fwd, up, right, spin, lod, col, ik)
    else
        render.SetColorMaterial()
        H.wheel(ent, "wheel", hub, right, spin, r, hit, debug, lod)
        -- The fork: two blades from the hub to a crown over the tyre, and the seat post
        -- up from the crown to the saddle at the rider's seat.
        local crown = hub + up * (r + 2.5)
        for _, side in ipairs({ 1, -1 }) do
            local off = right * (2.2 * side)
            H.tube(hub + off, crown + off, 1.1, col)
        end
        H.tube(crown - right * 2.2, crown + right * 2.2, 1.4, col)
        H.tube(crown, seat, 1.3, H.COL.chrome)
        H.solid("sph", seat + up * 0.8, ent:GetAngles(), Vector(9, 4, 2), H.COL.part, H.MAT.matte)
        if lod == 0 then H.joint(crown, 2.4, col) end
        cranks(ent, H, hub, fwd, up, right, spin, 6.5, 3.2, ik, lod, col)
    end

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
-- one at the back, a backbone from the head down to the small wheel's fork, the saddle
-- on a spring over the big wheel and the bars in front of the saddle. The rider sits a
-- long way up.
--------------------------------------------------------------------------

-- The model: the frame rigid, pitched to sit on both traced axles (as DrawDetailed
-- pitches a rigid bike); the fork, bars, spoon brake, big wheel, cranks and pedals
-- turned with the steer about the head; the cranks with the big wheel's spin.
local function pennyModel(ent, model, S, ik)
    local BM = BMX.BikeMesh
    local L = model.layout
    local up, right = S.up, S.right
    local function P0(m) return ent:LocalToWorld(m + Vector(0, 0, S.sag)) end
    local rA0, fA0 = P0(L.rear), P0(L.front)
    local a, b = fA0 - rA0, S.fPos - S.rPos
    a = a - right * a:Dot(right)
    b = b - right * b:Dot(right)
    local phi = math.atan2(right:Dot(a:Cross(b)), a:Dot(b))
    local rPos = S.rPos
    local function Pf(m) return rPos + rotVec(P0(m) - rA0, right, phi) end
    local upF = rotVec(up, right, phi)
    local headB = Pf(L.headB)
    local axis = (Pf(L.headT) - headB):GetNormalized()
    local function forkMap(m) return headB + rotVec(Pf(m) - headB, axis, -S.steer) end
    local bb = L.bb
    local function crankMap(m) return forkMap(turnY(m, bb, S.fSpin)) end
    local function tip(side)
        return turnY(bb + Vector(L.crank * side, 0, 0), bb, S.fSpin) + Vector(0, -L.pedalY * side, 0)
    end
    local function wheelMat(map, centre, spin)
        return matOf(function(m) return map(turnY(centre + m, centre, spin)) end)
    end
    BM.BeginLighting(ent:LocalToWorld(Vector(0, 0, 20)), ent)
        BM.DrawGroup(model, "frame", matOf(Pf), S.col, S.lod)
        BM.DrawGroup(model, "fork", matOf(forkMap), S.col, S.lod)
        BM.DrawGroup(model, "wheelF", wheelMat(forkMap, L.front, S.fSpin), S.col, S.lod)
        BM.DrawGroup(model, "wheelR", wheelMat(Pf, L.rear, S.rSpin), S.col, S.lod)
        BM.DrawGroup(model, "cranks", matOf(crankMap), S.col, S.lod)
        for _, side in ipairs({ 1, -1 }) do
            local t = tip(side)
            BM.DrawGroup(model, "pedal", matOf(function(m) return forkMap(t + m) end), S.col, S.lod)
        end
    BM.EndLighting()
    ik.rFoot = forkMap(tip(1)) + upF * 0.9
    ik.lFoot = forkMap(tip(-1)) + upF * 0.9
    ik.rHand, ik.rHandA, ik.rHandB = gripOf(forkMap, L.gripR)
    ik.lHand, ik.lHandA, ik.lHandB = gripOf(forkMap, L.gripL)
end

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
    local ik = {}

    local model = modelOf(ent, C, debug)
    if model then
        pennyModel(ent, model, { up = up, right = right, sag = sag, fPos = fPos, rPos = rPos, steer = steer,
                                 fSpin = fSpin, rSpin = rSpin, col = col, lod = lod }, ik)
        ent.ikTargets = ik
        ent.crankAngle = fSpin
        return
    end

    render.SetColorMaterial()
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
    local saddle = ent:LocalToWorld(Vector(C.Chassis.seatOffset.x, 0, C.Chassis.seatOffset.z + sag - 2))
    H.tube(crown, saddle, 1.6, col)
    H.tube(saddle, rPos + up * (rr + 2.5), 1.6, col)
    H.tube(rPos + up * (rr + 2.5) + right * 1.8, rPos + right * 1.8, 1.0, H.COL.part)
    H.tube(rPos + up * (rr + 2.5) - right * 1.8, rPos - right * 1.8, 1.0, H.COL.part)
    H.solid("sph", saddle + up * 1.5, ent:GetAngles(), Vector(9, 4, 2), H.COL.part, H.MAT.matte)
    if lod == 0 then H.joint(crown, 2.6, col) end

    cranks(ent, H, fPos, sFwd, up, fAxle, fSpin, 8, 4.5, ik, lod, col)
    ik.rHand = gripR - fAxle * 1.5
    ik.lHand = gripL + fAxle * 1.5
    ik.rHandA, ik.rHandB = ik.rHand, gripR
    ik.lHandA, ik.lHandB = ik.lHand, gripL
    ent.ikTargets = ik
    ent.crankAngle = fSpin
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
