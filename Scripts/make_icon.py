"""Turns Assets/logo-raw.png (squircle on white) into a transparent Assets/logo.png and Assets/Icon.icns."""
import os, subprocess, tempfile
from PIL import Image, ImageChops, ImageDraw

root = os.path.join(os.path.dirname(__file__), "..", "Assets")
img = Image.open(os.path.join(root, "logo-raw.png")).convert("RGB")

# Crop to the squircle: strongly blue pixels (the grey drop shadow and white background drop out).
r, _, b = img.split()
box = ImageChops.subtract(b, r).point(lambda p: 255 if p > 60 else 0).getbbox()
inset = int((box[2] - box[0]) * 0.03)  # trim the glassy rim
icon = img.crop((box[0] + inset, box[1] + inset, box[2] - inset, box[3] - inset)).resize((824, 824), Image.LANCZOS)

# Apple's macOS grid: 824px rounded rect (radius ~185) centered on a 1024 canvas.
mask = Image.new("L", (824 * 4, 824 * 4), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, 824 * 4 - 1, 824 * 4 - 1), radius=185 * 4, fill=255)
mask = mask.resize((824, 824), Image.LANCZOS)
out = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
out.paste(icon, (100, 100), mask)
out.save(os.path.join(root, "logo.png"))

with tempfile.TemporaryDirectory() as tmp:
    iconset = os.path.join(tmp, "Icon.iconset")
    os.mkdir(iconset)
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
            out.resize((size * scale, size * scale), Image.LANCZOS).save(os.path.join(iconset, name))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(root, "Icon.icns")], check=True)
print("wrote Assets/logo.png and Assets/Icon.icns")
