"""tools/rider/studio/capsules.py -- the BODY AS CAPSULES, measured off kleiner's own mesh,
for the clipping tests (tests/lib/bodyclip.lua, tests/test_body_clip.lua).

    python3 tools/rider/studio/capsules.py                    # -> tests/data/body_capsules_kleiner.lua
    python3 tools/rider/studio/capsules.py --render out.png   # ...and a picture of them in the skin
    python3 tools/rider/studio/capsules.py --render out.png shots.json [label]
                                                              # posed on a studio.lua shot instead

WHAT A CAPSULE IS. A segment between two points and a radius: everything within the
radius of the segment is inside. Each end is pinned to a bone, as an offset in that
bone's own frame (forward, left, up: what GetBoneMatrix's GetForward, -GetRight and
GetUp are), so the capsule moves with the bones it is pinned to and the clipping test
needs nothing but the posed skeleton to put the body back together.

THE PIECES (each side's mirrored): the pelvis, the belly, the chest and the top of the
chest as four slabs ACROSS the body (a torso is 14 wide and 11 deep: one capsule up the
spine as fat as the torso is wide stuck out of the belly and the back by three units,
so it runs across instead, as wide as the torso and as thick as it is deep), the neck,
the head (upright, chin to crown: along its longest way, which runs from the chin to
the back of the skull, it stood out of the face); each upper arm, forearm, thigh and
shin as two capsules end to end on the joint-to-joint segment (a forearm is twice as
thick at the elbow as at the wrist, a calf than an ankle: one radius for the whole bone
stood out at the thin end or sank in at the thick one), each moved across to the
middle of its sleeve or trouser leg (a leg's bones run nearer the back of the trouser
than its front); the palm (wrist to the middle knuckle), the fingers (the middle
knuckle to the middle fingertip, so a fist's curl is followed), the foot (heel to ball)
and the toes.

THE SKIN of a piece: the triangles of the two skin materials (walter_face and
players_sheet, the face and the clothes; the eyeballs, teeth and glasses are inside the
head or off it, and are left out) two of whose corners have one of the piece's bones as
their strongest weight, sampled every half unit over their area. Not the vertices: the
trouser leg is an eight-sided tube, and the middle of each flat side is a third of a
unit nearer the bone than its corners.

THE RADIUS: the 20th percentile, by area, of the skin's distance from the segment. Four
fifths of the skin is further out than the capsule, so it sits a little INSIDE the skin
(half a unit in, at the median): two limbs side by side, a hand on a thigh, a sole on a
pedal are skin on skin and do not touch, and what the test reports is a part pushed
INTO something. (A radius at the 70th or 80th percentile would stand proud of most of
the skin -- a capsule round the limb, not in it -- and every touch would be a hit.)
`out`: how far the capsule stands proud of the skin where it does, the 95th percentile
over the skin it is the nearest capsule to (0.65 at the most, the top of the chest):
what the test's tolerance has to allow for skin on skin.

Only numbers are written: bone names, offsets, radii. No vertex of Valve's mesh is
committed; the mesh is read from .model/ (fetch_model.py), which git ignores.
"""
import os, sys, struct
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..', '..'))
sys.path.insert(0, HERE)
import mdl

MODEL = os.environ.get('STUDIO_MODEL', os.path.join(HERE, '.model', 'kleiner'))
OUT = os.path.join(ROOT, 'tests', 'data', 'body_capsules_kleiner.lua')
Q = 20                                   # the radius's percentile (header)
SKIN = ('walter_face', 'players_sheet')  # the materials that are skin and clothes
BIP = 'ValveBiped.Bip01_'


def textures(base):
    """The model's material names, in the order the triangles' material indices use."""
    m = open(base + '.mdl', 'rb').read()
    n, idx = struct.unpack_from('<ii', m, 204)
    out = []
    for i in range(n):
        o = idx + i * 64
        ni = struct.unpack_from('<i', m, o)[0]
        out.append(m[o + ni:m.index(b'\0', o + ni)].decode('latin1'))
    return out


