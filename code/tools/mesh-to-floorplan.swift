#!/usr/bin/env swift
//
// mesh-to-floorplan.swift
// Reads .studiio bundle mesh data and generates a 2D floor plan SVG
// with RANSAC wall line fitting, inner-wall measurements, and opening detection.
//
// Usage: swift mesh-to-floorplan.swift /path/to/scan.studiio
//

import Foundation
import simd

// MARK: - Mesh Data Structures

struct MeshAnchor {
    let transform: simd_float4x4
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var indices: [UInt32]
}

// MARK: - Binary Mesh Reader

func readMeshBinary(from url: URL) -> MeshAnchor? {
    guard let data = try? Data(contentsOf: url) else { return nil }

    return data.withUnsafeBytes { rawBuffer -> MeshAnchor? in
        guard let basePtr = rawBuffer.baseAddress else { return nil }
        var offset = 0

        func readFloat() -> Float {
            let val = basePtr.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            var f: Float = 0
            memcpy(&f, val, 4)
            offset += 4
            return f
        }

        func readU32() -> UInt32 {
            let val = basePtr.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            var u: UInt32 = 0
            memcpy(&u, val, 4)
            offset += 4
            return u
        }

        // Transform (16 floats = 4x4 matrix)
        var floats: [Float] = []
        for _ in 0..<16 { floats.append(readFloat()) }
        let transform = simd_float4x4(
            SIMD4<Float>(floats[0], floats[1], floats[2], floats[3]),
            SIMD4<Float>(floats[4], floats[5], floats[6], floats[7]),
            SIMD4<Float>(floats[8], floats[9], floats[10], floats[11]),
            SIMD4<Float>(floats[12], floats[13], floats[14], floats[15])
        )

        // Vertices — SIMD3<Float> has stride of 16 bytes (12 data + 4 padding)
        let vertexCount = Int(readU32())
        guard offset + vertexCount * 16 <= data.count else { return nil }
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(vertexCount)
        for _ in 0..<vertexCount {
            let x = readFloat(), y = readFloat(), z = readFloat()
            let _ = readFloat() // padding (SIMD3 stride = 16)
            positions.append(SIMD3<Float>(x, y, z))
        }

        // Normals — same stride padding
        let normalCount = Int(readU32())
        guard offset + normalCount * 16 <= data.count else { return nil }
        var normals: [SIMD3<Float>] = []
        normals.reserveCapacity(normalCount)
        for _ in 0..<normalCount {
            let x = readFloat(), y = readFloat(), z = readFloat()
            let _ = readFloat() // padding
            normals.append(SIMD3<Float>(x, y, z))
        }

        // Indices
        let indexCount = Int(readU32())
        guard offset + indexCount * 4 <= data.count else { return nil }
        var indices: [UInt32] = []
        indices.reserveCapacity(indexCount)
        for _ in 0..<indexCount {
            indices.append(readU32())
        }

        return MeshAnchor(transform: transform, positions: positions, normals: normals, indices: indices)
    }
}

// MARK: - Transform vertices to world space

func worldPositions(anchor: MeshAnchor) -> [(pos: SIMD3<Float>, normal: SIMD3<Float>)] {
    let t = anchor.transform
    var result: [(pos: SIMD3<Float>, normal: SIMD3<Float>)] = []
    let count = min(anchor.positions.count, anchor.normals.count)

    for i in 0..<count {
        let local = anchor.positions[i]
        let worldPos4 = t * SIMD4<Float>(local.x, local.y, local.z, 1.0)
        let worldPos = SIMD3<Float>(worldPos4.x, worldPos4.y, worldPos4.z)

        let localN = anchor.normals[i]
        let worldN4 = t * SIMD4<Float>(localN.x, localN.y, localN.z, 0.0)
        let worldN = normalize(SIMD3<Float>(worldN4.x, worldN4.y, worldN4.z))

        result.append((pos: worldPos, normal: worldN))
    }

    return result
}

// MARK: - 2D Point and Line Types

struct Point2D {
    var x: Float
    var z: Float
}

struct WallLine {
    var start: Point2D
    var end: Point2D
    var normalAngle: Float  // Angle of wall normal (perpendicular to wall)
    var inlierCount: Int
    var thickness: Float    // Estimated wall thickness from point spread

    var length: Float {
        let dx = end.x - start.x
        let dz = end.z - start.z
        return sqrt(dx * dx + dz * dz)
    }

    var angle: Float {
        atan2(end.z - start.z, end.x - start.x)
    }

    var midpoint: Point2D {
        Point2D(x: (start.x + end.x) / 2, z: (start.z + end.z) / 2)
    }

    // Is this wall roughly axis-aligned? (within 15 degrees of X or Z axis)
    var isAxisAligned: Bool {
        let a = abs(angle)
        let tolerance: Float = 15 * .pi / 180
        return a < tolerance || abs(a - .pi / 2) < tolerance ||
               abs(a - .pi) < tolerance || abs(a + .pi / 2) < tolerance
    }

    // Is this wall roughly aligned with the X axis?
    var isXAligned: Bool {
        let a = abs(angle)
        let tolerance: Float = 15 * .pi / 180
        return a < tolerance || abs(a - .pi) < tolerance
    }

    // Is this wall roughly aligned with the Z axis?
    var isZAligned: Bool {
        let a = abs(angle)
        let tolerance: Float = 15 * .pi / 180
        return abs(a - .pi / 2) < tolerance || abs(a + .pi / 2) < tolerance
    }
}

struct WallOpening {
    enum Kind: String { case door, window, opening }
    var kind: Kind
    var position: Point2D
    var width: Float
    var wallIndex: Int
}

// MARK: - Dominant Angle Detection & Point Rotation

/// Find the dominant wall angle from wall points using a histogram of normal directions.
/// Wall normals cluster around 2 perpendicular angles — find the primary one.
func findDominantAngle(from points: [(x: Float, z: Float)], normals: [(nx: Float, nz: Float)]) -> Float {
    // Build histogram of normal angles (0 to 180°, since normal direction is ambiguous)
    let binCount = 180
    var histogram = Array(repeating: 0, count: binCount)

    for n in normals {
        var angle = atan2(n.nz, n.nx)
        if angle < 0 { angle += .pi }
        let bin = Int(angle / .pi * Float(binCount)) % binCount
        histogram[bin] += 1
    }

    // Smooth histogram
    var smoothed = Array(repeating: 0, count: binCount)
    for i in 0..<binCount {
        var sum = 0
        for d in -3...3 {
            let idx = (i + d + binCount) % binCount
            sum += histogram[idx]
        }
        smoothed[i] = sum
    }

    // Find peak
    let peakBin = smoothed.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
    let dominantNormalAngle = Float(peakBin) / Float(binCount) * .pi

    // Wall direction is perpendicular to normal
    let wallAngle = dominantNormalAngle - .pi / 2

    print("Dominant wall normal angle: \(String(format: "%.1f", dominantNormalAngle * 180 / .pi))°")
    print("Dominant wall direction: \(String(format: "%.1f", wallAngle * 180 / .pi))°")
    print("Rotation needed: \(String(format: "%.1f", -wallAngle * 180 / .pi))°")

    return wallAngle
}

