# G23 -- Skateboard (the flagship)

**Competitor:** none. Their author stopped ("significantly harder to
animate", "looks very janky"). Players ask for it on their page ("now whens
the skatebroad mod?"). The skatepark maps their players ride (`hb_skatepark_v7`,
`gm_skatepark`, `pf_skatepark`) are built for boards.

**Us today:** the right base. Raycast wheels, a tyre model, launch
classification, grinds (`sv_grind.lua` already has rails, ledges and
coping), Tony Hawk combos, manuals, an IK rider and a trick bot. Their jank
comes from animating a body that the physics doesn't drive. For us, the
board is the physics, and the rider is IK that follows it, which is the same
trick that made our bike work.

## Goal

The best skateboard in Garry's Mod. It should feel like **Skate** (flick-it
style ollies and flips) with **THPS** scoring and combos, and it should
work on every skatepark map on day one.

## Done when

### Riding

- **Board:** 4 raycast wheels on 2 trucks. **Steering is truck lean**: A/D
  lean the deck, and the trucks turn by `atan(sin(lean) · k)`, which is a
  real skateboard's geometry and fits our lean-derived steer philosophy.
  It carves, it doesn't snap-turn.
- **Push:** W pushes (a kick every 0.6 s, with the speed added per kick), and
  a held W keeps pushing. S drags a foot (brake) and, at standstill, turns the
  board round (a kick-turn). Shift = mongo-free option off.
- **Stance:** regular/goofy (`bmx_stance`), **switch** and **fakie**
  tracked from the direction of travel. Tricks in switch score ×1.2.
- **Powerslide:** Ctrl + A/D at speed breaks the rear trucks loose (lower
  lateral grip), and it's scored.
- Rolls over cracks and curb edges like a small wheel would, which depends
  on G05/G16's swept wheels.
- **Bail:** landing more than 35° off, or a wheel catching a 4 u+ edge at
  speed, ejects and ragdolls (G07 RagMod applies).

### Ollie and flip tricks

- **Ollie:** hold Space to crouch (pop height ∝ hold time, up to 0.4 s),
  release to pop. It works on flat, off ramps, and onto ledges.
- **Nollie** (front foot): Space with Alt.
- **Flips:** during the pop window, a direction picks the flip, the way Skate
  flicks do (mouse or keys, rebindable):
  - Kickflip (A after pop), Heelflip (D), Pop shove-it (S), Front shove (W),
    **360 flip / tre flip** (S + A), **Varial kick/heel** (S + A or D
    combos), **Hardflip** (W + A), **Impossible** (W + S).
  - The board rotates on its own axes (flip roll, shove yaw, impossible
    pitch) as a separate body from the rider. The rider's feet leave the deck
    and come back (IK), which is exactly the part they couldn't animate.
  - **Catch:** each flip has a catch window. Land with the board within
    20° of flat and wheels down, or bail. A late catch scores less, a clean
    one more.
