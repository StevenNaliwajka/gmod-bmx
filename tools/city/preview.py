# Software preview of a city layout: textured, z-buffered, perspective-correct,
# so a change to sh_city_maps.lua can be looked at without starting the game.
#
#   lua5.1 tools/city/export.lua gm_skatepark > layout.json
#   python3 tools/city/preview.py layout.json texdump out.png  X Y Z YAW PITCH [FOV] [W H]
#
# The camera is in Source terms: yaw 0 looks along +x, NEGATIVE pitch looks up.
# `texdump` is a directory made by tools/city/texdump.py (the HL2 textures the
# city uses, as PNGs). Set CITY_PROPS to a JSON list of
# [name, x0, y0, x1, y1, z0, z1] to draw the map's ramps as blocks.
# Needs numpy and Pillow.
import json, sys, math, os
import numpy as np
from PIL import Image

lay = json.load(open(sys.argv[1])); texdir = sys.argv[2]; out = sys.argv[3]
cx, cy, cz, yaw, pitch = map(float, sys.argv[4:9])
fov = float(sys.argv[9]) if len(sys.argv) > 9 else 100
W = int(sys.argv[10]) if len(sys.argv) > 10 else 960
H = int(sys.argv[11]) if len(sys.argv) > 11 else 540

idx = {}
for l in open(texdir + '/index.txt'):
    vmt, vtf, dims, fn = l.rstrip('\n').split('\t')
    idx[vmt[len('materials/'):-4]] = fn
cache = {}
def tex(name, mat):
    if name in cache: return cache[name]
    if mat.get('color'):
        a = np.ones((4, 4, 3), np.float32) * np.array(mat['color'], np.float32)
    else:
        fn = idx.get(name.lower())
        a = np.asarray(Image.open(texdir + '/' + fn).convert('RGB'), np.float32) / 255 if fn else np.ones((4, 4, 3), np.float32) * [1, 0, 1]
    cache[name] = a
    return a

# camera basis (Source: x fwd, y left, z up)
y, p = math.radians(yaw), math.radians(pitch)
fwd = np.array([math.cos(p) * math.cos(y), math.cos(p) * math.sin(y), -math.sin(p)])
left = np.array([-math.sin(y), math.cos(y), 0.0])
up = np.cross(fwd, left)
cam = np.array([cx, cy, cz])
f = (W / 2) / math.tan(math.radians(fov) / 2)

img = np.zeros((H, W, 3), np.float32)
# sky
for r in range(H):
    # direction elevation per row, approximate
    v = (H / 2 - r) / f
    el = math.atan2(v * math.cos(p) - math.sin(p), 1)
    k = max(0, min(1, (el + 0.2) / 1.2))
    img[r] = np.array([0.85, 0.89, 0.95]) * (1 - k) + np.array([0.45, 0.62, 0.9]) * k
zbuf = np.full((H, W), np.inf, np.float32)

def raster(P, UV, shade, texarr, alpha):
    # P: 3x3 world, UV: 3x2
    rel = P - cam
    xs = rel @ (-left); ys = rel @ up; zs = rel @ fwd
    if (zs < 1).any():
        if (zs < 1).all(): return
        # clip: split crudely by dropping (rare: near camera). subdivide instead
        return 'clip'
    sx = W / 2 + f * xs / zs; sy = H / 2 - f * ys / zs
    x0, x1 = int(max(0, math.floor(sx.min()))), int(min(W - 1, math.ceil(sx.max())))
    y0, y1 = int(max(0, math.floor(sy.min()))), int(min(H - 1, math.ceil(sy.max())))
    if x0 > x1 or y0 > y1: return
    gx, gy = np.meshgrid(np.arange(x0, x1 + 1) + 0.5, np.arange(y0, y1 + 1) + 0.5)
    d = (sy[1] - sy[2]) * (sx[0] - sx[2]) + (sx[2] - sx[1]) * (sy[0] - sy[2])
    if abs(d) < 1e-9: return
    l0 = ((sy[1] - sy[2]) * (gx - sx[2]) + (sx[2] - sx[1]) * (gy - sy[2])) / d
    l1 = ((sy[2] - sy[0]) * (gx - sx[2]) + (sx[0] - sx[2]) * (gy - sy[2])) / d
    l2 = 1 - l0 - l1
    m = (l0 >= -1e-4) & (l1 >= -1e-4) & (l2 >= -1e-4)
    if not m.any(): return
    iz = l0 / zs[0] + l1 / zs[1] + l2 / zs[2]
    z = 1 / iz
    u = (l0 * UV[0, 0] / zs[0] + l1 * UV[1, 0] / zs[1] + l2 * UV[2, 0] / zs[2]) * z
    v = (l0 * UV[0, 1] / zs[0] + l1 * UV[1, 1] / zs[1] + l2 * UV[2, 1] / zs[2]) * z
    th, tw = texarr.shape[:2]
    tu = (np.floor((u % 1) * tw).astype(int)) % tw
    tv = (np.floor((v % 1) * th).astype(int)) % th
    col = texarr[tv, tu]
    if alpha:
        m &= col.sum(-1) > 0.08
    zb = zbuf[y0:y1 + 1, x0:x1 + 1]
    m &= z < zb
    zb[m] = z[m]
    img[y0:y1 + 1, x0:x1 + 1][m] = col[m] * shade

