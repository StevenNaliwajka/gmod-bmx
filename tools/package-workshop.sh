#!/usr/bin/env bash
# Build the Steam Workshop upload kit: dist/BMX-Workshop-<version>.zip
#
#   tools/package-workshop.sh
#
# The icon is redrawn, the .gma packed (tools/gmad.py, whitelist-safe: only
# lua/ and addon.json go in, see addon.json "ignore"), and both put in a folder
# with the upload scripts and a README for the account that publishes it. The
# upload itself (gmpublish) runs on the publisher's PC with Steam signed in,
# never here and never in CI: see docs/PUBLISHING.md.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
VERSION="$(sed -n 's/^BMX.Version = "\(.*\)"/\1/p' lua/autorun/bmx_init.lua)"
[ -n "$VERSION" ] || { echo "no BMX.Version in lua/autorun/bmx_init.lua" >&2; exit 1; }
OUT="dist/BMX-Workshop"
mkdir -p "$OUT"
rm -f "$OUT"/*
python3 tools/make_icon.py >/dev/null
python3 tools/gmad.py -o "$OUT/bmx.gma" >/dev/null
cp workshop/icon.jpg workshop/publish.bat workshop/update.bat \
   workshop/find-gmpublish.ps1 workshop/publish.sh "$OUT/"
sed "s/VERSION/$VERSION/" workshop/README.txt > "$OUT/README.txt"
( cd dist && rm -f "BMX-Workshop-$VERSION.zip" && python3 -m zipfile -c "BMX-Workshop-$VERSION.zip" BMX-Workshop )
echo "dist/BMX-Workshop-$VERSION.zip"
ls -la "$OUT"
