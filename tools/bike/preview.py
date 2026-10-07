# Software render of the procedural bike, posed, so a change to
# lua/bmx/cl_bikegeo.lua can be looked at without starting the game.
#
#   lua5.1 tools/bike/export.lua > bike.txt
#   python3 tools/bike/preview.py bike.txt out.png [view] [W H] [steer crank]
#
# view: side | front | rear | three | top | close-drive | close-front | low
# Deferred shading: a G-buffer of normal / material / position, then a sun
# with a shadow map, a sky/ground ambient and a fake environment reflection
# per material. Needs numpy and Pillow.
import sys, math
import numpy as np
from PIL import Image

src, out = sys.argv[1], sys.argv[2]
view = sys.argv[3] if len(sys.argv) > 3 else 'three'
W = int(sys.argv[4]) if len(sys.argv) > 4 else 1280
H = int(sys.argv[5]) if len(sys.argv) > 5 else 800
steerDeg = float(sys.argv[6]) if len(sys.argv) > 6 else 12
crankDeg = float(sys.argv[7]) if len(sys.argv) > 7 else 30
SS = 2  # supersampling

# ---- load ----
buckets = []
steerAxis = None
with open(src) as f:
    lines = f.read().split('\n')
i = 0
while i < len(lines):
    l = lines[i]
    if l.startswith('L '):
        p = l.split()
        steerAxis = np.array([float(p[2]), float(p[3]), float(p[4])])
        i += 1
    elif l.startswith('B '):
        _, g, mat, det, n = l.split()
        n = int(n)
        arr = np.array([list(map(float, x.split())) for x in lines[i + 1:i + 1 + n]], np.float64)
        buckets.append((g, mat, det == '1', arr))
        i += 1 + n
    else:
        i += 1

FR = dict(bb=np.array([-4.5, 0, 2.5]), headB=np.array([14.5, 0, 10.5]),
          rear=np.array([-19.5, 0, 0]), front=np.array([19.5, 0, 0]))

def rotm(axis, ang):
    a = axis / np.linalg.norm(axis)
    c, s = math.cos(ang), math.sin(ang)
    K = np.array([[0, -a[2], a[1]], [a[2], 0, -a[0]], [-a[1], a[0], 0]])
    return np.eye(3) * c + s * K + (1 - c) * np.outer(a, a)

steer = math.radians(steerDeg)
crank = math.radians(crankDeg)
Rsteer = rotm(steerAxis, -steer)
Ry = lambda a: rotm(np.array([0, 1.0, 0]), a)

def xf(g):
    # returns list of (R, t): world = R @ p + t
    if g == 'frame':
        return [(np.eye(3), np.zeros(3))]
    if g in ('fork', 'bars'):
        return [(Rsteer, FR['headB'] - Rsteer @ FR['headB'])]
    if g == 'wheelF':
        R = Rsteer @ Ry(0.4)
        return [(R, Rsteer @ (FR['front'] - FR['headB']) + FR['headB'])]
    if g == 'wheelR':
        return [(Ry(0.9), FR['rear'])]
    if g == 'cranks':
        R = Ry(crank)
        return [(R, FR['bb'] - R @ FR['bb'])]
    if g == 'pedal':
        out = []
        for s, d in ((-1, 1), (1, -1)):
            tip = FR['bb'] + Ry(crank) @ np.array([6.8 * d, 0, 0])
            out.append((np.eye(3), tip + np.array([0, (3.4 + 1.8) * s, 0])))
        return out
    return [(np.eye(3), np.zeros(3))]

MAT = {  # base colour, spec strength, spec exponent, reflectivity
    'paint':   ((0.75, 0.08, 0.09), 0.55, 60, 0.10),
    'black':   ((0.045, 0.045, 0.05), 0.35, 30, 0.05),
    'chrome':  ((0.55, 0.57, 0.6), 1.2, 120, 0.75),
    'alloy':   ((0.6, 0.61, 0.63), 0.8, 50, 0.35),
    'steel':   ((0.3, 0.3, 0.32), 0.6, 40, 0.2),
    'rubber':  ((0.03, 0.03, 0.035), 0.08, 10, 0.0),
    'gum':     ((0.55, 0.38, 0.22), 0.08, 10, 0.0),
    'seat':    ((0.04, 0.04, 0.045), 0.25, 18, 0.02),
    'plastic': ((0.06, 0.06, 0.065), 0.2, 16, 0.02),
}
names = list(MAT.keys())

