#!/usr/bin/env swift
//  dollshouse.swift — Studiio Scanner comprehensive datapoint viewer
//  Runs full mesh geometry analysis and renders ALL detected features as
//  dense 3D datapoints with a transparent wireframe mesh overlay.

import Foundation
import simd

// MARK: - Binary mesh loading

struct MeshAnchor {
    let transform: simd_float4x4
    let positions: [SIMD3<Float>]
    let normals: [SIMD3<Float>]
    let indices: [UInt32]
}

func loadMeshBinary(_ url: URL) -> MeshAnchor? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    var offset = 0
    func read<T>(_ type: T.Type) -> T {
        let size = MemoryLayout<T>.size
        let value = data[offset..<offset+size].withUnsafeBytes { $0.load(as: T.self) }
        offset += size
        return value
    }
    let transform = read(simd_float4x4.self)
    let vc = Int(read(UInt32.self))
    var pos: [SIMD3<Float>] = []; pos.reserveCapacity(vc)
    for _ in 0..<vc { pos.append(read(SIMD3<Float>.self)) }
    let nc = Int(read(UInt32.self))
    var nrm: [SIMD3<Float>] = []; nrm.reserveCapacity(nc)
    for _ in 0..<nc { nrm.append(read(SIMD3<Float>.self)) }
    let ic = Int(read(UInt32.self))
    var idx: [UInt32] = []; idx.reserveCapacity(ic)
    for _ in 0..<ic { idx.append(read(UInt32.self)) }
    return MeshAnchor(transform: transform, positions: pos, normals: nrm, indices: idx)
}

// MARK: - Feature types for the viewer

struct Feature {
    let type: String     // wall, door, window, surface, corner, step, column, recess, ceiling, boundary
    let subtype: String  // e.g. "standardDoor", "kitchenBench", "wallCorner"
    let label: String    // display label
    let colour: String   // hex e.g. "FF9800"
    let px: Float, py: Float, pz: Float
    let dx: Float, dy: Float, dz: Float  // dimensions (0 for points)
    let rotation: Float  // Y rotation in radians
    let dimText: String  // dimension string e.g. "820mm"
}

// MARK: - Comprehensive Mesh Analyser

class MeshAnalyser {
    let positions: [SIMD3<Float>]
    let normals: [SIMD3<Float>]
    let floorY: Float
    let ceilingY: Float
    let wallAngle: Float  // dominant wall angle for alignment

    var features: [Feature] = []

    init(positions: [SIMD3<Float>], normals: [SIMD3<Float>]) {
        self.positions = positions
        self.normals = normals

        // Find floor
        var floorCandidates: [Float] = []
        for i in 0..<positions.count where normals[i].y > 0.8 {
            floorCandidates.append(positions[i].y)
        }
        floorCandidates.sort()
        if floorCandidates.count > 100 {
            self.floorY = floorCandidates[floorCandidates.count / 10]
        } else {
            self.floorY = floorCandidates.first ?? positions.map(\.y).min() ?? 0
        }

        // Find ceiling
        var ceilCandidates: [Float] = []
        for i in 0..<positions.count where normals[i].y < -0.8 && positions[i].y > self.floorY + 1.5 {
            ceilCandidates.append(positions[i].y)
        }
        ceilCandidates.sort()
        if ceilCandidates.count > 50 {
            self.ceilingY = ceilCandidates[ceilCandidates.count * 9 / 10]
        } else {
            self.ceilingY = ceilCandidates.last ?? (self.floorY + 2.4)
        }

        // Find dominant wall angle
        self.wallAngle = MeshAnalyser.findWallAngle(positions: positions, normals: normals, floorY: self.floorY)

        print("Floor: \(String(format: "%.2f", floorY))m, Ceiling: \(String(format: "%.2f", ceilingY))m, Height: \(String(format: "%.2f", ceilingY - floorY))m")
        print("Wall angle: \(String(format: "%.1f", wallAngle * 180 / .pi)) degrees")
    }

    static func findWallAngle(positions: [SIMD3<Float>], normals: [SIMD3<Float>], floorY: Float) -> Float {
        let binCount = 180
        var histogram = Array(repeating: 0, count: binCount)
        for i in 0..<positions.count {
            guard abs(normals[i].y) < 0.3 else { continue }
            guard positions[i].y >= floorY + 0.5 && positions[i].y <= floorY + 1.5 else { continue }
            var angle = atan2(normals[i].z, normals[i].x)
            if angle < 0 { angle += .pi }
            let bin = min(Int(angle / .pi * Float(binCount)), binCount - 1)
            histogram[bin] += 1
        }
        var smoothed = Array(repeating: 0, count: binCount)
        for i in 0..<binCount {
            var sum = 0
            for d in -3...3 { sum += histogram[(i + d + binCount) % binCount] }
            smoothed[i] = sum
        }
        let peakBin = smoothed.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
        let normalAngle = Float(peakBin) / Float(binCount) * .pi
        return normalAngle - .pi / 2
    }

    // MARK: - Run all detections

    func analyse() {
        detectWallSegments()
        detectOpenings()
        detectHorizontalSurfaces()
        detectFloorBoundary()
        detectVerticalFeatures()
        detectCeilingFeatures()
        detectSteps()

        print("Total features detected: \(features.count)")
    }

    // MARK: - Wall Segment Detection (RANSAC)

