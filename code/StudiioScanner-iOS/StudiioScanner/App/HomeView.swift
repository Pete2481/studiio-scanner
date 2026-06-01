import SwiftUI

/// The main home screen — edgy dark design with scan cards and branding.
struct HomeView: View {
    @ObservedObject var projectStore: ProjectStore
    @ObservedObject var syncManager: SyncManager
    @Binding var showingScanner: Bool
    @State private var projectToDelete: PropertyProject?

    var body: some View {
        NavigationStack {
            ZStack {
                // Background gradient
                backgroundGradient
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // Header
                    headerView

                    if projectStore.projects.isEmpty {
                        emptyStateView
                    } else {
                        scanListView
                    }
                }
            }
            .onAppear {
                projectStore.loadProjects()
                syncManager.checkiCloudAvailability()
            }
        }
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        ZStack {
            StudiioTheme.backgroundPrimary

            // Subtle radial glow from top-left
            RadialGradient(
                colors: [
                    StudiioTheme.accentOrange.opacity(0.06),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 0,
                endRadius: 500
            )
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    // Studiio wordmark
                    HStack(spacing: 6) {
                        // Geometric logo mark
                        ZStack {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(
                                    LinearGradient(
                                        colors: [StudiioTheme.accentOrange, StudiioTheme.accentOrangeDark],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 28, height: 28)

                            Image(systemName: "cube.transparent")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                        }

                        Text("STUDIIO")
                            .font(.system(size: 22, weight: .black, design: .default))
                            .tracking(3)
                            .foregroundColor(.white)
                    }

                    Text("SCANNER")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(6)
                        .foregroundColor(StudiioTheme.textTertiary)
                        .padding(.leading, 34)
                }

                Spacer()

                // Stats pill
                if !projectStore.projects.isEmpty {
                    HStack(spacing: 8) {
                        statChip(
                            value: "\(projectStore.projects.count)",
                            label: "SCANS"
                        )
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 16)

            // Accent line
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            StudiioTheme.accentOrange,
                            StudiioTheme.accentOrange.opacity(0.3),
                            Color.clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
        }
    }

    private func statChip(value: String, label: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(StudiioTheme.accentOrange)
            Text(label)
                .font(.system(size: 7, weight: .semibold))
                .tracking(1)
                .foregroundColor(StudiioTheme.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(StudiioTheme.backgroundElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(StudiioTheme.accentOrange.opacity(0.2), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Spacer()

            // Animated-looking grid
            ZStack {
                // Grid lines
                ForEach(0..<5, id: \.self) { i in
                    Rectangle()
                        .fill(StudiioTheme.accentOrange.opacity(0.08))
                        .frame(height: 0.5)
                        .offset(y: CGFloat(i - 2) * 24)
                }
                ForEach(0..<5, id: \.self) { i in
                    Rectangle()
                        .fill(StudiioTheme.accentOrange.opacity(0.08))
                        .frame(width: 0.5)
                        .offset(x: CGFloat(i - 2) * 24)
                }

                // Center icon
                Image(systemName: "viewfinder")
                    .font(.system(size: 56, weight: .thin))
                    .foregroundColor(StudiioTheme.accentOrange.opacity(0.4))
            }
            .frame(width: 120, height: 120)

            VStack(spacing: 8) {
                Text("NO SCANS YET")
                    .font(.system(size: 16, weight: .bold))
                    .tracking(2)
                    .foregroundColor(StudiioTheme.textPrimary)

                Text("Scan your first property to get started")
                    .font(.system(size: 14))
                    .foregroundColor(StudiioTheme.textTertiary)
            }

            Button {
                showingScanner = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 16, weight: .semibold))
                    Text("START SCANNING")
                        .font(.system(size: 14, weight: .bold))
                        .tracking(1)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [StudiioTheme.accentOrange, StudiioTheme.accentOrangeDark],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .shadow(color: StudiioTheme.accentOrange.opacity(0.3), radius: 12, y: 4)
                )
            }

            Spacer()
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Scan List

    private var scanListView: some View {
        VStack(spacing: 0) {
            // Section header
            HStack {
                Text("YOUR SCANS")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(2)
                    .foregroundColor(StudiioTheme.textTertiary)

                Spacer()

                Text("\(projectStore.projects.count) total")
                    .font(.system(size: 11))
                    .foregroundColor(StudiioTheme.textTertiary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            // Scan cards in List for swipe-to-delete
            List {
                ForEach(projectStore.projects) { project in
                    NavigationLink {
                        ProjectDetailView(
                            project: project,
                            projectStore: projectStore,
                            syncManager: syncManager
                        )
                    } label: {
                        ScanCard(project: project, projectStore: projectStore)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            projectToDelete = project
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .alert("Delete Scan?", isPresented: .init(
                get: { projectToDelete != nil },
                set: { if !$0 { projectToDelete = nil } }
            )) {
                Button("Delete", role: .destructive) {
                    if let project = projectToDelete {
                        try? projectStore.deleteProject(project)
                    }
                    projectToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    projectToDelete = nil
                }
            } message: {
                Text("This will permanently delete this scan and all its data.")
            }
        }
    }
}

// MARK: - Scan Card

struct ScanCard: View {
    let project: PropertyProject
    let projectStore: ProjectStore

    private var roomCount: Int {
        project.floors.flatMap(\.rooms).count
    }

    private var totalArea: Double {
        project.floors.flatMap(\.rooms).reduce(0) { $0 + $1.area }
    }

    private var relativeDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: project.capturedAt, relativeTo: Date())
    }

    private var heroImage: UIImage? {
        guard let url = projectStore.heroImageURL(for: project),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        HStack(spacing: 14) {
            // Property photo or placeholder
            thumbnailView

            // Info
            VStack(alignment: .leading, spacing: 6) {
                // Address
                Text(project.address ?? "Untitled Property")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(StudiioTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                // Date
                Text(relativeDate)
                    .font(.system(size: 12))
                    .foregroundColor(StudiioTheme.textTertiary)

                // Stats row
                HStack(spacing: 12) {
                    scanStat(icon: "square.split.2x2", value: "\(roomCount) rooms")
                    scanStat(icon: "arrow.up.arrow.down", value: "\(project.floors.count) floor\(project.floors.count == 1 ? "" : "s")")
                    if totalArea > 0 {
                        scanStat(icon: "ruler", value: String(format: "%.0f m\u{00B2}", totalArea))
                    }
                }

                // Status badge
                statusBadge
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(StudiioTheme.backgroundCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    StudiioTheme.accentOrange.opacity(0.15),
                                    StudiioTheme.backgroundElevated.opacity(0.3)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                )
        )
    }

    // MARK: - Thumbnail

    private var thumbnailView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(StudiioTheme.backgroundElevated)

            if let heroImage {
                Image(uiImage: heroImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "square.split.bottomrightquarter")
                    .font(.system(size: 28))
                    .foregroundColor(StudiioTheme.accentOrange.opacity(0.4))
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Helpers

    private func scanStat(icon: String, value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundColor(StudiioTheme.accentOrange.opacity(0.7))
            Text(value)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(StudiioTheme.textSecondary)
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(StudiioTheme.success)
                .frame(width: 5, height: 5)
            Text("Ready to export")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(StudiioTheme.success)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(StudiioTheme.success.opacity(0.12))
        )
    }
}
