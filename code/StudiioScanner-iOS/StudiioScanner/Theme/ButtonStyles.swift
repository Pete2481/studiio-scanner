import SwiftUI

struct StudiioPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold))
            .tracking(0.5)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: StudiioTheme.cornerRadiusPill)
                        .fill(
                            LinearGradient(
                                colors: [StudiioTheme.accentOrange, StudiioTheme.accentEmber],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    // Inner glow at top
                    RoundedRectangle(cornerRadius: StudiioTheme.cornerRadiusPill)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.15), Color.clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                }
            )
            .shadow(color: StudiioTheme.accentOrange.opacity(0.35), radius: 16, y: 6)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct StudiioSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold))
            .tracking(0.5)
            .foregroundColor(StudiioTheme.accentOrange)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: StudiioTheme.cornerRadiusPill)
                        .fill(StudiioTheme.accentOrange.opacity(0.08))

                    RoundedRectangle(cornerRadius: StudiioTheme.cornerRadiusPill)
                        .stroke(StudiioTheme.accentOrange.opacity(0.3), lineWidth: 1)
                }
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Glass Card Modifier

struct StudiioCardStyle: ViewModifier {
    var glowColor: Color = StudiioTheme.accentOrange
    var glowIntensity: Double = 0.0

    func body(content: Content) -> some View {
        content
            .padding(StudiioTheme.spacingM)
            .background(
                ZStack {
                    // Base fill
                    RoundedRectangle(cornerRadius: StudiioTheme.cornerRadiusMedium)
                        .fill(StudiioTheme.glassFill)

                    // Top highlight edge
                    RoundedRectangle(cornerRadius: StudiioTheme.cornerRadiusMedium)
                        .fill(
                            LinearGradient(
                                colors: [StudiioTheme.glassHighlight, Color.clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )

                    // Border
                    RoundedRectangle(cornerRadius: StudiioTheme.cornerRadiusMedium)
                        .stroke(StudiioTheme.glassStroke, lineWidth: 0.5)
                }
            )
            .shadow(color: glowColor.opacity(glowIntensity), radius: 20, y: 4)
    }
}

extension View {
    func studiioCard() -> some View {
        modifier(StudiioCardStyle())
    }

    func studiioCard(glow: Color, intensity: Double = 0.15) -> some View {
        modifier(StudiioCardStyle(glowColor: glow, glowIntensity: intensity))
    }
}

extension ButtonStyle where Self == StudiioPrimaryButtonStyle {
    static var studiioPrimary: StudiioPrimaryButtonStyle { StudiioPrimaryButtonStyle() }
}

extension ButtonStyle where Self == StudiioSecondaryButtonStyle {
    static var studiioSecondary: StudiioSecondaryButtonStyle { StudiioSecondaryButtonStyle() }
}
