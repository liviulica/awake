import CoreGraphics
import XCTest
@testable import Insomnia

/// The marks, checked on rendered geometry. The app icon: the menu bar's
/// open eye (`EyeMarkGeometry` at progress 1) on the charcoal tile, the pupil
/// on the axis inside the lens, nothing touching the outline, the drawn mark
/// centred on the tile, and the lashes left out only at 16 pixels. The eye's
/// geometry: five lashes that swap sides, the pupil inside the lens, and a
/// lid that shades exactly the lens.
final class BrandingTests: XCTestCase {
    private let grid = CGRect(x: 0, y: 0, width: EyeLensGeometry.designSize, height: EyeLensGeometry.designSize)

    func testThePupilSitsOnTheAxisInsideTheLensAndNothingTouchesTheOutline() {
        let lens = EyeMarkGeometry.lens(in: grid)
        XCTAssertEqual(EyeMarkGeometry.pupilCenter.y, EyeMarkGeometry.axisY, "the pupil is centred on the eye's axis")
        XCTAssertEqual(EyeMarkGeometry.pupilCenter.x, lens.boundingBoxOfPath.midX, accuracy: 0.001, "the pupil is centred between the corners")

        // Rendered at the app icon's smallest size that keeps the lashes:
        // the pupil fills the inside of the lens and the lashes stand
        // outside it, and neither shares a pixel with the outline.
        let size = 96
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let eye = EyeMarkGeometry.lens(in: rect)
        let width = EyeLensGeometry.lineWidth(for: CGFloat(size))
        let outline = Raster(size: size) { ctx in
            ctx.addPath(eye)
            ctx.setLineWidth(width)
            ctx.strokePath()
        }
        let pupil = Raster(size: size) { ctx in
            ctx.addPath(EyeMarkGeometry.pupil(in: rect))
            ctx.fillPath()
        }
        let lashes = Raster(size: size) { ctx in
            ctx.addPath(EyeMarkGeometry.lashes(in: rect, side: .above))
            ctx.setLineWidth(width)
            ctx.setLineCap(.round)
            ctx.strokePath()
        }
        var pupilPixels = 0, pupilOnOutline = 0, pupilOutsideEye = 0
        var lashPixels = 0, lashOnOutline = 0, lashInsideEye = 0
        for y in 0..<size {
            for x in 0..<size {
                let centre = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                if pupil.alpha(x, y) > 0.5 {
                    pupilPixels += 1
                    if outline.alpha(x, y) > 0.05 { pupilOnOutline += 1 }
                    if !eye.contains(centre) { pupilOutsideEye += 1 }
                }
                if lashes.alpha(x, y) > 0.5 {
                    lashPixels += 1
                    if outline.alpha(x, y) > 0.05 { lashOnOutline += 1 }
                    if eye.contains(centre) { lashInsideEye += 1 }
                }
            }
        }
        XCTAssertGreaterThan(pupilPixels, size * size / 40, "the pupil is a solid disc, not a dot")
        XCTAssertEqual(pupilOnOutline, 0, "the pupil must not touch the eye outline")
        XCTAssertEqual(pupilOutsideEye, 0, "the pupil must sit inside the eye")
        XCTAssertGreaterThan(lashPixels, 5 * size / 8, "five lashes are drawn")
        XCTAssertEqual(lashOnOutline, 0, "the lashes must not touch the eye outline")
        XCTAssertEqual(lashInsideEye, 0, "the lashes stand outside the eye")
        // Only the outline, the pupil and the lashes: one closed outline, one closed pupil, five open lashes.
        XCTAssertEqual(subpathCount(eye), 1)
        XCTAssertEqual(subpathCount(EyeMarkGeometry.pupil(in: rect)), 1)
        XCTAssertEqual(subpathCount(EyeMarkGeometry.lashes(in: rect, side: .above)), 5)
    }

