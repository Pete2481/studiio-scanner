import SwiftUI

/// Root tab view — the main navigation structure of the app.
struct MainTabView: View {
    @StateObject private var projectStore = ProjectStore()
    @StateObject private var syncManager = SyncManager()
    @State private var selectedTab: Tab = .home
    @State private var showingScanner = false

    enum Tab: String {
        case home
        case scan
        case settings
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Tab content
            Group {
                switch selectedTab {
                case .home:
                    HomeView(
                        projectStore: projectStore,
                        syncManager: syncManager,
                        showingScanner: $showingScanner
                    )
                case .scan:
                    // Scan tab just triggers the scanner
                    Color.clear.onAppear {
                        showingScanner = true
                        selectedTab = .home
                    }
                case .settings:
                    NavigationStack {
                        SyncSettingsView(syncManager: syncManager)
                    }
                }
            }

            // Custom tab bar
            customTabBar
        }
        .ignoresSafeArea(.keyboard)
        .fullScreenCover(isPresented: $showingScanner) {
            ScanView(projectStore: projectStore, isPresented: $showingScanner)
        }
        .onChange(of: showingScanner) { _, isShowing in
            if !isShowing {
                projectStore.loadProjects()
            }
        }
    }

    // MARK: - Custom Tab Bar

    private var customTabBar: some View {
        HStack(spacing: 0) {
            // Home tab
            tabButton(
                icon: "house.fill",
                label: "Home",
                tab: .home
            )

            // Scan button (center, prominent)
            scanButton

            // Settings tab
            tabButton(
                icon: "gearshape.fill",
                label: "Settings",
                tab: .settings
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(
            StudiioTheme.backgroundSecondary
                .overlay(
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [StudiioTheme.accentOrange.opacity(0.08), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(height: 1),
                    alignment: .top
                )
        )
    }

    private func tabButton(icon: String, label: String, tab: Tab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(selectedTab == tab ? StudiioTheme.accentOrange : StudiioTheme.textTertiary)
            .frame(maxWidth: .infinity)
        }
    }

    private var scanButton: some View {
        Button {
            showingScanner = true
        } label: {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [StudiioTheme.accentOrange, StudiioTheme.accentOrangeDark],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 56, height: 56)
                    .shadow(color: StudiioTheme.accentOrange.opacity(0.4), radius: 8, y: 2)

                Image(systemName: "viewfinder")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .offset(y: -16)
        .frame(maxWidth: .infinity)
    }
}
