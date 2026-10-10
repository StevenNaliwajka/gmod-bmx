#!/usr/bin/env bash
# Render the Workshop gallery's showcase shots from the vehicles' own code:
# export every model (tools/bike/export.lua, export_park.lua), lay out the
# shot list (gallery_scenes.py) and render it (showcase.py). Nothing here
# needs the game; a change to a model is a re-run away from new pictures.
#
#   tools/bike/gallery.sh [OUT]       default dist/gallery; JOBS=2 renders at once
#
# The shots land in OUT/shots. Which of them go on the page is a choice made
# by copying them into workshop/gallery (file-name order is page order, and
# Steam refuses a file of 1 MB or more).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$(mkdir -p "${1:-$ROOT/dist/gallery}" && cd "${1:-$ROOT/dist/gallery}" && pwd)"
LUA="${LUA:-lua5.1}"
cd "$ROOT"
mkdir -p "$OUT/models" "$OUT/shots"

echo "exporting models into $OUT/models"
"$LUA" tools/bike/export.lua > "$OUT/models/bmx.txt" 2>/dev/null
"$LUA" tools/bike/export.lua 1.1025641 12 > "$OUT/models/cruiser.txt" 2>/dev/null   # 43/39 wheelbase, 24-inch
"$LUA" tools/bike/export.lua 0.8717949 8 > "$OUT/models/mini.txt" 2>/dev/null      # 34/39 wheelbase, 16-inch
for k in road fixie city dh tandem unicycle penny ebike emoto dirtbike moped skateboard scooter skates; do
    "$LUA" tools/bike/export.lua kind=$k > "$OUT/models/$k.txt" 2>/dev/null
done
for p in street_plaza vert_ramp dirt_line; do
    "$LUA" tools/bike/export_park.lua preset $p > "$OUT/models/preset_$p.txt" 2>/dev/null
done

echo "laying out the shots"
python3 tools/bike/gallery_scenes.py "$OUT" 2>/dev/null

echo "rendering (${JOBS:-2} at a time; a still is ~1 min, a turntable ~5)"
ls "$OUT"/scenes/*.json | xargs -P "${JOBS:-2}" -I{} bash -c '
    n=$(basename "{}" .json); ext=jpg
    grep -q "\"turntable\"" "{}" && ext=gif
    python3 tools/bike/showcase.py "{}" "'"$OUT"'/shots/$n.$ext" | tail -n1'
