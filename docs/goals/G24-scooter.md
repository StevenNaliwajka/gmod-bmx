# G24 -- Kick scooter

**Competitor:** none. (Their #15 mentions a moped with pedals, which is a
motor vehicle, G15.)

**Us today:** nothing. After G22 and G23 it's cheap: 2 small wheels in
line (single track, like the bike) with the **board's** push and the bike's
bars.

## Goal

A pro stunt scooter, the third park vehicle. Scooter tricks are mostly bike
tricks (tailwhip, barspin) on a board-like deck, so most of the trick code
comes from G03 and G23.

## Done when

- `bmx_spawn scooter`, spawn menu **Scooters**.
- Riding: push like the board (W), steer at the bars like the bike
  (`singletrack` balance with a small trail), rear fender brake (S).
- Tricks: bunny hop, **tailwhip** (deck around the bars, from G03),
  **barspin** (G03), **bri flip** (whip + flip), front/back flips, manuals,
  grinds (deck and pegs: 50-50, feeble, smith).
- Rider: both feet on the deck, IK.
- All headless riding cases on `scooter`.

## Approach

Registry entry on G22: `family = "scooter"`, `balance = "singletrack"`,
`drive = { push = ... }` (from the board), `tricks` = the bike's air set +
whip and barspin. No new physics.

## Tests

- Headless: the riding cases plus `scooter_tailwhip_lands`.

## Risks

Low. It depends on G03 and G23 landing first.
