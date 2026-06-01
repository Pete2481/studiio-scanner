import SwiftUI

/// Detail view for an imported project — shows summary and will host the blueprint renderer.
struct BlueprintProjectDetailView: View {
    let project: PropertyProject

    @State private var selectedFloorIndex: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            // Top bar with project info
            projectHeader

            Divider().background(StudiioTheme.backgroundElevated)

            // Floor selector
            if project.floors.count > 1 {
                floorSelector
                Divider().background(StudiioTheme.backgroundElevated)
            }

            // Blueprint canvas area (placeholder for Phase 6)
            blueprintCanvas

            Divider().background(StudiioTheme.backgroundElevated)

            // Bottom info bar
            infoBar
        }
        .background(StudiioTheme.backgroundPrimary)
    }

    // MARK: - Header

    private var projectHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.address ?? "Untitled Property")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(StudiioTheme.textPrimary)

                Text("Scanned \(project.capturedAt.formatted(date: .long, time: .shortened))")
                    .font(.caption)
                    .foregroundColor(StudiioTheme.textTertiary)
            }

            Spacer()

            // Stats + Export
            HStack(spacing: StudiioTheme.spacingL) {
                statItem(value: "\(totalRoomCount)", label: "Rooms")
                statItem(value: "\(project.floors.count)", label: project.floors.count == 1 ? "Floor" : "Floors")
                statItem(value: String(format: "%.0f m\u{00B2}", totalArea), label: "Area")

                if !project.outdoorZones.isEmpty {
                    statItem(value: "\(project.outdoorZones.count)", label: "Outdoor")
                }

                Spacer().frame(width: StudiioTheme.spacingM)

                ExportButton(project: project)
                    .buttonStyle(.plain)
                    .foregroundColor(StudiioTheme.accentOrange)
            }
        }
        .padding(.horizontal, StudiioTheme.spacingL)
        .padding(.vertical, StudiioTheme.spacingM)
        .background(StudiioTheme.backgroundSecondary)
    }

    private func statItem(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline)
                .foregroundColor(StudiioTheme.accentOrange)
            Text(label)
                .font(.caption2)
                .foregroundColor(StudiioTheme.textSecondary)
        }
    }

    // MARK: - Floor Selector

    private var floorSelector: some View {
        HStack(spacing: StudiioTheme.spacingS) {
            ForEach(project.floors.indices, id: \.self) { index in
                Button {
                    selectedFloorIndex = index
                } label: {
                    Text(project.floors[index].name)
                        .font(.subheadline.weight(selectedFloorIndex == index ? .bold : .regular))
                        .foregroundColor(selectedFloorIndex == index ? .white : StudiioTheme.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(selectedFloorIndex == index
                                      ? StudiioTheme.accentOrange
                                      : StudiioTheme.backgroundElevated)
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(.horizontal, StudiioTheme.spacingL)
        .padding(.vertical, StudiioTheme.spacingS)
        .background(StudiioTheme.backgroundSecondary)
    }

    // MARK: - Blueprint Canvas

    private var blueprintCanvas: some View {
        GeometryReader { geo in
            if selectedFloorIndex < project.floors.count {
                let floor = project.floors[selectedFloorIndex]
                let layout = FloorPlanExtractor.extractLayout(from: floor)

                if layout.rooms.isEmpty {
                    emptyCanvasView
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        BlueprintRenderer(
                            layout: layout,
                            canvasSize: geo.size,
                            showDimensions: true,
                            showObjectLabels: true
                        )
                    }
                }
            } else {
                emptyCanvasView
            }
        }
    }

    private var emptyCanvasView: some View {
        ZStack {
            Color.white
            VStack(spacing: StudiioTheme.spacingM) {
                Image(systemName: "ruler")
                    .font(.system(size: 48))
                    .foregroundColor(StudiioTheme.textTertiary)
                Text("No room data to render")
                    .font(.body)
                    .foregroundColor(StudiioTheme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Info Bar

    private var infoBar: some View {
        HStack {
            if selectedFloorIndex < project.floors.count {
                let floor = project.floors[selectedFloorIndex]
                let roomNames = floor.rooms.map(\.name).joined(separator: " | ")
                Text(roomNames)
                    .font(.caption)
                    .foregroundColor(StudiioTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            // Tagged objects count
            let objectCount = project.floors.flatMap(\.rooms).flatMap(\.objects).count
            if objectCount > 0 {
                HStack(spacing: 4) {
                    Circle().fill(StudiioTheme.accentOrange).frame(width: 6, height: 6)
                    Text("\(objectCount) tagged objects")
                        .font(.caption)
                        .foregroundColor(StudiioTheme.textSecondary)
                }
            }

            // Scale indicator
            Text("1:100")
                .font(.caption.weight(.medium))
                .foregroundColor(StudiioTheme.accentOrange)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .stroke(StudiioTheme.accentOrange, lineWidth: 1)
                )
        }
        .padding(.horizontal, StudiioTheme.spacingL)
        .padding(.vertical, StudiioTheme.spacingS)
        .background(StudiioTheme.backgroundSecondary)
    }

    // MARK: - Helpers

    private var totalRoomCount: Int {
        project.floors.flatMap(\.rooms).count
    }

    private var totalArea: Double {
        project.floors.flatMap(\.rooms).reduce(0) { $0 + $1.area }
    }
}
