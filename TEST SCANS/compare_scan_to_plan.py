#!/usr/bin/env python3
"""Compare scan data against the real architectural floor plan of the LIVING room."""

import json
import math
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("pip install Pillow")
    exit(1)

SCAN_DIR = Path(__file__).parent / "untitled-2026-05-19t08-14-05z.studiio"

with open(SCAN_DIR / "metadata.json") as f:
    meta = json.load(f)
with open(SCAN_DIR / "planes" / "index.json") as f:
    planes_data = json.load(f)

room = meta["floors"][0]["rooms"][0]
walls = room["walls"]
openings = room["openings"]
floor_poly = room["floorPolygon"]
planes = planes_data["planes"]

# The walls are in world space, rotated by wallAlignmentAngle.
# To compare with the architectural plan, we need to un-rotate them
# so walls align to horizontal/vertical axes.
angle = room["wallAlignmentAngle"]  # 0.89 rad = ~51 degrees
cos_a = math.cos(-angle)
sin_a = math.sin(-angle)

def unrotate(x, z):
    """Rotate point back to axis-aligned space."""
    return (x * cos_a - z * sin_a, x * sin_a + z * cos_a)

# Un-rotate all wall endpoints
aligned_walls = []
for w in walls:
    sx, sz = unrotate(w["startX"], w["startZ"])
    ex, ez = unrotate(w["endX"], w["endZ"])
    aligned_walls.append({
        "sx": sx, "sz": sz, "ex": ex, "ez": ez,
        "length": w["length"], "thickness": w["thickness"],
        "angle": w["angle"], "id": w["id"]
    })

# Un-rotate floor polygon
aligned_poly = [unrotate(p["x"], p["z"]) for p in floor_poly]

# Un-rotate openings
aligned_openings = []
for op in openings:
    ox, oz = unrotate(op["positionX"], op["positionZ"])
    aligned_openings.append({"x": ox, "z": oz, "width": op["width"],
                              "height": op["height"], "kind": op["kind"]})

# Un-rotate plane-detected features
aligned_plane_features = []
for p in planes:
    if p["classification"] in ("door", "window"):
        t = p["transform"]
        wx, wz = unrotate(t[12], t[14])
        aligned_plane_features.append({
            "x": wx, "z": wz, "type": p["classification"],
            "width": p["extentX"]
        })

# Find bounding box of aligned walls
all_x = []
all_z = []
for w in aligned_walls:
    all_x.extend([w["sx"], w["ex"]])
    all_z.extend([w["sz"], w["ez"]])

min_x, max_x = min(all_x), max(all_x)
min_z, max_z = min(all_z), max(all_z)

scan_width = max_x - min_x
scan_depth = max_z - min_z

print("=" * 60)
print("SCAN vs REAL FLOOR PLAN COMPARISON")
print("=" * 60)
print(f"\nRoom: LIVING")
print(f"Scan date: 2026-05-19T08:14:05Z")
print()

print("--- ROOM DIMENSIONS ---")
print(f"  Scan roomWidth:  {room['roomWidth']*1000:.0f}mm")
print(f"  Scan roomDepth:  {room['roomDepth']*1000:.0f}mm")
print(f"  Aligned bbox:    {scan_width*1000:.0f}mm x {scan_depth*1000:.0f}mm")
print(f"  Area:            {room['area']:.1f} sqm")
print()

# From the architectural plan:
# Left wall: 340 + 1806_window + gap + 1806_window + 340 total height
# The 340mm segments are solid wall above/below each window
# Total left wall ≈ 340+1806+340+1806+340 ≈ 4632mm?
# But typical living room is more like 3400+3400 = separate dim marks
# The dimensions show 340, 340 on the left - these are likely wall-to-window margins
# Real room likely about 3400mm tall (each 340 is 3400mm = 3.4m segments?)
# Actually 340 in Australian plans at this scale = 3400mm. No - the text says 340.

print("--- FROM ARCHITECTURAL PLAN ---")
print("  Left wall: Two AR 1806 AWN windows")
print("  Dim marks on left: 340mm + 340mm segments (wall between features)")
print("  Bottom right: 1500mm dimension (likely window/opening)")
print("  Bottom left: Door (swing arc)")
print("  Top: Service void 530x210mm, ROBE 5 above")
print()

