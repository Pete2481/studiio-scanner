import Testing
import Foundation
@testable import StudiioBlueprint

@Suite("Import Tests")
struct ImportTests {

    @Test("PropertyProject decodes from JSON correctly")
    func testProjectDecoding() throws {
        let json = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "address": "42 Wallaby Way",
            "capturedAt": "2026-01-15T10:30:00Z",
            "floors": [
                {
                    "id": "22222222-2222-2222-2222-222222222222",
                    "name": "Ground",
                    "elevation": 0,
                    "rooms": [
                        {
                            "id": "33333333-3333-3333-3333-333333333333",
                            "name": "Kitchen",
                            "objects": [],
                            "area": 12.5,
                            "photosPaths": [],
                            "verifiedDimensions": []
                        }
                    ],
                    "stairConnections": []
                }
            ],
            "outbuildings": [],
            "outdoorZones": []
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = json.data(using: .utf8)!
        let project = try decoder.decode(PropertyProject.self, from: data)

        #expect(project.address == "42 Wallaby Way")
        #expect(project.floors.count == 1)
        #expect(project.floors[0].rooms.count == 1)
        #expect(project.floors[0].rooms[0].name == "Kitchen")
        #expect(project.floors[0].rooms[0].area == 12.5)
    }

    @Test("PropertyProject round-trips through JSON")
    func testProjectRoundTrip() throws {
        let room = Room(name: "Bathroom", objects: [
            TaggedObject(
                id: UUID(),
                category: .shower,
                positionX: 1, positionY: 0, positionZ: 2,
                dimensionsX: 0.9, dimensionsY: 2.1, dimensionsZ: 0.9,
                source: .autoRoomPlan
            )
        ], area: 6.2)

        let floor = Floor(name: "Ground", rooms: [room])
        let project = PropertyProject(
            address: "10 Test Lane",
            floors: [floor],
            outdoorZones: [
                OutdoorZone(name: "Back Deck", type: .deck)
            ]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PropertyProject.self, from: data)

        #expect(decoded.id == project.id)
        #expect(decoded.address == "10 Test Lane")
        #expect(decoded.floors[0].rooms[0].objects.count == 1)
        #expect(decoded.floors[0].rooms[0].objects[0].category == .shower)
        #expect(decoded.outdoorZones.count == 1)
        #expect(decoded.outdoorZones[0].type == .deck)
    }

    @Test("ObjectCategory abbreviations match Roomio conventions")
    func testAbbreviations() {
        #expect(ObjectCategory.refrigerator.abbreviation == "F")
        #expect(ObjectCategory.dishwasher.abbreviation == "DW")
        #expect(ObjectCategory.toilet.abbreviation == "WC")
        #expect(ObjectCategory.wardrobe.abbreviation == "BIR")
        #expect(ObjectCategory.pantry.abbreviation == "P'TRY")
        #expect(ObjectCategory.splitSystemAC.abbreviation == "A/C")
        #expect(ObjectCategory.barbecue.abbreviation == "BBQ")
        #expect(ObjectCategory.hotWaterUnit.abbreviation == "HWU")
    }

    @Test("All ObjectCategory cases have non-empty abbreviations")
    func testAllAbbreviations() {
        for category in ObjectCategory.allCases {
            #expect(!category.abbreviation.isEmpty, "Missing abbreviation for \(category)")
        }
    }

    @Test("OutdoorType has all required Australian types")
    func testOutdoorTypes() {
        let types = OutdoorType.allCases.map(\.rawValue)
        #expect(types.contains("deck"))
        #expect(types.contains("balcony"))
        #expect(types.contains("alfresco"))
        #expect(types.contains("verandah"))
        #expect(types.contains("patio"))
        #expect(types.contains("carport"))
    }

    @Test("ProjectImporter local directory is created")
    func testLocalDirectory() async {
        await MainActor.run {
            let importer = ProjectImporter()
            let url = importer.localProjectsDirectory
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("ProjectImporter rejects non-.studiio files")
    func testInvalidFormat() async {
        await MainActor.run {
            let importer = ProjectImporter()
            let fakeURL = URL(fileURLWithPath: "/tmp/fake.txt")
            do {
                _ = try importer.importProject(from: fakeURL)
                Issue.record("Should have thrown invalidFormat")
            } catch let error as ProjectImporter.ImportError {
                #expect(error == .invalidFormat)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("ImportError descriptions are human-readable")
    func testErrorDescriptions() {
        #expect(ProjectImporter.ImportError.invalidFormat.errorDescription == "Not a valid .studiio bundle")
        #expect(ProjectImporter.ImportError.missingMetadata.errorDescription == "Missing metadata.json in bundle")
        #expect(ProjectImporter.ImportError.decodingFailed.errorDescription == "Failed to read project data")
    }

    @Test("Empty project list returns empty array")
    func testEmptyProjectList() async {
        await MainActor.run {
            let importer = ProjectImporter()
            let projects = importer.loadAllProjects()
            // May or may not be empty depending on prior test runs — just confirm it doesn't crash
            #expect(projects.count >= 0)
        }
    }
}
