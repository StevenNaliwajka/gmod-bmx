#!/usr/bin/env bash
# THE NETWORK DEMO: bmx_predict and the lean's latency, ridden on a real dedicated server by
# a real client with a real (faked) ping. docs/TUNING.md's latency table, filled.
#
#   tools/bench/netdemo.sh            (after tools/bench/sp.sh install on the GPU client)
#
# 1. The CI game server (BMX_NET_SERVER, root ssh) is borrowed: bmx-test's lock
#    (/run/lock/bmx-test.lock) is held for the whole demo, so no pipeline restarts it under
#    the client, and it is restarted on gm_flatgrass through a runtime drop-in with
#    sv_cheats 1 (net_fakelag is a cheat). Both go again at the end.
# 2. The GPU client connects (sp.sh launch with BMX_SP_CONNECT), the server seats it on a
#    stock bike on the open lower plane (netdemo_sv.lua), and the client rides the table
#    (latency_cl.lua): net_fakelag 0 / 50 / 100 / 150, bmx_predict 0 and 1, 8 taps each.
# 3. The rows land in OUT/latency.txt (default bench-out/).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${1:-$ROOT/bench-out}"
mkdir -p "$OUT"
SV="${BMX_NET_SERVER:-root@10.0.1.49}"
SV_ADDR="${BMX_NET_ADDR:-10.0.1.49:27015}"
CL="${BMX_SP_CLIENT:-marionette@10.9.1.58}"
G="${BMX_SP_GMOD:-/home/marionette/.steam/debian-installation/steamapps/common/GarrysMod/garrysmod}"
SG=/opt/gmod/garrysmod
s() { ssh -o BatchMode=yes "$SV" "$@"; }
c() { ssh -o BatchMode=yes "$CL" "$@"; }
log() { printf '[netdemo %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
rcon() {  # one console command on the server, its password read there and never printed
  s "PW=\$(sed -n 's/^[[:space:]]*rcon_password[[:space:]]*\"\(.*\)\"[[:space:]]*\$/\1/p' $SG/cfg/server.cfg | head -1); IP=\$(ip -4 -o route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if(\$i==\"src\") print \$(i+1)}'); GMOD_RCON_PASSWORD=\"\$PW\" python3 /usr/local/lib/gmod/rcon.py --host \"\$IP\" $(printf '%q' "$1")"
}

cleanup() {
  log "putting the server back"
  c "pkill -f GarrysMod/hl2_linu[x]; true" 2>/dev/null
  s "rm -f /run/systemd/system/gmod.service.d/zz-netdemo.conf; systemctl daemon-reload; systemctl restart gmod; pkill -f 'sleep 7201'; true"
}
trap cleanup EXIT

# CAN THE CLIENT REACH THE SERVER AT ALL? The estate drops traffic between networks unless a
# path is declared (MGMT Config/service-needs.json): the first run (2026-11-11) waited 7 min
# for a client whose connects never arrived ("Connection failed after 6 retries") while a
# query from another network was answered. So the client asks the server for its info first
# (an A2S query, answered whatever the map or the lock) and this stops at once if it cannot.
reach() {
  c "python3 -c \"import socket,sys;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(3);h,p='${SV_ADDR%:*}',int('${SV_ADDR##*:}');[s.sendto(b'\\xff\\xff\\xff\\xffTSource Engine Query\\x00',(h,p)) for _ in (1,)];s.recvfrom(1400);print('ok')\"" 2>/dev/null | grep -q ok
}
log "checking the client reaches $SV_ADDR (udp)"
if ! reach; then
  log "the client ($CL) gets no answer from $SV_ADDR over udp: the router has no path from its network"
  log "to the game server (MGMT Config/service-needs.json declares paths). Not run."
  trap - EXIT
  exit 2
fi

log "taking the server's run lock (waits for a pipeline's run to end)"
s "nohup flock /run/lock/bmx-test.lock sleep 7201 >/dev/null 2>&1 &"
for _ in $(seq 1 180); do s "pgrep -f 'sleep 7201' >/dev/null" && break; sleep 20; done
s "pgrep -f 'sleep 7201' >/dev/null" || { log "never got the lock"; exit 2; }

log "restarting the server on gm_flatgrass, sv_cheats 1"
s ": > $SG/console.log; mkdir -p /run/systemd/system/gmod.service.d && printf '[Service]\nEnvironment=GMOD_MAP=gm_flatgrass\n' > /run/systemd/system/gmod.service.d/zz-netdemo.conf && systemctl daemon-reload && systemctl restart gmod"
for _ in $(seq 1 120); do s "grep -qas '\[BMX\].*loaded (server)' $SG/console.log" && break; sleep 2; done
for _ in $(seq 1 30); do rcon "echo up" >/dev/null 2>&1 && break; sleep 2; done
rcon "sv_cheats 1" >/dev/null
scp -q "$HERE/netdemo_sv.lua" "$SV:$SG/data/netdemo_sv.txt" && s "chown gmod:gmod $SG/data/netdemo_sv.txt"

log "the client connects to $SV_ADDR"
scp -q "$HERE/latency_cl.lua" "$CL:$G/data/latency_cl.txt"
c "rm -f $G/data/probe/latency.txt"
BMX_SP_CONNECT="$SV_ADDR" "$HERE/sp.sh" launch >/dev/null 2>&1 &
joined=0
for _ in $(seq 1 120); do
  rcon "status" 2>/dev/null | grep -q '^players.* [1-9][0-9]* humans' && { joined=1; break; }
  sleep 3
done
[ "$joined" = 1 ] || { log "the client never joined (Steam validation? see the client's console.log)"; c "tail -20 $G/console.log"; exit 2; }
sleep 20
"$HERE/sp.sh" focus
log "seating it and riding the table (~5 min)"
rcon 'lua_run RunString(file.Read("netdemo_sv.txt","DATA"),"netdemo")' >/dev/null
for _ in $(seq 1 120); do c "grep -q DONE $G/data/probe/latency.txt 2>/dev/null" && break; sleep 5; done
c "cat $G/data/probe/latency.txt" | tee "$OUT/latency.txt"
grep -q DONE "$OUT/latency.txt"
