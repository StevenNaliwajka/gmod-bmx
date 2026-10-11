#!/usr/bin/env bash
# Measure the riders' animation on every vehicle, frame by frame, on a connected client.
#
#   BMX_RCON_PASSWORD=... BMX_STUDIO_OWNER=<your name> tools/ride/sweep.sh [detail] [runs] [outfile]
#
# detail: 1 adds a line per frame per rider (each limb's miss, speed, stance, the reach);
# runs: space-separated numbers into SWEEP.RUNS in sweep_sv.lua (default all eighteen).
# Needs a test server running this addon with YOUR client connected (it renders and
# measures), ssh to the server, and an open floor: gm_flatgrass by default. See README.md.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
HOST="${BMX_STUDIO_HOST:-test-gmod.naliwajka.com}"
PORT="${BMX_STUDIO_PORT:-27016}"
SSH="${BMX_STUDIO_SSH:-root@$HOST}"
GMOD="${BMX_STUDIO_GMOD:-/opt/gmod/garrysmod}"
: "${BMX_RCON_PASSWORD:?set BMX_RCON_PASSWORD (the rcon_password of the server)}"
: "${BMX_STUDIO_OWNER:?set BMX_STUDIO_OWNER (the name of YOUR connected client; nobody else is used)}"
DETAIL="${1:-0}"
RUNS="${2:-}"
OUT="${3:-$(mktemp)}"

rcon() { python3 "$ROOT/tools/server/rcon.py" --host "$HOST" --port "$PORT" --password "$BMX_RCON_PASSWORD" "$1"; }

scp -q "$HERE/sweep_sv.lua" "$SSH:$GMOD/lua/sweep_sv.lua"
scp -q "$HERE/sweep_cl.lua" "$SSH:$GMOD/data/sweep_cl.txt"
ssh "$SSH" "chown gmod: $GMOD/lua/sweep_sv.lua $GMOD/data/sweep_cl.txt 2>/dev/null; rm -f $GMOD/data/sweep/result.txt"

rcon "lua_openscript sweep_sv.lua" >/dev/null
rcon "sweep_owner $BMX_STUDIO_OWNER" >/dev/null
rcon "sweep_push" >/dev/null
sleep 3
rcon "sweep_cv as-joined" >/dev/null
sleep 2
rcon "sweep_run $DETAIL $RUNS" >/dev/null

n=$(echo ${RUNS:-$(seq 1 18)} | wc -w)
echo "sweeping $n runs, 20 s each, on the client ..."
for _ in $(seq 1 $((n * 7 + 20))); do
  ssh "$SSH" "grep -q DONE $GMOD/data/sweep/result.txt 2>/dev/null" && break
  sleep 3
done
scp -q "$SSH:$GMOD/data/sweep/result.txt" "$OUT"
# The server and the client are left as they were: the probe goes, the bots were kicked.
ssh "$SSH" "rm -f $GMOD/lua/sweep_sv.lua $GMOD/data/sweep_cl.txt; rm -rf $GMOD/data/sweep"
grep -v '^[0-9-]' "$OUT" | grep -v '^DETAIL' || true
echo "results in $OUT"
