import Foundation
import Combine

/// Watches the iCloud Drive "Pending" folder for new .studiio bundles
/// and auto-imports them into the Mac app.
@MainActor
final class iCloudWatcher: ObservableObject {

    @Published var pendingBundles: [URL] = []

    private let fileManager = FileManager.default
    private var metadataQuery: NSMetadataQuery?
    private var timer: Timer?

    /// iCloud container Pending folder URL
    var iCloudPendingURL: URL? {
        guard let containerURL = fileManager.url(
            forUbiquityContainerIdentifier: "iCloud.com.studiio.scanner"
        ) else {
            return nil
        }
        return containerURL
            .appendingPathComponent("Documents")
            .appendingPathComponent("Pending")
    }

    var iCloudAvailable: Bool {
        fileManager.ubiquityIdentityToken != nil
    }

    // MARK: - Start Watching

    func startWatching() {
        guard iCloudAvailable else { return }

        // Poll every 5 seconds for new files in Pending
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scanPendingFolder()
            }
        }

        // Initial scan
        scanPendingFolder()
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Scan

    private func scanPendingFolder() {
        guard let pendingURL = iCloudPendingURL else {
            pendingBundles = []
            return
        }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: pendingURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            pendingBundles = []
            return
        }

        pendingBundles = contents.filter { $0.pathExtension == "studiio" }
    }

    /// Import a pending bundle and remove it from the Pending folder
    func importAndClear(url: URL, using importer: ProjectImporter) throws -> PropertyProject {
        let project = try importer.importProject(from: url)

        // Remove from Pending folder after successful import
        try? fileManager.removeItem(at: url)

        // Refresh
        scanPendingFolder()
        return project
    }
}
