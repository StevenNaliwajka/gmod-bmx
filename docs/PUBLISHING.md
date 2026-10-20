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

## The gallery

`workshop/gallery/` is the page's gallery, in file-name order; each file must
be a JPEG, PNG or GIF under 1 MB (`tools/workshop_sync.py` checks). The renders
in it are made from the vehicles' and park pieces' own code, offline, the same
way the icon is:

```
tools/bike/gallery.sh            # -> dist/gallery/shots, ~30 min with JOBS=2
```

It exports every model (`tools/bike/export.lua`, `export_park.lua`,
`export_drawn.lua`), lays out the shot list (`tools/bike/gallery_scenes.py`:
every vehicle together and named, each family as a still and as a turntable
GIF with its names, the 14 paints, a drivetrain close-up, two ready-made parks
and an orbit of one) and renders it (`tools/bike/showcase.py`). Last it makes
the extras sheet (`extras_sheet.py`): the bike rack and the bike lock (a
locked BMX's chain and padlock) rendered from their own drawing code, beside
the filmer camera and rental machine, which are base-game models and so are
shown by their spawn-menu pictures. Copy the shots
the page should show into `workshop/gallery/` under a numbered name. Re-run it
when a model changes, so the pictures stay true to the game.

The in-game shots (the front flip GIF, the lineup by the ramp) come from the
test server (`tools/ride/shoot.sh`), which needs a connected client.

## Publishing

The Workshop item belongs to the Steam account **ConvexBurrito5**. Uploading
is done by `gmpublish`, which ships with Garry's Mod (`bin\gmpublish.exe` on
Windows) and uploads as whichever account the running Steam client is signed
into -- so it runs where that client is, never on a server and never in CI. The
standard route is the gmod-marionette VM, driven from the desktop (see "The
standard route" below).

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
| 1.3.9 | 2026-10-20 | 0e7f70d, game files identical to b7ee852 (MGMT elevated call workshop-publish items=bmx, E-bc1887b7, auto-approved; branch pipeline 1340 green on b7ee852, validate + 199/199 headless; the rider pass looked at on a real client on test-gmod first; live on Petopia from 03:12 UTC). The call's content upload and change note landed, then its gallery re-send failed ("SubmitItemUpdate: Fail") and left the page with no pictures; E-54765ac9 page_only=1 put all 20 back (03:17 UTC, "replaced 0 old") | 2026-10-20 03:13 UTC; page text unchanged, the 20 gallery pictures re-added at 03:17 UTC; the item downloaded anonymously is the commit, file for file (243 files) |
| map 1.0.3 | 2026-10-20 | Petopia BMX Fall only (3815469993), petopia_bmx_fall 2a2c269: SkateGM's skater no longer falls into the ramps (the transition tops beside every coping and the flat ramp's side handed to SkateGM as meshes cut from the BSP; BSP unchanged; SkateGM's own loader: 365 coping spots with no ground -> 0; funbox 2's bevel cracks left, 6 spots: an upstream SkateGM fix or a slope change). MGMT elevated call workshop-publish items=map, E-9892997a: it reported "SubmitItemUpdate: Timeout", but the content and the change note landed; only the unchanged gallery's re-send was skipped. Map suite 122/122; live on Petopia from 02:47 UTC | 2026-10-20 02:50 UTC; page text, icon and 7 pictures unchanged; the item downloaded anonymously is the commit, file for file (15 files) |
| 1.3.8 | 2026-10-19 | e445460 (MGMT elevated call workshop-publish items=bmx, E-2e7b21b2, auto-approved, filed once the owner was out of a game; branch pipeline 1315 green, validate + 199/199 headless on the same sha; live on Petopia from 23:38 UTC) | 2026-10-19 23:52 UTC; page text updated ("New in 1.3"), the same 20 gallery pictures re-sent; the item downloaded anonymously is the commit, file for file (243 files) |
| mode 1.0.1 | 2026-10-19 | BMX (Mode) only (3815470101), gmod-bmx-mode 4698947: the two bot errors from live Petopia's journal (MGMT elevated call workshop-publish items=mode, E-8ce0ea4d, auto-approved; offline 149/149, and both errors reproduced then fixed on a real server, CI box gmod-bike3; live from 23:38 UTC) | 2026-10-19 23:53 UTC; page text and 5 pictures unchanged; the item downloaded anonymously is the commit, file for file (25 files) |
| 1.3.7 | 2026-10-19 | 799bce7 (MGMT elevated call workshop-publish items=bmx, E-e2041eb4, auto-approved; branch pipeline 1300 green, validate + 198/198 headless on the same sha (1299, on 0e0956d, had validate OOM-killed on the CI box: 799bce7's tests/run.lua fixes the suite's memory); live on Petopia from 06:09 UTC) | 2026-10-19 06:10 UTC; page text unchanged, the same 20 gallery pictures re-sent; the item downloaded anonymously is the commit, file for file (243 files) |
| 1.3.6 | 2026-10-19 | 99d5d16 (MGMT elevated call workshop-publish items=bmx, E-da7399cd, auto-approved; branch pipeline 1289 green, validate + 197/197 headless on the same sha; live on Petopia from 03:10 UTC) | 2026-10-19 03:11 UTC; page text updated (the combo line), the same 20 gallery pictures re-sent; the item downloaded anonymously is the commit, file for file (243 files) |
| 1.3.5 | 2026-10-15 | d0a2e27 (MGMT elevated call workshop-publish items=bmx, E-04837547, auto-approved: the sen4 GPU for the marionette was refused all night, 110130's guest agent down; branch pipeline 1272 green, validate + 197/197 headless on the same sha; live on Petopia from 06:35 UTC). Carries all of 1.3.4 (30bad60, tag v1.3.4), which never went to the Workshop on its own | 2026-10-15 06:36 UTC; page text unchanged, the same 20 gallery pictures re-sent ("replaced 20 old"); the item downloaded anonymously is the commit, file for file (243 files) |
| map 1.0.2 | 2026-10-15 | Petopia BMX Fall only (3815469993), petopia_bmx_fall af0de49: works with SkateGM -- the floor in pieces, so SkateGM's skater no longer falls through the park's north-east half, and the city's colliders handed to SkateGM (MGMT elevated call workshop-publish items=map, E-ec97df7f: the first real use of that route, the marionette's GPU being unavailable all night; its first run failed with no Steam client on MGMT, MGMT retried it); live on Petopia from 03:47 UTC | 2026-10-15 03:45 UTC; page text unchanged, its 7 gallery pictures re-sent; item now 2788729 bytes |
| map 1.0.1 | 2026-10-11 | Petopia BMX Fall only (3815469993), petopia_bmx_fall 40ed77d: the city built a slice at a time at join (tools/workshop_marionette.sh map --ref 40ed77d); live on Petopia from 15:05 UTC | 2026-10-11 15:04 UTC; page text unchanged, its 7 gallery pictures re-sent |
| 1.3.3 | 2026-10-12 | 547ed70 (tools/workshop_marionette.sh bmx --ref 547ed70; main pipeline 1203 validate + publish:github green, 197/197 headless on the same sha (branch pipeline 1202); live on Petopia from 03:16 UTC) | 2026-10-12 03:19 UTC; page text unchanged, the same 20 gallery pictures re-sent; the item downloaded anonymously is the commit, file for file |
| 1.3.2 | 2026-10-11 | dd86ae5 (tools/workshop_marionette.sh bmx --ref dd86ae5; main pipeline 1193 green, 197/197 headless; live on Petopia from 19:59 UTC) | 2026-10-11 20:02 UTC; page text unchanged, the same 20 gallery pictures re-sent; the item downloaded anonymously is the commit, file for file |
| 1.3.1 | 2026-10-11 | c2b5f25 (tools/workshop_marionette.sh bmx --ref c2b5f25; main pipeline 1185 green; live on Petopia from 14:04 UTC) | 2026-10-11 14:07 UTC; page text unchanged, the same 20 gallery pictures re-sent |
| 1.3.0 | 2026-10-11 | 482e836 (tools/workshop_marionette.sh bmx --ref 482e836; main pipeline 1179 green, 196/196 headless; live on Petopia from 09:36 UTC) | 2026-10-11 09:39 UTC; page text unchanged, the same 20 gallery pictures re-sent |
| 1.2.1 | 2026-10-10 | b67c8f2 (tools/workshop_marionette.sh's steps, run by hand from the desktop: the first upload from the marionette) | 2026-10-10 16:46 UTC; page text unchanged, the same 20 gallery pictures re-sent |
| page only | n/a | 81c23d9 | page only, 2026-10-10: 1.2.0 text and 20-picture gallery from 81c23d9 |
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

## The standard route: tools/workshop_marionette.sh

**Owner's decision, 2026-10-10: Workshop uploads go from the desktop through the
gmod-marionette VM (119158).** Its Steam client is signed in as ConvexBurrito5.
It is kept in offline mode so its game client can join the LAN test server, and
it goes online only while an upload runs. The decision to publish is still the
owner's; this is only how it gets done.

    tools/workshop_marionette.sh bmx --ref <sha> --dry-run           # pack and check on the desktop, nothing else
    tools/workshop_marionette.sh bmx --ref <sha> --note "what changed"
    tools/workshop_marionette.sh bmx --page-only                     # text, tags, icon, gallery

The arguments are `tools/workshop_sync.py`'s. Run it from the desktop's main
checkout (`/home/gmod/GMod/gmod-bmx`), because it copies the item repos as they
are there, and the gallery comes from the working tree. In order, it:

1. Does the dry run on the desktop. With `--dry-run` it stops there.
2. Refuses while ConvexBurrito5 is in a game. An upload starts a Garry's Mod
   session, and Steam would sign one of the two out.
3. Asks (unless `--yes`), then borrows sen4's GPU for the marionette
   (`webdesk-guest gpu-claim`). **That shuts down win11-marionette, another
   org's desktop, while it is held**, so the claim lasts minutes, not hours.
4. Copies gmad, libsteam_api.so and the repos to `~/GMod` on the marionette.
5. Switches Steam online (`WantsOfflineMode 0` in `loginusers.vdf`, restart,
   wait for the logon), uploads, and switches it back offline.
6. Releases the GPU. Going back offline and releasing the GPU also happen on a
   failure or Ctrl-C.

If it stops with a WARNING, finish by hand: set `WantsOfflineMode` back to 1 on
the marionette (`~/.steam/steam/config/loginusers.vdf`, with Steam stopped:
`systemctl --user stop steam`), then run `webdesk-guest gpu-release 119158`.

## Releasing an update (when the owner says go)

1. `CHANGELOG.md`: the top entry is the version going out; change its
   "not yet on the Workshop" line to the date it went out.
2. From the desktop: `tools/workshop_marionette.sh bmx --ref <sha> --note
   "what changed"` (the standard route, below; `--dry-run` first). If the
   marionette cannot be had, the owner's own PC: `tools/workshop_sync.py`, or
   `tools/package-workshop.sh` then `update.bat` / `./publish.sh update`.
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
