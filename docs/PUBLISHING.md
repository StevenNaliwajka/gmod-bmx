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
| the upload kit (zip) | `tools/package-workshop.sh` | no, built into `dist/` |
| title / description / type / tags | `addon.json` | yes |
| the Workshop item itself | `gmpublish`, by hand | n/a |

## Before the first publish

**The `.gma` writer has been verified against the real `gmad`** (2026-08-26): a
round trip extracted byte-identical, and `gmad create` on the same folder
produced a file 24 bytes different, all of it metadata whitespace. The note in
`tools/gmad.py` has the exact commands. Re-run it if you touch the header
layout, because a mount failure on a stranger's server is an expensive way to
find a byte-order mistake.

**Check the suite is green on a real server**, not just that it parses: the
pipeline's `headless` job runs `bmx-test` (24/24 as of 2026-09-27, v1.0.0).

**Verified for v1.0.0 (2026-09-27)** on the dev server with the real `gmad`:
`gmad extract` of the packed file gave all 25 files byte-identical to the repo,
and `gmad create` over the same files ignored 0 of them (the Workshop refuses an
addon with a file type off Garry's Mod's whitelist, and this is how to find out
before Steam does).

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

The Workshop item belongs to the Steam account **ConvexBurrito5**. Uploading
is done by `gmpublish`, which ships with Garry's Mod (`bin\gmpublish.exe` on
Windows) and uploads as whichever account the running Steam client is signed
into -- so it runs on the publisher's own PC, never on a server and never in CI.

Build the kit:

```
tools/package-workshop.sh        # -> dist/BMX-Workshop-<version>.zip
```

It holds `bmx.gma`, `icon.jpg`, `publish.bat` (first upload: `gmpublish create`),
`update.bat` (`gmpublish update -id`), `find-gmpublish.ps1` (finds Garry's Mod
through the registry and every Steam library folder, falling back to asking),
`publish.sh` for a Linux PC, and a README with the steps. By hand:

```
gmpublish.exe create -addon bmx.gma -icon icon.jpg
gmpublish.exe update -addon bmx.gma -id <workshop-id> -changes "what changed"
```

(An earlier version of this file said `gmpublish publish`; the command is
`create`.)

After the first upload, open the item in Steam (Garry's Mod > Workshop > Your
Files): accept the Workshop agreement if asked, and set the visibility.

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
