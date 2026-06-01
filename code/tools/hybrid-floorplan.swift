#!/usr/bin/env swift
//  hybrid-floorplan.swift — Clean labeled 2D floor plan from LiDAR mesh + AI vision
//
//  Combines:
//  1. Geometry from LiDAR mesh (walls, openings, dimensions)
//  2. AI-identified room labels and fixtures from camera frame analysis
//  3. Camera path overlay showing scan coverage
//
//  Output: Professional SVG floor plan ready for editors to redraw

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

// MARK: - AI Room Analysis model

struct RoomLabel {
    let id: String
    let label: String
    let centroidX: Float
    let centroidZ: Float
    let features: [String]
    let flooring: String
    let confidence: Float
}

struct FixtureLabel {
    let type: String
    let x: Float
    let z: Float
    let label: String
}

func loadRoomAnalysis(_ url: URL) -> (rooms: [RoomLabel], fixtures: [FixtureLabel]) {
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return ([], [])
    }

    var rooms: [RoomLabel] = []
    if let roomsArr = json["rooms"] as? [[String: Any]] {
        for r in roomsArr {
            let centroid = r["centroid"] as? [String: Any] ?? [:]
            rooms.append(RoomLabel(
                id: r["id"] as? String ?? "",
                label: r["label"] as? String ?? "",
                centroidX: Float(centroid["x"] as? Double ?? 0),
                centroidZ: Float(centroid["z"] as? Double ?? 0),
                features: r["features"] as? [String] ?? [],
                flooring: r["flooring"] as? String ?? "",
                confidence: Float(r["confidence"] as? Double ?? 0)
            ))
        }
    }

    var fixtures: [FixtureLabel] = []
    if let fixArr = json["fixtures"] as? [[String: Any]] {
        for f in fixArr {
            let pos = f["position"] as? [String: Any] ?? [:]
            fixtures.append(FixtureLabel(
                type: f["type"] as? String ?? "",
                x: Float(pos["x"] as? Double ?? 0),
                z: Float(pos["z"] as? Double ?? 0),
                label: f["label"] as? String ?? ""
            ))
        }
    }

    return (rooms, fixtures)
}

// MARK: - Camera path loading

struct CameraFrame {
    let x: Float
    let z: Float
    let index: Int
}

func loadCameraPath(_ url: URL) -> [CameraFrame] {
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let frames = json["frames"] as? [[String: Any]] else { return [] }

    return frames.enumerated().compactMap { (i, f) in
        guard let transform = f["transform"] as? [Double] else { return nil }
        return CameraFrame(x: Float(transform[12]), z: Float(transform[14]), index: i)
    }
}

// MARK: - Main

guard CommandLine.arguments.count >= 2 else {
    print("Usage: hybrid-floorplan <path-to.studiio>"); exit(1)
}

let bundleURL = URL(fileURLWithPath: CommandLine.arguments[1])
let meshDir = bundleURL.appendingPathComponent("mesh")
let framesDir = bundleURL.appendingPathComponent("frames")

guard let indexData = try? Data(contentsOf: meshDir.appendingPathComponent("index.json")),
      let indexJSON = try? JSONSerialization.jsonObject(with: indexData) as? [String: Any],
      let anchors = indexJSON["anchors"] as? [[String: Any]] else {
    print("Cannot load mesh index"); exit(1)
}

// Load mesh
var allPos: [SIMD3<Float>] = []
var allNrm: [SIMD3<Float>] = []
for anchor in anchors {
    guard let file = anchor["file"] as? String else { continue }
    guard let mesh = loadMesh(meshDir.appendingPathComponent(file)) else { continue }
    allPos.append(contentsOf: mesh.positions)
    allNrm.append(contentsOf: mesh.normals)
}
print("Loaded \(anchors.count) anchors: \(allPos.count) vertices")

// Load AI room analysis
let analysisURL = bundleURL.appendingPathComponent("ai-room-analysis.json")
let (roomLabels, fixtureLabels) = loadRoomAnalysis(analysisURL)
print("AI rooms: \(roomLabels.count), fixtures: \(fixtureLabels.count)")

// Load camera path
let cameraPath = loadCameraPath(framesDir.appendingPathComponent("index.json"))
print("Camera frames: \(cameraPath.count)")

// MARK: - Step 1: Find floor level

var floorCandidates: [Float] = []
for i in 0..<allPos.count where allNrm[i].y > 0.8 {
    floorCandidates.append(allPos[i].y)
}
floorCandidates.sort()
let floorY: Float = floorCandidates.count > 100 ? floorCandidates[floorCandidates.count / 10] : (floorCandidates.first ?? 0)
print("Floor: \(String(format: "%.3f", floorY))m")

// MARK: - Step 2: Extract wall points (horizontal slice)

struct WallPoint {
    let x: Float; let z: Float; let nx: Float; let nz: Float
}

var wallPoints: [WallPoint] = []
for i in 0..<allPos.count {
    guard abs(allNrm[i].y) < 0.3 else { continue }
    let h = allPos[i].y - floorY
    guard h >= 0.8 && h <= 1.2 else { continue }
    wallPoints.append(WallPoint(x: allPos[i].x, z: allPos[i].z, nx: allNrm[i].x, nz: allNrm[i].z))
}
print("Wall points in slice: \(wallPoints.count)")

