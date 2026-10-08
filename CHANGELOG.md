# Changelog

The top entry is always the version in `lua/autorun/bmx_init.lua`
(`BMX.Version`); the offline suite checks they agree. An entry says whether the
Workshop has it yet, because `main` and the test server move ahead of Steam:
a Workshop update goes out only when the owner says so.

## 1.2.0 -- not yet on the Workshop

Crashes that should not happen, gone; the board, skates, tandem and scooter
finished on a real server; and a bike that can ride itself.

- **Auto ride.** Press **O** (or `bmx_autoride`, or the button in the /bike
  window) and the bike rides itself with the trick bot's brain when the BMX (Mode)
  gamemode is running; any ride key takes it back on the same keypress.
  `bmx_autoride_key`, `bmx_autoride_allow`; hooks `BMX_AutoRideStart/Stop`.
- **No more flings.** Riding into a post, a goal or a bump stops the bike or
  rides it over instead of throwing it, cartwheeling it or sinking it into the
  floor. A quarter pipe ridden straight up rolls back down instead of looping
  you over backwards. On one wheel without asking for it, the rider leans the
  bike back down instead of going over the bars or the back.
- **Kerbs are kerbs.** A kerb or planter built from a frozen prop or entity no
  longer slides out from under a bike.
- **Holds on a hill.** Brake on a 10 or 20 degree slope and the bike stays put
  instead of creeping.
- **Ramps and vert.** A wheel at a ramp's top edge rolls over it instead of
  being kicked off it, so every bike rides up a 45 degree wedge and drops into a
  quarter pipe. Spine transfers carry you over the top, quarter-pipe coping no
  longer sticks out over the face, and the City Bike can wheelie. The Air 180
  off a quarter pipe is now a half turn about the ramp face, the way riders do
  it, so the bike comes back down facing the wall and lands. With the swept
  wheel on (`bmx_wheel_sweep 1`), the ground falling away past a crest no longer
  reads as a wall that stops the bike dead.
- **Skateboard and skates.** A quick SPACE tap always ollies, a drop-in stays on
  the quarter pipe and rides out, a bad catch bails, the skates' soul grind
  pays, and a grind or manual left alone is always lost in 2-3 s.
- **Tandem.** The captain's brake stops the stoker's pedalling and is strong
  enough for two.
- **Scooter** rides up a curb at kicking speed.
- **Bike rental.** A free vending machine (`bmx_rental`): press E, click a
  picture, ride. Idle rentals go back after 120 s.
- **Sound and look.** A real "ting" bell, a full set of bike sounds per vehicle,
  no pedals on motorbikes, hands and feet on the bars and pedals, no flash of
  the simple bike while a model builds, and model builds no longer run the
  client out of memory.

## 1.1.1 -- on the Workshop 2026-10-07

A small update on top of 1.1.0, from riding every vehicle in game.

- **Riders look better on the odd vehicles.** The unicyclist holds their arms
  out at chest height with open hands, balancing against the lean, instead of
  stiff fists at the hips. The skateboarder and the scooter rider ride on bent
  knees, deeper with speed, instead of locked-straight legs.
- **Every spawn-menu picture shows the new model**, shot in game: the road
  bike's drop bars, the city bike's basket, the dirt bike's bodywork, the
  skateboard's trucks and so on.
- `bmx_report` and the model cache can say which vehicle models are built,
  still building, or failed and why (`BMX.BikeMesh.Status`).

## 1.1.0 -- on the Workshop 2026-10-07

The first update since the Workshop item went up. One BMX became a garage:
nine bikes, a skateboard, a kick scooter and inline skates, with a picture of
each in the spawn menu. Everything below is new to subscribers unless it says
otherwise (the posted 1.0.0 build was not recorded, so combos and the steadier
camera may already have reached some of you).

**Split into three pieces.** This addon is now only the vehicle mod. The
games (SKATE, Trick Attack, Combo Mambo), personal bests and the leaderboard,
and the trick bot are the **BMX (Mode)** gamemode (gmod/gmod-bmx-mode); the
city around the park is the **petopia_bmx_fall** map (gmod/petopia_bmx_fall).
None of them was ever on the Workshop, so nothing a subscriber had is taken
away. Every vehicle's code, models and sounds stay here.

**New bikes**

- **BMX Cruiser** (24-inch: longer, heavier, faster at the top end, slower
  off the line) and **Mini BMX** (16-inch: short, light and quick).
- **Road Bike**: 700c wheels, eight gears (`]` / `[` or the mouse wheel),
  drop bars and a tucked rider, about 1.6x the BMX's top speed; tricks on it
  score x1.5.
- **Fixie**: the cranks are locked to the rear wheel, so S is a skid stop,
  pedalling backwards is a fakie, and standing still is a trackstand.
  `bmx_fixie_frontbrake 1` gives it a front brake on left mouse.
- **City Bike**: upright, heavy, a coaster brake, a basket that keeps small
  props in while you ride gently, and a child seat.
