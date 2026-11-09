#!/usr/bin/env bash
# Drive a SINGLEPLAYER session on a test client (the gmod-marionette VM by default): the
# setup most players report from, every Workshop subscription mounted, no Steam login
# needed. The addon under test goes in as a legacy addon folder and the Workshop copy of
# BMX is moved aside while it runs (put back by `restore`). BMX_SP_CLEAN=1 (the default)
# moves EVERY Workshop subscription aside: the client is 32-bit, and a singleplayer
# session (server and client in one process) with a few hundred addons runs it out of
# memory ("Out of memory", 2026-11-08, 236 mounted). What is measured is this addon alone.
#
#   tools/bench/sp.sh install [REF]   this working tree's addon (or REF's) + the control addon + the sweep scripts
#   tools/bench/sp.sh launch [map]    start singleplayer (gm_flatgrass, sandbox)
#   tools/bench/sp.sh cmd 'LINE'      a console command in the session ("lua <code>" runs Lua)
#   tools/bench/sp.sh camsweep [passes] [ids]   the camera sweep (tools/ride/camsweep_*), results printed
#   tools/bench/sp.sh parked [TAG]   8 parked vehicles in view: frame times + a line profile
#   tools/bench/sp.sh spawns [IDS]    the first-spawn hitch: each kind spawned once, every frame logged
#                                     (SPAWN_INTENT=1.5 pointed at in the menu first; SPAWN_RIDE=true ridden)
#   tools/bench/sp.sh features       every feature in its own scene, client and server cost (~6 min)
#   tools/bench/sp.sh probe           the real-client cost probe (tools/bench/realprobe_*)
#   tools/bench/sp.sh shots DIR       copy the camera sweep's pictures here
#   tools/bench/sp.sh riders [N]      N bot riders (8) in view, then behind the camera: client + server cost
#                                     (needs a session launched with BMX_SP_MAXPLAYERS > N: a listen server)
#   tools/bench/sp.sh lowfps [FPS] [passes]   the camera sweep with the game held to FPS (30), a weak PC
#   tools/bench/sp.sh ready           wait for the client VM to answer ssh and its Steam to be up
#   tools/bench/sp.sh restore         quit, remove what install added, put the Workshop copy back
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CL="${BMX_SP_CLIENT:-marionette@10.9.1.58}"
G="${BMX_SP_GMOD:-/home/marionette/.steam/debian-installation/steamapps/common/GarrysMod/garrysmod}"
WS="${BMX_SP_WORKSHOP:-/home/marionette/.steam/debian-installation/steamapps/workshop/content/4000}"
BMX_WS=3814420080
r() { ssh -o BatchMode=yes "$CL" "$@"; }
cmd() { printf '%s\n' "$1" | r "cat >> $G/data/probe/cmd.txt"; }
# THE WINDOW MUST HAVE FOCUS: an unfocused game is held to 20 fps whatever it draws (no
# window manager on the virtual display, so nothing ever focuses it; 2026-11-08: 20.0 fps
# unfocused, 291 focused, same scene).
focus() { r 'export DISPLAY=:1; w=$(xdotool search --name "Garry" | head -1); [ -n "$w" ] && xdotool windowfocus "$w"; true'; }
waitfile() { for _ in $(seq 1 "${2:-600}"); do r "grep -q DONE $G/data/$1 2>/dev/null" && return 0; sleep 2; done; return 1; }
case "${1:-}" in
  ready)
    # After the VM boots: ssh, then Steam's web helper (Steam signed in), then a settle. A
    # game launched before Steam is up hangs on "Failed to initialize Steamworks API".
    for _ in $(seq 1 90); do r true 2>/dev/null && break; sleep 5; done
    r true || { echo "no ssh to $CL"; exit 1; }
    for _ in $(seq 1 60); do r 'pgrep -f steamwebhelper >/dev/null' && break; sleep 5; done
    r 'pgrep -f steamwebhelper >/dev/null' || { r 'systemctl --user start steam' || true; sleep 60; }
    sleep "${BMX_SP_SETTLE:-45}"; echo ready ;;
  install)
    r "mkdir -p $G/data/probe; rm -rf $G/addons/gmod-bmx-dev $G/addons/bmxprobe; [ -d $WS/$BMX_WS ] && mv $WS/$BMX_WS $WS/.$BMX_WS.aside || true"
    if [ "${BMX_SP_CLEAN:-1}" = 1 ]; then r "[ -d $WS ] && [ ! -e $WS.clean-aside ] && mv $WS $WS.clean-aside && mkdir -p $WS; true"; fi
    # install [REF]: a commit's addon (git archive), or this working tree's by default.
    if [ -n "${2:-}" ]; then
      (cd "$ROOT" && git archive "$2" addon.json lua materials sound) | r "mkdir -p $G/addons/gmod-bmx-dev && tar xf - -C $G/addons/gmod-bmx-dev"
    else
      (cd "$ROOT" && tar cf - addon.json lua materials models sound 2>/dev/null) | r "mkdir -p $G/addons/gmod-bmx-dev && tar xf - -C $G/addons/gmod-bmx-dev"
    fi
    (cd "$HERE/probe_addon" && tar cf - .) | r "mkdir -p $G/addons/bmxprobe && tar xf - -C $G/addons/bmxprobe"
    for f in "$ROOT/tools/ride/camsweep_sv.lua" "$ROOT/tools/bench/realprobe_sv.lua"; do scp -q "$f" "$CL:$G/addons/bmxprobe/lua/$(basename "$f")"; done
    scp -q "$ROOT/tools/ride/camsweep_cl.lua" "$CL:$G/data/camsweep_cl.txt"
    scp -q "$ROOT/tools/bench/realprobe_cl.lua" "$CL:$G/data/realprobe_cl.txt"
    echo "installed ${2:-$(cd "$ROOT" && git describe --always --dirty)}" ;;
  launch)
    # An unfocused window sleeps engine_no_focus_sleep (50 ms) a frame: exactly 20 fps on a
    # virtual display whatever the scene costs, which hides every frame time (2026-11-08).
    r "for l in 'engine_no_focus_sleep 0' 'fps_max 300' 'mat_vsync 0'; do grep -qxF \"\$l\" $G/cfg/autoexec.cfg || echo \"\$l\" >> $G/cfg/autoexec.cfg; done"
    # (the old game gone before its log is cleared: a dying session wrote "player ready")
    r "pkill -f GarrysMod/hl2_linu[x]; sleep 2; pkill -9 -f GarrysMod/hl2_linu[x]; while pgrep -f GarrysMod/hl2_linu[x] >/dev/null; do sleep 1; done; rm -f $G/data/probe/cmd.txt $G/data/probe/log.txt; true"
    # -f -n: the game keeps the session's channel open, so a plain ssh never came back
    ssh -f -n -o BatchMode=yes "$CL" "cd $G/.. && export DISPLAY=:1 SteamAppId=4000 SteamGameId=4000 __GL_SYNC_TO_VBLANK=0 vblank_mode=0 && setsid ~/.steam/steam/ubuntu12_32/steam-runtime/run.sh ./hl2.sh -game garrysmod -windowed -noborder -w 1280 -h 960 -novid -nojoy -condebug +gamemode sandbox +maxplayers ${BMX_SP_MAXPLAYERS:-1} $([ "${BMX_SP_MAXPLAYERS:-1}" -gt 1 ] && echo "+sv_lan 1") +map ${2:-gm_flatgrass} >/tmp/gmod-sp.log 2>&1 </dev/null & disown"; echo launched
    for _ in $(seq 1 150); do r "grep -q 'player ready' $G/data/probe/log.txt 2>/dev/null" && { focus; echo "session up"; exit 0; }; sleep 2; done
    echo "no session after 5 min"; exit 1 ;;
  cmd) cmd "$2" ;;
  blocker)
    # on|off: another addon's PrePlayerDraw returning false, ahead of BMX's (probe_addon/lua/blocker_cl.txt)
    if [ "${2:-on}" = on ]; then
      scp -q "$HERE/probe_addon/lua/blocker_cl.txt" "$CL:$G/data/blocker_cl.txt"
      cmd 'lua BroadcastLua([[RunString(file.Read("blocker_cl.txt","DATA"),"blocker")]])'
      sleep 2; r "cat $G/data/probe/blocker.txt"
    else
      cmd 'lua BroadcastLua([[if BLOCKER_NAME then hook.Remove("PrePlayerDraw", BLOCKER_NAME) end]])'
    fi ;;
  focus) focus ;;
  camsweep)
    focus
    r "rm -rf $G/data/camsweep"
    cmd "lua include(\"camsweep_sv.lua\")"; sleep 1; cmd "camsweep_owner *"; cmd "camsweep_push"; sleep 3
    cmd "camsweep_run ${2:-4} $(echo "${3:-}" | tr , " ")"
    waitfile camsweep/result.txt 900 || echo "(timed out)"
    r "cat $G/data/camsweep/result.txt" ;;
  probe)
    focus
    r "rm -rf $G/data/realprobe"
    cmd "lua include(\"realprobe_sv.lua\")"; sleep 1; cmd "realprobe_owner *"; cmd "realprobe_push"; sleep 4
    cmd "realprobe_run"
    waitfile realprobe/result.txt 200 || echo "(timed out)"
    r "cat $G/data/realprobe/result.txt" ;;
  parked)
    # 8 parked vehicles of mixed kinds in view (probe_addon/lua/parked_sv.lua), their models
    # built; 6 s timed (frame times + the addon's hooks), then 8 s profiled (lines).
    focus
    T="${2:-parked}"
    r "rm -f $G/data/probe/$T.txt"
    cmd 'lua include("parked_sv.lua")'
    cmd 'lua BroadcastLua([[RunString(file.Read("realprobe_cl.txt","DATA"),"realprobe")]])'
    sleep 15; focus
    cmd "lua BroadcastLua([[REALPROBE.Measure(\"$T\", 6, function(s) file.Write(\"probe/$T.txt\", s) REALPROBE.Profile(8, function(p) file.Append(\"probe/$T.txt\", \"\\n\" .. p) end) end)]])"
    for _ in $(seq 1 30); do r "grep -q profile: $G/data/probe/$T.txt 2>/dev/null" && break; sleep 2; done
    r "cat $G/data/probe/$T.txt" ;;
  spawns)
    # each kind spawned once (a first spawn: its model is built), every frame for 5 s after
    focus
    r "rm -f $G/data/probe/spawns.txt"
    scp -q "$HERE/probe_addon/lua/spawnprobe_cl.txt" "$CL:$G/data/spawnprobe_cl.txt"
    [ -n "${2:-}" ] && cmd "lua SPAWNPROBE_IDS = string.Explode(\",\", \"$2\")"
    cmd "lua SPAWNPROBE_INTENT = ${SPAWN_INTENT:-0}"
    cmd "lua SPAWNPROBE_RIDE = ${SPAWN_RIDE:-false}"
    cmd 'lua include("spawnprobe_sv.lua")'
    for _ in $(seq 1 80); do r "grep -q DONE $G/data/probe/spawns.txt 2>/dev/null" && break; sleep 3; done
    r "cat $G/data/probe/spawns.txt" ;;
  features)
    # every feature, one scene each (probe_addon/lua/features_sv.lua): client and server cost
    focus
    r "rm -f $G/data/probe/features_cl.txt $G/data/probe/features_sv.txt"
    cmd 'lua BroadcastLua([[RunString(file.Read("realprobe_cl.txt","DATA"),"realprobe")]])'
    sleep 2
    cmd 'lua include("features_sv.lua")'
    for _ in $(seq 1 200); do r "grep -q DONE $G/data/probe/features_sv.txt 2>/dev/null" && break; sleep 5; done
    r "cat $G/data/probe/features_cl.txt; echo; cat $G/data/probe/features_sv.txt" ;;
  riders)
    # N bots riding circles in front of the player (probe_addon/lua/riders_sv.lua)
    focus
    r "rm -f $G/data/probe/riders.txt"
    scp -q "$HERE/probe_addon/lua/riders_sv.lua" "$CL:$G/addons/bmxprobe/lua/riders_sv.lua"
    cmd 'lua BroadcastLua([[RunString(file.Read("realprobe_cl.txt","DATA"),"realprobe")]])'
    sleep 2
    cmd "lua RIDERS_N = ${2:-8}"
    cmd 'lua include("riders_sv.lua")'
    for _ in $(seq 1 40); do r "grep -q DONE $G/data/probe/riders.txt 2>/dev/null" && break; sleep 3; done
    r "grep -v DONE $G/data/probe/riders.txt" ;;
  lowfps)
    # The camera sweep with the game held to FPS: what a weak PC draws. The rider's pose, the
    # carried targets and every smoothing must hold at a long frame as they do at a short one.
    cmd "fps_max ${2:-30}"; sleep 1
    "$0" camsweep "${3:-2}" "${4:-}"
    cmd "fps_max 300" ;;
  shots) mkdir -p "$2"; r "cd $G/data/camsweep && tar cf - *.jpg" | tar xf - -C "$2"; ls "$2" | wc -l ;;
  restore)
    r "pkill -f GarrysMod/hl2_linu[x]; sleep 2; pkill -9 -f GarrysMod/hl2_linu[x]; rm -rf $G/addons/gmod-bmx-dev $G/addons/bmxprobe $G/data/camsweep_cl.txt $G/data/realprobe_cl.txt; if [ -d $WS.clean-aside ]; then rmdir $WS 2>/dev/null; mv $WS.clean-aside $WS; fi; [ -d $WS/.$BMX_WS.aside ] && mv $WS/.$BMX_WS.aside $WS/$BMX_WS; true"
    echo restored ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
