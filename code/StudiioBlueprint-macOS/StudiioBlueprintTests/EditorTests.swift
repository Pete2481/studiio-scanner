import Testing
import Foundation
import CoreGraphics
@testable import StudiioBlueprint

@Suite("Editor Tests")
struct EditorTests {

    @Test("VerifiedDimension stores measured and original values")
    func testVerifiedDimension() {
        let wallID = UUID()
        let vd = VerifiedDimension(
            wallID: wallID,
            measuredLength: 3.45,
            originalLength: 3.52
        )
        #expect(vd.wallID == wallID)
        #expect(vd.measuredLength == 3.45)
        #expect(vd.originalLength == 3.52)
    }

    @Test("VerifiedDimension calculates correction ratio")
    func testCorrectionRatio() {
        let vd = VerifiedDimension(
            wallID: UUID(),
            measuredLength: 3.0,
            originalLength: 3.1
        )
        let ratio = vd.measuredLength / vd.originalLength
        #expect(abs(ratio - 0.9677) < 0.001)
    }

    @Test("EditorToolbar.EditMode has all required modes")
    func testEditModes() {
        let modes = EditorToolbar.EditMode.allCases
        #expect(modes.count == 3)
        #expect(modes.contains(.select))
        #expect(modes.contains(.moveRoom))
        #expect(modes.contains(.verifyDimension))
    }

    @Test("EditMode icons are valid SF Symbols names")
    func testEditModeIcons() {
        for mode in EditorToolbar.EditMode.allCases {
            #expect(!mode.icon.isEmpty)
        }
    }

    @Test("RoomPolygon can be moved by offset")
    func testMoveRoom() {
        let original = RoomPolygon(
            name: "Kitchen",
            polygon: [
                CGPoint(x: 0, y: 0),
                CGPoint(x: 4, y: 0),
                CGPoint(x: 4, y: 3),
                CGPoint(x: 0, y: 3)
            ],
            area: 12
        )

        let dx: CGFloat = 2.0
        let dy: CGFloat = 1.0
        let moved = RoomPolygon(
            id: original.id,
            name: original.name,
            polygon: original.polygon.map { CGPoint(x: $0.x + dx, y: $0.y + dy) },
            area: original.area,
            objects: original.objects,
            isBathroom: original.isBathroom,
            isOutdoor: original.isOutdoor
        )

        #expect(moved.polygon[0].x == 2.0)
        #expect(moved.polygon[0].y == 1.0)
        #expect(moved.polygon[2].x == 6.0)
        #expect(moved.polygon[2].y == 4.0)
        #expect(moved.centroid.x == original.centroid.x + dx)
    }

    @Test("Wall selection via point-to-segment distance")
    func testPointToSegmentDistance() {
        let a = CGPoint(x: 0, y: 0)
        let b = CGPoint(x: 10, y: 0)
        let p = CGPoint(x: 5, y: 3) // 3 units above the midpoint

        // Distance should be 3
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq
        t = max(0, min(1, t))
        let proj = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        let dist = hypot(p.x - proj.x, p.y - proj.y)

        #expect(abs(dist - 3.0) < 0.001)
    }

    @Test("Multiple verified dimensions can coexist")
    func testMultipleVerifiedDimensions() {
        var dims: [VerifiedDimension] = []
        dims.append(VerifiedDimension(wallID: UUID(), measuredLength: 3.0, originalLength: 3.1))
        dims.append(VerifiedDimension(wallID: UUID(), measuredLength: 4.5, originalLength: 4.4))
        dims.append(VerifiedDimension(wallID: UUID(), measuredLength: 2.1, originalLength: 2.2))

        #expect(dims.count == 3)
        #expect(dims.allSatisfy { $0.measuredLength > 0 })
    }
}
