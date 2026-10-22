# Changelog

The top entry is always the version in `lua/autorun/bmx_init.lua`
(`BMX.Version`); the offline suite checks they agree. An entry says whether the
Workshop has it yet, because `main` and the test server move ahead of Steam:
a Workshop update goes out only when the owner says so.

## 1.4.0 -- not on the Workshop yet

The animation update. Riders now move the way real riders do. Their joint angles
were measured from footage of real skaters, BMX riders and scooter riders, and
every vehicle's rider was filmed and compared side by side. Every part of the body
is checked against the bike and against the rest of the body, so arms and legs no
longer pass through things.

**Skateboard**

- **You ride it like a skater.** Before, you stood upright on the board with soft
  knees. Now your hips sit back over your heels, your knees are bent and your chest
  leans over your toes. You crouch deep before an ollie and lean into carves.
- **Your feet stand on the deck.** Before, they hung off the heel edge and floated
  above the grip tape. Now they stand on it, the front foot angled toward the nose,
  your knees over your toes, and a slightly wider stance.
- **Pushing:** your foot plants on the ground and stays there while the board rolls
  on, then lifts when your leg is stretched out behind. Before, it slid along the
  ground. Your hips turn forward for the push, and the step off the board is no
  longer a snap.
- **Ollies:** the tail snaps and the nose comes up. Your front knee drags up as the
  back leg straightens, then the back knee comes up as the front foot levels the
  board. Your arms go up with the pop and your knees come up in the air. You land
  soft and stand back up.
- **Grabs** bring the board up to your hand, knees tucked to your chest, instead of
  you bending down to it. Your knees open to let your hand through.
- **Manuals:** your weight shifts over the back wheels, and your arms balance out
  wide without going into a T. You ease into and out of it.
- **Never still:** you breathe, your weight shifts from foot to foot, and your arms
  swing when you speed up, slow down or turn.

**Bikes**

- Seated riders lean toward the bars instead of sitting bolt upright. Standing and
  attack fold further over the bars, as riders on footage do.
- **Every rider breathes** and shifts their weight a little.
- **Smoother:** your knee no longer jumps once per pedal turn at the top of the
  stroke, and your body absorbs a bunny hop and its landing instead of jerking
  with the bike.
- **Tricks no longer go through the bike or yourself:**
  - **Heel clicker:** your legs swing forward over the bars and click in front.
  - **Cliffhanger:** your legs go up over the bars and your hands go up.
  - **X-up:** the bars turn 140 degrees and your arms cross without passing
    through each other.
  - **Can-can:** your leg arcs over the top tube instead of through it.
  - **Tabletop:** your hips roll over with the bike.
  - **Superman with a passenger:** your legs spread past them instead of going
    through them.
- Motorbike riders' knees sit outside the side panels instead of inside them.
- **Penny-farthing:** you stay seated, since the pedals are on the hub. Your knees
  splay past the fork, and the big wheel turns no further than your legs allow.

**Scooter and passengers**

- **Scooter:** your feet stand on the deck (they floated above it). The back foot
  is turned out behind the front one, your knees go either side of the stem, and
  your kicking foot plants on the ground and goes out past the deck's edge.
- **The child seat** is now on the rack over the rear axle. Before, it sat so close
  that the passenger sat inside the rider.

For modders and testers:

- `tests/test_body_clip.lua` checks every part of every rider's body against every
  vehicle and against the rest of the body, through each move and trick. 1.3.9 had
  637 places where a body part went through something; 1.4.0 has about 240, nearly
  all in style tricks. They are listed and cannot get worse.
- `tests/test_lifelike.lua` holds the rider's joint angles to what real riders do.
- `tools/rider/studio/video.sh` films any rider offline, `motion.py` finds jerks
  and sliding feet, and `tools/rider/compare.py` puts a film next to real footage
  with both riders' joint angles plotted.

## 1.3.9 -- on the Workshop 2026-10-20

Riders that look like riders. Every vehicle's rider was looked at on the real
player model, pose by pose, and on a real game client.

**Skateboard**

- **Relaxed hands.** The hands hung bent back at the wrist with the palms down,
  like paws. They now hang loose at your sides, wrists straight.