- **Downhill Bike**: long travel, big tyres, heavy and stable.
- **Unicycle**: one wheel, balanced by pedalling and leaning, with an assist
  you can turn down (`bmx_unicycle_assist`, 0 is as hard as the real thing).
- **Penny-Farthing**: a huge front wheel with the pedals on its hub and the
  rider up high; a hard front brake at speed takes you over the bars.
- A **Tandem** (two seats, both pedalling, the front rider steers) is in the
  spawn menu too; its steering is still being tuned, so it is not on the page.

**Boards, scooter and skates** (new, and still being tuned)

- **Skateboard** (Boards in the spawn menu, or carry it with the Skateboard
  weapon): push, carve, ollie and nollie, nine flip tricks with a catch window,
  ten grinds and slides, manuals with a balance meter, grabs, reverts,
  powerslides and switch.
- **Kick scooter**: kick to push, a rear fender brake, bunny hop, tailwhip,
  barspin, bri flip, flips, manuals, and 50-50, smith and feeble grinds.
- **Inline skates** (the Skates weapon): stride, crossover, T-stop, jump, and
  soul, mizou and backslide grinds; spins score on the landing.

**Motor vehicles** (Motor in the spawn menu; admins only by default, through
the CAMI privilege "BMX - Spawn Motor Vehicles", and `bmx_allow_motor 0` turns
them off): an **E-Bike** (pedal assist in three levels, a battery that drains
and recharges), an **E-Moto** (throttle and regen), a **Dirt Bike** (torque
curve, five gears, a clutch to pop wheelies, FMX poses) and a **Moped** (pedal
it off, then the engine takes over). They sound a horn instead of a bell.

**Riding together, parking up**

- **Pegs**: E at the back of a friend's BMX or Cruiser rides their pegs, and
  the City Bike has a child seat. A passenger makes the bike heavier, doubles
  the trick score, and is thrown off with the rider in a crash.
  `bmx_passengers 0` switches it off.
- **Bike rack**: a rack that welds to the nearest car (the engine's own,
  simfphys or LVS) and carries two bikes. E on a racked bike lets it down.
- **Bike lock** (a weapon): left click locks a parked bike to the ground,
  right click unlocks. Only its owner or an admin can unlock it, ride it or
  pick it up.

**Tricks**

- **Combos**, the Tony Hawk way: chain airs, grinds and manuals into one
  line, then land it and the chain pays again for every trick past the first.
  Bail and the bonus is gone. The HUD shows the chain, the multiplier, then
  LANDED or BAILED.
- **Tailwhip** (left mouse + A / D in the air) and **barspin** (R in the air
  or a manual).
- **Style poses**: hold ALT in the air with W / S / A / D / SPACE for a
  no-hander, no-footer, can-can, superman, X-up, turndown, tabletop and more,
  stacked on any flip ("Backflip Superman").
- **Nose manual** (CTRL + left mouse leans over the bars), off until it has
  been ridden on your server: `bmx_nose_manual 1`. `bmx_lmb_mode lean` swaps
  left mouse to the lean.
- **Off a vertical ramp**, A / D turn you round to ride back down (Air 180),
  the landing is aimed down the ramp, and W near the top of a spine carries
  you over (Spine Transfer). `bmx_air_assist 0` turns it off.
- RMB + A / D in the air is a spin (a 360), stronger than before, and no
  longer also a barrel roll.

**Pictures, models and sound**

- **A picture for everything.** Every bike, board, weapon and park piece in
  the Q menu has a picture of the real thing, rendered in game, instead of the
  grey placeholder; the /bike window shows them too, and a park piece's
  picture follows the size and variant you pick.
