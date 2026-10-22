"""tools/rider/refpose/blazepose.py -- a real rider's joint angles, frame by frame, out of a
video: MediaPipe's BlazePose (the pose_landmarker_heavy models) run on LiteRT, for
compare.py to plot against the studio's rider. README.md, "Comparing with real footage".

    python -I tools/rider/refpose/blazepose.py VIDEO OUT.json [--from S] [--to S]
        [--models DIR] [--sheet SHEET.jpg]

WHY NOT THE MEDIAPIPE PACKAGE. Its wheels need AVX, which the machine this was written
on does not have; the models themselves are plain TFLite, and LiteRT (ai_edge_litert)
runs them anywhere. So this is MediaPipe's pose pipeline written out by hand: the
detector finds the person on the first frame (and again whenever tracking is lost),
then each frame is cropped to the region the previous frame's two alignment landmarks
give (the hips' middle and a point over the head, rotated upright, 2.5 times their
distance across, as MediaPipe does) and the landmark model runs on that.

THE MODELS (not in git; Google's, Apache 2.0): download the task bundle and unzip it,

    mkdir -p tools/rider/refpose/.models && cd tools/rider/refpose/.models
    curl -LO https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_heavy/float16/latest/pose_landmarker_heavy.task
    unzip pose_landmarker_heavy.task        # -> pose_detector.tflite, pose_landmarks_detector.tflite

--models defaults to that directory. It needs numpy, opencv-python and ai-edge-litert
(pip, in a venv); -I keeps a downloaded clip's directory off the import path.

WHAT IT WRITES: {"video", "fps", "frames": [{"t", "kneeL", "kneeR", "hipL", "hipR",
"trunk", "elbowL", "elbowR", "abdL", "abdR", "stance", "vis", "flag", "img", "world"}]}.
The angles are tools/rider/angles.py's, from the 3D WORLD landmarks (metres, hips at the
origin, y down -- so the trunk's lean is measured from -y), which is what makes a
monocular estimate comparable at all: the 2D image landmarks foreshorten every joint
that is not side-on to the camera. `vis` is the least visible of the hips, knees, ankles
and shoulders (compare.py drops frames under 0.5); `img` the 33 landmarks in image
fractions, `world` in metres. A frame without a person has only `t`. --sheet draws the
skeleton on a contact sheet of the clip, to see where it lost the rider.

Left and right are the PERSON's own, as the studio's are the rider's: for a skater the
front leg is the left for a regular stance and the right for goofy.
"""
import argparse
import json
import math
import os
import sys

import cv2
import numpy as np
from ai_edge_litert.interpreter import Interpreter

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import angles as ANG  # noqa: E402  (tools/rider/angles.py)

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument("video")
ap.add_argument("out")
ap.add_argument("--from", dest="t0", type=float, default=0.0)
ap.add_argument("--to", dest="t1", type=float, default=1e9)
ap.add_argument("--models", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".models"))
ap.add_argument("--sheet")
A = ap.parse_args()
for f in ("pose_detector.tflite", "pose_landmarks_detector.tflite"):
    if not os.path.exists(os.path.join(A.models, f)):
        raise SystemExit("no %s in %s: see this file's header for where the models come from" % (f, A.models))

det = Interpreter(model_path=os.path.join(A.models, "pose_detector.tflite"), num_threads=4)
det.allocate_tensors()
lmk = Interpreter(model_path=os.path.join(A.models, "pose_landmarks_detector.tflite"), num_threads=4)
lmk.allocate_tensors()
D_IN = det.get_input_details()[0]["index"]
D_OUT = {d["shape"][-1]: d["index"] for d in det.get_output_details()}
L_IN = lmk.get_input_details()[0]["index"]
L_OUT = {tuple(d["shape"]): d["index"] for d in lmk.get_output_details()}


def sigmoid(x):
    return 1 / (1 + np.exp(-np.clip(x, -50, 50)))


def anchors():
    """The detector's SSD anchors (224 x 224 input, strides 8, 16, 32, 32, 32)."""
    out = []
    strides = [8, 16, 32, 32, 32]
    i = 0
    while i < len(strides):
        s = strides[i]
        n = 0
        while i < len(strides) and strides[i] == s:
            n += 2
            i += 1
        g = math.ceil(224 / s)
        for y in range(g):
            for x in range(g):
                for _ in range(n):
                    out.append(((x + 0.5) / g, (y + 0.5) / g))
    return np.array(out, np.float32)


ANCH = anchors()
assert len(ANCH) == 2254


def letterbox(img, size):
    h, w = img.shape[:2]
    s = size / max(h, w)
    nw, nh = int(round(w * s)), int(round(h * s))
    px, py = (size - nw) // 2, (size - nh) // 2
    out = np.zeros((size, size, 3), np.uint8)
    out[py:py + nh, px:px + nw] = cv2.resize(img, (nw, nh))
    return out, s, px, py


