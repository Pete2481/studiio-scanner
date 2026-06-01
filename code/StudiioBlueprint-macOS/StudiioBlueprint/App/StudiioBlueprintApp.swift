import SwiftUI

@main
struct StudiioBlueprintApp: App {
    var body: some Scene {
        WindowGroup {
            BlueprintMainView()
                .preferredColorScheme(.dark)
                .frame(minWidth: 1200, minHeight: 800)
        }
        .windowStyle(.titleBar)
    }
}
