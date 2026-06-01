import Foundation
import ARKit
import Vision
import CoreImage

/// Detects indoor/outdoor transitions during scanning using multiple signals:
/// 1. Ambient light level (outdoor typically >2000 lux)
/// 2. LiDAR mesh density (outdoor has sparse nearby surfaces)
/// 3. Sky detection via Vision framework
/// 4. Door/opening transit from RoomPlan
///
/// When 3 of 4 signals agree, a mode switch is triggered.
@MainActor
final class OutdoorDetector: ObservableObject {

    // MARK: - Published State

    @Published var currentMode: ScanMode = .indoor
    @Published var modeTransitionBanner: String?

    enum ScanMode: String {
        case indoor
        case outdoor
    }

    // MARK: - Signal State

    struct SignalState {
        var lightLevel: SignalVote = .undetermined
        var meshDensity: SignalVote = .undetermined
        var skyDetected: SignalVote = .undetermined
        var doorTransit: SignalVote = .undetermined

        var outdoorVoteCount: Int {
            [lightLevel, meshDensity, skyDetected, doorTransit]
                .filter { $0 == .outdoor }
                .count
        }

        var indoorVoteCount: Int {
            [lightLevel, meshDensity, skyDetected, doorTransit]
                .filter { $0 == .indoor }
                .count
        }
    }

    enum SignalVote {
        case indoor
        case outdoor
        case undetermined
    }

    // MARK: - Properties

    private(set) var signals = SignalState()
    private let votesRequired = 3

    // Thresholds
    private let outdoorLightThreshold: CGFloat = 2000  // lux
    private let indoorLightThreshold: CGFloat = 500    // lux
    private let sparseMeshThreshold: Int = 5           // fewer mesh anchors nearby = outdoor
    private let densesMeshThreshold: Int = 15          // more mesh anchors nearby = indoor

    // Cooldown to prevent rapid flickering
    private var lastModeChange: TimeInterval = 0
    private let modeCooldownSeconds: TimeInterval = 5.0

    // Sky detection
    private let ciContext = CIContext()
    private var lastSkyCheckTime: TimeInterval = 0
    private let skyCheckInterval: TimeInterval = 2.0

    // Door transit tracking
    private var lastDoorDetectionTime: TimeInterval = 0
    private var doorTransitWindow: TimeInterval = 5.0

    // MARK: - Process Frame

    /// Called every AR frame to evaluate indoor/outdoor signals.
    func processFrame(_ frame: ARFrame, meshAnchorCount: Int, nearbyMeshAnchors: Int) {
        let timestamp = frame.timestamp

        // Signal 1: Light level
        if let lightEstimate = frame.lightEstimate {
            let lux = CGFloat(lightEstimate.ambientIntensity)
            if lux > outdoorLightThreshold {
                signals.lightLevel = .outdoor
            } else if lux < indoorLightThreshold {
                signals.lightLevel = .indoor
            }
            // Between thresholds: keep previous vote (hysteresis)
        }

        // Signal 2: Mesh density
        if nearbyMeshAnchors < sparseMeshThreshold {
            signals.meshDensity = .outdoor
        } else if nearbyMeshAnchors > densesMeshThreshold {
            signals.meshDensity = .indoor
        }

        // Signal 3: Sky detection (throttled — expensive)
        if timestamp - lastSkyCheckTime > skyCheckInterval {
            lastSkyCheckTime = timestamp
            Task {
                await detectSky(in: frame)
            }
        }

        // Signal 4: Door transit is set externally via notifyDoorDetected()

        // Evaluate mode change
        evaluateModeChange(timestamp: timestamp)
    }

    /// Called when RoomPlan detects a door or opening near the user's position.
    func notifyDoorDetected(at timestamp: TimeInterval) {
        lastDoorDetectionTime = timestamp
        signals.doorTransit = .outdoor // transitioning through a door suggests going outside

        // Reset after window expires
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(doorTransitWindow))
            if signals.doorTransit == .outdoor {
                signals.doorTransit = .undetermined
            }
        }
    }

    /// Override detection when user manually corrects
    func overrideMode(_ mode: ScanMode) {
        currentMode = mode
        lastModeChange = ProcessInfo.processInfo.systemUptime
        modeTransitionBanner = nil
    }

    // MARK: - Evaluation

    private func evaluateModeChange(timestamp: TimeInterval) {
        // Cooldown check
        guard timestamp - lastModeChange > modeCooldownSeconds else { return }

        let shouldBeOutdoor = signals.outdoorVoteCount >= votesRequired
        let shouldBeIndoor = signals.indoorVoteCount >= votesRequired

        if shouldBeOutdoor && currentMode == .indoor {
            currentMode = .outdoor
            lastModeChange = timestamp
            modeTransitionBanner = "Outside detected — scanning deck"
            clearBannerAfterDelay()
        } else if shouldBeIndoor && currentMode == .outdoor {
            currentMode = .indoor
            lastModeChange = timestamp
            modeTransitionBanner = "Back inside — scanning room"
            clearBannerAfterDelay()
        }
    }

    private func clearBannerAfterDelay() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            modeTransitionBanner = nil
        }
    }

    // MARK: - Sky Detection

    private func detectSky(in frame: ARFrame) async {
        let pixelBuffer = frame.capturedImage

        // Use Vision to detect the horizon / sky region
        // We check the top quarter of the image for high-brightness, low-saturation pixels
        // which is a simple proxy for open sky.
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Crop to top quarter
        let topQuarter = ciImage.cropped(to: CGRect(
            x: 0,
            y: CGFloat(height) * 0.75, // CIImage origin is bottom-left
            width: CGFloat(width),
            height: CGFloat(height) * 0.25
        ))

        // Calculate average brightness of top quarter
        guard let avgFilter = CIFilter(name: "CIAreaAverage") else { return }
        avgFilter.setValue(topQuarter, forKey: kCIInputImageKey)
        avgFilter.setValue(CIVector(cgRect: topQuarter.extent), forKey: "inputExtent")

        guard let outputImage = avgFilter.outputImage else { return }

        var bitmap = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        let brightness = (Float(bitmap[0]) + Float(bitmap[1]) + Float(bitmap[2])) / (3.0 * 255.0)

        // High brightness in top quarter suggests open sky
        await MainActor.run {
            if brightness > 0.7 {
                signals.skyDetected = .outdoor
            } else if brightness < 0.3 {
                signals.skyDetected = .indoor
            }
        }
    }
}
