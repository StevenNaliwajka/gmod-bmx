# Modding BMX

What another addon, a gamemode or a server owner can build on without
touching this one. Everything here is **public API**: it is documented, it has a
test (`tests/test_hooks_doc.lua`), and from the next major version a breaking
change to it needs a major version number.

Anything not in this file (the `BMX.*` functions of the simulation, `ent.st`,
the `sv_*` internals) is private and may change in any release.

## 1. Registering a bike

A bike is one table, registered from any file that loads after this addon
(an addon's own `lua/autorun/*.lua` is fine; `BMX.RegisterBike` works after
load, and derives its entity class on the spot):

```lua
BMX.RegisterBike("chopper", {
    printName   = "Chopper",
    description = "Long, low and slow.",
    colorIndex  = 4,                 -- which BMX.Palette colour it starts in
    physics = {
        Chassis = { mass = 110 },
        Wheel   = { wheelbase = 52, radius = 11 },
        Drive   = { crankTorque = 300000 },
    },
})
```

The id is lower-case and becomes the entity class `bmx_<id>`
(`BMX.ClassFor("chopper")`). It appears in the spawn menu under BMX, in
`bmx_spawn chopper`, in the duplicator, and as `ent.BikeID`.

It also needs a picture: `materials/entities/bmx_chopper.png`, 128x128. The suite
fails without one (`tests/test_spawn_icons.lua`). Shoot it in game with
`tools/icons/shoot.sh bmx_chopper`; see `tools/icons/README.md`. An addon of your
own puts the icon in its own `materials/entities/`.

### Registry fields (`lua/bmx/sh_bikes.lua`)

