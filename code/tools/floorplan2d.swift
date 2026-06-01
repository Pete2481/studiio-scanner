#!/usr/bin/env swift
//  floorplan2d.swift — Clean 2D floor plan from LiDAR mesh
//
//  Approach:
//  1. Load mesh, transform to world space
//  2. Find floor level, take horizontal slice at 1m height
//  3. Build 2D occupancy grid from wall-normal vertices
//  4. Detect wall axis alignment angle
//  5. Fit wall lines using occupancy density peaks
//  6. Detect openings (gaps in walls)
//  7. Render as clean SVG with wall lines, openings, dimensions, mesh shadow

import Foundation
import simd

// MARK: - Mesh loading

func loadMesh(_ url: URL) -> (positions: [SIMD3<Float>], normals: [SIMD3<Float>])? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    var offset = 0
    func read<T>(_ type: T.Type) -> T {
        let size = MemoryLayout<T>.size
        let value = data[offset..<offset+size].withUnsafeBytes { $0.load(as: T.self) }
        offset += size
        return value
    }
    let t = read(simd_float4x4.self)
    let vc = Int(read(UInt32.self))
    var pos: [SIMD3<Float>] = []; pos.reserveCapacity(vc)
    for _ in 0..<vc { pos.append(read(SIMD3<Float>.self)) }
    let nc = Int(read(UInt32.self))
    var nrm: [SIMD3<Float>] = []; nrm.reserveCapacity(nc)
    for _ in 0..<nc { nrm.append(read(SIMD3<Float>.self)) }

    // Transform to world space
    var wPos: [SIMD3<Float>] = []; wPos.reserveCapacity(vc)
    var wNrm: [SIMD3<Float>] = []; wNrm.reserveCapacity(nc)
    for i in 0..<vc {
        let lp = pos[i]
        let wp = t * SIMD4<Float>(lp.x, lp.y, lp.z, 1.0)
        wPos.append(SIMD3<Float>(wp.x, wp.y, wp.z))
    }
    for i in 0..<nc {
        let ln = nrm[i]
        let wn = t * SIMD4<Float>(ln.x, ln.y, ln.z, 0.0)
        wNrm.append(normalize(SIMD3<Float>(wn.x, wn.y, wn.z)))
    }
    return (wPos, wNrm)
}

// MARK: - Main

guard CommandLine.arguments.count >= 2 else {
    print("Usage: floorplan2d <path-to.studiio>"); exit(1)
}

let bundleURL = URL(fileURLWithPath: CommandLine.arguments[1])
let meshDir = bundleURL.appendingPathComponent("mesh")

guard let indexData = try? Data(contentsOf: meshDir.appendingPathComponent("index.json")),
      let indexJSON = try? JSONSerialization.jsonObject(with: indexData) as? [String: Any],
      let anchors = indexJSON["anchors"] as? [[String: Any]] else {
    print("Cannot load mesh index"); exit(1)
}

var allPos: [SIMD3<Float>] = []
var allNrm: [SIMD3<Float>] = []

for anchor in anchors {
    guard let file = anchor["file"] as? String else { continue }
    guard let mesh = loadMesh(meshDir.appendingPathComponent(file)) else { continue }
    allPos.append(contentsOf: mesh.positions)
    allNrm.append(contentsOf: mesh.normals)
}

print("Loaded \(anchors.count) anchors: \(allPos.count) vertices")

// MARK: - Step 1: Find floor level

var floorCandidates: [Float] = []
for i in 0..<allPos.count where allNrm[i].y > 0.8 {
    floorCandidates.append(allPos[i].y)
}
floorCandidates.sort()
let floorY: Float = floorCandidates.count > 100 ? floorCandidates[floorCandidates.count / 10] : (floorCandidates.first ?? 0)
print("Floor: \(String(format: "%.3f", floorY))m")

// MARK: - Step 2: Extract wall points (horizontal slice at 0.8-1.2m)

struct WallPoint {
    let x: Float
    let z: Float
    let nx: Float  // normal X
    let nz: Float  // normal Z
}

var wallPoints: [WallPoint] = []
for i in 0..<allPos.count {
    guard abs(allNrm[i].y) < 0.3 else { continue }  // vertical surface
    let h = allPos[i].y - floorY
    guard h >= 0.8 && h <= 1.2 else { continue }  // slice at ~1m
    wallPoints.append(WallPoint(x: allPos[i].x, z: allPos[i].z, nx: allNrm[i].x, nz: allNrm[i].z))
}
print("Wall points in slice: \(wallPoints.count)")

// Also collect ALL points for the mesh shadow (floor-level plan view)
struct FloorPoint { let x: Float; let z: Float }
var allFloorPoints: [FloorPoint] = []
for i in 0..<allPos.count {
    let h = allPos[i].y - floorY
    guard h >= -0.1 && h <= 2.0 else { continue }
    allFloorPoints.append(FloorPoint(x: allPos[i].x, z: allPos[i].z))
}

