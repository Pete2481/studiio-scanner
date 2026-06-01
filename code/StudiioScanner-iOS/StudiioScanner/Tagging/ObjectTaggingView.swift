import SwiftUI
import RealityKit
import ARKit

/// Post-scan 3D view where users can tap to place object tags
/// on anything RoomPlan missed — showers, vanities, wardrobes, etc.
struct ObjectTaggingView: View {
    @Binding var rooms: [Room]
    let meshAnchors: [ARMeshAnchor]
    var onDone: () -> Void

    @State private var selectedRoomIndex: Int = 0
    @State private var showCategoryPicker = false
    @State private var pendingTagPosition: SIMD3<Float>?

    var body: some View {
        NavigationStack {
            ZStack {
                StudiioTheme.backgroundPrimary
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // Room selector
                    roomSelector

                    // 3D view with tap-to-tag
                    TaggingARView(
                        meshAnchors: meshAnchors,
                        existingTags: currentRoom.objects,
                        onTap: { position in
                            pendingTagPosition = position
                            showCategoryPicker = true
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Existing tags list
                    tagsList
                }
            }
            .navigationTitle("Tag Objects")
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
            .sheet(isPresented: $showCategoryPicker) {
                CategoryPickerView { category in
                    if let position = pendingTagPosition {
                        addTag(category: category, at: position)
                    }
                    showCategoryPicker = false
                    pendingTagPosition = nil
                }
            }
        }
    }

    // MARK: - Room Selector

    private var roomSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: StudiioTheme.spacingS) {
                ForEach(rooms.indices, id: \.self) { index in
                    Button {
                        selectedRoomIndex = index
                    } label: {
                        Text(rooms[index].name)
                            .font(.subheadline.weight(selectedRoomIndex == index ? .bold : .regular))
                            .foregroundColor(selectedRoomIndex == index ? .white : StudiioTheme.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(selectedRoomIndex == index
                                          ? StudiioTheme.accentOrange
                                          : StudiioTheme.backgroundElevated)
                            )
                    }
                }
            }
            .padding(.horizontal, StudiioTheme.spacingM)
            .padding(.vertical, StudiioTheme.spacingS)
        }
        .background(StudiioTheme.backgroundSecondary)
    }

    // MARK: - Tags List

    private var tagsList: some View {
        VStack(spacing: 0) {
            Divider().background(StudiioTheme.backgroundElevated)

            if currentRoom.objects.isEmpty {
                HStack {
                    Image(systemName: "hand.tap")
                        .foregroundColor(StudiioTheme.textTertiary)
                    Text("Tap on the 3D model to tag objects")
                        .font(.caption)
                        .foregroundColor(StudiioTheme.textTertiary)
                }
                .padding(StudiioTheme.spacingM)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: StudiioTheme.spacingS) {
                        ForEach(currentRoom.objects) { obj in
                            TagPill(object: obj) {
                                removeTag(obj)
                            }
                        }
                    }
                    .padding(.horizontal, StudiioTheme.spacingM)
                    .padding(.vertical, StudiioTheme.spacingS)
                }
            }
        }
        .background(StudiioTheme.backgroundSecondary)
    }

    // MARK: - Helpers

    private var currentRoom: Room {
        guard selectedRoomIndex < rooms.count else {
            return Room(name: "Unknown")
        }
        return rooms[selectedRoomIndex]
    }

    private func addTag(category: ObjectCategory, at position: SIMD3<Float>) {
        guard selectedRoomIndex < rooms.count else { return }
        let tag = TaggedObject(
            id: UUID(),
            category: category,
            positionX: position.x,
            positionY: position.y,
            positionZ: position.z,
            dimensionsX: 0.5, dimensionsY: 0.5, dimensionsZ: 0.5,
            source: .manualTap
        )
        rooms[selectedRoomIndex].objects.append(tag)
    }

    private func removeTag(_ object: TaggedObject) {
        guard selectedRoomIndex < rooms.count else { return }
        rooms[selectedRoomIndex].objects.removeAll { $0.id == object.id }
    }
}

// MARK: - Tag Pill

