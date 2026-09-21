#!/usr/bin/env bash
# Install this addon's server-side test tooling onto the box it is checked out on.
#
#   sudo tools/server/install-server-tools.sh
#
# Run by install.sh on every deploy, so the runner on the box is always the one
# from the commit under test. That matters more than it sounds: the alternative
# is a copy installed by hand once, which then quietly tests new code with an
# old harness and disagrees with a fresh checkout for reasons nobody can see.
#
# What it does NOT install is the server itself -- the SteamCMD tree, the
# systemd unit, server.cfg and the RCON password are the host's business, not
# the addon's. On the naliwajka estate that lives in MGMT's
# Hosting/install-gmod-vm.sh; anywhere else, docs/TESTING.md describes it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${BIN_DIR:-/usr/local/bin}"
LIB="${LIB_DIR:-/usr/local/lib/gmod}"

install -d -m 0755 "$BIN" "$LIB"
install -m 0755 "$HERE/bmx-test" "$BIN/bmx-test"
install -m 0644 "$HERE/rcon.py"  "$LIB/rcon.py"

echo "  installed: $BIN/bmx-test, $LIB/rcon.py"
