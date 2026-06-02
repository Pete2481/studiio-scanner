import Foundation
import simd

/// Post-processing object detector that analyses collected mesh data (ExtractedMeshData)
/// to identify architectural features and fixtures using geometry heuristics.
///
/// This runs AFTER scanning completes — it does NOT touch the scanner or AR session.
/// Input: [ExtractedMeshData] (the same data we already collect)
/// Output: [TaggedObject] with positions, dimensions, and categories
struct MeshObjectDetector {

    // MARK: - Detection Results

    struct DetectionResult {
        var objects: [TaggedObject]
        var wallLines: [PropertyProject_WallSegment]
        var openings: [PropertyProject_Opening]
        var roomDimensions: (width: Float, depth: Float)?
        var floorLevel: Float
        var ceilingLevel: Float
        var wallAlignmentAngle: Float
        var floorPolygon: [PointXZ]
        var rooms: [RoomSegment]  // ceiling-plane segmented rooms
    }

    struct RoomSegment {
        var name: String
        var polygon: [PointXZ]
        var walls: [PropertyProject_WallSegment]
        var openings: [PropertyProject_Opening]
        var area: Double
        var width: Double
        var depth: Double
    }

    // Internal working types (converted to model types for persistence)
    struct RawWall {
        var startX: Float, startZ: Float
        var endX: Float, endZ: Float
        var thickness: Float
        var length: Float
        var angle: Float
    }

    struct RawOpening {
        var kind: OpeningKind
        var positionX: Float
        var positionZ: Float
        var width: Float
        var height: Float      // calculated from mesh gap (not hardcoded)
        var sillHeight: Float  // 0 for doors, >0 for windows
        var wallIndex: Int     // index into wall array
    }

    // Reuse the model-level OpeningKind enum
    typealias PropertyProject_WallSegment = WallSegment
    typealias PropertyProject_Opening = DetectedOpening

    // Vertex with optional classification (0=none, 1=wall, 2=floor, 3=ceiling, 4=table, 5=seat, 6=door, 7=window)
    typealias ClassifiedVertex = (pos: SIMD3<Float>, normal: SIMD3<Float>, classification: UInt8)
    // Legacy vertex type for functions that don't need classification
    typealias Vertex = (pos: SIMD3<Float>, normal: SIMD3<Float>)

    // MARK: - Main Detection Entry Point

    static func detect(from meshData: [ExtractedMeshData], planeData: [ExtractedPlaneData] = []) -> DetectionResult {
        // Step 1: Transform all vertices to world space, with per-vertex classification
        var allVertices: [(pos: SIMD3<Float>, normal: SIMD3<Float>, classification: UInt8)] = []

        for data in meshData {
            let t = data.transform
            // Build per-vertex classification from per-face classifications
            // ARMeshClassification: 0=none, 1=wall, 2=floor, 3=ceiling, 4=table, 5=seat, 6=door, 7=window
            var vertexClassifications = Array(repeating: UInt8(0), count: data.positions.count)
            if !data.classifications.isEmpty {
                // Each face has 3 vertex indices; assign face classification to its vertices
                let faceCount = data.indices.count / 3
                for f in 0..<min(faceCount, data.classifications.count) {
                    let cls = data.classifications[f]
                    for vi in 0..<3 {
                        let idx = Int(data.indices[f * 3 + vi])
                        if idx < vertexClassifications.count && cls > vertexClassifications[idx] {
                            vertexClassifications[idx] = cls
                        }
                    }
                }
            }

            for i in 0..<min(data.positions.count, data.normals.count) {
                let local = data.positions[i]
                let wp4 = t * SIMD4<Float>(local.x, local.y, local.z, 1.0)
                let worldPos = SIMD3<Float>(wp4.x, wp4.y, wp4.z)

                let localN = data.normals[i]
                let wn4 = t * SIMD4<Float>(localN.x, localN.y, localN.z, 0.0)
                let worldNorm = normalize(SIMD3<Float>(wn4.x, wn4.y, wn4.z))

                let cls = i < vertexClassifications.count ? vertexClassifications[i] : 0
                allVertices.append((pos: worldPos, normal: worldNorm, classification: cls))
            }
        }

        guard !allVertices.isEmpty else {
            return DetectionResult(objects: [], wallLines: [], openings: [],
                                   roomDimensions: nil, floorLevel: 0, ceilingLevel: 2.4,
                                   wallAlignmentAngle: 0, floorPolygon: [], rooms: [])
        }

        // Strip classification for functions that don't need it
        let plainVertices: [Vertex] = allVertices.map { (pos: $0.pos, normal: $0.normal) }

        // Step 2: Find floor and ceiling levels
        let floorY = findFloorLevel(plainVertices)
        let ceilingY = findCeilingLevel(plainVertices, floorY: floorY)
        print("[ObjectDetector] Floor: \(String(format: "%.2f", floorY))m, Ceiling: \(String(format: "%.2f", ceilingY))m")

        // Step 3: Rotate to align walls with axes
        let (rotatedPlain, rotAngle) = alignToWalls(plainVertices, floorY: floorY)

        // Also rotate the classified vertices for wall extraction
        let cosR = cos(rotAngle)
        let sinR = sin(rotAngle)
        let rotatedClassified: [ClassifiedVertex] = allVertices.map { v in
            let rx = v.pos.x * cosR - v.pos.z * sinR
            let rz = v.pos.x * sinR + v.pos.z * cosR
            let rnx = v.normal.x * cosR - v.normal.z * sinR
            let rnz = v.normal.x * sinR + v.normal.z * cosR
            return (
                pos: SIMD3<Float>(rx, v.pos.y, rz),
                normal: SIMD3<Float>(rnx, v.normal.y, rnz),
                classification: v.classification
            )
        }

        // Step 4: Object detection disabled — focus on walls/openings accuracy first
        let objects: [TaggedObject] = []

        // Step 5: Wall detection — plane anchors are PRIMARY, RANSAC fills gaps

        // 5a: Walls from ARPlaneAnchors (Apple's highest confidence detections)
        let planeWalls = wallsFromPlaneAnchors(planeData, rotAngle: rotAngle)
        let snappedPlaneWalls = snapWallsToOrthogonal(planeWalls)
        let mergedPlaneWalls = mergeCollinearWalls(snappedPlaneWalls)
        print("[ObjectDetector] Plane-anchor walls: \(mergedPlaneWalls.count)")

        // 5b: RANSAC walls from mesh points (supplemental — fills gaps plane anchors missed)
        let wallPoints = extractWallPoints(rotatedClassified, floorY: floorY)
        let ransacWalls = fitRawWalls(from: wallPoints)
        let snappedRansac = snapWallsToOrthogonal(ransacWalls)
        print("[ObjectDetector] RANSAC walls: \(snappedRansac.count)")

        // 5c: Combine — add RANSAC walls only where no plane wall exists
        var combinedWalls = mergedPlaneWalls
        for rw in snappedRansac {
            let rwMidX = (rw.startX + rw.endX) / 2
            let rwMidZ = (rw.startZ + rw.endZ) / 2
            let hasOverlap = combinedWalls.contains { pw in
                let angleDiff = abs(rw.angle - pw.angle)
                let isParallel = angleDiff < 0.35 || abs(angleDiff - .pi) < 0.35
                guard isParallel else { return false }
                // Perpendicular distance check
                if abs(pw.angle) < 0.01 || abs(pw.angle - .pi) < 0.01 {
                    return abs(rwMidZ - (pw.startZ + pw.endZ) / 2) < 0.4
                } else if abs(pw.angle - .pi / 2) < 0.01 {
                    return abs(rwMidX - (pw.startX + pw.endX) / 2) < 0.4
                }
                return false
            }
            if !hasOverlap && rw.length > 0.5 {
                combinedWalls.append(rw)
            }
        }

        // 5d: Final merge and corner fitting
        let mergedWalls = mergeCollinearWalls(combinedWalls)
        let cornerFittedWalls = fitCorners(mergedWalls)
        print("[ObjectDetector] Final walls after merge+corners: \(cornerFittedWalls.count)")

        // Step 6: Opening detection — mesh gaps + plane anchor door/window classifications
        var rawOpenings = detectRawOpenings(wallLines: cornerFittedWalls, vertices: rotatedPlain, floorY: floorY, ceilingY: ceilingY)

        // Enhance with plane anchor classifications (door/window planes override width-based guessing)
        let planeOpenings = openingsFromPlaneAnchors(planeData, rotAngle: rotAngle, walls: cornerFittedWalls, floorY: floorY, ceilingY: ceilingY)
        for po in planeOpenings {
            // If a mesh opening is near this plane opening, update its classification
            var matched = false
            for i in 0..<rawOpenings.count {
                let dist = sqrt(pow(rawOpenings[i].positionX - po.positionX, 2) + pow(rawOpenings[i].positionZ - po.positionZ, 2))
                if dist < 0.8 {
                    rawOpenings[i].kind = po.kind
                    rawOpenings[i].sillHeight = po.sillHeight
                    if po.width > 0.3 { rawOpenings[i].width = max(rawOpenings[i].width, po.width) }
                    matched = true
                    break
                }
            }
            if !matched {
                rawOpenings.append(po)
            }
        }
        print("[ObjectDetector] Openings: \(rawOpenings.count) (\(planeOpenings.count) from plane anchors)")

        // Step 6: Room dimensions from wall lines
        let dims = measureRoomFromRawWalls(wallLines: cornerFittedWalls)

        // Phase C: Extract floor polygon from wall endpoints
        let floorPoly = extractFloorPolygon(from: cornerFittedWalls)

        // Convert raw walls to model WallSegments (un-rotated to world space)
        let cosA = cos(-rotAngle)
        let sinA = sin(-rotAngle)

        let modelWalls: [WallSegment] = cornerFittedWalls.map { w in
            let sx = Double(w.startX * cosA - w.startZ * sinA)
            let sz = Double(w.startX * sinA + w.startZ * cosA)
            let ex = Double(w.endX * cosA - w.endZ * sinA)
            let ez = Double(w.endX * sinA + w.endZ * cosA)
            return WallSegment(
                startX: sx, startZ: sz, endX: ex, endZ: ez,
                thickness: Double(w.thickness), length: Double(w.length),
                angle: Double(w.angle),
                isExterior: w.thickness > 0.15
            )
        }

        let modelOpenings: [DetectedOpening] = rawOpenings.map { o in
            let px = Double(o.positionX * cosA - o.positionZ * sinA)
            let pz = Double(o.positionX * sinA + o.positionZ * cosA)
            let parentWallID = o.wallIndex < modelWalls.count ? modelWalls[o.wallIndex].id : nil
            return DetectedOpening(
                kind: o.kind,
                positionX: px, positionZ: pz,
                width: Double(o.width),
                height: Double(o.height),
                sillHeight: Double(o.sillHeight),
                wallID: parentWallID
            )
        }

        let modelFloorPoly: [PointXZ] = floorPoly.map { p in
            let rx = Double(p.x * cosA - p.z * sinA)
            let rz = Double(p.x * sinA + p.z * cosA)
            return PointXZ(x: rx, z: rz)
        }

        // Un-rotate object positions back to world space
        let unrotObjects = objects.map { obj -> TaggedObject in
            var o = obj
            let rx = o.positionX * cosA - o.positionZ * sinA
            let rz = o.positionX * sinA + o.positionZ * cosA
            o.positionX = rx
            o.positionZ = rz
            return o
        }

        print("[ObjectDetector] Detected \(unrotObjects.count) objects, \(modelWalls.count) walls, \(modelOpenings.count) openings, \(modelFloorPoly.count)-pt polygon")

        // Room segmentation: each ceiling plane = one room
        let segmentedRooms = segmentRoomsByCeiling(
            planeData: planeData,
            walls: modelWalls,
            openings: modelOpenings,
            floorLevel: floorY,
            ceilingLevel: ceilingY
        )
        print("[ObjectDetector] Segmented into \(segmentedRooms.count) rooms from ceiling planes")

        return DetectionResult(
            objects: unrotObjects,
            wallLines: modelWalls,
            openings: modelOpenings,
            roomDimensions: dims,
            floorLevel: floorY,
            ceilingLevel: ceilingY,
            wallAlignmentAngle: rotAngle,
            floorPolygon: modelFloorPoly,
            rooms: segmentedRooms
        )
    }

