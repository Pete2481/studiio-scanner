import Testing
import Foundation
import CoreGraphics
@testable import StudiioBlueprint

@Suite("PDF Export Tests")
struct PDFExportTests {

    @Test("A3 page dimensions are correct")
    func testPageDimensions() {
        // A3 at 72 DPI: 420mm x 297mm = 1190.55 x 841.89 points
        #expect(abs(PDFExporter.a3Width - 1190.55) < 0.01)
        #expect(abs(PDFExporter.a3Height - 841.89) < 0.01)
    }

    @Test("Disclaimer text contains required Australian language")
    func testDisclaimer() {
        let disclaimer = PDFExporter.disclaimer
        #expect(disclaimer.contains("approximate"))
        #expect(disclaimer.contains("not guaranteed"))
        #expect(disclaimer.contains("Buyers should make their own enquiries"))
        #expect(disclaimer.contains("Studiio"))
    }

    @Test("Margins are reasonable for A3")
    func testMargins() {
        #expect(PDFExporter.marginTop >= 30)
        #expect(PDFExporter.marginBottom >= 60)
        #expect(PDFExporter.marginLeft >= 30)
        #expect(PDFExporter.marginRight >= 30)
    }

    @Test("Export single floor produces non-empty PDF data")
    func testExportSingleFloor() async {
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

        let pdfData = await MainActor.run {
            PDFExporter.exportFloor(
                layout: layout,
                address: "42 Wallaby Way",
                projectDate: Date()
            )
        }

        #expect(!pdfData.isEmpty)
        let prefix = String(data: pdfData.prefix(5), encoding: .ascii)
        #expect(prefix?.hasPrefix("%PDF") == true)
    }

    @Test("Export multi-floor project produces valid PDF")
    func testExportMultiFloor() async {
        let kitchen = Room(
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
        let bathroom = Room(
            name: "Bathroom",
            objects: [
                TaggedObject(
                    id: UUID(),
                    category: .toilet,
                    positionX: 0.5, positionY: 0, positionZ: 0.5,
                    dimensionsX: 0.4, dimensionsY: 0.5, dimensionsZ: 0.6,
                    source: .autoRoomPlan
                )
            ],
            area: 5.0
        )

        let ground = Floor(name: "Ground Floor", rooms: [kitchen, bathroom])
        let bedroom = Room(name: "Master Bedroom", area: 16.0)
        let first = Floor(name: "First Floor", elevation: 2.7, rooms: [bedroom])

        let project = PropertyProject(
            address: "10 Test Lane, Sydney NSW 2000",
            floors: [ground, first]
        )

        let pdfData = await MainActor.run {
            PDFExporter.exportProject(project: project)
        }
        #expect(!pdfData.isEmpty)

        let prefix = String(data: pdfData.prefix(5), encoding: .ascii)
        #expect(prefix?.hasPrefix("%PDF") == true)
    }

    @Test("Export empty project produces valid PDF")
    func testExportEmptyProject() async {
        let project = PropertyProject(
            address: "Empty Property",
            floors: [Floor(name: "Ground")]
        )

        let pdfData = await MainActor.run {
            PDFExporter.exportProject(project: project)
        }
        #expect(!pdfData.isEmpty)
    }

    @Test("PDF can be saved to disk and read back")
    func testSaveAndRead() async throws {
        let layout = FloorPlanLayout(
            rooms: [
                RoomPolygon(
                    name: "Test",
                    polygon: [
                        CGPoint(x: 0, y: 0),
                        CGPoint(x: 4, y: 0),
                        CGPoint(x: 4, y: 3),
                        CGPoint(x: 0, y: 3)
                    ],
                    area: 12
                )
            ],
            walls: [
                BlueprintWall(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 4, y: 0)),
                BlueprintWall(start: CGPoint(x: 4, y: 0), end: CGPoint(x: 4, y: 3)),
                BlueprintWall(start: CGPoint(x: 4, y: 3), end: CGPoint(x: 0, y: 3)),
                BlueprintWall(start: CGPoint(x: 0, y: 3), end: CGPoint(x: 0, y: 0)),
            ],
            floorName: "Ground",
            totalArea: 12
        )

        let data = await MainActor.run {
            PDFExporter.exportFloor(layout: layout, address: "Test", projectDate: Date())
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")

        try PDFExporter.savePDF(data: data, to: tempURL)

        let readBack = try Data(contentsOf: tempURL)
        #expect(readBack.count == data.count)

        try FileManager.default.removeItem(at: tempURL)
    }
}
