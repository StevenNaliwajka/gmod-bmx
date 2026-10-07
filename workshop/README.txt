BMX, Steam Workshop upload kit
===============================

What is in here
  bmx.gma              the addon, packed (checked with Valve's own gmad)
  icon.jpg             the Workshop thumbnail, 512x512
  update.bat           Windows: upload this version to the live item (the usual)
  publish.bat          Windows: FIRST upload only; refuses while workshop-id.txt exists
  workshop-id.txt      the live item's ID, 3814420080, read by the scripts
  find-gmpublish.ps1   used by the two .bat files to find Garry's Mod
  publish.sh           the same for a Linux PC
  description.bbcode   the item page's text, to paste if the page still shows the old one

Before you start
  1. Steam is running and signed in as ConvexBurrito5.
  2. That account owns Garry's Mod (the uploader, gmpublish, ships with it).

BMX is already on the Workshop:
  https://steamcommunity.com/sharedfiles/filedetails/?id=3814420080
  For a new version skip straight to "Every later release".

First upload (done 2026-10-05; kept for the record)
  Double-click publish.bat, press a key when it asks, and wait for the upload.
  It prints the new item's Workshop ID. WRITE IT DOWN: updates need it, and
  running publish.bat a second time makes a second, separate item.

  Then in Steam: Garry's Mod > Workshop > Your Files > BMX.
    - Accept the Steam Workshop agreement if the page asks for it (until you do,
      nobody else can see the item).
    - Set Visibility: Private while you check it, Public when you are happy.
    - Add screenshots or a video from in game if you like.
  The title, description and icon come from the upload; you can edit the
  description on that page afterwards (it takes BBCode there).

Every later release
  Double-click update.bat. It reads the Workshop ID from workshop-id.txt and
  asks only for a one-line note of what changed. (Linux: ./publish.sh update
  "what changed".) An update uploads the addon, not the page: then open the
  item page and check its TITLE is "BMX" and its description matches
  description.bbcode in this folder; if not, Edit title & description and
  paste that file's contents in (the page takes BBCode).

If the .bat cannot find gmpublish.exe
  It asks you to paste the path. It is in your Garry's Mod folder:
  Steam > right-click Garry's Mod > Manage > Browse local files > bin\gmpublish.exe
  Or run it by hand from this folder:
    "<GarrysMod>\bin\gmpublish.exe" create -addon bmx.gma -icon icon.jpg
    "<GarrysMod>\bin\gmpublish.exe" update -addon bmx.gma -id 3814420080 -changes "what changed"

Check it works
  Subscribe to the item, start Garry's Mod, sandbox, and type bmx_spawn in the
  console (or find BMX in the Entities tab). The console prints
  "[BMX] VERSION loaded" on start.