// MARK: - Step 3: Find dominant wall angle

let angleBins = 180
var angleHist = Array(repeating: 0, count: angleBins)
for wp in wallPoints {
    var a = atan2(wp.nz, wp.nx)
    if a < 0 { a += .pi }
    let bin = min(Int(a / .pi * Float(angleBins)), angleBins - 1)
    angleHist[bin] += 1
}
// Smooth
var smoothHist = Array(repeating: 0, count: angleBins)
for i in 0..<angleBins {
    var s = 0; for d in -3...3 { s += angleHist[(i + d + angleBins) % angleBins] }; smoothHist[i] = s
}
let peakBin = smoothHist.enumerated().max(by: { $0.element < $1.element })!.offset
let normalAngle = Float(peakBin) / Float(angleBins) * .pi
let wallAngle = normalAngle - .pi / 2  // dominant wall direction
print("Wall angle: \(String(format: "%.1f", wallAngle * 180 / .pi)) degrees")

// MARK: - Step 4: Rotate everything to align walls with axes

let cosR = cos(-wallAngle)
let sinR = sin(-wallAngle)

struct AlignedPoint {
    let x: Float  // rotated X
    let z: Float  // rotated Z
    let isXWall: Bool  // normal mostly in X direction (wall runs along Z)
    let isZWall: Bool  // normal mostly in Z direction (wall runs along X)
}

var aligned: [AlignedPoint] = []
for wp in wallPoints {
    let rx = wp.x * cosR - wp.z * sinR
    let rz = wp.x * sinR + wp.z * cosR
    let rnx = wp.nx * cosR - wp.nz * sinR
    let rnz = wp.nx * sinR + wp.nz * cosR
    let isX = abs(rnx) > 0.7  // wall normal in X → wall runs along Z axis
    let isZ = abs(rnz) > 0.7  // wall normal in Z → wall runs along X axis
    aligned.append(AlignedPoint(x: rx, z: rz, isXWall: isX, isZWall: isZ))
}

// Rotate all floor points too
var alignedFloor: [FloorPoint] = []
for fp in allFloorPoints {
    let rx = fp.x * cosR - fp.z * sinR
    let rz = fp.x * sinR + fp.z * cosR
    alignedFloor.append(FloorPoint(x: rx, z: rz))
}

// MARK: - Step 5: Find wall positions using 1D density peaks

// For X-normal walls: project onto X axis, find peaks
// For Z-normal walls: project onto Z axis, find peaks

let resolution: Float = 0.02  // 2cm bins

func findWallPositions(points: [Float], minSupport: Int) -> [(position: Float, thickness: Float)] {
    guard !points.isEmpty else { return [] }
    let minVal = points.min()!
    let maxVal = points.max()!
    let range = maxVal - minVal
    let binCount = Int(range / resolution) + 1
    guard binCount > 0 && binCount < 100000 else { return [] }

    var histogram = Array(repeating: 0, count: binCount)
    for p in points {
        let bin = min(Int((p - minVal) / resolution), binCount - 1)
        histogram[bin] += 1
    }

    // Smooth
    var smooth = Array(repeating: 0, count: binCount)
    for i in 0..<binCount {
        var s = 0
        for d in -2...2 { s += histogram[max(0, min(binCount-1, i+d))] }
        smooth[i] = s
    }

    // Find peaks above threshold
    let threshold = minSupport
    var peaks: [(position: Float, thickness: Float)] = []
    var i = 0
    while i < binCount {
        if smooth[i] >= threshold {
            // Found start of a peak — walk to find extent
            var peakStart = i
            var peakEnd = i
            var maxVal = smooth[i]
            var maxBin = i
            while peakEnd < binCount - 1 && smooth[peakEnd + 1] >= threshold / 2 {
                peakEnd += 1
                if smooth[peakEnd] > maxVal { maxVal = smooth[peakEnd]; maxBin = peakEnd }
            }
            let peakPos = minVal + Float(maxBin) * resolution
            let thickness = max(Float(peakEnd - peakStart) * resolution, 0.06)
            // Don't add if too close to previous peak
            if let last = peaks.last, abs(last.position - peakPos) < 0.15 {
                // Merge — keep the stronger one
            } else {
                peaks.append((position: peakPos, thickness: min(thickness, 0.25)))
            }
            i = peakEnd + 1
        } else {
            i += 1
        }
    }

    return peaks
}

// X-normal walls (walls running along Z axis) — find X positions
let xWallPoints = aligned.filter { $0.isXWall }.map { $0.x }
let xWalls = findWallPositions(points: xWallPoints, minSupport: max(20, wallPoints.count / 200))
print("X-aligned walls: \(xWalls.count)")
for w in xWalls { print("  x=\(String(format: "%.3f", w.position))m, t=\(Int(w.thickness * 1000))mm") }

