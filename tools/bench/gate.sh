#!/usr/bin/env bash
# THE GPU GATE: the real-client benchmarks, run on the GPU client and judged against the
# budget (tools/bench/gate.py). The `gpu-bench` CI job runs this; so can a person.
#
#   tools/bench/gate.sh [OUT]        (default bench-out/)
#
# Borrows the GPU for the client VM, installs THIS working tree's addon, and runs:
#   camsweep.txt  every vehicle, 4 camera passes (no bad frame, every rider posed, <16.7 ms)
#   spawns.txt    every kind's first spawn, ridden away at once (no frame over 16.7 ms)
#   features.txt  every feature in its own scene (fps and server cost against baseline.json)
#   riders.txt    8 riders on bots in view, if the client can host a listen server (see sp.sh riders)
#   lowfps.txt    the camera sweep held to 30 fps, a weak PC's rate (no bad frame)
# then judges them. Exit 0 pass, 1 a budget broken, 2 the run could not be made.
#
# THE CARD. BMX_GPU_CLAIM / BMX_GPU_RELEASE are the commands that borrow and return it:
# on the gmod org desktop (the CI runner) `webdesk-guest gpu-claim 119158 <min>` and
# `webdesk-guest gpu-release 119158`, the defaults; from the MGMT box
#   BMX_GPU_CLAIM="python3 ~/Desktop/MGMT/core/gpu_broker.py claim gmod 119158 120"
#   BMX_GPU_RELEASE="python3 ~/Desktop/MGMT/core/gpu_broker.py release gmod 119158"
# The broker refuses while the card's home box is busy (Revit open); the claim is retried
# every minute for BMX_GPU_WAIT minutes (default 60). The card and the client are always
# given back, pass or fail (the trap).
#
# BMX_GATE_KEEP=1 leaves the card borrowed and the client as it is at the end, for more
# checks by hand (tools/bench/netdemo.sh, sp.sh p0); then `sp.sh restore` and the release.
# BMX_GATE_SKIP="riders lowfps" leaves benchmarks out (each one left out is said in the
# judgement as "not run"; camsweep, spawns and features are never optional).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${1:-$ROOT/bench-out}"
mkdir -p "$OUT"
SP="$HERE/sp.sh"
CLAIM="${BMX_GPU_CLAIM:-webdesk-guest gpu-claim 119158 150}"
RELEASE="${BMX_GPU_RELEASE:-webdesk-guest gpu-release 119158}"
SKIP=" ${BMX_GATE_SKIP:-} "
claimed=0
log() { printf '[gate %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
cleanup() {
  if [ "${BMX_GATE_KEEP:-0}" = 1 ] && [ "$claimed" = 1 ]; then
    log "BMX_GATE_KEEP=1: the client and the GPU are left as they are (sp.sh restore, then release, when done)"
    return
  fi
  log "restoring the client"; "$SP" restore >/dev/null 2>&1 || true
  if [ "$claimed" = 1 ]; then log "returning the GPU"; $RELEASE || true; fi
}
trap cleanup EXIT

# The broker answers in JSON and exits 0 either way: a refusal ("the GPU is in use ...:
# revit.exe is running") is `"ok": false`, a grant `"ok": true` (perhaps "queued": the card
# is being handed over and the client VM starts in a minute or two; sp.sh ready waits).
granted() { local out; out="$($CLAIM 2>&1)"; echo "$out"
            ! grep -q '"ok": *false' <<<"$out" && grep -q '"ok": *true' <<<"$out"; }
log "borrowing the GPU: $CLAIM"
for i in $(seq 1 "${BMX_GPU_WAIT:-60}"); do
  if granted; then claimed=1; break; fi
  log "refused (attempt $i), again in a minute"; sleep 60
done
[ "$claimed" = 1 ] || { log "never got the GPU"; exit 2; }

"$SP" ready || { log "the client never came up"; exit 2; }
inst=$("$SP" install 2>&1) || { log "install failed:"; echo "$inst" | sed 's/^/    /'; exit 2; }
echo "$inst" | grep -E "cannot find|installed lib" | sed 's/^/    /' || true
up=0
for _ in 1 2; do "$SP" launch >/dev/null && { up=1; break; }; log "no session, launching again"; done
if [ "$up" != 1 ]; then
  # What the client said: its launch log and the game's console (the fifth whole run,
  # 2026-11-11, never reached a session twice in 12 min, and the client was off again, with
  # the card, before anyone could look).
  log "the game never reached a session; the client's last words:"
  CLV="${BMX_SP_CLIENT:-marionette@10.9.1.58}"
  GV="${BMX_SP_GMOD:-/home/marionette/.steam/debian-installation/steamapps/common/GarrysMod/garrysmod}"
  ssh -o BatchMode=yes "$CLV" "tail -n 25 /tmp/gmod-sp.log; echo ---; tail -n 40 $GV/console.log" 2>&1 | sed 's/^/    /'
  exit 2
fi

bench() {  # name, then the command; its output to OUT/name.txt
  local name="$1"; shift
  case "$SKIP" in *" $name "*) log "skipping $name"; return 0 ;; esac
  log "running $name"
  "$@" > "$OUT/$name.txt" 2>&1 || log "$name exited $?"
  head -c 400 "$OUT/$name.txt" | head -3
}
bench camsweep "$SP" camsweep 4
bench spawns env SPAWN_RIDE=true "$SP" spawns
bench features "$SP" features
bench lowfps "$SP" lowfps 30
# Bots need player slots: the riders scene runs in a session of its own, a listen server.
case "$SKIP" in *" riders "*) ;; *)
  if BMX_SP_MAXPLAYERS=9 "$SP" launch >/dev/null; then bench riders "$SP" riders 8
  else log "no listen server session: riders not run"; fi ;;
esac

python3 "$HERE/gate.py" judge "$OUT" --json "$OUT/gate.json"
