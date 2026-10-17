import AppKit
import CoreGraphics
import XCTest
@testable import Insomnia

/// The app icon, checked on rendered pixels: the menu bar's lit flame
/// (`FlameGeometry`, filled) in moon-white on the midnight tile, centred,
/// at its share of the tile, legible at 16 pixels, and with the notch
/// between its two tongues still open from 32 pixels.
final class BrandingTests: XCTestCase {
    private let moonWhite = Raster.RGB(red: BrandPalette.moonWhite.red, green: BrandPalette.moonWhite.green, blue: BrandPalette.moonWhite.blue).luminance
    private let midnight = Raster.RGB(red: BrandPalette.midnight.red, green: BrandPalette.midnight.green, blue: BrandPalette.midnight.blue).luminance

    /// The menu bar icon and the app icon draw one path, so they cannot drift.
    func testTheMenuBarAndTheAppIconDrawTheSameFlame() {
        XCTAssertEqual(AppIconArtwork.pathData(MenuBarIcon.flame().cgPath), AppIconArtwork.pathData(FlameGeometry.path))
        let grid = CGRect(x: 0, y: 0, width: FlameGeometry.designSize, height: FlameGeometry.designSize)
        XCTAssertEqual(AppIconArtwork.pathData(FlameGeometry.flame(in: grid)), AppIconArtwork.pathData(FlameGeometry.path))
    }

    func testTheFlameIsCentredOnTheTileAtItsShare() {
        let box = AppIconArtwork.flame.boundingBoxOfPath
        let tile = AppIconArtwork.tile
        XCTAssertEqual(box.midX, tile.midX, accuracy: 0.01)
        XCTAssertEqual(box.midY, tile.midY, accuracy: 0.01)
        XCTAssertEqual(box.height, tile.height * AppIconArtwork.flameShare, accuracy: 0.01)
        XCTAssertEqual(AppIconArtwork.flameShare, 0.6)
        XCTAssertTrue(tile.insetBy(dx: tile.width * 0.15, dy: tile.height * 0.15).contains(box), "well inside the tile: \(box)")
    }

    /// Pixel for pixel: moon-white inside the flame, midnight on the rest of
    /// the tile, nothing outside it.
    func testTheIconIsTheFilledFlameOnTheMidnightTile() throws {
        let pixels = 256
        let drawn = IconPixels(try XCTUnwrap(AppIconArtwork.render(pixels: pixels)))
        let scale = CGFloat(pixels) / AppIconArtwork.canvas
        let flame = Raster(size: pixels) { ctx in
            ctx.scaleBy(x: scale, y: scale)
            ctx.addPath(AppIconArtwork.flame)
            ctx.fillPath()
        }
        let tile = AppIconArtwork.tile
        let inner = CGRect(x: tile.minX * scale, y: tile.minY * scale, width: tile.width * scale, height: tile.height * scale)
            .insetBy(dx: tile.width * AppIconArtwork.cornerShare * scale, dy: tile.width * AppIconArtwork.cornerShare * scale)
        var lit = 0, wrongInside = 0, wrongOutside = 0, outsideTile = 0
        for y in 0..<pixels {
            for x in 0..<pixels {
                let centre = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                if flame.alpha(x, y) > 0.99 {
                    lit += 1
                    if abs(drawn.luminance(x, y) - moonWhite) > 0.02 { wrongInside += 1 }
                } else if flame.alpha(x, y) < 0.01, inner.contains(centre) {
                    if abs(drawn.luminance(x, y) - midnight) > 0.02 || drawn.alpha(x, y) < 0.99 { wrongOutside += 1 }
                } else if !CGRect(x: tile.minX * scale, y: tile.minY * scale, width: tile.width * scale, height: tile.height * scale).insetBy(dx: -1, dy: -1).contains(centre) {
                    if drawn.alpha(x, y) > 0 { outsideTile += 1 }
                }
            }
        }
        XCTAssertGreaterThan(lit, pixels * pixels / 20)
        XCTAssertEqual(wrongInside, 0, "the flame is moon-white")
        XCTAssertEqual(wrongOutside, 0, "the rest of the tile is midnight")
        XCTAssertEqual(outsideTile, 0, "nothing outside the tile")
    }

    /// At 16 pixels the flame is still a solid light shape in the middle of
    /// the tile.
    func testTheFlameIsLegibleAt16Pixels() throws {
        let drawn = IconPixels(try XCTUnwrap(AppIconArtwork.render(pixels: 16)))
        var lit: [(Int, Int)] = []
        for y in 0..<16 {
            for x in 0..<16 where drawn.alpha(x, y) > 0.99 && drawn.luminance(x, y) > (moonWhite + midnight) / 2 {
                lit.append((x, y))
            }
        }
        XCTAssertGreaterThanOrEqual(lit.count, 12, "\(lit)")
        let cx = Double(lit.map(\.0).reduce(0, +)) / Double(lit.count) + 0.5
        let cy = Double(lit.map(\.1).reduce(0, +)) / Double(lit.count) + 0.5
        XCTAssertEqual(cx, 8, accuracy: 1, "centred across")
        XCTAssertEqual(cy, 8.5, accuracy: 1.5, "centred down (the round bottom holds most of the mass)")
    }

