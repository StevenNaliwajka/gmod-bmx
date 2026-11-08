#!/usr/bin/env bash
# The camera sweep: YOUR connected client rides every vehicle while the real chase camera
# is swung round it; frame-by-frame verdicts and frame times come back here, the pictures
# stay in the client's data/camsweep/ (fetch them with BMX_CAMSWEEP_CLIENT, below).
#
#   BMX_RCON_PASSWORD=... BMX_STUDIO_OWNER=<your name> tools/ride/camsweep.sh [passes] [ids] [outfile]
#
# passes: 1-4 (chase 12 deg, chase 40, chase -12, first person; default 4); ids: comma-separated
# vehicle ids (default every rideable one). Run on gm_flatgrass (see README.md).
# BMX_CAMSWEEP_CLIENT=user@host:/path/to/garrysmod also copies the pictures to OUTDIR.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
HOST="${BMX_STUDIO_HOST:-test-gmod.naliwajka.com}"
PORT="${BMX_STUDIO_PORT:-27016}"
SSH="${BMX_STUDIO_SSH:-root@$HOST}"
GMOD="${BMX_STUDIO_GMOD:-/opt/gmod/garrysmod}"
: "${BMX_RCON_PASSWORD:?set BMX_RCON_PASSWORD (the rcon_password of the server)}"
: "${BMX_STUDIO_OWNER:?set BMX_STUDIO_OWNER (the name of YOUR connected client; nobody else is used)}"
PASSES="${1:-4}"
IDS="${2:-}"
OUT="${3:-$(mktemp)}"
rcon() { python3 "$ROOT/tools/server/rcon.py" --host "$HOST" --port "$PORT" --password "$BMX_RCON_PASSWORD" "$1"; }

scp -q "$HERE/camsweep_sv.lua" "$SSH:$GMOD/lua/camsweep_sv.lua"
scp -q "$HERE/camsweep_cl.lua" "$SSH:$GMOD/data/camsweep_cl.txt"
ssh "$SSH" "chown gmod: $GMOD/lua/camsweep_sv.lua $GMOD/data/camsweep_cl.txt 2>/dev/null; rm -f $GMOD/data/camsweep/result.txt"
rcon "lua_openscript camsweep_sv.lua" >/dev/null
rcon "camsweep_owner $BMX_STUDIO_OWNER" >/dev/null
rcon "camsweep_push" >/dev/null
sleep 3
rcon "camsweep_run $PASSES ${IDS//,/ }" >/dev/null
n=$(echo ${IDS:-x x x x x x x x x x x x x x x x x} | tr ',' ' ' | wc -w)
each=$(python3 -c "print(int(2+1.4+$PASSES*11.5+1.5)+1)")
echo "camera sweep: $n vehicles, ${each} s each ..."
for _ in $(seq 1 $(( (n * each) / 3 + 40 ))); do
  ssh "$SSH" "grep -q DONE $GMOD/data/camsweep/result.txt 2>/dev/null" && break
  sleep 3
done
scp -q "$SSH:$GMOD/data/camsweep/result.txt" "$OUT"
ssh "$SSH" "rm -f $GMOD/lua/camsweep_sv.lua $GMOD/data/camsweep_cl.txt; rm -rf $GMOD/data/camsweep"
cat "$OUT"
echo "results in $OUT"
