#!/usr/bin/env bash
# Publish BMX Bike to the Steam Workshop as a NEW item, from a Linux PC with
# Garry's Mod installed. Run once; later releases use update.sh.
# Steam must be running and signed in as ConvexBurrito5.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GMP="${GMPUBLISH:-}"
for c in "$HOME/.steam/steam/steamapps/common/GarrysMod/bin/linux64/gmpublish_linux" \
         "$HOME/.local/share/Steam/steamapps/common/GarrysMod/bin/linux64/gmpublish_linux" \
         "$HOME/.steam/steam/steamapps/common/GarrysMod/bin/gmpublish_linux"; do
  [ -z "$GMP" ] && [ -x "$c" ] && GMP="$c"
done
[ -n "$GMP" ] || { echo "gmpublish not found; set GMPUBLISH=/path/to/gmpublish_linux" >&2; exit 1; }
cmd="${1:-create}"
if [ "$cmd" = create ]; then
  "$GMP" create -addon "$HERE/bmx.gma" -icon "$HERE/icon.jpg"
  echo; echo "Write down the Workshop ID above; updates need it:  ./publish.sh update <id> \"what changed\""
else
  "$GMP" update -addon "$HERE/bmx.gma" -id "$2" -changes "${3:-update}"
fi