    // MARK: - Room Segmentation by Ceiling Planes

    /// Each ceiling plane = one room. Walls and openings are assigned to the
    /// NEAREST ceiling plane (by distance from center), not strict containment.
    private static func segmentRoomsByCeiling(
        planeData: [ExtractedPlaneData],
        walls: [WallSegment],
        openings: [DetectedOpening],
        floorLevel: Float,
        ceilingLevel: Float
    ) -> [RoomSegment] {
        // Find ceiling planes (horizontal, classified as ceiling, > 4m²)
        let ceilingPlanes = planeData.filter {
            $0.classification == .ceiling && $0.alignment == .horizontal && $0.extentX * $0.extentZ > 4.0
        }
        guard !ceilingPlanes.isEmpty else { return [] }

        // Compute world-space center for each ceiling plane
        struct CeilingRoom {
            let plane: ExtractedPlaneData
            let centerWorld: SIMD2<Float>  // XZ center in world space
            let footprint: [SIMD2<Float>]  // 4 corners in world XZ
            var walls: [WallSegment] = []
            var openings: [DetectedOpening] = []
        }

        var ceilingRooms: [CeilingRoom] = ceilingPlanes.map { plane in
            let t = plane.transform
            let worldCenter = t * SIMD4<Float>(plane.centerX, 0, plane.centerZ, 1)
            let fp = ceilingFootprintXZ(plane)
            return CeilingRoom(
                plane: plane,
                centerWorld: SIMD2<Float>(worldCenter.x, worldCenter.z),
                footprint: fp
            )
        }

        // Sort by area descending (largest room first for logging clarity)
        ceilingRooms.sort { $0.plane.extentX * $0.plane.extentZ > $1.plane.extentX * $1.plane.extentZ }

        // Assign each wall to its nearest ceiling plane
        for wall in walls {
            let midX = Float((wall.startX + wall.endX) / 2)
            let midZ = Float((wall.startZ + wall.endZ) / 2)
            let wallMid = SIMD2<Float>(midX, midZ)

            var bestIdx = 0
            var bestDist: Float = .greatestFiniteMagnitude
            for (i, room) in ceilingRooms.enumerated() {
                let dist = simd_distance(wallMid, room.centerWorld)
                if dist < bestDist {
                    bestDist = dist
                    bestIdx = i
                }
            }
            ceilingRooms[bestIdx].walls.append(wall)
        }

        // Assign each opening to its nearest ceiling plane
        for opening in openings {
            let pos = SIMD2<Float>(Float(opening.positionX), Float(opening.positionZ))

            var bestIdx = 0
            var bestDist: Float = .greatestFiniteMagnitude
            for (i, room) in ceilingRooms.enumerated() {
                let dist = simd_distance(pos, room.centerWorld)
                if dist < bestDist {
                    bestDist = dist
                    bestIdx = i
                }
            }
            ceilingRooms[bestIdx].openings.append(opening)
        }

        // Build room segments
        var rooms: [RoomSegment] = []
        for (i, cr) in ceilingRooms.enumerated() {
            let area = Double(cr.plane.extentX * cr.plane.extentZ)
            let polygon = cr.footprint.map { PointXZ(x: Double($0.x), z: Double($0.y)) }
            let name = ceilingRooms.count == 1 ? "Scanned Area" : "Room \(i + 1)"

            rooms.append(RoomSegment(
                name: name,
                polygon: polygon,
                walls: cr.walls,
                openings: cr.openings,
                area: area,
                width: Double(cr.plane.extentX),
                depth: Double(cr.plane.extentZ)
            ))
            print("[ObjectDetector] Room '\(name)': \(String(format: "%.1f", cr.plane.extentX))m × \(String(format: "%.1f", cr.plane.extentZ))m = \(String(format: "%.1f", area))m², \(cr.walls.count) walls, \(cr.openings.count) openings, center=(\(String(format: "%.1f", cr.centerWorld.x)), \(String(format: "%.1f", cr.centerWorld.y)))")
        }

        return rooms
    }