    func detectWallSegments() {
        // Collect wall points at 0.5-1.5m height
        var wallPts: [(x: Float, z: Float)] = []
        for i in 0..<positions.count {
            guard abs(normals[i].y) < 0.3 else { continue }
            guard positions[i].y >= floorY + 0.5 && positions[i].y <= floorY + 1.5 else { continue }
            wallPts.append((x: positions[i].x, z: positions[i].z))
        }

        guard wallPts.count >= 20 else {
            print("  Walls: insufficient points (\(wallPts.count))")
            return
        }

        var remaining = wallPts
        let minInliers = max(15, wallPts.count / 60)
        var wallCount = 0

        for _ in 0..<20 {
            guard remaining.count >= minInliers else { break }

            var bestInliers: [(x: Float, z: Float)] = []
            var bestOutliers: [(x: Float, z: Float)] = []
            var bestStart = SIMD2<Float>(0, 0)
            var bestEnd = SIMD2<Float>(0, 0)
            var bestThickness: Float = 0

            for _ in 0..<500 {
                let i1 = Int.random(in: 0..<remaining.count)
                var i2 = Int.random(in: 0..<remaining.count)
                while i2 == i1 { i2 = Int.random(in: 0..<remaining.count) }

                let p1 = remaining[i1], p2 = remaining[i2]
                let dx = p2.x - p1.x, dz = p2.z - p1.z
                let len = sqrt(dx * dx + dz * dz)
                guard len > 0.2 else { continue }

                let nx = -dz / len, nz = dx / len

                var inliers: [(x: Float, z: Float)] = []
                var outliers: [(x: Float, z: Float)] = []

                for p in remaining {
                    let dist = abs((p.x - p1.x) * nx + (p.z - p1.z) * nz)
                    if dist < 0.06 { inliers.append(p) } else { outliers.append(p) }
                }

                if inliers.count > bestInliers.count {
                    var minT: Float = .greatestFiniteMagnitude
                    var maxT: Float = -.greatestFiniteMagnitude
                    var perpDists: [Float] = []

                    for p in inliers {
                        let t = (p.x - p1.x) * (dx / len) + (p.z - p1.z) * (dz / len)
                        minT = min(minT, t); maxT = max(maxT, t)
                        perpDists.append((p.x - p1.x) * nx + (p.z - p1.z) * nz)
                    }
                    perpDists.sort()
                    let thickness = perpDists.count > 10 ?
                        perpDists[perpDists.count * 9 / 10] - perpDists[perpDists.count / 10] : 0.08

                    let wallLen = maxT - minT
                    if wallLen > 0.4 {
                        bestInliers = inliers
                        bestOutliers = outliers
                        bestStart = SIMD2(p1.x + (dx / len) * minT, p1.z + (dz / len) * minT)
                        bestEnd = SIMD2(p1.x + (dx / len) * maxT, p1.z + (dz / len) * maxT)
                        bestThickness = max(thickness, 0.05)
                    }
                }
            }

            guard bestInliers.count >= minInliers else { break }

            let wallLen = simd_distance(bestStart, bestEnd)
            let midX = (bestStart.x + bestEnd.x) / 2
            let midZ = (bestStart.y + bestEnd.y) / 2
            let angle = atan2(bestEnd.y - bestStart.y, bestEnd.x - bestStart.x)

            features.append(Feature(
                type: "wall", subtype: "wall",
                label: "\(Int(wallLen * 1000))mm",
                colour: "78909C",
                px: midX, py: floorY + (ceilingY - floorY) / 2, pz: midZ,
                dx: wallLen, dy: ceilingY - floorY, dz: bestThickness,
                rotation: angle,
                dimText: "\(Int(wallLen * 1000))mm x \(Int(bestThickness * 1000))mm"
            ))

            // Add wall endpoints as corner candidates
            features.append(Feature(
                type: "corner", subtype: "wallEnd",
                label: "",
                colour: "B0BEC5",
                px: bestStart.x, py: floorY, pz: bestStart.y,
                dx: 0.08, dy: ceilingY - floorY, dz: 0.08,
                rotation: 0,
                dimText: ""
            ))
            features.append(Feature(
                type: "corner", subtype: "wallEnd",
                label: "",
                colour: "B0BEC5",
                px: bestEnd.x, py: floorY, pz: bestEnd.y,
                dx: 0.08, dy: ceilingY - floorY, dz: 0.08,
                rotation: 0,
                dimText: ""
            ))

            wallCount += 1
            remaining = bestOutliers

            print("  Wall \(wallCount): \(Int(wallLen * 1000))mm, thickness \(Int(bestThickness * 1000))mm, \(bestInliers.count) pts")
        }

        print("  Walls detected: \(wallCount)")
    }

    // MARK: - Opening Detection (doors & windows in walls)

    func detectOpenings() {
        let wallFeatures = features.filter { $0.type == "wall" }
        guard !wallFeatures.isEmpty else { return }

        var openingCount = 0

        for wall in wallFeatures {
            guard wall.dx > 1.0 else { continue }

            let cosA = cos(wall.rotation)
            let sinA = sin(wall.rotation)
            let halfLen = wall.dx / 2
            let startX = wall.px - cosA * halfLen
            let startZ = wall.pz - sinA * halfLen
            let nx = -sinA, nz = cosA  // wall normal

            let segSize: Float = 0.08
            let segCount = Int(wall.dx / segSize)
            guard segCount > 3 else { continue }

            var densityLow = Array(repeating: 0, count: segCount)   // 0-0.5m
            var densityMid = Array(repeating: 0, count: segCount)   // 0.5-2.0m
            var densityHigh = Array(repeating: 0, count: segCount)  // 2.0m+

            for i in 0..<positions.count {
                let perpDist = abs((positions[i].x - startX) * nx + (positions[i].z - startZ) * nz)
                guard perpDist < 0.15 && abs(normals[i].y) < 0.4 else { continue }

                let t = (positions[i].x - startX) * cosA + (positions[i].z - startZ) * sinA
                let seg = Int(t / segSize)
                guard seg >= 0 && seg < segCount else { continue }

                let h = positions[i].y - floorY
                if h >= 0 && h < 0.5 { densityLow[seg] += 1 }
                else if h >= 0.5 && h < 2.0 { densityMid[seg] += 1 }
                else if h >= 2.0 { densityHigh[seg] += 1 }
            }

            let avgDensity = densityMid.reduce(0, +) / max(1, segCount)
            let gapThreshold = max(2, avgDensity / 4)

            var inGap = false, gapStart = 0

            for seg in 0...segCount {
                let sparse = seg < segCount ? densityMid[seg] < gapThreshold : false

                if sparse && !inGap {
                    inGap = true; gapStart = seg
                } else if !sparse && inGap {
                    inGap = false
                    let gapWidth = Float(seg - gapStart) * segSize

                    if gapWidth >= 0.5 && gapWidth <= 3.0 {
                        let center = (Float(gapStart) + Float(seg)) / 2 * segSize
                        let posX = startX + cosA * center
                        let posZ = startZ + sinA * center

                        // Check for sill (wall below gap = window)
                        let lowDensity = (gapStart..<min(seg, segCount)).map { densityLow[$0] }.reduce(0, +)
                        let hasWallBelow = lowDensity > (seg - gapStart) * 2

                        let kind: String
                        let label: String
                        let colour: String
                        let height: Float

                        if hasWallBelow {
                            kind = "window"
                            label = "WIN \(Int(gapWidth * 1000))"
                            colour = "29B6F6"
                            height = 1.2  // window height
                        } else if gapWidth >= 1.5 {
                            kind = "slidingDoor"
                            label = "SD \(Int(gapWidth * 1000))"
                            colour = "66BB6A"
                            height = 2.1
                        } else if gapWidth >= 1.2 {
                            kind = "doubleDoor"
                            label = "DD \(Int(gapWidth * 1000))"
                            colour = "66BB6A"
                            height = 2.1
                        } else {
                            kind = "door"
                            label = "DR \(Int(gapWidth * 1000))"
                            colour = "66BB6A"
                            height = 2.1
                        }

                        features.append(Feature(
                            type: "opening", subtype: kind,
                            label: label, colour: colour,
                            px: posX, py: floorY + (hasWallBelow ? 0.9 : 0),
                            pz: posZ,
                            dx: gapWidth, dy: height, dz: 0.1,
                            rotation: wall.rotation,
                            dimText: "\(Int(gapWidth * 1000))mm"
                        ))
                        openingCount += 1
                        print("  \(kind): \(Int(gapWidth * 1000))mm at (\(String(format: "%.2f", posX)), \(String(format: "%.2f", posZ)))")
                    }
                }
            }
        }

        print("  Openings detected: \(openingCount)")
    }

