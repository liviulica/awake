import AppKit

/// The three menu bar states, drawn in code as template images so macOS
/// tints them for light and dark bars: a pilot light. Off is the flame's
/// outline (unlit); screen on is the flame filled; lid closed is the flame,
/// lower and a little smaller, on the closed lid: turned down, never out.
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
        case .off: "Ember: off"
        case .awake: "Ember: keeping the Mac awake"
        case .lid: "Ember: running with the lid closed"
        }
        return image
    }

    static let outlineWidth: CGFloat = 1.7
    static let lidLineWidth: CGFloat = 2.6
    /// Where the pilot flame sits: its bottom point, just above the lid line.
    private static let lidFlameBottom = NSPoint(x: 12, y: 17.2)
    /// Lower and a little smaller than the full flame, never slight: the
    /// three states read as one family (spec 2026-10-15 "Menu bar icon").
    private static let lidFlameScale: CGFloat = 0.78
    private static let lidLineY: CGFloat = 19.9

    /// Draws into the current context in 24-unit, y-down coordinates.
    static func draw(_ icon: MenuBarIcon) {
        NSColor.black.set()
        switch icon {
        case .off:
            stroke(flame(), width: outlineWidth)
        case .awake:
            flame().fill()
        case .lid:
            lidFlame().fill()
            line(from: NSPoint(x: 3.5, y: lidLineY), to: NSPoint(x: 20.5, y: lidLineY), width: lidLineWidth)
        }
    }

    /// The pilot flame: the flame scaled down around its bottom point and
    /// set just above the lid line. Internal so the test can measure it.
    static func lidFlame() -> NSBezierPath {
        let small = flame()
        var m = AffineTransform(translationByX: -12, byY: -18.8)
        m.append(AffineTransform(scale: lidFlameScale))
        m.append(AffineTransform(translationByX: lidFlameBottom.x, byY: lidFlameBottom.y))
        small.transform(using: m)
        return small
    }

    /// The flame, in 24-unit y-down coordinates (`FlameGeometry`, which the
    /// app icon draws too). Internal so the test can measure it.
    static func flame() -> NSBezierPath {
        NSBezierPath(cgPath: FlameGeometry.path)
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
