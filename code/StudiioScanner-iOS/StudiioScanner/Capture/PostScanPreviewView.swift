import SwiftUI
import RealityKit
import ARKit

/// Shows a 3D preview of the completed scan.
/// User can rotate/zoom to inspect, then save or discard.
struct PostScanPreviewView: View {
    let project: PropertyProject
    let meshData: [ExtractedMeshData]
    var onSave: (PropertyProject) -> Void
    var onDiscard: () -> Void

    @State private var editableProject: PropertyProject
    @State private var showAddressInput = false

    init(
        project: PropertyProject,
        meshData: [ExtractedMeshData],
        onSave: @escaping (PropertyProject) -> Void,
        onDiscard: @escaping () -> Void
    ) {
        self.project = project
        self.meshData = meshData
        self.onSave = onSave
        self.onDiscard = onDiscard
        self._editableProject = State(initialValue: project)
    }

    var body: some View {
        ZStack {
            StudiioTheme.backgroundPrimary
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                header

                // 3D Preview
                Preview3DView(meshData: meshData)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Scan summary
                scanSummary

                // Action buttons
                actionButtons
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Scan Complete")
                    .font(.title2.weight(.bold))
                    .foregroundColor(StudiioTheme.textPrimary)

                Text(editableProject.address ?? "Tap to add address")
                    .font(.subheadline)
                    .foregroundColor(editableProject.address != nil
                                     ? StudiioTheme.textSecondary
                                     : StudiioTheme.accentOrange)
                    .onTapGesture {
                        showAddressInput = true
                    }
            }

            Spacer()

            // Floor count badge
            HStack(spacing: 4) {
                Image(systemName: "building.2")
                    .font(.caption)
                Text("\(editableProject.floors.count)")
                    .font(.caption.weight(.bold))
            }
            .foregroundColor(StudiioTheme.accentOrange)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(StudiioTheme.backgroundElevated)
            )
        }
        .padding(StudiioTheme.spacingM)
        .alert("Property Address", isPresented: $showAddressInput) {
            TextField("e.g. 23 Smith St, Lismore", text: Binding(
                get: { editableProject.address ?? "" },
                set: { editableProject.address = $0.isEmpty ? nil : $0 }
            ))
            Button("Save") { }
            Button("Skip", role: .cancel) { }
        }
    }

    // MARK: - Scan Summary

    private var scanSummary: some View {
        VStack(spacing: StudiioTheme.spacingS) {
            Divider()
                .background(StudiioTheme.backgroundElevated)

            HStack(spacing: StudiioTheme.spacingL) {
                summaryItem(
                    icon: "square.split.2x2",
                    value: "\(totalRoomCount)",
                    label: "Rooms"
                )
                summaryItem(
                    icon: "building.2",
                    value: "\(editableProject.floors.count)",
                    label: "Floors"
                )
                summaryItem(
                    icon: "ruler",
                    value: "\(Int(totalArea)) m\u{00B2}",
                    label: "Total Area"
                )
            }
            .padding(.vertical, StudiioTheme.spacingS)
        }
        .padding(.horizontal, StudiioTheme.spacingM)
    }

    private func summaryItem(icon: String, value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(StudiioTheme.accentOrange)
            Text(value)
                .font(.headline)
                .foregroundColor(StudiioTheme.textPrimary)
            Text(label)
                .font(.caption2)
                .foregroundColor(StudiioTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: StudiioTheme.spacingM) {
            Button("Discard") {
                onDiscard()
            }
            .buttonStyle(.studiioSecondary)

            Button("Save Project") {
                onSave(editableProject)
            }
            .buttonStyle(.studiioPrimary)
        }
        .padding(StudiioTheme.spacingM)
    }

    // MARK: - Computed

    private var totalRoomCount: Int {
        editableProject.floors.reduce(0) { $0 + $1.rooms.count }
    }

    private var totalArea: Double {
        editableProject.floors.flatMap(\.rooms).reduce(0) { $0 + $1.area }
    }
}

// MARK: - 3D Preview UIViewRepresentable

struct Preview3DView: UIViewRepresentable {
    let meshData: [ExtractedMeshData]

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.environment.background = .color(UIColor(
            red: 0.05, green: 0.05, blue: 0.05, alpha: 1.0
        ))

        // Enable camera controls for orbiting
        arView.cameraMode = .nonAR

        let anchor = AnchorEntity(world: .zero)

        // Render all mesh data with orange material
        var material = UnlitMaterial()
        material.color = .init(
            tint: UIColor(
                red: 1.0,
                green: 0.55,
                blue: 0.0,
                alpha: 0.6
            )
        )

        for data in meshData {
            var descriptor = MeshDescriptor(name: "PreviewMesh")
            descriptor.positions = MeshBuffer(data.positions)
            descriptor.normals = MeshBuffer(data.normals)
            descriptor.primitives = .triangles(data.indices)

            if let meshResource = try? MeshResource.generate(from: [descriptor]) {
                let entity = ModelEntity(mesh: meshResource, materials: [material])
                entity.transform = Transform(matrix: data.transform)
                anchor.addChild(entity)
            }
        }

        arView.scene.addAnchor(anchor)

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) { }
}