    /// Pixel for pixel, the icon's ink is the open menu bar eye: the lens,
    /// the five upper lashes and the pupil of `EyeMarkGeometry` at progress
    /// 1, in the icon's mark square, and nothing else (the lid at progress 1
    /// draws nothing, and the lower lashes are absent).
    func testTheIconDrawsTheOpenMenuBarEyeAndNothingElse() throws {
        let pixels = 256
        let icon = try XCTUnwrap(AppIconArtwork.render(pixels: pixels))
        let drawn = IconPixels(icon)
        let scale = CGFloat(pixels) / AppIconArtwork.canvas
        let mark = AppIconArtwork.mark
        let expected = Raster(size: pixels) { ctx in
            ctx.scaleBy(x: scale, y: scale)
            ctx.setLineWidth(EyeLensGeometry.lineWidth(for: mark.width))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(EyeMarkGeometry.lens(in: mark))
            ctx.strokePath()
            ctx.addPath(EyeMarkGeometry.lashes(in: mark, side: .above))
            ctx.strokePath()
            ctx.addPath(EyeMarkGeometry.pupil(in: mark))
            ctx.fillPath()
            ctx.addPath(EyeMarkGeometry.lid(in: mark, progress: 1))
            ctx.fillPath()
        }
        // Half way between the tile and the ink is half coverage, where the
        // expected raster's alpha is also half; a few edge pixels can round
        // either way, nothing more.
        let halfInk = (luminance(BrandPalette.midnight) + luminance(BrandPalette.moonWhite)) / 2
        var ink = 0, mismatches = 0
        for y in 0..<pixels {
            for x in 0..<pixels {
                let isInk = drawn.alpha(x, y) > 0.99 && drawn.luminance(x, y) > halfInk
                if isInk { ink += 1 }
                if isInk != (expected.alpha(x, y) > 0.5) { mismatches += 1 }
            }
        }
        XCTAssertGreaterThan(ink, pixels * pixels / 50, "the mark is drawn")
        XCTAssertLessThanOrEqual(mismatches, pixels * pixels / 2000, "the icon's ink differs from the open eye at \(mismatches) of \(pixels * pixels) pixels")

        // And the lower lashes, the closed eye's, are not there.
        let below = EyeMarkGeometry.lashes(in: mark, side: .below)
        for point in points(of: below) {
            let x = Int(point.x * scale), y = Int(point.y * scale)
            XCTAssertLessThan(drawn.luminance(x, y), 0.3, "no lash below the icon's eye at \(point)")
        }
    }

    /// The 24-unit grid is 76% of the tile and centred across it, and sits
    /// down the tile so that what is drawn is centred rather than the grid:
    /// lower with the lashes (lashes above, lens below), and on the tile's
    /// centre without them (lens and pupil on the axis).
    func testTheMarkKeepsItsShareOfTheTileAndItsInkIsCentredOnIt() {
        let tile = AppIconArtwork.tile
        for (mark, lashes) in [(AppIconArtwork.mark, true), (AppIconArtwork.markWithoutLashes, false)] {
            XCTAssertEqual(mark.width, tile.width * 0.76, accuracy: 0.001)
            XCTAssertEqual(mark.height, mark.width)
            XCTAssertEqual(mark.midX, tile.midX, accuracy: 0.001)
            let inked = AppIconArtwork.inked(in: mark, lashes: lashes)
            XCTAssertEqual(inked.midX, tile.midX, accuracy: 0.01, "lashes \(lashes): the ink is centred across the tile")
            XCTAssertEqual(inked.midY, tile.midY, accuracy: 0.01, "lashes \(lashes): the ink is centred down the tile")
            XCTAssertTrue(tile.insetBy(dx: 40, dy: 40).contains(inked), "lashes \(lashes): the ink stays well inside the tile: \(inked)")
        }
        XCTAssertGreaterThan(AppIconArtwork.mark.midY, tile.midY, "the grid sits low so the lashes do not push the eye up")
        XCTAssertEqual(AppIconArtwork.markWithoutLashes.midY, tile.midY, accuracy: 0.01, "without lashes the eye's axis is the tile's centre line")
        XCTAssertEqual(tile, CGRect(x: 100, y: 100, width: 824, height: 824))
        XCTAssertEqual(AppIconArtwork.cornerShare, 0.2237)
    }

