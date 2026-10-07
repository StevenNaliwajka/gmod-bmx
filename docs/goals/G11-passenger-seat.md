# G11 -- Passenger seat (pegs and child seat)

**Competitor:** [#11](https://github.com/luttje/gmod-bicycle/issues/11) (open):
"A lot of comments have been about Happy Wheels." They plan a child seat
bodygroup that a second player can sit in.

**Us today:** one rider per bike (`sv_seat.lua`, one pod). Our BMX already
has **pegs**, though, and riding on someone's pegs is the authentic BMX
version of this.

## Goal

A second player can ride along, and the Happy Wheels crowd gets their crashes,
with both players thrown when it goes wrong.

## Done when

- **Pegs passenger** (BMX, cruiser): pressing E on an occupied bike's rear
  pegs seats a second player standing on them, with hands on the rider's
  shoulders (IK target = rider's shoulder bones).
- **Child seat** (cruiser and later city/retro bikes, G12): a toggleable
  seat attachment, `bmx_seat_child 1` on a bike via the context menu.
- Mass and COM change with the passenger (≈ +70% rider mass for an adult on
  pegs). Wheelies get harder, and so does the balance.
- Crash: both are ejected with their own velocity and both ragdoll (and G07
  RagMod applies to both).
- The passenger can get off with E. They can't steer, but they can look round
  and use their mouse (a "camera person" mode for clips, G28).
- Tricks with a passenger score ×2. Flips are allowed if you dare.
- `bmx_passengers 0` (server) turns it off.

## Approach

`sv_seat.lua` gets a seat list per registry entry (`seats = { rider=..., pegs=...
}`). The second pod is parented the same way as the first, and is
`DoNotDuplicate` like the first. Mass is added through the existing per-bike
physics path as a runtime override.

## Tests

- Headless `passenger_mount_and_crash` with two bots: both seated, the
  mass changes, and a forced crash ejects both without errors.
- Offline: seat registry validation.

## Risks

Bot-on-bot mount in headless needs a second fake client. Check the harness
supports two before promising the test.
