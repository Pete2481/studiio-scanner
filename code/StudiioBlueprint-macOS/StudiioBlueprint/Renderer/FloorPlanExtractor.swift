import Foundation
import CoreGraphics

/// Extracts 2D floor plan geometry from a PropertyProject's 3D scan data.
/// Converts rooms with 3D positions into 2D polygons and wall segments.
enum FloorPlanExtractor {

    // MARK: - Extract Layout

    /// Generate a FloorPlanLayout from a single floor's data.
    /// Projects 3D room data to 2D (XZ plane, Y is height).
    static func extractLayout(from floor: Floor) -> FloorPlanLayout {
        var rooms: [RoomPolygon] = []
        var walls: [WallSegment] = []

        for room in floor.rooms {
            let roomPoly = extractRoomPolygon(room: room)
            rooms.append(roomPoly)

            // Generate walls from room polygon edges
            let roomWalls = generateWalls(from: roomPoly.polygon, isExterior: false)
            walls.append(contentsOf: roomWalls)
        }

        // Detect exterior walls (walls on the convex hull)
        markExteriorWalls(&walls, rooms: rooms)

        // Merge coincident walls (shared walls between rooms)
        let mergedWalls = mergeCoincidentWalls(walls)

        return FloorPlanLayout(
            rooms: rooms,
            walls: mergedWalls,
            floorName: floor.name,
            totalArea: floor.rooms.reduce(0) { $0 + $1.area }
        )
    }

    // MARK: - Room Polygon Extraction

