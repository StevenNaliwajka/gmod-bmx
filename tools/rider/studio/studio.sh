#!/usr/bin/env bash
# The offline photo studio (README.md, "The photo studio"): a vehicle ridden through a
# scenario by kleiner's real skeleton, drawn with kleiner's own mesh.
#
#   tools/rider/studio/studio.sh <id> [scenario] [out.png] [shots] [scale]
#
# The first run builds the rasterizer and fetches the model from a GMod install
# (BMX_STUDIO_MODEL_SRC, default test-gmod:/opt/gmod/garrysmod, over ssh).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ID="${1:?vehicle id}"
SCEN="${2:-}"
OUT="${3:-$ID.png}"
SHOTS="${4:-}"
SCALE="${5:-0.7}"
if [ ! -x "$HERE/.build/raster" ]; then
  mkdir -p "$HERE/.build"
  cc -O2 -o "$HERE/.build/raster" "$HERE/raster.c" -lm
fi
if [ ! -f "$HERE/.model/kleiner.mdl" ]; then
  python3 "$HERE/fetch_model.py" "${BMX_STUDIO_MODEL_SRC:-test-gmod:/opt/gmod/garrysmod}"
fi
LUA="${LUA:-lua5.1}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"$LUA" "$HERE/studio.lua" "$ID" "$SCEN" > "$TMP/shots.json"
python3 "$HERE/render.py" "$TMP/shots.json" "$OUT" "$SHOTS" "$SCALE"