- **A detailed bike.** The BMX, Cruiser and Mini are full models built in
  code: welded frame and gussets, a raked fork, bars with a crossbar, a brake
  cable through a gyro detangler to a U-brake, laced 36-spoke wheels on
  skinwall tyres, knurled chrome pegs, a link chain on 25/9 gearing, pinned
  pedals and a bell on the bars. Metallic paint in the bike's colour, chrome
  that reflects, and every part moves as it should. Built models too: the
  Road Bike (drop bars, calipers, 2x11 with derailleurs) and the Fixie (deep-V
  rims, a fixed cog, bullhorns); the Unicycle (a 20" trials uni), the
  Penny-Farthing (a 52" ordinary) and the Tandem; and the motor vehicles as
  real motorbikes (a 250 four-stroke motocrosser, a Sur-Ron-style e-moto, a
  Ciao-style pedal moped). The City Bike, Downhill Bike, E-Bike and the
  boards draw the simpler shapes until theirs are built. `bmx_bike_model 0`
  draws the simple bike everywhere.
- **A real bell.** R on the ground always rings the bell, whatever else you
  hold, at once, and fast enough to ring-ring. The bell is the addon's own
  sound (a struck steel dome, computed, not recorded), so it now comes with
  the addon. `bmx_bell 0`, `bmx_bell_cooldown`.
- Wind that grows with speed, a freewheel tick, and **water**: wheels drag in
  it, it splashes, and it throws you off at chest height (`bmx_water`,
  `bmx_water_eject`). Volumes are yours: `bmx_vol_ride`, `bmx_vol_wind`,
  `bmx_vol_bell`; `bmx_sounds 0` mutes every bike for everyone.
- **Rider poses**: standing or attack riding stances, each vehicle with its
  own pose (tucked on the road bike, upright on the city bike, the
  motorcyclist in the attack position, elbows up and knees on the tank), and
  a passenger's hands on the rider's shoulders.

**Spawning, settings, cameras and replays**

- **/bike**: type it in chat (or `!bike`, `/bmx`, `bmx_menu`) for a window of
  every vehicle and park piece; a click spawns it where you look. For servers
  whose gamemode has no Q menu.
- **Park pieces**: 15 ramps, rails, ledges and quarter pipes in three sizes,
  with a snapping build tool. A piece settles upright and frozen on the ground
  under it (`bmx_park_ground`); `bmx_park_max` caps them.
- **Options > BMX**, a settings menu for players and server admins, with
  CAMI privileges for who may change what, and `bmx_reset_client` /
  `bmx_reset_server`.
- **Replays**: J plays back your last 30 seconds from four cameras, slowed
  down if you like, and saves the clip.
- A trick camera that pulls back in the air, and a combo and airtime line on
  the speedometer.
- **Server settings**: `bmx_max_per_player N` caps the vehicles one player
  can have out, `bmx_scoring 0` turns scoring off, `bmx_combos 0` keeps trick
  points but drops combo bonuses.
- `bmx_stick_deadzone` (default 0.1), so a gamepad stick resting slightly off
  centre no longer holds a slow turn.
- Crashes can be handed to **RagMod** if the server has it (`bmx_ragmod 0`
  keeps our own ragdoll).
- `bmx_report` prints a block to paste into a bug report.
- `bmx_nav_build` meshes a map into a navmesh a bike can use (props and every
  layer included), for gamemodes and bots built on BMX.

**Changed (how it rides)**

- **No see-saw off a ledge**: a landing now matches the surface's pitch as
  firmly as its roll, and the spring-back is soaked up after touchdown, so the
  bike lands flat instead of rocking.
- **The chase camera** no longer sways with the bike's lean, and eases after
  its turns and ramps instead of being bolted to it: the heading follows in
  about 0.4 s and a ramp tilts the view by about a third of its slope. The
  mouse is as immediate as ever. `bmx_cam_smooth 0` brings the old camera
  back.

**Fixed**

- **Holding A or D off a ramp no longer barrel-rolls the bike.** A side key
  held at takeoff is ignored until let go, as W / S already were; a fresh
  press still rolls.
- The bell was a door chime pitched up, heard a round trip after the press,
  swallowed while right mouse was held, and silent on a quick second press.
- Park pieces spawned on a server were never frozen, so a piece could be
  knocked off its spot.
- The bike rack errored and vanished once the last-drawn bike was removed.
- The hidden debug test cart was spawnable from the menu.
- A bike registered with `physics` overrides threw on its first grind or trick.

**Behind a switch, off until ridden on a real server**: swept wheel contact on
steep faces and curbs (`bmx_wheel_sweep`), the nose manual hold
(`bmx_nose_manual`), lean prediction for your own bike (`bmx_predict`,
client), tick-dated trick inputs (`bmx_lagcomp`) and a double-tap flip
(`bmx_flip_doubletap`, client).

**Under the hood**

- Every vehicle is built on one platform (`BMX.RegisterVehicle`: any number of
  wheels, balance modes, input maps, pose sets, grind points), with public
  `BMX_` hooks documented in docs/MODDING.md and `BMX.AddPrivilege` for other
  addons.
- Authors are **Burrito** everywhere a player sees one.
- The Workshop item ID (3814420080) ships in the upload kit, so an update needs
  nothing typed and the first-upload script refuses to make a second item.
- The offline suite went from 352 to over 1100 tests, among them a check that
  every menu entry has its picture, every sound the code plays is in the
  `.gma`, and every author is Burrito. The headless suite on a real server is
  green.

## 1.0.0 -- tagged 2026-09-27; the Workshop item was posted 2026-10-05

(The posted build was not recorded, and its size matches neither v1.0.0 nor
the combos commit exactly, so combos and the steadier camera below under 1.1.0
may already be on the Workshop. From 1.1.0 on, the release tag is the record.)


Lean-to-steer riding on raycast wheels with a real tyre model; pedalling,
braking and skids; wheelies, manuals, stoppies, bunny hops, flips, barrel
rolls and 360s with on-screen scoring; crank and double-peg grinds found
automatically on any map; slope-matched landings; ragdoll crashes; an IK
rider on a procedural bike; 14 paint colours; and a GTA-style cinematic camera.
