#!/usr/bin/env python3
"""Unit tests for tools/bench/gate.py: the parsers read the benchmarks' real output lines,
and the judge fails each budget it should and nothing else. Stdlib only (ci-test.sh)."""
import contextlib
import io
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gate  # noqa: E402

CAM = """== stock: frames on foot before 3.7 ms median | riding 3.5 ms median, p95 4.4, max 12.3 | pictures 78
  pass 1 (chase, pitch 12): 2143 frames, rider drawn 2143, posed 2143, vehicle drawn 2143, bad 0 (69 after a picture not judged) | limb miss median 0.1 p95 0.2 max 1.6 u
    p95 frame ms by stage: parked 4.8, pedal 4.4
  pass 4 (first, pitch 8): 3166 frames, rider drawn 1, posed 1, vehicle drawn 3166, bad 0 (9 after a picture not judged) | limb miss median 0.2 p95 0.2 max 0.2 u
== skates: frames on foot before 3.5 ms median | riding 3.5 ms median, p95 4.0, max 12.1 | pictures 19
  pass 1 (chase, pitch 12): 3157 frames, rider drawn 3157, posed 0, vehicle drawn 0, bad 0 (10 after a picture not judged) | limb miss median 0.0 p95 0.0 max 0.0 u
"""
SPAWNS = """stock       301 frames | median 3.50 p95 4.40 max 12.0 ms | >16.7ms 0 >33ms 0 | build 120 ms in all | collections 1 | frames with 2+ slices 0 | worst:
tandem      298 frames | median 3.50 p95 4.40 max 14.7 ms | >16.7ms 0 >33ms 0 | build 160 ms in all | collections 2 | frames with 2+ slices 0 | worst:
"""
FEAT = """idle: addon loaded, nothing spawned: 1743 frames, 290.5 fps | frame ms median 3.44 p95 3.73 p99 3.85 max 6.05 | addon Lua 0.04 ms/frame
    Think:BMX.Skates.Sparks                            0.005 ms/frame     1.0 calls/frame
riding stock: 1687 frames, 281.2 fps | frame ms median 3.47 p95 4.40 p99 5.73 max 10.24 | addon Lua 3.13 ms/frame

idle: addon loaded, nothing spawned server   0.70 ms/s | hook Think 0.5, hook StartCommand 0.2, hook Tick 0.0
riding stock                       server  11.86 ms/s | PhysicsSimulate 9.4, Think 1.0, hook Think 0.8
"""


def run_of(**texts):
    d = tempfile.mkdtemp()
    for name, text in texts.items():
        with open(os.path.join(d, name + ".txt"), "w") as fh:
            fh.write(text)
    return gate.load_run(d)


def failed(rows):
    return [n for n, ok, _ in rows if not ok]


class Parsers(unittest.TestCase):
    def test_camsweep(self):
        c = gate.parse_camsweep(CAM)
        self.assertEqual(set(c), {"stock", "skates"})
        self.assertEqual(c["stock"]["riding_max"], 12.3)
        self.assertEqual([p["pass"] for p in c["stock"]["passes"]], [1, 4])
        self.assertEqual(c["stock"]["passes"][0]["posed"], 2143)
        self.assertEqual(c["skates"]["passes"][0]["vehicle_drawn"], 0)

    def test_spawns(self):
        s = gate.parse_spawns(SPAWNS)
        self.assertEqual(s["tandem"]["max"], 14.7)
        self.assertEqual(s["stock"]["over_16"], 0)

    def test_features_joins_client_and_server_lines(self):
        f = gate.parse_features(FEAT)
        self.assertEqual(f["riding stock"]["fps"], 281.2)
        self.assertEqual(f["riding stock"]["server"], 11.86)
        self.assertEqual(f["idle: addon loaded, nothing spawned"]["server"], 0.70)
        self.assertNotIn("Think:BMX.Skates.Sparks", " ".join(f))