- **Hands open again after a grab.** One grab used to leave both hands as fists
  for the rest of the ride. Now only the grabbing hand closes, and it opens
  again when you let go.
- **You look where you are going**: up the board toward the nose (the tail,
  rolling fakie), and into turns, instead of out to the side.
- Softer knees and a slight lean while riding, a much deeper crouch before an
  ollie, and the knees tuck up for a grab. Pushing, the arms swing by the body
  instead of folding into your thighs.
- **Carrying a board shows the board**, hanging from your hand by its front
  truck, instead of a grey plate held out in front.

**Bikes**

- **Standing and attack stances leave the saddle.** They used to keep you sat
  with a straighter back. Now your hips come up, as far as your legs still reach
  the pedals, with your elbows bent. Sprinting stands you up too.
- **Fists on the grips**: round the middle of the grip with the thumb wrapped
  under, instead of half on the bare bar with the thumb sticking up.
- No-hander hands open; superman legs go straight back; a no-footer kicks the
  legs out wide.
- A passenger stands up on the pegs, hands resting on your shoulders. A
  unicyclist holds the arms out for balance.

**Skates and scooter**

- On skates the arms hang loose and swing with each stride, the stance is lower,
  and you look up the road. The grey plate that floated at every skater's waist
  is gone.
- Hands and feet stay on the bars and pedals even when a rider is drawn before
  their vehicle, or with it off the edge of the screen (a scooter rider's hands
  trailed behind the bars).

For modders: `tools/rider/studio` draws any vehicle's rider on the real Kleiner
model, offline, from several cameras.

## 1.3.8 -- on the Workshop 2026-10-19

A fix for crashes on fire, and the Workshop page brought up to date.

- **On fire, you stay on fire after a crash.** Getting up from a crash put
  the flames out, so a rider who was set alight could crash on purpose to be
  cured (seen on a real DarkRP server). The ragdoll now burns while you
  tumble, and you are still burning when you get up, for the time the fire
  had left. If the ragdoll lands in water, the fire stays out.
- The Workshop page's "New in" line now covers 1.3 instead of 1.2.0.

## 1.3.7 -- on the Workshop 2026-10-19

No more stutter the first time a vehicle shows up; skates on a server with any
lag, checked on a real game client at 100 and 200 ms of ping; and two skates
faults the same run found.

**Frame rate**

- **No more stutter the first time you see a vehicle.** The first time a kind of
  vehicle shows up in a session, its detailed model is built while you play, a
  few milliseconds a frame. Dozens of those frames used to jump to 20 to 90 ms
  for a BMX, a road bike or a motorbike: the build threw out hundreds of
  megabytes of scratch data for the game to clear away, handed each finished
  part to your graphics card in one lump of up to 58,000 points, and then
  forced two full clean-ups of all your game's script memory. It now throws
  away a sixth as much, keeps strictly to its few milliseconds a frame, hands
  its parts over in pieces small enough for one frame, builds the vehicles on
  your screen before the ones across the map, and forces no clean-ups. A model
  is ready in under half the frames it took, none of them over 16 ms in our
  tests, and every vehicle looks exactly as it did. `bmx_bike_build_report`
  prints what each build cost on your machine.

**Skates on a server with lag**

- **Skating is predicted exactly.** On your own screen, skates kept being pulled
  back to where the server had you: striding and carving at 100 ms of ping put
  you up to 120 units out (196 at 200 ms), corrected over and over, and even
  with no lag at all up to 41 units. Your game checks its guesses again every
  few moves, and each time it did the skates' own state got muddled. Riding is
  now exact at 100 and 200 ms.
- **Grinding keeps you on the rail.** Tapping A or D to balance slid you
  sideways off the rail on your screen and snapped you back, 26 units at 100 ms
  and 48 at 200, and turned your view too. You now stay on the rail where the
  server has you, and A and D leave the view alone.
- **Popping off a rail is instant.** Letting go of SPACE left you on the rail for
  a moment, then threw you up all at once. You pop off the moment you let go
  now, and off a ledge you pop away from it.
- **Skates settle after a lost packet.** With packets going missing, the
  corrections used to keep coming; now they settle within a few moves.