struct TagPill: View {
    let object: TaggedObject
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(object.category.abbreviation)
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)

            // Source indicator
            Circle()
                .fill(sourceColor)
                .frame(width: 6, height: 6)

            Button {
                onDelete()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(StudiioTheme.textSecondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(StudiioTheme.backgroundElevated)
                .overlay(
                    Capsule()
                        .stroke(StudiioTheme.accentOrange.opacity(0.5), lineWidth: 1)
                )
        )
    }

    private var sourceColor: Color {
        switch object.source {
        case .autoRoomPlan: return StudiioTheme.success
        case .manualTap: return StudiioTheme.accentOrange
        case .voice: return .blue
        case .ai: return .purple
        }
    }
}

// MARK: - Category Picker

struct CategoryPickerView: View {
    var onSelect: (ObjectCategory) -> Void
    @Environment(\.dismiss) private var dismiss

    // Group categories for easier browsing
    private let sections: [(title: String, categories: [ObjectCategory])] = [
        ("Bathroom", [.shower, .vanity, .toilet, .bathtub, .sink]),
        ("Kitchen", [.kitchenBench, .kitchenIsland, .pantry, .stove, .oven, .refrigerator, .dishwasher, .rangehood]),
        ("Bedroom", [.wardrobe, .bed, .linenCupboard]),
        ("Laundry", [.washerDryer, .laundryTub]),
        ("Living", [.sofa, .chair, .table, .television, .fireplace]),
        ("Climate", [.splitSystemAC, .ceilingFan]),
        ("Fixtures", [.pendant, .downlight, .powerPoint, .lightSwitch, .smokeAlarm, .intercom]),
        ("Outdoor", [.barbecue, .pool, .spa, .clothesLine, .letterbox]),
        ("Other", [.storage, .stairs, .hotWaterUnit, .solarPanel, .skylight, .nicheShelf, .wallTV, .custom])
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.categories, id: \.self) { category in
                            Button {
                                onSelect(category)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(category.abbreviation)
                                        .font(.caption.weight(.bold))
                                        .foregroundColor(StudiioTheme.accentOrange)
                                        .frame(width: 50, alignment: .leading)

                                    Text(category.displayName)
                                        .foregroundColor(StudiioTheme.textPrimary)

                                    Spacer()
                                }
                            }
                            .listRowBackground(StudiioTheme.backgroundCard)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(StudiioTheme.backgroundPrimary)
            .navigationTitle("Select Object")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(StudiioTheme.textSecondary)
                }
            }
        }
    }
}

// MARK: - Display Names for Categories

extension ObjectCategory {
    var displayName: String {
        switch self {
        case .storage: return "Storage"
        case .refrigerator: return "Refrigerator"
        case .stove: return "Stove"
        case .oven: return "Oven"
        case .dishwasher: return "Dishwasher"
        case .table: return "Table"
        case .sofa: return "Sofa"
        case .chair: return "Chair"
        case .bed: return "Bed"
        case .sink: return "Sink"
        case .washerDryer: return "Washer/Dryer"
        case .toilet: return "Toilet"
        case .bathtub: return "Bathtub"
        case .fireplace: return "Fireplace"
        case .television: return "Television"
        case .stairs: return "Stairs"
        case .shower: return "Shower"
        case .vanity: return "Vanity"
        case .kitchenBench: return "Kitchen Bench"
        case .kitchenIsland: return "Kitchen Island"
        case .pantry: return "Pantry"
        case .wardrobe: return "Built-in Robe"
        case .linenCupboard: return "Linen Cupboard"
        case .laundryTub: return "Laundry Tub"
        case .rangehood: return "Rangehood"
        case .splitSystemAC: return "Split System A/C"
        case .ceilingFan: return "Ceiling Fan"
        case .pendant: return "Pendant Light"
        case .downlight: return "Downlight"
        case .powerPoint: return "Power Point"
        case .lightSwitch: return "Light Switch"
        case .smokeAlarm: return "Smoke Alarm"
        case .intercom: return "Intercom"
        case .hotWaterUnit: return "Hot Water Unit"
        case .solarPanel: return "Solar Panel"
        case .skylight: return "Skylight"
        case .nicheShelf: return "Niche Shelf"
        case .wallTV: return "Wall Mounted TV"
        case .barbecue: return "BBQ"
        case .pool: return "Pool"
        case .spa: return "Spa"
        case .clothesLine: return "Clothes Line"
        case .letterbox: return "Letterbox"
        case .custom: return "Custom"
        }
    }
}

