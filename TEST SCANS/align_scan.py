#!/usr/bin/env python3
"""
Auto-align scan mesh data to real floor plan using reference point matching.
Then generate a properly pre-aligned overlay HTML.
"""

import struct
import json
import math
import base64
from pathlib import Path
from PIL import Image

SCAN_DIR = Path("/Users/peterhogan/studiio scanner/TEST SCANS/untitled-2026-05-19t07-32-49z.studiio")
REAL_PLAN = Path("/Users/peterhogan/studiio scanner/TEST SCANS/real house plan.png")
OUTPUT = Path("/Users/peterhogan/studiio scanner/TEST SCANS/overlay-comparison.html")

def read_mesh(filepath):
    with open(filepath, 'rb') as f:
        data = f.read()
    matrix = list(struct.unpack('<16f', data[:64]))
    vert_count = struct.unpack('<I', data[64:68])[0]
    vertices = []
    offset = 68
    for i in range(vert_count):
        if offset + 12 > len(data):
            break
        x, y, z = struct.unpack('<3f', data[offset:offset+12])
        vertices.append((x, y, z))
        offset += 32
    return matrix, vertices

def transform_point(matrix, x, y, z):
    tx = matrix[0]*x + matrix[4]*y + matrix[8]*z + matrix[12]
    ty = matrix[1]*x + matrix[5]*y + matrix[9]*z + matrix[13]
    tz = matrix[2]*x + matrix[6]*y + matrix[10]*z + matrix[14]
    return tx, ty, tz

def extract_all_points(scan_dir):
    index_path = scan_dir / "mesh" / "index.json"
    with open(index_path) as f:
        index = json.load(f)

    all_points = []
    all_y = []
    for anchor in index["anchors"]:
        mesh_file = scan_dir / "mesh" / anchor["file"]
        try:
            matrix, vertices = read_mesh(mesh_file)
        except:
            continue
        for lx, ly, lz in vertices:
            wx, wy, wz = transform_point(matrix, lx, ly, lz)
            all_points.append((wx, wz))
            all_y.append(wy)
    return all_points, all_y

def get_objects(scan_dir):
    with open(scan_dir / "metadata.json") as f:
        meta = json.load(f)
    objects = []
    for floor in meta.get("floors", []):
        for room in floor.get("rooms", []):
            for obj in room.get("objects", []):
                objects.append({
                    "category": obj["category"],
                    "x": obj["positionX"],
                    "z": obj["positionZ"],
                    "dx": obj.get("dimensionsX", 0),
                    "dz": obj.get("dimensionsZ", 0),
                })
    return objects

def compute_alignment():
    """
    Compute the transform from scan coordinates to plan pixel coordinates.

    Plan image: 2040 x 1650 pixels
    Plan dimensions: 15540mm overall width

    From reading the architectural dimension annotations:
    - The 15540mm overall spans from pixel x≈345 to x≈1970 (1625 pixels)
    - PPM = 1625 / 15.54 = 104.57 px/m
    - Plan left edge (0mm) is at pixel x=345

    Building walls (from plan left edge in mm):
    Upper floor room positions:
    - Building left wall: 450mm
    - BED 5: 450+230=680 to 680+3220=3900mm
    - RUMPUS: 3900+70=3970 to 3970+4780=8750mm
    - ENSUITE 2: 8750+70=8820 to 8820+?
    - BED 6: after ENSUITE 2

    Vertical:
    - Top external wall at approximately pixel y=308
    - Building depth uses same PPM

    KEY REFERENCE POINTS (read carefully from the plan):

    1. Ensuite 2 - Wall Hung Vanity (500x750mm)
       - Located at top-right area of ENSUITE 2 room
       - Plan position: approximately x=9200mm from plan left, y=500mm from top wall
       - The vanity is against the top wall, offset from left wall of ensuite

    2. PWD toilet
       - Located in the powder room, center of building width
       - Plan position: approximately x=5500mm from plan left, y=4000mm from top wall

    3. Rumpus center
       - Center of the main rumpus room
       - Plan position: x=6360mm from plan left, y=2500mm from top wall
    """

    # Image and plan constants
    img_w, img_h = 2040, 1650
    plan_left_px = 345  # where 0mm starts on the plan image
    plan_top_px = 308   # where the top external wall is
    ppm = 104.57        # pixels per meter

    # Plan coordinates of known features (mm from plan left edge, mm from top wall)
    # These are read from the architectural drawings dimension annotations

    # The plan shows this house has:
    # - Ensuite 2 with shower and vanity in the upper-right zone
    # - PWD (powder room) in the center, below RUMPUS level
    # - RUMPUS spanning the center-top

    # From the dimension annotations:
    # RUMPUS: 3970mm to 8750mm from plan left (center at 6360mm)
    # ENSUITE 2 starts at 8820mm, shower is near the top

    # The scan has these key objects:
    # Bathtub at scan (1.94, 0.54) - this is the shower in Ensuite 2
    # Vanity at scan (-1.98, -1.94) - this is the PWD vanity (standalone, away from others)
    # Vanities at scan (~2.1, -4.77) - these are in a bedroom/ensuite area

    # Let me match:
    # Scan bathtub (1.94, 0.54) -> Ensuite 2 shower
    #   Plan: x ≈ 9800mm, y ≈ 600mm (near top wall)
    #   The shower is labeled at the top of Ensuite 2

    # Scan vanity (-1.98, -1.94) -> PWD vanity/basin
    #   Plan: x ≈ 5400mm, y ≈ 3800mm (in the entry/PWD zone below rumpus)

    # Reference points in plan-meters from plan origin:
    plan_ref_1 = (9.80, 0.60)   # Ensuite 2 shower position
    plan_ref_2 = (5.40, 3.80)   # PWD vanity position

    # Corresponding scan coordinates:
    scan_ref_1 = (1.94, 0.54)   # Bathtub (= ensuite shower)
    scan_ref_2 = (-1.98, -1.94) # PWD vanity

    return plan_left_px, plan_top_px, ppm, plan_ref_1, plan_ref_2, scan_ref_1, scan_ref_2

