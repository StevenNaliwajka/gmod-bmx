# Draw what tools/rider/export.lua posed: every vehicle's rider through a
# pedal stroke, side and front, as a contact sheet, a looping GIF each, and a
# reach report (how far each hand and foot is from its grip or pedal).
#
#   lua5.1 tools/rider/export.lua [ids] [frames] > rider.json
#   python3 tools/rider/render.py rider.json out/
#
# out/sheet.png    one row per vehicle: side views at four crank angles + front
# out/<id>.gif     the stroke, side and front, looping
# out/report.txt   the worst miss per hand and foot over the stroke
#
# The skeleton is the offline suite's stand-in (tests/lib/skeleton.lua), so this
# shows what the IK and the pose sets DO, at a standard player's proportions;
# a real model's mesh is still a client's job (tools/ride/shoot.sh). Needs Pillow.
import json, math, os, sys
from PIL import Image, ImageDraw

src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
data = json.load(open(src))
parents = data["parents"]

# A hand or foot further than this from its grip or pedal is flagged: the
# offline suite's band for a foot over a whole stroke (tests/test_rider.lua).
MISS = 3.0

BG, GROUND, BIKE = (250, 249, 246), (190, 186, 178), (120, 124, 132)
NEAR, FAR, CORE = (214, 72, 15), (240, 170, 110), (40, 44, 52)
GRIP, PEDAL, BAD = (34, 110, 200), (40, 150, 80), (220, 30, 40)

SKIP = ("Finger", "Toe0")      # fingers and toes are clutter at this size


def bone_side(name):
    return "R" if name.startswith("R_") else "L" if name.startswith("L_") else ""


class View:
    """Project world points for one panel: 'side' looks from the bike's right
    (-Y), forward to the right; 'front' looks back at the rider from ahead,
    the rider's left (+Y) to the right."""

    def __init__(self, kind, box, rect):
        self.kind = kind
        (x0, z0, x1, z1), (px, py, pw, ph) = box, rect
        s = min(pw / (x1 - x0), ph / (z1 - z0)) * 0.92
        self.s, self.px, self.py, self.pw, self.ph = s, px, py, pw, ph
        self.cx, self.cz = (x0 + x1) / 2, (z0 + z1) / 2

    def h(self, p):
        return p[0] if self.kind == "side" else p[1]

    def __call__(self, p):
        return (self.px + self.pw / 2 + (self.h(p) - self.cx) * self.s,
                self.py + self.ph / 2 - (p[2] - self.cz) * self.s)

    def depth(self, p):        # larger = nearer the camera
        return -p[1] if self.kind == "side" else p[0]


def bounds(v, kind):
    hs, zs = [], [v["ground"]]
    for f in v["frames"]:
        for n, p in f["bones"].items():
            hs.append(p[0] if kind == "side" else p[1]); zs.append(p[2])
    for w, r in ((v["front"], v["frontRadius"]), (v["rear"], v["radius"])):
        h = w[0] if kind == "side" else w[1]
        hs += [h - r, h + r]; zs.append(w[2] + r)
    pad = 4
    return (min(hs) - pad, min(zs) - pad, max(hs) + pad, max(zs) + pad)


def draw_panel(d, v, f, view):
    g = v["ground"]
    gl, gr = view((-1e3, -1e3, g)), view((1e3, 1e3, g))
    d.line([(view.px, gl[1]), (view.px + view.pw, gl[1])], fill=GROUND, width=2)

    # The bike: wheels, and a frame line from the rear axle through the cranks
    # to the bars, enough to read the rider against.
    T = f["targets"]
    crank = None
    if "rFoot" in T and "lFoot" in T:
        crank = [(a + b) / 2 for a, b in zip(T["rFoot"], T["lFoot"])]
    for w, r in ((v["rear"], v["radius"]), (v["front"], v["frontRadius"])):
        c = view(w)
        if view.kind == "side":
            rr = r * view.s
            d.ellipse([c[0] - rr, c[1] - rr, c[0] + rr, c[1] + rr], outline=BIKE, width=2)
        else:
            d.line([(c[0], c[1] - r * view.s), (c[0], c[1] + r * view.s)], fill=BIKE, width=3)
    grips = [T[k] for k in ("rHandHeld", "lHandHeld", "rHand", "lHand") if k in T][:2]
    bar = [sum(c) / len(grips) for c in zip(*grips)] if grips else None
    pts = [v["rear"]] + ([crank] if crank else []) + [v["seat"]]
    d.line([view(p) for p in pts], fill=BIKE, width=2)
    if bar:
        d.line([view(v["front"]), view(bar)], fill=BIKE, width=2)
        if crank:
            d.line([view(crank), view(bar)], fill=BIKE, width=2)

    # The rider, far side first so the near limbs draw over it.
    B = f["bones"]
    segs = []
    for n, p in B.items():
        par = parents.get(n)
        if not par or par not in B or any(s in n for s in SKIP):
            continue
        segs.append((view.depth(p), n, B[par], p))
    near = "R" if view.kind == "side" else "L"
    for _, n, a, b in sorted(segs):
        side = bone_side(n)
        col = CORE if not side else NEAR if side == near else FAR
        d.line([view(a), view(b)], fill=col, width=4 if col is not FAR else 3)
    if "Head1" in B and "Spine2" in B:
        c = view(B["Head1"]); r = 4.2 * view.s
        d.ellipse([c[0] - r, c[1] - r, c[0] + r, c[1] + r], outline=CORE, width=3)

    # The targets: a grip or pedal the hand or foot missed gets a red ring.
    for k, col in (("rHand", GRIP), ("lHand", GRIP), ("rFoot", PEDAL), ("lFoot", PEDAL)):
        t = T.get(k + "Held") or T.get(k)
        if not t:
            continue
        c = view(t)
        miss = f["reach"].get(k)
        r = 2.5
        d.ellipse([c[0] - r, c[1] - r, c[0] + r, c[1] + r], fill=col)
        if miss is not None and miss > MISS:
            r = 7
            d.ellipse([c[0] - r, c[1] - r, c[0] + r, c[1] + r], outline=BAD, width=2)