// Z-normal walls (walls running along X axis) — find Z positions
let zWallPoints = aligned.filter { $0.isZWall }.map { $0.z }
let zWalls = findWallPositions(points: zWallPoints, minSupport: max(20, wallPoints.count / 200))
print("Z-aligned walls: \(zWalls.count)")
for w in zWalls { print("  z=\(String(format: "%.3f", w.position))m, t=\(Int(w.thickness * 1000))mm") }

// MARK: - Step 6: Find wall extents (how far each wall line runs)

struct WallLine {
    let position: Float  // X or Z coordinate of wall center
    let thickness: Float
    let start: Float     // start along the wall (min Z for X-walls, min X for Z-walls)
    let end: Float       // end along the wall
    let isXWall: Bool    // true = wall at X=position running along Z
}

func findWallExtent(wallPos: Float, isXWall: Bool, points: [AlignedPoint]) -> (start: Float, end: Float) {
    let nearPoints: [Float]
    if isXWall {
        nearPoints = points.filter { $0.isXWall && abs($0.x - wallPos) < 0.1 }.map { $0.z }
    } else {
        nearPoints = points.filter { $0.isZWall && abs($0.z - wallPos) < 0.1 }.map { $0.x }
    }
    guard let mn = nearPoints.min(), let mx = nearPoints.max() else { return (0, 0) }
    return (mn, mx)
}

var wallLines: [WallLine] = []

for w in xWalls {
    let ext = findWallExtent(wallPos: w.position, isXWall: true, points: aligned)
    if ext.end - ext.start > 0.3 {
        wallLines.append(WallLine(position: w.position, thickness: w.thickness,
                                  start: ext.start, end: ext.end, isXWall: true))
    }
}

for w in zWalls {
    let ext = findWallExtent(wallPos: w.position, isXWall: false, points: aligned)
    if ext.end - ext.start > 0.3 {
        wallLines.append(WallLine(position: w.position, thickness: w.thickness,
                                  start: ext.start, end: ext.end, isXWall: false))
    }
}

print("Total wall lines: \(wallLines.count)")

// MARK: - Step 7: Detect openings in walls

struct Opening {
    let wallIndex: Int
    let position: Float  // along the wall
    let width: Float
    let kind: String     // "door", "window", "sliding", "opening"
}

var openings: [Opening] = []

for (wi, wall) in wallLines.enumerated() {
    let wallLen = wall.end - wall.start
    guard wallLen > 0.8 else { continue }

    let segSize: Float = 0.06
    let segCount = Int(wallLen / segSize)
    guard segCount > 3 else { continue }

    // Count points per segment at two height bands
    var densityMid = Array(repeating: 0, count: segCount)  // 0.5-2.0m
    var densityLow = Array(repeating: 0, count: segCount)  // 0-0.5m

    for i in 0..<allPos.count {
        guard abs(allNrm[i].y) < 0.4 else { continue }
        let h = allPos[i].y - floorY
        guard h >= 0 && h <= 2.0 else { continue }

        // Rotate to aligned space
        let rx = allPos[i].x * cosR - allPos[i].z * sinR
        let rz = allPos[i].x * sinR + allPos[i].z * cosR

        let perpDist: Float
        let alongPos: Float

        if wall.isXWall {
            perpDist = abs(rx - wall.position)
            alongPos = rz
        } else {
            perpDist = abs(rz - wall.position)
            alongPos = rx
        }

        guard perpDist < 0.12 else { continue }

        let seg = Int((alongPos - wall.start) / segSize)
        guard seg >= 0 && seg < segCount else { continue }

        if h >= 0.5 && h <= 2.0 { densityMid[seg] += 1 }
        else if h >= 0 && h < 0.5 { densityLow[seg] += 1 }
    }

    let avgDensity = densityMid.reduce(0, +) / max(1, segCount)
    let gapThreshold = max(3, avgDensity / 3)

    var inGap = false, gapStart = 0
    for seg in 0...segCount {
        let sparse = seg < segCount ? densityMid[seg] < gapThreshold : false
        if sparse && !inGap { inGap = true; gapStart = seg }
        else if !sparse && inGap {
            inGap = false
            let gapWidth = Float(seg - gapStart) * segSize
            if gapWidth >= 0.5 && gapWidth <= 4.0 {
                let center = wall.start + (Float(gapStart) + Float(seg)) / 2 * segSize

                let lowCount = (gapStart..<min(seg, segCount)).map { densityLow[$0] }.reduce(0, +)
                let hasWallBelow = lowCount > (seg - gapStart) * 2

                let kind: String
                if hasWallBelow { kind = "window" }
                else if gapWidth >= 1.5 { kind = "sliding" }
                else if gapWidth >= 1.1 { kind = "double" }
                else { kind = "door" }

                openings.append(Opening(wallIndex: wi, position: center, width: gapWidth, kind: kind))
            }
        }
    }
}

