#!/usr/bin/env bash
# Tests for the Workshop upload kit, against a FAKE gmpublish that records what
# it was asked to do. The real uploader only runs on the publisher's PC with
# Steam signed in, so the scripts that drive it are otherwise never executed
# before the moment they matter: an update to the live item.
#
#   tools/test-workshop.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { if eval "$1"; then pass=$((pass+1)); echo "  ok   $2"; else fail=$((fail+1)); echo "  FAIL $2"; fi; }

ID="$(tr -d '[:space:]' < "$ROOT/workshop/workshop-id.txt")"
ok '[[ "$ID" =~ ^[0-9]{6,}$ ]]' "workshop-id.txt holds a numeric Workshop ID ($ID)"
ok 'grep -q "Workshop ID: $ID" "$ROOT/docs/PUBLISHING.md"' "PUBLISHING.md records the same ID"
ok 'grep -q "filedetails/?id=$ID" "$ROOT/README.md"' "README links the live item"
ok 'grep -q "workshop/workshop-id.txt" "$ROOT/tools/package-workshop.sh"' "the kit ships the ID file"
for b in publish update; do
  ok 'grep -q "workshop-id.txt" "$ROOT/workshop/$b.bat"' "$b.bat reads workshop-id.txt"
  ok '[ "$(grep -c $'"'"'\r$'"'"' "$ROOT/workshop/$b.bat")" = "$(wc -l < "$ROOT/workshop/$b.bat")" ]' "$b.bat is CRLF throughout"
done
ok '! grep -q "set /p WSID=Workshop" <(grep -v "if not defined WSID" "$ROOT/workshop/update.bat")' \
   "update.bat only asks for an ID when the file is missing"

# A kit in a scratch folder, with a gmpublish that logs its arguments.
KIT="$TMP/kit"; mkdir -p "$KIT"
cp "$ROOT/workshop/publish.sh" "$ROOT/workshop/workshop-id.txt" "$KIT/"
: > "$KIT/bmx.gma"; : > "$KIT/icon.jpg"
cat > "$TMP/gmp" <<'G'
#!/usr/bin/env bash
echo "$@" >> "$GMP_LOG"
G
chmod +x "$TMP/gmp"
export GMPUBLISH="$TMP/gmp" GMP_LOG="$TMP/log"

run() { : > "$GMP_LOG"; bash "$KIT/publish.sh" "$@" > "$TMP/out" 2>&1; echo $? > "$TMP/rc"; }

run update "combos"
ok '[ "$(cat $TMP/rc)" = 0 ]' "update exits 0"
ok 'grep -q -- "update -addon $KIT/bmx.gma -id $ID -changes combos" "$GMP_LOG"' "update targets the live item, with the note"

run
ok 'grep -q -- "-id $ID -changes update" "$GMP_LOG"' "no arguments means update, not create"

run update 123456 "elsewhere"
ok 'grep -q -- "-id 123456 -changes elsewhere" "$GMP_LOG"' "an explicit ID still wins"

run create
ok '[ "$(cat $TMP/rc)" = 1 ]' "create refuses while the item exists"
ok '[ ! -s "$GMP_LOG" ]' "and never reaches gmpublish"
ok 'grep -q "already on the Workshop as item $ID" "$TMP/out"' "and says why"

run create --new
ok 'grep -q -- "^create -addon" "$GMP_LOG"' "create --new makes a second item on purpose"

run bogus
ok '[ "$(cat $TMP/rc)" = 2 ]' "an unknown command is a usage error"

rm "$KIT/workshop-id.txt"
run update "x"
ok '[ "$(cat $TMP/rc)" = 1 ] && [ ! -s "$GMP_LOG" ]' "no ID file and no ID: refuses rather than guessing"
run create
ok 'grep -q -- "^create -addon" "$GMP_LOG"' "no ID file: create is the first upload"

# ---------------------------------------------------------------------------
# The release itself: the version, the changelog and the packed addon.
# ---------------------------------------------------------------------------
VER="$(sed -n 's/^BMX.Version = "\(.*\)"/\1/p' "$ROOT/lua/autorun/bmx_init.lua")"
TOP="$(grep -m1 '^## ' "$ROOT/CHANGELOG.md" | sed 's/^## \([^ ]*\).*/\1/')"
ok '[ -n "$VER" ] && [ "$VER" = "$TOP" ]' "BMX.Version ($VER) is the top CHANGELOG entry ($TOP)"
ok '[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]' "the version is MAJOR.MINOR.PATCH"
ok 'python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$ROOT/addon.json"' "addon.json is valid JSON"
ok 'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if len(d[\"description\"]) < 8000 else 1)" "$ROOT/addon.json"' \
   "the Workshop description fits Steam's 8000 characters"
for name in "BMX Cruiser" "Mini BMX" "Combos" "bmx_max_per_player" "bmx_scoring" "bmx_combos"; do
  ok 'grep -q "$name" "$ROOT/addon.json"' "the Workshop description mentions $name"
done
for cv in bmx_max_per_player bmx_scoring bmx_combos; do
  ok 'grep -q "$cv" "$ROOT/README.md"' "README documents $cv"
done

python3 "$ROOT/tools/gmad.py" --root "$ROOT" -o "$TMP/bmx.gma" > /dev/null
ok '[ -s "$TMP/bmx.gma" ]' "the .gma packs"
python3 - "$TMP/bmx.gma" > "$TMP/gma.txt" <<'PY'
import struct, sys
b = open(sys.argv[1], "rb").read()
assert b[:4] == b"GMAD", "magic"
i = 4 + 1 + 8 + 8
while b[i] != 0:                      # required content, then its terminator
    i = b.index(b"\0", i) + 1
i += 1
for _ in range(3):                    # title, description, author
    i = b.index(b"\0", i) + 1
i += 4                                # addon version
while True:
    (n,) = struct.unpack_from("<I", b, i); i += 4
    if n == 0: break
    j = b.index(b"\0", i); print(b[i:j].decode()); i = j + 1
    i += 8 + 4                        # size, crc
PY
want="$(cd "$ROOT" && git ls-files lua | tr 'A-Z' 'a-z' | sort)"
got="$(grep -v '^addon.json$' "$TMP/gma.txt" | sort)"
ok '[ "$want" = "$got" ]' "the .gma holds exactly the addon's lua files ($(echo "$got" | wc -l))"
ok 'grep -q "^lua/bmx/sv_rules.lua$" "$TMP/gma.txt"' "including the new server settings"
ok '! grep -qvE "^(lua/|addon\.json$)" "$TMP/gma.txt"' "and nothing outside lua/ (tests, tools, docs stay out)"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
