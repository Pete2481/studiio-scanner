import Foundation
import simd

/// Camera frame data for texture mapping, passed from scanner to project store.
struct CapturedFrameData: Sendable {
    let jpegData: Data
    let timestamp: TimeInterval
    let transform: simd_float4x4
    let intrinsics: simd_float3x3
    let imageWidth: Int
    let imageHeight: Int
}

/// Manages saving, loading, and listing PropertyProject files on disk.
/// Projects are stored as .studiio bundles (zipped JSON + assets).
@MainActor
final class ProjectStore: ObservableObject {

    @Published var projects: [PropertyProject] = []

    private let fileManager = FileManager.default

    /// Base directory for all projects
    private var projectsDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("StudiioProjects", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Load All

    func loadProjects() {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            projects = []
            return
        }

        let loaded = contents
            .filter { $0.pathExtension == "studiio" }
            .compactMap { loadProject(from: $0) }
            .sorted { $0.capturedAt > $1.capturedAt }

        projects = loaded
    }

    // MARK: - Save

    func saveProject(_ project: PropertyProject, meshData: [ExtractedMeshData] = [], frames: [CapturedFrameData] = [], planes: [ExtractedPlaneData] = []) throws {
        let bundleURL = projectsDirectory
            .appendingPathComponent(bundleName(for: project))

        // Create bundle directory
        try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        // Write metadata.json
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        try data.write(to: bundleURL.appendingPathComponent("metadata.json"))

        // Create subdirectories for floors
        for floor in project.floors {
            let floorDir = bundleURL
                .appendingPathComponent("floors")
                .appendingPathComponent(sanitize(floor.name))
            try fileManager.createDirectory(at: floorDir, withIntermediateDirectories: true)

            // Write each room
            for (index, room) in floor.rooms.enumerated() {
                let roomData = try encoder.encode(room)
                let roomFile = floorDir.appendingPathComponent("room-\(String(format: "%03d", index)).json")
                try roomData.write(to: roomFile)
            }
        }

        // Save mesh data as binary for floor plan generation
        if !meshData.isEmpty {
            let meshDir = bundleURL.appendingPathComponent("mesh")
            try fileManager.createDirectory(at: meshDir, withIntermediateDirectories: true)

            // Save mesh summary as JSON (vertices, faces per anchor)
            var meshSummary: [[String: Any]] = []
            for (index, mesh) in meshData.enumerated() {
                // Save each mesh anchor as a compact binary file
                let meshFile = meshDir.appendingPathComponent("mesh-\(String(format: "%03d", index)).bin")
                let binaryData = encodeMeshBinary(mesh)
                try binaryData.write(to: meshFile)

                meshSummary.append([
                    "id": mesh.identifier.uuidString,
                    "vertices": mesh.positions.count,
                    "triangles": mesh.indices.count / 3,
                    "file": "mesh-\(String(format: "%03d", index)).bin"
                ])
            }

            // Save mesh index
            let indexData = try JSONSerialization.data(
                withJSONObject: ["anchors": meshSummary, "count": meshData.count],
                options: [.prettyPrinted, .sortedKeys]
            )
            try indexData.write(to: meshDir.appendingPathComponent("index.json"))
        }

        // Save camera frames for texture mapping (dolls house view)
        if !frames.isEmpty {
            let framesDir = bundleURL.appendingPathComponent("frames")
            try fileManager.createDirectory(at: framesDir, withIntermediateDirectories: true)

            var frameIndex: [[String: Any]] = []
            for (index, frame) in frames.enumerated() {
                let filename = "frame-\(String(format: "%04d", index)).jpg"
                try frame.jpegData.write(to: framesDir.appendingPathComponent(filename))

                // Store transform as flat array of 16 floats (column-major)
                let t = frame.transform
                let transformArray: [Float] = [
                    t.columns.0.x, t.columns.0.y, t.columns.0.z, t.columns.0.w,
                    t.columns.1.x, t.columns.1.y, t.columns.1.z, t.columns.1.w,
                    t.columns.2.x, t.columns.2.y, t.columns.2.z, t.columns.2.w,
                    t.columns.3.x, t.columns.3.y, t.columns.3.z, t.columns.3.w
                ]

                // Store intrinsics (3x3 matrix, column-major)
                let k = frame.intrinsics
                let intrinsicsArray: [Float] = [
                    k.columns.0.x, k.columns.0.y, k.columns.0.z,
                    k.columns.1.x, k.columns.1.y, k.columns.1.z,
                    k.columns.2.x, k.columns.2.y, k.columns.2.z
                ]

                frameIndex.append([
                    "file": filename,
                    "timestamp": frame.timestamp,
                    "transform": transformArray,
                    "intrinsics": intrinsicsArray,
                    "width": frame.imageWidth,
                    "height": frame.imageHeight
                ])
            }

            let indexData = try JSONSerialization.data(
                withJSONObject: ["frames": frameIndex, "count": frames.count],
                options: [.prettyPrinted, .sortedKeys]
            )
            try indexData.write(to: framesDir.appendingPathComponent("index.json"))
        }

        // Phase B: Save classified plane anchors
        if !planes.isEmpty {
            let planesDir = bundleURL.appendingPathComponent("planes")
            try fileManager.createDirectory(at: planesDir, withIntermediateDirectories: true)

            var planeIndex: [[String: Any]] = []
            for plane in planes {
                let t = plane.transform
                let transformArray: [Float] = [
                    t.columns.0.x, t.columns.0.y, t.columns.0.z, t.columns.0.w,
                    t.columns.1.x, t.columns.1.y, t.columns.1.z, t.columns.1.w,
                    t.columns.2.x, t.columns.2.y, t.columns.2.z, t.columns.2.w,
                    t.columns.3.x, t.columns.3.y, t.columns.3.z, t.columns.3.w
                ]
                planeIndex.append([
                    "id": plane.identifier.uuidString,
                    "alignment": plane.alignment.rawValue,
                    "classification": plane.classification.rawValue,
                    "extentX": plane.extentX,
                    "extentZ": plane.extentZ,
                    "centerX": plane.centerX,
                    "centerZ": plane.centerZ,
                    "transform": transformArray
                ])
            }

            let indexData = try JSONSerialization.data(
                withJSONObject: ["planes": planeIndex, "count": planes.count],
                options: [.prettyPrinted, .sortedKeys]
            )
            try indexData.write(to: planesDir.appendingPathComponent("index.json"))
        }

        // Create outbuildings directory
        if !project.outbuildings.isEmpty {
            let outDir = bundleURL.appendingPathComponent("outbuildings")
            try fileManager.createDirectory(at: outDir, withIntermediateDirectories: true)
        }

        // Create outdoor-zones directory
        if !project.outdoorZones.isEmpty {
            let outdoorDir = bundleURL.appendingPathComponent("outdoor-zones")
            try fileManager.createDirectory(at: outdoorDir, withIntermediateDirectories: true)
        }

        // Reload projects list
        loadProjects()
    }

