import SwiftUI
import CoreGraphics

/// Interactive editor for touching up the 2D floor plan.
/// Allows dragging walls, rooms, and entering verified dimensions.
struct BlueprintEditor: View {
    @Binding var layout: FloorPlanLayout
    @Binding var verifiedDimensions: [VerifiedDimension]
    let canvasSize: CGSize

    @State private var selectedWallID: UUID?
    @State private var selectedRoomID: UUID?
    @State private var showDimensionInput = false
    @State private var dimensionInputValue: String = ""
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false

    var body: some View {
        ZStack {
            // Base blueprint (non-interactive)
            BlueprintRenderer(
                layout: layout,
                canvasSize: canvasSize,
                showDimensions: true,
                showObjectLabels: true
            )

            // Interactive overlay
            Canvas { context, size in
                let transform = BlueprintTransform.forA3(
                    planBounds: layout.bounds,
                    canvasSize: size
                )

                // Highlight selected wall
                if let wallID = selectedWallID,
                   let wall = layout.walls.first(where: { $0.id == wallID }) {
                    let start = transform.point(from: wall.start)
                    let end = transform.point(from: wall.end)
                    let path = highlightPath(start: start, end: end, width: 8)
                    context.fill(path, with: .color(Color.orange.opacity(0.3)))
                    context.stroke(path, with: .color(.orange), lineWidth: 2)
                }

                // Highlight selected room
                if let roomID = selectedRoomID,
                   let room = layout.rooms.first(where: { $0.id == roomID }) {
                    var path = Path()
                    guard let first = room.polygon.first else { return }
                    path.move(to: transform.point(from: first))
                    for p in room.polygon.dropFirst() {
                        path.addLine(to: transform.point(from: p))
                    }
                    path.closeSubpath()
                    context.stroke(path, with: .color(.orange), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }

                // Draw verified dimension markers
                for vd in verifiedDimensions {
                    if let wall = layout.walls.first(where: { $0.id == vd.wallID }) {
                        let mid = transform.point(from: wall.midpoint)
                        let checkmark = Path(ellipseIn: CGRect(x: mid.x - 6, y: mid.y - 6, width: 12, height: 12))
                        context.fill(checkmark, with: .color(.green))

                        let label = Text(String(format: "%.2f m", vd.measuredLength))
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(.green)
                        context.draw(
                            context.resolve(label),
                            at: CGPoint(x: mid.x, y: mid.y - 12),
                            anchor: .bottom
                        )
                    }
                }
            }
            .allowsHitTesting(true)
            .onTapGesture { location in
                handleTap(at: location)
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        handleDrag(value)
                    }
                    .onEnded { value in
                        finishDrag(value)
                    }
            )
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .sheet(isPresented: $showDimensionInput) {
            DimensionInputSheet(
                wallID: selectedWallID,
                currentLength: selectedWallLength,
                inputValue: $dimensionInputValue,
                onConfirm: { wallID, measured in
                    addVerifiedDimension(wallID: wallID, measured: measured)
                    showDimensionInput = false
                },
                onCancel: {
                    showDimensionInput = false
                }
            )
        }
    }

    // MARK: - Interaction

    private func handleTap(at location: CGPoint) {
        let transform = BlueprintTransform.forA3(
            planBounds: layout.bounds,
            canvasSize: canvasSize
        )

        // Check walls first (higher priority)
        for wall in layout.walls {
            let start = transform.point(from: wall.start)
            let end = transform.point(from: wall.end)
            if distanceToSegment(location, start, end) < 10 {
                selectedWallID = wall.id
                selectedRoomID = nil
                return
            }
        }

        // Then check rooms
        for room in layout.rooms {
            let center = transform.point(from: room.centroid)
            if hypot(location.x - center.x, location.y - center.y) < 30 {
                selectedRoomID = room.id
                selectedWallID = nil
                return
            }
        }

        // Tap on empty space — deselect
        selectedWallID = nil
        selectedRoomID = nil
    }

    private func handleDrag(_ value: DragGesture.Value) {
        isDragging = true
        dragOffset = value.translation
    }

    private func finishDrag(_ value: DragGesture.Value) {
        let transform = BlueprintTransform.forA3(
            planBounds: layout.bounds,
            canvasSize: canvasSize
        )

        let dx = value.translation.width / transform.scale
        let dy = value.translation.height / transform.scale

        // Move selected room
        if let roomID = selectedRoomID,
           let index = layout.rooms.firstIndex(where: { $0.id == roomID }) {
            var room = layout.rooms[index]
            room = RoomPolygon(
                id: room.id,
                name: room.name,
                polygon: room.polygon.map { CGPoint(x: $0.x + dx, y: $0.y + dy) },
                area: room.area,
                objects: room.objects,
                isBathroom: room.isBathroom,
                isOutdoor: room.isOutdoor
            )
            layout.rooms[index] = room
        }

        isDragging = false
        dragOffset = .zero
    }

    // MARK: - Verified Dimensions

    private var selectedWallLength: Double {
        guard let wallID = selectedWallID,
              let wall = layout.walls.first(where: { $0.id == wallID }) else { return 0 }
        return Double(wall.length)
    }

    private func addVerifiedDimension(wallID: UUID, measured: Double) {
        let original = selectedWallLength
        let vd = VerifiedDimension(
            wallID: wallID,
            measuredLength: measured,
            originalLength: original
        )
        verifiedDimensions.append(vd)
    }

    // MARK: - Helpers

    private func highlightPath(start: CGPoint, end: CGPoint, width: CGFloat) -> Path {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let len = hypot(dx, dy)
        guard len > 0 else { return Path() }

        let nx = -dy / len * width / 2
        let ny = dx / len * width / 2

        var path = Path()
        path.move(to: CGPoint(x: start.x + nx, y: start.y + ny))
        path.addLine(to: CGPoint(x: end.x + nx, y: end.y + ny))
        path.addLine(to: CGPoint(x: end.x - nx, y: end.y - ny))
        path.addLine(to: CGPoint(x: start.x - nx, y: start.y - ny))
        path.closeSubpath()
        return path
    }

    private func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return hypot(p.x - a.x, p.y - a.y) }

        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq
        t = max(0, min(1, t))
        let proj = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(p.x - proj.x, p.y - proj.y)
    }
}

// MARK: - Dimension Input Sheet

struct DimensionInputSheet: View {
    let wallID: UUID?
    let currentLength: Double
    @Binding var inputValue: String
    var onConfirm: (UUID, Double) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Verify Dimension")
                .font(.headline)

            Text(String(format: "Scanned: %.2f m", currentLength))
                .font(.subheadline)
                .foregroundColor(.secondary)

            TextField("Measured length (m)", text: $inputValue)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)

            HStack(spacing: 16) {
                Button("Cancel") {
                    onCancel()
                }

                Button("Confirm") {
                    guard let wallID = wallID,
                          let measured = Double(inputValue) else { return }
                    onConfirm(wallID, measured)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 1.0, green: 0.55, blue: 0.0))
            }
        }
        .padding(24)
        .frame(width: 300)
    }
}
