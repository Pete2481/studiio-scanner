import Foundation
import ARKit

/// Protocol for AI object detection — v3 feature.
/// v1 ships with a stub. v3 slots in a real CoreML model.
protocol CoreMLObjectDetector {
    func detect(in frame: ARFrame) async -> [DetectedObject]
}

struct DetectedObject {
    let category: ObjectCategory
    let confidence: Float       // 0.0 to 1.0
    let position: SIMD3<Float>
    let dimensions: SIMD3<Float>
}

/// Stub detector that returns nothing. Used in v1.
final class StubObjectDetector: CoreMLObjectDetector {
    static let isEnabled = false

    func detect(in frame: ARFrame) async -> [DetectedObject] {
        return []
    }
}