print("Openings: \(openings.count)")
for o in openings {
    let w = wallLines[o.wallIndex]
    print("  \(o.kind): \(Int(o.width * 1000))mm on \(w.isXWall ? "X" : "Z")-wall at \(String(format: "%.2f", w.position))")
}

// MARK: - Step 8: Build occupancy grid for mesh shadow

let gridRes: Float = 0.05  // 5cm cells
let allMinX = alignedFloor.map(\.x).min()! - 0.5
let allMaxX = alignedFloor.map(\.x).max()! + 0.5
let allMinZ = alignedFloor.map(\.z).min()! - 0.5
let allMaxZ = alignedFloor.map(\.z).max()! + 0.5
let gridW = Int((allMaxX - allMinX) / gridRes) + 1
let gridH = Int((allMaxZ - allMinZ) / gridRes) + 1
var grid = Array(repeating: 0, count: gridW * gridH)

for fp in alignedFloor {
    let gx = Int((fp.x - allMinX) / gridRes)
    let gz = Int((fp.z - allMinZ) / gridRes)
    guard gx >= 0 && gx < gridW && gz >= 0 && gz < gridH else { continue }
    grid[gz * gridW + gx] += 1
}

// MARK: - Step 9: Calculate dimensions

let wallMinX = wallLines.filter { $0.isXWall }.map { $0.position }.min() ?? allMinX
let wallMaxX = wallLines.filter { $0.isXWall }.map { $0.position }.max() ?? allMaxX
let wallMinZ = wallLines.filter { !$0.isXWall }.map { $0.position }.min() ?? allMinZ
let wallMaxZ = wallLines.filter { !$0.isXWall }.map { $0.position }.max() ?? allMaxZ

let overallWidth = wallMaxX - wallMinX
let overallDepth = wallMaxZ - wallMinZ
let area = overallWidth * overallDepth

print("Dimensions: \(Int(overallWidth * 1000))mm x \(Int(overallDepth * 1000))mm = \(String(format: "%.1f", area)) m²")

// MARK: - Step 10: Render SVG

let margin: Float = 80
let scale: Float = 100  // pixels per metre
let svgW = (allMaxX - allMinX) * scale + margin * 2
let svgH = (allMaxZ - allMinZ) * scale + margin * 2

func tx(_ x: Float) -> Float { (x - allMinX) * scale + margin }
func tz(_ z: Float) -> Float { (z - allMinZ) * scale + margin }

var svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="\(Int(svgW))" height="\(Int(svgH))"
     viewBox="0 0 \(Int(svgW)) \(Int(svgH))" style="background:#1a1a2e">
<defs>
  <style>
    text { font-family: -apple-system, 'SF Pro', 'Helvetica Neue', sans-serif; }
  </style>
</defs>

<!-- Title -->
<text x="\(Int(svgW/2))" y="30" text-anchor="middle" fill="#FF9800" font-size="18" font-weight="bold">STUDIIO FLOOR PLAN</text>
<text x="\(Int(svgW/2))" y="50" text-anchor="middle" fill="#999" font-size="12">\(Int(overallWidth * 1000))mm x \(Int(overallDepth * 1000))mm — \(String(format: "%.1f", area)) m²</text>

