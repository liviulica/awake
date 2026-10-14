import AppKit

/// The three menu bar states, drawn in code as template images so macOS
/// tints them for light and dark bars: a pilot light. Off is the flame's
/// outline (unlit); screen on is the flame filled; lid closed is a small low
/// flame on the closed lid: turned down, never out.
enum MenuBarIcon: Equatable, CaseIterable {
    case off
    case awake
    case lid

    static let size = NSSize(width: 18, height: 18)
    /// Shapes are specified in a 24-unit square, y down, like the mockup's SVG.
    private static let units: CGFloat = 24

    @MainActor
    static func image(_ icon: MenuBarIcon) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform()
            t.scale(by: rect.width / units)
            t.concat()
            draw(icon)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = switch icon {
        case .off: "Awake: off"
        case .awake: "Awake: keeping the Mac awake"
        case .lid: "Awake: running with the lid closed"
        }
        return image
    }

    /// Draws into the current context in 24-unit, y-down coordinates.
    static func draw(_ icon: MenuBarIcon) {
        NSColor.black.set()
        switch icon {
        case .off:
            stroke(flame(), width: 1.7)
        case .awake:
            flame().fill()
        case .lid:
            let small = flame()
            // Move the flame's bottom point to the origin, scale, then put
            // that point at (12, 17.4) just above the lid.
            var m = AffineTransform(translationByX: -12, byY: -18.8)
            m.append(AffineTransform(scale: 0.6))
            m.append(AffineTransform(translationByX: 12, byY: 17.4))
            small.transform(using: m)
            small.fill()
            line(from: NSPoint(x: 2.5, y: 19.4), to: NSPoint(x: 21.5, y: 19.4), width: 2.2)
        }
    }

    /// The flame, in 24-unit y-down coordinates: pointed top, round bottom
    /// through (12, 18.8).
    private static func flame() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 12, y: 2.6))
        p.curve(to: NSPoint(x: 17.4, y: 13.4), controlPoint1: NSPoint(x: 13.8, y: 6), controlPoint2: NSPoint(x: 17.4, y: 8.6))
        // Round bottom: from the right side, down through (12, 18.8), to the left side.
        p.appendArc(withCenter: NSPoint(x: 12, y: 13.4), radius: 5.4, startAngle: 0, endAngle: 180, clockwise: false)
        p.curve(to: NSPoint(x: 9.6, y: 7.6), controlPoint1: NSPoint(x: 6.6, y: 10.6), controlPoint2: NSPoint(x: 8.2, y: 8.8))
        p.curve(to: NSPoint(x: 11.6, y: 11.4), controlPoint1: NSPoint(x: 9.8, y: 9.6), controlPoint2: NSPoint(x: 10.6, y: 10.8))
        p.curve(to: NSPoint(x: 12, y: 2.6), controlPoint1: NSPoint(x: 11, y: 8.6), controlPoint2: NSPoint(x: 11.3, y: 5.4))
        p.close()
        return p
    }

    private static func stroke(_ path: NSBezierPath, width: CGFloat) {
        path.lineWidth = width
        path.lineJoinStyle = .round
        path.stroke()
    }

    private static func line(from a: NSPoint, to b: NSPoint, width: CGFloat) {
        let p = NSBezierPath()
        p.move(to: a)
        p.line(to: b)
        p.lineWidth = width
        p.lineCapStyle = .round
        p.stroke()
    }
}