def detect(rgb):
    """The best person: (centre, alignment point) in image pixels, or None."""
    box, s, px, py = letterbox(rgb, 224)
    det.set_tensor(D_IN, (box.astype(np.float32) / 127.5 - 1)[None])
    det.invoke()
    raw = det.get_tensor(D_OUT[12])[0]
    score = sigmoid(det.get_tensor(D_OUT[1])[0][:, 0])
    k = int(np.argmax(score))
    if score[k] < 0.75:
        return None
    r = raw[k]
    ax, ay = ANCH[k]

    def pt(j):
        x = (r[4 + 2 * j] / 224 + ax) * 224
        y = (r[5 + 2 * j] / 224 + ay) * 224
        return np.array([(x - px) / s, (y - py) / s])
    return pt(0), pt(1)


def roi_from(c, a):
    """MediaPipe's alignment ROI: centred on c, rotated so a is straight up, 2.5 x |a - c|."""
    d = a - c
    size = 2 * np.linalg.norm(d) * 1.25
    rot = math.pi / 2 - math.atan2(-d[1], d[0])
    rot = (rot + math.pi) % (2 * math.pi) - math.pi
    return c, size, rot


def crop(rgb, roi, n=256):
    (cx, cy), size, rot = roi
    c, s_ = math.cos(rot), math.sin(rot)
    # output (u, v) in 0..n -> image: centre + R * ((u, v) / n - 0.5) * size
    k = size / n
    M = np.array([[c * k, -s_ * k, 0], [s_ * k, c * k, 0]], np.float64)
    M[:, 2] = np.array([cx, cy]) - M[:, :2] @ np.array([n / 2, n / 2])
    out = cv2.warpAffine(rgb, cv2.invertAffineTransform(M), (n, n), flags=cv2.INTER_LINEAR,
                         borderMode=cv2.BORDER_CONSTANT)
    return out, M


def landmarks(rgb, roi):
    img, M = crop(rgb, roi)
    lmk.set_tensor(L_IN, (img.astype(np.float32) / 255.0)[None])
    lmk.invoke()
    raw = lmk.get_tensor(L_OUT[(1, 195)])[0].reshape(39, 5)
    flag = float(sigmoid(lmk.get_tensor(L_OUT[(1, 1)])[0][0]))
    world = lmk.get_tensor(L_OUT[(1, 117)])[0].reshape(39, 3)
    uv = raw[:, :2]
    xy = (M[:, :2] @ uv.T).T + M[:, 2]
    vis = sigmoid(raw[:, 3])
    return xy, world, vis, flag


# BlazePose's landmark numbers for the joints tools/rider/angles.py measures.
IDX = {"lsh": 11, "rsh": 12, "lel": 13, "rel": 14, "lwr": 15, "rwr": 16,
       "lhip": 23, "rhip": 24, "lkn": 25, "rkn": 26, "lan": 27, "ran": 28}
VIS_JOINTS = ("lhip", "rhip", "lkn", "rkn", "lan", "ran", "lsh", "rsh")


def angles(W, vis):
    r = ANG.from_points({k: W[j] for k, j in IDX.items()}, [0.0, -1.0, 0.0])
    r["vis"] = float(min(vis[IDX[k]] for k in VIS_JOINTS))
    return {k: round(v, 2) for k, v in r.items()}


EDGES = [(11, 12), (11, 13), (13, 15), (12, 14), (14, 16), (11, 23), (12, 24), (23, 24),
         (23, 25), (25, 27), (24, 26), (26, 28), (27, 31), (28, 32)]

cap = cv2.VideoCapture(A.video)
fps = cap.get(cv2.CAP_PROP_FPS) or 30
frames, thumbs = [], []
roi = None
i = 0
while True:
    ok, bgr = cap.read()
    if not ok:
        break
    t = i / fps
    i += 1
    if t < A.t0:
        continue
    if t > A.t1:
        break
    rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
    rec = {"t": round(t, 4)}
    if roi is None:
        d = detect(rgb)
        if d:
            roi = roi_from(*d)
    if roi is not None:
        xy, world, vis, flag = landmarks(rgb, roi)
        if flag < 0.7:
            roi = None
        else:
            rec.update(angles(world, vis))
            rec["flag"] = round(flag, 3)
            h, w = rgb.shape[:2]
            rec["img"] = [[round(float(p[0]) / w, 4), round(float(p[1]) / h, 4)] for p in xy[:33]]
            rec["world"] = [[round(float(v), 4) for v in p] for p in world[:33]]
            roi = roi_from(xy[33], xy[34])
            if A.sheet:
                for a, b in EDGES:
                    cv2.line(bgr, tuple(int(v) for v in xy[a]), tuple(int(v) for v in xy[b]), (0, 255, 0), 2)
    frames.append(rec)
    if A.sheet:
        thumbs.append((t, bgr))
json.dump({"video": os.path.basename(A.video), "fps": fps, "frames": frames}, open(A.out, "w"))
print(A.video, "frames", len(frames), "with pose", sum(1 for f in frames if "kneeL" in f))
if A.sheet and thumbs:
    pick = thumbs[:: max(1, len(thumbs) // 24)][:24]
    tiles = []
    for t, im in pick:
        im = cv2.resize(im, (320, int(320 * im.shape[0] / im.shape[1])))
        cv2.putText(im, "%.2f" % t, (5, 18), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 1)
        tiles.append(im)
    while len(tiles) % 6:
        tiles.append(np.zeros_like(tiles[0]))
    rows = [np.hstack(tiles[r:r + 6]) for r in range(0, len(tiles), 6)]
    cv2.imwrite(A.sheet, np.vstack(rows))