class Judge(unittest.TestCase):
    def setUp(self):
        self.run = run_of(camsweep=CAM, spawns=SPAWNS, features=FEAT)
        self.base = {"features": gate.parse_features(FEAT)}

    def test_a_clean_run_holds_every_budget(self):
        self.assertEqual(failed(gate.judge(self.run, self.base)), [])

    def test_a_bad_frame_fails(self):
        r = run_of(camsweep=CAM.replace("bad 0 (69", "bad 3 (69"), spawns=SPAWNS, features=FEAT)
        self.assertEqual(failed(gate.judge(r, self.base)), ["camsweep stock pass 1: no bad frame"])

    def test_an_unposed_rider_fails_but_worn_skates_do_not(self):
        r = run_of(camsweep=CAM.replace("posed 2143", "posed 2100"), spawns=SPAWNS, features=FEAT)
        self.assertEqual(failed(gate.judge(r, self.base)), ["camsweep stock pass 1: every drawn rider posed"])

    def test_a_long_riding_frame_fails(self):
        r = run_of(camsweep=CAM.replace("max 12.3", "max 17.0"), spawns=SPAWNS, features=FEAT)
        self.assertEqual(failed(gate.judge(r, self.base)), ["camsweep stock: longest riding frame"])

    def test_a_spawn_hitch_fails(self):
        r = run_of(camsweep=CAM, spawns=SPAWNS.replace(">16.7ms 0 >33ms 0 | build 160", ">16.7ms 1 >33ms 0 | build 160"),
                   features=FEAT)
        self.assertEqual(failed(gate.judge(r, self.base)), ["spawn tandem: no frame over 16.7 ms"])

    def test_fps_within_the_drop_holds_and_past_it_fails(self):
        ok = run_of(camsweep=CAM, spawns=SPAWNS, features=FEAT.replace("281.2 fps", "250.0 fps"))
        self.assertEqual(failed(gate.judge(ok, self.base)), [])
        bad = run_of(camsweep=CAM, spawns=SPAWNS, features=FEAT.replace("281.2 fps", "230.0 fps"))
        self.assertEqual(failed(gate.judge(bad, self.base)), ["features 'riding stock': fps"])

    def test_server_cost_rise_fails_past_the_ceiling_only(self):
        ok = run_of(camsweep=CAM, spawns=SPAWNS, features=FEAT.replace("0.70 ms/s", "1.60 ms/s"))
        self.assertEqual(failed(gate.judge(ok, self.base)), [], "an idle 0.7 -> 1.6 is under the floor")
        bad = run_of(camsweep=CAM, spawns=SPAWNS, features=FEAT.replace("11.86 ms/s", "17.00 ms/s"))
        self.assertEqual(failed(gate.judge(bad, self.base)), ["features 'riding stock': server ms/s"])

    def test_a_vehicle_left_by_an_earlier_bench_fails_and_is_named(self):
        # 2026-11-11, the first whole gate run: the spawn bench left its skateboard ridden
        # round its circle, and every features scene measured it too.
        dirty = FEAT.replace("\nidle: addon loaded, nothing spawned server",
                             "\n(cleared before the first scene: bmx_skateboard)\nidle: addon loaded, nothing spawned server")
        run = run_of(camsweep=CAM, spawns=SPAWNS, features=dirty)
        self.assertEqual(run["features"], gate.parse_features(FEAT), "the cleared line is not a scene")
        rows = gate.judge(run, self.base)
        self.assertEqual(failed(rows), ["benches before features left the world clean"])
        self.assertIn("bmx_skateboard", [d for n, ok, d in rows if not ok][0])
        self.assertEqual(failed(gate.judge(self.run, self.base)), [])

    def test_a_missing_benchmark_or_scene_fails(self):
        r = run_of(camsweep=CAM, features=FEAT)
        self.assertEqual(failed(gate.judge(r, self.base)), ["spawns: ran"])
        r = run_of(camsweep=CAM, spawns=SPAWNS, features=FEAT.split("riding stock:")[0])
        self.assertIn("features: every baseline scene ran", failed(gate.judge(r, self.base)))

    def test_a_vehicle_or_kind_missing_from_the_run_fails(self):
        base = dict(self.base, camsweep_vehicles=["skates", "stock", "tandem"], spawn_kinds=["stock", "tandem"])
        self.assertEqual(failed(gate.judge(self.run, base)), ["camsweep: every one in the baseline ran"])
        r = run_of(camsweep=CAM, spawns=SPAWNS.split("tandem")[0], features=FEAT)
        base = dict(self.base, spawn_kinds=["stock", "tandem"])
        self.assertEqual(failed(gate.judge(r, base)), ["spawns: every one in the baseline ran"])

    def test_riders_and_lowfps_are_judged_when_present(self):
        riders = "8 riders in view: 900 frames, 150.0 fps | frame ms median 6.0 p95 8.0 p99 9.0 max 40.0 | addon Lua 5 ms/frame\n"
        r = run_of(camsweep=CAM, spawns=SPAWNS, features=FEAT, riders=riders,
                   lowfps=CAM.replace("bad 0 (9", "bad 2 (9"))
        base = dict(self.base, riders=gate.parse_features(riders.replace("150.0", "200.0")))
        self.assertEqual(sorted(failed(gate.judge(r, base))),
                         ["lowfps stock pass 4: no bad frame", "riders '8 riders in view': fps",
                          "riders '8 riders in view': longest frame"])

    def test_exit_codes(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self._exit_codes()

    def _exit_codes(self):
        d = tempfile.mkdtemp()
        self.assertEqual(gate.main(["gate.py", "judge", d]), 2, "nothing ran")
        for name, text in (("camsweep", CAM), ("spawns", SPAWNS), ("features", FEAT)):
            with open(os.path.join(d, name + ".txt"), "w") as fh:
                fh.write(text)
        bpath = os.path.join(d, "base.json")
        with open(bpath, "w") as fh:
            import json
            json.dump(self.base, fh)
        self.assertEqual(gate.main(["gate.py", "judge", d, "--baseline", bpath]), 0)
        with open(os.path.join(d, "camsweep.txt"), "w") as fh:
            fh.write(CAM.replace("bad 0 (69", "bad 1 (69"))
        self.assertEqual(gate.main(["gate.py", "judge", d, "--baseline", bpath]), 1)


if __name__ == "__main__":
    unittest.main()
