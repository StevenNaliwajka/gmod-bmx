#!/usr/bin/env bash
# The fast gate, run by the shared pipeline's `validate` stage on EVERY branch.
#
# It parses every Lua file and nothing more. That is worth its own stage because
# a GLua syntax error does not fail loudly -- it stops the whole addon loading,
# silently, and the server then reports itself perfectly healthy. Catching that
# here costs two seconds; catching it on the box costs a deploy, a restart and a
# confused minute wondering why the bike is gone.
#
# The HEADLESS simulation suite is NOT here. It needs a running Garry's Mod
# server, so it runs after deploy in the `headless` stage -- see .gitlab-ci.yml.
set -euo pipefail

echo "▶ lua syntax"
# No LUAC= here on purpose: syntax-check.sh finds luac5.1, then luac, then falls
# back to Docker. Forcing a name turns "no Lua front end on this machine" into a
# parse failure on every file, which is a much worse thing to read.
./tools/syntax-check.sh

echo "▶ offline suite"
# The real addon files, EXECUTED in a stock Lua 5.1 against the GMod shim in
# tests/lib/gmod.lua: the client half, the usercmd decode, the wire format
# between the realms, the config's own derivations and a closed-loop ride on a
# rigid-body plant. About ten seconds, and it needs no game server, so it gates
# every branch before the headless stage borrows the real one.
./tools/run-tests.sh

echo "▶ workshop kit"
# The upload scripts, driven against a fake gmpublish: the real one only ever
# runs on the publisher's PC, at the moment an update reaches subscribers.
./tools/test-workshop.sh

echo "▶ bmx-test keeps a wedged run's console"
bash tools/server/test-bmx-test-evidence.sh
echo "▶ shell syntax"
for f in install.sh ci-test.sh tools/*.sh tools/server/*.sh tools/server/bmx-test; do
  [ -f "$f" ] || continue
  bash -n "$f" && echo "  ok $f"
done

echo "▶ python syntax"
python3 -m py_compile tools/gmad.py tools/make_icon.py tools/server/rcon.py
echo "  ok tools/"
