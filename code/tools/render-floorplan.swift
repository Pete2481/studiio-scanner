#!/usr/bin/env swift
//
// render-floorplan.swift
// Takes mesh-to-floorplan output and renders a production-quality
// architectural floor plan SVG, matching Australian drafting conventions.
//
// Usage: swift render-floorplan.swift /path/to/scan.studiio
//

import Foundation
import simd

// ============================================================================
// MARK: - Data Structures (shared with mesh-to-floorplan)
// ============================================================================

struct MeshAnchor {
    let transform: simd_float4x4
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var indices: [UInt32]
}

// ============================================================================
// MARK: - Binary Mesh Reader
// ============================================================================

func readMeshBinary(from url: URL) -> MeshAnchor? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return data.withUnsafeBytes { rawBuffer -> MeshAnchor? in
        guard let basePtr = rawBuffer.baseAddress else { return nil }
        var offset = 0
        func readFloat() -> Float {
            var f: Float = 0
            memcpy(&f, basePtr.advanced(by: offset), 4)
            offset += 4
            return f
        }
        func readU32() -> UInt32 {
            var u: UInt32 = 0
            memcpy(&u, basePtr.advanced(by: offset), 4)
            offset += 4
            return u
        }
        var floats: [Float] = []
        for _ in 0..<16 { floats.append(readFloat()) }
        let transform = simd_float4x4(
            SIMD4<Float>(floats[0], floats[1], floats[2], floats[3]),
            SIMD4<Float>(floats[4], floats[5], floats[6], floats[7]),
            SIMD4<Float>(floats[8], floats[9], floats[10], floats[11]),
            SIMD4<Float>(floats[12], floats[13], floats[14], floats[15])
        )
        let vertexCount = Int(readU32())
        guard offset + vertexCount * 16 <= data.count else { return nil }
        var positions: [SIMD3<Float>] = []
        for _ in 0..<vertexCount {
            let x = readFloat(), y = readFloat(), z = readFloat()
            let _ = readFloat()
            positions.append(SIMD3<Float>(x, y, z))
        }
        let normalCount = Int(readU32())
        guard offset + normalCount * 16 <= data.count else { return nil }
        var normals: [SIMD3<Float>] = []
        for _ in 0..<normalCount {
            let x = readFloat(), y = readFloat(), z = readFloat()
            let _ = readFloat()
            normals.append(SIMD3<Float>(x, y, z))
        }
        let indexCount = Int(readU32())
        guard offset + indexCount * 4 <= data.count else { return nil }
        var indices: [UInt32] = []
        for _ in 0..<indexCount { indices.append(readU32()) }
        return MeshAnchor(transform: transform, positions: positions, normals: normals, indices: indices)
    }
}

// ============================================================================
// MARK: - Geometry Processing
// ============================================================================

struct WallLine {
    var x1: Float, z1: Float, x2: Float, z2: Float
    var thickness: Float
    var inlierCount: Int
    var length: Float { sqrt(pow(x2 - x1, 2) + pow(z2 - z1, 2)) }
    var angle: Float { atan2(z2 - z1, x2 - x1) }
    var midX: Float { (x1 + x2) / 2 }
    var midZ: Float { (z1 + z2) / 2 }
    var isHorizontal: Bool {
        let a = abs(angle)
        return a < 0.26 || abs(a - .pi) < 0.26
    }
    var isVertical: Bool {
        let a = abs(angle)
        return abs(a - .pi / 2) < 0.26
    }
}

struct WallOpening {
    enum Kind: String { case door, window, slidingDoor, doubleDoor, garageDoor, opening }
    var kind: Kind
    var x: Float, z: Float
    var width: Float
    var wallAngle: Float  // angle of the wall this opening is on
    var hasSill: Bool     // true = window
}

struct DetectedObject {
    var category: String
    var label: String
    var x: Float, z: Float
    var width: Float, depth: Float
    var height: Float
}

struct FloorPlanData {
    var walls: [WallLine]
    var openings: [WallOpening]
    var objects: [DetectedObject]
    var roomWidth: Float   // inner dimension (horizontal)
    var roomDepth: Float   // inner dimension (vertical)
    var floorY: Float
    var bounds: (minX: Float, maxX: Float, minZ: Float, maxZ: Float)
}

// ============================================================================
// MARK: - Extract Floor Plan Data from Mesh
// ============================================================================

