#!/usr/bin/env python3
"""
Extract wall outlines from .studiio mesh data and overlay on real floor plan.
Produces an HTML file with the real plan as background and scan data overlaid.
"""

import struct
import json
import os
import math
import base64
from pathlib import Path

SCAN_DIR = Path("/Users/peterhogan/studiio scanner/TEST SCANS/untitled-2026-05-19t07-32-49z.studiio")
REAL_PLAN = Path("/Users/peterhogan/studiio scanner/TEST SCANS/real house plan.png")
OUTPUT = Path("/Users/peterhogan/studiio scanner/TEST SCANS/overlay-comparison.html")

def read_mesh(filepath, vert_count):
    """Read mesh binary: 64-byte transform matrix + 4-byte vert count + vertices (32-byte stride)"""
    with open(filepath, 'rb') as f:
        data = f.read()

    # 4x4 transform matrix
    matrix = list(struct.unpack('<16f', data[:64]))

    # Vertex count at offset 64
    stored_vert_count = struct.unpack('<I', data[64:68])[0]

    # Read vertex positions (stride 32, first 12 bytes = XYZ float32)
    vertices = []
    offset = 68
    for i in range(stored_vert_count):
        if offset + 12 > len(data):
            break
        x, y, z = struct.unpack('<3f', data[offset:offset+12])
        vertices.append((x, y, z))
        offset += 32

    return matrix, vertices

def transform_point(matrix, x, y, z):
    """Apply 4x4 transform matrix to point"""
    # Matrix is column-major (OpenGL style)
    tx = matrix[0]*x + matrix[4]*y + matrix[8]*z + matrix[12]
    ty = matrix[1]*x + matrix[5]*y + matrix[9]*z + matrix[13]
    tz = matrix[2]*x + matrix[6]*y + matrix[10]*z + matrix[14]
    return tx, ty, tz

def extract_floor_outline(scan_dir):
    """Extract all mesh vertices, transform to world space, project to XZ floor plan"""
    index_path = scan_dir / "mesh" / "index.json"
    with open(index_path) as f:
        index = json.load(f)

    all_points = []  # (world_x, world_z) pairs
    all_y_values = []

    for anchor in index["anchors"]:
        mesh_file = scan_dir / "mesh" / anchor["file"]
        vert_count = anchor["vertices"]

        try:
            matrix, vertices = read_mesh(mesh_file, vert_count)
        except Exception as e:
            print(f"  Skipping {anchor['file']}: {e}")
            continue

        for lx, ly, lz in vertices:
            wx, wy, wz = transform_point(matrix, lx, ly, lz)
            all_points.append((wx, wz))  # XZ plane = floor plan
            all_y_values.append(wy)

    print(f"Total vertices extracted: {len(all_points)}")

    # Find floor level (most common Y, should be ~lowest)
    if all_y_values:
        y_min = min(all_y_values)
        y_max = max(all_y_values)
        print(f"Y range: {y_min:.2f} to {y_max:.2f} (height: {y_max-y_min:.2f}m)")

    return all_points, all_y_values

def points_to_density_grid(points, resolution=0.02):
    """Convert points to a density grid for wall detection"""
    if not points:
        return [], 0, 0, 0, 0

    xs = [p[0] for p in points]
    zs = [p[1] for p in points]

    x_min, x_max = min(xs), max(xs)
    z_min, z_max = min(zs), max(zs)

    # Add small margin
    margin = 0.2
    x_min -= margin
    z_min -= margin
    x_max += margin
    z_max += margin

    cols = int((x_max - x_min) / resolution) + 1
    rows = int((z_max - z_min) / resolution) + 1

    grid = [[0] * cols for _ in range(rows)]

    for x, z in points:
        col = int((x - x_min) / resolution)
        row = int((z - z_min) / resolution)
        if 0 <= row < rows and 0 <= col < cols:
            grid[row][col] += 1

    return grid, x_min, z_min, x_max, z_max

def extract_wall_points(points, y_values, y_band_min=-0.5, y_band_max=0.5):
    """Extract points at wall height (mid-height band) for cleaner outlines"""
    wall_pts = []
    for (x, z), y in zip(points, y_values):
        if y_band_min <= y <= y_band_max:
            wall_pts.append((x, z))
    return wall_pts

def get_metadata_objects(scan_dir):
    """Get detected objects from metadata for labeling"""
    meta_path = scan_dir / "metadata.json"
    with open(meta_path) as f:
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

