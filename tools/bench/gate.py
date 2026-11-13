#!/usr/bin/env python3
"""The GPU gate: judge one run of the real-client benchmarks against the budget.

tools/bench/gate.sh runs the benchmarks on the GPU client (tools/bench/sp.sh) and saves
each one's output in a directory; this reads that directory and says pass or fail.

    gate.py judge DIR [--baseline tools/bench/baseline.json] [--json OUT]
    gate.py baseline DIR > tools/bench/baseline.json     # record a run as the new baseline

What a run must hold (the budget, BUDGET below):

    camsweep.txt   every vehicle, every pass: no bad frame (the rider off the vehicle,
                   unposed, or the vehicle not drawn), every drawn rider posed, and the
                   longest riding frame under a 60 fps frame (16.7 ms)
    spawns.txt     every kind's first spawn: no frame over 16.7 ms
    spawns2.txt    the same in a fresh session: a kind fails only when both went over
    features.txt   every scene's fps no more than FPS_DROP below the baseline's, and the
                   server's ms/s no more than SERVER_RISE above it (plus a small floor: an
                   idle 0.7 ms/s doubling is noise, not a regression)
    riders.txt     (when present) N riders in view: fps no more than FPS_DROP below the
                   baseline's, no frame over RIDERS_MAX_MS
    lowfps.txt     (when present) the camera sweep held to 30 / 60 fps: no bad frame

Exit 0 pass, 1 a budget broken (each one listed), 2 a run missing or unreadable.
"""
import json
import os
import re
import sys

BUDGET = {
    "frame_ms": 16.7,        # a 60 fps frame
    "fps_drop": 0.15,        # a scene may be at most 15% slower than the baseline
    "server_rise": 0.25,     # the server's cost may rise at most 25%...
    "server_floor": 1.0,     # ...plus 1 ms/s
    "riders_max_ms": 33.4,   # many riders in view: no frame under 30 fps
}

CAM_VEH = re.compile(r"^== (\S+): .*riding ([\d.]+) ms median, p95 ([\d.]+), max ([\d.]+)")
CAM_ENGINE10 = re.compile(r"\| engine ten-minute frame ([\d.]+) ms \(not judged\)")
CAM_PASS = re.compile(r"^\s+pass (\d+) \(([^)]*)\): (\d+) frames, rider drawn (\d+), posed (\d+), "
                      r"vehicle drawn (\d+), bad (\d+)")
SPAWN = re.compile(r"^(\S+)\s+(\d+) frames \| median ([\d.]+) p95 ([\d.]+) max ([\d.]+) ms \| "
                   r">16\.7ms (\d+) >33ms (\d+)")
FEAT_CL = re.compile(r"^(.+?): (\d+) frames, ([\d.]+) fps \| frame ms median ([\d.]+) p95 ([\d.]+) "
                     r"p99 ([\d.]+) max ([\d.]+)")
FEAT_SV = re.compile(r"^(.+?)\s+server\s+([\d.]+) ms/s")
CLEARED = re.compile(r"^\(cleared before the first scene: (.*)\)$", re.M)


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return None


def parse_camsweep(text):
    """{vehicle: {riding_median, riding_p95, riding_max, passes: [{...}]}}"""
    out, cur = {}, None
    for line in text.splitlines():
        m = CAM_VEH.match(line)
        if m:
            cur = {"riding_median": float(m[2]), "riding_p95": float(m[3]), "riding_max": float(m[4]),
                   "passes": []}
            e = CAM_ENGINE10.search(line)
            if e:
                cur["engine10"] = float(e[1])
            out[m[1]] = cur
            continue
        m = CAM_PASS.match(line)
        if m and cur is not None:
            cur["passes"].append({"pass": int(m[1]), "view": m[2], "frames": int(m[3]),
                                  "rider_drawn": int(m[4]), "posed": int(m[5]),
                                  "vehicle_drawn": int(m[6]), "bad": int(m[7])})
    return out


def parse_spawns(text):
    out = {}
    for line in text.splitlines():
        m = SPAWN.match(line)
        if m:
            out[m[1]] = {"frames": int(m[2]), "median": float(m[3]), "p95": float(m[4]),
                         "max": float(m[5]), "over_16": int(m[6]), "over_33": int(m[7])}
    return out


def parse_features(text):
    """{scene: {fps, p95, max, server}}: the client lines and the server lines, joined."""
    out = {}
    for line in text.splitlines():
        if line.startswith(" "):
            continue
        m = FEAT_SV.match(line)
        if m:
            out.setdefault(m[1].strip(), {})["server"] = float(m[2])
            continue
        m = FEAT_CL.match(line)
        if m:
            row = out.setdefault(m[1].strip(), {})
            row.update({"frames": int(m[2]), "fps": float(m[3]), "median": float(m[4]),
                        "p95": float(m[5]), "p99": float(m[6]), "max": float(m[7])})
    return out


def load_run(d):
    run = {}
    for name, parse in (("camsweep", parse_camsweep), ("spawns", parse_spawns), ("spawns2", parse_spawns),
                        ("features", parse_features), ("riders", parse_features),
                        ("lowfps", parse_camsweep)):
        text = read(os.path.join(d, name + ".txt"))
        if text is not None:
            run[name] = parse(text)
            # features_sv.lua clears what an earlier bench left in the world, and says so:
            # its scenes are then clean, but the bench that leaked is a bug to fix.
            m = CLEARED.search(text) if name == "features" else None
            if m:
                run["features_cleared"] = m[1]
    return run