func extractData(meshDir: URL) -> FloorPlanData? {
    let indexURL = meshDir.appendingPathComponent("index.json")
    guard let indexData = try? Data(contentsOf: indexURL),
          let indexJSON = try? JSONSerialization.jsonObject(with: indexData) as? [String: Any],
          let anchorsArray = indexJSON["anchors"] as? [[String: Any]] else { return nil }

    print("Loading \(anchorsArray.count) mesh anchors...")
    var allVertices: [(pos: SIMD3<Float>, normal: SIMD3<Float>)] = []

    for info in anchorsArray {
        guard let filename = info["file"] as? String else { continue }
        guard let anchor = readMeshBinary(from: meshDir.appendingPathComponent(filename)) else { continue }
        let t = anchor.transform
        for i in 0..<min(anchor.positions.count, anchor.normals.count) {
            let p = anchor.positions[i]
            let wp = t * SIMD4<Float>(p.x, p.y, p.z, 1.0)
            let n = anchor.normals[i]
            let wn = t * SIMD4<Float>(n.x, n.y, n.z, 0.0)
            let wnNorm = normalize(SIMD3<Float>(wn.x, wn.y, wn.z))
            allVertices.append((pos: SIMD3<Float>(wp.x, wp.y, wp.z), normal: wnNorm))
        }
    }

    print("Total vertices: \(allVertices.count)")

    // Floor level
    var floorCandidates: [Float] = []
    for v in allVertices where v.normal.y > 0.8 { floorCandidates.append(v.pos.y) }
    floorCandidates.sort()
    let floorY = floorCandidates.count > 100 ? floorCandidates[floorCandidates.count / 10] :
                 (floorCandidates.first ?? allVertices.map(\.pos.y).min() ?? 0)

    // Wall points + normals for angle detection
    var wallPoints: [(x: Float, z: Float)] = []
    var wallNormals: [(nx: Float, nz: Float)] = []
    for v in allVertices {
        if abs(v.normal.y) < 0.3 && v.pos.y >= floorY + 0.5 && v.pos.y <= floorY + 1.5 {
            wallPoints.append((x: v.pos.x, z: v.pos.z))
            wallNormals.append((nx: v.normal.x, nz: v.normal.z))
        }
    }

    // Dominant angle
    let binCount = 180
    var hist = Array(repeating: 0, count: binCount)
    for n in wallNormals {
        var a = atan2(n.nz, n.nx)
        if a < 0 { a += .pi }
        hist[min(Int(a / .pi * Float(binCount)), binCount - 1)] += 1
    }
    var smoothed = Array(repeating: 0, count: binCount)
    for i in 0..<binCount {
        var s = 0; for d in -3...3 { s += hist[(i + d + binCount) % binCount] }
        smoothed[i] = s
    }
    let peak = smoothed.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
    let normalAngle = Float(peak) / Float(binCount) * .pi
    let rotAngle = -(normalAngle - .pi / 2)

    let cosA = cos(rotAngle), sinA = sin(rotAngle)

    // Rotate everything
    let rotWallPts = wallPoints.map { p -> (x: Float, z: Float) in
        (x: p.x * cosA - p.z * sinA, z: p.x * sinA + p.z * cosA)
    }
    let rotVertices = allVertices.map { v -> (pos: SIMD3<Float>, normal: SIMD3<Float>) in
        let rx = v.pos.x * cosA - v.pos.z * sinA
        let rz = v.pos.x * sinA + v.pos.z * cosA
        let rnx = v.normal.x * cosA - v.normal.z * sinA
        let rnz = v.normal.x * sinA + v.normal.z * cosA
        return (pos: SIMD3<Float>(rx, v.pos.y, rz), normal: SIMD3<Float>(rnx, v.normal.y, rnz))
    }

    // RANSAC wall fitting
    var remaining = rotWallPts
    var walls: [WallLine] = []
    let minInliers = max(20, rotWallPts.count / 50)

    for _ in 0..<15 {
        guard remaining.count >= minInliers else { break }
        var bestInliers: [(x: Float, z: Float)] = []
        var bestOutliers: [(x: Float, z: Float)] = []
        var bestWall: WallLine?

        for _ in 0..<400 {
            let i1 = Int.random(in: 0..<remaining.count)
            var i2 = Int.random(in: 0..<remaining.count)
            while i2 == i1 { i2 = Int.random(in: 0..<remaining.count) }
            let p1 = remaining[i1], p2 = remaining[i2]
            let dx = p2.x - p1.x, dz = p2.z - p1.z
            let len = sqrt(dx * dx + dz * dz)
            guard len > 0.1 else { continue }
            let nx = -dz / len, nz = dx / len

            var inliers: [(x: Float, z: Float)] = []
            var outliers: [(x: Float, z: Float)] = []
            for p in remaining {
                if abs((p.x - p1.x) * nx + (p.z - p1.z) * nz) < 0.04 {
                    inliers.append(p)
                } else { outliers.append(p) }
            }

            if inliers.count > bestInliers.count {
                var minT: Float = .greatestFiniteMagnitude, maxT: Float = -.greatestFiniteMagnitude
                var perps: [Float] = []
                for p in inliers {
                    let t = (p.x - p1.x) * (dx / len) + (p.z - p1.z) * (dz / len)
                    minT = min(minT, t); maxT = max(maxT, t)
                    perps.append((p.x - p1.x) * nx + (p.z - p1.z) * nz)
                }
                perps.sort()
                let thick = perps.count > 10 ? perps[perps.count * 9 / 10] - perps[perps.count / 10] : 0.07
                let wallLen = maxT - minT
                if wallLen > 0.3 {
                    bestInliers = inliers; bestOutliers = outliers
                    bestWall = WallLine(
                        x1: p1.x + (dx / len) * minT, z1: p1.z + (dz / len) * minT,
                        x2: p1.x + (dx / len) * maxT, z2: p1.z + (dz / len) * maxT,
                        thickness: max(thick, 0.07), inlierCount: inliers.count
                    )
                }
            }
        }
        guard let wall = bestWall, bestInliers.count >= minInliers else { break }

        // Snap to axis
        var w = wall
        let snapTol: Float = 15 * .pi / 180
        let a = w.angle
        let rem = a.truncatingRemainder(dividingBy: .pi / 2)
        if abs(rem) < snapTol || abs(rem - .pi / 2) < snapTol || abs(rem + .pi / 2) < snapTol {
            let snapped: Float
            if abs(rem) < snapTol { snapped = a - rem }
            else if abs(rem - .pi / 2) < snapTol { snapped = a - rem + .pi / 2 }
            else { snapped = a - rem - .pi / 2 }
            let mid = (x: (w.x1 + w.x2) / 2, z: (w.z1 + w.z2) / 2)
            let hl = w.length / 2
            w.x1 = mid.x - cos(snapped) * hl; w.z1 = mid.z - sin(snapped) * hl
            w.x2 = mid.x + cos(snapped) * hl; w.z2 = mid.z + sin(snapped) * hl
        }

        walls.append(w)
        remaining = bestOutliers
    }

    // Opening detection
    var openings: [WallOpening] = []
    for wall in walls where wall.length > 1.0 {
        let dx = wall.x2 - wall.x1, dz = wall.z2 - wall.z1
        let len = wall.length
        let nx = -dz / len, nz = dx / len
        let segSize: Float = 0.1
        let segCount = Int(len / segSize)
        guard segCount > 3 else { continue }

        var densityLow = Array(repeating: 0, count: segCount)
        var densityMid = Array(repeating: 0, count: segCount)

        for v in rotVertices {
            let pd = abs((v.pos.x - wall.x1) * nx + (v.pos.z - wall.z1) * nz)
            guard pd < 0.15 && abs(v.normal.y) < 0.3 else { continue }
            let t = (v.pos.x - wall.x1) * (dx / len) + (v.pos.z - wall.z1) * (dz / len)
            let seg = Int(t / segSize)
            guard seg >= 0 && seg < segCount else { continue }
            let h = v.pos.y - floorY
            if h >= 0 && h < 0.5 { densityLow[seg] += 1 }
            else if h >= 0.5 && h < 2.0 { densityMid[seg] += 1 }
        }

        let avg = densityMid.reduce(0, +) / max(1, segCount)
        let thresh = max(2, avg / 4)
        var inGap = false, gapStart = 0

        for seg in 0..<segCount {
            let sparse = densityMid[seg] < thresh
            if sparse && !inGap { inGap = true; gapStart = seg }
            else if !sparse && inGap {
                inGap = false
                let gapW = Float(seg - gapStart) * segSize
                if gapW >= 0.5 && gapW <= 5.0 {
                    let center = Float(gapStart + seg) / 2 * segSize
                    let px = wall.x1 + (dx / len) * center
                    let pz = wall.z1 + (dz / len) * center
                    let lowDens = (gapStart..<seg).map { densityLow[$0] }.reduce(0, +)
                    let hasSill = lowDens > (seg - gapStart) * 2

                    let kind: WallOpening.Kind
                    if hasSill { kind = .window }
                    else if gapW >= 2.4 { kind = .garageDoor }
                    else if gapW >= 1.5 { kind = .slidingDoor }
                    else if gapW >= 1.2 { kind = .doubleDoor }
                    else if gapW >= 0.5 { kind = .door }
                    else { kind = .opening }

                    openings.append(WallOpening(kind: kind, x: px, z: pz, width: gapW, wallAngle: wall.angle, hasSill: hasSill))
                }
            }
        }
    }

    // Object detection
    var objects: [DetectedObject] = []
    let bands: [(min: Float, max: Float, name: String)] = [
        (0.35, 0.55, "low"), (0.70, 0.82, "mid"), (0.82, 0.98, "counter")
    ]
    for band in bands {
        var pts: [SIMD3<Float>] = []
        for v in rotVertices where v.normal.y > 0.6 && v.pos.y >= floorY + band.min && v.pos.y <= floorY + band.max {
            pts.append(v.pos)
        }
        guard pts.count > 20 else { continue }
        let cs: Float = 0.3
        var grid: [String: [SIMD3<Float>]] = [:]
        for p in pts { grid["\(Int(p.x / cs)),\(Int(p.z / cs))", default: []].append(p) }
        var vis = Set<String>()
        for key in grid.keys {
            guard !vis.contains(key) else { continue }
            var cluster: [SIMD3<Float>] = []; var q = [key]
            while !q.isEmpty {
                let c = q.removeFirst()
                guard !vis.contains(c) else { continue }
                vis.insert(c)
                if let p = grid[c] { cluster.append(contentsOf: p) }
                let parts = c.split(separator: ",")
                guard parts.count == 2, let cx = Int(parts[0]), let cz = Int(parts[1]) else { continue }
                for dx in -1...1 { for dz in -1...1 {
                    if dx == 0 && dz == 0 { continue }
                    let nb = "\(cx + dx),\(cz + dz)"
                    if grid[nb] != nil && !vis.contains(nb) { q.append(nb) }
                }}
            }
            guard cluster.count >= 10 else { continue }
            let w = cluster.map(\.x).max()! - cluster.map(\.x).min()!
            let d = cluster.map(\.z).max()! - cluster.map(\.z).min()!
            let avgY = cluster.map(\.y).reduce(0, +) / Float(cluster.count)
            let h = avgY - floorY
            guard w > 0.25 && d > 0.2 && w < 5.0 && d < 3.0 else { continue }

            let cat: String; let lbl: String
            if band.name == "counter" {
                if w > 1.0 || d > 1.0 { cat = "bench"; lbl = "BENCH" }
                else { cat = "vanity"; lbl = "VAN" }
            } else if band.name == "low" {
                let ls = max(w, d), ss = min(w, d)
                if ss > 0.25 && ss < 0.6 && ls > 0.35 && ls < 0.85 { cat = "toilet"; lbl = "WC" }
                else if ls > 1.2 && ss > 0.5 { cat = "bath"; lbl = "BATH" }
                else { cat = "table"; lbl = "TABLE" }
            } else {
                if w > 1.5 && d > 0.8 { cat = "bed"; lbl = "BED" }
                else { cat = "table"; lbl = "TABLE" }
            }
            objects.append(DetectedObject(category: cat, label: lbl,
                x: (cluster.map(\.x).min()! + cluster.map(\.x).max()!) / 2,
                z: (cluster.map(\.z).min()! + cluster.map(\.z).max()!) / 2,
                width: w, depth: d, height: h))
        }
    }

    // Room dimensions
    let hWalls = walls.filter { $0.isHorizontal && $0.length > 0.5 }.sorted { $0.midZ < $1.midZ }
    let vWalls = walls.filter { $0.isVertical && $0.length > 0.5 }.sorted { $0.midX < $1.midX }

    var roomW: Float = 0, roomD: Float = 0
    if hWalls.count >= 2 {
        roomD = abs(hWalls.last!.midZ - hWalls.first!.midZ) - (hWalls.first!.thickness + hWalls.last!.thickness) / 2
    }
    if vWalls.count >= 2 {
        roomW = abs(vWalls.last!.midX - vWalls.first!.midX) - (vWalls.first!.thickness + vWalls.last!.thickness) / 2
    }

    let minX = rotWallPts.map(\.x).min()!
    let maxX = rotWallPts.map(\.x).max()!
    let minZ = rotWallPts.map(\.z).min()!
    let maxZ = rotWallPts.map(\.z).max()!

    print("Room: \(Int(roomW * 1000))mm x \(Int(roomD * 1000))mm")
    print("Walls: \(walls.count), Openings: \(openings.count), Objects: \(objects.count)")

    return FloorPlanData(walls: walls, openings: openings, objects: objects,
                         roomWidth: roomW, roomDepth: roomD, floorY: floorY,
                         bounds: (minX, maxX, minZ, maxZ))
}

