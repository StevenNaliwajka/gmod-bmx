#!/usr/bin/env python3
# Showcase renders of the procedural vehicles and park pieces, for the Workshop
# gallery: several models lit together in one scene, a turntable GIF, or a sheet
# of one model in every paint. The look is tools/bike/preview.py's (a G-buffer,
# a sun with a shadow map, a sky/ground ambient, a fake environment reflection
# per material); the rasteriser does small triangles in bulk with numpy, so a
# scene of every vehicle at once (~1.3M triangles) takes minutes, not hours.
#
#   lua5.1 tools/bike/export.lua kind=road > road.txt      one model (export.lua)
#   lua5.1 tools/bike/export_park.lua quarterpipe 2 2 > qp.txt
#   python3 tools/bike/showcase.py scene.json out.jpg       a still (.jpg/.png)
#   python3 tools/bike/showcase.py scene.json out.gif       a turntable
#
# A scene is JSON:
#   size [W, H], ss 2                 output pixels and supersampling
#   models: [{file, paint, at [x, y], yaw, steer, crank, label, label_above}]
#       paint is a BMX.Palette name ("Blue") or [r, g, b] 0-255; files are
#       relative to the scene file; each model stands on the floor, centred on `at`
#   camera: {az, el, fov, fit, target [x, y, z], lift}
#       az/el in degrees (az 0 looks from the front, -90 from the right side),
#       fit is how much of the frame the scene fills (0.9)
#   turntable: {frames, degrees, ms}  a GIF of every model spinning in place
#   paints: {model, cols, rows, title} a sheet: one model in every palette paint
#   labels: true                      each model's label under it
#   caption: "text"                   a line at the top left
# Needs numpy and Pillow.
import sys, os, re, json, math
import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))


# ---- paint: BMX.Palette, read from the addon so a scene can say "Blue" ----
def read_palette():
    s = open(os.path.join(ROOT, "lua", "bmx", "sh_color.lua")).read()
    rows = re.findall(r'name\s*=\s*"(\w+)",\s*color\s*=\s*Color\(\s*(\d+),\s*(\d+),\s*(\d+)\s*\)', s)
    return {n: (int(r), int(g), int(b)) for n, r, g, b in rows}


PALETTE = read_palette()


def paint_rgb(p):
    c = np.array(PALETTE[p] if isinstance(p, str) else p, float) / 255
    return tuple(np.clip(c, 0, 1) ** 1.25 * 0.92)   # the palette's sRGB into the renderer's space


# ---- materials: base colour, spec strength, spec exponent, reflectivity (preview.py's) ----
MAT = {
    "paint":   ((0.75, 0.08, 0.09), 0.55, 60, 0.10),
    "black":   ((0.045, 0.045, 0.05), 0.35, 30, 0.05),
    "chrome":  ((0.55, 0.57, 0.6), 1.2, 120, 0.75),
    "alloy":   ((0.6, 0.61, 0.63), 0.8, 50, 0.35),
    "steel":   ((0.3, 0.3, 0.32), 0.6, 40, 0.2),
    "rubber":  ((0.03, 0.03, 0.035), 0.08, 10, 0.0),
    "gum":     ((0.55, 0.38, 0.22), 0.08, 10, 0.0),
    "seat":    ((0.04, 0.04, 0.045), 0.25, 18, 0.02),
    "plastic": ((0.06, 0.06, 0.065), 0.2, 16, 0.02),
    "white":   ((0.85, 0.85, 0.83), 0.3, 20, 0.04),
    "wood":    ((0.78, 0.6, 0.38), 0.1, 10, 0.0),
    "leather": ((0.4, 0.22, 0.1), 0.2, 14, 0.01),
    "lens":    ((0.8, 0.8, 0.78), 1.0, 90, 0.6),
    "redlens": ((0.75, 0.05, 0.04), 0.8, 70, 0.3),
    "amber":   ((0.9, 0.5, 0.05), 0.8, 70, 0.3),
    "decal":    ((0.9, 0.9, 0.9), 0.5, 60, 0.1),      # textured in the game; flat here
    "tyretext": ((0.3, 0.22, 0.14), 0.05, 10, 0.0),
}
GROUND = (0.46, 0.46, 0.44)


