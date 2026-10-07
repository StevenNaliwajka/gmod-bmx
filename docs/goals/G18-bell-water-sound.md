# G18 -- Bell, water and sound settings

**Competitor:** R rings a bell, and admins can mute it or give it a cooldown.
Water slows the bike, and riding in until half under throws you off (both
tunable, or off). There's a client volume for riding sounds and wind, and
admins can mute all bike sounds.

**Us today:** `sh_sound.lua` has base-game placeholders for rolling, skid,
freewheel and landing. We have no bell, no wind, no water handling at all
(a bike in water rides as on land), and no volume settings.

## Goal

The "it feels real" details, in one change.

## Done when

- **Bell / horn:** R (rebindable). A base-game placeholder sound, a
  per-vehicle sound (bike bell, skateboard: none, dirt bike: horn), and
  `bmx_bell_cooldown` (server, seconds) and `bmx_bell 0`.
- **Water:** wheel rays use `MASK_WATER` as well. Each submerged wheel adds
  drag ∝ depth × speed², and a splash effect + sound plays on entering water
  at speed. With the rider's chest under water, they're thrown off
  (`bmx_water_eject 1`). With `bmx_water 0` there's no effect.
- **Wind:** a whoosh that scales with speed². That's what sells speed on a
  downhill or a big air.
- **Volumes:** `bmx_vol_ride`, `bmx_vol_wind`, `bmx_vol_bell` (client, 0-1),
  and `bmx_sounds 0` (server).
- Exposed in G19's menu.

## Approach

Water: `util.PointContents` at each wheel's contact and at the rider's
chest bone, once per tick. That's cheap. The rest is `sh_sound.lua` entries and
client convars.

## Tests

- Offline: every new sound path exists (the suite already walks them).
- Headless `rides_into_water`: on a map with water (gm_construct pond), the
  speed drops and the rider is ejected when deep.

## Risks

None of note. The audio-licence rule stays: base-game sounds only until CC0
or CC-BY audio is sourced.

## Status (2026-10-07)

Implemented on the worktree branch; tested offline only. Nobody has heard the
new sounds or ridden into real water yet.

- **Bell:** R (IN_RELOAD) on the ground, out of a manual, fresh press only
  (`sv_input.lua`, one isolated block; in the air and in a manual R is left to
  the barspin). `lua/bmx/sv_bell.lua`: `bmx_bell` (1), `bmx_bell_cooldown`
  (0.6 s, per bike). The server decides, a `bmx_bell` net message makes every
  client play it at its own `bmx_vol_bell`. A bike picks its sound in the
  registry (`bell = "horn"` or `bell = false`); there is no skateboard or dirt
  bike yet to use it.
- **Water:** `lua/bmx/sv_water.lua`, `bmx_water` (1), `bmx_water_eject` (1).
  `util.PointContents` at three heights up each wheel and at the rider's chest,
  at 20 Hz in `ENT:Think`; the physics substep only applies the drag. Drag per
  wheel = depth * (3v + 0.0035 v^2). Chest under for 0.3 s ejects through
  `QueueCrash("water")`. Splash sound + `watersplash` effect once on entry at
  speed. Deviation from the doc: wheel rays still use `MASK_SOLID`; point
  queries were enough and cheaper than a second trace per wheel.
- **Sound settings:** `bmx_sounds` (server, replicated, 1; gates the four
  server one-shots, the bell, and the client loops incl. the grind scrape),
  client `bmx_vol_ride`, `bmx_vol_wind`, `bmx_vol_bell`. Wind loop is
  `BMX.WindVolume` = (speed / (1.3 * top))^2, only on a ridden bike.
- **Sound paths** (base game, unverified offline): `buttons/bell1.wav`,
  `ambient/water/water_splash1-3.wav`, `ambient/wind/wind_med1.wav`. The
  headless `sounds` case (file.Exists on a real server) is the check that they
  exist; run it before trusting them.
- **Tests:** `tests/test_ambient.lua`, `tests/test_wind.lua`. The headless
  `rides_into_water` case is NOT written: no test map has water.
- **Left:** the G19 menu entries for the new convars; real bell/wind audio.
