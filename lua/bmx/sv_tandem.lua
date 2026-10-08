--[[--------------------------------------------------------------------------
    bmx/sv_tandem.lua

    THE TANDEM (G13): two riders, both pedalling, one steering.

    The second seat is G11's: `seats = { pegs = {...} }`, boarded with E at the back of
    an occupied vehicle (sv_passenger.lua), a pod of its own, the second rider's weight
    where they sit, tricks x2 and a crash that takes both. What this adds is one key on
    that seat, `pedals = true`: the person in it has their feet on cranks of their own.

    THE TORQUE SUMS. The pedal drive's push is crankTorque * (1 - spin) * throttle,
    throttle being 0..1 for the one rider the usercmd decode reads. For a seat that
    pedals the stoker's own throttle, 0..1, is added to it (BMX.Tandem.Push, asked by
    drivetrain in sv_physics.lua): two riders at full effort are twice the torque, through
    the same falling curve, so the legs run out of cadence at the same speed and the
    second pair of legs is a stronger start and a faster climb, not a higher top speed
    (which is the legs' ceiling). A stoker who is not pedalling adds nothing, and a
    stoker alone with a captain who is coasting still drives it.

    THE CAPTAIN STOPS IT. While the captain holds a brake the stoker's push is nothing:
    a tandem's two cranksets are one timing chain, and a stoker who keeps mashing while
    the captain squeezes the lever is how a tandem runs a stop sign. Measured on the
    server before this rule: the stoker's 141,700 of wheel torque against the BMX's
    95,000 rear brake, and a captain on the brake rolled 870 units at 110 u/s instead
    of stopping. The brake is sized for the weight as well (sh_bikes.lua, rearBrake).

    THE FRONT RIDER STEERS. A passenger's input is not read for anything but this: the
    usercmd decode (sv_input.lua) only ever reads the driver's, so the lean, the brake
    and the hop are the captain's. The stoker's W is their pedalling and nothing else.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Tandem = BMX.Tandem or {}
local T = BMX.Tandem

-- The stoker's throttle, 0..1, when somebody is on a seat that pedals; 0 otherwise.
-- The throttle is stamped on the vehicle's input by the usercmd hook below (or by a
-- test), so a stoker who gets off stops contributing the moment they are not in the
-- seat, whatever the last value was.
function T.Push(ent, inp)
    local pax = ent.passengers and ent.passengers.pegs
    if not (pax and IsValid(pax)) then return 0 end
    local seat = ent.paxSeats and ent.paxSeats.pegs
    if not (seat and seat.pedals) then return 0 end
    if (inp.brakeRear or 0) > 0 or (inp.brakeFront or 0) > 0 then return 0 end
    return BMX.Clamp(inp.paxThrottle or 0, 0, 1)
end

-- Does the seat of this kind, on this vehicle, have pedals?
function T.SeatPedals(def, cfg, kind)
    local seat = BMX.SeatFor(def, cfg, kind)
    return seat ~= nil and seat.pedals == true
end

hook.Add("StartCommand", "BMX.TandemStoker", function(ply, cmd)
    local pax = ply.BMXPax
    if not pax or ply.BMXScripted then return end
    local bike = pax.bike
    if not IsValid(bike) or not bike.input then return end
    local seat = bike.paxSeats and bike.paxSeats[pax.kind]
    if not (seat and seat.pedals) then return end
    local fwd = cmd:GetForwardMove() or 0
    local held = fwd > 0 or bit.band(cmd:GetButtons(), IN_FORWARD) ~= 0
    bike.input.paxThrottle = held and 1 or 0
end)
