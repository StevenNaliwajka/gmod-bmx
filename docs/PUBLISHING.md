# Publishing

Getting this onto the Steam Workshop, and what is deliberately not automated.

The Workshop is how players get it. A server can mount the Workshop item or
run a checkout of this repository straight from `garrysmod/addons`, which needs
no `.gma` at all.

---

## The pieces, and where each comes from

| Piece | Made by | In git |
|---|---|---|
| `bmx.gma` | `tools/gmad.py` (or CI, on a `v*` tag) | no, built |
| `workshop/icon.jpg` | `tools/make_icon.py` | yes |
| the upload kit (zip) | `tools/package-workshop.sh` | no, built into `dist/` |
| title / type / tags | `addon.json` | yes |
| the page text | `workshop/description.bbcode` (copied into `addon.json`) | yes |
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

It holds `bmx.gma`, `icon.jpg`, `workshop-id.txt`, `update.bat` (`gmpublish update
-id`, the one to use), `publish.bat` (first upload only: `gmpublish create`), `find-gmpublish.ps1` (finds Garry's Mod
through the registry and every Steam library folder, falling back to asking),
`publish.sh` for a Linux PC, and a README with the steps. By hand:

```
gmpublish.exe update -addon bmx.gma -id 3814420080 -changes "what changed"
```

(An earlier version of this file said `gmpublish publish`; the command is
`create`.)

After the first upload, open the item in Steam (Garry's Mod > Workshop > Your
Files): accept the Workshop agreement if asked, and set the visibility.

**Record the workshop ID in this file when it exists.** It is not recoverable
from anything in the repo, and publishing without `-id` creates a second item
rather than updating the first.

Workshop ID: 3814420080
(<https://steamcommunity.com/sharedfiles/filedetails/?id=3814420080>, posted
2026-10-05; its page reports 467.997 KB, which matches no commit's .gma
exactly -- it lies between v1.0.0's and the combos commit's -- so which build
it is was not recorded. Record the commit next time, below.)

Updates, newest first (the commit the kit was built from; the `v` tag goes on
it once the upload is done):

| Version | Kit built | From commit | Uploaded |
|---|---|---|---|
| 1.2.0 | 2026-10-08 | a5e785b (tools/workshop_sync.py, from Linux; with BMX (Mode) 51d9a47 and Petopia BMX Fall 40ef174) | 2026-10-08, page text and gallery unchanged |
| 1.1.1 | 2026-10-07 | 932dc8c (tools/workshop_sync.py, from Linux) | 2026-10-07, with the gallery |
| 1.1.0 | 2026-10-07 | 817644e (tools/workshop_sync.py, from Linux) | 2026-10-07 16:25, with the gallery; icon now workshop/icon.gif |

The same number lives in `workshop/workshop-id.txt`, which the kit ships and
both `update.bat` and `publish.sh update` read, so an update needs nothing
typed. `publish.bat` and `publish.sh create` refuse while that file exists
(type NEW, or pass `--new`, to make a second item on purpose).
`tools/test-workshop.sh` checks all of this against a fake `gmpublish`.

**A Workshop update goes out only when the owner says so.** The addon is live
and people are subscribed: `main` and the test server move as fast as the work
does, Steam moves on a decision.

## Syncing from Linux: tools/workshop_sync.py

`tools/workshop_sync.py` publishes BMX, the petopia_bmx_fall map and the BMX
(Mode) gamemode from this Linux box, everything the page shows included: the
gmad-packed content, title, description, tags, icon (`workshop/icon.gif` when
there is one, else `icon.jpg`), the gallery (`workshop/gallery/`, in file-name
order -- gmpublish cannot set a gallery) and Required Items. It talks to the
Steam client through the Steamworks API, so Steam must be running here and
signed in as ConvexBurrito5, and **the account must not be in a game on
another PC**: starting the upload starts a Garry's Mod session, and Steam
signs this machine out ("Logged In Elsewhere") while a game runs elsewhere.

    tools/workshop_sync.py --dry-run        pack and check all three
    tools/workshop_sync.py                  sync all three
    tools/workshop_sync.py bmx --ref <sha>  one item, from a given commit

Items: BMX 3814420080, Petopia BMX Fall 3815469993, BMX (Mode) 3815470101
(each repo's `workshop/workshop-id.txt`). Tools in `~/sdk/gmod-tools` (gmad,
libsteam_api.so from a GMod dedicated server's bin/linux64).

## Releasing an update (when the owner says go)

1. `CHANGELOG.md`: the top entry is the version going out; change its
   "not yet on the Workshop" line to the date it went out.
2. `tools/package-workshop.sh`, then `update.bat` (or `./publish.sh update
   "what changed"`) on the publisher's PC, signed in as ConvexBurrito5.
3. Open the item page and check the title ("BMX") and the description.
   `gmpublish update` uploads the addon, not the page, so if the page still
   shows the old text, paste in `description.bbcode` from the kit (the page
   takes BBCode). It is `workshop/description.bbcode`, the page copy, and
   `addon.json`'s `description` carries it word for word
   (`tools/test-workshop.sh` fails if the two drift).
4. Tag it: `git tag -a v<version> -m "..." && git push origin v<version>`.
   The tag is the record of which commit subscribers have.

## What CI does and does not do

The GitLab pipeline (`.gitlab-ci.yml`) parses every Lua file, runs the offline
suite and `tools/test-workshop.sh` on every push, deploys `main` to the test
server and runs the headless suite there. It never touches the Workshop: the
`.gma` and the kit are built by `tools/package-workshop.sh` on the machine
that publishes. (There used to be a GitHub Actions workflow as well; the
repository has no GitHub remote, so it never ran, and it was removed.)

## Tagging a release

```
git tag -a v1.1.0 -m "..." && git push origin v1.1.0
```

Tag when the Workshop update goes out, not before: the tag says "this is what
subscribers have". Keep `BMX.Version` in `lua/autorun/bmx_init.lua`, the top
entry of `CHANGELOG.md` and the tag in step (the offline suite checks the first
two agree): it is what the server
prints at load, and a version that disagrees with the tag makes a bug report
useless.
