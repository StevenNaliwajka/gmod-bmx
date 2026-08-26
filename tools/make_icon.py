#!/usr/bin/env python3
"""Draw workshop/icon.jpg, the 512x512 image the Steam Workshop listing needs.

WHY THIS IS A SCRIPT AND NOT A PNG SOMEBODY MADE. This addon has a hard rule
that no asset comes from anywhere it should not (see docs/DESIGN.md section 8),
and the cheapest way to keep an icon honest is to have no source for it at all.
Everything below is drawn from the same numbers the simulation uses -- the
wheelbase, the wheel radius, the centre of mass, the rear contact patch -- so
the icon is a picture OF the config rather than an illustration next to it.
Change Wheel.wheelbase and the icon changes with it.

IT DRAWS THE BIKE LEVEL, and that is a reversal worth recording. The first
version stood it at its wheelie balance point, atan(17.5/20) = 41.2 degrees,
because that is the one piece of geometry in this project you can see at a
glance. It looked good at 512 and turned to mush at the roughly 64 pixels Steam
actually renders in a list, which is the size that decides whether anyone clicks
it. A side-on silhouette is instantly a bicycle at any size. Legibility beats the
clever angle; PITCH is still here if you disagree.

STEAM'S REQUIREMENTS, which are not negotiable and not well documented:
    512x512 exactly, JPEG, under 1 MB.
A PNG named .jpg is rejected, and so is 512x513.

    python3 tools/make_icon.py

Needs Pillow. It is a build-time tool, not a runtime dependency: the .gma
ignores tools/ and workshop/ entirely, because the icon is uploaded alongside
the addon by gmpublish rather than packed inside it.
"""

from __future__ import annotations

import math
import pathlib
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.exit("this needs Pillow:  pip install Pillow")

SIZE = 512
SS = 4                      # supersample factor, then downsample: cheap AA
W = SIZE * SS

# Straight out of lua/bmx/sh_config.lua. If these drift, the icon is wrong in
# the same way the docs would be, which is the point.
WHEELBASE = 39.0
RADIUS = 10.0
COM = (-2.0, 20.0)          # chassis space, origin on the axle line
REAR_X = -WHEELBASE / 2
FRONT_X = WHEELBASE / 2

BG_TOP = (24, 26, 32)
BG_BOTTOM = (14, 15, 19)
GROUND = (38, 41, 50)
ACCENT = (255, 138, 46)     # the wheel-ring orange from the debug overlay
FRAME = (232, 236, 244)
DIM = (128, 137, 156)


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


# The frame, in chassis space, axle line at z = 0, inches. Real 20-inch BMX
# numbers: the bottom bracket sits about 1.6 inches ABOVE the axle line (11.6"
# BB height against a 10" wheel radius), the head tube is up at the FRONT of the
# bike leaning back ~15 degrees off vertical, and the seat is low because nobody
# sits on a BMX.
#
# Worth being fussy about: put the head tube where a seat tube would go and the
# diamond stops reading as a bicycle and starts reading as a floating
# parallelogram, which is exactly what the first attempt did.
BB        = ( -2.0,  1.6)   # bottom bracket
SEAT_LO   = ( -7.5, 12.0)   # seat clamp, top of the seat tube
SEAT_BACK = (-10.5, 13.0)   # saddle, nose forward and tail back
SEAT_NOSE = ( -4.5, 12.6)
HEAD_LO   = ( 15.0,  5.0)   # bottom of the head tube, just behind the fork
HEAD_HI   = ( 12.6, 14.0)   # top of the head tube
BAR_MID   = ( 11.6, 19.5)   # stem and bar clamp
BAR_TOP   = (  7.0, 21.0)   # bar, swept back toward the rider


# Nose-up angle, radians. 0 is a side-on silhouette; the wheelie balance point
# is math.atan2(COM[0] - REAR_X, COM[1]), which is 41.2 degrees.
PITCH = 0.0