/// Rotate 2D points by a given angle around the centroid
func rotatePoints(_ points: [(x: Float, z: Float)], byAngle angle: Float) -> [(x: Float, z: Float)] {
    let cosA = cos(angle)
    let sinA = sin(angle)

    return points.map { p in
        let rx = p.x * cosA - p.z * sinA
        let rz = p.x * sinA + p.z * cosA
        return (x: rx, z: rz)
    }
}

// MARK: - RANSAC Wall Line Fitting

func fitWallLines(from points: [(x: Float, z: Float)], iterations: Int = 500, inlierThreshold: Float = 0.04) -> [WallLine] {
    guard points.count >= 10 else { return [] }

    var remainingPoints = points
    var walls: [WallLine] = []
    let minInliers = max(20, points.count / 50) // At least 20 points or 2% of total

    for _ in 0..<20 { // Max 20 walls
        guard remainingPoints.count >= minInliers else { break }

        var bestLine: WallLine?
        var bestInliers: [(x: Float, z: Float)] = []
        var bestOutliers: [(x: Float, z: Float)] = []

        for _ in 0..<iterations {
            // Pick 2 random points
            let i1 = Int.random(in: 0..<remainingPoints.count)
            var i2 = Int.random(in: 0..<remainingPoints.count)
            while i2 == i1 { i2 = Int.random(in: 0..<remainingPoints.count) }

            let p1 = remainingPoints[i1]
            let p2 = remainingPoints[i2]

            // Line direction
            let dx = p2.x - p1.x
            let dz = p2.z - p1.z
            let len = sqrt(dx * dx + dz * dz)
            guard len > 0.1 else { continue } // Points too close

            let nx = -dz / len  // Normal to line
            let nz = dx / len

            // Count inliers (points within threshold distance of line)
            var inliers: [(x: Float, z: Float)] = []
            var outliers: [(x: Float, z: Float)] = []

            for p in remainingPoints {
                let dist = abs((p.x - p1.x) * nx + (p.z - p1.z) * nz)
                if dist < inlierThreshold {
                    inliers.append(p)
                } else {
                    outliers.append(p)
                }
            }

            if inliers.count > bestInliers.count {
                // Project inliers onto line to find extent
                var minT: Float = .greatestFiniteMagnitude
                var maxT: Float = -.greatestFiniteMagnitude

                for p in inliers {
                    let t = (p.x - p1.x) * (dx / len) + (p.z - p1.z) * (dz / len)
                    minT = min(minT, t)
                    maxT = max(maxT, t)
                }

                // Calculate thickness (spread of points perpendicular to line)
                var perpDists: [Float] = []
                for p in inliers {
                    let dist = (p.x - p1.x) * nx + (p.z - p1.z) * nz
                    perpDists.append(dist)
                }
                perpDists.sort()
                let p10 = perpDists[perpDists.count / 10]
                let p90 = perpDists[perpDists.count * 9 / 10]
                let thickness = p90 - p10

                let startPt = Point2D(x: p1.x + (dx / len) * minT, z: p1.z + (dz / len) * minT)
                let endPt = Point2D(x: p1.x + (dx / len) * maxT, z: p1.z + (dz / len) * maxT)
                let normalAngle = atan2(nz, nx)

                let wall = WallLine(
                    start: startPt, end: endPt,
                    normalAngle: normalAngle,
                    inlierCount: inliers.count,
                    thickness: thickness
                )

                // Only accept lines longer than 0.3m
                if wall.length > 0.3 {
                    bestLine = wall
                    bestInliers = inliers
                    bestOutliers = outliers
                }
            }
        }

        guard let wall = bestLine, bestInliers.count >= minInliers else { break }
        walls.append(wall)
        remainingPoints = bestOutliers
    }

    return walls
}

// MARK: - Wall Line Regularization

func regularizeWalls(_ walls: [WallLine]) -> [WallLine] {
    // Snap near-axis-aligned walls to perfect alignment
    // Find dominant angles (should be ~0° and ~90° for rectangular rooms)

    var regularized: [WallLine] = []
    let snapTolerance: Float = 10 * .pi / 180  // 10 degrees

    for var wall in walls {
        let angle = wall.angle

        // Snap to nearest 90-degree increment
        let snappedAngle: Float
        let remainder = angle.truncatingRemainder(dividingBy: .pi / 2)

        if abs(remainder) < snapTolerance {
            snappedAngle = angle - remainder
        } else if abs(remainder - .pi / 2) < snapTolerance {
            snappedAngle = angle - remainder + .pi / 2
        } else if abs(remainder + .pi / 2) < snapTolerance {
            snappedAngle = angle - remainder - .pi / 2
        } else {
            // Not near an axis — keep as-is
            regularized.append(wall)
            continue
        }

        // Rebuild wall at snapped angle
        let mid = wall.midpoint
        let halfLen = wall.length / 2
        let dx = cos(snappedAngle) * halfLen
        let dz = sin(snappedAngle) * halfLen

        wall.start = Point2D(x: mid.x - dx, z: mid.z - dz)
        wall.end = Point2D(x: mid.x + dx, z: mid.z + dz)
        regularized.append(wall)
    }

    return regularized
}

// MARK: - Inner Wall Measurement

struct RoomDimensions {
    var width: Float   // X-axis extent between inner wall faces
    var depth: Float   // Z-axis extent between inner wall faces
    var xWalls: [(position: Float, side: String)] // X-aligned walls with their Z positions
    var zWalls: [(position: Float, side: String)] // Z-aligned walls with their X positions
}

