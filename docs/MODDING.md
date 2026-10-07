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

### `BMX_RiderCrashed` (ply, vel)

*Server.* **Pending**: another change adds it; documented here so the name is
reserved. It is the observation ("this rider came off at this velocity").
Until it ships, `BMX_Crash` below is the nearest.

### `BMX_Crash` (bike, ply, reason, severity)

*Server, vetoable.* The rider is about to be thrown. Return `false` to replace
the crash with your own (a deathrun server's opinion of what a crash is).
`severity` is 0..1.

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

### Scores and games

### `BMX_NewBest` (ply, stat, value, bikeId)

*Server.* A player beat their own best. `stat` is `combo`, `trick`, `grind`,
`manual` or `air`; `value` is points or seconds. Bots, noclip and
physgun-carried bikes never fire it (`BMX.Scores.Counts`).

### `BMX_GameStarted` (game)

*Server.* A SKATE / Trick Attack / Combo Mambo lobby began. `game.id`,
`game.players`.

### `BMX_GameEnded` (game, result)

*Server.* A game finished. `result.winner` is the winning player (nil for a
draw) and `result.ranking` the standings. Pay out here.

### `BMX_GameLetter` (game, ply, word, out)

*Server.* A SKATE player got a letter. `word` is what they have spelled so far;
`out` is true when it completes the word.

### Client

### `BMX_TricksLandedClient` (tricks, total)

*Client.* The local rider just landed something; the callout is on its way up.

### `BMX_ScoresUpdated` (cache)

*Client.* The server answered a `bmx_scores` request.

## 4. Commands for server owners

| Command | |
|---|---|
| `bmx_scoring 0\|1`, `bmx_combos 0\|1` | Turn scoring or combos off. |
| `bmx_max_per_player N` | Bikes per player. |
| `bmx_scores` (client) | The panel: top ten of each stat for this map. |
| `bmx_scores_reset` (superadmin) | Wipe this map's scores. |
| `bmx_game_start skate\|attack\|mambo [bot]` | Open a lobby; the host runs it again to begin. |
| `bmx_game_join`, `bmx_game_leave`, `bmx_game_status` | |
| `bmx_games_admin_only 1` | Only admins may start a game. |
| `bmx_leaderboard_set <stat\|all> [bike]` | Admin: on the leaderboard sign you are looking at. |

Scores are saved to `data/bmx/scores/<map>.json`: the top ten of each stat, per
bike, written at most every 30 seconds and on shutdown.
