import SwiftUI
import PhotosUI

/// Detail view for a single scanned property project — sci-fi glass card aesthetic.
struct ProjectDetailView: View {
    @State private var project: PropertyProject
    @ObservedObject var projectStore: ProjectStore
    @ObservedObject var syncManager: SyncManager

    @State private var showShareSheet = false
    @State private var showSyncOptions = false
    @State private var syncError: String?
    @State private var isSyncing = false
    @State private var isEditingName = false
    @State private var editedName = ""
    @State private var showPhotoSource = false
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var heroImage: UIImage?

    init(project: PropertyProject, projectStore: ProjectStore, syncManager: SyncManager) {
        _project = State(initialValue: project)
        self.projectStore = projectStore
        self.syncManager = syncManager
    }

    var body: some View {
        ZStack {
            // Background
            ZStack {
                StudiioTheme.backgroundPrimary
                RadialGradient(
                    colors: [
                        StudiioTheme.accentOrange.opacity(0.05),
                        Color.clear
                    ],
                    center: .top,
                    startRadius: 0,
                    endRadius: 500
                )
            }
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: StudiioTheme.spacingL) {
                    headerCard
                    statsSection
                    floorsSection

                    if !project.outdoorZones.isEmpty {
                        outdoorSection
                    }

                    exportSection
                }
                .padding(StudiioTheme.spacingM)
            }
        }
        .navigationTitle(project.address ?? "Untitled Property")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showShareSheet = true
                    } label: {
                        Label("Share via AirDrop", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        syncToiCloud()
                    } label: {
                        Label("Send to iCloud", systemImage: "icloud.and.arrow.up")
                    }

                    if syncManager.localMacDiscovered {
                        Button {
                            syncToLocalMac()
                        } label: {
                            Label("Send to Mac (WiFi)", systemImage: "desktopcomputer")
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundColor(StudiioTheme.accentOrange)
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            let url = projectStore.exportURL(for: project)
            ShareSheet(activityItems: [url])
        }
        .alert("Sync Error", isPresented: .init(
            get: { syncError != nil },
            set: { if !$0 { syncError = nil } }
        )) {
            Button("OK") { syncError = nil }
        } message: {
            Text(syncError ?? "")
        }
        .alert("Property Name", isPresented: $isEditingName) {
            TextField("Enter property name", text: $editedName)
            Button("Save") { saveName() }
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog("Add Property Photo", isPresented: $showPhotoSource) {
            Button("Take Photo") { showCamera = true }
            Button("Choose from Library") { showPhotoPicker = true }
            Button("Cancel", role: .cancel) { }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraView { image in
                if let image { setHeroImage(image) }
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images)
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    setHeroImage(image)
                }
            }
        }
        .onAppear { loadHeroImage() }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(spacing: 12) {
            // Hero image
            Button {
                showPhotoSource = true
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: StudiioTheme.cornerRadiusMedium)
                        .fill(StudiioTheme.backgroundElevated)
                        .frame(height: 200)

                    if let heroImage {
                        Image(uiImage: heroImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 200)
                            .clipShape(RoundedRectangle(cornerRadius: StudiioTheme.cornerRadiusMedium))
                    } else {
                        VStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(StudiioTheme.accentOrange.opacity(0.1))
                                    .frame(width: 64, height: 64)
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 28))
                                    .foregroundColor(StudiioTheme.accentOrange.opacity(0.5))
                            }
                            Text("ADD PHOTO")
                                .font(.system(size: 11, weight: .bold))
                                .tracking(1.5)
                                .foregroundColor(StudiioTheme.textTertiary)
                        }
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: StudiioTheme.cornerRadiusMedium)
                        .stroke(StudiioTheme.glassStroke, lineWidth: 0.5)
                )
            }

            // Editable property name
            Button {
                editedName = project.address ?? ""
                isEditingName = true
            } label: {
                HStack(spacing: 6) {
                    Text(project.address ?? "Untitled Property")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(StudiioTheme.textPrimary)

                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundColor(StudiioTheme.accentOrange.opacity(0.5))
                }
            }

            Text("Scanned \(project.capturedAt.formatted(date: .long, time: .shortened))")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(StudiioTheme.textTertiary)
        }
        .studiioCard(glow: StudiioTheme.accentOrange, intensity: 0.06)
    }

    // MARK: - Stats

    private var statsSection: some View {
        HStack(spacing: 12) {
            StatBadge(icon: "square.split.2x2", value: "\(totalRoomCount)", label: "Rooms")
            StatBadge(icon: "arrow.up.arrow.down", value: "\(project.floors.count)", label: project.floors.count == 1 ? "Floor" : "Floors")
            StatBadge(icon: "ruler", value: String(format: "%.0f m\u{00B2}", totalArea), label: "Total Area")

            if !project.outdoorZones.isEmpty {
                StatBadge(icon: "sun.max", value: "\(project.outdoorZones.count)", label: "Outdoor")
            }
        }
    }

    // MARK: - Floors

    private var floorsSection: some View {
        VStack(alignment: .leading, spacing: StudiioTheme.spacingS) {
            sectionHeader("Floors")

            ForEach(project.floors) { floor in
                FloorRow(floor: floor)
            }
        }
        .studiioCard()
    }

    // MARK: - Outdoor

    private var outdoorSection: some View {
        VStack(alignment: .leading, spacing: StudiioTheme.spacingS) {
            sectionHeader("Outdoor Zones")

            ForEach(project.outdoorZones) { zone in
                HStack {
                    ZStack {
                        Circle()
                            .fill(StudiioTheme.accentOrange.opacity(0.1))
                            .frame(width: 28, height: 28)
                        Image(systemName: "sun.max")
                            .font(.system(size: 12))
                            .foregroundColor(StudiioTheme.accentOrange)
                    }

                    Text(zone.name.isEmpty ? zone.type.rawValue.capitalized : zone.name)
                        .foregroundColor(StudiioTheme.textPrimary)

                    Spacer()

                    Text(zone.type.rawValue.capitalized)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(StudiioTheme.textTertiary)
                }
            }
        }
        .studiioCard()
    }

    // MARK: - Export

    private var exportSection: some View {
        VStack(spacing: StudiioTheme.spacingM) {
            Button {
                showShareSheet = true
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                    Text("Share Project")
                }
            }
            .buttonStyle(.studiioPrimary)

            if syncManager.iCloudAvailable {
                Button {
                    syncToiCloud()
                } label: {
                    HStack {
                        if isSyncing {
                            ProgressView()
                                .tint(StudiioTheme.accentOrange)
                        }
                        Image(systemName: "icloud.and.arrow.up")
                        Text("Send to iCloud Drive")
                    }
                }
                .buttonStyle(.studiioSecondary)
                .disabled(isSyncing)
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(2)
            .foregroundColor(StudiioTheme.accentOrange.opacity(0.7))
    }

    private var totalRoomCount: Int {
        project.floors.flatMap(\.rooms).count
    }

    private var totalArea: Double {
        project.floors.flatMap(\.rooms).reduce(0) { $0 + $1.area }
    }

    private func saveName() {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        project.address = trimmed.isEmpty ? nil : trimmed
        try? projectStore.updateProject(project)
    }

    private func setHeroImage(_ image: UIImage) {
        heroImage = image
        guard let jpegData = image.jpegData(compressionQuality: 0.85) else { return }
        do {
            let path = try projectStore.saveHeroImage(jpegData, for: project)
            project.heroImagePath = path
            try projectStore.updateProject(project)
        } catch {
            syncError = "Failed to save photo: \(error.localizedDescription)"
        }
    }

    private func loadHeroImage() {
        guard let url = projectStore.heroImageURL(for: project),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return }
        heroImage = image
    }

    private func syncToiCloud() {
        let url = projectStore.exportURL(for: project)
        isSyncing = true
        do {
            try syncManager.syncToiCloud(projectURL: url)
            isSyncing = false
        } catch {
            syncError = error.localizedDescription
            isSyncing = false
        }
    }

    private func syncToLocalMac() {
        let url = projectStore.exportURL(for: project)
        isSyncing = true
        Task {
            do {
                try await syncManager.sendToMac(projectURL: url)
                isSyncing = false
            } catch {
                syncError = error.localizedDescription
                isSyncing = false
            }
        }
    }
}

