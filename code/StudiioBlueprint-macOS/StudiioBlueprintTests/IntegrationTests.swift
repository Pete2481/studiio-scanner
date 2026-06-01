import Testing
import Foundation
import CoreGraphics
@testable import StudiioBlueprint

@Suite("Integration Tests")
struct IntegrationTests {

    // MARK: - Full Pipeline Tests

    @Test("Complete property project flows through import -> render -> export")
    func testFullPipeline() async {
        // 1. Create a realistic multi-room, multi-floor project
        let project = createRealisticProject()

        // 2. Encode to JSON (simulating iOS export)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try! encoder.encode(project)

        // 3. Decode from JSON (simulating Mac import)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let imported = try! decoder.decode(PropertyProject.self, from: data)

        // 4. Verify data integrity
        #expect(imported.id == project.id)
        #expect(imported.address == project.address)
        #expect(imported.floors.count == project.floors.count)

        let importedRooms = imported.floors.flatMap(\.rooms)
        let originalRooms = project.floors.flatMap(\.rooms)
        #expect(importedRooms.count == originalRooms.count)

        // 5. Extract layout for each floor
        for floor in imported.floors {
            let layout = FloorPlanExtractor.extractLayout(from: floor)
            #expect(layout.rooms.count == floor.rooms.count)
            #expect(layout.floorName == floor.name)
        }

        // 6. Generate PDF
        let pdfData = await MainActor.run {
            PDFExporter.exportProject(project: imported)
        }
        #expect(!pdfData.isEmpty)

        let prefix = String(data: pdfData.prefix(5), encoding: .ascii)
        #expect(prefix?.hasPrefix("%PDF") == true)
    }

    @Test("All object categories survive JSON round-trip")
    func testAllCategoriesRoundTrip() throws {
        var objects: [TaggedObject] = []
        for (index, category) in ObjectCategory.allCases.enumerated() {
            objects.append(TaggedObject(
                id: UUID(),
                category: category,
                positionX: Float(index),
                positionY: 0,
                positionZ: Float(index),
                dimensionsX: 0.5,
                dimensionsY: 0.5,
                dimensionsZ: 0.5,
                source: index % 2 == 0 ? .autoRoomPlan : .manualTap
            ))
        }

        let room = Room(name: "All Objects", objects: objects, area: 50)
        let floor = Floor(name: "Ground", rooms: [room])
        let project = PropertyProject(address: "Category Test", floors: [floor])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PropertyProject.self, from: data)

        let decodedObjects = decoded.floors[0].rooms[0].objects
        #expect(decodedObjects.count == ObjectCategory.allCases.count)