def create_overlay_html(points, y_values, objects, real_plan_path, output_path):
    """Create interactive HTML overlay with real plan as background"""

    # Get floor-level points for outline
    floor_points = extract_wall_points(points, y_values, -1.8, -1.2)  # floor level
    wall_points = extract_wall_points(points, y_values, -0.8, 0.5)    # wall level
    all_xz = points

    # Compute bounds
    xs = [p[0] for p in all_xz]
    zs = [p[1] for p in all_xz]
    x_min, x_max = min(xs), max(xs)
    z_min, z_max = min(zs), max(zs)

    scan_width = x_max - x_min
    scan_height = z_max - z_min

    print(f"Scan bounds: X=[{x_min:.2f}, {x_max:.2f}] ({scan_width:.2f}m)")
    print(f"             Z=[{z_min:.2f}, {z_max:.2f}] ({scan_height:.2f}m)")

    # Subsample points for SVG (take every Nth point to keep file manageable)
    max_svg_points = 50000
    step = max(1, len(wall_points) // max_svg_points)
    svg_wall_points = wall_points[::step]
    step2 = max(1, len(floor_points) // max_svg_points)
    svg_floor_points = floor_points[::step2]

    print(f"Wall points for SVG: {len(svg_wall_points)}")
    print(f"Floor points for SVG: {len(svg_floor_points)}")

    # Read and base64 encode the real plan
    with open(real_plan_path, 'rb') as f:
        plan_b64 = base64.b64encode(f.read()).decode()

    # Build SVG scan overlay data as JSON
    wall_json = json.dumps([(round(x, 3), round(z, 3)) for x, z in svg_wall_points])
    floor_json = json.dumps([(round(x, 3), round(z, 3)) for x, z in svg_floor_points])
    objects_json = json.dumps(objects)

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
    padding: 12px 20px;
    display: flex; align-items: center; gap: 16px;
    border-bottom: 1px solid #333;
}}
#toolbar h1 {{ font-size: 16px; font-weight: 600; color: #ff8c00; white-space: nowrap; }}
.ctrl {{ display: flex; align-items: center; gap: 6px; font-size: 12px; }}
.ctrl label {{ color: #999; white-space: nowrap; }}
.ctrl input[type=range] {{ width: 100px; accent-color: #ff8c00; }}
.ctrl input[type=number] {{ width: 60px; background: #2a2a2a; border: 1px solid #444; color: #fff; padding: 2px 4px; border-radius: 3px; }}
.ctrl button {{
    background: #333; border: 1px solid #555; color: #ddd; padding: 4px 10px;
    border-radius: 4px; cursor: pointer; font-size: 11px; white-space: nowrap;
}}
.ctrl button:hover {{ background: #444; }}
.ctrl button.active {{ background: #ff8c00; color: #000; border-color: #ff8c00; }}
.sep {{ width: 1px; height: 24px; background: #444; }}
#info {{
    position: fixed; bottom: 10px; left: 10px; z-index: 100;
    background: rgba(20,20,20,0.9); padding: 10px 14px; border-radius: 6px;
    font-size: 11px; color: #999; border: 1px solid #333;
    max-width: 350px;
}}
#info h3 {{ color: #ff8c00; margin-bottom: 4px; font-size: 13px; }}
#info .metric {{ color: #ccc; }}
#canvas-wrap {{
    position: absolute; top: 50px; left: 0; right: 0; bottom: 0;
    overflow: hidden; cursor: grab;
}}
#canvas-wrap.dragging {{ cursor: grabbing; }}
#plan-container {{
    position: absolute;
    transform-origin: 0 0;
}}
#real-plan {{
    display: block;
    image-rendering: -webkit-optimize-contrast;
}}
#scan-overlay {{
    position: absolute;
    top: 0; left: 0;
    pointer-events: none;
}}
</style>
</head>
<body>

<div id="toolbar">
    <h1>STUDIIO OVERLAY</h1>
    <div class="sep"></div>

    <div class="ctrl">
        <label>Scan Opacity</label>
        <input type="range" id="scanOpacity" min="0" max="100" value="70">
    </div>
    <div class="ctrl">
        <label>Plan Opacity</label>
        <input type="range" id="planOpacity" min="0" max="100" value="100">
    </div>
    <div class="sep"></div>

    <div class="ctrl">
        <label>Scale</label>
        <input type="number" id="scaleInput" value="1.00" step="0.01" min="0.5" max="2.0">
    </div>
    <div class="ctrl">
        <label>Rotate</label>
        <input type="number" id="rotateInput" value="0" step="0.5" min="-180" max="180">
        <label>deg</label>
    </div>
    <div class="ctrl">
        <label>Offset X</label>
        <input type="number" id="offsetX" value="0" step="1">
        <label>px</label>
    </div>
    <div class="ctrl">
        <label>Offset Y</label>
        <input type="number" id="offsetY" value="0" step="1">
        <label>px</label>
    </div>
    <div class="sep"></div>

    <div class="ctrl">
        <button id="btnWalls" class="active" onclick="toggleLayer('walls')">Walls</button>
        <button id="btnFloor" class="active" onclick="toggleLayer('floor')">Floor</button>
        <button id="btnObjects" class="active" onclick="toggleLayer('objects')">Objects</button>
        <button id="btnLabels" class="active" onclick="toggleLayer('labels')">Labels</button>
    </div>
    <div class="sep"></div>
    <div class="ctrl">
        <button onclick="resetView()">Reset View</button>
        <button onclick="fitView()">Fit</button>
    </div>
</div>

<div id="canvas-wrap">
    <div id="plan-container">
        <img id="real-plan" src="data:image/png;base64,{plan_b64}">
        <canvas id="scan-overlay"></canvas>
    </div>
</div>

<div id="info">
    <h3>Scan Analysis</h3>
    <div>Scan area: <span class="metric">{scan_width:.1f}m x {scan_height:.1f}m</span></div>
    <div>Total mesh points: <span class="metric">{len(points):,}</span></div>
    <div>Wall points: <span class="metric">{len(wall_points):,}</span></div>
    <div>Objects detected: <span class="metric">{len(objects)}</span></div>
    <div style="margin-top:6px; color:#ff8c00;">Drag scan controls to align with plan.</div>
    <div style="color:#777; margin-top:4px;">Mouse: scroll=zoom, drag=pan</div>
</div>

<script>
const wallPoints = {wall_json};
const floorPoints = {floor_json};
const objects = {objects_json};

const scanBounds = {{
    xMin: {x_min:.4f}, xMax: {x_max:.4f},
    zMin: {z_min:.4f}, zMax: {z_max:.4f},
    width: {scan_width:.4f}, height: {scan_height:.4f}
}};

// State
let layers = {{ walls: true, floor: true, objects: true, labels: true }};
let viewX = 0, viewY = 0, viewZoom = 0.5;

const img = document.getElementById('real-plan');
const canvas = document.getElementById('scan-overlay');
const ctx = canvas.getContext('2d');
const container = document.getElementById('plan-container');
const wrap = document.getElementById('canvas-wrap');

// Wait for image to load
img.onload = () => {{
    canvas.width = img.naturalWidth;
    canvas.height = img.naturalHeight;
    canvas.style.width = img.naturalWidth + 'px';
    canvas.style.height = img.naturalHeight + 'px';
    fitView();
    redraw();
}};

function getParams() {{
    return {{
        scanOpacity: document.getElementById('scanOpacity').value / 100,
        planOpacity: document.getElementById('planOpacity').value / 100,
        scale: parseFloat(document.getElementById('scaleInput').value),
        rotate: parseFloat(document.getElementById('rotateInput').value) * Math.PI / 180,
        offsetX: parseFloat(document.getElementById('offsetX').value),
        offsetY: parseFloat(document.getElementById('offsetY').value),
    }};
}}

function scanToCanvas(sx, sz, params) {{
    // Convert scan coords (meters) to canvas pixels
    // The real plan image: we need to establish a pixels-per-meter ratio
    // From the plan: overall width is 15540mm = 15.54m
    // Image width is img.naturalWidth pixels
    const planWidthM = 15.54;  // from dimension line on plan
    const ppm = img.naturalWidth / planWidthM;  // pixels per meter

    // Normalize scan point relative to scan center
    const cx = (scanBounds.xMin + scanBounds.xMax) / 2;
    const cz = (scanBounds.zMin + scanBounds.zMax) / 2;
    let dx = (sx - cx) * params.scale;
    let dz = (sz - cz) * params.scale;

    // Rotate
    const cos = Math.cos(params.rotate);
    const sin = Math.sin(params.rotate);
    const rx = dx * cos - dz * sin;
    const rz = dx * sin + dz * cos;

    // Convert to pixels and apply offset
    const px = rx * ppm + params.offsetX;
    const py = rz * ppm + params.offsetY;

    return [px, py];
}}

function redraw() {{
    const p = getParams();

    // Plan opacity
    img.style.opacity = p.planOpacity;

    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.globalAlpha = p.scanOpacity;

    // Save and translate to center of canvas for drawing
    ctx.save();
    ctx.translate(canvas.width / 2, canvas.height / 2);

    // Draw floor points
    if (layers.floor && floorPoints.length > 0) {{
        ctx.fillStyle = 'rgba(255, 140, 0, 0.15)';
        for (const [sx, sz] of floorPoints) {{
            const [px, py] = scanToCanvas(sx, sz, p);
            ctx.fillRect(px - 1, py - 1, 2, 2);
        }}
    }}

    // Draw wall points
    if (layers.walls && wallPoints.length > 0) {{
        ctx.fillStyle = 'rgba(255, 140, 0, 0.6)';
        for (const [sx, sz] of wallPoints) {{
            const [px, py] = scanToCanvas(sx, sz, p);
            ctx.fillRect(px - 1.5, py - 1.5, 3, 3);
        }}
    }}

    // Draw objects
    if (layers.objects) {{
        for (const obj of objects) {{
            const [px, py] = scanToCanvas(obj.x, obj.z, p);
            const planWidthM = 15.54;
            const ppm = img.naturalWidth / planWidthM;
            const w = obj.dx * p.scale * ppm;
            const h = obj.dz * p.scale * ppm;

            // Color by category
            let color = '#ff8c00';
            if (obj.category === 'toilet') color = '#00bfff';
            else if (obj.category === 'vanity') color = '#ff69b4';
            else if (obj.category === 'bathtub') color = '#00ff88';
            else if (obj.category === 'table') color = '#ffff00';

            ctx.strokeStyle = color;
            ctx.lineWidth = 2;
            ctx.strokeRect(px - w/2, py - h/2, w, h);

            if (layers.labels) {{
                ctx.fillStyle = color;
                ctx.font = '10px -apple-system, sans-serif';
                ctx.fillText(obj.category, px - w/2, py - h/2 - 3);
            }}
        }}
    }}

    ctx.restore();
    ctx.globalAlpha = 1;

    // Update container transform for pan/zoom
    container.style.transform = `translate(${{viewX}}px, ${{viewY}}px) scale(${{viewZoom}})`;
}}

function toggleLayer(name) {{
    layers[name] = !layers[name];
    document.getElementById('btn' + name.charAt(0).toUpperCase() + name.slice(1)).classList.toggle('active');
    redraw();
}}

function fitView() {{
    const ww = wrap.clientWidth;
    const wh = wrap.clientHeight;
    const iw = img.naturalWidth || 1024;
    const ih = img.naturalHeight || 768;
    viewZoom = Math.min(ww / iw, wh / ih) * 0.9;
    viewX = (ww - iw * viewZoom) / 2;
    viewY = (wh - ih * viewZoom) / 2;
    redraw();
}}

function resetView() {{
    document.getElementById('scaleInput').value = '1.00';
    document.getElementById('rotateInput').value = '0';
    document.getElementById('offsetX').value = '0';
    document.getElementById('offsetY').value = '0';
    fitView();
}}

// Pan and zoom
let isDragging = false, dragStartX, dragStartY;

wrap.addEventListener('mousedown', (e) => {{
    isDragging = true;
    dragStartX = e.clientX - viewX;
    dragStartY = e.clientY - viewY;
    wrap.classList.add('dragging');
}});

window.addEventListener('mousemove', (e) => {{
    if (isDragging) {{
        viewX = e.clientX - dragStartX;
        viewY = e.clientY - dragStartY;
        container.style.transform = `translate(${{viewX}}px, ${{viewY}}px) scale(${{viewZoom}})`;
    }}
}});

window.addEventListener('mouseup', () => {{
    isDragging = false;
    wrap.classList.remove('dragging');
}});

wrap.addEventListener('wheel', (e) => {{
    e.preventDefault();
    const rect = wrap.getBoundingClientRect();
    const mx = e.clientX - rect.left;
    const my = e.clientY - rect.top;

    const oldZoom = viewZoom;
    const delta = e.deltaY > 0 ? 0.9 : 1.1;
    viewZoom *= delta;
    viewZoom = Math.max(0.05, Math.min(10, viewZoom));

    // Zoom toward mouse
    viewX = mx - (mx - viewX) * (viewZoom / oldZoom);
    viewY = my - (my - viewY) * (viewZoom / oldZoom);

    container.style.transform = `translate(${{viewX}}px, ${{viewY}}px) scale(${{viewZoom}})`;
}});

// Redraw on control changes
['scanOpacity', 'planOpacity', 'scaleInput', 'rotateInput', 'offsetX', 'offsetY'].forEach(id => {{
    document.getElementById(id).addEventListener('input', redraw);
}});

// Keyboard shortcuts
window.addEventListener('keydown', (e) => {{
    const step = e.shiftKey ? 10 : 1;
    if (e.key === 'ArrowLeft') {{ document.getElementById('offsetX').value = parseFloat(document.getElementById('offsetX').value) - step; redraw(); }}
    if (e.key === 'ArrowRight') {{ document.getElementById('offsetX').value = parseFloat(document.getElementById('offsetX').value) + step; redraw(); }}
    if (e.key === 'ArrowUp') {{ document.getElementById('offsetY').value = parseFloat(document.getElementById('offsetY').value) - step; redraw(); }}
    if (e.key === 'ArrowDown') {{ document.getElementById('offsetY').value = parseFloat(document.getElementById('offsetY').value) + step; redraw(); }}
    if (e.key === '[') {{ document.getElementById('rotateInput').value = parseFloat(document.getElementById('rotateInput').value) - 0.5; redraw(); }}
    if (e.key === ']') {{ document.getElementById('rotateInput').value = parseFloat(document.getElementById('rotateInput').value) + 0.5; redraw(); }}
    if (e.key === '-') {{ document.getElementById('scaleInput').value = (parseFloat(document.getElementById('scaleInput').value) - 0.01).toFixed(2); redraw(); }}
    if (e.key === '=') {{ document.getElementById('scaleInput').value = (parseFloat(document.getElementById('scaleInput').value) + 0.01).toFixed(2); redraw(); }}
}});
</script>
</body>
</html>"""

    with open(output_path, 'w') as f:
        f.write(html)
    print(f"\nOverlay saved to: {output_path}")

def main():
    print("=" * 60)
    print("STUDIIO SCANNER - Scan Overlay Analysis")
    print("=" * 60)

    print(f"\nScan: {SCAN_DIR.name}")
    print(f"Plan: {REAL_PLAN.name}")

    # Extract mesh data
    print("\n--- Extracting mesh vertices ---")
    points, y_values = extract_floor_outline(SCAN_DIR)

    # Get objects
    print("\n--- Detected objects ---")
    objects = get_metadata_objects(SCAN_DIR)
    for obj in objects:
        print(f"  {obj['category']:12s} at ({obj['x']:.1f}, {obj['z']:.1f}) size {obj['dx']:.1f}x{obj['dz']:.1f}m")

    # Analyze scan area
    xs = [p[0] for p in points]
    zs = [p[1] for p in points]
    print(f"\n--- Scan footprint ---")
    print(f"  X range: {min(xs):.2f} to {max(xs):.2f} = {max(xs)-min(xs):.2f}m")
    print(f"  Z range: {min(zs):.2f} to {max(zs):.2f} = {max(zs)-min(zs):.2f}m")
    print(f"  Reported area: 45.4 sq m")

    # Identify which part of the house
    print(f"\n--- Room identification ---")
    print("  Objects found: bathtub, 4x toilet, 3x vanity, 5x table")
    print("  This scan covers the WET AREAS of the upper floor:")
    print("  -> ENSUITE 2 (bathtub + vanity)")
    print("  -> POWDER ROOM / PWD (toilet + vanity)")
    print("  -> Likely also RUMPUS / ENTRY / LIVING adjacent areas")
    print("  The scan footprint (~9.5m x 6.5m) matches the central")
    print("  upper floor zone from Rumpus through to Ensuite 2.")

    # Create overlay
    print("\n--- Generating overlay HTML ---")
    create_overlay_html(points, y_values, objects, REAL_PLAN, OUTPUT)
    print("\nDone! Open overlay-comparison.html in a browser.")
    print("Use arrow keys to nudge, [ ] to rotate, - = to scale.")

if __name__ == "__main__":
    main()
