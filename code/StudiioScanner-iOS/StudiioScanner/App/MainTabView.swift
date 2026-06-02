import SwiftUI

/// Root tab view — sci-fi dark navigation with glowing scan button.
struct MainTabView: View {
    @StateObject private var projectStore = ProjectStore()
    @StateObject private var syncManager = SyncManager()
    @State private var selectedTab: Tab = .home
    @State private var showingScanner = false
    @State private var scanPulse: CGFloat = 0

    enum Tab: String {
        case home
        case scan
        case settings
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch selectedTab {
                case .home:
                    HomeView(
                        projectStore: projectStore,
                        syncManager: syncManager,
                        showingScanner: $showingScanner
                    )
                case .scan:
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
        .onAppear {
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                scanPulse = 1
            }
        }
    }

    // MARK: - Custom Tab Bar

    private var customTabBar: some View {
        HStack(spacing: 0) {
            tabButton(icon: "house.fill", label: "Home", tab: .home)
            scanButton
            tabButton(icon: "gearshape.fill", label: "Settings", tab: .settings)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(
            ZStack {
                StudiioTheme.backgroundSecondary

                // Top glow line
                VStack {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.clear,
                                    StudiioTheme.accentOrange.opacity(0.12),
                                    Color.clear
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 1)
                        .shadow(color: StudiioTheme.accentOrange.opacity(0.2), radius: 4, y: -2)

                    Spacer()
                }
            }
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
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.5)
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
                // Outer glow ring
                Circle()
                    .fill(StudiioTheme.accentOrange.opacity(0.08))
                    .frame(width: 72, height: 72)
                    .scaleEffect(0.9 + 0.1 * scanPulse)

                // Glow shadow
                Circle()
                    .fill(StudiioTheme.accentOrange.opacity(0.15))
                    .frame(width: 58, height: 58)
                    .blur(radius: 8)

                // Main button
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [StudiioTheme.accentOrange, StudiioTheme.accentEmber],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 56, height: 56)
                    .overlay(
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.3), Color.clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.5
                            )
                    )
                    .shadow(color: StudiioTheme.accentOrange.opacity(0.5), radius: 12, y: 2)

                Image(systemName: "viewfinder")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .offset(y: -16)
        .frame(maxWidth: .infinity)
    }
}