    // MARK: - Horizontal Surface Detection

    func detectHorizontalSurfaces() {
        // Height bands with proper classification
        struct HeightBand {
            let minH: Float, maxH: Float
            let categories: [(minW: Float, maxW: Float, minD: Float, maxD: Float, cat: String, label: String, colour: String)]
        }

        let bands: [HeightBand] = [
            // Very low: 100-300mm — steps, plinths, low shelves
            HeightBand(minH: 0.10, maxH: 0.30, categories: [
                (0.2, 4.0, 0.2, 2.0, "step", "STEP", "8D6E63"),
            ]),
            // Low: 300-550mm — coffee tables, toilet seats, bath rims, ottomans
            HeightBand(minH: 0.30, maxH: 0.55, categories: [
                (0.25, 0.55, 0.35, 0.80, "toilet", "WC", "4FC3F7"),      // toilet-sized
                (0.5, 2.0, 0.5, 1.0, "bathtub", "BATH", "4FC3F7"),       // long narrow = bath rim
                (0.3, 1.5, 0.3, 1.5, "coffeeTable", "C.TABLE", "81C784"),// square-ish = coffee table
            ]),
            // Medium-low: 550-750mm — desks, dining tables, beds
            HeightBand(minH: 0.55, maxH: 0.78, categories: [
                (1.2, 2.2, 0.8, 1.8, "bed", "BED", "BA68C8"),           // large rectangle = bed
                (0.8, 3.0, 0.6, 1.5, "diningTable", "D.TABLE", "81C784"),// medium = dining table
                (0.5, 1.8, 0.3, 0.8, "desk", "DESK", "81C784"),         // narrow = desk
            ]),
            // Counter height: 780-920mm — vanities, kitchen benches, islands
            HeightBand(minH: 0.78, maxH: 0.95, categories: [
                (1.5, 5.0, 0.4, 0.8, "kitchenBench", "BENCH", "FF8A65"),  // long narrow = bench
                (0.8, 2.5, 0.6, 1.5, "kitchenIsland", "ISLAND", "FF8A65"),// squarish big = island
                (0.4, 1.5, 0.3, 0.7, "vanity", "VAN", "4FC3F7"),         // smaller = vanity
            ]),
            // High counter: 950-1100mm — bar counters
            HeightBand(minH: 0.95, maxH: 1.10, categories: [
                (0.5, 4.0, 0.3, 1.0, "barCounter", "BAR", "FF8A65"),
            ]),
        ]

        var surfaceCount = 0

        for band in bands {
            let bandMin = floorY + band.minH
            let bandMax = floorY + band.maxH

            var surfacePoints: [SIMD3<Float>] = []
            for i in 0..<positions.count where normals[i].y > 0.6 && positions[i].y >= bandMin && positions[i].y <= bandMax {
                surfacePoints.append(positions[i])
            }

            guard surfacePoints.count > 15 else { continue }

            let clusters = clusterPoints2D(surfacePoints, cellSize: 0.2, minPoints: 8)

            for cluster in clusters {
                let minX = cluster.map(\.x).min()!
                let maxX = cluster.map(\.x).max()!
                let minZ = cluster.map(\.z).min()!
                let maxZ = cluster.map(\.z).max()!
                let avgY = cluster.map(\.y).reduce(0, +) / Float(cluster.count)

                let width = maxX - minX
                let depth = maxZ - minZ
                let heightAboveFloor = avgY - floorY

                guard width > 0.2 && depth > 0.15 && width < 6.0 && depth < 3.0 else { continue }

                // Find best matching category
                var matched = false
                for cat in band.categories {
                    let w = max(width, depth), d = min(width, depth)
                    if w >= cat.minW && w <= cat.maxW && d >= cat.minD && d <= cat.maxD {
                        features.append(Feature(
                            type: "surface", subtype: cat.cat,
                            label: cat.label,
                            colour: cat.colour,
                            px: (minX + maxX) / 2, py: avgY, pz: (minZ + maxZ) / 2,
                            dx: width, dy: heightAboveFloor, dz: depth,
                            rotation: 0,
                            dimText: "\(Int(width * 1000))x\(Int(depth * 1000))mm h:\(Int(heightAboveFloor * 1000))"
                        ))
                        surfaceCount += 1
                        matched = true
                        print("  \(cat.label): \(Int(width * 1000))x\(Int(depth * 1000))mm at h:\(Int(heightAboveFloor * 1000))mm (\(cluster.count) pts)")
                        break
                    }
                }

                // Fallback: unknown surface
                if !matched && cluster.count > 20 {
                    features.append(Feature(
                        type: "surface", subtype: "surface",
                        label: "SURF",
                        colour: "9E9E9E",
                        px: (minX + maxX) / 2, py: avgY, pz: (minZ + maxZ) / 2,
                        dx: width, dy: heightAboveFloor, dz: depth,
                        rotation: 0,
                        dimText: "\(Int(width * 1000))x\(Int(depth * 1000))mm h:\(Int(heightAboveFloor * 1000))"
                    ))
                    surfaceCount += 1
                    print("  SURF: \(Int(width * 1000))x\(Int(depth * 1000))mm at h:\(Int(heightAboveFloor * 1000))mm (\(cluster.count) pts)")
                }
            }
        }

        print("  Surfaces detected: \(surfaceCount)")
    }

    // MARK: - Floor Boundary Outline

