--[[--------------------------------------------------------------------------
    RagMod support on crashes (G07): the adapter in sv_compat_ragmod.lua and
    the hook the crash path fires.

    RagMod itself cannot be here, so a FAKE one stands in: a global table with
    one entry point, which is exactly the surface the adapter pins. What these
    tests prove is the contract -- called with the rider, velocity set on what
    it returns, nothing thrown on any failure, our own ragdoll as the fallback.
    That RagMod's real API matches is the manual test in docs/goals/G07.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

-- The adapter looks in the host's globals (that is where an addon's tables
-- live in the real game), so a test sets one and always takes it back.
local function withRagMod(tbl, fn)
    _G.ragmod = tbl
    local ok, err = pcall(fn)
    _G.ragmod = nil
    if not ok then error(err, 0) end
end

-- A rider on a bike that is about to be knocked over at speed-zero, past the
-- grace period, the same set-up test_server.lua uses.
local function tipOver(sv)
    local bike = F.bike(sv)
    sv:run(0.5)
    local ply = F.scripted(sv, bike)
    sv:run(1.2)
    F.layDown(sv, bike)
    return bike, ply
end

-- A fake RagMod whose Ragdollize records the call and returns a real shim ragdoll.
local function fake(E, log)
    return {
        Ragdollize = function(ply)
            log.calls = (log.calls or 0) + 1
            log.ply = ply
            local rag = E.ents.Create("prop_ragdoll")
            rag:SetModel(ply:GetModel())
            rag:Spawn()
            log.rag = rag
            return rag
        end,
    }
end

T.test("ragmod: detected after load, absent when not installed", function()
    local sv = F.server()
    local E = sv.env
    T.eq(E.BMX.Compat.DetectRagMod(), nil, "nothing installed")
    withRagMod({ Ragdollize = function() end }, function()
        local r = E.BMX.Compat.DetectRagMod()
        T.ok(r and r.name == "ragmod.Ragdollize", "found it by its entry point")
    end)
    T.eq(E.BMX.Compat.DetectRagMod(), nil, "and gone again when it is")
    T.ok(E.GetConVar("bmx_ragmod"):GetBool(), "bmx_ragmod defaults to 1")
end)

T.test("ragmod: a crash hands the rider to RagMod with the throw velocity", function()
    local sv = F.server()
    local E = sv.env
    local log, heard = {}, {}
    withRagMod(fake(E, log), function()
        E.BMX.Compat.DetectRagMod()
        E.hook.Add("BMX_RiderCrashed", "t", function(ply, vel, bike) heard = { ply, vel, bike } end)
        local bike, ply = tipOver(sv)
        T.ok(sv:run(1, function() return not E.IsValid(bike:GetDriver()) end), "thrown off")
        sv:run(0.2)
        T.eq(log.calls, 1, "RagMod asked once")
        T.eq(log.ply, ply, "for this rider")
        T.ok(not ply.BMXTumbling, "and our own tumble was NOT made")
        T.eq(heard[1], ply, "the hook heard the rider")
        T.eq(heard[3], bike, "and the bike")
        T.ok(heard[2].z > 0, "the throw has lift")
        -- The ragdoll has been falling since; check the velocity itself at the
        -- adapter, where nothing has stepped between the call and the read.
        local v = E.Vector(120, -30, 80)
        T.eq(E.BMX.Compat.Ragdoll(ply, v), true, "adapter reports it took the rider")
        local got = log.rag:GetPhysicsObjectNum(0):GetVelocity()
        T.near(got.x, 120, 1e-6, "velocity x")
        T.near(got.y, -30, 1e-6, "velocity y")
        T.near(got.z, 80, 1e-6, "velocity z")
    end)
end)

T.test("ragmod: a RagMod that errors falls back to our ragdoll, no Lua error", function()
    local sv = F.server()
    local E = sv.env
    withRagMod({ Ragdollize = function() error("boom") end }, function()
        E.BMX.Compat.DetectRagMod()
        local bike, ply = tipOver(sv)
        T.ok(sv:run(1, function() return not E.IsValid(bike:GetDriver()) end), "thrown off")
        T.ok(E.IsValid(ply.BMXTumbling), "the built-in tumble took over")
    end)
end)

T.test("ragmod: bmx_ragmod 0 and no RagMod both use the built-in tumble", function()
    local sv = F.server()
    local E = sv.env
    local log = {}
    withRagMod(fake(E, log), function()
        E.BMX.Compat.DetectRagMod()
        E.GetConVar("bmx_ragmod"):SetString("0")
        local bike, ply = tipOver(sv)
        sv:run(1, function() return not E.IsValid(bike:GetDriver()) end)
        T.eq(log.calls, nil, "RagMod never called")
        T.ok(E.IsValid(ply.BMXTumbling), "ours")
    end)
    local sv2 = F.server()
    local bike2, ply2 = tipOver(sv2)
    sv2:run(1, function() return not sv2.env.IsValid(bike2:GetDriver()) end)
    T.ok(sv2.env.IsValid(ply2.BMXTumbling), "and with none installed")
end)

T.test("ragmod: a BMX_RiderCrashed hook returning true takes the rider", function()
    local sv = F.server()
    local E = sv.env
    E.hook.Add("BMX_RiderCrashed", "other", function() return true end)
    local bike, ply = tipOver(sv)
    T.ok(sv:run(1, function() return not E.IsValid(bike:GetDriver()) end), "thrown off")
    sv:run(0.2)
    T.ok(not ply.BMXTumbling, "no tumble of ours")
end)
