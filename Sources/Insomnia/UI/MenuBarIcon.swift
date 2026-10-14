import AppKit

/// The three menu bar states (spec "Menu bar icon"), drawn in code as
/// template images so macOS tints them for light and dark bars. An outline
/// means off and a filled shape means on, as in Caffeine; lid mode is a
/// small robot on a closed lid.
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
            stroke(NSBezierPath(roundedRect: NSRect(x: 4.2, y: 4.8, width: 15.6, height: 11.2), xRadius: 1.6, yRadius: 1.6), width: 1.7)
            line(from: NSPoint(x: 2.5, y: 19.2), to: NSPoint(x: 21.5, y: 19.2), width: 1.7)
        case .awake:
            let screen = NSBezierPath(roundedRect: NSRect(x: 4.2, y: 4.8, width: 15.6, height: 11.2), xRadius: 1.6, yRadius: 1.6)
            screen.fill()
            stroke(screen, width: 1.7)
            line(from: NSPoint(x: 2.5, y: 19.2), to: NSPoint(x: 21.5, y: 19.2), width: 1.7)
        case .lid:
            stroke(NSBezierPath(roundedRect: NSRect(x: 6, y: 7, width: 12, height: 8.6), xRadius: 2.6, yRadius: 2.6), width: 1.7)
            line(from: NSPoint(x: 12, y: 7), to: NSPoint(x: 12, y: 4.6), width: 1.7)
            dot(NSPoint(x: 12, y: 3.9), radius: 1)
            dot(NSPoint(x: 9.6, y: 11.3), radius: 1.3)
            dot(NSPoint(x: 14.4, y: 11.3), radius: 1.3)
            line(from: NSPoint(x: 2.5, y: 19.4), to: NSPoint(x: 21.5, y: 19.4), width: 2.2)
        }
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

    private static func dot(_ center: NSPoint, radius: CGFloat) {
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
    }
}