"""

// Mesh shadow (occupancy grid as background)
svg += "\n<!-- Mesh shadow -->\n"
let maxDensity = grid.max() ?? 1
for gz in 0..<gridH {
    for gx in 0..<gridW {
        let density = grid[gz * gridW + gx]
        if density > 0 {
            let opacity = min(Float(density) / Float(max(maxDensity / 3, 1)), 1.0) * 0.3
            let px = tx(allMinX + Float(gx) * gridRes)
            let pz = tz(allMinZ + Float(gz) * gridRes)
            let cellPx = gridRes * scale
            svg += "<rect x=\"\(String(format: "%.1f", px))\" y=\"\(String(format: "%.1f", pz))\" "
            svg += "width=\"\(String(format: "%.1f", cellPx))\" height=\"\(String(format: "%.1f", cellPx))\" "
            svg += "fill=\"#8899aa\" opacity=\"\(String(format: "%.2f", opacity))\"/>\n"
        }
    }
}

// Wall lines (thick orange lines with inner face)
svg += "\n<!-- Walls -->\n"
for wall in wallLines {
    let t = max(wall.thickness * scale, 3)

    if wall.isXWall {
        // Wall at X=position, running from start..end along Z
        let x = tx(wall.position)
        let y1 = tz(wall.start)
        let y2 = tz(wall.end)
        // Outer wall (thick)
        svg += "<line x1=\"\(String(format: "%.1f", x))\" y1=\"\(String(format: "%.1f", y1))\" "
        svg += "x2=\"\(String(format: "%.1f", x))\" y2=\"\(String(format: "%.1f", y2))\" "
        svg += "stroke=\"#FF6D00\" stroke-width=\"\(String(format: "%.1f", t))\" stroke-linecap=\"round\"/>\n"
        // Inner edge lines
        svg += "<line x1=\"\(String(format: "%.1f", x - t/2))\" y1=\"\(String(format: "%.1f", y1))\" "
        svg += "x2=\"\(String(format: "%.1f", x - t/2))\" y2=\"\(String(format: "%.1f", y2))\" "
        svg += "stroke=\"#FF9800\" stroke-width=\"1\" opacity=\"0.6\"/>\n"
        svg += "<line x1=\"\(String(format: "%.1f", x + t/2))\" y1=\"\(String(format: "%.1f", y1))\" "
        svg += "x2=\"\(String(format: "%.1f", x + t/2))\" y2=\"\(String(format: "%.1f", y2))\" "
        svg += "stroke=\"#FF9800\" stroke-width=\"1\" opacity=\"0.6\"/>\n"
    } else {
        // Wall at Z=position, running from start..end along X
        let y = tz(wall.position)
        let x1 = tx(wall.start)
        let x2 = tx(wall.end)
        svg += "<line x1=\"\(String(format: "%.1f", x1))\" y1=\"\(String(format: "%.1f", y))\" "
        svg += "x2=\"\(String(format: "%.1f", x2))\" y2=\"\(String(format: "%.1f", y))\" "
        svg += "stroke=\"#FF6D00\" stroke-width=\"\(String(format: "%.1f", t))\" stroke-linecap=\"round\"/>\n"
        svg += "<line x1=\"\(String(format: "%.1f", x1))\" y1=\"\(String(format: "%.1f", y - t/2))\" "
        svg += "x2=\"\(String(format: "%.1f", x2))\" y2=\"\(String(format: "%.1f", y - t/2))\" "
        svg += "stroke=\"#FF9800\" stroke-width=\"1\" opacity=\"0.6\"/>\n"
        svg += "<line x1=\"\(String(format: "%.1f", x1))\" y1=\"\(String(format: "%.1f", y + t/2))\" "
        svg += "x2=\"\(String(format: "%.1f", x2))\" y2=\"\(String(format: "%.1f", y + t/2))\" "
        svg += "stroke=\"#FF9800\" stroke-width=\"1\" opacity=\"0.6\"/>\n"
    }
}

// Openings
svg += "\n<!-- Openings -->\n"
for o in openings {
    let wall = wallLines[o.wallIndex]
    let halfW = o.width * scale / 2

    if wall.isXWall {
        let x = tx(wall.position)
        let y = tz(o.position)

        if o.kind == "door" || o.kind == "double" {
            // Door arc
            let r = halfW
            // Clear the wall behind
            svg += "<line x1=\"\(String(format: "%.1f", x))\" y1=\"\(String(format: "%.1f", y - halfW))\" "
            svg += "x2=\"\(String(format: "%.1f", x))\" y2=\"\(String(format: "%.1f", y + halfW))\" "
            svg += "stroke=\"#1a1a2e\" stroke-width=\"\(String(format: "%.1f", max(wall.thickness * scale, 3) + 2))\"/>\n"
            // Arc
            svg += "<path d=\"M \(String(format: "%.1f", x)) \(String(format: "%.1f", y - halfW)) "
            svg += "A \(String(format: "%.1f", r)) \(String(format: "%.1f", r)) 0 0 1 "
            svg += "\(String(format: "%.1f", x + r)) \(String(format: "%.1f", y))\" "
            svg += "fill=\"none\" stroke=\"#4CAF50\" stroke-width=\"1.5\" stroke-dasharray=\"3,2\"/>\n"
            // Label
            svg += "<text x=\"\(String(format: "%.1f", x - 15))\" y=\"\(String(format: "%.1f", y - halfW - 5))\" "
            svg += "fill=\"#4CAF50\" font-size=\"9\" text-anchor=\"middle\">D \(Int(o.width * 1000))mm</text>\n"

        } else if o.kind == "window" {
            // Window: parallel lines
            svg += "<line x1=\"\(String(format: "%.1f", x))\" y1=\"\(String(format: "%.1f", y - halfW))\" "
            svg += "x2=\"\(String(format: "%.1f", x))\" y2=\"\(String(format: "%.1f", y + halfW))\" "
            svg += "stroke=\"#1a1a2e\" stroke-width=\"\(String(format: "%.1f", max(wall.thickness * scale, 3) + 2))\"/>\n"
            let offset: Float = 3
            svg += "<line x1=\"\(String(format: "%.1f", x - offset))\" y1=\"\(String(format: "%.1f", y - halfW))\" "
            svg += "x2=\"\(String(format: "%.1f", x - offset))\" y2=\"\(String(format: "%.1f", y + halfW))\" "
            svg += "stroke=\"#29B6F6\" stroke-width=\"2\"/>\n"
            svg += "<line x1=\"\(String(format: "%.1f", x + offset))\" y1=\"\(String(format: "%.1f", y - halfW))\" "
            svg += "x2=\"\(String(format: "%.1f", x + offset))\" y2=\"\(String(format: "%.1f", y + halfW))\" "
            svg += "stroke=\"#29B6F6\" stroke-width=\"2\"/>\n"
            svg += "<text x=\"\(String(format: "%.1f", x - 15))\" y=\"\(String(format: "%.1f", y))\" "
            svg += "fill=\"#29B6F6\" font-size=\"9\" text-anchor=\"end\">W \(Int(o.width * 1000))</text>\n"

        } else {
            // Sliding door: dashed line
            svg += "<line x1=\"\(String(format: "%.1f", x))\" y1=\"\(String(format: "%.1f", y - halfW))\" "
            svg += "x2=\"\(String(format: "%.1f", x))\" y2=\"\(String(format: "%.1f", y + halfW))\" "
            svg += "stroke=\"#1a1a2e\" stroke-width=\"\(String(format: "%.1f", max(wall.thickness * scale, 3) + 2))\"/>\n"
            svg += "<line x1=\"\(String(format: "%.1f", x))\" y1=\"\(String(format: "%.1f", y - halfW))\" "
            svg += "x2=\"\(String(format: "%.1f", x))\" y2=\"\(String(format: "%.1f", y + halfW))\" "
            svg += "stroke=\"#4CAF50\" stroke-width=\"2\" stroke-dasharray=\"6,3\"/>\n"
            svg += "<text x=\"\(String(format: "%.1f", x - 15))\" y=\"\(String(format: "%.1f", y - halfW - 5))\" "
            svg += "fill=\"#4CAF50\" font-size=\"9\" text-anchor=\"middle\">SD \(Int(o.width * 1000))</text>\n"
        }

    } else {
        // Z-wall openings (horizontal wall)
        let y = tz(wall.position)
        let x = tx(o.position)

        if o.kind == "door" || o.kind == "double" {
            svg += "<line x1=\"\(String(format: "%.1f", x - halfW))\" y1=\"\(String(format: "%.1f", y))\" "
            svg += "x2=\"\(String(format: "%.1f", x + halfW))\" y2=\"\(String(format: "%.1f", y))\" "
            svg += "stroke=\"#1a1a2e\" stroke-width=\"\(String(format: "%.1f", max(wall.thickness * scale, 3) + 2))\"/>\n"
            let r = halfW
            svg += "<path d=\"M \(String(format: "%.1f", x - halfW)) \(String(format: "%.1f", y)) "
            svg += "A \(String(format: "%.1f", r)) \(String(format: "%.1f", r)) 0 0 1 "
            svg += "\(String(format: "%.1f", x)) \(String(format: "%.1f", y - r))\" "
            svg += "fill=\"none\" stroke=\"#4CAF50\" stroke-width=\"1.5\" stroke-dasharray=\"3,2\"/>\n"
            svg += "<text x=\"\(String(format: "%.1f", x))\" y=\"\(String(format: "%.1f", y - halfW - 5))\" "
            svg += "fill=\"#4CAF50\" font-size=\"9\" text-anchor=\"middle\">D \(Int(o.width * 1000))mm</text>\n"

        } else if o.kind == "window" {
            svg += "<line x1=\"\(String(format: "%.1f", x - halfW))\" y1=\"\(String(format: "%.1f", y))\" "
            svg += "x2=\"\(String(format: "%.1f", x + halfW))\" y2=\"\(String(format: "%.1f", y))\" "
            svg += "stroke=\"#1a1a2e\" stroke-width=\"\(String(format: "%.1f", max(wall.thickness * scale, 3) + 2))\"/>\n"
            let offset: Float = 3
            svg += "<line x1=\"\(String(format: "%.1f", x - halfW))\" y1=\"\(String(format: "%.1f", y - offset))\" "
            svg += "x2=\"\(String(format: "%.1f", x + halfW))\" y2=\"\(String(format: "%.1f", y - offset))\" "
            svg += "stroke=\"#29B6F6\" stroke-width=\"2\"/>\n"
            svg += "<line x1=\"\(String(format: "%.1f", x - halfW))\" y1=\"\(String(format: "%.1f", y + offset))\" "
            svg += "x2=\"\(String(format: "%.1f", x + halfW))\" y2=\"\(String(format: "%.1f", y + offset))\" "
            svg += "stroke=\"#29B6F6\" stroke-width=\"2\"/>\n"
            svg += "<text x=\"\(String(format: "%.1f", x))\" y=\"\(String(format: "%.1f", y + 15))\" "
            svg += "fill=\"#29B6F6\" font-size=\"9\" text-anchor=\"middle\">W \(Int(o.width * 1000))</text>\n"

        } else {
            svg += "<line x1=\"\(String(format: "%.1f", x - halfW))\" y1=\"\(String(format: "%.1f", y))\" "
            svg += "x2=\"\(String(format: "%.1f", x + halfW))\" y2=\"\(String(format: "%.1f", y))\" "
            svg += "stroke=\"#1a1a2e\" stroke-width=\"\(String(format: "%.1f", max(wall.thickness * scale, 3) + 2))\"/>\n"
            svg += "<line x1=\"\(String(format: "%.1f", x - halfW))\" y1=\"\(String(format: "%.1f", y))\" "
            svg += "x2=\"\(String(format: "%.1f", x + halfW))\" y2=\"\(String(format: "%.1f", y))\" "
            svg += "stroke=\"#4CAF50\" stroke-width=\"2\" stroke-dasharray=\"6,3\"/>\n"
            svg += "<text x=\"\(String(format: "%.1f", x))\" y=\"\(String(format: "%.1f", y - 8))\" "
            svg += "fill=\"#4CAF50\" font-size=\"9\" text-anchor=\"middle\">SD \(Int(o.width * 1000))</text>\n"
        }
    }
}

// Overall dimension lines
svg += "\n<!-- Dimensions -->\n"
let dimY = tz(wallMaxZ) + 30
let dimX = tx(wallMaxX) + 30

// Width dimension (along top)
let x1d = tx(wallMinX), x2d = tx(wallMaxX)
let topY = tz(wallMinZ) - 20
svg += "<line x1=\"\(String(format: "%.1f", x1d))\" y1=\"\(String(format: "%.1f", topY))\" "
svg += "x2=\"\(String(format: "%.1f", x2d))\" y2=\"\(String(format: "%.1f", topY))\" "
svg += "stroke=\"#29B6F6\" stroke-width=\"1\"/>\n"
svg += "<line x1=\"\(String(format: "%.1f", x1d))\" y1=\"\(String(format: "%.1f", topY - 5))\" "
svg += "x2=\"\(String(format: "%.1f", x1d))\" y2=\"\(String(format: "%.1f", topY + 5))\" "
svg += "stroke=\"#29B6F6\" stroke-width=\"1\"/>\n"
svg += "<line x1=\"\(String(format: "%.1f", x2d))\" y1=\"\(String(format: "%.1f", topY - 5))\" "
svg += "x2=\"\(String(format: "%.1f", x2d))\" y2=\"\(String(format: "%.1f", topY + 5))\" "
svg += "stroke=\"#29B6F6\" stroke-width=\"1\"/>\n"
svg += "<text x=\"\(String(format: "%.1f", (x1d+x2d)/2))\" y=\"\(String(format: "%.1f", topY - 8))\" "
svg += "fill=\"#29B6F6\" font-size=\"12\" text-anchor=\"middle\" font-weight=\"bold\">\(Int(overallWidth * 1000))mm</text>\n"

// Depth dimension (along right)
let z1d = tz(wallMinZ), z2d = tz(wallMaxZ)
let rightX = tx(wallMaxX) + 25
svg += "<line x1=\"\(String(format: "%.1f", rightX))\" y1=\"\(String(format: "%.1f", z1d))\" "
svg += "x2=\"\(String(format: "%.1f", rightX))\" y2=\"\(String(format: "%.1f", z2d))\" "
svg += "stroke=\"#29B6F6\" stroke-width=\"1\"/>\n"
svg += "<line x1=\"\(String(format: "%.1f", rightX - 5))\" y1=\"\(String(format: "%.1f", z1d))\" "
svg += "x2=\"\(String(format: "%.1f", rightX + 5))\" y2=\"\(String(format: "%.1f", z1d))\" "
svg += "stroke=\"#29B6F6\" stroke-width=\"1\"/>\n"
svg += "<line x1=\"\(String(format: "%.1f", rightX - 5))\" y1=\"\(String(format: "%.1f", z2d))\" "
svg += "x2=\"\(String(format: "%.1f", rightX + 5))\" y2=\"\(String(format: "%.1f", z2d))\" "
svg += "stroke=\"#29B6F6\" stroke-width=\"1\"/>\n"
svg += "<text x=\"\(String(format: "%.1f", rightX + 12))\" y=\"\(String(format: "%.1f", (z1d+z2d)/2))\" "
svg += "fill=\"#29B6F6\" font-size=\"12\" text-anchor=\"middle\" font-weight=\"bold\" "
svg += "transform=\"rotate(90 \(String(format: "%.1f", rightX + 12)) \(String(format: "%.1f", (z1d+z2d)/2)))\">\(Int(overallDepth * 1000))mm</text>\n"

// Room dimension labels between opposing walls
svg += "\n<!-- Room dimensions -->\n"
// Find pairs of X-walls (opposing walls) and label the distance between them
let sortedXWalls = wallLines.filter { $0.isXWall }.sorted { $0.position < $1.position }
for i in 0..<sortedXWalls.count - 1 {
    let gap = sortedXWalls[i+1].position - sortedXWalls[i].position
    if gap > 0.5 && gap < 8.0 {
        let midX = tx((sortedXWalls[i].position + sortedXWalls[i+1].position) / 2)
        // Find Z center of overlap
        let overlapStart = max(sortedXWalls[i].start, sortedXWalls[i+1].start)
        let overlapEnd = min(sortedXWalls[i].end, sortedXWalls[i+1].end)
        if overlapEnd > overlapStart {
            let midZ = tz((overlapStart + overlapEnd) / 2)
            svg += "<text x=\"\(String(format: "%.1f", midX))\" y=\"\(String(format: "%.1f", midZ))\" "
            svg += "fill=\"#EF5350\" font-size=\"11\" text-anchor=\"middle\" font-weight=\"bold\">"
            svg += "\(Int(gap * 1000))</text>\n"
        }
    }
}

let sortedZWalls = wallLines.filter { !$0.isXWall }.sorted { $0.position < $1.position }
for i in 0..<sortedZWalls.count - 1 {
    let gap = sortedZWalls[i+1].position - sortedZWalls[i].position
    if gap > 0.5 && gap < 8.0 {
        let midZ = tz((sortedZWalls[i].position + sortedZWalls[i+1].position) / 2)
        let overlapStart = max(sortedZWalls[i].start, sortedZWalls[i+1].start)
        let overlapEnd = min(sortedZWalls[i].end, sortedZWalls[i+1].end)
        if overlapEnd > overlapStart {
            let midX = tx((overlapStart + overlapEnd) / 2)
            svg += "<text x=\"\(String(format: "%.1f", midX))\" y=\"\(String(format: "%.1f", midZ))\" "
            svg += "fill=\"#EF5350\" font-size=\"11\" text-anchor=\"middle\" font-weight=\"bold\">"
            svg += "\(Int(gap * 1000))</text>\n"
        }
    }
}

// Legend
let legY = svgH - 30
svg += "\n<!-- Legend -->\n"
svg += "<line x1=\"\(margin)\" y1=\"\(String(format: "%.0f", legY))\" x2=\"\(margin + 30)\" y2=\"\(String(format: "%.0f", legY))\" stroke=\"#FF6D00\" stroke-width=\"4\"/>\n"
svg += "<text x=\"\(margin + 35)\" y=\"\(String(format: "%.0f", legY + 4))\" fill=\"#ccc\" font-size=\"10\">Wall</text>\n"

svg += "<circle cx=\"\(margin + 90)\" cy=\"\(String(format: "%.0f", legY))\" r=\"8\" fill=\"none\" stroke=\"#4CAF50\" stroke-width=\"1.5\"/>\n"
svg += "<text x=\"\(margin + 103)\" y=\"\(String(format: "%.0f", legY + 4))\" fill=\"#ccc\" font-size=\"10\">Door</text>\n"

svg += "<line x1=\"\(margin + 145)\" y1=\"\(String(format: "%.0f", legY - 3))\" x2=\"\(margin + 165)\" y2=\"\(String(format: "%.0f", legY - 3))\" stroke=\"#29B6F6\" stroke-width=\"2\"/>\n"
svg += "<line x1=\"\(margin + 145)\" y1=\"\(String(format: "%.0f", legY + 3))\" x2=\"\(margin + 165)\" y2=\"\(String(format: "%.0f", legY + 3))\" stroke=\"#29B6F6\" stroke-width=\"2\"/>\n"
svg += "<text x=\"\(margin + 170)\" y=\"\(String(format: "%.0f", legY + 4))\" fill=\"#ccc\" font-size=\"10\">Window</text>\n"

svg += "<line x1=\"\(margin + 225)\" y1=\"\(String(format: "%.0f", legY))\" x2=\"\(margin + 250)\" y2=\"\(String(format: "%.0f", legY))\" stroke=\"#4CAF50\" stroke-width=\"2\" stroke-dasharray=\"5,3\"/>\n"
svg += "<text x=\"\(margin + 255)\" y=\"\(String(format: "%.0f", legY + 4))\" fill=\"#ccc\" font-size=\"10\">Sliding</text>\n"

// Scale bar
svg += "<line x1=\"\(margin)\" y1=\"\(String(format: "%.0f", legY + 15))\" x2=\"\(margin + scale)\" y2=\"\(String(format: "%.0f", legY + 15))\" stroke=\"#666\" stroke-width=\"2\"/>\n"
svg += "<text x=\"\(margin)\" y=\"\(String(format: "%.0f", legY + 28))\" fill=\"#666\" font-size=\"10\">1 metre</text>\n"

svg += "\n</svg>"

// Write
let outputURL = bundleURL.deletingLastPathComponent().appendingPathComponent("floorplan.svg")
try! svg.write(to: outputURL, atomically: true, encoding: .utf8)
print("\nFloor plan written to: \(outputURL.path)")
print("SVG size: \(svg.count / 1024)KB")