print("--- CEILING HEIGHT ---")
print(f"  Scan floor level:   {room['floorLevel']:.3f}m")
print(f"  Scan ceiling level: {room['ceilingLevel']:.3f}m")
print(f"  Ceiling height:     {(room['ceilingLevel'] - room['floorLevel'])*1000:.0f}mm")
print(f"  Typical AU std:     2400-2700mm")
print()

print("--- WALLS DETECTED (axis-aligned) ---")
for i, w in enumerate(aligned_walls):
    dx = w["ex"] - w["sx"]
    dz = w["ez"] - w["sz"]
    orientation = "horizontal" if abs(dx) > abs(dz) else "vertical"
    print(f"  Wall {i}: {w['length']*1000:.0f}mm, {orientation}, "
          f"thickness={w['thickness']*1000:.0f}mm, "
          f"({w['sx']:.2f},{w['sz']:.2f})->({w['ex']:.2f},{w['ez']:.2f})")
print()

print("--- OPENINGS DETECTED ---")
for op in aligned_openings:
    print(f"  {op['kind']}: {op['width']*1000:.0f}mm wide x {op['height']*1000:.0f}mm tall "
          f"at ({op['x']:.2f}, {op['z']:.2f})")
print()

print("--- PLANE ANCHOR FEATURES ---")
for pf in aligned_plane_features:
    print(f"  Plane {pf['type']}: {pf['width']*1000:.0f}mm wide "
          f"at ({pf['x']:.2f}, {pf['z']:.2f})")
print()

# Count plane classifications
cls_counts = {}
for p in planes:
    c = p["classification"]
    cls_counts[c] = cls_counts.get(c, 0) + 1
print(f"--- ALL PLANE ANCHORS ({len(planes)} total) ---")
for c, n in sorted(cls_counts.items()):
    print(f"  {c}: {n}")
print()

# Now create a side-by-side visualization
IMG_W, IMG_H = 1400, 800
MARGIN = 60
BG = (20, 20, 25)

img = Image.new("RGBA", (IMG_W, IMG_H), BG)
draw = ImageDraw.Draw(img, "RGBA")

try:
    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 13)
    font_sm = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 11)
    font_title = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 18)
    font_big = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 15)
except:
    font = font_sm = font_title = font_big = ImageFont.load_default()

WALL_COL = (255, 140, 0)
DOOR_COL = (0, 200, 255)
WIN_COL = (100, 255, 100)
DIM_COL = (255, 200, 100)
TEXT_COL = (200, 200, 200)
POLY_FILL = (255, 200, 50, 30)

# --- LEFT PANEL: Scan data (axis-aligned) ---
panel_w = IMG_W // 2 - MARGIN
pad = 0.3
ax_min_x = min_x - pad
ax_max_x = max_x + pad
ax_min_z = min_z - pad
ax_max_z = max_z + pad
ax_range_x = ax_max_x - ax_min_x
ax_range_z = ax_max_z - ax_min_z
ax_scale = min((panel_w - 40) / ax_range_x, (IMG_H - 2*MARGIN - 60) / ax_range_z)

ox_left = MARGIN
oy_top = MARGIN + 50

def to_px_left(x, z):
    px = ox_left + (x - ax_min_x) * ax_scale
    py = oy_top + (ax_max_z - z) * ax_scale
    return int(px), int(py)

# Title
draw.text((MARGIN, 15), "SCAN DATA (axis-aligned)", fill=WALL_COL, font=font_title)
draw.text((MARGIN, 38), f"{room['roomWidth']:.2f}m x {room['roomDepth']:.2f}m | "
          f"Ceiling: {(room['ceilingLevel']-room['floorLevel']):.2f}m | "
          f"{room['area']:.1f}sqm", fill=TEXT_COL, font=font_sm)

# Floor polygon
poly_pts = [to_px_left(x, z) for x, z in aligned_poly]
draw.polygon(poly_pts, fill=POLY_FILL)

