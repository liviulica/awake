import AppKit
import XCTest
@testable import Insomnia

@MainActor
final class MenuBarIconTests: XCTestCase {
    func testEveryIconIsAnEighteenPointTemplate() {
        for icon in MenuBarIcon.allCases {
            let image = MenuBarIcon.image(icon)
            XCTAssertTrue(image.isTemplate, "\(icon)")
            XCTAssertEqual(image.size, NSSize(width: 18, height: 18), "\(icon)")
            XCTAssertNotNil(image.accessibilityDescription, "\(icon)")
        }
    }

    func testIconsDrawSomethingAndDifferFromEachOther() {
        let renders = MenuBarIcon.allCases.map { Self.inkCount(MenuBarIcon.image($0)) }
        for (icon, ink) in zip(MenuBarIcon.allCases, renders) {
            XCTAssertGreaterThan(ink, 20, "\(icon) drew nothing")
        }
        XCTAssertGreaterThan(renders[1], renders[0], "awake (filled) has more ink than off (outline)")
        XCTAssertEqual(Set(MenuBarIcon.allCases.map { Self.png(MenuBarIcon.image($0)) }).count, 3)
    }

    /// The flame's round bottom is drawn below its centre (the arc goes
    /// through y 18.8), and the lid icon's flame is small: ink near the
    /// top only for the full flame.
    func testPilotLightShapes() {
        let awake = Self.bitmap(MenuBarIcon.image(.awake))
        // 36 px render = 1.5 px per unit; bitmap y 0 is the top.
        XCTAssertGreaterThan(awake.colorAt(x: 18, y: 25)?.alphaComponent ?? 0, 0.5, "inside the flame's round bottom")
        XCTAssertGreaterThan(awake.colorAt(x: 18, y: 6)?.alphaComponent ?? 0, 0.3, "the full flame reaches near the top")
        let lid = Self.bitmap(MenuBarIcon.image(.lid))
        XCTAssertLessThan(lid.colorAt(x: 18, y: 6)?.alphaComponent ?? 1, 0.1, "the pilot flame is low")
        XCTAssertGreaterThan(lid.colorAt(x: 18, y: 29)?.alphaComponent ?? 0, 0.5, "the closed lid line")
        let off = Self.bitmap(MenuBarIcon.image(.off))
        XCTAssertLessThan(off.colorAt(x: 18, y: 19)?.alphaComponent ?? 1, 0.2, "off is an outline: its middle is empty")
    }

    /// Pixels with any alpha in a 36×36 render (2x).
    private static func inkCount(_ image: NSImage) -> Int {
        let rep = bitmap(image)
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                count += 1
            }
        }
        return count
    }

    private static func png(_ image: NSImage) -> Data {
        bitmap(image).representation(using: .png, properties: [:]) ?? Data()
    }

    static func bitmap(_ image: NSImage) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 36, height: 36))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