def drawquad(q, texarr, alpha, depth=0):
    P = np.array(q[0:12]).reshape(4, 3)
    u1, v1, u2, v2 = q[12:16]
    UV = np.array([[u1, v1], [u2, v1], [u2, v2], [u1, v2]])
    # subdivide big quads so near-plane clipping and precision are fine
    rel = P - cam
    zs = rel @ fwd
    size = np.linalg.norm(P[1] - P[0]) + np.linalg.norm(P[3] - P[0])
    if depth < 6 and ((zs < 1).any() and (zs > 1).any() or size > 0.8 * max(zs.min(), 1) and depth < 4):
        # split into 4
        a, b, c, d_ = P
        ab, dc = (a + b) / 2, (d_ + c) / 2
        ad, bc = (a + d_) / 2, (b + c) / 2
        mid = (a + b + c + d_) / 4
        um, vm = (u1 + u2) / 2, (v1 + v2) / 2
        for (A, B, C, D, uu1, vv1, uu2, vv2) in [(a, ab, mid, ad, u1, v1, um, vm), (ab, b, bc, mid, um, v1, u2, vm),
                                                (mid, bc, c, dc, um, vm, u2, v2), (ad, mid, dc, d_, u1, vm, um, v2)]:
            drawquad(list(A) + list(B) + list(C) + list(D) + [uu1, vv1, uu2, vv2, q[16]], texarr, alpha, depth + 1)
        return
    if (zs < 1).all(): return
    raster(P[[0, 1, 2]], UV[[0, 1, 2]], q[16], texarr, alpha)
    raster(P[[0, 2, 3]], UV[[0, 2, 3]], q[16], texarr, alpha)

mats = lay['materials']
# the map itself: floor, the props as grey blocks
props = json.load(open(os.environ['CITY_PROPS'])) if os.environ.get('CITY_PROPS') else []
def box(x0, y0, z0, x1, y1, z1, sh=0.75):
    return [[x0, y0, z1, x1, y0, z1, x1, y0, z0, x0, y0, z0, 0, 0, 1, 1, sh],
            [x1, y1, z1, x0, y1, z1, x0, y1, z0, x1, y1, z0, 0, 0, 1, 1, sh * 0.9],
            [x0, y1, z1, x0, y0, z1, x0, y0, z0, x0, y1, z0, 0, 0, 1, 1, sh * 0.8],
            [x1, y0, z1, x1, y1, z1, x1, y1, z0, x1, y0, z0, 0, 0, 1, 1, sh * 1.1],
            [x0, y1, z1, x1, y1, z1, x1, y0, z1, x0, y0, z1, 0, 0, 1, 1, 1.0]]
floor = [-256, 768, 64, 3584, 768, 64, 3584, -1792, 64, -256, -1792, 64, 0, 0, 3840 / 128, 2560 / 128, 0.9]
woodtex = np.ones((4, 4, 3), np.float32) * [0.62, 0.5, 0.36]
floortex = tex('concrete/concretefloor008a', {}) if 'concrete/concretefloor008a' in idx else np.ones((4, 4, 3), np.float32) * 0.6
drawquad(floor, floortex, False)
for pr in props:
    for q in box(pr[1], pr[2], pr[5], pr[3], pr[4], pr[6]): drawquad(q, woodtex, False)

for mat, faces in lay['faces'].items():
    m = mats[mat]; ta = tex(m['tex'], m)
    for q in faces: drawquad(q, ta, m['alpha'])
# signs: flat colour panels
for s in lay['signs']:
    n = s['normal']; px, py, pz = s['pos']; w, h = s['w'] / 2, s['h'] / 2
    r = [-n[1], n[0], 0]  # right when facing it? any
    q = [px - r[0] * w, py - r[1] * w, pz + h, px + r[0] * w, py + r[1] * w, pz + h, px + r[0] * w, py + r[1] * w, pz - h, px - r[0] * w, py - r[1] * w, pz - h, 0, 0, 1, 1, 1]
    drawquad(q, np.ones((2, 2, 3), np.float32) * np.array(s['color']) / 255, False)
Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8)).save(out)
print('ok', out)
