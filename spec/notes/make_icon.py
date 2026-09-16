# PenPDF app icon: line-art pencil (white fill, black outline) on red.
# Geometry is rotated mathematically and drawn directly on the background
# (no raster rotation ⇒ no soft/"shadow" edges).
import math
from PIL import Image, ImageDraw
S = 8
N = 1024 * S
RED = (206, 3, 20); WHITE = (255, 255, 255); BLACK = (0, 0, 0)

img = Image.new("RGB", (N, N), RED)
d = ImageDraw.Draw(img)

# pencil in local coords (vertical, tip at bottom), then rotated -45° about the center
cx = N // 2
w = int(330 * S); x0, x1 = cx - w // 2, cx + w // 2
top = int(140 * S); r = int(70 * S)
ferrule_top = top + int(150 * S)
ferrule_bot = ferrule_top + int(100 * S)
bottom = int(895 * S)
cone_top = bottom - int(250 * S)
lead_h = int(120 * S)
lw = int(26 * S)

ANG = math.radians(45)          # clockwise on screen ⇒ tip bottom-left
def R(p):
    x, y = p[0] - cx, p[1] - N / 2
    return (cx + x * math.cos(ANG) - y * math.sin(ANG), N / 2 + x * math.sin(ANG) + y * math.cos(ANG))

def arc_pts(cx_, cy_, rx, ry, a0, a1, n=24):
    return [(cx_ + rx * math.cos(math.radians(a0 + (a1 - a0) * t / n)),
             cy_ + ry * math.sin(math.radians(a0 + (a1 - a0) * t / n))) for t in range(n + 1)]

def silhouette(i):
    """Outline path of the pencil inset by i (rounded eraser top, straight sides, cone)."""
    rr = max(r - i, 1)
    A, B, C = (x0, cone_top), (x1, cone_top), (cx, bottom)
    if i > 0:   # inset triangle = scaled about the incenter
        a = math.dist(B, C); b = math.dist(C, A); c = math.dist(A, B)
        I = ((a * A[0] + b * B[0] + c * C[0]) / (a + b + c), (a * A[1] + b * B[1] + c * C[1]) / (a + b + c))
        area = abs((B[0] - A[0]) * (C[1] - A[1]) - (C[0] - A[0]) * (B[1] - A[1])) / 2
        rin = area / ((a + b + c) / 2); k = (rin - i) / rin
        A, B, C = [(I[0] + (P[0] - I[0]) * k, I[1] + (P[1] - I[1]) * k) for P in (A, B, C)]
    pts = [(x0 + i, cone_top), (x0 + i, top + i + rr)]
    pts += arc_pts(x0 + i + rr, top + i + rr, rr, rr, 180, 270)
    pts += arc_pts(x1 - i - rr, top + i + rr, rr, rr, 270, 360)
    pts += [(x1 - i, cone_top), B, C, A]
    return [R(p) for p in pts]

# centre the pencil's bounding box in the tile (the eraser end is the heavy
# part, so centring on the rotation centre leaves it sitting high)
_pts = silhouette(0)
_bx = (min(q[0] for q in _pts) + max(q[0] for q in _pts)) / 2
_by = (min(q[1] for q in _pts) + max(q[1] for q in _pts)) / 2
_dx, _dy = N / 2 - _bx, N / 2 - _by
_R = R
def R(p):
    q = _R(p); return (q[0] + _dx, q[1] + _dy)
d.polygon(silhouette(0), fill=BLACK)
d.polygon(silhouette(lw), fill=WHITE)

# lead (black), small
lx = (w / 2) * lead_h / (bottom - cone_top)
d.polygon([R((cx - lx, bottom - lead_h)), R((cx + lx, bottom - lead_h)), R((cx, bottom))], fill=BLACK)

def line(pts): d.line([R(p) for p in pts], fill=BLACK, width=lw, joint="curve")
# ferrule band
line([(x0, ferrule_top), (x1, ferrule_top)])
line([(x0, ferrule_bot), (x1, ferrule_bot)])
# facets
for k in (1, 2):
    fx = x0 + w * k / 3
    line([(fx, ferrule_bot), (fx, cone_top)])
# facet ends: three arcs bulging into the cone
bump = int(30 * S)
for k in range(3):
    xa, xb = x0 + w * k / 3, x0 + w * (k + 1) / 3
    # keep the stroke inside the outline band at the outer corners
    if k == 0: xa += lw / 2
    if k == 2: xb -= lw / 2
    line(arc_pts((xa + xb) / 2, cone_top, (xb - xa) / 2, bump, 0, 180))

out = img.resize((1024, 1024), Image.BOX)   # area average: no ringing halo at hard edges
out.save("build/icon/AppIcon-1024.png")
mask = Image.new("L", (1024, 1024), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, 1023, 1023], radius=230, fill=255)
p = Image.new("RGB", (1024, 1024), (240, 240, 244)); p.paste(out, mask=mask); p.save("build/icon/preview.png")
print("ok")
