import CoreGraphics
import Foundation

/// The flame, Ember's mark: the menu bar's icons (`MenuBarIcon`) and the app
/// icon (`AppIconArtwork`) both draw this one path, so the two can never
/// drift apart. Specified on a 24-unit square, y down: a pointed top, a round
/// bottom through (12, 18.8), and a notch on the left that reads as a second
/// tongue. Imports only CoreGraphics and Foundation, so
/// scripts/generate-app-icon.sh can compile it outside the app target.
enum FlameGeometry {
    static let designSize: CGFloat = 24

    /// The flame on its 24-unit grid. A CGPath is immutable once built, so
    /// sharing this one across threads is safe.
    nonisolated(unsafe) static let path: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 12, y: 2.6))
        p.addCurve(to: CGPoint(x: 17.4, y: 13.4), control1: CGPoint(x: 13.8, y: 6), control2: CGPoint(x: 17.4, y: 8.6))
        // Round bottom: from the right side, down through (12, 18.8), to the left side.
        p.addArc(center: CGPoint(x: 12, y: 13.4), radius: 5.4, startAngle: 0, endAngle: .pi, clockwise: false)
        p.addCurve(to: CGPoint(x: 9.6, y: 7.6), control1: CGPoint(x: 6.6, y: 10.6), control2: CGPoint(x: 8.2, y: 8.8))
        p.addCurve(to: CGPoint(x: 11.6, y: 11.4), control1: CGPoint(x: 9.8, y: 9.6), control2: CGPoint(x: 10.6, y: 10.8))
        p.addCurve(to: CGPoint(x: 12, y: 2.6), control1: CGPoint(x: 11, y: 8.6), control2: CGPoint(x: 11.3, y: 5.4))
        p.closeSubpath()
        return p
    }()

    /// The flame scaled so its 24-unit grid fills `rect`.
    static func flame(in rect: CGRect) -> CGPath {
        var t = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: rect.width / designSize, y: rect.height / designSize)
        return path.copy(using: &t) ?? path
    }
}
