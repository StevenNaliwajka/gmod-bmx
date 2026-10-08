--[[--------------------------------------------------------------------------
    Frozen solids stay frozen.

    VPhysics trap, measured on a real server (2026-10-08): PhysObj:SetMaterial
    on a body that is ALREADY frozen thaws it inside the engine while
    IsMotionEnabled() goes on answering false. A bike pressing a 20 u kerb
    built that way pushed it 3-6 u per ride at 50,000 kg (100-160 u at 500 kg);
    under MOVETYPE_NONE the body slid out from under the entity, so traces hit
    a kerb the hull rode straight into and the wheels sank in. That was
    petopia_bmx_fall's bmx_city_solid. The shim models the trap (tests/lib/
    gmod.lua, Phys.thawed); these hold every frozen solid the addon builds to
    the right order: material first, then EnableMotion(false).
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

T.test("frozen solids: the shim thaws a frozen body whose material is set after the freeze", function()
    local sv = F.server()
    local env = sv.env
    local e = env.ents.Create("bmx_test_solid")
    local V = env.Vector
    e.CustomHulls = { { V(0, 0, 0), V(10, 0, 0), V(10, 10, 0), V(0, 10, 0),
                        V(0, 0, 20), V(10, 0, 20), V(10, 10, 20), V(0, 10, 20) } }
    e:SetPos(V(5, 5, 10))
    e:Spawn()
    local p = e:GetPhysicsObject()
    T.eq(p.motion, false, "frozen")
    T.ok(not p.thawed, "and really frozen")
    p:SetMaterial("metal")
    T.ok(p.thawed, "a material after the freeze thaws it")
    T.eq(p:IsMotionEnabled(), false, "while IsMotionEnabled still says false (the trap)")
    p:EnableMotion(false)
    T.ok(not p.thawed, "freezing again after the material holds")
end)

T.test("frozen solids: bmx_test_solid (the headless suite's kerbs and walls) is really frozen", function()
    local sv = F.server()
    local env = sv.env
    local V = env.Vector
    local e = env.ents.Create("bmx_test_solid")
    e.CustomHulls = {
        { V(0, 0, 0), V(84, 0, 0), V(84, 400, 0), V(0, 400, 0),
          V(0, 0, 20), V(84, 0, 20), V(84, 400, 20), V(0, 400, 20) },
        { V(30, 30, 20), V(50, 30, 20), V(50, 50, 20), V(30, 50, 20),
          V(30, 30, 440), V(50, 30, 440), V(50, 50, 440), V(30, 50, 440) },
    }
    e:SetPos(V(42, 200, 10))
    e:Spawn()
    local p = e:GetPhysicsObject()
    T.eq(#p.boxes, 2, "both hulls in one body")
    T.eq(p.motion, false, "frozen")
    T.ok(not p.thawed, "material set before the freeze, not after")
end)

T.test("frozen solids: every park piece is really frozen", function()
    local sv = F.server()
    local env = sv.env
    local n = 0
    for class, t in pairs(sv.stored) do
        if t.ParkShape then
            local e = env.ents.Create(class)
            e:SetPos(env.Vector(0, 0, 0))
            e:Spawn()
            local p = e:GetPhysicsObject()
            T.eq(p.motion, false, class .. " frozen")
            T.ok(not p.thawed, class .. " material set before the freeze")
            n = n + 1
        end
    end
    T.ok(n > 10, "park pieces checked: " .. n)
end)