// Collect all points for mesh shadow
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
var smoothHist = Array(repeating: 0, count: angleBins)
for i in 0..<angleBins {
    var s = 0; for d in -3...3 { s += angleHist[(i + d + angleBins) % angleBins] }; smoothHist[i] = s
}
let peakBin = smoothHist.enumerated().max(by: { $0.element < $1.element })!.offset
let normalAngle = Float(peakBin) / Float(angleBins) * .pi
let wallAngle = normalAngle - .pi / 2
print("Wall angle: \(String(format: "%.1f", wallAngle * 180 / .pi)) degrees")

// MARK: - Step 4: Rotate to align walls with axes

let cosR = cos(-wallAngle)
let sinR = sin(-wallAngle)

struct AlignedPoint {
    let x: Float; let z: Float; let isXWall: Bool; let isZWall: Bool
}

var aligned: [AlignedPoint] = []
for wp in wallPoints {
    let rx = wp.x * cosR - wp.z * sinR
    let rz = wp.x * sinR + wp.z * cosR
    let rnx = wp.nx * cosR - wp.nz * sinR
    let rnz = wp.nx * sinR + wp.nz * cosR
    aligned.append(AlignedPoint(x: rx, z: rz, isXWall: abs(rnx) > 0.7, isZWall: abs(rnz) > 0.7))
}

var alignedFloor: [FloorPoint] = []
for fp in allFloorPoints {
    let rx = fp.x * cosR - fp.z * sinR
    let rz = fp.x * sinR + fp.z * cosR
    alignedFloor.append(FloorPoint(x: rx, z: rz))
}

// Rotate room labels
struct AlignedRoom {
    let label: String; let x: Float; let z: Float
    let features: [String]; let flooring: String; let confidence: Float
}
var alignedRooms: [AlignedRoom] = []
for r in roomLabels {
    let rx = r.centroidX * cosR - r.centroidZ * sinR
    let rz = r.centroidX * sinR + r.centroidZ * cosR
    alignedRooms.append(AlignedRoom(label: r.label, x: rx, z: rz,
                                     features: r.features, flooring: r.flooring, confidence: r.confidence))
}

// Rotate fixtures
struct AlignedFixture {
    let type: String; let x: Float; let z: Float; let label: String
}
var alignedFixtures: [AlignedFixture] = []
for f in fixtureLabels {
    let rx = f.x * cosR - f.z * sinR
    let rz = f.x * sinR + f.z * cosR
    alignedFixtures.append(AlignedFixture(type: f.type, x: rx, z: rz, label: f.label))
}

// Rotate camera path
struct AlignedCamera { let x: Float; let z: Float; let index: Int }
var alignedCameras: [AlignedCamera] = []
for c in cameraPath {
    let rx = c.x * cosR - c.z * sinR
    let rz = c.x * sinR + c.z * cosR
    alignedCameras.append(AlignedCamera(x: rx, z: rz, index: c.index))
}

// MARK: - Step 5: Find wall positions

