#!/usr/bin/env bash
# gate.sh's grant check against the broker's real answers (it exits 0 on a refusal).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
eval "$(sed -n '/^granted() {/,/^ *! grep.*<<<"\$out"; }$/p' "$HERE/gate.sh")"
type granted >/dev/null 2>&1 || { echo "FAIL: granted() not found in gate.sh"; exit 1; }
fail=0
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
check() {  # want, answer
  printf '%s\n' "$2" > "$TMP"
  CLAIM="cat $TMP"
  if granted >/dev/null; then got=yes; else got=no; fi
  [ "$got" = "$1" ] && echo "  ok   $3" || { echo "  FAIL $3 (got $got)"; fail=1; }
}
check no  '{"ok": false, "error": "refused: the GPU is in use ...", "holder": 110130, "busy": "revit.exe is running on it"}' "a refusal (Revit open) is not a grant"
check yes '{"ok": true, "card": "sen4-rtx2070", "holder": 119158, "detail": "VM 119158 already holds it"}' "already held is a grant"
check yes '{"ok": true, "card": "sen4-rtx2070", "queued": true, "from": 110130, "to": 119158}' "a queued handover is a grant"
check no  '{"job": "3e7f", "ok": true, "detail": {"ok": false, "error": "refused"}}' "the desktop relay's wrapper around a refusal is not a grant"
check yes '{"job": "3e7f", "ok": true, "detail": {"ok": true, "holder": 119158}}' "the relay's wrapper around a grant is"
check no  'cannot reach this machine'"'"'s broker' "no answer is not a grant"
exit $fail
