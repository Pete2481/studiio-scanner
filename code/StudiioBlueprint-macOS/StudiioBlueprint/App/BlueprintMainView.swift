import SwiftUI
import UniformTypeIdentifiers

struct BlueprintMainView: View {
    @StateObject private var importer = ProjectImporter()
    @StateObject private var icloudWatcher = iCloudWatcher()

    @State private var projects: [PropertyProject] = []
    @State private var selectedProjectID: UUID?
    @State private var showFileImporter = false
    @State private var importError: String?
    @State private var showPendingBanner = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let id = selectedProjectID, let project = projects.first(where: { $0.id == id }) {
                BlueprintProjectDetailView(project: project)
            } else {
                emptyState
            }
        }
        .background(StudiioTheme.backgroundPrimary)
        .onAppear {
            loadProjects()
            icloudWatcher.startWatching()
        }
        .onDisappear {
            icloudWatcher.stopWatching()
        }
        .onChange(of: icloudWatcher.pendingBundles) { _, pending in
            showPendingBanner = !pending.isEmpty
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.studiioBundle, .package, .folder],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .alert("Import Error", isPresented: .init(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // iCloud pending banner
            if showPendingBanner {
                pendingBanner
            }

            List(selection: $selectedProjectID) {
                Section {
                    if projects.isEmpty {
                        Text("No projects imported")
                            .foregroundColor(StudiioTheme.textTertiary)
                            .font(.subheadline)
                    } else {
                        ForEach(projects) { project in
                            SidebarProjectRow(project: project)
                                .tag(project.id)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        deleteProject(project)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                } header: {
                    HStack {
                        Text("PROJECTS")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(StudiioTheme.accentOrange)
                        Spacer()
                        Button {
                            showFileImporter = true
                        } label: {
                            Image(systemName: "plus")
                                .foregroundColor(StudiioTheme.accentOrange)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(StudiioTheme.backgroundSecondary)
        }
    }

    // MARK: - Pending Banner

    private var pendingBanner: some View {
        HStack {
            Image(systemName: "icloud.and.arrow.down")
                .foregroundColor(StudiioTheme.accentOrange)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(icloudWatcher.pendingBundles.count) scan\(icloudWatcher.pendingBundles.count == 1 ? "" : "s") waiting")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(StudiioTheme.textPrimary)

                Text("From iCloud Drive")
                    .font(.caption2)
                    .foregroundColor(StudiioTheme.textTertiary)
            }

            Spacer()

            Button("Import All") {
                importAllPending()
            }
            .font(.caption.weight(.semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(StudiioTheme.accentOrange))
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(StudiioTheme.backgroundElevated)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: StudiioTheme.spacingL) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 64))
                .foregroundColor(StudiioTheme.textTertiary)

            Text("No Project Selected")
                .font(.title2.weight(.semibold))
                .foregroundColor(StudiioTheme.textPrimary)

            Text("Import a .studiio scan from your iPhone\nor drop one here")
                .font(.body)
                .foregroundColor(StudiioTheme.textSecondary)
                .multilineTextAlignment(.center)

            Button("Import Project") {
                showFileImporter = true
            }
            .font(.headline)
            .foregroundColor(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: StudiioTheme.cornerRadiusPill)
                    .fill(StudiioTheme.accentOrange)
            )
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudiioTheme.backgroundPrimary)
    }

    // MARK: - Actions

    private func loadProjects() {
        projects = importer.loadAllProjects()
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let project = try importer.importProject(from: url)
                loadProjects()
                selectedProjectID = project.id
            } catch {
                importError = error.localizedDescription
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in
                do {
                    let project = try importer.importProject(from: url)
                    loadProjects()
                    selectedProjectID = project.id
                } catch {
                    importError = error.localizedDescription
                }
            }
        }
        return true
    }

    private func importAllPending() {
        for url in icloudWatcher.pendingBundles {
            do {
                let project = try icloudWatcher.importAndClear(url: url, using: importer)
                selectedProjectID = project.id
            } catch {
                importError = error.localizedDescription
            }
        }
        loadProjects()
    }

    private func deleteProject(_ project: PropertyProject) {
        try? importer.deleteProject(project)
        if selectedProjectID == project.id {
            selectedProjectID = nil
        }
        loadProjects()
    }
}

// MARK: - Sidebar Row

struct SidebarProjectRow: View {
    let project: PropertyProject

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(project.address ?? "Untitled Property")
                .font(.subheadline.weight(.medium))
                .foregroundColor(StudiioTheme.textPrimary)
                .lineLimit(1)

            HStack(spacing: 8) {
                let roomCount = project.floors.flatMap(\.rooms).count
                Text("\(roomCount) room\(roomCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundColor(StudiioTheme.accentOrange)

                Text(project.capturedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundColor(StudiioTheme.textTertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    BlueprintMainView()
        .preferredColorScheme(.dark)
        .frame(width: 1200, height: 800)
}