func measureInnerWalls(_ walls: [WallLine]) -> RoomDimensions {
    // Separate walls by orientation
    var xAligned: [WallLine] = []  // Walls running along X (horizontal in plan)
    var zAligned: [WallLine] = []  // Walls running along Z (vertical in plan)

    for wall in walls where wall.length > 0.5 {
        if wall.isXAligned {
            xAligned.append(wall)
        } else if wall.isZAligned {
            zAligned.append(wall)
        }
    }

    // For X-aligned walls, they have Z positions — find opposing pairs
    // Sort by Z position (midpoint)
    let xWallsByZ = xAligned.sorted { $0.midpoint.z < $1.midpoint.z }
    let zWallsByX = zAligned.sorted { $0.midpoint.x < $1.midpoint.x }

    print("\n=== WALL ANALYSIS ===")
    print("X-aligned walls (horizontal): \(xAligned.count)")
    for (i, w) in xWallsByZ.enumerated() {
        print("  [\(i)] Z=\(String(format: "%.3f", w.midpoint.z))  len=\(String(format: "%.2f", w.length))m  thickness=\(String(format: "%.0f", w.thickness * 1000))mm  inliers=\(w.inlierCount)")
    }
    print("Z-aligned walls (vertical): \(zAligned.count)")
    for (i, w) in zWallsByX.enumerated() {
        print("  [\(i)] X=\(String(format: "%.3f", w.midpoint.x))  len=\(String(format: "%.2f", w.length))m  thickness=\(String(format: "%.0f", w.thickness * 1000))mm  inliers=\(w.inlierCount)")
    }

    // Find room depth: distance between furthest opposing X-aligned walls
    // Use inner faces (subtract half thickness from each)
    var depth: Float = 0
    var xWallPositions: [(position: Float, side: String)] = []

    if xWallsByZ.count >= 2 {
        let nearWall = xWallsByZ.first!
        let farWall = xWallsByZ.last!
        let innerNear = nearWall.midpoint.z + nearWall.thickness / 2
        let innerFar = farWall.midpoint.z - farWall.thickness / 2
        depth = abs(innerFar - innerNear)

        for w in xWallsByZ {
            xWallPositions.append((position: w.midpoint.z, side: w.midpoint.z < (nearWall.midpoint.z + farWall.midpoint.z) / 2 ? "near" : "far"))
        }

        print("\nDepth (Z): inner near=\(String(format: "%.3f", innerNear)) inner far=\(String(format: "%.3f", innerFar))")
        print("  Raw distance: \(String(format: "%.3f", abs(farWall.midpoint.z - nearWall.midpoint.z)))m")
        print("  Inner distance: \(String(format: "%.3f", depth))m")
    }

    // Find room width: distance between furthest opposing Z-aligned walls
    var width: Float = 0
    var zWallPositions: [(position: Float, side: String)] = []

    if zWallsByX.count >= 2 {
        let leftWall = zWallsByX.first!
        let rightWall = zWallsByX.last!
        let innerLeft = leftWall.midpoint.x + leftWall.thickness / 2
        let innerRight = rightWall.midpoint.x - rightWall.thickness / 2
        width = abs(innerRight - innerLeft)

        for w in zWallsByX {
            zWallPositions.append((position: w.midpoint.x, side: w.midpoint.x < (leftWall.midpoint.x + rightWall.midpoint.x) / 2 ? "left" : "right"))
        }

        print("\nWidth (X): inner left=\(String(format: "%.3f", innerLeft)) inner right=\(String(format: "%.3f", innerRight))")
        print("  Raw distance: \(String(format: "%.3f", abs(rightWall.midpoint.x - leftWall.midpoint.x)))m")
        print("  Inner distance: \(String(format: "%.3f", width))m")
    }

    return RoomDimensions(width: width, depth: depth, xWalls: xWallPositions, zWalls: zWallPositions)
}

// MARK: - Opening Detection (doors, windows)

func detectOpenings(walls: [WallLine], allVertices: [(pos: SIMD3<Float>, normal: SIMD3<Float>)], floorY: Float) -> [WallOpening] {
    var openings: [WallOpening] = []

    for (wallIdx, wall) in walls.enumerated() {
        guard wall.length > 1.0 else { continue } // Only check longer walls

        let wallDx = wall.end.x - wall.start.x
        let wallDz = wall.end.z - wall.start.z
        let wallLen = wall.length

        // Divide wall into segments and check for gaps in wall vertices
        let segmentSize: Float = 0.1  // 10cm segments
        let segmentCount = Int(wallLen / segmentSize)
        guard segmentCount > 3 else { continue }

        // For each segment, count wall vertices nearby at different heights
        var segmentDensityLow: [Int] = Array(repeating: 0, count: segmentCount)   // 0-0.5m (below door)
        var segmentDensityMid: [Int] = Array(repeating: 0, count: segmentCount)   // 0.5-2.0m (door/window height)
        var segmentDensityHigh: [Int] = Array(repeating: 0, count: segmentCount)  // 2.0-2.5m (above door)

        let perpNx = -wallDz / wallLen
        let perpNz = wallDx / wallLen

        for v in allVertices {
            // Check if vertex is near this wall (within 0.15m perpendicular)
            let perpDist = abs((v.pos.x - wall.start.x) * perpNx + (v.pos.z - wall.start.z) * perpNz)
            guard perpDist < 0.15 else { continue }
            guard abs(v.normal.y) < 0.3 else { continue } // Wall-like normal

            // Project onto wall to find segment
            let t = ((v.pos.x - wall.start.x) * (wallDx / wallLen) + (v.pos.z - wall.start.z) * (wallDz / wallLen))
            let segIdx = Int(t / segmentSize)
            guard segIdx >= 0 && segIdx < segmentCount else { continue }

            let heightAboveFloor = v.pos.y - floorY
            if heightAboveFloor >= 0 && heightAboveFloor < 0.5 {
                segmentDensityLow[segIdx] += 1
            } else if heightAboveFloor >= 0.5 && heightAboveFloor < 2.0 {
                segmentDensityMid[segIdx] += 1
            } else if heightAboveFloor >= 2.0 && heightAboveFloor < 2.5 {
                segmentDensityHigh[segIdx] += 1
            }
        }

        // Find gaps in mid-height density (potential doors/windows)
        let avgMidDensity = segmentDensityMid.reduce(0, +) / max(1, segmentCount)
        let gapThreshold = max(2, avgMidDensity / 4)

        var inGap = false
        var gapStart = 0

        for seg in 0..<segmentCount {
            let isSparse = segmentDensityMid[seg] < gapThreshold

            if isSparse && !inGap {
                inGap = true
                gapStart = seg
            } else if !isSparse && inGap {
                inGap = false
                let gapWidth = Float(seg - gapStart) * segmentSize

                if gapWidth >= 0.5 && gapWidth <= 2.5 { // Reasonable opening size
                    let gapCenter = Float(gapStart + seg) / 2 * segmentSize
                    let posX = wall.start.x + (wallDx / wallLen) * gapCenter
                    let posZ = wall.start.z + (wallDz / wallLen) * gapCenter

                    // Check if there's wall below the gap (window) or not (door)
                    let lowDensityInGap = (gapStart..<seg).map { segmentDensityLow[$0] }.reduce(0, +)
                    let hasWallBelow = lowDensityInGap > (seg - gapStart) * 2

                    let kind: WallOpening.Kind
                    if hasWallBelow {
                        kind = .window
                    } else if gapWidth >= 0.6 && gapWidth <= 1.2 {
                        kind = .door
                    } else {
                        kind = .opening
                    }

                    openings.append(WallOpening(
                        kind: kind,
                        position: Point2D(x: posX, z: posZ),
                        width: gapWidth,
                        wallIndex: wallIdx
                    ))
                }
            }
        }
    }

    return openings
}