    /// Encode mesh data as compact binary: transform (64 bytes) + vertex count (4) + positions + index count (4) + indices
    private func encodeMeshBinary(_ mesh: ExtractedMeshData) -> Data {
        var data = Data()

        // Transform matrix (16 floats = 64 bytes)
        withUnsafeBytes(of: mesh.transform) { data.append(contentsOf: $0) }

        // Vertex count
        var vertexCount = UInt32(mesh.positions.count)
        withUnsafeBytes(of: &vertexCount) { data.append(contentsOf: $0) }

        // Positions (3 floats each)
        for pos in mesh.positions {
            var p = pos
            withUnsafeBytes(of: &p) { data.append(contentsOf: $0) }
        }

        // Normal count
        var normalCount = UInt32(mesh.normals.count)
        withUnsafeBytes(of: &normalCount) { data.append(contentsOf: $0) }

        // Normals
        for norm in mesh.normals {
            var n = norm
            withUnsafeBytes(of: &n) { data.append(contentsOf: $0) }
        }

        // Index count
        var indexCount = UInt32(mesh.indices.count)
        withUnsafeBytes(of: &indexCount) { data.append(contentsOf: $0) }

        // Indices
        for idx in mesh.indices {
            var i = idx
            withUnsafeBytes(of: &i) { data.append(contentsOf: $0) }
        }

        return data
    }

    // MARK: - Update

    func updateProject(_ project: PropertyProject) throws {
        guard let existingURL = bundleURL(forProjectID: project.id) else { return }

        // Write updated metadata
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        try data.write(to: existingURL.appendingPathComponent("metadata.json"))

        // Rename bundle if address changed
        let newURL = projectsDirectory.appendingPathComponent(bundleName(for: project))
        if existingURL != newURL && !fileManager.fileExists(atPath: newURL.path) {
            try fileManager.moveItem(at: existingURL, to: newURL)
        }

        loadProjects()
    }

    func saveHeroImage(_ imageData: Data, for project: PropertyProject) throws -> String {
        guard let bundleURL = bundleURL(forProjectID: project.id) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let filename = "hero.jpg"
        try imageData.write(to: bundleURL.appendingPathComponent(filename))
        return filename
    }

    func heroImageURL(for project: PropertyProject) -> URL? {
        guard let path = project.heroImagePath,
              let bundleURL = bundleURL(forProjectID: project.id) else { return nil }
        let url = bundleURL.appendingPathComponent(path)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: - Delete

    func deleteProject(_ project: PropertyProject) throws {
        guard let bundleURL = bundleURL(forProjectID: project.id) else { return }
        try fileManager.removeItem(at: bundleURL)
        loadProjects()
    }

    // MARK: - Load Single Project

    private func loadProject(from url: URL) -> PropertyProject? {
        let metadataURL = url.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PropertyProject.self, from: data)
    }

    // MARK: - Export for Sync

    /// Returns the URL of the .studiio bundle, ready for sharing via AirDrop, iCloud, etc.
    func exportURL(for project: PropertyProject) -> URL {
        bundleURL(forProjectID: project.id)
            ?? projectsDirectory.appendingPathComponent(bundleName(for: project))
    }

    // MARK: - Helpers

    /// Find existing bundle on disk by scanning metadata for matching project ID.
    private func bundleURL(forProjectID id: UUID) -> URL? {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for url in contents where url.pathExtension == "studiio" {
            let metadataURL = url.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metadataURL),
                  let project = try? decoder.decode(PropertyProject.self, from: data),
                  project.id == id else { continue }
            return url
        }
        return nil
    }

    private func bundleName(for project: PropertyProject) -> String {
        let address = project.address ?? "untitled"
        let date = ISO8601DateFormatter().string(from: project.capturedAt)
            .replacingOccurrences(of: ":", with: "-")
        let sanitized = sanitize("\(address)-\(date)")
        return "\(sanitized).studiio"
    }

    private func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        return name
            .components(separatedBy: allowed.inverted)
            .joined()
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
            .prefix(100)
            .description
    }
}