# Walls
for w in aligned_walls:
    p1 = to_px_left(w["sx"], w["sz"])
    p2 = to_px_left(w["ex"], w["ez"])
    thick_px = max(4, int(w["thickness"] * ax_scale))
    draw.line([p1, p2], fill=WALL_COL, width=thick_px)
    for pt in [p1, p2]:
        draw.ellipse([pt[0]-3, pt[1]-3, pt[0]+3, pt[1]+3], fill=WALL_COL)
    # Length label
    mx, my = (p1[0]+p2[0])//2, (p1[1]+p2[1])//2
    draw.text((mx+4, my-7), f"{w['length']*1000:.0f}", fill=DIM_COL, font=font_sm)

# Openings
for op in aligned_openings:
    px, py = to_px_left(op["x"], op["z"])
    w_px = int(op["width"] * ax_scale / 2)
    draw.arc([px-w_px, py-w_px, px+w_px, py+w_px], 0, 90, fill=DOOR_COL, width=2)
    draw.text((px+5, py+5), f"Door {op['width']*1000:.0f}mm", fill=DOOR_COL, font=font_sm)

# Plane features
for pf in aligned_plane_features:
    px, py = to_px_left(pf["x"], pf["z"])
    col = DOOR_COL if pf["type"] == "door" else WIN_COL
    r = int(pf["width"] * ax_scale / 2)
    draw.rectangle([px-r, py-3, px+r, py+3], outline=col, width=2)
    draw.text((px-r, py+6), f"{pf['type']} {pf['width']*1000:.0f}mm", fill=col, font=font_sm)

