import Testing
import Foundation
@testable import StudiioScanner

@Suite("ProjectStore Tests")
struct ProjectStoreTests {

    @Test("Project saves and loads from disk")
    @MainActor
    func testSaveAndLoad() throws {
        let store = ProjectStore()

        let project = PropertyProject(
            address: "42 Test St, Byron Bay NSW 2481",
            floors: [
                Floor(
                    name: "Ground",
                    rooms: [
                        Room(name: "Kitchen", area: 15.0),
                        Room(name: "Living Room", area: 28.0)
                    ]
                )
            ]
        )

        try store.saveProject(project)
        store.loadProjects()

        #expect(store.projects.count >= 1)

        let loaded = store.projects.first { $0.id == project.id }
        #expect(loaded != nil)
        #expect(loaded?.address == "42 Test St, Byron Bay NSW 2481")
        #expect(loaded?.floors.count == 1)
        #expect(loaded?.floors[0].rooms.count == 2)

        // Cleanup
        try store.deleteProject(project)
        store.loadProjects()
        let afterDelete = store.projects.first { $0.id == project.id }
        #expect(afterDelete == nil)
    }

    @Test("Project with verified dimensions round-trips")
    @MainActor
    func testVerifiedDimensionsRoundTrip() throws {
        let store = ProjectStore()
        let wallID = UUID()

        let project = PropertyProject(
            address: "Test Verified Dims",
            floors: [
                Floor(
                    name: "Ground",
                    rooms: [
                        Room(
                            name: "Kitchen",
                            area: 15.0,
                            verifiedDimensions: [
                                VerifiedDimension(
                                    wallID: wallID,
                                    measuredLength: 4.20,
                                    originalLength: 4.15
                                )
                            ]
                        )
                    ]
                )
            ]
        )

        try store.saveProject(project)
        store.loadProjects()

        let loaded = store.projects.first { $0.id == project.id }
        #expect(loaded != nil)

        let vd = loaded?.floors[0].rooms[0].verifiedDimensions[0]
        #expect(vd?.measuredLength == 4.20)
        #expect(vd?.originalLength == 4.15)
        #expect(vd?.wallID == wallID)

        // Cleanup
        try store.deleteProject(project)
    }

    @Test("Multiple projects sort by date descending")
    @MainActor
    func testProjectSortOrder() throws {
        let store = ProjectStore()

        let older = PropertyProject(
            address: "Older Project",
            capturedAt: Date(timeIntervalSinceNow: -3600)
        )
        let newer = PropertyProject(
            address: "Newer Project",
            capturedAt: Date()
        )

        try store.saveProject(older)
        try store.saveProject(newer)
        store.loadProjects()

        // Most recent should be first
        let newerIndex = store.projects.firstIndex { $0.id == newer.id }
        let olderIndex = store.projects.firstIndex { $0.id == older.id }

        if let ni = newerIndex, let oi = olderIndex {
            #expect(ni < oi)
        }

        // Cleanup
        try store.deleteProject(older)
        try store.deleteProject(newer)
    }
}
