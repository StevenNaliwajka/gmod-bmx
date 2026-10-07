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
