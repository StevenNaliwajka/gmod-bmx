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

# THE BIKE AS THE GAME DRAWS IT (lua/entities/bmx_base/cl_init.lua): the
# stock paint (BMX.Palette[1], sh_color.lua), black tyres on chrome rims, black
# fork, bars and cranks, chrome pegs and chainring. The first icon was orange
# line art on black, which is a bicycle but not THIS bicycle.
SKY_TOP = (58, 128, 206)
SKY_BOTTOM = (176, 214, 240)
FLOOR_TOP = (188, 190, 196)       # skatepark concrete
FLOOR_BOTTOM = (150, 152, 160)
PAINT = (205, 35, 45)             # BMX.Palette[1], "Red"
PAINT_HI = (240, 96, 100)
TYRE = (26, 26, 30)
RIM = (214, 218, 226)
PART = (34, 34, 38)               # cl_init COL_PART
CHROME = (226, 230, 238)
SHADOW = (120, 122, 130)


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


# The frame: cl_init.lua's FRAME table, which is in chassis space with the
# axle line at z = 0, drawn lifted by the static sag the way the game draws it
# (sh_util BMX.RestHeight: radius - sag = 7.3, so sag = 2.7).
SAG = 2.7
BB        = ( -4.5,  2.5 + SAG)   # bottom bracket
SEAT_J    = ( -9.5, 14.0 + SAG)   # top tube meets seat tube
SEAT      = (-10.5, 18.5 + SAG)   # top of the seat post
HEAD_T    = ( 12.5, 17.5 + SAG)   # head tube, top
HEAD_B    = ( 14.5, 10.5 + SAG)   # head tube, bottom
BARS      = ( 10.5, 26.0 + SAG)   # bar centre
CRANK     = 6.8
RING      = 3.8


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
             (("bb", BB), ("seat_j", SEAT_J), ("seat", SEAT), ("head_t", HEAD_T),
              ("head_b", HEAD_B), ("bars", BARS))}
    contact = rot(pivot)

    # FIT THE DRAWING TO THE CANVAS: Steam shows this at about 64 pixels in a
    # list, and every wasted pixel is one the bike does not get.
    xs, zs = [], []
    for hub in (rear_hub, front_hub):
        xs += [hub[0] - RADIUS, hub[0] + RADIUS]
        zs += [hub[1] - RADIUS, hub[1] + RADIUS]
    for p in frame.values():
        xs.append(p[0]); zs.append(p[1])
    zs.append(frame["bars"][1] + 1.5)

    margin = 0.07
    span = max(max(xs) - min(xs), max(zs) - min(zs))
    scale = W * (1 - 2 * margin) / span
    cx, cz = (min(xs) + max(xs)) / 2, (min(zs) + max(zs)) / 2 + 3.0

    def pt(p):
        return (W / 2 + (p[0] - cx) * scale, W / 2 - (p[1] - cz) * scale)

    img = Image.new("RGB", (W, W), SKY_TOP)
    d = ImageDraw.Draw(img)
    ground_y = pt(contact)[1]
    for y in range(0, W, SS):
        if y < ground_y:
            d.rectangle([0, y, W, y + SS], fill=lerp(SKY_TOP, SKY_BOTTOM, y / ground_y))
        else:
            t = (y - ground_y) / max(W - ground_y, 1)
            d.rectangle([0, y, W, y + SS], fill=lerp(FLOOR_TOP, FLOOR_BOTTOM, t))
    # A quarter pipe at the right edge: this is a skatepark bike. Its face is
    # a quarter circle rising from the floor to vertical, then the deck.
    R = W * 0.20
    x0 = W - R - W * 0.03
    ramp = [(x0, ground_y)]
    for k in range(0, 31):
        a = math.radians(90 * k / 30)
        ramp.append((x0 + R * math.sin(a), ground_y - R * (1 - math.cos(a))))
    ramp += [(W, ground_y - R), (W, ground_y)]
    d.polygon(ramp, fill=lerp(FLOOR_TOP, SKY_BOTTOM, 0.25))
    d.line([(x0 + R, ground_y - R), (W, ground_y - R)], fill=CHROME, width=round(1.2 * SS))

    for hub in (rear_hub, front_hub):
        c = pt(hub)
        d.ellipse([c[0] - 12 * scale, ground_y - 1.4 * scale,
                   c[0] + 12 * scale, ground_y + 1.4 * scale], fill=SHADOW)

    def tube(a, b, w, col):
        d.line([a, b], fill=col, width=round(w * scale))
        r = w * scale / 2
        for q in (a, b):
            d.ellipse([q[0] - r, q[1] - r, q[0] + r, q[1] + r], fill=col)

    def wheel(hub):
        c, r = pt(hub), RADIUS * scale
        tw = 2.4 * scale
        d.ellipse([c[0] - r, c[1] - r, c[0] + r, c[1] + r], fill=TYRE)
        ri = r - tw
        d.ellipse([c[0] - ri, c[1] - ri, c[0] + ri, c[1] + ri], fill=RIM)
        ri2 = ri - 0.9 * scale
        d.ellipse([c[0] - ri2, c[1] - ri2, c[0] + ri2, c[1] + ri2], fill=lerp(SKY_BOTTOM, FLOOR_TOP, 0.5))
        for k in range(12):
            a = k * math.pi / 6 + 0.13
            d.line([c[0] + math.cos(a) * 1.2 * scale, c[1] + math.sin(a) * 1.2 * scale,
                    c[0] + math.cos(a) * ri2, c[1] + math.sin(a) * ri2],
                   fill=(150, 154, 164), width=max(1, round(0.35 * scale)))
        d.ellipse([c[0] - 1.6 * scale, c[1] - 1.6 * scale,
                   c[0] + 1.6 * scale, c[1] + 1.6 * scale], fill=CHROME)
        # The peg: the part a BMX has that nothing else does.
        d.ellipse([c[0] - 1.35 * scale, c[1] - 1.35 * scale,
                   c[0] + 1.35 * scale, c[1] + 1.35 * scale], fill=CHROME, outline=PART,
                  width=max(1, round(0.25 * scale)))
        return c

    rear, front = wheel(rear_hub), wheel(front_hub)
    f = {k: pt(v) for k, v in frame.items()}

    # Drivetrain behind the frame: chainring, chain, crank and pedal.
    bb = f["bb"]
    rr = RING * scale
    d.ellipse([bb[0] - rr, bb[1] - rr, bb[0] + rr, bb[1] + rr], outline=CHROME,
              width=round(0.7 * scale))
    d.line([(bb[0], bb[1] - rr), (rear[0], rear[1] - 1.3 * scale)], fill=PART, width=round(0.45 * scale))
    d.line([(bb[0], bb[1] + rr), (rear[0], rear[1] + 1.3 * scale)], fill=PART, width=round(0.45 * scale))
    ca = math.radians(-35)
    pedal = (bb[0] + math.cos(ca) * CRANK * scale, bb[1] - math.sin(ca) * CRANK * scale)
    tube(bb, pedal, 0.9, PART)
    d.rounded_rectangle([pedal[0] - 1.9 * scale, pedal[1] - 0.6 * scale,
                         pedal[0] + 1.9 * scale, pedal[1] + 0.6 * scale],
                        radius=0.3 * scale, fill=PART)

    # Fork, stem and bars (black), then the painted frame over them.
    tube(f["head_b"], front, 1.1, PART)
    tube(f["head_t"], f["bars"], 1.3, PART)
    tube((f["bars"][0] - 2.2 * scale, f["bars"][1] - 0.4 * scale),
         (f["bars"][0] + 1.4 * scale, f["bars"][1] + 0.4 * scale), 1.2, PART)
    tube(f["seat_j"], f["seat"], 1.0, CHROME)
    seat = f["seat"]
    d.ellipse([seat[0] - 5.0 * scale, seat[1] - 1.6 * scale,
               seat[0] + 4.2 * scale, seat[1] + 0.9 * scale], fill=PART)

    for a, b, w in (
            (rear, f["bb"], 1.0),           # chain stay
            (rear, f["seat_j"], 1.0),       # seat stay
            (f["bb"], f["seat_j"], 1.5),    # seat tube
            (f["head_b"], f["bb"], 1.7),    # down tube
            (f["seat_j"], f["head_t"], 1.5),  # top tube
            (f["head_t"], f["head_b"], 1.9),  # head tube
    ):
        tube(a, b, w, PAINT)
    # A highlight along the top tube and down tube, the gloss the paint has.
    for a, b in ((f["seat_j"], f["head_t"]), (f["head_b"], f["bb"])):
        off = (0, -0.35 * scale)
        d.line([(a[0] + off[0], a[1] + off[1]), (b[0] + off[0], b[1] + off[1])],
               fill=PAINT_HI, width=max(1, round(0.35 * scale)))

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