    /// At 16 pixels the icon is the lens and pupil alone, placed on the
    /// tile's centre: pixel for pixel the lash-free drawing, and its ink
    /// balanced about the tile's centre line. The placement worked out for
    /// the lashes would put it about a pixel low.
    func testThe16PixelIconIsTheLashFreeEyeCentredOnTheTile() throws {
        let pixels = 16
        let drawn = IconPixels(try XCTUnwrap(AppIconArtwork.render(pixels: pixels)))
        let scale = CGFloat(pixels) / AppIconArtwork.canvas
        let mark = AppIconArtwork.markWithoutLashes
        let expected = Raster(size: pixels) { ctx in
            ctx.scaleBy(x: scale, y: scale)
            ctx.setLineWidth(max(EyeLensGeometry.lineWidth(for: mark.width), AppIconArtwork.minimumStrokePixels / scale))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(EyeMarkGeometry.lens(in: mark))
            ctx.strokePath()
            ctx.addPath(EyeMarkGeometry.pupil(in: mark))
            ctx.fillPath()
        }
        let tileInk = luminance(BrandPalette.midnight), markInk = luminance(BrandPalette.moonWhite)
        var mismatches = 0
        var weight: CGFloat = 0, weightedY: CGFloat = 0
        for y in 0..<pixels {
            for x in 0..<pixels where drawn.alpha(x, y) > 0.99 {
                let coverage = min(max((drawn.luminance(x, y) - tileInk) / (markInk - tileInk), 0), 1)
                // Coverage against coverage, not each against a half-way
                // threshold: the eye's axis falls on a pixel boundary at
                // this size, so many edge pixels are half covered.
                if abs(coverage - expected.alpha(x, y)) > 0.1 { mismatches += 1 }
                weight += coverage
                weightedY += coverage * (CGFloat(y) + 0.5)
            }
        }
        XCTAssertEqual(mismatches, 0, "the 16px icon differs from the lash-free eye at \(mismatches) pixels")
        XCTAssertGreaterThan(weight, 20, "the eye is drawn at 16 pixels")
        // The pupil's highlight takes a little ink from above the axis,
        // which moves the balance down by a few hundredths of a pixel.
        let centre = AppIconArtwork.tile.midY * scale
        XCTAssertEqual(weightedY / weight, centre, accuracy: 0.25, "the eye's ink is centred down the 16px tile")
    }

