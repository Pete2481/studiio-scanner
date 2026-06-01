import Foundation
import Speech

/// Voice tagging stub — architected for v2, disabled by feature flag in v1.
/// During scan, user says "this is a shower" and a tag is placed at current position.
@MainActor
final class VoiceTaggingEngine: ObservableObject {

    @Published var isListening = false
    @Published var lastTranscript: String?

    // Feature flag — disabled in v1
    nonisolated static let isEnabled = false

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    init() {
        guard Self.isEnabled else { return }
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-AU"))
    }

    func startListening() {
        guard Self.isEnabled else { return }
        // v2 implementation: connect to audio engine, start recognition
        isListening = true
    }

    func stopListening() {
        guard Self.isEnabled else { return }
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        isListening = false
    }

    /// Attempt to match a transcript to an ObjectCategory.
    nonisolated static func matchCategory(from transcript: String) -> ObjectCategory? {
        let lower = transcript.lowercased()

        let mapping: [(keywords: [String], category: ObjectCategory)] = [
            (["shower"], .shower),
            (["vanity", "basin"], .vanity),
            (["toilet", "loo", "wc"], .toilet),
            (["bath", "bathtub", "tub"], .bathtub),
            (["kitchen bench", "benchtop", "counter"], .kitchenBench),
            (["island", "kitchen island"], .kitchenIsland),
            (["pantry"], .pantry),
            (["wardrobe", "robe", "bir", "built in robe", "built-in robe"], .wardrobe),
            (["linen", "linen cupboard"], .linenCupboard),
            (["washing machine", "washer", "dryer"], .washerDryer),
            (["laundry tub"], .laundryTub),
            (["fridge", "refrigerator"], .refrigerator),
            (["stove", "cooktop"], .stove),
            (["oven"], .oven),
            (["dishwasher"], .dishwasher),
            (["sink"], .sink),
            (["air con", "aircon", "split system", "ac", "a/c"], .splitSystemAC),
            (["ceiling fan", "fan"], .ceilingFan),
            (["fireplace", "fire place"], .fireplace),
            (["bbq", "barbecue", "barbeque"], .barbecue),
            (["pool", "swimming pool"], .pool),
            (["spa"], .spa),
            (["hot water", "hwu"], .hotWaterUnit),
        ]

        for entry in mapping {
            for keyword in entry.keywords {
                if lower.contains(keyword) {
                    return entry.category
                }
            }
        }

        return nil
    }
}
