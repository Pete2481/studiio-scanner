import SwiftUI
import CoreGraphics

/// Renders a 2D floor plan in Roomio style using SwiftUI Canvas.
/// White background, black walls, blue bathroom fill, hatched outdoor areas.
struct BlueprintRenderer: View {
    let layout: FloorPlanLayout
    let canvasSize: CGSize
    let showDimensions: Bool
    let showObjectLabels: Bool

    init(
        layout: FloorPlanLayout,
        canvasSize: CGSize = CGSize(width: 1190, height: 842), // A3 at 72dpi
        showDimensions: Bool = true,
        showObjectLabels: Bool = true
    ) {
        self.layout = layout
        self.canvasSize = canvasSize
        self.showDimensions = showDimensions
        self.showObjectLabels = showObjectLabels
    }

    var body: some View {
        Canvas { context, size in
            let transform = BlueprintTransform.forA3(
                planBounds: layout.bounds,
                canvasSize: size
            )

            // 1. White background
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))

            // 2. Room fills
            drawRoomFills(context: &context, transform: transform)

            // 3. Walls
            drawWalls(context: &context, transform: transform)

            // 4. Room labels
            drawRoomLabels(context: &context, transform: transform)

            // 5. Object symbols
            if showObjectLabels {
                drawObjectLabels(context: &context, transform: transform)
            }

            // 6. Dimension lines
            if showDimensions {
                drawDimensionLines(context: &context, transform: transform)
            }

            // 7. Floor title
            drawFloorTitle(context: &context, size: size)

