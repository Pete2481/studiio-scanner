#!/usr/bin/env python3
"""Visualize wall segments, floor polygon, openings, and plane anchors from a .studiio scan."""

import json
import math
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("pip install Pillow")
    exit(1)

SCAN_DIR = Path(__file__).parent / "untitled-2026-05-19t08-14-05z.studiio"

# Load data
with open(SCAN_DIR / "metadata.json") as f:
    meta = json.load(f)

with open(SCAN_DIR / "planes" / "index.json") as f:
    planes_data = json.load(f)

room = meta["floors"][0]["rooms"][0]
walls = room["walls"]
openings = room["openings"]
floor_poly = room["floorPolygon"]
objects = room["objects"]
planes = planes_data["planes"]

# Image settings
IMG_W, IMG_H = 1200, 1200
MARGIN = 100
BG_COLOR = (20, 20, 25)
WALL_COLOR = (255, 140, 0)        # Orange walls
WALL_FILL = (255, 140, 0, 60)
POLY_COLOR = (255, 200, 50, 40)   # Floor polygon fill
POLY_OUTLINE = (255, 200, 50, 120)
DOOR_COLOR = (0, 200, 255)        # Cyan for doors
WINDOW_COLOR = (100, 255, 100)    # Green for windows
OBJECT_COLOR = (200, 100, 255)    # Purple for objects
PLANE_WALL = (255, 100, 100, 50)
PLANE_FLOOR = (100, 255, 100, 50)
PLANE_CEILING = (100, 100, 255, 50)
TEXT_COLOR = (200, 200, 200)
DIM_COLOR = (255, 200, 100)

# Gather all XZ points for bounds
all_x = []
all_z = []
for w in walls:
    all_x.extend([w["startX"], w["endX"]])
    all_z.extend([w["startZ"], w["endZ"]])
for p in floor_poly:
    all_x.append(p["x"])
    all_z.append(p["z"])

min_x, max_x = min(all_x), max(all_x)
min_z, max_z = min(all_z), max(all_z)

# Add padding
pad = 0.5
min_x -= pad; max_x += pad
min_z -= pad; max_z += pad

range_x = max_x - min_x
range_z = max_z - min_z
scale = min((IMG_W - 2*MARGIN) / range_x, (IMG_H - 2*MARGIN) / range_z)

def to_px(x, z):
    """Convert world XZ to pixel coords (Z flipped for screen)."""
    px = MARGIN + (x - min_x) * scale
    py = MARGIN + (max_z - z) * scale  # flip Z
    return int(px), int(py)

# Create image
img = Image.new("RGBA", (IMG_W, IMG_H), BG_COLOR)
draw = ImageDraw.Draw(img, "RGBA")

# Try to get a font
try:
    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 14)
    font_small = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 11)
    font_title = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 20)
except:
    font = ImageFont.load_default()
    font_small = font
    font_title = font

# 1. Draw floor polygon fill
if floor_poly:
    poly_pts = [to_px(p["x"], p["z"]) for p in floor_poly]
    draw.polygon(poly_pts, fill=POLY_COLOR, outline=POLY_OUTLINE)

# 2. Draw plane anchors as rectangles (world-space projection)
for plane in planes:
    t = plane["transform"]
    # Extract world position from transform column 3
    wx = t[12]
    wz = t[14]
    ext_x = plane["extentX"] / 2
    ext_z = plane["extentZ"] / 2

    cls = plane["classification"]
    if plane["alignment"] == "horizontal":
        # Draw as a rectangle at world position
        color = PLANE_FLOOR if cls == "floor" else PLANE_CEILING if cls == "ceiling" else (150, 150, 150, 30)
        p1 = to_px(wx - ext_x, wz - ext_z)
        p2 = to_px(wx + ext_x, wz + ext_z)
        # Ensure coords are in correct order for PIL
        x0, x1 = min(p1[0], p2[0]), max(p1[0], p2[0])
        y0, y1 = min(p1[1], p2[1]), max(p1[1], p2[1])
        draw.rectangle([x0, y0, x1, y1], fill=color)
        cx, cy = to_px(wx, wz)
        draw.text((cx-15, cy-6), cls.upper(), fill=TEXT_COLOR, font=font_small)

# 3. Draw walls with thickness
for w in walls:
    sx, sz = w["startX"], w["startZ"]
    ex, ez = w["endX"], w["endZ"]
    p1 = to_px(sx, sz)
    p2 = to_px(ex, ez)

    # Draw wall line (thick)
    thickness_px = max(3, int(w["thickness"] * scale))
    draw.line([p1, p2], fill=WALL_COLOR, width=thickness_px)

    # Draw endpoints
    for pt in [p1, p2]:
        draw.ellipse([pt[0]-3, pt[1]-3, pt[0]+3, pt[1]+3], fill=WALL_COLOR)

    # Label with length
    mid_x = (p1[0] + p2[0]) // 2
    mid_y = (p1[1] + p2[1]) // 2
    length_mm = int(w["length"] * 1000)
    draw.text((mid_x + 5, mid_y - 8), f"{length_mm}mm", fill=DIM_COLOR, font=font_small)

