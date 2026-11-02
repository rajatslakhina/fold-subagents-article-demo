"""Puts real Simulator screenshots side by side for the README and article.
Usage: compose_simulator.py OUT.png IN1.png IN2.png [IN3.png ...]"""
import sys
from PIL import Image, ImageDraw

out, inputs = sys.argv[1], sys.argv[2:]
height, pad = 900, 40
images = []
for path in inputs:
    img = Image.open(path).convert("RGB")
    scale = height / img.height
    images.append(img.resize((int(img.width * scale), height)))
width = sum(i.width for i in images) + pad * (len(images) + 1)
canvas = Image.new("RGB", (width, height + pad * 2), (241, 245, 249))
draw = ImageDraw.Draw(canvas)
x = pad
for img in images:
    canvas.paste(img, (x, pad))
    draw.rectangle([x - 1, pad - 1, x + img.width, pad + img.height], outline=(148, 163, 184), width=2)
    x += img.width + pad
canvas.save(out, optimize=True)