            // 8. Scale indicator
            drawScaleBar(context: &context, size: size, transform: transform)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .background(Color.white)
    }

    // MARK: - Room Fills

    private func drawRoomFills(context: inout GraphicsContext, transform: BlueprintTransform) {
        for room in layout.rooms {
            guard room.polygon.count >= 3 else { continue }

            var path = Path()
            let first = transform.point(from: room.polygon[0])
            path.move(to: first)
            for i in 1..<room.polygon.count {
                path.addLine(to: transform.point(from: room.polygon[i]))
            }
            path.closeSubpath()

            if room.isBathroom {
                // Light blue fill for bathrooms
                context.fill(path, with: .color(Color(red: 0.84, green: 0.92, blue: 0.97)))
            } else if room.isOutdoor {
                // Light grey for outdoor areas
                context.fill(path, with: .color(Color(white: 0.93)))
                // Diagonal hatching
                drawHatching(context: &context, path: path, transform: transform, room: room)
            }
        }
    }

    private func drawHatching(
        context: inout GraphicsContext,
        path: Path,
        transform: BlueprintTransform,
        room: RoomPolygon
    ) {
        let bounds = path.boundingRect
        let spacing: CGFloat = 8
        var hatchPath = Path()

        var x = bounds.minX
        while x < bounds.maxX + bounds.height {
            hatchPath.move(to: CGPoint(x: x, y: bounds.minY))
            hatchPath.addLine(to: CGPoint(x: x - bounds.height, y: bounds.maxY))
            x += spacing
        }

        var clippedContext = context
        clippedContext.clip(to: path)
        clippedContext.stroke(hatchPath, with: .color(Color(white: 0.7)), lineWidth: 0.5)
    }

    // MARK: - Walls

    private func drawWalls(context: inout GraphicsContext, transform: BlueprintTransform) {
        for wall in layout.walls {
            let start = transform.point(from: wall.start)
            let end = transform.point(from: wall.end)
            let thickness = transform.length(from: wall.thickness)

            // Draw wall as a thick line (filled rectangle)
            let wallPath = wallRectPath(
                start: start,
                end: end,
                thickness: max(thickness, wall.isExterior ? 4 : 2)
            )
            context.fill(wallPath, with: .color(.black))
        }
    }

    private func wallRectPath(start: CGPoint, end: CGPoint, thickness: CGFloat) -> Path {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let len = hypot(dx, dy)
        guard len > 0 else { return Path() }

        let nx = -dy / len * thickness / 2
        let ny = dx / len * thickness / 2

        var path = Path()
        path.move(to: CGPoint(x: start.x + nx, y: start.y + ny))
        path.addLine(to: CGPoint(x: end.x + nx, y: end.y + ny))
        path.addLine(to: CGPoint(x: end.x - nx, y: end.y - ny))
        path.addLine(to: CGPoint(x: start.x - nx, y: start.y - ny))
        path.closeSubpath()
        return path
    }

    // MARK: - Room Labels

    private func drawRoomLabels(context: inout GraphicsContext, transform: BlueprintTransform) {
        for room in layout.rooms {
            let center = transform.point(from: room.centroid)

            // Room name in caps
            let nameText = Text(room.name.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.black)

            context.draw(
                context.resolve(nameText),
                at: center,
                anchor: .center
            )

            // Dimensions below name
            if room.widthMetres > 0 && room.heightMetres > 0 {
                let dimText = Text(String(format: "%.1f x %.1f m", room.widthMetres, room.heightMetres))
                    .font(.system(size: 8))
                    .foregroundColor(.black)

                context.draw(
                    context.resolve(dimText),
                    at: CGPoint(x: center.x, y: center.y + 14),
                    anchor: .center
                )
            }
        }
    }

    // MARK: - Object Labels

    private func drawObjectLabels(context: inout GraphicsContext, transform: BlueprintTransform) {
        for room in layout.rooms {
            for object in room.objects {
                let pos = transform.point(from: CGPoint(
                    x: CGFloat(object.positionX),
                    y: CGFloat(object.positionZ)
                ))

                // Draw object abbreviation
                let label = Text(object.category.abbreviation)
                    .font(.system(size: 7, weight: .medium))
                    .foregroundColor(.black)

                // Background box
                let resolved = context.resolve(label)
                let labelSize = resolved.measure(in: CGSize(width: 100, height: 50))
                let padding: CGFloat = 2
                let bgRect = CGRect(
                    x: pos.x - labelSize.width / 2 - padding,
                    y: pos.y - labelSize.height / 2 - padding,
                    width: labelSize.width + 2 * padding,
                    height: labelSize.height + 2 * padding
                )
                context.fill(Path(bgRect), with: .color(.white))
                context.stroke(Path(bgRect), with: .color(Color(white: 0.6)), lineWidth: 0.5)

                context.draw(resolved, at: pos, anchor: .center)
            }
        }
    }

    // MARK: - Dimension Lines

    private func drawDimensionLines(context: inout GraphicsContext, transform: BlueprintTransform) {
        // Draw dimension lines for each wall segment
        for wall in layout.walls {
            guard wall.length > 0.5 else { continue } // skip tiny walls

            let start = transform.point(from: wall.start)
            let end = transform.point(from: wall.end)

            // Offset dimension line from wall
            let dx = end.x - start.x
            let dy = end.y - start.y
            let len = hypot(dx, dy)
            let normalX = -dy / len * 15
            let normalY = dx / len * 15

            let dimStart = CGPoint(x: start.x + normalX, y: start.y + normalY)
            let dimEnd = CGPoint(x: end.x + normalX, y: end.y + normalY)

            // Dimension line
            var dimPath = Path()
            dimPath.move(to: dimStart)
            dimPath.addLine(to: dimEnd)
            context.stroke(dimPath, with: .color(Color(white: 0.4)), lineWidth: 0.5)

            // End ticks
            let tickLen: CGFloat = 4
            let tickDx = dx / len * tickLen
            let tickDy = dy / len * tickLen

            var tick1 = Path()
            tick1.move(to: CGPoint(x: dimStart.x - tickDy, y: dimStart.y + tickDx))
            tick1.addLine(to: CGPoint(x: dimStart.x + tickDy, y: dimStart.y - tickDx))
            context.stroke(tick1, with: .color(Color(white: 0.4)), lineWidth: 0.5)

            var tick2 = Path()
            tick2.move(to: CGPoint(x: dimEnd.x - tickDy, y: dimEnd.y + tickDx))
            tick2.addLine(to: CGPoint(x: dimEnd.x + tickDy, y: dimEnd.y - tickDx))
            context.stroke(tick2, with: .color(Color(white: 0.4)), lineWidth: 0.5)

            // Label
            let midpoint = CGPoint(
                x: (dimStart.x + dimEnd.x) / 2,
                y: (dimStart.y + dimEnd.y) / 2
            )
            let dimLabel = Text(String(format: "%.2f", wall.length))
                .font(.system(size: 7))
                .foregroundColor(Color(white: 0.3))

            context.draw(context.resolve(dimLabel), at: midpoint, anchor: .center)
        }
    }

    // MARK: - Floor Title

    private func drawFloorTitle(context: inout GraphicsContext, size: CGSize) {
        let titleText = Text(layout.floorName.uppercased())
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(.black)

        context.draw(
            context.resolve(titleText),
            at: CGPoint(x: 40, y: size.height - 60),
            anchor: .topLeading
        )

        let areaText = Text(String(format: "TOTAL APPROX. FLOOR AREA %.0f SQ.M", layout.totalArea))
            .font(.system(size: 9))
            .foregroundColor(.black)

        context.draw(
            context.resolve(areaText),
            at: CGPoint(x: 40, y: size.height - 42),
            anchor: .topLeading
        )
    }

    // MARK: - Scale Bar

    private func drawScaleBar(context: inout GraphicsContext, size: CGSize, transform: BlueprintTransform) {
        let barMetres: CGFloat = 1.0 // 1 metre bar
        let barLength = transform.length(from: barMetres)
        let barY = size.height - 30
        let barX = size.width - 40 - barLength

        var barPath = Path()
        barPath.move(to: CGPoint(x: barX, y: barY))
        barPath.addLine(to: CGPoint(x: barX + barLength, y: barY))
        context.stroke(barPath, with: .color(.black), lineWidth: 1)

        // End ticks
        for x in [barX, barX + barLength] {
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: barY - 3))
            tick.addLine(to: CGPoint(x: x, y: barY + 3))
            context.stroke(tick, with: .color(.black), lineWidth: 1)
        }

        let scaleLabel = Text("1 m")
            .font(.system(size: 8))
            .foregroundColor(.black)

        context.draw(
            context.resolve(scaleLabel),
            at: CGPoint(x: barX + barLength / 2, y: barY - 6),
            anchor: .bottom
        )

        let scaleRatio = Text(transform.metricScale)
            .font(.system(size: 8, weight: .medium))
            .foregroundColor(.black)

        context.draw(
            context.resolve(scaleRatio),
            at: CGPoint(x: barX + barLength / 2, y: barY + 8),
            anchor: .top
        )
    }
}
