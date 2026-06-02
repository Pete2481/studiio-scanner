import SwiftUI

/// The main home screen — sci-fi dark UI with ambient orange glow, glass cards.
struct HomeView: View {
    @ObservedObject var projectStore: ProjectStore
    @ObservedObject var syncManager: SyncManager
    @Binding var showingScanner: Bool
    @State private var projectToDelete: PropertyProject?
    @State private var pulsePhase: CGFloat = 0

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundLayer
                    .ignoresSafeArea()

                VStack(spacing: 0) {
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
                withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) {
                    pulsePhase = 1
                }
            }
        }
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        ZStack {
            StudiioTheme.backgroundPrimary

            // Deep ambient glow — top center
            RadialGradient(
                colors: [
                    StudiioTheme.accentOrange.opacity(0.07),
                    StudiioTheme.accentEmber.opacity(0.03),
                    Color.clear
                ],
                center: .top,
                startRadius: 0,
                endRadius: 600
            )

            // Subtle secondary glow — bottom right
            RadialGradient(
                colors: [
                    StudiioTheme.accentOrange.opacity(0.04),
                    Color.clear
                ],
                center: UnitPoint(x: 0.8, y: 0.9),
                startRadius: 0,
                endRadius: 400
            )
            .opacity(0.6 + 0.4 * pulsePhase)
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        // Logo mark with glow
                        ZStack {
                            // Outer glow
                            Circle()
                                .fill(StudiioTheme.accentOrange.opacity(0.15))
                                .frame(width: 40, height: 40)
                                .blur(radius: 8)

                            RoundedRectangle(cornerRadius: 8)
                                .fill(
                                    LinearGradient(
                                        colors: [StudiioTheme.accentOrange, StudiioTheme.accentEmber],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 32, height: 32)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                                )

                            Image(systemName: "cube.transparent")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                        }

                        VStack(alignment: .leading, spacing: 1) {
                            Text("STUDIIO")
                                .font(.system(size: 22, weight: .black, design: .default))
                                .tracking(4)
                                .foregroundColor(.white)

                            Text("SCANNER")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(6)
                                .foregroundColor(StudiioTheme.accentOrange.opacity(0.6))
                        }
                    }
                }

                Spacer()

                if !projectStore.projects.isEmpty {
                    statChip(
                        value: "\(projectStore.projects.count)",
                        label: "SCANS"
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 16)

            // Glowing accent line
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            StudiioTheme.accentOrange.opacity(0.6),
                            StudiioTheme.accentOrange.opacity(0.15),
                            Color.clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
                .shadow(color: StudiioTheme.accentOrange.opacity(0.3), radius: 4, y: 0)
        }
    }

    private func statChip(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundColor(StudiioTheme.accentOrange)
            Text(label)
                .font(.system(size: 7, weight: .bold))
                .tracking(1.5)
                .foregroundColor(StudiioTheme.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(StudiioTheme.glassFill)
                RoundedRectangle(cornerRadius: 10)
                    .stroke(StudiioTheme.accentOrange.opacity(0.15), lineWidth: 0.5)
            }
        )
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 28) {
            Spacer()

            // Animated scanner ring
            ZStack {
                // Outer ring glow
                Circle()
                    .stroke(StudiioTheme.accentOrange.opacity(0.1), lineWidth: 1)
                    .frame(width: 140, height: 140)

                Circle()
                    .stroke(StudiioTheme.accentOrange.opacity(0.06), lineWidth: 1)
                    .frame(width: 180, height: 180)

                // Ambient glow behind icon
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                StudiioTheme.accentOrange.opacity(0.12),
                                StudiioTheme.accentOrange.opacity(0.03),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 70
                        )
                    )
                    .frame(width: 140, height: 140)
                    .opacity(0.7 + 0.3 * pulsePhase)

                // Grid lines
                ForEach(0..<5, id: \.self) { i in
                    Rectangle()
                        .fill(StudiioTheme.accentOrange.opacity(0.06))
                        .frame(height: 0.5)
                        .offset(y: CGFloat(i - 2) * 28)
                }
                .frame(width: 120)

                ForEach(0..<5, id: \.self) { i in
                    Rectangle()
                        .fill(StudiioTheme.accentOrange.opacity(0.06))
                        .frame(width: 0.5)
                        .offset(x: CGFloat(i - 2) * 28)
                }
                .frame(height: 120)

                Image(systemName: "viewfinder")
                    .font(.system(size: 52, weight: .ultraLight))
                    .foregroundColor(StudiioTheme.accentOrange.opacity(0.5))
            }

            VStack(spacing: 10) {
                Text("NO SCANS YET")
                    .font(.system(size: 18, weight: .bold))
                    .tracking(3)
                    .foregroundColor(StudiioTheme.textPrimary)

                Text("Scan your first property to get started")
                    .font(.system(size: 14))
                    .foregroundColor(StudiioTheme.textTertiary)
            }

            Button {
                showingScanner = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 16, weight: .semibold))
                    Text("START SCANNING")
                        .font(.system(size: 14, weight: .bold))
                        .tracking(1.5)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 36)
                .padding(.vertical, 16)
                .background(
                    ZStack {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [StudiioTheme.accentOrange, StudiioTheme.accentEmber],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )

                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.15), Color.clear],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                    }
                    .shadow(color: StudiioTheme.accentOrange.opacity(0.4), radius: 20, y: 6)
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
            HStack {
                Text("YOUR SCANS")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(2)
                    .foregroundColor(StudiioTheme.textTertiary)

                Spacer()

                Text("\(projectStore.projects.count) total")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(StudiioTheme.textTertiary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

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
            thumbnailView
            infoView
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(StudiioTheme.glassFill)

                // Subtle warm glow from left edge
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            colors: [
                                StudiioTheme.accentOrange.opacity(0.04),
                                Color.clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                // Top highlight
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            colors: [StudiioTheme.glassHighlight, Color.clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )

                RoundedRectangle(cornerRadius: 16)
                    .stroke(StudiioTheme.glassStroke, lineWidth: 0.5)
            }
        )
    }

    private var infoView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(project.address ?? "Untitled Property")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(StudiioTheme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Text(relativeDate)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(StudiioTheme.textTertiary)

            HStack(spacing: 12) {
                scanStat(icon: "square.split.2x2", value: "\(roomCount) rooms")
                scanStat(icon: "arrow.up.arrow.down", value: "\(project.floors.count) floor\(project.floors.count == 1 ? "" : "s")")
                if totalArea > 0 {
                    scanStat(icon: "ruler", value: String(format: "%.0f m\u{00B2}", totalArea))
                }
            }

            statusBadge
        }
    }

    // MARK: - Thumbnail

    private var thumbnailView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(StudiioTheme.backgroundElevated)

            if let heroImage {
                Image(uiImage: heroImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    // Ambient glow behind icon
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    StudiioTheme.accentOrange.opacity(0.15),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: 30
                            )
                        )
                        .frame(width: 50, height: 50)

                    Image(systemName: "square.split.bottomrightquarter")
                        .font(.system(size: 26))
                        .foregroundColor(StudiioTheme.accentOrange.opacity(0.5))
                }
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(StudiioTheme.glassStroke, lineWidth: 0.5)
        )
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
                .shadow(color: StudiioTheme.success.opacity(0.5), radius: 3)
            Text("Ready to export")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(StudiioTheme.success)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(StudiioTheme.success.opacity(0.08))
                .overlay(
                    Capsule()
                        .stroke(StudiioTheme.success.opacity(0.15), lineWidth: 0.5)
                )
        )
    }
}