# 4. Draw openings
for op in openings:
    px, py = to_px(op["positionX"], op["positionZ"])
    w_px = int(op["width"] * scale / 2)

    if op["kind"] == "standardDoor":
        color = DOOR_COLOR
        # Door arc symbol
        draw.arc([px - w_px, py - w_px, px + w_px, py + w_px], 0, 90, fill=color, width=2)
        draw.text((px + 5, py + 5), f"Door {int(op['width']*1000)}mm", fill=color, font=font_small)
    elif "window" in op["kind"].lower():
        color = WINDOW_COLOR
        draw.line([px - w_px, py, px + w_px, py], fill=color, width=3)
        draw.text((px + 5, py + 5), f"Window {int(op['width']*1000)}mm", fill=color, font=font_small)

# 5. Draw plane-detected doors and windows
for plane in planes:
    cls = plane["classification"]
    if cls in ("door", "window"):
        t = plane["transform"]
        wx, wz = t[12], t[14]
        px, py = to_px(wx, wz)
        ext = plane["extentX"]
        color = DOOR_COLOR if cls == "door" else WINDOW_COLOR
        r = int(ext * scale / 2)
        draw.rectangle([px-r, py-4, px+r, py+4], outline=color, width=2)
        draw.text((px + r + 4, py - 6), f"Plane:{cls} {ext:.1f}m", fill=color, font=font_small)

# 6. Draw objects
for obj in objects:
    px, py = to_px(obj["positionX"], obj["positionZ"])
    dx = int(obj["dimensionsX"] * scale / 2)
    dz = int(obj["dimensionsZ"] * scale / 2)
    draw.rectangle([px-dx, py-dz, px+dx, py+dz], outline=OBJECT_COLOR, width=2)
    draw.text((px - dx, py - dz - 14), obj["category"], fill=OBJECT_COLOR, font=font_small)

# 7. Title and stats
draw.text((20, 15), "STUDIIO SCAN DATA VISUALIZATION", fill=WALL_COLOR, font=font_title)
draw.text((20, 42), f"untitled-2026-05-19t08-14-05z", fill=TEXT_COLOR, font=font)

stats = [
    f"Room: {room['roomWidth']:.2f}m x {room['roomDepth']:.2f}m = {room['area']:.1f} sqm",
    f"Ceiling height: {room['ceilingLevel'] - room['floorLevel']:.2f}m",
    f"Walls: {len(walls)} | Openings: {len(openings)} | Objects: {len(objects)}",
    f"Plane anchors: {len(planes)} (wall:{sum(1 for p in planes if p['classification']=='wall')}, "
    f"floor:{sum(1 for p in planes if p['classification']=='floor')}, "
    f"ceiling:{sum(1 for p in planes if p['classification']=='ceiling')}, "
    f"door:{sum(1 for p in planes if p['classification']=='door')}, "
    f"window:{sum(1 for p in planes if p['classification']=='window')})",
    f"Wall alignment: {math.degrees(room['wallAlignmentAngle']):.1f} deg",
    f"Floor polygon: {len(floor_poly)} vertices",
]
y = 65
for s in stats:
    draw.text((20, y), s, fill=TEXT_COLOR, font=font_small)
    y += 16

# Legend
legend_y = IMG_H - 120
legend_items = [
    (WALL_COLOR, "Walls (RANSAC)"),
    (DOOR_COLOR, "Doors"),
    (WINDOW_COLOR, "Windows"),
    (OBJECT_COLOR, "Objects"),
    ((255, 200, 50), "Floor polygon"),
]
for color, label in legend_items:
    draw.rectangle([20, legend_y, 35, legend_y+12], fill=color)
    draw.text((42, legend_y - 1), label, fill=TEXT_COLOR, font=font_small)
    legend_y += 18

# Scale bar
bar_m = 1.0  # 1 metre
bar_px = int(bar_m * scale)
bar_y = IMG_H - 30
bar_x = IMG_W - MARGIN - bar_px
draw.line([bar_x, bar_y, bar_x + bar_px, bar_y], fill=TEXT_COLOR, width=2)
draw.line([bar_x, bar_y-5, bar_x, bar_y+5], fill=TEXT_COLOR, width=1)
draw.line([bar_x+bar_px, bar_y-5, bar_x+bar_px, bar_y+5], fill=TEXT_COLOR, width=1)
draw.text((bar_x + bar_px//2 - 10, bar_y - 18), "1 metre", fill=TEXT_COLOR, font=font_small)

# Save
out_path = Path(__file__).parent / "scan_visualization.png"
img.save(str(out_path))
print(f"Saved: {out_path}")
print(f"\nData captured:")
for s in stats:
    print(f"  {s}")
