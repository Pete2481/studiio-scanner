import SwiftUI

/// Post-scan view for tagging outdoor zones with their type.
/// Appears when outdoor areas were detected during the scan.
struct OutdoorZoneTaggingView: View {
    @Binding var outdoorZones: [OutdoorZone]
    var onDone: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                StudiioTheme.backgroundPrimary
                    .ignoresSafeArea()

                if outdoorZones.isEmpty {
                    Text("No outdoor areas detected")
                        .foregroundColor(StudiioTheme.textSecondary)
                } else {
                    List {
                        ForEach($outdoorZones) { $zone in
                            OutdoorZoneRow(zone: $zone)
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Outdoor Areas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        onDone()
                    }
                    .foregroundColor(StudiioTheme.accentOrange)
                }
            }
        }
    }
}

struct OutdoorZoneRow: View {
    @Binding var zone: OutdoorZone

    var body: some View {
        VStack(alignment: .leading, spacing: StudiioTheme.spacingS) {
            TextField("Zone name", text: $zone.name)
                .font(.headline)
                .foregroundColor(StudiioTheme.textPrimary)

            // Type picker
            HStack {
                Text("Type:")
                    .font(.subheadline)
                    .foregroundColor(StudiioTheme.textSecondary)

                Picker("Type", selection: $zone.type) {
                    ForEach(OutdoorType.allCases, id: \.self) { type in
                        Text(type.displayName)
                            .tag(type)
                    }
                }
                .pickerStyle(.menu)
                .tint(StudiioTheme.accentOrange)
            }

            if zone.elevation != 0 {
                Text("Elevation: \(String(format: "%.1f", zone.elevation))m relative to ground")
                    .font(.caption)
                    .foregroundColor(StudiioTheme.textTertiary)
            }
        }
        .padding(.vertical, StudiioTheme.spacingXS)
        .listRowBackground(StudiioTheme.backgroundCard)
    }
}

// MARK: - Display Names

extension OutdoorType {
    var displayName: String {
        switch self {
        case .deck: return "Deck"
        case .balcony: return "Balcony"
        case .alfresco: return "Alfresco"
        case .verandah: return "Verandah"
        case .porch: return "Porch"
        case .patio: return "Patio"
        case .garden: return "Garden"
        case .driveway: return "Driveway"
        case .carport: return "Carport"
        case .other: return "Other"
        }
    }
}
