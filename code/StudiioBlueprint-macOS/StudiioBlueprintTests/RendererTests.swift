import Testing
import Foundation
import CoreGraphics
@testable import StudiioBlueprint

@Suite("Blueprint Renderer Tests")
struct RendererTests {

    // MARK: - Geometry

    @Test("BlueprintWall calculates length correctly")
    func testWallLength() {
        let wall = BlueprintWall(
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 3, y: 4),
            thickness: 0.1
        )
        #expect(abs(wall.length - 5.0) < 0.001)
    }

    @Test("BlueprintWall calculates midpoint correctly")
    func testWallMidpoint() {
        let wall = BlueprintWall(
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 4, y: 6)
        )
        #expect(wall.midpoint.x == 2)
        #expect(wall.midpoint.y == 3)
    }

    @Test("RoomPolygon calculates centroid correctly")
    func testCentroid() {
        let polygon = RoomPolygon(
            name: "Test",
            polygon: [
                CGPoint(x: 0, y: 0),
                CGPoint(x: 4, y: 0),
                CGPoint(x: 4, y: 4),
                CGPoint(x: 0, y: 4)
            ],
            area: 16
        )
        #expect(polygon.centroid.x == 2)
        #expect(polygon.centroid.y == 2)
    }

    @Test("RoomPolygon calculates bounds correctly")
    func testBounds() {
        let polygon = RoomPolygon(
            name: "Test",
            polygon: [
                CGPoint(x: 1, y: 2),
                CGPoint(x: 5, y: 2),
                CGPoint(x: 5, y: 6),
                CGPoint(x: 1, y: 6)
            ]
        )
        #expect(polygon.bounds.minX == 1)
        #expect(polygon.bounds.minY == 2)
        #expect(polygon.bounds.width == 4)
        #expect(polygon.bounds.height == 4)
    }

    // MARK: - Transform

    @Test("BlueprintTransform scales correctly")
    func testTransformScale() {
        let transform = BlueprintTransform(scale: 100, offset: .zero, metricScale: "1:100")
        let result = transform.point(from: CGPoint(x: 1.0, y: 2.0))
        #expect(result.x == 100)
        #expect(result.y == 200)
    }

    @Test("BlueprintTransform applies offset")
    func testTransformOffset() {
        let transform = BlueprintTransform(scale: 50, offset: CGPoint(x: 10, y: 20), metricScale: "1:100")
        let result = transform.point(from: CGPoint(x: 1.0, y: 1.0))
        #expect(result.x == 60) // 1*50 + 10
        #expect(result.y == 70) // 1*50 + 20
    }

    @Test("BlueprintTransform forA3 computes valid scale")
    func testA3Transform() {
        let bounds = CGRect(x: 0, y: 0, width: 10, height: 8)
        let canvas = CGSize(width: 1190, height: 842)
        let transform = BlueprintTransform.forA3(planBounds: bounds, canvasSize: canvas)

        #expect(transform.scale > 0)
        #expect(transform.metricScale == "1:100")
    }

    // MARK: - Extractor

    @Test("FloorPlanExtractor generates layout from a floor")
    func testExtractLayout() {
        let room = Room(
            name: "Kitchen",
            objects: [
                TaggedObject(
                    id: UUID(),
                    category: .stove,
                    positionX: 1, positionY: 0, positionZ: 1,
                    dimensionsX: 0.6, dimensionsY: 0.9, dimensionsZ: 0.6,
                    source: .autoRoomPlan
                ),
                TaggedObject(
                    id: UUID(),
                    category: .refrigerator,
                    positionX: 3, positionY: 0, positionZ: 1,
                    dimensionsX: 0.7, dimensionsY: 1.8, dimensionsZ: 0.7,
                    source: .autoRoomPlan
                )
            ],
            area: 12.0
        )

        let floor = Floor(name: "Ground", rooms: [room])
        let layout = FloorPlanExtractor.extractLayout(from: floor)

        #expect(layout.rooms.count == 1)
        #expect(layout.rooms[0].name == "Kitchen")
        #expect(!layout.walls.isEmpty)
        #expect(layout.floorName == "Ground")
        #expect(layout.totalArea == 12.0)
    }

    @Test("Bathroom detection recognises room with toilet")
    func testBathroomDetection() {
        let room = Room(
            name: "Room 1",
            objects: [
                TaggedObject(
                    id: UUID(),
                    category: .toilet,
                    positionX: 1, positionY: 0, positionZ: 1,
                    dimensionsX: 0.4, dimensionsY: 0.5, dimensionsZ: 0.6,
                    source: .autoRoomPlan
                )
            ],
            area: 4.0
        )

        let floor = Floor(name: "Ground", rooms: [room])
        let layout = FloorPlanExtractor.extractLayout(from: floor)

        #expect(layout.rooms[0].isBathroom == true)
    }

    @Test("Bathroom detection recognises 'Ensuite' name")
    func testBathroomByName() {
        let room = Room(name: "Ensuite", area: 5.0)
        let floor = Floor(name: "Ground", rooms: [room])
        let layout = FloorPlanExtractor.extractLayout(from: floor)

        #expect(layout.rooms[0].isBathroom == true)
    }

    @Test("Non-bathroom room is not marked as bathroom")
    func testNonBathroom() {
        let room = Room(
            name: "Kitchen",
            objects: [
                TaggedObject(
                    id: UUID(),
                    category: .stove,
                    positionX: 1, positionY: 0, positionZ: 1,
                    dimensionsX: 0.6, dimensionsY: 0.9, dimensionsZ: 0.6,
                    source: .autoRoomPlan
                )
            ],
            area: 12.0
        )

        let floor = Floor(name: "Ground", rooms: [room])
        let layout = FloorPlanExtractor.extractLayout(from: floor)

        #expect(layout.rooms[0].isBathroom == false)
    }

    @Test("Convex hull computation produces valid hull")
    func testConvexHull() {
        let points: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 2, y: 1), // interior
            CGPoint(x: 4, y: 0),
            CGPoint(x: 4, y: 4),
            CGPoint(x: 0, y: 4),
            CGPoint(x: 2, y: 3), // interior
        ]

        let hull = FloorPlanExtractor.convexHull(points)

        // Hull should have 4 points (the corners), not the interior points
        #expect(hull.count == 4)
    }

    @Test("Empty floor produces empty layout")
    func testEmptyFloor() {
        let floor = Floor(name: "Empty")
        let layout = FloorPlanExtractor.extractLayout(from: floor)

        #expect(layout.rooms.isEmpty)
        #expect(layout.walls.isEmpty)
        #expect(layout.totalArea == 0)
    }

    @Test("FloorPlanLayout bounds encompass all geometry")
    func testLayoutBounds() {
        let room = Room(
            name: "Living",
            objects: [
                TaggedObject(
                    id: UUID(),
                    category: .sofa,
                    positionX: 2, positionY: 0, positionZ: 3,
                    dimensionsX: 2, dimensionsY: 0.8, dimensionsZ: 1,
                    source: .manualTap
                )
            ],
            area: 20.0
        )

        let floor = Floor(name: "Ground", rooms: [room])
        let layout = FloorPlanExtractor.extractLayout(from: floor)

        #expect(layout.bounds.width > 0)
        #expect(layout.bounds.height > 0)
    }
}
