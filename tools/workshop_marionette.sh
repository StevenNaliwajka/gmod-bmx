#!/usr/bin/env bash
# Publish to the Steam Workshop through the gmod-marionette VM (119158): the
# standard route since 2026-10-10 (owner's decision, docs/PUBLISHING.md).
#
#   tools/workshop_marionette.sh bmx --ref <sha> --note "what changed"
#   tools/workshop_marionette.sh bmx --page-only
#   tools/workshop_marionette.sh bmx --ref <sha> --dry-run    # pack and check here, touch nothing
#
# Every argument goes to tools/workshop_sync.py. The marionette's Steam client
# is signed in as ConvexBurrito5 and kept in OFFLINE mode, so its game client
# can join the LAN test server; it goes online only for the upload.
#
# In order:
#   1. a dry run HERE (packs, checks the whitelist and the gallery); with
#      --dry-run it stops there
#   2. refuses while ConvexBurrito5 is in a game: the upload starts a Garry's
#      Mod session, and Steam signs one of the two out ("Logged In Elsewhere")
#   3. asks (unless --yes), then borrows sen4's GPU for the marionette
#      (webdesk-guest gpu-claim). THIS SHUTS DOWN win11-marionette, another
#      org's desktop, for as long as it is held
#   4. copies gmad + libsteam_api.so and the item repos (as they are on this
#      desktop: the gallery comes from the working tree) to ~/GMod there
#   5. Steam online, the upload, Steam back offline
#   6. gives the GPU back. 5's "back offline" and 6 also run on any failure
#      or Ctrl-C.
#
# A Workshop update still goes out only when the owner says so.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESKTOP="${BMX_DESKTOP:-$(cd "$ROOT/.." && pwd)}"   # holds gmod-bmx, petopia_bmx_fall, gmod-bmx-mode
VM=119158
HOST=marionette                                       # ssh alias (org desktop access)
MINUTES="${BMX_GPU_MINUTES:-30}"
OWNER=76561198170324345                               # ConvexBurrito5
TOOLS="$HOME/sdk/gmod-tools"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8)

die() { echo "workshop_marionette: $*" >&2; exit 1; }
[ -f "$DESKTOP/gmod-bmx/tools/workshop_sync.py" ] || die "no $DESKTOP/gmod-bmx (set BMX_DESKTOP)"

dry=0; yes=0; items=()
for a in "$@"; do
    case "$a" in
        --dry-run) dry=1 ;;
        --yes) yes=1 ;;
        bmx) items+=(gmod-bmx) ;;
        map) items+=(petopia_bmx_fall) ;;
        mode) items+=(gmod-bmx-mode) ;;
    esac
