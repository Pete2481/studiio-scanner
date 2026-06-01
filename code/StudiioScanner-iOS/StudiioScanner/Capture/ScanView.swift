import SwiftUI
import RoomPlan
import ARKit
import RealityKit

/// The main scanning view — presents the AR camera feed with orange mesh overlay,
/// scanning controls, room counter, floor transition alerts, and optional debug overlay.
struct ScanView: View {
    @StateObject private var sessionManager = ScanSessionManager()
    @StateObject private var meshRenderer = MeshOverlayRenderer()
    @StateObject private var debugLog = ScanDebugLog()
    @ObservedObject var projectStore: ProjectStore
    @Binding var isPresented: Bool
    @State private var showCancelConfirmation = false
    @State private var showProcessingOverlay = false
    @State private var completedProject: PropertyProject?
    @State private var showPostScanPreview = false
    @State private var showDebug = true // Show by default for testing

    var body: some View {
        ZStack {
            // AR Camera + orange mesh overlay
            ARScanningView(
                sessionManager: sessionManager,
                meshRenderer: meshRenderer,
                debugLog: debugLog
            )
            .ignoresSafeArea()
            .onAppear {
                sessionManager.debugLog = debugLog
            }

            // UI Chrome overlay
            VStack {
                topChrome
                Spacer()
                bottomChrome
            }

            // Debug overlay (top-left, below status bar)
            if showDebug {
                VStack {
                    Spacer().frame(height: 100)
                    HStack {
                        ScanDebugOverlay(debugLog: debugLog)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.leading, 8)
            }

            // Floor transition alert
            if sessionManager.showFloorTransitionAlert {
                floorTransitionOverlay
            }

            // Processing overlay
            if showProcessingOverlay {
                processingOverlay
            }

            // Outdoor detection banner
            if let banner = sessionManager.outdoorDetector.modeTransitionBanner {
                outdoorBanner(banner)
            }

            // Error banner
            if let error = sessionManager.errorMessage {
                errorBanner(error)
            }
        }
        .statusBarHidden()
        .alert("Cancel Scan?", isPresented: $showCancelConfirmation) {
            Button("Continue Scanning", role: .cancel) { }
            Button("Discard", role: .destructive) {
                sessionManager.cancelScanning()
                isPresented = false
            }
        } message: {
            Text("Your scan progress will be lost.")
        }
        .fullScreenCover(isPresented: $showPostScanPreview) {
            if let project = completedProject {
                PostScanPreviewView(
                    project: project,
                    meshData: sessionManager.collectedMeshData,
                    onSave: { savedProject in
                        do {
                            // Convert captured frames for saving
                            let frameData = sessionManager.capturedFrames.map { frame in
                                CapturedFrameData(
                                    jpegData: frame.jpegData,
                                    timestamp: frame.timestamp,
                                    transform: frame.transform,
                                    intrinsics: frame.intrinsics,
                                    imageWidth: frame.imageWidth,
                                    imageHeight: frame.imageHeight
                                )
                            }
                            try projectStore.saveProject(
                                savedProject,
                                meshData: sessionManager.collectedMeshData,
                                frames: frameData,
                                planes: sessionManager.collectedPlanes
                            )
                        } catch {
                            print("Failed to save project: \(error)")
                        }
                        completedProject = savedProject
                        isPresented = false
                    },
                    onDiscard: {
                        isPresented = false
                    }
                )
            }
        }
    }

    // MARK: - Top Chrome

    private var topChrome: some View {
        HStack {
            // Scanning indicator — tap to toggle debug
            Button {
                showDebug.toggle()
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)

                    Text("Scanning...")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            }

            Spacer()

            // Mesh coverage indicator
            if debugLog.meshAnchorCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "cube.transparent")
                        .font(.caption)
                    Text("\(debugLog.meshAnchorCount) mesh")
                        .font(.caption.weight(.medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
            }

            Spacer()

            // Cancel button
            Button {
                showCancelConfirmation = true
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, StudiioTheme.spacingM)
        .padding(.top, 8)
    }

    // MARK: - Bottom Chrome

    private var bottomChrome: some View {
        VStack(spacing: StudiioTheme.spacingM) {
            // Current floor indicator
            HStack(spacing: 6) {
                Image(systemName: "building.2")
                    .font(.caption2)
                Text(sessionManager.currentFloor.name)
                    .font(.caption.weight(.medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())

            // Complete scan button
            Button {
                completeScan()
            } label: {
                Text("Complete scan")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(
                        Capsule()
                            .fill(StudiioTheme.accentOrange)
                    )
            }
            .padding(.horizontal, StudiioTheme.spacingXL)
        }
        .padding(.bottom, StudiioTheme.spacingL)
    }

    // MARK: - Floor Transition Overlay

    private var floorTransitionOverlay: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()

            VStack(spacing: StudiioTheme.spacingL) {
                Image(systemName: sessionManager.detectedElevationChange?.direction == .up
                      ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(StudiioTheme.accentOrange)

                Text("Floor Change Detected")
                    .font(.title2.weight(.bold))
                    .foregroundColor(.white)

                if let change = sessionManager.detectedElevationChange {
                    Text("Elevation changed \(String(format: "%.1f", abs(change.deltaMetres)))m \(change.direction == .up ? "up" : "down")")
                        .font(.subheadline)
                        .foregroundColor(StudiioTheme.textSecondary)
                }

                VStack(spacing: StudiioTheme.spacingS) {
                    Button("Yes, this is upstairs") {
                        sessionManager.confirmFloorTransition(isNewFloor: true, floorName: "Upper Floor")
                    }
                    .buttonStyle(.studiioPrimary)

                    Button("Yes, this is downstairs") {
                        sessionManager.confirmFloorTransition(isNewFloor: true, floorName: "Lower Floor")
                    }
                    .buttonStyle(.studiioPrimary)

                    Button("No, same floor") {
                        sessionManager.dismissFloorTransition()
                    }
                    .buttonStyle(.studiioSecondary)
                }
            }
            .padding(StudiioTheme.spacingXL)
            .studiioCard()
            .padding(StudiioTheme.spacingL)
        }
    }

    // MARK: - Processing Overlay

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(spacing: StudiioTheme.spacingM) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(StudiioTheme.accentOrange)
                    .scaleEffect(1.5)

                Text("Processing scan...")
                    .font(.headline)
                    .foregroundColor(.white)

                Text("Processing \(debugLog.meshAnchorCount) mesh segments")
                    .font(.subheadline)
                    .foregroundColor(StudiioTheme.textSecondary)
            }
            .studiioCard()
            .padding(StudiioTheme.spacingXL)
        }
    }

    // MARK: - Outdoor Detection Banner

    private func outdoorBanner(_ message: String) -> some View {
        VStack {
            Spacer()

            HStack(spacing: 8) {
                Image(systemName: sessionManager.outdoorDetector.currentMode == .outdoor
                      ? "sun.max.fill" : "house.fill")
                    .foregroundColor(StudiioTheme.accentOrange)
                Text(message)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white)
                Spacer()
                Button("Override") {
                    let newMode: OutdoorDetector.ScanMode =
                        sessionManager.outdoorDetector.currentMode == .outdoor ? .indoor : .outdoor
                    sessionManager.outdoorDetector.overrideMode(newMode)
                }
                .font(.caption.weight(.bold))
                .foregroundColor(StudiioTheme.accentOrange)
            }
            .padding(StudiioTheme.spacingS)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: StudiioTheme.cornerRadiusSmall))
            .padding(.horizontal, StudiioTheme.spacingM)
            .padding(.bottom, 120)
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        VStack {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(StudiioTheme.accentOrange)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.white)
                Spacer()
                Button {
                    sessionManager.errorMessage = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundColor(StudiioTheme.textSecondary)
                }
            }
            .padding(StudiioTheme.spacingS)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: StudiioTheme.cornerRadiusSmall))
            .padding(.horizontal, StudiioTheme.spacingM)
            .padding(.top, 60)

            Spacer()
        }
    }

    // MARK: - Actions

    private func completeScan() {
        showProcessingOverlay = true
        sessionManager.stopScanning()

        Task {
            let project = await sessionManager.finalizeCapture()
            showProcessingOverlay = false
            if let project {
                completedProject = project
                showPostScanPreview = true
            }
        }
    }
}
