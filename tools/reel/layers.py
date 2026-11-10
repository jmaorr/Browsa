#!/usr/bin/env python3
"""Cuts a SpikeBrowsa window shot into the reel's layers.

The shot is 2x (2880x1800 for a 1440x900 window). Sidebar pieces are colour-keyed against the
sidebar's own background so they float as shapes, not rectangles. The page card gets the page
snapshot set into a rounded card. Run: layers.py base.png page.png outdir
"""
import json, sys
from PIL import Image, ImageDraw, ImageFilter

base_path, page_path, out = sys.argv[1], sys.argv[2], sys.argv[3]
base = Image.open(base_path).convert("RGBA")
W, H = base.size
bg = base.getpixel((240, 1200))[:3]

# Regions in 2x pixels, from a 1440x900 window.
R = {
    "toolbar": (0, 0, 520, 72),
    "address": (22, 79, 499, 142),
    "fav0": (22, 163, 130, 259), "fav1": (144, 163, 252, 259),
    "fav2": (266, 163, 374, 259), "fav3": (391, 163, 499, 259),
    "newtab": (22, 307, 499, 358),
    **{f"tab{i}": (22, 372 + 72 * i, 499, 436 + 72 * i) for i in range(6)},
    "bottom": (0, 1723, 532, 1781),
}
CARD = (533, 12, W - 12, H - 12)

def keyed(img):
    """Background-coloured pixels go transparent, with a soft ramp for anti-aliased edges."""
    px = img.load()
    for y in range(img.height):
        for x in range(img.width):
            r, g, b, a = px[x, y]
            d = abs(r - bg[0]) + abs(g - bg[1]) + abs(b - bg[2])
            if d < 10:
                px[x, y] = (r, g, b, 0)
            elif d < 30:
                px[x, y] = (r, g, b, int(a * (d - 10) / 20))
    return img

WINDOW_RADIUS = 46   # the real window's corner in 2x px, measured from the shot


def rounded_mask(w, h, r, inset=0):
    """An anti-aliased rounded-rect mask: drawn at 4x, scaled down."""
    k = 4
    m = Image.new("L", (w * k, h * k), 0)
    ImageDraw.Draw(m).rounded_rectangle((inset * k, inset * k, (w - inset) * k - 1, (h - inset) * k - 1), radius=r * k, fill=255)
    return m.resize((w, h), Image.LANCZOS)


def bleed(img):
    """Give fully transparent pixels their neighbours' colour, so filtering at an angle can't drag
    black in around the edges (the dark fringe on corners)."""
    rgb = img.convert("RGB")
    a = img.getchannel("A")
    solid = a.point(lambda v: 255 if v > 0 else 0)
    spread = rgb
    for _ in range(6):
        blurred = spread.filter(ImageFilter.MaxFilter(5))
        spread = Image.composite(spread, blurred, solid)
        solid = solid.filter(ImageFilter.MaxFilter(5))
    # Anything still unset gets the average edge colour.
    out = Image.composite(spread, Image.new("RGB", img.size, bg), solid)
    out.putalpha(a)
    return out


def find_lights(img):
    """The three traffic lights: discs on the toolbar that differ from the sidebar, as (cx, cy, r)."""
    px = img.load()
    off = lambda x, y: px[x, y][3] == 255 and sum(abs(px[x, y][i] - bg[i]) for i in range(3)) > 24
    cols = [x for x in range(10, 150) if sum(off(x, y) for y in range(15, 50)) > 3]
    groups, cur = [], [cols[0]]
    for x in cols[1:]:
        if x - cur[-1] > 2:
            groups.append(cur); cur = [x]
        else:
            cur.append(x)
    groups.append(cur)
    out = []
    for g in groups[:3]:
        cx = (g[0] + g[-1]) // 2
        ys = [y for y in range(5, 70) if off(cx, y)]
        out.append((cx, (ys[0] + ys[-1]) // 2, (g[-1] - g[0]) // 2 + 2))
    return out


meta = {"window": [W // 2, H // 2], "layers": {}}
lights = find_lights(base)
for name, box in R.items():
    crop = keyed(base.crop(box).copy())
    if name == "toolbar":
        # The grey lights live on their own layer, in colour.
        cd = ImageDraw.Draw(crop)
        for cx, cy, r in lights:
            cd.ellipse((cx - r - 2, cy - r - 2, cx + r + 2, cy + r + 2), fill=bg + (0,))
    crop = bleed(crop)
    crop.save(f"{out}/{name}.png")
    meta["layers"][name] = [box[0] / 2, box[1] / 2, (box[2] - box[0]) / 2, (box[3] - box[1]) / 2]

# The bare window: the sidebar's pieces and the page card cleared to the window's own surface.
bare = base.copy()
d = ImageDraw.Draw(bare)
for box in list(R.values()) + [CARD]:
    if box == R["toolbar"]:
        # Keep the traffic lights; clear the toolbar buttons beside them.
        d.rectangle((150, 0, box[2], box[3]), fill=bg + (255,))
        continue
    d.rectangle((box[0] - 4, box[1] - 4, box[2] + 4, box[3] + 4), fill=bg + (255,))
# Traffic lights in colour, as on an active window.
ld = ImageDraw.Draw(bare)
for (cx, cy, r), col in zip(lights, ((255, 95, 87), (254, 188, 46), (40, 200, 64))):
    ld.ellipse((cx - r - 4, cy - r - 4, cx + r + 4, cy + r + 4), fill=bg + (255,))
# Rounded window corners, drawn at 4x and scaled down so the curve is smooth, not stair-stepped.
bare.putalpha(rounded_mask(W, H, WINDOW_RADIUS))
bare = bleed(bare)
bare.save(f"{out}/window.png")
# The lights go on their own layer so they stay crisp circles.
lw = Image.new("RGBA", (W, H), (0, 0, 0, 0))
for (cx, cy, r), col in zip(lights, ((255, 95, 87), (254, 188, 46), (40, 200, 64))):
    disc = rounded_mask(int(2 * r + 4), int(2 * r + 4), r, inset=2)
    lw.paste(Image.new("RGBA", disc.size, col + (255,)), (cx - r - 2, cy - r - 2), disc)
lw = bleed(lw)
box = (0, 0, 160, 80)
lw.crop(box).save(f"{out}/lights.png")
meta["layers"]["lights"] = [0, 0, 80, 40]
meta["layers"]["window"] = [0, 0, W / 2, H / 2]

# The page card: the page snapshot in a rounded card.
cw, ch = CARD[2] - CARD[0], CARD[3] - CARD[1]
# "-" takes the page straight from the window shot (when it painted); else a separate snapshot.
page = (base.crop(CARD) if page_path == "-" else Image.open(page_path).convert("RGBA").resize((cw, ch), Image.LANCZOS)).copy()
cmask = Image.new("L", (cw, ch), 0)
page.putalpha(rounded_mask(cw, ch, 20))
page = bleed(page)
page.save(f"{out}/card.png")
meta["layers"]["card"] = [CARD[0] / 2, CARD[1] / 2, cw / 2, ch / 2]

json.dump(meta, open(f"{out}/layers.json", "w"), indent=1)
print("ok", len(meta["layers"]), "layers")
