import Foundation
import CoreGraphics

/// Geometry types used by the 2D blueprint renderer.
/// All measurements are in metres; the renderer scales to screen/page coordinates.

// MARK: - Blueprint Wall (renderer's wall type, distinct from model WallSegment)

struct BlueprintWall: Identifiable {
    let id: UUID
    var start: CGPoint     // metres
    var end: CGPoint       // metres
    var thickness: CGFloat // metres (auto-detected or default)
    var isExterior: Bool

    init(
        id: UUID = UUID(),
        start: CGPoint,
        end: CGPoint,
        thickness: CGFloat = 0.1,
        isExterior: Bool = false,
        length: CGFloat? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.thickness = thickness
        self.isExterior = isExterior
    }

    var length: CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }

    var midpoint: CGPoint {
        CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
    }

    var angle: CGFloat {
        atan2(end.y - start.y, end.x - start.x)
    }
}

// MARK: - Room Polygon

struct RoomPolygon: Identifiable {
    let id: UUID
    var name: String
    var polygon: [CGPoint]   // vertices in metres
    var area: Double         // m2
    var objects: [TaggedObject]
    var isBathroom: Bool     // blue fill
    var isOutdoor: Bool      // hatching

    init(
        id: UUID = UUID(),
        name: String,
        polygon: [CGPoint],
        area: Double = 0,
        objects: [TaggedObject] = [],
        isBathroom: Bool = false,
        isOutdoor: Bool = false
    ) {
        self.id = id
        self.name = name
        self.polygon = polygon
        self.area = area
        self.objects = objects
        self.isBathroom = isBathroom
        self.isOutdoor = isOutdoor
    }

    var centroid: CGPoint {
        guard !polygon.isEmpty else { return .zero }
        let sumX = polygon.reduce(0) { $0 + $1.x }
        let sumY = polygon.reduce(0) { $0 + $1.y }
        return CGPoint(x: sumX / CGFloat(polygon.count), y: sumY / CGFloat(polygon.count))
    }

    var bounds: CGRect {
        guard let first = polygon.first else { return .zero }
        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for p in polygon {
            minX = min(minX, p.x)
            maxX = max(maxX, p.x)
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    var widthMetres: CGFloat { bounds.width }
    var heightMetres: CGFloat { bounds.height }
}

// MARK: - Floor Plan Layout

struct FloorPlanLayout {
    var rooms: [RoomPolygon]
    var walls: [BlueprintWall]
    var floorName: String
    var totalArea: Double

    var bounds: CGRect {
        var allPoints: [CGPoint] = []
        for room in rooms {
            allPoints.append(contentsOf: room.polygon)
        }
        for wall in walls {
            allPoints.append(wall.start)
            allPoints.append(wall.end)
        }
        guard let first = allPoints.first else { return .zero }
        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for p in allPoints {
            minX = min(minX, p.x)
            maxX = max(maxX, p.x)
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: - Scale & Transform

struct BlueprintTransform {
    let scale: CGFloat
    let offset: CGPoint
    let metricScale: String

    static func forA3(planBounds: CGRect, canvasSize: CGSize, margin: CGFloat = 60) -> BlueprintTransform {
        let availableWidth = canvasSize.width - 2 * margin
        let availableHeight = canvasSize.height - 2 * margin

        let scaleX = availableWidth / planBounds.width
        let scaleY = availableHeight / planBounds.height
        let scale = min(scaleX, scaleY)

        let planWidth = planBounds.width * scale
        let planHeight = planBounds.height * scale

        let offsetX = margin + (availableWidth - planWidth) / 2 - planBounds.minX * scale
        let offsetY = margin + (availableHeight - planHeight) / 2 - planBounds.minY * scale

        return BlueprintTransform(
            scale: scale,
            offset: CGPoint(x: offsetX, y: offsetY),
            metricScale: "1:100"
        )
    }

    func point(from metres: CGPoint) -> CGPoint {
        CGPoint(
            x: metres.x * scale + offset.x,
            y: metres.y * scale + offset.y
        )
    }

    func length(from metres: CGFloat) -> CGFloat {
        metres * scale
    }
}
