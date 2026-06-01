import Testing
import Foundation
@testable import StudiioScanner

@Suite("OutdoorDetector Signal Logic Tests")
struct OutdoorDetectorTests {

    @Test("Signal state counts outdoor votes correctly")
    func testOutdoorVoteCount() {
        var signals = OutdoorDetector.SignalState()
        #expect(signals.outdoorVoteCount == 0)

        signals.lightLevel = .outdoor
        #expect(signals.outdoorVoteCount == 1)

        signals.meshDensity = .outdoor
        #expect(signals.outdoorVoteCount == 2)

        signals.skyDetected = .outdoor
        #expect(signals.outdoorVoteCount == 3)

        signals.doorTransit = .outdoor
        #expect(signals.outdoorVoteCount == 4)
    }

    @Test("Signal state counts indoor votes correctly")
    func testIndoorVoteCount() {
        var signals = OutdoorDetector.SignalState()
        signals.lightLevel = .indoor
        signals.meshDensity = .indoor
        signals.skyDetected = .indoor
        signals.doorTransit = .undetermined

        #expect(signals.indoorVoteCount == 3)
        #expect(signals.outdoorVoteCount == 0)
    }

    @Test("Mixed signals don't trigger premature mode change")
    func testMixedSignals() {
        var signals = OutdoorDetector.SignalState()
        signals.lightLevel = .outdoor
        signals.meshDensity = .indoor
        signals.skyDetected = .outdoor
        signals.doorTransit = .undetermined

        // Only 2 outdoor votes, need 3
        #expect(signals.outdoorVoteCount == 2)
        #expect(signals.indoorVoteCount == 1)
    }

    @Test("OutdoorDetector initializes in indoor mode")
    @MainActor
    func testInitialMode() {
        let detector = OutdoorDetector()
        #expect(detector.currentMode == .indoor)
        #expect(detector.modeTransitionBanner == nil)
    }

    @Test("Override mode sets mode directly")
    @MainActor
    func testOverrideMode() {
        let detector = OutdoorDetector()
        detector.overrideMode(.outdoor)
        #expect(detector.currentMode == .outdoor)
    }

    @Test("OutdoorType display names are correct for AU real estate")
    func testDisplayNames() {
        #expect(OutdoorType.deck.displayName == "Deck")
        #expect(OutdoorType.balcony.displayName == "Balcony")
        #expect(OutdoorType.alfresco.displayName == "Alfresco")
        #expect(OutdoorType.verandah.displayName == "Verandah")
        #expect(OutdoorType.porch.displayName == "Porch")
        #expect(OutdoorType.carport.displayName == "Carport")
    }

    @Test("OutdoorZone serialization round-trip")
    func testOutdoorZoneSerialization() throws {
        let zone = OutdoorZone(
            name: "Back Deck",
            type: .deck,
            boundaryPolygonX: [0, 5, 5, 0],
            boundaryPolygonY: [0, 0, 3, 3],
            connectedFloorID: UUID(),
            elevation: 0.3
        )

        let data = try JSONEncoder().encode(zone)
        let decoded = try JSONDecoder().decode(OutdoorZone.self, from: data)

        #expect(decoded.name == "Back Deck")
        #expect(decoded.type == .deck)
        #expect(decoded.elevation == 0.3)
        #expect(decoded.boundaryPolygonX.count == 4)
    }
}