    func detectFloorBoundary() {
        // Collect floor points and find the convex-ish outline
        var floorPts: [(x: Float, z: Float)] = []
        for i in 0..<positions.count where normals[i].y > 0.7 && positions[i].y >= floorY - 0.1 && positions[i].y <= floorY + 0.15 {
            floorPts.append((x: positions[i].x, z: positions[i].z))
        }

        guard floorPts.count > 50 else { return }

        // Grid-based boundary: find occupied cells and mark edge cells
        let cellSize: Float = 0.25
        var grid = Set<String>()
        for p in floorPts {
            let gx = Int(floor(p.x / cellSize))
            let gz = Int(floor(p.z / cellSize))
            grid.insert("\(gx),\(gz)")
        }

        var boundaryCount = 0
        for key in grid {
            let parts = key.split(separator: ",")
            guard parts.count == 2, let gx = Int(parts[0]), let gz = Int(parts[1]) else { continue }

            // Check if this cell is on the edge (missing neighbour)
            var isEdge = false
            for dx in -1...1 {
                for dz in -1...1 {
                    if dx == 0 && dz == 0 { continue }
                    if !grid.contains("\(gx + dx),\(gz + dz)") {
                        isEdge = true
                        break
                    }
                }
                if isEdge { break }
            }

            if isEdge {
                let worldX = (Float(gx) + 0.5) * cellSize
                let worldZ = (Float(gz) + 0.5) * cellSize
                features.append(Feature(
                    type: "boundary", subtype: "floor",
                    label: "", colour: "FF9800",
                    px: worldX, py: floorY, pz: worldZ,
                    dx: cellSize * 0.8, dy: 0.02, dz: cellSize * 0.8,
                    rotation: 0, dimText: ""
                ))
                boundaryCount += 1
            }
        }

        print("  Boundary cells: \(boundaryCount)")
    }

    // MARK: - Vertical Features (wall protrusions, cabinets, recesses)

    func detectVerticalFeatures() {
        // Look for vertical surfaces NOT on main walls — these are cabinets, shelves, partitions
        let wallFeatures = features.filter { $0.type == "wall" }

        // Collect vertical points between 0.5m and 2m
        var vertPts: [(pos: SIMD3<Float>, normal: SIMD3<Float>)] = []
        for i in 0..<positions.count {
            guard abs(normals[i].y) < 0.3 else { continue }
            guard positions[i].y >= floorY + 0.3 && positions[i].y <= floorY + 2.0 else { continue }
            vertPts.append((pos: positions[i], normal: normals[i]))
        }

        // Remove points near detected walls
        var nonWallPts: [(pos: SIMD3<Float>, normal: SIMD3<Float>)] = []
        for pt in vertPts {
            var nearWall = false
            for wall in wallFeatures {
                let cosA = cos(wall.rotation)
                let sinA = sin(wall.rotation)
                let nx = -sinA, nz = cosA
                let perpDist = abs((pt.pos.x - wall.px) * nx + (pt.pos.z - wall.pz) * nz)
                if perpDist < 0.15 {
                    let along = (pt.pos.x - wall.px) * cosA + (pt.pos.z - wall.pz) * sinA
                    if abs(along) < wall.dx / 2 + 0.1 {
                        nearWall = true
                        break
                    }
                }
            }
            if !nearWall { nonWallPts.append(pt) }
        }

        guard nonWallPts.count > 30 else {
            print("  Vertical features: 0 (insufficient non-wall points)")
            return
        }

        // Cluster non-wall vertical points
        let pts3D = nonWallPts.map { $0.pos }
        let clusters = clusterPoints2D(pts3D, cellSize: 0.25, minPoints: 10)

        var featureCount = 0
        for cluster in clusters {
            let minX = cluster.map(\.x).min()!
            let maxX = cluster.map(\.x).max()!
            let minY = cluster.map(\.y).min()!
            let maxY = cluster.map(\.y).max()!
            let minZ = cluster.map(\.z).min()!
            let maxZ = cluster.map(\.z).max()!

            let width = maxX - minX
            let height = maxY - minY
            let depth = maxZ - minZ
            let longSide = max(width, depth)
            let shortSide = min(width, depth)

            guard longSide > 0.3 && height > 0.3 else { continue }

            let cat: String, label: String, colour: String

            if shortSide < 0.15 && longSide > 0.5 {
                // Thin vertical surface — partition, screen, cabinet face
                cat = "partition"
                label = "PART"
                colour = "78909C"
            } else if height > 1.5 && longSide > 0.4 {
                // Tall feature — wardrobe, tall cabinet, column
                if shortSide < 0.4 {
                    cat = "column"
                    label = "COL"
                    colour = "90A4AE"
                } else {
                    cat = "wardrobe"
                    label = "BIR"
                    colour = "BA68C8"
                }
            } else if height > 0.5 && longSide > 0.3 {
                cat = "cabinet"
                label = "CAB"
                colour = "BCAAA4"
            } else {
                continue
            }

            features.append(Feature(
                type: "vertical", subtype: cat,
                label: label, colour: colour,
                px: (minX + maxX) / 2, py: (minY + maxY) / 2, pz: (minZ + maxZ) / 2,
                dx: width, dy: height, dz: depth,
                rotation: 0,
                dimText: "\(Int(longSide * 1000))x\(Int(shortSide * 1000))mm h:\(Int(height * 1000))"
            ))
            featureCount += 1
            print("  \(label): \(Int(width * 1000))x\(Int(depth * 1000))mm h:\(Int(height * 1000))mm (\(cluster.count) pts)")
        }

        print("  Vertical features: \(featureCount)")
    }

    // MARK: - Ceiling Features