// MARK: - Object Detection from Mesh Geometry

struct DetectedObject {
    var category: String   // kitchen_bench, vanity, table, toilet, bathtub, ceiling_fan, fireplace
    var label: String      // Display label
    var x: Float, z: Float // Center position
    var width: Float, depth: Float
    var height: Float      // Height above floor
    var color: String      // SVG color
}

func detectObjects(from vertices: [(pos: SIMD3<Float>, normal: SIMD3<Float>)], floorY: Float) -> [DetectedObject] {
    var objects: [DetectedObject] = []

    // Find ceiling level
    var ceilingCandidates: [Float] = []
    for v in vertices where v.normal.y < -0.8 && v.pos.y > floorY + 1.5 {
        ceilingCandidates.append(v.pos.y)
    }
    ceilingCandidates.sort()
    let ceilingY = ceilingCandidates.count > 50 ?
        ceilingCandidates[ceilingCandidates.count * 9 / 10] : (floorY + 2.4)
    print("Ceiling level: \(String(format: "%.2f", ceilingY))m")

    // Horizontal surface detection at different height bands
    let bands: [(min: Float, max: Float, name: String)] = [
        (0.35, 0.55, "low_surface"),      // Coffee table, toilet top
        (0.70, 0.82, "mid_surface"),       // Table/desk
        (0.82, 0.98, "counter_surface"),   // Kitchen bench / vanity
    ]

    for band in bands {
        let bandMin = floorY + band.min
        let bandMax = floorY + band.max

        var surfacePoints: [SIMD3<Float>] = []
        for v in vertices where v.normal.y > 0.6 && v.pos.y >= bandMin && v.pos.y <= bandMax {
            surfacePoints.append(v.pos)
        }

        guard surfacePoints.count > 20 else { continue }

        // Simple grid-based clustering
        let cellSize: Float = 0.3
        var grid: [String: [SIMD3<Float>]] = [:]
        for p in surfacePoints {
            let key = "\(Int(p.x / cellSize)),\(Int(p.z / cellSize))"
            grid[key, default: []].append(p)
        }

        // Flood-fill clustering
        var visited = Set<String>()
        for key in grid.keys {
            guard !visited.contains(key) else { continue }
            var cluster: [SIMD3<Float>] = []
            var queue = [key]

            while !queue.isEmpty {
                let cur = queue.removeFirst()
                guard !visited.contains(cur) else { continue }
                visited.insert(cur)
                if let pts = grid[cur] { cluster.append(contentsOf: pts) }

                let parts = cur.split(separator: ",")
                guard parts.count == 2, let cx = Int(parts[0]), let cz = Int(parts[1]) else { continue }
                for dx in -1...1 {
                    for dz in -1...1 {
                        if dx == 0 && dz == 0 { continue }
                        let nb = "\(cx + dx),\(cz + dz)"
                        if grid[nb] != nil && !visited.contains(nb) { queue.append(nb) }
                    }
                }
            }

            guard cluster.count >= 10 else { continue }

            let cMinX = cluster.map(\.x).min()!, cMaxX = cluster.map(\.x).max()!
            let cMinZ = cluster.map(\.z).min()!, cMaxZ = cluster.map(\.z).max()!
            let w = cMaxX - cMinX, d = cMaxZ - cMinZ
            let avgY = cluster.map(\.y).reduce(0, +) / Float(cluster.count)
            let heightAboveFloor = avgY - floorY

            guard w > 0.25 && d > 0.2 && w < 5.0 && d < 3.0 else { continue }

            let category: String
            let label: String
            let color: String

            if band.name == "counter_surface" {
                if w > 1.0 || d > 1.0 {
                    category = "kitchen_bench"
                    label = "BENCH"
                    color = "#E91E63"
                } else {
                    category = "vanity"
                    label = "VAN"
                    color = "#9C27B0"
                }
            } else if band.name == "low_surface" {
                let longSide = max(w, d)
                let shortSide = min(w, d)
                if shortSide > 0.25 && shortSide < 0.6 && longSide > 0.35 && longSide < 0.85 {
                    category = "toilet"
                    label = "WC"
                    color = "#00BCD4"
                } else if longSide > 1.2 && shortSide > 0.5 {
                    category = "bathtub"
                    label = "BATH"
                    color = "#2196F3"
                } else {
                    category = "table"
                    label = "TABLE"
                    color = "#8BC34A"
                }
            } else {
                if w > 1.5 && d > 0.8 {
                    category = "bed"
                    label = "BED"
                    color = "#FF9800"
                } else {
                    category = "table"
                    label = "TABLE"
                    color = "#8BC34A"
                }
            }

            objects.append(DetectedObject(
                category: category, label: label,
                x: (cMinX + cMaxX) / 2, z: (cMinZ + cMaxZ) / 2,
                width: w, depth: d,
                height: heightAboveFloor,
                color: color
            ))
            print("  Detected \(category): \(Int(w * 1000))x\(Int(d * 1000))mm at height \(Int(heightAboveFloor * 1000))mm")
        }
    }

    // CEILING FAN detection
    let fanMin = ceilingY - 0.3
    var ceilingPoints: [SIMD3<Float>] = []
    for v in vertices where v.pos.y >= fanMin && v.pos.y <= ceilingY + 0.1 && v.normal.y < -0.3 {
        ceilingPoints.append(v.pos)
    }

    // Cluster ceiling points
    let fanCellSize: Float = 0.2
    var fanGrid: [String: [SIMD3<Float>]] = [:]
    for p in ceilingPoints {
        let key = "\(Int(p.x / fanCellSize)),\(Int(p.z / fanCellSize))"
        fanGrid[key, default: []].append(p)
    }

    var fanVisited = Set<String>()
    for key in fanGrid.keys {
        guard !fanVisited.contains(key) else { continue }
        var cluster: [SIMD3<Float>] = []
        var queue = [key]
        while !queue.isEmpty {
            let cur = queue.removeFirst()
            guard !fanVisited.contains(cur) else { continue }
            fanVisited.insert(cur)
            if let pts = fanGrid[cur] { cluster.append(contentsOf: pts) }
            let parts = cur.split(separator: ",")
            guard parts.count == 2, let cx = Int(parts[0]), let cz = Int(parts[1]) else { continue }
            for dx in -1...1 { for dz in -1...1 {
                if dx == 0 && dz == 0 { continue }
                let nb = "\(cx + dx),\(cz + dz)"
                if fanGrid[nb] != nil && !fanVisited.contains(nb) { queue.append(nb) }
            }}
        }
        guard cluster.count >= 10 else { continue }
        let w = cluster.map(\.x).max()! - cluster.map(\.x).min()!
        let d = cluster.map(\.z).max()! - cluster.map(\.z).min()!
        let aspect = min(w, d) / max(w, d)
        // Fan: roughly circular, 0.8-1.5m diameter
        if w > 0.8 && w < 1.6 && d > 0.8 && d < 1.6 && aspect > 0.6 {
            objects.append(DetectedObject(
                category: "ceiling_fan", label: "FAN",
                x: (cluster.map(\.x).min()! + cluster.map(\.x).max()!) / 2,
                z: (cluster.map(\.z).min()! + cluster.map(\.z).max()!) / 2,
                width: w, depth: d,
                height: ceilingY - floorY,
                color: "#607D8B"
            ))
            print("  Detected ceiling_fan: \(Int(w * 1000))x\(Int(d * 1000))mm")
        }
    }

    // FIREPLACE: Hearth detection (raised platform 100-400mm above floor)
    let hearthMin = floorY + 0.1, hearthMax = floorY + 0.5
    var hearthPoints: [SIMD3<Float>] = []
    for v in vertices where v.normal.y > 0.6 && v.pos.y >= hearthMin && v.pos.y <= hearthMax {
        hearthPoints.append(v.pos)
    }
    let hearthCellSize: Float = 0.15
    var hearthGrid: [String: [SIMD3<Float>]] = [:]
    for p in hearthPoints {
        let key = "\(Int(p.x / hearthCellSize)),\(Int(p.z / hearthCellSize))"
        hearthGrid[key, default: []].append(p)
    }
    var hearthVisited = Set<String>()
    for key in hearthGrid.keys {
        guard !hearthVisited.contains(key) else { continue }
        var cluster: [SIMD3<Float>] = []
        var queue = [key]
        while !queue.isEmpty {
            let cur = queue.removeFirst()
            guard !hearthVisited.contains(cur) else { continue }
            hearthVisited.insert(cur)
            if let pts = hearthGrid[cur] { cluster.append(contentsOf: pts) }
            let parts = cur.split(separator: ",")
            guard parts.count == 2, let cx = Int(parts[0]), let cz = Int(parts[1]) else { continue }
            for dx in -1...1 { for dz in -1...1 {
                if dx == 0 && dz == 0 { continue }
                let nb = "\(cx + dx),\(cz + dz)"
                if hearthGrid[nb] != nil && !hearthVisited.contains(nb) { queue.append(nb) }
            }}
        }
        guard cluster.count >= 5 else { continue }
        let w = cluster.map(\.x).max()! - cluster.map(\.x).min()!
        let d = cluster.map(\.z).max()! - cluster.map(\.z).min()!
        if w > 0.6 && w < 1.8 && d > 0.2 && d < 0.7 {
            let cx = (cluster.map(\.x).min()! + cluster.map(\.x).max()!) / 2
            let cz = (cluster.map(\.z).min()! + cluster.map(\.z).max()!) / 2
            let avgY = cluster.map(\.y).reduce(0, +) / Float(cluster.count)
            // Verify wall recess above hearth
            let recessCount = vertices.filter { v in
                abs(v.pos.x - cx) < w / 2 && abs(v.pos.z - cz) < 0.5 &&
                v.pos.y > avgY && v.pos.y < avgY + 1.0 && abs(v.normal.y) < 0.3
            }.count
            if recessCount > 15 {
                objects.append(DetectedObject(
                    category: "fireplace", label: "FP",
                    x: cx, z: cz, width: w, depth: d,
                    height: avgY - floorY,
                    color: "#FF5722"
                ))
                print("  Detected fireplace: \(Int(w * 1000))x\(Int(d * 1000))mm hearth")
            }
        }
    }

    return objects
}

