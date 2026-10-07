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

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