- **Taking the skates off stops you where you are.** Switching weapons while
  rolling let you glide on, then snapped you back 26 to 56 units.
- Locking onto a rail is still the server's call, so turning onto one for a
  backslide can jump once as it locks on.

**Skates**

- **SPACE jumps on flat ground.** On skates the jump only worked straight after
  being moved (a respawn, say); on flat ground the game kept you on the floor.
- **The end of a rail is smooth.** Right at a rail's end you were moved a few
  units along it in one step, which showed as a jolt as you dropped off.

## 1.3.6 -- on the Workshop 2026-10-19

Players reported low frame rates: a frame of BMX now costs your game much less
(measured offline, frame by frame, with every rider's pose and every drawn part
checked identical to 1.3.5). Also a DarkRP exploit closed, and combos that
reward variety instead of spamming one trick.

**Frame rate**

- **Riders near you are much cheaper to draw.** To keep each rider's hands on
  the bars and feet on the pedals, the game re-posed the rider's whole skeleton
  about 58 times a frame (49 on a scooter, 42 on a board), half of those times
  on a skeleton nothing had moved. It now re-poses only when something moved:
  about 11 times a frame for a rider pedalling, one to three for one standing
  on a board or a scooter. Eight riders around you went from about 470
  skeleton poses a frame to about 90, and every hand and foot lands exactly
  where it did before.
- **Motorbikes and the DH bike draw their shock spring for less.** The coil was
  rebuilt from scratch every frame with every point worked out four times, the
  dearest thing those bikes drew. Each point is worked out once now, and past
  350 units, where the coil is a few pixels across, it is drawn with fewer
  rings.
- **Less waste every frame for every bike in the world.** A bike no longer
  looks up its own model by name twice a frame; the sounds, the motor note and
  the grind sparks share one look through the map's entities instead of three;
  and the paint, the lighting and the HUD stop making throwaway text and
  tables.

**Scoring**

- **Combos reward variety.** The same trick again in one combo now adds less to
  it each time: all of it, then three quarters, a half, a quarter, and from the
  fifth time nothing, not even to the multiplier. Every trick still pays its
  own points and still keeps your combo going. Before, the multiplier counted
  every trick whatever it was, so spamming your best trick beat a real line:
  ten backflips paid 50,000 and ten different tricks 35,550, and twenty jumps
  on the spot on skates made a 30,000 combo. Now the backflips pay 8,750, the
  jumps about 2,000, and the ten different tricks still 35,550. A server that
  wants the old rule can set `bmx_combo_variety 0` (in the server settings,
  under Rules and scoring).

**Crashes**

- **Getting up from a crash is not a respawn.** On DarkRP, getting back up
  after a crash counted as a fresh spawn: five seconds of spawn protection, so
  crashing on purpose made you impossible to hurt and the crash itself never
  did any damage; it also filled your hunger right up and could stand you up
  wearing a different job model. Now you get up as you went down: same hunger,
  same model, no protection, and the crash hurts. An admin in god mode also
  stays in it after a crash, which they used to lose on any server.

## 1.3.5 -- on the Workshop 2026-10-15

The first Workshop update with the 1.3.4 fixes below, plus one more.