// MARK: - SVG Generation

func generateSVG(
    walls: [WallLine],
    openings: [WallOpening],
    dimensions: RoomDimensions,
    wallPoints: [(x: Float, z: Float)],
    floorPoints: [(x: Float, z: Float)],
    allBounds: (minX: Float, maxX: Float, minZ: Float, maxZ: Float),
    detectedObjects: [DetectedObject] = []
) -> String {
    let minX = allBounds.minX
    let maxX = allBounds.maxX
    let minZ = allBounds.minZ
    let maxZ = allBounds.maxZ

    let svgScale: Float = 150.0  // 150 pixels per metre (higher res)
    let margin: Float = 80.0
    let svgW = (maxX - minX) * svgScale + margin * 2
    let svgH = (maxZ - minZ) * svgScale + margin * 2

    func sx(_ worldX: Float) -> Float { (worldX - minX) * svgScale + margin }
    func sy(_ worldZ: Float) -> Float { (worldZ - minZ) * svgScale + margin }

    var svg = """
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(Int(svgW)) \(Int(svgH))" width="\(Int(svgW))" height="\(Int(svgH))">
    <defs>
      <style>
        .wall-line { stroke: #FF8C00; stroke-width: 3; stroke-linecap: round; }
        .wall-thick { stroke: #FF8C00; stroke-width: 8; stroke-linecap: round; opacity: 0.6; }
        .dim-line { stroke: #4FC3F7; stroke-width: 1; }
        .dim-text { fill: #4FC3F7; font-family: Helvetica; font-size: 11; }
        .opening-door { stroke: #4CAF50; stroke-width: 2; fill: none; }
        .opening-window { stroke: #42A5F5; stroke-width: 3; fill: none; }
        .opening-open { stroke: #FDD835; stroke-width: 2; fill: none; stroke-dasharray: 4,4; }
        .label { fill: #888; font-family: Helvetica; font-size: 10; }
        .title { fill: #FF8C00; font-family: Helvetica; font-size: 18; font-weight: bold; }
        .subtitle { fill: #888; font-family: Helvetica; font-size: 12; }
      </style>
    </defs>
    <rect width="100%" height="100%" fill="#1a1a1a"/>

    <!-- Grid (1m spacing) -->
    <g stroke="#282828" stroke-width="0.5">
    """

    // Grid lines
    var gx = floor(minX)
    while gx <= ceil(maxX) {
        svg += "  <line x1=\"\(sx(gx))\" y1=\"\(margin)\" x2=\"\(sx(gx))\" y2=\"\(svgH - margin)\" />\n"
        gx += 1.0
    }
    var gz = floor(minZ)
    while gz <= ceil(maxZ) {
        svg += "  <line x1=\"\(margin)\" y1=\"\(sy(gz))\" x2=\"\(svgW - margin)\" y2=\"\(sy(gz))\" />\n"
        gz += 1.0
    }
    svg += "</g>\n"

    // Floor area (subtle)
    svg += "<!-- Floor area -->\n<g fill=\"#222\">\n"
    let floorCellSize: Float = 0.1
    var floorGrid = Set<String>()
    for p in floorPoints {
        let key = "\(Int((p.x - minX) / floorCellSize)),\(Int((p.z - minZ) / floorCellSize))"
        if floorGrid.insert(key).inserted {
            let fx = sx(p.x)
            let fy = sy(p.z)
            let fs = floorCellSize * svgScale
            svg += "  <rect x=\"\(fx)\" y=\"\(fy)\" width=\"\(fs)\" height=\"\(fs)\" />\n"
        }
    }
    svg += "</g>\n"

    // Raw wall point cloud (faint, for reference)
    svg += "<!-- Wall point cloud -->\n<g fill=\"#FF8C00\" opacity=\"0.15\">\n"
    let pcCellSize: Float = 0.05
    var pcGrid = Set<String>()
    for p in wallPoints {
        let key = "\(Int((p.x - minX) / pcCellSize)),\(Int((p.z - minZ) / pcCellSize))"
        if pcGrid.insert(key).inserted {
            svg += "  <circle cx=\"\(sx(p.x))\" cy=\"\(sy(p.z))\" r=\"1.5\" />\n"
        }
    }
    svg += "</g>\n"

    // Fitted wall lines (thick for wall body, thin for edge)
    svg += "<!-- Fitted wall lines -->\n<g>\n"
    for wall in walls {
        // Thick wall body
        let wallPx = max(4, wall.thickness * svgScale)
        svg += "  <line x1=\"\(sx(wall.start.x))\" y1=\"\(sy(wall.start.z))\" x2=\"\(sx(wall.end.x))\" y2=\"\(sy(wall.end.z))\" stroke=\"#FF8C00\" stroke-width=\"\(wallPx)\" stroke-linecap=\"round\" opacity=\"0.5\" />\n"
        // Crisp center line
        svg += "  <line x1=\"\(sx(wall.start.x))\" y1=\"\(sy(wall.start.z))\" x2=\"\(sx(wall.end.x))\" y2=\"\(sy(wall.end.z))\" class=\"wall-line\" />\n"
    }
    svg += "</g>\n"

    // Openings
    svg += "<!-- Openings -->\n<g>\n"
    for opening in openings {
        let cx = sx(opening.position.x)
        let cz = sy(opening.position.z)
        let hw = opening.width * svgScale / 2

        switch opening.kind {
        case .door:
            // Door arc symbol
            svg += "  <circle cx=\"\(cx)\" cy=\"\(cz)\" r=\"\(hw)\" class=\"opening-door\" />\n"
            svg += "  <text x=\"\(cx)\" y=\"\(cz - hw - 4)\" text-anchor=\"middle\" fill=\"#4CAF50\" font-family=\"Helvetica\" font-size=\"9\">D \(Int(opening.width * 1000))mm</text>\n"
        case .window:
            svg += "  <line x1=\"\(cx - hw)\" y1=\"\(cz)\" x2=\"\(cx + hw)\" y2=\"\(cz)\" class=\"opening-window\" />\n"
            svg += "  <text x=\"\(cx)\" y=\"\(cz - 6)\" text-anchor=\"middle\" fill=\"#42A5F5\" font-family=\"Helvetica\" font-size=\"9\">W \(Int(opening.width * 1000))mm</text>\n"
        case .opening:
            svg += "  <line x1=\"\(cx - hw)\" y1=\"\(cz)\" x2=\"\(cx + hw)\" y2=\"\(cz)\" class=\"opening-open\" />\n"
            svg += "  <text x=\"\(cx)\" y=\"\(cz - 6)\" text-anchor=\"middle\" fill=\"#FDD835\" font-family=\"Helvetica\" font-size=\"9\">O \(Int(opening.width * 1000))mm</text>\n"
        }
    }
    svg += "</g>\n"

    // Detected objects
    if !detectedObjects.isEmpty {
        svg += "<!-- Detected Objects -->\n<g>\n"
        for obj in detectedObjects {
            let ox = sx(obj.x - obj.width / 2)
            let oz = sy(obj.z - obj.depth / 2)
            let ow = obj.width * svgScale
            let od = obj.depth * svgScale
            let cx = sx(obj.x)
            let cz = sy(obj.z)

            // Filled rectangle with opacity
            svg += "  <rect x=\"\(ox)\" y=\"\(oz)\" width=\"\(ow)\" height=\"\(od)\" fill=\"\(obj.color)\" opacity=\"0.25\" stroke=\"\(obj.color)\" stroke-width=\"1.5\" rx=\"4\" />\n"

            // Label
            svg += "  <text x=\"\(cx)\" y=\"\(cz + 4)\" text-anchor=\"middle\" fill=\"\(obj.color)\" font-family=\"Helvetica\" font-size=\"10\" font-weight=\"bold\">\(obj.label)</text>\n"

            // Dimensions below label
            svg += "  <text x=\"\(cx)\" y=\"\(cz + 15)\" text-anchor=\"middle\" fill=\"\(obj.color)\" font-family=\"Helvetica\" font-size=\"7\" opacity=\"0.8\">\(Int(obj.width * 1000))x\(Int(obj.depth * 1000))</text>\n"
        }
        svg += "</g>\n"
    }

    // Dimension lines
    let dimW = dimensions.width
    let dimD = dimensions.depth
    let area = dimW * dimD

    svg += "<!-- Dimension lines -->\n<g>\n"

    // Width dimension (top)
    if dimW > 0 {
        let y = margin - 25
        let x1 = sx(minX + (maxX - minX - dimW) / 2)
        let x2 = x1 + dimW * svgScale
        svg += "  <line x1=\"\(x1)\" y1=\"\(y)\" x2=\"\(x2)\" y2=\"\(y)\" class=\"dim-line\" />\n"
        svg += "  <line x1=\"\(x1)\" y1=\"\(y - 5)\" x2=\"\(x1)\" y2=\"\(y + 5)\" class=\"dim-line\" />\n"
        svg += "  <line x1=\"\(x2)\" y1=\"\(y - 5)\" x2=\"\(x2)\" y2=\"\(y + 5)\" class=\"dim-line\" />\n"
        svg += "  <text x=\"\((x1 + x2) / 2)\" y=\"\(y - 8)\" text-anchor=\"middle\" class=\"dim-text\">\(Int(dimW * 1000))mm</text>\n"
    }

    // Depth dimension (right side)
    if dimD > 0 {
        let x = svgW - margin + 25
        let y1 = sy(minZ + (maxZ - minZ - dimD) / 2)
        let y2 = y1 + dimD * svgScale
        svg += "  <line x1=\"\(x)\" y1=\"\(y1)\" x2=\"\(x)\" y2=\"\(y2)\" class=\"dim-line\" />\n"
        svg += "  <line x1=\"\(x - 5)\" y1=\"\(y1)\" x2=\"\(x + 5)\" y2=\"\(y1)\" class=\"dim-line\" />\n"
        svg += "  <line x1=\"\(x - 5)\" y1=\"\(y2)\" x2=\"\(x + 5)\" y2=\"\(y2)\" class=\"dim-line\" />\n"
        svg += "  <text x=\"\(x + 8)\" y=\"\((y1 + y2) / 2)\" class=\"dim-text\" transform=\"rotate(90 \(x + 8) \((y1 + y2) / 2))\">\(Int(dimD * 1000))mm</text>\n"
    }
    svg += "</g>\n"

    // Title and info
    svg += """

    <!-- Title -->
    <text x="\(svgW / 2)" y="25" text-anchor="middle" class="title">STUDIIO FLOOR PLAN</text>
    <text x="\(svgW / 2)" y="42" text-anchor="middle" class="subtitle">\(Int(dimW * 1000))mm x \(Int(dimD * 1000))mm — \(String(format: "%.1f", area)) m²</text>

    <!-- Legend -->
    <g transform="translate(\(margin), \(svgH - 50))">
      <line x1="0" y1="0" x2="20" y2="0" stroke="#FF8C00" stroke-width="3" />
      <text x="25" y="4" class="label">Wall</text>
      <circle cx="70" cy="0" r="6" stroke="#4CAF50" stroke-width="1.5" fill="none" />
      <text x="80" y="4" class="label">Door</text>
      <line x1="110" y1="0" x2="130" y2="0" stroke="#42A5F5" stroke-width="2" />
      <text x="135" y="4" class="label">Window</text>
      <line x1="175" y1="0" x2="195" y2="0" stroke="#FDD835" stroke-width="1.5" stroke-dasharray="3,3" />
      <text x="200" y="4" class="label">Opening</text>
    </g>

    <!-- Scale bar -->
    <g transform="translate(\(margin), \(svgH - 20))">
      <line x1="0" y1="0" x2="\(svgScale)" y2="0" stroke="#FF8C00" stroke-width="2"/>
      <line x1="0" y1="-5" x2="0" y2="5" stroke="#FF8C00" stroke-width="2"/>
      <line x1="\(svgScale)" y1="-5" x2="\(svgScale)" y2="5" stroke="#FF8C00" stroke-width="2"/>
      <text x="\(svgScale / 2)" y="-8" text-anchor="middle" class="label">1 metre</text>
    </g>
    """

    svg += "\n</svg>\n"
    return svg
}