def solve_rigid_transform(scan_pts, plan_pts):
    """
    Solve for rotation and translation: plan = R * scan + T
    Using 2 point pairs.
    """
    s1, s2 = scan_pts
    p1, p2 = plan_pts

    # Vectors
    ds = (s2[0]-s1[0], s2[1]-s1[1])
    dp = (p2[0]-p1[0], p2[1]-p1[1])

    # Distances
    dist_s = math.sqrt(ds[0]**2 + ds[1]**2)
    dist_p = math.sqrt(dp[0]**2 + dp[1]**2)

    # Scale factor
    scale = dist_p / dist_s

    # Angles
    angle_s = math.atan2(ds[1], ds[0])
    angle_p = math.atan2(dp[1], dp[0])

    # Rotation
    rotation = angle_p - angle_s

    # Translation: apply rotation and scale to scan_ref_1, then find offset to plan_ref_1
    cos_r = math.cos(rotation)
    sin_r = math.sin(rotation)

    # Transform scan point 1
    tx1 = (s1[0] * cos_r - s1[1] * sin_r) * scale
    ty1 = (s1[0] * sin_r + s1[1] * cos_r) * scale

    # Translation to match plan point 1
    offset_x = p1[0] - tx1
    offset_y = p1[1] - ty1

    # Verify with point 2
    tx2 = (s2[0] * cos_r - s2[1] * sin_r) * scale + offset_x
    ty2 = (s2[0] * sin_r + s2[1] * cos_r) * scale + offset_y

    err = math.sqrt((tx2-p2[0])**2 + (ty2-p2[1])**2)

    print(f"  Scale: {scale:.4f}")
    print(f"  Rotation: {math.degrees(rotation):.1f} degrees")
    print(f"  Translation: ({offset_x:.3f}, {offset_y:.3f})")
    print(f"  Verification error: {err:.4f}m")

    return scale, rotation, offset_x, offset_y

def scan_to_plan_meters(sx, sz, scale, rotation, tx, ty):
    cos_r = math.cos(rotation)
    sin_r = math.sin(rotation)
    px = (sx * cos_r - sz * sin_r) * scale + tx
    py = (sx * sin_r + sz * cos_r) * scale + ty
    return px, py

def plan_meters_to_pixels(pm_x, pm_y, plan_left_px, plan_top_px, ppm):
    px = plan_left_px + pm_x * ppm
    py = plan_top_px + pm_y * ppm
    return px, py