    /// The lashes are kept from 32 pixels up, where they still read as five
    /// strokes, and left out at 16, where they were a grey band over a
    /// nine-pixel eye.
    func testTheLashesAreDrawnFrom32PixelsAndLeftOutAt16() throws {
        XCTAssertEqual(AppIconArtwork.lashesFromPixels, 32)
        // Each lash's midpoint, placed where the lashes would go on the eye
        // drawn at that size, which at 16 pixels is still a full pixel clear
        // of the outline's one-pixel floor stroke.
        func midpoints(_ mark: CGRect) -> [CGPoint] {
            let ends = points(of: EyeMarkGeometry.lashes(in: mark, side: .above))
            XCTAssertEqual(ends.count, 10)
            var midpoints: [CGPoint] = []
            for i in stride(from: 0, to: ends.count, by: 2) {
                let a = ends[i], b = ends[i + 1]
                midpoints.append(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
            }
            return midpoints
        }
        /// The brightest of each midpoint's pixel and its two horizontal neighbours.
        func lashLight(_ pixels: Int) throws -> [CGFloat] {
            let px = IconPixels(try XCTUnwrap(AppIconArtwork.render(pixels: pixels)))
            let scale = CGFloat(pixels) / AppIconArtwork.canvas
            let mark = pixels < AppIconArtwork.lashesFromPixels ? AppIconArtwork.markWithoutLashes : AppIconArtwork.mark
            var lights: [CGFloat] = []
            for mid in midpoints(mark) {
                let x = Int(mid.x * scale), y = Int(mid.y * scale)
                var brightest: CGFloat = 0
                for dx in -1...1 { brightest = max(brightest, px.luminance(x + dx, y)) }
                lights.append(brightest)
            }
            return lights
        }
        let at16 = try lashLight(16)
        for light in at16 {
            XCTAssertLessThan(light, 0.45, "no lashes at 16 pixels: \(at16)")
        }
        for pixels in [32, 64, 1024] {
            let lights = try lashLight(pixels)
            for light in lights {
                XCTAssertGreaterThan(light, 0.5, "lashes at \(pixels) pixels: \(lights)")
            }
        }
    }

    private func luminance(_ rgb: BrandPalette.RGB) -> CGFloat {
        0.2126 * rgb.red + 0.7152 * rgb.green + 0.0722 * rgb.blue
    }

    func testLashesAreFiveStrokesThatSwapSidesAndThePupilSitsInsideTheLens() {
        let lens = EyeMarkGeometry.lens(in: grid)
        let axisY = grid.midY
        let open = EyeMarkGeometry.lashes(in: grid, side: .above)
        let closed = EyeMarkGeometry.lashes(in: grid, side: .below)
        XCTAssertEqual(subpathCount(open), 5)
        XCTAssertEqual(subpathCount(closed), 5)
        for point in points(of: open) {
            XCTAssertLessThan(point.y, axisY, "open lashes stand above the axis: \(point)")
            XCTAssertFalse(lens.contains(point), "lashes stay outside the lens: \(point)")
        }
        for point in points(of: closed) {
            XCTAssertGreaterThan(point.y, axisY, "closed lashes hang below the axis: \(point)")
            XCTAssertFalse(lens.contains(point), "lashes stay outside the lens: \(point)")
        }
        // Each lash is a plain segment of the designed length.
        XCTAssertEqual(points(of: open).count, 10)
        for pair in stride(from: 0, to: 10, by: 2) {
            let a = points(of: open)[pair], b = points(of: open)[pair + 1]
            XCTAssertEqual(hypot(b.x - a.x, b.y - a.y), EyeMarkGeometry.lashLength, accuracy: 0.01)
        }

        let pupil = EyeMarkGeometry.pupil(in: grid)
        XCTAssertEqual(subpathCount(pupil), 1)
        for point in points(of: pupil) {
            XCTAssertTrue(lens.contains(point), "the pupil sits inside the lens: \(point)")
        }
        // Solid at the centre, open at the highlight.
        XCTAssertTrue(pupil.contains(EyeMarkGeometry.pupilCenter))
        XCTAssertFalse(pupil.contains(EyeMarkGeometry.highlightCenter))

    }

    func testLidShadesTheWholeLensClosedNothingOpenAndLiftsOffThePupilFromTheBottom() {
        let size = 96
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let unit = CGFloat(size) / EyeLensGeometry.designSize
        func raster(_ path: CGPath) -> Raster {
            Raster(size: size) { ctx in
                ctx.addPath(path)
                ctx.fillPath()
            }
        }
        func inked(_ path: CGPath) -> Int { raster(path).count { $0.alpha > 0.5 } }

        let closed = inked(EyeMarkGeometry.lid(in: rect, progress: 0))
        let open = inked(EyeMarkGeometry.lid(in: rect, progress: 1))
        let half = inked(EyeMarkGeometry.lid(in: rect, progress: 0.5))
        XCTAssertEqual(open, 0, "an open lid shades nothing")
        // Pixel for pixel, the closed lid is the filled lens.
        let closedLid = raster(EyeMarkGeometry.lid(in: rect, progress: 0))
        let lens = raster(EyeMarkGeometry.lens(in: rect))
        var mismatches = 0
        for y in 0..<size {
            for x in 0..<size where (closedLid.alpha(x, y) > 0.5) != (lens.alpha(x, y) > 0.5) { mismatches += 1 }
        }
        XCTAssertEqual(mismatches, 0, "a closed lid shades exactly the lens")
        XCTAssertGreaterThan(half, open, "half way, some of the lens is shaded")
        XCTAssertLessThan(half, closed, "half way, some of the lens is clear")
        XCTAssertEqual(subpathCount(EyeMarkGeometry.lid(in: rect, progress: 0.5)), 1)

        // Half way, the pupil's centre column is covered above the axis and clear below it.
        let lid = raster(EyeMarkGeometry.lid(in: rect, progress: 0.5))
        let column = Int(EyeMarkGeometry.pupilCenter.x * unit)
        let axis = Int(EyeMarkGeometry.pupilCenter.y * unit)
        let radius = Int(EyeMarkGeometry.pupilRadius * unit)
        for y in (axis + 1)...(axis + radius) {
            XCTAssertLessThan(lid.alpha(column, y), 0.5, "the lower pupil is uncovered at row \(y)")
        }
        for y in (axis - radius)...(axis - 1) {
            XCTAssertGreaterThan(lid.alpha(column, y), 0.5, "the upper pupil is still shaded at row \(y)")
        }
    }

    func testStrokedLensAndLashesFitInsideTheSeventeenPointFrame() {
        let frame = CGRect(x: 0, y: 0, width: 17, height: 17)
        let width = EyeLensGeometry.lineWidth(for: frame.width)
        let stroked = CGMutablePath()
        for path in [EyeMarkGeometry.lens(in: frame), EyeMarkGeometry.lashes(in: frame, side: .above), EyeMarkGeometry.lashes(in: frame, side: .below)] {
            stroked.addPath(path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10))
        }
        let box = stroked.boundingBoxOfPath
        XCTAssertTrue(frame.contains(box), "the view's frame clips the mark: \(box)")
        // Enough headroom that a sub-pixel rasteriser does not clip the caps.
        let headroom = 0.4 * frame.width / EyeLensGeometry.designSize
        XCTAssertGreaterThanOrEqual(box.minY - frame.minY, headroom, "upper lashes too close to the edge: \(box)")
        XCTAssertLessThanOrEqual(box.maxY, frame.maxY - headroom, "lower lashes too close to the edge: \(box)")
    }

