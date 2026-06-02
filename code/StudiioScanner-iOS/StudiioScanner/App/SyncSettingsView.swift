import SwiftUI

/// Settings view — sci-fi glass card aesthetic
struct SyncSettingsView: View {
    @ObservedObject var syncManager: SyncManager

    var body: some View {
        ZStack {
            ZStack {
                StudiioTheme.backgroundPrimary
                RadialGradient(
                    colors: [StudiioTheme.accentOrange.opacity(0.04), Color.clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: 400
                )
            }
            .ignoresSafeArea()

            List {
                Section {
                    ForEach(SyncManager.SyncMode.allCases, id: \.self) { mode in
                        Button {
                            syncManager.preferredMode = mode
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(StudiioTheme.accentOrange.opacity(syncManager.preferredMode == mode ? 0.15 : 0.06))
                                        .frame(width: 34, height: 34)
                                    Image(systemName: iconForMode(mode))
                                        .font(.system(size: 14))
                                        .foregroundColor(syncManager.preferredMode == mode ? StudiioTheme.accentOrange : StudiioTheme.textTertiary)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mode.rawValue)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(StudiioTheme.textPrimary)
                                    Text(descriptionForMode(mode))
                                        .font(.system(size: 11))
                                        .foregroundColor(StudiioTheme.textTertiary)
                                }

                                Spacer()

                                if syncManager.preferredMode == mode {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(StudiioTheme.accentOrange)
                                        .font(.system(size: 18))
                                }

                                statusBadge(for: mode)
                            }
                        }
                        .listRowBackground(StudiioTheme.glassFill)
                    }
                } header: {
                    Text("PREFERRED SYNC MODE")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(2)
                        .foregroundColor(StudiioTheme.accentOrange.opacity(0.7))
                }

                Section {
                    statusRow(label: "iCloud Drive", available: syncManager.iCloudAvailable, detail: syncManager.iCloudAvailable ? "Available" : "Unavailable")
                    statusRow(label: "Mac on WiFi", available: syncManager.localMacDiscovered, detail: syncManager.localMacDiscovered ? "Found" : "Searching...")
                } header: {
                    Text("STATUS")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(2)
                        .foregroundColor(StudiioTheme.accentOrange.opacity(0.7))
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Sync Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            syncManager.checkiCloudAvailability()
            syncManager.startBrowsingForMac()
        }
        .onDisappear {
            syncManager.stopBrowsing()
        }
    }

    private func statusRow(label: String, available: Bool, detail: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(StudiioTheme.textPrimary)
            Spacer()
            HStack(spacing: 5) {
                Circle()
                    .fill(available ? StudiioTheme.success : StudiioTheme.textTertiary)
                    .frame(width: 6, height: 6)
                    .shadow(color: available ? StudiioTheme.success.opacity(0.5) : Color.clear, radius: 3)
                Text(detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(available ? StudiioTheme.success : StudiioTheme.textTertiary)
            }
        }
        .listRowBackground(StudiioTheme.glassFill)
    }

    private func iconForMode(_ mode: SyncManager.SyncMode) -> String {
        switch mode {
        case .iCloud: return "icloud"
        case .airDrop: return "airplayaudio"
        case .localWiFi: return "wifi"
        case .askEachTime: return "questionmark.circle"
        }
    }

    private func descriptionForMode(_ mode: SyncManager.SyncMode) -> String {
        switch mode {
        case .iCloud: return "Automatic via iCloud Drive"
        case .airDrop: return "Share sheet with nearby devices"
        case .localWiFi: return "Direct transfer to Mac on same network"
        case .askEachTime: return "Choose each time you export"
        }
    }

    @ViewBuilder
    private func statusBadge(for mode: SyncManager.SyncMode) -> some View {
        switch mode {
        case .iCloud:
            if !syncManager.iCloudAvailable {
                Text("N/A")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(StudiioTheme.textTertiary)
            }
        case .localWiFi:
            if !syncManager.localMacDiscovered {
                Text("No Mac")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(StudiioTheme.textTertiary)
            }
        default:
            EmptyView()
        }
    }
}