def worst(v):
    return {k: max((fr["reach"].get(k) or 0) for fr in v["frames"])
            for k in ("rHand", "lHand", "rFoot", "lFoot")}


def label(d, xy, text, col=CORE):
    d.text(xy, text, fill=col)


PW, PH = 230, 210                       # one panel
PHASES = [0, 90, 180, 270]
vehicles = data["vehicles"]


def frame_at(v, deg):
    return min(v["frames"], key=lambda f: abs((f["crank"] - deg + 180) % 360 - 180))


# ---- the contact sheet ----
cols = len(PHASES) + 1
LW = 150
sheet = Image.new("RGB", (LW + cols * PW, 28 + len(vehicles) * PH), BG)
d = ImageDraw.Draw(sheet)
label(d, (8, 8), "rider pose through a pedal stroke  (side: crank 0/90/180/270, then front)   "
                 "red ring = hand/foot > %.0f u off its grip/pedal" % MISS)
for c, deg in enumerate(PHASES):
    label(d, (LW + c * PW + 8, 18), "crank %d" % deg, BIKE)
label(d, (LW + len(PHASES) * PW + 8, 18), "front", BIKE)
for r, v in enumerate(vehicles):
    y = 28 + r * PH
    w = worst(v)
    bad = [k for k, x in w.items() if x > MISS]
    label(d, (8, y + 10), v["id"])
    label(d, (8, y + 24), "pose set: " + v["pose"], BIKE)
    for i, k in enumerate(("rHand", "lHand", "rFoot", "lFoot")):
        label(d, (8, y + 44 + i * 13), "%s %.1f" % (k, w[k]), BAD if w[k] > MISS else BIKE)
    sb, fb = bounds(v, "side"), bounds(v, "front")
    for c, deg in enumerate(PHASES):
        draw_panel(d, v, frame_at(v, deg), View("side", sb, (LW + c * PW, y, PW, PH)))
    draw_panel(d, v, frame_at(v, 0), View("front", fb, (LW + len(PHASES) * PW, y, PW, PH)))
    d.line([(0, y + PH - 1), (sheet.width, y + PH - 1)], fill=(228, 226, 220))
sheet.save(os.path.join(out, "sheet.png"))

# ---- a looping GIF each ----
for v in vehicles:
    sb, fb = bounds(v, "side"), bounds(v, "front")
    frames = []
    for f in v["frames"]:
        im = Image.new("RGB", (2 * PW + 40, PH + 24), BG)
        dd = ImageDraw.Draw(im)
        label(dd, (8, 6), "%s  (%s)  crank %3d" % (v["id"], v["pose"], round(f["crank"])))
        draw_panel(dd, v, f, View("side", sb, (0, 24, PW + 40, PH)))
        draw_panel(dd, v, f, View("front", fb, (PW + 40, 24, PW, PH)))
        frames.append(im)
    frames[0].save(os.path.join(out, v["id"] + ".gif"), save_all=True,
                   append_images=frames[1:], duration=int(1000 / max(1, len(frames))), loop=0)

# ---- the reach report ----
lines = ["worst distance from each hand / foot to its grip / pedal over a crank turn, units",
         "(> %.1f flagged; the offline suite holds the stock BMX to 1.5 at rest, 3 over a turn)" % MISS, ""]
lines.append("%-12s %-9s %7s %7s %7s %7s" % ("vehicle", "pose", "rHand", "lHand", "rFoot", "lFoot"))
for v in vehicles:
    w = worst(v)
    lines.append("%-12s %-9s " % (v["id"], v["pose"]) +
                 " ".join(("%6.1f%s" % (w[k], "!" if w[k] > MISS else " ")) for k in ("rHand", "lHand", "rFoot", "lFoot")))
for k, e in sorted(data.get("errors", {}).items()):
    lines.append("%-12s ERROR %s" % (k, e.splitlines()[0][:150]))
open(os.path.join(out, "report.txt"), "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
print("\nwrote %s/sheet.png, %d GIFs, report.txt" % (out, len(vehicles)))