# Scale bar
bar_m = 1.0
bar_px = int(bar_m * ax_scale)
bar_x = MARGIN
bar_y = IMG_H - 25
draw.line([bar_x, bar_y, bar_x+bar_px, bar_y], fill=TEXT_COL, width=2)
draw.line([bar_x, bar_y-4, bar_x, bar_y+4], fill=TEXT_COL, width=1)
draw.line([bar_x+bar_px, bar_y-4, bar_x+bar_px, bar_y+4], fill=TEXT_COL, width=1)
draw.text((bar_x+bar_px//2-15, bar_y-16), "1 metre", fill=TEXT_COL, font=font_sm)

# --- RIGHT PANEL: Expected from plan ---
rx = IMG_W // 2 + 20
draw.text((rx, 15), "REAL PLAN (LIVING room)", fill=(255, 100, 100), font=font_title)
draw.text((rx, 38), "From architectural drawing", fill=TEXT_COL, font=font_sm)

# Draw a schematic of what the plan shows
# The living room is roughly rectangular with:
# - Left wall with 2 windows (AR 1806 AWN)
# - Top wall (shared with service void / robe)
# - Right wall
# - Bottom wall with door (left) and window (right, 1500mm)
# Dimensions from plan marks: left wall segments 340+340mm between features
# Total wall heights ~3400mm each side? Let's estimate from typical proportions

# We know the scan says 3588mm x 4364mm
# Let's draw the expected room at similar scale
plan_w_mm = 3600  # estimated width
plan_d_mm = 4400  # estimated depth (we don't have exact from partial plan)

plan_scale = ax_scale  # use same scale for fair comparison
plan_ox = rx + 20
plan_oy = oy_top + 20

def to_px_right(x_mm, z_mm):
    px = plan_ox + (x_mm / 1000) * plan_scale
    py = plan_oy + ((plan_d_mm - z_mm) / 1000) * plan_scale
    return int(px), int(py)

# Draw expected room outline
PLAN_COL = (255, 100, 100)
corners = [(0,0), (plan_w_mm, 0), (plan_w_mm, plan_d_mm), (0, plan_d_mm)]
for i in range(4):
    p1 = to_px_right(*corners[i])
    p2 = to_px_right(*corners[(i+1)%4])
    draw.line([p1, p2], fill=PLAN_COL, width=5)

# Left wall windows: AR 1806 AWN (1800mm wide? or 1806mm = the code)
# Position them on the left wall
# 340mm from top, then window, gap, window, 340mm from bottom
win_h = 1806  # window height on wall
gap = (plan_d_mm - 340 - win_h - 340 - win_h) # remaining gap
# If room is 4400: 4400 - 340 - 1806 - 1806 - 340 = 108mm gap (tight but possible)
# More likely the 340s are wall-to-window-edge dims
y1_top = 340
y1_bot = 340 + win_h
y2_top = y1_bot + 108  # small gap
y2_bot = y2_top + win_h

for (yt, yb) in [(y1_top, y1_bot), (y2_top, y2_bot)]:
    p1 = to_px_right(0, plan_d_mm - yt)
    p2 = to_px_right(0, plan_d_mm - yb)
    draw.line([p1, p2], fill=WIN_COL, width=4)
    mx = p1[0] - 5
    my = (p1[1] + p2[1]) // 2
    draw.text((mx + 8, my - 6), "AR 1806", fill=WIN_COL, font=font_sm)

# Bottom wall: door on left, window 1500mm on right
# Door - standard 820mm
door_x = 200
p_door = to_px_right(door_x + 410, 0)
draw.arc([p_door[0]-25, p_door[1]-25, p_door[0]+25, p_door[1]+25], 180, 270, fill=DOOR_COL, width=2)
draw.text((p_door[0]-10, p_door[1]+8), "Door", fill=DOOR_COL, font=font_sm)

# Window 1500mm on bottom-right
win_start = plan_w_mm - 1500 - 200
p_w1 = to_px_right(win_start, 0)
p_w2 = to_px_right(win_start + 1500, 0)
draw.line([p_w1, p_w2], fill=WIN_COL, width=4)
draw.text(((p_w1[0]+p_w2[0])//2 - 15, p_w1[1]+8), "1500mm", fill=WIN_COL, font=font_sm)

# Service void at top
sv_x = 0
sv_w = 530
p_sv1 = to_px_right(sv_x, plan_d_mm)
p_sv2 = to_px_right(sv_w, plan_d_mm - 210)
draw.rectangle([min(p_sv1[0],p_sv2[0]), min(p_sv1[1],p_sv2[1]),
                max(p_sv1[0],p_sv2[0]), max(p_sv1[1],p_sv2[1])],
               outline=(150,150,150), width=1)
draw.text((p_sv1[0]+3, p_sv1[1]+3), "SVC VOID", fill=(150,150,150), font=font_sm)

# Dimension labels on plan
# Width
pw1 = to_px_right(0, -200)
pw2 = to_px_right(plan_w_mm, -200)
draw.line([pw1, pw2], fill=DIM_COL, width=1)
draw.text(((pw1[0]+pw2[0])//2-20, pw1[1]+3), f"~{plan_w_mm}mm", fill=DIM_COL, font=font)

# Depth
pd1 = to_px_right(-300, 0)
pd2 = to_px_right(-300, plan_d_mm)
draw.line([pd1, pd2], fill=DIM_COL, width=1)
draw.text((pd1[0]-5, (pd1[1]+pd2[1])//2), f"~{plan_d_mm}mm", fill=DIM_COL, font=font)

# ROBE 5 label above
pr = to_px_right(plan_w_mm//2, plan_d_mm + 300)
draw.text((pr[0]-20, pr[1]), "ROBE 5 (above)", fill=(150,150,150), font=font_sm)

# --- Comparison notes ---
note_y = IMG_H - 180
draw.text((rx, note_y), "COMPARISON NOTES:", fill=(255, 200, 100), font=font_big)
notes = [
    f"Scan width:  {room['roomWidth']*1000:.0f}mm  vs  Plan: ~{plan_w_mm}mm",
    f"Scan depth:  {room['roomDepth']*1000:.0f}mm  vs  Plan: ~{plan_d_mm}mm",
    f"Scan ceiling: {(room['ceilingLevel']-room['floorLevel'])*1000:.0f}mm (typical: 2400-2700)",
    f"Scan walls: 8 detected | Plan shows: ~4 main walls",
    f"Scan door: 1000mm | Plan: door at bottom-left corner",
    f"Plane windows: 2 detected | Plan: 2x AR1806 + 1x 1500mm",
    f"Plane door: 1 detected | Plan: 1 door",
]
for i, n in enumerate(notes):
    draw.text((rx, note_y + 20 + i*16), n, fill=TEXT_COL, font=font_sm)

# Divider line
draw.line([(IMG_W//2, 10), (IMG_W//2, IMG_H-10)], fill=(60,60,70), width=1)

out = Path(__file__).parent / "scan_vs_plan_comparison.png"
img.save(str(out))
print(f"\nSaved: {out}")
