--[[--------------------------------------------------------------------------
    bmx/sv_penny.lua

    THE PENNY-FARTHING (G13): a drive straight onto the front wheel, a wheel 26 units
    in radius, and a rider sat on top of it. Two things make it what it is and both are
    here.

    THE DRIVE (`drive = { kind = "front-direct" }`). The cranks are on the front hub,
    so the front wheel IS the drive wheel (the registration marks it `drive = true`),
    and the legs turn the wheel once a stroke: gearRatio 1. The pedal drive's function
    already works on "the first wheel marked drive" and not on "the rear", so the kind is
    that function under its own name: what differs is the wheel it is handed, and the
    registration's numbers (a big wheel at a ratio of 1 is a speed of its own).

    THE HEADER (`balance = "pennyfarthing"`). The mode is the single-track one, whole:
    two wheels in line, the front steered by the fork, the lean-derived steering. What it
    takes away is the pitch assist, because there is nothing to hold: the rider's centre
    of mass is 64 units off the ground (the bike's is 30) and 20 behind the front tyre's
    patch, so a front brake that decelerates harder than g * 20 / 64 = 0.31 g takes the
    back wheel off the ground, and a rider on top of a 26-unit wheel has a long way to
    fall forward. That is the physics, and it happens on its own with the same tyre model
    the other bikes ride on: hold the front brake hard at speed and the whole machine
    goes over the bars. A penny-farthing is famous for little else.

    The rule below is not what pitches the machine over. It is what DECIDES the rider is
    over the bars, as the tip rule decides a fallen bike (sv_physics.lua 6a), sooner and
    better: with the front brake held hard (Penny.headerBrake), at speed
    (Penny.headerSpeed), once the nose is down by Penny.headerPitch, the rider is thrown
    as the crash ladder throws anyone, with extra forward speed on top (Penny.headerThrow)
    because a header is OVER the bars and not merely off the bike. Without it the same
    machine tips at the 75 degrees of Crash.tipPitch and the rider comes off a moment
    later, in a worse place.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Penny = BMX.Penny or {}

-- The drive: the pedal drive on whichever wheel the vehicle drives (its front).
BMX.Drives["front-direct"] = function(ent, cfg, dt, inp, st, wheel, vdef)
    return BMX.Drives.pedal(ent, cfg, dt, inp, st, wheel, vdef)
end

-- Is the rider over the bars? The three conditions of the header.
function BMX.Penny.IsHeader(C, inp, st)
    local P = C.Penny
    return (inp.brakeFront or 0) >= P.headerBrake
        and (st.speed or 0) >= P.headerSpeed
        and (st.pitch or 0) < -P.headerPitch
end

BMX.BalanceModes.pennyfarthing = {
    Ground = function(...) return BMX.Balance(...) end,
    Pitch  = function(ent, phys, C, dt, inp, st, wheels)
        if not IsValid(ent:GetDriver()) or not C.Crash.enabled then return end
        if CurTime() - (ent.spawnTime or 0) < C.Crash.grace then return end
        if BMX.Penny.IsHeader(C, inp, st) and not ent.crashPending and ent.QueueCrash then
            ent.crashBoost = ent:GetForward() * C.Penny.headerThrow
            ent:QueueCrash("header", C.Penny.headerSeverity)
        end
    end,
}
