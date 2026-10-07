#!/usr/bin/env bash
# Photograph each vehicle RIDDEN, in game, through a connected client.
#
#   BMX_RCON_PASSWORD=... tools/ride/shoot.sh [ids|all] [throttle] [outdir] [seq]
#
# ids: comma-separated vehicle ids (stock,road,...); default every vehicle in the menu.
# Needs a test server running this addon with a human connected (the client renders),
# and ssh to the server. See README.md.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
HOST="${BMX_STUDIO_HOST:-test-gmod.naliwajka.com}"
PORT="${BMX_STUDIO_PORT:-27016}"
SSH="${BMX_STUDIO_SSH:-root@$HOST}"
GMOD="${BMX_STUDIO_GMOD:-/opt/gmod/garrysmod}"
: "${BMX_RCON_PASSWORD:?set BMX_RCON_PASSWORD (the rcon_password of the server)}"
IDS="${1:-all}"
THR="${2:-0.45}"
OUT="${3:-$(mktemp -d)}"
MODE="${4:-}"     # "seq": a pedal-off, a turn and a bunny hop, filmed frame by frame
mkdir -p "$OUT"

rcon() { python3 "$ROOT/tools/server/rcon.py" --host "$HOST" --port "$PORT" --password "$BMX_RCON_PASSWORD" "$1"; }

scp -q "$HERE/ride_sv.lua" "$SSH:$GMOD/lua/ridestudio_sv.lua"
scp -q "$HERE/ride_cl.lua" "$SSH:$GMOD/data/ridestudio_cl.txt"
ssh "$SSH" "chown gmod: $GMOD/lua/ridestudio_sv.lua $GMOD/data/ridestudio_cl.txt 2>/dev/null; rm -rf $GMOD/data/ridestudio"

rcon "lua_openscript ridestudio_sv.lua" >/dev/null
[ -n "${BMX_STUDIO_OWNER:-}" ] && rcon "ridestudio_owner $BMX_STUDIO_OWNER"
rcon 'lua_run for _,p in ipairs(player.GetHumans()) do p:SendLua([[net.Receive("ridestudio_code",function() RunString(net.ReadString(),"ridestudio") end)]]) end' >/dev/null
sleep 1
rcon "ridestudio_push"
rcon "ridestudio_run $IDS $THR $MODE"

echo "shooting on the client ..."
st=""
for _ in $(seq 1 400); do
  st=$(ssh "$SSH" "cat $GMOD/data/ridestudio/_done.txt 2>/dev/null" || true)
  [ -n "$st" ] && break
  sleep 4
done
scp -q "$SSH:$GMOD/data/ridestudio/*.jpg" "$OUT/" || true
echo "pictures in $OUT (${st:-timed out})"
