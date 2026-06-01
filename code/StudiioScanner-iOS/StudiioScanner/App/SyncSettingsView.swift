import SwiftUI

/// Settings view for configuring sync mode preference
struct SyncSettingsView: View {
    @ObservedObject var syncManager: SyncManager

    var body: some View {
        List {
            Section("Preferred Sync Mode") {
                ForEach(SyncManager.SyncMode.allCases, id: \.self) { mode in
                    Button {
                        syncManager.preferredMode = mode
                    } label: {
                        HStack {
                            Image(systemName: iconForMode(mode))
                                .foregroundColor(StudiioTheme.accentOrange)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.rawValue)
                                    .foregroundColor(StudiioTheme.textPrimary)

                                Text(descriptionForMode(mode))
                                    .font(.caption)
                                    .foregroundColor(StudiioTheme.textTertiary)
                            }

                            Spacer()

                            if syncManager.preferredMode == mode {
                                Image(systemName: "checkmark")
                                    .foregroundColor(StudiioTheme.accentOrange)
                            }

                            statusBadge(for: mode)
                        }
                    }
                    .listRowBackground(StudiioTheme.backgroundCard)
                }
            }

            Section("Status") {
                HStack {
                    Text("iCloud Drive")
                        .foregroundColor(StudiioTheme.textPrimary)
                    Spacer()
                    Text(syncManager.iCloudAvailable ? "Available" : "Unavailable")
                        .font(.caption)
                        .foregroundColor(syncManager.iCloudAvailable ? StudiioTheme.success : StudiioTheme.textTertiary)
                }
                .listRowBackground(StudiioTheme.backgroundCard)

                HStack {
                    Text("Mac on WiFi")
                        .foregroundColor(StudiioTheme.textPrimary)
                    Spacer()
                    Text(syncManager.localMacDiscovered ? "Found" : "Searching...")
                        .font(.caption)
                        .foregroundColor(syncManager.localMacDiscovered ? StudiioTheme.success : StudiioTheme.textTertiary)
                }
                .listRowBackground(StudiioTheme.backgroundCard)
            }
        }
        .scrollContentBackground(.hidden)
        .background(StudiioTheme.backgroundPrimary)
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
                    .font(.caption2)
                    .foregroundColor(StudiioTheme.textTertiary)
            }
        case .localWiFi:
            if !syncManager.localMacDiscovered {
                Text("No Mac")
                    .font(.caption2)
                    .foregroundColor(StudiioTheme.textTertiary)
            }
        default:
            EmptyView()
        }
    }
}