# ---- loading an export ----
def load(path):
    m = dict(buckets=[], steer=np.array([0, 0, 1.0]), k=1.0, A={}, N={}, mats={})
    lines = open(path).read().split("\n")
    i = 0
    while i < len(lines):
        l = lines[i]
        tag = l[:2]
        if tag == "L ":
            p = l.split()
            m["k"] = float(p[1]); m["steer"] = np.array([float(x) for x in p[2:5]])
        elif tag == "A ":
            p = l.split()
            m["A"][p[1]] = np.array([float(x) for x in p[2:5]])
        elif tag == "N ":
            p = l.split()
            m["N"][p[1]] = float(p[2])
        elif tag == "C ":                       # a material of the file's own: C name r g b (0-255)
            p = l.split()
            m["mats"][p[1]] = tuple(float(x) / 255 for x in p[2:5])
        elif tag == "B ":
            _, g, mat, det, n = l.split()
            n = int(n)
            arr = np.array(" ".join(lines[i + 1:i + 1 + n]).split(), float).reshape(n, 6)
            m["buckets"].append((g, mat, arr))
            i += 1 + n
            continue
        i += 1
    return m


def rotm(axis, ang):
    a = axis / np.linalg.norm(axis)
    c, s = math.cos(ang), math.sin(ang)
    K = np.array([[0, -a[2], a[1]], [a[2], 0, -a[0]], [-a[1], a[0], 0]])
    return np.eye(3) * c + s * K + (1 - c) * np.outer(a, a)