| Field | Meaning |
|---|---|
| `printName` | Spawn menu label. |
| `description` | Spawn menu tooltip. |
| `author` | Shown in the spawn menu; defaults to the addon's. |
| `model` | Frame model. **Optional**: without one the whole bike is drawn procedurally. |
| `frameOffset`, `frameAngles` | Align a model to the axle line (`Vector`, `Angle`). |
| `scale` | Model scale, for stand-in props that are not bike-sized. |
| `wheelModel`, `forkModel` | Optional; absent, wheels are drawn procedurally. The fork is drawn steered with the front wheel. |
| `seatModel` | Model the invisible pod uses; only its seat attachment and sit animation matter. |
| `colorIndex` | Starting `BMX.Palette` index (`sh_color.lua`). |
| `physics` | Per-bike config overrides, below. |
| `gears` | `{ ratios = { 1.2, 1.5, ... }, start = 4 }`: **2 to 11 gears** (G09). Each ratio is wheel revolutions per crank revolution, what `physics.Drive.gearRatio` is for a single-speed bike (the BMX's is 2.78), lowest gear first and strictly rising; `start` is the gear a new bike is in (default: the middle one). Validated at registration like `physics`: a list of the wrong length, ratios out of order, a ratio of 0 or over 20, a `start` outside the box, or any other key is reported and the vehicle is **not registered**. A bike without `gears` is single-speed and runs on `Drive.gearRatio`. See "Gears" below. |
| `scoreMult` | A number above 0 and at most 10 that multiplies every trick the vehicle scores (the road bike's is 1.5). Applied once, in `ENT:AwardTricks`, so the score, the callout, `BMX_TrickLanded` and the combo's chain all see the same number. |
| `barStyle` | `"flat"` (the default), `"drop"` or `"swept"`: the shape of the procedurally drawn bars. |
| `look` | `"bmx"`: draw the built-in detailed BMX model (`cl_bikegeo.lua`, scaled to the bike's wheelbase and wheel radius) instead of the simple bike. The stock BMX, cruiser and mini set it; leave it out for a bike that is not BMX-shaped. |
| `basket` | `{ mins = Vector, maxs = Vector, maxMass = kg, hold = u/s^2 }` (G12): a box in chassis space that small props ride in. `mins` and `maxs` are required (`maxs` above and beyond `mins` on every axis); `maxMass` (default 12) is the heaviest prop it takes, `hold` (default 1500) the acceleration the load stays in through. Checked at registration like the rest. See "The basket" below. |

### Gears

`BMX.RegisterBike("road", { gears = { ratios = { 1.2, 1.5, 1.8, 2.15, 2.5, 2.85, 3.15, 3.5 }, start = 4 }, input = "road", ... })`
is the whole of it. The drive asks `BMX.GearRatio(ent, cfg)` for the ratio it runs
on, which is the current gear's on a bike with `gears` and `Drive.gearRatio` on any
other; the crank turns, the cadence on the HUD and the rider's legs all follow.
The gear is a networked integer on the entity (`ent:GetGear()`, 1-based; 0 reads as
`start`).

The rider shifts with `]` and the mouse wheel up, `[` and the wheel down (the
`shiftUp` and `shiftDown` actions of the `road` input map, below; `bmx_shift_wheel 0`
gives the wheel back to the weapon switch). The client sends one small message and
the server decides: the sender must be the rider, and a bike takes at most one
shift per `BMX.Gears.SHIFT_COOLDOWN`. Server code can shift directly with
`BMX.Shift(bike, +1 | -1)` (cooldown applies) or `BMX.SetGear(bike, n)`.

The model (`lua/bmx/sh_gears.lua`) is what keeps the cadence sane. The legs' torque
falls to nothing at `Drive.maxCadence` (120 rpm), so a bike tops out a little under
that in whatever gear it is in; the box's job is that **some gear puts the legs
between `BMX.Gears.CAD_LOW` and `CAD_HIGH` (60 and 110 rpm) at every speed**, so
neighbouring gears' bands must overlap. `BMX.Gears.Covers(def, cfg, lowSpeed)`
checks that for a box, `BMX.Gears.InBand`, `Best` and `CadenceRpm` are the pieces,
and the road bike's own box is tested against it.

### The basket

`basket = { mins = Vector(23, -10, 21), maxs = Vector(43, 10, 37) }` on a vehicle (the
city bike's) is a box in its own space, which is what "welded to the frame" means: a
volume, not an entity, so there is nothing to constrain, break or duplicate. The
client draws it from the same corners (`cl_init.lua`). `lua/bmx/sv_basket.lua` does
the rest, from the Think hook:

- **Catching:** a loose `prop_physics` of at most `maxMass` kg that comes to rest
  inside the box (not thrown in at more than 140 u/s relative to the bike, not held by a
  physgun or a gravity gun) is captured. It is placed where it sits in the box every tick,
  moving with the bike and with no gravity of its own, and does not collide with the bike
  it is in.
- **Keeping:** the bike's acceleration is measured over a 50 ms window of its velocity
  (not tick to tick, which reads every contact as a spike). Pedalling, braking and turning
  are an order of magnitude under `hold`.
- **Losing:** past `hold` (a bunny hop, a hard landing, running into something), a crash
  (`BMX_Crashed`), the bike falling over or being removed, the whole load is released at
  once, each prop leaving with the bike's velocity and a flick up and to one side, so
  it flies. A released prop is not caught again for 1.5 s. A prop that somebody picks up
  is let go.
- `BMX.Basket.Of(bike)`, `Held(bike)`, `Contains(bike, basket, point)`, `Capture` and
  `Release` are there for a gamemode (a delivery job can count what is in the box).

### Passengers

`seats = { pegs = {} }` is the whole of it for a bike that can carry someone on its
rear pegs (the BMX and the cruiser do), `seats = { child = {} }` for one with a child
seat (the city bike, G12). E on the rear half of a ridden bike (`BMX_CanMount` is asked
first) seats the next player in the child seat if it is switched on and free, else on
the pegs. The passenger gets a pod of their own, parented to the bike, invisible,
non-solid and `DoNotDuplicate` like the rider's, made the first time somebody takes
that seat. They cannot steer (input is read only from the rider) but can look round and
use the mouse, and get off with E.

- **Mass:** the bike runs on a config with the passenger's `massFactor x Chassis.mass`
  more mass (`ENT:Cfg`), its physics object is that heavy and its inertia is measured
  again, so wheelies and the balance get harder through the same numbers everything
  else reads. VPhysics has no way to move a mass centre at runtime, so the passenger's
  weight is applied where they sit, as a couple (weight down at the seat, the same up
  at the mass centre): the rear sags and the front lightens, with no net force.
- **Crash:** the passenger is thrown with the rider, each their own way, and goes the
  same ladder: `BMX_RiderCrashed(ply, vel, bike)` for each of them, then RagMod, then
  our ragdoll, then the shove. A rider who gets off, dies or leaves takes the passenger
  off too.
- **Score:** every trick is x2 with a passenger aboard (times the vehicle's own
  `scoreMult`).
- **Child seat:** a Child seat toggle on the bike's context menu (hold C and right-click)
  switches it on and off; it cannot be switched off with somebody in it. A child is drawn
  at 0.6 scale. Only the bike's owner or an admin can switch it.
- `bmx_passengers 0` (server; Options > BMX > Server > Vehicles) stops boarding and puts
  everyone aboard off.

### Physics overrides

`physics` is grouped exactly as `BMX.Config` is (`sh_config.lua`): `Chassis`,
`Wheel`, `Drive`, `Balance`, `Stand`, `Pitch`, `Air`, `Hop`, `Crash`, `Tricks`,
`Grind`, `Combo`. Anything you leave out comes from the base config; a bike
with no `physics` shares the base table by reference.

The table is **validated at registration**: a key that does not exist is an
error printed to the console naming it, not a value that silently goes
nowhere. Two things follow from the bike being its own config:

- Overriding a field that has a convar opts *this bike* out of live tuning for
  that one field, because an explicit override is meant to win.
- Anything that depends on size (hull, inertia, the procedural frame) follows
  from `wheelbase` and `radius`. The one thing that does **not** scale on its
  own is `Chassis.seatOffset`, which is where the rider is put: scale it by the
  same ratio, or the rider hovers above or sinks into the saddle. The shipped
  cruiser and mini show how.

Read a bike's numbers with `ent:Cfg()`, never `BMX.Config`, so your code means
the same thing on a bike with other geometry.

### Vehicles that are not bikes: `BMX.RegisterVehicle`

`BMX.RegisterBike(id, def)` is the bike-shaped way in. Underneath it is
`BMX.RegisterVehicle{ ... }`, the one registration door (G22), which is what a
skateboard, a scooter or a motor vehicle uses. `RegisterBike` just fills in the
bike's `family`, `wheels`, `balance`, `drive`, `input`, `pose`, `tricks` and
`grindPoints` and calls it, so everything above (the id and class, the spawn
menu, the duplicator, `bmx_spawn`, `BMX.Bikes`) is the same for both.
`BMX.Bikes` is the same table as `BMX.Vehicles`.

```lua
BMX.RegisterVehicle{
    id = "cart", printName = "Cart", family = "board",
    wheels = {                                    -- any number, any layout
        { pos = Vector( 16,  11, 0), steer = function(w, ent, st, inp, cfg, dt, speed)
                                          return inp.lean * 0.2 end },
        { pos = Vector( 16, -11, 0), steer = function(w, ent, st, inp, cfg, dt, speed)
                                          return inp.lean * 0.2 end },
        { pos = Vector(-16,  11, 0), drive = true },
        { pos = Vector(-16, -11, 0), drive = true },
    },
    balance = "none",
    drive   = { kind = "throttle", torque = 110000, maxSpeed = 320 },
    input   = "drive",
    pose    = "seated",
    tricks  = {},
    grindPoints = false,
}
```

A vehicle that says nothing gets: `balance = "none"`, `drive = { kind = "none" }`,
`input = "drive"`, `pose = "seated"`, `tricks = {}`, `grindPoints = false`.
`id`, `family` and `wheels` are required.

| Field | Meaning |
|---|---|
| `id` | Lower-case letters, digits and `_`. Becomes the class `bmx_<id>`. |
| `family` | `"bike"`, `"board"`, `"skates"`, `"scooter"` or `"moto"`. Decides the spawn menu heading (Bikes, Boards, Scooters, Motor; skates are under Boards) and which `bmx_allow_*` setting can switch it off. |
| `wheels` | A list of wheels, or a function of the config returning one. At least one, at most eight. See below. |
| `balance` | `"singletrack"` (lean-derived steering: exactly one front and one rear wheel), `"unicycle"` (G13: exactly one wheel, balanced on two axes by pedalling and leaning, with `bmx_unicycle_assist`), `"pennyfarthing"` (G13: the single-track mode with the header on its pitch; one front and one rear wheel), `"board"` (the skateboard's, `sv_board.lua`: the chassis is held flat to the ground and the rider's lean is a state of its own that the steering reads; needs no particular wheel layout), `"skates"` (the one WORN mode, below: the player is the chassis) or `"none"` (nothing holds the vehicle up; it stands on its wheels). |
| `drive` | `{ kind = "pedal" }` (the bike's legs and stamina, from the config's `Drive`), `{ kind = "coaster" }` (the same, a coaster brake: freewheeling, S is the brake and, with the `bike_rearonly` map, that is all there is), `{ kind = "fixed" }` (a fixed gear, below; `reverse = true` makes S pedal backwards at any speed instead of skidding, which is a unicycle's only brake), `{ kind = "front-direct" }` (G13: the pedal drive on whichever wheel is the drive wheel, the front's, for a penny-farthing), `{ kind = "throttle", torque = N, maxSpeed = N }` (a motor whose torque falls to nothing at `maxSpeed`), `{ kind = "push", torque = N, maxSpeed = N, kickInterval = N }` (a skateboard rider's kick: `torque` is the speed one kick adds at a standstill, u/s, falling to nothing at `maxSpeed`, one kick every `kickInterval` seconds while the throttle is held; also the foot-drag brake and the kick-turn; add `footBrake = false` to drop both, for a vehicle that brakes with its wheel, as the scooter does), `{ kind = "stride", torque = N, maxSpeed = N, strideInterval = N }` (the skates' alternating strides: the same cycle as `push`, the legs taking turns) or `{ kind = "none" }`. `pedal`, `fixed`, `coaster`, `front-direct` and `throttle` need at least one wheel with `drive = true`. The motor kinds `assist` (an e-bike), `engine` (petrol) and `throttle` with `battery` / `regen` / `motorRatio` (the e-moto) are described under "Motor vehicles" below; `assist` and `engine` need a drive wheel. |
| `seats` | `{ rider = {...}, pegs = {...}, child = {...} }` (G11): the vehicle's seats, each `{ model, offset, angles, massFactor, pedals }` with every key optional (an empty table is all defaults). `rider` is always there; omitted, it is the config's `Chassis.seatOffset` and `seatAngles`. `pegs` seats a second player on the rear pegs, `child` in a child seat. `offset` may be a `Vector` or a function of the config (so a seat can follow a frame's size); `massFactor` is the passenger's mass as a fraction of the bike's own `Chassis.mass` (default 0.6 on the pegs, 0.25 in the child seat). The old list form, `{ { model, offset, angles } }`, is still the rider's seat. Checked at registration: an unknown seat or key, a bad type, a `massFactor` outside 0-2. `pedals = true` (G13) says the person in that seat pedals too, and their torque adds to the driver's (a tandem's stoker; see "The odd ones" below). See "Passengers" below. |
| `input` | An id in `BMX.InputMaps`: `"bike"`, `"drive"`, `"road"`, `"bike_rearonly"`, `"unicycle"`, `"penny"`, or one you register. |
| `drawer` | An id in `BMX.Drawers` (`cl_oddbikes.lua`, G13): the vehicle draws itself in code instead of the stock bike's shape, handed the entity's own drawing primitives (`BMX.Draw`: `tube`, `joint`, `solid`, `ring`, the wheel and the axle trace). Shipped: `"unicycle"`, `"pennyfarthing"`, `"tandem"`. A drawer records `ent.ikTargets` (`rFoot`, `lFoot`, `rHand`, `lHand`) for the rider's IK. |
| `pose` | An id in `BMX.PoseSets` (the rider's pose on the client): `"bike"`, `"seated"`, `"road"` (tucked over the drops), `"upright"` or `"unicycle"`. |
| `tricks` | `"all"` or a list of registered trick ids. Limits what is scored from motion: the flips and turns, the held wheelie and stoppie, and registered custom ticks. |
| `grindPoints` | `false` (cannot grind) or `{ crank = Vector or fn(cfg), pegs = { y, z, x = { ... } } or fn(cfg), moves = fn }`: where a pipe is looked for and ridden on, where the pegs are on an edge, and optionally `moves(ent, st, rail, dh, vel)`, called when a rail is found, which answers with the move (`{ id, name, mult, yaw, pitch, signed, reverse, crank = Vector, peg = fn(side) -> Vector }`: which point of the vehicle rides the rail, how it is turned and pitched, what it is called and the multiple of the grind rate it pays) or `nil` for no grind here. The skateboard's ten grinds and slides are one (`BMX.Board.GrindMoves`). |
| `physics`, `bones`, and every appearance field above | As for a bike. |
| `worn` | `true` for a **worn** vehicle (G25, below): no entity class, no seat, no spawn row of its own; the player is the chassis. It needs a worn `balance` (`"skates"`) and no `seats`. |
| `hidden` | Not in the spawn menu or `BMX.BikeIDs()`. |
| `debugOnly` | `bmx_spawn` and the spawn door refuse it unless the player has `bmx_debug 1`. |

**Wheels.** Each is `{ pos, radius, steer, drive, front, name }`:

- `pos` is the **axle**, in chassis space (x forward, y left, z up), measured
  from the design axle line. The suspension mount is `Wheel.restLength` above it.
- `radius` overrides the config's `Wheel.radius` for this wheel only.
- `steer` is `false`, `"fork"` (the single-track balance steers it from the lean)
  or a **function** `(wheel, ent, st, inp, cfg, dt, speed) -> radians`, called
  every grounded substep after the balance has run, so it may read `st.roll`.
  Positive turns right. A skateboard's truck lean is one.
- `drive = true` takes an equal share of the drive torque.
- `front` says which axle's brake the wheel takes (front brake on the front,
  rear brake on the rest). Omitted, it is `pos.x > 0`.

**Validation.** All of it is checked at registration, like `physics`. Every
unknown key at every level, a wheel with no `pos`, `singletrack` on anything but
a front and a rear wheel, `steer = "fork"` without `singletrack`, a throttle drive
with no drive wheel or no torque, an unknown input map, pose set or trick id, and
more than one seat are all reported to the console, naming the field, and the
vehicle is **not registered**. (An invalid `physics` or `bones` is reported but
the vehicle still registers, as it always has.) `RegisterVehicle` returns the
definition, or `false`.

**Input maps.** `BMX.RegisterInputMap{ id, actions = { name = { key = IN_..., ctx = { "ground", "air" }, label = "..." } } }`.
`key` is the usercmd bit, `ctx` is any of `ground`, `air`, `grind`, `manual`. An
action may instead (or as well) carry `buttons = { KEY_..., MOUSE_... }`: buttons the
**client** sees (the usercmd does not carry them), which is how the road bike's gear
shift is bound; a button-only action is never "down" to the usercmd decode and is
still listed for a keybind panel. The shipped maps: `bike`, `drive`, `road` (the
bike's, plus `shiftUp` and `shiftDown`) and `bike_rearonly` (the bike's with no ground
front brake: LMB is only a tailwhip, in the air).
`sv_input.lua` reads the key for each action from the vehicle's map; an action the
map lacks is never down. `BMX.InputActions(mapId, ctx)` lists a map's actions for a
keybind panel. The `bike` map is the controls in the game's help; `drive` is
forward, back, left, right, jump.

**A fixed gear** (`drive = { kind = "fixed" }`, G10; the shipped `fixie`). The cranks
are locked to the rear wheel through a stiff spring and damper (`sv_fixie.lua`): the
rider's push is the pedal drive's, but it goes onto the legs, a flywheel of their own
(three wheels' worth of inertia, a little drag), and the legs reach the wheel through
the spring. So there is no freewheel: coasting turns the legs and slows the bike a
little, S is a skid stop, and S at a standstill pedals backwards (a fakie, scored).
Set `physics = { Drive = { fixedGear = true } }` too: it is the config's switch for
"the wheel has no freewheel floor". Give it the `bike_rearonly` input map and LMB does
nothing on the ground, unless the server turns `bmx_fixie_frontbrake` on. Two tricks
only a fixie earns, `fakie` and `trackstand` (paid per second, `BMX.Fixie.Tick`).

**The odd ones** (G13: the unicycle, penny-farthing, tandem, downhill bike, rack and lock).
What each added to the platform, for anyone writing the next:

- *A one-wheeled vehicle* is `wheels = { { pos = Vector(0, 0, 0), drive = true } }` with
  `balance = "unicycle"` and `Wheel.wheelbase = 0` (the hull then has one wheel box, not two on
  top of each other). One wheel carries all the weight, so say `Wheel.loadShare = 1` (the
  fraction one wheel carries at rest, default 0.5: it sets the rest height) and a spring to match.
  The balance is an inverted pendulum on two axes: `alpha = -assist * topple + Kp (target - angle)
  - Kd (rate)` with the spring a *fraction* (`Unicycle.holdRoll`) of the toppling gradient
  `m g h / I`, so the break-even assist is `1 - hold` at any inertia the engine measures. The
  fore-and-aft balance is the real thing, the fixed drive's torque at the patch pitching the body;
  the mouse's yaw (`inp.mouseX`, from the usercmd) twists it round. `bmx_unicycle_assist` (0..1,
  default 0.6) is the share of gravity's toppling cancelled for the rider.
- *Two wheels of different sizes* is a per-wheel `radius` and `Wheel.rearRadius` for the hull
  (the rear axle sits `radius - rearRadius` lower on the chassis); a wheel's flywheel scales with
  its radius squared. **The sag must be under `Wheel.stepMax`** (default 5): a wheel's compression
  may rise at most that much in one substep, and a spawned wheel starts from none, so a bike that
  sags more than it sits on its hull. Long-travel bikes raise `stepMax` (half the radius is the
  tallest step a wheel rolls onto).
- *A drive on the front wheel* is `drive = { kind = "front-direct" }` with `drive = true` on the
  front wheel: the pedal drive acts on "the first drive wheel", not "the rear".
- *A header* is physics: a mass centre 62 units up and 18 behind the front patch goes over under
  a front brake harder than ~0.3 g. The `pennyfarthing` balance only decides it is a crash
  (`Penny.headerBrake`, `headerSpeed`, `headerPitch`), as reason `"header"` with a forward throw
  (`ent.crashBoost`, added once to the crash's throw).
- *A second pair of legs* is a seat with `pedals = true`: `BMX.Tandem.Push(ent, inp)` adds the
  stoker's throttle (`inp.paxThrottle`, 0..1, from their usercmd) to the driver's inside the pedal
  drive, so the torques sum through the one falling curve. A passenger's keys are read for nothing
  else: the front rider steers.
- *A racked or locked bike* does not simulate: `ent.BMXRack` stops `BMX.PhysicsStep` at its top.
  `BMX.Rack` (`sv_rack.lua`) and `BMX.Lock` (`sv_lock.lua`) are the rules; the entity
  `bmx_bike_rack` and the weapon `weapon_bmx_lock` are shells over them. `BMX.Lock.CanUnlock(bike,
  ply)` is the one permission question: the owner, a player with the CAMI privilege "BMX - Unlock
  Any Lock", or the console. The offline shim records constraints (`constraint.Weld`,
  `NoCollide`, `game.GetWorld`) rather than simulating them.

**An input map may have a decoder.** `BMX.InputMaps.<id>.decode = function(ply, bike, cmd, down, fwd, side)`: `sv_input.lua` hands the usercmd over instead of decoding it as a bike's, so a vehicle whose keys mean other things reads them itself (the skateboard's, `sv_board.lua`). It must write `bike.input` (the standard fields, and anything of its own) and suppress the engine's use of the keys.

**A balance mode may have more than `Ground` and `Pitch`.** `Tick(ent, phys, cfg, dt, inp, st, vdef)` runs once a substep with a rider aboard, on the ground and in the air (a skateboard's ollie, lean and tricks), and `Idle(ent, st)` once a substep with nobody aboard.

**A pose set may bring its own base pose and solver** (`cl_board.lua`): `rider(s)` the bone offsets (it also gets `s.bike` and `s.ply`), `poses` the style-pose rows, `activity(ply, bike)` the base sequence in place of the seated drive pose, `solveIK(ply, bike)` the limb solver. A family can draw itself: `BMX.DrawVehicle[family] = function(ent, kit)`, handed `BMX.DrawKit` (the primitives the bike is drawn from).

**Server settings.** `bmx_allow_bikes`, `bmx_allow_boards`, `bmx_allow_scooters`
and `bmx_allow_motor` (default 1; Options > BMX > Server > Vehicles) switch a
whole heading off for the spawn menu and `bmx_spawn`. Off stops new ones being
spawned; ones already out stay. `BMX_CanSpawn` is still the gamemode's own veto
on top.

### The skateboard (G23)

`skateboard` is registered in `sh_boards.lua` against the vocabulary in `sh_board.lua`
(`BMX.Board`): four wheels whose steer functions are `atan(sin(lean) * k)`, the
`board` balance, the `push` drive, the `board` input map and pose set. Everything
numeric is `BMX.Board.Tune`. Spawn it from the Boards tab, `bmx_spawn skateboard`,
or carry it (`weapon_bmx_board`, in the Weapons tab or `bmx_give_board`: left mouse
drops it, `bmx_pickup_board` takes it back; a carried board counts toward
`bmx_max_per_player`).

Controls: W pushes, S drags a foot (a kick-turn at a standstill), A / D lean (CTRL
with them at speed is a powerslide), hold SPACE to crouch and release to ollie (ALT
with it: a nollie), after the pop W / A / S / D and their pairs pick a flip (see
`BMX.Board.Flips`; with `bmx_board_flick 1` flick the mouse), RMB and a direction in
the air is a grab, RMB on the ground a manual (ALT: nose manual, W / S balance it),
SPACE held in the air near a rail or ledge grinds (release to pop out;
`bmx_board_autogrind 1` grinds on contact), CTRL + A / D in the air spins, A / D on
touching down on a transition is a revert, LMB swaps feet (switch). Player settings:
`bmx_stance` (regular or goofy), `bmx_board_flick`, `bmx_board_autogrind`.

Adding a board is a `BMX.RegisterVehicle` with `balance = "board"`, `drive = { kind =
"push" }`, `input = "board"`, `pose = "board"` and its own `wheels`; add flips with
`BMX.Board.Flips` before the first board is spawned.

### Motor vehicles (G14, G15)

The shipped `ebike`, `emoto`, `dirtbike` and `moped` are registry entries of family
`moto` (the Motor heading, `bmx_allow_motor`, and the CAMI privilege "BMX - Spawn Motor
Vehicles", an admin by default). They are single-track vehicles; what makes them motors is
the drive. The model is `lua/bmx/sh_motor.lua` (pure functions: the assist's cut-off, the
battery's arithmetic, the torque curve, the clutch), the drives and the battery are
`sv_motor.lua`, the HUD and the sounds `cl_motor.lua`.

**`assist`** (`drive = { kind = "assist", assist = 1, motorRatio = 12 }`): the pedal drive's
torque plus LEVEL times what the rider asks of the pedals (`crankTorque * throttle / gear
ratio`), faded out over the last 2 km/h under `bmx_ebike_limit` (25 by default), so the
legs take over above it. Level 0-3, on the mouse wheel and `[` `]` (the `ebike` input map:
the road bike's shift actions mean the level), spawning at `assist`. The motor's torque is
cut as the front wheel rises (`M.WheelieCut`): level 3 is four times a rider's push through
one tyre and loops a bike over otherwise.

**`throttle` with `battery` / `regen`**: a no-legs motor, `torque` falling to nothing at
`maxSpeed`; S adds `regen` of braking torque and puts the energy back in the pack.

**The battery** is Wh on the vehicle's state (`st.battery`, networked as `Battery`, 0-1, or
-1 for infinite). Capacity is `bmx_ebike_battery` times the drive's `battery` (default 1);
0 is infinite. It drains with the motor's work at the wheel, `torque * omega` in newton-metres
(a torque unit is `1 / 39.37^2` N m) divided by 0.85, and regen returns 60% of what braking
takes. A parked, unridden vehicle recharges in two minutes. An empty pack means no motor.

**`engine`** (`drive = { kind = "engine", torque, curve = { {rpm, fraction}, ... }, idle,
redline, inertia, friction, clutch, engageRpm, ratio, popGain, popTime, pedalStart }`; all but
the last four are required, and `ratio` only without `gears`): an engine with a torque curve
over rpm, an inertia, engine braking and a rev limiter, behind a clutch and the road bike's
gear model. `gears = { ratios = {...} }` is as for the road bike, but a ratio here is wheel
revolutions per ENGINE revolution, so the lowest gear is the smallest number. The clutch lever
is SHIFT (the `moto` input map, `inp.clutch`); a centrifugal bite (`engageRpm`) means a
stopped bike in gear neither stalls nor creeps. Let the lever go with the throttle open and
the engine well above the wheel's speed (a clutch pop) and the stored revs dump into the wheel
and the nose is kicked up for `popTime` seconds: a wheelie, which RMB holds. `pedalStart`
(the moped) is metres of pedalling before the engine catches. The clutch is three states
(open, locked, slipping: `M.EngineStep`) and, locked, the wheel carries the engine's inertia
(`wheel.extraInertia`, sv_wheel.lua).

**FMX tricks** are ordinary pose tricks: `heel_clicker` and `cliffhanger` are registered in
`sh_motor.lua` with `BMX.RegisterTrick`, decoded for a vehicle whose family is `moto`
(`DecodePose`'s `moto` flag: Alt + A / D, Alt + S; Alt + W + S is the registry's superman).

### The kick scooter (G24)

`scooter` is registered in `sh_scooter.lua` (`BMX.Scooter`): a bike's single-track
balance and input decoder, the board's `push` drive with `footBrake = false`, and a
`physics` table for a small, light, twitchy machine (5-unit wheels on a 28-unit
wheelbase, a high `Balance.steerRate` standing in for a small trail, a firm fender brake
on the rear wheel and no front brake). Everything numeric is `BMX.Scooter.Tune` and the
registration's `physics`. Spawn it from the Scooters tab or `bmx_spawn scooter`.

Controls: W kicks (S is the rear fender brake), A / D lean, SPACE bunny hops, in the
air LMB + A / D is a tailwhip (the **deck** turns round the steer tube, which is the part
G03's tailwhip turns: let go past 270 degrees and it finishes by itself), R a barspin
(LMB + R both), W / S flip, RMB + A / D a 360, ALT the style poses; a tailwhip and a
flip in one air is a **bri flip**; RMB on the ground a manual. Grinds are automatic on
contact, as the bike's: a **50-50** (the deck on a pipe or ledge), and on a ledge's
edge with W held as it locks on a **smith** (the front peg) or with S a **feeble** (the
back peg). Its input map is `scooter` (the bike's without a sprint or a ground front
brake), its pose set `scooter` (both feet on the deck, hands on the grips).

Adding a scooter is a `BMX.RegisterBike` with `family = "scooter"`, `input = "scooter"`,
`pose = "scooter"`, `drive = { kind = "push", ..., footBrake = false }` and a small
`physics` table, and `grindPoints = BMX.Scooter.GrindPoints` for the moves.

### Worn vehicles, and the skates (G25)

Every vehicle above is an entity with a seat. A **worn** vehicle is not: the player is
the chassis, nothing is spawned, and it is equipped and holstered. `worn = true` in the
registration is the whole of the flag; the platform (`sv_worn.lua`) does the rest.

```lua
BMX.Worn.Equip(ply, "skates")      -- put a player into a worn vehicle (returns the wearer's state)
BMX.Worn.Unequip(ply)
BMX.Worn.Of(ply)                   -- the wearer's state, or nil: { id, def, st, input, proxy, ... }
BMX.WornIDs()                      -- the worn vehicles, as BMX.VehicleIDs() is the entity ones
BMX.WornModes.<balance> = { Decode, Setup, Move, Equip, Unequip, Weapon }
```

A **mode** is what a `balance` name means for a worn vehicle: `Decode(ply, w, cmd)` reads
the player's usercmd into `w.input`; `Setup(ply, w, mv, dt)` runs once a movement tick
before the engine moves the player and may rewrite their velocity; `Move(ply, w, mv,
dt)` returns `true` to take the movement over; `Weapon` is the SWEP class that carries
the vehicle (`bmx_spawn <id>` and the /bike window give it). `w.proxy` is a plain table
that stands in for the entity for the scoring and the combos (`Bike`, `Cfg`, `GetDriver`,
`GetScore`, `AwardTricks`), so a trick on skates pays, builds a combo, fires
`BMX_TrickLanded` and shows a callout exactly as a bike's does; the score is the
networked int `BMXWornScore` on the player. A worn vehicle is **not** in
`BMX.VehicleIDs()` or `BMX.ClassFor()` (there is no class), and **is** in
`BMX.BikeIDs()` either (that is the entities), but **is** in `BMX.GettableIDs()` (the
entities and the worn ones), which is what `bmx_spawn` accepts and the /bike window lists:
`bmx_spawn skates` gives the weapon.

`skates` is registered in `sh_skates.lua` (`BMX.Skates`): eight wheels, four in a line
under each boot, cast down from the feet each tick for the slope under the skater. The
step is a pure function (`BMX.Skates.Step`) and everything numeric is
`BMX.Skates.Tune`. Equip them from the weapon list (`weapon_bmx_skates`), `bmx_give_skates`
or `bmx_spawn skates`; holster to walk. A held pair counts toward `bmx_max_per_player`
and `bmx_allow_boards` switches them off with the boards.

Controls: W strides (the legs alternate; each stroke adds speed, less as the skater
speeds up), A / D are crossovers (the view turns, and the skater goes round with it), the
heading follows where you look at a rate that falls with speed, S is a T-stop (or a
heel brake: `bmx_skates_brake heel`), SPACE jumps. Hold SPACE in the air near a rail or
ledge (or turn on `bmx_board_autogrind`) to grind: along it with no key a **soul**, with
W a **mizou**, turned across it a **backslide**; A / D hold the balance meter, release SPACE
to pop off. Spins in the air pay on the landing (a 180, a 360), and a landing across your
travel, or from too high, is a bail. Not done yet: makio, topside, royale, unity and
frontside grinds, flips and grabs, and the wall ride.

## 2. Tricks

Tricks are scored by name and points: a trick is `{ name = "Backflip", count = 1,
points = 500 }`, possibly with extra fields (see `BMX_TrickLanded`).

**`BMX.RegisterTrick` will be the trick API.** It is being built (in
`sh_tricks.lua`) and is not in this release; until it is, a trick cannot be
added from outside. Once it exists, registered tricks reach
`BMX_TrickLanded` exactly as the built-in ones do, with a stable `trick.id`,
which is also what SKATE matches on. This file will gain its section when it
lands.

## 3. Hooks

Hooks are ordinary `hook.Add` / `hook.Run` hooks. Arguments always lead with
the **player**, then the bike. A hook documented as **vetoable** is a question:
return `false` to say no, anything else (including nothing) to leave it alone.

Realm is where the hook is **fired**: listen to it there.

Each hook has its own heading below; `tests/test_hooks_doc.lua` reads these
headings and fails if a documented hook is never fired by the addon, or if the
addon fires a `BMX_` hook that is not documented here.

### Riding

### `BMX_Mounted` (ply, bike)

*Server.* A rider got on a bike. Replaces `BMX_RiderMounted(bike, ply)`.

### `BMX_Dismounted` (ply, bike)

*Server.* A rider got off, or was thrown. Replaces
`BMX_RiderDismounted(bike, ply)`.

### `BMX_CanMount` (ply, bike)

*Server, vetoable.* Asked when a player presses E on a bike. Return `false` to
refuse. **Breaking change from 1.1.0**: the arguments were `(bike, ply)`. The
name is the same, so it cannot be kept as an alias.

### `BMX_CanSpawn` (ply, bikeId)

*Server, vetoable.* Asked by `bmx_spawn` before the stock `PlayerSpawnSENT`
door, with the registry id (`"stock"`, `"cruiser"`, ...). Return `false` for no
bikes this round. The spawn menu goes through `PlayerSpawnSENT`, which this
addon's own limit (`bmx_max_per_player`) also uses.

### `BMX_RiderCrashed` (ply, vel, bike)

*Server, vetoable.* A rider has just come off and is about to be put in a
ragdoll. `vel` is the throw velocity (a vector) and `bike` the bike they came
off (on a **worn** vehicle, the skates, it is the player again: there is no entity). Return `true` to take the rider yourself (spawn your own ragdoll, or none):
the built-in ragdoll is then skipped. RagMod is handled this way by
`bmx_ragmod`. It fires once for every person thrown: the rider, then each passenger
(G11, with the bike's momentum and a little of their own). `BMX_Crash` is the earlier
veto, before the throw is decided.

### `BMX_Crash` (bike, ply, reason, severity)

*Server, vetoable.* The rider is about to be thrown. Return `false` to replace
the crash with your own (a deathrun server's opinion of what a crash is).
`severity` is 0..1.

### `BMX_Crashed` (bike, ply, reason, severity)

*Server, notification.* The crash is going ahead (no `BMX_Crash` hook vetoed
it): fired before the rider is thrown, while they are still aboard, so a log
or a server's stats can record why they came off (`reason` is `"angle"`, `"sideways"`,
`"impact"`, `"tipped"`, or `"header"`: a penny-farthing's rider over the bars). The
return value is ignored.
The trick bot uses it to log its own crashes.

### `BMX_BikeRacked` (bike, rack, slot)

*Server, notification* (G13). A bike was put in a bike rack's slot (1 or 2) and welded to
it. The return value is ignored.

### `BMX_BikeUnracked` (bike, rack, ply)

*Server, notification* (G13). A bike was let down off a rack. `ply` is who did it by using
it, or nil (the rack was removed, or a script released it).

### `BMX_BikeLocked` (bike, ply)

*Server, notification* (G13). A parked bike was locked to the world by the bike lock.

### `BMX_BikeUnlocked` (bike, ply)

*Server, notification* (G13). A lock was let go: by the owner getting on or physgunning
it, a player with "BMX - Unlock Any Lock", the weapon's right click or a script (`ply` may
be nil for a script).

### Scoring

### `BMX_TrickLanded` (ply, trick, points, bike)

*Server.* **One call per trick** of a clean landing (or a held manual or a
finished grind). `trick` is `{ name, count, points, ... }`. Extra fields say
what kind it was, absent otherwise: `air` (seconds the bike was up, on air
tricks), `held` (seconds, on a wheelie or stoppie), `grind` (seconds on the
rail). A trick that ends in a crash does not fire this (`BMX_TricksBailed`).
Does not fire with `bmx_scoring 0`. Replaces the per-landing
`BMX_TricksLanded`. On a worn vehicle (the skates) `bike` is the wearer, the player.

### `BMX_ComboBanked` (ply, chain, total)

*Server.* A combo of two or more tricks landed and paid its bonus. `chain` is
`{ n, base, bonus, total, names }`; `total` is `base + bonus`, the whole
combo's value. The tricks' own points (`base`) were already paid when they
landed, so a game that adds to a score adds `chain.bonus`.

### `BMX_ComboBailed` (ply, chain)

*Server.* A combo of two or more tricks was lost to a crash. The tricks' own
points stay; the bonus is gone.

### `BMX_TricksBailed` (bike, ply, tricks)

*Server.* A trick list ended in a crash and paid nothing.

### `BMX_GrindStarted` (bike, kind)

*Server.* A bike latched onto a rail. `kind` is `"crank"` or `"peg"`.

### `BMX_GrindEnded` (bike, kind, why, seconds)

*Server.* Off the rail. `why` is `"hop"`, `"end"`, `"slow"` or `"rider"`.

### `BMX_BoardPopped` (bike, ply, height, nollie)

*Server.* A skateboard rider released SPACE and popped an ollie. `height` is the
peak the pop is aimed at, in units (7 for a tap, 26 for a full crouch); `nollie`
is true if it was popped off the nose.

### `BMX_BoardFlipStarted` (bike, ply, flipId)

*Server.* The deck began a flip. `flipId` is `kickflip`, `heelflip`, `popshove`,
`frontshove`, `flip360`, `varialheel`, `varialkick`, `hardflip` or `impossible`
(`BMX.Board.Flips`). Whether it was caught is `BMX_TrickLanded` (paid) or
`BMX_Crashed` with the reason `"flip"` (not).

### `BMX_BoardGrind` (bike, ply, moveId)

*Server.* A skateboard locked onto a rail or ledge. `moveId` is `grind5050`,
`grind50`, `nosegrind`, `crooked`, `smith`, `feeble`, `boardslide`, `lipslide`,
`noseslide` or `tailslide` (`BMX.Board.Grinds`). `BMX_GrindStarted` fires too.

### Worn vehicles (skates)

### `BMX_WornEquipped` (ply, id)

*Server.* A player put on a worn vehicle (`id` is `"skates"`): the SWEP was deployed or
`BMX.Worn.Equip` was called.

### `BMX_WornHolstered` (ply, id)

*Server.* A player took a worn vehicle off: holstered it, died, left, or got into a
vehicle.

### `BMX_WornGrind` (ply, id, moveId)

*Server.* A skater locked onto a rail or ledge. `moveId` is `skate_soul`,
`skate_mizou` or `skate_backslide` (`BMX.Skates.Grinds`).

### `BMX_WornGrindEnded` (ply, id, moveId, why, seconds)

*Server.* Off the rail. `why` is `"hop"`, `"end"`, `"slow"` or `"balance"` (the meter was
lost, which is also a bail).

### `BMX_WornBailed` (ply, id, reason, severity)

*Server.* A skater came off: `reason` is `"fall"`, `"sideways"` or `"balance"`, `severity`
is 0 to 1. They are then thrown the way a bike's rider is (`BMX_RiderCrashed`, RagMod, a
ragdoll tumble, or a shove), and the combo is lost.

### `BMX_WornTricksBailed` (ply, id, tricks)

*Server.* The air ended in a bail and paid nothing: the worn counterpart of
`BMX_TricksBailed`.

### `BMX_CanRecolor` (bike, paletteIndex)

*Server, vetoable.* Asked before a bike is painted.

### Deprecated aliases

Kept for one version, fired right after their replacement. Move to the public
name; these go in the next release.

### `BMX_RiderMounted` (bike, ply)

*Server.* Deprecated alias of `BMX_Mounted`.

### `BMX_RiderDismounted` (bike, ply)

*Server.* Deprecated alias of `BMX_Dismounted`.

### `BMX_TricksLanded` (bike, ply, tricks, total)

*Server.* Deprecated alias: one call per landing with the whole list. Use
`BMX_TrickLanded`.

### `BMX_ComboEnded` (bike, ply, chain, landed, bonus)

*Server.* Deprecated alias: a combo of any length ended, banked (`landed`) or
bailed. Use `BMX_ComboBanked` / `BMX_ComboBailed`.

### Auto ride

`O` (or `bmx_autoride`) lets the bike ride itself. This addon has the button and
the hand-over, not the riding: whoever drives listens to these. BMX (Mode)'s
trick bot does (`sv_autoride.lua` there).

### `BMX_AutoRideStart` (ply, bike)

*Server.* `ply`, riding `bike`, asked for auto ride. Return `true` to take the
bike: from then on, set `ply.BMXScripted` and write `bike.input` every tick, as
the headless harness does. Return `false, "why"` to refuse with a reason the
rider is shown. Nobody returning `true` is "this server has no auto rider".

### `BMX_AutoRideStop` (ply, bike, why)

*Server.* Let go: the rider pressed a ride key (`"took the bars"`), pressed
`O` again (`"toggled off"`), died, left, or the bike is gone. Clear
`ply.BMXScripted` before returning, and the key that ended it is read on the
same tick. A driver that gives up by itself calls `BMX.AutoRide.Stop(ply, why)`.

### Scores, games and the bot

Personal bests, the leaderboard, SKATE / Trick Attack / Combo Mambo and the
trick bot are not part of this addon: they are the **BMX (Mode)** gamemode
(gmod/gmod-bmx-mode, `gamemodes/bmx`), built on the hooks above. Its own
`docs/MODDING.md` documents `BMX_NewBest`, `BMX_GameStarted`, `BMX_GameEnded`,
`BMX_GameLetter` and `BMX_ScoresUpdated`.

### Client

### `BMX_TricksLandedClient` (tricks, total)

*Client.* The local rider just landed something; the callout is on its way up.

## 4. Commands for server owners

| Command | |
|---|---|
| `bmx_scoring 0\|1`, `bmx_combos 0\|1` | Turn scoring or combos off. |
| `bmx_max_per_player N` | Bikes per player. |