class Body:
    def __init__(self, base):
        M = mdl.load(base)
        self.M = M
        self.names = [b[0] for b in M['bones']]
        self.P = M['pos']
        self.dom = M['bi'][np.arange(len(M['bi'])), np.argmax(M['w'], 1)]
        self.P2B = np.array([np.vstack([b[2], [0, 0, 0, 1]]) for b in M['bones']])   # model -> bone
        self.B2M = np.linalg.inv(self.P2B)                                          # bone -> model
        mats = textures(base)
        keep = [i for i, n in enumerate(mats) if n in SKIN]
        self.tskin = np.isin(M['tmat'], keep)

    def bone(self, short):
        return self.names.index(short if short.startswith('ValveBiped') else BIP + short)

    def origin(self, short):
        return self.B2M[self.bone(short)][:3, 3]

    def axis(self, short, k=0):
        """A bone's own axis (0 forward, 1 left, 2 up) in the bind pose's model space."""
        return self.B2M[self.bone(short)][:3, k]

    def surface(self, bones):
        """The skin of these bones as points over its triangles, each with the area it stands
        for: the triangles of the skin materials two of whose three corners have one of the
        bones as their strongest weight, sampled every half unit or so. (Not the vertices:
        the trousers are an eight-sided tube, and the middle of each flat side is a third of
        a unit nearer the bone than its corners. A radius measured on the corners stood
        proud of the cloth all down the legs.)"""
        idx = [self.bone(b) for b in bones]
        T = self.M['tris'][self.tskin]
        own = np.isin(self.dom[T], idx).sum(1) >= 2
        pts, wts = [], []
        for tri in self.P[T[own]]:
            a, b, c = tri
            area = 0.5 * np.linalg.norm(np.cross(b - a, c - a))
            if area < 1e-9:
                continue
            k = max(1, int(np.ceil(max(np.linalg.norm(b - a), np.linalg.norm(c - b), np.linalg.norm(a - c)) / 0.5)))
            bary = np.array([(i, j) for i in range(k + 1) for j in range(k + 1 - i)], float) / k
            p = a + np.outer(bary[:, 0], b - a) + np.outer(bary[:, 1], c - a)
            pts.append(p)
            wts.append(np.full(len(p), area / len(p)))
        return np.concatenate(pts), np.concatenate(wts)

    def local(self, short, p):
        """Model-space point -> offset in the bone's frame."""
        return (self.P2B[self.bone(short)] @ np.append(p, 1.0))[:3]


def seg_dist(P, a, b):
    g = b - a
    gg = g @ g
    t = np.clip(((P - a) @ g) / gg, 0, 1) if gg > 1e-12 else np.zeros(len(P))
    return np.linalg.norm(a + t[:, None] * g - P, axis=1)


def wpct(x, w, q):
    """The q-th percentile of x, each value counting for its weight (its area)."""
    o = np.argsort(x)
    cw = np.cumsum(w[o])
    return float(x[o][np.searchsorted(cw, cw[-1] * q / 100.0)])


def seg_t(P, a, b):
    g = b - a
    return ((P - a) @ g) / (g @ g)


def radius(S, a, b):
    """The radius for the segment a-b over the skin S = (points, areas), how far it stands
    proud of the skin's thinnest tenth, and how much skin (square units) it was measured on."""
    P, w = S
    d = seg_dist(P, a, b)
    r = wpct(d, w, Q)
    return r, r - wpct(d, w, 10), float(w.sum())


def fit_along(S, axis, centre=None):
    """A capsule along `axis` through the skin `P`: centred on the skin's extents (2nd to
    98th percentile, so a stray vertex does not move it), as long as the skin is less a
    radius at each end, the radius the percentile of the distances to that segment."""
    P, w = S
    axis = axis / np.linalg.norm(axis)
    c = centre if centre is not None else P.mean(0)
    s = (P - c) @ axis
    perp = (P - c) - np.outer(s, axis)
    # the centre across the axis: the middle of the perpendicular extents
    e1 = np.cross(axis, [0, 0, 1] if abs(axis[2]) < 0.9 else [1, 0, 0])
    e1 /= np.linalg.norm(e1)
    e2 = np.cross(axis, e1)
    u, v = perp @ e1, perp @ e2
    c = c + e1 * (wpct(u, w, 2) + wpct(u, w, 98)) / 2 + e2 * (wpct(v, w, 2) + wpct(v, w, 98)) / 2
    s = (P - c) @ axis
    lo, hi = wpct(s, w, 2), wpct(s, w, 98)
    mid = (lo + hi) / 2
    half = (hi - lo) / 2
    r = 0.0
    for _ in range(6):
        h = max(0.0, half - r)
        a, b = c + axis * (mid - h), c + axis * (mid + h)
        r, out, n = radius(S, a, b)
    return a, b, r, out, n


