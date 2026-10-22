#!/usr/bin/env bash
# The photo studio as a film (README.md, "Video"): a vehicle ridden through a scenario,
# a shot every simulated frame, drawn from one camera and encoded as an H.264 mp4.
#
#   tools/rider/studio/video.sh <id> <scenario> <out.mp4> [camera] [fps]
#
#   tools/rider/studio/video.sh skateboard skate_session skate.mp4 side
#   tools/rider/studio/video.sh stock bike_session bike.mp4 three-quarter
#   tools/rider/studio/video.sh scooter scooter_session scooter.mp4 follow 60
#
# camera: side (default), side-l, front, back, three-quarter, high, follow, tripod.
# fps: the simulation's frame rate as well as the film's (default 30): the *_session
# scenarios are timed in seconds, so the film is real time at any rate.
# STUDIO_KEEP=shots.json keeps the frames' JSON; STUDIO_SIZE, STUDIO_RANGE, STUDIO_JOBS,
# STUDIO_FRAMES, STUDIO_DIST, STUDIO_TRIPOD and STUDIO_CRF are video.py's.
# STUDIO_GOOFY=1 and STUDIO_PAX=1 work as for studio.sh.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ID="${1:?vehicle id}"
SCEN="${2:?scenario (skate_session, bike_session, scooter_session, ...)}"
OUT="${3:?out.mp4}"
CAM="${4:-side}"
FPS="${5:-30}"
if [ ! -x "$HERE/.build/raster" ]; then
  mkdir -p "$HERE/.build"
  cc -O2 -o "$HERE/.build/raster" "$HERE/raster.c" -lm
fi
if [ ! -f "$HERE/.model/kleiner.mdl" ]; then
  python3 "$HERE/fetch_model.py" "${BMX_STUDIO_MODEL_SRC:-test-gmod:/opt/gmod/garrysmod}"
fi
command -v ffmpeg >/dev/null || { echo "video.sh: needs ffmpeg" >&2; exit 1; }
LUA="${LUA:-lua5.1}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SHOTS="${STUDIO_KEEP:-$TMP/shots.json}"
echo "simulating $ID through $SCEN at $FPS fps..." >&2
STUDIO_VIDEO=1 STUDIO_FPS="$FPS" "$LUA" "$HERE/studio.lua" "$ID" "$SCEN" > "$SHOTS"
echo "drawing from the $CAM camera..." >&2
python3 "$HERE/video.py" "$SHOTS" "$OUT" "$CAM"
