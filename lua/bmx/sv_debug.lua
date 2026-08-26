--[[--------------------------------------------------------------------------
    bmx/sv_debug.lua

    The tuning channel.

    Everything that decides how the bike feels lives on the server: roll error,
    assist authority, the derived steer angle, per-wheel load and slip. None of
    it is visible from a client, and tuning a controller you cannot see the
    state of is guesswork with extra steps. So: when a rider sets bmx_debug 1,
    the server streams that rider's own bike state to them at 10 Hz.

    Only to the rider, only for their own bike, only while the convar is on. It
    is a development tool, not a feature, and it should cost a shipping server
    exactly nothing.
----------------------------------------------------------------------------]]

BMX = BMX or {}

util.AddNetworkString("bmx_debug")

local INTERVAL = 0.1
local nextSend = 0

-- The order here is the wire format and cl_hud.lua reads it back in exactly
-- this sequence. Keep the two in step or the overlay silently shows garbage.
local function writeWheel(w)
    net.WriteBool(w.onGround)
    net.WriteFloat(w.load)
    net.WriteFloat(w.slipLong)
    net.WriteFloat(w.slipLat)
    net.WriteFloat(w.saturation)
    net.WriteFloat(w.compression)
    net.WriteFloat(w.omega)
    net.WriteFloat(w.steer)
end

hook.Add("Think", "BMX.DebugStream", function()
    if CurTime() < nextSend then return end
    nextSend = CurTime() + INTERVAL

    for _, ply in ipairs(player.GetHumans()) do
        local bike = ply.BMXBike
        if not IsValid(bike) then continue end
        if ply:GetInfoNum("bmx_debug", 0) < 1 then continue end

        local st = bike.st
        local inp = bike.input
        if not st or not inp then continue end

        local front, rear
        for _, w in ipairs(bike.wheels) do
            if w.isFront then front = w else rear = w end
        end
        if not front or not rear then continue end

        net.Start("bmx_debug", true)   -- unreliable: a dropped debug frame is
                                       -- not worth a retransmit
            net.WriteFloat(st.roll)
            net.WriteFloat(inp.lean * bike:Cfg().Balance.maxLean)
            net.WriteFloat(st.rollRate)
            net.WriteFloat(st.leanAuthority)
            net.WriteFloat(st.steer)

            net.WriteFloat(st.pitch)
            net.WriteFloat(st.pitchRate)

            net.WriteFloat(st.speed)
            net.WriteFloat(st.fwdSpeed or 0)
            net.WriteFloat(st.cadence)
            net.WriteFloat(st.stamina)

            net.WriteBool(st.airMode)
            net.WriteFloat(st.airTime or 0)
            net.WriteFloat(st.spinPitch or 0)
            net.WriteFloat(st.spinRoll or 0)
            net.WriteFloat(st.spinYaw or 0)

            net.WriteFloat(inp.lean)
            net.WriteFloat(inp.pitch)
            net.WriteFloat(inp.throttle)

            writeWheel(front)
            writeWheel(rear)
        net.Send(ply)
    end
end)

--------------------------------------------------------------------------
-- Force-units self-test. RUN THIS FIRST ON A NEW SERVER BUILD.
--
-- The entire simulation rests on one assumption: PhysObj:ApplyForceCenter
-- takes an IMPULSE (kg*units/s), so applying F*dt for a force F produces
-- dv = F*dt/m. Every force in sv_wheel.lua and sv_physics.lua is scaled by dt
-- on that basis.
--
-- If that assumption is wrong on some build, nothing crashes and nothing looks
-- obviously broken: the bike is simply uniformly weak or uniformly violent by a
-- factor of the tick interval (~66x), and you spend an evening retuning grip
-- and crank torque to compensate for a units error. Two seconds of measurement
-- beats that.
--
-- Expected output on a correct build: "dv = 100.0 u/s  -> IMPULSE (expected)".
--------------------------------------------------------------------------
concommand.Add("bmx_selftest", function(ply)
    local function out(s)
        if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, s) end
        MsgN("[BMX selftest] " .. s)
    end

    local pos = IsValid(ply) and (ply:GetPos() + Vector(0, 0, 200)) or Vector(0, 0, 200)

    local test = ents.Create("prop_physics")
    test:SetModel("models/hunter/blocks/cube025x025x025.mdl")
    test:SetPos(pos)
    test:Spawn()

    local phys = test:GetPhysicsObject()
    if not IsValid(phys) then
        out("FAILED: could not create a test physics object")
        SafeRemoveEntity(test)
        return
    end

    local mass = 100
    phys:SetMass(mass)
    phys:EnableGravity(false)
    phys:EnableDrag(false)
    phys:SetDamping(0, 0)
    phys:SetVelocity(Vector(0, 0, 0))
    phys:Wake()

    -- Apply an impulse that SHOULD produce exactly 100 u/s if the argument is
    -- an impulse, and 100 * tickinterval (~1.5 u/s) if it is a force.
    local want = 100
    phys:ApplyForceCenter(Vector(0, 0, 1) * mass * want)

    timer.Simple(0.1, function()
        if not IsValid(test) then return end
        local p = test:GetPhysicsObject()
        local dv = IsValid(p) and p:GetVelocity().z or 0

        out(string.format("tick interval  = %.5f s", engine.TickInterval()))
        out(string.format("sv_gravity     = %.1f u/s^2", physenv.GetGravity():Length()))
        out(string.format("applied        = mass %d * %d", mass, want))
        out(string.format("dv             = %.1f u/s", dv))

        if math.abs(dv - want) < want * 0.15 then
            out("-> IMPULSE (expected). Force scaling in this addon is correct.")
        elseif math.abs(dv - want * engine.TickInterval()) < want * 0.05 then
            out("-> FORCE, not impulse. Every ApplyForce* call in sv_wheel.lua and")
            out("   sv_physics.lua is multiplied by dt and must NOT be. Remove the")
            out("   dt factor before tuning anything.")
        else
            out("-> INCONCLUSIVE. Something else damped the test object.")
        end

        SafeRemoveEntity(test)
    end)
end)

--------------------------------------------------------------------------
-- Dump the whole live config to console. When a tuning session lands on
-- something good, this is how it gets back into sh_config.lua.
--
-- THE BASE, DELIBERATELY, not the config of whatever bike you were last on. It
-- is the base that convars move and the base that this text is going to be
-- pasted back into, and a bike with per-bike overrides would dump its merged
-- values -- which would then be written into sh_config.lua as everybody's
-- defaults. Per-bike overrides live in that bike's `physics` table in
-- sh_bikes.lua and are not a tuning-session output.
--------------------------------------------------------------------------
concommand.Add("bmx_dump_config", function(ply)
    local function out(s)
        if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, s) else print(s) end
    end

    out("-- BMX live config, " .. os.date("%Y-%m-%d %H:%M:%S"))
    for _, group in ipairs({ "Chassis", "Wheel", "Drive", "Balance", "Pitch", "Air", "Hop", "Crash" }) do
        out("C." .. group .. " = {")
        local keys = {}
        for k in pairs(BMX.Config[group]) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local v = BMX.Config[group][k]
            if isnumber(v) then
                out(string.format("    %-20s = %s,", k, tostring(v)))
            elseif isbool(v) then
                out(string.format("    %-20s = %s,", k, tostring(v)))
            elseif isvector(v) then
                out(string.format("    %-20s = Vector(%g, %g, %g),", k, v.x, v.y, v.z))
            end
        end
        out("}")
    end
end)
