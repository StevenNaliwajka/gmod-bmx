#!/usr/bin/env python3
# The Workshop gallery's shot list, as tools/bike/showcase.py scenes: every
# vehicle together and named, each family on its own sheet and turning, the
# paints, a close-up, two ready-made parks and an orbit of one. Rows are laid out across the frame from
# each model's real footprint, so nothing overlaps whatever its size.
#
#   python3 tools/bike/gallery_scenes.py OUT     reads OUT/models/*.txt, writes OUT/scenes/*.json
#
# tools/bike/gallery.sh exports the models and renders the scenes; this only
# decides what is in each picture.
import sys, os, json, math
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import showcase as S

OUT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "dist/gallery")
MODELS = os.path.join(OUT, "models")

V = {  # key: file, label, paint (each vehicle's registry colorIndex, BMX.Palette)
    "bmx": ("bmx.txt", "BMX", "Red"),
    "cruiser": ("cruiser.txt", "BMX Cruiser", "Blue"),
    "mini": ("mini.txt", "Mini BMX", "Yellow"),
    "road": ("road.txt", "Road Bike", "White"),
    "fixie": ("fixie.txt", "Fixie", "Orange"),
    "city": ("city.txt", "City Bike", "Black"),
    "tandem": ("tandem.txt", "Tandem", "Blue"),
    "dh": ("dh.txt", "Downhill Bike", "Indigo"),
    "unicycle": ("unicycle.txt", "Unicycle", "Teal"),
    "penny": ("penny.txt", "Penny-Farthing", "Cyan"),
    "ebike": ("ebike.txt", "E-Bike", "Teal"),
    "emoto": ("emoto.txt", "E-Moto", "Blue"),
    "dirtbike": ("dirtbike.txt", "Dirt Bike", "Orange"),
    "moped": ("moped.txt", "Moped", "Pink"),
    "skateboard": ("skateboard.txt", "Skateboard", "Teal"),
    "scooter": ("scooter.txt", "Kick Scooter", "Orange"),
    "skates": ("skates.txt", "Inline Skates", "Red"),
    # the ready-made parks (BMX.Park.Presets), which between them use all 15 pieces
    "street_plaza": ("preset_street_plaza.txt", "Street plaza", None),
    "vert_ramp": ("preset_vert_ramp.txt", "Vert ramp", None),
    "dirt_line": ("preset_dirt_line.txt", "Dirt line", None),
    "rack": ("rack.txt", "Bike Rack", None),           # tools/bike/export_drawn.lua rack
    "bmx_locked": ("bmx_locked.txt", "BMX, locked", "Red"),   # the BMX with export_drawn.lua lock added
}

FOOT = {}
for k, (f, _, _) in V.items():
    P, N, M, shift = S.pose(S.load(os.path.join(MODELS, f)))
    FOOT[k] = P[:, :2]
    print(k, "footprint", np.round(P.max(0) - P.min(0), 1), file=sys.stderr)


def model(k, at, yaw=0, label=True, above=False):
    f, lab, paint = V[k]
    d = {"file": "../models/" + f, "at": [round(at[0], 2), round(at[1], 2)], "yaw": yaw}
    if paint:
        d["paint"] = paint
    if label:
        d["label"] = lab
        if above:
            d["label_above"] = True
    return d


def pair(m, gap=8.0):
    """Skates come in twos: the one model again, a stride to its left."""
    other = dict(m, at=[m["at"][0], m["at"][1] + gap])
    other.pop("label", None)
    return [m, other]


def row(keys, az, gap, depth=0.0, yaw=0, label=True, shift=0.0, above=False):
    a = math.radians(az)
    d = np.array([math.cos(a), math.sin(a)])          # toward the camera
    u = np.array([-math.sin(a), math.cos(a)])         # screen right
    ya = math.radians(yaw)
    R = np.array([[math.cos(ya), -math.sin(ya)], [math.sin(ya), math.cos(ya)]])
    spans = []
    for k in keys:
        pu = (FOOT[k] @ R.T) @ u
        spans.append((pu.min(), pu.max()))
    xs, cur = [], 0.0
    for lo, hi in spans:
        xs.append(cur - lo)
        cur = cur - lo + hi + gap
    total = cur - gap
    out = []
    for k, x in zip(keys, xs):
        m = model(k, u * (x - total / 2 + shift) - d * depth, yaw, label, above)
        out += pair(m) if k == "skates" else [m]
    return out