- **Saving a BMX file on a running server no longer breaks the skates.** Garry's
  Mod re-runs a file you change while the game is running (or when a new copy
  of the addon is put over the old one). When the trick list's own file ran
  again, it forgot every trick the other files had added. Depending on the
  order the files ran in, the skates then refused to load ("tricks lists
  board180, which is not a registered trick", seen on a live server),
  motorbikes could lose the heel clicker and the cliffhanger, and the pose
  numbers could be dealt out again in another order. The other way round, a
  board, scooter, skates or motorbike file run again by itself stopped at its
  first trick with "duplicate id". The list now keeps what it has, and a file
  that runs again updates its own tricks in place. One trick name claimed
  twice, by two files or twice in one, is still an error. Players on the Workshop version
  never saw this; server owners who edit or update the files without
  restarting could.

## 1.3.4 -- on the Workshop with 1.3.5 (2026-10-15)

A bug audit of the whole addon. Nothing here was reported by a player; each was
found by reading the code and is reproduced by a test that failed before the fix.

**Rules that could be got round**

- **A pasted dupe follows the spawn rules.** Pasting a bike (or loading a save)
  skipped every check a spawn makes: the per-player limit, the vehicle switches,
  the motor-vehicle permission, the no-spawning-while-dead rule and the server's
  entity limit. The copy also had no owner, so it never counted against the
  limit and anybody could lock it. Park pieces and the bike rack could be pasted
  past the park's piece cap the same way. All of them now ask exactly what the
  spawn menu asks, and belong to whoever pasted them.
- **A pasted locked bike shows no padlock.** It came up free but still drawn
  chained, saying "it is not locked" when you tried to unlock it.
- **A car pasted with bikes on its rack keeps them on the rack.** They hung from
  the copied weld running their own wheels, and the rack said it was empty.
- **`bmx_color` only paints a parked bike you could paint from the menu.** It
  repainted anybody's bike, a locked one too, with smoke for everyone near.
- **The bike rack is the owner's.** Pressing E on somebody else's free-standing
  rack welded it to your car, and you could drive off with it and their bikes.
  A racked bike (which cannot be locked) came off for anybody; now only for the
  bike's owner, the rack's owner or an admin.
- **The park tool asks the server, and removes only your own pieces.** Placing
  skipped the entity limit and admin-mod rules, and Reload removed anybody's
  piece, so a park somebody else built could be taken apart a piece at a time.
- **Skates are not given to the dead, to spectators, or past the per-player
  limit** (`bmx_give_skates`, `bmx_spawn skates`).
- **`bmx_dump_config` is for admins** (some 370 console lines a call).

**Scoring**

- **No points for waiting.** "Air Time" kept counting while a bike hung on a pipe
  by its frame with its wheels in the air: 120 points a second.
- **No grind pays a half tailwhip.** Locking onto a rail with the frame or bars
  part way round, or still in a style pose, paid the air there and rounded a half
  tailwhip up to a whole one, where on the ground it would have been a crash.
  The bike now goes on through the air and is judged where it lands.
- **Skates: noclip in the middle of a grind ends it, unpaid.** The grind's clock
  ran on through noclip and paid every second of it on the way out.
- **A board steps on in its new rider's stance.** The last rider's switch stayed
  on the board, so the next rider stood the wrong way round and every trick was
  paid as "Switch".

**Crashes**

- **A crash a gamemode cancels does nothing at all.** The combo was still lost,
  the basket emptied and `BMX_Crashed` fired, every tick for a bike lying on its
  side.
- **Getting up keeps the rounds in your guns.** Every crash ragdoll emptied every
  magazine.
- **Killed or respawned while ragdolled, you are not stood back up** 1.6 seconds
  later with your old health and weapons.
- **Skates: a bail without the ragdoll is a bail.** With crash ragdolls off (or
  in TTT) the skater was thrown at twice their speed for a moment and then put
  back to it; the bail only did damage.
- **Nobody gets on a bike somebody is holding** with the physgun or gravity gun
  (the holder could fling the rider about).

**Replays**

- **No rider drawn on a parked bike.** Every bike near you was replayed with a
  rider on it, a parked bike, a rental or a racked one too. Saved replays record
  who rode what (older replay files still load as before).
- **The rider's name and model follow whoever rides the bike.** A bike first seen
  parked kept a blank name for the rest of the session.
- **A damaged replay file is refused, not shown** (it errored every frame).

**Drawing and the rest**

- **Ragdolls that are not ours keep their own colour.** Sandbox ragdolls and TTT
  corpses could show another player's colour.
- **Wheels and pedals turn at the right speed in a reflection.** A bike seen in
  water or a mirror is drawn more than once a frame, and turned its wheels, its
  cranks and its rider's legs on every pass.
- **Turning off rider IK while riding puts the hands and feet back.**
- **A passenger's L does nothing** (it was letterbox bars with no camera).
- **The city bike's basket tells the engine when a prop goes in and out,** which
  it must when a collision rule changes.
- **The child seat gives a player back the size they had,** not the default.
- **A board put down from under your arm can be undone with Z** and is in your
  cleanup. A rented board cannot be picked up and kept.
- **The cleanup panel has a "BMX vehicles" button.**
- **Bots' paths:** placing a park piece no longer leaves overlapping copies of the
  ground in the navmesh, and planning a long path no longer stalls the server.
- **A stray global** (`gP`, from the unicycle) is gone; the syntax check now fails
  any file that sets a global other than `BMX`.

## 1.3.3 -- on the Workshop 2026-10-12

The last riders who did not fit their vehicles, found by riding every vehicle on
a real player model's skeleton:

- **Dirt bike: both hands on the bars.** The left hand was two units short,
  more at full lock. The rider now leans on to the bars when they are far,
  instead of twisting back and forth.
- **Scooter: hands stay on the bars through the kick.** Riders stood bolt
  upright between kicks with the bars at arm's length, so as each kick ended the
  hands came off them and the body pumped back and forth chasing them. Riders
  now stand leaned over the bars, as on a real scooter.
- **Hands don't slip off the bars when the body moves fast.** At lower frame
  rates a fast move -- dropping into a scooter kick, the pop of a hop -- left a
  hand up to eight units off the bar for a frame, because each joint could only
  turn so far per frame. The arm and the wrist now keep turning until the hand
  is there, and when a hard landing or a hop throws the bars out of reach the
  rider leans in for them at once rather than over several frames.
- **Riders ride the bike through a landing.** The bike is drawn sitting on its
  wheels, so a landing that squashed the suspension lifted the saddle, pedals
  and bars while the rider stayed where they were: hands came off the bars and
  a foot off its pedal for a moment. The rider now rises and settles with the
  bike.
- **The bike shown while a new model loads fits its rider.** For the few
  seconds a vehicle's model takes to build the first time, a simple bike stands
  in. On every vehicle longer than a BMX it was a BMX stretched to the length,
  with a saddle, pedals and bars a rider could not reach: the tandem's riders'
  feet hung off the pedals, and turning the dirt bike or the city bike took the
  hands off the bars. It is now an ordinary-sized bike cockpit under the rider
  (two on the tandem, one under each), joined to the real wheels. The city
  bike's hands hold its swept-back grips.

## 1.3.2 -- on the Workshop 2026-10-11

Hands on the bars and feet on the pedals, on every vehicle. Measured on a real
player model riding each vehicle in turn, frame by frame:

- **Tandem: both riders reach their bars.** The captain sat bolt upright over
  drop bars and was two units short of them; the captain now rides tucked, as on
  the road bike. The stoker's hands hung four units short of their bars: the
  torso lean that reaches for them was worked out but never drawn on a
  passenger. It is now, and a stoker leans forward to their bars as a road
  rider does.
- **Penny-farthing: feet on the pedals all the way round.** The saddle was so
  high that no player's leg reached the bottom of the stroke, and the hands
  were short of the bars. The saddle is lower (the backbone now hugs the big
  wheel to make room) and the pedals sit in the inner end of the crank slots,
  as on a real one.
- **Toes point for a far pedal.** When a pedal is just out of reach at the
  bottom of the stroke, the ankle extends to keep the foot on it, as a real
  rider's does, instead of the foot leaving the pedal.
- **No snap when a vehicle's model finishes building.** While a new vehicle's
  model builds, the simple bike is drawn; when the model appeared every grip and
  pedal moved at once and the riders' hands and feet jumped up to ten units in
  one frame. They now ease across in a fifth of a second.
- **Skaters stand up.** A skater's arms out for balance were treated as hands
  on handlebars: fists closed, and the body bent 30 degrees over trying to reach
  them. The hands are open now and the body is the skater's own; a grab still
  closes a hand on the deck.
- **No one-frame flicker off the bars.** At the bottom of a scooter kick or on a
  hard landing the hands came off the bars for a single frame, by up to eight
  units. The hand is placed again in the same frame when the body moves that
  fast.

## 1.3.1 -- on the Workshop 2026-10-11

- **Riders look through corners.** The head turns a little way into the turn
  the bike is making, and over the shoulder into a spin, then back to the road.
- **Spine transfers land.** About one in seven came down on the far side tail
  first and threw the rider, or overshot onto the floor. The transfer now aims
  half way down the far face and pitches the bike over onto it as it comes down.
- **Your bike is yours.** A bike rack only loads your own bike (or one nobody
  owns), and only welds to your own car or one nobody owns, so it is no longer a
  way round prop protection. The bike lock only locks your own bike (or one
  nobody owns): somebody else could lock yours and leave you unable to ride or
  move it. Admins (the "BMX - Unlock Any Lock" privilege) may do either.

## 1.3.0 -- on the Workshop 2026-10-11

No more freeze on spawn, riders that move like riders, and a round of fixes
for servers.

- **No more freeze when you spawn a vehicle.** The first time you spawned each
  kind, the game stopped for up to a second while its model was built (players
  reported it: "my frames go down the drain when I spawn something"). It is
  built a little at a time now, with the simple bike shown meanwhile, as before.
- **Riders look up the road.** On real player models every rider's head was
  nodded down onto their chest, looking at the ground. The head now holds the
  horizon however far the rider tucks, and drops in the air to spot the landing.
- **Smooth, not snapped.** Sprinting, changing stance, leaning forward, a hop
  and a landing used to jump the body into place in a single frame. Each eases
  in and out now, the same at any frame rate. Trick poses (no-hander, superman,
  X-up...) ease in and out too.
- **A back that bends.** Leaning forward curves the whole back instead of
  folding it at the shoulder blades.
- **Pedals that coast.** The legs used to keep pedalling down every hill and
  spin in the air with the back wheel. Now they pedal when you pedal; let go and
  the pedals come level and stay, ready for a jump. Out of the saddle
  (standing, attack, sprinting) the shoulders rock with each stroke. A fixie,
  a unicycle and a penny-farthing still turn with the wheel, as real ones do.
- **Riders across the park keep pedalling** instead of freezing mid-stroke.
- **Singleplayer: the gear keys, L (cinematic camera) and the replay keys work.**
  They did nothing in singleplayer before.
- **TTT and other round-based gamemodes:** a crash no longer takes a traitor's
  credits and equipment (the crash is the shove there, not the ragdoll), and dead
  players and spectators can no longer spawn bikes or park pieces into a round.
- **The Server settings page shows what the server really runs.** On a
  dedicated server it showed every setting at its default, whatever the server
  had saved, and players' games never saw a server's settings at all (the bell
  switch, the e-bike limit, the tuning sliders...). They do now. Singleplayer
  was always right.
- **For server owners:** the rental machine now asks for the "BMX - Spawn Motor
  Vehicles" privilege before handing out a motorbike or e-bike, as the spawn menu
  does; `bmx_selftest` is for the server console or a superadmin; the bike colour
  menu has the same short cooldown as K; a client can no longer pass "nan" for
  `cl_interp` to stretch the lag compensation (`bmx_lagcomp 1` only).
- Skates no longer stop you moving in noclip or on a ladder.
- A copied or saved bike rack no longer drags the original's bikes off with it,
  and a copied locked bike comes back unlocked instead of welded down for good.
- The board's kick and the bike's forward lean were sent to clients in the same
  networked slot, so each could overwrite the other; they have one each now.

## 1.2.1 -- on the Workshop 2026-10-10

Fixes for 1.2.0, two of them from players' reports.

- **The Server settings page opens again** (spawn menu > Options > BMX >
  Server). In 1.2.0 it showed an error and no settings for everyone, in
  singleplayer and on servers alike. It now shows every server setting, and
  says why they are greyed out if you are not allowed to change them.
- **A gamepad on skates.** Your own game now reads a part-pushed stick the way
  the server does. It used to read it as no stick at all, so the server kept
  correcting where you were.
- **A bad landing no longer trips the game's "Changing collision rules within
  a callback" warning**, which can crash a server: the rider is thrown just
  after the physics step instead of in the middle of it.
- **A front flip on the keys** works the way the trick bot does one: let go of
  W at the lip and press it again as you leave the ramp.
- A motorbike rider in the attack stance at full speed leans forward at most
  45 degrees (it added up to 62), hands still on the bars.

## 1.2.0 -- on the Workshop 2026-10-08

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