done
[ ${#items[@]} -gt 0 ] || items=(gmod-bmx petopia_bmx_fall gmod-bmx-mode)
[[ " ${items[*]} " == *" gmod-bmx "* ]] || items=(gmod-bmx "${items[@]}")   # the tool lives there

# 1. Dry run here. workshop_sync packs from each repo's --ref (default
# origin/main), so fetch first.
if [ ! -x "$TOOLS/gmad" ] || [ ! -f "$TOOLS/libsteam_api.so" ]; then
    mkdir -p "$TOOLS"
    scp -q -o BatchMode=yes gmod:/opt/gmod/bin/linux64/gmad gmod:/opt/gmod/bin/linux64/libsteam_api.so "$TOOLS/"
    chmod +x "$TOOLS/gmad"
fi
for r in "${items[@]}"; do git -C "$DESKTOP/$r" fetch -q origin; done
args=(); for a in "$@"; do [ "$a" = --dry-run ] || [ "$a" = --yes ] || args+=("$a"); done
python3 "$DESKTOP/gmod-bmx/tools/workshop_sync.py" "${args[@]}" --dry-run
[ "$dry" = 1 ] && exit 0

# 2. Not while the owner is in a game.
state="$(curl -s --max-time 15 "https://steamcommunity.com/profiles/$OWNER/?xml=1" \
    | sed -n 's:.*<onlineState>\(.*\)</onlineState>.*:\1:p' | head -1)"
[ "$state" != "in-game" ] || die "ConvexBurrito5 is in a game; upload when they are out of it"
[ -n "$state" ] || echo "workshop_marionette: could not read ConvexBurrito5's Steam state; going on"

# 3. Ask, then the GPU.
if [ "$yes" != 1 ]; then
    read -r -p "Upload to the Steam Workshop as ConvexBurrito5 (shuts win11-marionette down meanwhile)? Type YES: " ok
    [ "$ok" = YES ] || die "not uploaded"
fi
jget() { python3 -I -c 'import sys,json; d=json.load(sys.stdin)["detail"]; print(d.get(sys.argv[1], ""))' "$1"; }
claimed=0; online=0
steam_mode() {   # $1: 0 = online, 1 = offline. Waits for the logon when going online.
    "${SSH[@]}" "$HOST" bash -s -- "$1" <<'EOF'
set -e
export XDG_RUNTIME_DIR=/run/user/$(id -u)
f=~/.steam/steam/config/loginusers.vdf; log=~/.steam/steam/logs/connection_log.txt
systemctl --user stop steam
for i in $(seq 30); do pgrep -x steam >/dev/null || break; sleep 1; done
sed -i -E "s/(\"WantsOfflineMode\"[[:space:]]+)\"[01]\"/\1\"$1\"/" "$f"
n=$(wc -l < "$log" 2>/dev/null || echo 0)
systemctl --user start steam
[ "$1" = 1 ] && exit 0
for i in $(seq 60); do
    tail -n +"$((n + 1))" "$log" 2>/dev/null | grep -q '\[Logged On' && exit 0
    sleep 3
done
echo "Steam did not log on in 180 s" >&2; exit 1
EOF
}
cleanup() {
    if [ "$online" = 1 ]; then
        steam_mode 1 || echo "WARNING: the marionette's Steam may still be ONLINE: set WantsOfflineMode 1 by hand" >&2
    fi
    if [ "$claimed" = 1 ]; then
        webdesk-guest gpu-release "$VM" >/dev/null || echo "WARNING: release the GPU by hand: webdesk-guest gpu-release $VM" >&2
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if [ "$(webdesk-guest gpu "$VM" | jget holder)" != "$VM" ]; then
    # A claim right after win11-marionette boots fails its idle check; retry.
    for try in 1 2 3; do
        [ "$(webdesk-guest gpu-claim "$VM" "$MINUTES" | jget ok)" = True ] && { claimed=1; break; }
        [ "$try" = 3 ] || { echo "GPU claim refused, retrying in 60 s"; sleep 60; }
    done
    [ "$claimed" = 1 ] || die "the GPU claim was refused (webdesk-guest gpu $VM says why)"
fi
echo "waiting for $HOST..."
timeout 420 bash -c "until ${SSH[*]} $HOST true 2>/dev/null; do sleep 6; done" || die "$HOST did not come up"

# 4. Tools and repos.
"${SSH[@]}" "$HOST" 'mkdir -p ~/sdk/gmod-tools ~/GMod'
scp -q -o BatchMode=yes "$TOOLS/gmad" "$TOOLS/libsteam_api.so" "$HOST:sdk/gmod-tools/"
tar -C "$DESKTOP" -cf - "${items[@]}" \
    | "${SSH[@]}" "$HOST" "cd ~/GMod && rm -rf ${items[*]} && tar -xf - && chmod +x ~/sdk/gmod-tools/gmad"

# 5. Online, upload, offline (the offline half is in cleanup).
online=1
steam_mode 0
# The command goes in on stdin to bash, so the note's quoting (printf %q) never
# depends on the marionette's login shell.
{
    printf '%s' 'export XDG_RUNTIME_DIR=/run/user/$(id -u); cd ~/GMod/gmod-bmx && python3 tools/workshop_sync.py'
    printf ' %q' "${args[@]}"
    printf ' --yes\n'
} | "${SSH[@]}" "$HOST" bash -s