- **Grabs:** in the air, RMB + direction: indy, melon, stalefish, nosegrab,
  tailgrab, method. Hold for points (G17's pose system).
- **Manuals:** RMB on the ground (or W/S balance after landing on two
  wheels) manual / nose manual, with a balance meter in the HUD (THPS style).
  Combos chain through manuals, which our combo system already does.
- **Revert:** a 180 on landing (A/D on touchdown on vert) to keep the
  combo. That's the THPS 3 combo glue.

### Grinds and slides

- Snap onto rails, ledges and coping with a grind input (Space + direction, or
  automatic on contact if `bmx_board_autogrind 1`):
  **50-50, 5-0, nosegrind, crooked, smith, feeble, boardslide, lipslide,
  noseslide, tailslide**. Each has a balance meter.
- `sv_grind.lua` already finds grindable edges for the bike. The board
  reuses the finder with deck/truck contact points in place of pegs/cranks.

### Rider

- IK: feet on the deck at bolts (stance), knees bend with crouch, arms
  balance, and the body leans with the deck. Push animation: the back foot
  steps off, pushes and returns, driven by the push timer, not an animation.
- Works on any player model (it's the same IK the bike uses), and on the bot.

### Content

- A procedural board (deck, trucks, wheels drawn like the bike) on day one, so
  it ships with **zero content**, like the bike.
- A real deck model under G20's licence rule as soon as one exists.
  Grip-tape-top and graphic-bottom textures, recolourable, with a few deck
  graphics.
- Sounds: base-game placeholders (rolling, pop, land, grind) recorded in
  `sh_sound.lua`, with what each stands in for.

### Spawning and limits

- `bmx_spawn skateboard`, spawn menu **Boards**. It can be carried: E on the
  board in hand picks it up as a SWEP (`weapon_bmx_board`) and LMB drops it
  in front of you. That's how skaters actually carry a board, and it means no
  spawn spam.
- Counts against `bmx_max_per_player`.

## Approach

1. G22 first (platform, test cart).
2. Board balance mode `board`: no single-track balance, since a 4-wheel deck
   is statically stable. Lean is the rider's input, and the deck roll follows
   with a spring to the commanded lean. Steering comes from roll via the truck
   formula.
3. Pop: an upward impulse at the tail contact plus a nose-up torque; the
   flip is a kinematic board rotation (like G03's tailwhip) relative to the
   rider, with the rider's COM following the parabola.
4. Grinds: `sv_grind.lua` contact points become per-vehicle data
   (`grindPoints`), so each grind name maps to which points must be on the
   edge and the deck's angle relative to it.
5. Scoring: the board's tricks go through `BMX.RegisterTrick` (G17), and combos
   need nothing new.
6. Bot: `bmx_bot_trick kickflip` etc. The trick bot doing lines on
   `gm_skatepark` is the Workshop video (G29).

## Tests

- Offline: truck steer formula, pop height vs hold time, flip catch
  windows, each grind's contact rule, stance/switch tracking.
- Headless (on gm_skatepark, which the test servers already run):
  `board_pushes_to_speed`, `board_carves_without_tipping`, `board_ollie_height`,
  `board_kickflip_lands`, `board_50_50_on_rail`, `board_manual_holds`,
  `board_drops_in_to_quarter`, `board_bails_on_bad_catch`, and the `crowd` case
  with 25 boards (≥ 66 tps).
- Human: ride sessions on the player test server (VM 119149) with
  `bmx_debug 1`, using the same `docs/TUNING.md` process as the bike.

## Milestones

| M | Ship | Content |
|---|---|---|
| M1 | Ride | push, carve, brake, ollie, bail, procedural board |
| M2 | Flip | kickflip, heelflip, shove-its, tre, catch rules, scored |
| M3 | Grind | 50-50, 5-0, boardslide, lipslide, nose/tailslide, manuals |
| M4 | Style | grabs, reverts, switch, powerslide, carry SWEP |
| M5 | Look | deck model, deck graphics, sounds |

Each milestone goes to GitLab main and the test server as soon as it's green.
The Workshop gets M1 or M2 when the owner says go, ideally as a separate item
("BMX: Skateboards") cross-linked to the bike, or as the same item. That's
the owner's call.

## Risks

- **Feel** is everything, and it can't be judged headless. Budget real ride
  sessions per milestone.
- **Input design:** flick tricks on keyboard. Prototype two schemes (Skate
  flick on the mouse vs THPS direction+button) and let players pick.

## Status (2026-10-07)

M1 to M4 are built on branch `worktree-agent-a1d287f97fa46838c` (one commit each),
not merged, not on the Workshop. M5 (a real deck model, real sounds) is not started:
the board is procedural and the sounds are base-game placeholders recorded in
`sh_sound.lua` (`board_pop`, `board_push`).

- **M1 Ride:** `skateboard` through `RegisterVehicle`; the `board` balance
  (`sv_board.lua`), the `push` drive, truck steer, the ollie (pop height proportional
  to the hold), the stance setting, the edge bail, the procedural deck, trucks and
  wheels, and the rider's feet on the bolts with the push foot driven by the push phase.
- **M2 Flip:** nine flips, a 20 degree catch, scored and comboed, optional mouse flick.
- **M3 Grind:** ten grinds and slides through `grindPoints.moves`, manual and nose
  manual, one balance meter on the HUD.
- **M4 Style:** six grabs on the pose system, reverts, powerslide, switch, spin (180),
  `weapon_bmx_board`, bot tricks (Kickflip, Manual, 50-50 Grind).

Tests: offline `test_board.lua`, `test_board_flips.lua`, `test_board_grind.lua`,
`test_board_style.lua` (closed-loop rides on the plant); headless cases
`board_pushes_to_speed`, `board_carves_without_tipping`, `board_ollie_height`,
`board_kickflip_lands`, `board_bails_on_bad_catch`, `board_50_50_on_rail`,
`board_manual_holds`, `board_drops_in_to_quarter`, `board_crowd` (written, **not run**:
no server here).

**What the plant could not say, the biggest feel risks:** the carve (the tyre cap makes
slip large on a light chassis, see DESIGN 6d), the rider's pose on a real player model
(the seat is turned 180 or 0 degrees for regular or goofy and the pelvis is lowered by
a measured offset: every number is in `Tune` or `cl_board.lua`), whether the standing
base pose sits the root where the feet should be, the pop and the flip timing against
real VPhysics landings, and the bot's 50-50 timing. Ride sessions with `bmx_debug 1`
per the tuning guide.
