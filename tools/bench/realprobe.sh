#!/usr/bin/env bash
# The addon's cost on a REAL client: YOUR connected client (ideally on a GPU) times every
# BMX hook and entity method in a running game while the server stages scenes (nothing
# spawned; 8 first spawns; parked; riding; riding among 4 and 8 riders).
#   BMX_RCON_PASSWORD=... BMX_STUDIO_OWNER=<your name> tools/bench/realprobe.sh [outfile]
# Run on gm_flatgrass. See docs/TESTING.md, "What a client frame costs".
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
HOST="${BMX_STUDIO_HOST:-test-gmod.naliwajka.com}"
PORT="${BMX_STUDIO_PORT:-27016}"
SSH="${BMX_STUDIO_SSH:-root@$HOST}"
GMOD="${BMX_STUDIO_GMOD:-/opt/gmod/garrysmod}"
: "${BMX_RCON_PASSWORD:?set BMX_RCON_PASSWORD}"
: "${BMX_STUDIO_OWNER:?set BMX_STUDIO_OWNER (YOUR connected client)}"
OUT="${1:-$(mktemp)}"
rcon() { python3 "$ROOT/tools/server/rcon.py" --host "$HOST" --port "$PORT" --password "$BMX_RCON_PASSWORD" "$1"; }
scp -q "$HERE/realprobe_sv.lua" "$SSH:$GMOD/lua/realprobe_sv.lua"
scp -q "$HERE/realprobe_cl.lua" "$SSH:$GMOD/data/realprobe_cl.txt"
ssh "$SSH" "chown gmod: $GMOD/lua/realprobe_sv.lua $GMOD/data/realprobe_cl.txt; rm -f $GMOD/data/realprobe/result.txt"
rcon "lua_openscript realprobe_sv.lua" >/dev/null
rcon "realprobe_owner $BMX_STUDIO_OWNER" >/dev/null
rcon "realprobe_push" >/dev/null
sleep 3
rcon "realprobe_run" >/dev/null
echo "probing (~90 s) ..."
for _ in $(seq 1 60); do
  ssh "$SSH" "grep -q DONE $GMOD/data/realprobe/result.txt 2>/dev/null" && break
  sleep 3
done
scp -q "$SSH:$GMOD/data/realprobe/result.txt" "$OUT"
ssh "$SSH" "rm -f $GMOD/lua/realprobe_sv.lua $GMOD/data/realprobe_cl.txt; rm -rf $GMOD/data/realprobe"
cat "$OUT"