    /// Get the 4 corners of a ceiling plane projected to XZ (floor plan) space
    private static func ceilingFootprintXZ(_ plane: ExtractedPlaneData) -> [SIMD2<Float>] {
        let t = plane.transform
        let cx = plane.centerX
        let cz = plane.centerZ
        let hw = plane.extentX / 2
        let hz = plane.extentZ / 2

        // 4 corners in plane-local space
        let localCorners: [(Float, Float)] = [
            (cx - hw, cz - hz),
            (cx + hw, cz - hz),
            (cx + hw, cz + hz),
            (cx - hw, cz + hz)
        ]

        // Transform to world space, project to XZ
        return localCorners.map { (lx, lz) in
            let wp = t * SIMD4<Float>(lx, 0, lz, 1)
            return SIMD2<Float>(wp.x, wp.z)
        }
    }

    /// Point-in-convex-polygon test using cross products (with tolerance buffer)
    private static func pointInConvexPolygon(_ point: SIMD2<Float>, polygon: [SIMD2<Float>], tolerance: Float) -> Bool {
        guard polygon.count >= 3 else { return false }

        // First check simple bounding box with tolerance
        let xs = polygon.map(\.x)
        let ys = polygon.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return false }
        guard point.x >= minX - tolerance && point.x <= maxX + tolerance &&
              point.y >= minY - tolerance && point.y <= maxY + tolerance else { return false }

