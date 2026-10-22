"""tools/rider/compare.py -- real footage beside the studio's film, side by side, as one mp4,
with the joint angles of both plotted under them. README.md, "Comparing with real footage".

    python3 tools/rider/compare.py out.mp4 \\
        --ref ollie.ogv --ref-from 0.9 --ref-to 2.1 --ref-mirror --ref-pose ollie.json \\
        --ours skate.mp4 --ours-from 6.75 --ours-to 7.95

WHY. Whether an animation looks lifelike is a question about TIMING as much as about
poses: how long the crouch is before a pop, how fast the legs extend, how much the knees
take on landing, whether the body leads the board or follows it. A still of each cannot
show that and two films in two windows cannot be watched together. This plays one real
rider and the studio's rider in step, at the same height, each with its title and its
own clock, and under them the knee, hip and trunk angles of both against the same time
axis with a cursor -- so "the real kid's knees are at 110 degrees where ours are at 60"
is read off the strip rather than guessed at.

THE TWO CLIPS. Each is cut from its own start to its end (seconds of its source), may be
cropped (x,y,w,h in its source's pixels), slowed or sped up (--*-speed 0.5 is half
speed), and is scaled to --height. They start together; the shorter one holds its last
frame. Line the two up on an event (the pop, a foot down) by choosing the cuts so the
event is the same time after each start. --ref-mirror flips the real clip left to right,
and swaps its left and right angles with it: a goofy skater filmed riding right to left
then reads as a regular one riding left to right, which is how the studio's `side`
camera films its regular rider (or film ours with STUDIO_GOOFY=1 from `side-l`).

THE ANGLES (optional; the strip is left out when neither side has them). Ours come from
the film's sidecar, <ours>.angles.json, which video.py writes (tools/rider/angles.py on
the studio's bones). The real rider's come from refpose/blazepose.py run on the clip, the
same angles from BlazePose's 3D landmarks; frames whose landmarks it was unsure of
(visibility under --min-vis) are left as gaps, and the rest are smoothed over three
frames, as the landmarks jitter. Each angle is a flexion, 0 for a straight joint; the
trunk is its lean from vertical. They are only comparable as shapes and sizes: the real
one is a monocular estimate (a few degrees off at best, more when a limb is hidden), and
a child's proportions are not kleiner's.
"""
import argparse
import json
import math
import os
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

# Colours: the strip's surface and inks, and one hue per source (validated as a pair
# for colour-blind separation and contrast on this surface).
SURFACE = (28, 30, 34)
INK, INK2, GRID = (240, 239, 236), (195, 194, 183), (58, 61, 68)
REF_COL, OURS_COL = (217, 89, 38), (57, 135, 229)
TITLE_H, GAP, STRIP_H = 28, 8, 180
PANELS = [("kneeL", "knee, left"), ("kneeR", "knee, right"), ("hipL", "hip, left"),
          ("hipR", "hip, right"), ("trunk", "trunk lean")]
SWAP = {"kneeL": "kneeR", "kneeR": "kneeL", "hipL": "hipR", "hipR": "hipL", "elbowL": "elbowR",
        "elbowR": "elbowL", "abdL": "abdR", "abdR": "abdL"}


def font(size):
    for f in ("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "DejaVuSans.ttf",
              "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf"):
        try:
            return ImageFont.truetype(f, size)
        except OSError:
            pass
    return ImageFont.load_default()


def probe(path):
    """Width, height and frame rate of a file's first video stream."""
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                          "stream=width,height,r_frame_rate", "-of", "json", path],
                         capture_output=True, text=True, check=True)
    s = json.loads(out.stdout)["streams"][0]
    num, _, den = s.get("r_frame_rate", "0/1").partition("/")
    fps = float(num) / float(den or 1) if float(den or 1) else 0.0
    return int(s["width"]), int(s["height"]), fps


