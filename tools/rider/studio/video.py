"""tools/rider/studio/video.py -- studio.lua's video-mode shots (a shot every simulated
frame, STUDIO_VIDEO=1) drawn from ONE camera and encoded as an H.264 mp4. video.sh runs
studio.lua and this; README.md, "Video", says what to look for.

    python3 video.py shots.json out.mp4 [camera]

CAMERAS. A film of a rider who travels 2000 units cannot be shot from where a still is:
the rider leaves a fixed frame in a second. So every camera but `tripod` is a DOLLY: it
travels with the rider, kept on the rider's ground track by a centred running average of
where the vehicle is (half a second each way, so a steady roll is followed exactly and a
push or a carve does not shake the picture), and at a FIXED HEIGHT that does not follow
an air -- the ground stays put in the frame and a pop is the rider rising off it, which
is the point. Their directions are fixed by the vehicle's heading at the start, so a
carve is seen to turn the board, as from a filmer running alongside:

    side          from the vehicle's right (a regular skater's front, a bike's drive side)
    side-l        from its left
    front, back   ahead of it looking back, behind it looking on
    three-quarter ahead and to the right, a little above
    high          above and to the right, for a carve's line
    follow        a chase camera behind and above that turns with the vehicle's heading
                  (smoothed), as the game's third person does
    tripod        standing still beside the track, panning to follow, as real footage is
                  shot: STUDIO_TRIPOD=t puts it level with where the rider is t seconds in
                  (default: the middle), so the rider comes into frame, passes and leaves

THE GROUND is a checkerboard anchored to the world (16-unit tiles near, wider and plain
further out), so it slides past under a dolly camera at the vehicle's speed: a foot that
pushes and the wheels that roll can be judged against it. Each body and the vehicle cast
a SHADOW straight along the light onto it, which is what shows how high an ollie went
when the camera is level with it. The light is set from the camera's first direction,
over its shoulder, and then held, so a camera never films the rider's dark side and the
shadows do not swing.

THE LABEL STRIP under the picture: the vehicle, the scenario and the camera, the time,
the phase the scenario is in (its `phase`), the speed and the height off the ground, and
a timeline of the phases with a cursor.

Environment: STUDIO_SIZE (WxH of the picture, default 768x432; the strip is added under
it), STUDIO_RANGE=t0:t1 (seconds of the scenario to draw), STUDIO_JOBS (worker
processes, default every CPU), STUDIO_FRAMES=dir (also write each frame as a PNG),
STUDIO_DIST (a dolly camera's distance; by default far enough to keep the
whole clip's highest air in frame), STUDIO_CRF (x264 quality, 18).

Alongside the mp4 it writes <out>.angles.json: the rider's joint angles every frame
(tools/rider/angles.py), in the format refpose/blazepose.py writes for real footage,
which is what compare.py plots them from."""
import json
import math
import os
import struct
import subprocess
import sys
from multiprocessing import Pool

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.append(os.path.dirname(HERE))   # (after this one: tools/rider has a render.py of its own)
import render as RD          # noqa: E402  (kleiner's mesh, the skinning, the vehicle's triangles)
import angles as ANG         # noqa: E402

CAMERAS = ["side", "side-l", "front", "back", "three-quarter", "high", "follow", "tripod"]
STRIP = 40                   # px of label strip under the picture
SMOOTH_S = 0.5               # s each way of the dolly's running average


def font(size):
    for f in ("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "DejaVuSans.ttf",
              "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf"):
        try:
            return ImageFont.truetype(f, size)
        except OSError:
            pass
    return ImageFont.load_default()


def smooth(a, n):
    """A centred running average over 2n+1 samples along axis 0. The ends are padded by
    reflecting through the end point (odd reflection), which carries a steady motion on
    straight, so the camera is not dragged back at the first and last frames."""
    if n <= 0 or len(a) < 2:
        return a.copy()
    n = min(n, len(a) - 1)
    p = np.pad(a, [(n, n)] + [(0, 0)] * (a.ndim - 1), mode="reflect", reflect_type="odd")
    c = np.cumsum(np.concatenate([np.zeros((1,) + a.shape[1:]), p]), axis=0)
    return (c[2 * n + 1:] - c[:-2 * n - 1]) / (2 * n + 1)


