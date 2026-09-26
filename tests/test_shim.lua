--[[--------------------------------------------------------------------------
    The shim's own conventions, checked against values worked by hand.

    Every other file in tests/ trusts these. If the shim had Source's angle
    convention backwards, every sign test in the suite would pass with the
    addon's signs backwards too, so this is checked first and in isolation.
----------------------------------------------------------------------------]]

local VA = require("lib.vecang")
local gmod = require("lib.gmod")
local V, A = VA.Vector, VA.Angle

local function vnear(got, want, msg)
    T.near(got.x, want.x, 1e-9, msg .. ".x")
    T.near(got.y, want.y, 1e-9, msg .. ".y")
    T.near(got.z, want.z, 1e-9, msg .. ".z")
end

T.test("Angle(0,0,0) is X forward, -Y right, Z up", function()
    local f, r, u = VA.AngleVectors(A(0, 0, 0))
    vnear(f, V(1, 0, 0), "forward")
    vnear(r, V(0, -1, 0), "right")      -- Y is LEFT in Source
    vnear(u, V(0, 0, 1), "up")
end)

T.test("yaw 90 faces +Y (left turn increases yaw)", function()
    vnear(A(0, 90, 0):Forward(), V(0, 1, 0), "forward")
end)

T.test("positive Source pitch is nose DOWN", function()
    T.ok(A(30, 0, 0):Forward().z < 0, "pitch 30 points the nose at the ground")
end)

T.test("positive Source roll puts the right side down", function()
    T.ok(A(0, 0, 20):Right().z < 0, "roll 20 drops the right-hand side")
end)

T.test("basis -> angle round-trips", function()
    for _, a in ipairs({ A(10, 20, 30), A(-35, 170, -60), A(0, -90, 45), A(80, 5, 5) }) do
        local f, r, u = VA.AngleVectors(a)
        local b = VA.BasisAngle(f, -r, u)
        local g, s, w = VA.AngleVectors(b)
        vnear(g, f, "forward of " .. tostring(a))
        vnear(s, r, "right of " .. tostring(a))
        vnear(w, u, "up of " .. tostring(a))
    end
end)

T.test("vector algebra matches GMod", function()
    local a, b = V(1, 2, 3), V(4, 5, 6)
    vnear(a + b, V(5, 7, 9), "add")
    vnear(a * 2, V(2, 4, 6), "scale")
    vnear(2 * a, V(2, 4, 6), "scale left")
    vnear(a * b, V(4, 10, 18), "component-wise")
    T.eq(a:Dot(b), 32, "dot")
    vnear(V(1, 0, 0):Cross(V(0, 1, 0)), V(0, 0, 1), "x cross y")
    local n = V(3, 4, 0)
    n:Normalize()
    T.near(n:Length(), 1, 1e-12, "Normalize is in place")
end)

T.test("an entity's LocalToWorld honours Y-left", function()
    local world = gmod.World()
    local R = gmod.Realm(world, "server")
    local e = R.makeEntity("thing")
    e:SetPos(V(10, 0, 0))
    e:SetAngles(A(0, 90, 0))
    -- Facing +Y: local forward is world +Y, local left is world -X.
    vnear(e:LocalToWorld(V(1, 0, 0)), V(10, 1, 0), "forward")
    vnear(e:LocalToWorld(V(0, 1, 0)), V(9, 0, 0), "left")
end)

T.test("an impulse is an impulse, and an off-centre one spins", function()
    local world = gmod.World({ gravity = 0 })
    local R = gmod.Realm(world, "server")
    local e = R.makeEntity("thing")
    e:PhysicsInitBox(V(-18, -4, 2), V(14, 4, 38))
    local p = e:GetPhysicsObject()
    p:SetMass(86)
    p:ApplyForceCenter(V(0, 0, 86 * 100))
    T.near(p:GetVelocity().z, 100, 1e-9, "dv = J/m")

    -- The stock hull reproduces the MEASURED inertia the addon was tuned on.
    local I = p:InertiaU2()
    T.near(I.x, 9299, 0.5, "roll inertia")
    T.near(I.y, 11837, 0.5, "pitch inertia")
    T.near(I.z, 7353, 0.5, "yaw inertia")

    p:SetVelocity(V())
    local com = p:COM()
    -- Push +Y (left) at a point above the COM: the top goes left, which is
    -- rolling LEFT, which is a negative angular velocity about forward.
    p:ApplyForceOffset(V(0, 100, 0), com + V(0, 0, 10))
    T.ok(p.w:Dot(e:GetForward()) < 0, "pushing the top left rolls it left")
end)

T.test("bit ops agree with LuaJIT for the flags the input code uses", function()
    local bit = gmod.bit
    T.eq(bit.band(2 + 8, 8), 8, "band")
    T.eq(bit.bor(2, 4), 6, "bor")
    T.eq(bit.band(2 + 4 + 8, bit.bnot(bit.bor(2, 4))), 8, "strip JUMP and DUCK")
end)

T.test("the net wire rejects a read that does not match its write", function()
    local world = gmod.World()
    local sv = gmod.Realm(world, "server")
    local cl = gmod.Realm(world, "client")
    sv.env.util.AddNetworkString("x")
    sv.env.net.Start("x")
    sv.env.net.WriteFloat(1.5)
    sv.env.net.WriteBool(true)
    sv.env.net.Send(nil)

    cl.env.net.Receive("x", function()
        cl.env.net.ReadBool()          -- wrong order
    end)
    T.errors(function() cl:deliver(world.wire[1]) end, "disagree", "type mismatch")

    cl.env.net.Receive("x", function() cl.env.net.ReadFloat() end)
    T.errors(function() cl:deliver(world.wire[1]) end, "read 1 of 2", "short read")
end)