// ============================================================================
// MARK: - Architectural SVG Renderer
// ============================================================================

func renderArchitecturalSVG(_ data: FloorPlanData, address: String?) -> String {
    // A3 landscape proportions at screen resolution
    // Real A3 = 420 × 297mm. At 1:100 scale, 1m = 10mm on paper.
    // For SVG we use pixels: 1m = 100px (adjustable)
    let scale: Float = 100.0  // pixels per metre

    let roomW = data.roomWidth
    let roomD = data.roomDepth

    // Drawing area with margins for dimensions and title
    let marginLeft: Float = 120
    let marginRight: Float = 120
    let marginTop: Float = 100
    let marginBottom: Float = 140
    let drawW = max(roomW, data.bounds.maxX - data.bounds.minX) * scale
    let drawH = max(roomD, data.bounds.maxZ - data.bounds.minZ) * scale
    let svgW = drawW + marginLeft + marginRight
    let svgH = drawH + marginTop + marginBottom

    // Coordinate transforms (world → SVG)
    let originX = data.bounds.minX
    let originZ = data.bounds.minZ
    func sx(_ x: Float) -> Float { (x - originX) * scale + marginLeft }
    func sy(_ z: Float) -> Float { (z - originZ) * scale + marginTop }

    // Wall rendering thickness in pixels
    let wallPx: Float = 8.0  // ~80mm at 1:100

    var svg = """
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg"
         viewBox="0 0 \(Int(svgW)) \(Int(svgH))"
         width="\(Int(svgW))" height="\(Int(svgH))"
         style="background: #FAFAFA">
    <defs>
      <style>
        text { font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; }
        .wall { fill: #1A1A1A; stroke: none; }
        .wall-line { stroke: #1A1A1A; stroke-linecap: butt; }
        .dim-line { stroke: #333; stroke-width: 0.5; }
        .dim-tick { stroke: #333; stroke-width: 0.8; }
        .dim-text { fill: #333; font-size: 11px; }
        .room-label { fill: #1A1A1A; font-size: 16px; font-weight: 600; }
        .room-area { fill: #666; font-size: 12px; }
        .door-arc { stroke: #333; stroke-width: 1; fill: none; }
        .door-line { stroke: #333; stroke-width: 1.5; }
        .window-line { stroke: #333; stroke-width: 1; }
        .window-fill { fill: #E3F2FD; stroke: #333; stroke-width: 0.5; }
        .fixture-outline { fill: none; stroke: #555; stroke-width: 1; }
        .fixture-fill { fill: #F5F5F5; stroke: #555; stroke-width: 0.8; }
        .fixture-label { fill: #777; font-size: 8px; text-anchor: middle; }
        .title-text { fill: #1A1A1A; font-size: 20px; font-weight: 700; letter-spacing: 2px; }
        .subtitle-text { fill: #666; font-size: 11px; }
        .disclaimer { fill: #999; font-size: 7px; }
        .scale-line { stroke: #333; stroke-width: 1.5; }
        .scale-tick { stroke: #333; stroke-width: 1; }
        .scale-text { fill: #333; font-size: 9px; }
        .opening-label { fill: #888; font-size: 8px; text-anchor: middle; }
      </style>
      <!-- Hatch pattern for benches -->
      <pattern id="hatch" patternUnits="userSpaceOnUse" width="6" height="6" patternTransform="rotate(45)">
        <line x1="0" y1="0" x2="0" y2="6" stroke="#CCC" stroke-width="0.5"/>
      </pattern>
    </defs>

    """

    // ---- WALLS (solid filled rectangles) ----
    svg += "<!-- Walls -->\n<g>\n"
    for wall in data.walls where wall.length > 0.2 {
        let dx = wall.x2 - wall.x1
        let dz = wall.z2 - wall.z1
        let len = wall.length
        // Normal direction (perpendicular)
        let nx = -dz / len
        let nz = dx / len
        let halfT = max(wall.thickness, 0.07) / 2

        // Four corners of the wall rectangle
        let corners = [
            (wall.x1 + nx * halfT, wall.z1 + nz * halfT),
            (wall.x2 + nx * halfT, wall.z2 + nz * halfT),
            (wall.x2 - nx * halfT, wall.z2 - nz * halfT),
            (wall.x1 - nx * halfT, wall.z1 - nz * halfT),
        ]
        let points = corners.map { "\(sx($0.0)),\(sy($0.1))" }.joined(separator: " ")
        svg += "  <polygon points=\"\(points)\" class=\"wall\" />\n"
    }
    svg += "</g>\n"

    // ---- OPENINGS (cut into walls) ----
    // Draw white rectangles over walls to create openings, then add symbols
    svg += "<!-- Openings -->\n<g>\n"
    for opening in data.openings {
        let hw = opening.width / 2
        let wallCos = cos(opening.wallAngle)
        let wallSin = sin(opening.wallAngle)
        let perpCos = cos(opening.wallAngle + .pi / 2)
        let perpSin = sin(opening.wallAngle + .pi / 2)

        // White rectangle to cut wall
        let cutDepth: Float = 0.12  // slightly wider than wall
        let cx = [
            (opening.x - wallCos * hw - perpCos * cutDepth, opening.z - wallSin * hw - perpSin * cutDepth),
            (opening.x + wallCos * hw - perpCos * cutDepth, opening.z + wallSin * hw - perpSin * cutDepth),
            (opening.x + wallCos * hw + perpCos * cutDepth, opening.z + wallSin * hw + perpSin * cutDepth),
            (opening.x - wallCos * hw + perpCos * cutDepth, opening.z - wallSin * hw + perpSin * cutDepth),
        ]
        let cutPts = cx.map { "\(sx($0.0)),\(sy($0.1))" }.joined(separator: " ")
        svg += "  <polygon points=\"\(cutPts)\" fill=\"#FAFAFA\" stroke=\"none\" />\n"

        let ox = sx(opening.x)
        let oz = sy(opening.z)

        switch opening.kind {
        case .door:
            // Standard door: swing arc
            let arcR = opening.width * scale
            let hinge1X = sx(opening.x - wallCos * hw)
            let hinge1Z = sy(opening.z - wallSin * hw)
            // Door line (closed position)
            svg += "  <line x1=\"\(hinge1X)\" y1=\"\(hinge1Z)\" x2=\"\(sx(opening.x + wallCos * hw))\" y2=\"\(sy(opening.z + wallSin * hw))\" class=\"door-line\" />\n"
            // 90° arc
            let arcEndX = hinge1X + perpCos * arcR * scale / scale
            let arcEndZ = hinge1Z + perpSin * arcR * scale / scale
            let r = hw * scale
            svg += "  <path d=\"M \(sx(opening.x + wallCos * hw)) \(sy(opening.z + wallSin * hw)) A \(r) \(r) 0 0 1 \(hinge1X + perpCos * r) \(hinge1Z + perpSin * r)\" class=\"door-arc\" />\n"
            svg += "  <text x=\"\(ox)\" y=\"\(oz - 10)\" class=\"opening-label\">\(Int(opening.width * 1000))</text>\n"

        case .doubleDoor, .slidingDoor:
            // Sliding/double: two parallel lines with arrows
            let lineOff: Float = 3
            let sx1 = sx(opening.x - wallCos * hw)
            let sz1 = sy(opening.z - wallSin * hw)
            let sx2 = sx(opening.x + wallCos * hw)
            let sz2 = sy(opening.z + wallSin * hw)
            svg += "  <line x1=\"\(sx1)\" y1=\"\(sz1 - lineOff)\" x2=\"\(sx2)\" y2=\"\(sz2 - lineOff)\" class=\"door-line\" />\n"
            svg += "  <line x1=\"\(sx1)\" y1=\"\(sz1 + lineOff)\" x2=\"\(sx2)\" y2=\"\(sz2 + lineOff)\" class=\"door-line\" />\n"
            // Arrows
            svg += "  <line x1=\"\(ox - 8)\" y1=\"\(oz - lineOff)\" x2=\"\(ox + 8)\" y2=\"\(oz - lineOff)\" stroke=\"#333\" stroke-width=\"1\" marker-end=\"url(#arrow)\" />\n"
            let label = opening.kind == .slidingDoor ? "SLD" : "DBL"
            svg += "  <text x=\"\(ox)\" y=\"\(oz - 12)\" class=\"opening-label\">\(label) \(Int(opening.width * 1000))</text>\n"

        case .garageDoor:
            let sx1 = sx(opening.x - wallCos * hw)
            let sz1 = sy(opening.z - wallSin * hw)
            let sx2 = sx(opening.x + wallCos * hw)
            let sz2 = sy(opening.z + wallSin * hw)
            svg += "  <line x1=\"\(sx1)\" y1=\"\(sz1)\" x2=\"\(sx2)\" y2=\"\(sz2)\" stroke=\"#333\" stroke-width=\"2\" stroke-dasharray=\"8,4\" />\n"
            svg += "  <text x=\"\(ox)\" y=\"\(oz - 10)\" class=\"opening-label\">GARAGE \(Int(opening.width * 1000))</text>\n"

        case .window:
            // Window: 3 parallel lines
            let lineOff: Float = 4
            let sx1 = sx(opening.x - wallCos * hw)
            let sz1 = sy(opening.z - wallSin * hw)
            let sx2 = sx(opening.x + wallCos * hw)
            let sz2 = sy(opening.z + wallSin * hw)
            svg += "  <line x1=\"\(sx1)\" y1=\"\(sz1 - lineOff)\" x2=\"\(sx2)\" y2=\"\(sz2 - lineOff)\" class=\"window-line\" />\n"
            svg += "  <line x1=\"\(sx1)\" y1=\"\(sz1)\" x2=\"\(sx2)\" y2=\"\(sz2)\" class=\"window-line\" />\n"
            svg += "  <line x1=\"\(sx1)\" y1=\"\(sz1 + lineOff)\" x2=\"\(sx2)\" y2=\"\(sz2 + lineOff)\" class=\"window-line\" />\n"
            // Glass fill
            svg += "  <rect x=\"\(min(sx1, sx2))\" y=\"\(min(sz1, sz2) - lineOff)\" width=\"\(abs(sx2 - sx1))\" height=\"\(lineOff * 2)\" class=\"window-fill\" />\n"
            svg += "  <text x=\"\(ox)\" y=\"\(oz - lineOff - 6)\" class=\"opening-label\">W \(Int(opening.width * 1000))</text>\n"

        case .opening:
            // Simple dashed line
            let sx1 = sx(opening.x - wallCos * hw)
            let sz1 = sy(opening.z - wallSin * hw)
            let sx2 = sx(opening.x + wallCos * hw)
            let sz2 = sy(opening.z + wallSin * hw)
            svg += "  <line x1=\"\(sx1)\" y1=\"\(sz1)\" x2=\"\(sx2)\" y2=\"\(sz2)\" stroke=\"#999\" stroke-width=\"1\" stroke-dasharray=\"4,4\" />\n"
            svg += "  <text x=\"\(ox)\" y=\"\(oz - 8)\" class=\"opening-label\">\(Int(opening.width * 1000))</text>\n"
        }
    }
    svg += "</g>\n"

    // ---- FIXTURES / OBJECTS ----
    svg += "<!-- Fixtures -->\n<g>\n"
    for obj in data.objects {
        let cx = sx(obj.x)
        let cz = sy(obj.z)
        let w = obj.width * scale
        let d = obj.depth * scale
        let rx = cx - w / 2
        let rz = cz - d / 2

        switch obj.category {
        case "toilet":
            // Toilet: rectangle with oval bowl
            svg += "  <rect x=\"\(rx)\" y=\"\(rz)\" width=\"\(w)\" height=\"\(d)\" class=\"fixture-fill\" rx=\"4\" />\n"
            // Bowl (ellipse in front half)
            svg += "  <ellipse cx=\"\(cx)\" cy=\"\(cz + d * 0.15)\" rx=\"\(w * 0.35)\" ry=\"\(d * 0.3)\" class=\"fixture-outline\" />\n"
            // Cistern (rectangle at back)
            svg += "  <rect x=\"\(rx + w * 0.15)\" y=\"\(rz)\" width=\"\(w * 0.7)\" height=\"\(d * 0.25)\" class=\"fixture-outline\" rx=\"2\" />\n"
            svg += "  <text x=\"\(cx)\" y=\"\(cz + d / 2 + 12)\" class=\"fixture-label\">WC</text>\n"

        case "bath":
            // Bathtub: rounded rectangle with inner outline
            svg += "  <rect x=\"\(rx)\" y=\"\(rz)\" width=\"\(w)\" height=\"\(d)\" class=\"fixture-fill\" rx=\"8\" />\n"
            svg += "  <rect x=\"\(rx + 4)\" y=\"\(rz + 4)\" width=\"\(w - 8)\" height=\"\(d - 8)\" class=\"fixture-outline\" rx=\"6\" />\n"
            svg += "  <text x=\"\(cx)\" y=\"\(cz)\" class=\"fixture-label\">BATH</text>\n"

        case "bench":
            // Kitchen bench: hatched rectangle
            svg += "  <rect x=\"\(rx)\" y=\"\(rz)\" width=\"\(w)\" height=\"\(d)\" fill=\"url(#hatch)\" stroke=\"#555\" stroke-width=\"1\" />\n"
            svg += "  <text x=\"\(cx)\" y=\"\(cz + 4)\" class=\"fixture-label\">BENCH</text>\n"

        case "vanity":
            // Vanity: rectangle with sink circle
            svg += "  <rect x=\"\(rx)\" y=\"\(rz)\" width=\"\(w)\" height=\"\(d)\" class=\"fixture-fill\" rx=\"2\" />\n"
            svg += "  <circle cx=\"\(cx)\" cy=\"\(cz)\" r=\"\(min(w, d) * 0.3)\" class=\"fixture-outline\" />\n"
            svg += "  <text x=\"\(cx)\" y=\"\(cz + d / 2 + 12)\" class=\"fixture-label\">VAN</text>\n"

        case "bed":
            // Bed: rectangle with pillow rectangles
            svg += "  <rect x=\"\(rx)\" y=\"\(rz)\" width=\"\(w)\" height=\"\(d)\" class=\"fixture-fill\" rx=\"4\" />\n"
            // Pillows
            let pw: Float = w * 0.4, ph: Float = d * 0.12
            svg += "  <rect x=\"\(cx - pw - 2)\" y=\"\(rz + 4)\" width=\"\(pw)\" height=\"\(ph)\" class=\"fixture-outline\" rx=\"3\" />\n"
            svg += "  <rect x=\"\(cx + 2)\" y=\"\(rz + 4)\" width=\"\(pw)\" height=\"\(ph)\" class=\"fixture-outline\" rx=\"3\" />\n"
            svg += "  <text x=\"\(cx)\" y=\"\(cz + 4)\" class=\"fixture-label\">BED</text>\n"

        default:
            // Generic: rectangle with label
            svg += "  <rect x=\"\(rx)\" y=\"\(rz)\" width=\"\(w)\" height=\"\(d)\" class=\"fixture-fill\" rx=\"2\" />\n"
            svg += "  <text x=\"\(cx)\" y=\"\(cz + 4)\" class=\"fixture-label\">\(obj.label)</text>\n"
        }
    }
    svg += "</g>\n"

    // ---- DIMENSION LINES ----
    svg += "<!-- Dimensions -->\n<g>\n"

    // Room width (horizontal, above plan)
    if roomW > 0 {
        // Find the actual X extents of inner walls
        let vWalls = data.walls.filter { $0.isVertical && $0.length > 0.5 }.sorted { $0.midX < $1.midX }
        if vWalls.count >= 2 {
            let leftX = sx(vWalls.first!.midX)
            let rightX = sx(vWalls.last!.midX)
            let dimY = marginTop - 30

            svg += "  <line x1=\"\(leftX)\" y1=\"\(dimY)\" x2=\"\(rightX)\" y2=\"\(dimY)\" class=\"dim-line\" />\n"
            svg += "  <line x1=\"\(leftX)\" y1=\"\(dimY - 6)\" x2=\"\(leftX)\" y2=\"\(dimY + 6)\" class=\"dim-tick\" />\n"
            svg += "  <line x1=\"\(rightX)\" y1=\"\(dimY - 6)\" x2=\"\(rightX)\" y2=\"\(dimY + 6)\" class=\"dim-tick\" />\n"
            // Extension lines
            svg += "  <line x1=\"\(leftX)\" y1=\"\(dimY + 6)\" x2=\"\(leftX)\" y2=\"\(marginTop - 5)\" stroke=\"#AAA\" stroke-width=\"0.3\" />\n"
            svg += "  <line x1=\"\(rightX)\" y1=\"\(dimY + 6)\" x2=\"\(rightX)\" y2=\"\(marginTop - 5)\" stroke=\"#AAA\" stroke-width=\"0.3\" />\n"
            svg += "  <text x=\"\((leftX + rightX) / 2)\" y=\"\(dimY - 8)\" text-anchor=\"middle\" class=\"dim-text\">\(Int(roomW * 1000))</text>\n"
        }
    }

    // Room depth (vertical, right side)
    if roomD > 0 {
        let hWalls = data.walls.filter { $0.isHorizontal && $0.length > 0.5 }.sorted { $0.midZ < $1.midZ }
        if hWalls.count >= 2 {
            let topZ = sy(hWalls.first!.midZ)
            let botZ = sy(hWalls.last!.midZ)
            let dimX = svgW - marginRight + 30

            svg += "  <line x1=\"\(dimX)\" y1=\"\(topZ)\" x2=\"\(dimX)\" y2=\"\(botZ)\" class=\"dim-line\" />\n"
            svg += "  <line x1=\"\(dimX - 6)\" y1=\"\(topZ)\" x2=\"\(dimX + 6)\" y2=\"\(topZ)\" class=\"dim-tick\" />\n"
            svg += "  <line x1=\"\(dimX - 6)\" y1=\"\(botZ)\" x2=\"\(dimX + 6)\" y2=\"\(botZ)\" class=\"dim-tick\" />\n"
            svg += "  <line x1=\"\(dimX - 6)\" y1=\"\(topZ)\" x2=\"\(svgW - marginRight + 5)\" y2=\"\(topZ)\" stroke=\"#AAA\" stroke-width=\"0.3\" />\n"
            svg += "  <line x1=\"\(dimX - 6)\" y1=\"\(botZ)\" x2=\"\(svgW - marginRight + 5)\" y2=\"\(botZ)\" stroke=\"#AAA\" stroke-width=\"0.3\" />\n"
            svg += "  <text x=\"\(dimX + 12)\" y=\"\((topZ + botZ) / 2 + 4)\" class=\"dim-text\" transform=\"rotate(90 \(dimX + 12) \((topZ + botZ) / 2 + 4))\">\(Int(roomD * 1000))</text>\n"
        }
    }
    svg += "</g>\n"

    // ---- ROOM LABEL ----
    let centerX = (sx(data.bounds.minX) + sx(data.bounds.maxX)) / 2
    let centerZ = (sy(data.bounds.minZ) + sy(data.bounds.maxZ)) / 2
    let area = roomW * roomD
    svg += """

    <!-- Room Label -->
    <text x="\(centerX)" y="\(centerZ - 8)" text-anchor="middle" class="room-label">RUMPUS</text>
    <text x="\(centerX)" y="\(centerZ + 8)" text-anchor="middle" class="room-area">\(String(format: "%.1f", area)) m\u{00B2}</text>

    """

    // ---- TITLE BLOCK ----
    let titleY = svgH - marginBottom + 40
    let addr = address ?? "STUDIIO SCAN"

    svg += """

    <!-- Title Block -->
    <line x1="\(marginLeft)" y1="\(svgH - marginBottom + 20)" x2="\(svgW - marginRight)" y2="\(svgH - marginBottom + 20)" stroke="#DDD" stroke-width="1" />
    <text x="\(marginLeft)" y="\(titleY)" class="title-text">\(addr.uppercased())</text>
    <text x="\(marginLeft)" y="\(titleY + 18)" class="subtitle-text">Floor Plan — Scale 1:100 @ A3 — \(dateString())</text>
    <text x="\(marginLeft)" y="\(titleY + 36)" class="disclaimer">IMPORTANT: All measurements are approximate and have been derived from LiDAR scanning technology. Measurements should not be relied upon for construction or legal purposes. Verify all dimensions on site.</text>
    <text x="\(marginLeft)" y="\(titleY + 48)" class="disclaimer">Generated by STUDIIO Scanner — studiio.com.au</text>

    <!-- Scale Bar -->
    <g transform="translate(\(svgW - marginRight - scale * 2 - 10), \(titleY - 5))">
      <line x1="0" y1="0" x2="\(scale)" y2="0" class="scale-line" />
      <line x1="0" y1="-4" x2="0" y2="4" class="scale-tick" />
      <line x1="\(scale)" y1="-4" x2="\(scale)" y2="4" class="scale-tick" />
      <line x1="\(scale)" y1="0" x2="\(scale * 2)" y2="0" stroke="#333" stroke-width="1.5" stroke-dasharray="5,5" />
      <line x1="\(scale * 2)" y1="-4" x2="\(scale * 2)" y2="4" class="scale-tick" />
      <text x="0" y="14" class="scale-text" text-anchor="middle">0</text>
      <text x="\(scale)" y="14" class="scale-text" text-anchor="middle">1m</text>
      <text x="\(scale * 2)" y="14" class="scale-text" text-anchor="middle">2m</text>
    </g>

    <!-- North Arrow -->
    <g transform="translate(\(svgW - marginRight - 20), \(marginTop + 20))">
      <line x1="0" y1="20" x2="0" y2="-10" stroke="#333" stroke-width="1.5" />
      <polygon points="-5,0 5,0 0,-10" fill="#333" />
      <text x="0" y="30" text-anchor="middle" fill="#333" font-size="9" font-weight="bold">N</text>
    </g>

    """

    svg += "</svg>\n"
    return svg
}

