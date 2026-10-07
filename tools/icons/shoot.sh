#!/usr/bin/env bash
# Shoot spawn-menu icons in game and compose them into materials/entities/.
#
#   BMX_RCON_PASSWORD=... tools/icons/shoot.sh [filter]
#
# filter is a Lua pattern on the class (bmx_park_kicker, weapon_, ...); none = all.
# Needs a test server running this addon with a human client on it (the client is
# what renders), ssh to the server, Python with Pillow + numpy. See README.md.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
HOST="${BMX_STUDIO_HOST:-test-gmod.naliwajka.com}"
PORT="${BMX_STUDIO_PORT:-27016}"
SSH="${BMX_STUDIO_SSH:-root@$HOST}"
GMOD="${BMX_STUDIO_GMOD:-/opt/gmod/garrysmod}"
: "${BMX_RCON_PASSWORD:?set BMX_RCON_PASSWORD (the rcon_password of the server)}"
FILTER="${1:-}"
RAW="${BMX_STUDIO_RAW:-$(mktemp -d)}"

rcon() { python3 "$ROOT/tools/server/rcon.py" --host "$HOST" --port "$PORT" --password "$BMX_RCON_PASSWORD" "$1"; }

scp -q "$HERE/studio_sv.lua" "$SSH:$GMOD/lua/bmxstudio_sv.lua"
scp -q "$HERE/studio_cl.lua" "$SSH:$GMOD/data/bmxstudio_cl.txt"
ssh "$SSH" "chown gmod: $GMOD/lua/bmxstudio_sv.lua $GMOD/data/bmxstudio_cl.txt 2>/dev/null; rm -rf $GMOD/data/bmxstudio"

rcon "lua_openscript bmxstudio_sv.lua"
[ -n "${BMX_STUDIO_OWNER:-}" ] && rcon "bmxstudio_owner $BMX_STUDIO_OWNER"
# The client half arrives by net message; the receiver is the one line SendLua can carry.
rcon 'lua_run for _,p in ipairs(player.GetHumans()) do p:SendLua([[net.Receive("bmxstudio_code",function() RunString(net.ReadString(),"bmxstudio") end)]]) end'
sleep 1
rcon "bmxstudio_push"
rcon "bmxstudio_run $FILTER"

echo "rendering on the client ..."
for _ in $(seq 1 360); do
  st=$(ssh "$SSH" "cat $GMOD/data/bmxstudio/_done.txt 2>/dev/null" || true)
  [ -n "$st" ] && break
  sleep 5
done
[ "$st" = "ok" ] || { echo "studio stopped: ${st:-timed out}" >&2; exit 1; }

scp -q "$SSH:$GMOD/data/bmxstudio/*.png" "$RAW/"
echo "raw renders in $RAW"
python3 "$HERE/compose.py" "$RAW"
