"""tools/rider/studio/motion.py -- what a film shows that a still cannot, measured: the
frames where the rider's body JUMPS, and a foot that should be planted on the ground
SLIDING. Run on video-mode shots (video.sh with STUDIO_KEEP=shots.json).

    python3 tools/rider/studio/motion.py shots.json [pop_units]

POPS. Each joint is followed in the vehicle's travel frame (its position less the
vehicle's, turned by its heading only), so the vehicle's own travel, its pop off the
ground and its pitch are taken out and what is left is the rider moving on it. A joint
whose position in a frame is more than `pop_units` (default 2.5) from the straight line
through the frames either side of it -- the second difference -- has been moved in a way
the frames around it did not lead up to: at 30 fps, 2.5 units is a change of speed of 75
u/s in one frame, about 2 m/s, which a body does not do. A real snap shows on two frames
running (out and back, or a step and the stop after it); each is listed once, with every
joint that jumped and how far.

SLIDING FEET. A foot that is down on the GROUND (its ball, the Toe0 bone the IK pins,
within 4 units of the floor and away from the vehicle: a push, a kick) should not move
across it; its speed over the ground is printed for each contact, against the vehicle's.
A real push plants the foot and the board runs on from it.
"""
import json
import math
import sys

import numpy as np

JOINTS = ["Pelvis", "Spine2", "Head1", "L_Thigh", "R_Thigh", "L_Calf", "R_Calf", "L_Foot", "R_Foot",
          "L_Forearm", "R_Forearm", "L_Hand", "R_Hand"]


def travel_frame(shot):
    """The vehicle's position and its level heading (forward, left)."""
    y = math.radians(shot["ent"][4])
    return (np.array(shot["ent"][:3], float), np.array([math.cos(y), math.sin(y), 0.0]),
            np.array([-math.sin(y), math.cos(y), 0.0]))


def main():
    d = json.load(open(sys.argv[1]))
    lim = float(sys.argv[2]) if len(sys.argv) > 2 else 2.5
    S = d["shots"]
    if not d.get("video") or len(S) < 3:
        raise SystemExit("not a video-mode shots file")
    fps = d["video"].get("fps", 30)
    gz = d["video"].get("ground", 0)
    T = [s["t"] for s in S]
    ph = [s.get("phase", "") for s in S]
    X = {}
    for j in JOINTS:
        rows = []
        for s in S:
            b = s["bones"].get("ValveBiped.Bip01_" + j)
            o, f, l = travel_frame(s)
            q = (np.array(b[:3]) if b else o) - o
            rows.append([q @ f, q @ l, q[2]])
        X[j] = np.array(rows)
    print("POPS (a joint more than %.1f u off the line through its neighbours, in the vehicle's frame)" % lim)
    events = {}
    for j in JOINTS:
        x = X[j]
        acc = np.linalg.norm(x[2:] - 2 * x[1:-1] + x[:-2], axis=1)
        for i in np.where(acc > lim)[0]:
            events.setdefault(i + 1, []).append((acc[i], j))
    prev = None
    for i in sorted(events):
        js = sorted(events[i], reverse=True)
        if prev is not None and i != prev + 1:
            print()
        print("  t %5.2f  %-24s %s" % (T[i], ph[i][:24], ", ".join("%s %.1f" % (j, a) for a, j in js[:6])
                                       + (" (+%d more)" % (len(js) - 6) if len(js) > 6 else "")))
        prev = i
    if not events:
        print("  none")
    print("\nFEET ON THE GROUND (the ball of the foot within 4 u of the floor, off the vehicle)")
    any_ = False
    for side in "LR":
        W = np.array([s["bones"]["ValveBiped.Bip01_%s_Toe0" % side][:3] for s in S])
        down = []
        for i, s in enumerate(S):
            o, f, l = travel_frame(s)
            q = W[i] - o
            down.append(W[i, 2] - gz < 4 and (abs(q @ l) > 5 or abs(q @ f) > 18))
        i = 0
        while i < len(S):
            if not down[i]:
                i += 1
                continue
            k = i
            while k + 1 < len(S) and down[k + 1]:
                k += 1
            seg = W[i:k + 1, :2]
            slide = float(np.linalg.norm(seg[-1] - seg[0])) if k > i else 0.0
            v = [float(np.linalg.norm(W[m + 1, :2] - W[m - 1, :2]) / 2 * fps) for m in range(max(i, 1), min(k, len(S) - 2) + 1)]
            vb = np.mean([S[m]["st"]["v"] for m in range(i, k + 1)]) if "st" in S[i] else float("nan")
            print("  %s foot  t %5.2f-%5.2f  %-14s  down %.2f s, slid %4.1f u; speed over the ground mean %5.1f max %5.1f u/s"
                  " (vehicle %5.1f)" % (side, T[i], T[k], ph[i][:14], T[k] - T[i] + 1 / fps, slide,
                                        np.mean(v) if v else 0, max(v) if v else 0, vb))
            any_ = True
            i = k + 1
    if not any_:
        print("  none")


if __name__ == "__main__":
    main()
