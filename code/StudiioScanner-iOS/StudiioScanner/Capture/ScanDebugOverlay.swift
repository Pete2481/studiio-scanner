import SwiftUI
import ARKit
import RoomPlan

/// On-device debug overlay that shows real-time scanning diagnostics.
/// Tap the "Scanning..." pill to toggle visibility.
struct ScanDebugOverlay: View {
    @ObservedObject var debugLog: ScanDebugLog

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header
            HStack {
                Circle()
                    .fill(debugLog.arTrackingState == "Normal" ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text("DEBUG")
                    .font(.caption2.weight(.black))
                    .foregroundColor(.orange)
                Spacer()
                Text("\(debugLog.fps) FPS")
                    .font(.caption2.monospaced())
                    .foregroundColor(.white)
            }

            Divider().background(Color.gray)

            // AR Session
            debugRow("AR Tracking", debugLog.arTrackingState)
            debugRow("AR Config", debugLog.arConfigType)
            debugRow("Scene Recon", debugLog.sceneReconStatus)

            Divider().background(Color.gray)

            // Anchors
            debugRow("Total Anchors", "\(debugLog.totalAnchorCount)")
            debugRow("Mesh Anchors", "\(debugLog.meshAnchorCount)")
            debugRow("Mesh Vertices", "\(debugLog.totalMeshVertices)")
            debugRow("Mesh Entities", "\(debugLog.meshEntityCount)")

            Divider().background(Color.gray)

            // Rooms
            debugRow("Rooms (didAdd)", "\(debugLog.roomsAdded)")
            debugRow("Room Updates", "\(debugLog.roomUpdates)")

            Divider().background(Color.gray)

            // Last 5 log entries
            ForEach(debugLog.recentEntries.suffix(5), id: \.self) { entry in
                Text(entry)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.green)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.85))
        .cornerRadius(8)
        .frame(width: 220)
    }

    private func debugRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.gray)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
        }
    }
}

/// Collects debug data from the scanning pipeline
@MainActor
final class ScanDebugLog: ObservableObject {
    @Published var arTrackingState: String = "Unknown"
    @Published var arConfigType: String = "None"
    @Published var sceneReconStatus: String = "Unknown"
    @Published var totalAnchorCount: Int = 0
    @Published var meshAnchorCount: Int = 0
    @Published var totalMeshVertices: Int = 0
    @Published var meshEntityCount: Int = 0
    @Published var roomsAdded: Int = 0
    @Published var roomUpdates: Int = 0
    @Published var fps: Int = 0
    @Published var recentEntries: [String] = []

    private var frameCount: Int = 0
    private var lastFPSTime: TimeInterval = 0

    func log(_ message: String) {
        let timestamp = String(format: "%.1f", CACurrentMediaTime().truncatingRemainder(dividingBy: 1000))
        let entry = "[\(timestamp)] \(message)"
        recentEntries.append(entry)
        if recentEntries.count > 20 {
            recentEntries.removeFirst(recentEntries.count - 20)
        }
    }

    func updateFromFrame(_ frame: ARFrame) {
        // FPS counter
        frameCount += 1
        let now = CACurrentMediaTime()
        if now - lastFPSTime >= 1.0 {
            fps = frameCount
            frameCount = 0
            lastFPSTime = now
        }

        // Tracking state
        switch frame.camera.trackingState {
        case .notAvailable:
            arTrackingState = "Not Available"
        case .limited(let reason):
            switch reason {
            case .initializing: arTrackingState = "Initializing"
            case .excessiveMotion: arTrackingState = "Motion!"
            case .insufficientFeatures: arTrackingState = "Low Features"
            case .relocalizing: arTrackingState = "Relocalizing"
            @unknown default: arTrackingState = "Limited"
            }
        case .normal:
            arTrackingState = "Normal"
        }

        // Anchor counts
        totalAnchorCount = frame.anchors.count
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        meshAnchorCount = meshAnchors.count
        totalMeshVertices = meshAnchors.reduce(0) { $0 + $1.geometry.vertices.count }
    }

    func updateARConfig(_ session: ARSession) {
        if let config = session.configuration {
            arConfigType = String(describing: type(of: config))
                .replacingOccurrences(of: "Configuration", with: "")

            if let worldConfig = config as? ARWorldTrackingConfiguration {
                if worldConfig.sceneReconstruction.contains(.meshWithClassification) {
                    sceneReconStatus = "Mesh+Class"
                } else if worldConfig.sceneReconstruction.contains(.mesh) {
                    sceneReconStatus = "Mesh"
                } else {
                    sceneReconStatus = "OFF"
                }
            } else {
                sceneReconStatus = "N/A (not world)"
            }
        } else {
            arConfigType = "nil"
            sceneReconStatus = "No config"
        }
    }
}
