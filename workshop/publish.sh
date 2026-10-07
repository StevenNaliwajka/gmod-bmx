#!/usr/bin/env bash
# Upload BMX to the Steam Workshop from a Linux PC with Garry's Mod installed.
# Steam must be running and signed in as ConvexBurrito5.
#
#   ./publish.sh update "what changed"    new version of the live item (the usual)
#   ./publish.sh update <id> "what changed"  the same, to some other item
#   ./publish.sh create --new             a SECOND, separate item (almost never)
#
# The live item's ID ships next to this script in workshop-id.txt, so an update
# needs nothing typed. `create` refuses while that file exists: running it again
# makes a second item nobody is subscribed to.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GMP="${GMPUBLISH:-}"
for c in "$HOME/.steam/steam/steamapps/common/GarrysMod/bin/linux64/gmpublish_linux" \
         "$HOME/.local/share/Steam/steamapps/common/GarrysMod/bin/linux64/gmpublish_linux" \
         "$HOME/.steam/steam/steamapps/common/GarrysMod/bin/gmpublish_linux"; do
  [ -z "$GMP" ] && [ -x "$c" ] && GMP="$c"
done
[ -n "$GMP" ] || { echo "gmpublish not found; set GMPUBLISH=/path/to/gmpublish_linux" >&2; exit 1; }
WSID=""
[ -f "$HERE/workshop-id.txt" ] && WSID="$(tr -d '[:space:]' < "$HERE/workshop-id.txt")"
cmd="${1:-update}"
case "$cmd" in
  create)
    if [ -n "$WSID" ] && [ "${2:-}" != "--new" ]; then
      echo "BMX is already on the Workshop as item $WSID." >&2
      echo "Use: ./publish.sh update \"what changed\"   (or: create --new for a second item)" >&2
      exit 1
    fi
    "$GMP" create -addon "$HERE/bmx.gma" -icon "$HERE/icon.jpg"
    echo; echo "Write the new Workshop ID into workshop-id.txt; updates read it from there."
    ;;
  update)
    if [[ "${2:-}" =~ ^[0-9]+$ ]]; then WSID="$2"; shift; fi
    [ -n "$WSID" ] || { echo "no workshop-id.txt here; give the ID: ./publish.sh update <id> \"note\"" >&2; exit 1; }
    echo "Updating Workshop item $WSID"
    echo "  https://steamcommunity.com/sharedfiles/filedetails/?id=$WSID"
    "$GMP" update -addon "$HERE/bmx.gma" -id "$WSID" -changes "${2:-update}"
    ;;
  *) echo "usage: $0 update [\"what changed\"] | create --new" >&2; exit 2 ;;
esac
