#!/usr/bin/env python3
# The gallery's "extras" picture: the bike rack rendered from its own code
# (tools/bike/export_rack.lua through showcase.py) beside cards for the things
# with no code-built model to render -- the Bike Lock, the Filmer Camera and the
# rental machine -- each shown with the addon's own spawn-menu pictures
# (materials/entities/*.png, shot in game by tools/icons/shoot.sh).
#
#   python3 tools/bike/extras_sheet.py rack.jpg out.jpg
import sys, os
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import showcase as S

ROOT = S.ROOT
ICONS = os.path.join(ROOT, "materials", "entities")
W, H = 1280, 720
INK = (27, 40, 56)
TEXT = (236, 240, 244)
DIM = (160, 178, 196)
# the rental machine and the /bike window show these, in the spawn menu's order
RIDES = ["bmx_base", "bmx_cruiser", "bmx_mini", "bmx_road", "bmx_fixie", "bmx_city", "bmx_tandem",
         "bmx_dh", "bmx_unicycle", "bmx_penny", "bmx_scooter", "bmx_skateboard", "weapon_bmx_skates",
         "bmx_ebike", "bmx_emoto", "bmx_dirtbike", "bmx_moped"]


def icon(name, px):
    im = Image.open(os.path.join(ICONS, name + ".png")).convert("RGBA")
    return im.resize((px, px), Image.LANCZOS)


def wrap(draw, text, f, width):
    lines, cur = [], ""
    for word in text.split():
        t = (cur + " " + word).strip()
        if draw.textlength(t, font=f) <= width:
            cur = t
        else:
            lines.append(cur)
            cur = word
    return lines + [cur]


def card(sheet, box, title, body, pics, pic_px):
    d = ImageDraw.Draw(sheet)
    x0, y0, x1, y1 = box
    d.rounded_rectangle(box, radius=10, fill=INK)
    ft, fb = S.font(22), S.font(15)
    tx = x0 + 18
    if len(pics) == 1:                          # one picture: on the left, the words beside it
        sheet.alpha_composite(icon(pics[0], pic_px), (x0 + 14, y0 + (y1 - y0 - pic_px) // 2))
        tx = x0 + pic_px + 30
    d.text((tx, y0 + 16), title, font=ft, fill=TEXT)
    y = y0 + 48
    for line in wrap(d, body, fb, x1 - tx - 16):
        d.text((tx, y), line, font=fb, fill=DIM)
        y += 21
    if len(pics) > 1:                           # many: a strip under the words
        px, gap = pic_px, 6
        per = max(1, (x1 - x0 - 28 + gap) // (px + gap))
        for i, name in enumerate(pics):
            r, c = divmod(i, per)
            sheet.alpha_composite(icon(name, px), (x0 + 14 + c * (px + gap), y + 6 + r * (px + gap)))


def main(rack_path, out):
    sheet = Image.new("RGBA", (W, H))
    top, bot = (204, 211, 222), (165, 170, 178)
    for yy in range(H):                          # the studio backdrop the renders use
        t = yy / (H - 1)
        sheet.paste(tuple(round(top[i] + (bot[i] - top[i]) * t) for i in range(3)) + (255,), (0, yy, W, yy + 1))
    rack = Image.open(rack_path).convert("RGBA")
    mask = Image.new("L", rack.size, 0)          # a rounded card, so the render's own backdrop reads as a frame
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, rack.width - 1, rack.height - 1), radius=10, fill=255)
    rack.putalpha(mask)
    rx, ry = 24, H - rack.height - 24
    sheet.alpha_composite(rack, (rx, ry))
    d = ImageDraw.Draw(sheet)
    S.pill(d, rx + rack.width / 2, ry + rack.height - 30, "Bike Rack: welds to a car, carries two bikes", 17)
    cx0, cx1 = 680, W - 24
    card(sheet, (cx0, 96, cx1, 216), "Bike Lock",
         "Lock a parked bike to the ground. Only you, or an admin, can unlock it, and it says who locked it.",
         ["weapon_bmx_lock"], 96)
    card(sheet, (cx0, 228, cx1, 348), "Filmer Camera",
         "For admins: put one by a line and look through it. It pans after the rider like a person holding it.",
         ["bmx_filmer_cam"], 96)
    card(sheet, (cx0, 360, cx1, H - 24), "Bike Rental",
         "A free vending machine: press E, click a picture, ride. These are its pictures, one for every ride.",
         RIDES, 64)
    im = S.annotate(sheet.convert("RGB"), [], "Extras: a rack, a lock, a filming camera and a free rental", W, H)
    im.save(out, quality=90, optimize=True, progressive=True, subsampling=0)
    print("wrote", out, os.path.getsize(out), "bytes")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
