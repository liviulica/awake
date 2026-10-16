import AppKit
import SwiftUI
import XCTest
@testable import Insomnia

/// The setup window's view, built in a test for each step: nothing is shown
/// on screen, but every step has to lay out.
@MainActor
final class HotspotSetupViewTests: XCTestCase {
    private struct Scanner: WiFiScanning {
        func scan() async throws -> ScannedNetworks { ScannedNetworks(names: ["Home", "iPhone"], current: "Home") }
    }

    func testEveryStepLaysOut() async {
        let setup = HotspotSetup(config: Config(), scanner: Scanner(), secrets: InMemoryHotspotSecretStore(),
                                 saveConfig: { _ in }, passwordStored: { _ in })
        let permission = LocationPermission(authorizationStatus: .notDetermined)
        var seen: [HotspotSetup.Step] = []
        for _ in 0..<4 {
            let host = NSHostingController(rootView: HotspotSetupView(setup: setup, locationPermission: permission, onDone: {}))
            host.view.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.view.fittingSize.width, 300, "\(setup.step)")
            XCTAssertGreaterThan(host.view.fittingSize.height, 100, "\(setup.step)")
            seen.append(setup.step)
            if setup.step == .hotspot { setup.pick("iPhone") }
            if setup.step == .password { setup.password = "secret" }
            await setup.next()
        }
        XCTAssertEqual(seen, [.wifiNames, .hotspot, .password, .done])
    }
}
