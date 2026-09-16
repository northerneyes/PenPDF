from PIL import Image, ImageDraw
S = 4                      # supersample
N = 1024 * S
RED = (206, 3, 20, 255); WHITE = (255, 255, 255, 255); BLACK = (20, 20, 20, 255)

bg = Image.new("RGBA", (N, N), RED)

# Pencil drawn vertically on a transparent layer, then rotated 45°.
L = Image.new("RGBA", (N, N), (0, 0, 0, 0))
d = ImageDraw.Draw(L)
cx = N // 2
w = int(250 * S)            # pencil width
top = int(95 * S)          # eraser top
bottom = int(930 * S)       # tip point
tip_h = int(185 * S)        # cone height
lead_h = int(70 * S)
band_h = int(40 * S)
r = int(50 * S)

x0, x1 = cx - w // 2, cx + w // 2
cone_top = bottom - tip_h
# body (white) with rounded top
d.rounded_rectangle([x0, top, x1, cone_top], radius=r, fill=WHITE)
d.rectangle([x0, cone_top - r, x1, cone_top], fill=WHITE)
# black band below the eraser
d.rectangle([x0, top + int(140 * S), x1, top + int(140 * S) + band_h], fill=BLACK)
# cone (white) and lead (black)
d.polygon([(x0, cone_top), (x1, cone_top), (cx, bottom)], fill=WHITE)
lead_top = bottom - lead_h
lx = (w // 2) * lead_h / tip_h
d.polygon([(cx - lx, lead_top), (cx + lx, lead_top), (cx, bottom)], fill=BLACK)

L = L.rotate(-45, resample=Image.BICUBIC, center=(cx, N // 2))
# shift slightly so the pencil sits centered visually (tip toward bottom-right)
bg.alpha_composite(L, (int(0 * S), int(0 * S)))
out = bg.resize((1024, 1024), Image.LANCZOS).convert("RGB")
out.save("build/icon/AppIcon-1024.png")
# rounded preview to judge like on the home screen
prev = out.copy(); mask = Image.new("L", (1024, 1024), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, 1023, 1023], radius=230, fill=255)
p = Image.new("RGB", (1024, 1024), (240, 240, 244)); p.paste(prev, mask=mask); p.save("build/icon/preview.png")
print("ok")
