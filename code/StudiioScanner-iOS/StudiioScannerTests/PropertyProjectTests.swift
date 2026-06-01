import Testing
import Foundation
@testable import StudiioScanner

@Suite("PropertyProject Data Model Tests")
struct PropertyProjectTests {

    @Test("PropertyProject encodes and decodes correctly")
    func testRoundTripSerialization() throws {
        let project = PropertyProject(
            address: "23 Smith St, Lismore NSW 2480",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            floors: [
                Floor(
                    name: "Ground",
                    elevation: 0,
                    rooms: [
                        Room(
                            name: "Kitchen",
                            objects: [
                                TaggedObject(
                                    id: UUID(),
                                    category: .stove,
                                    positionX: 1.0, positionY: 0.5, positionZ: 2.0,
                                    dimensionsX: 0.6, dimensionsY: 0.9, dimensionsZ: 0.6,
                                    source: .autoRoomPlan
                                )
                            ],
                            area: 12.5
                        ),
                        Room(name: "Living Room", area: 24.3)
                    ]
                ),
                Floor(
                    name: "Upper Floor",
                    elevation: 2.8,
                    rooms: [
                        Room(name: "Bedroom 1", area: 14.2),
                        Room(name: "Bathroom", area: 6.1)
                    ]
                )
            ],
            outbuildings: [
                Outbuilding(name: "Garage", rooms: [
                    Room(name: "Garage", area: 38.0)
                ])
            ],
            outdoorZones: [
                OutdoorZone(
                    name: "Deck",
                    type: .deck,
                    boundaryPolygonX: [0, 5, 5, 0],
                    boundaryPolygonY: [0, 0, 3, 3],
                    elevation: 0.3
                )
            ]
        )

        // Encode
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(project)

        // Decode
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PropertyProject.self, from: data)

        // Validate
        #expect(decoded.id == project.id)
        #expect(decoded.address == "23 Smith St, Lismore NSW 2480")
        #expect(decoded.floors.count == 2)
        #expect(decoded.floors[0].name == "Ground")
        #expect(decoded.floors[0].rooms.count == 2)
        #expect(decoded.floors[0].rooms[0].name == "Kitchen")
        #expect(decoded.floors[0].rooms[0].area == 12.5)
        #expect(decoded.floors[0].rooms[0].objects.count == 1)
        #expect(decoded.floors[0].rooms[0].objects[0].category == .stove)
        #expect(decoded.floors[0].rooms[0].objects[0].source == .autoRoomPlan)
        #expect(decoded.floors[1].name == "Upper Floor")
        #expect(decoded.floors[1].elevation == 2.8)
        #expect(decoded.outbuildings.count == 1)
        #expect(decoded.outbuildings[0].name == "Garage")
        #expect(decoded.outdoorZones.count == 1)
        #expect(decoded.outdoorZones[0].type == .deck)
        #expect(decoded.outdoorZones[0].boundaryPolygonX == [0, 5, 5, 0])
    }

    @Test("VerifiedDimension stores original and measured values")
    func testVerifiedDimension() {
        let vd = VerifiedDimension(
            wallID: UUID(),
            measuredLength: 4.20,
            originalLength: 4.15
        )
        #expect(vd.measuredLength == 4.20)
        #expect(vd.originalLength == 4.15)
        #expect(abs(vd.measuredLength - vd.originalLength - 0.05) < 0.001)
    }

    @Test("ObjectCategory abbreviations match Roomio conventions")
    func testAbbreviations() {
        #expect(ObjectCategory.refrigerator.abbreviation == "F")
        #expect(ObjectCategory.dishwasher.abbreviation == "DW")
        #expect(ObjectCategory.washerDryer.abbreviation == "W/D")
        #expect(ObjectCategory.toilet.abbreviation == "WC")
        #expect(ObjectCategory.wardrobe.abbreviation == "BIR")
        #expect(ObjectCategory.pantry.abbreviation == "P'TRY")
        #expect(ObjectCategory.splitSystemAC.abbreviation == "A/C")
        #expect(ObjectCategory.barbecue.abbreviation == "BBQ")
        #expect(ObjectCategory.fireplace.abbreviation == "FP")
        #expect(ObjectCategory.stove.abbreviation == "OV")
        #expect(ObjectCategory.oven.abbreviation == "OV")
        #expect(ObjectCategory.linenCupboard.abbreviation == "LINEN")
        #expect(ObjectCategory.hotWaterUnit.abbreviation == "HWU")
    }

    @Test("Empty project initializes with sensible defaults")
    func testDefaults() {
        let project = PropertyProject()
        #expect(project.address == nil)
        #expect(project.floors.isEmpty)
        #expect(project.outbuildings.isEmpty)
        #expect(project.outdoorZones.isEmpty)
    }

    @Test("TaggedObject SIMD3 position accessor works")
    func testSIMDAccessor() {
        var obj = TaggedObject(
            id: UUID(),
            category: .shower,
            positionX: 1.5, positionY: 2.0, positionZ: 3.5,
            dimensionsX: 0.9, dimensionsY: 2.1, dimensionsZ: 0.9,
            source: .manualTap
        )

        #expect(obj.position.x == 1.5)
        #expect(obj.position.y == 2.0)
        #expect(obj.position.z == 3.5)

        obj.position = SIMD3<Float>(4.0, 5.0, 6.0)
        #expect(obj.positionX == 4.0)
        #expect(obj.positionY == 5.0)
        #expect(obj.positionZ == 6.0)
    }

    @Test("OutdoorType covers all required Australian types")
    func testOutdoorTypes() {
        let allTypes = OutdoorType.allCases
        #expect(allTypes.contains(.deck))
        #expect(allTypes.contains(.balcony))
        #expect(allTypes.contains(.alfresco))
        #expect(allTypes.contains(.verandah))
        #expect(allTypes.contains(.porch))
        #expect(allTypes.contains(.patio))
        #expect(allTypes.contains(.garden))
        #expect(allTypes.contains(.driveway))
        #expect(allTypes.contains(.carport))
        #expect(allTypes.contains(.other))
        #expect(allTypes.count == 10)
    }

    @Test("StairLink direction enum round-trips through JSON")
    func testStairLinkSerialization() throws {
        let link = StairLink(
            id: UUID(),
            fromFloorID: UUID(),
            toFloorID: UUID(),
            direction: .up
        )

        let data = try JSONEncoder().encode(link)
        let decoded = try JSONDecoder().decode(StairLink.self, from: data)
        #expect(decoded.direction == .up)
    }

    @Test("Floor total area calculation sums rooms correctly")
    func testFloorAreaCalculation() {
        let floor = Floor(
            name: "Ground",
            rooms: [
                Room(name: "Kitchen", area: 12.5),
                Room(name: "Living", area: 24.3),
                Room(name: "Hall", area: 4.2)
            ]
        )
        let totalArea = floor.rooms.reduce(0) { $0 + $1.area }
        #expect(abs(totalArea - 41.0) < 0.001)
    }
}
