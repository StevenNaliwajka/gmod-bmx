"""tools/rider/angles.py -- a rider's joint angles, measured the same way on the studio's
posed skeleton and on a real rider's BlazePose landmarks (refpose/blazepose.py), so the
two can be put on one plot (compare.py).

    python3 tools/rider/angles.py shots.json          # a table, a row per shot

Every angle is in degrees and is a FLEXION, 0 for a straight joint, because that is what
can be read off both: the knee is 180 less the angle at the knee between the thigh and
the shin, the hip 180 less the angle at the hip between the trunk (to the shoulders'
middle) and the thigh, the elbow likewise. `trunk` is the trunk's lean from vertical
(the hips' middle to the shoulders' middle), whichever way. `abd` is how far each upper
arm is out from the trunk's line, `stance` the feet apart in hip widths.

The joints are the bones' ORIGINS (ValveBiped.Bip01_*): the thigh's origin is the hip
joint, the calf's the knee, the foot's the ankle, the upper arm's the shoulder. That is
the same set of points BlazePose gives (hip, knee, ankle, shoulder, elbow, wrist), so the
two agree on what a knee angle is even though one skeleton is kleiner's and the other a
child's in a video. What they cannot agree on is anything the landmarks do not have:
there is no foot roll or spine curve here.
"""
import json
import math
import sys

import numpy as np

KEYS = ["kneeL", "kneeR", "hipL", "hipR", "trunk", "elbowL", "elbowR", "abdL", "abdR", "stance"]


def _ang(a, b, c):
    """The angle at b between b->a and b->c, degrees."""
    u, v = a - b, c - b
    d = np.dot(u, v) / max(np.linalg.norm(u) * np.linalg.norm(v), 1e-9)
    return math.degrees(math.acos(max(-1.0, min(1.0, d))))


def _between(u, v):
    d = np.dot(u, v) / max(np.linalg.norm(u) * np.linalg.norm(v), 1e-9)
    return math.degrees(math.acos(max(-1.0, min(1.0, d))))


def from_points(P, up):
    """The angles from named joint positions (lhip rhip lkn rkn lan ran lsh rsh lel rel lwr
    rwr) and the world's up, for either source."""
    hipm, shm = (P["lhip"] + P["rhip"]) / 2, (P["lsh"] + P["rsh"]) / 2
    down = hipm - shm
    return {
        "kneeL": 180 - _ang(P["lhip"], P["lkn"], P["lan"]), "kneeR": 180 - _ang(P["rhip"], P["rkn"], P["ran"]),
        "hipL": 180 - _ang(shm, P["lhip"], P["lkn"]), "hipR": 180 - _ang(shm, P["rhip"], P["rkn"]),
        "elbowL": 180 - _ang(P["lsh"], P["lel"], P["lwr"]), "elbowR": 180 - _ang(P["rsh"], P["rel"], P["rwr"]),
        "abdL": _between(P["lel"] - P["lsh"], down), "abdR": _between(P["rel"] - P["rsh"], down),
        "trunk": _between(shm - hipm, np.asarray(up, float)),
        "stance": float(np.linalg.norm(P["lan"] - P["ran"]) / max(np.linalg.norm(P["lhip"] - P["rhip"]), 1e-6)),
    }


BONE = {"lhip": "L_Thigh", "rhip": "R_Thigh", "lkn": "L_Calf", "rkn": "R_Calf", "lan": "L_Foot", "ran": "R_Foot",
        "lsh": "L_UpperArm", "rsh": "R_UpperArm", "lel": "L_Forearm", "rel": "R_Forearm",
        "lwr": "L_Hand", "rwr": "R_Hand"}


def of_shot(shot):
    """A studio shot's angles (its bones' origins; Source's up is +Z)."""
    P = {}
    for k, name in BONE.items():
        b = shot["bones"].get("ValveBiped.Bip01_" + name)
        if b is None:
            return None
        P[k] = np.array(b[:3], float)
    return {k: round(v, 2) for k, v in from_points(P, [0, 0, 1.0]).items()}


if __name__ == "__main__":
    d = json.load(open(sys.argv[1]))
    print("%-22s" % "shot", " kneeL kneeR  hipL  hipR trunk elbL elbR abdL abdR stance")
    for sh in d["shots"]:
        a = of_shot(sh)
        if a is None:
            continue
        print("%-22s" % sh["label"][:22], " ".join("%5.0f" % a[k] for k in
              ["kneeL", "kneeR", "hipL", "hipR", "trunk", "elbowL", "elbowR", "abdL", "abdR"]), "%5.2f" % a["stance"])