def judge(run, baseline, budget=BUDGET):
    """A list of (check, ok, detail) rows; every row with ok False is a broken budget."""
    rows = []
    B = budget

    def check(name, ok, detail):
        rows.append((name, bool(ok), detail))

    for need in ("camsweep", "spawns", "features"):
        check(f"{need}: ran", run.get(need), "results present" if run.get(need) else "no results")

    for key, listed in (("camsweep", "camsweep_vehicles"), ("spawns", "spawn_kinds")):
        want = set((baseline or {}).get(listed) or [])
        got = set(run.get(key) or {})
        if run.get(key) and want - got:
            check(f"{key}: every one in the baseline ran", False, "missing: " + ", ".join(sorted(want - got)))

    for key in ("camsweep", "lowfps"):
        for veh, v in sorted((run.get(key) or {}).items()):
            if not v["passes"]:
                check(f"{key} {veh}: passes", False, "no pass lines")
            for p in v["passes"]:
                check(f"{key} {veh} pass {p['pass']}: no bad frame", p["bad"] == 0, f"bad {p['bad']}")
                # a worn vehicle (the skates) has no entity to draw: its legs are posed by
                # cl_skates.lua, which this count does not see, and `bad` judges it instead
                if p["vehicle_drawn"] > 0:
                    check(f"{key} {veh} pass {p['pass']}: every drawn rider posed",
                          p["posed"] == p["rider_drawn"], f"{p['posed']} of {p['rider_drawn']}")
            if key == "camsweep":
                check(f"camsweep {veh}: longest riding frame", v["riding_max"] < B["frame_ms"],
                      f"{v['riding_max']:.1f} ms (budget {B['frame_ms']})")
                if v.get("engine10"):
                    # reported, not failed: the owner's call, 2026-11-12 (see camsweep_cl.lua)
                    check(f"camsweep {veh}: the engine's ten-minute frame (reported, not judged)", True,
                          f"{v['engine10']:.1f} ms")

    # BEST OF TWO (spawns2.txt, a second fresh session, when it ran): a kind fails only when
    # both of its first rides went over -- one frame's spread is a different kind each run.
    second = run.get("spawns2") or {}
    for kind, s in sorted((run.get("spawns") or {}).items()):
        s2 = second.get(kind)
        ok = s["over_16"] == 0 or (s2 is not None and s2["over_16"] == 0)
        detail = f"{s['over_16']} frames over, worst {s['max']:.1f} ms"
        if s2 is not None:
            detail += f"; second session {s2['over_16']} over, worst {s2['max']:.1f} ms"
        check(f"spawn {kind}: no frame over {B['frame_ms']} ms", ok, detail)

    if run.get("features") is not None:
        left = run.get("features_cleared")
        check("benches before features left the world clean", not left,
              "nothing left" if not left else "left behind: " + left)

    for key in ("features", "riders"):
        base = (baseline or {}).get(key) or {}
        for scene, f in sorted((run.get(key) or {}).items()):
            b = base.get(scene)
            if "fps" in f and b and "fps" in b:
                floor = b["fps"] * (1 - B["fps_drop"])
                check(f"{key} '{scene}': fps", f["fps"] >= floor,
                      f"{f['fps']:.1f} (baseline {b['fps']:.1f}, floor {floor:.1f})")
            if "server" in f and b and "server" in b:
                ceil = b["server"] * (1 + B["server_rise"]) + B["server_floor"]
                check(f"{key} '{scene}': server ms/s", f["server"] <= ceil,
                      f"{f['server']:.2f} (baseline {b['server']:.2f}, ceiling {ceil:.2f})")
            if key == "riders" and "max" in f:
                check(f"riders '{scene}': longest frame", f["max"] < B["riders_max_ms"],
                      f"{f['max']:.1f} ms (budget {B['riders_max_ms']})")
        missing = sorted(set(base) - set(run.get(key) or {}))
        if run.get(key) is not None and missing:
            check(f"{key}: every baseline scene ran", False, "missing: " + ", ".join(missing))
    return rows


def main(argv):
    if len(argv) < 3 or argv[1] not in ("judge", "baseline"):
        print(__doc__)
        return 2
    d = argv[2]
    run = load_run(d)
    if argv[1] == "baseline":
        base = {k: run[k] for k in ("features", "riders") if k in run}
        # what must have run: every vehicle the sweep rode, every kind first-spawned
        if run.get("camsweep"):
            base["camsweep_vehicles"] = sorted(run["camsweep"])
        if run.get("spawns"):
            base["spawn_kinds"] = sorted(run["spawns"])
        json.dump(base, sys.stdout, indent=1, sort_keys=True)
        print()
        return 0
    bpath = os.path.join(os.path.dirname(os.path.abspath(__file__)), "baseline.json")
    out = None
    i = 3
    while i < len(argv):
        if argv[i] == "--baseline":
            bpath = argv[i + 1]
            i += 2
        elif argv[i] == "--json":
            out = argv[i + 1]
            i += 2
        else:
            i += 1
    baseline = json.loads(read(bpath) or "{}")
    rows = judge(run, baseline)
    broken = [r for r in rows if not r[1]]
    for name, ok, detail in rows:
        if not ok:
            print(f"FAIL {name}: {detail}")
    print(f"{len(rows) - len(broken)} of {len(rows)} budget checks held")
    if out:
        with open(out, "w", encoding="utf-8") as fh:
            json.dump({"run": run, "checks": [{"check": n, "ok": o, "detail": d} for n, o, d in rows],
                       "pass": not broken}, fh, indent=1)
    if not any(run.get(k) for k in ("camsweep", "spawns", "features")):
        return 2
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