def spin_row(keys, az, gap, depth=0.0, label=True, above=False, shift=0.0):
    """A row spaced for turning in place: each model gets its whole circle."""
    a = math.radians(az)
    d = np.array([math.cos(a), math.sin(a)])
    u = np.array([-math.sin(a), math.cos(a)])
    xs, cur = [], 0.0
    for k in keys:
        r = np.linalg.norm(FOOT[k], axis=1).max()
        xs.append(cur + r)
        cur += 2 * r + gap
    total = cur - gap
    out = []
    for k, x in zip(keys, xs):
        m = model(k, u * (x - total / 2 + shift) - d * depth, 0, label, above)
        out += pair(m) if k == "skates" else [m]
    return out


def write(name, spec):
    os.makedirs(os.path.join(OUT, "scenes"), exist_ok=True)
    json.dump(spec, open(os.path.join(OUT, "scenes", name + ".json"), "w"), indent=1)


AZ, EL = -53, 15
cam = {"az": AZ, "el": EL, "fov": 32, "fit": 0.9}

write("garage", {"size": [1280, 720], "ss": 2, "camera": dict(cam, el=27, fit=0.95, lift=0.25),
                 "caption": "17 rides, every one built in code", "labels": True, "label_px": 13, "label_drop": 0.04,
                 "models": row(["dirtbike", "emoto", "city", "tandem", "road"], AZ, 10, depth=190)
                 + row(["penny", "dh", "cruiser", "ebike", "moped", "fixie"], AZ, 12, depth=95)
                 + row(["unicycle", "mini", "bmx", "scooter", "skateboard", "skates"], AZ, 16, depth=0)})
write("family", {"size": [1280, 720], "ss": 2, "camera": dict(cam, fit=0.86), "labels": True,
                 "caption": "The BMX family: 24, 20 and 16 inch wheels",
                 "models": row(["cruiser", "bmx", "mini"], AZ, 14)})
write("street", {"size": [1280, 720], "ss": 2, "camera": dict(cam, el=30, fit=0.86, lift=0.7), "labels": True,
                 "caption": "Gears, a fixed wheel, a basket, and a seat for two",
                 "models": row(["city", "tandem"], AZ, 24, depth=115, above=True, shift=-18)
                 + row(["road", "fixie"], AZ, 40, shift=20)})
write("odd", {"size": [1280, 720], "ss": 2, "camera": dict(cam, fit=0.86), "labels": True,
              "caption": "Long travel, one wheel, and one very big wheel",
              "models": row(["dh", "unicycle", "penny"], AZ, 16)})
write("boards", {"size": [1280, 720], "ss": 2, "camera": dict(cam, el=20, fit=0.86), "labels": True,
                 "caption": "Push, ollie, kick and stride: a board, a scooter and skates",
                 "models": row(["scooter", "skateboard", "skates"], AZ, 8)})
write("motor", {"size": [1280, 720], "ss": 2, "camera": dict(cam, el=30, fit=0.86, lift=0.7), "labels": True,
                "caption": "Motor vehicles, for admins unless the server opens them up",
                "models": row(["emoto", "dirtbike"], AZ, 24, depth=115, above=True, shift=-18)
                 + row(["ebike", "moped"], AZ, 40, shift=20)})
write("turn-bmx", {"size": [640, 360], "ss": 2, "camera": dict(cam, el=14, fit=0.92),
                   "turntable": {"frames": 30, "degrees": 360, "ms": 70},
                   "models": [model("bmx", [0, 0], label=False)]})
write("turn-dirtbike", {"size": [640, 360], "ss": 2, "camera": dict(cam, el=14, fit=0.92),
                        "turntable": {"frames": 30, "degrees": 360, "ms": 70},
                        "models": [model("dirtbike", [0, 0], label=False)]})
write("turn-boards", {"size": [640, 360], "ss": 2, "camera": dict(cam, el=22, fit=0.92),
                      "turntable": {"frames": 30, "degrees": 360, "ms": 70},
                      "models": row(["scooter", "skateboard", "skates"], AZ, 16, label=False)})
