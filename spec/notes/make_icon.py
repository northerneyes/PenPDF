# PenPDF app icon: line-art pencil (white fill, black outlines) on red.
from PIL import Image, ImageDraw
S = 4
N = 1024 * S
RED = (206, 3, 20, 255); WHITE = (255, 255, 255, 255); BLACK = (20, 20, 20, 255)

bg = Image.new("RGBA", (N, N), RED)
L = Image.new("RGBA", (N, N), (0, 0, 0, 0))
d = ImageDraw.Draw(L)

cx = N // 2
w = int(230 * S); x0, x1 = cx - w // 2, cx + w // 2
top = int(60 * S); r = int(46 * S)
ferrule_top = top + int(150 * S)
ferrule_bot = ferrule_top + int(95 * S)
bottom = int(935 * S)
cone_top = bottom - int(200 * S)
lead_h = int(72 * S)
lw = int(24 * S)                    # outline width

# --- silhouette: black, then the same shape inset by lw in white ---
import math
def silhouette(inset, color):
    i = inset
    d.rounded_rectangle([x0 + i, top + i, x1 - i, ferrule_bot + r], radius=max(r - i, 1), fill=color)
    d.rectangle([x0 + i, ferrule_bot, x1 - i, cone_top], fill=color)
    A, B, C = (x0, cone_top), (x1, cone_top), (cx, bottom)
    if i == 0:
        d.polygon([A, B, C], fill=color); return
    # inset triangle = outer triangle scaled about its incenter
    a = math.dist(B, C); b = math.dist(C, A); c = math.dist(A, B)
    I = ((a * A[0] + b * B[0] + c * C[0]) / (a + b + c), (a * A[1] + b * B[1] + c * C[1]) / (a + b + c))
    area = abs((B[0] - A[0]) * (C[1] - A[1]) - (C[0] - A[0]) * (B[1] - A[1])) / 2
    rin = area / ((a + b + c) / 2)
    k = (rin - i) / rin
    d.polygon([(I[0] + (P[0] - I[0]) * k, I[1] + (P[1] - I[1]) * k) for P in (A, B, C)], fill=color)
silhouette(0, BLACK)
silhouette(lw, WHITE)
lx = (w // 2) * lead_h / (bottom - cone_top)
d.polygon([(cx - lx, bottom - lead_h), (cx + lx, bottom - lead_h), (cx, bottom)], fill=BLACK)

def line(pts): d.line(pts, fill=BLACK, width=lw, joint="curve")
# ferrule band (two lines)
line([(x0, ferrule_top), (x1, ferrule_top)])
line([(x0, ferrule_bot), (x1, ferrule_bot)])
# facets
for k in (1, 2):
    fx = x0 + w * k // 3
    line([(fx, ferrule_bot), (fx, cone_top)])
# facet ends bulging into the cone
bump = int(48 * S)
for k in range(3):
    xa, xb = x0 + w * k // 3, x0 + w * (k + 1) // 3
    d.arc([xa, cone_top - bump, xb, cone_top + bump], 0, 180, fill=BLACK, width=lw)
# lead edge
line([(cx - lx, bottom - lead_h), (cx + lx, bottom - lead_h)])

L = L.rotate(-45, resample=Image.BICUBIC, center=(cx, N // 2))
bg.alpha_composite(L)
out = bg.resize((1024, 1024), Image.LANCZOS).convert("RGB")
out.save("build/icon/AppIcon-1024.png")
prev = out.copy(); mask = Image.new("L", (1024, 1024), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, 1023, 1023], radius=230, fill=255)
p = Image.new("RGB", (1024, 1024), (240, 240, 244)); p.paste(prev, mask=mask); p.save("build/icon/preview.png")
print("ok")