def centred(S, a, b):
    """The segment a-b moved across itself to the middle of the skin round it: a leg's bones
    run nearer the back of the trouser leg than its front, and a capsule on the bones stood
    out of the back of the leg and sank into the front."""
    P, w = S
    axis = (b - a) / np.linalg.norm(b - a)
    e1 = np.cross(axis, [0, 0, 1] if abs(axis[2]) < 0.9 else [1, 0, 0])
    e1 /= np.linalg.norm(e1)
    e2 = np.cross(axis, e1)
    q = P - a
    u, v = q @ e1, q @ e2
    off = e1 * (wpct(u, w, 2) + wpct(u, w, 98)) / 2 + e2 * (wpct(v, w, 2) + wpct(v, w, 98)) / 2
    return a + off, b + off


def pca_axis(S):
    P, w = S
    m = (P * w[:, None]).sum(0) / w.sum()
    ev, v = np.linalg.eigh(((P - m) * w[:, None]).T @ (P - m))
    return v[:, np.argmax(ev)]


def sub(S, sel):
    return S[0][sel], S[1][sel]


def build(body):
    pieces = []

    def add(name, part, ab, a, b, r, out, n):
        (ba, bb) = ab
        pieces.append(dict(name=name, part=part, a=(BIP + ba, body.local(ba, a)), b=(BIP + bb, body.local(bb, b)),
                           r=r, out=out, n=n, la=a, lb=b))

    # THE TORSO: slabs across the body, each pinned to the spine bone at its height.
    torso = body.surface(['Pelvis', 'Spine', 'Spine1', 'Spine2', 'Spine4'])
    hipZ = body.origin('R_Thigh')[2]
    for name, bone, zc, band in (('pelvis', 'Pelvis', hipZ, 4.0),
                                 ('belly', 'Spine1', body.origin('Spine1')[2] - 0.5, 4.0),
                                 ('chest', 'Spine2', body.origin('Spine2')[2] + 2.5, 4.0),
                                 ('chest_hi', 'Spine4', body.origin('Spine4')[2], 3.0)):
        S = sub(torso, np.abs(torso[0][:, 2] - zc) <= band)
        a, b, r, out, n = fit_along(S, np.array([1.0, 0, 0]), np.array([0.0, np.median(S[0][:, 1]), zc]))
        # (the slab's height is the band's middle, not the skin's mean: the slabs stack)
        a[2] = b[2] = zc
        r, out, n = radius(S, a, b)
        add(name, name, (bone, bone), a, b, r, out, n)

    # THE NECK, along its bone (its skin is about as long as it is thick: a ball, near
    # enough), and THE HEAD, upright: chin to crown. (Along the head's longest way, which
    # runs from the chin up to the back of the skull, it stood out of the face.)
    Nk = body.surface(['Neck1'])
    a, b, r, out, n = fit_along(Nk, body.origin('Head1') - body.origin('Neck1'))
    add('neck', 'neck', ('Neck1', 'Neck1'), a, b, r, out, n)
    a, b, r, out, n = fit_along(body.surface(['Head1']), np.array([0, 0, 1.0]))
    add('head', 'head', ('Head1', 'Head1'), a, b, r, out, n)

    for S_, s in (('R', 'r'), ('L', 'l')):
        # LIMBS: joint to joint, in two halves with a radius each, pinned to the bone.
        for part, bone, child, skin, names in (
                ('upperarm', 'UpperArm', 'Forearm', ['UpperArm', 'Bicep', 'Elbow', 'Shoulder'], ('shoulder', 'elbow')),
                ('forearm', 'Forearm', 'Hand', ['Forearm', 'Ulna', 'Wrist'], ('elbow', 'wrist')),
                ('thigh', 'Thigh', 'Calf', ['Thigh'], ('hip', 'knee')),
                ('shin', 'Calf', 'Foot', ['Calf'], ('knee', 'ankle'))):
            j0, j1 = body.origin(S_ + '_' + bone), body.origin(S_ + '_' + child)
            Sk = body.surface([S_ + '_' + b for b in skin])
            t = seg_t(Sk[0], j0, j1)
            mid = (j0 + j1) / 2
            for half, (a, b, sel) in enumerate(((j0, mid, t < 0.5), (mid, j1, t >= 0.5))):
                a, b = centred(sub(Sk, sel), a, b)
                r, out, n = radius(sub(Sk, sel), a, b)
                add('%s_%s_%s' % (s, part, names[half]), s + '_' + part, (S_ + '_' + bone, S_ + '_' + bone), a, b, r, out, n)
        # THE PALM: the wrist to the middle finger's knuckle.
        a, b = body.origin(S_ + '_Hand'), body.origin(S_ + '_Finger2')
        r, out, n = radius(body.surface([S_ + '_Hand']), a, b)
        add(s + '_palm', s + '_hand', (S_ + '_Hand', S_ + '_Hand'), a, b, r, out, n)
        # THE FINGERS: the middle knuckle to the middle fingertip (the last bone's skin as
        # far as it goes along it, less a radius), over all four fingers' skin.
        F = body.surface([S_ + '_Finger%d%s' % (f, k) for f in (1, 2, 3, 4) for k in ('', '1', '2')])
        tipB = S_ + '_Finger22'
        o, ax = body.origin(tipB), body.axis(tipB, 0)
        Tp = body.surface([tipB])
        reach = wpct((Tp[0] - o) @ ax, Tp[1], 98)
        a = body.origin(S_ + '_Finger2')
        r = 0.0
        for _ in range(4):
            b = o + ax * max(0.0, reach - r)
            r, out, n = radius(F, a, b)
        add(s + '_fingers', s + '_hand', (S_ + '_Finger2', tipB), a, b, r, out, n)
        # THE FOOT, heel to ball, and THE TOES, along their longest way.
        Ft = body.surface([S_ + '_Foot'])
        a, b, r, out, n = fit_along(Ft, pca_axis(Ft))
        if (b - a) @ body.axis(S_ + '_Foot', 0) < 0:      # (a at the heel, b at the toe)
            a, b = b, a
        add(s + '_foot', s + '_foot', (S_ + '_Foot', S_ + '_Foot'), a, b, r, out, n)
        Tt = body.surface([S_ + '_Toe0'])
        a, b, r, out, n = fit_along(Tt, pca_axis(Tt))
        add(s + '_toes', s + '_foot', (S_ + '_Toe0', S_ + '_Toe0'), a, b, r, out, n)
    return pieces


