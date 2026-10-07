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
# THE FIRST LINES ARE THE PITCH. A browser sees only the start of the description,
# and what we have that Rideable Bicycles does not is grinds and combos (G29), so
# the first 200 characters must say both. Also the title: "BMX Bike" with
# "BMX bike attempt in gmod" was the page that got 72 subscribers.
DESC200="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["description"][:200].lower())' "$ROOT/addon.json")"
ok '[[ "$DESC200" == *grind* ]]' "the first 200 characters of the description mention grinds"
ok '[[ "$DESC200" == *combo* ]]' "and combos"
ok '! grep -qi "attempt" "$ROOT/addon.json"' "the description does not call it an attempt"
TITLE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["title"])' "$ROOT/addon.json")"
ok '[ "$TITLE" = "BMX" ]' "the title is plain BMX, the owner's call ($TITLE)"
ok '[ "${#TITLE}" -le 128 ]' "the title fits Steam's 128 characters"

# THE CONTROLS SECTION MATCHES THE INPUT CODE. Every key sv_input.lua reads has
# its line in the description, so documentation that is already wrong cannot ship.
declare -A KEYLINE=( [IN_FORWARD]="W / S" [IN_BACK]="W / S" [IN_MOVELEFT]="A / D" [IN_MOVERIGHT]="A / D"
                     [IN_ATTACK2]="Right mouse" [IN_ATTACK]="Left mouse" [IN_JUMP]="SPACE"
                     [IN_SPEED]="SHIFT" [IN_DUCK]="CTRL" [IN_RELOAD]="R  " [IN_WALK]="ALT" )
CONTROLS="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["description"]; print(d.split("CONTROLS",1)[1].split("SERVER OWNERS",1)[0])' "$ROOT/addon.json")"
for key in $(grep -o 'IN_[A-Z0-9]*' "$ROOT/lua/bmx/sv_input.lua" | sort -u); do
  line="${KEYLINE[$key]:-}"
  ok '[ -n "$line" ] && grep -qF -- "$line" <<<"$CONTROLS"' "the description's controls cover $key (${line:-UNMAPPED: add it to this test})"
done

for name in "BMX Cruiser" "Mini BMX" "Combos" "bmx_max_per_player" "bmx_scoring" "bmx_combos" "bmx_stick_deadzone"; do
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
# The addon is its Lua and the spawn-menu pictures (materials/entities, one per Q-menu
# entry: tests/test_spawn_icons.lua), and nothing else.
want="$(cd "$ROOT" && git ls-files lua materials/entities | tr 'A-Z' 'a-z' | sort)"
got="$(grep -v '^addon.json$' "$TMP/gma.txt" | sort)"
ok '[ "$want" = "$got" ]' "the .gma holds exactly the addon's lua files and spawn icons ($(echo "$got" | wc -l))"
ok 'grep -q "^lua/bmx/sv_rules.lua$" "$TMP/gma.txt"' "including the new server settings"
ok 'grep -q "^materials/entities/bmx_base.png$" "$TMP/gma.txt"' "including the spawn-menu pictures"
ok '! grep -qvE "^(lua/|materials/entities/[a-z0-9_]+\.png$|addon\.json$)" "$TMP/gma.txt"' "and nothing else (tests, tools, docs stay out)"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
