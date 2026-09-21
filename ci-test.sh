#!/usr/bin/env bash
# The fast gate, run by the shared pipeline's `validate` stage on EVERY branch.
#
# It parses every Lua file and nothing more. That is worth its own stage because
# a GLua syntax error does not fail loudly -- it stops the whole addon loading,
# silently, and the server then reports itself perfectly healthy. Catching that
# here costs two seconds; catching it on the box costs a deploy, a restart and a
# confused minute wondering why the bike is gone.
#
# The headless simulation suite is NOT here. It needs a running Garry's Mod
# server, so it runs after deploy in the `headless` stage -- see .gitlab-ci.yml.
set -euo pipefail

echo "▶ lua syntax"
# No LUAC= here on purpose: syntax-check.sh finds luac5.1, then luac, then falls
# back to Docker. Forcing a name turns "no Lua front end on this machine" into a
# parse failure on every file, which is a much worse thing to read.
./tools/syntax-check.sh

echo "▶ shell syntax"
for f in install.sh ci-test.sh tools/*.sh tools/server/*.sh tools/server/bmx-test; do
  [ -f "$f" ] || continue
  bash -n "$f" && echo "  ok $f"
done

echo "▶ python syntax"
python3 -m py_compile tools/gmad.py tools/make_icon.py tools/server/rcon.py
echo "  ok tools/"