def proud(body, pieces):
    """How far each capsule stands out of the skin: over the whole skin, each point given to
    the capsule whose surface it is nearest, the 95th percentile of how far that capsule's
    surface is outside it. Sets `out` on each piece."""
    P, w = body.surface(body.names)
    D = np.stack([seg_dist(P, p['la'], p['lb']) - p['r'] for p in pieces], 1)   # < 0: inside
    own = np.argmin(D, 1)
    for i, p in enumerate(pieces):
        sel = own == i
        p['out'] = max(0.0, -wpct(D[sel, i], w[sel], 5)) if sel.any() else 0.0
        p['inset'] = wpct(D[sel, i], w[sel], 50) if sel.any() else 0.0


def lua(pieces):
    f = lambda v: '{ %.3f, %.3f, %.3f }' % tuple(v)
    lines = [
        '-- kleiner\'s body as capsules, for the clipping tests (tests/lib/bodyclip.lua).',
        '-- GENERATED by tools/rider/studio/capsules.py from models/player/kleiner.mdl: run it',
        '-- again rather than editing this. Each piece: a segment from `a` to `b`, each end an',
        '-- offset in a bone\'s own frame (forward, left, up), and a radius `r`: the %dth percentile' % Q,
        '-- by area of the distances from the piece\'s skin to the segment, so the capsule sits a',
        '-- little inside the skin. `out`: how far it stands proud of the skin where it does (the',
        '-- 95th percentile). `part`: the body part the piece is reported as. The method:',
        '-- capsules.py\'s header.',
        'return {',
        '    model = "models/player/kleiner.mdl",',
        '    percentile = %d,' % Q,
        '    pieces = {',
    ]
    for p in pieces:
        lines.append('        { name = "%s", part = "%s", a = { "%s", %s }, b = { "%s", %s }, r = %.3f, out = %.3f },'
                     % (p['name'], p['part'], p['a'][0], f(p['a'][1]), p['b'][0], f(p['b'][1]), p['r'], p['out']))
    lines += ['    },', '}', '']
    return '\n'.join(lines)


