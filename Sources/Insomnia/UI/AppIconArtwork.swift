import CoreGraphics
import Foundation

/// The app icon as one drawing: the lit flame, the menu bar's screen-on
/// icon (`FlameGeometry`, filled), in moon-white on the midnight rounded
/// tile. scripts/generate-app-icon.sh compiles this file with the geometry
/// and palette into the icon generator, which writes the PNG, the ICNS
/// members and the README SVG. PackagingTests renders this drawing and
/// compares it with all three checked-in files, so a geometry edit fails the
/// tests until the script runs again. The file imports only CoreGraphics and
/// Foundation, so swiftc can build it outside the app target.
enum AppIconArtwork {
    /// Apple's macOS icon layout. The rounded tile sits 100 units in from
    /// each edge of the 1024 canvas, and the system draws the icon's shadow
    /// in that margin. The corner radius is 22.37% of the tile side.
    static let canvas: CGFloat = 1024
    static let tileInset: CGFloat = 100
    static let cornerShare: CGFloat = 0.2237
    /// The flame's height as a share of the tile side (the chargingpixels.com
    /// version uses the same).
    static let flameShare: CGFloat = 0.6

    /// The tile, in canvas units.
    static let tile = CGRect(x: tileInset, y: tileInset, width: canvas - 2 * tileInset, height: canvas - 2 * tileInset)

    /// The flame's 24-unit grid placed on the canvas: scaled so the flame is
    /// `flameShare` of the tile tall, and moved so the flame itself (not the
    /// grid) is centred on the tile.
    static let mark: CGRect = {
        let grid = CGRect(x: 0, y: 0, width: FlameGeometry.designSize, height: FlameGeometry.designSize)
        let ink = FlameGeometry.path.boundingBoxOfPath
        let side = tile.height * flameShare / ink.height * FlameGeometry.designSize
        let scale = side / grid.width
        return CGRect(x: tile.midX - ink.midX * scale, y: tile.midY - ink.midY * scale, width: side, height: side)
    }()

    /// The flame, in canvas units.
    static var flame: CGPath { FlameGeometry.flame(in: mark) }

    /// The whole icon at `pixels` square. Returns nil if CoreGraphics cannot
    /// create a bitmap context of that size.
    static func render(pixels: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        // Work in canvas units, y-down like the geometry.
        let scale = CGFloat(pixels) / canvas
        ctx.translateBy(x: 0, y: CGFloat(pixels))
        ctx.scaleBy(x: scale, y: -scale)
        draw(in: ctx)
        return ctx.makeImage()
    }

    /// Draws the icon into a context whose transform maps canvas units to
    /// device pixels.
    static func draw(in ctx: CGContext) {
        let corner = tile.width * cornerShare
        ctx.addPath(CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil))
        ctx.setFillColor(BrandPalette.midnight.cgColor)
        ctx.fillPath()
        ctx.addPath(flame)
        ctx.setFillColor(BrandPalette.moonWhite.cgColor)
        ctx.fillPath()
    }

    // MARK: - The README SVG

    /// The same drawing as an SVG document, 112 CSS pixels square. The
    /// viewBox is the tile alone, which drops the 100-unit canvas margin.
    /// The flame comes from the same geometry on the 24-unit grid, inside a
    /// transform that places the grid on the tile.
    static func svg() -> String {
        let scale = mark.width / FlameGeometry.designSize
        return """
        <svg xmlns="http://www.w3.org/2000/svg" width="112" height="112" viewBox="\(number(tile.minX)) \(number(tile.minY)) \(number(tile.width)) \(number(tile.height))" role="img" aria-labelledby="ember-title ember-desc">
          <title id="ember-title">Ember</title>
          <desc id="ember-desc">The Ember mark: a lit flame with a pointed top, a round bottom and a second tongue on its left, in moon-white on a midnight rounded tile.</desc>
          <!-- scripts/generate-app-icon.sh writes this file from AppIconArtwork, and PackagingTests fails if the two differ, so edit the Swift drawing and rerun the script. The layout matches the app icon: an \(number(tile.width))-unit tile inset \(number(tileInset)) units in a \(number(canvas)) canvas, corners at \(number(cornerShare * 100))% of the tile, the flame \(number(flameShare * 100))% of the tile tall and centred on it. -->
          <rect x="\(number(tile.minX))" y="\(number(tile.minY))" width="\(number(tile.width))" height="\(number(tile.height))" rx="\(number(tile.width * cornerShare))" fill="\(hex(BrandPalette.midnight))"/>
          <!-- FlameGeometry on its 24-unit grid, the same path as the menu bar's screen-on icon. -->
          <g transform="translate(\(number(mark.minX)) \(number(mark.minY))) scale(\(number(scale)))">
            <path d="\(pathData(FlameGeometry.path))" fill="\(hex(BrandPalette.moonWhite))"/>
          </g>
        </svg>

        """
    }

    /// Converts a CGPath to SVG path data. CoreGraphics turns arcs into
    /// cubic curves when it adds them to a path, so the geometry's paths
    /// hold only moves, lines, cubics and closes.
    static func pathData(_ path: CGPath) -> String {
        var commands: [String] = []
        var current = CGPoint.zero
        path.applyWithBlock { element in
            let p = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:
                commands.append("M\(point(p[0]))")
                current = p[0]
            case .addLineToPoint:
                // An arc starts with a line to its first point, which is a
                // zero-length segment when the path is already there.
                if hypot(p[0].x - current.x, p[0].y - current.y) > 0.00005 {
                    commands.append("L\(point(p[0]))")
                }
                current = p[0]
            case .addQuadCurveToPoint:
                commands.append("Q\(point(p[0])) \(point(p[1]))")
                current = p[1]
            case .addCurveToPoint:
                commands.append("C\(point(p[0])) \(point(p[1])) \(point(p[2]))")
                current = p[2]
            case .closeSubpath:
                commands.append("Z")
            @unknown default:
                break
            }
        }
        return commands.joined(separator: " ")
    }

    private static func point(_ p: CGPoint) -> String {
        "\(number(p.x)) \(number(p.y))"
    }

    /// Formats a number to four decimals and drops trailing zeros, so two
    /// runs write identical SVG bytes and a coordinate reads 12.5, not
    /// 12.5000.
    static func number(_ value: CGFloat) -> String {
        var text = String(format: "%.4f", Double(value))
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    /// A palette colour as `#RRGGBB`.
    static func hex(_ rgb: BrandPalette.RGB) -> String {
        let channels = [rgb.red, rgb.green, rgb.blue].map { Int(($0 * 255).rounded()) }
        return "#" + channels.map { String(format: "%02X", $0) }.joined()
    }
}