    func detectCeilingFeatures() {
        let ceilMin = ceilingY - 0.35
        let ceilMax = ceilingY + 0.1

        var ceilPts: [SIMD3<Float>] = []
        for i in 0..<positions.count where positions[i].y >= ceilMin && positions[i].y <= ceilMax && normals[i].y < -0.3 {
            ceilPts.append(positions[i])
        }

        let clusters = clusterPoints2D(ceilPts, cellSize: 0.15, minPoints: 8)
        var featureCount = 0

        for cluster in clusters {
            let minX = cluster.map(\.x).min()!
            let maxX = cluster.map(\.x).max()!
            let minZ = cluster.map(\.z).min()!
            let maxZ = cluster.map(\.z).max()!
            let w = maxX - minX, d = maxZ - minZ

            let aspect = min(w, d) / max(w, d, 0.01)

            if w > 0.8 && w < 1.6 && d > 0.8 && d < 1.6 && aspect > 0.5 {
                // Ceiling fan
                features.append(Feature(
                    type: "ceiling", subtype: "fan",
                    label: "FAN", colour: "90A4AE",
                    px: (minX + maxX) / 2, py: ceilingY, pz: (minZ + maxZ) / 2,
                    dx: w, dy: 0.3, dz: d,
                    rotation: 0,
                    dimText: "\(Int(w * 1000))x\(Int(d * 1000))mm"
                ))
                featureCount += 1
                print("  FAN: \(Int(w * 1000))x\(Int(d * 1000))mm")
            } else if w > 0.1 && w < 0.5 && d > 0.1 && d < 0.5 && aspect > 0.5 {
                // Light fitting
                features.append(Feature(
                    type: "ceiling", subtype: "light",
                    label: "LIGHT", colour: "FFF176",
                    px: (minX + maxX) / 2, py: ceilingY, pz: (minZ + maxZ) / 2,
                    dx: w, dy: 0.15, dz: d,
                    rotation: 0,
                    dimText: "\(Int(w * 1000))mm"
                ))
                featureCount += 1
            }
        }

        print("  Ceiling features: \(featureCount)")
    }

    // MARK: - Step Detection

    func detectSteps() {
        // Look for horizontal surfaces at small height increments above floor
        var stepPts: [SIMD3<Float>] = []
        for i in 0..<positions.count where normals[i].y > 0.7
            && positions[i].y > floorY + 0.08 && positions[i].y < floorY + 0.35 {
            stepPts.append(positions[i])
        }

        let clusters = clusterPoints2D(stepPts, cellSize: 0.2, minPoints: 10)
        var stepCount = 0

        for cluster in clusters {
            let w = cluster.map(\.x).max()! - cluster.map(\.x).min()!
            let d = cluster.map(\.z).max()! - cluster.map(\.z).min()!
            let avgY = cluster.map(\.y).reduce(0, +) / Float(cluster.count)
            let h = avgY - floorY

            guard max(w, d) > 0.3 && h > 0.05 else { continue }

            features.append(Feature(
                type: "step", subtype: "step",
                label: "STEP \(Int(h * 1000))mm", colour: "8D6E63",
                px: (cluster.map(\.x).min()! + cluster.map(\.x).max()!) / 2,
                py: avgY,
                pz: (cluster.map(\.z).min()! + cluster.map(\.z).max()!) / 2,
                dx: w, dy: h, dz: d,
                rotation: 0,
                dimText: "\(Int(w * 1000))x\(Int(d * 1000))mm h:\(Int(h * 1000))"
            ))
            stepCount += 1
        }

        print("  Steps: \(stepCount)")
    }

    // MARK: - Clustering Helper

    func clusterPoints2D(_ points: [SIMD3<Float>], cellSize: Float, minPoints: Int) -> [[SIMD3<Float>]] {
        guard !points.isEmpty else { return [] }

        var grid: [String: [SIMD3<Float>]] = [:]
        for p in points {
            let key = "\(Int(floor(p.x / cellSize))),\(Int(floor(p.z / cellSize)))"
            grid[key, default: []].append(p)
        }

        var visited = Set<String>()
        var clusters: [[SIMD3<Float>]] = []

        for key in grid.keys {
            guard !visited.contains(key) else { continue }
            var cluster: [SIMD3<Float>] = []
            var queue = [key]
            while !queue.isEmpty {
                let current = queue.removeFirst()
                guard !visited.contains(current) else { continue }
                visited.insert(current)
                if let pts = grid[current] { cluster.append(contentsOf: pts) }
                let parts = current.split(separator: ",")
                guard parts.count == 2, let cx = Int(parts[0]), let cz = Int(parts[1]) else { continue }
                for ddx in -1...1 {
                    for ddz in -1...1 {
                        if ddx == 0 && ddz == 0 { continue }
                        let nb = "\(cx + ddx),\(cz + ddz)"
                        if grid[nb] != nil && !visited.contains(nb) { queue.append(nb) }
                    }
                }
            }
            if cluster.count >= minPoints { clusters.append(cluster) }
        }
        return clusters
    }
}

// MARK: - Main

guard CommandLine.arguments.count >= 2 else {
    print("Usage: dollshouse <path-to.studiio>")
    exit(1)
}

let bundlePath = CommandLine.arguments[1]
let bundleURL = URL(fileURLWithPath: bundlePath)
let meshDir = bundleURL.appendingPathComponent("mesh")

// Load mesh
guard let indexData = try? Data(contentsOf: meshDir.appendingPathComponent("index.json")),
      let indexJSON = try? JSONSerialization.jsonObject(with: indexData) as? [String: Any],
      let anchorList = indexJSON["anchors"] as? [[String: Any]] else {
    print("Cannot load mesh index"); exit(1)
}

var allPositions: [SIMD3<Float>] = []
var allNormals: [SIMD3<Float>] = []
var allIndices: [UInt32] = []

for anchor in anchorList {
    guard let file = anchor["file"] as? String else { continue }
    guard let mesh = loadMeshBinary(meshDir.appendingPathComponent(file)) else { continue }
    let base = UInt32(allPositions.count)
    let t = mesh.transform
    for i in 0..<mesh.positions.count {
        let lp = mesh.positions[i]
        let wp = t * SIMD4<Float>(lp.x, lp.y, lp.z, 1.0)
        allPositions.append(SIMD3<Float>(wp.x, wp.y, wp.z))
        if i < mesh.normals.count {
            let ln = mesh.normals[i]
            let wn = t * SIMD4<Float>(ln.x, ln.y, ln.z, 0.0)
            allNormals.append(normalize(SIMD3<Float>(wn.x, wn.y, wn.z)))
        } else {
            allNormals.append(SIMD3<Float>(0, 1, 0))
        }
    }
    for idx in mesh.indices { allIndices.append(base + idx) }
}

print("Loaded \(anchorList.count) mesh anchors: \(allPositions.count) vertices, \(allIndices.count / 3) triangles")

// Run comprehensive analysis
let analyser = MeshAnalyser(positions: allPositions, normals: allNormals)
analyser.analyse()

let floorY = analyser.floorY
let ceilingY = analyser.ceilingY

