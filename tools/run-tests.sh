#!/usr/bin/env bash
# Run the OFFLINE suite: the real addon files, executed in a stock Lua 5.1
# against the GMod shim in tests/lib/gmod.lua. No game, no server, no client.
#
#   tools/run-tests.sh            every test
#   tools/run-tests.sh balance    only tests whose file or name contains it
#
# Uses lua5.1 (or a lua that reports 5.1) if there is one, otherwise Docker,
# the same way tools/syntax-check.sh finds luac. Override with LUA=.
#
# This is the half of the testing story that needs nothing. The headless suite
# (bmx_test, lua/bmx/sv_test.lua) is the other half and needs a real Garry's Mod
# server; see docs/TESTING.md for which one covers what.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${LUA_IMAGE:-nickblah/lua:5.1-luarocks-alpine}"

LUA="${LUA:-}"
if [ -z "$LUA" ]; then
  for cand in lua5.1 lua; do
    if command -v "$cand" >/dev/null 2>&1 \
       && "$cand" -v 2>&1 | grep -q 'Lua 5\.1'; then
      LUA="$cand"; break
    fi
  done
fi

if [ -n "$LUA" ]; then
  cd "$ROOT" && exec "$LUA" tests/run.lua "$@"
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: no Lua 5.1 and no docker. Install lua5.1, or set LUA=." >&2
  exit 2
fi
exec docker run --rm -v "$ROOT:/w:ro" -w /w "$IMAGE" lua tests/run.lua "$@"