// MARK: - Camera View (UIKit wrapper)

struct CameraView: UIViewControllerRepresentable {
    let onCapture: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) { }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage?) -> Void

        init(onCapture: @escaping (UIImage?) -> Void) {
            self.onCapture = onCapture
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            onCapture(image)
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCapture(nil)
            picker.dismiss(animated: true)
        }
    }
}

// MARK: - Stat Badge

struct StatBadge: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(StudiioTheme.accentOrange.opacity(0.08))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundColor(StudiioTheme.accentOrange)
            }

            Text(value)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(StudiioTheme.textPrimary)

            Text(label.uppercased())
                .font(.system(size: 8, weight: .bold))
                .tracking(1)
                .foregroundColor(StudiioTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .studiioCard(glow: StudiioTheme.accentOrange, intensity: 0.04)
    }
}

// MARK: - Floor Row

struct FloorRow: View {
    let floor: Floor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(floor.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(StudiioTheme.textPrimary)

                Spacer()

                Text("\(floor.rooms.count) room\(floor.rooms.count == 1 ? "" : "s")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(StudiioTheme.textTertiary)
            }

            let roomNames = floor.rooms.map(\.name).joined(separator: ", ")
            if !roomNames.isEmpty {
                Text(roomNames)
                    .font(.system(size: 12))
                    .foregroundColor(StudiioTheme.textTertiary)
                    .lineLimit(2)
            }

            let objectCount = floor.rooms.flatMap(\.objects).count
            if objectCount > 0 {
                HStack(spacing: 4) {
                    Circle()
                        .fill(StudiioTheme.accentOrange)
                        .frame(width: 4, height: 4)
                    Text("\(objectCount) tagged object\(objectCount == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundColor(StudiioTheme.accentOrange.opacity(0.8))
                }
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Share Sheet (UIKit wrapper)

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}