class Clip:
    """One side: frames streamed out of ffmpeg, cut, cropped, flipped, retimed and scaled."""

    def __init__(self, path, t0, t1, crop, speed, height, fps, mirror):
        if t1 <= t0:
            raise SystemExit("%s: the end (%g) must be after the start (%g)" % (path, t1, t0))
        w, h, src_fps = probe(path)
        # The cut starts on the first whole frame at or after t0: the clock and the angles
        # are kept on that frame's time, not the time asked for.
        if src_fps > 0:
            t0 = math.ceil(t0 * src_fps - 1e-6) / src_fps
        vf = []
        if crop:
            x, y, cw, ch = (int(float(v)) for v in crop.split(","))
            vf.append("crop=%d:%d:%d:%d" % (cw, ch, x, y))
            w, h = cw, ch
        if mirror:
            vf.append("hflip")
        self.W = int(round(w * height / h / 2)) * 2
        self.H = height
        vf += ["setpts=(PTS-STARTPTS)/%r" % speed, "fps=%r" % fps, "scale=%d:%d:flags=bicubic" % (self.W, self.H)]
        self.t0, self.speed, self.fps = t0, speed, fps
        self.n = int(math.ceil((t1 - t0) / speed * fps - 1e-6))
        early = 0.25 / src_fps if src_fps > 0 else 0.0     # (so rounding cannot skip that frame)
        self.proc = subprocess.Popen(["ffmpeg", "-v", "error", "-ss", "%r" % max(0.0, t0 - early),
                                      "-t", "%r" % (t1 - t0 + early), "-i", path,
                                      "-vf", ",".join(vf), "-an", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                                     stdout=subprocess.PIPE)
        self.last, self.done, self.k = None, False, 0

    def next(self):
        """The next frame, or the last one again once it has run out (and whether it is held)."""
        if not self.done and self.k < self.n:
            b = self.proc.stdout.read(self.W * self.H * 3)
            if len(b) == self.W * self.H * 3:
                self.last = Image.frombytes("RGB", (self.W, self.H), b)
                self.k += 1
                return self.last, False
            self.done = True
        if self.last is None:
            self.last = Image.new("RGB", (self.W, self.H), (0, 0, 0))
        return self.last, True

    def close(self):
        self.proc.stdout.close()
        self.proc.kill()
        self.proc.wait()


def series(path, t0, t1, speed, mirror=False, min_vis=None, smooth=False):
    """{key: (times on the output's clock, values)} from an angles JSON, between t0 and t1."""
    if not path or not os.path.exists(path):
        return None
    rows = json.load(open(path)).get("frames", [])
    out = {}
    for key, _ in PANELS:
        src = SWAP.get(key, key) if mirror else key
        ts, vs = [], []
        for r in rows:
            t = r.get("t")
            if t is None or t < t0 - 1e-6 or t > t1 + 1e-6:
                continue
            v = r.get(src)
            if v is None or (min_vis is not None and r.get("vis", 1.0) < min_vis):
                ts.append((t - t0) / speed)
                vs.append(float("nan"))
                continue
            ts.append((t - t0) / speed)
            vs.append(float(v))
        v = np.array(vs, float)
        if smooth and len(v) >= 3:
            s = v.copy()
            for i in range(1, len(v) - 1):
                w = v[i - 1:i + 2]
                if not np.isnan(v[i]) and not np.isnan(w).any():
                    s[i] = float(np.median(w))
            v = s
        out[key] = (np.array(ts, float), v)
    return out


def draw_strip(W, dur, ref, ours, ref_name, ours_name):
    """The angle strip without its cursor: a legend, then a panel per angle."""
    img = Image.new("RGB", (W, STRIP_H), SURFACE)
    dr = ImageDraw.Draw(img)
    f, fs = font(13), font(11)
    x = 10
    for col, name in ((REF_COL, ref_name), (OURS_COL, ours_name)):
        dr.line([x, 13, x + 22, 13], fill=col, width=3)
        dr.text((x + 28, 5), name, fill=INK, font=f)
        x += 28 + dr.textlength(name, font=f) + 24
    note = "flexion in degrees (0 = straight); trunk: lean from vertical"
    dr.text((W - 10 - dr.textlength(note, font=fs), 7), note, fill=INK2, font=fs)
    n = len(PANELS)
    pw = (W - 20) / n
    top, bot = 50, STRIP_H - 18
    boxes = []
    for i, (key, title) in enumerate(PANELS):
        x0, x1 = 10 + i * pw + 6, 10 + (i + 1) * pw - 6
        vals = [s[key][1] for s in (ref, ours) if s and key in s]
        hi = max([np.nanmax(v) for v in vals if len(v) and not np.isnan(v).all()] + [1.0])
        ymax = 90 if key == "trunk" else 150
        ymax = max(ymax, int(math.ceil(hi / 30.0)) * 30)
        step = 45 if ymax <= 90 else 50 if ymax <= 150 else 60

        def Y(v, ymax=ymax):
            return bot - (v / ymax) * (bot - top)

        for g in range(0, ymax + 1, step):
            dr.line([x0 + 22, Y(g), x1, Y(g)], fill=GRID, width=1)
            dr.text((x0, Y(g) - 6), "%d" % g, fill=INK2, font=fs)
        dr.text((x0 + 22, top - 20), title, fill=INK, font=fs)
        px0 = x0 + 22

        def X(t, px0=px0, x1=x1):
            return px0 + (t / max(dur, 1e-6)) * (x1 - px0)

        for s, col in ((ref, REF_COL), (ours, OURS_COL)):
            if not s or key not in s:
                continue
            ts, vs = s[key]
            run = []
            for t, v in zip(ts, vs):
                if np.isnan(v) or t < 0 or t > dur + 1e-6:
                    if len(run) > 1:
                        dr.line(run, fill=col, width=2, joint="curve")
                    run = []
                    continue
                run.append((X(t), Y(min(v, ymax))))
            if len(run) > 1:
                dr.line(run, fill=col, width=2, joint="curve")
        dr.text((px0, bot + 3), "0 s", fill=INK2, font=fs)
        lab = "%.1f s" % dur
        dr.text((x1 - dr.textlength(lab, font=fs), bot + 3), lab, fill=INK2, font=fs)
        boxes.append((px0, x1, top, bot))
    return img, boxes


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out")
    ap.add_argument("--ref", required=True, help="the real clip")
    ap.add_argument("--ref-from", type=float, default=0.0)
    ap.add_argument("--ref-to", type=float, required=True)
    ap.add_argument("--ref-crop", help="x,y,w,h in the source's pixels")
    ap.add_argument("--ref-speed", type=float, default=1.0)
    ap.add_argument("--ref-mirror", action="store_true", help="flip left to right (and its angles' L and R)")
    ap.add_argument("--ref-title", default=None)
    ap.add_argument("--ref-pose", help="refpose/blazepose.py's JSON for the clip")
    ap.add_argument("--min-vis", type=float, default=0.5, help="drop real-rider frames less visible than this")
    ap.add_argument("--ours", required=True, help="the studio's film (video.sh)")
    ap.add_argument("--ours-from", type=float, default=0.0)
    ap.add_argument("--ours-to", type=float, required=True)
    ap.add_argument("--ours-crop")
    ap.add_argument("--ours-speed", type=float, default=1.0)
    ap.add_argument("--ours-title", default=None)
    ap.add_argument("--ours-angles", help="default: <ours>.angles.json")
    ap.add_argument("--height", type=int, default=432)
    ap.add_argument("--fps", type=float, default=30.0)
    ap.add_argument("--no-strip", action="store_true")
    a = ap.parse_args()
    H = a.height - a.height % 2
    ref_title = a.ref_title or os.path.basename(a.ref) + (" (mirrored)" if a.ref_mirror else "")
    ours_title = a.ours_title or "studio: " + os.path.basename(a.ours)
    R = Clip(a.ref, a.ref_from, a.ref_to, a.ref_crop, a.ref_speed, H, a.fps, a.ref_mirror)
    O = Clip(a.ours, a.ours_from, a.ours_to, a.ours_crop, a.ours_speed, H, a.fps, False)
    n = max(R.n, O.n)
    dur = n / a.fps
    W = R.W + GAP + O.W
    W += W % 2
    ref_s = series(a.ref_pose, R.t0, a.ref_to, a.ref_speed, a.ref_mirror, a.min_vis, smooth=True)
    ours_s = series(a.ours_angles or a.ours + ".angles.json", O.t0, a.ours_to, a.ours_speed)
    strip = None
    if not a.no_strip and (ref_s or ours_s):
        strip, boxes = draw_strip(W, dur, ref_s, ours_s, "real: " + ref_title, ours_title)
    TH = TITLE_H + H + (STRIP_H if strip else 0)
    TH += TH % 2
    ff = subprocess.Popen(["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
                           "-s", "%dx%d" % (W, TH), "-r", "%r" % a.fps, "-i", "-", "-c:v", "libx264", "-preset",
                           "medium", "-crf", "18", "-pix_fmt", "yuv420p", "-movflags", "+faststart", a.out],
                          stdin=subprocess.PIPE)
    f1, f2 = font(14), font(12)
    for k in range(n):
        tau = k / a.fps
        frame = Image.new("RGB", (W, TH), SURFACE)
        dr = ImageDraw.Draw(frame)
        for clip, x0, title, col in ((R, 0, "real: " + ref_title, REF_COL), (O, R.W + GAP, ours_title, OURS_COL)):
            im, held = clip.next()
            frame.paste(im, (x0, TITLE_H))
            dr.rectangle([x0, TITLE_H - 3, x0 + clip.W - 1, TITLE_H - 1], fill=col)
            dr.text((x0 + 8, 5), title, fill=INK, font=f1)
            src_t = clip.t0 + min(tau, (clip.n - 1) / a.fps) * clip.speed
            clock = "t %.2f s%s%s" % (src_t, "  x%g" % clip.speed if clip.speed != 1 else "", "  (held)" if held else "")
            dr.text((x0 + clip.W - 8 - dr.textlength(clock, font=f2), 7), clock, fill=INK2, font=f2)
        if strip:
            frame.paste(strip, (0, TITLE_H + H))
            for px0, x1, top, bot in boxes:
                cx = px0 + (tau / max(dur, 1e-6)) * (x1 - px0)
                dr.line([cx, TITLE_H + H + top - 2, cx, TITLE_H + H + bot], fill=INK, width=1)
        ff.stdin.write(frame.tobytes())
    ff.stdin.close()
    R.close()
    O.close()
    if ff.wait() != 0:
        raise SystemExit("ffmpeg failed")
    print("wrote %s: %dx%d, %d frames (%.2f s)%s" % (a.out, W, TH, n, dur, ", with the angle strip" if strip else ""))


if __name__ == "__main__":
    main()