    /// The notch between the two tongues: a point the flame's path leaves
    /// out, between the left tongue's tip and the main tongue. From 32
    /// pixels it renders clearly darker than the flame.
    func testTheNotchStaysOpenFrom32Pixels() throws {
        let notch = CGPoint(x: 10.6, y: 7.2)
        XCTAssertFalse(FlameGeometry.path.contains(notch), "the probe point is in the notch")
        XCTAssertTrue(FlameGeometry.path.contains(CGPoint(x: 12.3, y: 7.2)), "the main tongue is just right of it")
        XCTAssertTrue(FlameGeometry.path.contains(CGPoint(x: 10.6, y: 12)), "the flame is just below it")
        for pixels in [32, 64, 128] {
            let drawn = IconPixels(try XCTUnwrap(AppIconArtwork.render(pixels: pixels)))
            let scale = CGFloat(pixels) / AppIconArtwork.canvas
            let mark = AppIconArtwork.mark
            let p = CGPoint(x: (mark.minX + notch.x * mark.width / FlameGeometry.designSize) * scale,
                            y: (mark.minY + notch.y * mark.height / FlameGeometry.designSize) * scale)
            let l = drawn.luminance(Int(p.x), Int(p.y))
            XCTAssertLessThan(l, moonWhite - (moonWhite - midnight) * 0.3, "\(pixels) px: the notch at \(p) reads \(l)")
        }
    }
}

/// RGBA8 bitmap with the design's y-down orientation, drawn by CoreGraphics.
struct Raster {
    struct RGB: CustomStringConvertible {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        var luminance: CGFloat { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
        var saturation: CGFloat {
            let hi = max(red, green, blue)
            let lo = min(red, green, blue)
            return hi == 0 ? 0 : (hi - lo) / hi
        }
        var description: String { "rgb(\(red), \(green), \(blue))" }
    }

    let width: Int
    let height: Int
    private let data: [UInt8]

    var total: Int { width * height }

    init(size: Int, draw: (CGContext) -> Void) {
        self.init(width: size, height: size) { ctx in
            // Design coordinates are y-down; CoreGraphics bitmaps are y-up.
            ctx.translateBy(x: 0, y: CGFloat(size))
            ctx.scaleBy(x: 1, y: -1)
            draw(ctx)
        }
    }

    private init(width: Int, height: Int, draw: (CGContext) -> Void) {
        self.width = width
        self.height = height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            draw(ctx)
        }
        data = bytes
    }

    private func offset(_ x: Int, _ y: Int) -> Int {
        precondition(x >= 0 && x < width && y >= 0 && y < height, "pixel (\(x), \(y)) outside \(width)x\(height)")
        return (y * width + x) * 4
    }

    func alpha(_ x: Int, _ y: Int) -> CGFloat {
        CGFloat(data[offset(x, y) + 3]) / 255
    }

    func alpha(_ p: (Int, Int)) -> CGFloat { alpha(p.0, p.1) }

    /// Straight (un-premultiplied) colour at a pixel.
    func rgb(_ p: (Int, Int)) -> RGB {
        let o = offset(p.0, p.1)
        let a = max(CGFloat(data[o + 3]), 1)
        return RGB(red: CGFloat(data[o]) / a, green: CGFloat(data[o + 1]) / a, blue: CGFloat(data[o + 2]) / a)
    }

    func count(where pass: ((alpha: CGFloat, rgb: RGB)) -> Bool) -> Int {
        var n = 0
        for y in 0..<height {
            for x in 0..<width where pass((alpha(x, y), rgb((x, y)))) { n += 1 }
        }
        return n
    }
}

/// Straight RGBA at integer pixels of a rendered CGImage, (0,0) top-left.
struct IconPixels {
    let width: Int
    let height: Int
    private let data: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        data = bytes
    }

    private func offset(_ x: Int, _ y: Int) -> Int {
        precondition(x >= 0 && x < width && y >= 0 && y < height, "pixel (\(x), \(y)) outside \(width)x\(height)")
        return (y * width + x) * 4
    }

    func alpha(_ x: Int, _ y: Int) -> CGFloat {
        CGFloat(data[offset(x, y) + 3]) / 255
    }

    func luminance(_ x: Int, _ y: Int) -> CGFloat {
        let o = offset(x, y)
        let a = max(CGFloat(data[o + 3]), 1)
        let r = CGFloat(data[o]) / a, g = CGFloat(data[o + 1]) / a, b = CGFloat(data[o + 2]) / a
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// Pixels where any channel of the two images differs by more than `tolerance` (0 to 255).
    func differences(from other: IconPixels, tolerance: Int) -> Int {
        precondition(width == other.width && height == other.height)
        var n = 0
        for i in stride(from: 0, to: data.count, by: 4) {
            for c in 0..<4 where abs(Int(data[i + c]) - Int(other.data[i + c])) > tolerance {
                n += 1
                break
            }
        }
        return n
    }
}