def main() -> int:
    # Whatever the angle, the bike pitches about the REAR CONTACT PATCH, because
    # that is what a real wheelie pivots about and what docs/TUNING.md derives
    # the balance point from.
    theta = PITCH
    pivot = (REAR_X, -RADIUS)

    def rot(p):
        dx, dz = p[0] - pivot[0], p[1] - pivot[1]
        c, s = math.cos(theta), math.sin(theta)
        return (pivot[0] + dx * c - dz * s, pivot[1] + dx * s + dz * c)

    rear_hub, front_hub = rot((REAR_X, 0.0)), rot((FRONT_X, 0.0))
    frame = {k: rot(v) for k, v in
             (("bb", BB), ("seat", SEAT_LO), ("head_lo", HEAD_LO),
              ("head_hi", HEAD_HI), ("bar_mid", BAR_MID), ("bar_top", BAR_TOP),
              ("seat_back", SEAT_BACK), ("seat_nose", SEAT_NOSE))}
    contact = rot(pivot)

    # FIT THE DRAWING TO THE CANVAS rather than hand-placing it. A 41-degree
    # wheelie occupies a diagonal, and picking an origin and a scale by eye left
    # a quarter of the image empty -- which matters, because Steam shows this at
    # about 64 pixels in a list and every wasted pixel is one the bike does not
    # get.
    xs, zs = [], []
    for hub in (rear_hub, front_hub):
        xs += [hub[0] - RADIUS, hub[0] + RADIUS]
        zs += [hub[1] - RADIUS, hub[1] + RADIUS]
    for p in frame.values():
        xs.append(p[0]); zs.append(p[1])

    margin = 0.085
    span = max(max(xs) - min(xs), max(zs) - min(zs))
    scale = W * (1 - 2 * margin) / span
    cx, cz = (min(xs) + max(xs)) / 2, (min(zs) + max(zs)) / 2

    def pt(p):
        return (W / 2 + (p[0] - cx) * scale, W / 2 - (p[1] - cz) * scale)

    img = Image.new("RGB", (W, W), BG_TOP)
    d = ImageDraw.Draw(img)
    for y in range(0, W, SS):
        d.rectangle([0, y, W, y + SS], fill=lerp(BG_TOP, BG_BOTTOM, y / W))

    # Ground, at the rear contact patch: the bike stands on it rather than
    # floating above a decorative line.
    ground_y = pt(contact)[1]
    d.rectangle([0, ground_y, W, W], fill=GROUND)

    # One soft shadow under each wheel that is actually touching, rather than a
    # single smudge under the rear: with the bike level both wheels are down,
    # and a shadow under only one of them reads as a bike falling over.
    for hub in (rear_hub, front_hub):
        cx_ = pt(hub)[0]
        if abs(pt(hub)[1] + RADIUS * scale - ground_y) < 2 * scale:
            d.ellipse([cx_ - 13 * scale, ground_y - 1.6 * scale,
                       cx_ + 13 * scale, ground_y + 1.6 * scale],
                      fill=lerp(GROUND, BG_BOTTOM, 0.55))

    def wheel(hub):
        c, r = pt(hub), RADIUS * scale
        d.ellipse([c[0] - r, c[1] - r, c[0] + r, c[1] + r],
                  outline=ACCENT, width=round(4.0 * SS))
        # Few spokes and thin: reads as a wheel at 512 and as texture at 64.
        for k in range(8):
            a = theta + k * math.pi / 4
            d.line([c[0] + math.cos(a) * r * 0.16, c[1] + math.sin(a) * r * 0.16,
                    c[0] + math.cos(a) * r * 0.88, c[1] + math.sin(a) * r * 0.88],
                   fill=DIM, width=round(1.5 * SS))
        d.ellipse([c[0] - 1.6 * scale, c[1] - 1.6 * scale,
                   c[0] + 1.6 * scale, c[1] + 1.6 * scale], fill=ACCENT)
        return c

    rear, front = wheel(rear_hub), wheel(front_hub)
    f = {k: pt(v) for k, v in frame.items()}

    lw = round(4.2 * SS)
    for a, b in (
            (rear, f["bb"]),            # chainstay
            (rear, f["seat"]),          # seatstay
            (f["bb"], f["seat"]),       # seat tube
            (f["bb"], f["head_lo"]),    # down tube
            (f["seat"], f["head_hi"]),  # top tube
            (f["head_lo"], f["head_hi"]),
            (f["head_lo"], front),      # fork
            (f["head_hi"], f["bar_mid"]),
            (f["bar_mid"], f["bar_top"]),
    ):
        d.line([a, b], fill=FRAME, width=lw)

    # Saddle, drawn from its own model points so it rotates with everything
    # else instead of needing its own angle maths.
    d.line([f["seat_back"], f["seat_nose"]], fill=FRAME, width=round(3.4 * SS))
    d.ellipse([f["bb"][0] - 3.6 * scale, f["bb"][1] - 3.6 * scale,
               f["bb"][0] + 3.6 * scale, f["bb"][1] + 3.6 * scale],
              outline=ACCENT, width=round(3.0 * SS))

    img = img.resize((SIZE, SIZE), Image.LANCZOS)

    out = pathlib.Path(__file__).resolve().parent.parent / "workshop"
    out.mkdir(exist_ok=True)
    path = out / "icon.jpg"
    img.save(path, "JPEG", quality=92, optimize=True)

    kb = path.stat().st_size / 1024
    print(f"{path}: {img.size[0]}x{img.size[1]} JPEG, {kb:.0f} KB")
    if img.size != (SIZE, SIZE) or kb > 1024:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
