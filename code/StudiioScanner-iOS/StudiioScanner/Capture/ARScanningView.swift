import SwiftUI
import RoomPlan
import ARKit
import RealityKit

/// UIViewRepresentable that shows the camera feed via ARView with our
/// orange mesh overlay using our OWN ARSession with scene reconstruction.
///
/// We do NOT use RoomCaptureSession during scanning because its internal
/// ARRoomCaptureConfiguration does not support scene reconstruction (no mesh).
/// Instead we run ARWorldTrackingConfiguration with .mesh scene reconstruction
/// and process rooms from the mesh data after scanning completes.
struct ARScanningView: UIViewRepresentable {
    let sessionManager: ScanSessionManager
    let meshRenderer: MeshOverlayRenderer
    let debugLog: ScanDebugLog

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        // Don't let ARView auto-configure — we manage the session ourselves
        arView.automaticallyConfigureSession = false

        // Camera passthrough background
        arView.environment.background = .cameraFeed()
        arView.renderOptions = [
            .disablePersonOcclusion,
            .disableDepthOfField,
            .disableMotionBlur
        ]

        // Add the mesh overlay root entity to the scene
        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(meshRenderer.meshRoot)
        arView.scene.addAnchor(anchor)

        // Store references
        context.coordinator.arView = arView
        context.coordinator.sessionManager = sessionManager
        context.coordinator.meshRenderer = meshRenderer
        context.coordinator.debugLog = debugLog

        // Create and configure our OWN ARSession with scene reconstruction
        let arConfig = ARWorldTrackingConfiguration()

        // Phase B: Use meshWithClassification for surface-type labels (wall/floor/ceiling/door/window/etc.)
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            arConfig.sceneReconstruction = .meshWithClassification
            debugLog.log("Scene recon: MESH WITH CLASSIFICATION enabled")
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            arConfig.sceneReconstruction = .mesh
            debugLog.log("Scene recon: MESH enabled (no classification)")
        } else {
            debugLog.log("WARNING: Device doesn't support mesh!")
        }

        arConfig.environmentTexturing = .automatic
        arConfig.planeDetection = [.horizontal, .vertical]

        // Use the ARView's built-in session
        let session = arView.session

        // Set our delegate for mesh anchor callbacks
        let handler = ARMeshSessionHandler(
            manager: sessionManager,
            meshRenderer: meshRenderer,
            debugLog: debugLog
        )
        session.delegate = handler
        context.coordinator.sessionHandler = handler

        // Start the AR session
        session.run(arConfig)

        // Store references on the manager
        Task { @MainActor in
            sessionManager.attachARSession(session)
            sessionManager.scanState = .scanning
            debugLog.log("ARWorldTracking session started")
            debugLog.updateARConfig(session)
        }

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // No-op
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.arView?.session.pause()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    class Coordinator {
        var arView: ARView?
        var sessionHandler: ARMeshSessionHandler?
        weak var sessionManager: ScanSessionManager?
        weak var meshRenderer: MeshOverlayRenderer?
        weak var debugLog: ScanDebugLog?

        nonisolated deinit {}
    }
}

// MARK: - AR Session Delegate for Mesh Updates

/// Handles ARSession delegate callbacks for mesh anchor updates.
/// This replaces the old polling approach — delegate is the proper way
/// when we own the ARSession ourselves.
final class ARMeshSessionHandler: NSObject, ARSessionDelegate, @unchecked Sendable {

    private weak var manager: ScanSessionManager?
    private weak var meshRenderer: MeshOverlayRenderer?
    private weak var debugLog: ScanDebugLog?

    // Throttle mesh updates to prevent frame drops
    private var lastMeshUpdateTime: TimeInterval = 0
    private let meshUpdateInterval: TimeInterval = 0.5

    // Throttle per-frame callbacks to prevent main thread overload
    private var lastFrameProcessTime: TimeInterval = 0
    private let frameProcessInterval: TimeInterval = 0.2  // 5fps max, not 60fps
    private var isProcessingFrame = false

    init(manager: ScanSessionManager, meshRenderer: MeshOverlayRenderer, debugLog: ScanDebugLog) {
        self.manager = manager
        self.meshRenderer = meshRenderer
        self.debugLog = debugLog
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Throttle: only process ~5 frames per second, skip if previous task still pending
        let now = frame.timestamp
        guard now - lastFrameProcessTime >= frameProcessInterval else { return }
        guard !isProcessingFrame else { return }
        lastFrameProcessTime = now
        isProcessingFrame = true

        Task { @MainActor [weak self] in
            defer { self?.isProcessingFrame = false }
            self?.debugLog?.updateFromFrame(frame)
            self?.manager?.captureFrameIfNeeded(frame)
        }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        // Extract mesh anchors
        let meshAnchors = anchors.compactMap { $0 as? ARMeshAnchor }
        let extractedMesh = meshAnchors.compactMap { ExtractedMeshData(from: $0) }

        // Phase B: Extract plane anchors (classified surfaces)
        let planeAnchors = anchors.compactMap { $0 as? ARPlaneAnchor }
        let extractedPlanes = planeAnchors.map { ExtractedPlaneData(from: $0) }

        guard !extractedMesh.isEmpty || !extractedPlanes.isEmpty else { return }

        Task { @MainActor in
            for data in extractedMesh {
                manager?.storeMeshData(data)
                meshRenderer?.updateMesh(from: data)
            }
            for plane in extractedPlanes {
                manager?.storePlaneData(plane)
            }
            debugLog?.meshEntityCount = meshRenderer?.entityCount ?? 0
            if !extractedMesh.isEmpty {
                debugLog?.log("Added \(extractedMesh.count) mesh anchors")
            }
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        let meshAnchors = anchors.compactMap { $0 as? ARMeshAnchor }
        let planeAnchors = anchors.compactMap { $0 as? ARPlaneAnchor }

        // Throttle mesh updates — building MeshResource is expensive
        let now = CACurrentMediaTime()
        let shouldUpdateMesh = !meshAnchors.isEmpty && (now - lastMeshUpdateTime >= meshUpdateInterval)
        if shouldUpdateMesh { lastMeshUpdateTime = now }

        // CRITICAL: Extract mesh data NOW, before GPU buffers get recycled
        let extractedMesh = shouldUpdateMesh ? meshAnchors.compactMap { ExtractedMeshData(from: $0) } : []
        let extractedPlanes = planeAnchors.map { ExtractedPlaneData(from: $0) }

        guard !extractedMesh.isEmpty || !extractedPlanes.isEmpty else { return }

        Task { @MainActor in
            for data in extractedMesh {
                manager?.storeMeshData(data)
                meshRenderer?.updateMesh(from: data)
            }
            for plane in extractedPlanes {
                manager?.storePlaneData(plane)
            }
            debugLog?.meshEntityCount = meshRenderer?.entityCount ?? 0
        }
    }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        let meshAnchors = anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else { return }

        let removedIDs = meshAnchors.map(\.identifier)

        Task { @MainActor in
            manager?.removeMeshAnchors(meshAnchors)
            for id in removedIDs {
                meshRenderer?.removeMesh(identifier: id)
            }
            debugLog?.meshEntityCount = meshRenderer?.entityCount ?? 0
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: any Error) {
        Task { @MainActor in
            manager?.errorMessage = "AR error: \(error.localizedDescription)"
            debugLog?.log("AR ERROR: \(error.localizedDescription)")
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in
            manager?.errorMessage = "Scanning interrupted"
            debugLog?.log("Session interrupted")
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor in
            manager?.errorMessage = nil
            debugLog?.log("Interruption ended")
        }
    }
}
