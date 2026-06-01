import Testing
import Foundation
@testable import StudiioScanner

@Suite("Object Tagging Tests")
struct TaggingTests {

    @Test("All ObjectCategory cases have a display name")
    func testAllCategoriesHaveDisplayNames() {
        for category in ObjectCategory.allCases {
            #expect(!category.displayName.isEmpty, "Missing display name for \(category)")
        }
    }

    @Test("All ObjectCategory cases have an abbreviation")
    func testAllCategoriesHaveAbbreviations() {
        for category in ObjectCategory.allCases {
            #expect(!category.abbreviation.isEmpty, "Missing abbreviation for \(category)")
        }
    }

    @Test("Voice matching finds shower from transcript")
    func testVoiceMatchShower() {
        let result = VoiceTaggingEngine.matchCategory(from: "this is a shower")
        #expect(result == .shower)
    }

    @Test("Voice matching finds BBQ from transcript")
    func testVoiceMatchBBQ() {
        let result = VoiceTaggingEngine.matchCategory(from: "there's a barbecue here")
        #expect(result == .barbecue)
    }

    @Test("Voice matching finds air con from transcript")
    func testVoiceMatchAC() {
        let result = VoiceTaggingEngine.matchCategory(from: "split system on the wall")
        #expect(result == .splitSystemAC)
    }

    @Test("Voice matching finds wardrobe from 'built in robe'")
    func testVoiceMatchWardrobe() {
        let result = VoiceTaggingEngine.matchCategory(from: "built in robe")
        #expect(result == .wardrobe)
    }

    @Test("Voice matching returns nil for unrecognized text")
    func testVoiceMatchUnknown() {
        let result = VoiceTaggingEngine.matchCategory(from: "hello world")
        #expect(result == nil)
    }

    @Test("Voice tagging is disabled in v1")
    func testVoiceTaggingDisabled() {
        #expect(VoiceTaggingEngine.isEnabled == false)
    }

    @Test("AI detector is disabled in v1")
    func testAIDetectorDisabled() {
        #expect(StubObjectDetector.isEnabled == false)
    }

    @Test("Category picker sections cover all categories")
    func testAllCategoriesCovered() {
        // The sections defined in CategoryPickerView should cover all categories
        let sectionCategories: [ObjectCategory] = [
            // Bathroom
            .shower, .vanity, .toilet, .bathtub, .sink,
            // Kitchen
            .kitchenBench, .kitchenIsland, .pantry, .stove, .oven, .refrigerator, .dishwasher, .rangehood,
            // Bedroom
            .wardrobe, .bed, .linenCupboard,
            // Laundry
            .washerDryer, .laundryTub,
            // Living
            .sofa, .chair, .table, .television, .fireplace,
            // Climate
            .splitSystemAC, .ceilingFan,
            // Fixtures
            .pendant, .downlight, .powerPoint, .lightSwitch, .smokeAlarm, .intercom,
            // Outdoor
            .barbecue, .pool, .spa, .clothesLine, .letterbox,
            // Other
            .storage, .stairs, .hotWaterUnit, .solarPanel, .skylight, .nicheShelf, .wallTV, .custom
        ]

        let allCategories = Set(ObjectCategory.allCases)
        let coveredCategories = Set(sectionCategories)

        let missing = allCategories.subtracting(coveredCategories)
        #expect(missing.isEmpty, "Categories not in picker sections: \(missing)")
    }

    @Test("TaggedObject source tracks manual tap correctly")
    func testTagSource() {
        let tag = TaggedObject(
            id: UUID(),
            category: .shower,
            positionX: 1.0, positionY: 1.5, positionZ: 2.0,
            dimensionsX: 0.9, dimensionsY: 2.1, dimensionsZ: 0.9,
            source: .manualTap
        )
        #expect(tag.source == .manualTap)
    }
}
