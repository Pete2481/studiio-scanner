import Testing
import Foundation
@testable import StudiioScanner

@Suite("Sync Tests")
struct SyncTests {

    @Test("SyncMode has all four cases")
    func testSyncModeCount() {
        #expect(SyncManager.SyncMode.allCases.count == 4)
    }

    @Test("SyncMode raw values are user-facing strings")
    func testSyncModeRawValues() {
        #expect(SyncManager.SyncMode.iCloud.rawValue == "iCloud Drive")
        #expect(SyncManager.SyncMode.airDrop.rawValue == "AirDrop")
        #expect(SyncManager.SyncMode.localWiFi.rawValue == "Local WiFi")
        #expect(SyncManager.SyncMode.askEachTime.rawValue == "Ask Each Time")
    }

    @Test("Default preferred mode is iCloud")
    func testDefaultMode() async {
        await MainActor.run {
            let manager = SyncManager()
            #expect(manager.preferredMode == .iCloud)
        }
    }

    @Test("localMacDiscovered starts as false")
    func testInitialMacState() async {
        await MainActor.run {
            let manager = SyncManager()
            #expect(manager.localMacDiscovered == false)
        }
    }

    @Test("AirDrop URL returns the project URL unchanged")
    func testAirDropURL() async {
        await MainActor.run {
            let manager = SyncManager()
            let url = URL(fileURLWithPath: "/tmp/test.studiio")
            #expect(manager.airDropURL(for: url) == url)
        }
    }

    @Test("SyncError descriptions are human-readable")
    func testErrorDescriptions() {
        let errors: [(SyncManager.SyncError, String)] = [
            (.iCloudUnavailable, "iCloud Drive is not available"),
            (.noMacFound, "No Mac found on local network"),
            (.notImplemented, "This sync mode is not yet implemented"),
        ]
        for (error, expected) in errors {
            #expect(error.errorDescription == expected)
        }
    }

    @Test("sendToMac throws noMacFound when no Mac discovered")
    func testSendToMacNoMac() async {
        await MainActor.run {
            let manager = SyncManager()
            #expect(manager.localMacDiscovered == false)
        }
        // sendToMac should throw noMacFound
        do {
            try await MainActor.run {
                let manager = SyncManager()
                let url = URL(fileURLWithPath: "/tmp/test.studiio")
                Task {
                    do {
                        try await manager.sendToMac(projectURL: url)
                        Issue.record("Expected noMacFound error")
                    } catch let error as SyncManager.SyncError {
                        #expect(error == .noMacFound)
                    } catch {
                        Issue.record("Unexpected error: \(error)")
                    }
                }
            }
        }
    }

    @Test("ProjectStore exportURL returns a .studiio path")
    func testExportURLExtension() async {
        await MainActor.run {
            let store = ProjectStore()
            let project = PropertyProject(address: "42 Test St")
            let url = store.exportURL(for: project)
            #expect(url.pathExtension == "studiio")
        }
    }
}
