import Foundation
import RoomPlan
import ARKit
import RealityKit
import Combine
import CoreImage
// AVFoundation removed — video recording stripped to prevent crashes on large scans

/// Manages the entire scanning session: RoomPlan capture, stair detection,
/// floor management, mesh collection, and auto photo capture.
///
/// The ARScanningView creates and owns the RoomCaptureView. This manager
/// receives callbacks from the session delegate and processes data.
@MainActor
final class ScanSessionManager: NSObject, ObservableObject {

    // MARK: - Published State

    @Published var scanState: ScanState = .idle
    @Published var capturedRooms: [CapturedRoom] = []
    @Published var currentFloor: FloorInProgress = FloorInProgress(name: "Ground", elevation: 0)
    @Published var floors: [FloorInProgress] = []
    @Published var roomCount: Int = 0
    @Published var showFloorTransitionAlert = false
    @Published var detectedElevationChange: ElevationChange?
    @Published var errorMessage: String?

    // Outdoor detection
    let outdoorDetector = OutdoorDetector()

    // Debug logging (set by ScanView)
    var debugLog: ScanDebugLog?

    // MARK: - Scan State Enum

    enum ScanState: Equatable {
        case idle
        case scanning
        case processing
        case complete
        case failed(String)

        static func == (lhs: ScanState, rhs: ScanState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.scanning, .scanning),
                 (.processing, .processing), (.complete, .complete):
                return true
            case (.failed(let a), .failed(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    // MARK: - Floor-in-Progress

    struct FloorInProgress: Identifiable {
        let id = UUID()
        var name: String
        var elevation: Double
        var roomIndices: [Int] = [] // indices into capturedRooms
    }

    // MARK: - Elevation Change

    struct ElevationChange {
        let deltaMetres: Double
        let direction: StairLink.StairDirection
    }

    // MARK: - Private Properties

    private var arSession: ARSession?

    // Stair detection
    private var baselineElevation: Float = 0
    private var elevationHistory: [(timestamp: TimeInterval, elevation: Float)] = []
    private let stairThresholdMetres: Float = 0.4
    private let stairWindowSeconds: TimeInterval = 5.0
    private var lastFloorTransitionTime: TimeInterval = 0
    private let floorTransitionCooldown: TimeInterval = 15.0

    // Mesh collection
    private(set) var collectedMeshAnchors: [ARMeshAnchor] = []
    private(set) var collectedMeshData: [ExtractedMeshData] = []

    // Phase B: Plane anchor collection (classified surfaces)
    private(set) var collectedPlanes: [ExtractedPlaneData] = []

    // Auto-capture photos for texture mapping (dolls house view)
    private(set) var capturedFrames: [CapturedFrame] = []
    private var lastFrameCaptureTime: TimeInterval = 0
    private let frameCaptureInterval: TimeInterval = 1.0

    struct CapturedFrame: Sendable {
        let jpegData: Data
        let timestamp: TimeInterval
        let transform: simd_float4x4
        let intrinsics: simd_float3x3       // camera intrinsics (fx, fy, cx, cy)
        let imageWidth: Int
        let imageHeight: Int
    }

    // Reusable CIContext for pixel buffer → JPEG conversion
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Initialization

    override init() {
        super.init()
    }

    // MARK: - Session Attachment (called by ARScanningView)

    /// Called by ARScanningView after creating the ARSession
    func attachARSession(_ session: ARSession) {
        self.arSession = session
    }

    // MARK: - Session Lifecycle

    func stopScanning() {
        guard scanState == .scanning else { return }
        scanState = .processing
        arSession?.pause()
    }

    func cancelScanning() {
        arSession?.pause()
        arSession = nil
        cleanUp()
        scanState = .idle
    }

    // MARK: - AR Session Access

    var activeARSession: ARSession? {
        arSession
    }

    // MARK: - Stair Detection

    func processElevationUpdate(transform: simd_float4x4, timestamp: TimeInterval) {
        let currentY = transform.columns.3.y

        // Set baseline on first reading
        if elevationHistory.isEmpty {
            baselineElevation = currentY
        }

        // Add to history
        elevationHistory.append((timestamp: timestamp, elevation: currentY))

        // Prune old entries outside our window
        let cutoff = timestamp - stairWindowSeconds
        elevationHistory.removeAll { $0.timestamp < cutoff }

        // Check for significant elevation change within the window
        guard elevationHistory.count >= 10 else { return }

        // Cooldown: don't trigger again too quickly after a floor transition
        guard timestamp - lastFloorTransitionTime > floorTransitionCooldown else { return }

        let oldestInWindow = elevationHistory.first!.elevation
        let delta = currentY - oldestInWindow

        if abs(delta) > stairThresholdMetres {
            let horizontalMovement = calculateHorizontalMovement(from: elevationHistory)
            guard horizontalMovement > 0.5 else { return }

            let direction: StairLink.StairDirection = delta > 0 ? .up : .down
            detectedElevationChange = ElevationChange(
                deltaMetres: Double(delta),
                direction: direction
            )
            showFloorTransitionAlert = true
        }
    }

    private func calculateHorizontalMovement(from history: [(timestamp: TimeInterval, elevation: Float)]) -> Float {
        guard history.count >= 5 else { return 0 }

        var increasing = 0
        var decreasing = 0
        for i in 1..<history.count {
            if history[i].elevation > history[i-1].elevation {
                increasing += 1
            } else {
                decreasing += 1
            }
        }

        let ratio = Float(max(increasing, decreasing)) / Float(history.count - 1)
        return ratio > 0.7 ? 1.0 : 0.0
    }

    // MARK: - Floor Management

    func confirmFloorTransition(isNewFloor: Bool, floorName: String?) {
        lastFloorTransitionTime = elevationHistory.last?.timestamp ?? 0

        if isNewFloor {
            floors.append(currentFloor)

            let name = floorName ?? (detectedElevationChange?.direction == .up ? "Upper Floor" : "Lower Floor")
            let elevation = Double(elevationHistory.last?.elevation ?? 0) - Double(baselineElevation)
            currentFloor = FloorInProgress(name: name, elevation: elevation)
        }

        showFloorTransitionAlert = false
        detectedElevationChange = nil
    }

    func dismissFloorTransition() {
        showFloorTransitionAlert = false
        detectedElevationChange = nil
        lastFloorTransitionTime = elevationHistory.last?.timestamp ?? 0
    }

    // MARK: - Room Tracking (no longer used during scanning, kept for future RoomPlan post-processing)

    // MARK: - Mesh Collection

    func updateMeshAnchors(_ anchors: [ARMeshAnchor]) {
        for anchor in anchors {
            if let existingIndex = collectedMeshAnchors.firstIndex(where: { $0.identifier == anchor.identifier }) {
                collectedMeshAnchors[existingIndex] = anchor
            } else {
                collectedMeshAnchors.append(anchor)
            }
        }
    }

    func storeMeshData(_ data: ExtractedMeshData) {
        if let existingIndex = collectedMeshData.firstIndex(where: { $0.identifier == data.identifier }) {
            collectedMeshData[existingIndex] = data
        } else {
            collectedMeshData.append(data)
        }
    }

    func removeMeshAnchors(_ anchors: [ARMeshAnchor]) {
        let idsToRemove = Set(anchors.map(\.identifier))
        collectedMeshAnchors.removeAll { idsToRemove.contains($0.identifier) }
    }

    // MARK: - Phase B: Plane Anchor Collection

    func storePlaneData(_ plane: ExtractedPlaneData) {
        if let existingIndex = collectedPlanes.firstIndex(where: { $0.identifier == plane.identifier }) {
            collectedPlanes[existingIndex] = plane
        } else {
            collectedPlanes.append(plane)
        }
    }

    // MARK: - Frame Capture

    func captureFrameIfNeeded(_ frame: ARFrame) {
        let now = frame.timestamp

        // Process elevation for stair detection (lightweight — just math)
        processElevationUpdate(transform: frame.camera.transform, timestamp: now)

        // Feed outdoor detector (lightweight)
        outdoorDetector.processFrame(
            frame,
            meshAnchorCount: collectedMeshAnchors.count,
            nearbyMeshAnchors: collectedMeshAnchors.count
        )

        // JPEG capture for texture mapping (at configured intervals)
        guard now - lastFrameCaptureTime >= frameCaptureInterval else { return }
        lastFrameCaptureTime = now

        // Capture metadata synchronously (lightweight), but convert JPEG off main thread
        let transform = frame.camera.transform
        let intrinsics = frame.camera.intrinsics
        let pixelBuffer = frame.capturedImage
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Create CIImage on main thread while pixel buffer is still valid
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = 960.0 / Double(width)
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Do the heavy JPEG encoding on a background queue
        let ctx = self.ciContext
        Task.detached(priority: .utility) { [weak self] in
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            guard let jpeg = ctx.jpegRepresentation(
                of: scaled, colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7]
            ) else { return }

            let capturedFrame = CapturedFrame(
                jpegData: jpeg, timestamp: now, transform: transform,
                intrinsics: intrinsics, imageWidth: width, imageHeight: height
            )
            await MainActor.run { [weak self] in
                self?.capturedFrames.append(capturedFrame)
            }
        }
    }

    // MARK: - Finalization

    func finalizeCapture() async -> PropertyProject? {

        // Run geometry-based object detection on collected mesh data + plane anchors
        debugLog?.log("Running object detection on \(collectedMeshData.count) mesh anchors + \(collectedPlanes.count) plane anchors...")
        let detection = MeshObjectDetector.detect(from: collectedMeshData, planeData: collectedPlanes)

        debugLog?.log("Detected \(detection.objects.count) objects, \(detection.openings.count) openings, \(detection.wallLines.count) walls, \(detection.rooms.count) ceiling-segmented rooms")

        // Build rooms: use ceiling-plane segmented rooms if available, otherwise single room fallback
        let scannedRooms: [Room]
        if !detection.rooms.isEmpty {
            scannedRooms = detection.rooms.map { seg in
                Room(
                    name: seg.name,
                    objects: [],  // object detection disabled
                    area: seg.area,
                    walls: seg.walls,
                    openings: seg.openings,
                    roomWidth: seg.width,
                    roomDepth: seg.depth,
                    floorLevel: Double(detection.floorLevel),
                    ceilingLevel: Double(detection.ceilingLevel),
                    wallAlignmentAngle: Double(detection.wallAlignmentAngle),
                    floorPolygon: seg.polygon
                )
            }
            debugLog?.log("Using \(scannedRooms.count) ceiling-segmented rooms")
            for (i, r) in scannedRooms.enumerated() {
                debugLog?.log("  Room \(i): '\(r.name)' \(String(format: "%.1f", r.roomWidth ?? 0))x\(String(format: "%.1f", r.roomDepth ?? 0))m, \(r.walls.count) walls, \(r.openings.count) openings")
            }
        } else {
            // Fallback: single room from all detected geometry
            let totalArea: Double
            if let dims = detection.roomDimensions {
                totalArea = Double(dims.width * dims.depth)
            } else {
                totalArea = estimateAreaFromMesh()
            }
            scannedRooms = [Room(
                name: "Scanned Area",
                objects: detection.objects,
                area: totalArea,
                walls: detection.wallLines,
                openings: detection.openings,
                roomWidth: detection.roomDimensions.map { Double($0.width) },
                roomDepth: detection.roomDimensions.map { Double($0.depth) },
                floorLevel: Double(detection.floorLevel),
                ceilingLevel: Double(detection.ceilingLevel),
                wallAlignmentAngle: Double(detection.wallAlignmentAngle),
                floorPolygon: detection.floorPolygon
            )]
            debugLog?.log("Fallback: single room, area \(String(format: "%.1f", totalArea))m²")
        }

        var allFloors = floors
        allFloors.append(currentFloor)

        let projectFloors: [Floor]
        if allFloors.count <= 1 {
            projectFloors = [Floor(
                name: "Ground",
                elevation: 0,
                rooms: scannedRooms
            )]
        } else {
            // Multi-floor: for now, put all rooms on the current floor
            // (future: assign rooms to floors by elevation)
            projectFloors = allFloors.enumerated().map { (i, floor) in
                Floor(
                    name: floor.name,
                    elevation: floor.elevation,
                    rooms: i == allFloors.count - 1 ? scannedRooms : []
                )
            }
        }

        let project = PropertyProject(floors: projectFloors)
        scanState = .complete
        return project
    }

    /// Estimate total floor area from collected mesh data by measuring
    /// the horizontal bounding extent of all mesh vertices.
    private func estimateAreaFromMesh() -> Double {
        guard !collectedMeshData.isEmpty else {
            debugLog?.log("No mesh data for area calc!")
            return 0
        }

        var minX: Float = .greatestFiniteMagnitude
        var maxX: Float = -.greatestFiniteMagnitude
        var minZ: Float = .greatestFiniteMagnitude
        var maxZ: Float = -.greatestFiniteMagnitude

        for data in collectedMeshData {
            let transform = data.transform
            for vertex in data.positions {
                // Transform to world space
                let worldPos = transform * SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1.0)
                minX = min(minX, worldPos.x)
                maxX = max(maxX, worldPos.x)
                minZ = min(minZ, worldPos.z)
                maxZ = max(maxZ, worldPos.z)
            }
        }

        let width = Double(maxX - minX)
        let depth = Double(maxZ - minZ)
        debugLog?.log("Bounds: \(String(format: "%.1f", width))x\(String(format: "%.1f", depth))m")

        // Rough floor area from bounding box (multiply by ~0.7 for typical room shapes)
        return width * depth * 0.7
    }

    // MARK: - Cleanup

    private func cleanUp() {
        collectedMeshAnchors.removeAll()
        collectedMeshData.removeAll()
        collectedPlanes.removeAll()
        capturedFrames.removeAll()
        capturedRooms.removeAll()
        elevationHistory.removeAll()
        roomCount = 0
        floors.removeAll()
        currentFloor = FloorInProgress(name: "Ground", elevation: 0)

    }
}