// MARK: - Tagging AR View (3D with tap handling)

struct TaggingARView: UIViewRepresentable {
    let meshAnchors: [ARMeshAnchor]
    let existingTags: [TaggedObject]
    var onTap: (SIMD3<Float>) -> Void

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.environment.background = .color(UIColor(
            red: 0.05, green: 0.05, blue: 0.05, alpha: 1.0
        ))
        arView.cameraMode = .nonAR

        // Add mesh
        let anchor = AnchorEntity(world: .zero)
        for meshAnchor in meshAnchors {
            if let meshResource = MeshResourceBuilder.build(from: meshAnchor.geometry) {
                var material = UnlitMaterial()
                material.color = .init(
                    tint: UIColor(red: 1.0, green: 0.55, blue: 0.0, alpha: 0.3)
                )
                let entity = ModelEntity(mesh: meshResource, materials: [material])
                entity.transform = Transform(matrix: meshAnchor.transform)
                anchor.addChild(entity)
            }
        }
        arView.scene.addAnchor(anchor)

        // Add tag markers for existing objects
        addTagMarkers(to: anchor, tags: existingTags)

        // Tap gesture
        let tapGesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        arView.addGestureRecognizer(tapGesture)
        context.coordinator.arView = arView
        context.coordinator.onTap = onTap

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) { }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func addTagMarkers(to anchor: AnchorEntity, tags: [TaggedObject]) {
        for tag in tags {
            let marker = ModelEntity(
                mesh: .generateSphere(radius: 0.05),
                materials: [SimpleMaterial(color: UIColor(
                    red: 1.0, green: 0.55, blue: 0.0, alpha: 1.0
                ), isMetallic: false)]
            )
            marker.position = tag.position
            anchor.addChild(marker)
        }
    }

    @MainActor
    class Coordinator {
        var arView: ARView?
        var onTap: ((SIMD3<Float>) -> Void)?

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let arView = arView else { return }
            let location = gesture.location(in: arView)

            // Ray cast into the scene to find the tapped position
            let results = arView.hitTest(location, query: .nearest, mask: .all)
            if let result = results.first {
                let worldPosition = result.position
                onTap?(worldPosition)
            }
        }
    }
}

// MARK: - Shared Mesh Builder

enum MeshResourceBuilder {
    static func build(from geometry: ARMeshGeometry) -> MeshResource? {
        let vertexCount = geometry.vertices.count
        let vertexBuffer = geometry.vertices.buffer
        let vertexStride = geometry.vertices.stride
        let vertexOffset = geometry.vertices.offset

        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(vertexCount)
        for i in 0..<vertexCount {
            let byteOffset = vertexOffset + (vertexStride * i)
            let pointer = vertexBuffer.contents().advanced(by: byteOffset)
            positions.append(pointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee)
        }

        var normals: [SIMD3<Float>] = []
        let normalBuffer = geometry.normals.buffer
        let normalStride = geometry.normals.stride
        let normalOffset = geometry.normals.offset
        for i in 0..<geometry.normals.count {
            let byteOffset = normalOffset + (normalStride * i)
            let pointer = normalBuffer.contents().advanced(by: byteOffset)
            normals.append(pointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee)
        }

        let faceCount = geometry.faces.count
        let facesBuffer = geometry.faces.buffer
        let faceBytesPerIndex = geometry.faces.bytesPerIndex
        let indexCountPerPrimitive = geometry.faces.indexCountPerPrimitive
        var indices: [UInt32] = []
        indices.reserveCapacity(faceCount * indexCountPerPrimitive)
        for i in 0..<(faceCount * indexCountPerPrimitive) {
            let byteOffset = faceBytesPerIndex * i
            let pointer = facesBuffer.contents().advanced(by: byteOffset)
            switch faceBytesPerIndex {
            case 2: indices.append(UInt32(pointer.assumingMemoryBound(to: UInt16.self).pointee))
            case 4: indices.append(pointer.assumingMemoryBound(to: UInt32.self).pointee)
            default: return nil
            }
        }

        var descriptor = MeshDescriptor(name: "Mesh")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }
}