def ground_tiles(gz):
    """Ground tiles in a box around the origin, made once and shifted to the frame's
    centre on whole tiles (so the pattern stays where it is in the world): 16-unit
    checks to 256 out, 64-unit plain ones to 1536, then 512-unit ones to 8192, so its
    far edge is at the horizon. (Not one big quad: raster.c drops a triangle with a
    corner behind the camera.)"""
    tris, idx, kind = [], [], []
    f, nf = 16, 16                       # fine: 16 u, +-16 tiles
    for i in range(-nf, nf):
        for j in range(-nf, nf):
            a = np.array([i * f, j * f, 0.0])
            q = [a, a + [f, 0, 0], a + [f, f, 0], a + [0, f, 0]]
            tris += [[q[0], q[1], q[2]], [q[0], q[2], q[3]]]
            idx += [(i, j)] * 2
            kind += [0, 0]
    c, nc = 64, 24                       # coarse: 64 u, +-24 tiles, not under the fine ones
    for i in range(-nc, nc):
        for j in range(-nc, nc):
            if -nf * f <= i * c < nf * f and -nf * f <= j * c < nf * f:
                continue
            a = np.array([i * c, j * c, 0.0])
            q = [a, a + [c, 0, 0], a + [c, c, 0], a + [0, c, 0]]
            tris += [[q[0], q[1], q[2]], [q[0], q[2], q[3]]]
            idx += [(i, j)] * 2
            kind += [1, 1]
    far, nfar = 512, 16                  # far: 512 u, +-16 tiles, not under the coarse ones
    for i in range(-nfar, nfar):
        for j in range(-nfar, nfar):
            if -nc * c <= i * far < nc * c and -nc * c <= j * far < nc * c:
                continue
            a = np.array([i * far, j * far, 0.0])
            q = [a, a + [far, 0, 0], a + [far, far, 0], a + [0, far, 0]]
            tris += [[q[0], q[1], q[2]], [q[0], q[2], q[3]]]
            idx += [(i, j)] * 2
            kind += [2, 2]
    t = np.array(tris)
    t[:, :, 2] = gz
    return t, np.array(idx), np.array(kind)


GT, GI, GK = None, None, None