def pose(m, steerDeg=12, crankDeg=30):
    """The model's triangles, its groups placed the way preview.py places them:
    (points (n,3), normals (n,3), material name per vertex)."""
    k, A, Nn = m["k"], m["A"], m["N"]
    FR = dict(bb=np.array([-4.5, 0, 2.5]) * k, headB=np.array([14.5, 0, 10.5]) * k,
              rear=np.array([-19.5, 0, 0]) * k, front=np.array([19.5, 0, 0]) * k)
    for key in FR:
        if key in A:
            FR[key] = A[key]
    CRANK = Nn.get("crank", 6.8 * k)
    PEDALY = Nn.get("pedalY", (3.4 + 1.8) * k)
    AT = {}
    for key, v in A.items():
        if key.startswith("at."):
            AT.setdefault(key.split(".")[1], []).append(v)
    Rsteer = rotm(m["steer"], -math.radians(steerDeg))
    crank = math.radians(crankDeg)
    Ry = lambda a: rotm(np.array([0, 1.0, 0]), a)

    def xf(g):
        if g in AT:
            return [(np.eye(3), t) for t in AT[g]]
        if g in ("fork", "bars", "bellLever", "forkLower"):
            return [(Rsteer, FR["headB"] - Rsteer @ FR["headB"])]
        if g == "wheelF":
            return [(Rsteer @ Ry(0.4), Rsteer @ (FR["front"] - FR["headB"]) + FR["headB"])]
        if g == "wheelR":
            return [(Ry(0.9), FR["rear"])]
        if g == "cranks":
            R = Ry(crank)
            out = [(R, FR["bb"] - R @ FR["bb"])]
            if "bb2" in A:
                out.append((R, A["bb2"] - R @ FR["bb"]))
            return out
        if g == "pedal":
            out = []
            for c in [FR["bb"]] + ([A["bb2"]] if "bb2" in A else []):
                for s, d in ((-1, 1), (1, -1)):
                    tip = c + Ry(crank) @ np.array([CRANK * d, 0, 0])
                    out.append((np.eye(3), tip + np.array([0, PEDALY * s, 0])))
            return out
        return [(np.eye(3), np.zeros(3))]

    P, N, M = [], [], []
    for g, mat, arr in m["buckets"]:
        for R, t in xf(g):
            P.append(arr[:, :3] @ R.T + t)
            N.append(arr[:, 3:] @ R.T)
            M.extend([mat] * len(arr))
    P = np.concatenate(P); N = np.concatenate(N)
    # stand it on the floor, centred on its own footprint
    lo, hi = P.min(0), P.max(0)
    shift = np.array([(lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2, lo[2]])
    return P - shift, N, M, shift


def yawed(P, N, yawDeg, at):
    a = math.radians(yawDeg)
    R = np.array([[math.cos(a), -math.sin(a), 0], [math.sin(a), math.cos(a), 0], [0, 0, 1.0]])
    return P @ R.T + np.array([at[0], at[1], 0.0]), N @ R.T


# ---- the rasteriser ----
def project(Pw, cam):
    rel = Pw - cam["eye"]
    x = rel @ cam["right"]; y = rel @ cam["up"]; z = rel @ cam["fwd"]
    w, h = cam["w"], cam["h"]
    if cam.get("ortho"):
        return w / 2 + x * cam["ortho"], h / 2 - y * cam["ortho"], z
    return w / 2 + x * cam["f"] / z, h / 2 - y * cam["f"] / z, z


def raster(T, cam, attrs=True, tiles=(4, 8, 16, 32, 64), budget=6000000):
    """Depth (and triangle id and perspective-correct barycentrics) per pixel.
    Triangles go through in bulk by the size of their box on screen (a spoke is
    thin but long, so its box is not small); the few bigger than the largest
    class go one at a time, the way preview.py does them all."""
    w, h = cam["w"], cam["h"]
    n = len(T)
    # Depth is linear across the screen under an orthographic camera (the sun's),
    # and only its reciprocal is under a perspective one.
    ortho = bool(cam.get("ortho"))
    sx, sy, z = project(T.reshape(-1, 3), cam)
    sx = sx.reshape(n, 3); sy = sy.reshape(n, 3); z = z.reshape(n, 3)
    zb = np.full(h * w, np.inf)
    ib = np.full(h * w, -1, np.int64)
    bw = np.zeros((h * w, 3)) if attrs else None
    ok = (z > 0.5).all(1)
    x0 = np.maximum(0, np.floor(sx.min(1))).astype(np.int64)
    x1 = np.minimum(w - 1, np.ceil(sx.max(1))).astype(np.int64)
    y0 = np.maximum(0, np.floor(sy.min(1))).astype(np.int64)
    y1 = np.minimum(h - 1, np.ceil(sy.max(1))).astype(np.int64)
    ax, ay, bx, by, cx, cy = sx[:, 0], sy[:, 0], sx[:, 1], sy[:, 1], sx[:, 2], sy[:, 2]
    area = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
    ok &= (x1 >= x0) & (y1 >= y0) & (np.abs(area) > 1e-9)
    span = np.maximum(x1 - x0, y1 - y0) + 1
    small = ok & (span <= tiles[-1])

    zb2 = zb.reshape(h, w); ib2 = ib.reshape(h, w)
    bw2 = bw.reshape(h, w, 3) if attrs else None
    for t in np.nonzero(ok & ~small)[0]:
        xs = np.arange(x0[t], x1[t] + 1) + 0.5
        ys = np.arange(y0[t], y1[t] + 1) + 0.5
        X, Y = np.meshgrid(xs, ys)
        w0 = ((bx[t] - X) * (cy[t] - Y) - (by[t] - Y) * (cx[t] - X)) / area[t]
        w1 = ((cx[t] - X) * (ay[t] - Y) - (cy[t] - Y) * (ax[t] - X)) / area[t]
        w2 = 1 - w0 - w1
        msk = (w0 >= -1e-6) & (w1 >= -1e-6) & (w2 >= -1e-6)
        if not msk.any():
            continue
        zz = (w0 * z[t, 0] + w1 * z[t, 1] + w2 * z[t, 2]) if ortho else 1 / (w0 / z[t, 0] + w1 / z[t, 1] + w2 / z[t, 2])
        sub = zb2[y0[t]:y1[t] + 1, x0[t]:x1[t] + 1]
        msk &= zz < sub
        if not msk.any():
            continue
        sub[msk] = zz[msk]
        ib2[y0[t]:y1[t] + 1, x0[t]:x1[t] + 1][msk] = t
        if attrs:
            bsub = bw2[y0[t]:y1[t] + 1, x0[t]:x1[t] + 1]
            bsub[msk] = np.stack([w0[msk] / z[t, 0] * zz[msk], w1[msk] / z[t, 1] * zz[msk],
                                  w2[msk] / z[t, 2] * zz[msk]], -1)

    batches = []
    prev = 0
    for tile in tiles:
        cls = np.nonzero(ok & (span > prev) & (span <= tile))[0]
        chunk = max(256, budget // (tile * tile))
        batches += [(tile, cls[s:s + chunk]) for s in range(0, len(cls), chunk)]
        prev = tile
    for tile, idx in batches:
        off = np.arange(tile)
        c = len(idx)
        X = np.broadcast_to(x0[idx][:, None, None] + off[None, None, :], (c, tile, tile))
        Y = np.broadcast_to(y0[idx][:, None, None] + off[None, :, None], (c, tile, tile))
        Xc, Yc = X + 0.5, Y + 0.5
        e = lambda v: v[idx][:, None, None]
        A_ = e(area)
        w0 = ((e(bx) - Xc) * (e(cy) - Yc) - (e(by) - Yc) * (e(cx) - Xc)) / A_
        w1 = ((e(cx) - Xc) * (e(ay) - Yc) - (e(cy) - Yc) * (e(ax) - Xc)) / A_
        w2 = 1 - w0 - w1
        msk = (X <= e(x1)) & (Y <= e(y1)) & (w0 >= -1e-6) & (w1 >= -1e-6) & (w2 >= -1e-6)
        ti, yi, xi = np.nonzero(msk)
        if not len(ti):
            continue
        tri = idx[ti]
        W0, W1, W2 = w0[ti, yi, xi], w1[ti, yi, xi], w2[ti, yi, xi]
        z0, z1, z2 = z[tri, 0], z[tri, 1], z[tri, 2]
        zz = (W0 * z0 + W1 * z1 + W2 * z2) if ortho else 1 / (W0 / z0 + W1 / z1 + W2 / z2)
        pix = Y[ti, yi, xi] * w + X[ti, yi, xi]
        order = np.lexsort((zz, pix))                 # nearest fragment first, per pixel
        ps = pix[order]
        first = np.ones(len(ps), bool)
        first[1:] = ps[1:] != ps[:-1]
        sel = order[first]
        win = zz[sel] < zb[pix[sel]]
        sel = sel[win]
        p = pix[sel]
        zb[p] = zz[sel]
        ib[p] = tri[sel]
        if attrs:
            bw[p] = np.stack([W0[sel] / z0[sel] * zz[sel], W1[sel] / z1[sel] * zz[sel],
                              W2[sel] / z2[sel] * zz[sel]], -1)
    return zb2, ib2, bw2


# ---- the camera ----
def look(target, az, el, dist, w, h, fov):
    d = np.array([math.cos(math.radians(el)) * math.cos(math.radians(az)),
                  math.cos(math.radians(el)) * math.sin(math.radians(az)),
                  math.sin(math.radians(el))])
    eye = target + d * dist
    fwd = target - eye; fwd /= np.linalg.norm(fwd)
    right = np.cross(fwd, [0, 0, 1.0]); right /= np.linalg.norm(right)
    up = np.cross(right, fwd)
    return dict(eye=eye, fwd=fwd, right=right, up=up, w=w, h=h,
                f=(w / 2) / math.tan(math.radians(fov) / 2))


def fit_camera(pts, target, az, el, w, h, fov, fill):
    """The distance at which every point in `pts` sits inside `fill` of the frame."""
    lo, hi = 1.0, 1e5
    for _ in range(50):
        mid = math.sqrt(lo * hi)
        cam = look(target, az, el, mid, w, h, fov)
        sx, sy, z = project(pts, cam)
        inside = (z > 1).all() and (np.abs(sx - w / 2) <= w / 2 * fill).all() and (np.abs(sy - h / 2) <= h / 2 * fill).all()
        if inside:
            hi = mid
        else:
            lo = mid
    return hi


# ---- a frame: raster, shadow, shade ----
def gbuffer(T, TN, TM, cam, sun, ground_r, centre):
    h, w = cam["h"], cam["w"]
    zb, ib, bw = raster(T, cam)
    geo = ib >= 0
    # The floor is z = 0, solved per pixel rather than drawn: a quad big enough
    # to reach the horizon has corners behind the camera, and the rasteriser
    # drops any triangle that does. Everything stands on the floor, so a pixel
    # that hits a model hits it before the floor.
    POS = np.zeros((h, w, 3)); NRM = np.zeros((h, w, 3)); MID = np.full((h, w), -2, np.int64)
    t = ib[geo]
    b = bw[geo]
    gp = (T[t] * b[..., None]).sum(1)
    gn = (TN[t] * b[..., None]).sum(1)
    gn /= np.linalg.norm(gn, axis=1, keepdims=True) + 1e-9
    POS[geo] = gp; NRM[geo] = gn; MID[geo] = TM[t]
    ys, xs = np.nonzero(~geo)
    d = cam["fwd"][None, :] * cam["f"] + np.outer(xs + 0.5 - w / 2, cam["right"]) - np.outer(ys + 0.5 - h / 2, cam["up"])
    down = d[:, 2] < -1e-9
    ys, xs, d = ys[down], xs[down], d[down]
    POS[ys, xs] = cam["eye"] + d * (-cam["eye"][2] / d[:, 2])[:, None]
    NRM[ys, xs] = (0, 0, 1.0)
    MID[ys, xs] = -1
    # shadow map, orthographic from the sun, over the scene
    c = centre
    SW = 3072
    ext = ground_r * 1.25
    s_eye = np.array([c[0], c[1], 0]) + sun * 400
    s_fwd = -sun
    s_right = np.cross(s_fwd, [0, 0, 1.0]); s_right /= np.linalg.norm(s_right)
    s_up = np.cross(s_right, s_fwd)
    scam = dict(eye=s_eye, fwd=s_fwd, right=s_right, up=s_up, w=SW, h=SW, ortho=SW / (2 * ext))
    szb, _, _ = raster(T, scam, attrs=False)
    hit = MID != -2
    pos = POS[hit]; nrm = NRM[hit]
    vdir = cam["eye"] - pos
    vdir /= np.linalg.norm(vdir, axis=1, keepdims=True)
    nrm[(nrm * vdir).sum(1) < 0] *= -1
    # soft shadow: 3 x 3 taps
    sx, sy, sz = project(pos, scam)
    lit = np.zeros(len(pos))
    texel = 2 * ext / SW                          # a big scene has big texels: bias by them, or flat faces stripe
    bias = 0.35 + 1.5 * texel * (1 + np.sqrt(np.clip(1 - (nrm * sun).sum(1) ** 2, 0, 1)) * 2)
    for dx in (-1.5, 0, 1.5):
        for dy in (-1.5, 0, 1.5):
            xi = np.clip((sx + dx).astype(int), 0, SW - 1)
            yi = np.clip((sy + dy).astype(int), 0, SW - 1)
            lit += sz <= szb[yi, xi] + bias
    lit /= 9
    return dict(hit=hit, pos=pos, nrm=nrm, vdir=vdir, mid=MID[hit], lit=lit)


def shade(gb, names, mats, cam, sun, centre, ground_r):
    h, w = cam["h"], cam["w"]
    yy = np.linspace(0, 1, h)[:, None]
    bg = np.array([0.80, 0.83, 0.88]) * (1 - yy[..., None] * 0.30)
    img = np.broadcast_to(bg, (h, w, 3)).copy()
    nrm, vdir, mid, lit, pos = gb["nrm"], gb["vdir"], gb["mid"], gb["lit"], gb["pos"]
    n = len(mid)
    base = np.zeros((n, 3)); spec = np.zeros(n); expo = np.ones(n); refl = np.zeros(n)
    for i, k in enumerate(names):
        m = mid == i
        if m.any():
            c, sp, ex, rf = mats[k]
            base[m] = c; spec[m] = sp; expo[m] = ex; refl[m] = rf
    g = mid < 0
    base[g] = GROUND; spec[g] = 0.02; expo[g] = 4
    ndl = np.clip((nrm * sun).sum(1), 0, 1)
    hemi = 0.5 + 0.5 * nrm[:, 2]
    amb = 0.34 * hemi + 0.13
    hv = sun + vdir; hv /= np.linalg.norm(hv, axis=1, keepdims=True)
    sp = spec * np.clip((nrm * hv).sum(1), 0, 1) ** expo * lit
    diff = base * (amb[:, None] + 1.05 * (ndl * lit)[:, None])
    rv = 2 * (nrm * vdir).sum(1, keepdims=True) * nrm - vdir
    env = np.where(rv[:, 2:3] > 0, np.array([0.75, 0.82, 0.95]) * (0.6 + 0.4 * rv[:, 2:3]),
                   np.array([0.28, 0.27, 0.25]) * (1 + rv[:, 2:3] * 0.6))
    fres = 0.25 + 0.75 * (1 - np.clip((nrm * vdir).sum(1), 0, 1)) ** 4
    col = diff * (1 - refl[:, None]) + env * (refl * (0.6 + 0.4 * fres))[:, None] + sp[:, None]
    if "paint" in names:
        pm = mid == names.index("paint")
        col[pm] += env[pm] * (0.12 * fres[pm])[:, None]
    # the floor fades into the backdrop, a studio sweep with no edge
    d = np.linalg.norm(pos[:, :2] - np.array(centre[:2]), axis=1)
    fade = np.clip((d - ground_r * 1.1) / (ground_r * 1.6), 0, 1)[:, None]
    fade = fade * fade * (3 - 2 * fade)
    fade[~g] = 0
    bgpix = img[gb["hit"]]
    col = col * (1 - fade) + bgpix * fade
    img[gb["hit"]] = col
    return np.clip(img, 0, 1) ** (1 / 1.1)


# ---- labels ----
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"


def font(px):
    try:
        return ImageFont.truetype(FONT, px)
    except OSError:
        return ImageFont.load_default()


def pill(draw, cx, cy, text, px):
    f = font(px)
    x0, y0, x1, y1 = draw.textbbox((0, 0), text, font=f)
    tw, th = x1 - x0, y1 - y0
    pw, ph = tw + px * 1.1, th + px * 0.75
    box = (cx - pw / 2, cy - ph / 2, cx + pw / 2, cy + ph / 2)
    draw.rounded_rectangle(box, radius=ph / 2, fill=(27, 40, 56, 225))
    draw.text((cx - tw / 2 - x0, cy - th / 2 - y0), text, font=f, fill=(236, 240, 244, 255))


def annotate(im, labels, caption, W, H):
    if not labels and not caption:
        return im
    over = Image.new("RGBA", im.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(over)
    px = max(12, round(H * 0.026))
    for x, y, text in labels:
        pill(d, min(max(x, px * 4), W - px * 4), y, text, px)
    if caption:                                  # a dark bar, readable over any picture
        cpx = max(14, round(H * 0.03))
        f = font(cpx)
        x0, y0, x1, y1 = d.textbbox((0, 0), caption, font=f)
        bx, by = round(W * 0.025), round(H * 0.035)
        padx, pady = cpx * 0.7, cpx * 0.45
        d.rounded_rectangle((bx, by, bx + (x1 - x0) + 2 * padx, by + (y1 - y0) + 2 * pady),
                            radius=cpx * 0.4, fill=(27, 40, 56, 215))
        d.text((bx + padx - x0, by + pady - y0), caption, font=f, fill=(236, 240, 244, 255))
    return Image.alpha_composite(im.convert("RGBA"), over).convert("RGB")


# ---- the scene ----
def build_scene(spec, base_dir, cache, spin=0.0):
    names = list(MAT.keys())
    mats = dict(MAT)
    T, TN, TM, items = [], [], [], []
    for md in spec["models"]:
        path = os.path.join(base_dir, md["file"])
        key = (path, md.get("steer", 12), md.get("crank", 30))
        if key not in cache:
            mdl = load(path)
            P, N, M, shift = pose(mdl, md.get("steer", 12), md.get("crank", 30))
            cache[key] = (P, N, M, mdl["mats"], {k: v - shift for k, v in mdl["A"].items()})
        P, N, M, own, anchors = cache[key]
        for k, c in own.items():
            if k not in mats:
                mats[k] = (c, 0.08, 12, 0.02)
                names.append(k)
        mname = "paint"
        if md.get("paint") is not None:
            mname = "paint:" + json.dumps(md["paint"])
            if mname not in mats:
                mats[mname] = (paint_rgb(md["paint"]),) + MAT["paint"][1:]
                names.append(mname)
        at = md.get("at", [0, 0])
        Pw, Nw = yawed(P, N, md.get("yaw", 0) + spin, at)
        idx = np.array([names.index(mname if x == "paint" else x) for x in M[::3]])
        T.append(Pw.reshape(-1, 3, 3)); TN.append(Nw.reshape(-1, 3, 3)); TM.append(idx)
        r = np.linalg.norm(P[:, :2], axis=1).max()
        a = math.radians(md.get("yaw", 0) + spin)
        Rz = np.array([[math.cos(a), -math.sin(a), 0], [math.sin(a), math.cos(a), 0], [0, 0, 1.0]])
        items.append(dict(at=at, r=r, top=P[:, 2].max(), label=md.get("label"), above=md.get("label_above", False), P=Pw,
                          anchors={k: Rz @ v + np.array([at[0], at[1], 0]) for k, v in anchors.items()}))
    return np.concatenate(T), np.concatenate(TN), np.concatenate(TM), names, mats, items


def render(spec, base_dir, out):
    W, H = spec.get("size", [1280, 720])
    SS = spec.get("ss", 2)
    w, h = W * SS, H * SS
    camspec = spec.get("camera", {})
    az, el = camspec.get("az", -53), camspec.get("el", 16)
    fov = camspec.get("fov", 34)
    fill = camspec.get("fit", 0.9)
    sun = np.array(spec.get("sun", [0.45, -0.35, 0.82]), float); sun /= np.linalg.norm(sun)
    cache = {}
    turn = spec.get("turntable")
    frames = turn["frames"] if turn else 1
    step = (turn.get("degrees", 360) / frames) if turn else 0

    # frame the scene once, for every spin it will show
    T, TN, TM, names, mats, items = build_scene(spec, base_dir, cache)
    pts = []
    for it in items:
        if turn:
            for a in np.linspace(0, 2 * math.pi, 24, endpoint=False):
                for zz in (0, it["top"]):
                    pts.append([it["at"][0] + it["r"] * math.cos(a), it["at"][1] + it["r"] * math.sin(a), zz])
        else:
            pts.extend(it["P"][::7].tolist())
    pts = np.array(pts)
    lo, hi = pts.min(0), pts.max(0)
    centre = (lo + hi) / 2
    ground_r = max(hi[0] - lo[0], hi[1] - lo[1]) / 2 + 10
    target = np.array(camspec.get("target", [centre[0], centre[1], (hi[2] - lo[2]) * camspec.get("lift", 0.42)]), float)
    if camspec.get("anchor"):                    # aim at a named part: {"model": 0, "name": "bb", "offset": [x, y, z]}
        an = camspec["anchor"]
        target = items[an.get("model", 0)]["anchors"][an["name"]] + np.array(an.get("offset", [0, 0, 0]), float)
    dist = camspec.get("dist") or fit_camera(pts, target, az, el, w, h, fov, fill)
    cam = look(target, az, el, dist, w, h, fov)

    labels_on = spec.get("labels", False)
    images = []
    for fi in range(frames):
        if fi:
            T, TN, TM, names, mats, items = build_scene(spec, base_dir, cache, spin=fi * step)
        gb = gbuffer(T, TN, TM, cam, sun, ground_r, centre)
        img = shade(gb, names, mats, cam, sun, centre, ground_r)
        im = Image.fromarray((img * 255).astype(np.uint8)).resize((W, H), Image.LANCZOS)
        labels = []
        if labels_on:
            for it in items:
                if it["label"] and it["above"]:          # over the top of it (a back row)
                    sx, sy, _ = project(np.array([[it["at"][0], it["at"][1], it["top"]]]), cam)
                    labels.append((sx[0] / SS, max(H * 0.05, sy[0] / SS - H * 0.06), it["label"]))
                elif it["label"]:
                    sx, sy, _ = project(np.array([[it["at"][0], it["at"][1], 0.0]]), cam)
                    labels.append((sx[0] / SS, min(H - H * 0.05, sy[0] / SS + H * 0.075), it["label"]))
        images.append(annotate(im, labels, spec.get("caption"), W, H))
        print("frame %d/%d" % (fi + 1, frames), flush=True)
    save(images, out, turn)


def render_paints(spec, base_dir, out):
    """One model, rastered once and shaded in every palette paint, on a grid."""
    ps = spec["paints"]
    W, H = spec.get("size", [1280, 720])
    SS = spec.get("ss", 2)
    cols, rows = ps.get("cols", 4), ps.get("rows", 4)
    tw, th = W // cols, H // rows
    w, h = tw * SS, th * SS
    camspec = spec.get("camera", {})
    az, el, fov = camspec.get("az", -90), camspec.get("el", 8), camspec.get("fov", 30)
    sun = np.array(spec.get("sun", [0.45, -0.35, 0.82]), float); sun /= np.linalg.norm(sun)
    one = dict(spec, models=[dict(ps["model"], paint=None)])
    T, TN, TM, names, mats, items = build_scene(one, base_dir, {})
    P = items[0]["P"]
    lo, hi = P.min(0), P.max(0)
    centre = (lo + hi) / 2
    ground_r = max(hi[0] - lo[0], hi[1] - lo[1]) / 2 + 10
    target = np.array([centre[0], centre[1], (hi[2] - lo[2]) * 0.5])
    cam = look(target, az, el, fit_camera(P[::7], target, az, el, w, h, fov, camspec.get("fit", 0.82)), w, h, fov)
    gb = gbuffer(T, TN, TM, cam, sun, ground_r, centre)
    sheet = Image.new("RGB", (W, H), (205, 211, 220))
    d = None
    order = list(PALETTE)
    slots = [(r, c) for r in range(rows) for c in range(cols)]
    title = ps.get("title")
    if title:
        slots = slots[:-2]                         # the last two cells hold the title
    for (r, c), name in zip(slots, order):
        m = dict(mats)
        m["paint"] = (paint_rgb(name),) + MAT["paint"][1:]
        img = shade(gb, names, m, cam, sun, centre, ground_r)
        tile = Image.fromarray((img * 255).astype(np.uint8)).resize((tw, th), Image.LANCZOS)
        tile = annotate(tile, [(tw / 2, th - th * 0.11, name)], None, tw, th)
        sheet.paste(tile, (c * tw, r * th))
        print("paint", name, flush=True)
    if title:
        d = ImageDraw.Draw(sheet)
        x0, y0 = (cols - 2) * tw, (rows - 1) * th
        d.rectangle((x0, y0, W, H), fill=(27, 40, 56))
        f1, f2 = font(round(th * 0.2)), font(round(th * 0.11))
        d.text((x0 + tw * 0.12, y0 + th * 0.28), title[0], font=f1, fill=(236, 240, 244))
        if len(title) > 1:
            d.text((x0 + tw * 0.12, y0 + th * 0.56), title[1], font=f2, fill=(150, 170, 190))
    save([sheet], out, None)


GIF_BUDGET = 1000 * 1000                         # Steam refuses a preview of 1 MB or more


def save_gif(images, out, ms, budget=GIF_BUDGET):
    """One palette for every frame, so the GIF stores only what changes; then
    cheaper settings, one step at a time, until it fits Steam's limit."""
    ladder = [(255, Image.Dither.FLOYDSTEINBERG, 1.0), (255, Image.Dither.NONE, 1.0),
              (160, Image.Dither.NONE, 1.0), (112, Image.Dither.NONE, 1.0),
              (112, Image.Dither.NONE, 0.875), (96, Image.Dither.NONE, 0.75)]
    for colors, dither, scale in ladder:
        ims = images if scale == 1.0 else [im.resize((round(im.width * scale), round(im.height * scale)), Image.LANCZOS)
                                           for im in images]
        strip = Image.new("RGB", (ims[0].width, ims[0].height * min(len(ims), 6)))
        for i, im in enumerate(ims[::max(1, len(ims) // 6)][:6]):
            strip.paste(im, (0, i * ims[0].height))
        pal = strip.quantize(colors=colors, method=Image.Quantize.MEDIANCUT)
        frames = [im.quantize(palette=pal, dither=dither) for im in ims]
        frames[0].save(out, save_all=True, append_images=frames[1:], loop=0, duration=ms, optimize=True, disposal=1)
        if os.path.getsize(out) < budget:
            break
    print("gif: %d colours, %s, %dx%d" % (colors, "dithered" if dither else "flat", frames[0].width, frames[0].height))


def save(images, out, turn):
    if out.lower().endswith(".gif"):
        save_gif(images, out, (turn or {}).get("ms", 80))
    elif out.lower().endswith((".jpg", ".jpeg")):
        images[0].save(out, quality=90, optimize=True, progressive=True, subsampling=0)
    else:
        images[0].save(out, optimize=True)
    print("wrote", out, os.path.getsize(out), "bytes")


if __name__ == "__main__":
    if sys.argv[1] == "--refit":                 # showcase.py --refit in.gif out.gif: re-encode a GIF to fit
        g = Image.open(sys.argv[2])
        ims = []
        for i in range(g.n_frames):
            g.seek(i)
            ims.append(g.convert("RGB"))
        save_gif(ims, sys.argv[3], g.info.get("duration", 80))
        print("wrote", sys.argv[3], os.path.getsize(sys.argv[3]), "bytes")
        sys.exit(0)
    scene_path, out = sys.argv[1], sys.argv[2]
    spec = json.load(open(scene_path))
    for a in sys.argv[3:]:                       # quick looks: ss=1 size=640x360 frames=4
        k, v = a.split("=")
        if k == "ss":
            spec["ss"] = int(v)
        elif k == "size":
            spec["size"] = [int(x) for x in v.split("x")]
        elif k == "frames" and spec.get("turntable"):
            spec["turntable"]["frames"] = int(v)
    base = os.path.dirname(os.path.abspath(scene_path))
    if spec.get("paints"):
        render_paints(spec, base, out)
    else:
        render(spec, base, out)
