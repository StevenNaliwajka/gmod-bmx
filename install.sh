#!/usr/bin/env bash
# Deploy entrypoint for the BMX addon. Run BY THE PIPELINE after it checks this
# repo out at the deployed commit, inside the Garry's Mod server's addons directory
# (APP_DIR = /opt/gmod/garrysmod/addons/gmod-bmx).
#
# The addon is Lua: there is nothing to build. What a deploy has to get right is
# ownership and the reload, and both are easy to get wrong quietly.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT="${GMOD_UNIT:-gmod}"
OWNER="${GMOD_USER:-gmod}"

# srcds runs as an unprivileged user; the checkout arrives owned by root, and Lua
# files it cannot read are not an error the server reports -- the addon simply does
# not load, and the server looks healthy while missing the thing just deployed.
if id "$OWNER" >/dev/null 2>&1; then
  chown -R "$OWNER":"$OWNER" "$HERE"
  # AND ITS PARENT. addons/ was left drwx------ root:root by a rebuild in August
  # 2026, so the gmod user could not traverse into it; this script chowned the
  # checkout inside it, reported "owner: gmod", and the addon still did not load
  # for three weeks. The server was healthy the whole time -- that is the point.
  chmod 0755 "$HERE" "$(dirname "$HERE")"
  echo "  owner: $OWNER (checkout and addons/)"
else
  echo "  WARNING: user '$OWNER' does not exist -- leaving ownership alone."
  echo "  This guest is not a provisioned Garry's Mod server; the addon is checked"
  echo "  out but nothing will load it."
fi

# The server-side test tooling travels with the commit. Installing it here rather
# than once by hand is what stops a new suite being run by an old harness -- the
# two then disagree and nothing on the box says why.
if [ -x "$HERE/tools/server/install-server-tools.sh" ]; then
  "$HERE/tools/server/install-server-tools.sh" || echo "  WARNING: server tooling not installed"
fi

# RESTART ONLY IF IT IS ALREADY RUNNING. Garry's Mod loads addons at startup, so a
# reload is the only way to pick this up -- and it disconnects whoever is playing.
# On a guest where the server is not running (a twin that has not been cut over),
# starting it here would silently bring up a SECOND server against the same
# workshop content and player base.
if systemctl is-active --quiet "$UNIT"; then
  echo "  restarting $UNIT (this disconnects players -- addons load at startup)"
  systemctl restart "$UNIT"
  sleep 3
  systemctl is-active --quiet "$UNIT" && echo "  $UNIT is back up"
else
  echo "  $UNIT is not running here -- deployed the files, started nothing."
fi
