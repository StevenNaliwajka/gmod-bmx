# G29 -- The Workshop page

**Competitor:** title **"Rideable Bicycles"**, 13,966 subscribers, 1,456
favourites, 369 ratings in seven days. They posted updates about daily
(Sep 30, then through Oct 6) and announce each one in the comments ("Update:
Advanced airtime control is in [...]"). The author answers comments, including
the skateboard question. They have a screenshot of a real model on a
player, and a README that doubles as the description.

**Us today:** title **"BMX Bike"**, description opening "BMX bike attempt in
gmod", 72 subscribers, 9 favourites, no comments. The thumbnail is of the
procedural bike. 1.1.0 is built and not posted.

## Goal

The page makes someone who has already seen theirs subscribe to ours as
well. The pitch is what we have that they don't: **tricks with Tony Hawk
scoring, grinds, combos, and (soon) skateboards**.

## Done when

- **Title:** something like "BMX: Bikes, Grinds & Tony Hawk Combos". It
  becomes "BMX: Bikes, Boards & Combos" when G23 ships. "Attempt" goes:
  it undersells a working addon.
- **Description,** first three lines (the part a browser sees): what it
  does in one sentence, then "Grind rails, chain tricks into combos, score
  points," then the controls. Then a table of features, then the controls,
  then server settings, then links (G08).
- **Thumbnail:** a mid-air trick shot on gm_skatepark with the combo HUD
  visible. It's only possible with a real model (G20), and until then use a
  well-lit cinematic camera shot.
- **Video:** 30-60 s, recorded with the trick bot (`bmx_bot_spawn`) and the
  cinematic camera: a grind, a combo, a crash, all three bikes, and the city.
  Linked as the first media item.
- **Screenshots:** one per feature (grind, combo HUD, flips, cruiser/mini,
  city skyline, crash ragdoll).
- **Cadence:** small updates often, each with a change note and a comment
  saying what changed. **Every update needs the owner's go**, as the release
  rule says. The owner sets the pace, and this doc asks for "often".
- **Answer comments** within a day, and say what's coming (the skateboard).
- Tags: Vehicle, Fun, Roleplay where it fits.
- **Cross-promotion:** when the skateboard ships, either a second item that
  requires nothing, or the same item renamed. The owner decides.

## Approach

`addon.json` holds the description that `tools/package-workshop.sh` puts in the
kit, so these edits go in git, and the kit checks they're under Steam's
limits. The video and screenshots can be scripted on the player test server
(VM 119149, gm_skatepark).

## Tests

- Kit test: the description's first 200 characters contain "grind" and
  "combo", and the controls section matches `sv_input.lua`'s bindings (a test
  that already-wrong docs can't ship).

## Risks

None technical. This is the highest return per hour in the list.