P, N, M = [], [], []
for g, mat, det, arr in buckets:
    for R, t in xf(g):
        p = arr[:, :3] @ R.T + t
        n = arr[:, 3:] @ R.T
        P.append(p); N.append(n); M.append(np.full(len(p), names.index(mat)))
P = np.concatenate(P); N = np.concatenate(N); M = np.concatenate(M)
T = P.reshape(-1, 3, 3); TN = N.reshape(-1, 3, 3); TM = M.reshape(-1, 3)[:, 0]
print('triangles', len(T))

# ---- camera ----
views = {
    'side':        ((0, -1, 0.02), 62, (0, 0, 9)),
    'front':       ((1, -0.2, 0.15), 62, (0, 0, 10)),
    'rear':        ((-1, -0.35, 0.25), 62, (0, 0, 10)),
    'three':       ((0.75, -1, 0.35), 64, (0, 0, 9)),
    'top':         ((0.2, -0.5, 1), 64, (0, 0, 8)),
    'low':         ((0.9, -1, 0.05), 52, (0, 0, 9)),
    'close-drive': ((-0.25, -1, 0.25), 26, (-11, -1.5, 3)),
    'close-front': ((0.8, -1, 0.5), 26, (14, 0, 16)),
    'close-bars':  ((0.6, -1, 0.7), 24, (11, 0, 23)),
    'close-seat':  ((-0.5, -1, 0.6), 22, (-9, 0, 15)),
}
d, dist, tgt = views[view]
d = np.array(d, float); d /= np.linalg.norm(d)
tgt = np.array(tgt, float)
eye = tgt + d * dist * 1.6
fwd = (tgt - eye); fwd /= np.linalg.norm(fwd)
right = np.cross(fwd, [0, 0, 1.0]); right /= np.linalg.norm(right)
up = np.cross(right, fwd)
fov = 40
w, h = W * SS, H * SS
f = (w / 2) / math.tan(math.radians(fov) / 2)

def project(Pw, eye, right, up, fwd, f, w, h, ortho=None):
    rel = Pw - eye
    x = rel @ right; y = rel @ up; z = rel @ fwd
    if ortho:
        sx = w / 2 + x * ortho; sy = h / 2 - y * ortho
    else:
        sx = w / 2 + x * f / z; sy = h / 2 - y * f / z
    return sx, sy, z

def raster(T, w, h, proj, attrs=True):
    sx, sy, z = proj(T.reshape(-1, 3))
    sx = sx.reshape(-1, 3); sy = sy.reshape(-1, 3); z = z.reshape(-1, 3)
    zb = np.full((h, w), np.inf)
    ib = np.full((h, w), -1, np.int64)
    bw = np.full((h, w, 3), 0.0)
    order = np.arange(len(T))
    for t in order:
        if (z[t] < 0.5).any():
            continue
        x0, x1 = int(max(0, math.floor(sx[t].min()))), int(min(w - 1, math.ceil(sx[t].max())))
        y0, y1 = int(max(0, math.floor(sy[t].min()))), int(min(h - 1, math.ceil(sy[t].max())))
        if x1 < x0 or y1 < y0:
            continue
        ax, ay, bx, by, cx, cy = sx[t][0], sy[t][0], sx[t][1], sy[t][1], sx[t][2], sy[t][2]
        area = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
        if abs(area) < 1e-9:
            continue
        xs = np.arange(x0, x1 + 1) + 0.5
        ys = np.arange(y0, y1 + 1) + 0.5
        X, Y = np.meshgrid(xs, ys)
        w0 = ((bx - X) * (cy - Y) - (by - Y) * (cx - X)) / area
        w1 = ((cx - X) * (ay - Y) - (cy - Y) * (ax - X)) / area
        w2 = 1 - w0 - w1
        m = (w0 >= -1e-6) & (w1 >= -1e-6) & (w2 >= -1e-6)
        if not m.any():
            continue
        # perspective-correct depth
        iz = w0 / z[t][0] + w1 / z[t][1] + w2 / z[t][2]
        zz = 1 / iz
        sub = zb[y0:y1 + 1, x0:x1 + 1]
        m &= zz < sub
        if not m.any():
            continue
        sub[m] = zz[m]
        ib[y0:y1 + 1, x0:x1 + 1][m] = t
        if attrs:
            b0 = w0 / z[t][0] * zz; b1 = w1 / z[t][1] * zz; b2 = w2 / z[t][2] * zz
            bsub = bw[y0:y1 + 1, x0:x1 + 1]
            bsub[m] = np.stack([b0[m], b1[m], b2[m]], -1)
    return zb, ib, bw