def main():
    print("=== Extracting scan data ===")
    all_points, all_y = extract_all_points(SCAN_DIR)
    objects = get_objects(SCAN_DIR)
    print(f"  {len(all_points)} vertices, {len(objects)} objects")

    # Filter wall-height points
    wall_pts = [(x, z) for (x, z), y in zip(all_points, all_y) if -0.8 <= y <= 0.5]
    floor_pts = [(x, z) for (x, z), y in zip(all_points, all_y) if -1.8 <= y <= -1.2]
    print(f"  Wall points: {len(wall_pts)}, Floor points: {len(floor_pts)}")

    print("\n=== Computing alignment ===")
    plan_left_px, plan_top_px, ppm, plan_ref_1, plan_ref_2, scan_ref_1, scan_ref_2 = compute_alignment()

    scale, rotation, tx, ty = solve_rigid_transform(
        [scan_ref_1, scan_ref_2],
        [plan_ref_1, plan_ref_2]
    )

    # Transform all scan points to plan pixel coordinates
    print("\n=== Transforming points ===")

    # Subsample for performance
    max_pts = 40000
    wall_step = max(1, len(wall_pts) // max_pts)
    floor_step = max(1, len(floor_pts) // max_pts)

    wall_pixels = []
    for sx, sz in wall_pts[::wall_step]:
        pm_x, pm_y = scan_to_plan_meters(sx, sz, scale, rotation, tx, ty)
        px, py = plan_meters_to_pixels(pm_x, pm_y, plan_left_px, plan_top_px, ppm)
        wall_pixels.append((round(px, 1), round(py, 1)))

    floor_pixels = []
    for sx, sz in floor_pts[::floor_step]:
        pm_x, pm_y = scan_to_plan_meters(sx, sz, scale, rotation, tx, ty)
        px, py = plan_meters_to_pixels(pm_x, pm_y, plan_left_px, plan_top_px, ppm)
        floor_pixels.append((round(px, 1), round(py, 1)))

    obj_pixels = []
    for obj in objects:
        pm_x, pm_y = scan_to_plan_meters(obj['x'], obj['z'], scale, rotation, tx, ty)
        px, py = plan_meters_to_pixels(pm_x, pm_y, plan_left_px, plan_top_px, ppm)
        # Dimensions need to be scaled too
        dim_px = obj['dx'] * scale * ppm
        dim_pz = obj['dz'] * scale * ppm
        obj_pixels.append({
            'category': obj['category'],
            'px': round(px, 1), 'py': round(py, 1),
            'w': round(dim_px, 1), 'h': round(dim_pz, 1)
        })

    # Also transform reference points for verification markers
    ref1_px = plan_meters_to_pixels(plan_ref_1[0], plan_ref_1[1], plan_left_px, plan_top_px, ppm)
    ref2_px = plan_meters_to_pixels(plan_ref_2[0], plan_ref_2[1], plan_left_px, plan_top_px, ppm)

    print(f"  Wall pixels: {len(wall_pixels)}")
    print(f"  Floor pixels: {len(floor_pixels)}")
    print(f"  Ref 1 (Ensuite shower): ({ref1_px[0]:.0f}, {ref1_px[1]:.0f})")
    print(f"  Ref 2 (PWD vanity): ({ref2_px[0]:.0f}, {ref2_px[1]:.0f})")

    # Verify some object positions
    print("\n=== Object positions on plan ===")
    for op in obj_pixels:
        print(f"  {op['category']:12s} at pixel ({op['px']:.0f}, {op['py']:.0f})")

    print("\n=== Generating overlay HTML ===")
    generate_html(wall_pixels, floor_pixels, obj_pixels, ref1_px, ref2_px,
                  scale, rotation, tx, ty, plan_left_px, plan_top_px, ppm)
    print(f"  Saved: {OUTPUT}")

def generate_html(wall_pixels, floor_pixels, obj_pixels, ref1_px, ref2_px,
                  scale, rotation, tx, ty, plan_left_px, plan_top_px, ppm):

    with open(REAL_PLAN, 'rb') as f:
        plan_b64 = base64.b64encode(f.read()).decode()

    wall_json = json.dumps(wall_pixels)
    floor_json = json.dumps(floor_pixels)
    obj_json = json.dumps(obj_pixels)

    html = f"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Studiio Scanner - Scan vs Real Floor Plan Overlay</title>
<style>
* {{ margin: 0; padding: 0; box-sizing: border-box; }}
body {{
    background: #1a1a1a;
    color: #e0e0e0;
    font-family: -apple-system, BlinkMacSystemFont, 'SF Pro', sans-serif;
    overflow: hidden;
    height: 100vh;
}}
#toolbar {{
    position: fixed; top: 0; left: 0; right: 0; z-index: 100;
    background: rgba(20,20,20,0.95);
    backdrop-filter: blur(10px);
    padding: 10px 20px;
    display: flex; align-items: center; gap: 14px; flex-wrap: wrap;
    border-bottom: 1px solid #333;
}}
#toolbar h1 {{ font-size: 15px; font-weight: 600; color: #ff8c00; white-space: nowrap; }}
.ctrl {{ display: flex; align-items: center; gap: 5px; font-size: 11px; }}
.ctrl label {{ color: #999; white-space: nowrap; }}
.ctrl input[type=range] {{ width: 90px; accent-color: #ff8c00; }}
.ctrl input[type=number] {{ width: 55px; background: #2a2a2a; border: 1px solid #444; color: #fff; padding: 2px 4px; border-radius: 3px; font-size: 11px; }}
.ctrl button {{
    background: #333; border: 1px solid #555; color: #ddd; padding: 3px 8px;
    border-radius: 4px; cursor: pointer; font-size: 11px; white-space: nowrap;
}}
.ctrl button:hover {{ background: #444; }}
.ctrl button.active {{ background: #ff8c00; color: #000; border-color: #ff8c00; }}
.sep {{ width: 1px; height: 20px; background: #444; }}
#info {{
    position: fixed; bottom: 10px; left: 10px; z-index: 100;
    background: rgba(20,20,20,0.92); padding: 10px 14px; border-radius: 6px;
    font-size: 11px; color: #999; border: 1px solid #333; max-width: 380px;
}}
#info h3 {{ color: #ff8c00; margin-bottom: 4px; font-size: 13px; }}
#info .val {{ color: #ccc; }}
#canvas-wrap {{
    position: absolute; top: 44px; left: 0; right: 0; bottom: 0;
    overflow: hidden; cursor: grab;
}}
#canvas-wrap.dragging {{ cursor: grabbing; }}
#plan-container {{
    position: absolute;
    transform-origin: 0 0;
}}
#real-plan {{ display: block; }}
#scan-canvas {{
    position: absolute; top: 0; left: 0;
    pointer-events: none;
}}
</style>
</head>
<body>

<div id="toolbar">
    <h1>STUDIIO OVERLAY</h1>
    <div class="sep"></div>
    <div class="ctrl">
        <label>Scan</label>
        <input type="range" id="scanOpacity" min="0" max="100" value="75">
    </div>
    <div class="ctrl">
        <label>Plan</label>
        <input type="range" id="planOpacity" min="0" max="100" value="100">
    </div>
    <div class="sep"></div>
    <div class="ctrl">
        <label>Fine X</label>
        <input type="number" id="fineX" value="0" step="1">
    </div>
    <div class="ctrl">
        <label>Fine Y</label>
        <input type="number" id="fineY" value="0" step="1">
    </div>
    <div class="ctrl">
        <label>Fine Rot</label>
        <input type="number" id="fineRot" value="0" step="0.5">
    </div>
    <div class="ctrl">
        <label>Fine Scale</label>
        <input type="number" id="fineScale" value="1.00" step="0.01" min="0.5" max="1.5">
    </div>
    <div class="sep"></div>
    <div class="ctrl">
        <button id="btnWalls" class="active" onclick="toggle('walls')">Walls</button>
        <button id="btnFloor" class="active" onclick="toggle('floor')">Floor</button>
        <button id="btnObj" class="active" onclick="toggle('obj')">Objects</button>
        <button id="btnRef" class="active" onclick="toggle('ref')">Ref Pts</button>
    </div>
    <div class="sep"></div>
    <div class="ctrl">
        <button onclick="fitView()">Fit</button>
    </div>
</div>

<div id="canvas-wrap">
    <div id="plan-container">
        <img id="real-plan" src="data:image/png;base64,{plan_b64}">
        <canvas id="scan-canvas"></canvas>
    </div>
</div>

<div id="info">
    <h3>Scan Alignment</h3>
    <div>Transform: <span class="val">scale={scale:.3f}, rot={math.degrees(rotation):.1f}°</span></div>
    <div>PPM: <span class="val">{ppm:.1f} px/m</span></div>
    <div>Plan origin: <span class="val">({plan_left_px}, {plan_top_px}) px</span></div>
    <div style="margin-top:4px;">Arrow keys = nudge, [ ] = rotate, - = = scale</div>
    <div>Mouse: scroll=zoom, drag=pan</div>
</div>

<script>
const wallPx = {wall_json};
const floorPx = {floor_json};
const objPx = {obj_json};
const ref1 = [{ref1_px[0]:.1f}, {ref1_px[1]:.1f}];
const ref2 = [{ref2_px[0]:.1f}, {ref2_px[1]:.1f}];

let layers = {{ walls: true, floor: true, obj: true, ref: true }};
let viewX = 0, viewY = 0, viewZoom = 0.5;

const img = document.getElementById('real-plan');
const canvas = document.getElementById('scan-canvas');
const ctx = canvas.getContext('2d');
const container = document.getElementById('plan-container');
const wrap = document.getElementById('canvas-wrap');

img.onload = () => {{
    canvas.width = img.naturalWidth;
    canvas.height = img.naturalHeight;
    canvas.style.width = img.naturalWidth + 'px';
    canvas.style.height = img.naturalHeight + 'px';
    fitView();
    redraw();
}};

function getFine() {{
    return {{
        dx: parseFloat(document.getElementById('fineX').value) || 0,
        dy: parseFloat(document.getElementById('fineY').value) || 0,
        rot: (parseFloat(document.getElementById('fineRot').value) || 0) * Math.PI / 180,
        scale: parseFloat(document.getElementById('fineScale').value) || 1.0,
    }};
}}

function applyFine(px, py) {{
    const f = getFine();
    // Fine adjust: rotate around center of scan, scale, then translate
    // Approximate center of scan on plan
    const cx = (ref1[0] + ref2[0]) / 2;
    const cy = (ref1[1] + ref2[1]) / 2;
    let dx = px - cx;
    let dy = py - cy;
    // Scale
    dx *= f.scale;
    dy *= f.scale;
    // Rotate
    const cos = Math.cos(f.rot);
    const sin = Math.sin(f.rot);
    const rx = dx * cos - dy * sin;
    const ry = dx * sin + dy * cos;
    return [cx + rx + f.dx, cy + ry + f.dy];
}}

function redraw() {{
    const scanAlpha = document.getElementById('scanOpacity').value / 100;
    const planAlpha = document.getElementById('planOpacity').value / 100;

    img.style.opacity = planAlpha;
    ctx.clearRect(0, 0, canvas.width, canvas.height);

    // Draw floor points
    if (layers.floor) {{
        ctx.globalAlpha = scanAlpha * 0.3;
        ctx.fillStyle = '#ff8c00';
        for (const [px, py] of floorPx) {{
            const [ax, ay] = applyFine(px, py);
            ctx.fillRect(ax - 1, ay - 1, 2, 2);
        }}
    }}

    // Draw wall points
    if (layers.walls) {{
        ctx.globalAlpha = scanAlpha * 0.7;
        ctx.fillStyle = '#ff8c00';
        for (const [px, py] of wallPx) {{
            const [ax, ay] = applyFine(px, py);
            ctx.fillRect(ax - 1.5, ay - 1.5, 3, 3);
        }}
    }}

    // Draw objects
    if (layers.obj) {{
        ctx.globalAlpha = scanAlpha;
        for (const obj of objPx) {{
            const [ax, ay] = applyFine(obj.px, obj.py);
            let color = '#ff8c00';
            if (obj.category === 'toilet') color = '#00bfff';
            else if (obj.category === 'vanity') color = '#ff69b4';
            else if (obj.category === 'bathtub') color = '#00ff88';
            else if (obj.category === 'table') color = '#ffff00';

            ctx.strokeStyle = color;
            ctx.lineWidth = 2;
            ctx.strokeRect(ax - obj.w/2, ay - obj.h/2, obj.w, obj.h);
            ctx.fillStyle = color;
            ctx.font = 'bold 11px -apple-system, sans-serif';
            ctx.fillText(obj.category.toUpperCase(), ax - obj.w/2, ay - obj.h/2 - 4);
        }}
    }}

    // Draw reference points
    if (layers.ref) {{
        ctx.globalAlpha = 1;
        for (const [rx, ry, label] of [[ref1[0], ref1[1], 'REF1: Ensuite Shower'], [ref2[0], ref2[1], 'REF2: PWD Vanity']]) {{
            const [ax, ay] = applyFine(rx, ry);
            ctx.beginPath();
            ctx.arc(ax, ay, 8, 0, Math.PI * 2);
            ctx.strokeStyle = '#ff0000';
            ctx.lineWidth = 3;
            ctx.stroke();
            ctx.beginPath();
            ctx.moveTo(ax - 12, ay); ctx.lineTo(ax + 12, ay);
            ctx.moveTo(ax, ay - 12); ctx.lineTo(ax, ay + 12);
            ctx.stroke();
            ctx.fillStyle = '#ff0000';
            ctx.font = 'bold 11px -apple-system, sans-serif';
            ctx.fillText(label, ax + 14, ay + 4);
        }}
    }}

    ctx.globalAlpha = 1;
    container.style.transform = `translate(${{viewX}}px, ${{viewY}}px) scale(${{viewZoom}})`;
}}

function toggle(name) {{
    layers[name] = !layers[name];
    const btn = document.getElementById('btn' + name.charAt(0).toUpperCase() + name.slice(1));
    btn.classList.toggle('active');
    redraw();
}}

function fitView() {{
    const ww = wrap.clientWidth;
    const wh = wrap.clientHeight;
    viewZoom = Math.min(ww / img.naturalWidth, wh / img.naturalHeight) * 0.92;
    viewX = (ww - img.naturalWidth * viewZoom) / 2;
    viewY = (wh - img.naturalHeight * viewZoom) / 2;
    redraw();
}}

// Pan & zoom
let dragging = false, dsx, dsy;
wrap.addEventListener('mousedown', e => {{ dragging = true; dsx = e.clientX - viewX; dsy = e.clientY - viewY; wrap.classList.add('dragging'); }});
window.addEventListener('mousemove', e => {{ if (dragging) {{ viewX = e.clientX - dsx; viewY = e.clientY - dsy; container.style.transform = `translate(${{viewX}}px, ${{viewY}}px) scale(${{viewZoom}})`; }} }});
window.addEventListener('mouseup', () => {{ dragging = false; wrap.classList.remove('dragging'); }});
wrap.addEventListener('wheel', e => {{
    e.preventDefault();
    const r = wrap.getBoundingClientRect();
    const mx = e.clientX - r.left, my = e.clientY - r.top;
    const oz = viewZoom;
    viewZoom *= e.deltaY > 0 ? 0.9 : 1.1;
    viewZoom = Math.max(0.05, Math.min(10, viewZoom));
    viewX = mx - (mx - viewX) * viewZoom / oz;
    viewY = my - (my - viewY) * viewZoom / oz;
    container.style.transform = `translate(${{viewX}}px, ${{viewY}}px) scale(${{viewZoom}})`;
}});

// Fine controls
['scanOpacity','planOpacity','fineX','fineY','fineRot','fineScale'].forEach(id => {{
    document.getElementById(id).addEventListener('input', redraw);
}});

// Keyboard
window.addEventListener('keydown', e => {{
    const s = e.shiftKey ? 5 : 1;
    const el = id => document.getElementById(id);
    if (e.key === 'ArrowLeft')  {{ el('fineX').value = parseFloat(el('fineX').value) - s; redraw(); }}
    if (e.key === 'ArrowRight') {{ el('fineX').value = parseFloat(el('fineX').value) + s; redraw(); }}
    if (e.key === 'ArrowUp')    {{ el('fineY').value = parseFloat(el('fineY').value) - s; redraw(); }}
    if (e.key === 'ArrowDown')  {{ el('fineY').value = parseFloat(el('fineY').value) + s; redraw(); }}
    if (e.key === '[') {{ el('fineRot').value = (parseFloat(el('fineRot').value) - 0.5).toFixed(1); redraw(); }}
    if (e.key === ']') {{ el('fineRot').value = (parseFloat(el('fineRot').value) + 0.5).toFixed(1); redraw(); }}
    if (e.key === '-') {{ el('fineScale').value = (parseFloat(el('fineScale').value) - 0.01).toFixed(2); redraw(); }}
    if (e.key === '=') {{ el('fineScale').value = (parseFloat(el('fineScale').value) + 0.01).toFixed(2); redraw(); }}
}});
</script>
</body>
</html>"""

    with open(OUTPUT, 'w') as f:
        f.write(html)

if __name__ == "__main__":
    main()
