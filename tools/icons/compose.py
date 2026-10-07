"""Turn the studio's render pairs into spawn-menu icons.

    python3 tools/icons/compose.py RAW_DIR [OUT_DIR] [SIZE]

RAW_DIR holds <class>_k.png and <class>_w.png, the same frame drawn on black and on
white (tools/icons/studio_cl.lua). The difference between them is the matte, so the
item comes out with clean anti-aliased edges whatever its colours are. Each item is
cropped to itself, laid on one shared studio tile (soft gradient, a drop shadow from
its own silhouette, rounded corners) and written as OUT_DIR/<class>.png, SIZE square
(default materials/entities, 128: the size the Q menu draws them).

PARK PIECES KEEP THEIR SIZES. The S, M and L of a shape are cut with the L's crop
(the studio shot all three from the same camera), so S is visibly smaller than L,
and each gets an S / M / L badge. Without that the three icons would be identical.

Needs Pillow and numpy. Build-time only.
"""
import re, sys, pathlib
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = pathlib.Path(__file__).resolve().parents[2]
raw = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "materials" / "entities"
SIZE = int(sys.argv[3]) if len(sys.argv) > 3 else 128
W = 512                      # composed at 4x, then scaled down
out.mkdir(parents=True, exist_ok=True)

def matte(cls):
    k = np.asarray(Image.open(raw / f"{cls}_k.png").convert("RGB"), dtype=np.float32) / 255
    w = np.asarray(Image.open(raw / f"{cls}_w.png").convert("RGB"), dtype=np.float32) / 255
    a = np.clip(1 - (w - k).mean(axis=2), 0, 1)
    a[a < 0.03] = 0
    rgb = np.where(a[..., None] > 0, k / np.maximum(a[..., None], 1e-3), 0)
    return np.clip(rgb, 0, 1), a

def bbox(a):
    ys, xs = np.nonzero(a > 0.05)
    return xs.min(), ys.min(), xs.max() + 1, ys.max() + 1

def backdrop():
    y = np.linspace(0, 1, W)[:, None, None]
    top, bot = np.array([0.93, 0.95, 0.98]), np.array([0.70, 0.74, 0.80])
    g = top * (1 - y) + bot * y
    img = np.broadcast_to(g, (W, W, 3)).copy()
    # a soft light behind the item
    yy, xx = np.mgrid[0:W, 0:W]
    r = np.hypot((xx - W / 2) / W, (yy - W * 0.45) / W)
    img += (np.clip(0.42 - r, 0, None) * 0.25)[..., None]
    return np.clip(img, 0, 1)

def compose(cls, crop, badge=None):
    rgb, a = matte(cls)
    x0, y0, x1, y1 = crop
    cw, ch = x1 - x0, y1 - y0
    inner = W * 0.86
    s = inner / max(cw, ch)
    nw, nh = max(1, round(cw * s)), max(1, round(ch * s))
    rgba = np.dstack([rgb, a])[y0:y1, x0:x1]
    item = Image.fromarray((rgba * 255).astype(np.uint8), "RGBA").resize((nw, nh), Image.LANCZOS)
    ox, oy = round((W - nw) / 2), round((W - nh) / 2 + W * 0.02)
    bg = Image.fromarray((backdrop() * 255).astype(np.uint8), "RGB").convert("RGBA")
    # a soft drop shadow from the item's own silhouette, so it sits on the tile
    al = Image.new("L", (W, W), 0)
    al.paste(item.split()[3], (ox, oy + int(W * 0.025)))
    al = al.filter(ImageFilter.GaussianBlur(W * 0.018)).point(lambda v: int(v * 0.45))
    shadow = Image.new("RGBA", (W, W), (20, 24, 32, 0))
    shadow.putalpha(al)
    bg = Image.alpha_composite(bg, shadow)
    layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    layer.paste(item, (ox, oy))
    bg = Image.alpha_composite(bg, layer)
    if badge:
        d = ImageDraw.Draw(bg)
        f = ImageFont.truetype("DejaVuSans-Bold.ttf", int(W * 0.15))
        bw = W * 0.21
        d.rounded_rectangle([W - bw - W * 0.04, W * 0.04, W - W * 0.04, W * 0.04 + bw], radius=W * 0.04,
                            fill=(32, 40, 56, 235))
        d.text((W - W * 0.04 - bw / 2, W * 0.04 + bw / 2), badge, font=f, fill=(255, 255, 255), anchor="mm")
    # rounded tile, transparent corners, like the base game's icons
    mask = Image.new("L", (W, W), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, W - 1, W - 1], radius=W * 0.06, fill=255)
    bg.putalpha(mask)
    bg.resize((SIZE, SIZE), Image.LANCZOS).save(out / f"{cls}.png", optimize=True)

classes = sorted({p.name[:-6] for p in raw.glob("*_k.png")})
groups = {}
for c in classes:
    m = re.match(r"^(bmx_park_[a-z]+?)(?:_v\d)?_([sml])$", c)
    if m: groups.setdefault(m.group(1), []).append((c, m.group(2)))

def padded(b, a_shape, pad=0.04):
    x0, y0, x1, y1 = b
    p = int(max(x1 - x0, y1 - y0) * pad)
    return max(0, x0 - p), max(0, y0 - p), min(a_shape[1], x1 + p), min(a_shape[0], y1 + p)

# Smallest share of the tile an item may take. Below this a small piece is a speck
# nobody can read, so it is scaled up -- the badge still says S, and it is still
# visibly smaller than its L.
MIN_FILL = 0.6

def shrink_to(crop, item):
    cx0, cy0, cx1, cy1 = crop
    ix0, iy0, ix1, iy1 = item
    c = max(cx1 - cx0, cy1 - cy0)
    e = max(ix1 - ix0, iy1 - iy0)
    if e >= MIN_FILL * c:
        return crop
    k = e / (MIN_FILL * c)
    # scale the crop about the item's centre, keeping its shape
    mx, my = (ix0 + ix1) / 2, (iy0 + iy1) / 2
    hw, hh = (cx1 - cx0) * k / 2, (cy1 - cy0) * k / 2
    return max(0, int(mx - hw)), max(0, int(my - hh)), min(W, int(mx + hw)), min(W, int(my + hh))

done = set()
for g, members in groups.items():
    # ONE crop per shape: the box round every L (all variants), which the studio shot
    # from the same camera, so Low / Mid / Tall and S / M / L keep their real sizes
    boxes = []
    for c, size in members:
        if size == "l":
            boxes.append(bbox(matte(c)[1]))
    if not boxes:
        boxes = [bbox(matte(c)[1]) for c, _ in members]
    _, a = matte(members[0][0])
    union = (min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes))
    crop = padded(union, a.shape)
    for c, size in members:
        compose(c, shrink_to(crop, bbox(matte(c)[1])), badge=size.upper())
        done.add(c)
for c in classes:
    if c in done: continue
    _, a = matte(c)
    compose(c, padded(bbox(a), a.shape))
print(len(classes), "icons ->", out)
