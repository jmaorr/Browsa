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
    "tab0": (22, 374, 499, 434), "tab1": (22, 446, 499, 506), "tab2": (22, 518, 499, 578),
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

meta = {"window": [W // 2, H // 2], "layers": {}}
for name, box in R.items():
    crop = keyed(base.crop(box).copy())
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
# Rounded window corners.
mask = Image.new("L", (W, H), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, W - 1, H - 1), radius=22, fill=255)
bare.putalpha(mask)
bare.save(f"{out}/window.png")
meta["layers"]["window"] = [0, 0, W / 2, H / 2]

# The page card: the page snapshot in a rounded card.
cw, ch = CARD[2] - CARD[0], CARD[3] - CARD[1]
page = Image.open(page_path).convert("RGBA").resize((cw, ch), Image.LANCZOS)
cmask = Image.new("L", (cw, ch), 0)
ImageDraw.Draw(cmask).rounded_rectangle((0, 0, cw - 1, ch - 1), radius=18, fill=255)
page.putalpha(cmask)
page.save(f"{out}/card.png")
meta["layers"]["card"] = [CARD[0] / 2, CARD[1] / 2, cw / 2, ch / 2]

json.dump(meta, open(f"{out}/layers.json", "w"), indent=1)
print("ok", len(meta["layers"]), "layers")