func dateString() -> String {
    let df = DateFormatter()
    df.dateFormat = "d MMM yyyy"
    return df.string(from: Date())
}

// ============================================================================
// MARK: - Main
// ============================================================================

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Usage: swift render-floorplan.swift /path/to/scan.studiio")
    exit(1)
}

let bundlePath = args[1]
let meshDir = URL(fileURLWithPath: bundlePath).appendingPathComponent("mesh")

guard FileManager.default.fileExists(atPath: meshDir.path) else {
    print("ERROR: No mesh/ directory found in \(bundlePath)")
    exit(1)
}

// Read address from metadata
var address: String?
let metaURL = URL(fileURLWithPath: bundlePath).appendingPathComponent("metadata.json")
if let metaData = try? Data(contentsOf: metaURL),
   let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any] {
    address = meta["address"] as? String
}

guard let data = extractData(meshDir: meshDir) else {
    print("ERROR: Failed to extract floor plan data")
    exit(1)
}

let svg = renderArchitecturalSVG(data, address: address)

let outputURL = URL(fileURLWithPath: bundlePath).deletingLastPathComponent()
    .appendingPathComponent("floorplan-final.svg")
try? svg.write(toFile: outputURL.path, atomically: true, encoding: .utf8)
print("\nArchitectural floor plan written to: \(outputURL.path)")
