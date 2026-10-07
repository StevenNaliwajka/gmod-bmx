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
| `balance` | `"singletrack"` (lean-derived steering: exactly one front and one rear wheel), `"board"` (reserved for the skateboard; runs as `none`, with a message, until its module exists), or `"none"` (nothing holds the vehicle up; it stands on its wheels). |
| `drive` | `{ kind = "pedal" }` (the bike's legs and stamina, from the config's `Drive`), `{ kind = "throttle", torque = N, maxSpeed = N }` (a motor whose torque falls to nothing at `maxSpeed`), `{ kind = "push", ... }` (reserved for the board) or `{ kind = "none" }`. `pedal` and `throttle` need at least one wheel with `drive = true`. |
| `seats` | `{ { model, offset, angles } }`. One seat for now (passengers are G11). Omitted: the config's `Chassis.seatOffset` and `seatAngles`. |
| `input` | An id in `BMX.InputMaps`: `"bike"` or `"drive"`, or one you register. |
| `pose` | An id in `BMX.PoseSets` (the rider's pose on the client): `"bike"` or `"seated"`. |
| `tricks` | `"all"` or a list of registered trick ids. Limits what is scored from motion: the flips and turns, the held wheelie and stoppie, and registered custom ticks. |
| `grindPoints` | `false` (cannot grind) or `{ crank = Vector or fn(cfg), pegs = { y, z, x = { ... } } or fn(cfg) }`: where a pipe is looked for and ridden on, and where the pegs are on an edge. |
| `physics`, `bones`, and every appearance field above | As for a bike. |
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
`key` is the usercmd bit, `ctx` is any of `ground`, `air`, `grind`, `manual`.
`sv_input.lua` reads the key for each action from the vehicle's map; an action the
map lacks is never down. `BMX.InputActions(mapId, ctx)` lists a map's actions for a
keybind panel. The `bike` map is the controls in the game's help; `drive` is
forward, back, left, right, jump.

**Server settings.** `bmx_allow_bikes`, `bmx_allow_boards`, `bmx_allow_scooters`
and `bmx_allow_motor` (default 1; Options > BMX > Server > Vehicles) switch a
whole heading off for the spawn menu and `bmx_spawn`. Off stops new ones being
spawned; ones already out stay. `BMX_CanSpawn` is still the gamemode's own veto
on top.

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
off. Return `true` to take the rider yourself (spawn your own ragdoll, or none):
the built-in ragdoll is then skipped. RagMod is handled this way by
`bmx_ragmod`. `BMX_Crash` is the earlier veto, before the throw is decided.

### `BMX_Crash` (bike, ply, reason, severity)

*Server, vetoable.* The rider is about to be thrown. Return `false` to replace
the crash with your own (a deathrun server's opinion of what a crash is).
`severity` is 0..1.

### `BMX_Crashed` (bike, ply, reason, severity)

*Server, notification.* The crash is going ahead (no `BMX_Crash` hook vetoed
it): fired before the rider is thrown, while they are still aboard, so a log
or a server's stats can record why they came off. The return value is ignored.
The trick bot uses it to log its own crashes.

### Scoring

### `BMX_TrickLanded` (ply, trick, points, bike)

*Server.* **One call per trick** of a clean landing (or a held manual or a
finished grind). `trick` is `{ name, count, points, ... }`. Extra fields say
what kind it was, absent otherwise: `air` (seconds the bike was up, on air
tricks), `held` (seconds, on a wheelie or stoppie), `grind` (seconds on the
rail). A trick that ends in a crash does not fire this (`BMX_TricksBailed`).
Does not fire with `bmx_scoring 0`. Replaces the per-landing
`BMX_TricksLanded`.

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

### Scores, games and the bot

Personal bests, the leaderboard, SKATE / Trick Attack / Combo Mambo and the
trick bot are not part of this addon: they are the **BMX (Mode)** gamemode
(root/gmod-bmx-mode, `gamemodes/bmx`), built on the hooks above. Its own
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
