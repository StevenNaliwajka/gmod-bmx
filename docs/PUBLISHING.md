# Publishing

Getting this onto the Steam Workshop, and what is deliberately not automated.

GitHub is the primary channel: server owners clone straight into
`garrysmod/addons` and never touch a `.gma`. The Workshop exists for players in
singleplayer and for servers that prefer a mounted addon.

---

## The pieces, and where each comes from

| Piece | Made by | In git |
|---|---|---|
| `bmx.gma` | `tools/gmad.py` (or CI, on a `v*` tag) | no, built |
| `workshop/icon.jpg` | `tools/make_icon.py` | yes |
| title / description / type / tags | `addon.json` | yes |
| the Workshop item itself | `gmpublish`, by hand | n/a |

## Before the first publish

**The `.gma` writer has been verified against the real `gmad`** (2026-08-26): a
round trip extracted byte-identical, and `gmad create` on the same folder
produced a file 24 bytes different, all of it metadata whitespace. The note in
`tools/gmad.py` has the exact commands. Re-run it if you touch the header
layout, because a mount failure on a stranger's server is an expensive way to
find a byte-order mistake.

**Check the suite is green on a real server**, not just that it parses:

```
bmx_selftest        # -> IMPULSE (expected)
bmx_test            # 10/12 as of 2026-08-26; see docs/TUNING.md for the two
```

## The icon

512x512, JPEG, under 1 MB. Steam rejects a PNG named `.jpg` and rejects
512x513, and says so unhelpfully.

```
python3 tools/make_icon.py
```

It is drawn from the numbers in `sh_config.lua` -- wheelbase, wheel radius,
centre of mass -- rather than from any source image, which is the cheapest way
to keep the no-ripped-assets rule (`docs/DESIGN.md` section 8) true of the
artwork as well as the addon. Change the wheelbase and the icon changes with it.

## Publishing

`gmpublish` ships in the same depot as `gmad`, next to it in
`bin/linux64/`. It needs a Steam account that owns Garry's Mod and has accepted
the Workshop legal agreement, which is why this step is **not in CI** and should
not be: a token that can publish to the Workshop has no business in a build
runner.

First publish, which creates the item and prints the ID you will need forever
after:

```
python3 tools/gmad.py -o /tmp/bmx.gma
gmpublish publish -addon /tmp/bmx.gma -icon workshop/icon.jpg
```

Every publish after that updates it in place:

```
gmpublish update -id <workshop-id> -addon /tmp/bmx.gma -changes "what changed"
```

**Record the workshop ID in this file when it exists.** It is not recoverable
from anything in the repo, and publishing without `-id` creates a second item
rather than updating the first.

Workshop ID: _not yet published_

## What CI does and does not do

`.github/workflows/build.yml` parses every Lua file on each push, packs a `.gma`
as an artifact so a branch can be tested on a server without merging, and
attaches one to a GitHub release on a `v*` tag. It never touches the Workshop.

## Tagging a release

```
git tag -a v0.2.0 -m "..." && git push origin v0.2.0
```

Keep `BMX.Version` in `lua/autorun/bmx_init.lua` in step: it is what the server
prints at load, and a version that disagrees with the tag makes a bug report
useless.
