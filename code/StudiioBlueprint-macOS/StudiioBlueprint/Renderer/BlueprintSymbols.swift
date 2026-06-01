import SwiftUI
import CoreGraphics

/// Standard architectural symbols for the blueprint renderer.
/// Matches Roomio conventions: door arcs, window breaks, toilet ovals, etc.
enum BlueprintSymbols {

    // MARK: - Door (Arc swing)

    static func doorPath(at origin: CGPoint, width: CGFloat, swingAngle: CGFloat = .pi / 2, flipX: Bool = false) -> Path {
        var path = Path()
        let direction: CGFloat = flipX ? -1 : 1

        // Door leaf
        path.move(to: origin)
        path.addLine(to: CGPoint(x: origin.x + width * direction, y: origin.y))

        // Swing arc
        path.addArc(
            center: origin,
            radius: width,
            startAngle: .zero,
            endAngle: Angle(radians: -swingAngle * Double(direction)),
            clockwise: direction > 0
        )

        return path
    }

    // MARK: - Window (Double parallel break)

    static func windowPath(at start: CGPoint, end: CGPoint, thickness: CGFloat = 2) -> Path {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let len = hypot(dx, dy)
        guard len > 0 else { return Path() }

        let nx = -dy / len * thickness
        let ny = dx / len * thickness

        var path = Path()
        // Outer line
        path.move(to: CGPoint(x: start.x + nx, y: start.y + ny))
        path.addLine(to: CGPoint(x: end.x + nx, y: end.y + ny))
        // Inner line
        path.move(to: CGPoint(x: start.x - nx, y: start.y - ny))
        path.addLine(to: CGPoint(x: end.x - nx, y: end.y - ny))

        return path
    }

    // MARK: - Toilet (Elongated oval)

    static func toiletPath(at center: CGPoint, width: CGFloat = 12, height: CGFloat = 16) -> Path {
        let rect = CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        )
        return Path(ellipseIn: rect)
    }

    // MARK: - Shower (Square with diagonal lines)

    static func showerPath(at center: CGPoint, size: CGFloat = 20) -> Path {
        var path = Path()
        let half = size / 2
        let rect = CGRect(x: center.x - half, y: center.y - half, width: size, height: size)
        path.addRect(rect)

        // Diagonal lines
        let spacing: CGFloat = 4
        var x = rect.minX + spacing
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: x - rect.minX + rect.minY))
            x += spacing
        }
        x = rect.minY + spacing
        while x < rect.maxY {
            path.move(to: CGPoint(x: rect.maxX, y: x))
            path.addLine(to: CGPoint(x: rect.maxX - (rect.maxY - x), y: rect.maxY))
            x += spacing
        }

        return path
    }

    // MARK: - Bathtub (Rounded rectangle)

    static func bathtubPath(at center: CGPoint, width: CGFloat = 18, height: CGFloat = 40) -> Path {
        let rect = CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        )
        return Path(roundedRect: rect, cornerRadius: width / 3)
    }

    // MARK: - Ceiling Fan (4-blade symbol)

    static func ceilingFanPath(at center: CGPoint, radius: CGFloat = 10) -> Path {
        var path = Path()

        // Circle
        path.addEllipse(in: CGRect(
            x: center.x - 2, y: center.y - 2, width: 4, height: 4
        ))

        // 4 blades
        for i in 0..<4 {
            let angle = CGFloat(i) * .pi / 2
            let bladeEnd = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            path.move(to: center)
            path.addLine(to: bladeEnd)

            // Blade width
            let perpAngle = angle + .pi / 2
            let w: CGFloat = 3
            let tipLeft = CGPoint(
                x: bladeEnd.x + cos(perpAngle) * w,
                y: bladeEnd.y + sin(perpAngle) * w
            )
            let tipRight = CGPoint(
                x: bladeEnd.x - cos(perpAngle) * w,
                y: bladeEnd.y - sin(perpAngle) * w
            )
            path.move(to: tipLeft)
            path.addLine(to: tipRight)
        }

        return path
    }

    // MARK: - North Arrow

    static func northArrowPath(at center: CGPoint, size: CGFloat = 30) -> Path {
        var path = Path()
        let half = size / 2

        // Arrow pointing up (north)
        path.move(to: CGPoint(x: center.x, y: center.y - half))
        path.addLine(to: CGPoint(x: center.x - half * 0.3, y: center.y + half * 0.3))
        path.addLine(to: CGPoint(x: center.x, y: center.y))
        path.addLine(to: CGPoint(x: center.x + half * 0.3, y: center.y + half * 0.3))
        path.closeSubpath()

        return path
    }

    // MARK: - Appliance Box (labelled square)

    static func applianceBox(at center: CGPoint, size: CGFloat = 14) -> Path {
        let half = size / 2
        return Path(CGRect(x: center.x - half, y: center.y - half, width: size, height: size))
    }
}
