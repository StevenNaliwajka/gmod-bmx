# Competitive goals

Written 2026-10-07 against `ec79df6` (main, 1.1.0, not yet on Steam).

The competitor is **"Rideable Bicycles"** by luttje, Workshop item
[3810718443](https://steamcommunity.com/sharedfiles/filedetails/?id=3810718443),
source at [luttje/gmod-bicycle](https://github.com/luttje/gmod-bicycle).
There is one goal document for each of its GitHub issues (`G01`-`G16`), one for
each feature it has that is not an issue (`G17`-`G21`), and one for each thing
neither addon has that we should (`G22`-`G30`).

The release rule in `docs/GOALS.md` still applies. Nothing here goes to the
Workshop without the owner's go.

## Where we stand (2026-10-07)

| | Rideable Bicycles | BMX Bike (ours) |
|---|---|---|
| Posted | 2026-09-30, updated 10-06 | 2026-10-05 |
| Subscribers | **13,966** | 72 |
| Favourites | 1,456 | 9 |
| Ratings | 369 | too few to show |
| Size | 6.0 MB (real models) | 468 KB (procedural, no content) |
| Bikes | mountain bike + BMX (CC-BY models) | BMX, cruiser, mini (drawn from beams) |
| Physics | animated SENT, player motions rotated about the pedals | raycast wheels, tyre model, lean-derived steering |
| Tricks | tailwhip, barspin, flips, no-hander, no-footer, can-can, X-up | flips, barrel roll, 360, wheelie, manual, stoppie, hop, grinds |
| Scoring | none | points, Tony Hawk combos, HUD |
| Grinds | none | crank and double peg |
| Settings UI | Q-menu Options > Bicycle, CAMI privileges | console convars only |
| Modding | integration guide, trick API, model editor | bike registry with physics overrides |
| Extras | bell, water, RagMod, spine transfer, air turns | city skyline, trick bot, cinematic camera, CI test suites |

The comment on their page that matters most is from their author:

> I've stopped working on my skateboard mod. It's significantly harder to
> animate. The bicycle is simply running the playermodel motions through
> rotations around the pedals [...] anything I try with skateboarding looks
> very janky.

They have stopped on skateboarding, and players are asking for it ("now whens
the skatebroad mod?", "HAPPY WHEELS", "trials HD", "motorbike").

## Build status (end of 2026-10-07)

Every goal has been built and merged to `main`, and each doc ends with a
`## Status (2026-10-07)` section saying what is done, partial and left. The
offline suite went from 352 to 1128 tests, all passing. **None of it is on the
Workshop**: the release rule still applies, and `CHANGELOG.md` / `BMX.Version`
were left for the release.

The repo was split during this work (another session, commit 3474ba1). The bot,
games (SKATE, Trick Attack, Combo Mambo), scores and leaderboard now live in
`gmod/gmod-bmx-mode`. The city lives in `gmod/petopia_bmx_fall`. The G26 work
and every bot routine went with them.

**Default off until someone has ridden it on a real server:**

| Switch | Goal | What it guards |
|---|---|---|
| `bmx_wheel_sweep 0` | G05, G16 | swept wheel contact on steep faces and curbs |
| `bmx_nose_manual 0` | G02 | the nose manual hold |
| `bmx_predict 0` (client) | G30 | own-bike lean prediction |
| `bmx_lagcomp 0` | G30 | tick-dated trick inputs |
| `bmx_flip_doubletap 0` (client) | G17 | the competitor-style double-tap flip |

On by default but new: `bmx_wheel_stiction` (G04), `bmx_air_assist` (G06),
`bmx_ragmod` (G07), the bell and water (G18).

**On the real server.** The headless suite is green on `main` (pipeline 1015,
856e3e1): 165 passed, 0 failed, and 27 cases marked `wip`, each with a comment
citing the CI run that showed the feature unfinished. That list is the next
work: slope hold creeps on 10 and 20 degrees, the 75 degree drop-in, the
`@mini`/`@road`/`@fixie` 45 degree wedge, the city wheelie, Air 180 / Spine
Transfer, tandem steering and torque, the skates' soul grind pays the wrong
trick, tap-ollie height, board bad-catch bail, scooter tailwhip and curbs, and
the dirt bike's suspension on a big drop. The bot cases moved to
`gmod-bmx-mode`, which has no headless CI yet. Nothing has been looked at in a
game client: the IK poses, the board rider, the replay stand-ins, the menus and
the 3D2D signs all need eyes. Feel tuning (`docs/TUNING.md`) needs a person on
the test server.

**Where assets live (owner, 2026-10-07):** every BMX *vehicle* asset (vehicle
code, models, materials, sounds, and anything a bike, board, scooter, skate or
motor vehicle needs to be drawn or heard) goes in **this addon**,
`gmod/gmod-bmx`. The gamemode (`gmod/gmod-bmx-mode`) holds only game rules,
scores and the bot; the map (`gmod/petopia_bmx_fall`) holds only the map and
city. A vehicle that only works with the mode or the map installed is a bug.

**Waiting on the owner:**

1. **Model licence (G20):** allow CC-BY 4.0 with credits, alongside original
   and CC0? This unblocks real models for the thumbnail.
2. **Public tracker (G08):** GitHub mirror, issues-only repo, or none. The
   templates are in `.github/ISSUE_TEMPLATE/`.
3. **Workshop (G29):** the description in `addon.json` is rewritten. The
   title is back to "BMX" on `main`, changed by someone after G29 proposed
   "BMX: Bikes, Grinds & Tony Hawk Combos". Pick one, then thumbnail,
   video and screenshots. Whether boards ship in the same item or a second one.
4. **Release:** a version number for all of this, and the go.

## What I think we should do

**1. Don't fight them for "best bicycle". Be the action-sports addon.**
They will win on looks for bicycles: they have real models and a six-day
head start of 14k installs. Their engine is an animation rig, though, and
ours is a physics rig. That is why we already have grinds, combos and scoring
that they don't, and it's why a skateboard is hard for them and natural for
us: a board is four raycast wheels under a deck, which `sv_wheel.lua` already
does. The pitch is "**BMX: bikes, boards and scooters, with Tony Hawk
scoring**", not "another bike".

**2. Skateboard first, through a vehicle platform (G22, G23).**
Before the board, split the core into a vehicle-agnostic layer: N wheels,
a rider pose, an input map and a trick set per vehicle. The skateboard is then
the first non-bike client of that layer, and scooters (G24), and later
dirt bikes and e-bikes (G14, G15), follow cheaply. A skateboard that feels
like Skate/THPS is the single feature that can take subscribers from them.

**3. Close the parity gaps that cost us ratings (G03, G17, G19, G20).**
A player who has tried both will judge us by the list on their README.
Tailwhip, barspin, no-hander, can-can and X-up are the tricks every BMX player
looks for, and a Q-menu settings panel is what every GMod player expects.
These are cheap next to the skateboard, and each one also pays into combos,
which is where we are ahead.

**4. Real models, and relax the licence rule to CC-BY with attribution (G20).**
`docs/DESIGN.md` §8 says "original or CC0 only". They ship CC-BY Sketchfab
models with credit, which is legal and normal on the Workshop. The beam-drawn
bike is a fine debugging view, but it makes our thumbnail lose before
anyone subscribes. My proposal: allow CC-BY 4.0 with a credits file, keep
procedural as the fallback, and never ripped assets. **This needs the owner's
decision.**

**5. Give players a reason to stay (G26, G27).**
Scoring with nowhere to show it is half a feature. Persistent high scores,
a per-map leaderboard, SKATE/HORSE between players, and a prop pack of ramps,
rails and quarter pipes make any map a park. Server owners run addons that give
their players something to do, and subscriber counts follow servers.

**6. Fix the Workshop page (G29).**
72 vs 13,966 is mostly presentation: a real thumbnail, a 30-second video, a
GIF per trick, the description written for players, and frequent updates
(they've posted several in a week and answer every comment).

## Order

| Pri | Goal | Why now |
|---|---|---|
| P0 | [G29](G29-workshop-presence.md) Workshop page | costs nothing, every later feature rides on it |
| P0 | [G03](G03-tailwhip-barspin.md), [G17](G17-style-tricks.md) BMX trick parity | the tricks players look for first; feed combos |
| P0 | [G19](G19-settings-menu-permissions.md) Q-menu settings + CAMI | expected by every server admin |
| P0 | [G16](G16-edge-climbing.md), [G05](G05-steep-ramps.md), [G04](G04-slope-hold.md) terrain bugs they had | prove we don't have them, with tests |
| P1 | [G22](G22-vehicle-platform.md) vehicle platform | unblocks the whole suite |
| P1 | [G23](G23-skateboard.md) **skateboard** | the flagship; they gave up on it |
| P1 | [G20](G20-models-and-modding-api.md) real models + modding API | thumbnail, and community bikes |
| P1 | [G06](G06-air-control-spine.md) air turns + spine transfer | park riding |
| P1 | [G26](G26-game-modes-leaderboards.md) high scores, SKATE, leaderboards | retention |
| P1 | [G27](G27-park-prop-pack.md) ramp/rail prop pack | any map is a park |
| P2 | [G24](G24-scooter.md) scooter, [G07](G07-ragmod.md) RagMod, [G18](G18-bell-water-sound.md) bell/water/sound | breadth |
| P2 | [G02](G02-stoppie-lean.md), [G01](G01-visual-rig-fidelity.md), [G30](G30-netcode-feel.md) | polish |
| P2 | [G28](G28-replays-clips.md) replays | shareable clips are free marketing |
| P3 | [G09](G09-road-bike.md), [G10](G10-fixed-gear.md), [G12](G12-retro-bike.md), [G13](G13-other-bikes.md), [G11](G11-passenger-seat.md) | more bikes, after the platform |
| P3 | [G14](G14-e-bikes.md), [G15](G15-motorbikes.md) | powered vehicles, on the platform |
| P3 | [G08](G08-feedback-channel.md) public feedback channel | needed once players arrive |

## Every document

Issues on luttje/gmod-bicycle:

- [G01](G01-visual-rig-fidelity.md) #1 brake cable disconnects on turning
- [G02](G02-stoppie-lean.md) #2 stoppie on LMB / lean forward
- [G03](G03-tailwhip-barspin.md) #3 tailwhip and barspin
- [G04](G04-slope-hold.md) #4 bike slides slowly on a slight incline
- [G05](G05-steep-ramps.md) #5 wheels sink into steep ramps
- [G06](G06-air-control-spine.md) #6 airtime control (air turns, spine transfer)
- [G07](G07-ragmod.md) #7 RagMod support
- [G08](G08-feedback-channel.md) #8 issue templates
- [G09](G09-road-bike.md) #9 road bike
- [G10](G10-fixed-gear.md) #10 fixed gear
- [G11](G11-passenger-seat.md) #11 child seat / passenger
- [G12](G12-retro-bike.md) #12 retro bike
- [G13](G13-other-bikes.md) #13 other bikes (unicycle, penny-farthing, tandem, rack, lock)
- [G14](G14-e-bikes.md) #14 electric bikes
- [G15](G15-motorbikes.md) #15 motorbikes / dirt bikes
- [G16](G16-edge-climbing.md) #16 can't climb over edges

Their features that are not issues:

- [G17](G17-style-tricks.md) no-hander, no-footer, can-can, X-up
- [G18](G18-bell-water-sound.md) bell, water, sound settings
- [G19](G19-settings-menu-permissions.md) Q-menu settings, CAMI, reset commands
- [G20](G20-models-and-modding-api.md) real models, integration guide, model editor
- [G21](G21-camera-hud-options.md) third person, speedometer, camera options

Neither addon has these:

- [G22](G22-vehicle-platform.md) vehicle platform (one core, many vehicles)
- [G23](G23-skateboard.md) **skateboard**
- [G24](G24-scooter.md) kick scooter
- [G25](G25-inline-skates.md) inline skates / roller skates
- [G26](G26-game-modes-leaderboards.md) high scores, leaderboards, SKATE/HORSE, trick attack
- [G27](G27-park-prop-pack.md) ramp, rail and quarter-pipe prop pack
- [G28](G28-replays-clips.md) replays and clip camera
- [G29](G29-workshop-presence.md) Workshop presence
- [G30](G30-netcode-feel.md) netcode and feel under ping

## Format of each document

Every goal has the same sections: **Competitor** (what they have, with the
issue link), **Us today** (what our code does, with file names), **Goal**,
**Done when** (acceptance criteria, testable where possible), **Approach**,
**Tests**, and **Risks**.