func generateEmptySVG() -> String {
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 200" width="400" height="200">
    <rect width="100%" height="100%" fill="#1a1a1a"/>
    <text x="200" y="100" text-anchor="middle" fill="#FF8C00" font-family="Helvetica" font-size="16">No wall data found</text>
    </svg>
    """
}

// MARK: - Main Floor Plan Extraction

func extractFloorPlan(meshDir: URL) -> String {
    // Load all mesh anchors
    let indexURL = meshDir.appendingPathComponent("index.json")
    guard let indexData = try? Data(contentsOf: indexURL),
          let indexJSON = try? JSONSerialization.jsonObject(with: indexData) as? [String: Any],
          let anchorsArray = indexJSON["anchors"] as? [[String: Any]] else {
        print("ERROR: Cannot read mesh/index.json")
        return ""
    }

    print("Loading \(anchorsArray.count) mesh anchors...")

    var allVertices: [(pos: SIMD3<Float>, normal: SIMD3<Float>)] = []

    for anchorInfo in anchorsArray {
        guard let filename = anchorInfo["file"] as? String else { continue }
        let fileURL = meshDir.appendingPathComponent(filename)
        guard let anchor = readMeshBinary(from: fileURL) else {
            print("  WARNING: Failed to load \(filename)")
            continue
        }
        let verts = worldPositions(anchor: anchor)
        allVertices.append(contentsOf: verts)
        let vertCount = anchorInfo["vertices"] as? Int ?? 0
        print("  Loaded \(filename): \(vertCount) vertices")
    }

    print("Total vertices: \(allVertices.count)")

    // Step 1: Find floor level
    var floorYCandidates: [Float] = []
    for v in allVertices {
        if v.normal.y > 0.8 {
            floorYCandidates.append(v.pos.y)
        }
    }
    floorYCandidates.sort()

    let floorY: Float
    if floorYCandidates.count > 100 {
        floorY = floorYCandidates[floorYCandidates.count / 10]
    } else if !floorYCandidates.isEmpty {
        floorY = floorYCandidates[0]
    } else {
        floorY = allVertices.map(\.pos.y).min() ?? 0
    }
    print("Floor level: \(String(format: "%.2f", floorY))m")

    // Step 2: Extract wall points at multiple height slices for robustness
    let sliceRanges: [(min: Float, max: Float)] = [
        (floorY + 0.5, floorY + 0.8),
        (floorY + 0.8, floorY + 1.2),
        (floorY + 1.2, floorY + 1.6),
    ]

    var wallPointsRaw: [(x: Float, z: Float)] = []
    var wallNormals: [(nx: Float, nz: Float)] = []

    for v in allVertices {
        let isWallNormal = abs(v.normal.y) < 0.3
        let inSlice = sliceRanges.contains { v.pos.y >= $0.min && v.pos.y <= $0.max }

        if isWallNormal && inSlice {
            wallPointsRaw.append((x: v.pos.x, z: v.pos.z))
            wallNormals.append((nx: v.normal.x, nz: v.normal.z))
        }
    }

    print("Wall points (multi-slice): \(wallPointsRaw.count)")

    guard !wallPointsRaw.isEmpty else {
        print("ERROR: No wall points found!")
        return generateEmptySVG()
    }

    // Step 2b: Detect dominant wall angle and rotate to align with axes
    print("\n--- Dominant Angle Detection ---")
    let dominantAngle = findDominantAngle(from: wallPointsRaw, normals: wallNormals)
    let rotationAngle = -dominantAngle  // Rotate to align walls with X/Z axes

    let wallPoints = rotatePoints(wallPointsRaw, byAngle: rotationAngle)

    // Also rotate all vertices for opening detection later
    let rotCos = cos(rotationAngle)
    let rotSin = sin(rotationAngle)
    let rotatedVertices: [(pos: SIMD3<Float>, normal: SIMD3<Float>)] = allVertices.map { v in
        let rx = v.pos.x * rotCos - v.pos.z * rotSin
        let rz = v.pos.x * rotSin + v.pos.z * rotCos
        let rnx = v.normal.x * rotCos - v.normal.z * rotSin
        let rnz = v.normal.x * rotSin + v.normal.z * rotCos
        return (
            pos: SIMD3<Float>(rx, v.pos.y, rz),
            normal: SIMD3<Float>(rnx, v.normal.y, rnz)
        )
    }

    let minX = wallPoints.map(\.x).min()!
    let maxX = wallPoints.map(\.x).max()!
    let minZ = wallPoints.map(\.z).min()!
    let maxZ = wallPoints.map(\.z).max()!

    print("Rotated bounds: X[\(String(format: "%.2f", minX)) to \(String(format: "%.2f", maxX))], Z[\(String(format: "%.2f", minZ)) to \(String(format: "%.2f", maxZ))]")
    print("Bounding box: \(String(format: "%.2f", maxX - minX))m x \(String(format: "%.2f", maxZ - minZ))m")

    // Step 3: RANSAC wall line fitting (on rotated points — walls should be axis-aligned now)
    print("\n--- RANSAC Wall Line Fitting ---")
    let rawWalls = fitWallLines(from: wallPoints)
    print("Found \(rawWalls.count) raw wall lines")

    for (i, w) in rawWalls.enumerated() {
        print("  Wall \(i): len=\(String(format: "%.2f", w.length))m  angle=\(String(format: "%.1f", w.angle * 180 / .pi))°  inliers=\(w.inlierCount)  thickness=\(String(format: "%.0f", w.thickness * 1000))mm")
    }

    // Step 4: Regularize (snap to axis — should be close now after rotation)
    let walls = regularizeWalls(rawWalls)
    print("\nAfter regularization:")
    for (i, w) in walls.enumerated() {
        print("  Wall \(i): len=\(String(format: "%.2f", w.length))m  angle=\(String(format: "%.1f", w.angle * 180 / .pi))°  \(w.isXAligned ? "X-ALIGNED" : w.isZAligned ? "Z-ALIGNED" : "diagonal")")
    }

    // Step 5: Measure inner walls
    let dimensions = measureInnerWalls(walls)

    // Use raw dimensions as-is — X = horizontal width, Z = vertical depth in plan view
    let finalDimensions = dimensions

    print("\n=== ROOM DIMENSIONS ===")
    print("Width (X, horizontal):  \(String(format: "%.3f", dimensions.width))m  (\(Int(dimensions.width * 1000))mm)")
    print("Depth (Z, vertical):    \(String(format: "%.3f", dimensions.depth))m  (\(Int(dimensions.depth * 1000))mm)")
    print("Area:   \(String(format: "%.1f", dimensions.width * dimensions.depth)) m²")

    // Step 6: Detect openings (use rotated vertices)
    let openings = detectOpenings(walls: walls, allVertices: rotatedVertices, floorY: floorY)
    print("\n=== OPENINGS DETECTED ===")
    for o in openings {
        print("  \(o.kind.rawValue): \(Int(o.width * 1000))mm at (\(String(format: "%.2f", o.position.x)), \(String(format: "%.2f", o.position.z)))")
    }

    // Step 6b: Detect objects (benches, toilets, fans, fireplaces, etc.)
    print("\n=== OBJECT DETECTION ===")
    let detectedObjects = detectObjects(from: rotatedVertices, floorY: floorY)
    print("Total objects detected: \(detectedObjects.count)")

    // Step 7: Floor points for area fill (rotated)
    var floorPoints: [(x: Float, z: Float)] = []
    for v in rotatedVertices {
        if v.pos.y >= floorY - 0.1 && v.pos.y <= floorY + 0.5 && v.normal.y > 0.5 {
            floorPoints.append((x: v.pos.x, z: v.pos.z))
        }
    }

    // Step 8: Calibration comparison
    // X axis (horizontal in plan) = 5000mm short wall
    // Z axis (vertical in plan) = 5950mm long wall
    let refWidth: Float = 5.000  // Reference room: 5000mm (horizontal/X)
    let refDepth: Float = 5.950  // Reference room: 5950mm (vertical/Z)

    print("\n=== CALIBRATION vs REFERENCE ===")
    print("Reference:  \(Int(refWidth * 1000))mm x \(Int(refDepth * 1000))mm")
    print("Measured:   \(Int(finalDimensions.width * 1000))mm x \(Int(finalDimensions.depth * 1000))mm")
    if finalDimensions.width > 0 && finalDimensions.depth > 0 {
        let widthError = finalDimensions.width - refWidth
        let depthError = finalDimensions.depth - refDepth
        print("Error:      \(widthError > 0 ? "+" : "")\(Int(widthError * 1000))mm width, \(depthError > 0 ? "+" : "")\(Int(depthError * 1000))mm depth")
        print("Error %%:    \(String(format: "%.1f", abs(widthError / refWidth) * 100))%% width, \(String(format: "%.1f", abs(depthError / refDepth) * 100))%% depth")
    }

    // Generate SVG
    return generateSVG(
        walls: walls,
        openings: openings,
        dimensions: finalDimensions,
        wallPoints: wallPoints,
        floorPoints: floorPoints,
        allBounds: (minX: minX, maxX: maxX, minZ: minZ, maxZ: maxZ),
        detectedObjects: detectedObjects
    )
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Usage: swift mesh-to-floorplan.swift /path/to/scan.studiio")
    exit(1)
}

let bundlePath = args[1]
let meshDir = URL(fileURLWithPath: bundlePath).appendingPathComponent("mesh")

guard FileManager.default.fileExists(atPath: meshDir.path) else {
    print("ERROR: No mesh/ directory found in \(bundlePath)")
    exit(1)
}

let svg = extractFloorPlan(meshDir: meshDir)

let outputURL = URL(fileURLWithPath: bundlePath).deletingLastPathComponent()
    .appendingPathComponent("floorplan.svg")

try? svg.write(toFile: outputURL.path, atomically: true, encoding: .utf8)
print("\nFloor plan written to: \(outputURL.path)")

// Also write a JSON report
let reportURL = URL(fileURLWithPath: bundlePath).deletingLastPathComponent()
    .appendingPathComponent("floorplan-report.json")

let report: [String: Any] = [
    "bundle": bundlePath,
    "timestamp": ISO8601DateFormatter().string(from: Date()),
    "tool_version": "2.0",
    "reference_room": ["width_mm": 5950, "depth_mm": 5000],
]
if let reportData = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
    try? reportData.write(to: reportURL)
}

print("Open floorplan.svg in browser to view.")
