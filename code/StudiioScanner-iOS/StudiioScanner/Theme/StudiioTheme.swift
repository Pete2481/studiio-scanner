import SwiftUI

enum StudiioTheme {
    // MARK: - Backgrounds
    static let backgroundPrimary = Color(hex: "050506")
    static let backgroundSecondary = Color(hex: "0F0F11")
    static let backgroundCard = Color(hex: "141416")
    static let backgroundElevated = Color(hex: "1C1C1F")

    // MARK: - Glass
    static let glassStroke = Color.white.opacity(0.06)
    static let glassFill = Color(hex: "1A1A1E").opacity(0.7)
    static let glassHighlight = Color.white.opacity(0.03)

    // MARK: - Accent
    static let accentOrange = Color(hex: "FF8C00")
    static let accentOrangeLight = Color(hex: "FFB347")
    static let accentOrangeDark = Color(hex: "CC7000")
    static let accentAmber = Color(hex: "FF9F1C")
    static let accentEmber = Color(hex: "E8601C")

    // MARK: - Text
    static let textPrimary = Color.white
    static let textSecondary = Color(hex: "9A9AA0")
    static let textTertiary = Color(hex: "56565C")

    // MARK: - Semantic
    static let scanning = accentOrange
    static let scanMeshFill = accentOrange.opacity(0.45)
    static let scanMeshWireframe = Color.white.opacity(0.6)
    static let destructive = Color(hex: "FF3B30")
    static let success = Color(hex: "34C759")

    // MARK: - Bathroom fill (for blueprint — kept here for shared reference)
    static let bathroomFill = Color(hex: "D6EAF8")

    // MARK: - Corner Radius
    static let cornerRadiusSmall: CGFloat = 8
    static let cornerRadiusMedium: CGFloat = 14
    static let cornerRadiusLarge: CGFloat = 20
    static let cornerRadiusPill: CGFloat = 28

    // MARK: - Spacing
    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 16
    static let spacingL: CGFloat = 24
    static let spacingXL: CGFloat = 32
}

// MARK: - Hex Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
