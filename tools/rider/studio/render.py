"""tools/rider/studio/render.py -- draw studio.lua's shots: kleiner's own mesh (the .mdl,
.vvd and .dx90.vtx that fetch_model.py copies from a GMod install) skinned on the
exported bones, the vehicle's built model as it was drawn, and a floor, from a few
cameras round the rider; one row a shot, one column a camera, hands in orange.

   python3 render.py shots.json out.png [shots] [scale]

`shots`: comma-separated parts of the labels to draw (all of them if empty); STUDIO_VIEWS
picks cameras the same way (front, side, back, high, R hand, L hand). The triangles go
through raster.c (studio.sh builds it), a plain z-buffer: flat shading, no textures."""
import json, sys, os, subprocess, struct
import numpy as np
from PIL import Image, ImageDraw, ImageFont
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mdl

MODEL = os.environ.get('STUDIO_MODEL', os.path.join(HERE, '.model', 'kleiner'))
RASTER = os.path.join(HERE, '.build', 'raster')
M = mdl.load(MODEL)
NAMES = [b[0] for b in M['bones']]
P2B = np.array([np.vstack([b[2], [0, 0, 0, 1]]) for b in M['bones']])   # model -> bone at bind
# colour by the dominant bone: hands and fingers stand out
dom = M['bi'][np.arange(len(M['bi'])), np.argmax(M['w'], 1)]
SKIN = np.array([230, 190, 160]); CLOTH = np.array([150, 150, 160]); HAND = np.array([240, 140, 60])
SHIRT = np.array([200, 205, 215]); TROUS = np.array([110, 100, 85]); SHOE = np.array([60, 50, 45])
vcol = np.tile(CLOTH, (len(dom), 1))
for i, n in enumerate(NAMES):
    sel = dom == i
    if 'Hand' in n or 'Finger' in n: vcol[sel] = HAND
    elif 'Head' in n or 'Neck' in n: vcol[sel] = SKIN
    elif 'Spine' in n or 'Clavicle' in n or 'Arm' in n or 'Forearm' in n: vcol[sel] = SHIRT
    elif 'Thigh' in n or 'Calf' in n or 'Pelvis' in n: vcol[sel] = TROUS
    elif 'Foot' in n or 'Toe' in n: vcol[sel] = SHOE
TCOL = vcol[M['tris']].mean(1).astype(np.uint8)

MATCOL = {'frame': (40, 90, 200), 'tyre': (30, 30, 32), 'rubber': (30, 30, 32), 'chrome': (190, 195, 205),
          'grip': (35, 35, 38), 'metal': (150, 155, 165), 'seat': (25, 25, 28)}

def bone_mats(bones):
    out = np.zeros((len(NAMES), 4, 4))
    for i, n in enumerate(NAMES):
        b = bones.get(n)
        if b is None:
            out[i] = np.eye(4); continue
        t, f, l, u = b[0:3], b[3:6], b[6:9], b[9:12]
        out[i, :3, 0], out[i, :3, 1], out[i, :3, 2], out[i, :3, 3] = f, l, u, t
        out[i, 3, 3] = 1
    return out

def skin(bones):
    BW = bone_mats(bones) @ P2B                       # bind model space -> world
    v = np.hstack([M['pos'], np.ones((len(M['pos']), 1))])
    out = np.zeros((len(v), 3))
    for k in range(3):
        Mk = BW[M['bi'][:, k]]                        # (n,4,4)
        out += M['w'][:, k:k+1] * np.einsum('nij,nj->ni', Mk, v)[:, :3]
    return out[M['tris']]                             # (ntri,3,3)

