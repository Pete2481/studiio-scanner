import Foundation
import UniformTypeIdentifiers

/// Handles importing .studiio bundles from disk, iCloud Drive, or drag-and-drop.
@MainActor
final class ProjectImporter: ObservableObject {

    private let fileManager = FileManager.default

    /// The local directory where imported projects are stored
    var localProjectsDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("StudiioBlueprint", isDirectory: true)
            .appendingPathComponent("Projects", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Import from URL

    /// Import a .studiio bundle from any URL (file picker, drag-drop, iCloud)
    func importProject(from sourceURL: URL) throws -> PropertyProject {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { sourceURL.stopAccessingSecurityScopedResource() }
        }

        guard sourceURL.pathExtension == "studiio" else {
            throw ImportError.invalidFormat
        }

        // Copy to local projects directory
        let destinationURL = localProjectsDirectory
            .appendingPathComponent(sourceURL.lastPathComponent)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)

        // Parse the metadata.json
        let project = try loadProject(from: destinationURL)
        return project
    }

    // MARK: - Load from local storage

    func loadProject(from bundleURL: URL) throws -> PropertyProject {
        let metadataURL = bundleURL.appendingPathComponent("metadata.json")
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            throw ImportError.missingMetadata
        }

        let data = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PropertyProject.self, from: data)
    }

    /// Load all projects from local storage
    func loadAllProjects() -> [PropertyProject] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: localProjectsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents
            .filter { $0.pathExtension == "studiio" }
            .compactMap { try? loadProject(from: $0) }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    // MARK: - Delete

    func deleteProject(_ project: PropertyProject) throws {
        let contents = try fileManager.contentsOfDirectory(
            at: localProjectsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for url in contents where url.pathExtension == "studiio" {
            if let loaded = try? loadProject(from: url), loaded.id == project.id {
                try fileManager.removeItem(at: url)
                return
            }
        }
    }

    /// Returns the bundle URL for a given project
    func bundleURL(for project: PropertyProject) -> URL? {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: localProjectsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for url in contents where url.pathExtension == "studiio" {
            if let loaded = try? loadProject(from: url), loaded.id == project.id {
                return url
            }
        }
        return nil
    }

    // MARK: - Errors

    enum ImportError: LocalizedError {
        case invalidFormat
        case missingMetadata
        case decodingFailed

        var errorDescription: String? {
            switch self {
            case .invalidFormat: return "Not a valid .studiio bundle"
            case .missingMetadata: return "Missing metadata.json in bundle"
            case .decodingFailed: return "Failed to read project data"
            }
        }
    }
}

// MARK: - UTType for .studiio bundles

extension UTType {
    static let studiioBundle = UTType(exportedAs: "com.studiio.scanner.project", conformingTo: .package)
}
