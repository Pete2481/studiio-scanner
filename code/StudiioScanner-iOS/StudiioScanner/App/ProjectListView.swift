import SwiftUI

struct ProjectListView: View {
    @StateObject private var projectStore = ProjectStore()
    @StateObject private var syncManager = SyncManager()
    @State private var showingScanner = false

    var body: some View {
        NavigationStack {
            ZStack {
                StudiioTheme.backgroundPrimary
                    .ignoresSafeArea()

                if projectStore.projects.isEmpty {
                    emptyStateView
                } else {
                    projectGrid
                }
            }
            .navigationTitle("Studiio Scanner")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        SyncSettingsView(syncManager: syncManager)
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundColor(StudiioTheme.textSecondary)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingScanner = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.title3.weight(.semibold))
                            .foregroundColor(StudiioTheme.accentOrange)
                    }
                }
            }
            .fullScreenCover(isPresented: $showingScanner) {
                ScanView(projectStore: projectStore, isPresented: $showingScanner)
            }
            .onAppear {
                projectStore.loadProjects()
                syncManager.checkiCloudAvailability()
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: StudiioTheme.spacingL) {
            Image(systemName: "building.2")
                .font(.system(size: 64))
                .foregroundColor(StudiioTheme.textTertiary)

            Text("No Scans Yet")
                .font(.title2.weight(.semibold))
                .foregroundColor(StudiioTheme.textPrimary)

            Text("Tap + to scan your first property")
                .font(.body)
                .foregroundColor(StudiioTheme.textSecondary)

            Button("Start Scanning") {
                showingScanner = true
            }
            .buttonStyle(.studiioPrimary)
            .frame(maxWidth: 280)
        }
        .padding()
    }

    private var projectGrid: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: StudiioTheme.spacingM),
                GridItem(.flexible(), spacing: StudiioTheme.spacingM)
            ], spacing: StudiioTheme.spacingM) {
                ForEach(projectStore.projects) { project in
                    NavigationLink {
                        ProjectDetailView(
                            project: project,
                            projectStore: projectStore,
                            syncManager: syncManager
                        )
                    } label: {
                        ProjectTileView(project: project, projectStore: projectStore)
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            try? projectStore.deleteProject(project)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(StudiioTheme.spacingM)
        }
    }
}

// MARK: - Project Tile

struct ProjectTileView: View {
    let project: PropertyProject
    let projectStore: ProjectStore

    private var heroImage: UIImage? {
        guard let url = projectStore.heroImageURL(for: project),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudiioTheme.spacingS) {
            RoundedRectangle(cornerRadius: StudiioTheme.cornerRadiusSmall)
                .fill(StudiioTheme.backgroundElevated)
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay(
                    Group {
                        if let heroImage {
                            Image(uiImage: heroImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "building.2")
                                .font(.title)
                                .foregroundColor(StudiioTheme.textTertiary)
                        }
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: StudiioTheme.cornerRadiusSmall))

            Text(project.address ?? "Untitled Property")
                .font(.subheadline.weight(.medium))
                .foregroundColor(StudiioTheme.textPrimary)
                .lineLimit(1)

            HStack {
                Text(project.capturedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundColor(StudiioTheme.textSecondary)

                Spacer()

                let roomCount = project.floors.flatMap(\.rooms).count
                Text("\(roomCount) room\(roomCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(StudiioTheme.accentOrange)
            }
        }
        .studiioCard()
    }
}

#Preview {
    ProjectListView()
        .preferredColorScheme(.dark)
}