def ground(centre, gz):
    """The ground round `centre`, shifted by whole 64-unit steps; colours by the world
    tile each triangle is on."""
    global GT, GI, GK
    if GT is None:
        GT, GI, GK = ground_tiles(gz)
    sx, sy = (int(math.floor(centre[0] / 64.0)) * 64, int(math.floor(centre[1] / 64.0)) * 64)
    t = GT + np.array([sx, sy, 0.0])
    fi = GI + np.where(GK[:, None] == 0, [[sx // 16, sy // 16]], [[sx // 64, sy // 64]])
    odd = (fi[:, 0] + fi[:, 1]) % 2 == 1
    cols = np.where(GK[:, None] == 0,
                    np.where(odd[:, None], [[128, 132, 120]], [[142, 146, 134]]),
                    np.where(odd[:, None], [[133, 137, 125]], [[137, 141, 129]]))
    cols = np.where(GK[:, None] == 2, [[135, 139, 127]], cols)
    # a darker line every 128 units along each axis, for scale (the fine checks only)
    wx = (GI[:, 0] * 16 + sx) % 128 == 0
    wy = (GI[:, 1] * 16 + sy) % 128 == 0
    cols = np.where(((wx | wy) & (GK == 0))[:, None], cols - 14, cols)
    return t, cols.astype(np.uint8)


def shadow(tris, light, gz):
    """Triangles flattened onto the ground along the light, a hair above it."""
    if not len(tris):
        return tris
    h = (tris[:, :, 2] - gz)[..., None]
    s = tris - light[None, None, :] * (h / light[2])
    s[:, :, 2] = gz + 0.08
    return s


class Cams:
    """Every frame's camera position and look-at point for one camera."""

    def __init__(self, shots, name, gz, fps):
        self.name = name
        E = np.array([s["ent"][:3] for s in shots], float)
        F = np.array([s["fwd"] for s in shots], float)
        F[:, 2] = 0
        F /= np.maximum(np.linalg.norm(F, axis=1, keepdims=True), 1e-6)
        n = int(round(SMOOTH_S * fps))
        P = smooth(E[:, :2], n)
        # THE FRAMING: from the ground (and the shadow) to over the highest the head
        # gets in the clip, so the biggest air stays in frame, at one distance for the
        # whole film; the look-at point is the middle of that, held level.
        head = np.array([s["bones"]["ValveBiped.Bip01_Head1"][2] for s in shots]) - gz
        top, bottom = float(head.max()) + 12, -8.0
        look = (top + bottom) / 2
        self.look = look
        self.fov = 45
        W, H = G["W"], G["H"]
        vfov = 2 * math.atan(math.tan(math.radians(self.fov) / 2) * H / W)
        fit = (top - bottom) / 2 / math.tan(vfov / 2) * 1.05
        D = float(os.environ.get("STUDIO_DIST", 0) or max(150.0, fit))
        h0 = F[0]
        r0 = np.array([h0[1], -h0[0], 0.0])          # the vehicle's right at the start
        up = np.array([0, 0, 1.0])
        T = np.column_stack([P, np.full(len(P), gz + look)])
        cam_h = 40 - look                            # a filmer's camera, about a metre up
        if name == "side":
            C = T + r0 * D + up * cam_h
        elif name == "side-l":
            C = T - r0 * D + up * cam_h
        elif name == "front":
            C = T + h0 * D + up * cam_h
        elif name == "back":
            C = T - h0 * D + up * cam_h
        elif name == "three-quarter":
            d = (h0 + r0) / math.sqrt(2)
            C = T + d * D + up * (cam_h + 30)
        elif name == "high":
            d = (0.3 * h0 + r0) / np.linalg.norm(0.3 * h0 + r0)
            C = T + d * D * 0.7 + up * D * 0.75
        elif name == "follow":
            yaw = np.unwrap(np.arctan2(F[:, 1], F[:, 0]))
            ys = smooth(yaw[:, None], n)[:, 0]
            H = np.column_stack([np.cos(ys), np.sin(ys), np.zeros(len(ys))])
            C = T - H * 170 + up * 45
            self.fov = 55
        elif name == "tripod":
            tt = np.array([s.get("t", i / fps) for i, s in enumerate(shots)])
            at = float(os.environ.get("STUDIO_TRIPOD", (tt[0] + tt[-1]) / 2))
            k = int(np.argmin(abs(tt - at)))
            C = np.tile(T[k] + r0 * D + up * cam_h, (len(T), 1))
        else:
            raise SystemExit("camera %r: one of %s" % (name, ", ".join(CAMERAS)))
        self.C, self.T = C, T
        # the light: over the camera's shoulder as it starts, then held
        f0 = T[0] - C[0]
        f0[2] = 0
        f0 /= max(np.linalg.norm(f0), 1e-6)
        rr = np.array([f0[1], -f0[0], 0])
        L = -f0 * 0.45 + rr * 0.35 + up * 0.85
        self.light = L / np.linalg.norm(L)


def phases_of(shots):
    """[(t0, t1, phase)] runs of the same phase label."""
    out = []
    for s in shots:
        p = s.get("phase") or s.get("label") or ""
        if out and out[-1][2] == p:
            out[-1][1] = s["t"]
        else:
            out.append([s["t"], s["t"], p])
    return out


PALETTE = [(78, 121, 167), (242, 142, 43), (89, 161, 79), (225, 87, 89), (118, 183, 178),
           (237, 201, 72), (176, 122, 161), (156, 117, 95), (186, 176, 172), (255, 157, 167)]

# Worker state (set before the pool forks, read in the children).
G = {}


def draw_frame(i):
    d, cams, W, H = G["d"], G["cams"], G["W"], G["H"]
    s = d["shots"][i]
    gz = G["gz"]
    bt = RD.skin(s["bones"])
    pc = RD.TCOL
    if s.get("paxBones"):
        bt = np.concatenate([bt, RD.skin(s["paxBones"])])
        pc = np.concatenate([RD.TCOL, RD.TCOL])
    vt, vc = RD.vehicle(s, d["meshes"])
    tt = RD.tube_tris(s)
    L = cams.light
    gt, gc = ground(cams.T[i], gz)
    body = [bt] + ([vt] if len(vt) else []) + ([tt] if len(tt) else [])
    st = shadow(np.concatenate(body), L, gz)
    sc = np.tile(np.array([84, 87, 79], np.uint8), (len(st), 1))
    parts = [gt, st, bt] + ([vt] if len(vt) else []) + ([tt] if len(tt) else [])
    cols = [gc, sc, pc] + ([vc] if len(vt) else []) + \
        ([np.tile(np.array([90, 90, 90], np.uint8), (len(tt), 1))] if len(tt) else [])
    img = RD.render(np.concatenate(parts), np.concatenate(cols), cams.C[i], cams.T[i], W, H, cams.fov, light=L)
    out = Image.new("RGB", (W, H + STRIP), (28, 30, 34))
    out.paste(img, (0, 0))
    dr = ImageDraw.Draw(out)
    f1, f2 = G["font"], G["fontb"]
    stt = s.get("st", {})
    v = stt.get("v", 0.0)
    z = stt.get("z", 0.0)
    left = "%s  %s  %s" % (d["id"], d.get("video", {}).get("scenario", ""), cams.name)
    dr.text((8, H + 4), left, fill=(200, 204, 210), font=f1)
    ph = s.get("phase") or s.get("label") or ""
    w = dr.textlength(ph, font=f2)
    dr.text(((W - w) / 2, H + 2), ph, fill=(255, 255, 255), font=f2)
    right = "t %5.2f s   %3.0f u/s (%4.1f km/h)   %s" % (
        s["t"], v, v * 0.0254 * 3.6, ("air %4.1f" % z) if not stt.get("grounded", True) else "down")
    w = dr.textlength(right, font=f1)
    dr.text((W - w - 8, H + 4), right, fill=(200, 204, 210), font=f1)
    # the timeline: a band per phase, the cursor where this frame is
    t0, t1 = G["span"]
    y0 = H + 26
    for k, (a, b, p) in enumerate(G["phases"]):
        x0 = 8 + (a - t0) / max(t1 - t0, 1e-6) * (W - 16)
        x1 = 8 + (b + G["dt"] - t0) / max(t1 - t0, 1e-6) * (W - 16)
        dr.rectangle([x0, y0, max(x0 + 1, x1 - 1), y0 + 8], fill=G["pcol"][p])
    cx = 8 + (s["t"] - t0) / max(t1 - t0, 1e-6) * (W - 16)
    dr.rectangle([cx - 1, y0 - 3, cx + 1, y0 + 11], fill=(255, 255, 255))
    if G.get("frames"):
        out.save(os.path.join(G["frames"], "%05d.png" % i))
    return out.tobytes()


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    src, out = sys.argv[1], sys.argv[2]
    cam = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else "side"
    d = json.load(open(src))
    if d.get("err"):
        print("the scenario stopped with an error:", d["err"], file=sys.stderr)
    if not d.get("video"):
        raise SystemExit("not a video-mode shots file (studio.lua with STUDIO_VIDEO=1; video.sh does it)")
    fps = float(d["video"].get("fps", 30))
    gz = float(d["video"].get("ground", 0))
    shots = d["shots"]
    if not shots:
        raise SystemExit("no frames")
    rng = os.environ.get("STUDIO_RANGE")
    if rng:
        a, b = (float(x) if x else None for x in rng.split(":"))
        shots = [s for s in shots if (a is None or s["t"] >= a - 1e-6) and (b is None or s["t"] <= b + 1e-6)]
        d["shots"] = shots
    W, H = (int(x) for x in os.environ.get("STUDIO_SIZE", "768x432").lower().split("x"))
    W, H = W - W % 2, H - H % 2
    G.update(W=W, H=H)
    cams = Cams(shots, cam, gz, fps)
    phases = phases_of(shots)
    names = []
    for _, _, p in phases:
        if p not in names:
            names.append(p)
    G.update(d=d, cams=cams, W=W, H=H, gz=gz, phases=phases, dt=1.0 / fps,
             span=(shots[0]["t"], shots[-1]["t"] + 1.0 / fps),
             pcol={p: PALETTE[k % len(PALETTE)] for k, p in enumerate(names)},
             font=font(13), fontb=font(15), frames=os.environ.get("STUDIO_FRAMES"))
    if G["frames"]:
        os.makedirs(G["frames"], exist_ok=True)
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    ff = subprocess.Popen(["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
                           "-s", "%dx%d" % (W, H + STRIP), "-r", "%g" % fps, "-i", "-",
                           "-c:v", "libx264", "-preset", "medium", "-crf", os.environ.get("STUDIO_CRF", "18"),
                           "-pix_fmt", "yuv420p", "-movflags", "+faststart", out], stdin=subprocess.PIPE)
    jobs = int(os.environ.get("STUDIO_JOBS", os.cpu_count() or 1))
    with Pool(jobs) as pool:
        for k, frame in enumerate(pool.imap(draw_frame, range(len(shots)), chunksize=2)):
            ff.stdin.write(frame)
            if k % 60 == 0:
                print("  frame %d / %d" % (k, len(shots)), file=sys.stderr)
    ff.stdin.close()
    if ff.wait() != 0:
        raise SystemExit("ffmpeg failed")
    rows = []
    for s in shots:
        a = ANG.of_shot(s)
        if a:
            a["t"] = round(s["t"], 4)
            a["phase"] = s.get("phase", "")
            rows.append(a)
    json.dump({"video": out, "source": "studio", "id": d["id"], "scenario": d["video"].get("scenario"),
               "fps": fps, "frames": rows}, open(out + ".angles.json", "w"))
    print("wrote %s (%d frames, %.1f s, %dx%d, camera %s) and %s.angles.json"
          % (out, len(shots), len(shots) / fps, W, H + STRIP, cam, out))


if __name__ == "__main__":
    main()