// Prepare wireframe mesh (ceiling-cut, decimated)
let ceilingCutoff = ceilingY - 0.1
var keptIdx: [UInt32] = []
for i in stride(from: 0, to: allIndices.count, by: 3) {
    let y0 = allPositions[Int(allIndices[i])].y
    let y1 = allPositions[Int(allIndices[i+1])].y
    let y2 = allPositions[Int(allIndices[i+2])].y
    if y0 < ceilingCutoff || y1 < ceilingCutoff || y2 < ceilingCutoff {
        keptIdx.append(allIndices[i]); keptIdx.append(allIndices[i+1]); keptIdx.append(allIndices[i+2])
    }
}
let maxTri = 50000
let step = max(1, keptIdx.count / 3 / maxTri)
var wireIdx: [UInt32] = []
for i in stride(from: 0, to: keptIdx.count, by: 3 * step) {
    wireIdx.append(keptIdx[i]); wireIdx.append(keptIdx[i+1]); wireIdx.append(keptIdx[i+2])
}
print("Wireframe: \(wireIdx.count / 3) triangles")

// Encode binary
func encFloats(_ a: [Float]) -> String { a.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString() }
func encUints(_ a: [UInt32]) -> String { a.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString() }

var posFlat: [Float] = []
posFlat.reserveCapacity(allPositions.count * 3)
for p in allPositions { posFlat.append(p.x); posFlat.append(p.y); posFlat.append(p.z) }

let posB64 = encFloats(posFlat)
let idxB64 = encUints(wireIdx)

// Build features JSON
var featJSON = "["
for (i, f) in analyser.features.enumerated() {
    if i > 0 { featJSON += "," }
    let escapedLabel = f.label.replacingOccurrences(of: "'", with: "\\'")
    let escapedDim = f.dimText.replacingOccurrences(of: "'", with: "\\'")
    featJSON += "{\"t\":\"\(f.type)\",\"s\":\"\(f.subtype)\",\"l\":\"\(escapedLabel)\",\"c\":\"\(f.colour)\","
    featJSON += "\"px\":\(f.px),\"py\":\(f.py),\"pz\":\(f.pz),"
    featJSON += "\"dx\":\(f.dx),\"dy\":\(f.dy),\"dz\":\(f.dz),"
    featJSON += "\"r\":\(f.rotation),\"dim\":\"\(escapedDim)\"}"
}
featJSON += "]"

// Count features by type
var typeCounts: [String: Int] = [:]
for f in analyser.features { typeCounts[f.type, default: 0] += 1 }
let statsHTML = typeCounts.sorted(by: { $0.key < $1.key }).map { k, v in
    "<div class=\"stat\"><span>\(k.capitalized)</span><span class=\"val\">\(v)</span></div>"
}.joined()