    /// Extract a 2D polygon for a room from its objects' positions.
    /// Uses object positions to infer room boundaries.
    private static func extractRoomPolygon(room: Room) -> RoomPolygon {
        let isBathroom = isBathroomRoom(room)

        // If the room has area and objects, compute a bounding rectangle
        // from object positions projected to XZ plane
        if !room.objects.isEmpty {
            let positions = room.objects.map { obj in
                CGPoint(x: CGFloat(obj.positionX), y: CGFloat(obj.positionZ))
            }

            // Expand beyond object positions to form room boundaries
            let polygon = computeExpandedBounds(positions: positions, roomArea: room.area)
            return RoomPolygon(
                name: room.name,
                polygon: polygon,
                area: room.area,
                objects: room.objects,
                isBathroom: isBathroom
            )
        }

        // Fallback: generate a rectangle from area with assumed aspect ratio
        let side = sqrt(room.area)
        let polygon = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: side, y: 0),
            CGPoint(x: side, y: side),
            CGPoint(x: 0, y: side)
        ]

        return RoomPolygon(
            name: room.name,
            polygon: polygon,
            area: room.area,
            objects: room.objects,
            isBathroom: isBathroom
        )
    }

    /// Expand object positions into a room boundary rectangle
    private static func computeExpandedBounds(positions: [CGPoint], roomArea: Double) -> [CGPoint] {
        guard !positions.isEmpty else { return [] }

        var minX = positions[0].x, maxX = positions[0].x
        var minY = positions[0].y, maxY = positions[0].y

        for p in positions {
            minX = min(minX, p.x)
            maxX = max(maxX, p.x)
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
        }

        // Expand by 0.5m padding (walls sit beyond furniture)
        let padding: CGFloat = 0.5
        minX -= padding
        maxX += padding
        minY -= padding
        maxY += padding

        // If the calculated area is much smaller than reported, expand proportionally
        let calcWidth = maxX - minX
        let calcHeight = maxY - minY
        let calcArea = Double(calcWidth * calcHeight)

        if calcArea > 0 && roomArea > calcArea * 1.5 {
            let scaleFactor = CGFloat(sqrt(roomArea / calcArea))
            let cx = (minX + maxX) / 2
            let cy = (minY + maxY) / 2
            let halfW = calcWidth * scaleFactor / 2
            let halfH = calcHeight * scaleFactor / 2
            minX = cx - halfW
            maxX = cx + halfW
            minY = cy - halfH
            maxY = cy + halfH
        }

        return [
            CGPoint(x: minX, y: minY),
            CGPoint(x: maxX, y: minY),
            CGPoint(x: maxX, y: maxY),
            CGPoint(x: minX, y: maxY)
        ]
    }

    // MARK: - Wall Generation

    private static func generateWalls(from polygon: [CGPoint], isExterior: Bool) -> [WallSegment] {
        guard polygon.count >= 2 else { return [] }
        var walls: [WallSegment] = []
        for i in 0..<polygon.count {
            let next = (i + 1) % polygon.count
            walls.append(WallSegment(
                start: polygon[i],
                end: polygon[next],
                thickness: isExterior ? 0.2 : 0.1,
                isExterior: isExterior
            ))
        }
        return walls
    }

    /// Mark walls that are on the outer boundary as exterior
    private static func markExteriorWalls(_ walls: inout [WallSegment], rooms: [RoomPolygon]) {
        // Compute convex hull of all room polygons
        var allPoints: [CGPoint] = []
        for room in rooms {
            allPoints.append(contentsOf: room.polygon)
        }
        let hull = convexHull(allPoints)

        // A wall is exterior if both its endpoints are on (or very near) the hull
        for i in 0..<walls.count {
            let isOnHull = isPointNearHull(walls[i].start, hull: hull, tolerance: 0.3)
                && isPointNearHull(walls[i].end, hull: hull, tolerance: 0.3)
            if isOnHull {
                walls[i].isExterior = true
                walls[i] = WallSegment(
                    id: walls[i].id,
                    start: walls[i].start,
                    end: walls[i].end,
                    thickness: 0.2,
                    isExterior: true
                )
            }
        }
    }

    /// Merge walls that are coincident (shared walls between adjacent rooms)
    private static func mergeCoincidentWalls(_ walls: [WallSegment]) -> [WallSegment] {
        var merged: [WallSegment] = []
        var used = Set<UUID>()

        for i in 0..<walls.count {
            guard !used.contains(walls[i].id) else { continue }

            var best = walls[i]
            for j in (i + 1)..<walls.count {
                guard !used.contains(walls[j].id) else { continue }

                if areWallsCoincident(walls[i], walls[j], tolerance: 0.2) {
                    used.insert(walls[j].id)
                    // Keep the thicker/exterior version
                    if walls[j].isExterior { best = walls[j] }
                }
            }

            merged.append(best)
        }

        return merged
    }

    private static func areWallsCoincident(_ a: WallSegment, _ b: WallSegment, tolerance: CGFloat) -> Bool {
        let startClose = distance(a.start, b.start) < tolerance || distance(a.start, b.end) < tolerance
        let endClose = distance(a.end, b.end) < tolerance || distance(a.end, b.start) < tolerance
        return startClose && endClose
    }

    // MARK: - Bathroom Detection

    private static func isBathroomRoom(_ room: Room) -> Bool {
        let bathroomNames = ["bathroom", "ensuite", "wc", "toilet", "powder room", "wash"]
        let lower = room.name.lowercased()
        if bathroomNames.contains(where: { lower.contains($0) }) { return true }

        let bathroomObjects: Set<ObjectCategory> = [.toilet, .shower, .bathtub, .vanity]
        return room.objects.contains { bathroomObjects.contains($0.category) }
    }

    // MARK: - Geometry Helpers

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// Simple convex hull (Graham scan)
    static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count >= 3 else { return points }

        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        var lower: [CGPoint] = []
        for p in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }

        var upper: [CGPoint] = []
        for p in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }

        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    private static func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }

    private static func isPointNearHull(_ point: CGPoint, hull: [CGPoint], tolerance: CGFloat) -> Bool {
        for i in 0..<hull.count {
            let next = (i + 1) % hull.count
            let dist = pointToSegmentDistance(point, hull[i], hull[next])
            if dist < tolerance { return true }
        }
        return false
    }

    private static func pointToSegmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return distance(p, a) }

        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq
        t = max(0, min(1, t))
        let proj = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return distance(p, proj)
    }
}
