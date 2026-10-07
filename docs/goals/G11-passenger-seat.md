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

## Status (2026-10-07)

Done on the offline plant, in one commit on top of G10; the headless case is
written, **not run** (no server here). Not merged, not on the Workshop.

- **Seat list per registry entry:** `seats = { rider = {...}, pegs = {...}, child = {...} }`
  (`sh_vehicles.lua` validates, `sh_passenger.lua` resolves: `BMX.SeatFor`). Each seat is
  `{ model, offset, angles, massFactor }`, every key optional; `offset` may be a function of
  the config; an empty table is all defaults. The old one-seat list still works as the
  rider's. The BMX and the cruiser say `seats = { pegs = {} }`; the mini carries nobody.
  The rider's pod is built by the same `ENT:BuildPod` as a passenger's.
- **Pegs passenger:** E on the rear half of an occupied bike (`ENT:Use` hands over to
  `BMX.Passenger.TryBoard`; `BMX_CanMount` is asked) seats the next player in a pod of
  their own, parented, invisible, non-solid and `DoNotDuplicate` like the rider's, made
  the first time somebody takes that seat. They cannot steer (input is read from the
  rider only), can look round and use the mouse (the chase camera leaves a passenger's
  view to the pod, `cl_view.lua`), and get off with E. Only when pointing at the rear half
  (no trace, no boarding: E on an occupied bike does what it always did; a script passes
  `anywhere`), not onto a
  fallen bike, not while tumbling.
- **Hands on the rider's shoulders:** client IK (`cl_passenger.lua`): the passenger's
  hands go to the rider's upper-arm bones, the feet to the rear pegs, the torso leans
  forward; with nobody at the bars the hands still have somewhere to go. Not seen on a
  client.
- **Mass and COM:** the bike runs on a config with `massFactor x Chassis.mass` more mass
  (0.6 on the pegs, 1.6x in total, a +70% rider; 0.25 for a child), the physics object is
  that heavy and the inertia is measured again (and rescaled by hand if the engine does not
  rescale it with the mass). VPhysics cannot move a mass centre at runtime, so the weight is
  applied where the passenger sits, as a couple with no net force: on the plant the rear
  carries visibly more of the weight and the front less, and the bike is slower to 160 u/s.
- **Crash:** both are thrown, each with the bike's momentum and a little of their own, and
  go the same ladder: `BMX_RiderCrashed` fires for each (rider, then passenger), then RagMod,
  then our ragdoll, then the shove; both are hurt as the rider is. A `BMX_Crash` veto keeps
  both on. A rider who gets off, dies or disconnects takes the passenger off with them.
- **Tricks x2** with a passenger aboard, on top of the vehicle's own multiplier.
- **`bmx_passengers`** (server, default 1; Options > BMX > Server > Vehicles): 0 stops
  boarding and puts everyone aboard off, mid-ride too.
- **Child seat:** a "Child seat" toggle on the context menu of a bike that has the seat
  (`properties.Add`, owner or admin, not with somebody in it), a `ChildSeat` networked bool,
  a seat drawn when it is on, and a child seated in it at 0.6 model scale. No shipped bike
  has one until the city bike (G12) does.
- **Tests:** `tests/test_passenger.lua` (47): the seat registry's every form and 11
  rejections, defaults, boarding and refusing (a third rider, the front, an empty bike, a
  mini, bmx_passengers 0), getting off and every way of leaving, the pod's flags, trace and
  collision filters, mass and inertia and the weight couple, the x2, the crash (the hook for
  each, ragdolls, a veto, a tipped bike), the child seat's property and its owner rule, and
  the client's view (who is a passenger, the targets, the pose, the free-look camera, the
  drawn seat). Headless: `passenger_mount_and_crash` makes a second bot
  (`player.CreateNextBot`), boards it with `bike:Use`, checks both seated and the mass, forces
  a crash and checks both off with a hook for each. It is skipped, with a log line, if the
  server has no free player slot. **The harness can seat a second bot; it has not been tried
  on a server.**
- **Left:** the rider is not asked for permission (any player can board an occupied bike),
  there is no "kick the passenger" key, the passenger's own animation is the rider's sit
  pose with a lean (nobody has watched it), and flips with a passenger are allowed, as asked,
  with the passenger's pod simply along for the ride.