def vehicle(shot, meshes):
    tris, cols = [], []
    for d in shot['drawn']:
        p = meshes[d['mesh'] - 1]
        if not p: continue
        a = np.array(p).reshape(-1, 3)
        a = a[: len(a) // 3 * 3]
        m = np.array(d['m']).reshape(3, 4)
        w = a @ m[:, :3].T + m[:, 3]
        tris.append(w.reshape(-1, 3, 3))
        mat = d['mat'].lower()
        c = next((v for k, v in MATCOL.items() if k in mat), None)
        if c is None:
            c = tuple(int(x) for x in d['paint']) if d.get('paint') and 'paint' in mat else (120, 120, 128)
        cols.append(np.tile(np.array(c, np.uint8), (len(w) // 3, 1)))
    if not tris: return np.zeros((0, 3, 3)), np.zeros((0, 3), np.uint8)
    return np.concatenate(tris), np.concatenate(cols)

def tube_tris(shot):
    tris = []
    for t in shot.get('tubes', []):
        pts = np.array(t['pts'])
        for a, b in zip(pts[:-1], pts[1:]):
            d = b - a
            if np.linalg.norm(d) < 1e-6: continue
            n = np.cross(d, [0, 0, 1]);
            if np.linalg.norm(n) < 1e-6: n = np.cross(d, [1, 0, 0])
            n = n / np.linalg.norm(n) * max(t['r'], 0.15)
            tris += [[a - n, a + n, b + n], [a - n, b + n, b - n]]
    return np.array(tris).reshape(-1, 3, 3)

def ground(center, z, size=160, step=16):
    tris, cols = [], []
    x0, y0 = center[0] - size, center[1] - size
    n = int(2 * size / step)
    for i in range(n):
        for j in range(n):
            a = np.array([x0 + i * step, y0 + j * step, z])
            q = [a, a + [step, 0, 0], a + [step, step, 0], a + [0, step, 0]]
            c = (128, 132, 120) if (i + j) % 2 else (140, 144, 132)
            tris += [[q[0], q[1], q[2]], [q[0], q[2], q[3]]]
            cols += [c, c]
    return np.array(tris), np.array(cols, np.uint8)

def render(tris, cols, cam, at, W=480, H=400, fov=40):
    cam, at = np.array(cam, float), np.array(at, float)
    F = at - cam; F /= np.linalg.norm(F)
    R = np.cross(F, [0, 0, 1]); R /= np.linalg.norm(R)
    U = np.cross(R, F)
    L = np.array([0.4, -0.3, 0.85]); L /= np.linalg.norm(L)
    hdr = struct.pack('<iii', W, H, len(tris)) + np.concatenate([cam, F, R, U, [fov], L]).astype('<f4').tobytes()
    rec = np.zeros(len(tris), dtype=[('v', '<f4', 9), ('c', 'u1', 4)])
    rec['v'] = tris.reshape(-1, 9); rec['c'][:, :3] = cols
    out = subprocess.run([RASTER], input=hdr + rec.tobytes(), capture_output=True).stdout
    i = out.index(b'255\n') + 4
    return Image.frombytes('RGB', (W, H), out[i:])

def main():
    d = json.load(open(sys.argv[1]))
    out = sys.argv[2]
    want = sys.argv[3].split(',') if len(sys.argv) > 3 and sys.argv[3] else None
    scale = float(sys.argv[4]) if len(sys.argv) > 4 else 1.0
    meshes = d['meshes']
    board = d['pose'] in ('board',)
    rows = []
    for s in d['shots']:
        if want and not any(w in s['label'] for w in want): continue
        bt = skin(s['bones'])
        pcols = TCOL
        if s.get('paxBones'):
            bt = np.concatenate([bt, skin(s['paxBones'])]); pcols = np.concatenate([TCOL, TCOL])
        vt, vc = vehicle(s, meshes)
        tt = tube_tris(s)
        e = np.array(s['ent'][:3], float); f = np.array(s['fwd'], float); f[2] = 0; f /= np.linalg.norm(f)
        l = np.array([-f[1], f[0], 0]); up = np.array([0, 0, 1])
        gz = min(bt[:, :, 2].min(), vt[:, :, 2].min() if len(vt) else 1e9) - 0.2
        gt, gc = ground(e, gz)
        tris = np.concatenate([gt, vt, tt, bt]) if len(tt) else np.concatenate([gt, vt, bt])
        cols = np.concatenate([gc, vc, np.tile([90, 90, 90], (len(tt), 1)).astype(np.uint8), pcols]) if len(tt) \
            else np.concatenate([gc, vc, pcols])
        hip = np.array(s['bones']['ValveBiped.Bip01_Pelvis'][:3])
        chest = hip + up * 6
        # Where the rider faces: the pelvis's forward (its Z, [[valvebiped-bone-frames]]),
        # level -- across a board, either way, and the way a bike goes.
        pz = np.array(s['bones']['ValveBiped.Bip01_Pelvis'][9:12], float); pz[2] = 0
        face = pz / np.linalg.norm(pz) if np.linalg.norm(pz) > 1e-3 else (-l if board else f)
        side = np.cross(up, face)          # rider's left
        rh = np.array(s['bones']['ValveBiped.Bip01_R_Hand'][:3]); lh = np.array(s['bones']['ValveBiped.Bip01_L_Hand'][:3])
        V = [('front', chest + face * 130 + up * 8 - side * 25, chest),
             ('side (left)', chest + side * 130 + up * 8, chest),
             ('back 3/4', chest - face * 110 + up * 30 + side * 50, chest),
             ('high', chest + face * 80 - side * 70 + up * 85, chest - up * 8),
             ('R hand', rh + face * 22 - side * 18 + up * 6, rh),
             ('L hand', lh + face * 22 + side * 18 + up * 6, lh)]
        vw = os.environ.get('STUDIO_VIEWS')
        if vw: V = [v for v in V if any(w in v[0] for w in vw.split(','))]
        imgs = [render(tris, cols, c, a, int(480 * scale), int(400 * scale), 42 if 'hand' not in n else 40) for n, c, a in V]
        rows.append((s['label'], [n for n, _, _ in V], imgs))
    if not rows: print('no shots'); return
    w, h = rows[0][2][0].size
    sheet = Image.new('RGB', (w * len(rows[0][2]), (h + 18) * len(rows)), (245, 245, 240))
    dr = ImageDraw.Draw(sheet)
    for r, (label, names, imgs) in enumerate(rows):
        for c, (n, im) in enumerate(zip(names, imgs)):
            sheet.paste(im, (c * w, r * (h + 18) + 18))
            dr.text((c * w + 4, r * (h + 18) + 3), f"{d['id']}: {label} - {n}", fill=(0, 0, 0))
    sheet.save(out)
    print('wrote', out, sheet.size)

if __name__ == '__main__':
    main()
