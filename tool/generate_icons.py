"""Render the checked-in vector mark to every Android and iOS launcher size.

Run: python -m pip install cairosvg pillow && python tool/generate_icons.py
"""
import json
from pathlib import Path
import cairosvg
from PIL import Image

root = Path(__file__).resolve().parents[1]
source = root / "assets/brand/home-listen-icon.svg"
android = root / "android/app/src/main/res"
for density, size in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
    target = android / ("mipmap-" + density) / "ic_launcher.png"
    cairosvg.svg2png(url=str(source), write_to=str(target), output_width=size, output_height=size)
    with Image.open(target) as image:
        image.convert("RGB").save(target)
ios = root / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
catalog = json.loads((ios / "Contents.json").read_text())
for entry in catalog["images"]:
    if "filename" not in entry:
        continue
    size = round(float(entry["size"].split("x")[0]) * float(entry["scale"].rstrip("x")))
    target = ios / entry["filename"]
    cairosvg.svg2png(url=str(source), write_to=str(target), output_width=size, output_height=size)
    with Image.open(target) as image:
        image.convert("RGB").save(target)
print("Generated all launcher sizes from the Home Listen vector mark.")
