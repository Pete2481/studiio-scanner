import Foundation
import Network

/// Manages syncing .studiio project bundles to Mac via three modes:
/// - iCloud Drive (automatic)
/// - AirDrop (via system share sheet)
/// - Local WiFi (Bonjour + NWConnection)
@MainActor
final class SyncManager: ObservableObject {

    enum SyncMode: String, CaseIterable {
        case iCloud = "iCloud Drive"
        case airDrop = "AirDrop"
        case localWiFi = "Local WiFi"
        case askEachTime = "Ask Each Time"
    }

    @Published var preferredMode: SyncMode = .iCloud
    @Published var iCloudAvailable: Bool = false
    @Published var localMacDiscovered: Bool = false

    private let fileManager = FileManager.default
    private var browser: NWBrowser?

    // MARK: - iCloud Drive

    /// URL for iCloud Drive sync folder
    var iCloudPendingURL: URL? {
        guard let containerURL = fileManager.url(
            forUbiquityContainerIdentifier: "iCloud.com.studiio.scanner"
        ) else {
            return nil
        }
        let pendingDir = containerURL
            .appendingPathComponent("Documents")
            .appendingPathComponent("Pending")
        try? fileManager.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        return pendingDir
    }

    func checkiCloudAvailability() {
        iCloudAvailable = fileManager.ubiquityIdentityToken != nil
    }

    /// Copy a .studiio bundle to iCloud Drive Pending folder
    func syncToiCloud(projectURL: URL) throws {
        guard let pendingURL = iCloudPendingURL else {
            throw SyncError.iCloudUnavailable
        }

        let destination = pendingURL.appendingPathComponent(projectURL.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: projectURL, to: destination)
    }

    // MARK: - AirDrop

    /// Returns the URL for sharing via UIActivityViewController (AirDrop)
    func airDropURL(for projectURL: URL) -> URL {
        projectURL
    }

    // MARK: - Local WiFi (Bonjour)

    /// Start browsing for Studiio Blueprint Mac app on local network
    func startBrowsingForMac() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let browser = NWBrowser(
            for: .bonjour(type: "_studiio._tcp", domain: nil),
            using: parameters
        )

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    break
                case .failed:
                    self?.localMacDiscovered = false
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.localMacDiscovered = !results.isEmpty
            }
        }

        browser.start(queue: .main)
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        localMacDiscovered = false
    }

    /// Send a .studiio bundle to discovered Mac via NWConnection
    func sendToMac(projectURL: URL) async throws {
        guard localMacDiscovered else {
            throw SyncError.noMacFound
        }
        // Implementation would establish NWConnection to the discovered endpoint
        // and stream the .studiio bundle. Deferred to when Mac app's Bonjour listener is built.
        throw SyncError.notImplemented
    }

    // MARK: - Export Action

    /// Sync a project to Mac using the preferred mode.
    func syncProject(at projectURL: URL) async throws {
        switch preferredMode {
        case .iCloud:
            try syncToiCloud(projectURL: projectURL)
        case .airDrop:
            // AirDrop is handled via share sheet in the UI layer
            break
        case .localWiFi:
            try await sendToMac(projectURL: projectURL)
        case .askEachTime:
            // UI should present picker; this is a no-op
            break
        }
    }

    // MARK: - Errors

    enum SyncError: LocalizedError {
        case iCloudUnavailable
        case noMacFound
        case notImplemented

        var errorDescription: String? {
            switch self {
            case .iCloudUnavailable: return "iCloud Drive is not available"
            case .noMacFound: return "No Mac found on local network"
            case .notImplemented: return "This sync mode is not yet implemented"
            }
        }
    }
}