# ground quad under the tyres
gz = -10.0
G = np.array([[[-80, -60, gz], [80, -60, gz], [80, 60, gz]], [[-80, -60, gz], [80, 60, gz], [-80, 60, gz]]], float)
GN = np.tile(np.array([0, 0, 1.0]), (2, 3, 1))
ALL = np.concatenate([T, G]); ALLN = np.concatenate([TN, GN]); ALLM = np.concatenate([TM, [-1, -1]])

proj = lambda Q: project(Q, eye, right, up, fwd, f, w, h)
zb, ib, bw = raster(ALL, w, h, proj)

# shadow map from the sun (orthographic)
sun = np.array([0.45, -0.35, 0.82]); sun /= np.linalg.norm(sun)
s_eye = np.array([0, 0, 9.0]) + sun * 200
s_fwd = -sun
s_right = np.cross(s_fwd, [0, 0, 1.0]); s_right /= np.linalg.norm(s_right)
s_up = np.cross(s_right, s_fwd)
SW = 2048; scale = SW / 110
sproj = lambda Q: project(Q, s_eye, s_right, s_up, s_fwd, 1, SW, SW, ortho=scale)
szb, _, _ = raster(T, SW, SW, sproj, attrs=False)

# ---- shade ----
img = np.zeros((h, w, 3))
# background: soft studio gradient
yy = np.linspace(0, 1, h)[:, None]
bg = np.array([0.78, 0.82, 0.88]) * (1 - yy[..., None] * 0.35)
img[:] = bg
hit = ib >= 0
t = ib[hit]
b = bw[hit]
pos = (ALL[t] * b[..., None]).sum(1)
nrm = (ALLN[t] * b[..., None]).sum(1)
nrm /= np.linalg.norm(nrm, axis=1, keepdims=True) + 1e-9
vdir = eye - pos; vdir /= np.linalg.norm(vdir, axis=1, keepdims=True)
flip = (nrm * vdir).sum(1) < 0
nrm[flip] *= -1
mid = ALLM[t]
# shadow lookup
sx, sy, sz = sproj(pos)
sxi = np.clip(sx.astype(int), 0, SW - 1); syi = np.clip(sy.astype(int), 0, SW - 1)
lit = sz <= szb[syi, sxi] + 0.35
ndl = np.clip((nrm * sun).sum(1), 0, 1)
hemi = 0.5 + 0.5 * nrm[:, 2]
amb = 0.32 * hemi + 0.12
base = np.zeros((len(t), 3)); spec = np.zeros(len(t)); expo = np.ones(len(t)); refl = np.zeros(len(t))
for k, (c, sp, ex, rf) in MAT.items():
    m = mid == names.index(k)
    base[m] = c; spec[m] = sp; expo[m] = ex; refl[m] = rf
g = mid < 0
base[g] = (0.42, 0.42, 0.4); spec[g] = 0.02; expo[g] = 4
hv = sun + vdir; hv /= np.linalg.norm(hv, axis=1, keepdims=True)
sp = spec * np.clip((nrm * hv).sum(1), 0, 1) ** expo * lit
diff = base * (amb[:, None] + 1.05 * (ndl * lit)[:, None])
# fake environment: reflect vector -> sky gradient with a horizon line
rv = 2 * (nrm * vdir).sum(1, keepdims=True) * nrm - vdir
env = np.where(rv[:, 2:3] > 0, np.array([0.75, 0.82, 0.95]) * (0.6 + 0.4 * rv[:, 2:3]),
               np.array([0.28, 0.27, 0.25]) * (1 + rv[:, 2:3] * 0.6))
fres = 0.25 + 0.75 * (1 - np.clip((nrm * vdir).sum(1), 0, 1)) ** 4
col = diff * (1 - refl[:, None]) + env * (refl * (0.6 + 0.4 * fres))[:, None] + sp[:, None]
# paint gets a clear-coat env sheen
pm = mid == names.index('paint')
col[pm] += env[pm] * (0.12 * fres[pm])[:, None]
img[hit] = col
img = np.clip(img, 0, 1) ** (1 / 1.1)
im = Image.fromarray((img * 255).astype(np.uint8)).resize((W, H), Image.LANCZOS)
im.save(out)
print('wrote', out)