        // Winding number test for robust point-in-polygon
        var winding = 0
        let n = polygon.count
        for i in 0..<n {
            let j = (i + 1) % n
            let vi = polygon[i], vj = polygon[j]
            if vi.y <= point.y {
                if vj.y > point.y {
                    let cross = (vj.x - vi.x) * (point.y - vi.y) - (point.x - vi.x) * (vj.y - vi.y)
                    if cross > -tolerance { winding += 1 }
                }
            } else {
                if vj.y <= point.y {
                    let cross = (vj.x - vi.x) * (point.y - vi.y) - (point.x - vi.x) * (vj.y - vi.y)
                    if cross < tolerance { winding -= 1 }
                }
            }
        }
        return winding != 0
    }

    // MARK: - Phase C: Orthogonal Wall Snapping

    /// Snap walls that are within tolerance of 0°/90° to exact axis alignment.
    /// Uses a wider tolerance (10°) since RANSAC walls in rotated space should
    /// already be close to axis-aligned.
    private static func snapWallsToOrthogonal(_ walls: [RawWall]) -> [RawWall] {
        let snapTolerance: Float = 10.0 * .pi / 180  // 10 degrees

        return walls.map { wall in
            var w = wall
            let angle = atan2(w.endZ - w.startZ, w.endX - w.startX)
            let absAngle = abs(angle)

            // Check if near horizontal (0° or 180°)
            if absAngle < snapTolerance || abs(absAngle - .pi) < snapTolerance {
                let avgZ = (w.startZ + w.endZ) / 2
                w.startZ = avgZ
                w.endZ = avgZ
                w.angle = 0
            }
            // Check if near vertical (90° or -90°)
            else if abs(absAngle - .pi / 2) < snapTolerance {
                let avgX = (w.startX + w.endX) / 2
                w.startX = avgX
                w.endX = avgX
                w.angle = .pi / 2
            }

            // Recalculate length after snapping
            let dx = w.endX - w.startX
            let dz = w.endZ - w.startZ
            w.length = sqrt(dx * dx + dz * dz)

            return w
        }
    }

    // MARK: - Phase C: Merge Collinear Walls

    /// Merge wall segments that lie on the same line (same orientation, close
    /// perpendicular position, overlapping or nearby extent).
    /// After orthogonal snapping, horizontal walls share the same Z and vertical
    /// walls share the same X — so we group by position and merge overlapping spans.
    private static func mergeCollinearWalls(_ walls: [RawWall]) -> [RawWall] {
        // Separate into horizontal (angle==0) and vertical (angle==π/2) and other
        var horizontal: [RawWall] = []
        var vertical: [RawWall] = []
        var other: [RawWall] = []

        for w in walls {
            if w.angle == 0 {
                horizontal.append(w)
            } else if abs(w.angle - .pi / 2) < 0.01 {
                vertical.append(w)
            } else {
                other.append(w)
            }
        }

        // Merge horizontal walls: group by Z position (within threshold)
        let merged_h = mergeAlignedSegments(horizontal, posKey: { $0.startZ },
                                             spanStart: { min($0.startX, $0.endX) },
                                             spanEnd: { max($0.startX, $0.endX) },
                                             makeWall: { z, minVal, maxVal, thickness in
            RawWall(startX: minVal, startZ: z, endX: maxVal, endZ: z,
                    thickness: thickness, length: maxVal - minVal, angle: 0)
        })

        // Merge vertical walls: group by X position (within threshold)
        let merged_v = mergeAlignedSegments(vertical, posKey: { $0.startX },
                                             spanStart: { min($0.startZ, $0.endZ) },
                                             spanEnd: { max($0.startZ, $0.endZ) },
                                             makeWall: { x, minVal, maxVal, thickness in
            RawWall(startX: x, startZ: minVal, endX: x, endZ: maxVal,
                    thickness: thickness, length: maxVal - minVal, angle: .pi / 2)
        })

        return merged_h + merged_v + other
    }

    /// Group segments by their perpendicular position, then merge overlapping spans.
    private static func mergeAlignedSegments(
        _ walls: [RawWall],
        posKey: (RawWall) -> Float,
        spanStart: (RawWall) -> Float,
        spanEnd: (RawWall) -> Float,
        makeWall: (Float, Float, Float, Float) -> RawWall
    ) -> [RawWall] {
        guard !walls.isEmpty else { return [] }

        let mergePosTolerance: Float = 0.50  // walls within 50cm are "same line" (catches both faces of a wall)
        let mergeGapTolerance: Float = 0.5   // spans within 50cm gap get merged

        // Sort by position
        let sorted = walls.sorted { posKey($0) < posKey($1) }

        // Group by position
        var groups: [[RawWall]] = []
        var currentGroup: [RawWall] = [sorted[0]]

        for i in 1..<sorted.count {
            if abs(posKey(sorted[i]) - posKey(currentGroup[0])) < mergePosTolerance {
                currentGroup.append(sorted[i])
            } else {
                groups.append(currentGroup)
                currentGroup = [sorted[i]]
            }
        }
        groups.append(currentGroup)

        // Within each group, merge overlapping/nearby spans
        var result: [RawWall] = []
        for group in groups {
            let avgPos = group.map { posKey($0) }.reduce(0, +) / Float(group.count)
            // When merging two faces of the same wall, the real thickness is
            // the distance between the outermost detected faces
            let positions = group.map { posKey($0) }
            let posSpread = (positions.max() ?? 0) - (positions.min() ?? 0)
            let maxThickness = max(posSpread, group.map(\.thickness).max() ?? 0.05)

            // Sort spans by start
            var spans = group.map { (start: spanStart($0), end: spanEnd($0)) }
                .sorted { $0.start < $1.start }

            // Merge overlapping spans
            var merged: [(start: Float, end: Float)] = [spans[0]]
            for i in 1..<spans.count {
                if spans[i].start <= merged.last!.end + mergeGapTolerance {
                    merged[merged.count - 1].end = max(merged.last!.end, spans[i].end)
                } else {
                    merged.append(spans[i])
                }
            }

            for span in merged {
                result.append(makeWall(avgPos, span.start, span.end, maxThickness))
            }
        }

        return result
    }

    // MARK: - Phase C: Corner Fitting via Line Intersection

    /// For perpendicular walls whose extensions would meet within a threshold,
    /// compute the actual intersection point and trim/extend both walls to meet
    /// there. This produces clean right-angle corners.
    private static func fitCorners(_ walls: [RawWall]) -> [RawWall] {
        guard walls.count >= 2 else { return walls }
        var result = walls

        let extensionLimit: Float = 0.5  // max distance to extend a wall to reach a corner

        // For each horizontal-vertical wall pair, check if endpoints are close
        // enough to form a corner via line intersection.
        for i in 0..<result.count {
            for j in (i + 1)..<result.count {
                let wi = result[i], wj = result[j]

                // Only intersect perpendicular walls
                let bothAxis = (wi.angle == 0 || abs(wi.angle - .pi / 2) < 0.01) &&
                               (wj.angle == 0 || abs(wj.angle - .pi / 2) < 0.01)
                let perpendicular = abs(wi.angle - wj.angle) > 0.1
                guard bothAxis && perpendicular else { continue }

                // Determine which is horizontal and which is vertical
                let (hIdx, vIdx): (Int, Int)
                if wi.angle == 0 {
                    hIdx = i; vIdx = j
                } else {
                    hIdx = j; vIdx = i
                }

                let hWall = result[hIdx]  // horizontal: constant Z, spans X
                let vWall = result[vIdx]  // vertical: constant X, spans Z

                // Intersection point: (vWall.X, hWall.Z)
                let ix = vWall.startX  // vertical wall has constant X
                let iz = hWall.startZ  // horizontal wall has constant Z

                // Check if intersection is near the end of both walls
                let hMinX = min(hWall.startX, hWall.endX)
                let hMaxX = max(hWall.startX, hWall.endX)
                let vMinZ = min(vWall.startZ, vWall.endZ)
                let vMaxZ = max(vWall.startZ, vWall.endZ)

                // How far is the intersection from each wall's nearest endpoint?
                let hDistToEnd = min(abs(ix - hMinX), abs(ix - hMaxX))
                let vDistToEnd = min(abs(iz - vMinZ), abs(iz - vMaxZ))

                // Is intersection within the wall span or just past its end?
                let hInSpan = ix >= hMinX - extensionLimit && ix <= hMaxX + extensionLimit
                let vInSpan = iz >= vMinZ - extensionLimit && iz <= vMaxZ + extensionLimit

                // Only snap if the intersection is near an endpoint (not mid-wall)
                // and within extension limit
                let hNearEnd = hDistToEnd < extensionLimit || (ix >= hMinX && ix <= hMaxX)
                let vNearEnd = vDistToEnd < extensionLimit || (iz >= vMinZ && iz <= vMaxZ)

                guard hInSpan && vInSpan && (hNearEnd || vNearEnd) else { continue }

                // Snap the appropriate endpoint of each wall to the intersection
                // Horizontal wall: snap whichever X endpoint is closer to ix
                if abs(result[hIdx].startX - ix) < abs(result[hIdx].endX - ix) {
                    if abs(result[hIdx].startX - ix) < extensionLimit {
                        result[hIdx].startX = ix
                    }
                } else {
                    if abs(result[hIdx].endX - ix) < extensionLimit {
                        result[hIdx].endX = ix
                    }
                }

                // Vertical wall: snap whichever Z endpoint is closer to iz
                if abs(result[vIdx].startZ - iz) < abs(result[vIdx].endZ - iz) {
                    if abs(result[vIdx].startZ - iz) < extensionLimit {
                        result[vIdx].startZ = iz
                    }
                } else {
                    if abs(result[vIdx].endZ - iz) < extensionLimit {
                        result[vIdx].endZ = iz
                    }
                }
            }
        }

        // Recalculate lengths after corner fitting
        for i in 0..<result.count {
            let dx = result[i].endX - result[i].startX
            let dz = result[i].endZ - result[i].startZ
            result[i].length = sqrt(dx * dx + dz * dz)
        }

        // Remove walls that became too short after merging/trimming
        result = result.filter { $0.length > 0.3 }

        return result
    }

    // MARK: - Phase C: Floor Polygon Extraction

    /// Build a floor polygon from wall segment endpoints using convex hull
    private static func extractFloorPolygon(from walls: [RawWall]) -> [(x: Float, z: Float)] {
        guard walls.count >= 3 else { return [] }

        // Collect all wall endpoints
        var points: [(x: Float, z: Float)] = []
        for w in walls {
            points.append((x: w.startX, z: w.startZ))
            points.append((x: w.endX, z: w.endZ))
        }

        // Compute convex hull (Graham scan)
        guard points.count >= 3 else { return points }

        // Find bottom-most point (min Z, then min X)
        var pivot = 0
        for i in 1..<points.count {
            if points[i].z < points[pivot].z || (points[i].z == points[pivot].z && points[i].x < points[pivot].x) {
                pivot = i
            }
        }
        points.swapAt(0, pivot)
        let p0 = points[0]

        // Sort by polar angle from pivot
        let sorted = [p0] + points[1...].sorted { a, b in
            let angleA = atan2(a.z - p0.z, a.x - p0.x)
            let angleB = atan2(b.z - p0.z, b.x - p0.x)
            if abs(angleA - angleB) > 0.001 { return angleA < angleB }
            let distA = (a.x - p0.x) * (a.x - p0.x) + (a.z - p0.z) * (a.z - p0.z)
            let distB = (b.x - p0.x) * (b.x - p0.x) + (b.z - p0.z) * (b.z - p0.z)
            return distA < distB
        }

        // Build hull
        var hull: [(x: Float, z: Float)] = []
        for p in sorted {
            while hull.count >= 2 {
                let a = hull[hull.count - 2]
                let b = hull[hull.count - 1]
                let cross = (b.x - a.x) * (p.z - a.z) - (b.z - a.z) * (p.x - a.x)
                if cross <= 0 { hull.removeLast() }
                else { break }
            }
            hull.append(p)
        }

        return hull
    }

    // MARK: - Fix 3: ARPlaneAnchor Wall Fusion

    /// Convert ARPlaneAnchors classified as .wall into RawWall segments in rotated space
    private static func wallsFromPlaneAnchors(_ planes: [ExtractedPlaneData], rotAngle: Float) -> [RawWall] {
        let cosA = cos(rotAngle)
        let sinA = sin(rotAngle)
        var walls: [RawWall] = []

        for plane in planes where plane.classification == .wall && plane.alignment == .vertical {
            // Plane center in world space
            let t = plane.transform
            let worldCenterX = t.columns.3.x + plane.centerX * t.columns.0.x + plane.centerZ * t.columns.2.x
            let worldCenterZ = t.columns.3.z + plane.centerX * t.columns.0.z + plane.centerZ * t.columns.2.z

            // Plane extent direction (the "width" axis of the plane)
            let rightX = t.columns.0.x
            let rightZ = t.columns.0.z
            let halfWidth = plane.extentX / 2

            // Wall start and end in world space
            let startX = worldCenterX - rightX * halfWidth
            let startZ = worldCenterZ - rightZ * halfWidth
            let endX = worldCenterX + rightX * halfWidth
            let endZ = worldCenterZ + rightZ * halfWidth

            // Rotate into aligned space
            let rsx = startX * cosA - startZ * sinA
            let rsz = startX * sinA + startZ * cosA
            let rex = endX * cosA - endZ * sinA
            let rez = endX * sinA + endZ * cosA

            let dx = rex - rsx
            let dz = rez - rsz
            let length = sqrt(dx * dx + dz * dz)
            guard length > 0.5 else { continue }  // skip tiny planes

            let angle = atan2(dz, dx)

            walls.append(RawWall(
                startX: rsx, startZ: rsz,
                endX: rex, endZ: rez,
                thickness: 0.1,  // planes don't have thickness info, use default
                length: length,
                angle: angle
            ))
        }

        return walls
    }

    /// Fuse plane-anchor walls with RANSAC walls.
    /// Plane walls are higher confidence — if a plane wall overlaps a RANSAC wall, prefer the plane wall's position.
    /// If a plane wall has no RANSAC match, add it as a new wall.
    private static func fusePlaneWalls(_ planeWalls: [RawWall], with ransacWalls: [RawWall]) -> [RawWall] {
        var result = ransacWalls
        let matchThreshold: Float = 0.3  // perpendicular distance to consider same wall

        for pw in planeWalls {
            let pwMidX = (pw.startX + pw.endX) / 2
            let pwMidZ = (pw.startZ + pw.endZ) / 2

            // Find closest RANSAC wall
            var bestMatch = -1
            var bestDist: Float = .greatestFiniteMagnitude

            for (i, rw) in result.enumerated() {
                // Check if roughly parallel (within 20 degrees)
                let angleDiff = abs(pw.angle - rw.angle)
                let isParallel = angleDiff < 0.35 || abs(angleDiff - .pi) < 0.35 || abs(angleDiff - .pi / 2) < 0.35

                guard isParallel else { continue }

                // Perpendicular distance from plane wall midpoint to RANSAC wall line
                let rwDx = rw.endX - rw.startX
                let rwDz = rw.endZ - rw.startZ
                let rwLen = sqrt(rwDx * rwDx + rwDz * rwDz)
                guard rwLen > 0 else { continue }
                let nx = -rwDz / rwLen
                let nz = rwDx / rwLen
                let dist = abs((pwMidX - rw.startX) * nx + (pwMidZ - rw.startZ) * nz)

                if dist < bestDist {
                    bestDist = dist
                    bestMatch = i
                }
            }

            if bestDist < matchThreshold && bestMatch >= 0 {
                // Plane wall confirms this RANSAC wall — adjust RANSAC wall position
                // toward plane position (plane anchors are higher confidence)
                let blend: Float = 0.6  // 60% plane, 40% RANSAC
                result[bestMatch].startX = result[bestMatch].startX * (1 - blend) + pw.startX * blend
                result[bestMatch].startZ = result[bestMatch].startZ * (1 - blend) + pw.startZ * blend
                result[bestMatch].endX = result[bestMatch].endX * (1 - blend) + pw.endX * blend
                result[bestMatch].endZ = result[bestMatch].endZ * (1 - blend) + pw.endZ * blend

                // Extend wall span if plane is longer
                let dx = result[bestMatch].endX - result[bestMatch].startX
                let dz = result[bestMatch].endZ - result[bestMatch].startZ
                result[bestMatch].length = sqrt(dx * dx + dz * dz)
            } else {
                // No RANSAC match — add plane wall as new wall
                result.append(pw)
            }
        }

        return result
    }

    // MARK: - Openings from Plane Anchors

    /// Convert ARPlaneAnchors classified as door/window into RawOpenings placed on the nearest wall
    private static func openingsFromPlaneAnchors(_ planes: [ExtractedPlaneData], rotAngle: Float, walls: [RawWall], floorY: Float, ceilingY: Float) -> [RawOpening] {
        let cosA = cos(rotAngle)
        let sinA = sin(rotAngle)
        var openings: [RawOpening] = []

        for plane in planes {
            let isDoor = plane.classification == .door
            let isWindow = plane.classification == .window
            guard isDoor || isWindow else { continue }
            guard plane.alignment == .vertical else { continue }

            // Plane center in world space
            let t = plane.transform
            let worldX = t.columns.3.x + plane.centerX * t.columns.0.x + plane.centerZ * t.columns.2.x
            let worldZ = t.columns.3.z + plane.centerX * t.columns.0.z + plane.centerZ * t.columns.2.z
            let worldY = t.columns.3.y + plane.centerX * t.columns.0.y + plane.centerZ * t.columns.2.y

            // Rotate into aligned space
            let rx = worldX * cosA - worldZ * sinA
            let rz = worldX * sinA + worldZ * cosA

            // Width is the horizontal extent of the plane
            let width = plane.extentX
            guard width > 0.2 else { continue }

            // Height is the vertical extent
            let height = plane.extentZ

            // Find nearest wall
            var bestWallIdx = -1
            var bestDist: Float = .greatestFiniteMagnitude
            for (i, wall) in walls.enumerated() {
                let dx = wall.endX - wall.startX
                let dz = wall.endZ - wall.startZ
                let len = wall.length
                guard len > 0 else { continue }
                let nx = -dz / len, nz = dx / len
                let perpDist = abs((rx - wall.startX) * nx + (rz - wall.startZ) * nz)
                // Also check that the opening is along the wall's span
                let along = (rx - wall.startX) * (dx / len) + (rz - wall.startZ) * (dz / len)
                let onSpan = along >= -0.3 && along <= len + 0.3
                if perpDist < bestDist && perpDist < 0.5 && onSpan {
                    bestDist = perpDist
                    bestWallIdx = i
                }
            }

            let kind: OpeningKind
            let sillHeight: Float
            if isWindow {
                kind = .window
                // Estimate sill height from plane's vertical position
                let bottomY = worldY - height / 2
                sillHeight = max(0, bottomY - floorY)
            } else {
                // Door classification
                if width >= 1.5 {
                    kind = .slidingDoor
                } else if width >= 1.2 {
                    kind = .doubleDoor
                } else {
                    kind = .standardDoor
                }
                sillHeight = 0
            }

            openings.append(RawOpening(
                kind: kind,
                positionX: rx,
                positionZ: rz,
                width: width,
                height: height,
                sillHeight: sillHeight,
                wallIndex: bestWallIdx >= 0 ? bestWallIdx : 0
            ))
            print("[ObjectDetector] Plane \(isDoor ? "door" : "window"): \(Int(width * 1000))mm wide x \(Int(height * 1000))mm high")
        }

        return openings
    }

    // MARK: - Floor / Ceiling Detection

    private static func findFloorLevel(_ vertices: [(pos: SIMD3<Float>, normal: SIMD3<Float>)]) -> Float {
        var candidates: [Float] = []
        for v in vertices where v.normal.y > 0.8 {
            candidates.append(v.pos.y)
        }
        candidates.sort()
        if candidates.count > 100 {
            return candidates[candidates.count / 10]
        }
        return candidates.first ?? vertices.map(\.pos.y).min() ?? 0
    }

    private static func findCeilingLevel(_ vertices: [(pos: SIMD3<Float>, normal: SIMD3<Float>)], floorY: Float) -> Float {
        var candidates: [Float] = []
        for v in vertices where v.normal.y < -0.8 && v.pos.y > floorY + 1.5 {
            candidates.append(v.pos.y)
        }
        candidates.sort()
        if candidates.count > 50 {
            return candidates[candidates.count * 9 / 10]
        }
        return candidates.last ?? (floorY + 2.4)
    }

    // MARK: - Wall Alignment (rotate to axes)

    private static func alignToWalls(_ vertices: [(pos: SIMD3<Float>, normal: SIMD3<Float>)], floorY: Float) -> ([(pos: SIMD3<Float>, normal: SIMD3<Float>)], Float) {
        // Histogram of horizontal normal angles
        let binCount = 180
        var histogram = Array(repeating: 0, count: binCount)

        for v in vertices {
            guard abs(v.normal.y) < 0.3 else { continue }
            guard v.pos.y >= floorY + 0.5 && v.pos.y <= floorY + 1.5 else { continue }
            var angle = atan2(v.normal.z, v.normal.x)
            if angle < 0 { angle += .pi }
            let bin = min(Int(angle / .pi * Float(binCount)), binCount - 1)
            histogram[bin] += 1
        }

        // Smooth and find peak
        var smoothed = Array(repeating: 0, count: binCount)
        for i in 0..<binCount {
            var sum = 0
            for d in -3...3 {
                sum += histogram[(i + d + binCount) % binCount]
            }
            smoothed[i] = sum
        }

        let peakBin = smoothed.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
        let normalAngle = Float(peakBin) / Float(binCount) * .pi
        let wallAngle = normalAngle - .pi / 2
        let rotAngle = -wallAngle

        let cosA = cos(rotAngle)
        let sinA = sin(rotAngle)

        let rotated = vertices.map { v -> (pos: SIMD3<Float>, normal: SIMD3<Float>) in
            let rx = v.pos.x * cosA - v.pos.z * sinA
            let rz = v.pos.x * sinA + v.pos.z * cosA
            let rnx = v.normal.x * cosA - v.normal.z * sinA
            let rnz = v.normal.x * sinA + v.normal.z * cosA
            return (
                pos: SIMD3<Float>(rx, v.pos.y, rz),
                normal: SIMD3<Float>(rnx, v.normal.y, rnz)
            )
        }

        return (rotated, rotAngle)
    }

    // MARK: - Horizontal Surface Detection (benches, tables, vanities, shelves)

    private static func detectHorizontalSurfaces(_ vertices: [(pos: SIMD3<Float>, normal: SIMD3<Float>)], floorY: Float) -> [TaggedObject] {
        // Group upward-facing vertices by height bands (excluding floor and ceiling)
        struct SurfaceCluster {
            var points: [SIMD3<Float>] = []
            var heightSum: Float = 0
        }

        // Height bands for different surface types (above floor)
        let heightBands: [(min: Float, max: Float, candidates: [ObjectCategory])] = [
            (0.35, 0.55, [.table]),            // Coffee table ~450mm
            (0.70, 0.82, [.table, .bed]),      // Desk/table ~750mm, bed ~700mm
            (0.82, 0.92, [.vanity]),           // Bathroom vanity ~850mm
            (0.88, 0.98, [.kitchenBench]),     // Kitchen bench ~900mm
        ]

        var objects: [TaggedObject] = []

        for band in heightBands {
            let bandMin = floorY + band.min
            let bandMax = floorY + band.max

            // Collect points in this height band with upward normal
            var surfacePoints: [SIMD3<Float>] = []
            for v in vertices where v.normal.y > 0.6 && v.pos.y >= bandMin && v.pos.y <= bandMax {
                surfacePoints.append(v.pos)
            }

            guard surfacePoints.count > 20 else { continue }

            // Cluster these points spatially (simple grid-based clustering)
            let clusters = clusterPoints2D(surfacePoints, cellSize: 0.3, minPoints: 10)

            for cluster in clusters {
                let minX = cluster.map(\.x).min()!
                let maxX = cluster.map(\.x).max()!
                let minZ = cluster.map(\.z).min()!
                let maxZ = cluster.map(\.z).max()!
                let avgY = cluster.map(\.y).reduce(0, +) / Float(cluster.count)

                let width = maxX - minX
                let depth = maxZ - minZ
                let heightAboveFloor = avgY - floorY

                // Skip tiny surfaces or massive ones (probably floor fragments)
                guard width > 0.3 && depth > 0.2 && width < 4.0 && depth < 2.0 else { continue }

                // Classify based on height and shape
                let category: ObjectCategory
                if heightAboveFloor > 0.88 && width > 1.0 {
                    category = .kitchenBench
                } else if heightAboveFloor > 0.82 && width < 1.5 && depth < 0.8 {
                    category = .vanity
                } else if heightAboveFloor > 0.70 && heightAboveFloor < 0.82 {
                    if width > 1.2 && depth > 0.8 {
                        category = .bed
                    } else {
                        category = .table
                    }
                } else {
                    category = .table
                }

                let obj = TaggedObject(
                    id: UUID(),
                    category: category,
                    positionX: (minX + maxX) / 2,
                    positionY: avgY,
                    positionZ: (minZ + maxZ) / 2,
                    dimensionsX: width,
                    dimensionsY: heightAboveFloor,
                    dimensionsZ: depth,
                    source: .ai
                )
                objects.append(obj)
                print("[ObjectDetector] \(category.rawValue): \(Int(width * 1000))x\(Int(depth * 1000))mm at height \(Int(heightAboveFloor * 1000))mm")
            }
        }

        return objects
    }

    // MARK: - Fixture Detection (toilet, bath, shower)

    private static func detectFixtures(_ vertices: [(pos: SIMD3<Float>, normal: SIMD3<Float>)], floorY: Float) -> [TaggedObject] {
        var objects: [TaggedObject] = []

        // TOILET: Cluster of vertices at ~380-420mm height, ~400x600mm footprint
        let toiletHeightMin = floorY + 0.30
        let toiletHeightMax = floorY + 0.50
        var toiletPoints: [SIMD3<Float>] = []
        for v in vertices where v.normal.y > 0.5 && v.pos.y >= toiletHeightMin && v.pos.y <= toiletHeightMax {
            toiletPoints.append(v.pos)
        }
        let toiletClusters = clusterPoints2D(toiletPoints, cellSize: 0.15, minPoints: 8)
        for cluster in toiletClusters {
            let w = cluster.map(\.x).max()! - cluster.map(\.x).min()!
            let d = cluster.map(\.z).max()! - cluster.map(\.z).min()!
            // Toilet-sized: roughly 350-500mm x 500-750mm
            if w > 0.25 && w < 0.6 && d > 0.35 && d < 0.85 {
                let cx = (cluster.map(\.x).min()! + cluster.map(\.x).max()!) / 2
                let cz = (cluster.map(\.z).min()! + cluster.map(\.z).max()!) / 2
                let cy = cluster.map(\.y).reduce(0, +) / Float(cluster.count)
                objects.append(TaggedObject(
                    id: UUID(), category: .toilet,
                    positionX: cx, positionY: cy, positionZ: cz,
                    dimensionsX: w, dimensionsY: cy - floorY, dimensionsZ: d,
                    source: .ai
                ))
                print("[ObjectDetector] toilet: \(Int(w * 1000))x\(Int(d * 1000))mm")
            }
        }

        // BATHTUB: Long horizontal surface at ~500-600mm, ~1500-1800mm x 600-800mm
        let bathMin = floorY + 0.45
        let bathMax = floorY + 0.65
        var bathPoints: [SIMD3<Float>] = []
        for v in vertices where v.normal.y > 0.5 && v.pos.y >= bathMin && v.pos.y <= bathMax {
            bathPoints.append(v.pos)
        }
        let bathClusters = clusterPoints2D(bathPoints, cellSize: 0.2, minPoints: 15)
        for cluster in bathClusters {
            let w = cluster.map(\.x).max()! - cluster.map(\.x).min()!
            let d = cluster.map(\.z).max()! - cluster.map(\.z).min()!
            let longSide = max(w, d)
            let shortSide = min(w, d)
            if longSide > 1.2 && longSide < 2.0 && shortSide > 0.5 && shortSide < 0.9 {
                let cx = (cluster.map(\.x).min()! + cluster.map(\.x).max()!) / 2
                let cz = (cluster.map(\.z).min()! + cluster.map(\.z).max()!) / 2
                objects.append(TaggedObject(
                    id: UUID(), category: .bathtub,
                    positionX: cx, positionY: (bathMin + bathMax) / 2, positionZ: cz,
                    dimensionsX: w, dimensionsY: 0.55, dimensionsZ: d,
                    source: .ai
                ))
                print("[ObjectDetector] bathtub: \(Int(w * 1000))x\(Int(d * 1000))mm")
            }
        }

        // SHOWER: Enclosed floor area with walls on 2-3 sides, ~800x800mm to 1200x1200mm
        // Detected as a floor-level region bounded by walls
        // (Simplified: look for small recessed floor areas with surrounding wall vertices)
        let showerCandidates = detectShowerEnclosures(vertices, floorY: floorY)
        objects.append(contentsOf: showerCandidates)

        return objects
    }

    private static func detectShowerEnclosures(_ vertices: [(pos: SIMD3<Float>, normal: SIMD3<Float>)], floorY: Float) -> [TaggedObject] {
        // Showers are floor-level areas bounded by wall vertices on multiple sides
        // Look for rectangular wall arrangements that form 800-1500mm enclosures

        // Collect wall vertices at ~1m height
        var wallPts: [(x: Float, z: Float)] = []
        for v in vertices where abs(v.normal.y) < 0.3 && v.pos.y >= floorY + 0.8 && v.pos.y <= floorY + 1.2 {
            wallPts.append((x: v.pos.x, z: v.pos.z))
        }

        // Look for L-shaped or U-shaped wall clusters in small areas
        // This is a simplified version — full implementation would trace wall contours
        // For now, detect small enclosed floor areas (future improvement)
        return []
    }

    // MARK: - Ceiling Fixture Detection (fans, lights)

    private static func detectCeilingFixtures(_ vertices: [(pos: SIMD3<Float>, normal: SIMD3<Float>)], floorY: Float, ceilingY: Float) -> [TaggedObject] {
        var objects: [TaggedObject] = []

        // CEILING FAN: Circular cluster of vertices just below ceiling, ~1000-1400mm diameter
        let fanMin = ceilingY - 0.3
        let fanMax = ceilingY + 0.1

        var ceilingPoints: [SIMD3<Float>] = []
        for v in vertices where v.pos.y >= fanMin && v.pos.y <= fanMax && v.normal.y < -0.3 {
            ceilingPoints.append(v.pos)
        }

        let ceilingClusters = clusterPoints2D(ceilingPoints, cellSize: 0.2, minPoints: 10)
        for cluster in ceilingClusters {
            let minX = cluster.map(\.x).min()!
            let maxX = cluster.map(\.x).max()!
            let minZ = cluster.map(\.z).min()!
            let maxZ = cluster.map(\.z).max()!
            let w = maxX - minX
            let d = maxZ - minZ

            // Fan: roughly circular, 0.8-1.5m across
            let aspectRatio = min(w, d) / max(w, d)
            if w > 0.8 && w < 1.6 && d > 0.8 && d < 1.6 && aspectRatio > 0.6 {
                objects.append(TaggedObject(
                    id: UUID(), category: .ceilingFan,
                    positionX: (minX + maxX) / 2, positionY: ceilingY, positionZ: (minZ + maxZ) / 2,
                    dimensionsX: w, dimensionsY: 0.3, dimensionsZ: d,
                    source: .ai
                ))
                print("[ObjectDetector] ceilingFan: \(Int(w * 1000))x\(Int(d * 1000))mm")
            }
        }

        return objects
    }

    // MARK: - Wall Feature Detection (fireplace, niches, built-in shelves)

    private static func detectWallFeatures(_ vertices: [(pos: SIMD3<Float>, normal: SIMD3<Float>)], floorY: Float, ceilingY: Float) -> [TaggedObject] {
        var objects: [TaggedObject] = []

        // FIREPLACE: Recessed area in wall with hearth (~200-400mm above floor)
        // Look for inward-facing horizontal surface (hearth) with wall recess above
        let hearthMin = floorY + 0.1
        let hearthMax = floorY + 0.5
        var hearthPoints: [SIMD3<Float>] = []
        for v in vertices where v.normal.y > 0.6 && v.pos.y >= hearthMin && v.pos.y <= hearthMax {
            hearthPoints.append(v.pos)
        }

        let hearthClusters = clusterPoints2D(hearthPoints, cellSize: 0.15, minPoints: 5)
        for cluster in hearthClusters {
            let w = cluster.map(\.x).max()! - cluster.map(\.x).min()!
            let d = cluster.map(\.z).max()! - cluster.map(\.z).min()!
            // Fireplace hearth: ~800-1500mm wide, ~300-600mm deep, raised above floor
            if w > 0.6 && w < 1.8 && d > 0.2 && d < 0.7 {
                let cx = (cluster.map(\.x).min()! + cluster.map(\.x).max()!) / 2
                let cz = (cluster.map(\.z).min()! + cluster.map(\.z).max()!) / 2
                let avgY = cluster.map(\.y).reduce(0, +) / Float(cluster.count)

                // Verify there's a recess above (wall vertices going inward)
                let recessCount = vertices.filter { v in
                    abs(v.pos.x - cx) < w / 2 && abs(v.pos.z - cz) < 0.5 &&
                    v.pos.y > avgY && v.pos.y < avgY + 1.0 && abs(v.normal.y) < 0.3
                }.count

                if recessCount > 15 {
                    objects.append(TaggedObject(
                        id: UUID(), category: .fireplace,
                        positionX: cx, positionY: avgY, positionZ: cz,
                        dimensionsX: w, dimensionsY: 1.0, dimensionsZ: d,
                        source: .ai
                    ))
                    print("[ObjectDetector] fireplace: \(Int(w * 1000))x\(Int(d * 1000))mm hearth")
                }
            }
        }

        // STORAGE/WARDROBE: Deep recess in wall, floor to ~2100mm
        // (Simplified detection — look for wall-adjacent rectangular voids)

        return objects
    }

    // MARK: - Wall Point Extraction & Fitting

    private static func extractWallPoints(_ vertices: [(pos: SIMD3<Float>, normal: SIMD3<Float>, classification: UInt8)], floorY: Float) -> [(x: Float, z: Float)] {
        // ARMeshClassification values: 0=none, 1=wall, 2=floor, 3=ceiling, 4=table, 5=seat, 6=door, 7=window
        let wallClassifications: Set<UInt8> = [0, 1, 6, 7]  // none (unclassified), wall, door, window
        var points: [(x: Float, z: Float)] = []
        for v in vertices {
            let isWallNormal = abs(v.normal.y) < 0.3
            let inSlice = v.pos.y >= floorY + 0.5 && v.pos.y <= floorY + 1.5
            // If classifications are available, filter out non-wall surfaces (tables, seats, floors, ceilings)
            let classOK = v.classification == 0 || wallClassifications.contains(v.classification)
            if isWallNormal && inSlice && classOK {
                points.append((x: v.pos.x, z: v.pos.z))
            }
        }
        return points
    }

    private static func fitRawWalls(from points: [(x: Float, z: Float)]) -> [RawWall] {
        guard points.count >= 20 else { return [] }

        var remaining = points
        var walls: [RawWall] = []
        let minInliers = max(20, points.count / 50)

        for _ in 0..<15 {
            guard remaining.count >= minInliers else { break }

            var bestInliers: [(x: Float, z: Float)] = []
            var bestOutliers: [(x: Float, z: Float)] = []
            var bestWall: RawWall?

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
                    let dist = abs((p.x - p1.x) * nx + (p.z - p1.z) * nz)
                    if dist < 0.08 {
                        inliers.append(p)
                    } else {
                        outliers.append(p)
                    }
                }

                if inliers.count > bestInliers.count {
                    var minT: Float = .greatestFiniteMagnitude
                    var maxT: Float = -.greatestFiniteMagnitude
                    var perpDists: [Float] = []

                    for p in inliers {
                        let t = (p.x - p1.x) * (dx / len) + (p.z - p1.z) * (dz / len)
                        minT = min(minT, t)
                        maxT = max(maxT, t)
                        perpDists.append((p.x - p1.x) * nx + (p.z - p1.z) * nz)
                    }
                    perpDists.sort()
                    let thickness = perpDists.count > 10 ?
                        perpDists[perpDists.count * 9 / 10] - perpDists[perpDists.count / 10] : 0.07

                    let wallLen = maxT - minT
                    let wallAngle = atan2(dz, dx)
                    if wallLen > 0.3 {
                        bestInliers = inliers
                        bestOutliers = outliers
                        bestWall = RawWall(
                            startX: p1.x + (dx / len) * minT,
                            startZ: p1.z + (dz / len) * minT,
                            endX: p1.x + (dx / len) * maxT,
                            endZ: p1.z + (dz / len) * maxT,
                            thickness: thickness,
                            length: wallLen,
                            angle: wallAngle
                        )
                    }
                }
            }

            guard let wall = bestWall, bestInliers.count >= minInliers else { break }
            walls.append(wall)
            remaining = bestOutliers
        }

        return walls
    }

    // MARK: - Opening Detection

    private static func detectRawOpenings(wallLines: [RawWall], vertices: [Vertex], floorY: Float, ceilingY: Float = 2.4) -> [RawOpening] {
        var openings: [RawOpening] = []

        for (wallIndex, wall) in wallLines.enumerated() where wall.length > 1.0 {
            let dx = wall.endX - wall.startX
            let dz = wall.endZ - wall.startZ
            let len = wall.length
            let nx = -dz / len, nz = dx / len

            let segSize: Float = 0.1
            let segCount = Int(len / segSize)
            guard segCount > 3 else { continue }

            // Count wall vertices per segment at different heights
            var densityLow = Array(repeating: 0, count: segCount)  // 0-0.5m
            var densityMid = Array(repeating: 0, count: segCount)  // 0.5-2.0m
            var densityHigh = Array(repeating: 0, count: segCount) // 2.0-2.5m

            for v in vertices {
                let perpDist = abs((v.pos.x - wall.startX) * nx + (v.pos.z - wall.startZ) * nz)
                guard perpDist < 0.15 && abs(v.normal.y) < 0.3 else { continue }

                let t = (v.pos.x - wall.startX) * (dx / len) + (v.pos.z - wall.startZ) * (dz / len)
                let seg = Int(t / segSize)
                guard seg >= 0 && seg < segCount else { continue }

                let h = v.pos.y - floorY
                if h >= 0 && h < 0.5 { densityLow[seg] += 1 }
                else if h >= 0.5 && h < 2.0 { densityMid[seg] += 1 }
                else if h >= 2.0 && h < 2.5 { densityHigh[seg] += 1 }
            }

            let avgDensity = densityMid.reduce(0, +) / max(1, segCount)
            let gapThreshold = max(2, avgDensity / 4)

            var inGap = false
            var gapStart = 0

            for seg in 0..<segCount {
                let sparse = densityMid[seg] < gapThreshold

                if sparse && !inGap {
                    inGap = true
                    gapStart = seg
                } else if !sparse && inGap {
                    inGap = false
                    let gapWidth = Float(seg - gapStart) * segSize

                    if gapWidth >= 0.5 && gapWidth <= 5.0 {
                        let center = Float(gapStart + seg) / 2 * segSize
                        let posX = wall.startX + (dx / len) * center
                        let posZ = wall.startZ + (dz / len) * center

                        // Check for wall below gap (window sill)
                        let lowDensity = (gapStart..<seg).map { densityLow[$0] }.reduce(0, +)
                        let hasWallBelow = lowDensity > (seg - gapStart) * 2
                        let sillHeight: Float = hasWallBelow ? 0.9 : 0

                        // Fix 4: Calculate actual opening height from mesh gap
                        // Find the highest point with wall density above the gap
                        let gapCenterX = posX
                        let gapCenterZ = posZ
                        var maxGapHeight: Float = ceilingY - floorY  // default to full height
                        // Search for the lintel (top of opening) by scanning upward
                        let heightStep: Float = 0.1
                        var testHeight = floorY + (hasWallBelow ? 1.0 : 0.3)
                        while testHeight < ceilingY {
                            // Count wall vertices at this height in the gap region
                            var countAtHeight = 0
                            for v in vertices {
                                let perpDist = abs((v.pos.x - wall.startX) * nx + (v.pos.z - wall.startZ) * nz)
                                guard perpDist < 0.15 && abs(v.normal.y) < 0.3 else { continue }
                                let t = (v.pos.x - wall.startX) * (dx / len) + (v.pos.z - wall.startZ) * (dz / len)
                                let inGapRange = t >= Float(gapStart) * segSize && t <= Float(seg) * segSize
                                let atHeight = abs(v.pos.y - testHeight) < heightStep / 2
                                if inGapRange && atHeight { countAtHeight += 1 }
                            }
                            // If we find wall material, the opening ends here
                            if countAtHeight > 3 {
                                maxGapHeight = testHeight - floorY - sillHeight
                                break
                            }
                            testHeight += heightStep
                        }
                        // Clamp to reasonable range
                        let openingHeight = max(0.5, min(maxGapHeight, ceilingY - floorY))

                        let kind: OpeningKind
                        if hasWallBelow {
                            kind = .window
                        } else if gapWidth >= 2.4 {
                            kind = .garageDoor
                        } else if gapWidth >= 1.5 {
                            kind = .slidingDoor
                        } else if gapWidth >= 1.2 {
                            kind = .doubleDoor
                        } else if gapWidth >= 0.6 {
                            kind = .standardDoor
                        } else {
                            kind = .openingPassthrough
                        }

                        openings.append(RawOpening(
                            kind: kind,
                            positionX: posX, positionZ: posZ,
                            width: gapWidth,
                            height: openingHeight,
                            sillHeight: sillHeight,
                            wallIndex: wallIndex
                        ))
                        print("[ObjectDetector] \(kind.rawValue): \(Int(gapWidth * 1000))mm wide x \(Int(openingHeight * 1000))mm high at (\(String(format: "%.2f", posX)), \(String(format: "%.2f", posZ)))")
                    }
                }
            }
        }

        return openings
    }

    // MARK: - Room Measurement

    private static func measureRoomFromRawWalls(wallLines: [RawWall]) -> (width: Float, depth: Float)? {
        var xAligned: [RawWall] = []
        var zAligned: [RawWall] = []

        for wall in wallLines where wall.length > 0.5 {
            let angle = atan2(wall.endZ - wall.startZ, wall.endX - wall.startX)
            let tolerance: Float = 15 * .pi / 180
            let absAngle = abs(angle)

            if absAngle < tolerance || abs(absAngle - .pi) < tolerance {
                xAligned.append(wall)
            } else if abs(absAngle - .pi / 2) < tolerance {
                zAligned.append(wall)
            }
        }

        let xByZ = xAligned.sorted { ($0.startZ + $0.endZ) / 2 < ($1.startZ + $1.endZ) / 2 }
        let zByX = zAligned.sorted { ($0.startX + $0.endX) / 2 < ($1.startX + $1.endX) / 2 }

        var depth: Float = 0
        if xByZ.count >= 2 {
            let near = xByZ.first!, far = xByZ.last!
            let nearZ = (near.startZ + near.endZ) / 2
            let farZ = (far.startZ + far.endZ) / 2
            depth = abs(farZ - nearZ) - (near.thickness + far.thickness) / 2
        }

        var width: Float = 0
        if zByX.count >= 2 {
            let left = zByX.first!, right = zByX.last!
            let leftX = (left.startX + left.endX) / 2
            let rightX = (right.startX + right.endX) / 2
            width = abs(rightX - leftX) - (left.thickness + right.thickness) / 2
        }

        guard width > 0 && depth > 0 else { return nil }
        return (width: width, depth: depth)
    }

    // MARK: - Spatial Clustering

    private static func clusterPoints2D(_ points: [SIMD3<Float>], cellSize: Float, minPoints: Int) -> [[SIMD3<Float>]] {
        guard !points.isEmpty else { return [] }

        // Grid-based clustering
        var grid: [String: [SIMD3<Float>]] = [:]
        for p in points {
            let key = "\(Int(p.x / cellSize)),\(Int(p.z / cellSize))"
            grid[key, default: []].append(p)
        }

        // Merge adjacent cells using flood fill
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

                if let pts = grid[current] {
                    cluster.append(contentsOf: pts)
                }

                // Check 8 neighbors
                let parts = current.split(separator: ",")
                guard parts.count == 2, let cx = Int(parts[0]), let cz = Int(parts[1]) else { continue }

                for dx in -1...1 {
                    for dz in -1...1 {
                        if dx == 0 && dz == 0 { continue }
                        let neighbor = "\(cx + dx),\(cz + dz)"
                        if grid[neighbor] != nil && !visited.contains(neighbor) {
                            queue.append(neighbor)
                        }
                    }
                }
            }

            if cluster.count >= minPoints {
                clusters.append(cluster)
            }
        }

        return clusters
    }
}