// Generate HTML
let html = """
<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<title>Studiio - Datapoint Viewer</title>
<style>
  *{margin:0;padding:0;box-sizing:border-box}
  body{background:#1a1a2e;overflow:hidden;font-family:-apple-system,BlinkMacSystemFont,'SF Pro',sans-serif}
  #c{width:100vw;height:100vh;display:block}
  #hud{position:fixed;top:16px;left:16px;color:#e0e0e0;font-size:12px;z-index:10;
    background:rgba(20,20,40,0.85);border:1px solid rgba(255,160,50,0.3);border-radius:8px;
    padding:12px 16px;backdrop-filter:blur(8px);min-width:220px}
  #hud h2{font-size:14px;color:#FF9800;margin-bottom:8px;letter-spacing:0.5px}
  .stat{display:flex;justify-content:space-between;margin:3px 0}
  .stat .val{color:#FF9800;font-weight:600}
  #legend{position:fixed;top:16px;right:16px;color:#e0e0e0;font-size:11px;z-index:10;
    background:rgba(20,20,40,0.85);border:1px solid rgba(255,160,50,0.3);border-radius:8px;
    padding:12px 16px;backdrop-filter:blur(8px);max-height:85vh;overflow-y:auto;min-width:160px}
  #legend h3{font-size:12px;color:#FF9800;margin-bottom:8px}
  .leg-item{display:flex;align-items:center;gap:6px;margin:3px 0;cursor:pointer}
  .leg-item:hover{color:#FF9800}
  .leg-dot{width:10px;height:10px;border-radius:2px;flex-shrink:0}
  .leg-count{color:#888;margin-left:auto}
  #controls{position:fixed;bottom:16px;left:50%;transform:translateX(-50%);z-index:10;display:flex;gap:6px;flex-wrap:wrap;justify-content:center}
  #controls button{background:rgba(20,20,40,0.9);border:1px solid rgba(255,160,50,0.4);
    color:#e0e0e0;padding:7px 14px;border-radius:6px;cursor:pointer;font-size:11px;transition:all 0.2s}
  #controls button:hover,#controls button.active{background:rgba(255,152,0,0.3);color:#FF9800;border-color:#FF9800}
  #tooltip{position:fixed;display:none;background:rgba(20,20,40,0.95);border:1px solid #FF9800;
    border-radius:6px;padding:10px 14px;color:#e0e0e0;font-size:12px;z-index:20;pointer-events:none;max-width:280px}
  .tt-cat{color:#FF9800;font-weight:700;font-size:14px;margin-bottom:4px}
  .tt-dim{color:#aaa}
  .tt-type{color:#666;font-size:10px}
</style>
</head><body>

<div id="hud">
  <h2>STUDIIO SCAN</h2>
  <div class="stat"><span>Features</span><span class="val">\(analyser.features.count)</span></div>
  \(statsHTML)
  <div class="stat"><span>Mesh</span><span class="val">\(allPositions.count / 1000)K vtx</span></div>
  <div class="stat"><span>Height</span><span class="val">\(String(format: "%.2f", ceilingY - floorY))m</span></div>
</div>

<div id="legend"><h3>DETECTED FEATURES</h3></div>

<div id="controls">
  <button class="active" onclick="setView('iso',this)">Isometric</button>
  <button onclick="setView('top',this)">Top Down</button>
  <button onclick="setView('front',this)">Front</button>
  <button onclick="setView('side',this)">Side</button>
  <button class="active" id="btnMesh" onclick="toggleLayer('mesh',this)">Mesh</button>
  <button class="active" id="btnWalls" onclick="toggleLayer('walls',this)">Walls</button>
  <button class="active" id="btnOpenings" onclick="toggleLayer('openings',this)">Openings</button>
  <button class="active" id="btnSurfaces" onclick="toggleLayer('surfaces',this)">Surfaces</button>
  <button class="active" id="btnVertical" onclick="toggleLayer('vertical',this)">Vertical</button>
  <button class="active" id="btnBoundary" onclick="toggleLayer('boundary',this)">Boundary</button>
  <button class="active" id="btnLabels" onclick="toggleLayer('labels',this)">Labels</button>
</div>

<div id="tooltip"><div class="tt-cat"></div><div class="tt-dim"></div><div class="tt-type"></div></div>

<canvas id="c"></canvas>

<script type="importmap">
{"imports":{"three":"https://cdn.jsdelivr.net/npm/three@0.162.0/build/three.module.js",
"three/addons/":"https://cdn.jsdelivr.net/npm/three@0.162.0/examples/jsm/"}}
</script>
<script type="module">
import * as THREE from 'three';
import {OrbitControls} from 'three/addons/controls/OrbitControls.js';
import {CSS2DRenderer,CSS2DObject} from 'three/addons/renderers/CSS2DRenderer.js';

const features = \(featJSON);
const floorY = \(floorY);
const ceilY = \(ceilingY);

// Scene
const scene = new THREE.Scene();
scene.background = new THREE.Color(0x1a1a2e);
scene.fog = new THREE.FogExp2(0x1a1a2e, 0.02);

const canvas = document.getElementById('c');
const renderer = new THREE.WebGLRenderer({canvas, antialias:true});
renderer.setPixelRatio(Math.min(window.devicePixelRatio,2));
renderer.setSize(window.innerWidth, window.innerHeight);

const labelRenderer = new CSS2DRenderer();
labelRenderer.setSize(window.innerWidth, window.innerHeight);
labelRenderer.domElement.style.position='absolute';
labelRenderer.domElement.style.top='0';
labelRenderer.domElement.style.pointerEvents='none';
document.body.appendChild(labelRenderer.domElement);

const camera = new THREE.PerspectiveCamera(50, window.innerWidth/window.innerHeight, 0.1, 200);
const controls = new OrbitControls(camera, renderer.domElement);
controls.enableDamping=true; controls.dampingFactor=0.05;

// Lighting
scene.add(new THREE.AmbientLight(0xffffff, 0.5));
const dl = new THREE.DirectionalLight(0xffffff, 0.4);
dl.position.set(5,10,5); scene.add(dl);

// Decode mesh
function b64f32(b){const s=atob(b),a=new ArrayBuffer(s.length),u=new Uint8Array(a);for(let i=0;i<s.length;i++)u[i]=s.charCodeAt(i);return new Float32Array(a)}
function b64u32(b){const s=atob(b),a=new ArrayBuffer(s.length),u=new Uint8Array(a);for(let i=0;i<s.length;i++)u[i]=s.charCodeAt(i);return new Uint32Array(a)}

const positions=b64f32("\(posB64)");
const indices=b64u32("\(idxB64)");

// Mesh layers
const layers = {mesh:new THREE.Group(), walls:new THREE.Group(), openings:new THREE.Group(),
  surfaces:new THREE.Group(), vertical:new THREE.Group(), boundary:new THREE.Group(),
  labels:new THREE.Group(), ceiling:new THREE.Group(), step:new THREE.Group(), corner:new THREE.Group()};
Object.values(layers).forEach(g=>scene.add(g));

// Wireframe mesh
const geo = new THREE.BufferGeometry();
geo.setAttribute('position', new THREE.BufferAttribute(positions,3));
geo.setIndex(new THREE.BufferAttribute(indices,1));
geo.computeVertexNormals();

layers.mesh.add(new THREE.Mesh(geo, new THREE.MeshPhongMaterial({
  color:0x556677, transparent:true, opacity:0.06, side:THREE.DoubleSide, depthWrite:false})));
layers.mesh.add(new THREE.Mesh(geo, new THREE.MeshBasicMaterial({
  color:0x6688aa, wireframe:true, transparent:true, opacity:0.12})));

// Floor grid
const grid = new THREE.GridHelper(30,60,0x333355,0x222244);
grid.position.y=floorY; scene.add(grid);

// Raycasting
const raycaster = new THREE.Raycaster();
const mouse = new THREE.Vector2();
const tooltip = document.getElementById('tooltip');
const clickTargets = [];

// Render each feature
features.forEach((f,i) => {
  const col = new THREE.Color(parseInt(f.c,16));
  const layer = layers[f.t] || layers.surfaces;

  if (f.t === 'boundary') {
    // Small flat markers for floor boundary
    const g = new THREE.BoxGeometry(f.dx, 0.03, f.dz);
    const m = new THREE.MeshBasicMaterial({color:col, transparent:true, opacity:0.4});
    const mesh = new THREE.Mesh(g, m);
    mesh.position.set(f.px, f.py, f.pz);
    layer.add(mesh);
    return;
  }

  if (f.t === 'corner') {
    // Small vertical line at wall corners
    const g = new THREE.CylinderGeometry(0.03, 0.03, f.dy, 6);
    const m = new THREE.MeshBasicMaterial({color:col, transparent:true, opacity:0.5});
    const mesh = new THREE.Mesh(g, m);
    mesh.position.set(f.px, f.py + f.dy/2, f.pz);
    layer.add(mesh);
    return;
  }

  if (f.t === 'wall') {
    // Wall as a thin box
    const g = new THREE.BoxGeometry(f.dx, f.dy, f.dz);
    const m = new THREE.MeshPhongMaterial({color:col, transparent:true, opacity:0.15, depthWrite:false});
    const mesh = new THREE.Mesh(g, m);
    mesh.position.set(f.px, f.py, f.pz);
    mesh.rotation.y = -f.r;
    layer.add(mesh);
    mesh.userData = {index:i};
    clickTargets.push(mesh);

    // Bright edge outline
    const eg = new THREE.EdgesGeometry(g);
    const em = new THREE.LineBasicMaterial({color:col, transparent:true, opacity:0.6});
    const edges = new THREE.LineSegments(eg, em);
    edges.position.copy(mesh.position);
    edges.rotation.copy(mesh.rotation);
    layer.add(edges);

    // Dimension label on wall
    if (f.dx > 0.8) {
      const div = document.createElement('div');
      div.style.cssText='background:rgba(20,20,40,0.85);border:1px solid #'+col.getHexString()+
        ';border-radius:3px;padding:1px 5px;font-size:9px;color:#'+col.getHexString()+
        ';font-weight:600;white-space:nowrap;font-family:SF Mono,monospace;';
      div.textContent = f.l;
      const lbl = new CSS2DObject(div);
      lbl.position.set(f.px, f.py + f.dy/2 + 0.1, f.pz);
      layers.labels.add(lbl);
    }
    return;
  }

  if (f.t === 'opening') {
    // Door/window as a coloured frame
    const isWin = f.s === 'window';
    const g = new THREE.BoxGeometry(f.dx, f.dy, 0.08);
    const m = new THREE.MeshPhongMaterial({
      color:col, transparent:true, opacity:0.35, side:THREE.DoubleSide, depthWrite:false,
      emissive:col, emissiveIntensity:0.3
    });
    const mesh = new THREE.Mesh(g, m);
    mesh.position.set(f.px, f.py + f.dy/2, f.pz);
    mesh.rotation.y = -f.r;
    layer.add(mesh);
    mesh.userData = {index:i};
    clickTargets.push(mesh);

    const eg = new THREE.EdgesGeometry(g);
    const em = new THREE.LineBasicMaterial({color:col, linewidth:2});
    const edges = new THREE.LineSegments(eg, em);
    edges.position.copy(mesh.position); edges.rotation.copy(mesh.rotation);
    layer.add(edges);

    // Label
    const div = document.createElement('div');
    div.style.cssText='background:rgba(20,20,40,0.9);border:1px solid #'+col.getHexString()+
      ';border-radius:3px;padding:2px 6px;font-size:10px;color:#'+col.getHexString()+
      ';font-weight:700;white-space:nowrap;font-family:SF Mono,monospace;';
    div.textContent = f.l;
    const lbl = new CSS2DObject(div);
    lbl.position.set(f.px, f.py + f.dy + 0.15, f.pz);
    layers.labels.add(lbl);
    return;
  }

  // Generic: surfaces, vertical, ceiling, step
  const g = new THREE.BoxGeometry(f.dx||0.1, f.dy||0.1, f.dz||0.1);
  const m = new THREE.MeshPhongMaterial({
    color:col, transparent:true, opacity:0.3, side:THREE.DoubleSide, depthWrite:false
  });
  const mesh = new THREE.Mesh(g, m);
  mesh.position.set(f.px, f.py, f.pz);
  if (f.r) mesh.rotation.y = -f.r;
  layer.add(mesh);
  mesh.userData = {index:i};
  clickTargets.push(mesh);

  const eg = new THREE.EdgesGeometry(g);
  const em = new THREE.LineBasicMaterial({color:col, transparent:true, opacity:0.7});
  const edges = new THREE.LineSegments(eg, em);
  edges.position.copy(mesh.position); edges.rotation.copy(mesh.rotation);
  layer.add(edges);

  // Pin + label
  if (f.l) {
    const pg = new THREE.SphereGeometry(0.05,10,6);
    const pm = new THREE.MeshPhongMaterial({color:col, emissive:col, emissiveIntensity:0.5});
    const pin = new THREE.Mesh(pg, pm);
    pin.position.set(f.px, f.py + (f.dy||0)/2 + 0.12, f.pz);
    layers.labels.add(pin);

    const div = document.createElement('div');
    div.style.cssText='background:rgba(20,20,40,0.9);border:1px solid #'+col.getHexString()+
      ';border-radius:4px;padding:2px 6px;font-size:10px;color:#'+col.getHexString()+
      ';font-weight:700;white-space:nowrap;letter-spacing:0.5px;font-family:SF Mono,monospace;';
    div.textContent = f.l;
    const lbl = new CSS2DObject(div);
    lbl.position.set(f.px, f.py + (f.dy||0)/2 + 0.22, f.pz);
    layers.labels.add(lbl);
  }
});

// Legend
const legend = document.getElementById('legend');
const cats = {};
features.forEach(f => {
  const key = f.l || f.s;
  if (!key || f.t==='boundary' || f.t==='corner') return;
  if (!cats[key]) cats[key]={count:0,colour:f.c,type:f.t};
  cats[key].count++;
});
Object.entries(cats).sort((a,b)=>b[1].count-a[1].count).forEach(([k,v])=>{
  const item=document.createElement('div');
  item.className='leg-item';
  item.innerHTML='<div class="leg-dot" style="background:#'+v.colour+'"></div>'+
    '<span>'+k+'</span><span class="leg-count">'+v.count+'</span>';
  legend.appendChild(item);
});

// Camera
let cx=0,cy=0,cz=0,n=0;
features.forEach(f=>{if(f.t!=='boundary'&&f.t!=='corner'){cx+=f.px;cy+=f.py;cz+=f.pz;n++}});
if(n>0){cx/=n;cy/=n;cz/=n}

function setView(v,btn){
  if(btn){document.querySelectorAll('#controls button').forEach(b=>{
    if(!b.id.startsWith('btn'))b.classList.remove('active')});btn.classList.add('active')}
  controls.target.set(cx,cy,cz);
  if(v==='iso')camera.position.set(cx+10,cy+7,cz+10);
  else if(v==='top')camera.position.set(cx,cy+15,cz+0.01);
  else if(v==='front')camera.position.set(cx,cy+1,cz+14);
  else if(v==='side')camera.position.set(cx+14,cy+1,cz);
  controls.update();
}
window.setView=setView;

window.toggleLayer=function(name,btn){
  const g=layers[name]; if(!g)return;
  g.visible=!g.visible;
  btn.classList.toggle('active',g.visible);
};

// Tooltip
canvas.addEventListener('mousemove',e=>{
  mouse.x=(e.clientX/window.innerWidth)*2-1;
  mouse.y=-(e.clientY/window.innerHeight)*2+1;
  raycaster.setFromCamera(mouse,camera);
  const hits=raycaster.intersectObjects(clickTargets);
  if(hits.length>0){
    const f=features[hits[0].object.userData.index];
    tooltip.style.display='block';
    tooltip.style.left=(e.clientX+16)+'px';
    tooltip.style.top=(e.clientY-10)+'px';
    tooltip.querySelector('.tt-cat').textContent=f.l||f.s;
    tooltip.querySelector('.tt-dim').textContent=f.dim;
    tooltip.querySelector('.tt-type').textContent=f.t+' / '+f.s;
  } else tooltip.style.display='none';
});

setView('iso',null);

function animate(){requestAnimationFrame(animate);controls.update();renderer.render(scene,camera);labelRenderer.render(scene,camera)}
animate();

window.addEventListener('resize',()=>{
  camera.aspect=window.innerWidth/window.innerHeight;camera.updateProjectionMatrix();
  renderer.setSize(window.innerWidth,window.innerHeight);labelRenderer.setSize(window.innerWidth,window.innerHeight);
});
</script>
</body></html>
"""

let outputURL = bundleURL.deletingLastPathComponent().appendingPathComponent("dollshouse.html")
try! html.write(to: outputURL, atomically: true, encoding: .utf8)
let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
print("\nWritten to: \(outputURL.path) (\(fileSize / 1024)KB)")