let resolution: Float = 0.02

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

    var smooth = Array(repeating: 0, count: binCount)
    for i in 0..<binCount {
        var s = 0
        for d in -2...2 { s += histogram[max(0, min(binCount-1, i+d))] }
        smooth[i] = s
    }

    let threshold = minSupport
    var peaks: [(position: Float, thickness: Float)] = []
    var i = 0
    while i < binCount {
        if smooth[i] >= threshold {
            var peakEnd = i
            var maxVal = smooth[i]
            var maxBin = i
            while peakEnd < binCount - 1 && smooth[peakEnd + 1] >= threshold / 2 {
                peakEnd += 1
                if smooth[peakEnd] > maxVal { maxVal = smooth[peakEnd]; maxBin = peakEnd }
            }
            let peakPos = minVal + Float(maxBin) * resolution
            let thickness = max(Float(peakEnd - i) * resolution, 0.06)
            if let last = peaks.last, abs(last.position - peakPos) < 0.15 {
                // Merge
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

let xWallPoints = aligned.filter { $0.isXWall }.map { $0.x }
let xWalls = findWallPositions(points: xWallPoints, minSupport: max(20, wallPoints.count / 200))
let zWallPoints = aligned.filter { $0.isZWall }.map { $0.z }
let zWalls = findWallPositions(points: zWallPoints, minSupport: max(20, wallPoints.count / 200))

print("X-aligned walls: \(xWalls.count), Z-aligned walls: \(zWalls.count)")

// MARK: - Step 6: Wall extents

struct WallLine {
    let position: Float; let thickness: Float
    let start: Float; let end: Float; let isXWall: Bool
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
    if ext.end - ext.start > 0.5 {  // minimum 50cm wall segment
        wallLines.append(WallLine(position: w.position, thickness: w.thickness,
                                  start: ext.start, end: ext.end, isXWall: true))
    }
}
for w in zWalls {
    let ext = findWallExtent(wallPos: w.position, isXWall: false, points: aligned)
    if ext.end - ext.start > 0.5 {
        wallLines.append(WallLine(position: w.position, thickness: w.thickness,
                                  start: ext.start, end: ext.end, isXWall: false))
    }
}
print("Total wall lines: \(wallLines.count)")

// MARK: - Step 7: Detect openings

struct Opening {
    let wallIndex: Int; let position: Float; let width: Float; let kind: String
}

var openings: [Opening] = []
for (wi, wall) in wallLines.enumerated() {
    let wallLen = wall.end - wall.start
    guard wallLen > 0.8 else { continue }

    let segSize: Float = 0.08  // slightly larger segments for cleaner detection
    let segCount = Int(wallLen / segSize)
    guard segCount > 3 else { continue }

    var densityMid = Array(repeating: 0, count: segCount)
    var densityLow = Array(repeating: 0, count: segCount)

    for i in 0..<allPos.count {
        guard abs(allNrm[i].y) < 0.4 else { continue }
        let h = allPos[i].y - floorY
        guard h >= 0 && h <= 2.0 else { continue }

        let rx = allPos[i].x * cosR - allPos[i].z * sinR
        let rz = allPos[i].x * sinR + allPos[i].z * cosR

        let perpDist: Float
        let alongPos: Float
        if wall.isXWall {
            perpDist = abs(rx - wall.position); alongPos = rz
        } else {
            perpDist = abs(rz - wall.position); alongPos = rx
        }
        guard perpDist < 0.15 else { continue }  // slightly wider capture

        let seg = Int((alongPos - wall.start) / segSize)
        guard seg >= 0 && seg < segCount else { continue }

        if h >= 0.5 && h <= 2.0 { densityMid[seg] += 1 }
        else if h >= 0 && h < 0.5 { densityLow[seg] += 1 }
    }

    let avgDensity = densityMid.reduce(0, +) / max(1, segCount)
    let gapThreshold = max(5, avgDensity / 4)  // stricter threshold

    var inGap = false, gapStart = 0
    for seg in 0...segCount {
        let sparse = seg < segCount ? densityMid[seg] < gapThreshold : false
        if sparse && !inGap { inGap = true; gapStart = seg }
        else if !sparse && inGap {
            inGap = false
            let gapWidth = Float(seg - gapStart) * segSize
            if gapWidth >= 0.6 && gapWidth <= 3.5 {  // tighter range
                let center = wall.start + (Float(gapStart) + Float(seg)) / 2 * segSize

                // Deduplicate: skip if another opening is within 0.5m on same wall
                let isDuplicate = openings.contains { o in
                    o.wallIndex == wi && abs(o.position - center) < 0.5
                }
                guard !isDuplicate else { continue }

                // Skip openings near wall ends (likely scan boundary, not real opening)
                let distFromStart = center - wall.start
                let distFromEnd = wall.end - center
                guard distFromStart > 0.3 && distFromEnd > 0.3 else { continue }

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
print("Openings: \(openings.count) (deduplicated)")

// MARK: - Step 8: Occupancy grid for mesh shadow

let gridRes: Float = 0.08  // 8cm cells — balance between detail and SVG size
// Include room label positions in bounds so nothing gets clipped
let roomXs = alignedRooms.map { $0.x }
let roomZs = alignedRooms.map { $0.z }
// Also include camera positions in bounds (camera goes into rooms mesh might miss)
let camXs = alignedCameras.map { $0.x }
let camZs = alignedCameras.map { $0.z }
let allMinX = min(alignedFloor.map(\.x).min()!, min((roomXs.min() ?? 0), (camXs.min() ?? 0))) - 1.5
let allMaxX = max(alignedFloor.map(\.x).max()!, max((roomXs.max() ?? 0), (camXs.max() ?? 0))) + 2.0
let allMinZ = min(alignedFloor.map(\.z).min()!, min((roomZs.min() ?? 0), (camZs.min() ?? 0))) - 1.0
let allMaxZ = max(alignedFloor.map(\.z).max()!, max((roomZs.max() ?? 0), (camZs.max() ?? 0))) + 1.5
let gridW = Int((allMaxX - allMinX) / gridRes) + 1
let gridH = Int((allMaxZ - allMinZ) / gridRes) + 1
var grid = Array(repeating: 0, count: gridW * gridH)

for fp in alignedFloor {
    let gx = Int((fp.x - allMinX) / gridRes)
    let gz = Int((fp.z - allMinZ) / gridRes)
    guard gx >= 0 && gx < gridW && gz >= 0 && gz < gridH else { continue }
    grid[gz * gridW + gx] += 1
}

// MARK: - Step 9: Dimensions

let wallMinX = wallLines.filter { $0.isXWall }.map { $0.position }.min() ?? allMinX
let wallMaxX = wallLines.filter { $0.isXWall }.map { $0.position }.max() ?? allMaxX
let wallMinZ = wallLines.filter { !$0.isXWall }.map { $0.position }.min() ?? allMinZ
let wallMaxZ = wallLines.filter { !$0.isXWall }.map { $0.position }.max() ?? allMaxZ

let overallWidth = wallMaxX - wallMinX
let overallDepth = wallMaxZ - wallMinZ
let area = overallWidth * overallDepth
print("Dimensions: \(Int(overallWidth * 1000))mm x \(Int(overallDepth * 1000))mm = \(String(format: "%.1f", area)) m²")

// MARK: - Step 10: Render SVG

let margin: Float = 100
let scale: Float = 120  // slightly larger for clarity
let svgW = (allMaxX - allMinX) * scale + margin * 2
let svgH = (allMaxZ - allMinZ) * scale + margin * 2 + 60  // extra for footer

func tx(_ x: Float) -> Float { (x - allMinX) * scale + margin }
func tz(_ z: Float) -> Float { (z - allMinZ) * scale + margin }
func fmt(_ v: Float) -> String { String(format: "%.1f", v) }

var svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="\(Int(svgW))" height="\(Int(svgH))"
     viewBox="0 0 \(Int(svgW)) \(Int(svgH))" style="background:#111827">
<defs>
  <style>
    text { font-family: 'SF Pro Display', -apple-system, 'Helvetica Neue', sans-serif; }
    .room-label { font-size: 14px; font-weight: 700; fill: #F59E0B; text-anchor: middle; }
    .room-features { font-size: 8px; fill: #9CA3AF; text-anchor: middle; }
    .room-area { font-size: 10px; fill: #D1D5DB; text-anchor: middle; font-weight: 500; }
    .dim-label { font-size: 11px; fill: #60A5FA; text-anchor: middle; font-weight: 600; }
    .fixture-label { font-size: 7px; fill: #A78BFA; text-anchor: middle; font-weight: 600; }
    .title { font-size: 20px; font-weight: 800; fill: #F59E0B; text-anchor: middle; letter-spacing: 2px; }
    .subtitle { font-size: 11px; fill: #6B7280; text-anchor: middle; }
    .legend-text { font-size: 9px; fill: #9CA3AF; }
    .wall-dim { font-size: 9px; fill: #EF4444; text-anchor: middle; font-weight: 600; }
    .opening-label { font-size: 8px; text-anchor: middle; font-weight: 500; }
    .confidence { font-size: 7px; fill: #4B5563; text-anchor: middle; }
    .footer { font-size: 8px; fill: #4B5563; text-anchor: middle; }
  </style>
  <filter id="glow">
    <feGaussianBlur stdDeviation="2" result="blur"/>
    <feComposite in="SourceGraphic" in2="blur" operator="over"/>
  </filter>
</defs>

<!-- Title block -->
<text x="\(Int(svgW/2))" y="28" class="title">STUDIIO FLOOR PLAN</text>
<text x="\(Int(svgW/2))" y="44" class="subtitle">27 Perkins Close — AI-Enhanced Hybrid Analysis</text>
<text x="\(Int(svgW/2))" y="58" class="subtitle">\(Int(overallWidth * 1000))mm × \(Int(overallDepth * 1000))mm — \(String(format: "%.1f", area)) m² — \(anchors.count) mesh anchors, \(cameraPath.count) frames</text>

"""

// --- Mesh shadow ---
svg += "\n<!-- Mesh shadow -->\n"
let maxDensity = grid.max() ?? 1
for gz in stride(from: 0, to: gridH, by: 1) {
    for gx in stride(from: 0, to: gridW, by: 1) {
        let density = grid[gz * gridW + gx]
        if density > 2 {  // skip very sparse cells
            let opacity = min(Float(density) / Float(max(maxDensity / 4, 1)), 1.0) * 0.15
            let px = tx(allMinX + Float(gx) * gridRes)
            let pz = tz(allMinZ + Float(gz) * gridRes)
            let cellPx = gridRes * scale
            svg += "<rect x=\"\(fmt(px))\" y=\"\(fmt(pz))\" width=\"\(fmt(cellPx))\" height=\"\(fmt(cellPx))\" fill=\"#374151\" opacity=\"\(fmt(opacity))\"/>\n"
        }
    }
}

// --- Camera path (subtle dotted line showing scan coverage) ---
svg += "\n<!-- Camera path -->\n"
let pathSample = stride(from: 0, to: alignedCameras.count, by: 3).map { alignedCameras[$0] }
if pathSample.count > 1 {
    var pathD = "M \(fmt(tx(pathSample[0].x))) \(fmt(tz(pathSample[0].z)))"
    for c in pathSample.dropFirst() {
        pathD += " L \(fmt(tx(c.x))) \(fmt(tz(c.z)))"
    }
    svg += "<path d=\"\(pathD)\" fill=\"none\" stroke=\"#1E3A5F\" stroke-width=\"1\" stroke-dasharray=\"2,4\" opacity=\"0.5\"/>\n"
}

// --- Wall lines ---
svg += "\n<!-- Walls -->\n"
for wall in wallLines {
    let t = max(wall.thickness * scale, 4)

    if wall.isXWall {
        let x = tx(wall.position)
        let y1 = tz(wall.start), y2 = tz(wall.end)
        // Filled wall rectangle
        svg += "<rect x=\"\(fmt(x - t/2))\" y=\"\(fmt(min(y1,y2)))\" "
        svg += "width=\"\(fmt(t))\" height=\"\(fmt(abs(y2-y1)))\" "
        svg += "fill=\"#D97706\" opacity=\"0.8\" rx=\"1\"/>\n"
        // Edge lines
        svg += "<line x1=\"\(fmt(x - t/2))\" y1=\"\(fmt(y1))\" x2=\"\(fmt(x - t/2))\" y2=\"\(fmt(y2))\" stroke=\"#F59E0B\" stroke-width=\"1\"/>\n"
        svg += "<line x1=\"\(fmt(x + t/2))\" y1=\"\(fmt(y1))\" x2=\"\(fmt(x + t/2))\" y2=\"\(fmt(y2))\" stroke=\"#F59E0B\" stroke-width=\"1\"/>\n"
    } else {
        let y = tz(wall.position)
        let x1 = tx(wall.start), x2 = tx(wall.end)
        svg += "<rect x=\"\(fmt(min(x1,x2)))\" y=\"\(fmt(y - t/2))\" "
        svg += "width=\"\(fmt(abs(x2-x1)))\" height=\"\(fmt(t))\" "
        svg += "fill=\"#D97706\" opacity=\"0.8\" rx=\"1\"/>\n"
        svg += "<line x1=\"\(fmt(x1))\" y1=\"\(fmt(y - t/2))\" x2=\"\(fmt(x2))\" y2=\"\(fmt(y - t/2))\" stroke=\"#F59E0B\" stroke-width=\"1\"/>\n"
        svg += "<line x1=\"\(fmt(x1))\" y1=\"\(fmt(y + t/2))\" x2=\"\(fmt(x2))\" y2=\"\(fmt(y + t/2))\" stroke=\"#F59E0B\" stroke-width=\"1\"/>\n"
    }
}

// --- Openings ---
svg += "\n<!-- Openings -->\n"
for o in openings {
    let wall = wallLines[o.wallIndex]
    let halfW = o.width * scale / 2
    let wallT = max(wall.thickness * scale, 4)

    if wall.isXWall {
        let x = tx(wall.position)
        let y = tz(o.position)

        // Clear wall behind opening
        svg += "<rect x=\"\(fmt(x - wallT/2 - 1))\" y=\"\(fmt(y - halfW))\" "
        svg += "width=\"\(fmt(wallT + 2))\" height=\"\(fmt(halfW * 2))\" fill=\"#111827\"/>\n"

        switch o.kind {
        case "door", "double":
            let r = halfW
            svg += "<path d=\"M \(fmt(x)) \(fmt(y - halfW)) A \(fmt(r)) \(fmt(r)) 0 0 1 \(fmt(x + r)) \(fmt(y))\" "
            svg += "fill=\"none\" stroke=\"#34D399\" stroke-width=\"1.5\" stroke-dasharray=\"3,2\"/>\n"
            // Door line
            svg += "<line x1=\"\(fmt(x))\" y1=\"\(fmt(y - halfW))\" x2=\"\(fmt(x + r))\" y2=\"\(fmt(y))\" "
            svg += "stroke=\"#34D399\" stroke-width=\"1\" opacity=\"0.5\"/>\n"
            svg += "<text x=\"\(fmt(x - 12))\" y=\"\(fmt(y))\" class=\"opening-label\" fill=\"#34D399\">D\(Int(o.width * 1000))</text>\n"

        case "window":
            let off: Float = 3
            svg += "<line x1=\"\(fmt(x - off))\" y1=\"\(fmt(y - halfW))\" x2=\"\(fmt(x - off))\" y2=\"\(fmt(y + halfW))\" stroke=\"#38BDF8\" stroke-width=\"2\"/>\n"
            svg += "<line x1=\"\(fmt(x + off))\" y1=\"\(fmt(y - halfW))\" x2=\"\(fmt(x + off))\" y2=\"\(fmt(y + halfW))\" stroke=\"#38BDF8\" stroke-width=\"2\"/>\n"
            svg += "<text x=\"\(fmt(x - 14))\" y=\"\(fmt(y + 3))\" class=\"opening-label\" fill=\"#38BDF8\">W\(Int(o.width * 1000))</text>\n"

        default: // sliding
            svg += "<line x1=\"\(fmt(x))\" y1=\"\(fmt(y - halfW))\" x2=\"\(fmt(x))\" y2=\"\(fmt(y + halfW))\" "
            svg += "stroke=\"#34D399\" stroke-width=\"2\" stroke-dasharray=\"6,3\"/>\n"
            svg += "<text x=\"\(fmt(x - 14))\" y=\"\(fmt(y))\" class=\"opening-label\" fill=\"#34D399\">SD\(Int(o.width * 1000))</text>\n"
        }
    } else {
        let y = tz(wall.position)
        let x = tx(o.position)

        svg += "<rect x=\"\(fmt(x - halfW))\" y=\"\(fmt(y - wallT/2 - 1))\" "
        svg += "width=\"\(fmt(halfW * 2))\" height=\"\(fmt(wallT + 2))\" fill=\"#111827\"/>\n"

        switch o.kind {
        case "door", "double":
            let r = halfW
            svg += "<path d=\"M \(fmt(x - halfW)) \(fmt(y)) A \(fmt(r)) \(fmt(r)) 0 0 1 \(fmt(x)) \(fmt(y - r))\" "
            svg += "fill=\"none\" stroke=\"#34D399\" stroke-width=\"1.5\" stroke-dasharray=\"3,2\"/>\n"
            svg += "<line x1=\"\(fmt(x - halfW))\" y1=\"\(fmt(y))\" x2=\"\(fmt(x))\" y2=\"\(fmt(y - r))\" "
            svg += "stroke=\"#34D399\" stroke-width=\"1\" opacity=\"0.5\"/>\n"
            svg += "<text x=\"\(fmt(x))\" y=\"\(fmt(y + 14))\" class=\"opening-label\" fill=\"#34D399\">D\(Int(o.width * 1000))</text>\n"

        case "window":
            let off: Float = 3
            svg += "<line x1=\"\(fmt(x - halfW))\" y1=\"\(fmt(y - off))\" x2=\"\(fmt(x + halfW))\" y2=\"\(fmt(y - off))\" stroke=\"#38BDF8\" stroke-width=\"2\"/>\n"
            svg += "<line x1=\"\(fmt(x - halfW))\" y1=\"\(fmt(y + off))\" x2=\"\(fmt(x + halfW))\" y2=\"\(fmt(y + off))\" stroke=\"#38BDF8\" stroke-width=\"2\"/>\n"
            svg += "<text x=\"\(fmt(x))\" y=\"\(fmt(y + 16))\" class=\"opening-label\" fill=\"#38BDF8\">W\(Int(o.width * 1000))</text>\n"

        default:
            svg += "<line x1=\"\(fmt(x - halfW))\" y1=\"\(fmt(y))\" x2=\"\(fmt(x + halfW))\" y2=\"\(fmt(y))\" "
            svg += "stroke=\"#34D399\" stroke-width=\"2\" stroke-dasharray=\"6,3\"/>\n"
            svg += "<text x=\"\(fmt(x))\" y=\"\(fmt(y - 8))\" class=\"opening-label\" fill=\"#34D399\">SD\(Int(o.width * 1000))</text>\n"
        }
    }
}

// --- AI Room Labels ---
svg += "\n<!-- AI Room Labels -->\n"
for room in alignedRooms {
    let x = tx(room.x)
    let z = tz(room.z)

    // Room label background
    let labelWidth: Float = Float(room.label.count) * 9 + 16
    svg += "<rect x=\"\(fmt(x - labelWidth/2))\" y=\"\(fmt(z - 12))\" "
    svg += "width=\"\(fmt(labelWidth))\" height=\"20\" rx=\"4\" "
    svg += "fill=\"#1F2937\" stroke=\"#F59E0B\" stroke-width=\"1\" opacity=\"0.9\"/>\n"

    // Room name
    svg += "<text x=\"\(fmt(x))\" y=\"\(fmt(z + 3))\" class=\"room-label\">\(room.label)</text>\n"

    // Key features (max 3, on separate lines below)
    let topFeatures = Array(room.features.prefix(3))
    for (fi, feature) in topFeatures.enumerated() {
        svg += "<text x=\"\(fmt(x))\" y=\"\(fmt(z + 16 + Float(fi) * 10))\" class=\"room-features\">\(feature)</text>\n"
    }

    // Flooring indicator
    let floorIcon: String
    switch room.flooring {
    case "carpet": floorIcon = "▤ carpet"
    case "tile": floorIcon = "▦ tile"
    case "timber": floorIcon = "▥ timber"
    default: floorIcon = room.flooring
    }
    svg += "<text x=\"\(fmt(x))\" y=\"\(fmt(z + 16 + Float(topFeatures.count) * 10))\" "
    svg += "class=\"room-features\" fill=\"#6B7280\">\(floorIcon)</text>\n"
}

// --- Fixture symbols ---
svg += "\n<!-- Fixture symbols -->\n"
for fix in alignedFixtures {
    let x = tx(fix.x)
    let z = tz(fix.z)

    switch fix.type {
    case "toilet":
        // Toilet symbol: oval
        svg += "<ellipse cx=\"\(fmt(x))\" cy=\"\(fmt(z))\" rx=\"5\" ry=\"7\" "
        svg += "fill=\"none\" stroke=\"#A78BFA\" stroke-width=\"1.5\"/>\n"
        svg += "<rect x=\"\(fmt(x-4))\" y=\"\(fmt(z-9))\" width=\"8\" height=\"4\" rx=\"1\" "
        svg += "fill=\"none\" stroke=\"#A78BFA\" stroke-width=\"1\"/>\n"

    case "shower":
        // Shower: square with X
        svg += "<rect x=\"\(fmt(x-8))\" y=\"\(fmt(z-8))\" width=\"16\" height=\"16\" rx=\"2\" "
        svg += "fill=\"none\" stroke=\"#A78BFA\" stroke-width=\"1.5\"/>\n"
        svg += "<line x1=\"\(fmt(x-6))\" y1=\"\(fmt(z-6))\" x2=\"\(fmt(x+6))\" y2=\"\(fmt(z+6))\" stroke=\"#A78BFA\" stroke-width=\"0.8\"/>\n"
        svg += "<line x1=\"\(fmt(x+6))\" y1=\"\(fmt(z-6))\" x2=\"\(fmt(x-6))\" y2=\"\(fmt(z+6))\" stroke=\"#A78BFA\" stroke-width=\"0.8\"/>\n"

    case "vanity":
        // Vanity: rectangle with circle
        svg += "<rect x=\"\(fmt(x-6))\" y=\"\(fmt(z-4))\" width=\"12\" height=\"8\" rx=\"1\" "
        svg += "fill=\"none\" stroke=\"#A78BFA\" stroke-width=\"1.5\"/>\n"
        svg += "<circle cx=\"\(fmt(x))\" cy=\"\(fmt(z))\" r=\"3\" fill=\"none\" stroke=\"#A78BFA\" stroke-width=\"1\"/>\n"

    case "kitchen_bench":
        // Kitchen bench: L-shape
        svg += "<path d=\"M \(fmt(x-10)) \(fmt(z-8)) L \(fmt(x+10)) \(fmt(z-8)) L \(fmt(x+10)) \(fmt(z)) L \(fmt(x)) \(fmt(z)) L \(fmt(x)) \(fmt(z+8)) L \(fmt(x-10)) \(fmt(z+8)) Z\" "
        svg += "fill=\"none\" stroke=\"#A78BFA\" stroke-width=\"1.5\"/>\n"

    default:
        // Generic: diamond
        svg += "<polygon points=\"\(fmt(x)),\(fmt(z-5)) \(fmt(x+5)),\(fmt(z)) \(fmt(x)),\(fmt(z+5)) \(fmt(x-5)),\(fmt(z))\" "
        svg += "fill=\"none\" stroke=\"#A78BFA\" stroke-width=\"1\"/>\n"
    }

    svg += "<text x=\"\(fmt(x))\" y=\"\(fmt(z + 15))\" class=\"fixture-label\">\(fix.label)</text>\n"
}

// --- Overall dimensions ---
svg += "\n<!-- Dimensions -->\n"
let x1d = tx(wallMinX), x2d = tx(wallMaxX)
let topY = tz(wallMinZ) - 25

// Width
svg += "<line x1=\"\(fmt(x1d))\" y1=\"\(fmt(topY))\" x2=\"\(fmt(x2d))\" y2=\"\(fmt(topY))\" stroke=\"#60A5FA\" stroke-width=\"1\"/>\n"
svg += "<line x1=\"\(fmt(x1d))\" y1=\"\(fmt(topY-5))\" x2=\"\(fmt(x1d))\" y2=\"\(fmt(topY+5))\" stroke=\"#60A5FA\" stroke-width=\"1\"/>\n"
svg += "<line x1=\"\(fmt(x2d))\" y1=\"\(fmt(topY-5))\" x2=\"\(fmt(x2d))\" y2=\"\(fmt(topY+5))\" stroke=\"#60A5FA\" stroke-width=\"1\"/>\n"
svg += "<text x=\"\(fmt((x1d+x2d)/2))\" y=\"\(fmt(topY-8))\" class=\"dim-label\">\(Int(overallWidth * 1000))mm</text>\n"

// Depth
let z1d = tz(wallMinZ), z2d = tz(wallMaxZ)
let rightX = tx(wallMaxX) + 30
svg += "<line x1=\"\(fmt(rightX))\" y1=\"\(fmt(z1d))\" x2=\"\(fmt(rightX))\" y2=\"\(fmt(z2d))\" stroke=\"#60A5FA\" stroke-width=\"1\"/>\n"
svg += "<line x1=\"\(fmt(rightX-5))\" y1=\"\(fmt(z1d))\" x2=\"\(fmt(rightX+5))\" y2=\"\(fmt(z1d))\" stroke=\"#60A5FA\" stroke-width=\"1\"/>\n"
svg += "<line x1=\"\(fmt(rightX-5))\" y1=\"\(fmt(z2d))\" x2=\"\(fmt(rightX+5))\" y2=\"\(fmt(z2d))\" stroke=\"#60A5FA\" stroke-width=\"1\"/>\n"
svg += "<text x=\"\(fmt(rightX+15))\" y=\"\(fmt((z1d+z2d)/2))\" class=\"dim-label\" "
svg += "transform=\"rotate(90 \(fmt(rightX+15)) \(fmt((z1d+z2d)/2)))\">\(Int(overallDepth * 1000))mm</text>\n"

// Room-to-room dimensions between opposing walls
svg += "\n<!-- Room dimensions -->\n"
let sortedXWalls = wallLines.filter { $0.isXWall }.sorted { $0.position < $1.position }
for i in 0..<sortedXWalls.count - 1 {
    let gap = sortedXWalls[i+1].position - sortedXWalls[i].position
    if gap > 0.5 && gap < 8.0 {
        let midX = tx((sortedXWalls[i].position + sortedXWalls[i+1].position) / 2)
        let overlapStart = max(sortedXWalls[i].start, sortedXWalls[i+1].start)
        let overlapEnd = min(sortedXWalls[i].end, sortedXWalls[i+1].end)
        if overlapEnd > overlapStart {
            let midZ = tz((overlapStart + overlapEnd) / 2)
            // Dimension line
            let lx = tx(sortedXWalls[i].position), rx2 = tx(sortedXWalls[i+1].position)
            svg += "<line x1=\"\(fmt(lx))\" y1=\"\(fmt(midZ))\" x2=\"\(fmt(rx2))\" y2=\"\(fmt(midZ))\" "
            svg += "stroke=\"#EF4444\" stroke-width=\"0.5\" stroke-dasharray=\"2,3\" opacity=\"0.5\"/>\n"
            svg += "<text x=\"\(fmt(midX))\" y=\"\(fmt(midZ - 4))\" class=\"wall-dim\">\(Int(gap * 1000))</text>\n"
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
            let tz1 = tz(sortedZWalls[i].position), tz2 = tz(sortedZWalls[i+1].position)
            svg += "<line x1=\"\(fmt(midX))\" y1=\"\(fmt(tz1))\" x2=\"\(fmt(midX))\" y2=\"\(fmt(tz2))\" "
            svg += "stroke=\"#EF4444\" stroke-width=\"0.5\" stroke-dasharray=\"2,3\" opacity=\"0.5\"/>\n"
            svg += "<text x=\"\(fmt(midX + 4))\" y=\"\(fmt(midZ))\" class=\"wall-dim\" text-anchor=\"start\">\(Int(gap * 1000))</text>\n"
        }
    }
}

// --- Legend ---
let legY = svgH - 50
svg += "\n<!-- Legend -->\n"
svg += "<rect x=\"\(fmt(margin - 10))\" y=\"\(fmt(legY - 15))\" width=\"\(fmt(svgW - margin * 2 + 20))\" height=\"45\" rx=\"6\" fill=\"#1F2937\" opacity=\"0.8\"/>\n"

// Wall
svg += "<rect x=\"\(fmt(margin))\" y=\"\(fmt(legY - 3))\" width=\"25\" height=\"6\" rx=\"1\" fill=\"#D97706\"/>\n"
svg += "<text x=\"\(fmt(margin + 30))\" y=\"\(fmt(legY + 4))\" class=\"legend-text\">Wall</text>\n"

// Door
svg += "<path d=\"M \(fmt(margin + 70)) \(fmt(legY + 5)) A 8 8 0 0 1 \(fmt(margin + 78)) \(fmt(legY - 3))\" fill=\"none\" stroke=\"#34D399\" stroke-width=\"1.5\" stroke-dasharray=\"2,1\"/>\n"
svg += "<text x=\"\(fmt(margin + 85))\" y=\"\(fmt(legY + 4))\" class=\"legend-text\">Door</text>\n"

// Window
svg += "<line x1=\"\(fmt(margin + 125))\" y1=\"\(fmt(legY - 2))\" x2=\"\(fmt(margin + 145))\" y2=\"\(fmt(legY - 2))\" stroke=\"#38BDF8\" stroke-width=\"2\"/>\n"
svg += "<line x1=\"\(fmt(margin + 125))\" y1=\"\(fmt(legY + 4))\" x2=\"\(fmt(margin + 145))\" y2=\"\(fmt(legY + 4))\" stroke=\"#38BDF8\" stroke-width=\"2\"/>\n"
svg += "<text x=\"\(fmt(margin + 150))\" y=\"\(fmt(legY + 4))\" class=\"legend-text\">Window</text>\n"

// Sliding
svg += "<line x1=\"\(fmt(margin + 200))\" y1=\"\(fmt(legY + 1))\" x2=\"\(fmt(margin + 225))\" y2=\"\(fmt(legY + 1))\" stroke=\"#34D399\" stroke-width=\"2\" stroke-dasharray=\"5,3\"/>\n"
svg += "<text x=\"\(fmt(margin + 230))\" y=\"\(fmt(legY + 4))\" class=\"legend-text\">Sliding</text>\n"

// Fixture
svg += "<circle cx=\"\(fmt(margin + 285))\" cy=\"\(fmt(legY + 1))\" r=\"5\" fill=\"none\" stroke=\"#A78BFA\" stroke-width=\"1.5\"/>\n"
svg += "<text x=\"\(fmt(margin + 295))\" y=\"\(fmt(legY + 4))\" class=\"legend-text\">Fixture</text>\n"

// AI label
svg += "<rect x=\"\(fmt(margin + 340))\" y=\"\(fmt(legY - 6))\" width=\"40\" height=\"14\" rx=\"3\" fill=\"#1F2937\" stroke=\"#F59E0B\" stroke-width=\"1\"/>\n"
svg += "<text x=\"\(fmt(margin + 360))\" y=\"\(fmt(legY + 4))\" style=\"font-size:8px;fill:#F59E0B;text-anchor:middle;font-weight:700\">ROOM</text>\n"
svg += "<text x=\"\(fmt(margin + 390))\" y=\"\(fmt(legY + 4))\" class=\"legend-text\">AI Room ID</text>\n"

// Scale bar
svg += "<line x1=\"\(fmt(margin))\" y1=\"\(fmt(legY + 18))\" x2=\"\(fmt(margin + scale))\" y2=\"\(fmt(legY + 18))\" stroke=\"#6B7280\" stroke-width=\"2\"/>\n"
svg += "<line x1=\"\(fmt(margin))\" y1=\"\(fmt(legY + 14))\" x2=\"\(fmt(margin))\" y2=\"\(fmt(legY + 22))\" stroke=\"#6B7280\" stroke-width=\"1.5\"/>\n"
svg += "<line x1=\"\(fmt(margin + scale))\" y1=\"\(fmt(legY + 14))\" x2=\"\(fmt(margin + scale))\" y2=\"\(fmt(legY + 22))\" stroke=\"#6B7280\" stroke-width=\"1.5\"/>\n"
svg += "<text x=\"\(fmt(margin + scale/2))\" y=\"\(fmt(legY + 30))\" class=\"legend-text\" text-anchor=\"middle\">1 metre</text>\n"

// Footer
svg += "\n<!-- Footer -->\n"
svg += "<text x=\"\(fmt(svgW/2))\" y=\"\(fmt(svgH - 8))\" class=\"footer\">Generated by Studiio Scanner — Geometry (\(wallLines.count) walls, \(openings.count) openings) + AI Vision (\(roomLabels.count) rooms, \(fixtureLabels.count) fixtures) — For editor redrawing</text>\n"

// North arrow
svg += "\n<!-- North arrow -->\n"
let naX = svgW - margin + 10
let naY = margin + 20
svg += "<polygon points=\"\(fmt(naX)),\(fmt(naY-15)) \(fmt(naX-5)),\(fmt(naY)) \(fmt(naX+5)),\(fmt(naY))\" fill=\"#6B7280\"/>\n"
svg += "<text x=\"\(fmt(naX))\" y=\"\(fmt(naY + 12))\" style=\"font-size:10px;fill:#6B7280;text-anchor:middle;font-weight:700\">N</text>\n"

svg += "\n</svg>"

// Write output
let outputURL = bundleURL.deletingLastPathComponent().appendingPathComponent("hybrid-floorplan.svg")
try! svg.write(to: outputURL, atomically: true, encoding: .utf8)
print("\nHybrid floor plan written to: \(outputURL.path)")
print("SVG size: \(svg.count / 1024)KB")
print("Walls: \(wallLines.count), Openings: \(openings.count), AI Rooms: \(roomLabels.count), Fixtures: \(fixtureLabels.count)")