    func testPupilStaysClearOfTheOutlineAtSeventeenPoints() {
        let size = 34  // 17 pt @2x
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let outline = Raster(size: size) { ctx in
            ctx.addPath(EyeMarkGeometry.lens(in: rect))
            ctx.setLineWidth(EyeLensGeometry.lineWidth(for: CGFloat(size)))
            ctx.strokePath()
        }
        let fill = Raster(size: size) { ctx in
            ctx.addPath(EyeMarkGeometry.pupil(in: rect))
            ctx.fillPath()
        }
        var pupilPixels = 0
        var overlap = 0
        for y in 0..<size {
            for x in 0..<size where fill.alpha(x, y) > 0.5 {
                pupilPixels += 1
                if outline.alpha(x, y) > 0.05 { overlap += 1 }
            }
        }
        XCTAssertGreaterThan(pupilPixels, size * size / 40, "the pupil is a solid disc, not a dot")
        XCTAssertEqual(overlap, 0, "the pupil must not touch the eye outline")
    }

    // MARK: - The lid geometry

    /// The lid's progress is left unclamped in the view so the spring can
    /// overshoot; the geometry bounds what is drawn instead.
    func testTheLidGeometryClampHoldsBelowZeroAndAboveOne() {
        let size = 96
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        func raster(_ progress: CGFloat) -> Raster {
            Raster(size: size) { ctx in
                ctx.addPath(EyeMarkGeometry.lid(in: rect, progress: progress))
                ctx.fillPath()
            }
        }
        func mismatches(_ a: Raster, _ b: Raster) -> Int {
            var n = 0
            for y in 0..<size {
                for x in 0..<size where (a.alpha(x, y) > 0.5) != (b.alpha(x, y) > 0.5) { n += 1 }
            }
            return n
        }
        let closed = raster(0), open = raster(1)
        for below in [-0.01, -0.5, -3] as [CGFloat] {
            XCTAssertEqual(mismatches(raster(below), closed), 0, "progress \(below) draws the closed lid")
        }
        for above in [1.01, 1.04, 1.5, 4] as [CGFloat] {
            XCTAssertEqual(mismatches(raster(above), open), 0, "progress \(above) draws the open lid")
            XCTAssertEqual(raster(above).count { $0.alpha > 0.5 }, 0, "progress \(above) shades nothing")
        }
        // And every out-of-range lid is still one well-formed subpath inside the frame.
        for progress in [-3, 4] as [CGFloat] {
            let lid = EyeMarkGeometry.lid(in: rect, progress: progress)
            XCTAssertEqual(subpathCount(lid), 1)
            XCTAssertTrue(rect.contains(lid.boundingBoxOfPath), "\(lid.boundingBoxOfPath)")
        }
    }

    // MARK: - Helpers

    private func subpathCount(_ path: CGPath) -> Int {
        var moves = 0
        path.applyWithBlock { element in
            if element.pointee.type == .moveToPoint { moves += 1 }
        }
        return moves
    }

    /// Every point of every element, control points included.
    private func points(of path: CGPath) -> [CGPoint] {
        var points: [CGPoint] = []
        path.applyWithBlock { element in
            let count: Int
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint: count = 1
            case .addQuadCurveToPoint: count = 2
            case .addCurveToPoint: count = 3
            case .closeSubpath: count = 0
            @unknown default: count = 0
            }
            for i in 0..<count { points.append(element.pointee.points[i]) }
        }
        return points
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
