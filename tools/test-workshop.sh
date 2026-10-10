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

# THE PAGE TEXT IS ONE TEXT. workshop/description.bbcode is the Workshop page
# (the owner's copy); addon.json's description carries it verbatim, because the
# release step pastes it from there and the .gma embeds it. Two copies that
# drift would put the wrong page on Steam.
ok 'python3 -c "import json,sys; d=json.load(open(sys.argv[1]))[\"description\"]; sys.exit(0 if d.strip() == open(sys.argv[2]).read().strip() else 1)" "$ROOT/addon.json" "$ROOT/workshop/description.bbcode"' \
   "addon.json's description is workshop/description.bbcode, word for word"
# Players report bugs and ideas on the public GitHub copy (Issues on), so the
# page links it.
ok 'grep -qF "[url=https://github.com/StevenNaliwajka/gmod-bmx/issues]" "$ROOT/workshop/description.bbcode"' \
   "the Workshop page links the GitHub issues"
ok 'grep -q "workshop/description.bbcode" "$ROOT/tools/package-workshop.sh"' "the kit ships the page text, ready to paste"
# THE GALLERY. Every picture in workshop/gallery/ goes on the page in file-name
# order (tools/workshop_sync.py), and Steam refuses a preview of 1 MB or more.
for g in "$ROOT"/workshop/gallery/*; do
  n="$(basename "$g")"
  ok '[[ "$n" =~ ^[0-9][0-9]-[a-z0-9-]+\.(jpg|png|gif)$ ]]' "gallery $n is numbered and a JPEG, PNG or GIF"
  ok '[ "$(wc -c < "$g")" -lt 1048576 ]' "gallery $n is under 1 MB"
done

# STEAM'S TABLES. Steam turns every line break inside a [table] into an empty
# row, so a table goes on one line; a key written as a bare [ or ] reads as a
# tag and breaks its row (and [noparse] round one does not close: it swallowed
# the rest of the table on the live page, 2026-10-07), so a key is named in
# words; and the table has a header.
ok 'python3 -c "
import re,sys
s=open(sys.argv[1]).read()
ts=re.findall(r\"\[table[^\]]*\]([\s\S]*?)\[/table\]\", s)
ok=bool(ts)
for t in ts:
    ok = ok and \"\n\" not in t and t.startswith(\"[tr][th]\")
    plain = re.sub(r\"\[/?(tr|td|th|b|i|u)\]\", \"\", t)
    ok = ok and \"[\" not in plain and \"]\" not in plain
sys.exit(0 if ok else 1)" "$ROOT/workshop/description.bbcode"' \
   "the Controls table is one line, with a header, and no [ ] or [noparse] in a cell (Steam renders it cleanly)"

# THE CONTROLS TABLE MATCHES THE INPUT CODE. Every key sv_input.lua reads has its
# row in the page's Controls table, so documentation that is already wrong cannot ship.
declare -A KEYLINE=( [IN_FORWARD]="W / S" [IN_BACK]="W / S" [IN_MOVELEFT]="A / D" [IN_MOVERIGHT]="A / D"
                     [IN_ATTACK2]="Right mouse" [IN_ATTACK]="Left mouse" [IN_JUMP]="[td]SPACE"
                     [IN_SPEED]="SHIFT" [IN_DUCK]="CTRL" [IN_RELOAD]="[td]R[/td]" [IN_WALK]="[td]ALT" )
CONTROLS="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["description"]; print(d.split("[h2]Controls[/h2]",1)[1])' "$ROOT/addon.json")"
ok '[ -n "$CONTROLS" ]' "the description has a Controls table"
for key in $(grep -o 'IN_[A-Z0-9]*' "$ROOT/lua/bmx/sv_input.lua" | sort -u); do
  line="${KEYLINE[$key]:-}"
  ok '[ -n "$line" ] && grep -qF -- "$line" <<<"$CONTROLS"' "the description's controls cover $key (${line:-UNMAPPED: add it to this test})"
done
# Auto ride is a key of its own (sh_autoride.lua, not sv_input.lua): O by default.
ok 'grep -qE "^A\.DEFAULT_KEY = 25 .*KEY_O" "$ROOT/lua/bmx/sh_autoride.lua" && grep -qF "[td]O[/td]" <<<"$CONTROLS"' \
   "the description's controls cover auto ride's default key (O)"

# What the released version has, named on the page (the 1.1.0 page was still
# up after 1.2.0 shipped). The server settings stay off it on purpose
# (f4180d2): README has those.
for name in "Cruiser" "Mini" "Road Bike" "Fixie" "City Bike" "Downhill" "Tandem" "Unicycle" "Penny-Farthing" \
            "skateboard" "kick scooter" "inline skates" "E-Bike" "E-Moto" "Dirt Bike" "Moped" \
            "Auto ride" "Bike rental" "Combos" "child seat" "Bike rack and lock" "bell" \
            "BMX (Mode)" "Petopia BMX Fall"; do
  ok 'grep -qF "$name" "$ROOT/workshop/description.bbcode"' "the Workshop description mentions $name"
done
for cv in bmx_max_per_player bmx_scoring bmx_combos bmx_stick_deadzone; do
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
# The addon is its Lua, the spawn-menu pictures (materials/entities, one per Q-menu
# entry: tests/test_spawn_icons.lua) and its own sounds (sound/bmx/*.wav, the bell
# and the horn, made by tools/sound/make_sounds.py), and nothing else.
want="$(cd "$ROOT" && git ls-files lua materials/entities 'sound/bmx/*.wav' | tr 'A-Z' 'a-z' | sort)"
got="$(grep -v '^addon.json$' "$TMP/gma.txt" | sort)"
ok '[ "$want" = "$got" ]' "the .gma holds exactly the addon's lua files, spawn icons and sounds ($(echo "$got" | wc -l))"
ok 'grep -q "^lua/bmx/sv_rules.lua$" "$TMP/gma.txt"' "including the new server settings"
ok 'grep -q "^materials/entities/bmx_base.png$" "$TMP/gma.txt"' "including the spawn-menu pictures"
ok 'grep -q "^sound/bmx/bell1.wav$" "$TMP/gma.txt"' "including the bell"
ok '! grep -qvE "^(lua/.+\.lua$|materials/entities/[a-z0-9_]+\.png$|sound/bmx/[a-z0-9_]+\.wav$|addon\.json$)" "$TMP/gma.txt"' \
   "and nothing else (tests, tools, docs, licence notes stay out)"

# EVERY ASSET THE CODE NAMES IS SHIPPED, OR IS THE BASE GAME'S. A sound, model or
# material path in lua/ is either packed in the .gma (a sound path is relative to
# sound/, a material's to materials/; "%d" with `variants = N` is every variant)
# or sits in a folder Garry's Mod itself ships, and is not one of ours. A path of
# ours that is not packed plays silence or draws an ERROR for every subscriber,
# and no server-side test can hear or see that.
python3 - "$ROOT" "$TMP/gma.txt" > "$TMP/assets.txt" <<'ASSETS'
import os, re, sys
root, gma = sys.argv[1], sys.argv[2]
packed = set(open(gma).read().split())
BASE = ("physics/", "vehicles/", "ambient/", "garrysmod/", "doors/", "ui/", "buttons/",
        "weapons/", "player/", "npc/", "items/", "common/", "plats/", "icon16/", "gui/",
        "models/hunter/", "models/props_", "models/xqm/", "models/nova/", "models/weapons/",
        "models/player/", "models/dav0r/", "models/maxofs2d/", "models/editor/")
pat = re.compile(r'"([A-Za-z0-9_./%-]+\.(?:wav|mp3|ogg|mdl|vmt|vtf|png|jpg))"')
var = re.compile(r'variants\s*=\s*(\d+)')
seen = 0
for dp, _, fns in sorted(os.walk(os.path.join(root, "lua"))):
    for fn in sorted(fns):
        if not fn.endswith(".lua"):
            continue
        f = os.path.join(dp, fn)
        for n, line in enumerate(open(f, encoding="utf-8"), 1):
            for ref in pat.findall(line):
                ref = ref.lower()
                seen += 1
                if ref.endswith((".wav", ".mp3", ".ogg")):
                    cand = "sound/" + ref
                elif ref.startswith("models/"):
                    cand = ref
                else:
                    cand = "materials/" + ref
                m = var.search(line)
                cands = [cand.replace("%d", str(i)) for i in range(1, (int(m.group(1)) if m else 1) + 1)] \
                        if "%d" in cand else [cand]
                if all(c in packed for c in cands):
                    print("ok", ref)
                elif ref.startswith(BASE) and "bmx" not in ref:
                    print("base", ref)
                else:
                    print("MISSING", ref, os.path.relpath(f, root) + ":" + str(n))
print("seen", seen)
ASSETS
SEEN="$(sed -n 's/^seen //p' "$TMP/assets.txt")"
ok '[ "${SEEN:-0}" -ge 20 ]' "the asset scan finds the code's sound and model paths (${SEEN:-none})"
ok 'grep -q "^ok bmx/bell%d.wav$" "$TMP/assets.txt" && grep -q "^ok bmx/horn%d.wav$" "$TMP/assets.txt"' \
   "the bell and horn the code plays are packed, every variant"
ok '! grep -q "^MISSING" "$TMP/assets.txt"' \
   "every sound, model and material the code names is in the .gma or the base game $(grep '^MISSING' "$TMP/assets.txt" | tr '\n' ' ')"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
