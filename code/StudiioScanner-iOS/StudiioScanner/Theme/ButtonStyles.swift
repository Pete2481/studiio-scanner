import SwiftUI

struct StudiioPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: StudiioTheme.cornerRadiusPill)
                    .fill(StudiioTheme.accentOrange)
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct StudiioSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(StudiioTheme.accentOrange)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: StudiioTheme.cornerRadiusPill)
                    .stroke(StudiioTheme.accentOrange, lineWidth: 1.5)
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct StudiioCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(StudiioTheme.spacingM)
            .background(
                RoundedRectangle(cornerRadius: StudiioTheme.cornerRadiusMedium)
                    .fill(StudiioTheme.backgroundCard)
            )
    }
}

extension View {
    func studiioCard() -> some View {
        modifier(StudiioCardStyle())
    }
}

extension ButtonStyle where Self == StudiioPrimaryButtonStyle {
    static var studiioPrimary: StudiioPrimaryButtonStyle { StudiioPrimaryButtonStyle() }
}

extension ButtonStyle where Self == StudiioSecondaryButtonStyle {
    static var studiioSecondary: StudiioSecondaryButtonStyle { StudiioSecondaryButtonStyle() }
}