        for (original, decoded) in zip(objects, decodedObjects) {
            #expect(original.category == decoded.category)
            #expect(original.source == decoded.source)
        }
    }

    @Test("All outdoor types survive JSON round-trip")
    func testAllOutdoorTypesRoundTrip() throws {
        var zones: [OutdoorZone] = []
        for type in OutdoorType.allCases {
            zones.append(OutdoorZone(name: type.rawValue, type: type))
        }

        let project = PropertyProject(
            address: "Outdoor Test",
            floors: [Floor(name: "Ground")],
            outdoorZones: zones
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PropertyProject.self, from: data)

        #expect(decoded.outdoorZones.count == OutdoorType.allCases.count)
        for (original, decoded) in zip(zones, decoded.outdoorZones) {
            #expect(original.type == decoded.type)
        }
    }

    @Test("Verified dimensions persist through JSON round-trip")
    func testVerifiedDimensionsRoundTrip() throws {
        let wallID = UUID()
        let vd = VerifiedDimension(
            wallID: wallID,
            measuredLength: 3.45,
            originalLength: 3.52
        )
        let room = Room(name: "Test", verifiedDimensions: [vd])
        let project = PropertyProject(
            address: "Dimension Test",
            floors: [Floor(name: "Ground", rooms: [room])]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PropertyProject.self, from: data)

        let decodedVD = decoded.floors[0].rooms[0].verifiedDimensions[0]
        #expect(decodedVD.wallID == wallID)
        #expect(decodedVD.measuredLength == 3.45)
        #expect(decodedVD.originalLength == 3.52)
    }

    @Test("Multi-floor building renders distinct layouts per floor")
    func testMultiFloorRendering() {
        let ground = Floor(name: "Ground Floor", rooms: [
            Room(name: "Living", objects: [
                TaggedObject(id: UUID(), category: .sofa, positionX: 2, positionY: 0, positionZ: 3,
                           dimensionsX: 2, dimensionsY: 0.8, dimensionsZ: 1, source: .autoRoomPlan)
            ], area: 25),
            Room(name: "Kitchen", objects: [
                TaggedObject(id: UUID(), category: .stove, positionX: 5, positionY: 0, positionZ: 1,
                           dimensionsX: 0.6, dimensionsY: 0.9, dimensionsZ: 0.6, source: .autoRoomPlan)
            ], area: 15)
        ])

        let first = Floor(name: "First Floor", elevation: 2.7, rooms: [
            Room(name: "Master Bedroom", objects: [
                TaggedObject(id: UUID(), category: .bed, positionX: 2, positionY: 2.7, positionZ: 2,
                           dimensionsX: 1.5, dimensionsY: 0.5, dimensionsZ: 2, source: .autoRoomPlan)
            ], area: 20)
        ])

        let groundLayout = FloorPlanExtractor.extractLayout(from: ground)
        let firstLayout = FloorPlanExtractor.extractLayout(from: first)

        #expect(groundLayout.rooms.count == 2)
        #expect(firstLayout.rooms.count == 1)
        #expect(groundLayout.floorName != firstLayout.floorName)
        #expect(groundLayout.totalArea > firstLayout.totalArea)
    }

    @Test("Bathroom detection works across mixed room types")
    func testMixedRoomBathroomDetection() {
        let rooms = [
            Room(name: "Ensuite", area: 5),
            Room(name: "Kitchen", objects: [
                TaggedObject(id: UUID(), category: .stove, positionX: 1, positionY: 0, positionZ: 1,
                           dimensionsX: 0.6, dimensionsY: 0.9, dimensionsZ: 0.6, source: .autoRoomPlan)
            ], area: 12),
            Room(name: "Room 3", objects: [
                TaggedObject(id: UUID(), category: .shower, positionX: 1, positionY: 0, positionZ: 1,
                           dimensionsX: 0.9, dimensionsY: 2.1, dimensionsZ: 0.9, source: .autoRoomPlan)
            ], area: 4),
            Room(name: "Living", area: 30)
        ]

        let floor = Floor(name: "Ground", rooms: rooms)
        let layout = FloorPlanExtractor.extractLayout(from: floor)

        #expect(layout.rooms[0].isBathroom == true)  // Ensuite by name
        #expect(layout.rooms[1].isBathroom == false)  // Kitchen
        #expect(layout.rooms[2].isBathroom == true)   // Has shower
        #expect(layout.rooms[3].isBathroom == false)  // Living
    }

    @Test("Large property with many rooms doesn't crash")
    func testLargeProperty() async {
        var rooms: [Room] = []
        for i in 0..<20 {
            rooms.append(Room(
                name: "Room \(i + 1)",
                objects: [
                    TaggedObject(
                        id: UUID(),
                        category: ObjectCategory.allCases[i % ObjectCategory.allCases.count],
                        positionX: Float(i * 3),
                        positionY: 0,
                        positionZ: Float(i % 5 * 3),
                        dimensionsX: 1, dimensionsY: 1, dimensionsZ: 1,
                        source: .autoRoomPlan
                    )
                ],
                area: Double(10 + i * 2)
            ))
        }

        let floor = Floor(name: "Ground", rooms: rooms)
        let layout = FloorPlanExtractor.extractLayout(from: floor)

        #expect(layout.rooms.count == 20)
        #expect(!layout.walls.isEmpty)
        #expect(layout.bounds.width > 0)

        let project = PropertyProject(address: "Large House", floors: [floor])
        let pdfData = await MainActor.run {
            PDFExporter.exportProject(project: project)
        }
        #expect(!pdfData.isEmpty)
    }

    @Test("Bundle format compatibility - iOS metadata.json is Mac-readable")
    func testBundleCompatibility() async throws {
        // Simulate what iOS ProjectStore writes
        let project = createRealisticProject()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(project)

        // Write to temp .studiio bundle
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("studiio")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try jsonData.write(to: tempDir.appendingPathComponent("metadata.json"))

        // Import using Mac's ProjectImporter
        let importer = await MainActor.run { ProjectImporter() }
        let imported = await MainActor.run {
            try! importer.loadProject(from: tempDir)
        }

        #expect(imported.id == project.id)
        #expect(imported.address == project.address)
        #expect(imported.floors.count == project.floors.count)

        try FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helper

    private func createRealisticProject() -> PropertyProject {
        let kitchen = Room(
            name: "Kitchen",
            objects: [
                TaggedObject(id: UUID(), category: .stove, positionX: 1, positionY: 0, positionZ: 0.5,
                           dimensionsX: 0.6, dimensionsY: 0.9, dimensionsZ: 0.6, source: .autoRoomPlan),
                TaggedObject(id: UUID(), category: .refrigerator, positionX: 3, positionY: 0, positionZ: 0.5,
                           dimensionsX: 0.7, dimensionsY: 1.8, dimensionsZ: 0.7, source: .autoRoomPlan),
                TaggedObject(id: UUID(), category: .dishwasher, positionX: 2, positionY: 0, positionZ: 0.5,
                           dimensionsX: 0.6, dimensionsY: 0.85, dimensionsZ: 0.6, source: .autoRoomPlan),
            ],
            area: 15.0
        )

        let bathroom = Room(
            name: "Bathroom",
            objects: [
                TaggedObject(id: UUID(), category: .toilet, positionX: 0.5, positionY: 0, positionZ: 1.5,
                           dimensionsX: 0.4, dimensionsY: 0.5, dimensionsZ: 0.65, source: .autoRoomPlan),
                TaggedObject(id: UUID(), category: .shower, positionX: 1.5, positionY: 0, positionZ: 0.5,
                           dimensionsX: 0.9, dimensionsY: 2.1, dimensionsZ: 0.9, source: .autoRoomPlan),
                TaggedObject(id: UUID(), category: .vanity, positionX: 0.5, positionY: 0, positionZ: 0.5,
                           dimensionsX: 0.9, dimensionsY: 0.85, dimensionsZ: 0.5, source: .manualTap),
            ],
            area: 6.0,
            verifiedDimensions: [
                VerifiedDimension(wallID: UUID(), measuredLength: 2.4, originalLength: 2.38)
            ]
        )

        let living = Room(name: "Living", objects: [
            TaggedObject(id: UUID(), category: .sofa, positionX: 5, positionY: 0, positionZ: 3,
                       dimensionsX: 2.2, dimensionsY: 0.85, dimensionsZ: 0.95, source: .autoRoomPlan),
            TaggedObject(id: UUID(), category: .television, positionX: 5, positionY: 1.2, positionZ: 0.5,
                       dimensionsX: 1.2, dimensionsY: 0.7, dimensionsZ: 0.1, source: .autoRoomPlan),
        ], area: 28.0)

        let ground = Floor(name: "Ground Floor", rooms: [kitchen, bathroom, living])

        let masterBed = Room(name: "Master Bedroom", objects: [
            TaggedObject(id: UUID(), category: .bed, positionX: 2, positionY: 2.7, positionZ: 2,
                       dimensionsX: 1.5, dimensionsY: 0.5, dimensionsZ: 2.0, source: .autoRoomPlan),
            TaggedObject(id: UUID(), category: .wardrobe, positionX: 0.5, positionY: 2.7, positionZ: 2,
                       dimensionsX: 2.4, dimensionsY: 2.4, dimensionsZ: 0.6, source: .manualTap),
        ], area: 16.0)

        let firstFloor = Floor(name: "First Floor", elevation: 2.7, rooms: [masterBed])

        return PropertyProject(
            address: "42 Wallaby Way, Sydney NSW 2000",
            floors: [ground, firstFloor],
            outdoorZones: [
                OutdoorZone(name: "Back Deck", type: .deck, elevation: 0),
                OutdoorZone(name: "Front Porch", type: .porch, elevation: 0)
            ]
        )
    }
}