TURN = {"frames": 30, "degrees": 360, "ms": 70}
write("turn-family", {"size": [640, 360], "ss": 2, "camera": dict(cam, el=18, fit=0.94), "turntable": TURN,
                      "labels": True, "models": spin_row(["cruiser", "bmx", "mini"], AZ, 4)})
write("turn-street", {"size": [640, 360], "ss": 2, "camera": dict(cam, el=30, fit=0.9, lift=0.6), "turntable": TURN,
                      "labels": True, "models": spin_row(["city", "tandem"], AZ, 6, depth=100, above=True, shift=-20)
                      + spin_row(["road", "fixie"], AZ, 6, shift=20)})
write("turn-odd", {"size": [640, 360], "ss": 2, "camera": dict(cam, el=18, fit=0.94), "turntable": TURN,
                   "labels": True, "models": spin_row(["dh", "unicycle", "penny"], AZ, 4)})
write("turn-motor", {"size": [640, 360], "ss": 2, "camera": dict(cam, el=30, fit=0.9, lift=0.6), "turntable": TURN,
                     "labels": True, "models": spin_row(["emoto", "dirtbike"], AZ, 6, depth=100, above=True, shift=-20)
                     + spin_row(["ebike", "moped"], AZ, 6, shift=20)})
write("turn-park", {"size": [640, 360], "ss": 2, "camera": dict(cam, el=32, fit=0.96, lift=0.2),
                    "turntable": {"frames": 36, "degrees": 360, "ms": 90},
                    "models": [model("vert_ramp", [0, 0], label=False)]})
write("rack", {"size": [632, 296], "ss": 2, "camera": dict(cam, az=-40, el=24, fit=0.84, lift=0.3),
               "models": [model("rack", [0, 0], label=False)] + row(["bmx"], AZ, 0, label=False, shift=62)})
write("lock", {"size": [632, 296], "ss": 2,
               "camera": {"az": -118, "el": 20, "fov": 30, "dist": 92,
                          "anchor": {"model": 0, "name": "rear", "offset": [8, -3, -3]}},
               "models": [model("bmx_locked", [0, 0], label=False)]})
write("icon-turn", {"size": [512, 512], "ss": 2, "camera": dict(cam, el=16, fit=0.94),
                    "turntable": {"frames": 30, "degrees": 360, "ms": 70},
                    "models": [model("bmx", [0, 0], label=False)]})
write("paints", {"size": [1280, 720], "ss": 2, "camera": {"az": -90, "el": 6, "fov": 30, "fit": 0.8},
                 "paints": {"model": model("bmx", [0, 0], label=False), "cols": 4, "rows": 4,
                            "title": ["14 paints", "or pick any colour"]}})
write("detail", {"size": [1280, 720], "ss": 2,
                 "camera": {"az": -58, "el": 17, "fov": 30, "dist": 62,
                            "anchor": {"model": 0, "name": "bb", "offset": [-7, 0, 3]}},
                 "caption": "Every tooth, link, spoke and pedal pin",
                 "models": [model("bmx", [0, 0], label=False)]})
def front_of(key, ahead, along, az=AZ):
    """A point `ahead` units toward the camera from a model's front edge, `along` to the right."""
    a = math.radians(az)
    d = np.array([math.cos(a), math.sin(a)]); u = np.array([-math.sin(a), math.cos(a)])
    reach = (FOOT[key] @ d).max()
    p = d * (reach + ahead) + u * along
    return [float(p[0]), float(p[1])]


write("park-vert", {"size": [1280, 720], "ss": 2, "camera": dict(cam, el=30, fit=0.92, lift=0.35),
                    "caption": "15 ramps, rails and ledges in three sizes: the Vert ramp park",
                    "models": [model("vert_ramp", [0, 0], label=False),
                               model("bmx", front_of("vert_ramp", 40, -140), label=False),
                               model("cruiser", front_of("vert_ramp", 70, 60), yaw=25, label=False)]})
write("park-street", {"size": [1280, 720], "ss": 2, "camera": dict(cam, el=28, fit=0.92, lift=0.35),
                      "caption": "Rails, ledges and a hubba: the Street plaza park, built in one click",
                      "models": [model("street_plaza", [0, 0], label=False),
                                 model("fixie", front_of("street_plaza", 40, -180), label=False),
                                 model("bmx", front_of("street_plaza", 60, 120), yaw=-20, label=False)]})
print("ok", file=sys.stderr)