def capsule_tris(a, b, r, n=10, m=6):
    """A capsule as triangles (for the picture): a tube and two hemispheres."""
    d = b - a
    L = np.linalg.norm(d)
    z = d / L if L > 1e-6 else np.array([0, 0, 1.0])
    x = np.cross(z, [0, 0, 1] if abs(z[2]) < 0.9 else [1, 0, 0]); x /= np.linalg.norm(x)
    y = np.cross(z, x)
    rings = []
    for k in range(m, -1, -1):           # the hemisphere at a, then at b
        ph = -np.pi / 2 * k / m
        rings.append((a, ph))
    for k in range(m + 1):
        rings.append((b, np.pi / 2 * k / m))
    pts = []
    for c, ph in rings:
        ring = [c + (x * np.cos(t) + y * np.sin(t)) * r * np.cos(ph) + z * r * np.sin(ph)
                for t in np.linspace(0, 2 * np.pi, n, endpoint=False)]
        pts.append(ring)
    tris = []
    for i in range(len(pts) - 1):
        for j in range(n):
            p, q = pts[i][j], pts[i][(j + 1) % n]
            s, t = pts[i + 1][j], pts[i + 1][(j + 1) % n]
            tris += [[p, q, t], [p, t, s]]
    return np.array(tris)


def picture(body, pieces, out, shots=None, label=None):
    """The skin with the capsules in it, from the front, the side and the back: where a
    capsule's colour shows through, it stands proud of the skin."""
    import render                      # (the studio's rasterizer and skinning)
    import json
    if shots:
        d = json.load(open(shots))
        shot = next((s for s in d['shots'] if not label or label in s['label']), d['shots'][0])
        bones = shot['bones']
        skinned = render.skin(bones)

        def pose(bone, off):
            bn = bones[bone]
            t, f, l, u = (np.array(bn[i:i + 3]) for i in (0, 3, 6, 9))
            return t + f * off[0] + l * off[1] + u * off[2]
        title = '%s: %s' % (d['id'], shot['label'])
    else:
        skinned = body.P[body.M['tris']]

        def pose(bone, off):
            return (body.B2M[body.names.index(bone)] @ np.append(off, 1.0))[:3]
        title = 'bind pose'
    tris, cols = [skinned], [render.TCOL]
    pal = [(220, 40, 40), (40, 160, 60), (40, 90, 220), (230, 160, 20), (160, 40, 200)]
    for i, p in enumerate(pieces):
        ct = capsule_tris(pose(*p['a']), pose(*p['b']), p['r'])
        tris.append(ct)
        cols.append(np.tile(np.array(pal[i % len(pal)], np.uint8), (len(ct), 1)))
    T, C = np.concatenate(tris), np.concatenate(cols)
    c = T.reshape(-1, 3).mean(0)
    hip = c
    views = []
    W, Hh = 400, 640
    for cam in ((0, -1, 0.1), (1, 0, 0.1), (0, 1, 0.1), (-0.7, -0.7, 0.5)):
        cam = np.array(cam, float)
        views.append(render.render(T, C, hip + cam / np.linalg.norm(cam) * 92, hip, W, Hh, 50))
    from PIL import Image, ImageDraw
    sheet = Image.new('RGB', (W * len(views), Hh + 20), (245, 245, 240))
    for i, im in enumerate(views):
        sheet.paste(im, (W * i, 20))
    ImageDraw.Draw(sheet).text((4, 4), title + ' -- capsule colour showing = it stands proud of the skin', fill=(0, 0, 0))
    sheet.save(out)
    print('wrote', out)


def main():
    body = Body(MODEL)
    pieces = build(body)
    proud(body, pieces)
    open(OUT, 'w').write(lua(pieces))
    print('wrote', os.path.relpath(OUT, ROOT), len(pieces), 'pieces')
    for p in pieces:
        print('  %-22s r %.2f  out %.2f  inset %.2f  len %5.2f  (%.0f sq units of skin)' % (p['name'], p['r'], p['out'],
              p['inset'], np.linalg.norm(p['lb'] - p['la']), p['n']))
    if '--render' in sys.argv:
        i = sys.argv.index('--render')
        rest = sys.argv[i + 1:]
        picture(body, pieces, rest[0], rest[1] if len(rest) > 1 else None, rest[2] if len(rest) > 2 else None)


if __name__ == '__main__':
    main()
